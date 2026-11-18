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
//! A system that says its steps in its log, not through the SDK, has them too: an output line
//! of a node or a command (`<when> [INFO]  node-1: election won: term=4 tally=2`, hclog's and
//! logfmt's shape) is an event named by its message (`election_won`: its letters and digits,
//! "_" for the rest), its `key=value` pairs the details with the line's source ({ source:
//! "raft-node-1", term: 4, tally: 2 }: digits a number, anything else a string). A word of the
//! message with a digit in it is no part of the name (an address, an id: "connection from
//! 10.0.0.6:56392" is `connection_from`). A line that is a JSON object is named by its `msg`,
//! `message` or `event`, else by its keys (`{"op":"apply","data":"ab12"}` is `op_data`), its
//! fields the details. A spec with an action of that name takes those lines as steps, in the
//! timeline's order with the rest.
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
/// Steps of one run, and runs of one run above them: Quint's evaluator takes a chain of `.then`
/// as deep as it is long (its input nests 128 deep at most, "recursion limit exceeded", and a
/// chain of a few hundred runs ends its stack), so the trace is a tree of short chains, as deep
/// as its levels. A step with the invariant asked after it nests twice as deep: 40 of them were
/// too many, 20 are not.
const part_steps_max = 20;
pub const module_name = "determinismo_trace";
pub const run_name = "determinismo_trace_run";
const trace_file = module_name ++ ".qnt";
const states_file = module_name ++ ".itf.json";

const Step = struct { seq: u64, vtime_ns: u64, name: []const u8, details: ?std.json.Value };
const Trace = struct {
    steps: []const Step,
    /// Events the program emitted under names the spec has no action for.
    unnamed: u64,
    /// Every name the timeline's own events have, in the order they first came: what a spec
    /// could take as actions.
    kinds: []const Kind = &.{},
};

/// An event name of a timeline: how many events have it, and the first one's details as the
/// argument its action would get ("" for none, or when they are no Quint record).
pub const Kind = struct { name: []const u8, count: u64, example: []const u8 };
const kinds_max = 256;

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
        for (trace.kinds) |kind| std.debug.print("  {d} {s}{s}{s}\n", .{
            kind.count, kind.name, if (kind.example.len > 0) " " else "", kind.example,
        });
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
    var text: std.ArrayList(u8) = .empty;
    const said = try std.mem.concat(arena, u8, &.{ result.stdout, "\n", result.stderr });
    const status = try verdict(arena, &trace, invariant, passed, states_of(arena, states), said, &text);
    std.debug.print("{s}", .{text.items});
    return status;
}

/// What serve is asked for a timeline (POST /runs/<id>/quint): the trace's module for a spec
/// kept elsewhere, and, once Quint ran it there, what its result means.
pub const Asked = struct {
    branch: u32,
    /// The spec's text (its actions are read from it), or its actions' names.
    spec: ?[]const u8 = null,
    actions: ?[]const []const u8 = null,
    /// The spec's module, and its file's name without `.qnt` when it is another.
    main: []const u8,
    file: ?[]const u8 = null,
    invariant: ?[]const u8 = null,
    /// After Quint ran the module: whether its test passed, and the states it wrote
    /// (determinismo_trace.itf.json's content).
    passed: ?bool = null,
    states: ?std.json.Value = null,
};

