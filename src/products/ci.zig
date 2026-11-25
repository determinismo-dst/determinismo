// SPDX-License-Identifier: MIT
//! determinismo-ci [--config .determinismo/ci.json] [--serve <url>] [--cache <dir>]
//! [--flaky-passes]: a repository's tests run on determinismo (docs/CI.md), from the
//! repository's directory on the host (a GitHub Action reaches it over SSH). A product on
//! determinismo, not part of it (docs/PRODUCTS.md): everything here goes through serve's API.
//!
//! - The setup, once a key: a machine (POST /machines: a fast VM, several cores, real time) runs
//!   the config's setup and lists the tests, then is checkpointed and stopped. Its checkpoint and
//!   test list are cached under the key: the config's setup fields (not its shards or run
//!   command), the system's file and every key file's contents hashed. The next job with the
//!   same key starts from that checkpoint.
//! - The shards: the tests dealt round, each shard a run of held timelines from the checkpoint
//!   (POST /runs {checkpoint, checkpoint_exec}), its command ending with `det-assert` over its
//!   status. A shard failing in every timeline fails, in some is flaky, in none passes; one whose
//!   property never ran is an error of the job's.
//!
//! Exit status: 0 every shard passed, 1 one failed (or the job could not run), 2 one was flaky
//! (0 with --flaky-passes).
const std = @import("std");
const assert = std.debug.assert;
const Client = @import("serve_client.zig").Client;
const sleep_ms = @import("serve_client.zig").sleep_ms;

const Config = struct {
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    /// The node the commands run in.
    node: []const u8,
    /// Run once a key, in the fast VM: dependencies, a build, a database started.
    setup: []const u8 = "true",
    /// Prints the tests' names, one per line.
    list: []const u8,
    /// Runs some of them: `{tests}` (their names, spaces between) or `{shard}` and `{shards}`
    /// (1-based) for a runner that shards itself. Exit status 0 when they pass.
    run: []const u8,
    shards: u32 = 4,
    /// Where the run command writes a JUnit XML report in the node (pytest's --junitxml, JUnit's
    /// own, go-junit-report's): given, each test gets its own verdict across the timelines
    /// (failing in every one, flaky, passing), not only its shard.
    junit: ?[]const u8 = null,
    /// Faults while the tests run: "timing" (the default) pauses threads and processes and
    /// draws the scheduler's choices (det-faults' thread_pause, process_pause, interleave),
    /// which change when threads run and nothing else, so races show; "none", only each
    /// timeline's own schedule; or a list of det-faults' kinds, "timing" among them for its
    /// three (["timing", "partition", "disk"]: the timing ones and those).
    faults: std.json.Value = .{ .string = "timing" },
    /// Each shard's timelines: its tests run that many times, each under its own schedule.
    timelines: u32 = 3,
    vcpus: u32 = 4,
    memory_mib: u32 = 2048,
    key_files: []const []const u8 = &.{},
};

const Cached = struct { checkpoint: []const u8, tests: []const []const u8 };

const files_max = 100_000;
const timing_faults = "thread_pause,process_pause,interleave";
/// The test list in the setup's machine, each timeline's shard read from it.
const tests_path = "/tmp/determinismo-ci-tests";
/// What a setup's snapshot holds besides the setup's own (the test list at tests_path, since
/// one run a job): a setup cached before it lacks it, so it is in the key.
const setup_format = "2: the test list in the machine";
/// det-faults' kinds (guest/runtime/faults.zig's Kind): a name checked here, before any machine,
/// since det-faults refusing it in a shard would only say "Usage" there and inject nothing.
const fault_kinds_known = [_][]const u8{
    "pause",         "isolate",          "partition",    "degrade",    "restart",      "crash",
    "outage",        "durable_crash",    "sync_stall",   "wipe",       "stop",         "disk",
    "throttle",      "process_pause",    "thread_pause", "interleave", "process_kill", "signal",
    "syscall_error", "file_error",       "pod_pause",    "pod_kill",   "pod_isolate",  "pod_degrade",
    "pod_partition", "partition_groups", "clog",         "swizzle",    "clock_skip",   "clock_skew",
};
const fault_kinds_known_text = blk: {
    var text: []const u8 = "";
    for (fault_kinds_known, 0..) |kind, index| text = text ++ (if (index > 0) ", " else "") ++ kind;
    break :blk text;
};

