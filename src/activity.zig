// SPDX-License-Identifier: MIT
//! A run's activity over wall time, for serve's charts of where its workers' time went: a hunt
//! slowing down by its end (run 454) had longer timelines, replays to the moments it returned
//! to, or idle CPUs, and nothing said which. Each process of a run appends a line to the run
//! directory's activity.jsonl as something it did ends (O_APPEND, one write a line: whole,
//! whatever the processes): the explorer its setup, timelines and judgments (and what each
//! generation judged found new); node makers and
//! holders the nodes they made, by where from; the verifier its replays. Every 10 s the explorer
//! also says what runs, what is queued and the memory available. Times are the epoch's
//! milliseconds (CLOCK_REALTIME: the same in every process). serve bins them by minute
//! (`minutes`).
const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;

pub const Kind = enum { setup, timeline, node_memory, node_disk, node_replay, verify, judge };
pub const kind_count = @typeInfo(Kind).@"enum".field_names.len;

/// The run's log in this process (forks inherit it; CLOEXEC: programs exec'd do not).
var fd: linux.fd_t = -1;

/// The run's log opened, from its explorer: `workers` its timelines at once, and its setup,
/// from `start_ms` to now, the first thing in it.
pub fn open(directory: []const u8, workers: u32, start_ms: u64) void {
    var buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buffer, "{s}/activity.jsonl", .{directory}, 0) catch return;
    const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    fd = @intCast(opened);
    const now = now_ms();
    write("{{\"a\":\"run\",\"s\":{d},\"w\":{d}}}\n", .{ start_ms, workers });
    interval(.setup, start_ms, now, .{});
}

pub fn now_ms() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ms_per_s + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

/// The epoch's milliseconds at `monotonic_ns` (CLOCK_MONOTONIC), a moment past.
pub fn ms_of_monotonic(monotonic_ns: u64) u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    const now_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
    return now_ms() -| (now_ns -| monotonic_ns) / std.time.ns_per_ms;
}

pub const Extra = struct {
    /// A timeline's virtual time, how long it waited for memory and a CPU, and its index (the
    /// samples name the running ones by it).
    vtime_ns: u64 = 0,
    wait_ns: u64 = 0,
    index: u32 = 0,
};

pub fn interval(kind: Kind, start_ms: u64, end_ms: u64, extra: Extra) void {
    write("{{\"a\":\"{s}\",\"s\":{d},\"e\":{d},\"v\":{d},\"w\":{d},\"i\":{d}}}\n", .{
        @tagName(kind),                      start_ms,                           @max(start_ms, end_ms),
        extra.vtime_ns / std.time.ns_per_ms, extra.wait_ns / std.time.ns_per_ms, extra.index,
    });
}

/// What runs now: the timelines running, each since when and its index (a timeline is written
/// once it ends, so until then these count it as running), nodes being made, timelines queued;
/// the host's memory available.
/// `holders`: the run's holders kept in memory; `anonymous`, `shared`: the host's AnonPages and
/// Shmem (cpus.memory_split), in MiB as `m` is: what a run holds outside its VMs' claims over time
/// (Kafka 1919's resume, srv4 at 3 GB: 40 GB anonymous beside 92 GB of guest memory).
pub fn sample(running_start_ms: []const u64, running_index: []const u32, nodes: u32, queued: u32, available_bytes: u64, holders: u32, anonymous_bytes: u64, shared_bytes: u64) void {
    assert(running_start_ms.len == running_index.len);
    if (fd < 0) return;
    var buffer: [line_max]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    out.print("{{\"a\":\"sample\",\"t\":{d},\"r\":{d},\"n\":{d},\"q\":{d},\"m\":{d},\"h\":{d},\"an\":{d},\"sh\":{d},\"o\":[", .{
        now_ms(), running_start_ms.len, nodes, queued, available_bytes >> 20, holders, anonymous_bytes >> 20, shared_bytes >> 20,
    }) catch return;
    for (running_start_ms, running_index, 0..) |start, index, at| {
        out.print("{s}[{d},{d}]", .{ if (at > 0) "," else "", start, index }) catch return;
    }
    out.writeAll("]}\n") catch return;
    _ = linux.write(fd, out.buffered().ptr, out.buffered().len);
}

