// SPDX-License-Identifier: MIT
//! Output as events: what a node's processes, or a test command, write to stdout and stderr,
//! line by line, as `{"output":{"source":..,"stream":"stdout"|"stderr","text":..}}`, each with
//! its moment, as Antithesis logs container and command output. The bytes also go to a file
//! (the node's output.log, or the commands' log).
//!
//! One forwarder process per node start or command reads the two pipes it writes to, and sends
//! the lines it has as one write (one request to the platform), not one per line. It takes the
//! source's name as its own (its comm), so the events' source is the node or command. It ends
//! when every process writing to the pipes has closed them.
//!
//! A line that starts as a language runtime's panic, fatal error, data race or uncaught exception
//! does (Antithesis's "No panics (Go)" and others) is also an assertion that fails, right after
//! it: queries, a run's properties and its timelines all see it as any other. A node that declares
//! panics known (schema.Node.panics_known) has the line held while its stack is read: a known
//! one's text there counts it instead.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const crash_names = @import("crash_names.zig");
const exits_zig = @import("exits.zig");
const schema = sdk.schema;

/// A line longer than this is cut into several events.
const line_size_max = 2048;
const read_size = 4096;
/// Output kept, as events and in the log file, at Antithesis's logging rate (200 MB an hour of
/// virtual time, the logging property's), with a burst: a node looping on an error (a
/// controller, run 83: 4 GB of events in one timeline, its run's page slow while serve took
/// them in, and the log file in the guest's memory) has the rest dropped, counted in an
/// `output_dropped` event, so the property still sees it. Lines dropped are not checked for
/// language properties (a panic in a flood).
const kept_bytes_per_s = 200 * 1000 * 1000 / 3600;
const kept_burst_bytes = 8 * 1000 * 1000;
const report_every_ns = 10 * std.time.ns_per_s;
/// A held panic's stack: the lines after it looked through for a known panic's text, and how long
/// the forwarder waits for them: a runtime writes its whole stack at once, and a timeline may end
/// soon after (a wait of 1 s lost the e2e properties check's unknown panic: its node went on, its
/// driver ended 200 ms later). A runtime that exits ends the wait at once (its pipes close).
const held_lines_max = 16;
const held_wait_ms = 100;
const known_shown_max = 128;

pub const Pipes = struct { stdout: [2]linux.fd_t, stderr: [2]linux.fd_t };

pub fn pipes() !Pipes {
    var result: Pipes = undefined;
    for ([_]*[2]linux.fd_t{ &result.stdout, &result.stderr }) |pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    return result;
}

/// Starts the forwarder; the caller then closes the read ends, and the write ends once the
/// writer has them. The forwarder is not the caller's child (a process in between starts it and
/// exits), so callers that wait for any child never meet it: det-init reaps it.
/// `exits`: a node's, the socket its first process sends its exits filter's listener on
/// (exits.zig): the forwarder answers its notifications for as long as the node runs.
pub fn forward(source: []const u8, panics_known: []const []const u8, log_failures: []const schema.LogFailure, log_path: [:0]const u8, from: Pipes, exits: ?linux.fd_t) !void {
    const middle = linux.fork();
    if (linux.errno(middle) != .SUCCESS) return error.Fork;
    if (middle != 0) {
        var status: i32 = 0;
        _ = linux.wait4(@intCast(middle), &status, 0, null);
        return;
    }
    const pid = linux.fork();
    if (pid != 0) linux.exit_group(0); // The forwarder is adopted by PID 1.
    files_close_except(&.{ from.stdout[0], from.stderr[0], exits orelse from.stderr[0] });
    stdio_detach();
    var name_buffer: [16]u8 = @splat(0);
    const name_size = @min(source.len, name_buffer.len - 1);
    @memcpy(name_buffer[0..name_size], source[0..name_size]);
    _ = linux.prctl(@backingInt(linux.PR.SET_NAME), @intFromPtr(&name_buffer), 0, 0, 0);
    run(source, panics_known, log_failures, log_path, from.stdout[0], from.stderr[0], exits);
    linux.exit_group(0);
}

