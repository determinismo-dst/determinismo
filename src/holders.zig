// SPDX-License-Identifier: MIT
//! In-run snapshots for the tree explorer (main.zig). When a timeline reaches a behavior the
//! tree did not know, it pauses just after it, where a replay to that moment would stop (vm.zig's
//! hold points), forks a holder and goes on. The holder keeps the machine there, copy-on-write.
//! When the explorer returns to that moment, the holder copies it into a snapshot; to a later
//! moment of the same timeline, it replays only from there. Without a holder the explorer replays
//! from the timeline's start, as before: the tree is the same either way, only faster.
//!
//! A holder costs the memory its timeline writes after it (the pages it still shares are free):
//! a timeline keeps a few, spread out, none while memory runs low. Its cost grows as its timeline
//! goes on, so a holder goes by itself once the host's memory runs low (a node then costs a
//! replay, never a timeline): the VMs' memory comes first (cpus.zig). 18 YugabyteDB timelines
//! and their holders once left srv2 0 GB, thrashing until the OOM killer acted (2026-10-27).
//!
//! While memory runs low, a run with a directory keeps its moments on disk instead (Disk): a
//! short-lived child writes the moment's snapshot, diffed against the timeline's previous one,
//! and the explorer loads it when it needs a node there or after it. Kafka's timelines run 12
//! virtual minutes: without holders (none in 180 of run 67's first 207), each new one replayed
//! its parent from the start, half its time on average.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Snapshot = @import("core").snapshot;
const VM = @import("core").vm;
const fd_pass = @import("fd_pass.zig");
const cpus = @import("cpus.zig");

/// Holders a timeline keeps at most: past it, the one closest to the one before it goes, so the
/// replays from a holder to a later moment stay short wherever the moment is.
pub const per_timeline_max = 8;
/// Holders of a timeline are its length over this apart at least (a timeline reaches new
/// behaviors in bursts: one holder per burst).
const spacing_divisor = 64;
const spacing_ns_min = 10 * std.time.ns_per_ms;
/// Before any of the run's timelines said how long they run: each holder is a fork of the VM
/// (its page tables copied, and every page the guest writes after it copied again), so not
/// every 10 ms of a long timeline (a YugabyteDB VM of 7 GB, reaching new log lines all the
/// time, spent half its time outside the guest; srv3).
const spacing_ns_unknown = std.time.ns_per_s;
/// No holder is made with less memory than this available (MemAvailable): room to grow in; a
/// run's holders leave the sessions' memory too (cpus.sessions_reserve_bytes).
fn make_available_min() u64 {
    return 2 * cpus.memory_reserve() + cpus.sessions_reserve_bytes();
}
/// A holder goes once less than this is available, above where a VM start waits (cpus.zig).
fn keep_available_min() u64 {
    return cpus.reserve_bytes();
}
/// Whether a holder in memory goes, `available` bytes being so: below the reserve; or a VM
/// waits for memory and a VM this one's size would not fit (the VMs' memory comes first:
/// cpus.memory_wanted_waiting); or an explorer's node makers wait for room (`makers` bytes
/// above the reserve, cpus.makers_wanted: 0 when none does) and it is not there. A judgment's
/// makers are what a tree's pace hangs on, the holders in memory a cache for a few of its
/// returns (etcd's 12-hour run 2007: 40 of 594 nodes from one, the makers 1.5 at a time for
/// the room the holders kept).
/// Whether a timeline's holder on disk is written by its own process, the timeline waiting (its
/// VM stopped at the moment, its memory as it was), not by a forked writer while it goes on: a
/// writer keeps every page the VM writes while it runs, up to the VM's whole memory, and so it
/// may only when that much above the reserve is available. With `--holders-on-disk` writers
/// were always forked: Vitess's calibration run 2070 (16 GiB guests, a disk that writes a
/// holder in tens of seconds) went from 83 GB available to 3 in eight minutes, its anonymous
/// memory from 6 to 35 GB, and the memory guard stopped it at 0.85 hours.
fn disk_sync(sync_always: bool, available: u64, keep: u64, vm_bytes: u64) bool {
    if (sync_always) return true;
    return available != 0 and available < keep + vm_bytes;
}

test "a holder on disk is written in place when a writer's copies could take the reserve" {
    const gib: u64 = 1 << 30;
    const keep: u64 = 187 * gib / 12; // srv4's reserve.
    // Room: a writer forked, the timeline goes on.
    try std.testing.expect(!disk_sync(false, 150 * gib, keep, 16 * gib));
    try std.testing.expect(!disk_sync(false, 25 * gib, keep, 4 * gib));
    // Vitess's run 2070 (16 GiB guests, holders on disk): 30 GiB available, a writer's copies
    // up to its VM's 16 would leave less than the reserve; in place.
    try std.testing.expect(disk_sync(false, 30 * gib, keep, 16 * gib));
    try std.testing.expect(disk_sync(false, 18 * gib, keep, 4 * gib));
    try std.testing.expect(disk_sync(true, 150 * gib, keep, 16 * gib)); // Asked for (checks).
    try std.testing.expect(!disk_sync(false, 0, keep, 16 * gib)); // Unknown: never a reason.
}

fn leaves(available: u64, keep: u64, vm_bytes: u64, vm_waits: bool, makers: u64) bool {
    if (available < keep) return true;
    if (vm_waits and available < keep + vm_bytes) return true;
    return makers > 0 and available < keep + makers;
}
/// How often a holder looks at the host's memory, plus up to as much again by its pid: holders
/// look at different moments, so the first ones gone can give enough back for the rest.
const memory_check_ms = 200;

/// What the explorer asks a holder: the moment of the node to make; or (`disk`) to write its
/// snapshot to the run's ladder directory, diffed against `base` (Ladder).
pub const Request = extern struct {
    vtime_ns: u64,
    kind: Kind = .node,
    base_len: u32 = 0,
    base: [Snapshot.disk_name_max]u8 = @splat(0),

    pub const Kind = enum(u32) { node, disk };
};

/// A failing timeline's holders, written to disk one after the other (main.zig's ladder): each
/// `b<timeline>-<ms>`, the pages changed since the one before (its base). Set before the
/// workers fork: `hashes` is a shared mapping (Snapshot.PageHashes), the base's page hashes,
/// which each holder's save updates to its own for the next.
pub const Ladder = struct {
    directory: []const u8,
    hashes: []u64,
};

/// The name a holder's snapshot gets on disk (causality's, for a moment of the timeline).
pub fn ladder_name(buffer: *[Snapshot.disk_name_max]u8, branch: u32, vtime_ns: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "b{d}-{d}", .{ branch, vtime_ns / std.time.ns_per_ms }) catch unreachable;
}

/// A holder as its timeline's summary carries it to the explorer: its process, and where it
/// listens (an abstract Unix socket named after the explorer, its worker and its number there);
/// or (`disk` set, no process) its snapshot in the run's Disk directory, and whether its hold
/// point was inside an idle skip (VM.Hold.Point, for replays on from it).
pub const Held = extern struct {
    pid: linux.pid_t,
    worker: linux.pid_t,
    id: u32,
    vtime_ns: u64,
    disk: bool = false,
    idle: bool = false,
};

/// Where a run's holders go while memory runs low (Owner.disk_hold): `h<timeline>-<ns>` each,
/// the pages changed since the timeline's previous one (Snapshot.disk_save's chain), kept until
/// the run ends (Registry.kept): a return to an older generation's timeline loads one and
/// replays only from there. Deleted once their generation was judged, every such return
/// replayed from the setup snapshot along its whole path: 30 of run 454's 144 nodes (Go-Explore's
/// archive returns to the least visited behaviors of any generation). About 120 MB each on
/// disk (sparse); none written with the disk short (disk_reserve_min).
/// A disk holder: its timeline and moment (Disk.name).
pub const Origin = struct { branch: u32, vtime_ns: u64 };

/// The setup snapshot's name among the disk holders: a branch no timeline has.
const setup_origin: Origin = .{ .branch = std.math.maxInt(u32), .vtime_ns = 0 };

/// Writes the setup snapshot among `disk`'s holders, its page hashes beside it, by a writer of
/// its own (forked twice: nothing for the explorer to reap), and returns its origin: every root's
/// first disk holder saves against it, the pages it changed since the setup, not the whole guest
/// (run 1914: a root's first wrote 8 GB, its later ones skipped meanwhile, and the moments before
/// them were replayed). A root whose writer finds it not there yet writes its whole guest, as
/// before (origin_take: the name not on disk).
pub fn setup_origin_write(setup: *const Snapshot, disk: *const Disk) ?Origin {
    var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
    const name = Disk.name(&name_buffer, setup_origin.branch, setup_origin.vtime_ns);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return null;
    if (pid == 0) {
        const writer = linux.fork();
        if (writer != 0) linux.exit_group(0);
        cpus.forked_without_cpu();
        const mapped = linux.mmap(null, setup.memory_size, .{ .READ = true }, .{ .TYPE = .SHARED }, setup.memory_fd, 0);
        if (linux.errno(mapped) != .SUCCESS) linux.exit_group(1);
        const memory: []align(std.heap.page_size_min) const u8 = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(mapped))[0..setup.memory_size];
        const pages = setup.memory_size / std.heap.page_size_min;
        const hashes = std.heap.page_allocator.alloc(u64, pages) catch linux.exit_group(1);
        @memset(hashes, 0);
        Snapshot.disk_save(setup, memory, setup.memory_fd, hashes, disk.directory, name, null, false) catch linux.exit_group(1);
        Snapshot.disk_hashes_save(hashes, disk.directory, name) catch linux.exit_group(1);
        linux.exit_group(0);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return setup_origin;
}

/// A chain through timelines' disk holders (a timeline's first on its origin) this long at
/// most: deeper, a timeline starts a fresh one (a whole dump), a load reading every base.
const origin_chain_max = 3 * per_timeline_max;

