// SPDX-License-Identifier: MIT
//! Elle (Jepsen's checker, checkers/elle) as a host check: drivers record a history of
//! transactions as they happen, and `check` is a check (System.main's `.checks`) that hands each
//! timeline's history to Elle on the host and asserts its verdict. Elle finds every anomaly of
//! the history (G0, G1a/b/c, G-single, G2, and real-time order for strict serializability); the
//! guest pays nothing, and a replay records the same history, so it gets the same verdict, with
//! every operation of an anomaly at its moment.
//!
//!   // The program's checks: Elle on every timeline's history.
//!   return System.main(init, .{ .describe = ..., .scenarios = ...,
//!       .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) } });
//!
//!   // A driver: one operation at a time per process.
//!   const history: sdk.elle.History = .{};
//!   var process = sdk.elle.process_new();
//!   const asked = [_]sdk.elle.Mop{
//!       .{ .append = .{ .key = 3, .value = 17 } }, // Values unique per key.
//!       .{ .read = .{ .key = 4 } },
//!   };
//!   try history.invoke(arena, process, &asked);
//!   // ... the transaction, then with what the reads saw:
//!   const done = [_]sdk.elle.Mop{ asked[0], .{ .read = .{ .key = 4, .list = &.{ 2, 9 } } } };
//!   try history.ok(arena, process, &done); // Or fail (it did not happen), or info (unknown:
//!   process = sdk.elle.process_new();      // the process then goes on as another).
//!
//! Models: list-append (`append` and `read` of lists), rw-register (`write` and
//! `read_register`) and closed-predicate (Elle's elle.closed-predicate, jepsen-io/mysql's
//! closed-predicate test: an `init` operation of `init` micro-operations, then transactions of
//! `insert`, `write`, `delete`, `read_register` and `read_predicate`). Lines are appended with one write each, so parallel drivers never interleave
//! inside one; an invocation left open (its driver stopped mid-call) is closed as info.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo.zig");
const schema = @import("schema.zig");
const tcp = @import("tcp");

/// The service, on the host: one for every run there, started by the first check that needs it.
pub const port = 7700;
const address = [4]u8{ 127, 0, 0, 1 };
const image = "determinismo-elle";
const dockerfile = "checkers/elle/Dockerfile";
const start_lock = "/tmp/determinismo-elle.lock";
/// Elle reads a timeline's whole history at once: seconds, more for long ones.
const timeout_ms = 600 * std.time.ms_per_s;
const anomalies_size_max = 2500;
/// The whole of a failing verdict's anomalies, past the property's cut, as events of this much
/// text each (JSON escaping may double it, within a message), up to this many: the cut left
/// a G1a out of two timelines' failures (hunt run 1468, 27 and 44).
const anomalies_part_size = 1500;
const anomalies_parts_max = 40;

pub const ScenarioConsistency = struct { scenario: []const u8, consistency: []const u8 };

pub const CheckOptions = struct {
    /// list-append, rw-register or closed-predicate.
    model: []const u8 = "list-append",
    /// One of Elle's models: strict-serializable, serializable, snapshot-isolation,
    /// read-committed, ...; or strict-serializable-per-key: real-time order only between
    /// operations touching a key in common (serializable, each key linearizable: YDB's claim).
    consistency: []const u8 = "strict-serializable",
    /// Another consistency model for some scenarios' timelines.
    by_scenario: []const ScenarioConsistency = &.{},
    /// Anomaly types the system is known to have (Kafka's G0, seen by Jepsen in normal
    /// operation). They still fail the check's property whenever found, never hidden; a second
    /// property beside it ("Elle finds no anomaly but those known in the system") fails only on
    /// the others, so what is not known stands out.
    allowed: []const []const u8 = &.{},
    message: []const u8 = "Elle finds no anomaly in the history",
    /// Judged directly beside Elle: every list read lists each append acknowledged before the
    /// read began. For a system whose reads may see a write before it is acknowledged, one copy
    /// before another (OpenSearch's realtime GET: Elle at strict serializability takes that for
    /// G-single-item-realtime), checked at `serializable` with this: what it does promise.
    realtime_reads: bool = false,
    /// rw-register: each key's version order inferred from real time (Elle's
    /// :linearizable-keys?), for a system that claims each key linearizable. Without it Elle
    /// cannot order two blind writes of a key, and two reads after both answering one then the
    /// other pass.
    linearizable_keys: bool = false,
};

/// The check to put in the program's `.checks`: Elle on every timeline's history (the records of
/// the check's name: History records under "elle", the usual name).
pub fn check(comptime options: CheckOptions) fn (*sdk.Check, []const u8) anyerror!void {
    return struct {
        fn run(context: *sdk.Check, history: []const u8) anyerror!void {
            // Its properties in the program's catalog: only a program with the check has them.
            sdk.catalog_entry("always", options.message);
            sdk.catalog_entry("sometimes", valid_message);
            if (options.allowed.len > 0) sdk.catalog_entry("always", unknown_message);
            if (options.realtime_reads) sdk.catalog_entry("always", realtime_message);
            return check_history(context, history, options);
        }
    }.run;
}

/// `check`'s catalog, with options known at run time (libdeterminismo's det_elle_declare): a
/// program in another language declares them as its check is defined.
pub fn declare(options: CheckOptions) void {
    sdk.declare("always", options.message);
    sdk.declare("sometimes", valid_message);
    if (options.allowed.len > 0) sdk.declare("always", unknown_message);
    if (options.realtime_reads) sdk.declare("always", realtime_message);
}

// Computed, not cataloged where they are judged: the library that judges them is in every
// program of another language, Elle or not, and one never reached would fail its runs.
const valid_message = "Elle checked a history and found it valid";
const unknown_message = "Elle finds no anomaly but those known in the system";

