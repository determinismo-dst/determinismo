// SPDX-License-Identifier: MIT
//! determinismo SDK for Zig: assertions, platform randomness, lifecycle, and test commands
//! written as plain handler functions.
//!
//! Inside determinismo everything goes through /dev/determinismo: events are recorded with their
//! moment, and every random value is a decision the platform can steer and replay. Outside it
//! (local runs) randomness comes from the OS and events go to stderr, so the same test binary
//! works everywhere.
//!
//! A test program describes the system (typed nodes, built from profiles) and its scenarios,
//! each a plain function that lists test commands:
//!
//!     const Nodes = struct { redis: sdk.Node };
//!     const System = sdk.System(Nodes);
//!
//!     fn describe(d: *System.Describe) !void {
//!         const profile = try d.profile("default");
//!         profile.node(.redis, .{ .image = "redis:7.4", .ready = .{ .tcp = 6379 } });
//!     }
//!     fn bank(s: *System.Scenario) void {
//!         s.setup("accounts", create_accounts);
//!         s.parallel_driver("transfer", transfer); // fn transfer(ctx: *System.Context) !void
//!         s.finally("conserved", check_total);
//!     }
//!     pub fn main(init: std.process.Init) !void {
//!         return System.main(init, .{ .describe = describe, .scenarios = .{ .bank = bank } });
//!     }
//!
//! Drivers are ordinary functions: share them between scenarios and programs like any code.
//! See schema.zig for the two commands every test program answers.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const schema = @import("schema.zig");
const system = @import("system.zig");
pub const System = system.System;
pub const Node = system.Node;
pub const Output = system.Output;
pub const Check = system.Check;
/// TCP connections with timeouts, for protocol clients (see tcp.zig).
pub const tcp = @import("tcp");
/// Transaction histories checked by Elle (see elle.zig and checkers/elle).
pub const elle = @import("elle.zig");
pub const replicas = @import("replicas.zig");
pub const payloads = @import("payloads.zig");
pub const ring = @import("ring.zig");
/// Open-loop load with retry policies, for metastable failures (open_loop.zig).
pub const open_loop = @import("open_loop.zig");
pub const sideband = @import("sideband.zig");

pub const device_path = "/dev/determinismo";
/// One event or one randomness pull per device call (the guest module's page size limit).
pub const message_size_max = 4096 - 16;

/// The device, opened on first use. Not thread-safe: test commands are processes.
var device: Device = .unopened;

const Device = union(enum) { unopened, local, fd: linux.fd_t };

pub fn random_u64() u64 {
    var bytes: [8]u8 = undefined;
    random_bytes(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// A uniformly random integer in [0, count).
pub fn random_below(count: u64) u64 {
    assert(count > 0);
    const value = random_u64() % count; // Bias is below 2^-32 for counts below 2^32.
    assert(value < count);
    return value;
}

/// A float in [0, 1) from 53 random bits.
pub fn random_float() f64 {
    return @as(f64, @floatFromInt(random_u64() >> 11)) / @as(f64, 1 << 53);
}

/// A named decision among options, for strategies that reason about what they steer (which
/// fault, which account, which node): the platform sees the name and the options' names, then
/// picks the index, a decision like any other (replayed, steerable).
pub fn decide(name: []const u8, options: []const []const u8) usize {
    assert(options.len > 0);
    decision_announce(name, .{ .options = options });
    return @intCast(random_below(options.len));
}

/// `random_below_named` for a configuration of the timeline (a fault regime's mean gap, the
/// composer's starts): announced as such, the explorer's bandit learns which values pay
/// (src/bandit.zig) and draws them more often, never only them. A range of 2 to 16 values; any
/// other, a plain named draw.
pub fn random_config(name: []const u8, count: u64) u64 {
    if (count < 2 or count > 16) return random_below_named(name, count);
    decision_announce(name, .{ .range = count, .config = true });
    return random_below(count);
}

/// `random_below`, named for strategies: "fault.duration_ns", "retry.jitter_ms".
pub fn random_below_named(name: []const u8, count: u64) u64 {
    decision_announce(name, .{ .range = count });
    return random_below(count);
}

/// A value up to `max` drawn around a limit the workload declares (a batch size, a buffer, a
/// threshold: Antithesis's menus near limits; docs/PLAN.md's E): half the time uniform, else one
/// of the limit's edges, where bugs gather and uniform draws seldom land: 0, 1, limit - 1, limit,
/// limit + 1 or twice it (each kept within `max`). Named decisions (`<name>.near`, then `name`'s
/// edges by label): strategies steer them, replays repeat them.
pub fn random_near(name: []const u8, limit: u64, max: u64) u64 {
    assert(max > 0);
    assert(max < std.math.maxInt(u64));
    var near_buffer: [128]u8 = undefined;
    const near = std.fmt.bufPrint(&near_buffer, "{s}.near", .{name}) catch "near";
    if (random_below_named(near, 2) == 0) return random_below_named(name, max + 1);
    const edges = [_][]const u8{ "zero", "one", "limit-1", "limit", "limit+1", "twice" };
    const value: u64 = switch (decide(name, &edges)) {
        0 => 0,
        1 => 1,
        2 => limit -| 1,
        3 => limit,
        4 => limit +| 1,
        else => limit *| 2,
    };
    return @min(value, max);
}

test random_near {
    var seen: [6]bool = @splat(false);
    for (0..2000) |_| {
        const value = random_near("test.batch", 64, 1000);
        try std.testing.expect(value <= 1000);
        for ([_]u64{ 0, 1, 63, 64, 65, 128 }, 0..) |edge, index| {
            if (value == edge) seen[index] = true;
        }
    }
    for (seen) |hit| try std.testing.expect(hit); // Every edge drawn.
    // Kept within max: a limit at max has no limit + 1 or twice beyond it.
    for (0..200) |_| try std.testing.expect(random_near("test.full", 10, 10) <= 10);
}

/// Clones this machine where it stands, Unix's fork for timelines: `count` futures from this
/// moment, each its own randomness, on other cores, while this one goes on. Returns 0 here and
/// k (1 to count) in future k. In a session (serve's: a REPL inside the guest) the platform clones
/// the machine at the request; elsewhere nothing is cloned and it returns 0. The answer is a
/// platform decision, on the tape: a replay repeats it.
pub fn fork(count: u32) u64 {
    assert(count > 0);
    var buffer: [64]u8 = undefined;
    emit_raw(std.fmt.bufPrint(&buffer, "{{\"fork\":{{\"count\":{d}}}}}", .{count}) catch unreachable);
    return random_below_named(fork_decision, @as(u64, count) + 1);
}

/// The decision a fork's index is (vm.zig answers it: 0, or k in future k).
pub const fork_decision = "det.fork_index";

/// Asks the fast VM to explore from here (docs/DEVELOPING.md): the machine, its other CPUs
/// offline (the caller's), saved as a snapshot that machines start from. Where this one goes
/// on: the fast VM itself (or a fast VM restored from it), a timeline that runs the scenario,
/// or one held (its scenario not started: a CI shard's, a sandbox's replay, which run their
/// own commands). The platform answers (vm.zig): a fact, not a draw, on the tape.
pub const ExploreHere = enum(u64) { fast = 0, timeline = 1, held = 2 };

pub fn explore_here() ExploreHere {
    emit_raw("{\"explore_here\":{}}");
    return @fromBackingInt(@intCast(random_below_named(explore_here_decision, 3)));
}

pub const explore_here_decision = "det.explore_here";

/// Where a dev mode's composer waits to start its timeline (sdk.explore_here's timelines write
/// to it): a FIFO.
pub const dev_go_path = "/run/det/dev-go";

/// A timeline's kernel command line where it differs from the kernel's own: one started from a
/// fast VM's snapshot (explore from here) keeps the fast VM's /proc/cmdline, and its det.*
/// settings (explore's --drive-max, --timeline, swarm, fault weights) come from the platform
/// instead, written here by the guest's agent before the scenario starts.
pub const timeline_cmdline_path = "/run/det/cmdline";

/// The command line the guest's tools read their det.* settings from: the timeline's when the
/// platform gave one, else the kernel's.
pub fn cmdline_path() [*:0]const u8 {
    if (linux.errno(linux.faccessat(linux.AT.FDCWD, timeline_cmdline_path, linux.F_OK, 0)) == .SUCCESS) return timeline_cmdline_path;
    return "/proc/cmdline";
}

/// serve's API (its HTTP routes: POST /runs, GET /runs/<id>, ...) from inside a session's
/// machine: a program or its REPL in the guest starts runs and follows them as they go. The
/// request is an event the session's explore acts on, calling serve (`--serve-url`); the reply
/// comes back as decisions the platform answers, on the tape, so a replay repeats it without
/// serve. `body` is JSON, "" for none. The reply's status, its bytes appended to `reply` (at
/// most serve_reply_max); error.Unavailable outside a session.
pub fn serve(allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, reply: *std.ArrayList(u8)) !u16 {
    assert(method.len > 0 and path.len > 0 and path[0] == '/');
    if (device_get() != .fd) return error.Unavailable;
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"serve\":{\"method\":") catch return error.RequestTooLarge;
    json_write(&writer, method);
    writer.writeAll(",\"path\":") catch return error.RequestTooLarge;
    json_write(&writer, path);
    writer.writeAll(",\"body\":") catch return error.RequestTooLarge;
    writer.writeAll(if (body.len == 0) "null" else body) catch return error.RequestTooLarge;
    writer.writeAll("}}") catch return error.RequestTooLarge;
    emit_raw(writer.buffered());
    var header: [8]u8 = undefined;
    decision_announce(serve_status_decision, .{ .size = header.len });
    random_bytes(&header);
    const status = std.mem.readInt(u32, header[0..4], .little);
    const size = std.mem.readInt(u32, header[4..8], .little);
    if (status == 0) return error.Unavailable;
    if (status > std.math.maxInt(u16) or size > serve_reply_max) return error.BadReply;
    var at: u32 = 0;
    while (at < size) {
        var chunk: [serve_chunk_size]u8 = undefined;
        const count = @min(serve_chunk_size, size - at);
        decision_announce(serve_reply_decision, .{ .size = count });
        random_bytes(chunk[0..count]);
        try reply.appendSlice(allocator, chunk[0..count]);
        at += count;
    }
    return @intCast(status);
}

/// A connection out of a deterministic machine (docs/PRODUCTS.md: egress; guest/runtime/egress.zig
/// in a deterministic machine): `op` "open" (`target` "host:port"), "send" (`data`), "recv"
/// (up to egress_recv_max bytes into `reply`), "close", on connection `id`. The request is an
/// event the VM acts on (its allowlist, explore's --egress); the answer comes back as decisions,
/// on the tape: a replay answers from it and never connects. Its status: EgressStatus.
pub fn egress(allocator: std.mem.Allocator, op: []const u8, id: u32, target: []const u8, data: []const u8, reply: *std.ArrayList(u8)) !EgressStatus {
    return connection_ask("egress", egress_status_decision, egress_reply_decision, allocator, op, id, target, data, reply);
}

/// A connection into a deterministic machine from outside (docs/PLAN.md: deterministic ingress;
/// guest/runtime/ingress.zig, det-ingress, beside the node whose port it serves, in its
/// network): egress's inverse.
/// `op` "accept" (a connection the host's listener took: its id, 4 bytes little endian, in
/// `reply`; none, `reply` empty), "recv" (up to egress_recv_max of the outside's bytes for
/// connection `id`), "send" (`data`, the node's bytes, to the outside), "close". The answers
/// are decisions on the tape: the live timeline's host listens (explore's --ingress), a replay
/// answers from the tape, no listener and nobody outside needed.
pub fn ingress(allocator: std.mem.Allocator, op: []const u8, id: u32, data: []const u8, reply: *std.ArrayList(u8)) !EgressStatus {
    return connection_ask("ingress", ingress_status_decision, ingress_reply_decision, allocator, op, id, "", data, reply);
}

/// A connection's request (an event the VM acts on), its answer as decisions: status and size,
/// then the bytes.
fn connection_ask(
    comptime key: []const u8,
    status_decision: []const u8,
    reply_decision: []const u8,
    allocator: std.mem.Allocator,
    op: []const u8,
    id: u32,
    target: []const u8,
    data: []const u8,
    reply: *std.ArrayList(u8),
) !EgressStatus {
    assert(op.len > 0 and data.len <= egress_send_max);
    if (device_get() != .fd) return error.Unavailable;
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"" ++ key ++ "\":{{\"op\":", .{}) catch return error.RequestTooLarge;
    json_write(&writer, op);
    writer.print(",\"id\":{d},\"target\":", .{id}) catch return error.RequestTooLarge;
    json_write(&writer, target);
    writer.writeAll(",\"data\":\"") catch return error.RequestTooLarge;
    var encoded: [std.base64.standard.Encoder.calcSize(egress_send_max)]u8 = undefined;
    writer.writeAll(std.base64.standard.Encoder.encode(&encoded, data)) catch return error.RequestTooLarge;
    writer.writeAll("\"}}") catch return error.RequestTooLarge;
    emit_raw(writer.buffered());
    var header: [8]u8 = undefined;
    decision_announce(status_decision, .{ .size = header.len });
    random_bytes(&header);
    const status = std.mem.readInt(u32, header[0..4], .little);
    const size = std.mem.readInt(u32, header[4..8], .little);
    if (status > @backingInt(EgressStatus.reset) or size > egress_recv_max) return error.BadReply;
    var at: u32 = 0;
    while (at < size) {
        var chunk: [serve_chunk_size]u8 = undefined;
        const count = @min(serve_chunk_size, size - at);
        decision_announce(reply_decision, .{ .size = count });
        random_bytes(chunk[0..count]);
        try reply.appendSlice(allocator, chunk[0..count]);
        at += count;
    }
    return @fromBackingInt(@intCast(status));
}

