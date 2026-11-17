// SPDX-License-Identifier: MIT
//! Antithesis's ring test (docs: resources/ring_test, an online ACID invariant), what workloads
//! share: `n` nodes, 3 to 10, each pointing to the next and the last to the first; transactions
//! that read the ring and exchange two nodes' places in it, each node counting its acknowledged
//! swaps. Every committed state is a ring, so every read of one is: atomicity (no partial swap
//! seen) and isolation (concurrent swaps never break it: snapshot isolation is enough, as a swap
//! writes every pointer it changes, so two that interact write one in common) checked as the run
//! goes, by every transaction on its own snapshot; durability by the counters once faults stop. How the ring is
//! stored is the workload's (examples/sql/ring.zig: rows; examples/dgraph: edges).
//!
//!   setup:   const size = sdk.ring.size_draw(); ...create...; try sdk.ring.size_write(size);
//!   swap:    var ring: sdk.ring.Ring = .{ .size = size }; ...read ring.next...;
//!            sdk.always(ring.intact(), "a transaction reads an intact ring", ...);
//!            const places = sdk.ring.places_draw(size); const next = ring.swapped(places);
//!            ...write what changed...; sdk.ring.note(.sent, nodes); ...commit...;
//!            sdk.ring.note(.committed, nodes);   // or .failed: certainly not committed
//!   final:   ...read the ring and each node's counter...; try sdk.ring.counters_judge(arena, counters);
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo.zig");

pub const size_min = 3;
pub const size_max = 10;
/// The runner's files: the ring's size (setup's draw), and every swap's notes, a line each ("s
/// <a> <b>" its commit about to be sent, "c <a> <b>" committed, "f <a> <b>" certainly not),
/// appended by every driver.
const size_path = "/tmp/det-ring-size";
const outcomes_path = "/tmp/det-ring-outcomes";

/// The ring's size, drawn once (setup).
pub fn size_draw() u32 {
    return size_min + @as(u32, @intCast(sdk.random_below(size_max - size_min + 1)));
}

/// The ring as read: each node's next, null when its node or its pointer is missing (or more
/// than one: a node points to one other).
pub const Ring = struct {
    size: u32,
    next: [size_max]?u32 = @splat(null),

    /// From node 0, the pointers visit every node once and come back in `size` steps.
    pub fn intact(ring: *const Ring) bool {
        assert(ring.size >= size_min and ring.size <= size_max);
        var seen: [size_max]bool = @splat(false);
        var at: u32 = 0;
        for (0..ring.size) |_| {
            if (seen[at]) return false;
            seen[at] = true;
            at = ring.next[at] orelse return false;
            if (at >= ring.size) return false;
        }
        return at == 0;
    }

    /// The nodes in the ring's order from node 0 (an intact ring).
    fn order(ring: *const Ring) [size_max]u32 {
        assert(ring.intact());
        var sequence: [size_max]u32 = undefined;
        var at: u32 = 0;
        for (sequence[0..ring.size]) |*node| {
            node.* = at;
            at = ring.next[at].?;
        }
        return sequence;
    }

    /// The nodes at two places of the ring's order (the ones a swap exchanges: their counters).
    pub fn nodes(ring: *const Ring, places: [2]u32) [2]u32 {
        const sequence = ring.order();
        return .{ sequence[places[0]], sequence[places[1]] };
    }

    /// Each node's next once the nodes at the two places of the ring's order trade them.
    pub fn swapped(ring: *const Ring, places: [2]u32) [size_max]u32 {
        assert(places[0] != places[1] and places[0] < ring.size and places[1] < ring.size);
        var sequence = ring.order();
        std.mem.swap(u32, &sequence[places[0]], &sequence[places[1]]);
        var next: [size_max]u32 = undefined;
        for (0..ring.size) |place| next[sequence[place]] = sequence[(place + 1) % ring.size];
        return next;
    }

    /// "<next of 0>,<next of 1>,..." ("-" for none): an assertion's details.
    pub fn text(ring: *const Ring, buffer: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        for (ring.next[0..ring.size], 0..) |next, node| {
            if (node > 0) writer.writeByte(',') catch break;
            if (next) |friend| writer.print("{d}", .{friend}) catch break else writer.writeByte('-') catch break;
        }
        return writer.buffered();
    }
};

/// Two distinct places of the ring's order, drawn.
pub fn places_draw(size: u32) [2]u32 {
    assert(size >= size_min and size <= size_max);
    const first: u32 = @intCast(sdk.random_below(size));
    const second: u32 = @intCast((first + 1 + sdk.random_below(size - 1)) % size);
    return .{ first, second };
}

