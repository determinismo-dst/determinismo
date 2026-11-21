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
//! - Never lowered: the longest normal end only grows, and the limit with it.
//! - Off until `min_ends` normal ends (as claims learning waits for its 40), and never under
//!   `floor_ns`: a run whose first timelines all end quickly keeps room for a slow one.

const std = @import("std");

pub const Learner = struct {
    /// The limit is this many times the longest normal end (0: never learned, the run's
    /// explicit limit alone).
    multiple: u32 = 2,
    min_ends: u32 = 40,
    floor_ns: u64 = 5 * std.time.ns_per_min,
    ends: u32 = 0,
    longest_ns: u64 = 0,
    /// The timeline whose normal end is the longest: what set the limit, to tell a slow but sound
    /// system from a hang.
    longest_index: ?u32 = null,

    pub const End = enum { normal, hung, cut_short };

    /// Timeline `index`, which ended `length_ns` after its branch point.
    pub fn note(learner: *Learner, end: End, index: u32, length_ns: u64) void {
        if (end != .normal) return;
        learner.ends +|= 1;
        if (learner.longest_index != null and length_ns <= learner.longest_ns) return;
        learner.longest_ns = length_ns;
        learner.longest_index = index;
    }

    /// How long a timeline may run past its branch point; null while there is nothing to go by.
    pub fn limit_ns(learner: *const Learner) ?u64 {
        if (learner.multiple == 0 or learner.ends < learner.min_ends) return null;
        return @max(learner.floor_ns, learner.longest_ns *| learner.multiple);
    }
};

test "a learned limit: from normal ends only, from the branch point, never lowered" {
    var learner: Learner = .{ .min_ends = 3 };
    const s = std.time.ns_per_s;
    // Run 2100's shape: normal ends of a few hundred seconds, hangs held the hour.
    learner.note(.normal, 1, 16 * s);
    learner.note(.hung, 2, 3600 * s);
    learner.note(.normal, 3, 288 * s);
    try std.testing.expectEqual(null, learner.limit_ns()); // Two normal ends: not yet.
    learner.note(.cut_short, 4, 9000 * s);
    learner.note(.normal, 386, 836 * s);
    try std.testing.expectEqual(@as(?u64, 1672 * s), learner.limit_ns());
    try std.testing.expectEqual(@as(?u32, 386), learner.longest_index); // What set it.
    // A shorter end never lowers it.
    learner.note(.normal, 6, 5 * s);
    try std.testing.expectEqual(@as(?u64, 1672 * s), learner.limit_ns());
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
