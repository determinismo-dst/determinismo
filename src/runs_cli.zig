// SPDX-License-Identifier: MIT
//! `determinismo runs <command>`: the host's runs from a terminal, through serve's HTTP API
//! (serve.zig), as Antithesis's Snouty CLI works with its runs: for people and agents in a shell.
//!
//!   runs list                                         every run: id, state, system, scenario
//!   runs show <id> [--json]                           its state, progress and summary
//!   runs properties <id> [--details]                  each property's verdict; with --details,
//!                                                     failing ones' first examples (timeline, s)
//!   runs logs <id> <timeline> <seconds> [--window <s>] [--limit <n>]   the timeline's events
//!                                                     leading up to that moment (the last 10 s,
//!                                                     its last 200 lines by default), its
//!                                                     ancestors' included (a tree's timeline
//!                                                     begins inside them)
//!   runs export <id> <timeline> <seconds | failure> [--property <message>] [--before <s>]
//!                                                     [--after <s>] [--html]   the
//!                                                     timeline's window around that moment
//!                                                     (failure: its first failed assertion,
//!                                                     of that property if named)
//!                                                     (30 s before, 5 after by default) as one
//!                                                     JSON document on standard output, for a
//!                                                     viewer or an analysis without the host:
//!                                                     its events, ancestors' included, the run
//!                                                     (request, record), its properties,
//!                                                     causality analyses and the timeline's
//!                                                     automations; --html: a page that plays
//!                                                     it back (ui/export.html, the document
//!                                                     embedded)
//!   runs search <id> '<condition>' [--limit <n>] [--count] [--follow]   (query.zig's
//!                                                     conditions; --follow: new matches as
//!                                                     timelines finish, until the run ends or
//!                                                     the limit is printed)
//!   runs stream <id> [--property <name>]... [--json]  its properties as they change: new ones,
//!                                                     failed ones (with a sample: timeline and
//!                                                     moment, for `runs logs`), then every
//!                                                     verdict once it ends (serve's
//!                                                     /runs/<id>/stream)
//!   runs exec <id> <timeline> (<seconds> | --until '<condition>' [--rewind-ms n])
//!             --node <node> '<command>'               a command at that moment of a replay
//!                                                     (--node runner: the runner's), the
//!                                                     run's own inputs (memory, faults, ...)
//!   runs start (--program <path> | --compose <path>) [--scenario s] [--seed n] [--branches n]
//!                                    [--time-budget 2h] [--memory-mib n] [--verify-replays n]
//!   runs stop <id>
//!   runs logged <id>                                 what its nodes logged as errors (a panic,
//!                                                     fatal, exception, ERROR level...), as
//!                                                     templates by node, panics first: what no
//!                                                     property reads (serve's /runs/<id>/logged)
//!   runs sql <id> ('<select>' | -)                   one SELECT on its events database, the
//!                                                     rows tab-separated under their columns'
//!                                                     names; `-` reads it from stdin, where a
//!                                                     heredoc needs no quoting (through ssh)
//!
//! `--url http://host:port` (or DETERMINISMO_URL): serve's address, http://127.0.0.1:7878 by
//! default. Exit status: 0, 1 when nothing matched (search, sql), 2 for a usage or API error.
const std = @import("std");
const linux = std.os.linux;

const url_default = "http://127.0.0.1:7878";
const response_size_max = 256 << 20;

const Client = struct {
    address: [4]u8,
    port: u16,
    arena: std.mem.Allocator,

    fn init(arena: std.mem.Allocator, url: []const u8) !Client {
        const rest = if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else url;
        const host_end = std.mem.indexOfScalar(u8, rest, ':') orelse return error.BadUrl;
        const host = rest[0..host_end];
        const port_text = std.mem.trimEnd(u8, rest[host_end + 1 ..], "/");
        var address: [4]u8 = .{ 127, 0, 0, 1 };
        if (!std.mem.eql(u8, host, "localhost")) {
            var parts = std.mem.splitScalar(u8, host, '.');
            for (&address) |*byte| byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadUrl, 10);
        }
        return .{ .address = address, .port = try std.fmt.parseInt(u16, port_text, 10), .arena = arena };
    }

    /// One request (HTTP/1.0, the connection closed after): the body of a 2xx answer, or the
    /// error the API gave (printed).
    fn call(client: *const Client, method: []const u8, path: []const u8, body: ?[]const u8) ![]const u8 {
        const fd_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_result) != .SUCCESS) return error.Socket;
        const fd: linux.fd_t = @intCast(fd_result);
        defer _ = linux.close(fd);
        var target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, client.port), .addr = @bitCast(client.address) };
        if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            std.debug.print("determinismo runs: no serve at {d}.{d}.{d}.{d}:{d} (--url, DETERMINISMO_URL)\n", .{
                client.address[0], client.address[1], client.address[2], client.address[3], client.port,
            });
            return error.NoServe;
        }
        const payload = body orelse "";
        const head = try std.fmt.allocPrint(client.arena, "{s} {s} HTTP/1.0\r\nHost: determinismo\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ method, path, payload.len });
        try write_all(fd, head);
        try write_all(fd, payload);
        var response: std.ArrayList(u8) = .empty;
        while (response.items.len < response_size_max) {
            try response.ensureUnusedCapacity(client.arena, 1 << 16);
            const free = response.unusedCapacitySlice();
            const read = linux.read(fd, free.ptr, free.len);
            if (linux.errno(read) != .SUCCESS) return error.ReadFailed;
            if (read == 0) break;
            response.items.len += read;
        }
        const text = response.items;
        const header_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.BadResponse;
        const status_start = (std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadResponse) + 1;
        const status = std.fmt.parseInt(u16, text[status_start..][0..3], 10) catch return error.BadResponse;
        const answer = text[header_end + 4 ..];
        if (status / 100 != 2) {
            std.debug.print("determinismo runs: {s} {s}: {d} {s}\n", .{ method, path, status, answer });
            return error.ApiError;
        }
        return answer;
    }
};