pub const Disk = struct {
    directory: []const u8,

    pub fn name(buffer: *[Snapshot.disk_name_max]u8, branch: u32, vtime_ns: u64) []const u8 {
        return std.fmt.bufPrint(buffer, "h{d}-{d}", .{ branch, vtime_ns }) catch unreachable;
    }

    const suffixes = [_][]const u8{ ".state", ".mem", ".hashes" };

    /// One holder's files: a later return to it replays from its parent's start, as a gone
    /// holder's does (a later holder whose chain it was in fails to load, and replays too).
    pub fn delete_one(disk: *const Disk, branch: u32, vtime_ns: u64) void {
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const base = name(&name_buffer, branch, vtime_ns);
        for (suffixes) |suffix| {
            var path_buffer: [4096]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}{s}", .{ disk.directory, base, suffix }, 0) catch continue;
            _ = linux.unlink(path);
        }
    }

    /// The holder a holder's pages are changes from (its file's header: Snapshot.disk_base):
    /// the timeline's one before it, or for its first the one its node was loaded from (its
    /// parent's), or the setup's. Null for none (it holds every page), or a file not a holder's.
    pub fn base_of(disk: *const Disk, branch: u32, vtime_ns: u64) ?Origin {
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        var base_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const base = Snapshot.disk_base(disk.directory, name(&name_buffer, branch, vtime_ns), &base_buffer) catch return null;
        return origin_of(base);
    }

    /// A holder's name (`h<timeline>-<ns>`) as its timeline and moment.
    fn origin_of(text: []const u8) ?Origin {
        if (text.len < 2 or text[0] != 'h') return null;
        const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
        return .{
            .branch = std.fmt.parseInt(u32, text[1..dash], 10) catch return null,
            .vtime_ns = std.fmt.parseInt(u64, text[dash + 1 ..], 10) catch return null,
        };
    }

    /// One holder's files' bytes on the disk (their blocks: the memory file is sparse).
    pub fn bytes_of(disk: *const Disk, branch: u32, vtime_ns: u64) u64 {
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const base = name(&name_buffer, branch, vtime_ns);
        var bytes: u64 = 0;
        for (suffixes) |suffix| {
            var path_buffer: [4096]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}{s}", .{ disk.directory, base, suffix }, 0) catch continue;
            var stat: linux.Statx = undefined;
            const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .BLOCKS = true }, &stat);
            if (linux.errno(result) == .SUCCESS) bytes += stat.blocks * 512;
        }
        return bytes;
    }

    /// Each of `branches`' holder files on disk (allocated blocks, as bytes_of), every one of
    /// them: a dropped one too (Owner.drop leaves one on disk as a later one's base, in no
    /// timeline's summary). One read of the directory, into `out` (`branches`' order).
    pub fn branches_bytes(disk: *const Disk, branches: []const u32, out: []u64) void {
        assert(out.len == branches.len);
        @memset(out, 0);
        var path_buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{disk.directory}, 0) catch return;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const directory: linux.fd_t = @intCast(opened);
        defer _ = linux.close(directory);
        var entries: [16 * 1024]u8 align(8) = undefined;
        while (true) {
            const size = linux.getdents64(directory, &entries, entries.len);
            if (linux.errno(size) != .SUCCESS or size == 0) break;
            var at: usize = 0;
            while (at < size) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                at += entry.reclen;
                const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                // `h<timeline>-<moment>.<suffix>`: its timeline.
                if (entry_name.len < 2 or entry_name[0] != 'h') continue;
                const dash = std.mem.indexOfScalar(u8, entry_name, '-') orelse continue;
                const branch = std.fmt.parseInt(u32, entry_name[1..dash], 10) catch continue;
                const index = std.mem.indexOfScalar(u32, branches, branch) orelse continue;
                var name_buffer: [256]u8 = undefined;
                const name_z = std.fmt.bufPrintSentinel(&name_buffer, "{s}", .{entry_name}, 0) catch continue;
                var stat: linux.Statx = undefined;
                const result = linux.statx(directory, name_z, 0, .{ .BLOCKS = true }, &stat);
                if (linux.errno(result) == .SUCCESS) out[index] += stat.blocks * 512;
            }
        }
    }

    /// Deletes the snapshots of `branch` (all of them for null).
    pub fn delete(disk: *const Disk, branch: ?u32) void {
        var path_buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{disk.directory}, 0) catch return;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const directory: linux.fd_t = @intCast(opened);
        defer _ = linux.close(directory);
        var prefix_buffer: [32]u8 = undefined;
        const prefix = if (branch) |index|
            std.fmt.bufPrint(&prefix_buffer, "h{d}-", .{index}) catch unreachable
        else
            "h";
        var entries: [16 * 1024]u8 align(8) = undefined;
        // Passes until one deletes nothing: a directory read while its entries go may skip some.
        for (0..passes_max) |_| {
            _ = linux.lseek(directory, 0, linux.SEEK.SET);
            var deleted: u32 = 0;
            while (true) {
                const size = linux.getdents64(directory, &entries, entries.len);
                if (linux.errno(size) != .SUCCESS or size == 0) break;
                var at: usize = 0;
                while (at < size) {
                    const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                    at += entry.reclen;
                    const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                    // "h12-" is no prefix of "h123-...": the number ends at its dash.
                    if (!std.mem.startsWith(u8, entry_name, prefix)) continue;
                    var name_buffer: [256]u8 = undefined;
                    const name_z = std.fmt.bufPrintSentinel(&name_buffer, "{s}", .{entry_name}, 0) catch continue;
                    if (linux.errno(linux.unlinkat(directory, name_z, 0)) == .SUCCESS) deleted += 1;
                }
            }
            if (deleted == 0) return;
        }
    }

    const passes_max = 8;

    /// Whether the directory holds a holder's file (a name of `h`), at its first read.
    fn any(disk: *const Disk) bool {
        var path_buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{disk.directory}, 0) catch return false;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return false;
        defer _ = linux.close(@intCast(opened));
        var entries: [16 * 1024]u8 align(8) = undefined;
        while (true) {
            const size = linux.getdents64(@intCast(opened), &entries, entries.len);
            if (linux.errno(size) != .SUCCESS or size == 0) return false;
            var at: usize = 0;
            while (at < size) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                at += entry.reclen;
                const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (std.mem.startsWith(u8, entry_name, "h")) return true;
            }
        }
    }

    /// Every holder's file deleted (`delete(null)`) by a thread of its own, the caller going on:
    /// serve reaps an ended run with its shared lock held, and run 2019's ~800 GB of holders
    /// (2026-11-15, 19:20) held every request for minutes (its page 77 s). Nothing to delete:
    /// no thread. At most `detached_max` at once; past them, here.
    pub fn delete_detached(disk: *const Disk) void {
        if (!disk.any()) return;
        if (detached_count.fetchAdd(1, .acq_rel) >= detached_max) {
            _ = detached_count.fetchSub(1, .acq_rel);
            disk.delete(null);
            return;
        }
        const copy = std.heap.page_allocator.dupe(u8, disk.directory) catch {
            _ = detached_count.fetchSub(1, .acq_rel);
            disk.delete(null);
            return;
        };
        const thread = std.Thread.spawn(.{}, detached_run, .{copy}) catch {
            std.heap.page_allocator.free(copy);
            _ = detached_count.fetchSub(1, .acq_rel);
            disk.delete(null);
            return;
        };
        thread.detach();
    }

    fn detached_run(directory: []u8) void {
        const disk: Disk = .{ .directory = directory };
        disk.delete(null);
        std.heap.page_allocator.free(directory);
        _ = detached_count.fetchSub(1, .acq_rel);
    }

    /// Until every detached deletion ended (tests).
    pub fn detached_wait() void {
        while (detached_count.load(.acquire) > 0) _ = linux.nanosleep(&.{ .sec = 0, .nsec = 5 * std.time.ns_per_ms }, null);
    }

    const detached_max = 8;
    var detached_count: std.atomic.Value(u32) = .init(0);
};

test "a directory's holders deleted by a thread of their own; one without holders starts none" {
    var path_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, "/tmp/determinismo-detached-{d}", .{linux.getpid()});
    var directory_z_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&directory_z_buffer, "{s}", .{directory}, 0);
    _ = linux.mkdir(directory_z, 0o755);
    defer _ = linux.rmdir(directory_z);
    const disk: Disk = .{ .directory = directory };
    try std.testing.expect(!disk.any());
    disk.delete_detached(); // Nothing there: nothing started.
    try std.testing.expectEqual(@as(u32, 0), Disk.detached_count.load(.acquire));
    for ([_]u32{ 1, 2 }) |branch| for (Disk.suffixes) |suffix| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/h{d}-10{s}", .{ directory, branch, suffix }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.close(@intCast(fd));
    };
    try std.testing.expect(disk.any());
    disk.delete_detached();
    Disk.detached_wait();
    try std.testing.expect(!disk.any());
}

/// A trim's files, deleted by a thread of its own (Registry.trim_start): its lists copied, as
/// the trim's are its caller's.
const Trim = struct {
    directory: []const u8,
    whole: []u32,
    ones: []Origin,
    pending: *std.atomic.Value(u32),

    fn make(directory: []const u8, whole: []const u32, ones: []const Origin, pending: *std.atomic.Value(u32)) ?*Trim {
        const allocator = std.heap.page_allocator;
        const trim = allocator.create(Trim) catch return null;
        trim.* = .{
            .directory = directory,
            .whole = allocator.dupe(u32, whole) catch {
                allocator.destroy(trim);
                return null;
            },
            .ones = allocator.dupe(Origin, ones) catch {
                allocator.free(trim.whole);
                allocator.destroy(trim);
                return null;
            },
            .pending = pending,
        };
        return trim;
    }

    fn free(trim: *Trim) void {
        std.heap.page_allocator.free(trim.whole);
        std.heap.page_allocator.free(trim.ones);
        std.heap.page_allocator.destroy(trim);
    }

    fn delete(directory: []const u8, whole: []const u32, ones: []const Origin) void {
        const disk: Disk = .{ .directory = directory };
        for (whole) |branch| disk.delete(branch);
        for (ones) |one| disk.delete_one(one.branch, one.vtime_ns);
    }

    fn run(trim: *Trim) void {
        delete(trim.directory, trim.whole, trim.ones);
        const pending = trim.pending;
        trim.free();
        _ = pending.fetchSub(1, .acq_rel);
    }
};

