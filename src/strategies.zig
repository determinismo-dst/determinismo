// SPDX-License-Identifier: MIT
//! A run's strategy plugins, one or several (`--strategy` given more than once; serve's
//! `strategy` one per line): each a Strategy (strategy.zig) on its own transport, asked in the
//! order given. What one plugin would answer, the first that answers does: a decision, a
//! timeline's seed and clock, where the tree returns; every plugin hears the timelines' starts,
//! ends and the events it wants; the machine passes from one plugin to the next (each sees what
//! the ones before it decided); every checker's verdicts are the timeline's; the setup is told to
//! each that wants it. A planning plugin's plan draws first, as one alone's did.
//!
//! Followed (`--strategy-follow`, serve's `strategy_follow`): a plugin whose command names a
//! file (a program, or a module after `wasm:`) runs from a copy of it kept by content
//! (runs.artifact_keep), and before each timeline the file is read again: new bytes are kept
//! and that plugin restarted on them, so an upload reaches the run's next timelines while the
//! running ones keep theirs. Each timeline's tape says the plugins it ran with (`commands`).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Strategy = @import("strategy.zig");
const runs = @import("runs.zig");
const Events = @import("core").events;

pub const plugins_max = 8;

plugins: []*Strategy,
/// What any of them asks for (each plugin is asked only for what it wants).
decides: bool = false,
wants_setup: bool = false,
wants_machine: bool = false,
wants_check: bool = false,
wants_behaviors: bool = false,
/// The first plugin that plans its decisions: drawn from before any is asked.
planner: ?*Strategy = null,
wants_plans: bool = false,
/// The last answer's reason (the plugin that answered: its own buffer).
reason: []const u8 = "",
ended: bool = false,
name_buffer: [Strategy.name_size_max * plugins_max + plugins_max]u8 = undefined,
name_size: usize = 0,
/// The plugins' commands as run, one a line (a followed plugin's kept copy): each tape's.
commands: []const u8 = "",
/// Following their files (Follow), each plugin's source if it is followed.
follow: ?Follow = null,
sources: [plugins_max]?Source = @splat(null),
/// What hello said, for a plugin started again.
exploration_seed: u64 = 0,
run_url: ?[]const u8 = null,
environ: [:null]const ?[*:0]const u8 = &.{},

pub const Follow = struct { io: std.Io, data: []const u8 };

/// A followed plugin's file, its command around it, and the bytes last run.
const Source = struct { path: []const u8, rest: []const u8, hash: u64 };

const Strategies = @This();

/// `commands`: one plugin's command per line (start's forms: a program and its arguments,
/// `tcp://`, `image:`, `wasm:`). `follow`: their files followed (the module's head).
pub fn start(
    strategies: *Strategies,
    arena: std.mem.Allocator,
    commands: []const u8,
    environ: [:null]const ?[*:0]const u8,
    follow: ?Follow,
) !void {
    strategies.* = .{ .plugins = &.{}, .follow = follow, .environ = environ };
    var plugins: std.ArrayList(*Strategy) = .empty;
    var lines = std.mem.tokenizeScalar(u8, commands, '\n');
    while (lines.next()) |line| {
        var command = std.mem.trim(u8, line, " \t\r");
        if (command.len == 0) continue;
        if (plugins.items.len == plugins_max) return error.TooManyPlugins;
        if (follow) |given| if (try source_of(arena, given, command)) |source| {
            strategies.sources[plugins.items.len] = source;
            command = try kept_command(arena, given, source);
        };
        const plugin = try arena.create(Strategy);
        try plugin.start(arena, command, environ);
        try plugins.append(arena, plugin);
    }
    if (plugins.items.len == 0) return error.NoStrategy;
    strategies.plugins = plugins.items;
    try strategies.commands_set(arena);
}

/// A command's file (a program's path, or a module's after `wasm:`), if it names one: followed.
fn source_of(arena: std.mem.Allocator, follow: Follow, command: []const u8) !?Source {
    const bare = if (std.mem.startsWith(u8, command, "wasm:")) command["wasm:".len..] else command;
    const end = std.mem.indexOfScalar(u8, bare, ' ') orelse bare.len;
    const path = bare[0..end];
    if (std.mem.indexOfScalar(u8, path, '/') == null) return null; // A program found in PATH.
    _ = arena;
    const hash = file_hash(follow.io, path) orelse return null;
    return .{ .path = path, .rest = bare[end..], .hash = hash };
}

/// A file's content hash (runs.artifact_keep's), read through a buffer freed at once: asked
/// before every timeline, never held.
fn file_hash(io: std.Io, path: []const u8) ?u64 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(64 << 20)) catch return null;
    defer std.heap.page_allocator.free(bytes);
    return std.hash.Wyhash.hash(0, bytes);
}

