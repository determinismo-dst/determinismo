// SPDX-License-Identifier: MIT
//! Example test program: nREPL, the protocol every Clojure editor speaks, under concurrent clients
//! and faults: nrepl/nrepl 1.8.0 (server/deps.edn, profile default) and jank 0.1's own server
//! (Dockerfile.jank, profile jank, scenario jank: it has no interrupt). Clients talk bencode
//! over TCP (bencode.zig).
//!
//! Properties:
//!   evaluations return their value   `(+ a b)` answers a + b, whatever else runs
//!   a session's *1 is its own        right after `(+ a b)`, `*1` in that session is a + b,
//!                                    while other sessions evaluate concurrently
//!   requests finish                  every request that gets an answer ends with "done", and
//!                                    nothing answers it after (client.zig)
//!   errors are answered              an evaluation that throws answers its error, and its
//!                                    session evaluates on
//!   definitions are shared           a var defined in one session is that value in another,
//!                                    and completes and looks up there; a file loaded in one
//!                                    (`load-file`, as editors send a buffer) is called in another
//!   a session keeps its namespace    after `(in-ns 'x)`, the session's next evaluation is in x
//!   output is its own                what an evaluation prints comes back to it, nothing else
//!   interrupts land                  an interrupted long evaluation ends interrupted (or done)
//!   the server recovers              after faults, a new session evaluates again
//!   a connection serves on after a value fails to print
//!                                    after faults, a value whose printing throws is answered as
//!                                    an error and the connection answers its next request
//!   an evaluation in a namespace that does not exist is refused
//!                                    after faults, an eval naming a missing `ns` gets no value
//!                                    (nREPL: the namespace "must exist already")
//!
//! And proof (github.com/nrepl/proof, Dockerfile.proof), nREPL's compatibility suite, run from a
//! node of its own: whole once on the fresh server in the setup (its verdicts the baseline), by
//! drawn groups of checks as drivers beside the others while faults land, and whole again once
//! faults stop:
//!   proof's wire checks hold under faults      what the server sends is well-formed whatever
//!                                               happens (wire.*: a message's status, payload,
//!                                               session, nothing after an error); a frame cut
//!                                               off (wire.bencode) is what a killed server leaves,
//!                                               an event
//!   a check proof passed on the fresh server   once faults stop, after the drivers' load and
//!   passes once faults stop                    the faults, every check the fresh server passed
//!                                               passes (its known failures are in the baseline)
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const nrepl = @import("nrepl");
const Client = nrepl.Client;

const Nodes = struct { nrepl: sdk.Node, proof: sdk.Node };
const System = sdk.System(Nodes);

const port = 7888;
const evaluations_per_driver = 12;
const recovery_attempts_max = 120;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .sessions = sessions, .jank = jank, .basic = basic },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile" },
        .ready = .{ .tcp = port },
    });
    const jank_server = try d.profile("jank");
    jank_server.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.jank" },
        .ready = .{ .tcp = port },
    });
    const babashka = try d.profile("babashka");
    babashka.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.babashka" },
        .ready = .{ .tcp = port },
    });
    // nREPL with cider-nrepl's middleware, as CIDER and Calva start it (its load adds to the start).
    const cider = try d.profile("cider");
    cider.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.cider" },
        .ready = .{ .tcp = port, .timeout_s = 240 },
    });
    const nbb = try d.profile("nbb");
    nbb.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.nbb" },
        .ready = .{ .tcp = port },
    });
    // nbb's main branch (60e141d, built from source): its nREPL fixes after 1.6.214, unreleased.
    const nbb_main = try d.profile("nbb-main");
    nbb_main.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.nbb-main" },
        .ready = .{ .tcp = port },
    });
    // Basilisp compiles its core at start: 33 s natively on srv4's cores.
    const basilisp = try d.profile("basilisp");
    basilisp.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.basilisp" },
        .ready = .{ .tcp = port, .timeout_s = 240 },
    });
    // A client's node: its links cut and partitioned (proof's connections then fail as an
    // editor's would), never paused or powered off (its own timeouts would then judge it).
    for ([_]*System.Profile{ default, jank_server, babashka, cider, nbb, nbb_main, basilisp }) |profile| {
        profile.node(.proof, .{
            .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.proof" },
            .faults = .{ .pause = false, .outage = false, .sync_stall = false, .partial_persistence = false },
        });
    }
}

fn sessions(s: *System.Scenario) void {
    shared(s);
    s.parallel_driver("interrupt", interrupt_one);
    s.parallel_driver("queue", queue_one);
    s.parallel_driver("leave", leave_one);
}

