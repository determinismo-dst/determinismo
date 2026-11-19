// SPDX-License-Identifier: MIT
//! Plugins as WebAssembly modules, run inside the explorer (`--strategy "wasm:<module.wasm>
//! [arguments]"`): WAMR's fast interpreter compiled into it (build.zig's wamr_link), each
//! hook a direct call, no process, pipe or ring between them. The messages are the other
//! transports' (docs/PLUGINS.md), so every hook a plugin can want is a wasm module's too.
//!
//! The module's side, the ABI `determinismo_1` (its imports' module name: a module built for
//! another major is refused at load):
//!
//!   export fn det_call(request_size: u32) i32      a request: 0 once its reply is written
//!   import request_read(buffer, length) i32        copies the request's next bytes; 0 at its end
//!   import reply_write(bytes, length) i32          appends to the reply; nonzero past its room
//!   import log(level, bytes, length)               a line on the explorer's standard error
//!
//! The host owns the request and the reply: a module needs no allocator of its own exported,
//! and reads a large request (a history) in parts.
//! Each call has an instruction budget (WAMR's metering): a module that loops, traps or
//! fails answers `{}` (the defaults), said on standard error; the explorer goes on.
//!
//! The module's memory is a plain mapping of the explorer's: it forks with it, a timeline's
//! process carrying the plugin's state as of its start. It imports nothing else: a module
//! that reads no clock and draws from no host is a function of the messages it is sent.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const prefix = "wasm:";
/// The import module name a module's host functions come from: its ABI's major version.
pub const abi = "determinismo_1";
/// A module's file at most this large.
const module_size_max = 64 << 20;
/// One call's instructions at most (a decision's answer takes thousands; a history's check
/// millions): past it, the call ends and its answer is the defaults.
const instructions_per_call_max = 2_000_000_000;
/// The module's operand stack and its host-managed heap (none: it has its own memory).
const stack_size = 256 << 10;
const error_size_max = 256;

const Module = opaque {};
const Instance = opaque {};
const ExecEnv = opaque {};
const Function = opaque {};

/// WAMR's NativeSymbol (wasm_export.h): a host function by name, its signature in WAMR's
/// notation (`*~`: a pointer and its length, checked against the module's memory).
const NativeSymbol = extern struct {
    symbol: [*:0]const u8,
    function: *const anyopaque,
    signature: [*:0]const u8,
    attachment: ?*anyopaque = null,
};

extern fn wasm_runtime_init() bool;
extern fn wasm_runtime_register_natives(module_name: [*:0]const u8, symbols: [*]NativeSymbol, count: u32) bool;
extern fn wasm_runtime_load(bytes: [*]u8, size: u32, error_buffer: [*]u8, error_size: u32) ?*Module;
extern fn wasm_runtime_instantiate(module: *Module, stack: u32, heap: u32, error_buffer: [*]u8, error_size: u32) ?*Instance;
extern fn wasm_runtime_lookup_function(instance: *Instance, name: [*:0]const u8) ?*Function;
extern fn wasm_runtime_create_exec_env(instance: *Instance, stack: u32) ?*ExecEnv;
extern fn wasm_runtime_call_wasm(env: *ExecEnv, function: *Function, argc: u32, argv: [*]u32) bool;
extern fn wasm_runtime_get_exception(instance: *Instance) ?[*:0]const u8;
extern fn wasm_runtime_clear_exception(instance: *Instance) void;
extern fn wasm_runtime_set_instruction_count_limit(env: *ExecEnv, count: c_int) void;

/// The call in progress (the explorer is one thread: one at a time), for the host functions.
const Call = struct {
    request: []const u8,
    read: usize = 0,
    reply: []u8,
    written: usize = 0,
    overflow: bool = false,
    name: []const u8,
};
var current: ?*Call = null;

fn request_read(_: *ExecEnv, buffer: [*]u8, length: u32) callconv(.c) i32 {
    const call = current orelse return -1;
    const count = @min(length, call.request.len - call.read);
    @memcpy(buffer[0..count], call.request[call.read..][0..count]);
    call.read += count;
    return @intCast(count);
}

fn reply_write(_: *ExecEnv, bytes: [*]const u8, length: u32) callconv(.c) i32 {
    const call = current orelse return -1;
    if (length > call.reply.len - call.written) {
        call.overflow = true;
        return 1;
    }
    @memcpy(call.reply[call.written..][0..length], bytes[0..length]);
    call.written += length;
    return 0;
}

fn log(_: *ExecEnv, level: i32, bytes: [*]const u8, length: u32) callconv(.c) void {
    const name = if (current) |call| call.name else "wasm";
    const levels = [_][]const u8{ "error", "warn", "info", "debug" };
    const said = if (level >= 0 and level < levels.len) levels[@intCast(level)] else "info";
    std.debug.print("[{s}] {s}: {s}\n", .{ name, said, bytes[0..@min(length, 4096)] });
}

