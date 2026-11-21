// SPDX-License-Identifier: MIT
//! det-nodes hold <node> <function> [--caller <function>] [--arg <register>=<value>]
//! [--pid <pid>] [--timeout-ms <ms>]: holds the first thread of a node's process that enters
//! `function`, at its first instruction, while the process's other threads run on, until this
//! command is told to let it go (SIGTERM or SIGINT). A race inside a process made to happen: a
//! scenario holds the thread that would write first and lets it go once the other has written
//! (a spec's step that is an interleaving, caused rather than waited for).
//!
//! `--caller`: only a thread with a return address in that function on its stack (the entry's
//! own caller, then up the frame pointers' chain: Go keeps frame pointers on amd64, as C built
//! with them does). `--arg`: only a thread whose register has that value at the entry (Go's
//! ABIInternal: rax, rbx, rcx, rdi, rsi, r8 to r11 in order, a method's receiver first; the
//! System V ABI: rdi, rsi, rdx, rcx, r8, r9). Other entries step over the breakpoint and go on.
//!
//! It prints `{"armed":<pid>,...}` once its breakpoint is in (a caller may then go on), then
//! `{"held":<tid>,...}` once it holds one, `{"released":<tid>}` as it lets it go, and
//! `{"held":null}` (exit 1) when none came within the timeout (10 s of virtual time by default,
//! in whole seconds). The process's threads are seized (ptrace, new ones followed), the entry's
//! first byte a software breakpoint (int3) written through /proc/<pid>/mem; at the end every
//! thread is stopped, the byte restored and each thread detached. Deterministic as the guest is.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const nodes = @import("nodes.zig");
const symbol = @import("symbol.zig");

const ptrace_cont = 7;
const ptrace_singlestep = 9;
const ptrace_getregs = 12;
const ptrace_setregs = 13;
const ptrace_detach = 17;
const ptrace_seize = 0x4206;
const ptrace_interrupt = 0x4207;
const ptrace_o_traceclone = 0x8;
const ptrace_event_clone = 3;
const ptrace_event_stop = 128;
const wait_all = 0x40000000; // __WALL: threads too.
const signal_trap = 5;
const int3: u8 = 0xcc;
const processes_max = 1024;
const threads_max = 1024;
const frames_max = 32;

/// struct user_regs_struct: 27 registers.
const Regs = [27]u64;
const rbp_index = 4;
const rip_index = 16;
const rsp_index = 19;

/// The registers `--arg` names, by their index in user_regs_struct.
const register_names = [_]struct { name: []const u8, index: u8 }{
    .{ .name = "r15", .index = 0 },  .{ .name = "r14", .index = 1 },  .{ .name = "r13", .index = 2 },
    .{ .name = "r12", .index = 3 },  .{ .name = "rbp", .index = 4 },  .{ .name = "rbx", .index = 5 },
    .{ .name = "r11", .index = 6 },  .{ .name = "r10", .index = 7 },  .{ .name = "r9", .index = 8 },
    .{ .name = "r8", .index = 9 },   .{ .name = "rax", .index = 10 }, .{ .name = "rcx", .index = 11 },
    .{ .name = "rdx", .index = 12 }, .{ .name = "rsi", .index = 13 }, .{ .name = "rdi", .index = 14 },
};

pub const Arg = struct { index: u8, value: u64 };

pub const Options = struct {
    node: []const u8,
    function: []const u8,
    caller: ?[]const u8 = null,
    arg: ?Arg = null,
    pid: ?linux.pid_t = null,
    timeout_ms: u64 = 10_000,
};

pub fn parse(node: []const u8, function: []const u8, rest: []const []const u8) !Options {
    var options: Options = .{ .node = node, .function = function };
    var option = rest;
    while (option.len > 0) {
        if (option.len < 2) return error.Usage;
        const name = option[0];
        const value = option[1];
        if (std.mem.eql(u8, name, "--caller")) {
            options.caller = value;
        } else if (std.mem.eql(u8, name, "--arg")) {
            options.arg = try arg_parse(value);
        } else if (std.mem.eql(u8, name, "--pid")) {
            options.pid = try std.fmt.parseInt(linux.pid_t, value, 10);
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            options.timeout_ms = try std.fmt.parseInt(u64, value, 10);
        } else return error.Usage;
        option = option[2..];
    }
    return options;
}

