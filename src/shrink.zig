// SPDX-License-Identifier: MIT
//! `determinismo shrink`: the fewest faults a failure needs. From a failing timeline's script
//! (`determinismo script`), delta debugging (Zeller and Hildebrandt's ddmin) over its fault
//! entries, each candidate explored as a script (`explore --script`).
//!
//! A script fixes what the composer and the fault injector decided and the seed the rest; a
//! fault removed shifts the guest's one random stream, so whether one timeline fails again is
//! chance. A candidate is judged over the same timelines each time (the same seeds, flat: each
//! one independent): it reproduces the failure when it fails in at least half as many of them
//! as the whole script does. Reports the faults kept, the failure counts with them, with the
//! whole script and with none, and writes the shrunk script (`--out`, for `explore --script`).
//!
//!   determinismo shrink <explore options> --property '<message>'
//!     (--script <script.json> | --seed <s> --branch <n> | --tape <branch.jsonl>)
//!     [--timelines <n>] [--out <path>] [--json] [--strategy <plugin>]...
//!
//! With `--strategy`, a plugin that wants "shrink" proposes cuts first (Strategy.shrink: by
//! node, by time window, whatever it knows of the system): its candidates judged round after
//! round, each result told back, and ddmin starts from the smallest that reproduces the
//! failure. A failure needing several faults on one node is found in a few explorations where
//! ddmin's halves split them.
//!
//! From a branch (or a tape), its script is made first: the branch replayed with its events,
//! then `determinismo script`.
const std = @import("std");
const assert = std.debug.assert;
const Strategies = @import("strategies.zig");

const timelines_default = 16;
const timelines_max = 256;
/// Faults a script may have: ddmin's candidates grow with their square at worst.
const faults_max = 512;
/// A plugin's rounds at most, and its candidates judged at most: each one an exploration.
const plugin_rounds_max = 16;
const plugin_candidates_max = 128;

const Request = struct {
    script: []const u8 = "",
    /// Instead of a script, the failing branch to make one from: the exploration's seed and
    /// the branch, or its tape.
    seed: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    tape: ?[]const u8 = null,
    property: []const u8 = "",
    timelines: u32 = timelines_default,
    out: ?[]const u8 = null,
    json: bool = false,
    /// Plugins proposing cuts (`--strategy`, one a line): explore never gets them.
    strategy: ?[]const u8 = null,
    /// The explore options: the system, its scenario and profile.
    rest: []const []const u8 = &.{},
};

