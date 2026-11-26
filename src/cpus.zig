// SPDX-License-Identifier: MIT
//! The host's CPUs, shared by every run on it: a process holds a CPU while it runs a VM (a
//! timeline, a tree node's replay), pinned to it, and gives it back after. Any number of runs
//! then share the host with never two VMs on one CPU, and a lone run takes them all.
//!
//! A CPU is a lock on a file of its own (flock), named by the CPU's number, in a directory of
//! the user's: every process agrees on the CPUs, and the kernel gives a CPU back when its holder
//! dies. Locks belong to an open file, so each process opens the pool itself (never inherited).
//!
//! One VM per core by default; with `DETERMINISMO_SMT=1` (serve.sh's `--siblings on`) the second
//! hyperthreads too, once every core's first is busy: a VM alone on a core is fastest (with a
//! busy sibling, about 0.7x), and a busy core does about 1.4x. Not the default: twice the VMs
//! outgrew memory admission, which claims each VM's guest but not its in-run snapshots and
//! holders (a Dgraph hunt, 53 timelines killed by the OOM killer, srv3 2026-10-28). Siblings were left out when Kafka timelines diverged within seconds with two VMs on
//! one core (srv1, 2026-10-27), thought to perturb each other's branch counters; the divergences
//! were the guest kernel's, which branched on TLB state that a sibling's VM perturbs most (guest
//! patches 0001, 0002 and 0004: 150-branch spurious faults). With them, VMs on both hyperthreads
//! of two cores replayed YugabyteDB (39 s, 382 s) and Kafka timelines (three) exactly, 20
//! replays of 20 (srv3, 2026-10-28). But the first hunt with them (Kafka, run 55, srv3,
//! 2026-10-28: 32 VMs on 16 cores) replayed 7 of the 9 timelines it checked exactly, two
//! diverging with no clock hazard, while runs without them replayed 33 of 33: off, until what
//! a sibling still perturbs is found. With one thread per core, the pool holds each core's first;
//! a second only when the first is not this process's to run on (an affinity mask that leaves it
//! out).
//!
//! A process with `DETERMINISMO_CPU_PRIORITY` set (checks, e.g. `zig build e2e`) goes first: while
//! one waits it holds a shared lock on the `priority-<cpu>` file of each CPU it may run on, and
//! the others leave those CPUs to it when they come free. Only those: a check confined to cores
//! of its own (a host's reserved cores, infra/host/serve.sh) never holds back a hunt on the rest.
//!
//! The memory a VM claims counts on the whole host, whatever CPUs a process may run on: a hunt
//! and a check on cores of their own still share one memory.
//!
//! Runs share the host: one process of a run waits for a CPU at a time (the others queue on the
//! run's `run-<key>.turn` lock), and the waiting runs are served at random (each tries again after
//! a random 10 to 30 ms, its first try included). Every run that wants CPUs then gets them
//! equally often, however many processes it has; a lone run takes them all. (With exponential
//! backoff, a run's next timeline, forked as its last one gave a CPU back, took that CPU every
//! time while other runs' waiters slept 100 ms; and served at random, runs got CPUs in
//! proportion to their waiting processes: one run with 300 held most of the host.)
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;

const cpus_max = 1024;
const wait_ns_min = 10 * std.time.ns_per_ms;
const wait_ns_max = 30 * std.time.ns_per_ms;
/// A session waiting for memory says so after this long, and again every `memory_say_every_ns`:
/// replays through serve beside a YugabyteDB hunt waited 30 minutes and said nothing.
const memory_say_after_ns = 30 * std.time.ns_per_s;
const memory_say_every_ns = 5 * 60 * std.time.ns_per_s;

/// The run this process belongs to: set by a run's first process before it forks the others
/// (they inherit it); a process outside any run is a run of its own.
pub var run_key: ?linux.pid_t = null;

/// Whether `key` is one of this process's ancestors (its parent, its parent's, ...): a run's key
/// named on a command line is taken only from the run's own explorer.
pub fn is_ancestor(key: linux.pid_t) bool {
    if (key <= 1) return false;
    var pid: linux.pid_t = linux.getppid();
    var hops: u32 = 0;
    while (pid > 1 and hops < 64) : (hops += 1) {
        if (pid == key) return true;
        pid = parent_of(pid) orelse return false;
    }
    return false;
}

/// A process's parent, from /proc/<pid>/stat (the field after its state).
fn parent_of(pid: linux.pid_t) ?linux.pid_t {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return null;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [512]u8 = undefined;
    const size = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const stat = buffer[0..size];
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // Its state.
    return std.fmt.parseInt(linux.pid_t, fields.next() orelse return null, 10) catch null;
}

test is_ancestor {
    try std.testing.expect(is_ancestor(linux.getppid()));
    try std.testing.expect(!is_ancestor(linux.getpid())); // Itself: not an ancestor.
    try std.testing.expect(!is_ancestor(1)); // Everyone's: never a run's.
    try std.testing.expect(!is_ancestor(0));
    // A child of this process: alive, and not an ancestor.
    const pid = linux.fork();
    if (pid == 0) {
        const pause: linux.timespec = .{ .sec = 5, .nsec = 0 };
        _ = linux.nanosleep(&pause, null);
        linux.exit_group(0);
    }
    defer {
        _ = linux.kill(@intCast(pid), .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(@intCast(pid), &status, 0);
    }
    try std.testing.expect(!is_ancestor(@intCast(pid)));
}

/// A verify replay's run (`--run-key`, its explorer's pid): taken only while the explorer is one
/// of this process's ancestors, and then this process dies with the verifier's thread that
/// started it. The explorer stops its verifier's process group at the budget's grace and dies
/// with a stopped run, and each replay is a process group of its own (replays.zig run_to_file):
/// Vitess's trial run 2072 (2026-11-18) left a replay running minutes after it ended, a CPU and
/// its 16 GiB claim beside the next run's first VMs. Asked for before the ancestors are read: a
/// verifier gone between the two leaves this process reparented, and the key refused.
pub fn run_key_take(key: linux.pid_t) bool {
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    if (is_ancestor(key)) return true;
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), 0, 0, 0, 0);
    return false;
}

test "a verify replay that took its run's key dies with the verifier that started it" {
    // This process is the run's explorer, its child the verifier, the child's child the replay.
    const explorer = linux.getpid();
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds[0]);
    const verifier = linux.fork();
    if (verifier == 0) {
        const replay = linux.fork();
        if (replay == 0) {
            const pid: i32 = linux.getpid();
            var said: [5]u8 = undefined;
            said[0] = @intFromBool(run_key_take(explorer));
            @memcpy(said[1..], std.mem.asBytes(&pid));
            _ = linux.write(fds[1], &said, said.len);
            const pause: linux.timespec = .{ .sec = 30, .nsec = 0 };
            _ = linux.nanosleep(&pause, null);
            linux.exit_group(0);
        }
        const pause: linux.timespec = .{ .sec = 30, .nsec = 0 };
        _ = linux.nanosleep(&pause, null);
        linux.exit_group(0);
    }
    _ = linux.close(fds[1]);
    var said: [5]u8 = undefined;
    var read: usize = 0;
    while (read < said.len) {
        const size = linux.read(fds[0], said[read..].ptr, said.len - read);
        if (linux.errno(size) == .INTR) continue;
        try std.testing.expect(linux.errno(size) == .SUCCESS and size > 0);
        read += size;
    }
    const replay = std.mem.bytesToValue(i32, said[1..5]);
    defer _ = linux.kill(replay, .KILL); // Survived: not left running after the test.
    try std.testing.expectEqual(@as(u8, 1), said[0]);
    // The verifier stopped (the budget's grace over, or the explorer gone): the replay with it.
    _ = linux.kill(@intCast(verifier), .KILL);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(verifier), &status, 0);
    var waited_ms: u32 = 0;
    while (alive(replay) and waited_ms < 3000) : (waited_ms += 10) {
        const step: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&step, null);
    }
    try std.testing.expect(!alive(replay));
}

/// Whether `pid` runs: there and not a zombie.
fn alive(pid: linux.pid_t) bool {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return false;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [512]u8 = undefined;
    const size = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    const stat = buffer[0..size];
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    return close + 2 < stat.len and stat[close + 2] != 'Z' and stat[close + 2] != 'X';
}

/// The memory this process's VMs may come to use (their guest's size), claimed with the CPU it
/// takes: set once at its start, forks inherit it. 0: none claimed.
pub var claim_bytes: u64 = 0;

/// A CPU's lock file's content while a deterministic VM holds it: the VM's claim (its guest's
/// size) and its run. A build before the run was written leaves its claim alone: read whole.
/// A held CPU's claim: `bytes` its process's VM claims, `run` the run it is of, `shares` 1 where
/// that VM branches from a snapshot its run holds (claim_shares): only such a VM counts as what
/// its run learned they hold (claim_soft).
const CpuClaim = extern struct { bytes: u64 = 0, run: u64 = 0, shares: u64 = 0 };

/// This process's VMs branch from a snapshot their run holds (a tree's workers, its holders and
/// node makers: the explorer sets it before they fork), their memory beyond what they write the
/// snapshot's, counted once as the run's nodes: they may claim what the run learned they hold
/// (claim_soft). A VM that holds its whole memory itself (a fresh boot, a replay of the run's
/// verifier, its own process) claims its guest's size: ParadeDB's run 2096 admitted a
/// verification replay at the 16.4 GiB its branches were learned to hold, and the replay's
/// guest, booted afresh, took 39 GiB of shared memory in 5 minutes, MemAvailable down to 3 GiB
/// (2026-11-20 06:40) while its branches held 5 GiB in all.
pub var claim_shares: bool = false;

/// Where a run's turn file keeps what the run learned its VMs come to hold (Pool.claim_soft),
/// after its TurnMemory.
const claim_soft_offset = @sizeOf(TurnMemory);

/// Other runs' learned claims (their turn files' claim_soft), each read once in a look.
const RunSofts = struct {
    runs: [16]u64 = undefined,
    softs: [16]u64 = undefined,
    count: u32 = 0,

    /// What `run` learned its VMs hold, 0 when it has not (or its turn file is gone: its run
    /// ended, and its claims count at their guests' size).
    fn of(cache: *RunSofts, directory: []const u8, run: u64) u64 {
        for (cache.runs[0..cache.count], cache.softs[0..cache.count]) |known, soft| {
            if (known == run) return soft;
        }
        const soft = turn_soft(directory, run);
        if (cache.count < cache.runs.len) {
            cache.runs[cache.count] = run;
            cache.softs[cache.count] = soft;
            cache.count += 1;
        }
        return soft;
    }
};

/// A run's learned claim from its turn file (Pool.claim_soft_set), 0 when there is none.
fn turn_soft(directory: []const u8, run: u64) u64 {
    if (directory.len == 0) return 0;
    var path_buffer: [160]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/run-{d}.turn", .{ directory, run }, 0) catch return 0;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var bytes: [8]u8 = @splat(0);
    if (linux.pread(fd, &bytes, bytes.len, claim_soft_offset) != bytes.len) return 0;
    return std.mem.bytesToValue(u64, &bytes);
}

fn run_of_this_process() u64 {
    return @intCast(run_key orelse linux.getpid());
}

/// How many fast machines one CPU holds, unless told (serve's `--machines-per-cpu`, given to each
/// machine it starts): a fast VM (`run` with several vCPUs: a sandbox, a CI job's setup) is
/// never deterministic, so several share a CPU among themselves (Pool.take_shared), most of
/// them idle most of the time; with each holding a CPU of its own for its life, a host's
/// machines alive at once were its CPUs (three sandboxes on three). Never with a deterministic
/// VM: its CPU is its own (Pool.take), as before.
pub const machines_per_cpu_default = 4;
pub var machines_per_cpu: u32 = machines_per_cpu_default;

/// The CPUs this process was given: its affinity before a pin narrowed it to the one CPU it
/// held. Its pool, its count of usable CPUs and a CPU given back go by it, never by the pinned
/// affinity: an explorer pinned while it booted and set up once counted one usable CPU (every
/// run without --jobs ran one timeline at a time, 2026-10-27), and the timelines it forked
/// opened pools of that one CPU. Read before the first pin; forks inherit it.
var given_mask: ?linux.cpu_set_t = null;

fn given() linux.cpu_set_t {
    if (given_mask) |mask| return mask;
    var mask: linux.cpu_set_t = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask)) != .SUCCESS) {
        mask = @splat(~@as(@TypeOf(mask[0]), 0));
    }
    given_mask = mask;
    return mask;
}

