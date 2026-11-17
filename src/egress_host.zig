// SPDX-License-Identifier: MIT
//! A machine's egress, the host's side (docs/PRODUCTS.md: egress): guest/runtime/egress.zig is
//! an HTTPS proxy in a node, whose connections arrive here as the machine's events
//! (`egress_open`, `egress_data`, `egress_close`). For a target on the machine's allowlist the
//! host makes the real connection; its replies go back as frames ([kind u8][size u32 le][bytes]:
//! 'O' connected, 'D' data, 'C' closed) the guest's agent writes into the connection's FIFO
//! (det:send through the machine's control). Anything else is refused ('C' before 'O').
//!
//! One thread reads the machine's events (an offset of its own), and one more per connection
//! reads its socket. TLS stays end to end: the host carries bytes and sees none in clear. Each
//! connection's target, bytes each way and end are kept in the machine's egress.jsonl.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Machine = @import("machine.zig");

/// A frame's bytes at most: base64 of it, the FIFO's path and `action det:send` stay under a
/// FIFO's atomic write (PIPE_BUF, 4,096 bytes).
const frame_payload_max = 2048;
const connections_max = 256;

pub const Relay = struct {
    io: std.Io,
    machine: *Machine,
    /// "host" or "host:port" entries; a target matches either.
    allow: []const []const u8,
    /// Where the events were read up to: this relay's own.
    offset: u64 = 0,
    connections: [connections_max]Connection = @splat(.{}),
    log_mutex: std.Io.Mutex = .init,

    const Connection = struct {
        id: u32 = 0,
        fd: linux.fd_t = -1,
        fifo: [128]u8 = undefined,
        fifo_len: usize = 0,
        sent: u64 = 0,
        received: u64 = 0,
    };

    /// The relay's thread: the machine's events from where they stood, to its end.
    pub fn main(relay: *Relay) void {
        relay.run() catch |err| std.debug.print("[determinismo] egress relay: {s}\n", .{@errorName(err)});
    }

    fn run(relay: *Relay) !void {
        var path_buffer: [Machine.directory_max + 16]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/events.jsonl", .{relay.machine.directory()}, 0);
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(std.heap.page_allocator);
        var chunk: [64 * 1024]u8 = undefined;
        while (relay.machine.alive()) {
            const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(opened) != .SUCCESS) return error.EventsUnreadable;
            const fd: linux.fd_t = @intCast(opened);
            defer _ = linux.close(fd);
            const result = linux.pread(fd, &chunk, chunk.len, @intCast(relay.offset + pending.items.len));
            if (linux.errno(result) != .SUCCESS) return error.EventsUnreadable;
            if (result == 0) {
                sleep_ms(2);
                continue;
            }
            try pending.appendSlice(std.heap.page_allocator, chunk[0..result]);
            const last = std.mem.lastIndexOfScalar(u8, pending.items, '\n') orelse continue;
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena_state.deinit();
            var lines = std.mem.splitScalar(u8, pending.items[0..last], '\n');
            while (lines.next()) |line| relay.event(arena_state.allocator(), line);
            relay.offset += last + 1;
            const rest = pending.items.len - last - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[last + 1 ..]);
            pending.items.len = rest;
        }
    }

    fn event(relay: *Relay, arena: std.mem.Allocator, line: []const u8) void {
        if (std.mem.indexOf(u8, line, "\"egress_") == null) return;
        const Details = struct { id: u32 = 0, host: []const u8 = "", target_port: u16 = 0, fifo: []const u8 = "", data: []const u8 = "" };
        const Line = struct { event: struct { event: []const u8 = "", details: Details = .{} } = .{} };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch return;
        const name = parsed.event.event;
        const details = parsed.event.details;
        if (std.mem.eql(u8, name, "egress_open")) {
            relay.open(arena, details.id, details.host, details.target_port, details.fifo);
        } else if (std.mem.eql(u8, name, "egress_data")) {
            const connection = relay.find(details.id) orelse return;
            const bytes = arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(details.data) catch return) catch return;
            std.base64.standard.Decoder.decode(bytes, details.data) catch return;
            connection.sent += bytes.len;
            write_all(connection.fd, bytes);
        } else if (std.mem.eql(u8, name, "egress_close")) {
            const connection = relay.find(details.id) orelse return;
            _ = linux.shutdown(connection.fd, linux.SHUT.WR);
        }
    }

    fn open(relay: *Relay, arena: std.mem.Allocator, id: u32, host: []const u8, port: u16, fifo: []const u8) void {
        if (fifo.len > 128) return;
        if (!relay.allowed(host, port)) {
            relay.log(arena, .{ .id = id, .host = host, .port = port, .refused = true });
            relay.frame(fifo, 'C', "") catch {};
            return;
        }
        const name = std.Io.net.HostName.init(host) catch {
            relay.frame(fifo, 'C', "") catch {};
            return;
        };
        const stream = name.connect(relay.io, port, .{ .mode = .stream }) catch {
            relay.log(arena, .{ .id = id, .host = host, .port = port, .unreachable_ = true });
            relay.frame(fifo, 'C', "") catch {};
            return;
        };
        const slot = for (&relay.connections) |*slot| {
            if (slot.id == 0) break slot;
        } else {
            stream.close(relay.io);
            relay.frame(fifo, 'C', "") catch {};
            return;
        };
        slot.* = .{ .id = id, .fd = stream.socket.handle };
        @memcpy(slot.fifo[0..fifo.len], fifo);
        slot.fifo_len = fifo.len;
        relay.log(arena, .{ .id = id, .host = host, .port = port, .connected = true });
        relay.frame(fifo, 'O', "") catch {};
        const reader = std.Thread.spawn(.{}, Relay.socket_main, .{ relay, slot }) catch {
            relay.frame(fifo, 'C', "") catch {};
            return;
        };
        reader.detach();
    }

    /// A connection's socket to its end: each read a frame of data, then a close.
    fn socket_main(relay: *Relay, connection: *Connection) void {
        const fifo = connection.fifo[0..connection.fifo_len];
        var buffer: [frame_payload_max]u8 = undefined;
        while (true) {
            const result = linux.read(connection.fd, &buffer, buffer.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            connection.received += result;
            relay.frame(fifo, 'D', buffer[0..result]) catch break;
        }
        relay.frame(fifo, 'C', "") catch {};
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        relay.log(arena_state.allocator(), .{ .id = connection.id, .closed = true, .sent = connection.sent, .received = connection.received });
        _ = linux.close(connection.fd);
        connection.* = .{};
    }

    fn find(relay: *Relay, id: u32) ?*Connection {
        for (&relay.connections) |*connection| if (connection.id == id) return connection;
        return null;
    }

    fn allowed(relay: *const Relay, host: []const u8, port: u16) bool {
        return allow_matches(relay.allow, host, port);
    }

    /// A frame written into the connection's FIFO by the guest's agent.
    fn frame(relay: *Relay, fifo: []const u8, kind: u8, bytes: []const u8) !void {
        assert(bytes.len <= frame_payload_max);
        var raw: [5 + frame_payload_max]u8 = undefined;
        raw[0] = kind;
        std.mem.writeInt(u32, raw[1..5], @intCast(bytes.len), .little);
        @memcpy(raw[5..][0..bytes.len], bytes);
        var encoded: [std.base64.standard.Encoder.calcSize(5 + frame_payload_max)]u8 = undefined;
        const text = std.base64.standard.Encoder.encode(&encoded, raw[0 .. 5 + bytes.len]);
        var line: [Machine.action_max]u8 = undefined;
        try relay.machine.action(try std.fmt.bufPrint(&line, "det:send {s} {s}", .{ fifo, text }));
    }

    fn log(relay: *Relay, arena: std.mem.Allocator, entry: anytype) void {
        relay.log_mutex.lockUncancelable(relay.io);
        defer relay.log_mutex.unlock(relay.io);
        const text = std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(entry, .{})}) catch return;
        var path_buffer: [Machine.directory_max + 16]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/egress.jsonl", .{relay.machine.directory()}, 0) catch return;
        const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(opened) != .SUCCESS) return;
        defer _ = linux.close(@intCast(opened));
        write_all(@intCast(opened), text);
    }
};

pub const allow_matches = @import("core").egress_allow.allow_matches;

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

fn sleep_ms(ms: u64) void {
    const pause: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}
