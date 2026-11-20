// SPDX-License-Identifier: MIT
//! det-faults: the in-guest fault injector. The composer starts it for the driver phase of a
//! timeline and stops it (SIGTERM) before eventually/finally commands; on stop it undoes what it
//! did. Every choice (when, which fault, how long) is a randomness pull from the platform, so a
//! strategy steers faults like any other decision and a tape replays them.
//!
//! Usage: det-faults --scenario <name> [--only <kind>,<kind>...]
//!        det-faults --only <kind>,<kind>...   (the system's defaults for the scenario's)
//!        det-faults inject '<json>'   (a fault now, from a scenario: see below)
//!
//! `--only`: of the faults the system allows, those kinds alone: a CI shard's timing faults
//! (thread_pause, process_pause, interleave), which change when threads run and nothing else,
//! while its tests run (determinismo-ci).
//!
//! The faults come from /det/system.json: what each node allows (pause, isolate, partition,
//! restart) and whether the scenario wants clock skips.
//!
//! Quiet periods (Antithesis's pausing faults): `det-stop-faults <seconds>`, from any node or
//! command, writes to the control FIFO. The fault under way ends there (the network heals, a
//! node comes back), and no new faults start until the longest requested period is over,
//! except clock skips, which go on.
//!
//! Network faults overlap (see "Network faults" below); node faults happen one at a time on a
//! node, several nodes at once (see "Node faults").
//!
//! Branch points: the platform tells det-agent (its `det:branch` action, agent.zig), which tells
//! this, where a timeline begins at a moment of another (the tree's returns, just after a new
//! behavior), and which node that behavior came from. A quiet stretch of the pacing ends there
//! and a fault is drawn at once, among those involving that node when any does: each branch is
//! perturbed right after the moment it was chosen for, where it happened, never seconds later
//! somewhere else. Quiet periods a node or command asked for stay.
//!
//! Faults from the scenario: `det-faults inject '<json>'` (any language, any node or command)
//! or the SDK's `fault`, while the injector runs, apply that fault now, logged and undone like a
//! drawn one: {"kind": "pause", "node": "db", "duration_ms": 2000}, {"kind":
//! "partition_groups", "groups": [["runner", "a"], ["b", "c"]], "disruption": "stopped",
//! "direction": "both"}, {"kind": "degrade", "node": "a", "peer": "b", "flavor": "delay_loss"},
//! {"kind": "clog", "node": "a", "direction": "inbound"}, {"kind": "throttle", "node": "a",
//! "cpu_percent": 10}, {"kind": "clock_skip", "skip_ms": 500, "forward": true} (permanent),
//! {"kind": "clock_skew", "node": "a", "skip_ms": 300, "forward": false} (with "strobe_ms": 50,
//! coming and going), {"kind": "restore"}, {"kind": "disk", "node": "db", "failure": "lost_writes"} (failures:
//! errors, write_errors, lost_writes, corrupt_reads, slow with "delay_ms"); {"kind": "outage",
//! "nodes": ["a", "b"]} (every node that allows crashes when none are named); restart, crash,
//! durable_crash, wipe, stop, process_pause, thread_pause, interleave (with "one_in"),
//! process_kill, isolate and partition (with "peer") too.
//!
//! Interleavings (interleave): while the fault lasts, the guest kernel's scheduler leaves one in
//! a few of its choices among the node's threads to the guest module, which draws them: a woken
//! thread runs before its waker goes on (or not), a tick preempts the running thread, a random
//! runnable thread runs next (guest/kernel/patches/0006). The interleavings inside a process
//! that thread pauses reach only around one thread.
//!
//! Durability points (sync_stall, durable_crash): while the fault lasts, the guest module makes
//! each of the node's fsyncs and sync writes a decision, and one in a few is picked. A stall
//! holds the syncing thread there while the node's other threads run (the interleavings around
//! persisting). A crash parks it there, before its data reaches the disk or just after, and
//! asks for the node's crash: a power loss exactly where a system persists what it acts on (a
//! vote granted, a write acknowledged). A thread here waits for those asks and crashes the node;
//! it starts again at the fault's end.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const schema = sdk.schema;
const nodes = @import("nodes.zig");
const regex = @import("regex.zig");

/// A node's own fault kinds (24 today, the five pod kinds and its clog among them) and its custom
/// programs: what a node may list of its own.
const node_faults_max = 32;
/// The table holds every fault a system of schema.nodes_max nodes lists (faults_collect): each
/// node's own, three for its link with the runner and with each later node (a partition, a
/// degradation each way), the groups (their partition, swizzle, outages), the clock skip and the
/// restore. It was 256, which ten nodes fill: a system past that had its later nodes' faults,
/// the groups and the restore dropped without a word (an imported project of 20 services: only
/// its first six were ever stopped). A node listing more custom programs than node_faults_max
/// leaves room for is said and fails `listed_property`.
const faults_max = schema.nodes_max * node_faults_max +
    3 * (schema.nodes_max + schema.nodes_max * (schema.nodes_max - 1) / 2) + 16;
const listed_property = "the fault injector lists every fault the system allows";
/// The faults faults_collect had no room for, of its last call.
var faults_dropped: u32 = 0;
const injections_max = 10_000;
const delay_ns_min = 10 * std.time.ns_per_ms;
const delay_ns_max = 300 * std.time.ns_per_ms;
/// Most faults are short, interleaving with the system's steps; one in `long_one_in` may last
/// up to `duration_ns_max` (Antithesis's example partition: 10 s), outlasting election
/// timeouts, retries and snapshot intervals, so nodes come back far behind or with messages
/// queued.
const duration_short_ns_max = 500 * std.time.ns_per_ms;
const duration_ns_max = 10 * std.time.ns_per_s;
const long_one_in = 4;
const clock_skip_ns_max = 60 * std.time.ns_per_s;
/// A clock skew's size, log-uniform from a millisecond (within a hybrid logical clock's maximum
/// offset) up to the node's largest (Faults.clock_skew_ms_max; seconds: past leases, timeouts).
const clock_skew_ns_min = std.time.ns_per_ms;
const clock_skew_ns_max = 10 * std.time.ns_per_s;

const Kind = enum {
    pause,
    isolate,
    partition,
    degrade,
    restart,
    /// A power loss: the node's disk keeps what was synced, then it starts again.
    crash,
    /// A power loss of several nodes at the same moment (a rack's, a datacenter's; Jepsen's
    /// kill of a majority or of all): each keeps what it synced, and all start again at its end.
    /// Systems that acknowledge before a sync, counting on their replicas (Galera's
    /// recommended settings, Kafka's), lose acknowledged writes only so. For nodes that allow
    /// restarts but not power losses, a kill of several at once instead (`power` false): Jepsen
    /// found YugabyteDB 1.3.1's #2125 killing every master together.
    outage,
    /// A power loss at a durability point: its fsyncs and sync writes are decisions, and the
    /// one picked crashes the node there (before its data is on disk, or just after).
    durable_crash,
    /// Its fsyncs and sync writes are decisions, and the ones picked are held for a while.
    sync_stall,
    /// It starts again fresh from its image, everything it wrote gone.
    wipe,
    /// A graceful stop (SIGTERM, then a kill after a grace period), then it starts again.
    stop,
    /// Its disk fails for a while (nodes.DiskFailure).
    disk,
    throttle,
    process_pause,
    /// One thread of one of its processes stopped (ptrace), the others running: interleavings
    /// within a process, without instrumentation (Antithesis's thread pausing).
    thread_pause,
    /// Its threads' scheduling drawn for a while (one choice in `one_in`): interleavings within
    /// its processes, with no instrumentation (POS-style random priorities at each point).
    interleave,
    process_kill,
    /// A signal one of its processes catches (Faults.signals): interrupted system calls.
    signal,
    /// One of its system calls failing, one call in a few, for a while (Faults.syscall_errors).
    syscall_error,
    /// Its reads or writes of its disk's files failing, one in a few, for a while
    /// (Faults.file_errors).
    file_error,
    /// One pod of a Kubernetes node (Faults.pods) frozen, killed, cut off, or its network
    /// degraded, in its own network namespace.
    pod_pause,
    pod_kill,
    pod_isolate,
    pod_degrade,
    /// Two pods of a Kubernetes node cut off from each other (each drops what it sends to the
    /// other), the rest of their network as it was.
    pod_partition,
    /// The runner and the nodes split into groups that cannot talk across (Antithesis's
    /// partitions), with one disruption form.
    partition_groups,
    /// One node's inbound, outbound or both directions disrupted on all its links.
    clog,
    /// Several nodes clogged one after another, a drawn gap apart, then unclogged in a random
    /// order (FoundationDB's swizzle clogging): connectivity partial and shifting all along,
    /// what recovery protocols handle worst. Its clogs are the network's like any other.
    swizzle,
    /// One of the node's own fault programs (Faults.custom), run to completion in the node.
    custom,
    /// Every network fault under way ends (Antithesis's restore); skipped when none is.
    restore,
    clock_skip,
    /// One node's realtime clock skewed, forward or back, for a while (Jepsen's clock bumps;
    /// nodes.clock_offset): the other nodes' clocks as they were.
    clock_skew,
};
/// How a disrupted link behaves (Antithesis's forms): packets dropped, delayed, or held for
/// the whole fault and then delivered.
const Disruption = enum { stopped, slowed, jammed };
const Direction = enum { inbound, outbound, both };
const slowed_delay_ns_min = 50 * std.time.ns_per_ms;
const slowed_delay_ns_max = 500 * std.time.ns_per_ms;
/// Endpoints of a partition: the runner (0), then the nodes in order.
const endpoints_max = schema.nodes_max + 1;
/// A group outside every partition: the endpoint does not allow partitions.
const group_none = 255;
const throttle_percent_min = 5;
/// The longest a sync_stall may hold one sync (each stall draws up to its fault's maximum).
const stall_ms_max = 1000;
const throttle_percent_max = 50;
const disk_delay_ms_max = 200;
const disk_sector_size = 512;
const processes_max = 1024;
const threads_max = 1024;
/// What a degraded link does: one flavor per fault.
const Degradation = enum { delay_loss, duplicate, corrupt, reorder, congestion, burst_loss };
const degrade_delay_ns_max = 200 * std.time.ns_per_ms;
const degrade_loss_percent_max = 30;
/// The network's normal variation, on every link that allows degradation, for the whole run
/// (Antithesis's baseline latency): a small delay with jitter and a rare drop.
const baseline_delay_ns_min = 100 * std.time.ns_per_us;
const baseline_delay_ns_max = 2 * std.time.ns_per_ms;
const baseline_loss_ppm_max = 1000;
const disk_baseline_ms_max = 2;
/// Drawn once per timeline; links return to it when a fault on them ends.
var baseline: ?nodes.Netem = null;

const Fault = struct {
    kind: Kind,
    node: []const u8 = "",
    /// The other end of a partitioned link (a node or the runner).
    peer: []const u8 = "",
    /// For partition_groups: the endpoints that may be cut off (runner first).
    endpoints: [endpoints_max]bool = @splat(false),
    /// For custom: the program in the node.
    program: []const u8 = "",
    /// For outage: power losses (false: kills, the nodes allowing restarts).
    power: bool = true,
    /// For clock_skew: the node's largest skew.
    skew_ns_max: u64 = clock_skew_ns_max,
    /// For disk: whether its failing disk may drop acknowledged writes.
    lost_writes: bool = true,
};

/// Set by the SIGTERM handler; checked between steps so a stop never leaves a fault applied.
var stopping = std.atomic.Value(bool).init(false);

fn on_terminate(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

/// A built-in property: the main loop is never busy (not waiting for its next fault or a
/// fault's end) for long. It once waited forever on a lock (a deadlock with the durability
/// listener), and the only signs were nodes left down and isolations never healed (srv3,
/// 2026-10-28, Kafka run 24).
const stall_property = "the fault injector never stalls";
const stall_ns = 30 * std.time.ns_per_s;
const watchdog_interval_ns = 5 * std.time.ns_per_s;
/// When the main loop's work in hand began (CLOCK_MONOTONIC), 0 while it waits.
var busy_since_ns = std.atomic.Value(u64).init(0);
var watchdog_done = std.atomic.Value(bool).init(false);
var stall_reported = std.atomic.Value(bool).init(false);

fn busy_begin() void {
    if (busy_since_ns.load(.monotonic) == 0) busy_since_ns.store(monotonic_ns(), .monotonic);
}

/// What the main loop is doing ("apply crash kafka-1", "end restart kafka-3", "heal"), for the
/// watchdog to say with a stall: run 68's (srv3, a 34 s stall in timeline 98) said only how long.
/// A diagnostic: the watchdog's copy may catch it mid-write.
var doing_buffer: [96]u8 = undefined;
var doing_size = std.atomic.Value(u8).init(0);

fn doing_set(comptime phase: []const u8, kind: ?Kind, node: []const u8) void {
    doing_size.store(0, .release);
    const text = std.fmt.bufPrint(&doing_buffer, phase ++ "{s}{s}{s}{s}", .{
        if (kind != null) " " else "",
        if (kind) |known| @tagName(known) else "",
        if (node.len > 0) " " else "",
        node,
    }) catch doing_buffer[0..0];
    doing_size.store(@intCast(text.len), .release);
}

fn busy_end() void {
    busy_since_ns.store(0, .monotonic);
}

/// Watches the main loop from a thread of its own: a stall fails `stall_property` once, with
/// how long the loop had been busy.
fn watchdog() void {
    while (!watchdog_done.load(.acquire)) {
        nodes.sleep_ns(watchdog_interval_ns);
        const since = busy_since_ns.load(.monotonic);
        if (since == 0 or stall_reported.load(.monotonic)) continue;
        const busy = monotonic_ns() -| since;
        if (busy < stall_ns) continue;
        stall_reported.store(true, .monotonic);
        var doing: [96]u8 = undefined;
        const size = doing_size.load(.acquire);
        @memcpy(doing[0..size], doing_buffer[0..size]);
        sdk.assert_computed(.always, false, stall_property, .{
            .busy_ms = busy / std.time.ns_per_ms,
            .doing = doing[0..size],
        });
    }
}

fn watchdog_start() void {
    const thread = std.Thread.spawn(.{}, watchdog, .{}) catch return;
    thread.detach();
}

/// The loop is over (its faults undone): a timeline without a stall passes the property.
fn watchdog_finish() void {
    watchdog_done.store(true, .release);
    if (!stall_reported.load(.monotonic)) sdk.assert_computed(.always, true, stall_property, .{});
}

/// The control FIFO, under /opt/determinismo, which every node sees (read-only, which FIFOs
/// ignore). Each request is a u64, little endian: the quiet period in nanoseconds.
pub const control_path = "/opt/determinismo/faults-control";
var control: linux.fd_t = -1;
/// The system whose network faults sleeps expire (set once faults start).
var system_active: ?*const schema.System = null;
/// Until when (CLOCK_MONOTONIC) only clock skips are injected.
var quiet_until_ns: u64 = 0;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "inject")) {
        return inject_request(arguments[2]);
    }
    // `det-faults aim <node>` ("" for none): as the SDKs' fault_aim, for those that run commands.
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "aim")) {
        return control_request(aim_flag, arguments[2][0..@min(arguments[2].len, branch_node_max)]);
    }
    // `det-faults crash-point <asked_ns> <point>`: the node it runs in ($DETERMINISMO_NODE) asks
    // to crash now, at a point of its code (the Java agent's crash points; crash_point_asked).
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "crash-point")) {
        const node = init.environ_map.get("DETERMINISMO_NODE") orelse return error.NoNode;
        try crash_point_open(node, monotonic_ns());
        var body: [request_size_max - 8]u8 = undefined;
        const point = arguments[3][0..@min(arguments[3].len, crash_point_text_max)];
        const text = std.fmt.bufPrint(&body, "{s} {s}\n{s}", .{ arguments[2], node, point }) catch return error.RequestTooLarge;
        return control_request(crash_point_flag, text);
    }
    const asked = try start_parse(arguments);
    const system = try nodes.system_load(arena);
    // With --only and no scenario: the defaults (a Compose system without test templates has none).
    const default_scenario: schema.Scenario = .{ .name = "only", .commands = &.{} };
    const scenario = if (asked.scenario) |name| system.scenario(name) orelse return error.UnknownScenario else &default_scenario;
    var faults: [faults_max]Fault = undefined;
    var count = faults_collect(&system, scenario, &faults);
    if (faults_dropped > 0) {
        std.debug.print("[det-faults] {d} faults past the table's {d} are never injected\n", .{ faults_dropped, faults_max });
    }
    sdk.assert_computed(.always, faults_dropped == 0, listed_property, .{ .listed = count, .dropped = faults_dropped });
    if (asked.only) |kinds| count = faults_keep(&faults, count, kinds);
    if (count == 0) return; // Nothing allowed: nothing to inject.
    const action = linux.Sigaction{
        .handler = .{ .handler = on_terminate },
        .mask = linux.sigemptyset(),
        .flags = 0, // No SA_RESTART: a pending sleep returns early on stop.
    };
    _ = linux.sigaction(.TERM, &action, null);

    control_open();
    system_active = &system;
    arena_active = arena;
    sdk.event("faults_start", .{ .faults = count });
    busy_begin();
    watchdog_start();
    baseline_start(&system);
    disk_baseline_start(&system);
    if (script_faults(arena)) |scripted| return run_script(arena, &system, scripted);
    var mixed = swarm_select(&faults, count);
    faults_active = faults[0..mixed];
    crash_points_publish();
    var names = try fault_names(arena, faults[0..mixed]);
    regime = regime_draw();
    rerandomize_schedule();
    var regime_until_ns = if (regime.gap_mean_ns == 0) std.math.maxInt(u64) else monotonic_ns() + regime.stretch_ns;
    const pacing = scenario.pacing;
    nodes_down_max = scenario.nodes_down_max;
    quorum_configure(&system, scenario);
    // With bursts: when the stretch of faults under way ends (CLOCK_MONOTONIC).
    var active_until_ns: u64 = if (pacing.active_ms_max > 0) monotonic_ns() + stretch_ns("fault.active_ms", pacing.active_ms_max) else std.math.maxInt(u64);
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        if (monotonic_ns() >= regime_until_ns) {
            // The next regime, its fault mix drawn again (the kinds, their weights).
            mixed = swarm_select(&faults, count);
            faults_active = faults[0..mixed];
            crash_points_publish();
            names = try fault_names(arena, faults[0..mixed]);
            regime = regime_draw();
            rerandomize_schedule();
            regime_until_ns = monotonic_ns() + regime.stretch_ns;
        }
        wait_or_poll(regime_wait_ns());
        if (stopping.load(.acquire)) break;
        if (monotonic_ns() >= active_until_ns) {
            // A quiet stretch (healing what is under way), then the next stretch of faults.
            if (pacing.quiet_ms_max > 0) {
                const stretch = stretch_ns("fault.quiet_ms", pacing.quiet_ms_max);
                quiet_request(stretch);
                quiet_pacing = true;
                pacing_quiet_until_ns = monotonic_ns() + stretch;
                const now_ns = monotonic_ns();
                if (quiet_until_ns > now_ns) sleep_ns(quiet_until_ns - now_ns);
                if (stopping.load(.acquire)) break;
            }
            active_until_ns = @max(quiet_until_ns, monotonic_ns()) + stretch_ns("fault.active_ms", pacing.active_ms_max);
        }
        // Labeled decisions: a strategy sees which faults it chooses among, by name.
        const chosen = fault_choose(faults[0..mixed], names);
        var applied = draw(&faults[chosen.index]);
        applied.why = chosen.why;
        if (monotonic_ns() < quiet_until_ns and applied.kind != .clock_skip) continue;
        apply(arena, &system, &applied);
    }
    busy_begin();
    doing_set("heal", null, "");
    node_heal(&system);
    disk_settle(&system);
    network_stop(&system);
    leftovers_check(&system);
    busy_end();
    watchdog_finish();
    _ = linux.unlink(crash_points_path);
    sdk.event("faults_stop", .{ .injections = injections });
}

/// Once faults stop, nothing of them lasts: what the system does after (its recovery, the
/// eventually commands) is its own. Each node's state as the kernel has it (nodes.leftover), and
/// the injector's own: no durability point armed, no link down or degraded beyond the baseline.
fn leftovers_check(system: *const schema.System) void {
    for (system.nodes, 0..) |node, index| {
        const node_left = nodes.leftover(node.name);
        const armed = durable_active[index];
        const left = if (node_left.len > 0) node_left else if (armed) "a durability point armed" else "";
        sdk.assert_computed(.always, left.len == 0, "faults leave nothing behind once they stop", .{
            .node = node.name,
            .left = left,
        });
    }
    var links_down: u32 = 0;
    // The links still down, by name ("runner-raft-1 raft-2-raft-3"), as many as fit.
    var names_buffer: [256]u8 = undefined;
    var names: std.Io.Writer = .fixed(&names_buffer);
    for (network.down, 0..) |row, a| {
        for (row, 0..) |down, b| {
            if (!down) continue;
            links_down += 1;
            names.print("{s}{s}-{s}", .{
                if (links_down == 1) "" else " ", endpoint_name(system, a), endpoint_name(system, b),
            }) catch {};
        }
    }
    sdk.assert_computed(.always, links_down == 0 and network.count == 0, "faults leave nothing behind once they stop", .{
        .node = "",
        .left = if (links_down > 0) "links down" else if (network.count > 0) "network faults under way" else "",
        .links = names.buffered(),
    });
    // Each direction's netem as the kernel has it, against the bookkeeping's: a heal that only
    // the bookkeeping saw left links corrupting, reordering and rate-limited after faults
    // stopped (netem_set's options kept by a change: run 952, a connection stuck on bad
    // checksums). Only a harsher one is left behind: a restarted node's links have none.
    var netems_harsher: u32 = 0;
    var netem_buffer: [256]u8 = undefined;
    var netem_names: std.Io.Writer = .fixed(&netem_buffer);
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b or !faultable(system, a, b)) continue;
        const from = endpoint_name(system, a);
        const to = endpoint_name(system, b);
        if (!degradable(system, from) or !degradable(system, to)) continue;
        // A node gone (stopped, its namespace with it) has no links to read.
        const read = (nodes.link_netem_read(from, to) catch continue) orelse continue;
        if (!read.harsher(network.netem[a][b])) continue;
        netems_harsher += 1;
        netem_names.print("{s}{s}-{s}", .{ if (netems_harsher == 1) "" else " ", from, to }) catch {};
    };
    sdk.assert_computed(.always, netems_harsher == 0, "faults leave nothing behind once they stop", .{
        .node = "",
        .left = if (netems_harsher > 0) "netem harsher than healed" else "",
        .links = netem_names.buffered(),
    });
}

/// A stretch of the pacing, drawn from a tenth of `max_ms` up to it.
fn stretch_ns(comptime name: []const u8, max_ms: u32) u64 {
    const floor_ms = max_ms / 10;
    const drawn_ms = floor_ms + sdk.random_below_named(name, max_ms - floor_ms + 1);
    return drawn_ms * std.time.ns_per_ms;
}

/// The stop: every network fault heals (what jammed links hold is delivered first).
fn network_stop(system: *const schema.System) void {
    network_heal(system);
    if (network.count == 0) return;
    nodes.sleep_ns(release_ns); // A stop ends sleep_ns: this one is plain.
    network_expire(system, monotonic_ns() + release_ns);
}

/// Each fault's name, as a strategy reads it: its kind and whom it hits ("pause raft-2",
/// "partition raft-1 raft-3", "degrade raft-1 runner").
/// Swarm testing (Groce et al., "Swarm Testing", ISSTA 2012; Antithesis's exploration credits it
/// too): this timeline's faults are some of the kinds allowed, each kind in or out by a named
/// decision ("fault.swarm <kind>", for strategies to steer), one at least. A mix without some
/// kinds reaches what the full mix makes improbable (partitions on and on with no restart healing
/// them); a branch from a moment keeps its timeline's mix, subtrees differ. How likely a kind is
/// kept is drawn per timeline too ("fault.swarm_p", one to seven eighths: meta-swarm, Will
/// Wilson's "Swarm Testing" talk, 2026): kept half and half, the number of kinds is binomial,
/// nearly all of them together or one alone almost never. Each kind kept gets a weight
/// ("fault.weight <kind>", 1 to 64, powers of two; docs/ANTITHESIS_EXPLORATION.md, item A):
/// the next fault's kind is drawn by them, then one of that kind's instances, so one timeline is
/// mostly pauses and another mostly partitions, where the instances' count alone (every pair a
/// partition) set every timeline's mix. Not configurable beyond --no-swarm (every kind, each
/// instance alike): strategies steer the decisions. The kinds kept go first in `faults`: how
/// many.
fn swarm_select(faults: *[faults_max]Fault, count: u32) u32 {
    if (count == 0) return 0;
    if (swarm_off()) return count; // explore --no-swarm: every kind, for comparisons.
    var allowed: std.EnumSet(Kind) = .empty;
    for (faults[0..count]) |fault| allowed.insert(fault.kind);
    const eighths = 1 + sdk.random_config("fault.swarm_p", 7);
    var kept: std.EnumSet(Kind) = .empty;
    var kinds = allowed.iterator();
    while (kinds.next()) |kind| {
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "fault.swarm {s}", .{@tagName(kind)}) catch "fault.swarm";
        if (sdk.random_config(label, 8) < eighths) kept.insert(kind);
    }
    if (kept.count() == 0) {
        var pick = sdk.random_below_named("fault.swarm_one", allowed.count());
        var any = allowed.iterator();
        while (any.next()) |kind| {
            if (pick == 0) kept.insert(kind);
            pick -|= 1;
        }
    }
    var weighted = kept.iterator();
    while (weighted.next()) |kind| {
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "fault.weight {s}", .{@tagName(kind)}) catch "fault.weight";
        kind_weights.set(kind, @as(u32, 1) << @intCast(sdk.random_config(label, 7)));
    }
    // Kinds asked for (explore's --fault-weights: those inside a failure's causality jump), in
    // half the timelines kept at their weights ("fault.asked"), so the bug they made comes more
    // often, the other half as drawn for other bugs.
    var asked_buffer: [512]u8 = undefined;
    if (cmdline_word("det.fault_weights=", &asked_buffer)) |asked| {
        if (sdk.random_below_named("fault.asked", 2) == 0) {
            var pairs = std.mem.tokenizeScalar(u8, asked, ',');
            while (pairs.next()) |pair| {
                const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const kind = std.meta.stringToEnum(Kind, pair[0..equals]) orelse continue;
                const weight = std.fmt.parseInt(u32, pair[equals + 1 ..], 10) catch continue;
                if (!allowed.contains(kind)) continue;
                kept.insert(kind);
                kind_weights.set(kind, std.math.clamp(weight, 1, 64));
            }
        }
    }
    kinds_weighted = true;
    var front: u32 = 0;
    for (0..count) |index| {
        if (!kept.contains(faults[index].kind)) continue;
        std.mem.swap(Fault, &faults[front], &faults[index]);
        front += 1;
    }
    var names_buffer: [512]u8 = undefined;
    var names: std.Io.Writer = .fixed(&names_buffer);
    var listed = kept.iterator();
    while (listed.next()) |kind| names.print("{s}{s}:{d}", .{ if (names.end == 0) "" else " ", @tagName(kind), kind_weights.get(kind) }) catch break;
    sdk.event("fault_swarm", .{ .kinds = names.buffered(), .faults = front, .of = count, .kept_eighths = eighths });
    return front;
}

/// Antithesis's `fault_exclusions` (explore's --fault-exclusions: `det.fault_exclusions=` on
/// the guest's command line, hex): a regular expression (regex.zig, Rust's syntax) over node
/// names, and pod names on Kubernetes. A match gets no fault of its own and is in no partition,
/// isolation or outage; faults of the whole machine (clock skips) reach it as any. Read once,
/// at the first question; a pattern the explorer let through that does not compile here
/// excludes nothing, said as an event.
var exclusions: ?regex.Regex = null;
var exclusions_read = false;

fn excluded(name: []const u8) bool {
    if (!exclusions_read) {
        exclusions_read = true;
        exclusions = exclusions_load();
    }
    const pattern = &(exclusions orelse return false);
    return pattern.is_match(name);
}

fn exclusions_load() ?regex.Regex {
    var hex_buffer: [2 * regex.pattern_size_max]u8 = undefined;
    const hex = cmdline_word("det.fault_exclusions=", &hex_buffer) orelse return null;
    var pattern_buffer: [regex.pattern_size_max]u8 = undefined;
    const pattern = std.fmt.hexToBytes(&pattern_buffer, hex) catch {
        sdk.event("fault_exclusions_invalid", .{ .reason = "hex" });
        return null;
    };
    const compiled = regex.Regex.compile(pattern) catch |err| {
        sdk.event("fault_exclusions_invalid", .{ .reason = @errorName(err) });
        return null;
    };
    sdk.event("fault_exclusions", .{ .pattern = pattern });
    return compiled;
}

