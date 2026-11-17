// SPDX-License-Identifier: MIT
//! An agent's sandbox (docs/PRODUCTS.md): a fast VM in dev mode (`determinismo run --vcpus N
//! --dev <directory>`), worked in through its control FIFO and its events. serve keeps them
//! (its /sandboxes routes) and starts their machines; this is what one sandbox does:
//!
//! - exec: a command in a node, as a background action of the guest's agent (its own process,
//!   so several run at once and the agent stays free), told apart by a tag in front of it
//!   (`: sbx-<n>;`), its output and status read from the guest's events;
//! - files: written through a staging file in the guest (det:send's parts) and the node's
//!   stdin, read as base64 from a command's output;
//! - checkpoints: the machine saved as it stands (explore-here: the fast VM goes on), named
//!   `here-<k>` in its directory;
//! - its record (`record.jsonl`): every step and its result, in order, what a replay repeats.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const directory_max = 512;
/// A guest action's most (vm.zig's step_size_max, a page less the request's header).
pub const action_max = 4096 - 16;
/// A det:send's part, raw bytes (its base64 fits an action with the path).
const part_bytes = 2400;
/// What one command's output keeps (the rest is cut, said in the reply).
pub const output_max = 4 << 20;

const Sandbox = @This();

id: u32 = 0,
pid: linux.pid_t = 0,
directory_buffer: [directory_max]u8 = undefined,
directory_len: usize = 0,
/// Where the guest's events were read up to (events.jsonl).
events_offset: u64 = 0,
tag_next: u32 = 1,
/// Its checkpoints, here-1 to here-<count> in its directory.
checkpoints: u32 = 0,
/// One conversation with the machine at a time (its events are read in order).
busy: std.atomic.Value(bool) = .init(false),

pub fn directory(sandbox: *const Sandbox) []const u8 {
    return sandbox.directory_buffer[0..sandbox.directory_len];
}

pub fn directory_set(sandbox: *Sandbox, path: []const u8) !void {
    if (path.len > directory_max) return error.PathTooLong;
    @memcpy(sandbox.directory_buffer[0..path.len], path);
    sandbox.directory_len = path.len;
}

/// A line to the machine's control FIFO (vm.zig's dev_control_main): `explore-here`, or
/// `action <text>`.
fn control(sandbox: *const Sandbox, line: []const u8) !void {
    assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    var path_buffer: [directory_max + 16]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/control", .{sandbox.directory()}, 0);
    const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.SandboxGone;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    // One write, the line and its end: several threads write here (the egress relay's), and a
    // FIFO keeps a write of under PIPE_BUF (4,096 bytes) whole.
    var buffer: [action_max + 64]u8 = undefined;
    if (line.len + 1 > buffer.len) return error.ActionTooLong;
    @memcpy(buffer[0..line.len], line);
    buffer[line.len] = '\n';
    try write_all(fd, buffer[0 .. line.len + 1]);
}

pub fn action(sandbox: *const Sandbox, text: []const u8) !void {
    if (text.len > action_max) return error.ActionTooLong;
    var buffer: [action_max + 8]u8 = undefined;
    try sandbox.control(try std.fmt.bufPrint(&buffer, "action {s}", .{text}));
}

/// A guest event: its name and its JSON.
pub const Event = struct { name: []const u8, details: std.json.Value };

