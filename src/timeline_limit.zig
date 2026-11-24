// SPDX-License-Identifier: MIT
//! A run's learned timeline limit: how long a timeline may run past its branch point before it
//! is stopped, learned from the timelines that ended on their own. A timeline stopped there ends
//! without a verdict (cut short), as one stopped at a moment does: the explicit limit
//! (`--timeline-limit`, an hour unless asked) stays the hang verdict.
//!
//! Why: a crash that leaves a cluster dead holds its timeline to the explicit limit. etcd's run
//! 2100 spent 94% of its virtual time in such timelines (209 of 926 held the hour, the other 717
//! averaging 64 s), while its normal ends were 99% under 288 s from their branch points, the
//! longest 836 s.
//!
//! - Only normal ends teach it: finished or failed, never hung or cut short (a limit learned
//!   from its own cuts would only shrink).
//! - Measured from the branch point: a branch made late in a timeline has as long as one made
//!   at the setup.
//! - Twice the longest normal end after the top hundredth of them is left out: one sound but
//!   very slow end does not lift it for good (calibration run 2165: one normal end of
//!   2,554 s set the limit near 5,100 s while the 99th percentile was 333 s, and 28 of 35
//!   workers held hung timelines past 600 s an hour in). It follows the run's ends, up or down.
//! - Off until `min_ends` normal ends (as claims learning waits for its 40), and under
//!   `floor_ns` only past `floor_ends` of them: a run whose first timelines all end quickly
//!   keeps room for a slow one, while one that has seen hundreds goes by them (calibration
//!   run 2179: 1,683 normal ends, 99th percentile 76.8 s past the branch point, the
//!   longest 143.8 s, while 63 hung timelines held the 5-minute floor, 85% of its core time).
//!   Never under `learned_floor_ns` either way.

const std = @import("std");

pub const Learner = struct {
    /// The limit is this many times the longest normal end once the top hundredth is left out
    /// (0: never learned, the run's explicit limit alone).
    multiple: u32 = 2,
    min_ends: u32 = 40,
    floor_ns: u64 = 5 * std.time.ns_per_min,
    /// Normal ends past which the run's own set the limit under `floor_ns`.
    floor_ends: u32 = 400,
    learned_floor_ns: u64 = 30 * std.time.ns_per_s,
    ends: u32 = 0,
    longest_ns: u64 = 0,
    /// The timeline whose normal end is the longest of all: said beside the limit, to tell a slow
    /// but sound system from a hang.
    longest_index: ?u32 = null,
    /// Normal ends by length: bucket 0 under a second, bucket i up to 2^(i/8) seconds.
    buckets: [bucket_count]u32 = @splat(0),

    pub const End = enum { normal, hung, cut_short };
    const bucket_count = 160; // Up to 2^20 s, about 12 days.
    const steps_per_doubling = 8;

    /// Timeline `index`, which ended `length_ns` after its branch point.
    pub fn note(learner: *Learner, end: End, index: u32, length_ns: u64) void {
        if (end != .normal) return;
        learner.ends +|= 1;
        learner.buckets[bucket_of(length_ns)] +|= 1;
        if (learner.longest_index != null and length_ns <= learner.longest_ns) return;
        learner.longest_ns = length_ns;
        learner.longest_index = index;
    }

    /// The longest normal end once the top hundredth of them (one at least) is left out, to its
    /// bucket's top and never past the longest itself; the longest when there is only one.
    pub fn kept_longest_ns(learner: *const Learner) u64 {
        const left_out = (learner.ends + 99) / 100;
        const rank = learner.ends -| left_out;
        if (rank == 0) return learner.longest_ns;
        var seen: u64 = 0;
        for (learner.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= rank) return @min(bucket_top_ns(index), learner.longest_ns);
        }
        return learner.longest_ns;
    }

    /// How long a timeline may run past its branch point; null while there is nothing to go by.
    pub fn limit_ns(learner: *const Learner) ?u64 {
        if (learner.multiple == 0 or learner.ends < learner.min_ends) return null;
        const floor = if (learner.ends < learner.floor_ends) learner.floor_ns else learner.learned_floor_ns;
        return @max(floor, learner.kept_longest_ns() *| learner.multiple);
    }

    fn bucket_of(length_ns: u64) usize {
        if (length_ns < std.time.ns_per_s) return 0;
        const seconds = @as(f64, @floatFromInt(length_ns)) / std.time.ns_per_s;
        const step: usize = @intFromFloat(@floor(std.math.log2(seconds) * steps_per_doubling));
        return @min(step + 1, bucket_count - 1);
    }

    fn bucket_top_ns(index: usize) u64 {
        if (index == 0) return std.time.ns_per_s;
        const doublings = @as(f64, @floatFromInt(index)) / steps_per_doubling;
        return @intFromFloat(std.math.pow(f64, 2, doublings) * std.time.ns_per_s);
    }
};

