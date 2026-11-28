// SPDX-License-Identifier: MIT
//! The node runtime (ARCHITECTURE.md D19): runs each node of the resolved system
//! (/det/system.json) as a container we build ourselves.
//!
//! A node gets its own mount, PID, network, UTS and IPC namespaces; its root filesystem is an
//! overlay of its read-only disk and a writable layer of its own (so its writes live in guest
//! memory and are part of every snapshot): a tmpfs, or with crash faults an ext4 disk on a loop
//! device, which a crash shuts down without flushing (what was not synced is lost); its
//! processes share one cgroup, which pauses (freeze) and kills them as a unit. The guest network
//! is a full mesh: one veth pair between every two running nodes and between each node and the
//! runner (the guest's root namespace, where tests run), so a
//! partition is one link going down. Every link of a node carries the node's one /32 address,
//! with a host route per peer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const schema = sdk.schema;
const netlink = @import("netlink.zig");
const crash_names = @import("crash_names.zig");
const output = @import("output.zig");
const exits_zig = @import("exits.zig");
pub const LinkState = netlink.LinkState;

pub const system_path = "/det/system.json";
const state_root = "/run/det/nodes";
/// Shared volumes (schema.Volume.shared), a directory each, in the guest's memory beside the
/// nodes' disks: a node's power loss or wipe leaves them as a container's leaves the host's.
const volumes_root = "/run/det/volumes";
pub const cgroup_root = "/sys/fs/cgroup/nodes";
const system_size_max = 1 << 20;
pub const path_size_max = 256;
const arguments_max = 64;
const environment_max = 128;
/// determinismo's JVM coverage agent (build.zig, tools/initramfs.zig), on every node's
/// JAVA_TOOL_OPTIONS: each JVM's code covered (every class but the JDK's, narrowed by a program's
/// own -javaagent=<prefixes>), and where thread pausing pauses, with no change to an image, as
/// Antithesis instruments the JVM on its side. A JVM before 24 says it instruments nothing as
/// it loads: from 17 on, only classes instrumented ahead of time at the image's build report.
const coverage_agent = "-javaagent:/opt/determinismo/lib/determinismo-coverage.jar";

const JavaOptions = struct {
    /// NAME=value, the agent after the node's own options.
    entry: [:0]const u8,
    /// The node's entry it stands for (the same slice), or none: added.
    replaces: ?[]const u8,
};

/// Where a command run covered finds Python's coverage (initramfs.zig's): a sitecustomize, which
/// every Python process imports as it starts, and the Python SDK it starts coverage with.
const python_coverage_path = "/opt/determinismo/lib/python";

/// PYTHONPATH with python_coverage_path before the node's own entries, for a command run covered
/// (`det-nodes exec --coverage`: a CI job's tests): each Python process it starts reports the
/// lines of its own code with no change to the repository, as its JVMs do. None when the node's
/// coverage set is off (DETERMINISMO_COVERAGE=!).
fn python_options(arena: std.mem.Allocator, knobs: []const []const u8, env: []const []const u8) !?JavaOptions {
    const name = "PYTHONPATH=";
    var own: ?[]const u8 = null;
    for (env) |entry| {
        if (std.mem.eql(u8, entry, "DETERMINISMO_COVERAGE=!")) return null;
        if (std.mem.startsWith(u8, entry, name) and !knob_sets(knobs, entry)) own = entry;
    }
    for (knobs) |entry| if (std.mem.startsWith(u8, entry, name)) {
        own = entry;
    };
    const value = if (own) |entry| entry[name.len..] else "";
    const joined = if (value.len == 0)
        try std.fmt.allocPrintSentinel(arena, name ++ python_coverage_path, .{}, 0)
    else
        try std.fmt.allocPrintSentinel(arena, name ++ python_coverage_path ++ ":{s}", .{value}, 0);
    return .{ .entry = joined, .replaces = own };
}

test "a command run covered finds Python's coverage before the node's own PYTHONPATH" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = (try python_options(arena, &.{}, &.{ "PATH=/bin", "HOME=/root" })).?;
    try std.testing.expectEqualStrings("PYTHONPATH=" ++ python_coverage_path, none.entry);
    try std.testing.expect(none.replaces == null);
    const env = [_][]const u8{ "PYTHONPATH=/app/src:/app/lib", "A=1" };
    const own = (try python_options(arena, &.{}, &env)).?;
    try std.testing.expectEqualStrings("PYTHONPATH=" ++ python_coverage_path ++ ":/app/src:/app/lib", own.entry);
    try std.testing.expect(own.replaces.?.ptr == env[0].ptr);
    try std.testing.expect(try python_options(arena, &.{}, &.{ "DETERMINISMO_COVERAGE=!", "A=1" }) == null);
}

/// The node's JAVA_TOOL_OPTIONS with the coverage agent after its own (a knob's first, as the
/// environment takes it), or none when its coverage set is off (DETERMINISMO_COVERAGE=!).
fn java_options(arena: std.mem.Allocator, knobs: []const []const u8, env: []const []const u8) !?JavaOptions {
    const name = "JAVA_TOOL_OPTIONS=";
    var own: ?[]const u8 = null;
    for (env) |entry| {
        if (std.mem.eql(u8, entry, "DETERMINISMO_COVERAGE=!")) return null;
        if (std.mem.startsWith(u8, entry, name) and !knob_sets(knobs, entry)) own = entry;
    }
    for (knobs) |entry| if (std.mem.startsWith(u8, entry, name)) {
        own = entry;
    };
    const value = if (own) |entry| std.mem.trim(u8, entry[name.len..], " ") else "";
    if (std.mem.indexOf(u8, value, "determinismo-coverage.jar") != null and std.mem.indexOf(u8, value, coverage_agent) != null) {
        return null; // Already there.
    }
    const joined = if (value.len == 0)
        try std.fmt.allocPrintSentinel(arena, name ++ coverage_agent, .{}, 0)
    else
        try std.fmt.allocPrintSentinel(arena, name ++ "{s} " ++ coverage_agent, .{value}, 0);
    return .{ .entry = joined, .replaces = own };
}

test "every node's JVMs get the coverage agent after their own options, unless coverage is off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = (try java_options(arena, &.{}, &.{ "PATH=/bin", "HOME=/root" })).?;
    try std.testing.expectEqualStrings("JAVA_TOOL_OPTIONS=" ++ coverage_agent, none.entry);
    try std.testing.expect(none.replaces == null);
    const env = [_][]const u8{ "JAVA_TOOL_OPTIONS=-XX:TieredStopAtLevel=1", "A=1" };
    const own = (try java_options(arena, &.{}, &env)).?;
    try std.testing.expectEqualStrings("JAVA_TOOL_OPTIONS=-XX:TieredStopAtLevel=1 " ++ coverage_agent, own.entry);
    try std.testing.expect(own.replaces.?.ptr == env[0].ptr);
    // A knob's value is the one the environment takes.
    const knob = [_][]const u8{"JAVA_TOOL_OPTIONS=-Xmx512m"};
    const knobbed = (try java_options(arena, &knob, &env)).?;
    try std.testing.expectEqualStrings("JAVA_TOOL_OPTIONS=-Xmx512m " ++ coverage_agent, knobbed.entry);
    try std.testing.expect(knobbed.replaces.?.ptr == knob[0].ptr);
    try std.testing.expect(try java_options(arena, &.{}, &.{ "DETERMINISMO_COVERAGE=!", "A=1" }) == null);
}

/// The coverage entry that stands for the node's `entry` (the same slice), if one does.
fn covered_replacing(covered: []const ?JavaOptions, entry: []const u8) ?[:0]const u8 {
    for (covered) |candidate| {
        const with = candidate orelse continue;
        const replaced = with.replaces orelse continue;
        if (replaced.ptr == entry.ptr) return with.entry;
    }
    return null;
}

/// The quiet-period command (det-stop-faults), at the same path in the runner and every node,
/// whose /opt/determinismo is the runner's, read-only. Its environment variables name it, as
/// Antithesis's ANTITHESIS_STOP_FAULTS does (scripts written for Antithesis work unchanged).
pub const stop_faults_path = "/opt/determinismo/bin/det-stop-faults";
const start_draw_name = "node.start_draw";
const platform_environment = [_][:0]const u8{
    "DETERMINISMO_STOP_FAULTS=" ++ stop_faults_path,
    "ANTITHESIS_STOP_FAULTS=" ++ stop_faults_path,
    "ANTITHESIS_OUTPUT_DIR=" ++ sink_directory,
    "ANTITHESIS_FILTERED_OUTPUT_DIR=" ++ filtered_directory,
};
/// Antithesis's output sink in every node (ANTITHESIS_OUTPUT_DIR): what is written to files
/// there becomes events (det-sinks, sinks.zig).
pub const sink_directory = "/run/antithesis";
/// Antithesis's retroactive sink (ANTITHESIS_FILTERED_OUTPUT_DIR): what is written there is left
/// out of an exploration's logs and comes back in a replay of the timeline (det-sinks sends it as
/// output whose stream is "filtered <file>"; the host's retroactive logging hides those).
pub const filtered_directory = "/run/antithesis-filtered";

/// A node's sink directory (or its retroactive one), as the runner sees it.
pub fn sink_path(buffer: []u8, name: []const u8, filtered: bool) ![]const u8 {
    const directory = if (filtered) filtered_directory else sink_directory;
    return std.fmt.bufPrint(buffer, state_root ++ "/{s}/root{s}", .{ name, directory });
}
const poll_interval_ns = 10 * std.time.ns_per_ms;

const stop_attempts_max = 3000;
const freeze_attempts_max = 100; // 1 s of virtual time.
const link_attempts_max = 500;

pub fn system_load(arena: std.mem.Allocator) !schema.System {
    const source = try read_file(arena, system_path, system_size_max);
    const system = try schema.parse(schema.System, arena, source);
    if (system.schema != schema.version) return error.SchemaVersion;
    if (system.nodes.len > schema.nodes_max) return error.TooManyNodes;
    return system;
}

/// Starts every node in order (the host checked that `after` only names earlier nodes) and
/// waits for each to be ready before starting the next.
pub fn up(arena: std.mem.Allocator, system: *const schema.System) !void {
    try mkdir_all(state_root);
    try mkdir_all(cgroup_root);
    // Controllers in node cgroups: cpu for throttling faults, memory for limits, and all of
    // them for nodes that run containers (kubelet wants cpuset, io and pids too).
    const controls = [_][:0]const u8{
        "/sys/fs/cgroup/cgroup.subtree_control", cgroup_root ++ "/cgroup.subtree_control",
    };
    for (controls) |control| {
        try file_write(control, "+cpu +memory");
        for ([_][]const u8{ "+cpuset", "+io", "+pids", "+hugetlb" }) |controller| {
            file_write(control, controller) catch {}; // Optional: not every kernel has them.
        }
    }
    try hosts_write("/etc/hosts", system, null);
    host_settings();
    for (system.nodes, 0..) |*node, index| {
        if (node.spare) continue; // A driver starts it.
        try start(arena, system, node);
        if (node.once) {
            try once_wait(node);
            continue;
        }
        ready_wait(node) catch |err| {
            // Said, with the nodes it waited before: a readiness that needs them never comes
            // (Patroni's REST API waits for an etcd quorum; the first smoke said only that setup
            // never completed).
            var later: std.ArrayList(u8) = .empty;
            for (system.nodes[index + 1 ..], 0..) |other, at| {
                if (at > 0) later.appendSlice(arena, ", ") catch {};
                later.appendSlice(arena, other.name) catch {};
            }
            sdk.event("node_not_ready", .{
                .node = node.name,
                .tcp = if (node.ready) |ready| ready.tcp else 0,
                .err = @errorName(err),
                .not_started = later.items,
            });
            if (err == error.NodeNotReady) std.debug.print("[guest] node {s} never became ready " ++
                "(nothing accepted on tcp {d}); not started meanwhile: {s}. Does its readiness wait " ++
                "for them (a quorum, a peer)? A port it opens alone is ready earlier.\n", .{
                node.name, if (node.ready) |ready| ready.tcp else 0, if (later.items.len > 0) later.items else "none",
            });
            return err;
        };
    }
    sdk.event("nodes_up", .{ .nodes = system.nodes.len });
}

/// Starts one node (again, after a kill: its files survive in the overlay's upper layer).
pub fn start(
    arena: std.mem.Allocator,
    system: *const schema.System,
    node: *const schema.Resolved,
) !void {
    assert(schema.name_valid(node.name));
    // One start of a node at a time, across processes: det-faults starting it again after a
    // fault and a driver starting it (a spare) both found it not running and both started it,
    // two of its programs on one disk (Kafka's dynamic quorum's smoke, srv3, 2026-10-30: the
    // other's rename took quorum-state.tmp away, and the broker exited). Unlocked, not only
    // closed: the node's first process holds a copy of the file until it execs.
    var lock = try start_lock(node.name);
    defer start_unlock(lock);
    // A process a graceful stop signalled is the node's until it ends (stop_signal takes its
    // pidfile at once): a start then waits for it, as a supervisor does, never a second
    // incarnation beside it on the node's disk. A driver's start during a stop fault's grace
    // ran so in 68 of etcd's run 2007's 9,628 stops (53 timelines, about 100 ms together; its
    // bbolt and WAL file locks made the new one wait, another system's data would be shared).
    while (stopping(node.name) != null) {
        start_unlock(lock);
        try stopping_wait(node.name);
        lock = try start_lock(node.name);
    }
    if (pid_read(node.name) != null) return error.AlreadyRunning;
    var paths: Paths = undefined;
    try paths.init(node.name);
    // A new start: a disk fault healed before it is not this start's (disk_failed_this_start).
    var failed_buffer: [path_size_max]u8 = undefined;
    _ = linux.unlink(try disk_failed_path(&failed_buffer, &paths));
    const current = effective(node, &paths);
    try root_prepare(&paths, system, &current);
    try memory_limit(&paths, node.memory_max_mib);
    // A new incarnation runs: a freeze its cgroup still has was the gone one's. An outage froze
    // every node, a driver's wipe started one again before the outage's crash came to it, and
    // started frozen its first process never reached the program: the start waited for it with
    // the start lock held, the outage's crash of the node behind it (dqlite's run 746, timeline
    // 313: the fault injector stalled 785 s, until the length killed the driver). No crash runs
    // meanwhile: it holds the start lock.
    try file_write(paths.cgroup_freeze, "0");
    const launch = try Launch.init(arena, &current, &paths, .start);
    const output_pipes = try output.pipes();
    // Where this start's output begins in the node's log (appended across starts): its exit is
    // judged on it alone (cores.zig's known exits).
    try file_write(paths.output_start, try std.fmt.allocPrint(arena, "{d}\n", .{file_size(paths.output)}));
    var sync: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&sync, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    // Closed in the child by its exec (or its death): until then its root is not the node's,
    // and a command run in the node (through /proc/<pid>/root) would not find its files.
    var running: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&running, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    // Its exits filter's listener (exits.zig), sent by its first process to its forwarder.
    var exits: [2]linux.fd_t = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0, &exits)) != .SUCCESS) return error.Socket;
    const child: Child = .{ .launch = &launch, .sync = sync, .running = running, .output = output_pipes, .exits = exits };
    // When this start began (CLOCK_MONOTONIC, ms since boot), before its program can run: the
    // persistence audit's line between what the node wrote before it and relies on after it
    // (persist_trace.zig's node_open_unsynced).
    started_write(paths.directory);
    // det-init's child, whoever starts it: det-init reaps it as it exits and judges the exit
    // then. Started by det-faults (after a fault) it was det-faults' child, unreaped until the
    // faults stopped: its exit judged only then (Consul's smoke, srv3, 2026-10-30: a restart
    // that refused to boot at 7.4 s judged at 10.9 s), and the zombie taken for running.
    const pid = if (linux.getpid() == 1) try child.clone() else try child.clone_orphaned();
    // A start that fails from here on leaves nothing running: the child is the first process
    // of its PID namespace, so the namespace goes with it. (A pidfile that could not be
    // written, with /run full, once left a node running that no fault could reach: a crash
    // shut its disk down under it, and its program restarted against EIO for minutes.)
    errdefer _ = linux.kill(pid, .KILL);
    _ = linux.close(running[1]); // Before the forwarder's fork: only the child holds it.
    defer _ = linux.close(running[0]);
    _ = linux.close(exits[0]); // The child's end.
    defer _ = linux.close(exits[1]); // The forwarder's, once it has its own.
    try output.forward(node.name, node.panics_known, node.log_failures, paths.output, output_pipes, exits[1]);
    for ([_][2]linux.fd_t{ output_pipes.stdout, output_pipes.stderr }) |pipe| {
        for (pipe) |fd| _ = linux.close(fd);
    }
    _ = linux.close(sync[0]);
    defer _ = linux.close(sync[1]);
    try cgroup_join(&paths, pid);
    try network_connect(system, node, pid);
    _ = linux.write(sync[1], "g", 1);
    var byte: [1]u8 = undefined;
    _ = linux.read(running[0], &byte, 1); // End of file: it runs the node's program (or died).
    try file_write(paths.pid, try std.fmt.allocPrint(arena, "{d}\n", .{pid}));
    sdk.event("node_start", .{ .node = node.name, .pid = pid });
    relist(system, node);
}

/// The node's first process, cloned into its namespaces, and what it needs to become the node's
/// program.
const Child = struct {
    launch: *const Launch,
    sync: [2]linux.fd_t,
    running: [2]linux.fd_t,
    output: output.Pipes,
    exits: [2]linux.fd_t,

    const flags = linux.CLONE.NEWNS | linux.CLONE.NEWUTS | linux.CLONE.NEWIPC |
        linux.CLONE.NEWNET | linux.CLONE.NEWPID | @backingInt(linux.SIG.CHLD);

    /// Cloned as this process's child.
    fn clone(child: *const Child) !linux.pid_t {
        const result = linux.syscall5(.clone, flags, 0, 0, 0, 0);
        if (linux.errno(result) != .SUCCESS) return error.Clone;
        if (result == 0) child.run();
        return @intCast(result);
    }

    /// Cloned by an intermediate process that exits at once: an orphan, det-init's (PID 1) to
    /// reap. Its PID comes back through a pipe (0: the clone failed).
    fn clone_orphaned(child: *const Child) !linux.pid_t {
        var said: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&said, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        defer _ = linux.close(said[0]);
        const middle = linux.fork();
        if (linux.errno(middle) != .SUCCESS) {
            _ = linux.close(said[1]);
            return error.Fork;
        }
        if (middle == 0) {
            const result = linux.syscall5(.clone, flags, 0, 0, 0, 0);
            if (result == 0) child.run();
            const pid: linux.pid_t = if (linux.errno(result) == .SUCCESS) @intCast(result) else 0;
            _ = linux.write(said[1], std.mem.asBytes(&pid), @sizeOf(linux.pid_t));
            linux.exit_group(0);
        }
        _ = linux.close(said[1]);
        var status: i32 = 0;
        while (linux.errno(linux.wait4(@intCast(middle), &status, 0, null)) == .INTR) {}
        var pid: linux.pid_t = 0;
        if (linux.read(said[0], std.mem.asBytes(&pid), @sizeOf(linux.pid_t)) != @sizeOf(linux.pid_t) or pid == 0) {
            return error.Clone;
        }
        return pid;
    }

    fn run(child: *const Child) noreturn {
        _ = linux.close(child.sync[1]);
        _ = linux.close(child.running[0]);
        _ = linux.close(child.exits[1]);
        // Other nodes' mounts go first, before it is in the node's cgroup within reach of its
        // faults: a copy held here keeps another node's disk alive after its crash (its remount
        // gets the old, shut down filesystem back, or the disk is busy), and a fault may stop
        // or freeze it for seconds before it runs the node's program.
        child.launch.mounts_detach_other_nodes() catch |err| die("detach", err);
        // The parent has set up cgroup and network: its "g", nothing else (it failed, and
        // closed the pipe: a node running outside its cgroup, without a pidfile, would be out
        // of reach of every fault).
        var byte: [1]u8 = undefined;
        if (linux.read(child.sync[0], &byte, 1) != 1 or byte[0] != 'g') linux.exit_group(1);
        // Its own cgroup namespace, rooted at its cgroup (as containers have): what it creates
        // there (kubelet's pods) stays under the node, within reach of its faults.
        if (linux.errno(linux.unshare(linux.CLONE.NEWCGROUP)) != .SUCCESS) {
            die("unshare", error.Unshare);
        }
        // Its own time namespace, entered at the exec: its realtime clock can be skewed apart
        // from the other nodes' (clock_offset, the clock_skew fault).
        if (linux.errno(linux.unshare(linux.CLONE.NEWTIME)) != .SUCCESS) {
            die("unshare", error.Unshare);
        }
        // Its own session and process group, as a container's init has (runc's setsid). In the
        // group of what started it (a driver's; with det-nodes in a group of its own, the one
        // every node `det-nodes up` started), a member's exit left the group orphaned while a
        // node was stopped by a process pause, and the kernel sent every member SIGHUP: Go's
        // runtime, PID 1 of its namespace, dies of it with a silent exit(2) (dqlite run 746: 16
        // timelines' "no unexpected container exits", status 2, the member driver's exit at
        // 41.62 s in timeline 116; trial run 750, timeline 0: n2 paused from 2.95 s, n4 and its
        // forwarder gone at 4.52 s). The e2e check `hangup` keeps it so.
        if (linux.errno(linux.setsid()) != .SUCCESS) die("setsid", error.Setsid);
        child.launch.exec(child.output.stdout[1], child.output.stderr[1], child.exits[0]); // Never returns.
    }
};

/// A command run in a node: `coverage` gives its JVMs determinismo's coverage agent, as the
/// node's start's have, and its Python processes the SDK's coverage (`det-nodes exec
/// --coverage`): a CI job's tests, whose code is the system under test; by default a driver's
/// tools run without it (Launch.init).
/// `quiet`: its output discarded (a readiness command's, run every second).
pub const ExecOptions = struct { coverage: bool = false, quiet: bool = false };

/// Runs `argv` inside a running node (its namespaces, root, environment and user), like
/// `docker exec`, with this process's standard streams. Returns the command's exit status.
pub fn exec(
    arena: std.mem.Allocator,
    node: *const schema.Resolved,
    argv: []const []const u8,
    options: ExecOptions,
) !u8 {
    if (argv.len == 0) return error.NoCommand;
    const pid = pid_read(node.name) orelse pid: {
        // A start under way: its program may answer already, before the start writes its pid
        // (it runs from its exec on), and a command sent once it answered found it not running
        // (the e2e disk check's selftest, 2026-11-06: its read after a power loss 0.1 ms before
        // node_start). Its start lock is held until then: waited for, the pid read again.
        start_unlock(try start_lock(node.name));
        break :pid pid_read(node.name) orelse return error.NotRunning;
    };
    var root_buffer: [64]u8 = undefined;
    const root = try print_z(&root_buffer, "/proc/{d}/root", .{pid});
    var paths: Paths = undefined;
    try paths.init(node.name);
    const running = effective(node, &paths);
    const exec_node = schema.Resolved{
        .name = node.name,
        .address = node.address,
        .disk = running.disk,
        .digest = running.digest,
        .command = argv,
        .env = running.env,
        .workdir = running.workdir,
        .user = running.user,
        .ulimits = node.ulimits, // As docker exec: the container's limits.
        .hostname = node.hostname, // Its HOSTNAME as the start's (docker exec: the container's).
    };
    paths.root = root; // The node's root as this namespace sees it.
    const launch = try Launch.init(arena, &exec_node, &paths, if (options.coverage) .exec_covered else .exec);
    // Namespace files first: after joining the mount namespace, /proc is the node's.
    var namespace_fds: [namespaces.len]linux.fd_t = undefined;
    for (namespaces, &namespace_fds) |namespace, *fd| {
        var buffer: [64]u8 = undefined;
        const path = try print_z(&buffer, "/proc/{d}/ns/{s}", .{ pid, namespace.name });
        const result = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) return error.NoSuchNamespace;
        fd.* = @intCast(result);
    }
    const directory: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_fd = linux.open(root, directory, 0);
    if (linux.errno(root_fd) != .SUCCESS) return error.NoSuchRoot;
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return error.Fork;
    if (child == 0) {
        // Like the node's own processes: its CPU and memory limits, its freezes and kills.
        cgroup_join_self(&paths) catch |err| die("cgroup", err);
        for (namespaces, namespace_fds) |namespace, fd| {
            if (linux.errno(linux.setns(fd, namespace.flag)) != .SUCCESS) die("setns", error.Setns);
        }
        if (options.quiet) {
            const null_output = linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
            if (linux.errno(null_output) == .SUCCESS) {
                _ = linux.dup2(@intCast(null_output), 1);
                _ = linux.dup2(@intCast(null_output), 2);
            }
        }
        if (linux.errno(linux.fchdir(@intCast(root_fd))) != .SUCCESS) die("root", error.Chdir);
        if (linux.errno(linux.chroot(".")) != .SUCCESS) die("chroot", error.Chroot);
        // Joining a PID namespace places only the children: the command runs in a second
        // fork, or /proc/self would not resolve in the node (musl finds $ORIGIN through it).
        const command = linux.fork();
        if (linux.errno(command) != .SUCCESS) die("fork", error.Fork);
        if (command == 0) launch.exec_in_root(null); // Never returns.
        linux.exit_group(wait_status(@intCast(command), null));
    }
    var usage: linux.rusage = std.mem.zeroes(linux.rusage);
    const status = wait_status(@intCast(child), &usage);
    exec_cpu_note(node.name, argv[0], usage);
    return status;
}

/// The exit status of `pid`, or 128 + the signal that killed it (as shells report it); with
/// `usage`, its CPU and its reaped descendants' (wait4's).
fn wait_status(pid: linux.pid_t, usage: ?*linux.rusage) u8 {
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, usage);
    const bits: u32 = @bitCast(status);
    return if (bits & 0x7f == 0) @intCast((bits >> 8) & 0xff) else @intCast(128 + (bits & 0x7f));
}

/// Where each command run in a node (`exec`) says what it cost, a line each: the node, the
/// command's name, and its CPU (its process tree's, from wait4). det-init sums them by node and
/// command at a timeline's end (`exec_cpu` events). A node's own CPU (its cgroup's) counts them
/// too, so a tool's runtime started per call looked like the node's work: Cassandra's
/// `nodetool status`, a JVM of 1.1 to 2 s on the guest's one CPU, about 100 a timeline, most of
/// what run 964's timelines computed.
pub const exec_cpu_path = "/run/det/exec-cpu";

fn exec_cpu_note(name: []const u8, command: []const u8, usage: linux.rusage) void {
    var line: [exec_cpu_line_max]u8 = undefined;
    const text = exec_cpu_line(&line, name, command, usage) orelse return;
    const fd = linux.open(exec_cpu_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), text.ptr, text.len); // One write: whole, whatever the writers.
}

pub const exec_cpu_line_max = 2 * exec_cpu_name_max + 32;
pub const exec_cpu_name_max = 64;

/// "<node> <command> <cpu µs>\n": the command by its file's name, cut to a word.
fn exec_cpu_line(buffer: *[exec_cpu_line_max]u8, name: []const u8, command: []const u8, usage: linux.rusage) ?[]const u8 {
    const base = std.fs.path.basename(command);
    const word = base[0 .. std.mem.indexOfAny(u8, base, " \t\n") orelse base.len];
    if (word.len == 0) return null;
    const cpu_us = timeval_us(usage.utime) + timeval_us(usage.stime);
    return std.fmt.bufPrint(buffer, "{s} {s} {d}\n", .{
        name[0..@min(name.len, exec_cpu_name_max)], word[0..@min(word.len, exec_cpu_name_max)], cpu_us,
    }) catch null;
}

fn timeval_us(value: linux.timeval) u64 {
    if (value.sec < 0 or value.usec < 0) return 0;
    return @as(u64, @intCast(value.sec)) * std.time.us_per_s + @as(u64, @intCast(value.usec));
}

test exec_cpu_line {
    var buffer: [exec_cpu_line_max]u8 = undefined;
    var usage = std.mem.zeroes(linux.rusage);
    usage.utime = .{ .sec = 1, .usec = 960_000 };
    usage.stime = .{ .sec = 0, .usec = 90_000 };
    try std.testing.expectEqualStrings("n1 nodetool 2050000\n", exec_cpu_line(&buffer, "n1", "/opt/cassandra/bin/nodetool", usage).?);
    try std.testing.expectEqualStrings("n1 sh 0\n", exec_cpu_line(&buffer, "n1", "sh", std.mem.zeroes(linux.rusage)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), exec_cpu_line(&buffer, "n1", "", usage));
}

