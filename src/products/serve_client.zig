// SPDX-License-Identifier: MIT
//! serve's HTTP API as the products on determinismo call it (docs/PRODUCTS.md: determinismo-ci,
//! determinismo-sandbox): curl, one request a call, JSON in and out. The products are clients
//! of serve and nothing else: the machines (/machines) and runs (/runs) are its.
const std = @import("std");

/// serve's URL when no `--serve` names one: `DETERMINISMO_SERVE` (a serve on another port or
/// host, said once for every command of a shell), else the local default.
pub fn url_default() []const u8 {
    if (std.c.getenv("DETERMINISMO_SERVE")) |value| {
        if (std.mem.span(value).len > 0) return std.mem.span(value);
    }
    return "http://127.0.0.1:7878";
}

pub const Client = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// serve's URL, e.g. http://127.0.0.1:7878.
    url: []const u8,
    /// The largest reply read (curl's output): a reply past it ends the call with
    /// StreamTooLong. determinismo-ci's --reply-max.
    reply_max: usize = reply_max_default,

    pub const Reply = struct { status: u16, body: []const u8 };

    /// A request: its status and body (an HTTP error is a reply, not an error).
    pub fn call(client: Client, method: []const u8, path: []const u8, body: ?[]const u8) !Reply {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(client.arena, &.{ "curl", "-sS", "-X", method, "-H", "Content-Type: application/json", "-w", "\n%{http_code}" });
        // The body from a file: as an argument it was bounded by the kernel's (a test list of
        // 2,141 names, 150 KB, failed to start curl: SystemResources).
        var body_path: ?[]const u8 = null;
        defer if (body_path) |file| std.Io.Dir.cwd().deleteFile(client.io, file) catch {};
        if (body) |text| {
            var unique: u64 = 0;
            std.Io.random(client.io, std.mem.asBytes(&unique));
            const file = try std.fmt.allocPrint(client.arena, "/tmp/determinismo-client-{x:0>16}.body", .{unique});
            try std.Io.Dir.cwd().writeFile(client.io, .{ .sub_path = file, .data = text });
            body_path = file;
            try argv.appendSlice(client.arena, &.{ "--data-binary", try std.fmt.allocPrint(client.arena, "@{s}", .{file}) });
        }
        try argv.append(client.arena, try std.fmt.allocPrint(client.arena, "{s}{s}", .{ client.url, path }));
        const result = try std.process.run(client.arena, client.io, .{ .argv = argv.items, .stdout_limit = .limited(client.reply_max) });
        if (!result.term.success()) return error.ServeUnreachable;
        const newline = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.BadReply;
        const status = std.fmt.parseInt(u16, std.mem.trim(u8, result.stdout[newline + 1 ..], " \r\n"), 10) catch return error.BadReply;
        return .{ .status = status, .body = result.stdout[0..newline] };
    }

    /// A request whose reply must be 2xx: its body as `T` (JSON), or error.Refused (its body
    /// printed).
    pub fn json(client: Client, comptime T: type, method: []const u8, path: []const u8, body: ?[]const u8) !T {
        const reply = try client.call(method, path, body);
        if (reply.status / 100 != 2) {
            std.debug.print("serve refused {s} {s} ({d}): {s}\n", .{ method, path, reply.status, reply.body });
            return error.Refused;
        }
        return std.json.parseFromSliceLeaky(T, client.arena, reply.body, .{ .ignore_unknown_fields = true });
    }

    pub const Exec = struct { status: i64 = -1, output: []const u8 = "", truncated: bool = false };

    pub fn exec(client: Client, machine: u32, node: []const u8, command: []const u8, timeout_s: u32) !Exec {
        const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{ .node = node, .command = command, .timeout_s = timeout_s }, .{})});
        return client.json(Exec, "POST", try std.fmt.allocPrint(client.arena, "/machines/{d}/exec", .{machine}), body);
    }

    pub fn checkpoint(client: Client, machine: u32) ![]const u8 {
        const Saved = struct { checkpoint: []const u8 = "" };
        return (try client.json(Saved, "POST", try std.fmt.allocPrint(client.arena, "/machines/{d}/checkpoint", .{machine}), null)).checkpoint;
    }

    pub fn delete(client: Client, machine: u32) !void {
        _ = try client.call("DELETE", try std.fmt.allocPrint(client.arena, "/machines/{d}", .{machine}), null);
    }

    /// Whether a checkpoint is still on serve's disk.
    pub fn checkpoint_exists(client: Client, reference: []const u8) !bool {
        const reply = try client.call("GET", try std.fmt.allocPrint(client.arena, "/checkpoints/{s}", .{reference}), null);
        return reply.status == 200;
    }

    /// Waits for a run to end. Its output stays on serve: fetched here as well, a CI run's 119 MB
    /// passed the client's 64 MB read and ended determinismo-ci with StreamTooLong after the run
    /// had ended well (jank's run 2202), its verdicts never printed; nobody read it.
    pub fn run_wait(client: Client, run: u32, poll_ms: u64) !void {
        const Run = struct { state: []const u8 = "" };
        while (true) {
            const found = try client.json(Run, "GET", try std.fmt.allocPrint(client.arena, "/runs/{d}", .{run}), null);
            if (!std.mem.eql(u8, found.state, "running")) return;
            sleep_ms(poll_ms);
        }
    }
};

pub const reply_max_default: usize = 64 << 20;

pub fn sleep_ms(ms: u64) void {
    const linux = std.os.linux;
    const pause: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}