/// The guest-host protocol's shared part (protocol.zig: the core's only import of the SDK).
pub const protocol = @import("protocol");
pub const EgressStatus = protocol.EgressStatus;

pub const egress_status_decision = "det.egress_status";
pub const egress_reply_decision = "det.egress_reply";
pub const ingress_status_decision = "det.ingress_status";
pub const ingress_reply_decision = "det.ingress_reply";
/// A send's most (base64 in the request event, under message_size_max); a recv's is the
/// protocol's.
pub const egress_send_max = 2048;
pub const egress_recv_max = protocol.egress_recv_max;
/// How the machine's egress goes: 0 through the host's relay (a fast VM: events and a FIFO,
/// serve's allowlist), 1 through egress decisions (a deterministic machine).
pub const egress_channel_decision = "det.egress_channel";

pub const EgressChannel = enum(u64) { relay = 0, decisions = 1 };

/// This machine's egress channel (EgressChannel): a fact the VM answers, on the tape.
pub fn egress_channel() EgressChannel {
    return @fromBackingInt(@intCast(random_below_named(egress_channel_decision, 2)));
}

/// serve's reply to the guest: its status and size (8 bytes), then its bytes, 64 at a time (a
/// tape override's most: strategy.override_size_max), each a decision the VM answers.
pub const serve_status_decision = "det.serve_status";
pub const serve_reply_decision = "det.serve_reply";
pub const serve_chunk_size = 64;
pub const serve_reply_max = 16 << 10;

/// A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
/// of two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's
/// first evaluation; while active, it is true one evaluation in four, drawn from its own
/// generator seeded by the platform for the stretch. Outside determinismo, always false. `name`
/// lives as long as the program (a literal); up to 64 points. Where it is true, take a rare path
/// the real system can take too (a pause, a retry), never one it cannot.
pub fn buggify(name: []const u8) bool {
    const value = buggify_draw(name) orelse return false;
    return value % 4 == 0;
}

/// At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
/// (rarer than buggify: pause points sit on hot paths).
pub fn buggify_pause(name: []const u8) void {
    const value = buggify_draw(name) orelse return;
    if (value % 32 != 0) return;
    const ms = (value >> 8) % 10;
    if (ms > 0) sleep_ms(ms);
}

/// The next draw of `name`'s generator, while the point is active.
fn buggify_draw(name: []const u8) ?u64 {
    if (device_get() != .fd) return null;
    var now_spec: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now_spec); // Virtual time inside determinismo.
    const now_ns: u64 = @intCast(now_spec.sec * std.time.ns_per_s + now_spec.nsec);
    const point = for (buggify_points[0..buggify_point_count]) |*known| {
        if (std.mem.eql(u8, known.name, name)) break known;
    } else blk: {
        if (buggify_point_count == buggify_points.len) return null;
        const added = &buggify_points[buggify_point_count];
        buggify_point_count += 1;
        added.* = .{ .name = name, .until_ns = 0, .state = 0 };
        break :blk added;
    };
    if (now_ns >= point.until_ns) {
        var label_buffer: [message_size_max]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "buggify {s}", .{name}) catch name;
        point.state = if (random_below_named(label, 4) == 0) random_u64() | 1 else 0;
        point.until_ns = now_ns + 2 * std.time.ns_per_s;
    }
    if (point.state == 0) return null;
    point.state ^= point.state >> 12; // xorshift64*
    point.state ^= point.state << 25;
    point.state ^= point.state >> 27;
    return point.state *% 0x2545F4914F6CDD1D;
}

/// Buggify points' state for the current stretch: the generator, 0 when inactive.
const BuggifyPoint = struct { name: []const u8, until_ns: u64, state: u64 };
var buggify_points: [64]BuggifyPoint = undefined;
var buggify_point_count: u32 = 0;

/// A moment the program marks as worth a crash (CrashTuner's points, by hand: the node just
/// updated its view of the cluster, a record is half written): inside determinismo and in a
/// node, a point is armed one two-second stretch in eight (a named decision, "crash point
/// <name>"), and its first evaluation in an armed stretch asks the fault injector to crash this
/// node now, the thread waiting for it up to half a second. The injector grants it as one of the
/// node's crash faults the swarm keeps (a kill or a power loss, `why: crash_point`), outside quiet
/// periods; refused (the injector's published state says so) the thread goes on at once. The
/// JVM's coverage agent makes state transitions such points by itself. Nothing elsewhere.
pub fn crash_point(name: []const u8) void {
    const now_ns = crash_point_due(name) orelse return;
    crash_point_ask(name, now_ns);
}

/// Whether `name`'s point fires now (its moment, CLOCK_MONOTONIC), its decisions drawn: the part
/// of crash_point to run under a caller's lock (libdeterminismo's), crash_point_ask outside it.
pub fn crash_point_due(name: []const u8) ?u64 {
    if (device_get() != .fd) return null;
    const now_ns = crash_point_now_ns();
    const point = for (crash_points[0..crash_point_count]) |*known| {
        if (std.mem.eql(u8, known.name, name)) break known;
    } else blk: {
        if (crash_point_count == crash_points.len) return null;
        const added = &crash_points[crash_point_count];
        crash_point_count += 1;
        added.* = .{ .name = name, .until_ns = 0, .armed = false };
        break :blk added;
    };
    if (now_ns >= point.until_ns) {
        var label_buffer: [message_size_max]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "crash point {s}", .{name}) catch name;
        point.armed = random_below_named(label, 8) == 0;
        point.until_ns = now_ns + 2 * std.time.ns_per_s;
    }
    if (!point.armed) return null;
    point.armed = false; // Once a stretch.
    return now_ns;
}

/// Asks the injector to crash this node at `name`'s point and waits for it (crash_point_due's
/// moment): nothing if the injector would refuse, or outside a node.
pub fn crash_point_ask(name: []const u8, now_ns: u64) void {
    var node_buffer: [64]u8 = undefined;
    const node = node_name(&node_buffer) orelse return; // The runner's processes crash nothing.
    if (!crash_point_open(node, now_ns)) return;
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer, "{d} {s}\npoint {s}", .{ now_ns, node, name }) catch return;
    var message: [8 + 512]u8 = undefined;
    std.mem.writeInt(u64, message[0..8], crash_point_flag | body.len, .little);
    @memcpy(message[8..][0..body.len], body);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(faults_control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    const written = linux.write(@intCast(fd), &message, 8 + body.len); // Atomic: under PIPE_BUF.
    _ = linux.close(@intCast(fd));
    if (linux.errno(written) != .SUCCESS) return;
    while (crash_point_now_ns() - now_ns < crash_point_wait_ns) sleep_ms(5);
}

const CrashPoint = struct { name: []const u8, until_ns: u64, armed: bool };
var crash_points: [64]CrashPoint = undefined;
var crash_point_count: u32 = 0;
/// guest/runtime/faults.zig's: its control FIFO, the flag of a crash point's request, the state
/// it publishes, and how old a request it still grants.
const faults_control_path = "/opt/determinismo/faults-control";
const crash_point_flag: u64 = 1 << 59;
const crash_points_state_path = "/opt/determinismo/crash-points";
const crash_point_wait_ns = 500 * std.time.ns_per_ms;

fn crash_point_now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now); // Virtual time inside determinismo.
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// This process's node ($DETERMINISMO_NODE, from /proc/self/environ: no libc here).
fn node_name(buffer: *[64]u8) ?[]const u8 {
    const fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var environ: [16 * 1024]u8 = undefined;
    const size = linux.read(@intCast(fd), &environ, environ.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const key = "DETERMINISMO_NODE=";
    var entries = std.mem.splitScalar(u8, environ[0..size], 0);
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, key)) continue;
        const value = entry[key.len..];
        if (value.len == 0 or value.len > buffer.len) return null;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    return null;
}

