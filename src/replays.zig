// SPDX-License-Identifier: MIT
//! Timelines replayed while a run explores (explore with --record and --tape-dir): a verifier
//! process reads the record as it grows and replays `percent` of its timelines from their tapes,
//! a quarter of that once `confident_after` replays agreed and none differed (each one's by a
//! hash of its index: spread over the run, the same on a resume, which reads the results kept),
//! each replay its own explore (a CPU of the pool, beside the run's workers: under the run's own
//! load), comparing its history (events hash) with the record's. The run ends with a property
//! of determinismo's, "timelines replay to their recorded history": a timeline that does not
//! is a determinism bug, found on a real workload as it ran (its replay's first difference is
//! where to look: explore --trace, its .rdtsc log, DETERMINISMO_ITRACE_AT).
//!
//! When the run's timelines are done, the explorer asks the verifier to finish (SIGUSR1): it
//! reads the record a last time and replays the sampled timelines still pending, and each
//! failing property's first failing timeline (the one a person or an agent debugs: it must
//! replay), side by side on the CPUs the workers left (so that a short run is checked too, and
//! a long one waits about one timeline more), then exits.
//!
//! Sampled over the whole run, deep timelines included: 16 of the first generations alone found
//! a timeline started from an in-run snapshot that its replay did not follow by chance (run
//! 283, timeline 207); 20% by default since, to find such bugs sooner (since
//! 2026-10-31), at about that much of the run's CPU.
const std = @import("std");
const event_files = @import("event_files.zig");
const runs = @import("runs.zig");
const activity = @import("activity.zig");
const assert = std.debug.assert;
const linux = std.os.linux;
const cpus = @import("cpus.zig");

/// At most this many replays in a run (each as long as its timeline): a bound, not a sample
/// size (20% of a run of 40,960 timelines).
pub const replays_max = 8192;
/// Replays that all came back the same before the share replayed drops to a quarter: a fifth of
/// every timeline took 8% of a Raft run's worker time (run 1364) re-confirming, once dozens agreed,
/// what one difference would refute. A difference brings the whole share back.
const confident_after = 30;
/// Replays side by side when the run is done, at most (the host's CPUs bound them before).
const finish_threads_max = 256;
/// setpriority's `which` for a process (a thread, on Linux: its threads after inherit it).
const prio_process = 0;
/// The record is read this often; a timeline is replayed once it was there at the read before
/// (its tape closed).
const scan_interval_ns = 5 * std.time.ns_per_s;
/// The results file read at most this large.
const results_bytes_max = 1 << 20;
/// While the explorer waits for the last replays, it says how far they are this often.
const progress_interval_ns = 2 * std.time.ns_per_s;