/// The kinds a shard's injector draws from (det-faults --only's list), "" for none.
fn faults_only(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const items: []const std.json.Value = switch (value) {
        .string => |text| {
            if (std.mem.eql(u8, text, "none")) return "";
            if (std.mem.eql(u8, text, "timing")) return timing_faults;
            return error.BadFaults;
        },
        .array => |array| array.items,
        else => return error.BadFaults,
    };
    var kinds: std.ArrayList(u8) = .empty;
    for (items) |item| {
        const name = switch (item) {
            .string => |text| text,
            else => return error.BadFaults,
        };
        const known = for (fault_kinds_known) |kind| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        if (!known and !std.mem.eql(u8, name, "timing")) return error.BadFaults;
        if (kinds.items.len > 0) try kinds.append(arena, ',');
        try kinds.appendSlice(arena, if (known) name else timing_faults);
    }
    if (kinds.items.len == 0) return error.BadFaults; // An empty list: "none" says it.
    return kinds.items;
}
/// A guest action's most (a shard's command must fit one).
const command_max = 4096 - 16 - 256;
const shard_property = "the CI shard's tests pass";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    std.process.exit(run(arena, init.io, argv[1..]) catch |err| {
        std.debug.print("determinismo-ci: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    });
}

fn run(arena: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !u8 {
    var config_path: []const u8 = ".determinismo/ci.json";
    var serve_url: []const u8 = @import("serve_client.zig").url_default();
    var cache_directory: ?[]const u8 = null;
    // Where the tests come from (serve's CI page): the flags (a GitHub Action's, its checkout
    // copied without its .git), else the repository's git.
    var job: Job = .{};
    var flaky_passes = false;
    var reply_max: usize = @import("serve_client.zig").reply_max_default;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const flag = argv[index];
        if (std.mem.eql(u8, flag, "--flaky-passes")) {
            flaky_passes = true;
            continue;
        }
        if (index + 1 >= argv.len) return usage();
        if (std.mem.eql(u8, flag, "--config")) {
            config_path = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--serve")) {
            serve_url = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--cache")) {
            cache_directory = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--repository")) {
            job.repository = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--branch")) {
            job.branch = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--commit")) {
            job.commit = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--subject")) {
            job.subject = argv[index + 1];
        } else if (std.mem.eql(u8, flag, "--reply-max")) {
            reply_max = std.fmt.parseInt(usize, argv[index + 1], 10) catch return usage();
        } else return usage();
        index += 1;
    }
    const cwd = std.Io.Dir.cwd();
    const config_text = cwd.readFileAlloc(io, config_path, arena, .limited(1 << 20)) catch |err| {
        std.debug.print("determinismo-ci: cannot read {s}: {s}\n", .{ config_path, @errorName(err) });
        return 1;
    };
    var config = try std.json.parseFromSliceLeaky(Config, arena, config_text, .{ .ignore_unknown_fields = true });
    const faults = faults_only(arena, config.faults) catch {
        std.debug.print("determinismo-ci: faults is \"timing\", \"none\" or a list of det-faults' kinds (\"timing\" among them for its three): {s}\n", .{
            fault_kinds_known_text,
        });
        return 2;
    };
    if ((config.program == null) == (config.compose == null)) {
        std.debug.print("determinismo-ci: the config names a program or a compose file, one of them\n", .{});
        return 1;
    }
    // Paths as serve sees them: absolute (it runs in its own directory).
    const repository = try working_directory(arena);
    if (config.program) |path| config.program = try std.fs.path.resolve(arena, &.{ repository, path });
    if (config.compose) |path| config.compose = try std.fs.path.resolve(arena, &.{ repository, path });
    const client: Client = .{ .arena = arena, .io = io, .url = serve_url, .reply_max = reply_max };
    // The guest the machines boot (GET /build): a setup's snapshot holds its tools as they were.
    const build = try client.call("GET", "/build", null);
    if (build.status != 200) {
        std.debug.print("determinismo-ci: serve answers no /build ({d}): update it\n", .{build.status});
        return 1;
    }
    const key = try setup_key(arena, io, config, build.body);
    const cache = cache_directory orelse try std.fs.path.join(arena, &.{ std.mem.span(std.c.getenv("HOME") orelse "/tmp"), ".determinismo", "ci-cache" });
    try cwd.createDirPath(io, cache);
    const cache_path = try std.fs.path.join(arena, &.{ cache, try std.fmt.allocPrint(arena, "{s}.json", .{key}) });
    std.debug.print("determinismo-ci: setup key {s}\n", .{key});
    const started_ns = monotonic_ns();
    // The setup: from the cache while its checkpoint is still on serve's disk, else made now.
    var cached = true;
    const setup: Cached = from_cache: {
        const text = cwd.readFileAlloc(io, cache_path, arena, .limited(16 << 20)) catch break :from_cache null;
        const found = std.json.parseFromSliceLeaky(Cached, arena, text, .{ .ignore_unknown_fields = true }) catch break :from_cache null;
        if (!try client.checkpoint_exists(found.checkpoint)) break :from_cache null;
        break :from_cache found;
    } orelse made: {
        cached = false;
        std.debug.print("determinismo-ci: setup\n", .{});
        const found = setup_make(client, config) catch |err| {
            std.debug.print("determinismo-ci: the setup failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        try cwd.writeFile(io, .{ .sub_path = cache_path, .data = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(found, .{})}) });
        break :made found;
    };
    const setup_s = (monotonic_ns() - started_ns) / std.time.ns_per_s;
    std.debug.print("  setup: {s} in {d} s; {d} tests\n", .{ if (cached) "from its cached snapshot" else "made", setup_s, setup.tests.len });
    if (setup.tests.len == 0) {
        std.debug.print("determinismo-ci: no tests listed: pass\n", .{});
        return 0;
    }
    // One run a job: shards * timelines timelines from the checkpoint, each its shard's
    // (its index modulo the shards: explore's {timeline}), the run's page holding the whole job.
    const shard_count: u32 = @intCast(@min(config.shards, setup.tests.len));
    // The explorer writes each timeline's own numbers in (explore's {timeline%N+K}): literal
    // digits wherever the command puts them, a quoted awk program's included.
    const shard_of = try std.fmt.allocPrint(arena, "{{timeline%{d}}}", .{shard_count});
    const command = try shard_command(arena, config.run, tests_path, shard_count, shard_of, config.junit);
    var script: std.ArrayList(u8) = .empty;
    // The fault injector beside the command, stopped once it ends (undoing what it did).
    if (faults.len > 0) try script.print(arena, "det-faults --only {s} & f=$!; ", .{faults});
    // The tests' JVMs covered: here the exec'd code is the system under test (nodes.ExecOptions).
    try script.print(arena, "det-nodes exec --coverage {s} /bin/sh -c ", .{config.node});
    try shell_quote(arena, &script, command);
    try script.appendSlice(arena, "; s=$?");
    if (faults.len > 0) try script.appendSlice(arena, "; kill -TERM $f; wait $f");
    if (config.junit) |path| { // Each test a property (det-assert junit), judged across timelines.
        try script.print(arena, "; det-nodes exec {s} cat ", .{config.node});
        try shell_quote(arena, &script, path);
        try script.appendSlice(arena, " > /tmp/determinismo-ci-junit.xml && det-assert junit /tmp/determinismo-ci-junit.xml");
    }
    try script.print(arena, "; det-assert always \"" ++ shard_property ++ "\" $s \"{{\\\"shard\\\":{{timeline%{d}+1}},\\\"status\\\":$s}}\"", .{shard_count});
    if (script.items.len > command_max) {
        std.debug.print("determinismo-ci: the run command is too long for a guest action ({d} bytes, at most {d})\n", .{ script.items.len, command_max });
        return 1;
    }
    const Started = struct { id: u32 = 0 };
    const started = try client.json(Started, "POST", "/runs", try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = config.program,
        .compose = config.compose,
        .profile = config.profile,
        .scenario = config.scenario,
        .memory_mib = config.memory_mib,
        .branches = shard_count * config.timelines,
        .checkpoint = setup.checkpoint,
        .checkpoint_exec = script.items,
        .ci = try job_complete(arena, io, job),
    }, .{ .emit_null_optional_fields = false })}));
    std.debug.print("determinismo-ci: testing: {d} shards of {d} timelines, run {s}/#{d}\n", .{ shard_count, config.timelines, serve_url, started.id });
    try client.run_wait(started.id, 1000);
    // What serve said of the run: why it stopped it (no coverage in its first timelines: the
    // job's shards then lack timelines, an "error" with no reason given), or that it ended
    // without coverage.
    const Said = struct { stopped_why: []const u8 = "", uncovered: []const u8 = "" };
    const said = client.json(Said, "GET", try std.fmt.allocPrint(arena, "/runs/{d}", .{started.id}), null) catch Said{};
    if (said.stopped_why.len > 0) std.debug.print("determinismo-ci: serve stopped run {d}: {s}\n", .{ started.id, said.stopped_why });
    if (said.uncovered.len > 0) std.debug.print("determinismo-ci: run {d}: {s}\n", .{ started.id, said.uncovered });
    // Each shard's verdict: its property's failing timelines among its own.
    const rows = try client.json([]const ShardRow, "POST", try std.fmt.allocPrint(arena, "/runs/{d}/sql", .{started.id}), try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .sql = shard_sql }, .{})}));
    var verdict: []const u8 = "pass";
    var failing_timelines: u32 = 0;
    for (1..shard_count + 1) |number| {
        const row: ShardRow = for (rows) |row| {
            if (row.shard == number) break row;
        } else .{};
        var count: u32 = 0;
        var at = number - 1;
        while (at < setup.tests.len) : (at += shard_count) count += 1;
        const judged = shard_verdict(row, config.timelines);
        failing_timelines += judged.failing;
        if (verdict_rank(judged.verdict) > verdict_rank(verdict)) verdict = judged.verdict;
        std.debug.print("  shard {d}: {s:<6} {d} tests, failing in {d} of {d} timelines\n", .{
            number, judged.verdict, count, judged.failing, config.timelines,
        });
    }
    // Each test's verdict from the timelines' JUnit reports; the job's the worse of the two
    // (a shard failing with no test failing in its report, a crash in teardown, stays a failure).
    if (config.junit != null) {
        const tests = try tests_judge(client, &.{started.id}, config.timelines, serve_url);
        if (verdict_rank(tests.verdict) > verdict_rank(verdict)) verdict = tests.verdict;
        // Timelines without their report beyond those whose shard failed (a hang, a dead
        // runner): a run that passed and wrote none, a job set up wrong.
        if (tests.unreported > failing_timelines) verdict = "error";
    }
    // Serve stopped the run (no coverage in its first timelines): the job never ran its tests.
    if (said.stopped_why.len > 0) verdict = "error";
    std.debug.print("determinismo-ci: {s}\n", .{verdict});
    if (std.mem.eql(u8, verdict, "pass")) return 0;
    if (std.mem.eql(u8, verdict, "flaky")) return if (flaky_passes) 0 else 2;
    return 1;
}

