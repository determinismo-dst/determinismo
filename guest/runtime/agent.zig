// SPDX-License-Identifier: MIT
//! det-agent: runs commands the platform pushes into the guest at a chosen moment (multiverse
//! debugging: "at this moment, run this"). It sleeps in the guest module until the platform
//! raises its interrupt, so timelines that push nothing never see it run.
//!
//! For each action (a shell command line) it emits `exec_start`, the command's output as
//! `exec_output` events, and `exec_done` with the exit status, each with the action's `id` (its
//! number). `det:background <command>` runs the command beside the next ones (Antithesis's
//! run_in_background): its exec_start says `"background":true` as soon as it is started (the
//! platform goes on to the next step then), its output and exec_done follow as it runs.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const faults = @import("faults.zig");

/// The platform's action where a timeline begins at a moment of another (VM.Options
/// .branch_signal): not a command, no events; the fault injector hears of it (faults.zig).
const branch_action = "det:branch";
const background_action = "det:background ";
/// A moment's script with steps of the platform's (a wait, a background command) holds the
/// timeline from its end (det-init waits for hold_path, as for busy_path) until it releases it.
/// `det:explore-here`: the fast VM explored from here (docs/DEVELOPING.md). Its other CPUs go
/// offline, the platform saves the machine (sdk.explore_here), and then: in the fast VM, the
/// CPUs come back; in a timeline started from it, the dev mode's composer starts the timeline.
const explore_here_action = "det:explore-here";
const hold_action = "det:hold";
const release_action = "det:release";
/// A fresh future from the moment (VM.Options.fresh_seed): the kernel's generator reseeded from
/// a platform decision (now drawn from the new seed), so what processes draw afresh differs from
/// the timeline's too, and the fault injector perturbs at once, as at a tree's branch point.
/// Written as a shell no-op (`:`): an agent older than it runs it, harmlessly.
const reseed_action = ": det:reseed";
/// `det:send <path> <base64>`: the bytes written to a file or FIFO there, no command run (a
/// session's REPL: each message to the relay's FIFO, det-nrepl-relay serve, without a process
/// started for it). Not a command: no events but its end.
const send_action = "det:send ";
pub const hold_path = "/run/det-agent-hold";
/// `det:frozen <command>`: the command run with the rest of the guest held still (frozen_run),
/// so that what it reads is the moment's, not a moment its own run let the system reach (a
/// paused probe's long read went on past a node's crash: local-fs run 742, timeline 261).
const frozen_action = "det:frozen ";
/// Where frozen_run holds the root cgroup's processes for a step: a cgroup of its own only
/// then, since the cpu controller root gives its children would otherwise make the runner's side
/// one group against the nodes, where each of its processes is one task beside them.
const held_cgroup = "/sys/fs/cgroup/det-held";
const nodes_cgroup = "/sys/fs/cgroup/nodes";
const root_procs = "/sys/fs/cgroup/cgroup.procs";
/// `det:scenario-pause`: the scenario's own processes (the runner, the composer and its drivers,
/// the fault injector, the test program, all they started) frozen, the nodes and what serves them
/// (the sinks draining their output, det-nodes) left running: a person's session at a moment, the
/// system answering only them (a REPL inside the guest beside the workload's clients and faults
/// competed with both). `det:scenario-resume` undoes it. A cgroup of its own: det:frozen's thaws
/// what it froze, never these.
const scenario_pause_action = "det:scenario-pause";
const scenario_resume_action = "det:scenario-resume";
const scenario_cgroup = "/sys/fs/cgroup/det-scenario-paused";
/// The scenario's processes by name (/proc/<pid>/comm), and whatever descends from them.
const scenario_comms = [_][]const u8{ "det-runner", "det-composer", "det-faults", "program" };
/// The kernel's thread maker: every kernel thread is its child (pid 1 is det-init).
const kthreadd: linux.pid_t = 2;

/// det:send's: "<path> <base64>" decoded and written there with one write; its status.
/// The CPUs past the first, offline (or online again): Linux's CPU hotplug, by sysfs.
fn cpus_online(online: bool) u32 {
    var changed: u32 = 0;
    var path_buffer: [64]u8 = undefined;
    for (1..cpus_max) |cpu| {
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/sys/devices/system/cpu/cpu{d}/online", .{cpu}, 0) catch unreachable;
        const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) continue; // Absent: past the machine's CPUs.
        defer _ = linux.close(@intCast(fd));
        const text = if (online) "1" else "0";
        if (linux.errno(linux.write(@intCast(fd), text.ptr, 1)) == .SUCCESS) changed += 1;
    }
    return changed;
}

