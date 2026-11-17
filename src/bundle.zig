// SPDX-License-Identifier: MIT
//! `determinismo bundle <run directory> <timeline> <out>`: one timeline of a run with everything
//! it replays on, in a directory of its own: the run's request, machine and pinned system, the
//! timeline's tape and those of the timelines it began inside (a tree's ancestors, a fork's
//! origin), and every input the tapes were recorded on (the guest kernel, the initramfs, the
//! test program, each node's image), their paths made relative to the bundle. A tape replays
//! only on its own inputs, and an image rebuilt from its Dockerfile is other bytes (packages and
//! downloads move): the bundle is how someone else replays a finding's timeline exactly, on a
//! host with determinismo at the run's build and its KVM module:
//!
//!   cd <out> && determinismo explore --run . --branch <timeline>
//!
//! Its README.txt says that and what the run was; SHA256SUMS lists every file.
//!
//! With `--store <dir>`, a content-addressed store: the bundle's inputs (kernel, initramfs,
//! program, explorer, node images: gigabytes) go to `<dir>/sha256/<hex>` once, shared by every
//! bundle and run that has them, and STORED lists each (its path in the bundle, digest, size):
//! the bundle itself is kilobytes. A store syncs to S3 as is (infra/host/bundle-s3.sh: only new
//! blobs move), and `determinismo bundle fetch <bundle> <store>` puts the inputs back where the
//! bundle names them, each checked against its digest: then it replays as above (on a machine
//! made for it: infra/aws/inspect.sh).
const std = @import("std");
const assert = std.debug.assert;
const cpuid = @import("core").cpuid;
const kvm = @import("core").kvm;
const VM = @import("core").vm;

/// The guest's CPUID table in a bundle (cpuid.table_write's text).
const cpuid_name = "cpuid.txt";

/// A timeline begins inside at most this many others (tape.zig's chain, a fork's origin).
const tapes_max = 128;
const json_max = 64 << 20;

/// What is being written: the bundle's directory, its files, and with a store, the inputs it put
/// there instead.
const Bundle = struct {
    out: []const u8,
    files: std.ArrayList([]const u8) = .empty,
    store: ?[]const u8 = null,
    stored: std.ArrayList(Stored) = .empty,
};

/// A file of the bundle kept in the store: STORED's line, `<hex>  <size>  <path>`.
const Stored = struct { path: []const u8, sha256: [64]u8, size: u64 };

fn has(bundle: *const Bundle, name: []const u8) bool {
    for (bundle.files.items) |file| if (std.mem.eql(u8, file, name)) return true;
    for (bundle.stored.items) |entry| if (std.mem.eql(u8, entry.path, name)) return true;
    return false;
}

pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    if (arguments.len >= 1 and std.mem.eql(u8, arguments[0], "fetch")) return fetch(arena, io, arguments[1..]);
    const store: ?[]const u8 = if (arguments.len == 5 and std.mem.eql(u8, arguments[3], "--store")) arguments[4] else null;
    if (arguments.len != 3 and store == null) return error.Usage;
    const run_directory: []const u8 = arguments[0];
    const timeline = try std.fmt.parseInt(u32, arguments[1], 10);
    const out: []const u8 = arguments[2];
    const cwd = std.Io.Dir.cwd();
    var bundle: Bundle = .{ .out = out, .store = store };
    if (store) |directory| try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ directory, "sha256" }));
    // A bundle is new: never merged into an older one's files.
    if (cwd.access(io, out, .{})) |_| {
        std.debug.print("error: {s} exists\n", .{out});
        return 2;
    } else |_| {}
    for ([_][]const u8{ "artifacts", "cache", "events", "tapes" }) |sub| {
        try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ out, sub }));
    }

    // The machine: its kernel and initramfs into artifacts/, its image cache the bundle's.
    const machine = try std.json.parseFromSliceLeaky([][]const u8, arena, try read(arena, io, run_directory, "machine.json"), .{});
    var index: usize = 0;
    var cpuid_given = false;
    var guest_cpu: VM.GuestCpu = .host;
    while (index + 1 < machine.len) : (index += 1) {
        const flag = machine[index];
        if (std.mem.eql(u8, flag, "--kernel") or std.mem.eql(u8, flag, "--initrd")) {
            machine[index + 1] = try artifact(arena, io, &bundle, machine[index + 1]);
            index += 1;
        } else if (std.mem.eql(u8, flag, "--cache")) {
            machine[index + 1] = "cache";
            index += 1;
        } else if (std.mem.eql(u8, flag, "--guest-cpu")) {
            guest_cpu = std.meta.stringToEnum(VM.GuestCpu, machine[index + 1]) orelse .host;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--cpuid")) {
            // A run booted with another host's table: the bundle carries that table.
            try write(arena, io, &bundle, cpuid_name, try read(arena, io, "", machine[index + 1]));
            machine[index + 1] = cpuid_name;
            cpuid_given = true;
            index += 1;
        }
    }
    // The guest's CPUID, this host's (a bundle is made where its run was recorded): another CPU
    // model replays the timeline with it, its guest running the code it ran here.
    var machine_out = machine;
    if (!cpuid_given) {
        var entries: [VM.cpuid_entries_max]kvm.CpuidEntry2 = undefined;
        var msrs: [cpuid.pinned_msrs.len]kvm.MsrEntry = undefined;
        const count = try VM.cpuid_table_host(&entries, &msrs, guest_cpu);
        var text: std.Io.Writer.Allocating = .init(arena);
        try cpuid.table_write(entries[0..count.entries], &text.writer);
        try cpuid.msrs_write(msrs[0..count.msrs], &text.writer);
        try write(arena, io, &bundle, cpuid_name, text.written());
        machine_out = try std.mem.concat(arena, []const u8, &.{ machine, &.{ "--cpuid", cpuid_name } });
    }
    try write(arena, io, &bundle, "machine.json", try json_text(arena, machine_out));

    // The request: its program into artifacts/ (a compose or Kubernetes run names files of its
    // own, which no bundle carries yet).
    var request = try std.json.parseFromSliceLeaky(std.json.Value, arena, try read(arena, io, run_directory, "request.json"), .{});
    if (request != .object) return error.RequestNotAnObject;
    const program = request.object.get("program") orelse return error.RequestWithoutProgram;
    if (program != .string) {
        std.debug.print("error: a compose or Kubernetes run cannot be bundled yet\n", .{});
        return 2;
    }
    try request.object.put(arena, "program", .{ .string = try artifact(arena, io, &bundle, program.string) });
    // The explorer that ran it (serve keeps it): into artifacts/ too, what replays it exactly.
    if (request.object.get("explorer")) |explorer| if (explorer == .string) {
        try request.object.put(arena, "explorer", .{ .string = try artifact(arena, io, &bundle, explorer.string) });
        // Its library pair, kept beside it since 2026-11-09 (runs.zig's library_keep): what its
        // host checks load (checks.zig's library_variable looks beside the explorer first).
        for ([_][]const u8{ ".libdeterminismo.so", ".libdeterminismo.json", ".libdeterminismo.h" }) |suffix| {
            const library = try std.fmt.allocPrint(arena, "{s}{s}", .{ explorer.string, suffix });
            if (cwd.access(io, library, .{})) |_| {
                _ = try artifact(arena, io, &bundle, library);
            } else |_| {}
        }
    };
    try write(arena, io, &bundle, "request.json", try json_text(arena, request));

    // The pinned system: its nodes' images beside it (and what the cache keeps beside each:
    // `<image>.*`), where explore looks for a pin's disks not at their own paths (prepare.zig).
    const pin_name = "events/system.pin.json";
    var pin = try std.json.parseFromSliceLeaky(std.json.Value, arena, try read(arena, io, run_directory, pin_name), .{});
    if (pin != .object) return error.PinNotAnObject;
    if (pin.object.getPtr("disks")) |disks| {
        if (disks.* != .array) return error.PinDisksNotAList;
        for (disks.array.items) |*disk| {
            if (disk.* != .string) return error.PinDisksNotAList;
            disk.* = .{ .string = try image(arena, io, &bundle, disk.string) };
        }
    }
    try write(arena, io, &bundle, pin_name, try json_text(arena, pin));

    // The tapes: the timeline's, and those it began inside.
    var tapes: [tapes_max]u32 = undefined;
    var tape_count: usize = 0;
    try tapes_add(arena, io, run_directory, timeline, &tapes, &tape_count);
    for (tapes[0..tape_count]) |branch| {
        const name = try std.fmt.allocPrint(arena, "tapes/branch-{d}.jsonl", .{branch});
        try copy(arena, io, &bundle, try std.fs.path.join(arena, &.{ run_directory, name }), name);
    }

    try checkers_add(arena, io, &bundle);

    const Fields = struct { build: ?[]const u8 = null, seed: ?u64 = null, scenario: ?[]const u8 = null, timeline: ?[]const u8 = null };
    const fields = try std.json.parseFromSliceLeaky(Fields, arena, try read(arena, io, out, "request.json"), .{ .ignore_unknown_fields = true });
    const readme = try std.fmt.allocPrint(arena,
        \\Timeline {d} of {s} ({s}, seed {d}, timelines of {s}), recorded by determinismo {s}.
        \\
        \\Replay it on x86-64 Linux, with determinismo built at that commit and its KVM module loaded
        \\(infra/host/build-kvm.sh, load-kvm.sh). The guest boots with the recording host's CPUID
        \\(cpuid.txt, its model below), so it runs the same code; a CPU with every feature that table
        \\sets can present it (explore refuses one that lacks a feature). Whether retired-branch
        \\counts, determinismo's clock, agree on another model as they do on the recording one is
        \\what a first replay there shows (the events hash):
        \\
        \\  cd <this directory> && determinismo explore --run . --branch {d}
        \\
        \\It replays to the same history (its events hash, the same failures). A moment of it:
        \\add --at-vtime-ms <ms> --exec 'det-nodes exec <node> <command>'.
        \\
        \\The tapes (tapes/) are what was decided in the timeline and those it began inside; the
        \\rest is what they were recorded on (a tape refuses other inputs): the guest kernel, the
        \\initramfs and the test program (artifacts/), the run's options (request.json,
        \\machine.json), its system (events/system.pin.json) and its nodes' images beside it (by
        \\their digests). SHA256SUMS
        \\lists every file.
        \\
        \\Recorded on: {s}
        \\
    , .{
        timeline,                                  std.fs.path.basename(run_directory),
        fields.scenario orelse "-",                fields.seed orelse 0,
        fields.timeline orelse "their own length", fields.build orelse "(build not recorded)",
        timeline,                                  try cpu_model(arena, io),
    });
    try write(arena, io, &bundle, "README.txt", readme);
    try sums_write(arena, io, &bundle);
    var total: u64 = 0;
    for (bundle.files.items) |name| total += (try cwd.statFile(io, try std.fs.path.join(arena, &.{ out, name }), .{})).size;
    var stored_total: u64 = 0;
    for (bundle.stored.items) |entry| stored_total += entry.size;
    if (store) |directory| {
        var text: std.ArrayList(u8) = .empty;
        for (bundle.stored.items) |entry| try text.print(arena, "{s}  {d}  {s}\n", .{ &entry.sha256, entry.size, entry.path });
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ out, "STORED" }), .data = text.items });
        std.debug.print("bundle {s}: timeline {d}, {d} tapes, {d} files ({d} KiB) here, {d} in {s} ({d} MiB); " ++
            "replay: determinismo bundle fetch {s} {s}, then cd {s} && determinismo explore --run . --branch {d}\n", .{
            out,       timeline,           tape_count, bundle.files.items.len + 2, total >> 10, bundle.stored.items.len,
            directory, stored_total >> 20, out,        directory,                  out,         timeline,
        });
        return 0;
    }
    std.debug.print("bundle {s}: timeline {d}, {d} tapes, {d} files, {d} MiB; replay: cd {s} && " ++
        "determinismo explore --run . --branch {d}\n", .{ out, timeline, tape_count, bundle.files.items.len + 1, total >> 20, out, timeline });
    return 0;
}