const Namespace = struct { name: []const u8, flag: u32 };
/// The PID namespace applies to children: exec forks after joining.
const namespaces = [_]Namespace{
    .{ .name = "ipc", .flag = linux.CLONE.NEWIPC },
    .{ .name = "uts", .flag = linux.CLONE.NEWUTS },
    .{ .name = "net", .flag = linux.CLONE.NEWNET },
    .{ .name = "cgroup", .flag = linux.CLONE.NEWCGROUP },
    .{ .name = "pid", .flag = linux.CLONE.NEWPID },
    .{ .name = "time", .flag = linux.CLONE.NEWTIME },
    .{ .name = "mnt", .flag = linux.CLONE.NEWNS },
};

/// Kills every process of the node and waits until they are gone.
/// The node as it runs now: on its next release (its root filesystem, command, environment and
/// user: schema.Resolved.upgrade) while its variant file says so, else as described.
fn effective(node: *const schema.Resolved, paths: *const Paths) schema.Resolved {
    var running = node.*;
    const next = node.upgrade orelse return running;
    if (!exists(paths.variant)) return running;
    running.disk = next.disk;
    running.digest = next.digest;
    running.command = next.command;
    running.env = next.env;
    running.workdir = next.workdir;
    running.user = next.user;
    return running;
}

/// Restarts the node on its next release (`next`) or its own image: stopped gracefully (SIGTERM,
/// killed past a grace), its root filesystem swapped under its writable layer (its data kept,
/// as an operator's package upgrade keeps /var), and started again with that image's command and
/// environment (FoundationDB's restarting tests; a rolling upgrade one node at a time, or a
/// downgrade). A node not running (a spare outside its cluster, one a fault stopped) only has
/// its image swapped: its next start runs it. Nothing when it is on that one already.
pub fn upgrade(arena: std.mem.Allocator, system: *const schema.System, node: *const schema.Resolved, next: bool) !void {
    const variant = node.upgrade orelse return error.NoUpgrade;
    var was_running = false;
    {
        const lock = try start_lock(node.name);
        defer start_unlock(lock);
        var paths: Paths = undefined;
        try paths.init(node.name);
        if (exists(paths.variant) == next) return;
        was_running = pid_read(node.name) != null;
        if (was_running) {
            stop_signal(node.name) catch {};
            var waited_ns: u64 = 0;
            while (!exited(node.name) and waited_ns < upgrade_grace_ns) : (waited_ns += poll_interval_ns) {
                sleep_ns(poll_interval_ns);
            }
            try kill_remaining(node.name);
        }
        // The overlay off, its lower image swapped, the overlay back on the same layer.
        const mounted = exists(paths.mounted);
        if (mounted) try unmount_retrying(paths.root);
        if (exists(paths.root)) _ = linux.umount2(paths.lower, 0);
        // A spare never started has no directory yet (etcd's spare, trial run 1613).
        try mkdir_all(paths.directory);
        if (next) try file_write(paths.variant, "") else _ = linux.unlink(paths.variant);
        if (exists(paths.root)) {
            var device_buffer: [32]u8 = undefined;
            const device = try print_z(&device_buffer, "/dev/{s}", .{if (next) variant.disk else node.disk});
            try mount(device, paths.lower, "erofs", linux.MS.RDONLY, null);
        }
        if (mounted) {
            var options_buffer: [3 * path_size_max]u8 = undefined;
            const options = try print_z(&options_buffer, "lowerdir={s},upperdir={s},workdir={s}", .{
                paths.lower, paths.upper, paths.work,
            });
            try mount("overlay", paths.root, "overlay", 0, options);
        }
        sdk.event("node_upgrade", .{
            .node = node.name,
            .to = if (next) "next" else "base",
            .digest = if (next) variant.digest else node.digest,
            .running = was_running,
        });
    }
    if (!was_running) return;
    start(arena, system, node) catch |err| switch (err) {
        error.AlreadyRunning => {}, // A fault's restart came first: on the image swapped in.
        else => return err,
    };
}

/// A graceful stop's grace before an upgrade kills what is left (the stop fault's).
const upgrade_grace_ns = 3 * std.time.ns_per_s;

fn unmount_retrying(path: [:0]const u8) !void {
    for (0..stop_attempts_max) |_| {
        const result = linux.umount2(path, 0);
        if (linux.errno(result) == .SUCCESS or linux.errno(result) == .INVAL) return;
        sleep_ns(poll_interval_ns); // Busy until the killed processes are reaped.
    }
    return error.UnmountFailed;
}

/// Under the node's start lock, as a crash and a wipe: a start waits for a kill under way, and a
/// kill for a start. Unlocked, a driver's kill and the fault injector's start of one node ran
/// into each other: the kill emptied the cgroup, the injector (a stop fault's end, waiting for
/// just that) started the node again, and the kill's next look, "again at each look", killed
/// the new process between its clone and its network: "a faulted node starts again" failed,
/// NoSuchNamespace (etcd's 12-hour run 2007, timeline 1016 at 28.23 s: the member driver's
/// kill of its spare, 21 ms after the injector's start began).
pub fn kill(name: []const u8) !void {
    var lock_path_buffer: [path_size_max]u8 = undefined;
    return kill_under(try print_z(&lock_path_buffer, state_root ++ "/{s}.start", .{name}), name);
}

fn kill_under(lock_path: [:0]const u8, name: []const u8) !void {
    const lock = try lock_take(lock_path);
    defer start_unlock(lock);
    return kill_locked(name);
}

test "a kill waits for the node's start lock" {
    var lock_buffer: [path_size_max]u8 = undefined;
    const lock_path = try print_z(&lock_buffer, "/tmp/det-kill-test-{d}.start", .{linux.getpid()});
    defer _ = linux.unlink(lock_path);
    // A start under way in another process: it holds the lock 300 ms, saying so once it has it.
    var held: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&held, .{ .CLOEXEC = true })) == .SUCCESS);
    const forked = linux.fork();
    try std.testing.expect(linux.errno(forked) == .SUCCESS);
    if (forked == 0) {
        _ = lock_take(lock_path) catch linux.exit_group(2);
        _ = linux.write(held[1], "h", 1);
        sleep_ns(300 * std.time.ns_per_ms);
        linux.exit_group(0); // Its lock goes with it.
    }
    _ = linux.close(held[1]);
    var byte: [1]u8 = undefined;
    try std.testing.expect(linux.read(held[0], &byte, 1) == 1);
    _ = linux.close(held[0]);
    var before: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &before);
    try kill_under(lock_path, "killtest"); // Not running: nothing to kill.
    var after: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &after);
    const waited_ms = (after.sec - before.sec) * 1000 + @divTrunc(after.nsec - before.nsec, std.time.ns_per_ms);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(forked), &status, 0);
    try std.testing.expect(waited_ms >= 200);
}

/// `kill`'s own, for a caller that holds the node's start lock already (a crash, a wipe).
fn kill_locked(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    // Not running, and no process a graceful stop signalled still ending: that one is killed as
    // the node's (a kill during a shutdown ends it; left alone, the node was not down when the
    // kill returned, and the driver's start after it ran beside it).
    if (pid_read(name) == null and stopping(name) == null) return;
    // The pidfile goes first: an exit of a process it names is unexpected (see det-init).
    _ = linux.unlink(paths.pid);
    for (0..stop_attempts_max) |_| {
        // Again at each look: a `det-nodes exec` that read the pid before the unlink joins the
        // cgroup after a kill, frozen there by a crash, and one kill never reached it (Galera's
        // trial run 426: the fault injector held 30 s, the crash given up, twice).
        try file_write(paths.cgroup_kill, "1");
        if (!try cgroup_populated(&paths)) break;
        sleep_ns(poll_interval_ns);
    } else return error.NodeDidNotStop;
    sdk.event("node_kill", .{ .node = name });
}

/// A graceful stop begins: SIGTERM to its main process (its exit is expected from now on).
/// `kill_remaining` ends it if the node is still running after its grace period.
pub fn stop_signal(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    const pid = pid_recorded(name) orelse return error.NotRunning;
    // A pidfd holds that very process: checked as the node's (pid_read), then signalled, never
    // another that took its number in between.
    const pidfd = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd) != .SUCCESS) return error.NotRunning;
    defer _ = linux.close(@intCast(pidfd));
    if (pid_read(name) != pid) return error.NotRunning;
    // The pidfile goes first: its exit is expected (see det-init). The process is kept as the
    // one stopping: det-init judges its exit when it comes, as the node's, with what it said.
    // A process stopping slowly (a Galera joiner mid state transfer) went on 2 s and crashed
    // in an abort it had announced, a known exit; with the pidfile gone, its crash was judged
    // at the timeline's end by its name alone (hunt run 1952, timeline 15, n1 at 349.35 s).
    var text_buffer: [16]u8 = undefined;
    try file_write(paths.stopping, std.fmt.bufPrint(&text_buffer, "{d}\n", .{pid}) catch unreachable);
    _ = linux.unlink(paths.pid);
    _ = linux.pidfd_send_signal(@intCast(pidfd), .TERM, null, 0);
    sdk.event("node_stop", .{ .node = name });
}

/// Kills whatever is left of the node (after a graceful stop: its pidfile is already gone).
pub fn kill_remaining(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    for (0..stop_attempts_max) |_| {
        if (!try cgroup_populated(&paths)) return;
        try file_write(paths.cgroup_kill, "1"); // Again at each look, as `kill`.
        sleep_ns(poll_interval_ns);
    }
    return error.NodeDidNotStop;
}

/// A power loss: the node's disk keeps what reached it (synced, or written back already) and
/// loses the rest; its processes are gone. The next start mounts the disk again (ext4 replays
/// its journal: consistent, as after a real crash).
pub fn crash(name: []const u8, partial: ?Partial) !void {
    return crash_with(name, null, partial);
}

/// Unsynced pages that reached the disk anyway when the power went. A host's flusher writes
/// dirty pages back in its own order, so at a power loss part of them may be on the disk: code
/// that assumes "B is on the disk, so A, written before it, is too" breaks only then (LazyFS's
/// torn-seq and torn-op faults: Ramos et al., "When Amnesia Strikes", VLDB 2024). Ours is
/// otherwise all or nothing (no background writeback: writeback_relax). Drawn from `seed`, a
/// platform decision: a file in three of the node's layer, and of each a few 4 KiB pages. Over
/// blocks already allocated (an overwrite in place, a preallocated or memory-mapped segment) any
/// of them, in no order: a page dirtied again after the flusher's last pass goes before an
/// earlier one. A file's new data, its blocks not allocated yet (ext4's delayed allocation),
/// goes as the flusher writes it, an ascending run from the start of one of its new ranges
/// (FIEMAP's delayed-allocation extents, and its unwritten ones: allocated, read as zeros
/// until their data is written, `dioread_nolock`'s way, Linux 6.12's default): never a page before an earlier one of a fresh file, which leaves the earlier a hole
/// (zeros) under the committed size, what a real power loss hardly does (Cassandra's run 1067,
/// timeline 31: a fresh hints file's first page zeros, its node never started). With `commit`,
/// the journal is committed after them (their blocks' allocation durable: appended pages
/// survive too, and the metadata ext4's periodic commit would have written), else only pages
/// over blocks already allocated survive.
pub const Partial = struct { seed: u64, commit: bool };
const partial_files_max = 4096;
const partial_pages_max = 16;
const partial_depth_max = 16;
const partial_page_size = 4096;
const sync_file_range_wait_before = 1;
const sync_file_range_write = 2;
const sync_file_range_wait_after = 4;

/// `unmapped`: drawn files whose extents FIEMAP did not give, left alone (the layer is ext4, which
/// gives them: one is a fault of ours, the event says so). `delalloc` and `unwritten`: the drawn
/// files' new pages of each kind, before their write back.
const PartialCount = struct {
    walked: u32 = 0,
    files: u32 = 0,
    pages: u32 = 0,
    unmapped: u32 = 0,
    delalloc: u32 = 0,
    unwritten: u32 = 0,
};

/// FS_IOC_FIEMAP (_IOWR('f', 11, struct fiemap)): a file's extents. Without FIEMAP_FLAG_SYNC,
/// which would write the file back first.
const fiemap_request = 0xC020_660B;
const fiemap_extent_delalloc = 0x4;
const fiemap_extent_unwritten = 0x800;
const fiemap_extents_max = 64;
const FiemapExtent = extern struct {
    logical: u64,
    physical: u64,
    length: u64,
    reserved64: [2]u64,
    flags: u32,
    reserved: [3]u32,
};
const Fiemap = extern struct {
    start: u64,
    length: u64,
    flags: u32,
    mapped_extents: u32,
    extent_count: u32,
    reserved: u32,
    extents: [fiemap_extents_max]FiemapExtent,
};

comptime {
    assert(@sizeOf(FiemapExtent) == 56);
    assert(@offsetOf(Fiemap, "extents") == 32);
}

/// A file's new pages (not allocated yet, or over unwritten extents), as ranges of pages in file
/// order.
const Unallocated = struct {
    first: [fiemap_extents_max]u64 = undefined,
    count: [fiemap_extents_max]u64 = undefined,
    ranges: u32 = 0,
    delalloc: u64 = 0,
    unwritten: u64 = 0,
    /// No extent of the file written yet: its writeback has never run, so the flusher's pass
    /// starts at its first page (a written file's resumes where the last pass stopped).
    fresh: bool = true,

    fn contains(unallocated: *const Unallocated, page: u64) bool {
        for (unallocated.first[0..unallocated.ranges], unallocated.count[0..unallocated.ranges]) |first, count| {
            if (page >= first and page < first + count) return true;
        }
        return false;
    }

    fn pages(unallocated: *const Unallocated) u64 {
        var total: u64 = 0;
        for (unallocated.count[0..unallocated.ranges]) |count| total += count;
        return total;
    }
};

fn unallocated_of(fd: linux.fd_t) ?Unallocated {
    var map: Fiemap = .{
        .start = 0,
        .length = std.math.maxInt(u64),
        .flags = 0,
        .mapped_extents = 0,
        .extent_count = fiemap_extents_max,
        .reserved = 0,
        .extents = undefined,
    };
    if (linux.errno(linux.ioctl(fd, fiemap_request, @intFromPtr(&map))) != .SUCCESS) return null;
    var unallocated: Unallocated = .{};
    for (map.extents[0..@min(map.mapped_extents, fiemap_extents_max)]) |extent| {
        const new = extent.flags & (fiemap_extent_delalloc | fiemap_extent_unwritten);
        if (extent.length == 0) continue;
        if (new == 0) {
            unallocated.fresh = false;
            continue;
        }
        const first = extent.logical / partial_page_size;
        const last = (extent.logical + extent.length - 1) / partial_page_size;
        // Adjacent ranges of the two kinds are one run of new data.
        const joined = unallocated.ranges > 0 and
            unallocated.first[unallocated.ranges - 1] + unallocated.count[unallocated.ranges - 1] == first;
        if (joined) {
            unallocated.count[unallocated.ranges - 1] += last - first + 1;
        } else {
            unallocated.first[unallocated.ranges] = first;
            unallocated.count[unallocated.ranges] = last - first + 1;
            unallocated.ranges += 1;
        }
        if (new & fiemap_extent_delalloc != 0) unallocated.delalloc += last - first + 1 else unallocated.unwritten += last - first + 1;
    }
    return unallocated;
}

fn partial_writeback(paths: *const Paths, partial: Partial) PartialCount {
    var prng = std.Random.DefaultPrng.init(partial.seed);
    var count: PartialCount = .{};
    partial_walk(paths.upper, prng.random(), &count, 0);
    if (partial.commit) journal_commit(paths);
    return count;
}

fn partial_walk(directory: [:0]const u8, random: std.Random, count: *PartialCount, depth: u32) void {
    if (depth == partial_depth_max) return;
    const fd = linux.open(directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entries[name_offset])));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buffer: [path_size_max]u8 = undefined;
            const child = print_z(&child_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            if (entry.type == linux.DT.DIR) {
                partial_walk(child, random, count, depth + 1);
                continue;
            }
            if (entry.type != linux.DT.REG) continue;
            if (count.walked == partial_files_max) return;
            count.walked += 1;
            if (random.uintLessThan(u32, 3) != 0) continue;
            partial_file(child, random, count);
        }
    }
}

/// Of a file: a few pages over allocated blocks written back, each on its own (a clean page
/// costs nothing), and its new data's ascending run (Partial).
fn partial_file(path: [:0]const u8, random: std.Random, count: *PartialCount) void {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var stat: linux.Statx = undefined;
    const looked = linux.statx(@intCast(fd), "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat);
    if (linux.errno(looked) != .SUCCESS or stat.size == 0) return;
    const unallocated = unallocated_of(@intCast(fd)) orelse {
        count.unmapped += 1;
        return;
    };
    count.delalloc += @intCast(unallocated.delalloc);
    count.unwritten += @intCast(unallocated.unwritten);
    const pages: u64 = (stat.size + partial_page_size - 1) / partial_page_size;
    const flags = sync_file_range_wait_before | sync_file_range_write | sync_file_range_wait_after;
    const chosen = 1 + random.uintLessThan(u64, @min(pages, partial_pages_max));
    for (0..chosen) |_| {
        const page = random.uintLessThan(u64, pages);
        if (unallocated.contains(page)) continue; // New data goes in its run below.
        _ = linux.syscall4(.sync_file_range, @as(usize, @intCast(fd)), page * partial_page_size, partial_page_size, flags);
        count.pages += 1;
    }
    const total = unallocated.pages();
    if (total > 0) {
        // From the start of a drawn range, ascending through the next ones (wrapping, as the
        // flusher's cyclic writeback goes on from where its last pass stopped); a fresh file's
        // from its first, its writeback never having run: a later range kept and an earlier one
        // lost left zeros before a kept page (CE17, the Lean replica of determinismo: 13 of 64
        // seeds on srv4's ext4). The range is drawn either way, the generator's sequence kept.
        var left = 1 + random.uintLessThan(u64, total);
        const drawn = random.uintLessThan(u32, unallocated.ranges);
        var range = if (unallocated.fresh) 0 else drawn;
        while (left > 0) : (range = (range + 1) % unallocated.ranges) {
            const run = @min(left, unallocated.count[range]);
            _ = linux.syscall4(.sync_file_range, @as(usize, @intCast(fd)), unallocated.first[range] * partial_page_size, run * partial_page_size, flags);
            count.pages += @intCast(run);
            left -= run;
        }
    }
    count.files += 1;
}

/// At the setup's end, before the timelines part (the composer, PLAN's persistence audit): each
/// node with a disk of its own, the files of its writable layer holding data never written back
/// (their pages dirty or in writeback, cachestat's count: new data and overwrites alike, where
/// FIEMAP's delalloc extents show only the new), an event (`node_unsynced_files`): what a power
/// loss right after the setup would lose, before any fault. Every finding of a file written at a first start and never synced was
/// such a file there first (a keystore, cookies, a filer's configuration, checkpointed trees, a
/// node's configuration: 2026-11-07).
pub fn unsynced_report(system: *const schema.System) void {
    for (system.nodes) |node| {
        var paths: Paths = undefined;
        paths.init(node.name) catch continue;
        if (!exists(paths.image)) continue; // No disk of its own: nothing a power loss keeps.
        var report: UnsyncedReport = .{};
        unsynced_walk(paths.upper, paths.upper.len + 1, &report, 0);
        if (report.files == 0) continue;
        std.mem.sort(UnsyncedFile, report.largest[0..report.shown], {}, struct {
            fn more(_: void, a: UnsyncedFile, b: UnsyncedFile) bool {
                return a.bytes > b.bytes;
            }
        }.more);
        var shown: [unsynced_shown_max]struct { path: []const u8, bytes: u64 } = undefined;
        for (report.largest[0..report.shown], 0..) |*file, index| shown[index] = .{ .path = file.path_buffer[0..file.path_len], .bytes = file.bytes };
        sdk.event("node_unsynced_files", .{
            .node = node.name,
            .files = report.files,
            .bytes = report.bytes,
            .largest = shown[0..report.shown],
        });
    }
}

const unsynced_shown_max = 12;

/// cachestat(2) (Linux 6.5, x86_64's 451): a file's pages in the page cache, dirty and under
/// writeback, counted without writing anything back.
pub fn cachestat(fd: linux.fd_t) ?struct { dirty: u64, writeback: u64 } {
    const Range = extern struct { offset: u64, length: u64 };
    const Stat = extern struct { cache: u64, dirty: u64, writeback: u64, evicted: u64, recently_evicted: u64 };
    var range: Range = .{ .offset = 0, .length = 0 }; // To the end of the file.
    var stat: Stat = undefined;
    const result = linux.syscall4(@fromBackingInt(@intCast(451)), @as(usize, @intCast(fd)), @intFromPtr(&range), @intFromPtr(&stat), 0);
    if (linux.errno(result) != .SUCCESS) return null;
    return .{ .dirty = stat.dirty, .writeback = stat.writeback };
}

const UnsyncedFile = struct { path_buffer: [crash_files_path_shown_max]u8 = undefined, path_len: usize = 0, bytes: u64 = 0 };

const UnsyncedReport = struct {
    files: u32 = 0,
    bytes: u64 = 0,
    largest: [unsynced_shown_max]UnsyncedFile = undefined,
    shown: usize = 0,

    /// Kept among the largest shown, the smallest of them replaced once they are full.
    fn add(report: *UnsyncedReport, path: []const u8, bytes: u64) void {
        report.files += 1;
        report.bytes += bytes;
        var slot = report.shown;
        if (report.shown == unsynced_shown_max) {
            var smallest: usize = 0;
            for (report.largest[0..report.shown], 0..) |file, index| {
                if (file.bytes < report.largest[smallest].bytes) smallest = index;
            }
            if (report.largest[smallest].bytes >= bytes) return;
            slot = smallest;
        } else report.shown += 1;
        const size = @min(path.len, crash_files_path_shown_max);
        report.largest[slot] = .{ .path_len = size, .bytes = bytes };
        @memcpy(report.largest[slot].path_buffer[0..size], path[0..size]);
    }
};

fn unsynced_walk(directory: [:0]const u8, prefix: usize, report: *UnsyncedReport, depth: u32) void {
    if (depth == crash_files_depth_max) return;
    const fd = linux.open(directory, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entries[name_offset])));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buffer: [path_size_max]u8 = undefined;
            const child = print_z(&child_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            if (entry.type == linux.DT.DIR) {
                unsynced_walk(child, prefix, report, depth + 1);
                continue;
            }
            if (entry.type != linux.DT.REG) continue;
            const relative = child[prefix..];
            const ours = for (crash_files_ours) |file| {
                if (std.mem.eql(u8, relative, file)) break true;
            } else false;
            if (ours) continue;
            const file = linux.open(child, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
            if (linux.errno(file) != .SUCCESS) continue;
            defer _ = linux.close(@intCast(file));
            const pages = cachestat(@intCast(file)) orelse continue;
            if (pages.dirty + pages.writeback == 0) continue;
            report.add(relative, (pages.dirty + pages.writeback) * partial_page_size);
        }
    }
}

/// What a power loss changed in a node's files, an event at its next mount (`node_crash_files`):
/// the regular files of its writable layer (and overlayfs's whiteouts, its deletions of the
/// image's files: size -1) listed as the power goes, the node frozen, then again once the disk
/// is mounted afresh; the files left shorter or empty, gone, longer, or back (a deletion lost),
/// the most bytes lost first. A program that took a file for durable without syncing it reads it
/// so at its next start: a supervisor launched its worker from a jar left empty
/// (trial run 1168, timeline 0), which a replay to read the disk named 40 minutes later.
const crash_files_max = 4096;
const crash_files_depth_max = 16;
const crash_files_shown_max = 12;
const crash_files_path_shown_max = 160;
const crash_files_listing_size_max = crash_files_max * (path_size_max + 24);
/// Written at each start by root_prepare, unsynced: ours, not the node's.
const crash_files_ours = [_][]const u8{ "etc/hosts", "etc/resolv.conf", "etc/hostname" };

const CrashFileChange = struct {
    path: []const u8,
    /// Null: absent (created since the listing, or gone).
    before: ?i64,
    after: ?i64,
};

const CrashFilesReport = struct {
    files: u32 = 0,
    changed: u32 = 0,
    lost_bytes: u64 = 0,
    largest: []const CrashFileChange = &.{},
    /// Small files that held data before the power loss and came back all NUL bytes (their size
    /// kept, or another), the most suspect crash state: stock ext4 gave none in 430 trials of a
    /// small unsynced record (srv4, 2026-11-08), a temporary directories' record showed one (run
    /// 1506). Listed apart (`node_crash_nul_files`), sizes alike or not.
    nuls: []const []const u8 = &.{},
    nul_count: u32 = 0,
};
/// Files up to this size are read for an all-NUL content, before the cut and after the mount.
const crash_files_nul_size_max = 64 * 1024;

fn crash_files_save(paths: *const Paths) void {
    const buffer = std.heap.page_allocator.alloc(u8, crash_files_listing_size_max) catch return;
    defer std.heap.page_allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    crash_files_list(paths.upper, &writer);
    file_write(paths.crash_files, writer.buffered()) catch {};
}

fn crash_files_report(paths: *const Paths, name: []const u8) void {
    if (!exists(paths.crash_files)) return;
    defer _ = linux.unlink(paths.crash_files);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = read_file(arena, paths.crash_files, crash_files_listing_size_max + 1) catch return;
    const after_buffer = arena.alloc(u8, crash_files_listing_size_max) catch return;
    var writer: std.Io.Writer = .fixed(after_buffer);
    crash_files_list(paths.upper, &writer);
    const report = crash_files_compare(arena, before, writer.buffered()) catch return;
    if (report.nul_count > 0) sdk.event("node_crash_nul_files", .{ .node = name, .count = report.nul_count, .paths = report.nuls });
    if (report.changed == 0) return;
    sdk.event("node_crash_files", .{
        .node = name,
        .files = report.files,
        .changed = report.changed,
        .lost_bytes = report.lost_bytes,
        .largest = report.largest,
    });
}

/// The layer's files as lines "<size> <path>", the path from the layer's root.
fn crash_files_list(upper: [:0]const u8, writer: *std.Io.Writer) void {
    var count: u32 = 0;
    const content = std.heap.page_allocator.alloc(u8, crash_files_nul_size_max) catch return;
    defer std.heap.page_allocator.free(content);
    crash_files_walk(upper, upper.len + 1, writer, &count, 0, content);
}

/// Whether the file (`name` in the directory `fd`), up to crash_files_nul_size_max and not empty,
/// holds only NUL bytes.
fn crash_file_nul(fd: linux.fd_t, name: [*:0]const u8, size: u64, content: []u8) bool {
    if (size == 0 or size > content.len) return false;
    const file = linux.openat(fd, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NOATIME = true, .CLOEXEC = true }, 0);
    if (linux.errno(file) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(file));
    const read = linux.read(@intCast(file), content.ptr, @intCast(size));
    if (linux.errno(read) != .SUCCESS or read != size) return false;
    return std.mem.allEqual(u8, content[0..read], 0);
}

fn crash_files_walk(directory: [:0]const u8, prefix: usize, writer: *std.Io.Writer, count: *u32, depth: u32, content: []u8) void {
    if (depth == crash_files_depth_max) return;
    const fd = linux.open(directory, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name_z: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const name = std.mem.span(name_z);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (std.mem.indexOfScalar(u8, name, '\n') != null) continue; // A line each.
            var child_buffer: [path_size_max]u8 = undefined;
            const child = print_z(&child_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            if (entry.type == linux.DT.DIR) {
                crash_files_walk(child, prefix, writer, count, depth + 1, content);
                continue;
            }
            if (entry.type != linux.DT.REG and entry.type != linux.DT.CHR) continue;
            if (count.* == crash_files_max) return;
            const relative = child[prefix..];
            const ours = for (crash_files_ours) |file| {
                if (std.mem.eql(u8, relative, file)) break true;
            } else false;
            if (ours) continue;
            var stat: linux.Statx = undefined;
            const looked = linux.statx(@intCast(fd), name_z, linux.AT.SYMLINK_NOFOLLOW, .{ .SIZE = true }, &stat);
            if (linux.errno(looked) != .SUCCESS) continue;
            const length: i64 = if (entry.type == linux.DT.CHR) -1 else @intCast(stat.size);
            // "<size>z": its content all NUL bytes (a small file read: crash_file_nul).
            const nul = entry.type == linux.DT.REG and crash_file_nul(@intCast(fd), name_z, stat.size, content);
            writer.print("{d}{s} {s}\n", .{ length, if (nul) "z" else "", relative }) catch return;
            count.* += 1;
        }
    }
}

const CrashFile = struct { path: []const u8, size: i64, nul: bool = false };

fn crash_files_line(line: []const u8) ?CrashFile {
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const nul = space > 0 and line[space - 1] == 'z';
    const size = std.fmt.parseInt(i64, line[0 .. space - @intFromBool(nul)], 10) catch return null;
    return .{ .path = line[space + 1 ..], .size = size, .nul = nul };
}

