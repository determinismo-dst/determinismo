// SPDX-License-Identifier: MIT
//! The host's runs. Every exploration is one, however it was started (`determinismo explore` at
//! a terminal or from a script, or serve's API): a directory `runs/<id>` of the data directory
//! (`--data`, else $DETERMINISMO_DATA, else ~/.determinismo) with its request and machine (what
//! replays it), its record, events and tapes, its output, and a pid file its explorer holds
//! locked while it runs. `determinismo serve` shows that directory: the runs it starts and the
//! others, as they appear.
const std = @import("std");

/// The version of what an explorer persists and a later one reads back on a resume: the
/// timelines' summaries (record.jsonl.summaries), the record's lines, the holders' registry
/// and their files' names, the history and the bandit's files. Bumped when any of them changes:
/// a run made with another keeps its own explorer (serve.zig's core_same). 1: 2026-11-15. 2:
/// 2026-11-19, a timeline's own clock in its summary (SummaryHeader.jitter_seed). 3: 2026-11-25,
/// each timeline's properties in its record line (report.Recorded), for a resume's verdict. 4:
/// 2026-11-26, the seed a timeline ran with in its summary (SummaryHeader.seed: CE23). 5:
/// 2026-11-26, the record's catalog line (RecordLine.catalog: CE45). 6: 2026-11-26, each return's
/// children's numbers (RecordLine.planned: CE32-CE34). 7: 2026-11-26, a summary's full tape's
/// moment (SummaryHeader.tape_full_ns: CE58). 8: 2026-11-26, an assertion's declaration
/// (RecordLine.declared: CE45's remainder).
pub const state_format: u32 = 8;
const assert = std.debug.assert;
const linux = std.os.linux;

/// Run ids are below this (serve keeps them in an array of this size).
pub const runs_max = 4096;

/// The data directory: `given` (`--data`), else $DETERMINISMO_DATA, else ~/.determinismo.
pub fn data_directory(arena: std.mem.Allocator, given: ?[]const u8) ![]const u8 {
    if (given) |directory| return absolute(arena, directory);
    if (std.c.getenv("DETERMINISMO_DATA")) |directory| return absolute(arena, std.mem.span(directory));
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ std.mem.span(home), ".determinismo" });
}

pub fn directory_of(arena: std.mem.Allocator, data: []const u8, id: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/runs/{d}", .{ data, id });
}

pub const Claimed = struct { id: u32, directory: []const u8 };

/// The next run, claimed: the first id after the highest there whose directory this process
/// made (mkdir is atomic: two claimants never share one).
pub fn claim(arena: std.mem.Allocator, io: std.Io, data: []const u8) !Claimed {
    const runs_path = try std.fs.path.join(arena, &.{ data, "runs" });
    try std.Io.Dir.cwd().createDirPath(io, runs_path);
    var id = (try ids_highest(arena, runs_path)) + 1;
    while (id < runs_max) : (id += 1) {
        const directory = try directory_of(arena, data, id);
        const directory_z = try arena.dupeSentinel(u8, directory, 0);
        const made = linux.mkdirat(linux.AT.FDCWD, directory_z, 0o755);
        switch (linux.errno(made)) {
            .SUCCESS => return .{ .id = id, .directory = directory },
            .EXIST => continue, // Another claimant's.
            else => return error.ClaimFailed,
        }
    }
    return error.TooManyRuns;
}

/// `<data>/adopt/<id>`: a run an explorer resumed from a command line (`explore --resume`), said
/// to serve, which looks at a run's directory once and so showed it ended while it ran: a stop
/// through serve answered that it was not running and no guard of the host saw it (the
/// branching measure's resume, srv4, 2026-11-22). serve takes each as running (runs_adopt).
pub fn adopt_note(arena: std.mem.Allocator, data: []const u8, id: u32) !void {
    assert(id > 0 and id < runs_max);
    const directory = try std.fs.path.joinZ(arena, &.{ data, "adopt" });
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, directory, 0o755))) {
        .SUCCESS, .EXIST => {},
        else => return error.AdoptNote,
    }
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/{d}", .{ directory, id }, 0);
    const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.AdoptNote;
    _ = linux.close(@intCast(opened));
}

