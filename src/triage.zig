// SPDX-License-Identifier: MIT
//! `determinismo triage`: checker plugins over a run that ended, from its stored events. Each
//! timeline is told to the plugins as a run tells it (`branch`, its own events as they were
//! logged, `branch_end` with the properties it failed, `check`), and the verdicts they give are
//! the triage's: what a checker labels a timeline with ("known bug: #3217 via
//! core/io/mod.rs:278", a sometimes) once the bug is known, for runs made before it was, without
//! running them again. The calibrations' signature scripts (infra/calibrations/*.py), as plugins.
//!
//!   determinismo triage --events <dir> --strategy <plugin> [--strategy <plugin>]...
//!                       [--failing <file>] [--out <file>] [--json]
//!
//! `--events`: a run's events directory (its ended timelines, `branch-<n>.jsonl.zst`).
//! `--failing`: the properties each timeline failed, JSON lines `{"branch":N,"message":"..."}`
//! (serve's, from its store's timeline_failures: the store is one process's at a time); none
//! given, each `branch_end` says none. `--out`: the verdicts, a JSON line each
//! (`{"branch":N,"assert":{...}}`); standard output without it. `--json`: then, on standard
//! output, `{"triage":{"timelines":N,"verdicts":M,"labels":[{"type","message","held":[branch,
//! ...],"failed":[...]},...]}}`, the verdicts by message (serve's triage job's result).
//!
//! What differs from a run's telling: an event's `source` (the guest process that emitted it)
//! is not stored, so it is ""; a timeline's events are its own (a tree child's from its branch
//! point), as a run tells them; no histories (`sdk.record`'s) are given to `check`.
const std = @import("std");
const assert = std.debug.assert;
const Strategy = @import("strategy.zig");
const Strategies = @import("strategies.zig");
const event_files = @import("event_files.zig");
const Events = @import("core").events;

/// Timelines a triage reads at most (a run's: serve's largest are tens of thousands).
const timelines_max = 1 << 20;
/// A timeline's stored events read at most (a TiDB timeline's were 28 MB).
const timeline_size_max = 1 << 30;
/// Properties a timeline failed, told at most (as a run's branch_end tells).
const failing_max = 64;

const usage =
    \\usage: determinismo triage --events <dir> --strategy <plugin> [--strategy <plugin>]...
    \\                           [--failing <file>] [--out <file>] [--json]
    \\
;

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: [:null]const ?[*:0]const u8,
    argv: []const []const u8,
) !u8 {
    var events_directory: ?[]const u8 = null;
    var failing_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var commands: std.ArrayList(u8) = .empty;
    var json = false;
    var index: usize = 0;
    while (index < argv.len) {
        const flag = argv[index];
        if (std.mem.eql(u8, flag, "--json")) {
            json = true;
            index += 1;
            continue;
        }
        if (index + 1 == argv.len) return usage_error();
        const value = argv[index + 1];
        index += 2;
        if (std.mem.eql(u8, flag, "--events")) {
            events_directory = value;
        } else if (std.mem.eql(u8, flag, "--strategy")) {
            if (commands.items.len > 0) try commands.append(arena, '\n');
            try commands.appendSlice(arena, value);
        } else if (std.mem.eql(u8, flag, "--failing")) {
            failing_path = value;
        } else if (std.mem.eql(u8, flag, "--out")) {
            out_path = value;
        } else return usage_error();
    }
    const directory = events_directory orelse return usage_error();
    if (commands.items.len == 0) return usage_error();

    const failing = if (failing_path) |path| try failing_read(arena, io, path) else Failing{};
    const branches = try timelines_list(arena, io, directory);

    var strategies: Strategies = undefined;
    try strategies.start(arena, commands.items, environ, null);
    defer strategies.stop();
    try strategies.hello(0, null);

    var out_file: ?std.Io.File = null;
    defer if (out_file) |file| file.close(io);
    if (out_path) |path| out_file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = if (out_file) |file| file.writer(io, &out_buffer) else std.Io.File.stdout().writer(io, &out_buffer);

    const buffer = try arena.alloc(u8, Strategy.check_assertions_max * Strategy.check_line_size_max);
    var lines: [Strategy.check_assertions_max][]const u8 = undefined;
    var verdicts: u64 = 0;
    var labels: Labels = .{};
    // A timeline's events, read whole, freed before the next: a run's are hundreds of GB.
    var timeline_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer timeline_arena.deinit();
    for (branches) |branch| {
        _ = timeline_arena.reset(.retain_capacity);
        _ = try strategies.branch(branch, 0, null);
        const text = try event_files.read(timeline_arena.allocator(), io, directory, branch, .limited(timeline_size_max));
        var told: u64 = 0;
        var stored = std.mem.splitScalar(u8, text, '\n');
        while (stored.next()) |line| {
            const event = stored_event(line) orelse continue;
            _ = try strategies.event(event.moment, "", event.data);
            told += 1;
        }
        // Judged, then ended: a run's order (its end checks, then branch_end).
        if (strategies.wants_check) {
            const count = try strategies.judge(branch, &.{}, buffer, &lines);
            for (lines[0..count]) |verdict| {
                // An assertion event line, `{"assert":{...}}`: the branch beside it.
                assert(verdict.len > 2 and verdict[0] == '{');
                try writer.interface.print("{{\"branch\":{d},{s}\n", .{ branch, verdict[1..] });
                verdicts += 1;
                if (json) try labels.add(arena, branch, verdict);
            }
        }
        _ = try strategies.branch_end(.{
            .index = branch,
            .outcome = "stored",
            .events = told,
            .failing = failing.of(branch),
        });
    }
    try writer.interface.flush();
    std.debug.print("[determinismo] triage: {d} timelines, {d} verdicts\n", .{ branches.len, verdicts });
    if (json) {
        var summary_buffer: [64 * 1024]u8 = undefined;
        var summary = std.Io.File.stdout().writer(io, &summary_buffer);
        try summary.interface.print("{{\"triage\":{{\"timelines\":{d},\"verdicts\":{d},\"labels\":[", .{ branches.len, verdicts });
        for (labels.list.items, 0..) |label, position| {
            if (position > 0) try summary.interface.writeAll(",");
            try summary.interface.print("{{\"type\":{f},\"message\":{f},\"held\":{f},\"failed\":{f}}}", .{
                std.json.fmt(label.type, .{}),       std.json.fmt(label.message, .{}),
                std.json.fmt(label.held.items, .{}), std.json.fmt(label.failed.items, .{}),
            });
        }
        try summary.interface.writeAll("]}}\n");
        try summary.interface.flush();
    }
    return 0;
}

