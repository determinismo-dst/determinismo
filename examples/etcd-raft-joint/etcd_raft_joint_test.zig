// SPDX-License-Identifier: MIT
//! Test program: etcd-io/raft#558, a follower crash during a joint membership change, on
//! etcd-raft-node (node/main.go: go.etcd.io/raft/v3 at 99f9ffb, its log entries and HardState
//! two separate synced writes, entries first, as the library's README prescribes). Five nodes,
//! the initial voters {1,2,3}; nodes 4 and 5 start empty.
//!
//! Profiles: `default` and `async_writes` (raft's AsyncStorageWrites on every node) run the nodes
//! as production does, Go's collector on; `holds` and `async_writes_holds` with it off (GOGC=off,
//! four Ps), for the walks: a thread det-nodes holds keeps its P, and a collection's
//! stop-the-world would wait for it. Off in a hunt, the nodes keep every allocation: the agree
//! checks' requests grew each voter by about 2.5 MB/s, OOM-killed after about 9 minutes of
//! virtual time (17 of 309 timelines of a 6-hour joint_blind run).
//!
//! Scenario `joint_crash` (profile `holds`) walks the issue's triggers, each by a control, with C the leader, F
//! the follower that crashes, O the other old voter:
//!   1. F frozen (a hold armed at its HardState write first); C proposes the joint change
//!      {C,2,3} -> {C,4,5}: C commits the entry entering it (with O, and 4 or 5) and appends the
//!      one leaving it; both append messages queue at F, the second's commit covering the first.
//!   2. F thawed: it writes the two entries, then is held at its HardState write (the new commit
//!      index) and crashed there: back with both configuration entries above its commit.
//!   3. F and O cut off from C, 4 and 5 past an election timeout: F stands in the old
//!      configuration and wins with O's vote.
//!   4. Entries proposed on both sides: F's (old configuration) and C's (the new one, with 4
//!      and 5) at the same indexes.
//! Each step is an `joint_stage` event. The roles and waits are named decisions.
//!
//! Scenario `joint_blind` is the calibration: nothing steers toward the crash point. Faults are
//! drawn as in any hunt (power losses among them: each node's log and HardState files on a disk
//! of its own); a proposer sends entries to whoever leads; a membership driver reads the
//! leader's configuration and, when no change is in flight, swaps one or two voters for nodes
//! outside it in one joint change. Whether exploration reaches the issue's crash (between a
//! follower's entries write and its HardState write, during a joint change) is what it scores.
//!
//! Scenario `async_vote` (profile `async_writes_holds`: every node with raft's AsyncStorageWrites)
//! walks etcd-io/raft#551: a candidate's MsgVote leaves before its term and vote are written.
//! With L the leader, C the candidate and O the other voter:
//!   1. C's append thread held (det-nodes hold at storageAppend), and O's: its vote let go
//!      (written, answered), its next write (C's first entries as leader) kept. C campaigns: L
//!      and O grant, C leads the term, nothing of it on C's disk nor C's entries on O's.
//!   2. An entry x proposed at C reaches L.
//!   3. L frozen (no election of its own), C and O crashed with their writes held: C back at
//!      its old term, O with its vote for C. L thawed, C campaigns again: the same term; O
//!      grants it again (its vote is for C, its log no newer), C leads it a second time.
//!      (Without O's hold both voters held C's first entries and refused it: trial av-data 3.)
//!   4. An entry y proposed at C: at x's index and term in a different log. L keeps x (raft
//!      compares terms only) and applies it once C's commit covers the index; C and O apply y.
//!
//! Properties: replicas agree on the entries they applied (by index: term and digest, the
//! nodes' client API), the issue's state machine safety.
//!
//!   determinismo explore ... --program zig-out/bin/etcd-raft-joint-test --scenario joint_crash --profile holds
//!   determinismo explore ... --program zig-out/bin/etcd-raft-joint-test --scenario joint_blind
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node, n4: sdk.Node, n5: sdk.Node };
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "n1", "n2", "n3", "n4", "n5" };
const peers = "-peers=1=n1:9000,2=n2:9000,3=n3:9000,4=n4:9000,5=n5:9000";
const client_port = 8400;
const leader_attempts_max = 600;
const nodes_binary = "/opt/determinismo/bin/det-nodes";
const hardstate_write = "main.(*node).persistHardState";
const hold_timeout_ms = 20_000;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .joint_crash = joint_crash, .joint_blind = joint_blind, .async_vote = async_vote } });
}