/// Its kept copy's command: a module's (by its bytes) after `wasm:`, its arguments after it.
fn kept_command(arena: std.mem.Allocator, follow: Follow, source: Source) ![]const u8 {
    const kept = try runs.artifact_keep(arena, follow.io, follow.data, source.path);
    var magic: [4]u8 = @splat(0);
    const file = try std.Io.Dir.cwd().openFile(follow.io, kept, .{});
    defer file.close(follow.io);
    _ = file.readPositionalAll(follow.io, &magic, 0) catch 0;
    const prefix = if (std.mem.eql(u8, &magic, "\x00asm")) "wasm:" else "";
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, kept, source.rest });
}

fn commands_set(strategies: *Strategies, arena: std.mem.Allocator) !void {
    var text: std.Io.Writer.Allocating = .init(arena);
    for (strategies.plugins, 0..) |plugin, index| {
        if (index > 0) try text.writer.writeAll("\n");
        try text.writer.writeAll(plugin.command);
    }
    strategies.commands = text.written()[0..@min(text.written().len, @import("core").tape.strategy_size_max)];
}

/// Before a timeline: each followed plugin's file read again; new bytes kept and that plugin
/// started again on them (said on standard error). Whether one was.
pub fn refresh(strategies: *Strategies, arena: std.mem.Allocator) !bool {
    const follow = strategies.follow orelse return false;
    var changed = false;
    for (strategies.plugins, 0..) |*plugin, index| {
        const known = strategies.sources[index] orelse continue;
        const now = file_hash(follow.io, known.path) orelse continue;
        if (now == known.hash) continue;
        var source = known;
        source.hash = now;
        const command = try kept_command(arena, follow, source);
        plugin.*.stop();
        const fresh = try arena.create(Strategy);
        try fresh.start(arena, command, strategies.environ);
        try fresh.hello(strategies.exploration_seed, strategies.run_url);
        plugin.* = fresh;
        strategies.sources[index] = source;
        changed = true;
        std.debug.print("[determinismo] strategy: {s} new, its next timelines on {s}\n", .{ source.path, command });
    }
    if (changed) {
        strategies.aggregate();
        try strategies.commands_set(arena);
    }
    return changed;
}

pub fn hello(strategies: *Strategies, exploration_seed: u64, run_url: ?[]const u8) !void {
    strategies.exploration_seed = exploration_seed;
    strategies.run_url = run_url;
    for (strategies.plugins) |plugin| try plugin.hello(exploration_seed, run_url);
    strategies.aggregate();
}

/// What they ask for and their names, from each plugin's hello.
fn aggregate(strategies: *Strategies) void {
    strategies.decides = false;
    strategies.wants_setup = false;
    strategies.wants_machine = false;
    strategies.wants_check = false;
    strategies.wants_behaviors = false;
    strategies.planner = null;
    var writer: std.Io.Writer = .fixed(&strategies.name_buffer);
    for (strategies.plugins, 0..) |plugin, index| {
        strategies.decides = strategies.decides or plugin.decides;
        strategies.wants_setup = strategies.wants_setup or plugin.wants_setup;
        strategies.wants_machine = strategies.wants_machine or plugin.wants_machine;
        strategies.wants_check = strategies.wants_check or plugin.wants_check;
        strategies.wants_behaviors = strategies.wants_behaviors or plugin.wants_behaviors;
        if (plugin.wants_plans and strategies.planner == null) strategies.planner = plugin;
        if (index > 0) writer.writeAll("+") catch {};
        writer.writeAll(plugin.hello_name()) catch {};
    }
    strategies.wants_plans = strategies.planner != null;
    strategies.name_size = writer.buffered().len;
}

/// Their names, joined by `+` (one alone's own).
pub fn hello_name(strategies: *const Strategies) []const u8 {
    return strategies.name_buffer[0..strategies.name_size];
}

pub fn forget(strategies: *Strategies) void {
    for (strategies.plugins) |plugin| plugin.forget();
}

pub fn stop(strategies: *Strategies) void {
    for (strategies.plugins) |plugin| plugin.stop();
}

/// Their connections' descriptors, for a process that must close them (replays.Verifier).
pub fn held(strategies: *const Strategies, out: []linux.fd_t) []const linux.fd_t {
    var count: usize = 0;
    for (strategies.plugins) |plugin| {
        if (plugin.wasm != null) continue;
        if (count + 2 > out.len) break;
        out[count] = plugin.to_plugin;
        out[count + 1] = plugin.from_plugin;
        count += 2;
    }
    return out[0..count];
}

/// Each hears the timeline's start; the first to choose its seed, and the first to choose its
/// clock, give them.
pub fn branch(strategies: *Strategies, index: u32, seed: u64, from: ?Strategy.From) !Strategy.BranchChoice {
    var choice: Strategy.BranchChoice = .{};
    for (strategies.plugins) |plugin| {
        const own = try plugin.branch(index, seed, from);
        if (choice.seed == null) choice.seed = own.seed;
        if (choice.jitter_seed == null) choice.jitter_seed = own.jitter_seed;
        if (choice.margin_branches == null) choice.margin_branches = own.margin_branches;
    }
    return choice;
}

