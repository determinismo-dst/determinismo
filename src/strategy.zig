// SPDX-License-Identifier: MIT
//! determinismo's side of the strategy-plugin protocol (docs/PLUGINS.md): spawns the plugin, and
//! sends it one JSON line per request and reads one JSON line back. All buffers are fixed and
//! live in this struct, which the caller reserves once.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Events = @import("core").events;
const tape = @import("core").tape;
const wasm_plugin = @import("wasm_plugin.zig");

pub const override_size_max = tape.override_size_max;
pub const reason_size_max = tape.reason_size_max;
const name_size_max = 128;
const line_size_max = 16 * 1024;
const parse_buffer_size = 64 * 1024;
const argument_count_max = 16;
/// Events held for a batched plugin before they go (`wants_batched`).
const batch_size_max = 256 * 1024;
const batch_prefix = "{\"method\":\"events\",\"events\":[";
const batch_suffix = "]}";
/// A plan's limits (`wants_plans`): decisions it weighs, segments a decision's values make.
/// A plugin on this host takes its calls through a shared mapping instead of its socket when its
/// hello says `"ring": true` (a TCP plugin at 127.0.0.1): the request written into the mapping, a
/// word flipped with a futex wake, the reply read back from it; the explorer spins a little before
/// it sleeps, the round trip a few microseconds instead of a socket's tens. The socket stays open,
/// carrying nothing: its end is the plugin's. docs/PLUGINS.md's `ring`.
pub const Ring = extern struct {
    magic: [8]u8,
    /// `ring_idle`, `ring_request` (posted by the explorer), `ring_reply` (posted by the plugin).
    state: std.atomic.Value(u32),
    request_size: u32,
    reply_size: u32,
    reserved: [44]u8,
};
const ring_magic = "DETRING1";
const ring_idle = 0;
const ring_request = 1;
const ring_reply = 2;
const ring_request_at = @sizeOf(Ring);
/// A memfd's pages are taken as they are written: the room costs what requests use.
const ring_request_size_max = 16 << 20;
const ring_reply_at = ring_request_at + ring_request_size_max;
const ring_size = std.mem.alignForward(usize, ring_reply_at + line_size_max, std.heap.page_size_min);
/// POLLRDHUP (x86-64's): the peer closed its end; std.os.linux.POLL leaves it out.
const poll_rdhup = 0x2000;
/// Spins before the futex: a plugin answering at once (compiled code) is waited for without a
/// sleep, one that takes longer (a JSON decoder) costs this much CPU a call at most.
const ring_spins = 4096;
/// How long a futex sleep lasts before the plugin's socket is looked at (its end ends the wait).
const ring_wait_ns = 100 * std.time.ns_per_ms;
comptime {
    assert(@sizeOf(Ring) == 64);
    assert(ring_size % std.heap.page_size_min == 0);
}

pub const plan_labels_max = 16;
pub const plan_segments_max = 16;
const plan_name_size_max = 64;
/// How stale a plan may be, in virtual time, before a planned decision sends the events held
/// (an empty batch if none) for a fresh one.
pub const plan_refresh_ns = std.time.ns_per_s;

/// A plan's weights over a named decision's values: segments [low, high), each its weight.
pub const Planned = struct {
    name: [plan_name_size_max]u8 = undefined,
    name_size: u8 = 0,
    segment_count: u8 = 0,
    low: [plan_segments_max]u64 = undefined,
    high: [plan_segments_max]u64 = undefined,
    weight: [plan_segments_max]f64 = undefined,
};

/// A plan's draw: the value written, from which segment, and that segment's share.
pub const Draw = struct { value: u64, low: u64, high: u64, share: f64 };

/// The plugin's process, or 0 for a plugin reached over TCP (it runs elsewhere).
pid: linux.pid_t,
to_plugin: linux.fd_t,
from_plugin: linux.fd_t,
request: [line_size_max]u8,
response: [line_size_max]u8,
response_start: u32,
response_end: u32,
parse_buffer: [parse_buffer_size]u8,
/// The reason the last overriding answer gave, if any.
reason: [reason_size_max]u8 = undefined,
reason_size: u8 = 0,
/// The name its hello gave (`clojure/jev-blend-logs`): what a run shows beside its command.
name_buffer: [name_size_max]u8 = undefined,
name_size: u8 = 0,
/// From its hello: whether it is asked for decisions and told events (a plugin that only
/// chooses where the tree returns says no: no round trip per decision), and whether the tree's
/// `returns` gives it each candidate's behaviors.
decides: bool = true,
wants_behaviors: bool = false,
/// `"wants": ["labeled"]`: asked only for the decisions the guest named (`fault`, the SDKs'
/// `decide`); the other pulls keep their defaults with no round trip. A plugin that answers only
/// named decisions (llm.py, jev.py) served from afar (a laptop, through a tunnel: 26 ms a round
/// trip) costs a timeline a round trip per decision instead of one per pull.
wants_labeled: bool = false,
/// `"wants": ["assertions"]`: told only of assertions, guidance and faults, not every log line.
wants_assertions: bool = false,
/// `"wants": ["coverage"]` besides: told of the coverage events too (code a timeline reached,
/// `{"event":"coverage","details":{"name":"line <file>:<n>"}}`), live, as the timeline goes.
wants_coverage: bool = false,
/// `"wants": ["batched"]`: told of events in batches, not one round trip each (a 12 s bank
/// timeline told 4600 events through a 25 ms tunnel took 115 s, 2026-11-07): held, then sent
/// together as one `events` request before the next request that needs the plugin (a decision,
/// the timeline's end) or once `batch` fills. An `end` in its reply ends the timeline there.
wants_batched: bool = false,
/// `batch_prefix`, then the held events (`batch_count` of them), comma-separated.
batch: [batch_size_max]u8 = undefined,
batch_size: u32 = 0,
batch_count: u32 = 0,
/// A batch's reply ended the timeline (`take_end`).
ended: bool = false,
/// `"wants": ["plans"]` (with `"batched"`): never asked for a named decision; the explorer
/// draws it from the plan the plugin's last reply to a batch gave (`"plan": {"<name>": [[low,
/// high, weight], ...]}`), the default where it gives none: no round trip per decision. Told of
/// each decision's announcement, and of each value a plan drew (`{"event":"planned",...}`).
wants_plans: bool = false,
/// `"wants": ["setup"]`: the setup's decisions are its too (announced with `setup`, then asked
/// as a timeline's; on the setup's tape), not only the timelines'.
wants_setup: bool = false,
/// `"wants": ["machine"]`: asked for the machine a run boots before it does (`machine`).
wants_machine: bool = false,
/// `"wants": ["check"]`: asked to judge each timeline that ended (`check`, at its end moment):
/// its assertions are the timeline's, as a host check's (checks.zig).
wants_check: bool = false,
plan: [plan_labels_max]Planned = undefined,
plan_count: u8 = 0,
/// When the last batch went (virtual time): a plan older than `plan_refresh_ns` is refreshed.
flushed_ns: u64 = 0,
/// Whether the plugin's TCP connection is to this host (127.0.0.1): a ring can be offered.
loopback: bool = false,
/// The shared mapping the calls go through, once the plugin took it (`Ring` at its start).
ring: ?[]align(std.heap.page_size_min) u8 = null,
/// A module loaded into the explorer (`wasm:`, wasm_plugin.zig): calls are direct, no fds.
wasm: ?*wasm_plugin.Plugin = null,

const Strategy = @This();

const image_prefix = "image:";
/// How an `image:` plugin runs: its container's input and output are the protocol's pipes, its
/// logs not kept (its standard error goes to determinismo's, as a command's does).
const image_command = [_][*:0]const u8{ "podman", "run", "--rm", "--interactive", "--network=host", "--log-driver=none" };
comptime {
    assert(image_command.len < argument_count_max);
}