/// A shard's row from shard_sql: of its timelines that stated its property, those it failed in.
const ShardRow = struct { shard: u32 = 0, failing: u32 = 0, timelines: u32 = 0 };

/// A shard's verdict from its row and the timelines it ran in (docs/CI.md: failing in every
/// timeline, fail; in some, flaky; in none, pass). A timeline that never stated its property
/// failed it: its tests hung past its limit, or its runner died (the races and crashes CI here is
/// for); called the job's "error", "failing in 0 of 3", they exited 1 even with --flaky-passes
/// (CE27, the Lean replica of determinismo).
fn shard_verdict(row: ShardRow, timelines: u32) struct { verdict: []const u8, failing: u32 } {
    const failing = row.failing + (timelines -| row.timelines);
    const verdict = if (failing == 0) "pass" else if (failing >= timelines) "fail" else "flaky";
    return .{ .verdict = verdict, .failing = failing };
}

test "a shard whose tests hang in one timeline of three is flaky, failing in that one" {
    // CE27 (the Lean replica of determinismo): a timeline whose tests hung past its limit (or
    // whose runner died) states nothing, and the job said "error", "failing in 0 of 3", exit 1
    // even with --flaky-passes; docs/CI.md knows fail, flaky and pass.
    const judged = shard_verdict(.{ .shard = 1, .failing = 0, .timelines = 2 }, 3);
    try std.testing.expectEqualStrings("flaky", judged.verdict);
    try std.testing.expectEqual(@as(u32, 1), judged.failing);
    const all = shard_verdict(.{ .shard = 1, .failing = 0, .timelines = 0 }, 3); // Every one hung.
    try std.testing.expectEqualStrings("fail", all.verdict);
    try std.testing.expectEqual(@as(u32, 3), all.failing);
    try std.testing.expectEqualStrings("pass", shard_verdict(.{ .shard = 1, .failing = 0, .timelines = 3 }, 3).verdict);
    try std.testing.expectEqualStrings("flaky", shard_verdict(.{ .shard = 1, .failing = 1, .timelines = 3 }, 3).verdict);
}