/// The answer, a JSON object. Without `passed`: the module (`module`, to be written as `file`
/// beside the spec), the command that runs it, and how many events it has. With it: the
/// verdict's exit status (`status`: 0, 3, 1) and its text, as `determinismo quint` prints them.
pub fn answer(arena: std.mem.Allocator, io: std.Io, events_directory: []const u8, asked: Asked, out: *std.Io.Writer) !void {
    if (asked.invariant) |name| if (!identifier(name)) return error.BadRequest;
    if (!identifier(asked.main)) return error.BadRequest;
    const actions = asked.actions orelse try actions_of(arena, asked.spec orelse return error.BadRequest);
    const source = try event_files.read(arena, io, events_directory, asked.branch, .limited(events_size_max));
    const trace = try trace_read(arena, source, actions);
    if (asked.passed) |passed| {
        var text: std.ArrayList(u8) = .empty;
        const states = if (asked.states) |states| states_in(arena, states) else null;
        const status = try verdict(arena, &trace, asked.invariant, passed, states, "(its output is where it ran)", &text);
        const outcome = outcome_of(&trace, passed, states);
        const Event = struct { index: usize, of: usize, seq: u64, vtime_ns: u64, action: []const u8, argument: ?std.json.Value };
        const event: ?Event = if (outcome.event) |index| .{
            .index = index,
            .of = trace.steps.len,
            .seq = trace.steps[index - 1].seq,
            .vtime_ns = trace.steps[index - 1].vtime_ns,
            .action = trace.steps[index - 1].name,
            .argument = trace.steps[index - 1].details,
        } else null;
        const state: ?std.json.Value = if (states) |known| if (known.last_value) |last| plain(arena, last) catch null else null else null;
        try std.json.Stringify.value(.{
            .status = status,
            .text = text.items,
            .kind = outcome.kind,
            .events = trace.steps.len,
            .event = event,
            .state = state,
            .series = if (asked.states) |raw| series_of(arena, raw) catch null else null,
            .steps = if (states) |known| steps_of(arena, &trace, known) catch null else null,
        }, .{}, out);
    } else {
        const module = if (trace.steps.len == 0) "" else try trace_module(arena, asked.main, asked.file orelse asked.main, &trace, asked.invariant);
        try std.json.Stringify.value(.{
            .file = trace_file,
            .states = states_file,
            .command = "quint test " ++ trace_file ++ " --main " ++ module_name ++ " --match ^" ++ run_name ++ "$ --max-samples 1 --out-itf " ++ states_file,
            .events = trace.steps.len,
            .unnamed = trace.unnamed,
            .kinds = trace.kinds,
            .module = module,
        }, .{}, out);
    }
    try out.writeAll("\n");
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
    var kinds: std.ArrayList(Kind) = .empty;
    var unnamed: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        // A program's own event: {"seq":..,"vtime_ns":..,"event":{"event":"<name>","details":{..}}},
        // or a line of output: {..,"event":{"output":{"source":..,"stream":..,"text":".."}}}.
        const own = std.mem.indexOf(u8, text, "\"event\":{\"event\":\"") != null;
        if (!own and std.mem.indexOf(u8, text, "\"event\":{\"output\":{") == null) continue;
        const line = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch continue;
        if (line != .object) continue;
        const event = line.object.get("event") orelse continue;
        if (event != .object) continue;
        var name: []const u8 = "";
        var said: ?std.json.Value = null;
        if (own) {
            name = switch (event.object.get("event") orelse continue) {
                .string => |string| string,
                else => continue,
            };
            said = event.object.get("details");
        } else {
            const output = event.object.get("output") orelse continue;
            if (output != .object) continue;
            const step = (try log_step(arena, output.object)) orelse continue;
            name = step.name;
            said = step.details;
        }
        const kind = for (kinds.items) |*kind| {
            if (std.mem.eql(u8, kind.name, name)) break kind;
        } else if (kinds.items.len < kinds_max) added: {
            var example: std.ArrayList(u8) = .empty;
            if (said) |details| value_write(arena, &example, details) catch {
                example.clearRetainingCapacity();
            };
            try kinds.append(arena, .{ .name = name, .count = 0, .example = example.items });
            break :added &kinds.items[kinds.items.len - 1];
        } else null;
        if (kind) |known_kind| known_kind.count += 1;
        const known = for (actions) |action| {
            if (std.mem.eql(u8, action, name)) break true;
        } else false;
        if (!known) {
            unnamed += 1;
            continue;
        }
        if (steps.items.len == steps_max) return error.TraceTooLong;
        const details: ?std.json.Value = if (said) |details| switch (details) {
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
    return .{ .steps = steps.items, .unnamed = unnamed, .kinds = kinds.items };
}

const LogStep = struct { name: []const u8, details: std.json.Value };
const log_name_size_max = 64;

/// An output line as a step (the module's description): null for a line that names nothing.
/// Its pairs begin at the first word that is `key=`; what is before them, less a logger's name
/// and what precedes it (`<when> [LEVEL] <logger>: `), is the message. A line of pairs alone
/// (logfmt: `level=info msg="election won" term=4`) is named by its `msg` or `message`.
fn log_step(arena: std.mem.Allocator, output: std.json.ObjectMap) !?LogStep {
    const text = switch (output.get("text") orelse return null) {
        .string => |string| std.mem.trim(u8, string, " \t\r\n"),
        else => return null,
    };
    const source = switch (output.get("source") orelse std.json.Value{ .null = {} }) {
        .string => |string| string,
        else => "",
    };
    var pairs_at: usize = text.len;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '=')) |equals| : (at = equals + 1) {
        var start = equals;
        while (start > 0 and log_key_character(text[start - 1])) start -= 1;
        if (start == equals or !std.ascii.isAlphabetic(text[start])) continue;
        if (start > 0 and text[start - 1] != ' ') continue;
        pairs_at = start;
        break;
    }
    var fields: std.json.ObjectMap = .empty;
    try fields.put(arena, "source", .{ .string = source });
    if (text.len > 1 and text[0] == '{') {
        // A JSON object: its fields the details, named by what it calls itself, else its keys.
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})) |parsed| {
            if (parsed == .object) {
                var said: []const u8 = "";
                var keys: std.ArrayList(u8) = .empty;
                var entries = parsed.object.iterator();
                while (entries.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const naming = std.mem.eql(u8, key, "msg") or std.mem.eql(u8, key, "message") or std.mem.eql(u8, key, "event");
                    if (naming and said.len == 0 and entry.value_ptr.* == .string) {
                        said = entry.value_ptr.string;
                        continue;
                    }
                    try keys.appendSlice(arena, key);
                    try keys.append(arena, ' ');
                    try fields.put(arena, try log_key(arena, key), entry.value_ptr.*);
                }
                const named = (try log_name(arena, if (said.len > 0) said else keys.items)) orelse return null;
                return .{ .name = named, .details = .{ .object = fields } };
            }
        } else |_| {}
    }
    var message = std.mem.trimEnd(u8, std.mem.trim(u8, text[0..pairs_at], " \t"), ":");
    if (std.mem.lastIndexOf(u8, message, ": ")) |colon| message = message[colon + 2 ..];
    // What a line begins with before its message: a moment, a level in brackets.
    while (message.len > 0 and (std.ascii.isDigit(message[0]) or message[0] == '[')) {
        const end = std.mem.indexOfScalar(u8, message, ' ') orelse message.len;
        message = std.mem.trimStart(u8, message[end..], " ");
    }
    var rest = text[pairs_at..];
    while (rest.len > 0) {
        rest = std.mem.trimStart(u8, rest, " ");
        const equals = std.mem.indexOfScalar(u8, rest, '=') orelse break;
        const key = rest[0..equals];
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, ' ') != null) break; // Words after the pairs.
        rest = rest[equals + 1 ..];
        var value: []const u8 = undefined;
        if (rest.len > 0 and rest[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len;
            value = rest[1..close];
            rest = rest[@min(close + 1, rest.len)..];
        } else {
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            value = std.mem.trimEnd(u8, rest[0..end], ",;"); // "leader=node-2, term=2,".
            rest = rest[end..];
        }
        const name = try log_key(arena, key);
        if ((std.mem.eql(u8, name, "msg") or std.mem.eql(u8, name, "message")) and message.len == 0) {
            message = value;
            continue;
        }
        const number = std.fmt.parseInt(i64, value, 10) catch null;
        try fields.put(arena, name, if (number) |integer| .{ .integer = integer } else .{ .string = value });
    }
    const named = (try log_name(arena, message)) orelse return null;
    return .{ .name = named, .details = .{ .object = fields } };
}

