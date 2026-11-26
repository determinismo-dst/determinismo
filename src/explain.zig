// SPDX-License-Identifier: MIT
//! `determinismo explain`: which details of a failure's last faults it needed (Hypothesis's
//! explain phase, docs/PLAN.md): each detail of each fault drawn again in the failing timeline,
//! everything else as it was, and whether the property still fails.
//!
//!   determinismo explain <machine and system options> (--tape <tape> | --run <dir> --branch <n>)
//!       --property '<message>' [--faults <k>] [--variants <m>] [--jobs <j>] [--json]
//!       [--seed-variants <s>]   (the variants' values: 1 by default, the same explanation again)
//!       [--draw <name>[=<v>,<v>...]]...   (a named draw of the scenario's own, varied too)
//!
//! A scenario's own requests are drawn by its workload (a clock step's size, whether a driver
//! acts): `--draw <name>` varies that named draw's last pull before the failure as a fault's
//! details are (m fresh values, against the control), and `--draw <name>=0,1000` sets it to each
//! value given instead, m times each: "the step removed, or under twice the interval" (Datomic's
//! #3, whose step explain could not vary). The guest takes each value modulo the draw's range.
//!
//! A fault is a decision of named pulls (guest/runtime/faults.zig): its kind (`fault.kind`, by the
//! timeline's weights), which one (`fault`), its length, and the wait to the next (`fault.wait_ns`).
//! A variant is the timeline's tape with one of those pulls overridden (a pull's u64 modulo its
//! range is what the guest takes), replayed to the failure.
//!
//! 1. One replay to the property's first failure writes its events (`--events`) and its named
//!    draws (`--draws-out`: each label's last values, with their pulls).
//! 2. The last k fault decisions whose pick was no restore, each whole among the kept draws.
//! 3. A second replay saves the timeline a millisecond before the earliest varied pull.
//! 4. The variants go on from there (`--tape-snapshot`), to the failure or a horizon: the failure
//!    plus its distance from the snapshot (`--until '<failure> or vtime>=<horizon>'`). Per fault:
//!    a control (the first other draw after it, varied as often: the timeline's own chance of
//!    failing again once its history parts there), the fault removed (its kind drawn into the
//!    regime's restore weights), and each of its pulls m times.
//! 5. A verdict per detail against its fault's control, by their 90% intervals (Wilson's, as
//!    causality's): needed (none fails, its interval wholly below the control's), partly (some
//!    fail, wholly below), free (it fails as often as the control), unclear (fewer fail, but
//!    the intervals overlap: more variants would tell; or the control never fails). Six variants
//!    once called a wait needed (0 of 6) that another six found half the time (3 of 6).
//!
//! Prototyped on bank's timelines (docs/PLAN.md): the balance race needs no fault; a client's
//! parse of a reply cut by a fault needs the next fault ~6 ms after the last isolation.
const std = @import("std");
const assert = std.debug.assert;
const cpus = @import("cpus.zig");
const wilson = @import("causality.zig").wilson;

pub const faults_max = 16;
pub const variants_max = 64;
/// Each draw's label, as the draws file names them; a decision is a `fault.kind` pull and the
/// fault pulls after it up to the next.
const decision_first = "fault.kind";

const Request = struct {
    property: []const u8,
    tape: []const u8,
    faults: u32 = 3,
    variants: u32 = 6,
    jobs: u32 = 0,
    json: bool = false,
    /// The variants' fresh values (fixed: the same explanation each time).
    seed: u64 = 1,
    /// The explore options every replay is given (machine, system, `--run`).
    rest: []const []const u8,
    /// Named draws of the scenario's own to vary (`--draw`), beside the faults.
    draws: []const DrawAsked = &.{},
};

pub const DrawAsked = struct {
    name: []const u8,
    /// The values to set it to, each m times; none: m fresh values.
    values: []const u64 = &.{},

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !DrawAsked {
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse return .{ .name = text };
        if (equals == 0) return error.Usage;
        var values: std.ArrayList(u64) = .empty;
        var parts = std.mem.tokenizeScalar(u8, text[equals + 1 ..], ',');
        while (parts.next()) |part| try values.append(arena, try std.fmt.parseInt(u64, part, 0));
        if (values.items.len == 0) return error.Usage;
        return .{ .name = text[0..equals], .values = values.items };
    }
};

pub const Draw = struct {
    pull: u64,
    after_ns: u64,
    name: []const u8,
    count: u64,
    value: u64,
    /// The option's name, for a decision among options.
    option: ?[]const u8 = null,
    /// Every option's name, for a decision among options.
    options: ?[]const []const u8 = null,
    /// A value its variants set it to (`--draw <name>=<values>`), instead of fresh ones.
    set: ?u64 = null,

    fn fault(draw: Draw) bool {
        return std.mem.startsWith(u8, draw.name, "fault");
    }

    fn restore(draw: Draw) bool {
        return std.mem.eql(u8, draw.name, "fault") and draw.option != null and
            std.mem.eql(u8, draw.option.?, "restore");
    }
};

pub const Regime = struct { vtime_ns: u64, kinds: []const u8 };

pub const Verdict = enum { needed, partly, free, unclear };