/// The verdicts by message: the timelines where each held and where it failed (at most
/// label_timelines_max of each, the summary's: the verdicts file has them all).
const label_timelines_max = 10_000;
const labels_max = 1024;

const Labels = struct {
    list: std.ArrayList(Label) = .empty,
    by_message: std.StringHashMapUnmanaged(u32) = .empty,

    const Label = struct {
        type: []const u8,
        message: []const u8,
        held: std.ArrayList(u32) = .empty,
        failed: std.ArrayList(u32) = .empty,
    };

    fn add(labels: *Labels, arena: std.mem.Allocator, branch: u32, verdict: []const u8) !void {
        const Verdict = struct { assert: struct { type: []const u8, message: []const u8, condition: bool } };
        const parsed = std.json.parseFromSliceLeaky(Verdict, arena, verdict, .{ .ignore_unknown_fields = true }) catch return;
        const entry = try labels.by_message.getOrPut(arena, parsed.assert.message);
        if (!entry.found_existing) {
            if (labels.list.items.len == labels_max) {
                _ = labels.by_message.remove(parsed.assert.message);
                return;
            }
            entry.value_ptr.* = @intCast(labels.list.items.len);
            try labels.list.append(arena, .{ .type = parsed.assert.type, .message = parsed.assert.message });
        }
        const label = &labels.list.items[entry.value_ptr.*];
        const timelines = if (parsed.assert.condition) &label.held else &label.failed;
        if (timelines.items.len < label_timelines_max) try timelines.append(arena, branch);
    }
};

fn usage_error() u8 {
    std.debug.print("{s}", .{usage});
    return 2;
}

/// A stored event line (core/events.zig's write_log_line):
/// `{"seq":S,"vtime_ns":T,"branches":C,"event":<event>}`; null for the lines that are not one
/// (a checkpoint, a tree child's path).
const Stored = struct { moment: Events.Moment, data: []const u8 };

fn stored_event(line: []const u8) ?Stored {
    const head = "{\"seq\":";
    if (!std.mem.startsWith(u8, line, head) or line[line.len - 1] != '}') return null;
    var rest = line[head.len..];
    _ = number_take(&rest, ",\"vtime_ns\":") orelse return null;
    const vtime_ns = number_take(&rest, ",\"branches\":") orelse return null;
    const branches = number_take(&rest, ",\"event\":") orelse return null;
    if (rest.len < 3) return null;
    return .{ .moment = .{ .vtime_ns = vtime_ns, .branches = branches }, .data = rest[0 .. rest.len - 1] };
}

/// The number at the start of `rest`, which `next` must follow; `rest` moved past both.
fn number_take(rest: *[]const u8, next: []const u8) ?u64 {
    const end = std.mem.indexOfNone(u8, rest.*, "0123456789") orelse return null;
    const value = std.fmt.parseInt(u64, rest.*[0..end], 10) catch return null;
    if (!std.mem.startsWith(u8, rest.*[end..], next)) return null;
    rest.* = rest.*[end + next.len ..];
    return value;
}

/// The ended timelines in `directory`, by number.
fn timelines_list(arena: std.mem.Allocator, io: std.Io, directory_path: []const u8) ![]u32 {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var found: std.ArrayList(u32) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, event_files.ended_suffix)) continue;
        const branch = event_files.index_of(entry.name) orelse continue;
        if (found.items.len == timelines_max) return error.TooManyTimelines;
        try found.append(arena, branch);
    }
    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.items;
}

/// Each timeline's failed properties (--failing's lines), by branch.
const Failing = struct {
    by_branch: std.AutoHashMapUnmanaged(u32, std.ArrayList([]const u8)) = .empty,

    fn of(failing: *const Failing, branch: u32) []const []const u8 {
        const names = failing.by_branch.get(branch) orelse return &.{};
        return names.items[0..@min(names.items.len, failing_max)];
    }
};

fn failing_read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Failing {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20));
    var failing: Failing = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        const Line = struct { branch: u32, message: []const u8 };
        const parsed = try std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true });
        const entry = try failing.by_branch.getOrPut(arena, parsed.branch);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, parsed.message);
    }
    return failing;
}

test "a stored event line's moment and event" {
    const line = "{\"seq\":52,\"vtime_ns\":746376925,\"branches\":12,\"event\":{\"event\":\"fault_injector\"}}";
    const event = stored_event(line).?;
    try std.testing.expectEqual(@as(u64, 746376925), event.moment.vtime_ns);
    try std.testing.expectEqual(@as(u64, 12), event.moment.branches);
    try std.testing.expectEqualStrings("{\"event\":\"fault_injector\"}", event.data);
    try std.testing.expect(stored_event("{\"checkpoint\":{\"vtime_ns\":1,\"branches\":2}}") == null);
    try std.testing.expect(stored_event("{\"path\":[1,2]}") == null);
}