/// Whether the injector may grant `node` a crash point now (its published state: the end of a
/// quiet period, the nodes whose crash faults the swarm keeps).
fn crash_point_open(node: []const u8, now_ns: u64) bool {
    const fd = linux.open(crash_points_state_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    var lines = std.mem.tokenizeScalar(u8, buffer[0..size], '\n');
    const quiet_until = std.fmt.parseInt(u64, lines.next() orelse return false, 10) catch return false;
    if (now_ns < quiet_until) return false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, node)) return true;
    }
    return false;
}

fn decision_announce(name: []const u8, what: anytype) void {
    if (device_get() != .fd) return; // Only the platform's strategies read labels.
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"decision\":{\"name\":") catch unreachable;
    json_write(&writer, name);
    inline for (@typeInfo(@TypeOf(what)).@"struct".field_names) |field| {
        writer.writeAll(",\"" ++ field ++ "\":") catch return;
        json_write(&writer, @field(what, field));
    }
    writer.writeAll("}}") catch return;
    emit_raw(writer.buffered());
}

pub fn random_choice(comptime T: type, items: []const T) T {
    assert(items.len > 0);
    return items[@intCast(random_below(items.len))];
}

// Swarm testing over a workload's operations ----------------------------------------------------
// Groce et al., "Swarm Testing" (ISSTA 2012), and Will Wilson's talk of that name (2026): drawn
// uniformly, inserts and removes keep a cache's size a random walk near zero, and its eviction
// never runs; a timeline that leaves removes out, or makes them rare, fills it at once. A
// swarm choice is one of a name's options, drawn among those this timeline keeps, weighted, and
// repeated in runs (Mario's jump held), the table changing with stretches of virtual time.

/// The composer's swarm seed for this timeline ("swarm.seed", drawn as its drivers start;
/// guest/runtime/composer.zig), visible in every node. Absent outside determinismo, before the
/// drivers, and with --no-swarm: swarm choices are then plain uniform ones.
pub const swarm_seed_path = "/opt/determinismo/swarm-seed";
/// A file per stretch table said (`swarm` events): the first process to create it says the
/// table, the timeline's others do not (det-composer makes the directory with the seed).
pub const swarm_said_directory = "/opt/determinismo/swarm-said";

/// An option of the enum `T` by swarm testing (`swarm_index`): `sdk.swarm_choice(Op, "cache.op")`
/// where `sdk.random_choice` drew one uniformly.
pub fn swarm_choice(comptime T: type, name: []const u8) T {
    const options = comptime std.enums.values(T);
    return options[@intCast(swarm_index(name, options.len))];
}

/// The most options a swarm choice has: kinds of operations, not keys.
pub const swarm_options_max = 64;

/// An index below `count` by swarm testing. Every process of the timeline derives the same table
/// for `name` from the composer's seed: a stretch of 10 s to 2 min of virtual time; in each, a
/// keep probability (one to seven eighths), the options kept (one at least), a weight for each
/// (1 to 128, log-uniform) and a mean run (1, 4, 16 or 64: the answer repeated, each next call
/// going on with probability 1 - 1/mean). The answers are named decisions ("swarm.<name>",
/// "swarm.<name> run"), for strategies to steer and tapes to replay.
pub fn swarm_index(name: []const u8, count: u64) u64 {
    assert(count > 0);
    assert(count <= swarm_options_max);
    var label_buffer: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "swarm.{s}", .{name}) catch "swarm";
    const seed = swarm_seed() orelse return random_below_named(label, count);
    const table = swarm_table(seed, name, count, swarm_now_ms());
    swarm_lock_take();
    defer swarm_lock.unlock();
    const run = swarm_run(swarm_hash(seed, name, 0, 0));
    // A run's answer only within this call's options: a name asked with fewer options elsewhere
    // would otherwise get back an index past them.
    if (run.used and run.stretch == table.stretch and table.mean > 1 and run.answer < count) {
        var run_buffer: [112]u8 = undefined;
        const run_label = std.fmt.bufPrint(&run_buffer, "{s} run", .{label}) catch "swarm run";
        if (random_below_named(run_label, table.mean) != 0) return run.answer;
    }
    var pick = random_below_named(label, table.total);
    var answer: u64 = 0;
    for (table.weights[0..count], 0..) |weight, index| {
        if (pick < weight) {
            answer = index;
            break;
        }
        pick -= weight;
    }
    if ((!run.used or run.stretch != table.stretch) and swarm_said_first(seed, name, table.stretch)) {
        event("swarm", .{ .name = name, .stretch = table.stretch, .kept = table.kept, .mean = table.mean });
    }
    run.* = .{ .key = run.key, .used = true, .stretch = table.stretch, .answer = answer };
    return answer;
}

const SwarmTable = struct {
    stretch: u64,
    weights: [swarm_options_max]u64,
    total: u64,
    /// The options kept, a bit each.
    kept: u64,
    mean: u64,
};

/// Whether this process is the timeline's first to use the stretch table (a marker file made
/// with O_EXCL): each driver process said every table it used again (1,604 `swarm` events beside
/// 780 driver starts in a NATS timeline, trial run 1538). Where no marker can be made (a node's
/// process: the directory is read-only there) it says it.
fn swarm_said_first(seed: u64, name: []const u8, stretch: u64) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/{x:0>16}", .{
        swarm_said_directory, swarm_hash(seed, name, stretch, 5),
    }, 0) catch return true;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
    return switch (linux.errno(fd)) {
        .SUCCESS => {
            _ = linux.close(@intCast(fd));
            return true;
        },
        .EXIST => false,
        else => true,
    };
}

fn swarm_table(seed: u64, name: []const u8, count: u64, now_ms: u64) SwarmTable {
    const stretch_ms = 10_000 + swarm_hash(seed, name, 0, 1) % 110_001;
    const stretch = now_ms / stretch_ms;
    const eighths = 1 + swarm_hash(seed, name, stretch, 2) % 7;
    const means = [_]u64{ 1, 4, 16, 64 };
    var table: SwarmTable = .{
        .stretch = stretch,
        .weights = @splat(0),
        .total = 0,
        .kept = 0,
        .mean = means[swarm_hash(seed, name, stretch, 3) % means.len],
    };
    for (0..count) |index| {
        const drawn = swarm_hash(seed, name, stretch, 16 + index);
        if (drawn % 8 >= eighths) continue;
        table.weights[index] = @as(u64, 1) << @intCast((drawn >> 32) % 8);
        table.kept |= @as(u64, 1) << @intCast(index);
    }
    if (table.kept == 0) {
        const index = swarm_hash(seed, name, stretch, 4) % count;
        table.weights[index] = 1;
        table.kept = @as(u64, 1) << @intCast(index);
    }
    for (table.weights[0..count]) |weight| table.total += weight;
    assert(table.total > 0);
    return table;
}

test "swarm_index: a name asked with fewer options never answers past them" {
    // A run's answer from a call with 8 options came back to one with 2 (an HTTP driver's kinds
    // differ by driver): the answer past its options indexed out of bounds.
    swarm_seed_cache = 42;
    defer swarm_seed_cache = null;
    defer swarm_runs = @splat(.{});
    const names = [_][]const u8{ "test.a", "test.b", "test.c", "test.d", "test.e", "test.f" };
    for (0..300) |_| {
        for (names) |name| {
            _ = swarm_index(name, 8);
            try std.testing.expect(swarm_index(name, 2) < 2);
        }
    }
}

test swarm_table {
    // The same for every process; some option kept; a weight only where kept.
    const a = swarm_table(42, "cache.op", 3, 5_000);
    const b = swarm_table(42, "cache.op", 3, 5_000);
    try std.testing.expectEqual(a.kept, b.kept);
    try std.testing.expect(a.kept != 0);
    for (0..3) |index| {
        const kept = a.kept & (@as(u64, 1) << @intCast(index)) != 0;
        try std.testing.expectEqual(kept, a.weights[index] > 0);
    }
    // Over many seeds, every subset of three options comes up (removes left out among them).
    var subsets: u8 = 0;
    for (0..512) |seed| subsets |= @as(u8, 1) << @intCast(swarm_table(seed, "cache.op", 3, 0).kept);
    try std.testing.expectEqual(@as(u8, 0b11111110), subsets);
}

/// The table's draws: FNV-1a (64 bits) of the name, mixed with the seed, the stretch and what
/// is drawn by SplitMix64's finalizer, a few lines in any language: every SDK derives the same
/// table from the same seed.
pub fn swarm_hash(seed: u64, name: []const u8, stretch: u64, what: u64) u64 {
    var name_hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| name_hash = (name_hash ^ byte) *% 0x100000001b3;
    return splitmix(splitmix(splitmix(seed ^ name_hash) ^ stretch) ^ what);
}