/// The forwarder's stdin, stdout and stderr, not its starter's: /dev/null in, the console out (its
/// own messages, as det-init's children have). Kept, a starter's pipe never ended while the node
/// ran: a session step starting a node (`det-nodes start echo`) printed what it said and never
/// finished, its output's reader waiting for the end the forwarder held (e2e ingress-crash's
/// first run, 2026-11-15: 13 minutes, the step's call then stopped).
fn stdio_detach() void {
    const input = linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(input) == .SUCCESS) {
        _ = linux.dup2(@intCast(input), 0);
        _ = linux.close(@intCast(input));
    }
    const console = linux.open("/dev/console", .{ .ACCMODE = .WRONLY, .NOCTTY = true, .CLOEXEC = true }, 0);
    const out = if (linux.errno(console) == .SUCCESS)
        console
    else
        linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(out) != .SUCCESS) return;
    _ = linux.dup2(@intCast(out), 1);
    _ = linux.dup2(@intCast(out), 2);
    _ = linux.close(@intCast(out));
}

/// Every file the forwarder inherited, but stdin, stdout, stderr and its two pipes: it forks
/// from det-faults or det-nodes at any moment, from any of their threads, and a copy it kept
/// held what they held then for as long as it ran. A device-mapper lock det-faults' durability
/// listener held as its main thread restarted a node: the lock's next taker waited forever, and
/// the fault injector with it (srv3, 2026-10-28, a Kafka timeline without faults for 69 s); and
/// another node's pipes, whose forwarder then never saw them end.
fn files_close_except(keep: []const linux.fd_t) void {
    var sorted: [3]u32 = undefined;
    assert(keep.len <= sorted.len);
    for (keep, sorted[0..keep.len]) |fd, *slot| slot.* = @intCast(fd);
    std.mem.sort(u32, sorted[0..keep.len], {}, std.sort.asc(u32));
    var from: u32 = 3;
    for (sorted[0..keep.len]) |fd| {
        if (fd >= from) {
            if (fd > from) _ = linux.syscall3(.close_range, from, fd - 1, 0);
            from = fd + 1;
        }
    }
    _ = linux.syscall3(.close_range, from, std.math.maxInt(u32), 0);
}

const Stream = struct {
    fd: linux.fd_t,
    name: []const u8,
    open: bool = true,
    partial: [line_size_max]u8 = undefined,
    partial_size: usize = 0,
    /// The pieces of the line being read already sent (a line longer than line_size_max).
    parts: u32 = 0,
};

