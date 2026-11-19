// SPDX-License-Identifier: MIT
//! Plugins as WebAssembly modules, run inside the explorer (`--strategy "wasm:<module.wasm>
//! [arguments]"`) as native code: each module compiled ahead of time by WAMR's compiler
//! (wamrc, once a module: cached by its content), loaded by WAMR's runtime compiled into the
//! explorer (build.zig's wamr_link), each hook a direct call, no process, pipe or ring. The messages are the other
//! transports' (docs/PLUGINS.md), so every hook a plugin can want is a wasm module's too.
//!
//! The module's side, the ABI `determinismo_1` (its imports' module name: a module built for
//! another major is refused at load):
//!
//!   export fn det_call(request_size: u32) i32      a request: 0 once its reply is written
//!   import request_read(buffer, length) i32        copies the request's next bytes; 0 at its end
//!   import reply_write(bytes, length) i32          appends to the reply; nonzero past its room
//!   import log(level, bytes, length)               a line on the explorer's standard error
//!   import http(request, length) i32               an HTTP request, described in JSON: the
//!                                                  response's size, read with response_read
//!   import response_read(buffer, length) i32      copies the response's next bytes; 0 at its end
//!
//! And WASI (wasi_snapshot_preview1) for a module that imports it: its arguments (its name, then
//! the ones after its path), the explorer's environment, the clocks, randomness, standard output
//! and error (the explorer's standard error), sockets, and two directories: `/run` (the
//! explorer's working directory: the run's) and `/state` (~/.local/share/determinismo/plugins/
//! <name>, kept across runs). What a module reads there or over the network is outside the
//! messages: replays need it no more than a program's (its answers are on the tapes).
//!
//! The host owns the request and the reply: a module needs no allocator of its own exported,
//! and reads a large request (a history) in parts.
//! A module declares shared memory (Zig: --shared-memory, with atomics; the Clojure client's
//! wasm-build does it): compiled so, its loops and calls check a terminate flag, which each
//! call's deadline sets (SIGALRM: src/wasm_interrupt.c). A module that loops past it, traps or
//! fails answers `{}` (the defaults), said on standard error; the explorer goes on.
//!
//! The module's memory is a plain mapping of the explorer's: it forks with it, a timeline's
//! process carrying the plugin's state as of its start. A module that imports nothing but the
//! messages' functions is a function of the messages it is sent.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const prefix = "wasm:";
/// The import module name a module's host functions come from: its ABI's major version.
pub const abi = "determinismo_1";
/// A module's file at most this large.
const module_size_max = 64 << 20;
/// One call's time at most, whole seconds (a decision's answer takes microseconds; a history's
/// check milliseconds): past it, the call is stopped and its answer is the defaults.
const deadline_seconds = 2;
/// How wamrc compiles a module: for any x86-64 host from 2009 on (srv4's Skylake, a Coffee
/// Lake), software bounds checks (the runtime has no guard pages), the terminate flag checked
/// (--enable-multi-thread: with shared memory, at every loop and call), no SIMD.
const wamrc_flags = [_][]const u8{
    "--target=x86_64",         "--cpu=x86-64-v2",       "--bounds-checks=1",
    "--stack-bounds-checks=1", "--enable-multi-thread", "--disable-simd",
};
/// The module's operand stack and its host-managed heap (none: it has its own memory).
const stack_size = 256 << 10;
/// The native stack a call may take below its caller's frame: WAMR checks it in software (no
/// guard pages, no signal handlers here). Set at each call: what it finds itself (musl's
/// pthread_getattr_np: the main thread's stack as mapped so far) put the boundary above the
/// frames a deeper caller had, every call from the setup's decisions a "native stack overflow".
/// The explorer's callers are its main thread's (8 MiB): room for this below any of them.
const native_stack_budget = 512 << 10;
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
extern fn det_wasm_interrupt(env: *ExecEnv) void;
extern fn det_wasm_interrupt_clear(env: *ExecEnv) void;
extern fn wasm_runtime_set_native_stack_boundary(env: *ExecEnv, boundary: [*]u8) void;
extern fn wasm_runtime_set_wasi_args_ex(
    module: *Module,
    directories: [*]const [*:0]const u8,
    directory_count: u32,
    mapped: [*]const [*:0]const u8,
    mapped_count: u32,
    environment: [*]const [*:0]const u8,
    environment_count: u32,
    argv: [*]const [*:0]const u8,
    argc: c_int,
    stdin: i64,
    stdout: i64,
    stderr: i64,
) void;
extern fn wasm_runtime_set_wasi_addr_pool(module: *Module, pool: [*]const [*:0]const u8, count: u32) void;
extern fn wasm_runtime_set_wasi_ns_lookup_pool(module: *Module, pool: [*]const [*:0]const u8, count: u32) void;

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