const cpus_max = 32; // The fast VM's most (src/mptable.zig).

/// CPU 0 off its LAPIC timer (KVM's, on host time) and onto the PIT, the timer a deterministic
/// machine drives: Linux takes the next device it has when one is unbound. Once is enough: CPU
/// 0 keeps the PIT after (a later explore-here finds no lapic to unbind).
fn cpu0_on_pit() bool {
    // Its device now ("lapic", or "lapic-deadline" with TSC-deadline mode).
    var name_buffer: [64]u8 = undefined;
    const current = linux.open("/sys/devices/system/clockevents/clockevent0/current_device", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(current) != .SUCCESS) return false;
    const size = linux.read(@intCast(current), &name_buffer, name_buffer.len);
    _ = linux.close(@intCast(current));
    if (linux.errno(size) != .SUCCESS) return false;
    const name = std.mem.trim(u8, name_buffer[0..size], " \n");
    if (!std.mem.startsWith(u8, name, "lapic")) return false; // On the PIT already.
    const unbind = linux.open("/sys/devices/system/clockevents/clockevent0/unbind_device", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(unbind) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(unbind));
    return linux.errno(linux.write(@intCast(unbind), name.ptr, name.len)) == .SUCCESS;
}

/// Null when it said itself done already (a held machine's, before saying it is held).
fn explore_here() ?u8 {
    const offline = cpus_online(false);
    const moved = cpu0_on_pit();
    sdk.event("explore_here_ready", .{ .offline = offline, .pit = moved });
    const where = sdk.explore_here();
    if (where == .held) {
        // A held machine: its own commands come as actions, the scenario never starts. Its
        // kernel's randomness reseeded here, as the composer's timelines part does (a decision:
        // each timeline its own, every replay the same): else every timeline from the snapshot
        // drew the same bytes, and a CI shard's flaky test agreed in all of them.
        kernel_reseed();
        // Done, then held: the platform's command for it (explore --exec-at-start, at this event)
        // comes after this step's end, never taken for it.
        done(0, 0, false);
        sdk.event("explore_here_held", .{ .offline = offline });
        return null;
    }
    if (where == .timeline) {
        // Its settings first (the platform's next action, sent with the answer): the composer
        // and the fault injector read them, not the fast VM's command line.
        timeline_cmdline_take();
        // A timeline: the dev mode's composer, waiting, starts it.
        const fd = linux.open(sdk.dev_go_path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return 1;
        defer _ = linux.close(@intCast(fd));
        _ = linux.write(@intCast(fd), "go\n", 3);
        return 0;
    }
    const online = cpus_online(true);
    sdk.event("explore_here_done", .{ .offline = offline, .online = online });
    return 0;
}

/// The timeline's command line, the platform's action `det:cmdline <line>` given with the
/// explore-here answer, written to sdk.timeline_cmdline_path (none given: nothing written, the
/// kernel's stays).
fn timeline_cmdline_take() void {
    const device = linux.open(sdk.device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(device) != .SUCCESS) return;
    defer _ = linux.close(@intCast(device));
    var buffer: [action_size_max + 1]u8 = undefined;
    const result = while (true) {
        const waited = linux.ioctl(@intCast(device), ioctl_wait_action, @intFromPtr(&buffer));
        if (linux.errno(waited) == .INTR) continue;
        if (linux.errno(waited) != .SUCCESS) return;
        if (waited == 0) continue; // Woken without an action.
        break waited;
    };
    const action = buffer[0..result];
    if (!std.mem.startsWith(u8, action, cmdline_action)) return;
    const line = action[cmdline_action.len..];
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(sdk.timeline_cmdline_path ++ ".part", flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), line.ptr, line.len);
    _ = linux.close(@intCast(fd));
    _ = linux.rename(sdk.timeline_cmdline_path ++ ".part", sdk.timeline_cmdline_path);
}

const cmdline_action = "det:cmdline ";

fn send(arguments: []const u8) u8 {
    const space = std.mem.indexOfScalar(u8, arguments, ' ') orelse return 2;
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{arguments[0..space]}, 0) catch return 2;
    const encoded = std.mem.trim(u8, arguments[space + 1 ..], " \n");
    var bytes_buffer: [action_size_max]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return 2;
    if (size > bytes_buffer.len) return 2;
    decoder.decode(bytes_buffer[0..size], encoded) catch return 2;
    // A FIFO's reader holds it open (det-nrepl-relay serve): opened, never waited on.
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .APPEND = true, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    const written = linux.write(@intCast(fd), &bytes_buffer, size);
    if (linux.errno(written) != .SUCCESS or written != size) return 1;
    return 0;
}