fn describe(d: *System.Describe) !void {
    // `default` first (a run that names none), and `async_writes`: raft's AsyncStorageWrites on
    // every node (etcd-io/raft#551); each also with `_holds`, for the walks (`holds` alone for
    // the default one).
    inline for (.{ "default", "async_writes", "holds", "async_writes_holds" }) |profile_name| {
        const async_writes = comptime std.mem.startsWith(u8, profile_name, "async_writes");
        const holds = comptime std.mem.endsWith(u8, profile_name, "holds");
        const profile = try d.profile(profile_name);
        try describe_nodes(profile, async_writes, holds);
    }
}

fn describe_nodes(profile: anytype, comptime async_writes: bool, comptime holds: bool) !void {
    inline for (node_names, 1..) |name, id| {
        const command_base = [_][]const u8{ "-id=" ++ std.fmt.comptimePrint("{d}", .{id}), peers, "-initial=1,2,3" };
        const command = if (async_writes) command_base ++ [_][]const u8{"-async-writes"} else command_base;
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = "examples/etcd-raft-joint/Dockerfile" },
            .command = &command,
            .ready = .{ .tcp = client_port },
            // A held thread keeps its P (det-nodes hold): four of them, no collector, for the
            // walks only (the header's profiles).
            .env = if (holds) &.{ "GOMAXPROCS=4", "GOGC=off" } else &.{},
            // Power losses: its log and HardState files on a disk of its own.
            .faults = .{ .crash = true },
        });
    }
}

fn joint_crash(s: *System.Scenario) void {
    s.faults = false;
    s.setup("leader", leader_elected);
    s.singleton_driver("walk", walk);
    s.anytime("agree", replicas_agree);
}

fn joint_blind(s: *System.Scenario) void {
    s.setup("leader", leader_elected);
    s.parallel_driver("propose", blind_propose);
    s.serial_driver("membership", blind_membership);
    s.workload("propose");
    s.anytime("agree", replicas_agree);
}

/// A few entries to whoever leads now.
fn blind_propose(context: *System.Context) !void {
    const leader = leader_id(context) catch return sdk.unavailable_pause();
    const count = 1 + sdk.random_below_named("blind.entries", 3);
    for (0..count) |_| propose(context, node_names[leader - 1], "blind");
    sdk.sleep_ms(100 + sdk.random_below_named("blind.propose_ms", 400));
}

/// The leader's configuration (its state): `outgoing` is null outside a joint change (Go's nil
/// slice), so optional (a plain slice failed every parse: run 1447, no change made).
const Configuration = struct { voters: ?[]const u64 = null, outgoing: ?[]const u64 = null };

