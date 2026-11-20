// SPDX-License-Identifier: MIT
//! Imports a Compose file as a profile (ARCHITECTURE.md §10: Compose is an importer).
//!
//! Each service becomes a node: `image` (by name, as Antithesis uses it) or else `build` as its
//! source, `entrypoint` and `command`
//! (lists, or strings split like a shell), `environment` (list or map), `working_dir`, `user`,
//! `labels` (`determinismo.faults`, `determinismo.no-faults`: its node's fault kinds),
//! `depends_on` (dependencies start first), `mem_limit`, `privileged`, `ulimits`, and the first container
//! port of `ports`
//! or `expose` as its readiness check, `volumes` (volumes_apply: shared directories, the project's
//! files in the node's image), and `depends_on`'s `service_completed_successfully` (the service a
//! one-shot, schema.Node.once). Every node gets
//! ANTITHESIS_SDK_LOCAL_OUTPUT (a regular file the platform reads: detfs), so
//! services and tests using an Antithesis SDK report to determinismo. Fields with no meaning in
//! one deterministic machine (networks, ...) are reported, not silently dropped. A
//! `restart` policy that restarts a failed container (always, on-failure, unless-stopped) makes
//! the node supervised (schema.Node.supervised): started again after it exits on its own.
const std = @import("std");
const assert = std.debug.assert;
const schema = @import("determinismo").schema;
const yaml = @import("yaml.zig");

/// A regular file (detfs, det-init.sdk_output_path): Antithesis's Go SDK truncates its output
/// file, which /dev/determinismo, a device, cannot be.
pub const sdk_output_variable = "ANTITHESIS_SDK_LOCAL_OUTPUT=/opt/determinismo/sdk/output";

const ignored_fields = [_][]const u8{
    "networks", "deploy",      "logging",
    "env_file", "cap_add",     "cap_drop",
    "init",     "stop_signal", "platform",
    "tty",      "stdin_open",  "security_opt",
    // Namespaced kernel settings (net.unix.max_dgram_qlen): not applied in a node yet.
    "sysctls",
};

