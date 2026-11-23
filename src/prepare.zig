// SPDX-License-Identifier: MIT
//! Turns a test program into the disks a run boots with (ARCHITECTURE.md §10).
//!
//! 1. `<program> --describe` prints the system description (profiles and scenarios).
//! 2. The chosen profile is resolved: each node's root filesystem is materialized as an erofs
//!    image (OCI images through podman, cached by image ID), its command and environment are
//!    merged with the image's, and it gets an address and a disk.
//! 3. Disk 0 (the system disk) gets the program and /det/system.json: the frozen, resolved
//!    profile, which is also the run record of what was tested.
//!
//! Host tools: podman (for `image` sources) and mkfs.erofs (erofs-utils 1.7 or later).
const std = @import("std");
const assert = std.debug.assert;
const schema = @import("determinismo").schema;
const compose = @import("compose.zig");
const checks = @import("checks.zig");
const kubernetes = @import("kubernetes.zig");
const source_lines = @import("lines.zig");

pub const Options = struct {
    /// The test program (its `--describe`), or else a Compose file whose services become the
    /// nodes and whose images' Antithesis test templates become the scenarios.
    program: ?[]const u8 = null,
    /// A system with no scenario given one named `none`, with no commands: a sandbox's or a CI
    /// job's (a fast VM in dev mode, a held machine), which run their own commands.
    scenario_none: bool = false,
    compose: ?[]const u8 = null,
    /// Or a directory of Kubernetes manifests, run in a single-node K3s cluster (kubernetes.zig)
    /// whose images' Antithesis test templates become the scenarios.
    kubernetes: ?[]const u8 = null,
    /// Images loaded beside those the manifests name (explore's --images, comma-separated).
    kubernetes_images: ?[]const u8 = null,
    /// A script for the composer and the fault injector (/det/script.json on the system disk).
    script: ?[]const u8 = null,
    /// Fault injectors of the run's own (/det/injectors/<name> on the system disk, by its file's
    /// name): each timeline's injector a named decision among det-faults and them (composer.zig).
    injectors: []const []const u8 = &.{},
    /// The profile to resolve; null takes the first one.
    profile: ?[]const u8 = null,
    cache_directory: []const u8,
    /// A mutant (`determinismo mutate`): this node is built from its build context with a patch
    /// applied ("<node>=<patch file>").
    mutant: ?[]const u8 = null,
    /// Fault kinds every node also allows ("restart,crash"), and nodes that allow none
    /// ("client,monitor"): what an Antithesis launch says outside its Compose file.
    faults_added: ?[]const u8 = null,
    faults_none: ?[]const u8 = null,
    /// Every node's coverage set (schema.Coverage, as DETERMINISMO_COVERAGE: "include,-exclude"),
    /// in place of its own, in its environment and its image's build; "off": nothing covered (a
    /// set no name is in), the same build otherwise: the cost of the instrumentation, measured.
    coverage: ?[]const u8 = null,
    /// A pinned system (`explore --system`): what an earlier prepare resolved and the node disks
    /// it booted (its pin, `<cache>/systems/<hash>.pin.json`), used as is: nothing is described,
    /// pulled or built, so a run replays on another host (of the same CPU model) without its
    /// images or Dockerfiles. Faults were adjusted when it was pinned.
    pinned: ?[]const u8 = null,
};

pub const Prepared = struct {
    /// Disk 0 first, then one disk per node, in node order.
    disk_paths: []const []const u8,
    system: schema.System,
    system_json: []const u8,
    /// Identifies the resolved system: snapshots and runs are keyed by it.
    hash: u64,
    /// Its pin (`Options.pinned`).
    pin_path: []const u8,
    /// The test program's table of lines (lines.zig), for the program run on this host (its
    /// checks: `DETERMINISMO_LINES`); null without a program, or one with no debug information.
    program_lines: ?[]const u8 = null,
};

/// A resolved system with its node disks: their paths, absolute or relative to the pin's
/// directory (a kit: the pin and the disks side by side).
pub const Pin = struct {
    /// The resolved system's JSON, byte for byte: it is hashed.
    system_json: []const u8,
    /// One per node, in node order.
    disks: []const []const u8,
};

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    cache: []const u8,
    mutant: ?[]const u8 = null,
};

const description_size_max = 1 << 20;
const filesystem_uuid = "64657465-726d-696e-6973-6d6f00000000";
const path_default = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub fn prepare(arena: std.mem.Allocator, io: std.Io, options: Options) !Prepared {
    const context = Context{
        .arena = arena,
        .io = io,
        .cache = options.cache_directory,
        .mutant = options.mutant,
    };
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "images", "systems", "staging", "profiles", "mutants", "kubernetes" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ context.cache, directory }));
    }
    if (options.pinned) |path| return pinned_prepare(context, options, path);
    const description = try describe(context, options);
    if (description.schema != schema.version) return error.SchemaVersion;
    const profile = try profile_find(&description, options.profile);
    try profile_check(profile);

    const resolved = try arena.alloc(schema.Resolved, profile.nodes.len);
    const disk_paths = try arena.alloc([]const u8, profile.nodes.len + 1);
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    try scenarios.appendSlice(arena, description.scenarios);
    // The newest image's day of creation (Unix seconds, 0: none known): the guest's clock starts
    // after it unless the profile says when.
    var newest: u64 = 0;
    for (profile.nodes, resolved, disk_paths[1..], 0..) |*described, *target, *disk, index| {
        var adjusted = described.*;
        try coverage_adjust(arena, &adjusted, options.coverage);
        const node = &adjusted;
        var created: u64 = 0;
        disk.* = try node_resolve(context, node, @intCast(index), target, &created);
        newest = @max(newest, created);
        try faults_adjust(&target.faults, node.name, options);
        // A one-shot (schema.Node.once) has ended when commands run: its image's templates are
        // another node's (tests/antithesis-compat/volumes: one image for all three, the
        // composer's commands sent to the ended `init`, "error: NotRunning").
        if (options.compose != null and !node.once) {
            const listing = try templates_listing(context, disk.*);
            try compose.templates(arena, node.name, listing, &scenarios);
        }
    }
    if (scenarios.items.len == 0 and options.scenario_none) try scenarios.append(arena, .{ .name = "none", .commands = &.{} });
    if (scenarios.items.len == 0) return error.NoScenarios;
    // Each node's next release (Node.upgrade) on a disk of its own, after the nodes': within the
    // VMM's disks, as the nodes' are.
    var all_disks: std.ArrayList([]const u8) = .empty;
    try all_disks.appendSlice(arena, disk_paths);
    for (profile.nodes, resolved) |*described, *target| {
        const next = described.upgrade orelse continue;
        const index: u32 = @intCast(all_disks.items.len - 1);
        if (index >= schema.nodes_max) return error.TooManyDisks;
        var created: u64 = 0;
        var variant: schema.Variant = undefined;
        try all_disks.append(arena, try variant_resolve(context, described, next, index, &variant, &created));
        newest = @max(newest, created);
        target.upgrade = variant;
    }
    const system = schema.System{
        .profile = profile.name,
        .nodes = resolved,
        .scenarios = scenarios.items,
        // Compose's systems declare their setup through an Antithesis SDK; a Kubernetes one's
        // is its setup command's (kapp's readiness, as Antithesis's).
        .sdk_setup = options.compose != null,
        .checks = description.checks,
        .explain = profile.explain,
        .retroactive = profile.retroactive,
        .automations = profile.automations,
        .epoch_seconds = profile.epoch_seconds orelse epoch_after(newest),
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(system, .{ .emit_null_optional_fields = false }, &writer.writer);
    const system_json = writer.written();
    const prepared = try system_finish(context, options, system, system_json, all_disks.items);
    const source = options.program orelse options.compose orelse options.kubernetes.?;
    try profile_remember(context, source, &system, system_json);
    return prepared;
}

/// The system disk (the system, the program, the script) and the pin, for a resolved system
/// whose node disks are `disk_paths[1..]`.
fn system_finish(
    context: Context,
    options: Options,
    system: schema.System,
    system_json: []const u8,
    disk_paths: [][]const u8,
) !Prepared {
    const cwd = std.Io.Dir.cwd();
    const program = if (options.program) |path|
        try cwd.readFileAlloc(context.io, path, context.arena, .unlimited)
    else
        "";
    const script = if (options.script) |path|
        try cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 20))
    else
        null;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(system_json);
    hasher.update(program);
    // A program's disk has its table of lines (below): one made without it is another disk.
    if (options.program != null) hasher.update(std.fmt.comptimePrint("lines-{d}", .{source_lines.format_version}));
    if (script) |text| hasher.update(text);
    // Its injectors, by name and content: another set is another disk.
    for (options.injectors) |path| {
        hasher.update(std.fs.path.basename(path));
        hasher.update(try cwd.readFileAlloc(context.io, path, context.arena, .limited(64 << 20)));
    }
    const hash = hasher.final();
    const program_lines = if (options.program) |path| try program_lines_make(context, path, program) else null;
    disk_paths[0] = try system_disk(context, .{
        .system_json = system_json,
        .program = options.program,
        .program_lines = program_lines,
        .script = script,
        .injectors = options.injectors,
        .hash = hash,
    });
    // The pin names the node disks by absolute path: it is valid wherever it is copied to on
    // this host (a kit for another host has them beside it, by name).
    const disks = try context.arena.alloc([]const u8, disk_paths.len - 1);
    for (disk_paths[1..], disks) |disk, *absolute| {
        absolute.* = try cwd.realPathFileAlloc(context.io, disk, context.arena);
    }
    var writer: std.Io.Writer.Allocating = .init(context.arena);
    const pin: Pin = .{ .system_json = system_json, .disks = disks };
    try std.json.Stringify.value(pin, .{}, &writer.writer);
    const pin_name = try std.fmt.allocPrint(context.arena, "{x:0>16}.pin.json", .{hash});
    const pin_path = try path_join(context, &.{ context.cache, "systems", pin_name });
    if (!exists(context, pin_path)) {
        const staging = try own_path(context, pin_path, "partial");
        try cwd.writeFile(context.io, .{ .sub_path = staging, .data = writer.written() });
        try cwd.rename(staging, cwd, pin_path, context.io);
    }
    return .{
        .disk_paths = disk_paths,
        .system = system,
        .system_json = system_json,
        .hash = hash,
        .pin_path = pin_path,
        .program_lines = if (program_lines) |lines| try path_join(context, &.{ lines.directory, lines.name }) else null,
    };
}