/// A strategy's own faults (the machine it decided: explore's `det.custom_faults=` on the
/// guest's command line, hex of "node\tcommand\n" each, strategy.zig): custom faults of the
/// nodes named, drawn among theirs. Read once, at the first collection.
const PluginFault = struct { node: []const u8, command: []const u8 };
var plugin_faults_text: [256]u8 = undefined; // strategy.zig's custom_faults_size_max.
var plugin_faults_list: [4]PluginFault = undefined; // Its custom_faults_max.
var plugin_faults_count: usize = 0;
var plugin_faults_read = false;

fn plugin_faults() []const PluginFault {
    if (plugin_faults_read) return plugin_faults_list[0..plugin_faults_count];
    plugin_faults_read = true;
    var hex_buffer: [2 * plugin_faults_text.len]u8 = undefined;
    const hex = cmdline_word("det.custom_faults=", &hex_buffer) orelse return &.{};
    const text = std.fmt.hexToBytes(&plugin_faults_text, hex) catch {
        sdk.event("custom_faults_invalid", .{ .reason = "hex" });
        return &.{};
    };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (plugin_faults_count == plugin_faults_list.len) break;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        plugin_faults_list[plugin_faults_count] = .{ .node = line[0..tab], .command = line[tab + 1 ..] };
        plugin_faults_count += 1;
    }
    sdk.event("custom_faults", .{ .count = plugin_faults_count });
    return plugin_faults_list[0..plugin_faults_count];
}

/// The value of `key<value>` among the kernel's command line's words, copied into `buffer`.
fn cmdline_word(comptime key: []const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var text: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &text, text.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var words = std.mem.tokenizeAny(u8, text[0..size], " \n");
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, key)) continue;
        const value = word[key.len..];
        if (value.len > buffer.len) return null;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    return null;
}

/// This timeline's weight for each kind kept (swarm_select); unused with --no-swarm.
var kind_weights: std.EnumArray(Kind, u32) = .initFill(0);
var kinds_weighted = false;

/// The next drawn fault: its kind by the timeline's weights ("fault.kind"), then one of that
/// kind's instances ("fault", their names: what strategies steer). With --no-swarm, every
/// instance alike, as before weights.
fn fault_weighted(faults: []const Fault, names: []const []const u8) usize {
    if (!kinds_weighted) return sdk.decide("fault", names);
    var present: std.EnumSet(Kind) = .empty;
    for (faults) |fault| present.insert(fault.kind);
    var total: u64 = 0;
    var kinds = present.iterator();
    while (kinds.next()) |kind| total += @max(kind_weights.get(kind), 1);
    var pick = sdk.random_below_named("fault.kind", total);
    var chosen: Kind = faults[0].kind;
    kinds = present.iterator();
    while (kinds.next()) |kind| {
        const weight = @max(kind_weights.get(kind), 1);
        if (pick < weight) {
            chosen = kind;
            break;
        }
        pick -= weight;
    }
    var subset_names: [faults_max][]const u8 = undefined;
    var subset_indices: [faults_max]usize = undefined;
    var count: usize = 0;
    for (faults, 0..) |fault, index| {
        if (fault.kind != chosen) continue;
        subset_names[count] = names[index];
        subset_indices[count] = index;
        count += 1;
    }
    assert(count > 0);
    return subset_indices[sdk.decide("fault", subset_names[0..count])];
}

/// `det.swarm=0` among the kernel's command line's words (explore's --no-swarm).
fn swarm_off() bool {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    var words = std.mem.tokenizeAny(u8, buffer[0..size], " \n");
    while (words.next()) |word| if (std.mem.eql(u8, word, "det.swarm=0")) return true;
    return false;
}

test swarm_select {
    // Outside the guest the decisions are the local random source: whatever is kept goes first,
    // one kind at least, and nothing is lost.
    var faults: [faults_max]Fault = undefined;
    const kinds = [_]Kind{ .pause, .restart, .pause, .isolate, .restart };
    for (kinds, 0..) |kind, index| faults[index] = .{ .kind = kind, .node = "n" };
    const kept = swarm_select(&faults, kinds.len);
    try std.testing.expect(kept >= 1 and kept <= kinds.len);
    for (faults[0..kept]) |kept_fault| for (faults[kept..kinds.len]) |left| {
        try std.testing.expect(kept_fault.kind != left.kind);
    };
}

fn fault_names(arena: std.mem.Allocator, faults: []const Fault) ![]const []const u8 {
    const names = try arena.alloc([]const u8, faults.len);
    for (faults, names) |fault, *name| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, @tagName(fault.kind));
        if (fault.kind == .outage and !fault.power) try text.appendSlice(arena, " kill");
        for ([_][]const u8{ fault.node, fault.peer, fault.program }) |part| {
            if (part.len == 0) continue;
            try text.append(arena, ' ');
            try text.appendSlice(arena, part);
        }
        name.* = text.items;
    }
    return names;
}

/// One fault as applied: everything needed to apply it again. A script's fault entries are
/// these, with `at_ns` their offset from the start of the fault phase (0 in events).
const Applied = struct {
    at_ns: u64 = 0,
    kind: Kind,
    node: []const u8 = "",
    peer: []const u8 = "",
    duration_ns: u64,
    cpu_percent: u8 = 0,
    process_index: u32 = 0,
    thread_index: u32 = 0,
    flavor: ?Degradation = null,
    netem: ?nodes.Netem = null,
    forward: bool = false,
    skip_ns: u64 = 0,
    /// A clock skip that is never undone: skips then stack.
    permanent: bool = false,
    /// For clock_skew: 0 holds the skew for the fault's duration; otherwise it comes and goes
    /// every this many nanoseconds (Jepsen's strobe: a clock flipping as a confused NTP might).
    strobe_ns: u64 = 0,
    disruption: ?Disruption = null,
    direction: ?Direction = null,
    /// For custom: the program in the node, and its exit status (in the event).
    program: []const u8 = "",
    /// For partition_groups: each endpoint's group (runner first), group_none for those left out.
    /// (u16, not u8: JSON writes byte arrays as strings.)
    groups: [endpoints_max]u16 = @splat(group_none),
    /// For outage: the nodes that lose power, or are killed (`power` false) (runner first,
    /// never it).
    outage: [endpoints_max]bool = @splat(false),
    power: bool = true,
    /// For swizzle: each endpoint's place in the clogging order and in the unclogging one
    /// (from 1; 0: left out), and the gap between two steps.
    swizzle_order: [endpoints_max]u16 = @splat(0),
    swizzle_unclog: [endpoints_max]u16 = @splat(0),
    gap_ns: u64 = 0,
    /// For signal: the signal sent. For syscall_error: the system call failed, and its error.
    signal: []const u8 = "",
    syscall: []const u8 = "",
    errno: []const u8 = "",
    /// For file_error: the calls failed (with `errno`, one in `one_in`).
    file_calls: ?FileCalls = null,
    /// For process_pause, thread_pause and process_kill: the process's command name, as it was
    /// (which of a node's processes is the question: a master or a backend).
    process: []const u8 = "",
    /// Asked for by the scenario (`det-faults inject`, the SDK's `fault`), not drawn.
    injected: bool = false,
    /// Why a drawn fault was this one (in its event, for the UI and queries).
    why: Why = .drawn,
    disk: ?nodes.DiskFault = null,
    /// For durable_crash and sync_stall: one durability point in this many is picked; a crash
    /// there is just after the sync or before it; a stall lasts up to stall_ms_max. For
    /// interleave: one scheduling choice in this many is drawn.
    one_in: u32 = 0,
    after_sync: bool = false,
    stall_ms_min: u32 = 1,
    stall_ms_max: u32 = 0,
    /// For the pod faults: the pod's name (process_index picks it among the node's pods), and
    /// for pod_partition the other one's (thread_index picks it).
    pod: []const u8 = "",
    peer_pod: []const u8 = "",
    /// For a power loss (crash, durable_crash, an outage with power): unsynced pages that reached
    /// the disk anyway, a flusher's work before the power went (nodes.Partial): 0 none, else the
    /// seed of the subset; with `partial_commit`, the journal committed after them.
    partial_seed: u64 = 0,
    partial_commit: bool = false,

    fn partial(applied: *const Applied) ?nodes.Partial {
        if (applied.partial_seed == 0) return null;
        return .{ .seed = applied.partial_seed, .commit = applied.partial_commit };
    }
};

/// A power loss's partial persistence for a node, unless the node turned it off (an injected
/// one asked for applies all the same: the scenario's choice).
fn partial_for(system: *const schema.System, name: []const u8, applied: *const Applied) ?nodes.Partial {
    if (!applied.injected) {
        const node = system.node(name) orelse return null;
        if (!node.faults.partial_persistence) return null;
    }
    return applied.partial();
}

/// Half of power losses persist part of what was not synced (nodes.Partial): on by default, as
/// the all-or-nothing loss alone never shows code that trusts the order of unsynced writes.
fn partial_draw(applied: *Applied) void {
    if (sdk.random_below_named("fault.partial", 2) != 0) return;
    applied.partial_seed = sdk.random_u64() | 1;
    applied.partial_commit = sdk.random_below_named("fault.partial_commit", 2) == 0;
}

/// A clock skew's size up to `max_ns`: a decade from a millisecond (1 ms, 10 ms, 100 ms, 1 s)
/// below it, then uniform within that decade (or up to the maximum).
fn clock_skew_draw(max_ns: u64) u64 {
    assert(max_ns >= clock_skew_ns_min * 10);
    var decades: u64 = 0;
    var top: u64 = clock_skew_ns_min * 10;
    while (top < max_ns and decades < 3) : (decades += 1) top *= 10;
    var low: u64 = clock_skew_ns_min;
    for (0..sdk.random_below_named("fault.clock.skew_decade", decades + 1)) |_| low *= 10;
    return low + sdk.random_below_named("fault.clock.skew_ns", @min(low * 10, max_ns) - low);
}

test clock_skew_draw {
    // Every size within the maximum, from a millisecond.
    for ([_]u64{ 10 * std.time.ns_per_ms, 400 * std.time.ns_per_ms, clock_skew_ns_max }) |max_ns| {
        for (0..200) |_| {
            const size = clock_skew_draw(max_ns);
            try std.testing.expect(size >= clock_skew_ns_min and size < max_ns);
        }
    }
}

/// A fault's parameters, drawn from platform randomness.
fn draw(fault: *const Fault) Applied {
    var applied = Applied{
        .kind = fault.kind,
        .node = fault.node,
        .peer = fault.peer,
        .program = fault.program,
        .duration_ns = switch (fault.kind) {
            .pause, .process_pause, .thread_pause => pause_duration_draw(),
            else => duration_draw(),
        },
    };
    switch (fault.kind) {
        .throttle => {
            const range = throttle_percent_max - throttle_percent_min;
            applied.cpu_percent = @intCast(throttle_percent_min + sdk.random_below(range + 1));
        },
        .process_pause, .process_kill, .pod_pause, .pod_kill, .pod_isolate => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_partition, .signal => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_degrade => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            const flavor = choice_named(Degradation, "fault.degrade.flavor", std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
        },
        .thread_pause => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(threads_max));
            // Shorter than other pauses (Antithesis: "Threads are paused for small periods of
            // time"), how much shorter the regime's draw (Regime.thread_pause_max_ns).
            applied.duration_ns = @min(applied.duration_ns, regime.thread_pause_max_ns);
        },
        .degrade => {
            const flavor = choice_named(Degradation, "fault.degrade.flavor", std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
        },
        .clock_skip => {
            applied.forward = sdk.random_below_named("fault.clock.forward", 2) == 0;
            applied.skip_ns = sdk.random_below_named("fault.clock.skip_ns", clock_skip_ns_max);
            applied.permanent = sdk.random_below_named("fault.clock.permanent", 4) == 0;
        },
        .clock_skew => {
            applied.forward = sdk.random_below_named("fault.clock.forward", 2) == 0;
            applied.skip_ns = clock_skew_draw(fault.skew_ns_max);
            // One in four strobes, flipping every 10 ms to a second.
            if (sdk.random_below_named("fault.clock.strobe", 4) == 0) applied.strobe_ns = (10 + sdk.random_below_named("fault.clock.strobe_ms", 991)) * std.time.ns_per_ms;
        },
        .outage => {
            applied.outage = outage_draw(fault.endpoints);
            applied.power = fault.power;
            if (applied.power) partial_draw(&applied);
        },
        .crash => partial_draw(&applied),
        .partition_groups => {
            applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
            applied.groups = groups_draw(fault.endpoints);
            // One way only in the regime's share of them (drawn: Regime): only from lower
            // groups to higher (outbound) or the other way (inbound).
            applied.direction = if (sdk.random_below_named("fault.oneway", 8) >= regime.oneway_eighths)
                .both
            else if (sdk.random_below(2) == 0) .outbound else .inbound;
        },
        .clog => {
            applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
            applied.direction = sdk.random_choice(Direction, std.enums.values(Direction));
        },
        .swizzle => swizzle_draw(&applied, outage_draw(fault.endpoints)),
        .durable_crash => {
            applied.one_in = 1 + @as(u32, @intCast(sdk.random_below_named("fault.durable_one_in", 8)));
            applied.after_sync = sdk.random_below_named("fault.durable_after", 2) == 1;
            partial_draw(&applied);
        },
        .sync_stall => {
            applied.one_in = 1 + @as(u32, @intCast(sdk.random_below_named("fault.stall_one_in", 4)));
            applied.stall_ms_max = 1 + @as(u32, @intCast(sdk.random_below_named("fault.stall_ms", stall_ms_max)));
        },
        .interleave => {
            applied.one_in = 1 + @as(u32, @intCast(sdk.random_below_named("fault.interleave_one_in", 4)));
        },
        .syscall_error => syscall_error_draw(&applied),
        .file_error => file_error_draw(&applied),
        .disk => {
            const all = comptime std.enums.values(nodes.DiskFailure);
            const kept = comptime disk_failures_kept();
            const failures: []const nodes.DiskFailure = if (fault.lost_writes) all else &kept;
            applied.disk = .{
                .failure = choice_named(nodes.DiskFailure, "fault.disk.failure", failures),
                .delay_ms = @intCast(1 + sdk.random_below_named("fault.disk.delay_ms", disk_delay_ms_max)),
                .corrupt_byte = @intCast(1 + sdk.random_below_named("fault.disk.corrupt_byte", disk_sector_size)),
                .corrupt_value = @intCast(sdk.random_below_named("fault.disk.corrupt_value", 256)),
            };
            // Half the time one file's blocks alone, as CORDS injects (one fault in one block
            // of one file of one node: Ganesan et al., FAST 2017): the rest of the disk healthy,
            // what the node does with that file the question.
            if (sdk.random_below_named("fault.disk_aim", 2) == 0) {
                if (nodes.disk_file_draw(applied.node, disk_file_buffer(applied.node))) |file| applied.disk.?.file = file;
            }
        },
        else => {},
    }
    return applied;
}

/// The files aimed disk faults fail, a buffer per node (a node has one disk fault at a time),
/// claimed by its name (the system's, alive as long as the injector).
var disk_file_buffers: [endpoints_max][nodes.path_size_max]u8 = undefined;
var disk_file_owners: [endpoints_max][]const u8 = undefined;
var disk_file_owner_count: usize = 0;

fn disk_file_buffer(node: []const u8) *[nodes.path_size_max]u8 {
    for (disk_file_owners[0..disk_file_owner_count], 0..) |owner, index| {
        if (std.mem.eql(u8, owner, node)) return &disk_file_buffers[index];
    }
    assert(disk_file_owner_count < endpoints_max);
    disk_file_owners[disk_file_owner_count] = node;
    disk_file_owner_count += 1;
    return &disk_file_buffers[disk_file_owner_count - 1];
}

/// The disk failures that keep what was stored: every one but lost_writes.
fn disk_failures_kept() [std.enums.values(nodes.DiskFailure).len - 1]nodes.DiskFailure {
    var kept: [std.enums.values(nodes.DiskFailure).len - 1]nodes.DiskFailure = undefined;
    var count: usize = 0;
    for (std.enums.values(nodes.DiskFailure)) |failure| {
        if (failure == .lost_writes) continue;
        kept[count] = failure;
        count += 1;
    }
    return kept;
}

/// A pause's length (a node's, a process's, a thread's), fat-tailed: uniform in its exponent from
/// the regime's shortest pause to its bound on a fault's length, each octave as likely as
/// another, then uniform within it (both bounds drawn: Regime). Antithesis's (Will Wilson, Developer Voices): pauses drawn from a
/// fat-tailed power law find more than uniform ones; short ones open race windows a few
/// milliseconds wide, long ones outlast leases and timeouts. The uniform mixture before drew a
/// pause under 10 ms one time in 200.
fn pause_duration_draw() u64 {
    const max = if (regime.duration_max_ns == 0) duration_ns_max else regime.duration_max_ns;
    const octaves = std.math.log2_int(u64, max / regime.pause_min_ns);
    const octave = sdk.random_below_named("fault.pause_log2", octaves);
    const low = regime.pause_min_ns << @intCast(octave);
    return low + sdk.random_below_named("fault.pause_ns", low);
}

/// The fixed injector's shortest pause, and its longest thread pause.
const pause_ns_min: u64 = std.time.ns_per_ms;

test pause_duration_draw {
    // Within its bounds whatever the draws (outside determinismo the SDK draws from its own
    // generator), and spread over the octaves: some under 10 ms, some over a second.
    var short: u32 = 0;
    var long: u32 = 0;
    for (0..2000) |_| {
        const drawn = pause_duration_draw();
        try std.testing.expect(drawn >= regime.pause_min_ns and drawn < 2 * duration_ns_max);
        short += @intFromBool(drawn < 10 * std.time.ns_per_ms);
        long += @intFromBool(drawn > std.time.ns_per_s);
    }
    try std.testing.expect(short > 200 and long > 200);
}

const Start = struct { scenario: ?[]const u8 = null, only: ?std.EnumSet(Kind) = null };

/// `--scenario <name>` and `--only <kind>,<kind>...`, in any order, at least one of them.
fn start_parse(arguments: []const []const u8) !Start {
    var start: Start = .{};
    var at: usize = 1;
    while (at + 1 < arguments.len) : (at += 2) {
        if (std.mem.eql(u8, arguments[at], "--scenario")) {
            start.scenario = arguments[at + 1];
        } else if (std.mem.eql(u8, arguments[at], "--only")) {
            var kinds: std.EnumSet(Kind) = .empty;
            var names = std.mem.tokenizeScalar(u8, arguments[at + 1], ',');
            while (names.next()) |name| kinds.insert(std.meta.stringToEnum(Kind, name) orelse return error.Usage);
            if (kinds.count() == 0) return error.Usage;
            start.only = kinds;
        } else return error.Usage;
    }
    if (at != arguments.len or (start.scenario == null and start.only == null)) return error.Usage;
    return start;
}

/// The faults of those kinds, in their order, at the front: how many.
fn faults_keep(faults: *[faults_max]Fault, count: u32, kinds: std.EnumSet(Kind)) u32 {
    var kept: u32 = 0;
    for (faults[0..count]) |fault| {
        if (!kinds.contains(fault.kind)) continue;
        faults[kept] = fault;
        kept += 1;
    }
    return kept;
}

test "det-faults' arguments: a scenario, --only's kinds, or both; anything else refused" {
    const only = try start_parse(&.{ "det-faults", "--only", "thread_pause,process_pause,interleave" });
    try std.testing.expect(only.scenario == null);
    try std.testing.expectEqual(@as(usize, 3), only.only.?.count());
    try std.testing.expect(only.only.?.contains(.interleave));
    const both = try start_parse(&.{ "det-faults", "--only", "partition", "--scenario", "main" });
    try std.testing.expectEqualStrings("main", both.scenario.?);
    try std.testing.expect(both.only.?.contains(.partition));
    try std.testing.expect((try start_parse(&.{ "det-faults", "--scenario", "main" })).only == null);
    try std.testing.expectError(error.Usage, start_parse(&.{"det-faults"}));
    try std.testing.expectError(error.Usage, start_parse(&.{ "det-faults", "--only", "partitoin" }));
    try std.testing.expectError(error.Usage, start_parse(&.{ "det-faults", "--only", "," }));
    try std.testing.expectError(error.Usage, start_parse(&.{ "det-faults", "--only" }));
    try std.testing.expectError(error.Usage, start_parse(&.{ "det-faults", "--kinds", "pause" }));
}

test "det-faults --only keeps the faults of its kinds alone, in their order" {
    var faults: [faults_max]Fault = undefined;
    faults[0] = .{ .kind = .partition, .node = "a" };
    faults[1] = .{ .kind = .thread_pause, .node = "a" };
    faults[2] = .{ .kind = .crash, .node = "b" };
    faults[3] = .{ .kind = .process_pause, .node = "b" };
    faults[4] = .{ .kind = .interleave, .node = "a" };
    var timing: std.EnumSet(Kind) = .empty;
    for ([_]Kind{ .thread_pause, .process_pause, .interleave }) |kind| timing.insert(kind);
    const kept = faults_keep(&faults, 5, timing);
    try std.testing.expectEqual(@as(u32, 3), kept);
    try std.testing.expectEqual(Kind.thread_pause, faults[0].kind);
    try std.testing.expectEqual(Kind.process_pause, faults[1].kind);
    try std.testing.expectEqualStrings("b", faults[1].node);
    try std.testing.expectEqual(Kind.interleave, faults[2].kind);
}

test "regimes draw wide, varied distributions of a fault's length and a partition's direction" {
    // Within each regime's bound whatever the draws; across regimes, bounds from under a second
    // to over a minute, both shapes, and one-way shares from none to all.
    defer regime = .fixed;
    var bound_short = false;
    var bound_long = false;
    var shapes: std.EnumSet(Regime.Shape) = .empty;
    var oneway_none = false;
    var oneway_all = false;
    for (0..400) |_| {
        regime = regime_draw();
        try std.testing.expect(regime.duration_max_ns >= 50 * std.time.ns_per_ms);
        try std.testing.expect(regime.duration_max_ns <= 102_400 * std.time.ns_per_ms);
        try std.testing.expect(regime.oneway_eighths <= 8);
        try std.testing.expect(regime.gap_mean_ns >= 12_500 * std.time.ns_per_us);
        try std.testing.expect(regime.pause_min_ns >= 62_500 and regime.pause_min_ns <= 4 * std.time.ns_per_ms);
        try std.testing.expect(regime.thread_pause_max_ns >= 5 * std.time.ns_per_ms);
        try std.testing.expect(regime.thread_pause_max_ns <= 5_120 * std.time.ns_per_ms);
        for (0..5) |_| {
            const paused = pause_duration_draw();
            try std.testing.expect(paused >= regime.pause_min_ns and paused <= 2 * regime.duration_max_ns);
        }
        bound_short = bound_short or regime.duration_max_ns < std.time.ns_per_s;
        bound_long = bound_long or regime.duration_max_ns > 60 * std.time.ns_per_s;
        shapes.insert(regime.duration_shape);
        oneway_none = oneway_none or regime.oneway_eighths == 0;
        oneway_all = oneway_all or regime.oneway_eighths == 8;
        for (0..20) |_| {
            const drawn = duration_draw();
            try std.testing.expect(drawn >= 1 and drawn <= 2 * regime.duration_max_ns);
        }
    }
    try std.testing.expect(bound_short and bound_long and shapes.count() == 2 and oneway_none and oneway_all);
    // The fixed injector (--no-swarm): its mixture, up to 10 s.
    regime = .fixed;
    for (0..200) |_| try std.testing.expect(duration_draw() < duration_ns_max);
}

/// A fault's length (all but pauses): from the regime's distribution, its bound and its shape
/// drawn with it (regime_draw). With --no-swarm, the fixed injector's mixture: up to 500 ms,
/// one in four up to 10 s.
fn duration_draw() u64 {
    if (regime.duration_max_ns == 0) {
        const long = sdk.random_below_named("fault.duration_long", long_one_in) == 0;
        return sdk.random_below_named("fault.duration_ns", if (long) duration_ns_max else duration_short_ns_max);
    }
    return switch (regime.duration_shape) {
        .uniform => 1 + sdk.random_below_named("fault.duration_ns", regime.duration_max_ns),
        .log_uniform => log_uniform_draw(regime.duration_max_ns),
    };
}

/// Uniform in its exponent from the regime's shortest pause to `max` (each octave as likely as
/// another), then uniform within the octave.
fn log_uniform_draw(max: u64) u64 {
    assert(max >= 2 * regime.pause_min_ns);
    const octaves = std.math.log2_int(u64, max / regime.pause_min_ns);
    const octave = sdk.random_below_named("fault.duration_log2", octaves);
    const low = regime.pause_min_ns << @intCast(octave);
    return low + sdk.random_below_named("fault.duration_ns", low);
}

/// How often faults come, how long they last, and how partitions cut, for a stretch of the
/// timeline. Every one of these is drawn, wide, the distributions themselves per regime: no value
/// is the right one ("It's all probabilities/randomness, let's not be literal", the user,
/// 2026-11-10), and the explorer's guidance finds which regions matter. Copied numbers before:
/// durations up to 500 ms or one in four up to 10 s (Antithesis's example partition) times a
/// scale of 1 to 8, partitions one-way half the time (Antithesis's); our first injector's 110 to
/// 170 faults a virtual minute and Antithesis's public runs' 8 (lasting 2.5 to 3 s, partitions to
/// 70 s) both inside these ranges. A regime draws:
/// - a mean gap between faults, 12.5 ms to 25.6 s, log-uniform ("fault.gap_log2");
/// - a bound on a fault's length, 50 ms to 102.4 s, log-uniform ("fault.duration_max_log2"), and
///   a shape under it ("fault.duration_shape"): uniform (long faults common) or log-uniform
///   (each octave from the shortest pause alike: short ones common, a few long);
/// - pauses' bounds: the shortest 62.5 us to 4 ms ("fault.pause_min_log2"), the longest a fault's
///   bound; a thread's at most 5 ms to 5.12 s ("fault.thread_pause_log2", the fixed injector's
///   500 ms copied from Antithesis's "small periods");
/// - the share of partitions that cut one way only, 0 to 8 eighths ("fault.oneway_eighths");
/// - the share of faults that may come on a node already faulted in the other layer (a crash
///   under a skewed clock), 0 to 8 eighths ("fault.overlap_eighths": Layer);
/// and holds for 10 to 120 s ("fault.regime_ms"); then the next, the swarm's kinds and weights
/// drawn again with it. With --no-swarm, the fixed injector: every 10 to 300 ms, the fixed
/// mixture of durations, half the partitions one way, one fault at a time on a node, never
/// redrawn.
const Regime = struct {
    gap_mean_ns: u64,
    /// 0: the fixed injector's mixture (duration_draw).
    duration_max_ns: u64,
    duration_shape: Shape,
    oneway_eighths: u32,
    overlap_eighths: u32,
    pause_min_ns: u64,
    thread_pause_max_ns: u64,
    stretch_ns: u64,
    /// The guest kernel's random generator re-randomized every this long (0: never in this
    /// regime): what the guest's programs draw afresh from it (getrandom, /dev/urandom, TCP's
    /// sequence numbers) leaves its parent timeline's stream. Drawn on or off, then its interval,
    /// both learned from (random_config), as Antithesis's rollouts draw it (add_entropy, on in
    /// about 28% of them, every 10 to 58 s; docs/ANTITHESIS_EXPLORATION.md).
    rerandomize_ns: u64,

    const Shape = enum { uniform, log_uniform };
    const fixed: Regime = .{
        .gap_mean_ns = 0,
        .duration_max_ns = 0,
        .duration_shape = .uniform,
        .oneway_eighths = 4,
        .overlap_eighths = 0,
        .pause_min_ns = pause_ns_min,
        .thread_pause_max_ns = duration_short_ns_max,
        .stretch_ns = std.math.maxInt(u64),
        .rerandomize_ns = 0,
    };
};

var regime: Regime = .fixed;

