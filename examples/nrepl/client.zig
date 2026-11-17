// SPDX-License-Identifier: MIT
//! An nREPL client for test programs: a connection, the session it cloned, and requests with
//! their replies merged (bencode.zig is the wire format). Shared by the nREPL and
//! clojure-cli.repl examples.
const std = @import("std");
const sdk = @import("determinismo");
pub const bencode = @import("bencode.zig");

pub const Client = struct {
    connection: sdk.tcp.Connection = undefined,
    session: []const u8 = "",
    arena_state: std.heap.ArenaAllocator,
    /// Request ids count from here: distinct starts keep several clients' ids apart.
    next_id: u32 = 0,
    /// How long a read waits (virtual time) before the server counts as not answering.
    timeout_ms: u32 = 5000,
    /// The last request whose "done" came: "done" means no more messages for it (nREPL's ops
    /// reference), so one after is a property's violation.
    done_id: []const u8 = "",
    /// Whether `connection` is open (close and leave are safe either way).
    connected: bool = false,

    pub fn init() Client {
        return .{ .arena_state = .init(std.heap.page_allocator) };
    }

    /// Connects and clones a session (`clone`: every request after it is in that session).
    pub fn open(client: *Client, address: [4]u8, port: u16) !void {
        try client.connection.open(address, port, .{ .timeout_ms = client.timeout_ms });
        client.connected = true;
        errdefer client.leave();
        const reply = try client.call(&.{.{ "op", "clone" }});
        client.session = reply.new_session orelse return error.NoSession;
    }

    /// Connects and takes up `session`, made by another connection (nREPL's sessions outlive the
    /// connections that use them: an editor reconnecting, a second tool on the same REPL).
    pub fn open_session(client: *Client, address: [4]u8, port: u16, session: []const u8) !void {
        try client.connection.open(address, port, .{ .timeout_ms = client.timeout_ms });
        client.connected = true;
        client.session = try client.allocator().dupe(u8, session);
    }

    /// Done with the server: its session closed (`close`, its done awaited) as editors that
    /// tidy up do, or, one time in eight, left open as vim-fireplace and REPLy leave theirs
    /// (proof's client.close). nREPL keeps a thread per session, its sessions outliving their
    /// connections: drivers that never closed theirs had a server hold 10,177 threads at 300 s
    /// and its JVM killed for memory (trial run 1596). Safe if never opened.
    pub fn close(client: *Client) void {
        if (client.connected and client.session.len > 0 and sdk.random_below_named("nrepl.session_close", 8) != 0) {
            if (client.send(&.{.{ "op", "close" }})) |id| {
                _ = client.collect(id) catch {};
            } else |_| {}
        }
        client.leave();
    }

    /// Done with the connection alone: the session left for another to take up (a client going
    /// away mid-evaluation). Safe if never opened.
    pub fn leave(client: *Client) void {
        if (client.connected) client.connection.close();
        client.connected = false;
        client.arena_state.deinit();
        client.arena_state = .init(std.heap.page_allocator);
    }

    pub fn allocator(client: *Client) std.mem.Allocator {
        return client.arena_state.allocator();
    }

    /// Sends a request (the id and the session added); returns its id.
    pub fn send(client: *Client, fields: []const [2][]const u8) ![]const u8 {
        return client.send_in(fields, client.session);
    }

    /// Sends a request outside any session (`describe`: answered whatever a session runs).
    pub fn send_sessionless(client: *Client, fields: []const [2][]const u8) ![]const u8 {
        return client.send_in(fields, "");
    }

    fn send_in(client: *Client, fields: []const [2][]const u8, session: []const u8) ![]const u8 {
        client.next_id += 1;
        const id = try std.fmt.allocPrint(client.allocator(), "{d}", .{client.next_id});
        var all: [14][2][]const u8 = undefined;
        std.debug.assert(fields.len + 2 <= all.len);
        @memcpy(all[0..fields.len], fields);
        all[fields.len] = .{ "id", id };
        var count = fields.len + 1;
        if (session.len > 0) {
            all[count] = .{ "session", session };
            count += 1;
        }
        var buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try bencode.request_write(&writer, all[0..count]);
        try client.connection.write_all(writer.buffered());
        return id;
    }

    /// The replies to request `id` until its "done", merged.
    pub fn collect(client: *Client, id: []const u8) !Reply {
        const arena = client.allocator();
        var reply = Reply{};
        var out: std.ArrayList(u8) = .empty;
        var err: std.ArrayList(u8) = .empty;
        // A message for the request done before this one (asserted once, at this one's end).
        var late: ?bencode.Value = null;
        for (0..4096) |_| {
            const message = try bencode.read(arena, &client.connection);
            const for_id = message.string("id") orelse continue;
            if (std.mem.eql(u8, for_id, client.done_id)) {
                if (answers(message)) late = message else after_done_noted(message);
            }
            if (!std.mem.eql(u8, for_id, id)) continue;
            if (message.string("value")) |value| reply.value = value;
            if (message.string("new-session")) |session| reply.new_session = session;
            if (message.string("ns")) |ns| reply.ns = ns;
            if (message.string("ex")) |ex| reply.ex = ex;
            if (message.string("out")) |text| try out.appendSlice(arena, text);
            if (message.string("err")) |text| try err.appendSlice(arena, text);
            if (message.status_has("interrupted")) reply.interrupted = true;
            if (message.status_has("eval-error")) reply.eval_error = true;
            if (message.status_has("done")) {
                sdk.always(late == null, "nothing answers a request after its done", .{
                    .id = client.done_id,
                    .fields = if (late) |message_late| message_late.dictionary.len else 0,
                });
                client.done_id = id;
                reply.done = true;
                reply.last = message;
                reply.out = out.items;
                reply.err = err.items;
                return reply;
            }
        }
        return error.NoDone;
    }

    /// The replies to several requests in flight on this connection, each merged into its
    /// `replies` slot, until each has its done (`collect` for one drops the others' messages).
    /// A message for none of them is counted in `strays`; one for a request done already fails
    /// "nothing answers a request after its done". A read failing (a fault, or a done that never
    /// comes) leaves the slots as they were: `dropped` tells those apart.
    pub fn collect_all(client: *Client, ids: []const []const u8, replies: []Reply, strays: *u32) !void {
        std.debug.assert(ids.len == replies.len);
        while (!all_done(replies)) {
            const message = try bencode.read(client.allocator(), &client.connection);
            if (!client.route(message, ids, replies)) strays.* += 1;
        }
    }

    /// After `collect_all` failed: whether the server dropped a request's done. The connection
    /// is asked `describe` outside the session every 5 s (answered whatever the session runs):
    /// six answered over 30 s with some done still missing is a drop; a done coming meanwhile is
    /// not; a probe unanswered (a fault: the connection cut or the server stopped) fails as a read.
    pub fn dropped(client: *Client, ids: []const []const u8, replies: []Reply, strays: *u32) !bool {
        for (0..6) |_| {
            sdk.sleep_ms(5000);
            const probe = try client.send_sessionless(&.{.{ "op", "describe" }});
            while (true) {
                const message = try bencode.read(client.allocator(), &client.connection);
                const for_id = message.string("id") orelse continue;
                if (std.mem.eql(u8, for_id, probe)) {
                    if (message.status_has("done")) break;
                    continue;
                }
                if (!client.route(message, ids, replies)) strays.* += 1;
            }
            if (all_done(replies)) return false;
        }
        return true;
    }

    /// A message merged into the reply of the request it answers; false when it answers none.
    fn route(client: *Client, message: bencode.Value, ids: []const []const u8, replies: []Reply) bool {
        const arena = client.allocator();
        const for_id = message.string("id") orelse return false;
        for (ids, replies) |id, *reply| {
            if (!std.mem.eql(u8, for_id, id)) continue;
            if (reply.done and !answers(message)) {
                after_done_noted(message);
                return true;
            }
            sdk.always(!reply.done, "nothing answers a request after its done", .{ .id = id });
            if (message.string("value")) |value| reply.value = value;
            if (message.string("ns")) |ns| reply.ns = ns;
            if (message.string("ex")) |ex| reply.ex = ex;
            if (message.string("out")) |text| reply.out = std.mem.concat(arena, u8, &.{ reply.out, text }) catch reply.out;
            if (message.string("err")) |text| reply.err = std.mem.concat(arena, u8, &.{ reply.err, text }) catch reply.err;
            if (message.status_has("interrupted")) reply.interrupted = true;
            if (message.status_has("eval-error")) reply.eval_error = true;
            if (message.status_has("done")) {
                reply.done = true;
                reply.last = message;
            }
            return true;
        }
        return false;
    }

    pub fn call(client: *Client, fields: []const [2][]const u8) !Reply {
        return client.collect(try client.send(fields));
    }

    /// Evaluates `code` in this session.
    pub fn eval(client: *Client, code: []const u8) !Reply {
        return client.call(&.{ .{ "op", "eval" }, .{ "code", code } });
    }

    /// The next message from the server, whatever request it answers.
    pub fn read(client: *Client) !bencode.Value {
        return bencode.read(client.allocator(), &client.connection);
    }
};