pub const Verifier = struct {
    pid: linux.pid_t,
    results_path: []const u8,

    /// The verifier's process (a process group of its own, gone with the explorer). `held`: the
    /// explorer's descriptors it closes at once (a running strategy's pipes).
    pub fn start(
        arena: std.mem.Allocator,
        io: std.Io,
        argv: []const [:0]const u8,
        record: []const u8,
        tapes: []const u8,
        percent: u32,
        jobs: u32,
        held: []const linux.fd_t,
    ) !Verifier {
        assert(percent > 0 and percent <= 100);
        const results_path = try std.fmt.allocPrint(arena, "{s}.replays", .{record});
        std.Io.Dir.cwd().deleteFile(io, results_path) catch {};
        const replayer: Replayer = .{
            .base = try system_pinned(arena, io, try program_kept(arena, io, try replay_argv(arena, argv, cpus.run_key orelse linux.getpid()), tapes), argv),
            .tapes = tapes,
            .events = flag_value(argv, "--events-dir"),
            .from_snapshot = flag_value(argv, "--from-snapshot") != null,
        };
        const explorer = linux.getpid();
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
            if (linux.getppid() != explorer) linux.exit_group(0);
            // The explorer's pipes to a strategy running as this forks (the setup's): a plugin
            // sees its input end only once every holder closed it, and the explorer waits for
            // it to exit (a setup-decisions run hung on it, 2026-11-18).
            for (held) |fd| _ = linux.close(fd);
            runs.running_forget(); // The run is the explorer's: it ends with it.
            _ = linux.setpgid(0, 0); // Its replays with it: stopped as one.
            // Forked while the explorer held its CPU for the setup: its replays (programs of
            // their own, which read their affinity afresh) get every CPU the run was given.
            cpus.unpin();
            const action: linux.Sigaction = .{
                .handler = .{ .handler = finish_requested },
                .mask = linux.sigemptyset(),
                .flags = 0,
            };
            _ = linux.sigaction(linux.SIG.USR1, &action, null);
            verify_loop(io, replayer, record, percent, jobs, results_path);
            linux.exit_group(0);
        }
        return .{ .pid = @intCast(pid), .results_path = results_path };
    }

    /// Lets it replay the sampled timelines still pending (the run's are all recorded), waits
    /// for it, and reads what it found. Meanwhile `watcher.verifying(progress)` hears how far it
    /// is every few seconds: the run's timelines are all done, and nothing else shows it working
    /// (run 317's page showed its last timeline running for the five minutes its replays took).
    /// The replays left, done by `end_ns` (the budget's grace, main.zig's tail_grace_ns) or
    /// stopped there: those done are the verdict, the rest not replayed.
    pub fn finish(verifier: *const Verifier, arena: std.mem.Allocator, io: std.Io, watcher: anytype, end_ns: ?u64) !Results {
        _ = linux.kill(verifier.pid, .USR1);
        const buffer = try arena.alloc(u8, results_bytes_max);
        var status: i32 = 0;
        var waited_ns: u64 = progress_interval_ns; // Said at once.
        while (true) : (waited_ns += progress_interval_ns / 20) {
            const waited = linux.waitpid(verifier.pid, &status, linux.W.NOHANG);
            switch (linux.errno(waited)) {
                .SUCCESS => if (waited == verifier.pid) break,
                .INTR => continue,
                else => break,
            }
            if (waited_ns >= progress_interval_ns) {
                watcher.verifying(progress_parse(file_read(verifier.results_path, buffer)));
                waited_ns = 0;
            }
            if (end_ns) |end| if (monotonic_ns() >= end) {
                std.debug.print("[determinismo] the budget's grace is over: the replays left " ++
                    "stopped\n", .{});
                break;
            };
            sleep_ns(progress_interval_ns / 20);
        }
        _ = linux.kill(-verifier.pid, .KILL); // Anything of its group left.
        const text = std.Io.Dir.cwd().readFileAlloc(io, verifier.results_path, arena, .limited(results_bytes_max)) catch "";
        return results_parse(arena, text);
    }
};

pub const Results = struct {
    replayed: u32 = 0,
    same: u32 = 0,
    /// Replayed exactly by the guest, judged otherwise by the host checks (counted in `same`).
    rejudged: u32 = 0,
    first_different: ?u32 = null,
    /// The lines of the timelines that did not replay, or were judged anew, for people.
    different: []const []const u8 = &.{},
};

/// The replays done so far (killed or failed ones too: their turn is over), of how many in all
/// once the run is done (the results' "of <count>" line, written as the last ones start).
pub const Progress = struct { replayed: u32 = 0, of: ?u32 = null };

fn progress_parse(text: []const u8) Progress {
    var progress: Progress = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const first = words.next() orelse continue;
        if (std.mem.eql(u8, first, "of")) {
            progress.of = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        } else if (std.fmt.parseInt(u32, first, 10)) |_| {
            progress.replayed += 1;
        } else |_| {}
    }
    return progress;
}

/// `path`'s start, as much as `buffer` holds ("" when it cannot be read).
fn file_read(path: []const u8, buffer: []u8) []const u8 {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buffer.len) return "";
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const fd = linux.open(path_buffer[0..path.len :0], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < buffer.len) {
        const got = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        size += got;
    }
    return buffer[0..size];
}

/// Results lines: "<index> same <hash>" or "<index> different <recorded> <replayed> <why>"; and
/// "of <count>", the replays in all once the run is done (Progress).
fn results_parse(arena: std.mem.Allocator, text: []const u8) !Results {
    var results: Results = .{};
    var different: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const index = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        const verdict = words.next() orelse continue;
        // Not replayed: killed, or it could not run (its output kept beside the tapes).
        if (std.mem.eql(u8, verdict, "killed") or std.mem.eql(u8, verdict, "failed")) continue;
        results.replayed += 1;
        if (std.mem.eql(u8, verdict, "same")) {
            results.same += 1;
        } else if (std.mem.eql(u8, verdict, "rejudged")) {
            results.same += 1;
            results.rejudged += 1;
            try different.append(arena, line);
        } else {
            results.first_different = results.first_different orelse index;
            try different.append(arena, line);
        }
    }
    results.different = different.items;
    return results;
}

