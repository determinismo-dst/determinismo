// SPDX-License-Identifier: MIT
//! Persistence points traced (PLAN's persistence audit, after ALICE and CrashMonkey): a node's
//! rename of a file whose data is still dirty in the page cache, and its open of a file holding
//! data written before the opening process started and never synced, events. Armed by det-init
//! before the nodes start, so first starts are traced too; on unless det.persist_trace=0.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

/// Renamed with its data never written back, the file a power loss right after leaves empty or
/// short under its new name: the update protocol "write a temporary file, rename it into place"
/// without an fsync between (ALICE's most common vulnerability, Pillai et al., OSDI 2014). The
/// guest kernel's det_fs:det_rename tracepoint (guest/kernel/patches/0009) says each rename of a
/// regular file once it took place, with its data's state at that moment, its device, its name
/// before, its path from its file system's root and the renamer's cgroup; the kernel keeps those
/// whose data is not on the disk yet: pages dirty, or under writeback. ext4's auto_da_alloc
/// starts the writeback of a file renamed over another as it renames, but does not make it safe:
/// with dioread_nolock (ext4's default) the data's extents stay unwritten until the write
/// completes and their conversion commits, which the rename's commit does not wait for. A
/// cluster's node table, renamed over the old one so, came back its 755 bytes in zeros after a
/// power loss (hunt run 1488 timeline 13, read in a replay at the next mount).
/// A node's writable layer is an ext4 disk of its own mounted at its `layer` (nodes.zig's
/// layer_mount), the node's files under `/upper` in it: the device names the node, the path past
/// `/upper` its file. A node without a disk (a tmpfs layer) keeps nothing through a power loss:
/// its renames are not judged.
pub fn start() void {
    if (cmdline_number("det.persist_trace=") == 0) return;
    const root = "/sys/kernel/tracing";
    _ = linux.mount("none", root, "tracefs", 0, 0); // Mounted already, or now.
    const instance = root ++ "/instances/det-persist";
    _ = linux.mkdir(instance, 0o700);
    const event = instance ++ "/events/det_fs/det_rename";
    const armed = file_write(event ++ "/filter", "dirty == 1 || writeback == 1\n") and
        file_write(event ++ "/enable", "1\n") and
        file_write(instance ++ "/events/det_fs/det_open/enable", "1\n") and
        file_write(instance ++ "/tracing_on", "1\n");
    if (!armed) {
        sdk.event("persist_trace_failed", .{ .tracepoint = "det_fs" });
        return;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS or pid != 0) return;
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    const fd = linux.open(instance ++ "/trace_pipe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) linux.exit(1);
    var seen: Seen = .{};
    var opens_seen: Seen = .{};
    var buffer: [16384]u8 = undefined;
    var kept: usize = 0;
    while (true) {
        const size = linux.read(@intCast(fd), buffer[kept..].ptr, buffer.len - kept);
        if (linux.errno(size) != .SUCCESS or size == 0) linux.exit(0);
        kept += size;
        var from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..kept], from, '\n')) |end| : (from = end + 1) {
            const line = buffer[from..end];
            if (rename_line(line)) |rename| {
                rename_judge(rename, &seen);
            } else if (open_line(line)) |open| open_judge(open, &opens_seen);
        }
        std.mem.copyForwards(u8, buffer[0 .. kept - from], buffer[from..kept]);
        kept -= from;
        if (kept == buffer.len) kept = 0; // A line longer than the buffer: dropped.
    }
}

const events_max = 512;
const seen_max = 1024;
const path_size_max = 4096;

/// The destinations already reported, by a hash of node and path: each once.
const Seen = struct {
    hashes: [seen_max]u64 = undefined,
    count: u32 = 0,
    events: u32 = 0,

    fn first(seen: *Seen, node: []const u8, path: []const u8) bool {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(node);
        hasher.update("\x00");
        hasher.update(path);
        const hash = hasher.final();
        for (seen.hashes[0..seen.count]) |known| if (known == hash) return false;
        if (seen.count < seen_max) {
            seen.hashes[seen.count] = hash;
            seen.count += 1;
        }
        return true;
    }
};

const Rename = struct {
    /// The renaming task, `comm-pid` as the trace says it.
    task: []const u8,
    major: u32,
    minor: u32,
    size: u64,
    replaced: bool,
    /// The renaming task's cgroup, from cgroup2's root ("/nodes/<node>/..." for a node's).
    cgroup: []const u8,
    /// The file's name before (its last component).
    from: []const u8,
    /// Its path from its file system's root.
    path: []const u8,
};