/// One joint change from the leader's configuration: one or two of its voters swapped for nodes
/// outside it; none while a change is in flight (an outgoing configuration).
fn blind_membership(context: *System.Context) !void {
    const leader = leader_id(context) catch return sdk.unavailable_pause();
    const name = node_names[leader - 1];
    var buffer: [512]u8 = undefined;
    const line = ask(context, name, "{\"op\":\"state\"}\n", &buffer) catch return sdk.unavailable_pause();
    var parse_buffer: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    const configuration = std.json.parseFromSliceLeaky(Configuration, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch return sdk.unavailable_pause();
    const none: []const u64 = &.{};
    const current = configuration.voters orelse none;
    if ((configuration.outgoing orelse none).len > 0 or current.len == 0) {
        sdk.sleep_ms(500 + sdk.random_below_named("blind.in_flight_ms", 1500));
        return;
    }
    var outside: [node_names.len]u64 = undefined;
    var outside_count: usize = 0;
    for (1..node_names.len + 1) |id| {
        if (std.mem.indexOfScalar(u64, current, id) == null) {
            outside[outside_count] = id;
            outside_count += 1;
        }
    }
    const swaps = @min(1 + sdk.random_below_named("blind.swaps", 2), outside_count, current.len - 1);
    if (swaps == 0) return;
    var add: [2]u64 = undefined;
    var remove: [2]u64 = undefined;
    var voters: [node_names.len]u64 = undefined;
    @memcpy(voters[0..current.len], current);
    var voters_left = current.len;
    for (0..swaps) |at| {
        const pick_in = sdk.random_below(@intCast(outside_count));
        add[at] = outside[pick_in];
        outside[pick_in] = outside[outside_count - 1];
        outside_count -= 1;
        const pick_out = sdk.random_below(@intCast(voters_left));
        remove[at] = voters[pick_out];
        voters[pick_out] = voters[voters_left - 1];
        voters_left -= 1;
    }
    var request: [128]u8 = undefined;
    const joint = if (swaps == 1)
        std.fmt.bufPrint(&request, "{{\"op\":\"joint\",\"add\":[{d}],\"remove\":[{d}]}}\n", .{ add[0], remove[0] }) catch unreachable
    else
        std.fmt.bufPrint(&request, "{{\"op\":\"joint\",\"add\":[{d},{d}],\"remove\":[{d},{d}]}}\n", .{ add[0], add[1], remove[0], remove[1] }) catch unreachable;
    var reply: [256]u8 = undefined;
    _ = ask(context, name, joint, &reply) catch return sdk.unavailable_pause();
    sdk.event("blind_change", .{ .leader = name, .swaps = swaps, .add = add[0..swaps], .remove = remove[0..swaps] });
    sdk.sleep_ms(1000 + sdk.random_below_named("blind.change_ms", 3000));
}

fn node_of(context: *System.Context, name: []const u8) *const sdk.Node {
    inline for (node_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return &@field(context.nodes, candidate);
    }
    unreachable;
}

const State = struct { id: u64 = 0, term: u64 = 0, lead: u64 = 0, commit: u64 = 0, applied: u64 = 0, last: u64 = 0 };

fn ask(context: *System.Context, name: []const u8, request: []const u8, buffer: []u8) ![]const u8 {
    return sdk.tcp.request_line(node_of(context, name).address_now(), client_port, request, buffer);
}

fn state_of(context: *System.Context, name: []const u8) State {
    var buffer: [512]u8 = undefined;
    const line = ask(context, name, "{\"op\":\"state\"}\n", &buffer) catch return .{};
    var parse_buffer: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    return std.json.parseFromSliceLeaky(State, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch .{};
}

/// The node an old voter (1-3) says leads.
fn leader_id(context: *System.Context) !u64 {
    for (node_names[0..3]) |name| {
        const state = state_of(context, name);
        if (state.lead != 0 and state.lead == state.id) return state.id;
    }
    return error.NoLeader;
}

fn leader_elected(context: *System.Context) !void {
    _ = try sdk.retry(leader_attempts_max, 100, leader_id, .{context});
}

fn stage(context: *System.Context, name: []const u8, node: []const u8) State {
    const now = state_of(context, node);
    sdk.event("joint_stage", .{ .stage = name, .node = node, .term = now.term, .lead = now.lead, .commit = now.commit, .applied = now.applied, .last = now.last });
    return now;
}

fn propose(context: *System.Context, name: []const u8, tag: []const u8) void {
    var request: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&request, "{{\"op\":\"propose\",\"data\":\"{s}-{d}\"}}\n", .{ tag, sdk.random_below(1 << 30) }) catch return;
    var buffer: [256]u8 = undefined;
    _ = ask(context, name, line, &buffer) catch {};
}

/// det-nodes with `arguments`, waited for.
fn nodes_run(arguments: []const []const u8) void {
    var storage: [8][160]u8 = undefined;
    var argv: [9:null]?[*:0]const u8 = @splat(null);
    argv[0] = nodes_binary;
    for (arguments, 0..) |argument, index| {
        argv[index + 1] = (std.fmt.bufPrintSentinel(&storage[index], "{s}", .{argument}, 0) catch return).ptr;
    }
    const environment = [_:null]?[*:0]const u8{"PATH=/opt/determinismo/bin:/usr/bin:/bin"};
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return;
    if (pid == 0) {
        _ = linux.execve(nodes_binary, &argv, &environment);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
}

fn link(a: []const u8, b: []const u8, state: []const u8) void {
    nodes_run(&.{ "link", a, b, state });
}

/// `det-nodes hold` on a node: one point, its first thread at `function` held until SIGTERM.
const Hold = struct {
    pid: linux.pid_t,
    output: linux.fd_t,
    input: linux.fd_t,

    /// One point: the first thread entering `function` held.
    fn start(node: []const u8, function: []const u8) !Hold {
        return start_for(node, &.{function}, hold_timeout_ms);
    }

    /// `points`: det-nodes hold's arguments after the node (`<function> [--caller <f>]
    /// [--repeat] [--and <function> ...]`).
    fn start_points(node: []const u8, points: []const []const u8) !Hold {
        return start_for(node, points, hold_timeout_ms);
    }

    fn start_for(node: []const u8, points: []const []const u8, timeout_ms: u64) !Hold {
        var timeout: [16]u8 = undefined;
        var arguments: [16][]const u8 = undefined;
        std.debug.assert(points.len + 4 <= arguments.len);
        arguments[0] = "hold";
        arguments[1] = node;
        @memcpy(arguments[2..][0..points.len], points);
        arguments[2 + points.len] = "--timeout-ms";
        arguments[3 + points.len] = try std.fmt.bufPrint(&timeout, "{d}", .{timeout_ms});
        const count = points.len + 4;
        var storage: [16][256]u8 = undefined;
        var argv: [17:null]?[*:0]const u8 = @splat(null);
        argv[0] = nodes_binary;
        for (arguments[0..count], 0..) |argument, index| {
            argv[index + 1] = try std.fmt.bufPrintSentinel(&storage[index], "{s}", .{argument}, 0);
        }
        const environment = [_:null]?[*:0]const u8{"PATH=/opt/determinismo/bin:/usr/bin:/bin"};
        var output: [2]linux.fd_t = .{ -1, -1 };
        var input: [2]linux.fd_t = .{ -1, -1 };
        if (linux.errno(linux.pipe2(&output, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        if (linux.errno(linux.pipe2(&input, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            _ = linux.dup2(output[1], 1);
            _ = linux.dup2(input[0], 0);
            _ = linux.execve(nodes_binary, &argv, &environment);
            linux.exit_group(127);
        }
        _ = linux.close(output[1]);
        _ = linux.close(input[0]);
        return .{ .pid = @intCast(pid), .output = output[0], .input = input[1] };
    }

    fn line(hold: *const Hold, buffer: []u8) []const u8 {
        var size: usize = 0;
        while (size < buffer.len) {
            const result = linux.read(hold.output, buffer[size..].ptr, 1);
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            if (buffer[size] == '\n') break;
            size += 1;
        }
        return buffer[0..size];
    }

    /// Its first line: whether its breakpoints are in (`{"armed":<pid>...}`).
    fn armed(hold: *const Hold) bool {
        var buffer: [256]u8 = undefined;
        return std.mem.startsWith(u8, hold.line(&buffer), "{\"armed\":");
    }

    /// Its lines until point `point` is held (true), or none will be (`{"held":null}`, its end).
    fn held(hold: *const Hold, point: u32) bool {
        var expected: [24]u8 = undefined;
        const suffix = std.fmt.bufPrint(&expected, "\"point\":{d}}}", .{point}) catch unreachable;
        while (true) {
            var buffer: [256]u8 = undefined;
            const said = hold.line(&buffer);
            if (said.len == 0 or std.mem.startsWith(u8, said, "{\"held\":null")) return false;
            if (std.mem.startsWith(u8, said, "{\"held\":") and std.mem.endsWith(u8, said, suffix)) return true;
        }
    }

    /// As `held`, at most `wait_ms` (a point that may never match: its line never comes, and a
    /// hold holding another point does not end at its timeout).
    fn held_within(hold: *const Hold, point: u32, wait_ms: u32) bool {
        var expected: [24]u8 = undefined;
        const suffix = std.fmt.bufPrint(&expected, "\"point\":{d}}}", .{point}) catch unreachable;
        var waited: u32 = 0;
        while (waited < wait_ms) {
            var ready = [1]linux.pollfd{.{ .fd = hold.output, .events = linux.POLL.IN, .revents = 0 }};
            const result = linux.poll(&ready, 1, 100);
            if (linux.errno(result) != .SUCCESS) return false;
            if (result == 0) {
                waited += 100;
                continue;
            }
            var buffer: [256]u8 = undefined;
            const said = hold.line(&buffer);
            if (said.len == 0 or std.mem.startsWith(u8, said, "{\"held\":null")) return false;
            if (std.mem.startsWith(u8, said, "{\"held\":") and std.mem.endsWith(u8, said, suffix)) return true;
        }
        return false;
    }

    /// Lets point `point`'s thread go on, the others held still.
    fn release_point(hold: *const Hold, point: u32) void {
        var command: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&command, "release {d}\n", .{point}) catch unreachable;
        _ = linux.write(hold.input, text.ptr, text.len);
        _ = linux.kill(hold.pid, .USR1);
    }

    /// Lets every held thread go (SIGTERM), and waits for the command's end.
    fn release(hold: *const Hold) void {
        _ = linux.kill(hold.pid, .TERM);
        var status: i32 = 0;
        _ = linux.waitpid(hold.pid, &status, 0);
        _ = linux.close(hold.output);
        _ = linux.close(hold.input);
    }
};

fn walk(context: *System.Context) !void {
    const leader = sdk.retry(leader_attempts_max, 100, leader_id, .{context}) catch return sdk.unavailable_pause();
    sdk.sleep_ms(200 + sdk.random_below_named("joint.settle_ms", 1500));
    const c = node_names[leader - 1];
    var old: [2][]const u8 = undefined;
    var count: usize = 0;
    for (node_names[0..3]) |name| {
        if (std.mem.eql(u8, name, c)) continue;
        old[count] = name;
        count += 1;
    }
    const f = old[sdk.decide("joint.follower", &old)];
    const o = if (std.mem.eql(u8, f, old[0])) old[1] else old[0];
    sdk.event("joint_roles", .{ .leader = c, .follower = f, .other = o });
    // 1. F frozen, its hold armed first; C proposes the joint change {C,2,3} -> {C,4,5}.
    const hold = try Hold.start(f, hardstate_write);
    if (!hold.armed()) {
        hold.release();
        return sdk.unavailable_pause();
    }
    try node_of(context, f).pause();
    var request: [96]u8 = undefined;
    const joint = std.fmt.bufPrint(&request, "{{\"op\":\"joint\",\"add\":[4,5],\"remove\":[{c},{c}]}}\n", .{ f[1], o[1] }) catch unreachable;
    var buffer: [256]u8 = undefined;
    _ = ask(context, c, joint, &buffer) catch {};
    sdk.sleep_ms(500 + sdk.random_below_named("joint.change_ms", 1500));
    const changed = stage(context, "changed", c);
    // 2. F thawed into the two append messages: held at its HardState write, crashed there.
    try node_of(context, f).unpause();
    const held = hold.held(0);
    // The control: half the walks let the held write go on instead of crashing there (the
    // issue's rules then keep it safe): a disagreement in those would be this harness's, not
    // the library's.
    const crash = sdk.decide("joint.crash", &.{ "crash", "no crash" }) == 0;
    if (held and crash) node_of(context, f).crash() catch {};
    hold.release();
    const back = stage(context, "crashed", f);
    sdk.event("joint_crash", .{ .crash = crash, .held = held });
    // Computed, not cataloged: a walk's own control, which joint_blind's timelines never run (run
    // 2114 listed it unreached, its timeline 2299 having the very crash blind).
    sdk.assert_computed(.sometimes, held and crash, "the follower crashed between its entries' write and its HardState's", .{});
    // 3. F and O cut off from C, 4 and 5 past an election timeout.
    for ([_][]const u8{ f, o }) |inside| {
        for ([_][]const u8{ c, "n4", "n5" }) |outside| link(inside, outside, "down");
    }
    sdk.sleep_ms(2500 + sdk.random_below_named("joint.cut_ms", 2500));
    const f_state = stage(context, "cut", f);
    sdk.event("joint_stage", .{ .stage = "f_leads", .node = f, .leads = f_state.lead == f_state.id and f_state.id != 0, .changed_last = changed.last, .back_commit = back.commit });
    // 4. Entries on both sides at the same indexes.
    for (0..3) |_| {
        propose(context, f, "old");
        propose(context, c, "new");
    }
    sdk.sleep_ms(1000 + sdk.random_below_named("joint.after_ms", 1500));
    _ = stage(context, "both", f);
    _ = stage(context, "both", c);
    replicas_agree(context) catch {};
    for ([_][]const u8{ f, o }) |inside| {
        for ([_][]const u8{ c, "n4", "n5" }) |outside| link(inside, outside, "up");
    }
    sdk.sleep_ms(500 + sdk.random_below_named("joint.between_ms", 2000));
}

const Digest = struct { ok: bool = false, term: u64 = 0, digest: u64 = 0 };

fn digest_at(context: *System.Context, name: []const u8, index: u64) ?Digest {
    var request: [64]u8 = undefined;
    const line_request = std.fmt.bufPrint(&request, "{{\"op\":\"digest\",\"index\":{d}}}\n", .{index}) catch return null;
    var buffer: [256]u8 = undefined;
    const line = ask(context, name, line_request, &buffer) catch return null;
    var parse_buffer: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    const d = std.json.parseFromSliceLeaky(Digest, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch return null;
    return if (d.ok) d else null;
}

/// A node's `led` reply: up to thousands of terms in a long timeline.
const led_reply_max = 256 * 1024;
const Led = struct { ok: bool = false, terms: []const u64 = &.{} };

/// The terms `name` led (its file `led`, kept across its crashes), null when it does not answer.
fn led_terms(context: *System.Context, arena: std.mem.Allocator, name: []const u8) ?[]const u64 {
    const buffer = arena.alloc(u8, led_reply_max) catch return null;
    const line = ask(context, name, "{\"op\":\"led\"}\n", buffer) catch return null;
    const led = std.json.parseFromSliceLeaky(Led, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    return if (led.ok) led.terms else null;
}

/// Election safety (Raft §5.2): no two nodes led one term. #558's leader in the old
/// configuration beside the new one's, in one term (run 2114's timeline 2096: n5 and n3 in term
/// 13), shows here even when the two leaders' entries were alike (both their empty no-ops) and
/// replicas agree held. A node that does not answer is left out.
fn one_leader_per_term(context: *System.Context, arena: std.mem.Allocator) void {
    var led: [node_names.len][]const u64 = @splat(&.{});
    for (node_names, &led) |name, *terms| terms.* = led_terms(context, arena, name) orelse &.{};
    var term: u64 = 0;
    var first: []const u8 = "";
    var second: []const u8 = "";
    pairs: for (0..node_names.len) |a| for (a + 1..node_names.len) |b| for (led[a]) |led_term| {
        if (std.mem.indexOfScalar(u64, led[b], led_term) == null) continue;
        term = led_term;
        first = node_names[a];
        second = node_names[b];
        break :pairs;
    };
    sdk.always(term == 0, "at most one leader per term", .{ .term = term, .first = first, .second = second });
}

/// Election safety, then state machine safety: no two nodes applied different entries at one
/// index.
fn replicas_agree(context: *System.Context) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    one_leader_per_term(context, arena_state.allocator());
    var applied: [node_names.len]u64 = undefined;
    for (node_names, &applied) |name, *count| count.* = state_of(context, name).applied;
    for (0..node_names.len) |a| for (a + 1..node_names.len) |b| {
        const top = @min(applied[a], applied[b]);
        var index: u64 = if (top > 32) top - 32 else 1;
        while (index <= top) : (index += 1) {
            const first = digest_at(context, node_names[a], index) orelse continue;
            const second = digest_at(context, node_names[b], index) orelse continue;
            sdk.always(first.term == second.term and first.digest == second.digest, "replicas agree on the entries they applied", .{
                .first = node_names[a],
                .second = node_names[b],
                .index = index,
                .first_term = first.term,
                .second_term = second.term,
            });
        }
    };
}

fn async_vote(s: *System.Scenario) void {
    s.faults = false;
    s.setup("leader", leader_elected);
    s.singleton_driver("walk", walk_async_vote);
    s.anytime("agree", replicas_agree);
}

const storage_append = "main.(*node).storageAppend";

fn campaign(context: *System.Context, name: []const u8) void {
    var buffer: [256]u8 = undefined;
    _ = ask(context, name, "{\"op\":\"campaign\"}\n", &buffer) catch {};
}

/// Polls `name` until it leads a term above `above` (or at `exactly`, when given).
fn leads(context: *System.Context, name: []const u8, above: u64, exactly: ?u64) State {
    var now: State = .{};
    for (0..100) |_| {
        now = state_of(context, name);
        const term_ok = if (exactly) |term| now.term == term else now.term > above;
        if (now.id != 0 and now.lead == now.id and term_ok) return now;
        sdk.sleep_ms(50);
    }
    return now;
}

fn walk_async_vote(context: *System.Context) !void {
    const leader = sdk.retry(leader_attempts_max, 100, leader_id, .{context}) catch return sdk.unavailable_pause();
    sdk.sleep_ms(200 + sdk.random_below_named("async_vote.settle_ms", 1500));
    const l = node_names[leader - 1];
    var others: [2][]const u8 = undefined;
    var count: usize = 0;
    for (node_names[0..3]) |name| {
        if (std.mem.eql(u8, name, l)) continue;
        others[count] = name;
        count += 1;
    }
    const c = others[sdk.decide("async_vote.candidate", &others)];
    const o = if (std.mem.eql(u8, c, others[0])) others[1] else others[0];
    sdk.event("async_vote_roles", .{ .leader = l, .candidate = c, .other = o });
    const before = stage(context, "before", c);
    // 1. C's append thread held (nothing of its campaign will be written), O's too, its first
    // write (its vote for C) let go and the next (C's first entries as leader) kept: O, which
    // C needs (its own vote counts only once written), votes, and holds none of C's term.
    const hold = try Hold.start(c, storage_append);
    if (!hold.armed()) {
        hold.release();
        return sdk.unavailable_pause();
    }
    const o_hold = try Hold.start_points(o, &.{ storage_append, "--repeat" });
    if (!o_hold.armed()) {
        o_hold.release();
        hold.release();
        return sdk.unavailable_pause();
    }
    campaign(context, c);
    const held = hold.held_within(0, 3000);
    const o_vote = o_hold.held_within(0, 3000);
    if (o_vote) o_hold.release_point(0);
    const first = leads(context, c, before.term, null);
    const led = first.lead == first.id and first.term > before.term;
    const o_entries = led and o_hold.held_within(0, 3000);
    sdk.event("async_vote_stage", .{ .stage = "led", .node = c, .held = held, .led = led, .o_vote = o_vote, .o_entries = o_entries, .term = first.term, .last = first.last });
    if (!held or !led or !o_entries) {
        o_hold.release();
        hold.release();
        sdk.sleep_ms(1000);
        return;
    }
    // 2. x at C reaches L (O's write of C's entries held: O never keeps them).
    propose(context, c, "x");
    var l_state: State = .{};
    for (0..40) |_| {
        l_state = state_of(context, l);
        if (l_state.last > first.last) break;
        sdk.sleep_ms(50);
    }
    sdk.event("async_vote_stage", .{ .stage = "x_sent", .node = l, .last = l_state.last, .term = l_state.term, .c_last = first.last });
    // 3. L frozen (no election of its own), C and O crashed with their writes held: C back at
    // its old term, O with its vote for C and none of C's entries. Then L thawed, C campaigns
    // again: the same term; O grants it again (its vote is for C, its log no newer than C's).
    try node_of(context, l).pause();
    node_of(context, c).crash() catch {};
    node_of(context, o).crash() catch {};
    hold.release();
    o_hold.release();
    var back: State = .{};
    for (0..200) |_| {
        back = state_of(context, c);
        const o_back = state_of(context, o);
        if (back.id != 0 and o_back.id != 0) break;
        sdk.sleep_ms(50);
    }
    _ = stage(context, "back", c);
    try node_of(context, l).unpause();
    campaign(context, c);
    const second = leads(context, c, 0, first.term);
    const twice = second.lead == second.id and second.term == first.term;
    sdk.event("async_vote_stage", .{ .stage = "led_again", .node = c, .back_term = back.term, .term = second.term, .twice = twice });
    // Computed, not cataloged: the async_vote walk's, never run in other scenarios.
    sdk.assert_computed(.sometimes, twice, "a candidate led one term twice, its term and vote never written the first time", .{});
    // 4. y at C: at x's index and term, in a different log; L keeps x.
    propose(context, c, "y");
    sdk.sleep_ms(1000 + sdk.random_below_named("async_vote.after_ms", 1500));
    for ([_][]const u8{ c, l, o }) |name| _ = stage(context, "after", name);
    replicas_agree(context) catch {};
    sdk.sleep_ms(500 + sdk.random_below_named("async_vote.between_ms", 2000));
}