/// The bytes a change lost: what a file had beyond what it has (all of it, gone).
fn crash_file_lost(change: CrashFileChange) u64 {
    const before = change.before orelse return 0;
    if (before <= 0) return 0;
    const after = @max(change.after orelse 0, 0);
    return @intCast(@max(before - after, 0));
}

fn crash_files_compare(arena: std.mem.Allocator, before: []const u8, after: []const u8) !CrashFilesReport {
    var now: std.StringHashMapUnmanaged(i64) = .empty;
    var now_nul: std.StringHashMapUnmanaged(void) = .empty;
    var after_lines = std.mem.tokenizeScalar(u8, after, '\n');
    while (after_lines.next()) |line| {
        const file = crash_files_line(line) orelse continue;
        try now.put(arena, file.path, file.size);
        if (file.nul) try now_nul.put(arena, file.path, {});
    }
    var nuls: std.ArrayList([]const u8) = .empty;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    var changes: std.ArrayList(CrashFileChange) = .empty;
    var report: CrashFilesReport = .{};
    var before_lines = std.mem.tokenizeScalar(u8, before, '\n');
    while (before_lines.next()) |line| {
        const file = crash_files_line(line) orelse continue;
        report.files += 1;
        try listed.put(arena, file.path, {});
        if (!file.nul and file.size > 0 and now_nul.contains(file.path)) {
            if (nuls.items.len < crash_files_shown_max) try nuls.append(arena, file.path);
            report.nul_count += 1;
        }
        const size = now.get(file.path);
        if (size != null and size.? == file.size) continue;
        try changes.append(arena, .{ .path = file.path, .before = file.size, .after = size });
    }
    after_lines.reset();
    while (after_lines.next()) |line| {
        const file = crash_files_line(line) orelse continue;
        if (listed.contains(file.path)) continue;
        try changes.append(arena, .{ .path = file.path, .before = null, .after = file.size });
    }
    report.changed = @intCast(changes.items.len);
    for (changes.items) |change| report.lost_bytes += crash_file_lost(change);
    std.mem.sort(CrashFileChange, changes.items, {}, struct {
        fn more_lost(_: void, a: CrashFileChange, b: CrashFileChange) bool {
            const lost_a = crash_file_lost(a);
            const lost_b = crash_file_lost(b);
            if (lost_a != lost_b) return lost_a > lost_b;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.more_lost);
    const largest = changes.items[0..@min(changes.items.len, crash_files_shown_max)];
    // A long path's end: where the file's own name is.
    for (largest) |*change| if (change.path.len > crash_files_path_shown_max) {
        change.path = try std.fmt.allocPrint(arena, "...{s}", .{change.path[change.path.len - (crash_files_path_shown_max - 3) ..]});
    };
    report.largest = largest;
    report.nuls = nuls.items;
    return report;
}

test "a file that held data and came back NUL is named, its size the same or not" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const before =
        \\51 datastore-data/temp-dirs-record.txt
        \\4096z preallocated
        \\100 log/a
        \\
    ;
    const after =
        \\51z datastore-data/temp-dirs-record.txt
        \\4096z preallocated
        \\100 log/a
        \\
    ;
    const report = try crash_files_compare(arena_state.allocator(), before, after);
    try std.testing.expectEqual(@as(u32, 0), report.changed); // Sizes all the same.
    try std.testing.expectEqual(@as(u32, 1), report.nul_count);
    try std.testing.expectEqualStrings("datastore-data/temp-dirs-record.txt", report.nuls[0]);
}

test crash_files_compare {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const before =
        \\305528 data/app/supervisor/jars/m.jar
        \\100 log/a
        \\-1 etc/whiteout
        \\50 kept
        \\4096 data/gone
        \\
    ;
    const after =
        \\0 data/app/supervisor/jars/m.jar
        \\120 log/a
        \\50 kept
        \\7 back
        \\
    ;
    const report = try crash_files_compare(arena_state.allocator(), before, after);
    try std.testing.expectEqual(@as(u32, 5), report.files);
    try std.testing.expectEqual(@as(u32, 5), report.changed); // All but `kept`.
    try std.testing.expectEqual(@as(u64, 305528 + 4096), report.lost_bytes);
    try std.testing.expectEqualStrings("data/app/supervisor/jars/m.jar", report.largest[0].path);
    try std.testing.expectEqual(@as(?i64, 0), report.largest[0].after);
    try std.testing.expectEqualStrings("data/gone", report.largest[1].path);
    try std.testing.expectEqual(@as(?i64, null), report.largest[1].after);
    // No bytes lost: by path.
    try std.testing.expectEqualStrings("back", report.largest[2].path);
    try std.testing.expectEqual(@as(?i64, null), report.largest[2].before);
    try std.testing.expectEqualStrings("etc/whiteout", report.largest[3].path);
    try std.testing.expectEqualStrings("log/a", report.largest[4].path);
    const same = try crash_files_compare(arena_state.allocator(), before, before);
    try std.testing.expectEqual(@as(u32, 0), same.changed);
}

test "a crash's file listing names each regular file under the layer with its size, nested ones too" {
    var root_buffer: [path_size_max]u8 = undefined;
    var names: [12][path_size_max]u8 = undefined;
    const root = try partial_tree(&root_buffer, 200, &names);
    defer partial_tree_remove(root, &names);
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    crash_files_list(root, &writer);
    const listing = writer.buffered();
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, listing, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, listing, "12288 f0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "12288 a/b/f1\n") != null);
}

/// A tree of twelve fresh files of three pages, unsynced, half of them two directories down. On
/// the disk the tests run from, not /tmp: a tmpfs has no extents (FIEMAP), and its pages no
/// delayed allocation.
fn partial_tree(root_buffer: *[path_size_max]u8, tag: u64, names: *[12][path_size_max]u8) ![:0]const u8 {
    const root = try print_z(root_buffer, ".det-partial-test-{d}-{d}", .{ linux.getpid(), tag });
    var sub_buffer: [path_size_max]u8 = undefined;
    try mkdir_all(try print_z(&sub_buffer, "{s}/a/b", .{root}));
    const content: [3 * partial_page_size]u8 = @splat('x');
    for (names, 0..) |*name, index| {
        const directory = if (index % 2 == 0) root else try print_z(&sub_buffer, "{s}/a/b", .{root});
        try file_write(try print_z(name, "{s}/f{d}", .{ directory, index }), &content);
    }
    return root;
}

/// The tree's pages not allocated yet (delayed allocation): what the walk draws from. A host's
/// flusher may allocate some before the walk (srv4 under its hunts' writes: the two trees of one
/// test then drew differently, 2026-11-08), and the tests compare only trees found alike.
fn partial_tree_unallocated(names: *const [12][path_size_max]u8) u64 {
    var total: u64 = 0;
    for (names) |*name| {
        const fd = linux.open(@ptrCast(name), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) continue;
        defer _ = linux.close(@intCast(fd));
        if (unallocated_of(@intCast(fd))) |unallocated| total += unallocated.pages();
    }
    return total;
}

fn partial_tree_remove(root: [:0]const u8, names: *const [12][path_size_max]u8) void {
    for (names) |*name| _ = linux.unlink(@ptrCast(name));
    var buffer: [path_size_max]u8 = undefined;
    if (print_z(&buffer, "{s}/a/b", .{root})) |sub| _ = linux.rmdir(sub) else |_| {}
    if (print_z(&buffer, "{s}/a", .{root})) |a| _ = linux.rmdir(a) else |_| {}
    _ = linux.rmdir(root);
}

/// Attempts of a partial persistence test whose trees the host's flusher wrote back on its own.
const partial_attempts = 6;

test "partial persistence draws the same files and pages from the same seed, nested ones too" {
    for (0..partial_attempts) |_| {
        partial_same_seed() catch |err| switch (err) {
            error.HostWroteBack => continue,
            else => return err,
        };
        return;
    }
    return error.SkipZigTest; // The host wrote the trees back each time: nothing to compare.
}

test "a fresh file's new data is written back from its first range" {
    // CE17 (the Lean replica of determinismo): the run of new data began at any drawn range, so a
    // fresh file could keep a later range and lose an earlier one, zeros before a kept page.
    var later_first: u32 = 0;
    var seed: u64 = 1;
    while (seed <= 64) : (seed += 1) {
        var path_buffer: [path_size_max]u8 = undefined;
        const path = try print_z(&path_buffer, ".det-partial-fresh-{d}-{d}", .{ linux.getpid(), seed });
        const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(opened) == .SUCCESS);
        const fd: linux.fd_t = @intCast(opened);
        defer {
            _ = linux.close(fd);
            _ = linux.unlink(path);
        }
        // Pages 0 and 4 written, never synced; 1 to 3 a hole: a fresh file with two ranges of
        // new data (a sparse write, a preallocated layout's first pages).
        const page: [partial_page_size]u8 = @splat('x');
        _ = linux.pwrite(fd, &page, page.len, 0);
        _ = linux.pwrite(fd, &page, page.len, 4 * partial_page_size);
        const before = unallocated_of(fd) orelse continue;
        if (before.ranges != 2) continue; // The host's flusher wrote it back first.
        var prng = std.Random.DefaultPrng.init(seed);
        var count: PartialCount = .{};
        partial_file(path, prng.random(), &count);
        const after = unallocated_of(fd) orelse continue;
        // Page 4 written back and page 0 not: after the power loss (journal committed) page 0
        // reads zeros under the file's size, before a kept page.
        if (!after.contains(4) and after.contains(0)) later_first += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), later_first);
}

/// Two trees walked from the same seed draw the same files and pages. HostWroteBack when the
/// host's flusher allocated part of one before or during its walk (srv4 under its hunts'
/// writes, its dirty memory past the background threshold: the two drew differently in 2 of 3
/// runs, 2026-11-08): not the same input then, nothing to compare.
fn partial_same_seed() !void {
    var counts: [2]PartialCount = @splat(.{});
    var unallocated: [2][2]u64 = undefined;
    for (&counts, &unallocated, 0..) |*count, *measured, tag| {
        var root_buffer: [path_size_max]u8 = undefined;
        var names: [12][path_size_max]u8 = undefined;
        const root = try partial_tree(&root_buffer, tag, &names);
        defer partial_tree_remove(root, &names);
        measured[0] = partial_tree_unallocated(&names);
        var prng = std.Random.DefaultPrng.init(7);
        partial_walk(root, prng.random(), count, 0);
        measured[1] = partial_tree_unallocated(&names);
    }
    if (unallocated[0][0] != unallocated[1][0] or unallocated[0][1] != unallocated[1][1]) return error.HostWroteBack;
    if (!std.meta.eql(counts[0], counts[1])) return error.HostWroteBack; // Between a file's look and its pages.
    const first = counts[0];
    try std.testing.expectEqual(first, counts[1]);
    try std.testing.expectEqual(@as(u32, 12), first.walked); // Nested ones walked too.
    try std.testing.expectEqual(@as(u32, 0), first.unmapped);
    try std.testing.expect(first.files > 0 and first.files < 12); // A subset, a file in three.
    try std.testing.expect(first.pages >= first.files and first.pages <= first.files * 3);
    var differs = false;
    for (1..8) |seed| {
        var root_buffer: [path_size_max]u8 = undefined;
        var names: [12][path_size_max]u8 = undefined;
        const root = try partial_tree(&root_buffer, 10 + seed, &names);
        defer partial_tree_remove(root, &names);
        var prng = std.Random.DefaultPrng.init(7 + seed * 1000);
        var other: PartialCount = .{};
        partial_walk(root, prng.random(), &other, 0);
        if (other.files != first.files or other.pages != first.pages) differs = true;
    }
    try std.testing.expect(differs);
}

test "partial persistence writes a fresh file's pages back as a prefix: what stays unallocated ends the file" {
    for (0..partial_attempts) |attempt| {
        partial_prefix(attempt) catch |err| switch (err) {
            error.HostWroteBack => continue,
            else => return err,
        };
        return;
    }
    return error.SkipZigTest; // The host wrote the tree back each time: nothing to test.
}

/// HostWroteBack when the host's flusher allocated pages of the tree before the walks (every
/// page fresh, or nothing to test) or during them (more allocated than the walks wrote back:
/// their count includes pages over allocated blocks, so never less).
fn partial_prefix(attempt: usize) !void {
    var root_buffer: [path_size_max]u8 = undefined;
    var names: [12][path_size_max]u8 = undefined;
    const root = try partial_tree(&root_buffer, 99 + attempt, &names);
    defer partial_tree_remove(root, &names);
    const fresh = partial_tree_unallocated(&names);
    if (fresh != names.len * 3) return error.HostWroteBack;
    var written_back: u32 = 0;
    for (0..2) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var count: PartialCount = .{};
        partial_walk(root, prng.random(), &count, 0);
        written_back += count.pages;
    }
    if (fresh - partial_tree_unallocated(&names) > written_back) return error.HostWroteBack;
    try std.testing.expect(written_back > 0);
    var partly = false;
    for (&names) |*name| {
        const fd = linux.open(@ptrCast(name), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        defer _ = linux.close(@intCast(fd));
        const unallocated = unallocated_of(@intCast(fd)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(unallocated.ranges <= 1);
        if (unallocated.ranges == 1) {
            try std.testing.expectEqual(@as(u64, 3), unallocated.first[0] + unallocated.count[0]);
            if (unallocated.first[0] > 0) partly = true;
        }
    }
    try std.testing.expect(partly); // Some file's run stopped inside it.
}

/// The running journal transaction committed, as ext4's periodic commit would have done before
/// the power went: an fsync of a file of ours beside the overlay's directories (the node never
/// sees it), which commits the transaction holding every metadata change so far.
fn journal_commit(paths: *const Paths) void {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = print_z(&path_buffer, "{s}/.det-commit", .{paths.layer}) catch return;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.pwrite(@intCast(fd), "c", 1, 0);
    _ = linux.fsync(@intCast(fd));
}

/// A crash, with `frozen_begun` called once the node's freeze is asked for, before it is
/// waited for: a crash at a durability point releases the process parked there (a sleep in the
/// kernel the freeze does not reach), which then freezes on its way out.
pub fn crash_with(name: []const u8, frozen_begun: ?*const fn ([]const u8) void, partial: ?Partial) !void {
    // Under the start lock, as a wipe: a start in the middle of a crash (det-faults restarting
    // the node, whose process had exited with its layer still mounted) found the layer this
    // crash had shut down, remounted it and put the disk's table back. The power loss was
    // undone halfway, the disk taking writes again before the kill, and "a node's disk is never
    // left dropping writes" failed (Kafka's run 439: 22 timelines; timeline 78, kafka-4 at
    // 94.8 s).
    const lock = try start_lock(name);
    defer start_unlock(lock);
    var paths: Paths = undefined;
    try paths.init(name);
    // Down already (a crash a moment ago, its layer unmounted): nothing to crash. A second crash
    // there once switched the disk to dropping writes, failed, and left it so: every write after
    // was lost at the next crash, and Kafka truncated the cluster to it (srv3 run 67, timeline
    // 111: 92 committed transactions "lost").
    if (!exists(paths.mounted)) return error.NodeDown;
    // Frozen first, all at once as the power goes: running on between the shutdown and the
    // kill, its processes would see their writes fail (a program that stops on a failed write
    // reports it), and exiting after it they would close files ext4 then writes back. Frozen
    // under the crash lock, held to the thaw: no other thaw undoes it meanwhile (freeze).
    var crash_lock_buffer: [path_size_max]u8 = undefined;
    const crash_lock = try lock_take(try crash_lock_path(&crash_lock_buffer, name));
    defer _ = linux.close(crash_lock); // Released after the thaw (defers run in reverse).
    try file_write(paths.cgroup_freeze, "1");
    defer file_write(paths.cgroup_freeze, "0") catch {}; // Its next start runs.
    if (frozen_begun) |call| call(name);
    // A process inside the kernel (I/O to a stalled disk) reports frozen only once its system
    // call returns; the freeze stops it then, before the kill reaches it, so it never sees the
    // power go. Waiting longer only stalls the fault injector: 30 s a crash, and the crash
    // given up, in 95 timelines of PostgreSQL's run 43 (srv3, 2026-10-28).
    cgroup_frozen_wait(&paths) catch |err| switch (err) {
        error.NodeDidNotFreeze => {},
        else => return err,
    };
    // Still asked to freeze at the cut, whatever ran meanwhile: a cut under a running node
    // drops writes it then acknowledges as synced, a false loss of ours (local-fs run 742).
    var freeze_buffer: [8]u8 = undefined;
    const held = std.mem.startsWith(u8, read_small(paths.cgroup_freeze, &freeze_buffer) orelse "", "1");
    sdk.assert_computed(.always, held, "a power loss cuts the disk of a node held frozen", .{ .node = name });
    crash_files_save(&paths);
    // What a flusher had written back before the power went (the node frozen: nothing new dirtied).
    if (partial) |drawn| {
        const count = partial_writeback(&paths, drawn);
        sdk.event("node_crash_partial", .{ .node = name, .walked = count.walked, .files = count.files, .pages = count.pages, .unmapped = count.unmapped, .delalloc = count.delalloc, .unwritten = count.unwritten, .commit = drawn.commit });
        sdk.assert_computed(.always, count.unmapped == 0, "a partial power loss maps every file it draws", .{ .node = name, .unmapped = count.unmapped });
    }
    // The power goes: from here nothing the node's kernel still issues reaches its disk (a
    // journal commit, the discards of what a lost transaction freed: ext4's commit callback
    // ran on and punched blocks the disk's committed state still used, directories read back
    // as zeros). What reached it before stays.
    const loop = loop_read(&paths) catch null;
    var mapper_buffer: [mapper_name_size]u8 = undefined;
    const mapper = try mapper_name(&mapper_buffer, name);
    if (loop) |number| {
        // Marked while the disk drops writes, until its table is back (layer_mount checks).
        try file_write(paths.dropping, "");
        var parameters_buffer: [64]u8 = undefined;
        try mapper_table(mapper, .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 1 drop_writes",
            .{number},
        ) });
    }
    // Failing past here, the disk gets its table back: never left dropping writes.
    errdefer if (loop) |number| {
        var record_buffer: [disk_record_size]u8 = undefined;
        var parameters_buffer: [64]u8 = undefined;
        if (disk_table_now(&paths, number, &record_buffer, &parameters_buffer)) |table| {
            if (mapper_table(mapper, table)) |_| {
                _ = linux.unlink(paths.dropping);
            } else |_| {}
        } else |_| {}
    };
    const fd = linux.open(paths.layer, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    var flags: u32 = ext4_going_flags_nologflush;
    const shutdown = linux.ioctl(@intCast(fd), ext4_ioc_shutdown, @intFromPtr(&flags));
    _ = linux.close(@intCast(fd));
    if (linux.errno(shutdown) != .SUCCESS) return error.NotADurableDisk; // Not ext4: no crash.
    try kill_locked(name); // A frozen process dies of SIGKILL too.
    try layer_unmount(&paths);
    // Power back: the disk through the table it had (a disk fault's, while one is on).
    if (loop) |number| {
        var record_buffer: [disk_record_size]u8 = undefined;
        var parameters_buffer: [64]u8 = undefined;
        try mapper_table(mapper, try disk_table_now(&paths, number, &record_buffer, &parameters_buffer));
        _ = linux.unlink(paths.dropping);
    }
    sdk.event("node_crash", .{ .node = name });
}

/// A node's start lock (`<node>.start`), held across processes: starts, and what takes a node's
/// disk away (wipe), one at a time.
fn start_lock(name: []const u8) !linux.fd_t {
    var lock_path_buffer: [path_size_max]u8 = undefined;
    return lock_take(try print_z(&lock_path_buffer, state_root ++ "/{s}.start", .{name}));
}

/// A node's crash lock (`<node>.crash`): a power loss holds it from its freeze to its thaw, and
/// a thaw meanwhile is skipped (freeze). A pause fault's end thawed the node while a crash
/// waited for its freeze (a sync stall held a task in the kernel past the crash's second), and
/// the crash cut the disk under the running node: its fsyncs answered for 60 ms with their
/// writes dropped, a rename synced in its directory undone (local-fs run 742, timeline 261).
/// A flock: a crash that dies (a killed driver's) leaves none held.
fn crash_lock_path(buffer: *[path_size_max]u8, name: []const u8) ![:0]const u8 {
    return print_z(buffer, state_root ++ "/{s}.crash", .{name});
}

/// The lock file at `path`, made if absent, held (exclusive) until its descriptor closes.
fn lock_take(path: [:0]const u8) !linux.fd_t {
    const lock = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock) != .SUCCESS) return error.LockOpenFailed;
    while (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX)) == .INTR) {}
    return @intCast(lock);
}

fn start_unlock(lock: linux.fd_t) void {
    _ = linux.flock(lock, std.posix.LOCK.UN);
    _ = linux.close(lock);
}

/// The node starts fresh from its image: its writable layer is gone (with its disk, if any).
pub fn wipe(name: []const u8) !void {
    // Under the start lock: a fault's restart in the middle of its start (its disk mounted, not
    // yet marked so) had its devices taken from under it, the wipe skipping the unmount and its
    // busy device left, and the node never started again ("mount / failed: INVAL", exit 127:
    // rqlite's spare, trial run 418 timeline 13, a power loss of every node then the driver's
    // wipe). Released before the wipe's own start (det-nodes wipe), which takes it again.
    const lock = try start_lock(name);
    defer start_unlock(lock);
    var paths: Paths = undefined;
    try paths.init(name);
    // A node that never started (a spare) has nothing to lose, and its first start stays a first
    // start (no DETERMINISMO_WIPES). Its state directory not made yet, writing its wipe count
    // failed (OpenFailed): etcd's member driver wipes the spare as it adds it, and its command
    // failed in half of every etcd hunt's timelines since 2026-11-18 at least (runs 2067, 2068,
    // 2247, 2248), "test commands exit successfully" with them.
    if (!exists(paths.directory)) {
        sdk.event("node_wipe", .{ .node = name, .never_started = true });
        return;
    }
    try kill_locked(name);
    if (exists(paths.mounted)) try layer_unmount(&paths);
    var mapper_buffer: [mapper_name_size]u8 = undefined;
    _ = mapper_call(dm_dev_remove, try mapper_name(&mapper_buffer, name), 0, null) catch {};
    var text_buffer: [16]u8 = undefined;
    if (read_small(paths.loop, &text_buffer)) |text| {
        const number = std.fmt.parseInt(u32, text, 10) catch return error.BadLoop;
        var device_buffer: [32]u8 = undefined;
        const device = try print_z(&device_buffer, "/dev/loop{d}", .{number});
        const loop_fd = linux.open(device, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(loop_fd) == .SUCCESS) {
            _ = linux.ioctl(@intCast(loop_fd), loop_clr_fd, 0);
            _ = linux.close(@intCast(loop_fd));
        }
        _ = linux.unlink(paths.loop);
    }
    _ = linux.unlink(paths.image);
    _ = linux.unlink(paths.crash_files);
    var count_buffer: [16]u8 = undefined;
    const count = try std.fmt.bufPrint(&count_buffer, "{d}", .{wipes_of(&paths) + 1});
    try file_write(paths.wipes, count);
    sdk.event("node_wipe", .{ .node = name });
}

/// How many times the node was wiped. Its starts after one are told (DETERMINISMO_WIPES in a
/// start's environment, absent before any): a start that finds its disk empty knows a first
/// start from a disk lost, as the operator bringing a replica back does, where the two need
/// different commands (TigerBeetle: `format` for a new replica; for one that lost its data
/// file `recover`, a format there letting the cluster lose committed data).
fn wipes_of(paths: *const Paths) u32 {
    var buffer: [16]u8 = undefined;
    const text = read_small(paths.wipes, &buffer) orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

const directory_flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
const ext4_ioc_shutdown = 0x8004587d; // _IOR('X', 125, __u32)
const ext4_going_flags_nologflush = 2; // Neither the journal nor data are flushed.
const ext4_ioc_resize_fs = 0x40086610; // _IOW('f', 16, __u64)
const loop_ctl_get_free = 0x4c82;
const loop_set_fd = 0x4c00;
const loop_clr_fd = 0x4c01;
/// A durable disk's size (sparse: guest memory holds what is written).
const durable_size = 4 << 30;
const durable_template_path = "/opt/determinismo/durable.blocks"; // initramfs.zig's.

/// x86-64's struct statfs (linux/statfs.h), as fstatfs fills it.
const Statfs = extern struct {
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

/// The node's writable layer: a tmpfs of its own, or (crash and disk faults) its ext4 disk,
/// through device-mapper (disk faults swap its table).
fn layer_mount(paths: *const Paths, node: *const schema.Resolved) !void {
    if (!node.faults.crash and !node.faults.disk) {
        return mount("tmpfs", paths.layer, "tmpfs", 0, null);
    }
    const fresh = !exists(paths.image);
    if (fresh) try durable_image_create(paths.image);
    const loop = try loop_attach(paths);
    const minor = try mapper_attach(node.name, loop);
    // A crash that never put the disk's table back leaves it dropping every write, read back
    // from memory until the next crash loses them all: a false data loss, ours (a failed second
    // crash did, srv3 2026-10-28). Put back here, and reported.
    const dropping = exists(paths.dropping);
    if (dropping) {
        var name_buffer: [mapper_name_size]u8 = undefined;
        var record_buffer: [disk_record_size]u8 = undefined;
        var parameters_buffer: [64]u8 = undefined;
        try mapper_table(try mapper_name(&name_buffer, node.name), try disk_table_now(paths, loop, &record_buffer, &parameters_buffer));
        _ = linux.unlink(paths.dropping);
    }
    // Computed, as determinismo's other properties: not in the catalog, so a run whose nodes
    // have no such disk does not list it as never reached.
    sdk.assert_computed(.always, !dropping, "a node's disk is never left dropping writes", .{ .node = node.name });
    var device_buffer: [32]u8 = undefined;
    const device = try print_z(&device_buffer, "/dev/dm-{d}", .{minor});
    try device_wait(device);
    try device_free_wait(device);
    if (!fresh) fsck(node.name, device);
    // noinit_itable: no background zeroing of inode tables (it would fill guest memory).
    // discard: blocks ext4 frees are punched out of the image (loop, then tmpfs), else the
    // image keeps every block ever written: Scylla's rotating commit log grew five nodes'
    // images to the whole of /run (4 GiB) while their filesystems held 160 MB each, and its
    // writes failed with ENOSPC.
    try mount(device, paths.layer, "ext4", 0, "data=ordered,noinit_itable,discard");
    // Not left mounted on a failure: the next start would mount the disk over it.
    errdefer _ = linux.umount2(paths.layer, 0);
    // The template is small; grown in place to the disk's size, once. Not again: ext4 refuses an
    // online resize on a filesystem that recorded errors, and a node whose disk fault left it so
    // never started again (ParticleDB's smoke run 332: 169 of 328 timelines' final reads reached
    // no node), where a machine rebooted after the fault mounts its disk and runs.
    const fd = linux.open(paths.layer, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    var stat: Statfs = undefined;
    if (linux.errno(linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&stat))) != .SUCCESS) return error.StatFailed;
    if (stat.blocks * @as(u64, @intCast(stat.bsize)) < durable_size / 2) {
        var blocks: u64 = durable_size / 4096;
        const resized = linux.ioctl(@intCast(fd), ext4_ioc_resize_fs, @intFromPtr(&blocks));
        if (linux.errno(resized) != .SUCCESS) return error.ResizeFailed;
        if (linux.errno(linux.syscall2(.fstatfs, @intCast(fd), @intFromPtr(&stat))) != .SUCCESS) return error.StatFailed;
    }
    // As many inodes as mkfs gives a disk of its size (one per 16 KiB): the template's ratio
    // decides it (initramfs.zig's durable_template), an eighth of it once (run 1279).
    sdk.assert_computed(.always, stat.files * 16384 >= durable_size, "a node's disk has the inodes mkfs gives a disk of its size", .{
        .node = node.name,
        .inodes = stat.files,
    });
    writeback_relax();
}

/// A node's disk checked before it is mounted again, as a machine's boot does (systemd-fsck runs
/// `e2fsck -p`): the journal replayed, and a filesystem that recorded errors (a disk fault left
/// ext4 so) repaired as far as preen mode repairs alone. Beyond that (exit 4: "UNEXPECTED
/// INCONSISTENCY; RUN fsck MANUALLY") the boot stops and an operator runs `e2fsck -fy`, which
/// runs too. Each run an event (`node_fsck`, its status: 0 clean, 1 changed): the files a system
/// then finds truncated, cleared or in lost+found are its to survive.
fn fsck(name: []const u8, device: [:0]const u8) void {
    const preen = fsck_run(device, "-p");
    sdk.event("node_fsck", .{ .node = name, .mode = "preen", .status = preen.status, .output = preen.output() });
    if (preen.status < 4) return;
    const repair = fsck_run(device, "-fy");
    sdk.event("node_fsck", .{ .node = name, .mode = "manual", .status = repair.status, .output = repair.output() });
}

const FsckResult = struct {
    status: u32,
    buffer: [2048]u8 = undefined,
    size: usize = 0,

    /// Its output's end: what it changed comes last.
    fn output(result: *const FsckResult) []const u8 {
        return result.buffer[0..result.size];
    }
};

/// /sbin/e2fsck (tools/initramfs.zig) on the device, its exit status (128 + its signal) and the
/// end of its output; status 8 ("operational error") when it could not run.
fn fsck_run(device: [:0]const u8, mode: [*:0]const u8) FsckResult {
    var result: FsckResult = .{ .status = 8 };
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return result;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
        return result;
    }
    if (pid == 0) {
        _ = linux.dup2(pipe[1], 1);
        _ = linux.dup2(pipe[1], 2);
        const argv = [_:null]?[*:0]const u8{ "/sbin/e2fsck", mode, device.ptr };
        const envp = [_:null]?[*:0]const u8{"PATH=/sbin:/bin"};
        _ = linux.execve("/sbin/e2fsck", &argv, &envp);
        linux.exit_group(8);
    }
    _ = linux.close(pipe[1]);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = linux.read(pipe[0], &chunk, chunk.len);
        if (linux.errno(got) == .INTR) continue;
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        // The last bytes kept: shift what no longer fits out.
        const kept = @min(got, result.buffer.len);
        const from = chunk[got - kept .. got];
        const room = result.buffer.len - result.size;
        if (kept > room) {
            const drop = kept - room;
            std.mem.copyForwards(u8, result.buffer[0 .. result.size - drop], result.buffer[drop..result.size]);
            result.size -= drop;
        }
        @memcpy(result.buffer[result.size..][0..kept], from);
        result.size += kept;
    }
    _ = linux.close(pipe[0]);
    var status: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid), &status, 0, null)) == .INTR) {}
    const bits: u32 = @bitCast(status);
    result.status = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    return result;
}

