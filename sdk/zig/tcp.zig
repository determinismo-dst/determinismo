// SPDX-License-Identifier: MIT
//! TCP for test programs: a blocking connection with timeouts and a fixed read buffer, the base
//! of protocol clients (Redis, Postgres, line protocols).
//!
//! Under faults a server is often unreachable for a while: connecting, writing or reading then
//! fails quickly (the timeouts) with an error `unavailable` recognizes, which a test notes rather
//! than treats as a bug.
//!
//!   var connection: sdk.tcp.Connection = undefined;
//!   try connection.open(ctx.nodes.bank.address, 7000, .{});
//!   defer connection.close();
//!   try connection.write_all("total\n");
//!   const line = try connection.read_line();
//!
//!   const reply = try sdk.tcp.request_line(address, 7000, "total\n", &buffer); // One shot.
//!   const response = try sdk.tcp.http(address, 8000, "GET", "/state", "", &buffer); // HTTP.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const buffer_size = 64 * 1024;
/// A line longer than the buffer goes on in one of these, made for it (and kept until the
/// connection closes): a sidecar client's reply holding a whole collection (a ZooKeeper queue
/// drained, Keeper's total-queue run 700: past 64 KiB every final read was ReplyTooLarge, taken
/// for an ensemble that never served again).
pub const line_size_max = 16 << 20;

pub const Options = struct {
    /// A connect, write or read that waits longer fails (instead of waiting out TCP's
    /// retransmissions): under network faults, "unavailable" must be quick to observe.
    timeout_ms: u32 = 1000,
    /// http_with's request body's type (Dgraph, for one, answers only application/json).
    content_type: []const u8 = "application/octet-stream",
    /// http_with's further header lines, each ending in "\r\n" (SurrealDB's Accept and
    /// namespace).
    headers: []const u8 = "",
    /// http_with's response header to keep (its name, any case): its value in
    /// `Response.header` (Consul's X-Consul-Index: the index its answer reflects).
    header_kept: []const u8 = "",
    /// For a connection that only reads (a watch, a subscription): TCP keepalive probes once it
    /// was idle this many seconds, then one a second, three unanswered or one refused ending it
    /// (a read then fails); 0 for none. A peer that restarted while partitioned from us never
    /// says so (its FIN lost), and a reader that sends nothing waits for good on a socket whose
    /// other end is gone (a client's watchers judged silent, run 1566).
    keepalive_s: u16 = 0,
};

/// Whether `err` means the server could not be reached or went away (as opposed to a protocol
/// error or a bug).
pub fn unavailable(err: anyerror) bool {
    return switch (err) {
        error.ConnectFailed, error.WriteFailed, error.ReadFailed, error.ConnectionClosed => true,
        else => false,
    };
}

