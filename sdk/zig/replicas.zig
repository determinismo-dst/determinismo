// SPDX-License-Identifier: MIT
//! Replicas that agree up to an index they all reached (Antithesis's property catalogs: replicas
//! agree, checked as a run goes, not only once faults are over): each replica's own state, read
//! from it alone (no leader), the index it reflects (consensus applies in order: every write up
//! to it is there), its keys with the index that last wrote each. Every key written at or before
//! the lowest of the indexes is the same on each: its index and its value. The reads are
//! moments apart, so a key another replica wrote again after that index is not judged. For
//! systems that never delete the keys judged (a delete would read as a missing write).
//!
//!   sdk.always(sdk.replicas.differing(a, b, index).count == 0, "replicas agree ...", ...)
const std = @import("std");

pub const Entry = struct { key: []const u8, index: u64, value: []const u8 };

pub const State = struct {
    /// The index the replica's state reflects (consensus applied up to it).
    index: u64,
    entries: []const Entry,

    fn get(state: State, key: []const u8) ?Entry {
        for (state.entries) |entry| if (std.mem.eql(u8, entry.key, key)) return entry;
        return null;
    }
};

pub const Differing = struct { count: u32, example: []const u8 };

/// The keys of `first` written at or before `index` that `second` lacks or holds otherwise (and
/// did not write again after `index`): how many, and one of them.
pub fn differing(first: State, second: State, index: u64) Differing {
    var count: u32 = 0;
    var example: []const u8 = "";
    for (first.entries) |entry| {
        if (entry.index > index) continue;
        if (second.get(entry.key)) |other| {
            if (other.index > index) continue; // Written again since: not judged.
            if (other.index == entry.index and std.mem.eql(u8, other.value, entry.value)) continue;
        }
        count += 1;
        if (example.len == 0) example = entry.key;
    }
    return .{ .count = count, .example = example };
}

/// The lowest index among the states known.
pub fn index_common(states: []const ?State) ?u64 {
    var lowest: ?u64 = null;
    for (states) |state| if (state) |known| {
        lowest = @min(lowest orelse known.index, known.index);
    };
    return lowest;
}

test differing {
    const a: State = .{ .index = 50, .entries = &.{
        .{ .key = "1", .value = "1", .index = 10 },
        .{ .key = "2", .value = "2", .index = 20 },
        .{ .key = "3", .value = "3", .index = 30 },
        .{ .key = "4", .value = "4", .index = 45 },
    } };
    // The same up to 40 (4 past it); 2 written again since, on the second.
    const b: State = .{ .index = 60, .entries = &.{
        .{ .key = "1", .value = "1", .index = 10 },
        .{ .key = "2", .value = "2,2", .index = 55 },
        .{ .key = "3", .value = "3", .index = 30 },
    } };
    try std.testing.expectEqual(0, differing(a, b, 40).count);
    // A write at 30 missing, and another value at the same index: two keys, the first named.
    const c: State = .{ .index = 40, .entries = &.{
        .{ .key = "1", .value = "9", .index = 10 },
        .{ .key = "2", .value = "2", .index = 20 },
    } };
    const found = differing(a, c, 40);
    try std.testing.expectEqual(2, found.count);
    try std.testing.expectEqualStrings("1", found.example);
    try std.testing.expectEqual(40, index_common(&.{ a, null, c }).?);
    try std.testing.expectEqual(null, index_common(&.{ null, null }));
}
