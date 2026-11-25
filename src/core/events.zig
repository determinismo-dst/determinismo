// SPDX-License-Identifier: MIT
//! Events the guest emits through /dev/determinismo: logs, lifecycle and assertions. Each one is
//! stamped with its moment and appended to a JSONL log; assertions roll up into properties.
//!
//! No allocation: properties live in a fixed table, and JSON parsing uses a buffer the caller
//! reserves once at startup (`parse_buffer_size`) and that is reset for every event.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

/// A timeline's properties: a CI shard's tests are each one (a run's whole, every shard's, is
/// report.zig's aggregate_count_max). Events lives on stacks in tests: 4,096 is 1.8 MB.
pub const property_count_max = 4096;
pub const message_size_max = 192;
pub const parse_buffer_size = 256 * 1024;

pub const Moment = struct { vtime_ns: u64, branches: u64 };

pub const Kind = enum { always, always_or_unreachable, sometimes, reachable, @"unreachable" };

pub const Property = struct {
    kind: Kind,
    message: [message_size_max]u8,
    message_size: u8,
    hits: u64 = 0,
    trues: u64 = 0,
    first_failure: ?Moment = null,
    /// Where the assertion is in the code ("file:line function"), from the first event (or
    /// catalog entry) that said; empty when none did.
    location: [location_size_max]u8 = undefined,
    location_size: u8 = 0,

    pub fn where(property: *const Property) []const u8 {
        return property.location[0..property.location_size];
    }

    pub fn name(property: *const Property) []const u8 {
        assert(property.message_size > 0);
        assert(property.message_size <= message_size_max);
        return property.message[0..property.message_size];
    }

    /// Whether this timeline violates the property: an `always` that was false, an
    /// `unreachable` that was reached. `sometimes` and `reachable` (and an `always` never hit)
    /// are about the whole multiverse, as in Antithesis: no single timeline violates them
    /// (report.property_failing judges them across branches).
    pub fn passing(property: *const Property) bool {
        assert(property.trues <= property.hits);
        return switch (property.kind) {
            .always, .always_or_unreachable => property.trues == property.hits,
            .@"unreachable" => property.hits == 0,
            .sometimes, .reachable => true,
        };
    }
};

log_fd: ?linux.fd_t,
/// Events before this moment are not written (hashed and counted as ever): a timeline extending
/// another from a moment inherits what came before it, and its own file begins there.
log_from_ns: u64 = 0,
/// Output lines with one of these texts are not written (VM.Options.retroactive).
retroactive: []const []const u8 = &.{},
count: u64 = 0,
hash: std.hash.Wyhash = .init(0),
/// The hash of the guest's history, before the host checks' verdicts joined it (vm.zig): a
/// replay judged by other checkers has the same (replays.zig's "rejudged"). Null: no host check
/// ran, the guest's history is the whole.
guest_hash: ?u64 = null,
properties: [property_count_max]Property = undefined,
property_count: u32 = 0,
setup_complete: ?Moment = null,
/// The guest runtime reported the end of its scenario (it neither crashed nor hung).
guest_done: bool = false,
parse_buffer: []u8,
/// The `event` name of the most recent structured event (`{"event": name, ...}`), if any.
last_event_name: [32]u8 = undefined,
last_event_name_size: u8 = 0,
/// Output the nodes and commands printed, and since when (the first event seen): the logging
/// rate the "logging output" property checks.
output_bytes: u64 = 0,
/// That output by source (a node, a command, the kernel): what a failing logging property names
/// (report.zig). Two systems' were found by hand from the events (runs 806, 835).
output_sources: [output_sources_max]OutputSource = @splat(.{}),
output_source_count: u8 = 0,
first_vtime_ns: ?u64 = null,
/// When the guest began streaming its checks' inputs out (composer.zig's checks_stream: the
/// timeline's commands are over). A branch from later would hold only the rest of them.
checks_start_ns: ?u64 = null,
/// When its driver phase ended (det-composer's first `faults_phase` stop): what the timeline
/// spent after it is its ending's (faults stopped, eventually and finally commands), a cost the
/// explorer's Novelty measures.
drive_end_ns: ?u64 = null,
/// The first `doomed` event's moment (sdk.doomed): the explorer weighs returns after it down.
doomed_ns: ?u64 = null,
/// The latest event's moment.
last_vtime_ns: u64 = 0,
/// The behaviors this timeline reached (behavior_hash: an assertion with its outcome, an
/// event with its categorical details; and how close a guidance assertion came, by powers of
/// two), each with when it first did: where the tree explorer branches from (main.zig).
behaviors: [behavior_count_max]Behavior = undefined,
behavior_count: u32 = 0,
/// Behaviors new to this table it did not keep: past its first half, known to the tree or the
/// system's last runs (behavior_known); past its end, any (the table full). How full the tables
/// run, in each timeline's record (a Kafka hunt's first generation full of startup lines, run
/// 1887; the history's share, run 1919).
behaviors_known_skipped: u32 = 0,
behaviors_full_dropped: u32 = 0,
behavior_slots: [behavior_slot_count]u64 = @splat(0),
/// Each slot's behavior (its index in `behaviors`): a bucket seen again found at once (ranges
/// note one for every number an event carries).
behavior_slot_index: [behavior_slot_count]u16 = undefined,
/// The behaviors that name a node, first reached in this timeline (their hashes), and the newest
/// one's node: where a branch point aims its first fault (branch_node). Apart from what is kept
/// above, which past behavior_known_kept_max depends on what the tree knew in this process
/// (behaviors_seen) and so differs in a replay's: run 969's timeline 244 aimed at "kernel" from
/// a node maker's table and at "flecs" in every replay, which parted from its tape there.
named_slots: [behavior_slot_count]u64 = @splat(0),
named_count: u32 = 0,
newest_named: [behavior_node_size]u8 = undefined,
newest_named_size: u8 = 0,
/// The decisions announced (each name, how many times): announcements are hashed and counted,
/// not logged (emit), so their names are told once, in `decisions_announced` as the timeline
/// ends (announcements_log): which named decisions a timeline drew (an SDK's thread pausing,
/// the injector's), as the e2e pausing check asks.
announced: [announced_max]Announced = undefined,
announced_count: u8 = 0,
/// The checks' inputs (schema.Check), streamed out by the composer as the timeline ends:
/// decoded into `check_buffer` (the caller's, reserved once), one span per check.
check_buffer: []u8 = &.{},
check_used: usize = 0,
check_inputs: [check_count_max]CheckInput = @splat(.{}),

pub const check_count_max = 8;

pub const announced_max = 32;
pub const announced_name_max = 48;
pub const Announced = struct { name: [announced_name_max]u8 = undefined, size: u8 = 0, count: u32 = 0 };

/// A decision's name announced once more: counted under its name (names past the table's room,
/// longer than a slot or needing JSON escapes, not).
fn announced_note(events: *Events, name: []const u8) void {
    if (name.len == 0 or name.len > announced_name_max) return;
    for (name) |byte| if (byte == '"' or byte == '\\' or byte < 0x20) return;
    for (events.announced[0..events.announced_count]) |*entry| {
        if (std.mem.eql(u8, entry.name[0..entry.size], name)) {
            entry.count += 1;
            return;
        }
    }
    if (events.announced_count == announced_max) return;
    const entry = &events.announced[events.announced_count];
    entry.* = .{ .size = @intCast(name.len), .count = 1 };
    @memcpy(entry.name[0..name.len], name);
    events.announced_count += 1;
}

/// The names of the decisions announced and their counts, one `decisions_announced` event after
/// the timeline's last, logged, not hashed or counted (a replay's events compare as before): the
/// sequence it took, or the last event's when nothing was announced.
pub fn announcements_log(events: *const Events, moment: Moment) u64 {
    const fd = events.log_fd orelse return events.count;
    if (events.announced_count == 0) return events.count;
    var line_buffer: [announced_max * (announced_name_max + 16) + 64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&line_buffer);
    writer.writeAll("{\"event\":\"decisions_announced\",\"details\":{") catch unreachable;
    for (events.announced[0..events.announced_count], 0..) |entry, index| {
        writer.print("{s}\"{s}\":{d}", .{ if (index == 0) "" else ",", entry.name[0..entry.size], entry.count }) catch unreachable;
    }
    writer.writeAll("}}") catch unreachable;
    const sequence = events.count + 1;
    write_log_line(fd, .{ .sequence = sequence, .moment = moment, .data = writer.buffered(), .json = true });
    return sequence;
}

pub const CheckInput = struct {
    start: usize = 0,
    end: usize = 0,
    /// The composer said it was all sent (`check_input`), or that there was none.
    complete: bool = false,
    missing: bool = false,
    /// Larger than what was left of the buffer: not checkable.
    overflow: bool = false,
};

/// The node a branch point aims at (vm.branch_action_make): that of the newest behavior that
/// names one, first reached in this timeline. From the timeline's events alone, so a replay's
/// branch point says the same.
pub fn branch_node(events: *const Events) []const u8 {
    return events.newest_named[0..events.newest_named_size];
}

/// A behavior that names a node, first reached in this timeline (the table's own, at most half
/// full): the newest such node. Before what is kept is decided.
fn named_note(events: *Events, key: u64, node: []const u8) void {
    if (node.len == 0 or events.named_count == behavior_count_max) return;
    var slot = key % behavior_slot_count;
    while (events.named_slots[slot] != 0) : (slot = (slot + 1) % behavior_slot_count) {
        if (events.named_slots[slot] == key) return;
    }
    events.named_slots[slot] = key;
    events.named_count += 1;
    const size = @min(node.len, behavior_node_size);
    @memcpy(events.newest_named[0..size], node[0..size]);
    events.newest_named_size = @intCast(size);
}

/// What a timeline sent a check: its whole input; none (nothing sent, or the composer said there
/// was none); more than the buffer held; or a part, its end never said (the timeline ended in
/// the middle). The last two are a check that judges nothing although it had records.
pub const CheckState = union(enum) { input: []const u8, none, overflow, incomplete };

pub fn check_state(events: *const Events, index: usize) CheckState {
    if (index >= check_count_max) return .none;
    const input = events.check_inputs[index];
    if (input.overflow) return .overflow;
    if (input.complete) return if (input.missing) .none else .{ .input = events.check_buffer[input.start..input.end] };
    return if (input.end > input.start) .incomplete else .none;
}

test check_state {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var check_buffer: [8]u8 = undefined;
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null, .check_buffer = &check_buffer });
    const moment: Moment = .{ .vtime_ns = 1, .branches = 1 };
    // Check 0: whole ("abcd"). Check 1: more than the buffer's 8 bytes. Check 2: a part, its end
    // never said. Check 3: none sent. Check 4: the composer said there was none.
    try events.emit(moment, "{\"event\":\"check_chunk\",\"details\":{\"check\":0,\"data\":\"YWJjZA==\"}}");
    try events.emit(moment, "{\"event\":\"check_input\",\"details\":{\"check\":0,\"bytes\":4}}");
    try events.emit(moment, "{\"event\":\"check_chunk\",\"details\":{\"check\":1,\"data\":\"YWJjZGVmZ2hpams=\"}}");
    try events.emit(moment, "{\"event\":\"check_input\",\"details\":{\"check\":1,\"bytes\":11}}");
    try events.emit(moment, "{\"event\":\"check_chunk\",\"details\":{\"check\":2,\"data\":\"eHk=\"}}");
    try events.emit(moment, "{\"event\":\"check_input\",\"details\":{\"check\":4,\"missing\":true}}");
    try std.testing.expectEqualStrings("abcd", events.check_state(0).input);
    try std.testing.expectEqual(CheckState.overflow, events.check_state(1));
    try std.testing.expectEqual(CheckState.incomplete, events.check_state(2));
    try std.testing.expectEqual(CheckState.none, events.check_state(3));
    try std.testing.expectEqual(CheckState.none, events.check_state(4));
}

/// A check's whole input, once the composer sent it all; null when it never did (the timeline
/// ended first), there was none, or it did not fit.
pub fn check_input(events: *const Events, index: usize) ?[]const u8 {
    if (index >= check_count_max) return null;
    const input = events.check_inputs[index];
    if (!input.complete or input.missing or input.overflow) return null;
    return events.check_buffer[input.start..input.end];
}

const Events = @This();