fn jank(s: *System.Scenario) void {
    shared(s);
}

/// The servers without an interrupt op (nbb, Basilisp; jank's scenario by its first name).
fn basic(s: *System.Scenario) void {
    shared(s);
}

/// What every nREPL server does (jank's has no interrupt), and proof.
fn shared(s: *System.Scenario) void {
    s.setup("proof baseline", proof.baseline);
    s.parallel_driver("proof", proof.checks);
    s.finally("proof after faults", proof.after);
    // Faults in bursts with quiet stretches: continuous, the runner's link to the server was cut
    // or lossy nearly all the time (trial run 1236: 163 partitions and 291 degraded links in 120 s,
    // 2,568 connections failed, one failing form drawn in a whole timeline).
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 20_000 };
    s.parallel_driver("evaluate", evaluate_many);
    s.parallel_driver("fail", fail_one);
    s.parallel_driver("define", define_one);
    s.parallel_driver("load", load_one);
    s.parallel_driver("namespace", namespace_one);
    s.parallel_driver("print", print_one);
    s.eventually("recovers", recovers);
}

fn evaluate_many(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    for (0..evaluations_per_driver) |_| {
        evaluate_once(&client, context.profile) catch |err| return unavailable(err);
    }
}

/// An operand: small and positive, signed, or large (up to 2^62 either way: a sum of two still
/// fits a long), by stretches (sdk.swarm_index; the determinismo-review-inputs pass, 2026-11-08:
/// always below a million, no sign or long's digits through the protocol's value strings). On a
/// JavaScript host (nbb) numbers are doubles: large is up to 2^51, a sum still a safe integer
/// (hunt run 1634: 74 timelines failed on sums past 2^53, rounded as JavaScript does).
fn operand_draw(profile: []const u8) i64 {
    const large_bits: u6 = if (js_host(profile)) 52 else 63;
    const large: i64 = @intCast(sdk.random_below(@as(u64, 1) << large_bits));
    return switch (sdk.swarm_index("nrepl.operand", 3)) {
        0 => @intCast(sdk.random_below(1_000_000)),
        1 => @as(i64, @intCast(sdk.random_below(2_000_000))) - 1_000_000,
        else => large - (@as(i64, 1) << (large_bits - 1)),
    };
}

/// ClojureScript on Node.js: numbers are doubles, and arithmetic on a keyword or by zero answers
/// a value (a string, NaN, Infinity), not an error.
fn js_host(profile: []const u8) bool {
    return std.mem.eql(u8, profile, "nbb") or std.mem.eql(u8, profile, "nbb-main");
}

fn evaluate_once(client: *Client, profile: []const u8) !void {
    const a = operand_draw(profile);
    const b = operand_draw(profile);
    var code_buffer: [64]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "(+ {d} {d})", .{ a, b });
    const sum = try client.call(&.{ .{ "op", "eval" }, .{ "code", code } });
    sdk.always(sum.done, "requests finish", .{});
    const value = std.fmt.parseInt(i64, sum.value orelse "", 10) catch std.math.maxInt(i64);
    sdk.always(value == a + b, "evaluations return their value", .{ .a = a, .b = b, .value = sum.value orelse "" });
    const last = try client.call(&.{ .{ "op", "eval" }, .{ "code", "*1" } });
    const remembered = std.fmt.parseInt(i64, last.value orelse "", 10) catch std.math.maxInt(i64);
    sdk.always(remembered == a + b, "a session's *1 is its own", .{
        .expected = a + b,
        .got = last.value orelse "",
    });
    sdk.sometimes(true, "an evaluation completed", .{});
}

/// Forms that throw in Clojure, each its own way: unresolved, thrown, out of range, of the wrong
/// type, unread, divided by zero, deep. The last two kill jank 0.1's whole server (README.md):
/// in every timeline they would end it, so half of jank's timelines leave them out (drawn once a
/// timeline, `jank_crashers`), never all: until 2026-11-06 all did, which hid the crash.
const failing = [_][]const u8{
    "undefined-here",
    "(throw (ex-info \"thrown\" {:n 1}))",
    "(nth [1 2] 5)",
    "(+ 1 :a)",
    "(first 1)",
    "(+ 1 2",
    "(quot 1 0)",
    "(/ 1 0)",
    "((fn deep [n] (if (zero? n) 0 (inc (deep (dec n))))) 10000000)",
};
const failing_jank = failing[0 .. failing.len - 2];
/// ClojureScript's: `(+ 1 :a)` is "1:a", `(quot 1 0)` NaN, `(/ 1 0)` Infinity (hunt run 1634: 85
/// timelines failed on them, ##NaN answered).
const failing_js = [_][]const u8{
    "undefined-here",
    "(throw (ex-info \"thrown\" {:n 1}))",
    "(nth [1 2] 5)",
    "(first 1)",
    "(+ 1 2",
    "((fn deep [n] (if (zero? n) 0 (inc (deep (dec n))))) 10000000)",
};

