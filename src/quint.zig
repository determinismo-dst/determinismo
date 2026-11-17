// SPDX-License-Identifier: MIT
//! `determinismo quint`: a timeline's events checked against a Quint spec (docs/QUINT.md).
//!
//!   determinismo quint --spec <Spec.qnt> --events <events.jsonl[.zst] | directory> [--branch <n>]
//!                      [--main <module>] [--invariant <name>] [--quint <command>]
//!
//! The events a program emits itself (`sdk.event(name, details)`) whose name is an action of
//! the spec are the trace: each one a step, the event's name the action, its details the
//! action's argument (a record; none for an event without details). Events of a timeline are
//! totally ordered (one vCPU, virtual time), so the trace is the system's history as it
//! happened. It is written beside the spec as a module with one run,
//!
//!   run determinismo_trace_run = init.then(transfer({ from: 0, to: 2, amount: 7 })).then(...)
//!
//! and Quint runs it (`quint test`): the trace is a behavior of the spec when every event is an
//! enabled action in the state the events before it left. The spec's own states along it are
//! kept beside it (`determinismo_trace.itf.json`, Quint's trace format): the timeline in the
//! spec's terms, and where the run stopped when an event is refused.
//!
//! With `--invariant` the spec's invariant is asked after every event: where a timeline's bug
//! shows in the spec's terms.
//!
//! Exit status: 0 the trace is a behavior of the spec (and the invariant held), 3 it is not
//! (the first event the spec refuses, or the first after which the invariant fails, is said
//! with the spec's state before it), 1 nothing could be checked.
//!
//! A check of states, as `determinismo tla` makes with TLC, does not fit Quint's simulator: a
//! run's expectation must hold for every sample, and an action cannot constrain the state it
//! leads to. Events as actions do, and one sample decides.
const std = @import("std");
const assert = std.debug.assert;
const event_files = @import("event_files.zig");

const steps_max = 1 << 16;
const events_size_max = 1 << 30;
/// Steps of one run: a chain of `.then` this long parses and evaluates in a moment; the parts
/// follow each other (each part starts from the one before).
const part_steps_max = 200;
pub const module_name = "determinismo_trace";
pub const run_name = "determinismo_trace_run";
const trace_file = module_name ++ ".qnt";
const states_file = module_name ++ ".itf.json";

const Step = struct { seq: u64, vtime_ns: u64, name: []const u8, details: ?std.json.Value };
const Trace = struct {
    steps: []const Step,
    /// Events the program emitted under names the spec has no action for.
    unnamed: u64,
};

pub fn check(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    var spec: ?[]const u8 = null;
    var events: ?[]const u8 = null;
    var branch: ?u32 = null;
    var main: ?[]const u8 = null;
    var invariant: ?[]const u8 = null;
    var quint: []const u8 = "quint";
    if (arguments.len % 2 != 0) return error.Usage;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--spec")) {
            spec = value;
        } else if (std.mem.eql(u8, flag, "--events")) {
            events = value;
        } else if (std.mem.eql(u8, flag, "--branch")) {
            branch = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--main")) {
            main = value;
        } else if (std.mem.eql(u8, flag, "--invariant")) {
            invariant = value;
        } else if (std.mem.eql(u8, flag, "--quint")) {
            quint = value;
        } else return error.Usage;
    }
    const spec_path = spec orelse return error.Usage;
    if (invariant) |name| if (!identifier(name)) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const spec_text = try cwd.readFileAlloc(io, spec_path, arena, .limited(1 << 26));
    const actions = try actions_of(arena, spec_text);
    const source = try events_read(arena, io, events orelse return error.Usage, branch);
    const trace = try trace_read(arena, source, actions);
    if (trace.steps.len == 0) {
        std.debug.print("[determinismo] no event of the timeline is named like an action of the spec " ++
            "({d} actions; {d} events under other names)\n", .{ actions.len, trace.unnamed });
        return 1;
    }
    const directory = std.fs.path.dirname(spec_path) orelse ".";
    const stem = std.fs.path.stem(spec_path);
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, trace_file }),
        .data = try trace_module(arena, main orelse stem, stem, &trace, invariant),
    });
    const states_path = try std.fs.path.join(arena, &.{ directory, states_file });
    cwd.deleteTree(io, states_path) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, quint, ' ');
    while (words.next()) |word| try argv.append(arena, word);
    if (argv.items.len == 0) return error.Usage;
    try argv.appendSlice(arena, &.{
        "test",          trace_file, "--main",    module_name, "--match", "^" ++ run_name ++ "$",
        "--max-samples", "1",        "--out-itf", states_file,
    });
    const result = std.process.run(arena, io, .{ .argv = argv.items, .cwd = .{ .path = directory } }) catch |err| {
        std.debug.print("[determinismo] `{s}` did not run ({s}): Quint is `npm install -g @informalsystems/quint`, " ++
            "or name its command with --quint (\"npx -y @informalsystems/quint\")\n", .{ quint, @errorName(err) });
        return 1;
    };
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const states = cwd.readFileAlloc(io, states_path, arena, .limited(1 << 30)) catch "";
    return verdict(arena, &trace, invariant, passed, states, result.stdout, result.stderr);
}