/// A detail's verdict from how many of its variants failed, against its fault's control.
pub fn verdict(failing: u32, of: u32, control_failing: u32, control_of: u32) Verdict {
    assert(of > 0 and failing <= of and control_failing <= control_of);
    if (control_of == 0 or control_failing == 0) return .unclear;
    // As often as the control (or more): nothing says the detail mattered.
    if (@as(u64, failing) * control_of >= @as(u64, control_failing) * of) return .free;
    if (wilson(failing, of).high < wilson(control_failing, control_of).low) {
        return if (failing == 0) .needed else .partly;
    }
    return .unclear;
}

/// The `fault.kind` value that picks a restore in a regime's weights (`fault_swarm`'s kinds, in
/// pick order, each weight at least 1: faults.zig's fault_weighted); null without restores.
pub fn restore_value(kinds: []const u8) ?u64 {
    var start: u64 = 0;
    var parts = std.mem.tokenizeScalar(u8, kinds, ' ');
    while (parts.next()) |part| {
        const colon = std.mem.lastIndexOfScalar(u8, part, ':') orelse return null;
        const weight = std.fmt.parseInt(u64, part[colon + 1 ..], 10) catch return null;
        if (std.mem.eql(u8, part[0..colon], "restore")) return start;
        start += @max(weight, 1);
    }
    return null;
}

/// The fault decisions among `draws` (in pull order): each from its `fault.kind` pull (or, in a
/// timeline without kind weights, its `fault` pick: faults.zig's fault_weighted) to the next,
/// the fault draws only; those starting before `complete_from` (a label's draws not all kept
/// there) left out.
pub fn decisions_of(arena: std.mem.Allocator, draws: []const Draw, complete_from: u64) ![]const []const Draw {
    var decisions: std.ArrayList([]const Draw) = .empty;
    var current: std.ArrayList(Draw) = .empty;
    for (draws) |draw| {
        if (!draw.fault()) continue;
        const pick = std.mem.eql(u8, draw.name, "fault");
        const picked = for (current.items) |earlier| {
            if (std.mem.eql(u8, earlier.name, "fault")) break true;
        } else false;
        if (std.mem.eql(u8, draw.name, decision_first) or (pick and (current.items.len == 0 or picked))) {
            if (current.items.len > 0 and current.items[0].pull >= complete_from) try decisions.append(arena, current.items);
            current = .empty;
            try current.append(arena, draw);
        } else if (current.items.len > 0) try current.append(arena, draw);
    }
    if (current.items.len > 0 and current.items[0].pull >= complete_from) try decisions.append(arena, current.items);
    return decisions.items;
}

/// Each named draw asked for (`--draw`): its last pull before the failure as a decision of its
/// own, one detail per value to set (or one of fresh values). error.DrawNotFound when the
/// timeline drew none by that name before it fails.
pub fn named_decisions(arena: std.mem.Allocator, draws: []const Draw, asked: []const DrawAsked) ![]const []const Draw {
    var decisions: std.ArrayList([]const Draw) = .empty;
    for (asked) |wanted| {
        var last: ?Draw = null;
        for (draws) |draw| if (std.mem.eql(u8, draw.name, wanted.name)) {
            last = draw;
        };
        const found = last orelse {
            std.debug.print("[determinismo] explain: no draw named '{s}' before the failure\n", .{wanted.name});
            return error.DrawNotFound;
        };
        if (wanted.values.len == 0) {
            try decisions.append(arena, try arena.dupe(Draw, &.{found}));
            continue;
        }
        const details = try arena.alloc(Draw, wanted.values.len);
        for (details, wanted.values) |*detail, value| {
            detail.* = found;
            detail.set = value;
        }
        try decisions.append(arena, details);
    }
    return decisions.items;
}

/// Whether a decision picked a fault (no restore).
fn is_fault(decision: []const Draw) bool {
    for (decision) |draw| if (std.mem.eql(u8, draw.name, "fault") and !draw.restore()) return true;
    return false;
}

/// A replay's draws file (`--draws-out`): every kept value in pull order, and the first pull
/// from which every fault label's draws are all kept.
fn draws_read(arena: std.mem.Allocator, text: []const u8) !struct { draws: []const Draw, complete_from: u64 } {
    const Kept = struct { pull: u64, after_ns: u64, value: u64 };
    const Line = struct {
        name: ?[]const u8 = null,
        kind: []const u8 = "range",
        count: u64 = 0,
        options: ?[]const []const u8 = null,
        drawn: u64 = 0,
        kept: ?[]const Kept = null,
    };
    var draws: std.ArrayList(Draw) = .empty;
    var complete_from: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |text_line| {
        const line = try std.json.parseFromSliceLeaky(Line, arena, text_line, .{ .ignore_unknown_fields = true });
        const name = line.name orelse continue;
        const kept = line.kept orelse continue;
        if (std.mem.startsWith(u8, name, "fault") and line.drawn > kept.len and kept.len > 0) {
            complete_from = @max(complete_from, kept[0].pull);
        }
        for (kept) |value| {
            const option = if (line.options) |options| if (value.value < options.len) options[value.value] else null else null;
            const options = if (std.mem.eql(u8, line.kind, "options")) line.options else null;
            try draws.append(arena, .{
                .pull = value.pull,
                .after_ns = value.after_ns,
                .name = name,
                .count = line.count,
                .value = value.value,
                .option = option,
                .options = options,
            });
        }
    }
    std.mem.sort(Draw, draws.items, {}, struct {
        fn less(_: void, a: Draw, b: Draw) bool {
            return a.pull < b.pull;
        }
    }.less);
    return .{ .draws = draws.items, .complete_from = complete_from };
}

