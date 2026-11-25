// SPDX-License-Identifier: MIT
//! det-selftest: determinismo testing itself through a real system (ARCHITECTURE.md §14).
//!
//! One node, det-selftest-node, from a `binary` source. Scenarios:
//!   steady     the node answers; every property passes (and fails on profile "mutant", whose
//!              echo node answers in uppercase: the tests catch the mutant)
//!   node_exit  a driver makes the node exit: the built-in property
//!              "no unexpected container exits" must fail
//!   node_crash the node's own process crashes after saying so: known by that text in profile
//!              "known-exit", a failing crash otherwise
//!   node_panic the node prints a Go panic whose stack profile "known-exit" declares known
//!              (counted), and node_panic_other one it does not: "no panics (Go)" fails
//!   oom        (profile "memory") a command in the echo node exceeds its memory limit: the
//!              built-in property "the kernel kills no process for lack of memory" must fail
//!   stress     drivers hammer clocks, sleeps, yields, page faults and forks at once, and report
//!              what they observe as events: any nondeterminism changes the event hash
//!   quiet      (profile "workers") a driver asks for a 2 second quiet period from inside the
//!              echo node (det-stop-faults, as Antithesis's ANTITHESIS_STOP_FAULTS): no fault
//!              but clock skips may start during it
//!   progress   (profile "workers") after a second of faults, the echo node must answer while
//!              faults pause (sdk.progress_while_quiet), and faults resume once it has
//!   inject     (profile "injectable") faults the scenario asks for (sdk.fault): a pause, a
//!              graceful stop and a one-way partition, each taking the node away and giving it
//!              back; a clock skew, the node's realtime clock 5 s behind while it lasts
//!   hang       a driver that never ends: the timeline's ceiling of virtual time ends it, hung
//!   hang_sometimes  one timeline in eight hangs as `hang` does, the rest end within seconds: the
//!              run's learned timeline limit cuts the hanging ones short once it has learned
//!   readdress  (profile "movable") restarts the scenario asks for: the node answers at its
//!              name each time, and sometimes came back at a new address
//!   file_error (profile "durable") write errors the scenario asks for on the echo node's disk:
//!              its appends fail with ENOSPC for a second, its reads go on, then appends succeed;
//!              then short writes: its append writes part of its line
//!   syscall_error (profile "signaled") a system call error the scenario asks for: the echo node's
//!              accept4 fails with EMFILE for a second (the kernel's fail_function), then serves
//!   drivers    three parallel drivers, one the workload: the composer's swarm leaves the others
//!              out of some timelines, never the workload's only driver
//!   metastable (profile "queue") Peter Alvaro's toy service under an open-loop load: 0.5
//!              requests a second, a minute at 2, then 0.5 again, each client retrying on an 8 s
//!              timeout (under the full queue's wait): goodput never recovers (red: a metastable
//!              failure)
//!   stable     (profile "queue") the same with a 20 s timeout: goodput recovers
//!   cache      the cache of Will Wilson's "Swarm Testing" talk: inserts, reads and removes
//!              drawn by sdk.swarm_choice; eviction, its bug, runs once the cache fills, which
//!              uniform choices (--no-swarm) never make it do
//!   signal     (profile "signaled") signal faults the scenario asks for: the echo node's accept,
//!              its SIGURG handler installed without SA_RESTART, interrupted (EINTR)
//!   unlist     (profile "unlistable") graceful stops the scenario asks for: while the echo
//!              node is down its name is sometimes gone from the witness's hosts file, never
//!              from the runner's, and back in every one once it started again
//!   aftershock (profile "durable") drawn faults over idle drivers: power losses, some soon after
//!              a node started again (faults.zig's aftershocks)
//!   disk       (profile "durable") the echo node's disk under a crash and a wipe: what it synced
//!              survives a crash, what it did not is lost, a wipe loses both (with a second
//!              durable node beside it); then disk faults asked for: lost writes, failing
//!              writes, a slow disk, and the disk afterwards; then an outage of both nodes
//!   durability (profile "durable") faults at the echo node's durability points: a stall holds
//!              its syncs; a crash at a sync loses the write when it comes before it, and keeps
//!              it when it comes just after
//!   interleave (profile "injectable") a race between a thread and the batch thread it wakes,
//!              run in the echo node without and with the `interleave` fault: the kernel alone
//!              settles it one way (the waker goes on), the fault both ways
//!   aim        (profile "aimable") the driver aims the injector at the witness node
//!              (sdk.fault_aim): about three of its pauses in four go there, the rest anywhere
//!   records    a driver records numbers and their squares (sdk.record), and the host check
//!              `squares` (run on the host when the timeline ends) asserts every square and the
//!              count, from the records alone
//!   controller (profile "controller", ARCHITECTURE.md §14 level 1) determinismo's own HTTP API
//!              as the system under test, with a fake explorer, under pauses, partitions and
//!              restarts: every run it accepted must survive with a sensible state
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    echo: ?sdk.Node,
    csdk: ?sdk.Node,
    controller: ?sdk.Node,
    maze: ?sdk.Node,
    zigmaze: ?sdk.Node,
    summaze: ?sdk.Node,
    /// A second durable node: its mount namespace must not keep the echo node's disk (nor the
    /// echo node's keep its own) alive across a crash.
    witness: ?sdk.Node,
    /// The quorum profile's third node.
    third: ?sdk.Node,
};
pub const System = sdk.System(Nodes);
const port = 7000;
/// No faults: these nodes check the platform, not resilience.
const quiet = sdk.schema.Faults{
    .pause = false,
    .isolate = false,
    .partition = false,
    .degrade = false,
    .throttle = false,
    .process_pause = false,
    .sync_stall = false,
    .interleave = false,
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .steady = steady,
            .steady_single = steady_single,
            .node_exit = node_exit,
            .node_exit_again = node_exit_again,
            .node_crash = node_crash,
            .node_crash_nodump = node_crash_nodump,
            .node_crash_stopping = node_crash_stopping,
            .node_exit_stopping = node_exit_stopping,
            .node_crash_failing = node_crash_failing,
            .node_crash_after_heal = node_crash_after_heal,
            .node_supervised = node_supervised,
            .node_supervised_quiet = node_supervised_quiet,
            .node_sigbus_failing = node_sigbus_failing,
            .node_sigbus_healthy = node_sigbus_healthy,
            .node_panic = node_panic,
            .node_panic_other = node_panic_other,
            .node_logfail = node_logfail,
            .node_logfail_known = node_logfail_known,
            .spin = spin_scenario,
            .oom = oom,
            .crash = crash,
            .disk = disk,
            .writeback = writeback,
            .ending_window = ending_window_scenario,
            .before_nodes = before_nodes_scenario,
            .durability = durability,
            .interleave = interleave_scenario,
            .inject = inject,
            .readdress = readdress,
            .unlist = unlist,
            .signal = signal_scenario,
            .cache = cache_scenario,
            .metastable = metastable_scenario,
            .aftershock = aftershock_scenario,
            .record_power_loss = record_power_loss_scenario,
            .errno_storm = errno_storm_scenario,
            .stable = stable_scenario,
            .drivers = drivers_scenario,
            .drivers_unmarked = drivers_unmarked_scenario,
            .syscall_error = syscall_error_scenario,
            .file_error = file_error_scenario,
            .hang = hang,
            .hang_sometimes = hang_sometimes,
            .egress = egress_scenario,
            .fork_pull = fork_pull_scenario,
            .workload_singleton = workload_singleton_scenario,
            .serial_slow = serial_slow_scenario,
            .singleton_slow = singleton_slow_scenario,
            .ingress = ingress_scenario,
            .stress = stress,
            .quiet = quiet_scenario,
            .clock_jitter = clock_jitter_scenario,
            .progress = progress_scenario,
            .controller = @import("controller.zig").scenario,
            .maze = maze,
            .records = records_scenario,
            .flood = flood_scenario,
            .startup_coverage = startup_coverage_scenario,
            .ending = ending_scenario,
            .ending_signal = ending_signal_scenario,
            .ending_fail = ending_fail_scenario,
            .sinks = sinks_scenario,
            .aim = aim_scenario,
            .slow = slow_scenario,
            .slot_wait = slot_wait_scenario,
            .sought = sought_scenario,
            .streak = streak_scenario,
            .streak_blind = streak_blind_scenario,
            .spare = spare_scenario,
            .frozen_start = frozen_start_scenario,
            .hangup = hangup_scenario,
            .stale_pid = stale_pid_scenario,
            .leak = leak_scenario,
            .leak_climb = leak_climb_scenario,
            .upgrade = upgrade_scenario,
            .knobs = knobs_scenario,
            .quorum = quorum_scenario,
            .quorum_free = quorum_free_scenario,
        },
        .checks = .{ .squares = squares_check },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    // An echo node marking a crash point every 50 ms (sdk.crash_point), its kills and power
    // losses on: the injector crashes it there (e2e crash-points).
    const crash_points = try d.profile("crash-points");
    crash_points.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_CRASH_POINT=1"},
        .ready = .{ .tcp = port },
        .faults = comptime blk: {
            var faults = quiet;
            faults.restart = true;
            faults.crash = true;
            break :blk faults;
        },
    });
    // The same system with a mutant echo node: "steady" must catch it.
    const mutant = try d.profile("mutant");
    mutant.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_MUTANT=1"},
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    // The crash scenario's segfault declared known: counted, not failed.
    const known_crash = try d.profile("known-crash");
    known_crash.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .crashes_known = &.{"det-selftest-node"},
    });
    // The node_exit scenario's exit declared known, by what the node says as it dies.
    const known_exit = try d.profile("known-exit");
    known_exit.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .exits_known = &.{ "dying as told", "crashing as told" },
        .panics_known = &.{"main.told(0x0)"},
        // A panic the node survives and logs: a failure, but at main.site_known (node_logfail).
        .log_failures = &.{.{
            .text = "panic in the recoverable goroutine",
            .property = "no recovered panics (selftest)",
            .known = &.{"main.site_known"},
        }},
    });
    // Graceful stops allowed (off by default): node_crash_stopping asks one. Its exit known by
    // what the node says ("stop-known"), or nothing declared ("stop-unknown").
    var stoppable = quiet;
    stoppable.stop = true;
    const stop_known = try d.profile("stop-known");
    stop_known.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = stoppable,
        .exits_known = &.{"crashing as told"},
    });
    const stop_unknown = try d.profile("stop-unknown");
    stop_unknown.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = stoppable,
    });
    // known-exit's with disk faults allowed (off by default): node_crash_failing asks one.
    const known_exit_disk = try d.profile("known-exit-disk");
    var quiet_disk = quiet;
    quiet_disk.disk = true;
    known_exit_disk.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet_disk,
        .exits_known = &.{ "dying as told", "crashing as told" },
    });
    // Its crash known only while its disk fails (schema.Node.exits_known_disk): counted under
    // node_crash_failing's disk fault, failed in node_crash with a healthy disk.
    const known_exit_disk_only = try d.profile("known-exit-disk-only");
    known_exit_disk_only.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet_disk,
        .exits_known_disk = &.{"crashing as told"},
    });
    // Supervised (schema.Node.supervised): its own exit, known, then started again by init.
    const supervised_profile = try d.profile("supervised");
    supervised_profile.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .exits_known = &.{"leaving unannounced"},
        .supervised = true,
    });
    const memory = try d.profile("memory");
    memory.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .memory_max_mib = 32,
    });
    // A leak each timeline adds to (e2e memory-climb): the echo node's server keeps what each
    // driver start asks it to leak, past its limit only down the leakiest timelines.
    const climb = try d.profile("climb");
    climb.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .memory_max_mib = climb_limit_mib,
    });
    // Workers under a supervisor, and faults that kill processes (never the main one).
    const workers = try d.profile("workers");
    var kills = quiet;
    kills.process_kill = true;
    kills.custom = &.{"/bin/det-selftest-node custom-fault"};
    workers.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_WORKERS=3"},
        .ready = .{ .tcp = port },
        .faults = kills,
    });
    try describe_faulted(d);
    try describe_mazes(d);
    const controller = try d.profile("controller");
    controller.node(.controller, .{
        .directory = "zig-out/bin", // determinismo and det-fake-explore.
        .command = &.{
            "/determinismo", "serve",     "--listen",   "0.0.0.0:7878",
            "--data",        "/var/runs", "--explorer", "/det-fake-explore",
        },
        .ready = .{ .tcp = 7878 },
        .faults = .{ .restart = true },
    });
    // A node in C reporting through the C SDK; no faults (its properties are about the SDK).
    default.node(.csdk, .{
        .binary = "zig-out/bin/det-selftest-c",
        .faults = quiet,
    });
}

