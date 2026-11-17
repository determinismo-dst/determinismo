// SPDX-License-Identifier: MIT
//! Where a node's process ended on its own, with a nonzero status and no core: Go's os.Exit(1),
//! a C program's exit(1), a JVM's System.exit. Its `exit_stack` event names the code that asked,
//! as `crash_stack` does a crash's (cores.zig): an etcd spare that exits with status 1, saying
//! nothing, 6 ms after its promotion (run 2019, three timelines) left nothing to name its caller.
//!
//! The node's first process installs a seccomp filter before it becomes the node's program
//! (nodes.zig), inherited by every process of the node: exit_group with a nonzero status is
//! the only system call it holds (any other is allowed after its first four instructions). Its listener
//! goes to the node's output forwarder (output.zig), outside the node, which lives as long as
//! the node runs and answers each one: the process is held at its exit_group, whole, while the
//! instruction it called it from (the notification's), its stack pointer (/proc/<pid>/syscall)
//! and its stack's top (/proc/<pid>/mem) are read and named as a crash's are (where.zig); then
//! it goes on to exit. No frame pointer can be read from here: its callers are its stack's
//! words that point into code (scanned), as a crash's are where frame pointers do not chain.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const where = @import("where.zig");

const seccomp = linux.SECCOMP;
/// struct sock_filter (linux/filter.h).
const Instruction = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
/// struct sock_fprog.
const Program = extern struct { len: u16, filter: [*]const Instruction };

const ld_w_abs = 0x20; // BPF_LD | BPF_W | BPF_ABS
const jeq_k = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
const ret_k = 0x06; // BPF_RET | BPF_K
const audit_arch_x86_64 = 0xc000003e;
const exit_group_nr = 231;
/// struct seccomp_data: nr at 0, arch at 4, instruction_pointer at 8, args from 16 (the
/// status's low 32 bits at 16 on little endian: an int).
const data_nr = 0;
const data_arch = 4;
const data_arg0 = 16;

/// Allows all but exit_group with a nonzero status on x86-64, which it notifies.
const filter = [_]Instruction{
    .{ .code = ld_w_abs, .jt = 0, .jf = 0, .k = data_arch },
    .{ .code = jeq_k, .jt = 0, .jf = 4, .k = audit_arch_x86_64 },
    .{ .code = ld_w_abs, .jt = 0, .jf = 0, .k = data_nr },
    .{ .code = jeq_k, .jt = 0, .jf = 2, .k = exit_group_nr },
    .{ .code = ld_w_abs, .jt = 0, .jf = 0, .k = data_arg0 },
    .{ .code = jeq_k, .jt = 0, .jf = 1, .k = 0 },
    .{ .code = ret_k, .jt = 0, .jf = 0, .k = seccomp.RET.ALLOW },
    .{ .code = ret_k, .jt = 0, .jf = 0, .k = seccomp.RET.USER_NOTIF },
};

/// In the node's first process, root still (installing a filter without no_new_privs takes
/// CAP_SYS_ADMIN, and no_new_privs would end the node's setuid programs' privileges): the filter,
/// and its listener sent to the forwarder over `socket`, both closed here after.
pub fn filter_install(socket: linux.fd_t) !void {
    const program: Program = .{ .len = filter.len, .filter = &filter };
    const listener = linux.seccomp(seccomp.SET_MODE_FILTER, seccomp.FILTER_FLAG.NEW_LISTENER, &program);
    if (linux.errno(listener) != .SUCCESS) return error.Seccomp;
    defer _ = linux.close(@intCast(listener));
    try descriptor_send(socket, @intCast(listener));
    _ = linux.close(socket);
}