/// The explorer's own command line for one timeline's replay: what boots the system, without
/// what drives an exploration (its tape has the seeds and decisions).
fn replay_argv(arena: std.mem.Allocator, argv: []const [:0]const u8, run_key: ?linux.pid_t) ![]const []const u8 {
    const with_value = [_][]const u8{
        "--branches",       "--time-budget",   "--jobs",       "--record",         "--tape-dir",
        "--events-dir",     "--branching",     "--generation", "--pipeline",       "--horizon",
        "--return-offsets", "--strategy",      "--shard",      "--verify-replays", "--save-snapshots",
        "--save-at-ms",     "--data",          "--branch",     "--tape",           "--at-vtime-ms",
        "--until",          "--run-directory", "--exec",       "--exec-script",    "--rewind-ms",
        "--from-branch",    "--from-vtime-ms", "--from-exec",  "--from-snapshot",  "--trace",
        "--events",         "--seed",          "--run-key",
    };
    const alone = [_][]const u8{ "--resume", "--archive", "--no-archive", "--continue" };
    // Futures from a saved machine replay from it, released where they were, by their index:
    // their seeds are the run's seed's and the machine's (a tape has its own).
    const from_snapshot = [_][]const u8{ "--from-snapshot", "--branching", "--at-vtime-ms", "--exec", "--continue", "--seed" };
    const kept_from_snapshot = flag_value(argv, "--from-snapshot") != null;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ "/proc/self/exe", "explore" });
    assert(argv.len >= 2);
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        const flag: []const u8 = argv[index];
        const kept = kept_from_snapshot and contains(&from_snapshot, flag);
        if (contains(&with_value, flag) and !kept) {
            index += 1;
            continue;
        }
        if (contains(&alone, flag) and !kept) continue;
        try out.append(arena, flag);
        if (kept and contains(&with_value, flag)) {
            index += 1;
            try out.append(arena, argv[index]);
        }
    }
    // Its run's, so that it queues in its run's turn and counts by its run's claims (cpus.zig):
    // as a run of its own, each replay claimed its whole guest and had a turn to itself, and the
    // verifier's batch took 6 of the 7 VMs Vitess's run 2070 had memory for.
    if (run_key) |key| try out.appendSlice(arena, &.{ "--run-key", try std.fmt.allocPrint(arena, "{d}", .{key}) });
    return out.items; // /proc/self/exe: the explorer's binary, the build that ran.
}

/// The test program as the run started it, copied beside the tapes, for the replays: a program
/// rebuilt meanwhile (another `zig build`) is other inputs, and its replays would not boot the
/// timelines' system.
fn program_kept(
    arena: std.mem.Allocator,
    io: std.Io,
    base: []const []const u8,
    tapes: []const u8,
) ![]const []const u8 {
    const flag = for (base, 0..) |word, index| {
        if (std.mem.eql(u8, word, "--program") and index + 1 < base.len) break index;
    } else return base;
    const kept = try std.fs.path.join(arena, &.{ tapes, "program" });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, tapes);
    try cwd.copyFile(base[flag + 1], cwd, kept, io, .{});
    const out = try arena.dupe([]const u8, base);
    out[flag + 1] = kept;
    return out;
}

/// The system as the run booted it, for the replays: its pin beside the run's events (main.zig,
/// prepare.zig's), unless the run named one. Rebuilt instead, an image whose build is not
/// reproducible is another system, other inputs, and its replays refused their tapes
/// (run 1209: TapeInputsDiffer in three of three).
fn system_pinned(arena: std.mem.Allocator, io: std.Io, base: []const []const u8, argv: []const [:0]const u8) ![]const []const u8 {
    if (flag_value(argv, "--system") != null) return base;
    const events = flag_value(argv, "--events-dir") orelse return base;
    const pin = try std.fs.path.join(arena, &.{ events, "system.pin.json" });
    std.Io.Dir.cwd().access(io, pin, .{}) catch return base;
    return std.mem.concat(arena, []const u8, &.{ base, &.{ "--system", pin } });
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, word)) return true;
    return false;
}

/// Set by SIGUSR1: the run's timelines are all recorded.
var finishing: std.atomic.Value(bool) = .init(false);

fn finish_requested(_: linux.SIG) callconv(.c) void {
    finishing.store(true, .release);
}

/// What a replay needs: the explorer's arguments for it, the run's tapes, and the run's events
/// (`--events-dir`), to place where a replay parts from them.
const Replayer = struct {
    base: []const []const u8,
    tapes: []const u8,
    events: ?[]const u8,
    /// Futures from a saved machine (--from-snapshot, a session's fork): a timeline replays
    /// from it by its index (a tape replays from the setup's snapshot only).
    from_snapshot: bool,
};

