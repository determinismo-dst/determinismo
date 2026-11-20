// SPDX-License-Identifier: MIT
//! A node, a snapshot at a moment of a recorded timeline, made by running the timeline there
//! again: from its start with its seed and tape (make), along its ancestors from the setup
//! snapshot (chain), from one of its holders in memory (from_hold) or on disk (from_disk). Core
//! (PLAN: a run pins its core): a child's replay re-derives its start this way, so how a node is
//! made decides every timeline that branches from it. Where makers run, and which holder serves,
//! is the explorer's (main.zig, holders.zig).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const tape = @import("tape.zig");
const cpuid = @import("cpuid.zig");

/// A recorded timeline, as anything that runs a stretch of it again needs it: its seed and what
/// was decided in it beyond the seed (its tape: a strategy's overrides, the explorer's steering
/// of its driver phase, with their checkpoints). The only thing node_make replays: every path
/// that runs a segment again (the tree's nodes and chains, holders, disk holds, explore --tape)
/// loads it, none from a seed alone. The tree once replayed parents from their seeds alone,
/// harmless until the explorer steered decisions: rqlite's run 427 parted 11 of 212 replays.
pub const Recorded = struct {
    seed: u64,
    /// Null only where no tapes are kept: then nothing was overridden (the explorer steers only
    /// into a tape, VM.decide_random).
    tape: ?*tape.Overrides,

    /// Timeline `index`'s, its tape read from `directory` into `buffer` (none there: nothing
    /// was overridden in it).
    pub fn load(
        arena: std.mem.Allocator,
        directory: ?[]const u8,
        index: u32,
        seed: u64,
        buffer: *tape.Overrides,
    ) !Recorded {
        const known = directory orelse return .{ .seed = seed, .tape = null };
        return .{ .seed = seed, .tape = try tape_overrides(arena, known, index, buffer) };
    }
};

pub fn tape_overrides(
    arena: std.mem.Allocator,
    directory: []const u8,
    index: u32,
    overrides: *tape.Overrides,
) !?*tape.Overrides {
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/branch-{d}.jsonl", .{ directory, index }, 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var source: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const size = linux.read(@intCast(fd), &chunk, chunk.len);
        if (linux.errno(size) != .SUCCESS) return error.TapeRead;
        if (size == 0) break;
        try source.appendSlice(arena, chunk[0..size]);
    }
    var scratch: [64 * 1024]u8 = undefined;
    _ = try tape.parse(source.items, &scratch, overrides);
    return overrides;
}

pub fn moment_after_snapshot(snapshot: *const Snapshot, vtime_ns: u64) !void {
    const snapshot_ns = snapshot.tsc / (cpuid.tsc_hz / std.time.ns_per_s);
    if (vtime_ns > snapshot_ns) return;
    std.debug.print("[determinismo] the moment {d}ns is not after the snapshot ({d}ns): " ++
        "branches start there\n", .{ vtime_ns, snapshot_ns });
    return error.MomentBeforeSnapshot;
}

/// A snapshot at `vtime_ns` of the recorded timeline that runs from `from`: replays it there.
pub fn make(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    from: *const Snapshot,
    recorded: Recorded,
    vtime_ns: u64,
    /// `from` is a node (a moment of another timeline): the run is a branch's, from its branch
    /// point (VM.Options.branch_signal), as the timeline it replays was.
    branch_point: bool,
) !*const Snapshot {
    try moment_after_snapshot(from, vtime_ns);
    var probe = options.*;
    probe.seed = recorded.seed;
    probe.branch_signal = branch_point;
    probe.moment_vtime_ns = vtime_ns;
    probe.moment_command = null;
    probe.moment_continue = false;
    probe.until = null;
    probe.events_fd = null;
    try vm.init_from_snapshot(&probe, from);
    vm.overrides = recorded.tape;
    // From inside its segment (a holder's snapshot): its tape from the snapshot's pull on.
    if (options.from_hold != null) if (recorded.tape) |taped| taped.seek_inside(vm.decisions.pulls);
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached) {
        vm.deinit();
        return error.MomentNotReached;
    }
    const snapshot = try arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    return snapshot;
}

/// Made by a holder of the timeline itself (holders.zig, through main.zig's HolderMaker): on
/// from its own snapshot at `point`, the timeline going on as it did there.
pub fn from_hold(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    from: *const Snapshot,
    recorded: Recorded,
    vtime_ns: u64,
    point: VM.Hold.Point,
) !*const Snapshot {
    var held = options.*;
    assert(held.from_hold == null);
    held.from_hold = point; // The timeline goes on as it did there.
    return make(arena, vm, &held, from, recorded, vtime_ns, false);
}

/// From a holder on disk (`name` in `directory`, its moment `held_ns`): its snapshot itself at
/// its own moment, else a replay on from it as the holder would have made (from_hold).
pub fn from_disk(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    held_ns: u64,
    point: VM.Hold.Point,
    recorded: Recorded,
    vtime_ns: u64,
    root: ?Snapshot.DiskRoot,
) !*const Snapshot {
    const loaded = try arena.create(Snapshot);
    try loaded.disk_load(arena, io, directory, name, &.{}, root);
    if (vtime_ns == held_ns) return loaded;
    return from_hold(arena, vm, options, loaded, recorded, vtime_ns, point);
}

/// Where a chain stopped: the segment, and whether its tape could not be read (no snapshot then,
/// rather than one from a state the ancestor never had).
pub const ChainFailure = struct { segment: tape.Segment, tape_unread: bool };

/// Along a path: each ancestor replayed with its own tape (read in turn into `buffer`) from
/// `from` to the moment the next branched from it, snapshotted there as the exploration did.
pub fn chain(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    from: *const Snapshot,
    path: []const tape.Segment,
    tape_directory: ?[]const u8,
    buffer: *tape.Overrides,
    failure: *?ChainFailure,
) !*const Snapshot {
    var start = from;
    for (path, 0..) |segment, depth| {
        const recorded = Recorded.load(arena, tape_directory, segment.branch, segment.seed, buffer) catch |err| {
            failure.* = .{ .segment = segment, .tape_unread = true };
            return err;
        };
        // Each ancestor on the clock it ran on (`options`: the run's, for one that had none).
        var segment_options = options.*;
        if (segment.jitter_seed) |jitter| segment_options.tsc_jitter_seed = jitter;
        start = make(arena, vm, &segment_options, start, recorded, segment.vtime_ns, depth > 0) catch |err| {
            failure.* = .{ .segment = segment, .tape_unread = false };
            return err;
        };
    }
    return start;
}
