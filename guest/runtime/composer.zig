// SPDX-License-Identifier: MIT
//! det-composer: runs one timeline of a scenario, following Antithesis's test-command rules
//! (docs: test_composer_reference). Every choice it makes (which command, how many in parallel,
//! when) is a randomness pull from the platform, so a strategy can steer it and a tape replays
//! it.
//!
//! Usage: det-composer --scenario <name>
//!
//! The scenario comes from /det/system.json; its commands run as `/det/program run <scenario>
//! <command>` (or the program in the scenario's node, `det-nodes exec <node> <program> run ...`,
//! or each command's own file there). The composer runs the scenario's setup command and then signals setup_complete
//! itself: that is where determinismo snapshots, so every branch starts after setup.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const commands_max = 64;
const running_max = 1 << parallelism_log2_max;
const starts_max = 64;
/// Command starts in one timeline, a long one (det.timeline_ms=) included: a sanity bound.
const started_max = 1 << 24;
/// Parallel drivers running at once: 1, 2, 4, ... up to 32, drawn per timeline. Antithesis sets
/// no bound ("multiple copies of the same command" at once): a system under the load of many
/// clients reaches states one client never does (a cut-off leader that took many writes).
const parallelism_log2_max = 5;
const pause_ns_max = 20 * std.time.ns_per_ms;
/// Before an eventually ending the drivers run at least a drawn time, a tenth of this up to it
/// (or until they end): with every start within half a second (a high parallelism drawn), the
/// ending killed them 0.07 s in (Kafka run 308, branch 15) and under a second of driving was 10%
/// of etcd's timelines, 11% of NATS's, 18% of ZooKeeper's. The scenario's `min_drive_ms` or
/// det.min_drive_ms= (explore's --min-drive) set it, 0 none.
const min_drive_ms_default = 10_000;
/// How often the composer looks for drivers ended on their own during that minimum.
const min_drive_poll_ns = 50 * std.time.ns_per_ms;
const faults_path = "/opt/determinismo/bin/det-faults";
/// The test commands' cgroup (drivers_cpu_draw), beside the nodes' (nodes.cgroup_root).
const drivers_cgroup = "/sys/fs/cgroup/drivers";
/// The commands' CPU weight drawn per timeline ("composer.drivers_cpu"), 0 flat: no cgroup of
/// their own. Equal weighs all the commands together as all the nodes together; nodes-4x gives
/// the nodes four times their share under contention.
const drivers_cpu_names = [_][]const u8{ "flat", "equal", "nodes-4x" };
const drivers_cpu_weights = [_]u64{ 0, 100, 25 };
/// Whether this timeline's commands start in `drivers_cgroup` (drivers_cpu_draw).
var drivers_join = false;
/// detfs (det_guest): "1" once an SDK declared the system's setup complete.
const sdk_setup_path = "/opt/determinismo/sdk/setup";
const sdk_setup_wait_ns = 300 * std.time.ns_per_s;

/// A system with an Antithesis SDK declares its own setup (once it is ready: a leader elected,
/// data loaded); the drivers start after it, as Antithesis's do. The platform snapshots at that
/// declaration. A system that never declares it is started anyway after a while.
fn sdk_setup_wait() void {
    const poll_ns = 10 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < sdk_setup_wait_ns) : (waited_ns += poll_ns) {
        var buffer: [4]u8 = undefined;
        const fd = linux.open(sdk_setup_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) == .SUCCESS) {
            const size = linux.read(@intCast(fd), &buffer, buffer.len);
            _ = linux.close(@intCast(fd));
            if (linux.errno(size) == .SUCCESS and size > 0 and buffer[0] == '1') return;
        }
        nodes.sleep_ns(poll_ns);
    }
    sdk.event("sdk_setup_missing", .{ .waited_ns = waited_ns });
}
const faults_control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
const program_path = "/det/program";
const nodes_path = "/opt/determinismo/bin/det-nodes";
const nodes = @import("nodes.zig");
const output = @import("output.zig");
const schema = sdk.schema;
const Kind = schema.Kind;

const Command = struct {
    name: [:0]const u8,
    kind: Kind,
    /// For scenarios in a node: the executable there (run with det-nodes exec).
    path: ?[:0]const u8 = null,
    /// A driver of the workload (schema.Command.workload): one of them kept at least.
    workload: bool = false,
    /// In this timeline's mix (swarm_commands): only kept commands are started.
    kept: bool = true,
    /// How often it is picked among its kind's kept commands (swarm_commands), 1 to 8.
    weight: u32 = 1,
};

const Running = struct { pid: linux.pid_t, command: *const Command };

/// What this timeline's composer said already: a reachable property once per timeline is all it
/// needs, and "test commands exit successfully" true once (false at every failing exit). Said at
/// each command they were half of a Raft run's 15.8 million events (run 1381, 1.38 million
/// commands). A branch's composer is its parent's process, these with it.
var started_said: [commands_max]?*const Command = @splat(null);
var completed_said: [commands_max]?*const Command = @splat(null);
var exit_success_said = false;

/// Whether `command` is in `said`, noting it if not.
fn said_before(said: *[commands_max]?*const Command, command: *const Command) bool {
    for (said) |*slot| {
        if (slot.* == command) return true;
        if (slot.* == null) {
            slot.* = command;
            return false;
        }
    }
    return false; // Full (more commands than commands_max cannot be): said again.
}