/// The echo node with faults the scenarios ask for.
fn describe_faulted(d: *System.Describe) !void {
    // A disk of its own (crash faults allowed), for the "disk" scenario.
    const durable = try d.profile("durable");
    var crashes = quiet;
    crashes.crash = true;
    crashes.disk = true;
    // The strict model ("a crash keeps what was synced and loses the rest"): a driver's power
    // loss without partial persistence; partial_power_loss injects its own.
    crashes.partial_persistence = false;
    durable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = crashes,
    });
    durable.node(.witness, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = crashes,
    });
    // A durable node with a drawn flusher of a 1 s window, for the "writeback" scenario.
    const windowed = try d.profile("writeback");
    windowed.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = crashes,
        .writeback_s = 1,
    });
    // Faults the scenario asks for: the injector runs (it may pause or stop the node).
    const injectable = try d.profile("injectable");
    var asked = quiet;
    asked.pause = true;
    asked.stop = true;
    asked.clock_skew = true;
    // Its links faultable, for the partition and isolation the scenario asks for: a node that
    // takes no network fault has none (faults.zig faultable, for monitors and clients), so asked
    // for they cut nothing (the check failed from that change on). The scenario's quiet period
    // keeps drawn faults off.
    asked.partition = true;
    asked.isolate = true;
    injectable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = asked,
    });
    // Two nodes that may be paused, for the "aim" and "hangup" scenarios (hangup asks no fault).
    // Two echo nodes whose kills and power losses overlap unless a scenario caps them (e2e
    // nodes-down).
    const restartable = try d.profile("restarts");
    inline for (.{ .echo, .witness }) |name| {
        restartable.node(name, .{
            .binary = "zig-out/bin/det-selftest-node",
            .ready = .{ .tcp = port },
            .faults = comptime blk: {
                var faults = quiet;
                faults.restart = true;
                faults.crash = true;
                faults.outage = false;
                break :blk faults;
            },
        });
    }
    const aimable = try d.profile("aimable");
    var pauses = quiet;
    pauses.pause = true;
    inline for (.{ .echo, .witness }) |name| {
        aimable.node(name, .{
            .binary = "zig-out/bin/det-selftest-node",
            .ready = .{ .tcp = port },
            .faults = pauses,
        });
    }
    // The echo node for the "stale_pid" scenario: the stop it asks for, and clock skews alone
    // drawn (some fault kind, or the composer starts no injector and the asked stop goes
    // nowhere: sdk.fault finds no reader).
    // An echo node and its next release, the same program installed under another name (an
    // image of its own: which root is mounted shows in which program is there), for the upgrade
    // check: restarted there and back, its /data kept (DET_DURABLE makes /data at the first
    // start).
    const upgrading = try d.profile("upgrade");
    upgrading.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .upgrade = .{ .binary = "zig-out/bin/det-selftest-node-next" },
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    // A spare upgraded before it ever started (etcd's spare, trial run 1613: its state
    // directory not made yet, the upgrade failed), then started: on its next release.
    upgrading.node(.witness, .{
        .binary = "zig-out/bin/det-selftest-node",
        .upgrade = .{ .binary = "zig-out/bin/det-selftest-node-next" },
        .ready = .{ .tcp = port },
        .faults = quiet,
        .spare = true,
    });
    // Two nodes drawing a knob at each start and one for the run (schema.Knob), for the knobs
    // check: the run's the same in both, a start's one of its choices.
    const knobbed = try d.profile("knobs");
    const knobs = [_]sdk.schema.Knob{
        .{ .name = "mode", .choices = &.{ &.{"DET_KNOB=a"}, &.{"DET_KNOB=b"}, &.{"DET_KNOB=c"} } },
        .{ .name = "shared", .choices = &.{ &.{ "DET_SHARED=x", "DET_OTHER=1" }, &.{ "DET_SHARED=y", "DET_OTHER=2" } }, .scope = .run },
    };
    inline for (.{ .echo, .witness }) |name| {
        knobbed.node(name, .{
            .binary = "zig-out/bin/det-selftest-node",
            // Replaced by the knob's entry: one value of a name, the knob's.
            .env = &.{"DET_KNOB=unset"},
            .knobs = &knobs,
            .ready = .{ .tcp = port },
            .faults = quiet,
        });
    }
    // Three nodes under every fault kind but the outage's, for the quorum check (schema.Scenario
    // .quorum): with the cap a majority always answers the runner, without it not. Their links
    // with the runner kept: the cap asks one member reachable (a client fails over), so the
    // runner's view measures the members alone.
    const quorate = try d.profile("quorum");
    inline for (.{ .echo, .witness, .third }) |name| {
        quorate.node(name, .{
            .binary = "zig-out/bin/det-selftest-node",
            .ready = .{ .tcp = port },
            .faults = .{ .restart = true, .stop = true, .runner_links = false },
        });
    }
    const stale = try d.profile("stale-pid");
    stale.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = comptime blk: {
            var faults = quiet;
            faults.clock_skew = true;
            break :blk faults;
        },
    });
    // A spare witness (not started with the echo node: a driver starts it), restarts and pauses
    // allowed, for the "spare" scenario: faults must leave it alone until it runs.
    const spared = try d.profile("spare");
    spared.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    var spare_faults = quiet;
    spare_faults.pause = true;
    spare_faults.restart = true;
    spared.node(.witness, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = spare_faults,
        .spare = true,
    });
    // Restarts that may give it a new address, for the "readdress" scenario.
    const movable = try d.profile("movable");
    var moves = quiet;
    moves.restart = true;
    moves.new_address = true;
    movable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = moves,
    });
    // Signals it catches, for the "signal" scenario: its SIGURG handler does not restart.
    const signaled = try d.profile("signaled");
    var signals = quiet;
    signals.signals = true;
    signaled.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .env = &.{"DET_INTERRUPTIBLE=1"},
        .faults = signals,
    });
    // The toy queue service, for the "metastable" and "stable" scenarios (no faults: the
    // trigger is the load).
    const queued = try d.profile("queue");
    queued.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .env = &.{"DET_QUEUE=1"},
        .faults = quiet,
    });
    // Stops that may take its name from its peers' hosts files, for the "unlist" scenario.
    const unlistable = try d.profile("unlistable");
    var follows = quiet;
    follows.stop = true;
    follows.names_follow_liveness = true;
    unlistable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = follows,
    });
    unlistable.node(.witness, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
}

/// The mazes coverage-guided strategies must solve (C, the sum, Zig).
fn describe_mazes(d: *System.Describe) !void {
    const maze_profile = try d.profile("maze");
    maze_profile.node(.maze, .{
        .binary = "zig-out/bin/det-maze",
        .command = &.{ "/bin/det-maze", "idle" },
        .faults = quiet,
    });
    // The same maze in Zig: coverage through the Zig SDK.
    const maze_sum = try d.profile("maze-sum");
    maze_sum.node(.summaze, .{
        .binary = "zig-out/bin/det-maze-sum",
        .command = &.{ "/bin/det-maze-sum", "idle" },
        .faults = quiet,
    });
    const maze_zig = try d.profile("maze-zig");
    maze_zig.node(.zigmaze, .{
        .binary = "zig-out/bin/det-maze-zig",
        .command = &.{ "/bin/det-maze-zig", "idle" },
        .faults = quiet,
    });
}

/// `steady` with at most one node down at once (schema.Scenario.nodes_down_max): e2e
/// nodes-down, on the two-node profile `restarts`.
fn steady_single(s: *System.Scenario) void {
    s.nodes_down_max = 1;
    steady(s);
}

fn steady(s: *System.Scenario) void {
    s.first("entropy", entropy);
    s.parallel_driver("ping", ping);
    s.finally("ping_after", ping);
}

/// Antithesis's output sink (ANTITHESIS_OUTPUT_DIR): files written there in a node become
/// events (det-sinks). Written here from the runner, through the node's root (the echo node runs
/// no shell); its processes see the variable.
fn sinks_scenario(s: *System.Scenario) void {
    s.singleton_driver("sink_write", sink_write);
}

fn sink_write(_: *System.Context) !void {
    const sink = "/run/det/nodes/echo/root/run/antithesis";
    const assertion = "{\"antithesis_assert\":{\"hit\":true,\"must_hit\":true,\"assert_type\":\"always\"," ++
        "\"display_type\":\"Always\",\"message\":\"a sink assertion\",\"condition\":true," ++
        "\"id\":\"a sink assertion\",\"location\":{},\"details\":{}}}\n";
    try sink_append(sink ++ "/sdk.jsonl", assertion);
    try sink_append(sink ++ "/debug.log", "hello sink\n");
    try sink_append(sink ++ "/data.bin", "\x00\x01\x02");
    // The retroactive sink: out of the exploration's logs, back in a replay's.
    try sink_append("/run/det/nodes/echo/root/run/antithesis-filtered/verbose.log", "a filtered line\n");
    // The node's main process has the variable (Antithesis sets it in every container).
    const pid = nodes_pid_of("echo") orelse return error.NoEcho;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0);
    var environment: [8192]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoEnviron;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &environment, environment.len);
    if (linux.errno(size) != .SUCCESS) return error.NoEnviron;
    const set = std.mem.indexOf(u8, environment[0..size], "ANTITHESIS_OUTPUT_DIR=/run/antithesis") != null;
    sdk.always(set, "nodes have ANTITHESIS_OUTPUT_DIR", .{});
    // det-sinks looks every 50 ms: the timeline goes on a little.
    const pause_long = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause_long, null);
}

fn sink_append(path: [:0]const u8, data: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.SinkOpen;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.write(@intCast(fd), data.ptr, data.len)) != .SUCCESS) return error.SinkWrite;
}

/// A node's main process (det-nodes records it), as the runner sees it.
fn nodes_pid_of(name: []const u8) ?linux.pid_t {
    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/pid", .{name}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..size], " \n"), 10) catch null;
}

/// Antithesis's endings: an eventually command kills the drivers still running (here, ones
/// that sleep far past the driver phase); a finally one waits for them, and runs only when every
/// command ran to completion.
fn ending_scenario(s: *System.Scenario) void {
    s.parallel_driver("sleeper", sleeper);
    s.eventually("after_kill", ending_eventually);
    s.finally("after_all", ending_finally);
}

/// Where sleepers note the children they start, for the eventually command to look for.
const sleeper_children_path = "/tmp/det-selftest-sleeper-children";

fn sleeper(_: *System.Context) !void {
    sdk.event("sleeper_start", .{});
    const long = linux.timespec{ .sec = 30, .nsec = 0 };
    // A child of its own, as a command in a node has (det-nodes exec, then the program): a kill
    // of the command kills its group, the child too. Only the command's own process died once
    // (its group never made), and a driver in a node drove on through the final reads.
    const child = linux.fork();
    if (child == 0) {
        _ = linux.nanosleep(&long, null);
        linux.exit_group(0);
    }
    if (linux.errno(child) == .SUCCESS) {
        var line: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{d}\n", .{child}) catch unreachable;
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
        const fd = linux.open(sleeper_children_path, flags, 0o644);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.write(@intCast(fd), text.ptr, text.len);
            _ = linux.close(@intCast(fd));
        }
    }
    _ = linux.nanosleep(&long, null);
    sdk.event("sleeper_done", .{});
}

fn ending_eventually(context: *System.Context) !void {
    sdk.reachable("an eventually command ran", .{});
    const arena = context.init.arena.allocator();
    var pids = std.mem.tokenizeScalar(u8, try sdk.file_read(arena, sleeper_children_path), '\n');
    while (pids.next()) |text| {
        const pid = std.fmt.parseInt(linux.pid_t, text, 10) catch continue;
        sdk.always(!process_alive(pid), "a killed driver's children are gone", .{ .pid = pid });
    }
}

/// Whether `pid` runs still (a zombie, killed and not yet reaped, does not).
fn process_alive(pid: linux.pid_t) bool {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return false;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [256]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    // "pid (name) S ...": the state after the name's closing parenthesis.
    const close = std.mem.lastIndexOfScalar(u8, buffer[0..size], ')') orelse return false;
    return close + 2 < size and buffer[close + 2] != 'Z' and buffer[close + 2] != 'X';
}

fn ending_finally(_: *System.Context) !void {
    sdk.reachable("a finally command ran", .{});
}

/// A finally command runs only when every command ran to completion, the length's own kills
/// forgiven: a driver that died by a signal before the length killed the rest is no
/// completion. The length's forgiveness once wiped every earlier interruption with its own
/// (CE1, the blind Lean replica of the platform). Half the timelines have signaled_driver's first
/// start die by SIGKILL at once; outliving sleeps past a short --timeline in every one (run with
/// --no-swarm), so the length always has commands to kill.
fn ending_signal_scenario(s: *System.Scenario) void {
    s.parallel_driver("outliving", outliving_driver);
    s.parallel_driver("signaled", signaled_driver);
    s.finally("after_signal", ending_signal_finally);
}

const signaled_first_path = "/tmp/det-selftest-signaled-first";
const signaled_path = "/tmp/det-selftest-signaled";

fn signaled_driver(_: *System.Context) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const first = linux.open(signaled_first_path, flags, 0o644);
    if (linux.errno(first) == .SUCCESS) {
        _ = linux.close(@intCast(first));
        if (sdk.random_below(2) == 0) {
            const marked = linux.open(signaled_path, flags, 0o644);
            if (linux.errno(marked) == .SUCCESS) _ = linux.close(@intCast(marked));
            sdk.event("signaled_self", .{});
            _ = linux.kill(linux.getpid(), .KILL);
        }
    }
    const long = linux.timespec{ .sec = 30, .nsec = 0 };
    _ = linux.nanosleep(&long, null);
}

/// Past the length and its 30 s grace (composer.zig's length_grace_ns): the length's kill ends it.
fn outliving_driver(_: *System.Context) !void {
    const long = linux.timespec{ .sec = 600, .nsec = 0 };
    _ = linux.nanosleep(&long, null);
}

fn ending_signal_finally(_: *System.Context) !void {
    sdk.reachable("a finally command ran after the length killed the rest", .{});
    const marked = linux.access(signaled_path, linux.F_OK) == 0;
    sdk.always(!marked, "a finally runs only after every command ran to completion", .{});
}

/// A command that exits on its own is judged by its status, though it is reaped while the
/// composer kills the rest: with no minimum drive (--min-drive 0) nothing reaped the starts
/// below the parallelism before the eventually command's kill, which reported every one as
/// killed and its failure as none (CE2, the blind Lean replica of the platform).
fn ending_fail_scenario(s: *System.Scenario) void {
    s.parallel_driver("fails", fails);
    s.eventually("after_fail", ending_fail_eventually);
}

fn fails(_: *System.Context) !void {
    sdk.event("fails_start", .{});
    return error.Failed;
}

fn ending_fail_eventually(_: *System.Context) !void {
    sdk.reachable("an eventually command ran after failing drivers", .{});
}

fn clock_jitter_scenario(s: *System.Scenario) void {
    s.singleton_driver("clock_jitter", clock_jitter);
}

/// What a CPU-jitter entropy source measures, as Go's FIPS 140-3 mode's crypto/internal/entropy
/// does: 4 samples to warm up, then 1024, each 64 memory touches at pseudo-random places and the
/// monotonic clock's difference (nanoseconds, through the vDSO) since the last, its low byte the
/// sample; then its SP 800-90B health tests: no value 41 times in a row (repetition count), none
/// 410 times in a window of 512 (adaptive proportion). With time made of retired branches every
/// sample was alike and Go panicked at start (trial run 1348), unless the clock jitters
/// (VM.Options.tsc_jitter_seed). The longest run, the most frequent count and the verdict, an event.
fn clock_jitter(_: *System.Context) !void {
    var memory: [4096]u32 = @splat(0);
    var state: u32 = 1;
    var samples: [1024]u8 = undefined;
    var previous = monotonic_ns();
    for (0..4 + samples.len) |index| {
        for (0..64) |_| {
            state = state *% 1664525 +% 1013904223;
            memory[(state >> 6) % memory.len] +%= 13;
        }
        std.mem.doNotOptimizeAway(&memory);
        const now = monotonic_ns();
        if (index >= 4) samples[index - 4] = @truncate(now -% previous);
        previous = now;
    }
    var run: u32 = 1;
    var run_max: u32 = 1;
    for (samples[1..], samples[0 .. samples.len - 1]) |sample, before| {
        run = if (sample == before) run + 1 else 1;
        run_max = @max(run_max, run);
    }
    var counts: [256]u32 = @splat(0);
    var window_max: u32 = 0;
    for (samples, 0..) |sample, index| {
        counts[sample] += 1;
        if (index >= 512) counts[samples[index - 512]] -= 1;
        window_max = @max(window_max, counts[sample]);
    }
    sdk.event("clock_jitter", .{ .run_max = run_max, .window_max = window_max, .healthy = run_max < 41 and window_max < 410 });
}

fn quiet_scenario(s: *System.Scenario) void {
    s.singleton_driver("quiet_period", quiet_period);
}

/// Faults for a while, a quiet period requested from inside the node, then past its end.
fn quiet_period(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const second = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&second, null);
    sdk.event("quiet_request", .{ .seconds = 2 });
    _ = try node.exec(&.{ "/opt/determinismo/bin/det-stop-faults", "2" });
    const after = linux.timespec{ .sec = 3, .nsec = 0 };
    _ = linux.nanosleep(&after, null);
}

fn progress_scenario(s: *System.Scenario) void {
    s.parallel_driver("progress", progress_quiet);
}

/// Faults for a second, then the echo node must answer while they pause.
fn progress_quiet(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const second = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&second, null);
    _ = sdk.progress_while_quiet("the echo node answers while faults pause", 5000, 100, echo_once, .{node.address});
    const after = linux.timespec{ .sec = 2, .nsec = 0 };
    _ = linux.nanosleep(&after, null); // Faults again.
}

fn echo_once(address: [4]u8) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(address, "ping\n", &reply);
    if (!std.mem.eql(u8, answer, "ping\n")) return error.WrongAnswer;
}

fn node_exit(s: *System.Scenario) void {
    s.singleton_driver("kill_echo", tell_die);
}

/// The echo node's own process crashes after saying so: known (by that output) in the
/// known-exit profile, a crash and an exit otherwise.
fn node_crash(s: *System.Scenario) void {
    s.singleton_driver("crash_echo", tell_crash);
}

/// A guest busy computing and reading its clock (through the vDSO, as Go reads it all the time)
/// for 2 s of virtual time, no faults: the timer then fires at a clock read (its soft stop), the
/// case of a moment taken early at a modulation stretch's end (run 356; the e2e moments check).
fn spin_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("spin", spin);
}

fn spin(_: *System.Context) !void {
    var start: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &start);
    var sum: u64 = 0;
    while (true) {
        for (0..1000) |index| sum +%= index *% 2654435761;
        var now: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &now);
        if (now.sec - start.sec >= spin_seconds) break;
    }
    sdk.event("spun", .{ .sum = sum });
}

