// SPDX-License-Identifier: MIT
//! Typed system descriptions and scenarios for Zig test programs (see determinismo.zig).
//!
//! `System(Nodes)` ties three things to one type, `Nodes` (a struct whose fields are `Node` or
//! `?Node`): the profiles `describe` builds (`profile.node(.redis, ...)`, checked at compile
//! time), the scenarios (functions listing test commands), and what handlers see at run time
//! (`ctx.nodes.redis.address`).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const schema = @import("schema.zig");
const elle = @import("elle.zig");
const sdk = @import("determinismo.zig");

const profiles_max = 32;
const system_size_max = 1 << 20;
const nodes_binary = "/opt/determinismo/bin/det-nodes";

/// A command's exit status and what it printed.
pub const Output = struct { status: u8, output: []const u8 };

/// What a host check gets besides its records (System.main's `.checks`): it runs on the host,
/// once the timeline of `scenario` ended.
pub const Check = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    scenario: []const u8,
};

/// A node as tests see it in the guest.
pub const Node = struct {
    name: []const u8,
    /// Its first address: a restart may give it another (Faults.new_address), `address_now`.
    address: [4]u8,

    /// Where it is now: its line in the hosts file, which a restart with a new address rewrites
    /// (Faults.new_address, as pods come back); its first address when the file names it not.
    pub fn address_now(node: *const Node) [4]u8 {
        var buffer: [hosts_size_max]u8 = undefined;
        const fd = linux.open("/etc/hosts", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return node.address;
        defer _ = linux.close(@intCast(fd));
        const size = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS) return node.address;
        return hosts_address(buffer[0..size], node.name) orelse node.address;
    }

    /// Freezes all its processes (until `unpause`).
    pub fn pause(node: *const Node) !void {
        return nodes_command(&.{ "pause", node.name });
    }

    pub fn unpause(node: *const Node) !void {
        return nodes_command(&.{ "resume", node.name });
    }

    /// Kills all its processes; `start` runs it again with its files intact.
    pub fn kill(node: *const Node) !void {
        return nodes_command(&.{ "kill", node.name });
    }

    pub fn start(node: *const Node) !void {
        return nodes_command(&.{ "start", node.name });
    }

    /// A power loss, then it starts again: its disk keeps what was synced and loses the rest
    /// (the node needs crash faults allowed, which give it a disk of its own).
    pub fn crash(node: *const Node) !void {
        return nodes_command(&.{ "crash", node.name });
    }

    /// It starts again fresh from its image: everything it wrote is gone.
    pub fn wipe(node: *const Node) !void {
        return nodes_command(&.{ "wipe", node.name });
    }

    /// Runs `argv` inside the node (like `docker exec`); returns its exit status. Its output goes
    /// to this command's output.
    pub fn exec(node: *const Node, argv: []const []const u8) !u8 {
        assert(argv.len > 0);
        assert(argv.len + 3 <= exec_arguments_max);
        var arguments: [exec_arguments_max][]const u8 = undefined;
        arguments[0] = "exec";
        arguments[1] = node.name;
        for (argv, arguments[2..][0..argv.len]) |argument, *target| target.* = argument;
        return (try nodes_run(arguments[0 .. argv.len + 2], null, .stdout)).status;
    }

    /// Like `exec`, with the command's standard output captured into `buffer` (what fits; the
    /// rest is read and dropped): for tools whose answer is their output (kubectl get, psql).
    pub fn exec_output(node: *const Node, argv: []const []const u8, buffer: []u8) !Output {
        assert(argv.len > 0);
        assert(argv.len + 3 <= exec_arguments_max);
        var arguments: [exec_arguments_max][]const u8 = undefined;
        arguments[0] = "exec";
        arguments[1] = node.name;
        for (argv, arguments[2..][0..argv.len]) |argument, *target| target.* = argument;
        return nodes_run(arguments[0 .. argv.len + 2], buffer, .stdout);
    }

    /// Like `exec_output`, with the command's standard error in `buffer` too: for tools whose
    /// refusal is a message (a membership command refused: its reason, said in an event).
    pub fn exec_said(node: *const Node, argv: []const []const u8, buffer: []u8) !Output {
        assert(argv.len > 0);
        assert(argv.len + 3 <= exec_arguments_max);
        var arguments: [exec_arguments_max][]const u8 = undefined;
        arguments[0] = "exec";
        arguments[1] = node.name;
        for (argv, arguments[2..][0..argv.len]) |argument, *target| target.* = argument;
        return nodes_run(arguments[0 .. argv.len + 2], buffer, .both);
    }

    /// Restarts the node on its next release (`.next`, its spec's `upgrade`) or back on its own
    /// image (`.base`: a downgrade), gracefully, its writable layer (its data) kept; nothing
    /// when it is on that one already.
    pub fn upgrade(node: *const Node, to: enum { next, base }) !void {
        return nodes_command(&.{ "upgrade", node.name, @tagName(to) });
    }

    /// Whether its process runs now (its pidfile names a live process): a spare not started
    /// yet, a node a fault or a driver stopped, one whose process exited, are not.
    pub fn running(node: *const Node) bool {
        var path_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/pid", .{node.name}, 0) catch return false;
        const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return false;
        defer _ = linux.close(@intCast(fd));
        var buffer: [32]u8 = undefined;
        const size = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS) return false;
        const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..size], " \n"), 10) catch return false;
        return linux.errno(linux.kill(pid, @fromBackingInt(0))) == .SUCCESS;
    }

    /// Whether it is on its next release now (upgrade(.next), until an upgrade(.base)).
    pub fn upgraded(node: *const Node) bool {
        var buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buffer, "/run/det/nodes/{s}/variant-next", .{node.name}, 0) catch return false;
        return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
    }

    /// Cuts (or restores) the link between this node and `peer` (a node name or "runner").
    pub fn link(node: *const Node, peer: []const u8, state: enum { up, down }) !void {
        return nodes_command(&.{ "link", node.name, peer, @tagName(state) });
    }
};