const Composer = struct {
    commands: [commands_max]Command = undefined,
    command_count: u32 = 0,
    running: [running_max]Running = undefined,
    running_count: u32 = 0,
    started_count: u32 = 0,
    scenario: [:0]const u8 = "",
    /// The node the scenario's commands run in, if not the runner.
    node: ?[:0]const u8 = null,
    /// The test program's path in `node`, when it is the program that runs there (rather than
    /// a file for each command: Antithesis test templates).
    program: ?[:0]const u8 = null,
    /// Whether the scenario uses the fault injector, and its process while it runs.
    faults: bool = false,
    faults_pid: ?linux.pid_t = null,
    faults_control: ?linux.fd_t = null,
    /// Commands that did not run to completion (a signal ended them: a fault's, or the
    /// composer's): a timeline with any runs no finally command.
    interrupted: u32 = 0,

    /// The kept commands of `kind` (all of them but the drivers the swarm left out).
    fn kind_count(composer: *const Composer, kind: Kind) u32 {
        var count: u32 = 0;
        for (composer.commands[0..composer.command_count]) |command| {
            count += @intFromBool(command.kind == kind and command.kept);
        }
        assert(count <= composer.command_count);
        return count;
    }

    /// A kept command of `kind`, a named decision among their names (`composer.command`:
    /// strategies see which one starts); the caller checked that one exists.
    fn pick(composer: *const Composer, kind: Kind) *const Command {
        const count = composer.kind_count(kind);
        assert(count > 0);
        var names: [commands_max][]const u8 = undefined;
        var indices: [commands_max]u32 = undefined;
        var listed: u32 = 0;
        for (composer.commands[0..composer.command_count], 0..) |*command, index| {
            if (command.kind != kind or !command.kept) continue;
            names[listed] = command.name;
            indices[listed] = @intCast(index);
            listed += 1;
        }
        assert(listed == count);
        var total: u64 = 0;
        for (indices[0..listed]) |index| total += composer.commands[index].weight;
        if (total == listed) return &composer.commands[indices[sdk.decide("composer.command", names[0..listed])]];
        // Weighted (an unmarked scenario's few drivers: swarm_commands): by the weights.
        var draw = sdk.random_below_named("composer.command_weighted", total);
        for (indices[0..listed]) |index| {
            const weight = composer.commands[index].weight;
            if (draw < weight) return &composer.commands[index];
            draw -= weight;
        }
        unreachable;
    }

    /// Swarm testing over the drivers (docs/SWARM.md, part 2): each parallel, serial and anytime
    /// driver kept in this timeline by a named decision ("composer.swarm <name>"), with a keep
    /// probability drawn per timeline ("composer.swarm_p", one to seven eighths); one of the
    /// workload's drivers at least when the scenario marks them (a timeline of only nemeses
    /// judges nothing), else one driver at least, and a scenario that marks none with four
    /// drivers or fewer keeps them all, weighted. A driver left out is a `command_left_out`
    /// event. None with --no-swarm.
    fn swarm_commands(composer: *Composer) void {
        if (swarm_off()) return;
        var workload_marked = false;
        var swarmable: u32 = 0;
        for (composer.commands[0..composer.command_count]) |command| {
            workload_marked = workload_marked or command.workload;
            swarmable += @intFromBool(command.kind == .parallel_driver or command.kind == .serial_driver or command.kind == .anytime);
        }
        // A scenario that marks no workload, with four drivers or fewer, keeps them all and
        // weighs them per timeline (1 to 64, powers of two, "composer.weight <name>": a driver
        // nearly alone in one timeline, alike in another; the copied 1 to 8 before), as
        // Antithesis's composer zeroes none of four commands or fewer: a nemesis beside an
        // unmarked workload would otherwise run alone in about a third of timelines, judging
        // nothing.
        if (!workload_marked and swarmable <= 4) {
            for (composer.commands[0..composer.command_count]) |*command| {
                if (command.kind != .parallel_driver and command.kind != .serial_driver and command.kind != .anytime) continue;
                var label_buffer: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, "composer.weight {s}", .{command.name}) catch "composer.weight";
                command.weight = @as(u32, 1) << @intCast(sdk.random_config(label, 7));
                sdk.event("command_weight", .{ .name = command.name, .weight = command.weight });
            }
            return;
        }
        const eighths = 1 + sdk.random_config("composer.swarm_p", 7);
        // The drivers one of which must stay: the workload's when marked, else every driver.
        var needed: u32 = 0;
        var needed_kept: u32 = 0;
        for (composer.commands[0..composer.command_count]) |*command| {
            const driver = command.kind == .parallel_driver or command.kind == .serial_driver;
            if (!driver and command.kind != .anytime) continue;
            var label_buffer: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "composer.swarm {s}", .{command.name}) catch "composer.swarm";
            command.kept = sdk.random_config(label, 8) < eighths;
            // Asked for (explore's --keep): kept whatever the draw, the draw made all the same.
            if (keep_asked(command.name)) command.kept = true;
            const counts = if (workload_marked) command.workload else driver;
            needed += @intFromBool(counts);
            needed_kept += @intFromBool(counts and command.kept);
        }
        if (needed > 0 and needed_kept == 0) {
            var pick_index = sdk.random_below_named("composer.swarm_one", needed);
            for (composer.commands[0..composer.command_count]) |*command| {
                const driver = command.kind == .parallel_driver or command.kind == .serial_driver;
                const counts = if (workload_marked) command.workload else driver;
                if (!counts) continue;
                if (pick_index == 0) command.kept = true;
                pick_index -|= 1;
            }
        }
        for (composer.commands[0..composer.command_count]) |command| {
            if (!command.kept) sdk.event("command_left_out", .{ .name = command.name, .kept_eighths = eighths });
        }
    }

    fn start(composer: *Composer, command: *const Command) void {
        assert(composer.running_count < running_max);
        if (!said_before(&started_said, command)) {
            var buffer: [256]u8 = undefined;
            const property = command_property(&buffer, "started", command.name);
            sdk.assert_computed(.reachable, true, property, .{});
        }
        assert(composer.started_count < started_max);
        const pid = if (composer.program) |program| spawn_logged(command.name, &.{
            nodes_path, "exec", composer.node.?, program, "run", composer.scenario, command.name,
        }) else if (composer.node) |node|
            spawn_logged(command.name, &.{ nodes_path, "exec", node, command.path.? })
        else
            spawn_logged(command.name, &.{ program_path, "run", composer.scenario, command.name });
        composer.running[composer.running_count] = .{ .pid = pid, .command = command };
        composer.running_count += 1;
        composer.started_count += 1;
    }

    fn find(composer: *const Composer, name: []const u8) ?*const Command {
        for (composer.commands[0..composer.command_count]) |*command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }

    /// Waits for one running command to exit and reports how it ended.
    fn wait_one(composer: *Composer) void {
        assert(composer.reap(false, true));
    }

    /// One running command that exited, reported (`killed`: by the composer itself, as an
    /// eventually command begins): waited for (`hang`), or false if none has exited yet.
    fn reap(composer: *Composer, killed: bool, hang: bool) bool {
        assert(composer.running_count > 0);
        for (0..running_max + 1) |_| { // The injector may exit first, at most once.
            var status: i32 = 0;
            const result = linux.wait4(-1, &status, if (hang) 0 else linux.W.NOHANG, null);
            assert(linux.errno(result) == .SUCCESS);
            if (result == 0) return false;
            const pid: linux.pid_t = @intCast(result);
            if (composer.faults_pid == pid) {
                composer.faults_pid = null; // It ran out of injections: faults are over.
                continue;
            }
            for (composer.running[0..composer.running_count], 0..) |entry, index| {
                if (entry.pid != pid) continue;
                const bits: u32 = @bitCast(status);
                const signaled = bits & 0x7f != 0 or (bits >> 8) & 0xff >= 128;
                if (signaled or killed) composer.interrupted += 1;
                report_exit(entry.command, bits, killed);
                composer.running[index] = composer.running[composer.running_count - 1];
                composer.running_count -= 1;
                return true;
            }
            unreachable; // Every child is a command we started, or the injector.
        }
        unreachable;
    }

    /// Faults run during the driver phase only, as in Antithesis: not during first commands,
    /// and stopped before eventually and finally commands, which check recovery.
    fn faults_start(composer: *Composer) void {
        assert(composer.faults_pid == null);
        if (!composer.faults) return;
        // The control FIFO, held open through the driver phase: requests a driver writes before
        // the injector reads (quiet periods, injected faults) wait in it, not lost.
        const fifo = linux.S.IFIFO | 0o622;
        _ = linux.mknodat(linux.AT.FDCWD, faults_control_path, fifo, 0);
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true };
        const control = linux.open(faults_control_path, flags, 0);
        if (linux.errno(control) == .SUCCESS) composer.faults_control = @intCast(control);
        composer.faults_pid = spawn(&.{ faults_path, "--scenario", composer.scenario });
        // Declared only when the scenario has faults (commands_declare): not in the catalog.
        sdk.assert_computed(.reachable, true, faults_property, .{});
    }

    fn faults_stop(composer: *Composer) void {
        const pid = composer.faults_pid orelse return;
        _ = linux.kill(pid, .TERM); // It undoes its faults before exiting.
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        composer.faults_pid = null;
        if (composer.faults_control) |control| _ = linux.close(control);
        composer.faults_control = null;
    }

    fn wait_all(composer: *Composer) void {
        while (composer.running_count > 0) composer.wait_one();
        assert(composer.running_count == 0);
    }

    /// The running commands end on their own until `deadline_ns`, if they do.
    fn wait_until(composer: *Composer, deadline_ns: u64) void {
        composer.wait_below(1, deadline_ns);
    }

    /// Commands end on their own until fewer than `count` run, or `deadline_ns` passes (none:
    /// waited for as they end, no polling).
    fn wait_below(composer: *Composer, count: u32, deadline_ns: u64) void {
        while (composer.running_count >= count) {
            if (deadline_ns == std.math.maxInt(u64)) {
                assert(composer.reap(false, true));
                continue;
            }
            if (composer.reap(false, false)) continue;
            const now = now_ns();
            if (now >= deadline_ns) return;
            sleep_until(@min(deadline_ns, now + min_drive_poll_ns));
        }
    }

    /// Every running command killed, with whatever it started (its process group: commands
    /// lead their own), as Antithesis does when an eventually command begins.
    fn kill_all(composer: *Composer) void {
        for (composer.running[0..composer.running_count]) |entry| {
            _ = linux.kill(-entry.pid, .KILL);
            _ = linux.kill(entry.pid, .KILL); // Before it made its group, if it had not yet.
        }
        while (composer.running_count > 0) assert(composer.reap(true, true));
    }

    fn run_to_completion(composer: *Composer, command: *const Command) void {
        assert(composer.running_count == 0);
        announce(command, "complete");
        composer.start(command);
        composer.wait_all();
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 3 or !std.mem.eql(u8, arguments[1], "--scenario")) return error.Usage;
    const system = try nodes.system_load(arena);
    const scenario = system.scenario(arguments[2]) orelse return error.UnknownScenario;
    var composer: Composer = .{ .scenario = arguments[2], .faults = scenario.faults };
    if (scenario.node) |node| composer.node = try arena.dupeSentinel(u8, node, 0);
    if (scenario.program) |program| {
        if (composer.node == null) return error.ProgramWithoutNode;
        composer.program = try arena.dupeSentinel(u8, program, 0);
    }
    var setup: ?Command = null;
    for (scenario.commands) |command| {
        const name = try arena.dupeSentinel(u8, command.name, 0);
        const path = if (command.path) |path| try arena.dupeSentinel(u8, path, 0) else null;
        if (composer.node != null and composer.program == null and path == null) return error.CommandWithoutPath;
        if (command.kind == .setup) {
            if (setup != null) return error.SeveralSetupCommands;
            setup = .{ .name = name, .kind = .setup, .path = path };
            continue;
        }
        if (composer.command_count == commands_max) return error.TooManyCommands;
        composer.commands[composer.command_count] = .{
            .name = name,
            .kind = command.kind,
            .path = path,
            .workload = command.workload,
        };
        composer.command_count += 1;
    }
    if (setup) |*command| composer.run_to_completion(command);
    // A fast VM's dev mode (CI, sandboxes, a developer's REPL) hands the machine over as it is:
    // whoever uses it decides it is ready (CI's setup command, the developer's checkpoint), no
    // drivers start after it. Waiting for an SDK's declaration there held every CI setup five
    // minutes for a system that declares nothing (jank-lang/clojure-test-suite, 2026-11-11).
    var cmdline_buffer: [4096]u8 = undefined;
    if (sdk_setup_waited(&system, cmdline_read(&cmdline_buffer))) sdk_setup_wait();
    // Snapshotted before the nodes started (det-init's, schema.Scenario.snapshot_before_nodes):
    // the timeline started them and ran the setup itself.
    if (!scenario.snapshot_before_nodes) {
        // Before the timelines part: what each node holds unsynced (nodes.unsynced_report).
        nodes.unsynced_report(&system);
        sdk.setup_complete(.{ .scenario = composer.scenario });
        // The fast VM's dev mode (det.dev=1): the developer works in the machine as set up; a
        // timeline starts only from a snapshot of it (det:explore-here), which says so here.
        if (dev_mode()) dev_wait();
        nodes.timelines_parted();
    }
    commands_declare(&composer);
    if (composer.node != null and composer.program == null) invalid_report(scenario.invalid);
    const drivers = composer.kind_count(.parallel_driver) + composer.kind_count(.serial_driver);
    const singletons = composer.kind_count(.singleton_driver);
    if (drivers + singletons + composer.kind_count(.anytime) == 0) return error.NoDriverCommands;

    sdk.event("composer_start", .{ .commands = composer.command_count });
    drivers_cpu_draw();
    if (script_read(arena)) |script| {
        run_script(&composer, &script);
        checks_stream(&system);
        return;
    }
    if (composer.kind_count(.first) > 0) composer.run_to_completion(composer.pick(.first));
    const singleton_timeline = singletons > 0 and (drivers == 0 or singleton_drawn());
    swarm_seed_write();
    if (!singleton_timeline) composer.swarm_commands();
    sdk.event("faults_phase", .{ .state = "start" });
    composer.faults_start();
    const drive_start_ns = now_ns();
    var length_end_ns: ?u64 = null;
    if (singleton_timeline) {
        run_singleton(&composer);
    } else {
        length_end_ns = run_drivers(&composer, scenario.drive_ms_max orelse drive_max_default_ms(), scenario.parallel_max);
        while (drive_again(drive_start_ns)) {
            length_end_ns = run_drivers(&composer, scenario.drive_ms_max orelse drive_max_default_ms(), scenario.parallel_max);
        }
    }
    // The ending, as Antithesis's: an eventually command kills every command still running
    // (and the faults stop); a finally one waits for them to end on their own, and runs only
    // if every command ran to completion; or neither.
    const ending = ending_pick(&composer);
    var bounded = false;
    if (ending == .eventually) {
        min_drive(&composer, drive_start_ns, scenario.min_drive_ms);
        composer.kill_all();
    } else if (length_end_ns) |end_ns| {
        // A length bounds the timeline (--timeline, a drawn drive_ms_max): the commands still
        // running get a grace, then are killed, as an eventually ending kills them. Waiting for
        // them, a 300 s cap ended rqlite's faults at 629 s median, 2,719 s at most (run 402).
        composer.wait_until(end_ns + length_grace_ns);
        if (composer.running_count > 0) {
            sdk.event("length_reached", .{ .running = composer.running_count });
            composer.kill_all();
            bounded = true;
        }
    } else composer.wait_all();
    composer.faults_stop();
    sdk.event("faults_phase", .{ .state = "stop" });
    // Drivers ended by the length, by design: a finally (the checks) runs as an eventually
    // command would, not skipped as after commands that failed to end.
    if (bounded) composer.interrupted = 0;
    run_ending(&composer, ending, scenario.ending_ms_max orelse ending_ms_max_default);
    checks_stream(&system);
    sdk.event("composer_done", .{ .commands_started = composer.started_count });
}