/// This timeline's draw (a file in the runner, drawn at the first call): whether jank meets the
/// forms that kill its server.
fn jank_crashers() bool {
    const path = "/tmp/nrepl-jank-crashers";
    var buffer: [1]u8 = undefined;
    const existing = std.os.linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(existing) == .SUCCESS) {
        defer _ = std.os.linux.close(@intCast(existing));
        const size = std.os.linux.read(@intCast(existing), &buffer, 1);
        return std.os.linux.errno(size) == .SUCCESS and size == 1 and buffer[0] == '1';
    }
    const drawn = sdk.random_below_named("nrepl.jank_crashers", 2) == 0;
    sdk.event("nrepl_jank_crashers", .{ .drawn = drawn });
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const fd = std.os.linux.open(path, flags, 0o644);
    switch (std.os.linux.errno(fd)) {
        .SUCCESS => {},
        .EXIST => return jank_crashers(), // Another driver's draw won.
        else => return drawn,
    }
    defer _ = std.os.linux.close(@intCast(fd));
    _ = std.os.linux.write(@intCast(fd), if (drawn) "1" else "0", 1);
    return drawn;
}

/// An evaluation that throws: its error answered, then its session evaluates on.
fn fail_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    const forms: []const []const u8 = if (js_host(context.profile))
        &failing_js
    else if (std.mem.eql(u8, context.profile, "jank") and !jank_crashers())
        failing_jank
    else
        &failing;
    const form = forms[sdk.random_below_named("fail.form", forms.len)];
    const failed = client.eval(form) catch |err| return unavailable(err);
    sdk.always(failed.done, "requests finish", .{});
    sdk.always(failed.value == null and (failed.eval_error or failed.err.len > 0 or failed.ex != null), "errors are answered", .{
        .form = form,
        .value = failed.value orelse "",
    });
    evaluate_once(&client, context.profile) catch |err| return unavailable(err);
    sdk.sometimes(true, "a session evaluated on after an error", .{ .form = form });
}

/// A var defined in one session, a value or a function returning it (compiled while other
/// sessions call the ones before: jank's JIT on their threads): another session reads its value,
/// completes and looks it up.
fn define_one(context: *System.Context) !void {
    var definer = Client.init();
    definer.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer definer.close();
    var reader = Client.init();
    reader.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer reader.close();
    const n = sdk.random_below(1_000_000);
    const function = sdk.random_below_named("define.function", 2) == 1;
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "shared-{s}{d}", .{
        if (function) "fn-" else "",
        sdk.random_below(64),
    });
    var code_buffer: [96]u8 = undefined;
    const code = if (function)
        try std.fmt.bufPrint(&code_buffer, "(defn {s} [] {d})", .{ name, n })
    else
        try std.fmt.bufPrint(&code_buffer, "(def {s} {d})", .{ name, n });
    const defined = definer.eval(code) catch |err| return unavailable(err);
    sdk.always(defined.done, "requests finish", .{});
    if (defined.value == null) return; // Defined concurrently with another of its name: either.
    var call_buffer: [48]u8 = undefined;
    const call = if (function) try std.fmt.bufPrint(&call_buffer, "({s})", .{name}) else name;
    const read = reader.eval(call) catch |err| return unavailable(err);
    const value = std.fmt.parseInt(u64, read.value orelse "", 10) catch std.math.maxInt(u64);
    // Another driver may define the same name between the two: then a number all the same.
    sdk.always(value != std.math.maxInt(u64), "definitions are shared", .{
        .name = name,
        .defined = n,
        .read = read.value orelse "",
    });
    sdk.sometimes(value == n, "a definition was read in another session", .{ .function = function });
    // In the namespace the definition went to, as editors name it from the eval's answer
    // (jank's server knows no namespace without: README.md).
    const ns = defined.ns orelse "user";
    // Through the ops the server offers, as editors pick them from `describe` (CIDER's
    // op-supported-p): nREPL's own completions and lookup, or cider-nrepl's complete and info,
    // which Basilisp 0.5.1 serves alone (unknown-op for the others: hunt runs 1611 and 1635
    // failed both properties in every timeline that asked).
    const offered = ops_offered(&reader) catch |err| return unavailable(err);
    const complete_op = offered.completion orelse {
        sdk.event("nrepl_no_completion_op", .{});
        return;
    };
    const completions = reader.call(&.{ .{ "op", complete_op }, .{ "prefix", name }, .{ "ns", ns } }) catch |err|
        return unavailable(err);
    sdk.always(completions.done and completions_have(completions.last, name), "a definition completes in another session", .{
        .name = name,
        .ns = ns,
        .op = complete_op,
    });
    const lookup_op = offered.lookup orelse {
        sdk.event("nrepl_no_lookup_op", .{});
        return;
    };
    const lookup = reader.call(&.{ .{ "op", lookup_op }, .{ "sym", name }, .{ "ns", ns } }) catch |err|
        return unavailable(err);
    // lookup's answer holds an `info` map; cider-nrepl's info answers with its fields.
    const info = if (std.mem.eql(u8, lookup_op, "lookup")) lookup.last.get("info") else lookup.last;
    sdk.always(lookup.done and info != null and info.?.string("name") != null, "a definition looks up in another session", .{
        .name = name,
        .ns = ns,
        .op = lookup_op,
    });
}