/// How a node is built and run; mirrors `schema.Node` with typed dependencies.
pub fn NodeSpec(comptime Name: type) type {
    return struct {
        image: ?[]const u8 = null,
        directory: ?[]const u8 = null,
        binary: ?[]const u8 = null,
        build: ?schema.Build = null,
        /// Its next release (schema.Node.upgrade): Node.upgrade restarts it there, its data kept.
        upgrade: ?schema.Source = null,
        entrypoint: ?[]const []const u8 = null,
        command: ?[]const []const u8 = null,
        env: []const []const u8 = &.{},
        /// What of its instrumented code reports coverage and pauses threads (schema.Coverage).
        coverage: schema.Coverage = .{},
        workdir: ?[]const u8 = null,
        user: ?[]const u8 = null,
        ready: ?schema.Ready = null,
        after: []const Name = &.{},
        faults: schema.Faults = .{},
        memory_max_mib: ?u32 = null,
        privileged: bool = false,
        /// Process limits (Docker's names: .{ .name = "nofile", .soft = 65536, .hard = 65536 }).
        ulimits: ?[]const schema.Ulimit = null,
        /// Settings drawn as it starts (schema.Knob: FoundationDB's knobs), e.g.
        /// `.{ .name = "snapshot", .choices = &.{ &.{"ETCD_SNAPSHOT_COUNT=10"}, &.{"ETCD_SNAPSHOT_COUNT=1000"} } }`.
        knobs: []const schema.Knob = &.{},
        /// Processes (by command name) whose crashes the system is known to have: counted, not
        /// failed (schema.Node.crashes_known).
        crashes_known: []const []const u8 = &.{},
        /// A drawn flusher's window in seconds: in its on stretches the node's disk synced that
        /// often, as a host's flusher would, in its off ones nothing (schema.Node.writeback_s);
        /// null: strict, nothing written back unasked.
        writeback_s: ?u32 = null,
        /// Exits the system is known to make, by what the node wrote last: counted, not failed
        /// (schema.Node.exits_known).
        exits_known: []const []const u8 = &.{},
        /// Exits known only while the node's disk fails (schema.Node.exits_known_disk).
        exits_known_disk: []const []const u8 = &.{},
        /// Started again by its supervisor after it exits on its own (schema.Node.supervised).
        supervised: bool = false,
        /// Panics the system is known to have, by a text of their stacks: counted, not failed
        /// (schema.Node.panics_known).
        panics_known: []const []const u8 = &.{},
        /// Lines of its output that are failures, a known bug's ones counted instead
        /// (schema.Node.log_failures).
        log_failures: []const schema.LogFailure = &.{},
        /// Not started with the others: a driver starts it (`Node.start`), a member joining
        /// later (schema.Node.spare).
        spare: bool = false,
        /// A one-shot the nodes after it wait to end (schema.Node.once).
        once: bool = false,
        /// Directories shared with other nodes, files of the host (schema.Volume).
        volumes: []const schema.Volume = &.{},
        /// Its hostname when not its name, and other names the nodes resolve to it
        /// (schema.Node.hostname, schema.Node.aliases).
        hostname: ?[]const u8 = null,
        aliases: []const []const u8 = &.{},
        /// Antithesis's native library at /usr/lib/libvoidstar.so, determinismo's
        /// (schema.Node.antithesis_library): Antithesis's SDKs send through it, and libraries
        /// that draw from Antithesis's fuzzer (Hegel's workload backend) draw platform decisions.
        antithesis_library: bool = false,
    };
}

