//! The explorer's bandit over a run's configuration draws: the regimes' and the composer's
//! parameters the guest draws as configuration (sdk.random_config: a fault regime's mean gap, its
//! bound on a fault's length, the overlap share, the composer's starts, its weights). These were
//! independent coins nothing learned from; the user (2026-11-10): the swarm's draws feed the
//! learning. Each value of each one (a bucket: the draw's result, below its range) counts the
//! timelines that drew it and those of them that paid (found a behavior new to the run, or failed
//! a property); a timeline's draw picks a bucket in proportion to its posterior mean,
//! (paid + 1) / (drew + 2) (probability matching: a bucket that paid comes more often, one drawn
//! often without paying less, one never drawn as often as any at first). Floored: one draw in four
//! keeps the pull's own value, uniform, so no bucket's chance reaches zero.
//!
//! A timeline's process chooses from the counts as forked (explore_tree), from the pull's seeded
//! value (deterministic), and writes its answer on the tape: a replay repeats it. The explorer
//! credits a timeline's buckets when its generation is judged.
const std = @import("std");
const assert = std.debug.assert;

pub const buckets_max = 16;
pub const names_max = 256;
/// The buckets one timeline drew, each once (a regime's draws repeat every 10 to 120 s).
pub const uses_max = 64;
/// One draw in `floor_one_in` keeps the pull's own value.
pub const floor_one_in = 4;

pub const Use = struct { name: u64, bucket: u8 };

pub const Bandit = struct {
    /// Each configuration draw's name hash (0: free), open addressing.
    names: [names_max]u64 = @splat(0),
    name_count: u32 = 0,
    drew: [names_max][buckets_max]u32 = @splat(@splat(0)),
    paid: [names_max][buckets_max]u32 = @splat(@splat(0)),

    fn find(bandit: *const Bandit, name: u64) ?usize {
        assert(name != 0);
        var at: usize = @intCast(name % names_max);
        for (0..names_max) |_| {
            if (bandit.names[at] == name) return at;
            if (bandit.names[at] == 0) return null;
            at = (at + 1) % names_max;
        }
        return null;
    }

    fn find_or_add(bandit: *Bandit, name: u64) ?usize {
        if (bandit.find(name)) |at| return at;
        if (bandit.name_count == names_max) return null;
        var at: usize = @intCast(name % names_max);
        while (bandit.names[at] != 0) at = (at + 1) % names_max;
        bandit.names[at] = name;
        bandit.name_count += 1;
        return at;
    }

    /// The bucket for a draw of `range` values, from the pull's own (seeded) value; null where
    /// the pull keeps it (the floor, or a range past buckets_max).
    pub fn choose(bandit: *const Bandit, name: u64, range: u64, default: u64) ?u8 {
        if (range < 2 or range > buckets_max) return null;
        if (default % floor_one_in == 0) return null;
        // Nothing learned of it yet: the pull's own value, so that a tree's first timelines are
        // the ones a replay from a fresh boot draws without their tapes (a uniform pick by the
        // value's high bits parted them: e2e bank, 2026-11-11).
        const index = bandit.find(name) orelse return null;
        var drawn: u64 = 0;
        for (bandit.drew[index][0..range]) |count| drawn += count;
        if (drawn == 0) return null;
        var weights: [buckets_max]f64 = undefined;
        var total: f64 = 0;
        for (0..range) |bucket| {
            const drew: f64 = @floatFromInt(bandit.drew[index][bucket]);
            const paid: f64 = @floatFromInt(bandit.paid[index][bucket]);
            weights[bucket] = (paid + 1) / (drew + 2);
            total += weights[bucket];
        }
        // The bucket by the value's high bits (its low ones chose the floor).
        const unit = @as(f64, @floatFromInt(default >> 11)) / @as(f64, 1 << 53);
        var sum: f64 = 0;
        for (0..range) |bucket| {
            sum += weights[bucket];
            if (unit * total < sum) return @intCast(bucket);
        }
        return @intCast(range - 1);
    }

    /// Keeps `keep_eighths` eighths of every count (main.zig's memory_forget draws it each
    /// generation): recent draws weigh more than the run's first ones, a bucket's payoffs never
    /// above its draws.
    pub fn forget(bandit: *Bandit, keep_eighths: u32) void {
        assert(keep_eighths <= 8);
        if (keep_eighths == 8) return;
        for (&bandit.drew, &bandit.paid) |*drew, *paid| {
            for (drew, paid) |*draws, *payoffs| {
                draws.* = draws.* * keep_eighths / 8;
                payoffs.* = @min(payoffs.* * keep_eighths / 8, draws.*);
            }
        }
    }

    /// A judged timeline's draws: each bucket drawn once more, and paid when the timeline did.
    pub fn credit(bandit: *Bandit, uses: []const Use, paid: bool) void {
        for (uses) |use| {
            assert(use.bucket < buckets_max);
            const at = bandit.find_or_add(use.name) orelse continue;
            bandit.drew[at][use.bucket] +|= 1;
            if (paid) bandit.paid[at][use.bucket] +|= 1;
        }
    }
};