fn regime_draw() Regime {
    if (swarm_off()) return .fixed;
    const gap_min_ns: u64 = 12_500 * std.time.ns_per_us;
    const gap_mean_ns = gap_min_ns << @intCast(sdk.random_config("fault.gap_log2", 12));
    const duration_min_ns: u64 = 50 * std.time.ns_per_ms;
    const duration_max_ns = duration_min_ns << @intCast(sdk.random_config("fault.duration_max_log2", 12));
    const duration_shape: Regime.Shape = if (sdk.random_config("fault.duration_shape", 2) == 0) .uniform else .log_uniform;
    const oneway_eighths: u32 = @intCast(sdk.random_config("fault.oneway_eighths", 9));
    const overlap_eighths: u32 = @intCast(sdk.random_config("fault.overlap_eighths", 9));
    const pause_min_ns = @as(u64, 62_500) << @intCast(sdk.random_config("fault.pause_min_log2", 7));
    const thread_pause_max_ns = @as(u64, 5 * std.time.ns_per_ms) << @intCast(sdk.random_config("fault.thread_pause_log2", 11));
    const stretch_ms = 10_000 + sdk.random_below_named("fault.regime_ms", 110_001);
    // Re-randomized or not, then every 1 s to 128 s (a power of two: wide, each one learned).
    const rerandomize_ns: u64 = if (sdk.random_config("entropy.rerandomize", 2) == 0)
        0
    else
        @as(u64, std.time.ns_per_s) << @intCast(sdk.random_config("entropy.rerandomize_log2", 8));
    sdk.event("fault_regime", .{
        .gap_mean_ms = gap_mean_ns / std.time.ns_per_ms,
        .duration_max_ms = duration_max_ns / std.time.ns_per_ms,
        .duration_shape = @tagName(duration_shape),
        .oneway_eighths = oneway_eighths,
        .overlap_eighths = overlap_eighths,
        .pause_min_us = pause_min_ns / std.time.ns_per_us,
        .thread_pause_max_ms = thread_pause_max_ns / std.time.ns_per_ms,
        .stretch_ms = stretch_ms,
        .rerandomize_ms = rerandomize_ns / std.time.ns_per_ms,
    });
    return .{
        .gap_mean_ns = gap_mean_ns,
        .duration_max_ns = duration_max_ns,
        .duration_shape = duration_shape,
        .oneway_eighths = oneway_eighths,
        .overlap_eighths = overlap_eighths,
        .pause_min_ns = pause_min_ns,
        .thread_pause_max_ns = thread_pause_max_ns,
        .stretch_ns = stretch_ms * std.time.ns_per_ms,
        .rerandomize_ns = rerandomize_ns,
    };
}

/// When the guest kernel's generator is re-randomized next (Regime.rerandomize_ns; never when 0).
var rerandomize_next_ns: u64 = std.math.maxInt(u64);

fn rerandomize_schedule() void {
    rerandomize_next_ns = if (regime.rerandomize_ns == 0) std.math.maxInt(u64) else monotonic_ns() + regime.rerandomize_ns;
}

/// Due: the guest kernel's generator reseeded from a platform decision (replayed like any other),
/// and the next one scheduled.
fn rerandomize_due(now_ns: u64) void {
    if (now_ns < rerandomize_next_ns) return;
    nodes.kernel_reseed();
    sdk.event("entropy_rerandomized", .{ .every_ms = regime.rerandomize_ns / std.time.ns_per_ms });
    rerandomize_next_ns = if (regime.rerandomize_ns == 0) std.math.maxInt(u64) else now_ns + regime.rerandomize_ns;
}

/// A strategy's poll of the wait between faults (the machine it decided: explore's
/// `det.fault_poll_ms=`), read once; 0: none.
var fault_poll_read = false;
var fault_poll_ns: u64 = 0;

fn fault_poll() u64 {
    if (fault_poll_read) return fault_poll_ns;
    fault_poll_read = true;
    var buffer: [16]u8 = undefined;
    const text = cmdline_word("det.fault_poll_ms=", &buffer) orelse return 0;
    const ms = std.fmt.parseInt(u32, text, 10) catch return 0;
    fault_poll_ns = @as(u64, @min(ms, 1000)) * std.time.ns_per_ms;
    return fault_poll_ns;
}

/// The wait before the next fault, slept; polled when a strategy asked (fault_poll): in slices,
/// each asking "fault.now", whose answer 0 ends it (the strategy's moment: it has seen the
/// timeline's events so far), any other value, as a draw nearly always is, waits on.
fn wait_or_poll(wait_ns: u64) void {
    const poll_ns = fault_poll();
    if (poll_ns == 0) return sleep_ns(wait_ns);
    const deadline_ns = monotonic_ns() + wait_ns;
    while (true) {
        const now_ns = monotonic_ns();
        if (now_ns >= deadline_ns) return;
        sleep_ns(@min(poll_ns, deadline_ns - now_ns));
        if (stopping.load(.acquire)) return;
        if (sdk.random_below_named("fault.now", 1 << 32) == 0) {
            sdk.event("fault_now", .{ .poll_ms = poll_ns / std.time.ns_per_ms });
            return;
        }
    }
}

/// The wait before the next fault: uniform up to twice the regime's mean gap, or the fixed
/// injector's 10 to 300 ms.
fn regime_wait_ns() u64 {
    if (regime.gap_mean_ns == 0) return delay_ns_min + sdk.random_below_named("fault.wait_ns", delay_ns_max - delay_ns_min);
    return 1 + sdk.random_below_named("fault.wait_ns", 2 * regime.gap_mean_ns);
}

/// Two or three groups over the endpoints that allow partitions, never all in one.
fn groups_draw(allowed: [endpoints_max]bool) [endpoints_max]u16 {
    var groups: [endpoints_max]u16 = @splat(group_none);
    const count: u16 = @intCast(2 + sdk.random_below(2));
    var first: ?usize = null;
    var split = false;
    for (allowed, &groups, 0..) |ok, *group, index| {
        if (!ok) continue;
        group.* = @intCast(sdk.random_below(count));
        if (first) |at| split = split or groups[at] != group.* else first = index;
    }
    if (!split) if (first) |at| {
        groups[at] = (groups[at] + 1) % count; // At least two sides.
    };
    return groups;
}

/// The nodes of an outage, among those allowed: all of them half the time (a datacenter's
/// power), else a random group of at least two (a rack's).
fn outage_draw(allowed: [endpoints_max]bool) [endpoints_max]bool {
    if (sdk.random_below_named("fault.outage_all", 2) == 0) return allowed;
    var candidates: [endpoints_max]u8 = undefined;
    var count: u32 = 0;
    for (allowed, 0..) |yes, index| {
        if (!yes) continue;
        candidates[count] = @intCast(index);
        count += 1;
    }
    assert(count >= 2);
    const size = 2 + sdk.random_below_named("fault.outage_size", count - 1);
    // The first `size` of a partial Fisher-Yates shuffle.
    var picked: [endpoints_max]bool = @splat(false);
    for (0..size) |at| {
        const other = at + sdk.random_below(count - at);
        std.mem.swap(u8, &candidates[at], &candidates[other]);
        picked[candidates[at]] = true;
    }
    return picked;
}