/// The explorer starts no timeline from now on (a drain asked, or its budget over), those
/// running going on to their ends beside whatever takes the freed cores (the next hunt): its
/// cores are its running timelines' alone from here (the hunt queue's throughput line).
pub fn ending(why: []const u8) void {
    write("{{\"a\":\"ending\",\"t\":{d},\"why\":\"{s}\"}}\n", .{ now_ms(), why });
}

/// The tree ended with `count` of its holders still listening after its release: holders the
/// registry never had (a leak: their memory stays until the explorer exits, through its closing
/// replays; Kafka 1919: 46, 129 GB). The e2e drained check expects none.
pub fn holders_left(count: u32) void {
    write("{{\"a\":\"holders_left\",\"t\":{d},\"n\":{d}}}\n", .{ now_ms(), count });
}

/// A timeline that ran nothing: still waiting for its CPU as its run drained or passed its
/// budget (a resume runs it from its start). Neither run nor cut: `w` its wait, in ms.
pub fn unstarted(index: u32, wait_ms: u64) void {
    write("{{\"a\":\"unstarted\",\"t\":{d},\"i\":{d},\"w\":{d}}}\n", .{ now_ms(), index, wait_ms });
}

/// A generation judged: the behaviors new to the tree in it, and those it knows now (what the
/// tree steers by, and the hunt queue's plateau rule reads).
pub fn found(new: u64, known: u64) void {
    write("{{\"a\":\"found\",\"t\":{d},\"n\":{d},\"k\":{d}}}\n", .{ now_ms(), new, known });
}

/// A line's bytes at most: a sample of 256 timelines running fits (each about 26 bytes).
const line_max = 8192;

fn write(comptime format: []const u8, arguments: anytype) void {
    if (fd < 0) return;
    var buffer: [line_max]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, arguments) catch return;
    _ = linux.write(fd, text.ptr, text.len); // A line lost is a chart a little off: never a failure.
}

// Minutes ----------------------------------------------------------------------------------------

pub const minute_ms = 60 * std.time.ms_per_s;
/// A week of minutes at most: a longer run's last ones are left out.
pub const minutes_max = 7 * 24 * 60;

pub const Minute = struct {
    /// Timelines that ended in it.
    timelines: u32 = 0,
    /// The virtual time timelines explored in it (each its own spread over its wall time), and
    /// how long they waited for memory or a CPU.
    vtime_ms: u64 = 0,
    wait_ms: u64 = 0,
    /// Each kind's time in it, every process's added up: 60 s a CPU kept busy all minute.
    busy_ms: [kind_count]u64 = @splat(0),
    samples: u32 = 0,
    running_sum: u64 = 0,
    nodes_sum: u64 = 0,
    queued_sum: u64 = 0,
    available_mb_min: ?u64 = null,
    /// Behaviors new to the tree in the generations judged in it, and the most it knew then.
    found: u64 = 0,
    known: ?u64 = null,
};

pub const Activity = struct {
    start_ms: u64 = 0,
    /// Its last line's moment: the last minute covers only up to it.
    end_ms: u64 = 0,
    workers: u32 = 0,
    minutes: []Minute = &.{},
    /// From then on the minutes still fill in: the oldest timeline running at the last sample
    /// began then (its virtual time and waits are counted once it ends). Null: all settled.
    settling_ms: ?u64 = null,

    fn at(activity: *const Activity, at_ms: u64) ?*Minute {
        if (at_ms < activity.start_ms) return null;
        const index = (at_ms - activity.start_ms) / minute_ms;
        return if (index < activity.minutes.len) &activity.minutes[index] else null;
    }

    /// An interval's time into the minutes it overlaps; a timeline's virtual time and waits in
    /// proportion.
    fn spread(activity: *const Activity, kind: Kind, line: Line) void {
        const start = @max(line.s, activity.start_ms);
        if (line.e <= start) return;
        const length = line.e - line.s;
        var from = start;
        while (from < line.e) {
            const index = (from - activity.start_ms) / minute_ms;
            if (index >= activity.minutes.len) return;
            const minute_end = activity.start_ms + (index + 1) * minute_ms;
            const overlap = @min(line.e, minute_end) - from;
            const into = &activity.minutes[index];
            into.busy_ms[@backingInt(kind)] += overlap;
            if (kind == .timeline) {
                into.vtime_ms += line.v * overlap / length;
                into.wait_ms += line.w * overlap / length;
            }
            from += overlap;
        }
    }
};