fn run(source: []const u8, panics_known: []const []const u8, log_failures: []const schema.LogFailure, log_path: [:0]const u8, stdout: linux.fd_t, stderr: linux.fd_t, exits: ?linux.fd_t) void {
    const log_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_result = linux.open(log_path, log_flags, 0o644);
    const log: ?linux.fd_t = if (linux.errno(log_result) == .SUCCESS)
        @intCast(log_result)
    else
        null;
    const device_result = linux.open(sdk.device_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    const device: ?linux.fd_t = if (linux.errno(device_result) == .SUCCESS)
        @intCast(device_result)
    else
        null;
    var streams = [_]Stream{
        .{ .fd = stdout, .name = "stdout" },
        .{ .fd = stderr, .name = "stderr" },
    };
    var batch: Batch = .{ .source = source, .device = device, .panics_known = panics_known, .log_failures = log_failures };
    var budget: Budget = .{ .at_ns = monotonic_ns() };
    // The node's exits filter: its listener's socket until the listener comes, then the
    // listener, its notifications answered as they come (exits.zig).
    var exits_socket: ?linux.fd_t = exits;
    var listener: ?linux.fd_t = null;
    // Its output may end long before its processes (a daemon's stdio on /dev/null): the listener
    // is held, and answered, until no process of the node is left under the filter (its
    // POLLHUP). Closed earlier, a nonzero exit_group would fail with ENOSYS: glibc's _exit then
    // ends only the calling thread, and the process goes on.
    while (streams[0].open or streams[1].open or listener != null) {
        var polls: [3]linux.pollfd = undefined;
        var polled: [2]*Stream = undefined;
        var count: usize = 0;
        for (&streams) |*stream| {
            if (!stream.open) continue;
            polls[count] = .{ .fd = stream.fd, .events = linux.POLL.IN, .revents = 0 };
            polled[count] = stream;
            count += 1;
        }
        const exits_fd = listener orelse exits_socket;
        if (exits_fd) |fd| polls[count] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        const ready = linux.poll(&polls, count + @intFromBool(exits_fd != null), if (batch.held == null) -1 else held_wait_ms);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) break;
        if (ready == 0) { // A held panic's stack never came: it fails.
            batch.held_fail();
            batch.flush();
            continue;
        }
        if (exits_fd != null and polls[count].revents != 0) {
            const revents = polls[count].revents;
            if (listener) |fd| {
                if (revents & linux.POLL.IN != 0) {
                    var line_buffer: [sdk.message_size_max]u8 = undefined;
                    var line: std.Io.Writer = .fixed(&line_buffer);
                    if (exits_zig.answer(fd, source, &line)) {
                        batch.raw(line.buffered());
                        batch.flush();
                    }
                } else {
                    // No process of the node is left under the filter.
                    _ = linux.close(fd);
                    listener = null;
                }
            } else if (exits_socket) |socket| {
                listener = exits_zig.listener_receive(socket);
                _ = linux.close(socket);
                exits_socket = null;
            }
        }
        for (polls[0..count], polled[0..count]) |poll, stream| {
            if (poll.revents == 0) continue;
            var buffer: [read_size]u8 = undefined;
            const size = linux.read(stream.fd, &buffer, buffer.len);
            if (linux.errno(size) == .INTR) continue;
            if (linux.errno(size) != .SUCCESS or size == 0) {
                stream.open = false;
                const rest = stream.partial[0..stream.partial_size];
                if (rest.len > 0) batch.line(stream.name, rest);
                stream.partial_size = 0;
                continue;
            }
            if (!budget.take(size)) {
                budget.dropped_bytes += size;
                budget.dropped_lines += std.mem.count(u8, buffer[0..size], "\n");
                stream.partial_size = 0; // Its rest is dropped too.
                // Said every 10 s while dropping: a node flooding to its timeline's end has its
                // forwarder killed before it would say it.
                if (budget.seen_ns -| budget.reported_ns >= report_every_ns) budget.report(&batch);
                continue;
            }
            budget.report(&batch);
            if (log) |fd| _ = linux.write(fd, &buffer, size);
            lines_split(&batch, stream, buffer[0..size]);
        }
        batch.flush(); // What one read brought: one request.
    }
    batch.held_fail();
    budget.report(&batch);
    batch.flush();
}

/// A token bucket over virtual time (kept_bytes_per_s, kept_burst_bytes), and what it dropped
/// since it last said so.
const Budget = struct {
    tokens: u64 = kept_burst_bytes,
    at_ns: u64,
    dropped_bytes: u64 = 0,
    dropped_lines: u64 = 0,
    reported_ns: u64 = 0,
    /// The last moment a read was weighed: the reports' cadence.
    seen_ns: u64 = 0,

    fn take(budget: *Budget, size: u64) bool {
        const now = monotonic_ns();
        const earned = (now -| budget.at_ns) * kept_bytes_per_s / std.time.ns_per_s;
        if (earned > 0) {
            budget.tokens = @min(kept_burst_bytes, budget.tokens + earned);
            budget.at_ns = now;
        }
        budget.seen_ns = now;
        if (budget.tokens < size) return false;
        budget.tokens -= size;
        return true;
    }

    fn report(budget: *Budget, batch: *Batch) void {
        if (budget.dropped_bytes == 0) return;
        batch.event(.{ .event = "output_dropped", .details = .{
            .source = batch.source,
            .bytes = budget.dropped_bytes,
            .lines = budget.dropped_lines,
        } });
        budget.dropped_bytes = 0;
        budget.dropped_lines = 0;
        budget.reported_ns = budget.seen_ns;
    }
};

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn lines_split(batch: *Batch, stream: *Stream, bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') {
            batch.line_part(stream.name, stream.partial[0..stream.partial_size], stream.parts);
            stream.partial_size = 0;
            stream.parts = 0;
            continue;
        }
        if (stream.partial_size == line_size_max) {
            batch.line_part(stream.name, &stream.partial, stream.parts);
            stream.partial_size = 0;
            stream.parts += 1;
        }
        stream.partial[stream.partial_size] = byte;
        stream.partial_size += 1;
    }
}