/// The last `http` call's response (JSON: its status and body, or its error), read in parts.
var response: std.ArrayList(u8) = .empty;
var response_at: usize = 0;
/// A response's body at most.
const response_size_max = 64 << 20;
/// One client a process (its root certificates read once); no connection is kept between
/// requests: a timeline's process forked from another never shares one.
var http_client: ?std.http.Client = null;

/// `request`: {"method": "GET", "url": "https://...", "headers": {"name": "value"}, "body":
/// "..."}. The response, read with response_read: {"status": 200, "body": "..."}, or
/// {"error": "..."}. Its size is the answer (-1 outside a call). The call's deadline waits
/// for it (a language model's answer takes seconds).
fn http(_: *ExecEnv, bytes: [*]const u8, length: u32) callconv(.c) i32 {
    if (current == null) return -1;
    const paused = deadline_pause();
    defer deadline_resume(paused);
    response.clearRetainingCapacity();
    response_at = 0;
    http_answer(bytes[0..length]) catch |err| {
        response.clearRetainingCapacity();
        response.print(std.heap.c_allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch return -1;
    };
    return @intCast(@min(response.items.len, std.math.maxInt(i32)));
}

fn http_answer(request: []const u8) !void {
    const gpa = std.heap.c_allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, request, .{});
    if (parsed != .object) return error.RequestNotAnObject;
    const url = parsed.object.get("url") orelse return error.RequestWithoutUrl;
    if (url != .string) return error.RequestWithoutUrl;
    const method_name = if (parsed.object.get("method")) |value| (if (value == .string) value.string else "GET") else "GET";
    const method = std.meta.stringToEnum(std.http.Method, method_name) orelse return error.UnknownMethod;
    const body: ?[]const u8 = if (parsed.object.get("body")) |value| (if (value == .string) value.string else null) else null;
    var headers: std.ArrayList(std.http.Header) = .empty;
    if (parsed.object.get("headers")) |value| if (value == .object) {
        var entries = value.object.iterator();
        while (entries.next()) |entry| if (entry.value_ptr.* == .string) {
            try headers.append(arena, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.string });
        };
    };
    if (http_client == null) http_client = .{ .allocator = gpa, .io = std.Io.Threaded.global_single_threaded.io() };
    var out: std.Io.Writer.Allocating = .init(arena);
    const result = try http_client.?.fetch(.{
        .location = .{ .url = url.string },
        .method = method,
        .payload = body,
        .extra_headers = headers.items,
        .keep_alive = false,
        .response_writer = &out.writer,
    });
    if (out.written().len > response_size_max) return error.ResponseTooLarge;
    try response.print(gpa, "{{\"status\":{d},\"body\":{f}}}", .{ @backingInt(result.status), std.json.fmt(out.written(), .{}) });
}

fn response_read(_: *ExecEnv, buffer: [*]u8, length: u32) callconv(.c) i32 {
    if (current == null) return -1;
    const count = @min(length, response.items.len - response_at);
    @memcpy(buffer[0..count], response.items[response_at..][0..count]);
    response_at += count;
    return @intCast(count);
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
    .{ .symbol = "http", .function = &http, .signature = "(*~)i" },
    .{ .symbol = "response_read", .function = &response_read, .signature = "(*~)i" },
};
var runtime_ready = false;

