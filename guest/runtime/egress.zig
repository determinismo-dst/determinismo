// SPDX-License-Identifier: MIT
//! det-egress serve <port>: the way out of the machine for what a node calls outside it (an
//! agent's model, an external API: docs/PRODUCTS.md, egress), run in the node (`det-nodes exec
//! <node> det-egress serve 3128`): an HTTP proxy on 127.0.0.1:<port> for CONNECT (programs reach
//! it with HTTPS_PROXY=http://127.0.0.1:<port>; TLS stays end to end, the host only carries
//! bytes).
//!
//! Each connection, once its CONNECT is read, is an `egress_open` event (its id, target, and
//! the FIFO its replies come through); the client's bytes go out as `egress_data` events (in
//! parts), its end as `egress_close`. The host (serve's machine, its allowlist) makes the real
//! connection and writes frames into the FIFO with the agent's det:send: [kind u8][size u32 le]
//! [bytes]: kind 'O' connected (the client told 200), 'D' data, 'C' closed (or refused).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

/// A part of the client's bytes in one event (base64 in the event's JSON).
const part_max = 2048;
const request_max = 16 * 1024;
const connections_max = 256;
const fifo_directory = "/opt/determinismo/records";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 3 or !std.mem.eql(u8, arguments[1], "serve")) {
        std.debug.print("usage: det-egress serve <port>\n", .{});
        std.process.exit(2);
    }
    const port = try std.fmt.parseInt(u16, arguments[2], 10);
    const listener = listen(port) catch |err| switch (err) {
        // A proxy serves the port already: the one a machine restored from a checkpoint (a
        // fork's) brought with it. It is the one used; the host's relay is what was missing.
        error.AddressInUse => {
            sdk.event("egress_ready", .{ .port = port, .already = true });
            return;
        },
        else => return err,
    };
    sdk.event("egress_ready", .{ .port = port });
    // A deterministic machine's connections go through egress decisions (the VM connects,
    // replays answer from the tape); a fast VM's through the host's relay.
    const channel = sdk.egress_channel();
    // Faults at the boundary, a deterministic machine's: how many connections in eight fail,
    // drawn per timeline (none in a quarter of them; the bandit learns which rates pay).
    const fault_eighths: u64 = if (channel == .decisions) sdk.random_config("egress.fault_eighths", 4) else 0;
    var next: u32 = 1;
    while (true) {
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) == .INTR) continue;
        if (linux.errno(accepted) != .SUCCESS) continue;
        const id = next;
        next += 1;
        const pid = linux.fork();
        if (pid == 0) {
            _ = linux.close(listener);
            switch (channel) {
                .relay => connection(@intCast(accepted), port, id),
                .decisions => connection_deterministic(@intCast(accepted), id, fault_eighths),
            }
            linux.exit_group(0);
        }
        _ = linux.close(@intCast(accepted));
        // Reap what ended (no zombies piling up).
        while (true) {
            var status: i32 = 0;
            const reaped = linux.waitpid(-1, &status, linux.W.NOHANG);
            if (linux.errno(reaped) != .SUCCESS or reaped == 0) break;
        }
    }
}