const Shrinker = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
    /// The script as read; its "faults" replaced for each candidate.
    script: std.json.Value,
    faults: []const std.json.Value,
    candidate_path: []const u8,
    explorations: u32 = 0,

    /// In how many of the timelines the property failed with these faults (indexes into
    /// `faults`), the other entries of the script as they were.
    fn failing(shrinker: *Shrinker, kept: []const u32) !u32 {
        const arena = shrinker.arena;
        try shrinker.script_write(kept, shrinker.candidate_path);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ shrinker.self, "explore" });
        try argv.appendSlice(arena, shrinker.request.rest);
        try argv.appendSlice(arena, &.{
            "--script",    shrinker.candidate_path,
            "--seed",      "1",
            "--branches",  try std.fmt.allocPrint(arena, "{d}", .{shrinker.request.timelines}),
            "--branching", "flat",
        });
        const result = try std.process.run(arena, shrinker.io, .{ .argv = argv.items });
        shrinker.explorations += 1;
        const report = try report_of(arena, result);
        const count = failing_in(report, shrinker.request.property) orelse {
            if (!std.mem.containsAtLeast(u8, report, 1, " branches, ")) {
                std.debug.print("[determinismo] shrink: the exploration gave no report:\n{s}\n", .{
                    result.stderr[result.stderr.len -| 2000..],
                });
                return error.ExploreFailed;
            }
            return 0; // Reported, the property never evaluated: it did not fail.
        };
        std.debug.print("[determinismo] shrink: {d} faults, failing in {d}/{d}\n", .{
            kept.len, count, shrinker.request.timelines,
        });
        return count;
    }

    /// The script with these faults alone, at `path`.
    fn script_write(shrinker: *Shrinker, kept: []const u32, path: []const u8) !void {
        const arena = shrinker.arena;
        var entries = try std.json.Array.initCapacity(arena, kept.len);
        for (kept) |index| entries.appendAssumeCapacity(shrinker.faults[index]);
        var script = try shrinker.script.object.clone(arena);
        try script.put(arena, "faults", .{ .array = entries });
        const text = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(std.json.Value{ .object = script }, .{})});
        try std.Io.Dir.cwd().writeFile(shrinker.io, .{ .sub_path = path, .data = text });
    }
};

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    environ: [:null]const ?[*:0]const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var request = try arguments_parse(arena, arguments);
    if (request.script.len == 0) request.script = try script_make(arena, io, self, &request);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, request.script, arena, .limited(1 << 26));
    const script = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    if (script != .object) return error.ScriptInvalid;
    const faults_value = script.object.get("faults") orelse return error.ScriptInvalid;
    if (faults_value != .array) return error.ScriptInvalid;
    const faults = faults_value.array.items;
    if (faults.len > faults_max) {
        std.debug.print("[determinismo] shrink: {d} faults, more than {d}\n", .{ faults.len, faults_max });
        return error.Usage;
    }
    var shrinker = Shrinker{
        .arena = arena,
        .io = io,
        .self = self,
        .request = &request,
        .script = script,
        .faults = faults,
        .candidate_path = try std.fmt.allocPrint(arena, "/tmp/determinismo-shrink-{d}.json", .{
            std.os.linux.getpid(),
        }),
    };
    defer std.Io.Dir.cwd().deleteFile(io, shrinker.candidate_path) catch {};

    const all = try arena.alloc(u32, faults.len);
    for (all, 0..) |*index, at| index.* = @intCast(at);
    const whole = try shrinker.failing(all);
    if (whole == 0) {
        std.debug.print("[determinismo] shrink: '{s}' fails in none of {d} timelines with the " ++
            "whole script: nothing to shrink (more --timelines?)\n", .{ request.property, request.timelines });
        // Still an answer for whoever reads JSON (serve's shrink job, the MCP tool, e2e).
        if (request.json) {
            var buffer: [1024]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
            try stdout.interface.print("{f}\n", .{std.json.fmt(.{ .shrink = .{
                .property = request.property,
                .timelines = request.timelines,
                .faults = faults.len,
                .failing_whole = 0,
                .reproduced = false,
                .explorations = shrinker.explorations,
            } }, .{})});
            try stdout.interface.flush();
        }
        return 1;
    }
    const needed = @max(1, (whole + 1) / 2);
    const none = try shrinker.failing(&.{});
    const start = if (request.strategy) |commands| if (none >= needed) all else try plugin_cuts(arena, environ, &shrinker, commands, all, .{
        .whole = whole,
        .none = none,
        .needed = needed,
    }) else all;
    const kept = if (none >= needed) &[_]u32{} else try ddmin(arena, &shrinker, start, needed);
    const with_kept = if (kept.len == 0) none else if (kept.len == faults.len) whole else try shrinker.failing(kept);

    const out_path = request.out orelse try std.fmt.allocPrint(arena, "{s}.shrunk.json", .{request.script});
    try shrinker.script_write(kept, out_path);

    var buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    if (request.json) {
        var kept_faults = try std.json.Array.initCapacity(arena, kept.len);
        for (kept) |index| kept_faults.appendAssumeCapacity(faults[index]);
        try out.print("{f}\n", .{std.json.fmt(.{ .shrink = .{
            .property = request.property,
            .timelines = request.timelines,
            .faults = faults.len,
            .failing_whole = whole,
            .failing_none = none,
            .failing_kept = with_kept,
            .kept = std.json.Value{ .array = kept_faults },
            .explorations = shrinker.explorations,
            .script = out_path,
        } }, .{})});
    } else {
        try out.print("'{s}' over {d} timelines: fails in {d} with all {d} faults, {d} with none\n", .{
            request.property, request.timelines, whole, faults.len, none,
        });
        if (kept.len == 0) {
            try out.print("it needs no fault: it fails without any\n", .{});
        } else {
            try out.print("it needs {d} of them (fails in {d} with them alone):\n", .{ kept.len, with_kept });
            for (kept) |index| try out.print("  {f}\n", .{std.json.fmt(faults[index], .{})});
        }
        try out.print("{d} explorations; the shrunk script: {s} (explore --script)\n", .{
            shrinker.explorations, out_path,
        });
    }
    try out.flush();
    return 0;
}