/// `text` as `elle_anomalies` events, in order (`part` of `parts`), each a slice of it ending on a
/// character's boundary.
fn anomalies_parts(text: []const u8) void {
    const parts = @min(anomalies_parts_max, std.math.divCeil(usize, text.len, anomalies_part_size) catch unreachable);
    var start: usize = 0;
    for (0..parts) |part| {
        if (start >= text.len) break;
        var end = @min(text.len, start + anomalies_part_size);
        while (end < text.len and end > start and (text[end] & 0xC0) == 0x80) end -= 1;
        sdk.event("elle_anomalies", .{ .part = part + 1, .parts = parts, .text = text[start..end] });
        start = end;
    }
}

test anomalies_parts {
    // Cuts on boundaries: a continuation byte never starts a part.
    var buffer: [2000]u8 = undefined;
    for (0..1000) |index| @memcpy(buffer[index * 2 ..][0..2], "é");
    const text: []const u8 = &buffer;
    var start: usize = 0;
    while (start < text.len) {
        var end = @min(text.len, start + anomalies_part_size);
        while (end < text.len and end > start and (text[end] & 0xC0) == 0x80) end -= 1;
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[start..end]));
        start = end;
    }
}

/// `check`'s work, with options known at run time (libdeterminismo's det_elle_check).
pub fn check_history(context: *sdk.Check, history: []const u8, options: CheckOptions) !void {
    if (history.len == 0) return;
    const consistency = for (options.by_scenario) |entry| {
        if (std.mem.eql(u8, entry.scenario, context.scenario)) break entry.consistency;
    } else options.consistency;
    const verdict = try judge(context, history, options.model, consistency, options.linearizable_keys);
    const anomalies = verdict.anomalies[0..@min(verdict.anomalies.len, anomalies_size_max)];
    const known = verdict.valid == false and verdict.anomaly_types.len > 0 and
        allowed_only(verdict.anomaly_types, options.allowed);
    // Only its search giving up: no anomaly found.
    const searched_out = verdict.valid == false and verdict.anomaly_types.len > 0 and
        allowed_only(verdict.anomaly_types, &.{});
    // Its search gave up: anomalies past it unseen, said (an event, no target).
    for (verdict.anomaly_types) |kind| if (std.mem.eql(u8, kind, not_anomalies[0])) {
        sdk.event("elle_cycle_search_timeout", .{ .ops = verdict.ops });
    };
    // When the anomaly formed (its earliest operation): the failure's moment, not the check's.
    const formed_ns: ?u64 = if (verdict.window_ns) |window| window[0] else null;
    if (options.allowed.len > 0) {
        sdk.assert_computed_at(.always, verdict.valid != false or known, unknown_message, .{
            .anomaly_types = verdict.anomaly_types,
            .window_ns = verdict.window_ns,
        }, formed_ns);
    }
    sdk.assert_computed_at(.always, verdict.valid != false or searched_out, options.message, .{
        .model = options.model,
        .consistency = consistency,
        .ops = verdict.ops,
        .anomaly_types = verdict.anomaly_types,
        .anomalies = anomalies,
        .window_ns = verdict.window_ns,
    }, formed_ns);
    sdk.assert_computed(.sometimes, verdict.valid == true, valid_message, .{
        .ops = verdict.ops,
    });
    if (verdict.valid == false and verdict.anomalies.len > anomalies.len) {
        anomalies_parts(verdict.anomalies);
    }
    if (options.realtime_reads) {
        const stale = try reads_stale(context.arena, history);
        for (stale.first[0..@min(stale.count, stale.first.len)]) |read| {
            sdk.assert_computed(.always, false, realtime_message, read);
        }
        if (stale.count > stale.first.len) sdk.event("reads_stale", .{ .count = stale.count });
        if (stale.count == 0) sdk.assert_computed(.always, true, realtime_message, .{ .reads = stale.reads });
    }
}

const realtime_message = "every append acknowledged before a read began is in it";

/// A read that missed an append acknowledged before it began.
pub const Stale = struct {
    key: u64,
    value: u64,
    /// When the append was acknowledged, and when the read began and ended (the guest's clock).
    acknowledged_ns: u64,
    read_ns: [2]u64,
    listed: usize,
};

pub const StaleReads = struct {
    count: u32 = 0,
    reads: u32 = 0,
    first: [8]Stale = undefined,
};

/// The history's (JSON lines) list reads that miss an append acknowledged before they began:
/// a process does one operation at a time, so an `ok` began at that process's last `invoke`.
/// Each line parsed in a scratch arena reset after it (what is kept is copied out), each read
/// judged against its key's appends only.
pub fn reads_stale(gpa: std.mem.Allocator, text: []const u8) !StaleReads {
    const Append = struct { value: u64, acknowledged_ns: u64 };
    const Read = struct { key: u64, list: []const u64, began_ns: u64, ended_ns: u64 };
    var invoked: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    var appends: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(Append)) = .empty;
    var reads: std.ArrayList(Read) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        _ = scratch.reset(.retain_capacity);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch
            return error.BadHistory;
        if (parsed != .object) return error.BadHistory;
        const kind = parsed.object.get("type") orelse return error.BadHistory;
        const process = parsed.object.get("process") orelse return error.BadHistory;
        const time = parsed.object.get("time") orelse return error.BadHistory;
        if (kind != .string or process != .integer or time != .integer) return error.BadHistory;
        const now: u64 = @intCast(time.integer);
        if (std.mem.eql(u8, kind.string, "invoke")) {
            try invoked.put(gpa, @intCast(process.integer), now);
            continue;
        }
        if (!std.mem.eql(u8, kind.string, "ok")) continue;
        const began = invoked.get(@intCast(process.integer)) orelse continue;
        const mops = parsed.object.get("value") orelse return error.BadHistory;
        if (mops != .array) return error.BadHistory;
        for (mops.array.items) |mop| {
            if (mop != .array or mop.array.items.len != 3) continue;
            const f = mop.array.items[0];
            const key = mop.array.items[1];
            const value = mop.array.items[2];
            if (f != .string or key != .integer) continue;
            if (std.mem.eql(u8, f.string, "append") and value == .integer) {
                const entry = try appends.getOrPut(gpa, @intCast(key.integer));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, .{ .value = @intCast(value.integer), .acknowledged_ns = now });
            } else if (std.mem.eql(u8, f.string, "r") and value == .array) {
                const list = try gpa.alloc(u64, value.array.items.len);
                for (value.array.items, list) |item, *slot| {
                    if (item != .integer) return error.BadHistory;
                    slot.* = @intCast(item.integer);
                }
                try reads.append(gpa, .{ .key = @intCast(key.integer), .list = list, .began_ns = began, .ended_ns = now });
            }
        }
    }
    var stale: StaleReads = .{ .reads = @intCast(reads.items.len) };
    for (reads.items) |read| {
        const keyed = appends.get(read.key) orelse continue;
        for (keyed.items) |append| {
            if (append.acknowledged_ns >= read.began_ns) continue;
            if (std.mem.indexOfScalar(u64, read.list, append.value) != null) continue;
            if (stale.count < stale.first.len) stale.first[stale.count] = .{
                .key = read.key,
                .value = append.value,
                .acknowledged_ns = append.acknowledged_ns,
                .read_ns = .{ read.began_ns, read.ended_ns },
                .listed = read.list.len,
            };
            stale.count += 1;
        }
    }
    return stale;
}