pub const Behavior = struct {
    hash: u64,
    vtime_ns: u64,
    /// What it is, for people: `always "balance is conserved": false`, `fault partition`.
    label: [behavior_label_size]u8 = undefined,
    label_size: u8 = 0,
    /// The node it came from, when it says (a node's output, an event's `details.node`):
    /// where a branch from just after it aims its first fault (VM.Options.branch_signal).
    node_name: [behavior_node_size]u8 = undefined,
    node_size: u8 = 0,
    /// A `sometimes` or `reachable` assertion made true: a state its programmer marked as worth
    /// reaching, where the tree returns first (Antithesis restarts tests from where one is hit).
    sought: bool = false,
    /// A kind of output line that reads as trouble (an error, an exception, a timeout: see
    /// behavior_severe): a state the system itself marks as unusual, where the tree returns
    /// first too (`--no-prefer-severe`: as any other).
    severe: bool = false,
    /// An optimization's bucket (sdk.optimize): the best score this timeline reached in it
    /// (higher is better: a minimized value negated), `vtime_ns` when. The archive keeps each
    /// bucket's best state across timelines (Antithesis's Metroid exploration).
    score: ?f64 = null,

    pub fn name(behavior: *const Behavior) []const u8 {
        return behavior.label[0..behavior.label_size];
    }

    pub fn node(behavior: *const Behavior) []const u8 {
        return behavior.node_name[0..behavior.node_size];
    }
};
pub const behavior_node_size = 32;
pub const behavior_label_size = 72;
/// Room for instrumented programs' coverage (a Go service reports thousands of lines early on)
/// besides what comes after it.
pub const behavior_count_max = 8192;
/// Past this many, a behavior the tree already knows is not kept: the rest of the table is for
/// what is new to it. A system whose every timeline reports thousands of the same behaviors
/// early (Kafka's coverage) filled the table with them, and the tree saw nothing it reached
/// later (run 439's first generation: 48 timelines, 8,192 behaviors between them, the cap; its
/// second: none new, no moment returned to).
pub const behavior_known_kept_max = behavior_count_max / 2;

/// The behaviors the tree knew before this timeline's generation (main.zig's seen set, its
/// worker's copy): past behavior_known_kept_max, those are not kept. The process's, not a
/// snapshot's: a worker runs one timeline at a time.
pub var behaviors_seen: ?*const std.AutoHashMapUnmanaged(u64, void) = null;
/// The behaviors the system's last runs reached (serve's history, `--history`): known too where a
/// table decides what it keeps past its first half, never in what the tree counts new. A scenario
/// snapshotted before its nodes start (snapshot_before_nodes: Kafka's, XTDB's) has a setup that
/// reaches none of their startup coverage: its first generation's tables filled with the same
/// startup lines (run 1887: "8356 new (8356 known)"), which the system's earlier runs all reached.
pub var behaviors_history: ?*const std.AutoHashMapUnmanaged(u64, u32) = null;

/// Known where a table decides what it keeps: to the tree, or to the system's last runs.
fn behavior_known(known: ?*const std.AutoHashMapUnmanaged(u64, void), hash: u64) bool {
    if (known) |set| if (set.contains(hash)) return true;
    if (behaviors_history) |history| if (history.contains(hash)) return true;
    return false;
}
/// Every behavior noted while set, whatever the table keeps: the setup's (main.zig's
/// explore_snapshot), the tree's first known set. A timeline reaches what the setup did again
/// before anything of its own (each JVM's startup coverage at each restart: Pulsar's six, more
/// lines than a table holds); with nothing known, hunt run 1901's every table held the same
/// 8,192 startup lines, its first generation had nothing one timeline reached alone, and the
/// tree never returned (all 170 timelines from the setup snapshot, coverage on).
pub var behaviors_collected: ?*Collected = null;
pub const Collected = struct {
    allocator: std.mem.Allocator,
    set: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn note(collected: *Collected, key: u64) void {
        collected.set.put(collected.allocator, key, {}) catch @panic("out of memory collecting the setup's behaviors");
    }
};
/// Learned ranges on (explore's --no-ranges: off, for comparisons): ranges_note.
pub var ranges_on: bool = true;
/// The nodes' memory-growth objective counted (explore's --no-memory-objective: not, for
/// comparisons): the guest's sampler reports it always (guest/runtime/nodes.zig's
/// memory_growth_objective, the same message), and with it off the tree does not climb it.
pub var memory_objective_on: bool = true;
pub const memory_growth_objective = "a node's anonymous memory grows (MiB above its least)";
/// This timeline's draw over the range buckets, swarm testing's way (Groce et al.: a feature on
/// in every test hides the bugs it suppresses): from its seed, the share of buckets that count
/// (none, a quarter, ... all) and which ones. Set by the worker for each timeline.
pub var ranges_salt: u64 = 0;
const behavior_slot_count = 2 * behavior_count_max; // Open addressing, at most half full.

pub const InitOptions = struct {
    log_fd: ?linux.fd_t,
    /// Room for the checks' inputs (schema.Check), reserved once by the caller; empty: none.
    check_buffer: []u8 = &.{},
};

pub fn init(events: *Events, parse_buffer: []u8, options: InitOptions) void {
    if (options.log_fd) |fd| assert(fd >= 0);
    assert(parse_buffer.len == parse_buffer_size);
    events.* = .{
        .log_fd = options.log_fd,
        .parse_buffer = parse_buffer,
        .check_buffer = options.check_buffer,
    };
    assert(events.property_count == 0);
}

pub fn emit(events: *Events, moment: Moment, data: []const u8) !void {
    assert(data.len <= 4096);
    events.count += 1;
    if (events.first_vtime_ns == null) events.first_vtime_ns = moment.vtime_ns;
    events.last_vtime_ns = moment.vtime_ns;
    events.hash.update(std.mem.asBytes(&moment));
    events.hash.update(data);

    events.last_event_name_size = 0;
    // 64 times the largest event: a failure to parse is never for lack of room.
    var fba = std.heap.FixedBufferAllocator.init(events.parse_buffer);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), data, .{}) catch
        null;
    // Checks' inputs are the host's (they can be megabytes): hashed, not logged.
    const check_chunk = std.mem.startsWith(u8, data, "{\"event\":\"check_chunk\"");
    // A decision's announcement (`{"decision":{"name":...}}`, labelling the next pull): hashed
    // and counted, not logged. A fifth of a Raft run's 15.8 million events (run 1381), read by
    // nothing: a strategy is told them, and a strategy's answer logs its own decision event.
    const announcement = std.mem.startsWith(u8, data, "{\"decision\":");
    if (events.log_fd) |fd| if (moment.vtime_ns >= events.log_from_ns and !check_chunk and !announcement and !events.retroactive_hidden(data)) {
        write_log_line(fd, .{
            .sequence = events.count,
            .moment = moment,
            .data = data,
            .json = parsed != null,
        });
    };
    // Not JSON: logged as text (`{"raw": ...}`), but carries no properties.
    const value = parsed orelse return;
    if (value != .object) return;
    if (announcement) if (value.object.get("decision")) |decision| if (decision == .object) {
        if (decision.object.get("name")) |name| if (name == .string) events.announced_note(name.string);
    };
    if (value.object.get("event")) |name| {
        if (name == .string) {
            const checks = std.mem.eql(u8, name.string, "check_chunk") or
                std.mem.eql(u8, name.string, "check_input");
            if (checks and events.checks_start_ns == null) events.checks_start_ns = moment.vtime_ns;
            events.check_event(name.string, value.object.get("details"));
            if (events.doomed_ns == null and std.mem.eql(u8, name.string, "doomed")) events.doomed_ns = moment.vtime_ns;
            if (events.drive_end_ns == null and std.mem.eql(u8, name.string, "faults_phase")) {
                if (value.object.get("details")) |details| if (details == .object) {
                    if (details.object.get("state")) |state| if (state == .string and std.mem.eql(u8, state.string, "stop")) {
                        events.drive_end_ns = moment.vtime_ns;
                    };
                };
            }
        }
        if (name == .string and std.mem.eql(u8, name.string, "output_dropped")) {
            events.on_output_dropped(value.object.get("details"));
        }
        if (name == .string) {
            const size: u8 = @intCast(@min(name.string.len, events.last_event_name.len));
            @memcpy(events.last_event_name[0..size], name.string[0..size]);
            events.last_event_name_size = size;
        }
    }
    events.behavior_note(moment, value);
    if (value.object.get("lifecycle")) |lifecycle| events.on_lifecycle(moment, lifecycle);
    if (value.object.get("output")) |output| events.on_output(output);
    if (value.object.get("assert")) |assertion| try events.on_assert(moment, assertion);
    if (value.object.get("antithesis_assert")) |assertion| {
        try events.on_antithesis_assert(moment, assertion);
    }
    if (value.object.get("antithesis_setup")) |setup| {
        const status = if (setup == .object) string_field(setup.object, "status") else null;
        if (status != null and std.mem.eql(u8, status.?, "complete")) {
            events.on_lifecycle(moment, .{ .string = "setup_complete" });
        }
    }
}

/// Retroactive logging: an output line with a text it hides, not written while exploring.
fn retroactive_hidden(events: *const Events, data: []const u8) bool {
    if (events.retroactive.len == 0) return false;
    if (!std.mem.startsWith(u8, data, "{\"output\":")) return false;
    for (events.retroactive) |text| {
        if (std.mem.indexOf(u8, data, text) != null) return true;
    }
    return false;
}

/// Learned ranges (Fioraldi et al., "The Use of Likely Invariants as Feedback for Fuzzers",
/// USENIX Security 2021, its future work: learned online): each number a system's event carries
/// in its details (`{"event": "order", "details": {"latency_ms": 12}}`) is two buckets, its
/// highest and its lowest, scored as an optimization's (sdk.optimize). A timeline past the range
/// the tree has seen is a better state of the bucket, its place returned to anew: values unlike
/// the usual ones, where a state that code coverage cannot tell apart may hold its bug (a
/// libsndfile overflow reached by every fuzzer, triggered only by two unusual values at once).
/// Not determinismo's own events (runtime_events) nor identifiers and clocks (range_skipped).
fn ranges_note(events: *Events, moment: Moment, value: std.json.Value) void {
    const name = value.object.get("event") orelse return;
    if (name != .string) return;
    if (platform_events.has(name.string)) return;
    const details = value.object.get("details") orelse return;
    if (details != .object) return;
    const node = behavior_node(value);
    var fields = details.object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const number: f64 = switch (field.value_ptr.*) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => continue,
        };
        if (range_skipped(key)) continue;
        if (!range_kept(name.string, key, ranges_salt)) continue;
        for ([_]bool{ true, false }) |highest| {
            var hasher = std.hash.Wyhash.init(0x72616e6765);
            hasher.update(name.string);
            hasher.update(key);
            hasher.update(if (highest) "highest" else "lowest");
            var label_buffer: [behavior_label_size]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "{s} \"{s}\" {s}", .{
                if (highest) "highest" else "lowest", name.string, key,
            }) catch label_buffer[0..];
            events.scored_note(moment, hasher.final() | 1, if (highest) number else -number, label, node);
        }
    }
}

/// Whether this timeline counts the range of an event's field: its share (salt's quarters: none,
/// a quarter, half, three quarters, all) of the fields, which ones drawn by the salt too.
fn range_kept(event: []const u8, key: []const u8, salt: u64) bool {
    const quarters: u64 = salt % 5;
    if (quarters == 0) return false;
    if (quarters == 4) return true;
    var hasher = std.hash.Wyhash.init(salt);
    hasher.update(event);
    hasher.update(key);
    return hasher.final() % 4 < quarters;
}

test "a timeline's ranges: none, all, or a drawn share of the fields" {
    var none: u32 = 0;
    var all: u32 = 0;
    var kept_total: u32 = 0;
    for (0..1000) |salt| {
        var kept: u32 = 0;
        for (0..8) |field| {
            var key_buffer: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buffer, "f{d}", .{field}) catch unreachable;
            kept += @intFromBool(range_kept("order", key, salt));
        }
        none += @intFromBool(kept == 0);
        all += @intFromBool(kept == 8);
        kept_total += kept;
    }
    // About a fifth of the timelines count none, a fifth all, the rest a share; half overall.
    try std.testing.expect(none > 150 and none < 300);
    try std.testing.expect(all > 150 and all < 300);
    try std.testing.expect(kept_total > 3200 and kept_total < 4800);
    // The same salt, the same choice.
    try std.testing.expectEqual(range_kept("order", "latency_ms", 42), range_kept("order", "latency_ms", 42));
}