pub fn System(comptime Nodes: type) type {
    const field_names = std.meta.fieldNames(Nodes);
    const field_types = std.meta.fieldTypes(Nodes);
    comptime {
        assert(field_names.len > 0);
        assert(field_names.len <= schema.nodes_max);
        for (field_names, field_types) |name, Field| {
            assert(Field == Node or Field == ?Node);
            assert(schema.name_valid(name));
        }
    }
    return struct {
        pub const Name = std.meta.FieldEnum(Nodes);
        pub const Spec = NodeSpec(Name);

        /// What a handler gets: the nodes of the running system and the process's resources.
        pub const Context = struct {
            nodes: Nodes,
            scenario: []const u8,
            /// The profile the system runs ("default" outside the guest): a scenario whose
            /// profiles run different releases speaks to each as it is.
            profile: []const u8 = "default",
            init: std.process.Init,
        };

        pub const Handler = *const fn (context: *Context) anyerror!void;

        /// A scenario: the test commands of one family of timelines (Antithesis's test
        /// template). Built by an ordinary function, so commands can be shared and parametrized.
        pub const Scenario = struct {
            name: []const u8,
            commands: [schema.commands_max]Entry = undefined,
            count: u32 = 0,
            faults: bool = true,
            clock_skip: bool = false,
            pacing: schema.Pacing = .{},
            /// schema.Scenario.nodes_down_max.
            nodes_down_max: u32 = 0,
            /// schema.Scenario.quorum: the nodes whose majority faults always leave serving.
            quorum: []const []const u8 = &.{},
            /// schema.Scenario.quorum_link_delay_ms, quorum_link_loss_ppm, quorum_recovery_ms.
            quorum_link_delay_ms: u32 = 50,
            quorum_link_loss_ppm: u32 = 10_000,
            quorum_recovery_ms: u32 = 15_000,
            min_drive_ms: ?u32 = null,
            drive_ms_max: ?u32 = null,
            /// The ending's command's window (schema.Scenario.ending_ms_max).
            ending_ms_max: ?u32 = null,
            /// Each timeline starts the nodes and runs the setup itself
            /// (schema.Scenario.snapshot_before_nodes).
            snapshot_before_nodes: bool = false,
            /// At most this many drivers at once (schema.Scenario.parallel_max).
            parallel_max: ?u32 = null,

            const Entry = struct { command: schema.Command, handler: Handler };

            pub fn setup(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.setup, name, handler);
            }
            pub fn first(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.first, name, handler);
            }
            pub fn parallel_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.parallel_driver, name, handler);
            }
            pub fn serial_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.serial_driver, name, handler);
            }
            /// A driver that runs alone: a timeline that draws it runs no other driver
            /// (Antithesis's rule). Something meant to run beside the workload (a nemesis of
            /// its own: a tablet mover, a reconfiguration) is a parallel driver.
            pub fn singleton_driver(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.singleton_driver, name, handler);
            }
            pub fn anytime(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.anytime, name, handler);
            }
            pub fn eventually(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.eventually, name, handler);
            }
            pub fn finally(s: *Scenario, name: []const u8, handler: Handler) void {
                s.add(.finally, name, handler);
            }

            /// A driver of the workload the properties judge (`schema.Command.workload`): the
            /// composer's swarm keeps one of them at least, beside drivers that are its nemeses.
            pub fn workload(s: *Scenario, name: []const u8) void {
                for (s.commands[0..s.count]) |*entry| {
                    if (std.mem.eql(u8, entry.command.name, name)) {
                        entry.command.workload = true;
                        return;
                    }
                }
                unreachable; // Declared before it is marked.
            }

            fn add(s: *Scenario, kind: schema.Kind, name: []const u8, handler: Handler) void {
                assert(name.len > 0);
                assert(s.count < schema.commands_max);
                for (s.commands[0..s.count]) |entry| {
                    assert(!std.mem.eql(u8, entry.command.name, name)); // Names are unique.
                }
                s.commands[s.count] = .{
                    .command = .{ .kind = kind, .name = name },
                    .handler = handler,
                };
                s.count += 1;
            }

            fn find(s: *const Scenario, name: []const u8) ?Handler {
                for (s.commands[0..s.count]) |entry| {
                    if (std.mem.eql(u8, entry.command.name, name)) return entry.handler;
                }
                return null;
            }

            fn kind_of(s: *const Scenario, name: []const u8) ?schema.Kind {
                for (s.commands[0..s.count]) |entry| {
                    if (std.mem.eql(u8, entry.command.name, name)) return entry.command.kind;
                }
                return null;
            }
        };

        pub const Describe = struct {
            profiles: [profiles_max]Profile = undefined,
            count: u32 = 0,

            pub fn profile(d: *Describe, name: []const u8) !*Profile {
                if (d.count == profiles_max) return error.TooManyProfiles;
                d.profiles[d.count] = .{ .name = name };
                d.count += 1;
                return &d.profiles[d.count - 1];
            }
        };

        pub const Profile = struct {
            name: []const u8,
            specs: [field_names.len]?Spec = @splat(null),
            /// A command that turns the system's logs up, in the guest at a moment (`det-nodes
            /// exec <node> ...`): what causality's explanation runs inside a jump.
            explain: ?[]const u8 = null,
            /// Retroactive logging: a verbose system's output lines with one of these texts are
            /// left out of explorations' events and written by replays (`--retroactive` adds).
            retroactive: []const []const u8 = &.{},
            /// The guest's wall clock at boot, Unix seconds (null: the day after the newest image
            /// was made, 2026-01-01 when older; `--epoch` wins).
            epoch_seconds: ?u64 = null,

            pub fn node(p: *Profile, comptime name: Name, spec: Spec) void {
                assert(p.specs[@backingInt(name)] == null); // Each node once per profile.
                p.specs[@backingInt(name)] = spec;
            }
        };

        const Self = @This();

        /// `--describe` and `check <name> <scenario>` on the host, `run <scenario> <command>` in
        /// the guest. `definition` is `.{ .describe = fn (*Describe) !void, .scenarios = .{ .name
        /// = fn (*Scenario) void } }`, and optionally `.checks = .{ .name = fn (*Check, []const
        /// Record) !void }`: host checks, run when each timeline ends on the records its commands
        /// made (`sdk.record("name", record)`), decoded as the function's Record type (or, for
        /// `[]const u8`, the raw JSON lines). A check asserts as anything else does
        /// (`sdk.always`, ...): its assertions are properties of the timeline, at its end.
        pub fn main(init: std.process.Init, comptime definition: anytype) !void {
            const arena = init.arena.allocator();
            const arguments = try init.minimal.args.toSlice(arena);
            if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--describe")) {
                return Self.describe_print(arena, init.io, definition);
            }
            if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "run")) {
                return Self.run(init, definition, arguments[2], arguments[3]);
            }
            if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "check")) {
                var check: Check = .{ .arena = arena, .io = init.io, .scenario = arguments[3] };
                return Self.check_run(&check, definition, arguments[2]);
            }
            std.debug.print("usage: {s} --describe | run <scenario> <command> | " ++
                "check <name> <scenario>\n", .{arguments[0]});
            std.process.exit(2);
        }

        /// A host check: its records from standard input (one JSON line each), decoded as the
        /// function's Record type (raw for `[]const u8`), then the function.
        fn check_run(check: *Check, comptime definition: anytype, name: []const u8) !void {
            if (!@hasField(@TypeOf(definition), "checks")) return error.UnknownCheck;
            const arena = check.arena;
            var input: std.ArrayList(u8) = .empty;
            while (true) {
                try input.ensureUnusedCapacity(arena, 1 << 16);
                const free = input.unusedCapacitySlice();
                const result = linux.read(0, free.ptr, free.len);
                if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
                if (result == 0) break;
                input.items.len += result;
            }
            inline for (comptime std.meta.fieldNames(@TypeOf(definition.checks))) |field| {
                if (std.mem.eql(u8, field, name)) {
                    const function = @field(definition.checks, field);
                    const Records = @typeInfo(@TypeOf(function)).@"fn".param_types[1].?;
                    if (Records == []const u8) return function(check, input.items);
                    const Record = std.meta.Child(Records);
                    var records: std.ArrayList(Record) = .empty;
                    var lines = std.mem.tokenizeScalar(u8, input.items, '\n');
                    while (lines.next()) |line| {
                        try records.append(arena, try std.json.parseFromSliceLeaky(Record, arena, line, .{
                            .ignore_unknown_fields = true,
                        }));
                    }
                    return function(check, records.items);
                }
            }
            return error.UnknownCheck;
        }

        fn run(
            init: std.process.Init,
            comptime definition: anytype,
            scenario_name: []const u8,
            command_name: []const u8,
        ) !void {
            var scenario: Scenario = undefined;
            if (!Self.scenario_build(definition, scenario_name, &scenario)) {
                return error.UnknownScenario;
            }
            const handler = scenario.find(command_name) orelse return error.UnknownCommand;
            // Drivers' histories are capped (elle.history_size_max); the other commands' are not:
            // first, eventually and finally commands read for the judgment (final reads), past
            // the cap too.
            elle.cap_off = switch (scenario.kind_of(command_name).?) {
                .parallel_driver, .serial_driver, .singleton_driver, .anytime => false,
                else => true,
            };
            const resolved = system_read(init.arena.allocator()) catch null;
            var context = Context{
                .nodes = try Self.nodes_load(init.arena.allocator()),
                .scenario = scenario_name,
                .profile = if (resolved) |system| system.profile else "default",
                .init = init,
            };
            // What its operations looked like, said as the start ends (elle.operations_flush).
            defer elle.operations_flush();
            // A history at its cap (elle.history_size_max): the driver's work is done, not failed.
            // Not cataloged (assert_computed): a workload recording no history never reaches it,
            // and a cataloged sometimes never true fails the run.
            return handler(&context) catch |err| switch (err) {
                error.HistoryFull => {
                    sdk.assert_computed(.sometimes, true, "a driver ended at its history's cap", .{});
                    return;
                },
                else => return err,
            };
        }

        fn scenario_build(
            comptime definition: anytype,
            name: []const u8,
            scenario: *Scenario,
        ) bool {
            inline for (comptime std.meta.fieldNames(@TypeOf(definition.scenarios))) |field| {
                if (std.mem.eql(u8, field, name)) {
                    scenario.* = .{ .name = field };
                    @field(definition.scenarios, field)(scenario);
                    return true;
                }
            }
            return false;
        }

        /// The nodes of the running system, from schema.system_path; outside determinismo every
        /// node is on localhost.
        fn nodes_load(arena: std.mem.Allocator) !Nodes {
            const resolved = system_read(arena) catch null;
            var nodes: Nodes = undefined;
            inline for (field_names, field_types) |name, Field| {
                const found: ?Node = if (resolved) |s| blk: {
                    const entry = s.node(name) orelse break :blk null;
                    break :blk .{ .name = name, .address = try address_parse(entry.address) };
                } else .{ .name = name, .address = .{ 127, 0, 0, 1 } };
                if (Field == Node) {
                    @field(nodes, name) = found orelse return error.NodeMissing;
                } else {
                    @field(nodes, name) = found;
                }
            }
            return nodes;
        }

        fn describe_print(
            arena: std.mem.Allocator,
            io: std.Io,
            comptime definition: anytype,
        ) !void {
            var d: Describe = .{};
            try definition.describe(&d);
            const profiles = try arena.alloc(schema.Profile, d.count);
            for (d.profiles[0..d.count], profiles) |*source, *target| {
                target.* = try Self.profile_convert(arena, source);
            }
            const scenario_names = comptime std.meta.fieldNames(@TypeOf(definition.scenarios));
            comptime for (scenario_names) |name| {
                // `--scenario all` explores every scenario: one named so would never run alone.
                if (std.mem.eql(u8, name, "all")) @compileError("a scenario cannot be named " ++
                    "\"all\": --scenario all explores every scenario");
            };
            var scenarios: [scenario_names.len]schema.Scenario = undefined;
            inline for (scenario_names, 0..) |name, index| {
                const scenario = try arena.create(Scenario);
                assert(Self.scenario_build(definition, name, scenario));
                const commands = try arena.alloc(schema.Command, scenario.count);
                for (scenario.commands[0..scenario.count], commands) |entry, *command| {
                    command.* = entry.command;
                }
                scenarios[index] = .{
                    .name = name,
                    .commands = commands,
                    .faults = scenario.faults,
                    .clock_skip = scenario.clock_skip,
                    .pacing = scenario.pacing,
                    .nodes_down_max = scenario.nodes_down_max,
                    .quorum = scenario.quorum,
                    .quorum_link_delay_ms = scenario.quorum_link_delay_ms,
                    .quorum_link_loss_ppm = scenario.quorum_link_loss_ppm,
                    .quorum_recovery_ms = scenario.quorum_recovery_ms,
                    .min_drive_ms = scenario.min_drive_ms,
                    .drive_ms_max = scenario.drive_ms_max,
                    .ending_ms_max = scenario.ending_ms_max,
                    .snapshot_before_nodes = scenario.snapshot_before_nodes,
                    .parallel_max = scenario.parallel_max,
                };
            }
            // The program's host checks, each with where its records are.
            const check_names = if (@hasField(@TypeOf(definition), "checks"))
                comptime std.meta.fieldNames(@TypeOf(definition.checks))
            else
                &[_][]const u8{};
            comptime assert(check_names.len <= schema.checks_max);
            var checks: [check_names.len]schema.Check = undefined;
            inline for (check_names, &checks) |name, *check| {
                check.* = .{ .name = name, .file = schema.record_path(name) };
            }
            const description = schema.Description{
                .profiles = profiles,
                .scenarios = &scenarios,
                .checks = &checks,
            };
            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
            try description_write(&stdout.interface, description);
            try stdout.interface.flush();
        }

        fn profile_convert(arena: std.mem.Allocator, profile: *const Profile) !schema.Profile {
            var nodes: std.ArrayList(schema.Node) = .empty;
            inline for (field_names, field_types, 0..) |name, Field, index| {
                if (profile.specs[index]) |spec| {
                    var named: NodeSpec([]const u8) = undefined;
                    inline for (comptime std.meta.fieldNames(Spec)) |field| {
                        if (comptime std.mem.eql(u8, field, "after")) continue;
                        @field(named, field) = @field(spec, field);
                    }
                    const after = try arena.alloc([]const u8, spec.after.len);
                    for (spec.after, after) |dependency, *target| target.* = @tagName(dependency);
                    named.after = after;
                    try nodes.append(arena, try node_convert(arena, name, named));
                } else if (Field == Node) {
                    const message = "profile {s}: node {s} is not optional\n";
                    std.debug.print(message, .{ profile.name, name });
                    return error.NodeMissing;
                }
            }
            return .{
                .name = profile.name,
                .nodes = nodes.items,
                .explain = profile.explain,
                .retroactive = profile.retroactive,
                .epoch_seconds = profile.epoch_seconds,
            };
        }
    };
}