const spin_seconds = 2;

/// The same, the node dumping no core: the kernel's line alone, judged as the node exits.
fn node_crash_nodump(s: *System.Scenario) void {
    s.singleton_driver("crash_echo", tell_crash_nodump);
}

fn tell_crash_nodump(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "crash-nodump\n", &reply) catch {};
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null);
}

/// A graceful stop's SIGTERM makes the echo node say a known exit's text and crash, no core
/// dumped (Galera's joiner, hunt run 1952: stopped mid state transfer, it announced its abort
/// and crashed in it 1 s later, the pidfile already gone): judged as the node's exit.
fn node_crash_stopping(s: *System.Scenario) void {
    s.singleton_driver("crash_echo", tell_crash_stopping);
}

/// A graceful stop's SIGTERM makes the echo node exit 2 (PostgreSQL's gosu as PID 1, hunt run
/// 1971): an exit the stop asked for, never a failure.
fn node_exit_stopping(s: *System.Scenario) void {
    s.singleton_driver("exit_echo", tell_exit_stopping);
}

fn tell_exit_stopping(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    var reply: [16]u8 = undefined;
    _ = try request(echo.address, "exit-on-stop\n", &reply);
    sdk.fault(.{ .kind = "stop", .node = echo.name, .duration_ms = 1000 });
    sdk.sleep_ms(2000);
}

fn tell_crash_stopping(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s); // No drawn faults; the requested stop applies.
    var reply: [16]u8 = undefined;
    _ = try request(echo.address, "crash-on-stop\n", &reply);
    sdk.fault(.{ .kind = "stop", .node = echo.name, .duration_ms = 1000 });
    sdk.sleep_ms(2000);
}

/// The echo node says a known exit's text and crashes while a disk fault holds its disk
/// (MongoDB's abort on WiredTiger's EIO, hunt run 1707: an exit while the disk fails is
/// expected, and its crash lines were then judged as if it had said nothing).
fn node_crash_failing(s: *System.Scenario) void {
    s.singleton_driver("crash_echo", tell_crash_failing);
}

fn tell_crash_failing(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.fault(.{ .kind = "disk", .node = echo.name, .failure = "write_errors", .duration_ms = 3000 });
    sdk.sleep_ms(200); // The injector applies it.
    var reply: [16]u8 = undefined;
    _ = request(echo.address, "crash\n", &reply) catch {};
    sdk.sleep_ms(500);
}

/// The node reads a mapped page while a disk fault fails that file's reads: the kernel's SIGBUS,
/// no core dumped (judged at its exit by the kernel's line, as ParticleDB's in run 1877): a known
/// exit, the fault's doing.
fn node_sigbus_failing(s: *System.Scenario) void {
    s.singleton_driver("sigbus_echo", tell_sigbus_failing);
}

fn tell_sigbus_failing(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    _ = page_write(&echo, "/data/mapped");
    sdk.fault(.{ .kind = "disk", .node = echo.name, .failure = "errors", .file = "data/mapped", .duration_ms = 3000 });
    sdk.sleep_ms(200); // The injector applies it.
    var reply: [16]u8 = undefined;
    const answer = request(echo.address, "mmap-read\n", &reply) catch "";
    sdk.event("mapped_read", .{ .answer = answer });
    sdk.sleep_ms(500);
}

/// The same SIGBUS with a healthy disk (the file truncated under the mapping: a program's own
/// bug): it fails, as any crash.
fn node_sigbus_healthy(s: *System.Scenario) void {
    s.singleton_driver("sigbus_echo", tell_sigbus_healthy);
}

fn tell_sigbus_healthy(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    _ = page_write(&echo, "/data/mapped");
    var reply: [16]u8 = undefined;
    const answer = request(echo.address, "mmap-truncated\n", &reply) catch "";
    sdk.event("mapped_read", .{ .answer = answer });
    sdk.sleep_ms(500);
}

/// A disk fault that heals, then the crash: a fail-stop on the disk's errors that ends after the
/// heal (Kafka's orderly shutdown, trial run 1783), still this start's disk failure. The node is
/// then started again, as one that ended before the heal (hunt run 1804: two brokers ended
/// after theirs and stayed down, the cluster with them).
fn node_crash_after_heal(s: *System.Scenario) void {
    s.singleton_driver("crash_echo", tell_crash_after_heal);
}

fn tell_crash_after_heal(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.fault(.{ .kind = "disk", .node = echo.name, .failure = "write_errors", .duration_ms = 300 });
    sdk.sleep_ms(1000); // Applied, then healed.
    // The injector's own faults held from here (a quiet period heals what it drew since): a
    // regime with a 12 ms gap drew an 11.7 s disk fault 22 ms after the heal, and the crash fell
    // under it, the node down past the 5 s below (e2e properties, 2026-11-11).
    _ = try echo.exec(&.{ "/opt/determinismo/bin/det-stop-faults", "8" });
    var reply: [16]u8 = undefined;
    _ = request(echo.address, "crash\n", &reply) catch {};
    // Started again a second after its end was seen: answering within 5 s.
    var answered = false;
    for (0..20) |_| {
        sdk.sleep_ms(250);
        const answer = request(echo.address, "hello\n", &reply) catch continue;
        if (answer.len > 0) {
            answered = true;
            break;
        }
    }
    sdk.always(answered, "a node that ended after its disk healed starts again", .{});
}

/// The echo node exits on its own (a known exit, no fault): supervised, it answers again soon.
fn node_supervised(s: *System.Scenario) void {
    s.singleton_driver("leave_echo", tell_leave_supervised);
}

fn tell_leave_supervised(context: *System.Context) !void {
    try leave_then_answer(context, "leave\n");
}

/// The echo node's output goes to /dev/null, then it exits on its own: its exit still names its
/// stack (its forwarder answers the node's exits after its output ended).
fn node_supervised_quiet(s: *System.Scenario) void {
    s.singleton_driver("leave_echo_quietly", tell_leave_quietly);
}

fn tell_leave_quietly(context: *System.Context) !void {
    try leave_then_answer(context, "leave-quietly\n");
}

fn leave_then_answer(context: *System.Context, leave: []const u8) !void {
    const echo = context.nodes.echo.?;
    _ = try echo.exec(&.{ "/opt/determinismo/bin/det-stop-faults", "30" });
    var reply: [16]u8 = undefined;
    _ = request(echo.address, leave, &reply) catch {};
    // Its supervisor's first wait is a second: answering within 10 s.
    var answered = false;
    for (0..40) |_| {
        sdk.sleep_ms(250);
        const answer = request(echo.address, "hello\n", &reply) catch continue;
        if (answer.len > 0) {
            answered = true;
            break;
        }
    }
    sdk.always(answered, "a supervised node that exited on its own starts again", .{});
}

/// The echo node prints a panic its stack names known in the known-exit profile.
fn node_panic(s: *System.Scenario) void {
    s.singleton_driver("panic_echo", tell_panic);
}

/// The echo node logs a panic it survived, at a site nothing declares known.
fn node_logfail(s: *System.Scenario) void {
    s.singleton_driver("logfail_echo", tell_logfail);
}

/// The echo node logs a panic it survived, at the site the known-exit profile declares known.
fn node_logfail_known(s: *System.Scenario) void {
    s.singleton_driver("logfail_echo", tell_logfail_known);
}

fn tell_logfail(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "logfail\n", &reply) catch {};
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Its output forwarded and judged.
}

fn tell_logfail_known(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "logfail-known\n", &reply) catch {};
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null);
}

/// The echo node prints a panic nothing declares known.
fn node_panic_other(s: *System.Scenario) void {
    s.singleton_driver("panic_echo", tell_panic_other);
}

fn tell_panic(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "panic\n", &reply) catch {};
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Its output forwarded and judged.
}

fn tell_panic_other(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "panic-other\n", &reply) catch {};
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null);
}

fn tell_crash(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "crash\n", &reply) catch {}; // It crashes instead.
    const pause = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Let the runtime see the crash.
}

/// A process in the echo node dies of SIGSEGV: "no process crashes" must fail.
fn crash(s: *System.Scenario) void {
    s.singleton_driver("segfault", segfault);
}

fn segfault(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    _ = try node.exec(&.{ "/bin/det-selftest-node", "crash" });
}

fn flood_scenario(s: *System.Scenario) void {
    s.singleton_driver("flood", flood);
}

/// 40 MB of output in moments, as a node looping on an error writes it: the output forwarder
/// keeps 8 MB and the rate, drops the rest and says so (output_dropped), and the logging
/// property fails. In two halves 1.5 s apart: the run's output spans more than the second the
/// logging limit needs to judge a rate (written at once, its span was under it and the property
/// passed, the e2e properties check red since the limit was judged over the whole run, 33ec5ab).
fn flood(_: *System.Context) !void {
    var line: [100]u8 = undefined;
    @memset(&line, 'x');
    line[line.len - 1] = '\n';
    var buffer: [64 * 1024]u8 = undefined;
    for (0..buffer.len / line.len) |index| @memcpy(buffer[index * line.len ..][0..line.len], &line);
    const usable = buffer.len / line.len * line.len;
    for (0..2) |half| {
        if (half == 1) sdk.sleep_ms(1500);
        var written: usize = 0;
        while (written < 20 * 1000 * 1000) {
            const result = linux.write(1, &buffer, usable);
            if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
            written += result;
        }
    }
}

/// A JVM's startup coverage, as a tree meets it: the setup reaches more behaviors than a table
/// holds (startup_lines), each timeline reaches them all again first (a restart's), then one of
/// startup_paths of its own. Unknown to the tree before its first generation, every table held
/// the same first 8,192 and the tree returned nowhere (hunt run 1901, Pulsar, coverage on); the
/// e2e `startup-coverage` check wants returns from the first generation.
const startup_lines = 10_000;
const startup_paths = 32;
const startup_done_path = "/tmp/startup-coverage-done";

fn startup_coverage_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.setup("startup", startup_lines_reach);
    s.parallel_driver("restart", startup_restart);
}

fn startup_lines_reach(_: *System.Context) !void {
    var name: [32]u8 = undefined;
    for (0..startup_lines) |line| {
        sdk.event("startup_line", .{ .name = std.fmt.bufPrint(&name, "line {d}", .{line}) catch unreachable });
    }
}

/// The startup's lines once per timeline (a marker file: the runner's filesystem is the
/// timeline's), then a path of its own.
fn startup_restart(_: *System.Context) !void {
    const marker = linux.open(startup_done_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(marker) == .SUCCESS) {
        _ = linux.close(@intCast(marker));
    } else {
        try startup_lines_reach(undefined);
        const created = linux.open(startup_done_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(created) != .SUCCESS) return error.MarkerNotWritten;
        _ = linux.close(@intCast(created));
    }
    var name: [32]u8 = undefined;
    const path = sdk.random_below(startup_paths);
    sdk.event("startup_path", .{ .name = std.fmt.bufPrint(&name, "path {d}", .{path}) catch unreachable });
    sdk.sleep_ms(2 * std.time.ms_per_s);
}

fn records_scenario(s: *System.Scenario) void {
    s.singleton_driver("record", records_make);
}

const Square = struct { n: u64, square: u64 };
const records_count = 50;

/// Numbers and their squares, then a last record that says how many came before.
fn records_make(context: *System.Context) !void {
    _ = context;
    for (0..records_count) |n| sdk.record("squares", Square{ .n = n, .square = n * n });
    sdk.record("squares", Square{ .n = records_count, .square = 0 }); // The count: no square.
}

/// On the host, when the timeline ended: every record decoded, in order.
fn squares_check(check: *sdk.Check, records: []const Square) !void {
    sdk.always(std.mem.eql(u8, check.scenario, "records"), "a host check knows its scenario", .{});
    sdk.always(records.len == records_count + 1, "a host check gets every record", .{
        .records = records.len,
    });
    for (records[0..@min(records.len, records_count)], 0..) |record, index| {
        sdk.always(record.n == index and record.square == index * index, "a host check " ++
            "gets the records in order, as made", .{ .index = index, .n = record.n });
    }
}

fn disk(s: *System.Scenario) void {
    s.singleton_driver("disk_faults", disk_faults);
}

fn writeback(s: *System.Scenario) void {
    s.singleton_driver("writeback_window", writeback_window);
}

/// A node with a drawn flusher (a 1 s window, the "writeback" profile): a file it wrote without
/// syncing is on its disk once its flusher synced after the write, as a host's would have put
/// it, and a crash keeps it. With its flusher off meanwhile, the disk is strict ("disk") and the
/// crash may lose it. Two flushes counted after the write's start: one of them followed it.
/// The write waits for a drawn state of the flusher (on or off, up to 30 s), then two windows'
/// ends: each outcome likely in every timeline (waiting 5.5 s from any state, the off one needed
/// five windows without a switch: never in 8 timelines once their shared draw was on).
fn writeback_window(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    const wanted = if (sdk.random_below(2) == 0) "on" else "off";
    var before: ?u64 = null;
    var waits: u32 = 0;
    while (waits < 300) : (waits += 1) {
        var state_buffer: [32]u8 = undefined;
        const state = state_read("/run/det/nodes/echo/writeback", &state_buffer) orelse "";
        if (std.mem.startsWith(u8, state, wanted)) {
            before = flushes_read("/run/det/nodes/echo/writeback");
            break;
        }
        sdk.sleep_ms(100);
    }
    const status = echo.exec(&.{ "/bin/det-selftest-node", "unsynced", "/data/windowed" }) catch 1;
    sdk.sleep_ms(2500);
    const after = flushes_read("/run/det/nodes/echo/writeback");
    try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    const kept = file_present(&echo, "/data/windowed");
    var environ_buffer: [4096]u8 = undefined;
    const drawn = start_drawn(&environ_buffer);
    sdk.always(drawn, "a node's start has a number drawn for it", .{});
    const flushed = before != null and after != null and after.? >= before.? + 2;
    sdk.always(status == 0 and (kept or !flushed), "a crash keeps what a node's flusher synced", .{
        .written = status == 0,
        .flushed = flushed,
        .kept = kept,
    });
    sdk.sometimes(flushed, "a node's flusher syncs a file written unsynced", .{});
    sdk.sometimes(before != null and after != null and after.? == before.?, "a node's flusher stays off as it writes unsynced", .{});
    sdk.stop_faults(0);
}

/// Whether the echo node's main process has DETERMINISMO_DRAW in its environment.
fn start_drawn(buffer: []u8) bool {
    const value = start_variable(buffer, "DETERMINISMO_DRAW=") orelse return false;
    return value.len > 0;
}

/// The value the echo node's main process has for `key` ("NAME=") in its environment, or null.
fn start_variable(buffer: []u8, key: []const u8) ?[]const u8 {
    const pid = pid_read("/run/det/nodes/echo/pid") catch return null;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var entries = std.mem.splitScalar(u8, buffer[0..size], 0);
    while (entries.next()) |entry| {
        if (std.mem.startsWith(u8, entry, key)) return entry[key.len..];
    }
    return null;
}

/// The flushes counted in a node's `writeback` file ("on <flushes>" or "off <flushes>").
/// The flusher's state file's text ("on <flushes>" or "off <flushes>").
fn state_read(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.mem.trim(u8, buffer[0..size], " \n");
}

fn flushes_read(path: [:0]const u8) ?u64 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const text = std.mem.trim(u8, buffer[0..size], " \n");
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    return std.fmt.parseInt(u64, text[space + 1 ..], 10) catch null;
}

fn interleave_scenario(s: *System.Scenario) void {
    s.singleton_driver("interleavings", interleavings);
}

const race_rounds = 400;