/// A streamed answer, a line at a time as they come (POST /runs/<id>/stream): `each` gets every
/// line of a 2xx answer, until the server closes it.
fn stream_lines(
    client: *const Client,
    path: []const u8,
    body: []const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8) anyerror!void,
) !void {
    const fd_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_result) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(fd_result);
    defer _ = linux.close(fd);
    var target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, client.port), .addr = @bitCast(client.address) };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.NoServe;
    const head = try std.fmt.allocPrint(client.arena, "POST {s} HTTP/1.0\r\nHost: determinismo\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ path, body.len });
    try write_all(fd, head);
    try write_all(fd, body);
    var pending: std.ArrayList(u8) = .empty;
    var headers_done = false;
    var buffer: [1 << 16]u8 = undefined;
    while (true) {
        const read = linux.read(fd, &buffer, buffer.len);
        if (linux.errno(read) != .SUCCESS) return error.ReadFailed;
        if (read == 0) return;
        try pending.appendSlice(client.arena, buffer[0..read]);
        if (!headers_done) {
            const end = std.mem.indexOf(u8, pending.items, "\r\n\r\n") orelse continue;
            const status_start = (std.mem.indexOfScalar(u8, pending.items, ' ') orelse return error.BadResponse) + 1;
            const status = std.fmt.parseInt(u16, pending.items[status_start..][0..3], 10) catch return error.BadResponse;
            if (status / 100 != 2) {
                std.debug.print("determinismo runs: POST {s}: {d} {s}\n", .{ path, status, pending.items[end + 4 ..] });
                return error.ApiError;
            }
            const rest = pending.items[end + 4 ..];
            std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
            pending.items.len = rest.len;
            headers_done = true;
        }
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            try each(context, pending.items[0..newline]);
            const rest = pending.items[newline + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
            pending.items.len = rest.len;
        }
    }
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const written = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
        done += written;
    }
}

pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    var url: []const u8 = if (std.c.getenv("DETERMINISMO_URL")) |value| std.mem.span(value) else url_default;
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--url") and index + 1 < arguments.len) {
            url = arguments[index + 1];
            index += 1;
        } else try words.append(arena, arguments[index]);
    }
    if (words.items.len == 0) return error.Usage;
    const client = try Client.init(arena, url);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const command = words.items[0];
    const rest = words.items[1..];
    const eql = std.mem.eql;
    if (eql(u8, command, "list")) return list(&client, out);
    if (eql(u8, command, "show")) return show(&client, out, rest);
    if (eql(u8, command, "properties")) return properties(&client, out, rest);
    if (eql(u8, command, "logs")) return logs(&client, out, rest);
    if (eql(u8, command, "export")) return export_window(&client, out, rest);
    if (eql(u8, command, "search")) return search(&client, out, rest);
    if (eql(u8, command, "stream")) return stream(&client, out, rest);
    if (eql(u8, command, "exec")) return exec(&client, out, rest);
    if (eql(u8, command, "start")) return start(&client, out, rest);
    if (eql(u8, command, "stop")) return stop(&client, out, rest);
    if (eql(u8, command, "sql")) return sql(&client, out, rest);
    if (eql(u8, command, "logged")) return logged(&client, out, rest);
    return error.Usage;
}

fn parse(client: *const Client, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, client.arena, text, .{});
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn string(value: ?std.json.Value) []const u8 {
    const known = value orelse return "";
    return switch (known) {
        .string => |text| text,
        else => "",
    };
}

fn integer(value: ?std.json.Value) u64 {
    const known = value orelse return 0;
    return switch (known) {
        .integer => |number| @intCast(@max(0, number)),
        .float => |number| @intFromFloat(@max(0, number)),
        // Past i64 (a seed): std.json keeps the digits.
        .number_string => |digits| std.fmt.parseInt(u64, digits, 10) catch 0,
        else => 0,
    };
}

fn run_id(rest: []const []const u8) !u32 {
    if (rest.len == 0) return error.Usage;
    return std.fmt.parseInt(u32, rest[0], 10);
}