/// A trace_pipe line of the tracepoint: "  valkey-server-1234 [000] ..... 81.32: det_rename:
/// dev=254:3 ino=12 size=1580 dirty=1 writeback=0 replaced=0 cgroup=/nodes/v1
/// from=temp-1234.conf path=/upper/data/nodes.conf" (a task's name may hold spaces: it is what
/// precedes " [").
fn rename_line(line: []const u8) ?Rename {
    const marker = " det_rename: ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const cpu = std.mem.indexOf(u8, line, " [") orelse return null;
    const fields = line[at + marker.len ..];
    const dev = field(fields, "dev=") orelse return null;
    const colon = std.mem.indexOfScalar(u8, dev, ':') orelse return null;
    const from_key = " from=";
    const path_key = " path=";
    const from_at = std.mem.indexOf(u8, fields, from_key) orelse return null;
    const path_at = std.mem.indexOfPos(u8, fields, from_at, path_key) orelse return null;
    return .{
        .task = std.mem.trim(u8, line[0..cpu], " "),
        .major = std.fmt.parseInt(u32, dev[0..colon], 10) catch return null,
        .minor = std.fmt.parseInt(u32, dev[colon + 1 ..], 10) catch return null,
        .size = std.fmt.parseInt(u64, field(fields, "size=") orelse return null, 10) catch return null,
        .replaced = std.mem.eql(u8, field(fields, "replaced=") orelse return null, "1"),
        .cgroup = field(fields, "cgroup=") orelse return null,
        .from = fields[from_at + from_key.len .. path_at],
        .path = std.mem.trimEnd(u8, fields[path_at + path_key.len ..], "\r"),
    };
}

/// The value of `key` among the fields before `from=` (none of them holds a space).
fn field(fields: []const u8, comptime key: []const u8) ?[]const u8 {
    const head = fields[0 .. std.mem.indexOf(u8, fields, " from=") orelse fields.len];
    var words = std.mem.tokenizeScalar(u8, head, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, key)) return word[key.len..];
    }
    return null;
}

test rename_line {
    const rename = rename_line("  C2 CompilerThre-1234    [000] .....    81.325829: det_rename: " ++
        "dev=254:3 ino=12 size=1580 dirty=1 writeback=0 replaced=0 cgroup=/nodes/v1 from=temp 1.conf " ++
        "path=/upper/data/nodes.conf").?;
    try std.testing.expectEqualStrings("C2 CompilerThre-1234", rename.task);
    try std.testing.expectEqual(254, rename.major);
    try std.testing.expectEqual(3, rename.minor);
    try std.testing.expectEqual(1580, rename.size);
    try std.testing.expect(!rename.replaced);
    try std.testing.expectEqualStrings("temp 1.conf", rename.from);
    try std.testing.expectEqualStrings("/nodes/v1", rename.cgroup);
    try std.testing.expectEqualStrings("/upper/data/nodes.conf", rename.path);
    try std.testing.expectEqual(null, rename_line("# tracer: nop"));
}

/// A file whose data is not on its disk yet (dirty or under writeback) opened
/// (guest/kernel/patches/0011): when its inode was first dirtied
/// since it was last written back, and when the opening process started, ms since boot.
const Open = struct {
    task: []const u8,
    major: u32,
    minor: u32,
    size: u64,
    flags: u32,
    dirtied_ms: u64,
    started_ms: u64,
    cgroup: []const u8,
    path: []const u8,
};