/// The explorer's holders of a generation, from its timelines' summaries. The explorer is their
/// subreaper: holders whose worker exited are still its to wait for.
pub const Registry = struct {
    explorer: linux.pid_t,
    entries: [entries_max]Entry = undefined,
    count: u32 = 0,
    /// Disk holders of generations judged: any later return to their timelines loads them.
    /// Never taken (a load leaves the file), so more than one return can start from one.
    kept: []Entry,
    kept_count: u32 = 0,
    /// The kept holders' bytes on disk, and their budget: half the disk's free space above its
    /// reserve when the first generation was judged. Past it, the oldest kept ones go (their
    /// files deleted). Unbounded, they filled the disk in a long run: etcd's 12-hour run 2007
    /// kept 598 GB in 80 minutes, srv4's disk at its reserve 2 hours later, where no holder or
    /// node spills and every return replays.
    kept_bytes: u64 = 0,
    kept_budget: ?u64 = null,
    /// Trims whose files are still being deleted, each by a thread of its own (Trim): a trim of
    /// a long run's oldest kept holders unlinks hundreds of GB, and on the explorer's loop it
    /// stalled it (run 2019: 133 GB 58 s, 177 GB 111 s, ext4 freeing each file's extents).
    trims_pending: std.atomic.Value(u32) = .init(0),
    /// The run's Disk: a holder that left for memory wrote itself there first (Owner.leave_to_disk),
    /// where `take` finds it.
    disk: ?*const Disk = null,

    /// A generation's (the largest, of per_timeline_max each).
    const entries_max = 256 * per_timeline_max;
    /// Past it, a judged generation's disk holders are not kept (their files stay till the end).
    const kept_max = 16 * 1024;
    /// `base`: of a kept one, the holder its pages are changes from (Disk.base_of). `going`,
    /// `base_at` (its base's place among the kept) and `dependents` (the kept ones that are
    /// changes from it and stay): kept_trim's own, while it runs.
    const Entry = struct {
        held: Held,
        branch: u32,
        taken: bool,
        bytes: u64 = 0,
        /// Its timeline's files past its kept holders (dropped ones, left as bases), on the
        /// first kept one of its timeline: counted in the budget, deleted with the last.
        extra: u64 = 0,
        base: ?Origin = null,
        going: bool = false,
        base_at: ?u32 = null,
        dependents: u32 = 0,
    };

    pub fn init(registry: *Registry, arena: std.mem.Allocator) !void {
        const subreaper = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        if (linux.errno(subreaper) != .SUCCESS) return error.Subreaper;
        registry.* = .{ .explorer = linux.getpid(), .kept = try arena.alloc(Entry, kept_max) };
    }

    /// A timeline's holders (its summary's), as it is reaped: not at its generation's judgment,
    /// which a late run (drained, past its budget) never holds, so its last timelines' holders
    /// were never released (Kafka 1919's drain: 46 holders of ~4 GB polling for up to 54 minutes,
    /// through its closing replays, the next hunt waiting for their room).
    pub fn add(registry: *Registry, branch: u32, kept: []const Held) void {
        for (kept) |held| {
            if (registry.count == entries_max) {
                if (!held.disk) kill(held.pid); // Never with generations of at most 256 timelines.
                continue;
            }
            registry.entries[registry.count] = .{ .held = held, .branch = branch, .taken = false };
            registry.count += 1;
        }
    }

    /// A holder's socket, where the snapshot comes back as from a node-making child, and its
    /// pid; or (`disk`) a holder on disk, which a node-making child loads.
    pub const Taken = struct { socket: linux.fd_t = -1, pid: linux.pid_t = 0, disk: ?Held = null };

    /// Whether `branch` has a holder after `vtime_ns` (taken or not): a moment before its first
    /// holder has none to start from, by design (a behavior new at once, before the timeline
    /// made one), unlike one whose holders went (run 454's, an earlier generation's dropped).
    pub fn later(registry: *const Registry, branch: u32, vtime_ns: u64) bool {
        for ([_][]const Entry{ registry.entries[0..registry.count], registry.kept[0..registry.kept_count] }) |entries| {
            for (entries) |entry| {
                if (entry.branch == branch and entry.held.vtime_ns > vtime_ns) return true;
            }
        }
        return false;
    }

    /// The moment of `branch`'s earliest holder (taken or not), if any.
    pub fn earliest(registry: *const Registry, branch: u32) ?u64 {
        var found: ?u64 = null;
        for ([_][]const Entry{ registry.entries[0..registry.count], registry.kept[0..registry.kept_count] }) |entries| {
            for (entries) |entry| {
                if (entry.branch != branch) continue;
                if (found == null or entry.held.vtime_ns < found.?) found = entry.held.vtime_ns;
            }
        }
        return found;
    }

    /// The latest holder of `branch` at or before `vtime_ns` that takes the request (one killed
    /// for memory does not). Null when none does.
    pub fn take(registry: *Registry, branch: u32, vtime_ns: u64) ?Taken {
        while (true) {
            var best: ?*Entry = null;
            for ([_][]Entry{ registry.entries[0..registry.count], registry.kept[0..registry.kept_count] }) |entries| {
                for (entries) |*entry| {
                    if (entry.taken or entry.branch != branch) continue;
                    if (entry.held.vtime_ns > vtime_ns) continue; // At the moment, or replays to it.
                    if (best == null or entry.held.vtime_ns > best.?.held.vtime_ns) best = entry;
                }
            }
            const entry = best orelse return null;
            const held = entry.held;
            if (held.disk) return .{ .disk = held }; // Loaded by a node maker: the file stays.
            entry.taken = true;
            const at = address(registry.explorer, held.worker, held.id);
            if (connect(&at)) |socket| {
                const request = Request{ .vtime_ns = vtime_ns };
                if (write_all(socket, std.mem.asBytes(&request))) {
                    return .{ .socket = socket, .pid = held.pid };
                }
                _ = linux.close(socket);
            }
            kill(held.pid); // Gone, or not answering: the next one, or a replay.
            // Gone for memory, written to disk first: loaded from there (its hashes file, renamed
            // in last, says the write ended).
            if (registry.disk) |disk| {
                var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
                const name = Disk.name(&name_buffer, branch, held.vtime_ns);
                if (Snapshot.disk_hashes_exist(disk.directory, name)) {
                    var on_disk = held;
                    on_disk.pid = 0;
                    on_disk.disk = true;
                    return .{ .disk = on_disk };
                }
            }
        }
    }

    /// A generation judged: the holders of `branches` that nobody took go (their memory), and
    /// those on disk are kept (`kept`) for later returns. One made in memory that left for the
    /// host's memory wrote itself to disk on its way (Owner.leave_to_disk): on disk as any, kept
    /// and counted in the budget. Its entry still said memory, so its file was neither kept nor
    /// deleted, and stayed outside the budget till the run's end.
    pub fn release_listed(registry: *Registry, branches: []const u32) void {
        // Ended together (kill_all), their files deleted once they are gone: one ended while it
        // wrote itself to disk could otherwise rename its file in after the delete.
        var dying: [entries_max]linux.pid_t = undefined;
        var dying_count: usize = 0;
        var files: [entries_max]Origin = undefined;
        var files_count: usize = 0;
        const kept_from = registry.kept_count;
        var staying: u32 = 0;
        for (registry.entries[0..registry.count]) |entry| {
            const theirs = std.mem.indexOfScalar(u32, branches, entry.branch) != null;
            if (!theirs) {
                registry.entries[staying] = entry;
                staying += 1;
            } else if (entry.held.disk or registry.left_to_disk(entry)) {
                // No room to track it: its file goes, never left untracked till the run ends.
                if (registry.kept_count == registry.kept.len) {
                    if (registry.disk) |disk| disk.delete_one(entry.branch, entry.held.vtime_ns);
                    continue;
                }
                var kept = entry;
                kept.held.pid = 0; // Gone, if it was ever a process: a file now (take's on_disk).
                kept.held.disk = true;
                if (registry.disk) |disk| {
                    kept.bytes = disk.bytes_of(entry.branch, entry.held.vtime_ns);
                    kept.base = disk.base_of(entry.branch, entry.held.vtime_ns);
                }
                registry.kept[registry.kept_count] = kept;
                registry.kept_count += 1;
                registry.kept_bytes += kept.bytes;
            } else {
                if (!entry.taken) {
                    dying[dying_count] = entry.held.pid;
                    dying_count += 1;
                }
                // Ended while it wrote itself to disk (no hashes file yet: the write's last):
                // what it had written goes with it.
                files[files_count] = .{ .branch = entry.branch, .vtime_ns = entry.held.vtime_ns };
                files_count += 1;
            }
        }
        kill_all(dying[0..dying_count]);
        if (registry.disk) |disk| {
            for (files[0..files_count]) |file| disk.delete_one(file.branch, file.vtime_ns);
            registry.branches_settle(disk, branches, kept_from);
        }
        registry.count = staying;
        registry.kept_trim();
    }

    /// The files of the timelines just released past their kept holders: the ones each dropped
    /// (Owner.drop: a holder past its timeline's eight leaves its list, its file staying as a
    /// later one's base). Known to no budget and deleted by nothing, they took 18% of run
    /// 2012's holder files (162 GB in 94 timelines, up to 35 holders each) while its budget saw
    /// none of them. Counted now, on the timeline's first kept holder, and deleted with its last
    /// (kept_trim); a timeline with no kept holder has nothing on disk anything loads: they go.
    fn branches_settle(registry: *Registry, disk: *const Disk, branches: []const u32, kept_from: u32) void {
        var totals: [entries_max]u64 = undefined;
        const count = @min(branches.len, totals.len);
        disk.branches_bytes(branches[0..count], totals[0..count]);
        for (branches[0..count], totals[0..count]) |branch, total| {
            var tracked: u64 = 0;
            var first: ?usize = null;
            for (registry.kept[kept_from..registry.kept_count], kept_from..) |entry, at| {
                if (entry.branch != branch) continue;
                tracked += entry.bytes;
                if (first == null) first = at;
            }
            const extra = total -| tracked;
            if (extra == 0) continue;
            if (first) |at| {
                registry.kept[at].extra += extra;
                registry.kept_bytes += extra;
            } else disk.delete(branch);
        }
    }

    /// Whether a holder made in memory wrote itself to disk since (its hashes file, written
    /// last, says the write ended).
    fn left_to_disk(registry: *const Registry, entry: Entry) bool {
        const disk = registry.disk orelse return false;
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        return Snapshot.disk_hashes_exist(disk.directory, Disk.name(&name_buffer, entry.branch, entry.held.vtime_ns));
    }

    /// The oldest kept holders' files deleted until the kept fit their budget: the oldest that
    /// no kept holder is a change from. A holder's pages are changes from a base (its timeline's
    /// holder before it, or for its first the one its node was loaded from: its parent's), and
    /// a load reads the whole chain, so one that a kept holder still changes from stays, however
    /// old, until that one goes; then it goes too, before anything newer. What stays loads.
    /// Trimmed by age alone, a base took its chain with it or left it unloadable: under etcd's
    /// run 2007's budget (applied from outside), timelines 2504, 2506 and 2508 fell back to
    /// replays for timeline 2159's holder ("not loaded from disk (FileNotFound)", 4 of its 11
    /// fallbacks), and timeline 3253, judged ten minutes before, lost its holders with its
    /// parent's (2906, eleven generations older).
    /// A base is kept before what changes from it (judged before, or its timeline's earlier
    /// holder): each one's is looked for among the older ones.
    /// At most this many trims delete at once: a trim past them waits for one to end (the
    /// loop slowed, never an unbounded number of threads on one disk).
    const trims_max = 4;

    /// The files of a trim deleted by a thread of its own, the timelines `whole` entirely and the
    /// single holders `ones`: the explorer's loop goes on meanwhile. Nothing loads them again
    /// (their entries left `kept` before), and nothing writes their names again (a timeline's
    /// holders are written while it runs, long before its judgment).
    fn trim_start(registry: *Registry, disk: *const Disk, whole: []const u32, ones: []const Origin) void {
        if (whole.len == 0 and ones.len == 0) return;
        while (registry.trims_pending.load(.acquire) >= trims_max) {
            _ = linux.nanosleep(&.{ .sec = 0, .nsec = 10 * std.time.ns_per_ms }, null);
        }
        const trim = Trim.make(disk.directory, whole, ones, &registry.trims_pending) orelse {
            Trim.delete(disk.directory, whole, ones); // No memory or thread for it: here.
            return;
        };
        _ = registry.trims_pending.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, Trim.run, .{trim}) catch {
            _ = registry.trims_pending.fetchSub(1, .acq_rel);
            Trim.delete(disk.directory, whole, ones);
            trim.free();
            return;
        };
        thread.detach();
    }

    /// Until every trim's files are deleted (a test reading the disk, the run's end).
    pub fn trims_wait(registry: *Registry) void {
        while (registry.trims_pending.load(.acquire) > 0) {
            _ = linux.nanosleep(&.{ .sec = 0, .nsec = 5 * std.time.ns_per_ms }, null);
        }
    }

    fn kept_trim(registry: *Registry) void {
        const disk = registry.disk orelse return;
        const budget = registry.kept_budget orelse budget: {
            const space = disk_space(disk.directory) orelse return;
            const measured = (space.free -| space.reserve) / 2;
            registry.kept_budget = measured;
            break :budget measured;
        };
        if (registry.kept_bytes <= budget) return;
        const kept = registry.kept[0..registry.kept_count];
        for (kept) |*entry| {
            entry.going = false;
            entry.base_at = null;
            entry.dependents = 0;
        }
        for (kept, 0..) |*entry, at| {
            const base = entry.base orelse continue;
            var older = at;
            while (older > 0) {
                older -= 1;
                if (kept[older].branch != base.branch or kept[older].held.vtime_ns != base.vtime_ns) continue;
                entry.base_at = @intCast(older);
                kept[older].dependents += 1;
                break;
            }
        }
        var dropped: u32 = 0;
        var dropped_bytes: u64 = 0;
        var at: usize = 0;
        while (registry.kept_bytes - dropped_bytes > budget and at < kept.len) {
            const entry = &kept[at];
            if (entry.going or entry.dependents > 0) {
                at += 1;
                continue;
            }
            entry.going = true;
            dropped += 1;
            dropped_bytes += entry.bytes;
            at += 1;
            // Its base, older, may be nothing's base now: the next to go.
            const base_at = entry.base_at orelse continue;
            kept[base_at].dependents -= 1;
            if (kept[base_at].dependents == 0) at = base_at;
        }
        if (dropped == 0) return;
        // The older ones left for what changes from them.
        var needed: u32 = 0;
        for (kept[0..at]) |entry| needed += @intFromBool(!entry.going);
        // A timeline whose kept holders all go (they are side by side: released together, kept in
        // order) goes whole, its dropped ones with it (branches_settle); one with some staying
        // keeps them (bases of the ones that stay, maybe).
        // What goes, gathered here and deleted by a thread (trim_start).
        const whole_branches = std.heap.page_allocator.alloc(u32, kept.len) catch @panic("OOM");
        defer std.heap.page_allocator.free(whole_branches);
        var whole_count: usize = 0;
        const ones = std.heap.page_allocator.alloc(Origin, kept.len) catch @panic("OOM");
        defer std.heap.page_allocator.free(ones);
        var ones_count: usize = 0;
        var run_start: usize = 0;
        while (run_start < kept.len) {
            var run_end = run_start + 1;
            while (run_end < kept.len and kept[run_end].branch == kept[run_start].branch) run_end += 1;
            const run = kept[run_start..run_end];
            const whole = for (run) |entry| {
                if (!entry.going) break false;
            } else true;
            if (whole) {
                whole_branches[whole_count] = run[0].branch;
                whole_count += 1;
                for (run) |entry| dropped_bytes += entry.extra;
            } else for (run) |entry| {
                if (!entry.going) continue;
                ones[ones_count] = .{ .branch = entry.branch, .vtime_ns = entry.held.vtime_ns };
                ones_count += 1;
            }
            run_start = run_end;
        }
        registry.trim_start(disk, whole_branches[0..whole_count], ones[0..ones_count]);
        var staying: u32 = 0;
        for (kept) |entry| {
            if (!entry.going) {
                registry.kept[staying] = entry;
                staying += 1;
            }
        }
        assert(staying + dropped == registry.kept_count);
        registry.kept_count = staying;
        registry.kept_bytes -= dropped_bytes;
        std.debug.print("[determinismo] holders: {d} kept on disk removed for the run's budget " ++
            "({d} MB of them; {d} older ones left, kept ones are changes from them; {d} kept, {d} MB of {d} MB)\n", .{
            dropped,             dropped_bytes >> 20,       needed,
            registry.kept_count, registry.kept_bytes >> 20, budget >> 20,
        });
    }

    /// The holders of `branch` nobody took, set aside (they are not released with their
    /// generation): the caller writes them to disk, then they go (`Taken`'s socket closed, or
    /// `kill`). Sorted by moment, into `out`.
    pub fn set_aside(registry: *Registry, branch: u32, out: []Held) []Held {
        var count: usize = 0;
        for (registry.entries[0..registry.count]) |*entry| {
            if (entry.taken or entry.branch != branch or count == out.len) continue;
            if (entry.held.disk) continue; // On disk already, outside the ladder's chain.
            entry.taken = true;
            out[count] = entry.held;
            count += 1;
        }
        std.sort.insertion(Held, out[0..count], {}, held_earlier);
        return out[0..count];
    }

    /// The holders of `branch` on disk (this generation's), by moment, into `out`. Their files
    /// stay until the run ends (a later return loads them): a ladder keeps them by linking.
    pub fn disk_of(registry: *const Registry, branch: u32, out: []Held) []Held {
        var count: usize = 0;
        for (registry.entries[0..registry.count]) |entry| {
            if (!entry.held.disk or entry.branch != branch or count == out.len) continue;
            out[count] = entry.held;
            count += 1;
        }
        std.sort.insertion(Held, out[0..count], {}, held_earlier);
        return out[0..count];
    }

    fn held_earlier(_: void, a: Held, b: Held) bool {
        return a.vtime_ns < b.vtime_ns;
    }

    /// The holders nobody took go (their memory, before the next generation runs), and every
    /// snapshot on disk.
    pub fn release(registry: *Registry, disk: ?*const Disk) void {
        var dying: [entries_max]linux.pid_t = undefined;
        var dying_count: usize = 0;
        for (registry.entries[0..registry.count]) |*entry| {
            if (entry.taken or entry.held.disk) continue;
            dying[dying_count] = entry.held.pid;
            dying_count += 1;
        }
        kill_all(dying[0..dying_count]);
        registry.count = 0;
        registry.kept_count = 0;
        registry.kept_bytes = 0;
        if (disk) |known| known.delete(null);
        // A trim still deleting finds its files gone already: ended before the explorer does.
        registry.trims_wait();
    }
};