/// Each shard's verdict from serve's store: its property's failing timelines among its own, the
/// run's (explored_timeline_events): a session on the job's run (a fix tried at a failing
/// timeline's REPL) changed it, 3 failing and a passing session read flaky (CE28, the Lean
/// replica of determinismo).
pub const shard_sql = "SELECT CAST(json_extract(event, '$.assert.details.shard') AS INTEGER) AS shard, " ++
    "count(DISTINCT timeline) FILTER (WHERE condition = false) AS failing, count(DISTINCT timeline) AS timelines " ++
    "FROM explored_timeline_events WHERE name = 'the CI shard''s tests pass' GROUP BY 1 ORDER BY 1";
comptime {
    std.debug.assert(std.mem.eql(u8, shard_property, "the CI shard's tests pass")); // Its quote doubled above.
}

/// The setup in a machine of its own: the setup command, the test list, a checkpoint; the
/// machine stopped after (its checkpoint stays).
fn setup_make(client: Client, config: Config) !Cached {
    const arena = client.arena;
    const Made = struct { machine: u32 = 0 };
    const made = try client.json(Made, "POST", "/machines", try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = config.program,
        .compose = config.compose,
        .profile = config.profile,
        .scenario = config.scenario,
        .vcpus = config.vcpus,
        .memory_mib = config.memory_mib,
    }, .{ .emit_null_optional_fields = false })}));
    defer client.delete(made.machine) catch {};
    const set_up = try client.exec(made.machine, config.node, config.setup, 3600);
    if (set_up.status != 0) {
        std.debug.print("determinismo-ci: the setup exited {d}:\n{s}\n", .{ set_up.status, set_up.output[set_up.output.len -| 4000..] });
        return error.SetupFailed;
    }
    const listed = try client.exec(made.machine, config.node, config.list, 600);
    if (listed.status != 0) {
        std.debug.print("determinismo-ci: listing the tests exited {d}:\n{s}\n", .{ listed.status, listed.output[listed.output.len -| 4000..] });
        return error.ListFailed;
    }
    // The list in the machine (tests_path): each timeline takes its shard's part of it.
    const listing = try client.call("PUT", try std.fmt.allocPrint(arena, "/machines/{d}/files?node={s}&path=" ++ tests_path, .{ made.machine, config.node }), listed.output);
    if (listing.status / 100 != 2) {
        std.debug.print("determinismo-ci: the test list not written in the machine ({d}): {s}\n", .{ listing.status, listing.body });
        return error.ListFailed;
    }
    var tests: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, listed.output, "\r\n");
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t");
        if (name.len > 0) try tests.append(arena, name);
    }
    return .{ .checkpoint = try client.checkpoint(made.machine), .tests = tests.items };
}