/// How far below runtime_init's frame the main thread's stack is mapped before WAMR measures it.
const stack_premap_size = 2 << 20;

/// The main thread's stack grown `stack_premap_size` below this frame, page by page from the top.
/// WAMR measures a thread's stack boundary once and keeps it (os_thread_get_stack_boundary), and
/// musl's pthread_getattr_np gives the main thread's stack as mapped so far: measured from the
/// explorer's first load, a worker instantiating its module from deeper frames (its start
/// function, shared memory's, checked against that boundary) failed with "native stack
/// overflow". The explorer's main thread has 8 MiB.
noinline fn stack_premap() void {
    var room: [stack_premap_size]u8 = undefined;
    var at: usize = room.len;
    while (at >= std.heap.page_size_min) {
        at -= std.heap.page_size_min;
        @as(*volatile u8, &room[at]).* = 0;
    }
}

fn runtime_init() !void {
    if (runtime_ready) return;
    stack_premap();
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
        deadline_arm(plugin.env);
        defer deadline_disarm(plugin.env);
        wasm_runtime_set_native_stack_boundary(plugin.env, @ptrFromInt(@frameAddress() - native_stack_budget));
        var argv = [1]u32{@intCast(request.len)};
        const ran = wasm_runtime_call_wasm(plugin.env, plugin.call_function, 1, &argv);
        const late = deadline_expired;
        if (ran and !late and argv[0] == 0 and !state.overflow and state.written > 0) return reply[0..state.written];
        plugin.failures += 1;
        const why: []const u8 = if (late)
            "past its deadline (" ++ std.fmt.comptimePrint("{d}", .{deadline_seconds}) ++ " s)"
        else if (!ran)
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
pub fn load(arena: std.mem.Allocator, command: []const u8, environ: [:null]const ?[*:0]const u8) !*Plugin {
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    const path = words.next() orelse return error.NoWasmModule;
    var arguments: std.ArrayList([]const u8) = .empty;
    while (words.next()) |word| try arguments.append(arena, word);
    try runtime_init();
    const wasm = try file_read(arena, path);
    if (!memory_shared(wasm)) {
        std.debug.print("[determinismo] wasm plugin {s}: its memory is not shared: build it with shared memory (Zig: --shared-memory with the atomics feature; the client's wasm-build does), so that its calls can be stopped at their deadline\n", .{path});
        return error.WasmMemoryNotShared;
    }
    const bytes = try compiled(arena, path, wasm, environ);
    var error_buffer: [error_size_max]u8 = @splat(0);
    const module = wasm_runtime_load(bytes.ptr, @intCast(bytes.len), &error_buffer, error_buffer.len) orelse {
        std.debug.print("[determinismo] wasm plugin {s}: {s}\n", .{ path, std.mem.sliceTo(&error_buffer, 0) });
        return error.WasmLoad;
    };
    const name = std.fs.path.basename(path);
    try wasi_set(arena, module, name, arguments.items, environ);
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
        .name = name,
        .arguments = arguments.items,
    };
    return plugin;
}

