// SPDX-License-Identifier: MIT
//! Snapshots of moment replays. A replay of a run's timeline to a moment (serve's /replay,
//! /recover, a session, an automation) saves the timeline just before the moment (explore
//! --save-snapshots), and the next replay of that timeline to that moment or a later one goes on
//! from the newest before it (--tape-snapshot), not from boot: a Datalevin moment at 470 s took
//! 25 minutes of replay, each time (2026-11-05). Kept per run in replays/layout-<n> (snapshot.zig's
//! layout: another build's are never loaded, so removed), within one budget over every run's:
//! past it, the least recently used go first, a chain's newest end first (a base stays while a
//! snapshot names it).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Snapshot = @import("snapshot.zig");
const tape = @import("tape.zig");

/// Every run's replay snapshots together, at most (since 2026-11-05).
pub const budget_bytes: u64 = 50 << 30;
/// A replay this close (virtual time) to the newest snapshot before its moment saves none:
/// replaying that far is quick, and a JVM's heap makes each snapshot gigabytes.
pub const gap_ms: u64 = 60_000;
/// A snapshot used or saved this recently is never removed (a replay may be loading it).
const recent_s: i64 = 10 * 60;
/// A save's unfinished files (`.part<pid>`) this old are a save that died.
const part_stale_s: i64 = 6 * 60 * 60;
/// Snapshots read from one directory, at most.
const moments_max = 4096;
/// Timelines a replay's snapshots are looked for in, at most: its own and those it extends.
const sources_max = 64;

/// What a replay that needs the timeline from `needed_ms` on does: go on from `from_ms`, the
/// newest saved before it (strictly: the snapshot is a moment the replay passed), and save at
/// `needed_ms - 1` unless that is within `gap_ms` of where it starts.
pub const Choice = struct { from_ms: ?u64, save_at_ms: ?u64 };

pub fn choose(saved_ms: []const u64, needed_ms: u64) Choice {
    if (needed_ms == 0) return .{ .from_ms = null, .save_at_ms = null };
    const before = needed_ms - 1;
    var from: ?u64 = null;
    for (saved_ms) |ms| {
        if (ms <= before and (from == null or ms > from.?)) from = ms;
    }
    const start = from orelse 0;
    return .{ .from_ms = from, .save_at_ms = if (before - start > gap_ms) before else null };
}

test choose {
    // None saved: from boot, saved before the moment, unless the moment is near the start.
    try std.testing.expectEqual(Choice{ .from_ms = null, .save_at_ms = 463_399 }, choose(&.{}, 463_400));
    try std.testing.expectEqual(Choice{ .from_ms = null, .save_at_ms = null }, choose(&.{}, 50_000));
    // The newest strictly before the moment; one at the moment itself is not before it.
    const saved = [_]u64{ 409_999, 463_399, 469_999, 120_000 };
    try std.testing.expectEqual(Choice{ .from_ms = 463_399, .save_at_ms = null }, choose(&saved, 463_400));
    try std.testing.expectEqual(Choice{ .from_ms = 409_999, .save_at_ms = null }, choose(&saved, 463_399));
    try std.testing.expectEqual(Choice{ .from_ms = 469_999, .save_at_ms = 599_999 }, choose(&saved, 600_000));
    try std.testing.expectEqual(Choice{ .from_ms = null, .save_at_ms = null }, choose(&saved, 0));
}

pub const Plan = struct {
    /// Go on from this one (`<directory>/b<branch>-<ms>`).
    from: ?[]const u8 = null,
    /// Save the timeline at this moment, into `directory`.
    save_at_ms: ?u64 = null,
    directory: []const u8,
};

/// The run's replay snapshots of this build's layout: `<run>/replays/layout-<n>`.
pub fn directory_of(arena: std.mem.Allocator, run_directory: []const u8) ![]const u8 {
    return Snapshot.layout_directory(arena, try std.fs.path.join(arena, &.{ run_directory, "replays" }));
}

/// A timeline whose snapshots a replay of `branch` may start from: `branch` itself, and those it
/// extends (a session's timeline, a session's on a session's), each up to the moment the one
/// after it took over: up to there they are one timeline, so a snapshot of it no later than that
/// is the replayed one's state there (a session's checkpoint, after a second session from it
/// crashed too: the first's timeline's snapshot).
pub const Source = struct { branch: u32, until_ns: u64 = std.math.maxInt(u64) };

