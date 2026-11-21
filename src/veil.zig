// SPDX-License-Identifier: MIT
//! `determinismo veil`: a timeline checked against a Veil model (github.com/verse-lab/veil, Lean 4),
//! as `determinismo quint` checks one against a Quint spec. The timeline's output lines become the
//! module's action labels through a map, a label each line that matches one of its actions, its
//! argument the node the line came from; the module is replayed through them by Veil's `#replay`
//! (a Veil checkout with the replay patches: veil/patches in the private tree), from the instance's
//! initial states: refused at the first label no successor of the states so far takes, or a
//! property broken at the first state that breaks it, or accepted whole.
//!
//!   determinismo veil --module <M.lean> --map <map.json> --instance '{ node := Fin 3 }'
//!     [--theory '{}'] --events <run>/events --branch <n> --veil <checkout> [--lake <command>]
//!
//! The map: {"node_arg": "n", "actions": [{"name": "EnterLeader", "match": "entering leader
//! state"}, {"name": "TransferTimeout", "match": "leadership transfer timeout", "unless": "sent
//! response to client"}, ...]}, the first action whose `match` a line holds (and not its `unless`)
//! taking it. Exit 0 when accepted, 3 when refused or a property broke, 1 when it could not run.
const std = @import("std");
const event_files = @import("event_files.zig");

const events_size_max = 1 << 30;
const labels_max = 1 << 20;
const labels_file = "determinismo_veil_labels.json";
const module_file = "DeterminismoVeilReplay.lean";

const Action = struct { name: []const u8, match: []const u8, unless: ?[]const u8 = null };
const Map = struct { node_arg: []const u8 = "n", actions: []const Action };
/// A label and the line it came from: its moment, its node, its text.
const Label = struct { name: []const u8, node: u64, vtime_ns: u64, source: []const u8, text: []const u8 };

pub fn check(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    var module_path: ?[]const u8 = null;
    var map_path: ?[]const u8 = null;
    var instance: ?[]const u8 = null;
    var theory: []const u8 = "{}";
    var events: ?[]const u8 = null;
    var branch: ?u32 = null;
    var veil: ?[]const u8 = null;
    var lake: []const u8 = "lake";
    if (arguments.len % 2 != 0) return error.Usage;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--module")) {
            module_path = value;
        } else if (std.mem.eql(u8, flag, "--map")) {
            map_path = value;
        } else if (std.mem.eql(u8, flag, "--instance")) {
            instance = value;
        } else if (std.mem.eql(u8, flag, "--theory")) {
            theory = value;
        } else if (std.mem.eql(u8, flag, "--events")) {
            events = value;
        } else if (std.mem.eql(u8, flag, "--branch")) {
            branch = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--veil")) {
            veil = value;
        } else if (std.mem.eql(u8, flag, "--lake")) {
            lake = value;
        } else return error.Usage;
    }
    const cwd = std.Io.Dir.cwd();
    const module_text = try cwd.readFileAlloc(io, module_path orelse return error.Usage, arena, .limited(1 << 24));
    const map_text = try cwd.readFileAlloc(io, map_path orelse return error.Usage, arena, .limited(1 << 20));
    const map = try std.json.parseFromSliceLeaky(Map, arena, map_text, .{ .ignore_unknown_fields = true });
    const checkout = veil orelse return error.Usage;
    const events_path = events orelse return error.Usage;
    const source = if (branch) |timeline|
        try event_files.read(arena, io, events_path, timeline, .limited(events_size_max))
    else
        try cwd.readFileAlloc(io, events_path, arena, .limited(events_size_max));
    const labels = try labels_of(arena, source, map);
    if (labels.len == 0) {
        std.debug.print("[determinismo] no line of the timeline matches an action of the map ({d} actions)\n", .{map.actions.len});
        return 1;
    }
    const module_name = name_of(module_text) orelse {
        std.debug.print("[determinismo] {s} declares no `veil module <Name>`\n", .{module_path.?});
        return 1;
    };
    // The labels and the module with its #replay, in a directory of their own beside the module.
    const directory = try std.fs.path.join(arena, &.{ std.fs.path.dirname(module_path.?) orelse ".", ".determinismo-veil" });
    try cwd.createDirPath(io, directory);
    const absolute = try cwd.realPathFileAlloc(io, directory, arena);
    const labels_path = try std.fs.path.join(arena, &.{ absolute, labels_file });
    try cwd.writeFile(io, .{ .sub_path = labels_path, .data = try labels_json(arena, labels, map.node_arg) });
    const replay_path = try std.fs.path.join(arena, &.{ absolute, module_file });
    try cwd.writeFile(io, .{
        .sub_path = replay_path,
        .data = try with_replay(arena, module_text, module_name, instance orelse return error.Usage, theory, labels_path),
    });
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, lake, ' ');
    while (words.next()) |word| try argv.append(arena, word);
    if (argv.items.len == 0) return error.Usage;
    try argv.appendSlice(arena, &.{ "env", "lean", replay_path });
    const result = std.process.run(arena, io, .{ .argv = argv.items, .cwd = .{ .path = checkout } }) catch |err| {
        std.debug.print("[determinismo] `{s}` did not run in {s} ({s}): a Veil checkout with the replay patches, " ++
            "built (lake build), and Lean's `lake` (elan)\n", .{ lake, checkout, @errorName(err) });
        return 1;
    };
    const said = try std.mem.concat(arena, u8, &.{ result.stdout, "\n", result.stderr });
    const verdict = verdict_of(arena, said) orelse {
        std.debug.print("[determinismo] Veil gave no replay verdict; its output:\n{s}\n", .{said[0..@min(said.len, 4000)]});
        return 1;
    };
    return report(verdict, labels);
}