/// determinismo's own events (the guest runtime's, its kernel's, the SDK's), not the system's:
/// their numbers are the platform's draws and doings (a drawn driver phase, a loss rate, an
/// interleaving's choices), no state of the system's. Kept whole by a test reading the runtime.
const platform_events = std.StaticStringMap(void).initComptime(.{
    .{"aftershock_armed"},
    .{"check_chunk"},
    .{"check_input"},
    .{"check_kept"},
    .{"clock_start"},
    .{"command_exit"},
    .{"command_left_out"},
    .{"command_start"},
    .{"command_weight"},
    .{"composer_done"},
    .{"composer_load"},
    .{"composer_start"},
    .{"core_dump"},
    .{"coverage"},
    .{"crash_point"},
    .{"crash_stack"},
    .{"decision"},
    .{"decisions_announced"},
    .{"dev_go"},
    .{"dev_waiting"},
    .{"disk_baseline"},
    .{"disk_baseline_failed"},
    .{"drive_drawn"},
    .{"drivers_cpu"},
    .{"drivers_stopped"},
    .{"durable_crash"},
    .{"durable_crash_again"},
    .{"egress_close"},
    .{"egress_data"},
    .{"egress_fault"},
    .{"egress_open"},
    .{"egress_ready"},
    .{"exec_cpu"},
    .{"exec_cpu_dropped"},
    .{"exec_done"},
    .{"exec_output"},
    .{"exec_start"},
    .{"explore_here_done"},
    .{"explore_here_held"},
    .{"explore_here_ready"},
    .{"fault"},
    .{"custom_faults"}, // A strategy's own faults det-faults read (strategy.zig's machine).
    .{"custom_faults_invalid"},
    .{"fault_now"}, // A plugin's "fault.now" ended the injector's wait (det.fault_poll_ms).
    .{"fault_injector"}, // The timeline's fault injector, a run's own (composer.zig's injector_choose).
    .{"strategy_check"}, // How many assertions a checker plugin made (main.zig's StrategyCheck).
    .{"fault_custom_done"},
    .{"fault_exclusions"},
    .{"fault_exclusions_invalid"},
    .{"fault_custom_failed"},
    .{"fault_failed"},
    .{"fault_heal_failed"},
    .{"fault_inject_refused"},
    .{"fault_readdress_failed"},
    .{"entropy_rerandomized"},
    .{"fault_regime"},
    .{"fault_skipped"},
    .{"fault_swarm"},
    .{"fault_unlist_failed"},
    .{"faults_aim"},
    .{"faults_branch"},
    .{"faults_phase"},
    .{"faults_quiet"},
    .{"faults_resume"},
    .{"faults_start"},
    .{"faults_stop"},
    .{"file_errors"},
    .{"finally_skipped"},
    .{"ingress_close"},
    .{"ingress_open"},
    .{"ingress_ready"},
    .{"interleaved"},
    .{"length_reached"},
    .{"link_set_failed"},
    .{"min_drive"},
    .{"network_baseline"},
    .{"node_address"},
    .{"node_completed"},
    .{"node_cpu"},
    .{"node_crash"},
    .{"node_crash_files"},
    .{"node_crash_nul_files"},
    .{"node_crash_partial"},
    .{"exit_stack"},
    .{"hold"},
    .{"node_disk_broken"},
    .{"node_supervisor_restart"},
    .{"node_disk_ended"},
    .{"node_disk_fail"},
    .{"node_disk_heal"},
    .{"node_fsck"},
    .{"node_kill"},
    .{"node_knob"},
    .{"node_layer_remount"},
    .{"node_listed"},
    .{"node_not_ready"},
    .{"node_open_unsynced"},
    .{"node_ready"},
    .{"node_rename_unsynced"},
    .{"node_sample"},
    .{"node_start"},
    .{"node_stop"},
    .{"node_unlisted"},
    .{"node_unsynced_files"},
    .{"node_upgrade"},
    .{"node_wipe"},
    .{"nodes_up"},
    .{"nrepl_done"},
    .{"nrepl_relay_closed"},
    .{"nrepl_relay_ready"},
    .{"nrepl_reply"},
    .{"output_dropped"},
    .{"persist_trace_failed"},
    .{"runner_request"},
    .{"runner_session"},
    .{"scenario_end"},
    .{"sdk_setup_missing"},
    .{"self_driven"},
    .{"session_checkpoint"},
    .{"swarm"},
    .{"swarm_seed"},
    .{"sync_stalled"},
    .{"syscall_error"},
    .{"syscall_error_storm"},
    .{"syscall_trace_failed"},
    .{"writeback"},
});

/// Identifiers and clocks: their extremes are no unusual state (the newest id, the latest time).
fn range_skipped(key: []const u8) bool {
    const exact = [_][]const u8{ "id", "pid", "tid", "uid", "gid", "seq", "index", "port", "seed", "epoch", "time", "timestamp", "ts", "vtime_ns" };
    for (exact) |name| if (std.ascii.eqlIgnoreCase(key, name)) return true;
    const suffixes = [_][]const u8{ "_id", "Id", "_pid", "_seq", "_index", "_port", "_time", "_at", "_ns", "_timestamp" };
    for (suffixes) |suffix| if (std.mem.endsWith(u8, key, suffix)) return true;
    return false;
}

/// A timeline begins with its snapshot's table (the setup's, or its parent's prefix): past half of
/// it, the behaviors the tree knows are dropped, as behavior_note would not have kept them. A JVM
/// system's setup alone fills the table with its startup coverage, and every timeline from it
/// began full and kept nothing it reached (hunt run 1901, Pulsar with coverage: no return in 170
/// timelines). The node a branch aims at is apart (named_note): a replay's, knowing nothing, is
/// the same.
pub fn known_forget(events: *Events, known: *const std.AutoHashMapUnmanaged(u64, void)) void {
    if (events.behavior_count <= behavior_known_kept_max) return;
    var kept: u32 = behavior_known_kept_max;
    for (behavior_known_kept_max..events.behavior_count) |index| {
        if (behavior_known(known, events.behaviors[index].hash)) continue;
        events.behaviors[kept] = events.behaviors[index];
        kept += 1;
    }
    if (kept == events.behavior_count) return;
    events.behavior_count = kept;
    @memset(&events.behavior_slots, 0);
    for (events.behaviors[0..kept], 0..) |behavior, index| {
        var slot = behavior.hash % behavior_slot_count;
        while (events.behavior_slots[slot] != 0) slot = (slot + 1) % behavior_slot_count;
        events.behavior_slots[slot] = behavior.hash;
        events.behavior_slot_index[slot] = @intCast(index);
    }
}

/// A scored bucket (ranges_note's): its best score this timeline, and when; added once.
fn scored_note(events: *Events, moment: Moment, key: u64, score: f64, label: []const u8, node: []const u8) void {
    events.named_note(key, node);
    if (behaviors_collected) |collected| collected.note(key);
    var slot = key % behavior_slot_count;
    while (events.behavior_slots[slot] != 0) : (slot = (slot + 1) % behavior_slot_count) {
        if (events.behavior_slots[slot] != key) continue;
        const known = &events.behaviors[events.behavior_slot_index[slot]];
        if (known.score == null or score > known.score.?) {
            known.score = score;
            known.vtime_ns = moment.vtime_ns;
        }
        return;
    }
    if (events.behavior_count == behavior_count_max) return;
    events.behavior_slots[slot] = key;
    events.behavior_slot_index[slot] = @intCast(events.behavior_count);
    const behavior = &events.behaviors[events.behavior_count];
    behavior.* = .{ .hash = key, .vtime_ns = moment.vtime_ns, .score = score };
    behavior.label_size = @intCast(label_fit(label, &behavior.label).len);
    const node_size = @min(node.len, behavior_node_size);
    @memcpy(behavior.node_name[0..node_size], node[0..node_size]);
    behavior.node_size = @intCast(node_size);
    events.behavior_count += 1;
}

fn behavior_note(events: *Events, moment: Moment, value: std.json.Value) void {
    if (ranges_on and value == .object) events.ranges_note(moment, value);
    const optimized = optimize_of(value);
    const hash = behavior_hash(value) orelse guidance_hash(value) orelse
        if (optimized) |found| found.hash else output_hash(value) orelse return;
    const key = hash | 1; // 0 marks an empty slot.
    events.named_note(key, behavior_node(value));
    if (behaviors_collected) |collected| collected.note(key);
    var slot = key % behavior_slot_count;
    while (events.behavior_slots[slot] != 0) : (slot = (slot + 1) % behavior_slot_count) {
        if (events.behavior_slots[slot] != key) continue;
        // A bucket seen before in this timeline (a full table's too): its best score kept, and when.
        if (optimized) |found| {
            const known = &events.behaviors[events.behavior_slot_index[slot]];
            if (known.score == null or found.score > known.score.?) {
                known.score = found.score;
                known.vtime_ns = moment.vtime_ns;
            }
        }
        return;
    }
    if (events.behavior_count >= behavior_known_kept_max and behavior_known(behaviors_seen, key)) {
        events.behaviors_known_skipped +|= 1;
        return;
    }
    if (events.behavior_count == behavior_count_max) {
        events.behaviors_full_dropped +|= 1;
        return;
    }
    events.behavior_slots[slot] = key;
    events.behavior_slot_index[slot] = @intCast(events.behavior_count);
    const behavior = &events.behaviors[events.behavior_count];
    behavior.* = .{ .hash = key, .vtime_ns = moment.vtime_ns };
    var whole: [label_whole_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&whole);
    behavior_label(&writer, value);
    behavior.label_size = @intCast(label_fit(writer.buffered(), &behavior.label).len);
    const node = behavior_node(value);
    const size = @min(node.len, behavior_node_size);
    @memcpy(behavior.node_name[0..size], node[0..size]);
    behavior.node_size = @intCast(size);
    behavior.sought = behavior_sought(value);
    behavior.severe = behavior_severe(value);
    behavior.score = if (optimized) |found| found.score else null;
    events.behavior_count += 1;
}

const Optimized = struct { hash: u64, score: f64 };

/// `{"optimize":{"message":M,"bucket":{...},"value":V,"goal":"maximize"|"minimize"}}`
/// (sdk.optimize): its bucket as a behavior (the message and the bucket's strings and
/// booleans), and its score, higher better.
fn optimize_of(value: std.json.Value) ?Optimized {
    if (value != .object) return null;
    const optimize = value.object.get("optimize") orelse return null;
    if (optimize != .object) return null;
    const message = string_field(optimize.object, "message") orelse return null;
    if (!memory_objective_on and std.mem.eql(u8, message, memory_growth_objective)) return null;
    const measured: f64 = switch (optimize.object.get("value") orelse return null) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    const minimize = std.mem.eql(u8, string_field(optimize.object, "goal") orelse "", "minimize");
    var hasher = std.hash.Wyhash.init(0x6f7074696d697a65);
    hasher.update(message);
    if (optimize.object.get("bucket")) |bucket| if (bucket == .object) {
        var fields = bucket.object.iterator();
        while (fields.next()) |field| hash_field(&hasher, bucket.object, field.key_ptr.*);
    };
    return .{ .hash = hasher.final(), .score = if (minimize) -measured else measured };
}

/// Whether an assertion's evaluation is a `sometimes` or `reachable` made true (determinismo's
/// or an Antithesis SDK's).
fn behavior_sought(value: std.json.Value) bool {
    const assertion = assertion_of(value) orelse return false;
    const kind = assertion.kind;
    if (!std.mem.eql(u8, kind, "sometimes") and !std.mem.eql(u8, kind, "reachable")) return false;
    const condition = assertion.object.get("condition") orelse return true;
    return condition == .bool and condition.bool;
}

/// An assertion's evaluation, with its kind's name: determinismo's `assert`, or an Antithesis
/// SDK's `antithesis_assert` (its display_type mapped). A declaration (`hit` false) is none.
const Assertion = struct { object: std.json.ObjectMap, kind: []const u8 };

fn assertion_of(value: std.json.Value) ?Assertion {
    if (value.object.get("assert")) |assertion| {
        if (assertion != .object or declaration(assertion.object)) return null;
        return .{ .object = assertion.object, .kind = string_field(assertion.object, "type") orelse "assert" };
    }
    const assertion = value.object.get("antithesis_assert") orelse return null;
    if (assertion != .object or declaration(assertion.object)) return null;
    const display = string_field(assertion.object, "display_type") orelse return null;
    for (antithesis_kinds) |entry| {
        if (std.mem.eql(u8, display, entry[0])) return .{ .object = assertion.object, .kind = @tagName(entry[1]) };
    }
    return null;
}

/// The node a behavior came from: a node's output's source, an event's `details.node`, an
/// assertion's when its details name one (det-faults' aim moved: the new leader); "" when it
/// does not say.
/// Words that mark a line as trouble in most systems' logs (levels, exceptions, panics, the
/// usual failures), matched without case in a kind of output line's text.
const severe_words = [_][]const u8{
    "error", "exception", "panic", "fatal",       "fail",   "timeout", "timed out",  "refused",
    "abort", "corrupt",   "warn",  "unavailable", "denied", "invalid", "unexpected",
};

fn behavior_severe(value: std.json.Value) bool {
    const output = value.object.get("output") orelse return false;
    if (output != .object) return false;
    const text = string_field(output.object, "text") orelse return false;
    for (severe_words) |word| if (std.ascii.findIgnoreCase(text, word) != null) return true;
    return false;
}

test behavior_severe {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"output":{"source":"db","text":"2026-10-31 WARN replica lagging"}},
        \\ {"output":{"source":"db","text":"java.io.IOException: Connection refused"}},
        \\ {"output":{"source":"db","text":"accepted connection from 10.0.0.2"}},
        \\ {"event":"fault","details":{"kind":"error"}}]
    , .{});
    defer parsed.deinit();
    const values = parsed.value.array.items;
    try std.testing.expect(behavior_severe(values[0]));
    try std.testing.expect(behavior_severe(values[1]));
    try std.testing.expect(!behavior_severe(values[2]));
    try std.testing.expect(!behavior_severe(values[3])); // Events are not lines a system printed.
}