/// Each name's counts as lines, `{"name":"<hex>","drew":[...],"paid":[...]}` (a run's
/// `record.jsonl.bandit`, rewritten as it learns; serve gathers the system's last runs' into the
/// next run's history).
pub fn write(bandit: *const Bandit, out: *std.Io.Writer) !void {
    for (bandit.names, 0..) |name, at| {
        if (name == 0) continue;
        try out.print("{{\"name\":\"{x:0>16}\",\"drew\":[", .{name});
        for (bandit.drew[at], 0..) |count, bucket| try out.print("{s}{d}", .{ if (bucket == 0) "" else ",", count });
        try out.writeAll("],\"paid\":[");
        for (bandit.paid[at], 0..) |count, bucket| try out.print("{s}{d}", .{ if (bucket == 0) "" else ",", count });
        try out.writeAll("]}\n");
    }
}

/// The system's last runs' counts (their lines, concatenated) summed in, each bucket's then scaled
/// to at most `warm_drew_max` draws, paid in proportion: a warm start that its own run's draws
/// soon outweigh, still exploring (the floor). A line not understood is skipped.
pub fn warm(bandit: *Bandit, arena: std.mem.Allocator, source: []const u8) void {
    const Line = struct { name: []const u8, drew: []const u32, paid: []const u32 };
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
        const name = std.fmt.parseInt(u64, line.name, 16) catch continue;
        if (name == 0 or line.drew.len != buckets_max or line.paid.len != buckets_max) continue;
        const at = bandit.find_or_add(name) orelse continue;
        for (0..buckets_max) |bucket| {
            bandit.drew[at][bucket] +|= line.drew[bucket];
            bandit.paid[at][bucket] +|= @min(line.paid[bucket], line.drew[bucket]);
        }
    }
    for (bandit.names, 0..) |name, at| {
        if (name == 0) continue;
        for (0..buckets_max) |bucket| {
            const drew = bandit.drew[at][bucket];
            if (drew <= warm_drew_max) continue;
            bandit.paid[at][bucket] = @intCast(@as(u64, bandit.paid[at][bucket]) * warm_drew_max / drew);
            bandit.drew[at][bucket] = warm_drew_max;
        }
    }
}

/// A warm start's weight: at most this many draws a bucket.
pub const warm_drew_max = 32;

test "a run's counts written warm the next run's, scaled down" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var learned: Bandit = .{};
    const name = name_hash("fault.gap_log2");
    for (0..100) |_| learned.credit(&.{.{ .name = name, .bucket = 3 }}, true);
    for (0..10) |_| learned.credit(&.{.{ .name = name, .bucket = 1 }}, false);
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write(&learned, &out);
    // Two earlier runs alike.
    const text = try std.mem.concat(arena, u8, &.{ out.buffered(), out.buffered() });
    var next: Bandit = .{};
    warm(&next, arena, text);
    const at = next.find(name).?;
    try std.testing.expectEqual(@as(u32, warm_drew_max), next.drew[at][3]); // 200 scaled to 32.
    try std.testing.expectEqual(@as(u32, warm_drew_max), next.paid[at][3]);
    try std.testing.expectEqual(@as(u32, 20), next.drew[at][1]);
    try std.testing.expectEqual(@as(u32, 0), next.paid[at][1]);
    warm(&next, arena, "not json\n{\"name\":\"zz\",\"drew\":[],\"paid\":[]}\n"); // Skipped.
}

/// A configuration draw's announcement (`{"name":"fault.gap_log2","range":12,"config":true}`):
/// its name's hash and range; null for any other.
pub fn config_label(label: []const u8) ?struct { name: u64, range: u64 } {
    if (std.mem.indexOf(u8, label, "\"config\":true") == null) return null;
    const name_key = "{\"name\":\"";
    if (!std.mem.startsWith(u8, label, name_key)) return null;
    const name_end = std.mem.indexOfScalarPos(u8, label, name_key.len, '"') orelse return null;
    const name = label[name_key.len..name_end];
    const range_key = "\"range\":";
    const range_at = (std.mem.indexOf(u8, label, range_key) orelse return null) + range_key.len;
    var range_end = range_at;
    while (range_end < label.len and std.ascii.isDigit(label[range_end])) range_end += 1;
    const range = std.fmt.parseInt(u64, label[range_at..range_end], 10) catch return null;
    return .{ .name = name_hash(name), .range = range };
}