pub const Pool = struct {
    /// The CPUs this process may run on, their lock files, and their `priority-<cpu>` files
    /// (shared-locked by priority processes while they wait).
    cpus: [cpus_max]u16 = undefined,
    fds: [cpus_max]linux.fd_t = undefined,
    priority_fds: [cpus_max]linux.fd_t = undefined,
    count: u32 = 0,
    /// Every CPU of the host's lock file, for the memory claimed on them (claim_fits).
    host_fds: [cpus_max]linux.fd_t = undefined,
    host_count: u32 = 0,
    /// The run's turn to wait: one of its processes at a time holds it. Its file also keeps what
    /// the run learned its VMs hold (claim_soft).
    turn_fd: linux.fd_t = -1,
    /// The turn of the run's VMs that hold their whole memory (its verifier's replays, a fresh
    /// boot: not claim_shares), a queue of their own: one waiting for room for its guest held
    /// the run's turn, every branch behind it though they fit (ParadeDB's run 2098, 13:55 to
    /// 14:10: 3 replays of 32 GiB queued, its 40 timelines waiting at 0 s with claims and memory
    /// to spare, 4 timelines in 15 minutes).
    whole_fd: linux.fd_t = -1,
    priority: bool = false,
    /// The CPU side of `priority` alone: past the run's turn, tried at once, the others leaving
    /// it the next CPU; not the sessions' memory room. A tree judgment's node makers (main.zig,
    /// holders.zig): the generation's branches wait for every node, while one replay maker
    /// waited 396 of its 438 s for a CPU behind its own run's 40 timelines (Pulsar 1931).
    first: bool = false,
    /// Whether a claim must also find its memory available now (tests of the claims' own
    /// accounting turn it off: beside a hunt, half the host is never available).
    available_counts: bool = true,
    /// The pool's directory (its CPU, priority and nodes files).
    directory_buffer: [64]u8 = undefined,
    directory_size: usize = 0,

    /// Opens the pool of the CPUs this process may run on.
    pub fn open(pool: *Pool) !void {
        pool.* = .{};
        const available = given();
        var directory_buffer: [64]u8 = undefined;
        // Unit tests have a pool of their own: the host's runs' claims and locks are not theirs
        // (a test's claim of half the host never fit beside a hunt's, and waited forever).
        const directory = if (builtin.is_test)
            try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-test-{d}", .{linux.getpid()}, 0)
        else
            try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-{d}", .{linux.getuid()}, 0);
        const made = linux.mkdir(directory, 0o700);
        if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return error.PoolDirectory;
        @memcpy(pool.directory_buffer[0..directory.len], directory);
        pool.directory_size = directory.len;
        errdefer pool.close();
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
        const bits = @bitSizeOf(@TypeOf(available[0]));
        for (0..available.len * bits) |cpu| {
            if (!usable(&available, cpu)) continue;
            if (pool.count == cpus_max) break;
            pool.cpus[pool.count] = @intCast(cpu);
            pool.fds[pool.count] = try pool_file(directory, "cpu", cpu);
            pool.priority_fds[pool.count] = pool_file(directory, "priority", cpu) catch |err| {
                _ = linux.close(pool.fds[pool.count]);
                return err;
            };
            pool.count += 1;
        }
        if (pool.count == 0) return error.NoCpus;
        for (0..@min(host_cpu_count(), cpus_max)) |cpu| {
            pool.host_fds[pool.host_count] = try pool_file(directory, "cpu", cpu);
            pool.host_count += 1;
        }
        pool.priority = std.c.getenv("DETERMINISMO_CPU_PRIORITY") != null;
        var turn_buffer: [96]u8 = undefined;
        const turn_path = try std.fmt.bufPrintSentinel(&turn_buffer, "{s}/run-{d}.turn", .{
            directory, run_key orelse linux.getpid(),
        }, 0);
        const turn_fd = linux.open(turn_path, flags, 0o600);
        if (linux.errno(turn_fd) != .SUCCESS) return error.PoolFile;
        const whole_path = try std.fmt.bufPrintSentinel(&turn_buffer, "{s}/run-{d}.whole", .{
            directory, run_key orelse linux.getpid(),
        }, 0);
        const whole_fd = linux.open(whole_path, flags, 0o600);
        if (linux.errno(whole_fd) != .SUCCESS) {
            _ = linux.close(@intCast(turn_fd));
            return error.PoolFile;
        }
        pool.whole_fd = @intCast(whole_fd);
        // A run's explorer clears the turns of runs gone (its own process is the key).
        if ((run_key orelse linux.getpid()) == linux.getpid()) _ = turns_sweep(directory);
        pool.turn_fd = @intCast(turn_fd);
        // Each core's first thread, then the siblings (stable: by number within each).
        var order: [cpus_max]u32 = undefined;
        for (order[0..pool.count], 0..) |*slot, index| slot.* = @intCast(index);
        std.sort.insertion(u32, order[0..pool.count], pool, sibling_after);
        const cpus = pool.cpus;
        const fds = pool.fds;
        const priority_fds = pool.priority_fds;
        for (order[0..pool.count], 0..) |from, to| {
            pool.cpus[to] = cpus[from];
            pool.fds[to] = fds[from];
            pool.priority_fds[to] = priority_fds[from];
        }
    }

    fn sibling_after(pool: *const Pool, a: u32, b: u32) bool {
        const a_sibling = sibling(pool.cpus[a]);
        const b_sibling = sibling(pool.cpus[b]);
        if (a_sibling != b_sibling) return !a_sibling;
        return pool.cpus[a] < pool.cpus[b];
    }

    pub fn close(pool: *Pool) void {
        for (pool.fds[0..pool.count]) |fd| _ = linux.close(fd);
        for (pool.priority_fds[0..pool.count]) |fd| _ = linux.close(fd);
        for (pool.host_fds[0..pool.host_count]) |fd| _ = linux.close(fd);
        if (pool.turn_fd >= 0) _ = linux.close(pool.turn_fd);
        if (pool.whole_fd >= 0) _ = linux.close(pool.whole_fd);
        pool.count = 0;
        pool.host_count = 0;
    }

    /// Takes a free CPU (the first, physical cores first), waiting while none is, and pins this
    /// process to it.
    pub fn take(pool: *Pool) Held {
        return pool.take_unless(never).?;
    }

    fn never() bool {
        return false;
    }

    /// As take, but null as soon as `give_up` says so while it waits (its turn among the run's
    /// processes, memory, a CPU): a timeline whose run drained meanwhile runs nothing.
    pub fn take_unless(pool: *Pool, give_up: *const fn () bool) ?Held {
        assert(pool.count > 0);
        const asked_ns = monotonic_ns();
        const cpu_first = pool.priority or pool.first;
        // Waiting with priority: the others see it, and leave the CPUs it may run on to it.
        if (cpu_first) for (pool.priority_fds[0..pool.count]) |fd| {
            _ = linux.flock(fd, std.posix.LOCK.SH);
        };
        defer if (cpu_first) for (pool.priority_fds[0..pool.count]) |fd| {
            _ = linux.flock(fd, std.posix.LOCK.UN);
        };
        // The run's turn: its other processes queue behind this one (in the kernel, asleep).
        // What its holders waited for memory meanwhile is this one's memory wait too: a run
        // whose VMs did not fit queued behind its one waiter, and booked it all as a CPU's (run
        // 2060, Kafka's 8 GB guests on 40 workers: 40,472 s of CPU wait, 2,112 of memory, with
        // most of the host's CPUs idle).
        var memory_wait_ns: u64 = 0;
        var turn: TurnMemory = .{};
        const queue = pool.queue_for(claim_shares);
        if (!cpu_first) {
            const queued_at = TurnMemory.read(queue).at(asked_ns);
            while (linux.errno(linux.flock(queue, std.posix.LOCK.EX)) == .INTR) {}
            turn = TurnMemory.read(queue);
            const now = monotonic_ns();
            memory_wait_ns = @min(turn.at(now) -| queued_at, now - asked_ns);
            // A holder that died waiting left its wait open: closed as of now.
            if (turn.since_ns != 0) {
                turn = .{ .total_ns = turn.at(now) };
                turn.write(queue);
            }
        }
        defer if (!cpu_first) {
            _ = linux.flock(queue, std.posix.LOCK.UN);
        };
        // Host-side only (which CPU a timeline runs on never changes it): any seed will do.
        var random: std.Random.DefaultPrng = .init(@as(u64, @intCast(linux.getpid())) ^ monotonic_ns());
        var memory_since: ?u64 = null;
        var memory_said_ns: u64 = 0;
        while (true) {
            if (give_up()) {
                // What a wait for memory holds, let go as a take that succeeds lets it go.
                if (memory_since != null) {
                    if (pool.priority) if (memory_priority_open()) |fd| {
                        _ = linux.flock(fd, std.posix.LOCK.UN);
                    };
                    if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.UN);
                    if (!cpu_first) {
                        turn = .{ .total_ns = turn.at(monotonic_ns()) };
                        turn.write(queue);
                    }
                }
                return null;
            }
            // Every CPU runs a VM, or a priority process waits for it: back-pressure, until one
            // is free. A priority process tries at once; the others wait their turn first, at
            // random.
            if (!cpu_first) {
                const wait_ns = random.random().intRangeAtMost(u64, wait_ns_min, wait_ns_max);
                const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns) };
                _ = linux.nanosleep(&pause, null);
            }
            // The host's memory too: no VM starts while the VMs running and this one could come
            // to need more than the host has (a VM's memory grows after it starts, up to its
            // guest's size: 18 YugabyteDB VMs admitted with memory free filled srv2 and the OOM
            // killer took serve, 2026-10-27); nor while less than half the reserve is available
            // (holders go below the reserve, holders.zig: they make room before a VM waits).
            const available = memory_available(); // 0: unknown, never a reason to wait.
            const below = available != 0 and available < memory_reserve() / 2 + sessions_reserve_bytes();
            if (below or !pool.memory_fits()) {
                if (memory_since == null) {
                    memory_since = monotonic_ns();
                    // The run's processes queued behind this one wait for it too.
                    if (!cpu_first) {
                        turn = .{ .since_ns = memory_since.?, .total_ns = turn.total_ns };
                        turn.write(queue);
                    }
                    // A check waiting for memory: the runs leave it the sessions' room.
                    if (pool.priority) if (memory_priority_open()) |fd| {
                        _ = linux.flock(fd, std.posix.LOCK.SH);
                    };
                    // Any VM waiting: holders that keep it out go (holders.zig).
                    if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.SH);
                }
                if (pool.priority) {
                    const now = monotonic_ns();
                    if (now - memory_since.? >= memory_say_after_ns and
                        (memory_said_ns == 0 or now - memory_said_ns >= memory_say_every_ns))
                    {
                        memory_said_ns = now;
                        const waited_s = (now - memory_since.?) / std.time.ns_per_s;
                        if (below) {
                            std.debug.print("[determinismo] waiting {d} s for memory: {d} MiB " ++
                                "available, below the {d} MiB kept free (the runs' VMs and holders " ++
                                "hold the rest, until they end)\n", .{
                                waited_s,
                                available >> 20,
                                (memory_reserve() / 2 + sessions_reserve_bytes()) >> 20,
                            });
                        } else {
                            std.debug.print("[determinismo] waiting {d} s for memory: a VM of {d} " ++
                                "MiB beside the running ones could outgrow the host (each may " ++
                                "grow to its guest's size)\n", .{ waited_s, claim_bytes >> 20 });
                        }
                    }
                }
                // Asleep between two looks, as the plain takes are at the loop's top: a maker or
                // a holder (`first`) waiting here had no sleep at all, a CPU each reading the
                // cgroup's memory in a loop (two holders of 16 GB guests, 26 minutes: 1,260 s
                // of system time each).
                if (cpu_first) {
                    const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns_max) };
                    _ = linux.nanosleep(&pause, null);
                }
                continue;
            }
            if (memory_since) |since| {
                const now = monotonic_ns();
                memory_wait_ns += now - since;
                if (!cpu_first) {
                    turn = .{ .total_ns = turn.at(now) };
                    turn.write(queue);
                }
                if (pool.priority) if (memory_priority_open()) |fd| {
                    _ = linux.flock(fd, std.posix.LOCK.UN);
                };
                if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.UN);
            }
            memory_since = null;
            for (0..pool.count) |index| {
                const slot: u32 = @intCast(index);
                if (!cpu_first and pool.priority_waiting(slot)) continue;
                const locked = linux.flock(pool.fds[slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
                if (linux.errno(locked) != .SUCCESS) continue;
                // The claim, where the others read it while this process holds the CPU.
                const claim: CpuClaim = .{
                    .bytes = claim_bytes,
                    .run = run_of_this_process(),
                    .shares = @intFromBool(claim_shares),
                };
                _ = linux.pwrite(pool.fds[slot], std.mem.asBytes(&claim), @sizeOf(CpuClaim), 0);
                held_note(pool.fds[slot]);
                pin(pool.cpus[slot]);
                return .{
                    .slot = slot,
                    .memory_wait_ns = memory_wait_ns,
                    .cpu_wait_ns = (monotonic_ns() - asked_ns) -| memory_wait_ns,
                };
            }
            if (cpu_first) {
                const pause: linux.timespec = .{ .sec = 0, .nsec = wait_ns_min };
                _ = linux.nanosleep(&pause, null);
            }
        }
    }

    /// Takes a place for a fast machine, pinned to its CPU: on a CPU that has machines and
    /// fewer than machines_per_cpu (the one with the fewest), else on a free one, which becomes
    /// the machines'. A CPU's lock held shared is the machines'; a deterministic VM's take asks
    /// for it exclusively and never gets one a machine is on, nor a machine one a deterministic
    /// VM holds. One machine places itself at a time (the pool's `machines.lock`): the counts
    /// it reads are those it joins. Its memory claim waits as any VM's; kept in a file of its
    /// own (`machine-<pid>-<n>`, held while it has its place), a CPU's file having room for its
    /// one exclusive holder's.
    pub fn take_shared(pool: *Pool) Held {
        assert(pool.count > 0);
        assert(machines_per_cpu > 0);
        const asked_ns = monotonic_ns();
        const directory = pool.directory_buffer[0..pool.directory_size];
        var path_buffer: [128]u8 = undefined;
        const placing_path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/machines.lock", .{directory}, 0) catch unreachable;
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
        const placing_opened = linux.open(placing_path, flags, 0o600);
        assert(linux.errno(placing_opened) == .SUCCESS);
        const placing: linux.fd_t = @intCast(placing_opened);
        defer _ = linux.close(placing);
        var random: std.Random.DefaultPrng = .init(@as(u64, @intCast(linux.getpid())) ^ monotonic_ns());
        var memory_wait_ns: u64 = 0;
        var memory_since: ?u64 = null;
        var said_ns: u64 = asked_ns;
        while (true) {
            // The host's memory, as a deterministic VM's take: no machine starts while the VMs
            // running and this one could come to need more than the host has.
            const available = memory_available(); // 0: unknown, never a reason to wait.
            const below = available != 0 and available < memory_reserve() / 2 + sessions_reserve_bytes();
            const fitting = !below and pool.claim_fits(claim_bytes);
            if (!fitting and memory_since == null) {
                memory_since = monotonic_ns();
                // Any VM waiting: holders that keep it out go (holders.zig).
                if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.SH);
            }
            if (fitting) {
                if (memory_since) |since| {
                    memory_wait_ns += monotonic_ns() - since;
                    if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.UN);
                    memory_since = null;
                }
                while (linux.errno(linux.flock(placing, std.posix.LOCK.EX)) == .INTR) {}
                const placed = pool.machine_place();
                _ = linux.flock(placing, std.posix.LOCK.UN);
                if (placed) |held| {
                    var taken = held;
                    taken.memory_wait_ns = memory_wait_ns;
                    taken.cpu_wait_ns = (monotonic_ns() - asked_ns) -| memory_wait_ns;
                    pin(pool.cpus[taken.slot]);
                    return taken;
                }
            }
            // Said, for whoever started it and waits (serve gives a machine up after a while
            // and answers with its last line).
            const now = monotonic_ns();
            if (now - said_ns >= memory_say_after_ns) {
                said_ns = now;
                if (fitting) {
                    std.debug.print("[determinismo] waiting {d} s for a CPU: each one this machine may take holds a " ++
                        "deterministic VM or {d} machines\n", .{ (now - asked_ns) / std.time.ns_per_s, machines_per_cpu });
                } else {
                    std.debug.print("[determinismo] waiting {d} s for memory: {d} MiB available, a machine of {d} MiB " ++
                        "beside the VMs running\n", .{ (now - asked_ns) / std.time.ns_per_s, available >> 20, claim_bytes >> 20 });
                }
            }
            const wait_ns = random.random().intRangeAtMost(u64, wait_ns_min, wait_ns_max);
            const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns) };
            _ = linux.nanosleep(&pause, null);
        }
    }

    /// A place for a machine now, if one is (take_shared, holding the pool's `machines.lock`).
    fn machine_place(pool: *Pool) ?Held {
        const directory = pool.directory_buffer[0..pool.directory_size];
        var counts: [cpus_max]u16 = @splat(0);
        _ = machines_scan(directory, &counts);
        // Among the CPUs that have machines and room: the one with the fewest.
        var joined: ?u32 = null;
        for (0..pool.count) |index| {
            const count = counts[pool.cpus[index]];
            if (count == 0 or count >= machines_per_cpu) continue;
            if (joined == null or count < counts[pool.cpus[joined.?]]) joined = @intCast(index);
        }
        const slot: u32 = joined orelse fresh: {
            // None: a free CPU becomes the machines' (one a check waits for is left to it).
            for (0..pool.count) |index| {
                const candidate: u32 = @intCast(index);
                if (counts[pool.cpus[candidate]] != 0) continue; // Full of machines.
                if (!pool.priority and pool.priority_waiting(candidate)) continue;
                // Shared, the first of its machines: granted unless a deterministic VM holds
                // it exclusively (the scan found no machine on it).
                if (linux.errno(linux.flock(pool.fds[candidate], std.posix.LOCK.SH | std.posix.LOCK.NB)) != .SUCCESS) continue;
                break :fresh candidate;
            }
            return null;
        };
        // Shared with the machines there (a fresh one's is held already: taken again, the same).
        if (linux.errno(linux.flock(pool.fds[slot], std.posix.LOCK.SH | std.posix.LOCK.NB)) != .SUCCESS) return null;
        var held: Held = .{ .slot = slot };
        const serial = machine_serial;
        machine_serial += 1;
        const path = std.fmt.bufPrintSentinel(&held.machine_path, "{s}/machine-{d}-{d}", .{ directory, linux.getpid(), serial }, 0) catch unreachable;
        held.machine_path_size = @intCast(path.len);
        const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(opened) != .SUCCESS) {
            _ = linux.flock(pool.fds[slot], std.posix.LOCK.UN);
            return null;
        }
        held.machine_fd = @intCast(opened);
        const place: MachinePlace = .{ .claim_bytes = claim_bytes, .cpu = pool.cpus[slot] };
        _ = linux.pwrite(held.machine_fd, std.mem.asBytes(&place), @sizeOf(MachinePlace), 0);
        _ = linux.flock(held.machine_fd, std.posix.LOCK.EX);
        return held;
    }

    /// Whether `bytes` more fit beside what the held CPUs' processes claimed, on any CPU of the
    /// host: within the host's memory less the reserve. A CPU's claim counts while its lock is
    /// held exclusively (a deterministic VM's); the machines sharing CPUs keep theirs in their
    /// own files (machines_scan).
    fn claim_fits(pool: *Pool, bytes: u64) bool {
        if (bytes == 0) return true;
        // The claims are every run's, host-wide: against the host's memory and reserve. A
        // cgroup's limit bounds what this process has available (memory_available), not the
        // host's claims: compared with a session's 24 GB, a hunt's 50 GB of claims kept every
        // check's VM waiting while the hunt ran (srv3, 2026-10-29).
        const total = meminfo("MemTotal:");
        if (total == 0) return true; // Unknown: never a reason to wait.
        // A VM that branches from its run's snapshot counts as what its run learned its VMs
        // hold, where that is less than its guest's size (claim_soft): this run's, and any other
        // run's from that run's turn file. Counted at its guest's size by every other run, a
        // hunt's 35 VMs of 6 GiB guests were 210 GiB of a 187.6 GiB host while they held 2.4 GiB
        // each: nothing beside it was admitted, a second serve's runs waiting 10 minutes
        // (srv4, run 2122, 2026-11-22).
        const soft = pool.claim_soft();
        const mine = run_of_this_process();
        var softs: RunSofts = .{};
        var claimed: u64 = 0;
        for (pool.host_fds[0..pool.host_count]) |fd| {
            const probe = linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB);
            if (linux.errno(probe) == .SUCCESS) {
                _ = linux.flock(fd, std.posix.LOCK.UN);
                continue; // Free.
            }
            var claim: CpuClaim = .{};
            const got = linux.pread(fd, std.mem.asBytes(&claim), @sizeOf(CpuClaim), 0);
            if (linux.errno(got) != .SUCCESS or got < @sizeOf(u64)) continue;
            const run_soft = if (got != @sizeOf(CpuClaim) or claim.shares == 0)
                0
            else if (claim.run == mine)
                soft
            else
                softs.of(pool.directory_buffer[0..pool.directory_size], claim.run);
            claimed += if (run_soft != 0) @min(claim.bytes, run_soft) else claim.bytes;
        }
        claimed += nodes_claimed(pool.directory_buffer[0..pool.directory_size]);
        claimed += machines_scan(pool.directory_buffer[0..pool.directory_size], null);
        if (!fits(claimed, bytes, total, 0, host_reserve(total) + sessions_reserve_bytes())) return false;
        const available = if (pool.available_counts) memory_available() else 0;
        return fits(0, bytes, std.math.maxInt(u64) / 2, available, reserve_bytes());
    }

    /// Whether `vms` more of this run's VMs fit in memory beside every VM admitted: what its
    /// explorer asks before a worker takes a timeline (main.zig's timeline_gated).
    pub fn room(pool: *Pool, vms: u32) bool {
        assert(vms > 0);
        return pool.claim_fits(pool.claim_now() * vms);
    }

    /// Whether a VM of this run fits, memory-wise (above half the reserve, checked apart): its
    /// claim beside the others (claim_fits), or, with none of the run's VMs running, its own
    /// nodes holding memory (stalled_alone).
    fn memory_fits(pool: *Pool) bool {
        return pool.claim_fits(pool.claim_now()) or pool.stalled_alone();
    }

    /// None of this run's VMs runs while its own nodes hold memory: one of its VMs starts,
    /// whatever the claims. Its nodes leave only as its timelines run (their returns take
    /// them), so claims they push past the host's memory held the run for good: ParadeDB's run
    /// 2091, 134.5 GiB of its nodes beside 32 GiB guests not learned yet (39 timelines ended of
    /// 40 workers: learning needs one each, and VMs running), its 40 workers waiting and none
    /// running, the host 46 GB available. What its VM holds is its guest's use (about 20 GB
    /// there), not the claim; memory below half the reserve still waits (take).
    fn stalled_alone(pool: *Pool) bool {
        if (pool.run_held() != 0) return false;
        return nodes_of(pool.directory_buffer[0..pool.directory_size], run_of_this_process()) > 0;
    }

    /// The bytes of every live process's nodes claim (nodes_claim): counted in the admission on
    /// their own, beside the VMs' claims.
    pub fn nodes_held(pool: *Pool) u64 {
        return nodes_claimed(pool.directory_buffer[0..pool.directory_size]);
    }

    /// How many CPUs of the host this run's VMs hold now (their files name the run): the VMs
    /// admitted, where its workers also count those still waiting for a CPU or for memory.
    pub fn run_held(pool: *Pool) u32 {
        const mine = run_of_this_process();
        var held: u32 = 0;
        for (pool.host_fds[0..pool.host_count]) |fd| {
            const probe = linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB);
            if (linux.errno(probe) == .SUCCESS) {
                _ = linux.flock(fd, std.posix.LOCK.UN);
                continue; // Free.
            }
            var claim: CpuClaim = .{};
            const got = linux.pread(fd, std.mem.asBytes(&claim), @sizeOf(CpuClaim), 0);
            held += @intFromBool(linux.errno(got) == .SUCCESS and got == @sizeOf(CpuClaim) and claim.run == mine);
        }
        return held;
    }

    /// What the run's explorer learned each of its VMs comes to hold at most (claim_soft_set),
    /// 0 while it has not: the run's claims count as this where it is less than their guest's
    /// size. Read at each look: the explorer raises it as its VMs grow, and takes it back.
    fn claim_soft(pool: *const Pool) u64 {
        var bytes: [8]u8 = @splat(0);
        if (linux.pread(pool.turn_fd, &bytes, bytes.len, claim_soft_offset) != bytes.len) return 0;
        return std.mem.bytesToValue(u64, &bytes);
    }

    /// The run's explorer says what its VMs come to hold (0: their guest's size again).
    pub fn claim_soft_set(pool: *const Pool, bytes: u64) void {
        const value = std.mem.toBytes(bytes);
        _ = linux.pwrite(pool.turn_fd, &value, value.len, claim_soft_offset);
    }

    /// The queue a take of this process waits its turn in: the run's for its branches, its whole
    /// VMs' own for the others (whole_fd).
    fn queue_for(pool: *const Pool, shares: bool) linux.fd_t {
        return if (shares) pool.turn_fd else pool.whole_fd;
    }

    /// What a VM of this process claims: its guest's size, or less once its run learned so where
    /// it branches from a snapshot the run holds (claim_shares).
    fn claim_now(pool: *const Pool) u64 {
        if (!claim_shares) return claim_bytes;
        const soft = pool.claim_soft();
        return if (soft == 0) claim_bytes else @min(claim_bytes, soft);
    }

    /// Whether a priority process waits for the CPU of `slot` (it holds its `priority-<cpu>`
    /// file shared).
    fn priority_waiting(pool: *Pool, slot: u32) bool {
        const fd = pool.priority_fds[slot];
        const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(probe) != .SUCCESS) return true;
        _ = linux.flock(fd, std.posix.LOCK.UN);
        return false;
    }

    pub fn give(pool: *Pool, held: Held) void {
        assert(held.slot < pool.count);
        // A machine's place: its file gone (its claim and its count with it), then the CPU.
        if (held.machine_fd >= 0) {
            _ = linux.unlink(@ptrCast(held.machine_path[0..held.machine_path_size :0]));
            _ = linux.close(held.machine_fd);
        }
        // Its run goes from the CPU's file with it: a build that writes a claim alone, taking
        // the CPU next, is of no run the file names.
        const none: u64 = 0;
        _ = linux.pwrite(pool.fds[held.slot], std.mem.asBytes(&none), @sizeOf(u64), @offsetOf(CpuClaim, "run"));
        _ = linux.flock(pool.fds[held.slot], std.posix.LOCK.UN);
        held_forget(pool.fds[held.slot]);
        unpin(); // Not pinned to a CPU it no longer holds (nor are what it forks or runs next).
    }
};