/// A timeline's end, in the worker that runs it: VM.Hold's owner.
pub const Owner = struct {
    /// The explorer and this worker: they name the holders' sockets.
    explorer: linux.pid_t,
    worker: linux.pid_t,
    /// Behaviors the tree knew before this generation: a holder follows one it did not.
    seen: *const std.AutoHashMapUnmanaged(u64, void),
    branch: u32,
    seed: u64,
    start_ns: u64,
    spacing_ns: u64,
    /// A capture's room (large: a snapshot carries the timeline's events state).
    snapshot: *Snapshot,
    make: Make,
    /// Where holders write themselves when the explorer asks (a failing timeline's ladder).
    ladder: ?*const Ladder = null,
    /// Where moments go while memory runs low (null: none made then); always there with
    /// `disk_always` (--holders-on-disk, for checks).
    disk: ?*const Disk = null,
    disk_always: bool = false,
    /// Every disk holder written by the timeline's own process (--holders-on-disk-sync, for
    /// checks): what memory below the reserve does (disk_hold's `sync`).
    disk_sync_always: bool = false,
    /// Every holder in memory leaves at its first look, written to disk first (leave_to_disk:
    /// --holders-leave, for checks; memory pressure does it in hunts).
    leave_always: bool = false,
    /// The timeline's disk holders: the page hashes of the last one written (shared with its
    /// writer, which updates them), its name (the next one's base), the chain's length, and its
    /// writer while it runs.
    disk_hashes: ?[]u64 = null,
    disk_base: [Snapshot.disk_name_max]u8 = undefined,
    disk_base_len: u32 = 0,
    disk_chain: u32 = 0,
    /// The disk holder this timeline's node was made from (kept till the run ends): its first holder
    /// on disk saves against it, the pages changed since alone, not a whole dump (four siblings
    /// returned to one moment each wrote 1.9 GB of nearly the same pages, run 200, srv3).
    disk_origin: ?Origin = null,
    origin_name: [Snapshot.disk_name_max]u8 = undefined,
    disk_writer: linux.pid_t = 0,
    hold: VM.Hold = undefined,
    /// The moment armed (as the explorer will ask for it), and whether it follows a behavior
    /// (else it is periodic: a timeline that finds nothing new for a while still has holders,
    /// for the random moments the tree then returns to).
    armed_ns: ?u64 = null,
    armed_new: bool = false,
    last_ns: ?u64 = null,
    /// Holders made so far (each one's socket number).
    made: u32 = 0,
    /// Whether it said that memory stopped its holders (once a timeline).
    short_said: bool = false,
    /// Whether it said its disk keeps its reserve (no holder on disk, Owner.disk_hold).
    disk_full_said: bool = false,
    /// The last hold point (the holder forked there keeps it): inside an idle skip or not.
    point: VM.Hold.Point = .{ .idle = false },
    kept: [per_timeline_max + 1]Held = undefined,
    kept_count: u32 = 0,

    /// Replays a holder's snapshot of the timeline to a later moment of it (main.zig's
    /// node_make), in the holder.
    pub const Make = struct {
        context: *anyopaque,
        function: *const fn (
            context: *anyopaque,
            vm: *VM,
            from: *const Snapshot,
            seed: u64,
            vtime_ns: u64,
            point: VM.Hold.Point,
        ) anyerror!*const Snapshot,
    };

    pub fn spacing(timeline_ns: ?u64) u64 {
        const length = timeline_ns orelse return spacing_ns_unknown;
        return @max(spacing_ns_min, length / spacing_divisor);
    }

    /// Without new behaviors, a holder this often: the timeline's spread over the most it keeps.
    fn period(owner: *const Owner) u64 {
        return owner.spacing_ns * (spacing_divisor / per_timeline_max);
    }

    /// The holders kept, for the timeline's summary (the explorer's registry).
    pub fn holders(owner: *const Owner) []const Held {
        return owner.kept[0..owner.kept_count];
    }

    pub fn attach(owner: *Owner, vm: *VM) !void {
        owner.hold = .{ .context = owner, .behaviors = behaviors, .reached = reached };
        vm.hold = &owner.hold;
        vm.hold_behaviors = vm.events.behavior_count; // Its parents' are known.
        try owner.arm(vm, owner.start_ns + owner.period(), false);
    }

    fn arm(owner: *Owner, vm: *VM, moment_ns: u64, new: bool) !void {
        owner.armed_ns = moment_ns;
        owner.armed_new = new;
        try vm.hold_arm(moment_ns);
    }

    /// The tree returns just after a behavior it did not know (main.zig's tree_returns): a
    /// hold point there, unless one was made a moment ago.
    fn behaviors(context: *anyopaque, vm: *VM, first_new: u32) !void {
        const owner: *Owner = @ptrCast(@alignCast(context));
        if (owner.armed_new) return; // One armed already: a periodic one gives way.
        for (vm.events.behaviors[first_new..vm.events.behavior_count]) |*behavior| {
            if (behavior.vtime_ns <= owner.start_ns) continue;
            if (owner.seen.contains(behavior.hash)) continue;
            const moment = @max(
                behavior.vtime_ns + std.time.ns_per_us,
                owner.start_ns + std.time.ns_per_ms,
            );
            if (owner.last_ns) |last| if (moment < last + owner.spacing_ns) return;
            return owner.arm(vm, moment, true);
        }
    }

    fn reached(context: *anyopaque, vm: *VM, point: VM.Hold.Point) !void {
        const owner: *Owner = @ptrCast(@alignCast(context));
        const moment = owner.armed_ns.?;
        owner.armed_ns = null;
        owner.armed_new = false;
        owner.last_ns = moment;
        try owner.arm(vm, moment + owner.period(), false); // The next, unless one is new first.
        // Not once host checks' inputs arrived (the timeline's end): their bytes are in this
        // worker's buffer, and a node goes to any worker with its state, not that buffer's
        // content. A replay makes such a node right.
        if (vm.events.check_used > 0) return;
        const available = cpus.memory_available();
        if (owner.disk_always and owner.disk != null) return owner.disk_hold(vm, moment, point, disk_sync(owner.disk_sync_always, available, keep_available_min(), vm.memory.len));
        // None in memory either while an explorer's node makers wait for room (it would take
        // what the holders leaving give them): on disk then, as short of memory.
        if (available < make_available_min() + cpus.makers_wanted()) {
            // Said once a timeline: its nodes are then made by replays (checks read it), or from
            // disk.
            if (!owner.short_said) std.debug.print("[determinismo] holders: {s}, {d} GB " ++
                "available ({d} needed)\n", .{
                if (owner.disk != null) "on disk" else "none made",
                available >> 30,
                make_available_min() >> 30,
            });
            owner.short_said = true;
            // Short of a VM's memory above the reserve, written by this process while the
            // timeline waits: a writer's fork costs the pages the VM writes while it runs, and
            // there is no room for them (disk_sync).
            // Without it, nodes beside a hunt filling the host's memory were all replays (run
            // 1908, Pulsar's 40 VMs of 8 GB, 12 to 16 GB available: 8 of 9, a judgment of 747 s).
            if (owner.disk != null) try owner.disk_hold(vm, moment, point, disk_sync(owner.disk_sync_always, available, keep_available_min(), vm.memory.len));
            return;
        }
        try owner.snapshot.capture(vm);
        owner.point = point;
        const id = owner.made;
        owner.made += 1;
        // Listening before the fork: the explorer may connect whenever it needs the holder.
        const at = address(owner.explorer, owner.worker, id);
        const listener = listen(&at) orelse return;
        const pid = linux.fork();
        if (pid == 0) {
            // It waits; it runs only for whoever asks, who holds a CPU meanwhile (cpus.zig).
            cpus.forked_without_cpu();
            owner.serve(vm, listener, moment);
        }
        _ = linux.close(listener);
        if (linux.errno(pid) != .SUCCESS) return;
        owner.kept[owner.kept_count] = .{
            .pid = @intCast(pid),
            .worker = owner.worker,
            .id = id,
            .vtime_ns = moment,
            // Whether its hold point was inside an idle skip: a node made from it on disk (it
            // left for memory, Registry.take's fallback) replays on with it, as the holder's own
            // point does (left false, such a node ran 46 branches past the replay's: e2e tree,
            // --holders-leave, 2026-11-13).
            .idle = point.idle,
        };
        owner.kept_count += 1;
        if (owner.kept_count > per_timeline_max) owner.drop();
    }

    /// Memory runs low: the moment goes to disk instead, written by a child forked here (the
    /// timeline goes on meanwhile), its pages diffed against the timeline's previous one. With
    /// the previous write still under way, none this time: never a stall.
    /// `sync`: written here, the timeline waiting (its VM stopped at the moment, its memory as
    /// it was), not by a forked writer that lets it go on: no copied pages, for memory below the
    /// reserve.
    fn disk_hold(owner: *Owner, vm: *VM, moment: u64, point: VM.Hold.Point, sync: bool) !void {
        const disk = owner.disk.?;
        if (!disk_room(disk.directory)) {
            // Its nodes are then made by replays, as with no memory: slower, never a full disk.
            if (!owner.disk_full_said) std.debug.print("[determinismo] holders: none on disk " ++
                "either, the disk keeps its reserve\n", .{});
            owner.disk_full_said = true;
            return;
        }
        if (!owner.disk_writer_done(false)) return;
        const hashes = owner.disk_hashes orelse hashes: {
            const pages = vm.memory.len / std.heap.page_size_min;
            const bytes = pages * @sizeOf(u64);
            const mapped = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
            if (linux.errno(mapped) != .SUCCESS) return;
            const made: [*]u64 = @ptrFromInt(mapped);
            owner.disk_hashes = made[0..pages];
            break :hashes made[0..pages];
        };
        // A chain of at most a timeline's holders: loading one reads its bases too.
        if (owner.disk_chain == per_timeline_max) owner.disk_base_len = 0;
        if (owner.disk_base_len == 0) {
            owner.disk_chain = 0;
            if (owner.origin_take(disk, hashes)) |origin| {
                @memcpy(owner.disk_base[0..origin.len], origin);
                owner.disk_base_len = @intCast(origin.len);
                std.debug.print("[determinismo] holders: timeline {d}'s first on disk saved " ++
                    "against its origin {s}\n", .{ owner.branch, origin });
            } else @memset(hashes, 0); // A fresh table: every page written.
        }
        try owner.snapshot.capture(vm);
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = Disk.name(&name_buffer, owner.branch, moment);
        const base: ?[]const u8 = if (owner.disk_base_len > 0) owner.disk_base[0..owner.disk_base_len] else null;
        if (sync) {
            const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
            const written = written: {
                Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, hashes, disk.directory, name, base, point.idle) catch break :written false;
                Snapshot.disk_hashes_save(hashes, disk.directory, name) catch break :written false;
                break :written true;
            };
            // A failed write leaves no file (its node made by a replay) and the hashes partly
            // its own: the next one starts a chain afresh, as after a failed writer.
            if (!written) {
                owner.disk_base_len = 0;
                return;
            }
            return owner.disk_kept(name, moment, point);
        }
        const pid = linux.fork();
        if (pid == 0) {
            machine_forget(vm);
            cpus.forked_without_cpu();
            const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
            Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, hashes, disk.directory, name, base, point.idle) catch
                linux.exit_group(1);
            // For the timelines whose nodes are made from it (their first holders' base).
            Snapshot.disk_hashes_save(hashes, disk.directory, name) catch linux.exit_group(1);
            linux.exit_group(0);
        }
        if (linux.errno(pid) != .SUCCESS) return;
        owner.disk_writer = @intCast(pid);
        owner.disk_kept(name, moment, point);
    }

    /// Leaving for memory (serve): this holder's moment written to disk first, its pages its own
    /// (no memory to find), diffed against the timeline's disk holder before it as at its fork
    /// (that base's hashes read from their file: the shared table moved on since), its hashes
    /// file last; a return finding it gone loads it (Registry.take). Big-VM runs replayed nearly
    /// every return because their holders left before the judgment (Pulsar 1931 and 1932, 8 of 9
    /// and 9 of 9 "its holders before it taken or gone"). None without a base complete on disk:
    /// a whole guest written is what memory pressure cannot afford.
    fn leave_to_disk(owner: *Owner, vm: *VM, moment: u64) void {
        const disk = owner.disk orelse return;
        if (!disk_room(disk.directory)) return;
        // One writer at a time on the host, every run's (held until this process exits).
        const lock = linux.open("/tmp/determinismo-holder-leaving.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o666);
        if (linux.errno(lock) != .SUCCESS) return;
        if (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) return;
        const base: []const u8 = if (owner.disk_base_len > 0) owner.disk_base[0..owner.disk_base_len] else base: {
            const origin = owner.disk_origin orelse return;
            break :base Disk.name(&owner.origin_name, origin.branch, origin.vtime_ns);
        };
        const pages = vm.memory.len / std.heap.page_size_min;
        const bytes = pages * @sizeOf(u64);
        const mapped = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(mapped) != .SUCCESS) return;
        defer _ = linux.munmap(@ptrFromInt(mapped), bytes);
        const made: [*]u64 = @ptrFromInt(mapped);
        const hashes = made[0..pages];
        Snapshot.disk_hashes_load(hashes, disk.directory, base) catch return; // Not written whole yet.
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = Disk.name(&name_buffer, owner.branch, moment);
        const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
        Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, hashes, disk.directory, name, base, owner.point.idle) catch return;
        Snapshot.disk_hashes_save(hashes, disk.directory, name) catch return;
    }

    /// A disk holder written (or being written): the next one's base, kept among the timeline's.
    fn disk_kept(owner: *Owner, name: []const u8, moment: u64, point: VM.Hold.Point) void {
        @memcpy(owner.disk_base[0..name.len], name);
        owner.disk_base_len = @intCast(name.len);
        owner.disk_chain += 1;
        owner.kept[owner.kept_count] = .{
            .pid = 0,
            .worker = owner.worker,
            .id = owner.made,
            .vtime_ns = moment,
            .disk = true,
            .idle = point.idle,
        };
        owner.made += 1;
        owner.kept_count += 1;
        if (owner.kept_count > per_timeline_max) owner.drop();
    }

    /// The origin's name, its page hashes in `hashes`, once a timeline (its first disk holder):
    /// null when it has none, its writer failed, or its chain is long enough already (a load
    /// reads every base).
    fn origin_take(owner: *Owner, disk: *const Disk, hashes: []u64) ?[]const u8 {
        const origin = owner.disk_origin orelse return null;
        owner.disk_origin = null;
        const name = Disk.name(&owner.origin_name, origin.branch, origin.vtime_ns);
        const depth = Snapshot.disk_chain_depth(disk.directory, name) catch return null;
        if (depth >= origin_chain_max) return null;
        Snapshot.disk_hashes_load(hashes, disk.directory, name) catch return null;
        return name;
    }

    /// Whether the last disk holder's writer is done (waiting for it with `wait`). One that
    /// failed leaves no file (its node is then made by a replay) and the shared hashes partly
    /// its own: the next one starts a chain afresh.
    fn disk_writer_done(owner: *Owner, wait: bool) bool {
        if (owner.disk_writer == 0) return true;
        var status: i32 = 0;
        const flags: u32 = if (wait) 0 else linux.W.NOHANG;
        const result = linux.wait4(owner.disk_writer, &status, flags, null);
        if (linux.errno(result) == .SUCCESS and result == 0) return false; // Still writing.
        owner.disk_writer = 0;
        const code: u32 = @bitCast(status);
        const written = linux.errno(result) == .SUCCESS and linux.W.IFEXITED(code) and
            linux.W.EXITSTATUS(code) == 0;
        if (!written) owner.disk_base_len = 0;
        return true;
    }

    /// The timeline ends: its last disk holder is complete before the explorer may load it.
    pub fn disk_wait(owner: *Owner) void {
        _ = owner.disk_writer_done(true);
    }

    /// Drops the holder closest to the one before it (never the first or the newest).
    fn drop(owner: *Owner) void {
        assert(owner.kept_count == per_timeline_max + 1);
        var victim: u32 = 1;
        var gap_min: u64 = std.math.maxInt(u64);
        for (1..owner.kept_count - 1) |index| {
            const gap = owner.kept[index].vtime_ns - owner.kept[index - 1].vtime_ns;
            if (gap < gap_min) {
                gap_min = gap;
                victim = @intCast(index);
            }
        }
        // One on disk stays there (a later one's base): it goes with the timeline's holders.
        if (!owner.kept[victim].disk) kill(owner.kept[victim].pid);
        std.mem.copyForwards(
            Held,
            owner.kept[victim .. owner.kept_count - 1],
            owner.kept[victim + 1 .. owner.kept_count],
        );
        owner.kept_count -= 1;
    }

    /// The holder: waits for the explorer, then makes the node it asks for and exits (or is
    /// killed: dropped by its timeline, released by the explorer).
    fn serve(owner: *Owner, vm: *VM, listener: linux.fd_t, moment_ns: u64) noreturn {
        machine_forget(vm);
        oom_first();
        // Until the explorer asks, or is gone: a holder outlives its worker, never its explorer
        // (killed, or ended with timelines in flight whose holders it never heard of).
        const explorer = linux.pidfd_open(owner.explorer, 0);
        if (linux.errno(explorer) != .SUCCESS) linux.exit_group(0);
        var polled = [_]linux.pollfd{
            .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = @intCast(explorer), .events = linux.POLL.IN, .revents = 0 },
        };
        const check_ms = memory_check_ms + @as(i32, @intCast(@mod(linux.getpid(), memory_check_ms)));
        while (true) {
            const ready = linux.poll(&polled, polled.len, check_ms);
            if (linux.errno(ready) == .INTR) continue;
            if (linux.errno(ready) != .SUCCESS or polled[1].revents != 0) linux.exit_group(0);
            if (polled[0].revents != 0) break;
            const available = cpus.memory_available(); // 0: unknown, never a reason to go.
            if (available == 0 and !owner.leave_always) continue;
            // Below the reserve; or a VM waits for memory and a VM this one's size would not fit
            // (the VMs' memory comes first: cpus.memory_wanted_waiting).
            const short = owner.leave_always or
                leaves(available, keep_available_min(), vm.memory.len, cpus.memory_wanted_waiting(), cpus.makers_wanted());
            if (!short) continue;
            // Going, unless the explorer asked meanwhile; to disk first, out of the explorer's
            // reach while it writes (its listener closed: a request then finds the file or not).
            const asked = linux.poll(polled[0..1], 1, 0);
            if (linux.errno(asked) == .SUCCESS and polled[0].revents != 0) break;
            _ = linux.close(listener);
            // Its memory is what the host is short of: written only above half the reserve and
            // by one leaving holder at a time, the others gone at once (2026-11-13: every holder
            // writing as it left kept its memory through the write, srv4 unresponsive at 13:22).
            // Its memory is what the host is short of: written only above half the reserve and
            // by one leaving holder at a time, the others gone at once (2026-11-13: every holder
            // writing as it left kept its memory through the write, srv4 unresponsive at 13:22).
            // Its node the one a replay makes since 8b0987a6 (the entry's idle point; e2e tree).
            if (owner.leave_always or available >= keep_available_min() / 2) owner.leave_to_disk(vm, moment_ns);
            linux.exit_group(0);
        }
        _ = linux.close(@intCast(explorer));
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) linux.exit_group(1);
        _ = linux.close(listener);
        const socket: linux.fd_t = @intCast(accepted);
        var request: Request = undefined;
        if (!read_exact(socket, std.mem.asBytes(&request))) linux.exit_group(0); // Released.
        if (request.kind == .disk) owner.disk_write(vm, socket, &request, moment_ns);
        if (request.vtime_ns < moment_ns) linux.exit_group(1);
        owner.snapshot.capture_memory(vm.memory, vm.memory_fd) catch linux.exit_group(1);
        // Running on to a later moment is a VM run: on a CPU of the host's pool (cpus.zig), never
        // two VMs on one hardware thread.
        var pool: cpus.Pool = undefined;
        const cpu: ?cpus.Held = if (request.vtime_ns != moment_ns) cpu: {
            pool.open() catch linux.exit_group(1);
            pool.first = true; // A judgment's node: its branches wait for it (cpus.Pool.first).
            break :cpu pool.take();
        } else null;
        const node = if (request.vtime_ns == moment_ns)
            owner.snapshot
        else
            owner.make.function(
                owner.make.context,
                vm,
                owner.snapshot,
                owner.seed,
                request.vtime_ns,
                owner.point,
            ) catch linux.exit_group(1);
        // Its CPU back before the answer, which the explorer may read after another's, one
        // waiting for a CPU (main.zig's node_make_start).
        if (cpu) |held| pool.give(held);
        fd_pass.send(socket, node.memory_fd) catch linux.exit_group(1);
        if (!write_all(socket, std.mem.asBytes(node))) linux.exit_group(1);
        linux.exit_group(0);
    }

    /// Writes this holder's snapshot to the ladder (its pages changed since the base's, whose
    /// hashes the shared table holds, then its own), answers one byte (0: written), and ends:
    /// the explorer asks the next holder after it.
    fn disk_write(owner: *Owner, vm: *VM, socket: linux.fd_t, request: *const Request, moment_ns: u64) noreturn {
        const ladder = owner.ladder orelse linux.exit_group(1);
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = ladder_name(&name_buffer, owner.branch, moment_ns);
        const base = request.base[0..request.base_len];
        const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
        // A full disk takes every run's writes with it: no ladder past the reserve.
        if (!disk_room(ladder.directory)) {
            _ = write_all(socket, &.{1});
            linux.exit_group(1);
        }
        Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, ladder.hashes, ladder.directory, name, base, owner.point.idle) catch {
            _ = write_all(socket, &.{1});
            linux.exit_group(1);
        };
        _ = write_all(socket, &.{0});
        linux.exit_group(0);
    }
};