test "a learned limit: from normal ends only, from the branch point, following them" {
    var learner: Learner = .{ .min_ends = 3 };
    const s = std.time.ns_per_s;
    // Run 2100's shape: normal ends of a few hundred seconds, hangs held the hour.
    learner.note(.normal, 1, 16 * s);
    learner.note(.hung, 2, 3600 * s);
    learner.note(.normal, 3, 288 * s);
    try std.testing.expectEqual(null, learner.limit_ns()); // Two normal ends: not yet.
    learner.note(.cut_short, 4, 9000 * s);
    learner.note(.normal, 386, 836 * s);
    // Three normal ends, the top one left out: twice 288 s, to its bucket's top.
    const limit = learner.limit_ns().?;
    try std.testing.expect(limit >= 2 * 288 * s and limit < 2 * 320 * s);
    try std.testing.expectEqual(@as(?u32, 386), learner.longest_index); // The longest, said.
    // Its ends move it: a shorter one brings the kept longest down.
    learner.note(.normal, 6, 5 * s);
    try std.testing.expect(learner.limit_ns().? <= limit);
    try std.testing.expectEqual(@as(?u32, 386), learner.longest_index);
    // Quick ends alone keep the floor's room.
    var quick: Learner = .{ .min_ends = 1 };
    quick.note(.normal, 0, 2 * s);
    try std.testing.expectEqual(@as(?u64, 5 * std.time.ns_per_min), quick.limit_ns());
    // Off.
    var off: Learner = .{ .multiple = 0, .min_ends = 1 };
    off.note(.normal, 0, 2 * s);
    try std.testing.expectEqual(null, off.limit_ns());
}

test "one long normal end does not set the limit: the top hundredth is left out" {
    // Calibration run 2165: 11,387 normal ends, median 8 s and 99th percentile 333 s, but
    // one of 2,554 s (timeline 52) set the limit near 5,100 s, and 28 of 35 workers held hung
    // timelines past 600 s an hour in.
    var learner: Learner = .{};
    const s = std.time.ns_per_s;
    for (0..980) |i| learner.note(.normal, @intCast(i), 8 * s);
    for (980..1000) |i| learner.note(.normal, @intCast(i), 333 * s);
    learner.note(.normal, 52_000, 2554 * s);
    const limit = learner.limit_ns().?;
    try std.testing.expect(limit >= 2 * 333 * s);
    try std.testing.expect(limit < 2 * 400 * s);
    try std.testing.expectEqual(@as(?u32, 52_000), learner.longest_index); // Still said.
}

test "past floor_ends normal ends, the run's own ends set the limit under the floor" {
    // a calibration run (2179, its I/O through an unreliable libc), 22 minutes in: 1,683 normal
    // ends, median 2.2 s and 99th percentile 76.8 s past the branch point, the longest 143.8 s,
    // while 63 hung timelines held the 5-minute floor each: 85% of the run's core time. Twice the
    // 99th percentile, 154 s, cut no normal end of them.
    var learner: Learner = .{};
    const s = std.time.ns_per_s;
    for (0..1660) |i| learner.note(.normal, @intCast(i), 2 * s);
    for (1660..1683) |i| learner.note(.normal, @intCast(i), 76 * s);
    learner.note(.normal, 9_000, 143 * s);
    const limit = learner.limit_ns().?;
    try std.testing.expect(limit >= 2 * 76 * s);
    try std.testing.expect(limit < 2 * 90 * s);
    // Before them, the floor's room: a run's first ends may all be its quick ones.
    var early: Learner = .{};
    for (0..100) |i| early.note(.normal, @intCast(i), 2 * s);
    try std.testing.expectEqual(@as(?u64, 5 * std.time.ns_per_min), early.limit_ns());
    // Past them, never under the learned floor: a run whose ends are all a second long.
    var quick: Learner = .{};
    for (0..500) |i| quick.note(.normal, @intCast(i), 1 * s);
    try std.testing.expectEqual(@as(?u64, 30 * s), quick.limit_ns());
}
