// SPDX-License-Identifier: MIT
//! det-nrepl-relay: one nREPL message, from the platform to an nREPL server in a node, and its
//! replies back: what a session's step runs (`det-nodes exec <node> det-nrepl-relay ...`), so
//! that an nREPL client outside (CIDER, Calva: infra/host/nrepl-proxy.py) talks to a server in
//! the guest. The message comes base64-encoded on the command line (a step is one), or, for one
//! larger than a step, in parts gathered in a file first:
//!
//!   det-nrepl-relay send <port> <base64 | @file>   the message; its replies on stdout, each
//!                                                  base64 on a line, up to the one whose
//!                                                  status says done (or need-input)
//!   det-nrepl-relay part <file> <base64>           a part of a message, appended to file
//!   det-nrepl-relay serve <port> <fifo>            a session's relay, the fast path: one
//!                                                  connection to the server for the whole
//!                                                  session, messages read from the FIFO as the
//!                                                  platform writes them (the agent's det:send:
//!                                                  no process started per message), each reply
//!                                                  an event as it comes (nrepl_reply, in parts),
//!                                                  then nrepl_done with the message's id once
//!                                                  its status says done: what a session's step
//!                                                  waits for (vm.zig's det:ask)
//!
//! It reads replies as bencode only as far as it must: where each ends, and its status.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const message_size_max = 64 << 20;
const reply_size_max = 64 << 20;
/// How long a message may take, in seconds of virtual time: an eval that runs long (a driver
/// called from the REPL) answers when it is done.
const timeout_s = 600;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "part")) {
        const bytes = try base64_decode(arena, arguments[3]);
        return file_append(try arena.dupeSentinel(u8, arguments[2], 0), bytes);
    }
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "send")) {
        const port = try std.fmt.parseInt(u16, arguments[2], 10);
        const given = arguments[3];
        const message = if (given.len > 0 and given[0] == '@')
            try file_read(arena, try arena.dupeSentinel(u8, given[1..], 0))
        else
            try base64_decode(arena, given);
        return relay(arena, port, message);
    }
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "serve")) {
        const port = try std.fmt.parseInt(u16, arguments[2], 10);
        return serve(arena, port, try arena.dupeSentinel(u8, arguments[3], 0));
    }
    std.debug.print("usage: det-nrepl-relay send <port> <base64 | @file> | part <file> <base64> | serve <port> <fifo>\n", .{});
    std.process.exit(2);
}

fn relay(arena: std.mem.Allocator, port: u16, message: []const u8) !void {
    const fd = try connect(port);
    defer _ = linux.close(fd);
    try write_all(fd, message);
    var buffer: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    while (true) {
        // Every complete reply in the buffer, printed; done once one says so.
        while (true) {
            const end = value_end(buffer.items, start) catch |err| switch (err) {
                error.Incomplete => break,
                else => return err,
            };
            const reply = buffer.items[start..end];
            try reply_print(arena, reply);
            start = end;
            if (finished(reply)) return;
        }
        if (buffer.items.len > reply_size_max) return error.ReplyTooLarge;
        try buffer.ensureUnusedCapacity(arena, 64 * 1024);
        const free = buffer.unusedCapacitySlice();
        const result = linux.read(fd, free.ptr, free.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (result == 0) return error.ConnectionClosed;
        buffer.items.len += result;
    }
}

/// Each event carries this much of a reply (base64 of it: well within an event's 4 KB).
const reply_part_size = 2048;
/// How long the server may take to listen, in seconds of virtual time (a JVM starting).
const connect_attempts_max = 240;

fn serve(arena: std.mem.Allocator, port: u16, fifo: [:0]const u8) !void {
    _ = linux.unlink(fifo);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o666, 0)) != .SUCCESS) return error.Fifo;
    // Read and write: never an end of input when the last writer closes.
    const input_result = linux.open(fifo, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(input_result) != .SUCCESS) return error.Fifo;
    const input: linux.fd_t = @intCast(input_result);
    const server = for (0..connect_attempts_max) |_| {
        break connect(port) catch {
            const pause: linux.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
            _ = linux.nanosleep(&pause, null);
            continue;
        };
    } else return error.ConnectFailed;
    // No timeout on a session's connection: replies come when they come.
    const none = linux.timeval{ .sec = 0, .usec = 0 };
    _ = linux.setsockopt(server, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&none), @sizeOf(linux.timeval));
    sdk.event("nrepl_relay_ready", .{ .port = port });
    var replies: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = input, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = server, .events = linux.POLL.IN, .revents = 0 },
        };
        const ready = linux.poll(&fds, fds.len, -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return error.Poll;
        if (fds[0].revents & linux.POLL.IN != 0) {
            const result = linux.read(input, &chunk, chunk.len);
            if (linux.errno(result) == .SUCCESS and result > 0) try write_all(server, chunk[0..result]);
        }
        if (fds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const result = linux.read(server, &chunk, chunk.len);
            if (linux.errno(result) != .SUCCESS or result == 0) {
                sdk.event("nrepl_relay_closed", .{ .port = port });
                return;
            }
            if (start > 0 and start == replies.items.len) {
                replies.items.len = 0;
                start = 0;
            }
            try replies.appendSlice(arena, chunk[0..result]);
            while (true) {
                const end = value_end(replies.items, start) catch |err| switch (err) {
                    error.Incomplete => break,
                    else => return err,
                };
                reply_emit(replies.items[start..end]);
                start = end;
            }
        }
    }
}