fn verify_loop(
    io: std.Io,
    replayer: Replayer,
    record: []const u8,
    percent: u32,
    jobs: u32,
    results_path: []const u8,
) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var seen: std.AutoHashMapUnmanaged(u32, Pending) = .empty;
    var verified: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var replays: u32 = 0;
    while (replays < replays_max) {
        if (!finishing.load(.acquire)) sleep_ns(scan_interval_ns); // A signal ends the sleep.
        if (finishing.load(.acquire)) {
            // The run's budget is over and the queue's next hunt starts beside it: the replays
            // left take what it leaves (nice 19, inherited by every replay and its VM), not its
            // cores (run 442's 57 replays on CPUs 2-43 beside run 443, whose VMs waited for a
            // CPU over half their time). Not SCHED_IDLE: a hunt busy on every core would starve
            // them, and the run would never finish.
            _ = linux.syscall3(.setpriority, prio_process, 0, 19);
            const text = std.Io.Dir.cwd().readFileAlloc(io, record, arena, .unlimited) catch "";
            const share = rate(percent, results_now(arena, io, results_path));
            return finish_pending(arena, io, replayer, share, jobs, results_path, text, &verified, replays);
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, record, arena, .unlimited) catch continue;
        const share = rate(percent, results_now(arena, io, results_path));
        // Timelines recorded at the read before: their tapes are closed.
        var ready: std.ArrayList(Pending) = .empty;
        var it = seen.iterator();
        while (it.next()) |entry| {
            if (verified.contains(entry.key_ptr.*)) continue;
            ready.append(arena, entry.value_ptr.*) catch return;
        }
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
            const Line = struct { branch: struct { index: u32, events_hash: []const u8, guest_hash: []const u8 = "" } };
            const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (seen.contains(parsed.branch.index)) continue;
            if (!sampled(parsed.branch.index, share)) continue;
            seen.put(arena, parsed.branch.index, .{
                .index = parsed.branch.index,
                .hash = parsed.branch.events_hash,
                .guest = parsed.branch.guest_hash,
            }) catch return;
        }
        std.mem.sort(Pending, ready.items, {}, struct {
            fn less(_: void, a: Pending, b: Pending) bool {
                return a.index < b.index;
            }
        }.less);
        // Side by side, the run's share of its CPUs (`percent` of them): one at a time, a run's
        // 41 workers outran its replays (run 291 replayed 49 of the 181 sampled timelines).
        const batch = ready.items[0..@min(ready.items.len, replays_max - replays)];
        for (batch) |timeline| verified.put(arena, timeline.index, {}) catch return;
        replays += @intCast(batch.len);
        replay_batch(io, replayer, results_path, batch, @max(1, jobs * percent / 100));
    }
}

/// A timeline to replay: its recorded history's hash, and its guest's alone (before the host
/// checks' verdicts; "" in a record from before it was kept).
const Pending = struct { index: u32, hash: []const u8, guest: []const u8 = "" };

/// The share replayed now: `percent` until `confident_after` replays came back the same and none
/// differed, then a quarter of it (at least 1); all of them when asked for all.
fn rate(percent: u32, results: Results) u32 {
    if (percent >= 100) return percent; // All, as asked.
    if (results.first_different != null or results.same < confident_after) return percent;
    return @max(1, percent / 4);
}

test "the share replayed drops once replays agree, and comes back at a difference" {
    try std.testing.expectEqual(@as(u32, 20), rate(20, .{ .replayed = 29, .same = 29 }));
    try std.testing.expectEqual(@as(u32, 5), rate(20, .{ .replayed = 30, .same = 30 }));
    try std.testing.expectEqual(@as(u32, 20), rate(20, .{ .replayed = 40, .same = 39, .first_different = 7 }));
    try std.testing.expectEqual(@as(u32, 1), rate(2, .{ .replayed = 50, .same = 50 }));
    try std.testing.expectEqual(@as(u32, 100), rate(100, .{ .replayed = 50, .same = 50 }));
}

/// The run's results so far (none yet: empty).
fn results_now(arena: std.mem.Allocator, io: std.Io, results_path: []const u8) Results {
    const text = std.Io.Dir.cwd().readFileAlloc(io, results_path, arena, .unlimited) catch return .{};
    return results_parse(arena, text) catch .{};
}