/// The guest's events from where they were read up to, until `done` says one ends the wait,
/// or `timeout_ns` passes (error.Timeout). Each one is given to `done` as it comes.
pub fn events_until(
    sandbox: *Sandbox,
    arena: std.mem.Allocator,
    context: anytype,
    comptime done: fn (@TypeOf(context), Event) bool,
    timeout_ns: u64,
) !void {
    var path_buffer: [directory_max + 16]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/events.jsonl", .{sandbox.directory()}, 0);
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.SandboxGone;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const deadline = monotonic_ns() + timeout_ns;
    var pending: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    // `pending` holds the file's bytes from events_offset on: whole lines are taken from its
    // front, a partial last line stays, and the next read starts where `pending` ends.
    while (true) {
        const read_at = sandbox.events_offset + pending.items.len;
        const result = linux.pread(fd, &chunk, chunk.len, @intCast(read_at));
        if (linux.errno(result) != .SUCCESS) return error.EventsUnreadable;
        if (result == 0) {
            if (monotonic_ns() > deadline) return error.Timeout;
            if (!sandbox.alive()) return error.SandboxGone;
            sleep_ms(2);
            continue;
        }
        if (pending.items.len + result > events_line_max) return error.EventLineTooLong;
        try pending.appendSlice(arena, chunk[0..result]);
        const last_newline = std.mem.lastIndexOfScalar(u8, pending.items, '\n') orelse continue;
        const whole = pending.items[0 .. last_newline + 1];
        var lines = std.mem.splitScalar(u8, whole, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const event = event_parse(arena, line) orelse continue;
            if (done(context, event)) {
                // Past this line: the next wait reads from the one after it.
                sandbox.events_offset += @intFromPtr(line.ptr) - @intFromPtr(whole.ptr) + line.len + 1;
                return;
            }
        }
        sandbox.events_offset += whole.len;
        const rest = pending.items.len - whole.len;
        std.mem.copyForwards(u8, pending.items[0..rest], pending.items[whole.len..]);
        pending.items.len = rest;
    }
}

/// A guest event line's most: past it, the events are not a guest's.
const events_line_max = 16 << 20;

/// An events.jsonl line's guest event: `{"seq":..,"event":{"event":"<name>","details":{..}}}`.
fn event_parse(arena: std.mem.Allocator, line: []const u8) ?Event {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (value != .object) return null;
    const event = value.object.get("event") orelse return null;
    if (event != .object) return null;
    const name = event.object.get("event") orelse return null;
    if (name != .string) return null;
    return .{ .name = name.string, .details = event.object.get("details") orelse .null };
}

