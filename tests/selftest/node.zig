// SPDX-License-Identifier: MIT
//! det-selftest-node: a tiny TCP service for determinismo's self-tests (a `binary` node).
//! Answers each line with the same line; on "die" it exits with status 3, as a crashing
//! service would. With DET_MUTANT set it answers in uppercase: a mutant the tests must catch.
//! `det-selftest-node hog` instead touches memory until the kernel kills it (the node's memory
//! limit makes that an OOM kill). With DET_WORKERS=<n> it also supervises n worker processes,
//! replacing any that dies (what process_kill faults test). `det-selftest-node custom-fault` is
//! a custom fault: it draws a number and reports it, with where the node finds det-stop-faults.
//! With DET_DURABLE set, a first start writes /data/synced (synced: the file and its directory)
//! and /data/unsynced (not synced): what crashes and wipes must keep and lose.
//! `det-selftest-node write <path>` writes a file in /data and syncs it and its directory,
//! exiting 1 if the disk refused (disk faults); `unsynced <path>` writes one and syncs nothing;
//! `write2 <path> <path>` writes two at once, from
//! two threads (two durability points together). `det-selftest-node ping <a.b.c.d>` exits 0 if
//! the service at that address answers a line (a node reaching itself while isolated).
//! `realtime` prints the node's CLOCK_REALTIME in nanoseconds; `abs-sleep <ms>` waits until
//! that clock's now + ms twice, a nanosleep then a futex, both absolute (TIMER_ABSTIME,
//! FUTEX_CLOCK_REALTIME), and exits 0 if each took about that long on the monotonic clock (a
//! node's skewed clock: its deadlines are its own time). `race <rounds>` races a thread and the
//! one it wakes that many times and prints "early <n>": how many times the woken one ran before
//! its waker went on (what the `interleave` fault changes).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const port = 7000;
const connections_max = 1_000_000;
const hog_chunk_size = 1 << 20;
const hog_chunks_max = 4096;

var mutant = false;

/// DET_CRASH_POINT: a crash point marked every 50 ms (the e2e crash-points check's non-JVM half).
fn crash_point_loop() void {
    while (true) {
        sdk.sleep_ms(50);
        sdk.crash_point("selftest.loop");
    }
}