/// A module's name: what `veil module <Name>` declares.
fn name_of(text: []const u8) ?[]const u8 {
    const key = "veil module ";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    return if (end == 0) null else rest[0..end];
}

/// The module with its `#replay` before its `end <Name>` (after its `#gen_spec`).
fn with_replay(arena: std.mem.Allocator, text: []const u8, name: []const u8, instance: []const u8, theory: []const u8, labels_path: []const u8) ![]const u8 {
    const closing = try std.fmt.allocPrint(arena, "end {s}", .{name});
    const at = std.mem.lastIndexOf(u8, text, closing) orelse return error.NoModuleEnd;
    return std.fmt.allocPrint(arena, "{s}#replay interpreted {s} {s} (file := \"{s}\")\n\n{s}", .{
        text[0..at], instance, theory, labels_path, text[at..],
    });
}

/// The timeline's output lines that match an action of the map, as labels, in order.
fn labels_of(arena: std.mem.Allocator, source: []const u8, map: Map) ![]const Label {
    var found: std.ArrayList(Label) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"output\"") == null) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const event = parsed.object.get("event") orelse continue;
        if (event != .object) continue;
        const output = event.object.get("output") orelse continue;
        if (output != .object) continue;
        const text = switch (output.object.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const source_name = switch (output.object.get("source") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const node = node_of(source_name) orelse continue;
        for (map.actions) |action| {
            if (std.mem.indexOf(u8, text, action.match) == null) continue;
            if (action.unless) |unless| if (std.mem.indexOf(u8, text, unless) != null) continue;
            const vtime: u64 = switch (parsed.object.get("vtime_ns") orelse std.json.Value{ .integer = 0 }) {
                .integer => |n| @intCast(@max(n, 0)),
                else => 0,
            };
            if (found.items.len == labels_max) return error.TooManyLabels;
            try found.append(arena, .{ .name = action.name, .node = node, .vtime_ns = vtime, .source = source_name, .text = text });
            break;
        }
    }
    return found.items;
}

/// A source's trailing number: raft-node-2 is node 2.
fn node_of(source: []const u8) ?u64 {
    var start = source.len;
    while (start > 0 and std.ascii.isDigit(source[start - 1])) start -= 1;
    if (start == source.len) return null;
    return std.fmt.parseInt(u64, source[start..], 10) catch null;
}

fn labels_json(arena: std.mem.Allocator, labels: []const Label, node_arg: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"labels\":[");
    for (labels, 0..) |label, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"name\":\"{s}\",\"args\":[{{\"name\":\"{s}\",\"value\":{d}}}]}}", .{ label.name, node_arg, label.node });
    }
    try out.writer.writeAll("]}");
    return out.written();
}

const Verdict = struct { labels: u64 = 0, taken: u64 = 0, refused_at: ?u64 = null, violated_at: ?u64 = null, violates: []const []const u8 = &.{} };

/// `#replay`'s JSON line in Veil's output.
fn verdict_of(arena: std.mem.Allocator, said: []const u8) ?Verdict {
    const key = "{\"replay\":";
    const at = std.mem.indexOf(u8, said, key) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, said, at, '\n') orelse said.len;
    const Line = struct { replay: Verdict };
    const line = std.json.parseFromSliceLeaky(Line, arena, said[at..end], .{ .ignore_unknown_fields = true }) catch return null;
    return line.replay;
}