/// The test program's table of lines, where a program run on this host finds it.
const ProgramLines = struct {
    /// `<cache>/symbols/<the program's content and the format>`: the table alone in it.
    directory: []const u8,
    /// lines.zig's name for it: the program's build ID, or `name-<its file's name>`.
    name: []const u8,
};

/// The program's table of lines and functions (lines.zig), made once a program in the cache:
/// the Zig SDK names an assertion's site and an edge's line from it, in the guest (disk 0's
/// /symbols, below) and on this host (its checks, given the file), and reads no debug
/// information itself. Null
/// for a program without debug information (another language's, a stripped one).
fn program_lines_make(context: Context, path: []const u8, content: []const u8) !?ProgramLines {
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const directory = try path_join(context, &.{ context.cache, "symbols", try std.fmt.allocPrint(
        context.arena,
        "{x:0>16}-lines-{d}",
        .{ std.hash.Wyhash.hash(0, content), source_lines.format_version },
    ) });
    // Made before: the one file in it.
    if (cwd.openDir(io, directory, .{ .iterate = true })) |opened| {
        var known = opened;
        defer known.close(io);
        var entries = known.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind == .file) return .{ .directory = directory, .name = try context.arena.dupe(u8, entry.name) };
        }
        return null; // A program with no table: its empty directory says so.
    } else |_| {}
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const table = source_lines.of(std.heap.smp_allocator, scratch.allocator(), io, path) catch null;
    // Whole or not at all: in a directory of this process's own, renamed into place.
    const staging = try own_path(context, directory, "partial");
    errdefer cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    if (table) |made| {
        try cwd.writeFile(io, .{ .sub_path = try path_join(context, &.{ staging, made.name }), .data = made.bytes });
        std.debug.print("[determinismo] source lines of {s}: {d} bytes\n", .{ path, made.bytes.len });
    }
    cwd.rename(staging, cwd, directory, io) catch |err| {
        // Another prepare of the same program made it meanwhile: its own is the same.
        cwd.deleteTree(io, staging) catch {};
        if (!exists(context, directory)) return err;
    };
    const made = table orelse return null;
    return .{ .directory = directory, .name = try context.arena.dupe(u8, made.name) };
}

/// `Options.pinned`: the pin's system and node disks, as they are.
fn pinned_prepare(context: Context, options: Options, path: []const u8) !Prepared {
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(description_size_max);
    const pin = try schema.parse(Pin, context.arena, try cwd.readFileAlloc(context.io, path, context.arena, limit));
    const system = try schema.parse(schema.System, context.arena, pin.system_json);
    var upgrades: usize = 0;
    for (system.nodes) |node| upgrades += @intFromBool(node.upgrade != null);
    if (pin.disks.len != system.nodes.len + upgrades) return error.PinDisks;
    const disk_paths = try context.arena.alloc([]const u8, pin.disks.len + 1);
    const directory = std.fs.path.dirname(path) orelse ".";
    for (pin.disks, disk_paths[1..]) |disk, *target| {
        target.* = if (std.fs.path.isAbsolute(disk) and exists(context, disk))
            disk
        else
            try path_join(context, &.{ directory, std.fs.path.basename(disk) });
        if (!exists(context, target.*)) {
            std.debug.print("[determinismo] the pinned disk {s} is not there\n", .{disk});
            return error.PinnedDiskMissing;
        }
    }
    return system_finish(context, options, system, pin.system_json, disk_paths);
}

fn profile_find(description: *const schema.Description, name: ?[]const u8) !*const schema.Profile {
    if (description.profiles.len == 0) return error.NoProfiles;
    const wanted = name orelse return &description.profiles[0];
    for (description.profiles) |*profile| {
        if (std.mem.eql(u8, profile.name, wanted)) return profile;
    }
    std.debug.print("[determinismo] no profile named {s}\n", .{wanted});
    return error.UnknownProfile;
}

/// Names valid and unique, one source per node, dependencies on earlier nodes only.
fn profile_check(profile: *const schema.Profile) !void {
    if (profile.nodes.len == 0) return error.NoNodes;
    if (profile.nodes.len > schema.nodes_max) return error.TooManyNodes;
    for (profile.nodes, 0..) |node, index| {
        if (!schema.name_valid(node.name)) return error.BadNodeName;
        if (!schema.knobs_valid(node.knobs)) return error.BadKnobs;
        if (node.source.kind_count() != 1) return error.NodeNeedsOneSource;
        if (node.ulimits) |ulimits| {
            if (ulimits.len > schema.ulimits_max) return error.TooManyUlimits;
            for (ulimits) |ulimit| {
                if (schema.ulimit_resource(ulimit.name) == null or ulimit.soft > ulimit.hard) {
                    std.debug.print("[determinismo] {s}: ulimit {s} (soft {d}, hard {d}) is not one " ++
                        "of Docker's, or its soft limit is above its hard one\n", .{
                        node.name, ulimit.name, ulimit.soft, ulimit.hard,
                    });
                    return error.BadUlimit;
                }
            }
        }
        try volumes_check(&node);
        if (node.aliases.len > schema.aliases_max) return error.TooManyAliases;
        for (node.aliases) |alias| if (!schema.alias_valid(alias)) {
            std.debug.print("[determinismo] {s}: alias {s} is no hostname (1-63 letters, digits, '.', '_' or '-')\n", .{ node.name, alias });
            return error.BadAlias;
        };
        if (node.hostname) |name| if (!schema.alias_valid(name)) return error.BadHostname;
        if (node.ready) |ready| {
            const command = if (ready.command) |argv| argv.len > 0 else false;
            if ((ready.tcp != 0) == command) {
                std.debug.print("[determinismo] {s}: its readiness needs a port or a command, one of them\n", .{node.name});
                return error.BadReady;
            }
        }
        for (profile.nodes[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, node.name)) return error.DuplicateNodeName;
        }
        dependencies: for (node.after) |dependency| {
            for (profile.nodes[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, dependency)) continue :dependencies;
            }
            std.debug.print("[determinismo] {s} must come after {s}\n", .{ node.name, dependency });
            return error.DependencyOrder;
        }
    }
}

/// Its volumes (schema.Volume): an absolute path, one of shared and host, a shared one's name a
/// directory name.
fn volumes_check(node: *const schema.Node) !void {
    if (node.volumes.len > schema.volumes_max) return error.TooManyVolumes;
    for (node.volumes) |volume| {
        const kinds = @intFromBool(volume.shared != null) + @intFromBool(volume.host != null);
        const named = if (volume.shared) |name| schema.volume_name_valid(name) else true;
        if (kinds == 1 and named and std.fs.path.isAbsolute(volume.path)) continue;
        std.debug.print("[determinismo] {s}: a volume at {s} needs an absolute path and one of " ++
            "shared (1-64 letters, digits, '.', '_' or '-') and host\n", .{ node.name, volume.path });
        return error.BadVolume;
    }
}

/// Resolves one node and returns the path of its disk image.
fn node_resolve(
    context: Context,
    node: *const schema.Node,
    index: u32,
    target: *schema.Resolved,
    created: *u64,
) ![]const u8 {
    const arena = context.arena;
    var disk_buffer: [3]u8 = undefined;
    const address = schema.node_address(index);
    target.* = .{
        .name = node.name,
        .address = try std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{
            address[0], address[1], address[2], address[3],
        }),
        .disk = try arena.dupe(u8, schema.node_disk(&disk_buffer, index)),
        .digest = "",
        .command = &.{},
        .env = &.{},
        .ready = node.ready,
        .after = node.after,
        .faults = node.faults,
        .memory_max_mib = node.memory_max_mib,
        .privileged = node.privileged,
        .ulimits = node.ulimits,
        .sysctls = node.sysctls,
        .antithesis_library = node.antithesis_library,
        .crashes_known = node.crashes_known,
        .writeback_s = node.writeback_s,
        .exits_known = node.exits_known,
        .exits_known_disk = node.exits_known_disk,
        .supervised = node.supervised,
        .panics_known = node.panics_known,
        .log_failures = node.log_failures,
        .spare = node.spare,
        .knobs = node.knobs,
        .once = node.once,
        .hostname = node.hostname,
        .aliases = node.aliases,
        .volumes = try volumes_shared(arena, node.volumes),
    };
    // A one-shot is never started again: no fault, no supervisor (schema.Node.once).
    if (node.once) {
        schema.faults_none(&target.faults);
        target.supervised = false;
    }
    const files = for (node.volumes) |volume| {
        if (volume.host != null) break true;
    } else false;
    var image: ImageConfig = .{};
    const disk = if (node.source.image) |reference| disk: {
        const trained = try jvm_caches(context, node, reference);
        const with = if (files) try image_with_files(context, node, trained) else trained;
        break :disk try image_disk(context, with, &image, &target.digest, created);
    } else if (node.source.build) |build| disk: {
        const built = try jvm_caches(context, node, try image_build(context, try mutant_build(context, node, build)));
        const with = if (files) try image_with_files(context, node, built) else built;
        break :disk try image_disk(context, with, &image, &target.digest, created);
    } else if (files) {
        std.debug.print("[determinismo] {s}: host volumes need an image or a build\n", .{node.name});
        return error.VolumeHostNeedsImage;
    } else if (node.source.directory) |directory|
        try directory_disk(context, node.name, directory, &target.digest)
    else
        try binary_disk(context, node.name, node.source.binary.?, &image, &target.digest);
    target.command = try command_merge(arena, &image, node.entrypoint, node.command);
    if (target.command.len == 0) return error.NodeHasNoCommand;
    target.env = try environment_merge(arena, image.Env orelse &.{}, node.env);
    target.workdir = node.workdir orelse if (image.WorkingDir.len > 0) image.WorkingDir else "/";
    target.user = node.user orelse if (image.User.len > 0) image.User else null;
    return disk;
}