/// `command` is the plugin's program followed by its arguments, separated by spaces; a program
/// without a slash is looked up in PATH, as a shell would. The plugin inherits `environ`. Or
/// `tcp://<IPv4 address>:<port>`: a plugin already listening there, anywhere (one connection
/// per exploration worker; an SSH tunnel brings one from a laptop). Or `image:<reference>
/// [arguments]`: a plugin packaged as a container image, its dependencies in it (`podman run
/// --rm -i --network=host <reference> [arguments]`: the image's entrypoint is the plugin, on the
/// host's network as a command's would be, its run_url reachable), a container per exploration
/// worker, gone once its input closes.
pub fn start(
    strategy: *Strategy,
    arena: std.mem.Allocator,
    command: []const u8,
    environ: [:null]const ?[*:0]const u8,
) !void {
    assert(command.len > 0);
    strategy.wasm = null;
    if (std.mem.startsWith(u8, command, wasm_plugin.prefix)) {
        strategy.wasm = try wasm_plugin.load(arena, command[wasm_plugin.prefix.len..]);
        strategy.pid = 0;
        strategy.to_plugin = -1;
        strategy.from_plugin = -1;
        strategy.response_start = 0;
        strategy.response_end = 0;
        strategy.loopback = false;
        strategy.ring = null;
        return;
    }
    if (std.mem.startsWith(u8, command, "tcp://")) return strategy.connect(command["tcp://".len..]);
    var argv: [argument_count_max + 1:null]?[*:0]const u8 = @splat(null);
    var count: u32 = 0;
    const image = std.mem.startsWith(u8, command, image_prefix);
    if (image) {
        for (image_command) |word| {
            argv[count] = word;
            count += 1;
        }
    }
    var words = std.mem.tokenizeScalar(u8, if (image) command[image_prefix.len..] else command, ' ');
    if (image and words.peek() == null) return error.NoImage;
    while (words.next()) |word| {
        if (count == argument_count_max) return error.TooManyArguments;
        argv[count] = try arena.dupeSentinel(u8, word, 0);
        count += 1;
    }
    const program = try program_find(arena, std.mem.span(argv[0].?), environ);
    var requests: [2]linux.fd_t = undefined;
    var responses: [2]linux.fd_t = undefined;
    try check(linux.pipe2(&requests, .{ .CLOEXEC = true }));
    try check(linux.pipe2(&responses, .{ .CLOEXEC = true }));
    const pid = linux.fork();
    try check(pid);
    if (pid == 0) {
        _ = linux.dup2(requests[0], 0);
        _ = linux.dup2(responses[1], 1);
        _ = linux.execve(program, &argv, environ.ptr);
        linux.exit_group(127);
    }
    _ = linux.close(requests[0]);
    _ = linux.close(responses[1]);
    strategy.pid = @intCast(pid);
    strategy.to_plugin = requests[1];
    strategy.from_plugin = responses[0];
    strategy.response_start = 0;
    strategy.response_end = 0;
    strategy.loopback = false;
    strategy.ring = null;
}

fn connect(strategy: *Strategy, address_text: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.BadAddress;
    const port = std.fmt.parseInt(u16, address_text[colon + 1 ..], 10) catch
        return error.BadAddress;
    const host = address_text[0..colon];
    var address: [4]u8 = undefined;
    if (std.mem.eql(u8, host, "localhost")) {
        address = .{ 127, 0, 0, 1 };
    } else {
        var parts = std.mem.splitScalar(u8, host, '.');
        for (&address) |*byte| {
            byte.* = std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10) catch
                return error.BadAddress;
        }
        if (parts.next() != null) return error.BadAddress;
    }
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try check(socket);
    const fd: linux.fd_t = @intCast(socket);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    check(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) catch {
        _ = linux.close(fd);
        std.debug.print("[determinismo] strategy: nothing listens at {s}\n", .{address_text});
        return error.PluginUnreachable;
    };
    strategy.pid = 0;
    strategy.wasm = null; // Its own fields all set here: a test connects without start.
    strategy.to_plugin = fd;
    strategy.from_plugin = @intCast(linux.dup(fd)); // Closed separately, as pipes would be.
    strategy.response_start = 0;
    strategy.response_end = 0;
    strategy.loopback = address[0] == 127;
    strategy.ring = null;
}

fn program_find(
    arena: std.mem.Allocator,
    name: []const u8,
    environ: [:null]const ?[*:0]const u8,
) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try arena.dupeSentinel(u8, name, 0);
    const path = for (environ) |entry| {
        const text = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, text, "PATH=")) break text["PATH=".len..];
    } else "/usr/local/bin:/usr/bin:/bin";
    var directories = std.mem.tokenizeScalar(u8, path, ':');
    while (directories.next()) |directory| {
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, name }, 0);
        if (linux.errno(linux.access(candidate, linux.X_OK)) == .SUCCESS) return candidate;
    }
    std.debug.print("[determinismo] strategy: {s} not found in PATH\n", .{name});
    return error.PluginNotFound;
}

/// In a process forked from the one that started the plugin: its connection closed here, never
/// waited for. A fork that kept it (a holder, a tree's timeline) would keep the plugin from seeing
/// the end of its input when its owner stops it, and the owner would wait forever (a Tetris
/// tree with a returns-only strategy, srv3 2026-10-29: every timeline stuck at its end).
pub fn forget(strategy: *Strategy) void {
    if (strategy.wasm != null) return; // In this process: nothing held for another.
    strategy.ring_unmap();
    _ = linux.close(strategy.to_plugin);
    _ = linux.close(strategy.from_plugin);
}

pub fn stop(strategy: *Strategy) void {
    if (strategy.wasm != null) return; // In this process: gone with it.
    strategy.ring_unmap();
    _ = linux.close(strategy.to_plugin); // The plugin sees end of input and exits.
    _ = linux.close(strategy.from_plugin);
    if (strategy.pid == 0) return; // Remote: its connection closed.
    var status: i32 = 0;
    _ = linux.waitpid(strategy.pid, &status, 0);
}

/// `run_url`: the run's HTTP API under serve (its events, SQL, earlier runs of the system), for
/// a strategy that wants more than the events it is sent; null outside serve.
pub fn hello(strategy: *Strategy, exploration_seed: u64, run_url: ?[]const u8) !void {
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"hello\",\"protocol\":1,\"exploration_seed\":\"{x:0>16}\",\"run_url\":{f}", .{
        exploration_seed, std.json.fmt(run_url, .{}),
    });
    // A module has no argv: what followed its path, here.
    if (strategy.wasm) |plugin| try writer.print(",\"arguments\":{f}", .{std.json.fmt(plugin.arguments, .{})});
    try writer.writeAll("}");
    const reply = try strategy.call(writer.buffered());
    const name = reply.get("name") orelse return error.BadPluginReply;
    if (name != .string) return error.BadPluginReply;
    strategy.decides = true;
    strategy.wants_behaviors = false;
    strategy.wants_labeled = false;
    strategy.wants_assertions = false;
    strategy.wants_coverage = false;
    // Every field with a default too: a TCP plugin's struct is set field by field (connect),
    // from undefined memory (a batch_size of garbage panicked the first batched run).
    strategy.wants_batched = false;
    strategy.wants_plans = false;
    strategy.wants_setup = false;
    strategy.wants_machine = false;
    strategy.wants_check = false;
    strategy.plan_count = 0;
    strategy.flushed_ns = 0;
    strategy.batch_count = 0;
    strategy.batch_size = 0;
    strategy.ended = false;
    strategy.reason_size = 0;
    if (reply.get("decides")) |decides| if (decides == .bool) {
        strategy.decides = decides.bool;
    };
    if (reply.get("wants")) |wants| if (wants == .array) for (wants.array.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, "behaviors")) strategy.wants_behaviors = true;
        if (std.mem.eql(u8, item.string, "labeled")) strategy.wants_labeled = true;
        if (std.mem.eql(u8, item.string, "assertions")) strategy.wants_assertions = true;
        if (std.mem.eql(u8, item.string, "coverage")) strategy.wants_coverage = true;
        if (std.mem.eql(u8, item.string, "batched")) strategy.wants_batched = true;
        if (std.mem.eql(u8, item.string, "plans")) strategy.wants_plans = true;
        if (std.mem.eql(u8, item.string, "setup")) strategy.wants_setup = true;
        if (std.mem.eql(u8, item.string, "machine")) strategy.wants_machine = true;
        if (std.mem.eql(u8, item.string, "check")) strategy.wants_check = true;
    };
    // A plan comes with a batch's reply: plans need batches.
    if (strategy.wants_plans) strategy.wants_batched = true;
    const ring_asked = if (reply.get("ring")) |ring| ring == .bool and ring.bool else false;
    std.debug.print("[determinismo] strategy: {s}\n", .{name.string});
    strategy.name_size = @intCast(@min(name.string.len, name_size_max));
    @memcpy(strategy.name_buffer[0..strategy.name_size], name.string[0..strategy.name_size]);
    if (ring_asked and strategy.pid == 0 and strategy.loopback) try strategy.ring_open();
}