fn on_hangup(_: linux.SIG) callconv(.c) void {
    linux.exit_group(2);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "hog")) return hog();
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "leak")) return leak();
    // `exists <path>`: exits 0 if the file is there (the node has no shell to ask).
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "exists")) {
        const found = linux.errno(linux.access(arguments[2], linux.F_OK)) == .SUCCESS;
        linux.exit_group(if (found) 0 else 1);
    }
    // `holds <path> <text>`: exits 0 if the file holds exactly the text (a write's data, where
    // `exists` would take an empty file, its creation committed by the journal, for the write).
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "holds")) {
        var buffer: [256]u8 = undefined;
        const fd = linux.open(arguments[2], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) linux.exit_group(1);
        const size = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS) linux.exit_group(1);
        const expected = arguments[3];
        linux.exit_group(if (size == expected.len + 1 and std.mem.eql(u8, buffer[0..expected.len], expected) and buffer[expected.len] == '\n') 0 else 1);
    }
    // `hosts-has <name>`: exits 0 if this node's hosts file names it (a peer's name left out
    // while it is down: Faults.names_follow_liveness).
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "hosts-has")) {
        var buffer: [16 * 1024]u8 = undefined;
        const fd = linux.open("/etc/hosts", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) linux.exit_group(2);
        const size = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS) linux.exit_group(2);
        var lines = std.mem.tokenizeScalar(u8, buffer[0..size], '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next() orelse continue;
            while (fields.next()) |name| if (std.mem.eql(u8, name, arguments[2])) linux.exit_group(0);
        }
        linux.exit_group(1);
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "crash")) crash();
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "realtime")) {
        var line_buffer: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "{d}\n", .{clock_ns(.REALTIME)}) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "abs-sleep")) {
        const wanted_ns = (std.fmt.parseInt(u64, arguments[2], 10) catch linux.exit_group(2)) * std.time.ns_per_ms;
        const slept_ns = [_]u64{ abs_nanosleep(wanted_ns), abs_futex_wait(wanted_ns) };
        var line_buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "slept {d} {d}\n", .{ slept_ns[0], slept_ns[1] }) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
        for (slept_ns) |slept| {
            if (slept < wanted_ns * 8 / 10 or slept > wanted_ns + std.time.ns_per_s) linux.exit_group(1);
        }
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "ping")) {
        const address = std.Io.net.Ip4Address.parse(arguments[2], port) catch linux.exit_group(2);
        linux.exit_group(if (ping(address.bytes)) 0 else 1);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "write")) {
        synced_write(arguments[2], "written\n") catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "rebuild")) {
        // A log's way with a segment's index at recovery (reset, then its entries
        // appended): the existing file opened, truncated to 0 and written again
        // through the same descriptor, then synced (`synced`) or only closed (`closed`).
        const synced = std.mem.eql(u8, arguments[3], "synced");
        const fd = linux.open(arguments[2], .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) linux.exit_group(1);
        if (linux.errno(linux.ftruncate(@intCast(fd), 0)) != .SUCCESS) linux.exit_group(1);
        const content = "rebuilt\n";
        if (linux.pwrite(@intCast(fd), content, content.len, 0) != content.len) linux.exit_group(1);
        if (synced and linux.errno(linux.fsync(@intCast(fd))) != .SUCCESS) linux.exit_group(1);
        _ = linux.close(@intCast(fd));
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "fill")) {
        disk_fill(arguments[2]) catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "unsynced")) {
        const file = file_create(arguments[2], "lost in a power loss\n") catch linux.exit_group(1);
        _ = linux.close(file);
        linux.exit_group(0);
    }
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "rewrite")) {
        // The file rewritten in place `count` times (truncated, a page of one letter written,
        // never synced: os.WriteFile's way, a coordinator's status), another file written and
        // synced between rewrites (each fsync commits ext4's running transaction: the rewrites'
        // truncations and sizes in it).
        const count = std.fmt.parseInt(u32, arguments[3], 10) catch linux.exit_group(2);
        for (0..count) |index| {
            const content: [page_size]u8 = @splat(@as(u8, 'A') + @as(u8, @intCast(index % 26)));
            const fd = file_create(arguments[2], &content) catch linux.exit_group(1);
            _ = linux.close(fd);
            synced_write("/data/rewrite-commit", "commit\n") catch linux.exit_group(1);
        }
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "page-write")) {
        // A page of 'a', synced with its directory: on the disk, where a fault aimed at the file
        // finds it.
        const page: [page_size]u8 = @splat('a');
        const file = file_create(arguments[2], &page) catch linux.exit_group(1);
        const synced = linux.errno(linux.fsync(file)) == .SUCCESS;
        _ = linux.close(file);
        const directory = linux.open("/data", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(directory) == .SUCCESS) {
            _ = linux.fsync(@intCast(directory));
            _ = linux.close(@intCast(directory));
        }
        linux.exit_group(if (synced) 0 else 1);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "page-check")) {
        // The page read from the disk itself (O_DIRECT: not the page cache, where a corrupted
        // read never shows): "intact" (all 'a'), else "corrupt <bytes changed>".
        var page: [page_size]u8 align(page_size) = undefined;
        const fd = linux.open(@ptrCast(arguments[2].ptr), .{ .ACCMODE = .RDONLY, .DIRECT = true }, 0);
        if (linux.errno(fd) != .SUCCESS) linux.exit_group(1);
        const size = linux.read(@intCast(fd), &page, page.len);
        _ = linux.close(@intCast(fd));
        if (linux.errno(size) != .SUCCESS or size != page.len) linux.exit_group(1);
        var changed: u32 = 0;
        for (page) |byte| changed += @intFromBool(byte != 'a');
        var line: [32]u8 = undefined;
        const text = if (changed == 0) "intact\n" else std.fmt.bufPrint(&line, "corrupt {d}\n", .{changed}) catch linux.exit_group(1);
        _ = linux.write(1, text.ptr, text.len);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "rename-unsynced")) {
        // `<path>.tmp` written, never synced, renamed to `<path>`, and the process gone at once:
        // a script's `mv` (the guest's rename tracer finds the node by the path).
        rename_unsynced(arguments[2]) catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 5 and std.mem.eql(u8, arguments[1], "fail-loop")) {
        // A call failing `count` times, `pause_ms` apart: `open` a missing file (ENOENT), or
        // `close` a bad descriptor (EBADF). A tight retry loop, for errno_trace's storms.
        const count = std.fmt.parseInt(u32, arguments[3], 10) catch linux.exit_group(2);
        const pause_ms = std.fmt.parseInt(u32, arguments[4], 10) catch linux.exit_group(2);
        const open = std.mem.eql(u8, arguments[2], "open");
        for (0..count) |_| {
            if (open) {
                const fd = linux.open("/data/never-there", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
                if (linux.errno(fd) == .SUCCESS) _ = linux.close(@intCast(fd));
            } else _ = linux.close(-1);
            if (pause_ms > 0) {
                const request = linux.timespec{ .sec = @intCast(pause_ms / 1000), .nsec = @intCast(@as(u64, pause_ms % 1000) * std.time.ns_per_ms) };
                _ = linux.nanosleep(&request, null);
            }
        }
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "record")) {
        // A temporary directories' record: the file removed (a start's cleanup),
        // created again and a line appended, never synced; then another file written and synced
        // (a storage engine's WAL: ext4's running transaction committed).
        _ = linux.unlink(arguments[2]);
        const fd = linux.open(arguments[2], .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) linux.exit_group(1);
        const written = linux.write(@intCast(fd), record_line.ptr, record_line.len);
        _ = linux.close(@intCast(fd));
        if (linux.errno(written) != .SUCCESS or written != record_line.len) linux.exit_group(1);
        synced_write("/data/record-commit", "commit\n") catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "conf")) {
        // A cluster's node table: `<path>.tmp` written (755 bytes), renamed over `<path>`, never
        // synced (auto_da_alloc starts its writeback); then another file written and synced.
        var temp_buffer: [256]u8 = undefined;
        const temp = std.fmt.bufPrintSentinel(&temp_buffer, "{s}.tmp", .{arguments[2]}, 0) catch linux.exit_group(2);
        const fd = file_create(temp, conf_content[0..]) catch linux.exit_group(1);
        _ = linux.close(fd);
        if (linux.errno(linux.rename(temp, arguments[2])) != .SUCCESS) linux.exit_group(1);
        synced_write("/data/record-commit", "commit\n") catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "conf-read")) {
        // The conf file after a power loss: absent, empty, whole, zeros (NUL bytes only) or torn.
        const fd = linux.open(arguments[2], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            _ = linux.write(1, "absent\n", 7);
            linux.exit_group(0);
        }
        var content: [1024]u8 = undefined;
        const read = linux.read(@intCast(fd), &content, content.len);
        _ = linux.close(@intCast(fd));
        if (linux.errno(read) != .SUCCESS) linux.exit_group(1);
        const bytes = content[0..read];
        const kind: []const u8 = if (bytes.len == 0) "empty\n" else if (std.mem.allEqual(u8, bytes, 0)) "zeros\n" else if (std.mem.eql(u8, bytes, conf_content[0..])) "whole\n" else "torn\n";
        _ = linux.write(1, kind.ptr, kind.len);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "record-read")) {
        // What the record came back as: absent, empty, whole (the line), zeros (its size without
        // its bytes) or torn: printed, exit 0.
        const fd = linux.open(arguments[2], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            _ = linux.write(1, "absent\n", 7);
            linux.exit_group(0);
        }
        var content: [256]u8 = undefined;
        const read = linux.read(@intCast(fd), &content, content.len);
        _ = linux.close(@intCast(fd));
        if (linux.errno(read) != .SUCCESS) linux.exit_group(1);
        const bytes = content[0..read];
        const kind: []const u8 = if (bytes.len == 0)
            "empty\n"
        else if (std.mem.allEqual(u8, bytes, 0))
            "zeros\n"
        else if (std.mem.eql(u8, bytes, record_line))
            "whole\n"
        else
            "torn\n";
        _ = linux.write(1, kind.ptr, kind.len);
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "rewrite-read")) {
        // What a rewritten file came back as: absent, empty, whole (one letter throughout), or
        // zeros (a size kept without its data) or torn (letters mixed): printed, exit 0.
        const fd = linux.open(arguments[2], .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            _ = linux.write(1, "absent\n", 7);
            linux.exit_group(0);
        }
        var content: [page_size * 2]u8 = undefined;
        const read = linux.read(@intCast(fd), &content, content.len);
        if (linux.errno(read) != .SUCCESS) linux.exit_group(1);
        const bytes = content[0..read];
        const kind: []const u8 = if (bytes.len == 0)
            "empty\n"
        else if (std.mem.allEqual(u8, bytes, 0))
            "zeros\n"
        else if (bytes.len == page_size and std.mem.allEqual(u8, bytes, bytes[0]) and bytes[0] >= 'A' and bytes[0] <= 'Z')
            "whole\n"
        else
            "torn\n";
        _ = linux.write(1, kind.ptr, kind.len);
        linux.exit_group(0);
    }
    if (arguments.len == 5 and std.mem.eql(u8, arguments[1], "pages")) {
        // `files` files of `pages` 4 KiB pages under a directory, each page its own marker byte,
        // none synced (the directory synced, so the files' names are there after a power loss).
        const files = std.fmt.parseInt(u32, arguments[3], 10) catch linux.exit_group(2);
        const pages = std.fmt.parseInt(u32, arguments[4], 10) catch linux.exit_group(2);
        _ = linux.mkdir(arguments[2], 0o755);
        // Whether each file was there before, and its delayed pages just after its close.
        var existed: [64]u8 = @splat('-');
        var at_close: [64]u8 = @splat('-');
        for (0..files) |file| {
            var path_buffer: [256]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/p{d}", .{ arguments[2], file }, 0) catch linux.exit_group(2);
            if (file < existed.len) existed[file] = if (linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS) 'y' else 'n';
            const fd = file_create(path, "") catch linux.exit_group(1);
            for (0..pages) |page| {
                const content: [page_size]u8 = @splat(page_marker(@intCast(file), @intCast(page)));
                if (linux.write(fd, &content, content.len) != content.len) linux.exit_group(1);
            }
            _ = linux.close(fd);
            const look = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(look) == .SUCCESS) {
                if (file < at_close.len) at_close[file] = '0' + @as(u8, @intCast(@min(delayed_pages(@intCast(look)), 9)));
                _ = linux.close(@intCast(look));
            }
        }
        var before_buffer: [192]u8 = undefined;
        const before = std.fmt.bufPrint(&before_buffer, "existed {s} at-close {s}\n", .{ existed[0..@min(files, existed.len)], at_close[0..@min(files, at_close.len)] }) catch "";
        _ = linux.write(1, before.ptr, before.len);
        const directory = linux.open(arguments[2], .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(directory) != .SUCCESS) linux.exit_group(1);
        _ = linux.fsync(@intCast(directory));
        // How many of the pages are still new (delayed allocation, FIEMAP), the directory synced:
        // what a power loss now has to keep or lose.
        var delayed: u64 = 0;
        var each: [64]u8 = undefined;
        for (0..files) |file| {
            var path_buffer: [256]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/p{d}", .{ arguments[2], file }, 0) catch linux.exit_group(2);
            const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(fd) != .SUCCESS) continue;
            defer _ = linux.close(@intCast(fd));
            const here = delayed_pages(@intCast(fd));
            delayed += here;
            if (file < each.len) each[file] = '0' + @as(u8, @intCast(@min(here, 9)));
        }
        var line_buffer: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "delayed {d} each {s}\n", .{ delayed, each[0..@min(files, each.len)] }) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
        linux.exit_group(0);
    }
    if (arguments.len == 5 and std.mem.eql(u8, arguments[1], "pages-read")) {
        // Of those pages, how many have their marker after a power loss, how many not, and how
        // many of the lost come before a kept page of their file (a hole: a fresh file's pages
        // go back in ascending order, so none).
        const files = std.fmt.parseInt(u32, arguments[3], 10) catch linux.exit_group(2);
        const pages = std.fmt.parseInt(u32, arguments[4], 10) catch linux.exit_group(2);
        var intact: u32 = 0;
        var lost: u32 = 0;
        var holes: u32 = 0;
        for (0..files) |file| {
            var lost_here: u32 = 0;
            var path_buffer: [256]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/p{d}", .{ arguments[2], file }, 0) catch linux.exit_group(2);
            const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
            for (0..pages) |page| {
                var content: [page_size]u8 = undefined;
                const read = if (linux.errno(fd) == .SUCCESS) linux.pread(@intCast(fd), &content, content.len, @intCast(page * page_size)) else 0;
                const marker = page_marker(@intCast(file), @intCast(page));
                const whole = read == content.len and std.mem.allEqual(u8, &content, marker);
                if (whole) {
                    intact += 1;
                    holes += lost_here;
                    lost_here = 0;
                } else {
                    lost += 1;
                    lost_here += 1;
                }
            }
            if (linux.errno(fd) == .SUCCESS) _ = linux.close(@intCast(fd));
        }
        var line_buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "intact {d} lost {d} holes {d}\n", .{ intact, lost, holes }) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
        linux.exit_group(0);
    }
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "write2")) {
        // Both written first, then synced together: the two syncs reach the guest module at
        // once, before the first one's crash freezes the node.
        const first = try file_create(arguments[2], "written\n");
        const second = try file_create(arguments[3], "written\n");
        const other = try std.Thread.spawn(.{}, fsync_at_start, .{second});
        while (!started.load(.acquire)) {}
        _ = linux.fsync(first);
        other.join();
        linux.exit_group(0);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "race")) {
        const rounds = std.fmt.parseInt(u32, arguments[2], 10) catch linux.exit_group(2);
        var line_buffer: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "early {d}\n", .{race(rounds)}) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
        linux.exit_group(0);
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "custom-fault")) {
        const stop_faults = init.environ_map.get("ANTITHESIS_STOP_FAULTS") orelse "";
        const draw = sdk.random_below(1000);
        sdk.event("custom_fault_ran", .{ .draw = draw, .stop_faults = stop_faults });
        return;
    }
    mutant = init.environ_map.get("DET_MUTANT") != null;
    // A hangup ends the service as Go's runtime ends a program: a handler that exits (the
    // namespace's init ignores a default-action SIGHUP the kernel sends; Go's handler, there,
    // exits 2). What the "hangup" scenario's stopped node must never meet.
    const hangup: linux.Sigaction = .{
        .handler = .{ .handler = on_hangup },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.HUP, &hangup, null);
    // A handler without SA_RESTART: a signal it catches interrupts a blocked accept (EINTR),
    // which the "signal" scenario's fault must make happen (Faults.signals).
    const interruptible = init.environ_map.get("DET_INTERRUPTIBLE") != null;
    if (interruptible) {
        const urgent: linux.Sigaction = .{
            .handler = .{ .handler = on_urgent },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(.URG, &urgent, null);
    }
    if (init.environ_map.get("DET_DURABLE") != null) try durable_write();
    if (init.environ_map.get("DET_QUEUE") != null) _ = try std.Thread.spawn(.{}, queue_service, .{});
    if (init.environ_map.get("DET_CRASH_POINT") != null) _ = try std.Thread.spawn(.{}, crash_point_loop, .{});
    if (init.environ_map.get("DET_WORKERS")) |text| {
        const workers = try std.fmt.parseInt(u32, text, 10);
        for (0..workers) |_| worker_start();
        _ = try std.Thread.spawn(.{}, supervise, .{});
    }
    const listener = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listener) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(listener);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const address = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Bind;
    }
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.Listen;
    for (0..connections_max) |_| {
        const client = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(client) == .INTR) {
            marker_create("/tmp/eintr");
            continue;
        }
        // Out of descriptors (the "syscall_error" scenario's fault): backed off, as servers do.
        if (linux.errno(client) == .MFILE) {
            marker_create("/tmp/emfile");
            const backoff: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = linux.nanosleep(&backoff, null);
            continue;
        }
        if (linux.errno(client) != .SUCCESS) continue;
        defer _ = linux.close(@intCast(client));
        selftest_accepted += 1;
        selftest_stats.accepted += 1;
        selftest_stats.last_client = @intCast(client);
        selftest_stats.ratio = @as(f64, @floatFromInt(selftest_stats.accepted)) / 2.0;
        @call(.never_inline, selftest_record, .{ selftest_stats.ratio, @as(i32, @intCast(client)) });
        @call(.never_inline, selftest_serve, .{@as(i32, @intCast(client))});
    }
}