/// The node's shared volumes, what the guest mounts (its host ones are in its image).
fn volumes_shared(arena: std.mem.Allocator, volumes: []const schema.Volume) ![]const schema.Volume {
    var shared: std.ArrayList(schema.Volume) = .empty;
    for (volumes) |volume| if (volume.shared != null) try shared.append(arena, volume);
    return shared.items;
}

/// The node's image with its host volumes' files in it (schema.Volume.host): an image `FROM` the
/// node's own (by id) with a COPY each, built from a staging directory of the files. Its config
/// (entrypoint, command, environment, user) is the node's image's.
fn image_with_files(context: Context, node: *const schema.Node, reference: []const u8) ![]const u8 {
    const arena = context.arena;
    const base = try image_id(context, reference);
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", node.name }), "files");
    defer cwd.deleteTree(context.io, staging) catch {};
    try cwd.createDirPath(context.io, staging);
    var dockerfile: std.ArrayList(u8) = .empty;
    try dockerfile.print(arena, "FROM {s}\n", .{base});
    for (node.volumes, 0..) |volume, index| {
        const host = volume.host orelse continue;
        const name = try std.fmt.allocPrint(arena, "v{d}", .{index});
        _ = try tool(context, &.{ "cp", "-a", "--", host, try path_join(context, &.{ staging, name }) });
        // The JSON form: a path with spaces is one argument.
        try dockerfile.print(arena, "COPY [\"{s}\", {f}]\n", .{ name, std.json.fmt(volume.path, .{}) });
    }
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ staging, "Dockerfile" }), .data = dockerfile.items });
    std.debug.print("[determinismo] {s}: its host files copied into its image\n", .{node.name});
    return image_build(context, .{ .context = staging });
}

/// A node's next release (Node.upgrade): its disk at `index` (after the nodes'), its command
/// and environment merged with its image's as the node's own are. Returns its disk image's path.
fn variant_resolve(
    context: Context,
    node: *const schema.Node,
    source: schema.Source,
    index: u32,
    target: *schema.Variant,
    created: *u64,
) ![]const u8 {
    const arena = context.arena;
    var disk_buffer: [3]u8 = undefined;
    target.* = .{
        .disk = try arena.dupe(u8, schema.node_disk(&disk_buffer, index)),
        .digest = "",
        .command = &.{},
        .env = &.{},
    };
    var image: ImageConfig = .{};
    // Its own name for the disks named by node (a directory's): never the node's own disk.
    const name = try std.fmt.allocPrint(arena, "{s}-upgrade", .{node.name});
    const disk = if (source.image) |reference|
        try image_disk(context, reference, &image, &target.digest, created)
    else if (source.build) |build| disk: {
        const built = try image_build(context, build);
        break :disk try image_disk(context, built, &image, &target.digest, created);
    } else if (source.directory) |directory|
        try directory_disk(context, name, directory, &target.digest)
    else if (source.binary) |binary|
        try binary_disk(context, name, binary, &image, &target.digest)
    else
        return error.UpgradeWithoutSource;
    target.command = try command_merge(arena, &image, node.entrypoint, node.command);
    if (target.command.len == 0) return error.NodeHasNoCommand;
    target.env = try environment_merge(arena, image.Env orelse &.{}, node.env);
    target.workdir = node.workdir orelse if (image.WorkingDir.len > 0) image.WorkingDir else "/";
    target.user = node.user orelse if (image.User.len > 0) image.User else null;
    return disk;
}

/// The guest's clock at boot by default: the midnight after the newest image was made, when
/// that is past determinismo's own start (2026-01-01), so an image's data (an initial catalog, a
/// certificate) is never from the guest's future (YugabyteDB 2026.1's catalog was: no read saw
/// it). Null keeps determinismo's.
fn epoch_after(newest: u64) ?u64 {
    const start: u64 = 1767225600; // VM.epoch_seconds_default
    if (newest < start) return null;
    return (newest / std.time.s_per_day + 1) * std.time.s_per_day;
}

/// A date's midnight UTC (`YYYY-MM-DD`), Unix seconds, or null.
pub fn date_seconds(text: []const u8) ?u64 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    // Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const day_of_year = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return @intCast((era * 146097 + day_of_era - 719468) * std.time.s_per_day);
}

test date_seconds {
    try std.testing.expectEqual(1767225600, date_seconds("2026-01-01").?);
    try std.testing.expectEqual(1790812800, date_seconds("2026-10-01").?);
    try std.testing.expectEqual(951782400, date_seconds("2000-02-29").?);
    try std.testing.expectEqual(null, date_seconds("2026-13-01"));
    // YugabyteDB 2026.1's image, made 2026-09-18: its guests start on the 19th.
    try std.testing.expectEqual(date_seconds("2026-09-19").?, epoch_after(date_seconds("2026-09-18").?).?);
    try std.testing.expectEqual(null, epoch_after(date_seconds("2019-08-01").?));
}

/// The part of `podman image inspect` we use (field names are podman's).
const ImageConfig = struct {
    User: []const u8 = "",
    Env: ?[]const []const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    WorkingDir: []const u8 = "",
};

const ImageInspect = struct {
    Id: []const u8,
    Created: []const u8 = "",
    Architecture: []const u8 = "",
    Os: []const u8 = "",
    Config: ImageConfig = .{},
};

fn image_disk(
    context: Context,
    reference: []const u8,
    config: *ImageConfig,
    digest: *[]const u8,
    created: *u64,
) ![]const u8 {
    if (!try tool_succeeds(context, &.{ "podman", "image", "exists", reference })) {
        std.debug.print("[determinismo] pulling {s}\n", .{reference});
        _ = try tool(context, &.{ "podman", "pull", "--quiet", reference });
    }
    const inspect_json = try tool(context, &.{ "podman", "image", "inspect", reference });
    const inspect = try schema.parse([]const ImageInspect, context.arena, inspect_json);
    if (inspect.len != 1) return error.ImageInspect;
    // The guest is x86-64 Linux (Antithesis's "Software images match expected platform"): an
    // image built for another fails as its node starts (exec format error), in every timeline.
    const architecture = inspect[0].Architecture;
    const os = inspect[0].Os;
    if ((architecture.len > 0 and !std.mem.eql(u8, architecture, "amd64")) or (os.len > 0 and !std.mem.eql(u8, os, "linux"))) {
        std.debug.print("[determinismo] {s} is built for {s}/{s}: the guest runs linux/amd64 " ++
            "(build or pull it for that platform: --platform linux/amd64)\n", .{ reference, os, architecture });
        return error.ImagePlatform;
    }
    config.* = inspect[0].Config;
    digest.* = try std.fmt.allocPrint(context.arena, "sha256:{s}", .{inspect[0].Id});
    created.* = if (inspect[0].Created.len >= 10) date_seconds(inspect[0].Created[0..10]) orelse 0 else 0;
    const id = inspect[0].Id;
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "{s}.erofs",
        .{id},
    ) });
    const templates = try std.fmt.allocPrint(context.arena, "{s}.templates", .{disk});
    const lines_note = try std.fmt.allocPrint(context.arena, "{s}.lines-{d}", .{ disk, source_lines.format_version });
    if (exists(context, disk) and exists(context, templates) and exists(context, lines_note)) return disk;
    // An image an earlier format found no symbols in has none now: its disk is as it was, not
    // flattened again (every image on a host, at the format's change).
    if (exists(context, disk) and exists(context, templates)) {
        var earlier: u32 = source_lines.format_version;
        while (earlier > 1) {
            earlier -= 1;
            const note = try std.fmt.allocPrint(context.arena, "{s}.lines-{d}", .{ disk, earlier });
            const said = std.Io.Dir.cwd().readFileAlloc(context.io, note, context.arena, .limited(64)) catch continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, said, " \n"), "0")) break;
            try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = lines_note, .data = "0\n" });
            return disk;
        }
    }
    std.debug.print("[determinismo] flattening {s} into {s}\n", .{ reference, disk });
    const container = std.mem.trim(u8, try tool(context, &.{
        "podman", "create", "--quiet", reference,
    }), " \n");
    defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
    const tar = try own_path(context, disk, "tar");
    _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
    defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
    // Its test templates' files (written before the disk: a disk implies them).
    const listing = try tool(context, &.{ "tar", "-tvf", tar });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = templates,
        .data = try templates_of(context, tar, listing, disk),
    });
    // Source lines of its instrumented native code, in the image (a disk made before lacks them).
    const made = try symbol_lines(context, tar, listing, disk);
    if (made > 0 and exists(context, disk)) try std.Io.Dir.cwd().deleteFile(context.io, disk);
    if (!exists(context, disk)) try erofs_build(context, disk, &.{ "--tar=f", tar });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = lines_note,
        .data = try std.fmt.allocPrint(context.arena, "{d}\n", .{made}),
    });
    return disk;
}