fn behavior_node(value: std.json.Value) []const u8 {
    if (value.object.get("output")) |output| if (output == .object) {
        return string_field(output.object, "source") orelse "";
    };
    if (assertion_of(value)) |assertion| {
        const details = assertion.object.get("details") orelse return "";
        if (details != .object) return "";
        return string_field(details.object, "node") orelse "";
    }
    const details = value.object.get("details") orelse return "";
    if (details != .object) return "";
    return string_field(details.object, "node") orelse "";
}

/// A behavior's label, cut where the label ends.
/// A label as written before it is fitted to behavior_label_size.
const label_whole_size = 512;

/// `label` in `out`: whole if it fits; a line's coverage (`coverage line <place>:<n>`) with its
/// place shortened from the left at a package or path boundary, its line kept (a JVM class's
/// place is its long name: run 1871's Kafka lost the line of 1,993 of its 10,582, among them
/// every TransactionMetadata line, and --changed matched none of them); anything else cut.
fn label_fit(label: []const u8, out: *[behavior_label_size]u8) []const u8 {
    if (label.len <= out.len) {
        @memcpy(out[0..label.len], label);
        return out[0..label.len];
    }
    const prefix = "coverage line ";
    if (std.mem.startsWith(u8, label, prefix)) if (std.mem.lastIndexOfScalar(u8, label, ':')) |colon| {
        const line = label[colon..];
        const place = label[prefix.len..colon];
        const room = out.len -| (prefix.len + line.len);
        if (room > 0 and place.len > 0) {
            var start = place.len - @min(room, place.len);
            // At a boundary: a place that begins with a whole path component (a path's) or
            // package (a class's).
            const boundary: u8 = if (std.mem.indexOfScalar(u8, place, '/') != null) '/' else '.';
            while (start < place.len and start > 0 and place[start - 1] != boundary) start += 1;
            if (start < place.len) {
                const kept = place[start..];
                var at: usize = 0;
                for ([_][]const u8{ prefix, kept, line }) |part| {
                    @memcpy(out[at..][0..part.len], part);
                    at += part.len;
                }
                return out[0..at];
            }
        }
    };
    @memcpy(out, label[0..out.len]);
    return out[0..];
}

test label_fit {
    var out: [behavior_label_size]u8 = undefined;
    try std.testing.expectEqualStrings("coverage line /src/raft.go:624", label_fit("coverage line /src/raft.go:624", &out));
    // run 1871's: the class's package cut at a dot, its line kept, --changed still matching it.
    const fitted = label_fit("coverage line org.apache.kafka.coordinator.transaction.TransactionMetadata:123", &out);
    try std.testing.expectEqualStrings("coverage line kafka.coordinator.transaction.TransactionMetadata:123", fitted);
    // A path cut at a slash.
    const path = label_fit("coverage line /root/go/pkg/mod/go.etcd.io/etcd/server/v3@v3.6.0/etcdserver/api/v3rpc/watch.go:331", &out);
    try std.testing.expectEqualStrings("coverage line etcd/server/v3@v3.6.0/etcdserver/api/v3rpc/watch.go:331", path);
    // Anything else: cut.
    const said = "kafka-4 printed \"[# #,#] INFO [ControllerRegistrationManager id=# incarnation=#]\"";
    try std.testing.expectEqualStrings(said[0..behavior_label_size], label_fit(said, &out));
}

fn behavior_label(writer: *std.Io.Writer, value: std.json.Value) void {
    if (assertion_of(value)) |assertion| {
        const message = string_field(assertion.object, "message") orelse "";
        const condition = assertion.object.get("condition") orelse std.json.Value{ .bool = true };
        const holds = condition != .bool or condition.bool;
        writer.print("{s} \"{s}\": {}", .{ assertion.kind, message, holds }) catch {};
        return;
    }
    if (value.object.get("guidance")) |guidance| if (guidance == .object) {
        const message = string_field(guidance.object, "message") orelse "";
        writer.print("closer to \"{s}\"", .{message}) catch {};
        return;
    };
    if (value.object.get("optimize")) |optimize| if (optimize == .object) {
        const message = string_field(optimize.object, "message") orelse "";
        writer.print("best \"{s}\"", .{message}) catch {};
        if (optimize.object.get("bucket")) |bucket| if (bucket == .object) {
            var fields = bucket.object.iterator();
            while (fields.next()) |field| switch (field.value_ptr.*) {
                .string => |text| writer.print(" {s}={s}", .{ field.key_ptr.*, text }) catch {},
                .bool => |flag| writer.print(" {s}={}", .{ field.key_ptr.*, flag }) catch {},
                else => {},
            };
        };
        return;
    };
    if (value.object.get("output")) |output| if (output == .object) {
        const source = string_field(output.object, "source") orelse "";
        var template: [output_template_size]u8 = undefined;
        const text = output_template(string_field(output.object, "text") orelse "", &template);
        writer.print("{s} printed \"{s}\"", .{ source, text }) catch {};
        return;
    };
    const name_value = value.object.get("event") orelse return;
    if (name_value != .string) return;
    writer.writeAll(name_value.string) catch return;
    const details = value.object.get("details") orelse return;
    if (details != .object) return;
    for ([_][]const u8{ "kind", "flavor", "node", "peer", "state", "name" }) |key| {
        const text = string_field(details.object, key) orelse continue;
        writer.print(" {s}", .{text}) catch return;
    }
}

/// A kind of line a node printed: its text with numbers, hex and ids blanked (`#`), per source
/// and stream; a node saying something it never said before (a new error, an exception) is a
/// new behavior.
fn output_hash(value: std.json.Value) ?u64 {
    const output = value.object.get("output") orelse return null;
    if (output != .object) return null;
    // A long line's later pieces (guest/runtime/output.zig's line_part): cut mid-word.
    if (output.object.get("part") != null) return null;
    const text = string_field(output.object, "text") orelse return null;
    var hasher = std.hash.Wyhash.init(0x6f7574707574);
    hasher.update(string_field(output.object, "source") orelse "");
    hasher.update(string_field(output.object, "stream") orelse "");
    var template: [output_template_size]u8 = undefined;
    hasher.update(output_template(text, &template));
    return hasher.final();
}

const output_template_size = 96;

/// `text` with every run of digits, hex digits mixed with digits, or `-`/`.`/`:` between them
/// made one `#`, cut to the buffer (where variable parts usually are past).
fn output_template(text: []const u8, buffer: *[output_template_size]u8) []const u8 {
    var size: usize = 0;
    var index: usize = 0;
    while (index < text.len and size < buffer.len) {
        const c = text[index];
        // A random id as a whole (a Kafka Uuid's base64: `RmzRIF0_TZ3ZZIq9kPw1aA`), at a token's
        // start: its digits alone blanked, every timeline's lines were new kinds (run 1871).
        if (id_char(c) and (index == 0 or !id_char(text[index - 1]))) {
            var end = index;
            while (end < text.len and id_char(text[end])) end += 1;
            if (random_id(text[index..end])) {
                buffer[size] = '#';
                size += 1;
                index = end;
                continue;
            }
        }
        // A piece of a dash-joined name on its own (Scylla's `me-3h5g_003j_1dq4g2raybeoh34a0s-big-
        // Data.db`: the name's words kept, its generation blanked: run 1851, 4,844 kinds of
        // "Removing file" line each seen in one timeline).
        if (id_char(c) and c != '-' and index > 0 and text[index - 1] == '-') {
            var end = index;
            while (end < text.len and id_char(text[end]) and text[end] != '-') end += 1;
            if (random_id(text[index..end])) {
                buffer[size] = '#';
                size += 1;
                index = end;
                continue;
            }
        }
        if (!std.ascii.isDigit(c)) {
            buffer[size] = c;
            size += 1;
            index += 1;
            continue;
        }
        // A number, an id or an address: digits with hex letters and separators around them.
        var end = index;
        while (end < text.len and (std.ascii.isHex(text[end]) or text[end] == '-' or
            text[end] == '.' or text[end] == ':')) end += 1;
        // Hex letters before the digits belong to it too (`a708a334-...`).
        while (size > 0 and std.ascii.isHex(buffer[size - 1]) and
            !std.ascii.isDigit(buffer[size - 1])) size -= 1;
        buffer[size] = '#';
        size += 1;
        index = end;
    }
    return buffer[0..size];
}

fn id_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// A token that reads as random, not as a word or a name: 12 characters or more, digits and both
/// cases, and two capitals or more not followed by a small letter (camelCase's always are:
/// `ControllerRegistrationManager`, `Log4jLoggerFactory` stay).
fn random_id(token: []const u8) bool {
    if (token.len < 12) return false;
    // Words joined by dashes (`nREPL-session-a708a334-...`: a name, then a UUID the hex rule
    // blanks): a piece of three letters or more in one case is a word.
    var pieces = std.mem.splitScalar(u8, token, '-');
    while (pieces.next()) |piece| {
        if (piece.len < 3) continue;
        var all_lower = true;
        var all_upper = true;
        for (piece) |c| {
            if (!std.ascii.isLower(c)) all_lower = false;
            if (!std.ascii.isUpper(c)) all_upper = false;
        }
        if (all_lower or all_upper) return false;
    }
    // Letters and digits alternating often, whatever their case: NATS's server ids (base32,
    // capitals and digits: run 1854, 81% of its kinds of line seen in one timeline), Scylla's
    // sstable generations (base36, small letters and digits: run 1851, half of them).
    if (token.len >= 16 and alternations(token) >= 5) return true;
    var digits: u32 = 0;
    var lower: u32 = 0;
    var upper: u32 = 0;
    var upper_unfollowed: u32 = 0;
    for (token, 0..) |c, at| {
        if (std.ascii.isDigit(c)) digits += 1;
        if (std.ascii.isLower(c)) lower += 1;
        if (std.ascii.isUpper(c)) {
            upper += 1;
            if (at + 1 == token.len or !std.ascii.isLower(token[at + 1])) upper_unfollowed += 1;
        }
    }
    if (lower < 2 or upper < 2 or upper_unfollowed < 2) return false;
    // Without a digit (a 22-character base64 Uuid has none one time in forty: run 1871's
    // `DRPHqzhuTAadsvnXVVJYuw`), only long and capital-heavy (`HTTPSURLConnection` stays).
    if (digits == 0 and (token.len < 20 or upper_unfollowed < 4 or lower < 4)) return false;
    return true;
}

/// How often a token turns from a letter to a digit or back.
fn alternations(token: []const u8) u32 {
    var count: u32 = 0;
    for (token[0 .. token.len - 1], token[1..]) |a, b| {
        if (!std.ascii.isAlphanumeric(a) or !std.ascii.isAlphanumeric(b)) continue;
        if (std.ascii.isDigit(a) != std.ascii.isDigit(b)) count += 1;
    }
    return count;
}

test random_id {
    // NATS's server id and Scylla's sstable generation: random, though one case only.
    try std.testing.expect(random_id("NAVHLZYGOJHZRMAN7K3VFVBKOWKNTWRWMVPM4JCDSXINIHXXV2IWV"));
    try std.testing.expect(random_id("3gi5_0lzc_2jkls2fz7x8tnwuj3i"));
    try std.testing.expect(!random_id("TransactionMarkerChannelManager"));
    try std.testing.expect(!random_id("S3FileSystemProvider"));
    try std.testing.expect(!random_id("utf8mb4_general_ci"));
    // run 1871's Kafka: topic ids and incarnations, base64 Uuids.
    try std.testing.expect(random_id("RmzRIF0_TZ3ZZIq9kPw1aA"));
    try std.testing.expect(random_id("qqPcM2x7OVCPQ"));
    try std.testing.expect(random_id("xG7rVr2nQd-0bUgw2E3YvA"));
    try std.testing.expect(!random_id("ControllerRegistrationManager"));
    try std.testing.expect(!random_id("Log4jLoggerFactory"));
    try std.testing.expect(!random_id("__transaction_state"));
    try std.testing.expect(!random_id("TransactionMetadata"));
    try std.testing.expect(!random_id("HTTP2Server"));
    try std.testing.expect(random_id("DRPHqzhuTAadsvnXVVJYuw"));
    try std.testing.expect(!random_id("HTTPSURLConnection"));
    try std.testing.expect(!random_id("AbstractCoordinatorMetricsManager"));
}

test output_template {
    var buffer: [output_template_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Removing file /var/lib/scylla/data/system/truncated-#/me-#-big-Summary.db",
        output_template("Removing file /var/lib/scylla/data/system/truncated-38c19fd0fb863310a4b70d0cc66628aa/me-3h5g_003j_1dq4g2raybeoh34a0s-big-Summary.db", &buffer),
    );
    try std.testing.expectEqualStrings(
        "__transaction_state-#=PartitionData(topicId=#, partition=#)",
        output_template("__transaction_state-12=PartitionData(topicId=RmzRIF0_TZ3ZZIq9kPw1aA, partition=12)", &buffer),
    );
    try std.testing.expectEqualStrings(
        "INFO [ControllerRegistrationManager id=# incarnation=#] Found",
        output_template("INFO [ControllerRegistrationManager id=2 incarnation=xG7rVr2nQd-0bUgw2E3YvA] Found", &buffer),
    );
    try std.testing.expectEqualStrings(
        "Exception in thread \"nREPL-session-#\" java.net.SocketException: Socket closed",
        output_template("Exception in thread \"nREPL-session-a708a334-2896-48df-891a-" ++
            "8d76d5056a9c\" java.net.SocketException: Socket closed", &buffer),
    );
    try std.testing.expectEqualStrings("took # ms", output_template("took 12.5 ms", &buffer));
}

