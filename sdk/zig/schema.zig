// SPDX-License-Identifier: MIT
//! The system description, schema version 1 (ARCHITECTURE.md §10): what a test program's
//! `--describe` prints, and the resolved form determinismo freezes into the guest disk
//! (/det/system.json) and the run record.
//!
//! A test program is anything that answers two commands:
//!   <program> --describe                 print a `Description` as JSON on stdout (on the host)
//!   <program> run <scenario> <command>   run one command of a scenario (in the guest)
//! so any language can describe a system and its tests; SDKs only make it convenient.
const std = @import("std");
const assert = std.debug.assert;

pub const version: u32 = 1;
pub const nodes_max = 15; // Plus disk 0, within the VMM's 16 disks.
pub const scenarios_max = 64;
pub const commands_max = 64;
/// Node names become host names and interface names ("d-<name>", at most 15 bytes).
pub const node_name_size_max = 12;
pub const runner_name = "runner";
pub const runner_address = [4]u8{ 10, 0, 0, 1 };

pub const Description = struct {
    schema: u32 = version,
    profiles: []const Profile,
    scenarios: []const Scenario,
    checks: []const Check = &.{},
};

/// A check the host runs on what a timeline recorded: the test program's own (System.main's
/// `.checks`), run on the host as `<program> check <name> <scenario>` with the records its
/// commands made (`sdk.record`), which the composer streams out when the timeline ends. The
/// assertions the check makes are properties of the timeline, at its end: the host runs it on
/// all its cores, the guest pays nothing, and a replay sends the same records, so it gets the
/// same verdict. (sdk.elle.check is one: Jepsen's Elle on a transaction history.)
pub const Check = struct {
    /// Its name in the program's `.checks`.
    name: []const u8,
    /// The records, in the runner (record_path(name)).
    file: []const u8,
};
pub const checks_max = 8;

/// Where records are appended: a tmpfs the runner and every node write to (through their
/// /opt/determinismo), so that a program running in a node records as one in the runner does.
pub const records_directory = "/opt/determinismo/records/";

/// Where the runner takes commands from programs in nodes (det-runner, libdeterminismo's
/// det_runner): in the tmpfs they all see.
pub const runner_socket = records_directory ++ ".runner";

/// The built-in properties that count a system's known bugs, one per known crash, exit or panic
/// (guest/runtime/crash_names.zig): each passes when met. A count of a known bug, never a mark of
/// the workload's progress, so never "rarely true" (src/report.zig, infra/host/hunt-queue.sh).
pub const known_crash_prefix = "a process crash the system is known to have: ";
pub const known_exit_prefix = "an exit the system is known to make: ";
pub const known_panic_prefix = "a panic the system is known to have: ";
pub const known_log_prefix = "a failure the system is known to log: ";
pub const known_prefixes = [_][]const u8{ known_crash_prefix, known_exit_prefix, known_panic_prefix, known_log_prefix };

/// Fault kinds by their field names, "+restart,-partition" (a bare kind is "+"): each turned on,
/// or off with "-" (explore's --faults, a Compose service's `determinismo.faults` label).
pub fn faults_change(faults: *Faults, list: []const u8) error{UnknownFaultKind}!void {
    var kinds = std.mem.tokenizeScalar(u8, list, ',');
    kinds: while (kinds.next()) |kind_text| {
        const trimmed = std.mem.trim(u8, kind_text, " ");
        const taken = std.mem.startsWith(u8, trimmed, "-");
        const kind = std.mem.trimStart(u8, trimmed, "+-");
        const info = @typeInfo(Faults).@"struct";
        inline for (info.field_names, info.field_types) |field, Type| {
            if (Type == bool and std.mem.eql(u8, field, kind)) {
                @field(faults, field) = !taken;
                continue :kinds;
            }
        }
        std.debug.print("[determinismo] no fault kind {s}\n", .{kind});
        return error.UnknownFaultKind;
    }
}

/// Every fault kind off (explore's --no-faults, a Compose service's `determinismo.no-faults`).
pub fn faults_none(faults: *Faults) void {
    const info = @typeInfo(Faults).@"struct";
    inline for (info.field_names, info.field_types) |field, Type| {
        if (Type == bool) @field(faults, field) = false;
    }
    faults.custom = &.{};
}

test faults_change {
    var faults: Faults = .{};
    try faults_change(&faults, "+restart, crash,-partition");
    try std.testing.expect(faults.restart and faults.crash and !faults.partition);
    try std.testing.expectError(error.UnknownFaultKind, faults_change(&faults, "+teleport"));
    faults_none(&faults);
    try std.testing.expect(!faults.restart and !faults.pause and !faults.partition);
}

/// A text of a node's output that is a failure (Node.log_failures): the system's own report of a
/// bug it survived, which no language property sees (not at a line's start, nor ending the
/// process): TiDB's "panic in the recoverable goroutine".
pub const LogFailure = struct {
    /// Within a line, anywhere in it.
    text: []const u8,
    /// The property a line holding it fails (an always): its message.
    property: []const u8,
    /// Texts within the same line that make it a known bug's (its place): counted instead
    /// ("a failure the system is known to log: <known>", a sometimes), as panics_known's are.
    known: []const []const u8 = &.{},
};

/// Where `sdk.record(name, ...)` appends.
pub fn record_path(comptime name: []const u8) [:0]const u8 {
    return records_directory ++ name ++ ".jsonl";
}