fn script_faults(arena: std.mem.Allocator) ?[]const Applied {
    const Script = struct { faults: []const Applied = &.{} };
    const fd = linux.open("/det/script.json", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const buffer = arena.alloc(u8, 1 << 20) catch return null;
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const script = sdk.schema.parse(Script, arena, buffer[0..size]) catch return null;
    return script.faults;
}

/// The script's faults at their offsets (until stopped), instead of drawn ones.
fn run_script(
    arena: std.mem.Allocator,
    system: *const schema.System,
    faults: []const Applied,
) void {
    const start_ns = monotonic_ns();
    var injections: u32 = 0;
    following_script = true;
    for (faults) |*fault| {
        sleep_through_ns(start_ns + fault.at_ns -| monotonic_ns());
        if (stopping.load(.acquire)) break;
        // A fault of a node that is gone is skipped (clock skips and partitions into groups
        // name no node). The runner is no node of the system's, and never gone: its links'
        // faults ("degrade runner ...") were all skipped, the scripted timeline missing them.
        const runner = std.mem.eql(u8, fault.node, "runner");
        const gone = fault.node.len > 0 and !runner and !names_a_node(system, fault);
        if (gone) continue;
        apply(arena, system, fault);
        injections += 1;
    }
    node_heal(system);
    disk_settle(system);
    network_stop(system);
    leftovers_check(system);
    sdk.event("faults_stop", .{ .injections = injections, .script = true });
}

/// Whether a scripted fault names a node of the system. An outage's names every node it took
/// down, joined by commas ("witness,echo", its event's for reading; `outage` holds them): looked
/// up whole, no node had that name and every scripted outage was skipped as a gone node's.
fn names_a_node(system: *const schema.System, fault: *const Applied) bool {
    if (fault.kind != .outage) return system.node(fault.node) != null;
    var names = std.mem.splitScalar(u8, fault.node, ',');
    while (names.next()) |name| if (system.node(name) != null) return true;
    return false;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn faults_collect(
    system: *const schema.System,
    scenario: *const schema.Scenario,
    faults: *[faults_max]Fault,
) u32 {
    var count: u32 = 0;
    faults_dropped = 0;
    for (system.nodes, 0..) |node, index| {
        if (excluded(node.name)) continue; // Its links' faults too: they act on its network.
        const allowed = node.faults;
        if (allowed.pause) faults_add(faults, &count, .{ .kind = .pause, .node = node.name });
        if (allowed.isolate) faults_add(faults, &count, .{ .kind = .isolate, .node = node.name });
        if (allowed.restart) faults_add(faults, &count, .{ .kind = .restart, .node = node.name });
        if (allowed.crash) {
            faults_add(faults, &count, .{ .kind = .crash, .node = node.name });
            faults_add(faults, &count, .{ .kind = .durable_crash, .node = node.name });
        }
        if (allowed.wipe) faults_add(faults, &count, .{ .kind = .wipe, .node = node.name });
        if (allowed.stop) faults_add(faults, &count, .{ .kind = .stop, .node = node.name });
        if (allowed.disk) faults_add(faults, &count, .{
            .kind = .disk,
            .node = node.name,
            .lost_writes = allowed.disk_lost_writes,
        });
        if (allowed.throttle) faults_add(faults, &count, .{ .kind = .throttle, .node = node.name });
        if (allowed.clock_skew) faults_add(faults, &count, .{
            .kind = .clock_skew,
            .node = node.name,
            .skew_ns_max = @as(u64, @max(10, allowed.clock_skew_ms_max)) * std.time.ns_per_ms,
        });
        if (allowed.sync_stall) faults_add(faults, &count, .{ .kind = .sync_stall, .node = node.name });
        if (allowed.process_pause) {
            faults_add(faults, &count, .{ .kind = .process_pause, .node = node.name });
            faults_add(faults, &count, .{ .kind = .thread_pause, .node = node.name });
        }
        if (allowed.interleave) faults_add(faults, &count, .{ .kind = .interleave, .node = node.name });
        if (allowed.process_kill) {
            faults_add(faults, &count, .{ .kind = .process_kill, .node = node.name });
        }
        if (allowed.signals) faults_add(faults, &count, .{ .kind = .signal, .node = node.name });
        if (allowed.syscall_errors) faults_add(faults, &count, .{ .kind = .syscall_error, .node = node.name });
        if (allowed.file_errors) faults_add(faults, &count, .{ .kind = .file_error, .node = node.name });
        if (allowed.pods) {
            for ([_]Kind{ .pod_pause, .pod_kill, .pod_isolate, .pod_degrade, .pod_partition }) |kind| {
                faults_add(faults, &count, .{ .kind = kind, .node = node.name });
            }
        }
        for (allowed.custom) |program| {
            faults_add(faults, &count, .{ .kind = .custom, .node = node.name, .program = program });
        }
        for (plugin_faults()) |fault| if (std.mem.eql(u8, fault.node, node.name)) {
            faults_add(faults, &count, .{ .kind = .custom, .node = node.name, .program = fault.command });
        };
        links_collect(system, index, faults, &count);
    }
    var endpoints: [endpoints_max]bool = @splat(false);
    endpoints[0] = true; // The runner allows all.
    var partitionable: u32 = 1;
    var isolatable: [endpoints_max]bool = @splat(false);
    var isolatable_count: u32 = 0;
    for (system.nodes, 1..) |node, index| {
        // An excluded node stays with the runner's group, reaching every node and reached.
        const kept = !excluded(node.name);
        endpoints[index] = node.faults.partition and kept;
        partitionable += @intFromBool(endpoints[index]);
        if (node.faults.isolate and kept) faults_add(faults, &count, .{ .kind = .clog, .node = node.name });
        isolatable[index] = node.faults.isolate and kept;
        isolatable_count += @intFromBool(isolatable[index]);
    }
    if (partitionable >= 3) {
        faults_add(faults, &count, .{ .kind = .partition_groups, .endpoints = endpoints });
    }
    if (isolatable_count >= 2) faults_add(faults, &count, .{ .kind = .swizzle, .endpoints = isolatable });
    var crashable: [endpoints_max]bool = @splat(false);
    var crashable_count: u32 = 0;
    var restartable: [endpoints_max]bool = @splat(false);
    var restartable_count: u32 = 0;
    for (system.nodes, 1..) |node, index| {
        // Outages take the nodes that allow them (Faults.outage): a node left out still
        // restarts and crashes, one at a time.
        const kept = !excluded(node.name);
        crashable[index] = node.faults.crash and node.faults.outage and kept;
        crashable_count += @intFromBool(crashable[index]);
        restartable[index] = node.faults.restart and node.faults.outage and kept;
        restartable_count += @intFromBool(restartable[index]);
    }
    if (crashable_count >= 2) faults_add(faults, &count, .{ .kind = .outage, .endpoints = crashable });
    if (restartable_count >= 2) {
        faults_add(faults, &count, .{ .kind = .outage, .endpoints = restartable, .power = false });
    }
    if (scenario.clock_skip) faults_add(faults, &count, .{ .kind = .clock_skip });
    const networked = for (faults[0..count]) |fault| switch (fault.kind) {
        .isolate, .partition, .degrade, .partition_groups, .clog, .swizzle => break true,
        else => {},
    } else false;
    if (networked) faults_add(faults, &count, .{ .kind = .restore });
    assert(count <= faults_max);
    return count;
}

/// Link faults between node `index` and the runner or a later node, as both ends allow (the
/// runner allows all). A degraded link is one direction: both directions are listed.
fn links_collect(
    system: *const schema.System,
    index: usize,
    faults: *[faults_max]Fault,
    count: *u32,
) void {
    const node = &system.nodes[index];
    if (node.faults.runner_links) links_add(faults, count, node, schema.runner_name, .{});
    for (system.nodes[index + 1 ..]) |peer| links_add(faults, count, node, peer.name, peer.faults);
}

fn links_add(
    faults: *[faults_max]Fault,
    count: *u32,
    node: *const schema.Resolved,
    peer: []const u8,
    peer_faults: schema.Faults,
) void {
    if (node.faults.partition and peer_faults.partition) {
        faults_add(faults, count, .{ .kind = .partition, .node = node.name, .peer = peer });
    }
    if (node.faults.degrade and peer_faults.degrade) {
        faults_add(faults, count, .{ .kind = .degrade, .node = node.name, .peer = peer });
        faults_add(faults, count, .{ .kind = .degrade, .node = peer, .peer = node.name });
    }
}

fn faults_add(faults: *[faults_max]Fault, count: *u32, fault: Fault) void {
    if (count.* == faults_max) {
        faults_dropped += 1;
        return;
    }
    faults[count.*] = fault;
    count.* += 1;
}

/// Applies one fault for its duration and undoes it, even when stopped meanwhile. The event
/// carries everything about it, so that `determinismo script` can put it in a script.
fn apply(arena: std.mem.Allocator, system: *const schema.System, applied: *const Applied) void {
    doing_set("apply", applied.kind, applied.node);
    defer doing_set("wait", null, "");
    if (!quorum_kept(system, applied)) {
        sdk.event("fault_skipped", .{ .kind = @tagName(applied.kind), .node = applied.node, .err = "QuorumKept" });
        return;
    }
    switch (applied.kind) {
        .pause,
        .restart,
        .crash,
        .durable_crash,
        .sync_stall,
        .wipe,
        .stop,
        .disk,
        .throttle,
        .clock_skew,
        .process_pause,
        .thread_pause,
        .interleave,
        .syscall_error,
        .file_error,
        .pod_pause,
        .pod_isolate,
        .pod_degrade,
        .pod_partition,
        => _ = node_start(system, applied),
        .outage => outage_start(system, applied),
        .process_kill => apply_process_kill(system, applied),
        .signal => apply_signal(applied),
        .pod_kill => apply_pod_kill(applied),
        .isolate, .partition, .degrade, .partition_groups, .clog => network_start(system, applied),
        .swizzle => swizzle_start(system, applied),
        .restore => network_restore(system, applied),
        .clock_skip => {
            sdk.event("fault", applied.*);
            clock_shift(applied.skip_ns, .{ .forward = applied.forward });
            sleep_through_ns(applied.duration_ns); // Quiet periods leave clock skips alone.
            if (applied.permanent) return; // It stays, and later skips stack on it.
            clock_shift(applied.skip_ns, .{ .forward = !applied.forward });
        },
        .custom => apply_custom(arena, system, applied),
    }
}

// Node faults -----------------------------------------------------------------------------
// Two layers on a node: what happens to its processes (pauses, stops, crashes, restarts, wipes,
// disk failures, pods' faults) and the conditions it runs under (a skewed clock, a CPU limit,
// stalled syncs, interleaving, failing system calls or files). One fault at a time in a layer;
// across the two, the regime's overlap share draws whether a second one comes on a node already
// faulted (Regime.overlap_eighths: none to all). Antithesis's rule was one fault at a time on a
// node, copied before: a crash under a skewed clock or while syncs stall never came. A condition
// survives what the process layer does (armed on the node's cgroup; a restarted node's clock
// starts unskewed, a fresh namespace), and each one's undo tolerates a node down or restarted.
// Disk failures stay in the process layer: they interplay with crashes' partial persistence and
// wipes. Several nodes at once. Each is undone at its end, and all at a quiet period or the stop.

const Layer = enum(u1) { process, condition };
const layers = 2;

fn layer_of(kind: Kind) Layer {
    return switch (kind) {
        .clock_skew, .throttle, .sync_stall, .interleave, .syscall_error, .file_error => .condition,
        else => .process,
    };
}

const NodeFault = struct {
    applied: Applied,
    end_ns: u64,
    /// A stop: when what the node left running is killed (its grace period ends), if still
    /// pending.
    grace_end_ns: ?u64 = null,
    /// A strobing clock skew: when it next comes or goes, and whether it is on now.
    flip_ns: ?u64 = null,
    skewed: bool = true,
    /// The process or thread stopped (process_pause, thread_pause); for a pod fault, a process
    /// of the pod (its network namespace).
    pid: linux.pid_t = 0,
    /// thread_pause: its stop reported (a thread in a kernel wait stops only as it returns).
    stopped: bool = false,
    /// The pod's cgroup (pod faults), and for pod_partition the other one's, its process, and
    /// the two pods' addresses.
    pod: Pod = .{},
    peer: Pod = .{},
    peer_pid: linux.pid_t = 0,
    addresses: [2]nodes.Address = undefined,
    /// The stopped process's command name (process_pause, thread_pause), for its event.
    command: [16]u8 = undefined,
    command_size: u8 = 0,
};

/// A process's command name (/proc/<pid>/comm), into `buffer`.
fn command_of(pid: linux.pid_t, buffer: *[16]u8) []const u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return "";
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return "";
    return std.mem.trimEnd(u8, buffer[0..size], "\n");
}
var nodes_faulted: [schema.nodes_max][layers]?NodeFault = @splat(@splat(null));

/// Whether a node has a fault in either layer.
fn node_busy(index: usize) bool {
    for (nodes_faulted[index]) |slot| if (slot != null) return true;
    return false;
}

/// Whether a fault of `layer` may start on the node: its layer free, and the other free too or
/// the regime's overlap drawn.
fn node_admits(index: usize, layer: Layer) bool {
    if (nodes_faulted[index][@backingInt(layer)] != null) return false;
    if (!node_busy(index)) return true;
    // A scripted fault overlapped another where it was recorded: that overlap was drawn there.
    // Drawn again in a replay (whose regime is .fixed, overlap 0), every overlap was refused:
    // a 90 s throttle over a process pause, gone from the bank's scripted timeline.
    if (following_script) return true;
    return sdk.random_below_named("fault.overlap", 8) < regime.overlap_eighths;
}

/// Following a script (run_script): its faults are applied as they were, not admitted anew.
var following_script = false;
/// For starting nodes again when their fault ends (set once faults start).
var arena_active: ?std.mem.Allocator = null;
/// How long a graceful stop waits for the node to exit before it is killed. A node's main
/// process is the init of its PID namespace: without a SIGTERM handler, it ignores the signal
/// (as in a container), and the grace period ends in a kill.
const stop_grace_ns = 3 * std.time.ns_per_s;
/// How often a heal looks whether a stopping node exited.
const stop_exit_poll_ns = 20 * std.time.ns_per_ms;

test "a node takes one fault a layer, and one in each only as the regime's overlap draws" {
    defer regime = .fixed;
    defer nodes_faulted[0] = @splat(null);
    try std.testing.expectEqual(Layer.condition, layer_of(.clock_skew));
    try std.testing.expectEqual(Layer.condition, layer_of(.syscall_error));
    try std.testing.expectEqual(Layer.process, layer_of(.crash));
    try std.testing.expectEqual(Layer.process, layer_of(.disk)); // With crashes' partial persistence.
    try std.testing.expect(node_admits(0, .process) and node_admits(0, .condition));
    nodes_faulted[0][@backingInt(Layer.condition)] = .{ .applied = .{ .kind = .clock_skew, .node = "a", .duration_ns = 0 }, .end_ns = 0 };
    // The fixed injector (and a regime drawing none): one fault at a time on a node.
    regime = .fixed;
    for (0..50) |_| try std.testing.expect(!node_admits(0, .process) and !node_admits(0, .condition));
    // A regime drawing all: the other layer always, never the same one.
    regime.overlap_eighths = 8;
    for (0..50) |_| try std.testing.expect(node_admits(0, .process) and !node_admits(0, .condition));
    // Half: sometimes.
    regime.overlap_eighths = 4;
    var admitted: u32 = 0;
    for (0..400) |_| admitted += @intFromBool(node_admits(0, .process));
    try std.testing.expect(admitted > 100 and admitted < 300);
}

test "a script's fault overlapping another is admitted as it was, though a replay's regime draws none" {
    defer regime = .fixed;
    defer nodes_faulted[0] = @splat(null);
    defer following_script = false;
    nodes_faulted[0][@backingInt(Layer.process)] = .{ .applied = .{ .kind = .process_pause, .node = "redis", .duration_ns = 0 }, .end_ns = 0 };
    regime = .fixed; // A replay's: overlap 0.
    following_script = true;
    // A throttle over a process pause (the bank's scripted timeline): the other layer, admitted.
    for (0..50) |_| try std.testing.expect(node_admits(0, .condition));
    // The same layer stays one fault at a time, scripted or not.
    try std.testing.expect(!node_admits(0, .process));
}

fn node_slot(system: *const schema.System, name: []const u8, layer: Layer) ?*?NodeFault {
    const index = endpoint_index(system, name) orelse return null;
    if (index == 0) return null; // The runner is not a node.
    return &nodes_faulted[index - 1][@backingInt(layer)];
}

/// A clock skew's signed offset.
fn skew_ns(applied: *const Applied) i64 {
    const size: i64 = @intCast(applied.skip_ns);
    return if (applied.forward) size else -size;
}

/// A drawn skew kept within the node's largest skew of every other node's skew now: a system's
/// maximum clock offset holds between any two nodes, and two nodes skewed opposite ways would
/// otherwise be twice that apart (srv3, 2026-10-30: crdb-3 at +275 ms and crdb-2 at -223 ms,
/// 498 ms apart with CockroachDB's maximum at 500). And within it of the highest any clock has
/// read (clock_high_ns): a hybrid logical clock keeps the latest time it saw, a skew gone from
/// the clock that set it still in every clock it reached, so a node skewed back later met it
/// further apart than any two skews at once (YugabyteDB hunt run 1996, timeline 84: "Too big
/// clock skew is detected: 0.574s, while max allowed is: 0.500s", every skew within 400 ms of
/// the others then). A skew asked for by the scenario is as asked. Null when no offset fits.
fn skew_clamped(system: *const schema.System, applied: *const Applied) ?i64 {
    const offset_ns = skew_ns(applied);
    if (applied.injected) return offset_ns;
    const node = system.node(applied.node) orelse return offset_ns;
    const max_ns: i64 = @as(i64, @max(10, node.faults.clock_skew_ms_max)) * std.time.ns_per_ms;
    var others: [schema.nodes_max * layers]i64 = undefined;
    var count: usize = 0;
    for (nodes_faulted) |slots| for (slots) |slot| {
        const other = slot orelse continue;
        if (other.applied.kind != .clock_skew or std.mem.eql(u8, other.applied.node, applied.node)) continue;
        others[count] = skew_ns(&other.applied);
        count += 1;
    };
    return skew_clamp(offset_ns, max_ns, others[0..count], clock_high_ns - monotonic_signed_ns());
}

/// `offset_ns` within `max_ns` of each of `others` and no more than `max_ns` below
/// `remembered_ns` (the highest clock reading, less the time now); null when nothing fits.
fn skew_clamp(offset_ns: i64, max_ns: i64, others: []const i64, remembered_ns: i64) ?i64 {
    var low: i64 = @max(-max_ns, remembered_ns - max_ns);
    var high: i64 = max_ns;
    for (others) |theirs| {
        low = @max(low, theirs - max_ns);
        high = @min(high, theirs + max_ns);
    }
    if (low > high) return null;
    return std.math.clamp(offset_ns, low, high);
}

test skew_clamp {
    const ms = std.time.ns_per_ms;
    // Opposite ways at once: within the maximum of each other.
    try std.testing.expectEqual(@as(?i64, -125 * ms), skew_clamp(-300 * ms, 400 * ms, &.{275 * ms}, 0));
    // A skew of +350 ms gone (its clock back), still in the hybrid clocks it reached: a node
    // skewed back 300 ms now meets it 650 ms apart; kept within 400 ms of it (run 1996).
    try std.testing.expectEqual(@as(?i64, -50 * ms), skew_clamp(-300 * ms, 400 * ms, &.{}, 350 * ms));
    // Remembered long enough ago, as the clocks went on: no bound left from it.
    try std.testing.expectEqual(@as(?i64, -300 * ms), skew_clamp(-300 * ms, 400 * ms, &.{}, -2000 * ms));
    // Forward skews are bounded by the others alone.
    try std.testing.expectEqual(@as(?i64, 400 * ms), skew_clamp(400 * ms, 400 * ms, &.{}, 350 * ms));
    // Nothing fits: another node's skew past this one's largest.
    try std.testing.expectEqual(@as(?i64, null), skew_clamp(0, 10 * ms, &.{ -30 * ms, 30 * ms }, 0));
}

/// The highest any node's CLOCK_REALTIME has read, as the monotonic clock then plus its offset:
/// raised as a skew leaves a clock (its end, a strobe's flip back), which hybrid clocks keep.
var clock_high_ns: i64 = 0;

fn monotonic_signed_ns() i64 {
    return @intCast(monotonic_ns());
}

/// A clock leaves `offset_ns`: what it read stays the highest if it was.
fn clock_leaves(offset_ns: i64) void {
    clock_high_ns = @max(clock_high_ns, monotonic_signed_ns() + offset_ns);
}

fn skew_begin(system: *const schema.System, fault: *NodeFault) !void {
    const offset_ns = skew_clamped(system, &fault.applied) orelse return error.SkewApart;
    fault.applied.forward = offset_ns >= 0;
    fault.applied.skip_ns = @abs(offset_ns);
    try nodes.clock_offset(fault.applied.node, offset_ns);
    if (fault.applied.strobe_ns > 0) fault.flip_ns = monotonic_ns() + fault.applied.strobe_ns;
}

/// The scenario's cap on nodes down at once (schema.Scenario.nodes_down_max; 0: none).
var nodes_down_max: u32 = 0;

/// The scenario's quorum (schema.Scenario.quorum): its nodes' indices; none, no cap.
var quorum_members: [schema.nodes_max]usize = undefined;
var quorum_count: usize = 0;

/// A link the quorum cannot count on: one clearly worse than the baseline (2 ms, 0.1% at most),
/// delaying this long or more, or losing this share (the scenario's quorum_link_delay_ms and
/// quorum_link_loss_ppm). A bound on latency must never hold a system to it over a degraded
/// majority (the quorum check, 2026-11-08: links held 1 s and losing 49% counted as linked broke
/// a 1 s answer in 16 of 6 timelines' moments).
var quorum_delay_ns_max: u64 = 50 * std.time.ns_per_ms;
var quorum_loss_ppm_max: u32 = nodes.Netem.ppm / 100;

/// How long a node whose fault ended is not counted (restarting, rejoining its cluster: the
/// scenario's quorum_recovery_ms), and until when each is not.
var quorum_recovery_ns: u64 = 15 * std.time.ns_per_s;
var quorum_recovering_until_ns: [schema.nodes_max]u64 = @splat(0);

/// The scenario's quorum and what it counts as a degraded link or a recovering node.
fn quorum_configure(system: *const schema.System, scenario: *const schema.Scenario) void {
    quorum_resolve(system, scenario.quorum);
    quorum_delay_ns_max = @as(u64, scenario.quorum_link_delay_ms) * std.time.ns_per_ms;
    quorum_loss_ppm_max = scenario.quorum_link_loss_ppm;
    quorum_recovery_ns = @as(u64, scenario.quorum_recovery_ms) * std.time.ns_per_ms;
}

fn node_slot_index(system: *const schema.System, name: []const u8) ?usize {
    for (system.nodes, 0..) |node, index| if (std.mem.eql(u8, node.name, name)) return index;
    return null;
}

fn quorum_resolve(system: *const schema.System, names: []const []const u8) void {
    quorum_count = 0;
    for (names) |name| {
        for (system.nodes, 0..) |node, index| {
            if (!std.mem.eql(u8, node.name, name) or quorum_count == quorum_members.len) continue;
            quorum_members[quorum_count] = index;
            quorum_count += 1;
        }
    }
}

/// Whether a fault of this kind acts on its node alone (its processes, its disk, its clock).
fn on_node_alone(kind: Kind) bool {
    return switch (kind) {
        .pause,
        .restart,
        .crash,
        .durable_crash,
        .sync_stall,
        .wipe,
        .stop,
        .disk,
        .throttle,
        .clock_skew,
        .process_pause,
        .thread_pause,
        .interleave,
        .syscall_error,
        .file_error,
        .pod_pause,
        .pod_isolate,
        .pod_degrade,
        .pod_partition,
        .process_kill,
        .signal,
        .pod_kill,
        => true,
        else => false,
    };
}

/// Whether the link between endpoints a and b is cut or too harsh to count on, by the active
/// network faults and `candidate` (one about to start).
fn quorum_link_broken(system: *const schema.System, a: usize, b: usize, candidate: ?*const Active) bool {
    var entries: [active_max + 1]*const Active = undefined;
    var count: usize = 0;
    for (network.active[0..network.count]) |*entry| {
        entries[count] = entry;
        count += 1;
    }
    if (candidate) |entry| {
        entries[count] = entry;
        count += 1;
    }
    for (entries[0..count]) |entry| {
        if (!entry.started or entry.releasing) continue;
        if (cuts_link(system, &entry.applied, a, b)) return true;
        for ([_][2]usize{ .{ a, b }, .{ b, a } }) |direction| {
            const netem = link_netem(system, entry, direction[0], direction[1]) orelse continue;
            if (netem.loss_effective_ppm() >= quorum_loss_ppm_max or netem.delay_ns >= quorum_delay_ns_max) return true;
        }
    }
    return false;
}

/// Whether, with `applied` started too, a majority of the quorum stays unfaulted, linked to each
/// other and reachable from the runner (schema.Scenario.quorum). True without a quorum.
fn quorum_kept(system: *const schema.System, applied: *const Applied) bool {
    if (quorum_count == 0) return true;
    switch (applied.kind) {
        .restore => return true,
        .outage, .swizzle, .clock_skip, .custom => return false, // Their reach is unknown before.
        else => {},
    }
    var healthy: [schema.nodes_max]usize = undefined;
    var healthy_count: usize = 0;
    for (quorum_members[0..quorum_count]) |index| {
        const name = system.nodes[index].name;
        if (node_busy(index)) continue;
        if (quorum_recovering_until_ns[index] > monotonic_ns()) continue;
        if (on_node_alone(applied.kind) and std.mem.eql(u8, applied.node, name)) continue;
        if (nodes.state_of(name) == .stopped) continue;
        healthy[healthy_count] = index;
        healthy_count += 1;
    }
    const candidate: ?Active = if (on_node_alone(applied.kind)) null else .{ .applied = applied.*, .end_ns = 0 };
    const needed = quorum_count / 2 + 1;
    if (healthy_count < needed) return false;
    return quorum_clique(system, healthy[0..healthy_count], needed, if (candidate) |*entry| entry else null);
}

test "a quorum is a majority linked pairwise, one of them reachable from the runner" {
    const resolved = struct {
        fn of(name: []const u8) schema.Resolved {
            return .{ .name = name, .address = "10.0.0.2", .disk = "vdb", .digest = "", .command = &.{"x"}, .env = &.{} };
        }
    };
    const members = [_]schema.Resolved{ resolved.of("a"), resolved.of("b"), resolved.of("c") };
    const system: schema.System = .{ .profile = "test", .nodes = &members, .scenarios = &.{} };
    const saved = network;
    defer network = saved;
    network = .{};
    const all = [_]usize{ 0, 1, 2 };
    const isolate = struct {
        fn of(name: []const u8) Active {
            return .{ .applied = .{ .kind = .isolate, .node = name, .duration_ns = 1 }, .end_ns = 0 };
        }
    };
    // Nothing faulted: kept.
    try std.testing.expect(quorum_clique(&system, &all, 2, null));
    // c isolated: a and b remain, linked and reachable.
    const c_cut = isolate.of("c");
    try std.testing.expect(quorum_clique(&system, &all, 2, &c_cut));
    // c isolated already, then b: no two linked.
    network.active[0] = c_cut;
    network.count = 1;
    const b_cut = isolate.of("b");
    try std.testing.expect(!quorum_clique(&system, &all, 2, &b_cut));
    // c isolated, then a partition between a and b: none linked.
    const ab: Active = .{ .applied = .{ .kind = .partition, .node = "a", .peer = "b", .duration_ns = 1 }, .end_ns = 0 };
    try std.testing.expect(!quorum_clique(&system, &all, 2, &ab));
    // A partition between a and the runner alone: b and c still linked and reachable.
    network.count = 0;
    const a_runner: Active = .{ .applied = .{ .kind = .partition, .node = "a", .peer = schema.runner_name, .duration_ns = 1 }, .end_ns = 0 };
    try std.testing.expect(quorum_clique(&system, &all, 2, &a_runner));
    // A degraded link between a and b losing half: not counted, a and c remain.
    var lossy: Active = .{ .applied = .{ .kind = .degrade, .node = "a", .peer = "b", .duration_ns = 1, .netem = .{ .delay_ns = 0, .loss_ppm = nodes.Netem.ppm / 2, .seed = 1 } }, .end_ns = 0 };
    try std.testing.expect(quorum_clique(&system, &all, 2, &lossy));
    network.active[0] = lossy;
    network.count = 1;
    const c_cut_too = isolate.of("c");
    try std.testing.expect(!quorum_clique(&system, &all, 2, &c_cut_too));
    // The same link barely degraded (the baseline's 2 ms): still linked.
    lossy.applied.netem = .{ .delay_ns = 2 * std.time.ns_per_ms, .seed = 1 };
    network.active[0] = lossy;
    try std.testing.expect(quorum_clique(&system, &all, 2, &c_cut_too));
    // Delayed 100 ms: broken by the default threshold (50 ms), linked under a scenario's 200 ms.
    lossy.applied.netem = .{ .delay_ns = 100 * std.time.ns_per_ms, .seed = 1 };
    network.active[0] = lossy;
    const saved_delay = quorum_delay_ns_max;
    defer quorum_delay_ns_max = saved_delay;
    quorum_configure(&system, &.{ .name = "s", .commands = &.{} });
    try std.testing.expect(!quorum_clique(&system, &all, 2, &c_cut_too));
    quorum_configure(&system, &.{ .name = "s", .commands = &.{}, .quorum_link_delay_ms = 200 });
    try std.testing.expect(quorum_clique(&system, &all, 2, &c_cut_too));
}

/// Whether `needed` of the healthy nodes are linked pairwise and one of them to the runner: a
/// clique of that size with a node the runner reaches in it (clique_reached).
fn quorum_clique(system: *const schema.System, healthy: []const usize, needed: usize, candidate: ?*const Active) bool {
    assert(healthy.len <= schema.nodes_max);
    var linked: [schema.nodes_max]u32 = @splat(0);
    var reached: u32 = 0;
    for (healthy, 0..) |a, i| {
        if (!quorum_link_broken(system, 0, a + 1, candidate)) reached |= @as(u32, 1) << @intCast(i);
        for (healthy[i + 1 ..], i + 1..) |b, j| {
            if (quorum_link_broken(system, a + 1, b + 1, candidate)) continue;
            linked[i] |= @as(u32, 1) << @intCast(j);
            linked[j] |= @as(u32, 1) << @intCast(i);
        }
    }
    return clique_reached(linked[0..healthy.len], needed, reached);
}

/// Whether the graph holds a clique of `needed` nodes or more with one of `reached` in it;
/// `linked[i]` is the bit set of node i's neighbours. Bron and Kerbosch's search with a pivot,
/// on a stack of its own (a clique's nodes deep at most). Its first form tried every subset in
/// turn: 2^15 at most then, 2^25 with schema.nodes_max now.
fn clique_reached(linked: []const u32, needed: usize, reached: u32) bool {
    comptime assert(schema.nodes_max <= 32);
    assert(linked.len <= schema.nodes_max);
    // A frame: its clique, the nodes linked to all of it still to try (open) and tried
    // (closed), and of the open ones those this frame still branches on (left), once chosen.
    const Frame = struct { clique: u32, open: u32, closed: u32, left: u32 = 0, chosen: bool = false };
    var stack: [schema.nodes_max + 1]Frame = undefined;
    const all: u32 = @intCast((@as(u64, 1) << @intCast(linked.len)) - 1);
    stack[0] = .{ .clique = 0, .open = all, .closed = 0 };
    var depth: usize = 1;
    while (depth > 0) {
        const frame = &stack[depth - 1];
        if (!frame.chosen) {
            if (@popCount(frame.clique) >= needed and frame.clique & reached != 0) return true;
            // Nothing through here grows to `needed` nodes, or holds a node reached.
            const short = @popCount(frame.clique) + @popCount(frame.open) < needed;
            if (short or (frame.clique | frame.open) & reached == 0) {
                depth -= 1;
                continue;
            }
            // The pivot: of the open and closed nodes, the one with most neighbours open. A
            // maximal clique from here holds it or an open node it is not linked to.
            var pivot_linked: u32 = 0;
            var most: ?u32 = null;
            var rest = frame.open | frame.closed;
            while (rest != 0) : (rest &= rest - 1) {
                const index = @ctz(rest);
                const count: u32 = @popCount(frame.open & linked[index]);
                if (most == null or count > most.?) {
                    most = count;
                    pivot_linked = linked[index];
                }
            }
            frame.left = frame.open & ~pivot_linked;
            frame.chosen = true;
        }
        if (frame.left == 0) {
            depth -= 1;
            continue;
        }
        const index = @ctz(frame.left);
        const node = @as(u32, 1) << @intCast(index);
        frame.left &= ~node;
        const next: Frame = .{ .clique = frame.clique | node, .open = frame.open & linked[index], .closed = frame.closed & linked[index] };
        frame.open &= ~node;
        frame.closed |= node;
        assert(depth < stack.len);
        stack[depth] = next;
        depth += 1;
    }
    return false;
}

/// clique_reached's first form, every subset in turn: what the search is checked against.
fn clique_reached_exhaustive(linked: []const u32, needed: usize, reached: u32) bool {
    const subsets: u32 = @as(u32, 1) << @intCast(linked.len);
    var subset: u32 = 0;
    next: while (subset < subsets) : (subset += 1) {
        if (@popCount(subset) < needed or subset & reached == 0) continue;
        for (linked, 0..) |neighbours, index| {
            const node = @as(u32, 1) << @intCast(index);
            if (subset & node != 0 and subset & ~node & ~neighbours != 0) continue :next;
        }
        return true;
    }
    return false;
}

test "a clique of the size needed with a node reached in it, among 25 nodes at once" {
    // Two groups linked pairwise, of 13 and of 12, one link between them.
    var linked: [25]u32 = @splat(0);
    for (0..25) |a| for (0..25) |b| {
        if (a != b and (a < 13) == (b < 13)) linked[a] |= @as(u32, 1) << @intCast(b);
    };
    linked[12] |= 1 << 13;
    linked[13] |= 1 << 12;
    const everyone: u32 = (1 << 25) - 1;
    try std.testing.expect(clique_reached(&linked, 13, 1 << 0));
    try std.testing.expect(!clique_reached(&linked, 14, everyone));
    // Thirteen are in the first group alone, and the runner reaches a node of the second.
    try std.testing.expect(!clique_reached(&linked, 13, 1 << 20));
    try std.testing.expect(clique_reached(&linked, 12, 1 << 20));
    try std.testing.expect(!clique_reached(&linked, 1, 0));
    // No link at all: a node alone is a clique of one.
    const apart: [25]u32 = @splat(0);
    try std.testing.expect(clique_reached(&apart, 1, 1 << 24));
    try std.testing.expect(!clique_reached(&apart, 2, everyone));
    try std.testing.expect(!clique_reached(&.{}, 1, 0));
    // Against every subset in turn, on random graphs of up to 12 nodes.
    var random_state: std.Random.DefaultPrng = .init(0x636c69717565);
    const random = random_state.random();
    for (0..2000) |_| {
        const count = random.uintLessThan(usize, 13);
        var graph: [12]u32 = @splat(0);
        const density = random.uintLessThan(u32, 101);
        for (0..count) |a| for (a + 1..count) |b| {
            if (random.uintLessThan(u32, 100) >= density) continue;
            graph[a] |= @as(u32, 1) << @intCast(b);
            graph[b] |= @as(u32, 1) << @intCast(a);
        };
        const some = random.int(u32) & ((@as(u32, 1) << @intCast(count)) - 1);
        const size = random.uintLessThan(usize, count + 2);
        try std.testing.expectEqual(
            clique_reached_exhaustive(graph[0..count], size, some),
            clique_reached(graph[0..count], size, some),
        );
    }
}

/// Whether a fault takes its node down (its processes gone a while).
/// Until when each node, back from a fault that took it down, is still counted down by the
/// scenario's nodes_down_max (its quorum_recovery_ms): a restarted replica of a system replicating
/// in memory has lost its state until it caught up, and another's restart then is a correlated
/// failure (hunt run 1986: two and three replicas of such a system restarted within a second,
/// each down for milliseconds, acknowledged messages lost in 4 timelines).
var down_recovering_until_ns: [schema.nodes_max]u64 = @splat(0);

/// The other nodes down at `now_ns`: under a fault that took them down (`active`) or back from one
/// less than their recovery ago. The node the next fault aims at is not counted: a second fault
/// on it still leaves one node down.
fn nodes_down(active: []const bool, recovering_until_ns: []const u64, aimed: usize, now_ns: u64) u32 {
    assert(active.len == recovering_until_ns.len);
    var down: u32 = 0;
    for (active, recovering_until_ns, 0..) |faulted, until_ns, index| {
        if (index == aimed) continue;
        down += @intFromBool(faulted or until_ns > now_ns);
    }
    return down;
}

test nodes_down {
    // i2 restarted, back 0.2 s ago with 15 s to recover; i3 never faulted: i1's restart counts
    // one down already (run 1986: i2 restarted at 32.43 s, i1 at 32.66 s).
    const recovery_ns = 15 * std.time.ns_per_s;
    const now_ns = 32_660 * std.time.ns_per_ms;
    const until = [_]u64{ 0, 32_430 * std.time.ns_per_ms + recovery_ns, 0 };
    try std.testing.expectEqual(1, nodes_down(&.{ false, false, false }, &until, 0, now_ns));
    // Its recovery over: none.
    try std.testing.expectEqual(0, nodes_down(&.{ false, false, false }, &until, 0, now_ns + recovery_ns));
    // Under a fault now, i3: two, the aimed node itself (i2, recovering) not counted.
    try std.testing.expectEqual(1, nodes_down(&.{ false, false, true }, &until, 1, now_ns));
    try std.testing.expectEqual(2, nodes_down(&.{ false, false, true }, &until, 0, now_ns));
}

fn takes_down(kind: Kind) bool {
    return switch (kind) {
        .restart, .crash, .stop, .wipe, .durable_crash, .outage => true,
        else => false,
    };
}

/// A fault of one node begins, unless the node is turned away (below): whether it began. The
/// only place its admission is drawn (node_admits draws the regime's overlap at each call).
fn node_start(system: *const schema.System, applied: *const Applied) bool {
    const layer = layer_of(applied.kind);
    const slot = node_slot(system, applied.node, layer) orelse return false;
    // Busy in its layer, or in the other without the regime's overlap: skipped, not logged
    // (drawn faults turned away are many); a scripted one is logged: the script said it ran.
    if (!node_admits(node_slot_index(system, applied.node).?, layer)) {
        if (following_script) sdk.event("fault_skipped", .{ .kind = @tagName(applied.kind), .node = applied.node, .err = "LayerBusy" });
        return false;
    }
    // Crash points and aftershocks start here, not through apply.
    if (!quorum_kept(system, applied)) {
        sdk.event("fault_skipped", .{ .kind = @tagName(applied.kind), .node = applied.node, .err = "QuorumKept" });
        return false;
    }
    if (nodes_down_max > 0 and takes_down(applied.kind)) {
        var active: [schema.nodes_max]bool = @splat(false);
        for (nodes_faulted[0..system.nodes.len], 0..) |faulted, index| {
            if (faulted[@backingInt(Layer.process)]) |fault| active[index] = takes_down(fault.applied.kind);
        }
        const down = nodes_down(
            active[0..system.nodes.len],
            down_recovering_until_ns[0..system.nodes.len],
            node_slot_index(system, applied.node).?,
            monotonic_ns(),
        );
        if (down >= nodes_down_max) {
            sdk.event("fault_skipped", .{ .node = applied.node, .err = "NodesDownMax" });
            return false;
        }
    }
    // Not running: a spare not started yet, a member a driver took out, or a node that exited on
    // its own. A restart would start it behind the scenario's back.
    if (nodes.state_of(applied.node) == .stopped) {
        sdk.event("fault_skipped", .{ .node = applied.node, .err = "NotRunning" });
        return false;
    }
    var fault = NodeFault{ .applied = applied.*, .end_ns = monotonic_ns() + applied.duration_ns };
    const started: anyerror!void = switch (applied.kind) {
        .pod_pause, .pod_isolate, .pod_degrade => pod_begin(&fault),
        .pod_partition => pod_partition_begin(&fault),
        .pause => nodes.freeze(applied.node, .frozen),
        .restart => nodes.kill(applied.node),
        .crash => nodes.crash(applied.node, partial_for(system, applied.node, applied)),
        .durable_crash, .sync_stall => durable_arm(applied),
        .wipe => wipe_begin(system, applied.node),
        .stop => stop_begin(applied.node, &fault),
        .disk => disk_begin(system, applied),
        .throttle => nodes.cpu_limit(applied.node, applied.cpu_percent),
        .clock_skew => skew_begin(system, &fault),
        .process_pause => process_stop(applied, &fault),
        .thread_pause => thread_stop(applied, &fault),
        .interleave => interleave_arm(applied.node, applied.one_in),
        .syscall_error => syscall_error_begin(applied),
        .file_error => file_error_arm(applied.node, applied),
        else => unreachable,
    };
    started catch |err| {
        // Nothing to fault (no pod to pick right now): not a failure.
        const skipped = err == error.NoPods or err == error.PodsSpared or err == error.OnePod or err == error.ThreadPending or
            err == error.SkewApart or err == error.SyscallErrorElsewhere;
        sdk.event(if (skipped) "fault_skipped" else "fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return false;
    };
    slot.* = fault;
    switch (applied.kind) {
        .restart, .crash, .wipe, .stop => unlist_maybe(system, applied.node),
        else => {},
    }
    // A pod fault's event names its pod (kept in the slot, which the event reads).
    const node_fault = &slot.*.?;
    if (node_fault.command_size > 0) node_fault.applied.process = node_fault.command[0..node_fault.command_size];
    if (node_fault.pod.path_size > 0) node_fault.applied.pod = node_fault.pod.name();
    if (node_fault.peer.path_size > 0) node_fault.applied.peer_pod = node_fault.peer.name();
    sdk.event("fault", node_fault.applied);
    return true;
}

fn node_end(system: *const schema.System, slot: *?NodeFault) void {
    const fault = slot.* orelse return;
    slot.* = null;
    const name = fault.applied.node;
    // Back but not serving yet (restarting, rejoining): the quorum does not count it for a while.
    if (node_slot_index(system, name)) |index| {
        quorum_recovering_until_ns[index] = monotonic_ns() + quorum_recovery_ns;
        if (takes_down(fault.applied.kind)) down_recovering_until_ns[index] = monotonic_ns() + quorum_recovery_ns;
    }
    doing_set("end", fault.applied.kind, name);
    defer doing_set("wait", null, "");
    switch (fault.applied.kind) {
        .pause => nodes.freeze(name, .thawed) catch {},
        .sync_stall => durable_disarm(name),
        .durable_crash => {
            const index = node_index_of(system, name) orelse return;
            durable_lock_take();
            durable_active[index] = false;
            durable_disarm(name);
            const crashed = durable_crashed[index];
            durable_crashed[index] = false;
            durable_lock.unlock();
            // Crashed at a durability point meanwhile: it starts again, as after a crash.
            if (crashed) {
                if (system.node(name)) |node| readdress_maybe(system, node);
                node_start_again(system, name);
                if (!fault.applied.injected) aftershock_draw(system, name);
            }
        },
        .restart, .crash, .outage, .wipe, .stop => {
            // Healed early (a quiet stretch, a restore, the stop): a stop still in its grace
            // finishes it first, the SIGTERM sent being past undoing. Killed at once, the graceful
            // stop was a crash mid-shutdown, a harsher fault than drawn (run 962's n3, killed
            // mid-drain 1 s into its 3 s grace, 0.3 s after an acknowledged write).
            // The process the stop signalled, not the node's cgroup: a driver that started the
            // node again meanwhile has its own incarnation there, which the cgroup's emptiness
            // waited on and its kill took (nodes.stop_end).
            if (fault.grace_end_ns) |grace_end_ns| {
                while (nodes.stopping(name) != null and monotonic_ns() < grace_end_ns) {
                    nodes.sleep_ns(stop_exit_poll_ns);
                }
                nodes.stop_end(name) catch {};
            }
            // Antithesis's restarted nodes may rejoin with a new address: a decision.
            if (system.node(name)) |node| readdress_maybe(system, node);
            node_start_again(system, name);
            if (!fault.applied.injected) aftershock_draw(system, name);
        },
        .disk => {
            if (node_index_of(system, name)) |index| disk_healed_ns[index] = monotonic_ns();
            const again = nodes.disk_heal(name) catch |err| {
                sdk.event("fault_heal_failed", .{ .node = name, .err = @errorName(err) });
                return;
            };
            if (again) node_start_again(system, name);
        },
        .throttle => nodes.cpu_limit(name, null) catch {},
        // A node started again meanwhile has a fresh namespace: this sets what it has already.
        .clock_skew => {
            if (fault.skewed) clock_leaves(skew_ns(&fault.applied));
            nodes.clock_offset(name, 0) catch {};
        },
        .process_pause => _ = linux.kill(fault.pid, .CONT),
        .thread_pause => thread_release(fault.pid, fault.stopped),
        .interleave => interleave_arm(name, 0) catch {},
        .syscall_error => syscall_error_end(name),
        .file_error => file_error_arm(name, null) catch {},
        // The pod may be gone (killed, rescheduled), its cgroup and namespace with it: said.
        .pod_pause => fault.pod.write("cgroup.freeze", "0") catch |err| if (fault.pod.exists()) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .err = @errorName(err) });
        },
        // A pod gone meanwhile took its namespace, and what was set there, with it.
        .pod_isolate, .pod_degrade => nodes.pod_netem(fault.pid, null) catch |err| if (err != error.NoSuchNamespace) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .err = @errorName(err) });
        },
        .pod_partition => pod_partition_end(&fault),
        else => {},
    }
}
// Pod faults (Faults.pods) --------------------------------------------------------------------
// A Kubernetes node's pods are cgroups of its own (kubepods/<qos>/pod<uid>, or kubepods/pod<uid>
// for guaranteed ones): one is picked in name order by the fault's process_index.

const pods_max = 256;
const pod_containers_max = 16;

const Pod = struct {
    path_buffer: [nodes.path_size_max]u8 = undefined,
    path_size: usize = 0,
    name_buffer: [64]u8 = undefined,
    name_size: usize = 0,

    fn path(pod: *const Pod) []const u8 {
        return pod.path_buffer[0..pod.path_size];
    }

    /// Its name: a process's HOSTNAME (the pod's, as Kubernetes sets it), else its cgroup's.
    fn name(pod: *const Pod) []const u8 {
        if (pod.name_size > 0) return pod.name_buffer[0..pod.name_size];
        return std.fs.path.basename(pod.path());
    }

    /// Whether its cgroup is still there (a deleted pod's goes).
    fn exists(pod: *const Pod) bool {
        var buffer: [nodes.path_size_max]u8 = undefined;
        const directory = nodes.print_z(&buffer, "{s}", .{pod.path()}) catch return false;
        return linux.errno(linux.access(directory, linux.F_OK)) == .SUCCESS;
    }

    fn write(pod: *const Pod, file: []const u8, content: []const u8) !void {
        var buffer: [nodes.path_size_max + 32]u8 = undefined;
        try nodes.file_write(try nodes.print_z(&buffer, "{s}/{s}", .{ pod.path(), file }), content);
    }
};

const Directories = struct {
    paths: [pods_max][nodes.path_size_max]u8 = undefined,
    sizes: [pods_max]usize = undefined,
    count: usize = 0,

    fn get(directories: *const Directories, index: usize) []const u8 {
        return directories.paths[index][0..directories.sizes[index]];
    }

    /// The subdirectories of `parent` whose names start with `prefix`.
    fn add(directories: *Directories, parent: [:0]const u8, prefix: []const u8) void {
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
        const opened = linux.open(parent, flags, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        var entries: [8192]u8 align(8) = undefined;
        while (true) {
            const size = linux.getdents64(fd, &entries, entries.len);
            if (linux.errno(size) != .SUCCESS or size == 0) return;
            var at: usize = 0;
            while (at < size) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                at += entry.reclen;
                if (entry.type != linux.DT.DIR) continue;
                const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (entry_name[0] == '.' or !std.mem.startsWith(u8, entry_name, prefix)) continue;
                if (directories.count == pods_max) return;
                const slot = &directories.paths[directories.count];
                const full = std.fmt.bufPrint(slot, "{s}/{s}", .{ parent, entry_name }) catch continue;
                directories.sizes[directories.count] = full.len;
                directories.count += 1;
            }
        }
    }

    fn before(directories: *const Directories, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, directories.get(a), directories.get(b));
    }
};

/// The node's pod picked by `index` (their cgroups in name order: the same pod on a replay),
/// and a process of it (the first with a HOSTNAME naming the pod). Spared, the cluster's own
/// pods (kube-system: CoreDNS, the storage provisioner; node faults reach them) and, with
/// spare_drivers, the pods whose containers hold test templates (the drivers run there,
/// through kubectl exec: a kill would fail them, not the system).
fn pod_pick(node: []const u8, index: u32, pod: *Pod, spare_drivers: bool) !linux.pid_t {
    var pods: Directories = .{};
    var parent_buffer: [nodes.path_size_max]u8 = undefined;
    for ([_][]const u8{ "", "/burstable", "/besteffort" }) |class| {
        const format = nodes.cgroup_root ++ "/{s}/kubepods{s}";
        pods.add(try nodes.print_z(&parent_buffer, format, .{ node, class }), "pod");
    }
    if (pods.count == 0) return error.NoPods;
    var order: [pods_max]usize = undefined;
    for (order[0..pods.count], 0..) |*slot, at| slot.* = at;
    std.sort.insertion(usize, order[0..pods.count], &pods, Directories.before);
    var candidates: usize = 0;
    for (order[0..pods.count]) |at| {
        if (pod_in_namespace(node, pods.get(at), "kube-system")) continue;
        if (spare_drivers and pod_has_templates(pods.get(at))) continue;
        order[candidates] = at;
        candidates += 1;
    }
    // Pods, none to fault: never the node's own processes instead (fault_process).
    if (candidates == 0) return error.PodsSpared;
    // The drawn pod, or the next in order with a process (a pod being deleted, or between its
    // containers' restarts, keeps a cgroup with none for a while).
    for (0..candidates) |attempt| {
        const picked = pods.get(order[(index + attempt) % candidates]);
        @memcpy(pod.path_buffer[0..picked.len], picked);
        pod.path_size = picked.len;
        pod.name_size = 0;
        if (try pod_process(pod)) |pid| {
            if (pod.name_size == 0) if (pod_name_logged(node, std.fs.path.basename(picked), &pod.name_buffer)) |logged| {
                pod.name_size = logged.len;
            };
            if (excluded(pod.name())) continue;
            return pid;
        }
    }
    return error.PodsSpared;
}