/// `bundle fetch <bundle> <store>`: the files STORED lists, from the store into the bundle at
/// their paths, each checked against its digest (a blob altered or truncated in transit is
/// refused, never replayed on).
fn fetch(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    if (arguments.len != 2) return error.Usage;
    const out: []const u8 = arguments[0];
    const store: []const u8 = arguments[1];
    const cwd = std.Io.Dir.cwd();
    const listing = try read(arena, io, out, "STORED");
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    var count: usize = 0;
    var total: u64 = 0;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const hex = fields.next() orelse return error.BadStored;
        const size = try std.fmt.parseInt(u64, fields.next() orelse return error.BadStored, 10);
        const path = fields.rest();
        if (hex.len != 64 or path.len == 0 or std.mem.indexOf(u8, path, "..") != null or std.fs.path.isAbsolute(path)) return error.BadStored;
        const target = try std.fs.path.join(arena, &.{ out, path });
        if (std.fs.path.dirname(target)) |directory| try cwd.createDirPath(io, directory);
        const blob = try std.fs.path.join(arena, &.{ store, "sha256", hex });
        cwd.copyFile(blob, cwd, target, io, .{}) catch |err| {
            std.debug.print("error: {s} ({s}) from the store: {s}\n", .{ path, hex, @errorName(err) });
            return err;
        };
        const digest = try sha256_file(io, target);
        if (!std.mem.eql(u8, &digest, hex)) {
            std.debug.print("error: {s}: the store's blob {s} hashes to {s}\n", .{ path, hex, &digest });
            cwd.deleteFile(io, target) catch {};
            return 1;
        }
        count += 1;
        total += size;
    }
    std.debug.print("bundle {s}: {d} files from {s} ({d} MiB), each checked; replay: cd {s} && determinismo explore --run . --branch <timeline>\n", .{ out, count, store, total >> 20, out });
    return 0;
}