/// The bytes of a chunk: 2,400 are 3,200 in base64, an event well under the guest module's page.
const check_chunk_size = 2400;

/// Each check's file (schema.Check: a history), streamed out for the host once the timeline's
/// commands are done: base64 chunks (`check_chunk`), then `check_input` with its size (or
/// `missing`: nothing was recorded). The host runs the check on it and adds its verdict.
fn checks_stream(system: *const @import("determinismo").schema.System) void {
    for (system.checks, 0..) |check, index| {
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{check.file}, 0) catch continue;
        const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            sdk.event("check_input", .{ .check = index, .missing = true });
            continue;
        }
        defer _ = linux.close(@intCast(fd));
        var total: u64 = 0;
        while (true) {
            var raw: [check_chunk_size]u8 = undefined;
            var size: usize = 0;
            while (size < raw.len) { // Whole chunks, but the last.
                const result = linux.read(@intCast(fd), raw[size..].ptr, raw.len - size);
                if (linux.errno(result) != .SUCCESS or result == 0) break;
                size += result;
            }
            if (size == 0) break;
            var encoded: [std.base64.standard.Encoder.calcSize(check_chunk_size)]u8 = undefined;
            const data = std.base64.standard.Encoder.encode(&encoded, raw[0..size]);
            sdk.event("check_chunk", .{ .check = index, .data = data });
            total += size;
            if (size < raw.len) break;
        }
        sdk.event("check_input", .{ .check = index, .bytes = total });
    }
}