/// "12.5" seconds of virtual time, in nanoseconds.
fn seconds_ns(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.Usage;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

fn list(client: *const Client, out: *std.Io.Writer) !u8 {
    const runs = try parse(client, try client.call("GET", "/runs", null));
    if (runs != .array) return error.BadResponse;
    try out.print("{s:>5}  {s:<12} {s:<40} {s}\n", .{ "id", "state", "system", "scenario" });
    for (runs.array.items) |entry| {
        try out.print("{d:>5}  {s:<12} {s:<40} {s}\n", .{
            integer(field(entry, "id")),    string(field(entry, "state")),
            string(field(entry, "system")), string(field(entry, "scenario")),
        });
    }
    return 0;
}

fn show(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const text = try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}", .{id}), null);
    if (rest.len > 1 and std.mem.eql(u8, rest[1], "--json")) {
        try out.print("{s}\n", .{text});
        return 0;
    }
    const value = try parse(client, text);
    const asked = field(value, "run") orelse std.json.Value{ .null = {} };
    try out.print("run {d}: {s}", .{ id, string(field(value, "state")) });
    if (field(value, "status")) |status| if (status == .integer) try out.print(" (status {d})", .{status.integer});
    try out.print("\nscenario {s}", .{string(field(asked, "scenario"))});
    // The record's seed: 16 hex digits.
    if (std.fmt.parseInt(u64, string(field(asked, "seed")), 16)) |seed| {
        try out.print(", seed {d}", .{seed});
    } else |_| {}
    try out.writeByte('\n');
    if (field(value, "progress")) |progress| {
        const running = field(progress, "running");
        try out.print("timelines: {d} done, {d} failing, {d} running, generation {d}\n", .{
            integer(field(progress, "done")),
            integer(field(progress, "failing")),
            if (running) |known| (if (known == .array) known.array.items.len else 0) else 0,
            integer(field(progress, "generation")),
        });
    }
    if (field(value, "stats")) |stats| {
        try out.print("stats: {d} timelines, {d} failing, {d} behaviors, {d} events\n", .{
            integer(field(stats, "timelines")), integer(field(stats, "failing_timelines")),
            integer(field(stats, "behaviors")), integer(field(stats, "events")),
        });
    }
    return 0;
}

const Property = struct {
    type: []const u8 = "",
    message: []const u8 = "",
    status: []const u8 = "",
    timelines_hit: u64 = 0,
    timelines_failing: u64 = 0,
    location: ?[]const u8 = null,
};

fn properties(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const details = rest.len > 1 and std.mem.eql(u8, rest[1], "--details");
    const text = try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/properties", .{id}), null);
    const all = try std.json.parseFromSliceLeaky([]const Property, client.arena, text, .{ .ignore_unknown_fields = true });
    // The failing first, as the UI lists them.
    for ([_]bool{ true, false }) |failing_pass| for (all) |property| {
        const failing = std.mem.eql(u8, property.status, "failing");
        if (failing != failing_pass) continue;
        const verdict = if (failing) "FAIL" else if (std.mem.eql(u8, property.status, "passing")) "PASS" else "----";
        try out.print("{s} {s:<22} hit {d:>5}, failing {d:>5}  {s}", .{
            verdict, property.type, property.timelines_hit, property.timelines_failing, property.message,
        });
        if (property.location) |location| try out.print("  ({s})", .{location});
        try out.writeByte('\n');
        if (!details or !failing) continue;
        try examples(client, out, id, &property);
    };
    return 0;
}

/// A failing property's first failing evaluations: timeline, moment and details.
fn examples(client: *const Client, out: *std.Io.Writer, id: u32, property: *const Property) !void {
    const quoted = try quote(client.arena, property.message);
    const condition = if (std.mem.eql(u8, property.type, "unreachable"))
        try std.fmt.allocPrint(client.arena, "assert.message={s} assert.condition=true or " ++
            "antithesis_assert.message={s} antithesis_assert.hit=true", .{ quoted, quoted })
    else
        try std.fmt.allocPrint(client.arena, "assert.message={s} assert.condition=false or " ++
            "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.condition=false", .{ quoted, quoted });
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{ .condition = condition, .limit = 3 }, .{})});
    const text = client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const event = parse(client, line) catch continue;
        const at_ns = integer(field(event, "vtime_ns"));
        const assertion = field(field(event, "event") orelse continue, "assert") orelse
            field(field(event, "event") orelse continue, "antithesis_assert") orelse continue;
        const shown = if (field(assertion, "details")) |known|
            try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(known, .{})})
        else
            "";
        try out.print("     timeline {d} at {d}.{d:0>3}s  {s}\n", .{
            integer(field(event, "branch")),                at_ns / std.time.ns_per_s,
            at_ns % std.time.ns_per_s / std.time.ns_per_ms, shown[0..@min(shown.len, 300)],
        });
    }
}

/// A query condition's string (query.zig): in double quotes, backslashes and quotes escaped.
fn quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '"');
    for (text) |byte| {
        if (byte == '"' or byte == '\\') try quoted.append(arena, '\\');
        try quoted.append(arena, byte);
    }
    try quoted.append(arena, '"');
    return quoted.items;
}

test quote {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("\"a \\\"b\\\" \\\\c\"", try quote(arena_state.allocator(), "a \"b\" \\c"));
}

fn limit_of(rest: []const []const u8, default: u32) !u32 {
    for (rest, 0..) |word, at| {
        if (std.mem.eql(u8, word, "--limit") and at + 1 < rest.len) return std.fmt.parseInt(u32, rest[at + 1], 10);
    }
    return default;
}