/// What a swap's notes say, for the final check: its commit about to be sent (it may happen from
/// then on: a driver killed before its answer, as an eventually command does, leaves it noted),
/// then committed (its nodes' counters each one more) or certainly not.
pub const Note = enum { sent, committed, failed };

pub fn note(kind: Note, nodes: [2]u32) void {
    var line: [32]u8 = undefined;
    const letter: u8 = switch (kind) {
        .sent => 's',
        .committed => 'c',
        .failed => 'f',
    };
    const text = std.fmt.bufPrint(&line, "{c} {d} {d}\n", .{ letter, nodes[0], nodes[1] }) catch unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(outcomes_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), text.ptr, text.len); // One line, appended whole.
}

/// Once faults stop, each node's counter as read (null: none read): at least its acknowledged
/// swaps, at most the ones that may have happened (sent, not certainly failed).
pub fn counters_judge(arena: std.mem.Allocator, counters: []const ?u64) !void {
    assert(counters.len >= size_min and counters.len <= size_max);
    var acknowledged: [size_max]u64 = @splat(0);
    var sent: [size_max]u64 = @splat(0);
    var failed: [size_max]u64 = @splat(0);
    var lines = std.mem.tokenizeScalar(u8, try sdk.file_read(arena, outcomes_path), '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = words.next() orelse continue;
        while (words.next()) |word| {
            const node = std.fmt.parseInt(u32, word, 10) catch continue;
            if (node >= counters.len) continue;
            if (std.mem.eql(u8, kind, "c")) acknowledged[node] += 1;
            if (std.mem.eql(u8, kind, "s")) sent[node] += 1;
            if (std.mem.eql(u8, kind, "f")) failed[node] += 1;
        }
    }
    var total: u64 = 0;
    for (counters, 0..) |counter, node| {
        total += acknowledged[node];
        const possible = sent[node] -| failed[node];
        const kept = if (counter) |value| value >= acknowledged[node] and value <= possible else false;
        sdk.always(kept, "a node's counter counts every acknowledged swap of it and no more", .{
            .node = node,
            .counter = counter orelse 0,
            .acknowledged = acknowledged[node],
            .possible = possible,
        });
    }
    sdk.sometimes(total > 0, "a swap committed", .{ .swaps = total });
}

pub fn size_write(size: u32) !void {
    assert(size >= size_min and size <= size_max);
    var text: [8]u8 = undefined;
    const bytes = std.fmt.bufPrint(&text, "{d}", .{size}) catch unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(size_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.WriteFailed;
    defer _ = linux.close(@intCast(fd));
    if (linux.write(@intCast(fd), bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
}

pub fn size_read() !u32 {
    var buffer: [8]u8 = undefined;
    const fd = linux.open(size_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoRing;
    defer _ = linux.close(@intCast(fd));
    const read = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(read) != .SUCCESS) return error.NoRing;
    const size = std.fmt.parseInt(u32, std.mem.trim(u8, buffer[0..read], " \n"), 10) catch return error.NoRing;
    if (size < size_min or size > size_max) return error.NoRing;
    return size;
}

test "a ring intact, broken, and its swaps" {
    var ring: Ring = .{ .size = 5 };
    for (0..5) |node| ring.next[node] = @intCast((node + 1) % 5);
    try std.testing.expect(ring.intact());
    // Every pair of places, adjacent or not, across the end too: still one ring of 5.
    for (0..5) |first| for (0..5) |second| {
        if (first == second) continue;
        const next = ring.swapped(.{ @intCast(first), @intCast(second) });
        var after: Ring = .{ .size = 5 };
        for (0..5) |node| after.next[node] = next[node];
        try std.testing.expect(after.intact());
    };
    // 0 -> 2 -> 1 -> 3 -> 4 -> 0 once places 1 and 2 trade (nodes 1 and 2).
    const next = ring.swapped(.{ 1, 2 });
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 1, 4, 0 }, next[0..5]);
    try std.testing.expectEqual([2]u32{ 1, 2 }, ring.nodes(.{ 1, 2 }));
    // Two cycles, a missing pointer, one out of range, a node visited twice.
    var broken = ring;
    broken.next[1] = 0; // 0 -> 1 -> 0, and 2 -> 3 -> 4 -> 0.
    try std.testing.expect(!broken.intact());
    broken = ring;
    broken.next[3] = null;
    try std.testing.expect(!broken.intact());
    broken = ring;
    broken.next[3] = 7;
    try std.testing.expect(!broken.intact());
    broken = ring;
    broken.next[4] = 2;
    try std.testing.expect(!broken.intact());
}