/// The machine's process alive (serve's child). An exited child is a zombie until reaped, and
/// kill(pid, 0) still finds it: reaped here first (a machine dead at its start looked alive, and
/// a CI job waited 40 minutes on it).
pub fn alive(sandbox: *const Sandbox) bool {
    if (sandbox.pid <= 0) return false;
    var status: i32 = 0;
    const reaped = linux.waitpid(sandbox.pid, &status, linux.W.NOHANG);
    if (linux.errno(reaped) == .SUCCESS and reaped == @as(usize, @intCast(sandbox.pid))) return false;
    return linux.errno(linux.kill(sandbox.pid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
}

pub const Exec = struct { status: i64, output: []const u8, truncated: bool };

/// `command` in `node` (a shell's, /bin/sh -c), to its end or `timeout_s`: its status (126 when
/// it could not start, 124 at the timeout) and its output, stdout and stderr together.
pub fn exec(sandbox: *Sandbox, arena: std.mem.Allocator, node: []const u8, command: []const u8, timeout_s: u32) !Exec {
    var text: std.ArrayList(u8) = .empty;
    try text.print(arena, "det-nodes exec {s} /bin/sh -c ", .{node});
    try shell_quote(arena, &text, command);
    return sandbox.tagged(arena, text.items, timeout_s);
}

/// A runner command as a background action told apart by its tag: its status and output.
fn tagged(sandbox: *Sandbox, arena: std.mem.Allocator, command: []const u8, timeout_s: u32) !Exec {
    const tag = sandbox.tag_next;
    sandbox.tag_next += 1;
    const prefix = try std.fmt.allocPrint(arena, ": sbx-{d};", .{tag});
    try sandbox.action(try std.fmt.allocPrint(arena, "det:background {s} {s}", .{ prefix, command }));
    var watch: ExecWatch = .{ .arena = arena, .prefix = prefix };
    sandbox.events_until(arena, &watch, ExecWatch.done, @as(u64, timeout_s) * std.time.ns_per_s) catch |err| switch (err) {
        error.Timeout => return .{ .status = 124, .output = watch.output.items, .truncated = watch.truncated },
        else => return err,
    };
    return .{ .status = watch.status, .output = watch.output.items, .truncated = watch.truncated };
}

const ExecWatch = struct {
    arena: std.mem.Allocator,
    prefix: []const u8,
    id: ?i64 = null,
    output: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    status: i64 = 126,

    fn done(watch: *ExecWatch, event: Event) bool {
        if (event.details != .object) return false;
        const details = event.details.object;
        const id = switch (details.get("id") orelse return false) {
            .integer => |value| value,
            else => return false,
        };
        if (std.mem.eql(u8, event.name, "exec_start")) {
            const command = details.get("command") orelse return false;
            if (command == .string and std.mem.startsWith(u8, command.string, watch.prefix)) watch.id = id;
            return false;
        }
        if (watch.id == null or watch.id.? != id) return false;
        if (std.mem.eql(u8, event.name, "exec_output")) {
            const text = details.get("text") orelse return false;
            if (text != .string) return false;
            if (watch.output.items.len + text.string.len > output_max) {
                watch.truncated = true;
                return false;
            }
            watch.output.appendSlice(watch.arena, text.string) catch {
                watch.truncated = true;
            };
            return false;
        }
        if (std.mem.eql(u8, event.name, "exec_done")) {
            if (details.get("status")) |status| if (status == .integer) {
                watch.status = status.integer;
            };
            return true;
        }
        return false;
    }
};

/// `bytes` as the file `path` in `node`: given to the guest in det:send's parts (a staging file
/// in the guest, which the agent appends each part to), then copied into the node through its
/// stdin, its size checked there.
pub fn file_write(sandbox: *Sandbox, arena: std.mem.Allocator, node: []const u8, path: []const u8, bytes: []const u8) !void {
    const tag = sandbox.tag_next;
    sandbox.tag_next += 1;
    const staging = try std.fmt.allocPrint(arena, "/run/det/sbx-file-{d}", .{tag});
    // The staging file, empty: det:send appends, it does not create.
    const made = try sandbox.runner(arena, try std.fmt.allocPrint(arena, ": > {s}", .{staging}), 30);
    if (made.status != 0) return error.StagingFailed;
    var at: usize = 0;
    while (at < bytes.len) : (at += part_bytes) {
        const part = bytes[at..@min(bytes.len, at + part_bytes)];
        const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(part.len));
        _ = std.base64.standard.Encoder.encode(encoded, part);
        try sandbox.action(try std.fmt.allocPrint(arena, "det:send {s} {s}", .{ staging, encoded }));
    }
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "det-nodes exec {s} /bin/sh -c ", .{node});
    try shell_quote(arena, &command, try std.fmt.allocPrint(arena, "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && wc -c < \"$1\"", .{}));
    try command.appendSlice(arena, " sh ");
    try shell_quote(arena, &command, path);
    try command.print(arena, " < {s}; status=$?; rm -f {s}; exit $status", .{ staging, staging });
    const copied = try sandbox.runner(arena, command.items, 300);
    if (copied.status != 0) return error.FileWriteFailed;
    const size = std.fmt.parseInt(u64, std.mem.trim(u8, copied.output, " \n"), 10) catch return error.FileWriteFailed;
    if (size != bytes.len) return error.FileWriteShort;
}

/// The file `path` in `node`, read as base64 through a command's output.
pub fn file_read(sandbox: *Sandbox, arena: std.mem.Allocator, node: []const u8, path: []const u8) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    try command.appendSlice(arena, "base64 -w0 ");
    try shell_quote(arena, &command, path);
    const read = try sandbox.exec(arena, node, command.items, 300);
    if (read.status != 0) return error.FileReadFailed;
    if (read.truncated) return error.FileTooLarge;
    const text = std.mem.trim(u8, read.output, " \n");
    const decoded = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.FileReadFailed);
    std.base64.standard.Decoder.decode(decoded, text) catch return error.FileReadFailed;
    return decoded;
}

/// Where the guest's events end now (a reader starting from here sees only what comes next).
pub fn events_end(sandbox: *const Sandbox) u64 {
    var path_buffer: [directory_max + 16]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/events.jsonl", .{sandbox.directory()}, 0) catch return 0;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true }, &stat)) != .SUCCESS) return 0;
    return stat.size;
}

/// A runner command started in the background (the agent's det:background), not waited for.
pub fn exec_background(sandbox: *Sandbox, arena: std.mem.Allocator, command: []const u8) !void {
    try sandbox.action(try std.fmt.allocPrint(arena, "det:background {s}", .{command}));
}