fn has(rest: []const []const u8, flag: []const u8) bool {
    for (rest) |word| if (std.mem.eql(u8, word, flag)) return true;
    return false;
}

fn logs(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 3) return error.Usage;
    const id = try run_id(rest);
    const timeline = try std.fmt.parseInt(u32, rest[1], 10);
    const up_to_ns = try seconds_ns(rest[2]);
    const limit = try limit_of(rest[3..], 200);
    const window_ns = if (value_of(rest[3..], "--window")) |text| try seconds_ns(text) else 10 * std.time.ns_per_s;
    const up_to = @as(f64, @floatFromInt(up_to_ns)) / std.time.ns_per_s;
    const from = @as(f64, @floatFromInt(up_to_ns -| window_ns)) / std.time.ns_per_s;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = try std.fmt.allocPrint(client.arena, "vtime>={d:.6}", .{from}),
        .branch = timeline,
        .up_to_vtime = up_to,
        .limit = 1_000_000,
    }, .{})});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    // The window's last `limit` lines: what led up to the moment.
    var starts: std.ArrayList(usize) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        try starts.append(client.arena, at);
        at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len) + 1;
    }
    const first = starts.items.len -| limit;
    try events_print(client, out, if (first < starts.items.len) text[starts.items[first]..] else "");
    return 0;
}

/// A timeline's window around a moment, one JSON document (docs/PLAN.md's exports): what a
/// static viewer plays back and an analysis reads, with no host. Each part is serve's own answer,
/// embedded as it came (null where serve has none: no causality analysis yet).
fn export_window(client: *const Client, page_out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 3) return error.Usage;
    const html = has(rest[3..], "--html");
    var document: std.Io.Writer.Allocating = .init(client.arena);
    const out = if (html) &document.writer else page_out;
    const id = try run_id(rest);
    const timeline = try std.fmt.parseInt(u32, rest[1], 10);
    const moment_ns = if (std.mem.eql(u8, rest[2], "failure"))
        try failure_ns(client, id, timeline, value_of(rest[3..], "--property"))
    else
        try seconds_ns(rest[2]);
    const before_ns = if (value_of(rest[3..], "--before")) |text| try seconds_ns(text) else 30 * std.time.ns_per_s;
    const after_ns = if (value_of(rest[3..], "--after")) |text| try seconds_ns(text) else 5 * std.time.ns_per_s;
    const from_ns = moment_ns -| before_ns;
    const to_ns = moment_ns + after_ns;
    const seconds = struct {
        fn of(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
        }
    }.of;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = try std.fmt.allocPrint(client.arena, "vtime>={d:.6}", .{seconds(from_ns)}),
        .branch = timeline,
        .up_to_vtime = seconds(to_ns),
        .limit = 1_000_000,
    }, .{})});
    const events = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    const run_text = try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}", .{id}), null);
    const properties_text = client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/properties", .{id}), null) catch "null";
    const causality = client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/causality", .{id}), null) catch "null";
    const automations = client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/automations", .{id}), null) catch "";
    try out.print("{{\"format\":\"determinismo-export/1\",\"run\":{d},\"timeline\":{d},\"moment_s\":{d:.6},\"from_s\":{d:.6},\"to_s\":{d:.6},\"run_info\":", .{
        id, timeline, seconds(moment_ns), seconds(from_ns), seconds(to_ns),
    });
    try out.writeAll(json_or_null(run_text));
    try out.writeAll(",\"properties\":");
    try out.writeAll(json_or_null(properties_text));
    try out.writeAll(",\"causality\":");
    try out.writeAll(json_or_null(causality));
    // The timeline's automations: JSON lines, those of this timeline.
    try out.writeAll(",\"automations\":[");
    var first = true;
    var automation_lines = std.mem.tokenizeScalar(u8, automations, '\n');
    while (automation_lines.next()) |line| {
        const parsed = std.json.parseFromSliceLeaky(struct { timeline: ?u32 = null }, client.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.timeline != timeline) continue;
        try out.print("{s}{s}", .{ if (first) "" else ",", line });
        first = false;
    }
    try out.writeAll("],\"events\":[");
    first = true;
    var event_lines = std.mem.tokenizeScalar(u8, events, '\n');
    while (event_lines.next()) |line| {
        try out.print("{s}{s}", .{ if (first) "" else ",", line });
        first = false;
    }
    // The timeline's own failed assertions, wherever they are: a window around a moment of the
    // reader's own (the shard move a checker judges minutes later, Citus run 1892) said only "not
    // in this window", never where.
    const failures_body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = failed_condition,
        .branch = timeline,
        .limit = timeline_failures_max,
    }, .{})});
    const failures_text = client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), failures_body) catch "";
    try out.writeAll("],\"timeline_failures\":[");
    first = true;
    var failure_lines = std.mem.tokenizeScalar(u8, failures_text, '\n');
    while (failure_lines.next()) |line| {
        try out.print("{s}{s}", .{ if (first) "" else ",", line });
        first = false;
    }
    try out.writeAll("]}\n");
    if (html) try page_embed(page_out, document.written());
    return 0;
}