/// A timeline's events: a file (plain, or compressed as an ended timeline's), or with a branch
/// the timeline's of a directory of them (a run's events, an --events-dir).
fn events_read(arena: std.mem.Allocator, io: std.Io, path: []const u8, branch: ?u32) ![]const u8 {
    if (branch) |timeline| return event_files.read(arena, io, path, timeline, .limited(events_size_max));
    if (!std.mem.endsWith(u8, path, event_files.ended_suffix)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(events_size_max));
    }
    const name = std.fs.path.basename(path);
    const timeline = event_files.index_of(name) orelse return error.EventsFileName;
    return event_files.read(arena, io, std.fs.path.dirname(path) orelse ".", timeline, .limited(events_size_max));
}

/// The names the spec defines as actions (`action <name>`), from its text: what an event must be
/// named to be a step.
fn actions_of(arena: std.mem.Allocator, spec: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const key = "action";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, spec, start, key)) |at| {
        start = at + key.len;
        // A definition starts its line: prose that says "action" (a comment's) does not.
        var before = at;
        while (before > 0 and (spec[before - 1] == ' ' or spec[before - 1] == '\t')) before -= 1;
        if (before > 0 and spec[before - 1] != '\n') continue;
        var from = start;
        while (from < spec.len and (spec[from] == ' ' or spec[from] == '\t')) from += 1;
        if (from == start) continue; // "actions", "actionTaken".
        var to = from;
        while (to < spec.len and (std.ascii.isAlphanumeric(spec[to]) or spec[to] == '_')) to += 1;
        if (!identifier(spec[from..to])) continue;
        try names.append(arena, spec[from..to]);
        start = to;
    }
    return names.items;
}

fn trace_read(arena: std.mem.Allocator, source: []const u8, actions: []const []const u8) !Trace {
    var steps: std.ArrayList(Step) = .empty;
    var unnamed: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        // A program's own event: {"seq":..,"vtime_ns":..,"event":{"event":"<name>","details":{..}}}.
        if (std.mem.indexOf(u8, text, "\"event\":{\"event\":\"") == null) continue;
        const line = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch continue;
        if (line != .object) continue;
        const event = line.object.get("event") orelse continue;
        if (event != .object) continue;
        const name = switch (event.object.get("event") orelse continue) {
            .string => |string| string,
            else => continue,
        };
        const known = for (actions) |action| {
            if (std.mem.eql(u8, action, name)) break true;
        } else false;
        if (!known) {
            unnamed += 1;
            continue;
        }
        if (steps.items.len == steps_max) return error.TraceTooLong;
        const details: ?std.json.Value = if (event.object.get("details")) |details| switch (details) {
            .object => |fields| if (fields.count() == 0) null else details,
            .null => null,
            else => return error.DetailsNotARecord,
        } else null;
        try steps.append(arena, .{
            .seq = integer_of(line.object.get("seq")),
            .vtime_ns = integer_of(line.object.get("vtime_ns")),
            .name = name,
            .details = details,
        });
    }
    return .{ .steps = steps.items, .unnamed = unnamed };
}

fn integer_of(value: ?std.json.Value) u64 {
    return switch (value orelse return 0) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        else => 0,
    };
}