/// A process of the pod (the first with a HOSTNAME naming the pod, which it notes), if any.
fn pod_process(pod: *Pod) !?linux.pid_t {
    var parent_buffer: [nodes.path_size_max]u8 = undefined;
    var containers: Directories = .{};
    containers.add(try nodes.print_z(&parent_buffer, "{s}", .{pod.path()}), "");
    var pid: ?linux.pid_t = null;
    for (0..@min(containers.count, pod_containers_max)) |at| {
        var procs_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const procs = try nodes.print_z(&procs_buffer, "{s}/cgroup.procs", .{containers.get(at)});
        var text_buffer: [64]u8 = undefined;
        const text = nodes.read_small(procs, &text_buffer) orelse continue;
        const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " ");
        const first = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        if (pid == null) pid = first;
        if (hostname_of(first, &pod.name_buffer)) |host| {
            pod.name_size = host.len;
            return first;
        }
    }
    return pid;
}

/// Whether the pod is in `namespace`: its service account's projected volume names it, in the
/// node's /var/lib/kubelet/pods/<uid> (a tmpfs of the node's mount namespace: seen through its
/// main process, K3s).
fn pod_in_namespace(node: []const u8, path: []const u8, namespace: []const u8) bool {
    const directory = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, directory, "pod")) return false;
    const uid = directory["pod".len..];
    const main_pid = nodes.pid_recorded(node) orelse return false;
    var projected: Directories = .{};
    var buffer: [nodes.path_size_max]u8 = undefined;
    const format = "/proc/{d}/root/var/lib/kubelet/pods/{s}/volumes/kubernetes.io~projected";
    projected.add(nodes.print_z(&buffer, format, .{ main_pid, uid }) catch return false, "kube-api-access");
    for (0..projected.count) |at| {
        var file_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const file = nodes.print_z(&file_buffer, "{s}/namespace", .{projected.get(at)}) catch continue;
        var text_buffer: [256]u8 = undefined;
        const text = nodes.read_small(file, &text_buffer) orelse continue;
        return std.mem.eql(u8, std.mem.trim(u8, text, " \n"), namespace);
    }
    return false;
}

/// Whether one of the pod's containers holds Antithesis test templates.
fn pod_has_templates(path: []const u8) bool {
    var containers: Directories = .{};
    var buffer: [nodes.path_size_max]u8 = undefined;
    containers.add(nodes.print_z(&buffer, "{s}", .{path}) catch return false, "");
    for (0..@min(containers.count, pod_containers_max)) |at| {
        var procs_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const procs = nodes.print_z(&procs_buffer, "{s}/cgroup.procs", .{containers.get(at)}) catch continue;
        var text_buffer: [64]u8 = undefined;
        const text = nodes.read_small(procs, &text_buffer) orelse continue;
        const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " ");
        const pid = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        var templates_buffer: [64]u8 = undefined;
        const templates = std.fmt.bufPrintSentinel(&templates_buffer, "/proc/{d}/root/opt/antithesis/test/v1", .{pid}, 0) catch continue;
        if (linux.errno(linux.access(templates, linux.F_OK)) == .SUCCESS) return true;
    }
    return false;
}

/// A pod's name from kubelet's log directory for it (/var/log/pods/<namespace>_<name>_<uid>, made
/// as the pod is synced, before its containers), seen through the node's main process: where no
/// process of the pod names it (its sandbox's first, between its containers' restarts). Unnamed,
/// a pod went by its cgroup's pod<uid>, which no exclusion pattern matches (run 2089: 36 of
/// them, CloudNativePG's paradedb-1 made again after a kill among them; an e2e kubernetes run
/// 6 of its 15 pod faults).
fn pod_name_logged(node: []const u8, cgroup: []const u8, buffer: *[64]u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, cgroup, "pod")) return null;
    const uid = cgroup["pod".len..];
    const main_pid = nodes.pid_recorded(node) orelse return null;
    var path_buffer: [nodes.path_size_max]u8 = undefined;
    const path = nodes.print_z(&path_buffer, "/proc/{d}/root/var/log/pods", .{main_pid}) catch return null;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(fd, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return null;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const pod_name = logged_pod_name(name, uid) orelse continue;
            if (pod_name.len > buffer.len) return null;
            @memcpy(buffer[0..pod_name.len], pod_name);
            return buffer[0..pod_name.len];
        }
    }
}

/// The pod's name in a kubelet log directory's name, <namespace>_<name>_<uid> (neither a
/// namespace nor a pod name holds an underscore), if it is the pod's whose uid is `uid`.
fn logged_pod_name(directory: []const u8, uid: []const u8) ?[]const u8 {
    if (uid.len == 0 or directory.len <= uid.len + 1) return null;
    if (!std.mem.endsWith(u8, directory, uid)) return null;
    const rest = directory[0 .. directory.len - uid.len];
    if (rest[rest.len - 1] != '_') return null;
    const namespaced = rest[0 .. rest.len - 1];
    const separator = std.mem.indexOfScalar(u8, namespaced, '_') orelse return null;
    const name = namespaced[separator + 1 ..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '_') != null) return null;
    return name;
}

test logged_pod_name {
    const uid = "25cf8475-769e-4799-b9d6-7f3c529fbdcf";
    try std.testing.expectEqualStrings("paradedb-1", logged_pod_name("default_paradedb-1_" ++ uid, uid).?);
    try std.testing.expectEqualStrings("cnpg-cloudnative-pg-5bbd99d7d7-v5zx4", logged_pod_name("cnpg-system_cnpg-cloudnative-pg-5bbd99d7d7-v5zx4_" ++ uid, uid).?);
    try std.testing.expect(logged_pod_name("default_paradedb-1_17e60db2-673e-4815-aa60-df28a91eed28", uid) == null);
    try std.testing.expect(logged_pod_name("paradedb-1_" ++ uid, uid) == null); // No namespace.
    try std.testing.expect(logged_pod_name(uid, uid) == null);
}

/// A process's HOSTNAME (from its environment), into `buffer`.
fn hostname_of(pid: linux.pid_t, buffer: *[64]u8) ?[]const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0) catch
        return null;
    var environment: [8192]u8 = undefined;
    const text = nodes.read_small(path, &environment) orelse return null;
    var entries = std.mem.splitScalar(u8, text, 0);
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "HOSTNAME=")) continue;
        const value = entry["HOSTNAME=".len..];
        if (value.len == 0 or value.len > buffer.len) return null;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    return null;
}

/// A pod fault with a duration begins: the pod frozen, or its network cut off or degraded.
fn pod_begin(fault: *NodeFault) !void {
    const applied = &fault.applied;
    fault.pid = try pod_pick(applied.node, applied.process_index, &fault.pod, false);
    switch (applied.kind) {
        .pod_pause => try fault.pod.write("cgroup.freeze", "1"),
        .pod_isolate => try nodes.pod_netem(fault.pid, .{
            .delay_ns = 0,
            .loss_ppm = nodes.Netem.ppm,
            .seed = applied.duration_ns,
        }),
        .pod_degrade => try nodes.pod_netem(fault.pid, applied.netem.?),
        else => unreachable,
    }
}

/// A partition between two pods begins: each drops what it sends to the other (a blackhole route
/// to the other's address, in its own network namespace). The second pod is picked by the
/// fault's thread_index, the next one when that is the first.
fn pod_partition_begin(fault: *NodeFault) !void {
    const applied = &fault.applied;
    fault.pid = try pod_pick(applied.node, applied.process_index, &fault.pod, false);
    fault.peer_pid = try pod_pick(applied.node, applied.thread_index, &fault.peer, false);
    if (std.mem.eql(u8, fault.pod.path(), fault.peer.path())) {
        fault.peer_pid = try pod_pick(applied.node, applied.thread_index +% 1, &fault.peer, false);
        if (std.mem.eql(u8, fault.pod.path(), fault.peer.path())) return error.OnePod;
    }
    fault.addresses[0] = try pod_address(applied.node, &fault.pod);
    fault.addresses[1] = try pod_address(applied.node, &fault.peer);
    try nodes.pod_blackhole(fault.pid, fault.addresses[1], true);
    nodes.pod_blackhole(fault.peer_pid, fault.addresses[0], true) catch |err| {
        nodes.pod_blackhole(fault.pid, fault.addresses[1], false) catch {};
        return err;
    };
}

fn pod_partition_end(fault: *const NodeFault) void {
    const name = fault.applied.node;
    for ([_]linux.pid_t{ fault.pid, fault.peer_pid }, [_]nodes.Address{ fault.addresses[1], fault.addresses[0] }) |pid, address| {
        nodes.pod_blackhole(pid, address, false) catch |err| if (err != error.NoSuchNamespace) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .peer_pod = fault.peer.name(), .err = @errorName(err) });
        };
    }
}

/// A pod's address: the file of the cluster's address management (host-local, in the node's
/// /var/lib/cni/networks/cbr0, seen through its main process) that names its sandbox, one of
/// the pod's container cgroups.
fn pod_address(node: []const u8, pod: *const Pod) !nodes.Address {
    const main_pid = nodes.pid_recorded(node) orelse return error.NodeNotRunning;
    var directory_buffer: [nodes.path_size_max]u8 = undefined;
    const directory = try nodes.print_z(&directory_buffer, "/proc/{d}/root/var/lib/cni/networks/cbr0", .{main_pid});
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const opened = linux.open(directory, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return error.NoAddresses;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(fd, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return error.NoAddress;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const address = address_parse(name) orelse continue;
            var file_buffer: [nodes.path_size_max + 32]u8 = undefined;
            const file = nodes.print_z(&file_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            var text_buffer: [256]u8 = undefined;
            const text = nodes.read_small(file, &text_buffer) orelse continue;
            const sandbox = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " \r");
            if (sandbox.len == 0) continue;
            var sandbox_buffer: [nodes.path_size_max + 80]u8 = undefined;
            const cgroup = nodes.print_z(&sandbox_buffer, "{s}/{s}", .{ pod.path(), sandbox }) catch continue;
            if (linux.errno(linux.access(cgroup, linux.F_OK)) == .SUCCESS) return address;
        }
    }
}

/// An IPv4 address written as such ("10.42.0.5"), else null.
fn address_parse(text: []const u8) ?nodes.Address {
    var address: nodes.Address = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return address;
}

test address_parse {
    try std.testing.expectEqual(nodes.Address{ 10, 42, 0, 5 }, address_parse("10.42.0.5").?);
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("last_reserved_ip.0"));
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("lock"));
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("10.42.0"));
}

/// Every process of a pod killed at once (cgroup.kill): kubelet starts its containers again.
fn apply_pod_kill(applied: *const Applied) void {
    var pod: Pod = .{};
    _ = pod_pick(applied.node, applied.process_index, &pod, true) catch |err| {
        const skipped = err == error.NoPods or err == error.PodsSpared;
        sdk.event(if (skipped) "fault_skipped" else "fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    pod.write("cgroup.kill", "1") catch |err| {
        sdk.event("fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    var named = applied.*;
    named.pod = pod.name();
    sdk.event("fault", named);
}

/// A node down: half the time, with names following liveness, its name gone from the others'
/// hosts files until it starts again (nodes.start puts it back).
fn unlist_maybe(system: *const schema.System, name: []const u8) void {
    const node = system.node(name) orelse return;
    if (!node.faults.names_follow_liveness) return;
    if (sdk.random_below_named("fault.unlisted", 2) != 0) return;
    nodes.unlist(system, node) catch |err| {
        sdk.event("fault_unlist_failed", .{ .node = name, .err = @errorName(err) });
    };
}

fn readdress_maybe(system: *const schema.System, node: *const schema.Resolved) void {
    if (!node.faults.new_address) return;
    if (sdk.random_below_named("fault.new_address", 2) != 0) return;
    _ = nodes.readdress(system, node) catch |err| {
        sdk.event("fault_readdress_failed", .{ .node = node.name, .err = @errorName(err) });
    };
}

/// A disk fault begins; a node whose disk lost acknowledged writes is marked (disk_lied): its
/// filesystem's own metadata may be among them.
fn disk_begin(system: *const schema.System, applied: *const Applied) !void {
    const index = node_index_of(system, applied.node);
    if (applied.disk.?.failure == .lost_writes) {
        if (index) |at| disk_lied[at] = true;
    }
    try nodes.disk_fail(applied.node, applied.disk.?);
    if (index) |at| disk_watch[at] = true;
}

/// Nodes whose disk failed in their current start, watched for an end of their own after the
/// heal (nodes.ended_after_disk_heal), and when that end was first seen (0: not seen).
var disk_watch: [schema.nodes_max]bool = @splat(false);
var disk_ended_ns: [schema.nodes_max]u64 = @splat(0);
/// When each node's last disk fault healed (faults stopping wait for fail-stops under way).
var disk_healed_ns: [schema.nodes_max]u64 = @splat(0);
/// An ended node starts again this long after its end was first seen: det-init judges the exit
/// first (its known disk exits read the flag a start removes, looking up to 200 ms for its last
/// lines).
const disk_ended_wait_ns = 1 * std.time.ns_per_s;
/// How often watched nodes are looked at.
const disk_watch_poll_ns = 250 * std.time.ns_per_ms;
/// How long faults stopping wait for a node whose disk healed to end of itself: Kafka's
/// shutdown on a failed log directory took 5 s (run 1804).
const disk_settle_ns = 10 * std.time.ns_per_s;

fn disk_watching() bool {
    for (disk_watch) |watched| {
        if (watched) return true;
    }
    return false;
}

/// Watched nodes that ended of themselves after their disk healed start again.
fn disk_watch_expire(system: *const schema.System, now_ns: u64) void {
    for (system.nodes, 0..) |node, index| {
        if (!disk_watch[index]) continue;
        // A fault of its processes under way ends it its own way.
        if (nodes_faulted[index][@backingInt(Layer.process)] != null) continue;
        if (!nodes.ended_after_disk_heal(node.name)) {
            disk_ended_ns[index] = 0;
            // Started again since (a start removes the flag), or stopped: not watched anymore.
            if (!nodes.disk_failed_this_start(node.name) or nodes.pid_recorded(node.name) == null) {
                disk_watch[index] = false;
            }
            continue;
        }
        if (disk_ended_ns[index] == 0) {
            disk_ended_ns[index] = now_ns;
            continue;
        }
        if (now_ns - disk_ended_ns[index] < disk_ended_wait_ns) continue;
        disk_ended_ns[index] = 0;
        disk_watch[index] = false;
        sdk.event("node_disk_ended", .{ .node = node.name });
        nodes.disk_remount(node.name) catch |err| {
            sdk.event("fault_heal_failed", .{ .node = node.name, .err = @errorName(err) });
            continue;
        };
        node_start_again(system, node.name);
    }
}

/// As faults stop: a node whose disk healed in the last disk_settle_ns and still runs may be
/// ending of itself (a fail-stop under way): waited for, and started again if it ends.
fn disk_settle(system: *const schema.System) void {
    var deadline_ns: u64 = 0;
    for (system.nodes, 0..) |_, index| {
        if (disk_watch[index]) deadline_ns = @max(deadline_ns, disk_healed_ns[index] + disk_settle_ns + disk_ended_wait_ns);
    }
    while (disk_watching()) {
        const now_ns = monotonic_ns();
        disk_watch_expire(system, now_ns);
        if (now_ns >= deadline_ns) return;
        nodes.sleep_ns(disk_watch_poll_ns);
    }
}

/// A node wiped starts from a fresh filesystem: whatever its disk lost before is gone with it.
fn wipe_begin(system: *const schema.System, name: []const u8) !void {
    if (node_index_of(system, name)) |index| disk_lied[index] = false;
    return nodes.wipe(name);
}

/// Nodes whose disk lost acknowledged writes in this timeline: ext4's own metadata writes among
/// them, a later mount can find the filesystem broken ("iget: checksum invalid": the RustFS
/// disk hunt run 1435, timeline 55, r2 never started again, "Mkdir"). A drive that lies breaks
/// the host's filesystem too, and the guest has no fsck to repair it at the next boot.
var disk_lied: [schema.nodes_max]bool = @splat(false);

fn node_start_again(system: *const schema.System, name: []const u8) void {
    const node = system.node(name) orelse return;
    // Its own arena, gone with the start: the run-long one kept every restart's arguments,
    // environment and files read (1.16 GB after 1125 restarts: read_file).
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    doing_set("start again", null, name);
    // Waiting for the node to be ready (60 s at most: nodes.ready_wait) is not a stall: a
    // PostgreSQL recovering after a power loss took over 30 s in 95 timelines of run 43 (srv3),
    // each one failing the property.
    busy_end();
    defer busy_begin();
    // determinismo's own: a start that fails leaves the node down for good, which the system's
    // properties then take the blame for (ZooKeeper's set, run 711 timeline 45: three servers'
    // starts failed, "WriteFailed", and none served for the rest of the run).
    nodes.start(arena, system, node) catch |err| {
        // A start that fails on a disk that lost writes is that disk's doing, not determinismo's:
        // said, and the node left down as a dead drive leaves it (its system's properties judge
        // the rest). Started already is a start: a driver's spare found it down too.
        const lied = if (node_index_of(system, name)) |index| disk_lied[index] else false;
        if (lied and err != error.AlreadyRunning) {
            sdk.event("node_disk_broken", .{ .node = name, .err = @errorName(err) });
            return;
        }
        sdk.assert_computed(.always, err == error.AlreadyRunning, restart_property, .{ .node = name, .err = @errorName(err) });
        return;
    };
    sdk.assert_computed(.always, true, restart_property, .{ .node = name });
    network_node_new(system, name); // Its links are new.
}

const restart_property = "a faulted node starts again";

fn node_expire(system: *const schema.System, now_ns: u64) void {
    threads_release_pending(0);
    for (&nodes_faulted) |*slots| for (slots) |*slot| {
        const fault = &(slot.* orelse continue);
        if (fault.grace_end_ns) |grace_end_ns| if (grace_end_ns <= now_ns) {
            nodes.stop_end(fault.applied.node) catch {};
            slot.*.?.grace_end_ns = null;
        };
        if (fault.flip_ns) |flip_ns| if (flip_ns <= now_ns and fault.end_ns > now_ns) {
            const offset_ns = skew_ns(&fault.applied);
            // Back to its skew only within the maximum of what the clocks remember
            // (skew_clamped): else it stays at 0 until its next flip.
            const max_ns: i64 = if (system.node(fault.applied.node)) |node|
                @as(i64, @max(10, node.faults.clock_skew_ms_max)) * std.time.ns_per_ms
            else
                std.math.maxInt(i32);
            const fits = fault.applied.injected or offset_ns >= clock_high_ns - monotonic_signed_ns() - max_ns;
            const skewed = !fault.skewed and fits;
            if (fault.skewed) clock_leaves(offset_ns);
            nodes.clock_offset(fault.applied.node, if (skewed) offset_ns else 0) catch {};
            slot.*.?.skewed = skewed;
            slot.*.?.flip_ns = now_ns + fault.applied.strobe_ns;
        };
        if (fault.end_ns <= now_ns) node_end(system, slot);
    };
    aftershock_expire(system, now_ns);
    disk_watch_expire(system, now_ns);
}

/// Power losses again soon after a faulted node starts again (`why: aftershock`): what a start
/// writes and leaves unsynced (a record, a cookie, a file renamed over another) is lost before
/// the host writes it back, a moment random faults reach rarely (a temporary directories' record,
/// hunt run 1506: once in about 30 runs; a cookie, run 1436; a cluster's node table). One start in four, 200 ms to 12.8 s after it (log-uniform: within a host's 30 s
/// writeback window); named draws (`fault.aftershock`, `fault.aftershock_log2`,
/// `fault.aftershock_ms`): strategies steer them, replays repeat them. Only where the swarm keeps
/// the node's power losses (`crash`), after drawn faults (a scenario's own are deliberate), never
/// in a script.
var aftershock_ns: [schema.nodes_max]u64 = @splat(0);
/// The faults the swarm keeps now (swarm_select's, each regime).
var faults_active: []const Fault = &.{};

fn aftershock_draw(system: *const schema.System, name: []const u8) void {
    if (stopping.load(.acquire)) return;
    const index = node_index_of(system, name) orelse return;
    _ = crash_fault_of(name) orelse return;
    if (sdk.random_below_named("fault.aftershock", 4) != 0) return;
    aftershock_arm(index, name, "start");
}

/// Asked for at a moment a power loss would test (persist_trace: a node renamed a file over
/// unsynced data): one time in two (`fault.aftershock_asked`),
/// unless one is armed for the node already.
fn aftershock_asked(system: *const schema.System, name: []const u8) void {
    if (stopping.load(.acquire)) return;
    const index = node_index_of(system, name) orelse return;
    if (aftershock_ns[index] != 0) return;
    _ = crash_fault_of(name) orelse return;
    if (sdk.random_below_named("fault.aftershock_asked", 2) != 0) return;
    aftershock_arm(index, name, "asked");
}

/// 200 ms to 12.8 s from now, log-uniform: within a host's 30 s writeback window. Said
/// (`aftershock_armed`, by its cause: a node's start, or asked by persist_trace): a drawn power
/// loss coming first takes the same unsynced data and expires it, so an armed one need not fire
/// (the e2e check counted fired ones after renames and met none where drawn power losses came
/// every second or two).
fn aftershock_arm(index: usize, name: []const u8, cause: []const u8) void {
    const base_ms = @as(u64, 200) << @intCast(sdk.random_below_named("fault.aftershock_log2", 7));
    const ms = base_ms + sdk.random_below_named("fault.aftershock_ms", base_ms);
    aftershock_ns[index] = monotonic_ns() + ms * std.time.ns_per_ms;
    sdk.event("aftershock_armed", .{ .node = name, .cause = cause, .in_ms = ms });
}

/// Crash points (CrashTuner, SOSP 2019: crash-recovery bugs sit where a node updates its view of
/// the cluster): a node's code asks to crash where it is, a thread of it waiting there for the
/// crash (the Java agent's, at a state transition: sdk/java/DeterminismoCoverage). Granted at
/// once as one of the node's crash faults the swarm keeps now (a kill or a power loss, drawn:
/// `fault.crash_point_kind`), `why: crash_point`; not in a quiet period, not for a node another
/// fault holds, and not for a request older than the asking thread waits (the injector busy
/// meanwhile: the crash would come elsewhere). Said either way (`crash_point`), "crashed" once
/// the crash began: said before, with the node's admission drawn here and again by node_start,
/// a node held by a fault of the other layer was "crashed" at the first draw and turned away
/// at the second, no kill and no fault following (e2e crash-points with points in every
/// stretch: 132 crashed, 131 faults; the server asked again two seconds later).
const crash_point_age_ns_max = 400 * std.time.ns_per_ms;

/// What a crash point may be granted now, where every node reads it (its /opt/determinismo is the
/// runner's, read-only): the end of the quiet period under way (CLOCK_MONOTONIC, 0 for none),
/// then the nodes whose crash faults the swarm keeps, a line each. `det-faults crash-point`
/// declines at once from it (a quiet period, no crash fault kept, faults over: the file gone), so
/// the asking thread goes on instead of waiting out its half second (a stall in a quiet period
/// would be a fault of its own).
const crash_points_path = "/opt/determinismo/crash-points";

fn crash_points_publish() void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{d}\n", .{quiet_until_ns}) catch return;
    for (faults_active, 0..) |*fault, index| {
        if (fault.kind != .restart and fault.kind != .crash) continue;
        const said = for (faults_active[0..index]) |*earlier| {
            if ((earlier.kind == .restart or earlier.kind == .crash) and std.mem.eql(u8, earlier.node, fault.node)) break true;
        } else false;
        if (!said) writer.print("{s}\n", .{fault.node}) catch return;
    }
    const temporary = crash_points_path ++ ".new";
    const fd = linux.open(temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), &buffer, writer.end);
    _ = linux.close(@intCast(fd));
    _ = linux.rename(temporary, crash_points_path);
}

/// Whether the injector may grant `node` a crash point now (crash_points_publish's file).
fn crash_point_open(node: []const u8, now_ns: u64) error{ NoInjector, Quiet, NoCrashFault }!void {
    var buffer: [4096]u8 = undefined;
    const text = nodes.read_small(crash_points_path, &buffer) orelse return error.NoInjector;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const quiet_until = std.fmt.parseInt(u64, lines.next() orelse return error.NoInjector, 10) catch return error.NoInjector;
    if (now_ns < quiet_until) return error.Quiet;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, node)) return;
    }
    return error.NoCrashFault;
}

const CrashPoint = struct { asked_ns: u64, node: []const u8, point: []const u8 };

/// "<asked_ns> <node>\n<point>" (det-faults crash-point's body).
fn crash_point_parse(body: []const u8) ?CrashPoint {
    const line_end = std.mem.indexOfScalar(u8, body, '\n') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, body[0..line_end], ' ');
    const asked_ns = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const node = fields.next() orelse return null;
    if (fields.next() != null) return null;
    return .{ .asked_ns = asked_ns, .node = node, .point = body[line_end + 1 ..] };
}

test crash_point_parse {
    const parsed = crash_point_parse("123 server\nstate StateServer.role: FOLLOWER -> CANDIDATE (after)").?;
    try std.testing.expectEqual(@as(u64, 123), parsed.asked_ns);
    try std.testing.expectEqualStrings("server", parsed.node);
    try std.testing.expectEqualStrings("state StateServer.role: FOLLOWER -> CANDIDATE (after)", parsed.point);
    try std.testing.expect(crash_point_parse("123 server") == null);
    try std.testing.expect(crash_point_parse("x server\npoint") == null);
    try std.testing.expect(crash_point_parse("1 a b\npoint") == null);
}

fn crash_point_asked(system: *const schema.System, body: []const u8) void {
    const request = crash_point_parse(body) orelse return;
    const asked_ns = request.asked_ns;
    const name = request.node;
    const point = request.point;
    const now_ns = monotonic_ns();
    const outcome: []const u8 = outcome: {
        if (stopping.load(.acquire)) break :outcome "stopping";
        // 0: a request of unknown age (the C SDK built without POSIX clocks).
        if (asked_ns != 0 and now_ns > asked_ns + crash_point_age_ns_max) break :outcome "late";
        if (quiet_until_ns > now_ns) break :outcome "quiet";
        const index = node_slot_index(system, name) orelse break :outcome "unknown node";
        // Its own layer's fault holds it: no draw (node_start draws the other layer's overlap).
        if (nodes_faulted[index][@backingInt(Layer.process)] != null) break :outcome "faulted";
        var kept: [2]*const Fault = undefined;
        var count: usize = 0;
        for (faults_active) |*fault| {
            if ((fault.kind == .restart or fault.kind == .crash) and std.mem.eql(u8, fault.node, name) and count < kept.len) {
                kept[count] = fault;
                count += 1;
            }
        }
        if (count == 0) break :outcome "no crash fault";
        const fault = kept[sdk.random_below_named("fault.crash_point_kind", count)];
        var applied = draw(fault);
        applied.why = .crash_point;
        const began = node_start(system, &applied);
        sdk.event("crash_point", .{
            .node = name,
            .point = point,
            .kind = @tagName(fault.kind),
            .outcome = if (began) "crashed" else "turned away",
        });
        return;
    };
    sdk.event("crash_point", .{ .node = name, .point = point, .outcome = outcome });
}

fn crash_fault_of(name: []const u8) ?*const Fault {
    for (faults_active) |*fault| {
        if (fault.kind == .crash and std.mem.eql(u8, fault.node, name)) return fault;
    }
    return null;
}

/// The aftershocks due: each a power loss of its node, drawn as its crash fault is (downtime,
/// partial persistence). Skipped in a quiet period; node_start skips a node another fault holds
/// or one not running.
fn aftershock_expire(system: *const schema.System, now_ns: u64) void {
    for (&aftershock_ns, 0..) |*due, index| {
        if (due.* == 0 or due.* > now_ns) continue;
        due.* = 0;
        if (index >= system.nodes.len or stopping.load(.acquire)) continue;
        if (quiet_until_ns > now_ns) continue;
        const fault = crash_fault_of(system.nodes[index].name) orelse continue;
        var applied = draw(fault);
        applied.why = .aftershock;
        _ = node_start(system, &applied);
    }
}

fn aftershock_next() ?u64 {
    var next: ?u64 = null;
    for (aftershock_ns) |due| {
        if (due != 0) next = @min(next orelse due, due);
    }
    return next;
}

/// A graceful stop begins: SIGTERM to the node's main process; what is left when the grace
/// period ends is killed (node_expire), and the node starts again at the fault's end.
fn stop_begin(name: []const u8, fault: *NodeFault) !void {
    try nodes.stop_signal(name);
    const grace_end_ns = monotonic_ns() + stop_grace_ns;
    fault.grace_end_ns = grace_end_ns;
    fault.end_ns = @max(fault.end_ns, grace_end_ns);
}

fn node_next_end() ?u64 {
    var next: ?u64 = null;
    for (nodes_faulted) |slots| for (slots) |slot| {
        const fault = slot orelse continue;
        next = @min(next orelse fault.end_ns, fault.end_ns);
        if (fault.grace_end_ns) |grace_end_ns| next = @min(next.?, grace_end_ns);
        if (fault.flip_ns) |flip_ns| next = @min(next.?, flip_ns);
    };
    return next;
}