/// Tables of source lines (lines.zig) of the image's ELF files under /symbols, Antithesis's place
/// for the symbols of instrumented code, appended to its export: how many were made.
fn symbol_lines(context: Context, tar: []const u8, listing: []const u8, disk: []const u8) !usize {
    var members: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.tokenizeScalar(u8, listing, '\n');
    while (rows.next()) |row| {
        if (row.len < 10 or row[0] != '-') continue; // Regular files.
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        for (0..5) |_| _ = fields.next();
        const member = fields.rest();
        const path = std.mem.trimStart(u8, member, "./");
        if (!std.mem.startsWith(u8, path, "symbols/")) continue;
        if (std.mem.startsWith(u8, path, source_lines.tables_directory ++ "/")) continue;
        try members.append(context.arena, member);
    }
    if (members.items.len == 0) return 0;
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, disk, "symbols");
    defer cwd.deleteTree(context.io, staging) catch {};
    const tables = try path_join(context, &.{ staging, source_lines.tables_directory });
    try cwd.createDirPath(context.io, tables);
    var extract: std.ArrayList([]const u8) = .empty;
    try extract.appendSlice(context.arena, &.{ "tar", "-xf", tar, "-C", staging });
    try extract.appendSlice(context.arena, members.items);
    _ = try tool(context, extract.items);
    var made: usize = 0;
    for (members.items) |member| {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const path = try path_join(context, &.{ staging, member });
        const gpa = std.heap.smp_allocator;
        const table = (source_lines.of(gpa, scratch.allocator(), context.io, path) catch null) orelse continue;
        try cwd.writeFile(context.io, .{
            .sub_path = try path_join(context, &.{ tables, table.name }),
            .data = table.bytes,
        });
        std.debug.print("[determinismo] source lines of /{s}: {d} bytes\n", .{
            std.mem.trimStart(u8, member, "./"), table.bytes.len,
        });
        made += 1;
    }
    if (made > 0) _ = try tool(context, &.{ "tar", "-rf", tar, "-C", staging, source_lines.tables_directory });
    return made;
}

/// The names of the program's (or Compose file's) profiles.
pub fn profile_names(arena: std.mem.Allocator, io: std.Io, options: Options) ![]const []const u8 {
    const context = Context{ .arena = arena, .io = io, .cache = options.cache_directory };
    const description = try describe(context, options);
    const names = try arena.alloc([]const u8, description.profiles.len);
    for (description.profiles, names) |profile, *name| name.* = profile.name;
    return names;
}

fn describe(context: Context, options: Options) !schema.Description {
    if (options.kubernetes) |directory| return kubernetes_describe(context, directory, options.kubernetes_images);
    if (options.compose) |path| {
        const profiles = try context.arena.alloc(schema.Profile, 1);
        profiles[0] = try compose.profile(context.arena, context.io, path);
        return .{ .profiles = profiles, .scenarios = &.{} };
    }
    const program = options.program orelse return error.NoProgram;
    var environment = try program_environment(context.arena);
    const result = std.process.run(context.arena, context.io, .{
        .argv = &.{ program, "--describe" },
        .environ_map = &environment,
    }) catch |err| {
        std.debug.print("[determinismo] cannot run {s}: {s}\n", .{ program, @errorName(err) });
        return err;
    };
    if (!result.term.success()) {
        std.debug.print("[determinismo] {s} failed:\n{s}\n", .{ program, result.stderr });
        return error.ToolFailed;
    }
    return schema.parse(schema.Description, context.arena, result.stdout);
}

/// Kubernetes manifests as a system (kubernetes.zig): one K3s node, its image built from a
/// context made here (`<cache>/kubernetes/<hash>`: K3s, the workload's images saved, the
/// manifests, the setup and exec scripts, a wrapper per test template), and a scenario per
/// template directory found in the workload's images, its first command the setup.
fn kubernetes_describe(context: Context, directory: []const u8, extra_images: ?[]const u8) !schema.Description {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    // The manifests, by path relative to the directory (sorted: the hash and the copy follow).
    var files: std.ArrayList([]const u8) = .empty;
    var contents: std.ArrayList([]const u8) = .empty;
    var images: std.ArrayList([]const u8) = .empty;
    const listed = try tool(context, &.{ "find", directory, "-type", "f", "(", "-name", "*.yaml", "-o", "-name", "*.yml", "-o", "-name", "*.json", ")" });
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |path| try files.append(arena, path);
    std.sort.insertion([]const u8, files.items, {}, string_before);
    if (files.items.len == 0) return error.NoManifests;
    for (files.items) |path| {
        const text = try cwd.readFileAlloc(context.io, path, arena, .limited(16 << 20));
        try contents.append(arena, text);
        try kubernetes.images_note(arena, text, &images);
    }
    // The launch's own (Antithesis's `images`): an operator's, named in a custom resource.
    if (extra_images) |list| try kubernetes.images_add(arena, list, &images);
    // Every image, as K3s will find it (fully qualified: nothing is pulled in the guest), with
    // its test templates' files: test templates may be in any of them.
    var executables: std.ArrayList([]const u8) = .empty;
    var owners: std.ArrayList([]const u8) = .empty; // The image of each file.
    var ids: std.ArrayList([]const u8) = .empty;
    for (images.items) |image| {
        if (!kubernetes.qualified(image)) {
            std.debug.print("[determinismo] {s}: images in Kubernetes manifests are fully qualified " ++
                "(registry, name and tag or digest), as Antithesis asks\n", .{image});
            return error.ImageNotQualified;
        }
        const id = try image_id(context, image);
        try ids.append(arena, id);
        for (try image_templates(context, image, id)) |path| {
            try executables.append(arena, path);
            try owners.append(arena, image);
        }
    }
    const hash = node_hash(directory.len, files.items, contents.items, images.items, ids.items);
    const build = try path_join(context, &.{ context.cache, "kubernetes", try std.fmt.allocPrint(arena, "{x:0>16}", .{hash}) });
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    try compose.templates(arena, kubernetes.node_name, executables.items, &scenarios);
    if (scenarios.items.len == 0) {
        std.debug.print("[determinismo] no Antithesis test template in the manifests' images " ++
            "(/opt/antithesis/test/v1/<template>/<command>)\n", .{});
        return error.NoScenarios;
    }
    // Each scenario's first command deploys the manifests and waits until they are ready.
    for (scenarios.items) |*scenario| {
        const commands = try arena.alloc(schema.Command, scenario.commands.len + 1);
        commands[0] = .{ .kind = .setup, .name = "setup_kubernetes", .path = kubernetes.ready_path };
        @memcpy(commands[1..], scenario.commands);
        scenario.commands = commands;
    }
    if (!exists(context, try path_join(context, &.{ build, "Dockerfile" }))) {
        try kubernetes_context(context, build, directory, files.items, contents.items, images.items, executables.items, owners.items);
    }
    const nodes = try arena.alloc(schema.Node, 1);
    nodes[0] = .{
        .name = kubernetes.node_name,
        .source = .{ .build = .{ .context = build } },
        .entrypoint = &kubernetes.entrypoint,
        .command = &kubernetes.command,
        .env = &.{kubernetes.kubeconfig},
        .ready = .{ .tcp = kubernetes.api_port },
        .privileged = true,
        // Antithesis's node on Kubernetes is a pod: a pause freezes "a container", a partition
        // splits pods, and only thread pausing, clock skips and CPU modulation are the
        // machine's. So the pod faults, and of this node's own (the whole cluster: its control
        // plane and every pod, the excluded ones too) those that are the machine's alone: no
        // pause, throttle, isolation, partition or degraded link of the node itself. Paused
        // whole, CloudNativePG's excluded operator lost its leader lease and exited (ParadeDB's
        // run 2095); its links reach only the runner.
        .faults = .{ .pods = true, .pause = false, .throttle = false, .isolate = false, .partition = false, .degrade = false },
    };
    const profiles = try arena.alloc(schema.Profile, 1);
    profiles[0] = .{ .name = "kubernetes", .nodes = nodes };
    return .{ .profiles = profiles, .scenarios = scenarios.items };
}

/// The K3s node's build context's name: what it is made of (the scripts and K3s, the images'
/// format, the manifests, each image's archive name and ID), so that another of any makes
/// another context.
fn node_hash(directory_len: usize, files: []const []const u8, contents: []const []const u8, images: []const []const u8, ids: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for ([_][]const u8{ kubernetes.ready_script, kubernetes.exec_script, kubernetes.start_script, kubernetes.containerd_dropin, kubernetes.k3s_image, kubernetes.images_format }) |part| {
        hasher.update(part);
    }
    for (files, contents) |path, text| {
        hasher.update(path[directory_len..]);
        hasher.update(text);
    }
    for (images, ids) |image, id| {
        hasher.update(image); // Its archive's name, as K3s imports it (kubernetes.normalized).
        hasher.update(id);
    }
    return hasher.final();
}