/// `branch` and the timelines it extends, from their tapes' headers (`<run>/tapes`), into `out`:
/// how many. A tape that cannot be read ends the list there.
pub fn sources_of(arena: std.mem.Allocator, io: std.Io, run_directory: []const u8, branch: u32, out: []Source) usize {
    assert(out.len > 0);
    out[0] = .{ .branch = branch };
    var count: usize = 1;
    const scratch = arena.alloc(u8, 64 * 1024) catch return count;
    const start = arena.alloc(u8, 64 * 1024) catch return count;
    while (count < out.len) {
        const last = out[count - 1];
        const path = std.fmt.allocPrint(arena, "{s}/tapes/branch-{d}.jsonl", .{ run_directory, last.branch }) catch break;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch break;
        defer file.close(io);
        const size = file.readPositionalAll(io, start, 0) catch break;
        const header = tape.header_of(start[0..size], scratch) catch break;
        const extends = header.extends orelse break;
        out[count] = .{ .branch = extends.branch, .until_ns = @min(last.until_ns, extends.vtime_ns) };
        count += 1;
    }
    return count;
}

/// The plan for a replay of `branch` of the run in `run_directory` that needs the timeline from
/// `needed_ms` on; the snapshot it goes on from is marked used (its time: the last removed). It
/// may be one of a timeline `branch` extends (sources_of); it saves as `branch`.
pub fn plan(arena: std.mem.Allocator, io: std.Io, run_directory: []const u8, branch: u32, needed_ms: u64) !Plan {
    const directory = try directory_of(arena, run_directory);
    var sources: [sources_max]Source = undefined;
    const sources_count = sources_of(arena, io, run_directory, branch, &sources);
    var saved: [moments_max]u64 = undefined;
    var owners: [moments_max]u32 = undefined;
    var count: usize = 0;
    for (sources[0..sources_count]) |source| {
        const found = saved_moments(io, directory, source.branch, saved[count..]);
        for (saved[count..][0..found]) |ms| {
            // Named by a millisecond its moment is in or before the end of: kept when that
            // whole millisecond is the replayed timeline's too.
            if ((ms + 1) * std.time.ns_per_ms > source.until_ns) continue;
            saved[count] = ms;
            owners[count] = source.branch;
            count += 1;
        }
    }
    const chosen = choose(saved[0..count], needed_ms);
    const from = if (chosen.from_ms) |ms| blk: {
        // The replayed timeline's own first, when one of its own and an ancestor's share it.
        const owner = owners[std.mem.indexOfScalar(u64, saved[0..count], ms).?];
        break :blk try std.fmt.allocPrint(arena, "{s}/b{d}-{d}", .{ directory, owner, ms });
    } else null;
    if (from) |path| touch(arena, path);
    if (chosen.save_at_ms != null) try std.Io.Dir.cwd().createDirPath(io, directory);
    return .{ .from = from, .save_at_ms = chosen.save_at_ms, .directory = directory };
}

/// The moments of `branch` saved in `directory` (`b<branch>-<ms>.state`, complete ones: a state
/// is written after its memory), into `out`; how many.
fn saved_moments(io: std.Io, directory: []const u8, branch: u32, out: []u64) usize {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var prefix_buffer: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "b{d}-", .{branch}) catch unreachable;
    var count: usize = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (count == out.len) break;
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".state")) continue;
        const digits = entry.name[prefix.len .. entry.name.len - ".state".len];
        out[count] = std.fmt.parseInt(u64, digits, 10) catch continue;
        count += 1;
    }
    return count;
}

/// Marks `<path>` (a snapshot) used now: its state file's time.
fn touch(arena: std.mem.Allocator, path: []const u8) void {
    const state = std.fmt.allocPrintSentinel(arena, "{s}.state", .{path}, 0) catch return;
    _ = linux.utimensat(linux.AT.FDCWD, state, null, 0);
}

const Entry = struct {
    /// Its run's replays directory (of this layout), and its name there.
    directory: []const u8,
    name: []const u8,
    base: []const u8,
    used_s: i64,
    bytes: u64,
    removed: bool = false,
};