/// Replays `all`, `workers` at a time.
fn replay_batch(io: std.Io, replayer: Replayer, results_path: []const u8, all: []const Pending, workers: u32) void {
    const Worker = struct {
        fn run(
            worker_io: std.Io,
            worker_replayer: Replayer,
            worker_results: []const u8,
            items: []const Pending,
            next: *std.atomic.Value(u32),
        ) void {
            while (true) {
                const at = next.fetchAdd(1, .monotonic);
                if (at >= items.len) return;
                const timeline = items[at];
                // Each its own arena: the workers run at once.
                var own: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                defer own.deinit();
                const start_ms = activity.now_ms();
                const line = replay_one(own.allocator(), worker_io, worker_replayer, timeline) catch |err|
                    std.fmt.allocPrint(own.allocator(), "{d} different {s} none {s}\n", .{ timeline.index, timeline.hash, @errorName(err) }) catch return;
                activity.interval(.verify, start_ms, activity.now_ms(), .{});
                append(worker_results, line);
            }
        }
    };
    var next: std.atomic.Value(u32) = .init(0);
    const count = @min(workers, all.len, finish_threads_max);
    var threads: [finish_threads_max]std.Thread = undefined;
    var started: usize = 0;
    for (0..count) |_| {
        threads[started] = std.Thread.spawn(.{}, Worker.run, .{ io, replayer, results_path, all, &next }) catch break;
        started += 1;
    }
    // None started (no threads to be had): this one does them all.
    if (started == 0) Worker.run(io, replayer, results_path, all, &next);
    for (threads[0..started]) |thread| thread.join();
}

/// The run is done, its tapes closed: every sampled timeline not replayed yet (within
/// replays_max), up to `jobs` at once.
fn finish_pending(
    arena: std.mem.Allocator,
    io: std.Io,
    replayer: Replayer,
    percent: u32,
    jobs: u32,
    results_path: []const u8,
    text: []const u8,
    verified: *const std.AutoHashMapUnmanaged(u32, void),
    replays: u32,
) void {
    var pending: std.ArrayList(Pending) = .empty;
    // Each failing property's first failing timeline, sampled or not.
    var examples: std.StringHashMapUnmanaged(Pending) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const Line = struct { branch: struct { index: u32, events_hash: []const u8, guest_hash: []const u8 = "", failing: []const []const u8 = &.{} } };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const timeline: Pending = .{ .index = parsed.branch.index, .hash = parsed.branch.events_hash, .guest = parsed.branch.guest_hash };
        for (parsed.branch.failing) |property| {
            const entry = examples.getOrPut(arena, property) catch return;
            if (!entry.found_existing or timeline.index < entry.value_ptr.index) entry.value_ptr.* = timeline;
        }
        if (!sampled(parsed.branch.index, percent)) continue;
        if (verified.contains(parsed.branch.index)) continue;
        if (replays + pending.items.len == replays_max) continue;
        pending.append(arena, timeline) catch return;
    }
    var example_it = examples.valueIterator();
    while (example_it.next()) |example| {
        if (verified.contains(example.index)) continue;
        const known = for (pending.items) |other| {
            if (other.index == example.index) break true;
        } else false;
        if (!known) pending.append(arena, example.*) catch return;
    }
    var of_buffer: [32]u8 = undefined;
    append(results_path, std.fmt.bufPrint(&of_buffer, "of {d}\n", .{verified.count() + pending.items.len}) catch unreachable);
    replay_batch(io, replayer, results_path, pending.items, @max(jobs, 1));
}

/// Whether a timeline is among the `percent` replayed: by a hash of its index (SplitMix64's
/// finalizer), spread over the run whatever the tree's shape.
fn sampled(index: u32, percent: u32) bool {
    var value = @as(u64, index) +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    value ^= value >> 31;
    return value % 100 < percent;
}

test sampled {
    var count: u32 = 0;
    for (0..10_000) |index| count += @intFromBool(sampled(@intCast(index), 20));
    try std.testing.expect(count > 1_800 and count < 2_200);
    for (0..100) |index| try std.testing.expect(sampled(@intCast(index), 100));
}

