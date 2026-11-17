// SPDX-License-Identifier: MIT
//! Host checks (schema.Check): when a timeline ends, each of the test program's checks runs on
//! the host, as `<program> check <name> <scenario>`, with the records the timeline's commands
//! made (streamed out by the composer, collected by Events) on its standard input. The
//! assertions it makes (the SDK prints them as JSON lines, outside a guest) become events of the
//! timeline at its end moment, as the built-in properties are. The guest pays nothing; a replay
//! sends the same records, so the checks reach the same verdicts. sdk.elle.check is one such
//! check: Jepsen's Elle on a transaction history.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const schema = @import("determinismo").schema;
const Events = @import("core").events;
const VM = @import("core").vm;

/// Room for the inputs of a timeline's checks (Events.check_buffer): a history of a long
/// timeline is megabytes, of a long fault-free one past 64 MiB (Valkey's, Turso's and
/// FoundationDB's: 11 of run 1517's 646 timelines, 22 of run 1464's 207, up to 122 MB, sent
/// and never judged, "host checks run to completion" failing). Reserved whole, touched as used,
/// its pages given back once the checks ran (Events.check_release). 512 MiB: rqlite's append
/// histories past 256 MiB in timelines of a usual length whose drawn load and parallelism ran
/// 6-8 times the median's operations (660k-880k events against 105k: runs 1866 and 1867, 8
/// timelines unjudged). No more: the Elle service checks 16 histories at once in an 8 GiB heap.
pub const input_size_max = 512 << 20;
/// What a check may print: its assertions, and what it says when it fails.
const output_size_max = 4 << 20;
const event_size_max = 4096;

pub const Options = struct {
    /// The test program, run on the host (the same binary as in the guest).
    program: []const u8,
    scenario: []const u8,
    /// `<events directory>/branch-<n>`: a check that asserts anything false has its input kept
    /// there, `<keep>.check-<name>.jsonl` (an Elle history: Oxia's, Datahike's and Comdb2's
    /// failures each took a replay to the timeline's end to read theirs, 2026-11-06).
    keep: ?[]const u8 = null,
};

/// `DETERMINISMO_LIBRARY=<path>` for a test program run on the host (its --describe, its
/// checks): the explorer's own libdeterminismo, as a guest has /opt/determinismo/lib's. Programs
/// in other languages call the SDK through it (sdk/clojure's determinismo.ffi); a Zig program
/// has its SDK compiled in. Two layouts: a run's kept explorer has its library beside it as
/// `<explorer>.libdeterminismo.so` (runs.library_keep), the build's binary in its directory.
pub fn library_variable(buffer: []u8) ![:0]const u8 {
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = linux.readlink("/proc/self/exe", &exe_buffer, exe_buffer.len);
    if (linux.errno(size) != .SUCCESS) return error.NoExecutable;
    const exe = exe_buffer[0..size];
    var kept_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const kept = try std.fmt.bufPrintSentinel(&kept_buffer, "{s}.libdeterminismo.so", .{exe}, 0);
    if (linux.errno(linux.access(kept, linux.F_OK)) == .SUCCESS) {
        return std.fmt.bufPrintSentinel(buffer, "DETERMINISMO_LIBRARY={s}", .{kept}, 0);
    }
    const directory = std.fs.path.dirname(exe) orelse return error.NoExecutable;
    return std.fmt.bufPrintSentinel(buffer, "DETERMINISMO_LIBRARY={s}/libdeterminismo.so", .{directory}, 0);
}

/// Each check whose records the timeline sent: run, and its assertions emitted at `moment`.
/// The checks of a test program in a scenario, as the core's hook at a timeline's end
/// (VM.EndChecks): the core runs a timeline, the explorer judges it.
pub const Hook = struct {
    checks: []const schema.Check,
    program: []const u8,
    scenario: []const u8,

    pub fn end_checks(hook: *const Hook) VM.EndChecks {
        return .{ .context = hook, .run = run_hook };
    }

    fn run_hook(context: *const anyopaque, events: *Events, end: Events.Moment, keep: ?[]const u8) anyerror!void {
        const hook: *const Hook = @ptrCast(@alignCast(context));
        try run(events, end, hook.checks, .{ .program = hook.program, .scenario = hook.scenario, .keep = keep });
    }
};