/// A message as an action's name: its words' letters, lowercase, "_" between them; a word with
/// a digit in it left out (what changes from one line to the next: an address, an id). Null
/// when nothing is left, or too much.
fn log_name(arena: std.mem.Allocator, message: []const u8) !?[]const u8 {
    var name: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, message, " \t");
    while (words.next()) |word| {
        if (std.mem.indexOfAny(u8, word, "0123456789") != null) continue;
        const start = name.items.len;
        for (word) |character| {
            if (std.ascii.isAlphabetic(character)) {
                try name.append(arena, std.ascii.toLower(character));
            } else if (name.items.len > start and name.items[name.items.len - 1] != '_') {
                try name.append(arena, '_');
            }
        }
        while (name.items.len > start and name.items[name.items.len - 1] == '_') name.items.len -= 1;
        if (name.items.len > start) try name.append(arena, '_');
    }
    const named = std.mem.trimEnd(u8, name.items, "_");
    if (named.len == 0 or named.len > log_name_size_max) return null;
    return named;
}

/// A key of a line as a record's field: what is no letter or digit a "_".
fn log_key(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, key);
    for (name) |*character| {
        if (!std.ascii.isAlphanumeric(character.*)) character.* = '_';
    }
    return name;
}

fn log_key_character(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_' or character == '-' or character == '.';
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
    // The leaves: the events, twenty a run, the first one from the spec's init.
    var count = (trace.steps.len + part_steps_max - 1) / part_steps_max;
    for (0..count) |part| {
        const from = part * part_steps_max;
        const to = @min(trace.steps.len, from + part_steps_max);
        try run_begin(arena, &out, 0, part, count);
        for (trace.steps[from..to], from..) |step, index| {
            if (index == 0) {
                try out.appendSlice(arena, "    init\n");
                if (invariant) |name| try out.print(arena, "      .expect({s})\n", .{name});
            }
            try out.appendSlice(arena, if (index == from and index != 0) "    " else "      .then(");
            try out.appendSlice(arena, step.name);
            if (step.details) |details| {
                try out.append(arena, '(');
                try value_write(arena, &out, details);
                try out.append(arena, ')');
            }
            if (index != from or index == 0) try out.append(arena, ')');
            if (invariant) |name| try out.print(arena, ".expect({s})", .{name});
            try out.print(arena, " // event {d} at {d}.{d:0>3} s\n", .{
                step.seq, step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000,
            });
        }
    }
    // The levels above: twenty runs of the level below one after the other, up to a single run.
    var level: usize = 0;
    while (count > 1) : (level += 1) {
        const above = (count + part_steps_max - 1) / part_steps_max;
        for (0..above) |group| {
            try run_begin(arena, &out, level + 1, group, above);
            const from = group * part_steps_max;
            for (from..@min(count, from + part_steps_max)) |part| {
                if (part == from) {
                    try out.print(arena, "    determinismo_trace_part_{d}_{d}\n", .{ level, part });
                } else {
                    try out.print(arena, "      .then(determinismo_trace_part_{d}_{d})\n", .{ level, part });
                }
            }
        }
        count = above;
    }
    try out.appendSlice(arena, "}\n");
    return out.items;
}

