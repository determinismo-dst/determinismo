// SPDX-License-Identifier: MIT
//! det-runner: the runner's commands for programs in nodes (libdeterminismo's det_runner, from
//! any language: a Clojure program, its REPL). A program in a node sees only its node; the
//! runner sees them all (det-nodes: start, stop, kill, crash, pause, exec; the network, the
//! disks). Each request is one connection to a Unix socket in the records tmpfs every node
//! mounts (schema.runner_socket): a JSON line {"argv": [...], "stdin"?: "..."} in, the command
//! run here, a JSON line {"status", "stdout", "stderr", "truncated"} back. What a platform
//! mechanic made in another language is built from: its choices drawn from the platform's
//! decisions, its effects these commands, each one a `runner_request` event.
//!
//! Sessions, for what outlives one request (det-nodes hold: armed, a thread held, released):
//! {"argv": [...], "session": "open"} starts the command and answers {"session": <id>} at once;
//! {"session": "read", "id": N, "wait_ms"?: W} its next line of output ({"line": "..."}, null at
//! its end; with wait_ms, {"line": null, "timeout": true} when none began within W ms);
//! {"session": "write", "id": N, "input"?: "...", "signal"?: "USR1|TERM|INT|KILL"} writes to its
//! input and signals it ({"ok": true}); {"session": "close", "id": N, "signal"?: ...} signals it
//! (TERM by default) and forgets it. This process opens and closes them (their commands its
//! children, their pipes its own); a read or a write is a handler's, which inherits the pipes.
//!
//! Started by det-init with the guest's other services; asleep in accept() unless asked.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const schema = sdk.schema;

const request_size_max = 64 << 10;
/// Each of a command's outputs kept up to this; the rest is read and dropped (`truncated`).
const output_size_max = 4 << 20;
const argv_count_max = 64;
/// Reads after a command's exit, at most: what it wrote before it, not what lives on after it.
const drains_max = 64;
const path_size_max = 4096;

const environment = [_:null]?[*:0]const u8{
    "PATH=/opt/determinismo/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
};

const Request = struct {
    argv: []const []const u8 = &.{},
    stdin: []const u8 = "",
    session: ?[]const u8 = null,
    id: ?u32 = null,
    input: ?[]const u8 = null,
    signal: ?[]const u8 = null,
    wait_ms: ?u32 = null,
};

const sessions_max = 32;
const Session = struct { pid: linux.pid_t, input: linux.fd_t, output: linux.fd_t };
var sessions: [sessions_max]?Session = @splat(null);

pub fn main(init: std.process.Init) !void {
    _ = init;
    const listener = try listen(schema.runner_socket);
    // Handlers reaped as they end (each resets this for the command it waits for).
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.CHLD, &ignore, null);
    while (true) {
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(accepted)) {
            .SUCCESS => {},
            .INTR, .CONNABORTED => continue,
            else => return error.AcceptFailed,
        }
        const connection: linux.fd_t = @intCast(accepted);
        // The request read here: a session's open and close are this process's own.
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const line = request_read(arena, connection) catch {
            _ = linux.close(connection);
            continue;
        };
        const request = std.json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch null;
        if (request) |asked| if (asked.session) |op| {
            if (std.mem.eql(u8, op, "open") or std.mem.eql(u8, op, "close")) {
                session_main(arena, connection, asked, op) catch |err| std.debug.print("[det-runner] a session: {t}\n", .{err});
                _ = linux.close(connection);
                continue;
            }
        };
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) {
            _ = linux.close(connection);
            continue;
        }
        if (pid == 0) {
            _ = linux.close(listener);
            const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
            _ = linux.sigaction(linux.SIG.CHLD, &default, null);
            handle(arena, connection, request) catch |err| std.debug.print("[det-runner] a request: {t}\n", .{err});
            linux.exit_group(0);
        }
        _ = linux.close(connection);
    }
}