/// The connections this server accepted: a variable with a known course, watched by its name
/// from a session (e2e debugging: det-nodes symbol, det:watch). Exported, so kept whole.
export var selftest_accepted: u64 = 0;

/// The same as a structure whose fields a session reads by their paths (e2e debugging:
/// det-nodes symbol --field): the count, the last client's descriptor, half the count.
const Stats = extern struct { accepted: u64, last_client: i32, ratio: f64 };
export var selftest_stats: Stats = .{ .accepted = 0, .last_client = -1, .ratio = 0 };

/// A connection served: a function by its name with an argument in C's convention (the REPL's
/// `calls`: its client descriptor in rdi at each call).
export fn selftest_serve(client: i32) callconv(.c) void {
    serve(client);
}

/// A float argument before an integer one (the REPL's `calls` by DWARF: ratio in xmm0, client in
/// rdi, the float not taking an integer register).
export fn selftest_record(ratio: f64, client: i32) callconv(.c) void {
    selftest_recorded = if (client >= 0) ratio else -1;
}
export var selftest_recorded: f64 = 0;

fn on_urgent(_: linux.SIG) callconv(.c) void {}

// The toy service of Peter Alvaro's talk (docs/ANTITHESIS_EXPLORATION.md, M): one worker serving
// a request a second from a queue of 10, a request refused ("busy") when it is full, and a
// request whose client gave up served all the same (the wasted work a metastable failure lives
// on). With DET_QUEUE, on port 7100.
pub const queue_port = 7100;
const queue_capacity = 10;
var queue_fds: [queue_capacity]linux.fd_t = undefined;
var queue_head: usize = 0;
var queue_count: usize = 0;
var queue_lock: std.atomic.Mutex = .unlocked;