/// `<register>=<value>`, the value decimal or 0x-hexadecimal.
fn arg_parse(text: []const u8) !Arg {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.Usage;
    const index = register_index(text[0..equals]) orelse return error.UnknownRegister;
    return .{ .index = index, .value = try std.fmt.parseInt(u64, text[equals + 1 ..], 0) };
}

fn register_index(name: []const u8) ?u8 {
    for (register_names) |register| {
        if (std.mem.eql(u8, register.name, name)) return register.index;
    }
    return null;
}

/// Whether `address` is a return address into [start, end): a call's return address is just
/// after it, so the function's last byte's call returns to its end.
fn returns_into(address: u64, start: u64, end: u64) bool {
    return address > start and address <= end;
}

var release_asked: std.atomic.Value(bool) = .init(false);
var timed_out: std.atomic.Value(bool) = .init(false);

fn on_release(_: linux.SIG) callconv(.c) void {
    release_asked.store(true, .release);
}

fn on_alarm(_: linux.SIG) callconv(.c) void {
    timed_out.store(true, .release);
}

const Hold = struct {
    pid: linux.pid_t,
    entry: u64,
    caller: ?[2]u64,
    arg: ?Arg,
    memory: linux.fd_t,
    original: u8,
    inserted: bool = false,
    held: ?linux.pid_t = null,
    tids: [threads_max]linux.pid_t = undefined,
    count: u32 = 0,

    fn track(hold: *Hold, tid: linux.pid_t) void {
        for (hold.tids[0..hold.count]) |known| if (known == tid) return;
        if (hold.count == threads_max) return;
        hold.tids[hold.count] = tid;
        hold.count += 1;
    }

    fn forget(hold: *Hold, tid: linux.pid_t) void {
        for (hold.tids[0..hold.count], 0..) |known, index| {
            if (known != tid) continue;
            hold.tids[index] = hold.tids[hold.count - 1];
            hold.count -= 1;
            return;
        }
    }

    fn byte_write(hold: *Hold, byte: u8) bool {
        const bytes = [1]u8{byte};
        const result = linux.pwrite(hold.memory, &bytes, 1, @bitCast(hold.entry));
        return linux.errno(result) == .SUCCESS and result == 1;
    }

    fn word_read(hold: *const Hold, address: u64) ?u64 {
        var word: u64 = undefined;
        const bytes = std.mem.asBytes(&word);
        const read = linux.pread(hold.memory, bytes, bytes.len, @bitCast(address));
        if (linux.errno(read) != .SUCCESS or read != bytes.len) return null;
        return word;
    }

    /// Whether a thread at the entry is one to hold: its argument register, then a return
    /// address into the caller on its stack ([rsp] at the entry, then the frame pointers').
    fn matches(hold: *const Hold, regs: *const Regs) bool {
        if (hold.arg) |arg| {
            if (regs[arg.index] != arg.value) return false;
        }
        const range = hold.caller orelse return true;
        const first = hold.word_read(regs[rsp_index]) orelse return false;
        if (returns_into(first, range[0], range[1])) return true;
        var frame = regs[rbp_index];
        for (0..frames_max) |_| {
            if (frame == 0) return false;
            const returned = hold.word_read(frame + 8) orelse return false;
            if (returns_into(returned, range[0], range[1])) return true;
            const next = hold.word_read(frame) orelse return false;
            if (next <= frame) return false; // Stacks grow down: callers' frames are higher.
            frame = next;
        }
        return false;
    }

    /// A thread stopped at the breakpoint (its rip just after the int3): back to the entry, then
    /// held, or stepped over the restored instruction and the breakpoint put back.
    fn hit(hold: *Hold, tid: linux.pid_t, regs: *Regs) void {
        regs[rip_index] = hold.entry;
        _ = linux.ptrace(ptrace_setregs, tid, 0, @intFromPtr(regs), 0);
        if (hold.held == null and hold.matches(regs)) {
            hold.held = tid;
            if (hold.byte_write(hold.original)) hold.inserted = false;
            out("{{\"held\":{d},\"pid\":{d},\"entry\":{d}}}\n", .{ tid, hold.pid, hold.entry });
            return; // Left stopped.
        }
        _ = hold.byte_write(hold.original);
        var signal: usize = 0;
        while (true) {
            if (linux.errno(linux.ptrace(ptrace_singlestep, tid, 0, signal, 0)) != .SUCCESS) return;
            var status: i32 = 0;
            const result = linux.wait4(tid, &status, wait_all, null);
            if (linux.errno(result) != .SUCCESS) return;
            if (!linux.W.IFSTOPPED(@bitCast(status))) {
                hold.forget(tid);
                break;
            }
            const stop: u32 = @intFromEnum(linux.W.STOPSIG(@bitCast(status)));
            if (stop == signal_trap) break;
            signal = stop; // A signal came first: given with the step.
        }
        if (hold.held == null and hold.byte_write(int3)) hold.inserted = true;
        _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
    }

    /// Every thread stopped, the entry's byte back, each detached: the held one goes on from the
    /// entry with the process.
    fn finish(hold: *Hold) void {
        for (hold.tids[0..hold.count]) |tid| {
            if (hold.held != null and tid == hold.held.?) continue;
            if (linux.errno(linux.ptrace(ptrace_interrupt, tid, 0, 0, 0)) != .SUCCESS) continue;
            var status: i32 = 0;
            if (linux.errno(linux.wait4(tid, &status, wait_all, null)) != .SUCCESS) continue;
            if (!linux.W.IFSTOPPED(@bitCast(status))) continue;
            var regs: Regs = undefined;
            if (linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) != .SUCCESS) continue;
            if (hold.inserted and regs[rip_index] == hold.entry + 1) {
                regs[rip_index] = hold.entry;
                _ = linux.ptrace(ptrace_setregs, tid, 0, @intFromPtr(&regs), 0);
            }
        }
        if (hold.inserted and hold.byte_write(hold.original)) hold.inserted = false;
        for (hold.tids[0..hold.count]) |tid| _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
    }
};