/// The replay's fault regimes (`--events` lines: `fault_swarm`'s kinds by weight).
fn regimes_read(arena: std.mem.Allocator, text: []const u8) ![]const Regime {
    const Line = struct {
        vtime_ns: u64 = 0,
        event: struct { details: ?struct { kinds: ?[]const u8 = null } = null } = .{},
    };
    var regimes: std.ArrayList(Regime) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |text_line| {
        if (std.mem.indexOf(u8, text_line, "{\"event\":\"fault_swarm\",") == null) continue;
        const line = try std.json.parseFromSliceLeaky(Line, arena, text_line, .{ .ignore_unknown_fields = true });
        const details = line.event.details orelse continue;
        if (details.kinds) |kinds| try regimes.append(arena, .{ .vtime_ns = line.vtime_ns, .kinds = kinds });
    }
    return regimes.items;
}

pub const Override = struct { pull: u64, value: u64 };

/// A variant's tape: the timeline's, its checkpoints left out (its history parts at the
/// overrides), each override's pull answered its value (in place of the tape's own answer, if
/// any). `overrides` in pull order.
pub fn variant_tape(arena: std.mem.Allocator, tape: []const u8, overrides: []const Override) ![]const u8 {
    const Line = struct { pull: ?u64 = null, checkpoint: ?std.json.Value = null };
    var lines = std.mem.tokenizeScalar(u8, tape, '\n');
    const header = lines.next() orelse return error.BadTape;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, header);
    try out.append(arena, '\n');
    var next: usize = 0;
    while (lines.next()) |text| {
        const line = try std.json.parseFromSliceLeaky(Line, arena, text, .{ .ignore_unknown_fields = true });
        if (line.checkpoint != null) continue;
        if (line.pull) |at| {
            while (next < overrides.len and overrides[next].pull < at) : (next += 1) try override_write(arena, &out, overrides[next]);
            if (next < overrides.len and overrides[next].pull == at) {
                try override_write(arena, &out, overrides[next]);
                next += 1;
                continue;
            }
        }
        try out.appendSlice(arena, text);
        try out.append(arena, '\n');
    }
    while (next < overrides.len) : (next += 1) try override_write(arena, &out, overrides[next]);
    return out.items;
}

fn override_write(arena: std.mem.Allocator, out: *std.ArrayList(u8), override: Override) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, override.value, .little);
    try out.print(arena, "{{\"pull\":{d},\"hex\":\"{x}\"}}\n", .{ override.pull, bytes });
}

const What = enum { control, removed, detail };

const Item = struct {
    fault: u32,
    what: What,
    /// The decision's draw varied (detail).
    draw: u32 = 0,
    /// One override, or two: the fault removed and the control's draw varied.
    overrides: [2]Override,
    count: u8 = 1,
};

const Result = struct { failing: bool = false, vtime_ns: ?u64 = null };

const Explanation = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
    tape: []const u8,
    snapshot: []const u8,
    until: []const u8,
    directory: []const u8,
    items: []const Item,
    results: []Result,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(explanation: *Explanation) void {
        while (true) {
            const index = explanation.next.fetchAdd(1, .monotonic);
            if (index >= explanation.items.len) return;
            explanation.results[index] = explanation.one(index) catch |err| {
                std.debug.print("[determinismo] explain: variant {d} failed: {s}\n", .{ index, @errorName(err) });
                explanation.failed.store(true, .monotonic);
                continue;
            };
        }
    }

    fn one(explanation: *Explanation, index: usize) !Result {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const scratch = arena_state.allocator();
        const item = explanation.items[index];
        const io = explanation.io;
        const path = try std.fmt.allocPrint(scratch, "{s}/variant-{d}.jsonl", .{ explanation.directory, index });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = try variant_tape(scratch, explanation.tape, item.overrides[0..item.count]),
        });
        defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(scratch, &.{ explanation.self, "explore" });
        try argv.appendSlice(scratch, explanation.request.rest);
        try argv.appendSlice(scratch, &.{ "--tape", path, "--tape-snapshot", explanation.snapshot, "--until", explanation.until });
        const result = try std.process.run(scratch, io, .{ .argv = argv.items });
        return outcome(scratch, result.stderr, explanation.request.property);
    }
};