/// Events waiting to be sent, one JSON object per line, as the platform splits them (det-podlogs
/// sends a Kubernetes node's pods' output through it too).
pub const Batch = struct {
    source: []const u8,
    device: ?linux.fd_t,
    /// The node's known panics (schema.Node.panics_known): a language property's line is held
    /// while the lines after it are read for one of these texts.
    panics_known: []const []const u8 = &.{},
    /// The node's own failure texts (schema.Node.log_failures).
    log_failures: []const schema.LogFailure = &.{},
    held: ?Held = null,
    buffer: [sdk.message_size_max]u8 = undefined,
    size: usize = 0,

    /// A language property's line held for its stack.
    const Held = struct {
        property: []const u8,
        text: [line_size_max]u8,
        text_size: usize,
        lines_left: u32,
    };

    /// A piece of a line longer than line_size_max: the first as a line, the rest with their
    /// `part` (cut wherever the bytes fell, mid-word: never a kind of line of their own to the
    /// explorer, run 1871's Kafka 74% of whose kinds of line were such pieces and random ids),
    /// still in the log and still read for the node's failure texts.
    pub fn line_part(batch: *Batch, stream: []const u8, text: []const u8, part: u32) void {
        if (part == 0) return batch.line(stream, text);
        batch.event(.{ .output = .{ .source = batch.source, .stream = stream, .text = text, .part = part } });
        batch.log_failure(text);
    }

    pub fn line(batch: *Batch, stream: []const u8, text: []const u8) void {
        batch.event(.{ .output = .{ .source = batch.source, .stream = stream, .text = text } });
        if (batch.held) |*held| {
            if (known_in(batch.panics_known, text)) |known| {
                var property_buffer: [crash_names.known_panic_prefix.len + known_shown_max]u8 = undefined;
                const shown = known[0..@min(known.len, known_shown_max)];
                const property = std.fmt.bufPrint(&property_buffer, crash_names.known_panic_prefix ++ "{s}", .{shown}) catch
                    unreachable;
                batch.event(.{ .assert = .{
                    .type = "sometimes",
                    .message = property,
                    .condition = true,
                    .details = .{ .source = batch.source, .text = held.text[0..held.text_size] },
                } });
                batch.held = null;
            } else {
                held.lines_left -= 1;
                if (held.lines_left == 0) batch.held_fail();
            }
        }
        batch.log_failure(text);
        const property = language_property(text) orelse return;
        if (batch.panics_known.len == 0) return batch.fail(property, text);
        batch.held_fail(); // Another panic before the last one's stack named it.
        const size = @min(text.len, line_size_max);
        batch.held = .{ .property = property, .text = undefined, .text_size = size, .lines_left = held_lines_max };
        @memcpy(batch.held.?.text[0..size], text[0..size]);
    }

    /// A line holding one of the node's failure texts fails its property, or, holding a known
    /// text of it too, is counted as that known bug's (schema.LogFailure).
    fn log_failure(batch: *Batch, text: []const u8) void {
        for (batch.log_failures) |failure| {
            if (std.mem.indexOf(u8, text, failure.text) == null) continue;
            if (known_in(failure.known, text)) |known| {
                var property_buffer: [schema.known_log_prefix.len + known_shown_max]u8 = undefined;
                const shown = known[0..@min(known.len, known_shown_max)];
                const property = std.fmt.bufPrint(&property_buffer, schema.known_log_prefix ++ "{s}", .{shown}) catch
                    unreachable;
                batch.event(.{ .assert = .{
                    .type = "sometimes",
                    .message = property,
                    .condition = true,
                    .details = .{ .source = batch.source, .text = text[0..@min(text.len, line_size_max)] },
                } });
            } else batch.fail(failure.property, text[0..@min(text.len, line_size_max)]);
        }
    }

    /// The held line's property fails, as an unknown panic's.
    pub fn held_fail(batch: *Batch) void {
        const held = &(batch.held orelse return);
        batch.fail(held.property, held.text[0..held.text_size]);
        batch.held = null;
    }

    fn fail(batch: *Batch, property: []const u8, text: []const u8) void {
        batch.event(.{ .assert = .{
            .type = "always_or_unreachable",
            .message = property,
            .condition = false,
            .details = .{ .source = batch.source, .text = text },
        } });
    }

    fn event(batch: *Batch, value: anytype) void {
        var event_buffer: [3 * line_size_max + 512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&event_buffer);
        std.json.Stringify.value(value, .{}, &writer) catch return;
        writer.writeAll("\n") catch return;
        const bytes = writer.buffered();
        if (bytes.len > batch.buffer.len) return; // Escaping can grow a line; never cut JSON.
        if (batch.size + bytes.len > batch.buffer.len) batch.flush();
        @memcpy(batch.buffer[batch.size..][0..bytes.len], bytes);
        batch.size += bytes.len;
    }

    /// A JSON line sent as it is (an Antithesis sink's `.jsonl` line: an event of its own).
    pub fn raw(batch: *Batch, json_line: []const u8) void {
        if (json_line.len + 1 > batch.buffer.len) return;
        if (batch.size + json_line.len + 1 > batch.buffer.len) batch.flush();
        @memcpy(batch.buffer[batch.size..][0..json_line.len], json_line);
        batch.buffer[batch.size + json_line.len] = '\n';
        batch.size += json_line.len + 1;
    }

    pub fn flush(batch: *Batch) void {
        defer batch.size = 0;
        const fd = batch.device orelse return;
        if (batch.size == 0) return;
        _ = linux.write(fd, &batch.buffer, batch.size);
    }
};