/// The shared mapping offered to a plugin that asked for it: a memfd it opens through this
/// process's /proc entry, the layout in the request. Taken when it answers `"ring": true`; the
/// socket carries the calls otherwise.
fn ring_open(strategy: *Strategy) !void {
    assert(strategy.ring == null);
    const created = linux.memfd_create("determinismo-ring", linux.MFD.CLOEXEC);
    try check(created);
    const fd: linux.fd_t = @intCast(created);
    defer _ = linux.close(fd); // The mapping stays; the plugin has opened its own by its answer.
    try check(linux.ftruncate(fd, ring_size));
    const mapped = linux.mmap(null, ring_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    try check(mapped);
    const memory: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(mapped))[0..ring_size];
    const ring: *Ring = @ptrCast(memory.ptr);
    ring.* = .{
        .magic = ring_magic.*,
        .state = .init(ring_idle),
        .request_size = 0,
        .reply_size = 0,
        .reserved = @splat(0),
    };
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"ring\",\"path\":\"/proc/{d}/fd/{d}\",\"size\":{d}," ++
        "\"request_at\":{d},\"reply_at\":{d},\"reply_max\":{d}}}", .{
        linux.getpid(), fd, ring_size, ring_request_at, ring_reply_at, line_size_max,
    });
    const reply = strategy.call(writer.buffered()) catch |err| {
        _ = linux.munmap(memory.ptr, memory.len);
        return err;
    };
    const taken = if (reply.get("ring")) |value| value == .bool and value.bool else false;
    if (!taken) {
        _ = linux.munmap(memory.ptr, memory.len);
        return;
    }
    strategy.ring = memory;
    std.debug.print("[determinismo] strategy: its calls through a shared mapping\n", .{});
}

fn ring_unmap(strategy: *Strategy) void {
    const memory = strategy.ring orelse return;
    _ = linux.munmap(memory.ptr, memory.len);
    strategy.ring = null;
}

pub fn hello_name(strategy: *const Strategy) []const u8 {
    return strategy.name_buffer[0..strategy.name_size];
}

/// Whether the plugin is asked for this pull: it decides, the value fits an override, and it is
/// a named decision unless the plugin wants every pull.
pub fn asked(strategy: *const Strategy, label: ?[]const u8, size: usize) bool {
    if (strategy.wants_plans) return false; // Drawn from its plan, or the default.
    return strategy.decides and size <= override_size_max and
        (label != null or !strategy.wants_labeled);
}

/// Whether the plugin is told of this guest event: it decides, and the event is an assertion,
/// guidance or a fault unless it wants every event.
pub fn told(strategy: *const Strategy, line: []const u8) bool {
    if (!strategy.decides) return false;
    if (!strategy.wants_assertions) return true;
    const kinds = [_][]const u8{
        "{\"assert\":", "{\"antithesis_assert\":", "{\"guidance\":", "{\"event\":\"fault\",",
    };
    for (kinds) |kind| if (std.mem.startsWith(u8, line, kind)) return true;
    // A planning plugin learns the decisions there are (names, options, ranges) from them.
    if (strategy.wants_plans and std.mem.startsWith(u8, line, "{\"decision\":")) return true;
    return strategy.wants_coverage and std.mem.startsWith(u8, line, "{\"event\":\"coverage\",");
}

test "a plugin that wants named decisions and assertions is asked and told only those" {
    var strategy: Strategy = undefined;
    strategy.decides = true;
    strategy.wants_labeled = true;
    strategy.wants_assertions = true;
    try std.testing.expect(strategy.asked("{\"name\":\"fault\",\"options\":[\"a\"]}", 8));
    try std.testing.expect(!strategy.asked(null, 8));
    try std.testing.expect(!strategy.asked("{\"name\":\"fault\"}", override_size_max + 1));
    try std.testing.expect(strategy.told("{\"assert\":{\"type\":\"always\",\"message\":\"m\"}}"));
    try std.testing.expect(strategy.told("{\"event\":\"fault\",\"details\":{}}"));
    try std.testing.expect(!strategy.told("{\"log\":\"entering leader state\"}"));
    const coverage = "{\"event\":\"coverage\",\"details\":{\"name\":\"line main.go:112\"}}";
    strategy.wants_coverage = false;
    try std.testing.expect(!strategy.told(coverage));
    strategy.wants_coverage = true; // Coverage besides: told live.
    try std.testing.expect(strategy.told(coverage));
    try std.testing.expect(!strategy.told("{\"log\":\"entering leader state\"}"));
    strategy.wants_labeled = false;
    strategy.wants_assertions = false;
    try std.testing.expect(strategy.asked(null, 8));
    try std.testing.expect(strategy.told("{\"log\":\"entering leader state\"}"));
    strategy.decides = false;
    try std.testing.expect(!strategy.asked("{\"name\":\"fault\"}", 8));
    try std.testing.expect(!strategy.told("{\"assert\":{}}"));
}

/// Where a branch starts when not at the setup snapshot: a moment of another (the tree's).
pub const From = struct { branch: u32, vtime_ns: u64 };

/// A timeline's start: its index, seed and where it branches from. The reply may give the
/// timeline another seed (`{"seed":"<16 hex digits>"}`: which random future it gets), its tape's
/// header then saying it: null keeps the explorer's.
pub fn branch(strategy: *Strategy, index: u32, seed: u64, from: ?From) !?u64 {
    // A plan is a timeline's: the next one's first named decision asks for its own.
    strategy.plan_count = 0;
    strategy.flushed_ns = 0;
    strategy.ended = false;
    var writer: std.Io.Writer = .fixed(&strategy.request);
    const format = "{{\"method\":\"branch\",\"index\":{d},\"seed\":\"{x:0>16}\"";
    try writer.print(format, .{ index, seed });
    if (from) |parent| {
        try writer.print(",\"from\":{{\"branch\":{d},\"vtime_ns\":{d}}}", .{
            parent.branch, parent.vtime_ns,
        });
    }
    try writer.writeAll("}");
    const reply = try strategy.call(writer.buffered());
    const chosen = reply.get("seed") orelse return null;
    if (chosen != .string or chosen.string.len != 16) return error.BadPluginReply;
    return std.fmt.parseInt(u64, chosen.string, 16) catch error.BadPluginReply;
}

/// What a run's machine may be: the guest's wall clock no later than 2100, a timer's slack at
/// most a second, CPU modulation's stretches from a microsecond to ten seconds.
const epoch_seconds_max = 4102444800;
const timer_slack_us_max = std.time.us_per_s;
const stretch_us_min = 1;
const stretch_us_max = 10 * std.time.us_per_s;

/// The machine a run boots, a strategy's to decide when it wants (`"wants":["machine"]`):
/// `{"method":"machine","epoch_seconds":E,"timer_slack_us":S,"timer_delay_permille":D,
/// "tsc_jitter_seed":"<hex>","modulation_stretch_us":[low,high]}`, the run's own (D: how far into
/// its slack a timer lands at the earliest, thousandths); a reply may also give
/// `"custom_faults":[{"node","command"},...]`, faults of its own the injector draws among a
/// node's (each command run in the node, as a profile's custom fault), and the reply's fields replace them
/// (each within its bounds, else BadPluginReply). Asked once, before the machine is made.
pub const MachineChoice = struct { machine: tape.Machine, tsc_jitter_seed: u64 };

/// A plugin's own faults (its machine's `custom_faults`): at most this many, each a node's name
/// and a command run in it as a profile's custom fault (an absolute path, then arguments).
/// Their text ("node\tcommand\n" each) is at most custom_faults_size_max bytes: twice that in
/// hex on the guest's command line, as long as a --fault-exclusions pattern's.
pub const custom_faults_max = 4;
pub const custom_faults_size_max = 256;

