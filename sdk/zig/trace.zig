// SPDX-License-Identifier: MIT
//! A system walked through a spec's trace: an ITF file (the Informal Trace Format: Quint's
//! `test --out-itf` and `run --out-itf`, Apalache's counterexamples), its states in order, each
//! step the change from one state to the next. A system's adapter says how a step is caused and
//! how it is seen; the driver does the rest, the same for every system and spec:
//!   - the whole trace handed to the adapter first (`prepare`: what a later step needs armed
//!     before an earlier one, a hold for a write that lands late);
//!   - before each step, a wait drawn by its kind's name (`trace.<kind>.delay_ms`): the trace
//!     fixes the structure, the tree branches on the timings, and a race inside a node (a step
//!     no control causes) is searched only in the window the walk opens;
//!   - the step's control (`act`: a hand-over, a cut, a freeze, a hold let go; nothing for a
//!     step that follows by itself), then the system polled until it shows the step's state
//!     (`reached`), at most `wait_ms`: past it the walk diverged there, and says where.
//! Each step an event `trace_step` (the trace, its index, its kind, the wait drawn, how long it
//! took to show); the end an event `trace_walked` (steps taken of the whole, where it diverged)
//! and the catalog's "a spec trace walked to its end".
//!
//! An adapter is any type with these declarations (`adapter` a pointer to it):
//!   fn kind(adapter, step: Step) []const u8     a name for the step ("stands", "term_back")
//!   fn act(adapter, step: Step) anyerror!void    cause it
//!   fn reached(adapter, step: Step) bool         whether the system shows it now
//! and optionally:
//!   fn prepare(adapter, steps: []const Step) anyerror!void   the whole trace, once, first
//!   fn finish(adapter) void                      at the end, either way (controls left on undone)
//!   const delay_ms_max: u64, wait_ms: u64, poll_ms: u64   (defaults 500, 5000, 50)
//! A step's states are the ITF's JSON values; `int`, `field`, `get`, `tag` and `contains` read
//! them (bigints, records, maps, variants, sets).
//!
//!   const states = try sdk.trace.parse(arena, @embedFile("two_leaders.itf.json"));
//!   const outcome = sdk.trace.walk(DoubleVote, &adapter, "two_leaders", states);
const std = @import("std");
const sdk = @import("determinismo.zig");

pub const Value = std.json.Value;

/// One step: the state it starts from and the one it reaches (the ITF's states k and k+1).
pub const Step = struct {
    /// From 1: the ITF's state it reaches.
    index: usize,
    before: Value,
    after: Value,
};

pub const Outcome = struct {
    taken: usize,
    total: usize,
    /// The step the system never showed, if any.
    diverged: ?usize = null,
};

pub const Error = error{ NotAnItf, NoStates } || std.json.ParseError(std.json.Scanner);

/// The ITF's states, in order (each its variables' record, `#meta` left in).
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]const Value {
    const root = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    if (root != .object) return error.NotAnItf;
    const states = root.object.get("states") orelse return error.NotAnItf;
    if (states != .array) return error.NotAnItf;
    if (states.array.items.len < 2) return error.NoStates;
    return states.array.items;
}

/// The steps of `states`: one between each two.
pub fn steps_of(arena: std.mem.Allocator, states: []const Value) ![]const Step {
    const list = try arena.alloc(Step, states.len - 1);
    for (list, 0..) |*step, index| step.* = .{ .index = index + 1, .before = states[index], .after = states[index + 1] };
    return list;
}

/// An integer: a JSON number or the ITF's `{"#bigint": "<digits>"}`.
pub fn int(value: Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .object => |object| blk: {
            const digits = object.get("#bigint") orelse break :blk null;
            if (digits != .string) break :blk null;
            break :blk std.fmt.parseInt(i64, digits.string, 10) catch null;
        },
        else => null,
    };
}

/// A record's field.
pub fn field(value: Value, name: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(name);
}