/// WASI's arguments, used if the module imports it: its name and arguments, the explorer's
/// environment, standard output to the explorer's standard error, `/run` and `/state`, any
/// address its sockets ask for.
fn wasi_set(
    arena: std.mem.Allocator,
    module: *Module,
    name: []const u8,
    arguments: []const []const u8,
    environ: [:null]const ?[*:0]const u8,
) !void {
    var cwd_buffer: [4096]u8 = undefined;
    const cwd_size = linux.getcwd(&cwd_buffer, cwd_buffer.len);
    if (linux.errno(cwd_size) != .SUCCESS) return error.WorkingDirectory;
    const cwd = std.mem.sliceTo(&cwd_buffer, 0);
    const home = environ_value(environ, "HOME") orelse "/tmp";
    const stem = if (std.mem.endsWith(u8, name, ".wasm")) name[0 .. name.len - ".wasm".len] else name;
    const state = try std.fmt.allocPrint(arena, "{s}/.local/share/determinismo/plugins/{s}", .{ home, stem });
    try directory_make(arena, state);
    const directories = try arena.alloc([*:0]const u8, 2);
    directories[0] = try arena.dupeSentinel(u8, cwd, 0);
    directories[1] = try arena.dupeSentinel(u8, state, 0);
    const mapped = try arena.alloc([*:0]const u8, 2);
    mapped[0] = try std.fmt.allocPrintSentinel(arena, "/run::{s}", .{cwd}, 0);
    mapped[1] = try std.fmt.allocPrintSentinel(arena, "/state::{s}", .{state}, 0);
    var environment: std.ArrayList([*:0]const u8) = .empty;
    for (environ) |entry| try environment.append(arena, entry orelse continue);
    const argv = try arena.alloc([*:0]const u8, arguments.len + 1);
    argv[0] = try arena.dupeSentinel(u8, stem, 0);
    for (arguments, argv[1..]) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const stdin = linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(stdin) != .SUCCESS) return error.DevNull;
    wasm_runtime_set_wasi_args_ex(module, directories.ptr, 2, mapped.ptr, 2, environment.items.ptr, @intCast(environment.items.len), argv.ptr, @intCast(argv.len), @intCast(stdin), 2, 2);
    const anywhere = [_][*:0]const u8{ "0.0.0.0/0", "::/0" };
    wasm_runtime_set_wasi_addr_pool(module, &anywhere, anywhere.len);
    const any_name = [_][*:0]const u8{"*"};
    wasm_runtime_set_wasi_ns_lookup_pool(module, &any_name, any_name.len);
}

/// The call in progress's environment, for the deadline's signal; and whether it fired.
var deadline_env: ?*ExecEnv = null;
var deadline_expired = false;
var deadline_handler_set = false;

fn on_deadline(_: linux.SIG) callconv(.c) void {
    deadline_expired = true;
    if (deadline_env) |env| det_wasm_interrupt(env);
}

/// SIGALRM in `deadline_seconds` (the kernel's itimerval: seconds and microseconds, the
/// microseconds left 0), the terminate flag set when it fires. Timers are not inherited across a
/// fork: each timeline's process arms its own.
fn deadline_arm(env: *ExecEnv) void {
    if (!deadline_handler_set) {
        const action: linux.Sigaction = .{ .handler = .{ .handler = on_deadline }, .mask = linux.sigemptyset(), .flags = linux.SA.RESTART };
        _ = linux.sigaction(linux.SIG.ALRM, &action, null);
        deadline_handler_set = true;
    }
    det_wasm_interrupt_clear(env);
    deadline_expired = false;
    deadline_env = env;
    const value: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = deadline_seconds, .nsec = 0 } };
    _ = linux.setitimer(@backingInt(linux.ITIMER.REAL), &value, null);
}

/// The deadline's time left, the timer stopped: a host function waiting on the network.
fn deadline_pause() linux.itimerspec {
    var left: linux.itimerspec = undefined;
    const off: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    _ = linux.setitimer(@backingInt(linux.ITIMER.REAL), &off, &left);
    return left;
}

/// The timer again with what was left (the kernel's own values, given back as they came).
fn deadline_resume(left: linux.itimerspec) void {
    if (left.it_value.sec == 0 and left.it_value.nsec == 0) return;
    _ = linux.setitimer(@backingInt(linux.ITIMER.REAL), &left, null);
}

fn deadline_disarm(env: *ExecEnv) void {
    const off: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    _ = linux.setitimer(@backingInt(linux.ITIMER.REAL), &off, null);
    deadline_env = null;
    det_wasm_interrupt_clear(env);
}