fn node_heal(system: *const schema.System) void {
    // Conditions first: a node the process layer starts again starts without them.
    for (&nodes_faulted) |*slots| node_end(system, &slots[@backingInt(Layer.condition)]);
    for (&nodes_faulted) |*slots| node_end(system, &slots[@backingInt(Layer.process)]);
    threads_release_pending(threads_release_wait_ns);
}

/// How long healing waits for paused threads to stop so they can be let go.
const threads_release_wait_ns = 5 * std.time.ns_per_s;
/// How soon the injector looks again at threads it let go of but could not yet detach or reap.
const threads_pending_poll_ns = 50 * std.time.ns_per_ms;

/// An outage begins: its nodes all frozen first (none runs on while the others go down), then
/// each crashed (or killed, `power` false), each holding its own slot until the fault's end,
/// when all start again.
/// A node busy with another fault, or down already, is left out; with fewer than two left
/// there is no outage.
fn outage_start(system: *const schema.System, applied: *const Applied) void {
    var taken = applied.*;
    const count_nodes = system.nodes.len;
    var count: u32 = 0;
    for (system.nodes, taken.outage[1..][0..count_nodes], 0..) |node, *in, index| {
        if (!in.*) continue;
        in.* = node_admits(index, .process) and nodes.state_of(node.name) != .stopped;
        count += @intFromBool(in.*);
    }
    if (count < 2) {
        sdk.event("fault_skipped", .{ .kind = "outage", .err = "FewerThanTwoNodes" });
        return;
    }
    // The scenario's cap on nodes down at once counts those already down too.
    if (nodes_down_max > 0) {
        var down_already: u32 = 0;
        for (nodes_faulted[0..count_nodes]) |faulted| {
            if (faulted[@backingInt(Layer.process)]) |fault| down_already += @intFromBool(takes_down(fault.applied.kind));
        }
        if (down_already + count > nodes_down_max) {
            sdk.event("fault_skipped", .{ .kind = "outage", .err = "NodesDownMax" });
            return;
        }
    }
    for (system.nodes, taken.outage[1..][0..count_nodes]) |node, in| {
        if (in) nodes.freeze(node.name, .frozen) catch {};
    }
    const end_ns = monotonic_ns() + applied.duration_ns;
    var down: u32 = 0;
    for (system.nodes, nodes_faulted[0..count_nodes], taken.outage[1..][0..count_nodes]) |node, *slots, *in| {
        if (!in.*) continue;
        const slot = &slots[@backingInt(Layer.process)];
        const ended = if (applied.power) nodes.crash(node.name, partial_for(system, node.name, applied)) else killed: {
            const result = nodes.kill(node.name);
            nodes.freeze(node.name, .thawed) catch {}; // Its next start runs.
            break :killed result;
        };
        ended catch |err| {
            nodes.freeze(node.name, .thawed) catch {};
            sdk.event("fault_failed", .{ .kind = "outage", .node = node.name, .err = @errorName(err) });
            in.* = false;
            continue;
        };
        var one = taken;
        one.node = node.name;
        slot.* = .{ .applied = one, .end_ns = end_ns };
        down += 1;
        unlist_maybe(system, node.name);
    }
    if (down == 0) return;
    // Its event names them all ("a,b,c"), as the logs and the causality analysis show it.
    var names: std.ArrayList(u8) = .empty;
    if (arena_active) |arena| {
        for (system.nodes, taken.outage[1..][0..count_nodes]) |node, in| {
            if (!in) continue;
            if (names.items.len > 0) names.append(arena, ',') catch {};
            names.appendSlice(arena, node.name) catch {};
        }
    }
    taken.node = names.items;
    sdk.event("fault", taken);
}

// Durability points ---------------------------------------------------------------------------
// The guest module's (det_guest.c): armed per node cgroup, asked through /dev/determinismo.

const ioctl_durability_arm = 0xde02;
const ioctl_durability_wait = 0xde03;
const DurabilityMode = enum(u32) { stall = 0, crash_before = 1, crash_after = 2 };

const DurabilityArm = extern struct {
    cgroup: u64 align(1),
    one_in: u32 align(1),
    mode: DurabilityMode align(1),
    stall_ms_min: u32 align(1),
    stall_ms_max: u32 align(1),
    node: [32]u8 align(1),
};
const DurabilityRequest = extern struct {
    cgroup: u64 align(1),
    pid: i32 align(1),
    mode: DurabilityMode align(1),
    comm: [16]u8 align(1),
};

comptime {
    assert(@sizeOf(DurabilityArm) == 56); // The module's struct det_durability_arm (packed).
    assert(@sizeOf(DurabilityRequest) == 32);
}

/// The listener crashes nodes while the main loop ends their faults: under this lock, a crash
/// comes only while the node's fault lasts, and its end sees whether one came.
var durable_lock: std.atomic.Mutex = .unlocked;
/// The node's durable_crash fault lasts.
var durable_active: [schema.nodes_max]bool = @splat(false);
/// Each armed durable_crash's partial persistence (Applied.partial), for its crash at a point.
var durable_partial: [schema.nodes_max]?nodes.Partial = @splat(null);
/// The node crashed at a durability point during its fault (it starts again at the end).
var durable_crashed: [schema.nodes_max]bool = @splat(false);
var module_device: linux.fd_t = -1;
var durable_listening: bool = false;

fn node_index_of(system: *const schema.System, name: []const u8) ?usize {
    for (system.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

/// The node's cgroup, as the module names it: its directory's inode number.
fn node_cgroup(name: []const u8) !u64 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}", .{ nodes.cgroup_root, name }, 0);
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .INO = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return error.NoCgroup;
    return stat.ino;
}

fn durable_lock_take() void {
    while (!durable_lock.tryLock()) {
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
}

/// The guest module's device, opened once.
fn device_open() !void {
    if (module_device >= 0) return;
    const fd = linux.open(sdk.device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoDevice;
    module_device = @intCast(fd);
}

fn durable_arm(applied: *const Applied) !void {
    try device_open();
    if (!durable_listening) {
        const listener = try std.Thread.spawn(.{}, durable_listen, .{});
        listener.detach();
        durable_listening = true;
    }
    var arm: DurabilityArm = .{
        .cgroup = try node_cgroup(applied.node),
        .one_in = applied.one_in,
        .mode = if (applied.kind == .sync_stall)
            .stall
        else if (applied.after_sync) .crash_after else .crash_before,
        .stall_ms_min = applied.stall_ms_min,
        .stall_ms_max = @max(applied.stall_ms_max, applied.stall_ms_min),
        .node = @splat(0),
    };
    const length = @min(applied.node.len, arm.node.len - 1);
    @memcpy(arm.node[0..length], applied.node[0..length]);
    if (applied.kind == .durable_crash) {
        const system = system_active orelse return error.NoSystem;
        const index = node_index_of(system, applied.node) orelse return error.UnknownNode;
        durable_lock_take();
        defer durable_lock.unlock();
        durable_active[index] = true;
        durable_partial[index] = partial_for(system, applied.node, applied);
    }
    const armed = linux.ioctl(module_device, ioctl_durability_arm, @intFromPtr(&arm));
    if (linux.errno(armed) != .SUCCESS) return error.ArmFailed;
}

fn durable_disarm(name: []const u8) void {
    if (module_device < 0) return;
    var arm: DurabilityArm = .{
        .cgroup = node_cgroup(name) catch return,
        .one_in = 0,
        .mode = .stall,
        .stall_ms_min = 0,
        .stall_ms_max = 0,
        .node = @splat(0),
    };
    _ = linux.ioctl(module_device, ioctl_durability_arm, @intFromPtr(&arm));
}

const ioctl_interleave_arm = 0xde04;

const InterleaveArm = extern struct {
    cgroup: u64 align(1),
    one_in: u32 align(1),
    reserved: u32 align(1) = 0,
    node: [32]u8 align(1),
};

/// Arms the node's interleavings (one scheduling choice in `one_in` drawn), or disarms them
/// with 0: the module then says how many it drew (an `interleaved` event).
fn interleave_arm(name: []const u8, one_in: u32) !void {
    try device_open();
    var arm: InterleaveArm = .{ .cgroup = try node_cgroup(name), .one_in = one_in, .node = @splat(0) };
    const length = @min(name.len, arm.node.len - 1);
    @memcpy(arm.node[0..length], name[0..length]);
    const armed = linux.ioctl(module_device, ioctl_interleave_arm, @intFromPtr(&arm));
    if (linux.errno(armed) != .SUCCESS) return error.ArmFailed;
}

/// The listener: each ask of a durability point, its node crashed there.
fn durable_listen() void {
    const system = system_active orelse return;
    while (true) {
        var request: DurabilityRequest = undefined;
        const asked = linux.ioctl(module_device, ioctl_durability_wait, @intFromPtr(&request));
        if (linux.errno(asked) == .INTR) continue;
        if (linux.errno(asked) != .SUCCESS) return;
        const node = for (system.nodes, 0..) |node, index| {
            const cgroup = node_cgroup(node.name) catch continue;
            if (cgroup == request.cgroup) break .{ node.name, index };
        } else continue;
        durable_lock_take();
        defer durable_lock.unlock();
        if (!durable_active[node[1]]) continue; // Its fault ended: disarmed, nothing parked.
        // Crashed already during this fault (two of its threads were parked at durability
        // points): it is down until the fault's end starts it again.
        if (durable_crashed[node[1]]) {
            sdk.event("durable_crash_again", .{ .node = node[0], .pid = request.pid });
            continue;
        }
        sdk.event("durable_crash", .{
            .node = node[0],
            .process = std.mem.sliceTo(&request.comm, 0),
            .pid = request.pid,
            .when = if (request.mode == .crash_after) "after_sync" else "before_sync",
        });
        // Disarmed once the freeze is asked for: the parked process goes on into it.
        nodes.crash_with(node[0], durable_disarm, durable_partial[node[1]]) catch |err| {
            sdk.event("fault_failed", .{ .node = node[0], .err = @errorName(err) });
            continue;
        };
        durable_crashed[node[1]] = true;
    }
}

/// The process a process or thread fault stops. On a node running Kubernetes, a process of one
/// of its pods (pod_pick: the cluster's own spared), never the platform's (K3s, containerd, a
/// pod's shim or sandbox): stopped, those broke the drivers' kubectl exec, not the system (e2e
/// kubernetes, 2026-11-03: a containerd-shim stopped 4.45 s, the driver's exec timed out loading
/// its task, and the driver exited 1). Elsewhere, any of the node's processes. Pods all spared
/// (kube-system's, the exclusions'): none (error.PodsSpared, the fault skipped), never K3s's: a
/// run excluding every pod but the cluster's had K3s's server stopped 14.8 s, the control plane
/// with it, and an excluded operator lost its leader lease (ParadeDB's proptests, run 2098).
fn fault_process(applied: *const Applied) !linux.pid_t {
    var pod: Pod = .{};
    if (pod_pick(applied.node, applied.process_index, &pod, false)) |pid| {
        return pid;
    } else |err| if (err != error.NoPods) return err;
    var pids: [processes_max]linux.pid_t = undefined;
    const count = try nodes.processes(applied.node, &pids);
    if (count == 0) return error.NoProcess;
    return pids[applied.process_index % count];
}

/// One of the node's processes stopped (SIGSTOP).
fn process_stop(applied: *const Applied, fault: *NodeFault) !void {
    fault.pid = try fault_process(applied);
    fault.command_size = @intCast(command_of(fault.pid, &fault.command).len);
    _ = linux.kill(fault.pid, .STOP);
}

const ptrace_detach = 17;
const wait_all = 0x40000000; // __WALL: threads too.

/// One thread stopped with ptrace (seize, interrupt): the process's other threads run on.
fn thread_stop(applied: *const Applied, fault: *NodeFault) !void {
    const pid = try fault_process(applied);
    // A thread of it still seized from an earlier pause (not stopped when that pause ended) may
    // have exited unreaped: an exec of the process then holds its cred_guard_mutex waiting for
    // that zombie, and seizing another of its threads would wait on the mutex for good (srv3,
    // 2026-10-30, Redpanda's membership smoke: the injector stalled 3,500 s in `apply
    // thread_pause` on a broker restarted a second earlier, its start exec'ing). Reaped first;
    // left alone if one is still there.
    threads_release_pending(0);
    if (thread_pending_in(pid)) return error.ThreadPending;
    fault.command_size = @intCast(command_of(pid, &fault.command).len);
    var tids: [threads_max]linux.pid_t = undefined;
    const threads = nodes.threads(pid, &tids);
    if (threads == 0) return error.NoThread;
    const tid = tids[applied.thread_index % threads];
    if (linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) != .SUCCESS) {
        return error.Ptrace;
    }
    if (linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) != .SUCCESS) {
        _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
        return error.Ptrace;
    }
    // Stopped at its next return to user space: one in a kernel wait (a sync held, a page fault)
    // stops only when it ends. Not waited for (run 177's timeline 24: 31 s, the injector stalled
    // meanwhile): the pause begins when the thread stops.
    fault.pid = tid;
    fault.stopped = thread_stopped(tid);
}

/// Whether a thread of process `pid` is still seized from an earlier pause.
fn thread_pending_in(pid: linux.pid_t) bool {
    for (threads_pending[0..threads_pending_count]) |tid| {
        var path_buffer: [48]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task/{d}", .{ pid, tid }, 0) catch continue;
        if (linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS) return true;
    }
    return false;
}

/// Whether the tracee `tid` reported its stop, or exited (polled, never waited for).
fn thread_stopped(tid: linux.pid_t) bool {
    return tracee_event(tid) != .none;
}

/// The tracee's waiting event, polled (never waited for): none yet; its stop, consumed; or gone:
/// it exited and this wait reaped it, or it is no tracee of ours any more. A thread whose process
/// exited during its pause (exit_group kills a stopped thread too) is a zombie that only its
/// tracer reaps; until then its thread group never empties, so the process's pidfd never fires
/// and its parent never sees it exit (trial run 694: bun-write.test.js's spawnSync child, its
/// pool thread a zombie traced by det-faults, read from the runner's namespace (inside the node's
/// the tracer has no pid: TracerPid 0), its parent in epoll_pwait2 for good; shown natively on
/// srv4: detaching such a zombie failed with ESRCH, the pidfd stayed silent and waitpid(WNOHANG)
/// found nothing until the tracer's wait4; the selftest's `reaping` scenario keeps it so).
const TraceeEvent = enum { none, stopped, gone };

fn tracee_event(tid: linux.pid_t) TraceeEvent {
    var status: i32 = 0;
    const result = linux.wait4(tid, &status, wait_all | linux.W.NOHANG, null);
    if (linux.errno(result) != .SUCCESS) return .gone;
    if (result == 0) return .none;
    if (linux.W.IFSTOPPED(@bitCast(status))) return .stopped;
    return .gone;
}

fn detached(tid: linux.pid_t) bool {
    return linux.errno(linux.ptrace(ptrace_detach, tid, 0, 0, 0)) == .SUCCESS;
}

/// Threads paused whose pause ended before they stopped: detached once they do (a seized thread
/// is detached only stopped), each pass of the injector's loop (threads_release_pending).
var threads_pending: [threads_pending_max]linux.pid_t = undefined;
var threads_pending_count: u32 = 0;
const threads_pending_max = 64;

fn thread_release(tid: linux.pid_t, stopped: bool) void {
    // Its event first (tracee_event): an exit reaped, a stop consumed. A detach that fails is a
    // thread killed since it stopped: pending, reaped once it is a zombie.
    switch (tracee_event(tid)) {
        .gone => return,
        .stopped => if (detached(tid)) return,
        .none => if (stopped and detached(tid)) return,
    }
    if (threads_pending_count == threads_pending_max) {
        // Never expected (one pause a node at a time): waited for rather than left stopped,
        // until it is detached or reaped.
        while (true) {
            var status: i32 = 0;
            const result = linux.wait4(tid, &status, wait_all, null);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS or !linux.W.IFSTOPPED(@bitCast(status))) return;
            if (detached(tid)) return;
        }
    }
    threads_pending[threads_pending_count] = tid;
    threads_pending_count += 1;
}

test thread_release {
    // A child of two threads, one seized and stopped (its stop consumed, as thread_stop's poll
    // may), then the child killed: released, its exit shows on its pidfd. Detached without a
    // wait (the leak), the killed thread stayed a zombie only its tracer reaps and the pidfd
    // never fired. The non-leader seized, then the leader.
    try release_case(false);
    try release_case(true);
}

fn release_case(leader: bool) !void {
    var fds: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) == .SUCCESS);
    const forked = linux.fork();
    try std.testing.expect(linux.errno(forked) == .SUCCESS);
    if (forked == 0) {
        _ = linux.close(fds[0]);
        _ = std.Thread.spawn(.{}, release_case_thread, .{fds[1]}) catch linux.exit_group(2);
        while (true) _ = linux.pause();
    }
    const child: linux.pid_t = @intCast(forked);
    _ = linux.close(fds[1]);
    var other: i32 = 0;
    try std.testing.expect(linux.read(fds[0], std.mem.asBytes(&other), 4) == 4);
    _ = linux.close(fds[0]);
    const pidfd = linux.pidfd_open(child, 0);
    try std.testing.expect(linux.errno(pidfd) == .SUCCESS);
    defer _ = linux.close(@intCast(pidfd));
    const tid: linux.pid_t = if (leader) child else other;
    try std.testing.expect(linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) == .SUCCESS);
    try std.testing.expect(linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) == .SUCCESS);
    var status: i32 = 0;
    try std.testing.expect(linux.wait4(tid, &status, wait_all, null) == tid);
    try std.testing.expect(linux.W.IFSTOPPED(@bitCast(status)));
    try std.testing.expect(linux.errno(linux.kill(child, .KILL)) == .SUCCESS);
    thread_release(tid, true);
    threads_release_pending(std.time.ns_per_s);
    var polled = [_]linux.pollfd{.{ .fd = @intCast(pidfd), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&polled, 1, 1000));
    // Reaped by the release when it was the leader (this test is its tracer and its parent).
    const reaped = linux.wait4(child, &status, linux.W.NOHANG, null);
    try std.testing.expect(reaped == child or linux.errno(reaped) == .CHILD);
}

fn release_case_thread(fd: i32) void {
    const tid: i32 = linux.gettid();
    _ = linux.write(fd, std.mem.asBytes(&tid), 4);
    while (true) _ = linux.pause();
}

/// The pending threads that stopped meanwhile, detached; with `wait_ns`, waiting that long at
/// most for the rest (faults stop: none left stopped, leftovers_check says so if one is).
fn threads_release_pending(wait_ns: u64) void {
    const deadline_ns = monotonic_ns() + wait_ns;
    while (true) {
        var kept: u32 = 0;
        for (threads_pending[0..threads_pending_count]) |tid| {
            const released = switch (tracee_event(tid)) {
                .gone => true,
                .stopped => detached(tid),
                .none => false,
            };
            if (released) continue;
            threads_pending[kept] = tid;
            kept += 1;
        }
        threads_pending_count = kept;
        if (kept == 0 or monotonic_ns() >= deadline_ns) return;
        sleep_ns(std.time.ns_per_ms);
    }
}

/// Runs the node's fault program to completion (its duration is its own); nothing to undo.
/// The program is a command line split at spaces (no shell: nodes may have none). On a thread of
/// its own, beside the main loop: run in it, a program waiting on its node held every other
/// fault, the ends of those applied included (Datomic's gc asking a paused peer: 35 s in hunt
/// run 656, 31.8 s in run 735, each failing "the fault injector never stalls").
fn apply_custom(
    _: std.mem.Allocator,
    system: *const schema.System,
    applied: *const Applied,
) void {
    const node = system.node(applied.node) orelse return;
    if (std.mem.indexOfNone(u8, applied.program, " ") == null) return;
    sdk.event("fault", applied.*);
    // The node lives as long as the system; the program's text is the thread's own copy (an
    // injected fault's is in inject's parse buffer, on its stack).
    const program = std.heap.page_allocator.dupe(u8, applied.program) catch return;
    const thread = std.Thread.spawn(.{}, custom_run, .{ node, program }) catch |err| {
        sdk.event("fault_custom_failed", .{ .program = program, .err = @errorName(err) });
        std.heap.page_allocator.free(program);
        return;
    };
    thread.detach();
}

fn custom_run(node: *const schema.Resolved, program: []const u8) void {
    defer std.heap.page_allocator.free(program);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, program, ' ');
    while (words.next()) |word| argv.append(arena, word) catch return;
    const status = nodes.exec(arena, node, argv.items, .{}) catch |err| {
        sdk.event("fault_custom_failed", .{ .program = program, .err = @errorName(err) });
        return;
    };
    sdk.event("fault_custom_done", .{ .program = program, .status = status });
}

/// A crash: one of the node's processes other than its main one (a worker, a pod's process)
/// is killed, for whatever supervises it to notice; one of the names the node allows, when it
/// names some. Nothing to undo.
fn apply_process_kill(system: *const schema.System, applied: *const Applied) void {
    const names = if (system.node(applied.node)) |node| node.faults.process_kill_names else &.{};
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    const main_pid = nodes.pid_recorded(applied.node);
    var others: u32 = 0;
    for (pids[0..count]) |pid| {
        if (pid == main_pid) continue;
        if (names.len > 0 and !command_named(pid, names)) continue;
        // A worker that crashes has been running: a start script's helpers live for less than
        // a second, and one killed ends its script under set -e (Cassandra's launcher checks
        // its Java with `java -version`, named as its server: run 913's timeline 5, its node
        // down with "Cassandra 5.0 requires Java 11 or Java 17").
        if ((process_age_ns(pid) orelse 0) < process_kill_age_min_ns) continue;
        pids[others] = pid;
        others += 1;
    }
    if (others == 0) return;
    const pid = pids[applied.process_index % others];
    var named = applied.*;
    var command: [16]u8 = undefined;
    named.process = command_of(pid, &command);
    _ = linux.kill(pid, .KILL);
    sdk.event("fault", named);
}

// System call errors (Faults.syscall_errors) -------------------------------------------------
// The kernel's fail_function (guest/kernel/determinismo.config): the system call's entry point
// made to return the error without running, for the tasks marked make-it-fail (the task filter),
// which the node's tasks are for the fault's time (their children and threads inherit it). Its
// settings are the guest's, not a node's: one such fault at a time.

const SyscallError = struct { name: []const u8, errnos: []const linux.E };

/// Errors the system calls' manuals allow whatever the descriptor or the file system: never an
/// ENOSPC on a socket's write (a file's reads and writes need the file's type: not here).
const syscall_errors = [_]SyscallError{
    .{ .name = "openat", .errnos = &.{ .MFILE, .NFILE } },
    .{ .name = "accept", .errnos = &.{ .MFILE, .NFILE } },
    .{ .name = "accept4", .errnos = &.{ .MFILE, .NFILE } },
    .{ .name = "socket", .errnos = &.{ .MFILE, .NFILE } },
    .{ .name = "clone", .errnos = &.{.AGAIN} },
    .{ .name = "clone3", .errnos = &.{.AGAIN} },
    .{ .name = "mmap", .errnos = &.{.NOMEM} },
    .{ .name = "fsync", .errnos = &.{ .IO, .NOSPC } },
    .{ .name = "fdatasync", .errnos = &.{ .IO, .NOSPC } },
    .{ .name = "fallocate", .errnos = &.{ .NOSPC, .IO } },
    .{ .name = "rename", .errnos = &.{ .NOSPC, .IO } },
    .{ .name = "renameat", .errnos = &.{ .NOSPC, .IO } },
    .{ .name = "renameat2", .errnos = &.{ .NOSPC, .IO } },
    .{ .name = "mkdir", .errnos = &.{ .NOSPC, .IO } },
    .{ .name = "mkdirat", .errnos = &.{ .NOSPC, .IO } },
};

/// One call in `one_in` fails (fail_function's interval), each a named decision.
const syscall_one_in = [_]u32{ 1, 2, 5, 20, 100 };

fn syscall_error_draw(applied: *Applied) void {
    const call = syscall_errors[sdk.random_below_named("fault.syscall", syscall_errors.len)];
    applied.syscall = call.name;
    applied.errno = @tagName(call.errnos[sdk.random_below_named("fault.syscall_errno", call.errnos.len)]);
    applied.one_in = syscall_one_in[sdk.random_below_named("fault.syscall_one_in", syscall_one_in.len)];
}

const fail_function = "/sys/kernel/debug/fail_function";

fn syscall_error_begin(applied: *const Applied) !void {
    _ = linux.mount("debugfs", "/sys/kernel/debug", "debugfs", 0, 0); // Mounted already, or now.
    var listed: [256]u8 = undefined;
    if (std.mem.trim(u8, try file_read(fail_function ++ "/inject", &listed), " \n").len > 0) {
        return error.SyscallErrorElsewhere;
    }
    const errno = std.meta.stringToEnum(linux.E, applied.errno) orelse return error.UnknownErrno;
    var buffer: [128]u8 = undefined;
    try file_put(fail_function ++ "/inject", try std.fmt.bufPrint(&buffer, "__x64_sys_{s}\n", .{applied.syscall}));
    errdefer file_put(fail_function ++ "/inject", "\n") catch {};
    var path_buffer: [128]u8 = undefined;
    const retval = try std.fmt.bufPrintSentinel(&path_buffer, fail_function ++ "/__x64_sys_{s}/retval", .{applied.syscall}, 0);
    // The return value as the kernel's unsigned long: -errno.
    const value: u64 = @bitCast(-@as(i64, @backingInt(errno)));
    try file_put(retval, try std.fmt.bufPrint(&buffer, "{d}\n", .{value}));
    try file_put(fail_function ++ "/task-filter", "Y\n");
    try file_put(fail_function ++ "/probability", "100\n");
    try file_put(fail_function ++ "/interval", try std.fmt.bufPrint(&buffer, "{d}\n", .{applied.one_in}));
    try file_put(fail_function ++ "/times", "-1\n");
    try file_put(fail_function ++ "/space", "0\n");
    try file_put(fail_function ++ "/verbose", "0\n");
    tasks_mark(applied.node, true);
}

fn syscall_error_end(name: []const u8) void {
    tasks_mark(name, false);
    file_put(fail_function ++ "/inject", "\n") catch |err| {
        sdk.event("fault_heal_failed", .{ .node = name, .err = @errorName(err) });
    };
}

/// Every task of the node marked make-it-fail, or no longer.
fn tasks_mark(name: []const u8, on: bool) void {
    var pids: [1024]linux.pid_t = undefined;
    const count = nodes.processes(name, &pids) catch return;
    var tids: [4096]linux.pid_t = undefined;
    for (pids[0..count]) |pid| {
        for (tids[0..nodes.threads(pid, &tids)]) |tid| {
            var path_buffer: [64]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task/{d}/make-it-fail", .{ pid, tid }, 0) catch continue;
            file_put(path, if (on) "1\n" else "0\n") catch {}; // Gone meanwhile.
        }
    }
}

fn file_put(path: [:0]const u8, text: []const u8) !void {
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Open;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.write(@intCast(fd), text.ptr, text.len)) != .SUCCESS) return error.Write;
}

fn file_read(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Open;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return error.Read;
    return buffer[0..size];
}

// File errors (Faults.file_errors) ------------------------------------------------------------
// The guest kernel asks det_guest.ko at each read and write of a regular file
// (guest/kernel/patches/0010); an armed node's, of its own disk, fail one in `one_in`.

/// Reads or writes failing with an error, or writes shortened (moving part of what was asked).
pub const FileCalls = enum(u32) { reads = 1, writes = 2, both = 3, short_writes = 4 };

const ioctl_file_error_arm = 0xde05;

const FileErrorArm = extern struct {
    cgroup: u64 align(1),
    one_in: u32 align(1),
    errno: u32 align(1),
    calls: u32 align(1),
    reserved: u32 align(1) = 0,
    node: [32]u8 align(1),
};

/// A full disk fails writes (ENOSPC, EDQUOT) or shortens them, a failing one fails reads and
/// writes (EIO); writes failing two times in five.
fn file_error_draw(applied: *Applied) void {
    const calls: FileCalls = switch (sdk.random_below_named("fault.file_calls", 5)) {
        0, 1 => .writes,
        2 => .reads,
        3 => .both,
        else => .short_writes,
    };
    applied.file_calls = calls;
    applied.one_in = syscall_one_in[sdk.random_below_named("fault.file_one_in", syscall_one_in.len)];
    if (calls == .short_writes) return; // No error: the write returns less.
    const errnos: []const linux.E = if (calls == .writes) &.{ .NOSPC, .DQUOT, .IO } else &.{.IO};
    applied.errno = @tagName(errnos[sdk.random_below_named("fault.file_errno", errnos.len)]);
}