/// `record_path` for a name known at run time (libdeterminismo's callers').
pub fn record_path_format(buffer: []u8, name: []const u8) ![:0]const u8 {
    if (!check_name_valid(name)) return error.InvalidCheckName;
    return std.fmt.bufPrintSentinel(buffer, records_directory ++ "{s}.jsonl", .{name}, 0);
}

/// A check's name is a file name in `records_directory`.
pub fn check_name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

/// The resolved system as test programs read it, in the runner and every node (their
/// /opt/determinismo): /det/system.json, bound there at boot.
pub const system_path = "/opt/determinismo/system.json";

/// One way to build the system under test.
pub const Profile = struct {
    name: []const u8,
    nodes: []const Node,
    /// A command that turns the system's logs up, run in the guest at a moment (`det-nodes exec
    /// <node> ...`): causality's explanation runs it in futures inside a jump (its
    /// `explain_exec`, serve's default for the run's analyses).
    explain: ?[]const u8 = null,
    /// Retroactive logging: output lines with one of these texts are left out of an
    /// exploration's events (they still count: events hash, behaviors, the logging limit) and
    /// written by a replay of the timeline. Explore's `--retroactive` adds to them.
    retroactive: []const []const u8 = &.{},
    /// Commands run at each failing property's first counterexample once a run under serve
    /// ends (Antithesis's debugging automation); a run's request adds to them.
    automations: []const Automation = &.{},
    /// The guest's wall clock at boot, Unix seconds: null for the day after the system's newest
    /// image was made (2026-01-01 when older), so the images' data (an initial catalog snapshot,
    /// certificates) is never from the guest's future. Explore's `--epoch` wins.
    epoch_seconds: ?u64 = null,
};

/// What of a node's instrumented code reports coverage and is a point for thread pausing: names
/// under an `include` prefix (every name when there is none) and under no `exclude` prefix. The
/// names are each SDK's own: Java classes (`org.apache.kafka.raft`), Go packages
/// (`go.etcd.io/raft/v3`), Python files, and for C, C++, Rust and Zig source files (known when the
/// binary is in the image's /symbols, or its own DWARF for Zig). The node's processes get it as
/// DETERMINISMO_COVERAGE (`include,...,-exclude,...`), which a Compose project sets itself; it
/// narrows what the build instrumented, at no rebuild (an excluded block still calls the SDK,
/// which returns at once: to take a part's cost out entirely, leave it out of the build).
pub const Coverage = struct {
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
};