/// A timeline's shape, extracted from a branch's events (`determinismo script`): commands by
/// their start offset from composer_start, faults by theirs from the start of the fault phase.
/// Everything inside (scheduling, test inputs) is still decided by the seed.
pub const Script = struct {
    script: u32 = 1,
    commands: []const ScriptCommand = &.{},
    faults_start_ns: ?u64 = null,
    faults_stop_ns: ?u64 = null,
    faults: []const std.json.Value = &.{},
};

pub const ScriptCommand = struct { at_ns: u64, name: []const u8, mode: []const u8 };

pub const script_path = "/det/script.json";

fn script_read(arena: std.mem.Allocator) ?Script {
    const fd = linux.open(script_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const buffer = arena.alloc(u8, 1 << 20) catch return null;
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return sdk.schema.parse(Script, arena, buffer[0..size]) catch null;
}

/// What a script (determinismo script) is made of: which command started, and how.
fn announce(command: *const Command, mode: []const u8) void {
    sdk.event("command_start", .{ .name = command.name, .mode = mode });
}

fn run_script(composer: *Composer, script: *const Script) void {
    const start_ns = now_ns();
    var phase: enum { before, faults, after } = .before;
    for (script.commands) |item| {
        if (phase == .before and script.faults_start_ns != null and
            script.faults_start_ns.? <= item.at_ns)
        {
            sleep_until(start_ns + script.faults_start_ns.?);
            sdk.event("faults_phase", .{ .state = "start" });
            composer.faults_start();
            phase = .faults;
        }
        if (phase == .faults and script.faults_stop_ns != null and
            script.faults_stop_ns.? <= item.at_ns)
        {
            composer.wait_all(); // As without a script: drivers end before faults stop.
            composer.faults_stop();
            sdk.event("faults_phase", .{ .state = "stop" });
            phase = .after;
        }
        sleep_until(start_ns + item.at_ns);
        const command = composer.find(item.name) orelse continue; // Gone in this build.
        if (std.mem.eql(u8, item.mode, "complete")) {
            composer.wait_all();
            composer.run_to_completion(command);
        } else {
            while (composer.running_count >= running_max) composer.wait_one();
            announce(command, "start");
            composer.start(command);
        }
    }
    composer.wait_all();
    if (phase == .faults) composer.faults_stop();
    sdk.event("composer_done", .{ .commands_started = composer.started_count, .script = true });
}

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_until(deadline_ns: u64) void {
    const now = now_ns();
    if (now >= deadline_ns) return;
    const wait = deadline_ns - now;
    const request = linux.timespec{
        .sec = @intCast(wait / std.time.ns_per_s),
        .nsec = @intCast(wait % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

/// Whether a scenario with drivers too runs its singleton alone this timeline: a share of one to
/// seven eighths drawn per timeline ("composer.singleton_eighths"), then the timeline drawn by it
/// ("composer.singleton"); Antithesis's half of the timelines, copied before, only with
/// --no-swarm. Never none or all: either kind of timeline stays reachable.
fn singleton_drawn() bool {
    if (swarm_off()) return sdk.random_below(2) == 0;
    const eighths = 1 + sdk.random_config("composer.singleton_eighths", 7);
    return sdk.random_below_named("composer.singleton", 8) < eighths;
}

fn run_singleton(composer: *Composer) void {
    assert(composer.kind_count(.singleton_driver) > 0);
    if (composer.kind_count(.anytime) > 0) {
        if (sdk.random_below(2) == 0) composer.start(composer.pick(.anytime));
    }
    composer.start(composer.pick(.singleton_driver));
    composer.wait_all();
}

/// Parallel and serial drivers in random order and parallelism, with anytime checks mixed in.
/// Driver commands, started at random (Antithesis's rules): a drawn number of starts, or with
/// a timeline length (det.timeline_ms=) starts until that much virtual time has passed.
/// The commands still running when a timeline's length ends: this long to end on their own,
/// then killed.
const length_grace_ns = 30 * std.time.ns_per_s;

/// How many driver starts a timeline without a length makes: log-uniform, 2 to 63 (each octave
/// alike, "composer.starts_log2", then uniform in it): a few starts as often as dozens. The
/// uniform 4 to 63 before (Antithesis's rules' numbers) only with --no-swarm.
fn starts_draw() u64 {
    if (swarm_off()) return 4 + sdk.random_below(starts_max - 4);
    const low = @as(u64, 2) << @intCast(sdk.random_config("composer.starts_log2", 5));
    return low + sdk.random_below_named("composer.starts", low);
}

/// Returns when the timeline's length ends, when it has one (--timeline, drive_ms_max).
fn run_drivers(composer: *Composer, drive_ms_max: ?u32, parallel_max: ?u32) ?u64 {
    const timeline_ns = timeline_length_ns() orelse drive_drawn_ns(drive_ms_max);
    const starts = if (timeline_ns == null) starts_draw() else 0;
    const log2_max = if (parallel_max) |most| @min(parallelism_log2_max, std.math.log2_int(u32, @max(most, 1))) else parallelism_log2_max;
    // A named decision, as the driver phase's length: a strategy steers how many drivers run at
    // once. A timeline of one at a time judges no concurrency (Tarantool's register trial run
    // 658: 1,816 compare-and-sets, none met another writer).
    const parallelism = @as(u64, 1) << @intCast(sdk.random_config("composer.parallelism_log2", log2_max + 1));
    var load: Load = .{ .parallelism = parallelism, .log2_max = log2_max, .until_ns = if (swarm_off()) std.math.maxInt(u64) else now_ns() };
    assert(starts <= starts_max);
    var kinds_buffer: [3]Kind = undefined;
    var kinds: []Kind = kinds_buffer[0..0];
    for ([_]Kind{ .parallel_driver, .serial_driver, .anytime }) |kind| {
        if (composer.kind_count(kind) > 0) {
            kinds_buffer[kinds.len] = kind;
            kinds = kinds_buffer[0 .. kinds.len + 1];
        }
    }
    assert(kinds.len > 0);
    if (timeline_ns) |length_ns| {
        // Each start's wait for a slot bounded by the timeline's end: a driver that never ends
        // (retrying under faults) held the composer there, past the length, its faults going on
        // until the timeline limit (Kafka's perf run 355: 30 s timelines past 1,200 s).
        const end_ns = now_ns() + length_ns;
        while (now_ns() < end_ns) {
            if (!load.next(end_ns)) continue;
            driver_start_by(composer, kinds, load.parallelism, end_ns);
        }
        return end_ns;
    } else {
        // No driver starts past half the timeline's limit: those running finish, then the
        // ending and the checks run. Many starts one at a time of a slow system's drivers ran
        // past the limit and failed as hangs while every command progressed (Redpanda run 177:
        // its median timeline 20 minutes, a tenth at the hour; Group Replication's timeline 222).
        const stop_ns = if (timeline_limit_ns()) |limit_ns| now_ns() + limit_ns / 2 else null;
        for (0..starts) |started| {
            if (stop_ns) |stop| if (now_ns() >= stop) {
                sdk.event("drivers_stopped", .{ .started = started, .starts = starts });
                break;
            };
            while (!load.next(std.math.maxInt(u64))) {}
            driver_start(composer, kinds, load.parallelism);
        }
    }
    return null;
}

/// The drivers' load in stretches (docs/SWARM.md part 5: quiet, then the front page of Hacker
/// News): every 10 to 120 s ("composer.load_ms") a stretch is steady at a drawn parallelism,
/// quiet (no driver starts, those running finish), or a spike at the most allowed
/// ("composer.load"), a quiet one 1 to 15 s. With --no-swarm, the timeline's one parallelism
/// throughout.
const Load = struct {
    parallelism: u64,
    log2_max: u32,
    until_ns: u64,
    quiet: bool = false,

    /// Whether a driver may start now: false in a quiet stretch, after sleeping through it (or
    /// to `end_ns`, the timeline's end, if sooner).
    fn next(load: *Load, end_ns: u64) bool {
        const now = now_ns();
        if (now >= load.until_ns) {
            const shapes = [_][]const u8{ "steady", "quiet", "spike" };
            const shape = sdk.decide("composer.load", &shapes);
            // A quiet stretch short (1 to 15 s: idle, then the spike or the next load), the others
            // 10 to 120 s: quiet ones as long made every timeline longer (the e2e tree check
            // took twice its time).
            const stretch_ms = if (shape == 1)
                1_000 + sdk.random_below_named("composer.quiet_ms", 14_001)
            else
                10_000 + sdk.random_below_named("composer.load_ms", 110_001);
            load.until_ns = now + stretch_ms * std.time.ns_per_ms;
            load.quiet = shape == 1;
            load.parallelism = switch (shape) {
                0 => @as(u64, 1) << @intCast(sdk.random_config("composer.parallelism_log2", load.log2_max + 1)),
                1 => 1,
                else => @as(u64, 1) << @intCast(load.log2_max),
            };
            sdk.event("composer_load", .{ .shape = shapes[shape], .parallelism = load.parallelism, .stretch_ms = stretch_ms });
        }
        if (!load.quiet) return true;
        // Seconds: `pause` is for jitter under 20 ms (a quiet stretch through it asserted in a
        // safe build, and in a fast one its invalid timespec made nanosleep return at once, the
        // composer spinning through the stretch).
        sleep_until(@min(load.until_ns, end_ns));
        return false;
    }
};

/// The drivers still running carry on until the drawn minimum drive since they began (a named
/// decision: a strategy steers it), or until they end.
fn min_drive(composer: *Composer, drive_start_ns: u64, scenario_ms: ?u32) void {
    if (composer.running_count == 0) return;
    const max_ms = if (cmdline_ms("det.min_drive_ms=")) |ns| ns / std.time.ns_per_ms else scenario_ms orelse min_drive_ms_default;
    if (max_ms == 0) return;
    const floor_ms = max_ms / 10;
    const drawn_ms = floor_ms + sdk.random_below_named("composer.min_drive_ms", max_ms - floor_ms + 1);
    const deadline_ns = drive_start_ns + drawn_ms * std.time.ns_per_ms;
    const running = composer.running_count;
    composer.wait_until(deadline_ns);
    sdk.event("min_drive", .{
        .drawn_ms = drawn_ms,
        .running = running,
        .ended = running - composer.running_count,
        .waited_ms = (now_ns() -| drive_start_ns) / std.time.ns_per_ms,
    });
}

fn driver_start(composer: *Composer, kinds: []const Kind, parallelism: u64) void {
    driver_start_by(composer, kinds, parallelism, std.math.maxInt(u64));
}

/// A driver started, its slot waited for until `deadline_ns` at most (none started past it).
fn driver_start_by(composer: *Composer, kinds: []const Kind, parallelism: u64, deadline_ns: u64) void {
    const kind = sdk.random_choice(Kind, kinds);
    switch (kind) {
        .serial_driver => {
            composer.wait_below(1, deadline_ns);
            if (composer.running_count > 0) return;
            composer.run_to_completion(composer.pick(.serial_driver));
        },
        .parallel_driver, .anytime => {
            composer.wait_below(@intCast(parallelism), deadline_ns);
            if (composer.running_count >= parallelism) return;
            const command = composer.pick(kind);
            announce(command, "start");
            composer.start(command);
        },
        else => unreachable,
    }
    pause(sdk.random_below(pause_ns_max));
}

/// det.timeline_ms= from the kernel command line (explore's --timeline), in nanoseconds.
/// The scenario's driver phase length, drawn (Scenario.drive_ms_max): halved 0 to 6 times, then
/// uniform between that half and it; null without one.
fn drive_drawn_ns(drive_ms_max: ?u32) ?u64 {
    const max_ms: u64 = drive_ms_max orelse return null;
    const top_ms = @max(1, max_ms >> @intCast(sdk.random_below_named("composer.drive_ms", 7)));
    const ms = top_ms / 2 + sdk.random_below(top_ms - top_ms / 2 + 1);
    sdk.event("drive_drawn", .{ .ms = ms, .max_ms = max_ms });
    return ms * std.time.ns_per_ms;
}

/// det.drive_ms_max= (explore's --drive-max, 20 minutes unless none): the driver phase's longest
/// drawn length for a scenario that sets none of its own.
fn drive_max_default_ms() ?u32 {
    const ns = cmdline_ms("det.drive_ms_max=") orelse return null;
    return @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u32)));
}

fn timeline_length_ns() ?u64 {
    return cmdline_ms("det.timeline_ms=");
}

/// det.timeline_limit_ms= (explore's --timeline-limit: where a timeline not finished is a hang),
/// in nanoseconds.
fn timeline_limit_ns() ?u64 {
    return cmdline_ms("det.timeline_limit_ms=");
}

/// Whether the timeline drives another phase after this one: the explorer's decision
/// ("composer.again"). An exploring explorer answers it (advisor.zig): no, but for a timeline
/// the tree returned to an objective's best (a node's memory growth), once. That branch goes on
/// a phase past where its parent stopped and adds to what the parent built up, so a path grows a
/// phase a generation. Before it, a returned timeline ended when its parent would (its starts
/// or its length are drawn once, at its phase's start): whatever the tree returned to, a path
/// leaked one timeline's worth and a leak slower than a timeline was out of reach (e2e
/// memory-climb, 2026-11-17).
/// Yes is the answer 1 of again_range: where nothing answers (a plain run, a machine), the
/// timeline's own draw says it once in 2^62, so nothing but the explorer turns it on, and the
/// machine boots as it always did (a word on the kernel's command line to ask by made replays
/// boot other inputs than their tapes': refused).
/// Not asked past a quarter of the timeline's limit since the first phase began: another phase
/// and the ending have the rest.
const again_range = 1 << 62;

fn drive_again(drive_start_ns: u64) bool {
    if (timeline_limit_ns()) |limit_ns| if (now_ns() - drive_start_ns >= limit_ns / 4) return false;
    return sdk.random_below_named("composer.again", again_range) == 1;
}

fn cmdline_ms(comptime key: []const u8) ?u64 {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return words_ms(buffer[0..size], key);
}

/// `key<ms>` among a command line's words, in nanoseconds.
fn words_ms(text: []const u8, key: []const u8) ?u64 {
    var words = std.mem.tokenizeAny(u8, text, " \n");
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, key)) continue;
        const ms = std.fmt.parseInt(u64, word[key.len..], 10) catch return null;
        return ms * std.time.ns_per_ms;
    }
    return null;
}