/// Whether a replay stopped at the property's failure (its `until:` line an assertion of it that
/// failed, not the horizon's event), and when.
pub fn outcome(arena: std.mem.Allocator, stderr: []const u8, property: []const u8) !Result {
    const key = "[determinismo] until: ";
    const at = std.mem.lastIndexOf(u8, stderr, key) orelse return .{};
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, stderr, start, '\n') orelse stderr.len;
    const Assertion = struct {
        message: []const u8 = "",
        condition: ?bool = null,
        type: []const u8 = "",
        display_type: []const u8 = "",
        hit: ?bool = null,
    };
    const Line = struct { assert: ?Assertion = null, antithesis_assert: ?Assertion = null };
    const line = std.json.parseFromSliceLeaky(Line, arena, stderr[start..end], .{ .ignore_unknown_fields = true }) catch return .{};
    const failing = if (line.assert) |a|
        std.mem.eql(u8, a.message, property) and
            (a.condition == false or (std.mem.eql(u8, a.type, "unreachable") and a.condition == true))
    else if (line.antithesis_assert) |a|
        std.mem.eql(u8, a.message, property) and a.hit == true and
            (a.condition == false or std.mem.eql(u8, a.display_type, "Unreachable"))
    else
        false;
    if (!failing) return .{};
    const moment = "at moment vtime=";
    const vtime_ns: ?u64 = if (std.mem.lastIndexOf(u8, stderr, moment)) |m| digits: {
        var e = m + moment.len;
        while (e < stderr.len and std.ascii.isDigit(stderr[e])) e += 1;
        break :digits std.fmt.parseInt(u64, stderr[m + moment.len .. e], 10) catch null;
    } else null;
    return .{ .failing = true, .vtime_ns = vtime_ns };
}

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    const request = try arguments_parse(arena, arguments);
    const cwd = std.Io.Dir.cwd();
    const directory = try std.fmt.allocPrint(arena, "/tmp/determinismo-explain-{d}", .{std.os.linux.getpid()});
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};
    const tape = try cwd.readFileAlloc(io, request.tape, arena, .limited(1 << 28));
    const plain = try std.fmt.allocPrint(arena, "{s}/plain.jsonl", .{directory});
    // The tape as each variant's is (no checkpoints): what the variants are measured against.
    try cwd.writeFile(io, .{ .sub_path = plain, .data = try variant_tape_plain(arena, tape) });
    const failure_condition = try property_condition(arena, request.property);

    // 1. To the failure: its events and named draws.
    std.debug.print("[determinismo] explain: replaying to the failure\n", .{});
    const events_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{directory});
    const draws_path = try std.fmt.allocPrint(arena, "{s}/draws.jsonl", .{directory});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    try argv.appendSlice(arena, &.{ "--tape", plain, "--until", failure_condition, "--events", events_path, "--draws-out", draws_path });
    const first = try std.process.run(arena, io, .{ .argv = argv.items });
    const failure = try outcome(arena, first.stderr, request.property);
    if (!failure.failing or failure.vtime_ns == null) {
        std.debug.print("[determinismo] explain: '{s}' does not fail in {s}\n{s}\n", .{
            request.property, request.tape, first.stderr[first.stderr.len -| 2048..],
        });
        return 1;
    }
    const failure_ns = failure.vtime_ns.?;
    const read = try draws_read(arena, try cwd.readFileAlloc(io, draws_path, arena, .limited(1 << 26)));
    const regimes = try regimes_read(arena, try cwd.readFileAlloc(io, events_path, arena, .limited(1 << 31)));

    // 2. The last faults, whole.
    const decisions = try decisions_of(arena, read.draws, read.complete_from);
    var chosen: std.ArrayList([]const Draw) = .empty;
    var faults_count: u32 = 0;
    for (decisions) |decision| faults_count += @intFromBool(is_fault(decision));
    var index = decisions.len;
    while (index > 0 and chosen.items.len < request.faults) {
        index -= 1;
        if (is_fault(decisions[index])) try chosen.append(arena, decisions[index]);
    }
    try chosen.appendSlice(arena, try named_decisions(arena, read.draws, request.draws));
    if (chosen.items.len == 0) {
        // No fault decided before it fails, or only restores: it needs none (an answer).
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
        const out = &stdout.interface;
        try report(arena, out, &request, .{
            .failure_ns = failure_ns,
            .save_ms = 0,
            .horizon_ns = 0,
            .decisions = decisions.len,
            .faults = faults_count,
            .chosen = &.{},
            .controls = &.{},
            .items = &.{},
            .results = &.{},
        });
        try out.flush();
        return 0;
    }

    // 3. The timeline a millisecond before the earliest varied pull.
    std.debug.print("[determinismo] explain: {d} faults to vary; saving the timeline before them\n", .{chosen.items.len});
    var earliest_ns: u64 = std.math.maxInt(u64);
    for (chosen.items) |decision| earliest_ns = @min(earliest_ns, decision[0].after_ns);
    const save_ms = @max(1, earliest_ns / std.time.ns_per_ms -| 1);
    const snapshots = try std.fmt.allocPrint(arena, "{s}/snapshots", .{directory});
    try cwd.createDirPath(io, snapshots);
    argv = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    try argv.appendSlice(arena, &.{
        "--tape",           plain,
        "--until",          failure_condition,
        "--save-snapshots", snapshots,
        "--save-at-ms",     try std.fmt.allocPrint(arena, "{d}", .{save_ms}),
    });
    const second = try std.process.run(arena, io, .{ .argv = argv.items });
    const saved_key = "saved snapshot ";
    const saved_at = std.mem.indexOf(u8, second.stderr, saved_key) orelse {
        std.debug.print("[determinismo] explain: no snapshot at {d}ms\n{s}\n", .{ save_ms, second.stderr[second.stderr.len -| 2048..] });
        return error.NoSnapshot;
    };
    const saved_end = std.mem.indexOfScalarPos(u8, second.stderr, saved_at + saved_key.len, ' ') orelse return error.NoSnapshot;
    const snapshot = second.stderr[saved_at + saved_key.len .. saved_end];
    const horizon_ns = failure_ns + (failure_ns -| save_ms * std.time.ns_per_ms);
    const until = try std.fmt.allocPrint(arena, "{s} or vtime>={d}.{d:0>9}", .{
        failure_condition, horizon_ns / std.time.ns_per_s, horizon_ns % std.time.ns_per_s,
    });

    // 4. The variants: per fault a control, the fault removed, each pull m times.
    var prng: std.Random.DefaultPrng = .init(request.seed);
    const random = prng.random();
    var items: std.ArrayList(Item) = .empty;
    const controls = try arena.alloc(?Draw, chosen.items.len);
    for (chosen.items, 0..) |decision, at| {
        const last = decision[decision.len - 1].pull;
        controls[at] = for (read.draws) |draw| {
            if (draw.pull > last and !draw.fault() and draw.count > 1) break draw;
        } else null;
        const none: Override = .{ .pull = 0, .value = 0 };
        if (controls[at]) |control| for (0..request.variants) |_| {
            try items.append(arena, .{ .fault = @intCast(at), .what = .control, .overrides = .{ .{ .pull = control.pull, .value = random.int(u64) }, none } });
        };
        // The fault removed, as often as each detail: with the control's draw varied too (the same
        // nudge as the control's), so its failures compare with the control's; once without one.
        if (removal(decision, regimes)) |removed| {
            const fault_removed: Override = .{ .pull = removed.pull, .value = removed.value };
            if (controls[at]) |control| {
                // (A for's else runs when the loop ends: braces keep this one the if's.)
                for (0..request.variants) |_| {
                    try items.append(arena, .{ .fault = @intCast(at), .what = .removed, .count = 2, .overrides = .{
                        fault_removed, .{ .pull = control.pull, .value = random.int(u64) },
                    } });
                }
            } else try items.append(arena, .{ .fault = @intCast(at), .what = .removed, .overrides = .{ fault_removed, none } });
        }
        for (decision, 0..) |draw, draw_index| for (0..request.variants) |_| {
            try items.append(arena, .{
                .fault = @intCast(at),
                .what = .detail,
                .draw = @intCast(draw_index),
                .overrides = .{ .{ .pull = draw.pull, .value = draw.set orelse random.int(u64) }, none },
            });
        };
    }
    const results = try arena.alloc(Result, items.items.len);
    @memset(results, .{});
    var explanation: Explanation = .{
        .arena = arena,
        .io = io,
        .self = self,
        .request = &request,
        .tape = tape,
        .snapshot = snapshot,
        .until = until,
        .directory = directory,
        .items = items.items,
        .results = results,
    };
    // The unchanged tape first: from the snapshot it must fail as it did from the start.
    argv = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    try argv.appendSlice(arena, &.{ "--tape", plain, "--tape-snapshot", snapshot, "--until", until });
    const unchanged = try outcome(arena, (try std.process.run(arena, io, .{ .argv = argv.items })).stderr, request.property);
    if (!unchanged.failing or (unchanged.vtime_ns orelse 0) != failure_ns) {
        std.debug.print("[determinismo] explain: from the snapshot at {d}ms the unchanged tape does not fail " ++
            "as it did ({any} at {any}, not at {d}ns): its variants would say nothing\n", .{
            save_ms, unchanged.failing, unchanged.vtime_ns, failure_ns,
        });
        return error.SnapshotParts;
    }
    std.debug.print("[determinismo] explain: {d} variants from {d} ms\n", .{ explanation.items.len, save_ms });
    const wanted = if (request.jobs > 0) request.jobs else cpus.usable_count();
    const at_once = std.math.clamp(wanted, 1, @max(1, explanation.items.len));
    const threads = try arena.alloc(std.Thread, at_once);
    for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, Explanation.run, .{&explanation});
    for (threads) |thread| thread.join();
    if (explanation.failed.load(.monotonic)) return error.VariantsFailed;

    // 5. The verdicts.
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try report(arena, out, &request, .{
        .failure_ns = failure_ns,
        .save_ms = save_ms,
        .horizon_ns = horizon_ns,
        .decisions = decisions.len,
        .faults = faults_count,
        .chosen = chosen.items,
        .controls = controls,
        .items = explanation.items,
        .results = explanation.results,
    });
    try out.flush();
    return 0;
}