/// The profile ("default") of the Compose file at `path`. Relative build contexts are taken
/// from the file's directory.
pub fn profile(arena: std.mem.Allocator, io: std.Io, path: []const u8) !schema.Profile {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        std.debug.print("[determinismo] compose: {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    const directory_of = std.fs.path.dirname(path) orelse ".";
    const env_path = try std.fs.path.join(arena, &.{ directory_of, ".env" });
    const env = std.Io.Dir.cwd().readFileAlloc(io, env_path, arena, .limited(1 << 16)) catch "";
    const source = try interpolate(arena, raw, env);
    const root = try yaml.parse(arena, source);
    const services = root.get("services") orelse return error.NoServices;
    if (services != .mapping or services.mapping.len == 0) return error.NoServices;
    if (services.mapping.len > schema.nodes_max) return error.TooManyServices;
    const directory = std.fs.path.dirname(path) orelse ".";
    var kept: std.ArrayList(yaml.Value.Entry) = .empty;
    for (services.mapping) |service| {
        if (!started(service.value)) {
            std.debug.print("[determinismo] compose: {s} is not started (its profiles are none enabled)\n", .{service.key});
            continue;
        }
        try kept.append(arena, service);
    }
    if (kept.items.len == 0) return error.NoServices;
    const names = try node_names(arena, kept.items);
    var nodes: std.ArrayList(schema.Node) = .empty;
    for (kept.items, names) |service, name| {
        var node = try node_from_service(arena, directory, service, name);
        // Its dependencies by their nodes' names (a service's name may be no node's).
        const after = try arena.alloc([]const u8, node.after.len);
        for (node.after, after) |dependency, *slot| {
            slot.* = for (kept.items, names) |other, other_name| {
                if (std.mem.eql(u8, other.key, dependency)) break other_name;
            } else dependency; // Unknown: dependency_order says so.
        }
        node.after = after;
        try nodes.append(arena, node);
    }
    try once_mark(nodes.items, kept.items);
    try healthy_mark(arena, nodes.items, kept.items);
    try volumes_apply(arena, io, directory, kept.items, nodes.items);
    return .{ .name = "default", .nodes = try dependency_order(arena, nodes.items) };
}

/// Whether Compose starts the service with no profile enabled, as `docker compose up` does: one
/// with `profiles` starts only when one of them is (Antithesis's projects mark their config image
/// so: orleans-bank-test's `config`, an image of the Compose file alone, no command).
fn started(fields: yaml.Value) bool {
    const profiles = fields.get("profiles") orelse return true;
    return switch (profiles) {
        .sequence => |items| items.len == 0,
        .empty => true,
        else => false,
    };
}

test started {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try yaml.parse(arena.allocator(),
        \\services:
        \\    bankserver1:
        \\        image: localhost/orleans-bank-test/bankserver:10.1.0
        \\    config:
        \\        image: localhost/orleans-bank-test/config:10.1.0
        \\        profiles:
        \\            - config
        \\
    );
    const services = root.get("services").?.mapping;
    try std.testing.expect(started(services[0].value));
    try std.testing.expect(!started(services[1].value));
}

/// Each service's node name (schema.name_valid: 1-12 lowercase letters, digits or dashes, a letter
/// first: the guest's network interfaces are named after nodes): its own when valid, else its
/// letters and digits lowercased with other bytes as '-', a letter first, cut to 12, and a
/// number at its end when another node has it. The service's own name is then an alias of the
/// node (node_from_service) and its hostname, so the others reach it by it as under Compose (the
/// Kafka demo's data_generator, data_generator_client, state-tracker).
fn node_names(arena: std.mem.Allocator, services: []const yaml.Value.Entry) ![]const []const u8 {
    const names = try arena.alloc([]const u8, services.len);
    for (services, names, 0..) |service, *name, index| {
        if (schema.name_valid(service.key) and !name_taken(names[0..index], service.key)) {
            name.* = service.key;
            continue;
        }
        var buffer: [schema.node_name_size_max]u8 = undefined;
        var size: usize = 0;
        if (service.key.len == 0 or !std.ascii.isAlphabetic(service.key[0])) {
            buffer[0] = 's';
            size = 1;
        }
        for (service.key) |byte| {
            if (size == buffer.len) break;
            const lower = std.ascii.toLower(byte);
            buffer[size] = if (std.ascii.isLower(lower) or std.ascii.isDigit(lower)) lower else '-';
            size += 1;
        }
        var candidate: []const u8 = try arena.dupe(u8, buffer[0..size]);
        var number: u32 = 2;
        while (!schema.name_valid(candidate) or name_taken(names[0..index], candidate)) : (number += 1) {
            if (number > 99) return error.ServiceNamesClash;
            const digits: usize = if (number < 10) 1 else 2;
            const kept_size = @min(size, buffer.len - digits - 1);
            candidate = try std.fmt.allocPrint(arena, "{s}-{d}", .{ buffer[0..kept_size], number });
        }
        name.* = candidate;
        std.debug.print("[determinismo] compose: {s} runs as node {s} (node names are 1-12 lowercase " ++
            "letters, digits or dashes); its own name resolves to it and is its hostname\n", .{ service.key, candidate });
    }
    return names;
}

fn name_taken(names: []const []const u8, name: []const u8) bool {
    for (names) |other| if (std.mem.eql(u8, other, name)) return true;
    return false;
}

test node_names {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try yaml.parse(arena,
        \\kafka-1: {}
        \\data_generator: {}
        \\data_generator_client: {}
        \\state-tracker: {}
        \\Runner: {}
        \\
    );
    const names = try node_names(arena, root.mapping);
    try std.testing.expectEqualStrings("kafka-1", names[0]);
    try std.testing.expectEqualStrings("data-generat", names[1]);
    try std.testing.expectEqualStrings("data-gener-2", names[2]);
    try std.testing.expectEqualStrings("state-tracke", names[3]);
    try std.testing.expectEqualStrings("runner-2", names[4]); // "runner" is the runner's.
    for (names) |name| try std.testing.expect(schema.name_valid(name));
}

fn node_from_service(
    arena: std.mem.Allocator,
    directory: []const u8,
    service: yaml.Value.Entry,
    name: []const u8,
) !schema.Node {
    const fields = service.value;
    for (ignored_fields) |field| {
        if (fields.get(field) != null) {
            const note = "[determinismo] compose: {s}.{s} is ignored\n";
            std.debug.print(note, .{ service.key, field });
        }
    }
    // As on Antithesis, a restarted service may come back with a new address.
    // Other names that reach it: its service's when its node's differs (node_names), its
    // container_name; its hostname, the service's own name when renamed.
    var aliases: std.ArrayList([]const u8) = .empty;
    if (!std.mem.eql(u8, name, service.key)) try aliases.append(arena, service.key);
    if (fields.get("container_name")) |value| {
        const text = try scalar(value);
        if (!std.mem.eql(u8, text, name) and !name_taken(aliases.items, text)) try aliases.append(arena, text);
    }
    const hostname: ?[]const u8 = if (fields.get("hostname")) |value| try scalar(value) else if (aliases.items.len > 0 and !std.mem.eql(u8, name, service.key)) service.key else null;
    if (hostname) |text| {
        if (!std.mem.eql(u8, text, name) and !name_taken(aliases.items, text)) try aliases.append(arena, text);
    }
    var node = schema.Node{
        .name = name,
        .hostname = if (hostname) |text| (if (std.mem.eql(u8, text, name)) null else text) else null,
        .aliases = aliases.items,
        .source = .{},
        .faults = .{ .new_address = true },
        .antithesis_library = true,
    };
    // As Antithesis does, an image is used by name (built beforehand, as the project's own
    // scripts build it, or pulled); `build` only when no image is named.
    if (fields.get("image")) |image| {
        node.source.image = try scalar(image);
    } else if (fields.get("build")) |build| {
        node.source = .{ .build = try build_source(arena, directory, build) };
    }
    if (node.source.kind_count() != 1) return error.ServiceNeedsImageOrBuild;
    if (fields.get("entrypoint")) |value| node.entrypoint = try words(arena, value);
    if (fields.get("command")) |value| node.command = try words(arena, value);
    if (fields.get("working_dir")) |value| node.workdir = try scalar(value);
    if (fields.get("user")) |value| node.user = try scalar(value);
    node.env = try environment(arena, fields.get("environment"));
    try labels_apply(arena, service.key, &node.faults, fields.get("labels"));
    node.after = try dependencies(arena, fields.get("depends_on"));
    if (try first_port(fields)) |port| node.ready = .{ .tcp = port };
    if (fields.get("mem_limit")) |value| node.memory_max_mib = try memory_mib(try scalar(value));
    if (fields.get("privileged")) |value| {
        node.privileged = std.mem.eql(u8, try scalar(value), "true");
    }
    node.ulimits = try ulimits(arena, fields.get("ulimits"));
    if (fields.get("restart")) |value| node.supervised = try restart_supervises(try scalar(value));
    return node;
}

/// The services another waits for to end (`depends_on` with `condition:
/// service_completed_successfully` or `service_completed`): one-shots (schema.Node.once), started
/// before it, never started again.
fn once_mark(nodes: []schema.Node, services: []const yaml.Value.Entry) !void {
    for (services) |service| {
        const depends = service.value.get("depends_on") orelse continue;
        if (depends != .mapping) continue;
        for (depends.mapping) |dependency| {
            const condition = try scalar(dependency.value.get("condition") orelse continue);
            const completed = std.mem.eql(u8, condition, "service_completed_successfully") or
                std.mem.eql(u8, condition, "service_completed");
            if (!completed) continue;
            for (services, nodes) |other, *node| {
                if (std.mem.eql(u8, other.key, dependency.key)) node.once = true;
            }
        }
    }
}

/// The services another waits for with `service_healthy`: their `healthcheck` test is their
/// readiness (schema.Ready.command), as Compose starts the dependents once it passes. Compose
/// runs it on all along (data_generator's POST every interval, in the Kafka demo); here until it
/// first passes. A healthcheck nothing waits on is said, unused.
fn healthy_mark(arena: std.mem.Allocator, nodes: []schema.Node, services: []const yaml.Value.Entry) !void {
    var waited: std.ArrayList([]const u8) = .empty;
    for (services) |service| {
        const depends = service.value.get("depends_on") orelse continue;
        if (depends != .mapping) continue;
        for (depends.mapping) |dependency| {
            const condition = try scalar(dependency.value.get("condition") orelse continue);
            if (std.mem.eql(u8, condition, "service_healthy")) try waited.append(arena, dependency.key);
        }
    }
    for (services, nodes) |service, *node| {
        const check = service.value.get("healthcheck") orelse continue;
        const used = for (waited.items) |name| {
            if (std.mem.eql(u8, name, service.key)) break true;
        } else false;
        if (!used) {
            std.debug.print("[determinismo] compose: {s}.healthcheck is unused (nothing waits on it with service_healthy)\n", .{service.key});
            continue;
        }
        const argv = try health_command(arena, check) orelse return error.WaitedHealthcheckDisabled;
        node.ready = .{ .command = argv, .timeout_s = 300 };
    }
    for (waited.items) |name| {
        const found = for (services) |service| {
            if (std.mem.eql(u8, service.key, name) and service.value.get("healthcheck") != null) break true;
        } else false;
        if (!found) {
            std.debug.print("[determinismo] compose: {s} is waited on with service_healthy and has no healthcheck\n", .{name});
            return error.HealthyWithoutHealthcheck;
        }
    }
}

/// A healthcheck's `test` as a command: a string or ["CMD-SHELL", "..."] through /bin/sh -c,
/// ["CMD", ...] as it is; null for ["NONE"] or `disable: true`.
fn health_command(arena: std.mem.Allocator, check: yaml.Value) !?[]const []const u8 {
    if (check.get("disable")) |value| if (std.mem.eql(u8, try scalar(value), "true")) return null;
    const value = check.get("test") orelse return error.HealthcheckWithoutTest;
    switch (value) {
        .sequence => |items| {
            if (items.len == 0) return error.BadHealthcheck;
            const kind = try scalar(items[0]);
            if (std.mem.eql(u8, kind, "NONE")) return null;
            if (std.mem.eql(u8, kind, "CMD")) {
                if (items.len < 2) return error.BadHealthcheck;
                const argv = try arena.alloc([]const u8, items.len - 1);
                for (items[1..], argv) |item, *slot| slot.* = try scalar(item);
                return argv;
            }
            if (std.mem.eql(u8, kind, "CMD-SHELL")) {
                var line: std.ArrayList(u8) = .empty;
                for (items[1..], 0..) |item, index| {
                    if (index > 0) try line.append(arena, ' ');
                    try line.appendSlice(arena, try scalar(item));
                }
                return try arena.dupe([]const u8, &.{ "/bin/sh", "-c", line.items });
            }
            return error.BadHealthcheck;
        },
        else => return try arena.dupe([]const u8, &.{ "/bin/sh", "-c", try scalar(value) }),
    }
}

test healthy_mark {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try yaml.parse(arena,
        \\kafka-1:
        \\  image: kafka
        \\  healthcheck:
        \\    test: /opt/kafka/bin/kafka-cluster.sh cluster-id --bootstrap-server kafka-1:9092 || exit 1
        \\state-tracker:
        \\  image: postgres
        \\  healthcheck:
        \\    test: ["CMD-SHELL", "pg_isready", "-d", "d"]
        \\data_generator:
        \\  image: gen
        \\  healthcheck:
        \\    test: ["CMD", "curl", "-f", "http://localhost:5000/single"]
        \\unused:
        \\  image: x
        \\  healthcheck:
        \\    test: ["CMD", "true"]
        \\producer:
        \\  image: producer
        \\  depends_on:
        \\    kafka-1:
        \\      condition: service_healthy
        \\    state-tracker:
        \\      condition: service_healthy
        \\    data_generator:
        \\      condition: service_healthy
        \\
    );
    var nodes = [_]schema.Node{
        .{ .name = "kafka-1", .source = .{} },        .{ .name = "state-tracker", .source = .{} },
        .{ .name = "data_generator", .source = .{} }, .{ .name = "unused", .source = .{} },
        .{ .name = "producer", .source = .{} },
    };
    try healthy_mark(arena, &nodes, root.mapping);
    try std.testing.expectEqualStrings("/bin/sh", nodes[0].ready.?.command.?[0]);
    try std.testing.expectEqualStrings("pg_isready -d d", nodes[1].ready.?.command.?[2]);
    try std.testing.expectEqualStrings("curl", nodes[2].ready.?.command.?[0]);
    try std.testing.expectEqual(@as(usize, 3), nodes[2].ready.?.command.?.len);
    try std.testing.expect(nodes[3].ready == null and nodes[4].ready == null);
}

/// One `volumes` entry of a service as Compose reads it (short "source:target[:mode]", or long
/// with `type`, `source`, `target`, `read_only`).
const Mount = struct {
    named: bool,
    /// A named volume's name, or a bind's source as written ("./" and a last "/" left out): what
    /// services share it by.
    key: []const u8,
    /// A bind's source, against the file's directory when relative.
    path: []const u8,
    target: []const u8,
    read_only: bool,
};

/// Null for what has no meaning here, said: an anonymous volume, a tmpfs (both the node's own,
/// as its writable layer is).
fn mount_parse(arena: std.mem.Allocator, directory: []const u8, service: []const u8, value: yaml.Value) !?Mount {
    var source: []const u8 = "";
    var target: []const u8 = "";
    var read_only = false;
    var kind: ?[]const u8 = null;
    switch (value) {
        .mapping => {
            if (value.get("type")) |text| kind = try scalar(text);
            if (value.get("source")) |text| source = try scalar(text);
            target = try scalar(value.get("target") orelse return error.BadVolume);
            if (value.get("read_only")) |text| read_only = std.mem.eql(u8, try scalar(text), "true");
        },
        else => {
            var parts = std.mem.splitScalar(u8, try scalar(value), ':');
            const first = parts.next().?;
            if (parts.next()) |second| {
                source = first;
                target = second;
                if (parts.next()) |mode| {
                    var modes = std.mem.splitScalar(u8, mode, ',');
                    while (modes.next()) |each| read_only = read_only or std.mem.eql(u8, each, "ro");
                }
            } else target = first;
        },
    }
    if (kind) |text| if (!std.mem.eql(u8, text, "bind") and !std.mem.eql(u8, text, "volume")) {
        std.debug.print("[determinismo] compose: {s}.volumes {s}: a {s} mount is ignored\n", .{ service, target, text });
        return null;
    };
    if (target.len == 0 or target[0] != '/') return error.BadVolume;
    if (source.len == 0) {
        std.debug.print("[determinismo] compose: {s}.volumes {s}: an anonymous volume, on its own disk\n", .{ service, target });
        return null;
    }
    const bind = if (kind) |text| std.mem.eql(u8, text, "bind") else source[0] == '/' or source[0] == '.' or source[0] == '~';
    if (!bind) return .{ .named = true, .key = source, .path = "", .target = target, .read_only = read_only };
    if (source[0] == '~') {
        std.debug.print("[determinismo] compose: {s}.volumes {s}: a home directory has no meaning here\n", .{ service, source });
        return error.BadVolume;
    }
    var key = source;
    while (std.mem.startsWith(u8, key, "./")) key = key[2..];
    while (key.len > 1 and key[key.len - 1] == '/') key = key[0 .. key.len - 1];
    const path = if (std.fs.path.isAbsolute(source)) source else try std.fs.path.join(arena, &.{ directory, key });
    return .{ .named = false, .key = key, .path = path, .target = target, .read_only = read_only };
}

/// The services' `volumes` (schema.Volume), as Docker would give them:
/// - a host file, or a host directory with files in it, is copied into the node's image (`host`:
///   the project's own configuration; a writable directory's copy is the node's own, said);
/// - a named volume, or a host directory missing or empty, is shared (`shared`) when two services
///   or more use it (etcd_demo's members' directories, read by its client's validation), and
///   otherwise left on the node's own disk, where its data survives the node's restarts as the
///   volume's would (and a power loss loses what it had not synced, as for the rest of its disk).
fn volumes_apply(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    services: []const yaml.Value.Entry,
    nodes: []schema.Node,
) !void {
    assert(services.len == nodes.len);
    const Use = struct { node: usize, mount: Mount };
    var uses: std.ArrayList(Use) = .empty;
    for (services, 0..) |service, index| {
        const list = service.value.get("volumes") orelse continue;
        if (list != .sequence) return error.BadVolumes;
        for (list.sequence) |item| {
            const mount = try mount_parse(arena, directory, service.key, item) orelse continue;
            try uses.append(arena, .{ .node = index, .mount = mount });
        }
    }
    const volumes = try arena.alloc(std.ArrayList(schema.Volume), nodes.len);
    @memset(volumes, .empty);
    for (uses.items) |use| {
        const mount = use.mount;
        const service = nodes[use.node].name;
        if (!mount.named) {
            const kind = try host_kind(io, mount.path);
            if (kind == .file or kind == .directory_with_files) {
                if (kind == .directory_with_files and !mount.read_only) {
                    std.debug.print("[determinismo] compose: {s}.volumes {s}: a directory with files, " ++
                        "copied into its image (its own, not shared)\n", .{ service, mount.key });
                }
                try volumes[use.node].append(arena, .{ .path = mount.target, .host = mount.path });
                continue;
            }
        }
        var users: usize = 0;
        for (uses.items, 0..) |other, at| {
            if (other.mount.named != mount.named or !std.mem.eql(u8, other.mount.key, mount.key)) continue;
            const first = for (uses.items[0..at]) |earlier| {
                if (earlier.node == other.node and earlier.mount.named == mount.named and std.mem.eql(u8, earlier.mount.key, mount.key)) break false;
            } else true;
            users += @intFromBool(first);
        }
        if (users < 2) {
            std.debug.print("[determinismo] compose: {s}.volumes {s}: used by it alone, on its own disk\n", .{ service, mount.key });
            continue;
        }
        try volumes[use.node].append(arena, .{
            .path = mount.target,
            .shared = try shared_name(arena, mount),
            .read_only = mount.read_only,
        });
    }
    for (nodes, volumes) |*node, list| {
        if (list.items.len > schema.volumes_max) return error.TooManyVolumes;
        node.volumes = list.items;
    }
}

const HostKind = enum { missing, file, directory_empty, directory_with_files };

fn host_kind(io: std.Io, path: []const u8) !HostKind {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir => return .file,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    return if (try iterator.next(io) != null) .directory_with_files else .directory_empty;
}

/// A shared volume's name (schema.volume_name_valid): "v-" and a named volume's name, "b-" and a
/// host directory's path ('/' as '-', other bytes no name has as '_'); past 64 bytes, its last
/// 47 and a hash of the whole.
fn shared_name(arena: std.mem.Allocator, mount: Mount) ![]const u8 {
    const text = try std.fmt.allocPrint(arena, "{s}-{s}", .{
        if (mount.named) "v" else "b",
        std.mem.trimStart(u8, mount.key, "/"),
    });
    for (text) |*byte| byte.* = switch (byte.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => byte.*,
        '/' => '-',
        else => '_',
    };
    if (text.len <= schema.volume_name_size_max) return text;
    return std.fmt.allocPrint(arena, "{s}-{x:0>16}", .{ text[text.len - 47 ..], std.hash.Wyhash.hash(0, text) });
}

test volumes_apply {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.writeFile(io, .{ .sub_path = "pd.toml", .data = "name = 1\n" });
    try tmp.dir.createDirPath(io, "empty");
    const root = try yaml.parse(arena,
        \\init:
        \\  image: ubuntu
        \\  volumes:
        \\    - /tmp/etcddata0:/var/etcddata0
        \\    - ./empty:/var/report
        \\etcd0:
        \\  image: etcd
        \\  depends_on:
        \\    init:
        \\      condition: service_completed_successfully
        \\  volumes:
        \\    - /tmp/etcddata0/:/var/etcd/data
        \\    - ./pd.toml:/pd.toml:ro
        \\    - own:/var/own
        \\    - /anonymous
        \\client:
        \\  image: client
        \\  volumes:
        \\    - type: bind
        \\      source: /tmp/etcddata0
        \\      target: /var/etcddata0
        \\      read_only: true
        \\    - empty:/var/report
        \\
    );
    var nodes = [_]schema.Node{
        .{ .name = "init", .source = .{} },
        .{ .name = "etcd0", .source = .{} },
        .{ .name = "client", .source = .{} },
    };
    const services = root.mapping;
    try once_mark(&nodes, services);
    try std.testing.expect(nodes[0].once and !nodes[1].once and !nodes[2].once);
    try volumes_apply(arena, io, directory, services, &nodes);
    // /tmp/etcddata0 is used by all three ("/" at its end the same), shared.
    try std.testing.expectEqual(@as(usize, 1), nodes[0].volumes.len); // ./empty: init's alone.
    try std.testing.expectEqualStrings("b-tmp-etcddata0", nodes[0].volumes[0].shared.?);
    try std.testing.expectEqualStrings("/var/etcd/data", nodes[1].volumes[0].path);
    try std.testing.expectEqualStrings("b-tmp-etcddata0", nodes[1].volumes[0].shared.?);
    // The project's file: copied into etcd0's image; `own` and the anonymous one on its disk.
    try std.testing.expectEqual(@as(usize, 2), nodes[1].volumes.len);
    try std.testing.expect(std.mem.endsWith(u8, nodes[1].volumes[1].host.?, "pd.toml"));
    try std.testing.expect(nodes[2].volumes[0].read_only);
    // client's `empty` is a named volume, not ./empty: its own.
    try std.testing.expectEqual(@as(usize, 1), nodes[2].volumes.len);
}

test shared_name {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long: Mount = .{ .named = false, .key = "/a/directory/directory/directory/directory/directory/directory/directory/directory", .path = "", .target = "/x", .read_only = false };
    const name = try shared_name(arena, long);
    try std.testing.expectEqual(@as(usize, 64), name.len);
    try std.testing.expect(schema.volume_name_valid(name));
    const named: Mount = .{ .named = true, .key = "pg data", .path = "", .target = "/x", .read_only = false };
    try std.testing.expectEqualStrings("v-pg_data", try shared_name(arena, named));
}

/// Compose's `restart`: "no" leaves a failed container down; the others start it again.
fn restart_supervises(policy: []const u8) !bool {
    if (std.mem.eql(u8, policy, "no")) return false;
    if (std.mem.eql(u8, policy, "always") or std.mem.eql(u8, policy, "unless-stopped")) return true;
    if (std.mem.eql(u8, policy, "on-failure") or std.mem.startsWith(u8, policy, "on-failure:")) return true;
    return error.BadRestartPolicy;
}

test restart_supervises {
    try std.testing.expect(!try restart_supervises("no"));
    try std.testing.expect(try restart_supervises("always"));
    try std.testing.expect(try restart_supervises("unless-stopped"));
    try std.testing.expect(try restart_supervises("on-failure:3"));
    try std.testing.expectError(error.BadRestartPolicy, restart_supervises("sometimes"));
}

/// Compose's `ulimits`: per name one value (soft and hard) or a `soft` and a `hard`; -1 is
/// unlimited, as in Docker.
fn ulimits(arena: std.mem.Allocator, value: ?yaml.Value) !?[]const schema.Ulimit {
    const given = value orelse return null;
    if (given != .mapping) return error.BadUlimits;
    var out: std.ArrayList(schema.Ulimit) = .empty;
    for (given.mapping) |entry| {
        const soft, const hard = switch (entry.value) {
            .scalar => |text| .{ try ulimit_value(text), try ulimit_value(text) },
            .mapping => .{
                try ulimit_value(try scalar(entry.value.get("soft") orelse return error.BadUlimits)),
                try ulimit_value(try scalar(entry.value.get("hard") orelse return error.BadUlimits)),
            },
            .sequence, .empty => return error.BadUlimits,
        };
        try out.append(arena, .{ .name = entry.key, .soft = soft, .hard = hard });
    }
    return out.items;
}

fn ulimit_value(text: []const u8) !u64 {
    if (std.mem.eql(u8, text, "-1") or std.mem.eql(u8, text, "unlimited")) return schema.Ulimit.unlimited;
    return std.fmt.parseInt(u64, text, 10) catch error.BadUlimits;
}

test ulimits {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try yaml.parse(arena,
        \\ulimits:
        \\  nproc: 65535
        \\  memlock: -1
        \\  nofile:
        \\    soft: 20000
        \\    hard: 40000
        \\
    );
    const parsed = (try ulimits(arena, root.get("ulimits"))).?;
    try std.testing.expectEqual(3, parsed.len);
    try std.testing.expectEqualStrings("nproc", parsed[0].name);
    try std.testing.expectEqual(65535, parsed[0].hard);
    try std.testing.expectEqual(schema.Ulimit.unlimited, parsed[1].soft);
    try std.testing.expectEqual(20000, parsed[2].soft);
    try std.testing.expectEqual(40000, parsed[2].hard);
    try std.testing.expectEqual(null, try ulimits(arena, null));
}

/// A Compose byte value ("64m", "1g", "512mb", "1048576") in MiB, rounded up.
fn memory_mib(text: []const u8) !u32 {
    const digits = for (text, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte)) break index;
    } else text.len;
    const number = try std.fmt.parseInt(u64, text[0..digits], 10);
    const suffix = text[digits..];
    const shifts = [_]struct { []const u8, u6 }{
        .{ "", 0 },   .{ "b", 0 },   .{ "k", 10 }, .{ "kb", 10 },
        .{ "m", 20 }, .{ "mb", 20 }, .{ "g", 30 }, .{ "gb", 30 },
    };
    for (shifts) |entry| {
        if (!std.ascii.eqlIgnoreCase(suffix, entry[0])) continue;
        const bytes = std.math.shlExact(u64, number, entry[1]) catch return error.BadMemLimit;
        const mib = @divCeil(bytes, 1 << 20);
        return std.math.cast(u32, mib) orelse error.BadMemLimit;
    }
    return error.BadMemLimit;
}