fn splitmix(value: u64) u64 {
    var z = value +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test swarm_hash {
    // Fixed values, for the other SDKs' implementations to match (computed apart, in Python).
    try std.testing.expectEqual(@as(u64, 0xbf59ece8b9488041), swarm_hash(1, "cache.operation", 0, 2));
    try std.testing.expectEqual(@as(u64, 0xf5452f6a537dff80), swarm_hash(42, "a", 7, 16));
    try std.testing.expect(swarm_hash(1, "a", 0, 0) != swarm_hash(1, "b", 0, 0));
    try std.testing.expect(swarm_hash(1, "a", 0, 0) != swarm_hash(2, "a", 0, 0));
}

/// Each name's last answer in this process, for its runs.
const SwarmRun = struct { key: u64 = 0, used: bool = false, stretch: u64 = 0, answer: u64 = 0 };
const swarm_names_max = 32;
var swarm_runs: [swarm_names_max]SwarmRun = @splat(.{});
var swarm_lock: std.atomic.Mutex = .unlocked;

/// The swarm's lock, for a program's threads: a failed try yields (the guest has one vCPU).
fn swarm_lock_take() void {
    while (!swarm_lock.tryLock()) {
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
}

/// The run of the name with this key; full, the first slot taken over (its run ends early).
fn swarm_run(key: u64) *SwarmRun {
    for (&swarm_runs) |*run| if (run.used and run.key == key) return run;
    for (&swarm_runs) |*run| if (!run.used) {
        run.key = key;
        return run;
    };
    swarm_runs[0] = .{ .key = key };
    return &swarm_runs[0];
}

var swarm_seed_cache: ?u64 = null;

/// The seed, read once it exists (the drivers' first choices; a node's own process may ask
/// before the drivers start: read again until then).
fn swarm_seed() ?u64 {
    if (swarm_seed_cache) |seed| return seed;
    const fd = linux.open(swarm_seed_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const seed = std.fmt.parseInt(u64, std.mem.trim(u8, buffer[0..size], " \n"), 10) catch return null;
    swarm_seed_cache = seed;
    return seed;
}

/// Milliseconds of the guest's monotonic clock (virtual time since boot): the same in every
/// process, so stretches end together.
fn swarm_now_ms() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ms_per_s + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

pub fn random_bytes(target: []u8) void {
    assert(target.len > 0);
    assert(target.len <= message_size_max);
    switch (device_get()) {
        .fd => |fd| {
            const result = linux.read(fd, target.ptr, target.len);
            assert(linux.errno(result) == .SUCCESS); // The module never fails a sized read.
            assert(result == target.len);
        },
        .local => {
            const result = linux.getrandom(target.ptr, target.len, 0);
            assert(linux.errno(result) == .SUCCESS);
            assert(result == target.len); // Reads of at most 256 bytes are never short.
        },
        .unopened => unreachable,
    }
}

/// A `std.Random` whose every draw is a platform decision, for code that takes an RNG: what it
/// draws is steerable by strategies and replays from tapes. Each draw is one request to the
/// platform; for hot loops, `prng`.
pub fn rng() std.Random {
    return .{ .ptr = &rng_context, .fillFn = rng_fill };
}

var rng_context: u8 = 0;

fn rng_fill(_: *anyopaque, target: []u8) void {
    var rest = target;
    while (rest.len > 0) {
        const size = @min(rest.len, message_size_max);
        random_bytes(rest[0..size]);
        rest = rest[size..];
    }
}

/// A fast generator seeded from one platform decision: deterministic and different in every
/// branch, steered only through its seed. For drawing many values cheaply.
pub fn prng() std.Random.DefaultPrng {
    return .init(random_u64());
}

// Assertions ------------------------------------------------------------------------------
// Messages are literals (comptime): each call site is in the program's assertion catalog, which
// it announces as it starts, before any assertion runs (Antithesis's catalog). An assertion no
// timeline reaches is then judged too: a `sometimes` or `reachable` never hit fails, as does an
// `always` that never ran. `assert_computed` takes a message computed at run time, outside the
// catalog.

/// Which evaluations become events: every one (the default: queries see each), or, as
/// Antithesis's SDKs do, an assertion's first pass and first failure in each process (for hot
/// paths: the verdict is the same, the event stream far smaller). Set it once, at the start.
pub var assertion_events: enum { every, first } = .every;

pub noinline fn always(condition: bool, comptime message: []const u8, details: anytype) void {
    assert_at("always", condition, message, details, @returnAddress());
}

pub noinline fn always_or_unreachable(
    condition: bool,
    comptime message: []const u8,
    details: anytype,
) void {
    assert_at("always_or_unreachable", condition, message, details, @returnAddress());
}

pub noinline fn sometimes(condition: bool, comptime message: []const u8, details: anytype) void {
    assert_at("sometimes", condition, message, details, @returnAddress());
}

pub noinline fn reachable(comptime message: []const u8, details: anytype) void {
    assert_at("reachable", true, message, details, @returnAddress());
}

pub noinline fn assert_unreachable(comptime message: []const u8, details: anytype) void {
    assert_at("unreachable", true, message, details, @returnAddress());
}

/// (The public assertions are `noinline`: inlined, their `@returnAddress()` would be the return
/// address of the function they were inlined into, one frame too far.)
/// `caller`: the return address into the code that asserted; its source place goes with the
/// assertion's first event (as the other SDKs send theirs), from the program's debug info.
fn assert_at(
    comptime kind: [:0]const u8,
    condition: bool,
    comptime message: []const u8,
    details: anytype,
    caller: usize,
) void {
    const site = catalog_site(kind, message);
    if (site.repeated(condition)) return;
    const locate = !site.located;
    site.located = true;
    const assertion = Assertion{ .condition = condition, .message = message };
    emit_assertion(kind, assertion, details, if (locate) caller else null, null);
}

// Guidance assertions -----------------------------------------------------------------------
// As Antithesis's: a comparison's values go in the details (`left`, `right`), and a guidance
// event tells strategies how far the timeline is from the interesting outcome (an `always`
// violated, a `sometimes` true): `distance`, lower is closer, 0 or less is there. Strategies keep
// timelines that come closer (det-strategy-mutate does).

pub noinline fn always_greater_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .greater, left, right, message, details, @returnAddress());
}
pub noinline fn always_greater_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .greater_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn always_less_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .less, left, right, message, details, @returnAddress());
}
pub noinline fn always_less_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .less_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_greater_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .greater, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_greater_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .greater_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_less_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .less, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_less_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .less_or_equal, left, right, message, details, @returnAddress());
}

/// At least one of the named conditions holds, every time (all are evaluated: no short
/// circuit). `conditions` is a struct of bools: `.{ .leader = a, .follower = b }`.
pub noinline fn always_some(
    conditions: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    const held = conditions_held(conditions);
    const merged = .{ .conditions = conditions, .details = details };
    assert_at("always", held > 0, message, merged, @returnAddress());
    // Violated when none holds.
    catalog_site("always", message).guide(message, @floatFromInt(held));
}

/// All the named conditions hold together, at least once.
pub noinline fn sometimes_all(
    conditions: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    const total = @typeInfo(@TypeOf(conditions)).@"struct".field_names.len;
    const held = conditions_held(conditions);
    const merged = .{ .conditions = conditions, .details = details };
    assert_at("sometimes", held == total, message, merged, @returnAddress());
    // Conditions still missing.
    catalog_site("sometimes", message).guide(message, @floatFromInt(total - held));
}

const Relation = enum { greater, greater_or_equal, less, less_or_equal };

fn compare(
    comptime kind: enum { always, sometimes },
    comptime relation: Relation,
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
    caller: usize,
) void {
    const a = number(left);
    const b = number(right);
    const holds = switch (relation) {
        .greater => a > b,
        .greater_or_equal => a >= b,
        .less => a < b,
        .less_or_equal => a <= b,
    };
    // How much the relation holds by (negative: it does not).
    const margin = switch (relation) {
        .greater, .greater_or_equal => a - b,
        .less, .less_or_equal => b - a,
    };
    const merged = .{ .left = Operand.of(left), .right = Operand.of(right), .details = details };
    assert_at(@tagName(kind), holds, message, merged, caller);
    // An `always` is interesting where it breaks, a `sometimes` where it holds.
    const site = catalog_site(@tagName(kind), message);
    site.guide(message, if (kind == .always) margin else -margin);
}

/// A comparison's operand in its details. JSON has no infinity or NaN: std.json writes infinity
/// bare (`inf`), which no parser reads, so the whole assertion was lost (stored as raw text,
/// never judged), and NaN as "nan". They are the strings "Infinity", "-Infinity" and "NaN", as
/// every SDK of ours sends them (Antithesis's 63.12: consistent numeric edge cases).
const Operand = union(enum) {
    integer: i128,
    float: f64,

    fn of(value: anytype) Operand {
        return switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => .{ .integer = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            else => @compileError("guidance assertions compare numbers"),
        };
    }

    pub fn jsonStringify(operand: Operand, stringify: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (operand) {
            .integer => |integer| try stringify.write(integer),
            .float => |float| {
                if (std.math.isNan(float)) return stringify.write("NaN");
                if (std.math.isInf(float)) return stringify.write(if (float > 0) "Infinity" else "-Infinity");
                try stringify.write(float);
            },
        }
    }
};

fn number(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("guidance assertions compare numbers"),
    };
}

fn conditions_held(conditions: anytype) u32 {
    const info = @typeInfo(@TypeOf(conditions)).@"struct";
    var held: u32 = 0;
    inline for (info.field_names, info.field_types) |name, Type| {
        comptime assert(Type == bool);
        held += @intFromBool(@field(conditions, name));
    }
    return held;
}

/// `{"guidance":{"message":M,"distance":D}}`: how far this timeline is from the assertion's
/// interesting outcome, for strategies.
fn guidance(message: []const u8, distance: f64) void {
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"guidance\":{\"message\":") catch unreachable;
    json_write(&writer, message);
    // An infinite one (a comparison with an infinite operand) as the largest JSON number: there
    // (or as far as can be), and the message stays JSON. NaN never comes here (guide's `<`).
    const finite = std.math.clamp(distance, -std.math.floatMax(f64), std.math.floatMax(f64));
    writer.print(",\"distance\":{d}}}}}", .{finite}) catch unreachable;
    emit_raw(writer.buffered());
}

test "guidance assertions compute their distance" {
    try std.testing.expectEqual(@as(f64, 3), number(@as(u8, 3)));
    const conditions = .{ .a = true, .b = false, .c = true };
    try std.testing.expectEqual(@as(u32, 2), conditions_held(conditions));
}

/// An objective for exploration (Antithesis's, "Optimizing our way through Metroid"): `bucket`'s
/// strings and booleans split states into buckets (a leader, a phase), explored evenly, each
/// keeping the state that scored best on `value` (more uncommitted entries, a longer
/// partition): returns go to it, and from it further. Numbers in the bucket are left out.
pub fn optimize(comptime message: []const u8, bucket: anytype, value: f64, comptime goal: Goal) void {
    comptime assert(message.len > 0);
    optimize_computed(message, bucket, value, goal);
}

/// `optimize` with a message known at run time.
pub fn optimize_computed(message: []const u8, bucket: anytype, value: f64, goal: Goal) void {
    assert(message.len > 0);
    if (!std.math.isFinite(value)) return; // No JSON number.
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"optimize\":{\"message\":") catch unreachable;
    json_write(&writer, message);
    writer.writeAll(",\"bucket\":") catch unreachable;
    json_write(&writer, bucket);
    writer.print(",\"value\":{d},\"goal\":\"{s}\"}}}}", .{ value, @tagName(goal) }) catch return;
    emit_raw(writer.buffered());
}

pub const Goal = enum { maximize, minimize };

/// JSON text written as it is where a value goes (details, buckets, fault requests): what
/// programs in other languages hand libdeterminismo. The caller checked that it is JSON.
pub const RawJson = struct {
    text: []const u8,

    pub fn jsonStringify(raw: RawJson, stringify: *std.json.Stringify) !void {
        try stringify.beginWriteRaw();
        try stringify.writer.writeAll(raw.text);
        stringify.endWriteRaw();
    }
};

pub const Kind = enum { always, always_or_unreachable, sometimes, reachable, @"unreachable" };

/// An assertion whose message is computed at run time: known to the platform only once it runs
/// (declare it with `declare` to have it judged before).
pub fn assert_computed(kind: Kind, condition: bool, message: []const u8, details: anytype) void {
    assert_computed_at(kind, condition, message, details, null);
}

/// An assertion judged after the fact (a checker reading a whole history at the end): `at_ns`
/// says when what it judges happened, on the guest's monotonic clock. That clock is not the
/// platform's virtual time: it starts once the guest kernel keeps time, ~0.1 s after the VM does
/// (0.098 s, MongoDB run 1970), so the assertion carries the clock's now beside it (`now_ns`) and
/// the platform takes the moment as the event's vtime less (now_ns - at_ns): a failure's moment
/// (its examples, lead-up, analyses, exports and bundles), not when the verdict was asserted.
pub fn assert_computed_at(kind: Kind, condition: bool, message: []const u8, details: anytype, at_ns: ?u64) void {
    const value = Assertion{ .condition = condition, .message = message };
    switch (kind) {
        inline else => |known| emit_assertion(@tagName(known), value, details, null, at_ns),
    }
}