/// The runs adopt_note named, each note deleted as it is read.
pub fn adopted_take(arena: std.mem.Allocator, data: []const u8) ![]u32 {
    const directory = try std.fs.path.join(arena, &.{ data, "adopt" });
    const named = try ids(arena, directory);
    for (named) |id| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/{d}", .{ directory, id }, 0);
        _ = linux.unlink(path);
    }
    return named;
}

/// The id of `directory` when it is a run's, `<data>/runs/<id>` (absolute), else null.
pub fn id_in(data: []const u8, directory: []const u8) ?u32 {
    const parent = std.fs.path.dirname(directory) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(parent), "runs")) return null;
    if (!std.mem.eql(u8, std.fs.path.dirname(parent) orelse return null, data)) return null;
    const id = std.fmt.parseInt(u32, std.fs.path.basename(directory), 10) catch return null;
    return if (id > 0 and id < runs_max) id else null;
}

/// The run whose `<name>` (its events, record or tapes, asked elsewhere) links to `target`, if
/// any: a new run there would replace that one's (runs 69 to 71 on srv3 shared /tmp/rmq, and
/// serve could open only one: DuckDB attaches a file once).
pub fn linked_by(arena: std.mem.Allocator, data: []const u8, name: []const u8, target: []const u8) !?u32 {
    const runs_path = try std.fs.path.join(arena, &.{ data, "runs" });
    for (try ids(arena, runs_path)) |id| {
        const link = try std.fs.path.joinZ(arena, &.{ try directory_of(arena, data, id), name });
        var buffer: [4096]u8 = undefined;
        const size = linux.readlinkat(linux.AT.FDCWD, link, &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS) continue; // Its own, or none.
        if (std.mem.eql(u8, buffer[0..size], target)) return id;
    }
    return null;
}

/// Removes a run's link to its events, record or tapes kept elsewhere (`name`), once that
/// directory or file was deleted: another run takes the path.
pub fn link_drop(arena: std.mem.Allocator, data: []const u8, id: u32, name: []const u8) !void {
    const link = try std.fs.path.joinZ(arena, &.{ try directory_of(arena, data, id), name });
    const result = linux.unlink(link);
    switch (linux.errno(result)) {
        .SUCCESS, .NOENT => {},
        else => return error.UnlinkFailed,
    }
}

/// The run ids there, ascending.
pub fn ids(arena: std.mem.Allocator, runs_path: []const u8) ![]u32 {
    var found: std.ArrayList(u32) = .empty;
    const path_z = try arena.dupeSentinel(u8, runs_path, 0);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(path_z, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return found.items;
    defer _ = linux.close(@intCast(fd));
    var buffer: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            offset += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const id = std.fmt.parseInt(u32, name, 10) catch continue;
            if (id == 0 or id >= runs_max) continue;
            try found.append(arena, id);
        }
    }
    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.items;
}

fn ids_highest(arena: std.mem.Allocator, runs_path: []const u8) !u32 {
    const all = try ids(arena, runs_path);
    return if (all.len == 0) 0 else all[all.len - 1];
}