test reads_stale {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Process 2 reads 40 before its append is acknowledged (a dirty read, allowed), process 3
    // misses it after (stale), process 4's read began before the acknowledgment (allowed).
    const history =
        \\{"process":1,"type":"invoke","f":"txn","time":10,"value":[["append",7,40]]}
        \\{"process":2,"type":"invoke","f":"txn","time":11,"value":[["r",7,null]]}
        \\{"process":2,"type":"ok","f":"txn","time":12,"value":[["r",7,[40]]]}
        \\{"process":4,"type":"invoke","f":"txn","time":13,"value":[["r",7,null]]}
        \\{"process":1,"type":"ok","f":"txn","time":14,"value":[["append",7,40]]}
        \\{"process":4,"type":"ok","f":"txn","time":15,"value":[["r",7,[]]]}
        \\{"process":3,"type":"invoke","f":"txn","time":16,"value":[["r",7,null]]}
        \\{"process":3,"type":"ok","f":"txn","time":17,"value":[["r",7,[]]]}
        \\
    ;
    const stale = try reads_stale(arena.allocator(), history);
    try std.testing.expectEqual(@as(u32, 3), stale.reads);
    try std.testing.expectEqual(@as(u32, 1), stale.count);
    try std.testing.expectEqual(@as(u64, 40), stale.first[0].value);
    try std.testing.expectEqual([2]u64{ 16, 17 }, stale.first[0].read_ns);
}

/// What Elle lists among anomaly types that is none: its cycle search giving up on a large
/// history (run 177, beside G0 in timelines 157 and 172).
const not_anomalies = [_][]const u8{"cycle-search-timeout"};

/// Whether every anomaly type found is one of `allowed` (or no anomaly: not_anomalies).
fn allowed_only(found: []const []const u8, allowed: []const []const u8) bool {
    for (found) |kind| {
        const none = for (not_anomalies) |name| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        if (none) continue;
        const listed = for (allowed) |name| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        if (!listed) return false;
    }
    return true;
}

test allowed_only {
    try std.testing.expect(allowed_only(&.{"G0"}, &.{"G0"}));
    try std.testing.expect(!allowed_only(&.{ "G0", "G1a" }, &.{"G0"}));
    try std.testing.expect(!allowed_only(&.{"G1c"}, &.{}));
    try std.testing.expect(allowed_only(&.{ "G0", "cycle-search-timeout" }, &.{"G0"}));
    try std.testing.expect(!allowed_only(&.{ "G1c", "cycle-search-timeout" }, &.{"G0"}));
}

pub const Verdict = struct {
    /// Null: Elle could not tell (too little to go on).
    valid: ?bool,
    anomaly_types: []const []const u8,
    ops: u64,
    /// As Elle prints them.
    anomalies: []const u8,
    /// When the anomalies formed: the earliest and latest time (the guest's clock) of the
    /// operations they name; after it, the failure is decided (causality looks before it).
    window_ns: ?[2]u64 = null,
};

/// Elle's verdict on a history (JSON lines), from the service on the host.
pub fn judge(
    context: *sdk.Check,
    history: []const u8,
    model: []const u8,
    consistency: []const u8,
    linearizable_keys: bool,
) !Verdict {
    var path_buffer: [224]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/check?model={s}&consistency={s}{s}", .{
        model, consistency, if (linearizable_keys) "&linearizable_keys=true" else "",
    });
    const buffer = try context.arena.alloc(u8, tcp.buffer_size);
    // The service replaced while it checked this history (another version's check started its
    // own): checked again by the one that answers now.
    const response = for (0..judge_attempts_max) |attempt| {
        try service_ensure(context);
        break tcp.http_with(address, port, "POST", path, history, buffer, .{
            .timeout_ms = timeout_ms,
        }) catch |err| switch (err) {
            error.ConnectFailed, error.ConnectionClosed => {
                if (attempt + 1 == judge_attempts_max) return err;
                std.debug.print("elle: the service went away ({t}): again\n", .{err});
                const pause: linux.timespec = .{ .sec = judge_retry_pause_s, .nsec = 0 };
                _ = linux.nanosleep(&pause, null);
                continue;
            },
            else => return err,
        };
    } else unreachable;
    const Answer = struct {
        valid: std.json.Value = .null,
        anomaly_types: []const []const u8 = &.{},
        ops: u64 = 0,
        anomalies: []const u8 = "",
        window_ns: ?[2]u64 = null,
        @"error": []const u8 = "",
    };
    const answer = try std.json.parseFromSliceLeaky(Answer, context.arena, response.body, .{
        .ignore_unknown_fields = true,
    });
    if (response.status != 200) {
        std.debug.print("elle: {s}\n", .{answer.@"error"});
        return error.ElleFailed;
    }
    return .{
        .valid = if (answer.valid == .bool) answer.valid.bool else null,
        .anomaly_types = answer.anomaly_types,
        .ops = answer.ops,
        .anomalies = answer.anomalies,
        .window_ns = answer.window_ns,
    };
}