fn queue_lock_take() void {
    while (!queue_lock.tryLock()) sleep_ms(1);
}

fn sleep_ms(ms: u64) void {
    const pause: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}

fn queue_service() void {
    _ = std.Thread.spawn(.{}, queue_worker, .{}) catch return;
    const listener = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listener) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(listener);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const address = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, queue_port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return;
    if (linux.errno(linux.listen(fd, 256)) != .SUCCESS) return;
    while (true) {
        const accepted = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) continue;
        const client: linux.fd_t = @intCast(accepted);
        var line: [16]u8 = undefined;
        _ = linux.read(client, &line, line.len); // "work"
        queue_lock_take();
        if (queue_count == queue_capacity) {
            queue_lock.unlock();
            _ = linux.write(client, "busy\n", 5);
            _ = linux.close(client);
            continue;
        }
        queue_fds[(queue_head + queue_count) % queue_capacity] = client;
        queue_count += 1;
        queue_lock.unlock();
    }
}

fn queue_worker() void {
    while (true) {
        queue_lock_take();
        if (queue_count == 0) {
            queue_lock.unlock();
            sleep_ms(10);
            continue;
        }
        const client = queue_fds[queue_head];
        queue_head = (queue_head + 1) % queue_capacity;
        queue_count -= 1;
        queue_lock.unlock();
        sleep_ms(1000); // The service: one request a second.
        _ = linux.write(client, "done\n", 5); // Its client may have given up: work wasted.
        _ = linux.close(client);
    }
}