/// A map's value at a string key (the ITF's `{"#map": [[key, value], ...]}`), or a record's
/// field of that name.
pub fn get(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    const map = value.object.get("#map") orelse return value.object.get(key);
    if (map != .array) return null;
    for (map.array.items) |pair| {
        if (pair != .array or pair.array.items.len != 2) continue;
        const name = pair.array.items[0];
        if (name == .string and std.mem.eql(u8, name.string, key)) return pair.array.items[1];
    }
    return null;
}

/// A variant's tag (`{"tag": "Leader", "value": ...}`), or a string.
pub fn tag(value: Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .object => |object| blk: {
            const name = object.get("tag") orelse break :blk null;
            break :blk if (name == .string) name.string else null;
        },
        else => null,
    };
}

/// Whether a set (`{"#set": [...]}`) holds an integer or a string.
pub fn contains(value: Value, element: anytype) bool {
    const set = field(value, "#set") orelse return false;
    if (set != .array) return false;
    for (set.array.items) |item| {
        switch (@TypeOf(element)) {
            []const u8 => if (item == .string and std.mem.eql(u8, item.string, element)) return true,
            else => if (int(item)) |number| if (number == element) return true,
        }
    }
    return false;
}

fn setting(comptime Adapter: type, comptime name: []const u8, default: u64) u64 {
    return if (@hasDecl(Adapter, name)) @field(Adapter, name) else default;
}

/// Walks the system through `states` (parse's), each step caused by `adapter` and awaited.
pub fn walk(comptime Adapter: type, adapter: *Adapter, name: []const u8, states: []const Value) Outcome {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const total = if (states.len > 0) states.len - 1 else 0;
    var outcome: Outcome = .{ .taken = 0, .total = total };
    defer if (@hasDecl(Adapter, "finish")) adapter.finish();
    const list = steps_of(arena_state.allocator(), states) catch {
        sdk.event("trace_walked", .{ .trace = name, .taken = 0, .total = total, .diverged = @as(?usize, 0), .reason = "out of memory" });
        return outcome;
    };
    if (@hasDecl(Adapter, "prepare")) {
        adapter.prepare(list) catch |err| {
            sdk.event("trace_walked", .{ .trace = name, .taken = 0, .total = total, .diverged = @as(?usize, 0), .reason = @errorName(err) });
            outcome.diverged = 0;
            return outcome;
        };
    }
    const delay_max = setting(Adapter, "delay_ms_max", 500);
    const wait_ms = setting(Adapter, "wait_ms", 5000);
    const poll_ms = @max(1, setting(Adapter, "poll_ms", 50));
    for (list) |step| {
        const kind = adapter.kind(step);
        var name_buffer: [96]u8 = undefined;
        const draw = std.fmt.bufPrint(&name_buffer, "trace.{s}.delay_ms", .{kind}) catch "trace.delay_ms";
        const delay = if (delay_max > 0) sdk.random_below_named(draw, delay_max + 1) else 0;
        if (delay > 0) sdk.sleep_ms(delay);
        adapter.act(step) catch |err| {
            sdk.event("trace_step", .{ .trace = name, .index = step.index, .kind = kind, .delay_ms = delay, .acted = false, .reason = @errorName(err) });
            outcome.diverged = step.index;
            break;
        };
        var waited: u64 = 0;
        var shown = adapter.reached(step);
        while (!shown and waited < wait_ms) {
            sdk.sleep_ms(poll_ms);
            waited += poll_ms;
            shown = adapter.reached(step);
        }
        sdk.event("trace_step", .{ .trace = name, .index = step.index, .kind = kind, .delay_ms = delay, .acted = true, .shown = shown, .waited_ms = waited });
        if (!shown) {
            outcome.diverged = step.index;
            break;
        }
        outcome.taken += 1;
    }
    sdk.event("trace_walked", .{ .trace = name, .taken = outcome.taken, .total = total, .diverged = outcome.diverged });
    sdk.assert_computed(.sometimes, outcome.diverged == null and total > 0, "a spec trace walked to its end", .{ .trace = name, .taken = outcome.taken, .total = total });
    return outcome;
}