/// A node as the system description has it, from its spec (its dependencies named).
pub fn node_convert(arena: std.mem.Allocator, name: []const u8, spec: NodeSpec([]const u8)) !schema.Node {
    return .{
        .name = name,
        .source = .{
            .image = spec.image,
            .directory = spec.directory,
            .binary = spec.binary,
            .build = try build_with_coverage(arena, spec.build, spec.coverage),
        },
        .upgrade = if (spec.upgrade) |next| .{
            .image = next.image,
            .directory = next.directory,
            .binary = next.binary,
            .build = try build_with_coverage(arena, next.build, spec.coverage),
        } else null,
        .entrypoint = spec.entrypoint,
        .command = spec.command,
        .env = try env_with_coverage(arena, spec.env, spec.coverage),
        .workdir = spec.workdir,
        .user = spec.user,
        .ready = spec.ready,
        .after = spec.after,
        .faults = spec.faults,
        .memory_max_mib = spec.memory_max_mib,
        .privileged = spec.privileged,
        .ulimits = spec.ulimits,
        .crashes_known = spec.crashes_known,
        .writeback_s = spec.writeback_s,
        .exits_known = spec.exits_known,
        .exits_known_disk = spec.exits_known_disk,
        .supervised = spec.supervised,
        .panics_known = spec.panics_known,
        .log_failures = spec.log_failures,
        .spare = spec.spare,
        .knobs = spec.knobs,
        .antithesis_library = spec.antithesis_library,
        .once = spec.once,
        .volumes = spec.volumes,
        .hostname = spec.hostname,
        .aliases = spec.aliases,
    };
}