/// The completion and lookup ops a server offers (its `describe`): nREPL's own first, then
/// cider-nrepl's names; null when it offers neither.
const Offered = struct { completion: ?[]const u8, lookup: ?[]const u8 };

fn ops_offered(client: *Client) !Offered {
    const described = try client.call(&.{.{ "op", "describe" }});
    const ops = described.last.get("ops");
    return .{
        .completion = op_first(ops, &.{ "completions", "complete" }),
        .lookup = op_first(ops, &.{ "lookup", "info" }),
    };
}

fn op_first(ops: ?nrepl.bencode.Value, names: []const []const u8) ?[]const u8 {
    const offered = ops orelse return null;
    for (names) |name| if (offered.get(name) != null) return name;
    return null;
}

/// A file loaded in one session (`load-file`: its namespace and a function), the function called
/// in another.
fn load_one(context: *System.Context) !void {
    var loader = Client.init();
    loader.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer loader.close();
    var caller = Client.init();
    caller.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer caller.close();
    const k = sdk.random_below(64);
    const n = sdk.random_below(1_000_000);
    var file_buffer: [96]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "(ns loaded-{d}) (defn f [] {d})", .{ k, n });
    var path_buffer: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "loaded_{d}.clj", .{k});
    const loaded = loader.call(&.{
        .{ "op", "load-file" }, .{ "file", file }, .{ "file-path", path }, .{ "file-name", path },
    }) catch |err| return unavailable(err);
    sdk.always(loaded.done, "requests finish", .{});
    if (loaded.value == null) return; // Loaded concurrently with another of its name: either.
    var call_buffer: [32]u8 = undefined;
    const called = caller.eval(try std.fmt.bufPrint(&call_buffer, "(loaded-{d}/f)", .{k})) catch |err|
        return unavailable(err);
    const value = std.fmt.parseInt(u64, called.value orelse "", 10) catch std.math.maxInt(u64);
    // Another driver may load the same namespace between the two: then a number all the same.
    sdk.always(value != std.math.maxInt(u64), "definitions are shared", .{
        .file = file,
        .read = called.value orelse "",
    });
    sdk.sometimes(value == n, "a loaded file's function was called in another session", .{});
}

/// A session that moved to another namespace evaluates there next (nREPL's sessions keep their
/// *ns*, as *1).
fn namespace_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "session-{d}", .{sdk.random_below(64)});
    var code_buffer: [64]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "(in-ns '{s})", .{name});
    const moved = client.eval(code) catch |err| return unavailable(err);
    sdk.always(moved.done, "requests finish", .{});
    const next = client.eval("1") catch |err| return unavailable(err);
    sdk.always(std.mem.eql(u8, next.ns orelse "", name), "a session keeps its namespace", .{
        .name = name,
        .ns = next.ns orelse "",
    });
}