/// Whether a module's memory (defined or imported) is shared: its limits' flags bit 1.
fn memory_shared(wasm: []const u8) bool {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], "\x00asm")) return false;
    var at: usize = 8;
    while (at < wasm.len) {
        const id = wasm[at];
        at += 1;
        const size = leb(wasm, &at) orelse return false;
        const end = at + size;
        if (end > wasm.len) return false;
        if (id == 5) { // Memory: count, then each one's limits flags.
            var p = at;
            const count = leb(wasm, &p) orelse return false;
            return count > 0 and p < end and wasm[p] & 2 != 0;
        }
        if (id == 2) { // Imports: a memory import's limits flags.
            var p = at;
            const count = leb(wasm, &p) orelse return false;
            for (0..count) |_| {
                const module_size = leb(wasm, &p) orelse return false;
                p += module_size;
                const name_size = leb(wasm, &p) orelse return false;
                p += name_size;
                if (p >= end) return false;
                const kind = wasm[p];
                p += 1;
                switch (kind) {
                    0 => _ = leb(wasm, &p) orelse return false, // A function: its type.
                    1 => { // A table: its type, its limits.
                        p += 1;
                        const flags = wasm[p];
                        p += 1;
                        _ = leb(wasm, &p) orelse return false;
                        if (flags & 1 != 0) _ = leb(wasm, &p) orelse return false;
                    },
                    2 => return wasm[p] & 2 != 0, // A memory.
                    3 => p += 2, // A global: its type and mutability.
                    else => return false,
                }
            }
        }
        at = end;
    }
    return false;
}

fn leb(bytes: []const u8, at: *usize) ?usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (at.* < bytes.len) {
        const byte = bytes[at.*];
        at.* += 1;
        result |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift >= 56) return null;
        shift += 7;
    }
    return null;
}

/// The module compiled to native code by wamrc, once: cached by the module's content and the
/// flags, under $HOME/.cache/determinismo/wasm (written whole, then renamed: workers compiling
/// the same module at once agree). wamrc: $DETERMINISMO_WAMRC, else ~/opt/wamrc/wamrc (the
/// host's tools: infra/host/tools.sh; serve's runs have a fixed PATH), else on PATH.
fn compiled(arena: std.mem.Allocator, path: []const u8, wasm: []const u8, environ: [:null]const ?[*:0]const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(wasm);
    for (wamrc_flags) |flag| hasher.update(flag);
    const home = environ_value(environ, "HOME") orelse "/tmp";
    const directory = try std.fmt.allocPrint(arena, "{s}/.cache/determinismo/wasm", .{home});
    try directory_make(arena, directory);
    const aot = try std.fmt.allocPrint(arena, "{s}/{x:0>16}.aot", .{ directory, hasher.final() });
    const aot_z = try arena.dupeSentinel(u8, aot, 0);
    if (linux.errno(linux.access(aot_z, linux.R_OK)) == .SUCCESS) return aligned(arena, try file_read(arena, aot));
    const tools = try std.fmt.allocPrintSentinel(arena, "{s}/opt/wamrc/wamrc", .{home}, 0);
    const tools_wamrc: ?[]const u8 = if (linux.errno(linux.access(tools, linux.X_OK)) == .SUCCESS) tools else null;
    const wamrc = environ_value(environ, "DETERMINISMO_WAMRC") orelse tools_wamrc orelse try path_find(arena, "wamrc", environ) orelse {
        std.debug.print("[determinismo] wasm plugin {s}: no wamrc (WAMR's compiler: $DETERMINISMO_WAMRC, ~/opt/wamrc/wamrc or on PATH; infra/host/tools.sh installs it): it compiles a module before it runs\n", .{path});
        return error.WamrcMissing;
    };
    const wasm_copy = try std.fmt.allocPrint(arena, "{s}.{d}.wasm", .{ aot, linux.getpid() });
    const output = try std.fmt.allocPrint(arena, "{s}.{d}", .{ aot, linux.getpid() });
    const wasm_copy_z = try arena.dupeSentinel(u8, wasm_copy, 0);
    try file_write(arena, wasm_copy, wasm);
    defer _ = linux.unlink(wasm_copy_z);
    var argv: [wamrc_flags.len + 5:null]?[*:0]const u8 = @splat(null);
    argv[0] = try arena.dupeSentinel(u8, wamrc, 0);
    for (wamrc_flags, 1..) |flag, index| argv[index] = try arena.dupeSentinel(u8, flag, 0);
    argv[wamrc_flags.len + 1] = "-o";
    argv[wamrc_flags.len + 2] = try arena.dupeSentinel(u8, output, 0);
    argv[wamrc_flags.len + 3] = wasm_copy_z;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        _ = linux.dup2(2, 1); // Its words on standard error, as the explorer's own.
        _ = linux.execve(argv[0].?, &argv, environ.ptr);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    while (true) {
        const waited = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(waited) != .INTR) break;
    }
    if (status != 0) {
        std.debug.print("[determinismo] wasm plugin {s}: wamrc could not compile it (status {d})\n", .{ path, status });
        return error.WasmCompile;
    }
    const output_z = try arena.dupeSentinel(u8, output, 0);
    if (linux.errno(linux.rename(output_z, aot_z)) != .SUCCESS) return error.WasmCompile;
    std.debug.print("[determinismo] wasm plugin {s}: compiled to native code ({s})\n", .{ path, aot });
    return aligned(arena, try file_read(arena, aot));
}

