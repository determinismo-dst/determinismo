// SPDX-License-Identifier: MIT
//! Snapshots of a replayed timeline, saved to disk at moments (`explore --tape <t>
//! --save-snapshots <dir> --save-at-ms <a,b,...>`): causality analysis forks futures from them
//! without booting or replaying, and they outlive the process (snapshot.zig's disk format).
//!
//! The replay pauses at each moment as at a holder's hold point (holders.zig): its state is
//! captured, and a copy-on-write fork writes it with the memory pages that changed since the one
//! before (the first, since the setup snapshot, saved once per directory), while the replay goes
//! on. One child at a time: each updates the page hashes the next one compares with.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");

pub const moments_max = 256;

pub const Saver = struct {
    /// Takes a writer's process off the replay's CPU: the explorer's CPU pool (cpus.unpin), a
    /// hook, as where a process runs is no part of what it computes.
    unpin: ?*const fn () void = null,
    hold: VM.Hold = undefined,
    directory: []const u8,
    /// The taped branch: snapshots are named after it and their moment (`b<branch>-<ms>`).
    branch: u32,
    moments_ns: []const u64,
    next: usize = 0,
    /// The last one saved (or the setup snapshot): the next one's base.
    base: [Snapshot.disk_name_max]u8 = @splat(0),
    base_len: usize = 0,
    hashes: Snapshot.PageHashes,
    capture: *Snapshot,
    child: ?linux.pid_t = null,
    saved: u32 = 0,
    /// A fork's moment (fork mode, `fork_request`): saved as fork-<vtime ns>, apart from
    /// `moments_ns`.
    fork_ns: ?u64 = null,

    /// Ready to save the timeline that starts from `setup` (the run's setup snapshot, saved as
    /// `setup_name` unless the directory has it). Its moments, in increasing order, from
    /// `moments_ms`.
    pub fn init(
        arena: std.mem.Allocator,
        directory: []const u8,
        branch: u32,
        moments_ms: []const u64,
        setup: *const Snapshot,
        setup_name: []const u8,
    ) !Saver {
        assert(moments_ms.len > 0 and moments_ms.len <= moments_max);
        const moments_ns = try arena.alloc(u64, moments_ms.len);
        for (moments_ms, moments_ns) |ms, *ns| ns.* = ms * std.time.ns_per_ms;
        std.mem.sort(u64, moments_ns, {}, std.sort.asc(u64));
        var saver: Saver = .{
            .directory = directory,
            .branch = branch,
            .moments_ns = moments_ns,
            .hashes = try Snapshot.PageHashes.init(setup.memory_size),
            .capture = try arena.create(Snapshot),
        };
        // The setup snapshot's pages: the first moment's base.
        const size = setup.memory_size;
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, setup.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.OutOfMemory;
        defer _ = linux.munmap(@ptrFromInt(address), size);
        const memory = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(address))[0..size];
        if (Snapshot.disk_exists(directory, setup_name)) {
            try Snapshot.pages_hash(memory, setup.memory_fd, saver.hashes.hashes);
        } else {
            try Snapshot.disk_save(setup, memory, setup.memory_fd, saver.hashes.hashes, directory, setup_name, null, false);
        }
        saver.base_set(setup_name);
        return saver;
    }

    /// A saver for forks alone (a session's explore, `--fork-snapshots`): no moments of its own
    /// and no setup snapshot written first (the gigabytes of a large machine at a session's
    /// start); its first fork is written whole, the next ones against the one before.
    pub fn init_forks(arena: std.mem.Allocator, directory: []const u8, branch: u32, memory_size: u64) !Saver {
        return .{
            .directory = directory,
            .branch = branch,
            .moments_ns = &.{},
            .hashes = try Snapshot.PageHashes.init(memory_size),
            .capture = try arena.create(Snapshot),
        };
    }

    /// A saver for a session's checkpoints (`--checkpoint-snapshots`, the run's replay
    /// snapshots' directory): as one for forks, its first written whole, the next ones against
    /// the one before; each named as a moment of the session's timeline (checkpoint_save).
    pub fn init_checkpoints(arena: std.mem.Allocator, directory: []const u8, branch: u32, memory_size: u64) !Saver {
        return init_forks(arena, directory, branch, memory_size);
    }

    /// Pauses `vm` (the branch, which starts at `start_ns`) at the moments after its start.
    pub fn attach(saver: *Saver, vm: *VM, start_ns: u64) !void {
        while (saver.next < saver.moments_ns.len and saver.moments_ns[saver.next] <= start_ns) {
            std.debug.print("[determinismo] not saved: {d}ns is not after the branch's start " ++
                "({d}ns)\n", .{ saver.moments_ns[saver.next], start_ns });
            saver.next += 1;
        }
        if (saver.next == saver.moments_ns.len) return;
        saver.hold = .{ .context = saver, .behaviors = behaviors, .reached = reached };
        vm.hold = &saver.hold;
        vm.hold_behaviors = vm.events.behavior_count;
        try vm.hold_arm(saver.moments_ns[saver.next]);
    }

    /// The last moment to save: the replay needs to go no further.
    pub fn last_ns(saver: *const Saver) u64 {
        return saver.moments_ns[saver.moments_ns.len - 1];
    }

    fn behaviors(_: *anyopaque, _: *VM, _: u32) !void {}

    /// Fork mode: a guest asked for a fork at `vtime_ns` (sdk.fork): the machine saved at the next
    /// exact stop, 1 ns on, before the guest's next pull (the fork's index), named fork-<ns>.
    pub fn fork_request(context: *anyopaque, vm: *VM, vtime_ns: u64) !void {
        const saver: *Saver = @ptrCast(@alignCast(context));
        if (saver.fork_ns != null) return; // One at a time: a second ask during the first is none.
        saver.hold = .{ .context = saver, .behaviors = behaviors, .reached = reached };
        vm.hold = &saver.hold;
        saver.fork_ns = vtime_ns + 1;
        try vm.hold_arm(vtime_ns + 1);
    }

    fn reached(context: *anyopaque, vm: *VM, point: VM.Hold.Point) !void {
        const saver: *Saver = @ptrCast(@alignCast(context));
        const forking = saver.fork_ns;
        const moment_ns = forking orelse saver.moments_ns[saver.next];
        if (forking == null) {
            saver.next += 1;
            if (saver.next < saver.moments_ns.len) try vm.hold_arm(saver.moments_ns[saver.next]);
        }
        saver.fork_ns = null;
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = if (forking != null)
            try std.fmt.bufPrint(&name_buffer, "fork-{d}", .{moment_ns})
        else
            try std.fmt.bufPrint(&name_buffer, "b{d}-{d}", .{ saver.branch, moment_ns / std.time.ns_per_ms });
        try saver.write(vm, point, name, moment_ns);
    }

    /// Checkpoint mode (a session's det:checkpoint, VM.CheckpointHook): the machine saved as it
    /// is now, among its run's replay snapshots, named as one of the timeline's moments
    /// (`checkpoint_name`). A snapshot of that millisecond there already (the timeline's replay
    /// saved it, or a checkpoint before in the same millisecond) is left as it is: a session at
    /// the checkpoint starts from it or from one before, and a name is one state (the next is
    /// written against it).
    pub fn checkpoint_save(context: *anyopaque, vm: *VM, point: VM.Hold.Point) !void {
        const saver: *Saver = @ptrCast(@alignCast(context));
        const now_ns = (try vm.moment()).vtime_ns;
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = try checkpoint_name(&name_buffer, saver.branch, now_ns);
        if (Snapshot.disk_exists(saver.directory, name)) {
            std.debug.print("[determinismo] checkpoint not saved: {s}/{s} is there already\n", .{ saver.directory, name });
            return;
        }
        // The one before failed (a full disk), its hashes half updated, or its base gone meanwhile
        // (the replay snapshots' budget): this one written whole. A failed save is said, and the
        // session goes on.
        const failed = if (saver.wait()) |_| false else |err| blk: {
            std.debug.print("[determinismo] the checkpoint before was not saved: {s}\n", .{@errorName(err)});
            break :blk true;
        };
        if (failed or (saver.base_len > 0 and !Snapshot.disk_exists(saver.directory, saver.base[0..saver.base_len]))) {
            @memset(saver.hashes.hashes, 0);
            saver.base_len = 0;
        }
        // Its base marked used: the budget removes none used in its last minutes
        // (replay_snapshots.evict), so it stays while the child writes against it.
        if (saver.base_len > 0) {
            var path_buffer: [4096]u8 = undefined;
            const state = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}.state", .{ saver.directory, saver.base[0..saver.base_len] }, 0);
            _ = linux.utimensat(linux.AT.FDCWD, state, null, 0);
        }
        try saver.write(vm, point, name, now_ns);
    }

    /// The machine's state captured, then its pages written by a child against the last one
    /// saved (each child updates the page hashes the next compares with: the one before is
    /// waited for), named `name`.
    fn write(saver: *Saver, vm: *VM, point: VM.Hold.Point, name: []const u8, moment_ns: u64) !void {
        try saver.wait(); // The page hashes are the last one's.
        try saver.capture.capture(vm);
        const pid = linux.fork();
        if (pid == 0) {
            if (saver.unpin) |unpin| unpin(); // Off the replay's CPU (the explorer's pool: cpus.unpin).
            // A fork saver's first has no base: it is written whole (fork mode saves no setup).
            const base: ?[]const u8 = if (saver.base_len == 0) null else saver.base[0..saver.base_len];
            const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
            // Saved before (another analysis): its pages are this memory's, for the next.
            const result = if (Snapshot.disk_exists(saver.directory, name))
                Snapshot.pages_hash(memory, vm.memory_fd, saver.hashes.hashes)
            else
                Snapshot.disk_save(saver.capture, memory, vm.memory_fd, saver.hashes.hashes, saver.directory, name, base, point.idle);
            result catch |err| {
                std.debug.print("[determinismo] saving snapshot {s} failed: {s}\n", .{ name, @errorName(err) });
                linux.exit_group(1);
            };
            // What waits on it (serve, for a fork's futures) starts from it now.
            std.debug.print("[determinismo] snapshot written {s}/{s}\n", .{ saver.directory, name });
            linux.exit_group(0);
        }
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        saver.child = @intCast(pid);
        saver.base_set(name);
        std.debug.print("[determinismo] saved snapshot {s}/{s} at vtime={d}ns\n", .{
            saver.directory, name, moment_ns,
        });
        saver.saved += 1;
    }

    fn base_set(saver: *Saver, name: []const u8) void {
        assert(name.len < Snapshot.disk_name_max);
        @memcpy(saver.base[0..name.len], name);
        saver.base_len = name.len;
    }

    /// Waits for the snapshot being written.
    fn wait(saver: *Saver) !void {
        const pid = saver.child orelse return;
        saver.child = null;
        var status: i32 = 0;
        while (true) {
            const result = linux.wait4(pid, &status, 0, null);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS) return error.Wait;
            break;
        }
        if (status != 0) return error.SnapshotSaveFailed;
    }

    /// After the replay: every snapshot written, or an error.
    pub fn finish(saver: *Saver) !void {
        try saver.wait();
        saver.hashes.deinit();
        if (saver.next < saver.moments_ns.len) {
            std.debug.print("[determinismo] the timeline ended before {d}ns: {d} snapshots " ++
                "not saved\n", .{ saver.moments_ns[saver.next], saver.moments_ns.len - saver.next });
        }
    }
};