pub const Held = struct {
    slot: u32,
    /// How long the take waited for the host's memory (other runs' VMs and holders claim it),
    /// its own wait and its run's waiter's ahead of it while it queued for the run's turn: a run
    /// whose VMs mostly wait for memory runs fewer timelines at once than it has CPUs.
    memory_wait_ns: u64 = 0,
    /// And for a CPU, the rest of the take: every CPU held (by other runs' VMs, a priority
    /// process, or this run's own replays and workers), each attempt a pause of 10 to 30 ms.
    cpu_wait_ns: u64 = 0,
    /// A fast machine's place (take_shared): its file in the pool's directory, held while it
    /// has the place.
    machine_fd: linux.fd_t = -1,
    machine_path: [127:0]u8 = @splat(0),
    machine_path_size: u8 = 0,
};

/// A machine's place file's content: its memory claim and the CPU it is on.
const MachinePlace = extern struct { claim_bytes: u64 = 0, cpu: u64 = 0 };

/// This process's machines' places so far (a file each: machine-<pid>-<n>).
var machine_serial: u32 = 0;

/// The fast machines holding places (their `machine-<pid>-<n>` files, each locked by its
/// machine while it has the place): their memory claims in all and, in `counts`, how many sit
/// on each CPU (by its number). A file nobody holds is a machine gone (removed when its process
/// is), or one just made and not locked yet.
fn machines_scan(directory: []const u8, counts: ?*[cpus_max]u16) u64 {
    if (directory.len == 0) return 0;
    var path_buffer: [128]u8 = undefined;
    const directory_z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return 0;
    const opened = linux.open(directory_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const dir: linux.fd_t = @intCast(opened);
    defer _ = linux.close(dir);
    var total: u64 = 0;
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(dir, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (!std.mem.startsWith(u8, name, "machine-")) continue;
            const name_z: [*:0]const u8 = @ptrCast(&entry.name);
            const file = linux.openat(dir, name_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(file) != .SUCCESS) continue;
            const fd: linux.fd_t = @intCast(file);
            defer _ = linux.close(fd);
            if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) {
                const pid_text = name["machine-".len..];
                const pid_end = std.mem.indexOfScalar(u8, pid_text, '-') orelse pid_text.len;
                var proc_buffer: [32]u8 = undefined;
                const proc = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/{s}", .{pid_text[0..pid_end]}, 0) catch continue;
                if (linux.errno(linux.access(proc, std.posix.F_OK)) != .SUCCESS) _ = linux.unlinkat(dir, name_z, 0);
                continue;
            }
            var place: MachinePlace = .{};
            if (linux.pread(fd, std.mem.asBytes(&place), @sizeOf(MachinePlace), 0) != @sizeOf(MachinePlace)) continue;
            total += place.claim_bytes;
            if (counts) |by_cpu| if (place.cpu < cpus_max) {
                by_cpu[place.cpu] += 1;
            };
        }
    }
    return total;
}