fn build_source(arena: std.mem.Allocator, directory: []const u8, value: yaml.Value) !schema.Build {
    const context, const dockerfile, const args = switch (value) {
        .scalar => |text| .{ text, "Dockerfile", &.{} },
        .mapping => .{
            try scalar(value.get("context") orelse return error.BuildWithoutContext),
            if (value.get("dockerfile")) |file| try scalar(file) else "Dockerfile",
            try build_arguments(arena, value.get("args")),
        },
        else => return error.BadBuild,
    };
    const absolute = std.fs.path.isAbsolute(context);
    return .{
        .context = if (absolute) context else try std.fs.path.join(arena, &.{ directory, context }),
        .dockerfile = dockerfile,
        .args = args,
    };
}

/// A build's `args` (a map, or a list of "NAME=value"), as `--build-arg NAME=value`. A name
/// without a value takes the caller's environment's in Compose, which is never read here (the
/// same files make the same system): left out, the Dockerfile's default stands.
fn build_arguments(arena: std.mem.Allocator, value: ?yaml.Value) ![]const []const u8 {
    const present = value orelse return &.{};
    var entries: std.ArrayList([]const u8) = .empty;
    switch (present) {
        .sequence => |items| for (items) |item| {
            const text = try scalar(item);
            if (std.mem.indexOfScalar(u8, text, '=') != null) try entries.append(arena, text);
        },
        .mapping => |fields| for (fields) |field| {
            if (field.value == .empty) continue;
            try entries.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ field.key, try scalar(field.value) }));
        },
        .empty => {},
        .scalar => return error.BadBuildArgs,
    }
    return entries.items;
}

