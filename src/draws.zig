// SPDX-License-Identifier: MIT
//! A timeline's named draws, as the explorer answered them (advisor.zig): each label the guest
//! announced before a pull (`knob.<name>`, a fault's parameters, `swarm.<name>`, sdk.decide's
//! options, the workload's sdk.random_below_named), the values it drew and how often. The
//! announcements are hashed into a timeline's history but never logged (events.zig: a fifth of a
//! Raft run's events), and a tape keeps only the answers a strategy overrode, unlabeled: this is
//! where a run's decisions are read from (docs/PLAN.md: a run as a probabilistic program).
//!
//! What a live timeline drew in its own part (from its start: a tree timeline's ancestors and the
//! setup drew the rest, each in its own file), written beside its events when it ends
//! (`draws-<n>.jsonl`, the setup's `draws-setup.jsonl`), a line per label; serve ingests them
//! (store.zig's `draws`). Fixed memory, reserved once: a label past `labels_max` is counted, not
//! kept; a value past `values_max` occurrences of its label is counted in its histogram (labels
//! of `histogram_max` values or fewer) and not kept. Not part of the history: a replay asks no
//! advisor and writes none.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const labels_max = 256;
pub const name_size_max = 96;
/// The options' names of an sdk.decide, as announced (a JSON array).
pub const options_size_max = 256;
/// Each label's first occurrences (its last in a replay's `--draws-out`), with their pulls and
/// moments.
pub const values_max = 32;
/// A label of up to this many values is counted by value.
pub const histogram_max = 16;
/// Announcements that are no draw (a byte string's `"size"`: an outside answer), remembered so
/// that their next pulls cost no parse.
pub const skipped_max = 64;

pub const Kind = enum(u8) { range, options };

/// Which of a label's occurrences are kept past `values_max`: a timeline's first (what its
/// configuration drew, read by serve), or the last before a replay stopped (explore
/// --draws-out --until: a failure's last faults, which pull drew each).
pub const Keep = enum(u8) { first, last };

pub const Value = struct {
    pull: u64,
    /// The moment of the last event before the pull (a pull is no event: the draw came after it).
    after_ns: u64,
    value: u64,
    overridden: bool,
};

pub const Label = struct {
    /// The announcement's text hashed: the same label, the same entry.
    key: u64,
    name: [name_size_max]u8,
    name_size: u8,
    kind: Kind,
    /// Its range (sdk.random_below_named), or its options' count (sdk.decide).
    count_of: u64,
    /// sdk.random_config's: the bandit's configuration draws.
    config: bool,
    options: [options_size_max]u8,
    options_size: u16,
    drawn: u64,
    overridden: u64,
    histogram: [histogram_max]u64,
    values: [values_max]Value,
    value_count: u8,
    /// Where the next value goes once `values` is full and the last are kept (the oldest).
    value_next: u8,
};

pub const Draws = struct {
    labels: [labels_max]Label,
    label_count: u32,
    /// Draws of labels past `labels_max`.
    dropped: u64,
    skipped: [skipped_max]u64,
    skipped_count: u32,
    last_event_ns: u64,
    keep: Keep,
    parse_buffer: [4096]u8,

    pub fn reset(draws: *Draws, keep: Keep) void {
        draws.keep = keep;
        draws.label_count = 0;
        draws.dropped = 0;
        draws.skipped_count = 0;
        draws.last_event_ns = 0;
    }

    pub fn event_seen(draws: *Draws, vtime_ns: u64) void {
        draws.last_event_ns = vtime_ns;
    }

    /// A labeled pull's value as the guest takes it (sdk.random_below: the 8 bytes' u64 modulo the
    /// range), after every answer the explorer gave it.
    pub fn note(draws: *Draws, announcement: []const u8, pull: u64, bytes: []const u8, overridden: bool) void {
        if (bytes.len != 8) return;
        const key = std.hash.Wyhash.hash(0, announcement);
        const label = draws.label_of(key, announcement) orelse return;
        assert(label.count_of > 0);
        const value = std.mem.readInt(u64, bytes[0..8], .little) % label.count_of;
        label.drawn += 1;
        if (overridden) label.overridden += 1;
        if (label.count_of <= histogram_max) label.histogram[@intCast(value)] += 1;
        const kept: Value = .{
            .pull = pull,
            .after_ns = draws.last_event_ns,
            .value = value,
            .overridden = overridden,
        };
        if (label.value_count < values_max) {
            label.values[label.value_count] = kept;
            label.value_count += 1;
        } else if (draws.keep == .last) {
            label.values[label.value_next] = kept;
            label.value_next = @intCast((@as(u32, label.value_next) + 1) % values_max);
        }
    }

    fn label_of(draws: *Draws, key: u64, announcement: []const u8) ?*Label {
        for (draws.labels[0..draws.label_count]) |*label| {
            if (label.key == key) return label;
        }
        if (std.mem.indexOfScalar(u64, draws.skipped[0..draws.skipped_count], key) != null) return null;
        if (draws.label_count == labels_max) {
            draws.dropped += 1;
            return null;
        }
        const label = &draws.labels[draws.label_count];
        if (!label_parse(label, key, announcement, &draws.parse_buffer)) {
            if (draws.skipped_count < skipped_max) {
                draws.skipped[draws.skipped_count] = key;
                draws.skipped_count += 1;
            }
            return null;
        }
        draws.label_count += 1;
        return label;
    }

    /// A JSON line a label: its name, kind, range or options, how often drawn and overridden, its
    /// histogram (a label of `histogram_max` values or fewer) and its first values.
    pub fn write(draws: *const Draws, fd: linux.fd_t) void {
        var buffer: [16 << 10]u8 = undefined;
        for (draws.labels[0..draws.label_count]) |*label| {
            var writer: std.Io.Writer = .fixed(&buffer);
            label_write(&writer, label) catch continue;
            write_all(fd, writer.buffered());
        }
        if (draws.dropped > 0) {
            var writer: std.Io.Writer = .fixed(&buffer);
            writer.print("{{\"dropped\":{d}}}\n", .{draws.dropped}) catch return;
            write_all(fd, writer.buffered());
        }
    }
};