/// Arms the node's file errors, or disarms them (null): the module then says how many of its
/// calls it saw and failed (a `file_errors` event).
fn file_error_arm(name: []const u8, applied: ?*const Applied) !void {
    try device_open();
    var arm: FileErrorArm = .{ .cgroup = try node_cgroup(name), .one_in = 0, .errno = 0, .calls = 0, .node = @splat(0) };
    if (applied) |fault| {
        const calls = fault.file_calls orelse .both;
        arm.one_in = @max(fault.one_in, 1);
        arm.calls = @backingInt(calls);
        if (calls != .short_writes) {
            const errno = std.meta.stringToEnum(linux.E, fault.errno) orelse return error.UnknownErrno;
            arm.errno = @backingInt(errno);
        }
    }
    const length = @min(name.len, arm.node.len - 1);
    @memcpy(arm.node[0..length], name[0..length]);
    const armed = linux.ioctl(module_device, ioctl_file_error_arm, @intFromPtr(&arm));
    if (linux.errno(armed) != .SUCCESS) return error.ArmFailed;
}

/// The signals a `signal` fault may send: ones a server meets in its ordinary life, meaning nothing
/// to it beyond themselves (a child's exit, Go's preemption, a terminal's size, a pipe's reader
/// gone), never one an operator means something by (HUP, USR1, TERM).
const signals_ordinary = [_]linux.SIG{ .CHLD, .URG, .WINCH, .PIPE };

/// One of the node's processes (any, its main one included) sent a signal it catches, among the
/// ordinary ones: its blocked system calls see EINTR where its handler does not restart them.
/// None caught by the process drawn: nothing sent. Nothing to undo.
fn apply_signal(applied: *const Applied) void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    if (count == 0) return;
    const pid = pids[applied.process_index % count];
    const caught = signals_caught(pid) orelse return;
    var choices: [signals_ordinary.len]linux.SIG = undefined;
    var choice_count: usize = 0;
    for (signals_ordinary) |signal| {
        if (caught & (@as(u64, 1) << @intCast(@backingInt(signal) - 1)) != 0) {
            choices[choice_count] = signal;
            choice_count += 1;
        }
    }
    if (choice_count == 0) {
        sdk.event("fault_skipped", .{ .kind = "signal", .node = applied.node, .err = "NoneCaught" });
        return;
    }
    const signal = choices[applied.thread_index % choice_count];
    var named = applied.*;
    var command: [16]u8 = undefined;
    named.process = command_of(pid, &command);
    named.signal = @tagName(signal);
    _ = linux.kill(pid, signal);
    sdk.event("fault", named);
}

/// The signals a process catches: /proc/<pid>/status's SigCgt, a hexadecimal mask (bit n-1 for
/// signal n).
fn signals_caught(pid: linux.pid_t) ?u64 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/status", .{pid}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return status_mask(buffer[0..size], "SigCgt:");
}

fn status_mask(text: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = std.mem.trimStart(u8, text[at + key.len ..], " \t");
    const end = std.mem.indexOfAny(u8, rest, "\n ") orelse rest.len;
    rest = rest[0..end];
    return std.fmt.parseInt(u64, rest, 16) catch null;
}

test status_mask {
    const text = "Name:\tvalkey-server\nSigBlk:\t0000000000000000\nSigIgn:\t0000000000001001\n" ++
        "SigCgt:\t0000000100014a02\n";
    const mask = status_mask(text, "SigCgt:").?;
    try std.testing.expect(mask & (1 << (17 - 1)) != 0); // SIGCHLD
    try std.testing.expect(mask & (1 << (13 - 1)) == 0); // SIGPIPE not caught
}

/// A process process_kill may kill has lived this long at least.
const process_kill_age_min_ns = 5 * std.time.ns_per_s;

/// How long the process has run: its start (/proc/<pid>/stat, in clock ticks since boot)
/// against the boot clock, both the guest's virtual time.
fn process_age_ns(pid: linux.pid_t) ?u64 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [1024]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const ticks = stat_start_ticks(buffer[0..size]) orelse return null;
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.BOOTTIME, &now);
    const now_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
    // USER_HZ, 100 on x86-64 whatever the kernel's tick.
    return now_ns -| ticks * (std.time.ns_per_s / 100);
}

/// A /proc/<pid>/stat line's start time (its 22nd field), after the command in parentheses
/// (which may hold spaces and parentheses itself: the last ")" ends it).
fn stat_start_ticks(text: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    // From the state (the 3rd field) to the start time (the 22nd).
    for (0..19) |_| _ = fields.next() orelse return null;
    return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
}

test stat_start_ticks {
    const line = "817 (java -version) S 909 909 909 0 -1 4194304 1200 0 0 0 30 10 0 0 20 0 21 0 16597 3000000 400 18446744073709551615";
    try std.testing.expectEqual(@as(?u64, 16597), stat_start_ticks(line));
    try std.testing.expectEqual(@as(?u64, null), stat_start_ticks("817 (java"));
}

/// Whether the process's command name (/proc/<pid>/comm) is one of `names`.
fn command_named(pid: linux.pid_t, names: []const []const u8) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return false;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [64]u8 = undefined;
    const read = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(read) != .SUCCESS) return false;
    const command = std.mem.trimEnd(u8, buffer[0..read], "\n");
    for (names) |name| if (std.mem.eql(u8, command, name)) return true;
    return false;
}

/// The links (one direction each) a partition or clog disrupts.
const Directed = struct { from: []const u8, to: []const u8 };
const directed_max = endpoints_max * endpoints_max;

fn disrupted_links(
    system: *const schema.System,
    applied: *const Applied,
    links: *[directed_max]Directed,
) u32 {
    var count: u32 = 0;
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b or !disrupts(system, applied, a, b)) continue;
        links[count] = .{ .from = endpoint_name(system, a), .to = endpoint_name(system, b) };
        count += 1;
    };
    return count;
}

/// Whether a partition into groups or a clog disrupts the direction from endpoint a to b.
fn disrupts(system: *const schema.System, applied: *const Applied, a: usize, b: usize) bool {
    if (a == b or !faultable(system, a, b)) return false;
    return switch (applied.kind) {
        .partition_groups => applied.groups[a] != group_none and
            applied.groups[b] != group_none and switch (applied.direction orelse .both) {
            .both => applied.groups[a] != applied.groups[b],
            .outbound => applied.groups[a] < applied.groups[b],
            .inbound => applied.groups[a] > applied.groups[b],
        },
        .clog => blk: {
            const node = endpoint_index(system, applied.node) orelse break :blk false;
            break :blk switch (applied.direction.?) {
                .outbound => a == node,
                .inbound => b == node,
                .both => a == node or b == node,
            };
        },
        else => false,
    };
}

// Network faults -------------------------------------------------------------------------
// They overlap (Antithesis's): each is active until its end, and every link carries the most
// aggressive of the faults on it (down; else the most loss, then the most delay), or the
// baseline when none is. A restore, a quiet period or the stop heals them all. Only changes
// reach the kernel.

const active_max = 32;
const release_ns = 10 * std.time.ns_per_ms;

const Active = struct {
    applied: Applied,
    end_ns: u64,
    /// A swizzle's clog begins later than it was added: until then it disrupts nothing.
    start_ns: u64 = 0,
    started: bool = true,
    /// A jammed fault that ended: its links let what they held go (delay 0) before they heal,
    /// since removing netem drops its queue.
    releasing: bool = false,
};

const Network = struct {
    active: [active_max]Active = undefined,
    count: u32 = 0,
    /// Each link as the kernel has it: down (both directions, [low][high]), and the netem of
    /// each direction (from, to).
    down: [endpoints_max][endpoints_max]bool = @splat(@splat(false)),
    netem: [endpoints_max][endpoints_max]?nodes.Netem = @splat(@splat(null)),
};
var network: Network = .{};

fn network_start(system: *const schema.System, applied: *const Applied) void {
    if (network.count == active_max) return; // Skipped, so not logged.
    network.active[network.count] = .{
        .applied = applied.*,
        .end_ns = monotonic_ns() + applied.duration_ns,
    };
    network.count += 1;
    network_refresh(system);
    sdk.event("fault", applied.*);
}

/// A swizzle's steps: its nodes (`chosen`, at least two) in a drawn clogging order and a drawn
/// unclogging one, a gap of 100 ms to a second between steps; the drawn duration is how long all
/// of them stay clogged together.
fn swizzle_draw(applied: *Applied, chosen: [endpoints_max]bool) void {
    var members: [endpoints_max]u16 = undefined;
    var count: u16 = 0;
    for (chosen, 0..) |yes, index| {
        if (!yes) continue;
        members[count] = @intCast(index);
        count += 1;
    }
    assert(count >= 2);
    for ([_]*[endpoints_max]u16{ &applied.swizzle_order, &applied.swizzle_unclog }) |places| {
        var order = members;
        for (0..count) |at| std.mem.swap(u16, &order[at], &order[at + sdk.random_below(count - at)]);
        for (order[0..count], 1..) |index, place| places[index] = @intCast(place);
    }
    applied.gap_ns = (100 + sdk.random_below(901)) * std.time.ns_per_ms;
    applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
    applied.direction = .both;
}

/// When an endpoint of a swizzle is clogged and unclogged, from its start (`hold_ns`: all of
/// them clogged together): clogged at its place in the order, a gap apart, unclogged once the
/// last is clogged and the hold is over, at its place in the unclogging order, a gap apart.
fn swizzle_window(order: u16, unclog: u16, members: u16, gap_ns: u64, hold_ns: u64) struct { start_ns: u64, end_ns: u64 } {
    assert(order >= 1 and unclog >= 1 and order <= members and unclog <= members);
    return .{
        .start_ns = (order - 1) * gap_ns,
        .end_ns = (members - 1) * gap_ns + hold_ns + unclog * gap_ns,
    };
}

test swizzle_window {
    // Three nodes 100 ms apart, held 1 s: clogged at 0, 100 and 200 ms, all clogged by 200 ms,
    // unclogged from 1.3 s on, a gap apart, in the unclogging order.
    const gap = 100 * std.time.ns_per_ms;
    const hold = std.time.ns_per_s;
    const first = swizzle_window(1, 3, 3, gap, hold);
    const last = swizzle_window(3, 1, 3, gap, hold);
    try std.testing.expectEqual(@as(u64, 0), first.start_ns);
    try std.testing.expectEqual(@as(u64, 2 * gap), last.start_ns);
    try std.testing.expectEqual(@as(u64, 2 * gap + hold + gap), last.end_ns);
    try std.testing.expectEqual(@as(u64, 2 * gap + hold + 3 * gap), first.end_ns);
    // Every clog starts before any ends: they overlap, all of them, for the hold.
    for (1..4) |order| for (1..4) |unclog| {
        const window = swizzle_window(@intCast(order), @intCast(unclog), 3, gap, hold);
        try std.testing.expect(window.start_ns <= 2 * gap and window.end_ns > 2 * gap + hold);
    };
}

/// A swizzle: one clog per node, each in the network's faults with its own start and end.
fn swizzle_start(system: *const schema.System, applied: *const Applied) void {
    const now_ns = monotonic_ns();
    var members: u16 = 0;
    for (applied.swizzle_order) |place| members += @intFromBool(place > 0);
    for (applied.swizzle_order, applied.swizzle_unclog, 0..) |order, unclog, index| {
        if (order == 0 or network.count == active_max) continue;
        const window = swizzle_window(order, unclog, members, applied.gap_ns, applied.duration_ns);
        var clog = applied.*;
        clog.kind = .clog;
        clog.node = endpoint_name(system, index);
        clog.duration_ns = window.end_ns - window.start_ns;
        network.active[network.count] = .{
            .applied = clog,
            .start_ns = now_ns + window.start_ns,
            .started = window.start_ns == 0,
            .end_ns = now_ns + window.end_ns,
        };
        network.count += 1;
    }
    network_refresh(system);
    sdk.event("fault", applied.*);
}

/// Antithesis's restore: every network fault under way ends now.
fn network_restore(system: *const schema.System, applied: *const Applied) void {
    if (network.count == 0) return; // Nothing to restore: skipped, so not logged.
    sdk.event("fault", applied.*);
    network_heal(system);
}

/// Ends every network fault: jammed ones release what they hold first.
fn network_heal(system: *const schema.System) void {
    const now_ns = monotonic_ns();
    for (network.active[0..network.count]) |*entry| entry.end_ns = now_ns;
    network_expire(system, now_ns);
}

fn network_expire(system: *const schema.System, now_ns: u64) void {
    var kept: u32 = 0;
    var changed = false;
    for (network.active[0..network.count]) |entry| {
        var next = entry;
        if (!entry.started and entry.start_ns <= now_ns) {
            next.started = true;
            changed = true;
        }
        if (entry.end_ns <= now_ns) {
            changed = true;
            const jammed = entry.applied.disruption == .jammed and !entry.releasing;
            if (!jammed) continue;
            next.releasing = true;
            next.end_ns = now_ns + release_ns;
        }
        network.active[kept] = next;
        kept += 1;
    }
    network.count = kept;
    if (changed) {
        doing_set("refresh network", null, "");
        defer doing_set("wait", null, "");
        network_refresh(system);
    }
}

fn network_next_end() ?u64 {
    var next: ?u64 = null;
    for (network.active[0..network.count]) |entry| {
        const at_ns = if (entry.started) entry.end_ns else entry.start_ns;
        next = if (next) |at| @min(at, at_ns) else at_ns;
    }
    return next;
}

/// The node's links are new (it restarted): up, with no netem.
fn network_node_new(system: *const schema.System, name: []const u8) void {
    const index = endpoint_index(system, name) orelse return;
    for (0..endpoints_max) |other| {
        network.down[@min(index, other)][@max(index, other)] = false;
        network.netem[index][other] = null;
        network.netem[other][index] = null;
    }
    network_refresh(system);
}

/// Brings every link to what the active faults (or the baseline) make it.
/// A node (never the runner) that is not running.
fn not_running(endpoint: []const u8) bool {
    if (std.mem.eql(u8, endpoint, schema.runner_name)) return false;
    return nodes.state_of(endpoint) == .stopped;
}

fn network_refresh(system: *const schema.System) void {
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (a + 1..endpoints) |b| {
        var down = false;
        for (network.active[0..network.count]) |*entry| {
            if (!entry.started) continue;
            down = down or (!entry.releasing and cuts_link(system, &entry.applied, a, b));
        }
        if (down == network.down[a][b]) continue;
        const state: nodes.LinkState = if (down) .down else .up;
        const from = endpoint_name(system, a);
        const to = endpoint_name(system, b);
        // A failure leaves the link as it was, and the next refresh tries again: said, since a
        // link left down after faults stop was all run 100 (timeline 360) could tell. Bringing
        // up a link whose interface or namespace is gone is done, though: a node restarting
        // makes its links anew, up (run 123: hundreds of such failures, 7 timelines ending
        // their faults with a link marked down that no longer existed).
        nodes.link_set(system, from, to, state) catch |err| {
            const gone = err == error.NoSuchInterface or err == error.NoSuchNamespace;
            // A node not running (a spare not started yet) has no links to cut: its start makes
            // them anew.
            const absent = gone and (not_running(from) or not_running(to));
            if (!(gone and state == .up) and !absent) {
                sdk.event("link_set_failed", .{ .from = from, .to = to, .state = @tagName(state), .err = @errorName(err) });
                continue;
            }
        };
        network.down[a][b] = down;
    };
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b) continue;
        var wanted: ?nodes.Netem = null;
        for (network.active[0..network.count]) |*entry| {
            if (!entry.started) continue;
            const netem = link_netem(system, entry, a, b) orelse continue;
            if (wanted == null or harsher(netem, wanted.?)) wanted = netem;
        }
        const from = endpoint_name(system, a);
        const to = endpoint_name(system, b);
        if (wanted == null and faultable(system, a, b) and degradable(system, from) and
            degradable(system, to))
        {
            wanted = baseline;
        }
        if (std.meta.eql(wanted, network.netem[a][b])) continue;
        nodes.link_degrade(from, to, wanted) catch continue;
        network.netem[a][b] = wanted;
    };
}

/// Whether link faults may reach the link between endpoints a and b: not the runner's with a
/// node that keeps it (Faults.runner_links), nor one with a node that takes no network faults
/// (`--no-faults`: a monitor, a client), whichever node's isolation or clog it is: as pairwise
/// and group partitions already left such a node out. Isolating a Raft node cut its link to the
/// POC's monitor too, and the node, restarted meanwhile, could not reach it and exited, a
/// container exit of our making (runs 871 and 872).
fn faultable(system: *const schema.System, a: usize, b: usize) bool {
    for ([_]usize{ a, b }) |end| {
        if (end == 0) continue;
        const faults = system.nodes[end - 1].faults;
        if (!faults.partition and !faults.isolate and !faults.degrade) return false;
    }
    if (a != 0 and b != 0) return true;
    if (a == b) return false;
    return system.nodes[@max(a, b) - 1].faults.runner_links;
}

/// Whether a fault takes the link between endpoints a and b down (isolate, partition).
fn cuts_link(system: *const schema.System, applied: *const Applied, a: usize, b: usize) bool {
    if (!faultable(system, a, b)) return false;
    const node = endpoint_index(system, applied.node) orelse return false;
    return switch (applied.kind) {
        .isolate => a == node or b == node,
        .partition => blk: {
            const peer = endpoint_index(system, applied.peer) orelse break :blk false;
            break :blk (a == node and b == peer) or (a == peer and b == node);
        },
        else => false,
    };
}

/// What an active fault does to the direction from a to b, if anything.
fn link_netem(system: *const schema.System, entry: *const Active, a: usize, b: usize) ?nodes.Netem {
    const applied = &entry.applied;
    switch (applied.kind) {
        .degrade => {
            const from = endpoint_index(system, applied.node) orelse return null;
            const to = endpoint_index(system, applied.peer) orelse return null;
            return if (a == from and b == to) applied.netem else null;
        },
        .partition_groups, .clog => {
            if (!disrupts(system, applied, a, b)) return null;
            var netem = disruption_netem(applied);
            if (entry.releasing) netem.delay_ns = 0;
            return netem;
        },
        else => return null,
    }
}

/// Dropped (stopped), delayed (slowed), or held until the fault ends and then delivered
/// (jammed).
fn disruption_netem(applied: *const Applied) nodes.Netem {
    const delay_ns = switch (applied.disruption.?) {
        .stopped => 0,
        .slowed => slowed_delay_ns_min +
            applied.duration_ns % (slowed_delay_ns_max - slowed_delay_ns_min),
        .jammed => applied.duration_ns,
    };
    return .{
        .delay_ns = delay_ns,
        .loss_ppm = if (applied.disruption.? == .stopped) nodes.Netem.ppm else 0,
        .seed = applied.duration_ns,
    };
}

/// The more aggressive of two settings: more loss, then more delay.
fn harsher(a: nodes.Netem, b: nodes.Netem) bool {
    const a_loss = a.loss_effective_ppm();
    const b_loss = b.loss_effective_ppm();
    if (a_loss != b_loss) return a_loss > b_loss;
    return a.delay_ns > b.delay_ns;
}

fn endpoint_name(system: *const schema.System, index: usize) []const u8 {
    return if (index == 0) schema.runner_name else system.nodes[index - 1].name;
}

fn endpoint_index(system: *const schema.System, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, schema.runner_name)) return 0;
    for (system.nodes, 1..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

/// Draws the baseline and puts it on every link whose ends allow degradation (none: no
/// baseline).
fn baseline_start(system: *const schema.System) void {
    var any = false;
    for (system.nodes) |node| any = any or node.faults.degrade;
    if (!any) return;
    const delay_ns = baseline_delay_ns_min +
        sdk.random_below_named("network.baseline_delay_ns", baseline_delay_ns_max - baseline_delay_ns_min);
    baseline = .{
        .delay_ns = delay_ns,
        .jitter_ns = sdk.random_below_named("network.baseline_jitter_ns", delay_ns / 2),
        .loss_ppm = @intCast(sdk.random_below_named("network.baseline_loss_ppm", baseline_loss_ppm_max + 1)),
        .seed = sdk.random_u64(),
    };
    network_refresh(system);
    sdk.event("network_baseline", .{
        .delay_ns = baseline.?.delay_ns,
        .jitter_ns = baseline.?.jitter_ns,
        .loss_ppm = baseline.?.loss_ppm,
    });
}

/// Durable disks' latency for the timeline (the network has its baseline, disks theirs): each
/// I/O 0 to `disk_baseline_ms_max` ms, as a real disk's sync takes time. Named, as the
/// network's baseline is: a strategy's to steer.
fn disk_baseline_start(system: *const schema.System) void {
    var any = false;
    for (system.nodes) |node| any = any or node.faults.crash or node.faults.disk;
    if (!any) return;
    const delay_ms: u32 = @intCast(sdk.random_below_named("disk.baseline_ms", disk_baseline_ms_max + 1));
    nodes.disk_baseline_set(system, delay_ms) catch |err| {
        sdk.event("disk_baseline_failed", .{ .err = @errorName(err) });
        return;
    };
    sdk.event("disk_baseline", .{ .delay_ms = delay_ms });
}

fn degradable(system: *const schema.System, name: []const u8) bool {
    if (std.mem.eql(u8, name, schema.runner_name)) return true;
    const node = system.node(name) orelse return false;
    return node.faults.degrade;
}

/// One of `items`, drawn as a named decision over their names (sdk.decide): the value
/// sdk.random_choice draws, which a strategy steers by name (a device model's, a fault's).
fn choice_named(comptime T: type, name: []const u8, items: []const T) T {
    var names: [32][]const u8 = undefined;
    assert(items.len > 0 and items.len <= names.len);
    for (items, 0..) |item, index| names[index] = @tagName(item);
    return items[sdk.decide(name, names[0..items.len])];
}

/// netem settings for one flavor of degradation, every parameter a platform decision, named:
/// the network's model is a strategy's to steer (its delays, losses, rates; plans shape them).
fn degradation(flavor: Degradation) nodes.Netem {
    var netem = nodes.Netem{
        .delay_ns = sdk.random_below_named("fault.degrade.delay_ns", degrade_delay_ns_max),
        .seed = sdk.random_u64(),
    };
    switch (flavor) {
        .delay_loss => {
            netem.jitter_ns = sdk.random_below_named("fault.degrade.jitter_ns", degrade_delay_ns_max / 4);
            const percent = sdk.random_below_named("fault.degrade.loss_percent", degrade_loss_percent_max + 1);
            netem.loss_ppm = @intCast(percent * (nodes.Netem.ppm / 100));
        },
        .duplicate => netem.duplicate_percent = @intCast(1 + sdk.random_below_named("fault.degrade.duplicate_percent", 30)),
        .corrupt => netem.corrupt_percent = @intCast(1 + sdk.random_below_named("fault.degrade.corrupt_percent", 10)),
        .reorder => {
            netem.delay_ns = 1 + netem.delay_ns; // Reordering needs a delay to jump.
            netem.reorder_percent = @intCast(1 + sdk.random_below_named("fault.degrade.reorder_percent", 50));
        },
        .congestion => {
            const rate_min = 10 * 1024;
            netem.rate_bytes_per_second = @intCast(rate_min + sdk.random_below_named("fault.degrade.rate", 1024 * 1024));
        },
        // Losses in bursts (docs/SWARM.md, part 7): 1 to 5% of packets start one, each lasts 2
        // to 10 packets on average (leaving at 10 to 50%), every packet in it lost.
        .burst_loss => {
            netem.burst_enter_ppm = @intCast(10_000 + sdk.random_below_named("fault.degrade.burst_enter_ppm", 40_001));
            netem.burst_leave_ppm = @intCast(100_000 + sdk.random_below_named("fault.degrade.burst_leave_ppm", 400_001));
        },
    }
    return netem;
}

fn clock_shift(skip_ns: u64, direction: struct { forward: bool }) void {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    const now_ns: i128 = @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
    const shifted_ns = if (direction.forward) now_ns + skip_ns else now_ns - skip_ns;
    const shifted = linux.timespec{
        .sec = @intCast(@divFloor(shifted_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(shifted_ns, std.time.ns_per_s)),
    };
    _ = linux.clock_settime(.REALTIME, &shifted);
}

fn control_open() void {
    const fifo = linux.S.IFIFO | 0o622;
    const made = linux.mknodat(linux.AT.FDCWD, control_path, fifo, 0);
    if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return;
    // Read and write: the FIFO stays open with no writer, and never reports end of file.
    const flags: linux.O = .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) == .SUCCESS) control = @intCast(fd);
}

/// Sleeps for `duration_ns`, or less: a stop or a quiet-period request ends it (the caller
/// then undoes its fault; a request also heals the network). Network faults end on time
/// meanwhile.
fn sleep_ns(duration_ns: u64) void {
    const deadline_ns = monotonic_ns() + duration_ns;
    for (0..injections_max) |_| {
        busy_begin(); // Until it waits: what follows, and the caller's work after it returns.
        const now_ns = monotonic_ns();
        if (system_active) |system| {
            network_expire(system, now_ns);
            node_expire(system, now_ns);
        }
        rerandomize_due(now_ns);
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        const network_end = network_next_end() orelse deadline_ns;
        const node_end_ns = @min(node_next_end() orelse deadline_ns, aftershock_next() orelse deadline_ns);
        // Threads let go of but not yet stopped or reaped (threads_pending): soon again, not at
        // the next fault's end. A thread interrupted in a blocking call reports its stop only
        // after its pause began; killed meanwhile with its process, its exit follows that stop,
        // and until it is reaped its process's exit stays hidden (the selftest's `reaping`, its
        // children paused in pause(2), waited out a quiet period of 600 s for it).
        const pending_ns = if (threads_pending_count > 0) now_ns + threads_pending_poll_ns else deadline_ns;
        const watch_ns = if (disk_watching()) now_ns + disk_watch_poll_ns else deadline_ns;
        const wake_ns = @min(deadline_ns, network_end, node_end_ns, pending_ns, watch_ns, rerandomize_next_ns);
        const left_ns = wake_ns -| now_ns;
        busy_end();
        if (control < 0) {
            nodes.sleep_ns(left_ns);
            continue;
        }
        var timeout = linux.timespec{
            .sec = @intCast(left_ns / std.time.ns_per_s),
            .nsec = @intCast(left_ns % std.time.ns_per_s),
        };
        var poll = [1]linux.pollfd{.{ .fd = control, .events = linux.POLL.IN, .revents = 0 }};
        const result = linux.ppoll(&poll, 1, &timeout, null);
        if (linux.errno(result) == .INTR) return; // A stop.
        if (linux.errno(result) != .SUCCESS or result == 0) continue;
        // A quiet period healed what was under way as its request was read (before faults
        // injected after it): the caller undoes its own.
        if (requests_read() > 0) return;
    }
}

/// Sleeps the whole `duration_ns` (a stop still ends it), taking quiet-period requests.
fn sleep_through_ns(duration_ns: u64) void {
    const deadline_ns = monotonic_ns() + duration_ns;
    for (0..injections_max) |_| {
        const now_ns = monotonic_ns();
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        sleep_ns(deadline_ns - now_ns);
    }
}

/// A request on the control FIFO is a u64 (little endian): a quiet period in nanoseconds, or,
/// with its top bit set, the length (low 32 bits) of the JSON fault that follows (`inject`),
/// or, with `branch_flag`, the length (low 8 bits) of the node name that follows, "" for none
/// (`branch`), or with `aim_flag` the same for the node the scenario aims faults at (sdk's
/// `fault_aim`). Each fits in one write of at most PIPE_BUF: atomic.
const inject_flag: u64 = 1 << 63;
pub const branch_flag: u64 = 1 << 62;
pub const aim_flag: u64 = 1 << 61;
/// With the node's name as a branch's (low 8 bits its length): an aftershock asked for, a
/// moment that a power loss soon after would test (persist_trace's renames of unsynced data).
pub const aftershock_flag: u64 = 1 << 60;
/// With its body's length (low 16 bits): a crash point (`det-faults crash-point`), "<asked_ns>
/// <node>\n<point>".
pub const crash_point_flag: u64 = 1 << 59;
const crash_point_text_max = 1024;
/// The quiet period under way is the pacing's own (no node or command asked for it): a branch
/// point ends it.
var quiet_pacing = false;
/// When the pacing's last quiet stretch ends: a quiet period asked for and ended early returns
/// to it, not to faults (sdk.progress_while_quiet ends its window as soon as the system made
/// progress, and the stretches a slow system needs to recover in stay whole).
var pacing_quiet_until_ns: u64 = 0;
const request_size_max = 4096;