test build_source {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // hashicorp-raft-formalized's server: which of its patches are built in is a build argument
    // (RAFT_PATCHES), so a build without it is another system.
    const root = try yaml.parse(arena,
        \\mapped:
        \\  context: ../..
        \\  dockerfile: antithesis-fm/server/Dockerfile
        \\  args:
        \\    RAFT_PATCHES: R1 R3 R4 R5
        \\    UNSET:
        \\listed:
        \\  context: .
        \\  args:
        \\    - VERSION=2
        \\    - FROM_ENVIRONMENT
        \\
    );
    const mapped = try build_source(arena, "/p/config", root.get("mapped").?);
    try std.testing.expectEqualStrings("antithesis-fm/server/Dockerfile", mapped.dockerfile);
    try std.testing.expectEqual(1, mapped.args.len);
    try std.testing.expectEqualStrings("RAFT_PATCHES=R1 R3 R4 R5", mapped.args[0]);
    // A name without a value is the caller's environment's in Compose, which is never read here
    // (the same files make the same system): the Dockerfile's default stands.
    const listed = try build_source(arena, "/p", root.get("listed").?);
    try std.testing.expectEqual(1, listed.args.len);
    try std.testing.expectEqualStrings("VERSION=2", listed.args[0]);
}

/// A service's labels (a list of "key=value" or a map, as `environment`): `determinismo.faults`
/// changes its node's fault kinds as explore's --faults does ("+restart,+crash,-partition"),
/// `determinismo.no-faults: "true"` turns them all off (a client, a monitor), the faults a Compose
/// project declares in its own file as a Zig profile does. Other labels mean nothing here: said.
fn labels_apply(arena: std.mem.Allocator, service: []const u8, faults: *schema.Faults, value: ?yaml.Value) !void {
    const prefix = "determinismo.";
    for (try environment(arena, value)) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        const key = entry[0..equals];
        const text = if (equals < entry.len) entry[equals + 1 ..] else "";
        if (std.mem.eql(u8, key, prefix ++ "faults")) {
            try schema.faults_change(faults, text);
        } else if (std.mem.eql(u8, key, prefix ++ "no-faults")) {
            if (std.mem.eql(u8, text, "true")) schema.faults_none(faults);
        } else {
            std.debug.print("[determinismo] compose: {s}.labels.{s} is ignored\n", .{ service, key });
        }
    }
}