/// Brings every run's replay snapshots (`<runs>/<id>/replays`) under `budget_bytes`, least
/// recently used first, never one a snapshot names as its base or one used within `recent_s`,
/// nor any of the runs in `in_use` (a replay of theirs running: what it loads, or saves against,
/// stays). Another layout's are removed (never loaded again), and saves' leftovers.
pub fn evict(arena: std.mem.Allocator, io: std.Io, runs_directory: []const u8, in_use: []const u32, budget: u64) void {
    const cwd = std.Io.Dir.cwd();
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    var entries: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    var runs = cwd.openDir(io, runs_directory, .{ .iterate = true }) catch return;
    defer runs.close(io);
    var run_iterator = runs.iterate();
    while (run_iterator.next(io) catch null) |run| {
        const id = std.fmt.parseInt(u32, run.name, 10) catch continue;
        const busy = std.mem.indexOfScalar(u32, in_use, id) != null;
        const replays = std.fs.path.join(arena, &.{ runs_directory, run.name, "replays" }) catch return;
        const current = directory_of(arena, std.fs.path.join(arena, &.{ runs_directory, run.name }) catch return) catch return;
        var layouts = cwd.openDir(io, replays, .{ .iterate = true }) catch continue;
        defer layouts.close(io);
        var layout_iterator = layouts.iterate();
        while (layout_iterator.next(io) catch null) |layout| {
            const path = std.fs.path.join(arena, &.{ replays, layout.name }) catch return;
            if (!std.mem.eql(u8, path, current)) {
                if (!busy) cwd.deleteTree(io, path) catch {};
                continue;
            }
            total += directory_entries(arena, io, path, now.sec, busy, &entries);
        }
    }
    if (total <= budget) return;
    var removed: u32 = 0;
    var removed_bytes: u64 = 0;
    while (total > budget) {
        var oldest: ?*Entry = null;
        for (entries.items) |*entry| {
            if (entry.removed or now.sec - entry.used_s < recent_s or named_as_base(entries.items, entry)) continue;
            if (oldest == null or entry.used_s < oldest.?.used_s) oldest = entry;
        }
        const chosen = oldest orelse break; // The rest are in use.
        // The state first: a reader never finds a state without its memory.
        for ([_][]const u8{ "state", "mem", "hashes" }) |kind| {
            const file = std.fmt.allocPrint(arena, "{s}/{s}.{s}", .{ chosen.directory, chosen.name, kind }) catch return;
            cwd.deleteFile(io, file) catch {};
        }
        chosen.removed = true;
        total -= chosen.bytes;
        removed += 1;
        removed_bytes += chosen.bytes;
    }
    std.debug.print("[determinismo] replay snapshots past {d} GiB: removed {d} ({d} GiB), " ++
        "{d} GiB kept\n", .{ budget >> 30, removed, removed_bytes >> 30, total >> 30 });
}

/// The snapshots in `directory` into `entries` (none of a busy run's: it only counts), a save's
/// stale leftovers removed; the bytes they take on disk.
fn directory_entries(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    now_s: i64,
    busy: bool,
    entries: *std.ArrayList(Entry),
) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var bytes: u64 = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |file| {
        const path = std.fs.path.join(arena, &.{ directory, file.name }) catch return bytes;
        const stat = file_stat(arena, path) orelse continue;
        if (std.mem.indexOf(u8, file.name, ".part") != null) {
            if (!busy and now_s - stat.mtime_s > part_stale_s) std.Io.Dir.cwd().deleteFile(io, path) catch {};
            continue;
        }
        bytes += stat.bytes;
        if (!std.mem.endsWith(u8, file.name, ".state")) continue;
        const name = arena.dupe(u8, file.name[0 .. file.name.len - ".state".len]) catch return bytes;
        var base_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const base = Snapshot.disk_base(directory, name, &base_buffer) catch continue;
        // Its memory's bytes too: removed with it.
        const memory = std.fmt.allocPrint(arena, "{s}/{s}.mem", .{ directory, name }) catch return bytes;
        const memory_bytes = if (file_stat(arena, memory)) |m| m.bytes else 0;
        if (busy) continue;
        entries.append(arena, .{
            .directory = directory,
            .name = name,
            .base = arena.dupe(u8, base) catch return bytes,
            .used_s = stat.mtime_s,
            .bytes = stat.bytes + memory_bytes,
        }) catch return bytes;
    }
    return bytes;
}