/// One catalog entry, in the det_catalog section: every assertion call site compiled into the
/// program has one (the magic tells entries from the linker's padding between them).
pub const CatalogEntry = extern struct {
    magic: u64 = catalog_magic,
    kind: [*:0]const u8,
    message: [*:0]const u8,
    message_size: u64,
};
const catalog_magic: u64 = 0x676f_6c61_7461_6364; // "dcatalog"

/// What one assertion has sent in this process: for first-pass-first-failure events, and to
/// send guidance only when it improves (all a strategy needs).
const SiteState = struct {
    passed: bool = false,
    failed: bool = false,
    located: bool = false,
    best: f64 = std.math.inf(f64),

    /// Whether this evaluation adds nothing the platform does not have (assertion_events = first).
    fn repeated(site: *SiteState, condition: bool) bool {
        if (assertion_events == .every) return false;
        const seen = if (condition) &site.passed else &site.failed;
        if (seen.*) return true;
        seen.* = true;
        return false;
    }

    fn guide(site: *SiteState, message: []const u8, distance: f64) void {
        if (!(distance < site.best)) return;
        site.best = distance;
        guidance(message, distance);
    }
};

fn catalog_site(comptime kind: [:0]const u8, comptime message: []const u8) *SiteState {
    comptime assert(message.len > 0);
    const Site = struct {
        const entry: CatalogEntry linksection("det_catalog") = .{
            .kind = kind,
            .message = message ++ "",
            .message_size = message.len,
        };
        var state: SiteState = .{};
    };
    // A reference from the call site keeps its entry (and the section) in the linked program.
    std.mem.doNotOptimizeAway(&Site.entry);
    return &Site.state;
}

/// Puts an assertion whose message is known at compile time in the program's catalog, for one
/// evaluated with that message computed (`assert_computed`).
pub fn catalog_entry(comptime kind: [:0]const u8, comptime message: []const u8) void {
    _ = catalog_site(kind, message);
}

extern const __start_det_catalog: u8;
extern const __stop_det_catalog: u8;
/// Keeps the section in every program that uses the SDK, assertions or not.
const catalog_sentinel: CatalogEntry linksection("det_catalog") = .{
    .kind = "",
    .message = "",
    .message_size = 0,
};

/// Announces the catalog: run before main (.init_array), so a program that never calls the SDK
/// still declares its assertions. Only inside determinismo, and once per program file on each
/// machine or node: a test program runs as many processes, one per command.
fn catalog_announce() callconv(.c) void {
    std.mem.doNotOptimizeAway(&catalog_sentinel);
    // Probed, not cached when absent: det-init starts before /dev is mounted.
    if (device == .unopened) {
        const result = linux.open(device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) return;
        device = .{ .fd = @intCast(result) };
    }
    if (device != .fd) return;
    if (!catalog_first()) return;
    const start = @intFromPtr(&__start_det_catalog);
    const stop = @intFromPtr(&__stop_det_catalog);
    var at = std.mem.alignForward(usize, start, @alignOf(CatalogEntry));
    while (at + @sizeOf(CatalogEntry) <= stop) {
        const entry: *const CatalogEntry = @ptrFromInt(at);
        if (entry.magic != catalog_magic) {
            at += @alignOf(CatalogEntry);
            continue;
        }
        at += @sizeOf(CatalogEntry);
        if (entry.message_size == 0) continue; // The sentinel.
        const message = entry.message[0..entry.message_size];
        declare_runtime(std.mem.span(entry.kind), message);
    }
}

const Hook = *const fn () callconv(.c) void;
export const determinismo_catalog_announce: Hook linksection(".init_array") = &catalog_announce;

/// Whether this is the first process of this program file to announce its catalog here: a
/// marker named after the file (device and inode) is created once.
fn catalog_first() bool {
    var status: linux.Statx = undefined;
    const statted = linux.statx(linux.AT.FDCWD, "/proc/self/exe", 0, .{ .INO = true }, &status);
    if (linux.errno(statted) != .SUCCESS) return true;
    var path_buffer: [96]u8 = undefined;
    const format = "/tmp/.determinismo-catalog-{x}-{x}-{x}";
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{
        status.dev_major, status.dev_minor, status.ino,
    }, 0) catch return true;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const result = linux.open(path, flags, 0o444);
    switch (linux.errno(result)) {
        .SUCCESS => {
            _ = linux.close(@intCast(result));
            return true;
        },
        .EXIST => return false,
        else => return true, // No /tmp to mark: announcing twice is harmless.
    }
}

/// Declares an assertion without evaluating it (Antithesis's catalog): a `reachable` or
/// `sometimes` declared and never reached (or never true) in any timeline fails, as an
/// `always` never hit does. Assertions with literal messages are declared already.
pub fn declare(comptime kind: []const u8, message: []const u8) void {
    if (declared_count < declared_assertions.len and message.len <= 255) {
        const known = &declared_assertions[declared_count];
        known.kind = kind;
        @memcpy(known.message[0..message.len], message);
        known.message_size = @intCast(message.len);
        declared_count += 1;
    }
    if (device_get() == .fd) declare_runtime(kind, message);
}

/// One assertion the program declares.
pub const CatalogAssertion = struct { kind: []const u8, message: []const u8 };

/// The program's assertions: its call sites (the det_catalog section), then those declared at
/// run time (up to 64).
pub const CatalogIterator = struct {
    at: usize,
    declared: u32 = 0,

    pub fn next(iterator: *CatalogIterator) ?CatalogAssertion {
        const stop = @intFromPtr(&__stop_det_catalog);
        while (iterator.at + @sizeOf(CatalogEntry) <= stop) {
            const entry: *const CatalogEntry = @ptrFromInt(iterator.at);
            if (entry.magic != catalog_magic) {
                iterator.at += @alignOf(CatalogEntry);
                continue;
            }
            iterator.at += @sizeOf(CatalogEntry);
            if (entry.message_size == 0) continue; // The sentinel.
            return .{ .kind = std.mem.span(entry.kind), .message = entry.message[0..entry.message_size] };
        }
        if (iterator.declared == declared_count) return null;
        const known = &declared_assertions[iterator.declared];
        iterator.declared += 1;
        return .{ .kind = known.kind, .message = known.message[0..known.message_size] };
    }
};

pub fn catalog_assertions() CatalogIterator {
    std.mem.doNotOptimizeAway(&catalog_sentinel);
    return .{ .at = std.mem.alignForward(usize, @intFromPtr(&__start_det_catalog), @alignOf(CatalogEntry)) };
}

/// Writes the catalog to `fd`, one JSON object a line (`{"kind","message"}`): what a program
/// checks, for review or CI.
pub fn catalog_write(fd: linux.fd_t) void {
    var iterator = catalog_assertions();
    while (iterator.next()) |assertion| {
        var buffer: [message_size_max]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        json_write(&writer, assertion);
        writer.writeByte('\n') catch continue;
        _ = linux.write(fd, writer.buffered().ptr, writer.buffered().len);
    }
}

const DeclaredAssertion = struct { kind: []const u8, message: [256]u8, message_size: u8 };
var declared_assertions: [64]DeclaredAssertion = undefined;
var declared_count: u32 = 0;

fn declare_runtime(kind: []const u8, message: []const u8) void {
    assert(message.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"assert\":{{\"type\":\"{s}\",\"message\":", .{kind}) catch unreachable;
    json_write(&writer, message);
    writer.writeAll(",\"hit\":false}}") catch unreachable;
    emit_raw(writer.buffered());
}

/// The system is ready: the platform snapshots here and starts exploring.
pub fn setup_complete(details: anytype) void {
    lifecycle("setup_complete", details);
}

/// A lifecycle point the platform acts on (`setup_complete`; `guest_done` from the runtime).
pub fn lifecycle(comptime name: []const u8, details: anytype) void {
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"lifecycle\":\"" ++ name ++ "\",\"details\":") catch unreachable;
    json_write(&writer, details);
    writer.writeAll("}") catch unreachable;
    emit_raw(writer.buffered());
}

/// A structured event: `{"event": name, "details": details}`.
/// This timeline's state looks hopeless for finding anything more (a cluster wedged by a known
/// bug, a workload that cannot progress): the explorer weighs returns after this moment down, by a
/// share it draws each generation (main.zig's doom; never excluded: a hopeless state can still
/// hold a bug). The first call in a timeline counts.
pub fn doomed(message: []const u8, details: anytype) void {
    event("doomed", .{ .message = message, .details = details });
}

pub fn event(name: []const u8, details: anytype) void {
    assert(name.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"event\":") catch unreachable;
    json_write(&writer, name);
    writer.writeAll(",\"details\":") catch unreachable;
    json_write(&writer, details);
    writer.writeAll("}") catch unreachable;
    emit_raw(writer.buffered());
}

/// A record for the program's host check `name` (System.main's `.checks`): one JSON line in the
/// runner, which the composer sends out when the timeline ends; the host runs the check on all
/// of them, decoded as its Record type. Records are appended with one write each, so commands in
/// parallel never interleave inside one.
pub fn record(comptime name: []const u8, value: anytype) void {
    var buffer: [record_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return; // Too large: not recorded.
    writer.writeByte('\n') catch return;
    record_line(schema.record_path(name), writer.buffered());
}

pub const record_size_max = message_size_max * 16;

/// A file's whole contents, in `arena`; empty when there is none (a records file no command
/// wrote yet).
pub fn file_read(arena: std.mem.Allocator, path: [*:0]const u8) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) == .NOENT) return "";
    if (linux.errno(fd) != .SUCCESS) return error.ReadFailed;
    defer _ = linux.close(@intCast(fd));
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        try bytes.ensureUnusedCapacity(arena, 4096);
        const free = bytes.unusedCapacitySlice();
        const read = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(read) != .SUCCESS) return error.ReadFailed;
        if (read == 0) return bytes.items;
        bytes.items.len += read;
    }
}

/// Appends one record line (JSON and its newline) to `path`, with one write.
pub fn record_line(path: [:0]const u8, line: []const u8) void {
    assert(line.len > 0 and line[line.len - 1] == '\n');
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

/// A command run by the guest's runner, which sees every node (det-runner: det-nodes start,
/// stop, kill, crash, pause, exec; the network, the disks), from a program in a node as from
/// one in the runner: `request` is {"argv": [...], "stdin"?: "..."} as JSON, the reply
/// {"status", "stdout", "stderr", "truncated"} appended to `reply`. Unavailable outside a
/// guest. What a platform mechanic written in a program's language is made of.
pub fn runner(allocator: std.mem.Allocator, request: []const u8, reply: *std.ArrayList(u8)) !void {
    assert(std.mem.indexOfScalar(u8, request, '\n') == null);
    const socket = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.RunnerUnavailable;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..schema.runner_socket.len], schema.runner_socket);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        return error.RunnerUnavailable;
    }
    for ([_][]const u8{ request, "\n" }) |part| {
        var rest = part;
        while (rest.len > 0) {
            const result = linux.write(fd, rest.ptr, rest.len);
            switch (linux.errno(result)) {
                .SUCCESS => rest = rest[result..],
                .INTR => {},
                else => return error.RunnerFailed,
            }
        }
    }
    var chunk: [16 << 10]u8 = undefined;
    while (true) {
        const result = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.RunnerFailed,
        }
        if (result == 0) break;
        try reply.appendSlice(allocator, chunk[0..result]);
    }
    if (reply.items.len == 0) return error.RunnerFailed;
}