/// Dirty data stays dirty until a program syncs it (no periodic writeback): what a crash loses
/// is what was not synced, as on a machine whose power fails before the flusher ran.
///
/// The flusher's interval is a day, as the expiry, not 0: the first inode dirtied on a
/// writeback context wakes the flusher that interval later (`wb_wakeup_delayed`), at once with
/// 0, and it then writes back all the context has dirty when that is over the context's share
/// of the background threshold (`wb_over_bg_thresh`), its fraction of recent writeouts: about
/// none for a disk quiet a while or a node started again in a new cgroup. A power loss then kept
/// most of what nobody synced (the selftest's 30 fresh files, 9 to 26 of them written back
/// before the cut: trial runs 1075 and 1088, traced in a replay of 1088 to `reason=background`
/// for the node's cgroup).
fn writeback_relax() void {
    const settings = [_][2][:0]const u8{
        .{ "/proc/sys/vm/dirty_writeback_centisecs", "8640000" },
        .{ "/proc/sys/vm/dirty_expire_centisecs", "8640000" },
        .{ "/proc/sys/vm/dirty_background_ratio", "50" },
        .{ "/proc/sys/vm/dirty_ratio", "80" },
    };
    for (settings) |setting| file_write(setting[0], setting[1]) catch {};
}

/// What systems' documentation asks of every host, set once before any node starts (whatever
/// their disks): the memory-map count OpenSearch's and Elasticsearch's (their bootstrap checks
/// refuse to form a cluster below it), the asynchronous I/O events Redpanda's (Seastar reserves
/// them per shard).
fn host_settings() void {
    const settings = [_][2][:0]const u8{
        .{ "/proc/sys/vm/max_map_count", "262144" },
        .{ "/proc/sys/fs/aio-max-nr", "1048576" },
    };
    for (settings) |setting| file_write(setting[0], setting[1]) catch {};
}

fn layer_unmount(paths: *const Paths) !void {
    _ = linux.unlink(paths.mounted);
    for ([_][:0]const u8{ paths.root, paths.layer }) |path| {
        for (0..stop_attempts_max) |_| {
            const result = linux.umount2(path, 0);
            if (linux.errno(result) == .SUCCESS or linux.errno(result) == .INVAL) break;
            sleep_ns(poll_interval_ns); // Busy until the killed processes are reaped.
        } else return error.UnmountFailed;
    }
}

/// The empty ext4 filesystem of the initramfs, written as a sparse image of `durable_size`.
fn durable_image_create(path: [:0]const u8) !void {
    const template = linux.open(durable_template_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(template) != .SUCCESS) return error.NoDurableTemplate;
    defer _ = linux.close(@intCast(template));
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const image = linux.open(path, flags, 0o600);
    if (linux.errno(image) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(image));
    var size_bytes: [8]u8 = undefined;
    try read_exact(@intCast(template), &size_bytes);
    var record: [4 + 4096]u8 = undefined;
    while (read_exact(@intCast(template), &record)) {
        const index = std.mem.readInt(u32, record[0..4], .little);
        const offset = @as(i64, index) * 4096;
        const written = linux.pwrite(@intCast(image), record[4..].ptr, 4096, offset);
        if (linux.errno(written) != .SUCCESS or written != 4096) return error.WriteFailed;
    } else |err| if (err != error.EndOfFile) return err;
    if (linux.errno(linux.ftruncate(@intCast(image), durable_size)) != .SUCCESS) {
        return error.TruncateFailed;
    }
}

fn read_exact(fd: linux.fd_t, buffer: []u8) !void {
    var done: usize = 0;
    while (done < buffer.len) {
        const result = linux.read(fd, buffer[done..].ptr, buffer.len - done);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return if (done == 0) error.EndOfFile else error.ShortRead;
        done += result;
    }
}

/// The node's loop device over its image: attached once, its number kept beside the image.
fn loop_attach(paths: *const Paths) !u32 {
    var text_buffer: [16]u8 = undefined;
    if (read_small(paths.loop, &text_buffer)) |text| {
        return std.fmt.parseInt(u32, text, 10) catch error.BadLoop;
    }
    const control = linux.open("/dev/loop-control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(control) != .SUCCESS) return error.NoLoopControl;
    defer _ = linux.close(@intCast(control));
    const free = linux.ioctl(@intCast(control), loop_ctl_get_free, 0);
    if (linux.errno(free) != .SUCCESS) return error.NoFreeLoop;
    const number: u32 = @intCast(free);
    var device_buffer: [32]u8 = undefined;
    const device = try print_z(&device_buffer, "/dev/loop{d}", .{number});
    // devtmpfs creates the device node as the device appears.
    var loop_fd: linux.fd_t = -1;
    for (0..stop_attempts_max) |_| {
        const result = linux.open(device, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(result) == .SUCCESS) {
            loop_fd = @intCast(result);
            break;
        }
        sleep_ns(poll_interval_ns);
    } else return error.NoLoopDevice;
    defer _ = linux.close(loop_fd);
    const image = linux.open(paths.image, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(image) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(image));
    if (linux.errno(linux.ioctl(loop_fd, loop_set_fd, image)) != .SUCCESS) return error.LoopSetFd;
    var number_buffer: [16]u8 = undefined;
    try file_write(paths.loop, try std.fmt.bufPrint(&number_buffer, "{d}", .{number}));
    return number;
}

// Disk faults ------------------------------------------------------------------------------
// A durable node's disk is a device-mapper device over its loop device: linear while healthy,
// another target while it fails (the table swapped without freezing the filesystem, so no
// dirty data is flushed by it: a crash after still loses what was not synced).

/// How a failing disk behaves.
pub const DiskFailure = enum {
    /// Every read and write fails (EIO).
    errors,
    /// Writes fail; reads work.
    write_errors,
    /// Writes are acknowledged and never stored (a lying disk or controller cache): a crash
    /// after loses them although they were synced, and so does the kernel dropping a written
    /// page from its cache before any crash (memory pressure): a read then returns what the disk
    /// held, as a lying disk's would (CE36, the Lean replica of determinismo).
    lost_writes,
    /// Reads return one byte of each request changed (bit rot). What is stored is intact but where
    /// the node writes part of a page it did not hold: the kernel reads the page to merge the
    /// write, that read is corrupted, and the write-back stores its changed byte, as a real
    /// disk's would. Every read it corrupts is named (`disk_corrupt_read`: node, file, sectors,
    /// the byte; disk_reads_trace), so a durability judge excludes those pages, or flags a loss
    /// inside one, without guessing (CE31, the Lean replica of determinismo).
    corrupt_reads,
    /// Every request waits (a slow or overloaded disk).
    slow,
};

/// One disk fault's parameters (platform decisions, or asked for by a scenario).
pub const DiskFault = struct {
    failure: DiskFailure,
    /// slow: how long each request waits.
    delay_ms: u32 = 0,
    /// corrupt_reads: which byte of each read (from 1) becomes `corrupt_value`.
    corrupt_byte: u32 = 1,
    corrupt_value: u8 = 0,
    /// A file of the node's (its path from the node's root, in its writable layer) whose blocks
    /// alone fail, the rest of the disk healthy: one fault in one file at a time, as CORDS
    /// injects them (Ganesan et al., FAST 2017). "": the whole disk.
    file: []const u8 = "",
};

/// The node's disk fails as `fault` says until disk_heal. Its exit meanwhile is expected.
pub fn disk_fail(name: []const u8, fault: DiskFault) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    const loop = try loop_read(&paths);
    var parameters_buffer: [128]u8 = undefined;
    const target: MapperTarget = switch (fault.failure) {
        // flakey: <device> <offset> <up seconds> <down seconds> [<feature count> <features>]:
        // never up, down until the table is swapped back.
        .errors => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1",
            .{loop},
        ) },
        .write_errors => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 1 error_writes",
            .{loop},
        ) },
        .lost_writes => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 1 drop_writes",
            .{loop},
        ) },
        .corrupt_reads => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 5 corrupt_bio_byte {d} r {d} 0",
            .{ loop, @max(fault.corrupt_byte, 1), fault.corrupt_value },
        ) },
        .slow => .{ .kind = "delay", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 {d}",
            .{ loop, fault.delay_ms },
        ) },
    };
    // The fault's table, for a crash meanwhile to put back (disk_table_now).
    var flag_buffer: [path_size_max]u8 = undefined;
    var record_buffer: [disk_record_size]u8 = undefined;
    var extents: [fiemap_extents_max]Extent = undefined;
    const aimed = if (fault.file.len > 0) try file_extents(&paths, fault.file, &extents) else &.{};
    if (fault.file.len > 0 and aimed.len == 0) return error.FileNotOnDisk;
    const record = if (aimed.len > 0)
        try aimed_record(&record_buffer, loop, target, aimed)
    else
        try std.fmt.bufPrint(&record_buffer, "{s} {s}", .{ target.kind, target.parameters });
    try file_write(try disk_failing_path(&flag_buffer, &paths), record);
    var failed_buffer: [path_size_max]u8 = undefined;
    try file_write(try disk_failed_path(&failed_buffer, &paths), "1");
    var name_buffer: [mapper_name_size]u8 = undefined;
    const mapper = try mapper_name(&name_buffer, name);
    const table: MapperTarget = if (aimed.len > 0) .{ .segments = record[aimed_prefix.len..] } else target;
    // Its reads named from before the table fails them (a read just before is named too: never
    // one missed).
    if (fault.failure == .corrupt_reads) disk_reads_trace_start(name, &paths, mapper, fault.file, aimed, @max(fault.corrupt_byte, 1));
    try mapper_table(mapper, table);
    sdk.event("node_disk_fail", .{ .node = name, .failure = fault.failure, .file = fault.file, .extents = aimed.len });
}

/// A file of the node's to aim a disk fault at, drawn (`fault.disk_file`) among the regular files
/// of its writable layer that have blocks on its disk (not ours: etc/hosts and the like), in the
/// walk's order; its path from the node's root, in `buffer`. Null when there is none.
pub fn disk_file_draw(name: []const u8, buffer: *[path_size_max]u8) ?[]const u8 {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var walk: DiskFilesWalk = .{};
    disk_files_walk(paths.upper, paths.upper.len + 1, &walk, 0);
    if (walk.count == 0) return null;
    walk = .{ .pick = sdk.random_below_named("fault.disk_file", walk.count), .chosen = buffer };
    disk_files_walk(paths.upper, paths.upper.len + 1, &walk, 0);
    return walk.chosen_path;
}

const DiskFilesWalk = struct {
    count: u64 = 0,
    /// The index of the file to take, on the second walk.
    pick: ?u64 = null,
    chosen: ?*[path_size_max]u8 = null,
    chosen_path: ?[]const u8 = null,
};

fn disk_files_walk(directory: [:0]const u8, prefix: usize, walk: *DiskFilesWalk, depth: u32) void {
    if (depth == crash_files_depth_max or walk.chosen_path != null or walk.count == crash_files_max) return;
    const fd = linux.open(directory, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entries[name_offset])));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buffer: [path_size_max]u8 = undefined;
            const child = print_z(&child_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            if (entry.type == linux.DT.DIR) {
                disk_files_walk(child, prefix, walk, depth + 1);
                if (walk.chosen_path != null) return;
                continue;
            }
            if (entry.type != linux.DT.REG) continue;
            const relative = child[prefix..];
            const ours = for (crash_files_ours) |file| {
                if (std.mem.eql(u8, relative, file)) break true;
            } else false;
            if (ours or !on_disk(child)) continue;
            if (walk.pick) |pick| if (pick == walk.count) {
                const chosen = walk.chosen.?;
                @memcpy(chosen[0..relative.len], relative);
                walk.chosen_path = chosen[0..relative.len];
                return;
            };
            walk.count += 1;
            if (walk.count == crash_files_max) return;
        }
    }
}

/// Whether a file has blocks on the disk (an extent written back).
fn on_disk(path: [:0]const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var map: Fiemap = .{
        .start = 0,
        .length = std.math.maxInt(u64),
        .flags = 0,
        .mapped_extents = 0,
        .extent_count = fiemap_extents_max,
        .reserved = 0,
        .extents = undefined,
    };
    if (linux.errno(linux.ioctl(@intCast(fd), fiemap_request, @intFromPtr(&map))) != .SUCCESS) return false;
    for (map.extents[0..@min(map.mapped_extents, fiemap_extents_max)]) |extent| {
        if (extent.flags & fiemap_extent_delalloc == 0 and extent.length > 0) return true;
    }
    return false;
}

/// A disk record's first line when its table is aimed at a file's blocks (disk_table_now).
const aimed_prefix = "aimed\n";
/// A disk fault's table as recorded: one target, or an aimed table's segments.
const disk_record_size = 16 << 10;

/// A file's blocks on the node's disk, in 512-byte sectors.
const Extent = struct { start: u64, count: u64 };

// The reads a corrupt_reads fault corrupts, named ---------------------------------------------
// dm-flakey changes byte `corrupt_byte` of every read bio while the fault lasts and says nothing;
// the block layer's block_bio_queue tracepoint says each bio queued on the node's device-mapper
// device (its sectors), so each read is an event: what a durability judge needs to tell a byte
// the fault stored (a read-modify-write's) from a byte the system lost (CE31).

const disk_reads_events_max = 4096;

fn disk_reads_tracer_path(buffer: *[path_size_max]u8, paths: *const Paths) ![:0]const u8 {
    return print_z(buffer, "{s}/disk-reads-tracer", .{paths.directory});
}

fn disk_reads_instance(buffer: *[path_size_max]u8, mapper: []const u8) ![:0]const u8 {
    return print_z(buffer, "/sys/kernel/tracing/instances/det-reads-{s}", .{mapper});
}

/// What the heal writes into the tracer's instance (its trace_marker) once no read is traced
/// any more: the reader names every read before it, then exits.
const disk_reads_end_marker = "det-corrupt-reads-end";

/// How long the heal waits for the reader to drain to the end marker before killing it.
const disk_reads_drain_ms = 2000;

/// The tracer started (a process of its own, its pid beside the node's state), or said failed.
fn disk_reads_trace_start(name: []const u8, paths: *const Paths, mapper: []const u8, file: []const u8, aimed: []const Extent, corrupt_byte: u32) void {
    // The device by its minor (/dev/dm-N, as mount and fsck use it): the guest has no udev, so no
    // /dev/mapper/<name> links (every trace failed at statx, e2e disk 2026-11-26).
    const dev = mapper_call(dm_dev_status, mapper, 0, null) catch {
        sdk.event("disk_reads_trace_failed", .{ .node = name, .why = "dm_status" });
        return;
    };
    var device_buffer: [path_size_max]u8 = undefined;
    const device = print_z(&device_buffer, "/dev/dm-{d}", .{(dev & 0xff) | ((dev >> 12) & 0xfff00)}) catch return;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, device, 0, .{ .TYPE = true }, &stat)) != .SUCCESS) {
        sdk.event("disk_reads_trace_failed", .{ .node = name, .why = "statx" });
        return;
    }
    const major = stat.rdev_major;
    const minor = stat.rdev_minor;
    _ = linux.mount("none", "/sys/kernel/tracing", "tracefs", 0, 0); // Mounted already, or now.
    var instance_buffer: [path_size_max]u8 = undefined;
    const instance = disk_reads_instance(&instance_buffer, mapper) catch return;
    var path_buffer: [path_size_max]u8 = undefined;
    if (linux.errno(linux.mkdir(instance, 0o700)) == .EXIST) {
        // A tracer left behind (its removal failed): what its buffer holds is an earlier
        // fault's, cleared so this one names only its own reads (CE43, the Lean replica of
        // determinismo).
        file_write(print_z(&path_buffer, "{s}/trace", .{instance}) catch return, "") catch {};
    }
    var filter_buffer: [64]u8 = undefined;
    // The kernel's dev_t (MKDEV: major << 20 | minor), this device's bios alone.
    const filter = std.fmt.bufPrint(&filter_buffer, "dev == {d}\n", .{(@as(u64, major) << 20) | minor}) catch return;
    const armed = blk: {
        file_write(print_z(&path_buffer, "{s}/events/block/block_bio_queue/filter", .{instance}) catch break :blk false, filter) catch {};
        file_write(print_z(&path_buffer, "{s}/events/block/block_bio_queue/enable", .{instance}) catch break :blk false, "1\n") catch break :blk false;
        file_write(print_z(&path_buffer, "{s}/tracing_on", .{instance}) catch break :blk false, "1\n") catch break :blk false;
        break :blk true;
    };
    if (!armed) {
        sdk.event("disk_reads_trace_failed", .{ .node = name, .why = "tracefs" });
        return;
    }
    const pipe = print_z(&path_buffer, "{s}/trace_pipe", .{instance}) catch return;
    // Opened here, before the table fails reads: none queued after it is missed.
    const fd = linux.open(pipe, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        sdk.event("disk_reads_trace_failed", .{ .node = name, .why = "trace_pipe" });
        return;
    }
    // Detached (a fork of a fork): the injector that started it may not be the one that heals.
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) {
        _ = linux.close(@intCast(fd));
        return;
    }
    if (child != 0) {
        _ = linux.close(@intCast(fd));
        var status: i32 = 0;
        _ = linux.waitpid(@intCast(child), &status, 0);
        return;
    }
    const reader = linux.fork();
    if (reader != 0) linux.exit(0);
    var pid_buffer: [32]u8 = undefined;
    var tracer_buffer: [path_size_max]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{linux.getpid()}) catch linux.exit(1);
    file_write(disk_reads_tracer_path(&tracer_buffer, paths) catch linux.exit(1), pid_text) catch linux.exit(1);
    disk_reads_read(@intCast(fd), name, file, aimed, corrupt_byte, major, minor);
    linux.exit(0);
}

/// The tracer's loop: each read bio queued on the device (inside the aimed extents, for a fault
/// aimed at a file) an event, at most disk_reads_events_max a fault.
fn disk_reads_read(fd: linux.fd_t, name: []const u8, file: []const u8, aimed: []const Extent, corrupt_byte: u32, major: u32, minor: u32) void {
    var kept_extents: [fiemap_extents_max]Extent = undefined;
    const extents = kept_extents[0..aimed.len];
    @memcpy(extents, aimed);
    var buffer: [16384]u8 = undefined;
    var kept: usize = 0;
    var events: u32 = 0;
    while (true) {
        const size = linux.read(fd, buffer[kept..].ptr, buffer.len - kept);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        kept += size;
        var from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..kept], from, '\n')) |end| : (from = end + 1) {
            // The heal's marker: every read queued before it named, nothing after it traced.
            if (std.mem.indexOf(u8, buffer[from..end], "tracing_mark_write: " ++ disk_reads_end_marker) != null) return;
            const read = bio_read_line(buffer[from..end]) orelse continue;
            if (read.major != major or read.minor != minor) continue;
            if (extents.len > 0 and !extents_overlap(extents, read.sector, read.sectors)) continue;
            if (events > disk_reads_events_max) continue;
            var parts_buffer: [fiemap_extents_max + 1]CorruptedPart = undefined;
            for (read_corrupted_parts(extents, read.sector, read.sectors, corrupt_byte, &parts_buffer)) |part| {
                if (events == disk_reads_events_max) {
                    sdk.event("disk_corrupt_reads_capped", .{ .node = name, .file = file, .events = events });
                    events += 1;
                    break;
                }
                sdk.event("disk_corrupt_read", .{
                    .node = name,
                    .file = file,
                    .sector = part.sector,
                    .sectors = part.sectors,
                    .byte = part.byte, // The device's byte the fault changed.
                });
                events += 1;
            }
        }
        std.mem.copyForwards(u8, buffer[0 .. kept - from], buffer[from..kept]);
        kept -= from;
        if (kept == buffer.len) kept = 0; // A line longer than the buffer: dropped.
    }
}

/// A part of a read the fault corrupted: its sectors and the device's byte it changed.
const CorruptedPart = struct { sector: u64, sectors: u64, byte: u64 };

/// The parts of a read of `sectors` from `sector` the fault changed, and the byte of each. A
/// fault over the whole device (no extents): the read whole. An aimed one: device-mapper splits
/// the read at its table's segments (aimed_record's), and dm-flakey changes byte `corrupt_byte`
/// of each part over an extent, counted from the part's start, nothing in the linear parts, and
/// nothing in a part shorter than that (CE54, the Lean replica of determinismo: the read's first
/// sector's byte was named, one the fault never changed when the read began in a linear part).
fn read_corrupted_parts(extents: []const Extent, sector: u64, sectors: u64, corrupt_byte: u64, out: []CorruptedPart) []const CorruptedPart {
    assert(corrupt_byte >= 1);
    assert(out.len > extents.len);
    if (extents.len == 0) {
        if (corrupt_byte > sectors * 512) return out[0..0];
        out[0] = .{ .sector = sector, .sectors = sectors, .byte = sector * 512 + corrupt_byte - 1 };
        return out[0..1];
    }
    var count: usize = 0;
    for (extents) |extent| {
        const part_start = @max(sector, extent.start);
        const part_end = @min(sector + sectors, extent.start + extent.count);
        if (part_start >= part_end or corrupt_byte > (part_end - part_start) * 512) continue;
        out[count] = .{ .sector = part_start, .sectors = part_end - part_start, .byte = part_start * 512 + corrupt_byte - 1 };
        count += 1;
    }
    return out[0..count];
}

test "a read over a linear part and two aimed extents names each byte the fault changed" {
    // CE54 (the Lean replica of determinismo): device-mapper splits a read at its table's
    // segments, and dm-flakey changes byte `corrupt_bio_byte` of each part it completes, counted
    // from the part's start; the read's first sector's byte was named, a byte the fault never
    // changed when the read began in a linear part (a hole before the extent, written during
    // the fault, read with it), and one byte of two for a read over two extents.
    // The file's extents at the fault's start: sectors 100-107 and 116-123; the holes before and
    // between them were written during the fault at 92-99 and 108-115.
    const aimed = [_]Extent{ .{ .start = 100, .count = 8 }, .{ .start = 116, .count = 8 } };
    var parts: [fiemap_extents_max + 1]CorruptedPart = undefined;
    // One read of 32 sectors from 92: linear 92-99, flakey 100-107, linear 108-115, flakey 116-123.
    const changed = read_corrupted_parts(&aimed, 92, 32, 5, &parts);
    try std.testing.expectEqual(@as(usize, 2), changed.len);
    try std.testing.expectEqual(CorruptedPart{ .sector = 100, .sectors = 8, .byte = 100 * 512 + 4 }, changed[0]);
    try std.testing.expectEqual(CorruptedPart{ .sector = 116, .sectors = 8, .byte = 116 * 512 + 4 }, changed[1]);
    // A read inside one extent: its own first sector's byte.
    try std.testing.expectEqualSlices(CorruptedPart, &.{.{ .sector = 104, .sectors = 4, .byte = 104 * 512 + 4 }}, read_corrupted_parts(&aimed, 104, 4, 5, &parts));
    // A fault over the whole device (no extents): the read whole, its first sector's byte.
    try std.testing.expectEqualSlices(CorruptedPart, &.{.{ .sector = 92, .sectors = 32, .byte = 92 * 512 + 4 }}, read_corrupted_parts(&.{}, 92, 32, 5, &parts));
    // A part shorter than the byte's offset: nothing changed there.
    try std.testing.expectEqual(@as(usize, 0), read_corrupted_parts(&aimed, 98, 3, 1100, &parts).len);
}

fn extents_overlap(extents: []const Extent, sector: u64, sectors: u64) bool {
    for (extents) |extent| {
        if (sector < extent.start + extent.count and extent.start < sector + sectors) return true;
    }
    return false;
}

const BioRead = struct { major: u32, minor: u32, sector: u64, sectors: u64 };

/// A block_bio_queue line's read ("... block_bio_queue: 252,0 R 2048 + 8 [comm]": its device,
/// its kind of request, a read's R first, its first sector and its count), else null.
fn bio_read_line(line: []const u8) ?BioRead {
    const marker = "block_bio_queue: ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    var words = std.mem.tokenizeScalar(u8, line[at + marker.len ..], ' ');
    const device = words.next() orelse return null;
    const rwbs = words.next() orelse return null;
    if (rwbs.len == 0 or rwbs[0] != 'R') return null;
    const sector_text = words.next() orelse return null;
    if (!std.mem.eql(u8, words.next() orelse return null, "+")) return null;
    const count_text = words.next() orelse return null;
    const comma = std.mem.indexOfScalar(u8, device, ',') orelse return null;
    return .{
        .major = std.fmt.parseInt(u32, device[0..comma], 10) catch return null,
        .minor = std.fmt.parseInt(u32, device[comma + 1 ..], 10) catch return null,
        .sector = std.fmt.parseInt(u64, sector_text, 10) catch return null,
        .sectors = std.fmt.parseInt(u64, count_text, 10) catch return null,
    };
}

test bio_read_line {
    const read = bio_read_line("  kworker/u8:2-123  [000] ..... 12.345678: block_bio_queue: 252,0 R 2048 + 8 [det-selftest-no]").?;
    try std.testing.expectEqual(BioRead{ .major = 252, .minor = 0, .sector = 2048, .sectors = 8 }, read);
    try std.testing.expect(bio_read_line("  x-1 [000] ..... 1.0: block_bio_queue: 252,0 RA 64 + 32 [x]") != null); // Readahead.
    try std.testing.expect(bio_read_line("  x-1 [000] ..... 1.0: block_bio_queue: 252,0 WS 64 + 8 [x]") == null); // A write.
    try std.testing.expect(bio_read_line("  x-1 [000] ..... 1.0: block_rq_issue: 252,0 R 4096 () 64 + 8 [x]") == null);
    try std.testing.expect(extents_overlap(&.{.{ .start = 100, .count = 8 }}, 104, 8));
    try std.testing.expect(!extents_overlap(&.{.{ .start = 100, .count = 8 }}, 108, 8));
}

/// The tracer stopped (its pid read and killed, its instance removed). None running: nothing.
fn disk_reads_trace_stop(paths: *const Paths) void {
    var tracer_buffer: [path_size_max]u8 = undefined;
    const tracer = disk_reads_tracer_path(&tracer_buffer, paths) catch return;
    var text_buffer: [32]u8 = undefined;
    const text = read_small(tracer, &text_buffer) orelse return;
    defer _ = linux.unlink(tracer);
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return;
    const node = std.fs.path.basename(paths.directory);
    var name_buffer: [mapper_name_size]u8 = undefined;
    const mapper = mapper_name(&name_buffer, node) catch return;
    var instance_buffer: [path_size_max]u8 = undefined;
    const instance = disk_reads_instance(&instance_buffer, mapper) catch return;
    var path_buffer: [path_size_max]u8 = undefined;
    // Drained, not killed: reads queued just before the heal are still in the instance's
    // buffer, the reader not yet run. Killed, they were never named, and the instance, removed
    // while the dying reader held its pipe, stayed with them for the node's next fault to name
    // as its own (CE43, the Lean replica of determinismo). No read traced from here on, then
    // the end marker after the last one; the reader names them all and exits at it.
    file_write(print_z(&path_buffer, "{s}/events/block/block_bio_queue/enable", .{instance}) catch return, "0\n") catch {};
    const pidfd = linux.pidfd_open(pid, 0);
    const watched = linux.errno(pidfd) == .SUCCESS;
    defer if (watched) {
        _ = linux.close(@intCast(pidfd));
    };
    file_write(print_z(&path_buffer, "{s}/trace_marker", .{instance}) catch return, disk_reads_end_marker ++ "\n") catch {};
    if (watched and !pid_exited(@intCast(pidfd), disk_reads_drain_ms)) {
        sdk.event("disk_reads_trace_failed", .{ .node = node, .why = "drain" });
        _ = linux.kill(pid, .KILL);
        _ = pid_exited(@intCast(pidfd), disk_reads_drain_ms);
    }
    file_write(print_z(&path_buffer, "{s}/tracing_on", .{instance}) catch return, "0\n") catch {};
    if (linux.errno(linux.rmdir(instance)) != .SUCCESS) {
        sdk.event("disk_reads_trace_failed", .{ .node = node, .why = "rmdir" });
    }
}