/// A description as `--describe` prints it: one JSON line.
pub fn description_write(writer: *std.Io.Writer, description: schema.Description) !void {
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    try std.json.Stringify.value(description, options, writer);
    try writer.writeAll("\n");
}

/// A node's build with its coverage set as the build argument DETERMINISMO_COVERAGE.
fn build_with_coverage(
    arena: std.mem.Allocator,
    build: ?schema.Build,
    coverage: schema.Coverage,
) !?schema.Build {
    const given = build orelse return null;
    const with = try env_with_coverage(arena, given.args, coverage);
    if (with.len == given.args.len) return given;
    var result = given;
    result.args = with;
    return result;
}

/// A node's environment with its coverage set as DETERMINISMO_COVERAGE (schema.Coverage).
fn env_with_coverage(
    arena: std.mem.Allocator,
    env: []const []const u8,
    coverage: schema.Coverage,
) ![]const []const u8 {
    if (coverage.include.len == 0 and coverage.exclude.len == 0) return env;
    var value: std.ArrayList(u8) = .empty;
    try value.appendSlice(arena, "DETERMINISMO_COVERAGE=");
    for (coverage.include, 0..) |prefix, index| {
        assert(prefix.len > 0 and prefix[0] != '-' and std.mem.indexOfScalar(u8, prefix, ',') == null);
        if (index > 0) try value.append(arena, ',');
        try value.appendSlice(arena, prefix);
    }
    for (coverage.exclude, 0..) |prefix, index| {
        assert(prefix.len > 0 and std.mem.indexOfScalar(u8, prefix, ',') == null);
        if (index > 0 or coverage.include.len > 0) try value.append(arena, ',');
        try value.append(arena, '-');
        try value.appendSlice(arena, prefix);
    }
    const result = try arena.alloc([]const u8, env.len + 1);
    @memcpy(result[0..env.len], env);
    result[env.len] = value.items;
    return result;
}