/// The pull and value that make a decision a restore: its kind drawn into the regime's restore
/// weights, or (no kind drawn) its pick's restore option; null when neither has one.
pub fn removal(decision: []const Draw, regimes: []const Regime) ?struct { pull: u64, value: u64 } {
    const first = decision[0];
    if (std.mem.eql(u8, first.name, decision_first)) {
        const regime = regime_at(regimes, first.after_ns) orelse return null;
        return .{ .pull = first.pull, .value = restore_value(regime.kinds) orelse return null };
    }
    const options = first.options orelse return null;
    for (options, 0..) |option, index| {
        if (std.mem.eql(u8, option, "restore")) return .{ .pull = first.pull, .value = index };
    }
    return null;
}

fn regime_at(regimes: []const Regime, vtime_ns: u64) ?Regime {
    var found: ?Regime = null;
    for (regimes) |regime| {
        if (regime.vtime_ns > vtime_ns) break;
        found = regime;
    }
    return found;
}

/// What a decision picked (its `fault` draw's option: "restart etcd-3", "partition_groups").
fn pick_of(decision: []const Draw) []const u8 {
    // A named draw of the scenario's own (`--draw`): its name.
    if (!decision[0].fault()) return decision[0].name;
    for (decision) |draw| if (std.mem.eql(u8, draw.name, "fault")) return draw.option orelse "?";
    return "?";
}

/// The tape without its checkpoints (as every variant's).
fn variant_tape_plain(arena: std.mem.Allocator, tape: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, tape, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "{\"checkpoint\":")) continue;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