pub fn machine(strategy: *Strategy, arena: std.mem.Allocator, given: MachineChoice) !MachineChoice {
    assert(strategy.wants_machine);
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"machine\",\"epoch_seconds\":{d},\"timer_slack_us\":{d},\"timer_delay_permille\":{d},\"tsc_jitter_seed\":\"{x:0>16}\",\"modulation_stretch_us\":[{d},{d}]}}", .{
        given.machine.epoch_seconds,
        given.machine.timer_slack_ns / std.time.ns_per_us,
        given.machine.timer_delay_permille,
        given.tsc_jitter_seed,
        given.machine.modulation_stretch_ns[0] / std.time.ns_per_us,
        given.machine.modulation_stretch_ns[1] / std.time.ns_per_us,
    });
    const reply = try strategy.call(writer.buffered());
    var chosen = given;
    if (reply.get("epoch_seconds")) |value| {
        if (value != .integer or value.integer <= 0 or value.integer > epoch_seconds_max) return error.BadPluginReply;
        chosen.machine.epoch_seconds = @intCast(value.integer);
    }
    if (reply.get("timer_slack_us")) |value| {
        if (value != .integer or value.integer < 0 or value.integer > timer_slack_us_max) return error.BadPluginReply;
        chosen.machine.timer_slack_ns = @as(u64, @intCast(value.integer)) * std.time.ns_per_us;
    }
    if (reply.get("timer_delay_permille")) |value| {
        if (value != .integer or value.integer < 0 or value.integer > 1000) return error.BadPluginReply;
        chosen.machine.timer_delay_permille = @intCast(value.integer);
    }
    if (reply.get("custom_faults")) |value| {
        if (value != .array or value.array.items.len > custom_faults_max) return error.BadPluginReply;
        // On the guest's command line as det-faults reads it: hex of "node\tcommand\n"...
        var listed: [custom_faults_size_max]u8 = undefined;
        var text: std.Io.Writer = .fixed(&listed);
        for (value.array.items) |item| {
            if (item != .object) return error.BadPluginReply;
            const node = item.object.get("node") orelse return error.BadPluginReply;
            const command = item.object.get("command") orelse return error.BadPluginReply;
            if (node != .string or command != .string) return error.BadPluginReply;
            if (node.string.len == 0) return error.BadPluginReply;
            for (node.string) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.BadPluginReply;
            if (command.string.len < 2 or command.string[0] != '/') return error.BadPluginReply;
            for (command.string) |c| if (c < 0x20 or c == 0x7f) return error.BadPluginReply;
            text.print("{s}\t{s}\n", .{ node.string, command.string }) catch return error.BadPluginReply;
        }
        chosen.machine.custom_faults = try std.fmt.allocPrint(arena, "{x}", .{text.buffered()});
    }
    if (reply.get("tsc_jitter_seed")) |value| {
        if (value != .string or value.string.len != 16) return error.BadPluginReply;
        chosen.tsc_jitter_seed = std.fmt.parseInt(u64, value.string, 16) catch return error.BadPluginReply;
    }
    if (reply.get("modulation_stretch_us")) |value| {
        if (value != .array or value.array.items.len != 2) return error.BadPluginReply;
        var stretch: [2]u64 = undefined;
        for (value.array.items, &stretch) |item, *bound| {
            if (item != .integer or item.integer < stretch_us_min or item.integer > stretch_us_max) return error.BadPluginReply;
            bound.* = @as(u64, @intCast(item.integer)) * std.time.ns_per_us;
        }
        if (stretch[0] >= stretch[1]) return error.BadPluginReply;
        chosen.machine.modulation_stretch_ns = stretch;
    }
    return chosen;
}

/// The setup's start, before the snapshot every timeline starts from: its decisions are the
/// strategy's too (`{"method":"branch","index":0,"seed":...,"setup":true}`), on the setup's tape.
pub fn setup(strategy: *Strategy, seed: u64) !void {
    strategy.plan_count = 0;
    strategy.flushed_ns = 0;
    strategy.ended = false;
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"branch\",\"index\":0,\"seed\":\"{x:0>16}\",\"setup\":true}}", .{seed});
    _ = try strategy.call(writer.buffered());
}

/// A branch of the generation that just ended, as the tree explorer saw it: `novel` behaviors no
/// branch before it had, the last of them (`moment_ns`, `label`) where it would return.
pub const Candidate = struct {
    branch: u32,
    start_ns: u64,
    end_ns: u64,
    novel: u32,
    moment_ns: ?u64,
    label: []const u8,
    /// With `"wants": ["behaviors"]` in its hello: the behaviors it reached itself (after it
    /// began), each with how many timelines of the generation reached it when no earlier
    /// generation had (0: known before), and how many timelines reached it before.
    behaviors: []const Behavior = &.{},
};

pub const Behavior = struct {
    label: []const u8,
    vtime_ns: u64,
    new_in_generation: u32,
    timelines_before: u32,
};

/// One of the explorer's Go-Explore archive cells, offered with a generation's timelines: just
/// after a behavior (`label`) as `branch` reached it at `vtime_ns`, how many timelines reached
/// it, how many returns went there and how many of those found something new. A plugin returns
/// there by its branch and moment, and the cell is credited as the explorer's own return.
pub const ArchiveCell = struct {
    branch: u32,
    vtime_ns: u64,
    label: []const u8,
    timelines: u32,
    returns: u32,
    paid: u32,
};

/// A moment of a branch to return to, and why.
pub const Return = struct {
    branch: u32,
    vtime_ns: u64,
    reason: []const u8,
    /// How long the returned branches run past the moment (null: `--horizon`, or to the end).
    horizon_ns: ?u64 = null,
    /// How many timelines branch from it (null: `--return-branches`, 4 by default).
    branches: ?u32 = null,
};

/// What fills the next generation's timelines the strategy's returns leave: the explorer's own
/// returns (its frontier, then its archive), or fresh starts from the setup snapshot.
pub const Fill = enum { explorer, fresh };

/// A strategy's answer to `returns`: its moments, and what fills the rest of the generation.
pub const Answer = struct { returns: []const Return = &.{}, fill: Fill = .explorer };

/// The tree explorer asks where to return after a generation: the plugin answers
/// `{"returns": [{"branch": B, "vtime_ns": T, "reason": "...", "horizon_ns": H, "branches": N},
/// ...], "fill": "explorer"|"fresh"}` (`horizon_ns`, `branches` and `fill` optional), or `{}` to
/// leave it to the explorer. `count`: the explorer's own number of returns (the default shape,
/// `branches` timelines each); `budget`: the timelines of the next generation, which its returns'
/// branches may take whole (the rest start fresh, or the explorer's returns with `fill`
/// "explorer", its default). `archive`: the explorer's most promising archive cells, offered
/// beside the candidates. Reasons are copied into `arena`.
pub fn returns(
    strategy: *Strategy,
    arena: std.mem.Allocator,
    generation: u32,
    candidates: []const Candidate,
    archive: []const ArchiveCell,
    count: u32,
    branches: u32,
    budget: u32,
) !Answer {
    assert(branches > 0 and budget > 0);
    // Not the fixed request buffer: with behaviors, a generation's candidates run to megabytes.
    var writer: std.Io.Writer.Allocating = .init(arena);
    try writer.writer.print("{{\"method\":\"returns\",\"generation\":{d},\"count\":{d}," ++
        "\"branches\":{d},\"budget\":{d},\"candidates\":{f},\"archive\":{f}}}", .{
        generation, count, branches, budget, std.json.fmt(candidates, .{}), std.json.fmt(archive, .{}),
    });
    const reply = try strategy.call_long(writer.written());
    return answer_parse(arena, reply, branches, budget);
}