test labels_apply {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try yaml.parse(arena,
        \\db:
        \\  labels:
        \\    determinismo.faults: "+restart,+crash,-partition"
        \\client:
        \\  labels:
        \\    - determinismo.no-faults=true
        \\
    );
    var db: schema.Faults = .{};
    try labels_apply(arena, "db", &db, root.get("db").?.get("labels"));
    try std.testing.expect(db.restart and db.crash and !db.partition and db.pause);
    var client: schema.Faults = .{};
    try labels_apply(arena, "client", &client, root.get("client").?.get("labels"));
    try std.testing.expect(!client.pause and !client.isolate and !client.partition);
    var none: schema.Faults = .{};
    try labels_apply(arena, "x", &none, null);
    try std.testing.expect(none.pause);
}

fn environment(arena: std.mem.Allocator, value: ?yaml.Value) ![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    try entries.append(arena, sdk_output_variable);
    const present = value orelse return entries.items;
    switch (present) {
        .sequence => |items| for (items) |item| try entries.append(arena, try scalar(item)),
        .mapping => |fields| for (fields) |field| {
            const text = if (field.value == .empty) "" else try scalar(field.value);
            const entry = try std.fmt.allocPrint(arena, "{s}={s}", .{ field.key, text });
            try entries.append(arena, entry);
        },
        .empty => {},
        .scalar => return error.BadEnvironment,
    }
    return entries.items;
}