/// A guidance assertion's distance by power of two (0 or less: there): a timeline that came
/// closer than any before reached a new behavior.
/// What the explorer counts as a behavior: an assertion with its outcome, an event with its
/// categorical details (a code coverage edge or line included); not numbers, not what
/// determinismo itself reports (commands, faults, lifecycle). The events database counts the
/// same (store.zig's `behavior`).
const runtime_events = [_][]const u8{
    "composer_start", "composer_done", "command_start", "command_exit", "faults_phase",
    "faults_start",   "faults_stop",   "fault",         "nodes_up",     "node_start",
    "node_ready",     "node_kill",     "exec_start",    "exec_output",  "exec_done",
    "faults_branch",
};
const behavior_keys = [_][]const u8{ "kind", "flavor", "mode", "name", "node", "peer", "state" };

fn behavior_hash(value: std.json.Value) ?u64 {
    if (value != .object) return null;
    var hasher = std.hash.Wyhash.init(0x6265686176696f72);
    if (value.object.get("assert")) |assertion| {
        if (assertion != .object or declaration(assertion.object)) return null;
        for ([_][]const u8{ "type", "message", "condition" }) |key| {
            hash_field(&hasher, assertion.object, key);
        }
        return hasher.final();
    }
    // An Antithesis SDK's evaluation: the same behavior as determinismo's of its kind (a Compose
    // project's assertions guide the tree as a test program's do).
    if (value.object.get("antithesis_assert") != null) {
        const assertion = assertion_of(value) orelse return null;
        hasher.update("type");
        hasher.update(assertion.kind);
        for ([_][]const u8{ "message", "condition" }) |key| hash_field(&hasher, assertion.object, key);
        return hasher.final();
    }
    const name = value.object.get("event") orelse return null;
    if (name != .string) return null;
    for (runtime_events) |runtime| if (std.mem.eql(u8, name.string, runtime)) return null;
    hasher.update(name.string);
    if (value.object.get("details")) |details| {
        if (details == .object) for (behavior_keys) |key| hash_field(&hasher, details.object, key);
    }
    return hasher.final();
}

fn hash_field(hasher: *std.hash.Wyhash, object: std.json.ObjectMap, key: []const u8) void {
    const value = object.get(key) orelse return;
    hasher.update(key);
    switch (value) {
        .string => |text| hasher.update(text),
        .bool => |flag| hasher.update(if (flag) "true" else "false"),
        else => {}, // Numbers and structures: not behaviors.
    }
}

fn guidance_hash(value: std.json.Value) ?u64 {
    const guidance = value.object.get("guidance") orelse return null;
    if (guidance != .object) return null;
    const message = string_field(guidance.object, "message") orelse return null;
    const distance: f64 = switch (guidance.object.get("distance") orelse return null) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    const bucket: i32 = if (!(distance > 0)) -1 else bucket: {
        break :bucket @floor(@log2(@min(distance, 1e300)));
    };
    var hasher = std.hash.Wyhash.init(0x6775696465);
    hasher.update(message);
    hasher.update(std.mem.asBytes(&bucket));
    return hasher.final();
}

test "an optimized bucket keeps its best score" {
    var buffer: [parse_buffer_size]u8 = undefined;
    var events: Events = undefined;
    events.init(&buffer, .{ .log_fd = null });
    const leader_a_3 = "{\"optimize\":{\"message\":\"lag\",\"bucket\":{\"leader\":\"a\"},\"value\":3,\"goal\":\"maximize\"}}";
    const leader_a_7 = "{\"optimize\":{\"message\":\"lag\",\"bucket\":{\"leader\":\"a\"},\"value\":7,\"goal\":\"maximize\"}}";
    const leader_a_5 = "{\"optimize\":{\"message\":\"lag\",\"bucket\":{\"leader\":\"a\"},\"value\":5,\"goal\":\"maximize\"}}";
    const leader_b = "{\"optimize\":{\"message\":\"lag\",\"bucket\":{\"leader\":\"b\"},\"value\":9,\"goal\":\"minimize\"}}";
    try events.emit(.{ .vtime_ns = 10, .branches = 1 }, leader_a_3);
    try events.emit(.{ .vtime_ns = 20, .branches = 2 }, leader_a_7);
    try events.emit(.{ .vtime_ns = 30, .branches = 3 }, leader_a_5);
    try events.emit(.{ .vtime_ns = 40, .branches = 4 }, leader_b);
    try std.testing.expectEqual(@as(u32, 2), events.behavior_count);
    // Bucket a: its best (7), reached at 20; bucket b: minimized, 9 negated.
    try std.testing.expectEqual(@as(?f64, 7), events.behaviors[0].score);
    try std.testing.expectEqual(@as(u64, 20), events.behaviors[0].vtime_ns);
    try std.testing.expectEqualStrings("best \"lag\" leader=a", events.behaviors[0].name());
    try std.testing.expectEqual(@as(?f64, -9), events.behaviors[1].score);
}

test "an event's numbers are ranges: its highest and lowest kept, identifiers and the runtime's left out" {
    // A timeline whose draw counts every range (range_kept: salt % 5 == 4).
    const salt = ranges_salt;
    defer ranges_salt = salt;
    ranges_salt = 4;
    var buffer: [parse_buffer_size]u8 = undefined;
    var events: Events = undefined;
    events.init(&buffer, .{ .log_fd = null });
    try events.emit(.{ .vtime_ns = 10, .branches = 1 }, "{\"event\":\"order\",\"details\":{\"latency_ms\":12,\"order_id\":7,\"node\":\"db\"}}");
    try events.emit(.{ .vtime_ns = 20, .branches = 2 }, "{\"event\":\"order\",\"details\":{\"latency_ms\":40,\"order_id\":8,\"node\":\"db\"}}");
    try events.emit(.{ .vtime_ns = 30, .branches = 3 }, "{\"event\":\"order\",\"details\":{\"latency_ms\":3,\"order_id\":9,\"node\":\"db\"}}");
    try events.emit(.{ .vtime_ns = 40, .branches = 4 }, "{\"event\":\"exec_done\",\"details\":{\"status\":1,\"id\":3}}");
    var highest: ?Behavior = null;
    var lowest: ?Behavior = null;
    var ranges: u32 = 0;
    for (events.behaviors[0..events.behavior_count]) |behavior| {
        if (behavior.score == null) continue;
        ranges += 1;
        if (std.mem.eql(u8, behavior.name(), "highest \"order\" latency_ms")) highest = behavior;
        if (std.mem.eql(u8, behavior.name(), "lowest \"order\" latency_ms")) lowest = behavior;
    }
    // latency_ms alone: order_id an identifier, exec_done the runtime's.
    try std.testing.expectEqual(@as(u32, 2), ranges);
    try std.testing.expectEqual(@as(?f64, 40), highest.?.score);
    try std.testing.expectEqual(@as(u64, 20), highest.?.vtime_ns);
    try std.testing.expectEqual(@as(?f64, -3), lowest.?.score);
    try std.testing.expectEqual(@as(u64, 30), lowest.?.vtime_ns);
    try std.testing.expectEqualStrings("db", highest.?.node_name[0..highest.?.node_size]);
}

test behavior_note {
    var buffer: [parse_buffer_size]u8 = undefined;
    var events: Events = undefined;
    events.init(&buffer, .{ .log_fd = null });
    const near = "{\"guidance\":{\"message\":\"sum\",\"distance\":5}}";
    try events.emit(.{ .vtime_ns = 10, .branches = 1 }, near);
    try events.emit(.{ .vtime_ns = 20, .branches = 2 }, near);
    const closer = "{\"guidance\":{\"message\":\"sum\",\"distance\":1}}";
    try events.emit(.{ .vtime_ns = 30, .branches = 3 }, closer);
    // Same bucket once, closer is new; when each was first reached.
    try std.testing.expectEqual(@as(u32, 2), events.behavior_count);
    try std.testing.expectEqual(@as(u64, 10), events.behaviors[0].vtime_ns);
    try std.testing.expectEqual(@as(u64, 30), events.behaviors[1].vtime_ns);
    try std.testing.expectEqualStrings("closer to \"sum\"", events.behaviors[1].name());
}

/// Language properties (a Go panic, ...) are the guest's output forwarder's assertions
/// (guest/runtime/output.zig): events as any other, for queries and a run's properties alike.
fn on_output(events: *Events, output: std.json.Value) void {
    if (output != .object) return;
    const text = string_field(output.object, "text") orelse return;
    events.output_bytes += text.len;
    const source = string_field(output.object, "source") orelse "";
    output_source_add(&events.output_sources, &events.output_source_count, source, text.len);
}

pub const output_sources_max = 16;
const output_source_name_max = 32;
/// The table's last entry once it is full: every source past it.
const output_source_other = "(other sources)";

pub const OutputSource = struct {
    name: [output_source_name_max]u8 = undefined,
    name_size: u8 = 0,
    bytes: u64 = 0,

    pub fn named(source: *const OutputSource) []const u8 {
        return source.name[0..source.name_size];
    }
};

/// `bytes` more of `name`'s output: its entry, a new one, or the last (other sources) once the
/// table is full. Names cut to the entry's size.
pub fn output_source_add(sources: []OutputSource, count: *u8, name: []const u8, bytes: u64) void {
    assert(sources.len >= 2 and sources.len <= std.math.maxInt(u8));
    assert(count.* <= sources.len);
    const shown = if (name.len == 0) "(no source)" else name[0..@min(name.len, output_source_name_max)];
    for (sources[0..count.*]) |*source| {
        if (std.mem.eql(u8, source.named(), shown)) {
            source.bytes += bytes;
            return;
        }
    }
    const full = count.* == sources.len - 1;
    const label = if (full) output_source_other else shown;
    if (count.* == sources.len) {
        sources[sources.len - 1].bytes += bytes; // Already the other sources' entry.
        return;
    }
    const source = &sources[count.*];
    source.* = .{ .name_size = @intCast(label.len), .bytes = bytes };
    @memcpy(source.name[0..label.len], label);
    count.* += 1;
}

test "output is counted by its source, the bytes the guest dropped too" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const lines = [_][]const u8{
        "{\"output\":{\"source\":\"n1\",\"stream\":\"stdout\",\"text\":\"hello\"}}",
        "{\"output\":{\"source\":\"kernel\",\"stream\":\"console\",\"text\":\"[ 0.1] boot\"}}",
        "{\"output\":{\"source\":\"n1\",\"stream\":\"stderr\",\"text\":\"world!\"}}",
        "{\"event\":\"output_dropped\",\"details\":{\"source\":\"n1\",\"bytes\":1000,\"lines\":3}}",
    };
    for (lines, 0..) |line, index| try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    try std.testing.expectEqual(@as(u8, 2), events.output_source_count);
    try std.testing.expectEqualStrings("n1", events.output_sources[0].named());
    try std.testing.expectEqual(@as(u64, 5 + 6 + 1000), events.output_sources[0].bytes);
    try std.testing.expectEqualStrings("kernel", events.output_sources[1].named());
    try std.testing.expectEqual(events.output_bytes, events.output_sources[0].bytes + events.output_sources[1].bytes);
}

test output_source_add {
    var sources: [3]OutputSource = @splat(.{});
    var count: u8 = 0;
    output_source_add(&sources, &count, "n1", 10);
    output_source_add(&sources, &count, "n2", 5);
    output_source_add(&sources, &count, "n1", 1);
    output_source_add(&sources, &count, "kernel", 7); // The table full: the other sources.
    output_source_add(&sources, &count, "client", 2);
    try std.testing.expectEqual(@as(u8, 3), count);
    try std.testing.expectEqualStrings("n1", sources[0].named());
    try std.testing.expectEqual(@as(u64, 11), sources[0].bytes);
    try std.testing.expectEqual(@as(u64, 5), sources[1].bytes);
    try std.testing.expectEqualStrings(output_source_other, sources[2].named());
    try std.testing.expectEqual(@as(u64, 9), sources[2].bytes);
}

/// Output the guest's forwarder dropped over its rate (guest/runtime/output.zig): still output,
/// for the logging property.
fn on_output_dropped(events: *Events, details: ?std.json.Value) void {
    const found = details orelse return;
    if (found != .object) return;
    const bytes = found.object.get("bytes") orelse return;
    if (bytes != .integer or bytes.integer < 0) return;
    events.output_bytes += @intCast(bytes.integer);
    const source = string_field(found.object, "source") orelse "";
    output_source_add(&events.output_sources, &events.output_source_count, source, @intCast(bytes.integer));
}