/// The service answers, or is started (built from checkers/elle with podman, relative to where
/// determinismo runs): once per host, whichever check gets the lock first.
fn service_ensure(context: *sdk.Check) !void {
    if (service_state() == .current) return;
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const lock = linux.open(start_lock, flags, 0o600);
    if (linux.errno(lock) != .SUCCESS) return error.LockFailed;
    defer _ = linux.close(@intCast(lock));
    while (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX)) == .INTR) {}
    // Busy (checking another run's history, a JVM's collection): it answers in time, and is
    // never replaced for being slow, which closed the histories it was checking (run 200's
    // timeline 151, srv3 2026-10-29: "ConnectionClosed").
    for (0..busy_waits_max) |_| {
        switch (service_state()) {
            .current => return, // Another check started it meanwhile.
            .busy => {
                const pause: linux.timespec = .{ .sec = 1, .nsec = 0 };
                _ = linux.nanosleep(&pause, null);
            },
            .absent, .other => break,
        }
    } else return error.ElleBusy;
    std.debug.print("elle: starting the service on port {d} ({s})\n", .{ port, dockerfile });
    try command(context, &.{ "podman", "build", "-q", "-t", image, "-f", dockerfile, "." });
    _ = std.process.run(context.arena, context.io, .{ .argv = &.{ "podman", "rm", "-f", image } }) catch {};
    try command(context, &.{ "podman", "run", "-d", "--name", image, "--network", "host", image });
    for (0..120) |_| {
        if (service_state() == .current) return;
        const pause: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&pause, null);
    }
    return error.ElleNotAnswering;
}

/// A history sent again after the service went away mid-check, each time after a pause: a
/// service being replaced (a deploy, another version's check) closes every connection it held,
/// and three attempts in a row met it closing (hunt run 1206 timeline 65, "host checks run to
/// completion" failing on our own restart of the service).
const judge_attempts_max = 10;
const judge_retry_pause_s = 2;
/// How long a check waits for a busy service (seconds) before it gives up.
const busy_waits_max = 600;

/// The service as a check finds it: this version (checkers/elle's `version`) answering; another
/// version, or none listening (replaced or started: podman rm -f, then run); or listening but
/// slow to answer (busy: waited for, never replaced).
const ServiceState = enum { current, other, absent, busy };

fn service_state() ServiceState {
    return service_state_at(port);
}

fn service_state_at(at: u16) ServiceState {
    var buffer: [4096]u8 = undefined;
    const response = tcp.http_with(address, at, "GET", "/version", "", &buffer, .{ .timeout_ms = 2000 }) catch |err| {
        return if (err == error.ConnectFailed) .absent else .busy;
    };
    const current = response.status == 200 and
        std.mem.indexOf(u8, response.body, "\"version\":\"" ++ service_version ++ "\"") != null;
    return if (current) .current else .other;
}

/// checkers/elle/src/elle_service.clj's `version`.
const service_version = "5";

fn command(context: *sdk.Check, argv: []const []const u8) !void {
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv });
    if (!result.term.success()) {
        std.debug.print("elle: {s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.ToolFailed;
    }
}

/// A micro-operation. In an invocation reads have no value yet (null); in an `ok`, what they
/// saw (null for a key never written, in rw-register).
pub const Mop = union(enum) {
    append: struct { key: u64, value: u64 },
    read: struct { key: u64, list: ?[]const u64 = null },
    write: struct { key: u64, value: u64 },
    read_register: struct { key: u64, value: ?u64 = null },
    /// closed-predicate: the universe's first state, one key each (an `init` operation, all of
    /// whose micro-operations are these).
    init: struct { key: u64, value: u64 },
    insert: struct { key: u64, value: u64 },
    delete: struct { key: u64 },
    /// Every row matching `predicate`: its key and value (null in an invocation).
    read_predicate: struct { predicate: Predicate, rows: ?[]const [2]u64 = null },
};

/// closed-predicate's predicates over a row's value (Elle's :true, [:= a], [:mod a b]).
pub const Predicate = union(enum) {
    all,
    equal: u64,
    /// value mod [0] = [1].
    modulo: [2]u64,
};

pub const Kind = enum { invoke, ok, fail, info };

/// A process id for Elle: a driver takes a new one after an unknown outcome.
pub fn process_new() u64 {
    return sdk.random_below(1 << 48);
}

/// A history's size at most, below the host's check buffer (src/checks.zig's input_size_max,
/// 512 MiB): past it no transaction starts (`invoke` answers error.HistoryFull, a command ending
/// on it ends well: System.run), its outcomes still written. kvrocks' 20-minute timelines grew
/// histories past the buffer and went unjudged (hunt run 1969, 12 timelines), as Valkey's,
/// Turso's and FoundationDB's before (docs/PLAN.md, "Unjudged Elle histories").
pub const history_size_max: u64 = 448 << 20;

/// The guest's own room too: its records are a tmpfs in its memory (guest/runtime/init.zig),
/// every byte of a history taken from the nodes. An eighth of the guest's memory at most: a
/// 2 GiB guest's history 256 MiB (kvrocks' append driver failed its writes at 708 s, the tmpfs
/// full, hunt run 1969's timeline 184). Read once (/proc/meminfo's MemTotal).
var guest_cap_bytes: ?u64 = null;

/// Set by System.run for a command that is no driver (first, eventually, finally): its
/// invocations are never refused at the cap, its reads judging however large the history grew.
pub var cap_off = false;