/// Sleeps for `duration_ms` of (virtual) time.
/// A driver's pause before it returns for its server's unavailability (`tcp.unavailable`): 200 ms
/// to a second, drawn (named). Returning at once, the composer starts the driver again within 20
/// ms, and an outage of seconds becomes thousands of starts (etcd's lease driver: 1,606 in one
/// timeline, trial run 1534).
pub fn unavailable_pause() void {
    sleep_ms(200 + random_below_named("driver.unavailable_pause_ms", 800));
}

pub fn sleep_ms(duration_ms: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ms / std.time.ms_per_s),
        .nsec = @intCast((duration_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}

/// A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS, as det-stop-faults): faults stop (the
/// one under way is undone) for `duration_ns`, except clock skips; 0 ends it now. For checks a
/// fault would explain away: what fails in a quiet period is the system's own doing. Does
/// nothing without a running fault injector.
pub fn stop_faults(duration_ns: u64) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    const request = std.mem.toBytes(std.mem.nativeToLittle(u64, duration_ns));
    _ = linux.write(@intCast(fd), &request, request.len); // Atomic: under PIPE_BUF.
}

/// progress_while_quiet's window by default: long enough for TCP. A connection whose packets a
/// partition dropped retransmits with exponential backoff (up to about two minutes on Linux)
/// and is silent until its next try, so a system can sit idle for tens of seconds after the
/// heal through no fault of its own: NATS smoke run 338, its routes 21 s after their partition
/// still waiting (of 1108 windows the median recovered in 2.1 s, the longest 23.4 s, one never
/// within 30 s). The property returns at its first success: a longer window costs nothing then.
pub const progress_window_ms = 120_000;

/// Progress while faults pause (Antithesis's property catalogs: a key-value store serves, a
/// queue's producers and consumers move, in fault-free windows mid-run, not only once faults
/// are over): faults stop (a quiet period: what was under way heals) and `function` is retried
/// every `interval_ms` until it succeeds, for at most `window_ms` (the system's time to recover,
/// an election or a member back, and one operation); then faults resume at once (the pacing's
/// own quiet stretch, if one is under way, goes on). `message` is the property: it fails when a
/// whole window passes without a success; a timeline that never ran it does not judge it.
/// Returns whether it succeeded, or null when another window was under way (one at a time:
/// ending one would cut the other short). For a parallel driver of the scenario: a singleton
/// driver makes half the timelines run it alone.
pub fn progress_while_quiet(
    comptime message: []const u8,
    window_ms: u64,
    interval_ms: u64,
    function: anytype,
    arguments: anytype,
) ?bool {
    assert(window_ms > 0 and interval_ms > 0);
    const lock_flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const lock = linux.open("/tmp/determinismo-progress.lock", lock_flags, 0o600);
    if (linux.errno(lock) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(lock));
    if (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) return null;
    const start_ns = monotonic_ns();
    stop_faults(window_ms * std.time.ns_per_ms);
    defer stop_faults(0);
    var attempts: u32 = 0;
    while (true) {
        attempts += 1;
        const result = @call(.auto, function, arguments);
        const elapsed_ms = (monotonic_ns() - start_ns) / std.time.ns_per_ms;
        if (result) |_| {
            always_or_unreachable(true, message, .{ .attempts = attempts, .after_ms = elapsed_ms });
            return true;
        } else |err| if (elapsed_ms + interval_ms > window_ms) {
            always_or_unreachable(false, message, .{
                .attempts = attempts,
                .window_ms = window_ms,
                .err = @errorName(err),
            });
            return false;
        }
        sleep_ms(interval_ms);
    }
}

/// Virtual time inside determinismo, monotonic.
fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @intCast(now.sec * std.time.ns_per_s + now.nsec);
}

/// A fault now, from the scenario (as `det-faults inject`): the injector applies it, logs it
/// and undoes it like one it drew. `request` is written as JSON: `.{ .kind = "pause", .node =
/// "db", .duration_ms = 2000 }`, `.{ .kind = "partition_groups", .groups = .{ .{ "runner", "a"
/// }, .{"b"} }, .disruption = "stopped", .direction = "both" }`, `.{ .kind = "degrade", .node =
/// "a", .peer = "b", .flavor = "delay_loss" }`; guest/runtime/faults.zig lists them all. Only
/// while the injector runs (the drivers); otherwise nothing happens.
pub fn fault(request: anytype) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    var message: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(message[8..]);
    std.json.Stringify.value(request, .{}, &writer) catch return; // Too large: not sent.
    const length = writer.buffered().len;
    std.mem.writeInt(u64, message[0..8], (@as(u64, 1) << 63) | length, .little);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), &message, length + 8); // Atomic: under PIPE_BUF.
}

/// Aims the injector's faults at `node` from now on, until another call ("" for none): half its
/// faults involve it (the node itself, or a link of it), the other half any, each a decision
/// strategies see and replays repeat. For the node a scenario finds that matters most at the
/// moment (a primary, a leader), as Jepsen's nemeses target one. Only while the injector runs.
pub fn fault_aim(node: []const u8) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    const aim_flag: u64 = 1 << 61; // faults.zig's aim_flag.
    var message: [8 + 32]u8 = undefined;
    const size = @min(node.len, 32);
    std.mem.writeInt(u64, message[0..8], aim_flag | size, .little);
    @memcpy(message[8..][0..size], node[0..size]);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), &message, 8 + size); // Atomic: under PIPE_BUF.
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// Calls `function` with `arguments` until it succeeds, at most `attempts` times and
/// `interval_ms` apart: what checks need while a system recovers (after faults, a restart).
/// Returns its value, or its last error.
pub fn retry(
    attempts: u32,
    interval_ms: u64,
    function: anytype,
    arguments: anytype,
) Result(@TypeOf(function)) {
    assert(attempts > 0);
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (@call(.auto, function, arguments)) |value| {
            return value;
        } else |err| {
            if (attempt == attempts) return err;
            sleep_ms(interval_ms);
        }
    }
}

/// Calls `function` with `arguments` until it succeeds or `window_ms` of the guest's time has
/// passed, `interval_ms` between attempts (at least one attempt): `retry` with a deadline, for
/// waits whose attempts can be slow. Counted attempts multiply with them: Consul's "two minutes"
/// of 240 attempts ran half an hour against a leaderless cluster, each read waiting seconds.
/// Returns its value, or its last error.
pub fn retry_within(
    window_ms: u64,
    interval_ms: u64,
    function: anytype,
    arguments: anytype,
) Result(@TypeOf(function)) {
    assert(window_ms > 0);
    const deadline_ns = monotonic_ns() + window_ms * std.time.ns_per_ms;
    while (true) {
        if (@call(.auto, function, arguments)) |value| {
            return value;
        } else |err| {
            if (monotonic_ns() + interval_ms * std.time.ns_per_ms >= deadline_ns) return err;
            sleep_ms(interval_ms);
        }
    }
}

test retry_within {
    const Flaky = struct {
        var calls: u32 = 0;
        fn call(succeed_at: u32) !u32 {
            calls += 1;
            return if (calls >= succeed_at) calls else error.NotYet;
        }
    };
    try std.testing.expectEqual(3, try retry_within(1000, 1, Flaky.call, .{3}));
    Flaky.calls = 0;
    // Never succeeding: its last error once the window passed, after at least one attempt.
    try std.testing.expectError(error.NotYet, retry_within(5, 1, Flaky.call, .{1_000_000}));
    try std.testing.expect(Flaky.calls >= 1);
}

const Assertion = struct { condition: bool, message: []const u8 };

fn emit_assertion(
    comptime kind: []const u8,
    assertion: Assertion,
    details: anytype,
    caller: ?usize,
    at_ns: ?u64,
) void {
    assert(assertion.message.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"assert\":{\"type\":\"" ++ kind ++ "\",\"message\":") catch unreachable;
    json_write(&writer, assertion.message);
    writer.print(",\"condition\":{},\"details\":", .{assertion.condition}) catch unreachable;
    json_write(&writer, details);
    if (at_ns) |at| {
        writer.print(",\"at_ns\":{d}", .{at}) catch unreachable;
        // The guest's clock beside it, inside the guest only (its determinismo device): a check
        // the explorer runs on the host reads its host's clock (DuckDB run 1983: srv4's 48,000 s
        // against 183 s of vtime), and its at_ns, from the history, is the guest's already.
        if (device_get() == .fd) {
            var now_spec: linux.timespec = undefined;
            _ = linux.clock_gettime(.MONOTONIC, &now_spec);
            const now_ns: u64 = @intCast(now_spec.sec * std.time.ns_per_s + now_spec.nsec);
            writer.print(",\"now_ns\":{d}", .{now_ns}) catch unreachable;
        }
    }
    if (caller) |address| location_write(&writer, address);
    writer.writeAll("}}") catch unreachable;
    emit_raw(writer.buffered());
}

/// `,"location":{"file","line","function"}` for a return address, from the program's own debug
/// info; nothing when there is none (a stripped program) or it does not fit.
fn location_write(writer: *std.Io.Writer, address: usize) void {
    const info = std.debug.getSelfDebugInfo() catch return;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    // The return address follows the call: one byte back is in it.
    const io = std.Options.debug_io;
    info.getSymbols(io, arena, arena, address -| 1, false, &symbols) catch return;
    if (symbols.items.len == 0) return;
    const symbol = symbols.items[0];
    const source = symbol.source_location orelse return;
    var buffer: [512]u8 = undefined;
    var location: std.Io.Writer = .fixed(&buffer);
    location.writeAll(",\"location\":{\"file\":") catch return;
    std.json.Stringify.value(source.file_name, .{}, &location) catch return;
    location.print(",\"line\":{d},\"function\":", .{source.line}) catch return;
    std.json.Stringify.value(symbol.name orelse "", .{}, &location) catch return;
    location.writeAll("}") catch return;
    // Two bytes stay for the envelope's closing braces.
    if (writer.end + location.end + 2 > writer.buffer.len) return;
    writer.writeAll(location.buffered()) catch unreachable;
}