const action_size_max = sdk.message_size_max;
/// Output travels in events, which are JSON-escaped: keep chunks well under the event limit.
const output_chunk_size = 1024;
/// How much of a command its exec_start event shows.
const command_shown_max = 512;
const ioctl_wait_action = 0xde01;
const actions_max = 1_000_000;
const output_chunks_max = 1 << 20;
/// Exists while a command runs: det-init waits for it before ending the timeline, so that a
/// command at a moment near the end still finishes.
pub const busy_path = "/run/det-agent-busy";

pub fn main() !void {
    const device = linux.open(sdk.device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(device) != .SUCCESS) return; // Not inside determinismo: nothing to serve.
    var action_buffer: [action_size_max + 1]u8 = undefined;
    for (0..actions_max) |_| {
        const buffer_address = @intFromPtr(&action_buffer);
        const result = linux.ioctl(@intCast(device), ioctl_wait_action, buffer_address);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return error.WaitFailed;
        if (result == 0) continue; // Woken without an action.
        assert(result <= action_size_max);
        action_buffer[result] = 0;
        const action = action_buffer[0..result :0];
        if (std.mem.startsWith(u8, action, branch_action)) {
            // "det:branch" and, after a space, the node the branch aims its first fault at.
            const rest = action[branch_action.len..];
            // The branch's guest randomness: its parent's stream kept (the siblings then differ by
            // their faults and timing alone), or the kernel's generator reseeded (the programs'
            // fresh draws leave the parent's). A decision, learned from (random_config), never one
            // policy for every branch: Antithesis re-randomizes about 28% of its rollouts.
            if (sdk.random_config("entropy.branch_reseed", 2) == 1) kernel_reseed();
            faults.branch_request(if (rest.len > 1 and rest[0] == ' ') rest[1..] else "");
            continue;
        }
        background_reap();
        if (std.mem.eql(u8, action, reseed_action)) {
            kernel_reseed();
            faults.branch_request("");
            done(0, 0, false); // Not a command: id 0.
            continue;
        }
        if (std.mem.startsWith(u8, action, send_action)) {
            done(send(action[send_action.len..]), 0, false);
            continue;
        }
        if (std.mem.eql(u8, action, explore_here_action)) {
            // Not a command: id 0. A held machine's says itself done first (explore_here).
            if (explore_here()) |status| done(status, 0, false);
            continue;
        }
        if (std.mem.eql(u8, action, scenario_pause_action) or std.mem.eql(u8, action, scenario_resume_action)) {
            const paused = std.mem.eql(u8, action, scenario_pause_action);
            const moved = if (paused) scenario_pause() else scenario_resume();
            sdk.event(if (paused) "scenario_paused" else "scenario_resumed", .{ .processes = moved });
            done(0, 0, false); // Not a command: id 0.
            continue;
        }
        if (std.mem.eql(u8, action, hold_action) or std.mem.eql(u8, action, release_action)) {
            if (std.mem.eql(u8, action, hold_action)) {
                const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
                const hold = linux.open(hold_path, flags, 0o644);
                if (linux.errno(hold) == .SUCCESS) _ = linux.close(@intCast(hold));
            } else _ = linux.unlink(hold_path);
            done(0, 0, false); // Not a command: id 0.
            continue;
        }
        actions += 1;
        if (std.mem.startsWith(u8, action, frozen_action)) {
            const command = action[frozen_action.len.. :0];
            if (command.len == 0) continue;
            frozen_run(command, actions);
            continue;
        }
        if (std.mem.startsWith(u8, action, background_action)) {
            const command = action[background_action.len.. :0];
            if (command.len == 0) continue;
            const pid = linux.fork();
            if (pid == 0) {
                run(command, actions, true);
                linux.exit_group(0);
            }
            if (linux.errno(pid) != .SUCCESS) {
                sdk.event("exec_done", .{ .status = 126, .id = actions, .background = true });
            }
            continue;
        }
        run(action, actions, false);
    }
}

/// The guest kernel's random generator reseeded from a platform decision (composer.zig's
/// kernel_reseed, at setup_complete, does the same for every timeline).
fn kernel_reseed() void {
    const rnd_add_entropy = 0x40085203; // _IOW('R', 3, int[2])
    const rnd_reseed_crng = 0x5207; // _IO('R', 7)
    const seed_size = 32;
    var request: extern struct { bits: i32, size: i32, bytes: [seed_size]u8 } = .{
        .bits = seed_size * 8,
        .size = seed_size,
        .bytes = undefined,
    };
    sdk.random_bytes(&request.bytes);
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.ioctl(@intCast(fd), rnd_add_entropy, @intFromPtr(&request));
    _ = linux.ioctl(@intCast(fd), rnd_reseed_crng, 0);
}