/// Marks the run as running: this process's pid in its `pid` file, which it holds under an
/// exclusive lock until it ends (the file stays open; what it executes does not inherit it).
pub fn running_mark(arena: std.mem.Allocator, directory: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/pid", .{directory}, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.PidFile;
    const fd: linux.fd_t = @intCast(opened);
    // Another explorer holds it for good; a probe (running_pid: serve's, a queue's) for an
    // instant, retried past: one taken as another explorer's failed serve's run 187 at its start.
    const locked = for (0..lock_attempts_max) |_| {
        if (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)) == .SUCCESS) break true;
        const pause: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    } else false;
    if (!locked) {
        _ = linux.close(fd);
        return error.RunRunning; // Another explorer has it.
    }
    // One run at a time: the one before (an exploration of several scenarios, each its own
    // run) has ended.
    if (running_fd) |before| _ = linux.close(before);
    running_fd = fd;
    _ = linux.ftruncate(fd, 0);
    var text_buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{d}\n", .{linux.getpid()}) catch unreachable;
    if (linux.errno(linux.pwrite(fd, text.ptr, text.len, 0)) != .SUCCESS) return error.PidFile;
}

/// The pid file this process holds (locked) for the run it explores.
var running_fd: ?linux.fd_t = null;
/// Tries at the pid file's lock, 10 ms apart: a second.
const lock_attempts_max = 100;

/// In a child forked from the explorer: its copy of the pid file closed. A flock is the open
/// file's, held while any process keeps it: a worker or holder outliving a killed explorer kept
/// its run "running" (e2e `resume`: refused its own record; a terminal run's holders, for good).
pub fn running_forget() void {
    if (running_fd) |fd| _ = linux.close(fd);
    running_fd = null;
}

/// The run's explorer, if it runs: the pid its pid file names, while the file is locked.
pub fn running_pid(arena: std.mem.Allocator, directory: []const u8) ?linux.pid_t {
    const path = std.fmt.allocPrintSentinel(arena, "{s}/pid", .{directory}, 0) catch return null;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    // A shared lock taken: no explorer holds it.
    if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) return null;
    var buffer: [16]u8 = undefined;
    const read = linux.pread(fd, &buffer, buffer.len, 0);
    if (linux.errno(read) != .SUCCESS) return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..read], " \n"), 10) catch null;
}

/// A copy of the file named by its content, under `<data>/artifacts`, made once: runs of one
/// build share it, and a deploy, which replaces the original, leaves it be.
pub fn artifact_keep(arena: std.mem.Allocator, io: std.Io, data: []const u8, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, arena, .unlimited);
    const directory = try std.fs.path.join(arena, &.{ data, "artifacts" });
    try cwd.createDirPath(io, directory);
    const name = try std.fmt.allocPrint(arena, "{x:0>16}-{s}", .{
        std.hash.Wyhash.hash(0, bytes), std.fs.path.basename(path),
    });
    const kept = try std.fs.path.join(arena, &.{ directory, name });
    try keep_once(arena, io, kept, bytes);
    return kept;
}

/// A copy kept by content whose file keeps its own name: `<data>/artifacts/<hash>/<name>`, for a
/// file whose name is part of what a run boots (an injector: see injectors_keep).
pub fn artifact_keep_named(arena: std.mem.Allocator, io: std.Io, data: []const u8, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, arena, .unlimited);
    const directory = try std.fs.path.join(arena, &.{ data, "artifacts", try std.fmt.allocPrint(arena, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)}) });
    try cwd.createDirPath(io, directory);
    const kept = try std.fs.path.join(arena, &.{ directory, std.fs.path.basename(path) });
    try keep_once(arena, io, kept, bytes);
    return kept;
}

/// Writes `kept` once, executable. Staged under a name of this thread's: two runs keeping it at
/// once do not collide, nor two requests to one server (a thread each: the self-test's controller
/// answered 500 when one renamed the file the other was about to chmod).
fn keep_once(arena: std.mem.Allocator, io: std.Io, kept: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, kept, .{}) catch {
        const staging = try std.fmt.allocPrintSentinel(arena, "{s}.staging-{d}-{d}", .{ kept, linux.getpid(), linux.gettid() }, 0);
        try cwd.writeFile(io, .{ .sub_path = staging, .data = bytes });
        // Executable: a test program is run from its kept copy.
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, staging, 0o755)) != .SUCCESS) return error.ChmodFailed;
        try cwd.rename(staging, cwd, kept, io);
    };
}