fn replay_one(
    arena: std.mem.Allocator,
    io: std.Io,
    replayer: Replayer,
    timeline: Pending,
) ![]const u8 {
    const index = timeline.index;
    const recorded = timeline.hash;
    const tapes = replayer.tapes;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, replayer.base);
    if (replayer.from_snapshot) {
        try argv.appendSlice(arena, &.{ "--branch", try std.fmt.allocPrint(arena, "{d}", .{index}) });
    } else {
        try argv.appendSlice(arena, &.{ "--tape", try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index }) });
    }
    // Its events beside the tapes, while the run has its own to compare them with: kept when it
    // parts from the run, as the evidence.
    const replay_events: ?[]const u8 = if (replayer.events != null)
        try std.fmt.allocPrint(arena, "{s}/replay-{d}-events", .{ tapes, index })
    else
        null;
    if (replay_events) |directory| try argv.appendSlice(arena, &.{ "--events-dir", directory });
    const output_path = try std.fmt.allocPrint(arena, "{s}/replay-{d}.out", .{ tapes, index });
    const result = try run_to_file(arena, io, argv.items, output_path);
    var replayed: []const u8 = "none";
    var replayed_guest: []const u8 = "";
    var why: []const u8 = "";
    var hazards: []const u8 = "";
    var other_build = false;
    var lines = std.mem.tokenizeScalar(u8, result.output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[branch ")) {
            replayed = word_after(line, "events_hash=") orelse continue;
            replayed_guest = word_after(line, "guest_hash=") orelse "";
        } else if (std.mem.indexOf(u8, line, "replay diverged from its tape")) |at| {
            why = line[at..];
        } else if (std.mem.indexOf(u8, line, "its clock's hazards: ")) |at| {
            hazards = line[at..];
        } else if (std.mem.indexOf(u8, line, "recorded by another build of determinismo") != null) {
            other_build = true;
        }
    }
    if (std.mem.eql(u8, replayed, recorded) and why.len == 0) {
        if (replay_events) |directory| std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        return std.fmt.allocPrint(arena, "{d} same {s}\n", .{ index, recorded });
    }
    // The guest's history the same, the host checks' verdicts not: judged by another version of
    // a checker (a deploy replaced the Elle service mid-run: run 1482), or by one that is not
    // deterministic. The platform replayed it exactly; said apart, never as parting.
    if (why.len == 0 and timeline.guest.len > 0 and std.mem.eql(u8, replayed_guest, timeline.guest)) {
        if (replay_events) |directory| std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        return std.fmt.allocPrint(arena, "{d} rejudged {s} {s} the guest's history the same, the host " ++
            "checks' verdicts not (another checker version, or one not deterministic)\n", .{ index, recorded, replayed });
    }
    // Killed (SIGKILL: the host's OOM killer) before it ended: not replayed, which says nothing
    // about determinism.
    const killed = switch (result.term) {
        .signal => |signal| signal == .KILL,
        else => false,
    };
    if (killed and std.mem.eql(u8, replayed, "none") and why.len == 0) {
        return std.fmt.allocPrint(arena, "{d} killed {s}\n", .{ index, recorded });
    }
    // Ended without a history and without parting from its tape: it could not run (a host
    // check's container, the host itself), which says nothing about determinism either.
    if (std.mem.eql(u8, replayed, "none") and why.len == 0) {
        const log = try std.fmt.allocPrint(arena, "{s}/replay-{d}.log", .{ tapes, index });
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = tail(result.output, 256 << 10) }) catch {};
        return std.fmt.allocPrint(arena, "{d} failed {s}\n", .{ index, recorded });
    }
    // Its output beside the results (the last 256 KiB): where it parted, on what CPU, its
    // clock's hazards, without replaying it again.
    const log = try std.fmt.allocPrint(arena, "{s}/replay-{d}.log", .{ tapes, index });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = tail(result.output, 256 << 10) }) catch {};
    const parted = if (replay_events) |directory| parting(arena, io, replayer.events.?, directory, index) else "";
    return std.fmt.allocPrint(arena, "{d} different {s} {s} {s}{s}{s}{s}{s}\n", .{
        index,                                                                  recorded, replayed, why, if (hazards.len > 0) "; " else "", hazards, parted,
        if (other_build) "; recorded by another build of determinismo" else "",
    });
}

/// The word after `key` in a line ("events_hash=<hex> ..."), or null.
fn word_after(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const start = at + key.len;
    return line[start .. std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len];
}

test word_after {
    const line = "[branch    3] seed=ab ended events=9 events_hash=00ff guest_hash=00ee failing=0";
    try std.testing.expectEqualStrings("00ff", word_after(line, "events_hash=").?);
    try std.testing.expectEqualStrings("00ee", word_after(line, "guest_hash=").?);
    try std.testing.expectEqual(null, word_after("[branch 1] events_hash=1", "guest_hash="));
}

/// Where a replay's events part from the run's (timeline `index`'s in each events directory): the
/// last checkpoint both passed (one per second of virtual time, Events.checkpoint) and the first
/// line that differs on each side; "" when either cannot be read or they do not differ.
pub fn parting(arena: std.mem.Allocator, io: std.Io, recorded_directory: []const u8, replayed_directory: []const u8, index: u32) []const u8 {
    const limit: std.Io.Limit = .limited(1 << 30);
    const recorded = event_files.read(arena, io, recorded_directory, index, limit) catch return "";
    const replayed = event_files.read(arena, io, replayed_directory, index, limit) catch return "";
    return parting_text(arena, recorded, replayed);
}