/// The setup's key: what the setup's machine depends on (the system, the setup and list
/// commands, the machine's size, serve's build and guest), the system's file and every key
/// file's path and contents. Not the shards, their timelines or the run command: changing those
/// reuses the setup.
fn setup_key(arena: std.mem.Allocator, io: std.Io, config: Config, build: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var hasher = std.hash.Wyhash.init(0x6369);
    hasher.update(setup_format);
    hasher.update(build);
    hasher.update(try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = config.program,
        .compose = config.compose,
        .profile = config.profile,
        .scenario = config.scenario,
        .node = config.node,
        .setup = config.setup,
        .list = config.list,
        .vcpus = config.vcpus,
        .memory_mib = config.memory_mib,
        .key_files = config.key_files,
    }, .{})}));
    if (config.compose) |path| hasher.update(cwd.readFileAlloc(io, path, arena, .limited(16 << 20)) catch "");
    if (config.program) |path| hasher.update(cwd.readFileAlloc(io, path, arena, .limited(512 << 20)) catch "");
    var files: std.ArrayList([]const u8) = .empty;
    for (config.key_files) |path| try key_files_add(arena, io, &files, path);
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (files.items) |path| {
        hasher.update(path);
        hasher.update(cwd.readFileAlloc(io, path, arena, .limited(256 << 20)) catch "");
    }
    return std.fmt.allocPrint(arena, "{x:0>16}", .{hasher.final()});
}