/// Ends a holder set aside (Registry.set_aside) without writing it.
pub fn end(held: Held) void {
    kill(held.pid);
}

/// Asks a holder set aside (Registry.set_aside) to write itself to the ladder, diffed against
/// `base`; then it ends. Whether it did (a holder gone meanwhile, for memory, did not).
pub fn ask_disk(explorer: linux.pid_t, held: Held, base: []const u8) Written {
    defer kill(held.pid);
    const at = address(explorer, held.worker, held.id);
    const socket = connect(&at) orelse return .gone;
    defer _ = linux.close(socket);
    var request: Request = .{ .vtime_ns = held.vtime_ns, .kind = .disk, .base_len = @intCast(base.len) };
    @memcpy(request.base[0..base.len], base);
    if (!write_all(socket, std.mem.asBytes(&request))) return .gone;
    var answer: [1]u8 = undefined;
    return if (read_exact(socket, &answer) and answer[0] == 0) .written else .failed;
}

/// A ladder step: written; or the holder was gone (left for memory before it was asked: the
/// shared page hashes are untouched, still the base's); or its write failed on the way (they
/// may be partly its own).
pub const Written = enum { written, gone, failed };

/// Ends a holder and waits for it (it may have been waited for already, by its worker). Never
/// a pid of 0 or less: kill(0) is the caller's own process group (the explorer and every
/// worker, without a trace), kill(-1) every process of the user.
pub fn kill(pid: linux.pid_t) void {
    kill_all(&.{pid});
}