/// The race without the `interleave` fault, then under it (every scheduling choice drawn), in a
/// quiet period: only this fault.
fn interleavings(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    const plain = race_early(&echo) orelse return;
    sdk.fault(.{ .kind = "interleave", .node = echo.name, .one_in = 1, .duration_ms = 2000 });
    sdk.sleep_ms(100); // The injector applies it.
    const drawn = race_early(&echo) orelse return;
    sdk.event("races", .{ .rounds = race_rounds, .plain = plain, .interleaved = drawn });
    sdk.always(plain < race_rounds / 50, "the kernel alone lets a waker go on before the batch thread it woke", .{
        .early = plain,
    });
    sdk.always(drawn > race_rounds / 4 and drawn < race_rounds * 3 / 4, "under the interleave fault, a woken thread runs first about half the time", .{
        .early = drawn,
    });
    sdk.sleep_ms(2500); // The fault ends: the module says how many choices it drew.
    sdk.stop_faults(0);
}

/// How many of the race's rounds the woken thread ran first, from the node.
fn race_early(echo: *const sdk.Node) ?u32 {
    var buffer: [64]u8 = undefined;
    var rounds_buffer: [16]u8 = undefined;
    const rounds = std.fmt.bufPrint(&rounds_buffer, "{d}", .{race_rounds}) catch unreachable;
    const result = echo.exec_output(&.{ "/bin/det-selftest-node", "race", rounds }, &buffer) catch return null;
    const text = std.mem.trim(u8, result.output, " \n");
    if (result.status != 0 or !std.mem.startsWith(u8, text, "early ")) return null;
    return std.fmt.parseInt(u32, text["early ".len..], 10) catch null;
}

fn durability(s: *System.Scenario) void {
    s.singleton_driver("durability_faults", durability_faults);
}

/// Faults at durability points, asked for in a quiet period: only these.
fn durability_faults(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    // Every sync held 200 ms: a file and its directory synced take 400 ms or more.
    const stall_ms = 200;
    sdk.fault(.{
        .kind = "sync_stall",
        .node = echo.name,
        .one_in = 1,
        .stall_ms_min = stall_ms,
        .stall_ms_max = stall_ms,
        .duration_ms = 5000,
    });
    sdk.sleep_ms(100); // The injector applies it.
    const start_ns = monotonic_ns();
    const stalled_written = synced_write(&echo, "/data/stalled");
    const took_ns = monotonic_ns() - start_ns;
    const held = stalled_written and took_ns >= 2 * stall_ms * std.time.ns_per_ms;
    sdk.always(held, "a sync stall holds a node's syncs, and they complete", .{
        .took_ns = took_ns,
        .written = stalled_written,
    });
    sdk.sleep_ms(5000);
    // A crash at the write's first sync, before it: the write's data is gone after the restart
    // (the file may be there, empty: ext4's journal commits every 5 s, and one between its
    // creation and its sync keeps the creation alone).
    try durable_crash_at(&echo, "/data/before", false);
    const before = file_holds(&echo, "/data/before", "written");
    sdk.always(!before, "a crash just before a sync loses the write", .{ .held = before });
    // Just after it: the file synced (its directory entry with it) survives, its data with it.
    try durable_crash_at(&echo, "/data/after", true);
    const after = file_holds(&echo, "/data/after", "written");
    sdk.always(after, "a crash just after a sync keeps the write", .{ .held = after });
    // Two threads syncing at once, at durability points: one crash (a second, asked by the other
    // thread, once switched the disk to dropping writes, failed and left it so: Kafka's run 67 on
    // srv3, a false data loss). Whether both ask is the guest's scheduler's: the guard property
    // watches every run; here, what is synced after the crash survives the next one.
    sdk.fault(.{ .kind = "durable_crash", .node = echo.name, .one_in = 1, .duration_ms = 2000 });
    sdk.sleep_ms(100);
    _ = echo.exec(&.{ "/bin/det-selftest-node", "write2", "/data/two-a", "/data/two-b" }) catch 0;
    sdk.sleep_ms(2000);
    try sdk.retry(100, 100, answers, .{echo.address});
    const kept_written = synced_write(&echo, "/data/kept");
    sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500 });
    sdk.sleep_ms(600);
    try sdk.retry(100, 100, answers, .{echo.address});
    const kept = file_present(&echo, "/data/kept");
    sdk.always(kept_written and kept, "after a crash at a durability point, the disk keeps what " ++
        "is synced next", .{ .written = kept_written, .present = kept });
    // A file rewritten in place long before a power loss, as a log's recovery rebuilds a
    // segment's index (truncated, written again): synced, or only closed (ext4
    // writes a file truncated and written again out as it closes, auto_da_alloc), then two
    // journal commits (5 s each) before the cut. A machine keeps both; ours once gave both back
    // empty (a broker's indexes, run 1838 timeline 64).
    for ([_][]const u8{ "/data/rebuilt-synced", "/data/rebuilt-closed" }) |path| {
        _ = synced_write(&echo, path); // There first, with older content.
    }
    const rebuilt_synced = (echo.exec(&.{ "/bin/det-selftest-node", "rebuild", "/data/rebuilt-synced", "synced" }) catch 1) == 0;
    const rebuilt_closed = (echo.exec(&.{ "/bin/det-selftest-node", "rebuild", "/data/rebuilt-closed", "closed" }) catch 1) == 0;
    sdk.sleep_ms(12_000);
    sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500 });
    sdk.sleep_ms(600);
    try sdk.retry(100, 100, answers, .{echo.address});
    const synced_kept = file_holds(&echo, "/data/rebuilt-synced", "rebuilt");
    const closed_kept = file_holds(&echo, "/data/rebuilt-closed", "rebuilt");
    sdk.always(rebuilt_synced and synced_kept, "a file rewritten in place and synced keeps its content " ++
        "through a power loss", .{ .rewritten = rebuilt_synced, .kept = synced_kept });
    sdk.always(rebuilt_closed and closed_kept, "a file rewritten in place and closed keeps its content " ++
        "through a power loss two journal commits later", .{ .rewritten = rebuilt_closed, .kept = closed_kept });
    // A node that filled its disk (inodes, then blocks) starts again after a power loss, as a
    // machine whose disk is full boots: its start once needed room the node had taken (ClickHouse,
    // run 1279 timeline 2).
    const filled = (echo.exec(&.{ "/bin/det-selftest-node", "fill", "/data/fill" }) catch 1) == 0;
    sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500 });
    sdk.sleep_ms(600);
    const started = if (sdk.retry(100, 100, answers, .{echo.address})) |_| true else |_| false;
    sdk.always(filled and started, "a node whose disk is full starts again after a power loss", .{
        .filled = filled,
        .started = started,
    });
    sdk.stop_faults(0);
}

/// The node crashes at the first sync of a write of `path` (before it or just after), and is
/// back at the fault's end.
fn durable_crash_at(echo: *const sdk.Node, path: []const u8, after_sync: bool) !void {
    const fault_ms = 2000;
    sdk.fault(.{
        .kind = "durable_crash",
        .node = echo.name,
        .one_in = 1,
        .after_sync = after_sync,
        .duration_ms = fault_ms,
    });
    sdk.sleep_ms(100);
    const written = synced_write(echo, path); // Killed in its sync.
    sdk.always(!written, "a write crashed at its sync never returns", .{});
    sdk.sleep_ms(fault_ms);
    try sdk.retry(100, 100, answers, .{echo.address});
}

fn disk_faults(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    const witness = context.nodes.witness.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    // Whichever started first, the other's mount namespace began with its disk in it.
    try witness.crash();
    try sdk.retry(100, 100, answers, .{witness.address});
    try crash_and_wipe(&echo);
    try disk_failures(&echo);
    try outage(&.{ &echo, &witness });
    try partial_power_loss(&echo);
    try rewrite_power_loss(&echo, false);
    try rewrite_power_loss(&echo, true);
    try aimed_corruption(&echo);
    // A file renamed into place by a process gone at once, never synced: the guest's rename
    // tracer finds its node by the path (the e2e check counts node_rename_unsynced).
    _ = echo.exec(&.{ "/bin/det-selftest-node", "rename-unsynced", "/data/renamed-exec" }) catch 1;
    // A file written and never synced, then a restart (a kill, no power loss): the node's start
    // reads what it relies on across the start (persist_trace's node_open_unsynced).
    _ = echo.exec(&.{ "/bin/det-selftest-node", "unsynced", "/data/relied" }) catch 1;
    sdk.fault(.{ .kind = "restart", .node = echo.name, .duration_ms = 300 });
    sdk.sleep_ms(500);
    sdk.retry(100, 100, answers, .{echo.address}) catch {};
    sdk.stop_faults(0);
}

/// A disk fault aimed at one file's blocks (CORDS's one fault in one file): reads of that file
/// from the disk come back corrupted, a file beside it intact, and afterwards both whole.
fn aimed_corruption(echo: *const sdk.Node) !void {
    const written = page_write(echo, "/data/aimed") and page_write(echo, "/data/beside");
    const fault_ms = 1000;
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "corrupt_reads",
        .file = "data/aimed",
        .corrupt_value = 'Z',
        .duration_ms = fault_ms,
    });
    sdk.sleep_ms(100); // The injector applies it.
    var aimed_buffer: [32]u8 = undefined;
    var beside_buffer: [32]u8 = undefined;
    const aimed = page_check(echo, "/data/aimed", &aimed_buffer);
    const beside = page_check(echo, "/data/beside", &beside_buffer);
    sdk.sleep_ms(fault_ms); // Over: the disk healthy again.
    var after_buffer: [32]u8 = undefined;
    const after = page_check(echo, "/data/aimed", &after_buffer);
    sdk.always(written and std.mem.startsWith(u8, aimed, "corrupt") and std.mem.eql(u8, beside, "intact") and
        std.mem.eql(u8, after, "intact"), "a disk fault aimed at one file corrupts its reads alone, until it heals", .{
        .written = written,
        .aimed = aimed,
        .beside = beside,
        .after = after,
    });
}

fn page_write(node: *const sdk.Node, path: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "page-write", path }) catch return false;
    return status == 0;
}

fn page_check(node: *const sdk.Node, path: []const u8, buffer: []u8) []const u8 {
    const result = node.exec_output(&.{ "/bin/det-selftest-node", "page-check", path }, buffer) catch return "failed";
    return std.mem.trim(u8, result.output, " \n");
}

/// A file rewritten in place fifty times and never synced (another file synced between: ext4's
/// journal committed after each), then a power loss, strict or keeping part of what was not
/// synced: it comes back whole (one of its rewrites), empty or absent, as ext4's ordered mode
/// leaves it; never zeros, a size kept without its data (smoke run 1065: a
/// coordinator's status file read as NUL bytes after a power loss).
fn rewrite_power_loss(echo: *const sdk.Node, partial: bool) !void {
    const path = if (partial) "/data/rewritten-partial" else "/data/rewritten";
    const written = echo.exec(&.{ "/bin/det-selftest-node", "rewrite", path, "50" }) catch 1;
    if (partial) {
        sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500, .partial = true, .partial_commit = true });
        sdk.sleep_ms(600);
    } else try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    var buffer: [64]u8 = undefined;
    const output = echo.exec_output(&.{ "/bin/det-selftest-node", "rewrite-read", path }, &buffer) catch {
        sdk.assert_unreachable("a rewritten file is read after a power loss", .{ .partial = partial });
        return;
    };
    const kind = std.mem.trim(u8, output.output, " \n");
    const allowed = std.mem.eql(u8, kind, "whole") or std.mem.eql(u8, kind, "empty") or std.mem.eql(u8, kind, "absent");
    sdk.always(written == 0 and allowed, "a file rewritten in place and never synced comes back whole, empty or absent after a power loss", .{
        .written = written,
        .partial = partial,
        .found = kind,
    });
}

/// A power loss that persists part of what was not synced (nodes.Partial), its journal committed
/// after: of 30 files' unsynced pages, some are there after it (no file of the 30 drawn, a file
/// in three each: (2/3)^30, five in a million), and others lost. Before it, every page is still
/// only in memory: the guest's kernel writes back nothing nobody synced (its flusher woke at
/// once and wrote back a quiet node's dirty pages: trial runs 1075 and 1088). The files are
/// fresh: what of each is kept is a prefix, no page lost before a kept one (a hole, zeros under
/// the size).
fn partial_power_loss(echo: *const sdk.Node) !void {
    const files = "30";
    const pages = "4";
    var delayed_buffer: [2048]u8 = undefined;
    const written: u8 = if (echo.exec_output(&.{ "/bin/det-selftest-node", "pages", "/data/partial", files, pages }, &delayed_buffer)) |result| blk: {
        const said = std.mem.trim(u8, result.output, " \n");
        sdk.event("partial_pages_delayed", .{ .said = said });
        // "delayed N each ...": the pages FIEMAP still gives as delayed allocation.
        const delayed: ?u32 = if (std.mem.indexOf(u8, said, "delayed ")) |at| number: {
            var words = std.mem.tokenizeScalar(u8, said[at + "delayed ".len ..], ' ');
            break :number std.fmt.parseInt(u32, words.next() orelse "", 10) catch null;
        } else null;
        if (result.status == 0) {
            sdk.always(delayed == 30 * 4, "the guest writes back no page nobody synced", .{ .delayed = delayed, .said = said });
        }
        break :blk result.status;
    } else |_| 1;
    sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500, .partial = true, .partial_commit = true });
    sdk.sleep_ms(600);
    try sdk.retry(100, 100, answers, .{echo.address});
    var buffer: [256]u8 = undefined;
    const output = echo.exec_output(&.{ "/bin/det-selftest-node", "pages-read", "/data/partial", files, pages }, &buffer) catch {
        sdk.assert_unreachable("the pages are read after a partial power loss", .{});
        return;
    };
    var words = std.mem.tokenizeAny(u8, output.output, " \n");
    var intact: u32 = 0;
    var lost: u32 = 0;
    var holes: ?u32 = null;
    while (words.next()) |word| {
        const value = std.fmt.parseInt(u32, words.next() orelse break, 10) catch 0;
        if (std.mem.eql(u8, word, "intact")) intact = value;
        if (std.mem.eql(u8, word, "lost")) lost = value;
        if (std.mem.eql(u8, word, "holes")) holes = value;
    }
    sdk.always(holes == 0, "a power loss persisting part of a fresh file keeps a prefix of it", .{
        .intact = intact,
        .lost = lost,
        .holes = holes,
    });
    sdk.always(written == 0 and intact > 0, "a power loss persisting part of what was not synced keeps some pages", .{
        .written = written,
        .intact = intact,
        .lost = lost,
    });
    sdk.sometimes(lost > 0, "a power loss persisting part of what was not synced loses others", .{ .intact = intact, .lost = lost });
}

/// An outage of `group`: each node wrote one file synced and one not just before, and after it
/// each has only the first: all lost power (the fault's event says at the same moment).
fn outage(group: []const *const sdk.Node) !void {
    var names: [2][]const u8 = undefined;
    assert(group.len == names.len);
    var written = true;
    for (group, &names) |node, *name| {
        name.* = node.name;
        written = written and synced_write(node, "/data/outage-synced");
        const status = node.exec(&.{ "/bin/det-selftest-node", "unsynced", "/data/outage-unsynced" }) catch 1;
        written = written and status == 0;
    }
    const fault_ms = 1000;
    sdk.fault(.{ .kind = "outage", .nodes = &names, .duration_ms = fault_ms });
    sdk.sleep_ms(fault_ms + 100);
    var kept = true;
    for (group) |node| {
        try sdk.retry(100, 100, answers, .{node.address});
        kept = kept and file_present(node, "/data/outage-synced") and
            !file_present(node, "/data/outage-unsynced");
    }
    sdk.always(written and kept, "an outage takes its nodes down at once, each keeping only " ++
        "what it synced", .{ .written = written, .kept = kept });
    // A kill outage (nodes that allow restarts, not power losses): processes killed, the
    // kernel's page cache kept, so what was not synced survives too.
    var unsynced_written = true;
    for (group) |node| {
        const status = node.exec(&.{ "/bin/det-selftest-node", "unsynced", "/data/killed-unsynced" }) catch 1;
        unsynced_written = unsynced_written and status == 0;
    }
    sdk.fault(.{ .kind = "outage", .nodes = &names, .power = false, .duration_ms = fault_ms });
    sdk.sleep_ms(fault_ms + 100);
    var survived = true;
    for (group) |node| {
        try sdk.retry(100, 100, answers, .{node.address});
        survived = survived and file_present(node, "/data/killed-unsynced");
    }
    sdk.always(unsynced_written and survived, "a kill outage takes its nodes down at once, each " ++
        "keeping even what it did not sync", .{ .written = unsynced_written, .kept = survived });
}