/// Commands started so far: each one's id.
var actions: u32 = 0;

/// Background commands that ended (their processes, the agent's children) are reaped.
/// `command` run with every process but the agent's own, det-init's and the kernel's held: the
/// nodes' cgroup frozen, and the root cgroup's processes (the runner, the composer, the fault
/// injector, the drivers and what they started, the sinks) moved into a cgroup of their own,
/// frozen too, and moved back after. The kernel's own work goes on (a journal commit in flight
/// completes), as do the agent's background commands. A command that enters a node (det-nodes
/// exec) waits for it: what it reads of a node is read from outside (/proc, the node's root under
/// /run/det/nodes).
fn frozen_run(command: [:0]const u8, id: u32) void {
    _ = linux.mkdir(held_cgroup, 0o755);
    // Again until none is left: a process not yet moved may fork meanwhile.
    for (0..8) |_| {
        if (procs_move(root_procs, held_cgroup ++ "/cgroup.procs", true) == 0) break;
    }
    const cgroups = [_][]const u8{ held_cgroup, nodes_cgroup };
    for (cgroups) |cgroup| freeze_write(cgroup, "1");
    // Frozen, but for a task inside the kernel, which freezes on its way out: no longer waited.
    for (0..100) |_| {
        if (frozen(held_cgroup) and (frozen(nodes_cgroup) or !exists(nodes_cgroup))) break;
        const pause: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    run(command, id, false);
    for (cgroups) |cgroup| freeze_write(cgroup, "0");
    _ = procs_move(held_cgroup ++ "/cgroup.procs", root_procs, false);
}

/// The scenario's processes moved into scenario_cgroup and frozen: how many.
fn scenario_pause() u32 {
    _ = linux.mkdir(scenario_cgroup, 0o755);
    var moved: u32 = 0;
    // Again until none is left: a process not yet moved may fork meanwhile.
    for (0..8) |_| {
        const now = scenario_procs_move();
        moved += now;
        if (now == 0) break;
    }
    freeze_write(scenario_cgroup, "1");
    for (0..100) |_| {
        if (frozen(scenario_cgroup)) break;
        const pause: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    return moved;
}

/// Thawed and moved back: how many.
fn scenario_resume() u32 {
    freeze_write(scenario_cgroup, "0");
    return procs_move(scenario_cgroup ++ "/cgroup.procs", root_procs, false);
}

/// The root cgroup's processes that are the scenario's (scenario_of) moved into scenario_cgroup.
fn scenario_procs_move() u32 {
    var list_buffer: [64 * 1024]u8 = undefined;
    const fd = linux.open(root_procs, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    const size = linux.read(@intCast(fd), &list_buffer, list_buffer.len);
    _ = linux.close(@intCast(fd));
    if (linux.errno(size) != .SUCCESS) return 0;
    const target = linux.open(scenario_cgroup ++ "/cgroup.procs", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(target) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(target));
    var moved: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, list_buffer[0..size], '\n');
    while (lines.next()) |line| {
        const pid = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        if (pid <= kthreadd or !scenario_of(pid)) continue;
        if (linux.errno(linux.write(@intCast(target), line.ptr, line.len)) == .SUCCESS) moved += 1;
    }
    return moved;
}

/// Whether `pid` or one of its parents (a few generations up) is one of scenario_comms.
fn scenario_of(pid: linux.pid_t) bool {
    var current = pid;
    for (0..16) |_| {
        var comm_buffer: [32]u8 = undefined;
        if (comm_of(current, &comm_buffer)) |comm| {
            if (scenario_comm(comm)) return true;
        }
        const parent = parent_of(current) orelse return false;
        if (parent <= 1) return false;
        current = parent;
    }
    return false;
}

fn scenario_comm(comm: []const u8) bool {
    for (scenario_comms) |name| if (std.mem.eql(u8, comm, name)) return true;
    return false;
}

test scenario_comm {
    try std.testing.expect(scenario_comm("det-faults"));
    try std.testing.expect(scenario_comm("program"));
    try std.testing.expect(!scenario_comm("det-sinks")); // Drains the nodes' output: never paused.
    try std.testing.expect(!scenario_comm("det-nodes"));
    try std.testing.expect(!scenario_comm("det-agent"));
}

/// A process's name (/proc/<pid>/comm, its newline dropped); null when gone.
fn comm_of(pid: linux.pid_t, buffer: *[32]u8) ?[]const u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS or size == 0) return null;
    return std.mem.trimEnd(u8, buffer[0..size], "\n");
}