/// The failing branch's script (`determinismo script` of its events, replayed), in /tmp.
fn script_make(arena: std.mem.Allocator, io: std.Io, self: []const u8, request: *const Request) ![]const u8 {
    const pid = std.os.linux.getpid();
    const events = try std.fmt.allocPrint(arena, "/tmp/determinismo-shrink-{d}.events.jsonl", .{pid});
    defer std.Io.Dir.cwd().deleteFile(io, events) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    if (request.tape) |tape| {
        try argv.appendSlice(arena, &.{ "--tape", tape });
    } else {
        try argv.appendSlice(arena, &.{ "--seed", request.seed.?, "--branch", request.branch.? });
    }
    try argv.appendSlice(arena, &.{ "--events", events });
    const replay = try std.process.run(arena, io, .{ .argv = argv.items });
    const report = try report_of(arena, replay);
    // No report: the replay itself was refused or failed (a tape recorded on other inputs: runs
    // from before a modulation_version change), which a shrink from a run's page read as the
    // property not failing.
    if (!std.mem.containsAtLeast(u8, report, 1, " branches, ")) {
        std.debug.print("[determinismo] shrink: the branch could not be replayed:\n{s}\n", .{
            replay.stderr[replay.stderr.len -| 2000..],
        });
        return error.ReplayFailed;
    }
    if (failing_in(report, request.property) orelse 0 == 0) {
        std.debug.print("[determinismo] shrink: '{s}' does not fail in the branch replayed\n", .{request.property});
        return error.NotFailing;
    }
    const script = try std.process.run(arena, io, .{ .argv = &.{ self, "script", events } });
    const path = try std.fmt.allocPrint(arena, "/tmp/determinismo-shrink-{d}.script.json", .{pid});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script.stdout });
    std.debug.print("[determinismo] shrink: the branch's script: {s}\n", .{path});
    return path;
}

/// ddmin: the smallest subset of `items` found that still fails in `needed` timelines or more
/// (`judge.failing(subset)`), each element of it needed (removing any one fails fewer).
const Judged = struct { whole: u32, none: u32, needed: u32 };
const Tried = struct { kept: []const u32, failing: u32 };