fn label_write(writer: *std.Io.Writer, label: *const Label) !void {
    try writer.print("{{\"name\":{f},\"kind\":\"{s}\",\"count\":{d},\"config\":{},", .{
        std.json.fmt(label.name[0..label.name_size], .{}), @tagName(label.kind), label.count_of, label.config,
    });
    if (label.kind == .options) try writer.print("\"options\":{s},", .{label.options[0..label.options_size]});
    try writer.print("\"drawn\":{d},\"overridden\":{d}", .{ label.drawn, label.overridden });
    if (label.count_of <= histogram_max) {
        try writer.writeAll(",\"histogram\":[");
        for (label.histogram[0..@intCast(label.count_of)], 0..) |n, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{n});
        }
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"kept\":[");
    // In pull order: from the oldest kept (a full ring's next slot).
    for (0..label.value_count) |index| {
        const value = label.values[(label.value_next + index) % values_max];
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"pull\":{d},\"after_ns\":{d},\"value\":{d},\"overridden\":{}}}", .{
            value.pull, value.after_ns, value.value, value.overridden,
        });
    }
    try writer.writeAll("]}\n");
}

/// An announcement's name, and its range (`"range": n`) or options (`"options": [...]`); anything
/// else (a byte string's `"size"`: an outside answer, not a choice) is not a draw kept here.
fn label_parse(label: *Label, key: u64, announcement: []const u8, buffer: []u8) bool {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), announcement, .{}) catch
        return false;
    if (value != .object) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0 or name.string.len > name_size_max) return false;
    label.* = .{
        .key = key,
        .name = undefined,
        .name_size = @intCast(name.string.len),
        .kind = .range,
        .count_of = 0,
        .config = false,
        .options = undefined,
        .options_size = 0,
        .drawn = 0,
        .overridden = 0,
        .histogram = @splat(0),
        .values = undefined,
        .value_count = 0,
        .value_next = 0,
    };
    @memcpy(label.name[0..name.string.len], name.string);
    if (value.object.get("range")) |range| {
        if (range != .integer or range.integer <= 0) return false;
        label.count_of = @intCast(range.integer);
        if (value.object.get("config")) |config| label.config = config == .bool and config.bool;
        return true;
    }
    const options = value.object.get("options") orelse return false;
    if (options != .array or options.array.items.len == 0) return false;
    // The options as announced: the text between `"options":` and the array's end.
    const at = std.mem.indexOf(u8, announcement, "\"options\":") orelse return false;
    const start = std.mem.indexOfScalarPos(u8, announcement, at, '[') orelse return false;
    const end = array_end(announcement, start) orelse return false;
    const text = announcement[start .. end + 1];
    if (text.len > options_size_max) return false;
    label.kind = .options;
    label.count_of = options.array.items.len;
    @memcpy(label.options[0..text.len], text);
    label.options_size = @intCast(text.len);
    return true;
}