fn on_lifecycle(events: *Events, moment: Moment, lifecycle: std.json.Value) void {
    assert(events.count > 0);
    if (lifecycle != .string) return;
    if (std.mem.eql(u8, lifecycle.string, "setup_complete")) {
        if (events.setup_complete == null) events.setup_complete = moment;
    }
    if (std.mem.eql(u8, lifecycle.string, "guest_done")) events.guest_done = true;
    if (events.setup_complete) |setup| assert(setup.branches <= moment.branches);
}

fn on_assert(events: *Events, moment: Moment, assertion: std.json.Value) !void {
    assert(events.count > 0);
    if (assertion != .object) return error.BadAssertion;
    const kind_name = string_field(assertion.object, "type") orelse return error.BadAssertion;
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse return error.BadAssertion;
    if (declaration(assertion.object)) return events.declare(kind, assertion.object);
    return events.assertion_record(moment, kind, assertion);
}

/// `"hit": false`: the assertion is declared (Antithesis's catalog), not evaluated. A declared
/// `reachable` or `sometimes` that no timeline reaches fails, as must-hit assertions do.
fn declaration(assertion: std.json.ObjectMap) bool {
    const hit = assertion.get("hit") orelse return false;
    return hit == .bool and !hit.bool;
}

fn declare(events: *Events, kind: Kind, assertion: std.json.ObjectMap) !void {
    const message = string_field(assertion, "message") orelse return error.BadAssertion;
    const property = try events.property_get_or_put(kind, message);
    location_note(property, assertion);
}

/// Antithesis SDKs' `display_type`s, as determinismo's kinds.
const antithesis_kinds = [_]struct { []const u8, Kind }{
    .{ "Always", .always },
    .{ "AlwaysOrUnreachable", .always_or_unreachable },
    .{ "Sometimes", .sometimes },
    .{ "Reachable", .reachable },
    .{ "Unreachable", .@"unreachable" },
};

/// An assertion from an Antithesis SDK (`{"antithesis_assert": {...}}`): its `display_type`
/// names the property kind; entries with `hit: false` only declare the assertion.
fn on_antithesis_assert(events: *Events, moment: Moment, assertion: std.json.Value) !void {
    if (assertion != .object) return error.BadAssertion;
    const display = string_field(assertion.object, "display_type") orelse
        return error.BadAssertion;
    for (antithesis_kinds) |entry| {
        if (!std.mem.eql(u8, display, entry[0])) continue;
        if (declaration(assertion.object)) return events.declare(entry[1], assertion.object);
        return events.assertion_record(moment, entry[1], assertion);
    }
    return error.BadAssertion;
}

fn assertion_record(events: *Events, moment: Moment, kind: Kind, assertion: std.json.Value) !void {
    const message = string_field(assertion.object, "message") orelse return error.BadAssertion;
    const condition_value = assertion.object.get("condition") orelse std.json.Value{ .bool = true };
    if (condition_value != .bool) return error.BadAssertion;
    const condition = condition_value.bool;

    const property = try events.property_get_or_put(kind, message);
    assert(property.kind == kind);
    location_note(property, assertion.object);
    property.hits += 1;
    if (condition) property.trues += 1;
    const failure = switch (kind) {
        .always, .always_or_unreachable => !condition,
        .@"unreachable" => true,
        .sometimes, .reachable => false,
    };
    if (failure) {
        if (property.first_failure == null) property.first_failure = moment;
    }
    assert(property.trues <= property.hits);
}

const location_size_max = 120;

/// `"location": {"file", "line", "function", "class"}` (Antithesis's SDKs send `begin_line`):
/// kept as "file:line Class.function", once: a qualified class (a JVM's) by its simple name, and
/// not again when the function's name carries it (Go's package).
fn location_note(property: *Property, assertion: std.json.ObjectMap) void {
    if (property.location_size > 0) return;
    const location = assertion.get("location") orelse return;
    if (location != .object) return;
    const file = string_field(location.object, "file") orelse
        string_field(location.object, "file_name") orelse return;
    const line_value = location.object.get("line") orelse location.object.get("begin_line");
    const line: i64 = if (line_value) |value| switch (value) {
        .integer => |integer| integer,
        else => 0,
    } else 0;
    const function = string_field(location.object, "function") orelse
        string_field(location.object, "function_name") orelse "";
    const qualified = string_field(location.object, "class") orelse "";
    const class = qualified[if (std.mem.lastIndexOfScalar(u8, qualified, '.')) |dot| dot + 1 else 0..];
    const carried = std.mem.startsWith(u8, function, class) and function.len > class.len and function[class.len] == '.';
    var writer: std.Io.Writer = .fixed(&property.location);
    writer.print("{s}:{d}", .{ std.fs.path.basename(file), line }) catch {};
    if (class.len > 0 and function.len > 0 and !carried) {
        writer.print(" {s}.{s}", .{ class, function }) catch {};
    } else if (function.len > 0) writer.print(" {s}", .{function}) catch {};
    property.location_size = @intCast(writer.end);
}

fn property_get_or_put(events: *Events, kind: Kind, message: []const u8) !*Property {
    assert(events.property_count <= property_count_max);
    if (message.len == 0) return error.BadAssertion;
    const size: u8 = @intCast(@min(message.len, message_size_max));
    for (events.properties[0..events.property_count]) |*property| {
        if (std.mem.eql(u8, property.name(), message[0..size])) {
            if (property.kind != kind) {
                // One property per message (as in Antithesis): a message with two kinds is a
                // test's mistake, worth saying plainly.
                std.debug.print("[determinismo] the assertion \"{s}\" is both {s} and {s}: give " ++
                    "each kind its own message\n", .{
                    property.name(), @tagName(property.kind), @tagName(kind),
                });
                return error.AssertionKindsDiffer;
            }
            return property;
        }
    }
    if (events.property_count == property_count_max) return error.TooManyProperties;
    const property = &events.properties[events.property_count];
    property.* = .{ .kind = kind, .message = undefined, .message_size = size };
    @memcpy(property.message[0..size], message[0..size]);
    events.property_count += 1;
    assert(events.property_count <= property_count_max);
    return property;
}

/// `check_chunk` and `check_input` events (composer.zig's checks_stream): the inputs collected.
fn check_event(events: *Events, name: []const u8, details: ?std.json.Value) void {
    const chunk = std.mem.eql(u8, name, "check_chunk");
    if (!chunk and !std.mem.eql(u8, name, "check_input")) return;
    const object = (details orelse return).object;
    const index_value = object.get("check") orelse return;
    if (index_value != .integer or index_value.integer < 0) return;
    const index: usize = @intCast(index_value.integer);
    if (index >= check_count_max) return;
    const input = &events.check_inputs[index];
    if (!chunk) {
        input.complete = true;
        input.missing = object.get("missing") != null;
        return;
    }
    const data = object.get("data") orelse return;
    if (data != .string) return;
    if (input.start == input.end) {
        input.start = events.check_used;
        input.end = events.check_used;
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data.string) catch return;
    if (input.overflow or input.end != events.check_used or events.check_used + size > events.check_buffer.len) {
        input.overflow = true;
        return;
    }
    decoder.decode(events.check_buffer[events.check_used..][0..size], data.string) catch {
        input.overflow = true;
        return;
    };
    events.check_used += size;
    input.end = events.check_used;
}

/// Built-in property, checked when a timeline ends: the guest finished its scenario, rather than
/// panicking (the kernel reboots on panic), halting for good, or failing to start.
pub fn finish(events: *Events, moment: Moment, outcome: enum { ended, cut_short }) !void {
    if (outcome == .cut_short) return; // Stopped at a moment on purpose.
    const assertion = if (events.guest_done)
        "{\"assert\":{\"type\":\"always\",\"message\":\"" ++ finish_property ++
            "\",\"condition\":true,\"details\":{}}}"
    else
        "{\"assert\":{\"type\":\"always\",\"message\":\"" ++ finish_property ++
            "\",\"condition\":false,\"details\":{}}}";
    try events.emit(moment, assertion);
}

const finish_property = "the guest finishes its scenario (no panic, hang or crash)";

/// The raw bytes of a kept chunk: 2,400 are 3,200 in base64, as the composer's own chunks.
const kept_chunk_size = 2400;

/// Kept inputs go as gzip, a member per block of this many bytes of an input (members in a row
/// are one gzip stream to Python's gzip.decompress and zcat). A history's JSON lines compress
/// about 69 times (run 1632: a timeline's 197 MB history, 2.9 MB), where their base64 made an
/// hour-long failing timeline's log 300 MB and the run's events 12 GB, past what serve could
/// summarize.
const kept_block_size = 1 << 20;
/// Deflate's worst case is stored blocks, 5 bytes per 64 KiB block, then gzip's 18 bytes.
const kept_compressed_max = kept_block_size + kept_block_size / 1024 + 64;
const Kept = struct {
    compress: std.compress.flate.Compress,
    window: [std.compress.flate.max_window_len]u8,
    compressed: [kept_compressed_max]u8,
};
/// One per process: a worker keeps one timeline's inputs at a time (asserted). 1.4 MB, its pages
/// touched only once a timeline failed.
var kept_state: Kept = undefined;
var kept_busy: std.atomic.Value(bool) = .init(false);

/// A timeline that ended failing keeps its checks' inputs (their histories) in its log, after
/// its last event: `check_kept` events, base64 chunks in order of each input's gzip (`offset`
/// in it). What a failure is explained from without a replay (run 410: a committed
/// append lost, its history gone with the timeline, only `check_input`'s size left). Logged,
/// not hashed or counted: a replay's events compare as before. A passing timeline keeps nothing
/// (histories are megabytes).
/// The checks ran (and kept their failing inputs): the pages their inputs took go back to the
/// kernel. The buffer is reserved at its largest and touched only as used, but pages once
/// touched stay with the worker for good: one long history each would hold 256 MiB a worker.
pub fn check_release(events: *const Events) void {
    const page = std.heap.pageSize();
    const used = std.mem.alignForward(usize, events.check_used, page);
    if (used == 0 or !std.mem.isAligned(@intFromPtr(events.check_buffer.ptr), page)) return;
    _ = linux.madvise(events.check_buffer.ptr, @min(used, events.check_buffer.len), linux.MADV.DONTNEED);
}

test check_release {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    const page = std.heap.pageSize();
    const check_buffer = try std.heap.page_allocator.alloc(u8, 4 * page);
    defer std.heap.page_allocator.free(check_buffer);
    @memset(check_buffer, 0xaa);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null, .check_buffer = check_buffer });
    events.check_used = page + 1;
    events.check_release();
    // The pages the inputs took are the kernel's again (zero when touched), the rest untouched.
    try std.testing.expect(std.mem.allEqual(u8, check_buffer[0 .. 2 * page], 0));
    try std.testing.expect(std.mem.allEqual(u8, check_buffer[2 * page ..], 0xaa));
}

pub fn checks_keep(events: *const Events, moment: Moment, after: u64) void {
    const fd = events.log_fd orelse return;
    if (events.failing_count() == 0) return;
    assert(!kept_busy.swap(true, .acquire));
    defer kept_busy.store(false, .release);
    var sequence = after;
    for (0..check_count_max) |index| {
        const input = events.check_input(index) orelse continue;
        var offset: usize = 0; // In the input's gzip.
        var block_start: usize = 0;
        while (block_start < input.len) {
            const block = input[block_start..@min(input.len, block_start + kept_block_size)];
            var output: std.Io.Writer = .fixed(&kept_state.compressed);
            // Sized for deflate's worst case: the fixed writer never fills.
            kept_state.compress = std.compress.flate.Compress.init(&output, &kept_state.window, .gzip, .default) catch unreachable;
            kept_state.compress.writer.writeAll(block) catch unreachable;
            kept_state.compress.finish() catch unreachable;
            const compressed = output.buffered();
            assert(compressed.len > 0 and compressed.len <= kept_compressed_max);
            var chunk_start: usize = 0;
            while (chunk_start < compressed.len) {
                const raw = compressed[chunk_start..@min(compressed.len, chunk_start + kept_chunk_size)];
                var encoded: [std.base64.standard.Encoder.calcSize(kept_chunk_size)]u8 = undefined;
                var line_buffer: [encoded.len + 128]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &line_buffer,
                    "{{\"event\":\"check_kept\",\"details\":{{\"check\":{d},\"offset\":{d},\"data\":\"{s}\"}}}}",
                    .{ index, offset, std.base64.standard.Encoder.encode(&encoded, raw) },
                ) catch unreachable; // Sized for the largest chunk.
                sequence += 1;
                write_log_line(fd, .{ .sequence = sequence, .moment = moment, .data = line, .json = true });
                offset += raw.len;
                chunk_start += raw.len;
            }
            block_start += block.len;
        }
    }
}

/// Virtual time from the first event to `end_ns`: what the timeline's output was printed over
/// (the logging property, judged across the multiverse: report.zig).
pub fn output_span_ns(events: *const Events, end_ns: u64) u64 {
    const start_ns = events.first_vtime_ns orelse return 0;
    return end_ns -| start_ns;
}