/// The trace as a module beside the spec: one run through its events, in parts.
fn trace_module(
    arena: std.mem.Allocator,
    main: []const u8,
    file_stem: []const u8,
    trace: *const Trace,
    invariant: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "// Written by `determinismo quint`: a timeline's {d} events as a run of the spec's actions.\n" ++
        "module " ++ module_name ++ " {{\n  import {s}.* from \"./{s}\"\n", .{ trace.steps.len, main, file_stem });
    const parts = (trace.steps.len + part_steps_max - 1) / part_steps_max;
    for (0..parts) |part| {
        const from = part * part_steps_max;
        const to = @min(trace.steps.len, from + part_steps_max);
        if (part + 1 == parts) {
            try out.appendSlice(arena, "\n  run " ++ run_name ++ " =\n");
        } else {
            try out.print(arena, "\n  run determinismo_trace_part_{d} =\n", .{part});
        }
        if (part == 0) {
            try out.appendSlice(arena, "    init\n");
            if (invariant) |name| try out.print(arena, "      .expect({s})\n", .{name});
        } else {
            try out.print(arena, "    determinismo_trace_part_{d}\n", .{part - 1});
        }
        for (trace.steps[from..to]) |step| {
            try out.print(arena, "      .then({s}", .{step.name});
            if (step.details) |details| {
                try out.append(arena, '(');
                try value_write(arena, &out, details);
                try out.append(arena, ')');
            }
            try out.append(arena, ')');
            if (invariant) |name| try out.print(arena, ".expect({s})", .{name});
            try out.print(arena, " // event {d} at {d}.{d:0>3} s\n", .{
                step.seq, step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000,
            });
        }
    }
    try out.appendSlice(arena, "}\n");
    return out.items;
}

/// A JSON value as a Quint expression: an integer, a boolean, a string, a list, a record. A
/// null field is left out of its record (Quint has no null).
fn value_write(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .integer => |number| try out.print(arena, "{d}", .{number}),
        .bool => |flag| try out.appendSlice(arena, if (flag) "true" else "false"),
        .string => |text| {
            // Quint's strings have no escapes: what would need one is written as an apostrophe.
            try out.append(arena, '"');
            for (text) |byte| try out.append(arena, switch (byte) {
                '"', '\\' => '\'',
                '\n', '\r', '\t' => ' ',
                else => byte,
            });
            try out.append(arena, '"');
        },
        .array => |items| {
            try out.append(arena, '[');
            for (items.items, 0..) |item, index| {
                if (index > 0) try out.appendSlice(arena, ", ");
                try value_write(arena, out, item);
            }
            try out.append(arena, ']');
        },
        .object => |fields| {
            try out.appendSlice(arena, "{ ");
            var written: u32 = 0;
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                if (field.value_ptr.* == .null) continue;
                if (!identifier(field.key_ptr.*)) return error.FieldNotAnIdentifier;
                if (written > 0) try out.appendSlice(arena, ", ");
                written += 1;
                try out.print(arena, "{s}: ", .{field.key_ptr.*});
                try value_write(arena, out, field.value_ptr.*);
            }
            if (written == 0) return error.EmptyRecord;
            try out.appendSlice(arena, " }");
        },
        else => return error.UnsupportedValue, // Floats have no Quint counterpart.
    }
}