const Report = struct {
    failure_ns: u64,
    save_ms: u64,
    horizon_ns: u64,
    decisions: usize,
    faults: u32,
    chosen: []const []const Draw,
    controls: []const ?Draw,
    items: []const Item,
    results: []const Result,
};

fn count(r: Report, fault: usize, what: What, draw: u32) struct { failing: u32, of: u32 } {
    var failing: u32 = 0;
    var of: u32 = 0;
    for (r.items, r.results) |item, result| {
        if (item.fault != fault or item.what != what) continue;
        if (what == .detail and item.draw != draw) continue;
        of += 1;
        failing += @intFromBool(result.failing);
    }
    return .{ .failing = failing, .of = of };
}

/// The explanation as data: `--json`'s one line, the text's source.
const Explained = struct {
    property: []const u8,
    failure_ns: u64,
    snapshot_ms: u64,
    horizon_ns: u64,
    decisions: usize,
    faults_kept: u32,
    variants: u32,
    faults: []const struct {
        /// When it was decided (its first draw's moment: the last event before it), and what it
        /// picked (the fault's kind and its target).
        vtime_ns: u64,
        picked: []const u8,
        control: ?struct { draw: []const u8, failing: u32, of: u32 },
        /// The fault removed (null: no restore to draw), against the control as a detail is.
        removed: ?struct { failing: u32, of: u32, verdict: Verdict },
        details: []const struct {
            draw: []const u8,
            pull: u64,
            drew: u64,
            /// The value its variants set it to (`--draw <name>=<values>`).
            set: ?u64 = null,
            option: ?[]const u8,
            failing: u32,
            of: u32,
            verdict: Verdict,
        },
    },
};

fn explained_of(arena: std.mem.Allocator, request: *const Request, r: Report) !Explained {
    const Faults = @typeInfo(@FieldType(Explained, "faults")).pointer.child;
    const Details = @typeInfo(@FieldType(Faults, "details")).pointer.child;
    const faults = try arena.alloc(Faults, r.chosen.len);
    for (r.chosen, faults, 0..) |decision, *fault, at| {
        const control = count(r, at, .control, 0);
        const removed = count(r, at, .removed, 0);
        const details = try arena.alloc(Details, decision.len);
        for (decision, details, 0..) |draw, *detail, draw_index| {
            const tally = count(r, at, .detail, @intCast(draw_index));
            detail.* = .{
                .draw = draw.name,
                .pull = draw.pull,
                .drew = draw.value,
                .set = draw.set,
                .option = draw.option,
                .failing = tally.failing,
                .of = tally.of,
                .verdict = verdict(tally.failing, tally.of, control.failing, control.of),
            };
        }
        fault.* = .{
            .vtime_ns = decision[0].after_ns,
            .picked = pick_of(decision),
            .control = if (r.controls[at]) |c| .{ .draw = c.name, .failing = control.failing, .of = control.of } else null,
            .removed = if (removed.of == 0) null else .{
                .failing = removed.failing,
                .of = removed.of,
                .verdict = verdict(removed.failing, removed.of, control.failing, control.of),
            },
            .details = details,
        };
    }
    return .{
        .property = request.property,
        .failure_ns = r.failure_ns,
        .snapshot_ms = r.save_ms,
        .horizon_ns = r.horizon_ns,
        .decisions = r.decisions,
        .faults_kept = r.faults,
        .variants = request.variants,
        .faults = faults,
    };
}

fn report(arena: std.mem.Allocator, out: *std.Io.Writer, request: *const Request, r: Report) !void {
    const explained = try explained_of(arena, request, r);
    if (request.json) {
        try out.print("{f}\n", .{std.json.fmt(.{ .explain = explained }, .{})});
        return;
    }
    const seconds = struct {
        fn of(ns: u64) struct { u64, u64 } {
            return .{ ns / std.time.ns_per_s, (ns % std.time.ns_per_s) / std.time.ns_per_ms };
        }
    }.of;
    const failure = seconds(explained.failure_ns);
    if (explained.faults.len == 0) {
        try out.print("'{s}' fails at {d}.{d:0>3} s with {s}: it needs no fault\n", .{
            explained.property,                                                                                failure[0], failure[1],
            if (explained.decisions == 0) "no fault decided before it" else "only restores decided before it",
        });
        return;
    }
    try out.print("'{s}' fails at {d}.{d:0>3} s; {d} fault decisions kept before it, {d} of them faults; " ++
        "the last {d} varied, {d} variants each detail, from {d} ms\n", .{
        explained.property,  failure[0],            failure[1],
        explained.decisions, explained.faults_kept, explained.faults.len,
        explained.variants,  explained.snapshot_ms,
    });
    for (explained.faults) |fault| {
        const at = seconds(fault.vtime_ns);
        try out.print("\n{s}, decided at {d}.{d:0>3} s\n", .{ fault.picked, at[0], at[1] });
        if (fault.control) |control| {
            try out.print("  control ({s}): {d} of {d} fail\n", .{ control.draw, control.failing, control.of });
        } else try out.writeAll("  control: none (no other draw after it)\n");
        if (fault.removed) |removed| {
            try out.print("  {s:<20} {s:>21}: {d} of {d} fail: {s}\n", .{
                "without it",                                                              "(a restore)", removed.failing, removed.of,
                if (removed.verdict == .free) "not needed" else @tagName(removed.verdict),
            });
        }
        for (fault.details) |detail| {
            var number: [24]u8 = undefined;
            try out.print("  {s:<20} {s} {s:>16}: {d} of {d} fail: {s}\n", .{
                detail.draw,
                if (detail.set != null) "set " else "drew",
                if (detail.set) |set| try std.fmt.bufPrint(&number, "{d}", .{set}) else if (detail.option) |option| option else try std.fmt.bufPrint(&number, "{d}", .{detail.drew}),
                detail.failing,
                detail.of,
                @tagName(detail.verdict),
            });
        }
    }
}