/// Ends holders together: every one signalled, then each waited for, so that their teardowns
/// (the kernel freeing a forked guest of up to 4 GB each) run beside one another, not one after
/// another in the explorer's thread (run 2010: 67 released at a judgment's end one at a time,
/// 38 s with no timeline reaped or started). Gone, every one, when it returns.
pub fn kill_all(pids: []const linux.pid_t) void {
    for (pids) |pid| {
        if (pid <= 0) {
            std.debug.print("[determinismo] a holder with pid {d}: not signalled\n", .{pid});
            continue;
        }
        _ = linux.kill(pid, .KILL);
    }
    for (pids) |pid| {
        if (pid <= 0) continue;
        var status: i32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
    }
}

/// How many of `explorer`'s holders' sockets exist (/proc/net/unix, abstract ones shown with
/// a leading '@'): after the tree's release, holders the registry never had. 0 when unreadable.
pub fn listening(explorer: linux.pid_t) u32 {
    var needle_buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "@determinismo-holder-{d}-", .{explorer}) catch unreachable;
    const opened = linux.open("/proc/net/unix", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    // Read in chunks, the end of each kept for a needle split across two.
    var buffer: [64 * 1024]u8 = undefined;
    var kept: usize = 0;
    var count: u32 = 0;
    while (true) {
        const size = linux.read(fd, buffer[kept..].ptr, buffer.len - kept);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        const text = buffer[0 .. kept + size];
        count += @intCast(std.mem.count(u8, text, needle));
        kept = @min(needle.len - 1, text.len);
        std.mem.copyForwards(u8, buffer[0..kept], text[text.len - kept ..]);
    }
    return count;
}

