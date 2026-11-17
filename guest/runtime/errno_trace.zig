// SPDX-License-Identifier: MIT
//! Syscall errors traced (explore's --trace-errno, det.trace_errno= on the guest's command line):
//! armed by det-init before the nodes start, so a node that dies starting is traced too.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

/// det.trace_errno=<n> (explore's --trace-errno): every system call that returns -<n>, in any
/// process of the guest, becomes a `syscall_error` event, from the composer's start to the
/// timeline's end (the kernel's raw_syscalls:sys_exit tracepoint, filtered; a child reads its
/// pipe). The failing call of a race recorded as it happens: a replay with a command at its
/// moment makes another timeline, where the race may not come (an eacces, run 401).
pub fn start() void {
    // 0: every error, but those a busy program returns all the time (EAGAIN, EINTR, ETIMEDOUT):
    // what failed, when that is the question (a node dying 1 s into its start, before a tape).
    const errno = cmdline_number("det.trace_errno=") orelse return;
    const root = "/sys/kernel/tracing";
    _ = linux.mount("none", root, "tracefs", 0, 0); // Mounted already, or now.
    var filter_buffer: [32]u8 = undefined;
    const filter = if (errno == 0)
        "ret < 0 && ret > -4096 && ret != -11 && ret != -4 && ret != -110\n"
    else
        std.fmt.bufPrint(&filter_buffer, "ret == -{d}\n", .{errno}) catch return;
    const armed = file_write(root ++ "/events/raw_syscalls/sys_exit/filter", filter) and
        file_write(root ++ "/events/raw_syscalls/sys_exit/enable", "1\n") and
        file_write(root ++ "/tracing_on", "1\n");
    if (!armed) {
        sdk.event("syscall_trace_failed", .{ .errno = errno });
        return;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS or pid != 0) return;
    // The child: gone with the composer.
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    const fd = linux.open(root ++ "/trace_pipe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) linux.exit(1);
    var buffer: [8192]u8 = undefined;
    var kept: usize = 0;
    var storms: Storms = .{};
    while (true) {
        const size = linux.read(@intCast(fd), buffer[kept..].ptr, buffer.len - kept);
        if (linux.errno(size) != .SUCCESS or size == 0) linux.exit(0);
        kept += size;
        var from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..kept], from, '\n')) |end| : (from = end + 1) {
            if (errno_line(buffer[from..end])) |hit| {
                switch (storms.note(hit.task, hit.nr, hit.errno, hit.at_us)) {
                    .event => sdk.event("syscall_error", .{ .task = hit.task, .nr = hit.nr, .errno = hit.errno }),
                    .storm => sdk.event("syscall_error_storm", .{
                        .task = hit.task,
                        .nr = hit.nr,
                        .errno = hit.errno,
                        .count = storm_count,
                        .within_ms = storm_window_us / std.time.us_per_ms,
                    }),
                    .quiet => {},
                }
            }
        }
        std.mem.copyForwards(u8, buffer[0 .. kept - from], buffer[from..kept]);
        kept -= from;
        if (kept == buffer.len) kept = 0; // A line longer than the buffer: dropped.
    }
}

/// A process failing one call the same way this many times within the window: a tight retry
/// loop (WASABI's oracle, Sun et al., SOSP 2024, black-box): a `syscall_error_storm` event once
/// for the task, call and error, and its failures past this many in a window not each an event
/// (a loop failing a hundred thousand times flooded the timeline's events). A hint, measured for
/// its noise before it judges anything (docs/PLAN.md's O).
const storm_count = 100;
const storm_window_us = std.time.us_per_s;