const test_itf =
    \\{"#meta":{"format":"ITF"},"vars":["s"],"states":[
    \\ {"#meta":{"index":0},"s":{"nodes":{"#map":[["a",{"role":{"tag":"Follower","value":{"#tup":[]}},"term":{"#bigint":"1"}}]]},"voted":{"#set":[]}}},
    \\ {"#meta":{"index":1},"s":{"nodes":{"#map":[["a",{"role":{"tag":"Candidate","value":{"#tup":[]}},"term":{"#bigint":"2"}}]]},"voted":{"#set":["a"]}}},
    \\ {"#meta":{"index":2},"s":{"nodes":{"#map":[["a",{"role":{"tag":"Leader","value":{"#tup":[]}},"term":{"#bigint":"2"}}]]},"voted":{"#set":["a"]}}}
    \\]}
;

test "an ITF's states, read by their variables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const states = try parse(arena_state.allocator(), test_itf);
    try std.testing.expectEqual(@as(usize, 3), states.len);
    const a = get(field(field(states[1], "s").?, "nodes").?, "a").?;
    try std.testing.expectEqualStrings("Candidate", tag(field(a, "role").?).?);
    try std.testing.expectEqual(@as(?i64, 2), int(field(a, "term").?));
    try std.testing.expect(contains(field(field(states[1], "s").?, "voted").?, @as([]const u8, "a")));
    try std.testing.expect(!contains(field(field(states[0], "s").?, "voted").?, @as([]const u8, "a")));
    try std.testing.expectEqual(@as(?Value, null), get(field(field(states[1], "s").?, "nodes").?, "b"));
    try std.testing.expectError(error.NoStates, parse(arena_state.allocator(), "{\"states\":[{}]}"));
    try std.testing.expectError(error.NotAnItf, parse(arena_state.allocator(), "[]"));
}

/// A system of one node whose role the adapter sets (its control) and reads back.
const TestAdapter = struct {
    pub const delay_ms_max = 0;
    pub const wait_ms = 20;
    pub const poll_ms = 1;
    role: []const u8 = "Follower",
    /// A step the system never shows (the role not set).
    deaf_at: ?usize = null,
    prepared: usize = 0,
    acted: usize = 0,
    finished: bool = false,

    fn role_of(state: Value) []const u8 {
        const node = get(field(field(state, "s").?, "nodes").?, "a").?;
        return tag(field(node, "role").?).?;
    }
    pub fn prepare(adapter: *TestAdapter, list: []const Step) !void {
        adapter.prepared = list.len;
    }
    pub fn kind(_: *TestAdapter, step: Step) []const u8 {
        return role_of(step.after);
    }
    pub fn act(adapter: *TestAdapter, step: Step) !void {
        adapter.acted += 1;
        if (adapter.deaf_at == step.index) return;
        adapter.role = role_of(step.after);
    }
    pub fn reached(adapter: *TestAdapter, step: Step) bool {
        return std.mem.eql(u8, adapter.role, role_of(step.after));
    }
    pub fn finish(adapter: *TestAdapter) void {
        adapter.finished = true;
    }
};

test "a walk takes each step in order, and names the one the system never showed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const states = try parse(arena_state.allocator(), test_itf);
    var whole: TestAdapter = .{};
    const done = walk(TestAdapter, &whole, "test", states);
    try std.testing.expectEqual(Outcome{ .taken = 2, .total = 2, .diverged = null }, done);
    try std.testing.expectEqualStrings("Leader", whole.role);
    try std.testing.expectEqual(@as(usize, 2), whole.prepared);
    try std.testing.expect(whole.finished);
    var deaf: TestAdapter = .{ .deaf_at = 2 };
    const stuck = walk(TestAdapter, &deaf, "test", states);
    try std.testing.expectEqual(Outcome{ .taken = 1, .total = 2, .diverged = 2 }, stuck);
    try std.testing.expectEqual(@as(usize, 2), deaf.acted);
    try std.testing.expect(deaf.finished);
}