/// Whether the process a pidfd refers to exited within `timeout_ms`.
fn pid_exited(pidfd: linux.fd_t, timeout_ms: i32) bool {
    var fds = [_]linux.pollfd{.{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 }};
    const ready = linux.poll(&fds, fds.len, timeout_ms);
    return linux.errno(ready) == .SUCCESS and ready == 1;
}

/// The extents of `file` (a path from the node's root) in its writable layer, as the disk holds
/// them (FIEMAP without FIEMAP_FLAG_SYNC: asking writes nothing back), adjacent ones joined. Data
/// never written back has no place on the disk yet (delalloc): left out.
fn file_extents(paths: *const Paths, file: []const u8, out: *[fiemap_extents_max]Extent) ![]const Extent {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/{s}", .{ paths.upper, std.mem.trimStart(u8, file, "/") });
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.FileNotOnDisk;
    defer _ = linux.close(@intCast(fd));
    var map: Fiemap = .{
        .start = 0,
        .length = std.math.maxInt(u64),
        .flags = 0,
        .mapped_extents = 0,
        .extent_count = fiemap_extents_max,
        .reserved = 0,
        .extents = undefined,
    };
    if (linux.errno(linux.ioctl(@intCast(fd), fiemap_request, @intFromPtr(&map))) != .SUCCESS) return error.FileNotOnDisk;
    var count: usize = 0;
    for (map.extents[0..@min(map.mapped_extents, fiemap_extents_max)]) |extent| {
        if (extent.flags & fiemap_extent_delalloc != 0 or extent.length == 0) continue;
        const first = extent.physical / 512;
        const sectors = (extent.length + 511) / 512;
        if (first + sectors > durable_size / 512) continue;
        if (count > 0 and out[count - 1].start + out[count - 1].count == first) {
            out[count - 1].count += sectors;
            continue;
        }
        out[count] = .{ .start = first, .count = sectors };
        count += 1;
    }
    std.mem.sort(Extent, out[0..count], {}, struct {
        fn less(_: void, a: Extent, b: Extent) bool {
            return a.start < b.start;
        }
    }.less);
    return out[0..count];
}

/// The aimed table, recorded: `aimed_prefix`, then a line a segment, "<start> <length> <kind>
/// <parameters>": the failing target over each of the file's extents (its device offset the
/// segment's own), linear over the rest.
fn aimed_record(buffer: []u8, loop: u32, target: MapperTarget, extents: []const Extent) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll(aimed_prefix);
    // The failing target's parameters after its device and offset ("7:<loop> 0 ...").
    var head_buffer: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "7:{d} 0", .{loop});
    if (!std.mem.startsWith(u8, target.parameters, head)) return error.UnaimableTarget;
    const rest = std.mem.trimStart(u8, target.parameters[head.len..], " ");
    const total = durable_size / 512;
    var at: u64 = 0;
    for (extents) |extent| {
        if (extent.start > at) try writer.print("{d} {d} linear 7:{d} {d}\n", .{ at, extent.start - at, loop, at });
        try writer.print("{d} {d} {s} 7:{d} {d}{s}{s}\n", .{
            extent.start, extent.count, target.kind, loop, extent.start, if (rest.len > 0) " " else "", rest,
        });
        at = extent.start + extent.count;
    }
    if (at < total) try writer.print("{d} {d} linear 7:{d} {d}\n", .{ at, total - at, loop, at });
    return writer.buffered();
}

test aimed_record {
    var buffer: [1024]u8 = undefined;
    const extents = [_]Extent{ .{ .start = 100, .count = 8 }, .{ .start = 400, .count = 16 } };
    const record = try aimed_record(&buffer, 3, .{ .kind = "flakey", .parameters = "7:3 0 0 1 1 error_writes" }, &extents);
    const total = durable_size / 512;
    var expected_buffer: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "aimed\n0 100 linear 7:3 0\n100 8 flakey 7:3 100 0 1 1 error_writes\n" ++
        "108 292 linear 7:3 108\n400 16 flakey 7:3 400 0 1 1 error_writes\n416 {d} linear 7:3 416\n", .{total - 416});
    try std.testing.expectEqualStrings(expected, record);
}

/// The node's disk works again. True when the node must start again (the caller starts it):
/// it exited, or its filesystem gave up (ext4 remounts read-only when its journal fails); it
/// is then stopped, and its disk unmounted (mounted afresh at the start: the journal replays).
pub fn disk_heal(name: []const u8) !bool {
    var paths: Paths = undefined;
    try paths.init(name);
    var flag_buffer: [path_size_max]u8 = undefined;
    const flag = try disk_failing_path(&flag_buffer, &paths);
    defer _ = linux.unlink(flag);
    const loop = try loop_read(&paths);
    var parameters_buffer: [64]u8 = undefined;
    var name_buffer: [mapper_name_size]u8 = undefined;
    const mapper = try mapper_name(&name_buffer, name);
    try mapper_table(mapper, try disk_baseline_target(&parameters_buffer, loop));
    disk_reads_trace_stop(&paths); // After the table heals: a read just before it is named too.
    sdk.event("node_disk_heal", .{ .node = name });
    if (pid_read(name) != null and layer_writable(&paths)) return false;
    try kill(name);
    if (exists(paths.mounted)) try layer_unmount(&paths);
    return true;
}

/// Whether the node ended of itself after a disk fault of its current start healed: its pidfile
/// still names its main process (a stop or a kill takes the pidfile away first), nothing of it
/// runs, and its disk failed since it started and fails no more. A fail-stop under way as its disk
/// healed ends after disk_heal looked (Kafka's orderly shutdown of a broker whose log directory
/// failed takes seconds: hunt run 1804, timeline 17, two brokers down for good after the heal,
/// the cluster with them): started again as disk_heal starts one that ended before
/// (disk_remount first), as an operator brings back a node whose disk was repaired.
pub fn ended_after_disk_heal(name: []const u8) bool {
    if (pid_recorded(name) == null) return false;
    if (!exited(name)) return false;
    return disk_failed_this_start(name) and !disk_failing(name);
}

/// The node's disk unmounted, to be mounted afresh at its next start (its journal replays), as
/// disk_heal leaves one that must start again.
pub fn disk_remount(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    if (exists(paths.mounted)) try layer_unmount(&paths);
}

/// Whether the node's disk is failing (a disk fault is under way): its exit is expected.
/// The table the node's disk has when no crash is under way: a disk fault's, or its baseline.
fn disk_table_now(paths: *const Paths, loop: u32, record: *[disk_record_size]u8, parameters: *[64]u8) !MapperTarget {
    var flag_buffer: [path_size_max]u8 = undefined;
    if (read_small(try disk_failing_path(&flag_buffer, paths), record)) |text| {
        if (std.mem.startsWith(u8, text, aimed_prefix)) return .{ .segments = text[aimed_prefix.len..] };
        const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadDiskFault;
        return .{ .kind = text[0..space], .parameters = text[space + 1 ..] };
    }
    return disk_baseline_target(parameters, loop);
}

pub fn disk_failing(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return false;
    var flag_buffer: [path_size_max]u8 = undefined;
    return exists(disk_failing_path(&flag_buffer, &paths) catch return false);
}

/// Whether the node's disk failed at some point since its program last started (a disk fault
/// under way or healed since): a process giving up on its disk's errors may end after the heal
/// (Kafka's orderly shutdown on a failed log directory, 0.3 s after it: trial run 1783), and its
/// exit names them all the same. Cleared at each start: a start that meets a file torn by a
/// power loss, with no disk fault since, is not the fault's doing.
pub fn disk_failed_this_start(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return false;
    var flag_buffer: [path_size_max]u8 = undefined;
    return exists(disk_failed_path(&flag_buffer, &paths) catch return false);
}

fn disk_failing_path(buffer: *[path_size_max]u8, paths: *const Paths) ![:0]const u8 {
    return print_z(buffer, "{s}/disk-failing", .{paths.directory});
}

fn disk_failed_path(buffer: *[path_size_max]u8, paths: *const Paths) ![:0]const u8 {
    return print_z(buffer, "{s}/disk-failed", .{paths.directory});
}

fn loop_read(paths: *const Paths) !u32 {
    var text_buffer: [16]u8 = undefined;
    const text = read_small(paths.loop, &text_buffer) orelse return error.NotADurableDisk;
    return std.fmt.parseInt(u32, text, 10) catch error.BadLoop;
}

/// Whether the node's layer takes writes: a file made and removed. ext4 aborts its journal on an
/// I/O error and refuses writes from then on, though /proc/mounts and statfs's flags still say
/// read-write; a node that ran through its disk fault was neither restarted at the heal nor
/// able to start again later (ParticleDB's smoke run 349: "fault_restart_failed: OpenFailed",
/// /etc/hosts unwritable, 112 of 327 timelines' final reads reaching no node).
fn layer_writable(paths: *const Paths) bool {
    var path_buffer: [path_size_max]u8 = undefined;
    const probe = print_z(&path_buffer, "{s}/.det-writable", .{paths.layer}) catch return false;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(probe, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return false;
    _ = linux.close(@intCast(fd));
    return linux.errno(linux.unlink(probe)) == .SUCCESS;
}

/// devtmpfs creates the device node as the device appears.
fn device_wait(device: [:0]const u8) !void {
    for (0..stop_attempts_max) |_| {
        if (exists(device)) return;
        sleep_ns(poll_interval_ns);
    }
    return error.NoDevice;
}

/// Until no filesystem holds the device. After a crash its old filesystem outlives the unmount
/// for as long as a mount namespace still has it; mounted then, the disk is busy, or comes back
/// as that shut down filesystem.
fn device_free_wait(device: [:0]const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .EXCL = true, .CLOEXEC = true };
    for (0..stop_attempts_max) |_| {
        const fd = linux.open(device, flags, 0);
        switch (linux.errno(fd)) {
            .SUCCESS => {
                _ = linux.close(@intCast(fd));
                return;
            },
            .BUSY => sleep_ns(poll_interval_ns),
            else => return error.OpenFailed,
        }
    }
    return error.DeviceBusy;
}

// device-mapper's ioctls (linux/dm-ioctl.h), on /dev/mapper/control.
const DmIoctl = extern struct {
    version: [3]u32 = .{ 4, 0, 0 },
    data_size: u32 = 0,
    data_start: u32 = 0,
    target_count: u32 = 0,
    open_count: i32 = 0,
    flags: u32 = 0,
    event_nr: u32 = 0,
    padding: u32 = 0,
    dev: u64 = 0,
    name: [128]u8 = @splat(0),
    uuid: [129]u8 = @splat(0),
    data: [7]u8 = @splat(0),
};
const DmTargetSpec = extern struct {
    sector_start: u64 = 0,
    length: u64,
    status: i32 = 0,
    next: u32 = 0,
    target_type: [16]u8 = @splat(0),
};
comptime {
    assert(@sizeOf(DmIoctl) == 312);
    assert(@sizeOf(DmTargetSpec) == 40);
}
const dm_dev_create = 3;
const dm_dev_remove = 4;
const dm_dev_suspend = 6; // Without DM_SUSPEND_FLAG: resume, swapping in a loaded table.
const dm_dev_status = 7;
const dm_table_load = 9;
/// Swap tables without freezing the filesystem (which would flush its dirty data).
const dm_skip_lockfs_flag = 1 << 10;
const mapper_name_size = 128;
const mapper_buffer_size = 32 << 10;

const MapperTarget = struct {
    kind: []const u8 = "",
    parameters: []const u8 = "",
    /// Instead, several segments, a line each "<start> <length> <kind> <parameters>" (sectors),
    /// covering the disk in order: an aimed disk fault's table (aimed_record).
    segments: []const u8 = "",
};

/// What a sync costs outside disk faults, set when faults start: a disk that answers at once
/// leaves no time for another thread to run while one waits on it, so races around a sync
/// (a write that lands after a newer one) would never happen.
const disk_baseline_path = state_root ++ "/disk_baseline_ms";

/// Every durable disk gets `delay_ms` on each I/O (0: none), from now on and after a disk fault.
pub fn disk_baseline_set(system: *const schema.System, delay_ms: u32) !void {
    var text_buffer: [16]u8 = undefined;
    try file_write(disk_baseline_path, try std.fmt.bufPrint(&text_buffer, "{d}", .{delay_ms}));
    for (system.nodes) |*node| {
        if (!node.faults.crash and !node.faults.disk) continue;
        var paths: Paths = undefined;
        try paths.init(node.name);
        const loop = loop_read(&paths) catch continue; // Not started yet: attached with it.
        if (disk_failing(node.name)) continue; // Healed to it.
        var parameters_buffer: [64]u8 = undefined;
        var name_buffer: [mapper_name_size]u8 = undefined;
        const target = try disk_baseline_target(&parameters_buffer, loop);
        try mapper_table(try mapper_name(&name_buffer, node.name), target);
    }
}

fn disk_baseline_target(buffer: *[64]u8, loop: u32) !MapperTarget {
    var text_buffer: [16]u8 = undefined;
    const text = read_small(disk_baseline_path, &text_buffer) orelse "0";
    const delay_ms = std.fmt.parseInt(u32, text, 10) catch return error.BadDiskBaseline;
    if (delay_ms == 0) {
        return .{ .kind = "linear", .parameters = try std.fmt.bufPrint(buffer, "7:{d} 0", .{loop}) };
    }
    return .{
        .kind = "delay",
        .parameters = try std.fmt.bufPrint(buffer, "7:{d} 0 {d}", .{ loop, delay_ms }),
    };
}

fn mapper_name(buffer: *[mapper_name_size]u8, node: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "det-{s}", .{node});
}

/// The node's device-mapper device over its loop device (linear), created once: its minor.
fn mapper_attach(node: []const u8, loop: u32) !u32 {
    var name_buffer: [mapper_name_size]u8 = undefined;
    const name = try mapper_name(&name_buffer, node);
    const dev = mapper_call(dm_dev_status, name, 0, null) catch blk: {
        _ = try mapper_call(dm_dev_create, name, 0, null);
        var parameters_buffer: [64]u8 = undefined;
        try mapper_table(name, try disk_baseline_target(&parameters_buffer, loop));
        break :blk try mapper_call(dm_dev_status, name, 0, null);
    };
    // The kernel's huge_encode_dev: minor bits 0-7, then 20 and up.
    return @intCast((dev & 0xff) | ((dev >> 12) & 0xfff00));
}

/// Loads `target` over the whole disk and swaps it in. One process at a time: a load fills the
/// device's inactive slot and the resume swaps it in, so two interleaved (the fault injector's
/// disk baseline and a scenario's crash of the node) swapped one's table in twice, and the
/// other's resume found none (MapperFailed; the disk self-test, srv3 2026-10-28).
fn mapper_table(name: []const u8, target: MapperTarget) !void {
    const lock = linux.open(mapper_lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock) != .SUCCESS) return error.MapperLock;
    defer _ = linux.close(@intCast(lock));
    while (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX)) == .INTR) {}
    // Unlocked, not only closed: a process forked meanwhile from another thread has a copy of
    // the file, and a flock lasts until its last copy closes (output.zig's forwarders once kept
    // it held for good).
    defer _ = linux.flock(@intCast(lock), std.posix.LOCK.UN);
    _ = try mapper_call(dm_table_load, name, 0, target);
    _ = try mapper_call(dm_dev_suspend, name, dm_skip_lockfs_flag, null);
}

const mapper_lock_path = "/run/det-mapper.lock";

/// The segments' target specifications after the ioctl header, each followed by its parameters
/// (NUL-terminated, the next one 8-byte aligned: `next` the offset from this one); how many.
fn mapper_segments(buffer: *align(8) [mapper_buffer_size]u8, segments: []const u8) !u32 {
    var count: u32 = 0;
    var at: usize = @sizeOf(DmIoctl);
    var lines = std.mem.tokenizeScalar(u8, segments, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const first = std.fmt.parseInt(u64, fields.next() orelse return error.BadSegment, 10) catch return error.BadSegment;
        const length = std.fmt.parseInt(u64, fields.next() orelse return error.BadSegment, 10) catch return error.BadSegment;
        const kind = fields.next() orelse return error.BadSegment;
        const parameters = std.mem.trimStart(u8, fields.rest(), " ");
        const end = at + @sizeOf(DmTargetSpec) + parameters.len + 1;
        const next = std.mem.alignForward(usize, end, 8);
        if (next > buffer.len) return error.ParametersTooLong;
        const spec: *DmTargetSpec = @ptrCast(@alignCast(buffer[at..]));
        spec.* = .{ .sector_start = first, .length = length, .next = @intCast(next - at) };
        if (kind.len >= spec.target_type.len) return error.TargetTooLong;
        @memcpy(spec.target_type[0..kind.len], kind);
        @memcpy(buffer[at + @sizeOf(DmTargetSpec) ..][0..parameters.len], parameters);
        buffer[at + @sizeOf(DmTargetSpec) + parameters.len] = 0;
        at = next;
        count += 1;
    }
    if (count == 0) return error.BadSegment;
    return count;
}

fn mapper_call(command: u8, name: []const u8, flags: u32, target: ?MapperTarget) !u64 {
    const control = linux.open("/dev/mapper/control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(control) != .SUCCESS) return error.NoMapperControl;
    defer _ = linux.close(@intCast(control));
    var buffer: [mapper_buffer_size]u8 align(8) = @splat(0);
    const header: *DmIoctl = @ptrCast(&buffer);
    header.* = .{ .data_size = buffer.len, .data_start = @sizeOf(DmIoctl), .flags = flags };
    if (name.len >= header.name.len) return error.NameTooLong;
    @memcpy(header.name[0..name.len], name);
    if (target) |chosen| {
        if (chosen.segments.len > 0) {
            header.target_count = try mapper_segments(&buffer, chosen.segments);
        } else {
            header.target_count = 1;
            const spec: *DmTargetSpec = @ptrCast(@alignCast(buffer[@sizeOf(DmIoctl)..]));
            spec.* = .{ .length = durable_size / 512 };
            if (chosen.kind.len >= spec.target_type.len) return error.TargetTooLong;
            @memcpy(spec.target_type[0..chosen.kind.len], chosen.kind);
            const parameters = buffer[@sizeOf(DmIoctl) + @sizeOf(DmTargetSpec) ..];
            if (chosen.parameters.len >= parameters.len) return error.ParametersTooLong;
            @memcpy(parameters[0..chosen.parameters.len], chosen.parameters);
        }
    }
    // _IOWR(0xfd, command, struct dm_ioctl)
    const request: u32 = (3 << 30) | (@sizeOf(DmIoctl) << 16) | (0xfd << 8) | @as(u32, command);
    const result = linux.ioctl(@intCast(control), request, @intFromPtr(&buffer));
    return switch (linux.errno(result)) {
        .SUCCESS => header.dev,
        .NXIO => error.NoMapperDevice,
        .BUSY => error.MapperBusy,
        else => error.MapperFailed,
    };
}

/// Caps the node's CPU to `percent` of one CPU, or with null lifts the cap.
pub fn cpu_limit(name: []const u8, percent: ?u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/cpu.max", .{paths.cgroup});
    var value_buffer: [32]u8 = undefined;
    const period_us = 100_000;
    const value = if (percent) |share| blk: {
        const quota_us = @as(u32, share) * period_us / 100;
        break :blk try std.fmt.bufPrint(&value_buffer, "{d} {d}", .{ quota_us, period_us });
    } else "max 100000";
    try file_write(path, value);
}

/// Skews the node's realtime clock `offset_ns` from the guest's (0: none), in its time
/// namespace: CLOCK_REALTIME, its coarse form and CLOCK_TAI, read through the vDSO or a syscall,
/// and their absolute deadlines (the guest kernel's patch 0005: Linux offsets only the
/// monotonic and boot clocks, before anything runs in the namespace). As a skewed host's clock:
/// its monotonic clock and its timers' durations are untouched.
pub fn clock_offset(name: []const u8, offset_ns: i64) !void {
    const pid = pid_read(name) orelse return error.NotRunning;
    var path_buffer: [64]u8 = undefined;
    const path = try print_z(&path_buffer, "/proc/{d}/timens_offsets", .{pid});
    var value_buffer: [64]u8 = undefined;
    try file_write(path, realtime_offset_line(&value_buffer, offset_ns));
}

/// "realtime <seconds> <nanoseconds>": the seconds rounded down, the nanoseconds within
/// [0, 10^9), as the kernel reads an offset (a second and a half back: -2 500000000).
fn realtime_offset_line(buffer: *[64]u8, offset_ns: i64) []const u8 {
    const seconds = @divFloor(offset_ns, std.time.ns_per_s);
    const nanoseconds = @mod(offset_ns, std.time.ns_per_s);
    return std.fmt.bufPrint(buffer, "realtime {d} {d}\n", .{ seconds, nanoseconds }) catch unreachable;
}

test realtime_offset_line {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("realtime 0 0\n", realtime_offset_line(&buffer, 0));
    try std.testing.expectEqualStrings("realtime 5 0\n", realtime_offset_line(&buffer, 5 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("realtime -2 500000000\n", realtime_offset_line(&buffer, -1_500_000_000));
    try std.testing.expectEqualStrings("realtime -1 999999999\n", realtime_offset_line(&buffer, -1));
    // The largest skews fit.
    _ = realtime_offset_line(&buffer, std.math.minInt(i64));
}

/// The node's processes, in the order its cgroup lists them.
pub fn processes(name: []const u8, pids: []linux.pid_t) !u32 {
    var paths: Paths = undefined;
    try paths.init(name);
    if (!exists(paths.cgroup_procs)) return error.NoCgroup;
    var count: u32 = 0;
    try processes_collect(paths.cgroup, pids, &count, 0);
    return count;
}

/// The threads of a process, in /proc's order (by id), as many as fit.
pub fn threads(pid: linux.pid_t, tids: []linux.pid_t) u32 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task", .{pid}, 0) catch return 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var count: u32 = 0;
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return count;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const tid = std.fmt.parseInt(linux.pid_t, std.mem.span(name), 10) catch continue;
            if (count == tids.len) return count;
            tids[count] = tid;
            count += 1;
        }
    }
}

/// Nodes that run containers (K3s) put their processes in cgroups of their own, under the
/// node's: the whole subtree, depth first.
const cgroup_depth_max = 8;

fn processes_collect(directory: [:0]const u8, pids: []linux.pid_t, count: *u32, depth: u32) !void {
    var path_buffer: [path_size_max]u8 = undefined;
    var text_buffer: [16 * 1024]u8 = undefined;
    const procs = try print_z(&path_buffer, "{s}/cgroup.procs", .{directory});
    if (read_small(procs, &text_buffer)) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (count.* == pids.len) return;
            pids[count.*] = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
            count.* += 1;
        }
    }
    if (depth == cgroup_depth_max) return;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(directory, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            if (entry.type != linux.DT.DIR) continue;
            const name_offset = offset - entry.reclen + @offsetOf(linux.dirent64, "name");
            const child_name: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const child = std.mem.span(child_name);
            if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
            var child_buffer: [path_size_max]u8 = undefined;
            const child_path = try print_z(&child_buffer, "{s}/{s}", .{ directory, child });
            try processes_collect(child_path, pids, count, depth + 1);
        }
    }
}

/// A thaw while a power loss holds the node's crash lock is skipped: the crash thaws the node
/// itself once its processes are gone (crash_lock_path).
pub fn freeze(name: []const u8, state: enum { frozen, thawed }) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    if (state == .frozen) return file_write(paths.cgroup_freeze, "1");
    var crash_lock_buffer: [path_size_max]u8 = undefined;
    return thaw_unless_locked(try crash_lock_path(&crash_lock_buffer, name), paths.cgroup_freeze);
}

/// "0" written to `freeze_path` unless a crash holds `lock_path`; checked and written under the
/// lock, so that no crash freezes between the check and the thaw.
fn thaw_unless_locked(lock_path: [:0]const u8, freeze_path: [:0]const u8) !void {
    const lock = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock) != .SUCCESS) return error.LockOpenFailed;
    defer _ = linux.close(@intCast(lock));
    while (true) {
        switch (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN => return, // A crash's.
            else => return error.LockFailed,
        }
    }
    try file_write(freeze_path, "0");
}

test thaw_unless_locked {
    var lock_buffer: [path_size_max]u8 = undefined;
    var freeze_buffer: [path_size_max]u8 = undefined;
    const pid = linux.getpid();
    const lock_path = try print_z(&lock_buffer, "/tmp/det-thaw-test-{d}.crash", .{pid});
    const freeze_path = try print_z(&freeze_buffer, "/tmp/det-thaw-test-{d}.freeze", .{pid});
    defer _ = linux.unlink(lock_path);
    defer _ = linux.unlink(freeze_path);
    var buffer: [8]u8 = undefined;
    try file_write(freeze_path, "1");
    // A crash holds the lock (its own open file, as another process's): the thaw is skipped.
    const held = try lock_take(lock_path);
    try thaw_unless_locked(lock_path, freeze_path);
    try std.testing.expectEqualStrings("1", read_small(freeze_path, &buffer).?);
    // The crash over: thawed.
    _ = linux.close(held);
    try thaw_unless_locked(lock_path, freeze_path);
    try std.testing.expectEqualStrings("0", read_small(freeze_path, &buffer).?);
}

/// What a fault may have left on a node once faults stop, or "" for nothing: its cgroup frozen,
/// a thread stopped (SIGSTOP), its disk dropping writes. A fault's effect outliving it made two
/// false findings (srv3, 2026-10-28: a node cut from its own address, a disk left dropping
/// writes); faults.zig checks every node at the stop.
pub fn leftover(name: []const u8) []const u8 {
    // Under the start lock: a power loss still in progress (asked by a driver the composer had
    // just killed, the runner carrying on) holds the node frozen and its disk dropping writes
    // until it ends, and was taken for a fault's leftover (local-fs's run 742, timeline 164:
    // "its cgroup frozen" at the stop, the crash's kill reported 4 ms later).
    const lock = start_lock(name) catch null;
    defer if (lock) |held| start_unlock(held);
    if (state_of(name) == .paused) return "its cgroup frozen";
    var paths: Paths = undefined;
    paths.init(name) catch return "";
    if (exists(paths.dropping)) return "its disk dropping writes";
    if (clock_skewed(name)) return "its clock skewed";
    var pids: [1024]linux.pid_t = undefined;
    const count = processes(name, &pids) catch return "";
    for (pids[0..count]) |pid| {
        var tids: [1024]linux.pid_t = undefined;
        for (tids[0..threads(pid, &tids)]) |tid| {
            if (thread_stopped(pid, tid)) return "a thread stopped";
        }
    }
    return "";
}

/// Whether the node's realtime clock is offset (its time namespace's "realtime" line).
fn clock_skewed(name: []const u8) bool {
    const pid = pid_read(name) orelse return false;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/timens_offsets", .{pid}, 0) catch return false;
    var buffer: [256]u8 = undefined;
    const text = read_small(path, &buffer) orelse return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next() orelse continue, "realtime")) continue;
        const seconds = fields.next() orelse return false;
        const nanoseconds = fields.next() orelse return false;
        return !std.mem.eql(u8, seconds, "0") or !std.mem.eql(u8, nanoseconds, "0");
    }
    return false;
}

/// Whether a thread is stopped by a signal ('T' in its stat, after the command's parenthesis).
fn thread_stopped(pid: linux.pid_t, tid: linux.pid_t) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task/{d}/stat", .{ pid, tid }, 0) catch return false;
    var buffer: [512]u8 = undefined;
    const text = read_small(path, &buffer) orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    return close + 2 < text.len and text[close + 2] == 'T';
}

pub const State = enum { running, paused, stopped };