fn guest_cap() u64 {
    if (guest_cap_bytes) |cap| return cap;
    var cap: u64 = history_size_max;
    const fd = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) == .SUCCESS) {
        defer _ = linux.close(@intCast(fd));
        var buffer: [256]u8 = undefined;
        const size = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) == .SUCCESS) {
            const text = buffer[0..size];
            if (std.mem.indexOf(u8, text, "MemTotal:")) |at| {
                var words = std.mem.tokenizeScalar(u8, text[at + "MemTotal:".len ..], ' ');
                if (words.next()) |kib| {
                    if (std.fmt.parseInt(u64, kib, 10)) |total_kib| cap = @min(cap, total_kib * 1024 / 8) else |_| {}
                }
            }
        }
    }
    guest_cap_bytes = cap;
    return cap;
}

/// The history, as records of the check named "elle" (sdk.record's file): `History.of("other")`
/// for a check of another name.
pub const History = struct {
    path: [:0]const u8 = schema.record_path("elle"),
    size_max: u64 = history_size_max,
    /// False for the judgment's own reads (final_reads): never refused at the cap, a lost append
    /// judged however large the history grew.
    capped: bool = true,

    pub fn of(comptime name: []const u8) History {
        return .{ .path = schema.record_path(name) };
    }

    pub fn invoke(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .invoke, mops);
    }
    pub fn ok(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .ok, mops);
    }
    pub fn fail(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .fail, mops);
    }
    pub fn info(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .info, mops);
    }

    /// A line whose micro-operations are JSON already (`[["append",3,17],["r",4,null]]`): what
    /// programs in other languages note through libdeterminismo.
    pub fn note_json(history: *const History, gpa: std.mem.Allocator, process: u64, kind: Kind, mops: []const u8) !void {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        const now = time_ns();
        try line_begin(&line.writer, process, kind, now);
        try line.writer.writeAll(mops);
        try line.writer.writeAll("}\n");
        sdk.record_line(history.path, line.written());
        operations_note(process, kind, now, 0);
    }

    /// One line, appended with one write.
    pub fn note(
        history: *const History,
        gpa: std.mem.Allocator,
        process: u64,
        kind: Kind,
        mops: []const Mop,
    ) !void {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        const now = time_ns();
        try line_write(&line.writer, process, kind, mops, now);
        const bytes = line.written();
        defer operations_note(process, kind, now, longest_read(mops));
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
        const fd = linux.open(history.path, flags, 0o644);
        if (linux.errno(fd) != .SUCCESS) return error.HistoryOpen;
        defer _ = linux.close(@intCast(fd));
        if (kind == .invoke and history.capped and !cap_off) {
            const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
            if (linux.errno(end) == .SUCCESS and @as(u64, @intCast(end)) + bytes.len > @min(history.size_max, guest_cap())) return error.HistoryFull;
        }
        const written = linux.write(@intCast(fd), bytes.ptr, bytes.len);
        if (linux.errno(written) != .SUCCESS or written != bytes.len) return error.HistoryWrite;
    }
};

/// What a driver's operations looked like, as a few ordinary numbers in the workload's events
/// (learned ranges score their highest and lowest: 99147d05): each window of `window_size`
/// outcomes, the slowest operation (its invocation to its outcome, virtual time), the longest list
/// a read returned, and the outcomes left unknown. Workloads reported almost no numbers of their
/// own (rqlite's only workload event had none: run 1867), so ranges had nothing to learn from.
pub const Window = struct {
    pub const size = 256;
    const pending_max = 64;
    pending_process: [pending_max]u64 = @splat(0),
    pending_time: [pending_max]u64 = @splat(0),
    completed: u32 = 0,
    slowest_ns: u64 = 0,
    longest_read: u64 = 0,
    unknown: u32 = 0,

    pub const Summary = struct { slowest_ms: u64, longest_read: u64, unknown: u32 };

    /// A recorded line: an invocation remembered, an outcome timed; a full window's summary.
    pub fn note(window: *Window, process: u64, kind: Kind, now: u64, read_length: u64) ?Summary {
        if (process == 0) return null; // 0 marks a free slot.
        if (kind == .invoke) {
            const slot = window.slot_of(process) orelse window.slot_of(0) orelse
                (process % pending_max); // Full: an older invocation's slot reused.
            window.pending_process[slot] = process;
            window.pending_time[slot] = now;
            return null;
        }
        if (window.slot_of(process)) |slot| {
            window.slowest_ns = @max(window.slowest_ns, now -| window.pending_time[slot]);
            window.pending_process[slot] = 0;
        }
        window.longest_read = @max(window.longest_read, read_length);
        window.unknown += @intFromBool(kind == .info);
        window.completed += 1;
        if (window.completed < size) return null;
        return window.flush();
    }

    /// What the window holds, if any outcome: a driver's start ends with it (system.zig's run), a
    /// process doing a few operations each start (rqlite's: 9,707 starts in trial run 1884, no
    /// window ever full).
    pub fn flush(window: *Window) ?Summary {
        if (window.completed == 0) return null;
        const summary: Summary = .{
            .slowest_ms = window.slowest_ns / std.time.ns_per_ms,
            .longest_read = window.longest_read,
            .unknown = window.unknown,
        };
        window.completed = 0;
        window.slowest_ns = 0;
        window.longest_read = 0;
        window.unknown = 0;
        return summary;
    }

    fn slot_of(window: *const Window, process: u64) ?usize {
        return std.mem.indexOfScalar(u64, &window.pending_process, process);
    }
};

var operations_window: Window = .{};
var operations_lock: std.atomic.Mutex = .unlocked;