/// Each hears its end; it ends early if any says so.
pub fn branch_end(strategies: *Strategies, end: Strategy.BranchEnd) !bool {
    var ended = false;
    for (strategies.plugins) |plugin| ended = (try plugin.branch_end(end)) or ended;
    return ended;
}

/// The machine through each that wants it, in order: each given the one before it decided.
pub fn machine(strategies: *Strategies, arena: std.mem.Allocator, given: Strategy.MachineChoice) !Strategy.MachineChoice {
    assert(strategies.wants_machine);
    var decided = given;
    for (strategies.plugins) |plugin| {
        if (plugin.wants_machine) decided = try plugin.machine(arena, decided);
    }
    return decided;
}

pub fn setup(strategies: *Strategies, seed: u64) !void {
    for (strategies.plugins) |plugin| if (plugin.wants_setup) try plugin.setup(seed);
}

/// Every checker's verdicts, in the plugins' order, at most `lines.len`.
pub fn judge(strategies: *Strategies, index: u32, histories: []const Strategy.History, buffer: []u8, lines: [][]const u8) !usize {
    assert(lines.len >= Strategy.check_assertions_max);
    var count: usize = 0;
    var used: usize = 0;
    const own = try std.heap.page_allocator.alloc(u8, Strategy.check_assertions_max * Strategy.check_line_size_max);
    defer std.heap.page_allocator.free(own);
    var own_lines: [Strategy.check_assertions_max][]const u8 = undefined;
    for (strategies.plugins) |plugin| {
        if (!plugin.wants_check) continue;
        const said = try plugin.judge(index, histories, own, &own_lines);
        for (own_lines[0..said]) |line| {
            if (count == lines.len or used + line.len > buffer.len) break;
            @memcpy(buffer[used..][0..line.len], line);
            lines[count] = buffer[used..][0..line.len];
            used += line.len;
            count += 1;
        }
    }
    return count;
}

/// Where the tree returns: each is told the generation (a plugin that only chooses returns
/// decides nothing else: `decides` false); the first that names returns gives them (and its fill).
pub fn returns(
    strategies: *Strategies,
    arena: std.mem.Allocator,
    generation: u32,
    candidates: []const Strategy.Candidate,
    archive: []const Strategy.ArchiveCell,
    count: u32,
    branches: u32,
    budget: u32,
) !Strategy.Answer {
    var answer: Strategy.Answer = .{};
    for (strategies.plugins) |plugin| {
        const own = try plugin.returns(arena, generation, candidates, archive, count, branches, budget);
        if (answer.returns.len == 0 and own.returns.len > 0) answer = own;
    }
    return answer;
}

/// Whether any plugin is asked for this pull.
pub fn asked(strategies: *const Strategies, label: ?[]const u8, size: usize) bool {
    for (strategies.plugins) |plugin| if (plugin.asked(label, size)) return true;
    return false;
}

/// A pull asked of each that is asked for it, in order, until one answers: `reason` is then
/// that one's.
pub fn random(
    strategies: *Strategies,
    pull: u64,
    moment: Events.Moment,
    source: []const u8,
    label: ?[]const u8,
    value: []u8,
) !bool {
    for (strategies.plugins) |plugin| {
        if (!plugin.asked(label, value.len)) continue;
        const overridden = try plugin.random(pull, moment, source, label, value);
        strategies.ended = plugin.take_end() or strategies.ended;
        if (overridden) {
            strategies.reason = plugin.reason[0..plugin.reason_size];
            return true;
        }
    }
    strategies.reason = "";
    return false;
}

/// Whether any plugin is told of this line.
pub fn told(strategies: *const Strategies, line: []const u8) bool {
    for (strategies.plugins) |plugin| if (plugin.told(line)) return true;
    return false;
}

/// The event to each that is told of it: the timeline ends if any says so.
pub fn event(strategies: *Strategies, moment: Events.Moment, source: []const u8, data: []const u8) !bool {
    var ended = false;
    for (strategies.plugins) |plugin| {
        if (plugin.told(data)) ended = (try plugin.event(moment, source, data)) or ended;
    }
    return ended;
}

/// Whether a plugin ended the timeline since asked last (each plugin's, taken).
pub fn take_end(strategies: *Strategies) bool {
    var ended = strategies.ended;
    strategies.ended = false;
    for (strategies.plugins) |plugin| ended = plugin.take_end() or ended;
    return ended;
}

pub fn plan_draw(strategies: *Strategies, label: []const u8, vtime_ns: u64, default: u64) !?Strategy.Draw {
    return strategies.planner.?.plan_draw(label, vtime_ns, default);
}

pub fn planned_tell(strategies: *Strategies, moment: Events.Moment, source: []const u8, label: []const u8, value: u64) !void {
    return strategies.planner.?.planned_tell(moment, source, label, value);
}

test "several plugins' names, joined" {
    var strategies: Strategies = .{ .plugins = &.{} };
    var writer: std.Io.Writer = .fixed(&strategies.name_buffer);
    try writer.writeAll("a+b");
    strategies.name_size = writer.buffered().len;
    try std.testing.expectEqualStrings("a+b", strategies.hello_name());
}