pub const Connection = struct {
    fd: linux.fd_t = -1,
    buffer: [buffer_size]u8 = undefined,
    start: u32 = 0,
    end: u32 = 0,
    long: ?[]u8 = null,

    pub fn open(connection: *Connection, address: [4]u8, port: u16, options: Options) !void {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
        connection.* = .{ .fd = @intCast(socket) };
        errdefer connection.close();
        const timeout = linux.timeval{
            .sec = @intCast(options.timeout_ms / std.time.ms_per_s),
            .usec = @intCast((options.timeout_ms % std.time.ms_per_s) * std.time.us_per_ms),
        };
        for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
            const size = @sizeOf(linux.timeval);
            _ = linux.setsockopt(connection.fd, linux.SOL.SOCKET, option, @ptrCast(&timeout), size);
        }
        if (options.keepalive_s > 0) {
            const settings = [_]struct { level: i32, name: u32, value: u32 }{
                .{ .level = linux.SOL.SOCKET, .name = linux.SO.KEEPALIVE, .value = 1 },
                .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPIDLE, .value = options.keepalive_s },
                .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPINTVL, .value = 1 },
                .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPCNT, .value = 3 },
            };
            for (settings) |setting| {
                const result = linux.setsockopt(connection.fd, setting.level, setting.name, @ptrCast(&setting.value), @sizeOf(u32));
                if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
            }
        }
        const target = linux.sockaddr.in{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(address), // Already in network order.
        };
        const result = linux.connect(connection.fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in));
        if (linux.errno(result) != .SUCCESS) return error.ConnectFailed;
    }

    pub fn close(connection: *Connection) void {
        assert(connection.fd >= 0);
        _ = linux.close(connection.fd);
        connection.fd = -1;
        if (connection.long) |long| std.heap.page_allocator.free(long);
        connection.long = null;
    }

    pub fn write_all(connection: *Connection, bytes: []const u8) !void {
        assert(connection.fd >= 0);
        var written: usize = 0;
        while (written < bytes.len) {
            const result = linux.write(connection.fd, bytes[written..].ptr, bytes.len - written);
            if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
            written += result;
        }
    }

    /// The next line, without its "\n" (or "\r\n"). It borrows the buffer (or, past it, the
    /// connection's long line, `line_size_max` at most) until the next read.
    pub fn read_line(connection: *Connection) ![]const u8 {
        while (true) {
            const pending = connection.buffer[connection.start..connection.end];
            if (std.mem.indexOfScalar(u8, pending, '\n')) |index| {
                connection.start += @intCast(index + 1);
                return std.mem.trimEnd(u8, pending[0..index], "\r");
            }
            if (connection.start == 0 and connection.end == buffer_size) {
                const long = connection.long orelse try std.heap.page_allocator.alloc(u8, line_size_max);
                connection.long = long;
                return connection.read_line_into(long);
            }
            try connection.fill();
        }
    }

    /// The next line however long, up to `destination.len`, into it (its end taken off): a
    /// line protocol's reply larger than the buffer (a ZooKeeper queue drained whole, Keeper's
    /// total-queue, run 700: past 64 KiB every final read was ReplyTooLarge). What follows the
    /// line stays buffered.
    pub fn read_line_into(connection: *Connection, destination: []u8) ![]const u8 {
        var size: usize = 0;
        while (true) {
            const pending = connection.buffer[connection.start..connection.end];
            const index = std.mem.indexOfScalar(u8, pending, '\n');
            const taken = index orelse pending.len;
            if (size + taken > destination.len) return error.LineTooLong;
            @memcpy(destination[size..][0..taken], pending[0..taken]);
            size += taken;
            if (index != null) {
                connection.start += @intCast(taken + 1);
                return std.mem.trimEnd(u8, destination[0..size], "\r");
            }
            connection.start = connection.end;
            try connection.fill();
        }
    }

    /// The next `size` bytes. They borrow the buffer until the next read.
    pub fn read_exact(connection: *Connection, size: u32) ![]const u8 {
        if (size > buffer_size) return error.ReplyTooLarge;
        while (connection.end - connection.start < size) try connection.fill();
        const bytes = connection.buffer[connection.start..][0..size];
        connection.start += size;
        return bytes;
    }

    /// The next `destination.len` bytes, into it: what is buffered, then straight from the
    /// socket, so a body as large as its caller's buffer (a page of etcd's values with bodies,
    /// megabytes: a chunk of a Go server's reply is a whole write) is no larger than ours.
    pub fn read_into(connection: *Connection, destination: []u8) !void {
        assert(connection.fd >= 0);
        const buffered = @min(destination.len, connection.end - connection.start);
        @memcpy(destination[0..buffered], connection.buffer[connection.start..][0..buffered]);
        connection.start += @intCast(buffered);
        var size: usize = buffered;
        while (size < destination.len) {
            const free = destination[size..];
            const result = linux.read(connection.fd, free.ptr, free.len);
            if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
            if (result == 0) return error.ConnectionClosed;
            size += result;
        }
        assert(size == destination.len);
    }

    /// Everything until the server closes the connection, into `destination`: what is buffered,
    /// then straight from the socket. The body of an answer to an HTTP/1.0 request, with neither
    /// a length nor chunks (Go's servers: etcd's pages of values with bodies, smoke run 343).
    pub fn read_all_into(connection: *Connection, destination: []u8) ![]u8 {
        assert(connection.fd >= 0);
        const buffered = connection.end - connection.start;
        if (buffered > destination.len) return error.ReplyTooLarge;
        @memcpy(destination[0..buffered], connection.buffer[connection.start..connection.end]);
        connection.start = connection.end;
        var size: usize = buffered;
        while (true) {
            if (size == destination.len) {
                var probe: [1]u8 = undefined;
                const more = linux.read(connection.fd, &probe, 1);
                if (linux.errno(more) != .SUCCESS) return error.ReadFailed;
                if (more == 0) return destination[0..size];
                return error.ReplyTooLarge;
            }
            const free = destination[size..];
            const result = linux.read(connection.fd, free.ptr, free.len);
            if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
            if (result == 0) return destination[0..size];
            size += result;
        }
    }

    /// Reads past the next `size` bytes, however many: a message too large to keep, but whose
    /// end the protocol says.
    pub fn skip(connection: *Connection, size: u64) !void {
        var left = size;
        while (left > 0) {
            if (connection.end == connection.start) try connection.fill();
            const taken: u32 = @intCast(@min(left, connection.end - connection.start));
            connection.start += taken;
            left -= taken;
        }
    }

    /// The next byte, left unread.
    pub fn peek(connection: *Connection) !u8 {
        if (connection.end == connection.start) try connection.fill();
        return connection.buffer[connection.start];
    }

    fn fill(connection: *Connection) !void {
        assert(connection.fd >= 0);
        assert(connection.start <= connection.end);
        if (connection.start > 0) {
            const pending = connection.end - connection.start;
            const source = connection.buffer[connection.start..connection.end];
            std.mem.copyForwards(u8, connection.buffer[0..pending], source);
            connection.start = 0;
            connection.end = pending;
        }
        if (connection.end == buffer_size) return error.ReplyTooLarge;
        const free = connection.buffer[connection.end..];
        const result = linux.read(connection.fd, free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return error.ConnectionClosed;
        connection.end += @intCast(result);
        assert(connection.end <= buffer_size);
    }
};