/// Until the guest says `name` (an event), within `timeout_s`.
pub fn event_wait(sandbox: *Sandbox, arena: std.mem.Allocator, name: []const u8, timeout_s: u32) !void {
    var watch: NameWatch = .{ .name = name };
    try sandbox.events_until(arena, &watch, NameWatch.done, @as(u64, timeout_s) * std.time.ns_per_s);
}

/// The machine saved as it stands (the fast VM goes on): its name, here-<k>.
pub fn checkpoint(sandbox: *Sandbox, arena: std.mem.Allocator) ![]const u8 {
    try sandbox.control("explore-here");
    var watch: NameWatch = .{ .name = "explore_here_done" };
    try sandbox.events_until(arena, &watch, NameWatch.done, 300 * std.time.ns_per_s);
    sandbox.checkpoints += 1;
    return std.fmt.allocPrint(arena, "here-{d}", .{sandbox.checkpoints});
}

/// Until the machine is ready: a fresh one waiting after its setup (dev_waiting), one restored
/// from a checkpoint with its CPUs back (explore_here_done).
pub fn ready_wait(sandbox: *Sandbox, arena: std.mem.Allocator, restored: bool, timeout_s: u32) !void {
    var watch: NameWatch = .{ .name = if (restored) "explore_here_done" else "dev_waiting" };
    try sandbox.events_until(arena, &watch, NameWatch.done, @as(u64, timeout_s) * std.time.ns_per_s);
}

const NameWatch = struct {
    name: []const u8,

    fn done(watch: *NameWatch, event: Event) bool {
        return std.mem.eql(u8, event.name, watch.name);
    }
};

/// A command in the guest's runner (it sees every node: det-nodes), as exec runs one in a node.
fn runner(sandbox: *Sandbox, arena: std.mem.Allocator, command: []const u8, timeout_s: u32) !Exec {
    return sandbox.tagged(arena, command, timeout_s);
}

fn shell_quote(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else try out.append(arena, byte);
    }
    try out.append(arena, '\'');
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

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_ms(ms: u64) void {
    const pause: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}

test "a command quoted for the guest's shell" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try shell_quote(std.testing.allocator, &out, "echo 'hi' there");
    try std.testing.expectEqualStrings("'echo '\\''hi'\\'' there'", out.items);
}

test "an event across a read's end is seen, and a partial last line waits" {
    const arena_state = std.testing.allocator;
    var arena_instance = std.heap.ArenaAllocator.init(arena_state);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var path_buffer: [64]u8 = undefined;
    const test_directory = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/det-sandbox-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(test_directory, 0o755);
    var sandbox: Sandbox = .{ .id = 1, .pid = linux.getpid() };
    try sandbox.directory_set(test_directory);
    // Filler lines up to just before 64 KiB, so the awaited one crosses the first read's end.
    var text: std.ArrayList(u8) = .empty;
    const filler = "{\"seq\":1,\"event\":{\"event\":\"filler\",\"details\":{}}}\n";
    while (text.items.len + filler.len < 64 * 1024 - 20) try text.appendSlice(arena, filler);
    try text.appendSlice(arena, "{\"seq\":2,\"event\":{\"event\":\"awaited\",\"details\":{}}}\n");
    try text.appendSlice(arena, "{\"seq\":3,\"event\":{\"event\":\"partial"); // Not ended yet.
    var file_buffer: [96]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/events.jsonl", .{test_directory}, 0);
    const fd: linux.fd_t = @intCast(linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    try write_all(fd, text.items);
    _ = linux.close(fd);
    const Watch = struct {
        name: []const u8,
        fn done(watch: *@This(), event: Event) bool {
            return std.mem.eql(u8, event.name, watch.name);
        }
    };
    var awaited: Watch = .{ .name = "awaited" };
    try sandbox.events_until(arena, &awaited, Watch.done, std.time.ns_per_s);
    // The partial line: no event yet, a timeout, not a loop that grows.
    var later: Watch = .{ .name = "partial" };
    try std.testing.expectError(error.Timeout, sandbox.events_until(arena, &later, Watch.done, 50 * std.time.ns_per_ms));
}