/// A run's first line: the trace's whole run when it is its level's only one, else a part.
fn run_begin(arena: std.mem.Allocator, out: *std.ArrayList(u8), level: usize, part: usize, count: usize) !void {
    if (count == 1) return out.appendSlice(arena, "\n  run " ++ run_name ++ " =\n");
    try out.print(arena, "\n  run determinismo_trace_part_{d}_{d} =\n", .{ level, part });
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
    states_known: ?States,
    /// What Quint said, shown when it wrote no states.
    said: []const u8,
    out: *std.ArrayList(u8),
) !u8 {
    if (passed) {
        try out.print(arena, "[determinismo] the trace ({d} events) is a behavior of the spec", .{trace.steps.len});
        if (invariant) |name| try out.print(arena, ", and {s} holds after every one", .{name});
        try out.print(arena, " ({d} events under names the spec has no action for; its states: " ++ states_file ++ ")\n", .{trace.unnamed});
        return 0;
    }
    const states = states_known orelse {
        try out.print(arena, "[determinismo] Quint did not run the trace:\n{s}\n", .{said});
        return 1;
    };
    // States with variables: init, then one an event taken.
    if (states.whole == 0) {
        try out.print(arena, "[determinismo] the spec's init is not enabled\n", .{});
        return 3;
    }
    const taken = states.whole - 1;
    if (states.whole == states.count or taken >= trace.steps.len) {
        // Every state the run has is whole: it took its last event, and what was expected of
        // the state after it (the invariant) did not hold.
        if (taken == 0) {
            try out.print(arena, "[determinismo] {s} does not hold in the spec's first state\n", .{invariant orelse "the run"});
        } else {
            const step = trace.steps[@min(taken, trace.steps.len) - 1];
            try out.print(arena, "[determinismo] {s} does not hold after event {d} of {d} ({s}, event {d} at {d}.{d:0>3} s)\n", .{
                invariant orelse "the run",        taken,                                     trace.steps.len, step.name, step.seq,
                step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000,
            });
        }
    } else {
        const step = trace.steps[taken];
        try out.print(arena, "[determinismo] the spec refuses event {d} of {d}: {s}", .{ taken + 1, trace.steps.len, step.name });
        if (step.details) |details| {
            try out.append(arena, '(');
            value_write(arena, out, details) catch {};
            try out.append(arena, ')');
        }
        try out.print(arena, " (event {d} at {d}.{d:0>3} s): not enabled after the {d} before it\n", .{
            step.seq, step.vtime_ns / std.time.ns_per_s, step.vtime_ns / std.time.ns_per_ms % 1000, taken,
        });
    }
    if (states.last) |state| try out.print(arena, "[determinismo] the spec's state there: {s}\n", .{state});
    return 3;
}