pub fn last_event_is(events: *const Events, name: []const u8) bool {
    assert(name.len > 0);
    assert(events.last_event_name_size <= events.last_event_name.len);
    return std.mem.eql(u8, events.last_event_name[0..events.last_event_name_size], name);
}

pub fn failing_count(events: *const Events) u32 {
    var count: u32 = 0;
    for (events.properties[0..events.property_count]) |*property| {
        count += @intFromBool(!property.passing());
    }
    assert(count <= events.property_count);
    return count;
}

fn string_field(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    assert(key.len > 0);
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

const LogLine = struct { sequence: u64, moment: Moment, data: []const u8, json: bool };

/// One JSON line (the events database ingests them, store.zig): data that is not JSON is
/// written as text, `{"raw": "..."}`.
/// Where the execution is (`{"checkpoint":{"vtime_ns":..,"branches":..}}`): logged beside the
/// events, not one of them (no seq, so ingestion skips it; neither counted nor hashed), so that a
/// replay that parts from the run is placed between two checkpoints.
pub fn checkpoint(events: *const Events, moment: Moment) void {
    const fd = events.log_fd orelse return;
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{{\"checkpoint\":{{\"vtime_ns\":{d},\"branches\":{d}}}}}\n", .{
        moment.vtime_ns, moment.branches,
    }) catch unreachable; // 128 bytes fit two u64s and the keys.
    write_all(fd, line);
}

fn write_log_line(fd: linux.fd_t, line: LogLine) void {
    assert(fd >= 0);
    assert(line.sequence > 0);
    var head_buffer: [128]u8 = undefined;
    const head_format = "{{\"seq\":{d},\"vtime_ns\":{d},\"branches\":{d},\"event\":";
    const head = std.fmt.bufPrint(&head_buffer, head_format, .{
        line.sequence, line.moment.vtime_ns, line.moment.branches,
    }) catch unreachable; // 128 bytes fit three u64s and the keys.
    write_all(fd, head);
    if (line.json) {
        write_all(fd, line.data);
    } else {
        // At most 4096 bytes, each at most 6 escaped (or 4 as a byte array, for invalid UTF-8).
        var raw_buffer: [4096 * 6 + 16]u8 = undefined;
        var raw: std.Io.Writer = .fixed(&raw_buffer);
        raw.print("{{\"raw\":{f}}}", .{std.json.fmt(line.data, .{})}) catch unreachable;
        write_all(fd, raw.buffered());
    }
    write_all(fd, "}\n");
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    assert(fd >= 0);
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return; // The event log is best effort.
        written += result;
    }
    assert(written <= bytes.len);
}

test "a decision's announcement is hashed and counted, not logged" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true }));
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = pipe[1] });
    var unlogged: Events = undefined;
    const other_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(other_buffer);
    unlogged.init(other_buffer, .{ .log_fd = null });
    const announcement = "{\"decision\":{\"name\":\"fault\",\"options\":[\"crash n1\",\"pause n1\"]}}";
    for ([_]*Events{ &events, &unlogged }) |each| {
        try each.emit(.{ .vtime_ns = 1, .branches = 1 }, announcement);
        try each.emit(.{ .vtime_ns = 2, .branches = 2 }, "{\"event\":\"fault\",\"details\":{}}");
    }
    try std.testing.expectEqual(@as(u64, 2), events.count);
    try std.testing.expectEqual(unlogged.hash.final(), events.hash.final()); // The same stream.
    var logged: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &logged, logged.len);
    try std.testing.expect(linux.errno(size) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, logged[0..size], "\"decision\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, logged[0..size], "\"fault\"") != null);
    // Their names, counted, logged once as the timeline ends (after its last event's sequence).
    try events.emit(.{ .vtime_ns = 3, .branches = 3 }, "{\"decision\":{\"name\":\"thread pausing\",\"range\":2}}");
    try events.emit(.{ .vtime_ns = 4, .branches = 4 }, announcement);
    try std.testing.expectEqual(@as(u64, 5), events.announcements_log(.{ .vtime_ns = 5, .branches = 5 }));
    try std.testing.expectEqual(@as(u64, 4), events.count); // Not counted.
    const end_size = linux.read(pipe[0], &logged, logged.len);
    try std.testing.expect(linux.errno(end_size) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, logged[0..end_size], "\"decisions_announced\",\"details\":{\"fault\":2,\"thread pausing\":1}") != null);
}

test "a failing timeline keeps its checks' inputs in its log, a passing one nothing" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    const check_buffer = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(check_buffer);
    var pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true }));
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = pipe[1], .check_buffer = check_buffer });
    // A history of 5,000 bytes: three chunks in the composer's stream, three kept.
    var history: [5000]u8 = undefined;
    for (&history, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    var offset: usize = 0;
    var vtime_ns: u64 = 1;
    while (offset < history.len) : (vtime_ns += 1) {
        const raw = history[offset..@min(history.len, offset + kept_chunk_size)];
        var encoded: [std.base64.standard.Encoder.calcSize(kept_chunk_size)]u8 = undefined;
        var line: [encoded.len + 64]u8 = undefined;
        try events.emit(.{ .vtime_ns = vtime_ns, .branches = 1 }, try std.fmt.bufPrint(
            &line,
            "{{\"event\":\"check_chunk\",\"details\":{{\"check\":0,\"data\":\"{s}\"}}}}",
            .{std.base64.standard.Encoder.encode(&encoded, raw)},
        ));
        offset += raw.len;
    }
    try events.emit(.{ .vtime_ns = vtime_ns, .branches = 1 }, "{\"event\":\"check_input\",\"details\":{\"check\":0,\"bytes\":5000}}");
    try std.testing.expectEqualSlices(u8, &history, events.check_input(0).?);
    const end: Moment = .{ .vtime_ns = vtime_ns + 1, .branches = 1 };
    var read_buffer: [32 * 1024]u8 = undefined;
    _ = linux.read(pipe[0], &read_buffer, read_buffer.len); // The check_input line.
    events.checks_keep(end, events.count); // Passing: nothing kept.
    try std.testing.expectEqual(linux.E.AGAIN, linux.errno(linux.read(pipe[0], &read_buffer, read_buffer.len)));
    const count = events.count;
    try events.emit(end, "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":false}}");
    _ = linux.read(pipe[0], &read_buffer, read_buffer.len); // The assertion's line.
    events.checks_keep(end, events.count);
    try std.testing.expectEqual(count + 1, events.count); // Not counted.
    const size = linux.read(pipe[0], &read_buffer, read_buffer.len);
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(std.testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, read_buffer[0..size], '\n');
    var sequence = count + 1;
    while (lines.next()) |line| {
        const Line = struct { seq: u64, event: struct { event: []const u8, details: struct { check: u32, offset: u64, data: []const u8 } } };
        const parsed = try std.json.parseFromSlice(Line, std.testing.allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        sequence += 1;
        try std.testing.expectEqual(sequence, parsed.value.seq);
        try std.testing.expectEqualStrings("check_kept", parsed.value.event.event);
        try std.testing.expectEqual(@as(u64, kept.items.len), parsed.value.event.details.offset);
        const data = parsed.value.event.details.data;
        const decoded = try kept.addManyAsSlice(std.testing.allocator, try std.base64.standard.Decoder.calcSizeForSlice(data));
        try std.base64.standard.Decoder.decode(decoded, data);
    }
    try std.testing.expectEqual(count + 2, sequence); // One chunk: 5,000 bytes of the alphabet in gzip.
    var unzipped: [history.len + 1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &history, try gunzip_members(kept.items, &unzipped));
}

/// gzip members in a row, decompressed into `out` (a kept input's reader's work).
fn gunzip_members(gzipped: []const u8, out: []u8) ![]u8 {
    var input: std.Io.Reader = .fixed(gzipped);
    var output: std.Io.Writer = .fixed(out);
    while (input.seek < input.end) {
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
        _ = try decompress.reader.streamRemaining(&output);
    }
    return output.buffered();
}

test "an input kept in gzip members of a MiB each, in order" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    const history_size = 2 * kept_block_size + 12_345; // Three members, the last a part.
    const check_buffer = try std.testing.allocator.alloc(u8, history_size + 16);
    defer std.testing.allocator.free(check_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null, .check_buffer = check_buffer });
    for (check_buffer[0..history_size], 0..) |*byte, index| byte.* = @intCast('a' + (index * 7 + index / 1000) % 26);
    events.check_used = history_size;
    events.check_inputs[0] = .{ .start = 0, .end = history_size, .complete = true };
    const input = events.check_input(0).?;
    try std.testing.expectEqual(history_size, input.len);
    // The members as checks_keep makes them, joined: one stream to a gzip reader.
    var gzipped: std.ArrayList(u8) = .empty;
    defer gzipped.deinit(std.testing.allocator);
    var block_start: usize = 0;
    var members: usize = 0;
    while (block_start < input.len) : (members += 1) {
        const block = input[block_start..@min(input.len, block_start + kept_block_size)];
        var output: std.Io.Writer = .fixed(&kept_state.compressed);
        kept_state.compress = try std.compress.flate.Compress.init(&output, &kept_state.window, .gzip, .default);
        try kept_state.compress.writer.writeAll(block);
        try kept_state.compress.finish();
        try gzipped.appendSlice(std.testing.allocator, output.buffered());
        block_start += block.len;
    }
    try std.testing.expectEqual(@as(usize, 3), members);
    try std.testing.expect(gzipped.items.len * 20 < history_size);
    const out = try std.testing.allocator.alloc(u8, history_size + 1);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, input, try gunzip_members(gzipped.items, out));
}

test "always fails on the first false condition and records its moment" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const pass = "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":true}}";
    const fail = "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":false}}";
    try events.emit(.{ .vtime_ns = 1, .branches = 10 }, pass);
    try std.testing.expectEqual(@as(u32, 0), events.failing_count());
    try events.emit(.{ .vtime_ns = 2, .branches = 20 }, fail);
    try std.testing.expectEqual(@as(u32, 1), events.failing_count());
    try std.testing.expectEqual(@as(u64, 20), events.properties[0].first_failure.?.branches);
}

test "a location names the assertion's class, as Antithesis's SDKs send it" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const lines = [_][]const u8{
        // A JVM's: a qualified class, its simple name kept.
        "{\"antithesis_assert\":{\"display_type\":\"Always\",\"message\":\"conserved\",\"hit\":true,\"condition\":true,\"location\":{\"class\":\"com.example.Bank\",\"function\":\"transfer\",\"file\":\"/src/com/example/Bank.java\",\"begin_line\":42,\"begin_column\":5}}}",
        // Python's (determinismo's SDK too): the class the function is defined in.
        "{\"assert\":{\"type\":\"always\",\"message\":\"balanced\",\"condition\":true,\"location\":{\"file\":\"/app/bank.py\",\"line\":7,\"function\":\"audit\",\"class\":\"Ledger\"}}}",
        // A Go function's name carries its package (the class) already: not twice.
        "{\"antithesis_assert\":{\"display_type\":\"Always\",\"message\":\"ordered\",\"hit\":true,\"condition\":true,\"location\":{\"class\":\"main\",\"function\":\"main.run\",\"file\":\"/src/main.go\",\"begin_line\":3}}}",
        // None: as before.
        "{\"assert\":{\"type\":\"always\",\"message\":\"plain\",\"condition\":true,\"location\":{\"file\":\"/src/a.zig\",\"line\":9,\"function\":\"check\"}}}",
    };
    for (lines, 0..) |line, index| try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    try std.testing.expectEqualStrings("Bank.java:42 Bank.transfer", events.properties[0].where());
    try std.testing.expectEqualStrings("bank.py:7 Ledger.audit", events.properties[1].where());
    try std.testing.expectEqualStrings("main.go:3 main.run", events.properties[2].where());
    try std.testing.expectEqualStrings("a.zig:9 check", events.properties[3].where());
}

test "sometimes and reachable made true are sought; an Antithesis SDK's evaluation is a behavior" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const lines = [_][]const u8{
        "{\"assert\":{\"type\":\"sometimes\",\"message\":\"failover\",\"condition\":true}}",
        "{\"assert\":{\"type\":\"sometimes\",\"message\":\"failover\",\"condition\":false}}",
        "{\"assert\":{\"type\":\"reachable\",\"message\":\"retry path\"}}",
        "{\"assert\":{\"type\":\"always\",\"message\":\"conserved\",\"condition\":true}}",
        // An Antithesis SDK's declaration (hit false) is none; its evaluation is one, as
        // determinismo's of the same kind, message and outcome.
        "{\"antithesis_assert\":{\"display_type\":\"Sometimes\",\"message\":\"leader moved\",\"hit\":false,\"condition\":false}}",
        "{\"antithesis_assert\":{\"display_type\":\"Sometimes\",\"message\":\"leader moved\",\"hit\":true,\"condition\":true}}",
        "{\"assert\":{\"type\":\"sometimes\",\"message\":\"leader moved\",\"condition\":true}}",
        // determinismo's own declarations (the catalog's, at every timeline's start) neither:
        // they were behaviors, sought ones, labeled true, every timeline's first moments.
        "{\"assert\":{\"type\":\"reachable\",\"message\":\"declared\",\"hit\":false}}",
        "{\"assert\":{\"type\":\"always\",\"message\":\"declared too\",\"hit\":false}}",
    };
    for (lines, 0..) |line, index| try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    try std.testing.expectEqual(@as(u32, 5), events.behavior_count);
    const sought = [_]bool{ true, false, true, false, true };
    for (sought, 0..) |expected, index| try std.testing.expectEqual(expected, events.behaviors[index].sought);
    try std.testing.expectEqualStrings("sometimes \"leader moved\": true", events.behaviors[4].name());
}