fn operations_note(process: u64, kind: Kind, now: u64, read_length: u64) void {
    while (!operations_lock.tryLock()) {
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    const summary = operations_window.note(process, kind, now, read_length);
    operations_lock.unlock();
    if (summary) |values| sdk.event("elle_operations", values);
}

/// A driver's start ended (system.zig): its window's outcomes said, however few.
pub fn operations_flush() void {
    while (!operations_lock.tryLock()) {
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    const summary = operations_window.flush();
    operations_lock.unlock();
    if (summary) |values| sdk.event("elle_operations", values);
}

fn longest_read(mops: []const Mop) u64 {
    var longest: u64 = 0;
    for (mops) |mop| switch (mop) {
        .read => |read| if (read.list) |list| {
            longest = @max(longest, list.len);
        },
        .read_predicate => |read| if (read.rows) |rows| {
            longest = @max(longest, rows.len);
        },
        else => {},
    };
    return longest;
}

test Window {
    var window: Window = .{};
    // 255 quick operations, then one slow with a long read and one unknown outcome among them.
    for (0..Window.size - 1) |index| {
        const process: u64 = 1 + index % 7;
        try std.testing.expectEqual(@as(?Window.Summary, null), window.note(process, .invoke, index * 10, 0));
        const kind: Kind = if (index == 3) .info else .ok;
        try std.testing.expectEqual(@as(?Window.Summary, null), window.note(process, kind, index * 10 + 2_000_000, 1));
    }
    _ = window.note(9, .invoke, 5_000_000_000, 0);
    const summary = window.note(9, .ok, 5_000_000_000 + 750 * std.time.ns_per_ms, 40).?;
    try std.testing.expectEqual(@as(u64, 750), summary.slowest_ms);
    try std.testing.expectEqual(@as(u64, 40), summary.longest_read);
    try std.testing.expectEqual(@as(u32, 1), summary.unknown);
    // The next window starts afresh.
    try std.testing.expectEqual(@as(?Window.Summary, null), window.note(9, .invoke, 0, 0));
    // A start ending with a part of a window says it; an empty one says nothing.
    _ = window.note(9, .ok, 3 * std.time.ns_per_ms, 0);
    try std.testing.expectEqual(@as(u64, 3), window.flush().?.slowest_ms);
    try std.testing.expectEqual(@as(?Window.Summary, null), window.flush());
}

/// Each key's committed appends, from a history's `ok` lines, in the order keys first appear.
pub const Committed = std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(u64));

/// The appends `history` says committed (none when nothing was recorded).
/// Read line by line, each line parsed in a scratch arena of its own, reset after it: the
/// result's memory is the committed appends alone (a long timeline's whole history held at
/// once, its reads' lists and every line's JSON tree, took the final reads to 1.7 GB of a 2 GB
/// guest: Turso's hunt run 1192, OOM-killed in 31 timelines).
pub fn appends_committed(gpa: std.mem.Allocator, history: *const History) !Committed {
    var committed: Committed = .empty;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const fd = linux.open(history.path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) == .NOENT) return committed;
    if (linux.errno(fd) != .SUCCESS) return error.HistoryOpen;
    defer _ = linux.close(@intCast(fd));
    // The line being read, across reads (a read's list can outgrow any buffer).
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.page_allocator);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(count) == .INTR) continue;
        if (linux.errno(count) != .SUCCESS) return error.HistoryRead;
        if (count == 0) break;
        var rest: []const u8 = buffer[0..count];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
            try line.appendSlice(std.heap.page_allocator, rest[0..end]);
            try appends_line(gpa, &scratch, line.items, &committed);
            line.clearRetainingCapacity();
            rest = rest[end + 1 ..];
        }
        try line.appendSlice(std.heap.page_allocator, rest);
    }
    try appends_line(gpa, &scratch, line.items, &committed);
    return committed;
}

/// `appends_committed`'s, from a history's text.
pub fn appends_parse(gpa: std.mem.Allocator, text: []const u8) !Committed {
    var committed: Committed = .empty;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try appends_line(gpa, &scratch, line, &committed);
    return committed;
}

/// One history line's committed appends into `committed` (gpa's), its JSON in `scratch` until
/// it returns.
fn appends_line(gpa: std.mem.Allocator, scratch: *std.heap.ArenaAllocator, line: []const u8, committed: *Committed) !void {
    defer _ = scratch.reset(.retain_capacity);
    if (line.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch
        return error.BadHistory;
    if (parsed != .object) return error.BadHistory;
    const kind = parsed.object.get("type") orelse return error.BadHistory;
    if (kind != .string or !std.mem.eql(u8, kind.string, "ok")) return;
    const mops = parsed.object.get("value") orelse return error.BadHistory;
    if (mops != .array) return error.BadHistory;
    for (mops.array.items) |mop| {
        if (mop != .array or mop.array.items.len != 3) continue;
        const f = mop.array.items[0];
        if (f != .string or !std.mem.eql(u8, f.string, "append")) continue;
        const key = mop.array.items[1];
        const value = mop.array.items[2];
        if (key != .integer or value != .integer) return error.BadHistory;
        const entry = try committed.getOrPut(gpa, @intCast(key.integer));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, @intCast(value.integer));
    }
}

/// Lost appends asserted one by one; past these, counted in an event.
const lost_reported_max = 8;