test node_hash {
    const files = [_][]const u8{"manifests/publisher.yaml"};
    const contents = [_][]const u8{"image: docker.io/postgres:18\n"};
    const ids = [_][]const u8{"0123456789abcdef"};
    const hash = node_hash("manifests".len, &files, &contents, &.{"docker.io/library/postgres:18"}, &ids);
    try std.testing.expectEqual(hash, node_hash("manifests".len, &files, &contents, &.{"docker.io/library/postgres:18"}, &ids));
    // One image's archive named otherwise (its manifests and ID the same: the names' rule
    // changed, kubernetes.normalized): another context, not the archive named before.
    try std.testing.expect(hash != node_hash("manifests".len, &files, &contents, &.{"docker.io/postgres:18"}, &ids));
    try std.testing.expect(hash != node_hash("manifests".len, &files, &contents, &.{"docker.io/library/postgres:18"}, &.{"fedcba9876543210"}));
}

/// The K3s node's build context (kubernetes_describe), written whole into a staging directory
/// and then moved: a context that is there is complete.
fn kubernetes_context(
    context: Context,
    build: []const u8,
    directory: []const u8,
    files: []const []const u8,
    contents: []const []const u8,
    images: []const []const u8,
    executables: []const []const u8,
    owners: []const []const u8,
) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, build, "partial");
    errdefer cwd.deleteTree(context.io, staging) catch {};
    const tools = try path_join(context, &.{ staging, "determinismo-kubernetes" });
    try cwd.createDirPath(context.io, try path_join(context, &.{ tools, "manifests" }));
    for (files, contents) |path, text| {
        const target = try path_join(context, &.{ tools, "manifests", path[directory.len..] });
        if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(context.io, parent);
        try cwd.writeFile(context.io, .{ .sub_path = target, .data = text });
    }
    try executable_write(context, try path_join(context, &.{ tools, "ready" }), kubernetes.ready_script);
    try executable_write(context, try path_join(context, &.{ tools, "exec" }), kubernetes.exec_script);
    try executable_write(context, try path_join(context, &.{ tools, "start" }), kubernetes.start_script);
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ tools, "determinismo.toml" }), .data = kubernetes.containerd_dropin });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (executables, owners) |line, image| {
        const file = compose.template_file(line) orelse continue;
        if (file.state != .runs) continue; // Reported by the composer (compose.templates).
        const path = file.path;
        if ((try seen.getOrPut(arena, path)).found_existing) continue; // The first image's.
        const target = try path_join(context, &.{ staging, "antithesis", path["opt/antithesis/".len..] });
        if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(context.io, parent);
        try executable_write(context, target, try kubernetes.wrapper(arena, image, try std.fmt.allocPrint(arena, "/{s}", .{path})));
    }
    if (images.len > 0) {
        // Each image an OCI archive of zstd layers, named by its reference (a digest's too).
        // K3s imports each as it is and containerd unpacks a layer when a container first needs
        // it, so the node holds both in memory (containerd's root is a tmpfs): uncompressed
        // layers (a docker-archive's) doubled the images' size there, ParadeDB's 9 GB to 18 GB
        // of a 32 GiB guest.
        std.debug.print("[determinismo] saving the manifests' {d} images for K3s (zstd layers)\n", .{images.len});
        const folder = try path_join(context, &.{ staging, "images" });
        try cwd.createDirPath(context.io, folder);
        for (images, 0..) |image, index| {
            const archive = try path_join(context, &.{ folder, try std.fmt.allocPrint(arena, "{d}.tar", .{index}) });
            const target = try std.fmt.allocPrint(arena, "oci-archive:{s}:{s}", .{ archive, image });
            _ = try tool(context, &.{ "podman", "push", "--quiet", "--compression-format", "zstd", "--force-compression", image, target });
        }
    }
    const text = try kubernetes.dockerfile(arena, images.len > 0, seen.count() > 0);
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ staging, "Dockerfile" }), .data = text });
    cwd.rename(staging, cwd, build, context.io) catch |err| switch (err) {
        error.DirNotEmpty => if (exists(context, try path_join(context, &.{ build, "Dockerfile" }))) {
            cwd.deleteTree(context.io, staging) catch {}; // Another process made it meanwhile.
        } else {
            cwd.deleteTree(context.io, build) catch {}; // Left unfinished, from before.
            try cwd.rename(staging, cwd, build, context.io);
        },
        else => return err,
    };
}

fn executable_write(context: Context, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(context.io, .{ .sub_path = path, .data = data });
    const path_z = try context.arena.dupeSentinel(u8, path, 0);
    if (std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, path_z, 0o755)) != .SUCCESS) return error.Chmod;
}

fn string_before(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// An image's ID, pulled first when it is not on the host.
fn image_id(context: Context, reference: []const u8) ![]const u8 {
    if (!try tool_succeeds(context, &.{ "podman", "image", "exists", reference })) {
        std.debug.print("[determinismo] pulling {s}\n", .{reference});
        _ = try tool(context, &.{ "podman", "pull", "--quiet", reference });
    }
    const inspect_json = try tool(context, &.{ "podman", "image", "inspect", reference });
    const inspect = try schema.parse([]const ImageInspect, context.arena, inspect_json);
    if (inspect.len != 1) return error.ImageInspect;
    return inspect[0].Id;
}

/// An image's test templates' files, listed once (`<cache>/images/<id>.erofs.templates`, beside
/// the disk image_disk makes of it, when it makes one).
fn image_templates(context: Context, reference: []const u8, id: []const u8) ![]const []const u8 {
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(context.arena, "{s}.erofs", .{id}) });
    const templates = try std.fmt.allocPrint(context.arena, "{s}.templates", .{disk});
    if (!exists(context, templates)) {
        const container = std.mem.trim(u8, try tool(context, &.{ "podman", "create", "--quiet", reference }), " \n");
        defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
        const tar = try std.fmt.allocPrint(context.arena, "{s}.listing.tar", .{disk});
        _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
        defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
        const listing = try tool(context, &.{ "tar", "-tvf", tar });
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = templates, .data = try templates_of(context, tar, listing, disk) });
    }
    return templates_listing(context, disk);
}

/// The image's test templates' files, recorded next to its disk when it was flattened.
fn templates_listing(context: Context, disk: []const u8) ![]const []const u8 {
    const path = try std.fmt.allocPrint(context.arena, "{s}.templates", .{disk});
    const limit: std.Io.Limit = .limited(1 << 22);
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, limit) catch
        return &.{}; // Not an image (a directory or a binary): no templates.
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| try list.append(context.arena, line);
    return list.items;
}

/// From an image's export and its `tar -tv` output: the files directly in its test templates,
/// one a line as compose.template_file reads them (`x`: one that runs, an executable ELF
/// binary or script with a shebang, or a link; `n` not executable; `s` executable but neither).
fn templates_of(context: Context, tar: []const u8, listing: []const u8, disk: []const u8) ![]const u8 {
    const arena = context.arena;
    const Member = struct { name: []const u8, path: []const u8, state: compose.TemplateFile.State };
    var members: std.ArrayList(Member) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        // "-rwxr-xr-x owner/group size date time path": the path is the sixth field on (a
        // link's followed by " -> " and its target).
        if (line.len < 10 or (line[0] != '-' and line[0] != 'l')) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..5) |_| _ = fields.next();
        var name = fields.rest();
        if (line[0] == 'l') name = name[0 .. std.mem.indexOf(u8, name, " -> ") orelse name.len];
        const path = std.mem.trimStart(u8, name, "./");
        if (!compose.template_member(path)) continue;
        const state: compose.TemplateFile.State = if (line[0] == 'l') .runs else if (line[3] == 'x') .no_interpreter else .not_executable;
        try members.append(arena, .{ .name = name, .path = path, .state = state });
    }
    // The executables' first bytes, from one pass over the export.
    var argv: std.ArrayList([]const u8) = .empty;
    const scratch = try own_path(context, disk, "templates");
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(context.io, scratch);
    defer cwd.deleteTree(context.io, scratch) catch {};
    try argv.appendSlice(arena, &.{ "tar", "-xf", tar, "-C", scratch });
    for (members.items) |member| {
        if (member.state == .no_interpreter) try argv.append(arena, member.name);
    }
    if (argv.items.len > 5) _ = try tool(context, argv.items);
    var out: std.ArrayList(u8) = .empty;
    for (members.items) |*member| {
        if (member.state == .no_interpreter) {
            var head: [4]u8 = undefined;
            const file = try cwd.openFile(context.io, try path_join(context, &.{ scratch, member.path }), .{});
            defer file.close(context.io);
            const size = try file.readPositionalAll(context.io, &head, 0);
            if (std.mem.startsWith(u8, head[0..size], "#!") or std.mem.startsWith(u8, head[0..size], "\x7fELF")) {
                member.state = .runs;
            }
        }
        try out.print(arena, "{c} {s}\n", .{ @backingInt(member.state), member.path });
    }
    return out.items;
}