fn identifier(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// Quint's answer. The run's states (its ITF file) say how far it went: the first state, the
/// spec's `init`, then one an event the spec took; a state without variables is where it stopped.
fn verdict(
    arena: std.mem.Allocator,
    trace: *const Trace,
    invariant: ?[]const u8,
    passed: bool,
    states_text: []const u8,
    stdout: []const u8,
    stderr: []const u8,
) u8 {
    if (passed) {
        std.debug.print("[determinismo] the trace ({d} events) is a behavior of the spec", .{trace.steps.len});
        if (invariant) |name| std.debug.print(", and {s} holds after every one", .{name});
        std.debug.print(" ({d} events under names the spec has no action for; its states: " ++ states_file ++ ")\n", .{trace.unnamed});
        return 0;
    }
    const states = states_of(arena, states_text) orelse {
        std.debug.print("[determinismo] Quint did not run the trace:\n{s}\n{s}\n", .{ stdout, stderr });
        return 1;
    };
    // States with variables: init, then one an event taken.
    if (states.whole == 0) {
        std.debug.print("[determinismo] the spec's init is not enabled\n", .{});
        return 3;
    }
    const taken = states.whole - 1;
    if (states.whole == states.count or taken >= trace.steps.len) {
        // Every state the run has is whole: it took its last event, and what was expected of
        // the state after it (the invariant) did not hold.
        if (taken == 0) {
            std.debug.print("[determinismo] {s} does not hold in the spec's first state\n", .{invariant orelse "the run"});
        } else {
            const step = trace.steps[@min(taken, trace.steps.len) - 1];
            std.debug.print("[determinismo] {s} does not hold after event {d} of {d} ({s}, event {d} at {d}.{d:0>3} s)\n", .{
                invariant orelse "the run",        taken,                                     trace.steps.len, step.name, step.seq,
                step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000,
            });
        }
    } else {
        const step = trace.steps[taken];
        std.debug.print("[determinismo] the spec refuses event {d} of {d}: {s}", .{ taken + 1, trace.steps.len, step.name });
        if (step.details) |details| {
            var text: std.ArrayList(u8) = .empty;
            value_write(arena, &text, details) catch {};
            std.debug.print("({s})", .{text.items});
        }
        std.debug.print(" (event {d} at {d}.{d:0>3} s): not enabled after the {d} before it\n", .{
            step.seq, step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000, taken,
        });
    }
    if (states.last) |state| std.debug.print("[determinismo] the spec's state there: {s}\n", .{state});
    return 3;
}

const States = struct { count: usize, whole: usize, last: ?[]const u8 };

/// The run's states from its ITF file: how many, how many of them have variables (a state the
/// run did not reach has its "#meta" alone), and the last of those as text.
fn states_of(arena: std.mem.Allocator, text: []const u8) ?States {
    if (text.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (parsed != .object) return null;
    const states = switch (parsed.object.get("states") orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    var whole: usize = 0;
    for (states) |state| {
        if (state != .object) return null;
        var variables: usize = 0;
        var keys = state.object.iterator();
        while (keys.next()) |field| variables += @intFromBool(!std.mem.eql(u8, field.key_ptr.*, "#meta"));
        if (variables == 0) break;
        whole += 1;
    }
    var last: std.ArrayList(u8) = .empty;
    if (whole > 0) itf_write(arena, &last, states[whole - 1]) catch return null;
    return .{ .count = states.len, .whole = whole, .last = if (whole == 0) null else last.items };
}

/// A value of Quint's trace format (ITF) as Quint writes it: {"#bigint":"7"} is 7, {"#map":
/// [[k, v], ...]} is Map(k -> v, ...), {"#set": [...]} Set(...), {"#tup": [...]} a tuple; a
/// state's "#meta" is left out.
fn itf_write(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) ItfError!void {
    switch (value) {
        .integer => |number| try out.print(arena, "{d}", .{number}),
        .bool => |flag| try out.appendSlice(arena, if (flag) "true" else "false"),
        .string => |text| try out.print(arena, "\"{s}\"", .{text}),
        .array => |items| try itf_items_write(arena, out, "[", items.items, "]"),
        .object => |fields| {
            if (fields.get("#bigint")) |number| if (number == .string) return out.appendSlice(arena, number.string);
            if (fields.get("#set")) |items| if (items == .array) return itf_items_write(arena, out, "Set(", items.array.items, ")");
            if (fields.get("#tup")) |items| if (items == .array) return itf_items_write(arena, out, "(", items.array.items, ")");
            if (fields.get("#map")) |pairs| if (pairs == .array) {
                try out.appendSlice(arena, "Map(");
                for (pairs.array.items, 0..) |pair, index| {
                    if (pair != .array or pair.array.items.len != 2) return error.UnsupportedValue;
                    if (index > 0) try out.appendSlice(arena, ", ");
                    try itf_write(arena, out, pair.array.items[0]);
                    try out.appendSlice(arena, " -> ");
                    try itf_write(arena, out, pair.array.items[1]);
                }
                return out.append(arena, ')');
            };
            try out.appendSlice(arena, "{ ");
            var written: u32 = 0;
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "#meta")) continue;
                if (written > 0) try out.appendSlice(arena, ", ");
                written += 1;
                try out.print(arena, "{s}: ", .{field.key_ptr.*});
                try itf_write(arena, out, field.value_ptr.*);
            }
            try out.appendSlice(arena, " }");
        },
        else => return error.UnsupportedValue,
    }
}