/// A key file, or every file under a directory (sorted later: the key does not depend on the
/// order the file system lists them in).
fn key_files_add(arena: std.mem.Allocator, io: std.Io, files: *std.ArrayList([]const u8), path: []const u8) !void {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        try files.append(arena, path);
        return;
    };
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (files.items.len == files_max) return error.TooManyKeyFiles;
        try files.append(arena, try std.fs.path.join(arena, &.{ path, entry.path }));
    }
}

/// The shard property's failing timelines, from its run's verdict line (`... failing in   k
/// the CI shard's tests pass`); null when the property never ran.
const Job = struct { repository: []const u8 = "", branch: []const u8 = "", commit: []const u8 = "", subject: []const u8 = "" };

/// The job's repository, branch, commit and subject: as given, else from git where it runs (the
/// repository its origin's URL, else its directory's name; a directory without git: its name).
fn job_complete(arena: std.mem.Allocator, io: std.Io, given: Job) !Job {
    var job = given;
    const git = struct {
        fn ask(a: std.mem.Allocator, i: std.Io, args: []const []const u8) []const u8 {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.append(a, "git") catch return "";
            argv.appendSlice(a, args) catch return "";
            const result = std.process.run(a, i, .{ .argv = argv.items }) catch return "";
            if (!result.term.success()) return "";
            return std.mem.trim(u8, result.stdout, " \r\n");
        }
    };
    if (job.repository.len == 0) {
        job.repository = git.ask(arena, io, &.{ "remote", "get-url", "origin" });
        if (job.repository.len == 0) job.repository = std.fs.path.basename(try working_directory(arena));
    }
    if (job.branch.len == 0) job.branch = git.ask(arena, io, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    if (job.commit.len == 0) job.commit = git.ask(arena, io, &.{ "rev-parse", "HEAD" });
    if (job.subject.len == 0 and job.commit.len > 0) job.subject = git.ask(arena, io, &.{ "log", "-1", "--format=%s", job.commit });
    return job;
}

fn verdict_rank(verdict: []const u8) u8 {
    if (std.mem.eql(u8, verdict, "error")) return 3;
    if (std.mem.eql(u8, verdict, "fail")) return 2;
    if (std.mem.eql(u8, verdict, "flaky")) return 1;
    return 0;
}

/// The prefix of each test's property (det-assert junit's).
const test_prefix = "test passes: ";

/// Each test across its shard's timelines, from the run's properties (each test one, stated by
/// det-assert junit from the timeline's JUnit report): failing in all it ran in, flaky (in
/// some), or passing. Prints the tests that did not pass, each with its property's page on
/// serve (its examples, each failing timeline replayable). "error" when a timeline stated no
/// test (the run command died before its report).
fn tests_judge(client: Client, runs: []const u32, timelines: u32, serve_url: []const u8) !struct { verdict: []const u8, unreported: u32 } {
    const arena = client.arena;
    const Property = struct { message: []const u8, timelines_hit: u32 = 0, timelines_failing: u32 = 0 };
    var tests: u32 = 0;
    var failing: u32 = 0;
    var flaky: u32 = 0;
    var unreported: u32 = 0;
    for (runs) |run_id| {
        const path = try std.fmt.allocPrint(arena, "/runs/{d}/properties", .{run_id});
        const properties = try client.json([]const Property, "GET", path, null);
        var reported: u32 = 0;
        for (properties) |property| {
            if (!std.mem.startsWith(u8, property.message, test_prefix)) continue;
            tests += 1;
            reported = @max(reported, property.timelines_hit);
            if (property.timelines_failing == 0) continue;
            const every = property.timelines_failing >= property.timelines_hit;
            if (every) failing += 1 else flaky += 1;
            var link: std.ArrayList(u8) = .empty;
            for (property.message) |byte| {
                if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.~", byte) != null) {
                    try link.append(arena, byte);
                } else try link.print(arena, "%{X:0>2}", .{byte});
            }
            std.debug.print("  {s:<6} {s}: failing in {d} of {d} timelines  {s}/#{d}/property/{s}\n", .{
                if (every) "fail" else "flaky", property.message[test_prefix.len..], property.timelines_failing,
                property.timelines_hit,         serve_url,                           run_id,
                link.items,
            });
        }
        unreported += timelines -| reported;
    }
    std.debug.print("determinismo-ci: {d} tests, {d} failing, {d} flaky", .{ tests, failing, flaky });
    if (unreported > 0) std.debug.print("; {d} timelines without their JUnit report", .{unreported});
    std.debug.print("\n", .{});
    const verdict = if (failing > 0) "fail" else if (flaky > 0) "flaky" else "pass";
    return .{ .verdict = verdict, .unreported = unreported };
}