test "the composer draws its start counts and singleton share wide" {
    // Outside determinismo the SDK draws from its own generator; swarm is on (no det.no_swarm).
    var few = false;
    var many = false;
    for (0..2000) |_| {
        const starts = starts_draw();
        try std.testing.expect(starts >= 2 and starts <= starts_max);
        few = few or starts < 4;
        many = many or starts > 32;
    }
    try std.testing.expect(few and many);
    var alone: u32 = 0;
    for (0..2000) |_| alone += @intFromBool(singleton_drawn());
    try std.testing.expect(alone > 200 and alone < 1800);
}

test words_ms {
    const line = "quiet det.scenario=bank det.timeline_limit_ms=3600000 det.timeline_ms=30000\n";
    try std.testing.expectEqual(@as(?u64, 3600 * std.time.ns_per_s), words_ms(line, "det.timeline_limit_ms="));
    try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_s), words_ms(line, "det.timeline_ms="));
    try std.testing.expectEqual(@as(?u64, null), words_ms("quiet det.scenario=bank", "det.timeline_ms="));
    try std.testing.expectEqual(@as(?u64, null), words_ms("det.timeline_ms=soon", "det.timeline_ms="));
}

/// At most one eventually command (which stops everything else) or one finally command.
const Ending = enum { eventually, finally, none };

