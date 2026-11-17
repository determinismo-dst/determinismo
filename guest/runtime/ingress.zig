// SPDX-License-Identifier: MIT
//! det-ingress serve [<node>] <port>: connections from outside into a node's port (without one,
//! a port of the network it runs in: a test program's runner), in a deterministic machine (docs/PLAN.md: deterministic ingress; egress's inverse,
//! guest/runtime/egress.zig).
//!
//! It asks the host for connections (sdk.ingress "accept"): the live timeline's explore takes
//! them on its listener (--ingress ip:port), and each one gets a process here, connected to
//! 127.0.0.1:<port> in the node's network namespace, copying bytes both ways: the outside's
//! ("recv") written to the node, the node's sent out ("send"), an end on either side closing
//! both. Every answer is a decision on the tape, so a replay delivers the same connections and
//! bytes at the same moments with nobody outside. Idle, it asks less and less often (up to once
//! a virtual second), as egress does.
//!
//! It lives outside the node, joining the node's network for each connection only: a node whose
//! first process ends takes every process of its PID namespace with it, and a relay there went
//! too, its connections never closed outside (a client waited for good: examples/flecs-game's
//! crash, 2026-11-15). Here the node's end is its connections' (their sockets reset), each closed
//! outside as any end is, and a node started again is served again: each connection joins the
//! network of the node running then.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const nodes = @import("nodes.zig");

const idle_max_ms = 1000;
const node_name_max = 64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 3 or arguments.len > 4 or !std.mem.eql(u8, arguments[1], "serve")) {
        std.debug.print("usage: det-ingress serve [<node>] <port>\n", .{});
        std.process.exit(2);
    }
    const node: ?[]const u8 = if (arguments.len == 4) arguments[2] else null;
    if (node) |name| if (name.len == 0 or name.len > node_name_max) {
        std.debug.print("det-ingress: a node's name, up to {d} bytes\n", .{node_name_max});
        std.process.exit(2);
    };
    const port = try std.fmt.parseInt(u16, arguments[arguments.len - 1], 10);
    if (sdk.egress_channel() != .decisions) {
        // A fast VM has no tape to keep the outside's bytes on: not this way in.
        std.debug.print("det-ingress: a deterministic machine's only\n", .{});
        std.process.exit(1);
    }
    // One relay a node's port: a session opened on a timeline whose steps started one already (a
    // session's own timeline, replayed to the moment) starts none beside it.
    var lock_buffer: [48 + node_name_max]u8 = undefined;
    const lock_path = if (node) |name|
        try std.fmt.bufPrintSentinel(&lock_buffer, "/tmp/det-ingress-{s}-{d}.lock", .{ name, port }, 0)
    else
        try std.fmt.bufPrintSentinel(&lock_buffer, "/tmp/det-ingress-{d}.lock", .{port}, 0);
    const lock = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock) == .SUCCESS) {
        if (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) {
            sdk.event("ingress_ready", .{ .node = node, .port = port, .already = true });
            return;
        }
    }
    sdk.event("ingress_ready", .{ .node = node, .port = port });
    const allocator = std.heap.page_allocator;
    var reply: std.ArrayList(u8) = .empty;
    var idle_ms: u64 = 1;
    while (true) {
        reply.clearRetainingCapacity();
        const status = sdk.ingress(allocator, "accept", 0, "", &reply) catch .refused;
        if (status == .ok and reply.items.len == 4) {
            const id = std.mem.readInt(u32, reply.items[0..4], .little);
            sdk.event("ingress_open", .{ .id = id, .port = port });
            const pid = linux.fork();
            if (pid == 0) {
                connection(id, node, port);
                linux.exit_group(0);
            }
            idle_ms = 1;
        } else {
            sdk.sleep_ms(idle_ms);
            idle_ms = @min(idle_ms * 2, idle_max_ms);
        }
        // Reap what ended (no zombies piling up).
        while (true) {
            var wait_status: i32 = 0;
            const reaped = linux.waitpid(-1, &wait_status, linux.W.NOHANG);
            if (linux.errno(reaped) != .SUCCESS or reaped == 0) break;
        }
    }
}

/// One connection, in a process of its own: the node's port and the outside, bytes both ways.
fn connection(id: u32, node_name: ?[]const u8, port: u16) void {
    const allocator = std.heap.page_allocator;
    var reply: std.ArrayList(u8) = .empty;
    defer {
        reply.clearRetainingCapacity();
        _ = sdk.ingress(allocator, "close", id, "", &reply) catch {};
        sdk.event("ingress_close", .{ .id = id, .port = port });
    }
    const node = connect(node_name, port) orelse return;
    defer _ = linux.close(node);
    var chunk: [sdk.egress_send_max]u8 = undefined;
    var idle_ms: i32 = 1;
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = node, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, idle_ms);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return;
        if (ready > 0 and fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            const result = linux.read(node, &chunk, chunk.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) return; // The node closed.
            reply.clearRetainingCapacity();
            const sent = sdk.ingress(allocator, "send", id, chunk[0..result], &reply) catch return;
            if (sent != .ok) return;
            idle_ms = 1;
            continue;
        }
        reply.clearRetainingCapacity();
        const received = sdk.ingress(allocator, "recv", id, "", &reply) catch return;
        switch (received) {
            .ok => if (reply.items.len > 0) {
                if (!write_all(node, reply.items)) return;
                idle_ms = 1;
            } else {
                idle_ms = @min(idle_ms * 2, idle_max_ms);
            },
            .end, .reset, .refused => return, // The outside closed, or this machine never had it.
        }
    }
}

/// The node's port, from the network of the node running now (none: the connection closed); or,
/// without a node, the port of the network this runs in.
fn connect(node_name: ?[]const u8, port: u16) ?linux.fd_t {
    if (node_name) |node| if (!network_join(node)) return null;
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(socket);
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// This process into the network of the node running now: its main process's.
fn network_join(node: []const u8) bool {
    const pid = nodes.pid_read(node) orelse return false;
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/ns/net", .{pid}, 0) catch return false;
    const namespace = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(namespace) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(namespace));
    return linux.errno(linux.setns(@intCast(namespace), linux.CLONE.NEWNET)) == .SUCCESS;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

comptime {
    assert(idle_max_ms > 0);
}