/// Whether the node runs, is frozen, or has no live main process.
/// Each node's resources over time (init runs it): every `sample_period_ns` of virtual time, the
/// CPU its cgroup used meanwhile and the memory it holds, a `node_sample` event, for studies of
/// what a system's resources say before it fails (a stuck cluster goes quiet: run 230's failing
/// timelines ended with far less CPU and output than the others).
pub fn samples_loop(system: *const schema.System) noreturn {
    var used_usec: [schema.nodes_max]?u64 = @splat(null);
    var anon_least: [schema.nodes_max]?u64 = @splat(null);
    var oom_kills: [schema.nodes_max]u64 = @splat(0);
    var room_was = true;
    while (true) {
        sleep_ns(sample_period_ns);
        const room = disks_room();
        if (room_was and !room.left) sdk.assert_computed(.always, false, disks_room_property, .{ .run_mib = room.total_mib });
        room_was = room.left;
        for (system.nodes, 0..) |node, index| {
            var path_buffer: [path_size_max]u8 = undefined;
            var buffer: [1024]u8 = undefined;
            const cpu_path = print_z(&path_buffer, cgroup_root ++ "/{s}/cpu.stat", .{node.name}) catch continue;
            const usage = stat_field(read_small(cpu_path, &buffer) orelse continue, "usage_usec") orelse continue;
            const before = used_usec[index];
            used_usec[index] = usage;
            const memory_path = print_z(&path_buffer, cgroup_root ++ "/{s}/memory.current", .{node.name}) catch continue;
            const memory_text = std.mem.trim(u8, read_small(memory_path, &buffer) orelse continue, " \n");
            const memory = std.fmt.parseInt(u64, memory_text, 10) catch continue;
            // An OOM kill in the node (its cgroup's count, whatever killer: the guest's or its
            // limit's), judged now: the kernel's log was read only at the timeline's end, so a
            // kill's failure came minutes after it (the tree's returns and causality looked
            // there). The end judges it again with the kernel's report.
            const events_path = print_z(&path_buffer, cgroup_root ++ "/{s}/memory.events", .{node.name}) catch continue;
            var events_buffer: [1024]u8 = undefined;
            if (read_small(events_path, &events_buffer)) |events_text| {
                const kills = stat_field(events_text, "oom_kill") orelse 0;
                if (kills > oom_kills[index]) sdk.assert_computed(.always, false, crash_names.oom_property, .{
                    .node = node.name,
                    .oom_kills = kills,
                    .memory_mib = memory >> 20,
                });
                oom_kills[index] = kills;
            }
            sdk.event("node_sample", .{
                .node = node.name,
                .cpu_ms = if (before) |used| (usage -| used) / std.time.us_per_ms else null,
                .memory_mib = memory >> 20,
            });
            // Its anonymous memory (heaps, JIT code: not the page cache a node's writes grow)
            // above its least so far, an objective the tree climbs: a leak too slow to reach the
            // OOM killer within a timeline grows in the timelines built on the leakiest (jank
            // kept 0.1 to 0.65 MiB an evaluation, found only where a 2 GB guest ran out: hunt
            // run 1569). No property: caches and heaps grow by design.
            const stat_path = print_z(&path_buffer, cgroup_root ++ "/{s}/memory.stat", .{node.name}) catch continue;
            var stat_buffer: [8192]u8 = undefined;
            const anon = stat_field(read_small(stat_path, &stat_buffer) orelse continue, "anon") orelse continue;
            const least = @min(anon_least[index] orelse anon, anon);
            anon_least[index] = least;
            sdk.optimize_computed(memory_growth_objective, node.name, @floatFromInt((anon - least) >> 20), .maximize);
        }
    }
}

const sample_period_ns = 2 * std.time.ns_per_s;
/// The nodes' memory growth, by node (samples_loop): MiB of anonymous memory above its least.
/// The same message as the host's (src/events.zig memory_growth_objective), which turns it off
/// for comparisons (explore --no-memory-objective).
const memory_growth_objective = "a node's anonymous memory grows (MiB above its least)";

/// determinismo's own: the nodes' disks (their images, sparse, and logs in the guest's /run, a
/// tmpfs of half its memory) fit in it. Past it every node's disk fails its writes with EIO, a
/// disk fault the profile never asked for, and starts fail (ZooKeeper's set, run 711 timeline
/// 45: its set's znode logged whole at each add, 504 MB of logs a node by 540 s, /run full, no
/// server started again; Scylla's commit logs, runs 603 and 615).
const disks_room_property = "the nodes' disks fit in the guest's memory";

fn disks_room() struct { left: bool, total_mib: u64 } {
    var stat: Statfs = undefined;
    if (linux.errno(linux.syscall2(.statfs, @intFromPtr(state_root), @intFromPtr(&stat))) != .SUCCESS) {
        return .{ .left = true, .total_mib = 0 };
    }
    const block: u64 = @intCast(stat.bsize);
    return .{ .left = stat.bavail * block >= 1 << 20, .total_mib = stat.blocks * block >> 20 };
}

/// A `name value` line's value in a cgroup stat file.
pub fn stat_field(text: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, words.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u64, words.next() orelse return null, 10) catch null;
    }
    return null;
}

test stat_field {
    const text = "usage_usec 1500\nuser_usec 1000\nsystem_usec 500\n";
    try std.testing.expectEqual(@as(?u64, 500), stat_field(text, "system_usec"));
    try std.testing.expectEqual(@as(?u64, null), stat_field(text, "nr_periods"));
}

/// A drawn host's flusher, for nodes that declare a writeback window (schema.Node.writeback_s):
/// a workaround for systems a strict disk bricks in every timeline, never a cover for them. Each
/// such node's flusher is on or off, drawn as the guest starts (again as the timelines part,
/// each its own) and switched at the end of a
/// window one time in `writeback_switch_one_in` (stretches of four windows on average). On, its
/// disk is synced (syncfs) at each window's end: a power loss drops the last window's writes.
/// Off, nothing is written back, as on a strict disk (a drive's volatile cache: the kernel's
/// writeback never flushes it): a power loss drops every write since the last flush, however
/// old, and the bug shows. Its state, "on <flushes>" or "off <flushes>", is the node's
/// `writeback` file; each switch a `writeback` event. Runs as long as the guest (det-nodes
/// writeback, from init); a node down (its disk unmounted) is not synced.
pub fn writeback_loop(system: *const schema.System) noreturn {
    var last_s: [schema.nodes_max]u64 = @splat(0);
    var on: [schema.nodes_max]bool = @splat(false);
    var flushes: [schema.nodes_max]u64 = @splat(0);
    // Each node's state file, once its directory is there (the loop starts before the nodes).
    var stated: [schema.nodes_max]bool = @splat(false);
    for (system.nodes, 0..) |node, index| {
        if (node.writeback_s == null) continue;
        on[index] = sdk.random_below_named("writeback.on", 2) == 0;
        sdk.event("writeback", .{ .node = node.name, .flusher = if (on[index]) "on" else "off", .flushes = 0 });
    }
    var now_s: u64 = 0;
    // Drawn again once the timelines part: the first draw, before the snapshot, was every
    // timeline's (all 8 of the selftest's had the flusher on, its off state never reached).
    var parted = false;
    while (true) {
        sleep_ns(std.time.ns_per_s);
        now_s += 1;
        const parting = !parted and exists(parted_path);
        if (parting) parted = true;
        for (system.nodes, 0..) |node, index| {
            const window_s = node.writeback_s orelse continue;
            if (parting) {
                on[index] = sdk.random_below_named("writeback.on", 2) == 0;
                stated[index] = writeback_state(node.name, on[index], flushes[index], true);
            }
            if (!stated[index]) stated[index] = writeback_state(node.name, on[index], flushes[index], false);
            if (now_s - last_s[index] < window_s) continue;
            last_s[index] = now_s;
            if (on[index] and writeback(node.name)) flushes[index] += 1;
            const switched = sdk.random_below_named("writeback.switch", writeback_switch_one_in) == 0;
            if (switched) on[index] = !on[index];
            stated[index] = writeback_state(node.name, on[index], flushes[index], switched);
        }
    }
}

const writeback_switch_one_in = 4;

/// The flusher's state in the node's `writeback` file (tests read it), and an event when it
/// switched. Whether the file was written.
fn writeback_state(name: []const u8, on: bool, flushes: u64, switched: bool) bool {
    if (switched) sdk.event("writeback", .{ .node = name, .flusher = if (on) "on" else "off", .flushes = flushes });
    var path_buffer: [path_size_max]u8 = undefined;
    var text_buffer: [32]u8 = undefined;
    const path = print_z(&path_buffer, state_root ++ "/{s}/writeback", .{name}) catch return false;
    const text = std.fmt.bufPrint(&text_buffer, "{s} {d}\n", .{ if (on) "on" else "off", flushes }) catch return false;
    file_write(path, text) catch return false;
    return true;
}

/// Whether the node's disk was synced (not when it is down).
fn writeback(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return false;
    if (!exists(paths.mounted)) return false;
    const fd = linux.open(paths.layer, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    return linux.errno(linux.syscall1(.syncfs, @as(usize, @intCast(fd)))) == .SUCCESS;
}

/// Whether every process of the node is gone (its cgroup empty): a stop's SIGTERM unlinks the
/// pidfile first, so `state_of` says stopped before the node finished stopping.
pub fn exited(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return true;
    return !(cgroup_populated(&paths) catch return true);
}

pub fn state_of(name: []const u8) State {
    if (pid_read(name) == null) return .stopped;
    var paths: Paths = undefined;
    paths.init(name) catch return .stopped;
    var buffer: [8]u8 = undefined;
    const frozen = read_small(paths.cgroup_freeze, &buffer) orelse "0";
    return if (std.mem.startsWith(u8, frozen, "1")) .paused else .running;
}

/// The link between `a` and `b` (either may be the runner) goes up or down on both ends.
pub fn link_set(
    system: *const schema.System,
    a: []const u8,
    b: []const u8,
    state: LinkState,
) !void {
    assert(!std.mem.eql(u8, a, b));
    const pid_a = pid_of(a) orelse return; // Not running: no link to change.
    const pid_b = pid_of(b) orelse return;
    const address_a = try endpoint_address(system, a);
    const address_b = try endpoint_address(system, b);
    var name_a: [netlink.interface_name_size_max]u8 = undefined;
    var name_b: [netlink.interface_name_size_max]u8 = undefined;
    const interface_a = interface_name(&name_a, b);
    const interface_b = interface_name(&name_b, a);
    try netlink.in_namespace_of(pid_a, link_change, .{ interface_a, address_b, state });
    try netlink.in_namespace_of(pid_b, link_change, .{ interface_b, address_a, state });
}

/// Linux drops a link's routes when it goes down: bringing it up restores the host route.
fn link_change(
    socket: *netlink.Socket,
    interface: []const u8,
    peer: netlink.Address,
    state: LinkState,
) !void {
    try socket.link_set(interface, state);
    if (state == .down) return;
    socket.route_add(interface, peer) catch |err| switch (err) {
        error.Exists => {},
        else => return err,
    };
    // A node's link to the runner also carries its default route.
    if (!std.mem.eql(u8, &peer, &schema.runner_address)) return;
    socket.route_default(interface, peer) catch |err| switch (err) {
        error.Exists => {},
        else => return err,
    };
}

fn endpoint_address(system: *const schema.System, name: []const u8) !netlink.Address {
    if (std.mem.eql(u8, name, schema.runner_name)) return schema.runner_address;
    const node = system.node(name) orelse return error.UnknownNode;
    return address_now(node);
}

/// A node's address now: the system's, or the one a restart gave it (readdress).
pub fn address_now(node: *const schema.Resolved) !netlink.Address {
    var paths: Paths = undefined;
    try paths.init(node.name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/address", .{paths.directory});
    var buffer: [32]u8 = undefined;
    if (read_small(path, &buffer)) |text| return address_parse(std.mem.trim(u8, text, " \n"));
    return address_parse(node.address);
}

/// The node, stopped, rejoins with a new address when it starts again (Faults.new_address):
/// 10.<n>.0.<x> for its n-th one (x as in its first, so no two nodes share one), and every
/// hosts file (the runner's, each node's) names it there.
pub fn readdress(system: *const schema.System, node: *const schema.Resolved) !netlink.Address {
    const old = try address_now(node);
    const new = netlink.Address{ 10, if (old[1] >= 254) 1 else old[1] + 1, 0, old[3] };
    var paths: Paths = undefined;
    try paths.init(node.name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/address", .{paths.directory});
    var text_buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "{d}.{d}.{d}.{d}\n", .{
        new[0], new[1], new[2], new[3],
    });
    try file_write(path, text);
    try hosts_write("/etc/hosts", system, null);
    hosts_rewrite(system);
    sdk.event("node_address", .{ .node = node.name, .address = std.mem.trimEnd(u8, text, "\n") });
    return new;
}

/// Degrades the direction `from` → `to` of a link (delay, jitter, loss), or with null restores it.
pub fn link_degrade(from: []const u8, to: []const u8, netem: ?netlink.Netem) !void {
    assert(!std.mem.eql(u8, from, to));
    const pid = pid_of(from) orelse return;
    var name: [netlink.interface_name_size_max]u8 = undefined;
    const interface = interface_name(&name, to);
    if (netem) |settings| {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_set, .{ interface, settings });
    } else {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_clear, .{interface});
    }
}

pub const Netem = netlink.Netem;
pub const NetemRead = netlink.NetemRead;

/// The netem on the direction from `from` to `to` as the kernel has it (null: none, or `from`
/// not running): what faults.zig's leftovers check holds against its own bookkeeping.
pub fn link_netem_read(from: []const u8, to: []const u8) !?NetemRead {
    assert(!std.mem.eql(u8, from, to));
    const pid = pid_of(from) orelse return null;
    var name: [netlink.interface_name_size_max]u8 = undefined;
    const interface = interface_name(&name, to);
    var read: ?NetemRead = null;
    try netlink.in_namespace_of(pid, netem_read_into, .{ interface, &read });
    return read;
}

fn netem_read_into(socket: *netlink.Socket, interface: []const u8, read: *?NetemRead) !void {
    read.* = try socket.netem_get(interface);
}
pub const Address = netlink.Address;

/// A blackhole route to `destination` in a Kubernetes pod's network namespace (one of its
/// processes'): one direction of a partition between two pods (faults.zig's pod_partition).
pub fn pod_blackhole(pid: linux.pid_t, destination: netlink.Address, present: bool) !void {
    try netlink.in_namespace_of(pid, netlink.Socket.blackhole_set, .{ destination, present });
}

/// A Kubernetes pod's network (faults.zig's pod faults): netem on its eth0, in the namespace of
/// one of its processes; null clears it.
pub fn pod_netem(pid: linux.pid_t, netem: ?Netem) !void {
    if (netem) |settings| {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_set, .{ "eth0", settings });
    } else {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_clear, .{"eth0"});
    }
}

/// The PID (in the guest's root namespace) of the node's first process, or 1 for the runner.
pub fn pid_of(name: []const u8) ?linux.pid_t {
    if (std.mem.eql(u8, name, schema.runner_name)) return 1;
    return pid_read(name);
}

/// The node's start time, `started_ms` in its state directory.
fn started_write(directory: []const u8) void {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    const ms = @as(u64, @intCast(now.sec)) * std.time.ms_per_s + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
    var path_buffer: [path_size_max]u8 = undefined;
    const path = print_z(&path_buffer, "{s}/started_ms", .{directory}) catch return;
    var text_buffer: [24]u8 = undefined;
    file_write(path, std.fmt.bufPrint(&text_buffer, "{d}\n", .{ms}) catch return) catch {};
}

/// The main process a graceful stop signalled and det-init has not reaped yet, if one.
pub fn pid_stopping(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var buffer: [32]u8 = undefined;
    const text = read_small(paths.stopping, &buffer) orelse return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
}

/// The stopping process reaped: no longer the node's.
pub fn stopping_clear(name: []const u8) void {
    var paths: Paths = undefined;
    paths.init(name) catch return;
    _ = linux.unlink(paths.stopping);
}

/// The process a graceful stop signalled, while it is still there: the marker's PID, alive and
/// in the node's cgroup (as pid_read: its number come round again is another process).
pub fn stopping(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    return stopping_at(paths.stopping, paths.cgroup);
}

fn stopping_at(marker: [:0]const u8, cgroup: []const u8) ?linux.pid_t {
    var buffer: [32]u8 = undefined;
    const text = read_small(marker, &buffer) orelse return null;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    if (linux.errno(linux.kill(pid, @fromBackingInt(0))) != .SUCCESS) return null;
    if (!pid_in_cgroup(pid, cgroup)) return null;
    return pid;
}

/// How long a start waits for a stopping process: past any stop's grace (3 s: a stop fault's,
/// an upgrade's), whose owner kills it then (stop_end).
const stopping_wait_ns_max = 30 * std.time.ns_per_s;

fn stopping_wait(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    return stopping_wait_at(paths.stopping, paths.cgroup, stopping_wait_ns_max);
}

fn stopping_wait_at(marker: [:0]const u8, cgroup: []const u8, wait_ns_max: u64) !void {
    var waited_ns: u64 = 0;
    while (stopping_at(marker, cgroup) != null) : (waited_ns += poll_interval_ns) {
        if (waited_ns >= wait_ns_max) return error.StillStopping;
        sleep_ns(poll_interval_ns);
    }
}

test "the process a stop signalled is the node's while it lives, and a start waits for its end" {
    var buffer: [path_size_max + 8]u8 = undefined;
    const own = read_small("/proc/self/cgroup", &buffer) orelse return error.SkipZigTest;
    if (!std.mem.startsWith(u8, own, "0::")) return error.SkipZigTest; // cgroup v1.
    var cgroup_buffer: [path_size_max]u8 = undefined;
    const cgroup = try std.fmt.bufPrint(&cgroup_buffer, "/sys/fs/cgroup{s}", .{std.mem.trimEnd(u8, own["0::".len..], "\n")});
    var marker_buffer: [path_size_max]u8 = undefined;
    const marker = try print_z(&marker_buffer, "/tmp/det-stopping-test-{d}", .{linux.getpid()});
    defer _ = linux.unlink(marker);
    // No marker: nothing stopping.
    try std.testing.expectEqual(@as(?linux.pid_t, null), stopping_at(marker, cgroup));
    // A stopping process that ends 300 ms from now, not this test's child (reaped by whoever
    // adopts it, as det-init reaps a node's): its pid through a pipe.
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    const forked = linux.fork();
    try std.testing.expect(linux.errno(forked) == .SUCCESS);
    if (forked == 0) {
        const again = linux.fork();
        if (again == 0) {
            _ = linux.close(pipe[1]);
            sleep_ns(300 * std.time.ns_per_ms);
            linux.exit_group(0);
        }
        const pid: linux.pid_t = @intCast(again);
        _ = linux.write(pipe[1], std.mem.asBytes(&pid), @sizeOf(linux.pid_t));
        linux.exit_group(0);
    }
    _ = linux.close(pipe[1]);
    var stopping_pid: linux.pid_t = 0;
    try std.testing.expect(linux.read(pipe[0], std.mem.asBytes(&stopping_pid), @sizeOf(linux.pid_t)) == @sizeOf(linux.pid_t));
    _ = linux.close(pipe[0]);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(forked), &status, 0);
    var text_buffer: [16]u8 = undefined;
    try file_write(marker, try std.fmt.bufPrint(&text_buffer, "{d}\n", .{stopping_pid}));
    try std.testing.expectEqual(@as(?linux.pid_t, stopping_pid), stopping_at(marker, cgroup));
    // In another cgroup, the number is another process's: not the node's.
    try std.testing.expectEqual(@as(?linux.pid_t, null), stopping_at(marker, cgroup_root ++ "/v3"));
    // A wait shorter than its end gives up, saying so; a start's waits it out.
    try std.testing.expectError(error.StillStopping, stopping_wait_at(marker, cgroup, 50 * std.time.ns_per_ms));
    try stopping_wait_at(marker, cgroup, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(?linux.pid_t, null), stopping_at(marker, cgroup));
}

/// A graceful stop's grace is over (or its fault ends): the process it signalled, if still
/// there, is killed, its PID namespace with it (it is its first process), and nothing else of
/// the node. `kill_remaining` killed the node's whole cgroup, a new incarnation with it when a
/// driver had started the node again meanwhile: a kill of a running node the faults drawn never
/// asked for.
pub fn stop_end(name: []const u8) !void {
    const pid = stopping(name) orelse return;
    // A pidfd holds that very process (as stop_signal's).
    const pidfd = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(pidfd));
    if (stopping(name) != pid) return;
    _ = linux.pidfd_send_signal(@intCast(pidfd), .KILL, null, 0);
    for (0..stop_attempts_max) |_| {
        if (stopping(name) != pid) return;
        sleep_ns(poll_interval_ns);
    }
    return error.NodeDidNotStop;
}

/// The PID the node's pidfile names, alive or not.
pub fn pid_recorded(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var buffer: [32]u8 = undefined;
    const text = read_small(paths.pid, &buffer) orelse return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
}

/// The node's main process: the pidfile's PID, alive and in the node's cgroup. Alive alone is not
/// enough: once the process the pidfile names exited (a crash of the node's own) its number comes
/// round again, and a graceful stop of the node then signalled whatever process had it (Valkey's
/// run 1554, timeline 62: v3 down, a stop's SIGTERM ended a `migrate` driver, exit 143).
pub fn pid_read(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var buffer: [32]u8 = undefined;
    const text = read_small(paths.pid, &buffer) orelse return null;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    if (linux.errno(linux.kill(pid, @fromBackingInt(0))) != .SUCCESS) return null;
    if (!pid_in_cgroup(pid, paths.cgroup)) return null;
    return pid;
}

/// Whether process `pid` is in cgroup `cgroup` (a path under /sys/fs/cgroup) or one under it, as
/// its /proc/<pid>/cgroup says (cgroup v2's one line, `0::<path>`, from our cgroup namespace).
fn pid_in_cgroup(pid: linux.pid_t, cgroup: []const u8) bool {
    var path_buffer: [48]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cgroup", .{pid}, 0) catch return false;
    var buffer: [path_size_max + 8]u8 = undefined;
    const text = read_small(path, &buffer) orelse return false;
    return cgroup_line_within(text, cgroup);
}

fn cgroup_line_within(text: []const u8, cgroup: []const u8) bool {
    const hierarchy = "/sys/fs/cgroup";
    if (!std.mem.startsWith(u8, cgroup, hierarchy)) return false;
    const want = cgroup[hierarchy.len..];
    if (!std.mem.startsWith(u8, text, "0::")) return false;
    const own = std.mem.trimEnd(u8, text["0::".len..], "\n");
    if (!std.mem.startsWith(u8, own, want)) return false;
    return own.len == want.len or own[want.len] == '/';
}

test cgroup_line_within {
    try std.testing.expect(cgroup_line_within("0::/nodes/v3\n", cgroup_root ++ "/v3"));
    try std.testing.expect(cgroup_line_within("0::/nodes/v3/inner\n", cgroup_root ++ "/v3"));
    // Another node's (a name it prefixes), the runner's, or none.
    try std.testing.expect(!cgroup_line_within("0::/nodes/v30\n", cgroup_root ++ "/v3"));
    try std.testing.expect(!cgroup_line_within("0::/\n", cgroup_root ++ "/v3"));
    try std.testing.expect(!cgroup_line_within("", cgroup_root ++ "/v3"));
}

test pid_in_cgroup {
    // This process is in its own cgroup and not in a node's.
    var buffer: [path_size_max + 8]u8 = undefined;
    const own = read_small("/proc/self/cgroup", &buffer) orelse return error.SkipZigTest;
    if (!std.mem.startsWith(u8, own, "0::")) return error.SkipZigTest; // cgroup v1.
    var cgroup_buffer: [path_size_max]u8 = undefined;
    const cgroup = try std.fmt.bufPrint(&cgroup_buffer, "/sys/fs/cgroup{s}", .{std.mem.trimEnd(u8, own["0::".len..], "\n")});
    try std.testing.expect(pid_in_cgroup(linux.getpid(), cgroup));
    try std.testing.expect(!pid_in_cgroup(linux.getpid(), cgroup_root ++ "/v3"));
}

/// A file's size, 0 when it is not there.
fn file_size(path: [:0]const u8) u64 {
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true }, &stat);
    return if (linux.errno(result) == .SUCCESS) stat.size else 0;
}

const Paths = struct {
    buffers: [19][path_size_max]u8 = undefined,
    directory: [:0]const u8 = "",
    lower: [:0]const u8 = "",
    /// The writable layer's mount (upper and work are in it), its disk image and loop device
    /// (crash faults), and a mark that layer and root are mounted.
    layer: [:0]const u8 = "",
    image: [:0]const u8 = "",
    loop: [:0]const u8 = "",
    mounted: [:0]const u8 = "",
    /// Present while a crash has the disk dropping writes (crash_with).
    dropping: [:0]const u8 = "",
    /// The layer's files as a power loss found them, until the next mount reports what it
    /// changed (crash_files_report).
    crash_files: [:0]const u8 = "",
    upper: [:0]const u8 = "",
    work: [:0]const u8 = "",
    root: [:0]const u8 = "",
    pid: [:0]const u8 = "",
    /// The main process a graceful stop signalled, until det-init reaps it (stop_signal).
    stopping: [:0]const u8 = "",
    output: [:0]const u8 = "",
    /// The offset in `output` where the running start's output begins.
    output_start: [:0]const u8 = "",
    /// Present while the node runs on its next release (schema.Resolved.upgrade).
    variant: [:0]const u8 = "",
    /// How many times the node was wiped (a decimal number; absent: never), for its starts.
    wipes: [:0]const u8 = "",
    /// The CPU count its running start drew (schema.Node.cpus; absent: none drawn), for the
    /// commands run in it: a machine's CPUs, the same for every process in the node.
    cpus: [:0]const u8 = "",
    cgroup: [:0]const u8 = "",
    cgroup_procs: [:0]const u8 = "",
    cgroup_kill: [:0]const u8 = "",
    cgroup_freeze: [:0]const u8 = "",
    cgroup_events: [:0]const u8 = "",
    cgroup_buffers: [5][path_size_max]u8 = undefined,

    /// In place: the paths point into the struct's own buffers.
    fn init(paths: *Paths, name: []const u8) !void {
        if (!schema.name_valid(name)) return error.BadNodeName;
        paths.* = .{};
        const b = &paths.buffers;
        paths.directory = try print_z(&b[0], state_root ++ "/{s}", .{name});
        paths.lower = try print_z(&b[1], state_root ++ "/{s}/lower", .{name});
        paths.upper = try print_z(&b[2], state_root ++ "/{s}/layer/upper", .{name});
        paths.work = try print_z(&b[3], state_root ++ "/{s}/layer/work", .{name});
        paths.layer = try print_z(&b[8], state_root ++ "/{s}/layer", .{name});
        paths.image = try print_z(&b[9], state_root ++ "/{s}/disk.img", .{name});
        paths.loop = try print_z(&b[10], state_root ++ "/{s}/loop", .{name});
        paths.mounted = try print_z(&b[11], state_root ++ "/{s}/mounted", .{name});
        paths.dropping = try print_z(&b[12], state_root ++ "/{s}/disk-dropping", .{name});
        paths.crash_files = try print_z(&b[14], state_root ++ "/{s}/crash-files", .{name});
        paths.root = try print_z(&b[4], state_root ++ "/{s}/root", .{name});
        paths.pid = try print_z(&b[5], state_root ++ "/{s}/pid", .{name});
        paths.output = try print_z(&b[6], state_root ++ "/{s}/output.log", .{name});
        paths.output_start = try print_z(&b[13], state_root ++ "/{s}/output.start", .{name});
        paths.variant = try print_z(&b[15], state_root ++ "/{s}/variant-next", .{name});
        paths.stopping = try print_z(&b[16], state_root ++ "/{s}/pid-stopping", .{name});
        paths.wipes = try print_z(&b[17], state_root ++ "/{s}/wipes", .{name});
        paths.cpus = try print_z(&b[18], state_root ++ "/{s}/cpus", .{name});
        paths.cgroup = try print_z(&b[7], cgroup_root ++ "/{s}", .{name});
        const c = &paths.cgroup_buffers;
        paths.cgroup_procs = try print_z(&c[0], "{s}/cgroup.procs", .{paths.cgroup});
        paths.cgroup_kill = try print_z(&c[1], "{s}/cgroup.kill", .{paths.cgroup});
        paths.cgroup_freeze = try print_z(&c[2], "{s}/cgroup.freeze", .{paths.cgroup});
        paths.cgroup_events = try print_z(&c[3], "{s}/cgroup.events", .{paths.cgroup});
    }
};