const States = struct {
    count: usize,
    whole: usize,
    last: ?[]const u8,
    /// The last whole state as Quint's trace format has it (for `plain`).
    last_value: ?std.json.Value = null,
    /// The whole states, as Quint's trace format has them: the spec's init, then one an event.
    values: []const std.json.Value = &.{},
};

/// The run's last events before it stopped (or its end), each with the spec's state after it:
/// how the timeline's events drive the spec, for a client that shows it. `steps_shown` at most.
const steps_shown = 8;

const Shown = struct {
    index: usize,
    seq: u64,
    vtime_ns: u64,
    action: []const u8,
    argument: ?std.json.Value,
    state: std.json.Value,
    /// What the event changed in the spec's state: each place that differs from the state
    /// before it, `changes_shown` at most (`changes` says how many there were).
    changed: []const Change,
    changes: usize,
};

/// A place of the spec's state (`nodes.raft-node-0.mark`) an event changed, and its values
/// before and after (null where there was none).
const Change = struct { path: []const u8, before: ?std.json.Value, after: ?std.json.Value };
const changes_shown = 8;

/// The places where `after` differs from `before`: records by field, anything else whole.
fn changes_of(arena: std.mem.Allocator, found: *std.ArrayList(Change), count: *usize, path: []const u8, before: ?std.json.Value, after: ?std.json.Value) ItfError!void {
    // A variant ({tag, value}) is one value, not a record of two fields.
    const records = before != null and after != null and before.? == .object and after.? == .object and
        before.?.object.get("tag") == null and after.?.object.get("tag") == null;
    if (records) {
        var fields = after.?.object.iterator();
        while (fields.next()) |field| {
            const inner = if (path.len == 0) field.key_ptr.* else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, field.key_ptr.* });
            try changes_of(arena, found, count, inner, before.?.object.get(field.key_ptr.*), field.value_ptr.*);
        }
        var gone = before.?.object.iterator();
        while (gone.next()) |field| {
            if (after.?.object.get(field.key_ptr.*) != null) continue;
            const inner = if (path.len == 0) field.key_ptr.* else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, field.key_ptr.* });
            try changes_of(arena, found, count, inner, field.value_ptr.*, null);
        }
        return;
    }
    const same = same: {
        if (before == null or after == null) break :same before == null and after == null;
        const one = std.json.Stringify.valueAlloc(arena, before.?, .{}) catch return error.OutOfMemory;
        const other = std.json.Stringify.valueAlloc(arena, after.?, .{}) catch return error.OutOfMemory;
        break :same std.mem.eql(u8, one, other);
    };
    if (same) return;
    count.* += 1;
    if (found.items.len < changes_shown) try found.append(arena, .{ .path = path, .before = before, .after = after });
}

fn steps_of(arena: std.mem.Allocator, trace: *const Trace, states: States) ItfError![]const Shown {
    var shown: std.ArrayList(Shown) = .empty;
    // State i is the spec after event i (state 0 its init).
    const last = @min(states.values.len -| 1, trace.steps.len);
    var index = last -| (steps_shown - 1);
    if (index == 0) index = 1;
    while (index <= last) : (index += 1) {
        const step = trace.steps[index - 1];
        const state = try plain(arena, states.values[index]);
        var changed: std.ArrayList(Change) = .empty;
        var changes: usize = 0;
        try changes_of(arena, &changed, &changes, "", try plain(arena, states.values[index - 1]), state);
        try shown.append(arena, .{
            .index = index,
            .seq = step.seq,
            .vtime_ns = step.vtime_ns,
            .action = step.name,
            .argument = step.details,
            .state = state,
            .changed = changed.items,
            .changes = changes,
        });
    }
    return shown.items;
}

/// The verdict as data, for a client that draws it (the text says the same).
const Outcome = struct {
    /// "behavior", "refused" (an event the spec does not take), "invariant" (lost after an
    /// event, or in the first state: no event), "unknown" (Quint wrote no states).
    kind: []const u8,
    /// The event refused, or the one after which the invariant was lost: its place among the
    /// trace's events, from 1.
    event: ?usize = null,
};

fn outcome_of(trace: *const Trace, passed: bool, states_known: ?States) Outcome {
    if (passed) return .{ .kind = "behavior" };
    const states = states_known orelse return .{ .kind = "unknown" };
    if (states.whole == 0) return .{ .kind = "refused" };
    const taken = states.whole - 1;
    if (states.whole == states.count or taken >= trace.steps.len) {
        return .{ .kind = "invariant", .event = if (taken == 0) null else @min(taken, trace.steps.len) };
    }
    return .{ .kind = "refused", .event = taken + 1 };
}