fn listen(path: [:0]const u8) !linux.fd_t {
    const socket = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    assert(path.len < address.path.len);
    @memcpy(address.path[0..path.len], path);
    _ = linux.unlink(path);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn handle(arena: std.mem.Allocator, connection: linux.fd_t, parsed: ?Request) !void {
    const request = parsed orelse {
        return reply_write(arena, connection, .{ .status = 2, .stdout = "", .stderr = "det-runner: not a request: {\"argv\": [...], \"stdin\"?: \"...\"}", .truncated = false });
    };
    if (request.session) |op| return session_handler(arena, connection, request, op);
    if (request.argv.len == 0 or request.argv.len > argv_count_max) {
        return reply_write(arena, connection, .{ .status = 2, .stdout = "", .stderr = "det-runner: argv: 1 to 64 words", .truncated = false });
    }
    const result = try command_run(arena, request);
    sdk.event("runner_request", .{ .argv = request.argv, .status = result.status });
    try reply_write(arena, connection, result);
}

/// A session opened or closed (this process's: its commands are its children, their pipes kept
/// here for the handlers that inherit them).
fn session_main(arena: std.mem.Allocator, connection: linux.fd_t, request: Request, op: []const u8) !void {
    if (std.mem.eql(u8, op, "close")) {
        const id = request.id orelse return text_write(arena, connection, "{{\"error\":\"no id\"}}", .{});
        if (id >= sessions_max or sessions[id] == null) return text_write(arena, connection, "{{\"error\":\"no session {d}\"}}", .{id});
        const session = sessions[id].?;
        sessions[id] = null;
        _ = linux.kill(session.pid, signal_of(request.signal) orelse .TERM);
        _ = linux.close(session.input);
        _ = linux.close(session.output);
        sdk.event("runner_session", .{ .op = "close", .id = id });
        return text_write(arena, connection, "{{\"ok\":true}}", .{});
    }
    if (request.argv.len == 0 or request.argv.len > argv_count_max) return text_write(arena, connection, "{{\"error\":\"argv: 1 to 64 words\"}}", .{});
    const slot = for (&sessions, 0..) |*slot, index| {
        if (slot.* == null) break index;
    } else return text_write(arena, connection, "{{\"error\":\"{d} sessions open\"}}", .{sessions_max});
    const path = try executable_find(arena, request.argv[0]) orelse return text_write(arena, connection, "{{\"error\":\"not found\"}}", .{});
    var argv: [argv_count_max:null]?[*:0]const u8 = @splat(null);
    argv[0] = path;
    for (request.argv[1..], 1..) |word, index| argv[index] = try arena.dupeSentinel(u8, word, 0);
    var input: [2]i32 = undefined;
    var output: [2]i32 = undefined;
    for ([_]*[2]i32{ &input, &output }) |pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.dup2(input[0], 0);
        _ = linux.dup2(output[1], 1);
        _ = linux.execve(path, &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(input[0]);
    _ = linux.close(output[1]);
    sessions[slot] = .{ .pid = @intCast(pid), .input = input[1], .output = output[0] };
    sdk.event("runner_session", .{ .op = "open", .id = slot, .argv = request.argv });
    return text_write(arena, connection, "{{\"session\":{d}}}", .{slot});
}

/// A session's read (its next line of output) or write (to its input, and a signal): a
/// handler's, the pipes inherited.
fn session_handler(arena: std.mem.Allocator, connection: linux.fd_t, request: Request, op: []const u8) !void {
    const id = request.id orelse return text_write(arena, connection, "{{\"error\":\"no id\"}}", .{});
    if (id >= sessions_max or sessions[id] == null) return text_write(arena, connection, "{{\"error\":\"no session {d}\"}}", .{id});
    const session = sessions[id].?;
    if (std.mem.eql(u8, op, "read")) {
        // A line not begun within wait_ms: a timeout, nothing read (a line, once begun, is read
        // whole: det-nodes hold writes each at once).
        if (request.wait_ms) |wait_ms| {
            var ready = [1]linux.pollfd{.{ .fd = session.output, .events = linux.POLL.IN, .revents = 0 }};
            while (true) {
                const polled = linux.poll(&ready, 1, @intCast(@min(wait_ms, std.math.maxInt(i32))));
                if (linux.errno(polled) == .INTR) continue;
                if (linux.errno(polled) == .SUCCESS and polled == 0) {
                    return text_write(arena, connection, "{{\"line\":null,\"timeout\":true}}", .{});
                }
                break;
            }
        }
        var line: std.ArrayList(u8) = .empty;
        var ended = true;
        while (line.items.len < output_size_max) {
            var byte: [1]u8 = undefined;
            const result = linux.read(session.output, &byte, 1);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            if (byte[0] == '\n') {
                ended = false;
                break;
            }
            try line.append(arena, byte[0]);
        }
        if (ended and line.items.len == 0) return text_write(arena, connection, "{{\"line\":null}}", .{});
        return text_write(arena, connection, "{{\"line\":{f}}}", .{std.json.fmt(try utf8_valid(arena, line.items), .{})});
    }
    if (std.mem.eql(u8, op, "write")) {
        if (request.input) |input| write_all(session.input, input) catch {};
        if (signal_of(request.signal)) |signal| _ = linux.kill(session.pid, signal);
        return text_write(arena, connection, "{{\"ok\":true}}", .{});
    }
    return text_write(arena, connection, "{{\"error\":\"session: open, read, write or close\"}}", .{});
}

fn signal_of(name: ?[]const u8) ?linux.SIG {
    const given = name orelse return null;
    const names = [_]struct { name: []const u8, signal: linux.SIG }{
        .{ .name = "USR1", .signal = .USR1 }, .{ .name = "USR2", .signal = .USR2 },
        .{ .name = "TERM", .signal = .TERM }, .{ .name = "INT", .signal = .INT },
        .{ .name = "KILL", .signal = .KILL },
    };
    for (names) |known| if (std.mem.eql(u8, known.name, given)) return known.signal;
    return null;
}

fn text_write(arena: std.mem.Allocator, fd: linux.fd_t, comptime format: []const u8, arguments: anytype) !void {
    try write_all(fd, try std.fmt.allocPrint(arena, format ++ "\n", arguments));
}

/// The request's line: up to its newline or the connection's end.
fn request_read(arena: std.mem.Allocator, fd: linux.fd_t) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (bytes.items.len < request_size_max) {
        const result = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (result == 0) break;
        try bytes.appendSlice(arena, chunk[0..result]);
        if (std.mem.indexOfScalar(u8, chunk[0..result], '\n') != null) break;
    }
    const end = std.mem.indexOfScalar(u8, bytes.items, '\n') orelse bytes.items.len;
    return bytes.items[0..end];
}

const Reply = struct { status: u32, stdout: []const u8, stderr: []const u8, truncated: bool };

fn reply_write(arena: std.mem.Allocator, fd: linux.fd_t, reply: Reply) !void {
    const valid: Reply = .{
        .status = reply.status,
        .stdout = try utf8_valid(arena, reply.stdout),
        .stderr = try utf8_valid(arena, reply.stderr),
        .truncated = reply.truncated,
    };
    const text = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(valid, .{})});
    try write_all(fd, text);
}