pub const Node = struct {
    name: []const u8,
    source: Source,
    /// Its next release (an image or a build), for upgrade tests (FoundationDB's restarting
    /// tests): `det-nodes upgrade <node> next` (the SDK's Node.upgrade) stops it gracefully and
    /// starts it on this root filesystem with its writable layer kept (its data), `base` back on
    /// its own (a downgrade). Its command and environment are merged with this image's as the
    /// node's are with its own image's.
    upgrade: ?Source = null,
    /// Replaces the image's entrypoint (null keeps it).
    entrypoint: ?[]const []const u8 = null,
    /// The command to run, after the entrypoint; null keeps the image's.
    command: ?[]const []const u8 = null,
    /// `NAME=value` entries, added to (and overriding) the image's environment.
    env: []const []const u8 = &.{},
    workdir: ?[]const u8 = null,
    /// A numeric `uid[:gid]`; null keeps the image's user.
    user: ?[]const u8 = null,
    ready: ?Ready = null,
    /// Nodes that must be ready before this one starts.
    after: []const []const u8 = &.{},
    faults: Faults = .{},
    /// The memory its processes may use (cgroup memory.max); past it, the kernel reclaims and
    /// then kills one of them. Null: no limit beyond the VM's memory.
    memory_max_mib: ?u32 = null,
    /// /sys and the node's cgroups writable, as for a privileged container: for nodes that run
    /// containers themselves (K3s, Docker in Docker).
    privileged: bool = false,
    /// Process limits of its processes and of commands run in it (Compose's `ulimits`); null:
    /// Docker's (open files 1048576, the kernel's for the rest).
    ulimits: ?[]const Ulimit = null,
    /// Antithesis's native library at /usr/lib/libvoidstar.so (determinismo's): Antithesis's
    /// SDKs then send through it, and instrumented programs report coverage. Imported Compose
    /// projects have it, as on Antithesis. Off by default: a static program with Antithesis's
    /// Go SDK (K3s, through etcd) cannot load a library, and the SDK stops it when one is there.
    antithesis_library: bool = false,
    /// Processes (by command name) whose crashes the system is known to have: such a crash is
    /// counted ("a process crash the system is known to have: <name>", a sometimes) instead of
    /// failing "no process crashes: <name>" in every timeline, which left a run's failing
    /// timelines saying nothing (YugabyteDB 1.3.1's YSQL backends crash on their way out: run
    /// 77, every timeline). Another process's crash still fails.
    crashes_known: []const []const u8 = &.{},
    /// A drawn flusher's window, in seconds. The guest writes nothing back unasked (a power loss
    /// drops every write never synced, however old). With a window, this node's flusher is on or
    /// off in drawn stretches (nodes.zig writeback_loop): on, its disk is synced every window, as a
    /// host's flusher writes dirty data back within ~30 s; off, strict. Only for systems a strict
    /// disk bricks in every timeline (a broker's feature flags and tables, after power
    /// losses at any age), so the rest of them is tested while their bug still shows in the
    /// off stretches. Null: strict.
    writeback_s: ?u32 = null,
    /// Exits the system is known to make, by what the node wrote last (a substring of its
    /// output's last 64 KB, of the exiting start's output alone): such an exit is counted ("an exit the system is known to make:
    /// <text>", a sometimes) instead of failing "no unexpected container exits" in nearly every
    /// timeline (ZooKeeper's servers that lost power before their first snapshot reached the
    /// disk refuse to start: ZOOKEEPER-3220). Another exit still fails.
    exits_known: []const []const u8 = &.{},
    /// Exits known only when the node's disk failed since its program started (a disk fault's
    /// errors or corrupted reads, under way or healed since: a fail-stop may end after the heal,
    /// as Kafka's orderly shutdown on a failed log directory does, trial run 1783), matched as
    /// exits_known: a storage engine's fail-stop on what its disk gave it (MongoDB's WiredTiger
    /// refusing a file its corrupted reads made unreadable, hunt run 1734). The same text at a
    /// start with no disk fault since still fails: a file torn by a power loss is a durability
    /// bug, not a fault's doing.
    exits_known_disk: []const []const u8 = &.{},
    /// Its supervisor starts it again after it exits on its own (any status but 0, not killed by a
    /// signal), as systemd's Restart=on-failure, a Compose restart policy or a Kubernetes pod do:
    /// 1 s later, the wait doubling up to 60 s while its starts keep ending within a minute. Its
    /// exit is judged as before (failing "no unexpected container exits", or counted as a known
    /// one). Off: it stays down, as a process with no supervisor does (Kafka's brokers exit by
    /// design when they cannot register with the quorum: hunt run 1928, one left down through a
    /// whole quiet window, the transaction log's only eligible leader, no InitProducerId).
    supervised: bool = false,
    /// Panics the system is known to have, by a text of the lines after the panic's (its stack:
    /// the next 16): such a language property's line (a Go panic or fatal error, a Rust panic, a
    /// Java uncaught exception) is counted ("a panic the system is known to have: <text>", a
    /// sometimes) instead of failing it (a system's servers panicking in a leadership check on a
    /// nil node while a shard moves to one restarting: every timeline that moves shards under
    /// restarts). Another panic still fails; the panic's line alone does not name its
    /// cause (a nil dereference anywhere).
    panics_known: []const []const u8 = &.{},
    /// Lines of its output that are failures (LogFailure): a line holding one's text fails its
    /// property, unless it holds one of its known texts too.
    log_failures: []const LogFailure = &.{},
    /// Not started with the others (its root, address and disk ready all the same): a driver
    /// starts it, as a member that joins later (Jepsen's membership changes). Faults leave it
    /// alone while it is not running.
    spare: bool = false,
    /// Settings drawn as it starts (Knob: FoundationDB's randomized knobs).
    knobs: []const Knob = &.{},
    /// A one-shot (Compose's `service_completed_successfully`: a setup step, etcd_demo's `init`
    /// making its members' directories): the nodes after it start once its processes ended, and
    /// it is never started again, no faults (none of Faults), no supervisor. Its exit is judged
    /// as any ("no unexpected container exits": 0 is expected).
    once: bool = false,
    /// What it sees beyond its image (Volume), at most volumes_max.
    volumes: []const Volume = &.{},
    /// Its hostname (sethostname, /etc/hostname) when not its name: Compose's `hostname`, or its
    /// service's name when that is no node name (the Kafka demo's data_generator).
    hostname: ?[]const u8 = null,
    /// Other names every node resolves to it (/etc/hosts), at most aliases_max, each a hostname
    /// (alias_valid): a Compose service's own name when its node's differs, its container_name.
    aliases: []const []const u8 = &.{},
};

pub const aliases_max = 8;
pub const alias_size_max = 63;

/// A hostname: 1-63 letters, digits, '.', '_' or '-' (Compose's service names, which DNS-minded
/// tools take as they are).
pub fn alias_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > alias_size_max) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// A directory or file a node sees beyond its image (Compose's `volumes`), at `path`, one of
/// `shared` and `host`.
pub const Volume = struct {
    /// Where the node sees it, an absolute path.
    path: []const u8,
    /// A directory shared by every node naming it (a name of volume_name_valid), kept in the
    /// guest's memory beside the nodes' disks: Compose's bind mount of a host directory, or a
    /// named volume. What one node writes there the others see at once, and a node's restart,
    /// crash, power loss or wipe leaves it as a container's leaves the host's directory (Docker's
    /// and Antithesis's: only a node's own disk loses what it had not synced). Made empty and
    /// root's (0755) as the first node using it starts, as Docker makes a missing bind source.
    shared: ?[]const u8 = null,
    /// A file or directory of the host (relative to the run's working directory), copied into the
    /// node's image at `path` as the run is prepared (Compose's bind mount of a project's own
    /// file: a configuration, TiKV's `./pd.toml:/pd.toml:ro`): the node's own copy.
    host: ?[]const u8 = null,
    /// Mounted read-only (a `shared` one; a `host` copy is the node's own either way).
    read_only: bool = false,
};
pub const volumes_max = 16;
pub const volume_name_size_max = 64;

/// A shared volume's name: 1-64 letters, digits, `.`, `_` or `-`, not `.` or `..` (a directory
/// of the guest's /run/det/volumes).
pub fn volume_name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > volume_name_size_max) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

