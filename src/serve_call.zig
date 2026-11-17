// SPDX-License-Identifier: MIT
//! A call to serve's API for a session's machine (sdk.serve: a program or its REPL in the
//! guest starting runs and following them): one HTTP/1.1 request to serve, on this host
//! (`--serve-url http://127.0.0.1:<port>`), its status and body. The VM answers the guest's
//! decisions with them and keeps them on the tape (vm.zig), so a replay never calls again.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("core").vm;

/// What the guest gets of a reply at most (sdk.serve_reply_max): the rest is cut.
pub const reply_size_max = VM.serve_reply_size_max;
const response_size_max = 1 << 20;
/// How long serve may take, wall time: the machine waits meanwhile.
const timeout_s = 60;

pub const Reply = VM.ServeReply;

/// The guest's request ({"serve":{"method","path","body"}}) sent to serve at `url`.
pub fn call(arena: std.mem.Allocator, url: []const u8, event: []const u8) !Reply {
    const Request = struct { serve: struct { method: []const u8, path: []const u8, body: ?std.json.Value = null } };
    const request = std.json.parseFromSliceLeaky(Request, arena, event, .{ .ignore_unknown_fields = true }) catch
        return .{ .status = 400, .body = "{\"error\":\"not a request: {\\\"serve\\\":{method, path, body}}\"}" };
    const asked = request.serve;
    if (asked.path.len == 0 or asked.path[0] != '/') return .{ .status = 400, .body = "{\"error\":\"a path starts with /\"}" };
    // A session's own routes wait on the machine that asks: it would wait for itself.
    if (std.mem.startsWith(u8, asked.path, "/sessions")) {
        return .{ .status = 403, .body = "{\"error\":\"sessions are driven from outside the machine\"}" };
    }
    const body = if (asked.body) |value| try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})}) else "";
    const address = try address_parse(url);
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const timeout = linux.timeval{ .sec = timeout_s, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));
    if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return .{ .status = 503, .body = "{\"error\":\"serve is not answering\"}" };
    }
    const head = try std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\nHost: serve\r\nContent-Type: application/json\r\n" ++
        "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ asked.method, asked.path, body.len });
    try write_all(fd, head);
    try write_all(fd, body);
    var response: std.ArrayList(u8) = .empty;
    var chunk: [16 << 10]u8 = undefined;
    while (response.items.len < response_size_max) {
        const result = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .{ .status = 504, .body = "{\"error\":\"serve did not answer in time\"}" },
        }
        if (result == 0) break;
        try response.appendSlice(arena, chunk[0..result]);
    }
    return response_parse(response.items);
}

/// "http://127.0.0.1:7879" as an address (serve on this host).
fn address_parse(url: []const u8) !linux.sockaddr.in {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.BadServeUrl;
    const rest = std.mem.trimEnd(u8, url[prefix.len..], "/");
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadServeUrl;
    const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.BadServeUrl;
    var octets: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, rest[0..colon], '.');
    for (&octets) |*octet| octet.* = std.fmt.parseInt(u8, parts.next() orelse return error.BadServeUrl, 10) catch
        return error.BadServeUrl;
    if (parts.next() != null) return error.BadServeUrl;
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(octets) };
}

/// Its status line's code and what follows the headers (serve closes the connection after it).
fn response_parse(response: []const u8) Reply {
    const bad: Reply = .{ .status = 502, .body = "{\"error\":\"serve's answer was not HTTP\"}" };
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return bad;
    const space = std.mem.indexOfScalar(u8, response, ' ') orelse return bad;
    if (space + 4 > response.len) return bad;
    const status = std.fmt.parseInt(u16, response[space + 1 .. space + 4], 10) catch return bad;
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return bad;
    const body = response[end + 4 ..];
    return .{ .status = status, .body = body[0..@min(body.len, reply_size_max)] };
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

test response_parse {
    const reply = response_parse("HTTP/1.1 201 Created\r\nContent-Length: 9\r\nConnection: close\r\n\r\n{\"id\":12}");
    try std.testing.expectEqual(201, reply.status);
    try std.testing.expectEqualStrings("{\"id\":12}", reply.body);
    try std.testing.expectEqual(502, response_parse("nonsense").status);
}

test address_parse {
    const address = try address_parse("http://127.0.0.1:7879");
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 7879), address.port);
    try std.testing.expectError(error.BadServeUrl, address_parse("127.0.0.1:7879"));
}

test "a session's own routes are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const reply = try call(arena_state.allocator(), "http://127.0.0.1:1", "{\"serve\":{\"method\":\"POST\",\"path\":\"/sessions/1/step\"}}");
    try std.testing.expectEqual(403, reply.status);
}