fn property_condition(arena: std.mem.Allocator, property: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(property, .{})});
    return std.fmt.allocPrint(arena, "assert.message={s} assert.condition=false or " ++
        "assert.message={s} assert.type=unreachable assert.condition=true or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.condition=false or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.display_type=Unreachable", .{
        message, message, message, message,
    });
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Request {
    var request = Request{ .property = "", .tape = "", .rest = &.{} };
    var rest: std.ArrayList([]const u8) = .empty;
    var run_directory: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var tape: ?[]const u8 = null;
    var draws: std.ArrayList(DrawAsked) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--json")) {
            request.json = true;
            continue;
        }
        const ours = eql(u8, flag, "--property") or eql(u8, flag, "--faults") or
            eql(u8, flag, "--variants") or eql(u8, flag, "--jobs") or eql(u8, flag, "--tape") or
            eql(u8, flag, "--branch") or eql(u8, flag, "--seed-variants") or eql(u8, flag, "--draw");
        if (!ours) {
            try rest.append(arena, flag);
            // The run's own options (explore --run): its tapes are beside them.
            if (eql(u8, flag, "--run") and index + 1 < arguments.len) {
                run_directory = arguments[index + 1];
                try rest.append(arena, arguments[index + 1]);
                index += 1;
            }
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (eql(u8, flag, "--property")) {
            request.property = value;
        } else if (eql(u8, flag, "--faults")) {
            request.faults = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--variants")) {
            request.variants = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--jobs")) {
            request.jobs = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--tape")) {
            tape = value;
        } else if (eql(u8, flag, "--branch")) {
            branch = value;
        } else if (eql(u8, flag, "--draw")) {
            try draws.append(arena, try DrawAsked.parse(arena, value));
        } else {
            request.seed = try std.fmt.parseInt(u64, value, 10);
        }
    }
    request.tape = tape orelse if (run_directory) |directory| if (branch) |n|
        try std.fmt.allocPrint(arena, "{s}/tapes/branch-{s}.jsonl", .{ directory, n })
    else
        return error.Usage else return error.Usage;
    if (request.property.len == 0) return error.Usage;
    if (request.faults == 0 or request.faults > faults_max) return error.Usage;
    if (request.variants == 0 or request.variants > variants_max) return error.Usage;
    request.rest = rest.items;
    request.draws = draws.items;
    return request;
}

test restore_value {
    try std.testing.expectEqual(@as(?u64, 13), restore_value("degrade:8 thread_pause:4 clog:1 restore:64"));
    try std.testing.expectEqual(@as(?u64, 1), restore_value("sync_stall:0 restore:2"));
    try std.testing.expectEqual(@as(?u64, null), restore_value("sync_stall:2"));
}

test verdict {
    try std.testing.expectEqual(Verdict.needed, verdict(0, 6, 6, 6));
    try std.testing.expectEqual(Verdict.free, verdict(6, 6, 6, 6));
    try std.testing.expectEqual(Verdict.free, verdict(4, 6, 4, 6));
    // Half against all, of six each: the intervals overlap, so six variants cannot tell.
    try std.testing.expectEqual(Verdict.unclear, verdict(3, 6, 6, 6));
    try std.testing.expectEqual(Verdict.partly, verdict(4, 24, 24, 24));
    try std.testing.expectEqual(Verdict.unclear, verdict(0, 6, 0, 6));
    try std.testing.expectEqual(Verdict.unclear, verdict(0, 6, 1, 6));
}

test decisions_of {
    const draws = [_]Draw{
        .{ .pull = 3, .after_ns = 1, .name = "composer.weight", .count = 7, .value = 1 },
        .{ .pull = 10, .after_ns = 2, .name = "fault.kind", .count = 77, .value = 40 },
        .{ .pull = 11, .after_ns = 2, .name = "fault", .count = 1, .value = 0, .option = "restore" },
        .{ .pull = 12, .after_ns = 2, .name = "fault.wait_ns", .count = 100, .value = 5 },
        .{ .pull = 20, .after_ns = 3, .name = "fault.kind", .count = 77, .value = 3 },
        .{ .pull = 21, .after_ns = 3, .name = "fault", .count = 2, .value = 0, .option = "degrade redis runner" },
        .{ .pull = 22, .after_ns = 3, .name = "composer.command", .count = 4, .value = 2 },
        .{ .pull = 23, .after_ns = 3, .name = "fault.duration_ns", .count = 1000, .value = 9 },
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const kept = try decisions_of(arena_state.allocator(), &draws, 0);
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expect(!is_fault(kept[0]));
    try std.testing.expect(is_fault(kept[1]));
    try std.testing.expectEqual(@as(usize, 3), kept[1].len); // The workload's draw is no fault's.
    // A decision before every fault label's kept draws begin is left out.
    try std.testing.expectEqual(@as(usize, 1), (try decisions_of(arena_state.allocator(), &draws, 15)).len);
}

test "decisions without kind weights start at their pick; removal picks restore" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const options = [_][]const u8{ "isolate redis", "restore" };
    const draws = [_]Draw{
        .{ .pull = 43, .after_ns = 1, .name = "fault.wait_ns", .count = 100, .value = 7 },
        .{ .pull = 50, .after_ns = 2, .name = "fault", .count = 2, .value = 0, .option = "isolate redis", .options = &options },
        .{ .pull = 51, .after_ns = 2, .name = "fault.duration_ns", .count = 1000, .value = 9 },
        .{ .pull = 52, .after_ns = 2, .name = "fault.wait_ns", .count = 100, .value = 3 },
        .{ .pull = 60, .after_ns = 3, .name = "fault", .count = 2, .value = 1, .option = "restore", .options = &options },
    };
    const decisions = try decisions_of(arena_state.allocator(), &draws, 0);
    try std.testing.expectEqual(@as(usize, 2), decisions.len);
    try std.testing.expectEqual(@as(usize, 3), decisions[0].len);
    try std.testing.expect(is_fault(decisions[0]) and !is_fault(decisions[1]));
    const removed = removal(decisions[0], &.{}).?;
    try std.testing.expectEqual(@as(u64, 50), removed.pull);
    try std.testing.expectEqual(@as(u64, 1), removed.value);
}