/// Mounts the node's disk and overlay once, and (re)writes its network identity files.
fn root_prepare(
    paths: *const Paths,
    system: *const schema.System,
    node: *const schema.Resolved,
) !void {
    if (!exists(paths.root)) {
        try mkdir_all(paths.directory);
        for ([_][:0]const u8{ paths.lower, paths.layer, paths.root }) |path| try mkdir_all(path);
        var device_buffer: [32]u8 = undefined;
        const device = try print_z(&device_buffer, "/dev/{s}", .{node.disk});
        try mount(device, paths.lower, "erofs", linux.MS.RDONLY, null);
    }
    // A layer whose filesystem gave up is mounted afresh (its journal replays), as a machine
    // rebooted after the fault would; once, and again after a crash or a wipe unmounted them.
    // The reserve first: a full disk is not one that gave up.
    if (exists(paths.mounted)) reserve_release(paths);
    if (exists(paths.mounted) and !layer_writable(paths)) {
        sdk.event("node_layer_remount", .{ .node = node.name });
        try layer_unmount(paths);
    }
    if (!exists(paths.mounted)) {
        try layer_mount(paths, node);
        reserve_release(paths);
        for ([_][:0]const u8{ paths.upper, paths.work }) |path| try mkdir_all(path);
        crash_files_report(paths, node.name);
        var options_buffer: [3 * path_size_max]u8 = undefined;
        const options = try print_z(&options_buffer, "lowerdir={s},upperdir={s},workdir={s}", .{
            paths.lower, paths.upper, paths.work,
        });
        try mount("overlay", paths.root, "overlay", 0, options);
        try file_write(paths.mounted, "");
    }
    try mkdir_all(paths.cgroup);
    var path_buffer: [path_size_max]u8 = undefined;
    try mkdir_all(try print_z(&path_buffer, "{s}/etc", .{paths.root}));
    try hosts_write(try print_z(&path_buffer, "{s}/etc/hosts", .{paths.root}), system, node.name);
    const resolv = try print_z(&path_buffer, "{s}/etc/resolv.conf", .{paths.root});
    _ = linux.unlink(resolv); // Often a symlink in images; ours is a plain file.
    try file_write(resolv, "# determinismo: names are in /etc/hosts\n");
    const hostname = try print_z(&path_buffer, "{s}/etc/hostname", .{paths.root});
    _ = linux.unlink(hostname);
    var line_buffer: [schema.alias_size_max + 1]u8 = undefined;
    try file_write(hostname, try std.fmt.bufPrint(&line_buffer, "{s}\n", .{node.hostname orelse node.name}));
    reserve_take(paths);
}

/// Inodes and blocks of a node's disk kept from it, outside its view (beside the overlay's upper
/// directory), for what a start needs: the overlay makes its work directory again at each mount,
/// and the identity files are written anew. A node that filled its disk never started again,
/// the overlay's mount refused with ENOSPC (ClickHouse, run 1279 timeline 2: "a faulted node
/// starts again" failed, determinismo's own doing), where a machine whose disk is full boots and
/// its programs meet the full disk. Released before a start's mounts and writes, taken again
/// after, as much as is left (the node's processes are not running then).
const reserve_inodes = 64;
const reserve_bytes = 1 << 20;

fn reserve_release(paths: *const Paths) void {
    var path_buffer: [path_size_max]u8 = undefined;
    for (0..reserve_inodes) |index| {
        const path = print_z(&path_buffer, "{s}/reserve/{d}", .{ paths.layer, index }) catch return;
        _ = linux.unlink(path);
    }
}

/// Unsynced: a later sync of the node's (ext4 commits its metadata in one journal) makes it
/// durable, and a power loss before any loses the node's own writes too.
fn reserve_take(paths: *const Paths) void {
    if (paths.image.len == 0 or !exists(paths.image)) return; // A tmpfs layer: nothing to keep.
    var path_buffer: [path_size_max]u8 = undefined;
    mkdir_all(print_z(&path_buffer, "{s}/reserve", .{paths.layer}) catch return) catch return;
    for (0..reserve_inodes) |index| {
        const path = print_z(&path_buffer, "{s}/reserve/{d}", .{ paths.layer, index }) catch return;
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
        const fd = linux.open(path, flags, 0o600);
        if (linux.errno(fd) != .SUCCESS) return;
        defer _ = linux.close(@intCast(fd));
        // The blocks in the first (allocated, not written: the disk's image is the guest's
        // memory).
        if (index == 0) _ = linux.fallocate(@intCast(fd), 0, 0, reserve_bytes);
    }
}

/// Every node's hosts file written again (an address changed, a name left out or back). A node
/// going down meanwhile (its disk cut by a crash) refuses the write: it gets the hosts as they are
/// when it starts again (root_prepare). The others must still learn the change, or they would
/// lose the node for good.
fn hosts_rewrite(system: *const schema.System) void {
    for (system.nodes) |*other| {
        var other_paths: Paths = undefined;
        other_paths.init(other.name) catch continue;
        var hosts_buffer: [path_size_max]u8 = undefined;
        const hosts = print_z(&hosts_buffer, "{s}/etc/hosts", .{other_paths.root}) catch continue;
        if (exists(hosts)) hosts_write(hosts, system, other.name) catch {};
    }
}

/// The node's name left out of the other nodes' hosts files until it starts again
/// (Faults.names_follow_liveness): a marker in its state directory, every hosts file rewritten.
pub fn unlist(system: *const schema.System, node: *const schema.Resolved) !void {
    var paths: Paths = undefined;
    try paths.init(node.name);
    var path_buffer: [path_size_max]u8 = undefined;
    try file_write(try print_z(&path_buffer, "{s}/unlisted", .{paths.directory}), "");
    hosts_rewrite(system);
    sdk.event("node_unlisted", .{ .node = node.name });
}

/// The node's name back in every hosts file, if it was left out (it started).
fn relist(system: *const schema.System, node: *const schema.Resolved) void {
    var paths: Paths = undefined;
    paths.init(node.name) catch return;
    var path_buffer: [path_size_max]u8 = undefined;
    const marker = print_z(&path_buffer, "{s}/unlisted", .{paths.directory}) catch return;
    if (!exists(marker)) return;
    _ = linux.unlink(marker);
    hosts_rewrite(system);
    sdk.event("node_listed", .{ .node = node.name });
}

fn unlisted(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return false;
    var path_buffer: [path_size_max]u8 = undefined;
    return exists(print_z(&path_buffer, "{s}/unlisted", .{paths.directory}) catch return false);
}

/// The hosts file `viewer` sees (null: the runner's, every name): the nodes left out are
/// missing from the others' (`unlist`), never from their own.
fn hosts_write(path: [:0]const u8, system: *const schema.System, viewer: ?[]const u8) !void {
    // Each node's line with its aliases (schema.Node.aliases): 16 nodes of 8 aliases fit.
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("127.0.0.1 localhost\n");
    const runner = schema.runner_address;
    try writer.print("{d}.{d}.{d}.{d} {s}\n", .{
        runner[0], runner[1], runner[2], runner[3], schema.runner_name,
    });
    for (system.nodes) |*node| {
        if (viewer) |name| {
            if (!std.mem.eql(u8, name, node.name) and unlisted(node.name)) continue;
        }
        const address = try address_now(node);
        try writer.print("{d}.{d}.{d}.{d} {s}", .{
            address[0], address[1], address[2], address[3], node.name,
        });
        for (node.aliases) |alias| try writer.print(" {s}", .{alias});
        try writer.writeAll("\n");
    }
    _ = linux.unlink(path);
    try file_write(path, writer.buffered());
}

fn cgroup_join(paths: *const Paths, pid: linux.pid_t) !void {
    var buffer: [32]u8 = undefined;
    try file_write(paths.cgroup_procs, try std.fmt.bufPrint(&buffer, "{d}\n", .{pid}));
}

/// Moves the calling process into the node's cgroup or, when the node delegates controllers to
/// cgroups of its own (a container runtime in the node), into a leaf under it: cgroup v2 keeps
/// processes out of cgroups that have controllers enabled for their children.
fn cgroup_join_self(paths: *const Paths) !void {
    const enabled = blk: {
        var buffer: [256]u8 = undefined;
        var path_buffer: [path_size_max]u8 = undefined;
        const control = try print_z(&path_buffer, "{s}/cgroup.subtree_control", .{paths.cgroup});
        const text = read_small(control, &buffer) orelse break :blk false;
        break :blk std.mem.trim(u8, text, " \n").len > 0;
    };
    if (!enabled) return file_write(paths.cgroup_procs, "0");
    var leaf_buffer: [path_size_max]u8 = undefined;
    const leaf = try print_z(&leaf_buffer, "{s}/det-exec", .{paths.cgroup});
    try mkdir_all(leaf);
    var procs_buffer: [path_size_max]u8 = undefined;
    try file_write(try print_z(&procs_buffer, "{s}/cgroup.procs", .{leaf}), "0");
}

fn memory_limit(paths: *const Paths, memory_max_mib: ?u32) !void {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/memory.max", .{paths.cgroup});
    var value_buffer: [32]u8 = undefined;
    const value = if (memory_max_mib) |mib|
        try std.fmt.bufPrint(&value_buffer, "{d}\n", .{@as(u64, mib) * 1024 * 1024})
    else
        "max\n";
    try file_write(path, value);
}

/// Until every process of the node is frozen (one inside a system call stops when it returns),
/// a second at most.
fn cgroup_frozen_wait(paths: *const Paths) !void {
    for (0..freeze_attempts_max) |_| {
        var buffer: [256]u8 = undefined;
        const events = read_small(paths.cgroup_events, &buffer) orelse return error.NoCgroup;
        if (std.mem.indexOf(u8, events, "frozen 1") != null) return;
        sleep_ns(poll_interval_ns);
    }
    return error.NodeDidNotFreeze;
}

fn cgroup_populated(paths: *const Paths) !bool {
    var buffer: [256]u8 = undefined;
    const events = read_small(paths.cgroup_events, &buffer) orelse return error.NoCgroup;
    return std.mem.indexOf(u8, events, "populated 1") != null;
}

/// Links the new node to the runner and to every running node.
fn network_connect(
    system: *const schema.System,
    node: *const schema.Resolved,
    pid: linux.pid_t,
) !void {
    try netlink.in_namespace_of(pid, netlink.Socket.link_set, .{ "lo", .up });
    const address = try address_now(node);
    // Its own address on lo too, first: the kernel reaches a local address through the route of
    // the interface that holds it, and with it on its links alone, an isolated node (every link
    // down) could not reach itself. A cut cable never does that: Kafka's transaction
    // coordinator, isolated, failed to send its commit markers to its own broker for minutes.
    try netlink.in_namespace_of(pid, netlink.Socket.address_add, .{ "lo", address });
    const self = Endpoint{ .name = node.name, .address = address, .pid = pid };
    try link_create(self, .{
        .name = schema.runner_name,
        .address = schema.runner_address,
        .pid = 1,
    });
    // A default route through the runner, as containers have one: some software (K3s, etcd)
    // looks for it to choose its address. Nothing lies beyond the runner.
    var name: [netlink.interface_name_size_max]u8 = undefined;
    const runner_interface = interface_name(&name, schema.runner_name);
    const route_default = netlink.Socket.route_default;
    try netlink.in_namespace_of(pid, route_default, .{ runner_interface, schema.runner_address });
    for (system.nodes) |*peer| {
        if (std.mem.eql(u8, peer.name, node.name)) continue;
        const peer_pid = pid_read(peer.name) orelse continue;
        link_create(self, .{
            .name = peer.name,
            .address = try address_now(peer),
            .pid = peer_pid,
        }) catch |err| switch (err) {
            // The peer died meanwhile (killed, not yet reaped: its pid answers, its namespace
            // is gone): it links to this node when it starts again. Once, every start after a
            // kill of a peer failed here and left its node down for good.
            error.NoSuchNamespace => continue,
            else => return err,
        };
    }
}

const Endpoint = struct { name: []const u8, address: netlink.Address, pid: linux.pid_t };

fn link_create(a: Endpoint, b: Endpoint) !void {
    var name_a: [netlink.interface_name_size_max]u8 = undefined;
    var name_b: [netlink.interface_name_size_max]u8 = undefined;
    const interface_a = interface_name(&name_a, b.name); // In a's namespace, towards b.
    const interface_b = interface_name(&name_b, a.name);
    const ends = [2]netlink.VethEnd{
        .{ .name = interface_a, .mac = mac(a.address, b.address), .pid = a.pid },
        .{ .name = interface_b, .mac = mac(b.address, a.address), .pid = b.pid },
    };
    // After a restart, the dead namespace's links disappear when the kernel gets to it (a
    // worker, later under load): the peer's old end is removed instead of waited for (both ends
    // of a veth go together). Created from inside a's namespace: one end local, the peer moved
    // to b's.
    for (0..link_attempts_max) |_| {
        const create = netlink.Socket.veth_create;
        netlink.in_namespace_of(a.pid, create, .{ends}) catch |err| switch (err) {
            error.Exists => {
                const delete = netlink.Socket.link_delete;
                netlink.in_namespace_of(b.pid, delete, .{interface_b}) catch {};
                netlink.in_namespace_of(a.pid, delete, .{interface_a}) catch {};
                sleep_ns(poll_interval_ns);
                continue;
            },
            else => return err,
        };
        break;
    } else return error.StaleLink;
    try netlink.in_namespace_of(a.pid, link_configure, .{ interface_a, a.address, b.address });
    try netlink.in_namespace_of(b.pid, link_configure, .{ interface_b, b.address, a.address });
}

fn link_configure(
    socket: *netlink.Socket,
    interface: []const u8,
    local: netlink.Address,
    peer: netlink.Address,
) !void {
    try socket.address_add(interface, local);
    try socket.link_set(interface, .up);
    try socket.route_add(interface, peer);
}

fn interface_name(buffer: *[netlink.interface_name_size_max]u8, peer: []const u8) []const u8 {
    assert(peer.len <= schema.node_name_size_max);
    return std.fmt.bufPrint(buffer, "d-{s}", .{peer}) catch unreachable;
}

fn mac(local: netlink.Address, peer: netlink.Address) [6]u8 {
    return .{ 0x02, 0xde, local[2], local[3], peer[2], peer[3] };
}

pub fn address_parse(text: []const u8) !netlink.Address {
    var address: netlink.Address = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10);
    }
    if (parts.next() != null) return error.BadAddress;
    return address;
}

/// A one-shot's end (schema.Node.once): its processes gone, as Compose waits for a dependency's
/// `service_completed_successfully` (its status is judged by "no unexpected container exits").
/// Its readiness timeout bounds it, 600 s without one: a setup step that hangs is said.
fn once_wait(node: *const schema.Resolved) !void {
    var paths: Paths = undefined;
    try paths.init(node.name);
    const timeout_s: u64 = if (node.ready) |ready| ready.timeout_s else 600;
    const attempts = timeout_s * std.time.ns_per_s / poll_interval_ns;
    for (0..attempts) |_| {
        if (!try cgroup_populated(&paths)) {
            sdk.event("node_completed", .{ .node = node.name });
            return;
        }
        sleep_ns(poll_interval_ns);
    }
    sdk.event("node_not_ready", .{ .node = node.name, .tcp = 0, .err = "OnceNotEnded", .not_started = "" });
    std.debug.print("[guest] node {s} (a one-shot) did not end in {d} s\n", .{ node.name, timeout_s });
    return error.NodeNotReady;
}

fn ready_wait(node: *const schema.Resolved) !void {
    const ready = node.ready orelse return;
    if (ready.command) |argv| return ready_command_wait(node, argv, ready.timeout_s);
    const address = try address_now(node);
    const attempts = @as(u64, ready.timeout_s) * std.time.ns_per_s / poll_interval_ns;
    for (0..attempts) |_| {
        if (tcp_accepts(address, ready.tcp)) {
            sdk.event("node_ready", .{ .node = node.name });
            return;
        }
        var paths: Paths = undefined;
        try paths.init(node.name);
        if (!try cgroup_populated(&paths)) return error.NodeExited; // Its processes are gone.
        sleep_ns(poll_interval_ns);
    }
    return error.NodeNotReady;
}

const ready_command_interval_ns = std.time.ns_per_s;

/// Its readiness command (schema.Ready.command) run in it every second until it exits 0, each
/// run in an arena of its own (a slow start's hundreds of runs kept nothing).
fn ready_command_wait(node: *const schema.Resolved, argv: []const []const u8, timeout_s: u32) !void {
    var paths: Paths = undefined;
    try paths.init(node.name);
    const attempts = @max(1, @as(u64, timeout_s) * std.time.ns_per_s / ready_command_interval_ns);
    for (0..attempts) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const status = exec(arena_state.allocator(), node, argv, .{ .quiet = true }) catch 255;
        if (status == 0) {
            sdk.event("node_ready", .{ .node = node.name });
            return;
        }
        if (!try cgroup_populated(&paths)) return error.NodeExited; // Its processes are gone.
        sleep_ns(ready_command_interval_ns);
    }
    return error.NodeNotReady;
}

fn tcp_accepts(address: netlink.Address, port: u16) bool {
    const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    const result = linux.connect(@intCast(fd), @ptrCast(&target), @sizeOf(linux.sockaddr.in));
    return linux.errno(result) == .SUCCESS;
}

/// Everything the child needs after clone, prepared before it (the child only makes syscalls).
const Launch = struct {
    root: [:0]const u8,
    hostname: []const u8,
    workdir: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Absolute candidates for argv[0], one per PATH entry (or argv[0] itself).
    executables: []const [:0]const u8,
    uid: ?u32,
    gid: ?u32,
    privileged: bool,
    antithesis_library: bool,
    /// The node's process limits (Compose's `ulimits`), resource numbers resolved.
    limits: [schema.ulimits_max]Limit = undefined,
    limit_count: u32 = 0,
    /// Its kernel settings (Compose's `sysctls`): each one's /proc/sys path and value.
    sysctls: [schema.sysctls_max]Sysctl = undefined,
    sysctl_count: u32 = 0,
    /// Its shared volumes (schema.Volume.shared): each one's directory bound at its path.
    volumes: [schema.volumes_max]Bind = undefined,
    volume_count: u32 = 0,

    const Limit = struct { resource: u32, value: linux.rlimit };
    const Sysctl = struct { path: [:0]const u8, value: []const u8 };
    const Bind = struct { source: [:0]const u8, target: [:0]const u8, read_only: bool };

    /// `.start` draws the start's number (start_draw_name) for its script; `.exec` (a command in
    /// a running node) draws none: start scripts alone read it, and an exec's draw was 1.4 million
    /// announced pulls in a Raft run, 9% of its events (run 1381).
    fn init(arena: std.mem.Allocator, node: *const schema.Resolved, paths: *const Paths, kind: enum { start, exec, exec_covered }) !Launch {
        if (node.command.len == 0 or node.command.len >= arguments_max) return error.BadCommand;
        if (node.knobs.len > schema.knobs_max) return error.TooManyKnobs;
        // A start's knobs (schema.Knob): their chosen entries first, the node's own of the same
        // names left out (one value each, whichever entry a program reads).
        var knob_entries: [schema.knobs_max * schema.knob_entries_max + cpus_entries_max][]const u8 = undefined;
        var knob_count: usize = 0;
        if (kind == .start) {
            for (node.knobs) |knob| {
                const choice = knob.choices[try knob_draw(node.name, knob)];
                for (choice) |entry| {
                    knob_entries[knob_count] = entry;
                    knob_count += 1;
                }
            }
            // The CPUs its programs size their thread pools by (schema.Node.cpus), drawn as a
            // knob of its own (`knob.cpus`): each runtime's setting where the node sets none,
            // kept for the commands run in the node meanwhile (paths.cpus).
            if (node.cpus.len > 0) {
                const count = node.cpus[@intCast(sdk.random_below_named("knob.cpus", node.cpus.len))];
                var own_buffer: [256]u8 = undefined;
                var own: std.ArrayList(u8) = .initBuffer(&own_buffer);
                try cpus_add(arena, count, &knob_entries, &knob_count, node.env, &own);
                var digits: [16]u8 = undefined;
                try file_write(paths.cpus, try std.fmt.bufPrint(&digits, "{d}", .{count}));
                sdk.event("node_cpus", .{ .node = node.name, .cpus = count, .own = own.items });
            } else _ = linux.unlink(paths.cpus);
        } else if (cpus_kept(paths.cpus)) |count| {
            // A command run in the node: the CPUs its start drew (a machine's, every process's),
            // not drawn again; its knobs are the start's alone.
            var own_buffer: [256]u8 = undefined;
            var own: std.ArrayList(u8) = .initBuffer(&own_buffer);
            try cpus_add(arena, count, &knob_entries, &knob_count, node.env, &own);
        }
        var env_kept: usize = 0;
        for (node.env) |entry| env_kept += @intFromBool(!knob_sets(knob_entries[0..knob_count], entry));
        // Its hostname in HOSTNAME, as Docker and Podman set it in a container's environment, for
        // its start and the commands run in it (the node's own entry wins): Antithesis's
        // formalized Raft projects name each node's forwarded log lines by it, and without it
        // every line came from "unknown" (line 19's trial run 2115: one node's term after
        // another's read as a term going backwards; election safety and the logs' agreement could
        // not fail).
        const hostname_given = env_sets(knob_entries[0..knob_count], "HOSTNAME") or env_sets(node.env, "HOSTNAME");
        // Its user's home in HOME, as runc sets it from the image's /etc/passwd when the
        // environment has none (the node's own entry wins): examples/ci-kaocha's setup ran
        // Clojure's CLI with no HOME, which made /.clojure instead of using what the image fetched
        // under /root (srv4, 2026-11-23).
        const home_given = env_sets(knob_entries[0..knob_count], "HOME") or env_sets(node.env, "HOME");
        if (knob_count + env_kept + platform_environment.len + 7 >= environment_max) {
            return error.TooManyEnvironmentEntries;
        }
        // Every JVM the node's start runs with determinismo's coverage agent (java_options); not
        // a command a driver execs there, the test's own tools (kafka-topics.sh, a reassignment:
        // each one instrumented and slower, its admin client's code a behavior the explorer would
        // chase; trial run 1891), which keep the node's environment as it is.
        const java = if (kind != .exec) try java_options(arena, knob_entries[0..knob_count], node.env) else null;
        // Its Python processes too, for a command run covered (python_options): not a node's
        // start, whose Python programs start their own coverage with the paths they mean.
        const python = if (kind == .exec_covered) try python_options(arena, knob_entries[0..knob_count], node.env) else null;
        const covered = [_]?JavaOptions{ java, python };
        const argv = try arena.allocSentinel(?[*:0]const u8, node.command.len, null);
        for (node.command, argv) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
        // Its own name too (DETERMINISMO_NODE): what det-faults crash-point names.
        var covered_added: usize = 0;
        for (covered) |entry| covered_added += @intFromBool(entry != null and entry.?.replaces == null);
        const wipes = if (kind == .start) wipes_of(paths) else 0;
        const envp_count = knob_count + env_kept + platform_environment.len + 1 + @intFromBool(wipes > 0) +
            @intFromBool(kind == .start) + covered_added + @intFromBool(!hostname_given) + @intFromBool(!home_given);
        const envp = try arena.allocSentinel(?[*:0]const u8, envp_count, null);
        var path_value: []const u8 = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        var filled: usize = 0;
        for (knob_entries[0..knob_count]) |entry| {
            envp[filled] = if (covered_replacing(&covered, entry)) |with| with.ptr else (try arena.dupeSentinel(u8, entry, 0)).ptr;
            filled += 1;
        }
        for (node.env) |entry| {
            if (knob_sets(knob_entries[0..knob_count], entry)) continue;
            envp[filled] = if (covered_replacing(&covered, entry)) |with| with.ptr else (try arena.dupeSentinel(u8, entry, 0)).ptr;
            filled += 1;
        }
        for (covered) |entry| {
            const added = entry orelse continue;
            if (added.replaces != null) continue;
            envp[filled] = added.entry.ptr;
            filled += 1;
        }
        if (!hostname_given) {
            envp[filled] = try std.fmt.allocPrintSentinel(arena, "HOSTNAME={s}", .{node.hostname orelse node.name}, 0);
            filled += 1;
        }
        const ids: ?Ids = if (node.user) |user| try user_resolve(arena, paths.root, user) else null;
        if (!home_given) {
            const home = home_in(arena, paths.root, if (ids) |i| i.uid else 0);
            envp[filled] = try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0);
            filled += 1;
        }
        for (envp[0..filled]) |entry| {
            const text = std.mem.span(entry.?);
            if (std.mem.startsWith(u8, text, "PATH=")) path_value = text["PATH=".len..];
        }
        for (platform_environment, envp[filled..][0..platform_environment.len]) |entry, *slot| slot.* = entry.ptr;
        envp[filled + platform_environment.len] = try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_NODE={s}", .{node.name}, 0);
        // A start after a wipe (wipes_of).
        if (wipes > 0) {
            envp[filled + platform_environment.len + 1] = try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_WIPES={d}", .{wipes}, 0);
        }
        // A number drawn for this start (start_draw_name): a start script's own choices, a
        // workaround a node applies at random (never for good), steered and replayed as any.
        if (kind == .start) {
            const draw = sdk.random_below_named(start_draw_name, std.math.maxInt(u32));
            envp[envp_count - 1] = try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_DRAW={d}", .{draw}, 0);
        }
        var launch: Launch = .{
            .root = paths.root,
            .hostname = node.hostname orelse node.name,
            .workdir = try arena.dupeSentinel(u8, node.workdir, 0),
            .argv = argv.ptr,
            .envp = envp.ptr,
            .executables = try executables(arena, node.command[0], path_value),
            .uid = if (ids) |i| i.uid else null,
            .gid = if (ids) |i| i.gid else null,
            .privileged = node.privileged,
            .antithesis_library = node.antithesis_library,
        };
        for (node.volumes) |volume| {
            if (launch.volume_count == schema.volumes_max) return error.TooManyVolumes;
            const name = volume.shared orelse continue;
            if (!schema.volume_name_valid(name) or volume.path.len == 0 or volume.path[0] != '/') return error.BadVolume;
            const source = try std.fmt.allocPrintSentinel(arena, volumes_root ++ "/{s}", .{name}, 0);
            // Made by the first node to use it, empty and root's (Docker's missing bind source).
            try mkdir_all(source);
            launch.volumes[launch.volume_count] = .{
                .source = source,
                .target = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ paths.root, volume.path }, 0),
                .read_only = volume.read_only,
            };
            launch.volume_count += 1;
        }
        for (node.ulimits orelse &.{}) |ulimit| {
            if (launch.limit_count == schema.ulimits_max) return error.TooManyUlimits;
            const resource = schema.ulimit_resource(ulimit.name) orelse return error.BadUlimit;
            launch.limits[launch.limit_count] = .{ .resource = resource, .value = .{
                .cur = ulimit.soft,
                .max = ulimit.hard,
            } };
            launch.limit_count += 1;
        }
        const proc_sys = "/proc/sys/";
        for (node.sysctls orelse &.{}) |entry| {
            if (launch.sysctl_count == schema.sysctls_max) return error.TooManySysctls;
            const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadSysctl;
            const key = entry[0..equals];
            if (!schema.sysctl_namespaced(key)) return error.SysctlNotNamespaced;
            const path = try arena.allocSentinel(u8, proc_sys.len + key.len, 0);
            @memcpy(path[0..proc_sys.len], proc_sys);
            for (key, path[proc_sys.len..]) |byte, *out| out.* = if (byte == '.') '/' else byte;
            launch.sysctls[launch.sysctl_count] = .{ .path = path, .value = entry[equals + 1 ..] };
            launch.sysctl_count += 1;
        }
        return launch;
    }

    /// One kernel setting of the node's own namespaces: the guest's /proc resolves a network or
    /// IPC setting by the writer's namespace, the node's now. A setting that does not take stops
    /// the node, as Docker refuses the container.
    fn sysctl_set(sysctl: Sysctl) void {
        const fd = linux.open(sysctl.path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) die(sysctl.path, error.SysctlOpen);
        defer _ = linux.close(@intCast(fd));
        const written = linux.write(@intCast(fd), sysctl.value.ptr, sysctl.value.len);
        if (linux.errno(written) != .SUCCESS or written != sysctl.value.len) die(sysctl.path, error.SysctlWrite);
    }

    /// In the child, PID 1 of the node's namespaces.
    /// Its stdout and stderr are the forwarder's pipes (output.zig): events and output.log.
    /// `exits`: a node's start's socket for its exits filter's listener (exits.zig).
    fn exec(launch: *const Launch, stdout: linux.fd_t, stderr: linux.fd_t, exits: ?linux.fd_t) noreturn {
        const null_input = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        _ = linux.dup2(stdout, 1);
        _ = linux.dup2(stderr, 2);
        if (linux.errno(null_input) == .SUCCESS) _ = linux.dup2(@intCast(null_input), 0);
        // Before its mounts, which may give it a /proc whose sys is read-only.
        for (launch.sysctls[0..launch.sysctl_count]) |sysctl| sysctl_set(sysctl);
        launch.mounts() catch |err| die("mounts", err);
        _ = linux.syscall2(.sethostname, @intFromPtr(launch.hostname.ptr), launch.hostname.len);
        launch.exec_in_root(exits);
    }

    /// In the node's root: its process limits, then drop to its user, enter its working
    /// directory, run the command.
    fn exec_in_root(launch: *const Launch, exits: ?linux.fd_t) noreturn {
        // Before the user: installing the exits filter without no_new_privs takes root.
        if (exits) |socket| exits_zig.filter_install(socket) catch |err| die("exits filter", err);
        // Before the user: a hard limit above the one inherited needs root to raise.
        for (launch.limits[0..launch.limit_count]) |limit| {
            const result = linux.syscall4(.prlimit64, 0, limit.resource, @intFromPtr(&limit.value), 0);
            if (linux.errno(result) != .SUCCESS) die("setrlimit", error.Setrlimit);
        }
        if (launch.gid) |gid| {
            _ = linux.syscall2(.setgroups, 0, 0);
            if (linux.errno(linux.setgid(gid)) != .SUCCESS) die("setgid", error.Setgid);
        }
        if (launch.uid) |uid| {
            if (linux.errno(linux.setuid(uid)) != .SUCCESS) die("setuid", error.Setuid);
        }
        if (linux.errno(linux.chdir(launch.workdir)) != .SUCCESS) _ = linux.chdir("/");
        var failure: linux.E = .NOENT;
        for (launch.executables) |path| {
            failure = linux.errno(linux.execve(path, launch.argv, launch.envp));
        }
        std.debug.print("det-nodes: exec {s} failed: {s}\n", .{
            launch.argv[0].?, @tagName(failure),
        });
        linux.exit_group(127);
    }

    fn mounts_detach_other_nodes(launch: *const Launch) !void {
        // Private first: a detach would otherwise reach the guest's mounts too.
        try mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, null);
        const directory = std.fs.path.dirname(launch.root) orelse return error.BadRoot;
        try mounts_detach_others(directory, state_root);
    }

    fn mounts(launch: *const Launch) !void {
        var buffer: [path_size_max]u8 = undefined;
        const Target = struct {
            path: []const u8,
            fs: [:0]const u8,
            flags: u32,
            data: ?[:0]const u8,
        };
        const read_only: u32 = if (launch.privileged) 0 else linux.MS.RDONLY;
        const targets = [_]Target{
            .{ .path = "proc", .fs = "proc", .flags = 0, .data = null },
            .{ .path = "sys", .fs = "sysfs", .flags = read_only, .data = null },
            .{ .path = "sys/fs/cgroup", .fs = "cgroup2", .flags = read_only, .data = null },
            .{ .path = "dev", .fs = "devtmpfs", .flags = 0, .data = null },
            .{ .path = "dev/pts", .fs = "devpts", .flags = 0, .data = "newinstance,ptmxmode=0666" },
            .{ .path = "dev/shm", .fs = "tmpfs", .flags = 0, .data = null },
        };
        for (targets) |target| {
            const path = try print_z(&buffer, "{s}/{s}", .{ launch.root, target.path });
            try mkdir_all(path);
            const data: ?[*:0]const u8 = if (target.data) |d| d.ptr else null;
            try mount(target.fs, path, target.fs, target.flags, data);
        }
        // Antithesis's output sink (ANTITHESIS_OUTPUT_DIR).
        try mkdir_all(try print_z(&buffer, "{s}" ++ sink_directory, .{launch.root}));
        try mkdir_all(try print_z(&buffer, "{s}" ++ filtered_directory, .{launch.root}));
        // The platform's binaries and the fault injector's control FIFO, read-only.
        const platform = try print_z(&buffer, "{s}/opt/determinismo", .{launch.root});
        try mkdir_all(platform);
        try mount("/opt/determinismo", platform, null, linux.MS.BIND | linux.MS.REC, null);
        const remount = linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY;
        try mount(null, platform, null, remount, null);
        // Antithesis's native library, where its SDKs and instrumented programs look for it.
        if (launch.antithesis_library) {
            try mkdir_all(try print_z(&buffer, "{s}/usr/lib", .{launch.root}));
            const voidstar = try print_z(&buffer, "{s}/usr/lib/libvoidstar.so", .{launch.root});
            const create: linux.O = .{ .ACCMODE = .RDONLY, .CREAT = true, .CLOEXEC = true };
            const created = linux.open(voidstar, create, 0o644);
            if (linux.errno(created) == .SUCCESS) _ = linux.close(@intCast(created));
            try mount(voidstar_path, voidstar, null, linux.MS.BIND, null);
            try mount(null, voidstar, null, remount, null);
        }
        // What container runtimes add to /dev (bash process substitution needs /dev/fd).
        const links = [_]struct { path: []const u8, target: [:0]const u8 }{
            .{ .path = "dev/fd", .target = "/proc/self/fd" },
            .{ .path = "dev/stdin", .target = "/proc/self/fd/0" },
            .{ .path = "dev/stdout", .target = "/proc/self/fd/1" },
            .{ .path = "dev/stderr", .target = "/proc/self/fd/2" },
        };
        for (links) |link| {
            const path = try print_z(&buffer, "{s}/{s}", .{ launch.root, link.path });
            switch (linux.errno(linux.symlink(link.target, path))) {
                .SUCCESS, .EXIST => {},
                else => return error.Symlink,
            }
        }
        // Its shared volumes, under its root: they stay as the others go below.
        for (launch.volumes[0..launch.volume_count]) |volume| {
            try mkdir_all(volume.target);
            try mount(volume.source, volume.target, null, linux.MS.BIND, null);
            if (volume.read_only) try mount(null, volume.target, null, remount, null);
        }
        // The namespace began as a copy of the guest's mounts (other nodes' went first, see
        // `start`): only the node's root stays.
        try mounts_detach_others(launch.root, "/");
        // The guest's root is the initramfs, where pivot_root is not allowed: move the node's
        // root over it and chroot, as switch_root does. The mount namespace is the node's own.
        if (linux.errno(linux.chdir(launch.root)) != .SUCCESS) return error.Chdir;
        try mount(".", "/", null, linux.MS.MOVE, null);
        if (linux.errno(linux.chroot(".")) != .SUCCESS) return error.Chroot;
        if (linux.errno(linux.chdir("/")) != .SUCCESS) return error.Chdir;
    }
};