/// One request on a new connection, and the first line of the reply, copied into `reply`: what
/// line protocols need.
pub fn request_line(address: [4]u8, port: u16, request: []const u8, reply: []u8) ![]const u8 {
    return request_line_with(address, port, request, reply, .{});
}

/// request_line with options: a longer timeout for a request the server works on for seconds
/// (the default second makes it "unavailable", and the server goes on working for nobody).
pub fn request_line_with(
    address: [4]u8,
    port: u16,
    request: []const u8,
    reply: []u8,
    options: Options,
) ![]const u8 {
    var connection: Connection = undefined;
    try connection.open(address, port, options);
    defer connection.close();
    try connection.write_all(request);
    const line = try connection.read_line();
    if (line.len > reply.len) return error.ReplyTooLarge;
    @memcpy(reply[0..line.len], line);
    return reply[0..line.len];
}

pub const Response = struct {
    status: u16,
    body: []const u8,
    /// The value of `Options.header_kept`, "" without it (in the buffer, before the body).
    header: []const u8 = "",
};

/// One HTTP/1.0 request on a new connection: its status and body, copied into `buffer`. For the
/// HTTP APIs systems under test expose.
pub fn http(
    address: [4]u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    buffer: []u8,
) !Response {
    return http_with(address, port, method, path, body, buffer, .{});
}

/// `http` with connection options: a longer timeout for servers that answer slowly but surely
/// (a consensus write waits out an election).
pub fn http_with(
    address: [4]u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    buffer: []u8,
    options: Options,
) !Response {
    var connection: Connection = undefined;
    try connection.open(address, port, options);
    defer connection.close();
    var head_buffer: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "{s} {s} HTTP/1.0\r\nHost: node\r\n" ++
        "Content-Length: {d}\r\nContent-Type: {s}\r\n", .{
        method, path, body.len, options.content_type,
    });
    assert(options.headers.len == 0 or std.mem.endsWith(u8, options.headers, "\r\n"));
    try connection.write_all(head);
    try connection.write_all(options.headers);
    try connection.write_all("\r\n");
    try connection.write_all(body);
    return response_read(&connection, buffer, options.header_kept);
}

/// "HTTP/1.x NNN reason", headers, an empty line, then the body: Content-Length bytes when the
/// server says how many (it may keep the connection open after them, as Java's HttpServer
/// does), chunks when it sends them (some do even to an HTTP/1.0 request: Redpanda's admin
/// API), else everything until it closes. A reply cut short (nothing, or part of its head)
/// means the server went away (a stop, a crash): ConnectionClosed, not another protocol.
fn response_read(connection: *Connection, buffer: []u8, header_kept: []const u8) !Response {
    const status_line = try connection.read_line();
    if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.")) {
        return error.BadReply;
    }
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadReply;
    var length: ?u32 = null;
    var chunked = false;
    var kept: usize = 0; // The kept header's value, at the buffer's start.
    while (true) {
        const line = try connection.read_line();
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (header_kept.len > 0 and std.ascii.eqlIgnoreCase(name, header_kept)) {
            if (value.len > buffer.len) return error.ReplyTooLarge;
            @memcpy(buffer[0..value.len], value);
            kept = value.len;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = std.ascii.findIgnoreCase(value, "chunked") != null;
        }
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        length = std.fmt.parseInt(u32, value, 10) catch return error.BadReply;
    }
    const header = buffer[0..kept];
    const rest = buffer[kept..];
    if (chunked) return .{ .status = status, .body = try chunks_read(connection, rest), .header = header };
    if (length) |size| {
        if (size > rest.len) return error.ReplyTooLarge;
        try connection.read_into(rest[0..size]);
        return .{ .status = status, .body = rest[0..size], .header = header };
    }
    return .{ .status = status, .body = try connection.read_all_into(rest), .header = header };
}