/// A plugin's cuts (Strategy.shrink), before ddmin: asked with every result so far, its
/// candidates judged in turn; the smallest that reproduces the failure is ddmin's start.
fn plugin_cuts(
    arena: std.mem.Allocator,
    environ: [:null]const ?[*:0]const u8,
    shrinker: *Shrinker,
    commands: []const u8,
    all: []const u32,
    judged: Judged,
) ![]const u32 {
    var strategies: Strategies = undefined;
    try strategies.start(arena, commands, environ, null);
    defer strategies.stop();
    try strategies.hello(0, null);
    var tried: std.ArrayList(Tried) = .empty;
    try tried.append(arena, .{ .kept = all, .failing = judged.whole });
    try tried.append(arena, .{ .kept = &.{}, .failing = judged.none });
    var best = all;
    var count: u32 = 0;
    rounds: for (0..plugin_rounds_max) |_| {
        var request: std.Io.Writer.Allocating = .init(arena);
        try request.writer.print("{{\"method\":\"shrink\",\"property\":{f},\"needed\":{d},\"timelines\":{d},\"faults\":{f},\"tried\":{f}}}", .{
            std.json.fmt(shrinker.request.property, .{}), judged.needed,                  shrinker.request.timelines,
            std.json.fmt(shrinker.faults, .{}),           std.json.fmt(tried.items, .{}),
        });
        const candidates = try strategies.shrink(arena, request.written(), shrinker.faults.len);
        if (candidates.len == 0) break;
        for (candidates) |candidate| {
            if (count == plugin_candidates_max) break :rounds;
            const failing = try shrinker.failing(candidate);
            count += 1;
            try tried.append(arena, .{ .kept = candidate, .failing = failing });
            if (failing >= judged.needed and candidate.len < best.len) best = candidate;
        }
    }
    std.debug.print("[determinismo] shrink: the plugin's {d} candidates judged; ddmin starts from {d} faults\n", .{ count, best.len });
    return best;
}

fn ddmin(arena: std.mem.Allocator, judge: anytype, items: []const u32, needed: u32) ![]const u32 {
    var current = items;
    var granularity: usize = 2;
    while (current.len >= 2) {
        const chunk_size = (current.len + granularity - 1) / granularity;
        var reduced = false;
        // A chunk alone reproducing it, then a complement (the rest without a chunk).
        var start: usize = 0;
        while (start < current.len and !reduced) : (start += chunk_size) {
            const chunk = current[start..@min(start + chunk_size, current.len)];
            if (try judge.failing(chunk) >= needed) {
                current = try arena.dupe(u32, chunk);
                granularity = 2;
                reduced = true;
            }
        }
        start = 0;
        while (start < current.len and !reduced and granularity > 2) : (start += chunk_size) {
            const end = @min(start + chunk_size, current.len);
            const complement = try std.mem.concat(arena, u32, &.{ current[0..start], current[end..] });
            if (try judge.failing(complement) >= needed) {
                current = complement;
                granularity = @max(granularity - 1, 2);
                reduced = true;
            }
        }
        if (reduced) continue;
        if (granularity >= current.len) break;
        granularity = @min(granularity * 2, current.len);
    }
    return current;
}

/// An exploration's report: explore writes it with its progress, on stderr (the shrink job in
/// serve read stdout alone and found every failing branch passing; srv4, 2026-10-31); both.
fn report_of(arena: std.mem.Allocator, result: std.process.RunResult) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
}

/// In how many timelines a property failed, from its report line ("failing in    3  <message>",
/// then its example and its place in the code when it has them).
fn failing_in(report: []const u8, message: []const u8) ?u32 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const count = property_count(std.mem.trimEnd(u8, line, " "), message) orelse continue;
        return count;
    }
    return null;
}