/// "  valkey-server-88 [000] ..... 9.1: det_open: dev=254:3 ino=12 size=1580 flags=0x80000
/// dirtied_ms=4012 started_ms=8890 cgroup=/nodes/v1 path=/upper/data/nodes.conf".
fn open_line(line: []const u8) ?Open {
    const marker = " det_open: ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const cpu = std.mem.indexOf(u8, line, " [") orelse return null;
    const fields = line[at + marker.len ..];
    const path_key = " path=";
    const path_at = std.mem.indexOf(u8, fields, path_key) orelse return null;
    const head = fields[0..path_at];
    const dev = head_field(head, "dev=") orelse return null;
    const colon = std.mem.indexOfScalar(u8, dev, ':') orelse return null;
    return .{
        .task = std.mem.trim(u8, line[0..cpu], " "),
        .major = std.fmt.parseInt(u32, dev[0..colon], 10) catch return null,
        .minor = std.fmt.parseInt(u32, dev[colon + 1 ..], 10) catch return null,
        .size = std.fmt.parseInt(u64, head_field(head, "size=") orelse return null, 10) catch return null,
        .flags = std.fmt.parseInt(u32, head_field(head, "flags=") orelse return null, 0) catch return null,
        .dirtied_ms = std.fmt.parseInt(u64, head_field(head, "dirtied_ms=") orelse return null, 10) catch return null,
        .started_ms = std.fmt.parseInt(u64, head_field(head, "started_ms=") orelse return null, 10) catch return null,
        .cgroup = head_field(head, "cgroup=") orelse return null,
        .path = std.mem.trimEnd(u8, fields[path_at + path_key.len ..], "\r"),
    };
}

fn head_field(head: []const u8, comptime key: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, head, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, key)) return word[key.len..];
    }
    return null;
}

test open_line {
    const open = open_line("   valkey-server-88    [000] .....  9.100: det_open: dev=254:3 ino=12 " ++
        "size=1580 flags=0x80002 dirtied_ms=4012 started_ms=8890 cgroup=/nodes/v1 path=/upper/data/nodes conf").?;
    try std.testing.expectEqualStrings("valkey-server-88", open.task);
    try std.testing.expectEqual(254, open.major);
    try std.testing.expectEqual(0x80002, open.flags);
    try std.testing.expectEqual(4012, open.dirtied_ms);
    try std.testing.expectEqual(8890, open.started_ms);
    try std.testing.expectEqualStrings("/upper/data/nodes conf", open.path);
    try std.testing.expectEqualStrings("/nodes/v1", open.cgroup);
    try std.testing.expectEqual(0, open_line("  a-1 [000] ..... 1.0: det_open: dev=0:1 ino=1 size=0 flags=0 " ++
        "dirtied_ms=1 started_ms=2 cgroup=/ path=/x").?.flags);
}

/// A node relying, across its start, on what a power loss would have taken: a file whose data
/// was written before the node's latest start and never synced, opened by the node since (a file
/// written at a first start and read at the next: a node's key, a cluster's global state, a
/// cookie, each found after a power loss). The node's start is
/// nodes.zig's `started_ms`, written before its program runs; another of its processes reading
/// what one wrote since the start is the page cache doing its work (PostgreSQL's backends), not
/// this (the selftest's own commands were counted so first).
fn open_judge(open: Open, seen: *Seen) void {
    if (open.major == 0) return; // Not a disk.
    const upper = "/upper";
    if (!std.mem.startsWith(u8, open.path, upper ++ "/")) return;
    const path = open.path[upper.len..];
    if (volatile_place(path) or log_like(path)) return;
    var node_buffer: [256]u8 = undefined;
    const node = node_of_device(open.major, open.minor, &node_buffer) orelse return;
    if (!cgroup_of_node(open.cgroup, node)) return; // The platform's (det-faults reading a node's files).
    const node_started_ms = node_started(node) orelse return;
    if (open.dirtied_ms >= node_started_ms) return; // Written since the node's start.
    if (seen.events == events_max) return;
    var shape_buffer: [path_size_max]u8 = undefined;
    const shape = path_shape(path, &shape_buffer);
    if (!seen.first(node, shape)) return;
    seen.events += 1;
    // `name` a behavior key, as a rename's: the tree returns just after a node first relies on
    // such a file, its first fault aimed at the node (a power loss now takes what it relies on).
    // And the injector may cut its power soon after (faults.zig's aftershocks), the moment the
    // relied-on data is lost (a node's identity key, a cluster's global state file).
    aftershock_ask(node);
    const write_mask: u32 = 3; // O_ACCMODE: O_WRONLY 1, O_RDWR 2.
    sdk.event("node_open_unsynced", .{
        .node = node,
        .name = shape,
        .path = path,
        .process = open.task,
        .size = open.size,
        .writing = open.flags & write_mask != 0,
        .written_ms_before_start = node_started_ms - open.dirtied_ms,
    });
}

/// The node's latest start (nodes.zig's `started_ms`), ms of CLOCK_MONOTONIC since boot.
fn node_started(node: []const u8) ?u64 {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, nodes_root ++ "/{s}/started_ms", .{node}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buffer[0..size], " \n"), 10) catch null;
}