fn ending_pick(composer: *const Composer) Ending {
    const eventually = composer.kind_count(.eventually) > 0;
    const finally = composer.kind_count(.finally) > 0;
    if (eventually and (!finally or sdk.random_below(2) == 0)) return .eventually;
    return if (finally) .finally else .none;
}

fn run_ending(composer: *Composer, ending: Ending, window_ms: u32) void {
    assert(composer.running_count == 0);
    switch (ending) {
        .eventually => run_ending_command(composer, composer.pick(.eventually), window_ms),
        .finally => if (composer.interrupted == 0) {
            run_ending_command(composer, composer.pick(.finally), window_ms);
        } else {
            sdk.event("finally_skipped", .{ .interrupted = composer.interrupted });
        },
        .none => {},
    }
}

/// The ending's command, within its window of virtual time (schema.Scenario.ending_ms_max):
/// past it, killed. A check retrying a system that never came back otherwise held a timeline
/// for hours (DuckDB's trial run 1200: four hours of 60 s requests; Oxia's 1201: 12 keys of 120
/// attempts each).
fn run_ending_command(composer: *Composer, command: *const Command, window_ms: u32) void {
    assert(composer.running_count == 0);
    announce(command, "complete");
    composer.start(command);
    composer.wait_until(now_ns() + @as(u64, window_ms) * std.time.ns_per_ms);
    const finished = composer.running_count == 0;
    sdk.assert_computed(.always, finished, ending_window_property, .{ .command = command.name, .window_ms = window_ms });
    if (!finished) composer.kill_all();
}

