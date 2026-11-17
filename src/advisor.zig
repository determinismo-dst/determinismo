// SPDX-License-Identifier: MIT
//! The explorer's advice on a live timeline's pulls (VM.Advisor): its strategy (strategy.zig: a
//! plan's named decisions, or an answer with its reason) and its bandit over configuration
//! draws (bandit.zig), in that order, as the VM asked them before they were split from it. The
//! core asks only where nothing replays and tapes every answer: what is decided here is the
//! explorer's, free to change without touching how a timeline runs.
const std = @import("std");
const VM = @import("core").vm;
const Events = @import("core").events;
const Strategy = @import("strategy.zig");
const bandit = @import("bandit.zig");
const Draws = @import("draws.zig").Draws;

/// A named decision fixed for every timeline (explore --decide "name=value"): its answer is
/// `value`, a range's number or one of the announced options by name. The intervention of a what
/// if: the run as it would go with that choice, taped as a strategy's answer (a replay repeats it).
pub const Fixed = struct { name: []const u8, value: []const u8 };
const fixed_reason = "fixed by --decide";

/// Labels the VM answers itself after the advisor's turn (vm.zig: the driver phase's length, a
/// fork's index): what the advisor sees of them is not what the guest gets, so not recorded.
const answered_after = [_][]const u8{ "{\"name\":\"composer.drive_ms\"", "{\"name\":\"det.fork_index\"" };

pub const Explorer = struct {
    strategy: ?*Strategy,
    learned: ?*const bandit.Bandit,
    /// The configuration draws' buckets this timeline drew, credited when it is judged.
    uses: [bandit.uses_max]bandit.Use = undefined,
    use_count: u8 = 0,
    /// The timeline's named draws, as answered (draws.zig): none in a replay, which asks nothing.
    draws: ?*Draws = null,
    fixed: []const Fixed = &.{},

    /// None when there is nothing to ask.
    pub fn advisor(explorer: *Explorer) ?VM.Advisor {
        if (explorer.strategy == null and explorer.learned == null and explorer.draws == null and explorer.fixed.len == 0) return null;
        return .{
            .context = explorer,
            .wants_moment = explorer.strategy != null,
            .pull = pull,
            .event = event,
            .forget = forget,
        };
    }

    fn pull(context: *anyopaque, asked: VM.Pull) anyerror!VM.Advice {
        const explorer: *Explorer = @ptrCast(@alignCast(context));
        const advice = try explorer.answer(asked);
        if (explorer.draws) |draws| if (asked.label) |text| {
            for (answered_after) |prefix| {
                if (std.mem.startsWith(u8, text, prefix)) return advice;
            }
            draws.note(text, asked.pull, asked.value, advice.overridden);
        };
        return advice;
    }

    fn answer(explorer: *Explorer, asked: VM.Pull) anyerror!VM.Advice {
        if (explorer.fixed.len > 0) if (asked.label) |text| if (asked.value.len == 8) {
            if (fixed_answer(explorer.fixed, text)) |index| {
                std.mem.writeInt(u64, asked.value[0..8], index, .little);
                return .{ .overridden = true, .reason = fixed_reason, .decision = true, .done = true };
            }
        };
        var ended = false;
        if (explorer.strategy) |strategy| {
            // A planning strategy's named decisions: drawn from its plan, no round trip (a stale
            // plan refreshed first); taped as an answer of its, without a reason.
            if (strategy.wants_plans) if (asked.label) |text| if (asked.value.len == 8) {
                const drawn = try strategy.plan_draw(text, asked.moment.vtime_ns, std.mem.readInt(u64, asked.value[0..8], .little));
                ended = strategy.take_end() or ended;
                if (drawn) |draw| {
                    std.mem.writeInt(u64, asked.value[0..8], draw.value, .little);
                    try strategy.planned_tell(asked.moment, asked.source, text, draw.value);
                    ended = strategy.take_end() or ended;
                    return .{ .overridden = true, .done = true, .ended = ended };
                }
            };
            // Asked unless it only chooses where the tree returns, the value is too large, or it
            // wants named decisions only and this pull has no name.
            if (strategy.asked(asked.label, asked.value.len)) {
                const overridden = try strategy.random(asked.pull, asked.moment, asked.source, asked.label, asked.value);
                ended = strategy.take_end() or ended; // Its batch before the decision.
                if (overridden) return .{
                    .overridden = true,
                    .reason = strategy.reason[0..strategy.reason_size],
                    .decision = true,
                    .done = true,
                    .ended = ended,
                };
            }
        }
        // A configuration draw (sdk.random_config): the bandit answers it, taped as a plan's
        // value (no reason: a regime's draws repeat all timeline long); the bucket drawn, its own
        // value's or the bandit's, noted for the judgment. Only into a tape.
        if (asked.taped) if (explorer.learned) |learned| if (asked.label) |text| if (asked.value.len == 8) if (bandit.config_label(text)) |config| {
            if (config.range < 2 or config.range > bandit.buckets_max) return .{ .done = true, .ended = ended };
            var overridden = false;
            if (learned.choose(config.name, config.range, std.mem.readInt(u64, asked.value[0..8], .little))) |bucket| {
                std.mem.writeInt(u64, asked.value[0..8], bucket, .little);
                overridden = true;
            }
            const bucket: u8 = @intCast(std.mem.readInt(u64, asked.value[0..8], .little) % config.range);
            bandit.use_note(&explorer.uses, &explorer.use_count, .{ .name = config.name, .bucket = bucket });
            return .{ .overridden = overridden, .done = true, .ended = ended };
        };
        return .{ .ended = ended };
    }

    fn event(context: *anyopaque, moment: Events.Moment, source: []const u8, line: []const u8) anyerror!bool {
        const explorer: *Explorer = @ptrCast(@alignCast(context));
        if (explorer.draws) |draws| draws.event_seen(moment.vtime_ns);
        const strategy = explorer.strategy orelse return false;
        if (!strategy.told(line)) return false;
        return try strategy.event(moment, source, line);
    }

    fn forget(context: *anyopaque) void {
        const explorer: *Explorer = @ptrCast(@alignCast(context));
        if (explorer.strategy) |strategy| strategy.forget();
    }
};