fn shard_failing(output: []const u8) ?u32 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, shard_property) == null) continue;
        const at = std.mem.indexOf(u8, line, "failing in") orelse continue;
        var words = std.mem.tokenizeScalar(u8, line[at + "failing in".len ..], ' ');
        return std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
    }
    return null;
}

/// A shard's command in its node: the runner's own sharding ({shard}, {shards}, 1-based), or the
/// shard's part of the list at `list` ({tests}: the lines whose position modulo the shards is
/// the shard's, through xargs, a name with spaces one argument). A long list makes xargs run the
/// runner more than once, each run writing the JUnit report over the last, so with a report each
/// run's is moved aside and all of them make the report (det-assert junit reads every
/// `<testcase>` in its text): every test of the shard gets its verdict, not only the last run's
/// (CE21, the Lean replica of determinismo: 1,617 of 2,000 80-byte names lost at 128 KiB).
fn shard_command(arena: std.mem.Allocator, run_line: []const u8, list: []const u8, shard_count: u32, shard_of: []const u8, junit: ?[]const u8) ![]const u8 {
    if (std.mem.indexOf(u8, run_line, "{tests}") != null) {
        var each: std.ArrayList(u8) = .empty;
        try each.appendSlice(arena, try std.mem.replaceOwned(u8, arena, run_line, "{tests}", "\"$@\""));
        if (junit) |path| {
            try each.appendSlice(arena, "; s=$?; if [ -f ");
            try shell_quote(arena, &each, path);
            try each.appendSlice(arena, " ]; then mv ");
            try shell_quote(arena, &each, path);
            try each.append(arena, ' ');
            try shell_quote(arena, &each, path);
            try each.appendSlice(arena, ".determinismo-ci-part.$$; fi; exit $s");
        }
        var line: std.ArrayList(u8) = .empty;
        try line.print(arena, "awk -v n={d} -v i={s} '(NR - 1) % n == i' {s} | tr '\\n' '\\000' | xargs -0 sh -c ", .{ shard_count, shard_of, list });
        try shell_quote(arena, &line, each.items);
        try line.appendSlice(arena, " sh");
        if (junit) |path| {
            try line.appendSlice(arena, "; s=$?; set -- ");
            try shell_quote(arena, &line, path);
            try line.appendSlice(arena, ".determinismo-ci-part.*; if [ -e \"$1\" ]; then cat \"$@\" > ");
            try shell_quote(arena, &line, path);
            try line.appendSlice(arena, "; rm -f \"$@\"; fi; exit $s");
        }
        return line.items;
    }
    const with_shard = try std.mem.replaceOwned(u8, arena, run_line, "{shard}", try std.fmt.allocPrint(arena, "{{timeline%{d}+1}}", .{shard_count}));
    return std.mem.replaceOwned(u8, arena, with_shard, "{shards}", try std.fmt.allocPrint(arena, "{d}", .{shard_count}));
}

fn shell_quote(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, byte);
    }
    try out.append(arena, '\'');
}

fn working_directory(arena: std.mem.Allocator) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = std.os.linux.getcwd(&buffer, buffer.len);
    if (std.os.linux.errno(size) != .SUCCESS) return error.NoWorkingDirectory;
    return arena.dupe(u8, std.mem.sliceTo(&buffer, 0));
}