const voidstar_path = "/opt/determinismo/lib/libvoidstar.so"; // initramfs.zig's.
const mounts_max = 4096;
var mountinfo_buffer: [1 << 20]u8 = undefined;

/// Detaches every mount of this (new, private) namespace under `within` other than `root`, what
/// is under it and its ancestors (which hold it until it moves over `/`).
fn mounts_detach_others(root: []const u8, within: []const u8) !void {
    const fd = linux.open("/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoMountinfo;
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < mountinfo_buffer.len) {
        const free = mountinfo_buffer[size..];
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) break;
        size += result;
    } else return error.TooManyMounts;
    var points: [mounts_max][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, mountinfo_buffer[0..size], '\n');
    while (lines.next()) |line| {
        // id, parent id, major:minor, root, then the mount point.
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = fields.next();
        const point = fields.next() orelse continue;
        if (count == mounts_max) return error.TooManyMounts;
        points[count] = point;
        count += 1;
    }
    var index = count;
    while (index > 0) { // Children first.
        index -= 1;
        const point = points[index];
        if (std.mem.eql(u8, point, root) or path_under(point, root) or path_under(root, point)) {
            continue;
        }
        if (!path_under(point, within)) continue;
        var buffer: [path_size_max]u8 = undefined;
        const path = print_z(&buffer, "{s}", .{point}) catch continue;
        _ = linux.umount2(path, linux.MNT.DETACH); // Gone already with a detached parent.
    }
}

/// Whether `path` is strictly under `directory` ("/" is above every other path).
fn path_under(path: []const u8, directory: []const u8) bool {
    if (std.mem.eql(u8, directory, "/")) return !std.mem.eql(u8, path, "/");
    return path.len > directory.len and std.mem.startsWith(u8, path, directory) and
        path[directory.len] == '/';
}

test path_under {
    try std.testing.expect(path_under("/run/det/nodes/a/root/proc", "/run/det/nodes/a/root"));
    try std.testing.expect(path_under("/run", "/"));
    try std.testing.expect(!path_under("/", "/"));
    try std.testing.expect(!path_under("/run/det/nodes/ab", "/run/det/nodes/a"));
    try std.testing.expect(!path_under("/run/det/nodes/a/root", "/run/det/nodes/a/root"));
}

const Ids = struct { uid: u32, gid: u32 };

/// `user[:group]`, each a number or a name from the node's /etc/passwd and /etc/group.
fn user_resolve(arena: std.mem.Allocator, root: []const u8, text: []const u8) !Ids {
    var parts = std.mem.splitScalar(u8, text, ':');
    const user = parts.next().?;
    const group = parts.next();
    var buffer: [path_size_max]u8 = undefined;
    const passwd = try read_file(arena, try print_z(&buffer, "{s}/etc/passwd", .{root}), 1 << 20);
    const entry = id_lookup(passwd, user) orelse return error.UnknownUser;
    var ids = Ids{ .uid = entry.id, .gid = entry.group };
    if (group) |name| {
        const group_path = try print_z(&buffer, "{s}/etc/group", .{root});
        const groups = try read_file(arena, group_path, 1 << 20);
        ids.gid = (id_lookup(groups, name) orelse return error.UnknownGroup).id;
    }
    return ids;
}

/// Finds `name` (or a number) in passwd/group lines: `name:x:id:group...`.
fn id_lookup(database: []const u8, name: []const u8) ?struct { id: u32, group: u32 } {
    if (std.fmt.parseInt(u32, name, 10)) |id| {
        return .{ .id = id, .group = id };
    } else |_| {}
    var lines = std.mem.tokenizeScalar(u8, database, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        if (!std.mem.eql(u8, fields.next() orelse continue, name)) continue;
        _ = fields.next(); // Password.
        const id = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
        const group_text = fields.next() orelse "";
        const group = std.fmt.parseInt(u32, group_text, 10) catch id;
        return .{ .id = id, .group = group };
    }
    return null;
}

fn executables(
    arena: std.mem.Allocator,
    program: []const u8,
    path_value: []const u8,
) ![]const [:0]const u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const single = try arena.alloc([:0]const u8, 1);
        single[0] = try arena.dupeSentinel(u8, program, 0);
        return single;
    }
    var list: std.ArrayList([:0]const u8) = .empty;
    var directories = std.mem.tokenizeScalar(u8, path_value, ':');
    while (directories.next()) |directory| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, program }, 0);
        try list.append(arena, path);
    }
    return list.items;
}

fn die(what: []const u8, err: anyerror) noreturn {
    std.debug.print("det-nodes: {s} failed: {s}\n", .{ what, @errorName(err) });
    linux.exit_group(127);
}

fn mount(
    special: ?[*:0]const u8,
    target: [*:0]const u8,
    fs: ?[*:0]const u8,
    flags: u32,
    data: ?[*:0]const u8,
) !void {
    const result = linux.mount(special, target, fs, flags, if (data) |d| @intFromPtr(d) else 0);
    if (linux.errno(result) != .SUCCESS) {
        const errno = @tagName(linux.errno(result));
        std.debug.print("det-nodes: mount {s} failed: {s}\n", .{ target, errno });
        return error.MountFailed;
    }
}

pub fn mkdir_all(path: []const u8) !void {
    assert(path.len > 0 and path.len < path_size_max);
    var buffer: [path_size_max]u8 = undefined;
    for (path, 0..) |byte, index| {
        if (byte != '/' and index + 1 != path.len) continue;
        const end = if (byte == '/') index else index + 1;
        if (end == 0) continue;
        @memcpy(buffer[0..end], path[0..end]);
        buffer[end] = 0;
        const result = linux.mkdir(buffer[0..end :0], 0o755);
        switch (linux.errno(result)) {
            .SUCCESS, .EXIST => {},
            else => return error.Mkdir,
        }
    }
}

fn exists(path: [:0]const u8) bool {
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

/// A knob's choice for this start (schema.Knob): drawn by name, or for a run-scoped knob the
/// choice the first start of any node drew (kept in /run/det/nodes/knob-<name>: the first link
/// wins when two start at once). Said in a `node_knob` event.
fn knob_draw(node_name: []const u8, knob: schema.Knob) !usize {
    assert(knob.choices.len > 0);
    var decision_buffer: [64]u8 = undefined;
    const decision = try std.fmt.bufPrint(&decision_buffer, "knob.{s}", .{knob.name});
    const count = knob.choices.len;
    const index: usize = switch (knob.scope) {
        .start => @intCast(sdk.random_below_named(decision, count)),
        .run => run: {
            var path_buffer: [path_size_max]u8 = undefined;
            const path = try print_z(&path_buffer, state_root ++ "/knob-{s}", .{knob.name});
            if (knob_read(path, count)) |kept| break :run kept;
            const drawn: usize = @intCast(sdk.random_below_named(decision, count));
            var temporary_buffer: [path_size_max]u8 = undefined;
            const temporary = try print_z(&temporary_buffer, state_root ++ "/knob-{s}.{d}", .{ knob.name, linux.getpid() });
            var digits: [24]u8 = undefined;
            try file_write(temporary, try std.fmt.bufPrint(&digits, "{d}", .{drawn}));
            const linked = linux.link(temporary, path);
            _ = linux.unlink(temporary);
            if (linux.errno(linked) == .EXIST) break :run knob_read(path, count) orelse return error.KnobUnreadable;
            if (linux.errno(linked) != .SUCCESS) return error.KnobUnwritten;
            break :run drawn;
        },
    };
    var joined_buffer: [512]u8 = undefined;
    var joined: std.ArrayList(u8) = .initBuffer(&joined_buffer);
    for (knob.choices[index], 0..) |entry, position| {
        if (position > 0) joined.appendBounded(' ') catch break;
        joined.appendSliceBounded(entry) catch break;
    }
    sdk.event("node_knob", .{ .node = node_name, .knob = knob.name, .choice = index, .env = joined.items });
    return index;
}

fn knob_read(path: [:0]const u8, count: usize) ?usize {
    var buffer: [24]u8 = undefined;
    const text = read_small(path, &buffer) orelse return null;
    const index = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return if (index < count) index else null;
}

/// Whether one of a start's knob entries sets the variable `entry` (NAME=value) sets.
/// Each runtime's own setting of the CPUs it sizes its thread pools by (schema.Node.cpus): the
/// count alone, or Erlang's schedulers (`+S n:n`). The JVM's is a flag in JAVA_TOOL_OPTIONS
/// (cpus_add). Node.js sizes its pool by none (libuv's 4), CPython has no pool to size.
const cpus_variables = [_]struct { name: []const u8, form: enum { count, erlang } }{
    .{ .name = "TOKIO_WORKER_THREADS", .form = .count },
    .{ .name = "GOMAXPROCS", .form = .count },
    .{ .name = "RAYON_NUM_THREADS", .form = .count },
    .{ .name = "OMP_NUM_THREADS", .form = .count },
    .{ .name = "DOTNET_PROCESSOR_COUNT", .form = .count },
    .{ .name = "ERL_FLAGS", .form = .erlang },
};
const java_cpus_flag = "-XX:ActiveProcessorCount=";
/// The entries cpus_add may add: each variable's, and JAVA_TOOL_OPTIONS.
const cpus_entries_max = cpus_variables.len + 1;

/// The entries giving a start's programs `count` CPUs to size their pools by, appended to
/// `entries` (a start's knob entries, which come before the node's own): each runtime's
/// variable the node's environment and its knobs leave unset, and the JVM's flag after their
/// JAVA_TOOL_OPTIONS (replacing a knob's entry of it, so one value is taken). What the node
/// sets itself is left alone, its names in `own` (space-separated): a count of its own.
fn cpus_add(arena: std.mem.Allocator, count: u32, entries: [][]const u8, entries_count: *usize, env: []const []const u8, own: *std.ArrayList(u8)) !void {
    assert(entries.len >= entries_count.* + cpus_entries_max);
    const knobs = entries[0..entries_count.*];
    for (cpus_variables) |variable| {
        if (env_sets(knobs, variable.name) or env_sets(env, variable.name)) {
            if (own.items.len > 0) own.appendBounded(' ') catch {};
            own.appendSliceBounded(variable.name) catch {};
            continue;
        }
        entries[entries_count.*] = switch (variable.form) {
            .count => try std.fmt.allocPrint(arena, "{s}={d}", .{ variable.name, count }),
            .erlang => try std.fmt.allocPrint(arena, "{s}=+S {d}:{d}", .{ variable.name, count, count }),
        };
        entries_count.* += 1;
    }
    const java = "JAVA_TOOL_OPTIONS";
    var knob_index: ?usize = null;
    for (entries[0..entries_count.*], 0..) |entry, index| {
        if (entry.len > java.len and entry[java.len] == '=' and std.mem.startsWith(u8, entry, java)) knob_index = index;
    }
    const value: ?[]const u8 = if (knob_index) |index| entries[index][java.len + 1 ..] else env_value(env, java);
    if (value != null and std.mem.indexOf(u8, value.?, "ActiveProcessorCount") != null) {
        if (own.items.len > 0) own.appendBounded(' ') catch {};
        own.appendSliceBounded(java) catch {};
        return;
    }
    const joined = if (value) |options|
        try std.fmt.allocPrint(arena, "{s}={s} " ++ java_cpus_flag ++ "{d}", .{ java, std.mem.trim(u8, options, " "), count })
    else
        try std.fmt.allocPrint(arena, "{s}=" ++ java_cpus_flag ++ "{d}", .{ java, count });
    if (knob_index) |index| {
        entries[index] = joined;
    } else {
        entries[entries_count.*] = joined;
        entries_count.* += 1;
    }
}

/// The CPU count a node's running start drew (paths.cpus), or null: none drawn, or unreadable.
fn cpus_kept(path: [:0]const u8) ?u32 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var digits: [16]u8 = undefined;
    const size = linux.read(@intCast(fd), &digits, digits.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, digits[0..size], " \n"), 10) catch null;
}

/// The value of `name` in environment entries, or null.
fn env_value(entries: []const []const u8, name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

test "a start's CPUs: each runtime's setting where the node sets none, the JVM's after its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: [4 + cpus_entries_max][]const u8 = undefined;
    entries[0] = "SNAPSHOT_COUNT=100"; // A knob's.
    var count: usize = 1;
    var own_buffer: [256]u8 = undefined;
    var own: std.ArrayList(u8) = .initBuffer(&own_buffer);
    const env = [_][]const u8{ "GOMAXPROCS=8", "JAVA_TOOL_OPTIONS=-Xmx1g", "PATH=/bin" };
    try cpus_add(arena, 4, &entries, &count, &env, &own);
    try std.testing.expectEqualStrings("GOMAXPROCS", own.items);
    try std.testing.expectEqualStrings("4", env_value(entries[0..count], "TOKIO_WORKER_THREADS").?);
    try std.testing.expect(env_value(entries[0..count], "GOMAXPROCS") == null); // The node's own stays.
    try std.testing.expectEqualStrings("+S 4:4", env_value(entries[0..count], "ERL_FLAGS").?);
    try std.testing.expectEqualStrings("-Xmx1g -XX:ActiveProcessorCount=4", env_value(entries[0..count], "JAVA_TOOL_OPTIONS").?);
    // A knob's JAVA_TOOL_OPTIONS: the flag after it, in its place (one value each).
    var knobbed: [4 + cpus_entries_max][]const u8 = undefined;
    knobbed[0] = "JAVA_TOOL_OPTIONS=-Xss512k";
    var knobbed_count: usize = 1;
    own.clearRetainingCapacity();
    try cpus_add(arena, 2, &knobbed, &knobbed_count, &.{}, &own);
    try std.testing.expectEqualStrings("", own.items);
    try std.testing.expectEqualStrings("-Xss512k -XX:ActiveProcessorCount=2", knobbed[0]["JAVA_TOOL_OPTIONS=".len..]);
    var java_count: usize = 0;
    for (knobbed[0..knobbed_count]) |entry| java_count += @intFromBool(std.mem.startsWith(u8, entry, "JAVA_TOOL_OPTIONS="));
    try std.testing.expectEqual(@as(usize, 1), java_count);
    // A count of the node's own in its JVM options: left alone.
    var counted: [4 + cpus_entries_max][]const u8 = undefined;
    var counted_count: usize = 0;
    own.clearRetainingCapacity();
    try cpus_add(arena, 2, &counted, &counted_count, &.{"JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=8"}, &own);
    try std.testing.expectEqualStrings("JAVA_TOOL_OPTIONS", own.items);
    try std.testing.expect(env_value(counted[0..counted_count], "JAVA_TOOL_OPTIONS") == null);
}

fn knob_sets(knob_entries: []const []const u8, entry: []const u8) bool {
    const name_end = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    for (knob_entries) |knob_entry| {
        if (knob_entry.len > name_end and knob_entry[name_end] == '=' and std.mem.eql(u8, knob_entry[0..name_end], entry[0..name_end])) return true;
    }
    return false;
}

/// The home directory of `uid` in a passwd file's lines (`name:x:uid:gid:gecos:home:shell`), or
/// null when it has no such user or an empty home.
fn home_of(passwd: []const u8, uid: u32) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        _ = fields.next(); // Name.
        _ = fields.next(); // Password.
        const id = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (id != uid) continue;
        _ = fields.next(); // Group.
        _ = fields.next(); // Its comment.
        const home = fields.next() orelse return null;
        return if (home.len > 0) home else null;
    }
    return null;
}

/// HOME for `uid` in the node at `root`, as runc sets it when a container's environment has none:
/// its home in the image's /etc/passwd, else "/".
fn home_in(arena: std.mem.Allocator, root: []const u8, uid: u32) []const u8 {
    var buffer: [path_size_max]u8 = undefined;
    const path = print_z(&buffer, "{s}/etc/passwd", .{root}) catch return "/";
    const passwd = read_file(arena, path, 1 << 20) catch return "/";
    return home_of(passwd, uid) orelse "/";
}

test home_of {
    const passwd = "root:x:0:0:root:/root:/bin/sh\nbroken line\napp:x:1000:1000:App,,,:/srv/app:/bin/sh\nnohome:x:7:7:::/bin/sh\n";
    try std.testing.expectEqualStrings("/root", home_of(passwd, 0).?);
    try std.testing.expectEqualStrings("/srv/app", home_of(passwd, 1000).?);
    try std.testing.expectEqual(null, home_of(passwd, 999));
    try std.testing.expectEqual(null, home_of(passwd, 7));
    try std.testing.expectEqual(null, home_of("", 0));
}

/// Whether `entries` (NAME=value) set `name`.
fn env_sets(entries: []const []const u8, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return true;
    }
    return false;
}

test env_sets {
    try std.testing.expect(env_sets(&.{ "PATH=/bin", "HOSTNAME=raft1" }, "HOSTNAME"));
    try std.testing.expect(!env_sets(&.{ "HOSTNAMES=x", "PATH=/bin" }, "HOSTNAME"));
    try std.testing.expect(!env_sets(&.{}, "HOSTNAME"));
}

test "a knob's entry replaces the node's own of its name" {
    const entries = [_][]const u8{ "SNAP=10", "HEARTBEAT=100" };
    try std.testing.expect(knob_sets(&entries, "SNAP=1000"));
    try std.testing.expect(knob_sets(&entries, "HEARTBEAT="));
    try std.testing.expect(!knob_sets(&entries, "SNAPSHOT=1"));
    try std.testing.expect(!knob_sets(&entries, "SNA=1"));
    try std.testing.expect(!knob_sets(&entries, "PATH=/bin"));
}

pub fn file_write(path: [:0]const u8, content: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    const written = linux.write(@intCast(fd), content.ptr, content.len);
    // A full /run named as such: the node's disk image and log live there, and a start that
    // found it full failed as "WriteFailed" alone (ZooKeeper's set, run 711 timeline 45).
    if (linux.errno(written) == .NOSPC) return error.NoSpaceLeft;
    if (linux.errno(written) != .SUCCESS or written != content.len) return error.WriteFailed;
}

/// The last `buffer.len` bytes the node wrote since its current start, or null when unreadable:
/// its log goes on across starts, and an exit is judged on what its own start wrote (a text an
/// earlier start wrote must not make a later exit known: etcd's spare, run 356).
pub fn output_tail(name: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, state_root ++ "/{s}/output.log", .{name}, 0) catch return null;
    var start_path_buffer: [path_size_max]u8 = undefined;
    const start_path = std.fmt.bufPrintSentinel(&start_path_buffer, state_root ++ "/{s}/output.start", .{name}, 0) catch
        return null;
    var start_buffer: [32]u8 = undefined;
    const start_text = read_small(start_path, &start_buffer) orelse "0";
    const started_at = std.fmt.parseInt(u64, std.mem.trim(u8, start_text, " \n"), 10) catch 0;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return null;
    const size: u64 = @intCast(end);
    const offset = @min(@max(size -| buffer.len, started_at), size);
    const read = linux.pread(@intCast(fd), buffer.ptr, buffer.len, @intCast(offset));
    if (linux.errno(read) != .SUCCESS) return null;
    return buffer[0..read];
}

pub fn read_small(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

/// A whole file, of fewer than `size_max` bytes, in a buffer of its own size (and one byte more,
/// to see it grew while read): never `size_max` up front, which a safe build fills whole (0xAA,
/// every page touched). Each start of a node with a user read /etc/passwd so, 1 MiB kept in
/// det-faults' run-long arena per restart: 1.16 GB after 1125 restarts, and the guest's kernel
/// killed det-faults (Kvrocks, user 999: hunt run 1993, timeline 486 at 732 s).
fn read_file(arena: std.mem.Allocator, path: [:0]const u8, size_max: u32) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    var stat: linux.Statx = undefined;
    const stated = linux.statx(@intCast(fd), "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat);
    if (linux.errno(stated) != .SUCCESS) return error.StatFailed;
    if (stat.size >= size_max) return error.FileTooLarge;
    const buffer = try arena.alloc(u8, @intCast(stat.size + 1));
    var size: u64 = 0;
    while (size < buffer.len) {
        const result = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return buffer[0..size];
        size += result;
    }
    return error.FileGrew;
}

test "a file is read into a buffer of its own size, not the most it may have" {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, ".det-read-file-test-{d}", .{linux.getpid()});
    defer _ = linux.unlink(path);
    try file_write(path, "root:x:0:0:root:/root:/bin/sh\nkvrocks:x:999:999::/var/lib/kvrocks:/bin/sh\n");
    // Room for the file, far less than the 1 MiB a passwd may have.
    var memory: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const content = try read_file(fixed.allocator(), path, 1 << 20);
    try std.testing.expect(std.mem.endsWith(u8, content, "/var/lib/kvrocks:/bin/sh\n"));
    try std.testing.expect(fixed.end_index < 256);
    try std.testing.expectError(error.FileTooLarge, read_file(fixed.allocator(), path, 16));
}

/// Formats into `buffer` as a NUL-terminated path.
pub fn print_z(buffer: []u8, comptime format: []const u8, arguments: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, format, arguments, 0);
}

pub fn sleep_ns(duration_ns: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

test id_lookup {
    const passwd = "root:x:0:0:root:/root:/bin/sh\nredis:x:999:1000::/data:/bin/false\n";
    try std.testing.expectEqual(@as(u32, 999), id_lookup(passwd, "redis").?.id);
    try std.testing.expectEqual(@as(u32, 1000), id_lookup(passwd, "redis").?.group);
    try std.testing.expectEqual(@as(u32, 42), id_lookup(passwd, "42").?.id);
    try std.testing.expect(id_lookup(passwd, "nobody") == null);
}

test address_parse {
    try std.testing.expectEqual(netlink.Address{ 10, 0, 0, 7 }, try address_parse("10.0.0.7"));
    try std.testing.expectError(error.BadAddress, address_parse("10.0.0"));
}

test mac {
    const expected = [6]u8{ 2, 0xde, 0, 2, 0, 1 };
    try std.testing.expectEqual(expected, mac(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }));
}

/// Every branch starts from the same snapshot, the guest kernel's random generator included:
/// without this, what processes draw from it afresh (getrandom, /dev/urandom, TCP sequence
/// numbers) would repeat in every branch. The new seed is a platform decision, so it differs
/// per branch and replays from tapes like any other.
/// The timelines part here (after setup_complete): the kernel's randomness reseeded, and a mark
/// for what drew before the snapshot and draws again for each timeline (the flusher's state).
pub fn timelines_parted() void {
    kernel_reseed();
    file_write(parted_path, "") catch {};
}

const parted_path = "/run/det/timelines-parted";

pub fn kernel_reseed() void {
    const rnd_add_entropy = 0x40085203; // _IOW('R', 3, int[2])
    const rnd_reseed_crng = 0x5207; // _IO('R', 7)
    const seed_size = 32;
    // struct rand_pool_info: entropy bits, buffer size, buffer.
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