/// A timeline's failed assertions an export carries (each one's events: the viewer keeps each
/// message's first).
const timeline_failures_max = 500;

const export_page = @embedFile("ui/export.html");

/// The viewer with `document` in its script #determinismo-export. Each `<` written as \u003c:
/// JSON has one only inside strings, where the escape means the same, and the page's script can
/// then never be closed by a node's output (`</script>` in a log line).
fn page_embed(out: *std.Io.Writer, document: []const u8) !void {
    const marker = "/*EXPORT*/";
    const at = std.mem.indexOf(u8, export_page, marker) orelse unreachable;
    try out.writeAll(export_page[0..at]);
    var rest = std.mem.trimEnd(u8, document, "\n");
    while (std.mem.indexOfScalar(u8, rest, '<')) |index| {
        try out.writeAll(rest[0..index]);
        try out.writeAll("\\u003c");
        rest = rest[index + 1 ..];
    }
    try out.writeAll(rest);
    try out.writeAll(export_page[at + marker.len ..]);
}

test page_embed {
    var buffer: [export_page.len + 256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try page_embed(&out, "{\"text\":\"</script><b>\"}\n");
    const page = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, page, "{\"text\":\"\\u003c/script>\\u003cb>\"}</script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/*EXPORT*/") == null);
}

/// What a failed assertion is: a false condition, or an `unreachable` reached (its condition
/// true: DuckDB's "the trigger tables answer once faults stop", run 1203, whose window export
/// found no failure).
// A failure as events.zig judges one: an always (or always-or-unreachable) false, an unreachable
// reached; never a sometimes or a reachable that was false, which the export took for the failure
// (DuckDB run 1950's timeline 241: "a transaction with bound parameters committed", a sometimes
// false at 1.438 s, for Elle's failure at 182.549 s). `or` binds loosest.
const failed_condition = "assert.condition=false and assert.type=always or " ++
    "assert.condition=false and assert.type=always_or_unreachable or assert.type=unreachable and assert.condition=true";

test failed_condition {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const condition = try @import("query.zig").parse(arena, failed_condition);
    const cases = [_]struct { []const u8, bool }{
        .{ "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":false}}", true },
        .{ "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":true}}", false },
        .{ "{\"assert\":{\"type\":\"unreachable\",\"message\":\"m\",\"condition\":true}}", true },
        .{ "{\"assert\":{\"type\":\"unreachable\",\"message\":\"m\",\"condition\":false}}", false },
        .{ "{\"assert\":{\"type\":\"always_or_unreachable\",\"message\":\"m\",\"condition\":false}}", true },
        // A sometimes or a reachable false is no failure (run 1950's timeline 241 at 1.438 s).
        .{ "{\"assert\":{\"type\":\"sometimes\",\"message\":\"m\",\"condition\":false}}", false },
        .{ "{\"assert\":{\"type\":\"reachable\",\"message\":\"m\",\"condition\":false}}", false },
    };
    for (cases) |case| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, case[0], .{});
        try std.testing.expectEqual(case[1], condition.matches(.{ .value = value, .vtime_ns = 1, .seq = 1 }));
    }
}

/// The timeline's first failed assertion (of `property` when named: its message containing it):
/// its moment.
fn failure_ns(client: *const Client, id: u32, timeline: u32, property: ?[]const u8) !u64 {
    const condition = if (property) |message|
        // Contains: a page's window line may name it shorter ("no process crashes" for "no process
        // crashes: valkey-server", an analysis page's, 2026-11-08).
        try std.fmt.allocPrint(client.arena, "assert.condition=false and assert.type=always and assert.message~{f} or " ++
            "assert.condition=false and assert.type=always_or_unreachable and assert.message~{f} or " ++
            "assert.type=unreachable and assert.condition=true and assert.message~{f}", .{ std.json.fmt(message, .{}), std.json.fmt(message, .{}), std.json.fmt(message, .{}) })
    else
        failed_condition;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = condition,
        .branch = timeline,
        .limit = 1,
    }, .{})});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " ");
    if (line.len == 0) {
        std.debug.print("run {d}'s timeline {d} has no failed assertion{s}{s}\n", .{
            id, timeline, if (property != null) " of " else "", property orelse "",
        });
        return error.NoFailure;
    }
    const value = try parse(client, line);
    // An assertion judged after the fact says when it happened (assert.at_ns): the moment is
    // there, as the store's (properties_sql), not where the verdict was asserted.
    const asserted = integer(field(value, "vtime_ns"));
    const happened = at_ns_of(value) orelse return asserted;
    return if (happened < asserted) happened else asserted;
}

/// A query line's assertion's at_ns ({"vtime_ns", "event": {"assert": {..., "at_ns", "now_ns"}}}),
/// if any, in vtime: the guest's monotonic at_ns moved by the line's vtime less the monotonic now
/// beside it (the clock starts ~0.1 s after the VM: the SDK's assert_computed_at).
fn at_ns_of(line: std.json.Value) ?u64 {
    const event = field(line, "event") orelse return null;
    const holder = field(event, "assert") orelse field(event, "antithesis_assert") orelse return null;
    const at = unsigned_of(field(holder, "at_ns") orelse return null) orelse return null;
    const now = unsigned_of(field(holder, "now_ns") orelse return at) orelse return at;
    const vtime = unsigned_of(field(line, "vtime_ns") orelse return at) orelse return at;
    // A now past the line's vtime is no guest's clock (a host check's: the store's at_ns_sql).
    if (now > vtime) return at;
    return vtime - (now - @min(now, at));
}