/// A `returns` reply read: its moments (at most `budget` timelines' worth of branches, `branches`
/// each unless they say), what fills the rest.
fn answer_parse(arena: std.mem.Allocator, reply: std.json.ObjectMap, branches: u32, budget: u32) !Answer {
    assert(branches > 0 and budget > 0);
    const fill: Fill = if (reply.get("fill")) |value| switch (value) {
        .string => |text| std.meta.stringToEnum(Fill, text) orelse return error.BadPluginReply,
        .null => .explorer,
        else => return error.BadPluginReply,
    } else .explorer;
    const list = reply.get("returns") orelse return .{ .fill = fill };
    if (list != .array) return error.BadPluginReply;
    var chosen: std.ArrayList(Return) = .empty;
    var taken: u32 = 0; // Branches so far: within the budget.
    for (list.array.items) |item| {
        if (taken >= budget) break;
        if (item != .object) return error.BadPluginReply;
        const index = item.object.get("branch") orelse return error.BadPluginReply;
        const vtime = item.object.get("vtime_ns") orelse return error.BadPluginReply;
        if (index != .integer or vtime != .integer) return error.BadPluginReply;
        const reason = if (item.object.get("reason")) |text| switch (text) {
            .string => |string| try arena.dupe(u8, string[0..@min(string.len, reason_size_max)]),
            else => "",
        } else "";
        const horizon: ?u64 = if (item.object.get("horizon_ns")) |value| switch (value) {
            .integer => |integer| std.math.cast(u64, integer) orelse return error.BadPluginReply,
            .null => null,
            else => return error.BadPluginReply,
        } else null;
        const wanted: ?u32 = if (item.object.get("branches")) |value| switch (value) {
            .integer => |integer| if (integer >= 1) std.math.cast(u32, integer) orelse return error.BadPluginReply else return error.BadPluginReply,
            .null => null,
            else => return error.BadPluginReply,
        } else null;
        // The last return gets what is left of the budget.
        const own = @min(wanted orelse branches, budget - taken);
        taken += own;
        try chosen.append(arena, .{
            .branch = std.math.cast(u32, index.integer) orelse return error.BadPluginReply,
            .vtime_ns = std.math.cast(u64, vtime.integer) orelse return error.BadPluginReply,
            .reason = reason,
            .horizon_ns = horizon,
            .branches = if (wanted != null or own != branches) own else null,
        });
    }
    return .{ .returns = chosen.items, .fill = fill };
}

test "a strategy shapes the generation: branches per return within the budget, and the fill" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"returns": [{"branch": 3, "vtime_ns": 10, "reason": "wide", "branches": 10},
        \\  {"branch": 4, "vtime_ns": 20, "reason": "default"},
        \\  {"branch": 5, "vtime_ns": 30, "reason": "what is left", "branches": 9},
        \\  {"branch": 6, "vtime_ns": 40, "reason": "past the budget"}],
        \\ "fill": "fresh"}
    ;
    const reply = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const answer = try answer_parse(arena, reply.object, 4, 16);
    try std.testing.expectEqual(Fill.fresh, answer.fill);
    try std.testing.expectEqual(@as(usize, 3), answer.returns.len);
    try std.testing.expectEqual(@as(?u32, 10), answer.returns[0].branches);
    try std.testing.expectEqual(@as(?u32, null), answer.returns[1].branches); // The default, 4.
    try std.testing.expectEqual(@as(?u32, 2), answer.returns[2].branches); // 16 - 10 - 4.
    // An answer from before: its moments, the explorer's fill.
    const old = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"returns": [{"branch": 1, "vtime_ns": 5, "reason": "r"}]}
    , .{});
    const plain = try answer_parse(arena, old.object, 4, 16);
    try std.testing.expectEqual(Fill.explorer, plain.fill);
    try std.testing.expectEqual(@as(usize, 1), plain.returns.len);
    try std.testing.expectError(error.BadPluginReply, answer_parse(arena, (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"returns": [{"branch": 1, "vtime_ns": 5, "branches": 0}]}
    , .{})).object, 4, 16));
}

/// Offers the plugin a decision. Returns true when it overrode `value` (which on entry holds
/// the default and on return holds the answer).
pub fn random(
    strategy: *Strategy,
    pull: u64,
    moment: Events.Moment,
    source: []const u8,
    /// The decision's label (`{"name": ..., "options": [...]}` or `"range"`), if announced.
    label: ?[]const u8,
    value: []u8,
) !bool {
    assert(value.len > 0);
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"random\",\"pull\":{d},\"size\":{d},\"default\":\"", .{
        pull, value.len,
    });
    for (value) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.print("\",\"source\":{f},\"vtime_ns\":{d},\"branches\":{d}", .{
        std.json.fmt(source, .{}), moment.vtime_ns, moment.branches,
    });
    if (label) |decision| try writer.print(",\"decision\":{s}", .{decision});
    try writer.writeAll("}");
    // The events before it first: the plugin decides knowing them (its reply may end the
    // timeline: `take_end`).
    if (try strategy.flush()) strategy.ended = true;
    const reply = try strategy.call(writer.buffered());
    strategy.reason_size = 0;
    const hex = reply.get("hex") orelse return false;
    if (reply.get("reason")) |reason| if (reason == .string) {
        const size = @min(reason.string.len, reason_size_max);
        @memcpy(strategy.reason[0..size], reason.string[0..size]);
        strategy.reason_size = @intCast(size);
    };
    if (hex != .string) return error.BadPluginReply;
    if (hex.string.len != value.len * 2) return error.BadPluginReply;
    if (value.len > override_size_max) return error.OverrideTooLarge;
    _ = std.fmt.hexToBytes(value, hex.string) catch return error.BadPluginReply;
    return true;
}

/// Returns true when the plugin ends the timeline here (`{"end": true}`): it stops at this
/// moment, its end checks not run, as one stopped at its horizon (and not extended).
pub fn event(
    strategy: *Strategy,
    moment: Events.Moment,
    source: []const u8,
    data: []const u8,
) !bool {
    assert(data.len > 0);
    const object = data[0] == '{' and data[data.len - 1] == '}';
    if (!object) return false; // Only structured events are forwarded.
    if (strategy.wants_batched) return strategy.hold(moment, source, data);
    var writer: std.Io.Writer = .fixed(&strategy.request);
    const format = "{{\"method\":\"event\",\"vtime_ns\":{d},\"branches\":{d},\"source\":{f}," ++
        "\"event\":";
    try writer.print(format, .{ moment.vtime_ns, moment.branches, std.json.fmt(source, .{}) });
    try writer.writeAll(data);
    try writer.writeAll("}");
    return reply_ends(try strategy.call(writer.buffered()));
}

/// An event held for the next batch; returns true when a full batch went first and its reply
/// ended the timeline.
fn hold(strategy: *Strategy, moment: Events.Moment, source: []const u8, data: []const u8) !bool {
    var item_buffer: [line_size_max]u8 = undefined;
    var item: std.Io.Writer = .fixed(&item_buffer);
    item.print("{{\"vtime_ns\":{d},\"branches\":{d},\"source\":{f},\"event\":", .{
        moment.vtime_ns, moment.branches, std.json.fmt(source, .{}),
    }) catch return false; // Too large to tell: dropped, as an unstructured one.
    item.writeAll(data) catch return false;
    item.writeAll("}") catch return false;
    const bytes = item.buffered();
    var ends = false;
    if (batch_prefix.len + strategy.batch_size + 1 + bytes.len + batch_suffix.len > batch_size_max) {
        ends = try strategy.flush();
    }
    assert(batch_prefix.len + strategy.batch_size + 1 + bytes.len + batch_suffix.len <= batch_size_max);
    var at = batch_prefix.len + strategy.batch_size;
    if (strategy.batch_count > 0) {
        strategy.batch[at] = ',';
        at += 1;
    }
    @memcpy(strategy.batch[at..][0..bytes.len], bytes);
    strategy.batch_size = @intCast(at + bytes.len - batch_prefix.len);
    strategy.batch_count += 1;
    return ends;
}

/// Sends the held events, if any, as one `events` request; returns true when its reply ends
/// the timeline. Its plan, if it gives one, replaces the last.
pub fn flush(strategy: *Strategy) !bool {
    if (strategy.batch_count == 0) return false;
    return strategy.send_batch();
}

fn send_batch(strategy: *Strategy) !bool {
    @memcpy(strategy.batch[0..batch_prefix.len], batch_prefix);
    const end = batch_prefix.len + strategy.batch_size;
    @memcpy(strategy.batch[end..][0..batch_suffix.len], batch_suffix);
    strategy.batch_count = 0;
    strategy.batch_size = 0;
    const reply = try strategy.call_long(strategy.batch[0 .. end + batch_suffix.len]);
    if (strategy.wants_plans) if (reply.get("plan")) |plan| strategy.plan_parse(plan);
    return reply_ends(reply);
}