/// A run's turn file's content: how long the turn's holders waited for memory, for the run's
/// processes queued behind them (each books the part of its queueing that a memory wait ahead of
/// it took as memory wait). Written by the turn's holder alone, whole, in one write.
const TurnMemory = extern struct {
    /// When the holder's wait for memory began (monotonic, the host's), 0: none.
    since_ns: u64 = 0,
    /// The holders' memory waits that ended.
    total_ns: u64 = 0,

    /// The holders' memory waiting up to `now`.
    fn at(state: TurnMemory, now: u64) u64 {
        return state.total_ns + if (state.since_ns != 0) now -| state.since_ns else 0;
    }

    /// The file's, nothing waited when it has none yet (a new run's). A reader not holding the
    /// turn reads it until two reads agree: a holder's write is never seen half done.
    fn read(fd: linux.fd_t) TurnMemory {
        var last: TurnMemory = .{};
        for (0..4) |_| {
            var state: TurnMemory = .{};
            if (linux.pread(fd, std.mem.asBytes(&state), @sizeOf(TurnMemory), 0) != @sizeOf(TurnMemory)) return .{};
            if (std.meta.eql(state, last)) return state;
            last = state;
        }
        return last;
    }

    fn write(state: TurnMemory, fd: linux.fd_t) void {
        _ = linux.pwrite(fd, std.mem.asBytes(&state), @sizeOf(TurnMemory), 0);
    }
};

/// The pool directory's `<kind>-<cpu>` file, opened (made if new).
fn pool_file(directory: [:0]const u8, comptime kind: []const u8, cpu: usize) !linux.fd_t {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/" ++ kind ++ "-{d}", .{ directory, cpu }, 0);
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return error.PoolFile;
    return @intCast(fd);
}

/// The host's CPUs, whatever this process may run on: one past the last of
/// /sys/devices/system/cpu/possible ("0-35"), or 0 if unknown (then only the pool's count).
fn host_cpu_count() usize {
    const fd = linux.open("/sys/devices/system/cpu/possible", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [256]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    return possible_count(std.mem.trim(u8, buffer[0..size], " \n"));
}

/// One past the highest CPU of a kernel CPU list ("0-35", "0,2-5").
fn possible_count(list: []const u8) usize {
    var highest: ?usize = null;
    var ranges = std.mem.splitScalar(u8, list, ',');
    while (ranges.next()) |range| {
        const last = if (std.mem.indexOfScalar(u8, range, '-')) |dash| range[dash + 1 ..] else range;
        const cpu = std.fmt.parseInt(usize, last, 10) catch continue;
        highest = @max(highest orelse 0, cpu);
    }
    return if (highest) |cpu| cpu + 1 else 0;
}

test "a check waiting for a CPU leaves the others to the rest" {
    var waiter: Pool = undefined;
    try waiter.open();
    defer waiter.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    if (other.count < 2) return error.SkipZigTest;
    // A priority process confined to the first CPU waits for it.
    _ = linux.flock(waiter.priority_fds[0], std.posix.LOCK.SH);
    defer _ = linux.flock(waiter.priority_fds[0], std.posix.LOCK.UN);
    try std.testing.expect(other.priority_waiting(0));
    try std.testing.expect(!other.priority_waiting(1));
}

/// The CPUs a rootless podman build or container of this process should use (podman's
/// `--cpuset-cpus`): its own CPUs, as far as the user manager's cpuset reaches. Rootless podman
/// moves its containers into a scope under user@<uid>.service, whose cpuset caps them: srv4's
/// isolation confined the whole user slice to the sessions' CPUs, and every image build of a run
/// serve started (serve on the hunt CPUs) ran on the sessions' instead (2026-11-26). Null when
/// none of this process's CPUs is in reach (the build runs where the slice lets it), and when the
/// user manager has no cpuset to read (no isolation, no cpuset controller delegated: whether
/// podman would take one there is unknown, so none is asked: CE64).
pub fn podman_cpuset(arena: std.mem.Allocator) !?[]const u8 {
    const uid = linux.getuid();
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/sys/fs/cgroup/user.slice/user-{d}.slice/user@{d}.service/cpuset.cpus.effective", .{ uid, uid }, 0);
    var reach_buffer: [cpus_max * 6]u8 = undefined;
    const reach = list_file_read(path, &reach_buffer) orelse return null;
    return cpuset_within(arena, given(), reach);
}

/// A kernel CPU list file, whole (CE64: one 512-byte read cut a long one, as alternate CPUs of
/// a big host); null when it can't be read.
fn list_file_read(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < buffer.len) {
        const got = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(got) != .SUCCESS) return null;
        if (got == 0) break;
        size += got;
    }
    return std.mem.trim(u8, buffer[0..size], " \n");
}

test "a CPU list file is read whole (CE64)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, ".zig-cache/tmp/{s}/cpus", .{&tmp.sub_path}, 0);
    var list: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&list);
    var cpu: usize = 0;
    while (cpu < 512) : (cpu += 2) try writer.print("{s}{d}", .{ if (cpu == 0) "" else ",", cpu });
    try writer.writeAll("\n");
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    _ = linux.write(@intCast(fd), writer.buffered().ptr, writer.buffered().len);
    _ = linux.close(@intCast(fd));
    var buffer: [cpus_max * 6]u8 = undefined;
    const read = list_file_read(path, &buffer).?;
    try std.testing.expect(read.len > 512);
    try std.testing.expect(std.mem.endsWith(u8, read, ",510"));
}

/// `mine`'s CPUs within the kernel CPU list `reach`, as a kernel CPU list; null when none is.
fn cpuset_within(arena: std.mem.Allocator, mine: linux.cpu_set_t, reach: []const u8) !?[]const u8 {
    var mask = mine;
    {
        const list = reach;
        var allowed: linux.cpu_set_t = @splat(0);
        var ranges = std.mem.splitScalar(u8, list, ',');
        while (ranges.next()) |range| {
            if (range.len == 0) continue;
            const dash = std.mem.indexOfScalar(u8, range, '-');
            const first = std.fmt.parseInt(usize, if (dash) |at| range[0..at] else range, 10) catch continue;
            const last = if (dash) |at| std.fmt.parseInt(usize, range[at + 1 ..], 10) catch continue else first;
            var cpu = first;
            while (cpu <= last and cpu < cpus_max) : (cpu += 1) set_add(&allowed, cpu);
        }
        for (&mask, allowed) |*word, reachable| word.* &= reachable;
    }
    const bits = @bitSizeOf(@TypeOf(mask[0]));
    var list: std.ArrayList(u8) = .empty;
    var cpu: usize = 0;
    while (cpu < mask.len * bits) {
        if (!set_has(&mask, cpu)) {
            cpu += 1;
            continue;
        }
        var last = cpu;
        while (last + 1 < mask.len * bits and set_has(&mask, last + 1)) last += 1;
        if (list.items.len > 0) try list.append(arena, ',');
        if (last == cpu) try list.print(arena, "{d}", .{cpu}) else try list.print(arena, "{d}-{d}", .{ cpu, last });
        cpu = last + 1;
    }
    return if (list.items.len == 0) null else list.items;
}

fn set_add(set: *linux.cpu_set_t, cpu: usize) void {
    const bits = @bitSizeOf(@TypeOf(set[0]));
    set[cpu / bits] |= @as(@TypeOf(set[0]), 1) << @intCast(cpu % bits);
}

fn set_has(set: *const linux.cpu_set_t, cpu: usize) bool {
    const bits = @bitSizeOf(@TypeOf(set[0]));
    return set[cpu / bits] & (@as(@TypeOf(set[0]), 1) << @intCast(cpu % bits)) != 0;
}

test "a podman build's CPUs: the process's, as far as the user manager's cpuset reaches" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var hunt: linux.cpu_set_t = @splat(0);
    for (9..44) |cpu| set_add(&hunt, cpu);
    // Under today's srv4 isolation: the user slice on the sessions' CPUs, none of the hunt's.
    try std.testing.expectEqual(@as(?[]const u8, null), try cpuset_within(arena, hunt, "0-8,44-52"));
    // The user manager unconfined: the hunt's own.
    try std.testing.expectEqualStrings("9-43", (try cpuset_within(arena, hunt, "0-52")).?);
    // Ranges and single CPUs.
    var some: linux.cpu_set_t = @splat(0);
    for ([_]usize{ 0, 2, 3, 4, 7 }) |cpu| set_add(&some, cpu);
    try std.testing.expectEqualStrings("0,2-4,7", (try cpuset_within(arena, some, "0-63")).?);
    try std.testing.expectEqualStrings("2-3", (try cpuset_within(arena, some, "1-3")).?);
    // A list past 512 bytes (alternate CPUs of a 512-CPU host): read and taken whole (CE64).
    var long: std.ArrayList(u8) = .empty;
    var cpu: usize = 0;
    while (cpu < 512) : (cpu += 2) try long.print(arena, "{s}{d}", .{ if (cpu == 0) "" else ",", cpu });
    try std.testing.expect(long.items.len > 512);
    var high: linux.cpu_set_t = @splat(0);
    set_add(&high, 510);
    try std.testing.expectEqualStrings("510", (try cpuset_within(arena, high, long.items)).?);
}

test "a kernel CPU list's count" {
    try std.testing.expectEqual(@as(usize, 36), possible_count("0-35"));
    try std.testing.expectEqual(@as(usize, 6), possible_count("0,2-5"));
    try std.testing.expectEqual(@as(usize, 1), possible_count("0"));
    try std.testing.expectEqual(@as(usize, 0), possible_count(""));
}

/// Memory kept free on the host: no VM starts, and no holder is made, below it.
pub const memory_reserve_bytes = 8 << 30;

/// The reserve for what this process may use: the host's, or an eighth of a smaller limit (its
/// cgroup's): 8 GB kept free under a 24 GB unit would have left its checks no holders.
pub fn memory_reserve() u64 {
    const total = memory_total();
    if (total == 0) return memory_reserve_bytes;
    return host_reserve(total);
}

/// The reserve of memory `total` in size: 8 GB, an eighth of less than 64 GB, or a twelfth of
/// more than 96 GB. A host's claims against its whole reserve admitted no VM on an 8 GB host (EC2's
/// c8i.xlarge, 2026-11-07); a 187 GB host thrashed at 12 GB available beside a 40-VM run, its
/// holders' shared memory at 71 GB and the page cache its VMs' disks and the events' writes
/// need squeezed (ssh dead four minutes, 2026-11-17): its reserve 15.6 GB, and its holders kept
/// in memory only above twice that (holders.zig).
fn host_reserve(total: u64) u64 {
    return @max(@min(memory_reserve_bytes, total / 8), total / 12);
}

test host_reserve {
    const gib: u64 = 1 << 30;
    try std.testing.expectEqual(1 * gib, host_reserve(8 * gib)); // An eighth of a small host.
    try std.testing.expectEqual(8 * gib, host_reserve(64 * gib));
    try std.testing.expectEqual(8 * gib, host_reserve(96 * gib)); // A twelfth: 8 GB again.
    // A 187 GB host (srv4's): no less than what kept it from thrashing beside a 40-VM run.
    try std.testing.expect(host_reserve(187 * gib) >= 15 * gib);
}

/// Memory a host's runs leave to its user's own sessions (a host with reserved cores: their
/// builds, checks and replays) while one of the sessions' VMs waits for memory, from
/// DETERMINISMO_SESSIONS_MEMORY_MIB: serve carries it (serve.sh sets it with the reserved
/// cores), and so every process of its runs; the sessions' own processes do not. Without it a
/// hunt held all but 9 GiB of srv3's 125, and a check on the reserved cores ran one VM at a
/// time; held back always, it kept a Kafka hunt's holders from being made (they want room to
/// grow) in nearly every timeline (2026-10-28). So only while a priority process (a check)
/// waits for memory (`memory-priority`, held shared by it): runs start no VM into that room,
/// and their holders give theirs up.
pub fn sessions_reserve_bytes() u64 {
    const value = std.c.getenv("DETERMINISMO_SESSIONS_MEMORY_MIB") orelse return 0;
    const mib = std.fmt.parseInt(u64, std.mem.span(value), 10) catch return 0;
    if (!memory_priority_waiting()) return 0;
    return mib << 20;
}

/// The pool directory's `memory-priority` file, opened once by this process (-1: not yet, -2:
/// could not be).
var memory_priority_fd: linux.fd_t = -1;

fn memory_priority_open() ?linux.fd_t {
    if (memory_priority_fd == -2) return null;
    if (memory_priority_fd >= 0) return memory_priority_fd;
    var buffer: [96]u8 = undefined;
    const path = (if (builtin.is_test)
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-test-{d}/memory-priority", .{linux.getpid()}, 0)
    else
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/memory-priority", .{linux.getuid()}, 0)) catch {
        memory_priority_fd = -2;
        return null;
    };
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) {
        memory_priority_fd = -2;
        return null;
    }
    memory_priority_fd = @intCast(fd);
    return memory_priority_fd;
}

/// The pool directory's `memory-wanted` file, held shared by every process whose VM waits for
/// memory (-1: not opened yet, -2: could not be).
var memory_wanted_fd: linux.fd_t = -1;

fn memory_wanted_open() ?linux.fd_t {
    if (memory_wanted_fd == -2) return null;
    if (memory_wanted_fd >= 0) return memory_wanted_fd;
    var buffer: [96]u8 = undefined;
    const path = (if (builtin.is_test)
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-test-{d}/memory-wanted", .{linux.getpid()}, 0)
    else
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/memory-wanted", .{linux.getuid()}, 0)) catch {
        memory_wanted_fd = -2;
        return null;
    };
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) {
        memory_wanted_fd = -2;
        return null;
    }
    memory_wanted_fd = @intCast(fd);
    return memory_wanted_fd;
}

/// Whether a VM waits for memory anywhere on the host (it holds `memory-wanted` shared): a
/// holder keeping it out goes (holders.zig). Between where holders go by themselves (below the
/// reserve) and where a VM starts (its size above it), neither moved: a tree's last timeline
/// waited for ever beside its generation's holders (a 24 GB check, 2026-10-29).
pub fn memory_wanted_waiting() bool {
    const fd = memory_wanted_open() orelse return false;
    const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (linux.errno(probe) != .SUCCESS) return true;
    _ = linux.flock(fd, std.posix.LOCK.UN);
    return false;
}