pub fn run(events: *Events, moment: Events.Moment, checks: []const schema.Check, options: Options) !void {
    for (checks, 0..) |check, index| {
        if (index >= Events.check_count_max) break;
        const input = switch (events.check_state(index)) {
            .input => |bytes| bytes,
            .none => continue,
            // Records sent and never judged: once skipped without a word (trial run 1270, jetcd:
            // a timeline's Elle history past the buffer, no verdict and nothing failing).
            .overflow, .incomplete => {
                var buffer: [512]u8 = undefined;
                try events.emit(moment, try unjudged_event(&buffer, check.name, switch (events.check_state(index)) {
                    .overflow => "its input outgrew the host's check buffer",
                    else => "its input never arrived whole",
                }));
                continue;
            },
        };
        const output = try std.heap.page_allocator.alloc(u8, output_size_max);
        defer std.heap.page_allocator.free(output);
        const result = try check_run(options, check.name, input, output);
        var asserted: u32 = 0;
        var lines = std.mem.tokenizeScalar(u8, result.output, '\n');
        while (lines.next()) |line| {
            // Its assertions; the rest (traces, its own messages) stays with the host's output.
            if (!std.mem.startsWith(u8, line, "{\"assert\":") or line.len > event_size_max) {
                std.debug.print("[determinismo] check {s}: {s}\n", .{ check.name, line });
                continue;
            }
            try events.emit(moment, line);
            asserted += 1;
        }
        var buffer: [512]u8 = undefined;
        try events.emit(moment, try ran_event(&buffer, check.name, result.status, asserted));
        if (options.keep) |prefix| if (std.mem.indexOf(u8, result.output, "\"condition\":false") != null) {
            input_keep(prefix, check.name, input);
        };
    }
}

/// A failing check's input, beside the timeline's events (best effort: the verdict stands).
fn input_keep(prefix: []const u8, name: []const u8, input: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}.check-{s}.jsonl", .{ prefix, name }, 0) catch return;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var written: usize = 0;
    while (written < input.len) {
        const result = linux.write(@intCast(fd), input[written..].ptr, input.len - written);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        written += result;
    }
}

test "an Elle history's cap stays below the host's check buffer" {
    // The SDK stops a history short of what the host can hold (elle.history_size_max): past the
    // buffer it went unjudged (hunt run 1969).
    try std.testing.expect(@import("determinismo").elle.history_size_max < input_size_max);
}

test input_keep {
    var path_buffer: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&path_buffer, ".det-keep-test-{d}", .{linux.getpid()});
    input_keep(prefix, "elle", "{\"type\":\"ok\"}\n");
    var name_buffer: [96:0]u8 = undefined;
    const kept = try std.fmt.bufPrintSentinel(&name_buffer, "{s}.check-elle.jsonl", .{prefix}, 0);
    defer _ = linux.unlink(kept);
    var read_buffer: [64]u8 = undefined;
    const fd = linux.open(kept, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expect(linux.errno(fd) == .SUCCESS);
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &read_buffer, read_buffer.len);
    try std.testing.expectEqualStrings("{\"type\":\"ok\"}\n", read_buffer[0..size]);
}

/// `always "host checks run to completion"`: a check that crashed or failed judged nothing, and
/// so did one that exited 0 having asserted nothing on the records it was sent (its assertions
/// lost on the way: 40 hunt runs, 997 to 1037, passed this property while every check's
/// assertions went nowhere, Elle's verdicts among them).
fn ran_event(buffer: []u8, name: []const u8, status: u32, asserted: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"assert\":{{\"type\":\"always\",\"message\":\"host " ++
        "checks run to completion\",\"condition\":{},\"details\":{{\"check\":\"{s}\"," ++
        "\"status\":{d},\"assertions\":{d}}}}}}}", .{ status == 0 and asserted > 0, name, status, asserted });
}