/// A plan's draw for a named decision (`label`, its announcement's JSON) of a u64 pull, at
/// `vtime_ns`: the plan refreshed first when stale (its batch's end, if any, in `take_end`);
/// null when the plan does not weigh it. `default` is the pull's own value: which segment, and
/// where in it, come from it (a replay takes the value from the tape).
pub fn plan_draw(strategy: *Strategy, label: []const u8, vtime_ns: u64, default: u64) !?Draw {
    assert(strategy.wants_plans);
    if (strategy.flushed_ns == 0 or vtime_ns -| strategy.flushed_ns >= plan_refresh_ns or strategy.flushed_ns > vtime_ns) {
        strategy.flushed_ns = vtime_ns;
        if (try strategy.send_batch()) strategy.ended = true;
    }
    const name = label_name(label) orelse return null;
    const planned = for (strategy.plan[0..strategy.plan_count]) |*planned| {
        if (std.mem.eql(u8, planned.name[0..planned.name_size], name)) break planned;
    } else return null;
    return plan_pick(planned, default);
}

fn plan_pick(planned: *const Planned, default: u64) ?Draw {
    var total: f64 = 0;
    for (planned.weight[0..planned.segment_count]) |weight| total += weight;
    if (!(total > 0)) return null;
    // The segment by the default's high bits, the value in it by its low ones.
    const unit = @as(f64, @floatFromInt(default >> 11)) / @as(f64, 1 << 53);
    var sum: f64 = 0;
    const last = planned.segment_count - 1;
    const index = for (0..planned.segment_count) |index| {
        sum += planned.weight[index];
        if (unit * total < sum) break index;
    } else last;
    const low = planned.low[index];
    const span = planned.high[index] - low;
    const mixed = std.hash.Wyhash.hash(0x706c616e, std.mem.asBytes(&default));
    return .{ .value = low + mixed % span, .low = low, .high = planned.high[index], .share = planned.weight[index] / total };
}

/// A decision announcement's name (`{"name":"fault",...}`).
fn label_name(label: []const u8) ?[]const u8 {
    const key = "{\"name\":\"";
    if (!std.mem.startsWith(u8, label, key)) return null;
    const rest = label[key.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// `{"<name>": [[low, high, weight], ...], ...}`: segments with high > low and a weight >= 0;
/// the rest is left out (up to the limits).
fn plan_parse(strategy: *Strategy, plan: std.json.Value) void {
    strategy.plan_count = 0;
    if (plan != .object) return;
    var entries = plan.object.iterator();
    while (entries.next()) |entry| {
        if (strategy.plan_count == plan_labels_max) break;
        const name = entry.key_ptr.*;
        if (name.len == 0 or name.len > plan_name_size_max) continue;
        if (entry.value_ptr.* != .array) continue;
        const planned = &strategy.plan[strategy.plan_count];
        planned.* = .{};
        @memcpy(planned.name[0..name.len], name);
        planned.name_size = @intCast(name.len);
        for (entry.value_ptr.array.items) |segment| {
            if (planned.segment_count == plan_segments_max) break;
            if (segment != .array or segment.array.items.len != 3) continue;
            const items = segment.array.items;
            if (items[0] != .integer or items[1] != .integer) continue;
            if (items[0].integer < 0 or items[1].integer <= items[0].integer) continue;
            const weight: f64 = switch (items[2]) {
                .integer => |value| @floatFromInt(value),
                .float => |value| value,
                else => continue,
            };
            if (!(weight >= 0)) continue;
            planned.low[planned.segment_count] = @intCast(items[0].integer);
            planned.high[planned.segment_count] = @intCast(items[1].integer);
            planned.weight[planned.segment_count] = weight;
            planned.segment_count += 1;
        }
        if (planned.segment_count > 0) strategy.plan_count += 1;
    }
}

/// Tells a planning plugin what its plan drew (held with the next batch).
pub fn planned_tell(strategy: *Strategy, moment: Events.Moment, source: []const u8, label: []const u8, value: u64) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"event\":\"planned\",\"details\":{{\"value\":{d},\"decision\":{s}}}}}", .{ value, label }) catch return;
    if (try strategy.hold(moment, source, writer.buffered())) strategy.ended = true;
}

/// Whether a batch sent before a decision ended the timeline; cleared as read.
pub fn take_end(strategy: *Strategy) bool {
    const ended = strategy.ended;
    strategy.ended = false;
    return ended;
}

fn reply_ends(reply: std.json.ObjectMap) bool {
    const value = reply.get("end") orelse return false;
    return value == .bool and value.bool;
}

test "hello readies a plugin's struct from undefined memory, as TCP's connect leaves it" {
    const allocator = std.testing.allocator;
    const strategy = try allocator.create(Strategy);
    defer allocator.destroy(strategy);
    @memset(std.mem.asBytes(strategy), 0xaa); // connect sets its fields one by one.
    var to: [2]i32 = undefined;
    var from: [2]i32 = undefined;
    try check(linux.pipe(&to));
    try check(linux.pipe(&from));
    defer for ([_]i32{ to[0], to[1], from[0], from[1] }) |fd| {
        _ = linux.close(fd);
    };
    strategy.pid = 0;
    strategy.to_plugin = to[1];
    strategy.from_plugin = from[0];
    strategy.response_start = 0;
    strategy.response_end = 0;
    strategy.loopback = false;
    strategy.ring = null;
    strategy.wasm = null; // start's, before connect: not a module.
    try write_all(from[1], "{\"name\":\"t\",\"wants\":[\"assertions\",\"batched\"]}\n{}\n");
    try strategy.hello(1, null);
    const moment: Events.Moment = .{ .vtime_ns = 5, .branches = 9 };
    try std.testing.expect(!try strategy.event(moment, "n1", "{\"event\":\"fault\"}"));
    try std.testing.expectEqual(@as(u32, 1), strategy.batch_count);
    try std.testing.expect(!try strategy.flush());
    var sent: [4096]u8 = undefined;
    const size = linux.read(to[0], &sent, sent.len);
    try check(size);
    const batch = batch_prefix ++ "{\"vtime_ns\":5,\"branches\":9,\"source\":\"n1\",\"event\":{\"event\":\"fault\"}}" ++ batch_suffix ++ "\n";
    const hello_end = std.mem.indexOfScalar(u8, sent[0..size], '\n').? + 1;
    try std.testing.expectEqualStrings(batch, sent[hello_end..size]);
}

test "a batched plugin is told its events together, before the decision, and may end the timeline" {
    const allocator = std.testing.allocator;
    const strategy = try allocator.create(Strategy);
    defer allocator.destroy(strategy);
    var to: [2]i32 = undefined;
    var from: [2]i32 = undefined;
    try check(linux.pipe(&to));
    try check(linux.pipe(&from));
    defer for ([_]i32{ to[0], to[1], from[0], from[1] }) |fd| {
        _ = linux.close(fd);
    };
    strategy.* = .{
        .pid = 0,
        .to_plugin = to[1],
        .from_plugin = from[0],
        .request = undefined,
        .response = undefined,
        .response_start = 0,
        .response_end = 0,
        .parse_buffer = undefined,
    };
    strategy.decides = true;
    strategy.wants_labeled = true;
    strategy.wants_assertions = true;
    strategy.wants_batched = true;
    // The plugin's replies, in order: to the batch (ending the timeline), then to the decision.
    try write_all(from[1], "{\"end\":true}\n{}\n");
    const moment: Events.Moment = .{ .vtime_ns = 5, .branches = 9 };
    for (0..3) |_| try std.testing.expect(!try strategy.event(moment, "n1", "{\"event\":\"fault\"}"));
    try std.testing.expectEqual(@as(u32, 3), strategy.batch_count);
    var value: [8]u8 = @splat(0);
    try std.testing.expect(!try strategy.random(1, moment, "n1", "{\"name\":\"fault\"}", &value));
    try std.testing.expect(strategy.take_end());
    try std.testing.expect(!strategy.take_end()); // Read once.
    var sent: [4096]u8 = undefined;
    const size = linux.read(to[0], &sent, sent.len);
    try check(size);
    const item = "{\"vtime_ns\":5,\"branches\":9,\"source\":\"n1\",\"event\":{\"event\":\"fault\"}}";
    const batch = batch_prefix ++ item ++ "," ++ item ++ "," ++ item ++ batch_suffix ++ "\n";
    try std.testing.expect(std.mem.startsWith(u8, sent[0..size], batch));
    try std.testing.expect(std.mem.startsWith(u8, sent[batch.len..size], "{\"method\":\"random\""));
    try std.testing.expectEqual(@as(u32, 0), strategy.batch_count);
}