/// The index of the `]` closing the array that opens at `start`, strings skipped.
fn array_end(text: []const u8, start: usize) ?usize {
    assert(text[start] == '[');
    var depth: u32 = 0;
    var in_string = false;
    var index = start;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (in_string) {
            if (byte == '\\') index += 1 else if (byte == '"') in_string = false;
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return,
        }
    }
}

test "a label's draws are its values modulo its range, counted by value" {
    const draws = try std.testing.allocator.create(Draws);
    defer std.testing.allocator.destroy(draws);
    draws.reset(.first);
    draws.event_seen(1_000);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 7, .little);
    draws.note("{\"name\":\"knob.flush\",\"range\":3}", 10, &bytes, false);
    draws.event_seen(2_000);
    std.mem.writeInt(u64, &bytes, 5, .little);
    draws.note("{\"name\":\"knob.flush\",\"range\":3}", 11, &bytes, true);
    try std.testing.expectEqual(@as(u32, 1), draws.label_count);
    const label = &draws.labels[0];
    try std.testing.expectEqualStrings("knob.flush", label.name[0..label.name_size]);
    try std.testing.expectEqual(@as(u64, 2), label.drawn);
    try std.testing.expectEqual(@as(u64, 1), label.overridden);
    try std.testing.expectEqual(@as(u64, 1), label.histogram[1]); // 7 % 3
    try std.testing.expectEqual(@as(u64, 1), label.histogram[2]); // 5 % 3
    try std.testing.expectEqual(@as(u64, 1_000), label.values[0].after_ns);
    try std.testing.expectEqual(@as(u64, 2_000), label.values[1].after_ns);
}

test "a decision's options are kept as announced; a byte string is no draw" {
    const draws = try std.testing.allocator.create(Draws);
    defer std.testing.allocator.destroy(draws);
    draws.reset(.first);
    var bytes: [8]u8 = @splat(0);
    bytes[0] = 4;
    draws.note("{\"name\":\"fault\",\"options\":[\"kill\",\"a \\\"]\\\" pause\"]}", 3, &bytes, false);
    draws.note("{\"name\":\"det.ingress_status\",\"size\":8}", 4, &bytes, false);
    draws.note("{\"name\":\"det.ingress_status\",\"size\":8}", 5, &bytes, false);
    try std.testing.expectEqual(@as(u32, 1), draws.label_count);
    try std.testing.expectEqual(@as(u64, 0), draws.dropped);
    try std.testing.expectEqual(@as(u32, 1), draws.skipped_count);
    const label = &draws.labels[0];
    try std.testing.expectEqual(Kind.options, label.kind);
    try std.testing.expectEqualStrings("[\"kill\",\"a \\\"]\\\" pause\"]", label.options[0..label.options_size]);
    try std.testing.expectEqual(@as(u64, 0), label.values[0].value); // 4 % 2
}

comptime {
    assert(histogram_max <= values_max);
    assert(name_size_max <= std.math.maxInt(u8));
    assert(options_size_max <= std.math.maxInt(u16));
}

test "a replay's draws keep each label's last values, in pull order" {
    const draws = try std.testing.allocator.create(Draws);
    defer std.testing.allocator.destroy(draws);
    draws.reset(.last);
    var bytes: [8]u8 = undefined;
    const total = values_max + 5;
    for (0..total) |pull| {
        draws.event_seen(pull * 1_000);
        std.mem.writeInt(u64, &bytes, pull, .little);
        draws.note("{\"name\":\"fault.kind\",\"range\":1000}", pull, &bytes, false);
    }
    const label = &draws.labels[0];
    try std.testing.expectEqual(@as(u64, total), label.drawn);
    try std.testing.expectEqual(@as(u8, values_max), label.value_count);
    var buffer: [16 << 10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try label_write(&writer, label);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const kept = parsed.value.object.get("kept").?.array.items;
    try std.testing.expectEqual(@as(usize, values_max), kept.len);
    for (kept, total - values_max..) |value, pull| {
        try std.testing.expectEqual(@as(i64, @intCast(pull)), value.object.get("pull").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(pull)), value.object.get("value").?.integer);
    }
    // A timeline's own draws keep the first.
    draws.reset(.first);
    for (0..total) |pull| {
        std.mem.writeInt(u64, &bytes, pull, .little);
        draws.note("{\"name\":\"fault.kind\",\"range\":1000}", pull, &bytes, false);
    }
    try std.testing.expectEqual(@as(u64, values_max - 1), draws.labels[0].values[values_max - 1].pull);
}