/// Once faults stop (a `finally` command, the drivers done): every append the history says
/// committed must be in its key's list as `reader` reads it, `reader.read_list(gpa, key)`: the
/// list, or null once it can read no more (a cluster may wait for an operator, as Galera does
/// after losing every node), the rest of the keys then unjudged. A lost append fails "every
/// committed append is in the final read"; each read goes into the history, for Elle. Elle below
/// strict serializability takes a read missing a committed append for an older snapshot, and a
/// workload's own reads may never read a key again (a committed row lost in one run, Elle's 58
/// operations none the wiser).
pub fn final_reads(gpa: std.mem.Allocator, history_given: *const History, reader: anytype) !void {
    // Past the history's cap too: these reads are the judgment (a capped history's drivers
    // stopped; its final reads must not).
    var uncapped = history_given.*;
    uncapped.capped = false;
    const history = &uncapped;
    const committed = try appends_committed(gpa, history);
    if (committed.count() == 0) return;
    var judged: u32 = 0;
    var lost: u32 = 0;
    for (committed.keys(), committed.values()) |key, values| {
        const asked = [_]Mop{.{ .read = .{ .key = key, .list = null } }};
        const process = process_new();
        try history.invoke(gpa, process, &asked);
        const seen = reader.read_list(gpa, key) orelse {
            try history.fail(gpa, process, &asked);
            break; // Out of attempts: the rest unjudged.
        };
        try history.ok(gpa, process, &.{.{ .read = .{ .key = key, .list = seen } }});
        judged += 1;
        for (values.items) |value| {
            if (std.mem.indexOfScalar(u64, seen, value) != null) continue;
            lost += 1;
            if (lost > lost_reported_max) continue;
            sdk.always(false, "every committed append is in the final read", .{
                .key = key,
                .value = value,
                .read = seen.len,
                .committed = values.items.len,
            });
        }
    }
    sdk.sometimes(judged > 0, "the final reads reach a node once faults stop", .{
        .keys = committed.count(),
        .judged = judged,
    });
    if (judged > 0 and lost == 0) {
        sdk.always(true, "every committed append is in the final read", .{ .keys = judged });
    }
    if (lost > lost_reported_max) sdk.event("final_reads_lost", .{ .lost = lost, .keys = judged });
}

/// The guest's clock (virtual, the same in every replay): when an operation was recorded, which
/// Elle reports with the operations of an anomaly (the window the anomaly formed in).
fn time_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// `{"process":7,"type":"ok","f":"txn","time":5000000,"value":[["append",3,17],["r",4,[2,9]]]}`
/// and a newline.
pub fn line_write(writer: *std.Io.Writer, process: u64, kind: Kind, mops: []const Mop, time: u64) !void {
    const f = if (mops.len > 0 and mops[0] == .init) "init" else "txn";
    for (mops) |mop| assert((mop == .init) == std.mem.eql(u8, f, "init"));
    try line_begin_f(writer, process, kind, f, time);
    try writer.writeByte('[');
    for (mops, 0..) |mop, index| {
        if (index > 0) try writer.writeByte(',');
        switch (mop) {
            .append => |a| try writer.print("[\"append\",{d},{d}]", .{ a.key, a.value }),
            .write => |w| try writer.print("[\"w\",{d},{d}]", .{ w.key, w.value }),
            .read => |r| {
                try writer.print("[\"r\",{d},", .{r.key});
                if (r.list) |list| {
                    try writer.writeByte('[');
                    for (list, 0..) |value, at| {
                        if (at > 0) try writer.writeByte(',');
                        try writer.print("{d}", .{value});
                    }
                    try writer.writeAll("]]");
                } else try writer.writeAll("null]");
            },
            .read_register => |r| {
                if (r.value) |value| {
                    try writer.print("[\"r\",{d},{d}]", .{ r.key, value });
                } else try writer.print("[\"r\",{d},null]", .{r.key});
            },
            .init => |i| try writer.print("[\"init\",{d},{d}]", .{ i.key, i.value }),
            .insert => |i| try writer.print("[\"insert\",{d},{d}]", .{ i.key, i.value }),
            .delete => |d| try writer.print("[\"delete\",{d},null]", .{d.key}),
            .read_predicate => |r| {
                try writer.writeAll("[\"rp\",");
                switch (r.predicate) {
                    .all => try writer.writeAll("\"true\""),
                    .equal => |a| try writer.print("[\"=\",{d}]", .{a}),
                    .modulo => |m| try writer.print("[\"mod\",{d},{d}]", .{ m[0], m[1] }),
                }
                if (r.rows) |rows| {
                    try writer.writeAll(",[");
                    for (rows, 0..) |row, at| {
                        if (at > 0) try writer.writeByte(',');
                        try writer.print("[{d},{d}]", .{ row[0], row[1] });
                    }
                    try writer.writeAll("]]");
                } else try writer.writeAll(",null]");
            },
        }
    }
    try writer.writeAll("]}\n");
}

/// A line up to its value.
fn line_begin(writer: *std.Io.Writer, process: u64, kind: Kind, time: u64) !void {
    return line_begin_f(writer, process, kind, "txn", time);
}

fn line_begin_f(writer: *std.Io.Writer, process: u64, kind: Kind, f: []const u8, time: u64) !void {
    try writer.print("{{\"process\":{d},\"type\":\"{s}\",\"f\":\"{s}\",\"time\":{d},\"value\":", .{
        process, @tagName(kind), f, time,
    });
}

test appends_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const history =
        \\{"process":1,"type":"invoke","f":"txn","time":1,"value":[["append",7,70],["r",8,null]]}
        \\{"process":1,"type":"ok","f":"txn","time":2,"value":[["append",7,70],["r",8,[1]]]}
        \\{"process":2,"type":"info","f":"txn","time":3,"value":[["append",7,71]]}
        \\{"process":3,"type":"fail","f":"txn","time":4,"value":[["append",9,90]]}
        \\{"process":4,"type":"ok","f":"txn","time":5,"value":[["append",9,91],["append",7,72]]}
        \\
    ;
    const committed = try appends_parse(arena.allocator(), history);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, committed.keys());
    try std.testing.expectEqualSlices(u64, &.{ 70, 72 }, committed.get(7).?.items);
    try std.testing.expectEqualSlices(u64, &.{91}, committed.get(9).?.items);
    try std.testing.expectError(error.BadHistory, appends_parse(arena.allocator(), "{\"type\":\"ok\"}\n"));
}