test env_with_coverage {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const plain = try env_with_coverage(arena, &.{"A=1"}, .{});
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    const set = try env_with_coverage(arena, &.{"A=1"}, .{
        .include = &.{ "org.apache.kafka.raft", "kafka.server" },
        .exclude = &.{"kafka.server.metadata"},
    });
    try std.testing.expectEqualStrings("DETERMINISMO_COVERAGE=org.apache.kafka.raft,kafka.server,-kafka.server.metadata", set[1]);
    const excluded = try env_with_coverage(arena, &.{}, .{ .exclude = &.{"vendor/"} });
    try std.testing.expectEqualStrings("DETERMINISMO_COVERAGE=-vendor/", excluded[0]);
}

fn system_read(arena: std.mem.Allocator) !schema.System {
    const fd = linux.open(schema.system_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoSystem;
    defer _ = linux.close(@intCast(fd));
    const buffer = try arena.alloc(u8, system_size_max);
    var size: u64 = 0;
    while (size < buffer.len) {
        const result = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) break;
        size += result;
    }
    return schema.parse(schema.System, arena, buffer[0..size]);
}

fn address_parse(text: []const u8) ![4]u8 {
    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10);
    }
    if (parts.next() != null) return error.BadAddress;
    return address;
}

/// det-nodes's own (guest/runtime/nodes.zig's arguments_max): SQLancer's command line, 37 words,
/// met the 32 this was (TiDB trial run 1526, every start aborting on the assertion).
const exec_arguments_max = 64;
/// The guest's hosts file: the runner, localhost and each node, a line each.
const hosts_size_max = 16 * 1024;