/// The pool directory's `makers-wanted` file: held by an explorer whose judgment has node
/// makers waiting for room, the bytes it wants available above the reserve written in it
/// (makers_want). The holders in memory leave for it (makers_wanted, holders.zig): a maker
/// waited otherwise until one in flight ended, the memory around it full of holders that leave
/// for a VM that waits (memory-wanted) but knew of no maker (etcd's 12-hour run 2007: its
/// nodes made 1.5 at a time beside 10 to 16 GB available, its judgments its pace).
/// The explorer's own description of it (-1: not opened yet, -2: could not be), apart from the
/// one a process asks with: a lock is its description's, and a child's question through its
/// parent's would be the explorer's own lock answering.
var makers_want_fd: linux.fd_t = -1;
var makers_want_bytes: u64 = 0;
/// The description a process asks with (makers_wanted).
var makers_wanted_fd: linux.fd_t = -1;

fn makers_file_open(cached: *linux.fd_t) ?linux.fd_t {
    if (cached.* == -2) return null;
    if (cached.* >= 0) return cached.*;
    var buffer: [96]u8 = undefined;
    const path = (if (builtin.is_test)
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-test-{d}/makers-wanted", .{linux.getpid()}, 0)
    else
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/makers-wanted", .{linux.getuid()}, 0)) catch {
        cached.* = -2;
        return null;
    };
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) {
        cached.* = -2;
        return null;
    }
    cached.* = @intCast(fd);
    return cached.*;
}

/// An explorer's node makers wait for `bytes` available above the reserve (the claims of those
/// in flight and of the next): said to the host's holders until makers_want_end. The file is
/// held exclusively (one explorer's want at a time: another's waits its turn, its makers as
/// before this) and never waited for: a holder asking holds it shared for an instant, and the
/// next call tries again (the explorer's loop calls at every look).
pub fn makers_want(bytes: u64) void {
    assert(bytes > 0);
    const fd = makers_file_open(&makers_want_fd) orelse return;
    if (makers_want_bytes == 0) {
        const held = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(held) != .SUCCESS) return;
    }
    if (makers_want_bytes != bytes) {
        const said = std.mem.toBytes(bytes);
        _ = linux.pwrite(fd, &said, said.len, 0);
    }
    makers_want_bytes = bytes;
}

/// No maker of this explorer waits for room any more: nothing left in the file for a later
/// look to read.
pub fn makers_want_end() void {
    if (makers_want_bytes == 0) return;
    makers_want_bytes = 0;
    const fd = makers_file_open(&makers_want_fd) orelse return;
    const none = std.mem.toBytes(@as(u64, 0));
    _ = linux.pwrite(fd, &none, none.len, 0);
    _ = linux.flock(fd, std.posix.LOCK.UN);
}

/// The bytes an explorer's node makers wait for above the reserve, anywhere on the host; 0 when
/// none waits. Asked with a shared hold: those asking do not see each other (asked with an
/// exclusive one, as memory_wanted_waiting is, two holders asking at once took each other for
/// an explorer, and a holder that leaves for bytes nobody wants is lost).
pub fn makers_wanted() u64 {
    const fd = makers_file_open(&makers_wanted_fd) orelse return 0;
    const probe = linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB);
    if (linux.errno(probe) == .SUCCESS) {
        _ = linux.flock(fd, std.posix.LOCK.UN);
        return 0;
    }
    var said: [8]u8 = @splat(0);
    if (linux.pread(fd, &said, said.len, 0) != said.len) return 0;
    return std.mem.bytesToValue(u64, &said);
}

/// Whether a priority process waits for memory: it holds `memory-priority` shared.
fn memory_priority_waiting() bool {
    const fd = memory_priority_open() orelse return false;
    const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (linux.errno(probe) != .SUCCESS) return true;
    _ = linux.flock(fd, std.posix.LOCK.UN);
    return false;
}

/// The memory this process leaves free: the host's reserve, and the sessions' if it is a run's.
pub fn reserve_bytes() u64 {
    return memory_reserve() + sessions_reserve_bytes();
}

/// The memory available to this process (MemAvailable, or less within its cgroup's limit), or 0
/// if unknown.
pub fn memory_available() u64 {
    const host = meminfo("MemAvailable:");
    const limited = cgroup_memory() orelse return host;
    return if (host == 0) limited.available else @min(host, limited.available);
}

/// The host's memory in use (MemTotal less MemAvailable, whatever this process's cgroup: the
/// claims are host-wide), 0 if unknown.
pub fn host_in_use() u64 {
    return meminfo("MemTotal:") -| meminfo("MemAvailable:");
}

/// The memory this process may use (MemTotal, or its cgroup's limit), 0 if unknown.
/// The host's anonymous and shared memory (AnonPages, Shmem): a run's VMs' guest memory is shared
/// (memfds), what lies outside their claims mostly anonymous (holders' copy-on-write pages,
/// forks, the explorers): how a run's memory splits, sampled over it (activity.sample).
pub fn memory_split() struct { anonymous: u64, shared: u64 } {
    return .{ .anonymous = meminfo("AnonPages:"), .shared = meminfo("Shmem:") };
}

pub fn memory_total() u64 {
    const host = meminfo("MemTotal:");
    const limited = cgroup_memory() orelse return host;
    return if (host == 0) limited.total else @min(host, limited.total);
}

/// Memory limits on this process's cgroup v2 or its ancestors (systemd's MemoryMax on a unit, a
/// container's): the tightest, and what is free under it now. A user's checks confined to cores
/// of their own (MemoryMax too) once took 30 GB beside a hunt that then made no holders, since
/// VMs were admitted by the host's memory: under a limit, by the limit's.
const CgroupMemory = struct { total: u64, available: u64 };

/// The levels with a limit (`memory.max` other than "max"), found once: limits move rarely, and
/// a process under none reads nothing more.
const levels_max = 8;
var limited_levels: [levels_max][256]u8 = undefined;
var limited_level_sizes: [levels_max]u8 = undefined;
var limited_count: ?u8 = null;

fn cgroup_memory() ?CgroupMemory {
    if (limited_count == null) cgroup_levels_find();
    var found: ?CgroupMemory = null;
    for (0..limited_count.?) |index| {
        const level = limited_levels[index][0..limited_level_sizes[index]];
        const limit = cgroup_number(level, "memory.max") orelse continue;
        const current = cgroup_number(level, "memory.current") orelse continue;
        // Reclaimable: file pages not shared (memory.current counts the page cache too).
        const reclaimable = cgroup_stat(level, "inactive_file ");
        const available = limit -| (current -| reclaimable);
        found = if (found) |known| .{
            .total = @min(known.total, limit),
            .available = @min(known.available, available),
        } else .{ .total = limit, .available = available };
    }
    return found;
}

fn cgroup_levels_find() void {
    limited_count = 0;
    var buffer: [512]u8 = undefined;
    const own = read_small("/proc/self/cgroup", &buffer) orelse return;
    // cgroup v2: one line, "0::<path>".
    const start = std.mem.indexOf(u8, own, "0::") orelse return;
    const relative = std.mem.trimEnd(u8, own[start + 3 ..], "\n");
    var path_buffer: [256]u8 = undefined;
    var path: []const u8 = std.fmt.bufPrint(&path_buffer, "/sys/fs/cgroup{s}", .{if (std.mem.eql(u8, relative, "/")) "" else relative}) catch return;
    while (limited_count.? < levels_max) {
        if (cgroup_number(path, "memory.max") != null) {
            const index = limited_count.?;
            @memcpy(limited_levels[index][0..path.len], path);
            limited_level_sizes[index] = @intCast(path.len);
            limited_count = index + 1;
        }
        if (std.mem.eql(u8, path, "/sys/fs/cgroup")) return;
        path = std.fs.path.dirname(path) orelse return;
    }
}

/// A cgroup file holding one number; null for "max", or when it is not there.
fn cgroup_number(level: []const u8, comptime name: []const u8) ?u64 {
    var path_buffer: [320]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/" ++ name, .{level}, 0) catch return null;
    var buffer: [64]u8 = undefined;
    const text = read_small(path, &buffer) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

/// A field of a cgroup's memory.stat ("<key> <bytes>"), 0 when absent.
fn cgroup_stat(level: []const u8, comptime key: []const u8) u64 {
    var path_buffer: [320]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/memory.stat", .{level}, 0) catch return 0;
    var buffer: [8192]u8 = undefined;
    const text = read_small(path, &buffer) orelse return 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " "), 10) catch 0;
    }
    return 0;
}

fn read_small(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

fn meminfo(comptime key: []const u8) u64 {
    const fd = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    const at = std.mem.indexOf(u8, buffer[0..size], key) orelse return 0;
    var words = std.mem.tokenizeScalar(u8, buffer[at + key.len .. size], ' ');
    const kib = std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch return 0;
    return kib * 1024;
}

/// How many CPUs this process's pool holds: the CPUs it was given, one thread per core.
pub fn usable_count() u32 {
    const available = given();
    const bits = @bitSizeOf(@TypeOf(available[0]));
    var count: u32 = 0;
    for (0..available.len * bits) |cpu| {
        if (usable(&available, cpu)) count += 1;
    }
    return @max(count, 1);
}

/// In the set, and, with one thread per core (the default), not a second hyperthread whose
/// core's first thread is in the set too.
fn usable(available: *const linux.cpu_set_t, cpu: usize) bool {
    const bits = @bitSizeOf(@TypeOf(available[0]));
    if (available[cpu / bits] >> @intCast(cpu % bits) & 1 == 0) return false;
    if (siblings_allowed()) return true;
    const first = first_sibling(@intCast(cpu)) orelse return true;
    if (first == cpu) return true;
    return available[first / bits] >> @intCast(first % bits) & 1 == 0;
}

fn siblings_allowed() bool {
    const value = std.c.getenv("DETERMINISMO_SMT") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

/// Whether the CPU is a core's second hyperthread (not the first of its siblings).
fn sibling(cpu: u16) bool {
    const first = first_sibling(cpu) orelse return false;
    return cpu != first;
}

/// The first thread of the CPU's core (itself without SMT), if the kernel says.
fn first_sibling(cpu: u16) ?u16 {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/sys/devices/system/cpu/cpu{d}/" ++
        "topology/thread_siblings_list", .{cpu}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var text: [64]u8 = undefined;
    const size = linux.read(@intCast(fd), &text, text.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return siblings_first(text[0..size]);
}

/// "0,18" or "0-1": the first is the core's first thread.
fn siblings_first(text: []const u8) ?u16 {
    const end = std.mem.indexOfAny(u8, text, ",-\n") orelse text.len;
    return std.fmt.parseInt(u16, text[0..end], 10) catch null;
}

test siblings_first {
    try std.testing.expectEqual(0, siblings_first("0,18\n"));
    try std.testing.expectEqual(4, siblings_first("4-5\n"));
    try std.testing.expectEqual(7, siblings_first("7\n"));
    try std.testing.expectEqual(null, siblings_first(""));
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn pin(cpu: u16) void {
    _ = given(); // Read before narrowing it.
    var set: linux.cpu_set_t = @splat(0);
    const bits = @bitSizeOf(@TypeOf(set[0]));
    set[cpu / bits] = @as(@TypeOf(set[0]), 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch {}; // Best effort: the lock is what counts.
}

/// Lets this process run on the CPUs it was given again (one that holds none, after a pin).
pub fn unpin() void {
    const set = given();
    linux.sched_setaffinity(0, &set) catch {};
}

/// The CPUs' files this process locked (take, give back): a process forked from it has copies,
/// and a lock lives while any copy of its file is open.
var held_fds: [cpus_max]linux.fd_t = @splat(-1);

fn held_note(fd: linux.fd_t) void {
    for (&held_fds) |*slot| if (slot.* < 0) {
        slot.* = fd;
        return;
    };
    unreachable; // One a CPU of the pool's at most.
}

fn held_forget(fd: linux.fd_t) void {
    for (&held_fds) |*slot| if (slot.* == fd) {
        slot.* = -1;
    };
}

/// In a process forked from one that held a CPU (a holder, a disk writer, a replayer), which holds
/// none itself: its copies of the CPUs' files that one locked, closed, and not pinned to them. Kept
/// open, a worker killed holding its CPU (a run's budget stopping its timelines) left the CPU
/// locked by its holders, its claim counted as a running VM's: run 2089's CPUs 4 to 7, four
/// killed workers' 32 GiB each, and the run's last node makers waited for room behind them for
/// good. The forking process's own pool is not used here after (a holder opens one of its own).
pub fn forked_without_cpu() void {
    for (&held_fds) |*fd| if (fd.* >= 0) {
        _ = linux.close(fd.*);
        fd.* = -1;
    };
    unpin();
}

test "a CPU's lock goes with the process that took it, not with what it forked" {
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    const worker = linux.fork();
    if (worker == 0) {
        // A worker takes a CPU of its own pool (as a run's do: a test's pool is its process's)
        // and forks a holder (it sleeps on, holding none); then it is killed holding the CPU, no
        // give (a run's budget stopping its timelines).
        var pool: Pool = undefined;
        pool.open() catch linux.exit_group(1);
        const held = pool.take();
        const cpu: u32 = pool.cpus[held.slot];
        const holder = linux.fork();
        if (holder == 0) {
            forked_without_cpu();
            // Said once it holds none: the test reads the CPU's lock after this, and the worker's
            // end.
            _ = linux.write(pipe_fds[1], std.mem.asBytes(&cpu), @sizeOf(u32));
            _ = linux.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);
            linux.exit_group(0);
        }
        linux.exit_group(0);
    }
    _ = linux.close(pipe_fds[1]);
    var cpu: u32 = undefined;
    try std.testing.expect(linux.read(pipe_fds[0], std.mem.asBytes(&cpu), @sizeOf(u32)) == @sizeOf(u32));
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(worker), &status, 0);
    // The holder lives on: the CPU is free all the same, its claim no longer counted (run 2089's
    // CPUs 4 to 7, locked by four killed workers' holders, counted as 32 GiB VMs each: the run's
    // last node makers waited for room behind them for good).
    var path_buffer: [96]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-cpus-test-{d}", .{worker}, 0);
    const file = try pool_file(directory, "cpu", cpu);
    defer _ = linux.close(file);
    const lock = linux.flock(file, std.posix.LOCK.EX | std.posix.LOCK.NB);
    try std.testing.expect(linux.errno(lock) == .SUCCESS);
    _ = linux.flock(file, std.posix.LOCK.UN);
}

test "pinned, a process still counts and pools the CPUs it was given" {
    const before = usable_count();
    var pool: Pool = undefined;
    try pool.open();
    defer pool.close();
    const held = pool.take(); // Pins this process to one CPU.
    try std.testing.expectEqual(before, usable_count());
    var while_pinned: Pool = undefined;
    try while_pinned.open();
    defer while_pinned.close();
    try std.testing.expectEqual(pool.count, while_pinned.count);
    pool.give(held);
    var mask: linux.cpu_set_t = undefined;
    _ = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
    try std.testing.expectEqualSlices(usize, &given(), &mask); // Unpinned when given back.
}

/// What processes hold outside their VMs' claims (a tree explorer's in-run snapshots, the
/// setup's among them, gigabytes each): `nodes-<pid>` in the pool's directory, its bytes, counted
/// while its process holds its lock. Unclaimed, they filled a host whose VMs fit their claims
/// (Dgraph hunts, srv3 2026-10-28: 20 GB of nodes beside 96 GB of VMs).
var nodes_fd: ?linux.fd_t = null;

/// Sets this process's nodes claim (the bytes of the snapshots it holds).
pub fn nodes_claim(bytes: u64) void {
    const fd = nodes_fd orelse opened: {
        var buffer: [96]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/nodes-{d}", .{
            linux.getuid(), linux.getpid(),
        }, 0) catch return;
        const result = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(result) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(result);
        _ = linux.flock(fd, std.posix.LOCK.EX);
        nodes_fd = fd;
        break :opened fd;
    };
    const value = std.mem.toBytes(bytes);
    _ = linux.pwrite(fd, &value, value.len, 0);
}

/// Removes the turn files (`run-<key>.turn`) of runs whose explorer is gone: a run's key is its
/// explorer's process, and nothing else ever removed one (53,512 in srv4's pool directory from
/// 2026-11-01 to 2026-11-09). Returns how many.
fn turns_sweep(directory: []const u8) u32 {
    var path_buffer: [128]u8 = undefined;
    const directory_z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return 0;
    const opened = linux.open(directory_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const dir: linux.fd_t = @intCast(opened);
    defer _ = linux.close(dir);
    var removed: u32 = 0;
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(dir, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (!std.mem.startsWith(u8, name, "run-")) continue;
            const suffix: []const u8 = if (std.mem.endsWith(u8, name, ".turn")) ".turn" else if (std.mem.endsWith(u8, name, ".whole")) ".whole" else continue;
            const key = std.fmt.parseInt(linux.pid_t, name["run-".len .. name.len - suffix.len], 10) catch continue;
            if (key <= 0 or key == linux.getpid()) continue;
            var proc_buffer: [32]u8 = undefined;
            const proc = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/{d}", .{key}, 0) catch continue;
            if (linux.errno(linux.access(proc, std.posix.F_OK)) == .SUCCESS) continue;
            if (linux.errno(linux.unlinkat(dir, @ptrCast(&entry.name), 0)) == .SUCCESS) removed += 1;
        }
    }
    return removed;
}

test turns_sweep {
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-turns-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(directory, 0o700);
    defer _ = linux.rmdir(directory);
    // A gone run's (a pid above any the kernel gives), this process's own, and another file.
    const names = [_][]const u8{ "run-2147483646.turn", "run-{d}.turn", "cpu-0" };
    var paths: [names.len][96]u8 = undefined;
    var path_lengths: [names.len]usize = undefined;
    for (names, 0..) |name, index| {
        const path = if (index == 1)
            try std.fmt.bufPrint(&paths[index], "{s}/run-{d}.turn", .{ directory, linux.getpid() })
        else
            try std.fmt.bufPrint(&paths[index], "{s}/{s}", .{ directory, name });
        path_lengths[index] = path.len;
        paths[index][path.len] = 0;
        const fd = linux.open(@ptrCast(&paths[index]), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
        _ = linux.close(@intCast(fd));
    }
    defer for (&paths) |*path| {
        _ = linux.unlink(@ptrCast(path));
    };
    try std.testing.expectEqual(@as(u32, 1), turns_sweep(directory));
    try std.testing.expect(linux.errno(linux.access(@ptrCast(&paths[0]), std.posix.F_OK)) != .SUCCESS);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.access(@ptrCast(&paths[1]), std.posix.F_OK)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.access(@ptrCast(&paths[2]), std.posix.F_OK)));
}