/// The echo node wrote one file synced and one not (DET_DURABLE). After a crash the first is
/// there and the second is not; after a wipe neither is. In a quiet period: only these.
fn crash_and_wipe(echo: *const sdk.Node) !void {
    try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    const synced = file_present(echo, "/data/synced");
    const unsynced = file_present(echo, "/data/unsynced");
    sdk.event("disk_after_crash", .{ .synced = synced, .unsynced = unsynced });
    sdk.always(synced and !unsynced, "a crash keeps what was synced and loses the rest", .{
        .synced = synced,
        .unsynced = unsynced,
    });
    var environment: [8192]u8 = undefined;
    const wipes_before = start_variable(&environment, "DETERMINISMO_WIPES=") != null;
    try echo.wipe();
    try sdk.retry(100, 100, answers, .{echo.address});
    // The node wrote both again on its fresh start: the wipe lost what the crash kept.
    sdk.always(file_present(echo, "/data/unsynced"), "a wipe starts the node fresh", .{});
    // And its start knows its disk was lost, not new (DETERMINISMO_WIPES; none before any).
    const wipes = start_variable(&environment, "DETERMINISMO_WIPES=");
    sdk.always(!wipes_before and wipes != null and std.mem.eql(u8, wipes.?, "1"), "a node's start " ++
        "after a wipe is told how many times its disk was lost", .{
        .before = wipes_before,
        .after = wipes orelse "",
    });
}

/// Disk faults asked for. Writes a disk drops are acknowledged, synced even, and gone after a
/// crash; writes a disk refuses fail the sync (and the node, its filesystem read-only, starts
/// again at the fault's end); a disk failing every I/O leaves its filesystem with errors, and the
/// node starts again after a crash; a slow disk slows a sync; afterwards the disk works.
fn disk_failures(echo: *const sdk.Node) !void {
    const lost_ms = 1000;
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "lost_writes",
        .duration_ms = lost_ms,
    });
    sdk.sleep_ms(100); // The injector applies it.
    const acknowledged = synced_write(echo, "/data/lost");
    sdk.sleep_ms(lost_ms); // The fault is over: the disk is healthy again.
    try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    const vanished = !file_present(echo, "/data/lost");
    const message = "writes a disk drops are synced, then gone after a crash";
    sdk.always(acknowledged and vanished, message, .{
        .acknowledged = acknowledged,
        .vanished = vanished,
    });

    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "write_errors",
        .duration_ms = 1000,
    });
    sdk.sleep_ms(100);
    sdk.always(!synced_write(echo, "/data/refused"), "a disk refusing writes fails a sync", .{});
    sdk.sleep_ms(1000);
    try sdk.retry(100, 100, answers, .{echo.address});

    // Every I/O failing aborts ext4's journal and the filesystem records the error: the node
    // starts again at the fault's end, and after a crash later (a filesystem that recorded errors
    // refuses an online resize; ParticleDB's smoke run 332's node never started again).
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "errors",
        .duration_ms = 1000,
    });
    sdk.sleep_ms(100);
    _ = synced_write(echo, "/data/errored");
    sdk.sleep_ms(1000);
    try sdk.retry(100, 100, answers, .{echo.address});
    try echo.crash();
    const restarted = if (sdk.retry(100, 100, answers, .{echo.address})) |_| true else |_| false;
    sdk.always(restarted, "a node whose disk recorded errors starts again after a crash", .{});

    const slow_ms = 300;
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "slow",
        .delay_ms = slow_ms,
        .duration_ms = 5000,
    });
    sdk.sleep_ms(100);
    const start_ns = monotonic_ns();
    _ = synced_write(echo, "/data/slow");
    const took_ns = monotonic_ns() - start_ns;
    // A file and its directory synced: data, journal and commit, each waiting.
    sdk.always(took_ns >= 2 * slow_ms * std.time.ns_per_ms, "a slow disk slows a sync", .{
        .took_ns = took_ns,
    });
    sdk.sleep_ms(5000);
    sdk.always(synced_write(echo, "/data/after"), "a disk works again after its faults", .{});
}

/// The node writes the file and syncs it and its directory: whether the disk took it.
fn synced_write(node: *const sdk.Node, path: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "write", path }) catch return false;
    return status == 0;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn inject(s: *System.Scenario) void {
    s.singleton_driver("faults_on_request", faults_on_request);
}

/// In a quiet period (no drawn faults; requested ones still apply), the driver asks for a
/// pause, a graceful stop, a partition from the runner to the node and its isolation: each
/// takes the node away for a while, then it answers again. Isolated, it still reaches itself
/// at its own address, as a host whose cables are cut does.
fn faults_on_request(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    sdk.fault(.{ .kind = "pause", .node = echo.name, .duration_ms = 2000 });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected pause stops the node", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    // The node ignores SIGTERM (no handler, init of its PID namespace): down when its grace
    // period ends in a kill.
    sdk.fault(.{ .kind = "stop", .node = echo.name, .duration_ms = 1000 });
    const down = if (sdk.retry(60, 100, gone, .{echo.address})) |_| true else |_| false;
    sdk.always(down, "an injected stop takes the node down", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    sdk.fault(.{
        .kind = "partition_groups",
        .groups = .{ .{"runner"}, .{echo.name} },
        .direction = "outbound",
        .duration_ms = 1500,
    });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected one-way partition cuts the node off", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    sdk.fault(.{ .kind = "isolate", .node = echo.name, .duration_ms = 1500 });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected isolation cuts the node off", .{});
    var own: [15]u8 = undefined;
    const own_address = std.fmt.bufPrint(&own, "{d}.{d}.{d}.{d}", .{
        echo.address[0], echo.address[1], echo.address[2], echo.address[3],
    }) catch unreachable;
    const itself = echo.exec(&.{ "/bin/det-selftest-node", "ping", own_address }) catch 255;
    sdk.always(itself == 0, "an isolated node still reaches itself at its own address", .{
        .status = itself,
    });
    try sdk.retry(100, 100, answers, .{echo.address});
    // A clock skew: the node's realtime clock 5 s behind the runner's while it lasts (a command
    // in the node joins its time namespace), its absolute deadlines on that clock its own time.
    sdk.fault(.{ .kind = "clock_skew", .node = echo.name, .skip_ms = 5000, .forward = false, .duration_ms = 2000 });
    sdk.sleep_ms(100);
    const skew_ms = realtime_skew_ms(&echo);
    sdk.always(skew_ms != null and @abs(skew_ms.? + 5000) < 500, "an injected clock skew moves the node's realtime clock", .{
        .skew_ms = skew_ms orelse 0,
    });
    const slept = echo.exec(&.{ "/bin/det-selftest-node", "abs-sleep", "300" }) catch 255;
    sdk.always(slept == 0, "a skewed node's absolute realtime deadlines keep their time", .{ .status = slept });
    sdk.sleep_ms(2000);
    const after_ms = realtime_skew_ms(&echo);
    sdk.always(after_ms != null and @abs(after_ms.?) < 500, "a clock skew ends with its fault", .{
        .skew_ms = after_ms orelse 0,
    });
    // A strobe: the skew comes and goes every 300 ms while the fault lasts.
    sdk.fault(.{ .kind = "clock_skew", .node = echo.name, .skip_ms = 5000, .forward = true, .strobe_ms = 300, .duration_ms = 3000 });
    var skewed: u32 = 0;
    var unskewed: u32 = 0;
    for (0..8) |_| {
        sdk.sleep_ms(120);
        const sample = realtime_skew_ms(&echo) orelse continue;
        if (@abs(sample - 5000) < 500) skewed += 1;
        if (@abs(sample) < 500) unskewed += 1;
    }
    sdk.always(skewed > 0 and unskewed > 0, "a strobing clock skew comes and goes", .{
        .skewed = skewed,
        .unskewed = unskewed,
    });
    sdk.sleep_ms(2500);
    sdk.reachable("injected faults came and went", .{});
    sdk.stop_faults(0);
}

/// The node's CLOCK_REALTIME less the runner's (around the command), in milliseconds.
fn realtime_skew_ms(node: *const sdk.Node) ?i64 {
    var buffer: [64]u8 = undefined;
    const before = realtime_ns();
    const answer = node.exec_output(&.{ "/bin/det-selftest-node", "realtime" }, &buffer) catch return null;
    const after = realtime_ns();
    if (answer.status != 0) return null;
    const theirs = std.fmt.parseInt(i128, std.mem.trim(u8, answer.output, " \n"), 10) catch return null;
    return @intCast(@divTrunc(theirs - @divTrunc(before + after, 2), std.time.ns_per_ms));
}

fn realtime_ns() i128 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    return @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
}

/// A spare node started late: for 20 s faults find it not running (and skip it), then the driver
/// starts it and it answers; faults reach it from then on.
fn spare_scenario(s: *System.Scenario) void {
    s.singleton_driver("spare_start", spare_start);
}

fn spare_start(context: *System.Context) !void {
    const spare = &context.nodes.witness.?;
    sdk.sleep_ms(20 * std.time.ms_per_s);
    try spare.start();
    var reply: [16]u8 = undefined;
    for (0..200) |_| {
        const answer = request(spare.address, "ping\n", &reply) catch {
            sdk.sleep_ms(100);
            continue;
        };
        sdk.always(std.mem.eql(u8, answer, "ping\n"), "the spare echoes once started", .{});
        sdk.reachable("the spare node started and answered", .{});
        break;
    }
    sdk.sleep_ms(20 * std.time.ms_per_s); // Faults reach it now.
}

fn frozen_start_scenario(s: *System.Scenario) void {
    s.singleton_driver("frozen_start", frozen_start);
}

/// The echo node frozen, killed and started again: a start into its frozen cgroup (an outage
/// froze the node, a driver's wipe started it before the outage's crash came to it) thaws it,
/// and it answers. Frozen, its first process never reached its program and the start waited
/// for it for good, the start lock held (dqlite run 746, timeline 313).
fn frozen_start(context: *System.Context) !void {
    const node = &context.nodes.echo.?;
    try node.pause();
    try node.kill();
    try node.start();
    var reply: [16]u8 = undefined;
    for (0..200) |_| {
        const answer = request(node.address, "ping\n", &reply) catch {
            sdk.sleep_ms(100);
            continue;
        };
        sdk.always(std.mem.eql(u8, answer, "ping\n"), "a node started while frozen echoes", .{});
        sdk.reachable("a node started while frozen ran and answered", .{});
        return;
    }
}

fn hangup_scenario(s: *System.Scenario) void {
    s.singleton_driver("hangup", hangup);
}

/// A process of the driver's, in a process group of its own, starts the echo node again, stops
/// its process (SIGSTOP, as a process pause does) and exits; then the driver continues the node,
/// which answers. Started from that process, the node was in its group, which its exit left
/// orphaned with a stopped member, and the kernel sent each member SIGHUP (dqlite run 746,
/// timeline 116: the member driver exited at 41.62 s, and n2, n5 and n3, which it had started,
/// exited 2 within 0.1 s; Go's runtime, PID 1 of its namespace, dies of it with exit 2, as this
/// node's handler does).
fn hangup(context: *System.Context) !void {
    const echo = &context.nodes.echo.?;
    const starter = linux.fork();
    if (linux.errno(starter) != .SUCCESS) return error.Fork;
    if (starter == 0) {
        _ = linux.setpgid(0, 0);
        echo.kill() catch linux.exit_group(1);
        echo.start() catch linux.exit_group(1);
        const pid = pid_read("/run/det/nodes/echo/pid") catch linux.exit_group(1);
        _ = linux.kill(pid, .STOP);
        // Stopped before this process exits, as a paused node is long before.
        for (0..100) |_| {
            if (state_of(pid) == 'T') linux.exit_group(0);
            sdk.sleep_ms(10);
        }
        linux.exit_group(1);
    }
    var status: i32 = 0;
    while (linux.errno(linux.waitpid(@intCast(starter), &status, 0)) == .INTR) {}
    if (status != 0) return error.StarterFailed;
    sdk.sleep_ms(200);
    _ = linux.kill(try pid_read("/run/det/nodes/echo/pid"), .CONT);
    var reply: [16]u8 = undefined;
    for (0..50) |_| {
        const answer = request(echo.address, "ping\n", &reply) catch {
            sdk.sleep_ms(100);
            continue;
        };
        sdk.always(std.mem.eql(u8, answer, "ping\n"), "a stopped node outlives its starter's exit", .{});
        sdk.reachable("a stopped node answered after its starter's exit", .{});
        return;
    }
}

/// A process's state letter, from /proc/<pid>/stat (after the command name's parenthesis).
fn state_of(pid: linux.pid_t) u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return 0;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [512]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    const close = std.mem.lastIndexOfScalar(u8, buffer[0..size], ')') orelse return 0;
    return if (close + 2 < size) buffer[close + 2] else 0;
}

fn continue_and_ping(context: *System.Context) !void {
    const echo = &context.nodes.echo.?;
    _ = linux.kill(try pid_read("/run/det/nodes/echo/pid"), .CONT);
    var reply: [16]u8 = undefined;
    for (0..50) |_| {
        const answer = request(echo.address, "ping\n", &reply) catch {
            sdk.sleep_ms(100);
            continue;
        };
        sdk.always(std.mem.eql(u8, answer, "ping\n"), "a stopped node outlives its starter's exit", .{});
        sdk.reachable("a stopped node answered after its starter's exit", .{});
        return;
    }
}

/// A node's pid, as det-nodes records it.
fn pid_read(path: [:0]const u8) !linux.pid_t {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoPidFile;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return error.NoPidFile;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..size], " \n"), 10);
}

fn aim_scenario(s: *System.Scenario) void {
    s.singleton_driver("aim_at_witness", aim_at_witness);
}

/// Aims the injector at the echo node briefly, then at the witness for a while (the aim moves,
/// as when a leader changes): the e2e check counts where the pauses went.
fn aim_at_witness(context: *System.Context) !void {
    sdk.fault_aim(context.nodes.echo.?.name);
    sdk.sleep_ms(2 * std.time.ms_per_s);
    sdk.fault_aim(context.nodes.witness.?.name);
    sdk.sleep_ms(40 * std.time.ms_per_s);
    sdk.reachable("the driver aimed the faults for a while", .{});
}

/// Snapshotted before the nodes start (schema.Scenario.snapshot_before_nodes): each timeline
/// starts echo itself, so its start's number ($DETERMINISMO_DRAW) is the timeline's own. The e2e
/// `before-nodes` check finds both parities across 8 timelines.
fn before_nodes_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.snapshot_before_nodes = true;
    s.parallel_driver("draw", draw_read);
}

fn draw_read(_: *System.Context) !void {
    var buffer: [16384]u8 = undefined;
    const draw = start_draw_value(&buffer) orelse return;
    sdk.assert_computed(.sometimes, draw % 2 == 0, "a timeline's echo start drew an even number", .{ .draw = draw });
    sdk.assert_computed(.sometimes, draw % 2 == 1, "a timeline's echo start drew an odd number", .{ .draw = draw });
}