/// A value of Quint's trace format as plain JSON: {"#bigint":"7"} a number (a string when it
/// does not fit 64 bits), a map an object (its keys as text), a set or a tuple an array; a
/// state's "#meta" left out.
fn plain(arena: std.mem.Allocator, value: std.json.Value) ItfError!std.json.Value {
    switch (value) {
        .array => |items| return plain_items(arena, items.items),
        .object => |fields| {
            if (fields.get("#bigint")) |number| if (number == .string) {
                const parsed = std.fmt.parseInt(i64, number.string, 10) catch return number;
                return .{ .integer = parsed };
            };
            if (fields.get("#set")) |items| if (items == .array) return plain_items(arena, items.array.items);
            if (fields.get("#tup")) |items| if (items == .array) return plain_items(arena, items.array.items);
            var object: std.json.ObjectMap = .empty;
            if (fields.get("#map")) |pairs| if (pairs == .array) {
                for (pairs.array.items) |pair| {
                    if (pair != .array or pair.array.items.len != 2) return error.UnsupportedValue;
                    var key: std.ArrayList(u8) = .empty;
                    const key_value = pair.array.items[0];
                    if (key_value == .string) try key.appendSlice(arena, key_value.string) else try itf_write(arena, &key, key_value);
                    try object.put(arena, key.items, try plain(arena, pair.array.items[1]));
                }
                return .{ .object = object };
            };
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "#meta")) continue;
                try object.put(arena, field.key_ptr.*, try plain(arena, field.value_ptr.*));
            }
            return .{ .object = object };
        },
        else => return value,
    }
}

/// The run's states as numbers a client can draw: for each of the spec's variables that is a
/// number, or a map, record or list of numbers ("balances.0"), its value in every whole
/// state, the first state's first. As a JSON object of lists; the variables are those of the
/// first state, `series_max` of them at most.
const series_max = 32;

fn series_of(arena: std.mem.Allocator, parsed: std.json.Value) ItfError!std.json.Value {
    var series: std.json.ObjectMap = .empty;
    if (parsed != .object) return .{ .object = series };
    const states = switch (parsed.object.get("states") orelse return .{ .object = series }) {
        .array => |array| array.items,
        else => return .{ .object = series },
    };
    for (states, 0..) |state_raw, index| {
        if (state_raw != .object or state_raw.object.count() <= 1) break; // Where the run stopped.
        const state = try plain(arena, state_raw);
        var variables = state.object.iterator();
        while (variables.next()) |variable| {
            switch (variable.value_ptr.*) {
                .integer => try series_add(arena, &series, variable.key_ptr.*, "", index, variable.value_ptr.*),
                .object => |fields| {
                    var inner = fields.iterator();
                    while (inner.next()) |field| {
                        if (field.value_ptr.* == .integer) try series_add(arena, &series, variable.key_ptr.*, field.key_ptr.*, index, field.value_ptr.*);
                    }
                },
                .array => |items| for (items.items, 0..) |item, at| {
                    if (item != .integer) continue;
                    var name_buffer: [20]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buffer, "{d}", .{at}) catch unreachable;
                    try series_add(arena, &series, variable.key_ptr.*, name, index, item);
                },
                else => {},
            }
        }
    }
    return .{ .object = series };
}

/// One state's value of a series; a series is of the first state's variables, a value for
/// every state (one that lacks it, a map's key not there yet, repeats the one before).
fn series_add(
    arena: std.mem.Allocator,
    series: *std.json.ObjectMap,
    variable: []const u8,
    field: []const u8,
    index: usize,
    value: std.json.Value,
) ItfError!void {
    const name = if (field.len == 0) variable else std.fmt.allocPrint(arena, "{s}.{s}", .{ variable, field }) catch return error.OutOfMemory;
    const entry = series.getPtr(name) orelse added: {
        if (index != 0 or series.count() == series_max) return;
        try series.put(arena, name, .{ .array = .init(arena) });
        break :added series.getPtr(name).?;
    };
    while (entry.array.items.len < index) {
        const before: std.json.Value = if (entry.array.items.len == 0) value else entry.array.items[entry.array.items.len - 1];
        try entry.array.append(before);
    }
    if (entry.array.items.len == index) try entry.array.append(value);
}

fn plain_items(arena: std.mem.Allocator, items: []const std.json.Value) ItfError!std.json.Value {
    var array: std.json.Array = .init(arena);
    for (items) |item| try array.append(try plain(arena, item));
    return .{ .array = array };
}