/// A command-line run's injectors kept by content for its analyses (run_request_write), each
/// under its own name: an injector's name is part of what the run boots (its system disk holds
/// `/det/injectors/<name>`, and the disk's hash covers the name). Kept as `<hash>-<name>`, every
/// analysis of a command-line run with an injector booted another disk and was refused (CE60,
/// the Lean replica of determinismo, round 7).
pub fn injectors_keep(arena: std.mem.Allocator, io: std.Io, data: []const u8, given: []const []const u8) ![]const []const u8 {
    const kept = try arena.alloc([]const u8, given.len);
    for (kept, given) |*path, one| path.* = try artifact_keep_named(arena, io, data, one);
    return kept;
}

/// An initramfs kept by content (artifact_keep), with the guest's tools whole that det-initramfs
/// wrote beside the image under its content's name (`<hash>-tools.cpio`: the image packs them
/// stripped of their debug sections) kept beside it in artifacts/: a guest tool's panic, its
/// functions and addresses, maps to lines after a deploy (docs/DEBUGGING.md). None beside it
/// (an image of an earlier det-initramfs): the image alone.
pub fn initrd_keep(arena: std.mem.Allocator, io: std.Io, data: []const u8, path: []const u8) ![]const u8 {
    const kept = try artifact_keep(arena, io, data, path);
    const name = try std.fmt.allocPrint(arena, "{s}-tools.cpio", .{std.fs.path.basename(kept)[0..16]});
    const target = try std.fs.path.join(arena, &.{ data, "artifacts", name });
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, target, .{}) catch {
        const source = try std.fs.path.join(arena, &.{ std.fs.path.dirname(path) orelse ".", name });
        const bytes = cwd.readFileAlloc(io, source, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return kept,
            else => return err,
        };
        const staging = try std.fmt.allocPrint(arena, "{s}.staging-{d}-{d}", .{ target, linux.getpid(), linux.gettid() });
        try cwd.writeFile(io, .{ .sub_path = staging, .data = bytes });
        try cwd.rename(staging, cwd, target, io);
    };
    return kept;
}

/// The library a kept explorer's test programs reach the SDK through on the host (sdk/clojure's
/// determinismo.ffi: libdeterminismo.so and its .json, beside the build's binary; a jank one's
/// header, libdeterminismo.h), kept beside it as `<explorer>.libdeterminismo.so`, `.json` and
/// `.h` when missing (checks.library_variable reads
/// them): a run's explorer kept alone (1cfcc26) left a Clojure program no library, and every
/// Hazelcast hunt from run 1658 on ended in NoSuchFileException.
pub fn library_keep(arena: std.mem.Allocator, io: std.Io, explorer: []const u8, build_binary: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const directory = std.fs.path.dirname(build_binary) orelse return error.NoDirectory;
    // The header too: a jank program compiles against it (program_pack.zig's script includes
    // libdeterminismo.h from beside its library); without it every jank workload run through
    // serve failed ("'libdeterminismo.h' file not found", phoenixNAP run 1901).
    for ([_][]const u8{ "so", "json", "h" }) |extension| {
        const kept = try std.fmt.allocPrint(arena, "{s}.libdeterminismo.{s}", .{ explorer, extension });
        cwd.access(io, kept, .{}) catch {
            const source = try std.fmt.allocPrint(arena, "{s}/libdeterminismo.{s}", .{ directory, extension });
            const bytes = try cwd.readFileAlloc(io, source, arena, .unlimited);
            const staging = try std.fmt.allocPrint(arena, "{s}.staging-{d}-{d}", .{ kept, linux.getpid(), linux.gettid() });
            try cwd.writeFile(io, .{ .sub_path = staging, .data = bytes });
            try cwd.rename(staging, cwd, kept, io);
        };
    }
}