/// A request's replies, merged: the last value, all output, the status seen; `last` is the
/// message that said "done" (where middleware puts its data).
pub const Reply = struct {
    value: ?[]const u8 = null,
    new_session: ?[]const u8 = null,
    ns: ?[]const u8 = null,
    ex: ?[]const u8 = null,
    out: []const u8 = "",
    err: []const u8 = "",
    interrupted: bool = false,
    eval_error: bool = false,
    done: bool = false,
    last: bencode.Value = .{ .integer = 0 },
};

/// Whether a message answers its request: a value, output, an error or a status. Babashka sends
/// its `changed-namespaces` (for CIDER, status `state`) after each evaluation's done: bookkeeping, noted, not
/// judged (proof rates "only output follows done" a warning), which would otherwise fail every
/// Babashka timeline and bury an answer after done (nREPL #506's exception, trial run 1601).
fn answers(message: bencode.Value) bool {
    for ([_][]const u8{ "value", "out", "err", "ex", "new-session" }) |key| {
        if (message.get(key) != null) return true;
    }
    // A status answers unless it is CIDER's tracked state alone (`["state"]`, with the
    // changed-namespaces: hunt run 1605 counted it after 16,415 Babashka evaluations' done).
    const status = message.get("status") orelse return false;
    if (status != .list) return true;
    for (status.list) |item| {
        if (item != .bytes or !std.mem.eql(u8, item.bytes, "state")) return true;
    }
    return false;
}

fn after_done_noted(message: bencode.Value) void {
    const fields = if (message == .dictionary) message.dictionary.len else 0;
    sdk.event("nrepl_message_after_done", .{ .fields = fields });
}

fn all_done(replies: []const Reply) bool {
    for (replies) |reply| if (!reply.done) return false;
    return true;
}

/// Errors that mean the server could not be reached or answered too late (faults), not that it
/// answered wrong.
pub fn unavailable(err: anyerror) bool {
    return sdk.tcp.unavailable(err) or err == error.NoDone or err == error.NoSession;
}