fn dependencies(arena: std.mem.Allocator, value: ?yaml.Value) ![]const []const u8 {
    const present = value orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    switch (present) {
        .sequence => |items| for (items) |item| try names.append(arena, try scalar(item)),
        .mapping => |fields| for (fields) |field| try names.append(arena, field.key),
        else => return error.BadDependsOn,
    }
    return names.items;
}

/// The container side of the first `ports` entry ("8080:80", "80", {target: 80}) or `expose`.
fn first_port(fields: yaml.Value) !?u16 {
    for ([_][]const u8{ "ports", "expose" }) |key| {
        const list = fields.get(key) orelse continue;
        if (list != .sequence or list.sequence.len == 0) continue;
        const entry = list.sequence[0];
        const text = switch (entry) {
            .scalar => |port| port,
            .mapping => try scalar(entry.get("target") orelse return error.BadPort),
            else => return error.BadPort,
        };
        const colon = std.mem.lastIndexOfScalar(u8, text, ':');
        const container = text[if (colon) |index| index + 1 else 0..];
        const protocol = std.mem.indexOfScalar(u8, container, '/') orelse container.len;
        const number = container[0..protocol];
        return try std.fmt.parseInt(u16, number, 10);
    }
    return null;
}

/// Dependencies first; the schema wants `after` to name earlier nodes only.
fn dependency_order(arena: std.mem.Allocator, nodes: []const schema.Node) ![]const schema.Node {
    const ordered = try arena.alloc(schema.Node, nodes.len);
    var placed = try arena.alloc(bool, nodes.len);
    @memset(placed, false);
    var count: usize = 0;
    while (count < nodes.len) {
        const before = count;
        for (nodes, 0..) |node, index| {
            if (placed[index]) continue;
            const ready = for (node.after) |dependency| {
                const known = for (ordered[0..count]) |done| {
                    if (std.mem.eql(u8, done.name, dependency)) break true;
                } else false;
                if (!known) break false;
            } else true;
            if (!ready) continue;
            ordered[count] = node;
            placed[index] = true;
            count += 1;
        }
        if (count == before) return error.DependencyCycleOrUnknownService;
    }
    return ordered;
}