/// The count of a report line of `message`'s property: "...failing in    3  <message>", then
/// the line's end, its example ("  (e.g. --branch 0)") or its place ("  at bank_test.zig:167
/// audit"). The place, added to the report since shrinking was built, made every property read
/// as never failing: the e2e shrink check's whole script "failed in none of 8" where explore
/// counted 8 (2026-11-01).
fn property_count(line: []const u8, message: []const u8) ?u32 {
    const start = std.mem.indexOf(u8, line, "failing in ") orelse return null;
    const rest = std.mem.trimStart(u8, line[start + "failing in ".len ..], " ");
    const count_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const count = std.fmt.parseInt(u32, rest[0..count_end], 10) catch return null;
    const text = rest[count_end..];
    if (!std.mem.startsWith(u8, text, "  ") or !std.mem.startsWith(u8, text[2..], message)) return null;
    const after = text[2 + message.len ..];
    const whole = after.len == 0 or std.mem.startsWith(u8, after, "  (e.g.") or std.mem.startsWith(u8, after, "  at ");
    return if (whole) count else null;
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Request {
    var request = Request{};
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--json")) {
            request.json = true;
            continue;
        }
        const ours = eql(u8, flag, "--script") or eql(u8, flag, "--property") or
            eql(u8, flag, "--timelines") or eql(u8, flag, "--out") or eql(u8, flag, "--seed") or
            eql(u8, flag, "--branch") or eql(u8, flag, "--tape") or eql(u8, flag, "--strategy");
        if (!ours) {
            if (eql(u8, flag, "--branches") or eql(u8, flag, "--branching")) {
                std.debug.print("[determinismo] shrink: {s} is its own (the same timelines for every candidate)\n", .{flag});
                return error.Usage;
            }
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (eql(u8, flag, "--strategy")) {
            request.strategy = if (request.strategy) |earlier| try std.fmt.allocPrint(arena, "{s}\n{s}", .{ earlier, value }) else value;
        } else if (eql(u8, flag, "--script")) {
            request.script = value;
        } else if (eql(u8, flag, "--property")) {
            request.property = value;
        } else if (eql(u8, flag, "--timelines")) {
            request.timelines = try std.fmt.parseInt(u32, value, 10);
            if (request.timelines == 0 or request.timelines > timelines_max) return error.Usage;
        } else if (eql(u8, flag, "--out")) {
            request.out = value;
        } else if (eql(u8, flag, "--seed")) {
            request.seed = value;
        } else if (eql(u8, flag, "--branch")) {
            request.branch = value;
        } else if (eql(u8, flag, "--tape")) {
            request.tape = value;
        }
    }
    const branch = request.seed != null and request.branch != null;
    const sources = @as(u32, @intFromBool(request.script.len > 0)) + @intFromBool(branch) +
        @intFromBool(request.tape != null);
    if (sources != 1 or request.property.len == 0) return error.Usage;
    request.rest = rest.items;
    return request;
}

test "ddmin keeps what a failure needs" {
    // A stand-in for explorations: fails in 16 of 16 only while faults 3 and 7 are both kept.
    const Judge = struct {
        calls: u32 = 0,
        fn failing(judge: *@This(), kept: []const u32) !u32 {
            judge.calls += 1;
            var three = false;
            var seven = false;
            for (kept) |index| {
                three = three or index == 3;
                seven = seven or index == 7;
            }
            return if (three and seven) 16 else 0;
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var items: [40]u32 = undefined;
    for (&items, 0..) |*item, index| item.* = @intCast(index);
    var judge = Judge{};
    const kept = try ddmin(arena_state.allocator(), &judge, &items, 8);
    try std.testing.expectEqualSlices(u32, &.{ 3, 7 }, kept);
    try std.testing.expect(judge.calls < 100); // Not every subset: about 2 log 40 steps each.
}

test "failing_in reads a report's property line" {
    const report =
        \\32 branches, 3 with failing properties
        \\  FAIL always                hit in   32/32 branches, failing in    3  no process crashes: race
        \\  ok   sometimes             hit in   12/32 branches, failing in    0  a race
        \\  FAIL always                hit in    8/8 branches, failing in    8  total balance is conserved  (e.g. --branch 0)  at bank_test.zig:167 audit
        \\  PASS sometimes             hit in    8/8 branches, failing in    0  anytime audit ran  at bank_test.zig:168 audit
        \\  FAIL always                hit in    8/8 branches, failing in    2  total balance is conserved twice  (e.g. --branch 1)
    ;
    try std.testing.expectEqual(@as(?u32, 3), failing_in(report, "no process crashes: race"));
    try std.testing.expectEqual(@as(?u32, 0), failing_in(report, "a race"));
    try std.testing.expectEqual(@as(?u32, null), failing_in(report, "unknown"));
    try std.testing.expectEqual(@as(?u32, 8), failing_in(report, "total balance is conserved"));
    try std.testing.expectEqual(@as(?u32, 0), failing_in(report, "anytime audit ran"));
}