/// A compiled module's bytes where WAMR's loader reads them: it aligns its cursor to each word
/// it reads (read_uint32), so from a buffer at an odd address the magic number is read past
/// (the explorer's arena gives bytes at any address: "magic header not detected").
fn aligned(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const copy = try arena.alignedAlloc(u8, .@"16", bytes.len);
    @memcpy(copy, bytes);
    return copy;
}

fn environ_value(environ: [:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    for (environ) |entry| {
        const text = std.mem.span(entry orelse continue);
        if (text.len > name.len and std.mem.startsWith(u8, text, name) and text[name.len] == '=') return text[name.len + 1 ..];
    }
    return null;
}

fn path_find(arena: std.mem.Allocator, name: []const u8, environ: [:null]const ?[*:0]const u8) !?[]const u8 {
    var directories = std.mem.tokenizeScalar(u8, environ_value(environ, "PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (directories.next()) |directory| {
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, name }, 0);
        if (linux.errno(linux.access(candidate, linux.X_OK)) == .SUCCESS) return candidate;
    }
    return null;
}

fn directory_make(arena: std.mem.Allocator, directory: []const u8) !void {
    var at: usize = 1;
    while (at <= directory.len) : (at += 1) {
        if (at < directory.len and directory[at] != '/') continue;
        const part = try arena.dupeSentinel(u8, directory[0..at], 0);
        const made = linux.mkdir(part, 0o755);
        if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return error.CacheDirectory;
    }
}

fn file_write(arena: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const opened = linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.CacheWrite;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return error.CacheWrite;
        written += result;
    }
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

test "a module's memory is shared only when its limits say so, defined or imported" {
    // A memory section: one memory, its limits' flags (bit 1 shared), least and most pages.
    const defined_shared = "\x00asm\x01\x00\x00\x00" ++ "\x05\x04\x01\x03\x01\x02";
    const defined_plain = "\x00asm\x01\x00\x00\x00" ++ "\x05\x04\x01\x01\x01\x02";
    // An import section: "m" "f" a function (type 0), then "m" "mem" a shared memory.
    const imported_shared = "\x00asm\x01\x00\x00\x00" ++
        "\x02\x10\x02" ++ "\x01m\x01f\x00\x00" ++ "\x01m\x03mem\x02\x03\x01\x02";
    try std.testing.expect(memory_shared(defined_shared));
    try std.testing.expect(!memory_shared(defined_plain));
    try std.testing.expect(memory_shared(imported_shared));
    try std.testing.expect(!memory_shared("\x00asm\x01\x00\x00\x00"));
    try std.testing.expect(!memory_shared("not a module"));
    // Cut short anywhere: never past its end.
    for (0..defined_shared.len) |length| _ = memory_shared(defined_shared[0..length]);
    for (0..imported_shared.len) |length| _ = memory_shared(imported_shared[0..length]);
}