/// A chunked body into `buffer`: each chunk's size in hex on a line, its bytes and a line end,
/// until a chunk of size 0 and the trailer's lines (to an empty one, or the server closing).
fn chunks_read(connection: *Connection, buffer: []u8) ![]const u8 {
    var size_total: usize = 0;
    while (true) {
        const size_line = try connection.read_line();
        const extension = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const digits = std.mem.trim(u8, size_line[0..extension], " \t");
        const size = std.fmt.parseInt(u32, digits, 16) catch return error.BadReply;
        if (size == 0) break;
        if (size_total + size > buffer.len) return error.ReplyTooLarge;
        try connection.read_into(buffer[size_total..][0..size]);
        size_total += size;
        if ((try connection.read_line()).len != 0) return error.BadReply;
    }
    for (0..trailer_lines_max) |_| {
        const line = connection.read_line() catch break;
        if (line.len == 0) break;
    }
    return buffer[0..size_total];
}

const trailer_lines_max = 64;

test response_read {
    const Case = struct { sent: []const u8, close: bool };
    const cases = [_]Case{
        // A length, the connection left open (keep-alive): the read stops at the length.
        .{ .sent = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", .close = false },
        // No length: the body runs until the server closes.
        .{ .sent = "HTTP/1.0 409 Conflict\r\nA: b\r\n\r\nleader raft-2\n", .close = true },
        // Chunks, one with an extension, then the last chunk and the trailer's end.
        .{ .sent = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=y\r\n world\r\n0\r\n\r\n", .close = false },
    };
    const expected = [_]Response{
        .{ .status = 200, .body = "hello" },
        .{ .status = 409, .body = "leader raft-2\n" },
        .{ .status = 200, .body = "hello world" },
    };
    for (cases, expected) |case, want| {
        var fds: [2]i32 = undefined;
        _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
        defer _ = linux.close(fds[1]);
        var connection = Connection{ .fd = fds[0] };
        defer connection.close();
        _ = linux.write(fds[1], case.sent.ptr, case.sent.len);
        if (case.close) _ = linux.shutdown(fds[1], linux.SHUT.WR);
        var buffer: [64]u8 = undefined;
        const response = try response_read(&connection, &buffer, "a");
        try std.testing.expectEqual(want.status, response.status);
        try std.testing.expectEqualStrings(want.body, response.body);
        // A header kept by name, any case ("A: b" in the second case).
        try std.testing.expectEqualStrings(if (case.close) "b" else "", response.header);
    }
    // Cut short by the server going away (nothing, or part of the head), or not HTTP at all.
    const failures = [_]struct { []const u8, anyerror }{
        .{ "", error.ConnectionClosed },
        .{ "HTTP/1.1 200 OK\r\nA:", error.ConnectionClosed },
        .{ "garbage, and more garbage\n", error.BadReply },
    };
    for (failures) |failure| {
        var fds: [2]i32 = undefined;
        _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
        defer _ = linux.close(fds[1]);
        var connection = Connection{ .fd = fds[0] };
        defer connection.close();
        _ = linux.write(fds[1], failure[0].ptr, failure[0].len);
        _ = linux.shutdown(fds[1], linux.SHUT.WR);
        var buffer: [64]u8 = undefined;
        try std.testing.expectError(failure[1], response_read(&connection, &buffer, ""));
    }
}

test "a body larger than the connection's buffer, by length, as one chunk, or until the close" {
    const size = 100_000;
    comptime assert(size > buffer_size);
    var body: [size]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const heads = [_][]const u8{
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{size}),
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n", .{size}),
        // Neither: the body ends as the server closes (Go's answer to an HTTP/1.0 request).
        "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n",
    };
    const tails = [_][]const u8{ "", "\r\n0\r\n\r\n", "" };
    for (heads, tails) |head, tail| {
        var fds: [2]i32 = undefined;
        _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
        var connection = Connection{ .fd = fds[0] };
        defer connection.close();
        const Writer = struct {
            fn write(fd: i32, parts: []const []const u8) void {
                var server = Connection{ .fd = fd };
                defer server.close();
                for (parts) |part| server.write_all(part) catch return;
            }
        };
        const writer = try std.Thread.spawn(.{}, Writer.write, .{ fds[1], &[_][]const u8{ head, &body, tail } });
        defer writer.join();
        var buffer: [size + 64]u8 = undefined;
        const response = try response_read(&connection, &buffer, "");
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualSlices(u8, &body, response.body);
    }
}

test "a line larger than the connection's buffer, then the next" {
    const size = 100_000;
    comptime assert(size > buffer_size);
    var line: [size]u8 = undefined;
    for (&line, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    var fds: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    var connection = Connection{ .fd = fds[0] };
    defer connection.close();
    const Writer = struct {
        fn write(fd: i32, parts: []const []const u8) void {
            var server = Connection{ .fd = fd };
            defer server.close();
            for (parts) |part| server.write_all(part) catch return;
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.write, .{ fds[1], &[_][]const u8{ &line, "\r\nnext\n" } });
    defer writer.join();
    var destination: [size + 16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &line, try connection.read_line_into(&destination));
    try std.testing.expectEqualStrings("next", try connection.read_line_into(&destination));
    // read_line too, past its buffer (red before: ReplyTooLarge).
    var fds_again: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds_again);
    var again = Connection{ .fd = fds_again[0] };
    defer again.close();
    const writer_again = try std.Thread.spawn(.{}, Writer.write, .{ fds_again[1], &[_][]const u8{ &line, "\nnext\n" } });
    defer writer_again.join();
    try std.testing.expectEqualSlices(u8, &line, try again.read_line());
    try std.testing.expectEqualStrings("next", try again.read_line());
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, connection.read_line_into(&small));
}

test "lines and exact reads over a socket pair" {
    var fds: [2]i32 = undefined;
    const paired = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(paired));
    defer _ = linux.close(fds[1]);
    var connection = Connection{ .fd = fds[0] };
    defer connection.close();
    const sent = "+OK\r\nhello\n$5\r\nworld\r\nrest";
    _ = linux.write(fds[1], sent, sent.len);
    try std.testing.expectEqualStrings("+OK", try connection.read_line());
    try std.testing.expectEqualStrings("hello", try connection.read_line());
    try std.testing.expectEqualStrings("$5", try connection.read_line());
    try std.testing.expectEqualStrings("world\r\n", try connection.read_exact(7));
    _ = linux.shutdown(fds[1], linux.SHUT.WR); // The server is done: end of file after "rest".
    var rest: [16]u8 = undefined;
    try std.testing.expectEqualStrings("rest", try connection.read_all_into(&rest));
    try std.testing.expect(unavailable(error.ConnectionClosed));
    try std.testing.expect(!unavailable(error.BadReply));
}