/// A file's SHA-256, in hex.
fn sha256_file(io: std.Io, path: []const u8) ![64]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [1 << 20]u8 = undefined;
    var reader = file.reader(io, &.{});
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// This host's CPU, as /proc/cpuinfo names it (a bundle is made where its run was recorded).
fn cpu_model(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    // Read to its end: /proc files report a size of 0, which a read sized by it takes for empty
    // (every bundle said "Recorded on: " with nothing after, until 2026-11-09).
    const file = std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return "unknown";
    defer file.close(io);
    var reader = file.reader(io, &.{});
    var buffer: [64 * 1024]u8 = undefined;
    var size: usize = 0;
    while (size < buffer.len) {
        const count = reader.interface.readSliceShort(buffer[size..]) catch return "unknown";
        if (count == 0) break;
        size += count;
    }
    const text = buffer[0..size];
    var parts: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for ([_][]const u8{ "vendor_id", "cpu family", "model", "stepping", "model name" }) |wanted| {
            if (!std.mem.eql(u8, key, wanted)) continue;
            try parts.print(arena, "{s}{s} {s}", .{ if (parts.items.len > 0) ", " else "", key, value });
        }
        if (std.mem.eql(u8, key, "stepping")) break; // The first CPU's (its last field of these).
    }
    return parts.items;
}

/// `branch` and, recursively, the timelines its tape says it began inside, each once.
fn tapes_add(arena: std.mem.Allocator, io: std.Io, run_directory: []const u8, branch: u32, tapes: *[tapes_max]u32, count: *usize) !void {
    if (std.mem.indexOfScalar(u32, tapes[0..count.*], branch) != null) return;
    if (count.* == tapes_max) return error.TooManyTapes;
    tapes[count.*] = branch;
    count.* += 1;
    const name = try std.fmt.allocPrint(arena, "tapes/branch-{d}.jsonl", .{branch});
    const text = try read(arena, io, run_directory, name);
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const Header = struct {
        chain: []const struct { branch: u32 } = &.{},
        fork: ?struct { branch: u32 } = null,
    };
    const header = try std.json.parseFromSliceLeaky(Header, arena, line, .{ .ignore_unknown_fields = true });
    for (header.chain) |segment| try tapes_add(arena, io, run_directory, segment.branch, tapes, count);
    if (header.fork) |fork| try tapes_add(arena, io, run_directory, fork.branch, tapes, count);
}

/// A file into artifacts/: its path in the bundle.
fn artifact(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle, path: []const u8) ![]const u8 {
    const name = try std.fs.path.join(arena, &.{ "artifacts", std.fs.path.basename(path) });
    if (has(bundle, name)) return name;
    try bundle_input(arena, io, bundle, path, name);
    return name;
}