/// An evaluation's output comes back to it, all of it and no other's, while others print too
/// (jank's server captures it by pointing the process's stdout at a file of the evaluation's
/// own while it runs).
fn print_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    const mark = sdk.random_below(1 << 40);
    var code_buffer: [128]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "(do (println \"mark-{d}\") (reduce + (range 20000)) " ++
        "(println \"mark-{d}\") nil)", .{ mark, mark });
    const printed = client.eval(code) catch |err| return unavailable(err);
    sdk.always(printed.done, "requests finish", .{});
    var own_buffer: [32]u8 = undefined;
    const own = try std.fmt.bufPrint(&own_buffer, "mark-{d}\n", .{mark});
    sdk.always(std.mem.count(u8, printed.out, own) == 2 and std.mem.count(u8, printed.out, "mark-") == 2, "an evaluation's output is its own", .{
        .mark = mark,
        .out = printed.out[0..@min(printed.out.len, 160)],
    });
}

/// Whether a `completions` reply lists `name` as a candidate.
fn completions_have(reply: nrepl.bencode.Value, name: []const u8) bool {
    const candidates = reply.get("completions") orelse return false;
    if (candidates != .list) return false;
    for (candidates.list) |candidate| {
        const text = candidate.string("candidate") orelse continue;
        if (std.mem.endsWith(u8, text, name)) return true;
    }
    return false;
}

/// A long evaluation, interrupted a random moment later.
fn interrupt_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    const long = "(do (Thread/sleep 3000) :slept)";
    const id = client.send(&.{ .{ "op", "eval" }, .{ "code", long } }) catch |err|
        return unavailable(err);
    sdk.sleep_ms(sdk.random_below_named("interrupt.after_ms", 2000));
    _ = client.send(&.{ .{ "op", "interrupt" }, .{ "interrupt-id", id } }) catch |err|
        return unavailable(err);
    const reply = client.collect(id) catch |err| return unavailable(err);
    sdk.always(reply.done, "requests finish", .{});
    sdk.sometimes(reply.interrupted, "interrupts land", .{});
    sdk.sometimes(!reply.interrupted, "an evaluation finished before its interrupt", .{});
}

/// Evaluations queued in one session behind a long one, which is interrupted from this
/// connection or (drawn) from another taking up the session: each queued one is answered with
/// its value (nREPL #503 dropped them), the interrupted one's done comes to its own connection
/// (#498 sent it to the interrupter's), and the other connection is answered nothing of this
/// one's. A done missing while the connection still answers is the server's drop, not a fault
/// (Client.dropped).
fn queue_one(context: *System.Context) !void {
    const address = context.nodes.nrepl.address;
    var client = Client.init();
    client.open(address, port) catch |err| return unavailable(err);
    defer client.close();
    var ids: [4][]const u8 = undefined;
    var replies: [4]nrepl.Reply = @splat(.{});
    ids[0] = client.send(&.{ .{ "op", "eval" }, .{ "code", "(do (Thread/sleep 3000) :slept)" } }) catch |err|
        return unavailable(err);
    const count = 2 + sdk.random_below_named("queue.queued", 3);
    var codes: [4][16]u8 = undefined;
    for (1..count) |k| {
        const code = std.fmt.bufPrint(&codes[k], "(+ {d} 100)", .{k}) catch unreachable;
        ids[k] = client.send(&.{ .{ "op", "eval" }, .{ "code", code } }) catch |err| return unavailable(err);
    }
    sdk.sleep_ms(sdk.random_below_named("queue.interrupt_after_ms", 2000));
    const elsewhere = sdk.random_below_named("queue.interrupt_elsewhere", 2) == 1;
    var other = Client.init();
    other.next_id = 1000;
    defer other.close();
    var interrupt_id: []const u8 = "";
    if (elsewhere) {
        other.open_session(address, port, client.session) catch |err| return unavailable(err);
        interrupt_id = other.send(&.{ .{ "op", "interrupt" }, .{ "interrupt-id", ids[0] } }) catch |err|
            return unavailable(err);
    } else {
        _ = client.send(&.{ .{ "op", "interrupt" }, .{ "interrupt-id", ids[0] } }) catch |err|
            return unavailable(err);
    }
    var strays: u32 = 0;
    if (!try answered(&client, ids[0..count], replies[0..count], &strays)) return;
    sdk.always(replies[0].done, "an interrupted evaluation's done comes to its own connection", .{ .elsewhere = elsewhere });
    for (1..count) |k| {
        sdk.always(replies[k].done, "every evaluation queued behind an interrupted one is answered", .{ .position = k });
        if (!replies[k].done) continue;
        var expected: [8]u8 = undefined;
        sdk.always(std.mem.eql(u8, replies[k].value orelse "", std.fmt.bufPrint(&expected, "{d}", .{k + 100}) catch unreachable), "evaluations return their value", .{ .value = replies[k].value orelse "" });
    }
    sdk.sometimes(replies[0].interrupted, "an evaluation with others queued behind it is interrupted", .{ .elsewhere = elsewhere });
    if (elsewhere) {
        var interrupt_reply: [1]nrepl.Reply = .{.{}};
        var other_strays: u32 = 0;
        if (!try answered(&other, &.{interrupt_id}, &interrupt_reply, &other_strays)) return;
        sdk.always(other_strays == 0, "a connection is answered nothing of another's requests", .{ .strays = other_strays });
        sdk.sometimes(true, "an evaluation was interrupted from another connection", .{});
    }
}