/// Keeps the resolved system of each program and profile, and reports what changed since the
/// last run of the same pair: snapshots and tapes from before do not apply to the new one.
fn profile_remember(
    context: Context,
    program: []const u8,
    system: *const schema.System,
    system_json: []const u8,
) !void {
    // By its path, not its name alone: every Compose project's file is compose.yaml or
    // docker-compose.yaml, and each run of one was "changed since the last run" of another.
    const absolute = std.fs.path.resolve(context.arena, &.{program}) catch program;
    const name = try std.fmt.allocPrint(context.arena, "{s}-{x:0>16}--{s}.json", .{
        std.fs.path.basename(program), std.hash.Wyhash.hash(0, absolute), system.profile,
    });
    const path = try path_join(context, &.{ context.cache, "profiles", name });
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 20))) |previous_json| {
        if (!std.mem.eql(u8, previous_json, system_json)) {
            // Remembered by an older determinismo, in a format of its own: nothing to compare.
            const previous = schema.parse(schema.System, context.arena, previous_json) catch {
                std.debug.print("[determinismo] profile {s}: the last run's, from another " ++
                    "version, is replaced\n", .{system.profile});
                return cwd.writeFile(context.io, .{ .sub_path = path, .data = system_json });
            };
            std.debug.print("[determinismo] profile {s} changed since the last run:\n", .{
                system.profile,
            });
            differences = 0;
            try profile_diff(context.arena, &previous, system);
            if (differences == 0) std.debug.print("  (in its encoding only)\n", .{});
        }
    } else |_| {}
    try cwd.writeFile(context.io, .{ .sub_path = path, .data = system_json });
}

fn profile_diff(
    arena: std.mem.Allocator,
    old: *const schema.System,
    new: *const schema.System,
) !void {
    for (old.nodes) |node| {
        if (new.node(node.name) == null) {
            differences += 1;
            std.debug.print("  - node {s}\n", .{node.name});
        }
    }
    for (new.nodes) |node| {
        const before = old.node(node.name) orelse {
            differences += 1;
            std.debug.print("  + node {s}\n", .{node.name});
            continue;
        };
        try changed(arena, node.name, "digest", before.digest, node.digest);
        try changed(arena, node.name, "address", before.address, node.address);
        try changed(arena, node.name, "disk", before.disk, node.disk);
        try changed(arena, node.name, "command", before.command, node.command);
        try changed(arena, node.name, "env", before.env, node.env);
        try changed(arena, node.name, "workdir", before.workdir, node.workdir);
        try changed(arena, node.name, "user", before.user, node.user);
        try changed(arena, node.name, "ready", before.ready, node.ready);
        try changed(arena, node.name, "after", before.after, node.after);
        try changed(arena, node.name, "faults", before.faults, node.faults);
    }
    for (old.scenarios) |scenario| {
        if (new.scenario(scenario.name) == null) {
            differences += 1;
            std.debug.print("  - scenario {s}\n", .{scenario.name});
        }
    }
    for (new.scenarios) |scenario| {
        const before = old.scenario(scenario.name) orelse {
            differences += 1;
            std.debug.print("  + scenario {s}\n", .{scenario.name});
            continue;
        };
        try changed(arena, "scenario", scenario.name, before.*, scenario);
    }
}

var differences: u32 = 0;

/// Prints `owner.field: old -> new` when the two differ (compared as JSON).
fn changed(
    arena: std.mem.Allocator,
    owner: []const u8,
    field: []const u8,
    old: anytype,
    new: @TypeOf(old),
) !void {
    const old_json = try json(arena, old);
    const new_json = try json(arena, new);
    if (std.mem.eql(u8, old_json, new_json)) return;
    differences += 1;
    std.debug.print("  ~ {s}.{s}: {s} -> {s}\n", .{ owner, field, old_json, new_json });
}

fn json(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.written();
}

/// A node's coverage set replaced by `coverage` (Options.coverage), in its environment and its
/// build's arguments.
fn coverage_adjust(arena: std.mem.Allocator, node: *schema.Node, coverage: ?[]const u8) !void {
    const given = coverage orelse return;
    // "off": an include no name starts with (a class, a package, a file all start otherwise).
    const set = if (std.mem.eql(u8, given, "off")) "!" else given;
    const entry = try std.fmt.allocPrint(arena, "DETERMINISMO_COVERAGE={s}", .{set});
    node.env = try entries_replaced(arena, node.env, entry);
    if (node.source.build) |build| {
        var adjusted = build;
        adjusted.args = try entries_replaced(arena, build.args, entry);
        node.source.build = adjusted;
    }
}

/// `NAME=value` entries with `entry`'s name replaced by it (or it added).
fn entries_replaced(arena: std.mem.Allocator, entries: []const []const u8, entry: []const u8) ![]const []const u8 {
    const name = entry[0 .. std.mem.indexOfScalar(u8, entry, '=').? + 1];
    var result: std.ArrayList([]const u8) = .empty;
    for (entries) |each| if (!std.mem.startsWith(u8, each, name)) try result.append(arena, each);
    try result.append(arena, entry);
    return result.items;
}

test entries_replaced {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const replaced = try entries_replaced(state.allocator(), &.{ "A=1", "DETERMINISMO_COVERAGE=x" }, "DETERMINISMO_COVERAGE=!");
    try std.testing.expectEqual(@as(usize, 2), replaced.len);
    try std.testing.expectEqualStrings("A=1", replaced[0]);
    try std.testing.expectEqualStrings("DETERMINISMO_COVERAGE=!", replaced[1]);
}

/// Builds the image (podman reuses its layer cache) and returns its ID.
/// Fault kinds added to every node (by field name: restart, crash, wipe, process_kill, ...), or
/// with a "-" taken from every node (-interleave: a run without it, to compare), then none at
/// all for the nodes named in `faults_none`.
fn faults_adjust(faults: *schema.Faults, name: []const u8, options: Options) !void {
    if (options.faults_added) |list| try schema.faults_change(faults, list);
    if (options.faults_none) |list| {
        var names = std.mem.tokenizeScalar(u8, list, ',');
        while (names.next()) |none| {
            if (std.mem.eql(u8, none, name)) schema.faults_none(faults);
        }
    }
}

/// The build of a node, or for a mutant's node the same build from a patched copy of its
/// context (in the cache, by the patch's content: built once).
fn mutant_build(context: Context, node: *const schema.Node, build: schema.Build) !schema.Build {
    const mutant = context.mutant orelse return build;
    const equals = std.mem.indexOfScalar(u8, mutant, '=') orelse return error.BadMutant;
    if (!std.mem.eql(u8, mutant[0..equals], node.name)) return build;
    const patch_path = mutant[equals + 1 ..];
    const cwd = std.Io.Dir.cwd();
    const patch = try cwd.readFileAlloc(context.io, patch_path, context.arena, .limited(1 << 24));
    var hasher = std.hash.Wyhash.init(0x6d7574616e74);
    hasher.update(build.context);
    hasher.update(patch);
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}", .{hasher.final()});
    const copy = try path_join(context, &.{ context.cache, "mutants", name });
    if (!exists(context, copy)) {
        const staging = try std.fmt.allocPrint(context.arena, "{s}.staging", .{copy});
        _ = tool(context, &.{ "rm", "-rf", staging }) catch {};
        const source = try std.fmt.allocPrint(context.arena, "{s}/", .{build.context});
        _ = try tool(context, &.{
            "rsync",   "-a",        "--exclude",  ".git",      "--exclude",
            "zig-out", "--exclude", ".zig-cache", "--exclude", ".determinismo-cache",
            source,    staging,
        });
        const absolute = try cwd.realPathFileAlloc(context.io, patch_path, context.arena);
        _ = try tool(context, &.{ "git", "-C", staging, "apply", "--unsafe-paths", absolute });
        _ = try tool(context, &.{ "mv", staging, copy });
    }
    std.debug.print("[determinismo] mutant: {s} built with {s}\n", .{ node.name, patch_path });
    return .{ .context = copy, .dockerfile = build.dockerfile, .args = build.args };
}

/// The SDK this explorer carries (tools/sdk_pack.zig: the repository's sdk/ as it was built):
/// node images built from a Dockerfile take it as the build context `determinismo-sdk`
/// (`COPY --from=determinismo-sdk go /sdk`), so an image gets the SDK of the platform that builds
/// it, wherever its Dockerfile lives (the examples' own repository: docs/PLAN.md, the split).
const sdk_tar = @embedFile("sdk_tar");

/// The carried SDK as a directory: extracted once into the cache, named by its content.
fn sdk_context(context: Context) ![]const u8 {
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}", .{std.hash.Wyhash.hash(0, sdk_tar)});
    const directory = try path_join(context, &.{ context.cache, "sdk", name });
    if (exists(context, directory)) return directory;
    const cwd = std.Io.Dir.cwd();
    // Beside it, then renamed: a builder beside this one never sees half of it.
    const staging = try std.fmt.allocPrint(context.arena, "{s}.staging-{d}", .{ directory, std.os.linux.getpid() });
    try cwd.createDirPath(context.io, staging);
    {
        var dir = try cwd.openDir(context.io, staging, .{});
        defer dir.close(context.io);
        var reader: std.Io.Reader = .fixed(sdk_tar);
        try std.tar.extract(context.io, dir, &reader, .{});
    }
    cwd.rename(staging, cwd, directory, context.io) catch |err| {
        // Another builder renamed its own first: the same content.
        cwd.deleteTree(context.io, staging) catch {};
        if (!exists(context, directory)) return err;
    };
    return directory;
}

/// The image's label naming the script that makes its JVM caches (an AOT cache, a CDS archive),
/// docs/CI.md: prepare runs it again with java.instrument among the modules, as every JVM of
/// the node starts with our coverage agent, so that its caches load (aws-hunt run 18: refused at
/// 1,255 of 1,441 starts, a restarted server serving a median 75 virtual s later).
const jvm_caches_label_name = "determinismo.jvm-caches";