const ItfError = error{ OutOfMemory, UnsupportedValue };

fn itf_items_write(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    open: []const u8,
    items: []const std.json.Value,
    close: []const u8,
) ItfError!void {
    try out.appendSlice(arena, open);
    for (items, 0..) |item, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try itf_write(arena, out, item);
    }
    try out.appendSlice(arena, close);
}

test actions_of {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try actions_of(arena_state.allocator(),
        \\module bank {
        \\  // An action in a comment's prose, and actionTaken: neither is one.
        \\  var actionTaken: str
        \\  action init = all { x' = 0 }
        \\  action transfer(e: { amount: int }): bool = x' = x + e.amount
        \\  action  audit = x' = x
        \\}
    );
    try std.testing.expectEqual(3, names.len);
    try std.testing.expectEqualStrings("init", names[0]);
    try std.testing.expectEqualStrings("transfer", names[1]);
    try std.testing.expectEqualStrings("audit", names[2]);
}

test "a timeline's events as a run: the spec's actions only, a record for the details, none without" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\{"seq":1,"vtime_ns":1500000000,"branches":10,"event":{"event":"transfer","details":{"from":0,"to":2,"amount":7,"note":"a \"b\"","tags":["x","y"],"ok":true,"gone":null}}}
        \\{"seq":2,"vtime_ns":1600000000,"branches":20,"event":{"assert":{"type":"always","message":"m","condition":true}}}
        \\{"seq":3,"vtime_ns":1700000000,"branches":30,"event":{"event":"fault","details":{"kind":"pause"}}}
        \\{"seq":4,"vtime_ns":2000000000,"branches":40,"event":{"event":"audit","details":{}}}
    ;
    const trace = try trace_read(arena, source, &.{ "init", "transfer", "audit" });
    try std.testing.expectEqual(2, trace.steps.len);
    try std.testing.expectEqual(1, trace.unnamed);
    const module = try trace_module(arena, "bank", "bank", &trace, null);
    try std.testing.expectEqualStrings(
        \\// Written by `determinismo quint`: a timeline's 2 events as a run of the spec's actions.
        \\module determinismo_trace {
        \\  import bank.* from "./bank"
        \\
        \\  run determinismo_trace_run =
        \\    init
        \\      .then(transfer({ from: 0, to: 2, amount: 7, note: "a 'b'", tags: ["x", "y"], ok: true })) // event 1 at 1.500 s
        \\      .then(audit) // event 4 at 2.000 s
        \\}
        \\
    , module);
    const asked = try trace_module(arena, "bank", "bank", &trace, "conserved");
    try std.testing.expect(std.mem.indexOf(u8, asked, "    init\n      .expect(conserved)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asked, "ok: true })).expect(conserved) // event 1") != null);
}

test "the run's states say where it stopped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const states = states_of(arena,
        \\{"#meta":{"format":"ITF"},"vars":["x"],"states":[{"#meta":{"index":0},"x":{"#bigint":"0"}},{"#meta":{"index":1},"x":{"#bigint":"7"}},{"#meta":{"index":2}}]}
    ).?;
    try std.testing.expectEqual(3, states.count);
    try std.testing.expectEqual(2, states.whole);
    try std.testing.expectEqualStrings("{ x: 7 }", states.last.?);
    try std.testing.expect(states_of(arena, "") == null);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"#meta":{"index":4},"balances":{"#map":[[{"#bigint":"0"},{"#bigint":"95"}],[{"#bigint":"1"},{"#bigint":"107"}]]},"reads":{"#map":[]},"seen":{"#set":["a"]},"pair":{"#tup":[true,[1]]}}
    , .{});
    var text: std.ArrayList(u8) = .empty;
    try itf_write(arena, &text, value);
    try std.testing.expectEqualStrings("{ balances: Map(0 -> 95, 1 -> 107), reads: Map(), seen: Set(\"a\"), pair: (true, [1]) }", text.items);
}