test "past half its table, a timeline keeps what the tree does not know, not what it does" {
    const allocator = std.testing.allocator;
    const parse_buffer = try allocator.alloc(u8, parse_buffer_size);
    defer allocator.free(parse_buffer);
    const events = try allocator.create(Events);
    defer allocator.destroy(events);
    events.init(parse_buffer, .{ .log_fd = null });
    // The tree knew the output of sources 0 to 9999 (their behaviors' hashes, as a timeline
    // makes them: a source's name is a behavior's whole, its text's numbers are not).
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(allocator);
    var line_buffer: [128]u8 = undefined;
    const scratch = try allocator.create(Events);
    defer allocator.destroy(scratch);
    scratch.init(parse_buffer, .{ .log_fd = null });
    for (0..10_000) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"output\":{{\"source\":\"s{d}\",\"stream\":\"stdout\",\"text\":\"up\"}}}}", .{index});
        if (scratch.behavior_count == behavior_count_max) scratch.init(parse_buffer, .{ .log_fd = null });
        try scratch.emit(.{ .vtime_ns = 1, .branches = 1 }, line);
        try known.put(allocator, scratch.behaviors[scratch.behavior_count - 1].hash, {});
    }
    behaviors_seen = &known;
    defer behaviors_seen = null;
    // Known ones until half the table, then only the 192 the tree did not know get in.
    for (0..behavior_count_max + 2000) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"output\":{{\"source\":\"s{d}\",\"stream\":\"stdout\",\"text\":\"up\"}}}}", .{index});
        try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    }
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max + 192), events.behavior_count);
    try std.testing.expect(!known.contains(events.behaviors[events.behavior_count - 1].hash));
}

test "the nodes' memory-growth objective counts unless turned off" {
    const allocator = std.testing.allocator;
    const parse_buffer = try allocator.alloc(u8, parse_buffer_size);
    defer allocator.free(parse_buffer);
    const events = try allocator.create(Events);
    defer allocator.destroy(events);
    const line = "{\"optimize\":{\"message\":\"" ++ memory_growth_objective ++
        "\",\"bucket\":{\"node\":\"n1\"},\"value\":12,\"goal\":\"maximize\"}}";
    for ([_]bool{ true, false }) |on| {
        events.init(parse_buffer, .{ .log_fd = null });
        memory_objective_on = on;
        defer memory_objective_on = true;
        try events.emit(.{ .vtime_ns = 1, .branches = 1 }, line);
        try std.testing.expectEqual(@as(u32, if (on) 1 else 0), events.behavior_count);
    }
}

test "a timeline from a full snapshot table keeps room for what the tree does not know" {
    // The setup's table full (8,192 behaviors, a JVM system's startup coverage), all of them known
    // to the tree: a timeline from it drops the known ones past half its table, keeps what it
    // reaches that is new, and still not what is known.
    const allocator = std.testing.allocator;
    const parse_buffer = try allocator.alloc(u8, parse_buffer_size);
    defer allocator.free(parse_buffer);
    const events = try allocator.create(Events);
    defer allocator.destroy(events);
    events.init(parse_buffer, .{ .log_fd = null });
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(allocator);
    var line_buffer: [128]u8 = undefined;
    for (0..behavior_count_max + 100) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"startup_line\",\"details\":{{\"name\":\"line {d}\"}}}}", .{index});
        try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    }
    try std.testing.expectEqual(@as(u32, behavior_count_max), events.behavior_count);
    for (events.behaviors[0..events.behavior_count]) |behavior| try known.put(allocator, behavior.hash, {});
    const new_line = "{\"event\":\"startup_path\",\"details\":{\"name\":\"path 7\"}}";
    // Full: nothing new gets in (run 1901's every timeline).
    try events.emit(.{ .vtime_ns = 9000, .branches = 9000 }, new_line);
    try std.testing.expectEqual(@as(u32, behavior_count_max), events.behavior_count);
    behaviors_seen = &known;
    defer behaviors_seen = null;
    events.known_forget(&known);
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max), events.behavior_count);
    try events.emit(.{ .vtime_ns = 9001, .branches = 9001 }, new_line);
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max + 1), events.behavior_count);
    try std.testing.expect(!known.contains(events.behaviors[events.behavior_count - 1].hash));
    // A known one reached again is not kept, and one the table kept is found where it is.
    try events.emit(.{ .vtime_ns = 9002, .branches = 9002 }, "{\"event\":\"startup_line\",\"details\":{\"name\":\"line 8000\"}}");
    try events.emit(.{ .vtime_ns = 9003, .branches = 9003 }, "{\"event\":\"startup_line\",\"details\":{\"name\":\"line 1\"}}");
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max + 1), events.behavior_count);
}

test "past half its table, a behavior the system's last runs reached is not kept" {
    // Run 1887's first generation (Kafka, snapshotted before its nodes): its tables full of the
    // startup lines every earlier run of the system reached, the tree knowing none of them yet.
    const allocator = std.testing.allocator;
    const parse_buffer = try allocator.alloc(u8, parse_buffer_size);
    defer allocator.free(parse_buffer);
    const events = try allocator.create(Events);
    defer allocator.destroy(events);
    events.init(parse_buffer, .{ .log_fd = null });
    const scratch = try allocator.create(Events);
    defer allocator.destroy(scratch);
    scratch.init(parse_buffer, .{ .log_fd = null });
    var history: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer history.deinit(allocator);
    var line_buffer: [128]u8 = undefined;
    // The startup lines' hashes, as the last runs recorded them.
    for (0..behavior_count_max) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"startup_line\",\"details\":{{\"name\":\"line {d}\"}}}}", .{index});
        try scratch.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
        if (scratch.behavior_count == behavior_count_max) break;
    }
    for (scratch.behaviors[0..scratch.behavior_count]) |behavior| try history.put(allocator, behavior.hash, 3);
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty; // The tree knows nothing yet.
    defer known.deinit(allocator);
    behaviors_seen = &known;
    defer behaviors_seen = null;
    behaviors_history = &history;
    defer behaviors_history = null;
    for (0..behavior_count_max) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"startup_line\",\"details\":{{\"name\":\"line {d}\"}}}}", .{index});
        try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    }
    // The first half kept whatever it is, the rest of the startup known: room left.
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max), events.behavior_count);
    try std.testing.expectEqual(@as(u32, behavior_count_max - behavior_known_kept_max), events.behaviors_known_skipped);
    try std.testing.expectEqual(@as(u32, 0), events.behaviors_full_dropped);
    try events.emit(.{ .vtime_ns = 9000, .branches = 9000 }, "{\"event\":\"startup_path\",\"details\":{\"name\":\"path 7\"}}");
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max + 1), events.behavior_count);
    // And a table that began full of them (its snapshot's) makes the same room.
    behaviors_history = null;
    const full = try allocator.create(Events);
    defer allocator.destroy(full);
    full.init(parse_buffer, .{ .log_fd = null });
    for (0..behavior_count_max) |index| {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"startup_line\",\"details\":{{\"name\":\"line {d}\"}}}}", .{index});
        try full.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
    }
    try std.testing.expectEqual(@as(u32, behavior_count_max), full.behavior_count);
    try std.testing.expectEqual(@as(u32, 0), full.behaviors_full_dropped);
    try full.emit(.{ .vtime_ns = 9001, .branches = 9001 }, "{\"event\":\"startup_path\",\"details\":{\"name\":\"path 8\"}}");
    try std.testing.expectEqual(@as(u32, 1), full.behaviors_full_dropped); // Full: a new one dropped, counted.
    behaviors_history = &history;
    full.known_forget(&known);
    try std.testing.expectEqual(@as(u32, behavior_known_kept_max), full.behavior_count);
}

test "a branch point's node is the timeline's own, whatever its process's tree knew" {
    // The same events in two processes: a node maker's, whose tree knew the late behavior, and a
    // replay's, which knew none. Past half the table a known behavior is not kept, so a node
    // taken from what is kept differed (run 969, timeline 244: "kernel" against "flecs", and the
    // replay parted from its tape at the branch point's event).
    const allocator = std.testing.allocator;
    const parse_buffer = try allocator.alloc(u8, parse_buffer_size);
    defer allocator.free(parse_buffer);
    const late = "{\"output\":{\"source\":\"kernel\",\"stream\":\"stdout\",\"text\":\"up\"}}";
    const scratch = try allocator.create(Events);
    defer allocator.destroy(scratch);
    scratch.init(parse_buffer, .{ .log_fd = null });
    try scratch.emit(.{ .vtime_ns = 1, .branches = 1 }, late);
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(allocator);
    try known.put(allocator, scratch.behaviors[0].hash, {});
    var nodes: [2][]const u8 = undefined;
    for (&nodes, [_]?*const std.AutoHashMapUnmanaged(u64, void){ &known, null }) |*node, seen| {
        const events = try allocator.create(Events);
        defer allocator.destroy(events);
        events.init(parse_buffer, .{ .log_fd = null });
        behaviors_seen = seen;
        defer behaviors_seen = null;
        var line_buffer: [160]u8 = undefined;
        for (0..behavior_known_kept_max) |index| {
            const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"step\",\"details\":" ++
                "{{\"node\":\"flecs\",\"name\":\"s{d}\"}}}}", .{index});
            try events.emit(.{ .vtime_ns = index + 1, .branches = index + 1 }, line);
        }
        try events.emit(.{ .vtime_ns = behavior_known_kept_max + 1, .branches = behavior_known_kept_max + 1 }, late);
        node.* = try allocator.dupe(u8, events.branch_node());
    }
    defer for (nodes) |node| allocator.free(node);
    try std.testing.expectEqualStrings("kernel", nodes[1]);
    try std.testing.expectEqualStrings(nodes[1], nodes[0]);
}

test "a behavior keeps the node it came from" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const output = "{\"output\":{\"source\":\"yb2\",\"stream\":\"stderr\",\"text\":\"tablet 7 lagging\"}}";
    const event = "{\"event\":\"leader\",\"details\":{\"node\":\"yb3\",\"state\":\"elected\"}}";
    const assertion = "{\"assert\":{\"type\":\"sometimes\",\"message\":\"m\",\"condition\":true}}";
    try events.emit(.{ .vtime_ns = 1, .branches = 10 }, output);
    try events.emit(.{ .vtime_ns = 2, .branches = 20 }, event);
    try events.emit(.{ .vtime_ns = 3, .branches = 30 }, assertion);
    // A branch point's own event names a node, but is the platform's, not the system's.
    const branch = "{\"event\":\"faults_branch\",\"details\":{\"quiet_ended\":true,\"node\":\"yb1\"}}";
    try events.emit(.{ .vtime_ns = 4, .branches = 40 }, branch);
    // An assertion whose details name a node (det-faults' aim moved: the new leader).
    const moved = "{\"assert\":{\"type\":\"sometimes\",\"message\":\"moved\",\"condition\":true," ++
        "\"details\":{\"from\":\"yb2\",\"node\":\"yb1\"}}}";
    try events.emit(.{ .vtime_ns = 5, .branches = 50 }, moved);
    try std.testing.expectEqual(@as(u32, 4), events.behavior_count);
    try std.testing.expectEqualStrings("yb2", events.behaviors[0].node());
    try std.testing.expectEqualStrings("yb3", events.behaviors[1].node());
    try std.testing.expectEqualStrings("", events.behaviors[2].node());
    try std.testing.expectEqualStrings("yb1", events.behaviors[3].node());
}

test "learned ranges leave out every event the guest runtime emits" {
    // Each sdk.event("name", ...) of guest/runtime: the platform's (a test program's own events
    // are made with the SDK elsewhere, and count).
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "guest/runtime", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = dir.iterate();
    var buffer: [1 << 20]u8 = undefined;
    var checked: u32 = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const source = try dir.readFile(std.testing.io, entry.name, &buffer);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, "sdk.event(\"")) |found| {
            const start = found + "sdk.event(\"".len;
            const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
            at = end;
            const name = source[start..end];
            if (!platform_events.has(name)) {
                std.debug.print("guest/runtime/{s}: event \"{s}\" missing from platform_events\n", .{ entry.name, name });
                return error.PlatformEventMissing;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 50);
}