/// A reply as events: its bytes, base64, in parts (nrepl_reply), then, once its status says
/// done, nrepl_done with its id.
fn reply_emit(reply: []const u8) void {
    const id = field_string(reply, "id") orelse "";
    const encoder = std.base64.standard.Encoder;
    const parts = @max(1, (reply.len + reply_part_size - 1) / reply_part_size);
    for (0..parts) |index| {
        const piece = reply[index * reply_part_size .. @min(reply.len, (index + 1) * reply_part_size)];
        var encoded: [encoder.calcSize(reply_part_size)]u8 = undefined;
        const text = encoder.encode(&encoded, piece);
        sdk.event("nrepl_reply", .{ .id = id, .part = index, .last = index + 1 == parts, .data = text });
    }
    if (finished(reply)) sdk.event("nrepl_done", .{ .id = id });
}

/// A top-level string field of a bencoded dictionary.
fn field_string(reply: []const u8, key: []const u8) ?[]const u8 {
    if (reply.len < 2 or reply[0] != 'd') return null;
    var position: usize = 1;
    while (position < reply.len and reply[position] != 'e') {
        const key_end = value_end(reply, position) catch return null;
        const name = string_of(reply[position..key_end]) orelse return null;
        const value_stop = value_end(reply, key_end) catch return null;
        if (std.mem.eql(u8, name, key)) return string_of(reply[key_end..value_stop]);
        position = value_stop;
    }
    return null;
}

fn connect(port: u16) !linux.fd_t {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    const timeout = linux.timeval{ .sec = timeout_s, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        _ = linux.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

/// A reply that ends its message's: its status lists done, or need-input (the server waits for
/// the client's stdin, which comes as another message).
fn finished(reply: []const u8) bool {
    if (reply.len < 2 or reply[0] != 'd') return false;
    var position: usize = 1;
    while (position < reply.len and reply[position] != 'e') {
        const key_end = value_end(reply, position) catch return false;
        const key = string_of(reply[position..key_end]) orelse return false;
        const value_stop = value_end(reply, key_end) catch return false;
        if (std.mem.eql(u8, key, "status") and reply[key_end] == 'l') {
            var item = key_end + 1;
            while (item < value_stop - 1) {
                const item_end = value_end(reply, item) catch return false;
                const text = string_of(reply[item..item_end]) orelse "";
                if (std.mem.eql(u8, text, "done") or std.mem.eql(u8, text, "need-input")) return true;
                item = item_end;
            }
        }
        position = value_stop;
    }
    return false;
}

/// A bencoded string's bytes.
fn string_of(value: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    if (colon == 0 or !std.ascii.isDigit(value[0])) return null;
    return value[colon + 1 ..];
}

/// Where the bencode value starting at `at` ends.
fn value_end(bytes: []const u8, at: usize) error{ Incomplete, BadBencode }!usize {
    if (at >= bytes.len) return error.Incomplete;
    switch (bytes[at]) {
        'i' => {
            const end = std.mem.indexOfScalarPos(u8, bytes, at, 'e') orelse return error.Incomplete;
            return end + 1;
        },
        'l', 'd' => {
            var position = at + 1;
            while (true) {
                if (position >= bytes.len) return error.Incomplete;
                if (bytes[position] == 'e') return position + 1;
                position = try value_end(bytes, position);
            }
        },
        '0'...'9' => {
            const colon = std.mem.indexOfScalarPos(u8, bytes, at, ':') orelse return error.Incomplete;
            const size = std.fmt.parseInt(usize, bytes[at..colon], 10) catch return error.BadBencode;
            if (colon + 1 + size > bytes.len) return error.Incomplete;
            return colon + 1 + size;
        },
        else => return error.BadBencode,
    }
}

fn reply_print(arena: std.mem.Allocator, reply: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const line = try arena.alloc(u8, encoder.calcSize(reply.len) + 1);
    _ = encoder.encode(line[0 .. line.len - 1], reply);
    line[line.len - 1] = '\n';
    try write_all(1, line);
}

fn base64_decode(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(bytes, text);
    return bytes;
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

fn file_append(path: [:0]const u8, bytes: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    try write_all(@intCast(fd), bytes);
}

fn file_read(arena: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        if (bytes.items.len > message_size_max) return error.MessageTooLarge;
        try bytes.ensureUnusedCapacity(arena, 64 * 1024);
        const free = bytes.unusedCapacitySlice();
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) break;
        bytes.items.len += result;
    }
    // A message's parts are gathered once: the file goes with its sending.
    _ = linux.unlink(path);
    return bytes.items;
}

test field_string {
    const reply = "d2:id3:abc5:value1:36:statusl4:doneee";
    try std.testing.expectEqualStrings("abc", field_string(reply, "id").?);
    try std.testing.expectEqualStrings("3", field_string(reply, "value").?);
    try std.testing.expectEqual(null, field_string(reply, "out"));
}

test value_end {
    try std.testing.expectEqual(@as(usize, 3), try value_end("i5e", 0));
    try std.testing.expectEqual(@as(usize, 5), try value_end("3:abcxx", 0));
    const reply = "d2:id1:16:statusl4:doneee";
    try std.testing.expectEqual(reply.len, try value_end(reply, 0));
    try std.testing.expect(finished(reply));
    try std.testing.expectError(error.Incomplete, value_end("d2:id1:1", 0));
    try std.testing.expect(!finished("d3:out2:hie"));
    // Text that looks like a status is not one.
    try std.testing.expect(!finished("d3:out16:6:statusl4:donee2:id1:1e"));
}