fn parting_text(arena: std.mem.Allocator, recorded: []const u8, replayed: []const u8) []const u8 {
    var recorded_lines = std.mem.tokenizeScalar(u8, recorded, '\n');
    var replayed_lines = std.mem.tokenizeScalar(u8, replayed, '\n');
    var passed: ?u64 = null; // The last checkpoint both passed, its virtual time.
    while (true) {
        const a = recorded_lines.next();
        const b = replayed_lines.next();
        if (a == null and b == null) return "";
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) {
            if (std.mem.startsWith(u8, a.?, "{\"checkpoint\":")) passed = number_after(a.?, "\"vtime_ns\":");
            continue;
        }
        const after = if (passed) |ns|
            std.fmt.allocPrint(arena, "the checkpoint at {f}", .{seconds(ns)}) catch return ""
        else
            "no checkpoint";
        return std.fmt.allocPrint(arena, "; parted after {s}: recorded {s}, replayed {s}", .{
            after, place(arena, a), place(arena, b),
        }) catch "";
    }
}

/// A line's place: "seq <n> at <t> s", "a checkpoint at <t> s", or "nothing" (its file ended).
fn place(arena: std.mem.Allocator, line: ?[]const u8) []const u8 {
    const text = line orelse return "nothing";
    const vtime_ns = number_after(text, "\"vtime_ns\":") orelse return "an unreadable line";
    if (std.mem.startsWith(u8, text, "{\"checkpoint\":")) {
        return std.fmt.allocPrint(arena, "a checkpoint at {f}", .{seconds(vtime_ns)}) catch "";
    }
    const seq = number_after(text, "\"seq\":") orelse 0;
    return std.fmt.allocPrint(arena, "seq {d} at {f}", .{ seq, seconds(vtime_ns) }) catch "";
}

fn number_after(text: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const start = at + key.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[start..end], 10) catch null;
}

/// Virtual time to the microsecond, for a person: "94.852498 s".
const Seconds = struct {
    ns: u64,
    pub fn format(value: Seconds, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d:0>6} s", .{ value.ns / std.time.ns_per_s, value.ns % std.time.ns_per_s / std.time.ns_per_us });
    }
};

fn seconds(ns: u64) Seconds {
    return .{ .ns = ns };
}

/// The value after `flag` in an argument list, if it is there.
fn flag_value(argv: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (argv, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, flag) and index + 1 < argv.len) return argv[index + 1];
    }
    return null;
}

test parting_text {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const recorded =
        \\{"seq":1,"vtime_ns":500,"branches":7,"event":{"event":"a"}}
        \\{"checkpoint":{"vtime_ns":1000000123,"branches":9}}
        \\{"seq":2,"vtime_ns":94852498828,"branches":13274724501,"event":{"event":"b"}}
    ;
    const replayed =
        \\{"seq":1,"vtime_ns":500,"branches":7,"event":{"event":"a"}}
        \\{"checkpoint":{"vtime_ns":1000000123,"branches":9}}
        \\{"seq":2,"vtime_ns":94852499537,"branches":13274690239,"event":{"event":"b"}}
    ;
    try std.testing.expectEqualStrings(
        "; parted after the checkpoint at 1.000000 s: recorded seq 2 at 94.852498 s, replayed seq 2 at 94.852499 s",
        parting_text(arena.allocator(), recorded, replayed),
    );
    try std.testing.expectEqualStrings("", parting_text(arena.allocator(), recorded, recorded));
    try std.testing.expectEqualStrings(
        "; parted after no checkpoint: recorded seq 1 at 0.000000 s, replayed nothing",
        parting_text(arena.allocator(), recorded, ""),
    );
}

/// The last `size_max` bytes of `bytes` (all of them when shorter).
/// A replay run to its process's end: its output (both streams) into `output_path`, read back
/// once it exited, then removed; its process group (its own) killed after it. Not until its
/// pipes close: anything it started that kept them (a host check's daemon) kept the verifier
/// waiting on its replays for good, and the explorer on the verifier (the e2e coverage check's
/// Python maze, 2026-11-09: 25 minutes, killed by hand).
const RunToFile = struct { term: std.process.Child.Term, output: []const u8 };

fn run_to_file(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, output_path: []const u8) !RunToFile {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, output_path, .{ .truncate = true });
    defer cwd.deleteFile(io, output_path) catch {};
    var child = child: {
        defer file.close(io);
        break :child try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
            .pgid = 0,
        });
    };
    const pid = child.id.?;
    const term = try child.wait(io);
    _ = linux.kill(-pid, .KILL); // What it left of its group.
    const output = try cwd.readFileAlloc(io, output_path, arena, .limited(128 << 20));
    return .{ .term = term, .output = output };
}

test run_to_file {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/replay-1.out", .{&tmp.sub_path});
    // A replay that leaves a process holding its output open (a host check's daemon): its end
    // is its own exit, not the minute the other holds it.
    const start_ns = monotonic_ns();
    const result = try run_to_file(arena, io, &.{ "sh", "-c", "sleep 60 & echo '[branch 1] events_hash=ab'; echo err >&2" }, path);
    try std.testing.expect(monotonic_ns() - start_ns < 10 * std.time.ns_per_s);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "events_hash=ab") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "err") != null);
    // The file is gone once read.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}