pub fn name_hash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x636f6e66, name) | 1; // Never 0: a free slot.
}

/// Adds a use, each bucket of a name once; past uses_max, dropped.
pub fn use_note(uses: *[uses_max]Use, count: *u8, use: Use) void {
    for (uses[0..count.*]) |known| if (known.name == use.name and known.bucket == use.bucket) return;
    if (count.* == uses_max) return;
    uses[count.*] = use;
    count.* += 1;
}

test "a bucket that pays comes more often, none ever left out" {
    var bandit: Bandit = .{};
    const name = name_hash("fault.gap_log2");
    // Unknown: the pull's own value, always (a replay without the tape draws the same).
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..4000) |_| try std.testing.expectEqual(@as(?u8, null), bandit.choose(name, 4, prng.random().int(u64)));
    // Drawn alike, none paid: every bucket alike (the floor aside).
    for (0..4) |bucket| bandit.credit(&.{.{ .name = name, .bucket = @intCast(bucket) }}, false);
    var counts: [4]u32 = @splat(0);
    for (0..4000) |_| if (bandit.choose(name, 4, prng.random().int(u64))) |bucket| {
        counts[bucket] += 1;
    };
    for (counts) |count| try std.testing.expect(count > 600 and count < 900);
    // Bucket 2 paid in most timelines, the others never.
    for (0..40) |_| {
        bandit.credit(&.{.{ .name = name, .bucket = 2 }}, true);
        bandit.credit(&.{.{ .name = name, .bucket = 0 }}, false);
        bandit.credit(&.{.{ .name = name, .bucket = 1 }}, false);
        bandit.credit(&.{.{ .name = name, .bucket = 3 }}, false);
    }
    counts = @splat(0);
    var floored: u32 = 0;
    for (0..4000) |_| if (bandit.choose(name, 4, prng.random().int(u64))) |bucket| {
        counts[bucket] += 1;
    } else {
        floored += 1;
    };
    try std.testing.expect(counts[2] > 2000);
    for ([_]usize{ 0, 1, 3 }) |bucket| try std.testing.expect(counts[bucket] > 0);
    try std.testing.expect(floored > 800 and floored < 1200); // One in four keeps its own value.
    // Ranges past the buckets, or of one value: the pull's own.
    try std.testing.expectEqual(@as(?u8, null), bandit.choose(name, buckets_max + 1, 3));
    try std.testing.expectEqual(@as(?u8, null), bandit.choose(name, 1, 3));
}

test config_label {
    const parsed = config_label("{\"name\":\"fault.gap_log2\",\"range\":12,\"config\":true}").?;
    try std.testing.expectEqual(name_hash("fault.gap_log2"), parsed.name);
    try std.testing.expectEqual(@as(u64, 12), parsed.range);
    try std.testing.expectEqual(null, config_label("{\"name\":\"fault.wait_ns\",\"range\":12}"));
}

test use_note {
    var uses: [uses_max]Use = undefined;
    var count: u8 = 0;
    use_note(&uses, &count, .{ .name = 5, .bucket = 1 });
    use_note(&uses, &count, .{ .name = 5, .bucket = 1 });
    use_note(&uses, &count, .{ .name = 5, .bucket = 2 });
    try std.testing.expectEqual(@as(u8, 2), count);
}

test "forget keeps a share of every count, payoffs never above draws" {
    var bandit: Bandit = .{};
    const name = name_hash("fault.gap_log2");
    const at = bandit.find_or_add(name).?;
    bandit.drew[at][0] = 16;
    bandit.paid[at][0] = 9;
    bandit.drew[at][1] = 3;
    bandit.paid[at][1] = 3;
    bandit.forget(8);
    try std.testing.expectEqual(16, bandit.drew[at][0]);
    bandit.forget(4);
    try std.testing.expectEqual(8, bandit.drew[at][0]);
    try std.testing.expectEqual(4, bandit.paid[at][0]);
    try std.testing.expectEqual(1, bandit.drew[at][1]);
    try std.testing.expectEqual(1, bandit.paid[at][1]);
    bandit.forget(0);
    try std.testing.expectEqual(0, bandit.drew[at][0]);
    try std.testing.expectEqual(0, bandit.paid[at][0]);
}