/// A client that leaves in the middle of an evaluation; another takes up its session, interrupts
/// what runs there or not (drawn), and evaluates in it: answered (with its value, or, where the
/// session ended with its connection, unknown-session). nREPL 1.8.0 never answers it when the
/// left evaluation was still running (trial run 1599, reproduced natively: the left evaluation's
/// reply fails on the closed connection, the session restarts, the queue is dropped); #509 leaks a
/// thread when it is interrupted.
fn leave_one(context: *System.Context) !void {
    const address = context.nodes.nrepl.address;
    var session_buffer: [64]u8 = undefined;
    var first = Client.init();
    defer first.leave();
    first.open(address, port) catch |err| return unavailable(err);
    const session_len = @min(first.session.len, session_buffer.len);
    @memcpy(session_buffer[0..session_len], first.session[0..session_len]);
    const left = first.send(&.{ .{ "op", "eval" }, .{ "code", "(do (Thread/sleep 3000) :slept)" } }) catch |err|
        return unavailable(err);
    var left_buffer: [16]u8 = undefined;
    const left_id = left_buffer[0..left.len];
    @memcpy(left_id, left);
    sdk.sleep_ms(sdk.random_below_named("leave.after_ms", 1500));
    first.leave();
    var second = Client.init();
    second.next_id = 1000;
    defer second.close();
    second.open_session(address, port, session_buffer[0..session_len]) catch |err| return unavailable(err);
    var ids: [2][]const u8 = undefined;
    var replies: [2]nrepl.Reply = @splat(.{});
    var count: usize = 0;
    const interrupt = sdk.random_below_named("leave.interrupt", 2) == 1;
    if (interrupt) {
        ids[count] = second.send(&.{ .{ "op", "interrupt" }, .{ "interrupt-id", left_id } }) catch |err|
            return unavailable(err);
        count += 1;
    }
    ids[count] = second.send(&.{ .{ "op", "eval" }, .{ "code", "(+ 20 22)" } }) catch |err| return unavailable(err);
    count += 1;
    var strays: u32 = 0;
    if (!try answered(&second, ids[0..count], replies[0..count], &strays)) return;
    const evaluation = replies[count - 1];
    sdk.always(evaluation.done, "a request in a session whose client left mid-evaluation is answered", .{ .interrupted = interrupt });
    if (!evaluation.done) return;
    // nREPL after #512 (master, 2026-11-05) ends a session with its connection: the request is
    // answered unknown-session. 1.8.0 keeps the session, and evaluates in it.
    if (evaluation.last.status_has("unknown-session")) {
        sdk.assert_computed(.sometimes, true, "a session ended with its client's connection", .{});
        return;
    }
    sdk.always(std.mem.eql(u8, evaluation.value orelse "", "42"), "evaluations return their value", .{ .value = evaluation.value orelse "" });
    sdk.sometimes(true, "a session was taken up after its client left mid-evaluation", .{ .interrupted = interrupt });
}

/// Collects `ids`' replies on `client`: true when judged (every done came, or the server is
/// shown to have dropped some: the slots without done), false when a fault kept it from knowing.
fn answered(client: *Client, ids: []const []const u8, replies: []nrepl.Reply, strays: *u32) !bool {
    client.collect_all(ids, replies, strays) catch |err| {
        if (!nrepl.unavailable(err)) return err;
        const dropped = client.dropped(ids, replies, strays) catch |probe_err| {
            try unavailable(probe_err);
            return false;
        };
        if (!dropped) return true;
        sdk.sometimes(true, "a request's done never came while its connection answered", .{});
        return true;
    };
    return true;
}

/// Faults are over: a new session evaluates again.
fn recovers(context: *System.Context) !void {
    sdk.retry(recovery_attempts_max, 250, evaluates, .{context.nodes.nrepl.address}) catch |err| {
        sdk.assert_unreachable("the server never evaluates again", .{ .err = @errorName(err) });
        return err;
    };
    // With the faults over and the server evaluating, a request that gets no reply is the
    // server's doing, not the network's.
    try print_error_serves_on(context.nodes.nrepl.address);
    try missing_namespace_refused(context.nodes.nrepl.address);
}