/// A node's image into events/, beside the pin, with what the cache keeps beside it
/// (`<image>.*`): its name for the pin. Nodes sharing one image share its copy.
fn image(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    const name = try std.fs.path.join(arena, &.{ "events", base });
    if (has(bundle, name)) return base;
    try bundle_input(arena, io, bundle, path, name);
    const directory = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    const prefix = try std.fmt.allocPrint(arena, "{s}.", .{base});
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or std.mem.indexOf(u8, entry.name, ".part") != null) continue;
        const beside = try std.fs.path.join(arena, &.{ "events", entry.name });
        try bundle_input(arena, io, bundle, try std.fs.path.join(arena, &.{ directory, entry.name }), beside);
    }
    return base;
}

/// One of the inputs: into the store by its digest (once: another bundle's or run's copy is
/// the same bytes), STORED's entry; or, without a store, copied into the bundle.
fn bundle_input(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle, from: []const u8, name: []const u8) !void {
    const store = bundle.store orelse return copy(arena, io, bundle, from, name);
    const cwd = std.Io.Dir.cwd();
    const digest = try sha256_file(io, from);
    const blob = try std.fs.path.join(arena, &.{ store, "sha256", &digest });
    if (cwd.access(io, blob, .{})) |_| {} else |_| {
        const partial = try std.fmt.allocPrint(arena, "{s}.part", .{blob});
        cwd.copyFile(from, cwd, partial, io, .{}) catch |err| {
            std.debug.print("error: storing {s}: {s}\n", .{ from, @errorName(err) });
            return err;
        };
        try cwd.rename(partial, cwd, blob, io);
    }
    const size = (try cwd.statFile(io, from, .{})).size;
    try bundle.stored.append(arena, .{ .path = name, .sha256 = digest, .size = size });
}

/// The host checks' services' sources (checkers/: Elle's, built with podman), from where the
/// bundle is made, as a check finds them where determinismo runs (sdk/zig/elle.zig): a bundle's
/// checks start what they need in its directory, on a machine with podman and nothing of ours set
/// up for them (an inspection machine's "host checks run to completion" failed without, NATS run
/// 1722's timeline 241). Build outputs and dot directories left out; none here, none carried.
fn checkers_add(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle) !void {
    const root = "checkers";
    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        var parts = std.mem.splitScalar(u8, item.path, '/');
        const skipped = while (parts.next()) |part| {
            if (part.len > 0 and part[0] == '.') break true;
            if (std.mem.eql(u8, part, "classes") or std.mem.eql(u8, part, "target")) break true;
        } else false;
        if (skipped) continue;
        const name = try std.fs.path.join(arena, &.{ root, item.path });
        if (std.fs.path.dirname(name)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ bundle.out, parent }));
        }
        try copy(arena, io, bundle, name, name);
    }
}

fn copy(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle, from: []const u8, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(from, cwd, try std.fs.path.join(arena, &.{ bundle.out, name }), io, .{}) catch |err| {
        std.debug.print("error: copying {s}: {s}\n", .{ from, @errorName(err) });
        return err;
    };
    try bundle.files.append(arena, name);
}

fn read(arena: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(arena, &.{ directory, name });
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(json_max)) catch |err| {
        std.debug.print("error: reading {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn write(arena: std.mem.Allocator, io: std.Io, bundle: *Bundle, name: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ bundle.out, name }), .data = data });
    try bundle.files.append(arena, name);
}

fn json_text(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(value, .{})});
}

/// SHA256SUMS: `<hex>  <name>` for each file, the stored ones too (sha256sum -c checks it,
/// once they are fetched).
fn sums_write(arena: std.mem.Allocator, io: std.Io, bundle: *const Bundle) !void {
    var text: std.ArrayList(u8) = .empty;
    for (bundle.files.items) |name| {
        try text.print(arena, "{s}  {s}\n", .{ &(try sha256_file(io, try std.fs.path.join(arena, &.{ bundle.out, name }))), name });
    }
    for (bundle.stored.items) |entry| try text.print(arena, "{s}  {s}\n", .{ &entry.sha256, entry.path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ bundle.out, "SHA256SUMS" }), .data = text.items });
}

test tapes_max {
    assert(tapes_max >= 64 + 1); // tape.zig's chain_length_max, and a fork's origin.
}