test "appends_parse: its memory is the committed appends, not the history's" {
    // 2,000 transactions each reading a list of 300 values: every line's JSON tree held at once
    // outgrew the guest (Turso's hunt run 1192: the final reads at 1.7 GB of a 2 GB guest,
    // OOM-killed in 31 timelines). A line's tree lives until the next line's only.
    const testing = std.testing;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..2000) |index| {
        try text.print(testing.allocator, "{{\"process\":1,\"type\":\"ok\",\"f\":\"txn\",\"time\":{d}," ++
            "\"value\":[[\"append\",{d},{d}],[\"r\",1,[", .{ index, index % 10, index });
        for (0..300) |value| {
            if (value > 0) try text.append(testing.allocator, ',');
            try text.print(testing.allocator, "{d}", .{value});
        }
        try text.appendSlice(testing.allocator, "]]]}\n");
    }
    var memory: [256 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const committed = try appends_parse(fixed.allocator(), text.items);
    try testing.expectEqual(@as(usize, 10), committed.count());
    try testing.expectEqual(@as(usize, 200), committed.get(3).?.items.len);
}

test line_write {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const asked = [_]Mop{ .{ .append = .{ .key = 3, .value = 17 } }, .{ .read = .{ .key = 4 } } };
    try line_write(&writer, 7, .invoke, &asked, 5);
    const done = [_]Mop{ asked[0], .{ .read = .{ .key = 4, .list = &.{ 2, 9 } } } };
    try line_write(&writer, 7, .ok, &done, 9);
    const registers = [_]Mop{
        .{ .write = .{ .key = 1, .value = 5 } },
        .{ .read_register = .{ .key = 2 } },
        .{ .read_register = .{ .key = 1, .value = 5 } },
    };
    try line_write(&writer, 8, .info, &registers, 12);
    try std.testing.expectEqualStrings(
        \\{"process":7,"type":"invoke","f":"txn","time":5,"value":[["append",3,17],["r",4,null]]}
        \\{"process":7,"type":"ok","f":"txn","time":9,"value":[["append",3,17],["r",4,[2,9]]]}
        \\{"process":8,"type":"info","f":"txn","time":12,"value":[["w",1,5],["r",2,null],["r",1,5]]}
        \\
    , writer.buffered());
}

test "line_write: closed-predicate" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try line_write(&writer, 1, .ok, &.{ .{ .init = .{ .key = 1, .value = 0 } }, .{ .init = .{ .key = 2, .value = 1 } } }, 3);
    const done = [_]Mop{
        .{ .insert = .{ .key = 3, .value = 4 } },
        .{ .delete = .{ .key = 2 } },
        .{ .read_predicate = .{ .predicate = .{ .modulo = .{ 2, 0 } }, .rows = &.{ .{ 1, 0 }, .{ 3, 4 } } } },
        .{ .read_predicate = .{ .predicate = .all } },
        .{ .read_predicate = .{ .predicate = .{ .equal = 1 }, .rows = &.{} } },
    };
    try line_write(&writer, 2, .ok, &done, 5);
    try std.testing.expectEqualStrings(
        \\{"process":1,"type":"ok","f":"init","time":3,"value":[["init",1,0],["init",2,1]]}
        \\{"process":2,"type":"ok","f":"txn","time":5,"value":[["insert",3,4],["delete",2,null],["rp",["mod",2,0],[[1,0],[3,4]]],["rp","true",null],["rp",["=",1],[]]]}
        \\
    , writer.buffered());
}

/// A listening socket on a port of the kernel's choosing (`listening`: accepted into its backlog,
/// never answered unless a thread does).
fn test_listener() !struct { fd: linux.fd_t, port: u16 } {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    var bound = linux.sockaddr.in{ .port = 0, .addr = @bitCast(address) };
    if (linux.errno(linux.bind(fd, @ptrCast(&bound), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 4)) != .SUCCESS) return error.ListenFailed;
    var size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(fd, @ptrCast(&bound), &size);
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound.port) };
}

fn test_answer(fd: linux.fd_t, body: []const u8) void {
    const accepted = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(accepted) != .SUCCESS) return;
    const client: linux.fd_t = @intCast(accepted);
    defer _ = linux.close(client);
    var request: [1024]u8 = undefined;
    _ = linux.read(client, &request, request.len);
    var response: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{
        body.len, body,
    }) catch return;
    _ = linux.write(client, text.ptr, text.len);
}

test service_state_at {
    // Nobody listening: absent (replaced or started).
    const gone = try test_listener();
    _ = linux.close(gone.fd);
    try std.testing.expectEqual(ServiceState.absent, service_state_at(gone.port));
    // Listening, never answering in time (a long check on its one thread, run 200): busy, waited
    // for, never replaced.
    const busy = try test_listener();
    defer _ = linux.close(busy.fd);
    try std.testing.expectEqual(ServiceState.busy, service_state_at(busy.port));
    // Answering: this version, or another.
    for ([_]struct { []const u8, ServiceState }{
        .{ "{\"version\":\"" ++ service_version ++ "\"}", .current },
        .{ "{\"version\":\"1\"}", .other },
    }) |case| {
        const answering = try test_listener();
        defer _ = linux.close(answering.fd);
        const thread = try std.Thread.spawn(.{}, test_answer, .{ answering.fd, case[0] });
        defer thread.join();
        try std.testing.expectEqual(case[1], service_state_at(answering.port));
    }
}

test "a history past its cap starts no transaction, its outcomes still written" {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/elle-cap-{d}.jsonl", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);
    _ = linux.unlink(path);
    const history: History = .{ .path = path, .size_max = 400 };
    const gpa = std.testing.allocator;
    const mops = [_]Mop{.{ .append = .{ .key = 1, .value = 7 } }};
    var invoked: u32 = 0;
    while (true) : (invoked += 1) {
        history.invoke(gpa, 1, &mops) catch |err| {
            try std.testing.expectEqual(error.HistoryFull, err);
            break;
        };
        if (invoked > 100) return error.NeverFull;
    }
    try std.testing.expect(invoked > 0);
    // Past the cap, an invoked transaction's outcome is written still.
    try history.ok(gpa, 1, &mops);
    try history.info(gpa, 1, &mops);
    // The judgment's own reads are never refused (final_reads).
    var uncapped = history;
    uncapped.capped = false;
    try uncapped.invoke(gpa, 2, &.{.{ .read = .{ .key = 1, .list = null } }});
}