/// A value whose printing throws (a lazy sequence realized as the server prints it) is answered
/// as an error, and the same connection then answers its next request.
fn print_error_serves_on(address: [4]u8) !void {
    var client = Client.init();
    client.timeout_ms = 30_000;
    try client.open(address, port);
    defer client.close();
    const form = "(map (fn [_] (throw (ex-info \"print\" {}))) [1])";
    const failed = client.eval(form) catch |err| {
        sdk.always(false, "a connection serves on after a value fails to print", .{ .err = @errorName(err), .request = "the failing value" });
        return;
    };
    sdk.always(failed.value == null and (failed.eval_error or failed.err.len > 0 or failed.ex != null), "errors are answered", .{
        .form = form,
        .value = failed.value orelse "",
    });
    const next = client.eval("(+ 1 1)") catch |err| {
        sdk.always(false, "a connection serves on after a value fails to print", .{ .err = @errorName(err), .request = "the next" });
        return;
    };
    sdk.always(std.mem.eql(u8, next.value orelse "", "2"), "a connection serves on after a value fails to print", .{
        .err = "",
        .request = next.value orelse "",
    });
}

/// An evaluation naming a namespace that does not exist is refused, not run in another (nREPL's
/// eval: the supplied namespace must exist already; the reference server answers
/// namespace-not-found).
fn missing_namespace_refused(address: [4]u8) !void {
    var client = Client.init();
    try client.open(address, port);
    defer client.close();
    var ns_buffer: [48]u8 = undefined;
    const ns = try std.fmt.bufPrint(&ns_buffer, "determinismo-missing-{d}", .{sdk.random_below(1 << 30)});
    const reply = try client.call(&.{ .{ "op", "eval" }, .{ "code", "(str *ns*)" }, .{ "ns", ns } });
    sdk.always(reply.done, "requests finish", .{});
    sdk.always(reply.value == null, "an evaluation in a namespace that does not exist is refused", .{
        .ns = ns,
        .value = reply.value orelse "",
    });
}

fn evaluates(address: [4]u8) !void {
    var client = Client.init();
    try client.open(address, port);
    defer client.close();
    const reply = try client.call(&.{ .{ "op", "eval" }, .{ "code", "(+ 1 1)" } });
    if (!std.mem.eql(u8, reply.value orelse "", "2")) return error.WrongValue;
}