/// Language properties (Antithesis's "No panics (Go)" and others): the signature of a panic, a
/// fatal error, a data race or an uncaught exception, at the start of a line.
const language_signs = [_]struct { prefix: []const u8, property: []const u8 }{
    .{ .prefix = "panic: ", .property = "no panics (Go)" },
    .{ .prefix = "fatal error: ", .property = "no fatal errors (Go)" },
    .{ .prefix = "WARNING: DATA RACE", .property = "no data races (Go)" },
    .{ .prefix = "thread '", .property = "no panics (Rust)" },
    .{ .prefix = "Exception in thread \"", .property = "no uncaught exceptions (Java)" },
    // Ours beside Antithesis's: a JVM run with -ea whose assertion failed, logged (a framework
    // catches it: Netty on an event loop, mu-server's run 990 study) rather than uncaught.
    .{ .prefix = "java.lang.AssertionError", .property = "no assertion failures (Java)" },
    .{ .prefix = "Caused by: java.lang.AssertionError", .property = "no assertion failures (Java)" },
};

/// The known panic's text a line holds, if any.
fn known_in(panics_known: []const []const u8, text: []const u8) ?[]const u8 {
    for (panics_known) |known| {
        if (std.mem.indexOf(u8, text, known) != null) return known;
    }
    return null;
}

/// The language property a line of output violates, if any.
fn language_property(text: []const u8) ?[]const u8 {
    for (language_signs) |sign| {
        if (!std.mem.startsWith(u8, text, sign.prefix)) continue;
        // Rust's panic line: "thread 'main' panicked at src/main.rs:4:5:".
        const rust = std.mem.eql(u8, sign.prefix, "thread '");
        if (rust and std.mem.indexOf(u8, text, "' panicked at ") == null) continue;
        return sign.property;
    }
    return null;
}