test volume_name_valid {
    try std.testing.expect(volume_name_valid("tmp-etcddata0"));
    try std.testing.expect(volume_name_valid("data_1.x"));
    try std.testing.expect(!volume_name_valid(""));
    try std.testing.expect(!volume_name_valid(".."));
    try std.testing.expect(!volume_name_valid("a/b"));
}

/// A setting drawn as a node starts (FoundationDB's knobs, docs/FOUNDATIONDB.md): one of its
/// choices, each one or more `NAME=value` environment entries added to the node's, decided by
/// name (`knob.<name>`: steered and replayed as any decision) and said in a `node_knob` event.
/// A system's documented, production-safe settings only, never an unsafe mode: what its
/// users may run, so that a failure under one is theirs too. Execs in the node do not get them
/// (a start's environment, not the container's).
pub const Knob = struct {
    name: []const u8,
    choices: []const []const []const u8,
    scope: Scope = .start,

    pub const Scope = enum {
        /// Drawn again at each start of the node: a restart may run it with another.
        start,
        /// Drawn at the first start of a node naming it, the same for every start of every
        /// node after (a setting members must agree on: timeouts, a cluster-wide mode).
        run,
    };
};

pub const knobs_max = 16;
pub const knob_entries_max = 8;

/// Whether a node's knobs are well formed: named (a decision name's characters), each with a
/// choice or more, each choice's entries `NAME=value`, within the limits.
pub fn knobs_valid(knobs: []const Knob) bool {
    if (knobs.len > knobs_max) return false;
    for (knobs, 0..) |knob, index| {
        if (knob.name.len == 0 or knob.name.len > 48) return false;
        for (knob.name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
        for (knobs[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, knob.name)) return false;
        if (knob.choices.len == 0) return false;
        for (knob.choices) |choice| {
            if (choice.len == 0 or choice.len > knob_entries_max) return false;
            for (choice) |entry| {
                const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
                if (equals == 0) return false;
            }
        }
    }
    return true;
}

/// Where a node's root filesystem comes from: exactly one field is set.
pub const Source = struct {
    /// An OCI image reference, pinned to a digest when resolved.
    image: ?[]const u8 = null,
    /// A directory on the host, used as the root filesystem.
    directory: ?[]const u8 = null,
    /// A static executable on the host, alone in an otherwise empty root filesystem.
    binary: ?[]const u8 = null,
    /// An image built on the host from a Dockerfile, then used like `image`.
    build: ?Build = null,

    pub fn kind_count(source: Source) u32 {
        return @as(u32, @intFromBool(source.image != null)) +
            @intFromBool(source.directory != null) + @intFromBool(source.binary != null) +
            @intFromBool(source.build != null);
    }
};

/// A build context directory and the Dockerfile in it (relative to the context).
pub const Build = struct {
    context: []const u8,
    dockerfile: []const u8 = "Dockerfile",
    /// `NAME=value` build arguments (the Dockerfile's ARGs). A node's coverage set is one too,
    /// DETERMINISMO_COVERAGE (schema.Coverage): a build that instruments reads it (Go's
    /// determinismo-toolexec), so what the set leaves out is not instrumented at all.
    args: []const []const u8 = &.{},
};

/// The node is ready once this succeeds (from the runner).
pub const Ready = struct {
    /// A port that accepts a connection once the node is ready (0: `command` instead).
    tcp: u16 = 0,
    /// Or a command run in the node (as `docker exec`, its output discarded) every second until
    /// it exits 0: Compose's `healthcheck` test, for a service another waits on with
    /// `service_healthy` (Kafka's `kafka-cluster.sh cluster-id`, PostgreSQL's `pg_isready`).
    command: ?[]const []const u8 = null,
    /// How long it may take, in seconds of virtual time: a node that joins its cluster before
    /// it listens (Cassandra's CQL port, after its ring delay alone) needs more than a minute.
    timeout_s: u32 = 60,
};

/// A process limit, by Docker's name ("nofile", "memlock", "nproc", ...: ulimit_resource), set
/// before a node's command runs. `unlimited` (RLIM_INFINITY) for no limit.
pub const Ulimit = struct {
    name: []const u8,
    soft: u64,
    hard: u64,

    pub const unlimited = std.math.maxInt(u64);
};
pub const ulimits_max = 16;

/// The Linux resource number (RLIMIT_*) of a Docker ulimit name; null for another name.
pub fn ulimit_resource(name: []const u8) ?u32 {
    const names = [_][]const u8{
        "cpu",     "fsize", "data",  "stack",      "core",     "rss",  "nproc",  "nofile",
        "memlock", "as",    "locks", "sigpending", "msgqueue", "nice", "rtprio", "rttime",
    };
    for (names, 0..) |known, resource| {
        if (std.mem.eql(u8, name, known)) return @intCast(resource);
    }
    return null;
}

test ulimit_resource {
    try std.testing.expectEqual(@as(?u32, 7), ulimit_resource("nofile"));
    try std.testing.expectEqual(@as(?u32, 8), ulimit_resource("memlock"));
    try std.testing.expectEqual(@as(?u32, 15), ulimit_resource("rttime"));
    try std.testing.expectEqual(@as(?u32, null), ulimit_resource("files"));
}

/// What the fault injector may do to the node.
pub const Faults = struct {
    /// Freeze all its processes for a while.
    pause: bool = true,
    /// Cut all its network links for a while.
    isolate: bool = true,
    /// Cut single links between it and other nodes for a while.
    partition: bool = true,
    /// Kill it and start it again (its files survive, its memory does not).
    restart: bool = false,
    /// Kill it as a power loss would and start it again: its disk keeps what was synced
    /// (fsync, sync, O_SYNC) and loses the rest (Antithesis's restarts that keep "durably synced
    /// filesystem changes"). The node's writable layer is then an ext4 disk of its own. With
    /// it, crashes at durability points too: at one of its fsyncs (or sync writes), before its
    /// data reaches the disk or just after.
    crash: bool = false,
    /// At half of its power losses (crash, crash at a durability point, outage), part of what
    /// it had not synced reaches its disk anyway, as a host's flusher may have written it back
    /// before the power went (LazyFS's torn writes): of a drawn subset of its files, pages over
    /// blocks already allocated in any order, a file's new data as an ascending run (the
    /// flusher's order: never a hole before a kept page), and half the time the journal
    /// committed after them. Off, a power loss keeps exactly what was synced (Antithesis's).
    partial_persistence: bool = true,
    /// Hold its fsyncs (and sync writes) for a while, one in a few, while its other threads
    /// run: the interleavings around persisting (a goroutine waiting on a store write while
    /// another acts on what the store says).
    sync_stall: bool = true,
    /// Kill it and start it fresh from its image: everything it wrote is gone (Antithesis's
    /// restarts that "lose all of their modified data").
    wipe: bool = false,
    /// Take part in outages: several nodes at once losing power (crash) or killed (restart),
    /// a datacenter's power or a rack's. Off, it is in no outage; its own restarts and crashes
    /// may still overlap another node's (a scenario's `nodes_down_max` caps that).
    /// A system that durably promises only what was synced (Cassandra's periodic commitlog:
    /// "synced every commitlog_sync_period") loses acknowledged writes when every replica dies
    /// within that window, by its own contract: such a profile leaves outages out (Cassandra's
    /// runs 396, 936, 944).
    outage: bool = true,
    /// Stop it gracefully (SIGTERM, then a kill after a grace period of 3 s) and start it again
    /// (Antithesis's node stop, beside the kill that restart is). A heal waits for its grace.
    stop: bool = false,
    /// Make its disk fail for a while: every I/O failing, writes failing, writes acknowledged
    /// and never stored, reads corrupted, or slow I/O. The node's writable layer is then an
    /// ext4 disk of its own (as with crash). An exit while the disk fails is expected; at the
    /// fault's end a node that exited, or whose filesystem gave up (read-only), starts again
    /// with its disk mounted afresh, as an operator would reboot it; so does one that ends of
    /// itself later in the same start (a fail-stop still under way as its disk healed: Kafka's
    /// shutdown on a failed log directory), a second after its end, while faults run and up to
    /// 10 s into their stop.
    disk: bool = false,
    /// Whether its failing disk may acknowledge writes and never store them (a lying disk or
    /// cache). Off where the workload judges durability: a commit acknowledged after its sync
    /// and lost to such a disk is no system's fault (ParticleDB's smoke run 332). Its other
    /// failures leave what is stored intact, so durability stays judgeable under them: a
    /// corrupted read taken for the end of a log (Jepsen's ParticleDB #108, #112) loses commits.
    disk_lost_writes: bool = true,
    /// A restart (restart, crash, wipe, stop) may give it a new address (Antithesis's
    /// "Restarted nodes may change IP addresses upon rejoining the network"): every hosts file
    /// then names it there; a peer that kept its old address loses it. Imported Compose
    /// projects have it; test programs whose drivers hold `Node.address` leave it off.
    new_address: bool = false,
    /// While it is down after a restart, crash, wipe, stop or outage (half of them, drawn), its
    /// name is left out of the other nodes' hosts files until it starts again: Kubernetes's
    /// headless services publish ready pods only (`publishNotReadyAddresses` off, the default),
    /// so a peer read by name stops resolving (Typesense #2927: its leader shrank the cluster to
    /// the peers listed before such a name). The runner's hosts file keeps every name.
    names_follow_liveness: bool = false,
    /// Degrade single links, in one direction, for a while: delay and loss, duplication,
    /// corruption, reordering or congestion.
    degrade: bool = true,
    /// Whether link faults (isolate, partition, degrade, partitions into groups, clogs) may
    /// reach its link with the runner (the test program's drivers). Off for a node that stands
    /// for the test's own client library, as Jepsen's clients live in the test process: its
    /// links to the servers are faulted (a commit delayed on its way to the coordinator), the
    /// drivers' calls into it are not.
    runner_links: bool = true,
    /// Limit its CPU (a share of one CPU) for a while.
    throttle: bool = true,
    /// Skew its realtime clock for a while, forward or back, 1 ms to 10 s (Jepsen's clock bumps;
    /// one in four strobes, coming and going every 10 ms to a second): its CLOCK_REALTIME apart
    /// from the other nodes', the monotonic clock untouched.
    /// For systems ordering by wall clocks (hybrid logical clocks, leases, timestamps). Off by
    /// default: some stop a node on purpose past their maximum offset.
    clock_skew: bool = false,
    /// The largest clock skew, in milliseconds (at least 10): below a system's documented
    /// maximum offset when its safety assumes one (YugabyteDB's and CockroachDB's 500 ms), so
    /// that what it then does wrong is a bug.
    clock_skew_ms_max: u32 = 10_000,
    /// Stop one of its processes (SIGSTOP) for a while.
    process_pause: bool = true,
    /// Draw its threads' scheduling for a while: at one scheduling point in a few, a woken
    /// thread runs before its waker goes on (or not), a tick preempts the running thread, a
    /// random runnable thread runs next. Interleavings inside its processes (a check-then-act
    /// between threads, a callback racing its registration), no instrumentation needed.
    interleave: bool = true,
    /// Kill one of its processes other than its main one (SIGKILL), as a crash its supervisor
    /// must recover from (a worker, a pod's process under kubelet): one running 5 s at least
    /// (a start script's helper is not a worker: Cassandra's `java -version`).
    process_kill: bool = false,
    /// When not empty, the processes process_kill may kill: those whose command name (comm,
    /// 15 characters at most) is one of these. A system's own servers, not what they spawn and
    /// handle the death of themselves (a PostgreSQL backend killed makes its postmaster restart
    /// every backend, by design: YugabyteDB's YSQL), nor the node's scaffolding (a supervising
    /// shell killed leaves its server unsupervised; a start script's helper killed under set -e
    /// ends the script, the node down for good: Dgraph's and Scylla's first hunts).
    process_kill_names: []const []const u8 = &.{},
    /// Deliver one of its processes a signal it catches, among those a server meets in its
    /// ordinary life with no one meaning anything by it (SIGCHLD, SIGURG, SIGWINCH, SIGPIPE): the
    /// system calls its handlers interrupt return EINTR where the handler was installed without
    /// SA_RESTART, as Antithesis's "make rare events common" for code we cannot edit (YugabyteDB's
    /// tablet servers abort on waitpid's EINTR, #34681). A signal it does not catch is never
    /// sent (its default would ignore it, or end the process: no interruption to test).
    signals: bool = false,
    /// Fail one of its system calls in a few, for a while, with an error its manual allows
    /// whatever the descriptor, as a kernel under pressure returns them: openat, accept, accept4
    /// and socket out of descriptors (EMFILE, ENFILE), clone and clone3 out of processes
    /// (EAGAIN), mmap out of memory (ENOMEM), fsync, fdatasync, fallocate, rename, renameat,
    /// renameat2, mkdir and mkdirat out of space or failing I/O (ENOSPC, EIO). The kernel's own
    /// fault injection (fail_function), for the node's tasks alone. Antithesis's "make rare
    /// events common" for code we cannot edit; a system that exits on such an error fails
    /// "no unexpected container exits", so a workload turns this on with its exits in mind.
    syscall_errors: bool = false,
    /// Fail one of its reads or writes of its disk's files in a few, for a while, before any
    /// data moves: ENOSPC, EDQUOT or EIO for writes, EIO for reads, as a full or failing disk
    /// returns them; or shorten one of its buffered writes in a few (part of what was asked
    /// written and returned). Guest kernel hooks at every read and write of a regular file and
    /// in ext4's writes; files on the node's own disk alone, never the image's. A node without a
    /// disk has none to fail.
    file_errors: bool = false,
    /// Kubernetes pods run in it (`explore --kubernetes`, kubernetes.zig): faults also act on one
    /// of its pods at a time, as Antithesis's on a cluster's pods: frozen, killed (kubelet starts
    /// its containers again), cut off, or its network degraded (in the pod's own namespace).
    pods: bool = false,
    /// Commands in the node (an absolute path, then arguments, split at spaces: no shell) that
    /// the fault injector runs at random times, as Antithesis's custom faults: calling an admin
    /// API, forcing a compaction, a failover. They can draw from the SDK's randomness.
    custom: []const []const u8 = &.{},
};

pub const Scenario = struct {
    name: []const u8,
    commands: []const Command,
    /// Where the commands run: null for the test program in the runner, or a node whose
    /// filesystem holds them (`Command.path`), as with Antithesis test templates, or the program
    /// itself (`program`).
    node: ?[]const u8 = null,
    /// The test program's path inside `node`: commands run there as `<program> run <scenario>
    /// <command>`, for a program whose language the runner lacks (a JVM's: libdeterminismo, with
    /// sdk/clojure's determinismo.workload). Its commands have no `path`.
    program: ?[]const u8 = null,
    /// Whether the fault injector runs during the driver phase.
    faults: bool = true,
    clock_skip: bool = false,
    /// How the fault injector paces its faults.
    pacing: Pacing = .{},
    /// At most this many nodes down at once (killed, powered off, stopped, wiped: their own faults
    /// overlap otherwise, one node's restart beside another's); 0, no cap. For a system whose
    /// claim covers a minority's failures (Iggy's `replicated` durability: one replica at a time).
    nodes_down_max: u32 = 0,
    /// The nodes whose majority the system needs to serve (its voters): when set, a fault starts
    /// only if, with it, a majority of them stays unfaulted, linked to each other (no cut, no link
    /// losing 1% or delayed 50 ms), and one of them reachable from the runner; kinds whose
    /// reach is not known before they start (outages, swizzles, clock skips, custom faults) are
    /// left out. For latency bounds (FoundationDB's LowLatency): a system claiming availability
    /// with a minority down answers within its bound throughout. Empty: no cap.
    quorum: []const []const u8 = &.{},
    /// What the quorum cap counts as a degraded link (one clearly worse than the baseline's 2 ms
    /// and 0.1%): delaying this long or more...
    quorum_link_delay_ms: u32 = 50,
    /// ... or losing this many packets in a million or more (10,000: 1%).
    quorum_link_loss_ppm: u32 = 10_000,
    /// How long after its fault ends a node is not counted in the quorum (restarting, rejoining
    /// its cluster): a system slower to rejoin sets more.
    quorum_recovery_ms: u32 = 15_000,
    /// Before an eventually command the drivers run at least a drawn time since they began, a
    /// tenth of this up to it, or until they end (det-composer's): null for its default (10 s),
    /// 0 none. Explore's --min-drive overrides it.
    min_drive_ms: ?u32 = null,
    /// The driver phase's length in virtual time, drawn (det-composer's `composer.drive_ms`, a
    /// named decision: this halved 0 to 6 times, then between that half and it), drivers started
    /// until it passed: a timeline's length no longer follows how slow its commands are (rqlite's
    /// 61 starts of 80-140 s membership steps made 2,000 s timelines). Null: a drawn number of
    /// starts (4 to 63). Explore's --timeline overrides it.
    drive_ms_max: ?u32 = null,
    /// The ending's command (finally or eventually) runs at most this long in virtual time, then
    /// is killed and "an ending command finishes within its window" fails: a system that never
    /// recovers holds no timeline for hours of retries (det-composer's; null for its default,
    /// 20 min).
    ending_ms_max: ?u32 = null,
    /// The setup snapshot taken before the nodes start, not after the setup command: each timeline
    /// starts the nodes and runs the setup itself. What a node's first start draws
    /// (`$DETERMINISMO_DRAW`, the drawn flusher's first window) and what the setup decides are
    /// then the timeline's own, not the same in all of a run's (trial run 1214: a first start's
    /// draw kept two of a three-server cluster's servers on a bug's path in every timeline). Each timeline
    /// pays for the nodes' start and the setup.
    snapshot_before_nodes: bool = false,
    /// The most drivers running at once: the composer draws 1, 2, 4, ... up to this (its
    /// default, 32, when null). For drivers that cost a process each, a JVM's, in a guest with
    /// the system's own JVMs beside them.
    parallel_max: ?u32 = null,
    /// Files in the scenario's test template named as commands that cannot run (Antithesis's
    /// "Invalid commands found"): the composer fails `always "test templates hold only valid
    /// commands"` with each.
    invalid: []const InvalidCommand = &.{},
};

/// A command run at a failing property's first counterexample when the run ends (Antithesis's
/// debugging automation: what one would run there by hand, run for every run, its output beside
/// the failure): serve replays the failing timeline to the moment and runs it there, as the
/// Logs view's "Run at this moment" does.
pub const Automation = struct {
    /// The property it runs for (its message): null for every failing one with a moment (a
    /// `sometimes` never true has none).
    property: ?[]const u8 = null,
    /// In the runner at the moment; in a node through `det-nodes exec <node> <command>`.
    exec: []const u8,
    /// This long (virtual time) before the failure.
    rewind_ms: u64 = 0,
};

/// A file in a test template with a command's prefix that cannot run, and why.
pub const InvalidCommand = struct { path: []const u8, why: []const u8 };

/// The fault injector's pace. By default a fault every 10 to 300 ms for the whole driver phase.
/// With bursts (`active_ms_max` > 0), stretches of faults and quiet stretches alternate, each
/// drawn up to its maximum (named decisions, "fault.active_ms" and "fault.quiet_ms": a strategy
/// steers them), a quiet stretch healing what was under way: a system slow to recover (an
/// election, a catalog loaded) gets windows to make progress in, and faults land on its work
/// rather than on its recovery alone, as Jepsen's nemeses' intervals (10 s) left.
pub const Pacing = struct {
    active_ms_max: u32 = 0,
    quiet_ms_max: u32 = 0,
};

pub const Command = struct {
    kind: Kind,
    name: []const u8,
    /// The executable inside `Scenario.node`, for scenarios that run in a node.
    path: ?[]const u8 = null,
    /// A driver of the workload the properties judge, beside drivers that are its nemeses: the
    /// composer's swarm keeps one of a scenario's workload drivers at least (a timeline of only a
    /// nemesis judges nothing). Every driver is otherwise kept per timeline by a named decision
    /// (`composer.swarm <name>`), the workload's too (passive suppression).
    workload: bool = false,
};

pub const Kind = enum {
    setup,
    first,
    parallel_driver,
    serial_driver,
    singleton_driver,
    anytime,
    eventually,
    finally,
};

/// What the guest receives: one profile, resolved, and every scenario.
pub const System = struct {
    schema: u32 = version,
    profile: []const u8,
    nodes: []const Resolved,
    scenarios: []const Scenario,
    /// The system declares its own setup through an Antithesis SDK (Compose projects): the
    /// composer waits for it before the drivers, as Antithesis does.
    sdk_setup: bool = false,
    checks: []const Check = &.{},
    /// The profile's command that turns the system's logs up (Profile.explain).
    explain: ?[]const u8 = null,
    /// The profile's retroactive texts (Profile.retroactive).
    retroactive: []const []const u8 = &.{},
    /// The profile's automations (Profile.automations).
    automations: []const Automation = &.{},
    /// The guest's wall clock at boot: the profile's (Profile.epoch_seconds), else the day after
    /// its newest image was made.
    epoch_seconds: ?u64 = null,

    pub fn scenario(system: *const System, name: []const u8) ?*const Scenario {
        for (system.scenarios) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn node(system: *const System, name: []const u8) ?*const Resolved {
        for (system.nodes) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// A node with everything the guest needs to run it.
pub const Resolved = struct {
    name: []const u8,
    /// IPv4 address on the guest network, "10.0.0.N".
    address: []const u8,
    /// The block device holding its root filesystem ("vdb", "vdc", ...).
    disk: []const u8,
    /// Identifies the root filesystem's content (image digest or content hash).
    digest: []const u8,
    command: []const []const u8,
    env: []const []const u8,
    workdir: []const u8 = "/",
    user: ?[]const u8 = null,
    ready: ?Ready = null,
    after: []const []const u8 = &.{},
    faults: Faults = .{},
    memory_max_mib: ?u32 = null,
    privileged: bool = false,
    ulimits: ?[]const Ulimit = null,
    antithesis_library: bool = false,
    crashes_known: []const []const u8 = &.{},
    writeback_s: ?u32 = null,
    exits_known: []const []const u8 = &.{},
    exits_known_disk: []const []const u8 = &.{},
    supervised: bool = false,
    panics_known: []const []const u8 = &.{},
    log_failures: []const LogFailure = &.{},
    spare: bool = false,
    knobs: []const Knob = &.{},
    /// Its next release, resolved (Node.upgrade): on a disk of its own.
    upgrade: ?Variant = null,
    once: bool = false,
    /// Its shared volumes (Volume.shared); its host ones are in its image.
    volumes: []const Volume = &.{},
    hostname: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
};

/// A node's other root filesystem (Node.upgrade), resolved as its own is.
pub const Variant = struct {
    disk: []const u8,
    digest: []const u8,
    command: []const []const u8,
    env: []const []const u8,
    workdir: []const u8 = "/",
    user: ?[]const u8 = null,
};

pub fn node_address(index: u32) [4]u8 {
    assert(index < nodes_max);
    return .{ 10, 0, 0, @intCast(index + 2) };
}

/// The block device of node `index` (disk 0, vda, is the system disk).
pub fn node_disk(buffer: *[3]u8, index: u32) []const u8 {
    assert(index < nodes_max);
    buffer.* = .{ 'v', 'd', @intCast('b' + index) };
    return buffer;
}

pub fn name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > node_name_size_max) return false;
    if (std.mem.eql(u8, name, runner_name)) return false;
    for (name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid) return false;
    }
    return std.ascii.isLower(name[0]);
}

pub fn parse(comptime T: type, arena: std.mem.Allocator, source: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test name_valid {
    try std.testing.expect(name_valid("redis"));
    try std.testing.expect(name_valid("pg-1"));
    try std.testing.expect(!name_valid("Redis"));
    try std.testing.expect(!name_valid("runner"));
    try std.testing.expect(!name_valid("a-very-long-name"));
}

test "knobs are named, each choice NAME=value entries" {
    const good = [_]Knob{
        .{ .name = "snapshot", .choices = &.{ &.{"SNAP=10"}, &.{"SNAP=1000"} } },
        .{ .name = "timing", .choices = &.{&.{ "HEARTBEAT=100", "ELECTION=1000" }}, .scope = .run },
    };
    try std.testing.expect(knobs_valid(&good));
    try std.testing.expect(knobs_valid(&.{}));
    try std.testing.expect(!knobs_valid(&.{.{ .name = "none", .choices = &.{} }}));
    try std.testing.expect(!knobs_valid(&.{.{ .name = "empty", .choices = &.{&.{}} }}));
    try std.testing.expect(!knobs_valid(&.{.{ .name = "bare", .choices = &.{&.{"SNAP"}} }}));
    try std.testing.expect(!knobs_valid(&.{.{ .name = "unnamed", .choices = &.{&.{"=10"}} }}));
    try std.testing.expect(!knobs_valid(&.{.{ .name = "a b", .choices = &.{&.{"A=1"}} }}));
    try std.testing.expect(!knobs_valid(&.{ good[0], good[0] }));
}

test "a node's knobs round-trip through JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\{"name":"etcd-1","address":"10.0.0.2","disk":"vdb","digest":"sha256:x","command":["etcd"],
        \\"env":[],"knobs":[{"name":"timing","choices":[["HEARTBEAT=100","ELECTION=1000"]],"scope":"run"}]}
    ;
    const node = try parse(Resolved, arena_state.allocator(), source);
    try std.testing.expectEqual(Knob.Scope.run, node.knobs[0].scope);
    try std.testing.expectEqualStrings("ELECTION=1000", node.knobs[0].choices[0][1]);
}

test "a system round-trips through JSON" {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const source =
        \\{"schema":1,"profile":"default","nodes":[{"name":"redis","address":"10.0.0.2",
        \\"disk":"vdb","digest":"sha256:x","command":["redis-server"],"env":["A=1"],
        \\"ready":{"tcp":6379}}],"scenarios":[{"name":"bank","commands":[
        \\{"kind":"setup","name":"seed"},{"kind":"parallel_driver","name":"transfer"}]}]}
    ;
    const system = try parse(System, arena.allocator(), source);
    try std.testing.expectEqual(@as(u16, 6379), system.node("redis").?.ready.?.tcp);
    const bank = system.scenario("bank").?;
    try std.testing.expectEqual(Kind.parallel_driver, bank.commands[1].kind);
    try std.testing.expect(bank.faults);
}