fn unsigned_of(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

test at_ns_of {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const judged = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"branch":59,"vtime_ns":739068000000,"event":{"assert":{"type":"always","message":"Elle finds no anomaly in the history","condition":false,"details":{},"at_ns":158928868225}}}
    , .{});
    try std.testing.expectEqual(@as(?u64, 158928868225), at_ns_of(judged));
    const plain = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"branch":59,"vtime_ns":240140000000,"event":{"assert":{"type":"always","message":"no unexpected container exits","condition":false,"details":{"node":"w2"}}}}
    , .{});
    try std.testing.expectEqual(@as(?u64, null), at_ns_of(plain));
    // With the clock's now: the moment in vtime, 0.098 s later than the guest's clock said
    // (DuckDB run 1950's timeline 241: Elle's read at 138.105 s of the guest's clock, 138.203 s).
    const offset = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"branch":241,"vtime_ns":182548997838,"event":{"assert":{"type":"always","message":"Elle finds no anomaly in the history","condition":false,"details":{},"at_ns":138105038105,"now_ns":182450997838}}}
    , .{});
    try std.testing.expectEqual(@as(?u64, 138203038105), at_ns_of(offset));
    // A host check's now (srv4's monotonic clock, DuckDB run 1983): the guest's at_ns as it is.
    const host = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"branch":0,"vtime_ns":183077497201,"event":{"assert":{"type":"always","message":"Elle finds no anomaly in the history","condition":false,"details":{},"at_ns":157052964447,"now_ns":48148643824986}}}
    , .{});
    try std.testing.expectEqual(@as(?u64, 157052964447), at_ns_of(host));
}

/// A JSON document as serve answered it, or null when it answered nothing usable.
fn json_or_null(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return "null";
    return trimmed;
}

fn value_of(rest: []const []const u8, flag: []const u8) ?[]const u8 {
    for (rest, 0..) |word, at| {
        if (std.mem.eql(u8, word, flag) and at + 1 < rest.len) return rest[at + 1];
    }
    return null;
}

/// Query answers (JSON lines), one event a line: its moment, then output as text, the rest as
/// JSON.
fn events_print(client: *const Client, out: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const value = parse(client, line) catch continue;
        const at_ns = integer(field(value, "vtime_ns"));
        try out.print("{d:>5}.{d:0>3}s [{d}] ", .{
            at_ns / std.time.ns_per_s, at_ns % std.time.ns_per_s / std.time.ns_per_ms, integer(field(value, "branch")),
        });
        const event = field(value, "event") orelse {
            try out.print("{s}\n", .{line});
            continue;
        };
        if (field(event, "output")) |output| {
            try out.print("{s} {s}: {s}\n", .{ string(field(output, "source")), string(field(output, "stream")), string(field(output, "text")) });
        } else try out.print("{f}\n", .{std.json.fmt(event, .{})});
    }
}

fn search(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 2) return error.Usage;
    const id = try run_id(rest);
    const count = has(rest[2..], "--count");
    const limit = try limit_of(rest[2..], 50);
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = rest[1],
        .limit = limit,
        .output = if (count) "count" else "events",
    }, .{})});
    if (has(rest[2..], "--follow") and !count) return search_follow(client, out, id, rest[1], limit);
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    if (count) {
        try out.print("{s}", .{text});
        return 0;
    }
    try events_print(client, out, text);
    return if (std.mem.trim(u8, text, " \n").len == 0) 1 else 0;
}

/// `search --follow`: the matches, then each new one as timelines finish, until the run ended
/// (its last timelines in) or `limit` were printed (Antithesis's `runs search --follow`).
fn search_follow(client: *const Client, out: *std.Io.Writer, id: u32, condition: []const u8, limit: u32) !u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var printed: u32 = 0;
    const path = try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id});
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = condition,
        .limit = follow_matches_max,
        .output = "events",
    }, .{})});
    while (true) {
        // Its state first: a run that ended before this look has every timeline in it.
        const shown = try parse(client, try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}", .{id}), null));
        const running = std.mem.eql(u8, string(field(shown, "state")), "running");
        const text = try client.call("POST", path, body);
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (printed == limit) return 0;
            const entry = try seen.getOrPut(client.arena, line);
            if (entry.found_existing) continue;
            try events_print(client, out, line);
            try out.flush();
            printed += 1;
        }
        if (!running) return if (printed == 0) 1 else 0;
        const interval: linux.timespec = .{ .sec = follow_interval_s, .nsec = 0 };
        _ = linux.nanosleep(&interval, null);
    }
}

const follow_interval_s = 2;
const follow_matches_max = 100_000;