fn marker_create(path: [*:0]const u8) void {
    const marker = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(marker) == .SUCCESS) _ = linux.close(@intCast(marker));
}

/// On a first start (no /data/synced yet): one file synced, one not. Restarts leave them be, and
/// read the unsynced one back, as a system reads its state at a start (after a kill it still holds
/// data never synced: the persistence audit's node_open_unsynced).
fn durable_write() !void {
    if (linux.errno(linux.access("/data/synced", linux.F_OK)) == .SUCCESS) {
        // And /data/relied, a command's write the "disk" scenario makes before a restart.
        for ([_][*:0]const u8{ "/data/unsynced", "/data/relied" }) |path| {
            const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(fd) != .SUCCESS) continue; // Lost in a power loss, or never written.
            var buffer: [64]u8 = undefined;
            _ = linux.read(@intCast(fd), &buffer, buffer.len);
            _ = linux.close(@intCast(fd));
        }
        return;
    }
    _ = linux.mkdir("/data", 0o755);
    try synced_write("/data/synced", "kept\n");
    const unsynced = try file_create("/data/unsynced", "lost in a crash\n");
    _ = linux.close(unsynced);
    // Written under a temporary name, never synced, renamed into place: the update ALICE found
    // most often unsafe, which the guest's rename tracer reports (node_rename_unsynced).
    try rename_unsynced("/data/renamed");
}

/// `<path>.tmp` written and never synced, then renamed to `<path>`.
fn rename_unsynced(path: []const u8) !void {
    var temporary_buffer: [256]u8 = undefined;
    var final_buffer: [256]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&temporary_buffer, "{s}.tmp", .{path}, 0);
    const final = try std.fmt.bufPrintSentinel(&final_buffer, "{s}", .{path}, 0);
    const file = try file_create(temporary, "renamed, never synced\n");
    _ = linux.close(file);
    if (linux.errno(linux.rename(temporary, final)) != .SUCCESS) return error.Rename;
}

/// The file written and synced, then its directory (/data) synced: durable once it returns.
/// A cluster's node table, 755 bytes of its lines.
const conf_content: [755]u8 = blk: {
    const line = "e7c1a2b3 10.0.0.2:6379@16379 myself,master - 0 0 1 connected 0-5460\n";
    var bytes: [755]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = line[index % line.len];
    break :blk bytes;
};

/// A temporary directories' record line: 51 bytes.
const record_line = "/datastore/datastore-data/datastore-temp2237603885\n";

fn synced_write(path: [*:0]const u8, content: []const u8) !void {
    const file = try file_create(path, content);
    defer _ = linux.close(file);
    if (linux.errno(linux.fsync(file)) != .SUCCESS) return error.Fsync;
    const directory = linux.open("/data", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(directory) != .SUCCESS) return error.Open;
    defer _ = linux.close(@intCast(directory));
    if (linux.errno(linux.fsync(@intCast(directory))) != .SUCCESS) return error.Fsync;
}

var started: std.atomic.Value(bool) = .init(false);

/// The race: the round the waker announced, the round the woken thread finished, and the round
/// whose next step the waker took.
var race_round: std.atomic.Value(u32) = .init(0);
var race_done: std.atomic.Value(u32) = .init(0);
var race_stepped: std.atomic.Value(u32) = .init(0);
var race_early: u32 = 0;

/// `rounds` times, the waker announces a round, wakes the other thread and takes its next step;
/// the woken one notes whether it ran before that step. The woken one is a batch thread
/// (SCHED_BATCH), which the kernel alone never lets preempt at its wakeup (a normal one does, two
/// times in five here): under the `interleave` fault, it runs first whenever the draw says so.
fn race(rounds: u32) u32 {
    const woken = std.Thread.spawn(.{}, race_woken, .{rounds}) catch linux.exit_group(1);
    for (1..rounds + 1) |round_index| {
        const round: u32 = @intCast(round_index);
        race_round.store(round, .release);
        futex_wake(&race_round);
        race_stepped.store(round, .release);
        while (race_done.load(.acquire) != round) futex_wait(&race_done, round - 1);
    }
    woken.join();
    return race_early;
}