/// `path` from the root: relative ones from the working directory.
pub fn absolute(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = linux.getcwd(&buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return error.WorkingDirectory;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buffer)), 0);
    return std.fs.path.resolve(arena, &.{ cwd, path });
}

/// What this process and its children print goes on to where it went, and into `path` too:
/// a run started at a terminal has its output in its directory, as serve's runs do. A child
/// copies both streams until every writer is gone; it outlives an interrupt to drain them.
pub fn output_tee(arena: std.mem.Allocator, path: []const u8) !void {
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const file_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const file = linux.open(path_z, file_flags, 0o644);
    if (linux.errno(file) != .SUCCESS) return error.OutputFile;
    var pipes: [2][2]i32 = undefined;
    for (&pipes) |*pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        for (pipes) |pipe| _ = linux.close(pipe[1]);
        const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        for ([_]linux.SIG{ .INT, .TERM, .HUP, .PIPE }) |signal| _ = linux.sigaction(signal, &ignore, null);
        tee_loop(.{ pipes[0][0], pipes[1][0] }, .{ 1, 2 }, @intCast(file));
        linux.exit_group(0);
    }
    _ = linux.close(@intCast(file));
    for (pipes, [_]i32{ 1, 2 }) |pipe, target| {
        _ = linux.close(pipe[0]);
        if (linux.errno(linux.dup2(pipe[1], target)) != .SUCCESS) return error.Dup;
        _ = linux.close(pipe[1]);
    }
}

fn tee_loop(sources: [2]i32, targets: [2]i32, file: linux.fd_t) void {
    var polled: [2]linux.pollfd = .{
        .{ .fd = sources[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sources[1], .events = linux.POLL.IN, .revents = 0 },
    };
    var open: u32 = 2;
    var buffer: [16 * 1024]u8 = undefined;
    while (open > 0) {
        const ready = linux.poll(&polled, polled.len, -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return;
        for (&polled, targets) |*entry, target| {
            if (entry.fd < 0 or entry.revents == 0) continue;
            const read = linux.read(entry.fd, &buffer, buffer.len);
            if (linux.errno(read) == .INTR) continue;
            if (linux.errno(read) != .SUCCESS or read == 0) {
                _ = linux.close(entry.fd);
                entry.fd = -1; // poll passes over negative descriptors.
                open -= 1;
                continue;
            }
            write_all(target, buffer[0..read]);
            write_all(file, buffer[0..read]);
        }
    }
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return; // A terminal gone: the file still gets it.
        written += result;
    }
}

test "a command-line run's injectors are kept by content under their own names" {
    // Kept as `<hash>-chaos`, the analysis's --injector built a system disk with
    // /det/injectors/<hash>-chaos, another disk than the run's: every tape refused
    // (TapeInputsDiffer; CE60, the Lean replica of determinismo, round 7).
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absolute(arena, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    const cwd = std.Io.Dir.cwd();
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    const chaos = try std.fs.path.join(arena, &.{ root, "chaos" });
    try cwd.writeFile(io, .{ .sub_path = chaos, .data = "#!/bin/sh\nexit 0\n" });
    const kept = try injectors_keep(arena, io, data, &.{chaos});
    try std.testing.expectEqualStrings("chaos", std.fs.path.basename(kept[0]));
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0\n", try cwd.readFileAlloc(io, kept[0], arena, .limited(64)));
    // Another content under the same name: another copy, the first one left as it was.
    const other = try std.fs.path.join(arena, &.{ root, "other" });
    try cwd.createDirPath(io, other);
    const chaos2 = try std.fs.path.join(arena, &.{ other, "chaos" });
    try cwd.writeFile(io, .{ .sub_path = chaos2, .data = "#!/bin/sh\nexit 1\n" });
    const kept2 = try injectors_keep(arena, io, data, &.{chaos2});
    try std.testing.expectEqualStrings("chaos", std.fs.path.basename(kept2[0]));
    try std.testing.expect(!std.mem.eql(u8, kept[0], kept2[0]));
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0\n", try cwd.readFileAlloc(io, kept[0], arena, .limited(64)));
}

test "an initramfs is kept with its tools whole beside it, by the image's content name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absolute(arena, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    const cwd = std.Io.Dir.cwd();
    const guest = try std.fs.path.join(arena, &.{ root, "guest" });
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    try cwd.createDirPath(io, guest);
    const image = try std.fs.path.join(arena, &.{ guest, "base.cpio" });
    try cwd.writeFile(io, .{ .sub_path = image, .data = "an image" });
    const name = try std.fmt.allocPrint(arena, "{x:0>16}-tools.cpio", .{std.hash.Wyhash.hash(0, "an image")});
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ guest, name }), .data = "its tools" });
    const kept = try initrd_keep(arena, io, data, image);
    try std.testing.expect(std.mem.endsWith(u8, kept, "-base.cpio"));
    try std.testing.expectEqualStrings(name[0..16], std.fs.path.basename(kept)[0..16]);
    const tools = try std.fs.path.join(arena, &.{ data, "artifacts", name });
    try std.testing.expectEqualStrings("its tools", try cwd.readFileAlloc(io, tools, arena, .limited(64)));
    // Kept again (a resume, its --initrd the kept copy, named `<hash>-<hash>-base.cpio` then, as
    // artifact_keep names a copy of a copy): its tools found by the same leading hash.
    const again = try initrd_keep(arena, io, data, kept);
    try std.testing.expectEqualStrings(name[0..16], std.fs.path.basename(again)[0..16]);
    // An image with no tools beside it: kept alone.
    try cwd.writeFile(io, .{ .sub_path = image, .data = "an older image" });
    const older = try initrd_keep(arena, io, data, image);
    const none = try std.fmt.allocPrint(arena, "{s}-tools.cpio", .{std.fs.path.basename(older)[0..16]});
    try std.testing.expectError(error.FileNotFound, cwd.access(io, try std.fs.path.join(arena, &.{ data, "artifacts", none }), .{}));
}