/// The run's states from its ITF file: how many, how many of them have variables (a state the
/// run did not reach has its "#meta" alone), and the last of those as text.
fn states_of(arena: std.mem.Allocator, text: []const u8) ?States {
    if (text.len == 0) return null;
    return states_in(arena, std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null);
}

fn states_in(arena: std.mem.Allocator, parsed: std.json.Value) ?States {
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
    return .{
        .count = states.len,
        .whole = whole,
        .last = if (whole == 0) null else last.items,
        .last_value = if (whole == 0) null else states[whole - 1],
        .values = states[0..whole],
    };
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
    try std.testing.expectEqual(3, trace.kinds.len);
    try std.testing.expectEqualStrings("fault", trace.kinds[1].name);
    try std.testing.expectEqual(1, trace.kinds[1].count);
    try std.testing.expectEqualStrings("{ kind: \"pause\" }", trace.kinds[1].example);
    try std.testing.expectEqualStrings("", trace.kinds[2].example); // audit: no details.
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

test "a system's log lines are steps: the message the action, its pairs and source the argument" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const source =
        \\{"seq":1,"vtime_ns":100,"event":{"output":{"source":"raft-node-1","stream":"stderr","text":"2026-11-19T00:00:03.158Z [INFO]  node-1: election won: term=4 tally=2"}}}
        \\{"seq":2,"vtime_ns":200,"event":{"output":{"source":"raft-node-0","stream":"stderr","text":"2026-11-19T00:00:03.160Z [DEBUG] node-0: vote granted: from=node-1 term=4 tally=1"}}}
        \\{"seq":3,"vtime_ns":300,"event":{"output":{"source":"raft-node-2","stream":"stderr","text":"level=info msg=\"Election Won!\" term=5 last-leader-id=\"\" took=1.5ms"}}}
        \\{"seq":4,"vtime_ns":400,"event":{"output":{"source":"client","stream":"stdout","text":"---- 1234 ----"}}}
        \\{"seq":5,"vtime_ns":500,"event":{"event":"election_won","details":{"term":6}}}
        \\{"seq":6,"vtime_ns":600,"event":{"output":{"source":"raft-monitor","stream":"stdout","text":"connection from 10.0.0.6:56392"}}}
        \\{"seq":7,"vtime_ns":700,"event":{"output":{"source":"raft-node-1","stream":"stdout","text":"{\"op\":\"apply\",\"data\":\"aadb6b27\"}"}}}
        \\{"seq":8,"vtime_ns":800,"event":{"output":{"source":"raft-client","stream":"stdout","text":"client: leader=raft-node-2:8400, term=2, ok"}}}
        \\
    ;
    const trace = try trace_read(arena, source, &.{"election_won"});
    try std.testing.expectEqual(3, trace.steps.len); // Two lines of logs and the program's own event.
    try std.testing.expectEqual(4, trace.unnamed); // vote_granted and the three after: no action of the spec's.
    try std.testing.expectEqual(5, trace.kinds.len); // A line with no word names nothing.
    try std.testing.expectEqualStrings("connection_from", trace.kinds[2].name); // Its address no part of the name.
    try std.testing.expectEqualStrings("op_data", trace.kinds[3].name); // A JSON line, by its keys.
    try std.testing.expectEqualStrings("{ source: \"raft-node-1\", op: \"apply\", data: \"aadb6b27\" }", trace.kinds[3].example);
    try std.testing.expectEqualStrings("client", trace.kinds[4].name);
    try std.testing.expectEqualStrings("{ source: \"raft-client\", leader: \"raft-node-2:8400\", term: 2 }", trace.kinds[4].example);
    try std.testing.expectEqualStrings("election_won", trace.kinds[0].name);
    try std.testing.expectEqual(3, trace.kinds[0].count);
    try std.testing.expectEqualStrings("{ source: \"raft-node-1\", term: 4, tally: 2 }", trace.kinds[0].example);
    try std.testing.expectEqualStrings("vote_granted", trace.kinds[1].name);
    try std.testing.expectEqualStrings("{ source: \"raft-node-0\", from: \"node-1\", term: 4, tally: 1 }", trace.kinds[1].example);
    // logfmt: named by its msg, the level a field as any other, a key's "-" an "_".
    var third: std.ArrayList(u8) = .empty;
    try value_write(arena, &third, trace.steps[1].details.?);
    try std.testing.expectEqualStrings("{ source: \"raft-node-2\", level: \"info\", term: 5, last_leader_id: \"\", took: \"1.5ms\" }", third.items);
    try std.testing.expectEqual(300, trace.steps[1].vtime_ns);
}