test leaves {
    const gib = 1 << 30;
    // Below the reserve: gone, whoever waits.
    try std.testing.expect(leaves(7 * gib, 8 * gib, 4 * gib, false, 0));
    // Above it, nobody waiting: stays.
    try std.testing.expect(!leaves(9 * gib, 8 * gib, 4 * gib, false, 0));
    // A VM waits and one its size does not fit: gone; it fits: stays.
    try std.testing.expect(leaves(11 * gib, 8 * gib, 4 * gib, true, 0));
    try std.testing.expect(!leaves(12 * gib, 8 * gib, 4 * gib, true, 0));
    // Node makers wait for two claims above the reserve (one in flight, the next): gone until
    // they are there, although a VM would fit (run 2007's 10 to 16 GB available).
    try std.testing.expect(leaves(12 * gib, 8 * gib, 4 * gib, false, 8 * gib));
    try std.testing.expect(leaves(15 * gib, 8 * gib, 4 * gib, true, 8 * gib));
    try std.testing.expect(!leaves(16 * gib, 8 * gib, 4 * gib, false, 8 * gib));
}

test listening {
    const at = address(linux.getpid(), 1, 1);
    const listener = listen(&at) orelse return error.SkipZigTest;
    defer _ = linux.close(listener);
    try std.testing.expectEqual(@as(u32, 1), listening(linux.getpid()));
    try std.testing.expectEqual(@as(u32, 0), listening(std.math.maxInt(i32)));
}

/// A holder's socket: abstract (no file to clean up), named after its explorer, its worker and
/// its number there.
fn address(explorer: linux.pid_t, worker: linux.pid_t, id: u32) linux.sockaddr.un {
    var at: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = std.fmt.bufPrint(at.path[1..], "determinismo-holder-{d}-{d}-{d}", .{
        explorer, worker, id,
    }) catch unreachable; // Three numbers fit.
    return at;
}

fn listen(at: *const linux.sockaddr.un) ?linux.fd_t {
    const created = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(created) != .SUCCESS) return null;
    const socket: linux.fd_t = @intCast(created);
    const bound = linux.bind(socket, @ptrCast(at), @sizeOf(linux.sockaddr.un));
    if (linux.errno(bound) != .SUCCESS or linux.errno(linux.listen(socket, 1)) != .SUCCESS) {
        _ = linux.close(socket);
        return null;
    }
    return socket;
}

fn connect(at: *const linux.sockaddr.un) ?linux.fd_t {
    const created = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(created) != .SUCCESS) return null;
    const socket: linux.fd_t = @intCast(created);
    const connected = linux.connect(socket, @ptrCast(at), @sizeOf(linux.sockaddr.un));
    if (linux.errno(connected) != .SUCCESS) {
        _ = linux.close(socket);
        return null;
    }
    return socket;
}

/// The kernel's OOM killer takes this process before any other.
/// In a fork of the worker (a holder, its disk writer): the worker's machine is not this
/// process's, only its memory and captured state are; nor is the worker's strategy plugin, which
/// would otherwise never see the end of its input when the worker stops it.
fn machine_forget(vm: *VM) void {
    _ = linux.close(vm.vcpu_fd);
    _ = linux.close(vm.vm_fd);
    _ = linux.close(vm.kvm_fd);
    if (vm.events.log_fd) |fd| _ = linux.close(fd);
    if (vm.advisor) |advisor| advisor.forget(advisor.context);
}

/// Snapshots on disk (holders, ladders) leave their filesystem at least the larger of these
/// free: a Kafka hunt's holders took 355 GB in an hour and filled srv3's disk (run 173, every
/// run's writes failing with NoSpaceLeft). A fifth was too much: srv3's 875 GB disk at 175 GB
/// free made none (e2e `runs`).
pub const disk_reserve_min = 100 << 30;
pub const disk_reserve_percent = 10;

/// Whether the filesystem holding `directory` has more free than its reserve.
fn disk_room(directory: []const u8) bool {
    const space = disk_space(directory) orelse return false;
    return space.free >= space.reserve;
}

const DiskSpace = struct { free: u64, reserve: u64 };

/// The filesystem holding `directory`: its free bytes and its reserve.
fn disk_space(directory: []const u8) ?DiskSpace {
    var path_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return null;
    var buffer: Statfs = undefined;
    const result = linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&buffer));
    if (linux.errno(result) != .SUCCESS) return null;
    const block: u64 = @intCast(buffer.bsize);
    const total = buffer.blocks * block;
    return .{ .free = buffer.bavail * block, .reserve = @max(disk_reserve_min, total / 100 * disk_reserve_percent) };
}

/// Linux's `struct statfs` (x86_64).
pub const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

test disk_room {
    try std.testing.expect(@sizeOf(Statfs) == 120);
    // The scratch filesystem of a test host has room or not; a missing directory has none.
    try std.testing.expect(!disk_room("/nonexistent/determinismo"));
}

fn oom_first() void {
    const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), "1000", 4);
    _ = linux.close(@intCast(fd));
}

/// MemAvailable from /proc/meminfo, in bytes (0 when unreadable: no holders then).
fn read_exact(fd: linux.fd_t, target: []u8) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const result = linux.read(fd, target[done..].ptr, target.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return false;
        done += result;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return false;
        done += result;
    }
    return true;
}

test "kept holders on disk past the run's budget go, the oldest first, and none is left untracked" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-kept-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    const disk: Disk = .{ .directory = directory };
    defer {
        disk.delete(null);
        _ = linux.rmdir(directory_z);
    }
    var content: [64 * 1024]u8 = @splat(7);
    for ([_]u32{ 1, 2, 3, 4 }) |branch| for (Disk.suffixes) |suffix| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/h{d}-10{s}", .{ directory, branch, suffix }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.write(@intCast(fd), &content, content.len);
        _ = linux.close(@intCast(fd));
    };
    const one = disk.bytes_of(1, 10);
    try std.testing.expect(one >= 3 * content.len);
    var kept: [3]Registry.Entry = undefined;
    var registry: Registry = .{ .explorer = 0, .kept = &kept, .disk = &disk, .kept_budget = one + one / 2 };
    for ([_]u32{ 1, 2, 3 }, 0..) |branch, at| registry.entries[at] = .{
        .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 10, .disk = true },
        .branch = branch,
        .taken = false,
    };
    registry.count = 3;
    registry.release_listed(&.{ 1, 2, 3 }); // Their generation judged.
    registry.trims_wait();
    // Past the budget (one and a half holders' bytes): 1 and 2 go, 3 is kept.
    try std.testing.expectEqual(@as(u32, 1), registry.kept_count);
    try std.testing.expectEqual(@as(u32, 3), registry.kept[0].branch);
    try std.testing.expectEqual(one, registry.kept_bytes);
    for ([_]u32{ 1, 2, 3 }) |branch| try std.testing.expectEqual(branch == 3, disk.bytes_of(branch, 10) > 0);
    // `kept` full: a holder released then has its files deleted, not left untracked.
    registry.kept_count = kept.len;
    registry.kept_budget = std.math.maxInt(u64);
    registry.entries[0] = .{ .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 10, .disk = true }, .branch = 4, .taken = false };
    registry.count = 1;
    registry.release_listed(&.{4});
    registry.trims_wait();
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(4, 10));
}