/// `name`'s address in a hosts file's text ("a.b.c.d name" lines), the last line naming it.
fn hosts_address(text: []const u8, name: []const u8) ?[4]u8 {
    var found: ?[4]u8 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const address_text = fields.next() orelse continue;
        while (fields.next()) |alias| {
            if (!std.mem.eql(u8, alias, name)) continue;
            var address: [4]u8 = undefined;
            var octets = std.mem.splitScalar(u8, address_text, '.');
            var count: usize = 0;
            while (octets.next()) |octet| : (count += 1) {
                if (count == 4) break;
                address[count] = std.fmt.parseInt(u8, octet, 10) catch break;
            } else if (count == 4) found = address;
        }
    }
    return found;
}

test hosts_address {
    const text = "127.0.0.1 localhost\n10.0.0.1 runner\n10.0.0.2 t1\n10.1.0.3 t2\n";
    try std.testing.expectEqual([4]u8{ 10, 1, 0, 3 }, hosts_address(text, "t2").?);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 2 }, hosts_address(text, "t1").?);
    try std.testing.expect(hosts_address(text, "t3") == null);
    try std.testing.expect(hosts_address(text, "t") == null);
}

const argument_size_max = 1024;

fn nodes_command(arguments: []const []const u8) !void {
    if ((try nodes_run(arguments, null, .stdout)).status != 0) return error.NodeCommandFailed;
}