/// nodes.zig's state_root: each node's directory, its writable layer at `layer`, the overlay's
/// upper directory at `layer/upper`, mounted in this mount namespace.
const nodes_root = "/run/det/nodes";

fn rename_judge(rename: Rename, seen: *Seen) void {
    if (rename.major == 0) return; // Not a disk: a tmpfs layer, or a node's own tmpfs.
    const upper = "/upper";
    if (!std.mem.startsWith(u8, rename.path, upper ++ "/")) return; // The overlay's work directory.
    const path = rename.path[upper.len..];
    if (volatile_place(path)) return;
    var node_buffer: [256]u8 = undefined;
    const node = node_of_device(rename.major, rename.minor, &node_buffer) orelse return;
    if (!cgroup_of_node(rename.cgroup, node)) return; // The platform's, not the node's.
    report(rename, node, path, seen);
}

/// A cgroup path the node's: its own, or one under it (a container runtime's in it).
fn cgroup_of_node(cgroup: []const u8, node: []const u8) bool {
    const prefix = "/nodes/";
    if (!std.mem.startsWith(u8, cgroup, prefix)) return false;
    const rest = cgroup[prefix.len..];
    if (!std.mem.startsWith(u8, rest, node)) return false;
    return rest.len == node.len or rest[node.len] == '/';
}

test cgroup_of_node {
    try std.testing.expect(cgroup_of_node("/nodes/v1", "v1"));
    try std.testing.expect(cgroup_of_node("/nodes/k1/kubepods/pod1", "k1"));
    try std.testing.expect(!cgroup_of_node("/nodes/v10", "v1"));
    try std.testing.expect(!cgroup_of_node("/", "v1"));
}

/// The node whose writable layer is on the device, or null (gone since, or no node's).
fn node_of_device(major: u32, minor: u32, buffer: []u8) ?[]const u8 {
    const directory = linux.open(nodes_root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(directory) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(directory));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(directory), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return null;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entries[name_offset])));
            if (entry.type != linux.DT.DIR or name[0] == '.' or name.len > buffer.len) continue;
            var path_buffer: [path_size_max]u8 = undefined;
            const layer = std.fmt.bufPrintSentinel(&path_buffer, nodes_root ++ "/{s}/layer/upper", .{name}, 0) catch continue;
            var stat: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, layer, 0, .{ .TYPE = true }, &stat)) != .SUCCESS) continue;
            if (stat.dev_major != major or stat.dev_minor != minor) continue;
            @memcpy(buffer[0..name.len], name);
            return buffer[0..name.len];
        }
    }
}

fn report(rename: Rename, node: []const u8, path: []const u8, seen: *Seen) void {
    if (seen.events == events_max) return;
    var shape_buffer: [path_size_max]u8 = undefined;
    const shape = path_shape(path, &shape_buffer);
    if (!seen.first(node, shape)) return;
    seen.events += 1;
    // `name`, the destination, is a behavior key (src/events.zig's behavior_keys), as `node`: each
    // destination's first such rename in a timeline is a behavior the tree returns to just
    // after, its first fault aimed at the node (vm.zig's det:branch): the crash right after a
    // persistence point, CrashMonkey's (Mohan et al., OSDI 2018), drawn among its faults. A
    // log's rotation is said too, under `to` alone (no key): one behavior a node, not one a
    // rotated name (Infinispan's gc.log and server.log, trial run 1458).
    // The destination's shape, ids and numbers made `#`, is the key: a system naming its files
    // by timestamps or random ids (Weaviate's shards and segments) made each rename a behavior of
    // its own, 1,781 of 1,808 (hunt run 1473), the tree's returns spent on them.
    const log = log_like(path);
    // The injector may cut the node's power soon after (faults.zig's aftershocks): the renamed
    // file's content is what a power loss now would lose.
    if (!log) aftershock_ask(node);
    sdk.event("node_rename_unsynced", .{
        .node = node,
        .name = if (log) null else shape,
        .to = path,
        .from = rename.from,
        .size = rename.size,
        .replaced = rename.replaced,
        .process = rename.task,
    });
}

/// Asks the fault injector for an aftershock on `node` (its control FIFO; faults.zig's
/// aftershock_flag, the node's name after it, in one atomic write). Nothing without an injector.
fn aftershock_ask(node: []const u8) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    const aftershock_flag: u64 = 1 << 60; // faults.zig's aftershock_flag.
    var message: [8 + 32]u8 = undefined;
    const size = @min(node.len, 32);
    std.mem.writeInt(u64, message[0..8], aftershock_flag | size, .little);
    @memcpy(message[8..][0..size], node[0..size]);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), &message, 8 + size); // Atomic: under PIPE_BUF.
}