fn race_woken(rounds: u32) void {
    const sched_batch = 3;
    const parameters: i32 = 0; // struct sched_param: its priority, 0 for batch threads.
    _ = linux.syscall3(.sched_setscheduler, 0, sched_batch, @intFromPtr(&parameters));
    for (1..rounds + 1) |round_index| {
        const round: u32 = @intCast(round_index);
        while (race_round.load(.acquire) != round) futex_wait(&race_round, round - 1);
        if (race_stepped.load(.acquire) != round) race_early += 1;
        race_done.store(round, .release);
        futex_wake(&race_done);
    }
}

const futex_private = 128;

/// Sleeps while `word` holds `value` (or returns at once if it no longer does).
fn futex_wait(word: *const std.atomic.Value(u32), value: u32) void {
    _ = linux.syscall4(.futex, @intFromPtr(&word.raw), futex_private | 0, value, 0);
}

fn futex_wake(word: *const std.atomic.Value(u32)) void {
    _ = linux.syscall3(.futex, @intFromPtr(&word.raw), futex_private | 1, 1);
}

fn fsync_at_start(fd: linux.fd_t) void {
    started.store(true, .release);
    _ = linux.fsync(fd);
}

const page_size = 4096;

/// A page's own byte (never 0: a hole or a lost page reads as zeros).
fn page_marker(file: u32, page: u32) u8 {
    return @intCast(1 + (file * 31 + page * 7) % 250);
}

/// A file's pages under delayed allocation (FIEMAP's DELALLOC extents, FS_IOC_FIEMAP without
/// FIEMAP_FLAG_SYNC): written, their blocks not allocated yet.
fn delayed_pages(fd: linux.fd_t) u64 {
    const Extent = extern struct { logical: u64, physical: u64, length: u64, reserved64: [2]u64, flags: u32, reserved: [3]u32 };
    const Map = extern struct { start: u64, length: u64, flags: u32, mapped: u32, count: u32, reserved: u32, extents: [16]Extent };
    var map: Map = .{ .start = 0, .length = std.math.maxInt(u64), .flags = 0, .mapped = 0, .count = 16, .reserved = 0, .extents = undefined };
    if (linux.errno(linux.ioctl(fd, 0xC020_660B, @intFromPtr(&map))) != .SUCCESS) return 0;
    var pages: u64 = 0;
    for (map.extents[0..@min(map.mapped, 16)]) |extent| {
        if (extent.flags & 0x4 != 0) pages += (extent.length + page_size - 1) / page_size;
    }
    return pages;
}

/// The disk filled as a node's data fills it: files until no inode is left, then blocks
/// (allocated, not written: the disk's image is the guest's memory) until none is left, all
/// synced. An error unless both ran out.
fn disk_fill(directory: [*:0]const u8) !void {
    var path: [256]u8 = undefined;
    if (linux.errno(linux.mkdir(directory, 0o755)) != .SUCCESS) return error.Mkdir;
    var inodes_out = false;
    var subdirectory: u32 = 0;
    while (!inodes_out) : (subdirectory += 1) {
        const sub = std.fmt.bufPrintSentinel(&path, "{s}/{d}", .{ directory, subdirectory }, 0) catch unreachable;
        const made = linux.mkdir(sub, 0o755);
        if (linux.errno(made) == .NOSPC) break;
        if (linux.errno(made) != .SUCCESS) return error.Mkdir;
        for (0..1000) |index| {
            const file = std.fmt.bufPrintSentinel(&path, "{s}/{d}/{d}", .{ directory, subdirectory, index }, 0) catch unreachable;
            const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
            if (linux.errno(fd) == .NOSPC) {
                inodes_out = true;
                break;
            }
            if (linux.errno(fd) != .SUCCESS) return error.Open;
            _ = linux.close(@intCast(fd));
        }
    }
    // The blocks: in a file that took an inode before they ran out, else none is left for it.
    const blocks = std.fmt.bufPrintSentinel(&path, "{s}/0/0", .{directory}, 0) catch unreachable;
    const fd = linux.open(blocks, .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Open;
    defer _ = linux.close(@intCast(fd));
    var offset: i64 = 0;
    var chunk: i64 = 64 << 20;
    while (chunk >= 4096) {
        const result = linux.fallocate(@intCast(fd), 0, offset, chunk);
        if (linux.errno(result) == .SUCCESS) {
            offset += chunk;
        } else if (linux.errno(result) == .NOSPC) {
            chunk = @divExact(chunk, 2);
        } else return error.Fallocate;
    }
    linux.sync();
    if (!inodes_out) return error.InodesLeft;
}

fn file_create(path: [*:0]const u8, content: []const u8) !linux.fd_t {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.Open;
    const written = linux.write(@intCast(fd), content.ptr, content.len);
    if (linux.errno(written) != .SUCCESS or written != content.len) return error.Write;
    return @intCast(fd);
}

fn worker_start() void {
    const pid = linux.fork();
    if (pid == 0) {
        while (true) _ = linux.pause(); // A worker: here to be killed.
    }
}

/// Replaces every worker that dies.
fn supervise() void {
    while (true) {
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return; // No children left.
        sdk.reachable("a killed worker is replaced", .{});
        worker_start();
    }
}

/// A write through an invalid pointer: SIGSEGV, which the kernel logs as a segfault.
/// SIGTERM's handler after "crash-on-stop": the known exit's text, then a crash with no core
/// (a Galera joiner's abort after "need to abort", the stop's SIGTERM already sent).
fn crash_on_stop(_: linux.SIG) callconv(.c) void {
    const said = "crashing as told\n";
    _ = linux.write(2, said, said.len);
    const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Its output forwarded first, as a real one's.
    const set_dumpable = 4; // PR_SET_DUMPABLE
    _ = linux.prctl(set_dumpable, 0, 0, 0, 0);
    crash();
}

/// SIGTERM's handler after "exit-on-stop": an exit code of its own (2, as a Go program that was
/// PID 1 when the signal came: gosu in PostgreSQL's entrypoint).
fn exit_on_stop(_: linux.SIG) callconv(.c) void {
    linux.exit_group(2);
}

fn crash() noreturn {
    const address: usize = 8;
    const target: *volatile u8 = @ptrFromInt(address);
    target.* = 1;
    unreachable;
}

fn hog() !void {
    for (0..hog_chunks_max) |_| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const address = linux.mmap(null, hog_chunk_size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < hog_chunk_size) : (offset += 4096) memory[offset] = 1;
    }
    return error.NotKilled; // 4 GiB touched and still alive: no limit applied.
}