/// A checkpoint's snapshot name (`b<branch>-<ms>`, replay_snapshots.zig's): the millisecond of
/// the nanosecond before it. A session opened at its event (serve's moment_ms: the millisecond
/// the event falls in, or the next) needs a snapshot named strictly before that millisecond
/// (replay_snapshots.choose), and one saved exactly on a millisecond's start is then still
/// before it, not left out.
pub fn checkpoint_name(buffer: []u8, branch: u32, vtime_ns: u64) ![]const u8 {
    assert(vtime_ns > 0);
    return std.fmt.bufPrint(buffer, "b{d}-{d}", .{ branch, (vtime_ns - 1) / std.time.ns_per_ms });
}

test checkpoint_name {
    const choose = @import("replay_snapshots.zig").choose;
    var buffer: [Snapshot.disk_name_max]u8 = undefined;
    // A checkpoint at 15,226.898855 ms, on a millisecond's start, and its last nanosecond: a
    // session opened at its event's moment (rounded up, as serve's moment_ms) starts from it.
    for ([_]u64{ 15_226_898_855, 15_227_000_000, 15_226_999_999, 1 }) |vtime_ns| {
        const name = try checkpoint_name(&buffer, 4, vtime_ns);
        const ms = try std.fmt.parseInt(u64, name["b4-".len..], 10);
        const moment_ms = (vtime_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        try std.testing.expectEqual(@as(?u64, ms), choose(&.{ms}, moment_ms).from_ms);
        // Never a millisecond after the machine it names: a session before it never starts there.
        try std.testing.expect(ms * std.time.ns_per_ms < vtime_ns);
    }
    try std.testing.expectEqualStrings("b4-15226", try checkpoint_name(&buffer, 4, 15_227_000_000));
}