/// What a command's capture takes: its standard output, or its standard error with it.
const Captured = enum { stdout, both };

/// Runs det-nodes with `arguments`; returns its exit status, and what `captured` names into
/// `capture` when given.
fn nodes_run(arguments: []const []const u8, capture: ?[]u8, captured: Captured) !Output {
    assert(arguments.len + 1 <= exec_arguments_max);
    var storage: [exec_arguments_max][argument_size_max]u8 = undefined;
    var argv: [exec_arguments_max:null]?[*:0]const u8 = @splat(null);
    argv[0] = nodes_binary;
    for (arguments, 1..) |argument, index| {
        argv[index] = try std.fmt.bufPrintSentinel(&storage[index], "{s}", .{argument}, 0);
    }
    const environment = [_:null]?[*:0]const u8{"PATH=/opt/determinismo/bin:/usr/bin:/bin"};
    var pipe: [2]linux.fd_t = .{ -1, -1 };
    if (capture != null) {
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        if (capture != null) _ = linux.dup2(pipe[1], 1);
        if (capture != null and captured == .both) _ = linux.dup2(pipe[1], 2);
        _ = linux.execve(nodes_binary, &argv, &environment);
        linux.exit_group(127);
    }
    var size: usize = 0;
    if (capture) |buffer| {
        _ = linux.close(pipe[1]);
        defer _ = linux.close(pipe[0]);
        var drain: [4096]u8 = undefined;
        while (true) {
            const target = if (size < buffer.len) buffer[size..] else drain[0..];
            const result = linux.read(pipe[0], target.ptr, target.len);
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            if (size < buffer.len) size += result;
        }
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    const bits: u32 = @bitCast(status);
    const code: u8 = if (bits & 0x7f == 0)
        @intCast((bits >> 8) & 0xff)
    else
        @intCast(128 + (bits & 0x7f));
    return .{ .status = code, .output = if (capture) |buffer| buffer[0..size] else "" };
}

test "scenarios and profiles are typed" {
    const Nodes = struct { redis: Node, cache: ?Node };
    const S = System(Nodes);
    const handlers = struct {
        fn noop(_: *S.Context) !void {}
        fn bank(s: *S.Scenario) void {
            s.setup("accounts", noop);
            s.parallel_driver("transfer", noop);
        }
    };
    var scenario: S.Scenario = undefined;
    const definition = .{ .describe = undefined, .scenarios = .{ .bank = handlers.bank } };
    try std.testing.expect(S.scenario_build(definition, "bank", &scenario));
    try std.testing.expectEqual(@as(u32, 2), scenario.count);
    try std.testing.expect(scenario.find("transfer") != null);
    var describe: S.Describe = .{};
    const profile = try describe.profile("default");
    profile.node(.redis, .{ .image = "redis:7", .after = &.{.cache} });
    try std.testing.expect(profile.specs[1] == null);
}