/// One proxied connection, in a process of its own.
fn connection(client: linux.fd_t, port: u16, id: u32) void {
    var request: [request_max]u8 = undefined;
    var used: usize = 0;
    // The CONNECT request and its headers, to the blank line.
    const head_end = while (used < request.len) {
        const result = linux.read(client, request[used..].ptr, request.len - used);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        used += result;
        if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |at| break at + 4;
    } else return;
    const line_end = std.mem.indexOf(u8, request[0..head_end], "\r\n") orelse return;
    var words = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    const method = words.next() orelse return;
    const target = words.next() orelse return;
    if (!std.mem.eql(u8, method, "CONNECT")) {
        write_all(client, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
        return;
    }
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return;
    const host = target[0..colon];
    const target_port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch return;
    var fifo_buffer: [128]u8 = undefined;
    const fifo = std.fmt.bufPrintSentinel(&fifo_buffer, "{s}/.egress-{d}-{d}", .{ fifo_directory, port, id }, 0) catch return;
    _ = linux.unlink(fifo);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o666, 0)) != .SUCCESS) return;
    defer _ = linux.unlink(fifo);
    // Read and write: never an end of input when the agent's write closes.
    const opened = linux.open(fifo, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const replies: linux.fd_t = @intCast(opened);
    sdk.event("egress_open", .{ .id = id, .port = port, .host = host, .target_port = target_port, .fifo = fifo });
    defer sdk.event("egress_close", .{ .id = id, .port = port });
    // Bytes the client sent past its request's head: the tunnel's first.
    var connected = false;
    var early: []const u8 = request[head_end..used];
    var frames: std.ArrayList(u8) = .empty;
    var frame_buffer: [64 * 1024]u8 = undefined;
    var chunk: [part_max]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = replies, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = client, .events = if (connected) linux.POLL.IN else 0, .revents = 0 },
        };
        const ready = linux.poll(&fds, fds.len, -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return;
        if (fds[0].revents & linux.POLL.IN != 0) {
            const result = linux.read(replies, &frame_buffer, frame_buffer.len);
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            frames.appendSlice(std.heap.page_allocator, frame_buffer[0..result]) catch return;
            // Whole frames: kind, size, bytes.
            while (frames.items.len >= 5) {
                const size = std.mem.readInt(u32, frames.items[1..5], .little);
                if (frames.items.len < 5 + size) break;
                const kind = frames.items[0];
                const bytes = frames.items[5 .. 5 + size];
                switch (kind) {
                    'O' => {
                        connected = true;
                        write_all(client, "HTTP/1.1 200 Connection established\r\n\r\n");
                        if (early.len > 0) {
                            emit_data(id, port, early);
                            early = "";
                        }
                    },
                    'D' => write_all(client, bytes),
                    'C' => {
                        if (!connected) write_all(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                        return;
                    },
                    else => return,
                }
                const rest = frames.items.len - 5 - size;
                std.mem.copyForwards(u8, frames.items[0..rest], frames.items[5 + size ..]);
                frames.items.len = rest;
            }
        }
        if (fds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const result = linux.read(client, &chunk, chunk.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            emit_data(id, port, chunk[0..result]);
        }
    }
}

/// One proxied connection in a deterministic machine: its CONNECT read, then the client's bytes
/// sent and the server's received as egress decisions (sdk.egress), the client polled between
/// them in virtual time (longer as the connection idles: an idle keep-alive connection costs
/// few exits).
const EgressFault = enum { none, refused, reset_after_reply, slow_replies };

fn connection_deterministic(client: linux.fd_t, id: u32, fault_eighths: u64) void {
    var request: [request_max]u8 = undefined;
    var used: usize = 0;
    const head_end = while (used < request.len) {
        const result = linux.read(client, request[used..].ptr, request.len - used);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        used += result;
        if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n")) |at| break at + 4;
    } else return;
    const line_end = std.mem.indexOf(u8, request[0..head_end], "\r\n") orelse return;
    var words = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    const method = words.next() orelse return;
    const target = words.next() orelse return;
    if (!std.mem.eql(u8, method, "CONNECT")) {
        write_all(client, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
        return;
    }
    // This connection's fault, if one: refused before it reaches out, reset once the first of
    // the server's bytes reached the client, or each reply held a drawn while (virtual time).
    const fault: EgressFault = if (fault_eighths > 0 and sdk.random_below_named("egress.fault", 8) < fault_eighths)
        @fromBackingInt(@intCast(1 + sdk.random_below_named("egress.fault_kind", 3)))
    else
        .none;
    if (fault != .none) sdk.event("egress_fault", .{ .id = id, .target = target, .kind = @tagName(fault) });
    if (fault == .refused) {
        write_all(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    }
    const slow_ms: u64 = if (fault == .slow_replies) 50 + sdk.random_below_named("egress.fault_delay_ms", 4000) else 0;
    const allocator = std.heap.page_allocator;
    var reply: std.ArrayList(u8) = .empty;
    const opened = sdk.egress(allocator, "open", id, target, "", &reply) catch .refused;
    if (opened != .ok) {
        write_all(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    }
    defer _ = sdk.egress(allocator, "close", id, "", "", &reply) catch {};
    write_all(client, "HTTP/1.1 200 Connection established\r\n\r\n");
    if (!send_parts(allocator, id, request[head_end..used], &reply)) return;
    var chunk: [sdk.egress_send_max]u8 = undefined;
    var idle_ms: i32 = 1;
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = client, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, idle_ms);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return;
        if (ready > 0 and fds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const result = linux.read(client, &chunk, chunk.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            if (!send_parts(allocator, id, chunk[0..result], &reply)) return;
            idle_ms = 1;
            continue;
        }
        reply.clearRetainingCapacity();
        const received = sdk.egress(allocator, "recv", id, "", "", &reply) catch return;
        switch (received) {
            .ok => {
                if (reply.items.len > 0) {
                    if (slow_ms > 0) sdk.sleep_ms(slow_ms);
                    write_all(client, reply.items);
                    // The connection reset under the client (its socket closed: RST with data
                    // unread, a close otherwise), the server's side closed too.
                    if (fault == .reset_after_reply) {
                        const linger: extern struct { onoff: i32, seconds: i32 } = .{ .onoff = 1, .seconds = 0 };
                        _ = linux.setsockopt(client, linux.SOL.SOCKET, linux.SO.LINGER, std.mem.asBytes(&linger), @sizeOf(@TypeOf(linger)));
                        return;
                    }
                    idle_ms = 1;
                } else idle_ms = @min(idle_ms * 2, 1000);
            },
            .end, .reset, .refused => return,
        }
    }
}

fn send_parts(allocator: std.mem.Allocator, id: u32, bytes: []const u8, reply: *std.ArrayList(u8)) bool {
    var at: usize = 0;
    while (at < bytes.len) : (at += sdk.egress_send_max) {
        const part = bytes[at..@min(bytes.len, at + sdk.egress_send_max)];
        reply.clearRetainingCapacity();
        const sent = sdk.egress(allocator, "send", id, "", part, reply) catch return false;
        if (sent != .ok) return false;
    }
    return true;
}

fn emit_data(id: u32, port: u16, bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) : (at += part_max) {
        const part = bytes[at..@min(bytes.len, at + part_max)];
        var encoded: [std.base64.standard.Encoder.calcSize(part_max)]u8 = undefined;
        const text = std.base64.standard.Encoder.encode(&encoded, part);
        sdk.event("egress_data", .{ .id = id, .port = port, .data = text });
    }
}

fn listen(port: u16) !linux.fd_t {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    switch (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        .ADDRINUSE => {
            _ = linux.close(fd);
            return error.AddressInUse;
        },
        else => return error.BindFailed,
    }
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return,
        }
    }
}

comptime {
    assert(connections_max > 0);
}