test "a plan's segments are drawn by weight, values inside them, from the pull's own bits" {
    var strategy: Strategy = undefined;
    strategy.wants_plans = true;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"fault": [[0, 1, 1], [2, 3, 3]], "fault.quiet_ms": [[20000, 30000, 1]], "bad": [[5, 5, 1]]}
    , .{});
    defer parsed.deinit();
    strategy.plan_parse(parsed.value);
    try std.testing.expectEqual(@as(u8, 2), strategy.plan_count); // "bad": an empty segment.
    var counts: [3]u32 = @splat(0);
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..4000) |_| {
        const draw = plan_pick(&strategy.plan[0], prng.random().int(u64)).?;
        try std.testing.expect(draw.value == 0 or draw.value == 2);
        counts[@intCast(draw.value)] += 1;
    }
    try std.testing.expect(counts[2] > 2 * counts[0]); // Weights 3 to 1.
    try std.testing.expect(counts[0] > 600);
    const timing = plan_pick(&strategy.plan[1], 12345).?;
    try std.testing.expect(timing.value >= 20000 and timing.value < 30000);
    try std.testing.expectEqualStrings("fault.quiet_ms", label_name("{\"name\":\"fault.quiet_ms\",\"range\":30000}").?);
    try std.testing.expectEqual(@as(?[]const u8, null), label_name("{\"options\":[]}"));
}

test "an event's reply ends the timeline only with end true" {
    const cases = [_]struct { reply: []const u8, ends: bool }{
        .{ .reply = "{}", .ends = false },
        .{ .reply = "{\"end\":true}", .ends = true },
        .{ .reply = "{\"end\":false}", .ends = false },
        .{ .reply = "{\"end\":\"yes\"}", .ends = false },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.reply, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.ends, reply_ends(parsed.value.object));
    }
}

pub const BranchEnd = struct {
    index: u32,
    outcome: []const u8,
    events: u64,
    failing: []const []const u8,
};

/// Returns true when the plugin asks to stop exploring.
pub fn branch_end(strategy: *Strategy, end: BranchEnd) !bool {
    _ = try strategy.flush(); // Its last events first (an end there changes nothing now).
    strategy.ended = false;
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"branch_end\",\"index\":{d},\"outcome\":\"{s}\"," ++
        "\"events\":{d},\"failing\":[", .{ end.index, end.outcome, end.events });
    for (end.failing, 0..) |name, index| {
        if (index > 0) try writer.writeAll(",");
        try std.json.Stringify.value(name, .{}, &writer);
    }
    try writer.writeAll("]}");
    const reply = try strategy.call(writer.buffered());
    const stop_value = reply.get("stop") orelse return false;
    return stop_value == .bool and stop_value.bool;
}

/// A history the timeline's commands recorded for one of the program's host checks
/// (`sdk.record`: JSON lines), given whole to a checker plugin.
pub const History = struct { name: []const u8, records: []const u8 };
/// A check request with its histories at most this large, on every transport: a history past
/// it is given as its size alone (`"records":null,"bytes":N`).
const check_request_size_max = ring_request_size_max;

/// A plugin's verdicts on a timeline: at most this many, each an assertion event line.
pub const check_assertions_max = 64;
pub const check_line_size_max = 4096; // Events.emit's largest event.
const assertion_types = [_][]const u8{ "always", "always_or_unreachable", "sometimes", "reachable", "unreachable" };

/// A timeline that ended, judged by a plugin that wants "check" (its events told first):
/// `{"method":"check","index":I,"histories":[{"name","records"},...]}` (the records the
/// program's host checks get, Elle's or a linearizability checker's input), the reply `{"assertions":[{"type":"always"|"sometimes"|...,
/// "message":"...","condition":bool,"details":{...}},...]}`. Each is written into `lines` as an
/// assertion event (`{"assert":{...}}`, as the SDKs make), in `buffer`; returns how many.
pub fn judge(strategy: *Strategy, index: u32, histories: []const History, buffer: []u8, lines: [][]const u8) !usize {
    assert(lines.len >= check_assertions_max);
    _ = try strategy.flush(); // Its last events first: it judges the whole timeline.
    strategy.ended = false;
    var request: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer request.deinit();
    try request.writer.print("{{\"method\":\"check\",\"index\":{d},\"histories\":[", .{index});
    for (histories, 0..) |history, position| {
        if (position > 0) try request.writer.writeAll(",");
        const mark = request.written().len;
        try request.writer.print("{{\"name\":{f},\"records\":{f}}}", .{ std.json.fmt(history.name, .{}), std.json.fmt(history.records, .{}) });
        // Past a request's room: its size alone (the ring's room, kept on every transport).
        if (request.written().len + 2 > check_request_size_max) {
            request.shrinkRetainingCapacity(mark);
            try request.writer.print("{{\"name\":{f},\"records\":null,\"bytes\":{d}}}", .{ std.json.fmt(history.name, .{}), history.records.len });
        }
    }
    try request.writer.writeAll("]}");
    const reply = try strategy.call_long(request.written());
    const assertions = reply.get("assertions") orelse return 0;
    if (assertions != .array or assertions.array.items.len > check_assertions_max) return error.BadPluginReply;
    var used: usize = 0;
    for (assertions.array.items, 0..) |item, position| {
        if (item != .object) return error.BadPluginReply;
        const kind = item.object.get("type") orelse return error.BadPluginReply;
        const message = item.object.get("message") orelse return error.BadPluginReply;
        if (kind != .string or message != .string or message.string.len == 0) return error.BadPluginReply;
        const known = for (assertion_types) |name| {
            if (std.mem.eql(u8, name, kind.string)) break true;
        } else false;
        if (!known) return error.BadPluginReply;
        const condition = item.object.get("condition") orelse std.json.Value{ .bool = true };
        if (condition != .bool) return error.BadPluginReply;
        const details = item.object.get("details") orelse std.json.Value{ .object = .empty };
        if (details != .object) return error.BadPluginReply;
        const room = buffer[used..@min(buffer.len, used + check_line_size_max)];
        var line: std.Io.Writer = .fixed(room);
        line.print("{{\"assert\":{{\"type\":\"{s}\",\"message\":{f},\"condition\":{},\"details\":{f}}}}}", .{
            kind.string, std.json.fmt(message.string, .{}), condition.bool, std.json.fmt(details, .{}),
        }) catch return error.BadPluginReply;
        lines[position] = line.buffered();
        used += line.buffered().len;
    }
    return assertions.array.items.len;
}

/// One request line and its reply, for other plugins on this transport (causality planners).
/// The reply lives in parse_buffer until the next call.
pub fn call_json(strategy: *Strategy, request: []const u8) !std.json.ObjectMap {
    return strategy.call_long(request);
}

/// Sends one request line and parses the one reply line. The reply lives in parse_buffer until
/// the next call.
fn call(strategy: *Strategy, request: []const u8) !std.json.ObjectMap {
    assert(request.len < line_size_max);
    return strategy.call_long(request);
}