/// A slow leak (e2e memory-growth): 4 MiB touched every 200 ms, 400 MiB in all, never freed,
/// then idle: no OOM within the guest, only memory that grows.
fn leak() !void {
    for (0..100) |_| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const size = 4 << 20;
        const address = linux.mmap(null, size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < size) : (offset += 4096) memory[offset] = 1;
        const pause: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    const idle: linux.timespec = .{ .sec = 10, .nsec = 0 };
    _ = linux.nanosleep(&idle, null);
}

fn serve(client: linux.fd_t) void {
    assert(client >= 0);
    var buffer: [256]u8 = undefined;
    const size = linux.read(client, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS or size == 0) return;
    const line = std.mem.trim(u8, buffer[0..size], "\r\n");
    // `leak <MiB>`: that much memory touched in this server's process and kept for good (e2e
    // memory-climb: a leak each timeline adds to, past the node's limit only where the tree
    // returns to the leakiest).
    if (std.mem.startsWith(u8, line, "leak ")) {
        const mib = std.fmt.parseInt(usize, line["leak ".len..], 10) catch return;
        if (mib > 0) {
            const bytes = mib << 20;
            const address = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            if (linux.errno(address) != .SUCCESS) return;
            const memory: [*]u8 = @ptrFromInt(address);
            var offset: usize = 0;
            while (offset < bytes) : (offset += 4096) memory[offset] = 1;
        }
        const said = "leaked\n";
        _ = linux.write(client, said, said.len);
        return;
    }
    if (std.mem.eql(u8, line, "die")) {
        const said = "dying as told\n";
        _ = linux.write(2, said, said.len);
        linux.exit_group(3);
    }
    // An exit nothing declares known (node_exit_again: after a known one, in the same log).
    if (std.mem.eql(u8, line, "leave")) {
        const said = "leaving unannounced\n";
        _ = linux.write(2, said, said.len);
        linux.exit_group(4);
    }
    // The same exit after its output went where a daemon's goes (node_supervised_quiet): its
    // forwarder sees both streams end half a second before it.
    if (std.mem.eql(u8, line, "leave-quietly")) {
        const quiet = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(quiet) != .SUCCESS) return;
        _ = linux.dup2(@intCast(quiet), 1);
        _ = linux.dup2(@intCast(quiet), 2);
        const request = linux.timespec{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
        _ = linux.nanosleep(&request, null);
        linux.exit_group(5);
    }
    // A graceful stop's SIGTERM then makes it crash after saying so (node_crash_stopping): the
    // stop takes the node's pidfile first, the crash comes after.
    if (std.mem.eql(u8, line, "exit-on-stop")) {
        const action: linux.Sigaction = .{ .handler = .{ .handler = exit_on_stop }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.TERM, &action, null);
        const said = "armed\n";
        _ = linux.write(client, said, said.len);
        return;
    }
    if (std.mem.eql(u8, line, "crash-on-stop")) {
        const action: linux.Sigaction = .{ .handler = .{ .handler = crash_on_stop }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.TERM, &action, null);
        const said = "armed\n";
        _ = linux.write(client, said, said.len);
        return;
    }
    // The node itself crashes, after saying so (Galera's abort after "need to abort"); with
    // "crash-nodump" it dumps no core (mariadbd crashing as it exits): only the kernel's line.
    if (std.mem.eql(u8, line, "crash") or std.mem.eql(u8, line, "crash-nodump")) {
        const said = "crashing as told\n";
        _ = linux.write(2, said, said.len);
        const pause = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null); // Its output forwarded first, as a real one's.
        if (std.mem.eql(u8, line, "crash-nodump")) {
            const set_dumpable = 4; // PR_SET_DUMPABLE
            _ = linux.prctl(set_dumpable, 0, 0, 0, 0);
        }
        crash();
    }
    // The node reads a mapped page of /data/mapped from the disk (its clean page evicted first),
    // dumping no core, as ParticleDB does: under a disk fault failing that file's reads the
    // kernel's answer is a SIGBUS. "mmap-truncated": the file truncated under the mapping first,
    // a SIGBUS with a healthy disk (a program's own bug). Answers "read" if it survives.
    if (std.mem.eql(u8, line, "mmap-read") or std.mem.eql(u8, line, "mmap-truncated")) {
        const set_dumpable = 4; // PR_SET_DUMPABLE
        _ = linux.prctl(set_dumpable, 0, 0, 0, 0);
        // The kernel's own SIGBUS, as a Rust or C program dies of it: Zig's crash handler would
        // catch it and end the process with SIGSEGV (status 139, the first try of this case).
        const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.BUS, &default, null);
        var answer: []const u8 = "unopened\n";
        const fd = linux.open("/data/mapped", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(fd) == .SUCCESS) {
            answer = "unmapped\n";
            const dont_need = 4; // POSIX_FADV_DONTNEED: the clean page dropped from the cache.
            _ = linux.fadvise(@intCast(fd), 0, 0, dont_need);
            const mapped = linux.mmap(null, page_size, .{ .READ = true }, .{ .TYPE = .SHARED }, @intCast(fd), 0);
            if (linux.errno(mapped) == .SUCCESS) {
                if (std.mem.eql(u8, line, "mmap-truncated")) _ = linux.ftruncate(@intCast(fd), 0);
                const byte: *const volatile u8 = @ptrFromInt(mapped);
                // Its value answered: the load cannot be left out. A SIGBUS here when the page
                // cannot be read.
                answer = if (byte.* == 'a') "read a\n" else "read other\n";
            }
            _ = linux.close(@intCast(fd));
        }
        _ = linux.write(client, answer.ptr, answer.len);
        return;
    }
    // A Go-style panic's lines, the node going on (the language property is the output's): its
    // stack names main.told, known in the known-exit profile, or main.elsewhere, which nothing
    // declares.
    if (std.mem.eql(u8, line, "panic") or std.mem.eql(u8, line, "panic-other")) {
        const frame = if (std.mem.eql(u8, line, "panic")) "main.told(0x0)\n" else "main.elsewhere(0x0)\n";
        const said = "panic: runtime error: invalid memory address or nil pointer dereference\n\n" ++
            "goroutine 1 [running]:\n";
        _ = linux.write(2, said, said.len);
        _ = linux.write(2, frame.ptr, frame.len);
    }
    // A panic the program survived, logged as a system does (TiDB's "panic in the recoverable
    // goroutine"), at a site the known-exit profile declares known or at another: its log
    // failures (schema.Node.log_failures), not a language property (mid-line, nothing ended).
    if (std.mem.eql(u8, line, "logfail") or std.mem.eql(u8, line, "logfail-known")) {
        const said = if (std.mem.eql(u8, line, "logfail"))
            "[ERROR] [\"panic in the recoverable goroutine\"] [stack=\"main.site_other\"]\n"
        else
            "[ERROR] [\"panic in the recoverable goroutine\"] [stack=\"main.site_known\"]\n";
        _ = linux.write(2, said, said.len);
    }
    // A line appended to a file on its disk, or one read: "ok", or the error's name (the
    // "file_error" scenario's faults).
    if (std.mem.eql(u8, line, "append") or std.mem.eql(u8, line, "read")) {
        const result = if (std.mem.eql(u8, line, "append")) disk_append() else disk_read();
        var answer_buffer: [32]u8 = undefined;
        const said = switch (result) {
            .done => "ok",
            .short => "short",
            .failed => |errno| @tagName(errno),
        };
        const answer = std.fmt.bufPrint(&answer_buffer, "{s}\n", .{said}) catch unreachable;
        _ = linux.write(client, answer.ptr, answer.len); // One write: the client reads one answer.
        return;
    }
    if (mutant) {
        for (buffer[0..size]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    }
    _ = linux.write(client, buffer[0..size].ptr, size);
}