/// One notification answered: its process's exit named in an `exit_stack` event of `node`, its
/// JSON line written on `out` (true then), and the process let go to exit. The forwarder sends the
/// line through its own device: the SDK's (sdk.event) went with the descriptors it closed as it
/// started (output.zig's files_close_except). A process gone meanwhile has no answer to wait for.
pub fn answer(listener: linux.fd_t, node: []const u8, out: *std.Io.Writer) bool {
    var notification = std.mem.zeroes(seccomp.notif);
    if (linux.errno(linux.ioctl(listener, seccomp.IOCTL_NOTIF.RECV, @intFromPtr(&notification))) != .SUCCESS) return false;
    defer {
        var response: seccomp.notif_resp = .{ .id = notification.id, .val = 0, .@"error" = 0, .flags = seccomp.USER_NOTIF_FLAG_CONTINUE };
        _ = linux.ioctl(listener, seccomp.IOCTL_NOTIF.SEND, @intFromPtr(&response));
    }
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pid: linux.pid_t = @intCast(notification.pid);
    const status: i32 = @truncate(@as(i64, @bitCast(notification.data.arg0)));
    const rip = notification.data.instruction_pointer;
    const tgid = thread_group_of(arena, pid) orelse pid;
    // What could not be read is said, never left out: a capture that fails is a platform bug.
    const failed = struct {
        fn said(o: *std.Io.Writer, n: []const u8, p: linux.pid_t, s: i32, r: u64, why: []const u8) bool {
            std.json.Stringify.value(.{ .event = "exit_stack", .details = .{
                .node = n,
                .pid = p,
                .status = s,
                .rip = r,
                .@"error" = why,
            } }, .{}, o) catch return false;
            return true;
        }
    }.said;
    const stack_pointer = stack_pointer_of(arena, pid) orelse {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/syscall", .{pid}, 0) catch unreachable;
        const said = file_read(arena, path) orelse "(unreadable)";
        const why = std.fmt.allocPrint(arena, "its stack pointer unread: /proc/<pid>/syscall said \"{s}\"", .{std.mem.trim(u8, said[0..@min(said.len, 160)], " \n")}) catch "its stack pointer unread";
        return failed(out, node, tgid, status, rip, why);
    };
    // Still the process that asked (a PID read after its death could be another's).
    if (linux.errno(linux.ioctl(listener, seccomp.IOCTL_NOTIF.ID_VALID, @intFromPtr(&notification.id))) != .SUCCESS) {
        return failed(out, node, tgid, status, rip, "gone before its stack was read");
    }
    var path_buffer: [64]u8 = undefined;
    const memory_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{pid}, 0) catch unreachable;
    const memory = linux.open(memory_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(memory) != .SUCCESS) return failed(out, node, tgid, status, rip, @tagName(linux.errno(memory)));
    defer _ = linux.close(@intCast(memory));
    const process = where.Process.read(arena, tgid);
    defer process.release();
    const walked = where.live(arena, &process, @intCast(memory), rip, stack_pointer, null) orelse
        return failed(out, node, tgid, status, rip, "its stack unwalked");
    std.json.Stringify.value(.{ .event = "exit_stack", .details = .{
        .node = node,
        .process = name_of(arena, tgid),
        .pid = tgid,
        .tid = pid,
        .status = status,
        .rip = hex(arena, rip),
        .rsp = hex(arena, stack_pointer),
        .frames = walked.frames,
        .scanned = walked.scanned,
    } }, .{}, out) catch {
        out.end = 0;
        return failed(out, node, tgid, status, rip, "too long for one message");
    };
    return true;
}

/// The stack pointer of a thread blocked in a system call: /proc/<pid>/syscall's "nr args...
/// sp pc" (its next to last field).
/// The kernel queues the notification before the thread sleeps waiting for its answer: until it
/// sleeps, /proc/<pid>/syscall says "running" (task_current_syscall's -EAGAIN). It sleeps until
/// answered, so the read waits for that, a bounded number of yields.
const running_reads_max = 10_000;