const Line = struct {
    a: []const u8,
    s: u64 = 0,
    e: u64 = 0,
    v: u64 = 0,
    w: u64 = 0,
    t: u64 = 0,
    r: u64 = 0,
    n: u64 = 0,
    q: u64 = 0,
    m: u64 = 0,
    k: u64 = 0,
    i: u64 = 0,
    o: []const [2]u64 = &.{},
};

/// The run's activity log by minute from its start (its first `run` line). Lines that do not
/// parse (a last one being written) are left out.
pub fn minutes(arena: std.mem.Allocator, text: []const u8) !Activity {
    var activity: Activity = .{};
    var lines: std.ArrayList(Line) = .empty;
    var split = std.mem.tokenizeScalar(u8, text, '\n');
    var end_ms: u64 = 0;
    var last_sample: ?Line = null;
    var ended: std.AutoHashMapUnmanaged(u64, void) = .empty;
    while (split.next()) |raw| {
        const line = std.json.parseFromSliceLeaky(Line, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, line.a, "run")) {
            if (activity.start_ms == 0) activity.start_ms = line.s;
            activity.workers = @intCast(line.w); // A resumed run's: its last.
            continue;
        }
        end_ms = @max(end_ms, line.e, line.t);
        if (std.mem.eql(u8, line.a, "sample") and (last_sample == null or line.t >= last_sample.?.t)) last_sample = line;
        try lines.append(arena, line);
    }
    if (activity.start_ms == 0 or end_ms <= activity.start_ms) return activity;
    activity.end_ms = end_ms;
    const count = @min(minutes_max, (end_ms - activity.start_ms) / minute_ms + 1);
    activity.minutes = try arena.alloc(Minute, count);
    @memset(activity.minutes, .{});
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.a, "sample")) {
            const into = activity.at(line.t) orelse continue;
            into.samples += 1;
            into.running_sum += line.r;
            into.nodes_sum += line.n;
            into.queued_sum += line.q;
            into.available_mb_min = @min(into.available_mb_min orelse line.m, line.m);
            continue;
        }
        if (std.mem.eql(u8, line.a, "found")) {
            const into = activity.at(line.t) orelse continue;
            into.found += line.n;
            into.known = @max(into.known orelse line.k, line.k);
            continue;
        }
        const kind = std.meta.stringToEnum(Kind, line.a) orelse continue;
        if (kind == .timeline) {
            if (activity.at(line.e)) |into| into.timelines += 1;
            try ended.put(arena, line.i, {});
        }
        activity.spread(kind, line);
    }
    // The timelines running at the last sample and not ended since: running to the log's end.
    if (last_sample) |sampled| for (sampled.o) |running| {
        const start = running[0];
        if (ended.contains(running[1])) continue;
        activity.spread(.timeline, .{ .a = "timeline", .s = start, .e = end_ms });
        activity.settling_ms = @min(activity.settling_ms orelse start, start);
    };
    return activity;
}