test "a long trace is a tree of short runs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var steps: [45]Step = undefined;
    for (&steps, 0..) |*step, index| step.* = .{ .seq = index, .vtime_ns = 0, .name = "tick", .details = null };
    const module = try trace_module(arena, "clock", "clock", &.{ .steps = &steps, .unnamed = 0 }, null);
    // Three leaves (20, 20, 5 events), the first from init, the others from their first event.
    try std.testing.expect(std.mem.indexOf(u8, module, "  run determinismo_trace_part_0_0 =\n    init\n      .then(tick) // event 0 at") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "  run determinismo_trace_part_0_1 =\n    tick // event 20 at") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "  run determinismo_trace_part_0_2 =\n    tick // event 40 at") != null);
    try std.testing.expect(std.mem.endsWith(u8, module, "  run determinismo_trace_run =\n    determinismo_trace_part_0_0\n" ++
        "      .then(determinismo_trace_part_0_1)\n      .then(determinismo_trace_part_0_2)\n}\n"));
    try std.testing.expectEqual(45, std.mem.count(u8, module, " // event "));
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
    // Two states whole of three: the second event was refused; all whole: the invariant.
    const steps = [_]Step{
        .{ .seq = 5, .vtime_ns = 1, .name = "a", .details = null },
        .{ .seq = 9, .vtime_ns = 2, .name = "b", .details = null },
    };
    const trace: Trace = .{ .steps = &steps, .unnamed = 0 };
    const refused = outcome_of(&trace, false, states);
    try std.testing.expectEqualStrings("refused", refused.kind);
    try std.testing.expectEqual(2, refused.event.?);
    const lost = outcome_of(&trace, false, .{ .count = 2, .whole = 2, .last = null });
    try std.testing.expectEqualStrings("invariant", lost.kind);
    try std.testing.expectEqual(1, lost.event.?);
    try std.testing.expectEqualStrings("behavior", outcome_of(&trace, true, null).kind);
    const plain_state = try plain(arena, states.last_value.?);
    try std.testing.expectEqual(7, plain_state.object.get("x").?.integer);
    const shown = try steps_of(arena, &trace, states);
    try std.testing.expectEqual(1, shown.len); // Its init, then the one event it took.
    try std.testing.expectEqual(1, shown[0].index);
    try std.testing.expectEqualStrings("a", shown[0].action);
    try std.testing.expectEqual(7, shown[0].state.object.get("x").?.integer);
    // What the event changed: x alone, from the init's value.
    try std.testing.expectEqual(1, shown[0].changes);
    try std.testing.expectEqualStrings("x", shown[0].changed[0].path);
    try std.testing.expectEqual(7, shown[0].changed[0].after.?.integer);
    const drawn = try series_of(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"states":[{"#meta":{"index":0},"n":{"#bigint":"1"},"b":{"#map":[[{"#bigint":"0"},{"#bigint":"100"}],[{"#bigint":"1"},{"#bigint":"100"}]]},"r":{"#map":[]}},
        \\{"#meta":{"index":1},"n":{"#bigint":"2"},"b":{"#map":[[{"#bigint":"0"},{"#bigint":"93"}],[{"#bigint":"1"},{"#bigint":"107"}]]},"r":{"#map":[]}},
        \\{"#meta":{"index":2}}]}
    , .{}));
    try std.testing.expectEqual(3, drawn.object.count()); // n, b.0, b.1: r has no number.
    try std.testing.expectEqual(2, drawn.object.get("n").?.array.items.len);
    try std.testing.expectEqual(93, drawn.object.get("b.0").?.array.items[1].integer);
    try std.testing.expectEqual(107, drawn.object.get("b.1").?.array.items[1].integer);
    try std.testing.expect(states_of(arena, "") == null);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"#meta":{"index":4},"balances":{"#map":[[{"#bigint":"0"},{"#bigint":"95"}],[{"#bigint":"1"},{"#bigint":"107"}]]},"reads":{"#map":[]},"seen":{"#set":["a"]},"pair":{"#tup":[true,[1]]}}
    , .{});
    var text: std.ArrayList(u8) = .empty;
    try itf_write(arena, &text, value);
    try std.testing.expectEqualStrings("{ balances: Map(0 -> 95, 1 -> 107), reads: Map(), seen: Set(\"a\"), pair: (true, [1]) }", text.items);
}