test "a scenario's own named draw is varied as a decision: fresh values, or each value set" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const draws = [_]Draw{
        .{ .pull = 10, .after_ns = 1, .name = "clock_step.ms", .count = 8000, .value = 4100 },
        .{ .pull = 20, .after_ns = 2, .name = "fault.kind", .count = 10, .value = 3 },
        .{ .pull = 30, .after_ns = 3, .name = "clock_step.ms", .count = 8000, .value = 5200 },
        .{ .pull = 40, .after_ns = 4, .name = "retry.jitter-ms", .count = 100, .value = 7 },
    };
    // Its last pull before the failure, fresh values.
    const fresh = try named_decisions(arena, &draws, &.{.{ .name = "clock_step.ms" }});
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
    try std.testing.expectEqual(@as(u64, 30), fresh[0][0].pull);
    try std.testing.expectEqual(@as(?u64, null), fresh[0][0].set);
    try std.testing.expectEqualStrings("clock_step.ms", pick_of(fresh[0]));
    // Each value set: one detail each, at that pull.
    const asked = try DrawAsked.parse(arena, "clock_step.ms=0,1000");
    const set = try named_decisions(arena, &draws, &.{asked});
    try std.testing.expectEqual(@as(usize, 2), set[0].len);
    try std.testing.expectEqual(@as(?u64, 0), set[0][0].set);
    try std.testing.expectEqual(@as(?u64, 1000), set[0][1].set);
    try std.testing.expectEqual(@as(u64, 30), set[0][1].pull);
    try std.testing.expectError(error.DrawNotFound, named_decisions(arena, &draws, &.{.{ .name = "absent" }}));
    try std.testing.expectError(error.Usage, DrawAsked.parse(arena, "clock_step.ms="));
}

test variant_tape {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const tape =
        \\{"tape":2,"branch":8}
        \\{"checkpoint":{"events":64,"branches":1,"events_hash":"00"}}
        \\{"pull":5,"hex":"0100000000000000"}
        \\{"pull":9,"hex":"0200000000000000"}
        \\
    ;
    const out = try variant_tape(arena_state.allocator(), tape, &.{.{ .pull = 7, .value = 40 }});
    try std.testing.expectEqualStrings(
        \\{"tape":2,"branch":8}
        \\{"pull":5,"hex":"0100000000000000"}
        \\{"pull":7,"hex":"2800000000000000"}
        \\{"pull":9,"hex":"0200000000000000"}
        \\
    , out);
    // A pull the tape answered already: ours in its place.
    const replaced = try variant_tape(arena_state.allocator(), tape, &.{.{ .pull = 9, .value = 1 }});
    try std.testing.expect(std.mem.indexOf(u8, replaced, "\"pull\":9,\"hex\":\"0100000000000000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replaced, "0200000000000000") == null);
    // Two: the fault removed and the control's draw varied, each in its place.
    const both = try variant_tape(arena_state.allocator(), tape, &.{ .{ .pull = 3, .value = 2 }, .{ .pull = 12, .value = 3 } });
    try std.testing.expectEqualStrings(
        \\{"tape":2,"branch":8}
        \\{"pull":3,"hex":"0200000000000000"}
        \\{"pull":5,"hex":"0100000000000000"}
        \\{"pull":9,"hex":"0200000000000000"}
        \\{"pull":12,"hex":"0300000000000000"}
        \\
    , both);
}

test outcome {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const failed = "[determinismo] until: {\"assert\":{\"type\":\"always\",\"message\":\"total balance is conserved\",\"condition\":false}}\n" ++
        "[determinismo] at moment vtime=1638641316ns branches=599598136\n";
    const result = try outcome(arena_state.allocator(), failed, "total balance is conserved");
    try std.testing.expect(result.failing);
    try std.testing.expectEqual(@as(?u64, 1638641316), result.vtime_ns);
    // The horizon's event: no failure.
    const horizon = "[determinismo] until: {\"event\":\"fault\",\"details\":{}}\n[determinismo] at moment vtime=1900000000ns\n";
    try std.testing.expect(!(try outcome(arena_state.allocator(), horizon, "total balance is conserved")).failing);
}