/// Every live process's nodes claim, in bytes; a dead process's file is removed.
fn nodes_claimed(directory: []const u8) u64 {
    if (directory.len == 0) return 0;
    var path_buffer: [128]u8 = undefined;
    const directory_z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const opened = linux.open(directory_z, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const dir: linux.fd_t = @intCast(opened);
    defer _ = linux.close(dir);
    var total: u64 = 0;
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(dir, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (!std.mem.startsWith(u8, name, "nodes-")) continue;
            const name_z: [*:0]const u8 = @ptrCast(&entry.name);
            const file = linux.openat(dir, name_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(file) != .SUCCESS) continue;
            const fd: linux.fd_t = @intCast(file);
            defer _ = linux.close(fd);
            if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) {
                // Nobody holds it: its process is gone, or has just made it (not locked yet).
                var proc_buffer: [32]u8 = undefined;
                const proc = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/{s}", .{name["nodes-".len..]}, 0) catch continue;
                if (linux.errno(linux.access(proc, std.posix.F_OK)) != .SUCCESS) _ = linux.unlinkat(dir, name_z, 0);
                continue;
            }
            var value: [8]u8 = @splat(0);
            if (linux.pread(fd, &value, value.len, 0) == value.len) total += std.mem.bytesToValue(u64, &value);
        }
    }
    return total;
}

/// The nodes claim of one process (nodes-<pid> in the pool's directory: an explorer's, its run's
/// key), while that process holds it; 0 without one.
fn nodes_of(directory: []const u8, pid: u64) u64 {
    if (directory.len == 0) return 0;
    var path_buffer: [160]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/nodes-{d}", .{ directory, pid }, 0) catch return 0;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    // Nobody holds it: its process is gone (nodes_claimed removes it), or has just made it.
    if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) return 0;
    var value: [8]u8 = @splat(0);
    if (linux.pread(fd, &value, value.len, 0) != value.len) return 0;
    return std.mem.bytesToValue(u64, &value);
}

/// Whether `bytes` more fit: within the claims (the VMs holding CPUs, each its guest's size) and
/// the reserve, and there now (`available`, 0 when unknown): claims miss what holds memory
/// without a CPU (holders, in-run snapshots, host checks' services), and a check beside a hunt
/// once fit its claims while the host ran out (srv3, 2026-10-28: the OOM killer took a hunt's
/// timeline and podman's pause process).
fn fits(claimed: u64, bytes: u64, total: u64, available: u64, reserve: u64) bool {
    if (claimed + bytes + reserve > total) return false;
    return available == 0 or bytes + reserve <= available;
}

test fits {
    const gib = 1 << 30;
    const reserve = memory_reserve_bytes;
    try std.testing.expect(fits(100 * gib, 7 * gib, 125 * gib, 40 * gib, reserve));
    try std.testing.expect(!fits(112 * gib, 7 * gib, 125 * gib, 40 * gib, reserve)); // Past the claims.
    try std.testing.expect(!fits(60 * gib, 7 * gib, 125 * gib, 12 * gib, reserve)); // Not there now.
    try std.testing.expect(fits(60 * gib, 7 * gib, 125 * gib, 0, reserve)); // Unknown: the claims alone.
    // A run leaves the sessions' memory: what a check could take, a run waits for.
    try std.testing.expect(fits(60 * gib, 2 * gib, 125 * gib, 12 * gib, reserve));
    try std.testing.expect(!fits(60 * gib, 2 * gib, 125 * gib, 12 * gib, reserve + 12 * gib));
}

test "a small host keeps an eighth of its memory free" {
    const gib = 1 << 30;
    try std.testing.expect(fits(0, 2 * gib, 8 * gib, 0, host_reserve(8 * gib))); // A 2 GB VM on 8 GB.
    try std.testing.expect(!fits(6 * gib, 2 * gib, 8 * gib, 0, host_reserve(8 * gib))); // Not beside 6 GB.
    // srv4's: a twelfth since it thrashed at 12 GB available (2026-11-17).
    try std.testing.expectEqual(@as(u64, 187 * gib / 12), host_reserve(187 * gib));
}

test "a VM's memory claim counts while its CPU is held" {
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    holder.available_counts = false; // The claims' accounting alone (fits has the rest).
    other.available_counts = false;
    // The host's: claims are host-wide, whatever this test's cgroup limit (a check's unit).
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2;
    const held = holder.take(); // Claims half the host.
    try std.testing.expect(!other.claim_fits(total / 2)); // Half more, and the reserve: no.
    try std.testing.expect(other.claim_fits(1 << 20));
    holder.give(held);
    try std.testing.expect(other.claim_fits(total / 2)); // Given back: its claim no longer counts.
}

test "another run's VMs count at what their run learned they hold" {
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved_key = run_key;
    defer run_key = saved_key;
    const saved_bytes = claim_bytes;
    defer claim_bytes = saved_bytes;
    const saved_shares = claim_shares;
    defer claim_shares = saved_shares;
    // Two runs of one host: a hunt's VMs branching from its snapshot, and another run looking.
    const hunt_key: linux.pid_t = linux.getpid() + 100000;
    const other_key: linux.pid_t = linux.getpid() + 200000;
    var hunt: Pool = undefined;
    run_key = hunt_key;
    try hunt.open();
    defer hunt.close();
    var other: Pool = undefined;
    run_key = other_key;
    try other.open();
    defer other.close();
    hunt.available_counts = false; // The claims' accounting alone (fits has the rest).
    other.available_counts = false;
    claim_bytes = total / 2; // Its guests' size: half the host.
    claim_shares = true;
    hunt.claim_soft_set(1 << 20); // What the hunt learned each of its VMs holds: 1 MiB.
    run_key = hunt_key;
    const held = hunt.take();
    run_key = other_key;
    // Counted as the hunt learned, not as its guests' size (run 2122: 210 GiB of a 187.6 GiB
    // host claimed by 35 VMs that held 2.4 GiB each, nothing else admitted beside it).
    try std.testing.expect(other.claim_fits(total / 2));
    hunt.claim_soft_set(0); // Taken back: its guests' size again.
    try std.testing.expect(!other.claim_fits(total / 2));
    run_key = hunt_key;
    hunt.give(held);
}

/// What a run learns its VMs come to hold, from the host's memory while they run. A claim is a
/// guest's size, what a VM may come to hold: a run whose VMs stay far under it kept its last
/// worker waiting for memory the host had (run 2067: 40 workers of 4 GiB guests, 39 CPUs held
/// in every look, 169.3 GiB claimed of the 171.9 that may be, 110 GB available; 6.5% of the
/// workers' time), and larger guests more (8 GiB: 40,472 s of a run 2060).
pub const ClaimLearning = struct {
    /// The most one of the run's VMs held of its own at a look counted (sample): its whole run's,
    /// never lowered. Over a window of the last ten minutes' looks, a judgment of more than that
    /// (its VMs young, or few) took it down: ParadeDB's run 2098 went from 4.0 to 2.2 GiB at its
    /// generation 2's, as it was about to admit VMs that grow to 2.7 GiB each.
    held_max: u64 = 0,
    /// Before as many timelines ended as the run has workers: what its VMs held at its last
    /// plateau_looks looks counted, the oldest next written.
    recent: [plateau_looks]u64 = @splat(0),
    recent_count: u32 = 0,
    /// The run said a claim under its guests' size.
    softened: bool = false,
    /// Its workers without a timeline wait on memory at this look (the explorer sets it).
    memory_idle: bool = false,
    /// Memory ran short after that: its claims are its guests' size until this many timelines
    /// ended (as many more as it has workers), then half again more room than before each time
    /// (margin_halves). For good, one short look cost a run its learned claim for hours.
    backoff_until: u64 = 0,
    /// The claim is what one held at most times (2 + margin_halves) / 2: half again at first.
    margin_halves: u32 = 1,
    /// What the run's last look counted (sample): timelines ended, workers.
    ended_seen: u64 = 0,
    jobs_seen: u32 = 0,

    /// A look at the run's VMs: `held`, the most one of its timeline processes holds of its own
    /// (its anonymous memory: the pages its guest wrote, its VMM's, and the explorer's it shares
    /// since its fork, so a little high; not the snapshot's pages it reads, counted once as the
    /// nodes'), beside `admitted` VMs of the run (holding a CPU: Pool.run_held), `workers` of its
    /// `jobs` having a timeline, `ended` timelines so far. Counted once as many timelines ended as
    /// the run has workers (its VMs seen whole, not young), while every worker has a timeline and
    /// one of its VMs runs. The host's memory in use less the nodes', over the VMs admitted,
    /// counted the holders, serve and other runs on a few VMs: ParadeDB's run 2095 went back to
    /// its 32 GiB guests from 23 GiB "a VM" with 1 or 2 admitted, while its one running VM held
    /// 2.25 GB of its own; 1 VM at a time for hours.
    /// Before as many timelines ended as it has workers, it learns once what its VMs hold stopped
    /// growing: no more than plateau_growth over a minute of looks (claims_look's every 5 s). A
    /// run of long timelines waited hours for its workers' count of ends at its guests' size:
    /// ParadeDB's proptests (run 2098), 13 minutes a timeline, 4 VMs of 32 GiB for 2.5 hours,
    /// while each held its 2.6 GB of its own within its first 2 minutes (and 2.7 GB at most).
    pub fn sample(learning: *ClaimLearning, held: u64, admitted: u32, workers: u32, jobs: u32, ended: u64) void {
        learning.ended_seen = ended;
        learning.jobs_seen = jobs;
        if (admitted == 0) return;
        // Learned: never less than one holds, however many workers have a timeline (filler held
        // for a judgment's makers leaves some idle while the VMs running grow).
        if (learning.held_max != 0) learning.held_max = @max(learning.held_max, held);
        if (workers < jobs) return;
        // With workers idle on memory a first claim waits for the plateau below, however many
        // ended: the few VMs admitted may all be young, and one look at one would set it.
        if (ended >= jobs and (!learning.memory_idle or learning.held_max != 0)) {
            learning.held_max = @max(learning.held_max, held);
            return;
        }
        // The look plateau_looks ago, overwritten by this one.
        const at = learning.recent_count % plateau_looks;
        const before = learning.recent[at];
        learning.recent[at] = held;
        learning.recent_count += 1;
        if (learning.recent_count <= plateau_looks) return;
        if (held > before + before / plateau_growth) return; // Still growing.
        var most: u64 = 0;
        for (learning.recent) |look| most = @max(most, look);
        learning.held_max = @max(learning.held_max, most);
    }

    /// A minute of looks (claims_look_ns apart), over which what the VMs hold has stopped growing
    /// when it grew by no more than a fiftieth.
    pub const plateau_looks = 13;
    const plateau_growth = 50;

    /// The claim to say for a VM of `guest` bytes: half again what one held at most (more after
    /// memory ran short); 0 (its guest's size) while nothing is learned, where that is no less,
    /// and while memory backs off (short).
    pub fn claim(learning: *ClaimLearning, guest: u64) u64 {
        const claimed = learning.learned(guest);
        if (claimed != 0) learning.softened = true;
        return claimed;
    }

    /// What claim says, without saying it (a node maker's room, main.zig).
    pub fn learned(learning: *const ClaimLearning, guest: u64) u64 {
        if (learning.held_max == 0 or learning.ended_seen < learning.backoff_until) return 0;
        const claimed = learning.held_max / 2 * (2 + @as(u64, learning.margin_halves));
        return if (claimed >= guest) 0 else claimed;
    }

    /// Whether memory is short on a run that claimed less than its guests' size: `available`
    /// under half the `reserve`. Its claims are its guests' size until as many more timelines
    /// ended as it has workers, then with half again more room (a new short after that backs off
    /// again, with more room still); while this says yes its explorer ends its youngest VM, one
    /// a look (it runs again once memory allows).
    pub fn short(learning: *ClaimLearning, available: u64, reserve: u64) bool {
        if (!learning.softened) return false;
        if (available == 0 or available >= reserve / 2) return false;
        // A new back-off (not one going on): more room after it.
        if (learning.ended_seen >= learning.backoff_until) learning.margin_halves += 1;
        learning.backoff_until = learning.ended_seen + learning.jobs_seen;
        return true;
    }
};