const DiskResult = union(enum) { done, short, failed: linux.E };

/// A line of 16 bytes appended in one write: done, short (fewer bytes written), or failed.
fn disk_append() DiskResult {
    const fd = linux.open("/data/appended", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return .{ .failed = linux.errno(fd) };
    defer _ = linux.close(@intCast(fd));
    const line = "xxxxxxxxxxxxxxx\n";
    const written = linux.write(@intCast(fd), line, line.len);
    if (linux.errno(written) != .SUCCESS) return .{ .failed = linux.errno(written) };
    return if (written < line.len) .short else .done;
}

fn disk_read() DiskResult {
    const fd = linux.open("/data/appended", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return .{ .failed = linux.errno(fd) };
    defer _ = linux.close(@intCast(fd));
    var buffer: [64]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return .{ .failed = linux.errno(size) };
    return .done;
}

/// Whether the service at `address` answers "ping" within a second.
fn ping(address: [4]u8) bool {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    const option = std.mem.asBytes(&timeout);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, option.ptr, option.len);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, option.ptr, option.len);
    const target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(address) };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return false;
    }
    _ = linux.write(fd, "ping\n", 5);
    var reply: [16]u8 = undefined;
    const size = linux.read(fd, &reply, reply.len);
    if (linux.errno(size) != .SUCCESS) return false;
    return std.mem.eql(u8, reply[0..size], "ping\n");
}

fn clock_ns(clock: linux.clockid_t) i128 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(clock, &now);
    return @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
}

fn timespec_of(ns: i128) linux.timespec {
    return .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
}

/// Sleeps until CLOCK_REALTIME's now + `wanted_ns` (an absolute deadline); how long that took
/// on the monotonic clock.
fn abs_nanosleep(wanted_ns: u64) u64 {
    const start = clock_ns(.MONOTONIC);
    const deadline = timespec_of(clock_ns(.REALTIME) + wanted_ns);
    while (true) {
        const result = linux.clock_nanosleep(.REALTIME, .{ .ABSTIME = true }, &deadline, null);
        if (linux.errno(result) != .INTR) break;
    }
    return @intCast(clock_ns(.MONOTONIC) - start);
}

/// A futex wait nothing wakes, until CLOCK_REALTIME's now + `wanted_ns` (FUTEX_WAIT_BITSET
/// with FUTEX_CLOCK_REALTIME: pthread_cond_timedwait's); how long it took on the monotonic clock.
fn abs_futex_wait(wanted_ns: u64) u64 {
    var word: u32 = 0;
    const start = clock_ns(.MONOTONIC);
    const deadline = timespec_of(clock_ns(.REALTIME) + wanted_ns);
    const wait_bitset = 9;
    const clock_realtime = 256;
    while (true) {
        const result = linux.syscall6(.futex, @intFromPtr(&word), wait_bitset | clock_realtime, 0, @intFromPtr(&deadline), 0, 0xffff_ffff);
        if (linux.errno(result) != .INTR and linux.errno(result) != .AGAIN) break;
    }
    return @intCast(clock_ns(.MONOTONIC) - start);
}