fn json_write(writer: *std.Io.Writer, value: anytype) void {
    const start = writer.end;
    const fits = if (std.json.Stringify.value(value, .{}, writer)) |_|
        writer.buffer.len - writer.end >= json_closing_max
    else |_|
        false;
    const valid = fits and json_valid(writer.buffered()[start..]);
    if (valid) return;
    // Details that don't fit, with room for what closes the message after them, are cut: their
    // JSON text as a string, as much as fits ("<details cut> ..."), never the assertion itself
    // (Consul's driver panicked on an event whose details fit but left no room for its closing
    // brace). Replaced whole they said nothing: Bun's suite lost a failing test's output (run
    // 731, node-net.test.ts).
    writer.end = start;
    var scratch: [message_size_max]u8 = undefined;
    var text: std.Io.Writer = .fixed(&scratch);
    std.json.Stringify.value(value, .{}, &text) catch {}; // What fits of it is enough.
    const prefix = if (fits) "<details not JSON> " else "<details cut> ";
    json_string_cut(writer, prefix, text.buffered(), writer.buffer.len - json_closing_max);
}

/// Whether std.json wrote JSON: not when the value held an infinite float (written bare, `inf`);
/// such details go as their text, a string, as cut ones do, and the assertion stays judged.
fn json_valid(written: []const u8) bool {
    if (std.mem.indexOf(u8, written, "inf") == null) return true; // The one way it is not.
    var stack: [1024]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&stack);
    return std.json.validate(allocator.allocator(), written) catch false;
}

/// `prefix` then as much of `text` as fits before `limit`, as one JSON string: whole code points
/// only (a cut one would make the message invalid UTF-8), escaped as JSON escapes them.
fn json_string_cut(writer: *std.Io.Writer, prefix: []const u8, text: []const u8, limit: usize) void {
    // The quotes fit whatever is left: the buffer keeps json_closing_max beyond `limit`.
    writer.writeByte('"') catch unreachable;
    if (writer.end + prefix.len + 1 <= limit) writer.writeAll(prefix) catch unreachable;
    var index: usize = 0;
    while (index < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        if (index + size > text.len) break;
        var escaped_buffer: [8]u8 = undefined;
        var escaped: std.Io.Writer = .fixed(&escaped_buffer);
        std.json.Stringify.encodeJsonStringChars(text[index..][0..size], .{}, &escaped) catch break;
        if (writer.end + escaped.end + 1 > limit) break;
        writer.writeAll(escaped.buffered()) catch unreachable;
        index += size;
    }
    writer.writeByte('"') catch unreachable;
}

/// What a message may still write after a value: its closing braces.
const json_closing_max = 16;

test "json_write leaves room for what closes the message, and keeps what fits" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"event\":") catch unreachable;
    // A string that fits the buffer but leaves no room for "}".
    const filler: [50]u8 = @splat('x');
    json_write(&writer, @as([]const u8, &filler));
    writer.writeAll("}") catch unreachable;
    const message = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, message, "{\"event\":\"<details cut> \\\"xx"));
    try std.testing.expect(message.len <= buffer.len - json_closing_max + 1);
    // Valid JSON, cut where it must be.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, message, .{});
    defer parsed.deinit();
}

test "a comparison's numbers that are not finite stay JSON: the assertion is judged" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const inf = std.math.inf(f64);
    // A comparison's operands (compare's details), each SDK's convention.
    json_write(&writer, .{ .left = Operand.of(inf), .right = Operand.of(-inf), .nan = Operand.of(std.math.nan(f64)), .count = Operand.of(3) });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Infinity", parsed.value.object.get("left").?.string);
    try std.testing.expectEqualStrings("-Infinity", parsed.value.object.get("right").?.string);
    try std.testing.expectEqualStrings("NaN", parsed.value.object.get("nan").?.string);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("count").?.integer);
    // A program's own details with one: their text, a string, rather than no assertion at all.
    var other: [256]u8 = undefined;
    var details: std.Io.Writer = .fixed(&other);
    json_write(&details, .{ .latency = inf });
    const kept = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, details.buffered(), .{});
    defer kept.deinit();
    try std.testing.expect(std.mem.startsWith(u8, kept.value.string, "<details not JSON> {\"latency\":inf"));
    // Valid details with the word in them stay an object.
    var plain: [256]u8 = undefined;
    var valid: std.Io.Writer = .fixed(&plain);
    json_write(&valid, .{ .note = "information", .nested = .{ .deeper = .{ .count = 1 } } });
    const object = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid.buffered(), .{});
    defer object.deinit();
    try std.testing.expectEqualStrings("information", object.value.object.get("note").?.string);
}

test "json_string_cut keeps whole code points" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // "aé" then "€": the limit falls inside "€" (3 bytes), so it is left out whole.
    json_string_cut(&writer, "", "a\u{e9}\u{20ac}", 6);
    try std.testing.expectEqualStrings("\"a\u{e9}\"", writer.buffered());
}

fn emit_raw(message: []const u8) void {
    assert(message.len > 0);
    assert(message.len <= message_size_max);
    switch (device_get()) {
        .fd => |fd| {
            const result = linux.write(fd, message.ptr, message.len);
            assert(linux.errno(result) == .SUCCESS);
            assert(result == message.len);
        },
        .local => {
            const fd = local_output_fd() orelse return;
            _ = linux.write(fd, message.ptr, message.len);
            _ = linux.write(fd, "\n", 1);
        },
        .unopened => unreachable,
    }
}

/// Outside determinismo: the file DETERMINISMO_SDK_LOCAL_OUTPUT (or Antithesis's
/// ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else nothing (Antithesis's default:
/// assertions evaluated, nothing written). From /proc/self/environ: the SDK needs no libc.
var local_output: ?linux.fd_t = null;
var local_output_looked = false;

fn local_output_fd() ?linux.fd_t {
    if (local_output) |fd| return fd;
    if (local_output_looked) return null;
    local_output_looked = true;
    var environ_buffer: [32 * 1024]u8 = undefined;
    const environ_fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(environ_fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(environ_fd));
    const size = linux.read(@intCast(environ_fd), &environ_buffer, environ_buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "DETERMINISMO_SDK_LOCAL_OUTPUT=", "ANTITHESIS_SDK_LOCAL_OUTPUT=" }) |key| {
        var entries = std.mem.splitScalar(u8, environ_buffer[0..size], 0);
        while (entries.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, key) or entry.len == key.len) continue;
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{entry[key.len..]}, 0) catch continue;
            const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
            const fd = linux.open(path, flags, 0o644);
            if (linux.errno(fd) != .SUCCESS) continue;
            local_output = @intCast(fd);
            return local_output.?;
        }
    }
    return null;
}

/// An environment variable's value (`key` ends with "="), copied into `buffer`; null when unset
/// or empty. From /proc/self/environ: the SDK needs no libc.
fn environment_value(key: []const u8, buffer: []u8) ?[]const u8 {
    @disableInstrumentation();
    var environ_buffer: [32 * 1024]u8 = undefined;
    const fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &environ_buffer, environ_buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var entries = std.mem.splitScalar(u8, environ_buffer[0..size], 0);
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, key) or entry.len == key.len) continue;
        const value = entry[key.len..];
        if (value.len > buffer.len) return null;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    return null;
}

/// Any JSON value as an event of its own (the protocol's raw form: docs/SDKS.md).
pub fn output(value: anytype) void {
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    json_write(&writer, value);
    emit_raw(writer.buffered());
}