test "a kept holder stays while a kept one is a change from it; the oldest that none is go first" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-chain-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    const disk: Disk = .{ .directory = directory };
    defer {
        disk.delete(null);
        _ = linux.rmdir(directory_z);
    }
    // Timeline 1, old: holders at 10 (a change from the setup's), 20 (from its own at 10) and
    // 30 (from 20). Timeline 2, old, from the setup. Timeline 3, a child of 1 loaded from its
    // holder at 20, judged last: its first holder is a change from that one, its second from
    // its first.
    const Chained = struct { branch: u32, vtime_ns: u64, base: []const u8 };
    const chained = [_]Chained{
        .{ .branch = 1, .vtime_ns = 10, .base = "h4294967295-0" },
        .{ .branch = 1, .vtime_ns = 20, .base = "h1-10" },
        .{ .branch = 1, .vtime_ns = 30, .base = "h1-20" },
        .{ .branch = 2, .vtime_ns = 10, .base = "h4294967295-0" },
        .{ .branch = 3, .vtime_ns = 25, .base = "h1-20" },
        .{ .branch = 3, .vtime_ns = 35, .base = "h3-25" },
    };
    var content: [64 * 1024]u8 = @splat(7);
    for (chained) |holder| {
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const holder_name = Disk.name(&name_buffer, holder.branch, holder.vtime_ns);
        try Snapshot.disk_header_write(directory, holder_name, holder.base);
        for ([_][]const u8{ ".mem", ".hashes" }) |suffix| {
            var file_buffer: [128]u8 = undefined;
            const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}{s}", .{ directory, holder_name, suffix }, 0);
            const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
            try std.testing.expect(linux.errno(fd) == .SUCCESS);
            _ = linux.write(@intCast(fd), &content, content.len);
            _ = linux.close(@intCast(fd));
        }
    }
    const one = disk.bytes_of(1, 10);
    try std.testing.expectEqual(@as(?Origin, .{ .branch = 1, .vtime_ns = 10 }), disk.base_of(1, 20));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), disk.base_of(2, 10).?.branch);
    var kept: [8]Registry.Entry = undefined;
    // Room for four of the six.
    var registry: Registry = .{ .explorer = 0, .kept = &kept, .disk = &disk, .kept_budget = 4 * one + one / 2 };
    for (chained, 0..) |holder, at| registry.entries[at] = .{
        .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = holder.vtime_ns, .disk = true },
        .branch = holder.branch,
        .taken = false,
    };
    registry.count = chained.len;
    registry.release_listed(&.{ 1, 2, 3 }); // Their generations judged, the child's last.
    registry.trims_wait();
    const whole = struct {
        // Every kept holder's chain is there: its base is kept, or the setup's.
        fn check(checked: *const Registry, on: *const Disk) !void {
            for (checked.kept[0..checked.kept_count]) |entry| {
                try std.testing.expect(on.bytes_of(entry.branch, entry.held.vtime_ns) > 0);
                const base = entry.base orelse continue;
                if (base.branch == std.math.maxInt(u32)) continue;
                try std.testing.expect(on.bytes_of(base.branch, base.vtime_ns) > 0);
            }
        }
    }.check;
    // The oldest that nothing kept changes from went: timeline 1's last holder and timeline 2's.
    // Timeline 1's first two stay for the child, whose holders load. (By age alone: timeline
    // 1's first, and the child's unloadable or gone with it.)
    try std.testing.expectEqual(@as(u32, 4), registry.kept_count);
    try std.testing.expectEqual(4 * one, registry.kept_bytes);
    for ([_]Origin{ .{ .branch = 1, .vtime_ns = 10 }, .{ .branch = 1, .vtime_ns = 20 }, .{ .branch = 3, .vtime_ns = 25 }, .{ .branch = 3, .vtime_ns = 35 } }, registry.kept[0..4]) |want, got| {
        try std.testing.expectEqual(want.branch, got.branch);
        try std.testing.expectEqual(want.vtime_ns, got.held.vtime_ns);
    }
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(1, 30));
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(2, 10));
    try whole(&registry, &disk);
    // Room for two: the child's second holder is the oldest nothing changes from, then its
    // first; timeline 1's two would go next (nothing changes from them any more).
    registry.kept_budget = 2 * one + one / 2;
    registry.release_listed(&.{});
    registry.trims_wait();
    try std.testing.expectEqual(@as(u32, 2), registry.kept_count);
    try std.testing.expectEqual(@as(u32, 1), registry.kept[0].branch);
    try std.testing.expectEqual(@as(u32, 1), registry.kept[1].branch);
    try whole(&registry, &disk);
    registry.kept_budget = one / 2;
    registry.release_listed(&.{});
    registry.trims_wait();
    try std.testing.expectEqual(@as(u32, 0), registry.kept_count);
    try std.testing.expectEqual(@as(u64, 0), registry.kept_bytes);
    for (chained) |holder| try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(holder.branch, holder.vtime_ns));
}

test "a holder made in memory that left to disk is kept within the budget; one ended mid-write leaves nothing" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-left-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    const disk: Disk = .{ .directory = directory };
    defer {
        disk.delete(null);
        _ = linux.rmdir(directory_z);
    }
    var content: [64 * 1024]u8 = @splat(7);
    // Timelines 1 and 2: whole on disk (their hashes files too). 3: ended as it wrote itself
    // (no hashes file).
    for ([_]u32{ 1, 2, 3 }) |branch| for (Disk.suffixes) |suffix| {
        if (branch == 3 and std.mem.eql(u8, suffix, ".hashes")) continue;
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/h{d}-10{s}", .{ directory, branch, suffix }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.write(@intCast(fd), &content, content.len);
        _ = linux.close(@intCast(fd));
    };
    const one = disk.bytes_of(1, 10);
    var kept: [4]Registry.Entry = undefined;
    var registry: Registry = .{ .explorer = 0, .kept = &kept, .disk = &disk, .kept_budget = one + one / 2 };
    // All three made in memory (their entries say so), taken or gone since: no process to end.
    for ([_]u32{ 1, 2, 3 }, 0..) |branch, at| registry.entries[at] = .{
        .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 10, .disk = false },
        .branch = branch,
        .taken = true,
    };
    registry.count = 3;
    registry.release_listed(&.{ 1, 2, 3 }); // Their generation judged.
    registry.trims_wait();
    // 1 and 2 are disk holders now, counted: past the budget (one and a half), 1 goes.
    try std.testing.expectEqual(@as(u32, 1), registry.kept_count);
    try std.testing.expectEqual(@as(u32, 2), registry.kept[0].branch);
    try std.testing.expect(registry.kept[0].held.disk);
    try std.testing.expectEqual(one, registry.kept_bytes);
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(1, 10));
    try std.testing.expect(disk.bytes_of(2, 10) > 0);
    // 3's part of a write is gone: nothing on disk outside the budget.
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(3, 10));
}

test "a judged generation's holders in memory are ended together, each gone and reaped, then their files deleted" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-ended-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    const disk: Disk = .{ .directory = directory };
    defer {
        disk.delete(null);
        _ = linux.rmdir(directory_z);
    }
    // Four holders in memory (children that only sleep), the second of them ended as it wrote
    // itself to disk (its snapshot file, no hashes file).
    var pids: [4]linux.pid_t = undefined;
    for (&pids) |*pid| {
        const forked = linux.fork();
        if (forked == 0) {
            while (true) _ = linux.nanosleep(&.{ .sec = 60, .nsec = 0 }, null);
        }
        pid.* = @intCast(forked);
    }
    var file_buffer: [128]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/h2-10{s}", .{ directory, Disk.suffixes[0] }, 0);
    const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    try std.testing.expect(linux.errno(fd) == .SUCCESS);
    _ = linux.write(@intCast(fd), "part", 4);
    _ = linux.close(@intCast(fd));
    var kept: [4]Registry.Entry = undefined;
    var registry: Registry = .{ .explorer = 0, .kept = &kept, .disk = &disk };
    for (pids, 0..) |pid, at| registry.entries[at] = .{
        .held = .{ .pid = pid, .worker = 0, .id = 0, .vtime_ns = 10, .disk = false },
        .branch = @intCast(at + 1),
        .taken = false,
    };
    // A fifth, of another timeline, stays.
    registry.entries[4] = .{ .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 10, .disk = false }, .branch = 9, .taken = true };
    registry.count = 5;
    registry.release_listed(&.{ 1, 2, 3, 4 });
    registry.trims_wait();
    try std.testing.expectEqual(@as(u32, 1), registry.count);
    try std.testing.expectEqual(@as(u32, 9), registry.entries[0].branch);
    for (pids) |pid| {
        // Reaped: no longer this process's child, nor anyone's.
        var status: i32 = 0;
        try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.wait4(pid, &status, 1, null))); // WNOHANG
        try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))));
    }
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(2, 10));
}

test "a timeline's dropped holders, left on disk as bases, count in the budget and go with its last kept one" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-dropped-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    const disk: Disk = .{ .directory = directory };
    defer {
        disk.delete(null);
        _ = linux.rmdir(directory_z);
    }
    var content: [64 * 1024]u8 = @splat(7);
    // Timeline 5: a holder at 10 its timeline dropped (Owner.drop: a later one's base, in no
    // summary), two at 20 and 30 it kept. Timeline 6: one it dropped, none kept.
    for ([_][2]u64{ .{ 5, 10 }, .{ 5, 20 }, .{ 5, 30 }, .{ 6, 7 } }) |holder| for (Disk.suffixes) |suffix| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/h{d}-{d}{s}", .{ directory, holder[0], holder[1], suffix }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.write(@intCast(fd), &content, content.len);
        _ = linux.close(@intCast(fd));
    };
    const one = disk.bytes_of(5, 10);
    var kept: [4]Registry.Entry = undefined;
    var registry: Registry = .{ .explorer = 0, .kept = &kept, .disk = &disk, .kept_budget = 100 * one };
    for ([_]u64{ 20, 30 }, 0..) |vtime_ns, at| registry.entries[at] = .{
        .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = vtime_ns, .disk = true },
        .branch = 5,
        .taken = false,
    };
    // Timeline 6's one holder was made in memory and taken: nothing of it on disk to keep.
    registry.entries[2] = .{ .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 8, .disk = false }, .branch = 6, .taken = true };
    registry.count = 3;
    registry.release_listed(&.{ 5, 6 });
    registry.trims_wait();
    // Timeline 5's two kept, and the budget sees its dropped one too.
    try std.testing.expectEqual(@as(u32, 2), registry.kept_count);
    try std.testing.expectEqual(3 * one, registry.kept_bytes);
    // Timeline 6 keeps nothing: its dropped one is nothing's base any more.
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(6, 7));
    try std.testing.expectEqual(one, disk.bytes_of(5, 10));
    // Past the budget, the timeline goes whole: its kept ones and the one it dropped.
    registry.kept_budget = one / 2;
    registry.kept_trim();
    registry.trims_wait();
    try std.testing.expectEqual(@as(u32, 0), registry.kept_count);
    try std.testing.expectEqual(@as(u64, 0), registry.kept_bytes);
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(5, 10));
    try std.testing.expectEqual(@as(u64, 0), disk.bytes_of(5, 30));
}

test "a timeline's holders on disk go, and only its own" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-holders-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    defer _ = linux.rmdir(directory_z);
    const names = [_][]const u8{ "h12-5.state", "h12-5.mem", "h12-9.mem.part77", "h123-5.state", "h7-1.mem" };
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.close(@intCast(fd));
    }
    const disk: Disk = .{ .directory = directory };
    disk.delete(12);
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        const there = linux.errno(linux.access(file, std.posix.F_OK)) == .SUCCESS;
        try std.testing.expectEqual(!std.mem.startsWith(u8, name, "h12-"), there);
    }
    disk.delete(null);
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        try std.testing.expect(linux.errno(linux.access(file, std.posix.F_OK)) != .SUCCESS);
    }
}

test "a judged generation's disk holders serve later returns, more than one each" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const registry = try arena_state.allocator().create(Registry);
    try registry.init(arena_state.allocator());
    const on_disk = [_]Held{
        .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 100, .disk = true },
        .{ .pid = 0, .worker = 0, .id = 1, .vtime_ns = 300, .disk = true },
    };
    registry.add(5, &on_disk);
    registry.release_listed(&.{5}); // Its generation judged.
    registry.trims_wait();
    try std.testing.expectEqual(0, registry.count);
    for (0..2) |_| try std.testing.expectEqual(300, registry.take(5, 400).?.disk.?.vtime_ns);
    try std.testing.expectEqual(100, registry.take(5, 200).?.disk.?.vtime_ns);
    try std.testing.expect(registry.take(5, 50) == null);
    try std.testing.expect(registry.take(6, 400) == null);
    registry.release(null);
    try std.testing.expect(registry.take(5, 400) == null);
}