fn report(verdict: Verdict, labels: []const Label) u8 {
    if (verdict.refused_at) |step| {
        const label = labels[@intCast(@min(step - 1, labels.len - 1))];
        std.debug.print("[determinismo] the model refuses label {d} of {d}: {s}(node {d}) at {d}.{d:0>3} s, {s}: {s}\n", .{
            step, labels.len, label.name, label.node, label.vtime_ns / std.time.ns_per_s, (label.vtime_ns / std.time.ns_per_ms) % 1000, label.source, label.text,
        });
        return 3;
    }
    if (verdict.violated_at) |step| {
        const label = labels[@intCast(@min(@max(step, 1) - 1, labels.len - 1))];
        std.debug.print("[determinismo] {s} does not hold after label {d} of {d}: {s}(node {d}) at {d}.{d:0>3} s, {s}: {s}\n", .{
            if (verdict.violates.len > 0) verdict.violates[0] else "a property", step, labels.len, label.name, label.node,
            label.vtime_ns / std.time.ns_per_s, (label.vtime_ns / std.time.ns_per_ms) % 1000, label.source, label.text,
        });
        return 3;
    }
    std.debug.print("[determinismo] the timeline ({d} labels) is a run of the model, every property holding\n", .{verdict.taken});
    return 0;
}

test name_of {
    try std.testing.expectEqualStrings("StuckLeaderLog", name_of("module\n\nveil module StuckLeaderLog\n\ntype node\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), name_of("module X"));
}

test "a module gets its #replay before its end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try with_replay(arena_state.allocator(), "veil module M\n#gen_spec\n\nend M\n", "M", "{ node := Fin 3 }", "{}", "/l.json");
    try std.testing.expectEqualStrings("veil module M\n#gen_spec\n\n#replay interpreted { node := Fin 3 } {} (file := \"/l.json\")\n\nend M\n", out);
}

test "a timeline's lines as labels, a node from each line's source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const map: Map = .{ .actions = &.{
        .{ .name = "TransferTimeout", .match = "leadership transfer timeout", .unless = "sent response to client" },
        .{ .name = "EnterLeader", .match = "entering leader state" },
    } };
    const source =
        \\{"seq":1,"vtime_ns":1500000000,"event":{"output":{"source":"raft-node-2","text":"[INFO] node-2: entering leader state: x"}}}
        \\{"seq":2,"vtime_ns":2000000000,"event":{"output":{"source":"raft-node-2","text":"sent response to client: {\"err\":\"leadership transfer timeout\"}"}}}
        \\{"seq":3,"vtime_ns":2500000000,"event":{"output":{"source":"raft-node-0","text":"[DEBUG] node-0: leadership transfer timeout"}}}
        \\{"seq":4,"vtime_ns":3000000000,"event":{"event":"x","details":{}}}
    ;
    const labels = try labels_of(arena, source, map);
    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("EnterLeader", labels[0].name);
    try std.testing.expectEqual(@as(u64, 2), labels[0].node);
    try std.testing.expectEqualStrings("TransferTimeout", labels[1].name);
    try std.testing.expectEqual(@as(u64, 0), labels[1].node);
    try std.testing.expectEqualStrings("{\"labels\":[{\"name\":\"EnterLeader\",\"args\":[{\"name\":\"n\",\"value\":2}]},{\"name\":\"TransferTimeout\",\"args\":[{\"name\":\"n\",\"value\":0}]}]}", try labels_json(arena, labels, "n"));
}

test "Veil's verdict line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const said = "error: ❌ Violation\n{\"replay\":{\"file\":\"/l.json\",\"labels\":1209,\"refused_at\":null,\"taken\":1168,\"violated_at\":1168,\"violates\":[\"no_refusal_for_a_past_term\"]}}\n";
    const verdict = verdict_of(arena_state.allocator(), said).?;
    try std.testing.expectEqual(@as(u64, 1168), verdict.violated_at.?);
    try std.testing.expectEqualStrings("no_refusal_for_a_past_term", verdict.violates[0]);
    try std.testing.expectEqual(@as(?u64, null), verdict.refused_at);
    try std.testing.expectEqual(@as(?Verdict, null), verdict_of(arena_state.allocator(), "nothing"));
}