test "a run learns what its VMs hold once enough ended, and claims half again" {
    const gib: u64 = 1 << 30;
    var learning: ClaimLearning = .{};
    try std.testing.expectEqual(@as(u64, 0), learning.claim(4 * gib)); // Nothing learned.
    learning.sample(2 * gib, 40, 40, 40, 39); // Fewer timelines ended than workers: young VMs.
    try std.testing.expectEqual(@as(u64, 0), learning.claim(4 * gib));
    learning.sample(2 * gib, 20, 20, 40, 400); // Half its workers without a timeline: not counted.
    try std.testing.expectEqual(@as(u64, 0), learning.claim(4 * gib));
    learning.sample(2 * gib, 0, 40, 40, 400); // None of its VMs running: nothing to read.
    try std.testing.expectEqual(@as(u64, 0), learning.claim(4 * gib));
    // Run 2067's: VMs holding 2 GiB, 39 admitted of 40 workers with a timeline.
    learning.sample(2 * gib, 39, 40, 40, 400);
    try std.testing.expectEqual(3 * gib, learning.claim(4 * gib));
    learning.sample(gib, 40, 40, 40, 500); // Less later: what one held at most stays.
    try std.testing.expectEqual(3 * gib, learning.claim(4 * gib));
    try std.testing.expectEqual(@as(u64, 0), learning.claim(3 * gib)); // No less than the guest.
    // Guests that fill their memory (8 GiB ones holding 6): their guest's size.
    var large: ClaimLearning = .{};
    large.sample(6 * gib, 20, 40, 40, 400);
    try std.testing.expectEqual(@as(u64, 0), large.claim(8 * gib));
}

test "what a run's VM holds of its own, not the host's memory over the VMs admitted" {
    const kib: u64 = 1 << 10;
    const gib: u64 = 1 << 30;
    // ParadeDB's run 2095 at its 64th timeline: 135.4 GiB of nodes, holders in memory and on
    // disk, 1 VM admitted, 40 workers with a timeline; the VM's own memory 2,247,596 kB. Half
    // again: 3.2 GiB of its 32 GiB guest, where the host's memory in use over its VM gave 23.
    var learning: ClaimLearning = .{};
    learning.sample(2_247_596 * kib, 1, 40, 40, 64);
    const claim = learning.claim(32 * gib);
    try std.testing.expect(claim > 3 * gib and claim < 4 * gib);
}

test "what a VM held at most stays, however long the run's VMs are young after (a judgment)" {
    const gib: u64 = 1 << 30;
    const mib: u64 = 1 << 20;
    var learning: ClaimLearning = .{};
    // ParadeDB's run 2098: VMs grown to 2.7 GiB of their own (a claim of 4.0), then a judgment
    // of more than ten minutes, its VMs young (1.5 GiB) at every look.
    learning.sample(2765 * mib, 34, 40, 40, 60);
    const grown = learning.claim(32 * gib);
    try std.testing.expect(grown > 4 * gib - gib / 8 and grown < 4 * gib + gib / 8);
    for (0..1000) |_| learning.sample(1536 * mib, 3, 40, 40, 109);
    try std.testing.expectEqual(grown, learning.claim(32 * gib));
}

test "before its workers' count of timelines ended, a run learns once what its VMs hold stopped growing" {
    const mib: u64 = 1 << 20;
    const gib: u64 = 1 << 30;
    // ParadeDB's run 2098: 4 VMs admitted of 40 workers, none ended; its VMs at 2.2, 2.4, 2.55
    // then 2.6 GB of their own.
    var learning: ClaimLearning = .{};
    for ([_]u64{ 2200, 2400, 2550 }) |held| learning.sample(held * mib, 4, 40, 40, 0);
    try std.testing.expectEqual(@as(u64, 0), learning.claim(32 * gib)); // Growing: not yet.
    for (0..ClaimLearning.plateau_looks - 3) |_| learning.sample(2600 * mib, 4, 40, 40, 0);
    try std.testing.expectEqual(@as(u64, 0), learning.claim(32 * gib)); // Less than a minute flat.
    for (0..3) |_| learning.sample(2600 * mib, 4, 40, 40, 0);
    try std.testing.expectEqual(3900 * mib, learning.claim(32 * gib));
    // Memory that grows slowly, a hundredth a look: never flat, learned only once as many
    // timelines ended as workers.
    var slow: ClaimLearning = .{};
    var held: u64 = 2000 * mib;
    for (0..200) |_| {
        slow.sample(held, 4, 40, 40, 10);
        held += held / 100;
    }
    try std.testing.expectEqual(@as(u64, 0), slow.claim(32 * gib));
    slow.sample(held, 4, 40, 40, 40);
    try std.testing.expect(slow.claim(32 * gib) != 0);
    // Workers without a timeline, or none of its VMs admitted: nothing counted.
    var idle: ClaimLearning = .{};
    for (0..100) |_| idle.sample(2 * gib, 0, 40, 40, 0);
    for (0..100) |_| idle.sample(2 * gib, 4, 20, 40, 0);
    try std.testing.expectEqual(@as(u64, 0), idle.claim(32 * gib));
}

test "memory short under a learned claim: the guest's size for a round of timelines, then more room" {
    const gib: u64 = 1 << 30;
    var hard: ClaimLearning = .{};
    hard.sample(4 * gib, 40, 40, 40, 400); // 4 GiB a VM: half again is past the guest.
    try std.testing.expectEqual(@as(u64, 0), hard.claim(4 * gib));
    try std.testing.expect(!hard.short(2 * gib, 16 * gib)); // Its claims were its guests': not its doing.
    var learning: ClaimLearning = .{};
    learning.sample(2 * gib, 39, 40, 40, 400);
    try std.testing.expectEqual(3 * gib, learning.claim(16 * gib));
    try std.testing.expect(!learning.short(9 * gib, 16 * gib)); // Half the reserve is there.
    try std.testing.expect(!learning.short(0, 16 * gib)); // Unknown: never a reason.
    try std.testing.expect(learning.short(7 * gib, 16 * gib));
    try std.testing.expectEqual(@as(u64, 0), learning.claim(16 * gib));
    try std.testing.expect(learning.short(7 * gib, 16 * gib)); // Still short: yes again.
    try std.testing.expect(!learning.short(40 * gib, 16 * gib));
    // The guest's size until 40 more timelines ended (its workers), then twice what one held.
    learning.sample(2 * gib, 39, 40, 40, 439);
    try std.testing.expectEqual(@as(u64, 0), learning.claim(16 * gib));
    learning.sample(2 * gib, 39, 40, 40, 440);
    try std.testing.expectEqual(4 * gib, learning.claim(16 * gib));
    // Short again: a new back-off, then two and a half times.
    try std.testing.expect(learning.short(7 * gib, 16 * gib));
    try std.testing.expectEqual(@as(u64, 0), learning.claim(16 * gib));
    learning.sample(2 * gib, 39, 40, 40, 480);
    try std.testing.expectEqual(5 * gib, learning.claim(16 * gib));
    // Until it would be its guest's size (twice what one held, plus 14 halves): its guest's size.
    for (0..12) |round| {
        try std.testing.expect(learning.short(7 * gib, 16 * gib));
        learning.sample(2 * gib, 39, 40, 40, 520 + 40 * @as(u64, round));
    }
    try std.testing.expectEqual(@as(u64, 0), learning.claim(16 * gib));
}

test "a run none of whose VMs runs starts one beside its own nodes, whatever the claims" {
    var pool: Pool = undefined;
    try pool.open();
    defer pool.close();
    pool.available_counts = false; // The claims' accounting alone.
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 4;
    // This run's nodes fill the host (run 2091's 134.5 GiB): no claim fits beside them.
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/nodes-{d}", .{ pool.directory_buffer[0..pool.directory_size], run_of_this_process() }, 0);
    const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const fd: linux.fd_t = @intCast(opened);
    defer {
        _ = linux.close(fd);
        _ = linux.unlink(path);
    }
    _ = linux.flock(fd, std.posix.LOCK.EX);
    const nodes = std.mem.toBytes(total);
    _ = linux.pwrite(fd, &nodes, nodes.len, 0);
    try std.testing.expect(!pool.claim_fits(pool.claim_now()));
    // None of its VMs runs: one starts.
    try std.testing.expectEqual(@as(u32, 0), pool.run_held());
    try std.testing.expect(pool.memory_fits());
    const held = pool.take();
    defer pool.give(held);
    // One runs: the claims decide again, and the next waits.
    try std.testing.expect(!pool.memory_fits());
}

test "a run's VMs count as what the run learned they hold, another run's as its guest" {
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    holder.available_counts = false; // The claims' accounting alone.
    other.available_counts = false;
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2;
    defer holder.claim_soft_set(0);
    claim_shares = true; // A tree's branches.
    defer claim_shares = false;
    try std.testing.expectEqual(@as(u32, 0), other.run_held());
    const held = holder.take(); // A VM of half the host, of this run.
    try std.testing.expectEqual(@as(u32, 1), other.run_held());
    try std.testing.expect(!other.claim_fits(total / 2));
    try std.testing.expectEqual(total / 2, other.claim_now());
    try std.testing.expect(!other.room(1)); // The gate's question (Pool.room), the same claims.
    // The run learned its VMs hold an eighth of the host: the VM running counts as that, and
    // the next one asks for that.
    holder.claim_soft_set(total / 8);
    try std.testing.expectEqual(total / 8, other.claim_now());
    try std.testing.expect(other.claim_fits(total / 2));
    try std.testing.expect(other.room(1) and !other.room(8));
    // A VM of another run on that CPU: its guest's size, whatever this run learned.
    const elsewhere: u64 = run_of_this_process() + 1;
    _ = linux.pwrite(holder.fds[held.slot], std.mem.asBytes(&elsewhere), @sizeOf(u64), @offsetOf(CpuClaim, "run"));
    try std.testing.expect(!other.claim_fits(total / 2));
    try std.testing.expectEqual(@as(u32, 0), other.run_held());
    // Its own again, and the run's claim taken back (memory ran short): the guest's size.
    const mine: u64 = run_of_this_process();
    _ = linux.pwrite(holder.fds[held.slot], std.mem.asBytes(&mine), @sizeOf(u64), @offsetOf(CpuClaim, "run"));
    try std.testing.expect(other.claim_fits(total / 2));
    holder.claim_soft_set(0);
    try std.testing.expect(!other.claim_fits(total / 2));
    try std.testing.expectEqual(total / 2, other.claim_now());
    // Given back, the CPU's file names no run.
    holder.give(held);
    var claim: CpuClaim = .{};
    _ = linux.pread(holder.fds[held.slot], std.mem.asBytes(&claim), @sizeOf(CpuClaim), 0);
    try std.testing.expectEqual(total / 2, claim.bytes);
    try std.testing.expectEqual(@as(u64, 0), claim.run);
}

test "a VM holding its whole memory claims its guest's size, whatever its run learned" {
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    holder.available_counts = false; // The claims' accounting alone.
    other.available_counts = false;
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2;
    defer holder.claim_soft_set(0);
    // The run learned its branches hold an eighth of the host; a VM of it booted afresh (its
    // verifier's replay, as in ParadeDB's run 2096) holds half: it counts as half, and asks for it.
    holder.claim_soft_set(total / 8);
    const held = holder.take();
    defer holder.give(held);
    try std.testing.expect(!other.claim_fits(total / 2));
    try std.testing.expectEqual(total / 2, other.claim_now());
    // Its branches' processes: the learned claim, for their own VMs and the next.
    claim_shares = true;
    defer claim_shares = false;
    try std.testing.expectEqual(total / 8, other.claim_now());
    try std.testing.expect(!other.claim_fits(total / 2)); // The replay still holds its half.
}