/// The tasks, calls and errors seen failing, each with its window: a small table (a key's slot
/// by its hash, a newer key taking an older one's).
const Storms = struct {
    const slots = 256;
    const Slot = struct { key: u64 = 0, window_us: u64 = 0, count: u32 = 0, stormed: bool = false };
    table: [slots]Slot = @splat(.{}),

    const Verdict = enum { event, storm, quiet };

    fn note(storms: *Storms, task: []const u8, nr: u32, errno: u32, at_us: u64) Verdict {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(task);
        hasher.update(std.mem.asBytes(&nr));
        hasher.update(std.mem.asBytes(&errno));
        const key = hasher.final() | 1; // Never 0: an empty slot's.
        const slot = &storms.table[key % slots];
        if (slot.key != key) slot.* = .{ .key = key, .window_us = at_us };
        if (at_us -| slot.window_us >= storm_window_us) {
            slot.window_us = at_us;
            slot.count = 0;
        }
        slot.count += 1;
        if (slot.count < storm_count) return .event;
        if (slot.count == storm_count and !slot.stormed) {
            slot.stormed = true;
            return .storm;
        }
        return if (slot.count == storm_count) .event else .quiet;
    }
};

test Storms {
    var storms: Storms = .{};
    // 99 failures in a second: each an event. The 100th: the storm, once. Then quiet.
    for (0..99) |index| try std.testing.expectEqual(Storms.Verdict.event, storms.note("loop-12", 21, 13, index * 1000));
    try std.testing.expectEqual(Storms.Verdict.storm, storms.note("loop-12", 21, 13, 99_000));
    try std.testing.expectEqual(Storms.Verdict.quiet, storms.note("loop-12", 21, 13, 100_000));
    // Another task's failures stay events; slow ones (a second apart) never storm.
    try std.testing.expectEqual(Storms.Verdict.event, storms.note("other-7", 21, 13, 100_000));
    for (0..200) |index| try std.testing.expectEqual(Storms.Verdict.event, storms.note("slow-3", 2, 2, index * std.time.us_per_s));
    // The stormed task's next window: events again, and no second storm.
    for (0..99) |index| try std.testing.expectEqual(Storms.Verdict.event, storms.note("loop-12", 21, 13, 2_000_000 + index));
    try std.testing.expectEqual(Storms.Verdict.event, storms.note("loop-12", 21, 13, 2_000_100));
    try std.testing.expectEqual(Storms.Verdict.quiet, storms.note("loop-12", 21, 13, 2_000_101));
}

/// A trace_pipe line's task (`comm-pid`), its time (microseconds since boot), and system call
/// number: "  erts_dios_3-2371    [000] .....    81.325829: sys_exit: NR 21 = -13".
fn errno_line(line: []const u8) ?struct { task: []const u8, nr: u32, errno: u32, at_us: u64 } {
    const marker = "sys_exit: NR ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const nr = std.fmt.parseInt(u32, rest[0..space], 10) catch return null;
    const minus = std.mem.lastIndexOf(u8, rest, "= -") orelse return null;
    const errno = std.fmt.parseInt(u32, std.mem.trim(u8, rest[minus + 3 ..], " \r"), 10) catch return null;
    const trimmed = std.mem.trimStart(u8, line, " ");
    const task_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    // The time: the word ending in ':' before the marker ("81.325829:").
    const head = std.mem.trimEnd(u8, line[0..at], " ");
    const time_start = (std.mem.lastIndexOfScalar(u8, head, ' ') orelse 0) + 1;
    const time_text = std.mem.trimEnd(u8, head[time_start..], ":");
    const dot = std.mem.indexOfScalar(u8, time_text, '.') orelse return null;
    const whole = std.fmt.parseInt(u64, time_text[0..dot], 10) catch return null;
    const fraction = std.fmt.parseInt(u64, time_text[dot + 1 ..], 10) catch return null;
    return .{ .task = trimmed[0..task_end], .nr = nr, .errno = errno, .at_us = whole * std.time.us_per_s + fraction };
}

test errno_line {
    const hit = errno_line("     erts_dios_3-2371    [000] .....    81.325829: sys_exit: NR 21 = -13").?;
    try std.testing.expectEqualStrings("erts_dios_3-2371", hit.task);
    try std.testing.expectEqual(21, hit.nr);
    try std.testing.expectEqual(13, hit.errno);
    try std.testing.expectEqual(@as(u64, 81_325_829), hit.at_us);
    try std.testing.expectEqual(null, errno_line("# tracer: nop"));
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