/// The number echo's start was given ($DETERMINISMO_DRAW in its environment), or null.
fn start_draw_value(buffer: []u8) ?u64 {
    const pid = pid_read("/run/det/nodes/echo/pid") catch return null;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var entries = std.mem.splitScalar(u8, buffer[0..size], 0);
    while (entries.next()) |entry| {
        const key = "DETERMINISMO_DRAW=";
        if (std.mem.startsWith(u8, entry, key)) return std.fmt.parseInt(u64, entry[key.len..], 10) catch null;
    }
    return null;
}

/// A finally command that never ends on its own, in a window of 2 s: killed once the window
/// passes, the timeline goes on to its end ("an ending command finishes within its window"
/// fails).
fn ending_window_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.ending_ms_max = 2000;
    s.parallel_driver("quick", quick_driver);
    s.finally("never", never_ends);
}

fn quick_driver(_: *System.Context) !void {
    sdk.sleep_ms(100);
}

fn never_ends(_: *System.Context) !void {
    sdk.reachable("an ending command began", .{});
    while (true) sdk.sleep_ms(1000);
}

/// Drivers of 3 s each, as many starts as the composer draws: past half the timeline limit no
/// more start, and the timeline finishes (the e2e check gives it 30 s).
fn slow_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.parallel_driver("slow", slow_driver);
}

fn slow_driver(_: *System.Context) !void {
    sdk.sleep_ms(3 * std.time.ms_per_s);
    sdk.reachable("a slow driver finished", .{});
}

/// One slot (parallel_max 1), a driver holding it past half the timeline limit, and another
/// start waiting for it: the wait ends at the stop, no start after it (a start that waited for
/// the only slot began past the stop: CE5's other path, the Lean replica of determinismo).
fn slot_wait_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.parallel_max = 1;
    s.parallel_driver("holding", holding_driver);
    s.parallel_driver("next", next_driver);
}

fn holding_driver(_: *System.Context) !void {
    sdk.sleep_ms(20 * std.time.ms_per_s);
}

fn next_driver(_: *System.Context) !void {
    sdk.sleep_ms(100);
}

/// Half the timelines reach a marked state (a `sometimes` made true), among the selftest's other
/// new behaviors: the tree returns just after the marked state first (the e2e check reads why).
fn sought_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("wander", wander);
}

fn wander(_: *System.Context) !void {
    sdk.sleep_ms(500);
    if (sdk.random_below(2) == 0) sdk.sometimes(true, "a marked state was reached", .{});
    sdk.sleep_ms(200);
    _ = sdk.random_below(2); // A draw after it: its moment leads elsewhere.
    sdk.sleep_ms(3000);
}

/// A streak of coin flips won, reset by any loss: 24 in a row is one chance in 16 million at
/// each step, out of reach by chance. Optimized (sdk.optimize: the streak, maximized), the tree
/// returns to the longest streak yet and goes on from it, as Antithesis's explorer kept the
/// state with the most missiles; blind, the same flips with nothing said.
fn streak_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("flips", flips_optimized);
}

fn streak_blind_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("flips", flips_blind);
}

fn flips_optimized(_: *System.Context) !void {
    flips(true);
}

fn flips_blind(_: *System.Context) !void {
    flips(false);
}

const streak_wanted = 24;

fn flips(optimized: bool) void {
    var streak: u32 = 0;
    for (0..400) |_| {
        sdk.sleep_ms(20);
        streak = if (sdk.random_below_named("flip", 2) == 1) streak + 1 else 0;
        if (optimized) sdk.optimize("streak", .{}, @floatFromInt(streak), .maximize);
        if (streak >= streak_wanted) {
            sdk.event("streak_won", .{ .length = streak });
            return;
        }
    }
}

/// ingress: connections from outside into a deterministic machine (sdk.ingress, explore
/// --ingress): an HTTP server on the runner's 127.0.0.1:8080, det-ingress in front of it; what
/// the outside asks is served (each request's path, size and sum said back, /big 256 KiB),
/// until /end. Replayed from its tape with nobody outside, the same requests at the same
/// moments (tools/e2e.zig: ingress).
fn ingress_scenario(s: *System.Scenario) void {
    s.singleton_driver("ingress", ingress_driver);
}

fn ingress_driver(context: *System.Context) !void {
    _ = context;
    const server = linux.fork();
    if (linux.errno(server) != .SUCCESS) return error.Fork;
    if (server == 0) {
        ingress_serve();
        linux.exit_group(0);
    }
    const relay = linux.fork();
    if (linux.errno(relay) != .SUCCESS) return error.Fork;
    if (relay == 0) {
        const argv = [_:null]?[*:0]const u8{ "det-ingress", "serve", "8080" };
        const environment = [_:null]?[*:0]const u8{};
        _ = linux.execve("/opt/determinismo/bin/det-ingress", &argv, &environment);
        linux.exit_group(127);
    }
    // Until the outside's /end: ten virtual minutes at most (the live timeline paced to the
    // wall clock, a replay at its own speed).
    var ended = false;
    for (0..6000) |_| {
        var status: i32 = 0;
        const reaped = linux.waitpid(@intCast(server), &status, linux.W.NOHANG);
        if (linux.errno(reaped) == .SUCCESS and reaped == server) {
            ended = true;
            break;
        }
        sdk.sleep_ms(100);
    }
    sdk.always(ended, "ingress delivers the outside's requests to the end", .{});
    _ = linux.kill(@intCast(relay), .TERM);
    if (!ended) _ = linux.kill(@intCast(server), .KILL);
}

/// The node's HTTP server: one connection at a time, each one request (Connection: close).
fn ingress_serve() void {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return;
    const listener: linux.fd_t = @intCast(socket);
    const one: i32 = 1;
    _ = linux.setsockopt(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 8080), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.bind(listener, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return;
    if (linux.errno(linux.listen(listener, 64)) != .SUCCESS) return;
    var served: u32 = 0;
    const received = std.heap.page_allocator.alloc(u8, 1 << 20) catch return;
    while (true) {
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) continue;
        const client: linux.fd_t = @intCast(accepted);
        defer _ = linux.close(client);
        // The head, then the body its Content-Length says.
        var used: usize = 0;
        const head_end = while (used < received.len) {
            const result = linux.read(client, received[used..].ptr, received.len - used);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) break null;
            used += result;
            if (std.mem.indexOf(u8, received[0..used], "\r\n\r\n")) |at| break at + 4;
        } else null;
        const head = received[0 .. head_end orelse continue];
        var length: usize = 0;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const first = lines.next() orelse continue;
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                length = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10) catch 0;
            }
        }
        while (used < head.len + length and used < received.len) {
            const result = linux.read(client, received[used..].ptr, received.len - used);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            used += result;
        }
        const body = received[head.len..@min(used, head.len + length)];
        var words = std.mem.tokenizeScalar(u8, first, ' ');
        _ = words.next();
        const path = words.next() orelse "/";
        served += 1;
        var sum: u64 = 0;
        for (body) |byte| sum += byte;
        sdk.event("ingress_request", .{ .n = served, .path = path, .bytes = body.len, .sum = sum });
        var answer_buffer: [256]u8 = undefined;
        const big = std.mem.eql(u8, path, "/big");
        const answer = std.fmt.bufPrint(&answer_buffer, "ingress {d}: {s} {d} bytes, sum {d}\n", .{ served, path, body.len, sum }) catch continue;
        const size = if (big) 256 * 1024 else answer.len;
        var header_buffer: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{size}) catch continue;
        ingress_write(client, header);
        if (big) {
            var block: [4096]u8 = undefined;
            for (&block, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
            for (0..size / block.len) |_| ingress_write(client, &block);
        } else ingress_write(client, answer);
        if (std.mem.eql(u8, path, "/end")) return;
    }
}

/// All of `bytes`, a signal's interruption retried: the default faults deliver signals processes
/// catch, and a blocking write they interrupt returns EINTR (the first version gave up there, its
/// 256 KiB answers cut at about 26 KB: the ingress check's download).
fn ingress_write(fd: linux.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return,
        }
    }
}

/// egress: a deterministic machine's connection out (sdk.egress, explore --egress): det-egress in
/// the runner, a CONNECT through it to 127.0.0.1:7899 (the host's server, allowed) and a GET of
/// egress.txt, its body read (retried through the boundary's faults); then a CONNECT to
/// 127.0.0.1:7898 (not allowed): refused. Replayed
/// from its tape with the server gone, the same bytes (tools/e2e.zig: egress).
/// fork_pull: sdk.fork outside a session (nothing cloned: it answers 0), then 200 events past
/// several checkpoints, so that a replay from the tape compares them (tools/e2e.zig:
/// fork-replay; the Lean replica of determinismo's CE12: a replayed fork pull emitted no
/// decision event, one event short from there).
fn fork_pull_scenario(s: *System.Scenario) void {
    s.singleton_driver("fork-pull", fork_pull_driver);
}

fn fork_pull_driver(_: *System.Context) !void {
    const index = sdk.fork(2);
    sdk.always(index == 0, "outside a session a fork clones nothing", .{ .index = index });
    for (0..200) |step| sdk.event("fork_pull_step", .{ .step = step });
}

fn egress_scenario(s: *System.Scenario) void {
    s.singleton_driver("egress", egress_driver);
}

fn egress_driver(context: *System.Context) !void {
    _ = context;
    const proxy = linux.fork();
    if (linux.errno(proxy) != .SUCCESS) return error.Fork;
    if (proxy == 0) {
        const argv = [_:null]?[*:0]const u8{ "det-egress", "serve", "3128" };
        const environment = [_:null]?[*:0]const u8{};
        _ = linux.execve("/opt/determinismo/bin/det-egress", &argv, &environment);
        linux.exit_group(127);
    }
    var body: [4096]u8 = undefined;
    // Retried as a client does: the boundary's faults (refused, reset, slow) are drawn per
    // connection, at most three in eight.
    const allowed = for (0..10) |_| {
        const answer = egress_get("127.0.0.1:7899", &body);
        if (std.mem.indexOf(u8, answer, "through a deterministic machine") != null) break answer;
        sdk.event("egress_retry", .{ .answer = answer });
    } else "";
    sdk.event("egress_answer", .{ .text = allowed });
    sdk.always(std.mem.indexOf(u8, allowed, "through a deterministic machine") != null, "egress reaches an allowed server", .{ .answer = allowed });
    var refused_buffer: [4096]u8 = undefined;
    const refused = egress_get("127.0.0.1:7898", &refused_buffer);
    sdk.always(std.mem.startsWith(u8, refused, "HTTP/1.1 502"), "egress refuses a server not allowed", .{ .answer = refused });
    _ = linux.kill(@intCast(proxy), .TERM);
}

/// A CONNECT to `target` through det-egress on 127.0.0.1:3128, then a GET of /egress.txt: what
/// came back (the proxy's refusal, or the server's answer), at most `buffer`'s length.
fn egress_get(target: []const u8, buffer: []u8) []const u8 {
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 3128), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const fd: linux.fd_t = for (0..200) |_| {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return "";
        const attempt: linux.fd_t = @intCast(socket);
        if (linux.errno(linux.connect(attempt, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) == .SUCCESS) break attempt;
        _ = linux.close(attempt);
        sdk.sleep_ms(10); // det-egress still starting.
    } else return "";
    defer _ = linux.close(fd);
    var connect_buffer: [256]u8 = undefined;
    const connect = std.fmt.bufPrint(&connect_buffer, "CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n\r\n", .{ target, target }) catch return "";
    _ = linux.write(fd, connect.ptr, connect.len);
    var used: usize = 0;
    // The proxy's answer to the CONNECT, to its blank line.
    while (used < buffer.len and std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") == null) {
        const result = linux.read(fd, buffer[used..].ptr, buffer.len - used);
        if (linux.errno(result) != .SUCCESS or result == 0) return buffer[0..used];
        used += result;
    }
    if (!std.mem.startsWith(u8, buffer[0..used], "HTTP/1.1 200")) return buffer[0..used];
    const get = "GET /egress.txt HTTP/1.0\r\nHost: localhost\r\n\r\n";
    _ = linux.write(fd, get, get.len);
    used = 0;
    while (used < buffer.len) {
        const result = linux.read(fd, buffer[used..].ptr, buffer.len - used);
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        used += result;
    }
    return buffer[0..used];
}

fn hang(s: *System.Scenario) void {
    s.singleton_driver("forever", forever);
}

/// A driver that never ends (an hour of sleep): the timeline's ceiling ends it as hung.
fn forever(_: *System.Context) !void {
    sdk.sleep_ms(std.time.ms_per_hour);
}

fn hang_sometimes(s: *System.Scenario) void {
    s.singleton_driver("maybe_forever", maybe_forever);
}

/// An hour asleep in one timeline of eight, else one to three seconds.
fn maybe_forever(_: *System.Context) !void {
    if (sdk.random_below(8) == 0) return sdk.sleep_ms(std.time.ms_per_hour);
    sdk.sleep_ms(1000 + sdk.random_below(2000));
}

fn readdress(s: *System.Scenario) void {
    s.singleton_driver("restarts", restarts);
}

/// Restarts asked for, in a quiet period: each time the node answers at its name (where the
/// hosts file says it is); across timelines, sometimes at a new address.
fn restarts(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    var moved = false;
    for (0..4) |_| {
        sdk.fault(.{ .kind = "restart", .node = echo.name, .duration_ms = 200 });
        sdk.sleep_ms(300); // The fault is over: it started again, maybe elsewhere.
        const found = host_address(echo.name);
        const back = if (found) |address|
            if (sdk.retry(100, 100, answers, .{address})) |_| true else |_| false
        else
            false;
        sdk.always(back, "a restarted node answers at its name", .{});
        if (found) |address| moved = moved or !std.mem.eql(u8, &address, &echo.address);
    }
    sdk.sometimes(moved, "a restarted node comes back at a new address", .{});
    sdk.stop_faults(0);
}

fn file_error_scenario(s: *System.Scenario) void {
    s.singleton_driver("file_errors", file_errors_injected);
}

/// ENOSPC on every write of the node's disk files for a second: its appends fail with it, its
/// reads do not; after, its appends succeed again.
fn file_errors_injected(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    var reply: [32]u8 = undefined;
    const before = request(echo.address, "append\n", &reply) catch "unanswered";
    sdk.always(std.mem.eql(u8, before, "ok\n"), "the node appends to its disk before the file errors", .{});
    sdk.fault(.{ .kind = "file_error", .node = echo.name, .duration_ms = 1000, .file_calls = "writes", .errno = "NOSPC" });
    sdk.sleep_ms(300);
    const during = request(echo.address, "append\n", &reply) catch "unanswered";
    sdk.always(std.mem.eql(u8, during, "NOSPC\n"), "a write error the scenario asks for fails the node's append (ENOSPC)", .{ .answer = during });
    const read = request(echo.address, "read\n", &reply) catch "unanswered";
    sdk.always(std.mem.eql(u8, read, "ok\n"), "the node's reads go on under write errors", .{ .answer = read });
    sdk.sleep_ms(1500);
    const after = request(echo.address, "append\n", &reply) catch "unanswered";
    sdk.always(std.mem.eql(u8, after, "ok\n"), "the node appends again once its file errors end", .{ .answer = after });
    // Short writes: every buffered write moves part of what it was asked.
    sdk.fault(.{ .kind = "file_error", .node = echo.name, .duration_ms = 1000, .file_calls = "short_writes" });
    sdk.sleep_ms(300);
    const shortened = request(echo.address, "append\n", &reply) catch "unanswered";
    sdk.always(std.mem.eql(u8, shortened, "short\n"), "a short write the scenario asks for writes part of the node's append", .{ .answer = shortened });
    sdk.sleep_ms(1500);
    sdk.stop_faults(0);
}