/// The command run with its stdin given, its outputs read as they come (both at once: a command
/// filling one while the other is read would wait forever), its exit status. Done when it exits,
/// not when its outputs end: what it started may keep them open (`det-nodes start`'s node, its
/// copy of the pipes: the end never came, and the REPL's request waited out its step's 600 s).
fn command_run(arena: std.mem.Allocator, request: Request) !Reply {
    const path = try executable_find(arena, request.argv[0]) orelse {
        return .{ .status = 127, .stdout = "", .stderr = try std.fmt.allocPrint(arena, "det-runner: {s}: not found", .{request.argv[0]}), .truncated = false };
    };
    var argv: [argv_count_max:null]?[*:0]const u8 = @splat(null);
    argv[0] = path;
    for (request.argv[1..], 1..) |word, index| argv[index] = try arena.dupeSentinel(u8, word, 0);
    var input: [2]i32 = undefined;
    var stdout: [2]i32 = undefined;
    var stderr: [2]i32 = undefined;
    for ([_]*[2]i32{ &input, &stdout, &stderr }) |pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.dup2(input[0], 0);
        _ = linux.dup2(stdout[1], 1);
        _ = linux.dup2(stderr[1], 2);
        _ = linux.execve(path, &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(input[0]);
    _ = linux.close(stdout[1]);
    _ = linux.close(stderr[1]);
    write_all(input[1], request.stdin) catch {}; // A command that reads none closed it.
    _ = linux.close(input[1]);
    const exited_result = linux.pidfd_open(@intCast(pid), 0);
    if (linux.errno(exited_result) != .SUCCESS) return error.PidfdFailed;
    const exited: linux.fd_t = @intCast(exited_result);
    defer _ = linux.close(exited);
    var outputs = [2]std.ArrayList(u8){ .empty, .empty };
    var open = [2]bool{ true, true };
    var truncated = false;
    var done = false;
    // After its exit, a bounded drain: what it started may write on into the copy it holds.
    var drains: u32 = 0;
    while ((open[0] or open[1]) and drains < drains_max) {
        if (done) drains += 1;
        var polled = [3]linux.pollfd{
            .{ .fd = if (open[0]) stdout[0] else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (open[1]) stderr[0] else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (done) -1 else exited, .events = linux.POLL.IN, .revents = 0 },
        };
        // Once it exited, what its outputs already hold is read, and no more waited for.
        const ready = linux.poll(&polled, polled.len, if (done) 0 else -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return error.PollFailed;
        if (ready == 0) break;
        if (polled[2].revents != 0) done = true;
        for (polled[0..2], 0..) |entry, index| {
            if (entry.revents == 0) continue;
            var chunk: [16 << 10]u8 = undefined;
            const result = linux.read(entry.fd, &chunk, chunk.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) {
                _ = linux.close(entry.fd);
                open[index] = false;
                continue;
            }
            const room = output_size_max - outputs[index].items.len;
            if (result > room) truncated = true;
            try outputs[index].appendSlice(arena, chunk[0..@min(result, room)]);
        }
    }
    for (open, [2]linux.fd_t{ stdout[0], stderr[0] }) |still, fd| if (still) {
        _ = linux.close(fd);
    };
    var status: i32 = 0;
    while (true) {
        const result = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return error.WaitFailed;
        break;
    }
    const bits: u32 = @bitCast(status);
    const code = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    return .{ .status = code, .stdout = outputs[0].items, .stderr = outputs[1].items, .truncated = truncated };
}

/// `name` as a path: itself when it has a slash, else the first in the runner's PATH.
fn executable_find(arena: std.mem.Allocator, name: []const u8) !?[:0]const u8 {
    if (name.len == 0 or name.len >= path_size_max) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try arena.dupeSentinel(u8, name, 0);
    for ([_][]const u8{ "/opt/determinismo/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" }) |directory| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, name }, 0);
        if (linux.errno(linux.access(path, linux.X_OK)) == .SUCCESS) return path;
    }
    return null;
}

/// `text` with each byte that is not UTF-8 replaced (U+FFFD): JSON text is UTF-8.
fn utf8_valid(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;
    var valid: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[at]) catch 0;
        if (size > 0 and at + size <= text.len and std.unicode.utf8ValidateSlice(text[at .. at + size])) {
            try valid.appendSlice(arena, text[at .. at + size]);
            at += size;
        } else {
            try valid.appendSlice(arena, "\u{FFFD}");
            at += 1;
        }
    }
    return valid.items;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

test utf8_valid {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("a\u{FFFD}b", try utf8_valid(arena_state.allocator(), "a\xffb"));
}

test signal_of {
    try std.testing.expectEqual(linux.SIG.USR1, signal_of("USR1").?);
    try std.testing.expect(signal_of("HUP") == null);
    try std.testing.expect(signal_of(null) == null);
}

test executable_find {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("/x/y", (try executable_find(arena_state.allocator(), "/x/y")).?);
    try std.testing.expect(try executable_find(arena_state.allocator(), "") == null);
}