/// `path` with each alphanumeric run that holds a digit, or that is a long id (8 or more
/// characters, letters of both cases), made one `#`: a file's place, not its instance.
fn path_shape(path: []const u8, buffer: *[path_size_max]u8) []const u8 {
    var size: usize = 0;
    var index: usize = 0;
    while (index < path.len and size < buffer.len) {
        if (!std.ascii.isAlphanumeric(path[index])) {
            buffer[size] = path[index];
            size += 1;
            index += 1;
            continue;
        }
        var end = index;
        var digit = false;
        var upper = false;
        var lower = false;
        while (end < path.len and std.ascii.isAlphanumeric(path[end])) : (end += 1) {
            digit = digit or std.ascii.isDigit(path[end]);
            upper = upper or std.ascii.isUpper(path[end]);
            lower = lower or std.ascii.isLower(path[end]);
        }
        const run = path[index..end];
        if (digit or (run.len >= 8 and upper and lower)) {
            buffer[size] = '#';
            size += 1;
        } else {
            const kept = @min(run.len, buffer.len - size);
            @memcpy(buffer[size..][0..kept], run[0..kept]);
            size += kept;
        }
        index = end;
    }
    return buffer[0..size];
}

test path_shape {
    var buffer: [path_size_max]u8 = undefined;
    try std.testing.expectEqualStrings("/var/lib/weaviate/reg/#/proplengths", path_shape("/var/lib/weaviate/reg/JB2y2scwHUQI/proplengths", &buffer));
    try std.testing.expectEqualStrings("/var/lib/weaviate/reg/#/lsm/objects/segment-#.wal", path_shape("/var/lib/weaviate/reg/NFabcdefghij/lsm/objects/segment-1793923207816520433.wal", &buffer));
    try std.testing.expectEqualStrings("datalog/version-#/log.#", path_shape("datalog/version-2/log.2000004ca", &buffer));
    try std.testing.expectEqualStrings("/data/renamed", path_shape("/data/renamed", &buffer));
}

/// A log's path: in a `log` or `logs` directory, a name with `.log` in it, or RocksDB's and
/// LevelDB's info log (`LOG`, rotated to `LOG.old.<time>`: every RocksDB system's, Typesense's
/// trial run 1478).
fn log_like(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/log/") != null or std.mem.indexOf(u8, path, "/logs/") != null) return true;
    const base = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0..];
    if (std.mem.eql(u8, base, "LOG") or std.mem.startsWith(u8, base, "LOG.old")) return true;
    return std.mem.indexOf(u8, base, ".log") != null;
}

/// A place no machine keeps through a power loss (tmpfs on most systems): what is renamed there
/// is not meant to last (a start script's own files: Typesense's /tmp/nodes, trial run 1478).
fn volatile_place(path: []const u8) bool {
    inline for (.{ "/tmp/", "/run/", "/dev/shm/" }) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

test volatile_place {
    try std.testing.expect(volatile_place("/tmp/nodes"));
    try std.testing.expect(!volatile_place("/data/members"));
}

test log_like {
    try std.testing.expect(log_like("/opt/infinispan/server/log/backupgc.log"));
    try std.testing.expect(log_like("/var/lib/x/server.log.2026-11-08-1"));
    try std.testing.expect(log_like("/data/logs/a"));
    try std.testing.expect(!log_like("/data/renamed"));
    try std.testing.expect(!log_like("/var/lib/kafka/catalog/state"));
    try std.testing.expect(log_like("/data/db/LOG.old.1794096010205373"));
    try std.testing.expect(!log_like("/data/db/MANIFEST-000005"));
}

fn file_write(path: [:0]const u8, text: []const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    return linux.errno(linux.write(@intCast(fd), text.ptr, text.len)) == .SUCCESS;
}

/// `key<n>` among the guest's command line's words.
fn cmdline_number(comptime key: []const u8) ?u64 {
    const fd = linux.open(sdk.cmdline_path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var words = std.mem.tokenizeAny(u8, buffer[0..size], " \n");
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, key)) return std.fmt.parseInt(u64, word[key.len..], 10) catch null;
    }
    return null;
}