fn named_as_base(entries: []const Entry, entry: *const Entry) bool {
    for (entries) |other| {
        if (other.removed or !std.mem.eql(u8, other.directory, entry.directory)) continue;
        if (std.mem.eql(u8, other.base, entry.name)) return true;
    }
    return false;
}

/// A file's allocated bytes (a snapshot's memory is sparse) and when it last changed.
fn file_stat(arena: std.mem.Allocator, path: []const u8) ?struct { bytes: u64, mtime_s: i64 } {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return null;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path_z, 0, .{ .MTIME = true, .BLOCKS = true }, &stat)) != .SUCCESS) return null;
    return .{ .bytes = stat.blocks * 512, .mtime_s = stat.mtime.sec };
}

test named_as_base {
    var entries = [_]Entry{
        .{ .directory = "a", .name = "setup-1", .base = "", .used_s = 0, .bytes = 10 },
        .{ .directory = "a", .name = "b1-400", .base = "setup-1", .used_s = 5, .bytes = 1 },
        .{ .directory = "b", .name = "b1-400", .base = "", .used_s = 1, .bytes = 1 },
    };
    try std.testing.expect(named_as_base(&entries, &entries[0]));
    try std.testing.expect(!named_as_base(&entries, &entries[1]));
    entries[1].removed = true; // Its base is a leaf once it is gone.
    try std.testing.expect(!named_as_base(&entries, &entries[0]));
}

test "a replay of a session's timeline starts from the timeline it extends, before the session took over" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const run = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const tapes = try std.fs.path.join(arena, &.{ run, "tapes" });
    try std.Io.Dir.cwd().createDirPath(io, tapes);
    // Timeline 0, the run's; 1 a session on it from 5 s; 2 a session on 1 from 9 s (one opened at
    // 1's checkpoint, say); 3 a session on 1 from 4 s, before 1's own part began.
    const headers = [_]tape.Header{
        .{ .inputs = 1, .exploration_seed = 7, .branch = 0, .branch_seed = 0x11 },
        .{ .inputs = 1, .exploration_seed = 7, .branch = 1, .branch_seed = 0x11, .extends = .{ .branch = 0, .vtime_ns = 5_000_000_000 } },
        .{ .inputs = 1, .exploration_seed = 7, .branch = 2, .branch_seed = 0x11, .extends = .{ .branch = 1, .vtime_ns = 9_000_000_000 } },
        .{ .inputs = 1, .exploration_seed = 7, .branch = 3, .branch_seed = 0x11, .extends = .{ .branch = 1, .vtime_ns = 4_000_000_000 } },
    };
    for (headers) |header| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/branch-{d}.jsonl", .{ tapes, header.branch }, 0);
        const fd: linux.fd_t = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644));
        defer _ = linux.close(fd);
        tape.write_header(fd, header);
    }
    var sources: [sources_max]Source = undefined;
    const count = sources_of(arena, io, run, 2, &sources);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(Source{ .branch = 2 }, sources[0]);
    try std.testing.expectEqual(Source{ .branch = 1, .until_ns = 9_000_000_000 }, sources[1]);
    try std.testing.expectEqual(Source{ .branch = 0, .until_ns = 5_000_000_000 }, sources[2]);
    // Saved: 0's at 3.999 s and in 5 s's millisecond (past 1's start), 1's checkpoint in 8.5 s's
    // millisecond and one in 9 s's (past 2's start).
    const directory = try directory_of(arena, run);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    for ([_][]const u8{ "b0-3999", "b0-5000", "b1-8500", "b1-9000" }) |name| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}.state", .{ directory, name }), .data = "" });
    }
    const after = try plan(arena, io, run, 2, 12_000);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/b1-8500", .{directory}), after.from.?);
    // 3 took 1 over at 4 s: 1's own snapshots are not its, 0's at 3.999 s is.
    const early = try plan(arena, io, run, 3, 12_000);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/b0-3999", .{directory}), early.from.?);
    // A timeline's own come first: 2's checkpoint in 8.5 s's millisecond too.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/b2-8500.state", .{directory}), .data = "" });
    const own = try plan(arena, io, run, 2, 12_000);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/b2-8500", .{directory}), own.from.?);
}