/// Compose's variables: `${NAME}`, `${NAME:-default}` (also when empty), `${NAME-default}`,
/// `$NAME` and `$$` (a dollar), from the `.env` beside the file (NAME=value lines). Not from
/// the caller's environment: the same files make the same system.
fn interpolate(arena: std.mem.Allocator, source: []const u8, env: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < source.len) {
        const dollar = std.mem.indexOfScalarPos(u8, source, at, '$') orelse {
            try out.appendSlice(arena, source[at..]);
            break;
        };
        try out.appendSlice(arena, source[at..dollar]);
        const rest = source[dollar + 1 ..];
        if (rest.len > 0 and rest[0] == '$') {
            try out.append(arena, '$');
            at = dollar + 2;
            continue;
        }
        if (rest.len > 0 and rest[0] == '{') {
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse return error.BadVariable;
            const body = rest[1..close];
            const name_end = std.mem.indexOfAny(u8, body, ":-") orelse body.len;
            const name = body[0..name_end];
            const value = env_value(env, name);
            const default: ?[]const u8 = if (std.mem.startsWith(u8, body[name_end..], ":-"))
                body[name_end + 2 ..]
            else if (std.mem.startsWith(u8, body[name_end..], "-")) body[name_end + 1 ..] else null;
            const empty_counts = std.mem.startsWith(u8, body[name_end..], ":-");
            const chosen = if (value) |text|
                (if (empty_counts and text.len == 0) default orelse "" else text)
            else
                default orelse "";
            try out.appendSlice(arena, chosen);
            at = dollar + 2 + close;
            continue;
        }
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
            end += 1;
        }
        if (end == 0) {
            try out.append(arena, '$');
            at = dollar + 1;
            continue;
        }
        try out.appendSlice(arena, env_value(env, rest[0..end]) orelse "");
        at = dollar + 1 + end;
    }
    return out.items;
}

fn env_value(env: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, env, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..equals], " "), name)) continue;
        return std.mem.trim(u8, trimmed[equals + 1 ..], " \"'");
    }
    return null;
}

test interpolate {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const image = "node:${BUILD_TAG:-latest}";
    try std.testing.expectEqualStrings("node:latest", try interpolate(a, image, ""));
    try std.testing.expectEqualStrings("node:v2", try interpolate(a, image, "BUILD_TAG=v2\n"));
    try std.testing.expectEqualStrings("a $ b", try interpolate(a, "a $$ b", ""));
}

fn scalar(value: yaml.Value) ![]const u8 {
    return switch (value) {
        .scalar => |text| text,
        else => error.ExpectedScalar,
    };
}

/// A list as is, or a string split like a shell does (quotes group, backslash escapes).
fn words(arena: std.mem.Allocator, value: yaml.Value) ![]const []const u8 {
    switch (value) {
        .sequence => |items| {
            const list = try arena.alloc([]const u8, items.len);
            for (items, list) |item, *word| word.* = try scalar(item);
            return list;
        },
        .scalar => |text| return split_shell(arena, text),
        else => return error.BadCommand,
    }
}

fn split_shell(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |open| {
            if (byte == open) {
                quote = null;
            } else if (byte == '\\' and open == '"' and index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
            } else try word.append(arena, byte);
            continue;
        }
        switch (byte) {
            ' ', '\t', '\n' => if (in_word) {
                try list.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '"', '\'' => {
                quote = byte;
                in_word = true;
            },
            '\\' => if (index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
                in_word = true;
            },
            else => {
                try word.append(arena, byte);
                in_word = true;
            },
        }
    }
    if (quote != null) return error.UnterminatedQuote;
    if (in_word) try list.append(arena, try word.toOwnedSlice(arena));
    return list.items;
}

const templates_root = "opt/antithesis/test/v1/";

/// A file directly in a test template (/opt/antithesis/test/v1/<template>/<name>), as an
/// image's listing has it (prepare.zig's templates_of): `<state> <path>` a line.
pub const TemplateFile = struct {
    template: []const u8,
    name: []const u8,
    /// Without the leading slash.
    path: []const u8,
    state: State,

    pub const State = enum(u8) {
        /// Executable, and an ELF binary, a script with a shebang or a link.
        runs = 'x',
        not_executable = 'n',
        /// Executable but neither: exec fails (ENOEXEC).
        no_interpreter = 's',
    };
};