/// `runs stream <id>`: each event of serve's stream, a line (or its JSON, `--json`).
fn stream(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 1) return error.Usage;
    const id = try run_id(rest);
    var names: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (index < rest.len) : (index += 1) {
        if (std.mem.eql(u8, rest[index], "--property") and index + 1 < rest.len) {
            try names.append(client.arena, rest[index + 1]);
            index += 1;
        }
    }
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{ .properties = names.items }, .{})});
    const Context = struct { client: *const Client, out: *std.Io.Writer, json: bool };
    const context: Context = .{ .client = client, .out = out, .json = has(rest[1..], "--json") };
    try out.print("stream open: run {d}\n", .{id});
    try out.flush();
    try stream_lines(client, try std.fmt.allocPrint(client.arena, "/runs/{d}/stream", .{id}), body, context, struct {
        fn each(c: Context, line: []const u8) !void {
            defer c.out.flush() catch {};
            if (c.json) return c.out.print("{s}\n", .{line});
            const value = parse(c.client, line) catch return c.out.print("{s}\n", .{line});
            const kind = string(field(value, "type"));
            const data = field(value, "data") orelse return;
            if (data != .array) return;
            for (data.array.items) |property| {
                const name = string(field(property, "name"));
                const type_name = string(field(property, "type"));
                if (std.mem.eql(u8, kind, "NEW_PROPERTIES_ADDED")) {
                    try c.out.print("new       {s} \"{s}\"\n", .{ type_name, name });
                } else if (std.mem.eql(u8, kind, "PROPERTIES_FAILED")) {
                    try c.out.print("failed    {s} \"{s}\" ({d} counterexamples)\n", .{ type_name, name, integer(field(property, "counterexample_count")) });
                    if (field(property, "sample")) |sample| if (sample == .object) {
                        const at_ns = integer(field(sample, "vtime_ns"));
                        try c.out.print("  sample  timeline {d} at {d}.{d:0>3} s\n", .{
                            integer(field(sample, "timeline")), at_ns / std.time.ns_per_s, at_ns % std.time.ns_per_s / std.time.ns_per_ms,
                        });
                    };
                } else try c.out.print("{s:<9} {s} \"{s}\"\n", .{ string(field(property, "status")), type_name, name });
            }
            if (std.mem.eql(u8, kind, "RUN_FINALIZED")) try c.out.print("run finalized\n", .{});
        }
    }.each);
    return 0;
}

fn exec(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 4) return error.Usage;
    const id = try run_id(rest);
    const timeline = try std.fmt.parseInt(u32, rest[1], 10);
    var at_ns: ?u64 = null;
    var until: ?[]const u8 = null;
    var rewind_ms: ?u64 = null;
    var node: []const u8 = "runner";
    var command: ?[]const u8 = null;
    var index: usize = 2;
    while (index < rest.len) : (index += 1) {
        const flag = rest[index];
        const value = if (index + 1 < rest.len) rest[index + 1] else null;
        if (std.mem.eql(u8, flag, "--node") and value != null) {
            node = value.?;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--until") and value != null) {
            until = value.?;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--rewind-ms") and value != null) {
            rewind_ms = try std.fmt.parseInt(u64, value.?, 10);
            index += 1;
        } else if (at_ns == null and until == null and index == 2) {
            at_ns = try seconds_ns(flag);
        } else command = flag;
    }
    const asked = command orelse return error.Usage;
    if ((at_ns == null) == (until == null)) return error.Usage; // A moment, one way.
    // In a node as docker exec runs it; the runner's directly.
    const shell = if (std.mem.eql(u8, node, "runner"))
        asked
    else
        try std.fmt.allocPrint(client.arena, "det-nodes exec {s} sh -c {s}", .{ node, try shell_quote(client.arena, asked) });
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .branch = timeline,
        .at_vtime_ms = if (at_ns) |ns| ns / std.time.ns_per_ms else null,
        .until = until,
        .rewind_ms = rewind_ms,
        .exec = shell,
    }, .{ .emit_null_optional_fields = false })});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/replay", .{id}), body);
    // The replay's output: what the command printed (exec_output events), in order.
    var printed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "{\"event\":\"exec_output\"") orelse continue;
        const value = parse(client, line[at..]) catch continue;
        try out.print("{s}", .{string(field(field(value, "details") orelse continue, "text"))});
        printed = true;
    }
    if (!printed) try out.print("(no output; the replay said:)\n{s}\n", .{text[text.len -| 4000..]});
    return 0;
}

/// `text` as one shell word, in single quotes.
/// `runs sql`: serve's rows (POST /runs/<id>/sql, a JSON array of objects), a line each, its
/// cells tab-separated in the first row's column order, under a line of the columns' names.
/// `runs logged <id>`: what the nodes logged as errors (serve's GET /runs/<id>/logged), a line a
/// template: level, node, timelines, lines, the first timeline and moment, the template. Exit 1
/// when none.
fn logged(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len != 1) return error.Usage;
    const id = try run_id(rest);
    const rows = try parse(client, try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/logged", .{id}), ""));
    if (rows != .array) return error.BadResponse;
    if (rows.array.items.len == 0) return 1;
    try out.writeAll("level\tnode\ttimelines\tlines\tfirst\ttemplate\n");
    for (rows.array.items) |row| {
        const timelines = field(row, "timelines") orelse return error.BadResponse;
        const lines = field(row, "lines") orelse return error.BadResponse;
        const first = field(row, "first_timeline") orelse return error.BadResponse;
        const at = field(row, "first_vtime_ns") orelse return error.BadResponse;
        try out.print("{s}\t{s}\t", .{ string(field(row, "level")), string(field(row, "node")) });
        try cell_print(out, timelines);
        try out.writeByte('\t');
        try cell_print(out, lines);
        try out.writeAll("\t#");
        try cell_print(out, first);
        try out.writeAll(" at ");
        try cell_print(out, at);
        try out.writeAll(" ns\t");
        try cell_print(out, field(row, "template") orelse .null);
        try out.writeByte('\n');
    }
    return 0;
}