fn tail(bytes: []const u8, size_max: usize) []const u8 {
    return bytes[bytes.len -| size_max..];
}

test tail {
    try std.testing.expectEqualStrings("cd", tail("abcd", 2));
    try std.testing.expectEqualStrings("abcd", tail("abcd", 256 << 10));
    try std.testing.expectEqualStrings("", tail("", 4));
}

fn append(path: []const u8, line: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buffer.len) return;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path_buffer[0..path.len :0], flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_ns(ns: u64) void {
    const duration: linux.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.nanosleep(&duration, null);
}

test results_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "15 same ab\n31 different ab cd diverged\nof 7\n47 same ef\n63 killed gh\n79 failed ij\n" ++
        "95 rejudged kl mn the guest's history the same\n";
    const results = try results_parse(arena.allocator(), text);
    try std.testing.expectEqual(4, results.replayed);
    try std.testing.expectEqual(3, results.same);
    try std.testing.expectEqual(1, results.rejudged);
    try std.testing.expectEqual(31, results.first_different.?);
    try std.testing.expectEqual(2, results.different.len);
    // How far: every line's turn over (killed and failed too), of the count said.
    try std.testing.expectEqual(Progress{ .replayed = 6, .of = 7 }, progress_parse(text));
    try std.testing.expectEqual(Progress{ .replayed = 1, .of = null }, progress_parse("15 same ab\n"));
}

test replay_argv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "determinismo", "explore", "--kernel", "k", "--branches", "64", "--resume", "--program", "p", "--record", "r" };
    const out = try replay_argv(arena.allocator(), &argv, null);
    try std.testing.expectEqual(6, out.len);
    try std.testing.expectEqualStrings("--kernel", out[2]);
    try std.testing.expectEqualStrings("p", out[5]);
    // A session's fork's futures: replayed from their machine, with the run's seed.
    const futures = [_][:0]const u8{ "determinismo", "explore", "--seed", "7", "--from-snapshot", "s", "--fork-futures", "--branching", "flat", "--at-vtime-ms", "9", "--exec", "det:release", "--continue", "--record", "r", "--branches", "3" };
    const kept = try replay_argv(arena.allocator(), &futures, null);
    try std.testing.expectEqual(14, kept.len);
    try std.testing.expectEqualStrings("7", kept[3]);
    try std.testing.expectEqualStrings("--continue", kept[13]);
}

test "a verify replay names its run, so it queues in its run's turn and counts by its claims" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "determinismo", "explore", "--program", "p", "--jobs", "40", "--run-key", "7" };
    const out = try replay_argv(arena.allocator(), &argv, 4242);
    var named: ?[]const u8 = null;
    for (out, 0..) |flag, index| {
        if (std.mem.eql(u8, flag, "--run-key") and index + 1 < out.len) named = out[index + 1];
    }
    // The explorer's run (the verifier's: forked from it), once, not the one it was given.
    try std.testing.expectEqualStrings("4242", named orelse "");
    var count: usize = 0;
    for (out) |flag| count += @intFromBool(std.mem.eql(u8, flag, "--run-key"));
    try std.testing.expectEqual(@as(usize, 1), count);
}

test system_pinned {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const events = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const events_z = try arena.allocator().dupeSentinel(u8, events, 0);
    const base = [_][]const u8{ "/proc/self/exe", "explore", "--program", "p" };
    const argv = [_][:0]const u8{ "determinismo", "explore", "--program", "p", "--events-dir", events_z };
    // No pin beside the events: the replays build the system as the run did.
    try std.testing.expectEqual(base.len, (try system_pinned(arena.allocator(), io, &base, &argv)).len);
    try tmp.dir.writeFile(io, .{ .sub_path = "system.pin.json", .data = "{}" });
    const pinned = try system_pinned(arena.allocator(), io, &base, &argv);
    try std.testing.expectEqual(base.len + 2, pinned.len);
    try std.testing.expectEqualStrings("--system", pinned[base.len]);
    try std.testing.expect(std.mem.endsWith(u8, pinned[base.len + 1], "/system.pin.json"));
    // A run that named its system: kept as it is (replay_argv keeps the flag).
    const named = [_][:0]const u8{ "determinismo", "explore", "--system", "s.pin.json", "--events-dir", events_z };
    try std.testing.expectEqual(base.len, (try system_pinned(arena.allocator(), io, &base, &named)).len);
}