/// The answer a fixed decision gives this announcement (`{"name":...,"range":n}` or
/// `{"name":...,"options":[...]}`): its number when below the range, its option's index; none
/// for another name, or a value the announcement cannot take (left to the explorer as any pull).
fn fixed_answer(fixed: []const Fixed, announcement: []const u8) ?u64 {
    const prefix = "{\"name\":\"";
    if (!std.mem.startsWith(u8, announcement, prefix)) return null;
    const rest = announcement[prefix.len..];
    const name_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..name_end];
    const asked = for (fixed) |one| {
        if (std.mem.eql(u8, one.name, name)) break one;
    } else return null;
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), announcement, .{}) catch return null;
    if (value != .object) return null;
    if (value.object.get("range")) |range| {
        if (range != .integer or range.integer <= 0) return null;
        const number = std.fmt.parseInt(u64, asked.value, 10) catch return null;
        return if (number < @as(u64, @intCast(range.integer))) number else null;
    }
    const options = value.object.get("options") orelse return null;
    if (options != .array) return null;
    for (options.array.items, 0..) |option, index| {
        if (option == .string and std.mem.eql(u8, option.string, asked.value)) return index;
    }
    return std.fmt.parseInt(u64, asked.value, 10) catch null;
}

test "a fixed decision answers its name: a range's number, an option by name or index" {
    const fixed = [_]Fixed{ .{ .name = "knob.mode", .value = "2" }, .{ .name = "fault", .value = "pause" } };
    try std.testing.expectEqual(@as(?u64, 2), fixed_answer(&fixed, "{\"name\":\"knob.mode\",\"range\":3}"));
    try std.testing.expectEqual(@as(?u64, null), fixed_answer(&fixed, "{\"name\":\"knob.mode\",\"range\":2}"));
    try std.testing.expectEqual(@as(?u64, 1), fixed_answer(&fixed, "{\"name\":\"fault\",\"options\":[\"kill\",\"pause\"]}"));
    try std.testing.expectEqual(@as(?u64, null), fixed_answer(&fixed, "{\"name\":\"fault\",\"options\":[\"kill\",\"crash\"]}"));
    try std.testing.expectEqual(@as(?u64, null), fixed_answer(&fixed, "{\"name\":\"knob.modes\",\"range\":3}"));
}