/// Registered once, kept by WAMR (which sorts it in place): the host functions of `abi`.
var natives = [_]NativeSymbol{
    .{ .symbol = "request_read", .function = &request_read, .signature = "(*~)i" },
    .{ .symbol = "reply_write", .function = &reply_write, .signature = "(*~)i" },
    .{ .symbol = "log", .function = &log, .signature = "(i*~)" },
};
var runtime_ready = false;

fn runtime_init() !void {
    if (runtime_ready) return;
    if (!wasm_runtime_init()) return error.WasmRuntime;
    if (!wasm_runtime_register_natives(abi, &natives, natives.len)) return error.WasmRuntime;
    runtime_ready = true;
}

pub const Plugin = struct {
    /// The module's bytes: WAMR's loader refers to them while the module lives.
    bytes: []u8,
    module: *Module,
    instance: *Instance,
    env: *ExecEnv,
    call_function: *Function,
    /// Its file's name, said beside what it logs.
    name: []const u8,
    /// Given after its path, sent with the hello (`"arguments"`): a module has no argv.
    arguments: []const []const u8,
    /// Calls that answered the defaults (a trap, its budget spent, its reply too large).
    failures: u64 = 0,

    /// Its answer to `request` (a JSON message), written into `reply`: the defaults when it
    /// trapped, spent its budget, returned nonzero or outgrew `reply`.
    pub fn call(plugin: *Plugin, request: []const u8, reply: []u8) []const u8 {
        assert(current == null);
        var state: Call = .{ .request = request, .reply = reply, .name = plugin.name };
        current = &state;
        defer current = null;
        wasm_runtime_set_instruction_count_limit(plugin.env, instructions_per_call_max);
        var argv = [1]u32{@intCast(request.len)};
        const ran = wasm_runtime_call_wasm(plugin.env, plugin.call_function, 1, &argv);
        if (ran and argv[0] == 0 and !state.overflow and state.written > 0) return reply[0..state.written];
        plugin.failures += 1;
        const why: []const u8 = if (!ran)
            std.mem.span(wasm_runtime_get_exception(plugin.instance) orelse "it trapped")
        else if (state.overflow)
            "its reply outgrew the reply's room"
        else if (argv[0] != 0)
            "it returned nonzero"
        else
            "it wrote no reply";
        std.debug.print("[determinismo] wasm plugin {s}: {s}; answered with the defaults ({d} so far)\n", .{
            plugin.name, why, plugin.failures,
        });
        wasm_runtime_clear_exception(plugin.instance);
        return "{}";
    }
};

/// `command` is `<module.wasm> [arguments]`, after the `wasm:` prefix.
pub fn load(arena: std.mem.Allocator, command: []const u8) !*Plugin {
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    const path = words.next() orelse return error.NoWasmModule;
    var arguments: std.ArrayList([]const u8) = .empty;
    while (words.next()) |word| try arguments.append(arena, word);
    try runtime_init();
    const bytes = try file_read(arena, path);
    var error_buffer: [error_size_max]u8 = @splat(0);
    const module = wasm_runtime_load(bytes.ptr, @intCast(bytes.len), &error_buffer, error_buffer.len) orelse {
        std.debug.print("[determinismo] wasm plugin {s}: {s}\n", .{ path, std.mem.sliceTo(&error_buffer, 0) });
        return error.WasmLoad;
    };
    const instance = wasm_runtime_instantiate(module, stack_size, 0, &error_buffer, error_buffer.len) orelse {
        std.debug.print("[determinismo] wasm plugin {s}: {s}\n", .{ path, std.mem.sliceTo(&error_buffer, 0) });
        return error.WasmInstantiate;
    };
    const call_function = wasm_runtime_lookup_function(instance, "det_call") orelse {
        std.debug.print("[determinismo] wasm plugin {s}: no det_call export (ABI {s})\n", .{ path, abi });
        return error.WasmNoEntry;
    };
    const env = wasm_runtime_create_exec_env(instance, stack_size) orelse return error.WasmRuntime;
    const plugin = try arena.create(Plugin);
    plugin.* = .{
        .bytes = bytes,
        .module = module,
        .instance = instance,
        .env = env,
        .call_function = call_function,
        .name = std.fs.path.basename(path),
        .arguments = arguments.items,
    };
    return plugin;
}

fn file_read(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const opened = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("[determinismo] wasm plugin {s}: cannot open it ({s})\n", .{ path, @tagName(linux.errno(opened)) });
        return error.WasmModuleMissing;
    }
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        try bytes.ensureUnusedCapacity(arena, 64 << 10);
        const room = bytes.unusedCapacitySlice();
        const result = linux.read(fd, room.ptr, room.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return error.WasmModuleUnreadable;
        if (result == 0) break;
        bytes.items.len += result;
        if (bytes.items.len > module_size_max) return error.WasmModuleTooLarge;
    }
    return bytes.items;
}