/// The same property, false: a check whose records were sent and not judged.
fn unjudged_event(buffer: []u8, name: []const u8, reason: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"assert\":{{\"type\":\"always\",\"message\":\"host " ++
        "checks run to completion\",\"condition\":false,\"details\":{{\"check\":\"{s}\"," ++
        "\"reason\":\"{s}\"}}}}}}", .{ name, reason });
}

test unjudged_event {
    var buffer: [512]u8 = undefined;
    const line = try unjudged_event(&buffer, "elle", "its input outgrew the host's check buffer");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const assertion = parsed.value.object.get("assert").?.object;
    try std.testing.expectEqualStrings("host checks run to completion", assertion.get("message").?.string);
    try std.testing.expect(!assertion.get("condition").?.bool);
}

const Result = struct { status: u32, output: []const u8 };

/// The program as `check <name> <scenario>`: its input from a memory file, what it prints to
/// standard error read into `output` (the rest dropped).
fn check_run(options: Options, name: []const u8, input: []const u8, output: []u8) !Result {
    const memory = linux.memfd_create("det-check-input", linux.MFD.CLOEXEC);
    if (linux.errno(memory) != .SUCCESS) return error.MemoryFile;
    const input_fd: linux.fd_t = @intCast(memory);
    defer _ = linux.close(input_fd);
    var written: usize = 0;
    while (written < input.len) {
        const result = linux.write(input_fd, input[written..].ptr, input.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        written += result;
    }
    _ = linux.lseek(input_fd, 0, linux.SEEK.SET);
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    var arguments_buffer: [3][256:0]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{
        try std.fmt.bufPrintSentinel(&arguments_buffer[0], "{s}", .{options.program}, 0),
        "check",
        try std.fmt.bufPrintSentinel(&arguments_buffer[1], "{s}", .{name}, 0),
        try std.fmt.bufPrintSentinel(&arguments_buffer[2], "{s}", .{options.scenario}, 0),
        null,
    };
    var library_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const environment = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/usr/bin:/bin",
        try library_variable(&library_buffer),
        // The SDKs are silent outside a guest unless told where to write: here, the pipe this
        // reads (standard error). Without it every check's assertions were lost, Elle's verdicts
        // among them (hunt run 1036, etcd: "Elle checked a history" never reached).
        "DETERMINISMO_SDK_LOCAL_OUTPUT=/dev/stderr",
        null,
    };
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        _ = linux.dup2(input_fd, 0);
        _ = linux.dup2(pipe[1], 2);
        _ = linux.execve(argv[0].?, &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(pipe[1]);
    defer _ = linux.close(pipe[0]);
    var used: usize = 0;
    while (true) {
        var scratch: [4096]u8 = undefined;
        const target = if (used < output.len) output[used..] else &scratch;
        const result = linux.read(pipe[0], target.ptr, target.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        if (used < output.len) used += result;
    }
    var status: i32 = 0;
    while (true) {
        const waited = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(waited) != .INTR) break;
    }
    const bits: u32 = @bitCast(status);
    const exit_status: u32 = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    return .{ .status = exit_status, .output = output[0..used] };
}

test ran_event {
    var buffer: [512]u8 = undefined;
    const passed = try ran_event(&buffer, "elle", 0, 3);
    try std.testing.expect(std.mem.indexOf(u8, passed, "\"condition\":true") != null);
    // Exited 0 with nothing asserted: its assertions went nowhere, it judged nothing.
    const silent = try ran_event(&buffer, "elle", 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, silent, "\"condition\":false") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try ran_event(&buffer, "elle", 3, 1), .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("assert").?.object;
    try std.testing.expectEqual(false, event.get("condition").?.bool);
    try std.testing.expectEqual(@as(i64, 1), event.get("details").?.object.get("assertions").?.integer);
}