const ending_window_property = "an ending command finishes within its window";
const ending_ms_max_default = 20 * std.time.ms_per_min;

const environment = [_:null]?[*:0]const u8{
    "PATH=/opt/determinismo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
    "DETERMINISMO_STOP_FAULTS=" ++ nodes.stop_faults_path,
    "ANTITHESIS_STOP_FAULTS=" ++ nodes.stop_faults_path,
};

/// The seed of this timeline's swarm choices (sdk.swarm_choice), drawn as its drivers start: a
/// named decision ("swarm.seed"), written where every process reads it (sdk.swarm_seed_path,
/// read-only in the nodes). None with --no-swarm (det.swarm=0): plain choices, the comparison.
fn swarm_seed_write() void {
    if (swarm_off()) return;
    const seed = sdk.random_below_named("swarm.seed", std.math.maxInt(u64));
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}\n", .{seed}) catch unreachable;
    const fd = linux.open(sdk.swarm_seed_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), text.ptr, text.len);
    _ = linux.mkdir(sdk.swarm_said_directory, 0o755); // sdk.swarm_said_first's markers.
    sdk.event("swarm_seed", .{ .seed = seed });
}

/// Whether `name` is among `det.keep=<a,b,...>` on the kernel's command line (explore's --keep).
fn keep_asked(name: []const u8) bool {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    var words = std.mem.tokenizeAny(u8, buffer[0..size], " \n");
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, "det.keep=")) continue;
        var names = std.mem.tokenizeScalar(u8, word["det.keep=".len..], ',');
        while (names.next()) |kept| if (std.mem.eql(u8, kept, name)) return true;
    }
    return false;
}

/// `det.dev=1` among the kernel's command line's words (the fast VM's `run --dev`).
fn dev_mode() bool {
    var buffer: [4096]u8 = undefined;
    return dev_in(cmdline_read(&buffer));
}

/// The timeline's kernel command line (sdk.cmdline_path), "" when unreadable.
fn cmdline_read(buffer: *[4096]u8) []const u8 {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return "";
    return buffer[0..size];
}

/// `det.dev=1` among a kernel command line's words.
fn dev_in(cmdline: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (words.next()) |word| if (std.mem.eql(u8, word, "det.dev=1")) return true;
    return false;
}

/// Whether the composer waits for an SDK's declaration of the system's setup before its
/// drivers: a system that declares it (Compose's), unless the machine is a fast VM's dev mode,
/// whose user decides when it is ready and where no drivers start.
fn sdk_setup_waited(system: *const schema.System, cmdline: []const u8) bool {
    return system.sdk_setup and !dev_in(cmdline);
}

test "the composer waits for an SDK's setup in a timeline, never in a fast VM's dev mode" {
    const compose: schema.System = .{ .profile = "default", .nodes = &.{}, .scenarios = &.{}, .sdk_setup = true };
    const program: schema.System = .{ .profile = "default", .nodes = &.{}, .scenarios = &.{} };
    try std.testing.expect(sdk_setup_waited(&compose, "console=ttyS0 det.seed=7 quiet"));
    try std.testing.expect(!sdk_setup_waited(&compose, "console=ttyS0 det.dev=1 quiet\n"));
    try std.testing.expect(!sdk_setup_waited(&program, "console=ttyS0 quiet"));
    try std.testing.expect(!sdk_setup_waited(&program, "det.dev=1"));
    // A word, not a prefix: det.dev=10 is not dev mode.
    try std.testing.expect(sdk_setup_waited(&compose, "det.dev=10"));
}

/// Until a timeline explored from the fast VM says go (sdk.dev_go_path, the agent's).
fn dev_wait() void {
    _ = linux.unlink(sdk.dev_go_path);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, sdk.dev_go_path, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return;
    sdk.event("dev_waiting", .{ .fifo = sdk.dev_go_path });
    const fd = linux.open(sdk.dev_go_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var buffer: [8]u8 = undefined;
    while (true) {
        const result = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(result) == .INTR) continue;
        break;
    }
    sdk.event("dev_go", .{});
}

/// `det.swarm=0` among the kernel's command line's words (explore's --no-swarm).
/// The calling process into the commands' cgroup (a command's child, before its exec).
fn drivers_enter() void {
    const fd = linux.open(drivers_cgroup ++ "/cgroup.procs", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), "0", 1);
}