/// Takes the pending requests: injected faults are applied; the quiet period ends at the latest
/// one asks for; a branch point ends the pacing's. Returns how many requests end a sleep (quiet
/// periods and branch points).
fn requests_read() u32 {
    var buffer: [16 * request_size_max]u8 = undefined;
    const size = linux.read(control, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    var quiet: u32 = 0;
    var at: usize = 0;
    while (at + 8 <= size) {
        const header = std.mem.readInt(u64, buffer[at..][0..8], .little);
        at += 8;
        if (header & inject_flag != 0) {
            const length: usize = @intCast(header & 0xffff_ffff);
            if (at + length > size) break;
            inject(buffer[at..][0..length]);
            at += length;
            continue;
        }
        if (header & aim_flag != 0) {
            const length: usize = @intCast(header & 0xff);
            if (at + length > size) break;
            aim_set(buffer[at..][0..length]);
            at += length;
            continue;
        }
        if (header & aftershock_flag != 0) {
            const length: usize = @intCast(header & 0xff);
            if (at + length > size) break;
            if (system_active) |system| aftershock_asked(system, buffer[at..][0..length]);
            at += length;
            continue;
        }
        if (header & crash_point_flag != 0) {
            const length: usize = @intCast(header & 0xffff);
            if (at + length > size) break;
            if (system_active) |system| crash_point_asked(system, buffer[at..][0..length]);
            at += length;
            continue;
        }
        quiet += 1;
        if (header & branch_flag != 0) {
            const length: usize = @intCast(header & 0xff);
            if (at + length > size) break;
            branch_point(buffer[at..][0..length]);
            at += length;
            continue;
        }
        quiet_pacing = false; // A node or command asked: it stays, branch points or not.
        quiet_request(header);
    }
    return quiet;
}

/// A timeline begins here, at a moment of another: the pacing's quiet stretch ends, the sleep
/// under way returns, and the main loop draws a fault at once, aimed at `node` when one of the
/// faults involves it.
fn branch_point(node: []const u8) void {
    const quiet = quiet_pacing and quiet_until_ns > monotonic_ns();
    if (quiet) {
        quiet_until_ns = 0;
        quiet_pacing = false;
        pacing_quiet_until_ns = 0;
        crash_points_publish();
    }
    // The FIFO's header allows 255 bytes; det-agent sends at most branch_node_max.
    branch_node_size = @min(node.len, branch_node_max);
    @memcpy(branch_node[0..branch_node_size], node[0..branch_node_size]);
    sdk.event("faults_branch", .{ .quiet_ended = quiet, .node = node });
}

/// Why a drawn fault was this one: one involving the node a branch point named (the tree
/// returned there for it), one involving the node the scenario aims at (`sdk.fault_aim`: a
/// leader, a primary), a power loss soon after a node started again (`aftershock`), or any.
const Why = enum { branch_point, aimed, drawn, aftershock, crash_point };

/// The next fault's index: after a branch point, one of those involving its node (a named
/// decision: strategies see it, tapes replay it), when any does; else, while the scenario aims
/// at a node, one involving it half the time (named decisions too); else any (`fault`).
fn fault_choose(faults: []const Fault, names: []const []const u8) struct { index: usize, why: Why } {
    defer branch_node_size = 0;
    var aimed: [faults_max]usize = undefined;
    const branched = involving(faults, branch_node[0..branch_node_size], &aimed);
    if (branched > 0) return .{ .index = aimed[sdk.random_below_named("fault.branch_aim", branched)], .why = .branch_point };
    if (aim_node_size > 0 and sdk.random_below_named("fault.aim", 2) == 0) {
        const count = involving(faults, aim_node[0..aim_node_size], &aimed);
        if (count > 0) return .{ .index = aimed[sdk.random_below_named("fault.aimed", count)], .why = .aimed };
    }
    return .{ .index = fault_weighted(faults, names), .why = .drawn };
}

/// The indices of the faults that involve `node` (theirs, or the other end of a link), into
/// `aimed`; how many. None for "".
fn involving(faults: []const Fault, node: []const u8, aimed: *[faults_max]usize) usize {
    if (node.len == 0) return 0;
    var count: usize = 0;
    for (faults, 0..) |fault, index| {
        if (std.mem.eql(u8, fault.node, node) or std.mem.eql(u8, fault.peer, node)) {
            aimed[count] = index;
            count += 1;
        }
    }
    return count;
}

fn quiet_request(duration_ns: u64) void {
    // The fault under way ends where a quiet period begins.
    if (duration_ns > 0) if (system_active) |system| {
        network_heal(system);
        node_heal(system);
    };
    if (duration_ns == 0) {
        // A zero-length request ends the quiet period asked for (Antithesis's unpause); the
        // pacing's own stretch, under way, goes on to its end.
        const pacing_left = pacing_quiet_until_ns > monotonic_ns();
        quiet_until_ns = if (pacing_left) pacing_quiet_until_ns else 0;
        quiet_pacing = pacing_left;
        crash_points_publish();
        sdk.event("faults_resume", .{ .pacing_quiet_left = pacing_left });
        return;
    }
    quiet_until_ns = @max(quiet_until_ns, monotonic_ns() + duration_ns);
    crash_points_publish();
    sdk.event("faults_quiet", .{ .duration_ns = duration_ns, .until_ns = quiet_until_ns });
}

/// A fault the scenario asks for, as `det-faults inject` and the SDK's `fault` write it.
const Request = struct {
    kind: Kind,
    node: []const u8 = "",
    peer: []const u8 = "",
    duration_ms: u64 = 1000,
    /// partition_groups: the groups, by name ("runner" for the test commands' side).
    groups: []const []const []const u8 = &.{},
    disruption: Disruption = .stopped,
    direction: Direction = .both,
    flavor: Degradation = .delay_loss,
    cpu_percent: u8 = 20,
    /// clock_skip (permanent: later skips stack on it), clock_skew (the node's; with
    /// strobe_ms, coming and going that often).
    skip_ms: u64 = 0,
    strobe_ms: u64 = 0,
    forward: bool = true,
    program: []const u8 = "",
    /// syscall_error: the system call (its name, as `openat`) and its error (`NOSPC`); "" drawn.
    syscall: []const u8 = "",
    errno: []const u8 = "",
    /// file_error: the calls failed (null: drawn), with `errno` ("" drawn), one in `one_in`.
    file_calls: ?FileCalls = null,
    /// disk.
    failure: nodes.DiskFailure = .errors,
    delay_ms: u32 = 50,
    /// disk: one file's blocks alone (its path from the node's root), "" the whole disk.
    file: []const u8 = "",
    /// disk, corrupt_reads: the value the corrupted byte takes (null: drawn).
    corrupt_value: ?u8 = null,
    /// outage: the nodes that lose power (none named: every node that allows crashes), or with
    /// `power` false are killed (none named: every node that allows restarts).
    nodes: []const []const u8 = &.{},
    power: bool = true,
    /// durable_crash and sync_stall: one durability point in `one_in` is picked; interleave: one
    /// scheduling choice in `one_in` is drawn.
    one_in: u32 = 1,
    after_sync: bool = false,
    stall_ms_min: u32 = 1,
    stall_ms_max: u32 = 100,
    /// crash, durable_crash, an outage with power: part of what was not synced persists anyway
    /// (nodes.Partial), the journal committed after it with `partial_commit`.
    partial: bool = false,
    partial_commit: bool = false,
};

fn inject(json: []const u8) void {
    const system = system_active orelse return;
    var parse_buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const allocator = fixed.allocator();
    const request = std.json.parseFromSliceLeaky(Request, allocator, json, options) catch |err| {
        sdk.event("fault_inject_refused", .{ .err = @errorName(err) });
        return;
    };
    const applied = injected_applied(system, &request) catch |err| {
        const kind = @tagName(request.kind);
        sdk.event("fault_inject_refused", .{ .kind = kind, .err = @errorName(err) });
        return;
    };
    if (applied.kind == .clock_skip) {
        sdk.event("fault", applied);
        clock_shift(applied.skip_ns, .{ .forward = applied.forward });
        return;
    }
    apply(arena_active orelse return, system, &applied);
}

/// The fault a request describes; what it leaves out (which process, which thread) is drawn.
/// A request's string, copied for as long as the run.
fn request_string_kept(text: []const u8) ![]const u8 {
    const arena = arena_active orelse return error.NotStarted;
    return arena.dupe(u8, text);
}

fn injected_applied(system: *const schema.System, request: *const Request) !Applied {
    var applied = Applied{
        .kind = request.kind,
        .node = request.node,
        .peer = request.peer,
        .duration_ns = request.duration_ms * std.time.ns_per_ms,
        .injected = true,
    };
    if (request.partial) {
        applied.partial_seed = sdk.random_u64() | 1;
        applied.partial_commit = request.partial_commit;
    }
    // Its names the system's own, and its strings the run's: the request's are in inject's
    // parse buffer, on its stack, and a node fault keeps them until it ends (its end undid the
    // fault on the name left in that stack: a scenario's file errors never ended, e2e
    // file_error 2026-11-10, once the injector's frames had moved).
    if (request.node.len > 0) {
        applied.node = endpoint_name(system, endpoint_index(system, request.node) orelse return error.UnknownNode);
    }
    if (request.peer.len > 0) {
        applied.peer = endpoint_name(system, endpoint_index(system, request.peer) orelse return error.UnknownNode);
    }
    switch (request.kind) {
        .throttle => applied.cpu_percent = request.cpu_percent,
        .process_pause, .process_kill, .pod_pause, .pod_kill, .pod_isolate => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_partition, .signal => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(processes_max));
        },
        // A scenario names the call, its error and how often (every call by default), or the
        // injector's draws fill in what it leaves out.
        .syscall_error => {
            syscall_error_draw(&applied);
            if (request.syscall.len > 0) applied.syscall = try request_string_kept(request.syscall);
            if (request.errno.len > 0) applied.errno = try request_string_kept(request.errno);
            applied.one_in = @max(request.one_in, 1);
        },
        .file_error => {
            file_error_draw(&applied);
            if (request.file_calls) |calls| applied.file_calls = calls;
            if (request.errno.len > 0) applied.errno = try request_string_kept(request.errno);
            applied.one_in = @max(request.one_in, 1);
        },
        .pod_degrade => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            const flavor = choice_named(Degradation, "fault.degrade.flavor", std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
        },
        .thread_pause => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(threads_max));
        },
        .degrade => {
            applied.flavor = request.flavor;
            applied.netem = degradation(request.flavor);
        },
        .clog => {
            applied.disruption = request.disruption;
            applied.direction = request.direction;
        },
        .swizzle => {
            // The nodes named (every one that allows isolation when none is), orders drawn.
            var chosen: [endpoints_max]bool = @splat(false);
            for (system.nodes, 1..) |node, index| chosen[index] = request.nodes.len == 0 and node.faults.isolate;
            for (request.nodes) |name| {
                const index = endpoint_index(system, name) orelse return error.UnknownNode;
                if (index == 0) return error.UnknownNode;
                chosen[index] = true;
            }
            if (std.mem.count(bool, &chosen, &.{true}) < 2) return error.FewerThanTwoNodes;
            swizzle_draw(&applied, chosen);
            applied.disruption = request.disruption;
        },
        .partition_groups => {
            if (request.groups.len < 2) return error.FewerThanTwoGroups;
            for (request.groups, 0..) |group, number| {
                for (group) |name| {
                    const index = endpoint_index(system, name) orelse return error.UnknownNode;
                    applied.groups[index] = @intCast(number);
                }
            }
            applied.disruption = request.disruption;
            applied.direction = request.direction;
        },
        .clock_skip => {
            applied.skip_ns = request.skip_ms * std.time.ns_per_ms;
            applied.forward = request.forward;
            applied.permanent = true;
        },
        .clock_skew => {
            applied.skip_ns = request.skip_ms * std.time.ns_per_ms;
            applied.forward = request.forward;
            applied.strobe_ns = request.strobe_ms * std.time.ns_per_ms;
        },
        .custom => applied.program = try request_string_kept(request.program),
        .outage => {
            applied.power = request.power;
            for (system.nodes, 1..) |node, index| applied.outage[index] = request.nodes.len == 0 and
                if (request.power) node.faults.crash else node.faults.restart;
            for (request.nodes) |name| {
                const index = endpoint_index(system, name) orelse return error.UnknownNode;
                if (index == 0) return error.UnknownNode; // The runner has no power to lose.
                applied.outage[index] = true;
            }
            if (std.mem.count(bool, &applied.outage, &.{true}) < 2) return error.FewerThanTwoNodes;
        },
        .interleave => applied.one_in = @max(request.one_in, 1),
        .durable_crash, .sync_stall => {
            applied.one_in = @max(request.one_in, 1);
            applied.after_sync = request.after_sync;
            applied.stall_ms_min = request.stall_ms_min;
            applied.stall_ms_max = request.stall_ms_max;
        },
        .disk => applied.disk = .{
            .failure = request.failure,
            .delay_ms = request.delay_ms,
            .corrupt_byte = @intCast(1 + sdk.random_below_named("fault.disk.corrupt_byte", disk_sector_size)),
            .corrupt_value = request.corrupt_value orelse @intCast(sdk.random_below_named("fault.disk.corrupt_value", 256)),
            .file = try request_string_kept(request.file),
        },
        else => {},
    }
    return applied;
}

/// `det-faults inject '<json>'`: asks the running injector for that fault now.
/// Tells the running injector a timeline begins here (det-agent, on the platform's `det:branch`),
/// and at which node (the newest behavior's, "" for none) its first fault aims. Without an
/// injector (no driver phase under way), nothing to do.
pub fn branch_request(node: []const u8) void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var message: [8 + branch_node_max]u8 = undefined;
    const size = @min(node.len, branch_node_max);
    std.mem.writeInt(u64, message[0..8], branch_flag | size, .little);
    @memcpy(message[8..][0..size], node[0..size]);
    _ = linux.write(@intCast(fd), &message, 8 + size);
}

const branch_node_max = 32;
/// The node a branch point aims the next fault at (cleared once drawn).
var branch_node: [branch_node_max]u8 = undefined;
var branch_node_size: usize = 0;
/// The node the scenario aims faults at (sdk's `fault_aim`: a primary, a leader it found), until
/// it names another or none.
var aim_node: [branch_node_max]u8 = undefined;
var aim_node_size: usize = 0;

fn aim_set(node: []const u8) void {
    var previous_buffer: [branch_node_max]u8 = undefined;
    const previous_size = aim_node_size;
    @memcpy(previous_buffer[0..previous_size], aim_node[0..previous_size]);
    const previous = previous_buffer[0..previous_size];
    aim_node_size = @min(node.len, branch_node_max);
    @memcpy(aim_node[0..aim_node_size], node[0..aim_node_size]);
    sdk.event("faults_aim", .{ .node = aim_node[0..aim_node_size] });
    // The scenario aims at the node that matters (a leader, a primary, a coordinator): another
    // one now means it moved, a rare state the tree returns to first (what follows a failover is
    // where systems break). Computed: a system that never moves it is not failed for it.
    const current = aim_node[0..aim_node_size];
    if (previous.len > 0 and current.len > 0 and !std.mem.eql(u8, previous, current)) {
        // `node`: a branch from just after it aims its first fault at the new one.
        sdk.assert_computed(.sometimes, true, "the aimed node moved (a leader or primary changed)", .{
            .from = previous,
            .node = current,
        });
    }
}

fn inject_request(json: []const u8) !void {
    return control_request(inject_flag, json);
}

/// One request on the control FIFO: `flag` with the length of `body`, then `body`.
fn control_request(flag: u64, body: []const u8) !void {
    if (body.len + 8 > request_size_max) return error.RequestTooLarge;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) {
        std.debug.print("det-faults: no fault injector is running (faults happen while " ++
            "drivers run)\n", .{});
        return error.NoInjector;
    }
    defer _ = linux.close(@intCast(fd));
    var message: [request_size_max]u8 = undefined;
    std.mem.writeInt(u64, message[0..8], flag | body.len, .little);
    @memcpy(message[8..][0..body.len], body);
    const written = linux.write(@intCast(fd), &message, body.len + 8);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
}

test "outages take only the nodes that allow them" {
    const base = schema.Resolved{
        .name = "a",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [3]schema.Resolved{ base, base, base };
    resolved[1].name = "b";
    resolved[2].name = "c";
    const scenario = schema.Scenario{ .name = "s", .commands = &.{} };
    var faults: [faults_max]Fault = undefined;
    // Restarts on all three: a kill outage among them.
    for (&resolved) |*node| node.faults = .{ .restart = true };
    var system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var count = faults_collect(&system, &scenario, &faults);
    const with_outage = for (faults[0..count]) |fault| {
        if (fault.kind == .outage) break true;
    } else false;
    try std.testing.expect(with_outage);
    // The same nodes with outages off (Cassandra's periodic commitlog): their restarts stay, one
    // node at a time, and no outage is drawn.
    for (&resolved) |*node| node.faults = .{ .restart = true, .outage = false };
    system = .{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    count = faults_collect(&system, &scenario, &faults);
    var restarts: u32 = 0;
    for (faults[0..count]) |fault| {
        try std.testing.expect(fault.kind != .outage);
        restarts += @intFromBool(fault.kind == .restart);
    }
    try std.testing.expectEqual(@as(u32, 3), restarts);
}

test "every fault of a system of schema.nodes_max nodes is listed: its last node's, its groups', its restore" {
    var names: [schema.nodes_max][3]u8 = undefined;
    var resolved: [schema.nodes_max]schema.Resolved = undefined;
    for (&resolved, 0..) |*node, index| {
        node.* = .{
            .name = std.fmt.bufPrint(&names[index], "n{d:0>2}", .{index}) catch unreachable,
            .address = "10.0.0.2",
            .disk = "vdb",
            .digest = "",
            .command = &.{"x"},
            .env = &.{},
            // Every kind a node can allow, and two custom programs.
            .faults = .{
                .restart = true,
                .crash = true,
                .wipe = true,
                .stop = true,
                .disk = true,
                .clock_skew = true,
                .process_kill = true,
                .signals = true,
                .syscall_errors = true,
                .file_errors = true,
                .pods = true,
                .custom = &.{ "a", "b" },
            },
        };
    }
    const scenario = schema.Scenario{ .name = "s", .commands = &.{}, .clock_skip = true };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    const count = faults_collect(&system, &scenario, &faults);
    const last = resolved[schema.nodes_max - 1].name;
    var last_stops: u32 = 0;
    var stops: u32 = 0;
    var partitions: u32 = 0;
    var kinds: std.EnumSet(Kind) = .empty;
    for (faults[0..count]) |fault| {
        kinds.insert(fault.kind);
        stops += @intFromBool(fault.kind == .stop);
        last_stops += @intFromBool(fault.kind == .stop and std.mem.eql(u8, fault.node, last));
        partitions += @intFromBool(fault.kind == .partition);
    }
    // A table of 256 was full after the first ten nodes: the rest were never stopped, and the
    // groups and the restore, listed last, were not there at all.
    try std.testing.expectEqual(@as(u32, 0), faults_dropped);
    try std.testing.expectEqual(@as(u32, schema.nodes_max), stops);
    try std.testing.expectEqual(@as(u32, 1), last_stops);
    // A link with the runner each, and one between every two nodes.
    try std.testing.expectEqual(@as(u32, schema.nodes_max + schema.nodes_max * (schema.nodes_max - 1) / 2), partitions);
    for ([_]Kind{ .partition_groups, .swizzle, .outage, .clock_skip, .restore, .clog, .custom, .pod_partition }) |kind| {
        try std.testing.expect(kinds.contains(kind));
    }
}

test faults_collect {
    const node_faults = schema.Faults{ .pause = true, .isolate = false, .restart = true };
    const base = schema.Resolved{
        .name = "a",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[0].faults = node_faults;
    resolved[1].name = "b";
    resolved[1].faults = .{ .clock_skew = true };
    const scenario = schema.Scenario{ .name = "s", .commands = &.{}, .clock_skip = true };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    // a: pause, restart, throttle, process pause; with the runner and with b: partition and
    // degrade both ways (6). b: pause, isolate, throttle, clock skew, process pause; with the
    // runner: partition and degrade both ways (3). Thread pauses where process pauses are (2).
    // Sync stalls and interleavings (on by default) on both (4). A clog of b (it allows
    // isolation), groups across the runner, a and b. Clock skip. A restore.
    try std.testing.expectEqual(@as(u32, 28), faults_collect(&system, &scenario, &faults));
    const groups = faults[0..28];
    const has_groups = for (groups) |fault| {
        if (fault.kind == .partition_groups) break true;
    } else false;
    try std.testing.expect(has_groups);
    // b's clock skews reach its largest, ten seconds by default (10^10 ns: past u32).
    const skew = for (groups) |fault| {
        if (fault.kind == .clock_skew) break fault;
    } else unreachable;
    try std.testing.expectEqualStrings("b", skew.node);
    try std.testing.expectEqual(10 * std.time.ns_per_s, skew.skew_ns_max);
    try std.testing.expectEqual(Kind.restore, faults[27].kind); // The last one.
}

test skew_clamped {
    var resolved = [2]schema.Resolved{
        .{ .name = "a", .address = "10.0.0.2", .disk = "vdb", .digest = "", .command = &.{"x"}, .env = &.{} },
        .{ .name = "b", .address = "10.0.0.3", .disk = "vdc", .digest = "", .command = &.{"x"}, .env = &.{} },
    };
    for (&resolved) |*node| node.faults = .{ .clock_skew = true, .clock_skew_ms_max = 300 };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{} };
    const ms = std.time.ns_per_ms;
    // b is 250 ms ahead: a may go back at most 50 ms, and ahead up to its largest, 300.
    nodes_faulted[1][@backingInt(Layer.condition)] = .{ .applied = .{ .kind = .clock_skew, .node = "b", .duration_ns = 0, .skip_ns = 250 * ms, .forward = true }, .end_ns = 0 };
    defer nodes_faulted[1][@backingInt(Layer.condition)] = null;
    const back: Applied = .{ .kind = .clock_skew, .node = "a", .duration_ns = 0, .skip_ns = 300 * ms, .forward = false };
    try std.testing.expectEqual(@as(?i64, -50 * ms), skew_clamped(&system, &back));
    const ahead: Applied = .{ .kind = .clock_skew, .node = "a", .duration_ns = 0, .skip_ns = 200 * ms, .forward = true };
    try std.testing.expectEqual(@as(?i64, 200 * ms), skew_clamped(&system, &ahead));
    // Asked for by the scenario: as asked.
    var asked = back;
    asked.injected = true;
    try std.testing.expectEqual(@as(?i64, -300 * ms), skew_clamped(&system, &asked));
}

test fault_choose {
    const faults = [_]Fault{
        .{ .kind = .pause, .node = "a" },
        .{ .kind = .pause, .node = "b" },
        .{ .kind = .partition, .node = "a", .peer = "b" },
        .{ .kind = .pause, .node = "c" },
    };
    const names = [_][]const u8{ "pause a", "pause b", "partition a b", "pause c" };
    // Faults drawn uniformly, not by kind (another test's swarm leaves kinds weighted: then two
    // in three involve b unaimed, and this test failed whenever it ran after that one).
    const weighted = kinds_weighted;
    defer kinds_weighted = weighted;
    kinds_weighted = false;
    // Aimed at b: half the draws among its two faults, the other half any (two of four its):
    // three in four involve it. Not aimed: two in four.
    for ([_]struct { []const u8, u32, u32 }{ .{ "b", 240, 360 }, .{ "", 140, 260 } }) |case| {
        // As aim_set sets it (without its event).
        @memcpy(aim_node[0..case[0].len], case[0]);
        aim_node_size = case[0].len;
        defer aim_node_size = 0;
        var involving_b: u32 = 0;
        for (0..400) |_| {
            const fault = faults[fault_choose(&faults, &names).index];
            if (std.mem.eql(u8, fault.node, "b") or std.mem.eql(u8, fault.peer, "b")) involving_b += 1;
        }
        try std.testing.expect(involving_b >= case[1] and involving_b <= case[2]);
    }
}

test harsher {
    const stopped = nodes.Netem{ .delay_ns = 0, .loss_ppm = nodes.Netem.ppm, .seed = 0 };
    const jammed = nodes.Netem{ .delay_ns = 400 * std.time.ns_per_ms, .seed = 0 };
    const slowed = nodes.Netem{ .delay_ns = 60 * std.time.ns_per_ms, .seed = 0 };
    try std.testing.expect(harsher(stopped, jammed));
    try std.testing.expect(harsher(jammed, slowed));
    try std.testing.expect(!harsher(slowed, stopped));
}

test groups_draw {
    var allowed: [endpoints_max]bool = @splat(false);
    for (allowed[0..4]) |*ok| ok.* = true;
    for (0..64) |_| {
        const groups = groups_draw(allowed);
        for (groups[4..]) |group| try std.testing.expectEqual(@as(u16, group_none), group);
        const split = for (groups[1..4]) |group| {
            if (group != groups[0]) break true;
        } else false;
        try std.testing.expect(split);
    }
}

test disrupted_links {
    const base = schema.Resolved{
        .name = "a",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[1].name = "b";
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{} };
    var groups: [endpoints_max]u16 = @splat(group_none);
    groups[0] = 0; // runner
    groups[1] = 0; // a
    groups[2] = 1; // b
    const partition = Applied{
        .kind = .partition_groups,
        .duration_ns = 1,
        .disruption = .jammed,
        .groups = groups,
    };
    var links: [directed_max]Directed = undefined;
    // b is cut from the runner and from a, both ways.
    try std.testing.expectEqual(@as(u32, 4), disrupted_links(&system, &partition, &links));
    const clog = Applied{
        .kind = .clog,
        .node = "a",
        .duration_ns = 1,
        .disruption = .stopped,
        .direction = .inbound,
    };
    // Into a: from the runner and from b.
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &clog, &links));
}

test "a node that takes no network faults keeps its links when another node is isolated or clogged" {
    const base = schema.Resolved{
        .name = "raft-node-1",
        .address = "10.0.0.3",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [3]schema.Resolved{ base, base, base };
    resolved[1].name = "raft-node-2";
    resolved[2].name = "raft-monitor"; // --no-faults raft-monitor: every kind off.
    const info = @typeInfo(schema.Faults).@"struct";
    inline for (info.field_names, info.field_types) |field, Type| {
        if (Type == bool) @field(resolved[2].faults, field) = false;
    }
    const scenario = schema.Scenario{ .name = "s", .commands = &.{} };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    // Endpoints: 0 the runner, 1 raft-node-1, 2 raft-node-2, 3 raft-monitor.
    const isolate = Applied{ .kind = .isolate, .node = "raft-node-1", .duration_ns = 1 };
    try std.testing.expect(cuts_link(&system, &isolate, 1, 2));
    try std.testing.expect(cuts_link(&system, &isolate, 0, 1));
    // The POC's node, restarted while isolated, could not reach its monitor and exited (runs
    // 871 and 872): the monitor's link stays.
    try std.testing.expect(!cuts_link(&system, &isolate, 1, 3));
    try std.testing.expect(!cuts_link(&system, &isolate, 3, 1));
    const clog = Applied{ .kind = .clog, .node = "raft-node-1", .duration_ns = 1, .disruption = .stopped, .direction = .both };
    var links: [directed_max]Directed = undefined;
    // Both ways with the runner and raft-node-2, none with the monitor.
    try std.testing.expectEqual(@as(u32, 4), disrupted_links(&system, &clog, &links));
}

test "runner_links: a client node's link with the runner is never faulted" {
    const base = schema.Resolved{
        .name = "server",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[1].name = "client";
    resolved[1].faults.runner_links = false;
    const scenario = schema.Scenario{ .name = "s", .commands = &.{} };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    const count = faults_collect(&system, &scenario, &faults);
    var client_server: u32 = 0;
    for (faults[0..count]) |fault| {
        if (fault.kind != .partition and fault.kind != .degrade) continue;
        const node_client = std.mem.eql(u8, fault.node, "client");
        const peer_client = std.mem.eql(u8, fault.peer, "client");
        const node_runner = std.mem.eql(u8, fault.node, schema.runner_name);
        const peer_runner = std.mem.eql(u8, fault.peer, schema.runner_name);
        try std.testing.expect(!(node_client and peer_runner) and !(node_runner and peer_client));
        if (std.mem.eql(u8, fault.node, "client") or std.mem.eql(u8, fault.peer, "client")) {
            client_server += 1;
        }
    }
    // Its links with the server are: a partition and a degradation each way.
    try std.testing.expectEqual(@as(u32, 3), client_server);
    var groups: [endpoints_max]u16 = @splat(group_none);
    groups[0] = 0; // runner
    groups[1] = 0; // server
    groups[2] = 1; // client
    const partition = Applied{
        .kind = .partition_groups,
        .duration_ns = 1,
        .disruption = .stopped,
        .groups = groups,
    };
    var links: [directed_max]Directed = undefined;
    // The client is cut from the server only, both ways.
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &partition, &links));
    const clog = Applied{
        .kind = .clog,
        .node = "client",
        .duration_ns = 1,
        .disruption = .stopped,
        .direction = .both,
    };
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &clog, &links));
    const isolate = Applied{ .kind = .isolate, .node = "client", .duration_ns = 1 };
    try std.testing.expect(!cuts_link(&system, &isolate, 0, 2));
    try std.testing.expect(cuts_link(&system, &isolate, 1, 2));
}