/// The label's value as `podman image inspect --format` prints it, or none (absent: empty, or
/// Go's "<no value>").
fn jvm_caches_label(printed: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, printed, " \t\r\n");
    if (value.len == 0 or std.mem.eql(u8, value, "<no value>")) return null;
    return value;
}

/// The derived image's Dockerfile: the node's image, its caches made again by its script with
/// the module the agent adds at every start (JDK_JAVA_OPTIONS reaches every `java`, not the
/// image's own runtime: set for that one RUN alone). The agent's hash in it keys podman's cache:
/// a new agent trains again.
fn jvm_caches_dockerfile(arena: std.mem.Allocator, base: []const u8, script: []const u8, jars: []const u8, agent: []const u8) ![]const u8 {
    // Then every file at time 0, as the guest's erofs gives them (the cache records the time
    // and size of each classpath jar, the JDK's too), and the training.
    // `<class prefixes, comma-separated> <jar or glob>...`: what the cache's classes are
    // instrumented from, ahead (a cache's classes pass the agent by: Datalevin's lines fell from
    // 22,084 to 9,102 trained alone, 97% kept with its jars instrumented first).
    var words = std.mem.tokenizeAny(u8, jars, " \t");
    const prefixes = words.next() orelse return error.JvmJarsLabel;
    const globs = std.mem.trim(u8, words.rest(), " \t");
    if (globs.len == 0) return error.JvmJarsLabel;
    return std.fmt.allocPrint(arena,
        \\FROM {[base]s}
        \\COPY determinismo-coverage.jar /opt/determinismo/instrument.jar
        \\RUN DETERMINISMO_AGENT={[agent]s} sh -ec 'set --; for jar in {[globs]s}; do set -- "$@" "$jar" "$jar.det"; done; java -cp /opt/determinismo/instrument.jar DeterminismoCoverage instrument {[prefixes]s} "$@"; for jar in {[globs]s}; do mv "$jar.det" "$jar"; done'
        \\RUN find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o -exec touch -h -d @0 {{}} +
        \\RUN DETERMINISMO_AGENT={[agent]s} JDK_JAVA_OPTIONS=--add-modules=java.instrument {[script]s}
        \\
    , .{ .base = base, .agent = agent, .globs = globs, .prefixes = prefixes, .script = script });
}

/// The image's label naming what its caches' classes are instrumented from ahead (`<class
/// prefixes> <jars>...`), jvm_caches_dockerfile: without it its caches are not made again,
/// their classes would pass the coverage agent by.
const jvm_jars_label_name = "determinismo.jvm-jars";

/// The node's image with its JVM caches made again (jvm_caches_label), or the image as it was:
/// no label, or its script failed (said; its own caches stay, refused at each start as the
/// run's jvm-cache note says). podman's build cache keys it: the image, the script, the agent.
fn jvm_caches(context: Context, node: *const schema.Node, reference: []const u8) ![]const u8 {
    const script = jvm_caches_label(image_label(context, reference, jvm_caches_label_name)) orelse return reference;
    const jars = jvm_caches_label(image_label(context, reference, jvm_jars_label_name)) orelse {
        std.debug.print("[determinismo] {s}: its JVM caches not made again: no {s} label (its caches' " ++
            "classes would pass the coverage agent by, uncovered), docs/CI.md\n", .{ node.name, jvm_jars_label_name });
        return reference;
    };
    const agent = agent_jar(context) orelse {
        std.debug.print("[determinismo] {s}: its JVM caches not made again: no coverage agent beside " ++
            "this explorer\n", .{node.name});
        return reference;
    };
    const base = try image_id(context, reference);
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", node.name }), "jvm-caches");
    defer cwd.deleteTree(context.io, staging) catch {};
    try cwd.createDirPath(context.io, staging);
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ staging, "determinismo-coverage.jar" }), .data = agent });
    const hash = try std.fmt.allocPrint(context.arena, "{x:0>16}", .{std.hash.Wyhash.hash(0, agent)});
    const dockerfile = jvm_caches_dockerfile(context.arena, base, script, jars, hash) catch |err| {
        std.debug.print("[determinismo] {s}: its JVM caches not made again: its {s} label is " ++
            "`<class prefixes> <jars>...` ({s})\n", .{ node.name, jvm_jars_label_name, @errorName(err) });
        return reference;
    };
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ staging, "Dockerfile" }), .data = dockerfile });
    const trained = image_build(context, .{ .context = staging }) catch |err| {
        std.debug.print("[determinismo] {s}: its JVM caches not made again ({s} failed: {s}): its image's own " ++
            "caches stay, refused beside the coverage agent\n", .{ node.name, script, @errorName(err) });
        return reference;
    };
    std.debug.print("[determinismo] {s}: its JVM caches made again with the coverage agent's module ({s})\n", .{ node.name, script });
    return trained;
}

/// The coverage agent's jar (beside this executable, as the guest's initramfs takes it), or none.
fn agent_jar(context: Context) ?[]const u8 {
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = std.os.linux.readlink("/proc/self/exe", &exe_buffer, exe_buffer.len);
    if (std.os.linux.errno(size) != .SUCCESS) return null;
    const directory = std.fs.path.dirname(exe_buffer[0..size]) orelse return null;
    const jar = path_join(context, &.{ directory, "determinismo-coverage.jar" }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(context.io, jar, context.arena, .limited(64 << 20)) catch null;
}

/// An image's label as `podman image inspect --format` prints it ("" when podman fails).
fn image_label(context: Context, reference: []const u8, name: []const u8) []const u8 {
    const format = std.fmt.allocPrint(context.arena, "{{{{index .Config.Labels \"{s}\"}}}}", .{name}) catch return "";
    return tool(context, &.{ "podman", "image", "inspect", "--format", format, reference }) catch "";
}

test "an image's JVM caches are made again with the agent's module, keyed by the agent" {
    try std.testing.expectEqual(@as(?[]const u8, null), jvm_caches_label("<no value>\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), jvm_caches_label("\n"));
    try std.testing.expectEqualStrings("/opt/train.sh", jvm_caches_label("/opt/train.sh\n").?);
    const dockerfile = try jvm_caches_dockerfile(std.testing.allocator, "sha256:abc", "/opt/train.sh", "datalevin,com.alipay.sofa.jraft /opt/app/*.jar /opt/jraft.jar", "0123abcd");
    defer std.testing.allocator.free(dockerfile);
    try std.testing.expectEqualStrings(
        \\FROM sha256:abc
        \\COPY determinismo-coverage.jar /opt/determinismo/instrument.jar
        \\RUN DETERMINISMO_AGENT=0123abcd sh -ec 'set --; for jar in /opt/app/*.jar /opt/jraft.jar; do set -- "$@" "$jar" "$jar.det"; done; java -cp /opt/determinismo/instrument.jar DeterminismoCoverage instrument datalevin,com.alipay.sofa.jraft "$@"; for jar in /opt/app/*.jar /opt/jraft.jar; do mv "$jar.det" "$jar"; done'
        \\RUN find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o -exec touch -h -d @0 {} +
        \\RUN DETERMINISMO_AGENT=0123abcd JDK_JAVA_OPTIONS=--add-modules=java.instrument /opt/train.sh
        \\
    , dockerfile);
    // Every file at time 0 before the training, as the guest's erofs gives them: the cache
    // records each classpath jar's time and size, the JDK's too.
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "-prune -o -exec touch -h -d @0 {} +\nRUN DETERMINISMO_AGENT") != null);
    // The build's own mounts left alone: touching /proc failed the RUN (srv4, 2026-11-23).
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "-path /proc -o -path /sys -o -path /dev -o -path /run") != null);
    // The agent is in instructions (podman's cache keys instructions, never comments).
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "RUN DETERMINISMO_AGENT=0123abcd JDK_JAVA_OPTIONS") != null);
    // Jars without class prefixes, or none at all: no recipe.
    try std.testing.expectError(error.JvmJarsLabel, jvm_caches_dockerfile(std.testing.allocator, "b", "/t.sh", "datalevin", "a"));
}

fn image_build(context: Context, build: schema.Build) ![]const u8 {
    const dockerfile = try path_join(context, &.{ build.context, build.dockerfile });
    std.debug.print("[determinismo] building {s}\n", .{dockerfile});
    var command: std.ArrayList([]const u8) = .empty;
    try command.appendSlice(context.arena, &.{ "podman", "build", "--quiet", "--file", dockerfile });
    const sdk = try std.fmt.allocPrint(context.arena, "determinismo-sdk={s}", .{try sdk_context(context)});
    try command.appendSlice(context.arena, &.{ "--build-context", sdk });
    for (build.args) |argument| try command.appendSlice(context.arena, &.{ "--build-arg", argument });
    try command.append(context.arena, build.context);
    const output = try tool(context, command.items);
    const id = std.mem.trim(u8, output, " \n");
    if (id.len == 0) return error.ImageBuild;
    return id[if (std.mem.lastIndexOfScalar(u8, id, '\n')) |index| index + 1 else 0..];
}

fn directory_disk(
    context: Context,
    name: []const u8,
    directory: []const u8,
    digest: *[]const u8,
) ![]const u8 {
    digest.* = try std.fmt.allocPrint(context.arena, "directory:{s}", .{directory});
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "directory-{s}.erofs",
        .{name},
    ) });
    try erofs_build(context, disk, &.{ "--ignore-mtime", directory });
    return disk;
}