/// Whether an image's member is directly in a test template.
pub fn template_member(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, templates_root)) return false;
    const rest = path[templates_root.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return slash > 0 and slash + 1 < rest.len and std.mem.indexOfScalar(u8, rest[slash + 1 ..], '/') == null;
}

pub fn template_file(line: []const u8) ?TemplateFile {
    if (line.len < 3 or line[1] != ' ') return null;
    const state = std.enums.fromInt(TemplateFile.State, line[0]) orelse return null;
    const path = std.mem.trimStart(u8, line[2..], "./");
    if (!template_member(path)) return null;
    const rest = path[templates_root.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/').?;
    return .{ .template = rest[0..slash], .name = rest[slash + 1 ..], .path = path, .state = state };
}

/// Scenarios from Antithesis test templates found in a node's image: every file directly in
/// /opt/antithesis/test/v1/<template>/ whose name starts with a test-command prefix, a command
/// when it can run, invalid otherwise (others are the commands' helpers).
pub fn templates(
    arena: std.mem.Allocator,
    node: []const u8,
    listing: []const []const u8,
    scenarios: *std.ArrayList(schema.Scenario),
) !void {
    const Found = struct {
        commands: std.ArrayList(schema.Command) = .empty,
        invalid: std.ArrayList(schema.InvalidCommand) = .empty,
    };
    var found: std.StringArrayHashMapUnmanaged(Found) = .empty;
    for (listing) |line| {
        const file = template_file(line) orelse continue;
        const kind = command_kind(file.name) orelse continue;
        const entry = try found.getOrPut(arena, file.template);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const path = try std.fmt.allocPrint(arena, "/{s}", .{file.path});
        switch (file.state) {
            .runs => try entry.value_ptr.commands.append(arena, .{ .kind = kind, .name = file.name, .path = path }),
            .not_executable => try entry.value_ptr.invalid.append(arena, .{ .path = path, .why = "not executable" }),
            .no_interpreter => try entry.value_ptr.invalid.append(arena, .{
                .path = path,
                .why = "neither an ELF binary nor a script with a shebang (#!)",
            }),
        }
    }
    for (found.keys(), found.values()) |template, *entry| {
        const scenario = schema.Scenario{
            .name = template,
            .commands = entry.commands.items,
            .node = node,
            .invalid = entry.invalid.items,
        };
        try scenarios.append(arena, scenario);
    }
}

fn command_kind(name: []const u8) ?schema.Kind {
    const prefixes = [_]struct { []const u8, schema.Kind }{
        // Not Antithesis's: runs before setup_complete, so branches start after it (a cluster
        // that is ready, rather than one still starting).
        .{ "setup_", .setup },
        .{ "first_", .first },
        .{ "parallel_driver_", .parallel_driver },
        .{ "serial_driver_", .serial_driver },
        .{ "singleton_driver_", .singleton_driver },
        .{ "anytime_", .anytime },
        .{ "eventually_", .eventually },
        .{ "finally_", .finally },
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix[0])) return prefix[1];
    }
    return null;
}

test memory_mib {
    try std.testing.expectEqual(@as(u32, 64), try memory_mib("64m"));
    try std.testing.expectEqual(@as(u32, 1024), try memory_mib("1G"));
    try std.testing.expectEqual(@as(u32, 512), try memory_mib("512mb"));
    try std.testing.expectEqual(@as(u32, 1), try memory_mib("1000"));
    try std.testing.expectError(error.BadMemLimit, memory_mib("5x"));
}

test split_shell {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const parts = try split_shell(arena_state.allocator(), "redis-server --save \"\" 'a b' c\\ d");
    try std.testing.expectEqual(@as(usize, 5), parts.len);
    try std.testing.expectEqualStrings("", parts[2]);
    try std.testing.expectEqualStrings("a b", parts[3]);
    try std.testing.expectEqualStrings("c d", parts[4]);
}

test templates {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    const listing = [_][]const u8{
        "x ./opt/antithesis/test/v1/bank/parallel_driver_transfer.sh",
        "x opt/antithesis/test/v1/bank/finally_check",
        "x opt/antithesis/test/v1/bank/helper_lib.sh",
        "n opt/antithesis/test/v1/bank/anytime_forgot_chmod.sh",
        "s opt/antithesis/test/v1/bank/eventually_no_shebang",
        "n opt/antithesis/test/v1/bank/README.md",
        "x opt/antithesis/test/v1/bank/lib/serial_driver_nested.sh",
        "x usr/bin/redis-server",
    };
    try templates(arena_state.allocator(), "client", &listing, &scenarios);
    try std.testing.expectEqual(@as(usize, 1), scenarios.items.len);
    const bank = scenarios.items[0];
    try std.testing.expectEqualStrings("bank", bank.name);
    try std.testing.expectEqual(@as(usize, 2), bank.commands.len);
    const path = bank.commands[1].path.?;
    try std.testing.expectEqualStrings("/opt/antithesis/test/v1/bank/finally_check", path);
    // Named as commands, they cannot run; a helper and a nested file are no commands.
    try std.testing.expectEqual(@as(usize, 2), bank.invalid.len);
    try std.testing.expectEqualStrings("/opt/antithesis/test/v1/bank/anytime_forgot_chmod.sh", bank.invalid[0].path);
    try std.testing.expectEqualStrings("not executable", bank.invalid[0].why);
    try std.testing.expectEqualStrings("/opt/antithesis/test/v1/bank/eventually_no_shebang", bank.invalid[1].path);
}

test template_member {
    try std.testing.expect(template_member("opt/antithesis/test/v1/bank/first_x"));
    try std.testing.expect(!template_member("opt/antithesis/test/v1/bank/"));
    try std.testing.expect(!template_member("opt/antithesis/test/v1/bank"));
    try std.testing.expect(!template_member("opt/antithesis/test/v1/bank/lib/first_x"));
    try std.testing.expect(!template_member("opt/antithesis/test/v1//first_x"));
    try std.testing.expect(!template_member("usr/bin/x"));
}