test "claim: ids in order, never one twice; the pid lock tells a running run" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try absolute(arena, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    const first = try claim(arena, io, data);
    const second = try claim(arena, io, data);
    try std.testing.expectEqual(1, first.id);
    try std.testing.expectEqual(2, second.id);
    // One made by hand further on: the next comes after it.
    try std.Io.Dir.cwd().createDirPath(io, try directory_of(arena, data, 7));
    try std.testing.expectEqual(8, (try claim(arena, io, data)).id);
    const runs_path = try std.fs.path.join(arena, &.{ data, "runs" });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 7, 8 }, try ids(arena, runs_path));

    try std.testing.expectEqual(null, running_pid(arena, first.directory));
    try running_mark(arena, first.directory);
    try std.testing.expectEqual(linux.getpid(), running_pid(arena, first.directory).?);
    try std.testing.expectError(error.RunRunning, running_mark(arena, first.directory));
}

test "adopt: a resume's note, read once; a run's directory's id" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try absolute(arena, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    try std.testing.expectEqual(0, (try adopted_take(arena, data)).len); // None said: no directory.
    try adopt_note(arena, data, 12);
    try adopt_note(arena, data, 12); // Said twice before serve looked: once.
    try std.testing.expectEqualSlices(u32, &.{12}, try adopted_take(arena, data));
    try std.testing.expectEqual(0, (try adopted_take(arena, data)).len);
    try std.testing.expectEqual(12, id_in(data, try directory_of(arena, data, 12)).?);
    try std.testing.expectEqual(null, id_in(data, "/elsewhere/runs/12"));
    try std.testing.expectEqual(null, id_in(data, try std.fmt.allocPrint(arena, "{s}/runs/x", .{data})));
    try std.testing.expectEqual(null, id_in(data, try std.fmt.allocPrint(arena, "{s}/other/12", .{data})));
}