fn binary_disk(
    context: Context,
    name: []const u8,
    binary: []const u8,
    config: *ImageConfig,
    digest: *[]const u8,
) ![]const u8 {
    const io = context.io;
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", name }), "binary");
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, staging) catch {};
    for ([_][]const u8{ "bin", "etc", "tmp", "proc", "sys", "dev" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ staging, directory }));
    }
    const basename = std.fs.path.basename(binary);
    const target = try path_join(context, &.{ staging, "bin", basename });
    try cwd.copyFile(binary, cwd, target, io, .{});
    const content = try cwd.readFileAlloc(io, binary, context.arena, .unlimited);
    const content_hash = std.hash.Wyhash.hash(0, content);
    // With its source lines' table (below): a disk without one is another disk.
    digest.* = try std.fmt.allocPrint(context.arena, "binary:{x}:lines-{d}", .{ content_hash, source_lines.format_version });
    config.Entrypoint = try context.arena.dupe([]const u8, &.{try std.fmt.allocPrint(
        context.arena,
        "/bin/{s}",
        .{basename},
    )});
    // By content: by name alone, another build of the binary replaced the disk under runs
    // still to replay from it (and two at once raced on it).
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "binary-{s}-{x:0>16}-lines-{d}.erofs",
        .{ name, content_hash, source_lines.format_version },
    ) });
    if (exists(context, disk)) return disk;
    // Its source lines (lines.zig) where coverage looks for them, as an image's /symbols gets
    // (symbol_lines): a binary built for coverage with its debug information reports each edge
    // as the line it is on ("line <file>:<n>"), not a number; one without says numbers as before.
    {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        if (source_lines.of(std.heap.smp_allocator, scratch.allocator(), io, binary) catch null) |table| {
            const tables = try path_join(context, &.{ staging, source_lines.tables_directory });
            try cwd.createDirPath(io, tables);
            try cwd.writeFile(io, .{ .sub_path = try path_join(context, &.{ tables, table.name }), .data = table.bytes });
            std.debug.print("[determinismo] source lines of {s}: {d} bytes\n", .{ binary, table.bytes.len });
        }
    }
    try erofs_build(context, disk, &.{ "--all-root", "--ignore-mtime", staging });
    return disk;
}

/// Disk 0: the program and the resolved system, cached by their hash.
const SystemFiles = struct {
    system_json: []const u8,
    program: ?[]const u8,
    program_lines: ?ProgramLines = null,
    script: ?[]const u8,
    injectors: []const []const u8 = &.{},
    hash: u64,
};

fn system_disk(context: Context, files: SystemFiles) ![]const u8 {
    const system_json = files.system_json;
    const program = files.program;
    const hash = files.hash;
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}.erofs", .{hash});
    const disk = try path_join(context, &.{ context.cache, "systems", name });
    if (exists(context, disk)) return disk;
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", "system" }), "system");
    defer cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    if (program) |path| {
        try cwd.copyFile(path, cwd, try path_join(context, &.{ staging, "program" }), io, .{});
    }
    if (files.program_lines) |lines| {
        // Its table of lines where the guest's /symbols leads (init.zig: a link to this disk's
        // symbols), under the name the SDK asks for there: the file is "program" in the guest.
        const tables = try path_join(context, &.{ staging, source_lines.tables_directory });
        try cwd.createDirPath(io, tables);
        const key = if (std.mem.startsWith(u8, lines.name, "name-")) "name-program" else lines.name;
        try cwd.copyFile(try path_join(context, &.{ lines.directory, lines.name }), cwd, try path_join(context, &.{ tables, key }), io, .{});
    }
    try cwd.writeFile(io, .{
        .sub_path = try path_join(context, &.{ staging, "system.json" }),
        .data = system_json,
    });
    if (files.script) |text| {
        try cwd.writeFile(io, .{
            .sub_path = try path_join(context, &.{ staging, "script.json" }),
            .data = text,
        });
    }
    if (files.injectors.len > 0) {
        const directory = try path_join(context, &.{ staging, "injectors" });
        try cwd.createDirPath(io, directory);
        for (files.injectors) |path| {
            const target = try path_join(context, &.{ directory, std.fs.path.basename(path) });
            try cwd.copyFile(path, cwd, target, io, .{});
            const target_z = try context.arena.dupeSentinel(u8, target, 0);
            if (std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, target_z, 0o755)) != .SUCCESS) return error.ChmodFailed;
        }
    }
    try erofs_build(context, disk, &.{ "--all-root", "--ignore-mtime", staging });
    return disk;
}

/// Builds `disk` atomically (via a temporary name), reproducibly (fixed time and UUID): disks are
/// read by the guest, so their exact bytes are part of every timeline.
/// A path of this process's own beside `path` (`<path>.<what>-<pid>`): explores preparing the
/// same system at once (a hunt and a check, six replays of one script) shared the staging names,
/// and one renamed or deleted another's half-made files: 5 of 6 failed (srv3, 2026-10-28), and
/// a disk could have been made of another's partial file. Each makes its own, and renames it in
/// whole (the same content, by the same hash: whichever lands last).
fn own_path(context: Context, path: []const u8, what: []const u8) ![]const u8 {
    return std.fmt.allocPrint(context.arena, "{s}.{s}-{d}", .{ path, what, std.os.linux.getpid() });
}

fn erofs_build(context: Context, disk: []const u8, source: []const []const u8) !void {
    const temporary = try own_path(context, disk, "partial");
    errdefer std.Io.Dir.cwd().deleteFile(context.io, temporary) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    const fixed = [_][]const u8{ "mkfs.erofs", "--quiet", "-T0", "-U" ++ filesystem_uuid };
    try argv.appendSlice(context.arena, &fixed);
    try argv.appendSlice(context.arena, source[0 .. source.len - 1]);
    try argv.append(context.arena, temporary);
    try argv.append(context.arena, source[source.len - 1]);
    _ = try tool(context, argv.items);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(temporary, cwd, disk, context.io);
}

/// Like `docker run`: the entrypoint (ours, else the image's), then the command (ours, else
/// the image's, unless we replaced the entrypoint, which drops the image's command too).
fn command_merge(
    arena: std.mem.Allocator,
    image: *const ImageConfig,
    entrypoint: ?[]const []const u8,
    command: ?[]const []const u8,
) ![]const []const u8 {
    const entry = entrypoint orelse image.Entrypoint orelse &.{};
    const image_command = if (entrypoint != null) null else image.Cmd;
    const arguments = command orelse image_command orelse &.{};
    return std.mem.concat(arena, []const u8, &.{ entry, arguments });
}

/// The image's environment with ours on top (same name: ours wins), PATH always present.
fn environment_merge(
    arena: std.mem.Allocator,
    image: []const []const u8,
    ours: []const []const u8,
) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ image, ours }) |layer| {
        for (layer) |entry| {
            const name = entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
            for (merged.items) |*existing| {
                if (std.mem.startsWith(u8, existing.*, name) and existing.*.len > name.len and
                    existing.*[name.len] == '=')
                {
                    existing.* = entry;
                    break;
                }
            } else try merged.append(arena, entry);
        }
    }
    for (merged.items) |entry| {
        if (std.mem.startsWith(u8, entry, "PATH=")) return merged.items;
    }
    try merged.append(arena, "PATH=" ++ path_default);
    return merged.items;
}

/// Runs a host tool and returns its standard output; reports its standard error on failure.
/// What a test program runs with on the host (its --describe): this process's environment, and
/// the SDK of a program in another language, libdeterminismo, the build's (checks.zig).
pub fn program_environment(arena: std.mem.Allocator) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(arena);
    var entries: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    while (entries[0]) |entry| : (entries += 1) {
        const text = std.mem.span(entry);
        const at = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        try environment.put(text[0..at], text[at + 1 ..]);
    }
    var library_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const library = try checks.library_variable(&library_buffer);
    const equals = std.mem.indexOfScalar(u8, library, '=').?;
    try environment.put(library[0..equals], library[equals + 1 ..]);
    return environment;
}

fn tool(context: Context, argv: []const []const u8) ![]u8 {
    assert(argv.len > 0);
    const result = std.process.run(context.arena, context.io, .{ .argv = argv }) catch |err| {
        std.debug.print("[determinismo] cannot run {s}: {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };
    if (!result.term.success()) {
        std.debug.print("[determinismo] {s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.ToolFailed;
    }
    return result.stdout;
}

fn tool_succeeds(context: Context, argv: []const []const u8) !bool {
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv });
    return result.term.success();
}

fn exists(context: Context, path: []const u8) bool {
    std.Io.Dir.cwd().access(context.io, path, .{}) catch return false;
    return true;
}

fn path_join(context: Context, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(context.arena, parts);
}

test environment_merge {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const merged = try environment_merge(arena.allocator(), &.{ "A=1", "PATHX=2" }, &.{"A=3"});
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("A=3", merged[0]);
    try std.testing.expect(std.mem.startsWith(u8, merged[2], "PATH="));
}

test command_merge {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const image = ImageConfig{ .Entrypoint = &.{"entry.sh"}, .Cmd = &.{"serve"} };
    const ours = try command_merge(arena.allocator(), &image, null, &.{ "redis-server", "--x" });
    try std.testing.expectEqual(@as(usize, 3), ours.len);
    const theirs = try command_merge(arena.allocator(), &image, null, null);
    try std.testing.expectEqualStrings("serve", theirs[1]);
    const replaced = try command_merge(arena.allocator(), &image, &.{"sh"}, null);
    try std.testing.expectEqual(@as(usize, 1), replaced.len);
}