fn sql(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len != 2) return error.Usage;
    const id = try run_id(rest);
    const statement = if (std.mem.eql(u8, rest[1], "-")) try stdin_all(client.arena) else rest[1];
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{ .sql = statement }, .{})});
    const rows = try parse(client, try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/sql", .{id}), body));
    if (rows != .array) return error.BadResponse;
    if (rows.array.items.len == 0) return 1;
    const first = rows.array.items[0];
    if (first != .object) return error.BadResponse;
    const columns = first.object.keys();
    for (columns, 0..) |column, index| {
        if (index > 0) try out.writeByte('\t');
        try cell_print(out, .{ .string = column });
    }
    try out.writeByte('\n');
    for (rows.array.items) |row| {
        if (row != .object) return error.BadResponse;
        for (columns, 0..) |column, index| {
            if (index > 0) try out.writeByte('\t');
            try cell_print(out, row.object.get(column) orelse .null);
        }
        try out.writeByte('\n');
    }
    return 0;
}

/// A cell on one line: a text with its tabs, newlines and backslashes escaped (\t, \n, \\), a
/// number as it came, null empty, a nested value as its JSON.
fn cell_print(out: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => {},
        .bool => |yes| try out.writeAll(if (yes) "true" else "false"),
        .integer => |number| try out.print("{d}", .{number}),
        .float => |number| try out.print("{d}", .{number}),
        .number_string => |digits| try out.writeAll(digits),
        .string => |text| for (text) |byte| switch (byte) {
            '\t' => try out.writeAll("\\t"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\\' => try out.writeAll("\\\\"),
            else => try out.writeByte(byte),
        },
        .array, .object => try out.print("{f}", .{std.json.fmt(value, .{})}),
    }
}

test cell_print {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cell_print(&out.writer, .{ .string = "a\tb\nc\\" });
    try out.writer.writeByte('|');
    try cell_print(&out.writer, .{ .integer = -3 });
    try out.writer.writeByte('|');
    try cell_print(&out.writer, .null);
    try out.writer.writeByte('|');
    try cell_print(&out.writer, .{ .number_string = "18446744073709551615" });
    try std.testing.expectEqualStrings("a\\tb\\nc\\\\|-3||18446744073709551615", out.written());
}

/// Standard input whole (a statement), at most a response's size.
fn stdin_all(arena: std.mem.Allocator) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    while (text.items.len < response_size_max) {
        try text.ensureUnusedCapacity(arena, 1 << 16);
        const free = text.unusedCapacitySlice();
        const read = linux.read(0, free.ptr, free.len);
        if (linux.errno(read) != .SUCCESS) return error.ReadFailed;
        if (read == 0) break;
        text.items.len += read;
    }
    return text.items;
}

fn shell_quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, byte);
    }
    try quoted.append(arena, '\'');
    return quoted.items;
}

test shell_quote {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("'it'\\''s'", try shell_quote(arena_state.allocator(), "it's"));
}

fn start(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    var request: std.json.ObjectMap = .empty;
    var index: usize = 0;
    while (index + 1 < rest.len) : (index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--program")) {
            try request.put(client.arena, "program", .{ .string = value });
        } else if (eql(u8, flag, "--compose")) {
            try request.put(client.arena, "compose", .{ .string = value });
        } else if (eql(u8, flag, "--scenario")) {
            try request.put(client.arena, "scenario", .{ .string = value });
        } else if (eql(u8, flag, "--profile")) {
            try request.put(client.arena, "profile", .{ .string = value });
        } else if (eql(u8, flag, "--time-budget")) {
            try request.put(client.arena, "time_budget", .{ .string = value });
        } else if (eql(u8, flag, "--seed") or eql(u8, flag, "--branches") or eql(u8, flag, "--memory-mib") or
            eql(u8, flag, "--verify-replays"))
        {
            const name = try std.mem.replaceOwned(u8, client.arena, flag[2..], "-", "_");
            try request.put(client.arena, name, .{ .integer = try std.fmt.parseInt(i64, value, 10) });
        } else return error.Usage;
    }
    if (index != rest.len) return error.Usage;
    if (request.get("program") == null and request.get("compose") == null) return error.Usage;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(std.json.Value{ .object = request }, .{})});
    const text = try client.call("POST", "/runs", body);
    try out.print("{s}", .{text});
    return 0;
}

fn stop(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/stop", .{id}), "");
    try out.print("{s}", .{text});
    return 0;
}