test language_property {
    try std.testing.expectEqual(@as(?[]const u8, null), language_property("thread 'x' started"));
    try std.testing.expectEqualStrings("no panics (Rust)", language_property(
        "thread 'main' panicked at src/main.rs:4:5:",
    ).?);
    try std.testing.expectEqualStrings("no panics (Go)", language_property(
        "panic: runtime error: invalid memory address or nil pointer dereference",
    ).?);
    try std.testing.expectEqual(@as(?[]const u8, null), language_property("I0101 panic: later"));
    try std.testing.expectEqualStrings("no assertion failures (Java)", language_property(
        "java.lang.AssertionError: Status change to FINISHED not in event loop",
    ).?);
    try std.testing.expectEqualStrings("no assertion failures (Java)", language_property(
        "Caused by: java.lang.AssertionError",
    ).?);
    // Uncaught, it is the uncaught exceptions' property (the first sign that matches).
    try std.testing.expectEqualStrings("no uncaught exceptions (Java)", language_property(
        "Exception in thread \"main\" java.lang.AssertionError",
    ).?);
    try std.testing.expectEqual(@as(?[]const u8, null), language_property("\tat java.lang.AssertionError"));
}

test "a node's failure text fails its property, a known bug's line is counted instead" {
    const failures = [_]schema.LogFailure{.{
        .text = "panic in the recoverable goroutine",
        .property = "no recovered panics (TiDB)",
        .known = &.{"meta.splitRangeInt64Max"},
    }};
    var batch: Batch = .{ .source = "n1", .device = null, .log_failures = &failures };
    batch.line("stdout", "[ERROR] [\"panic in the recoverable goroutine\"] [stack=\"pkg/executor.(*X).Next\"]");
    batch.line("stdout", "[ERROR] [\"panic in the recoverable goroutine\"] [stack=\"meta.splitRangeInt64Max\"]");
    batch.line("stdout", "[INFO] all is well");
    const sent = batch.buffer[0..batch.size];
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, sent, "\n")); // 3 lines, 2 asserts.
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"message\":\"no recovered panics (TiDB)\",\"condition\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"message\":\"" ++ schema.known_log_prefix ++
        "meta.splitRangeInt64Max\",\"condition\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sent, "\"condition\":false"));
}

test "a panic line is its output event, then its property's failing assertion" {
    var batch: Batch = .{ .source = "n5", .device = null };
    batch.line("stderr", "panic: runtime error: invalid memory address or nil pointer dereference");
    batch.line("stderr", "goroutine 275 [running]:");
    const sent = batch.buffer[0..batch.size];
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, sent, "\n"));
    const output = std.mem.indexOf(u8, sent, "{\"output\":{\"source\":\"n5\"").?;
    const assertion = std.mem.indexOf(u8, sent, "{\"assert\":{\"type\":\"always_or_unreachable\"," ++
        "\"message\":\"no panics (Go)\",\"condition\":false,\"details\":{\"source\":\"n5\"").?;
    try std.testing.expect(output < assertion);
}

test "a known panic, named in its stack, is counted; another still fails" {
    var batch: Batch = .{ .source = "n3", .device = null, .panics_known = &.{"worker.(*node).IsLeader(0x0"} };
    batch.line("stderr", "panic: runtime error: invalid memory address or nil pointer dereference");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, batch.buffer[0..batch.size], "\n"));
    batch.line("stderr", "goroutine 316 [running]:");
    batch.line("stderr", "example.com/store/worker.(*node).IsLeader(0x0, 0xc02349a000)");
    var sent = batch.buffer[0..batch.size];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"condition\":false") == null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "{\"assert\":{\"type\":\"sometimes\",\"message\":" ++
        "\"a panic the system is known to have: worker.(*node).IsLeader(0x0\",\"condition\":true") != null);
    try std.testing.expectEqual(@as(?Batch.Held, null), batch.held);
    batch.size = 0;
    batch.line("stderr", "panic: send on closed channel");
    for (0..held_lines_max) |_| batch.line("stderr", "\tat somewhere");
    sent = batch.buffer[0..batch.size];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sent, "\"message\":\"no panics (Go)\",\"condition\":false"));
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"text\":\"panic: send on closed channel\"") != null);
    // Held at the forwarder's end: it fails then.
    batch.size = 0;
    batch.line("stderr", "fatal error: concurrent map writes");
    batch.held_fail();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, batch.buffer[0..batch.size], "\"message\":\"no fatal errors (Go)\",\"condition\":false"));
}