/// Moves the processes `from` lists into the cgroup whose cgroup.procs is `to`: all of them, or
/// (`others_only`) all but det-init's, the agent's and its descendants', and the kernel's
/// threads (kthreadd's children: many let themselves be moved, never freeze, and the cgroup
/// would then never say it is frozen). Returns how many moved.
fn procs_move(from: [:0]const u8, to: [:0]const u8, others_only: bool) u32 {
    var list_buffer: [64 * 1024]u8 = undefined;
    const fd = linux.open(from, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    const size = linux.read(@intCast(fd), &list_buffer, list_buffer.len);
    _ = linux.close(@intCast(fd));
    if (linux.errno(size) != .SUCCESS) return 0;
    const target = linux.open(to, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(target) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(target));
    const self = linux.getpid();
    var moved: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, list_buffer[0..size], '\n');
    while (lines.next()) |line| {
        const pid = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        if (others_only and (pid <= kthreadd or pid == self or parent_of(pid) == kthreadd or
            descends_from(pid, self))) continue;
        if (linux.errno(linux.write(@intCast(target), line.ptr, line.len)) == .SUCCESS) moved += 1;
    }
    return moved;
}

/// Whether `ancestor` is among `pid`'s parents (a few generations up).
fn descends_from(pid: linux.pid_t, ancestor: linux.pid_t) bool {
    var current = pid;
    for (0..16) |_| {
        const parent = parent_of(current) orelse return false;
        if (parent == ancestor) return true;
        if (parent <= 1) return false;
        current = parent;
    }
    return false;
}

/// A process's parent, from /proc/<pid>/stat (after the command name's closing parenthesis).
fn parent_of(pid: linux.pid_t) ?linux.pid_t {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return null;
    var buffer: [512]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const text = buffer[0..size];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // State.
    return std.fmt.parseInt(linux.pid_t, fields.next() orelse return null, 10) catch null;
}

fn freeze_write(cgroup: []const u8, value: []const u8) void {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/cgroup.freeze", .{cgroup}, 0) catch return;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), value.ptr, value.len);
}

fn frozen(cgroup: []const u8) bool {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/cgroup.events", .{cgroup}, 0) catch return false;
    var buffer: [256]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    return std.mem.indexOf(u8, buffer[0..size], "frozen 1") != null;
}

fn exists(path: []const u8) bool {
    var path_buffer: [96]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0) catch return false;
    return linux.errno(linux.access(z, 0)) == .SUCCESS;
}

fn background_reap() void {
    var status: i32 = 0;
    while (true) {
        const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
    }
}

/// Runs one command line through /bin/sh, streaming its output as events. A background one
/// leaves the timeline's end alone (det-init waits only for the others: busy_path).
fn run(command: [:0]const u8, id: u32, background: bool) void {
    assert(command.len > 0);
    if (!background) {
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
        const busy = linux.open(busy_path, flags, 0o644);
        if (linux.errno(busy) == .SUCCESS) _ = linux.close(@intCast(busy));
    }
    defer if (!background) {
        _ = linux.unlink(busy_path);
    };
    // Long commands (inject's base64 chunks) are cut: the event must fit in one message.
    const shown = command[0..@min(command.len, command_shown_max)];
    if (background) {
        sdk.event("exec_start", .{ .command = shown, .size = command.len, .id = id, .background = true });
    } else {
        sdk.event("exec_start", .{ .command = shown, .size = command.len, .id = id });
    }
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
        done(126, id, background);
        return;
    }
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.dup2(pipe[1], 1);
        _ = linux.dup2(pipe[1], 2);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr };
        const environment = [_:null]?[*:0]const u8{
            "PATH=/opt/determinismo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:" ++
                "/sbin:/bin",
            "HOME=/root",
        };
        _ = linux.execve("/bin/sh", &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(pipe[1]);
    stream_output(pipe[0], id);
    _ = linux.close(pipe[0]);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const bits: u32 = @bitCast(status);
    const code = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    done(code, id, background);
}

fn done(status: u32, id: u32, background: bool) void {
    if (background) {
        sdk.event("exec_done", .{ .status = status, .id = id, .background = true });
    } else {
        sdk.event("exec_done", .{ .status = status, .id = id });
    }
}

fn stream_output(fd: linux.fd_t, id: u32) void {
    assert(fd >= 0);
    var chunk: [output_chunk_size]u8 = undefined;
    for (0..output_chunks_max) |_| {
        const result = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        if (result == 0) return; // The command closed its output.
        sdk.event("exec_output", .{ .text = chunk[0..result], .id = id });
    }
}