fn drivers_scenario(s: *System.Scenario) void {
    s.parallel_driver("workload", driver_ran);
    s.parallel_driver("nemesis_a", driver_ran);
    s.parallel_driver("nemesis_b", driver_ran);
    s.workload("workload");
}

/// The same three drivers, none marked: the composer keeps them all, weighted per timeline.
/// A singleton marked as the workload beside two parallel nemeses (tools/e2e.zig:
/// workload-singleton): a timeline that doesn't draw the singleton still runs a driver (the Lean
/// replica of determinismo's CE3: the swarm's rescue had nothing to keep, the composer panicked).
fn workload_singleton_scenario(s: *System.Scenario) void {
    s.singleton_driver("workload", driver_ran);
    s.parallel_driver("nemesis_a", driver_ran);
    s.parallel_driver("nemesis_b", driver_ran);
    s.workload("workload");
}

/// A serial driver, and a singleton, that outlast any timeline length (tools/e2e.zig:
/// length-bounds): with --timeline 30s each is killed after the length's grace, the faults with
/// it (the Lean replica of determinismo's CE4: they ran their 300 s).
fn serial_slow_scenario(s: *System.Scenario) void {
    s.serial_driver("slow", length_slow_driver);
}

fn singleton_slow_scenario(s: *System.Scenario) void {
    s.singleton_driver("slow", length_slow_driver);
}

fn length_slow_driver(_: *System.Context) !void {
    sdk.sleep_ms(300_000);
}

fn drivers_unmarked_scenario(s: *System.Scenario) void {
    s.parallel_driver("workload", driver_ran);
    s.parallel_driver("nemesis_a", driver_ran);
    s.parallel_driver("nemesis_b", driver_ran);
}

fn driver_ran(context: *System.Context) !void {
    _ = context;
    sdk.sleep_ms(10);
}

/// (profile "durable") Drawn faults over idle drivers: power losses, and aftershocks (a power loss
/// soon after a node started again, faults.zig) among them.
/// (profile "durable") A small record removed, created again and appended, never synced, a file
/// synced after it (a storage engine's WAL), then a power loss: strict, partial with the journal
/// committed, or partial without, drawn; thirty rounds. Stock ext4 gives it back whole, empty or
/// absent (430 trials on srv4's 6.12, 2026-11-08: a writeback started or finished, the journal
/// committed, the disk dropping writes at the cut), never its size in NULs, which a temporary
/// directories' record showed after our partial power losses (hunt run 1506).
/// A process failing one call 1,000 times with no pause (a tight retry loop: open of a missing
/// file, ENOENT), another failing 50 times 50 ms apart (close of a bad descriptor, EBADF): with
/// --trace-errno 0, errno_trace's storm for the first only, its failures past the storm's 100 not
/// each an event.
fn errno_storm_scenario(s: *System.Scenario) void {
    s.singleton_driver("storm", errno_storms);
}

fn errno_storms(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    _ = echo.exec(&.{ "/bin/det-selftest-node", "fail-loop", "open", "1000", "0" }) catch 1;
    _ = echo.exec(&.{ "/bin/det-selftest-node", "fail-loop", "close", "50", "50" }) catch 1;
    sdk.sleep_ms(500); // The trace's last lines read.
}

fn record_power_loss_scenario(s: *System.Scenario) void {
    s.singleton_driver("records", records_power_losses);
}

fn records_power_losses(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(3600 * std.time.ns_per_s);
    defer sdk.stop_faults(0);
    const path = "/data/record";
    const conf = "/data/nodes.conf";
    for (0..30) |round| {
        const written = echo.exec(&.{ "/bin/det-selftest-node", "record", path }) catch 1;
        // A cluster's node table beside it: renamed over the last one, never synced.
        const renamed = echo.exec(&.{ "/bin/det-selftest-node", "conf", conf }) catch 1;
        sdk.sleep_ms(sdk.random_below(2000));
        const shape = sdk.random_below(3);
        switch (shape) {
            0 => echo.crash() catch {},
            else => sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 300, .partial = true, .partial_commit = shape == 1 }),
        }
        sdk.sleep_ms(600);
        sdk.retry(100, 100, answers, .{echo.address}) catch {};
        var buffer: [64]u8 = undefined;
        const output = echo.exec_output(&.{ "/bin/det-selftest-node", "record-read", path }, &buffer) catch continue;
        const kind = std.mem.trim(u8, output.output, " \n");
        const allowed = std.mem.eql(u8, kind, "whole") or std.mem.eql(u8, kind, "empty") or std.mem.eql(u8, kind, "absent");
        sdk.always(written == 0 and allowed, "a small record removed and appended again, never synced, comes back whole, empty or absent after a power loss", .{
            .round = round,
            .written = written,
            .shape = shape,
            .found = kind,
        });
        const conf_output = echo.exec_output(&.{ "/bin/det-selftest-node", "conf-read", conf }, &buffer) catch continue;
        const conf_kind = std.mem.trim(u8, conf_output.output, " \n");
        // Its last version or the one before (whole either way: the same bytes), never NULs.
        const conf_allowed = std.mem.eql(u8, conf_kind, "whole") or std.mem.eql(u8, conf_kind, "empty") or std.mem.eql(u8, conf_kind, "absent");
        sdk.always(renamed == 0 and conf_allowed, "a file renamed over another, never synced, comes back whole, empty or absent after a power loss", .{
            .round = round,
            .renamed = renamed,
            .shape = shape,
            .found = conf_kind,
        });
    }
}

fn aftershock_scenario(s: *System.Scenario) void {
    s.parallel_driver("idle", driver_idle);
    s.parallel_driver("rename", driver_rename_unsynced);
}

/// A file renamed over another and never synced, in the echo node (persist_trace reports it and
/// asks the injector for an aftershock). Under one of 676 directories, each a shape of its own
/// (persist_trace reports a shape's first rename a timeline: numbers are one shape).
fn driver_rename_unsynced(context: *System.Context) !void {
    const echo = context.nodes.echo orelse return;
    var path_buffer: [64]u8 = undefined;
    const first: u8 = @intCast('a' + sdk.random_below(26));
    const second: u8 = @intCast('a' + sdk.random_below(26));
    const path = try std.fmt.bufPrint(&path_buffer, "/data/{c}{c}-after", .{ first, second });
    _ = echo.exec(&.{ "/bin/det-selftest-node", "rename-unsynced", path }) catch 1;
}

fn driver_idle(context: *System.Context) !void {
    _ = context;
    sdk.sleep_ms(2000);
}

fn metastable_scenario(s: *System.Scenario) void {
    s.singleton_driver("open_loop", open_loop_metastable);
}

fn stable_scenario(s: *System.Scenario) void {
    s.singleton_driver("open_loop", open_loop_stable);
}

/// 8 s: under the full queue's wait (10 requests ahead at a second each), every request admitted
/// then times out, and its retries keep the queue full.
fn open_loop_metastable(context: *System.Context) !void {
    try open_loop(context, 8_000);
}

fn open_loop_stable(context: *System.Context) !void {
    try open_loop(context, 20_000);
}

const queue_port = 7100;

/// The talk's load through the SDK's open loop (sdk.open_loop), its policy fixed: 0.5 requests a
/// second for 30 s, 2 a second for a minute (the trigger), then 0.5 a second for 4 minutes; each
/// client retries, 20 times at most, at once on a timeout and a second after a refusal (requests
/// "in orbit"). Goodput from a minute to three after the trigger must be 80% of what is offered.
fn open_loop(context: *System.Context, timeout_ms: u32) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(3600 * std.time.ns_per_s);
    const result = try std.heap.page_allocator.create(sdk.open_loop.Result);
    defer std.heap.page_allocator.destroy(result);
    sdk.open_loop.run(QueueClient{ .address = echo.address }, QueueClient.call, .{
        .base_milli = 500,
        .spike = 4,
        .before_s = 30,
        .trigger_s = 60,
        .after_s = 240,
        .retry = .{ .timeout_ms = timeout_ms, .retries = 20, .backoff_ms = 1000, .exponential = false },
        .policy = "storm",
    }, result);
    var buffer: [40]u32 = undefined;
    sdk.always(result.recovered(60, 120, 80), "goodput recovers after an overload", result.summary(&buffer));
    sdk.stop_faults(0);
}

/// One attempt at the toy queue service: "done", "busy" (refused: the queue full), or no answer
/// within the timeout.
const QueueClient = struct {
    address: [4]u8,

    fn call(client: QueueClient, timeout_ms: u32) sdk.open_loop.Outcome {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return .failed;
        const fd: linux.fd_t = @intCast(socket);
        defer _ = linux.close(fd);
        const timeout: linux.timeval = .{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));
        const target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, queue_port), .addr = @bitCast(client.address) };
        if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return .failed;
        _ = linux.write(fd, "work\n", 5);
        var reply: [8]u8 = undefined;
        const size = linux.read(fd, &reply, reply.len);
        if (linux.errno(size) == .AGAIN) return .timed_out;
        if (linux.errno(size) != .SUCCESS or size < 4) return .failed;
        if (std.mem.eql(u8, reply[0..4], "done")) return .done;
        if (std.mem.eql(u8, reply[0..4], "busy")) return .refused;
        return .failed;
    }
};

fn cache_scenario(s: *System.Scenario) void {
    s.parallel_driver("cache", cache_operations);
}

const cache_capacity = 64;
const cache_operations_max = 300;

/// A bounded cache's size under inserts, reads and removes. Drawn uniformly, inserts and removes
/// keep it a random walk near zero: in 300 operations it reaches 64 almost never. A swarm's
/// timeline without removes, or with them rare, fills it, and eviction runs: its bug.
fn cache_operations(context: *System.Context) !void {
    _ = context;
    const Operation = enum { insert, read, remove };
    var size: u32 = 0;
    for (0..cache_operations_max) |_| {
        switch (sdk.swarm_choice(Operation, "cache.operation")) {
            .insert => {
                if (size == cache_capacity) {
                    sdk.assert_unreachable("the cache's eviction is never reached (its bug)", .{ .size = size });
                    size -= 1;
                }
                size += 1;
            },
            .read => {},
            .remove => size -|= 1,
        }
    }
}

fn syscall_error_scenario(s: *System.Scenario) void {
    s.singleton_driver("syscall_errors", syscall_errors_injected);
}

/// The node's accept4 fails with EMFILE, every call, for a second: it marks /tmp/emfile and backs
/// off; once the fault ends its accepts succeed again. The fault fails calls as they begin: the
/// accept the node is blocked in when it starts returns the connection made during it, and its
/// next one fails.
fn syscall_errors_injected(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    sdk.fault(.{ .kind = "syscall_error", .node = echo.name, .duration_ms = 1000, .syscall = "accept4", .errno = "MFILE" });
    sdk.sleep_ms(200);
    answers(echo.address) catch {};
    sdk.sleep_ms(300);
    sdk.always(file_present(&echo, "/tmp/emfile"), "a system call error the scenario asks for reaches the node (accept4, EMFILE)", .{});
    sdk.sleep_ms(1500);
    const back = if (sdk.retry(50, 100, answers, .{echo.address})) |_| true else |_| false;
    sdk.always(back, "the node answers once its system call errors end", .{});
    sdk.stop_faults(0);
}

fn signal_scenario(s: *System.Scenario) void {
    s.singleton_driver("signals", signals_sent);
}

/// Signal faults asked for, in a quiet period: the node's blocked accept returns EINTR (it marks
/// /tmp/eintr), as a handler installed without SA_RESTART makes it.
fn signals_sent(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    for (0..3) |_| {
        sdk.fault(.{ .kind = "signal", .node = echo.name, .duration_ms = 100 });
        sdk.sleep_ms(300);
    }
    sdk.always(file_present(&echo, "/tmp/eintr"), "a signal the node catches interrupts its accept (EINTR)", .{});
    const back = if (sdk.retry(50, 100, answers, .{echo.address})) |_| true else |_| false;
    sdk.always(back, "the node answers after its signals", .{});
    sdk.stop_faults(0);
}

fn unlist(s: *System.Scenario) void {
    s.singleton_driver("stops", stops);
}

/// Stops asked for, in a quiet period: while the echo node is down, its name is in the runner's
/// hosts file always and in the witness's not always; once it started again, in both.
fn stops(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    const witness = context.nodes.witness.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    var gone_once = false;
    for (0..6) |_| {
        sdk.fault(.{ .kind = "stop", .node = echo.name, .duration_ms = 3000 });
        sdk.sleep_ms(1000); // Down: stopped, not started again yet.
        sdk.always(host_address(echo.name) != null, "the runner names a node that is down", .{});
        const listed = witness.exec(&.{ "/bin/det-selftest-node", "hosts-has", echo.name }) catch 2;
        sdk.always(listed <= 1, "a peer's hosts file is read", .{ .status = listed });
        gone_once = gone_once or listed == 1;
        sdk.sleep_ms(4000); // Started again.
        const back = if (sdk.retry(50, 100, answers, .{echo.address})) |_| true else |_| false;
        const relisted = witness.exec(&.{ "/bin/det-selftest-node", "hosts-has", echo.name }) catch 2;
        sdk.always(back and relisted == 0, "a node started again is named in its peers' hosts files", .{
            .back = back,
            .status = relisted,
        });
    }
    sdk.sometimes(gone_once, "a node down is gone from its peers' hosts files", .{});
    sdk.stop_faults(0);
}

/// Where /etc/hosts says `name` is.
fn host_address(name: []const u8) ?[4]u8 {
    var buffer: [4096]u8 = undefined;
    const fd = linux.open("/etc/hosts", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var lines = std.mem.tokenizeScalar(u8, buffer[0..size], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const text = fields.next() orelse continue;
        const host = fields.next() orelse continue;
        if (!std.mem.eql(u8, host, name)) continue;
        var address: [4]u8 = undefined;
        var parts = std.mem.splitScalar(u8, text, '.');
        for (&address) |*byte| {
            byte.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
        }
        return address;
    }
    return null;
}

fn gone(address: [4]u8) !void {
    if (answering(address)) return error.StillAnswering;
}

fn answering(address: [4]u8) bool {
    answers(address) catch return false;
    return true;
}

/// The file holds exactly `text` and a newline (synced_write's "written").
fn file_holds(node: *const sdk.Node, path: []const u8, text: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "holds", path, text }) catch return false;
    return status == 0;
}

fn file_present(node: *const sdk.Node, path: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "exists", path }) catch return false;
    return status == 0;
}

fn answers(address: [4]u8) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(address, "ping\n", &reply);
    if (!std.mem.eql(u8, answer, "ping\n")) return error.WrongAnswer;
}

fn oom(s: *System.Scenario) void {
    s.singleton_driver("hog", hog);
}

fn hog(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const status = try node.exec(&.{ "/bin/det-selftest-node", "hog" });
    sdk.always(status == 128 + 9, "the hog is killed", .{ .status = status });
    // Past the nodes' sampler's period (2 s): it judges the kill as it sees it.
    sdk.sleep_ms(3000);
}

fn stress(s: *System.Scenario) void {
    s.parallel_driver("clocks", clocks);
    s.parallel_driver("sleeps", sleeps);
    s.parallel_driver("faults", page_faults);
    s.parallel_driver("forks", forks);
    s.finally("ping_after", ping);
}

const stress_rounds = 200;

/// Reads every clock in a tight loop: the values (virtual time) must be the same on replay.
fn clocks(_: *System.Context) !void {
    var sum: u64 = 0;
    for (0..stress_rounds) |round| {
        for ([_]linux.clockid_t{ .REALTIME, .MONOTONIC, .BOOTTIME, .PROCESS_CPUTIME_ID }) |clock| {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(clock, &now);
            sum +%= @as(u64, @intCast(now.sec)) *% 1_000_000_007 +% @as(u64, @intCast(now.nsec));
        }
        if (round % 50 == 0) sdk.event("clocks", .{ .round = round, .sum = sum });
    }
}