/// Code coverage for strategies: build the program with `sanitize_coverage_trace_pc_guard` set
/// on its compile step, and reference this (`comptime { _ = sdk.coverage; }`). Each edge then
/// emits a "coverage" event the first time a process runs it, which strategies such as
/// det-strategy-mutate use to keep timelines that reach new code. Same events as the C SDK's:
/// the edge as the source line it is on ("line <file>:<n>", from the program's own debug
/// information, for targeted runs and the causality analysis's code), "edge <n>" without one.
/// Every pass through an edge is also where thread pausing may pause (`pausing`).
pub const coverage = struct {
    var next: u32 = 1;
    /// A guard's top bit: its edge reported (the rest its number, kept for thread pausing).
    const reported: u32 = 0x8000_0000;
    /// Edges the SDK runs while reporting one are reported later, when they run again.
    var busy = false;
    // Zig's instrumentation also tracks stack depth (unused here) in a thread-local the program
    // must define. In assembly: defined in Zig, LLVM's pass would not bind to it.
    comptime {
        asm (
            \\.section .tbss,"awT",@nobits
            \\.globl __sancov_lowest_stack
            \\.type __sancov_lowest_stack,@object
            \\.p2align 3
            \\__sancov_lowest_stack:
            \\.zero 8
            \\.size __sancov_lowest_stack, 8
            \\.text
        );
    }

    export fn __sanitizer_cov_trace_pc_guard_init(start: [*]u32, stop: [*]u32) void {
        @disableInstrumentation();
        const count = (@intFromPtr(stop) - @intFromPtr(start)) / @sizeOf(u32);
        if (count == 0 or start[0] != 0) return; // Already numbered.
        for (start[0..count]) |*guard| {
            guard.* = next;
            next += 1;
        }
        shared.add(start, stop);
    }

    /// Which edges the timeline reported, shared by every process of every node (as the C
    /// SDK's): a bit per guard in /opt/determinismo/coverage/sdk-zig-<the executable's device,
    /// inode and size> (a Zig program has no build ID by default; within a timeline, its file
    /// names its build). A process started again (a node restarted, a command run anew) reports
    /// only the edges no process did: each reported every edge again, Zig's standard library's
    /// too, an event (a VM exit) each.
    const shared = struct {
        const modules_max = 64;
        const Module = struct { start: usize, stop: usize, bits: ?[*]u8 };
        var modules: [modules_max]Module = undefined;
        var count: usize = 0;

        fn add(start: [*]u32, stop: [*]u32) void {
            @disableInstrumentation();
            if (count == modules_max or device_get() != .fd) return;
            const edges = (@intFromPtr(stop) - @intFromPtr(start)) / @sizeOf(u32);
            modules[count] = .{ .start = @intFromPtr(start), .stop = @intFromPtr(stop), .bits = open(edges) };
            count += 1;
        }

        fn open(edges: usize) ?[*]u8 {
            @disableInstrumentation();
            var stat: linux.Statx = undefined;
            const mask: linux.STATX = .{ .INO = true, .SIZE = true };
            if (linux.errno(linux.statx(linux.AT.FDCWD, "/proc/self/exe", 0, mask, &stat)) != .SUCCESS) return null;
            var path_buffer: [128]u8 = undefined;
            const format = "/opt/determinismo/coverage/sdk-zig-{x}-{x}-{x}-{x}";
            const identity = .{ stat.dev_major, stat.dev_minor, stat.ino, stat.size };
            const path = std.fmt.bufPrintSentinel(&path_buffer, format, identity, 0) catch return null;
            const fd = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o666);
            if (linux.errno(fd) != .SUCCESS) return null;
            defer _ = linux.close(@intCast(fd));
            const size = std.mem.alignForward(usize, (edges + 7) / 8, std.heap.page_size_min);
            if (linux.errno(linux.ftruncate(@intCast(fd), @intCast(size))) != .SUCCESS) return null;
            const protection: linux.PROT = .{ .READ = true, .WRITE = true };
            const address = linux.mmap(null, size, protection, .{ .TYPE = .SHARED }, @intCast(fd), 0);
            if (linux.errno(address) != .SUCCESS) return null;
            return @ptrFromInt(address);
        }

        /// Whether a process of the timeline reported this edge before (this one has now).
        fn reported_before(guard: *u32) bool {
            @disableInstrumentation();
            const at = @intFromPtr(guard);
            for (modules[0..count]) |module| {
                if (at < module.start or at >= module.stop) continue;
                const bits = module.bits orelse return false;
                const index = (at - module.start) / @sizeOf(u32);
                const bit: u8 = @as(u8, 1) << @intCast(index % 8);
                return @atomicRmw(u8, &bits[index / 8], .Or, bit, .monotonic) & bit != 0;
            }
            return false;
        }
    };

    export fn __sanitizer_cov_trace_pc_guard(guard: *u32) void {
        @disableInstrumentation();
        const edge = guard.*;
        if (edge == 0) return;
        if (edge & reported == 0) {
            if (busy) return;
            busy = true;
            defer busy = false;
            var name_buffer: [512]u8 = undefined;
            // The line, before anything else, only when a set asks for it (a DWARF lookup).
            var line: ?[]const u8 = null;
            const looked = set.active();
            if (looked) {
                line = line_of(@returnAddress(), &name_buffer);
                if (!set.holds(line)) {
                    guard.* = 0; // Left out: never again.
                    return;
                }
            }
            guard.* = edge | reported;
            if (!shared.reported_before(guard)) {
                if (!looked) line = line_of(@returnAddress(), &name_buffer);
                const name = line orelse
                    std.fmt.bufPrint(&name_buffer, "edge {d}", .{edge}) catch unreachable;
                event("coverage", .{ .name = name });
            }
        }
        pausing.at(edge & ~reported);
    }

    /// The node's coverage set, DETERMINISMO_COVERAGE (schema.Coverage): source file prefixes,
    /// those starting with "-" excluded. An edge it leaves out (by its source line, the first
    /// time it runs; "" when unknown) reports nothing and pauses nothing. From /proc/self/environ.
    const set = struct {
        var text_buffer: [4096]u8 = undefined;
        var text: ?[]const u8 = null;
        var read = false;

        fn active() bool {
            @disableInstrumentation();
            if (!read) {
                read = true;
                text = environment_value("DETERMINISMO_COVERAGE=", &text_buffer);
            }
            return text != null;
        }

        fn holds(line: ?[]const u8) bool {
            @disableInstrumentation();
            const entries = if (active()) text.? else return true;
            const name = line orelse "";
            const file = if (std.mem.startsWith(u8, name, "line ")) name["line ".len..] else name;
            const path = file[0 .. std.mem.lastIndexOfScalar(u8, file, ':') orelse file.len];
            var included = true;
            var matched = false;
            var iterator = std.mem.splitScalar(u8, entries, ',');
            while (iterator.next()) |entry| {
                if (entry.len > 1 and entry[0] == '-') {
                    if (std.mem.startsWith(u8, path, entry[1..])) return false;
                } else if (entry.len > 0 and entry[0] != '-') {
                    included = false;
                    if (std.mem.startsWith(u8, path, entry)) matched = true;
                }
            }
            return included or matched;
        }
    };

    /// Thread pausing (Antithesis's, which needs their instrumentation too), the C SDK's
    /// det_pausing_at: inside determinismo, one stretch of two seconds (virtual time) in four, a
    /// named decision ("thread pausing") at the stretch's first edge, one edge in 64 is a slow
    /// point with its own pause (1 to 10 ms), drawn for the stretch: a thread reaching one waits
    /// there, at most 8 times a stretch. Threads that reach a slow point wait there together, so
    /// the checks of a check-then-act between them all run before any of its acts. A thread
    /// looks at the clock at its first edge and every 4096.
    const pausing = struct {
        const edges_per_look = 4096;
        const pauses_max = 8;
        /// The clock's seconds / 2 + 1 of the stretch drawn; 0 before any.
        var stretch: u64 = 0;
        /// The stretch's, odd; 0 when it pauses nothing.
        var seed: u64 = 0;
        var lock: bool = false;
        threadlocal var countdown: u32 = 0;
        threadlocal var thread_stretch: u64 = 0;
        threadlocal var thread_pauses: u32 = 0;
        /// The SDK's own code is instrumented too: its edges inside a look or a pause are none.
        threadlocal var inside: bool = false;

        fn at(edge: u32) void {
            @disableInstrumentation();
            if (inside) return;
            inside = true;
            defer inside = false;
            if (device_get() != .fd) return;
            if (countdown == 0) {
                countdown = edges_per_look;
                var now: linux.timespec = undefined;
                _ = linux.clock_gettime(.MONOTONIC, &now); // Virtual time inside determinismo.
                const current = @as(u64, @intCast(now.sec)) / 2 + 1;
                while (@atomicRmw(bool, &lock, .Xchg, true, .acquire)) {}
                if (stretch != current) {
                    @atomicStore(u64, &stretch, current, .monotonic);
                    const drawn = if (random_below_named("thread pausing", 4) == 0) random_u64() | 1 else 0;
                    @atomicStore(u64, &seed, drawn, .monotonic);
                }
                @atomicStore(bool, &lock, false, .release);
            }
            countdown -= 1;
            const drawn = @atomicLoad(u64, &seed, .monotonic);
            if (drawn == 0) return;
            var value = (drawn ^ edge) *% 0x9e3779b97f4a7c15; // The edge's draw for the stretch.
            value ^= value >> 29;
            value *%= 0xbf58476d1ce4e5b9;
            value ^= value >> 32;
            if (value % 64 != 0) return;
            const current = @atomicLoad(u64, &stretch, .monotonic);
            if (thread_stretch != current) {
                thread_stretch = current;
                thread_pauses = 0;
            }
            if (thread_pauses == pauses_max) return;
            thread_pauses += 1;
            sleep_ms(1 + (value >> 8) % 10);
        }
    };

    /// The program's own line table, read once, apart from std.debug's: its SelfInfo is shared
    /// (a lock, an arena), and an edge inside the stack unwinding a SafeAllocator does at each
    /// allocation would wait for the lock that unwinding holds (det-maze-zig hung). Its own
    /// file, Io, allocators and DWARF: nothing the program may be in the middle of.
    const Lines = struct {
        arena: std.heap.ArenaAllocator,
        text: std.heap.ArenaAllocator,
        elf: std.debug.ElfFile,
        /// Where the executable is in memory, less where it says it is (0 unless PIE).
        load_offset: usize,
    };
    var lines: ?Lines = null;
    var lines_failed = false;

    /// "line <file>:<n>" for a code address (a return address: the call is just before it), or
    /// null without debug information there.
    fn line_of(address: usize, buffer: []u8) ?[]const u8 {
        @disableInstrumentation();
        const known = lines_get() orelse return null;
        defer _ = known.text.reset(.retain_capacity);
        const dwarf: *std.debug.Dwarf = if (known.elf.dwarf) |*opened| opened else return null;
        const vaddr = address -% known.load_offset -% 1;
        const unit = dwarf.findCompileUnit(builtin.cpu.arch.endian(), vaddr) catch return null;
        const location = dwarf.getLineNumberInfo(
            known.arena.allocator(),
            known.text.allocator(),
            builtin.cpu.arch.endian(),
            unit,
            vaddr,
        ) catch return null;
        if (location.line == 0) return null;
        return std.fmt.bufPrint(buffer, "line {s}:{d}", .{ location.file_name, location.line }) catch null;
    }

    fn lines_get() ?*Lines {
        @disableInstrumentation();
        if (lines) |*known| return known;
        if (lines_failed) return null;
        lines_failed = true; // Until it is read: once only, whatever happens.
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const file = std.Io.Dir.cwd().openFile(io, "/proc/self/exe", .{}) catch return null;
        defer file.close(io);
        var elf = std.debug.ElfFile.load(arena.allocator(), io, file, null, &.none) catch return null;
        if (elf.dwarf) |*dwarf| {
            dwarf.open(arena.allocator(), builtin.cpu.arch.endian()) catch return null;
        } else return null;
        var offset: ?usize = null;
        std.posix.dl_iterate_phdr(&offset, error{}, struct {
            fn first(info: *std.posix.dl_phdr_info, _: usize, found: *?usize) error{}!void {
                if (found.* == null) found.* = info.addr; // The program comes first.
            }
        }.first) catch {};
        lines = .{
            .arena = arena,
            .text = .init(std.heap.page_allocator),
            .elf = elf,
            .load_offset = offset orelse 0,
        };
        lines_failed = false;
        return &lines.?;
    }
};

fn device_get() Device {
    if (device == .unopened) {
        const result = linux.open(device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        device = switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            else => .local, // Not inside determinismo.
        };
    }
    assert(device != .unopened);
    return device;
}

test {
    _ = schema;
    _ = system;
    _ = elle;
    _ = replicas;
    _ = sideband;
    _ = payloads;
    _ = ring;
    _ = open_loop;
}

test retry {
    const Flaky = struct {
        var calls: u32 = 0;
        fn call(succeed_at: u32) !u32 {
            calls += 1;
            if (calls < succeed_at) return error.NotYet;
            return calls;
        }
    };
    try std.testing.expectEqual(@as(u32, 3), try retry(5, 0, Flaky.call, .{3}));
    Flaky.calls = 0;
    try std.testing.expectError(error.NotYet, retry(2, 0, Flaky.call, .{3}));
}

test "rng and prng draw (from the OS outside determinismo)" {
    const value = rng().intRangeLessThan(u32, 0, 10);
    try std.testing.expect(value < 10);
    var generator = prng();
    try std.testing.expect(generator.random().intRangeLessThan(u32, 0, 10) < 10);
}

test "the catalog lists declared assertions; raw output, buggify_pause and random_float run" {
    declare("sometimes", "declared in a test");
    var iterator = catalog_assertions();
    var found = false;
    while (iterator.next()) |assertion| {
        if (std.mem.eql(u8, assertion.message, "declared in a test")) found = true;
    }
    try std.testing.expect(found);
    // Into a pipe of the test's own: a test's stdout is the build runner's protocol.
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    catalog_write(fds[1]);
    const kept = local_output;
    defer local_output = kept;
    local_output = fds[1];
    output(.{ .custom = 1 });
    var buffer: [4096]u8 = undefined;
    const size = linux.read(fds[0], &buffer, buffer.len);
    try std.testing.expectEqual(.SUCCESS, linux.errno(size));
    const written = buffer[0..size];
    try std.testing.expect(std.mem.indexOf(u8, written, "\"message\":\"declared in a test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "{\"custom\":1}") != null);
    buggify_pause("anywhere"); // Outside determinismo: no pause.
    try std.testing.expect(random_float() < 1.0);
}