fn stack_pointer_of(arena: std.mem.Allocator, pid: linux.pid_t) ?u64 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/syscall", .{pid}, 0) catch return null;
    var reads: u32 = 0;
    const text = while (true) : (reads += 1) {
        const read = file_read(arena, path) orelse return null;
        if (!std.mem.startsWith(u8, read, "running") or reads == running_reads_max) break read;
        _ = linux.sched_yield();
    };
    var fields: [9][]const u8 = undefined;
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    while (words.next()) |word| {
        if (count == fields.len) return null;
        fields[count] = word;
        count += 1;
    }
    if (count != fields.len) return null;
    const sp = fields[7];
    return std.fmt.parseInt(u64, if (std.mem.startsWith(u8, sp, "0x")) sp[2..] else sp, 16) catch null;
}

fn thread_group_of(arena: std.mem.Allocator, pid: linux.pid_t) ?linux.pid_t {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/status", .{pid}, 0) catch return null;
    const text = file_read(arena, path) orelse return null;
    const at = std.mem.indexOf(u8, text, "\nTgid:") orelse return null;
    const line = std.mem.sliceTo(text[at + "\nTgid:".len ..], '\n');
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, line, " \t"), 10) catch null;
}

fn name_of(arena: std.mem.Allocator, pid: linux.pid_t) []const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return "";
    return std.mem.trim(u8, file_read(arena, path) orelse return "", " \n");
}

fn hex(arena: std.mem.Allocator, value: u64) []const u8 {
    return std.fmt.allocPrint(arena, "0x{x}", .{value}) catch "";
}

fn file_read(arena: std.mem.Allocator, path: [:0]const u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const buffer = arena.alloc(u8, 4096) catch return null;
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

// The listener from the node's first process to its forwarder: a descriptor over a Unix socket
// (SCM_RIGHTS), one byte of data with it.

const scm_rights = 1;
/// struct cmsghdr (len, level, type) and one int of data, padded to the header's alignment.
const header_size = @sizeOf(usize) + 2 * @sizeOf(i32);
const control_size = header_size + @sizeOf(usize);

fn descriptor_send(socket: linux.fd_t, fd: linux.fd_t) !void {
    var control: [control_size]u8 align(@alignOf(usize)) = @splat(0);
    std.mem.writeInt(usize, control[0..@sizeOf(usize)], header_size + @sizeOf(i32), .little);
    std.mem.writeInt(i32, control[@sizeOf(usize)..][0..4], linux.SOL.SOCKET, .little);
    std.mem.writeInt(i32, control[@sizeOf(usize) + 4 ..][0..4], scm_rights, .little);
    std.mem.writeInt(i32, control[header_size..][0..4], fd, .little);
    const byte = [1]u8{1};
    var vector = [1]std.posix.iovec_const{.{ .base = &byte, .len = 1 }};
    const message = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const sent = linux.sendmsg(socket, &message, 0);
    if (linux.errno(sent) != .SUCCESS or sent != 1) return error.SendFailed;
}

/// The listener the node's first process sent: none when it closed its end without (it died
/// before its exec).
pub fn listener_receive(socket: linux.fd_t) ?linux.fd_t {
    var control: [control_size]u8 align(@alignOf(usize)) = @splat(0);
    var byte: [1]u8 = undefined;
    var vector = [1]std.posix.iovec{.{ .base = &byte, .len = 1 }};
    var message = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const received = linux.recvmsg(socket, &message, linux.MSG.CMSG_CLOEXEC);
    if (linux.errno(received) != .SUCCESS or received != 1) return null;
    if (message.controllen < header_size + @sizeOf(i32)) return null;
    const level = std.mem.readInt(i32, control[@sizeOf(usize)..][0..4], .little);
    const kind = std.mem.readInt(i32, control[@sizeOf(usize) + 4 ..][0..4], .little);
    if (level != linux.SOL.SOCKET or kind != scm_rights) return null;
    return std.mem.readInt(i32, control[header_size..][0..4], .little);
}

comptime {
    assert(filter.len < 16);
    assert(@sizeOf(Instruction) == 8);
}