/// Short sleeps and yields: wake-ups land where timers fire.
fn sleeps(_: *System.Context) !void {
    for (0..stress_rounds) |round| {
        const pause = linux.timespec{ .sec = 0, .nsec = @intCast(1 + sdk.random_below(200_000)) };
        _ = linux.nanosleep(&pause, null);
        _ = linux.sched_yield();
        if (round % 50 == 0) {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(.MONOTONIC, &now);
            sdk.event("sleeps", .{ .round = round, .ns = now.nsec });
        }
    }
}

/// Maps, touches and unmaps memory: page faults, zeroing, reclaim.
fn page_faults(_: *System.Context) !void {
    const size = 4 << 20;
    var checksum: u64 = 0;
    for (0..stress_rounds / 10) |round| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const address = linux.mmap(null, size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < size) : (offset += 4096) memory[offset] = @truncate(offset >> 12);
        checksum +%= memory[sdk.random_below(size / 4096) * 4096];
        _ = linux.munmap(memory, size);
        sdk.event("faults", .{ .round = round, .checksum = checksum });
    }
}

/// Forks children that exit with a status the parent checks: scheduling across processes.
fn forks(_: *System.Context) !void {
    for (0..stress_rounds / 10) |round| {
        const pid = linux.fork();
        if (pid == 0) linux.exit_group(@intCast(round % 7));
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        const code = (@as(u32, @bitCast(status)) >> 8) & 0xff;
        sdk.always(code == round % 7, "children exit with their status", .{ .round = round });
    }
}

/// One attempt at the maze per timeline (profile "maze", or "maze-zig"), inside the maze node:
/// by chance 1 in 10000 timelines solves it.
fn maze(s: *System.Scenario) void {
    s.singleton_driver("attempt", maze_attempt);
}

fn maze_attempt(context: *System.Context) !void {
    if (context.nodes.maze) |node| _ = try node.exec(&.{ "/bin/det-maze", "solve" });
    if (context.nodes.zigmaze) |node| _ = try node.exec(&.{ "/bin/det-maze-zig", "solve" });
    if (context.nodes.summaze) |node| _ = try node.exec(&.{ "/bin/det-maze-sum", "solve" });
}

fn ping(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(context.nodes.echo.?.address, "ping\n", &reply);
    sdk.always(std.mem.eql(u8, answer, "ping\n"), "the echo node echoes", .{});
}

/// What the guest kernel's random generator gives after the snapshot: different in every
/// branch (the composer reseeds it from a platform decision), the same when a branch replays.
fn entropy(_: *System.Context) !void {
    var bytes: [8]u8 = undefined;
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoUrandom;
    defer _ = linux.close(@intCast(fd));
    if (linux.read(@intCast(fd), &bytes, bytes.len) != bytes.len) return error.ShortRead;
    sdk.event("kernel_entropy", .{ .value = std.mem.readInt(u64, &bytes, .little) });
    // An RNG passed to code that takes one: every draw a platform decision.
    var deck = [_]u16{ 1, 2, 3, 4, 5 };
    sdk.rng().shuffle(u16, &deck);
    sdk.event("shuffled", .{ .deck = &deck });
}

/// The echo node exits as told (known in the known-exit profile), starts again, and exits with
/// what nothing declares: that exit fails, though the log still holds the known text.
fn node_exit_again(s: *System.Scenario) void {
    s.singleton_driver("exit_twice", exit_twice);
}

fn exit_twice(context: *System.Context) !void {
    try tell_die(context);
    const echo = &context.nodes.echo.?;
    try echo.start();
    var reply: [16]u8 = undefined;
    for (0..100) |_| {
        if (request(echo.address, "ping\n", &reply)) |_| break else |_| {}
        const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    _ = request(echo.address, "leave\n", &reply) catch {}; // It exits instead.
    const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Let the runtime see the exit.
}

fn tell_die(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "die\n", &reply) catch {}; // It exits instead.
    const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Let the runtime see the exit.
}

fn request(address: [4]u8, message: []const u8, reply: []u8) ![]const u8 {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    // An answer within a second (virtual time), or none: a paused node must not answer later.
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    const option = std.mem.asBytes(&timeout);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, option.ptr, option.len);
    // Connecting too (a dropped SYN is retried past a short partition otherwise).
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, option.ptr, option.len);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Connect;
    }
    _ = linux.write(fd, message.ptr, message.len);
    const size = linux.read(fd, reply.ptr, reply.len);
    if (linux.errno(size) != .SUCCESS) return error.Read;
    return reply[0..size];
}

/// A stop of a node whose main process exited must signal no other process (e2e stale-pid):
/// once a node's process is gone, its PID comes round again, and a graceful stop signalled
/// whatever process had it (Valkey's run 1554: a `migrate` driver SIGTERMed). The driver has the
/// echo node restarted (its first PID is under 300, below where the kernel's PIDs come round),
/// kills its process itself, forks until the kernel hands out that PID again (the guest's kernel
/// has no ns_last_pid), asks for a stop of the node, and looks whether its child lives.
fn quorum_scenario(s: *System.Scenario) void {
    s.quorum = &.{ "echo", "witness", "third" };
    s.singleton_driver("majority", majority_driver);
}

/// The same without the cap: faults may take a majority away (the check's other half).
fn quorum_free_scenario(s: *System.Scenario) void {
    s.singleton_driver("majority", majority_driver);
}

/// Every 250 ms for a minute: a majority of the three answers the runner within a second.
fn majority_driver(context: *System.Context) !void {
    const all = [_]?sdk.Node{ context.nodes.echo, context.nodes.witness, context.nodes.third };
    for (0..240) |_| {
        var up: u32 = 0;
        for (all) |maybe| {
            const node = maybe orelse return error.NoQuorumNode;
            up += @intFromBool(answering(node.address_now()));
        }
        sdk.always(up >= 2, "a majority of the quorum answers the runner", .{ .answering = up });
        sdk.sleep_ms(250);
    }
}

fn knobs_scenario(s: *System.Scenario) void {
    s.singleton_driver("knobs", knobs_driver);
}

/// A node's environment entry `name` as its process has it (/proc/<pid>/environ), "" if absent.
fn node_environment(arena: std.mem.Allocator, node: []const u8, name: []const u8) ![]const u8 {
    var path_buffer: [64]u8 = undefined;
    const pid_text = try sdk.file_read(arena, try std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/pid", .{node}, 0));
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, pid_text, " \n"), 10);
    const environ = try sdk.file_read(arena, try std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0));
    var found: []const u8 = "";
    var count: u32 = 0;
    var entries = std.mem.tokenizeScalar(u8, environ, 0);
    while (entries.next()) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
            found = entry[name.len + 1 ..];
            count += 1;
        }
    }
    if (count > 1) return error.Duplicated;
    return found;
}

/// Each node runs with one of its start knob's choices, the node's own entry of that name gone;
/// the run's knob is the same in both, and restarts draw the start knob again.
fn knobs_driver(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const echo = context.nodes.echo orelse return error.NoEchoNode;
    const shared = try node_environment(arena, "echo", "DET_SHARED");
    const shared_witness = try node_environment(arena, "witness", "DET_SHARED");
    const other = try node_environment(arena, "echo", "DET_OTHER");
    sdk.always(shared.len > 0 and std.mem.eql(u8, shared, shared_witness) and
        std.mem.eql(u8, other, if (std.mem.eql(u8, shared, "x")) "1" else "2"), "a run's knob is the same choice in every node", .{
        .echo = shared,
        .witness = shared_witness,
        .other = other,
    });
    var seen: [3]bool = @splat(false);
    for (0..6) |_| {
        const mode = try node_environment(arena, "echo", "DET_KNOB");
        const index: ?usize = if (mode.len == 1 and mode[0] >= 'a' and mode[0] <= 'c') mode[0] - 'a' else null;
        sdk.always(index != null, "a start's knob is one of its choices", .{ .value = mode });
        if (index) |i| seen[i] = true;
        try echo.kill();
        try echo.start();
        sdk.retry(100, 100, answers, .{echo.address}) catch return error.NeverAnswered;
        const after = try node_environment(arena, "echo", "DET_SHARED");
        sdk.always(std.mem.eql(u8, after, shared), "a run's knob is kept across restarts", .{ .before = shared, .after = after });
    }
    const distinct = @as(u32, @intFromBool(seen[0])) + @intFromBool(seen[1]) + @intFromBool(seen[2]);
    sdk.sometimes(distinct > 1, "restarts drew a start's knob anew", .{ .distinct = distinct });
}

fn upgrade_scenario(s: *System.Scenario) void {
    s.singleton_driver("upgrade", upgrade_driver);
}

/// The echo node upgraded to its next release and back (Node.upgrade): each time the other
/// program runs in its root, answering, and what it wrote in /data before is there.
fn upgrade_driver(context: *System.Context) !void {
    const echo = context.nodes.echo orelse return error.NoEchoNode;
    if (try echo.exec(&.{ "/bin/det-selftest-node", "write", "/data/kept" }) != 0) return error.NotWritten;
    try echo.upgrade(.next);
    sdk.retry(100, 100, answers, .{echo.address}) catch return error.NextNeverAnswered;
    const next_holds = try echo.exec(&.{ "/bin/det-selftest-node-next", "holds", "/data/kept", "written" });
    sdk.always(next_holds == 0, "an upgraded node runs its next release, its data kept", .{ .status = next_holds });
    const base_there = echo.exec(&.{ "/bin/det-selftest-node", "exists", "/data/kept" }) catch 255;
    sdk.always(base_there != 0, "an upgraded node's own release is not in its root", .{ .status = base_there });
    try echo.upgrade(.base);
    sdk.retry(100, 100, answers, .{echo.address}) catch return error.BaseNeverAnswered;
    const base_holds = try echo.exec(&.{ "/bin/det-selftest-node", "holds", "/data/kept", "written" });
    sdk.always(base_holds == 0, "a downgraded node runs its own release, its data kept", .{ .status = base_holds });
    const spare = context.nodes.witness orelse return error.NoWitness;
    try spare.upgrade(.next);
    try spare.start();
    sdk.retry(100, 100, answers, .{spare.address}) catch return error.SpareNeverAnswered;
    const spare_next = spare.exec(&.{ "/bin/det-selftest-node-next", "exists", "/bin" }) catch 255;
    sdk.always(spare_next == 0, "a spare upgraded before its first start runs its next release", .{ .status = spare_next });
}

fn stale_pid_scenario(s: *System.Scenario) void {
    s.singleton_driver("stale_pid", stale_pid);
}

fn pidfile_read(arena: std.mem.Allocator) ?linux.pid_t {
    const text = sdk.file_read(arena, "/run/det/nodes/echo/pid") catch return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn stale_pid(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const first = pidfile_read(arena) orelse return error.NoPidfile;
    // The guest has started few processes (PIDs in the tens): past 400 first, so the restarted
    // node's PID is one the kernel comes back to after it wraps (at 300).
    while (true) {
        const forked = linux.fork();
        if (linux.errno(forked) != .SUCCESS) return error.ForkFailed;
        if (forked == 0) linux.exit_group(0);
        var ignored: i32 = 0;
        _ = linux.waitpid(@intCast(forked), &ignored, 0);
        if (forked >= 400) break;
    }
    sdk.fault(.{ .kind = "restart", .node = "echo", .duration_ms = 100 });
    const pid = for (0..200) |_| {
        sdk.sleep_ms(100);
        const now = pidfile_read(arena) orelse continue;
        if (now != first) break now;
    } else return error.NotRestarted;
    sdk.event("stale_pid_node", .{ .first = first, .restarted = pid });
    if (pid < 300) return error.LowPid; // Never handed out again.
    _ = linux.kill(pid, .KILL);
    for (0..100) |_| {
        if (linux.errno(linux.kill(pid, @fromBackingInt(0))) == .SRCH) break;
        sdk.sleep_ms(50);
    } else return error.NodeLived;
    // Fork until the kernel hands out that PID again (it allocates them in turn, wrapping at
    // pid_max): the one child that gets it stays, the others exit at once.
    const pid_max_text = sdk.file_read(arena, "/proc/sys/kernel/pid_max") catch "32768";
    const pid_max = std.fmt.parseInt(u32, std.mem.trim(u8, pid_max_text, " \n"), 10) catch 32768;
    const child: linux.pid_t = for (0..2 * @as(usize, pid_max)) |_| {
        const forked = linux.fork();
        if (linux.errno(forked) != .SUCCESS) return error.ForkFailed;
        if (forked == 0) {
            if (linux.getpid() == pid) while (true) sdk.sleep_ms(1000); // The child at that PID lives.
            linux.exit_group(0);
        }
        const forked_pid: linux.pid_t = @intCast(forked);
        if (forked_pid == pid) break forked_pid;
        var ignored: i32 = 0;
        _ = linux.waitpid(forked_pid, &ignored, 0);
    } else {
        sdk.event("stale_pid", .{ .node_pid = pid, .child = null });
        return; // Another process took it first: nothing to judge.
    };
    defer {
        _ = linux.kill(child, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(child, &status, 0);
    }
    sdk.event("stale_pid", .{ .node_pid = pid, .child = child });
    sdk.reachable("a child holds the PID of the echo node's exited process", .{});
    sdk.fault(.{ .kind = "stop", .node = "echo", .duration_ms = 1000 });
    sdk.sleep_ms(3000);
    var status: i32 = 0;
    const exited = linux.waitpid(child, &status, linux.W.NOHANG);
    sdk.always(exited == 0, "a stop of a node signals none of another's processes", .{ .child = child, .status = status });
}

/// The echo node's limit in profile `climb`, and the most one driver start leaks: a timeline's
/// share stays under the limit; the tree's returns to the leakiest moments add up past it.
/// A timeline makes up to 63 driver starts (composer.zig's starts_draw): at most 126 MiB of its
/// own. With 6 MiB a start, one of 58 starts reached the limit alone (174 MiB expected), the
/// first kill of both arms in three seeds of four, and the kills after it were the returns
/// near that failure in either arm: the check compared nothing of the objective (2026-11-17).
const climb_limit_mib = 160;
const climb_step_mib_max = 2;
comptime {
    std.debug.assert(63 * climb_step_mib_max < climb_limit_mib);
}

/// A leak that grows down the tree (e2e memory-climb, profile `climb`): each driver start has
/// the echo node's server keep a drawn 0 to climb_step_mib_max MiB. A timeline alone stays under
/// the node's limit; children of the leakiest moments inherit the leak and add to it, so a tree
/// that climbs the nodes' memory-growth objective reaches the OOM killer ("the kernel kills no
/// process for lack of memory" fails) and one that does not, seldom.
fn leak_climb_scenario(s: *System.Scenario) void {
    s.faults = false;
    s.parallel_driver("grow", leak_climb_grow);
}

fn leak_climb_grow(context: *System.Context) !void {
    var line: [32]u8 = undefined;
    const ask = std.fmt.bufPrint(&line, "leak {d}\n", .{sdk.random_below(climb_step_mib_max + 1)}) catch unreachable;
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, ask, &reply) catch return;
    sdk.sleep_ms(1000);
}

/// A slow leak in the echo node (e2e memory-growth): the node's process allocates 400 MiB over
/// 20 s and keeps it; the platform's objective, its anonymous memory above its least, says so.
fn leak_scenario(s: *System.Scenario) void {
    s.singleton_driver("leak", leak_driver);
}

fn leak_driver(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const status = try node.exec(&.{ "/bin/det-selftest-node", "leak" });
    sdk.always(status == 0, "the leak ran to its end", .{ .status = status });
}