test "a CPU is held by one process at a time, and given back" {
    var first: Pool = undefined;
    try first.open();
    defer first.close();
    var second: Pool = undefined;
    try second.open();
    defer second.close();
    const held = first.take();
    // The same CPU is taken: another process (another open file) finds another, or waits.
    const lock = linux.flock(second.fds[held.slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
    try std.testing.expect(linux.errno(lock) == .AGAIN);
    first.give(held);
    const again = linux.flock(second.fds[held.slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
    try std.testing.expect(linux.errno(again) == .SUCCESS);
    _ = linux.flock(second.fds[held.slot], std.posix.LOCK.UN);
    unpin();
}

/// The pool's slot of a CPU, by its number (each pool orders the same CPUs alike).
fn test_slot_of(pool: *const Pool, cpu: u16) u32 {
    for (pool.cpus[0..pool.count], 0..) |candidate, index| {
        if (candidate == cpu) return @intCast(index);
    }
    unreachable;
}

test "fast machines share a CPU up to their number, and a deterministic VM never one of theirs" {
    var machines: [3]Pool = undefined;
    for (&machines) |*pool| try pool.open();
    defer for (&machines) |*pool| pool.close();
    var timeline: Pool = undefined;
    try timeline.open();
    defer timeline.close();
    if (timeline.count < 3) return error.SkipZigTest;
    for (&machines) |*pool| pool.available_counts = false;
    timeline.available_counts = false;
    const saved_number = machines_per_cpu;
    defer machines_per_cpu = saved_number;
    machines_per_cpu = 2;
    const saved_claim = claim_bytes;
    defer claim_bytes = saved_claim;
    claim_bytes = 1 << 20;
    defer unpin();
    // Two machines: one CPU.
    const first = machines[0].take_shared();
    const second = machines[1].take_shared();
    const theirs = machines[0].cpus[first.slot];
    try std.testing.expectEqual(theirs, machines[1].cpus[second.slot]);
    // A deterministic VM: a CPU of its own, not the machines'.
    const own = timeline.take();
    try std.testing.expect(timeline.cpus[own.slot] != theirs);
    // The machines' CPU has its two: a third machine opens another, not the deterministic VM's.
    const third = machines[2].take_shared();
    const another = machines[2].cpus[third.slot];
    try std.testing.expect(another != theirs);
    try std.testing.expect(another != timeline.cpus[own.slot]);
    // Asked exclusively, the machines' CPU is refused while one of them is there.
    const asked = timeline.fds[test_slot_of(&timeline, theirs)];
    try std.testing.expect(linux.errno(linux.flock(asked, std.posix.LOCK.EX | std.posix.LOCK.NB)) == .AGAIN);
    machines[0].give(first);
    try std.testing.expect(linux.errno(linux.flock(asked, std.posix.LOCK.EX | std.posix.LOCK.NB)) == .AGAIN);
    // A machine that comes now joins the one left there (the fewest of the CPUs with room).
    const again = machines[0].take_shared();
    try std.testing.expectEqual(theirs, machines[0].cpus[again.slot]);
    machines[0].give(again);
    machines[1].give(second);
    // The last gone, it is anyone's.
    try std.testing.expect(linux.errno(linux.flock(asked, std.posix.LOCK.EX | std.posix.LOCK.NB)) == .SUCCESS);
    _ = linux.flock(asked, std.posix.LOCK.UN);
    // Nor does a machine take the CPU a deterministic VM holds: with every other CPU's places
    // taken it would wait, so asked of that CPU alone, it finds no place.
    var counts: [cpus_max]u16 = @splat(0);
    _ = machines_scan(machines[2].directory_buffer[0..machines[2].directory_size], &counts);
    try std.testing.expectEqual(@as(u16, 1), counts[another]);
    try std.testing.expectEqual(@as(u16, 0), counts[timeline.cpus[own.slot]]);
    const held_exclusively = machines[0].fds[test_slot_of(&machines[0], timeline.cpus[own.slot])];
    try std.testing.expect(linux.errno(linux.flock(held_exclusively, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .AGAIN);
    machines[2].give(third);
    timeline.give(own);
}

test "a machine's memory claim counts while it has its place, and a gone machine's file goes" {
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    holder.available_counts = false; // The claims' accounting alone (fits has the rest).
    other.available_counts = false;
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2;
    defer unpin();
    const held = holder.take_shared(); // Claims half the host.
    try std.testing.expect(!other.claim_fits(total / 2)); // Half more, and the reserve: no.
    try std.testing.expect(other.claim_fits(1 << 20));
    holder.give(held);
    try std.testing.expect(other.claim_fits(total / 2)); // Its place given back: no claim.
    // A place file whose machine is gone (a pid above any the kernel gives), held by no one.
    const directory = holder.directory_buffer[0..holder.directory_size];
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/machine-2147483646-0", .{directory}, 0);
    const made = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    try std.testing.expect(linux.errno(made) == .SUCCESS);
    const place: MachinePlace = .{ .claim_bytes = total, .cpu = holder.cpus[0] };
    _ = linux.pwrite(@intCast(made), std.mem.asBytes(&place), @sizeOf(MachinePlace), 0);
    _ = linux.close(@intCast(made));
    var counts: [cpus_max]u16 = @splat(0);
    try std.testing.expectEqual(@as(u64, 0), machines_scan(directory, &counts));
    try std.testing.expectEqual(@as(u16, 0), counts[holder.cpus[0]]);
    try std.testing.expect(linux.errno(linux.access(path, std.posix.F_OK)) != .SUCCESS);
}

var test_give_up_at_ns: u64 = 0;
fn test_give_up() bool {
    return monotonic_ns() >= test_give_up_at_ns;
}

var test_give_up_calls: u32 = 0;
fn test_give_up_counted() bool {
    test_give_up_calls += 1;
    return monotonic_ns() >= test_give_up_at_ns;
}

test "a maker waiting for memory sleeps between its looks" {
    // A claim the host never fits: the take waits for memory until it gives up.
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = meminfo("MemTotal:") * 2;
    if (claim_bytes == 0) return error.SkipZigTest;
    var maker: Pool = undefined;
    try maker.open();
    defer maker.close();
    maker.first = true;
    const waited_ns = 300 * std.time.ns_per_ms;
    test_give_up_calls = 0;
    test_give_up_at_ns = monotonic_ns() + waited_ns;
    try std.testing.expect(maker.take_unless(test_give_up_counted) == null);
    // A look every wait_ns_max: ten in 300 ms, where the loop without its sleep made thousands.
    try std.testing.expect(test_give_up_calls <= waited_ns / wait_ns_max + 2);
}

test "a VM that holds its whole memory waits in a queue of its own, never before the run's branches" {
    // A replay of the run's verifier holds its queue, waiting for room for its guest.
    var replay: Pool = undefined;
    try replay.open();
    defer replay.close();
    const whole = replay.queue_for(false);
    try std.testing.expect(linux.errno(linux.flock(whole, std.posix.LOCK.EX)) == .SUCCESS);
    defer _ = linux.flock(whole, std.posix.LOCK.UN);
    // A branch of the run takes a CPU meanwhile.
    claim_shares = true;
    defer claim_shares = false;
    var branch: Pool = undefined;
    try branch.open();
    defer branch.close();
    test_give_up_at_ns = monotonic_ns() + 2 * std.time.ns_per_s;
    const held = branch.take_unless(test_give_up) orelse return error.BranchWaitedForTheReplay;
    branch.give(held);
    unpin();
}

test "a judgment's maker takes a CPU past its run's turn, a plain take waits behind it" {
    // Another of the run's processes holds its turn, as a timeline waiting for a CPU does.
    var waiting: Pool = undefined;
    try waiting.open();
    defer waiting.close();
    try std.testing.expect(linux.errno(linux.flock(waiting.turn_fd, std.posix.LOCK.EX)) == .SUCCESS);
    var turn_held = true;
    defer if (turn_held) {
        _ = linux.flock(waiting.turn_fd, std.posix.LOCK.UN);
    };
    // A maker (first) goes past it and takes a CPU.
    var maker: Pool = undefined;
    try maker.open();
    defer maker.close();
    maker.first = true;
    test_give_up_at_ns = monotonic_ns() + 2 * std.time.ns_per_s;
    const held = maker.take_unless(test_give_up) orelse return error.MakerWaited;
    maker.give(held);
    unpin();
    // A plain take of the run's branches queues behind that turn (asleep in the kernel): nothing
    // while it is held.
    claim_shares = true;
    defer claim_shares = false;
    var plain: Pool = undefined;
    try plain.open();
    defer plain.close();
    test_give_up_at_ns = monotonic_ns(); // Once past the turn: given up at once.
    var plain_done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(pool: *Pool, done: *std.atomic.Value(bool)) void {
            _ = pool.take_unless(test_give_up);
            done.store(true, .release);
        }
    }.run, .{ &plain, &plain_done });
    const pause: linux.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null);
    try std.testing.expect(!plain_done.load(.acquire));
    _ = linux.flock(waiting.turn_fd, std.posix.LOCK.UN);
    turn_held = false;
    thread.join();
    try std.testing.expect(plain_done.load(.acquire));
}

test "a take queued behind its run's waiter for memory books that wait as memory's" {
    // The host's: claims are host-wide, whatever this test's cgroup limit (a check's unit).
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2; // One VM's claim fits at a time.
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var front: Pool = undefined;
    try front.open();
    defer front.close();
    var queued: Pool = undefined;
    try queued.open();
    defer queued.close();
    for ([_]*Pool{ &holder, &front, &queued }) |pool| pool.available_counts = false;
    const held = holder.take();
    unpin();
    var holder_given = false;
    defer if (!holder_given) holder.give(held);
    const Take = struct {
        fn run(pool: *Pool, out: *?Held) void {
            out.* = pool.take_unless(Pool.never);
            unpin();
        }
    };
    // The front takes the run's turn and waits for memory (the holder's claim leaves no room);
    // the other queues behind the turn meanwhile.
    var front_held: ?Held = null;
    const front_thread = try std.Thread.spawn(.{}, Take.run, .{ &front, &front_held });
    const settle: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&settle, null);
    var queued_held: ?Held = null;
    const queued_thread = try std.Thread.spawn(.{}, Take.run, .{ &queued, &queued_held });
    const blocked: linux.timespec = .{ .sec = 0, .nsec = 400 * std.time.ns_per_ms };
    _ = linux.nanosleep(&blocked, null);
    holder.give(held);
    holder_given = true;
    front_thread.join();
    front.give(front_held.?); // The queued one's claim fits now: it takes a CPU at once.
    queued_thread.join();
    const taken = queued_held.?;
    defer queued.give(taken);
    // Some 400 ms queued while the front waited for memory: memory's, not a CPU's.
    try std.testing.expect(taken.memory_wait_ns >= 300 * std.time.ns_per_ms);
    try std.testing.expect(taken.cpu_wait_ns < taken.memory_wait_ns);
}

test "a check waiting for memory is seen by the runs" {
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(directory, 0o700);
    try std.testing.expect(!memory_priority_waiting());
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/memory-priority", .{directory}, 0);
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const waiter: linux.fd_t = @intCast(linux.open(path, flags, 0o600));
    defer _ = linux.close(waiter);
    _ = linux.flock(waiter, std.posix.LOCK.SH); // The check, waiting.
    try std.testing.expect(memory_priority_waiting());
    _ = linux.flock(waiter, std.posix.LOCK.UN); // Served.
    try std.testing.expect(!memory_priority_waiting());
}

test "the room an explorer's node makers wait for is seen by the host's holders, while they wait" {
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(directory, 0o700);
    const gib = 1 << 30;
    try std.testing.expectEqual(@as(u64, 0), makers_wanted());
    makers_want(8 * gib); // One in flight and the next: two claims of 4 GB.
    try std.testing.expectEqual(@as(u64, 8 * gib), makers_wanted());
    makers_want(12 * gib); // The next started, one more waits.
    try std.testing.expectEqual(@as(u64, 12 * gib), makers_wanted());
    // Seen from another process too, through a description of its own (opened here by the
    // path: a test's directory is named by its process).
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/makers-wanted", .{directory}, 0);
    const pid = linux.fork();
    if (pid == 0) {
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
        makers_wanted_fd = @intCast(linux.open(path, flags, 0o600));
        linux.exit_group(if (makers_wanted() == 12 * gib) 0 else 1);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    try std.testing.expectEqual(@as(i32, 0), status);
    makers_want_end(); // None waits.
    try std.testing.expectEqual(@as(u64, 0), makers_wanted());
    makers_want_end();
    // Another process asking at this instant (its shared hold) is not an explorer's want; and
    // an explorer's want waits for it to be over, tried again at its next look.
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const asking: linux.fd_t = @intCast(linux.open(path, flags, 0o600));
    defer _ = linux.close(asking);
    _ = linux.flock(asking, std.posix.LOCK.SH);
    try std.testing.expectEqual(@as(u64, 0), makers_wanted());
    makers_want(4 * gib);
    _ = linux.flock(asking, std.posix.LOCK.UN);
    try std.testing.expectEqual(@as(u64, 0), makers_wanted());
    makers_want(4 * gib);
    try std.testing.expectEqual(@as(u64, 4 * gib), makers_wanted());
    makers_want_end();
    try std.testing.expectEqual(@as(u64, 0), makers_wanted());
}

test "a cgroup's limit and what is free under it" {
    var path_buffer: [64]u8 = undefined;
    const level_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-cgroup-test-{d}", .{linux.getpid()}, 0);
    const level: []const u8 = level_z;
    _ = linux.mkdir(level_z, 0o755);
    defer _ = linux.rmdir(level_z);
    const files = [_][2][]const u8{
        .{ "memory.max", "25769803776\n" },
        .{ "memory.current", "10737418240\n" },
        .{ "memory.stat", "anon 6442450944\nfile 4294967296\ninactive_file 2147483648\nactive_file 1073741824\n" },
    };
    for (files) |file| {
        var file_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ level, file[0] }, 0);
        const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.write(@intCast(fd), file[1].ptr, file[1].len);
        _ = linux.close(@intCast(fd));
    }
    defer for (files) |file| {
        var file_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ level, file[0] }, 0) catch unreachable;
        _ = linux.unlink(path);
    };
    try std.testing.expectEqual(24 << 30, cgroup_number(level, "memory.max").?);
    try std.testing.expectEqual(10 << 30, cgroup_number(level, "memory.current").?);
    try std.testing.expectEqual(2 << 30, cgroup_stat(level, "inactive_file "));
    try std.testing.expectEqual(0, cgroup_stat(level, "shmem "));
    try std.testing.expectEqual(null, cgroup_number(level, "memory.high")); // Not there.
}