fn out(comptime format: []const u8, arguments: anytype) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, arguments) catch return;
    var written: usize = 0;
    while (written < text.len) {
        const result = linux.write(1, text[written..].ptr, text.len - written);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        written += result;
    }
}

pub fn run(arena: std.mem.Allocator, options: Options) !u8 {
    var pids_buffer: [processes_max]linux.pid_t = undefined;
    const pids = if (options.pid) |pid| blk: {
        pids_buffer[0] = pid;
        break :blk pids_buffer[0..1];
    } else pids_buffer[0..try nodes.processes(options.node, &pids_buffer)];
    var found: ?symbol.Found = null;
    for (pids) |pid| {
        found = symbol.find(arena, pid, options.function, null) catch null;
        if (found != null) break;
    }
    const target = found orelse return error.UnknownFunction;
    var caller: ?[2]u64 = null;
    if (options.caller) |name| {
        const site = (symbol.find(arena, target.pid, name, null) catch null) orelse return error.UnknownCaller;
        caller = .{ site.address, site.address + site.size };
    }
    var path_buffer: [48]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{target.pid}, 0) catch unreachable;
    const fd = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Memory;
    var hold: Hold = .{
        .pid = target.pid,
        .entry = target.address,
        .caller = caller,
        .arg = options.arg,
        .memory = @intCast(fd),
        .original = 0,
    };
    defer _ = linux.close(hold.memory);
    var original: [1]u8 = undefined;
    if (linux.pread(hold.memory, &original, 1, @bitCast(hold.entry)) != 1) return error.Memory;
    hold.original = original[0];
    assert(hold.original != int3);

    // Seized, each stopped, before the breakpoint goes in.
    var tids: [threads_max]linux.pid_t = undefined;
    const threads = nodes.threads(target.pid, &tids);
    for (tids[0..threads]) |tid| {
        if (linux.errno(linux.ptrace(ptrace_seize, tid, 0, ptrace_o_traceclone, 0)) != .SUCCESS) continue;
        if (linux.errno(linux.ptrace(ptrace_interrupt, tid, 0, 0, 0)) != .SUCCESS) continue;
        var status: i32 = 0;
        _ = linux.wait4(tid, &status, wait_all, null);
        hold.track(tid);
    }
    if (hold.count == 0) return error.Ptrace;
    const release_action = linux.Sigaction{
        .handler = .{ .handler = on_release },
        .mask = linux.sigemptyset(),
        .flags = 0, // No SA_RESTART: the wait returns on a signal.
    };
    _ = linux.sigaction(.TERM, &release_action, null);
    _ = linux.sigaction(.INT, &release_action, null);
    const alarm_action = linux.Sigaction{ .handler = .{ .handler = on_alarm }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.ALRM, &alarm_action, null);
    _ = linux.syscall1(.alarm, @max(1, (options.timeout_ms + 999) / 1000));
    if (hold.byte_write(int3)) hold.inserted = true;
    for (hold.tids[0..hold.count]) |tid| _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
    out("{{\"armed\":{d},\"threads\":{d},\"breakpoint\":{}}}\n", .{ hold.pid, hold.count, hold.inserted });

    while (!release_asked.load(.acquire)) {
        if (timed_out.load(.acquire) and hold.held == null) break;
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, wait_all, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) break; // No tracee left.
        const tid: linux.pid_t = @intCast(result);
        const word: u32 = @bitCast(status);
        if (!linux.W.IFSTOPPED(word)) {
            hold.forget(tid);
            if (hold.held != null and hold.held.? == tid) hold.held = null;
            continue;
        }
        hold.track(tid);
        const stop: u32 = @intFromEnum(linux.W.STOPSIG(word));
        const event = word >> 16;
        if (event == ptrace_event_clone or event == ptrace_event_stop) {
            _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
            continue;
        }
        if (stop == signal_trap and event == 0) {
            var regs: Regs = undefined;
            if (linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) == .SUCCESS and
                regs[rip_index] == hold.entry + 1)
            {
                if (hold.inserted) {
                    hold.hit(tid, &regs);
                } else {
                    // It reached the int3 before the byte went back (one thread held meanwhile):
                    // back to the entry, the trap never given to the process.
                    regs[rip_index] = hold.entry;
                    _ = linux.ptrace(ptrace_setregs, tid, 0, @intFromPtr(&regs), 0);
                    _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
                }
                continue;
            }
        }
        _ = linux.ptrace(ptrace_cont, tid, 0, stop, 0); // Its signal given back.
    }
    const held = hold.held;
    hold.finish();
    if (held) |tid| {
        out("{{\"released\":{d}}}\n", .{tid});
        return 0;
    }
    out("{{\"held\":null}}\n", .{});
    return 1;
}

test returns_into {
    try std.testing.expect(returns_into(0x1010, 0x1000, 0x1100));
    try std.testing.expect(returns_into(0x1100, 0x1000, 0x1100)); // A call as the last instruction.
    try std.testing.expect(!returns_into(0x1000, 0x1000, 0x1100)); // Its entry is no return address.
    try std.testing.expect(!returns_into(0x1101, 0x1000, 0x1100));
}

test parse {
    const options = try parse("raft-node-1", "f", &.{ "--caller", "g", "--arg", "rbx=0x18", "--timeout-ms", "2500" });
    try std.testing.expectEqualStrings("g", options.caller.?);
    try std.testing.expectEqual(@as(u8, 5), options.arg.?.index);
    try std.testing.expectEqual(@as(u64, 24), options.arg.?.value);
    try std.testing.expectEqual(@as(u64, 2500), options.timeout_ms);
    try std.testing.expectError(error.UnknownRegister, parse("n", "f", &.{ "--arg", "xmm0=1" }));
    try std.testing.expectError(error.Usage, parse("n", "f", &.{"--caller"}));
}