/// Where this timeline's test commands run. In the root cgroup (flat, as before) each runnable
/// command weighs as much as the whole `nodes` group: DuckDB's drivers, ~24 at once, left its
/// restarted node 7% of the VM's CPU, its open (0.65 s of CPU) not done in 20 s, the system
/// down 44 s (hunt run 1950, timeline 241; docs/PLAN.md). In a cgroup of their own the commands
/// share by its weight, as clients on machines of their own: drawn per timeline, flat among the
/// draws (a server starved by its clients stays reachable), det.drivers_cpu_weight= (explore's
/// --drivers-cpu-weight, 0 flat) to set it; flat with --no-swarm.
fn drivers_cpu_draw() void {
    const weight: u64 = if (cmdline_ms("det.drivers_cpu_weight=")) |ns|
        ns / std.time.ns_per_ms
    else if (swarm_off())
        0
    else
        drivers_cpu_weights[sdk.decide("composer.drivers_cpu", &drivers_cpu_names)];
    sdk.event("drivers_cpu", .{ .weight = weight });
    if (weight == 0) return;
    const made = linux.mkdir(drivers_cgroup, 0o755);
    if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) {
        sdk.assert_unreachable("the test commands' cgroup is made", .{ .errno = @backingInt(linux.errno(made)) });
        return;
    }
    var text_buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{d}", .{@min(weight, 10_000)}) catch unreachable;
    nodes.file_write(drivers_cgroup ++ "/cpu.weight", text) catch |err| {
        sdk.assert_unreachable("the test commands' cgroup takes its CPU weight", .{ .err = @errorName(err) });
        return;
    };
    drivers_join = true;
}

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

/// The most: det-nodes, "exec", a node, its program, "run", the scenario, the command.
const spawn_arguments_max = 7;
comptime {
    assert(spawn_arguments_max >= 7); // det-nodes exec <node> <program> run <scenario> <command>.
}

fn spawn(arguments: []const [*:0]const u8) linux.pid_t {
    assert(arguments.len >= 1);
    assert(arguments.len <= spawn_arguments_max);
    const result = linux.fork();
    assert(linux.errno(result) == .SUCCESS);
    if (result == 0) {
        _ = linux.setpgid(0, 0); // Its own group: killed with what it starts (kill_all).
        var argv: [spawn_arguments_max:null]?[*:0]const u8 = @splat(null);
        for (arguments, 0..) |argument, index| argv[index] = argument;
        _ = linux.execve(arguments[0], &argv, &environment);
        linux.exit_group(127); // Exec failed: reported by the parent as status 127.
    }
    return @intCast(result);
}

/// A test command, its output as events (output.zig) named after it, and in the commands' log.
fn spawn_logged(name: []const u8, arguments: []const [*:0]const u8) linux.pid_t {
    assert(arguments.len >= 1);
    assert(arguments.len <= spawn_arguments_max);
    const pipes = output.pipes() catch return spawn(arguments);
    defer for ([_][2]linux.fd_t{ pipes.stdout, pipes.stderr }) |pipe| {
        for (pipe) |fd| _ = linux.close(fd);
    };
    const result = linux.fork();
    assert(linux.errno(result) == .SUCCESS);
    if (result == 0) {
        // Its own group, as spawn's: kill_all kills the group. Without it a command in a node
        // lived on when killed (only `det-nodes exec` died, not what it had started in the node):
        // TigerBeetle's resubmit driver, killed as the final reads began, went on submitting
        // through them (hunt run 654, timeline 23: the queries returned 32 transfers, the 8 found
        // all that its records named).
        _ = linux.setpgid(0, 0);
        if (drivers_join) drivers_enter();
        _ = linux.dup2(pipes.stdout[1], 1);
        _ = linux.dup2(pipes.stderr[1], 2);
        var argv: [spawn_arguments_max:null]?[*:0]const u8 = @splat(null);
        for (arguments, 0..) |argument, index| argv[index] = argument;
        _ = linux.execve(arguments[0], &argv, &environment);
        linux.exit_group(127);
    }
    output.forward(name, &.{}, &.{}, commands_log, pipes, null) catch {};
    return @intCast(result);
}

const commands_log = "/run/det/commands.log";

/// Built-in properties, as Antithesis's test composer has: every command is started, and runs
/// to completion, in some timeline.
/// Antithesis's "The Antithesis Fault Injector was started", for scenarios with faults.
const faults_property = "the fault injector started";

fn commands_declare(composer: *const Composer) void {
    if (composer.faults) sdk.declare("reachable", faults_property);
    for (composer.commands[0..composer.command_count]) |*command| {
        var buffer: [256]u8 = undefined;
        sdk.declare("reachable", command_property(&buffer, "started", command.name));
        sdk.declare("reachable", command_property(&buffer, "completed", command.name));
    }
}

/// Antithesis's "Invalid commands found", for test templates: a file named as a command
/// (compose.templates) that cannot run, not executable or with no interpreter, is never run.
const invalid_property = "test templates hold only valid commands";

fn invalid_report(invalid: []const schema.InvalidCommand) void {
    for (invalid) |command| {
        sdk.assert_computed(.always, false, invalid_property, .{ .path = command.path, .why = command.why });
    }
    if (invalid.len == 0) sdk.assert_computed(.always, true, invalid_property, .{});
}

fn command_property(buffer: *[256]u8, what: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "test command {s}: {s}", .{ what, name }) catch
        buffer[0..0];
}

fn report_exit(command: *const Command, status: u32, killed: bool) void {
    if (killed) { // The composer's doing (an eventually command began), not the command's.
        sdk.event("command_exit", .{ .command = command.name, .killed = true });
        return;
    }
    const exited = status & 0x7f == 0;
    if (exited and !said_before(&completed_said, command)) {
        var buffer: [256]u8 = undefined;
        const property = command_property(&buffer, "completed", command.name);
        sdk.assert_computed(.reachable, true, property, .{});
    }
    const code = if (exited) (status >> 8) & 0xff else 128 + (status & 0x7f);
    const name = command.name;
    sdk.event("command_exit", .{ .command = name, .status = code });
    if (code != 0 or !exit_success_said) {
        exit_success_said = exit_success_said or code == 0;
        const details = .{ .command = name, .status = code };
        sdk.assert_computed(.always, code == 0, "test commands exit successfully", details);
    }
}

fn pause(duration_ns: u64) void {
    assert(duration_ns < pause_ns_max);
    const request = linux.timespec{
        .sec = 0,
        .nsec = @intCast(duration_ns),
    };
    _ = linux.nanosleep(&request, null); // Interruption only shortens a random pause.
}