/// The minutes as serve answers them (GET /runs/<id>/activity): seconds a minute by kind, the
/// samples' averages, the memory's lowest.
pub fn write_json(activity: Activity, out: *std.Io.Writer) !void {
    try out.print("{{\"start_ms\":{d},\"end_ms\":{d},\"workers\":{d},\"minute_s\":60,", .{ activity.start_ms, activity.end_ms, activity.workers });
    if (activity.settling_ms) |settling| try out.print("\"settling_ms\":{d},", .{settling});
    try out.writeAll("\"minutes\":[");
    for (activity.minutes, 0..) |item, index| {
        if (index > 0) try out.writeAll(",");
        try out.print("{{\"timelines\":{d},\"vtime_s\":{d:.1},\"wait_s\":{d:.1},\"busy_s\":{{", .{
            item.timelines, seconds(item.vtime_ms), seconds(item.wait_ms),
        });
        for (item.busy_ms, 0..) |busy, kind| {
            if (kind > 0) try out.writeAll(",");
            try out.print("\"{s}\":{d:.1}", .{ @tagName(@as(Kind, @fromBackingInt(@intCast(kind)))), seconds(busy) });
        }
        try out.writeAll("}");
        if (item.samples > 0) {
            const samples: f64 = @floatFromInt(item.samples);
            try out.print(",\"running\":{d:.1},\"nodes\":{d:.1},\"queued\":{d:.1}", .{
                @as(f64, @floatFromInt(item.running_sum)) / samples,
                @as(f64, @floatFromInt(item.nodes_sum)) / samples,
                @as(f64, @floatFromInt(item.queued_sum)) / samples,
            });
        }
        if (item.available_mb_min) |mb| try out.print(",\"available_gb\":{d:.1}", .{@as(f64, @floatFromInt(mb)) / 1024});
        if (item.known) |known| try out.print(",\"found\":{d},\"known\":{d}", .{ item.found, known });
        try out.writeAll("}");
    }
    try out.writeAll("]}\n");
}

fn seconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / std.time.ms_per_s;
}

test minutes {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The setup the first 30 s; a timeline from 30 s to 150 s (120 s, 600 s virtual, 12 s
    // waiting); a node replayed over the minute boundary; a sample; a line being written.
    const text =
        \\{"a":"run","s":1000000,"w":4}
        \\{"a":"setup","s":1000000,"e":1030000,"v":0,"w":0}
        \\{"a":"timeline","s":1030000,"e":1150000,"v":600000,"w":12000,"i":3}
        \\{"a":"node_replay","s":1050000,"e":1070000,"v":0,"w":0}
        \\{"a":"sample","t":1065000,"r":3,"n":1,"q":5,"m":20480,"o":[]}
        \\{"a":"sample","t":1170000,"r":2,"n":0,"q":0,"m":30720,"o":[[1030000,3],[1160000,9]]}
        \\{"a":"found","t":1100000,"n":7,"k":70}
        \\{"a":"timeline","s":1100
    ;
    const activity = try minutes(arena, text);
    try std.testing.expectEqual(1000000, activity.start_ms);
    try std.testing.expectEqual(1170000, activity.end_ms);
    try std.testing.expectEqual(4, activity.workers);
    try std.testing.expectEqual(3, activity.minutes.len);
    const first = activity.minutes[0];
    try std.testing.expectEqual(30000, first.busy_ms[@backingInt(Kind.setup)]);
    try std.testing.expectEqual(30000, first.busy_ms[@backingInt(Kind.timeline)]);
    try std.testing.expectEqual(150000, first.vtime_ms); // A quarter of its 600 s.
    try std.testing.expectEqual(10000, first.busy_ms[@backingInt(Kind.node_replay)]);
    try std.testing.expectEqual(10000, activity.minutes[1].busy_ms[@backingInt(Kind.node_replay)]);
    try std.testing.expectEqual(1, activity.minutes[1].samples);
    try std.testing.expectEqual(7, activity.minutes[1].found);
    try std.testing.expectEqual(70, activity.minutes[1].known.?);
    try std.testing.expectEqual(20480, activity.minutes[1].available_mb_min.?);
    try std.testing.expectEqual(0, activity.minutes[1].timelines);
    try std.testing.expectEqual(1, activity.minutes[2].timelines);
    // The one ended (30 s of it, counted once though the last sample still lists it) and the one
    // still running at the last sample (10 s, to the log's end).
    try std.testing.expectEqual(40000, activity.minutes[2].busy_ms[@backingInt(Kind.timeline)]);
    try std.testing.expectEqual(1160000, activity.settling_ms.?);
    var total: u64 = 0;
    for (activity.minutes) |item| total += item.wait_ms;
    try std.testing.expectEqual(12000, total);
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write_json(activity, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"node_replay\":10.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"available_gb\":20.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"settling_ms\":1160000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"found\":7,\"known\":70") != null);
}