/// proof's runs against the server, from its node, with its built-in profile for the server
/// (the snippets it evaluates, what the server can do), by the run's profile.
const proof = struct {
    /// Every check but robust.*, whose malformed requests kill some servers (nbb's: "Vector's key
    /// for assoc must be a number", uncaught, in the setup's baseline: hunt run 1608's 284
    /// timelines all began with the server dead). path.Match's globs (proof's -only): what begins
    /// with r but reply.*, and reply.*. robust.* stays among the drivers' groups, drawn.
    const safe_patterns = [_][]const u8{ "[^r]*", "reply.*" };
    const baseline_paths = [_][]const u8{ "/var/lib/proof/baseline-0.json", "/var/lib/proof/baseline-1.json" };

    /// On the fresh server, before the timelines part: every check's verdict (but robust's),
    /// kept in the node's disk (every timeline starts from it).
    fn baseline(context: *System.Context) !void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        var checks_count: usize = 0;
        for (safe_patterns, baseline_paths) |pattern, path| {
            const report = run(context, arena_state.allocator(), pattern, path) catch |err| {
                sdk.event("proof_baseline_unread", .{ .err = @errorName(err) });
                return;
            };
            checks_count += report.len;
        }
        sdk.sometimes(checks_count > 0, "proof judged the fresh server", .{ .checks = checks_count });
    }

    /// A drawn group of checks (or all of them), beside the other drivers and under faults:
    /// the wire checks judged, the others' failures noted.
    fn checks(context: *System.Context) !void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const only = groups[sdk.swarm_index("proof.group", groups.len)];
        const report = run(context, arena_state.allocator(), only, "") catch return;
        for (report) |result| {
            const failed = std.mem.eql(u8, result.verdict, "fail");
            if (std.mem.startsWith(u8, result.id, "wire.") and !std.mem.eql(u8, result.id, "wire.bencode")) {
                sdk.always(!failed, "proof's wire checks hold under faults", .{
                    .check = result.id,
                    .details = details_first(result),
                });
            } else if (failed) {
                sdk.event("proof_failed", .{ .check = result.id, .details = details_first(result) });
            }
        }
        sdk.sometimes(report.len > 0, "proof ran checks under faults", .{ .only = only });
    }

    /// Once faults stop: the baseline's checks again, each the fresh server passed passing still.
    fn after(context: *System.Context) !void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fresh: std.ArrayList(Result) = .empty;
        var now: std.ArrayList(Result) = .empty;
        for (safe_patterns, baseline_paths) |pattern, path| {
            const before = report_read(context, arena, path) catch |err| {
                sdk.event("proof_baseline_unread", .{ .err = @errorName(err) });
                return;
            };
            try fresh.appendSlice(arena, before);
            const results = run(context, arena, pattern, "") catch |err| {
                sdk.event("proof_after_unread", .{ .err = @errorName(err) });
                return;
            };
            try now.appendSlice(arena, results);
        }
        var compared: u32 = 0;
        for (fresh.items) |before| {
            if (!std.mem.eql(u8, before.verdict, "pass")) continue;
            for (now.items) |result| {
                if (!std.mem.eql(u8, result.id, before.id)) continue;
                compared += 1;
                sdk.always(!std.mem.eql(u8, result.verdict, "fail"), "a check proof passed on the fresh server passes once faults stop", .{
                    .check = result.id,
                    .details = details_first(result),
                });
            }
        }
        sdk.sometimes(compared > 0, "proof compared the server once faults stop with the fresh one", .{ .compared = compared });
    }

    /// `proof run` against the server (the checks matching `only`, all when empty), its JSON
    /// report read back: kept at `keep` in proof's node when named, else at a drawn path
    /// removed after (drivers run proof side by side).
    fn run(context: *System.Context, arena: std.mem.Allocator, only: []const u8, keep: []const u8) ![]const Result {
        const path = if (keep.len > 0) keep else try std.fmt.allocPrint(arena, "/tmp/proof-{d}.json", .{sdk.random_below(1 << 40)});
        const address = context.nodes.nrepl.address;
        const command = try std.fmt.allocPrint(arena, "proof run -address {d}.{d}.{d}.{d}:{d} -json {s}{s}{s}{s} {s} " ++
            ">/dev/null 2>&1; cat {s}{s}", .{
            address[0],                           address[1], address[2],                    address[3],                     port, path,
            if (only.len > 0) " -only '" else "", only,       if (only.len > 0) "'" else "", proof_profile(context.profile), path, if (keep.len > 0) "" else try std.fmt.allocPrint(arena, "; rm -f {s}", .{path}),
        });
        return report_parse(context, arena, &.{ "sh", "-c", command });
    }

    fn report_read(context: *System.Context, arena: std.mem.Allocator, path: []const u8) ![]const Result {
        return report_parse(context, arena, &.{ "cat", path });
    }

    fn report_parse(context: *System.Context, arena: std.mem.Allocator, argv: []const []const u8) ![]const Result {
        const buffer = try arena.alloc(u8, 1 << 20);
        const output = try context.nodes.proof.exec_output(argv, buffer);
        if (output.output.len == 0) return error.ReportMissing;
        const report = try std.json.parseFromSliceLeaky(Report, arena, output.output, .{ .ignore_unknown_fields = true });
        return report.results;
    }
};

/// proof's profile for the server of the run's profile.
fn proof_profile(profile: []const u8) []const u8 {
    if (std.mem.eql(u8, profile, "jank")) return "jank";
    if (std.mem.eql(u8, profile, "babashka")) return "babashka";
    if (std.mem.eql(u8, profile, "nbb") or std.mem.eql(u8, profile, "nbb-main")) return "nbb";
    if (std.mem.eql(u8, profile, "basilisp")) return "basilisp";
    return "clojure";
}

/// The groups of proof's checks a driver runs (`-only`), one of them all.
const groups = [_][]const u8{ "", "eval.*", "session.*", "interrupt.*", "robust.*", "stdin.*", "cider.*", "describe.*" };

/// proof's JSON report (`-json`): a verdict a check (pass, warn, fail, skip, error).
const Report = struct { results: []const Result };
const Result = struct { id: []const u8, verdict: []const u8, details: []const []const u8 = &.{} };

fn details_first(result: Result) []const u8 {
    if (result.details.len == 0) return "";
    return result.details[0][0..@min(result.details[0].len, 300)];
}

fn unavailable(err: anyerror) !void {
    if (!nrepl.unavailable(err)) return err;
    sdk.sometimes(true, "the server was unavailable to a client", .{ .err = @errorName(err) });
}