test "keepalive_s arms TCP keepalive on the connection, as asked" {
    // A listener on an ephemeral loopback port.
    const listener = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(listener) == .SUCCESS);
    defer _ = linux.close(@intCast(listener));
    var address = linux.sockaddr.in{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try std.testing.expect(linux.errno(linux.bind(@intCast(listener), @ptrCast(&address), @sizeOf(linux.sockaddr.in))) == .SUCCESS);
    try std.testing.expect(linux.errno(linux.listen(@intCast(listener), 1)) == .SUCCESS);
    var size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try std.testing.expect(linux.errno(linux.getsockname(@intCast(listener), @ptrCast(&address), &size)) == .SUCCESS);
    const port = std.mem.bigToNative(u16, address.port);
    for ([_]u16{ 0, 2 }) |keepalive_s| {
        var connection: Connection = undefined;
        try connection.open(.{ 127, 0, 0, 1 }, port, .{ .keepalive_s = keepalive_s });
        defer connection.close();
        var value: u32 = 0;
        var length: linux.socklen_t = @sizeOf(u32);
        _ = linux.getsockopt(connection.fd, linux.SOL.SOCKET, linux.SO.KEEPALIVE, @ptrCast(&value), &length);
        try std.testing.expectEqual(@as(u32, @intFromBool(keepalive_s > 0)), value);
        if (keepalive_s == 0) continue;
        _ = linux.getsockopt(connection.fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, @ptrCast(&value), &length);
        try std.testing.expectEqual(@as(u32, keepalive_s), value);
        _ = linux.getsockopt(connection.fd, linux.IPPROTO.TCP, linux.TCP.KEEPCNT, @ptrCast(&value), &length);
        try std.testing.expectEqual(@as(u32, 3), value);
    }
}