/// `call` for a request of any size (the reply still fits the fixed buffers).
fn call_long(strategy: *Strategy, request: []const u8) !std.json.ObjectMap {
    assert(request.len > 0);
    const line = if (strategy.wasm) |plugin| plugin.call(request, &strategy.response) else if (strategy.ring) |memory| try strategy.ring_call(memory, request) else line: {
        try write_all(strategy.to_plugin, request);
        try write_all(strategy.to_plugin, "\n");
        break :line try strategy.read_line();
    };
    var fba = std.heap.FixedBufferAllocator.init(&strategy.parse_buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch {
        return error.BadPluginReply;
    };
    if (value != .object) return error.BadPluginReply;
    return value.object;
}

/// One call through the shared mapping: the reply copied out of it (it is the next call's room).
fn ring_call(strategy: *Strategy, memory: []u8, request: []const u8) ![]const u8 {
    if (request.len > ring_request_size_max) return error.PluginRequestTooLarge;
    const ring: *Ring = @ptrCast(@alignCast(memory.ptr));
    assert(ring.state.load(.acquire) == ring_idle);
    @memcpy(memory[ring_request_at..][0..request.len], request);
    ring.request_size = @intCast(request.len);
    ring.state.store(ring_request, .release);
    _ = linux.futex_3arg(&ring.state.raw, .{ .cmd = .WAKE, .private = false }, 1);
    var spins: u32 = 0;
    while (ring.state.load(.acquire) != ring_reply) {
        if (spins < ring_spins) {
            spins += 1;
            std.atomic.spinLoopHint();
            continue;
        }
        const timeout: linux.timespec = .{ .sec = 0, .nsec = ring_wait_ns };
        _ = linux.futex_4arg(&ring.state.raw, .{ .cmd = .WAIT, .private = false }, ring_request, &timeout);
        if (ring.state.load(.acquire) != ring_reply and strategy.plugin_gone()) return error.PluginExited;
    }
    const size = ring.reply_size;
    if (size > line_size_max) return error.PluginLineTooLong;
    @memcpy(strategy.response[0..size], memory[ring_reply_at..][0..size]);
    ring.state.store(ring_idle, .release);
    strategy.response_start = 0;
    strategy.response_end = 0;
    return std.mem.trimEnd(u8, strategy.response[0..size], "\n");
}

/// Whether a ring plugin's socket has ended (closed, or an error on it): the plugin is gone.
fn plugin_gone(strategy: *Strategy) bool {
    var polled = [_]linux.pollfd{.{
        .fd = strategy.from_plugin,
        .events = linux.POLL.IN | poll_rdhup,
        .revents = 0,
    }};
    const ready = linux.poll(&polled, polled.len, 0);
    if (linux.errno(ready) != .SUCCESS or ready == 0) return false;
    return polled[0].revents & (linux.POLL.HUP | poll_rdhup | linux.POLL.ERR) != 0;
}

fn read_line(strategy: *Strategy) ![]const u8 {
    for (0..line_size_max) |_| {
        const pending = strategy.response[strategy.response_start..strategy.response_end];
        if (std.mem.indexOfScalar(u8, pending, '\n')) |index| {
            strategy.response_start += @intCast(index + 1);
            return pending[0..index];
        }
        if (strategy.response_start > 0) {
            std.mem.copyForwards(u8, strategy.response[0..pending.len], pending);
            strategy.response_start = 0;
            strategy.response_end = @intCast(pending.len);
        }
        if (strategy.response_end == line_size_max) return error.PluginLineTooLong;
        const free = strategy.response[strategy.response_end..];
        const result = linux.read(strategy.from_plugin, free.ptr, free.len);
        try check(result);
        if (result == 0) return error.PluginExited;
        strategy.response_end += @intCast(result);
    }
    return error.PluginLineTooLong;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    assert(fd >= 0);
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        check(result) catch return error.PluginExited;
        written += result;
    }
    assert(written == bytes.len);
}

fn check(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.SyscallFailed;
}

/// The plugin side of a ring for the test: hello over the socket, the mapping taken, then each
/// request answered in it with its size, until the explorer's socket ends.
fn ring_test_plugin(listener: linux.fd_t) void {
    const connection_or_error = linux.accept(listener, null, null);
    if (linux.errno(connection_or_error) != .SUCCESS) linux.exit_group(10);
    const connection: linux.fd_t = @intCast(connection_or_error);
    var buffer: [4096]u8 = undefined;
    var have: usize = 0;
    // Two lines over the socket: the hello, then the ring's offer.
    var lines: [2][]const u8 = undefined;
    for (&lines) |*line| {
        while (std.mem.indexOfScalar(u8, buffer[0..have], '\n') == null) {
            const got = linux.read(connection, buffer[have..].ptr, buffer.len - have);
            if (linux.errno(got) != .SUCCESS or got == 0) linux.exit_group(11);
            have += got;
        }
        const end = std.mem.indexOfScalar(u8, buffer[0..have], '\n').?;
        line.* = buffer[0..end];
        if (line == &lines[0]) {
            write_all(connection, "{\"name\":\"ring-test\",\"decides\":false,\"ring\":true}\n") catch linux.exit_group(12);
            std.mem.copyForwards(u8, buffer[0 .. have - end - 1], buffer[end + 1 .. have]);
            have -= end + 1;
        }
    }
    var path_buffer: [64]u8 = undefined;
    const key = "\"path\":\"";
    const at = (std.mem.indexOf(u8, lines[1], key) orelse linux.exit_group(13)) + key.len;
    const path_end = std.mem.indexOfScalarPos(u8, lines[1], at, '"') orelse linux.exit_group(14);
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{lines[1][at..path_end]}, 0) catch linux.exit_group(15);
    const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) linux.exit_group(16);
    const mapped = linux.mmap(null, ring_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, @intCast(opened), 0);
    if (linux.errno(mapped) != .SUCCESS) linux.exit_group(17);
    _ = linux.close(@intCast(opened));
    const memory: [*]u8 = @ptrFromInt(mapped);
    const ring: *Ring = @ptrCast(@alignCast(memory));
    if (!std.mem.eql(u8, &ring.magic, ring_magic)) linux.exit_group(18);
    write_all(connection, "{\"ring\":true}\n") catch linux.exit_group(19);
    while (true) {
        const seen = ring.state.load(.acquire);
        if (seen != ring_request) {
            const timeout: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = linux.futex_4arg(&ring.state.raw, .{ .cmd = .WAIT, .private = false }, seen, &timeout);
            var polled = [_]linux.pollfd{.{ .fd = connection, .events = linux.POLL.IN | poll_rdhup, .revents = 0 }};
            if (linux.poll(&polled, 1, 0) == 1 and polled[0].revents & (linux.POLL.HUP | poll_rdhup) != 0) linux.exit_group(0);
            continue;
        }
        var reply_buffer: [64]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buffer, "{{\"size\":{d}}}", .{ring.request_size}) catch linux.exit_group(20);
        @memcpy(memory[ring_reply_at..][0..reply.len], reply);
        ring.reply_size = @intCast(reply.len);
        ring.state.store(ring_reply, .release);
        _ = linux.futex_3arg(&ring.state.raw, .{ .cmd = .WAKE, .private = false }, 1);
    }
}

test "a plugin on this host that asks for a ring takes its calls through the shared mapping" {
    const listener_or_error = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try check(listener_or_error);
    const listener: linux.fd_t = @intCast(listener_or_error);
    defer _ = linux.close(listener);
    var address = linux.sockaddr.in{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    var address_size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try check(linux.bind(listener, @ptrCast(&address), address_size));
    try check(linux.listen(listener, 1));
    try check(linux.getsockname(listener, @ptrCast(&address), &address_size));
    const pid = linux.fork();
    try check(pid);
    if (pid == 0) ring_test_plugin(listener);
    const allocator = std.testing.allocator;
    const strategy = try allocator.create(Strategy);
    defer allocator.destroy(strategy);
    @memset(std.mem.asBytes(strategy), 0xaa); // connect sets its fields one by one.
    var text: [32]u8 = undefined;
    try strategy.connect(try std.fmt.bufPrint(&text, "127.0.0.1:{d}", .{std.mem.bigToNative(u16, address.port)}));
    try strategy.hello(1, null);
    try std.testing.expect(strategy.ring != null);
    try std.testing.expectEqualStrings("ring-test", strategy.hello_name());
    // Each call through the mapping: one of a few bytes, one past a socket's line.
    for ([_]usize{ 13, 300 * 1024 }) |size| {
        const request = try allocator.alloc(u8, size);
        defer allocator.free(request);
        @memset(request, ' ');
        request[0] = '{';
        request[size - 1] = '}';
        const reply = try strategy.call_json(request);
        try std.testing.expectEqual(@as(i64, @intCast(size)), reply.get("size").?.integer);
    }
    strategy.stop(); // The plugin's wait ends with the socket.
    try std.testing.expect(strategy.ring == null);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const exited: u32 = @bitCast(status);
    try std.testing.expect(linux.W.IFEXITED(exited) and linux.W.EXITSTATUS(exited) == 0);
}