fn monotonic_ns() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn usage() u8 {
    std.debug.print("usage: determinismo-ci [--config .determinismo/ci.json] [--serve <url>] [--cache <dir>] [--flaky-passes]\n" ++
        "                      [--repository <name>] [--branch <name>] [--commit <sha>] [--subject <text>]   (default: git's, where it runs)\n" ++
        "                      [--reply-max <bytes>]   (the largest reply read from serve: 64 MB)\n", .{});
    return 2;
}

test "a shard's verdict line read" {
    const output = "  PASS always hit in 6/6\n  FAIL always                hit in    6/6 branches, failing in    2  the CI shard's tests pass\n";
    try std.testing.expectEqual(@as(?u32, 2), shard_failing(output));
    try std.testing.expectEqual(@as(?u32, null), shard_failing("nothing here\n"));
}

test "the setup's key: the shards and run command reuse it, the setup and the guest do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const base: Config = .{ .node = "app", .setup = "make", .list = "ls tests", .run = "run {tests}" };
    var reshard = base;
    reshard.run = "run --shard {shard}/{shards}";
    reshard.shards = 12;
    reshard.timelines = 1;
    var resetup = base;
    resetup.setup = "make all";
    const build = "{\"commit\":\"abc\",\"initrd\":\"1-base.cpio\"}";
    const key = try setup_key(arena, io, base, build);
    try std.testing.expectEqualStrings(key, try setup_key(arena, io, reshard, build));
    try std.testing.expect(!std.mem.eql(u8, key, try setup_key(arena, io, resetup, build)));
    // Another guest (an update's tools): another setup.
    try std.testing.expect(!std.mem.eql(u8, key, try setup_key(arena, io, base, "{\"commit\":\"abc\",\"initrd\":\"2-base.cpio\"}")));
}

test "faults: timing, none, or a list of det-faults' kinds with timing's three" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = struct {
        fn of(a: std.mem.Allocator, text: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        }
    }.of;
    try std.testing.expectEqualStrings(timing_faults, try faults_only(arena, try parse(arena, "\"timing\"")));
    try std.testing.expectEqualStrings("", try faults_only(arena, try parse(arena, "\"none\"")));
    try std.testing.expectEqualStrings(timing_faults ++ ",partition,disk", try faults_only(arena, try parse(arena, "[\"timing\", \"partition\", \"disk\"]")));
    try std.testing.expectEqualStrings("process_kill", try faults_only(arena, try parse(arena, "[\"process_kill\"]")));
    try std.testing.expectError(error.BadFaults, faults_only(arena, try parse(arena, "[\"partitoin\"]")));
    try std.testing.expectError(error.BadFaults, faults_only(arena, try parse(arena, "\"all\"")));
    try std.testing.expectError(error.BadFaults, faults_only(arena, try parse(arena, "[]")));
}

test "every test of a shard is in its JUnit report, however many runs xargs splits the list into" {
    // CE21 (the Lean replica of determinismo): a shard's list past xargs's command-line size ran
    // the runner more than once, each run writing the report over the last: only the last
    // batch's tests got verdicts (1,617 of 2,000 80-byte names lost at GNU's 128 KiB).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root = root_buffer[0..try directory.dir.realPathFile(io, ".", &root_buffer)];
    const list = try std.fs.path.join(arena, &.{ root, "tests" });
    const report = try std.fs.path.join(arena, &.{ root, "junit.xml" });
    var names: std.ArrayList(u8) = .empty;
    for (0..3000) |i| try names.print(arena, "suite.module.{d:0>6}.a_test_name_long_enough_to_take_eighty_bytes_of_the_line\n", .{i});
    try directory.dir.writeFile(io, .{ .sub_path = "tests", .data = names.items });
    const runner = try std.fmt.allocPrint(arena, "for t in {{tests}}; do printf '<testcase classname=\"c\" name=\"%s\"/>\\n' \"$t\"; done > {s}", .{report});
    const command = try shard_command(arena, runner, list, 1, "0", report);
    const result = try std.process.run(arena, io, .{ .argv = &.{ "/bin/sh", "-c", command } });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const text = try directory.dir.readFileAlloc(io, "junit.xml", arena, .limited(1 << 24));
    try std.testing.expectEqual(@as(usize, 3000), std.mem.count(u8, text, "<testcase"));
}
