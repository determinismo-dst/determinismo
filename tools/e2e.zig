// SPDX-License-Identifier: MIT
//! End-to-end checks on the Linux host: the whole system, through the command line, as a user
//! runs it. `zig build e2e` (after building the guest kernel and initramfs, see README.md).
//!
//! Each check boots real VMs: exploration finds the examples' known bugs without overshoots,
//! branches replay from fresh boots with identical event hashes, tapes replay without their
//! strategy, and a tape refuses to replay on different inputs.
//!
//! Usage: e2e [--bin <dir>] [--guest <dir>] [--cache <dir>] [--only <name>]
//!   --bin    built programs (zig-out/bin)       --guest  vmlinuz and base.cpio ($HOME/guest)
//!   --cache  determinismo's cache ($HOME/cache) --only   the check <name>, else those containing it
const std = @import("std");
const assert = std.debug.assert;

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    determinismo: []const u8,
    machine: []const []const u8,
    bin: []const u8,
    scratch: []const u8,
    /// Babashka, for notebooks ($DETERMINISMO_BB); without it their evaluation is skipped.
    bb: ?[]const u8 = null,
    /// jank, for the REPL's client as the viz runs it ($DETERMINISMO_JANK).
    jank: ?[]const u8 = null,
    failures: u32 = 0,
    /// Every exploration's whole output is kept (`<scratch>/outputs/<n>.log`): a failing check
    /// names the ones it judged (those since the check before it), to read rather than rerun.
    outputs: std.ArrayList([]const u8) = .empty,
    output_count: u32 = 0,
    /// bank's first timeline of seed 3 that loses money (bank_violating_branch), once found.
    bank_violating: ?[]const u8 = null,
    bank_cold_violating: ?[]const []const u8 = null,
};

/// The first of bank's seed 3 timelines that violates "total balance is conserved", found once
/// by exploring 16 (the timelines the until, rewind, extract and inject checks stop in). Any
/// guest change makes other timelines: the guest kernel's TLB patch made timeline 4, these
/// checks' for a day, one that keeps its money.
/// The first timeline of an exploration's output where `property` failed.
fn failing_branch(output: []const u8, property: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        const fail = std.mem.indexOf(u8, line, "FAIL \"") orelse continue;
        if (std.mem.indexOf(u8, line[fail..], property) == null) continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        return std.mem.trim(u8, line["[branch ".len..end], " ");
    }
    return null;
}

fn bank_violating_branch(context: *Context) ![]const u8 {
    if (context.bank_violating) |known| return known;
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const report = try explore(context, &.{
        "--program",  program, "--scenario", "bank", "--seed", "3",
        "--branches", "16",
    });
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        if (std.mem.indexOf(u8, line, "FAIL \"total balance is conserved\"") == null) continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const index = std.mem.trim(u8, line["[branch ".len..end], " ");
        context.bank_violating = try context.arena.dupe(u8, index);
        return context.bank_violating.?;
    }
    expect(context, false, "bank: one of seed 3's first 16 timelines loses money", .{});
    return error.NoViolatingBranch;
}

/// A timeline of seed 3's `bank_cold` (40 accounts: collisions seldom) that loses money: its
/// failure was decided at its colliding transfers, so causality analysis finds a jump. In
/// `bank`, 10 accounts collide so often that a timeline fails from almost any moment (7 futures
/// in 8 from its first second, the guest kernel of 2026-10-29): no moment decides it.
/// bank_cold's timelines of seed 3 (the first 32) that lose money, by index.
fn bank_cold_violating_branches(context: *Context) ![]const []const u8 {
    if (context.bank_cold_violating) |known| return known;
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const report = try explore(context, &.{
        "--program",  program, "--scenario", "bank_cold", "--seed", "3",
        "--branches", "32",
    });
    var indexes: std.ArrayList(u32) = .empty;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        if (std.mem.indexOf(u8, line, "FAIL \"total balance is conserved\"") == null) continue;
        const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const index = std.fmt.parseInt(u32, std.mem.trim(u8, line["[branch ".len..end], " "), 10) catch continue;
        try indexes.append(context.arena, index);
    }
    if (indexes.items.len == 0) {
        expect(context, false, "bank_cold: one of seed 3's first 32 timelines loses money", .{});
        return error.NoViolatingBranch;
    }
    // By index: the report lists timelines as they end, in the order the workers finish them.
    std.mem.sort(u32, indexes.items, {}, std.sort.asc(u32));
    const texts = try context.arena.alloc([]const u8, indexes.items.len);
    for (indexes.items, texts) |index, *text| text.* = try std.fmt.allocPrint(context.arena, "{d}", .{index});
    context.bank_cold_violating = texts;
    return texts;
}

/// One branch line of a report: `[branch N] seed=... events_hash=H failing=F ...`.
const Branch = struct { index: u32, events_hash: []const u8, failing: bool };

const branches_max = 64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/root";
    var bin: []const u8 = "zig-out/bin";
    var guest: []const u8 = try std.fs.path.join(arena, &.{ home, "guest" });
    var cache: []const u8 = try std.fs.path.join(arena, &.{ home, "cache" });
    var only: []const u8 = "";
    var bb: ?[]const u8 = init.environ_map.get("DETERMINISMO_BB");
    var jank: ?[]const u8 = init.environ_map.get("DETERMINISMO_JANK");
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--bin")) bin = value else if (std.mem.eql(u8, flag, "--guest")) {
            guest = value;
        } else if (std.mem.eql(u8, flag, "--cache")) {
            cache = value;
        } else if (std.mem.eql(u8, flag, "--only")) {
            only = value;
        } else if (std.mem.eql(u8, flag, "--bb")) {
            bb = value;
        } else if (std.mem.eql(u8, flag, "--jank")) {
            jank = value;
        } else return error.Usage;
    }
    // Its own: suites run at once (a full one and a single check) do not share files. On disk,
    // not in /tmp: a tmpfs is memory, and failed checks' files (kept to look at) once held 16
    // GB of srv3's, short of what the hunts' holders needed. A day after a suite ended, its
    // files go.
    const scratches = try std.fs.path.join(arena, &.{ home, ".cache", "determinismo-e2e" });
    try std.Io.Dir.cwd().createDirPath(init.io, scratches);
    scratches_sweep(init.io, arena, scratches);
    const scratch = try std.fmt.allocPrint(arena, "{s}/{d}", .{ scratches, std.os.linux.getpid() });
    std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);
    // The guest as the suite started: a deploy meanwhile rewrites ~/guest, and the replays of
    // timelines explored before it would boot other inputs (refused: TapeInputsDiffer; srv3,
    // 2026-10-27).
    const kernel = try std.fs.path.join(arena, &.{ scratch, "vmlinuz" });
    const initrd = try std.fs.path.join(arena, &.{ scratch, "base.cpio" });
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(try std.fs.path.join(arena, &.{ guest, "vmlinuz" }), cwd, kernel, init.io, .{});
    try cwd.copyFile(try std.fs.path.join(arena, &.{ guest, "base.cpio" }), cwd, initrd, init.io, .{});
    var context = Context{
        .arena = arena,
        .io = init.io,
        .bb = bb,
        .jank = jank,
        .determinismo = try std.fs.path.join(arena, &.{ bin, "determinismo" }),
        .machine = &.{
            "--kernel",     kernel,
            "--initrd",     initrd,
            "--memory-mib", "2048",
            "--append",     "quiet",
            "--cache",      cache,
            // Counted driver starts, as the checks were written for (explore's default draws a
            // scenario's driver phase up to 20 minutes).
            "--drive-max",  "none",
        },
        .bin = bin,
        .scratch = scratch,
    };

    const jar = try std.fs.path.join(arena, &.{ home, "opt", "tla", "tla2tools.jar" });
    const ran = try checks_run(&context, only, jar);
    if (ran == 0) {
        std.debug.print("e2e: no check is named like '{s}'\n", .{only});
        std.process.exit(2);
    }
    if (context.failures > 0) {
        std.debug.print("e2e: {d} checks failed (their files: {s})\n", .{
            context.failures, context.scratch,
        });
        std.process.exit(1);
    }
    std.Io.Dir.cwd().deleteTree(init.io, context.scratch) catch {};
    std.debug.print("e2e: all checks passed\n", .{});
}

/// Deletes the scratch directories (named by their suite's pid) of suites no longer running whose
/// files are a day old.
fn scratches_sweep(io: std.Io, arena: std.mem.Allocator, scratches: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, scratches, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now_s = std.Io.Clock.real.now(io).toSeconds();
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(std.os.linux.pid_t, entry.name, 10) catch continue;
        const alive = std.os.linux.errno(std.os.linux.kill(pid, @fromBackingInt(@intCast(0)))) != .SRCH;
        if (alive) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (now_s - stat.mtime.toSeconds() < std.time.s_per_day) continue;
        const path = std.fs.path.join(arena, &.{ scratches, entry.name }) catch continue;
        cwd.deleteTree(io, path) catch {};
    }
}

/// Runs the check named `only`, or when none is, those whose names contain it (all when empty),
/// and counts them.
fn checks_run(context: *Context, only: []const u8, jar: []const u8) !u32 {
    const checks = .{
        .{ "bank", check_bank },                             .{ "shop", check_shop },
        .{ "tapes", check_tapes },                           .{ "debugging", check_debugging },
        .{ "python", check_python_strategy },                .{ "egress", check_egress },
        .{ "ingress", check_ingress },                       .{ "ingress-session", check_ingress_session },
        .{ "moments", check_moments },                       .{ "properties", check_builtin_properties },
        .{ "entropy", check_kernel_entropy },                .{ "quiet", check_quiet_period },
        .{ "clock_jitter", check_clock_jitter },             .{ "query", check_query },
        .{ "progress", check_progress_while_quiet },         .{ "network", check_network_faults },
        .{ "fault-exclusions", check_fault_exclusions },     .{ "serve", check_serve },
        .{ "until", check_until_and_causality },             .{ "coverage-gate", check_coverage_gate },
        .{ "coverage", check_coverage },                     .{ "parallel", check_parallel },
        .{ "fork", check_fork },                             .{ "tree", check_tree },
        .{ "startup-coverage", check_startup_coverage },     .{ "memory-climb", check_memory_climb },
        .{ "disk", check_disk },                             .{ "shape", check_shape },
        .{ "repl-strategy", check_repl_strategy },           .{ "end", check_end },
        .{ "plans", check_plans },                           .{ "durability", check_durability },
        .{ "mutate", check_mutate },                         .{ "interleave", check_interleave },
        .{ "checks", check_host_checks },                    .{ "pausing", check_pausing },
        .{ "shrink", check_shrink },                         .{ "holds", check_holds },
        .{ "coverage-set", check_coverage_set },             .{ "inject", check_inject },
        .{ "aim", check_aim },                               .{ "aftershock", check_aftershock },
        .{ "record-power-loss", check_record_power_loss },   .{ "errno-storm", check_errno_storm },
        .{ "compose", check_compose },                       .{ "shards", check_shards },
        .{ "stress", check_stress },                         .{ "controller", check_controller },
        .{ "clojure", check_clojure },                       .{ "k3s", check_k3s },
        .{ "script", check_script },                         .{ "modulation", check_cpu_modulation },
        .{ "profile", check_profile },                       .{ "catalog", check_catalog },
        .{ "guidance", check_guidance },                     .{ "voidstar", check_voidstar },
        .{ "changed", check_changed },                       .{ "readdress", check_readdress },
        .{ "unlist", check_unlist },                         .{ "signal", check_signal },
        .{ "syscall_error", check_syscall_error },           .{ "swarm", check_swarm },
        .{ "metastable", check_metastable },                 .{ "file_error", check_file_error },
        .{ "retroactive", check_retroactive },               .{ "epoch", check_epoch },
        .{ "drive", check_drive },                           .{ "hang", check_hang },
        .{ "pinned", check_pinned },                         .{ "slow", check_slow },
        .{ "ending-window", check_ending_window },           .{ "sought", check_sought },
        .{ "optimize", check_optimize },                     .{ "states", check_states },
        .{ "crash-points", check_crash_points },             .{ "nodes-down", check_nodes_down },
        .{ "stale-pid", check_stale_pid },                   .{ "memory-growth", check_memory_growth },
        .{ "upgrade", check_upgrade },                       .{ "knobs", check_knobs },
        .{ "quorum", check_quorum },                         .{ "spare", check_spare },
        .{ "saved", check_saved },                           .{ "concurrent", check_concurrent },
        .{ "resume", check_resume },                         .{ "ui", check_ui },
        .{ "runs", check_runs },                             .{ "kubernetes", check_kubernetes },
        .{ "steps", check_steps },                           .{ "before-nodes", check_before_nodes },
        .{ "session", check_session },                       .{ "fast", check_fast },
        .{ "sandbox", check_sandbox },                       .{ "devproxy", check_devproxy },
        .{ "sandbox-egress", check_sandbox_egress },         .{ "ci", check_ci },
        .{ "repl", check_repl },                             .{ "mechanics", check_mechanics },
        .{ "budget", check_budget },                         .{ "sinks", check_sinks },
        .{ "dotnet", check_dotnet },                         .{ "lines", check_lines },
        .{ "voidstar-static", check_voidstar_static },       .{ "frozen-start", check_frozen_start },
        .{ "hangup", check_hangup },                         .{ "frozen-step", check_frozen_step },
        .{ "templates", check_templates },                   .{ "volumes", check_volumes },
        .{ "setup-mode", check_setup_mode },                 .{ "jank", check_jank_repl },
        .{ "bank-steps", check_bank_steps },                 .{ "checkpoint", check_session_checkpoint },
        .{ "ingress-checkpoint", check_ingress_checkpoint }, .{ "ingress-crash", check_ingress_crash },
        .{ "draws", check_draws },                           .{ "exit-stack", check_exit_stack },
        .{ "plan-calls", check_plan_calls },                 .{ "services", check_services },
        .{ "sites", check_sites },                           .{ "client", check_client },
        .{ "session-exact", check_session_exact },           .{ "java-watch", check_java_watch },
    };
    // A check's whole name runs it alone (check.sh's `ui` ran guidance and quiet too).
    var exact = std.mem.eql(u8, only, "tla");
    inline for (checks) |check| exact = exact or std.mem.eql(u8, check[0], only);
    var ran: u32 = 0;
    inline for (checks) |check| {
        const named = if (exact) std.mem.eql(u8, check[0], only) else std.mem.indexOf(u8, check[0], only) != null;
        if (named) {
            try check[1](context);
            ran += 1;
        }
    }
    if (if (exact) std.mem.eql(u8, only, "tla") else std.mem.indexOf(u8, "tla", only) != null) {
        try check_tla(context, jar);
        ran += 1;
    }
    return ran;
}

const Example = struct { program: []const u8, scenario: []const u8, branches: u32 };

fn check_bank(context: *Context) !void {
    try check_example(context, .{ .program = "bank-test", .scenario = "bank", .branches = 12 });
}

fn check_shop(context: *Context) !void {
    try check_example(context, .{ .program = "shop-test", .scenario = "prices", .branches = 4 });
}

/// Explores, then replays the first failing branch (if any) and the first passing one alone.
fn check_example(context: *Context, example: Example) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, example.program });
    const branches_text = try std.fmt.allocPrint(context.arena, "{d}", .{example.branches});
    const report = try explore(context, &.{
        "--program",  program,       "--scenario", example.scenario, "--seed", "7",
        "--branches", branches_text,
    });
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == example.branches, "{s}: explored {d} branches", .{
        example.program, count,
    });
    expect(context, std.mem.indexOf(u8, report, ", 0 overshoots") != null, "{s}: no overshoots", .{
        example.program,
    });
    for ([_]bool{ true, false }) |failing| {
        const branch = for (branches[0..count]) |branch| {
            if (branch.failing == failing) break branch;
        } else continue;
        const index_text = try std.fmt.allocPrint(context.arena, "{d}", .{branch.index});
        const replay = try explore(context, &.{
            "--program", program,    "--scenario", example.scenario, "--seed", "7",
            "--branch",  index_text,
        });
        var replayed: [1]Branch = undefined;
        const ran_one = parse_branches(replay, &replayed) == 1;
        expect_all(context, &.{
            .{ "the replay ran one timeline", ran_one },
            .{ "its events hash is the original's", ran_one and std.mem.eql(u8, replayed[0].events_hash, branch.events_hash) },
        }, "{s}: branch {d} ({s}) replays from a fresh boot", .{
            example.program, branch.index, if (failing) "failing" else "passing",
        });
    }
    if (std.mem.eql(u8, example.program, "bank-test")) {
        const found = for (branches[0..count]) |branch| {
            if (branch.failing) break true;
        } else false;
        expect(context, found, "{s}: exploration finds the lost update", .{example.program});
    }
}

/// A strategy's branch replays from its tape alone, and not on different inputs.
/// A moment is never reached early: replays of a timeline under CPU modulation to moments across
/// it each stop at or after theirs. A soft stop that ended a modulation stretch read as the
/// moment's own stop, up to 144 us early, and the children of a node made by a holder at the
/// moment parted from their replays (run 356, srv4 2026-11-01). A busy guest reading its clock
/// (the selftest's spin) and stretches of 100 to 1000 us, so that stretches end at soft stops all
/// the time (at 10 to 200 ms, 40 moments of an idle bank never met one, before the fix too;
/// without the fix, 40 of 40 spin moments at 20 to 200 us came early, by up to 472 us).
fn check_moments(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "spin", "--seed", "3", "--branch", "0", "--cpu-modulation-stretch-us", "100-1000",
    };
    const whole = try explore(context, &common);
    const length_ms = branch_vtime_ms(whole) orelse return expect(context, false, "moments: the timeline's length", .{});
    if (length_ms < 1500) return expect(context, false, "moments: a timeline past its setup ({d} ms)", .{length_ms});
    const count = 10;
    var reached: u32 = 0;
    var early: u32 = 0;
    var worst_ns: u64 = 0;
    var worst_ms: u64 = 0;
    for (0..count) |index| {
        const ms = 1100 + (length_ms - 1200) * index / count;
        const text = try explore(context, &(common ++ [_][]const u8{ "--at-vtime-ms", try std.fmt.allocPrint(arena, "{d}", .{ms}) }));
        const at = moment_ns(text) orelse continue;
        reached += 1;
        if (at >= ms * std.time.ns_per_ms) continue;
        early += 1;
        if (ms * std.time.ns_per_ms - at > worst_ns) {
            worst_ns = ms * std.time.ns_per_ms - at;
            worst_ms = ms;
        }
    }
    expect_all(context, &.{
        .{ "every replay reached its moment", reached == count },
        .{ "none before its moment", early == 0 },
    }, "moments: {d} replays under CPU modulation, each at or after its moment ({d} early, the worst {d} ns before {d} ms)", .{
        count, early, worst_ns, worst_ms,
    });
}

/// The virtual time of a run's first timeline ("[branch    0] ... vtime=4.967s").
fn branch_vtime_ms(output: []const u8) ?u64 {
    const line_start = std.mem.indexOf(u8, output, "[branch ") orelse return null;
    const at = std.mem.indexOfPos(u8, output, line_start, " vtime=") orelse return null;
    const rest = output[at + " vtime=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, 's') orelse return null;
    const seconds = std.fmt.parseFloat(f64, rest[0..end]) catch return null;
    return @intFromFloat(seconds * 1000);
}

/// Where a replay stopped ("at moment vtime=1500000123ns").
fn moment_ns(output: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, output, "at moment vtime=") orelse return null;
    const rest = output[at + "at moment vtime=".len ..];
    const end = std.mem.indexOf(u8, rest, "ns") orelse return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

/// Egress from a deterministic machine (sdk.egress, explore --egress): det-selftest's egress
/// scenario reaches a server on this host through the allowlist and is refused one port over;
/// then the timeline replayed from its tape with the server stopped: the same answer (from the
/// tape: nothing connects), the same history.
fn check_egress(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const site = try std.fs.path.join(arena, &.{ context.scratch, "egress-site" });
    try std.Io.Dir.cwd().createDirPath(context.io, site);
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ site, "egress.txt" }),
        .data = "out of the machine and back: through a deterministic machine\n",
    });
    var server = try std.process.spawn(context.io, .{
        .argv = &.{ "python3", "-m", "http.server", "7899", "--bind", "127.0.0.1", "--directory", site },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var server_running = true;
    defer if (server_running) server.kill(context.io);
    for (0..50) |_| {
        if (curl(context, &.{"http://127.0.0.1:7899/egress.txt"})) |_| break else |_| sleep_ms(100);
    }
    const tapes = try std.fs.path.join(arena, &.{ context.scratch, "egress-tapes" });
    const explored = try explore(context, &.{
        "--program", program,          "--scenario", "egress", "--seed", "3", "--branches", "1",
        "--egress",  "127.0.0.1:7899", "--tape-dir", tapes,
    });
    var branches: [1]Branch = undefined;
    const ran = parse_branches(explored, &branches) == 1;
    // The boundary's faults (refused, reset, slow), drawn per connection: some timelines meet
    // them, their clients retry through, every one reaches the server. Sixteen timelines: a
    // timeline's two connections meet none about 68% of the time (its rate 0 to 3 eighths),
    // six together about 10% (2026-11-11: none in six after a guest change moved the draws).
    const events = try std.fs.path.join(arena, &.{ context.scratch, "egress-events" });
    const faulted = try explore(context, &.{
        "--program", program,          "--scenario",   "egress", "--seed", "4", "--branches", "16",
        "--egress",  "127.0.0.1:7899", "--events-dir", events,
    });
    var faults_seen: usize = 0;
    try events_plain(context, events);
    for (0..16) |index| {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ events, index }), arena, .limited(1 << 26)) catch continue;
        faults_seen += std.mem.count(u8, text, "\"egress_fault\"");
    }
    server.kill(context.io);
    server_running = false;
    const tape = if (ran) try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, branches[0].index }) else "";
    const replay = if (ran) try explore(context, &.{ "--program", program, "--scenario", "egress", "--tape", tape }) else "";
    var replayed: [1]Branch = undefined;
    const replayed_one = ran and parse_branches(replay, &replayed) == 1;
    const passing = "PASS always                hit in    1/1 branches, failing in    0  ";
    expect_all(context, &.{
        .{ "a timeline reaches the allowed server through det-egress", ran and std.mem.indexOf(u8, explored, passing ++ "egress reaches an allowed server") != null },
        .{ "a server not allowed is refused", ran and std.mem.indexOf(u8, explored, passing ++ "egress refuses a server not allowed") != null },
        .{ "replayed with the server stopped, the answer comes from the tape", replayed_one and std.mem.indexOf(u8, replay, passing ++ "egress reaches an allowed server") != null },
        .{ "the replay's history is the run's", replayed_one and std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash) },
        .{ "faults at the boundary happen", faults_seen > 0 },
        .{ "clients retry through them: sixteen timelines reach the server", std.mem.indexOf(u8, faulted, "PASS always                hit in   16/16 branches, failing in    0  egress reaches an allowed server") != null },
    }, "egress: explored {}, replayed {}, {d} faults in 16 timelines", .{ ran, replayed_one, faults_seen });
}

/// Ingress into a deterministic machine (sdk.ingress, explore --ingress): det-selftest's ingress
/// scenario serves HTTP in its node behind det-ingress; from here, as a person's browser would,
/// curl asks it pages through the live timeline's listener: one, two, a 100 KB upload, a 256 KiB
/// download, four at once, then /end. Then the timeline replayed from its tape with nobody
/// listening or asking: the same requests at the same moments, the same history.
fn check_ingress(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const answers = try std.fs.path.join(arena, &.{ context.scratch, "ingress-answers" });
    try cwd.createDirPath(context.io, answers);
    var payload: [100_000]u8 = undefined;
    var payload_sum: u64 = 0;
    for (&payload, 0..) |*byte, index| {
        byte.* = @intCast((index * 7) % 251);
        payload_sum += byte.*;
    }
    try cwd.writeFile(context.io, .{ .sub_path = try std.fs.path.join(arena, &.{ answers, "payload" }), .data = &payload });
    // The outside: waits for the listener (the guest's first accept opens it), then asks.
    const client = try std.fmt.allocPrint(arena,
        \\cd {s} && base=http://127.0.0.1:7897 && ask() {{ curl -s --max-time 60 -H 'Expect:' "$@"; }}
        \\for i in $(seq 1 900); do ask -o one $base/one && break; sleep 0.2; done
        \\ask -o two $base/two
        \\ask -o echo --data-binary @payload $base/echo
        \\ask -o big $base/big
        \\for c in 1 2 3 4; do ask -o c$c $base/c$c & done; wait
        \\ask -o end $base/end
    , .{answers});
    var outside = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", client }, .stdout = .ignore, .stderr = .ignore });
    var outside_running = true;
    defer if (outside_running) outside.kill(context.io);
    const tapes = try std.fs.path.join(arena, &.{ context.scratch, "ingress-tapes" });
    const explored = try explore(context, &.{
        "--program", program,          "--scenario", "ingress", "--seed", "3", "--branches", "1",
        "--ingress", "127.0.0.1:7897", "--tape-dir", tapes,
    });
    _ = outside.wait(context.io) catch {};
    outside_running = false;
    var branches: [1]Branch = undefined;
    const ran = parse_branches(explored, &branches) == 1;
    const read = struct {
        fn answer(c: *Context, directory: []const u8, name: []const u8) []const u8 {
            const path = std.fs.path.join(c.arena, &.{ directory, name }) catch return "";
            return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(1 << 20)) catch "";
        }
    };
    const echo_expected = try std.fmt.allocPrint(arena, ": /echo 100000 bytes, sum {d}\n", .{payload_sum});
    var concurrent: usize = 0;
    for ([_][]const u8{ "c1", "c2", "c3", "c4" }) |name| {
        if (std.mem.startsWith(u8, read.answer(context, answers, name), "ingress ")) concurrent += 1;
    }
    const big = read.answer(context, answers, "big");
    // Replayed with nobody listening or asking: from the tape.
    const tape = if (ran) try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, branches[0].index }) else "";
    const replay = if (ran) try explore(context, &.{ "--program", program, "--scenario", "ingress", "--tape", tape }) else "";
    var replayed: [1]Branch = undefined;
    const replayed_one = ran and parse_branches(replay, &replayed) == 1;
    const passing = "PASS always                hit in    1/1 branches, failing in    0  ingress delivers the outside's requests to the end";
    expect_all(context, &.{
        .{ "the live timeline listens and serves the outside's requests to the end", ran and std.mem.indexOf(u8, explored, passing) != null },
        .{ "the first request answered, in order", std.mem.eql(u8, read.answer(context, answers, "one"), "ingress 1: /one 0 bytes, sum 0\n") },
        .{ "a 100 KB upload arrives whole", std.mem.endsWith(u8, read.answer(context, answers, "echo"), echo_expected) },
        .{ "a 256 KiB download comes back whole", big.len == 256 * 1024 and big[0] == 'a' and big[big.len - 1] == 'a' + (4095 % 26) },
        .{ "four connections at once, each answered", concurrent == 4 },
        .{ "replayed with nobody outside, the requests come from the tape", replayed_one and std.mem.indexOf(u8, replay, passing) != null },
        .{ "the replay listens on nothing", std.mem.indexOf(u8, replay, "ingress: listening") == null },
        .{ "the replay's history is the run's", replayed_one and std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash) },
    }, "ingress: explored {}, replayed {}, {d} of 4 concurrent, download {d} bytes", .{ ran, replayed_one, concurrent, big.len });
}

/// Ingress through serve, as a person opens it: a session on a timeline with `ingress` (its
/// first step starts det-ingress in the echo node, the session live), a client here sending a
/// line through the session's listener and reading it back. The session is a timeline of the
/// run (its next number: 1), so its events answer queries and its replay, with nobody
/// connecting, delivers the same connection from its tape; a second session asking for the
/// address the first holds is refused.
fn check_ingress_session(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7893";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-ingress" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .scenario = "quiet",
        .seed = 1,
        .branches = 1,
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const ingress = "{\"branch\":0,\"until\":\"event=composer_start\",\"ingress\":{\"node\":\"echo\",\"port\":7000,\"listen\":\"127.0.0.1:7903\"}}";
    const opened = try curl(context, &.{ "-X", "POST", "-d", ingress, url ++ "/runs/1/session" });
    const Opened = struct { session: u32 = 0, timeline: ?u32 = null };
    const first = try std.json.parseFromSliceLeaky(Opened, arena, opened, .{ .ignore_unknown_fields = true });
    const session = first.session;
    const timeline = first.timeline orelse 0;
    // Its status alone (curl's --fail gives no body for a 409).
    const second = if (run_kept(context, &.{ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "-d", ingress, url ++ "/runs/1/session" })) |result| result.stdout else |_| "";
    // The client: connects once the guest's det-ingress asked (its first accept opens the
    // listener), sends a line, prints what came back.
    const client =
        \\import socket, sys, time
        \\for _ in range(120):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7903), timeout=30)
        \\        s.sendall(b"through the session\n")
        \\        data = s.recv(256)
        \\        if data:
        \\            sys.stdout.write(data.decode()); break
        \\    except OSError:
        \\        pass
        \\    time.sleep(0.5)
    ;
    const answered = run_kept(context, &.{ "python3", "-c", client }) catch null;
    const answer = if (answered) |result| result.stdout else "";
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{session}) }) catch "";
    // The session's timeline in the run: its connection found by a query, and its replay to
    // just after the connection closed (a moment named by the event).
    const query_body = try std.fmt.allocPrint(arena, "{{\"condition\":\"event=ingress_open\",\"branch\":{d},\"limit\":1}}", .{timeline});
    const queried = curl(context, &.{ "-X", "POST", "-d", query_body, url ++ "/runs/1/query" }) catch "";
    const timelines = curl(context, &.{url ++ "/runs/1/timelines"}) catch "";
    const replay_body = try std.fmt.allocPrint(arena, "{{\"branch\":{d},\"until\":\"event=ingress_close\",\"exec\":\":\"}}", .{timeline});
    const replayed = curl(context, &.{ "-X", "POST", "-d", replay_body, url ++ "/runs/1/replay" }) catch "";
    expect_all(context, &.{
        .{ "a session opened with ingress", session > 0 },
        .{ "it is the run's next timeline: 1", timeline == 1 },
        .{ "a second session on the address it holds is refused (409)", std.mem.eql(u8, second, "409") },
        .{ "a client here reaches the node's port through the session's listener", std.mem.eql(u8, answer, "through the session\n") },
        .{ "the run lists the session's timeline, extending timeline 0", std.mem.indexOf(u8, timelines, "\"index\":1,") != null and std.mem.indexOf(u8, timelines, "\"extends\":0,") != null },
        .{ "a query finds the connection in the session's timeline", std.mem.indexOf(u8, queried, "\"event\":\"ingress_open\"") != null },
        .{ "the timeline's replay delivers the connection from its tape", std.mem.indexOf(u8, replayed, "ingress_open") != null and std.mem.indexOf(u8, replayed, "ingress_close") != null },
        .{ "the replay listens on nothing", std.mem.indexOf(u8, replayed, "ingress: listening") == null },
    }, "ingress session {d}, timeline {d}: answered {s}, replay {d} bytes", .{ session, timeline, std.mem.trim(u8, answer, "\n"), replayed.len });
}

/// A session's checkpoint through serve, as a person resumes a REPL after a crash: a session on
/// a run's timeline writes a file, takes a checkpoint (det:checkpoint loaded), writes another and
/// ends. A session opened on its timeline at the checkpoint's event starts from the machine saved
/// there, not from boot: the first file is there, the second not. The checkpoint is one of the
/// run's replay snapshots; with them gone, the same session opened again replays from boot to the
/// same history (the saved machine is the timeline's).
fn check_session_checkpoint(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7896";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-checkpoint" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .scenario = "quiet",
        .seed = 1,
        .branches = 1,
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const Reply = struct { session: u32 = 0, timeline: ?u32 = null, output: []const u8 = "" };
    const opened = try std.json.parseFromSliceLeaky(Reply, arena, try curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0,\"until\":\"event=composer_start\"}", url ++ "/runs/1/session" }), .{ .ignore_unknown_fields = true });
    const timeline = opened.timeline orelse 0;
    const step_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{opened.session});
    var said: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "echo before > /tmp/checkpoint-a", "det:checkpoint loaded", "echo after > /tmp/checkpoint-b" }) |step| {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .exec = step }, .{})});
        const reply = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", body, step_url }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
        try said.appendSlice(arena, reply.output);
    }
    const ended = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{opened.session}) }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
    try said.appendSlice(arena, ended.output);
    const saved = std.mem.indexOf(u8, said.items, "[determinismo] checkpoint: {\"name\":\"loaded\",") != null and
        std.mem.indexOf(u8, said.items, "\"saved\":true}") != null;
    const written = std.mem.indexOf(u8, said.items, "snapshot written ") != null;
    // The session from the checkpoint, its first step reading both files; a session at the same
    // event of that session's timeline (its part before the moment is the first's); then the
    // first again from boot.
    var resumed: [3][]const u8 = undefined;
    var hashes: [3][]const u8 = undefined;
    var walls_ms: [3]u64 = undefined;
    var timelines: [3]u32 = undefined;
    for (&resumed, &hashes, &walls_ms, &timelines, 0..) |*output, *hash, *wall_ms, *own, attempt| {
        // The last: the run's replay snapshots gone, the timeline replayed from boot.
        if (attempt == 2) try std.Io.Dir.cwd().deleteTree(context.io, try std.fs.path.join(arena, &.{ data, "runs", "1", "replays" }));
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
            .branch = if (attempt == 1) timelines[0] else timeline,
            .until = "event=session_checkpoint details.name=loaded",
            .exec = "cat /tmp/checkpoint-a; test -e /tmp/checkpoint-b && echo second there || echo second absent",
        }, .{})});
        const started_ns = monotonic_ns();
        const reply = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", body, url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
        wall_ms.* = (monotonic_ns() - started_ns) / std.time.ns_per_ms;
        own.* = reply.timeline orelse 0;
        const end = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{reply.session}) }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
        output.* = try std.mem.concat(arena, u8, &.{ reply.output, end.output });
        var branch: [1]Branch = undefined;
        hash.* = if (parse_branches(output.*, &branch) == 1) branch[0].events_hash else "";
    }
    const from_checkpoint = try std.fmt.allocPrint(arena, "[determinismo] on from b{d}-", .{timeline});
    const texts = try exec_texts(arena, resumed[0]);
    const both = std.mem.join(arena, "", texts) catch "";
    expect_all(context, &.{
        .{ "a session on the run's timeline: its next, 1", timeline == 1 },
        .{ "its checkpoint said, saved", saved },
        .{ "and written before the session's end answered", written },
        .{ "a session opened at the checkpoint's event starts from it, not from boot", std.mem.indexOf(u8, resumed[0], from_checkpoint) != null },
        .{ "there, what the session did before the checkpoint", std.mem.indexOf(u8, both, "before\n") != null },
        .{ "and not what it did after", std.mem.indexOf(u8, both, "second absent\n") != null },
        .{ "a session at the event on that session's timeline starts from the first's checkpoint", timelines[1] > timelines[0] and std.mem.indexOf(u8, resumed[1], from_checkpoint) != null },
        .{ "with the run's replay snapshots gone, the first's replays from boot", std.mem.indexOf(u8, resumed[2], "[determinismo] on from b") == null },
        .{ "the three, the same history", hashes[0].len > 0 and std.mem.eql(u8, hashes[0], hashes[1]) and std.mem.eql(u8, hashes[0], hashes[2]) },
    }, "checkpoint: timeline {d}; from it {d} ms, again from the second session's timeline {d} ms, from boot {d} ms; events {s} {s} {s}", .{ timeline, walls_ms[0], walls_ms[1], walls_ms[2], hashes[0], hashes[1], hashes[2] });
}

/// Ingress across a checkpoint: a session with a relay into a node's port, a client connected
/// and still connected when the session takes a checkpoint and ends; a session resumed at the
/// checkpoint answers a new client through its own listener. The resumed machine holds the first
/// session's connection in its relay (its process waits on it), so the new connection must not
/// take its number: the next number is the machine's, kept with its snapshot.
fn check_ingress_checkpoint(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7899";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-ingress-checkpoint" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .scenario = "quiet", .seed = 1, .branches = 1 }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const Reply = struct { session: u32 = 0, timeline: ?u32 = null, output: []const u8 = "" };
    const ingress = "{\"node\":\"echo\",\"port\":7000,\"listen\":\"127.0.0.1:7905\"}";
    const opened = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0,\"until\":\"event=composer_start\",\"ingress\":" ++ ingress ++ "}", url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
    // The first client: a line echoed, then the connection held open (a REPL's editor).
    const holder =
        \\import socket, sys, time
        \\for _ in range(120):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7905), timeout=30); break
        \\    except OSError:
        \\        time.sleep(0.5)
        \\s.sendall(b"before the checkpoint\n")
        \\sys.stdout.write(s.recv(256).decode()); sys.stdout.flush()
        \\time.sleep(600)
    ;
    const held_out = try std.fs.path.join(arena, &.{ context.scratch, "ingress-checkpoint-held.txt" });
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "exec python3 -c '{s}' > '{s}'", .{ holder, held_out });
    var held = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", command.items }, .stdout = .ignore, .stderr = .ignore });
    defer held.kill(context.io);
    var echoed: []const u8 = "";
    for (0..240) |_| {
        echoed = std.Io.Dir.cwd().readFileAlloc(context.io, held_out, arena, .limited(4096)) catch "";
        if (echoed.len > 0) break;
        sleep_ms(500);
    }
    const step_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{opened.session});
    const checkpoint = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", "{\"exec\":\"det:checkpoint held\"}", step_url }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{opened.session}) }) catch "";
    // At the checkpoint again, the first client's connection still in the machine: a new one.
    const resume_body = try std.fmt.allocPrint(arena, "{{\"branch\":{d},\"until\":\"event=session_checkpoint details.name=held\",\"ingress\":{s}}}", .{ opened.timeline orelse 0, ingress });
    const resumed = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", resume_body, url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
    const client =
        \\import socket, sys, time
        \\for _ in range(120):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7905), timeout=30)
        \\        s.sendall(b"after the checkpoint\n")
        \\        data = s.recv(256)
        \\        if data:
        \\            sys.stdout.write(data.decode()); break
        \\    except OSError:
        \\        pass
        \\    time.sleep(0.5)
    ;
    const answered = run_kept(context, &.{ "python3", "-c", client }) catch null;
    const answer = if (answered) |result| result.stdout else "";
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{resumed.session}) }) catch "";
    // The resumed session's connection: its number the one after the first session's (whose
    // relay process is still in the machine), not 1 again.
    const last_open = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .condition = "event=ingress_open",
        .not_followed_by = "event=ingress_open",
        .branch = resumed.timeline orelse 0,
        .limit = 1,
    }, .{})});
    const found = curl(context, &.{ "-X", "POST", "-d", last_open, url ++ "/runs/1/query" }) catch "";
    const Found = struct { event: struct { details: struct { id: u32 = 0 } = .{} } = .{} };
    const opened_id = (std.json.parseFromSliceLeaky(Found, arena, std.mem.sliceTo(found, '\n'), .{ .ignore_unknown_fields = true }) catch Found{}).event.details.id;
    expect_all(context, &.{
        .{ "a client through the session's relay, answered", std.mem.eql(u8, echoed, "before the checkpoint\n") },
        .{ "the session's checkpoint saved, the client still connected", std.mem.indexOf(u8, checkpoint.output, "\"saved\":true") != null },
        .{ "a session resumed at the checkpoint starts from it", std.mem.indexOf(u8, resumed.output, "[determinismo] on from b") != null },
        .{ "and a new client through its relay is answered", std.mem.eql(u8, answer, "after the checkpoint\n") },
        .{ "as connection 2: the first session's 1 is still the machine's", opened_id == 2 },
    }, "ingress checkpoint: first {s}, after the checkpoint {s} as connection {d}", .{ std.mem.trim(u8, echoed, "\n"), std.mem.trim(u8, answer, "\n"), opened_id });
}

/// Ingress when its node dies: a session with a relay into the echo node's port, a client asking
/// the node to crash (its main process, the first of its PID namespace: every process there ends
/// with it). The client sees its connection close at once, not when its own timeout gives up;
/// the node started again (a session step, which ends: the node's forwarder keeps none of the
/// step's output open), a new client is served: the relay outlives the node.
fn check_ingress_crash(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7890";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-ingress-crash" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .scenario = "quiet", .seed = 1, .branches = 1 }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const Reply = struct { session: u32 = 0, timeline: ?u32 = null, output: []const u8 = "" };
    const ingress = "{\"node\":\"echo\",\"port\":7000,\"listen\":\"127.0.0.1:7907\"}";
    const opened = std.json.parseFromSliceLeaky(Reply, arena, curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0,\"until\":\"event=composer_start\",\"ingress\":" ++ ingress ++ "}", url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Reply{};
    // The crash asked through the relay: how long until the connection ends ("closed <s>"), or
    // "waiting" if it is still open after 30 s.
    const crasher =
        \\import socket, sys, time
        \\for _ in range(240):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7907), timeout=30); break
        \\    except OSError:
        \\        time.sleep(0.5)
        \\s.sendall(b"crash\n")
        \\started = time.monotonic()
        \\try:
        \\    while s.recv(256): pass
        \\    sys.stdout.write("closed %.1f" % (time.monotonic() - started))
        \\except socket.timeout:
        \\    sys.stdout.write("waiting")
        \\except OSError:
        \\    sys.stdout.write("closed %.1f" % (time.monotonic() - started))
    ;
    const crashed = run_kept(context, &.{ "python3", "-c", crasher }) catch null;
    const crash_said = if (crashed) |result| result.stdout else "";
    const closed_s: f64 = if (std.mem.startsWith(u8, crash_said, "closed "))
        std.fmt.parseFloat(f64, crash_said["closed ".len..]) catch 1e9
    else
        1e9;
    // The node started again, then a new client through the same session's listener.
    const step_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{opened.session});
    // Bounded: a step whose output never ends (a node's forwarder holding it) never answers.
    const started_said = if (run_kept(context, &.{ "curl", "-s", "-m", "120", "-X", "POST", "-d", "{\"exec\":\"det-nodes start echo && echo started\"}", step_url })) |result| result.stdout else |_| "{}";
    const started = std.json.parseFromSliceLeaky(Reply, arena, started_said, .{ .ignore_unknown_fields = true }) catch Reply{};
    const client =
        \\import socket, sys, time
        \\for _ in range(6):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7907), timeout=10)
        \\        s.sendall(b"after the crash\n")
        \\        data = s.recv(256)
        \\        if data:
        \\            sys.stdout.write(data.decode()); break
        \\    except OSError:
        \\        pass
        \\    time.sleep(0.5)
    ;
    const answered = run_kept(context, &.{ "python3", "-c", client }) catch null;
    const answer = if (answered) |result| result.stdout else "";
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{opened.session}) }) catch "";
    expect_all(context, &.{
        .{ "a session with a relay into the echo node", opened.session > 0 },
        .{ "the node's crash closes the client's connection at once (under 10 s)", closed_s < 10 },
        .{ "the node started again", std.mem.indexOf(u8, started.output, "started") != null },
        .{ "and a new client through the same listener is served", std.mem.eql(u8, answer, "after the crash\n") },
    }, "ingress crash: the crash's client {s}, after the start {s}", .{ crash_said, std.mem.trim(u8, answer, "\n") });
}

/// docs/DEBUGGING.md: a watched replay is the recorded history and logs the guest's writes; a
/// fork with a poke goes on from the changed memory, and its branch replays from its tape (the
/// poke on it). What is watched and poked: the guest kernel's jiffies, written every tick, its
/// address read at the moment from /proc/kallsyms (nokaslr, loaded where linked: physical =
/// virtual - 0xffffffff80000000). Not a wider range: the kernel's page tables live in its image,
/// and a read-only page under them stops the guest (the CPU's accessed and dirty bits).
fn check_debugging(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-tapes" });
    const record = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-record.jsonl" });
    const base = try explore(context, &.{
        "--program",   program, "--scenario", "bank", "--seed",     "11",  "--timeline", "30s",
        "--branching", "flat",  "--branches", "1",    "--tape-dir", tapes, "--record",   record,
    });
    var recorded: [1]Branch = undefined;
    expect(context, parse_branches(base, &recorded) == 1, "debugging: recorded one timeline", .{});
    const tape = try std.fs.path.join(context.arena, &.{ tapes, "branch-0.jsonl" });
    const symbols = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec", "grep ' jiffies$' /proc/kallsyms" });
    const at = std.mem.indexOf(u8, symbols, " D jiffies") orelse std.mem.indexOf(u8, symbols, " d jiffies") orelse {
        const shown = if (std.mem.indexOf(u8, symbols, "exec_output")) |i| symbols[i..@min(symbols.len, i + 200)] else symbols[symbols.len -| 400..];
        expect(context, false, "debugging: the guest kernel's jiffies found in /proc/kallsyms ({s})", .{shown});
        return;
    };
    const start = std.mem.lastIndexOfAny(u8, symbols[0..at], " \"\n") orelse 0;
    const virtual = try std.fmt.parseInt(u64, std.mem.trim(u8, symbols[start..at], " \"\n"), 16);
    const physical = virtual - 0xffffffff80000000;
    const watch = try std.fmt.allocPrint(context.arena, "0x{x}:8", .{physical});
    const poke = try std.fmt.allocPrint(context.arena, "0x{x}=00000000", .{physical});
    const poked = try std.fmt.allocPrint(context.arena, "[determinismo] poke: 0x{x}", .{physical});
    const look: []const []const u8 = &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec", "true" };
    const plain = try explore(context, look);
    const watched = try explore(context, try std.mem.concat(context.arena, []const u8, &.{ look, &.{ "--watch", watch } }));
    var plain_branch: [1]Branch = undefined;
    var watched_branch: [1]Branch = undefined;
    const both = parse_branches(plain, &plain_branch) == 1 and parse_branches(watched, &watched_branch) == 1;
    expect_all(context, &.{
        .{ "the watched replay's events hash is the plain one's", both and std.mem.eql(u8, plain_branch[0].events_hash, watched_branch[0].events_hash) },
        .{ "it logged the guest's writes there", std.mem.indexOf(u8, watched, "[determinismo] watch: {") != null },
    }, "debugging: a watched replay of jiffies ({s}) keeps the recorded history", .{watch});
    // The debugger's steps at the moment: registers, memory read, poked, read again.
    const script = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-steps.txt" });
    const steps = try std.fmt.allocPrint(context.arena, "det:regs\ndet:translate current 0x{x}\ndet:mem 0x{x} 8\ndet:poke 0x{x}=00000000\ndet:mem 0x{x} 8\n", .{ virtual, physical, physical, physical });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = steps });
    const stepped = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", script });
    const zeros = try std.fmt.allocPrint(context.arena, "\"address\":\"0x{x}\",\"size\":8,\"hex\":\"0000000000000000\"", .{physical});
    expect_all(context, &.{
        .{ "det:regs printed the vCPU's registers", std.mem.indexOf(u8, stepped, "[determinismo] regs: {\"vtime_ns\":3000") != null },
        .{ "det:regs said the vector registers too (xmm0 to xmm7)", std.mem.indexOf(u8, stepped, "\"xmm0\":\"0x") != null and std.mem.indexOf(u8, stepped, "\"xmm7\":\"0x") != null },
        .{ "det:mem printed memory", std.mem.indexOf(u8, stepped, "[determinismo] mem: {") != null },
        .{ "det:translate walked the page tables to jiffies' physical address", std.mem.indexOf(u8, stepped, try std.fmt.allocPrint(context.arena, "\"physical\":\"0x{x}\"", .{physical})) != null },
        .{ "det:poke changed it, det:mem read it back", std.mem.indexOf(u8, stepped, zeros) != null },
    }, "debugging: the debugger's steps at a moment", .{});
    // Breakpoints and steps: stopped on the kernel's schedule (its first instruction), on 1000
    // branches, and the history to 5 s the plain replay's.
    const scheduler = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec", "grep ' T schedule$' /proc/kallsyms" });
    // In the command's output, not its echo (the grep itself names " T schedule").
    const output_at = std.mem.indexOf(u8, scheduler, "\"exec_output\"") orelse 0;
    const schedule_at = std.mem.indexOfPos(u8, scheduler, output_at, " T schedule") orelse {
        expect(context, false, "debugging: the guest kernel's schedule found in /proc/kallsyms", .{});
        return;
    };
    const schedule_start = std.mem.lastIndexOfAny(u8, scheduler[0..schedule_at], " \"\n") orelse 0;
    const schedule = try std.fmt.parseInt(u64, std.mem.trim(u8, scheduler[schedule_start..schedule_at], " \"\n"), 16);
    const stops = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-stops.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = stops, .data = try std.fmt.allocPrint(context.arena, "det:break 0x{x}\ndet:continue 1000\ndet:regs\ndet:step 1000\ndet:regs\ndet:break off\ndet:at 5000000000\ntrue\n", .{schedule}) });
    const plain_to = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-plain.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = plain_to, .data = "det:at 5000000000\ntrue\n" });
    const stopped = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", stops });
    const unstopped = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", plain_to });
    var stopped_branch: [1]Branch = undefined;
    var unstopped_branch: [1]Branch = undefined;
    const rip = try std.fmt.allocPrint(context.arena, "\"rip\":\"0x{x}\",\"cr3\"", .{schedule});
    expect_all(context, &.{
        .{ "det:continue stopped on the breakpoint (schedule's first instruction)", std.mem.indexOf(u8, stopped, rip) != null },
        .{ "det:step ran on from it", std.mem.count(u8, stopped, "[determinismo] regs: {") == 2 },
        .{ "the history to 5 s is the plain replay's", parse_branches(stopped, &stopped_branch) == 1 and parse_branches(unstopped, &unstopped_branch) == 1 and
            std.mem.eql(u8, stopped_branch[0].events_hash, unstopped_branch[0].events_hash) },
    }, "debugging: a breakpoint and a step stop where asked and change nothing", .{});
    // A watched write: jiffies (the kernel's, any address space) twice, each stop after the
    // tick's write with the value written, det:mem reading the same, the history to 5 s the
    // plain replay's.
    const watches = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-watches.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = watches, .data = try std.fmt.allocPrint(context.arena, "det:watch 0x{x} 8\ndet:continue 1000\ndet:continue 1000\ndet:mem 0x{x} 8\ndet:watch off\ndet:at 5000000000\ntrue\n", .{ virtual, physical }) });
    const watched_steps = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", watches });
    const hit_prefix = try std.fmt.allocPrint(context.arena, "\"watch\":\"0x{x}\",\"size\":8,\"hex\":\"", .{virtual});
    var values: [2]u64 = .{ 0, 0 };
    var hexes: [2][]const u8 = .{ "", "" };
    var hits: usize = 0;
    var from: usize = 0;
    while (hits < values.len) : (hits += 1) {
        const at_hit = std.mem.indexOfPos(u8, watched_steps, from, hit_prefix) orelse break;
        const hex = watched_steps[at_hit + hit_prefix.len ..][0..@min(16, watched_steps.len - at_hit - hit_prefix.len)];
        var bytes: [8]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex) catch break;
        values[hits] = std.mem.readInt(u64, &bytes, .little);
        hexes[hits] = hex;
        from = at_hit + hit_prefix.len;
    }
    const read_back = if (hits == 2) try std.fmt.allocPrint(context.arena, "\"address\":\"0x{x}\",\"size\":8,\"hex\":\"{s}\"", .{ physical, hexes[1] }) else "";
    var watched_branch_to: [1]Branch = undefined;
    expect_all(context, &.{
        .{ "det:continue stopped at two writes of jiffies, each with its value", hits == 2 },
        .{ "the second value is past the first", hits == 2 and values[1] > values[0] },
        .{ "det:mem read the second value there", hits == 2 and std.mem.indexOf(u8, watched_steps, read_back) != null },
        .{ "the history to 5 s is the plain replay's", parse_branches(watched_steps, &watched_branch_to) == 1 and
            std.mem.eql(u8, watched_branch_to[0].events_hash, unstopped_branch[0].events_hash) },
    }, "debugging: a watched variable's writes stop with their values and change nothing (jiffies {d}, {d})", .{ values[0], values[1] });
    // A window of hits without stops (det:collect): jiffies' writes for 20 ms, then the
    // scheduler's calls for 100 ms with their argument registers, each said as it passed, the
    // first of them the stop det:continue makes from the same moment, the history to 5 s the
    // plain replay's. (The guest can idle for tens of milliseconds there: a 5 ms window had
    // no call once the initramfs grew, 2026-11-18, and det:continue's first stop was 26 ms on.)
    const collects = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-collects.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = collects, .data = try std.fmt.allocPrint(context.arena, "det:watch 0x{x} 8\ndet:collect 20\ndet:watch off\ndet:break 0x{x}\ndet:collect 100\ndet:break off\ndet:at 5000000000\ntrue\n", .{ virtual, schedule }) });
    const collected = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", collects });
    const collect_stops = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-collect-stops.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = collect_stops, .data = try std.fmt.allocPrint(context.arena, "det:watch 0x{x} 8\ndet:collect 20\ndet:watch off\ndet:break 0x{x}\ndet:continue 1000\ndet:break off\ndet:at 5000000000\ntrue\n", .{ virtual, schedule }) });
    const stopped_call = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", collect_stops });
    const write_prefix = try std.fmt.allocPrint(context.arena, "\"watch\":\"0x{x}\",\"size\":8,\"hex\":\"", .{virtual});
    var writes: u32 = 0;
    var increasing = true;
    var last_value: u64 = 0;
    var at_write: usize = 0;
    while (std.mem.indexOfPos(u8, collected, at_write, write_prefix)) |found| {
        const start_of_line = std.mem.lastIndexOfScalar(u8, collected[0..found], '\n') orelse 0;
        at_write = found + write_prefix.len;
        if (std.mem.indexOf(u8, collected[start_of_line..found], "[determinismo] hit: {") == null) continue;
        if (at_write + 16 > collected.len) break;
        var bytes: [8]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, collected[at_write..][0..16]) catch break;
        const value = std.mem.readInt(u64, &bytes, .little);
        if (writes > 0 and value <= last_value) increasing = false;
        last_value = value;
        writes += 1;
    }
    const said_writes = try std.fmt.allocPrint(context.arena, "[determinismo] collect: {{\"hits\":{d},\"dropped\":0}}", .{writes});
    const call_hit = try std.fmt.allocPrint(context.arena, "\"rip\":\"0x{x}\",\"cr3\":", .{schedule});
    const calls = std.mem.count(u8, collected, call_hit);
    const first_call = first_moment(collected, "[determinismo] hit: ", call_hit);
    const first_stop = first_moment(stopped_call, "[determinismo] break: ", call_hit);
    var collected_branch: [1]Branch = undefined;
    expect_all(context, &.{
        .{ "jiffies' writes said as they passed, one more each", writes >= 10 and increasing },
        .{ "the window's count is theirs, none dropped", std.mem.indexOf(u8, collected, said_writes) != null },
        .{ "the scheduler's calls said with their argument registers", calls > 0 and std.mem.indexOf(u8, collected, "\",\"rdi\":\"0x") != null },
        .{ "the first call said is the stop det:continue makes from the same moment", first_call != null and first_stop != null and
            std.mem.eql(u8, first_call.?, first_stop.?) },
        .{ "the history to 5 s is the plain replay's", parse_branches(collected, &collected_branch) == 1 and
            std.mem.eql(u8, collected_branch[0].events_hash, unstopped_branch[0].events_hash) },
    }, "debugging: windows of hits without stops (det:collect: {d} writes in 20 ms, {d} calls in 100 ms)", .{ writes, calls });
    try check_debugging_symbol(context);
    const forks = try std.fs.path.join(context.arena, &.{ context.scratch, "debugging-forks" });
    const forked = try explore(context, &.{
        "--program",   program, "--scenario",    "bank", "--seed",          "11",   "--timeline",  "30s",
        "--branching", "flat",  "--from-branch", "0",    "--from-vtime-ms", "3000", "--from-poke", poke,
        "--branches",  "1",     "--tape-dir",    forks,
    });
    var fork_branch: [1]Branch = undefined;
    const one = parse_branches(forked, &fork_branch) == 1;
    const fork_tape = try std.fs.path.join(context.arena, &.{ forks, "branch-0.jsonl" });
    const again = try explore(context, &.{ "--program", program, "--scenario", "bank", "--timeline", "30s", "--tape", fork_tape });
    var again_branch: [1]Branch = undefined;
    expect_all(context, &.{
        .{ "the fork wrote the poke", std.mem.indexOf(u8, forked, poked) != null },
        .{ "its timeline is not the original's", one and !std.mem.eql(u8, fork_branch[0].events_hash, recorded[0].events_hash) },
        .{ "its tape replays it, the poke again", parse_branches(again, &again_branch) == 1 and one and
            std.mem.eql(u8, again_branch[0].events_hash, fork_branch[0].events_hash) and std.mem.indexOf(u8, again, poked) != null },
    }, "debugging: a fork with a poke goes on from it and replays from its tape", .{});
}

/// A node's variable by its name (det-nodes symbol): the selftest echo node's count of the
/// connections it accepted (selftest_accepted), found in its process at 3 s, read at its
/// physical address, watched at its virtual one while a guest command connects (steady's own
/// drivers connect once in its 10 s): the write the watch stops at is that connection's.
fn check_debugging_symbol(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const tapes = try std.fs.path.join(arena, &.{ context.scratch, "debugging-symbol" });
    const common = [_][]const u8{ "--program", program, "--scenario", "steady", "--seed", "1", "--timeline", "10s" };
    _ = try explore(context, &(common ++ [_][]const u8{ "--branching", "flat", "--branches", "1", "--tape-dir", tapes }));
    const tape = try std.fs.path.join(arena, &.{ tapes, "branch-0.jsonl" });
    const named = try explore(context, &(common ++ [_][]const u8{ "--tape", tape, "--at-vtime-ms", "3000", "--exec", "det-nodes symbol echo selftest_accepted; det-nodes list" }));
    // Its JSON line inside the exec_output event's text, quotes escaped there.
    const address = hex_after(named, "address\\\":\\\"0x");
    const physical = hex_after(named, "physical\\\":\\\"0x");
    const object = std.mem.indexOf(u8, named, "kind\\\":\\\"object") != null;
    // A page of the process's own beside it (its stack's top), there now.
    const probe = hex_after(named, "probe\\\":{\\\"address\\\":\\\"0x") != null and
        std.mem.indexOf(u8, named, "probe\\\":null") == null;
    const echo_prefix = "\\\"name\\\":\\\"echo\\\"";
    const address_key = "address\\\":\\\"";
    const echo_at = std.mem.indexOf(u8, named, echo_prefix);
    const ip_at = if (echo_at) |at| if (std.mem.indexOfPos(u8, named, at, address_key)) |key| key + address_key.len else null else null;
    const ip_end = if (ip_at) |at| std.mem.indexOfScalarPos(u8, named, at, '\\') else null;
    if (address == null or physical == null or ip_end == null) {
        const shown = if (std.mem.indexOf(u8, named, "exec_output")) |i| named[i..@min(named.len, i + 300)] else named[named.len -| 300..];
        expect(context, false, "debugging: det-nodes symbol named the echo node's selftest_accepted ({s})", .{shown});
        return;
    }
    const script = try std.fs.path.join(arena, &.{ context.scratch, "debugging-symbol.txt" });
    const ip = named[ip_at.?..ip_end.?];
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = try std.fmt.allocPrint(arena, "det:mem 0x{x} 8\ndet:watch 0x{x} 8\ndet:background echo ping | nc -w 1 {s} 7000\ndet:continue 3000\ndet:mem 0x{x} 8\ndet:watch off\n", .{ physical.?, address.?, ip, physical.? }) });
    const watched = try explore(context, &(common ++ [_][]const u8{ "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", script }));
    const read_prefix = try std.fmt.allocPrint(arena, "\"address\":\"0x{x}\",\"size\":8,\"hex\":\"", .{physical.?});
    const before = little_u64_after(watched, read_prefix, 0);
    const hit_prefix = try std.fmt.allocPrint(arena, "\"watch\":\"0x{x}\",\"size\":8,\"hex\":\"", .{address.?});
    const hit = little_u64_after(watched, hit_prefix, 0);
    const after_at = if (std.mem.indexOf(u8, watched, read_prefix)) |first| first + read_prefix.len else 0;
    const after = little_u64_after(watched, read_prefix, after_at);
    expect_all(context, &.{
        .{ "det-nodes symbol said where it is: an object, its address and its page", object },
        .{ "and a page of its process's own to tell its address space by (a probe)", probe },
        .{ "its value read at its physical address", before != null },
        .{ "det:watch at its address stopped at the next connection's write, one more", before != null and hit != null and hit.? == before.? + 1 },
        .{ "read again there, the value the stop said", hit != null and after != null and after.? == hit.? },
    }, "debugging: a node's variable by its name (selftest_accepted at 0x{x}, page 0x{x}: {?d}, then {?d})", .{ address.?, physical.?, before, hit });
    // A structure's fields by their paths, typed by the node's DWARF: selftest_stats whole,
    // its last_client and its ratio (half its count), the ratio watched as a double.
    const typed = try explore(context, &(common ++ [_][]const u8{
        "--tape",                                                                                                                                             tape, "--at-vtime-ms", "3000", "--exec",
        "det-nodes symbol echo selftest_stats; det-nodes symbol echo selftest_stats --field last_client; det-nodes symbol echo selftest_stats --field ratio",
    }));
    const whole_at = std.mem.indexOf(u8, typed, "address\\\":\\\"0x") orelse 0;
    const base = hex_after(typed[whole_at..], "address\\\":\\\"0x");
    const aggregate = std.mem.indexOf(u8, typed, "kind\\\":\\\"aggregate\\\",\\\"size\\\":24") != null;
    const client_at = std.mem.indexOf(u8, typed, "field\\\":\\\"last_client");
    const ratio_at = std.mem.indexOf(u8, typed, "field\\\":\\\"ratio");
    // Each line's own address comes before its field: the last address before it.
    const address_before = struct {
        fn of(text: []const u8, end: usize) ?u64 {
            const key = "address\\\":\\\"0x";
            const at = std.mem.lastIndexOf(u8, text[0..end], key) orelse return null;
            return hex_after(text[at..end], key);
        }
    }.of;
    const client_address = if (client_at) |at| address_before(typed, at) else null;
    const ratio_address = if (ratio_at) |at| address_before(typed, at) else null;
    const client_typed = std.mem.indexOf(u8, typed, "kind\\\":\\\"signed\\\",\\\"size\\\":4") != null;
    const ratio_typed = std.mem.indexOf(u8, typed, "kind\\\":\\\"float\\\",\\\"size\\\":8") != null;
    var ratio_hit: ?f64 = null;
    if (ratio_address) |watched_address| {
        const ratio_script = try std.fs.path.join(arena, &.{ context.scratch, "debugging-ratio.txt" });
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = ratio_script, .data = try std.fmt.allocPrint(arena, "det:watch 0x{x} 8\ndet:background echo ping | nc -w 1 {s} 7000\ndet:continue 3000\ndet:watch off\n", .{ watched_address, ip }) });
        const ratio_watched = try explore(context, &(common ++ [_][]const u8{ "--tape", tape, "--at-vtime-ms", "3000", "--exec-script", ratio_script }));
        const ratio_prefix = try std.fmt.allocPrint(arena, "\"watch\":\"0x{x}\",\"size\":8,\"hex\":\"", .{watched_address});
        if (little_u64_after(ratio_watched, ratio_prefix, 0)) |bits| ratio_hit = @bitCast(bits);
    }
    const expected_ratio: ?f64 = if (before) |count| @as(f64, @floatFromInt(count + 1)) / 2.0 else null;
    expect_all(context, &.{
        .{ "the structure whole: an aggregate of 24 bytes", aggregate and base != null },
        .{ "last_client 8 bytes in, a signed 4-byte integer", base != null and client_address != null and client_address.? == base.? + 8 and client_typed },
        .{ "ratio 16 bytes in, an 8-byte float", base != null and ratio_address != null and ratio_address.? == base.? + 16 and ratio_typed },
        .{ "ratio watched: the connection's write, half the count", ratio_hit != null and expected_ratio != null and ratio_hit.? == expected_ratio.? },
    }, "debugging: a structure's fields by their paths, typed by DWARF (selftest_stats at 0x{x}: ratio {?d})", .{ base orelse 0, ratio_hit });
}

/// The hexadecimal number right after `prefix` in `text`, or null.
fn hex_after(text: []const u8, prefix: []const u8) ?u64 {
    const at = (std.mem.indexOf(u8, text, prefix) orelse return null) + prefix.len;
    var end = at;
    while (end < text.len and std.ascii.isHex(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[at..end], 16) catch null;
}

/// The 8 bytes of hex (memory order) right after `prefix` (its first at or past `from`), as a
/// little-endian number, or null.
fn little_u64_after(text: []const u8, prefix: []const u8, from: usize) ?u64 {
    const at = (std.mem.indexOfPos(u8, text, from, prefix) orelse return null) + prefix.len;
    if (at + 16 > text.len) return null;
    var bytes: [8]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[at..][0..16]) catch return null;
    return std.mem.readInt(u64, &bytes, .little);
}

/// The REPL's client (clients/clojure, under babashka) against a serve: a session at a moment
/// of a selftest run, its registers, a variable and a structure's field by their names (their
/// types from DWARF, the field 16 bytes in), the field's writes after two of the guest's
/// connections (half a connection each), a function's call with its argument (the connection's
/// descriptor, also by its parameter's name and type from DWARF), and `across`: a look at the condition's first match in the run's two timelines
/// (the session's own, a third, left out). Judged in the script, said as `ok <name>` or
/// `bad <name> <values>` a line. Every name is looked up before the connection it is to see:
/// det-nodes symbol runs the guest on while it reads the module's DWARF, and a connection
/// started first was served before the watch or the breakpoint was there.
fn check_client(context: *Context) !void {
    const bb = context.bb orelse {
        std.debug.print("SKIP client: no babashka (-Dbb or $DETERMINISMO_BB)\n", .{});
        return;
    };
    const arena = context.arena;
    const address = "127.0.0.1:7887";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-client" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .scenario = "steady",
        .seed = 1,
        .branches = 2,
        .branching = "flat",
        .timeline = "10s",
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    var run: []const u8 = "";
    for (0..1200) |_| {
        run = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const script = try std.fs.path.join(arena, &.{ context.scratch, "client.clj" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = try std.fmt.allocPrint(arena,
        \\(require '[determinismo.api :as api] '[determinismo.debug :as d] '[clojure.string :as str])
        \\(def unhex (deref (resolve 'determinismo.debug/unhex)))
        \\(defn number [x] (if (string? x) (unhex x) x))
        \\(defn echo-of [s] (first (filter (fn [n] (= "echo" (:name n))) (d/nodes s))))
        \\(defn connect [s n]
        \\  (d/step s (str "det:background sh -c 'for i in $(seq " n "); do echo ping | nc -w 1 "
        \\                 (:address (echo-of s)) " 7000; done'")))
        \\(defn said [name ok & values] (println (if ok "ok" "bad") name (pr-str values)))
        \\(binding [api/*url* "{s}"]
        \\  (let [condition "event=node_sample details.node=echo"
        \\        s (d/open 1 {{:branch 0 :until condition}})
        \\        regs (d/regs s)
        \\        accepted (d/symbol s :echo :selftest_accepted)
        \\        stats (d/symbol s "echo" "selftest_stats")
        \\        ratio (d/symbol s 'echo 'selftest_stats {{:field ".ratio"}})
        \\        _ (connect s 2)
        \\        ratios (mapv :value (d/watch-values s ratio {{:limit 2 :ms 3000}}))
        \\        serve-fn (d/symbol s :echo :selftest_serve)
        \\        _ (connect s 1)
        \\        served (d/calls s serve-fn {{:limit 1 :ms 3000}})
        \\        record-fn (d/symbol s :echo :selftest_record)
        \\        _ (connect s 1)
        \\        recorded (:params (first (d/calls s record-fn {{:limit 1 :ms 3000}})))
        \\        recorded-ratio (:value (first recorded))
        \\        _ (connect s 1)
        \\        _ (d/break s (:address serve-fn) nil)
        \\        stop (d/continue s 3000)
        \\        framed (when stop (d/frames s :echo))
        \\        _ (d/break s nil)
        \\        _ (d/close s)
        \\        ;; The guest kernel's jiffies by its name, then its moment of reaching +500 ticks.
        \\        k (d/open 1 {{:branch 0 :at-vtime-ms 2000}})
        \\        jiffies (unhex (str "0x" (first (str/split (str/trim (d/sh k "grep -m1 ' D jiffies$' /proc/kallsyms")) #" "))))
        \\        _ (d/close k)
        \\        j (d/open 1 {{:branch 0 :at-vtime-ms 2000}})
        \\        jiffies-at-2s (d/value-of (d/mem j (d/translate j :current jiffies) 8) :u64)
        \\        _ (d/close j)
        \\        held? (fn [t] (>= (d/value-of (d/mem t (d/translate t :current jiffies) 8) :u64) (+' jiffies-at-2s 500)))
        \\        reached (d/moment-when 1 0 held? {{:from-ms 2000 :to-ms 3000}})
        \\        ;; The first moment: not yet one taken branch before it, held at it. (Not 2.5 s
        \\        ;; itself: a tickless guest's jiffies, read at 2 s, can be behind.)
        \\        edge (let [e (d/open 1 {{:branch 0 :at-vtime-ms (:ms reached)}})]
        \\               (try (when (pos? (:branches reached)) (d/step-branches e (dec (:branches reached))))
        \\                    (let [before (held? e)] (d/step-branches e 1) [before (held? e)])
        \\                    (finally (d/close e))))
        \\        across (d/across 1 condition
        \\                         (fn [t] (let [found (d/symbol t :echo :selftest_accepted)]
        \\                                   (connect t 1)
        \\                                   (mapv :value (d/watch-values t found {{:limit 1 :ms 3000}}))))
        \\                         {{:branches [0 1]}})
        \\        fd (first (:args (first served)))]
        \\    (said "regs" (some? (:rip regs)) (:rip regs))
        \\    (said "accepted-u64" (= ["unsigned" 8] [(:kind (:type accepted)) (:size (:type accepted))]) (:type accepted))
        \\    (said "ratio-f64" (= ["float" 8] [(:kind (:type ratio)) (:size (:type ratio))]) (:type ratio))
        \\    (said "ratio-16-in" (= 16 (- (number (:address ratio)) (number (:address stats)))) (:address stats) (:address ratio))
        \\    (said "ratios-half-a-connection" (and (= 2 (count ratios)) (every? float? ratios) (== 0.5 (- (second ratios) (first ratios)))) ratios)
        \\    (said "call-descriptor" (and (some? fd) (< 2 fd 1024)) (:args (first served)))
        \\    (said "call-float" (and (= ["ratio" "f64" "client" "i32"] (mapcat (juxt :name :type) recorded))
        \\                            (float? recorded-ratio) (> recorded-ratio 1.5) (== 0.0 (mod (* 2 recorded-ratio) 1.0))
        \\                            (< 2 (:value (second recorded)) 1024))
        \\          recorded)
        \\    (said "call-params" (= [{{:name "client" :type "i32" :value fd}}] (:params (first served))) (:params serve-fn) (:params (first served)))
        \\    (said "frames" (and (seq framed) (every? (fn [f] (string? (:at f))) framed)
        \\                        (some (fn [f] (str/includes? (:at f) "selftest")) framed))
        \\          (mapv :at framed))
        \\    (said "moment-when" (and (= [false true] edge) (< 2000 (:ms reached) 3000) (some? (:rip (:regs reached)))) (dissoc reached :regs) edge (:rip (:regs reached)))
        \\    (said "across-both" (and (= [0 1] (mapv :branch across))
        \\                             (every? (fn [r] (and (= 1 (count (:result r))) (pos? (first (:result r))))) across))
        \\          (mapv (juxt :branch :timeline :result) across))))
        \\
    , .{url}) });
    // The same script under babashka and under jank (the viz's runtime, where the client's own
    // limits are: a catch's nil, 32-bit products), each judged on its own.
    const Runner = struct { name: []const u8, argv: []const []const u8 };
    var runners: std.ArrayList(Runner) = .empty;
    try runners.append(arena, .{ .name = "babashka", .argv = &.{ bb, "--classpath", "clients/clojure/src", script } });
    if (context.jank) |jank| {
        try runners.append(arena, .{ .name = "jank", .argv = try arena.dupe([]const u8, &.{ jank, "--module-path", "clients/clojure/src", "run", script }) });
    } else std.debug.print("SKIP client: under jank (no jank: $DETERMINISMO_JANK or --jank)\n", .{});
    for (runners.items) |runner| {
        const ran = try run_kept(context, runner.argv);
        const out = try std.mem.concat(arena, u8, &.{ ran.stdout, ran.stderr });
        const names = [_][]const u8{ "regs", "accepted-u64", "ratio-f64", "ratio-16-in", "ratios-half-a-connection", "call-descriptor", "call-params", "call-float", "frames", "moment-when", "across-both" };
        var good: [names.len]bool = undefined;
        for (names, 0..) |name, index| good[index] = std.mem.indexOf(u8, out, try std.fmt.allocPrint(arena, "ok {s} ", .{name})) != null;
        expect_all(context, &.{
            .{ "a session's registers", good[0] },
            .{ "a variable by its name, typed from DWARF (unsigned, 8)", good[1] },
            .{ "a structure's field by its path, typed (float, 8)", good[2] },
            .{ "the field 16 bytes into the structure", good[3] },
            .{ "its writes after two connections, half a connection apart", good[4] },
            .{ "a function's call, its argument the connection's descriptor", good[5] },
            .{ "the call's parameter by its DWARF name and type (client, i32)", good[6] },
            .{ "a float argument from its vector register, the integer after it from rdi", good[7] },
            .{ "a stop's frames, named as a crash's stack is (det-nodes where), the node's own code among them", good[8] },
            .{ "moment-when: jiffies' +500 ticks from 2 s, not yet one branch before the moment found, held at it", good[9] },
            .{ "across: the same look in both timelines", good[10] },
        }, "client: the REPL's session, symbols, values, calls and across, from {s} ({s})", .{ runner.name, out[0..@min(out.len, 1200)] });
    }
}

/// A session that runs no guest command leaves the timeline it opened on as it was: opened at 3 s
/// of a selftest timeline, its registers read, on to 6 s: its events there are the recorded
/// ones, the same at the same moments (the guest's agent never woken: no hold at the moment).
/// On past the scenario's end, it is held there by the VMM and goes on taking steps: a look, then
/// a guest command (the agent's hold sent then, before it). A guest command mid-timeline still
/// runs, the session's future its own from there.
fn check_session_exact(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7886";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-exact" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .scenario = "steady",
        .seed = 1,
        .branches = 1,
        .branching = "flat",
        .timeline = "10s",
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const Opened = struct { session: u32 = 0, timeline: ?u32 = null };
    const Stepped = struct { output: []const u8 = "" };
    const Session = struct {
        fn open(c: *Context, at_ms: u32) !Opened {
            const body = try std.fmt.allocPrint(c.arena, "{{\"branch\":0,\"at_vtime_ms\":{d}}}", .{at_ms});
            const answer = try curl(c, &.{ "-X", "POST", "-d", body, url ++ "/runs/1/session" });
            return std.json.parseFromSliceLeaky(Opened, c.arena, answer, .{ .ignore_unknown_fields = true });
        }
        fn step(c: *Context, session: u32, exec: []const u8) ![]const u8 {
            const body = try std.fmt.allocPrint(c.arena, "{f}", .{std.json.fmt(.{ .exec = exec }, .{})});
            const path = try std.fmt.allocPrint(c.arena, url ++ "/sessions/{d}/step", .{session});
            const answer = try curl(c, &.{ "-X", "POST", "-d", body, path });
            return (try std.json.parseFromSliceLeaky(Stepped, c.arena, answer, .{ .ignore_unknown_fields = true })).output;
        }
        fn end(c: *Context, session: u32) !void {
            const path = try std.fmt.allocPrint(c.arena, url ++ "/sessions/{d}/end", .{session});
            _ = try curl(c, &.{ "-X", "POST", "-d", "{}", path });
        }
        fn events(c: *Context, branch: u32) ![]const u8 {
            const sql = try std.fmt.allocPrint(c.arena, "SELECT vtime_ns, event FROM events WHERE branch = {d} " ++
                "AND vtime_ns > 3000000000 AND vtime_ns <= 6000000000 ORDER BY seq", .{branch});
            const body = try std.fmt.allocPrint(c.arena, "{f}", .{std.json.fmt(.{ .sql = sql }, .{})});
            return curl(c, &.{ "-X", "POST", "-d", body, url ++ "/runs/1/sql" });
        }
    };
    // 1. Looks only, then on: the recorded future.
    const looked = try Session.open(context, 3000);
    const regs = try Session.step(context, looked.session, "det:regs");
    _ = try Session.step(context, looked.session, "det:at 6000000000");
    try Session.end(context, looked.session);
    const recorded = try Session.events(context, 0);
    var own: []const u8 = "";
    for (0..60) |_| {
        own = try Session.events(context, looked.timeline orelse 0);
        if (own.len > 4) break;
        sleep_ms(500);
    }
    // 2. On past the scenario's end: held there, a look, then a guest command.
    const ended = try Session.open(context, 3000);
    const past = try Session.step(context, ended.session, "det:at 30000000000");
    const at_end = try Session.step(context, ended.session, "det:regs");
    const listed = try Session.step(context, ended.session, "det-nodes list");
    try Session.end(context, ended.session);
    // 3. A guest command mid-timeline.
    const commanded = try Session.open(context, 3000);
    const mid = try Session.step(context, commanded.session, "det-nodes list");
    try Session.end(context, commanded.session);
    expect_all(context, &.{
        .{ "a look at the moment (det:regs)", std.mem.indexOf(u8, regs, "[determinismo] regs: {") != null },
        .{ "the recorded timeline has events from 3 s to 6 s", recorded.len > 64 },
        .{ "a session with no guest command has the same events at the same moments", recorded.len > 64 and std.mem.eql(u8, recorded, own) },
        .{ "on past the scenario's end, the session is held there", std.mem.indexOf(u8, past, "the scenario ended: held here") != null },
        .{ "and takes a look there", std.mem.indexOf(u8, at_end, "[determinismo] regs: {") != null },
        .{ "and runs a guest command there (the agent's hold sent first)", std.mem.indexOf(u8, listed, "\\\"name\\\":\\\"echo\\\"") != null },
        .{ "a guest command mid-timeline runs", std.mem.indexOf(u8, mid, "\\\"name\\\":\\\"echo\\\"") != null },
    }, "session-exact: recorded {d} bytes of events from 3 s to 6 s, the session's {d}", .{ recorded.len, own.len });
}

fn check_tapes(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const strategy = try std.fs.path.join(context.arena, &.{ context.bin, "det-strategy-mutate" });
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "tapes" });
    const record = try std.fs.path.join(context.arena, &.{ context.scratch, "tapes-record.jsonl" });
    const report = try explore(context, &.{
        "--program",  program,  "--scenario", "bank", "--seed",   "11",   "--branches", "4",
        "--strategy", strategy, "--tape-dir", tapes,  "--record", record,
    });
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 4, "tapes: explored {d} branches with a strategy", .{count});
    if (count == 0) return;
    const last = branches[count - 1];
    const tape_name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{last.index});
    const tape = try std.fs.path.join(context.arena, &.{ tapes, tape_name });
    const replay = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--tape", tape,
    });
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "its events hash is the original's", ran_one and std.mem.eql(u8, replayed[0].events_hash, last.events_hash) },
    }, "tapes: branch {d} replays from its tape without the strategy", .{
        last.index,
    });
    const elsewhere = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--tape", tape, "--timer-slack-us", "1001",
    });
    const refused = std.mem.indexOf(u8, elsewhere, "the tape was recorded with inputs") != null;
    expect(context, refused, "tapes: a replay on different inputs is refused", .{});
    // A command at a moment of a replay (looking inside a timeline) makes a new timeline from
    // there: the replay goes on to the end, not stopping at the tape it no longer follows. The
    // moment inside the timeline, from its replay (1500 ms once, past the taken-branch clock's).
    const moment = try moment_inside(context.arena, replay, 0.5);
    const inside = try explore(context, &.{
        "--program",     program, "--scenario", "bank",               "--tape",     tape,
        "--at-vtime-ms", moment,  "--exec",     "echo looked inside", "--continue",
    });
    var looked: [1]Branch = undefined;
    expect_all(context, &.{
        .{ "the command ran (\"looked inside\")", std.mem.indexOf(u8, inside, "looked inside") != null },
        .{ "the replay did not diverge", std.mem.indexOf(u8, inside, "diverged") == null },
        .{ "one timeline ran to its end", parse_branches(inside, &looked) == 1 },
    }, "tapes: a command at a moment of a replay runs, and the replay goes on to the end", .{});
    // Steps after a command (a wait, a wait-until) run the new timeline on: its tape no longer
    // applies (a sync, then an until a crash, once parted from Galera's tape at its first
    // checkpoint).
    const script = try std.fs.path.join(context.arena, &.{ context.scratch, "tape-steps.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = "echo changed\n" ++
        "det:wait 300\ndet:background sleep 0.2; echo waited\n" ++
        "det:until 3000 event=exec_output details.text~waited\n" });
    const stepped = try explore(context, &.{
        "--program",     program, "--scenario",    "bank", "--tape",     tape,
        "--at-vtime-ms", moment,  "--exec-script", script, "--continue",
    });
    var stepped_branch: [1]Branch = undefined;
    expect_all(context, &.{
        .{ "the steps ran (\"changed\", \"waited\")", std.mem.indexOf(u8, stepped, "changed") != null and std.mem.indexOf(u8, stepped, "waited") != null },
        .{ "the until held", std.mem.indexOf(u8, stepped, "until: timed out") == null },
        .{ "the replay did not diverge", std.mem.indexOf(u8, stepped, "diverged") == null },
        .{ "one timeline ran to its end", parse_branches(stepped, &stepped_branch) == 1 },
    }, "tapes: steps after a command at a moment of a replay run on, the tape no longer applying", .{});
    // A replay that parts from its tape names where, and the events since the last checkpoint
    // (to compare with the timeline's own): here a tape whose first checkpoint was altered.
    const cwd = std.Io.Dir.cwd();
    const recorded = try cwd.readFileAlloc(context.io, tape, context.arena, .limited(1 << 26));
    const marker = "\"events_hash\":\"";
    const at = std.mem.indexOf(u8, recorded, marker) orelse {
        expect(context, false, "tapes: its tape has a checkpoint to alter", .{});
        return;
    };
    const altered = try context.arena.dupe(u8, recorded);
    @memcpy(altered[at + marker.len ..][0..16], "0123456789abcdef");
    const altered_path = try std.fs.path.join(context.arena, &.{ tapes, "altered.jsonl" });
    try cwd.writeFile(context.io, .{ .sub_path = altered_path, .data = altered });
    const parted = try explore(context, &.{ "--program", program, "--scenario", "bank", "--tape", altered_path });
    expect_all(context, &.{
        .{ "it diverged at the first checkpoint (event 64)", std.mem.indexOf(u8, parted, "replay diverged from its tape at event 64\n") != null },
        // Since the setup's snapshot, where a replay starts (event 25 here), up to the checkpoint.
        .{ "it printed the events since the last checkpoint", std.mem.indexOf(u8, parted, "events (seq vtime_ns branches event)") != null },
        .{ "the 64th among them", std.mem.indexOf(u8, parted, "[determinismo]   64 ") != null },
    }, "tapes: a replay that parts from its tape names where, and its last events", .{});
    // `determinismo verify`: the timeline named replays as recorded; from the altered tape it
    // does not, and says where, with the replay's last events.
    const index = try std.fmt.allocPrint(context.arena, "{d}", .{last.index});
    const verified = try verify(context, &.{
        "--program", program, "--scenario", "bank", "--record", record, "--tape-dir", tapes, "--timeline", index,
    });
    const altered_tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "tapes-altered" });
    try cwd.createDirPath(context.io, altered_tapes);
    try cwd.writeFile(context.io, .{
        .sub_path = try std.fs.path.join(context.arena, &.{ altered_tapes, tape_name }),
        .data = altered,
    });
    const unverified = try verify(context, &.{
        "--program", program, "--scenario", "bank", "--record", record, "--tape-dir", altered_tapes, "--timeline", index,
    });
    const passed = try std.fmt.allocPrint(context.arena, "PASS timeline {d} replays", .{last.index});
    const failed = try std.fmt.allocPrint(context.arena, "FAIL timeline {d} does not replay", .{last.index});
    expect_all(context, &.{
        .{ "the timeline named replays", std.mem.indexOf(u8, verified, passed) != null },
        .{ "and only it", std.mem.indexOf(u8, verified, "verify: 1 of 1 timelines replayed") != null },
        .{ "from the altered tape it does not", std.mem.indexOf(u8, unverified, failed) != null },
        .{ "saying where", std.mem.indexOf(u8, unverified, "replay diverged from its tape at event 64") != null },
        .{ "with its last events", std.mem.indexOf(u8, unverified, "events (seq vtime_ns branches event)") != null },
    }, "tapes: verify replays the timeline named ({d}), and reports one that parts from its tape", .{last.index});
}

/// `determinismo verify` with the machine options, its output kept as explore's.
fn verify(context: *Context, extra: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "verify" });
    try argv.appendSlice(context.arena, context.machine);
    try argv.appendSlice(context.arena, extra);
    const result = try run_kept(context, argv.items);
    return std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
}

/// Coverage-guided exploration solves the maze (1 in 10000 timelines by chance): with coverage
/// from the C, Zig, Python and JVM SDKs, one worker or several sharing one corpus, and in
/// Python and Java under faults (decisions and events of other processes interleaved). The
/// solving branch replays from its tape.
fn check_coverage(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const c = [_][]const u8{ "--program", program, "--profile", "maze", "--scenario", "maze" };
    const zig = [_][]const u8{
        "--program", program, "--profile", "maze-zig", "--scenario", "maze",
    };
    const python = [_][]const u8{
        "--compose", "tests/antithesis-compat/python/compose.yaml", "--scenario", "maze",
    };
    const java = [_][]const u8{
        "--compose", "tests/antithesis-compat/java/compose.yaml", "--scenario", "maze",
    };
    const mazes = [_]Maze{
        .{ .label = "C, one worker", .system = &c, .jobs = 1, .branches = 300 },
        // 600: with its own lines for coverage (the SDK leaves the library's and its own
        // out), seeds 1 to 6 first solve it at timelines 184, 65, 212, 175, 314 and 87
        // (2026-11-17); 300 held while the debug information's parser, run anew at each
        // assertion's site, counted as the maze's coverage.
        .{ .label = "Zig, one worker", .system = &zig, .jobs = 1, .branches = 600, .lines = "\"name\":\"line [^\"]*tests/selftest/maze.zig:[0-9]+" },
        .{ .label = "C, 4 synced workers", .system = &c, .jobs = 4, .branches = 300 },
        .{ .label = "Python, 8 synced workers", .system = &python, .jobs = 8, .branches = 1000 },
        .{ .label = "Java, 8 synced workers", .system = &java, .jobs = 8, .branches = 1000 },
    };
    for (mazes, 0..) |maze, index| try check_maze(context, maze, index);
}

const Maze = struct {
    label: []const u8,
    system: []const []const u8,
    jobs: u32,
    branches: u32,
    /// What its coverage events must match (an extended regular expression): edges as lines.
    lines: ?[]const u8 = null,
};

fn check_maze(context: *Context, maze: Maze, index: usize) !void {
    const arena = context.arena;
    const mutate = try std.fs.path.join(arena, &.{ context.bin, "det-strategy-mutate" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/maze-{d}-tapes", .{ context.scratch, index });
    const sync = try std.fmt.allocPrint(arena, "{s}/maze-{d}-sync", .{ context.scratch, index });
    const strategy = if (maze.jobs == 1)
        mutate
    else
        try std.fmt.allocPrint(arena, "{s} --sync-dir {s}", .{ mutate, sync });
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(arena, maze.system);
    try arguments.appendSlice(arena, &.{
        "--seed",     "1",
        "--branches", try std.fmt.allocPrint(arena, "{d}", .{maze.branches}),
        "--jobs",     try std.fmt.allocPrint(arena, "{d}", .{maze.jobs}),
        "--strategy", strategy,
        "--tape-dir", tapes,
    });
    const events = try std.fmt.allocPrint(arena, "{s}/maze-{d}-events", .{ context.scratch, index });
    if (maze.lines != null) try arguments.appendSlice(arena, &.{ "--events-dir", events });
    const report = try explore(context, arguments.items);
    if (maze.lines) |pattern| {
        const found = try run_kept(context, &.{ "grep", "-rlE", pattern, events });
        expect(context, found.stdout.len > 0, "coverage ({s}): its edges are reported as source " ++
            "lines (\"line <file>:<n>\")", .{maze.label});
    }
    const branches = try arena.alloc(Branch, maze.branches); // One line per branch.
    const count = parse_branches(report, branches);
    const solved = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else null;
    expect(context, solved != null, "coverage ({s}): guided exploration solves the maze", .{
        maze.label,
    });
    const branch = solved orelse return;
    const tape_name = try std.fmt.allocPrint(arena, "branch-{d}.jsonl", .{branch.index});
    const tape = try std.fs.path.join(arena, &.{ tapes, tape_name });
    var replay_arguments: std.ArrayList([]const u8) = .empty;
    try replay_arguments.appendSlice(arena, maze.system);
    try replay_arguments.appendSlice(arena, &.{ "--tape", tape });
    const replay = try explore(context, replay_arguments.items);
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "it fails, as the original", ran_one and replayed[0].failing },
        .{ "its events hash is the original's", ran_one and std.mem.eql(u8, replayed[0].events_hash, branch.events_hash) },
    }, "coverage ({s}): the solving branch {d} replays from its tape", .{ maze.label, branch.index });
}

/// A strategy written in Python (found through PATH, as a shell would) steers decisions, and a
/// branch it steered replays from its tape without it.
fn check_python_strategy(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "python-tapes" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "3" };
    const report = try explore(context, &(common ++ [_][]const u8{
        "--branches", "12",  "--jobs", "1", "--strategy", "python3 plugins/python/extremes.py",
        "--tape-dir", tapes,
    }));
    var branches: [12]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 12, "python strategy: explored {d} branches", .{count});
    if (count == 0) return;
    // The bandit tries its rates in order: branch 1 overrides 5% of the decisions.
    const tape = try std.fs.path.join(context.arena, &.{ tapes, "branch-1.jsonl" });
    const cwd = std.Io.Dir.cwd();
    const recorded = cwd.readFileAlloc(context.io, tape, context.arena, .limited(1 << 24)) catch "";
    const steered = std.mem.indexOf(u8, recorded, "\"pull\"") != null;
    expect(context, steered, "python strategy: it overrides decisions", .{});
    const replay = try explore(context, &(common ++ [_][]const u8{ "--tape", tape }));
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "its events hash is the original's", ran_one and std.mem.eql(u8, replayed[0].events_hash, branches[1].events_hash) },
    }, "python strategy: its branch replays from the tape without it", .{});
    try check_mcp_strategy(context, program);
    try check_image_strategy(context, program);
}

/// The same strategy as a container image (plugins/python/Dockerfile), its dependencies in it:
/// `--strategy image:<reference>` runs it with podman, and its decisions are in the tapes as a
/// command's are.
fn check_image_strategy(context: *Context, program: []const u8) !void {
    const reference = "localhost/determinismo-strategy-extremes:1";
    const build = try run_kept(context, &.{
        "podman", "build", "--quiet", "--tag", reference, "--file", "plugins/python/Dockerfile", ".",
    });
    expect(context, build.term.success(), "image strategy: plugins/python/Dockerfile builds", .{});
    if (!build.term.success()) return;
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "image-strategy-tapes" });
    const report = try explore(context, &.{
        "--program",  program, "--scenario", "bank", "--seed",     "3",
        "--branches", "4",     "--jobs",     "1",    "--strategy", "image:" ++ reference,
        "--tape-dir", tapes,
    });
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    // The bandit's rates in branch order: branch 1 overrides 5% of the decisions.
    const tape = try std.fs.path.join(context.arena, &.{ tapes, "branch-1.jsonl" });
    const recorded = std.Io.Dir.cwd().readFileAlloc(context.io, tape, context.arena, .limited(1 << 24)) catch "";
    expect_all(context, &.{
        .{ "it explored 4 branches", count == 4 },
        .{ "its overrides are in the tapes", std.mem.indexOf(u8, recorded, "\"pull\"") != null },
    }, "image strategy: a plugin in a container steers the exploration", .{});
}

/// The same strategy brought through MCP's explore tool (an agent's own strategy, any command):
/// its decisions in the run's tapes.
fn check_mcp_strategy(context: *Context, program: []const u8) !void {
    const arena = context.arena;
    const call = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1," ++
        "\"method\":\"tools/call\",\"params\":{{\"name\":\"explore\",\"arguments\":" ++
        "{{\"program\":{f},\"scenario\":\"bank\",\"seed\":3,\"branches\":4," ++
        "\"strategy\":\"python3 plugins/python/extremes.py\"}}}}}}\n", .{std.json.fmt(program, .{})});
    const message = try std.fs.path.join(arena, &.{ context.scratch, "mcp-strategy.jsonl" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = message, .data = call });
    // One job: the bandit's rates in branch order, as above.
    var argv: std.ArrayList([]const u8) = .empty;
    const script = try std.fmt.allocPrint(arena, "exec \"$0\" mcp \"$@\" < {s}", .{message});
    try argv.appendSlice(arena, &.{ "sh", "-c", script, context.determinismo });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &.{ "--jobs", "1" });
    const result = try run_kept(context, argv.items);
    const Response = struct { result: struct {
        content: []const struct { text: []const u8 },
        isError: bool = false,
    } };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const response = std.json.parseFromSliceLeaky(Response, arena, result.stdout, options) catch {
        expect(context, false, "mcp strategy: an answer ({s})", .{result.stdout});
        return;
    };
    const text = if (response.result.content.len > 0) response.result.content[0].text else "";
    const failed = response.result.isError or text.len == 0;
    expect(context, !failed, "mcp strategy: explore answered ({s})", .{text[0..@min(text.len, 200)]});
    if (failed) return;
    const last = std.mem.trimEnd(u8, text, "\n");
    const where = last[(std.mem.lastIndexOfScalar(u8, last, '\n') orelse 0)..];
    const Where = struct { tape_dir: []const u8 };
    const dirs = try std.json.parseFromSliceLeaky(Where, arena, std.mem.trim(u8, where, "\n"), options);
    const tape = try std.fs.path.join(arena, &.{ dirs.tape_dir, "branch-1.jsonl" });
    const cwd = std.Io.Dir.cwd();
    const recorded = cwd.readFileAlloc(context.io, tape, arena, .limited(1 << 24)) catch "";
    const steered = std.mem.indexOf(u8, recorded, "\"pull\"") != null;
    expect(context, steered, "mcp strategy: the strategy given to explore overrides decisions", .{});
}

/// Kubernetes (K3s) as the system under test, on one node and as a three-node cluster (pods
/// spread over them): the workload survives faults, and a branch replays exactly.
/// The .NET SDK (sdk/dotnet) inside determinismo: a C# program's assertions with their places,
/// its named decisions and events, the generated catalog's announcement of an assertion it never
/// runs; its timeline replays exactly.
fn check_dotnet(context: *Context) !void {
    const arena = context.arena;
    const common = [_][]const u8{ "--compose", "tests/antithesis-compat/dotnet/compose.yaml", "--scenario", "sdk", "--seed", "1" };
    const events = try std.fmt.allocPrint(arena, "{s}/dotnet", .{context.scratch});
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2", "--events-dir", events }));
    const grep = struct {
        fn found(c: *Context, pattern: []const u8, directory: []const u8) bool {
            const result = run_kept(c, &.{ "grep", "-rlF", pattern, directory }) catch return false;
            return result.stdout.len > 0;
        }
    }.found;
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const index = try std.fmt.allocPrint(arena, "{d}", .{branches[0].index});
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    }
    expect_all(context, &.{
        .{ "2 timelines", count == 2 },
        .{ "the program is inside determinismo", grep(context, "\"message\":\"dotnet: inside determinismo\",\"condition\":true", events) },
        .{ "an assertion's place in the code", grep(context, "\"file\":\"/app/Check.cs\"", events) },
        // Its name and its options, wherever the draws file puts its other fields (it has
        // put kind, count and config between them since the named draws got their kinds).
        .{ "a named decision", grep(context, "\"name\":\"dotnet.account\"", events) and
            grep(context, "\"options\":[\"alice\",\"bob\",\"carol\"]", events) },
        .{ "an event", grep(context, "\"event\":\"dotnet_transfer\"", events) },
        .{ "the catalog announced the assertion it never runs", grep(context, "\"message\":\"dotnet: never reached\",\"hit\":false", events) },
        .{ "no property failed", std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null },
        .{ "a timeline replays exactly", same },
    }, "dotnet: the .NET SDK inside determinismo", .{});
}

/// A run ends on time: past its budget and a grace (a twentieth of it, a minute at least), the
/// timelines still running stop, not counted, and so do the replays left. Ten-minute timelines
/// under a 30 s budget: over in about 90 s, its verdict its own.
fn check_budget(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const start_ns = monotonic_ns();
    const report = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--seed", "4", "--time-budget", "30s", "--timeline", "600s",
    });
    const wall_s = (monotonic_ns() - start_ns) / std.time.ns_per_s;
    expect_all(context, &.{
        .{ "the timelines still running were stopped at the grace's end", std.mem.indexOf(u8, report, "the budget's grace is over") != null },
        .{ "the run ended within its budget, its grace and its setup", wall_s < 240 },
        // Both stopped: no verdict, and no pass claimed.
        .{ "it said none finished, nothing judged", std.mem.indexOf(u8, report, "multiverse: 0 branches, none finished") != null },
        .{ "it ended in an error, not a pass", std.mem.indexOf(u8, report, "NoTimelineFinished") != null },
    }, "budget: a 30 s budget over 600 s timelines ended in {d} s", .{wall_s});
}

fn monotonic_ns() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// A platform mechanic written in a program's language: repl-test's rolling restart (Clojure,
/// :custom-faults) is a fault kind of its node's, which the fault injector runs (asked by the
/// scenario's driver, and picked on its own), and which restarts the other nodes through the
/// runner (det_runner), its order and pauses drawn by the platform. Replayed as the platform's.
fn check_mechanics(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "repl-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "mechanics", "--seed", "1" };
    const events = try std.fmt.allocPrint(arena, "{s}/mechanics", .{context.scratch});
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2", "--events-dir", events }));
    const grep = struct {
        fn found(c: *Context, pattern: []const u8, directory: []const u8) bool {
            const result = run_kept(c, &.{ "grep", "-rlF", pattern, directory }) catch return false;
            return result.stdout.len > 0;
        }
    }.found;
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const index = try std.fmt.allocPrint(arena, "{d}", .{branches[0].index});
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    }
    expect_all(context, &.{
        .{ "2 timelines", count == 2 },
        .{ "the injector ran the program's fault kind", grep(context, "\"program\":\"/opt/workload/run fault rolling-restart\",\"status\":0", events) },
        .{ "it killed a peer through the runner", grep(context, "\"argv\":[\"det-nodes\",\"kill\",\"peer", events) },
        .{ "and started it again", grep(context, "\"argv\":[\"det-nodes\",\"start\",\"peer", events) },
        .{ "every peer answers after the restarts", std.mem.indexOf(u8, report, "failing in    0  every peer answers after the restarts") != null },
        .{ "a timeline replays exactly", same },
    }, "mechanics: a fault kind written in Clojure, through the runner", .{});
}

/// Antithesis's output sink (ANTITHESIS_OUTPUT_DIR): a node's .jsonl lines are events (an
/// Antithesis SDK's assertion), other files' lines output, .bin files' bytes output in base64.
fn check_sinks(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(arena, "{s}/sinks", .{context.scratch});
    const report = try explore(context, &.{
        "--program", program, "--scenario", "sinks", "--seed", "1", "--branches", "2", "--events-dir", events,
    });
    const grep = struct {
        fn found(c: *Context, pattern: []const u8, directory: []const u8) bool {
            const result = run_kept(c, &.{ "grep", "-rlF", pattern, directory }) catch return false;
            return result.stdout.len > 0;
        }
    }.found;
    // The retroactive sink (ANTITHESIS_FILTERED_OUTPUT_DIR): out of the exploration's events,
    // in a replay's.
    const replayed = try std.fmt.allocPrint(arena, "{s}/sinks-replay.jsonl", .{context.scratch});
    _ = try explore(context, &.{
        "--program", program, "--scenario", "sinks", "--seed", "1", "--branch", "0", "--events", replayed,
    });
    const hidden = !grep(context, "a filtered line", events);
    const recovered = grep(context, "\"stream\":\"filtered verbose.log\",\"text\":\"a filtered line\"", replayed);
    expect_all(context, &.{
        .{ "the retroactive sink's line is out of the exploration's events", hidden },
        .{ "and in a replay's", recovered },
        .{ "the node has ANTITHESIS_OUTPUT_DIR", std.mem.indexOf(u8, report, "nodes have ANTITHESIS_OUTPUT_DIR") != null and
            std.mem.indexOf(u8, report, "FAIL always                hit in    2/2 branches, failing in    2  nodes have") == null },
        .{ "a .jsonl line is an event (an Antithesis SDK assertion)", grep(context, "\"message\":\"a sink assertion\"", events) },
        .{ "a text file's line is output under the node and the file", grep(context, "\"source\":\"echo\",\"stream\":\"debug.log\",\"text\":\"hello sink\"", events) },
        .{ "a .bin file's bytes are output in base64", grep(context, "\"stream\":\"data.bin\",\"text\":\"AAEC\"", events) },
    }, "sinks: what nodes write to ANTITHESIS_OUTPUT_DIR is events", .{});
}

/// Antithesis's endings (det-composer): an eventually command kills the commands still running
/// (drivers sleeping past the driver phase), and their ends are no failures, once they drove at
/// least the drawn minimum (none with --min-drive 0); a finally command waits for every command
/// to end on its own.
fn check_ending(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(arena, "{s}/ending", .{context.scratch});
    const report = try explore(context, &.{
        "--program", program, "--scenario", "ending", "--seed", "1", "--branches", "8", "--events-dir", events,
    });
    // Per timeline (by the assertions' evaluations, not their catalog's declarations): eventually
    // ones killed the sleepers still running (fewer finished than started: with one driver at a
    // time, the earlier ones finish) once they drove the drawn minimum (30 s sleepers: all still
    // running then); finally ones killed none.
    const script = try std.fmt.allocPrint(arena,
        \\cd {s}; e=0; f=0; bad=0; short=0
        \\for t in branch-*.jsonl; do
        \\  if grep -q 'an eventually command ran","condition":true' $t; then e=$((e+1))
        \\    grep -q '"killed":true' $t || bad=$((bad+1))
        \\    [ $(grep -c sleeper_done $t) -lt $(grep -c sleeper_start $t) ] || bad=$((bad+1))
        \\    d=$(grep -o '"drawn_ms":[0-9]*' $t | cut -d: -f2); w=$(grep -o '"waited_ms":[0-9]*' $t | cut -d: -f2)
        \\    [ -n "$d" ] && [ "$w" -ge "$d" ] || short=$((short+1))
        \\  elif grep -q 'a finally command ran","condition":true' $t; then f=$((f+1)); grep -q '"killed":true' $t && bad=$((bad+1))
        \\  fi
        \\done; echo "$e $f $bad $short"
    , .{events});
    const counted = try run_kept(context, &.{ "sh", "-c", script });
    var words = std.mem.tokenizeAny(u8, counted.stdout, " \n");
    const eventually = std.fmt.parseInt(u32, words.next() orelse "0", 10) catch 0;
    const finally = std.fmt.parseInt(u32, words.next() orelse "0", 10) catch 0;
    const wrong = std.fmt.parseInt(u32, words.next() orelse "1", 10) catch 1;
    const short = std.fmt.parseInt(u32, words.next() orelse "1", 10) catch 1;
    const exits = std.mem.indexOf(u8, report, "FAIL always") == null or
        std.mem.indexOf(u8, report, "test commands exit successfully  (e.g.") == null;
    // The sleepers' children killed with them: a command's group, its children in it.
    const children_gone = children: {
        var lines = std.mem.tokenizeScalar(u8, report, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "a killed driver's children are gone") == null) continue;
            break :children std.mem.indexOf(u8, line, "PASS") != null;
        }
        break :children false;
    };
    const none_events = try std.fmt.allocPrint(arena, "{s}/ending-no-drive", .{context.scratch});
    _ = try explore(context, &.{
        "--program",    program,     "--scenario",  "ending", "--seed", "1", "--branches", "4",
        "--events-dir", none_events, "--min-drive", "0",
    });
    const drawn = try run_kept(context, &.{ "grep", "-rlF", "\"event\":\"min_drive\"", none_events });
    // A timeline length bounds the driver phase even while every slot is held: sleepers of 30 s,
    // 2 s of starts, no minimum drive. A start that waited for a slot without a deadline held
    // the composer past the length (Kafka's perf run 355: 30 s timelines past 1,200 s).
    const timed_events = try std.fmt.allocPrint(arena, "{s}/ending-timeline", .{context.scratch});
    _ = try explore(context, &.{
        "--program",    program,      "--scenario",  "ending", "--seed",     "1",  "--branches", "4",
        "--events-dir", timed_events, "--min-drive", "0",      "--timeline", "2s",
    });
    const timed_script = try std.fmt.allocPrint(arena,
        \\cd {s}; e=0; long=0
        \\for t in branch-*.jsonl; do
        \\  grep -q 'an eventually command ran","condition":true' $t || continue; e=$((e+1))
        \\  s=$(grep '"faults_phase","details":{{"state":"start"}}' $t | grep -o '"vtime_ns":[0-9]*' | head -1 | cut -d: -f2)
        \\  x=$(grep '"faults_phase","details":{{"state":"stop"}}' $t | grep -o '"vtime_ns":[0-9]*' | head -1 | cut -d: -f2)
        \\  if [ -z "$s" ] || [ -z "$x" ] || [ $((x - s)) -ge 5000000000 ]; then long=$((long+1)); fi
        \\done; echo "$e $long"
    , .{timed_events});
    const timed = try run_kept(context, &.{ "sh", "-c", timed_script });
    var timed_words = std.mem.tokenizeAny(u8, timed.stdout, " \n");
    const timed_eventually = std.fmt.parseInt(u32, timed_words.next() orelse "0", 10) catch 0;
    const timed_long = std.fmt.parseInt(u32, timed_words.next() orelse "1", 10) catch 1;
    expect_all(context, &.{
        .{ "timelines ending with an eventually command", eventually > 0 },
        .{ "timelines ending with a finally command", finally > 0 },
        .{ "eventually killed the running drivers, finally none", wrong == 0 },
        .{ "eventually ones drove at least the drawn minimum first", short == 0 },
        .{ "a killed command is no failing exit", exits },
        .{ "a killed driver's children die with it (its group killed)", children_gone },
        .{ "--min-drive 0 draws no minimum", drawn.stdout.len == 0 },
        .{ "a timeline length ends the driver phase though every slot is held", timed_eventually > 0 and timed_long == 0 },
    }, "ending: {d} eventually (drivers killed after their minimum drive), {d} finally (all ran to completion)", .{ eventually, finally });
}

/// A branch grown from a moment step by step (Antithesis's advanced multiverse debugging):
/// a command run to its end, one in the background (its output comes while the branch waits),
/// a wait, a wait-until that holds and one that times out, each step's end a moment.
fn check_steps(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const script = try std.fs.path.join(arena, &.{ context.scratch, "steps.txt" });
    const steps =
        \\echo first
        \\det:background sleep 0.2; echo background
        \\det:wait 500
        \\echo second
        \\det:background sleep 0.1; echo third
        \\det:until 2000 event=exec_output details.text~third
        \\det:until 300 assert.message="no such assertion"
        \\
    ;
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = steps });
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    const report = try explore(context, &.{
        "--program", program,   "--scenario",    "bank", "--seed", "3", "--branch", try bank_violating_branch(context),
        "--until",   violation, "--exec-script", script,
    });
    const first = std.mem.indexOf(u8, report, "\"text\":\"first\\n\"");
    const background = std.mem.indexOf(u8, report, "\"text\":\"background\\n\"");
    const second = std.mem.indexOf(u8, report, "\"text\":\"second\\n\"");
    const third = std.mem.indexOf(u8, report, "\"text\":\"third\\n\"");
    const in_order = first != null and background != null and second != null and third != null and
        first.? < background.? and background.? < second.? and second.? < third.?;
    // The moments: the violation's, the wait's end, the two until steps' ends.
    var moments: [8]u64 = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const key = "[determinismo] at moment vtime=";
        if (!std.mem.startsWith(u8, line, key) or count == moments.len) continue;
        const end = std.mem.indexOfScalarPos(u8, line, key.len, 'n') orelse continue;
        moments[count] = std.fmt.parseInt(u64, line[key.len..end], 10) catch continue;
        count += 1;
    }
    const waited = count >= 2 and moments[1] >= moments[0] + 500 * std.time.ns_per_ms;
    const timed_out = std.mem.indexOf(u8, report, "until: timed out") != null;
    const background_done = std.mem.indexOf(u8, report, "\"status\":0,\"id\":2,\"background\":true") != null;
    expect_all(context, &.{
        .{ "the outputs in order: first, background (during the wait), second, third", in_order },
        .{ "a moment at each step's end (4)", count == 4 },
        .{ "the wait took 500 ms of virtual time", waited },
        .{ "the background command ended on its own (status 0, id 2)", background_done },
        .{ "a wait-until that never holds times out (the other held: once)", timed_out and std.mem.count(u8, report, "until: timed out") == 1 },
    }, "steps: a branch from a moment, step by step ({d} moments)", .{count});
    try check_steps_fresh(context, program, violation);
}

/// Interactive sessions (serve's: explore --exec-interactive): steps from standard input, each
/// answered once done ("step done"), the machine paused between them, so a session is its steps:
/// run as a script, it says the same. And live (--exec-live): the guest running on between steps.
/// A session on a taped timeline is a timeline of the run (--extend): the run's next number, its
/// steps on its tape at their moments and its end there, so its replay is the session again.
fn check_session(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const steps = "echo first\nhead -c 8 /dev/urandom | od -An -tx1\ndet:wait 300\n" ++
        "head -c 8 /dev/urandom | od -An -tx1\n";
    const steps_path = try std.fs.path.join(arena, &.{ context.scratch, "session.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = steps_path, .data = steps });
    // The session's first step is the moment's no-op (det:here, the VMM's: the guest's agent not
    // woken): the script's too, the same steps.
    const script_path = try std.fs.path.join(arena, &.{ context.scratch, "session-script.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script_path, .data = "det:here\n" ++ steps });
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    const branch = try bank_violating_branch(context);
    const base = [_][]const u8{
        "--program", program, "--scenario", "bank", "--seed", "3", "--branch", branch, "--until", violation,
    };
    const session = try explore_stdin(context, &(base ++ [_][]const u8{"--exec-interactive"}), steps_path);
    const script = try explore(context, &(base ++ [_][]const u8{ "--exec-script", script_path }));
    const live = try explore_stdin(context, &(base ++ [_][]const u8{"--exec-live"}), steps_path);
    // As timelines of a run: one timeline recorded (its tape, events and record in a run's
    // directory), a session on it and a live one, each taking the run's next number.
    const run = try std.fs.path.join(arena, &.{ context.scratch, "session-run" });
    const tapes = try std.fs.path.join(arena, &.{ run, "tapes" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--timeline", "30s" };
    _ = try explore(context, &(common ++ [_][]const u8{
        "--seed",       "3",                                              "--branching", "flat",
        "--branches",   "1",                                              "--tape-dir",  tapes,
        "--events-dir", try std.fs.path.join(arena, &.{ run, "events" }), "--record",    try std.fs.path.join(arena, &.{ run, "record.jsonl" }),
    }));
    const at = [_][]const u8{ "--tape", try std.fs.path.join(arena, &.{ tapes, "branch-0.jsonl" }), "--at-vtime-ms", "3000" };
    const extended = try explore_stdin(context, &(common ++ at ++ [_][]const u8{ "--exec-interactive", "--extend" }), steps_path);
    const live_extended = try explore_stdin(context, &(common ++ at ++ [_][]const u8{ "--exec-live", "--extend" }), steps_path);
    // A fresh future's session: a timeline too (the run's next: 3), the seed it took on its tape.
    const fresh_extended = try explore_stdin(context, &(common ++ at ++ [_][]const u8{ "--exec-interactive", "--extend", "--fresh-seed", "7" }), steps_path);
    const fresh_replayed = try explore(context, &(common ++ [_][]const u8{ "--tape", try std.fs.path.join(arena, &.{ tapes, "branch-3.jsonl" }) }));
    // Each session's timeline replays it from its tape: the live one's too, its steps at their
    // moments, to where it ended.
    const replayed = try explore(context, &(common ++ [_][]const u8{ "--tape", try std.fs.path.join(arena, &.{ tapes, "branch-1.jsonl" }) }));
    const live_replayed = try explore(context, &(common ++ [_][]const u8{ "--tape", try std.fs.path.join(arena, &.{ tapes, "branch-2.jsonl" }) }));
    const record = std.Io.Dir.cwd().readFileAlloc(context.io, try std.fs.path.join(arena, &.{ run, "record.jsonl" }), arena, .unlimited) catch "";
    var ended: [6][1]Branch = undefined;
    const ended_all = for ([_][]const u8{ extended, replayed, live_extended, live_replayed, fresh_extended, fresh_replayed }, &ended) |report, *one| {
        if (parse_branches(report, one) != 1) break false;
    } else true;
    const session_texts = try exec_texts(arena, session);
    const script_texts = try exec_texts(arena, script);
    const same = session_texts.len == script_texts.len and for (session_texts, script_texts) |a, b| {
        if (!std.mem.eql(u8, a, b)) break false;
    } else true;
    const live_texts = try exec_texts(arena, live);
    const extended_texts = try exec_texts(arena, extended);
    const live_extended_texts = try exec_texts(arena, live_extended);
    const replayed_same = extended_texts.len == 3 and texts_equal(extended_texts, try exec_texts(arena, replayed));
    const live_replayed_same = live_extended_texts.len == 3 and texts_equal(live_extended_texts, try exec_texts(arena, live_replayed));
    const fresh_texts = try exec_texts(arena, fresh_extended);
    const live_first = for (live_texts) |text| {
        if (std.mem.eql(u8, text, "first\n")) break true;
    } else false;
    expect_all(context, &.{
        .{ "each step answered: the moment's, then the four", std.mem.count(u8, session, "[determinismo] step done") == 5 },
        .{ "its outputs: first, then two draws", session_texts.len == 3 and std.mem.eql(u8, session_texts[0], "first\n") },
        .{ "the session is its steps: run as a script, the same outputs", same },
        .{ "live: each step answered as the guest ran on", std.mem.count(u8, live, "[determinismo] step done") == 5 and live_first },
        .{ "a session on a taped timeline takes the run's next number, a second the one after", std.mem.indexOf(u8, extended, "[determinismo] timeline 1: timeline 0 from 3000 ms on") != null and std.mem.indexOf(u8, live_extended, "[determinismo] timeline 2: timeline 0 from 3000 ms on") != null },
        .{ "the run's record has the three, each extending timeline 0 from the moment", std.mem.count(u8, record, "\"extends\":{\"branch\":0,\"vtime_ns\":3000000000}") == 3 },
        .{ "the session's timeline replays it from its tape: the same outputs", replayed_same },
        .{ "and the same history, to where the session ended", ended_all and ended[0][0].index == 1 and std.mem.eql(u8, ended[0][0].events_hash, ended[1][0].events_hash) },
        .{ "the live session's timeline replays it, its steps at their moments", live_replayed_same },
        .{ "and the same history", ended_all and ended[2][0].index == 2 and std.mem.eql(u8, ended[2][0].events_hash, ended[3][0].events_hash) },
        .{ "a session with a fresh seed is a timeline too (3), its draws not the timeline's", fresh_texts.len == 3 and !texts_equal(fresh_texts, extended_texts) and std.mem.eql(u8, fresh_texts[0], "first\n") },
        .{ "its replay takes the same seed at the same moment: the same outputs and history", texts_equal(fresh_texts, try exec_texts(arena, fresh_replayed)) and ended_all and ended[4][0].index == 3 and std.mem.eql(u8, ended[4][0].events_hash, ended[5][0].events_hash) },
    }, "session: {d} outputs, the script's {d}, live {d}, as timelines {d} and {d}", .{ session_texts.len, script_texts.len, live_texts.len, extended_texts.len, live_extended_texts.len });
}

/// The fast VM for developing (docs/DEVELOPING.md): `run --vcpus 4 --dev <dir>` boots the bank
/// program's system on four vCPUs, which its guest brings up, and waits after its setup; a line
/// `explore-here` in its control FIFO saves the machine (its other CPUs offline first, back
/// after); explore --from-snapshot runs timelines from that snapshot, each starting the scenario,
/// and one timeline run twice has the same history.
fn check_fast(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const dev = try std.fs.path.join(arena, &.{ context.scratch, "fast-dev" });
    try cwd.createDirPath(context.io, dev);
    const log = try std.fs.path.join(arena, &.{ context.scratch, "fast-run.log" });
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "exec '{s}' run", .{context.determinismo});
    for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
    try command.print(arena, " --program '{s}' --scenario bank --vcpus 4 --dev '{s}' > '{s}' 2>&1", .{ program, dev, log });
    var child = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", command.items }, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(context.io);
    const waiting = log_wait(context, log, "dev_waiting", 1200);
    const control = try std.fmt.allocPrint(arena, "{s}/control", .{dev});
    if (waiting) {
        const control_z = try arena.dupeSentinel(u8, control, 0);
        const fd = std.os.linux.open(control_z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (std.os.linux.errno(fd) == .SUCCESS) {
            _ = std.os.linux.write(@intCast(fd), "explore-here\n", 13);
            _ = std.os.linux.close(@intCast(fd));
        }
    }
    const saved = waiting and log_wait(context, log, "explore from here:", 300);
    // The PIT's clock against the guest's TSC at the snapshot (on a host without TSC scaling it
    // ran 5.5% ahead: the snapshot's timer that share of the machine's age in the future).
    const skew_us: ?i64 = if (saved) skew: {
        const text = cwd.readFileAlloc(context.io, log, arena, .limited(1 << 26)) catch break :skew null;
        const at = std.mem.indexOf(u8, text, "clock skew ") orelse break :skew null;
        const start = at + "clock skew ".len;
        const end = std.mem.indexOfScalarPos(u8, text, start, ' ') orelse break :skew null;
        break :skew std.fmt.parseInt(i64, text[start..end], 10) catch null;
    } else null;
    const back = saved and log_wait(context, log, "explore_here_done", 60);
    // The guest's own count (the checks boot quiet: no kernel lines): three CPUs beside the first
    // went offline for the snapshot and came back.
    const booted = back and log_wait(context, log, "\"offline\":3,\"online\":3", 1);
    const snapshot = try std.fmt.allocPrint(arena, "{s}/here-1", .{dev});
    var timelines: u32 = 0;
    var started: bool = false;
    var same: bool = false;
    var snapshot_vtime_s: f64 = 0;
    var limited_vtime_s: f64 = 0;
    var drive_set = false;
    if (saved) {
        const base = [_][]const u8{ "--from-snapshot", snapshot, "--program", program, "--scenario", "bank", "--seed", "5" };
        const four = try explore(context, &(base ++ [_][]const u8{ "--branches", "4", "--branching", "flat" }));
        var branches: [4]Branch = undefined;
        timelines = parse_branches(four, &branches);
        started = std.mem.indexOf(u8, four, "test command started") != null;
        var hashes: [2][]const u8 = undefined;
        for (&hashes) |*hash| {
            const one = try explore(context, &(base ++ [_][]const u8{ "--branch", "2", "--branching", "flat" }));
            var single: [1]Branch = undefined;
            hash.* = if (parse_branches(one, &single) == 1) single[0].events_hash else "";
        }
        same = hashes[0].len > 0 and std.mem.eql(u8, hashes[0], hashes[1]);
        // A timeline limit counts from the snapshot, not from the machine's boot: one of 300 ms
        // from a snapshot taken later in the fast VM's life runs on past it (run 3 of a
        // Clojure system's REPL: every timeline from an hour-old checkpoint hung at its start).
        const limited = try explore(context, &(base ++ [_][]const u8{ "--branch", "2", "--branching", "flat", "--timeline-limit", "300ms" }));
        snapshot_vtime_s = vtime_after(limited, "snapshot at") orelse 0;
        limited_vtime_s = vtime_after(limited, "[branch") orelse 0;
        // Explore's settings reach the guest's composer (the fast VM's command line has none:
        // the platform gives the timeline's): its driver phase drawn under --drive-max.
        const events = try std.fs.path.join(arena, &.{ context.scratch, "fast-drive.jsonl" });
        _ = try explore(context, &(base ++ [_][]const u8{ "--branch", "1", "--branching", "flat", "--drive-max", "1500ms", "--events", events }));
        const drawn = cwd.readFileAlloc(context.io, events, arena, .limited(1 << 26)) catch "";
        drive_set = std.mem.indexOf(u8, drawn, "\"drive_drawn\"") != null and std.mem.indexOf(u8, drawn, "\"max_ms\":1500") != null;
    }
    // Its directory deleted (by hand, not through serve): the machine is no one's and ends.
    const running = waiting and !log_wait(context, log, "is gone", 0);
    try cwd.deleteTree(context.io, dev);
    const ended = running and log_wait(context, log, "is gone: the machine ends", 10);
    expect_all(context, &.{
        .{ "the fast VM ends once its directory is deleted", ended },
        .{ "its timer's clock keeps to the guest's TSC (skew under 5 ms at the snapshot)", if (skew_us) |us| @abs(us) < 5000 else false },
        .{ "the fast VM's guest runs on its four vCPUs (three offline and back)", booted },
        .{ "in dev mode it waits after its setup", waiting },
        .{ "explore-here writes a snapshot of it", saved },
        .{ "its other CPUs come back after", back },
        .{ "explore runs four timelines from that snapshot", timelines == 4 },
        .{ "each starts the scenario", started },
        .{ "a timeline run twice from it has the same history", same },
        .{ "a timeline limit counts from the snapshot", snapshot_vtime_s > 0.3 and limited_vtime_s >= snapshot_vtime_s + 0.25 },
        .{ "a timeline from it takes explore's settings (its driver phase under --drive-max)", drive_set },
    }, "fast: booted {}, waiting {}, saved {}, {d} timelines from it, replayed the same {}, ended with its directory {}, a 300 ms limit from the snapshot at {d:.1} s ended at {d:.1} s, clock skew {?d} us", .{
        booted, waiting, saved, timelines, same, ended, snapshot_vtime_s, limited_vtime_s, skew_us,
    });
}

/// The seconds of the first `vtime=<s>s` after `marker` in `output`.
fn vtime_after(output: []const u8, marker: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, output, marker) orelse return null;
    const found = std.mem.indexOfPos(u8, output, at, "vtime=") orelse return null;
    const start = found + "vtime=".len;
    const end = std.mem.indexOfScalarPos(u8, output, start, 's') orelse return null;
    return std.fmt.parseFloat(f64, output[start..end]) catch null;
}

/// CI on determinismo (docs/CI.md, examples/ci-demo): determinismo-ci on the demo's three
/// tests in three shards of twelve timelines each (a coin-flip test fails or passes in all six about 3% of
/// the time; all twelve, 1 in 2,048): the passing one's shard passes, the flaky one's
/// is flaky, the wrong one's fails, the job fails (exit 1), all one run; run again, its setup comes from the
/// cached snapshot and the verdicts are the same kinds. With a JUnit report (ci-junit.json, one
/// shard), each test is a property of its own and gets its own verdict.
fn check_ci(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7895";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-ci" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed: []const u8 = curl(context, &.{url ++ "/sandboxes"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    // determinismo-ci's path from the repository's root: the command runs in the demo's directory.
    const ci = try std.fs.path.join(arena, &.{ context.bin, "determinismo-ci" });
    const cache = try std.fs.path.join(arena, &.{ context.scratch, "ci-cache" });
    const command = try std.fmt.allocPrint(arena, "d=$(realpath '{s}') && c=$(realpath -m '{s}') && cd examples/ci-demo && \"$d\" --config ci.json --serve {s} --cache \"$c\" 2>&1", .{ ci, cache, url });
    var outputs: [2][]const u8 = undefined;
    var statuses: [2]u8 = undefined;
    for (&outputs, &statuses) |*output, *status| {
        const result = try run_kept(context, &.{ "sh", "-c", command });
        output.* = result.stdout;
        status.* = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
    }
    // Each job's run names its repository (git's where it ran, else its directory: ci-demo),
    // branch and commit: GET /runs lists it, the UI's CI page groups by it.
    const listed_runs = curl(context, &.{url ++ "/runs"}) catch "";
    const job_tagged = std.mem.indexOf(u8, listed_runs, "\"ci\":{\"repository\":") != null;
    const kinds = struct {
        fn all(text: []const u8) bool {
            return std.mem.indexOf(u8, text, ": pass ") != null and std.mem.indexOf(u8, text, ": flaky ") != null and
                std.mem.indexOf(u8, text, ": fail ") != null;
        }
    }.all;
    // The same tests in one shard with a JUnit report (ci-junit.json): each test its own
    // property, so its own verdict: the shard's failing test no longer hides its flaky one.
    const junit_command = try std.mem.replaceOwned(u8, arena, command, "--config ci.json", "--config ci-junit.json");
    const junit = try run_kept(context, &.{ "sh", "-c", junit_command });
    const per_test = std.mem.indexOf(u8, junit.stdout, "flaky  tests.test_demo::test_flaky: failing in ") != null and
        std.mem.indexOf(u8, junit.stdout, "fail   tests.test_demo::test_always_wrong: failing in 12 of 12") != null and
        std.mem.indexOf(u8, junit.stdout, "3 tests, 1 failing, 1 flaky") != null and
        std.mem.indexOf(u8, junit.stdout, "/property/test%20passes%3A%20") != null;
    // Timing faults by default: the injector started in every shard's timeline (a setup cached
    // before an update once ran its old det-faults, "Usage" and nothing injected, every verdict
    // still passing), read from serve as a user would; and no setup waited out an SDK's
    // declaration (five minutes in a fast VM's dev mode): the demo's is made in seconds.
    var timelines: u64 = 0;
    var started: u64 = 0;
    const Count = struct { timelines: u64 = 0, started: u64 = 0 };
    const listed = curl(context, &.{url ++ "/runs"}) catch "[]";
    const Listed = struct { id: u32 };
    const runs = std.json.parseFromSliceLeaky([]const Listed, arena, listed, .{ .ignore_unknown_fields = true }) catch &.{};
    // The tests' code covered with nothing in the repository asking for it (det-nodes exec
    // --coverage: Python's sitecustomize, nodes.zig): each job's run reports coverage (serve
    // stops a run whose first timelines report none: the demo's job of 12 timelines ended
    // "error" at 10), the tests' own lines and none of the interpreter's library.
    var runs_covered: u32 = 0;
    var tests_lines = false;
    var library_lines = false;
    for (runs) |listed_run| {
        const covered_sql = "{\"sql\":\"SELECT count(*) AS covered FROM (SELECT 1 FROM events WHERE name = 'coverage' LIMIT 1)\"}";
        const covered = curl(context, &.{ "-X", "POST", "-d", covered_sql, try std.fmt.allocPrint(arena, url ++ "/runs/{d}/sql", .{listed_run.id}) }) catch "[]";
        runs_covered += @intFromBool(std.mem.indexOf(u8, covered, "\"covered\":1") != null);
        const run_output = curl(context, &.{try std.fmt.allocPrint(arena, url ++ "/runs/{d}/output", .{listed_run.id})}) catch "";
        tests_lines = tests_lines or std.mem.indexOf(u8, run_output, "\"name\":\"line /app/tests/test_demo.py:") != null;
        library_lines = library_lines or std.mem.indexOf(u8, run_output, "\"name\":\"line /usr/local/lib/python") != null;
    }
    expect_all(context, &.{
        .{ "each job's run reports coverage, the repository asking for none", runs.len > 0 and runs_covered == runs.len },
        .{ "the tests' own lines", tests_lines },
        .{ "and none of the interpreter's library or its packages", !library_lines },
    }, "ci: {d} of {d} runs covered; the tests' lines {}; the library's {}", .{ runs_covered, runs.len, tests_lines, library_lines });
    for (runs) |listed_run| {
        const sql = "{\"sql\":\"SELECT count(DISTINCT timeline) AS timelines, count(DISTINCT timeline) FILTER (WHERE name = 'faults_start') AS started FROM timeline_events\"}";
        const answer = curl(context, &.{ "-X", "POST", "-d", sql, try std.fmt.allocPrint(arena, url ++ "/runs/{d}/sql", .{listed_run.id}) }) catch "[]";
        const rows = std.json.parseFromSliceLeaky([]const Count, arena, answer, .{ .ignore_unknown_fields = true }) catch &.{};
        for (rows) |row| {
            timelines += row.timelines;
            started += row.started;
        }
    }
    const made = std.mem.indexOf(u8, outputs[0], "setup: made in ") orelse outputs[0].len;
    const made_s = std.fmt.parseInt(u32, std.mem.sliceTo(outputs[0][@min(made + "setup: made in ".len, outputs[0].len)..], ' '), 10) catch std.math.maxInt(u32);
    expect_all(context, &.{
        .{ "timing faults started in every shard's timeline", timelines > 0 and started == timelines },
        .{ "its setup waited for no SDK's declaration (made in under 2 minutes)", made_s < 120 },
    }, "ci: {d} timelines, {d} with faults_start; setup made in {d} s", .{ timelines, started, made_s });
    // The runner sharding itself ({shard} inside a quoted awk program, as urllib3's config does):
    // each timeline's shard a number written in, every test run once a shard (a shell
    // expression there was never evaluated: 363 of urllib3's 2,141 tests ran).
    const shard_command = try std.mem.replaceOwned(u8, arena, command, "--config ci.json", "--config ci-shard.json");
    const sharded = try run_kept(context, &.{ "sh", "-c", shard_command });
    expect_all(context, &.{
        .{ "{shard} in a quoted program: every test reported, one failing, one flaky", std.mem.indexOf(u8, sharded.stdout, "3 tests, 1 failing, 1 flaky") != null },
    }, "ci, sharded by the runner:\n{s}", .{sharded.stdout[sharded.stdout.len -| 1500..]});
    expect_all(context, &.{
        .{ "with JUnit: each test its own verdict (one failing everywhere, one flaky), linked to its property", per_test },
        .{ "the demo's shards: one passes, one is flaky, one fails", kinds(outputs[0]) },
        .{ "a job is one run, its timelines the shards'", std.mem.count(u8, outputs[0], "determinismo-ci: testing: 3 shards of 12 timelines, run ") == 1 },
        .{ "each job's run tagged with where its tests come from (serve's CI page)", job_tagged },
        .{ "the job fails (exit 1)", statuses[0] == 1 },
        .{ "its setup made in a fast VM the first time", std.mem.indexOf(u8, outputs[0], "setup: made") != null },
        .{ "run again, its setup from the cached snapshot", std.mem.indexOf(u8, outputs[1], "setup: from its cached snapshot") != null },
        .{ "and the same kinds of verdicts", kinds(outputs[1]) and statuses[1] == 1 },
    }, "ci: exit {d} then {d}\n{s}\nwith JUnit:\n{s}", .{ statuses[0], statuses[1], outputs[0][outputs[0].len -| 1500..], junit.stdout[junit.stdout.len -| 1500..] });
}

/// Agent sandboxes (docs/SANDBOXES.md): determinismo-sandbox on serve's machines. One made from
/// the bank program's system, a command run in its node, a file written and read back, a
/// checkpoint, a step after it, the file changed; two forks from the checkpoint each find the
/// file as it was there; a rewind brings the sandbox back to it; its steps after the checkpoint
/// replay in a deterministic machine (the step reads the file as it was); timelines explored from
/// it run their scenario; deleted, its machine gone.
fn check_sandbox(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7894";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-sandbox" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed: []const u8 = curl(context, &.{url ++ "/machines"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const tool = struct {
        fn run(c: *Context, args: []const []const u8) []const u8 {
            var command: std.ArrayList([]const u8) = .empty;
            const binary = std.fs.path.join(c.arena, &.{ c.bin, "determinismo-sandbox" }) catch return "";
            const sandboxes = std.fs.path.join(c.arena, &.{ c.scratch, "sandboxes" }) catch return "";
            command.appendSlice(c.arena, &.{ binary, "--serve", "http://127.0.0.1:7894", "--data", sandboxes }) catch return "";
            command.appendSlice(c.arena, args) catch return "";
            const result = run_kept(c, command.items) catch return "";
            return std.mem.trimEnd(u8, result.stdout, "\n");
        }
    }.run;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const Made = struct { sandbox: u32 = 0 };
    const id = (std.json.parseFromSliceLeaky(Made, arena, tool(context, &.{ "create", "--program", program, "--scenario", "bank", "--vcpus", "2" }), .{ .ignore_unknown_fields = true }) catch Made{}).sandbox;
    const id_text = try std.fmt.allocPrint(arena, "{d}", .{id});
    const Exec = struct { status: i64 = -1, output: []const u8 = "" };
    const hello = std.json.parseFromSliceLeaky(Exec, arena, tool(context, &.{ "exec", id_text, "redis", "echo hello from $(hostname)" }), .{ .ignore_unknown_fields = true }) catch Exec{};
    const before = try std.fs.path.join(arena, &.{ context.scratch, "note-before.txt" });
    const after = try std.fs.path.join(arena, &.{ context.scratch, "note-after.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = before, .data = "before the checkpoint" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = after, .data = "after the checkpoint" });
    _ = tool(context, &.{ "write", id_text, "redis", "/tmp/note.txt", before });
    const read = tool(context, &.{ "read", id_text, "redis", "/tmp/note.txt" });
    const Checkpoint = struct { checkpoint: []const u8 = "" };
    const checkpoint = (std.json.parseFromSliceLeaky(Checkpoint, arena, tool(context, &.{ "checkpoint", id_text }), .{ .ignore_unknown_fields = true }) catch Checkpoint{}).checkpoint;
    // A step after the checkpoint, in its record: what a replay from it runs again.
    _ = tool(context, &.{ "exec", id_text, "redis", "cat /tmp/note.txt" });
    _ = tool(context, &.{ "write", id_text, "redis", "/tmp/note.txt", after });
    const changed = tool(context, &.{ "read", id_text, "redis", "/tmp/note.txt" });
    // A second checkpoint: only the pages changed since the first (a diff on it, its base).
    const second = (std.json.parseFromSliceLeaky(Checkpoint, arena, tool(context, &.{ "checkpoint", id_text }), .{ .ignore_unknown_fields = true }) catch Checkpoint{}).checkpoint;
    const Forked = struct { sandboxes: []const u32 = &.{} };
    const second_forks = (std.json.parseFromSliceLeaky(Forked, arena, tool(context, &.{ "fork", id_text, second, "1" }), .{ .ignore_unknown_fields = true }) catch Forked{}).sandboxes;
    var fork_cpus: Exec = .{};
    const second_read = if (second_forks.len == 1) read: {
        const fork_text = try std.fmt.allocPrint(arena, "{d}", .{second_forks[0]});
        defer _ = tool(context, &.{ "delete", fork_text });
        // Its other vCPUs back online (created before the interrupt controllers' restore).
        fork_cpus = std.json.parseFromSliceLeaky(Exec, arena, tool(context, &.{ "exec", fork_text, "redis", "cat /sys/devices/system/cpu/online" }), .{ .ignore_unknown_fields = true }) catch Exec{};
        break :read tool(context, &.{ "read", fork_text, "redis", "/tmp/note.txt" });
    } else "";
    const forks = (std.json.parseFromSliceLeaky(Forked, arena, tool(context, &.{ "fork", id_text, checkpoint, "2" }), .{ .ignore_unknown_fields = true }) catch Forked{}).sandboxes;
    var forks_see_before: u32 = 0;
    for (forks) |fork| {
        const fork_text = try std.fmt.allocPrint(arena, "{d}", .{fork});
        if (std.mem.eql(u8, tool(context, &.{ "read", fork_text, "redis", "/tmp/note.txt" }), "before the checkpoint")) forks_see_before += 1;
        _ = tool(context, &.{ "delete", fork_text });
    }
    _ = tool(context, &.{ "rewind", id_text, checkpoint });
    const rewound = tool(context, &.{ "read", id_text, "redis", "/tmp/note.txt" });
    const Run = struct { run: u32 = 0 };
    const replay_id = (std.json.parseFromSliceLeaky(Run, arena, tool(context, &.{ "replay", id_text, checkpoint }), .{ .ignore_unknown_fields = true }) catch Run{}).run;
    const explore_id = (std.json.parseFromSliceLeaky(Run, arena, tool(context, &.{ "explore", id_text, checkpoint, "2" }), .{ .ignore_unknown_fields = true }) catch Run{}).run;
    var outputs: [2][]const u8 = undefined;
    for ([_]u32{ replay_id, explore_id }, &outputs) |run_id, *output| {
        for (0..1200) |_| {
            const run_state = curl(context, &.{try std.fmt.allocPrint(arena, url ++ "/runs/{d}", .{run_id})}) catch "";
            if (run_state.len > 0 and std.mem.indexOf(u8, run_state, "\"state\":\"running\"") == null) break;
            sleep_ms(500);
        }
        output.* = curl(context, &.{try std.fmt.allocPrint(arena, url ++ "/runs/{d}/output", .{run_id})}) catch "";
    }
    // A timeline of the run from the checkpoint replayed through serve (a session's replay
    // alike): from the checkpoint, its history the recorded one.
    var recorded: [2]Branch = undefined;
    const recorded_count = parse_branches(outputs[1], &recorded);
    const replayed_output = if (explore_id > 0 and recorded_count > 0) curl(context, &.{
        "-X",                                                                    "POST", "-d", try std.fmt.allocPrint(arena, "{{\"branch\":{d}}}", .{recorded[0].index}),
        try std.fmt.allocPrint(arena, url ++ "/runs/{d}/replay", .{explore_id}),
    }) catch "" else "";
    const replayed_same = recorded_count > 0 and
        std.mem.indexOf(u8, replayed_output, try std.fmt.allocPrint(arena, "events_hash={s}", .{recorded[0].events_hash})) != null;
    // The flat run's timelines in its activity (serve's per-minute charts read them).
    const activity_text = std.Io.Dir.cwd().readFileAlloc(context.io, try std.fmt.allocPrint(arena, "{s}/runs/{d}/activity.jsonl", .{ data, explore_id }), arena, .limited(1 << 24)) catch "";
    const activity_timelines = std.mem.count(u8, activity_text, "\"a\":\"timeline\"");
    const Listed = struct { sandbox: u32 = 0, machine: u32 = 0 };
    const listed = std.json.parseFromSliceLeaky([]const Listed, arena, tool(context, &.{"list"}), .{ .ignore_unknown_fields = true }) catch &.{};
    const machine = for (listed) |entry| {
        if (entry.sandbox == id) break entry.machine;
    } else 0;
    _ = tool(context, &.{ "delete", id_text });
    const machines = curl(context, &.{url ++ "/machines"}) catch "";
    expect_all(context, &.{
        .{ "a sandbox made from the bank program's system", id > 0 },
        .{ "a command runs in its node", hello.status == 0 and std.mem.indexOf(u8, hello.output, "hello from") != null },
        .{ "a file written there reads back", std.mem.eql(u8, read, "before the checkpoint") },
        .{ "a checkpoint is named", checkpoint.len > 0 },
        .{ "the file changes after it", std.mem.eql(u8, changed, "after the checkpoint") },
        .{ "a fork from a second checkpoint (a diff on the first) finds the file as then", std.mem.eql(u8, second_read, "after the checkpoint") },
        .{ "a fork has all its CPUs online", std.mem.eql(u8, std.mem.trim(u8, fork_cpus.output, " \n"), "0-1") },
        .{ "two forks from the checkpoint find the file as it was", forks.len == 2 and forks_see_before == 2 },
        .{ "a rewind brings the sandbox back to it", std.mem.eql(u8, rewound, "before the checkpoint") },
        .{ "its steps after the checkpoint replay in a deterministic machine", replay_id > 0 and std.mem.indexOf(u8, outputs[0], "before the checkpoint") != null },
        .{ "timelines explored from it run their scenario", explore_id > 0 and std.mem.indexOf(u8, outputs[1], "test command started") != null },
        .{ "one of them replayed through serve has its recorded history", replayed_same },
        .{ "the run's activity has each of its timelines", recorded_count > 0 and activity_timelines == recorded_count },
        .{ "a deleted sandbox's machine is gone", machine > 0 and std.mem.indexOf(u8, machines, try std.fmt.allocPrint(arena, "\"machine\":{d},", .{machine})) == null },
    }, "sandbox: {d}, exec {d}, read \"{s}\", checkpoint {s}, forks {d} ({d} saw it), a fork's CPUs \"{s}\", rewound \"{s}\", replay run {d}, explore run {d}", .{
        id, hello.status, read, checkpoint, forks.len, forks_see_before, std.mem.trim(u8, fork_cpus.output, " \n"), rewound, replay_id, explore_id,
    });
}

/// A sandbox's egress, carried by its checkpoints (docs/SANDBOXES.md), on a serve given two run
/// CPUs: a node allowed a local site reads a page through its proxy; a fork of a checkpoint
/// taken after that reads it too, and so does the sandbox rewound to it (the proxy came with the
/// checkpoint, the host's relay is added: an agent's model calls in its forks), and its steps
/// replayed in a deterministic machine (the run's egress, the proxy asking its channel at each
/// connection). Machines share a CPU among themselves (two each here, `--machines-per-cpu 2`):
/// the sandbox and its first fork sit on one CPU, the next two forks on the other, four
/// machines on two CPUs. With every place taken, one more is refused at once, saying so (it
/// waited ten minutes for a CPU that could not come, then failed without a reason); and one
/// asked of a second serve on the same CPUs, which has no machine of its own to count, is given
/// up after that serve's `--machine-start-seconds` and its process stopped (it was left, and
/// took a CPU when one came free: a machine of no one's). A deleted sandbox leaves the list.
/// The replay's deterministic VM then runs on the CPU the forks left, never the sandbox's.
fn check_sandbox_egress(context: *Context) !void {
    const arena = context.arena;
    const linux = std.os.linux;
    const address = "127.0.0.1:7911";
    const url = "http://" ++ address;
    const site_address = "127.0.0.1:7912";
    const site = try std.fs.path.join(arena, &.{ context.scratch, "sandbox-egress-site" });
    try std.Io.Dir.cwd().createDirPath(context.io, site);
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ site, "page.txt" }),
        .data = "out of the sandbox and back\n",
    });
    var site_server = try std.process.spawn(context.io, .{
        .argv = &.{ "python3", "-m", "http.server", "7912", "--bind", "127.0.0.1", "--directory", site },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer site_server.kill(context.io);
    // serve on two of this process's CPUs: its pool (cpus.zig: the CPUs it was given).
    var given: linux.cpu_set_t = @splat(0);
    _ = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &given);
    var two: std.ArrayList(u8) = .empty;
    var taken: u32 = 0;
    const bits = @bitSizeOf(@TypeOf(given[0]));
    for (0..given.len * bits) |cpu| {
        if (taken == 2) break;
        if (given[cpu / bits] >> @intCast(cpu % bits) & 1 == 0) continue;
        try two.print(arena, "{s}{d}", .{ if (taken > 0) "," else "", cpu });
        taken += 1;
    }
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-sandbox-egress" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "taskset", "-c", two.items, context.determinismo, "serve", "--listen", address, "--data", data, "--machines-per-cpu", "2",
    });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed: []const u8 = curl(context, &.{url ++ "/machines"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const tool = struct {
        /// The tool's standard output, then its standard error (a refusal's reason is there).
        fn run(c: *Context, args: []const []const u8) []const u8 {
            var command: std.ArrayList([]const u8) = .empty;
            const binary = std.fs.path.join(c.arena, &.{ c.bin, "determinismo-sandbox" }) catch return "";
            const sandboxes = std.fs.path.join(c.arena, &.{ c.scratch, "sandboxes-egress" }) catch return "";
            // Bounded: a fetch through a proxy with no way out waits its 20 s at each try.
            command.appendSlice(c.arena, &.{ "timeout", "700", binary, "--serve", "http://127.0.0.1:7911", "--data", sandboxes }) catch return "";
            command.appendSlice(c.arena, args) catch return "";
            const result = run_kept(c, command.items) catch return "";
            return std.mem.concat(c.arena, u8, &.{ std.mem.trimEnd(u8, result.stdout, "\n"), result.stderr }) catch "";
        }
    }.run;
    // The page through the node's proxy: a CONNECT to the site, then a GET inside it; tried
    // again (a deterministic machine draws faults at the boundary).
    const fetch = "for i in 1 2 3 4 5 6 7 8; do out=$( (printf 'CONNECT " ++ site_address ++ " HTTP/1.1\\r\\nHost: site\\r\\n\\r\\n'; sleep 1; " ++
        "printf 'GET /page.txt HTTP/1.0\\r\\nHost: site\\r\\n\\r\\n'; sleep 2) | timeout 20 nc 127.0.0.1 3128 2>&1 ); " ++
        "case \"$out\" in *'and back'*) echo \"$out\" | tail -1; break;; esac; done";
    const page = "out of the sandbox and back";
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const Made = struct { sandbox: u32 = 0 };
    const id = (std.json.parseFromSliceLeaky(Made, arena, tool(context, &.{ "create", "--program", program, "--scenario", "bank", "--vcpus", "2" }), .{ .ignore_unknown_fields = true }) catch Made{}).sandbox;
    const id_text = try std.fmt.allocPrint(arena, "{d}", .{id});
    const allowed = tool(context, &.{ "egress", id_text, "redis", site_address });
    const first = tool(context, &.{ "exec", id_text, "redis", fetch });
    const Checkpoint = struct { checkpoint: []const u8 = "" };
    const checkpoint = (std.json.parseFromSliceLeaky(Checkpoint, arena, tool(context, &.{ "checkpoint", id_text }), .{ .ignore_unknown_fields = true }) catch Checkpoint{}).checkpoint;
    // A step after the checkpoint, in its record: what a replay from it runs again.
    _ = tool(context, &.{ "exec", id_text, "redis", fetch });
    const Forked = struct { sandboxes: []const u32 = &.{} };
    const forks = (std.json.parseFromSliceLeaky(Forked, arena, tool(context, &.{ "fork", id_text, checkpoint, "1" }), .{ .ignore_unknown_fields = true }) catch Forked{}).sandboxes;
    const fork_text = if (forks.len == 1) try std.fmt.allocPrint(arena, "{d}", .{forks[0]}) else "0";
    const forked = if (forks.len == 1) tool(context, &.{ "exec", fork_text, "redis", fetch }) else "";
    // Where each machine is pinned (serve numbers them as they are made: the sandbox's 1, its
    // forks' 2 to 4), read from its process.
    const machine_cpu = struct {
        fn of(c: *Context, serve_data: []const u8, machine: u32) []const u8 {
            const command = std.fmt.allocPrint(c.arena, "grep Cpus_allowed_list /proc/$(cat '{s}/machines/{d}/pid')/status | cut -f2", .{ serve_data, machine }) catch return "";
            const result = run_kept(c, &.{ "sh", "-c", command }) catch return "";
            return std.mem.trim(u8, result.stdout, " \t\n");
        }
    }.of;
    // Two more forks: the first CPU has its two machines, they take the other.
    const more = (std.json.parseFromSliceLeaky(Forked, arena, tool(context, &.{ "fork", id_text, checkpoint, "2" }), .{ .ignore_unknown_fields = true }) catch Forked{}).sandboxes;
    const cpu_of = [_][]const u8{ machine_cpu(context, data, 1), machine_cpu(context, data, 2), machine_cpu(context, data, 3), machine_cpu(context, data, 4) };
    // Every place taken now (two CPUs, two machines each): a fifth is refused at once.
    const refused_start = monotonic_ns();
    const refused = tool(context, &.{ "fork", id_text, checkpoint, "1" });
    const refused_s = (monotonic_ns() - refused_start) / std.time.ns_per_s;
    // A second serve on the same two CPUs, giving a machine 5 s to start: its machine waits
    // for a CPU the first serve's machines hold, is given up, and is stopped.
    const other_data = try std.fs.path.join(arena, &.{ context.scratch, "serve-sandbox-egress-other" });
    var other_argv: std.ArrayList([]const u8) = .empty;
    try other_argv.appendSlice(arena, &.{
        "taskset",            "-c", two.items, context.determinismo, "serve", "--listen", "127.0.0.1:7913", "--data", other_data, "--machine-start-seconds", "5",
        "--machines-per-cpu", "2",
    });
    try other_argv.appendSlice(arena, context.machine);
    var other = try std.process.spawn(context.io, .{ .argv = other_argv.items, .stdout = .ignore, .stderr = .ignore });
    defer other.kill(context.io);
    for (0..50) |_| {
        const up: []const u8 = curl(context, &.{"http://127.0.0.1:7913/machines"}) catch "";
        if (up.len > 0) break;
        sleep_ms(100);
    }
    const given_up = (run_kept(context, &.{
        "curl",                                                                                                 "-s",                             "-H", "Content-Type: application/json", "-d",
        try std.fmt.allocPrint(arena, "{{\"program\":\"{s}\",\"scenario\":\"bank\",\"vcpus\":2}}", .{program}), "http://127.0.0.1:7913/machines",
    }) catch return error.RequestFailed).stdout;
    const given_up_pid_text = std.Io.Dir.cwd().readFileAlloc(context.io, try std.fs.path.join(arena, &.{ other_data, "machines", "1", "pid" }), arena, .limited(64)) catch "";
    const given_up_pid = std.fmt.parseInt(i32, std.mem.trim(u8, given_up_pid_text, " \n"), 10) catch 0;
    sleep_ms(500);
    const given_up_runs = given_up_pid > 0 and linux.errno(linux.kill(given_up_pid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
    _ = tool(context, &.{ "delete", fork_text });
    for (more) |fork| _ = tool(context, &.{ "delete", try std.fmt.allocPrint(arena, "{d}", .{fork}) });
    const listed = tool(context, &.{"list"});
    _ = tool(context, &.{ "rewind", id_text, checkpoint });
    const rewound = tool(context, &.{ "exec", id_text, "redis", fetch });
    const Run = struct { run: u32 = 0 };
    const replay_id = (std.json.parseFromSliceLeaky(Run, arena, tool(context, &.{ "replay", id_text, checkpoint }), .{ .ignore_unknown_fields = true }) catch Run{}).run;
    if (replay_id > 0) for (0..1200) |_| {
        const run_state = curl(context, &.{try std.fmt.allocPrint(arena, url ++ "/runs/{d}", .{replay_id})}) catch "";
        if (run_state.len > 0 and std.mem.indexOf(u8, run_state, "\"state\":\"running\"") == null) break;
        sleep_ms(500);
    };
    const replayed = if (replay_id > 0) curl(context, &.{try std.fmt.allocPrint(arena, url ++ "/runs/{d}/output", .{replay_id})}) catch "" else "";
    _ = tool(context, &.{ "delete", id_text });
    expect_all(context, &.{
        .{ "a sandbox's node is given a way out", id > 0 and std.mem.indexOf(u8, allowed, "\"proxy\"") != null },
        .{ "it reads the allowed site's page", std.mem.indexOf(u8, first, page) != null },
        .{ "a fork of a checkpoint taken after reads it too", forks.len == 1 and std.mem.indexOf(u8, forked, page) != null },
        .{ "the sandbox and its first fork share a CPU", cpu_of[0].len > 0 and std.mem.indexOfAny(u8, cpu_of[0], ",-") == null and std.mem.eql(u8, cpu_of[0], cpu_of[1]) },
        .{ "the next two forks share the other", more.len == 2 and cpu_of[2].len > 0 and !std.mem.eql(u8, cpu_of[2], cpu_of[0]) and std.mem.eql(u8, cpu_of[2], cpu_of[3]) },
        .{ "with every place taken, one more is refused at once, saying so", refused_s < 30 and std.mem.indexOf(u8, refused, "every place for a machine is taken (4 of 4") != null },
        .{ "a machine that got no CPU in its serve's time is given up, saying so", std.mem.indexOf(u8, given_up, "was not up after 5 s") != null },
        .{ "and its process is stopped", given_up_pid > 0 and !given_up_runs },
        .{ "a deleted sandbox leaves the list", forks.len == 1 and std.mem.indexOf(u8, listed, try std.fmt.allocPrint(arena, "\"sandbox\":{s},", .{fork_text})) == null and
            std.mem.indexOf(u8, listed, try std.fmt.allocPrint(arena, "\"sandbox\":{d},", .{id})) != null },
        .{ "the sandbox rewound to the checkpoint reads it", std.mem.indexOf(u8, rewound, page) != null },
        .{ "its steps replayed in a deterministic machine read it", replay_id > 0 and std.mem.indexOf(u8, replayed, page) != null },
    }, "sandbox-egress: {d}, first \"{s}\", fork {s} \"{s}\", machines on CPUs {s} {s} {s} {s}, a fifth refused in {d} s (\"{s}\"), another serve's given up \"{s}\" (pid {d}, {s}), rewound \"{s}\", replay run {d}", .{
        id,                                             std.mem.trim(u8, first[0..@min(first.len, 60)], " \n"),      fork_text,                                                     std.mem.trim(u8, forked[0..@min(forked.len, 60)], " \n"),
        cpu_of[0],                                      cpu_of[1],                                                   cpu_of[2],                                                     cpu_of[3],
        refused_s,                                      std.mem.trim(u8, refused[0..@min(refused.len, 140)], " \n"), std.mem.trim(u8, given_up[0..@min(given_up.len, 160)], " \n"), given_up_pid,
        if (given_up_runs) "still running" else "gone", std.mem.trim(u8, rewound[0..@min(rewound.len, 60)], " \n"),  replay_id,
    });
}

/// Whether `text` appears in the file at `path` within `seconds` (polled; each read freed, not
/// the arena's: a long wait reads a growing log thousands of times).
fn log_wait(context: *Context, path: []const u8, text: []const u8, seconds: u32) bool {
    const allocator = std.heap.page_allocator;
    for (0..seconds * 4) |_| {
        const content = std.Io.Dir.cwd().readFileAlloc(context.io, path, allocator, .limited(1 << 26)) catch "";
        defer if (content.len > 0) allocator.free(content);
        if (std.mem.indexOf(u8, content, text) != null) return true;
        sleep_ms(250);
    }
    return false;
}

/// A REPL inside the guest, as a person at CIDER uses it: a Clojure program's run (tests/repl),
/// a session at its scenario's start, its nREPL server started (run nrepl), and through the
/// relay a service with a known race written there with its workload: 64 threads transferring
/// between accounts without a lock, the money they should keep asserted. Its answers come back
/// over nREPL, and so does its verdict: the race loses money.
/// infra/host/nrepl-proxy.py --dev's replies whole whatever the reads of the machine's events
/// cut: the guest played here, deterministically. Message 1's reply, its nrepl_done and the
/// first part of a reply the server sent by itself (output a thread printed) in one write;
/// message 2's answer with that reply's last part first. The client gets reply 1, the whole
/// unasked reply, reply 2 (the proxy dropped what it read past nrepl_done: the unasked reply's
/// tail alone reached the client, its bencode broken, examples/clj-orders).
fn check_devproxy(context: *Context) !void {
    const arena = context.arena;
    const linux = std.os.linux;
    const cwd = std.Io.Dir.cwd();
    const dev = try std.fs.path.join(arena, &.{ context.scratch, "devproxy" });
    try cwd.createDirPath(context.io, dev);
    const control = try std.fmt.allocPrintSentinel(arena, "{s}/control", .{dev}, 0);
    _ = linux.unlink(control);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, control, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.FifoFailed;
    const events_path = try std.fmt.allocPrintSentinel(arena, "{s}/events.jsonl", .{dev}, 0);
    const events_opened = linux.open(events_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(events_opened) != .SUCCESS) return error.EventsFailed;
    const events: linux.fd_t = @intCast(events_opened);
    defer _ = linux.close(events);
    // The control FIFO open read and write first: the proxy's open for writing never blocks.
    const control_opened = linux.open(control, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(control_opened) != .SUCCESS) return error.FifoFailed;
    const control_fd: linux.fd_t = @intCast(control_opened);
    defer _ = linux.close(control_fd);
    const port = "7898";
    var proxy = try std.process.spawn(context.io, .{
        .argv = &.{ "python3", "infra/host/nrepl-proxy.py", "--dev", dev, "--node", "app", "--listen", "127.0.0.1:" ++ port },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer proxy.kill(context.io);
    // It starts the relay in the node before it listens: that action answered first.
    const relay_started = if (devproxy_action(context, control_fd)) |action|
        std.mem.indexOf(u8, action, "det-nrepl-relay") != null
    else |_|
        false;
    if (relay_started) {
        const ready = "{\"event\":{\"event\":\"nrepl_relay_ready\",\"details\":{}}}\n";
        _ = linux.write(events, ready, ready.len);
    }
    const reply_1 = "d2:id2:m15:value1:1e";
    const unasked = "d2:id2:m13:out25:printed by a thread, latee";
    const reply_2 = "d2:id2:m25:value1:2e";
    // The client: both messages, one after the other's replies.
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    const client: linux.fd_t = @intCast(socket);
    defer _ = linux.close(client);
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 7898), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const connected = relay_started and for (0..100) |_| {
        if (linux.errno(linux.connect(client, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) == .SUCCESS) break true;
        sleep_ms(100);
    } else false;
    var received: std.ArrayList(u8) = .empty;
    if (connected) {
        for ([_][]const u8{ "d2:id2:m12:op4:evale", "d2:id2:m22:op4:evale" }, 0..) |message, index| {
            _ = linux.write(client, message.ptr, message.len);
            try devproxy_guest(context, control_fd, events, index);
            const want = if (index == 0) reply_1.len else unasked.len + reply_2.len;
            const before = received.items.len;
            var buffer: [4096]u8 = undefined;
            for (0..50) |_| {
                if (received.items.len - before >= want) break;
                var fds = [_]linux.pollfd{.{ .fd = client, .events = linux.POLL.IN, .revents = 0 }};
                if (linux.poll(&fds, 1, 100) <= 0) continue;
                const result = linux.read(client, &buffer, buffer.len);
                if (linux.errno(result) != .SUCCESS or result == 0) break;
                try received.appendSlice(arena, buffer[0..result]);
            }
        }
    }
    const expected = reply_1 ++ unasked ++ reply_2;
    expect_all(context, &.{
        .{ "the proxy starts the relay, then a client reaches it", connected },
        .{ "its replies come whole, an unasked one across two messages' events too", std.mem.eql(u8, received.items, expected) },
    }, "devproxy: received \"{s}\"", .{received.items});
}

/// The next line written to the dev control FIFO (10 s at most).
fn devproxy_action(context: *Context, control: std.os.linux.fd_t) ![]const u8 {
    const linux = std.os.linux;
    var line: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = control, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&fds, 1, 10_000) <= 0) return error.NoAction;
        if (linux.read(control, &byte, 1) != 1) return error.NoAction;
        if (byte[0] == '\n') return line.items;
        try line.append(context.arena, byte[0]);
    }
}

/// The guest's side of check_devproxy for message `index`: the relay started once (its start
/// action), the message's parts read from the control FIFO, then its events written.
fn devproxy_guest(context: *Context, control: std.os.linux.fd_t, events: std.os.linux.fd_t, index: usize) !void {
    const linux = std.os.linux;
    const arena = context.arena;
    // Actions until this message's det:send.
    while (std.mem.indexOf(u8, try devproxy_action(context, control), "det:send") == null) {}
    const Event = struct {
        fn reply(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, last: bool) !void {
            var encoded: [256]u8 = undefined;
            const data = std.base64.standard.Encoder.encode(&encoded, bytes);
            try list.print(allocator, "{{\"event\":{{\"event\":\"nrepl_reply\",\"details\":{{\"data\":\"{s}\",\"last\":{}}}}}}}\n", .{ data, last });
        }
        fn done(list: *std.ArrayList(u8), allocator: std.mem.Allocator, id: []const u8) !void {
            try list.print(allocator, "{{\"event\":{{\"event\":\"nrepl_done\",\"details\":{{\"id\":\"{s}\"}}}}}}\n", .{id});
        }
    };
    const unasked = "d2:id2:m13:out25:printed by a thread, latee";
    const split = 20;
    var out: std.ArrayList(u8) = .empty;
    if (index == 0) {
        try Event.reply(&out, arena, "d2:id2:m15:value1:1e", true);
        try Event.done(&out, arena, "m1");
        try Event.reply(&out, arena, unasked[0..split], false);
    } else {
        try Event.reply(&out, arena, unasked[split..], true);
        try Event.reply(&out, arena, "d2:id2:m25:value1:2e", true);
        try Event.done(&out, arena, "m2");
    }
    _ = linux.write(events, out.items.ptr, out.items.len);
}

fn check_repl(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7892";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-repl" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "repl-test" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .scenario = "repl",
        .seed = 1,
        .branches = 1,
        .memory_mib = 2048,
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    // Its one timeline done (the image built the first time: minutes).
    for (0..3600) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const opened = try curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0,\"until\":\"event=composer_start\"}", url ++ "/runs/1/session" });
    const Opened = struct { session: u32 = 0, timeline: ?u32 = null, done: bool = true };
    const first = try std.json.parseFromSliceLeaky(Opened, arena, opened, .{ .ignore_unknown_fields = true });
    const session = first.session;
    const step_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{session});
    // The client's REPL is warm (its node's command, up before the setup's snapshot): the
    // relay connects at once, no server started for the session.
    _ = try repl_step(context, step_url, "det:background det-nodes exec client /opt/determinismo/bin/det-nrepl-relay serve 7888 " ++ repl_fifo);
    const listening = try repl_step(context, step_url, "det:until 1500 event=nrepl_relay_ready");
    const started = std.mem.indexOf(u8, listening, "nrepl_relay_ready") != null;
    const clone = try nrepl_eval(context, step_url, &.{ .{ "id", "1" }, .{ "op", "clone" } });
    const nrepl_session = nrepl_field(clone, "new-session") orelse "";
    const forms = [_][]const u8{
        "(+ 1 2)",
        "(do (require '[determinismo.workload :as w])" ++
            " (def accounts (vec (repeatedly 8 #(atom 100))))" ++
            " (defn total [] (reduce + (map deref accounts)))" ++
            " (defn transfer! [from to amount] (let [balance @(accounts from)] (when (>= balance amount)" ++
            " (Thread/yield) (reset! (accounts from) (- balance amount)) (swap! (accounts to) + amount))))" ++
            " (run! deref (doall (for [_ (range 64)] (future (dotimes [_ 50]" ++
            " (transfer! (w/random-below 8) (w/random-below 8) (inc (w/random-below 20))))))))" ++
            " (w/always (= 800 (total)) \"the bank keeps its money\" {:total (total)})" ++
            " (total))",
        // The runner's commands from the REPL (det_runner): the peer node seen, killed, down,
        // started again.
        "(:stdout (w/node-exec :peer \"hostname\"))",
        "(:status (w/node! :kill :peer))",
        "(:status (w/node-exec :peer \"true\"))",
        "(do (w/node! :start :peer) (:stdout (w/node-exec :peer \"hostname\")))",
        // serve from inside the machine (sdk.serve): its runs, and its sessions refused (they
        // would wait on the machine asking).
        "(let [{:keys [status body]} (w/serve :get \"/runs\")] (str status \" \" (count body)))",
        "(:status (w/serve :post \"/sessions/1/step\" {:exec \"true\"}))",
        // The machine cloned where it stands: 0 here, k in future k, which says so and ends.
        "(let [k (w/fork! 2)] (when (pos? k) (w/always false \"a future of the REPL ran\" {:k k})) k)",
        // The fork's futures, a run serve lists from inside the machine once its snapshot is
        // written (by a copy-on-write child, after the fork's evaluation returned): looked for
        // again as a person at the REPL would.
        "(loop [tries 0] (let [n (count (w/fork-runs 1))] (if (or (pos? n) (= tries 300)) n (do (Thread/sleep 100) (recur (inc tries))))))",
    };
    var values: [forms.len][]const u8 = undefined;
    var outputs: [forms.len][]const u8 = undefined;
    for (forms, &values, &outputs, 0..) |form, *value, *output, index| {
        const id = try std.fmt.allocPrint(arena, "{d}", .{index + 2});
        const replies = try nrepl_eval(context, step_url, &.{
            .{ "code", form }, .{ "id", id }, .{ "op", "eval" }, .{ "session", nrepl_session },
        });
        value.* = nrepl_field(replies, "value") orelse "";
        output.* = replies;
    }
    // A checkpoint of the warm REPL, its bank defined: after the server's death below, a session
    // at it has the server and its definitions back, from the machine saved there.
    const checkpointed = try repl_step(context, step_url, "det:checkpoint warm");
    // The REPL's server dies in an evaluation (a crash in what it ran): the session answers at
    // once, its machine not waiting out the ask's 600 s on a server gone.
    const uptime_before = guest_uptime_s(try repl_step(context, step_url, "cat /proc/uptime"));
    const halted = try nrepl_eval(context, step_url, &.{
        .{ "code", "(.halt (Runtime/getRuntime) 1)" }, .{ "id", "halt" }, .{ "op", "eval" }, .{ "session", nrepl_session },
    });
    const uptime_after = guest_uptime_s(try repl_step(context, step_url, "cat /proc/uptime"));
    const halt_s = uptime_after - uptime_before;
    // The fork's futures: started from its snapshot once written, each to its timeline's end.
    var forks: []const u8 = "";
    const forks_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/forks", .{session});
    for (0..600) |_| {
        forks = curl(context, &.{ "-X", "POST", "-d", "{}", forks_url }) catch "";
        if (std.mem.indexOf(u8, forks, "\"done\":true") != null) break;
        sleep_ms(500);
    }
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{session}) }) catch "";
    // The session's timeline replayed to where the evaluation that read serve's runs was done
    // (the form at index 6, its message's id 8: a moment named by its event): its steps from its
    // tape, serve's replies to the guest too, the same as they were.
    const replay_body = try std.fmt.allocPrint(arena, "{{\"branch\":{d},\"until\":\"event=nrepl_done details.id=\\\"8\\\"\",\"exec\":\":\"}}", .{first.timeline orelse 0});
    const replay = curl(context, &.{ "-X", "POST", "-d", replay_body, url ++ "/runs/1/replay" }) catch "";
    const replayed_serve = nrepl_replies_have(arena, replay, "7:\"200 1\"");
    // Back to the checkpoint after the crash: a session on the timeline at its event, the same
    // nREPL session evaluating there.
    const resume_body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .branch = first.timeline orelse 0,
        .until = "event=session_checkpoint details.name=warm",
    }, .{})});
    const Resumed = struct { session: u32 = 0, output: []const u8 = "" };
    const resumed = std.json.parseFromSliceLeaky(Resumed, arena, curl(context, &.{ "-X", "POST", "-d", resume_body, url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Resumed{};
    const resumed_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{resumed.session});
    const resumed_total = if (resumed.session > 0) nrepl_field(nrepl_eval(context, resumed_url, &.{
        .{ "code", "(total)" }, .{ "id", "resumed" }, .{ "op", "eval" }, .{ "session", nrepl_session },
    }) catch "", "value") orelse "" else "";
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{resumed.session}) }) catch "";
    // The same through nrepl-proxy.py, as an editor uses it: its det-checkpoint and det-resume
    // ops between evaluations.
    var proxy = try std.process.spawn(context.io, .{
        .argv = &.{ "python3", "infra/host/nrepl-proxy.py", "--serve", url, "--run", "1", "--node", "client", "--listen", "127.0.0.1:7898" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer proxy.kill(context.io);
    const proxy_client =
        \\import importlib.util, socket, time
        \\spec = importlib.util.spec_from_file_location("proxy", "infra/host/nrepl-proxy.py")
        \\proxy = importlib.util.module_from_spec(spec); spec.loader.exec_module(proxy)
        \\for _ in range(1200):
        \\    try:
        \\        s = socket.create_connection(("127.0.0.1", 7898), timeout=900); break
        \\    except OSError:
        \\        time.sleep(0.5)
        \\buf = b""
        \\def ask(message):
        \\    global buf
        \\    s.sendall(proxy.encode(message))
        \\    replies = []
        \\    while True:
        \\        end = proxy.bencode_end(buf, 0)
        \\        if end is None:
        \\            chunk = s.recv(65536)
        \\            if not chunk:
        \\                return replies
        \\            buf += chunk
        \\            continue
        \\        reply, _ = proxy.decode(buf[:end], 0)
        \\        buf = buf[end:]
        \\        replies.append(reply)
        \\        if b"done" in reply.get("status", []):
        \\            return replies
        \\def said(replies, key):
        \\    return next((r[key].decode() for r in replies if key in r), "")
        \\session = said(ask({"op": "clone", "id": "1"}), "new-session")
        \\def value(code, id):
        \\    return said(ask({"op": "eval", "code": code, "id": id, "session": session}), "value")
        \\print("defined", value("(def checkpointed-a 1)", "2"))
        \\print("checkpoint", said(ask({"op": "det-checkpoint", "name": "proxy", "id": "3"}), "value"))
        \\print("after", value("(def checkpointed-b 2)", "4"))
        \\print("resumed", said(ask({"op": "det-resume", "name": "proxy", "id": "5"}), "value"))
        \\print("back", value("[checkpointed-a (resolve 'checkpointed-b)]", "6"))
    ;
    const proxied = if (run_kept(context, &.{ "timeout", "1200", "python3", "-c", proxy_client })) |result| result.stdout else |_| "";
    const lost = !std.mem.eql(u8, values[1], "800") and values[1].len > 0;
    const futures_ran = std.mem.indexOf(u8, forks, "failing in    2  a future of the REPL ran") != null;
    expect_all(context, &.{
        .{ "a session opened at the scenario's start", session > 0 },
        .{ "the program's nREPL server is warm in its node: the relay connects at once", started },
        .{ "an nREPL session cloned through the relay", nrepl_session.len > 0 },
        .{ "(+ 1 2) is 3, evaluated in the guest", std.mem.eql(u8, values[0], "3") },
        .{ "the service written at the REPL ran its 64 threads: the race lost money", lost },
        .{ "the REPL runs a command in the peer through the runner", std.mem.indexOf(u8, values[2], "peer") != null },
        .{ "it kills the peer", std.mem.eql(u8, values[3], "0") },
        .{ "the peer is down then", values[4].len > 0 and !std.mem.eql(u8, values[4], "0") },
        .{ "it starts the peer again, which answers", std.mem.indexOf(u8, values[5], "peer") != null },
        .{ "the REPL reads serve's runs from inside the machine", std.mem.eql(u8, values[6], "\"200 1\"") },
        .{ "and a session's own routes are refused there", std.mem.eql(u8, values[7], "403") },
        .{ "the session is the run's next timeline: 1", first.timeline == 1 },
        .{ "the timeline's replay has serve's reply from its tape", replayed_serve },
        .{ "a fork from the REPL answers 0 where it was asked", std.mem.eql(u8, values[8], "0") },
        .{ "its two futures ran from the clone, a run of serve's, each knowing it is one", futures_ran and std.mem.indexOf(u8, forks, "\"run\":") != null },
        .{ "the REPL finds its fork's run from inside the machine", std.mem.eql(u8, values[9], "1") },
        // No value: what reached the client during that step is the exact timeline's (on srv4
        // after 43e4d4b9's guest image, an earlier request's late "state" status, id 11,
        // cider's changed-namespaces: no reply at all was asked, and it failed).
        .{ "its server dying in an evaluation answers at once (no value, under 60 s of virtual time)", nrepl_field(halted, "value") == null and uptime_before > 0 and halt_s < 60 },
        .{ "a checkpoint of the warm REPL, saved", std.mem.indexOf(u8, checkpointed, "\"saved\":true") != null },
        .{ "after the crash, a session at the checkpoint starts from it, not from boot", std.mem.indexOf(u8, resumed.output, "[determinismo] on from b") != null },
        .{ "and the REPL is back there, its bank with it", std.mem.eql(u8, resumed_total, values[1]) },
        .{ "through nrepl-proxy.py: det-checkpoint saved", std.mem.indexOf(u8, proxied, "checkpoint {\"name\":\"proxy\"") != null and std.mem.indexOf(u8, proxied, "\"saved\":true") != null },
        .{ "and det-resume back there: defined before it, not after", std.mem.indexOf(u8, proxied, "back [1 nil]") != null },
    }, "repl: a session {d}, (+ 1 2) = {s}, the bank's total {s}, the peer {s} {s} {s} {s}, serve {s} {s}, the fork {s}, its server's death answered in {d:.1} s, the total at the checkpoint {s}", .{
        session, values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8], halt_s, resumed_total,
    });
}

/// A jank REPL inside the guest, as the Clojure one: jank 0.1's own nREPL server (examples/nrepl's
/// jank profile, warm: its node's command), a session at its scenario's start, the relay to it,
/// and evaluations through the relay, state kept between them.
fn check_jank_repl(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7893";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-jank-repl" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "nrepl-test" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .program = program,
        .profile = "jank",
        .scenario = "jank",
        .seed = 1,
        .branches = 1,
    }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    // Its one timeline done (jank's image built the first time: minutes).
    for (0..3600) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const opened = try curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0,\"until\":\"event=composer_start\"}", url ++ "/runs/1/session" });
    const Opened = struct { session: u32 = 0, done: bool = true };
    const session = (try std.json.parseFromSliceLeaky(Opened, arena, opened, .{ .ignore_unknown_fields = true })).session;
    const step_url = try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/step", .{session});
    // jank's server is its node's command (Dockerfile.jank, port 7888 through socat): warm.
    _ = try repl_step(context, step_url, "det:background det-nodes exec nrepl /opt/determinismo/bin/det-nrepl-relay serve 7888 " ++ repl_fifo);
    const listening = try repl_step(context, step_url, "det:until 1500 event=nrepl_relay_ready");
    const started = std.mem.indexOf(u8, listening, "nrepl_relay_ready") != null;
    const clone = try nrepl_eval(context, step_url, &.{ .{ "id", "1" }, .{ "op", "clone" } });
    const nrepl_session = nrepl_field(clone, "new-session") orelse "";
    const forms = [_][]const u8{
        "(+ 1 2)",
        "(do (defn square [x] (* x x)) (def counter (atom 0)) (square 7))",
        "(do (swap! counter inc) (swap! counter inc) @counter)",
    };
    var values: [forms.len][]const u8 = undefined;
    for (forms, &values, 0..) |form, *value, index| {
        const id = try std.fmt.allocPrint(arena, "{d}", .{index + 2});
        const replies = try nrepl_eval(context, step_url, &.{
            .{ "code", form }, .{ "id", id }, .{ "ns", "user" }, .{ "op", "eval" }, .{ "session", nrepl_session },
        });
        value.* = nrepl_field(replies, "value") orelse replies[0..@min(replies.len, 200)];
    }
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{session}) }) catch "";
    expect_all(context, &.{
        .{ "a session opened at the scenario's start", session > 0 },
        .{ "jank's nREPL server is warm in its node: the relay connects at once", started },
        .{ "an nREPL session cloned through the relay", nrepl_session.len > 0 },
        .{ "(+ 1 2) is 3, evaluated by jank in the guest", std.mem.eql(u8, values[0], "3") },
        .{ "a function defined at the REPL runs", std.mem.eql(u8, values[1], "49") },
        .{ "its state stays between evaluations", std.mem.eql(u8, values[2], "2") },
    }, "jank repl: a session {d}, (+ 1 2) = {s}, (square 7) = {s}, the counter {s}", .{
        session, values[0], values[1], values[2],
    });
}

/// One step of a session: its output, the session's own lines (guest events among them).
fn repl_step(context: *Context, step_url: []const u8, command: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(.{ .exec = command }, .{})});
    const reply = try curl(context, &.{ "-X", "POST", "-d", body, step_url });
    const Reply = struct { output: []const u8 = "" };
    return (try std.json.parseFromSliceLeaky(Reply, context.arena, reply, .{ .ignore_unknown_fields = true })).output;
}

/// The guest's uptime in seconds from a `cat /proc/uptime` step's output (its exec_output text):
/// its virtual time; 0 when not found.
fn guest_uptime_s(output: []const u8) f64 {
    const at = std.mem.indexOf(u8, output, "\"text\":\"") orelse return 0;
    const text = output[at + "\"text\":\"".len ..];
    const end = std.mem.indexOfAny(u8, text, " \\\"") orelse return 0;
    return std.fmt.parseFloat(f64, text[0..end]) catch 0;
}

/// Whether a replay's nREPL replies (the relay's nrepl_reply events, each decoded) hold `text`.
fn nrepl_replies_have(arena: std.mem.Allocator, output: []const u8, text: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const decoder = std.base64.standard.Decoder;
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "{\"event\":\"nrepl_reply\"") orelse continue;
        const end = std.mem.lastIndexOfScalar(u8, line, '}') orelse continue;
        const Event = struct { details: struct { data: []const u8 = "" } = .{} };
        const event = std.json.parseFromSliceLeaky(Event, arena, line[at .. end + 1], .{ .ignore_unknown_fields = true }) catch continue;
        const size = decoder.calcSizeForSlice(event.details.data) catch continue;
        const bytes = arena.alloc(u8, size) catch return false;
        decoder.decode(bytes, event.details.data) catch continue;
        if (std.mem.indexOf(u8, bytes, text) != null) return true;
    }
    return false;
}

/// The session relay's FIFO (det-nrepl-relay serve), in the tmpfs every node shares.
const repl_fifo = "/opt/determinismo/records/.nrepl-7888";

/// An nREPL message through the session's relay, as nrepl-proxy.py sends it: one det:ask step
/// (its fields bencoded in the order given: sorted keys; its id the second field's value), its
/// replies (each bencoded, one after the other) put together from the relay's nrepl_reply events.
fn nrepl_eval(context: *Context, step_url: []const u8, fields: []const [2][]const u8) ![]const u8 {
    const arena = context.arena;
    var message: std.ArrayList(u8) = .empty;
    try message.append(arena, 'd');
    for (fields) |pair| for (pair) |text| try message.print(arena, "{d}:{s}", .{ text.len, text });
    try message.append(arena, 'e');
    const id = for (fields) |pair| {
        if (std.mem.eql(u8, pair[0], "id")) break pair[1];
    } else unreachable;
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(message.items.len));
    _ = encoder.encode(encoded, message.items);
    const command = try std.fmt.allocPrint(arena, "det:ask " ++ repl_fifo ++ " {s} {s}", .{ id, encoded });
    const output = try repl_step(context, step_url, command);
    var replies: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const decoder = std.base64.standard.Decoder;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[guest @")) continue;
        const json = line[(std.mem.indexOf(u8, line, "] ") orelse continue) + 2 ..];
        const Event = struct { event: []const u8 = "", details: struct { data: []const u8 = "" } = .{} };
        const event = std.json.parseFromSliceLeaky(Event, arena, json, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, event.event, "nrepl_reply")) continue;
        const size = decoder.calcSizeForSlice(event.details.data) catch continue;
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, event.details.data) catch continue;
        try replies.appendSlice(arena, bytes);
    }
    return replies.items;
}

/// A string field's value in bencoded nREPL replies (the first reply that has it).
fn nrepl_field(replies: []const u8, key: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, replies, at, key)) |found| {
        at = found + key.len;
        // The key as a bencoded string: "<len>:<key>".
        const prefix_digits = std.fmt.count("{d}", .{key.len});
        if (found < prefix_digits + 1 or replies[found - 1] != ':') continue;
        const value_start = found + key.len;
        const colon = std.mem.indexOfScalarPos(u8, replies, value_start, ':') orelse return null;
        const size = std.fmt.parseInt(usize, replies[value_start..colon], 10) catch continue;
        if (colon + 1 + size > replies.len) return null;
        return replies[colon + 1 .. colon + 1 + size];
    }
    return null;
}

fn texts_equal(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// An exploration with standard input from `input` (an interactive session's steps).
fn explore_stdin(context: *Context, extra: []const []const u8, input: []const u8) ![]const u8 {
    var command: std.ArrayList(u8) = .empty;
    try command.appendSlice(context.arena, "exec");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "explore" });
    try argv.appendSlice(context.arena, context.machine);
    try argv.appendSlice(context.arena, extra);
    for (argv.items) |argument| {
        assert(std.mem.indexOfScalar(u8, argument, '\'') == null);
        try command.print(context.arena, " '{s}'", .{argument});
    }
    try command.print(context.arena, " < '{s}'", .{input});
    const result = try run_kept(context, &.{ "/bin/sh", "-c", command.items });
    return std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
}

/// The texts of a report's exec_output events, in order.
fn exec_texts(arena: std.mem.Allocator, report: []const u8) ![]const []const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[guest @")) continue;
        const json = line[(std.mem.indexOf(u8, line, "] ") orelse continue) + 2 ..];
        const Event = struct { event: []const u8 = "", details: struct { text: []const u8 = "" } = .{} };
        const event = std.json.parseFromSliceLeaky(Event, arena, json, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, event.event, "exec_output")) try texts.append(arena, event.details.text);
    }
    return texts.items;
}

/// A branch's own future (--fresh-seed, Antithesis's branches): the guest kernel's randomness
/// a second after the moment differs from the timeline's and between seeds, and is the same for
/// the same seed.
fn check_steps_fresh(context: *Context, program: []const u8, violation: []const u8) !void {
    const arena = context.arena;
    const script = try std.fs.path.join(arena, &.{ context.scratch, "fresh.txt" });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = script,
        .data = "det:wait 1000\nhead -c 8 /dev/urandom | od -An -tx1\n",
    });
    const branch = try bank_violating_branch(context);
    var drawn: [4][]const u8 = undefined;
    const seeds = [_]?[]const u8{ null, "1", "1", "2" };
    for (seeds, &drawn) |seed, *bytes| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "--program", program,   "--scenario",    "bank", "--seed", "3", "--branch", branch,
            "--until",   violation, "--exec-script", script,
        });
        if (seed) |value| try argv.appendSlice(arena, &.{ "--fresh-seed", value });
        bytes.* = exec_output_last(try explore(context, argv.items));
    }
    expect_all(context, &.{
        .{ "each branch printed its bytes", drawn[0].len > 0 and drawn[1].len > 0 and drawn[3].len > 0 },
        .{ "a fresh future is not the timeline's", !std.mem.eql(u8, drawn[0], drawn[1]) },
        .{ "the same seed, the same future", std.mem.eql(u8, drawn[1], drawn[2]) },
        .{ "another seed, another future", !std.mem.eql(u8, drawn[1], drawn[3]) },
    }, "steps: a branch's own future (--fresh-seed): {s} | {s} | {s} | {s}", .{ drawn[0], drawn[1], drawn[2], drawn[3] });
}

/// The text of a report's last exec_output event (a command's output at a moment).
fn exec_output_last(report: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, report, "\"event\":\"exec_output\"") orelse return "";
    const text = std.mem.indexOfPos(u8, report, at, "\"text\":\"") orelse return "";
    const start = text + "\"text\":\"".len;
    const end = std.mem.indexOfScalarPos(u8, report, start, '"') orelse return "";
    return std.mem.trim(u8, report[start..end], " \\n");
}

/// Kubernetes manifests imported (kubernetes.zig), as Antithesis runs them: a single-node K3s
/// cluster with the manifests' images (one built here), deployed and ready before branching,
/// the client image's test templates run in its pod; one timeline replays exactly.
fn check_kubernetes(context: *Context) !void {
    const arena = context.arena;
    const build = try run_kept(context, &.{
        "podman", "build",                                 "--quiet", "--tag", "localhost/determinismo-kubernetes-client:1",
        "--file", "examples/kubernetes/Dockerfile.client", ".",
    });
    // The probe spared (fault_exclusions, by its pod's name): its output stays whole, and pod
    // faults show they pass it over.
    const common = [_][]const u8{
        "--kubernetes", "examples/kubernetes/manifests", "--scenario",         "counter", "--seed", "1",
        "--memory-mib", "4096",                          "--fault-exclusions", "^probe$",
    };
    const explored = try std.fmt.allocPrint(arena, "{s}/kubernetes", .{context.scratch});
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "4", "--events-dir", explored }));
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    const deployed = std.mem.indexOf(u8, report, "test command completed: setup_kubernetes") != null;
    const driven = std.mem.indexOf(u8, report, "test command completed: parallel_driver_increment") != null;
    const read = std.mem.indexOf(u8, report, "test command completed: eventually_counter_readable") != null;
    const passing = std.mem.indexOf(u8, report, "4 branches, 0 with failing properties") != null;
    // The greps below read the timelines' own files plain (an ended timeline's are compressed:
    // they found no pod fault, and no pod's output, in any).
    try events_plain(context, explored);
    // Faults on single pods (Faults.pods), each naming its pod.
    const pod_faults = try run_kept(context, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "grep -rhoE '\"kind\":\"pod_[a-z]+\"' {s} | sort | uniq -c | tr -s ' \\n' ' '", .{explored}) });
    // The pods' own output, named after them (det-podlogs): Redis says it is ready.
    const pod_output = try run_kept(context, &.{ "grep", "-rl", "\"source\":\"redis-0\"", explored });
    // A pod fault that could not be applied or undone (the pod picked, its address, its
    // namespace): none.
    const pod_failures = try run_kept(context, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "grep -rh 'fault_failed\\|fault_heal_failed' {s} | grep -c kubernetes || true", .{explored}) });
    const named = try run_kept(context, &.{ "grep", "-rhoE", "\"pod\":\"[a-z0-9-]+\"", explored });
    // Pods' containers' exits judged as Antithesis judges a container's (a pod kill's 137).
    const exits = try run_kept(context, &.{ "grep", "-rlF", "\"no unexpected container exits\",\"condition\":true,\"details\":{\"pod\"", explored });
    // A bare Pod given what Antithesis gives every container (det-kubespec's base spec): its
    // library, its device, the coverage bitmaps, the SDK's output; nothing missing.
    const given = try run_kept(context, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "grep -rhoE 'probe given [a-z/.]+' {s} | sort -u | wc -l", .{explored}) });
    const missing = try run_kept(context, &.{ "grep", "-rlF", "probe missing", explored });
    const sdk_env = try run_kept(context, &.{ "grep", "-rlF", "probe sdk output /opt/determinismo/sdk/output", explored });
    const probe_faulted = try run_kept(context, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "grep -rhF '\"pod\":\"probe\"' {s} | grep -cF '\"event\":\"fault\"' || true", .{explored}) });
    var same = false;
    if (count > 0) {
        const index = try std.fmt.allocPrint(arena, "{d}", .{branches[0].index});
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    }
    expect_all(context, &.{
        .{ "the client image builds", build.term.success() },
        .{ "4 timelines", count == 4 },
        .{ "the manifests deployed and became ready (setup_kubernetes)", deployed },
        .{ "a driver ran in the client's pod", driven },
        .{ "the counter read back once faults stopped", read },
        .{ "no property failed", passing },
        .{ "a timeline replays exactly", same },
        .{ "faults on single pods, each naming its pod", pod_faults.stdout.len > 0 and named.stdout.len > 0 },
        .{ "the pods' output as events named after them (redis-0)", pod_output.stdout.len > 0 },
        .{ "pods' container exits judged (no unexpected container exits)", exits.stdout.len > 0 },
        .{ "a bare Pod given libvoidstar, its device, the coverage and the SDK's output", std.mem.eql(u8, std.mem.trim(u8, given.stdout, " \n"), "4") and missing.stdout.len == 0 },
        .{ "a bare Pod's environment names the SDK's output", sdk_env.stdout.len > 0 },
        .{ "no fault of the excluded probe pod (fault_exclusions ^probe$)", std.mem.eql(u8, std.mem.trim(u8, probe_faulted.stdout, " \n"), "0") },
        .{ "no fault of the K3s node or its pods failed to apply or heal", std.mem.eql(u8, std.mem.trim(u8, pod_failures.stdout, " \n"), "0") },
    }, "kubernetes: manifests in K3s, deployed before branching, templates run in their pod; " ++
        "pod faults: {s}", .{std.mem.trim(u8, pod_faults.stdout[0..@min(pod_faults.stdout.len, 120)], "\n")});
}

fn check_k3s(context: *Context) !void {
    try check_k3s_profile(context, "single", "4096", "one node");
    try check_k3s_profile(context, "cluster", "8192", "three nodes");
}

fn check_k3s_profile(
    context: *Context,
    profile: []const u8,
    memory_mib: []const u8,
    label: []const u8,
) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "k3s-test" });
    const common = [_][]const u8{
        "--program",    program,    "--profile", profile, "--scenario", "cluster", "--seed", "1",
        "--memory-mib", memory_mib,
    };
    const arena = context.arena;
    const explored = try std.fmt.allocPrint(arena, "{s}/k3s-{s}", .{ context.scratch, profile });
    const report = try explore(context, &(common ++ [_][]const u8{
        "--branches", "4", "--events-dir", explored,
    }));
    const passes = std.mem.indexOf(u8, report, "4 branches, 0 with failing properties") != null;
    expect(context, passes, "k3s ({s}): the workload survives faults in 4 branches", .{label});
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    if (count == 0) return;
    const index = try std.fmt.allocPrint(arena, "{d}", .{branches[0].index});
    const replayed_events = try std.fmt.allocPrint(arena, "{s}-replay.jsonl", .{explored});
    const replay = try explore(context, &(common ++ [_][]const u8{
        "--branch", index, "--events", replayed_events,
    }));
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    const same = ran_one and std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "its events hash is the original's", same },
    }, "k3s ({s}): branch {d} replays exactly", .{ label, branches[0].index });
    if (!same) {
        try events_plain(context, explored);
        const original = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{
            explored, branches[0].index,
        });
        first_difference(context, original, replayed_events);
    }
}

/// In each timeline's events (`--events-dir`), the first branch point naming a node
/// (`faults_branch`) and whether the fault after it involves that node.
fn branches_aimed(context: *Context, dir: []const u8, branches: []const Branch) !struct { named: u32, aimed: u32 } {
    var named: u32 = 0;
    var aimed: u32 = 0;
    try events_plain(context, dir);
    for (branches) |branch| {
        const path = try std.fmt.allocPrint(context.arena, "{s}/branch-{d}.jsonl", .{ dir, branch.index });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(1 << 28)) catch continue;
        var node: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, context.arena, line, .{}) catch continue;
            if (parsed != .object) continue;
            const data = parsed.object.get("event") orelse continue;
            if (data != .object) continue;
            const name = data.object.get("event") orelse continue;
            const details = data.object.get("details") orelse continue;
            if (name != .string or details != .object) continue;
            if (node == null and std.mem.eql(u8, name.string, "faults_branch")) {
                const at = json_string(details.object, "node");
                if (at.len > 0) {
                    node = at;
                    named += 1;
                }
            } else if (node != null and std.mem.eql(u8, name.string, "fault")) {
                const involved = std.mem.eql(u8, json_string(details.object, "node"), node.?) or
                    std.mem.eql(u8, json_string(details.object, "peer"), node.?);
                aimed += @intFromBool(involved);
                break;
            }
        }
    }
    return .{ .named = named, .aimed = aimed };
}

fn json_string(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

/// Prints where two event logs part: what a replay did differently.
fn first_difference(context: *Context, a_path: []const u8, b_path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(1 << 28);
    const a = cwd.readFileAlloc(context.io, a_path, context.arena, limit) catch return;
    const b = cwd.readFileAlloc(context.io, b_path, context.arena, limit) catch return;
    var a_lines = std.mem.splitScalar(u8, a, '\n');
    var b_lines = std.mem.splitScalar(u8, b, '\n');
    var line: u32 = 1;
    while (true) : (line += 1) {
        const left = a_lines.next() orelse "<end>";
        const right = b_lines.next() orelse "<end>";
        if (std.mem.eql(u8, left, "<end>") and std.mem.eql(u8, right, "<end>")) return;
        if (std.mem.eql(u8, left, right)) continue;
        std.debug.print("  first difference, line {d}:\n    explored: {s}\n    replayed: {s}\n", .{
            line, left[0..@min(left.len, 400)], right[0..@min(right.len, 400)],
        });
        return;
    }
}

/// Every branch's events, queried as Antithesis's Logs Explorer does: the failing timelines are
/// found, node output is searchable, and a temporal condition splits the violations exactly
/// (those preceded by a fault and those not add up to all).
fn check_query(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "query-events" });
    const report = try explore(context, &.{
        "--program",    program, "--scenario", "bank", "--seed", "3", "--branches", "16",
        "--events-dir", events,
    });
    const failing_report = std.mem.indexOf(u8, report, "with failing properties") != null;
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    const all = try query_count(context, &.{ events, violation });
    const fault = "event=fault";
    const after_fault = try query_count(context, &.{ events, violation, "--preceded-by", fault });
    const no_fault = try query_count(context, &.{ events, violation, "--not-preceded-by", fault });
    const output = try query_count(context, &.{ events, "output.source=redis" });
    // A regular expression finds the same lines.
    const matched = try query_count(context, &.{ events, "output.source=~^re(d|x)i[s]$" });
    expect_all(context, &.{
        .{ "the run reports failing properties", failing_report },
        .{ "violations found", all > 0 },
        .{ "redis output found", output > 0 },
        .{ "after a fault + without one = all violations", after_fault + no_fault == all },
        .{ "the regex finds the same output lines", matched == output },
    }, "query: {d} violations ({d} after a fault, {d} without), {d} redis output lines ({d} " ++
        "by a regex)", .{ all, after_fault, no_fault, output, matched });
    // Event sets: the same answers through a pipeline (with_last), and through a program.
    const arena = context.arena;
    const annotated = try std.fmt.allocPrint(arena, "[{{\"filter\": {f}}}, " ++
        "{{\"with_last\": {{\"fault\": \"event=fault\"}}}}, {{\"filter\": \"last_fault?\"}}]", .{
        std.json.fmt(violation, .{}),
    });
    const with_last = try events_count(context, &.{ events, annotated });
    const piped = try std.fmt.allocPrint(arena, "[{{\"filter\": {f}}}, " ++
        "{{\"through\": \"cat\"}}]", .{std.json.fmt(violation, .{})});
    const through = try events_count(context, &.{ events, piped });
    expect_all(context, &.{
        .{ "with_last finds the violations after a fault", with_last == after_fault },
        .{ "a program passes every violation through", through == all },
    }, "event sets: with_last finds {d} violations after a fault, a program passes {d} through", .{
        with_last, through,
    });
}

/// How many events `determinismo events` gives (its --count line).
fn events_count(context: *Context, arguments: []const []const u8) !u64 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "events" });
    try argv.appendSlice(context.arena, arguments);
    try argv.append(context.arena, "--count");
    const result = try run_kept(context, argv.items);
    const end = std.mem.indexOfScalar(u8, result.stdout, ' ') orelse return 0;
    return std.fmt.parseInt(u64, result.stdout[0..end], 10) catch 0;
}

/// Coverage always (serve's coverage_gate): a run of a program with no coverage at all (the
/// self-test bank, its nodes uninstrumented) is stopped once 4 of its timelines ended, its
/// `stopped` file saying why, and its JSON too (what its page and determinismo-ci show: the
/// reason was in serve's log alone); the same run asked with `"coverage": "off"` goes on; and
/// one of two timelines, ended by itself before the gate's four, keeps its verdict and says it
/// ran uncovered (it ended unjudged).
fn check_coverage_gate(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7931";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-coverage-gate" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const blind = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\"," ++
        "\"seed\":5,\"branches\":100000,\"jobs\":1,\"time_budget\":\"10m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", blind, url ++ "/runs" });
    var run: []const u8 = "";
    for (0..1200) |_| {
        run = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const stopped_path = try std.fs.path.join(arena, &.{ data, "runs", "1", "stopped" });
    const why = std.Io.Dir.cwd().readFileAlloc(context.io, stopped_path, arena, .limited(4096)) catch "";
    // The same, asked without coverage: it goes on past 4 timelines.
    const asked_off = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",\"coverage\":\"off\"," ++
        "\"seed\":5,\"branches\":100000,\"jobs\":1,\"time_budget\":\"10m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked_off, url ++ "/runs" });
    defer _ = curl(context, &.{ "-X", "POST", url ++ "/runs/2/stop" }) catch "";
    var going: []const u8 = "";
    var ended: u64 = 0;
    for (0..1200) |_| {
        going = curl(context, &.{url ++ "/runs/2"}) catch "";
        const Stats = struct { stats: struct { timelines: u64 = 0 } = .{} };
        const stats = std.json.parseFromSliceLeaky(Stats, arena, going, .{ .ignore_unknown_fields = true }) catch Stats{};
        ended = stats.stats.timelines;
        if (ended >= 8 or std.mem.indexOf(u8, going, "\"state\":\"running\"") == null) break;
        sleep_ms(500);
    }
    // Two timelines, fewer than the gate waits for: the run ends by itself.
    const short = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\"," ++
        "\"seed\":5,\"branches\":2,\"jobs\":1,\"time_budget\":\"10m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", short, url ++ "/runs" });
    var ended_run: []const u8 = "";
    for (0..1200) |_| {
        ended_run = curl(context, &.{url ++ "/runs/3"}) catch "";
        if (ended_run.len > 0 and std.mem.indexOf(u8, ended_run, "\"state\":\"running\"") == null) break;
        sleep_ms(500);
    }
    // Its verdict, then serve's look at what it left (the watcher's next passes).
    for (0..60) |_| {
        if (std.mem.indexOf(u8, ended_run, "\"uncovered\"") != null) break;
        sleep_ms(500);
        ended_run = curl(context, &.{url ++ "/runs/3"}) catch "";
    }
    expect_all(context, &.{
        .{ "the uncovered run is stopped", std.mem.indexOf(u8, run, "\"state\":\"stopped\"") != null },
        .{ "its stopped file says why", std.mem.indexOf(u8, why, "no coverage in its first") != null },
        .{ "and its JSON, for its page and its client", std.mem.indexOf(u8, run, "\"stopped_why\":\"no coverage in its first") != null },
        .{ "a run that ended by itself before the gate keeps its verdict", std.mem.indexOf(u8, ended_run, "\"state\":\"stopped\"") == null and
            std.mem.indexOf(u8, ended_run, "\"state\":\"running\"") == null and ended_run.len > 0 },
        .{ "and says it ran uncovered", std.mem.indexOf(u8, ended_run, "\"uncovered\":\"no coverage in its 2 timelines") != null },
        .{ "asked without coverage, it goes on past 4 timelines", ended >= 8 and std.mem.indexOf(u8, going, "\"state\":\"running\"") != null },
    }, "coverage gate: run 1 {s}, why \"{s}\"; run 2 at {d} timelines; run 3 {s}", .{
        run[0..@min(run.len, 160)], why, ended, ended_run[0..@min(ended_run.len, 260)],
    });
}

/// The HTTP API and its web UI: `serve` answers with the page, starts a run, records every
/// branch's events, and answers queries about them.
fn check_serve(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7891";
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address });
    try argv.appendSlice(arena, &.{ "--data", data });
    if (context.bb) |bb| try argv.appendSlice(arena, &.{ "--bb", bb });
    // Its own initramfs: replaced below, as a deploy replaces the host's.
    const initrd = try std.fs.path.join(arena, &.{ context.scratch, "serve-initrd.cpio" });
    const machine = try arena.dupe([]const u8, context.machine);
    for (machine[0 .. machine.len - 1], 0..) |flag, index| {
        if (!std.mem.eql(u8, flag, "--initrd")) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, machine[index + 1], arena, .unlimited);
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = initrd, .data = bytes });
        machine[index + 1] = initrd;
    }
    try argv.appendSlice(arena, machine);
    var server = try std.process.spawn(context.io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer server.kill(context.io);
    const url = "http://" ++ address;
    var page: []const u8 = "";
    for (0..50) |_| {
        page = curl(context, &.{url ++ "/"}) catch "";
        if (page.len > 0) break;
        sleep_ms(100);
    }
    // GET /build: serve's commit and the guest it boots, its kernel and initramfs named by
    // content (a product's cache keys on it: determinismo-ci's setup).
    const build = curl(context, &.{url ++ "/build"}) catch "";
    expect_all(context, &.{
        .{ "serve says its build and guest (GET /build)", std.mem.indexOf(u8, build, "\"commit\":") != null and std.mem.indexOf(u8, build, "\"explorer\":\"") != null and
            std.mem.indexOf(u8, build, "\"kernel\":\"") != null and std.mem.indexOf(u8, build, "-vmlinuz\"") != null and
            std.mem.indexOf(u8, build, "\"initrd\":\"") != null },
    }, "serve /build: {s}", .{build});
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    // With an automation: a command run at each failing property's first counterexample once
    // the run ends (schema.Automation).
    const body = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",\"coverage\":\"off\"," ++
        "\"seed\":3,\"branches\":8,\"automations\":[{{\"property\":\"total balance is conserved\"," ++
        "\"exec\":\"echo automation at the failure\"}}]}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", body, url ++ "/runs" });
    var run: []const u8 = "";
    for (0..600) |_| {
        run = try curl(context, &.{url ++ "/runs/1"});
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null) break;
        sleep_ms(200);
    }
    const asked = "{\"condition\":\"output.source=redis\",\"output\":\"count\"}";
    const answer = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs/1/query" });
    const discovery = try curl(context, &.{url ++ "/runs/1/discovery"});
    const curve = std.mem.indexOf(u8, discovery, "[8,") != null; // A point after 8 branches.
    // Where its workers' time went, by minute (activity.zig): its 8 timelines, the setup.
    const activity_text = try curl(context, &.{url ++ "/runs/1/activity"});
    const Activity = struct {
        workers: u32 = 0,
        minutes: []const struct { timelines: u32, busy_s: struct { setup: f64, timeline: f64 } } = &.{},
    };
    const activity = std.json.parseFromSliceLeaky(Activity, arena, activity_text, .{ .ignore_unknown_fields = true }) catch Activity{};
    var activity_timelines: u32 = 0;
    var activity_busy: f64 = 0;
    var activity_setup: f64 = 0;
    for (activity.minutes) |minute| {
        activity_timelines += minute.timelines;
        activity_busy += minute.busy_s.timeline;
        activity_setup += minute.busy_s.setup;
    }
    // How its explorer ended, for a server started later (bank fails: explore exits 3).
    const exit_path = try std.fs.path.join(arena, &.{ data, "runs", "1", "exit" });
    const exit = std.Io.Dir.cwd().readFileAlloc(context.io, exit_path, arena, .limited(256)) catch "";
    // The explorer that ran it, kept by content in the data directory (its replays run on it).
    const request_text = std.Io.Dir.cwd().readFileAlloc(context.io, try std.fs.path.join(arena, &.{ data, "runs", "1", "request.json" }), arena, .limited(1 << 20)) catch "";
    const Kept = struct { explorer: ?[]const u8 = null };
    const kept_explorer: Kept = std.json.parseFromSliceLeaky(Kept, arena, request_text, .{ .ignore_unknown_fields = true }) catch .{};
    const explorer_kept = if (kept_explorer.explorer) |path| kept: {
        std.Io.Dir.cwd().access(context.io, path, .{}) catch break :kept false;
        break :kept std.mem.startsWith(u8, path, data) and std.mem.indexOf(u8, path, "/artifacts/") != null;
    } else false;
    expect_all(context, &.{
        .{ "the UI page loads", std.mem.indexOf(u8, page, "<title>determinismo</title>") != null },
        .{ "the discovery curve has a point after 8 branches", curve },
        .{ "its activity by minute has its 8 timelines, their time and the setup's", activity.workers > 0 and
            activity_timelines == 8 and activity_busy > 0 and activity_setup > 0 },
        .{ "the run finished (its summary)", std.mem.indexOf(u8, run, "\"summary\"") != null },
        .{ "serve kept how its explorer ended", std.mem.startsWith(u8, exit, "3 exited with status 3") },
        .{ "serve kept the explorer that ran it, for its replays", explorer_kept },
        .{ "the query answers", std.mem.indexOf(u8, answer, "\"events\":") != null },
        .{ "the query finds events", std.mem.indexOf(u8, answer, "\"events\":0,") == null },
    }, "serve: the UI, a run over HTTP, its activity ({d} timelines over {d} minutes), and a query of its events ({s})", .{
        activity_timelines, activity.minutes.len, std.mem.trim(u8, answer, "\n"),
    });
    // Its automation, at the property's first counterexample: a replay to it, the output kept.
    var automations: []const u8 = "";
    for (0..1500) |_| {
        automations = try curl(context, &.{url ++ "/runs/1/automations"});
        if (automations.len > 0) break;
        sleep_ms(200);
    }
    expect_all(context, &.{
        .{ "for the failing property", std.mem.indexOf(u8, automations, "\"property\":\"total balance is conserved\"") != null },
        // Its output event's text (`...\n` in it) inside the kept output, a JSON string: `\\n`.
        .{ "its command's output", std.mem.indexOf(u8, automations, "automation at the failure\\\\n") != null },
    }, "serve: an automation runs at a failing property's first counterexample once the run ends ({s})", .{
        automations[0..@min(automations.len, 300)],
    });
    // A shrink from the run's page: serve's child, in serve's environment (no HOME: its
    // explorations found no store, and every shrink from a page failed at once, srv4 2026-11-01).
    // Of a timeline that lost money in this run (which do depends on the guest's build).
    const output = try curl(context, &.{url ++ "/runs/1/output?lines=200&explorer=1"});
    const failing = failing_branch(output, "total balance is conserved") orelse "0";
    const shrink_asked = try std.fmt.allocPrint(arena, "{{\"branch\":{s},\"property\":\"total balance is conserved\",\"timelines\":2}}", .{failing});
    _ = try curl(context, &.{ "-X", "POST", "-d", shrink_asked, url ++ "/runs/1/shrink" });
    var shrinks: []const u8 = "";
    for (0..1800) |_| {
        shrinks = try curl(context, &.{url ++ "/runs/1/shrink"});
        if (std.mem.indexOf(u8, shrinks, "\"done\":true") != null) break;
        sleep_ms(200);
    }
    expect_all(context, &.{
        .{ "the shrink ended", std.mem.indexOf(u8, shrinks, "\"done\":true") != null },
        .{ "with a result", std.mem.indexOf(u8, shrinks, "\"result\":{\"shrink\":") != null },
    }, "serve: a shrink started over HTTP ends with a result ({s})", .{
        shrinks[0..@min(shrinks.len, 400)],
    });
    // A deploy replaces the initramfs: the run's replays still boot what it booted (kept by
    // content), to the same events.
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = initrd, .data = "not the run's" });
    const replayed = try curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0}", url ++ "/runs/1/replay" });
    const hash_at = std.mem.indexOf(u8, replayed, "events_hash=");
    const hash = if (hash_at) |at| replayed[at + "events_hash=".len ..][0..16] else "";
    const record_path = try std.fs.path.join(arena, &.{ data, "runs", "1", "record.jsonl" });
    const record = try std.Io.Dir.cwd().readFileAlloc(context.io, record_path, arena, .limited(1 << 24));
    expect_all(context, &.{
        .{ "the replay printed an events hash", hash.len == 16 },
        .{ "the record has that hash", hash.len == 16 and std.mem.indexOf(u8, record, hash) != null },
    }, "serve: a run replays after a deploy replaced its initramfs (events hash {s})", .{hash});
    // A file put into a node at a moment of a replay (its `inject`), then a command there sees
    // it byte for byte: what a person or an agent tries a change with (a patched binary).
    var patch: [3000]u8 = undefined;
    for (&patch, 0..) |*byte, index| byte.* = @truncate(index *% 2654435761 >> 9);
    const encoder = std.base64.standard.Encoder;
    const content = try arena.alloc(u8, encoder.calcSize(patch.len));
    _ = encoder.encode(content, &patch);
    var patch_digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(&patch, &patch_digest, .{});
    // Between the setup's snapshot (a moment before it is refused) and the timeline's end.
    // The timeline's own line ("[branch    0] seed=... <outcome> vtime=<s>s ..."), not the
    // snapshot's.
    const branch_line = replayed[std.mem.indexOf(u8, replayed, "[branch") orelse 0 ..];
    const ended_ms: u64 = @intFromFloat((number_after(branch_line, " vtime=") orelse 2.0) * 1000.0);
    const snapshot_ms = snapshot_vtime_ms(replayed) orelse 0;
    const middle_ms = snapshot_ms + (ended_ms -| snapshot_ms) / 2;
    const inject_body = try std.fmt.allocPrint(arena, "{{\"branch\":0,\"at_vtime_ms\":{d},\"inject\":{{\"node\":\"redis\"," ++
        "\"path\":\"/tmp/patch.bin\",\"content\":\"{s}\",\"mode\":\"755\"}},\"exec\":\"md5sum " ++
        "/proc/$(cat /run/det/nodes/redis/pid)/root/tmp/patch.bin; stat -c %a /proc/$(cat /run/det/nodes/redis/pid)/root/tmp/patch.bin\"}}", .{ middle_ms, content });
    const injected = try curl(context, &.{ "-X", "POST", "-d", inject_body, url ++ "/runs/1/replay" });
    const patch_hex = std.fmt.bytesToHex(patch_digest, .lower);
    expect_all(context, &.{
        .{ "the file went in", std.mem.indexOf(u8, injected, "[injected]") != null },
        .{ "a command there sees its bytes", std.mem.indexOf(u8, injected, &patch_hex) != null },
        .{ "with its mode", std.mem.indexOf(u8, injected, "755\\n") != null },
    }, "serve: a replay puts a file into a node at a moment ({d} bytes at {d} ms), the same there", .{ patch.len, middle_ms });
    if (std.mem.indexOf(u8, injected, &patch_hex) == null) std.debug.print("{s}\n", .{lines_with(arena, injected, &.{
        "exec_", "injected", "error", "refused", "snapshot", "[branch",
    }) catch ""});
    // Its timeline in a bundle (bundle.zig), for another host: the bundle names nothing of the
    // store's or the cache's, and it replays inside it, the store's artifacts away, to the
    // record's events.
    const bundle_directory = try std.fs.path.join(arena, &.{ context.scratch, "bundle" });
    const bundled = try run_kept(context, &.{ context.determinismo, "bundle", try std.fs.path.join(arena, &.{ data, "runs", "1" }), "0", bundle_directory });
    const cache = for (context.machine, 0..) |flag, at| {
        if (std.mem.eql(u8, flag, "--cache")) break context.machine[at + 1];
    } else unreachable;
    var named_outside = false;
    for ([_][]const u8{ "machine.json", "request.json", "events/system.pin.json" }) |name| {
        const path = try std.fs.path.join(arena, &.{ bundle_directory, name });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 24)) catch "";
        named_outside = named_outside or text.len == 0 or std.mem.indexOf(u8, text, data) != null or
            std.mem.indexOf(u8, text, cache) != null;
    }
    const artifacts = try std.fs.path.join(arena, &.{ data, "artifacts" });
    const artifacts_away = try std.fs.path.join(arena, &.{ data, "artifacts.away" });
    try std.Io.Dir.cwd().rename(artifacts, std.Io.Dir.cwd(), artifacts_away, context.io);
    const determinismo = try std.Io.Dir.cwd().realPathFileAlloc(context.io, context.determinismo, arena);
    const from_bundle = std.process.run(arena, context.io, .{
        .argv = &.{ determinismo, "explore", "--run", ".", "--branch", "0" },
        .cwd = .{ .path = bundle_directory },
    });
    try std.Io.Dir.cwd().rename(artifacts_away, std.Io.Dir.cwd(), artifacts, context.io);
    const bundle_output = if (from_bundle) |result| try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr }) else |_| "";
    const bundle_hash = if (hash.len == 16) std.mem.indexOf(u8, bundle_output, hash) != null else false;
    expect_all(context, &.{
        .{ "it was made", bundled.term == .exited and bundled.term.exited == 0 },
        .{ "it names nothing of the store's or the cache's", !named_outside },
        .{ "it replays inside it to the record's events hash", bundle_hash },
    }, "serve: a timeline's bundle replays on its own (events hash {s})", .{hash});
    if (!bundle_hash) std.debug.print("{s}\n", .{bundle_output[bundle_output.len -| 3000..]});
    // The run's notebook: none at first, then what was saved.
    const empty = try curl(context, &.{url ++ "/runs/1/notebook"});
    const cells = "{\"source\":\"print(1)\\n// %%\\nprint(2)\"}";
    _ = try curl(context, &.{ "-X", "PUT", "-d", cells, url ++ "/runs/1/notebook" });
    const saved = try curl(context, &.{url ++ "/runs/1/notebook"});
    expect_all(context, &.{
        .{ "no notebook at first", std.mem.indexOf(u8, empty, "\"source\":null") != null },
        .{ "the saved notebook comes back", std.mem.indexOf(u8, saved, "print(1)\\n// %%\\nprint(2)") != null },
        .{ "the page evaluates notebooks", std.mem.indexOf(u8, page, "notebookEvaluate") != null },
    }, "serve: the notebook is kept with the run", .{});
    // Clojure cells, evaluated with babashka: a query of the run's events, and a value.
    if (context.bb == null) {
        std.debug.print("SKIP serve: notebook evaluation (no babashka: -Dbb or $DETERMINISMO_BB)\n", .{});
        return;
    }
    const evaluate = "{\"cells\":[\"(def failing (query \\\"assert.condition=false\\\"))\"," ++
        "\"(pos? (count failing))\"],\"results\":{}}";
    const evaluated = try curl(context, &.{
        "-X", "POST", "-d", evaluate, url ++ "/runs/1/notebook/evaluate",
    });
    const found = std.mem.indexOf(u8, evaluated, "\"type\":\"edn\",\"text\":\"true\"") != null;
    expect(context, found, "serve: a Clojure notebook queries the run ({s})", .{
        evaluated[0..@min(evaluated.len, 300)],
    });
}

/// The web UI in a browser (tests/ui, Playwright), against a serve with three runs of the bank
/// example: one finished with a failing property (its causality analysis, run from the page to
/// its end), another finished, and one running while the tests look at it.
fn check_ui(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    cwd.access(context.io, "tests/ui/node_modules/@playwright/test", .{}) catch {
        std.debug.print("SKIP ui: tests/ui has no Playwright (npm ci && npx playwright install " ++
            "--with-deps chromium there)\n", .{});
        return;
    };
    const address = "127.0.0.1:7892";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "ui-serve" });
    cwd.deleteTree(context.io, data) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed = curl(context, &.{url ++ "/runs"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    for ([_][]const u8{
        "\"seed\":3,\"branches\":16",
        "\"seed\":4,\"branches\":8",
    }) |runs| {
        const body = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",\"coverage\":\"off\",{s}}}", .{
            std.json.fmt(program, .{}), runs,
        });
        _ = try curl(context, &.{ "-X", "POST", "-d", body, url ++ "/runs" });
    }
    for ([_][]const u8{ url ++ "/runs/1", url ++ "/runs/2" }) |run_url| {
        for (0..3000) |_| {
            const run = try curl(context, &.{run_url});
            if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null) break;
            sleep_ms(200);
        }
    }
    // Run 1's first failure is on disk as soon as it was found: the explorer's ladder (its
    // holders) or serve's save of it.
    const snapshots = try std.fs.path.join(arena, &.{ data, "runs", "1", "snapshots" });
    var saved_log: []const u8 = "";
    for (0..600) |_| {
        var dir = cwd.openDir(context.io, snapshots, .{ .iterate = true }) catch {
            sleep_ms(500);
            continue;
        };
        defer dir.close(context.io);
        var iterator = dir.iterate();
        while (try iterator.next(context.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "failure-")) continue;
            const path = try std.fs.path.join(arena, &.{ snapshots, entry.name });
            const text = cwd.readFileAlloc(context.io, path, arena, .limited(1 << 20)) catch "";
            if (std.mem.indexOf(u8, text, "saved") != null) saved_log = text;
        }
        if (saved_log.len > 0) break;
        sleep_ms(500);
    }
    expect(context, saved_log.len > 0, "ui: run 1's first failure is on disk as soon as it was " ++
        "found (the explorer's ladder or serve's save)", .{});
    // The third runs while the tests look at it (on one CPU: the analysis needs the rest).
    const running = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",\"coverage\":\"off\"," ++
        "\"seed\":5,\"branches\":100000,\"jobs\":1,\"time_budget\":\"30m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", running, url ++ "/runs" });
    defer _ = curl(context, &.{ "-X", "POST", url ++ "/runs/3/stop" }) catch "";
    // The fourth, flat, for the page to stop and resume.
    const resumable = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",\"coverage\":\"off\"," ++
        "\"seed\":6,\"branches\":100000,\"jobs\":1,\"branching\":\"flat\",\"time_budget\":\"30m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", resumable, url ++ "/runs" });
    defer _ = curl(context, &.{ "-X", "POST", url ++ "/runs/4/stop" }) catch "";
    const command = try std.fmt.allocPrint(arena, "cd tests/ui && DETERMINISMO_URL={s} npx playwright test", .{url});
    const result = try std.process.run(arena, context.io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
    });
    const passed = result.term.success();
    // Playwright's summary ("8 passed (6.2m)"): how many tests ran.
    const summary = if (std.mem.indexOf(u8, result.stdout, " passed (")) |at| blk: {
        const start = (std.mem.lastIndexOfScalar(u8, result.stdout[0..at], '\n') orelse 0);
        const end = std.mem.indexOfScalarPos(u8, result.stdout, at, '\n') orelse result.stdout.len;
        break :blk std.mem.trim(u8, result.stdout[start..end], " \n");
    } else "no summary";
    expect(context, passed, "ui: the run page in a browser (Playwright, {s}): runs and their views by " ++
        "URL, a causality analysis from the page to its end, the map's failures, the tree's rows " ++
        "under the pointer, a running run's refreshes, a run stopped and resumed from its page", .{summary});
    if (!passed) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
}

/// Every exploration is a run of the host's (src/runs.zig): one started at a terminal shows in
/// serve as serve's own do, running, then judged; serve stops it.
fn check_runs(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const address = "127.0.0.1:7893";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "runs-store" });
    cwd.deleteTree(context.io, data) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed = curl(context, &.{url ++ "/runs"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    // --coverage off as every self-test's run in a store asks: bank-test is not instrumented,
    // and serve's gate stopped run 1 after its fifth timeline ("no coverage in its first 5").
    const system = [_][]const u8{ "--data", data, "--program", program, "--scenario", "bank", "--branching", "flat", "--jobs", "2", "--coverage", "off" };
    // One to its end, as at a terminal, its events elsewhere (--events-dir): the run links them.
    // serve took the link for no directory (NotDir) and never opened such runs (srv3, 65-71).
    const elsewhere = try std.fs.path.join(arena, &.{ context.scratch, "runs-events-elsewhere" });
    cwd.deleteTree(context.io, elsewhere) catch {};
    const output = try explore(context, &(system ++ [_][]const u8{ "--seed", "3", "--branches", "8", "--events-dir", elsewhere }));
    const claimed = std.mem.indexOf(u8, output, "[determinismo] run 1: ") != null;
    // Another with the same events directory would make run 1's its own: refused.
    const again = try explore(context, &(system ++ [_][]const u8{ "--seed", "4", "--branches", "1", "--events-dir", elsewhere }));
    const refused = std.mem.indexOf(u8, again, "holds run 1's") != null;
    var listed: []const u8 = "";
    for (0..100) |_| {
        listed = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, listed, "\"state\":\"failed\"") != null) break;
        sleep_ms(200);
    }
    const timelines = curl(context, &.{url ++ "/runs/1/timelines"}) catch "";
    const logged = cwd.readFileAlloc(context.io, try std.fs.path.join(arena, &.{ data, "runs", "1", "output.log" }), arena, .limited(1 << 24)) catch "";
    // Replayed through serve from what the run kept (machine.json, request.json, its tape): the
    // same timeline. A terminal's command line was kept with --deterministic's part, which the
    // replay added again: other inputs, and the tape refused (srv3, Quint run 32).
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(output, &branches);
    const asked = try std.fmt.allocPrint(arena, "{{\"branch\":{d}}}", .{if (count > 0) branches[0].index else 0});
    const replay = curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs/1/replay" }) catch "";
    var replayed: [1]Branch = undefined;
    const same = count > 0 and parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    expect_all(context, &.{
        .{ "the exploration claimed run 1", claimed },
        .{ "another given its events directory is refused", refused },
        .{ "serve shows it failed", std.mem.indexOf(u8, listed, "\"state\":\"failed\"") != null },
        .{ "serve lists its 8 timelines, its events in another directory", std.mem.count(u8, timelines, "\"index\"") == 8 },
        .{ "its output.log has its timelines", std.mem.indexOf(u8, logged, "[branch") != null },
        .{ "serve replays one from what the run kept, the same", same },
    }, "runs: an exploration at a terminal is run 1 of the host's, in serve with its 8 timelines " ++
        "and its output, failed as it ended, replayed by serve", .{});
    // Another, long, which serve stops.
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "exec '{s}' explore", .{context.determinismo});
    for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
    for (system) |part| try command.print(arena, " '{s}'", .{part});
    try command.print(arena, " --seed 4 --branches 100000 --time-budget 30m --branching tree --holders-on-disk > /dev/null 2>&1", .{});
    var child = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", command.items }, .stdout = .ignore, .stderr = .ignore });
    var running = false;
    for (0..600) |_| {
        const run = curl(context, &.{url ++ "/runs/2"}) catch "";
        running = std.mem.indexOf(u8, run, "\"state\":\"running\"") != null;
        if (running) break;
        sleep_ms(100);
    }
    // Stopped once it holds moments on disk: they go with it (run 173's 209 GB stayed).
    const holders_directory = try std.fs.path.join(arena, &.{ data, "runs", "2", "holders" });
    var held: usize = 0;
    for (0..1200) |_| {
        held = files_count(context, holders_directory);
        if (held > 0) break;
        sleep_ms(100);
    }
    _ = curl(context, &.{ "-X", "POST", url ++ "/runs/2/stop" }) catch "";
    const term = try child.wait(context.io);
    var stopped = false;
    for (0..100) |_| {
        const run = curl(context, &.{url ++ "/runs/2"}) catch "";
        stopped = std.mem.indexOf(u8, run, "\"state\":\"stopped\"") != null;
        if (stopped) break;
        sleep_ms(200);
    }
    _ = term;
    var left = held;
    for (0..200) |_| {
        left = files_count(context, holders_directory);
        if (left == 0) break;
        sleep_ms(100);
    }
    expect_all(context, &.{
        .{ "serve shows it running", running },
        .{ "it held moments on disk", held > 0 },
        .{ "serve stopped it", stopped },
        .{ "its moments on disk went with it", left == 0 },
    }, "runs: another, running at a terminal, shows running in serve, and serve stops it; its " ++
        "{d} moments held on disk go", .{held});
    // A third, drained (stop?drain=1): it starts no timeline more and ends once those running
    // end, every one recorded (a stop discards them: 26 to 82% of a first pass's core time,
    // 2026-11-10); stopped then, resumable.
    try drained_check(context, url, data, system);
    // Run 1's events directory deleted, the path is free: another run takes it, and run 1's
    // link to it goes (it would show the new run's events). The smokes of 2026-10-29 were
    // refused their own deleted directories.
    cwd.deleteTree(context.io, elsewhere) catch {};
    const taken = try explore(context, &(system ++ [_][]const u8{ "--seed", "5", "--branches", "1", "--events-dir", elsewhere }));
    var link_buffer: [4096]u8 = undefined;
    const link = try std.fs.path.joinZ(arena, &.{ data, "runs", "1", "events" });
    const run_1_link = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, link, &link_buffer, link_buffer.len);
    expect_all(context, &.{
        .{ "it says the directory was run 1's", std.mem.indexOf(u8, taken, "was run 1's, deleted since") != null },
        .{ "it ran", std.mem.indexOf(u8, taken, "[branch") != null },
        .{ "run 1 links it no more", std.os.linux.errno(run_1_link) == .NOENT },
    }, "runs: a deleted run's events directory is another's to take", .{});
}

fn drained_check(context: *Context, url: []const u8, data: []const u8, system: anytype) !void {
    const arena = context.arena;
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "exec '{s}' explore", .{context.determinismo});
    for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
    for (system) |part| try command.print(arena, " '{s}'", .{part});
    // Twice as many timelines at once as CPUs: half wait for theirs as it drains (a hunt's
    // drain beside the next hunt's VMs), and run nothing (unstarted).
    const cpu_count: u32 = @intCast(std.Thread.getCpuCount() catch 4);
    try command.print(arena, " --seed 6 --branches 100000 --time-budget 30m --branching tree --jobs {d} > /dev/null 2>&1", .{@min(2 * cpu_count, 256)});
    var child = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", command.items }, .stdout = .ignore, .stderr = .ignore });
    // Its id: the newest run serve lists once it runs.
    var id: u32 = 0;
    for (0..600) |_| {
        const runs = curl(context, &.{try std.fmt.allocPrint(arena, "{s}/runs", .{url})}) catch "";
        const Row = struct { id: u32, state: []const u8 };
        const rows = std.json.parseFromSliceLeaky([]const Row, arena, runs, .{ .ignore_unknown_fields = true }) catch &.{};
        for (rows) |row| {
            if (std.mem.eql(u8, row.state, "running") and row.id > id) id = row.id;
        }
        if (id != 0) break;
        sleep_ms(100);
    }
    const directory = try std.fs.path.join(arena, &.{ data, "runs", try std.fmt.allocPrint(arena, "{d}", .{id}) });
    const activity_path = try std.fs.path.join(arena, &.{ directory, "activity.jsonl" });
    // Drained once a sample shows timelines running (the explorer samples every 10 s).
    var sampled_running = false;
    for (0..600) |_| {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, activity_path, arena, .limited(64 << 20)) catch "";
        sampled_running = std.mem.indexOf(u8, text, "\"a\":\"sample\"") != null and std.mem.indexOf(u8, text, "\"o\":[[") != null;
        if (sampled_running) break;
        sleep_ms(200);
    }
    const answer = curl(context, &.{ "-X", "POST", try std.fmt.allocPrint(arena, "{s}/runs/{d}/stop?drain=1", .{ url, id }) }) catch "";
    const term = try child.wait(context.io);
    var stopped = false;
    for (0..100) |_| {
        const run = curl(context, &.{try std.fmt.allocPrint(arena, "{s}/runs/{d}", .{ url, id })}) catch "";
        stopped = std.mem.indexOf(u8, run, "\"state\":\"stopped\"") != null;
        if (stopped) break;
        sleep_ms(200);
    }
    // Every timeline a sample saw running has its end recorded: none cut.
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, activity_path, arena, .limited(64 << 20)) catch "";
    var ended: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var unstarted: usize = 0;
    // Holders still listening once its tree ended: its drained timelines' holders, never in the
    // registry (it took them at their generation's judgment, which a drain never holds), alive
    // until the explorer exited (Kafka 1919: 46, 129 GB through its closing replays).
    var holders_left = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const Line = struct { a: []const u8, i: ?u32 = null, o: ?[]const [2]u64 = null };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, parsed.a, "timeline")) if (parsed.i) |index| try ended.put(arena, index, {});
        if (std.mem.eql(u8, parsed.a, "unstarted")) if (parsed.i) |index| {
            try ended.put(arena, index, {});
            unstarted += 1;
        };
        if (parsed.o) |running| for (running) |entry| try seen.put(arena, @intCast(entry[1]), {});
        if (std.mem.eql(u8, parsed.a, "holders_left")) holders_left = true;
    }
    var cut: usize = 0;
    var it = seen.keyIterator();
    while (it.next()) |index| {
        if (!ended.contains(index.*)) cut += 1;
    }
    const exited_itself = term == .exited and (term.exited == 0 or term.exited == 3);
    const resumed = curl(context, &.{ "-X", "POST", try std.fmt.allocPrint(arena, "{s}/runs/{d}/resume", .{ url, id }) }) catch "";
    _ = curl(context, &.{ "-X", "POST", try std.fmt.allocPrint(arena, "{s}/runs/{d}/stop", .{ url, id }) }) catch "";
    expect_all(context, &.{
        .{ "serve answered draining", std.mem.indexOf(u8, answer, "\"state\":\"draining\"") != null },
        .{ "a sample saw timelines running first", sampled_running },
        .{ "the explorer ended itself (not killed)", exited_itself },
        .{ "every timeline seen running recorded its end", seen.count() > 0 and cut == 0 },
        .{ "no holder left listening at its tree's end", !holders_left },
        .{ "those still waiting for a CPU ran nothing (unstarted)", unstarted > 0 },
        // The hunt queue's throughput counts its cores from then by its running timelines.
        .{ "its activity log says its ending, a drain", std.mem.indexOf(u8, text, "\"a\":\"ending\"") != null and std.mem.indexOf(u8, text, "\"why\":\"drain\"") != null },
        .{ "serve shows it stopped", stopped },
        .{ "serve resumes it", std.mem.indexOf(u8, resumed, "\"id\"") != null },
    }, "runs: a drained stop (stop?drain=1) records the {d} timelines it saw running ({d} cut, " ++
        "{d} unstarted), ends stopped and resumes", .{ seen.count(), cut, unstarted });
}

/// The files in a directory (none when it is missing).
fn files_count(context: *Context, path: []const u8) usize {
    var directory = std.Io.Dir.cwd().openDir(context.io, path, .{ .iterate = true }) catch return 0;
    defer directory.close(context.io);
    var count: usize = 0;
    var entries = directory.iterate();
    while (entries.next(context.io) catch null) |_| count += 1;
    return count;
}

/// Whether causality's explanation ran futures inside the jump, each one's events kept.
fn explained_ok(context: *Context, stdout: []const u8) bool {
    const key = "{\"explained\":";
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const Line = struct { explained: []const struct { vtime_ms: u64, fails: bool, events: []const u8 } };
        const parsed = std.json.parseFromSliceLeaky(Line, context.arena, line, .{}) catch return false;
        if (parsed.explained.len == 0) return false;
        for (parsed.explained) |item| {
            const timelines = std.fs.path.join(context.arena, &.{ item.events, "timelines.jsonl" }) catch return false;
            std.Io.Dir.cwd().access(context.io, timelines, .{}) catch return false;
        }
        return true;
    }
    return false;
}

fn curl(context: *Context, arguments: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const json = "Content-Type: application/json";
    try argv.appendSlice(context.arena, &.{ "curl", "-s", "--fail", "-H", json });
    try argv.appendSlice(context.arena, arguments);
    const result = try run_kept(context, argv.items);
    if (!result.term.success()) return error.RequestFailed;
    return result.stdout;
}

fn sleep_ms(duration_ms: u64) void {
    const request = std.os.linux.timespec{
        .sec = @intCast(duration_ms / 1000),
        .nsec = @intCast((duration_ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&request, null);
}

/// `--until` (Antithesis's wait_until) stops a branch at its first violation and runs a command
/// there, the same on every replay; causality analysis measures the failure's probability at
/// moments before it (certain at the failure itself).
fn check_until_and_causality(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "3" };
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    const branch = try bank_violating_branch(context);
    var outputs: [2][]const u8 = undefined;
    for (&outputs) |*output| {
        const read = "det-nodes exec redis redis-cli mget account:0 account:1";
        const report = try explore(context, &(system ++ [_][]const u8{
            "--branch", branch, "--until", violation, "--exec", read,
        }));
        output.* = try lines_with(arena, report, &.{ "at moment", "exec_output" });
    }
    expect_all(context, &.{
        .{ "the command ran at the violation", std.mem.indexOf(u8, outputs[0], "exec_output") != null },
        .{ "the same output twice", std.mem.eql(u8, outputs[0], outputs[1]) },
    }, "until: branch {s} stops at its first violation, the same twice", .{branch});
    // Causality on a timeline whose failure some moment decided (bank_cold's): the first of seed
    // 3's violating timelines whose analysis finds a jump. Not every one has one: a timeline's
    // draws at its start can settle it (every future from its first moment failing), and which
    // timelines do moves with anything that moves their moments (the first violating one did on
    // 2026-11-18, with the SDK's change: timelines 0 and 1 certain from the snapshot on, 2 not).
    const cold_branches = try bank_cold_violating_branches(context);
    const cold_system = [_][]const u8{ "--program", program, "--scenario", "bank_cold", "--seed", "3" };
    var cold_branch: []const u8 = cold_branches[0];
    var result: std.process.RunResult = undefined;
    for (cold_branches) |candidate| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ context.determinismo, "causality" });
        try argv.appendSlice(arena, context.machine);
        try argv.appendSlice(arena, &cold_system);
        try argv.appendSlice(arena, &.{
            "--branch",  candidate, "--property", "total balance is conserved", "--points", "4",
            "--futures", "8",       "--json",
        });
        // Its explanation too: futures inside the jump with a command at their moment (a
        // system's logs turned up there; here, any command), each one's events kept.
        const explain_dir = try std.fmt.allocPrint(arena, "{s}/explain-{s}", .{ context.scratch, candidate });
        try argv.appendSlice(arena, &.{ "--explain-exec", "true", "--explain-dir", explain_dir });
        cold_branch = candidate;
        result = try run_kept(context, argv.items);
        if (std.mem.indexOf(u8, result.stdout, "{\"decided\":[{") != null) break;
    }
    // Refinement adds moments inside jumps.
    const curve = try causality_curve(arena, result.stdout);
    // Each round counts the faults its futures went through, with and without failing.
    const effects = std.mem.indexOf(u8, result.stdout, "{\"faults\":[") != null;
    expect_all(context, &.{
        .{ "at least 4 moments", curve.moments >= 4 },
        .{ "certain at the failure", curve.latest.probability == 1 },
        .{ "each within its 90% interval", curve.bounded },
        .{ "the futures' faults counted (a faults line each round)", effects },
        .{ "where it was decided: each jump with its faults and code first run (a decided line)", std.mem.indexOf(u8, result.stdout, "{\"decided\":[{") != null },
        .{ "explained: futures inside the jump, each with its events", explained_ok(context, result.stdout) },
    }, "causality: timeline {s} of {d} violating, {d} moments (4, and refinements inside jumps), certain at the " ++
        "failure ({d:.2}), each within its 90% interval, where it was decided", .{ cold_branch, cold_branches.len, curve.moments, curve.latest.probability });
    // The bug as an event condition (a verdict) instead of a property: the same analysis.
    var verdict_argv: std.ArrayList([]const u8) = .empty;
    try verdict_argv.appendSlice(arena, &.{ context.determinismo, "causality" });
    try verdict_argv.appendSlice(arena, context.machine);
    try verdict_argv.appendSlice(arena, &cold_system);
    try verdict_argv.appendSlice(arena, &.{
        "--branch", cold_branch, "--verdict", violation, "--points", "4", "--futures", "8", "--refine", "0", "--json",
    });
    const verdict_result = try run_kept(context, verdict_argv.items);
    const verdict = try causality_curve(arena, verdict_result.stdout);
    expect_all(context, &.{
        .{ "5 moments (the 4 points and the setup's)", verdict.moments == 5 },
        .{ "certain at the failure", verdict.latest.probability == 1 },
    }, "causality with a verdict (an event condition, no property): {d} moments, certain at the " ++
        "failure ({d:.2})", .{ verdict.moments, verdict.latest.probability });
    try check_files(context, &system, violation);
    try check_rewind(context, &system, violation);
}

const Point = struct { vtime_ms: u64, futures: u32 = 0, probability: f64, low: f64, high: f64 };

/// A causality analysis's curve from its `--json` lines: a moment's point comes again each time
/// one of its futures finishes, so each moment's last (most futures) is its point.
fn causality_curve(arena: std.mem.Allocator, stdout: []const u8) !struct { moments: u32, latest: Point, bounded: bool } {
    var by_moment: std.AutoArrayHashMapUnmanaged(u64, Point) = .empty;
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const point = std.json.parseFromSliceLeaky(Point, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        const entry = try by_moment.getOrPut(arena, point.vtime_ms);
        if (!entry.found_existing or point.futures >= entry.value_ptr.futures) entry.value_ptr.* = point;
    }
    var latest: Point = .{ .vtime_ms = 0, .probability = 0, .low = 0, .high = 0 };
    var bounded = true;
    for (by_moment.values()) |point| {
        bounded = bounded and point.low <= point.probability and point.probability <= point.high;
        if (point.vtime_ms >= latest.vtime_ms) latest = point;
    }
    return .{ .moments = @intCast(by_moment.count()), .latest = latest, .bounded = bounded };
}

/// The profiler at a moment of the self-test's echo node (a static Zig binary, with symbols):
/// samples, named functions, and the same profile twice.
fn check_profile(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    // A timeline of a fixed length: steady's driver phase is drawn, and seed 1's first ended at
    // 0.96 s, before the moment both parts look at (the command never ran: CommandUnfinished).
    const system = [_][]const u8{ "--program", program, "--scenario", "steady", "--seed", "1", "--timeline", "3s" };
    var folded: [2][]const u8 = undefined;
    for (&folded, 0..) |*text, run| {
        const name = try std.fmt.allocPrint(arena, "profile-{d}.folded", .{run});
        const path = try std.fs.path.join(arena, &.{ context.scratch, name });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ context.determinismo, "profile" });
        try argv.appendSlice(arena, context.machine);
        try argv.appendSlice(arena, &system);
        try argv.appendSlice(arena, &.{ "--branch", "0", "--at-vtime-ms", "1050" });
        try argv.appendSlice(arena, &.{ "--node", "echo", "--ms", "100", "--all" });
        try argv.appendSlice(arena, &.{ "--folded", path });
        _ = try run_kept(context, argv.items);
        const cwd = std.Io.Dir.cwd();
        text.* = cwd.readFileAlloc(context.io, path, arena, .limited(1 << 22)) catch "";
    }
    const samples = number_after(folded[0], "# det-profile: ") orelse 0;
    // Some stack ends in a named function, not an address.
    var named = false;
    var lines = std.mem.tokenizeScalar(u8, folded[0], '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const end = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ';') orelse continue) + 1;
        named = named or std.mem.indexOf(u8, line[start..end], "0x") == null;
    }
    expect_all(context, &.{
        .{ "samples taken", samples > 0 },
        .{ "a stack ends in a named function", named },
        .{ "the same profile twice", std.mem.eql(u8, folded[0], folded[1]) },
    }, "profile: {d} samples of a node at a moment, functions named, the same twice", .{samples});
    // Every thread's stack at the same moment.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "stacks" });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &system);
    try argv.appendSlice(arena, &.{ "--branch", "0", "--at-vtime-ms", "1050", "--node", "echo" });
    const result = try run_kept(context, argv.items);
    expect_all(context, &.{
        .{ "threads listed", std.mem.indexOf(u8, result.stderr, " thread ") != null },
        .{ "frames listed (#0)", std.mem.indexOf(u8, result.stderr, "#0  ") != null },
        .{ "frames named (_start)", std.mem.indexOf(u8, result.stderr, "_start") != null },
    }, "stacks: every thread of a node at a moment, named", .{});
}

/// Rewind: 5 ms of virtual time before the first violation, where it has not happened yet.
fn check_rewind(context: *Context, system: []const []const u8, violation: []const u8) !void {
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(context.arena, system);
    try extra.appendSlice(context.arena, &.{
        "--branch", try bank_violating_branch(context), "--until", violation, "--rewind-ms", "50", "--exec", "echo rewound",
    });
    const report = try explore(context, extra.items);
    const holds: u64 = @trunc(number_after(report, "the condition holds at ") orelse 0);
    const target: u64 = @trunc(number_after(report, "; the moment is ") orelse 0);
    const last = std.mem.lastIndexOf(u8, report, "at moment vtime=") orelse 0;
    const reached: u64 = @trunc(number_after(report[last..], "at moment vtime=") orelse 0);
    // The guest runs on while the command does: the rewind leaves it room to end first.
    expect_all(context, &.{
        .{ "the moment is exactly 50 ms before the condition holds", holds > target and holds - target == 50 * std.time.ns_per_ms },
        .{ "the guest stopped within 1 ms of the moment", reached >= target and reached - target < std.time.ns_per_ms },
        .{ "the command ran (\"rewound\")", std.mem.indexOf(u8, report, "\"text\":\"rewound\\n\"") != null },
        .{ "not failing yet", std.mem.indexOf(u8, report, "failing=0") != null },
    }, "rewind: 50 ms before the violation ({d}ns, then {d}ns), not failing yet", .{ holds, reached });
    // wait_until's timeout: the condition, or this time at the latest (here, before it holds:
    // just after the setup snapshot, wherever the guest's setup put it).
    const snapshot_ms = snapshot_vtime_ms(report) orelse 0;
    const deadline = try std.fmt.allocPrint(context.arena, "{d}", .{snapshot_ms + 20});
    var timeout: std.ArrayList([]const u8) = .empty;
    try timeout.appendSlice(context.arena, system);
    try timeout.appendSlice(context.arena, &.{
        "--branch", try bank_violating_branch(context), "--until", violation, "--at-vtime-ms", deadline, "--exec", "echo late",
    });
    const timed = try explore(context, timeout.items);
    const expected = try std.fmt.allocPrint(context.arena, "at moment vtime={d}", .{
        snapshot_ms + 20,
    });
    expect_all(context, &.{
        .{ "until says it timed out", std.mem.indexOf(u8, timed, "until: timed out") != null },
        .{ "the moment is the timeout's", std.mem.indexOf(u8, timed, expected) != null },
    }, "until: with a timeout, the moment is the timeout when the condition has not held", .{});
}

/// extract_file and inject_file at the first violation of branch 4.
fn check_files(context: *Context, system: []const []const u8, violation: []const u8) !void {
    const arena = context.arena;
    // extract_file: a node's file at that moment, byte for byte (Redis's own config here).
    const extracted = try std.fs.path.join(arena, &.{ context.scratch, "extracted" });
    var extract_argv: std.ArrayList([]const u8) = .empty;
    try extract_argv.appendSlice(arena, &.{ context.determinismo, "extract" });
    try extract_argv.appendSlice(arena, context.machine);
    try extract_argv.appendSlice(arena, system);
    try extract_argv.appendSlice(arena, &.{
        "--branch", try bank_violating_branch(context), "--until", violation, "--file", "redis:/etc/hostname",
        "--to",     extracted,
    });
    _ = try run_kept(context, extract_argv.items);
    const cwd = std.Io.Dir.cwd();
    const hostname = cwd.readFileAlloc(context.io, extracted, arena, .limited(64)) catch "";
    expect(context, std.mem.eql(u8, hostname, "redis\n"), "extract: a node's file at a moment " ++
        "({d} bytes)", .{hostname.len});
    // inject_file: 10000 arbitrary bytes into the node at that moment (three moment commands
    // of base64 and more), then a command there sees them, byte for byte.
    var bytes: [10_000]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 2654435761 >> 7);
    const local = try std.fs.path.join(arena, &.{ context.scratch, "to-inject" });
    try cwd.writeFile(context.io, .{ .sub_path = local, .data = &bytes });
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(&bytes, &digest, .{});
    var inject_argv: std.ArrayList([]const u8) = .empty;
    try inject_argv.appendSlice(arena, &.{ context.determinismo, "inject" });
    try inject_argv.appendSlice(arena, context.machine);
    try inject_argv.appendSlice(arena, system);
    try inject_argv.appendSlice(arena, &.{
        "--branch", try bank_violating_branch(context), "--until", violation, "--file", "redis:/tmp/injected", "--from", local,
    });
    try inject_argv.appendSlice(arena, &.{
        "--then", "md5sum /proc/$(cat /run/det/nodes/redis/pid)/root/tmp/injected",
    });
    const injected = try run_kept(context, inject_argv.items);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const seen = std.mem.indexOf(u8, injected.stderr, &hex) != null;
    expect(context, seen, "inject: {d} bytes into a node at a moment, the same there", .{
        bytes.len,
    });
}

/// The lines of `text` containing any of `keys`, joined.
fn lines_with(arena: std.mem.Allocator, text: []const u8, keys: []const []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        for (keys) |key| {
            if (std.mem.indexOf(u8, line, key) == null) continue;
            try kept.appendSlice(arena, line);
            try kept.append(arena, '\n');
            break;
        }
    }
    return kept.items;
}

/// Antithesis's network faults: partitions into groups and clogs, with their disruption forms,
/// recorded in full; a branch with one replays exactly.
fn check_network_faults(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "shop-test" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "fault-events" });
    const system = [_][]const u8{ "--program", program, "--scenario", "prices", "--seed", "2" };
    // Flat: one baseline per timeline, and any of them replays by its index.
    _ = try explore(context, &(system ++ [_][]const u8{
        "--branches", "64", "--events-dir", events, "--branching", "flat",
    }));
    const partition = "event=fault details.kind=partition_groups";
    const groups = try query_count(context, &.{ events, partition });
    const clogs = try query_count(context, &.{ events, "event=fault details.kind=clog" });
    const threads = try query_count(context, &.{ events, "event=fault details.kind=thread_pause" });
    const baselines = try query_count(context, &.{ events, "event=network_baseline" });
    // A restore is logged only while network faults are under way: they overlap the next fault.
    const restores = try query_count(context, &.{ events, "event=fault details.kind=restore" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        context.determinismo, "query",  events, "event=fault details.kind=partition_groups",
        "--branches",         "--json",
    });
    const found = try run_kept(context, argv.items);
    const First = struct { branch: u32 };
    const line_end = std.mem.indexOfScalar(u8, found.stdout, '\n') orelse found.stdout.len;
    const first = std.json.parseFromSliceLeaky(First, arena, found.stdout[0..line_end], .{
        .ignore_unknown_fields = true,
    }) catch null;
    var same = false;
    if (first) |branch_found| {
        const index = try std.fmt.allocPrint(arena, "{d}", .{branch_found.branch});
        var hashes: [2]Branch = undefined;
        for (&hashes) |*hash| {
            const report = try explore(context, &(system ++ [_][]const u8{
                "--branch", index, "--branching", "flat",
            }));
            var one: [1]Branch = undefined;
            if (parse_branches(report, &one) == 1) hash.* = one[0];
        }
        same = std.mem.eql(u8, hashes[0].events_hash, hashes[1].events_hash);
    }
    expect_all(context, &.{
        .{ "partitions into groups", groups > 0 },
        .{ "clogs", clogs > 0 },
        .{ "thread pauses", threads > 0 },
        .{ "64 network baselines", baselines == 64 },
        .{ "restores of overlapping network faults", restores > 0 },
        .{ "a branch with a partition replays exactly", same },
    }, "faults: {d} partitions into groups, {d} clogs, {d} thread pauses, " ++
        "{d} network baselines, {d} restores of overlapping network faults; a branch with a " ++
        "partition replays exactly", .{ groups, clogs, threads, baselines, restores });
}

/// Antithesis's fault exclusions (`fault_exclusions`, a regex over names): a node whose name
/// matches gets no faults of its own while the others get theirs; the same seeds without it
/// fault that node.
fn check_fault_exclusions(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "shop-test" });
    const system = [_][]const u8{
        "--program",  program, "--scenario",  "prices", "--seed", "2",
        "--branches", "16",    "--branching", "flat",
    };
    const plain = try std.fs.path.join(arena, &.{ context.scratch, "exclusions-plain" });
    const spared = try std.fs.path.join(arena, &.{ context.scratch, "exclusions-spared" });
    _ = try explore(context, &(system ++ [_][]const u8{ "--events-dir", plain }));
    _ = try explore(context, &(system ++ [_][]const u8{ "--events-dir", spared, "--fault-exclusions", "^postg.es$" }));
    const plain_postgres = try query_count(context, &.{ plain, "event=fault details.node=postgres" });
    const spared_postgres = try query_count(context, &.{ spared, "event=fault details.node=postgres" });
    const spared_redis = try query_count(context, &.{ spared, "event=fault details.node=redis" });
    const said = try query_count(context, &.{ spared, "event=fault_exclusions" });
    expect_all(context, &.{
        .{ "faults on postgres without exclusions", plain_postgres > 0 },
        .{ "none on postgres excluded", spared_postgres == 0 },
        .{ "faults on redis beside it", spared_redis > 0 },
        .{ "the pattern said in every timeline", said == 16 },
    }, "fault exclusions: {d} faults on postgres without them, {d} with `^postg.es$`, {d} on " ++
        "redis beside it; the pattern said in {d} of 16 timelines", .{ plain_postgres, spared_postgres, spared_redis, said });
}

/// How many events `determinismo query` finds (its --count line).
fn query_count(context: *Context, arguments: []const []const u8) !u64 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "query" });
    try argv.appendSlice(context.arena, arguments);
    try argv.append(context.arena, "--count");
    const result = try run_kept(context, argv.items);
    const end = std.mem.indexOfScalar(u8, result.stdout, ' ') orelse return 0;
    return std.fmt.parseInt(u64, result.stdout[0..end], 10) catch 0;
}

/// Antithesis's pausing faults: a driver asks for a quiet period from inside a node, and no
/// fault (but clock skips) starts during it, while faults happen before it.
fn check_quiet_period(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "quiet-events" });
    _ = try explore(context, &.{
        "--program",  program, "--profile",    "workers", "--scenario", "quiet", "--seed", "1",
        "--branches", "4",     "--events-dir", events,
    });
    const quiet = try query_count(context, &.{ events, "event=faults_quiet" });
    // Custom faults ran in the node, which finds det-stop-faults in its environment.
    const custom = try query_count(context, &.{
        events, "event=custom_fault_ran details.stop_faults=/opt/determinismo/bin/det-stop-faults",
    });
    const faults = try query_count(context, &.{ events, "event=fault" });
    const during = try query_count(context, &.{
        events,               "event=fault details.kind!=clock_skip", "--preceded-by",
        "event=faults_quiet", "--within",                             "1.9",
    });
    const counts = .{ quiet, faults, during, custom };
    expect_all(context, &.{
        .{ "quiet periods in all 4 timelines", quiet == 4 },
        .{ "faults happened", faults > 0 },
        .{ "none during a quiet period", during == 0 },
        .{ "custom faults ran in the node", custom > 0 },
    }, "quiet periods: requested from a node in {d} of 4 timelines; {d} faults, {d} during " ++
        "them; {d} custom faults", counts);
}

/// sdk.progress_while_quiet: after a second of faults the echo node answers while they pause, in
/// every timeline, and faults resume as soon as it has (not after the 5 s window).
fn check_progress_while_quiet(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "progress-events" });
    _ = try explore(context, &.{
        "--program",  program, "--profile",    "workers", "--scenario", "progress", "--seed", "1",
        "--branches", "4",     "--events-dir", events,
    });
    const message = "assert.message=\"the echo node answers while faults pause\"";
    const passed = try query_count(context, &.{ events, message ++ " assert.condition=true" });
    const failed = try query_count(context, &.{ events, message ++ " assert.condition=false" });
    const resumed = try query_count(context, &.{ events, "event=faults_resume" });
    const after = try query_count(context, &.{
        events, "event=fault details.kind!=clock_skip", "--preceded-by", "event=faults_resume",
    });
    const counts = .{ passed, failed, resumed, after };
    expect_all(context, &.{
        .{ "it passed in all 4 timelines", passed >= 4 },
        .{ "it never failed", failed == 0 },
        .{ "faults resumed each time it passed", resumed == passed },
        .{ "faults came back after", after > 0 },
    }, "progress while faults pause: passed {d} times (4 timelines), failed {d}; faults " ++
        "resumed {d} times, {d} faults after", counts);
}

/// The guest kernel's random generator after the snapshot: different in every branch, the same
/// when a branch replays.
fn check_kernel_entropy(context: *Context) !void {
    var values: [3][]const u8 = undefined;
    for ([_][]const u8{ "0", "1", "0" }, &values, 0..) |branch, *value, run| {
        const name = try std.fmt.allocPrint(context.arena, "entropy-{d}.jsonl", .{run});
        const events = try std.fs.path.join(context.arena, &.{ context.scratch, name });
        const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
        _ = try explore(context, &.{
            "--program", program, "--scenario", "steady", "--seed", "1", "--branch", branch,
            "--events",  events,
        });
        const cwd = std.Io.Dir.cwd();
        const log = cwd.readFileAlloc(
            context.io,
            events,
            context.arena,
            .limited(1 << 24),
        ) catch "";
        const key = "\"kernel_entropy\",\"details\":{\"value\":";
        const at = std.mem.indexOf(u8, log, key) orelse {
            value.* = "";
            continue;
        };
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, log, start, '}') orelse start;
        value.* = log[start..end];
    }
    const found = values[0].len > 0 and values[1].len > 0;
    expect_all(context, &.{
        .{ "both branches logged their kernel entropy", found },
        .{ "it differs between the branches", found and !std.mem.eql(u8, values[0], values[1]) },
        .{ "the replay has the first branch's", found and std.mem.eql(u8, values[0], values[2]) },
    }, "kernel randomness: {s} and {s} in two branches, {s} on replay", .{ values[0], values[1], values[2] });
}

/// A CPU-jitter entropy source passes its health tests (Go's FIPS mode's, the scenario mirrors
/// them) on the clock's low bits (VM.Options.tsc_jitter_seed), and a run of the same seed reads
/// the same.
fn check_clock_jitter(context: *Context) !void {
    var values: [2][]const u8 = undefined;
    for (&values, 0..) |*value, run| {
        const name = try std.fmt.allocPrint(context.arena, "clock-jitter-{d}.jsonl", .{run});
        const events = try std.fs.path.join(context.arena, &.{ context.scratch, name });
        const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
        _ = try explore(context, &.{
            "--program", program, "--scenario", "clock_jitter", "--seed", "1", "--branch", "0",
            "--events",  events,
        });
        const log = std.Io.Dir.cwd().readFileAlloc(context.io, events, context.arena, .limited(1 << 24)) catch "";
        const key = "\"clock_jitter\",\"details\":";
        const at = std.mem.indexOf(u8, log, key) orelse {
            value.* = "";
            continue;
        };
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, log, start, '}') orelse start;
        value.* = log[start .. end + 1];
    }
    expect_all(context, &.{
        .{ "the scenario measured its samples", values[0].len > 0 },
        .{ "its samples pass the health tests (no value 41 times in a row, none 410 of 512)", std.mem.indexOf(u8, values[0], "\"healthy\":true") != null },
        .{ "the same seed reads them the same", std.mem.eql(u8, values[0], values[1]) },
    }, "clock jitter: {s}, then {s}", .{ values[0], values[1] });
}

/// The built-in properties pass on a steady system and catch a node that exits by itself and an
/// OOM kill.
fn check_builtin_properties(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const steady = try explore(context, &.{
        "--program", program, "--scenario", "steady", "--seed", "1", "--branches", "2",
    });
    const passes = std.mem.indexOf(u8, steady, "2 branches, 0 with failing properties") != null;
    expect(context, passes, "built-in properties pass on a steady system", .{});
    const both = try explore(context, &.{
        "--program", program, "--profile",  "default,mutant", "--scenario", "steady",
        "--seed",    "1",     "--branches", "2",
    });
    expect_all(context, &.{
        .{ "the tests pass on the system (PASS default)", std.mem.indexOf(u8, both, "PASS default") != null },
        .{ "they catch its mutant (FAIL mutant)", std.mem.indexOf(u8, both, "FAIL mutant") != null },
    }, "mutation: the tests pass on the system and catch its mutant", .{});
    const exit_events = try std.fs.path.join(context.arena, &.{ context.scratch, "node-exit-events.jsonl" });
    const crash = try explore(context, &.{
        "--program", program,     "--scenario", "node_exit", "--seed", "1", "--branch", "0",
        "--events",  exit_events,
    });
    const caught = std.mem.indexOf(u8, crash, "FAIL \"no unexpected container exits\"") != null;
    // The failure carries what the node said last (tail.zig).
    const exit_said = std.Io.Dir.cwd().readFileAlloc(context.io, exit_events, context.arena, .limited(1 << 26)) catch "";
    const said = said: {
        var lines = std.mem.tokenizeScalar(u8, exit_said, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"no unexpected container exits\",\"condition\":false") == null) continue;
            break :said std.mem.indexOf(u8, line, "dying as told") != null;
        }
        break :said false;
    };
    expect_all(context, &.{
        .{ "the exit fails the property", caught },
        .{ "the failure carries the node's last words (dying as told)", said },
    }, "built-in properties catch a node that exits, saying what it said last", .{});
    try check_samples(context, program);
    const hog_events = try std.fs.path.join(context.arena, &.{ context.scratch, "hog-events.jsonl" });
    const hog = try explore(context, &.{
        "--program", program, "--profile", "memory",   "--scenario", "oom", "--seed", "1",
        "--branch",  "0",     "--events",  hog_events,
    });
    // Judged as the nodes' sampler saw it: within its period of the hog's command returning (the
    // kill), not at the timeline's end.
    const hog_log = std.Io.Dir.cwd().readFileAlloc(context.io, hog_events, context.arena, .limited(1 << 26)) catch "";
    var oom_failed_ns: ?u64 = null;
    var hog_returned_ns: ?u64 = null;
    var hog_lines = std.mem.tokenizeScalar(u8, hog_log, '\n');
    while (hog_lines.next()) |line| {
        const at = field_u64(line, "\"vtime_ns\":") orelse continue;
        if (hog_returned_ns == null and std.mem.indexOf(u8, line, "\"message\":\"the hog is killed\"") != null) hog_returned_ns = at;
        if (oom_failed_ns == null and std.mem.indexOf(u8, line, "\"message\":\"the kernel kills no process for lack of memory\"") != null and
            std.mem.indexOf(u8, line, "\"condition\":false") != null) oom_failed_ns = at;
    }
    const oom_at_its_moment = if (oom_failed_ns) |failed| if (hog_returned_ns) |returned|
        failed <= returned + 3 * std.time.ns_per_s
    else
        false else false;
    const workers = try explore(context, &.{
        "--program",  program, "--profile", "workers", "--scenario", "steady", "--seed", "1",
        "--branches", "8",
    });
    const all_pass = "8 branches, 0 with failing properties";
    // Judged, not only absent: the fault injector's watchdog reports when its faults end.
    const watched = std.mem.indexOf(u8, workers, "the fault injector never stalls") != null;
    expect_all(context, &.{
        .{ "every property passes in all 8", std.mem.indexOf(u8, workers, all_pass) != null },
        .{ "the workers' kills were reached (PASS reachable)", std.mem.indexOf(u8, workers, "PASS reachable") != null },
        .{ "the fault injector's stall property was judged", watched },
    }, "process kills hit workers, never a node's main process", .{});
    const oom = "FAIL \"the kernel kills no process for lack of memory\"";
    expect_all(context, &.{
        .{ "the OOM kill fails its property", std.mem.indexOf(u8, hog, oom) != null },
        .{ "the hog was killed", std.mem.indexOf(u8, hog, "FAIL \"the hog is killed\"") == null },
        .{ "at its moment (within the sampler's period of the kill)", oom_at_its_moment },
    }, "built-in properties catch an OOM kill in a node, as it happens", .{});
    const crash_events = try std.fs.path.join(context.arena, &.{ context.scratch, "crash-events.jsonl" });
    const crashed = try explore(context, &.{
        "--program", program,      "--scenario", "crash", "--seed", "1", "--branch", "0",
        "--events",  crash_events,
    });
    const crash_caught = std.mem.indexOf(u8, crashed, "FAIL \"no process crashes") != null;
    // Judged by det-core as it happened: the failure's moment the core dump's, not the end's.
    const crash_log = std.Io.Dir.cwd().readFileAlloc(context.io, crash_events, context.arena, .limited(1 << 26)) catch "";
    var crash_failed_ns: ?u64 = null;
    var dumped_ns: ?u64 = null;
    var crash_lines = std.mem.tokenizeScalar(u8, crash_log, '\n');
    while (crash_lines.next()) |line| {
        const at = field_u64(line, "\"vtime_ns\":") orelse continue;
        if (dumped_ns == null and std.mem.indexOf(u8, line, "\"event\":\"core_dump\"") != null) dumped_ns = at;
        if (crash_failed_ns == null and std.mem.indexOf(u8, line, "\"message\":\"no process crashes: ") != null and
            std.mem.indexOf(u8, line, "\"condition\":false") != null) crash_failed_ns = at;
    }
    const at_its_moment = if (crash_failed_ns) |failed| if (dumped_ns) |dumped|
        failed <= dumped + std.time.ns_per_s
    else
        false else false;
    expect_all(context, &.{
        .{ "the crash fails its property", crash_caught },
        .{ "at its moment (within 1 s of its core dump)", at_its_moment },
    }, "built-in properties catch a crash (SIGSEGV) in a node, as it happens", .{});
    // Declared known (schema.Node.crashes_known): counted as a sometimes, not failed.
    const known = try explore(context, &.{
        "--program", program, "--profile", "known-crash", "--scenario", "crash", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no crash property fails", std.mem.indexOf(u8, known, "FAIL \"no process crashes") == null },
        .{ "the known crash is counted", std.mem.indexOf(u8, known, "a process crash the system is known to have: det-selftest-node") != null },
    }, "a crash the system declares known is counted, not failed", .{});
    // An exit declared known by what the node wrote last: counted, not failed.
    const known_exit = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_exit", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no exit property fails", std.mem.indexOf(u8, known_exit, "FAIL \"no unexpected container exits\"") == null },
        .{ "the known exit is counted", std.mem.indexOf(u8, known_exit, "an exit the system is known to make: dying as told") != null },
    }, "an exit the system declares known (by its output) is counted, not failed", .{});
    // Then a start and an exit nothing declares: judged on that start's output alone, it fails,
    // though the node's log still holds the known text (etcd's spare, run 356: a removed
    // member's stop must not make a later start's panic known).
    const exit_again = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_exit_again", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "the first exit is counted known", std.mem.indexOf(u8, exit_again, "an exit the system is known to make: dying as told") != null },
        .{ "the later one fails", std.mem.indexOf(u8, exit_again, "FAIL \"no unexpected container exits\"") != null },
    }, "a known exit's text from an earlier start does not make a later exit known", .{});
    // A crash of the node's own process after it printed a known exit's text (Galera's abort
    // after "need to abort"): counted with it, the crash and the exit both, not failed.
    const known_crash_said = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_crash", "--seed", "1", "--branches", "1",
    });
    const unknown_crash_said = try explore(context, &.{
        "--program", program, "--scenario", "node_crash", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no crash property fails", std.mem.indexOf(u8, known_crash_said, "FAIL \"no process crashes") == null },
        .{ "no exit property fails", std.mem.indexOf(u8, known_crash_said, "FAIL \"no unexpected container exits\"") == null },
        .{ "the known way down is counted", std.mem.indexOf(u8, known_crash_said, "an exit the system is known to make: crashing as told") != null },
        .{ "without it, the crash fails its property", std.mem.indexOf(u8, unknown_crash_said, "FAIL \"no process crashes") != null },
    }, "a crash after a known exit's text (by its output) is counted, not failed", .{});
    // The same with no core dump (mariadbd crashing as it exits, runs 340 and 358): the kernel's
    // line alone, judged as the node exits (guest kernel patch 0007 names the node's namespace).
    const known_nodump = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_crash_nodump", "--seed", "1", "--branches", "1",
    });
    const unknown_nodump = try explore(context, &.{
        "--program", program, "--scenario", "node_crash_nodump", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no crash property fails", std.mem.indexOf(u8, known_nodump, "FAIL \"no process crashes") == null },
        .{ "the known way down is counted", std.mem.indexOf(u8, known_nodump, "an exit the system is known to make: crashing as told") != null },
        .{ "without it, the crash fails its property", std.mem.indexOf(u8, unknown_nodump, "FAIL \"no process crashes: det-selftest") != null },
    }, "a crash with no core dump after a known exit's text is counted, not failed", .{});
    // The same after a graceful stop's SIGTERM (Galera's joiner in hunt run 1952: its abort came
    // 1 s after the stop took the pidfile, and its crash was judged at the timeline's end by
    // its name alone): judged as the node's exit, with what it said.
    const known_stopping = try explore(context, &.{
        "--program", program, "--profile", "stop-known", "--scenario", "node_crash_stopping", "--seed", "1", "--branches", "1",
    });
    const unknown_stopping = try explore(context, &.{
        "--program", program, "--profile", "stop-unknown", "--scenario", "node_crash_stopping", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no crash property fails", std.mem.indexOf(u8, known_stopping, "FAIL \"no process crashes") == null },
        .{ "the known way down is counted", std.mem.indexOf(u8, known_stopping, "an exit the system is known to make: crashing as told") != null },
        .{ "without it, the crash fails its property", std.mem.indexOf(u8, unknown_stopping, "FAIL \"no process crashes: det-selftest") != null },
    }, "a crash after a known exit's text, while a graceful stop ends the node, is counted, not failed", .{});
    // An exit code of its own after a graceful stop's SIGTERM (PostgreSQL's gosu as PID 1, exit 2:
    // hunt run 1971): what the stop asked for, never a failure.
    const exit_stopping = try explore(context, &.{
        "--program", program, "--profile", "stop-unknown", "--scenario", "node_exit_stopping", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no exit property fails", std.mem.indexOf(u8, exit_stopping, "FAIL \"no unexpected container exits\"") == null },
    }, "an exit code of its own after a graceful stop is expected", .{});
    // The same while the node's disk fails (MongoDB's abort on WiredTiger's EIO, hunt run 1707:
    // the exit, expected under a disk fault, judged its crash lines as if nothing was said).
    const known_failing = try explore(context, &.{
        "--program", program, "--profile", "known-exit-disk", "--scenario", "node_crash_failing", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "no crash property fails", std.mem.indexOf(u8, known_failing, "FAIL \"no process crashes") == null },
        .{ "the known way down is counted", std.mem.indexOf(u8, known_failing, "an exit the system is known to make: crashing as told") != null },
    }, "a crash after a known exit's text while its disk fails is counted, not failed", .{});
    // A text known only while the disk fails (MongoDB's WiredTiger refusing a file its corrupted
    // reads made unreadable, hunt run 1734): counted under a disk fault, failed with a healthy
    // disk (a file torn by a power loss is a durability bug, not a fault's doing).
    const disk_only_failing = try explore(context, &.{
        "--program", program, "--profile", "known-exit-disk-only", "--scenario", "node_crash_failing", "--seed", "1", "--branches", "1",
    });
    // Healthy for sure: no disk fault drawn (with them, one drawn a millisecond before the crash
    // made it the fault's doing, rightly: seed 1's draws, 2026-11-10).
    const disk_only_healthy = try explore(context, &.{
        "--program", program, "--profile", "known-exit-disk-only", "--scenario", "node_crash", "--seed", "1", "--branches", "1", "--faults", "-disk",
    });
    // The disk healed a moment before the crash, in the same start: still the fault's doing
    // (Kafka's orderly shutdown on a failed log directory ends after the heal, trial run 1783).
    const disk_only_healed = try explore(context, &.{
        "--program", program, "--profile", "known-exit-disk-only", "--scenario", "node_crash_after_heal", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "under a disk fault no crash property fails", std.mem.indexOf(u8, disk_only_failing, "FAIL \"no process crashes") == null },
        .{ "under a disk fault it is counted", std.mem.indexOf(u8, disk_only_failing, "an exit the system is known to make: crashing as told") != null },
        .{ "after the heal in the same start it is counted", std.mem.indexOf(u8, disk_only_healed, "an exit the system is known to make: crashing as told") != null },
        .{ "after the heal no crash property fails", std.mem.indexOf(u8, disk_only_healed, "FAIL \"no process crashes") == null },
        .{ "ended after the heal, it starts again", std.mem.indexOf(u8, disk_only_healed, "FAIL \"a node that ended after its disk healed starts again") == null and
            std.mem.indexOf(u8, disk_only_healed, "a node that ended after its disk healed starts again") != null },
        .{ "with a healthy disk the crash fails", std.mem.indexOf(u8, disk_only_healthy, "FAIL \"no process crashes") != null },
    }, "a crash after a text known only under a failing disk is counted there and after its heal in that start, failed elsewhere", .{});
    // A supervised node's own exit (schema.Node.supervised): init starts it again, as systemd or
    // a pod would (Kafka's broker left down through a quiet window, hunt run 1928).
    const supervised = try explore(context, &.{
        "--program", program, "--profile", "supervised", "--scenario", "node_supervised", "--seed", "1", "--branches", "1", "--faults", "-crash,-restart",
    });
    expect_all(context, &.{
        .{ "its exit is counted as known", std.mem.indexOf(u8, supervised, "an exit the system is known to make: leaving unannounced") != null },
        .{ "it starts again", std.mem.indexOf(u8, supervised, "FAIL \"a supervised node that exited on its own starts again") == null and
            std.mem.indexOf(u8, supervised, "a supervised node that exited on its own starts again") != null },
    }, "a supervised node that exits on its own is started again", .{});
    // A SIGBUS reading a mapped page while a disk fault fails that file's reads, no core dumped
    // (judged at the node's exit, as ParticleDB's in run 1877): a known exit, the fault's doing;
    // the same SIGBUS with a healthy disk (a file truncated under its mapping) fails. The
    // "durable" profile: /data on the node's own disk (DET_DURABLE), no drawn crash.
    const sigbus_failing = try explore(context, &.{
        "--program", program, "--profile", "durable", "--scenario", "node_sigbus_failing", "--seed", "1", "--branches", "1", "--faults", "-crash",
    });
    const sigbus_healthy = try explore(context, &.{
        "--program", program, "--profile", "durable", "--scenario", "node_sigbus_healthy", "--seed", "1", "--branches", "1", "--faults", "-crash,-disk",
    });
    expect_all(context, &.{
        .{ "under a disk fault no crash property fails", std.mem.indexOf(u8, sigbus_failing, "FAIL \"no process crashes") == null },
        .{ "under a disk fault the SIGBUS is a known exit", std.mem.indexOf(u8, sigbus_failing, "an exit the system is known to make: a SIGBUS while its disk failed") != null },
        .{ "with a healthy disk the SIGBUS fails", std.mem.indexOf(u8, sigbus_healthy, "FAIL \"no process crashes") != null },
    }, "a SIGBUS under a failing disk is a known exit, failed with a healthy disk", .{});
    // A Go panic whose stack names a declared known panic (a leadership check on a nil node): the
    // panic's line is held for its stack and counted; undeclared, or another stack, it fails.
    const known_panic = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_panic", "--seed", "1", "--branches", "1",
    });
    const undeclared_panic = try explore(context, &.{
        "--program", program, "--scenario", "node_panic", "--seed", "1", "--branches", "1",
    });
    const other_panic = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_panic_other", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "the known panic does not fail", std.mem.indexOf(u8, known_panic, "FAIL \"no panics (Go)\"") == null },
        .{ "the known panic is counted", std.mem.indexOf(u8, known_panic, "a panic the system is known to have: main.told(0x0)") != null },
        .{ "undeclared, it fails", std.mem.indexOf(u8, undeclared_panic, "FAIL \"no panics (Go)\"") != null },
        .{ "another stack fails", std.mem.indexOf(u8, other_panic, "FAIL \"no panics (Go)\"") != null },
    }, "a panic whose stack names a known one is counted, another still fails", .{});
    // A panic the node survives and logs (TiDB's recovered ones): a node's log failures fail their
    // property at an undeclared site, count a known one's (schema.Node.log_failures).
    const logged_failure = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_logfail", "--seed", "1", "--branches", "1",
    });
    const logged_known = try explore(context, &.{
        "--program", program, "--profile", "known-exit", "--scenario", "node_logfail_known", "--seed", "1", "--branches", "1",
    });
    const logged_undeclared = try explore(context, &.{
        "--program", program, "--scenario", "node_logfail", "--seed", "1", "--branches", "1",
    });
    expect_all(context, &.{
        .{ "a logged failure fails its property", std.mem.indexOf(u8, logged_failure, "FAIL \"no recovered panics (selftest)\"") != null },
        .{ "a known one's is counted, not failed", std.mem.indexOf(u8, logged_known, "FAIL \"no recovered panics (selftest)\"") == null and
            std.mem.indexOf(u8, logged_known, "a failure the system is known to log: main.site_known") != null },
        .{ "a profile declaring none judges nothing", std.mem.indexOf(u8, logged_undeclared, "no recovered panics (selftest)") == null },
    }, "a node's log failures: one fails its property, a known one is counted", .{});
    // A command writes 40 MB in moments: the forwarder keeps 8 MB and the rate, and says what it
    // dropped; the logging property fails; the events are far smaller than the output.
    const flood_events = try std.fs.path.join(context.arena, &.{ context.scratch, "flood-events" });
    std.Io.Dir.cwd().deleteTree(context.io, flood_events) catch {};
    const flooded = try explore(context, &.{
        "--program", program, "--scenario", "flood", "--seed", "1", "--branches", "1", "--events-dir", flood_events,
    });
    const dropped = try query_count(context, &.{ flood_events, "event=output_dropped" });
    try events_plain(context, flood_events);
    const flood_file = try std.fs.path.join(context.arena, &.{ flood_events, "branch-0.jsonl" });
    const flood_size = (std.Io.Dir.cwd().statFile(context.io, flood_file, .{}) catch null);
    expect_all(context, &.{
        .{ "the forwarder said what it dropped", dropped > 0 },
        .{ "the logging property fails", std.mem.indexOf(u8, flooded, "FAIL always                hit in    1/1 branches, failing in    0  logging output stays under 200 MB") != null },
        .{ "the events are under 20 MB", flood_size != null and flood_size.?.size < 20 * 1000 * 1000 },
    }, "40 MB of output in moments: 8 MB kept, the rest dropped and counted, the logging property failing", .{});
    try check_core_dump(context, program);
}

/// One timeline run at once by more processes than the host has cores (they queue for the CPU
/// pool's hardware threads, both hyperthreads of a core busy): the same history in each. VMs on
/// sibling hyperthreads once parted (the guest kernel's TLB dependence, fixed since), and VMs
/// outside the pool ran anywhere (2026-10-27).
fn check_concurrent(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const runs = 8;
    var children: [runs]std.process.Child = undefined;
    var logs: [runs][]const u8 = undefined;
    for (&children, &logs, 0..) |*child, *log, index| {
        log.* = try std.fmt.allocPrint(arena, "{s}/concurrent-{d}.log", .{ context.scratch, index });
        var command: std.ArrayList(u8) = .empty;
        try command.print(arena, "exec '{s}' explore", .{context.determinismo});
        for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
        try command.print(arena, " --program '{s}' --scenario bank --seed 9 --branch 3 " ++
            "--branching flat 2> '{s}'", .{ program, log.* });
        child.* = try std.process.spawn(context.io, .{
            .argv = &.{ "sh", "-c", command.items },
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }
    for (&children) |*child| _ = try child.wait(context.io);
    var first: ?[]const u8 = null;
    var same: u32 = 0;
    for (logs) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 24)) catch "";
        var branches: [1]Branch = undefined;
        if (parse_branches(text, &branches) != 1) continue;
        const hash = branches[0].events_hash;
        if (first == null) first = hash;
        if (std.mem.eql(u8, first.?, hash)) same += 1;
    }
    expect(context, same == runs, "concurrent: one timeline run by {d} processes at once, " ++
        "the same history in {d}", .{ runs, same });
}

/// A run killed partway and resumed (--resume) explores what it would have whole: the same
/// timelines (index, events hash), once each; flat, and a tree (from its recorded summaries).
fn check_resume(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    for ([_][]const u8{ "flat", "tree" }) |branching| {
        const system = [_][]const u8{
            "--program",  program, "--scenario",   "bank", "--seed", "7", "--branching", branching,
            "--branches", "48",    "--generation", "16",   "--jobs", "3",
        };
        const whole = try std.fmt.allocPrint(arena, "{s}/resume-{s}-whole.jsonl", .{ context.scratch, branching });
        const parts = try std.fmt.allocPrint(arena, "{s}/resume-{s}-parts.jsonl", .{ context.scratch, branching });
        _ = try explore(context, &(system ++ [_][]const u8{ "--record", whole }));
        // Killed once a dozen timelines are recorded (its workers go with it).
        var command: std.ArrayList(u8) = .empty;
        try command.print(arena, "exec '{s}' explore", .{context.determinismo});
        for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
        for (system) |part| try command.print(arena, " '{s}'", .{part});
        try command.print(arena, " --record '{s}' 2> /dev/null", .{parts});
        var child = try std.process.spawn(context.io, .{
            .argv = &.{ "sh", "-c", command.items },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        for (0..6000) |_| {
            const text = std.Io.Dir.cwd().readFileAlloc(context.io, parts, arena, .limited(1 << 24)) catch "";
            if (std.mem.count(u8, text, "{\"branch\":") >= 12) break;
            sleep_ms(50);
        }
        _ = std.os.linux.kill(child.id.?, .TERM);
        _ = try child.wait(context.io);
        const interrupted = try record_timelines(context, parts);
        _ = try explore(context, &(system ++ [_][]const u8{ "--record", parts, "--resume" }));
        const expected = try record_timelines(context, whole);
        const resumed = try record_timelines(context, parts);
        const once = resumed.len == 48 and for (resumed[1..], resumed[0 .. resumed.len - 1]) |a, b| {
            if (std.mem.eql(u8, timeline_index(a), timeline_index(b))) break false;
        } else true;
        const kept = for (interrupted) |line| {
            const found = for (resumed) |other| {
                if (std.mem.eql(u8, line, other)) break true;
            } else false;
            if (!found) break false;
        } else true;
        // Flat: the timelines of the whole run. A tree's generations follow its timelines'
        // finishing order, which the interruption changed: the resumed tree goes on from the
        // record, not as the whole run went.
        const as_whole = std.mem.eql(u8, branching, "tree") or (expected.len == resumed.len and
            for (expected, resumed) |a, b| {
                if (!std.mem.eql(u8, a, b)) break false;
            } else true);
        expect_all(context, &.{
            .{ "48 timelines recorded, once each", once },
            .{ "those recorded before the interruption kept as they were", kept },
            .{ "flat: the whole run's timelines", as_whole },
        }, "resume ({s}): killed at {d} timelines, resumed: {d} timelines, once each (the whole " ++
            "run: {d})", .{ branching, interrupted.len, resumed.len, expected.len });
    }
}

/// A record_timelines line's index.
fn timeline_index(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
}

/// A record's timelines as "index events_hash", sorted (duplicates kept: they would differ).
fn record_timelines(context: *Context, path: []const u8) ![]const []const u8 {
    const arena = context.arena;
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 26)) catch "";
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const index = field_json(line, "\"index\":") orelse continue;
        const hash = field_json(line, "\"events_hash\":\"") orelse continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s:0>8} {s}", .{ index, hash }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out.items;
}

/// The crash leaves a core dump, which `extract` takes out of the runner at a later moment.
/// Each node's resources every 2 s (det-nodes samples): its memory, and from the second sample on
/// the CPU it used meanwhile.
fn check_samples(context: *Context, program: []const u8) !void {
    const events_path = try std.fs.path.join(context.arena, &.{ context.scratch, "samples-events.jsonl" });
    _ = try explore(context, &.{
        "--program", program, "--scenario", "steady", "--seed",   "1",
        "--branch",  "0",     "--timeline", "10s",    "--events", events_path,
    });
    const events = std.Io.Dir.cwd().readFileAlloc(context.io, events_path, context.arena, .limited(1 << 26)) catch "";
    var samples: u32 = 0;
    var samples_cpu: u32 = 0;
    var last_ns: u64 = 0;
    var first_sample_ns: ?u64 = null;
    var lines = std.mem.tokenizeScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"vtime_ns\":")) |at| {
            last_ns = field_u64(line[at..], "\"vtime_ns\":") orelse last_ns;
        }
        if (std.mem.indexOf(u8, line, "\"event\":\"node_sample\"") == null) continue;
        if (std.mem.indexOf(u8, line, "\"node\":\"echo\"") == null) continue;
        if (std.mem.indexOf(u8, line, "\"memory_mib\":") == null) continue;
        samples += 1;
        if (first_sample_ns == null) first_sample_ns = last_ns;
        if (std.mem.indexOf(u8, line, "\"cpu_ms\":null") == null) samples_cpu += 1;
    }
    // One every 2 s from the first to the timeline's end, give or take one.
    const expected = (last_ns -| (first_sample_ns orelse last_ns)) / (2 * std.time.ns_per_s) + 1;
    expect_all(context, &.{
        .{ "the timeline lasts two samples (4 s)", samples >= 2 },
        .{ "the node is sampled every 2 s", samples + 1 >= expected and samples <= expected + 1 },
        .{ "every sample after the first has the CPU used meanwhile", samples_cpu + 1 >= samples },
    }, "each node's CPU and memory sampled every 2 s: {d} samples of the echo node in {d} s", .{
        samples, last_ns / std.time.ns_per_s,
    });
}

/// A node's own exit with a nonzero status names where it was asked (guest/runtime/exits.zig):
/// the echo node told to leave (`leave`: exit_group(4) in its handler of a request) leaves an
/// exit_stack event with its status, its process, the instruction its exit_group was called
/// from, its stack pointer, and its stack's words into code, the handler's caller among them by
/// its line (the node is a binary, with its table of lines).
fn check_exit_stack(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "exit-stack.jsonl" });
    _ = try explore(context, &.{
        "--program", program, "--profile", "supervised",      "--scenario", "node_supervised", "--seed", "1",
        "--branch",  "0",     "--faults",  "-crash,-restart", "--events",   events,
    });
    const log = std.Io.Dir.cwd().readFileAlloc(context.io, events, arena, .limited(1 << 24)) catch "";
    const key = "\"event\":\"exit_stack\"";
    const at = std.mem.indexOf(u8, log, key);
    const line = if (at) |found| log[found..(std.mem.indexOfScalarPos(u8, log, found, '\n') orelse log.len)] else "";
    expect_all(context, &.{
        .{ "the node's own exit leaves an exit_stack event", at != null },
        .{ "with its status and its process", std.mem.indexOf(u8, line, "\"status\":4") != null and std.mem.indexOf(u8, line, "\"process\":\"det-selftest-no") != null },
        .{ "the instruction it asked to exit from and its stack pointer", std.mem.indexOf(u8, line, "\"rip\":\"0x") != null and std.mem.indexOf(u8, line, "\"rsp\":\"0x") != null },
        .{ "and the node's own code among its stack's callers, by line", std.mem.indexOf(u8, line, "node.zig:") != null },
    }, "exit stack: {s}", .{line[0..@min(line.len, 700)]});
    // Its output gone to /dev/null first (a daemon's): the forwarder still answers its exit.
    const quiet_events = try std.fs.path.join(arena, &.{ context.scratch, "exit-stack-quiet.jsonl" });
    _ = try explore(context, &.{
        "--program", program, "--profile", "supervised",      "--scenario", "node_supervised_quiet", "--seed", "1",
        "--branch",  "0",     "--faults",  "-crash,-restart", "--events",   quiet_events,
    });
    const quiet_log = std.Io.Dir.cwd().readFileAlloc(context.io, quiet_events, arena, .limited(1 << 24)) catch "";
    const quiet_at = std.mem.indexOf(u8, quiet_log, key);
    const quiet_line = if (quiet_at) |found| quiet_log[found..(std.mem.indexOfScalarPos(u8, quiet_log, found, '\n') orelse quiet_log.len)] else "";
    expect_all(context, &.{
        .{ "an exit after the node's output ended leaves an exit_stack event too", quiet_at != null },
        .{ "with its status, its process and its stack", std.mem.indexOf(u8, quiet_line, "\"status\":5") != null and std.mem.indexOf(u8, quiet_line, "\"process\":\"det-selftest-no") != null and std.mem.indexOf(u8, quiet_line, "node.zig:") != null },
    }, "exit stack, output ended: {s}", .{quiet_line[0..@min(quiet_line.len, 700)]});
    // A Go program's exit (examples/race's, each run a process ending in os.Exit(counter + 10)):
    // its frames named from its own .gopclntab, the function that asked among them.
    const go_events = try std.fs.path.join(arena, &.{ context.scratch, "exit-stack-go.jsonl" });
    _ = try explore(context, &.{
        "--program", try std.fs.path.join(arena, &.{ context.bin, "race-test" }), "--profile", "go", "--scenario",   "race",
        "--seed",    "1",                                                         "--branch",  "0",  "--memory-mib", "1024",
        "--events",  go_events,
    });
    const go_log = std.Io.Dir.cwd().readFileAlloc(context.io, go_events, arena, .limited(1 << 26)) catch "";
    const go_at = std.mem.indexOf(u8, go_log, key);
    const go_line = if (go_at) |found| go_log[found..(std.mem.indexOfScalarPos(u8, go_log, found, '\n') orelse go_log.len)] else "";
    expect_all(context, &.{
        .{ "a Go program's own exit leaves an exit_stack event", go_at != null },
        .{ "its frames named by function, file and line (os.Exit called from main.main)", std.mem.indexOf(u8, go_line, "os.Exit proc.go:") != null and std.mem.indexOf(u8, go_line, "main.main race.go:") != null },
    }, "exit stack, Go: {s}", .{go_line[0..@min(go_line.len, 900)]});
    // A Rust program's exit (the same race in Rust, std::process::exit through Debian's glibc):
    // its frames in the stripped libc.so.6 named from its .dynsym, the function and the offset.
    const rust_events = try std.fs.path.join(arena, &.{ context.scratch, "exit-stack-rust.jsonl" });
    _ = try explore(context, &.{
        "--program", try std.fs.path.join(arena, &.{ context.bin, "race-test" }), "--profile", "rust", "--scenario",   "race",
        "--seed",    "1",                                                         "--branch",  "0",    "--memory-mib", "1024",
        "--events",  rust_events,
    });
    const rust_log = std.Io.Dir.cwd().readFileAlloc(context.io, rust_events, arena, .limited(1 << 26)) catch "";
    const rust_at = std.mem.indexOf(u8, rust_log, key);
    const rust_line = if (rust_at) |found| rust_log[found..(std.mem.indexOfScalarPos(u8, rust_log, found, '\n') orelse rust_log.len)] else "";
    expect_all(context, &.{
        .{ "a Rust program's own exit leaves an exit_stack event", rust_at != null },
        .{ "its frames in glibc named by function and offset (exit, from libc.so.6's .dynsym)", std.mem.indexOf(u8, rust_line, "exit+0x") != null and std.mem.indexOf(u8, rust_line, " libc.so.6\"") != null },
        .{ "and Rust's own by their paths, demangled (std::process::exit)", std.mem.indexOf(u8, rust_line, "\"std::process::exit+0x") != null },
    }, "exit stack, Rust: {s}", .{rust_line[0..@min(rust_line.len, 900)]});
}

fn check_core_dump(context: *Context, program: []const u8) !void {
    const arena = context.arena;
    const events = try std.fs.path.join(arena, &.{ context.scratch, "crash.jsonl" });
    const system = [_][]const u8{ "--program", program, "--scenario", "crash", "--seed", "1" };
    _ = try explore(context, &(system ++ [_][]const u8{ "--branch", "0", "--events", events }));
    const cwd = std.Io.Dir.cwd();
    const log = cwd.readFileAlloc(context.io, events, arena, .limited(1 << 24)) catch "";
    const key = "\"event\":\"core_dump\"";
    const at = std.mem.indexOf(u8, log, key) orelse {
        expect(context, false, "core dump: a crash leaves one", .{});
        return;
    };
    const path_key = "\"path\":\"";
    const path_start = (std.mem.indexOfPos(u8, log, at, path_key) orelse at) + path_key.len;
    const path_end = std.mem.indexOfScalarPos(u8, log, path_start, '"') orelse path_start;
    const core_path = log[path_start..path_end];
    const local = try std.fs.path.join(arena, &.{ context.scratch, "core" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "extract" });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &system);
    const file = try std.fmt.allocPrint(arena, "runner:{s}", .{core_path});
    try argv.appendSlice(arena, &.{ "--branch", "0", "--until", "event=core_dump" });
    try argv.appendSlice(arena, &.{ "--file", file, "--to", local });
    _ = try run_kept(context, argv.items);
    const core = cwd.readFileAlloc(context.io, local, arena, .limited(1 << 28)) catch "";
    // Where it crashed, said beside the dump (guest/runtime/where.zig): the thread's registers
    // and its stack, the instruction it stopped at first.
    const stack_key = "\"event\":\"crash_stack\"";
    const stack_at = std.mem.indexOf(u8, log, stack_key);
    const stack_line = if (stack_at) |found| log[found..(std.mem.indexOfScalarPos(u8, log, found, '\n') orelse log.len)] else "";
    const first_key = "\"frames\":[{\"address\":\"0x";
    const first_at = std.mem.indexOf(u8, stack_line, first_key);
    const named_key = "\"at\":\"";
    const named_start = if (first_at) |found| (std.mem.indexOfPos(u8, stack_line, found, named_key) orelse found) + named_key.len else 0;
    const named_end = std.mem.indexOfScalarPos(u8, stack_line, named_start, '"') orelse named_start;
    expect_all(context, &.{
        .{ "the core was extracted", core.len > 4 },
        .{ "it is an ELF file", core.len > 4 and std.mem.eql(u8, core[0..4], "\x7fELF") },
        .{ "the crash's stack is said beside it", stack_at != null and stack_at.? > at },
        .{ "with the thread's registers", std.mem.indexOf(u8, stack_line, "\"rip\":\"0x") != null and std.mem.indexOf(u8, stack_line, "\"rsp\":\"0x") != null },
        .{ "and the instruction it stopped at, named", first_at != null and named_end > named_start },
    }, "core dump: {s}, {d} bytes, an ELF core, extracted at a moment; its crash at {s}", .{
        core_path, core.len, stack_line[named_start..named_end],
    });
}

/// CPU modulation: the same seed's timelines change (preemption lands elsewhere), the bug is
/// still found, and a modulated branch replays exactly.
fn check_cpu_modulation(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "7" };
    const plain = try explore(context, &(system ++ [_][]const u8{ "--branches", "8", "--no-cpu-modulation" }));
    const modulated = try explore(context, &(system ++ [_][]const u8{
        "--branches", "8", "--cpu-modulation",
    }));
    var before: [8]Branch = undefined;
    var after: [8]Branch = undefined;
    const count = parse_branches(plain, &before);
    const count_modulated = parse_branches(modulated, &after);
    // Workers finish in any order: branches pair by index.
    var changed: u32 = 0;
    var third: []const u8 = "";
    for (after[0..count_modulated]) |b| {
        if (b.index == 3) third = b.events_hash;
        for (before[0..count]) |a| {
            if (a.index != b.index) continue;
            changed += @intFromBool(!std.mem.eql(u8, a.events_hash, b.events_hash));
        }
    }
    const failing = std.mem.indexOf(u8, modulated, "failing=1") != null;
    var replays: [2]Branch = undefined;
    for (&replays) |*replay| {
        const report = try explore(context, &(system ++ [_][]const u8{
            "--branch", "3", "--cpu-modulation",
        }));
        var one: [1]Branch = undefined;
        replay.* = if (parse_branches(report, &one) == 1) one[0] else .{
            .index = 0,
            .events_hash = "",
            .failing = false,
        };
    }
    expect_all(context, &.{
        .{ "modulation changes timelines", changed > 0 },
        .{ "the bug is found", failing },
        .{ "8 modulated timelines", count_modulated == 8 },
        .{ "branch 3 replays exactly, twice", third.len > 0 and std.mem.eql(u8, replays[0].events_hash, third) and std.mem.eql(u8, replays[1].events_hash, third) },
    }, "cpu modulation: {d} of {d} timelines change, the bug is found, branch 3 replays exactly", .{
        changed, count,
    });
}

/// The assertion catalog: an assertion no timeline evaluates fails, known from the catalog the
/// test program announced as it started; the C node announced its own.
fn check_catalog(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest-catalog" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "catalog.jsonl" });
    const report = try explore(context, &.{
        "--program", program, "--scenario", "catalog", "--seed", "1", "--branch", "0",
        "--events",  events,
    });
    // The catalog's verdict comes last: the line after its header names the assertion.
    const verdict = std.mem.indexOf(u8, report, "not reached in any scenario") orelse report.len;
    const failed = std.mem.indexOf(u8, report[verdict..], "FAIL sometimes") != null and
        std.mem.indexOf(u8, report[verdict..], "catalog: a branch no timeline takes") != null;
    const cwd = std.Io.Dir.cwd();
    const log = cwd.readFileAlloc(context.io, events, arena, .limited(1 << 24)) catch "";
    const declared_c = std.mem.indexOf(u8, log, "\"message\":\"the C SDK's randomness stays " ++
        "below its bound\",\"hit\":false") != null;
    expect_all(context, &.{
        .{ "the never-evaluated assertion fails from the catalog", failed },
        .{ "the C node announces its own assertion", declared_c },
    }, "catalog: an assertion no timeline evaluates fails from the catalog alone; the C node " ++
        "announces its own", .{});
    // Zig assertions carry their place in the code, from the program's debug info.
    const place = "catalog_test.zig\",\"line\":26,\"function\":";
    const located = std.mem.indexOf(u8, log, place) != null;
    expect(context, located, "catalog: a Zig assertion's event says where it is (file, line)", .{});
    if (!located or !failed or !declared_c) std.debug.print("{s}\n", .{report});
}

/// Guidance: four digits must add up to 35 (5 timelines in 10000), one comparison that coverage
/// cannot see into. 300 timelines miss it by chance; with the guidance assertion's distance,
/// det-strategy-mutate climbs to it.
fn check_guidance(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    // No replays verified (the timelines' own business, other checks'), and one worker: with
    // several, which timelines run follows the workers' timing (mutate's shared corpus, the tree's
    // generations), and under a busy host's load the guided 300 sometimes fell short (the batch of
    // 2026-11-08; the same run by hand solved it in 9), the random ones could hit by chance (5 in
    // 10000 each). One worker runs the same timelines every time: guided, 8 solve it.
    const common = [_][]const u8{
        "--program",  program, "--profile",        "maze-sum", "--scenario", "maze", "--seed", "3",
        "--branches", "300",   "--verify-replays", "0",        "--jobs",     "1",
    };
    const property = "PASS sometimes             hit in  300/300 branches, failing in    0  " ++
        "maze sum";
    const random = try explore(context, &common);
    const sync = try std.fmt.allocPrint(arena, "{s}/guidance-sync", .{context.scratch});
    try std.Io.Dir.cwd().createDirPath(context.io, sync);
    const strategy = try std.fmt.allocPrint(arena, "{s}/det-strategy-mutate --sync-dir {s}", .{
        context.bin, sync,
    });
    const guided = try explore(context, &(common ++ [_][]const u8{ "--strategy", strategy }));
    const missed = std.mem.indexOf(u8, random, property) == null;
    const found = std.mem.indexOf(u8, guided, property) != null;
    expect_all(context, &.{
        .{ "300 random timelines miss it", missed },
        .{ "the guided strategy solves it", found },
    }, "guidance: 300 random timelines miss the sum maze; guided by its distance, the strategy " ++
        "solves it", .{});
}

/// The tree explorer: timelines return to moments of earlier ones (a path at least one deep),
/// with one worker or four (a tree's generations follow its timelines' finishing order: not the
/// same tree); and a timeline of the greatest depth replays alone, exactly, from its tape (which
/// holds its path).
/// A strategy shapes the generation (the protocol's `branches` and `fill`): tree_focus.py puts
/// its one return on the generation's rarest moment with 8 timelines and asks for the rest fresh,
/// so the second generation is those 8 from one moment and 8 started from the setup snapshot.
fn check_shape(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/shape-tapes", .{context.scratch});
    const record = try std.fmt.allocPrint(arena, "{s}/shape.jsonl", .{context.scratch});
    _ = try explore(context, &.{
        "--program",  program, "--scenario",  "bank",                                 "--seed",       "5",
        "--branches", "48",    "--branching", "tree",                                 "--generation", "16",
        "--jobs",     "2",     "--strategy",  "python3 plugins/python/tree_focus.py", "--tape-dir",   tapes,
        "--record",   record,
    });
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, record, arena, .limited(1 << 26)) catch "";
    const Segment = struct { branch: u32, vtime_ns: u64 };
    const Timeline = struct { generation: u32 = 0, why: []const u8 = "", path: []const Segment = &.{} };
    const Line = struct { branch: ?Timeline = null };
    var focused: u32 = 0;
    var fresh: u32 = 0;
    var moments: std.AutoHashMapUnmanaged([2]u64, void) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const timeline = parsed.branch orelse continue;
        if (timeline.generation != 1) continue;
        if (std.mem.indexOf(u8, timeline.why, "focus:") != null) {
            focused += 1;
            if (timeline.path.len > 0) {
                const last = timeline.path[timeline.path.len - 1];
                try moments.put(arena, .{ last.branch, last.vtime_ns }, {});
            }
        } else if (std.mem.startsWith(u8, timeline.why, "From the setup snapshot")) fresh += 1;
    }
    expect_all(context, &.{
        .{ "8 timelines of the second generation from the strategy's one moment", focused == 8 and moments.count() == 1 },
        .{ "the rest of it started fresh, as it asked", fresh == 8 },
    }, "shape: generation 1: {d} timelines from its moment ({d} moments), {d} fresh", .{
        focused, moments.count(), fresh,
    });
}

/// A strategy served from a REPL (clients/clojure's determinismo.strategy), under babashka and
/// under jank: `:middle` chosen in its registry, a tree exploration of the bank asks it where to
/// return, over TCP (48 timelines: the pipeline's first two generations of 16 start from the
/// setup snapshot), and the timelines of its first judged generation start from its moments (each
/// the middle of a timeline's span, their reason "middle of timeline <n>"), while the composer's
/// named draws are answered by a strategy of their own (`use-strategy-for!`: zeros); the deepest
/// timeline replays alone from its tape, without the strategy.
fn check_repl_strategy(context: *Context) !void {
    const bb = context.bb orelse {
        std.debug.print("SKIP repl-strategy: no babashka (-Dbb or $DETERMINISMO_BB)\n", .{});
        return;
    };
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const Host = struct { name: []const u8, port: u16, runtime: []const []const u8 };
    var hosts: std.ArrayList(Host) = .empty;
    try hosts.append(arena, .{ .name = "babashka", .port = 7888, .runtime = &.{ bb, "--classpath", "clients/clojure/src" } });
    if (context.jank) |jank| {
        try hosts.append(arena, .{ .name = "jank", .port = 7889, .runtime = try arena.dupe([]const u8, &.{ jank, "--module-path", "clients/clojure/src", "run" }) });
    } else std.debug.print("SKIP repl-strategy: under jank (no jank: $DETERMINISMO_JANK or --jank)\n", .{});
    for (hosts.items) |host| {
        // jank's run takes no arguments past the script: the port is in its text.
        const script = try std.fmt.allocPrint(arena, "{s}/strategy-{s}.clj", .{ context.scratch, host.name });
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = try std.fmt.allocPrint(arena,
            \\(require '[determinismo.strategy :as strategy] '[determinismo.http :as http])
            \\(strategy/use-strategy! :middle)
            \\;; Per service: the composer's named draws all zeros, every other process's left as drawn.
            \\(swap! strategy/strategies assoc :zeros
            \\       {{:decide (fn [_ request] {{:hex (apply str (repeat (* 2 (:size request)) "0")) :reason "zeros"}})}})
            \\(strategy/use-strategy-for! #"^det-composer$" :zeros)
            \\;; Served only when right: a moment past 2^31 ns from two below it (jank 0.1's + wraps at
            \\;; 32 bits there), and decisions by their source.
            \\(let [answer (strategy/answer {{:method "returns" :generation 0 :count 1
            \\                               :candidates [{{:branch 1 :start_ns 1200000000 :end_ns 3200000000 :novel 1}}]}}
            \\                              (atom {{}}))
            \\      pull (fn [source] (strategy/answer {{:method "random" :size 2 :source source}} (atom {{}})))]
            \\  (when (and (= 2200000000 (:vtime_ns (first (:returns answer))))
            \\             (= {{:hex "0000" :reason "zeros"}} (pull "det-composer"))
            \\             (= {{}} (pull "bank-test")))
            \\    (strategy/serve! {d})))
            \\(http/sleep-ms 1800000)
            \\
        , .{host.port}) });
        const argv = try std.mem.concat(arena, []const u8, &.{ host.runtime, &.{script} });
        var served = try std.process.spawn(context.io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore });
        defer served.kill(context.io);
        // Its standard output is a file's, written at its exit: the port says when it serves.
        const listening = for (0..1200) |_| {
            if (tcp_listening(host.port)) break true;
            sleep_ms(100);
        } else false;
        expect(context, listening, "repl strategy ({s}): it listens on {d} (its middle of a span past 2^31 ns right, decisions by source)", .{ host.name, host.port });
        if (!listening) continue;
        const tapes = try std.fmt.allocPrint(arena, "{s}/strategy-{s}-tapes", .{ context.scratch, host.name });
        const record = try std.fmt.allocPrint(arena, "{s}/strategy-{s}.jsonl", .{ context.scratch, host.name });
        const strategy = try std.fmt.allocPrint(arena, "tcp://127.0.0.1:{d}", .{host.port});
        const report = try explore(context, &.{
            "--program",  program, "--scenario",  "bank",   "--seed",       "5",
            "--branches", "48",    "--branching", "tree",   "--generation", "16",
            "--jobs",     "2",     "--strategy",  strategy, "--tape-dir",   tapes,
            "--record",   record,
        });
        var branches: [48]Branch = undefined;
        const count = parse_branches(report, &branches);
        const middle = try record_whys_with(context, record, "middle of timeline ");
        const deep = try deepest_replays(context, program, record, tapes, branches[0..count], &.{});
        // The composer's draws answered zeros: on the tapes as overrides.
        const zeroed = try run_kept(context, &.{ "grep", "-rlF", "\"hex\":\"0000", tapes });
        const zeroed_tapes = count_lines(zeroed.stdout, "branch-");
        expect_all(context, &.{
            .{ "the composer's decisions answered by its own strategy (zeros, on the tapes)", zeroed_tapes > 0 },
            .{ "48 timelines explored", count == 48 },
            .{ "timelines from the strategy's moments", middle > 0 },
            .{ "the deepest replays alone from its tape, without the strategy", deep.depth >= 1 and deep.replays },
        }, "repl strategy ({s}): {d} timelines, {d} from its moments, {d} tapes with the composer's zeros; #{?d}, {d} deep, replays alone: {}", .{
            host.name, count, middle, zeroed_tapes, deep.index, deep.depth, deep.replays,
        });
    }
}

/// Whether something listens on 127.0.0.1:`port`: a connection opened, and closed at once.
fn tcp_listening(port: u16) bool {
    const linux = std.os.linux;
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    return linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) == .SUCCESS;
}

/// Lines of `text` containing `needle`.
fn count_lines(text: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| count += @intFromBool(std.mem.indexOf(u8, line, needle) != null);
    return count;
}

/// Timelines in a run's record whose reason (`why`) contains `needle`.
fn record_whys_with(context: *Context, record: []const u8, needle: []const u8) !u32 {
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, record, context.arena, .limited(1 << 26)) catch "";
    const Timeline = struct { why: []const u8 = "" };
    const Line = struct { branch: ?Timeline = null };
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(Line, context.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const timeline = parsed.branch orelse continue;
        count += @intFromBool(std.mem.indexOf(u8, timeline.why, needle) != null);
    }
    return count;
}

/// A strategy ends timelines (an event's reply `{"end": true}`): end_at_fault.py ends each at its
/// first fault. Those stop there, as the strategy ended them, without their end's checks. Told its
/// events one by one, then in batches (the end with the batch before its next decision).
fn check_end(context: *Context) !void {
    try check_end_told(context, "python3 plugins/python/end_at_fault.py", "one by one");
    try check_end_told(context, "python3 plugins/python/end_at_fault.py --batched", "in batches");
}

fn check_end_told(context: *Context, strategy: []const u8, told: []const u8) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const record = try std.fmt.allocPrint(arena, "{s}/end-{d}.jsonl", .{ context.scratch, strategy.len });
    const events = try std.fmt.allocPrint(arena, "{s}/end-{d}-events", .{ context.scratch, strategy.len });
    _ = try explore(context, &.{
        "--program",  program, "--scenario",   "bank", "--seed",     "5",
        "--branches", "8",     "--jobs",       "2",    "--strategy", strategy,
        "--record",   record,  "--events-dir", events,
    });
    // Each timeline's first fault ("branch N vtime S.SSSSSSs  {...}"), the moment the strategy
    // ends it at.
    var first_fault: [8]?u64 = @splat(null);
    const faults = try run_kept(context, &.{ context.determinismo, "query", events, "event=fault" });
    var fault_lines = std.mem.tokenizeScalar(u8, faults.stdout, '\n');
    while (fault_lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, words.next() orelse continue, "branch")) continue;
        const branch = std.fmt.parseInt(usize, words.next() orelse continue, 10) catch continue;
        if (!std.mem.eql(u8, words.next() orelse continue, "vtime")) continue;
        const text = words.next() orelse continue;
        const seconds = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, text, "s")) catch continue;
        if (branch >= first_fault.len) continue;
        const ns: u64 = @intFromFloat(seconds * std.time.ns_per_s);
        first_fault[branch] = @min(first_fault[branch] orelse ns, ns);
    }
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, record, arena, .limited(1 << 26)) catch "";
    const Timeline = struct { index: usize = 0, outcome: []const u8 = "", vtime_ns: u64 = 0, failing: []const []const u8 = &.{} };
    const Line = struct { branch: ?Timeline = null };
    var count: u32 = 0;
    var ended: u32 = 0;
    var ended_vtime_max: u64 = 0;
    var ended_at_fault: u32 = 0;
    var ended_judged_finished: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const timeline = parsed.branch orelse continue;
        count += 1;
        if (std.mem.eql(u8, timeline.outcome, "strategy_ended")) {
            ended += 1;
            ended_vtime_max = @max(ended_vtime_max, timeline.vtime_ns);
            // At its first fault: within a second of it (told in batches, the end comes with the
            // batch, before the next decision).
            if (timeline.index < first_fault.len) if (first_fault[timeline.index]) |fault_ns| {
                if (fault_ns <= timeline.vtime_ns and timeline.vtime_ns - fault_ns <= std.time.ns_per_s) ended_at_fault += 1;
            };
            for (timeline.failing) |name| {
                if (std.mem.startsWith(u8, name, "the guest finishes its scenario")) ended_judged_finished += 1;
            }
        }
    }
    expect_all(context, &.{
        .{ "8 timelines", count == 8 },
        .{ "most of them ended by the strategy at a fault", ended >= 4 },
        .{ "none judged on its end's checks", ended_judged_finished == 0 },
        // Not "before any that ran whole": a bank timeline's drive is drawn, some whole ones
        // 1.8 s long, past which a strategy's end at a later first fault came (2026-11-08).
        .{ "each ended within a second of its first fault", ended_at_fault == ended },
    }, "end, events told {s}: {d} timelines, {d} ended by the strategy (the last at {d} ms), {d} judged on their end", .{
        told, count, ended, ended_vtime_max / std.time.ns_per_ms, ended_judged_finished,
    });
}

/// A strategy plans (plan_first.py: every named decision with options, its first): the explorer
/// draws those decisions itself, no round trip each, the strategy's decisions all the same (a
/// plan's reason), and a timeline replays from its tape without the strategy.
fn check_plans(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/plans-tapes", .{context.scratch});
    const report = try explore(context, &.{
        "--program",  program, "--scenario", "bank", "--seed",     "5",
        "--branches", "4",     "--jobs",     "2",    "--strategy", "python3 plugins/python/plan_first.py",
        "--tape-dir", tapes,
    });
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    // The plan's draws, on the tapes: overrides with no reason (a strategy's asked answers have
    // one; this plugin is never asked).
    var planned: u32 = 0;
    for (branches[0..count]) |branch| {
        const tape_path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, branch.index });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, tape_path, arena, .limited(1 << 28)) catch continue;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "{\"pull\":") and std.mem.indexOf(u8, line, "\"reason\"") == null) planned += 1;
        }
    }
    const replays = if (count > 0) blk: {
        const last = branches[count - 1];
        const tape = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, last.index });
        const replay = try explore(context, &.{ "--program", program, "--scenario", "bank", "--tape", tape });
        var replayed: [1]Branch = undefined;
        break :blk parse_branches(replay, &replayed) == 1 and std.mem.eql(u8, replayed[0].events_hash, last.events_hash);
    } else false;
    expect_all(context, &.{
        .{ "4 timelines", count == 4 },
        .{ "decisions drawn from the strategy's plans, on the tapes", planned > 0 },
        .{ "a planned timeline replays from its tape without the strategy", replays },
    }, "plans: {d} timelines, {d} draws from plans on their tapes, replays: {}", .{ count, planned, replays });
}

/// A setup that reaches more behaviors than a timeline's table holds, each timeline reaching
/// them again before a path of its own (det-selftest's startup_coverage: a JVM's startup
/// coverage at each restart): the tree knows the setup's before its first generation
/// (Events.behaviors_collected), so the tables keep the paths and the first generation returns
/// to some. Before, every table held the same 8,192 startup lines and the tree never returned
/// (hunt run 1901, Pulsar with coverage: 170 timelines, all from the setup snapshot).
fn check_startup_coverage(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const output = try explore(context, &.{
        // 64: with four workers two generations are planned from the setup snapshot at once
        // (pipeline_depth_few_workers), and with 32 every timeline was planned before the first
        // judgment, no room for a return.
        "--program",   program, "--scenario",   "startup_coverage", "--seed", "3", "--branches", "64",
        "--branching", "tree",  "--generation", "16",               "--jobs", "4",
    });
    const known_line = try lines_with(arena, output, &.{"behaviors known from the setup"});
    const known = number_after(known_line, "tree: ") orelse 0;
    const first = try lines_with(arena, output, &.{"tree: generation 0:"});
    const returned = number_after(first, "known); ") orelse 0;
    expect_all(context, &.{
        .{ "the setup's 10,000 lines known before the first generation", known >= 10_000 },
        .{ "the first generation returns to some moment", returned > 0 },
    }, "startup coverage: {d} behaviors known from the setup; the first generation: {s}", .{
        known, std.mem.trimEnd(u8, first, "\n"),
    });
}

fn check_tree(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/tree-tapes", .{context.scratch});
    const record = try std.fmt.allocPrint(arena, "{s}/tree.jsonl", .{context.scratch});
    // Without CPU modulation (on by default): the check below has it.
    const common = [_][]const u8{
        "--program",   program, "--scenario",          "bank", "--seed", "5", "--branches", "64",
        "--branching", "tree",  "--no-cpu-modulation",
    };
    const one = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "1", "--tape-dir", tapes, "--record", record, "--verify-holders",
    }));
    const tree_events = try std.fmt.allocPrint(arena, "{s}/tree-events", .{context.scratch});
    const many = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4", "--events-dir", tree_events }));
    var sequential: [branches_max]Branch = undefined;
    var parallel: [branches_max]Branch = undefined;
    const count = parse_branches(one, &sequential);
    const parallel_count = parse_branches(many, &parallel);
    // Past the first generations planned (all from the setup snapshot), the tree deepens.
    const deep = try deepest_replays(context, program, record, tapes, sequential[0..count], &.{"--no-cpu-modulation"});
    // In-run snapshots (holders) made nodes without replays, in both: the same tree as replays
    // from their parents' start would make, which the deepest timeline's lone replay checks.
    // Holders are made only with 16 GB available (holders.zig): beside a hunt of large VMs
    // there may not be, and replays make the nodes (the run says so).
    const held = holders_made(one) and holders_made(many);
    // Each the node a replay makes, in what the guest can see (--verify-holders remade them).
    const verified = holders_verified(one);
    // The explorer looks at the host's memory beside its VMs for its run's claims, and says so
    // at its first look: without a pool of its own it never looked, and nothing said so
    // (2026-11-18). Not its first look that counts (every worker running a timeline at a look
    // 5 s apart): a one-worker tree is idle most of its time, and that line came or not.
    const claims_looked = std.mem.indexOf(u8, one, "the run's VMs claim") != null or
        std.mem.indexOf(u8, many, "the run's VMs claim") != null;
    expect_all(context, &.{
        .{ "64 timelines with one worker", count == 64 },
        .{ "64 timelines with four", parallel_count == 64 },
        .{ "the explorer looks at what the host holds for its VMs (its run's claims)", claims_looked },
        .{ "the tree deepens (a path at least one deep)", deep.depth >= 1 },
        .{ "the deepest timeline replays alone from its tape", deep.replays },
        .{ "in-run snapshots made nodes, with one worker and with four", held },
        .{ "each such node is the one a replay makes (--verify-holders)", verified },
    }, "tree: {d} and {d} timelines, up to {d} deep; #{?d} replays alone from its tape; {d} and " ++
        "{d} nodes from in-run snapshots, each the one a replay makes", .{
        count, parallel_count, deep.depth, deep.index, held_nodes(one), held_nodes(many),
    });
    if (!verified) std.debug.print("{s}\n", .{lines_with(context.arena, one, &.{
        "verify",
    }) catch ""});
    // Earlier returns (docs/ANTITHESIS_EXPLORATION.md's B): with an offset of 1 s (`1s`) every return
    // far enough into its branch lands before the moment it was chosen for, none with
    // --return-offsets 0. Not the default's draws (0 half the time): this seed's returns are at
    // three moments, one too early for any offset, so every eligible draw was 0 about one seed in
    // sixteen, and a change in what draws first flipped it (develop, 2026-11-14: 0 where 4 had).
    const record_offset = try std.fmt.allocPrint(arena, "{s}/tree-offset.jsonl", .{context.scratch});
    _ = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4", "--return-offsets", "1s", "--record", record_offset }));
    const earlier = try record_whys_with(context, record_offset, "(an earlier return)");
    const record_after = try std.fmt.allocPrint(arena, "{s}/tree-after.jsonl", .{context.scratch});
    _ = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4", "--return-offsets", "0", "--record", record_after }));
    const earlier_off = try record_whys_with(context, record_after, "(an earlier return)");
    expect_all(context, &.{
        .{ "some returns land before their moment", earlier > 0 },
        .{ "none with --return-offsets 0", earlier_off == 0 },
    }, "tree: {d} timelines from earlier returns with --return-offsets 1s, {d} with 0", .{ earlier, earlier_off });
    // Generations of 16 (the least) on 8 workers, nodes made by replays (no holders): a generation completes
    // while the last judgment's nodes are made, and waits for them as timelines go on (the loop
    // once blocked there: nothing reaped, sampled or started, and past the budget's grace finished
    // timelines killed uncounted). Every timeline counted, none stopped.
    const outpaced = try explore(context, &(common ++ [_][]const u8{ "--jobs", "8", "--generation", "16", "--no-holders" }));
    const outpaced_count = parse_branches(outpaced, &parallel);
    const waited = count_lines(outpaced, "it waits, timelines going on");
    expect_all(context, &.{
        .{ "64 timelines in generations of 16 on 8 workers", outpaced_count == 64 },
        .{ "none stopped uncounted", std.mem.indexOf(u8, outpaced, "stopped, not counted") == null },
    }, "tree: generations of 16 on 8 workers without holders: {d} timelines, {d} generations completed while the last one's nodes were made", .{ outpaced_count, waited });
    // Holders on disk (as while memory runs low): nodes loaded from the run's directory, each
    // the one a replay makes, and their files gone with the run.
    const disk_data = try std.fmt.allocPrint(arena, "{s}/tree-disk-data", .{context.scratch});
    std.Io.Dir.cwd().deleteTree(context.io, disk_data) catch {};
    const on_disk = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "2", "--data", disk_data, "--holders-on-disk", "--verify-holders",
    }));
    const disk_count = parse_branches(on_disk, &parallel);
    const disk_nodes = held_nodes(on_disk);
    const disk_replayed = replayed_nodes(on_disk);
    const disk_before = replayed_before_holders(on_disk);
    const disk_verified = std.mem.indexOf(u8, on_disk, "DIFFERENT") == null and
        std.mem.indexOf(u8, on_disk, "ns: the same") != null;
    const disk_left = try run_kept(context, &.{ "find", disk_data, "-path", "*/holders/*", "-type", "f" });
    expect_all(context, &.{
        .{ "64 timelines with holders on disk", disk_count == 64 },
        // The host's own disk below the holders' reserve (100 GB free) makes none: said so,
        // not taken for a holder bug (srv3 2026-10-29, 108 GB free beside a hunt's holders).
        .{ "the disk above the holders' reserve", std.mem.indexOf(u8, on_disk, "the disk keeps its reserve") == null },
        .{ "nodes loaded from disk", disk_nodes > 0 },
        // Every node from a holder, an earlier generation's timeline's too: kept on disk till the
        // run ends (holders.Registry.kept), not replayed from the setup snapshot (run 454's 30).
        // But for a moment before its parent's first holder: nothing nearer to start from (on
        // the taken-branch clock, a behavior 0.08 ms after the setup snapshot, check of
        // 2026-11-02).
        .{ "no node replayed from its parent's start but before its first holder", disk_replayed == disk_before },
        // A timeline whose node came from a disk holder saves its own against it (a diff).
        .{ "a timeline's first holder on disk saved against its origin", std.mem.indexOf(u8, on_disk, "saved against its origin") != null },
        .{ "each the one a replay makes (--verify-holders)", disk_verified },
        .{ "no holder file left once the run ended", disk_left.stdout.len == 0 },
    }, "tree: {d} nodes from holders on disk ({d} replayed from their parent's start, {d} before its first holder), each the one a replay makes; none left after", .{ disk_nodes, disk_replayed, disk_before });
    // The same, each written by the timeline's own process while it waits (what memory below the
    // reserve does: no writer's fork, whose copied pages there is no room for; run 1908's nodes
    // beside 40 Pulsar VMs were all replays): every node still the one a replay makes.
    const sync_data = try std.fmt.allocPrint(arena, "{s}/tree-disk-sync-data", .{context.scratch});
    std.Io.Dir.cwd().deleteTree(context.io, sync_data) catch {};
    const on_disk_sync = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "2", "--data", sync_data, "--holders-on-disk-sync", "--verify-holders",
    }));
    const sync_count = parse_branches(on_disk_sync, &parallel);
    const sync_nodes = held_nodes(on_disk_sync);
    const sync_verified = std.mem.indexOf(u8, on_disk_sync, "DIFFERENT") == null and
        std.mem.indexOf(u8, on_disk_sync, "ns: the same") != null;
    const sync_left = try run_kept(context, &.{ "find", sync_data, "-path", "*/holders/*", "-type", "f" });
    expect_all(context, &.{
        .{ "64 timelines with holders written in-process", sync_count == 64 },
        .{ "nodes loaded from in-process disk holders", sync_nodes > 0 },
        .{ "each the one a replay makes (--verify-holders)", sync_verified },
        .{ "no holder file left once the run ended", sync_left.stdout.len == 0 },
    }, "tree: {d} nodes from holders written in-process, each the one a replay makes; none left after", .{sync_nodes});
    // Holders in memory that leave (memory pressure, forced here) write themselves to disk first,
    // against the setup origin or their timeline's disk holder before them, and a return finding
    // one gone loads its file (Pulsar 1931 and 1932: nearly every return replayed, its holders
    // gone before the judgment): every such node the one a replay makes.
    const leave_data = try std.fmt.allocPrint(arena, "{s}/tree-leave-data", .{context.scratch});
    std.Io.Dir.cwd().deleteTree(context.io, leave_data) catch {};
    const left_run = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "2", "--data", leave_data, "--holders-leave", "--verify-holders",
    }));
    const leave_count = parse_branches(left_run, &parallel);
    const leave_nodes = held_nodes(left_run);
    const leave_verified = std.mem.indexOf(u8, left_run, "DIFFERENT") == null and
        std.mem.indexOf(u8, left_run, "ns: the same") != null;
    const leave_files = try run_kept(context, &.{ "find", leave_data, "-path", "*/holders/*", "-type", "f" });
    expect_all(context, &.{
        .{ "64 timelines with holders that leave", leave_count == 64 },
        .{ "nodes loaded from holders that left", leave_nodes > 0 },
        .{ "each the one a replay makes (--verify-holders)", leave_verified },
        .{ "no holder file left once the run ended", leave_files.stdout.len == 0 },
    }, "tree: {d} nodes from holders written to disk as they left, each the one a replay makes; none left after", .{leave_nodes});
    // A property's first failing timeline keeps its holders on disk (the ladder links them and
    // their bases into the run's snapshots), past the run's end that deletes the holders' own:
    // a bundle of the failure then replays from the nearest, not the whole timeline. Before,
    // a run with every holder on disk (a hunt beside another) kept none.
    const disk_failed = std.mem.indexOf(u8, on_disk, "FAIL \"") != null;
    const kept_states = try run_kept(context, &.{ "find", disk_data, "-path", "*/snapshots/layout-*/h*.state", "-type", "f" });
    const kept_markers = try run_kept(context, &.{ "grep", "-rl", "kept by the explorer", disk_data });
    const kept_whole = kept_whole: {
        // Every kept snapshot's chain of bases is there too (a load follows it).
        var lines = std.mem.tokenizeScalar(u8, kept_states.stdout, '\n');
        while (lines.next()) |path| {
            if (!snapshot_chain_whole(context, path)) break :kept_whole false;
        }
        break :kept_whole true;
    };
    expect_all(context, &.{
        .{ "the run failed a property (else nothing to keep)", disk_failed },
        .{ "its first failing timeline's holders kept on disk", kept_states.stdout.len > 0 },
        .{ "the marker serve reads, saying so", kept_markers.stdout.len > 0 },
        .{ "each kept snapshot's chain of bases whole", kept_whole },
    }, "tree: the first failure's holders on disk kept past the run's end ({d} bytes of names)", .{kept_states.stdout.len});
    if (!disk_verified or disk_nodes == 0) std.debug.print("{s}\n", .{lines_with(context.arena, on_disk, &.{
        "verify", "holder", "disk",
    }) catch ""});
    // Branch points: a timeline from a node starts with the injector told where the news came
    // from, and its first fault involves that node.
    const aim = try branches_aimed(context, tree_events, parallel[0..parallel_count]);
    expect_all(context, &.{
        .{ "timelines from nodes had branch points naming a node", aim.named > 0 },
        .{ "the fault after a named branch point involved its node", aim.aimed > 0 },
    }, "tree: {d} branch points named a node, the next fault involved it in {d}", .{ aim.named, aim.aimed });
    // With a strategy (overriding decisions): nodes replay their parents with their tapes, and
    // a deep timeline still replays alone, without the strategy.
    const strategy_tapes = try std.fmt.allocPrint(arena, "{s}/tree-strategy-tapes", .{
        context.scratch,
    });
    const strategy_record = try std.fmt.allocPrint(arena, "{s}/tree-strategy.jsonl", .{
        context.scratch,
    });
    const steered = try explore(context, &(common ++ [_][]const u8{
        "--jobs",     "2",            "--strategy", "python3 plugins/python/extremes.py",
        "--tape-dir", strategy_tapes, "--record",   strategy_record,
    }));
    var steered_branches: [branches_max]Branch = undefined;
    const steered_count = parse_branches(steered, &steered_branches);
    const steered_deep = try deepest_replays(
        context,
        program,
        strategy_record,
        strategy_tapes,
        steered_branches[0..steered_count],
        &.{"--no-cpu-modulation"},
    );
    expect_all(context, &.{
        .{ "64 timelines", steered_count == 64 },
        .{ "the tree deepens", steered_deep.depth >= 1 },
        .{ "the deepest replays alone from its tape", steered_deep.replays },
    }, "tree with a strategy: {d} timelines, up to {d} deep; #{?d} " ++
        "replays from its tape (its ancestors' decisions from theirs)", .{
        steered_count, steered_deep.depth, steered_deep.index,
    });
    // The explorer's own steering of the driver phase's length (Novelty: e2e otherwise runs
    // counted drivers, --drive-max none): its overrides in the tapes, and a deep timeline below
    // them replays alone. The tree once replayed parents from their seeds alone (rqlite's run
    // 427 parted 11 of 212 replays below steered timelines): every replay takes its tape now.
    const drive_tapes = try std.fmt.allocPrint(arena, "{s}/tree-drive-tapes", .{context.scratch});
    const drive_record = try std.fmt.allocPrint(arena, "{s}/tree-drive.jsonl", .{context.scratch});
    // Driver phases of up to 20 s: the steering and a deep tree, in minutes (2 m took 40). The
    // steering trusts a run's first minute once 5 minutes of it are explored, every judgment
    // halving what came before: with bank's timelines of about 6 s, a generation of 16 explores
    // about 96 s, and the sum never gets there (64 and 128 timelines, none steered, 2026-11-02).
    // Generations of 48 do after their second judgment.
    var steered_common = common;
    steered_common[7] = "128";
    const drive_options = [_][]const u8{ "--no-cpu-modulation", "--drive-max", "20s" };
    const driven = try explore(context, &(steered_common ++ drive_options ++ [_][]const u8{
        "--generation", "48", "--jobs", "4", "--tape-dir", drive_tapes, "--record", drive_record,
    }));
    var driven_branches: [2 * branches_max]Branch = undefined;
    const driven_count = parse_branches(driven, &driven_branches);
    const driven_deep = try deepest_replays(context, program, drive_record, drive_tapes, driven_branches[0..driven_count], &drive_options);
    const steered_tapes = try run_kept(context, &.{ "grep", "-rlF", "the run's novelty curve", drive_tapes });
    const steered_tape_count = std.mem.count(u8, steered_tapes.stdout, "\n");
    expect_all(context, &.{
        .{ "128 timelines, their driver phases drawn", driven_count == 128 },
        .{ "the explorer steered some (its overrides in their tapes)", steered_tape_count > 0 },
        .{ "the tree deepens", driven_deep.depth >= 1 },
        .{ "the deepest replays alone from its tape", driven_deep.replays },
    }, "tree with steered driver phases: {d} timelines, {d} steered, up to {d} deep; #{?d} " ++
        "replays from its tape", .{ driven_count, steered_tape_count, driven_deep.depth, driven_deep.index });
    // A strategy that only chooses where the tree returns ("decides": false) keeps in-run
    // snapshots, whose holders must not keep its plugin's pipes: a timeline stopping its plugin
    // at its end then waited forever (a Tetris tree, srv3 2026-10-29). Under `timeout`, a hang is
    // this check's failure, named, not the suite's.
    const returns_tapes = try std.fmt.allocPrint(arena, "{s}/tree-returns-tapes", .{context.scratch});
    const returns_record = try std.fmt.allocPrint(arena, "{s}/tree-returns.jsonl", .{context.scratch});
    var returns_argv: std.ArrayList([]const u8) = .empty;
    try returns_argv.appendSlice(arena, &.{ "timeout", "600", context.determinismo, "explore" });
    try returns_argv.appendSlice(arena, context.machine);
    try returns_argv.appendSlice(arena, &(common ++ [_][]const u8{
        "--jobs",     "2",           "--strategy", "python3 plugins/python/tree_rarity.py",
        "--tape-dir", returns_tapes, "--record",   returns_record,
    }));
    const returned = try run_kept(context, returns_argv.items);
    const returned_output = try std.mem.concat(arena, u8, &.{ returned.stdout, returned.stderr });
    var returned_branches: [branches_max]Branch = undefined;
    const returned_count = parse_branches(returned_output, &returned_branches);
    const returned_ended = switch (returned.term) {
        .exited => |code| code == 0 or code == 3,
        else => false,
    };
    expect_all(context, &.{
        .{ "the run ends (within timeout's 600 s)", returned_ended },
        .{ "64 timelines", returned_count == 64 },
        .{ "in-run snapshots made nodes", holders_made(returned_output) },
    }, "tree with a strategy choosing only its returns: {d} timelines, its holders kept", .{
        returned_count,
    });
    // With CPU modulation: holders keep the modulated timelines as they were, their nodes are
    // the ones a replay makes, and a deep timeline replays alone.
    const modulated_tapes = try std.fmt.allocPrint(arena, "{s}/tree-modulated-tapes", .{
        context.scratch,
    });
    const modulated_record = try std.fmt.allocPrint(arena, "{s}/tree-modulated.jsonl", .{
        context.scratch,
    });
    const modulated = try explore(context, &(common ++ [_][]const u8{
        "--jobs",     "2",             "--cpu-modulation", "--verify-holders",
        "--tape-dir", modulated_tapes, "--record",         modulated_record,
    }));
    var modulated_branches: [branches_max]Branch = undefined;
    const modulated_count = parse_branches(modulated, &modulated_branches);
    const modulated_deep = try deepest_replays(
        context,
        program,
        modulated_record,
        modulated_tapes,
        modulated_branches[0..modulated_count],
        &.{"--cpu-modulation"},
    );
    const modulated_verified = holders_verified(modulated);
    expect_all(context, &.{
        .{ "64 timelines", modulated_count == 64 },
        .{ "the tree deepens", modulated_deep.depth >= 1 },
        .{ "the deepest replays alone from its tape", modulated_deep.replays },
        .{ "in-run snapshots made nodes", holders_made(modulated) },
        .{ "each such node is the one a replay makes", modulated_verified },
    }, "tree with cpu modulation: {d} timelines, up to {d} deep; " ++
        "#{?d} replays alone from its tape; {d} nodes from in-run snapshots, each the one a " ++
        "replay makes", .{
        modulated_count, modulated_deep.depth, modulated_deep.index, held_nodes(modulated),
    });
    if (!modulated_verified) std.debug.print("{s}\n", .{lines_with(arena, modulated, &.{
        "verify",
    }) catch ""});
}

/// The tree's nodes made from in-run snapshots, over its generations ("(n from holders in
/// memory, m from holders on disk, ..." in each generation's line).
/// Whether in-run snapshots made nodes, or the run said memory stopped them (holders need
/// 16 GB available, holders.zig's make_available_min: a hunt beside the check may hold the rest).
fn holders_made(report: []const u8) bool {
    if (held_nodes(report) > 0) return true;
    const short = std.mem.indexOf(u8, report, "holders: none made") != null;
    if (short) std.debug.print("SKIP tree: nodes from in-run snapshots (memory stopped them)\n", .{});
    return short;
}

/// Whether each node an in-run snapshot made is the one a replay makes (--verify-holders):
/// one at least compared, none different; none to compare when memory stopped them.
fn holders_verified(report: []const u8) bool {
    if (std.mem.indexOf(u8, report, "DIFFERENT") != null) return false;
    if (std.mem.indexOf(u8, report, "ns: the same") != null) return true;
    return held_nodes(report) == 0 and std.mem.indexOf(u8, report, "holders: none made") != null;
}

fn held_nodes(report: []const u8) u64 {
    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const end = std.mem.indexOf(u8, line, " from holders in memory, ") orelse continue;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], '(') orelse continue) + 1;
        total += std.fmt.parseInt(u64, line[start..end], 10) catch 0;
        const disk_start = end + " from holders in memory, ".len;
        const disk_end = std.mem.indexOfPos(u8, line, disk_start, " from holders on disk") orelse continue;
        total += std.fmt.parseInt(u64, line[disk_start..disk_end], 10) catch 0;
    }
    return total;
}

/// The tree's nodes replayed from their parent's start, over its generations ("k replayed from
/// the parent's start" in each generation's line).
fn replayed_nodes(report: []const u8) u64 {
    return count_before(report, " replayed from the parent's start");
}

/// Of those, the ones for a moment before the parent's first holder (it had later ones): nothing
/// nearer to start from, by design.
fn replayed_before_holders(report: []const u8) u64 {
    return count_before(report, " of them before its first holder");
}

/// The sum, over the report's lines, of the number just before `text`.
fn count_before(report: []const u8, comptime text: []const u8) u64 {
    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const end = std.mem.indexOf(u8, line, text) orelse continue;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse continue) + 1;
        total += std.fmt.parseInt(u64, line[start..end], 10) catch 0;
    }
    return total;
}

/// The deepest timeline of a tree exploration (from its record), and whether it replays alone
/// from its tape with the events it had.
fn deepest_replays(
    context: *Context,
    program: []const u8,
    record: []const u8,
    tapes: []const u8,
    explored: []const Branch,
    /// The exploration's options a replay needs too (they are in its inputs).
    options: []const []const u8,
) !struct { index: ?u32, depth: usize, replays: bool } {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const lines = cwd.readFileAlloc(context.io, record, arena, .limited(1 << 24)) catch "";
    var deepest: ?u32 = null;
    var depth_max: usize = 0;
    var records = std.mem.tokenizeScalar(u8, lines, '\n');
    while (records.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const Step = struct { branch: u32 };
        const Line = struct { branch: struct { index: u32, path: []const Step } };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (parsed.branch.path.len <= depth_max) continue;
        depth_max = parsed.branch.path.len;
        deepest = parsed.branch.index;
    }
    const index = deepest orelse return .{ .index = null, .depth = 0, .replays = false };
    const tape = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--tape", tape };
    const argv = try std.mem.concat(arena, []const u8, &.{ &system, options });
    const replay = try explore(context, argv);
    var replayed: [1]Branch = undefined;
    const original = for (explored) |branch| {
        if (branch.index == index) break branch;
    } else null;
    const replays = original != null and parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, original.?.events_hash);
    return .{ .index = index, .depth = depth_max, .replays = replays };
}

/// Faults a scenario asks for (sdk.fault, det-faults inject): a pause, a graceful stop and a
/// one-way partition each take the node away and give it back, in every timeline.
fn check_inject(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "injectable", "--scenario", "inject", "--seed", "1",
        "--branches", "2",
    });
    const clean = std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null;
    const came_and_went = std.mem.indexOf(u8, report, "injected faults came and went") != null;
    expect_all(context, &.{
        .{ "no failing properties", clean },
        .{ "the injected faults came and went", came_and_went },
    }, "inject: a pause, a stop and a one-way partition asked for by the scenario take the node " ++
        "away and give it back; a clock skew moves its realtime clock alone, deadlines kept", .{});
    if (!clean or !came_and_went) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_inject_refused", "fault_failed",
    }) catch ""});
}

/// Faults aimed at a node (sdk.fault_aim): the aim reaches the injector, each draw then decides
/// whether to aim (`fault.aim`), and about half do (`fault.aimed`, drawn only then). Each aimed
/// fault is on the node aimed at when it was drawn (the timeline's last faults_aim before it), and
/// aiming raises each node's rate of faults per virtual second it is free to take one (a node
/// holds one fault at a time). Not the totals: while an aimed pause holds the witness the drawn
/// faults fall on echo, and pauses of a fat-tailed length (cf24ffd) tied them (130 against 131,
/// 2026-11-10).
fn check_aim(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "aim-events" });
    // The fixed injector (--no-swarm): aiming is judged by how many draws aim, which a regime
    // of rare faults (a mean gap up to 25.6 s) would leave too few of in these short timelines.
    _ = try explore(context, &.{
        "--program",  program, "--profile",    "aimable", "--scenario", "aim", "--seed", "1",
        "--branches", "4",     "--events-dir", events,    "--no-swarm",
    });
    const aims = try query_count(context, &.{ events, "event=faults_aim details.node=witness" });
    // Each fault says why it was drawn (`why`): decisions' announcements are not logged (a fifth
    // of a Raft run's events, run 1381), so a fault's own field tells an aimed one.
    const decided = try query_count(context, &.{ events, "event=fault" });
    const aimed = try query_count(context, &.{ events, "event=fault details.why=aimed" });
    const witness = try query_count(context, &.{ events, "event=fault details.node=witness" });
    const echo = try query_count(context, &.{ events, "event=fault details.node=echo" });
    const aim_events = try query_events(context, events, "event=faults_aim");
    const fault_events = try query_events(context, events, "event=fault");
    const judged = aim_judge(aim_events, fault_events);
    const moved = try query_count(context, &.{
        events, "assert.message=\"the aimed node moved (a leader or primary changed)\" assert.condition=true",
    });
    // det-init's CPU time of each node at a timeline's end (efficiency: CPU by node).
    const cpu = try query_count(context, &.{ events, "event=node_cpu" });
    expect_all(context, &.{
        .{ "the aim reached the injector in all 4 timelines", aims == 4 },
        .{ "its move (echo, then witness) marked in all 4", moved == 4 },
        .{ "each node's CPU time reported at each timeline's end", cpu == 8 },
        .{ "faults were drawn", decided >= 20 },
        .{ "about half aimed (once the aim arrived)", aimed * 10 >= decided * 2 and aimed * 10 <= decided * 6 },
        .{ "each aimed fault on the node aimed at as it was drawn", judged.aimed == aimed and judged.mismatched == 0 },
        .{ "the witness's rate higher while aimed at", judged.witness.raised() },
        .{ "the echo node's rate higher while aimed at", judged.echo.raised() },
    }, "aim: {d} of {d} faults aimed, {d} on another node than the aim's; {d} pauses of the " ++
        "witness, {d} of the echo node; per free virtual second, aimed at or not: witness " ++
        "{d}/{d} ms against {d}/{d} ms, echo {d}/{d} ms against {d}/{d} ms", .{
        aimed,                          decided,                     judged.mismatched,
        witness,                        echo,                        judged.witness.faults_aimed,
        judged.witness.free_aimed_ms(), judged.witness.faults_other, judged.witness.free_other_ms(),
        judged.echo.faults_aimed,       judged.echo.free_aimed_ms(), judged.echo.faults_other,
        judged.echo.free_other_ms(),
    });
}

/// An event `determinismo query` printed: `branch <n> vtime <s>s  <json>  (...)`.
const QueriedEvent = struct {
    branch: u32,
    vtime_ns: u64,
    node: []const u8,
    why: []const u8,
    duration_ns: u64,
};

/// The events `determinismo query` finds, in its order (by timeline, then moment).
fn query_events(context: *Context, events: []const u8, condition: []const u8) ![]QueriedEvent {
    const result = try run_kept(context, &.{ context.determinismo, "query", events, condition });
    const Details = struct { node: []const u8 = "", why: []const u8 = "", duration_ns: u64 = 0 };
    const Json = struct { details: Details = .{} };
    var found: std.ArrayList(QueriedEvent) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "branch ")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next(); // "branch"
        const branch = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        _ = words.next(); // "vtime"
        const seconds = words.next() orelse continue;
        const vtime_s = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, seconds, "s")) catch continue;
        const json_start = std.mem.indexOfScalar(u8, line, '{') orelse continue;
        const json_end = std.mem.lastIndexOf(u8, line, "}  (") orelse continue;
        const json = std.json.parseFromSliceLeaky(Json, context.arena, line[json_start .. json_end + 1], .{
            .ignore_unknown_fields = true,
        }) catch continue;
        try found.append(context.arena, .{
            .branch = branch,
            .vtime_ns = @intFromFloat(vtime_s * std.time.ns_per_s),
            .node = json.details.node,
            .why = json.details.why,
            .duration_ns = json.details.duration_ns,
        });
    }
    return found.items;
}

/// A node's faults and free virtual time, while aimed at and while not (from the first aim on).
const AimRate = struct {
    faults_aimed: u64 = 0,
    free_aimed_ns: u64 = 0,
    faults_other: u64 = 0,
    free_other_ns: u64 = 0,

    /// More faults per free second while aimed at than while not.
    fn raised(rate: AimRate) bool {
        if (rate.free_aimed_ns == 0 or rate.free_other_ns == 0) return false;
        return @as(u128, rate.faults_aimed) * rate.free_other_ns > @as(u128, rate.faults_other) * rate.free_aimed_ns;
    }
    fn free_aimed_ms(rate: AimRate) u64 {
        return rate.free_aimed_ns / std.time.ns_per_ms;
    }
    fn free_other_ms(rate: AimRate) u64 {
        return rate.free_other_ns / std.time.ns_per_ms;
    }
};

const AimJudged = struct { aimed: u64 = 0, mismatched: u64 = 0, witness: AimRate = .{}, echo: AimRate = .{} };

/// check_aim's judgment of each timeline: its aims (faults_aim, in order) cut it into stretches,
/// each aimed at one node; a node's free time in a stretch is the stretch less its faults'
/// durations within it; the timeline ends at its last fault.
fn aim_judge(aims: []const QueriedEvent, faults: []const QueriedEvent) AimJudged {
    var judged: AimJudged = .{};
    var branch: u32 = 0;
    while (branch < 64) : (branch += 1) {
        var end_ns: u64 = 0;
        for (faults) |fault| {
            if (fault.branch == branch) end_ns = @max(end_ns, fault.vtime_ns);
        }
        for (faults) |fault| {
            if (fault.branch != branch or !std.mem.eql(u8, fault.why, "aimed")) continue;
            judged.aimed += 1;
            const aim = aim_at(aims, branch, fault.vtime_ns) orelse "";
            if (!std.mem.eql(u8, aim, fault.node)) judged.mismatched += 1;
        }
        for (aims, 0..) |aim, index| {
            if (aim.branch != branch) continue;
            const next = if (index + 1 < aims.len and aims[index + 1].branch == branch) aims[index + 1].vtime_ns else end_ns;
            if (next <= aim.vtime_ns) continue;
            for ([_][]const u8{ "witness", "echo" }) |node| {
                const rate = if (std.mem.eql(u8, node, "witness")) &judged.witness else &judged.echo;
                var busy_ns: u64 = 0;
                var count: u64 = 0;
                for (faults) |fault| {
                    if (fault.branch != branch or !std.mem.eql(u8, fault.node, node)) continue;
                    if (fault.vtime_ns >= aim.vtime_ns and fault.vtime_ns < next) count += 1;
                    const from = @max(fault.vtime_ns, aim.vtime_ns);
                    const to = @min(fault.vtime_ns + fault.duration_ns, next);
                    if (to > from) busy_ns += to - from;
                }
                const free_ns = (next - aim.vtime_ns) -| busy_ns;
                if (std.mem.eql(u8, aim.node, node)) {
                    rate.faults_aimed += count;
                    rate.free_aimed_ns += free_ns;
                } else {
                    rate.faults_other += count;
                    rate.free_other_ns += free_ns;
                }
            }
        }
    }
    return judged;
}

/// The node aimed at in the timeline at that moment: its last aim at or before it.
fn aim_at(aims: []const QueriedEvent, branch: u32, vtime_ns: u64) ?[]const u8 {
    var node: ?[]const u8 = null;
    for (aims) |aim| {
        if (aim.branch == branch and aim.vtime_ns <= vtime_ns) node = aim.node;
    }
    return node;
}

/// errno_trace's storms (docs/PLAN.md's O): with --trace-errno 0, a node's process failing open
/// 1,000 times with no pause is one `syscall_error_storm` (ENOENT, 2), and its failures past the
/// storm's 100 are not each an event; another failing close 50 times 50 ms apart (EBADF, 9) never
/// storms, each failure its event.
fn check_errno_storm(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "errno-storm-events" });
    _ = try explore(context, &.{
        "--program",     program, "--scenario",   "errno_storm", "--seed", "1", "--branches", "1",
        "--trace-errno", "0",     "--events-dir", events,
    });
    const storms_enoent = try query_count(context, &.{ events, "event=syscall_error_storm details.errno=2 details.task~det-selftest" });
    const storms_ebadf = try query_count(context, &.{ events, "event=syscall_error_storm details.errno=9" });
    const enoent = try query_count(context, &.{ events, "event=syscall_error details.errno=2 details.task~det-selftest" });
    const ebadf = try query_count(context, &.{ events, "event=syscall_error details.errno=9 details.task~det-selftest" });
    expect_all(context, &.{
        .{ "the tight loop is one storm", storms_enoent == 1 },
        .{ "its failures past the storm not each an event", enoent >= 99 and enoent <= 200 },
        .{ "the slow one never storms", storms_ebadf == 0 },
        .{ "its 50 failures each an event", ebadf == 50 },
    }, "errno-storm: ENOENT storms {d}, events {d}; EBADF storms {d}, events {d}", .{ storms_enoent, enoent, storms_ebadf, ebadf });
}

/// Crash states against ext4's (docs/PLAN.md): a small record removed, created again and appended,
/// never synced, a file synced after it, then power losses strict and partial (with the journal
/// committed and without), 30 rounds a timeline. Stock ext4 gives it back whole, empty or absent,
/// never its size in NULs (430 trials on srv4's kernel, 2026-11-08); a temporary directories' record
/// showed NULs after our partial power losses (run 1506).
fn check_record_power_loss(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "record-power-loss-events" });
    _ = try explore(context, &.{
        "--program",  program, "--profile",    "durable", "--scenario", "record_power_loss", "--seed", "1",
        "--branches", "4",     "--events-dir", events,
    });
    const message = "assert.message=\"a small record removed and appended again, never synced, comes back whole, empty or absent after a power loss\"";
    const judged = try query_count(context, &.{ events, message });
    const failed = try query_count(context, &.{ events, try std.fmt.allocPrint(context.arena, "{s} assert.condition=false", .{message}) });
    const partial = try query_count(context, &.{ events, "event=node_crash_partial" });
    // A cluster's node table's pattern beside it (a rename over the file, never synced).
    const conf_message = "assert.message=\"a file renamed over another, never synced, comes back whole, empty or absent after a power loss\"";
    const conf_judged = try query_count(context, &.{ events, conf_message });
    const conf_failed = try query_count(context, &.{ events, try std.fmt.allocPrint(context.arena, "{s} assert.condition=false", .{conf_message}) });
    expect_all(context, &.{
        .{ "the renamed file judged after each power loss", conf_judged >= 100 },
        .{ "the renamed file never in NULs, nor torn", conf_failed == 0 },
        .{ "the record judged after each power loss", judged >= 100 },
        .{ "partial power losses among them", partial >= 30 },
        .{ "never its size in NULs, nor torn", failed == 0 },
    }, "record-power-loss: {d} judged, {d} failed; renamed {d} judged, {d} failed; {d} partial power losses", .{ judged, failed, conf_judged, conf_failed, partial });
}

/// Aftershocks (faults.zig): a power loss again soon after a node started again, one start in
/// four, 200 ms to 12.8 s after it. Drawn faults over idle drivers on the two-node "durable"
/// profile, every kind kept (--no-swarm).
fn check_aftershock(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "aftershock-events" });
    _ = try explore(context, &.{
        "--program",  program, "--profile",  "durable", "--scenario",   "aftershock", "--seed",     "1",
        "--branches", "2",     "--timeline", "90s",     "--events-dir", events,       "--no-swarm",
    });
    const losses = try query_count(context, &.{ events, "event=fault details.kind=crash" });
    const aftershocks = try query_count(context, &.{ events, "event=fault details.why=aftershock" });
    const near = try query_count(context, &.{
        events, "event=fault details.why=aftershock", "--preceded-by", "event=node_start", "--within", "13",
    });
    // Asked for by persist_trace after a rename over unsynced data (`node_rename_unsynced`).
    const after_rename = try query_count(context, &.{
        events, "event=fault details.why=aftershock", "--preceded-by", "event=node_rename_unsynced", "--within", "13",
    });
    // Asks armed (`aftershock_armed`, cause asked): a drawn power loss coming first takes the same
    // unsynced data and expires an armed one, so where drawn ones came every second or two none
    // asked had fired (2026-11-08); the asks themselves are what persist_trace's renames make.
    const renames = try query_count(context, &.{ events, "event=node_rename_unsynced" });
    const armed_asked = try query_count(context, &.{ events, "event=aftershock_armed details.cause=asked" });
    // And after a node's start opened data written before it and never synced
    // (`node_open_unsynced`): the relied-on data a power loss then takes.
    const opens = try query_count(context, &.{ events, "event=node_open_unsynced" });
    const after_open = try query_count(context, &.{
        events, "event=fault details.why=aftershock", "--preceded-by", "event=node_open_unsynced", "--within", "13",
    });
    expect_all(context, &.{
        .{ "power losses were drawn", losses >= 8 },
        .{ "some came as aftershocks", aftershocks > 0 },
        .{ "each within 13 s of a node's start or an unsynced rename", near + after_rename >= aftershocks },
        .{ "unsynced renames ask for aftershocks, some armed", renames >= 4 and armed_asked > 0 },
        .{ "fewer than the starts", aftershocks * 2 <= losses },
    }, "aftershock: {d} of {d} power losses were aftershocks, {d} within 13 s of a start, {d} of an unsynced rename; {d} unsynced renames, {d} asks armed; {d} after one of {d} unsynced opens", .{
        aftershocks, losses, near, after_rename, renames, armed_asked, after_open, opens,
    });
}

/// A mutation campaign (determinismo mutate): of two mutants, the one that breaks the sums is
/// caught, the one in code nothing runs is not (shell has no line coverage: unnoticed).
fn check_mutate(context: *Context) !void {
    const arena = context.arena;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "mutate" });
    try argv.appendSlice(arena, context.machine);
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest-sum" });
    const out = try std.fmt.allocPrint(arena, "{s}/mutate", .{context.scratch});
    try argv.appendSlice(arena, &.{
        "--program",  program, "--scenario", "sum",                        "--seed", "1",
        "--branches", "4",     "--mutants",  "tests/mutate/mutants.jsonl", "--out",  out,
    });
    const result = try run_kept(context, argv.items);
    const caught = std.mem.indexOf(u8, result.stdout, "caught     sum subtracts") != null;
    const unnoticed = std.mem.indexOf(u8, result.stdout, "unnoticed  an unused function") != null;
    const counted = std.mem.indexOf(u8, result.stdout, "1 of 2 mutants caught") != null;
    expect_all(context, &.{
        .{ "the mutant that breaks the sums is caught", caught },
        .{ "the one in unused code goes unnoticed", unnoticed },
        .{ "1 of 2 mutants counted caught", counted },
    }, "mutate: the mutant that breaks the sums is caught, the one in unused code is not", .{});
    if (!(caught and unnoticed and counted)) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    }
}

/// Disk faults (Antithesis's restarts that keep synced changes, or lose all): a node writes
/// one file synced and one not; a crash keeps the first and loses the second, a wipe loses
/// both, in every timeline (and the timeline replays exactly). An outage takes both durable
/// nodes down at once, each keeping only what it synced.
fn check_disk(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--profile", "durable", "--scenario", "disk", "--seed", "1",
    };
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "disk-events" });
    std.Io.Dir.cwd().deleteTree(context.io, events) catch {};
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "3", "--events-dir", events }));
    const passes = has_lines(report, &.{
        "3 branches, 0 with failing properties",
        "PASS always                hit in    3/3 branches, failing in    0  a crash keeps what " ++
            "was synced and loses the rest",
        "PASS always                hit in    3/3 branches, failing in    0  writes a disk drops " ++
            "are synced, then gone after a crash",
        "PASS always                hit in    3/3 branches, failing in    0  a disk works again " ++
            "after its faults",
        "PASS always                hit in    3/3 branches, failing in    0  a node whose disk " ++
            "recorded errors starts again after a crash",
        "PASS always                hit in    3/3 branches, failing in    0  a node's start after " ++
            "a wipe is told how many times its disk was lost",
    });
    const outage_passes = has_lines(report, &.{
        "PASS always                hit in    3/3 branches, failing in    0  an outage takes its " ++
            "nodes down at once, each keeping only what it synced",
        "PASS always                hit in    3/3 branches, failing in    0  a kill outage takes " ++
            "its nodes down at once, each keeping even what it did not sync",
    });
    const outages = try query_count(context, &.{ events, "event=fault details.kind=outage" });
    // A power loss persisting part of what was not synced: some of its pages kept, others lost.
    const partial_passes = has_lines(report, &.{
        "PASS always                hit in    3/3 branches, failing in    0  a power loss persisting " ++
            "part of what was not synced keeps some pages",
        "PASS always                hit in    3/3 branches, failing in    0  a power loss persisting " ++
            "part of a fresh file keeps a prefix of it",
        "PASS always                hit in    3/3 branches, failing in    0  the guest writes back " ++
            "no page nobody synced",
    }) and has_prefix_line(report, "PASS sometimes", "a power loss persisting part of what was not " ++
        "synced loses others");
    const partials = try query_count(context, &.{ events, "event=node_crash_partial" });
    // What a power loss changed in a node's files, said at its next mount: the file it did not
    // sync, lost.
    const crash_files = try query_count(context, &.{ events, "event=node_crash_files" });
    // A file rewritten in place and never synced: whole, empty or absent after a power loss,
    // strict or partial (ext4's ordered mode), never zeros.
    const rewrite_passes = has_lines(report, &.{
        "PASS always                hit in    3/3 branches, failing in    0  a file rewritten in " ++
            "place and never synced comes back whole, empty or absent after a power loss",
    });
    // The persistence audit (guest/runtime/nodes.zig's unsynced_report, persist_trace.zig): the
    // node's files never synced listed at the setup's end, and its renames of files never synced,
    // by its own process at its first start and by a command gone at once (found by the path).
    const unsynced_files = try query_count(context, &.{ events, "event=node_unsynced_files" });
    const renamed = try query_count(context, &.{ events, "event=node_rename_unsynced details.name=/data/renamed" });
    const renamed_exec = try query_count(context, &.{ events, "event=node_rename_unsynced details.name=/data/renamed-exec" });
    // Its restart after a kill reading back the file its first start never synced.
    const relied = try query_count(context, &.{ events, "event=node_open_unsynced details.name=/data/relied" });
    // Its disk checked before each mount after a power loss, as a boot does (e2fsck -p).
    const checked = try query_count(context, &.{ events, "event=node_fsck details.mode=preen" });
    // A disk fault aimed at one file's blocks (CORDS): its reads corrupted, its neighbor's not.
    const aimed_passes = has_lines(report, &.{
        "PASS always                hit in    3/3 branches, failing in    0  a disk fault aimed at one " ++
            "file corrupts its reads alone, until it heals",
    });
    var branches: [3]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect_all(context, &.{
        .{ "every disk property passes in all 3 timelines", passes },
        .{ "the outages' properties (power losses, kills) pass in all 3 timelines", outage_passes },
        .{ "the outage is logged as one fault", outages > 0 },
        .{ "a partial power loss keeps some unsynced pages in all 3 timelines, of a fresh file a prefix, and loses others in some", partial_passes },
        .{ "a power loss's changes to a node's files are said at its next mount", crash_files > 0 },
        .{ "the partial power loss is logged with its pages", partials > 0 },
        .{ "a file rewritten in place comes back whole, empty or absent in all 3 timelines", rewrite_passes },
        .{ "the node's files never synced are listed at the setup's end", unsynced_files > 0 },
        .{ "a rename of a file never synced is said, by a running process and by one gone at once", renamed > 0 and renamed_exec > 0 },
        .{ "a restart reading data its node wrote before it and never synced is said", relied > 0 },
        .{ "a node's disk is checked before it is mounted again (e2fsck -p)", checked > 0 },
        .{ "a disk fault aimed at one file corrupts its reads alone in all 3 timelines", aimed_passes },
        .{ "a timeline replays exactly", same },
    }, "disk: a crash keeps what was synced and loses the rest, a wipe loses both; dropped " ++
        "writes vanish, refused ones fail, a slow disk is slow, and it works again; an outage " ++
        "takes two nodes down at once, each keeping what it synced; a timeline replays exactly", .{});
    // A delayed disk is waited for, not polled: Linux's dm-delay starts a kthread for a delay
    // under 50 ms ("dm-delay-flush-worker") that loops for as long as a bio is delayed, and the
    // disk baseline is 0 to 2 ms on every durable disk. A guest computed through every delayed
    // write and read no clock doing it: three quarters of an etcd timeline's exact stops
    // (guest/kernel/patches/0013). Each timeline at the moment its baseline is set: the delay
    // it drew, and the kernel's threads of that name.
    var delayed: u32 = 0;
    var polling: u32 = 0;
    for ([_][]const u8{ "0", "1", "2" }) |branch| {
        const looked = try explore(context, &(common ++ [_][]const u8{
            "--branch",                                                                                                                                                         branch, "--until", "event=disk_baseline", "--exec",
            // What it prints is not in what it is (the command's text is in the output too).
            "printf 'baseline-%s=%s polling-%s=%s.\n' ms \"$(cat /run/det/nodes/disk_baseline_ms)\" threads \"$(cat /proc/[0-9]*/comm 2>/dev/null | grep -c dm-delay-flush)\"",
        }));
        const baseline_at = std.mem.indexOf(u8, looked, "baseline-ms=") orelse continue;
        const said = looked[baseline_at + "baseline-ms=".len ..];
        if (said.len == 0 or said[0] < '1' or said[0] > '9') continue;
        delayed += 1;
        // Not said: not shown to be none.
        if (std.mem.indexOf(u8, said[0..@min(said.len, 40)], "polling-threads=0.") == null) polling += 1;
    }
    expect_all(context, &.{
        .{ "a timeline drew a delay", delayed > 0 },
        .{ "none of them has a polling thread", polling == 0 },
    }, "disk: a disk with a baseline delay is waited for, no kernel thread polling it ({d} of 3 timelines " ++
        "drew a delay, {d} with a dm-delay-flush thread)", .{ delayed, polling });
    // A node with a drawn flusher (a 1 s window: on, its disk synced every second, as a host's
    // flusher would; off, strict) keeps across a crash what it wrote unsynced once the flusher
    // synced it, and in some timelines its flusher stays off: the bug a strict disk shows.
    const windowed = try explore(context, &.{
        "--program", program, "--profile", "writeback", "--scenario", "writeback", "--seed", "1", "--branches", "16",
    });
    const flusher_passes = has_lines(windowed, &.{
        "PASS always                hit in   16/16 branches, failing in    0  a crash keeps what a node's flusher synced",
        "PASS always                hit in   16/16 branches, failing in    0  a node's start has a number drawn for it",
    }) and has_prefix_line(windowed, "PASS sometimes", "a node's flusher syncs a file written unsynced") and
        has_prefix_line(windowed, "PASS sometimes", "a node's flusher stays off as it writes unsynced");
    expect(context, flusher_passes and std.mem.indexOf(u8, windowed, "FAIL") == null, "disk: a node's drawn flusher: " ++
        "what it synced survives a crash, and some timelines have it off", .{});
    if (!passes or !outage_passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "fault_skipped", "fault_heal_failed", "fault_inject_refused", "det-nodes",
    }) catch ""});
}

/// Host checks (System.main's `.checks`): records a timeline's command made reach the program's
/// check on the host, in order and typed, as properties of the timeline; a replay agrees.
fn check_host_checks(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{ "--program", program, "--scenario", "records", "--seed", "1" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2" }));
    const properties = [_][]const u8{
        "a host check knows its scenario",
        "a host check gets every record",
        "a host check gets the records in order, as made",
        "host checks run to completion",
    };
    var lines: [properties.len + 1][]const u8 = undefined;
    lines[0] = "2 branches, 0 with failing properties";
    for (properties, lines[1..]) |property, *line| {
        line.* = try std.fmt.allocPrint(context.arena, "hit in    2/2 branches, failing in    0  {s}", .{property});
    }
    const passes = has_lines(report, &lines);
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect_all(context, &.{
        .{ "every host-check property passes in both timelines", passes },
        .{ "a replay agrees", same },
    }, "host checks: a timeline's records reach the program's check on the host, in order and " ++
        "typed, as properties; a replay agrees", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "check", "always",
    }) catch ""});
}

/// Faults at durability points (the guest module's): a stall holds a node's syncs; a crash at
/// a sync loses the write before it and keeps it just after; a timeline replays exactly.
fn check_durability(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--profile", "durable", "--scenario", "durability", "--seed", "1",
    };
    const events = try std.fmt.allocPrint(context.arena, "{s}/durability-events", .{context.scratch});
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2", "--events-dir", events }));
    // The kernel's console lines are events (source kernel: boot in the setup's, a power loss's
    // ext4 lines in a timeline's), and a timeline's events carry a checkpoint each second.
    var kernel_lines: u32 = 0;
    var checkpoints: u32 = 0;
    try events_plain(context, events);
    for ([_][]const u8{ "setup.jsonl", "branch-0.jsonl" }) |name| {
        const path = try std.fs.path.join(context.arena, &.{ events, name });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(1 << 28)) catch continue;
        kernel_lines += @intCast(std.mem.count(u8, text, "\"source\":\"kernel\""));
        if (std.mem.eql(u8, name, "branch-0.jsonl")) checkpoints += @intCast(std.mem.count(u8, text, "{\"checkpoint\":"));
    }
    // The commands its driver ran in the echo node, summed at each timeline's end (det-init's
    // exec_cpu events: CPU by command run in a node).
    const execs = try query_count(context, &.{
        events, "event=exec_cpu details.node=echo details.command=det-selftest-node",
    });
    expect_all(context, &.{
        .{ "the kernel's console lines are events", kernel_lines > 0 },
        .{ "a timeline's events carry checkpoints", checkpoints > 0 },
        .{ "the commands run in a node are summed at each timeline's end", execs == 2 },
    }, "events: {d} kernel lines, {d} checkpoints in timeline 0, {d} sums of commands run in " ++
        "the echo node", .{ kernel_lines, checkpoints, execs });
    const properties = [_][]const u8{
        "a sync stall holds a node's syncs, and they complete",
        "a crash just before a sync loses the write",
        "a crash just after a sync keeps the write",
        "a write crashed at its sync never returns",
        "after a crash at a durability point, the disk keeps what is synced next",
        "a node whose disk is full starts again after a power loss",
        "a node's disk has the inodes mkfs gives a disk of its size",
        "a file rewritten in place and synced keeps its content through a power loss",
        "a file rewritten in place and closed keeps its content through a power loss two journal commits later",
    };
    var lines: [properties.len + 1][]const u8 = undefined;
    lines[0] = "2 branches, 0 with failing properties";
    for (properties, lines[1..]) |property, *line| {
        line.* = try std.fmt.allocPrint(context.arena, "hit in    2/2 branches, failing in    0  {s}", .{property});
    }
    const passes = has_lines(report, &lines);
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect_all(context, &.{
        .{ "every durability property passes in both timelines", passes },
        .{ "a timeline replays exactly", same },
    }, "durability points: a stall holds a node's syncs; a crash just before a sync loses the " ++
        "write, just after keeps it, and the disk stores what is synced next; a timeline replays " ++
        "exactly", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "fault_inject_refused", "det-nodes", "always",
    }) catch ""});
}

/// The `interleave` fault: a race between a thread and the one it wakes, which the guest
/// kernel alone settles one way, goes both ways under it (the scheduler's choices drawn by the
/// guest module, guest/kernel/patches/0006), and a timeline replays exactly with them.
fn check_interleave(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--profile", "injectable", "--scenario", "interleave", "--seed", "1",
    };
    const events = try std.fmt.allocPrint(context.arena, "{s}/interleave-events", .{context.scratch});
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2", "--events-dir", events }));
    const properties = [_][]const u8{
        "the kernel alone lets a waker go on before the batch thread it woke",
        "under the interleave fault, a woken thread runs first about half the time",
    };
    var lines: [properties.len + 1][]const u8 = undefined;
    lines[0] = "2 branches, 0 with failing properties";
    for (properties, lines[1..]) |property, *line| {
        line.* = try std.fmt.allocPrint(context.arena, "hit in    2/2 branches, failing in    0  {s}", .{property});
    }
    const passes = has_lines(report, &lines);
    const interleaved = try query_count(context, &.{ events, "event=interleaved" });
    const idle = try query_count(context, &.{ events, "event=interleaved details.choices=0" });
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect_all(context, &.{
        .{ "the race goes one way alone and both ways under the fault, in both timelines", passes },
        .{ "each fault's end says how many choices it drew, never none", interleaved > 0 and idle == 0 },
        .{ "a timeline replays exactly", same },
    }, "interleavings: {d} faults ended, {d} with no choice drawn", .{ interleaved, idle });
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "fault_inject_refused", "races", "always",
    }) catch ""});
}

/// Thread pausing at the instrumentation's callbacks, in every language instrumented by
/// determinismo: the 64-thread race of examples/race (every thread between its check and its
/// increment), which interleavings at ticks never reach, found exploring blind, each language's
/// program failing as it fails (an abort, a panic, an uncaught exception, an exit).
fn check_pausing(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "race-test" });
    // Frequent: found in most timelines with pausing (run 281's C++ in 40% of a tree's); the
    // others' races are rare in 32 timelines (Zig 3, Java 9 finds in five minutes): their SDK's
    // pausing must draw, a find is reported but not required.
    const languages = [_]struct { profile: []const u8, memory_mib: []const u8, property: []const u8, frequent: bool }{
        .{ .profile = "instrumented", .memory_mib = "1024", .property = "no process crashes: race-instrumented", .frequent = true },
        .{ .profile = "zig", .memory_mib = "1024", .property = "no process crashes: race-zig", .frequent = false },
        .{ .profile = "rust", .memory_mib = "1024", .property = "no panics (Rust)", .frequent = true },
        .{ .profile = "go", .memory_mib = "1024", .property = "no panics (Go)", .frequent = true },
        .{ .profile = "java", .memory_mib = "2048", .property = "no uncaught exceptions (Java)", .frequent = false },
        .{ .profile = "python", .memory_mib = "1024", .property = "no unexpected container exits", .frequent = false },
        .{ .profile = "javascript", .memory_mib = "2048", .property = "no unexpected container exits", .frequent = false },
        // Not frequent: as Java's, Python's and JavaScript's, the race runs again and again in
        // one process, which draws a stretch every two seconds (about three in a timeline of
        // 1 to 10 s) where C++'s, Rust's and Go's start a process a run, each with its own
        // draw (hundreds a timeline). examples/race/README.md's blind runs: 6 finds in 1,479
        // timelines for .NET, 9 in 953 for Java, against 787 in 2,153 for C++. It was marked
        // frequent while the draws' count was read as 0 and the whole line red.
        .{ .profile = "dotnet", .memory_mib = "2048", .property = "no unexpected container exits", .frequent = false },
    };
    const timelines = 32;
    for (languages) |language| {
        const events = try std.fmt.allocPrint(arena, "{s}/pausing-{s}", .{ context.scratch, language.profile });
        const report = try explore(context, &.{
            "--program",    program, "--profile",  language.profile, "--scenario",   "race",
            "--seed",       "1",     "--branches", "32",             "--memory-mib", language.memory_mib,
            "--events-dir", events,
        });
        var branches: [timelines]Branch = undefined;
        const count = parse_branches(report, &branches);
        var failing: u32 = 0;
        for (branches[0..count]) |branch| failing += @intFromBool(branch.failing);
        const property_failing = failing_in(report, language.property) orelse 0;
        // The SDK's draws: a named decision at each stretch's first look, announced (not logged
        // since 41334b0) and counted by name in each timeline's `decisions_announced`.
        // In the timelines' own files, plain: an ended timeline's is compressed, and the grep
        // over the directory counted 0 draws in every language since it was (2026-11-17).
        try events_plain(context, events);
        const counted = try run_kept(context, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "grep -ho '\"thread pausing\":[0-9]*' {s}/branch-*.jsonl | cut -d: -f2 | paste -sd+ - | bc 2>/dev/null || echo 0", .{events}) });
        const draws = std.fmt.parseInt(u64, std.mem.trim(u8, counted.stdout, " \n"), 10) catch 0;
        expect_all(context, &.{
            .{ "every timeline explored", count == timelines },
            .{ "its SDK draws thread pausing", draws > 0 },
            .{ "a frequent race is found", !language.frequent or failing > 0 },
            .{ "it fails as the language's program does", failing == 0 or property_failing > 0 },
        }, "pausing ({s}): {d} draws; {d} of {d} timelines found the race, {d} failing \"{s}\"", .{
            language.profile, draws, failing, count, property_failing, language.property,
        });
    }
}

/// A node's coverage set narrows its instrumented code at run: the C++ race, its build
/// instrumented, explored with a set no edge is in reports no coverage and pauses no thread (the
/// race is never found: plain, it never was); so with `--coverage off` (every node's set
/// replaced: the instrumentation's cost measured); with no set, the same build reports its edges.
/// (Whether pausing finds the race is the `pausing` check's.)
fn check_coverage_set(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "race-test" });
    const cases = [_]struct { name: []const u8, profile: []const u8, off: bool }{
        .{ .name = "set", .profile = "instrumented", .off = false },
        .{ .name = "uncovered", .profile = "instrumented-uncovered", .off = false },
        .{ .name = "off", .profile = "instrumented", .off = true },
    };
    var counts: [cases.len]struct { coverage: u64, failing: u32 } = undefined;
    for (cases, &counts) |case, *count| {
        const events = try std.fmt.allocPrint(arena, "{s}/coverage-set-{s}", .{ context.scratch, case.name });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "--program",  program, "--profile",    case.profile, "--scenario", "race", "--seed", "1",
            "--branches", "32",    "--events-dir", events,
        });
        if (case.off) try argv.appendSlice(arena, &.{ "--coverage", "off" });
        const report = try explore(context, argv.items);
        count.coverage = try query_count(context, &.{ events, "event=coverage" });
        count.failing = failing_in(report, "no process crashes: race-instrumented") orelse 0;
    }
    expect_all(context, &.{
        .{ "the build reports coverage without a set", counts[0].coverage > 0 },
        .{ "the set leaves it all out", counts[1].coverage == 0 },
        .{ "--coverage off leaves it all out", counts[2].coverage == 0 },
        .{ "never found without pausing", counts[1].failing == 0 and counts[2].failing == 0 },
    }, "coverage set: {d} coverage events without a set, {d} with every file left out, {d} " ++
        "with --coverage off; the race found in {d}, {d} and {d} timelines", .{
        counts[0].coverage, counts[1].coverage, counts[2].coverage,
        counts[0].failing,  counts[1].failing,  counts[2].failing,
    });
}

/// In-run snapshots leave their timelines as they were: a tree of the Zig race (its holders and
/// in-run nodes; threads, timers and clock reads dense) with every timeline replayed, each the
/// same. A hold point on the clock read that was the timer's soft stop once moved the timer to
/// the next read in the original alone: 59 of 600 timelines parted from their replays (srv4,
/// 2026-10-31).
fn check_holds(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "race-test" });
    const record = try std.fs.path.join(arena, &.{ context.scratch, "holds-record.jsonl" });
    const tapes = try std.fs.path.join(arena, &.{ context.scratch, "holds-tapes" });
    const timelines = 192;
    const report = try explore(context, &.{
        "--program",  program, "--profile",        "zig", "--scenario", "race",
        "--seed",     "7",     "--branches",       "192", "--record",   record,
        "--tape-dir", tapes,   "--verify-replays", "100",
    });
    const property = "timelines replay to their recorded history";
    const line = for_line(report, property);
    const failing = failing_in(report, property);
    const hit = if (line) |text| hit_count(text) else 0;
    expect_all(context, &.{
        .{ "every timeline replayed", hit == timelines },
        .{ "every replay the same", failing != null and failing.? == 0 },
    }, "holds: {d} of {d} timelines replayed, {?d} parting from their record", .{ hit, timelines, failing });
}

/// A report's line for a property (ending with its message).
fn for_line(report: []const u8, message: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| if (property_line(line, message)) return line;
    return null;
}

/// Whether a report line is the property's: its message last, or followed by its example
/// ("failing in    1  no panics (Go)  (e.g. --branch 0)").
fn property_line(line: []const u8, message: []const u8) bool {
    if (std.mem.endsWith(u8, line, message)) return true;
    const at = std.mem.indexOf(u8, line, message) orelse return false;
    const after = line[at + message.len ..];
    // Then its example, its place in the code ("  at bank_test.zig:167 audit"), or both.
    return at >= 2 and std.mem.eql(u8, line[at - 2 .. at], "  ") and
        (std.mem.startsWith(u8, after, "  (e.g.") or std.mem.startsWith(u8, after, "  at "));
}

test property_line {
    try std.testing.expect(property_line("FAIL always  hit in 32/32 branches, failing in   11  no panics (Go)  (e.g. --branch 0)", "no panics (Go)"));
    try std.testing.expect(property_line("PASS always  hit in 32/32 branches, failing in    0  no panics (Go)", "no panics (Go)"));
    try std.testing.expect(!property_line("FAIL always  failing in 1  no panics (Go) twice  (e.g. --branch 0)", "no panics (Go)"));
    try std.testing.expect(property_line("PASS sometimes  hit in 8/8 branches, failing in    0  anytime audit ran  at bank_test.zig:168 audit", "anytime audit ran"));
}

/// The branches a property line says it was hit in ("hit in  192/192 branches").
fn hit_count(line: []const u8) u32 {
    const start = std.mem.indexOf(u8, line, "hit in ") orelse return 0;
    var numbers = std.mem.tokenizeAny(u8, line[start + "hit in ".len ..], " /");
    return std.fmt.parseInt(u32, numbers.next() orelse return 0, 10) catch 0;
}

/// `determinismo shrink` on bank's failure: from a failing timeline's script, the faults kept are
/// among the script's, the failure counts agree with the rule (the kept faults fail in at least
/// half as many timelines as the whole script, or none are kept and it fails as often without
/// any), and the shrunk script is one explore follows and fails with.
fn check_shrink(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank" };
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(try explore(context, &(common ++ [_][]const u8{ "--seed", "7", "--branches", "8" })), &branches);
    const failing = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else return expect(context, false, "shrink: a failing branch to start from", .{});
    const events = try std.fs.path.join(arena, &.{ context.scratch, "shrink-events.jsonl" });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--seed", "7", "--branch", try std.fmt.allocPrint(arena, "{d}", .{failing.index}), "--events", events,
    }));
    const extracted = try run_kept(context, &.{ context.determinismo, "script", events });
    const script_path = try std.fs.path.join(arena, &.{ context.scratch, "shrink-script.json" });
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script_path, .data = extracted.stdout });
    const shrunk_path = try std.fs.path.join(arena, &.{ context.scratch, "shrink-shrunk.json" });
    const property = "total balance is conserved";
    // The same machine as the explorations (its kernel, initrd, cache): without them the
    // shrinker explored another, where the bank never failed (chain7, 2026-11-01).
    var shrink_argv: std.ArrayList([]const u8) = .empty;
    try shrink_argv.appendSlice(arena, &.{ context.determinismo, "shrink" });
    try shrink_argv.appendSlice(arena, context.machine);
    try shrink_argv.appendSlice(arena, &.{
        "--program",   program, "--scenario", "bank",      "--script", script_path, "--property", property,
        "--timelines", "8",     "--out",      shrunk_path, "--json",
    });
    const shrunk = try run_kept(context, shrink_argv.items);
    const Shape = struct {
        shrink: struct {
            faults: u32,
            failing_whole: u32,
            failing_none: u32,
            failing_kept: u32,
            kept: []const std.json.Value,
            explorations: u32,
        },
    };
    const last = std.mem.trim(u8, shrunk.stdout[(std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, shrunk.stdout, "\n"), '\n') orelse 0)..], " \n");
    const parsed = std.json.parseFromSliceLeaky(Shape, arena, last, .{ .ignore_unknown_fields = true }) catch
        return expect(context, false, "shrink: a JSON result ({s})", .{last[0..@min(last.len, 200)]});
    const result = parsed.shrink;
    const needed = @max(1, (result.failing_whole + 1) / 2);
    const rule = if (result.kept.len == 0) result.failing_none >= needed else result.failing_kept >= needed;
    const shrunk_script = try std.Io.Dir.cwd().readFileAlloc(context.io, shrunk_path, arena, .limited(1 << 26));
    const followed = failing_count(try explore(context, &(common ++ [_][]const u8{
        "--seed", "1", "--branches", "8", "--branching", "flat", "--script", shrunk_path,
    })));
    expect_all(context, &.{
        .{ "the whole script fails", result.failing_whole > 0 },
        .{ "the faults kept are among the script's", result.kept.len <= result.faults },
        .{ "the counts agree with the rule", rule },
        .{ "the shrunk script is written", std.mem.indexOf(u8, shrunk_script, "\"faults\"") != null },
        .{ "explore follows it and fails", followed > 0 },
    }, "shrink: {d} of {d} faults kept, failing in {d}/8 with them, {d}/8 with all, {d}/8 with none ({d} explorations)", .{
        result.kept.len, result.faults, result.failing_kept, result.failing_whole, result.failing_none, result.explorations,
    });
}

/// In how many timelines a property failed, from its report line ("failing in    3  <message>").
fn failing_in(report: []const u8, message: []const u8) ?u32 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!property_line(line, message)) continue;
        const start = std.mem.indexOf(u8, line, "failing in ") orelse continue;
        var numbers = std.mem.tokenizeScalar(u8, line[start + "failing in ".len ..], ' ');
        return std.fmt.parseInt(u32, numbers.next() orelse continue, 10) catch continue;
    }
    return null;
}

/// An objective (sdk.optimize) leads the tree where chance does not: a streak of 24 coin flips,
/// out of reach in 256 timelines blind, reached optimized (the archive keeps the longest streak
/// yet and returns to it).
fn check_optimize(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    var won: [2]u64 = undefined;
    for ([_][]const u8{ "streak", "streak_blind" }, &won) |scenario, *count| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/{s}-events", .{ context.scratch, scenario });
        _ = try explore(context, &.{
            "--program",    program, "--scenario", scenario, "--seed", "1", "--branches", "256",
            "--events-dir", events,
        });
        count.* = try query_count(context, &.{ events, "event=streak_won" });
    }
    expect_all(context, &.{
        .{ "optimized, the streak is won", won[0] > 0 },
        .{ "blind, it is not", won[1] == 0 },
    }, "optimize: a streak of 24 won in {d} timelines optimized, {d} blind, of 256 each", .{ won[0], won[1] });
}

/// A spare node (schema `spare`): not started with the others; until a driver starts it, faults
/// find it not running and skip it (none applied to it), then it answers and faults reach it.
fn check_spare(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/spare-events", .{context.scratch});
    const report = try explore(context, &.{
        "--program",  program, "--profile",    "spare", "--scenario", "spare", "--seed", "1",
        "--branches", "2",     "--events-dir", events,
    });
    const started = try query_count(context, &.{ events, "event=node_start details.node=witness" });
    const answered = try query_count(context, &.{ events, "assert.message=\"the spare node started and answered\"" });
    const skipped = try query_count(context, &.{ events, "event=fault_skipped details.node=witness details.err=NotRunning" });
    const before = try query_count(context, &.{
        events, "event=fault details.node=witness", "--not-preceded-by", "event=node_start details.node=witness",
    });
    const after = try query_count(context, &.{ events, "event=fault details.node=witness" });
    const passed = std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null;
    expect_all(context, &.{
        .{ "the spare starts only when the driver starts it", started > 0 },
        .{ "it answers once started", answered > 0 },
        .{ "faults skip it while it is not running", skipped > 0 },
        .{ "no fault is applied to it before it starts", before == 0 },
        .{ "faults reach it once it runs", after > 0 },
        .{ "every property passes (no exit or fault failure)", passed },
    }, "spare: started by its driver in {d} timelines; {d} faults skipped before, {d} after", .{
        started, skipped, after,
    });
}

/// A `det:frozen` step: its command runs with the nodes and the runner's side frozen (held in a
/// cgroup of their own meanwhile), and the next step finds them back, running.
fn check_frozen_step(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const script = try std.fs.path.join(arena, &.{ context.scratch, "frozen-steps.txt" });
    const steps =
        \\det:frozen sh -c 'grep -h frozen /sys/fs/cgroup/det-held/cgroup.events /sys/fs/cgroup/nodes/cgroup.events | tr "\n" " "; [ -n "$(cat /sys/fs/cgroup/det-held/cgroup.procs)" ] && echo held'
        \\sh -c 'echo after $(wc -l < /sys/fs/cgroup/det-held/cgroup.procs) $(grep frozen /sys/fs/cgroup/nodes/cgroup.events)'
        \\
    ;
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = script, .data = steps });
    const report = try explore(context, &.{
        "--program",     program, "--scenario",    "steady", "--seed", "1", "--branch", "0",
        "--at-vtime-ms", "900",   "--exec-script", script,
    });
    // Its output in two events: the states, then "held".
    const frozen = std.mem.indexOf(u8, report, "\"text\":\"frozen 1 frozen 1 \"") != null and
        std.mem.indexOf(u8, report, "\"text\":\"held\\n\"") != null;
    const back = std.mem.indexOf(u8, report, "after 0 frozen 0") != null;
    expect_all(context, &.{
        .{ "under det:frozen, the runner's side and the nodes frozen", frozen },
        .{ "after it, nothing held and the nodes running", back },
    }, "frozen step: frozen {}, back {} ({d} outputs, {d} moments)", .{
        frozen, back, std.mem.count(u8, report, "exec_output"), std.mem.count(u8, report, "at moment"),
    });
}

/// A node whose process is stopped outlives the exit of the driver that started it: each node is
/// its own session, so the kernel's job control (an orphaned group with a stopped member gets
/// SIGHUP) never reaches it (dqlite run 746).
fn check_hangup(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/hangup-events", .{context.scratch});
    const report = try explore(context, &.{
        "--program",  program, "--profile",    "aimable", "--scenario", "hangup", "--seed", "1",
        "--branches", "1",     "--events-dir", events,
    });
    const answered = try query_count(context, &.{ events, "assert.message=\"a stopped node answered after its starter's exit\"" });
    const passed = std.mem.indexOf(u8, report, "1 branches, 0 with failing properties") != null;
    expect_all(context, &.{
        .{ "the stopped node answers once continued", answered > 0 },
        .{ "every property passes (no unexpected exit)", passed },
    }, "hangup: answered {d} times", .{answered});
}

/// A node frozen, killed and started again runs (its start thaws its cgroup): the start no
/// longer waits for good on a first process that never reached its program (dqlite run 746).
fn check_frozen_start(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/frozen-start-events", .{context.scratch});
    const report = try explore(context, &.{
        "--program",    program, "--scenario", "frozen_start", "--seed", "1", "--branches", "1",
        "--events-dir", events,
    });
    const answered = try query_count(context, &.{ events, "assert.message=\"a node started while frozen ran and answered\"" });
    const passed = std.mem.indexOf(u8, report, "1 branches, 0 with failing properties") != null;
    expect_all(context, &.{
        .{ "the node started while frozen answers", answered > 0 },
        .{ "every property passes", passed },
    }, "frozen start: answered {d} times", .{answered});
}

/// States from instrumented code (the JVM agent's enum transitions, SGFuzz's state variables)
/// guide the tree where line coverage cannot: the state maze's progress runs no new line, and is
/// solved when its stage is an enum field, never when the same progress is an int.
/// The state maze (tests/antithesis-compat/java): solved by the tree with the agent's state
/// transitions to return to, rarely without them. 1,024 timelines and a comparison, not one
/// seed's 256 and "never with an int": at 256 the enum's solved in two seeds of three and the
/// int's once by chance (2026-11-18, after a syscall more at each node start, 65ff0f7, moved every
/// moment and seed 1 from 25 solved to none); at 1,024, 91 and 15 against 0 and 0.
fn check_states(context: *Context) !void {
    var solved: [2]u64 = undefined;
    var transitions: u64 = 0;
    // The client's Ready declares its setup with our Java SDK (`{"lifecycle":"setup_complete"}`):
    // the composer sees it and starts the drivers then, not after its 300 s (sdk_setup_missing).
    var setup_missing: u64 = 0;
    for ([_][]const u8{ "state", "state_int" }, &solved) |scenario, *count| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/{s}-events", .{ context.scratch, scenario });
        _ = try explore(context, &.{
            "--compose",    "tests/antithesis-compat/java/compose.yaml", "--scenario", scenario,
            "--seed",       "1",                                         "--branches", "1024",
            "--events-dir", events,
        });
        count.* = try query_count(context, &.{ events, "assert.message=\"the state maze is never solved\" assert.condition=false" });
        if (std.mem.eql(u8, scenario, "state")) transitions = try query_count(context, &.{ events, "event=state" });
        setup_missing += try query_count(context, &.{ events, "event=sdk_setup_missing" });
    }
    expect_all(context, &.{
        .{ "the composer sees the client's setup declared by our Java SDK", setup_missing == 0 },
        .{ "the agent reports the stage's transitions", transitions > 0 },
        .{ "with its stage an enum, the maze is solved", solved[0] > 0 },
        .{ "with its stage an enum, in more timelines than with its progress an int", solved[0] > solved[1] },
    }, "states: the state maze solved in {d} timelines by its enum's transitions ({d} reported), {d} with an int, of 1024 each; the setup missed in {d}", .{
        solved[0], transitions, solved[1], setup_missing,
    });
}

/// A scenario's cap on nodes down at once (nodes_down_max): two nodes whose kills and power
/// losses overlap, uncapped, then capped at one: the cap turns faults away where a second node
/// would go down, and none is turned away without it. (Uncapped, two were down at once: Iggy's
/// trial run 1559.)
fn check_nodes_down(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    var skipped: [2]u64 = undefined;
    for ([_][]const u8{ "steady", "steady_single" }, &skipped) |scenario, *count| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/nodes-down-{s}-events", .{ context.scratch, scenario });
        _ = try explore(context, &.{
            "--program", program, "--profile",  "restarts", "--scenario", scenario,
            "--seed",    "1",     "--branches", "8",        "--no-swarm", "--events-dir",
            events,
        });
        count.* = try query_count(context, &.{ events, "event=fault_skipped details.err=NodesDownMax" });
    }
    expect_all(context, &.{
        .{ "uncapped, no fault is turned away for the cap", skipped[0] == 0 },
        .{ "capped at one, a fault that would take a second node down is turned away", skipped[1] > 0 },
    }, "nodes-down: {d} faults turned away at one node down, {d} uncapped", .{ skipped[1], skipped[0] });
}

/// A node's memory that only grows is an objective the tree climbs (jank's leak, hunt run 1569):
/// the selftest's echo node leaks 400 MiB and the objective reaches it; the steady scenario's
/// stays near its start.
fn check_memory_growth(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const objective = "optimize.message=\"a node's anonymous memory grows (MiB above its least)\"";
    var found: [2]u64 = undefined;
    for ([_][]const u8{ "leak", "steady" }, &found) |scenario, *count| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/memory-growth-{s}-events", .{ context.scratch, scenario });
        _ = try explore(context, &.{
            "--program",    program, "--scenario", scenario, "--seed", "1", "--branches", "4",
            "--events-dir", events,
        });
        count.* = try query_count(context, &.{ events, try std.fmt.allocPrint(context.arena, "{s} optimize.value>=200", .{objective}) });
    }
    expect_all(context, &.{
        .{ "a node leaking 400 MiB reaches 200 MiB of growth", found[0] > 0 },
        .{ "a steady node's never does", found[1] == 0 },
    }, "memory-growth: {d} samples past 200 MiB leaking, {d} steady", .{ found[0], found[1] });
}

/// The nodes' memory-growth objective where it pays (det-selftest's leak_climb, profile `climb`): a
/// leak each timeline adds to, under the node's limit in any one timeline, reaches the OOM killer
/// down a tree that climbs the objective, and seldom without it (`--no-memory-objective`). jank's
/// leak reached it within a timeline either way (runs 1912 and 1913: 10 kills each), which showed
/// nothing of the objective.
/// The leak is truly under the limit in one timeline (2 MiB a start, 63 starts at most: a
/// green of before, 106 against 76, counted timelines of 58 starts dying alone and the returns
/// near them, in either arm). What adds a path's leaks up is the objective's extension: a
/// timeline returned to the objective's best drives one more phase past where its parent
/// stopped (composer.zig's drive_again, answered by the explorer); without it a return ended
/// when its parent would and no tree reached the limit (0 against 0, 2026-11-17). One of the
/// killed timelines, a path of several phases, replays to its recorded history from its tape.
/// Trees of 160 timelines, ten generations: a path gains about 30 MiB a generation (the best of
/// a return's four branches) from a first generation's 50 to 60, so the limit is four or five
/// returns deep, and a tree of 96 has three or four (it reached 98 to 155 MiB, one kill in the
/// four seeds). With 160, twice on one host: 10, 25, 6, 23 and 14, 18, 19, 22 killed with the
/// objective, none without either time. The counts move from run to run (a tree takes fresh
/// timelines while a judgment is pending, as its workers' timing has it): the total is the claim.
fn check_memory_climb(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const property = "the kernel kills no process for lack of memory";
    // Over four seeds (the step was tuned on seed 1: one seed's margin may be its luck): the
    // objective's tree OOM-killed more often in all, and never less in one.
    const seeds = [_][]const u8{ "1", "2", "3", "4" };
    var killed: [seeds.len][2]f64 = undefined;
    var climbed: [seeds.len][]const u8 = undefined; // Each seed's tree with the objective.
    var tapes: [seeds.len][]const u8 = undefined;
    for (seeds, &killed, &climbed, &tapes) |seed, *pair, *report, *tape_directory| {
        tape_directory.* = try std.fmt.allocPrint(context.arena, "{s}/climb-tapes-{s}", .{ context.scratch, seed });
        for ([_]bool{ true, false }, pair) |on, *count| {
            const common = [_][]const u8{
                "--program",  program, "--profile",   "climb", "--scenario",   "leak_climb", "--seed", seed,
                "--branches", "160",   "--branching", "tree",  "--generation", "16",         "--jobs", "4",
            };
            const output = try explore(context, if (on)
                &(common ++ [_][]const u8{ "--tape-dir", tape_directory.* })
            else
                &(common ++ [_][]const u8{"--no-memory-objective"}));
            if (on) report.* = output;
            // "failing in    3  the kernel kills ...": the count padded.
            const line = try lines_with(context.arena, output, &.{property});
            const after = if (std.mem.indexOf(u8, line, "failing in")) |at| std.mem.trimStart(u8, line[at + "failing in".len ..], " ") else "";
            count.* = number_after(after, "") orelse 0;
        }
    }
    var on_total: f64 = 0;
    var off_total: f64 = 0;
    var never_less = true;
    var margins: std.ArrayList(u8) = .empty;
    for (seeds, killed) |seed, pair| {
        on_total += pair[0];
        off_total += pair[1];
        never_less = never_less and pair[0] >= pair[1];
        try margins.print(context.arena, " seed {s}: {d} against {d};", .{ seed, pair[0], pair[1] });
    }
    // A killed timeline of the first tree that has one: its line, its tape, its replay.
    var replayed_same = false;
    var replayed_index: u32 = 0;
    find: for (climbed, tapes) |report, tape_directory| {
        var lines = std.mem.tokenizeScalar(u8, report, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "[branch ") or std.mem.indexOf(u8, line, property) == null) continue;
            var one: [1]Branch = undefined;
            if (parse_branches(line, &one) != 1) continue;
            replayed_index = one[0].index;
            const tape = try std.fmt.allocPrint(context.arena, "{s}/branch-{d}.jsonl", .{ tape_directory, one[0].index });
            const replay = try explore(context, &.{ "--program", program, "--profile", "climb", "--scenario", "leak_climb", "--tape", tape });
            var again: [1]Branch = undefined;
            replayed_same = parse_branches(replay, &again) == 1 and std.mem.eql(u8, again[0].events_hash, one[0].events_hash);
            break :find;
        }
    }
    expect_all(context, &.{
        .{ "climbing the objective reaches the OOM killer", on_total > 0 },
        .{ "more often than without it, over the four seeds", on_total > off_total },
        .{ "and no less in any one", never_less },
        .{ "a killed timeline, its path several phases long, replays to its recorded history", replayed_same },
    }, "memory-climb: timelines OOM-killed with the objective against without (160 a tree):{s} {d} against {d} in all; timeline {d} replayed", .{
        margins.items, on_total, off_total, replayed_index,
    });
}

/// A scenario's quorum (schema.Scenario.quorum): faults leave a majority of its nodes up, linked and
/// reachable throughout, so a majority always answers the runner; without the cap the same faults
/// take a majority away at times.
fn check_quorum(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    var broken: [2]u64 = undefined;
    var skipped: [2]u64 = undefined;
    for ([_][]const u8{ "quorum", "quorum_free" }, &broken, &skipped) |scenario, *lost, *kept| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/{s}-events", .{ context.scratch, scenario });
        _ = try explore(context, &.{
            "--program", program, "--profile",  "quorum", "--scenario",   scenario,
            "--seed",    "1",     "--branches", "6",      "--events-dir", events,
        });
        lost.* = try query_count(context, &.{ events, "assert.message=\"a majority of the quorum answers the runner\" assert.condition=false" });
        kept.* = try query_count(context, &.{ events, "event=fault_skipped details.err=QuorumKept" });
    }
    expect_all(context, &.{
        .{ "with the quorum a majority always answered", broken[0] == 0 },
        .{ "faults that would have broken it were skipped", skipped[0] > 0 },
        .{ "without it the same faults took a majority away", broken[1] > 0 },
    }, "quorum: majority lost {d} times with the cap ({d} faults skipped), {d} without", .{ broken[0], skipped[0], broken[1] });
}

/// Knobs (schema.Knob): a start's drawn anew at each start, one of its choices replacing the
/// node's own entry; a run's the same in every node and kept across restarts; each said in a
/// node_knob event.
fn check_knobs(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/knobs-events", .{context.scratch});
    _ = try explore(context, &.{
        "--program", program, "--profile",  "knobs", "--scenario",   "knobs",
        "--seed",    "1",     "--branches", "4",     "--events-dir", events,
    });
    var broken: [3]u64 = undefined;
    for ([_][]const u8{
        "a run's knob is the same choice in every node",
        "a start's knob is one of its choices",
        "a run's knob is kept across restarts",
    }, &broken) |message, *count| {
        count.* = try query_count(context, &.{ events, try std.fmt.allocPrint(context.arena, "assert.message=\"{s}\" assert.condition=false", .{message}) });
    }
    const anew = try query_count(context, &.{ events, "assert.message=\"restarts drew a start's knob anew\" assert.condition=true" });
    const said = try query_count(context, &.{ events, "event=node_knob details.knob=mode" });
    expect_all(context, &.{
        .{ "a run's knob agreed in every node", broken[0] == 0 },
        .{ "a start's knob was one of its choices, the node's own entry replaced", broken[1] == 0 },
        .{ "a run's knob was kept across restarts", broken[2] == 0 },
        .{ "restarts drew a start's knob anew", anew > 0 },
        .{ "each draw was said", said > 0 },
    }, "knobs: broken {d}/{d}/{d}, drawn anew {d}, said {d}", .{ broken[0], broken[1], broken[2], anew, said });
}

/// A run's named draws (src/draws.zig) through serve, as determinismo.api reads them: the knobs
/// profile's run (each node's `knob.mode` drawn at every start, `knob.shared` once for the run)
/// in serve's store. Every timeline's `knob.mode` draws, its setup's and its own in the order
/// drawn, are the choices its node_knob events said; the run's knob one value in all; the
/// starts' draws not all the same. Then the same run with `knob.mode` fixed (`decide`, explore's
/// --decide): every start runs with that choice, each draw of it the fixed one, steered.
fn check_draws(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7889";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-draws" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .profile = "knobs", .scenario = "knobs", .seed = 1, .branches = 4 }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const sql = struct {
        fn ask(c: *Context, text: []const u8) []const u8 {
            return ask_run(c, 1, text);
        }
        fn ask_run(c: *Context, run: u32, text: []const u8) []const u8 {
            const body = std.fmt.allocPrint(c.arena, "{f}", .{std.json.fmt(.{ .sql = text }, .{})}) catch return "";
            const at = std.fmt.allocPrint(c.arena, "http://127.0.0.1:7889/runs/{d}/sql", .{run}) catch return "";
            return curl(c, &.{ "-X", "POST", "-d", body, at }) catch "";
        }
    };
    // Each timeline's knob.mode values in the order drawn, and its node_knob events' choices in
    // the order said, as one text a timeline.
    const drawn = sql.ask(context,
        \\SELECT timeline, string_agg(value::VARCHAR, ',' ORDER BY pull) AS seq
        \\FROM timeline_draws WHERE name = 'knob.mode' GROUP BY timeline ORDER BY timeline
    );
    const said = sql.ask(context,
        \\SELECT timeline, string_agg(event ->> '$.details.choice', ',' ORDER BY vtime_ns, seq) AS seq
        \\FROM timeline_events WHERE name = 'node_knob' AND event ->> '$.details.knob' = 'mode'
        \\GROUP BY timeline ORDER BY timeline
    );
    const shared = sql.ask(context,
        \\SELECT count(DISTINCT value) AS values, count(DISTINCT timeline) AS timelines
        \\FROM timeline_draws WHERE name = 'knob.shared'
    );
    const distinct = sql.ask(context, "SELECT count(DISTINCT value) AS values FROM timeline_draws WHERE name = 'knob.mode'");
    const Row = struct { timeline: u32 = 0, seq: []const u8 = "" };
    const drawn_rows = std.json.parseFromSliceLeaky([]const Row, arena, drawn, .{ .ignore_unknown_fields = true }) catch &.{};
    const said_rows = std.json.parseFromSliceLeaky([]const Row, arena, said, .{ .ignore_unknown_fields = true }) catch &.{};
    var same = drawn_rows.len == 4 and drawn_rows.len == said_rows.len;
    if (same) for (drawn_rows, said_rows) |a, b| {
        same = same and a.timeline == b.timeline and a.seq.len > 0 and std.mem.eql(u8, a.seq, b.seq);
    };
    const Shared = struct { values: u64 = 0, timelines: u64 = 0 };
    const shared_row = std.json.parseFromSliceLeaky([]const Shared, arena, shared, .{ .ignore_unknown_fields = true }) catch &.{};
    const Distinct = struct { values: u64 = 0 };
    const distinct_row = std.json.parseFromSliceLeaky([]const Distinct, arena, distinct, .{ .ignore_unknown_fields = true }) catch &.{};
    // The same run with knob.mode fixed at 1.
    const fixed_asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .profile = "knobs", .scenario = "knobs", .seed = 1, .branches = 2, .decide = "knob.mode=1" }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", fixed_asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/2"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const fixed = sql.ask_run(context, 2,
        \\SELECT count(*) AS draws, count(*) FILTER (WHERE drew = '1' AND overridden) AS fixed
        \\FROM timeline_draws WHERE name = 'knob.mode'
    );
    const fixed_said = sql.ask_run(context, 2,
        \\SELECT count(*) AS draws, count(*) FILTER (WHERE event ->> '$.details.choice' = '1') AS fixed
        \\FROM timeline_events WHERE name = 'node_knob' AND event ->> '$.details.knob' = 'mode'
    );
    const Fixed = struct { draws: u64 = 0, fixed: u64 = 0 };
    const fixed_row = std.json.parseFromSliceLeaky([]const Fixed, arena, fixed, .{ .ignore_unknown_fields = true }) catch &.{};
    const fixed_said_row = std.json.parseFromSliceLeaky([]const Fixed, arena, fixed_said, .{ .ignore_unknown_fields = true }) catch &.{};
    const all_fixed = fixed_row.len == 1 and fixed_row[0].draws > 0 and fixed_row[0].fixed == fixed_row[0].draws;
    const all_said = fixed_said_row.len == 1 and fixed_said_row[0].draws > 0 and fixed_said_row[0].fixed == fixed_said_row[0].draws;
    expect_all(context, &.{
        .{ "every timeline's knob.mode draws are its node_knob choices, in order", same },
        .{ "the run's knob, drawn once in the setup, one value in all four", shared_row.len == 1 and shared_row[0].values == 1 and shared_row[0].timelines == 4 },
        .{ "the starts' draws differ", distinct_row.len == 1 and distinct_row[0].values > 1 },
        .{ "with knob.mode fixed at 1, every draw of it is 1, steered", all_fixed },
        .{ "and every start ran with that choice", all_said },
    }, "draws: knob.mode {s}; node_knob {s}; knob.shared {s}; fixed {s} {s}", .{ std.mem.trim(u8, drawn, "\n"), std.mem.trim(u8, said, "\n"), std.mem.trim(u8, shared, "\n"), std.mem.trim(u8, fixed, "\n"), std.mem.trim(u8, fixed_said, "\n") });
}

/// Plans (`plan: true`): what a call would do, done nothing. A session's plan names the timeline
/// it would be, its moment and where its replay starts; nothing opens, and the session opened
/// after with the same request is that timeline. A run's plan names the last run like it and
/// what that one drew; nothing starts.
fn check_plan_calls(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7888";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve-plans" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const runs: []const u8 = curl(context, &.{url ++ "/runs"}) catch "";
        if (runs.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .profile = "knobs", .scenario = "knobs", .seed = 1, .branches = 2 }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs" });
    for (0..1200) |_| {
        const run: []const u8 = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) break;
        sleep_ms(500);
    }
    const Planned = struct { plan: bool = false, timeline: u32 = 0, at_vtime_ms: u64 = 0, from: []const u8 = "", replay_ms: u64 = 0 };
    const opening = "{\"branch\":0,\"until\":\"event=composer_start\"";
    const planned_text = curl(context, &.{ "-X", "POST", "-d", opening ++ ",\"plan\":true}", url ++ "/runs/1/session" }) catch "";
    const planned = std.json.parseFromSliceLeaky(Planned, arena, planned_text, .{ .ignore_unknown_fields = true }) catch Planned{};
    const sessions_after_plan = curl(context, &.{url ++ "/sessions"}) catch "";
    const Opened = struct { session: u32 = 0, timeline: ?u32 = null };
    const opened = std.json.parseFromSliceLeaky(Opened, arena, curl(context, &.{ "-X", "POST", "-d", opening ++ "}", url ++ "/runs/1/session" }) catch "{}", .{ .ignore_unknown_fields = true }) catch Opened{};
    _ = curl(context, &.{ "-X", "POST", "-d", "{}", try std.fmt.allocPrint(arena, url ++ "/sessions/{d}/end", .{opened.session}) }) catch "";
    // A run's plan: the same program and scenario, run 1 the one like it.
    const Like = struct { run: u32 = 0, timelines: u64 = 0 };
    const Set = struct { name: []const u8 = "" };
    const RunPlanned = struct { plan: bool = false, like: ?Like = null, timelines_expected: ?u64 = null, sets: []const Set = &.{} };
    const run_asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = program, .profile = "knobs", .scenario = "knobs", .branches = 3, .plan = true }, .{})});
    const run_planned_text = curl(context, &.{ "-X", "POST", "-d", run_asked, url ++ "/runs" }) catch "";
    const run_planned = std.json.parseFromSliceLeaky(RunPlanned, arena, run_planned_text, .{ .ignore_unknown_fields = true }) catch RunPlanned{};
    const runs_after = curl(context, &.{url ++ "/runs"}) catch "";
    var knob_set = false;
    for (run_planned.sets) |set| knob_set = knob_set or std.mem.eql(u8, set.name, "knob.mode");
    expect_all(context, &.{
        .{ "a session's plan names the timeline it would be, its moment and its replay", planned.plan and planned.timeline > 0 and planned.at_vtime_ms > 0 and planned.from.len > 0 },
        .{ "and opens nothing", std.mem.indexOf(u8, sessions_after_plan, "\"session\"") == null },
        .{ "the session opened after with the same request is that timeline", opened.timeline != null and opened.timeline.? == planned.timeline },
        .{ "a run's plan names the last run like it", run_planned.plan and run_planned.like != null and run_planned.like.?.run == 1 },
        .{ "with what that one drew (knob.mode among its sets) and as many timelines as asked", knob_set and run_planned.timelines_expected != null and run_planned.timelines_expected.? == 3 },
        .{ "and starts nothing", std.mem.indexOf(u8, runs_after, "\"id\":2") == null },
    }, "plans: session {s}; opened as {any}; run {s}", .{ std.mem.trim(u8, planned_text, "\n"), opened.timeline, run_planned_text[0..@min(run_planned_text.len, 300)] });
    // A run's plan carried out: bank's (configuration draws among its setups: the composer's
    // weights and parallelism), run 2 the one like it, whose configuration bandit the next run
    // starts warm from; run 3 with the plan's seed draws each first timeline's choices as
    // imagined, the bandit's answers among them.
    const bank = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const wait_ended = struct {
        fn wait(c: *Context, run_url: []const u8) void {
            for (0..1200) |_| {
                const run: []const u8 = curl(c, &.{run_url}) catch "";
                if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null and run.len > 0) return;
                sleep_ms(500);
            }
        }
    }.wait;
    // "coverage":"off" as the other checks that start the bank through serve: bank-test is not
    // instrumented, and serve's gate stopped these runs at their fourth timeline ("0 of 0
    // choices as imagined", 2026-11-18).
    const learning = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = bank, .scenario = "bank", .seed = 1, .branches = 4, .coverage = "off" }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", learning, url ++ "/runs" });
    wait_ended(context, url ++ "/runs/2");
    const Draw = struct { name: []const u8 = "", drew: []const u8 = "" };
    const Setup = struct { index: u32 = 0, draws: []const Draw = &.{} };
    const Imagined = struct { seed: u64 = 0, setups: []const Setup = &.{} };
    const bank_asked = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = bank, .scenario = "bank", .seed = 7, .branches = 4, .coverage = "off", .plan = true }, .{})});
    const bank_planned = curl(context, &.{ "-X", "POST", "-d", bank_asked, url ++ "/runs" }) catch "";
    const imagined = std.json.parseFromSliceLeaky(Imagined, arena, bank_planned, .{ .ignore_unknown_fields = true }) catch Imagined{};
    const executed = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .program = bank, .scenario = "bank", .seed = imagined.seed, .branches = 4, .coverage = "off" }, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", executed, url ++ "/runs" });
    wait_ended(context, url ++ "/runs/3");
    const first_draws = "{\"sql\":\"SELECT timeline, name, arg_min(drew, pull)::VARCHAR AS drew FROM timeline_draws WHERE part = 'own' GROUP BY timeline, name\"}";
    const Row = struct { timeline: u32 = 0, name: []const u8 = "", drew: ?[]const u8 = null };
    const rows = std.json.parseFromSliceLeaky([]const Row, arena, curl(context, &.{ "-X", "POST", "-d", first_draws, url ++ "/runs/3/sql" }) catch "[]", .{ .ignore_unknown_fields = true }) catch &.{};
    var choices: u32 = 0;
    var as_imagined: u32 = 0;
    var config_imagined = false;
    var parted: std.ArrayList(u8) = .empty;
    for (imagined.setups) |setup| for (setup.draws) |draw| {
        const drawn = for (rows) |row| {
            if (row.timeline == setup.index and std.mem.eql(u8, row.name, draw.name)) break row.drew;
        } else null;
        choices += 1;
        config_imagined = config_imagined or std.mem.startsWith(u8, draw.name, "composer.weight") or std.mem.eql(u8, draw.name, "composer.parallelism_log2");
        if (drawn != null and std.mem.eql(u8, drawn.?, draw.drew)) {
            as_imagined += 1;
        } else {
            try parted.print(arena, " {d}:{s} imagined {s} drew {s};", .{ setup.index, draw.name, draw.drew, drawn orelse "nothing" });
        }
    };
    expect_all(context, &.{
        .{ "its plan imagines its first timelines' setups, configuration draws among them", imagined.setups.len > 0 and choices > 0 and config_imagined },
        .{ "and the run started with its seed draws each choice as imagined", choices > 0 and as_imagined == choices },
    }, "plans carried out: {d} of {d} choices as imagined;{s}", .{ as_imagined, choices, parted.items });
}

/// A node upgraded to its next release and back (Node.upgrade, FoundationDB's restarting
/// tests): each time the other image's program runs, its data kept, the release it left not in
/// its root.
fn check_upgrade(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/upgrade-events", .{context.scratch});
    _ = try explore(context, &.{
        "--program", program, "--profile",  "upgrade", "--scenario",   "upgrade",
        "--seed",    "1",     "--branches", "2",       "--events-dir", events,
    });
    var held: [4]u64 = undefined;
    for ([_][]const u8{
        "an upgraded node runs its next release, its data kept",
        "an upgraded node's own release is not in its root",
        "a downgraded node runs its own release, its data kept",
        "a spare upgraded before its first start runs its next release",
    }, &held) |message, *count| {
        count.* = try query_count(context, &.{ events, try std.fmt.allocPrint(context.arena, "assert.message=\"{s}\" assert.condition=true", .{message}) });
    }
    const upgraded = try query_count(context, &.{ events, "event=node_upgrade details.to=next" });
    expect_all(context, &.{
        .{ "the node was upgraded", upgraded > 0 },
        .{ "its next release ran with its data", held[0] > 0 },
        .{ "its own release was gone meanwhile", held[1] > 0 },
        .{ "downgraded, its own ran with its data", held[2] > 0 },
        .{ "a spare upgraded before its first start ran its next release", held[3] > 0 },
    }, "upgrade: {d} upgrades, next with data {d}, own gone {d}, back with data {d}, spare {d}", .{ upgraded, held[0], held[1], held[2], held[3] });
}

/// A stop of a node whose process exited signals no process that took its PID since (Valkey's
/// run 1554: a `migrate` driver SIGTERMed by a stop of a dead node). The selftest's driver
/// kills the echo node's process, starts a child at its PID, and asks for the stop.
fn check_stale_pid(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fmt.allocPrint(context.arena, "{s}/stale-pid-events", .{context.scratch});
    _ = try explore(context, &.{
        "--program", program, "--profile",  "stale-pid", "--scenario",   "stale_pid",
        "--seed",    "1",     "--branches", "4",         "--events-dir", events,
    });
    // Hit (condition true), not the catalog's declaration of it (hit false).
    const held = try query_count(context, &.{ events, "assert.message=\"a child holds the PID of the echo node's exited process\" assert.condition=true" });
    const signalled = try query_count(context, &.{ events, "assert.message=\"a stop of a node signals none of another's processes\" assert.condition=false" });
    const refused = try query_count(context, &.{ events, "event=fault_skipped details.node=echo details.err=NotRunning" });
    expect_all(context, &.{
        .{ "a child took the PID of the node's exited process", held > 0 },
        .{ "the stop asked then signalled none of them", signalled == 0 },
        .{ "it was refused, the node not running", refused > 0 },
    }, "stale-pid: {d} children at a dead node's PID, {d} signalled, {d} stops refused", .{ held, signalled, refused });
}

/// Crash points on the JVM: a server whose role is an enum, under the Java agent, asks to crash at
/// its state transitions, and the injector crashes it there (one of its crash faults the swarm
/// keeps, `why: crash_point`), the server starting again.
fn check_crash_points(context: *Context) !void {
    const events = try std.fmt.allocPrint(context.arena, "{s}/crash-points-events", .{context.scratch});
    _ = try explore(context, &.{
        "--compose",    "tests/antithesis-compat/java/crash-points.yaml", "--scenario", "crash_points",
        "--seed",       "1",                                              "--branches", "16",
        "--events-dir", events,
    });
    const asked = try query_count(context, &.{ events, "event=crash_point" });
    const crashed = try query_count(context, &.{ events, "event=crash_point details.outcome=crashed" });
    const faults = try query_count(context, &.{ events, "event=fault details.why=crash_point" });
    const stores = try query_count(context, &.{ events, "event=crash_point details.point~StateServer.epoch" });
    const starts = try query_count(context, &.{ events, "event=node_start details.node=server" });
    // The SDK's explicit points (sdk.crash_point): the selftest's echo node marks one every 50 ms.
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const marked_events = try std.fmt.allocPrint(context.arena, "{s}/crash-points-sdk-events", .{context.scratch});
    _ = try explore(context, &.{
        "--program", program, "--profile",  "crash-points", "--scenario",   "steady",
        "--seed",    "1",     "--branches", "16",           "--events-dir", marked_events,
    });
    const marked = try query_count(context, &.{ marked_events, "event=crash_point details.point~selftest.loop details.outcome=crashed" });
    expect_all(context, &.{
        .{ "the agent asks for crashes at the server's state transitions", asked > stores },
        .{ "and at its epoch's stores (a meta-info field by its name)", stores > 0 },
        .{ "the injector crashes the server there", crashed > 0 and faults == crashed },
        .{ "the server starts again after them", starts > 16 },
        .{ "the SDK's own points (Zig: sdk.crash_point) crash their node too", marked > 0 },
    }, "crash-points: {d} asked ({d} at the epoch's stores), {d} crashed ({d} faults), the server started {d} times in 16 timelines; the SDK's points crashed the selftest's node {d} times", .{
        asked, stores, crashed, faults, starts, marked,
    });
}

/// Watches on the JVM (DETERMINISMO_WATCH): StateServer's epoch and role said at each store and
/// its step() at each call, as `watch` events with their values and object, the first 50 of each
/// then one "over"; the same seed's timelines say the same (their events' hashes equal: the
/// objects' identities too).
fn check_java_watch(context: *Context) !void {
    var hashes: [2][2]Branch = undefined;
    var counts: [6]u64 = undefined;
    for (0..2) |round| {
        const events = try std.fmt.allocPrint(context.arena, "{s}/java-watch-{d}-events", .{ context.scratch, round });
        const report = try explore(context, &.{
            "--compose",   "tests/antithesis-compat/java/watch.yaml", "--scenario",   "crash_points",
            "--seed",      "1",                                       "--branches",   "2",
            "--branching", "flat",                                    "--events-dir", events,
        });
        _ = parse_branches(report, &hashes[round]);
        if (round > 0) continue;
        counts = .{
            try query_count(context, &.{ events, "event=watch details.name~StateServer.epoch details.value=1" }),
            try query_count(context, &.{ events, "event=watch details.name~StateServer.role details.value=LEADER" }),
            try query_count(context, &.{ events, "event=watch details.name~StateServer.step details.object~StateServer@" }),
            try query_count(context, &.{ events, "event=watch details.name~StateServer.step details.over=50" }),
            try query_count(context, &.{ events, "event=watch details.name~StateServer.step" }),
            try query_count(context, &.{ events, "event=watch details.name~StateServer.work" }),
        };
    }
    const same = std.mem.eql(u8, hashes[0][0].events_hash, hashes[1][0].events_hash) and
        std.mem.eql(u8, hashes[0][1].events_hash, hashes[1][1].events_hash);
    expect_all(context, &.{
        .{ "the epoch's first store said with its value (1)", counts[0] > 0 },
        .{ "the role's stores said by the enum constant's name", counts[1] > 0 },
        .{ "step()'s calls said with their object", counts[2] > 0 },
        .{ "past 50 calls, one event says the rest are not said", counts[3] == 2 },
        .{ "so at most 51 step() events a timeline", counts[4] <= 2 * 51 },
        .{ "a field not watched says nothing", counts[5] == 0 },
        .{ "the same seed's timelines say the same (events' hashes)", same },
    }, "java-watch: epoch=1 {d}, LEADER {d}, step() with object {d}, over {d}, step() events {d}", .{ counts[0], counts[1], counts[2], counts[3], counts[4] });
}

/// A `sometimes` made true comes first among a timeline's new behaviors: the tree returns just
/// after it, and says so; with --no-prefer-sometimes it does not.
fn check_sought(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    var whys: [2]bool = undefined;
    for ([_]bool{ true, false }, &whys) |prefer, *said| {
        const record = try std.fmt.allocPrint(context.arena, "{s}/sought-{}.jsonl", .{ context.scratch, prefer });
        std.Io.Dir.cwd().deleteFile(context.io, record) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(context.arena, &.{
            "--program", program, "--scenario", "sought", "--seed", "1", "--branches", "64",
            "--record",  record,
        });
        if (!prefer) try argv.append(context.arena, "--no-prefer-sometimes");
        _ = try explore(context, argv.items);
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, record, context.arena, .limited(1 << 26)) catch "";
        said.* = std.mem.indexOf(u8, text, "a state the program marks worth reaching") != null and
            std.mem.indexOf(u8, text, "a marked state was reached") != null;
    }
    expect_all(context, &.{
        .{ "returns go just after the sometimes first, saying so", whys[0] },
        .{ "without --prefer-sometimes, none says so", !whys[1] },
    }, "sought: the tree returns just after a sometimes made true first, saying why", .{});
}

/// The bank's scenario bank_steps says each step as an event (bank_read, bank_commit,
/// bank_reject, bank_audit), a step at Redis and its event under one lock: a timeline's events
/// are its steps in the order Redis took them, the trace a spec is checked against (determinismo
/// quint). Each timeline's events are run here against the bank they describe: a read must see
/// the balances the commits before it left, a commit write what its read gave it, an audit list
/// them. Without the lock a client that has Redis's reply says so only when it runs again,
/// after others' steps: the 61st event of a timeline was a read of what a commit said after it
/// had written (2026-11-17). The bug is in the trace too: some commit writes from a stale read.
fn check_bank_steps(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "bank-steps-events" });
    std.Io.Dir.cwd().deleteTree(context.io, events) catch {};
    const report = try explore(context, &.{
        "--program",   program, "--scenario", "bank_steps", "--seed",       "1",    "--branches", "4",
        "--branching", "flat",  "--timeline", "8s",         "--events-dir", events,
    });
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    try events_plain(context, events);
    const account_count = 4;
    const Read = struct { client: i64, source: usize, target: usize, source_balance: i64, target_balance: i64 };
    var steps: u64 = 0;
    var misfits: u64 = 0;
    var stale: u64 = 0;
    var misfit_first: []const u8 = "";
    for (0..4) |index| {
        const path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ events, index });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 28)) catch continue;
        var balances: [account_count]i64 = @splat(100);
        var reads: std.ArrayList(Read) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"event\":{\"event\":\"bank_") == null) continue;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
            const event = parsed.object.get("event").?.object;
            const name = event.get("event").?.string;
            const details = event.get("details").?.object;
            steps += 1;
            var fits = true;
            if (std.mem.eql(u8, name, "bank_audit")) {
                for (details.get("balances").?.array.items, balances) |said, balance| fits = fits and said.integer == balance;
            } else {
                const client = details.get("client").?.integer;
                const held: ?usize = for (reads.items, 0..) |read, at| {
                    if (read.client == client) break at;
                } else null;
                if (std.mem.eql(u8, name, "bank_read")) {
                    const read: Read = .{
                        .client = client,
                        .source = @intCast(details.get("source").?.integer),
                        .target = @intCast(details.get("target").?.integer),
                        .source_balance = details.get("source_balance").?.integer,
                        .target_balance = details.get("target_balance").?.integer,
                    };
                    fits = held == null and read.source_balance == balances[read.source] and
                        read.target_balance == balances[read.target];
                    if (held == null) try reads.append(arena, read);
                } else if (held) |at| {
                    const read = reads.swapRemove(at);
                    if (std.mem.eql(u8, name, "bank_commit")) {
                        const amount = details.get("amount").?.integer;
                        fits = details.get("source_balance").?.integer == read.source_balance - amount and
                            details.get("target_balance").?.integer == read.target_balance + amount;
                        // The bug: what it read is no longer what is there.
                        if (balances[read.source] != read.source_balance or balances[read.target] != read.target_balance) stale += 1;
                        balances[read.source] = read.source_balance - amount;
                        balances[read.target] = read.target_balance + amount;
                    }
                } else fits = false; // A commit or a reject of no read.
            }
            if (!fits) {
                misfits += 1;
                if (misfit_first.len == 0) misfit_first = line[0..@min(line.len, 200)];
            }
        }
    }
    expect_all(context, &.{
        .{ "4 timelines", count == 4 },
        .{ "they said their steps", steps > 400 },
        .{ "every step fits the steps before it", misfits == 0 },
        .{ "some commit wrote from a stale read (the bug)", stale > 0 },
    }, "bank-steps: {d} steps of 4 timelines in the order Redis took them, {d} that do not fit ({s}); " ++
        "{d} commits from a stale read", .{ steps, misfits, misfit_first, stale });
}

/// Drivers slower than their timeline's limit allows: no driver starts past half the limit, and
/// every timeline finishes (drivers ran on to the limit and failed as hangs before).
fn check_slow(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "slow-events" });
    const report = try explore(context, &.{
        "--program",        program, "--scenario",  "slow", "--seed",       "1",    "--branches", "8",
        "--timeline-limit", "30s",   "--branching", "flat", "--events-dir", events,
    });
    var branches: [8]Branch = undefined;
    const count = parse_branches(report, &branches);
    const stopped = try query_count(context, &.{ events, "event=drivers_stopped" });
    var unfinished = false;
    var hung = false;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "FAIL") != null and
            std.mem.indexOf(u8, line, "the guest finishes its scenario") != null) unfinished = true;
        // A timeline's own line (a property's text may say "hung" too).
        if (std.mem.startsWith(u8, line, "[branch") and std.mem.indexOf(u8, line, " hung ") != null) hung = true;
    }
    expect_all(context, &.{
        .{ "8 timelines", count == 8 },
        .{ "none hung", !hung },
        .{ "\"the guest finishes its scenario\" holds", !unfinished },
        .{ "drivers stopped starting in some", stopped > 0 },
    }, "slow: no driver starts past half the timeline limit; {d} of 8 timelines stopped starting them, none hung", .{stopped});
}

/// A finally command that never ends is killed once its window (2 s here) passes: the property
/// says so, and the timeline goes on to its end, not hung.
fn check_ending_window(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program", program, "--scenario", "ending_window", "--seed", "1", "--branches", "2", "--timeline-limit", "120s",
    });
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var unfinished = false;
    var hung = false;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "FAIL") != null and
            std.mem.indexOf(u8, line, "the guest finishes its scenario") != null) unfinished = true;
        if (std.mem.startsWith(u8, line, "[branch") and std.mem.indexOf(u8, line, " hung ") != null) hung = true;
    }
    expect_all(context, &.{
        .{ "2 timelines", count == 2 },
        .{ "none hung", !hung },
        .{ "\"the guest finishes its scenario\" holds", !unfinished },
        .{ "the window's property fails in both", has_lines(report, &.{
            "FAIL always                hit in    2/2 branches, failing in    2  an ending command finishes within its window",
        }) },
    }, "ending-window: a finally command past its window is killed, the property says so, the timeline ends", .{});
}

/// A scenario snapshotted before its nodes start (schema.Scenario.snapshot_before_nodes): each
/// timeline starts the echo node itself, so its start's draw differs between timelines, both
/// parities met in 8 (after the nodes, every timeline would share the setup's one draw).
fn check_before_nodes(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program", program, "--scenario", "before_nodes", "--seed", "1", "--branches", "8", "--timeline-limit", "60s",
    });
    var branches: [8]Branch = undefined;
    const count = parse_branches(report, &branches);
    var one_parity = false;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "FAIL") != null and std.mem.indexOf(u8, line, "start drew an") != null) one_parity = true;
    }
    expect_all(context, &.{
        .{ "8 timelines", count == 8 },
        .{ "both parities drawn across them", !one_parity and has_lines(report, &.{"a timeline's echo start drew an even number"}) },
    }, "before-nodes: each timeline starts the nodes itself, their start draws its own", .{});
}

/// A timeline that never finishes ends at its ceiling of virtual time, as hung (the finish
/// property fails), at the same point in a replay.
fn check_hang(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "hang", "--seed", "1", "--timeline-limit", "20s",
    };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2" }));
    const both_hung = std.mem.count(u8, report, " hung ") == 2;
    const unfinished = std.mem.indexOf(u8, report, "FAIL always                hit in    2/2 " ++
        "branches, failing in    2  the guest finishes its scenario") != null;
    const hung = both_hung and unfinished;
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    const same = count == 2 and ran_one and same_timelines(&replayed, branches[0..count]);
    expect_all(context, &.{
        .{ "both timelines end hung", both_hung },
        .{ "\"the guest finishes its scenario\" fails in both", unfinished },
        .{ "2 timelines", count == 2 },
        .{ "the replay ran one timeline", ran_one },
        .{ "the replay is the same timeline", same },
    }, "hang: a timeline that never finishes ends at its ceiling, hung, the same in a replay", .{});
    if (!(hung and same)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "[branch", "FAIL",
    }) catch ""});
}

/// Retroactive logging: output lines with a hidden text are not written while exploring (the
/// timelines are the same: events hash), and a replay of a timeline writes them.
/// A scenario's drawn driver phase (Scenario.drive_ms_max): each timeline draws its length, at
/// most the scenario's, and its drivers stop starting once it passed.
fn check_drive(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const events = try std.fmt.allocPrint(arena, "{s}/drive-events", .{context.scratch});
    const report = try explore(context, &.{
        "--program",   program, "--scenario",   "bank_drawn", "--seed", "5", "--branches", "4",
        "--branching", "flat",  "--events-dir", events,
    });
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    const drawn = try run_kept(context, &.{ "grep", "-rhoE", "\"event\":\"drive_drawn\",\"details\":.\"ms\":[0-9]+", events });
    var lengths: u32 = 0;
    var within = true;
    var lines = std.mem.tokenizeScalar(u8, drawn.stdout, '\n');
    while (lines.next()) |line| {
        const at = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        const ms = std.fmt.parseInt(u64, line[at + 1 ..], 10) catch continue;
        lengths += 1;
        within = within and ms <= 20_000;
    }
    expect_all(context, &.{
        .{ "4 timelines", count == 4 },
        .{ "each drew its driver phase's length", lengths == 4 },
        .{ "none longer than the scenario's 20 s", within },
    }, "drive: a scenario's driver phase drawn in virtual time ({d} drawn)", .{lengths});
}

/// The guest's clock starts the day after the system's newest image was made, or where
/// `--epoch` says: a node reads the date at a moment.
fn check_epoch(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const timeline = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "1", "--branch", "0" };
    // A quarter of the way into the timeline (a date's epoch changes the timeline after it, not
    // its setup); 1500 ms once, which a timeline on the taken-branch clock may end before.
    const moment = try moment_inside(arena, try explore(context, &timeline), 0.25);
    const look = timeline ++ [_][]const u8{
        "--at-vtime-ms", moment, "--exec", "det-nodes exec redis date -u +date=%F",
    };
    const given = try explore(context, &(look ++ [_][]const u8{ "--epoch", "2027-03-04" }));
    const default = try explore(context, &look);
    // The node's answer (exec_output's text), not the command echoed before it.
    const answer = "\"text\":\"date=";
    const default_date = if (std.mem.indexOf(u8, default, answer)) |at|
        default[at + answer.len ..][0..@min(10, default.len - at - answer.len)]
    else
        "";
    expect_all(context, &.{
        .{ "with --epoch 2027-03-04 the node reads 2027-03-04", std.mem.indexOf(u8, given, "\"text\":\"date=2027-03-04") != null },
        .{ "by default a date of 2026-01-01 or later", default_date.len == 10 and
            std.mem.order(u8, default_date, "2026-01-01") != .lt },
    }, "epoch: the guest's clock starts where --epoch says, else after its images (by default: {s})", .{default_date});
}

fn check_retroactive(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "21" };
    const text = "Ready to accept";
    // Hidden by --retroactive, shown, hidden by the profile's own (bank's `retroactive`).
    var hidden_dirs: [3][]const u8 = undefined;
    var reports: [3][]const u8 = undefined;
    for (&hidden_dirs, &reports, 0..) |*dir, *report, index| {
        dir.* = try std.fmt.allocPrint(arena, "{s}/retroactive-{d}", .{ context.scratch, index });
        const extra: []const []const u8 = switch (index) {
            0 => &.{ "--retroactive", text },
            1 => &.{},
            else => &.{ "--profile", "retroactive" },
        };
        report.* = try explore(context, try std.mem.concat(arena, []const u8, &.{
            &system, &.{ "--branches", "2", "--branching", "flat", "--events-dir", dir.* }, extra,
        }));
    }
    const replay_dir = try std.fmt.allocPrint(arena, "{s}/retroactive-replay", .{context.scratch});
    _ = try explore(context, &(system ++ [_][]const u8{
        "--branch", "0", "--retroactive", text, "--events-dir", replay_dir,
    }));
    const hidden = try directory_has(context, hidden_dirs[0], text);
    const shown = try directory_has(context, hidden_dirs[1], text);
    const hidden_by_profile = try directory_has(context, hidden_dirs[2], text);
    const replayed = try directory_has(context, replay_dir, text);
    var with: [2]Branch = undefined;
    var without: [2]Branch = undefined;
    var profiled: [2]Branch = undefined;
    const both = parse_branches(reports[0], &with) == 2 and parse_branches(reports[1], &without) == 2;
    expect_all(context, &.{
        .{ "the hidden text is not in the exploration's events", !hidden },
        .{ "shown, it is", shown },
        .{ "declared by the workload's profile, it is not", !hidden_by_profile },
        .{ "2 timelines with the profile's", parse_branches(reports[2], &profiled) == 2 },
        .{ "a replay writes it", replayed },
        .{ "2 timelines each way", both },
        .{ "the timelines are the same either way", both and same_timelines(&with, &without) },
    }, "retroactive: hidden output stays out of an exploration's events, the timelines unchanged, " ++
        "and a replay writes it", .{});
}

/// A pinned system replays on another host: a kit (the run's pin, with its node disks beside it
/// by name) replays a timeline from an empty cache, with nothing pulled or built, to the same
/// events.
fn check_pinned(context: *Context) !void {
    const arena = context.arena;
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5", "--branch", "0" };
    const events = try std.fs.path.join(arena, &.{ context.scratch, "pinned-events" });
    const report = try explore(context, &(system ++ [_][]const u8{ "--events-dir", events }));
    const Pin = struct { system_json: []const u8, disks: []const []const u8 };
    const pin_path = try std.fs.path.join(arena, &.{ events, "system.pin.json" });
    const pin_json = try cwd.readFileAlloc(io, pin_path, arena, .limited(1 << 20));
    const pin = try std.json.parseFromSliceLeaky(Pin, arena, pin_json, .{});
    const kit = try std.fs.path.join(arena, &.{ context.scratch, "pinned-kit" });
    try cwd.createDirPath(io, kit);
    const names = try arena.alloc([]const u8, pin.disks.len);
    for (pin.disks, names) |disk, *name| {
        name.* = std.fs.path.basename(disk);
        const copy = try std.fs.path.join(arena, &.{ kit, name.* });
        cwd.access(io, copy, .{}) catch try cwd.copyFile(disk, cwd, copy, io, .{});
    }
    const kit_pin = try std.fs.path.join(arena, &.{ kit, "system.pin.json" });
    try cwd.writeFile(io, .{ .sub_path = kit_pin, .data = try std.fmt.allocPrint(arena, "{f}", .{
        std.json.fmt(Pin{ .system_json = pin.system_json, .disks = names }, .{}),
    }) });
    const fresh = try std.fs.path.join(arena, &.{ context.scratch, "pinned-cache" });
    const replayed = try explore(context, &(system ++ [_][]const u8{ "--system", kit_pin, "--cache", fresh }));
    var original: [1]Branch = undefined;
    var again: [1]Branch = undefined;
    const ran = parse_branches(report, &original) == 1 and parse_branches(replayed, &again) == 1;
    const same = ran and std.mem.eql(u8, original[0].events_hash, again[0].events_hash);
    expect_all(context, &.{
        .{ "one timeline each", ran },
        .{ "the same events hash", same },
        .{ "nothing built", std.mem.indexOf(u8, replayed, "] building ") == null },
        .{ "nothing pulled", std.mem.indexOf(u8, replayed, "] pulling ") == null },
        .{ "nothing flattened", std.mem.indexOf(u8, replayed, "] flattening ") == null },
    }, "pinned: a kit replays a timeline from an empty cache, nothing pulled or built ({s})", .{
        if (same) original[0].events_hash else "differs",
    });
}

/// Whether some events file of an events directory has `text`.
fn directory_has(context: *Context, directory: []const u8, text: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(context.io, directory, .{ .iterate = true }) catch return false;
    defer dir.close(context.io);
    var iterator = dir.iterate();
    while (try iterator.next(context.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(context.arena, &.{ directory, entry.name });
        const content = try cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 30));
        if (std.mem.indexOf(u8, content, text) != null) return true;
    }
    return false;
}

/// Antithesis's "restarted nodes may change IP addresses": restarts asked for by the scenario;
/// the node answers at its name every time (hosts files follow it) and in some timeline came
/// back at a new address.
fn check_readdress(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "movable", "--scenario", "readdress", "--seed", "1",
        "--branches", "4",
    });
    const answers = std.mem.indexOf(u8, report, "PASS always                hit in    4/4 " ++
        "branches, failing in    0  a restarted node answers at its name") != null;
    const moved = std.mem.indexOf(u8, report, "PASS sometimes") != null and
        std.mem.indexOf(u8, report, "a restarted node comes back at a new address") != null;
    expect_all(context, &.{
        .{ "a restarted node answers at its name, in all 4", answers },
        .{ "some came back at a new address (PASS sometimes)", moved },
    }, "readdress: restarted nodes answer at their names, some at a new address", .{});
    if (!(answers and moved)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "PASS", "readdress",
    }) catch ""});
}

fn check_signal(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "signaled", "--scenario", "signal", "--seed", "1",
        "--branches", "2",
    });
    const interrupted = std.mem.indexOf(u8, report, "PASS always                hit in    2/2 " ++
        "branches, failing in    0  a signal the node catches interrupts its accept (EINTR)") != null;
    const answering = std.mem.indexOf(u8, report, "failing in    0  the node answers after its signals") != null;
    expect_all(context, &.{
        .{ "a caught signal interrupted the accept, in both", interrupted },
        .{ "the node answers after its signals", answering },
    }, "signal: a signal the node catches interrupts its blocked accept (EINTR)", .{});
    if (!(interrupted and answering)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "PASS", "signal",
    }) catch ""});
}

fn check_file_error(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "file-error-events" });
    std.Io.Dir.cwd().deleteTree(context.io, events) catch {};
    const report = try explore(context, &.{
        "--program",  program, "--profile",    "durable", "--scenario", "file_error", "--seed", "1",
        "--branches", "2",     "--events-dir", events,
    });
    const passes = has_lines(report, &.{
        "PASS always                hit in    2/2 branches, failing in    0  the node appends to its disk before the file errors",
        "PASS always                hit in    2/2 branches, failing in    0  a write error the scenario asks for fails the node's append (ENOSPC)",
        "PASS always                hit in    2/2 branches, failing in    0  the node's reads go on under write errors",
        "PASS always                hit in    2/2 branches, failing in    0  the node appends again once its file errors end",
        "PASS always                hit in    2/2 branches, failing in    0  a short write the scenario asks for writes part of the node's append",
    });
    const counted = try query_count(context, &.{ events, "event=file_errors details.failed>0" });
    expect_all(context, &.{
        .{ "its appends fail with ENOSPC under the fault, its reads do not, both before and after succeed", passes },
        .{ "the module counts the calls it failed (file_errors)", counted > 0 },
    }, "file_error: a guest kernel hook fails a node's writes of its disk files with the error asked for", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{ "FAIL", "PASS" }) catch ""});
}

/// Swarm testing over a workload's operations (sdk.swarm_choice, Will Wilson's cache): with the
/// swarm, some timeline leaves removes out or makes them rare, and the cache's eviction (its bug)
/// is reached; with --no-swarm (uniform choices) it is reached in none.
fn check_swarm(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{ "--program", program, "--scenario", "cache", "--seed", "1", "--branches", "16" };
    const swarmed = try explore(context, &common);
    const plain = try explore(context, &(common ++ [_][]const u8{"--no-swarm"}));
    const message = "the cache's eviction is never reached (its bug)";
    const found = has_prefix_line(swarmed, "FAIL unreachable", message);
    const missed = std.mem.indexOf(u8, plain, "PASS unreachable           hit in    0/16 branches, failing in    0  " ++ message) != null;
    // The composer's swarm over drivers: some timeline leaves a nemesis out, none the workload
    // (its one workload driver, marked); --no-swarm leaves none out.
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "swarm-drivers-events" });
    const plain_events = try std.fs.path.join(context.arena, &.{ context.scratch, "swarm-drivers-plain-events" });
    for ([_][]const u8{ events, plain_events }) |directory| std.Io.Dir.cwd().deleteTree(context.io, directory) catch {};
    const drivers = [_][]const u8{ "--program", program, "--scenario", "drivers", "--seed", "1", "--branches", "16" };
    _ = try explore(context, &(drivers ++ [_][]const u8{ "--events-dir", events }));
    _ = try explore(context, &(drivers ++ [_][]const u8{ "--no-swarm", "--events-dir", plain_events }));
    const nemesis_out = try query_count(context, &.{ events, "event=command_left_out details.name=nemesis_a" }) +
        try query_count(context, &.{ events, "event=command_left_out details.name=nemesis_b" });
    const workload_out = try query_count(context, &.{ events, "event=command_left_out details.name=workload" });
    const plain_out = try query_count(context, &.{ plain_events, "event=command_left_out" });
    // --keep nemesis_a: kept in every timeline (a trial of a new driver), nemesis_b swarmed still.
    const kept_events = try std.fs.path.join(context.arena, &.{ context.scratch, "swarm-kept-events" });
    std.Io.Dir.cwd().deleteTree(context.io, kept_events) catch {};
    _ = try explore(context, &(drivers ++ [_][]const u8{ "--keep", "nemesis_a", "--events-dir", kept_events }));
    const kept_a_out = try query_count(context, &.{ kept_events, "event=command_left_out details.name=nemesis_a" });
    const kept_b_out = try query_count(context, &.{ kept_events, "event=command_left_out details.name=nemesis_b" });
    // Unmarked, three drivers: none left out, each weighted.
    const unmarked_events = try std.fs.path.join(context.arena, &.{ context.scratch, "swarm-unmarked-events" });
    std.Io.Dir.cwd().deleteTree(context.io, unmarked_events) catch {};
    _ = try explore(context, &.{ "--program", program, "--scenario", "drivers_unmarked", "--seed", "1", "--branches", "8", "--events-dir", unmarked_events });
    const unmarked_out = try query_count(context, &.{ unmarked_events, "event=command_left_out" });
    const unmarked_weighted = try query_count(context, &.{ unmarked_events, "event=command_weight" });
    expect_all(context, &.{
        .{ "the swarm reaches the cache's eviction", found },
        .{ "uniform choices never do", missed },
        .{ "the composer leaves a nemesis driver out of some timeline", nemesis_out > 0 },
        .{ "never the scenario's one workload driver", workload_out == 0 },
        .{ "and none with --no-swarm", plain_out == 0 },
        .{ "a driver --keep names is never left out, another still is", kept_a_out == 0 and kept_b_out > 0 },
        .{ "a scenario marking no workload, with three drivers, leaves none out and weighs them", unmarked_out == 0 and unmarked_weighted > 0 },
    }, "swarm: swarm_choice finds the bug uniform choices miss (a cache's eviction); the composer swarms its drivers, one of the workload's kept", .{});
    if (!(found and missed)) std.debug.print("{s}\n{s}\n", .{
        lines_with(context.arena, swarmed, &.{ "FAIL", "eviction" }) catch "",
        lines_with(context.arena, plain, &.{ "FAIL", "eviction" }) catch "",
    });
}

/// Metastability (docs/ANTITHESIS_EXPLORATION.md, M): the toy service under an open-loop load,
/// red with clients retrying on a 10 s timeout (goodput never recovers after the trigger), green
/// with a 20 s timeout.
fn check_metastable(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const message = "goodput recovers after an overload";
    const collapsed = try explore(context, &.{ "--program", program, "--profile", "queue", "--scenario", "metastable", "--seed", "1", "--branches", "2" });
    const recovered = try explore(context, &.{ "--program", program, "--profile", "queue", "--scenario", "stable", "--seed", "1", "--branches", "2" });
    const red = std.mem.indexOf(u8, collapsed, "FAIL always                hit in    2/2 branches, failing in    2  " ++ message) != null;
    const green = std.mem.indexOf(u8, recovered, "PASS always                hit in    2/2 branches, failing in    0  " ++ message) != null;
    expect_all(context, &.{
        .{ "with an 8 s timeout and retries, goodput never recovers (a metastable failure)", red },
        .{ "with a 20 s timeout, it recovers", green },
    }, "metastable: an open-loop load's recovery property tells a metastable service from a stable one", .{});
    if (!(red and green)) std.debug.print("{s}\n{s}\n", .{
        lines_with(context.arena, collapsed, &.{ "goodput", "FAIL" }) catch "",
        lines_with(context.arena, recovered, &.{ "goodput", "FAIL" }) catch "",
    });
}

fn check_syscall_error(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "signaled", "--scenario", "syscall_error", "--seed", "1",
        "--branches", "2",
    });
    const failed = std.mem.indexOf(u8, report, "PASS always                hit in    2/2 " ++
        "branches, failing in    0  a system call error the scenario asks for reaches the node (accept4, EMFILE)") != null;
    const answering = std.mem.indexOf(u8, report, "failing in    0  the node answers once its system call errors end") != null;
    expect_all(context, &.{
        .{ "the node's accept4 failed with EMFILE, in both", failed },
        .{ "the node answers once the errors end", answering },
    }, "syscall_error: the kernel's fail_function fails a node's system call with the error asked for", .{});
    if (!(failed and answering)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "PASS", "fault",
    }) catch ""});
}

fn check_unlist(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "unlistable", "--scenario", "unlist", "--seed", "1",
        "--branches", "4",
    });
    const kept = std.mem.indexOf(u8, report, "FAIL always") == null and
        std.mem.indexOf(u8, report, "a node started again is named in its peers' hosts files") != null;
    const gone = std.mem.indexOf(u8, report, "PASS sometimes") != null and
        std.mem.indexOf(u8, report, "a node down is gone from its peers' hosts files") != null;
    expect_all(context, &.{
        .{ "the runner names it, and every peer once it started again (no FAIL always)", kept },
        .{ "a node down was gone from a peer's hosts file (PASS sometimes)", gone },
    }, "unlist: a node down leaves its peers' hosts files, and comes back to them", .{});
    if (!(kept and gone)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "PASS", "unlist", "hosts",
    }) catch ""});
}

/// A targeted run (--changed): the Python maze with a diff of three lines, matched by their
/// line coverage although the diff names repository paths and the image has its own. The line
/// every timeline runs ran in all, the first digit's in some, and the tree returned to them just
/// after; the solved maze's line never ran.
fn check_changed(context: *Context) !void {
    const arena = context.arena;
    const record = try std.fmt.allocPrint(arena, "{s}/changed.jsonl", .{context.scratch});
    // One generation in flight: the tree returns from the second one on (with the default three,
    // 48 timelines would all be roots).
    const report = try explore(context, &.{
        "--compose",  "tests/antithesis-compat/python/compose.yaml", "--scenario", "maze",
        "--seed",     "1",                                           "--branches", "48",
        "--changed",  "tests/changed/maze.diff",                     "--record",   record,
        "--pipeline", "1",
    });
    const file = "tests/antithesis-compat/python/client/maze/singleton_driver_maze.py";
    const every = try std.fmt.allocPrint(arena, "ran in   48/48 timelines  {s}:24-24", .{file});
    const never = try std.fmt.allocPrint(arena, "NEVER RAN  {s}:23-23", .{file});
    const some = try std.fmt.allocPrint(arena, "{s}:17-17", .{file});
    const cwd = std.Io.Dir.cwd();
    const recorded = cwd.readFileAlloc(context.io, record, arena, .limited(64 << 20)) catch "";
    const said = has_lines(report, &.{ "2 of 3 hunks ran", every, never, some });
    const returned = std.mem.indexOf(u8, recorded, "just after it first ran changed code") != null;
    const passes = said and returned;
    expect_all(context, &.{
        .{ "it says which hunks ran and which never did", said },
        .{ "the tree returned just after changed code", returned },
    }, "changed: a targeted run says which hunks ran and which never did, and returns to changed " ++
        "code", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(arena, report, &.{
        "changed code", "ran in", "NEVER", "tree:",
    }) catch ""});
    try check_changed_commit(context, file);
}

/// A targeted run by commit: the same three lines as a commit of a repository fetched by its
/// URL (--changed-repository), the commit named alone (that commit's change).
fn check_changed_commit(context: *Context, file: []const u8) !void {
    const arena = context.arena;
    const repository = try std.fmt.allocPrint(arena, "{s}/changed-repository", .{context.scratch});
    const script = try std.fmt.allocPrint(arena,
        \\set -e; source=$(pwd)/{1s}; rm -rf {0s}; mkdir -p {0s}/$(dirname {1s}); cd {0s}
        \\git init -q; cp "$source" {1s}; sed -i '17s/$/  # before/;23s/$/  # before/;24s/$/  # before/' {1s}
        \\git add -A; git -c user.name=e2e -c user.email=e2e@localhost commit -qm before
        \\cp "$source" {1s}; git -c user.name=e2e -c user.email=e2e@localhost commit -qam after
        \\git rev-parse HEAD
    , .{ repository, file });
    const made = try run_kept(context, &.{ "sh", "-c", script });
    const commit = std.mem.trim(u8, made.stdout, " \n");
    const url = try std.fmt.allocPrint(arena, "file://{s}", .{repository});
    const report = try explore(context, &.{
        "--compose",            "tests/antithesis-compat/python/compose.yaml", "--scenario", "maze",
        "--seed",               "1",                                           "--branches", "16",
        "--changed",            commit,                                        "--pipeline", "1",
        "--changed-repository", url,
    });
    const both = try std.fmt.allocPrint(arena, "ran in   16/16 timelines  {s}:23-24", .{file});
    const first = try std.fmt.allocPrint(arena, "{s}:17-17", .{file});
    expect_all(context, &.{
        .{ "the repository was made", made.term == .exited and made.term.exited == 0 and commit.len == 40 },
        .{ "the commit's two hunks", std.mem.indexOf(u8, report, "of 2 hunks ran") != null },
        .{ "lines 23-24 ran in every timeline", std.mem.indexOf(u8, report, both) != null },
        .{ "line 17 is one of them", std.mem.indexOf(u8, report, first) != null },
    }, "changed: a targeted run by a commit of a repository fetched by its URL", .{});
}

/// A static program without libc (its own _start, so no constructor runs, as a Zig program's),
/// built with trace-pc-guard and linked with the SDK's lib/libvoidstar.o (from the build context
/// determinismo-sdk): libvoidstar numbers its guards at their first call, and its edges are
/// source lines.
fn check_voidstar_static(context: *Context) !void {
    const arena = context.arena;
    const events = try std.fmt.allocPrint(arena, "{s}/voidstar-static", .{context.scratch});
    const report = try explore(context, &.{
        "--compose",    "tests/antithesis-compat/static/compose.yaml", "--scenario", "run",
        "--seed",       "1",                                           "--branches", "1",
        "--events-dir", events,
    });
    const ran = try run_kept(context, &.{ "grep", "-rlF", "static-prog ran", events });
    const coverage = try run_kept(context, &.{ "grep", "-rlF", "\"name\":\"line /src/static/prog.c:", events });
    expect_all(context, &.{
        .{ "the program ran", ran.stdout.len > 0 },
        .{ "its edges are source lines, though no constructor of it ran", coverage.stdout.len > 0 },
    }, "voidstar-static: a static program without libc, linked with lib/libvoidstar.o, reports its coverage ({d} bytes of report)", .{report.len});
}

/// C built as Antithesis builds it (clang's trace-pc-guard, linked against libvoidstar, the binary
/// in /symbols): its edges are reported as source lines (a table of its DWARF the host made when
/// preparing the image), so a targeted run sees which of a diff's lines ran.
fn check_lines(context: *Context) !void {
    const arena = context.arena;
    const events = try std.fmt.allocPrint(arena, "{s}/lines", .{context.scratch});
    const report = try explore(context, &.{
        "--compose",  "tests/antithesis-compat/c/compose.yaml", "--scenario",   "maze",
        "--seed",     "1",                                      "--branches",   "16",
        "--changed",  "tests/changed/c-maze.diff",              "--events-dir", events,
        "--pipeline", "1",
    });
    const file = "tests/antithesis-compat/c/client/maze.c";
    const every = try std.fmt.allocPrint(arena, "ran in   16/16 timelines  {s}:13-15", .{file});
    const never = try std.fmt.allocPrint(arena, "NEVER RAN  {s}:22-23", .{file});
    const coverage = try run_kept(context, &.{ "grep", "-rlF", "\"name\":\"line /src/client/maze.c:", events });
    // The same with determinismo's C SDK instead of libvoidstar.
    const sdk_events = try std.fmt.allocPrint(arena, "{s}/lines-sdk", .{context.scratch});
    _ = try explore(context, &.{
        "--compose",    "tests/antithesis-compat/c/compose.yaml", "--scenario", "maze_sdk",
        "--seed",       "1",                                      "--branches", "4",
        "--events-dir", sdk_events,
    });
    const sdk_coverage = try run_kept(context, &.{ "grep", "-rlF", "\"name\":\"line /src/client/maze_sdk.c:", sdk_events });
    // And with the Rust SDK (feature coverage: its trace-pc-guard callbacks in C).
    const rust_events = try std.fmt.allocPrint(arena, "{s}/lines-rust", .{context.scratch});
    _ = try explore(context, &.{
        "--compose",    "tests/antithesis-compat/rust/compose.yaml", "--scenario", "maze_rust",
        "--seed",       "1",                                         "--branches", "4",
        "--events-dir", rust_events,
    });
    const rust_coverage = try run_kept(context, &.{ "grep", "-rlE", "\"name\":\"line [^\"]*src/main.rs:[0-9]+", rust_events });
    // A node given as a binary (no image, so no /symbols of its maker's): its lines' table is
    // made with its disk, and its edges are lines too (the C++ race, built for coverage).
    const binary_events = try std.fmt.allocPrint(arena, "{s}/lines-binary", .{context.scratch});
    _ = try explore(context, &.{
        "--program",  try std.fs.path.join(arena, &.{ context.bin, "race-test" }), "--scenario",   "race",
        "--profile",  "instrumented",                                              "--seed",       "1",
        "--branches", "2",                                                         "--events-dir", binary_events,
    });
    const binary_coverage = try run_kept(context, &.{ "grep", "-rlE", "\"name\":\"line [^\"]*race.cpp:[0-9]+", binary_events });
    expect_all(context, &.{
        .{ "the C program's coverage is source lines", coverage.stdout.len > 0 },
        .{ "with determinismo's C SDK too", sdk_coverage.stdout.len > 0 },
        .{ "and its Rust SDK", rust_coverage.stdout.len > 0 },
        .{ "a binary node's too (its table made with its disk)", binary_coverage.stdout.len > 0 },
        .{ "main's first lines ran in every timeline", std.mem.indexOf(u8, report, every) != null },
        .{ "the solved maze's lines never ran", std.mem.indexOf(u8, report, never) != null },
    }, "lines: C instrumented for Antithesis reports source lines, and a targeted run sees them; so do the C and Rust SDKs' coverage", .{});
    if (std.mem.indexOf(u8, report, every) == null) std.debug.print("{s}\n", .{lines_with(arena, report, &.{
        "changed code", "ran in", "NEVER", "source lines",
    }) catch ""});
}

/// libvoidstar.so, Antithesis's native library, in a node: Python (musl) loads it with ctypes,
/// and its SDK message is an event, its random number a decision (the same on a replay), its
/// coverage an edge event of the module, in the timeline's events. The command runs with the
/// node's Compose ulimits (open files 20000, 40000 hard). The nodes' output forwarders hold
/// their pipes, stdio, log and the platform's device, nothing they inherited (a copy of a lock
/// once deadlocked the fault injector).
fn check_voidstar(context: *Context) !void {
    const arena = context.arena;
    const code =
        \\det-nodes exec client python3 -c '
        \\import ctypes, json, resource
        \\print("nofile", *resource.getrlimit(resource.RLIMIT_NOFILE))
        \\lib = ctypes.CDLL("/usr/lib/libvoidstar.so")
        \\lib.fuzz_get_random.restype = ctypes.c_uint64
        \\lib.init_coverage_module.restype = ctypes.c_uint64
        \\lib.notify_coverage.restype = ctypes.c_bool
        \\number = lib.fuzz_get_random()
        \\message = json.dumps({"event": "voidstar", "details": {"random": number}}).encode()
        \\lib.fuzz_json_data(message, len(message))
        \\lib.fuzz_flush()
        \\base = lib.init_coverage_module(3, b"none.sym.tsv")
        \\print("voidstar", number, base, lib.notify_coverage(ctypes.c_size_t(base + 1)))'
        \\for p in /proc/[0-9]*; do case "$(cat $p/comm 2>/dev/null)" in redis|client) echo "forwarder $(ls $p/fd | wc -l) files";; esac; done
    ;
    var outputs: [2][]const u8 = undefined;
    var events_found = true;
    for (&outputs, 0..) |*output, attempt| {
        const events = try std.fmt.allocPrint(arena, "{s}/voidstar-{d}", .{
            context.scratch, attempt,
        });
        const report = try explore(context, &.{
            "--compose",    "tests/antithesis-compat/python/compose.yaml", "--scenario", "bank",
            "--seed",       "1",                                           "--branch",   "0",
            "--until",      "event=command_start",                         "--exec",     code,
            "--events-dir", events,
        });
        output.* = try lines_with(arena, report, &.{ "voidstar", "nofile", "forwarder" });
        try events_plain(context, events);
        const path = try std.fs.path.join(arena, &.{ events, "branch-0.jsonl" });
        const cwd = std.Io.Dir.cwd();
        const text = cwd.readFileAlloc(context.io, path, arena, .limited(64 << 20)) catch "";
        const event = std.mem.indexOf(u8, text, "\"event\": \"voidstar\"") != null; // json.dumps'.
        const edge = std.mem.indexOf(u8, text, "edge none.sym.tsv:1") != null;
        events_found = events_found and event and edge;
    }
    // notify_coverage answers True: the edge is reported once, and asked about at every pass,
    // where thread pausing pauses (voidstar.zig; False was its answer before pausing rode on it).
    const answered = std.mem.indexOf(u8, outputs[0], "voidstar ") != null and
        std.mem.indexOf(u8, outputs[0], "True") != null;
    const same = std.mem.eql(u8, outputs[0], outputs[1]);
    // Thread-local state would be the host program's (static-pie: local-exec): none at all.
    const library = try std.fs.path.join(arena, &.{ context.bin, "libvoidstar.so" });
    const tls_free = !(try elf_has_tls(context, library));
    const ulimits = std.mem.indexOf(u8, outputs[0], "nofile 20000 40000") != null;
    // At most stdin, stdout, stderr, two pipes, the log, the device and the listener of the
    // node's exits (exits.zig's seccomp notification): 8 files each.
    var forwarders: u32 = 0;
    var forwarders_lean = true;
    var forwarder_lines = std.mem.tokenizeScalar(u8, outputs[0], '\n');
    while (forwarder_lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "forwarder ") orelse continue;
        var words = std.mem.tokenizeScalar(u8, line[at + "forwarder ".len ..], ' ');
        const files = std.fmt.parseInt(u32, words.next() orelse "", 10) catch 1000;
        forwarders += 1;
        forwarders_lean = forwarders_lean and files <= 8;
    }
    forwarders_lean = forwarders_lean and forwarders >= 2;
    const passes = answered and events_found and same and tls_free and ulimits and forwarders_lean;
    expect_all(context, &.{
        .{ "notify_coverage answered (True)", answered },
        .{ "the command ran with the node's Compose ulimits (nofile 20000 40000)", ulimits },
        .{ "every node's output forwarder holds 8 files at most (none inherited)", forwarders_lean },
        .{ "its events and edges reach the timeline", events_found },
        .{ "the same twice", same },
        .{ "libvoidstar.so has no thread-local storage", tls_free },
    }, "voidstar: a node's Python loads libvoidstar.so; its message, decision and coverage reach " ++
        "the timeline, the same twice", .{});
    if (!passes) std.debug.print("tls free: {}\n{s}\n{s}\n", .{
        tls_free, outputs[0], outputs[1],
    });
}

/// Whether an ELF file has a PT_TLS program header.
fn elf_has_tls(context: *Context, path: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(context.io, path, context.arena, .limited(64 << 20));
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    const offset = std.mem.readInt(u64, bytes[0x20..][0..8], .little);
    const size = std.mem.readInt(u16, bytes[0x36..][0..2], .little);
    const count = std.mem.readInt(u16, bytes[0x38..][0..2], .little);
    for (0..count) |index| {
        const at = offset + index * size;
        if (at + 4 > bytes.len) return error.NotElf;
        const kind = std.mem.readInt(u32, bytes[at..][0..4], .little);
        if (kind == 7) return true; // PT_TLS
    }
    return false;
}

/// Branches give the same timelines whether one worker runs them or one per CPU does.
fn check_parallel(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "bank", "--seed", "21", "--branches", "8",
    };
    const one = try explore(context, &(common ++ [_][]const u8{ "--jobs", "1" }));
    const many = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4" }));
    var sequential: [branches_max]Branch = undefined;
    var parallel: [branches_max]Branch = undefined;
    const count = parse_branches(one, &sequential);
    const counts_match = count == 8 and parse_branches(many, &parallel) == count;
    expect_all(context, &.{
        .{ "8 timelines each way", counts_match },
        .{ "the same timelines", counts_match and same_timelines(sequential[0..count], parallel[0..count]) },
    }, "parallel workers give the timelines of one worker", .{});
    // Without --jobs a run takes every core: an explorer pinned to the CPU it booted on once
    // counted one, and ran one timeline at a time (srv2, 2026-10-27). Timelines at once, on
    // average: their wall times over the run's.
    for ([_][]const u8{ "flat", "tree" }) |branching| {
        const output = try explore(context, &[_][]const u8{
            "--program", program, "--scenario", "bank", "--seed", "22", "--branches", "48", "--branching", branching,
        });
        // On the cores the run has (a host's reserved cores give a check 2): a core short of
        // them all is fine, one timeline at a time is the bug (0.95 at once on 2 cores). A
        // tree waits for its nodes between generations: 1.46 at once on 2 cores (srv3,
        // 2026-10-28), so 0.65 of the cores, up to 1.8.
        const cores = workers_said(output);
        if (cores < 2) {
            std.debug.print("SKIP parallel: a {s} run on {d} core\n", .{ branching, cores });
            continue;
        }
        const at_once = concurrency(output);
        // A host whose memory or CPUs other runs claim (a hunt, or smokes on the reserved cores,
        // beside the checks) admits fewer VMs at once than the run has CPUs: that is the pool's
        // back-pressure, not this bug (srv3, 2026-10-28: a Kafka hunt's 50 GB and its holders
        // left one VM at a time; 2026-10-29: smokes on the reserved cores).
        const run = waits_of(output);
        if (run.memory_s + run.cpu_s > 0.25 * run.run_s) {
            std.debug.print("SKIP parallel: a {s} run's VMs waited {d:.0}s for memory and {d:.0}s " ++
                "for CPUs in {d:.0}s (other runs' claims): {d:.1} timelines at once says nothing of " ++
                "its cores\n", .{ branching, run.memory_s, run.cpu_s, run.run_s, at_once });
            continue;
        }
        const least = @min(1.8, 0.65 * @as(f64, @floatFromInt(cores)));
        expect(context, at_once >= least, "parallel: without --jobs, a {s} run keeps its {d} cores busy " ++
            "({d:.1} timelines at once on average)", .{ branching, cores, at_once });
    }
}

/// The workers a run says it has ("... on N workers"), 0 if it does not say.
fn workers_said(output: []const u8) u32 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[determinismo] ")) continue;
        if (!std.mem.endsWith(u8, line, " workers")) continue;
        const end = line.len - " workers".len;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse continue) + 1;
        return std.fmt.parseInt(u32, line[start..end], 10) catch continue;
    }
    return 0;
}

/// The timelines' wall times over the run's (its multiverse line's).
/// How long a report's timelines waited for the host's memory and for a CPU
/// (their `memory_wait=` and `cpu_wait=`), and the run's wall time.
fn waits_of(output: []const u8) struct { memory_s: f64, cpu_s: f64, run_s: f64 } {
    var memory_s: f64 = 0;
    var cpu_s: f64 = 0;
    var run_s: f64 = 0;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[branch ")) {
            if (field(line, "memory_wait=")) |wait| {
                memory_s += std.fmt.parseFloat(f64, std.mem.trimEnd(u8, wait, "s")) catch 0;
            }
            if (field(line, "cpu_wait=")) |wait| {
                cpu_s += std.fmt.parseFloat(f64, std.mem.trimEnd(u8, wait, "s")) catch 0;
            }
        } else if (std.mem.indexOf(u8, line, "] multiverse: ")) |_| {
            const end = std.mem.lastIndexOf(u8, line, "s wall") orelse continue;
            const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse continue) + 1;
            run_s = std.fmt.parseFloat(f64, line[start..end]) catch 0;
        }
    }
    return .{ .memory_s = memory_s, .cpu_s = cpu_s, .run_s = run_s };
}

test waits_of {
    const report = "[branch    0] seed=ab shutdown vtime=2.9s wall=0.4s events=488 " ++
        "events_hash=5167 failing=0 memory_wait=1.500s cpu_wait=0.250s\n" ++
        "[branch    1] seed=cd shutdown vtime=2.1s wall=0.1s events=99 events_hash=c66e failing=1 " ++
        "memory_wait=0.500s  FAIL \"total\"\n" ++
        "[determinismo] multiverse: 2 branches, 1 with failing properties, 3.000s wall\n";
    const run = waits_of(report);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), run.memory_s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), run.cpu_s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), run.run_s, 0.001);
}

fn concurrency(output: []const u8) f64 {
    var timelines_s: f64 = 0;
    var run_s: f64 = 0;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[branch ")) {
            const wall = field(line, "wall=") orelse continue;
            timelines_s += std.fmt.parseFloat(f64, std.mem.trimEnd(u8, wall, "s")) catch 0;
        } else if (std.mem.indexOf(u8, line, "] multiverse: ")) |_| {
            const end = std.mem.lastIndexOf(u8, line, "s wall") orelse continue;
            const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse continue) + 1;
            run_s = std.fmt.parseFloat(f64, line[start..end]) catch 0;
        }
    }
    return if (run_s > 0) timelines_s / run_s else 0;
}

/// TLA+ trace validation: the buggy service's trace is not a behavior of the spec; once its
/// transfer is patched through the REPL, it is. Needs Java and tla2tools.jar.
fn check_tla(context: *Context, jar: []const u8) !void {
    std.Io.Dir.cwd().access(context.io, jar, .{}) catch {
        std.debug.print("SKIP tla: no {s}\n", .{jar});
        return;
    };
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "clojure-bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5" };
    const spec = "examples/clojure-bank/tla/Bank.tla";
    const scratch = context.scratch;
    const buggy_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-buggy.jsonl" });
    const buggy = [_][]const u8{ "--branch", "1", "--events", buggy_events };
    _ = try explore(context, &(common ++ buggy));
    const fixed_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-fixed.jsonl" });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--from-branch", "1",                                 "--from-vtime-ms", "3700",
        "--from-exec",   "det-nodes exec bank /app/patch.sh", "--branch",        "2",
        "--events",      fixed_events,
    }));
    var statuses: [2]u8 = undefined;
    for ([_][]const u8{ buggy_events, fixed_events }, &statuses) |events, *status| {
        const result = try run_kept(context, &.{
            context.determinismo, "tla", "--spec", spec, "--events", events, "--tla2tools", jar,
        });
        status.* = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
    }
    const message = "tla: the buggy trace is rejected, the patched one is a behavior of the spec";
    expect(context, statuses[0] == 3 and statuses[1] == 0, message, .{});
}

/// A failing branch's script (its commands and faults) makes other seeds fail too.
fn check_script(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank" };
    // A failing timeline whose script has a fault: what the check is about (a script's faults
    // and commands followed). Which timelines fail, and whether before their first fault, moves
    // with every build of the program and of the guest: seed 7's four failing ones of eight all
    // ended within 6 s, before any fault, once the composer asked one decision more
    // (2026-11-17), and the check failed on its premise. The first one of a few seeds.
    const events_name = "script-events.jsonl";
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, events_name });
    var seed: []const u8 = "";
    var index: []const u8 = "";
    var extracted: std.process.RunResult = undefined;
    const found = seeds: for ([_][]const u8{ "7", "8", "9", "10" }) |candidate| {
        const explored = try explore(context, &(common ++ [_][]const u8{ "--seed", candidate, "--branches", "8" }));
        var branches: [branches_max]Branch = undefined;
        const count = parse_branches(explored, &branches);
        for (branches[0..count]) |branch| {
            if (!branch.failing) continue;
            seed = candidate;
            index = try std.fmt.allocPrint(context.arena, "{d}", .{branch.index});
            _ = try explore(context, &(common ++ [_][]const u8{
                "--seed", seed, "--branch", index, "--events", events,
            }));
            extracted = try run_kept(context, &.{ context.determinismo, "script", events });
            if ((try script_shape(context.arena, extracted.stdout)).fault_count > 0) break :seeds true;
        }
    } else false;
    if (!found) return expect(context, false, "script: a failing timeline whose script has a fault, in seeds 7 to 10", .{});
    const script_path = try std.fs.path.join(context.arena, &.{ context.scratch, "script.json" });
    const script_file: std.Io.Dir.WriteFileOptions = .{
        .sub_path = script_path,
        .data = extracted.stdout,
    };
    try std.Io.Dir.cwd().writeFile(context.io, script_file);
    const others = common ++ [_][]const u8{ "--seed", "99", "--branches", "8" };
    const without = failing_count(try explore(context, &others));
    const scripted = others ++ [_][]const u8{ "--script", script_path };
    const with = failing_count(try explore(context, &scripted));
    // Its own timeline, scripted, follows the script: the same commands and faults, in order.
    // Not the same failure: a script fixes what the composer and the injector decided, the seed
    // the rest, and the injector drawing nothing shifts every later draw of the guest's one
    // stream (the drivers' accounts and amounts), so whether bank fails again is chance (it did
    // at 18:45 on 2026-10-28, and did not in the full suite at 23:30). Whether other seeds fail
    // more often with it than without is not a check either: bank's bug is found in most
    // timelines either way (6 of 8 without, 5 with, once), and 8 cannot tell them apart.
    const own_events = try std.fs.path.join(context.arena, &.{ context.scratch, "script-own-events.jsonl" });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--seed", seed, "--branch", index, "--script", script_path, "--events", own_events,
    }));
    const followed = try run_kept(context, &.{ context.determinismo, "script", own_events });
    const original = try script_shape(context.arena, extracted.stdout);
    const own = try script_shape(context.arena, followed.stdout);
    // Its faults are the script's, in order, each one due before its fault phase ended: the
    // phase may end sooner than the original's (when its commands finish is the seed's: the
    // full suite of 2026-10-29 stopped faults at 6.02 s, not 6.98, before the script's last 4).
    const window_ns = faults_window_ns(context, own_events) orelse 0;
    const due = script_due(context.arena, extracted.stdout, window_ns -| script_due_margin_ns);
    expect_all(context, &.{
        .{ "other seeds fail with the script", with > 0 },
        .{ "its own timeline, scripted, starts the script's commands, in order", std.mem.eql(u8, own.commands, original.commands) },
        .{ "and applies the script's faults, in order", std.mem.startsWith(u8, original.faults, own.faults) },
        .{ "each one due before its faults stopped", own.fault_count >= due and due > 0 },
        .{ "a script with faults and commands", original.faults.len > 0 and original.commands.len > 0 },
    }, "script: other seeds fail with it ({d} of 8, {d} without); its own timeline follows it ({d} commands, {d} faults)", .{
        with, without, original.command_count, original.fault_count,
    });
}

/// How far a script's fault times (from the scenario's setup) may sit from the moment a timeline's
/// faults stopped and still count as due: the injector's start is a little past setup's end.
const script_due_margin_ns = 100 * std.time.ns_per_ms;

/// How many of a script's faults come at or before `until_ns` (from the setup's end).
fn script_due(arena: std.mem.Allocator, text: []const u8, until_ns: u64) usize {
    const Script = struct { faults: []const struct { at_ns: u64 = 0 } = &.{} };
    const script = std.json.parseFromSliceLeaky(Script, arena, text, .{ .ignore_unknown_fields = true }) catch
        return 0;
    var count: usize = 0;
    for (script.faults) |fault| count += @intFromBool(fault.at_ns <= until_ns);
    return count;
}

/// A timeline's fault phase, from its setup's end (setup_complete) to its faults' stop
/// (faults_stop), from its events.
fn faults_window_ns(context: *Context, events_path: []const u8) ?u64 {
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, events_path, context.arena, .limited(1 << 28)) catch return null;
    const Line = struct {
        vtime_ns: u64 = 0,
        event: struct { lifecycle: []const u8 = "", event: []const u8 = "" } = .{},
    };
    var setup_ns: ?u64 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line_text| {
        if (std.mem.indexOf(u8, line_text, "setup_complete") == null and
            std.mem.indexOf(u8, line_text, "faults_stop") == null) continue;
        const parsed = std.json.parseFromSliceLeaky(Line, context.arena, line_text, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, parsed.event.lifecycle, "setup_complete")) setup_ns = parsed.vtime_ns;
        if (std.mem.eql(u8, parsed.event.event, "faults_stop")) return parsed.vtime_ns -| (setup_ns orelse return null);
    }
    return null;
}

/// A script's commands (name and mode) and faults (kind and node), in order, one line each.
fn script_shape(arena: std.mem.Allocator, text: []const u8) !struct {
    commands: []const u8,
    faults: []const u8,
    command_count: usize,
    fault_count: usize,
} {
    const Script = struct {
        commands: []const struct { name: []const u8, mode: []const u8 } = &.{},
        faults: []const struct { kind: []const u8, node: []const u8 = "" } = &.{},
    };
    const script = std.json.parseFromSliceLeaky(Script, arena, text, .{ .ignore_unknown_fields = true }) catch
        return .{ .commands = "", .faults = "", .command_count = 0, .fault_count = 0 };
    var commands: std.ArrayList(u8) = .empty;
    for (script.commands) |command| try commands.print(arena, "{s} {s}\n", .{ command.name, command.mode });
    var faults: std.ArrayList(u8) = .empty;
    for (script.faults) |fault| try faults.print(arena, "{s} {s}\n", .{ fault.kind, fault.node });
    return .{
        .commands = commands.items,
        .faults = faults.items,
        .command_count = script.commands.len,
        .fault_count = script.faults.len,
    };
}

fn failing_count(report: []const u8) u32 {
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    var failing: u32 = 0;
    for (branches[0..count]) |branch| failing += @intFromBool(branch.failing);
    return failing;
}

/// A JVM service, patched through its REPL at a moment: its futures stop losing money; and a
/// moment before the snapshot is refused.
fn check_clojure(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "clojure-bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5" };
    // Fork just after the setup snapshot (where it is depends on the guest's work so far): the
    // patch lands before the futures run.
    const probe = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    const snapshot_ms = snapshot_vtime_ms(probe) orelse {
        expect(context, false, "clojure: the setup snapshot's moment is reported", .{});
        return;
    };
    const moment = try std.fmt.allocPrint(context.arena, "{d}", .{snapshot_ms + 200});
    const fork = common ++ [_][]const u8{
        "--from-branch", "0", "--from-vtime-ms", moment, "--branches", "4",
    };
    const plain = try explore(context, &fork);
    const patched = try explore(context, &(fork ++ [_][]const u8{
        "--from-exec", "det-nodes exec bank /app/patch.sh",
    }));
    const fails = std.mem.indexOf(u8, plain, "4 branches, 0 with failing") == null;
    const fixed = std.mem.indexOf(u8, patched, "4 branches, 0 with failing properties") != null;
    const message = "clojure: futures fail, and pass once patched via the REPL";
    expect(context, fails and fixed, message, .{});
    const early = try explore(context, &(common ++ [_][]const u8{
        "--branch", "0", "--at-vtime-ms", "100", "--exec", "true",
    }));
    const refused = std.mem.indexOf(u8, early, "is not after the snapshot") != null;
    expect(context, refused, "moments before the snapshot are refused", .{});
}

/// The setup snapshot's virtual time from explore's report ("snapshot at setup_complete:
/// vtime=3.512s").
fn snapshot_vtime_ms(report: []const u8) ?u64 {
    const key = "snapshot at setup_complete: vtime=";
    const start = (std.mem.indexOf(u8, report, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, report, start, 's') orelse return null;
    const seconds = std.fmt.parseFloat(f64, report[start..end]) catch return null;
    return @trunc(seconds * std.time.ms_per_s);
}

/// Self-test level 1 (§14): the HTTP API under faults keeps every run and its result.
fn check_controller(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program", program, "--profile",  "controller", "--scenario", "controller",
        "--seed",    "2",     "--branches", "16",
    });
    const passes = std.mem.indexOf(u8, report, "16 branches, 0 with failing properties") != null;
    expect(context, passes, "controller: runs survive pauses, partitions and restarts", .{});
}

/// Adversarial guest (§14 level 2): clocks, sleeps, page faults and forks at once replay.
fn check_stress(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{ "--program", program, "--scenario", "stress", "--seed", "4" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "6" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 6, "stress: explored {d} branches", .{count});
    if (count == 0) return;
    var all_same = true;
    for ([_][]const u8{ "1", "4" }) |index| {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
        var replayed: [1]Branch = undefined;
        const ok = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
        all_same = all_same and ok;
    }
    expect(context, all_same, "stress: branches replay from fresh boots", .{});
}

/// Two shards, merged, give the timelines of one exploration.
fn check_shards(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "bank", "--seed", "21", "--branches", "6",
    };
    const whole = try explore(context, &common);
    var records: [2][]const u8 = undefined;
    for (&records, 0..) |*record, shard| {
        record.* = try std.fmt.allocPrint(context.arena, "{s}/shard-{d}.jsonl", .{
            context.scratch, shard,
        });
        const flag = try std.fmt.allocPrint(context.arena, "{d}/2", .{shard});
        const shard_flags = [_][]const u8{ "--shard", flag, "--record", record.* };
        _ = try explore(context, &(common ++ shard_flags));
    }
    const result = try run_kept(context, &.{ context.determinismo, "merge", records[0], records[1] });
    var unsharded: [branches_max]Branch = undefined;
    const count = parse_branches(whole, &unsharded);
    var merged: [branches_max]Branch = undefined;
    const merged_count = merged_branches(result.stdout, &merged);
    expect_all(context, &.{
        .{ "6 timelines in the whole run", count == 6 },
        .{ "as many merged", merged_count == count },
        .{ "the same timelines", count == merged_count and same_timelines(unsharded[0..count], merged[0..merged_count]) },
    }, "shards: two shards merged give the timelines of one run", .{});
}

/// The branches of a merged record (JSON lines).
fn merged_branches(record: []const u8, branches: []Branch) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        if (count == branches.len) break;
        const index_text = field_json(line, "\"index\":") orelse continue;
        const hash = field_json(line, "\"events_hash\":\"") orelse continue;
        branches[count] = .{
            .index = std.fmt.parseInt(u32, index_text, 10) catch continue,
            .events_hash = hash,
            .failing = false,
        };
        count += 1;
    }
    return count;
}

fn field_json(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    var end = start;
    while (end < line.len and line[end] != ',' and line[end] != '"') end += 1;
    return line[start..end];
}

/// An Antithesis-style project (Compose file, test templates in an image, SDK-format
/// assertions) explores, finds its bug, and replays.
fn check_compose(context: *Context) !void {
    const compose = "tests/antithesis-compat/bank/compose.yaml";
    const common = [_][]const u8{ "--compose", compose, "--scenario", "bank", "--seed", "3" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "8" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 8, "compose: explored {d} branches", .{count});
    const failing = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else null;
    const found = failing != null;
    expect(context, found, "compose: finds the lost update via SDK-format assertions", .{});
    const branch = failing orelse return;
    const index = try std.fmt.allocPrint(context.arena, "{d}", .{branch.index});
    const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "the same timeline", ran_one and same_timelines(&replayed, branches[0..count]) },
    }, "compose: branch {d} replays", .{branch.index});
}

/// Antithesis's "Invalid commands found": files in a test template named as commands that cannot
/// run (one not executable, one with no shebang) are never run, and the composer fails "test
/// templates hold only valid commands" with them; the template's valid command and its helper
/// are untouched.
fn check_templates(context: *Context) !void {
    const compose = "tests/antithesis-compat/templates/compose.yaml";
    const report = try explore(context, &.{ "--compose", compose, "--scenario", "checks", "--seed", "1", "--branches", "1" });
    const line_with = struct {
        fn line_with(text: []const u8, first: []const u8, second: []const u8) bool {
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, first) != null and std.mem.indexOf(u8, line, second) != null) return true;
            }
            return false;
        }
    }.line_with;
    expect_all(context, &.{
        .{ "the property fails", line_with(report, "FAIL always", "test templates hold only valid commands") },
        .{ "the valid command ran", line_with(report, "PASS reachable", "test command completed: singleton_driver_ok.sh") },
        .{ "the invalid files are no commands", std.mem.indexOf(u8, report, "anytime_forgot_chmod") == null and
            std.mem.indexOf(u8, report, "eventually_no_shebang") == null },
    }, "templates: files named as commands that cannot run are reported, never run", .{});
}

/// Compose's volumes, one-shots and healthchecks (tests/antithesis-compat/volumes): `init` ends
/// before `server` starts (its marker read there), the project's file is in server's image, the
/// client starts once server's healthcheck passes (its file there), server's write is seen through
/// the client's read-only mount, which takes no write. Any of it missing fails "no unexpected
/// container exits" (server's or client's exit) or "test commands exit successfully" (the driver's).
fn check_volumes(context: *Context) !void {
    const compose = "tests/antithesis-compat/volumes/compose.yaml";
    const report = try explore(context, &.{ "--compose", compose, "--scenario", "volumes", "--seed", "1", "--branches", "1" });
    const line_with = struct {
        fn line_with(text: []const u8, first: []const u8, second: []const u8) bool {
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, first) != null and std.mem.indexOf(u8, line, second) != null) return true;
            }
            return false;
        }
    }.line_with;
    expect_all(context, &.{
        .{ "the driver ran and passed", line_with(report, "PASS reachable", "test command completed: singleton_driver_volumes.sh") },
        .{ "no node exited unexpectedly", !line_with(report, "FAIL", "no unexpected container exits") },
        .{ "the commands exited 0", !line_with(report, "FAIL", "test commands exit successfully") },
    }, "volumes: a one-shot ends first, a healthcheck holds its dependents, a shared directory is shared, a project file is in the image", .{});
}

/// A Zig program's sites come from its table of lines (src/lines.zig: made when the system is
/// prepared, on the system disk), not from its debug information. A workload's drivers are
/// processes, and each one parsing its DWARF for its first assertion computed where the guest
/// would have idled: an exact stop is a timer that found no clock read, and 88% of a bank
/// timeline's were in that parse (411 a virtual second over six 60 s timelines, 14 without
/// it, 2026-11-17). The bound is between the two.
fn check_sites(context: *Context) !void {
    const arena = context.arena;
    const stops_a_second_max = 100;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "sites-events" });
    std.Io.Dir.cwd().deleteTree(context.io, events) catch {};
    const report = try explore(context, &.{
        "--program",   program, "--scenario", "bank", "--seed",       "3",    "--branches", "4",
        "--branching", "flat",  "--timeline", "10s",  "--events-dir", events,
    });
    try events_plain(context, events);
    // The program's assertions: each with its file, a line and the function it is in.
    var sites: u64 = 0;
    var unnamed: u64 = 0;
    var example: []const u8 = "none";
    for (0..4) |index| {
        const path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ events, index });
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 28)) catch continue;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const at = std.mem.indexOf(u8, line, "\"location\":{") orelse continue;
            const end = std.mem.indexOfScalarPos(u8, line, at, '}') orelse continue;
            const location = std.json.parseFromSliceLeaky(
                struct { file: []const u8 = "", line: u64 = 0, function: []const u8 = "" },
                arena,
                line[at + "\"location\":".len .. end + 1],
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            if (!std.mem.endsWith(u8, location.file, "bank_test.zig")) continue;
            sites += 1;
            if (location.line == 0 or location.function.len == 0) unnamed += 1;
            if (sites == 1) example = try std.fmt.allocPrint(arena, "bank_test.zig:{d} {s}", .{ location.line, location.function });
        }
    }
    // "... after <n> counter overflows, ...": the run's exact stops; "(one core; <s>s virtual".
    const stops: f64 = stops: {
        const end = std.mem.indexOf(u8, report, " counter overflows") orelse break :stops -1;
        var start = end;
        while (start > 0 and std.ascii.isDigit(report[start - 1])) start -= 1;
        break :stops std.fmt.parseFloat(f64, report[start..end]) catch -1;
    };
    const virtual_s = number_after(report, "(one core; ") orelse 0;
    const rate = if (virtual_s > 0) stops / virtual_s else -1;
    expect_all(context, &.{
        .{ "the program's assertions have their sites", sites > 0 },
        .{ "each with a line and a function", unnamed == 0 },
        .{ "the run's exact stops and virtual time are printed", stops >= 0 and virtual_s > 0 },
        .{ "the drivers read no debug information (exact stops a virtual second)", rate >= 0 and rate < stops_a_second_max },
    }, "sites: a Zig program's sites come from its table of lines ({d} assertions' sites, the first {s}), " ++
        "its drivers read no debug information ({d:.0} exact stops in {d:.1} virtual seconds: {d:.1} a second, under {d})", .{
        sites, example, stops, virtual_s, rate, stops_a_second_max,
    });
}

/// A Compose project of 20 services (tests/antithesis-compat/services; Vitess's Antithesis
/// project has 20, schema.nodes_max was 15): nineteen servers and a client, every one a node,
/// each server answering the client's test command by its own name. No faults: the command
/// asks every server.
fn check_services(context: *Context) !void {
    const compose = "tests/antithesis-compat/services/compose.yaml";
    const everyone = "s01,s02,s03,s04,s05,s06,s07,s08,s09,s10,s11,s12,s13,s14,s15,s16,s17,s18,s19,client";
    const report = try explore(context, &.{ "--compose", compose, "--scenario", "services", "--seed", "1", "--branches", "1", "--no-faults", everyone });
    const line_with = struct {
        fn line_with(text: []const u8, first: []const u8, second: []const u8) bool {
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, first) != null and std.mem.indexOf(u8, line, second) != null) return true;
            }
            return false;
        }
    }.line_with;
    expect_all(context, &.{
        .{ "the driver ran and passed", line_with(report, "PASS reachable", "test command completed: singleton_driver_services.sh") },
        .{ "no node exited unexpectedly", !line_with(report, "FAIL", "no unexpected container exits") },
        .{ "the commands exited 0", !line_with(report, "FAIL", "test commands exit successfully") },
    }, "services: a Compose project of 20 services, every one a node the others reach by name", .{});
}

/// Setup mode (Antithesis's): the setup alone, to setup_complete, its events kept, no timeline,
/// no catalog judged; exit status 0.
fn check_setup_mode(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "setup-mode-events" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "explore" });
    try argv.appendSlice(context.arena, context.machine);
    try argv.appendSlice(context.arena, &.{
        "--program", program, "--scenario", "bank", "--seed", "1", "--setup-only", "--events-dir", events,
    });
    const result = try run_kept(context, argv.items);
    const report = try std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
    const status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    var branches: [1]Branch = undefined;
    const setup_events = try std.fs.path.join(context.arena, &.{ events, "setup.jsonl" });
    const cwd = std.Io.Dir.cwd();
    const setup_text = cwd.readFileAlloc(context.io, setup_events, context.arena, .limited(1 << 26)) catch "";
    expect_all(context, &.{
        .{ "it exits 0", status == 0 },
        .{ "it says the setup completed", std.mem.indexOf(u8, report, "setup mode: setup complete at") != null },
        .{ "no timeline ran", parse_branches(report, &branches) == 0 },
        .{ "no catalog judged (nothing unreached)", std.mem.indexOf(u8, report, "assertions not reached") == null },
        .{ "the setup's events are kept", std.mem.indexOf(u8, setup_text, "setup_complete") != null },
    }, "setup mode: the setup alone, to setup_complete (exit {d})", .{status});
}

/// Branches from a moment of another branch (a nested snapshot) replay alone.
fn check_fork(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "21" };
    const parent = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    const setup_s = number_after(parent, "snapshot at setup_complete: vtime=") orelse 0;
    const branch_end_s = branch_vtime(parent) orelse 0;
    const ok_times = setup_s > 0 and branch_end_s > setup_s;
    expect_all(context, &.{
        .{ "the setup snapshot's moment is known", setup_s > 0 },
        .{ "the branch ends after it", branch_end_s > setup_s },
    }, "fork: the parent branch runs past its snapshot", .{});
    if (!ok_times) return;
    const middle_ms: u64 = @trunc((setup_s + branch_end_s) / 2 * 1000);
    const middle = try std.fmt.allocPrint(context.arena, "{d}", .{middle_ms});
    const fork = common ++ [_][]const u8{ "--from-branch", "0", "--from-vtime-ms", middle };
    const children = try explore(context, &(fork ++ [_][]const u8{ "--branches", "4" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(children, &branches);
    expect(context, count == 4, "fork: explored {d} branches from {d} ms of branch 0", .{
        count, middle_ms,
    });
    if (count == 0) return;
    const replay = try explore(context, &(fork ++ [_][]const u8{ "--branch", "2" }));
    var replayed: [1]Branch = undefined;
    const ran_one = parse_branches(replay, &replayed) == 1;
    expect_all(context, &.{
        .{ "the replay ran one timeline", ran_one },
        .{ "the same timeline", ran_one and same_timelines(&replayed, branches[0..count]) },
    }, "fork: a branch from the fork point replays alone", .{});
}

/// The end vtime (seconds) of the first branch line.
fn branch_vtime(report: []const u8) ?f64 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        return number_after(line, "vtime=");
    }
    return null;
}

/// The number (seconds, as printed with an `s`) right after `key` in `text`.
fn number_after(text: []const u8, key: []const u8) ?f64 {
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, text[start..end]) catch null;
}

/// Whether every branch of `a` has a twin in `b` (same index) with the same event hash.
fn same_timelines(a: []const Branch, b: []const Branch) bool {
    for (a) |branch| {
        const twin = for (b) |other| {
            if (other.index == branch.index) break other;
        } else return false;
        if (!std.mem.eql(u8, twin.events_hash, branch.events_hash)) return false;
    }
    return true;
}

/// Runs `determinismo explore` with the machine options; returns its whole output.
/// Snapshots saved to disk along a replay (saver.zig), each the pages changed since the one
/// before: the futures from each, loaded instead of booted to and replayed, are the futures a
/// replay to that moment forks.
/// A timeline's first event's virtual time, in seconds (its events in `directory`): where it
/// began, just past the snapshot it started from.
fn first_event_s(context: *Context, directory: []const u8, index: u32) !f64 {
    try events_plain(context, directory);
    const path = try std.fmt.allocPrint(context.arena, "{s}/branch-{d}.jsonl", .{ directory, index });
    const text = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(1 << 28));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const Line = struct { vtime_ns: ?u64 = null };
        const parsed = std.json.parseFromSliceLeaky(Line, context.arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.vtime_ns) |vtime_ns| return @as(f64, @floatFromInt(vtime_ns)) / std.time.ns_per_s;
    }
    return error.NoEvents;
}

fn check_saved(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/saved-tapes", .{context.scratch});
    const snapshots = try std.fmt.allocPrint(arena, "{s}/saved-snapshots", .{context.scratch});
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "11" };
    const events = try std.fmt.allocPrint(arena, "{s}/saved-events", .{context.scratch});
    std.Io.Dir.cwd().deleteTree(context.io, events) catch {};
    const ran = try explore(context, &(common ++ [_][]const u8{
        "--branches", "2", "--branching", "flat", "--tape-dir", tapes, "--events-dir", events,
    }));
    var lines = std.mem.tokenizeScalar(u8, ran, '\n');
    const vtime_s = while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ") or std.mem.indexOf(u8, line, " 1]") == null) continue;
        const text = field(line, "vtime=") orelse continue;
        break std.fmt.parseFloat(f64, std.mem.trimEnd(u8, text, "s")) catch continue;
    } else 0;
    // Between the branch's start (its first event, just past the setup snapshot) and its end: a
    // share of its end alone fell before its start once the setup took 0.73 s of a 1.8 s branch
    // ("not saved: 726000000ns is not after the branch's start", phoenixNAP, 2026-11-14).
    const start_s = try first_event_s(context, events, 1);
    const span_s = @max(vtime_s - start_s, 0);
    const moments = [_]u64{ @trunc((start_s + span_s * 0.4) * 1000), @trunc((start_s + span_s * 0.7) * 1000) };
    const tape = try std.fmt.allocPrint(arena, "{s}/branch-1.jsonl", .{tapes});
    const saved = try explore(context, &(common ++ [_][]const u8{
        "--tape",           tape,
        "--save-snapshots", snapshots,
        "--save-at-ms",     try std.fmt.allocPrint(arena, "{d},{d}", .{ moments[0], moments[1] }),
    }));
    const saved_count = std.mem.count(u8, saved, "saved snapshot ");
    var same = vtime_s > 0;
    for (moments) |ms| {
        const at = try std.fmt.allocPrint(arena, "{d}", .{ms});
        const replayed = try explore(context, &(common ++ [_][]const u8{
            "--tape", tape, "--from-vtime-ms", at, "--branches", "4", "--jobs", "2",
        }));
        const name = try std.fmt.allocPrint(arena, "{s}/b1-{d}", .{ snapshots, ms });
        const loaded = try explore(context, &(common ++ [_][]const u8{
            "--from-snapshot", name, "--branches", "4", "--jobs", "2",
        }));
        var from_replay: [branches_max]Branch = undefined;
        var from_disk: [branches_max]Branch = undefined;
        const count = parse_branches(replayed, &from_replay);
        same = same and count == 4 and parse_branches(loaded, &from_disk) == count and
            same_timelines(from_replay[0..count], from_disk[0..count]);
    }
    // The timeline itself on from a snapshot of it (--tape-snapshot, serve's moment replays):
    // the same timeline to its end, and a snapshot it saves later (against the one it loaded)
    // as good to go on from.
    var original: [branches_max]Branch = undefined;
    const original_count = parse_branches(ran, &original);
    const recorded = for (original[0..original_count]) |branch| {
        if (branch.index == 1) break branch;
    } else null;
    const later_ms: u64 = @trunc((start_s + span_s * 0.85) * 1000);
    const first = try std.fmt.allocPrint(arena, "{s}/b1-{d}", .{ snapshots, moments[0] });
    const resumed = try explore(context, &(common ++ [_][]const u8{ "--tape", tape, "--tape-snapshot", first }));
    // Saving stops it just past the moment saved (saver.zig).
    const saving = try explore(context, &(common ++ [_][]const u8{
        "--tape",           tape,
        "--tape-snapshot",  first,
        "--save-snapshots", snapshots,
        "--save-at-ms",     try std.fmt.allocPrint(arena, "{d}", .{later_ms}),
    }));
    const later = try std.fmt.allocPrint(arena, "{s}/b1-{d}", .{ snapshots, later_ms });
    const resumed_later = try explore(context, &(common ++ [_][]const u8{ "--tape", tape, "--tape-snapshot", later }));
    var on_count: u32 = 0;
    for ([_][]const u8{ resumed, resumed_later }) |output| {
        var parsed: [branches_max]Branch = undefined;
        const count = parse_branches(output, &parsed);
        const twin = recorded orelse break;
        if (count == 1 and parsed[0].index == 1 and std.mem.eql(u8, parsed[0].events_hash, twin.events_hash)) on_count += 1;
    }
    const saved_on = std.mem.count(u8, saving, "saved snapshot ") == 1;
    expect_all(context, &.{
        .{ "2 snapshots on disk", saved_count == 2 },
        .{ "the futures from each, loaded, are the ones a replay forks there", same },
        .{ "the timeline on from a snapshot of it is the timeline", on_count == 2 and saved_on },
    }, "saved: {d} snapshots on disk along branch 1 " ++
        "(at {d} and {d} ms); the futures from each, loaded, are the ones a replay forks there; " ++
        "the timeline on from the first, and from one it saved at {d} ms, is the timeline ({d} of 2)", .{
        saved_count, moments[0], moments[1], later_ms, on_count,
    });
    if (saved_count != 2) std.debug.print("{s}\n", .{saved});
    if (on_count != 2 or !saved_on) std.debug.print("{s}\n{s}\n{s}\n", .{ resumed, saving, resumed_later });
}

fn explore(context: *Context, extra: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "explore" });
    try argv.appendSlice(context.arena, context.machine);
    try argv.appendSlice(context.arena, extra);
    const result = try run_kept(context, argv.items);
    // Exit status 3 means "properties failed", which the checks expect; others are errors.
    const status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    // Refusals some checks expect (a tape on other inputs, a moment before the snapshot, a
    // directory of another run's).
    const refusal = std.mem.indexOf(u8, result.stderr, "recorded with") != null or
        std.mem.indexOf(u8, result.stderr, "is not after the snapshot") != null or
        std.mem.indexOf(u8, result.stderr, "holds run") != null or
        std.mem.indexOf(u8, result.stderr, "replay diverged from its tape") != null;
    if (status != 0 and status != 3 and !refusal) {
        std.debug.print("e2e: determinismo exited with {d}:\n{s}\n", .{ status, result.stderr });
    }
    return std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
}

/// Runs a command (determinismo's causality, extract, a replay...) and keeps its output as
/// `explore` does, for the check that judges it.
/// Whether a snapshot on disk has every base its load follows (`<name>.state`'s header names its
/// base at byte 40, 64 bytes, snapshot.zig's DiskHeader), in its own directory.
fn snapshot_chain_whole(context: *Context, state_path: []const u8) bool {
    const directory = std.fs.path.dirname(state_path) orelse return false;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = state_path;
    for (0..256) |_| {
        var header: [104]u8 = undefined;
        const file = std.Io.Dir.cwd().openFile(context.io, path, .{}) catch return false;
        defer file.close(context.io);
        const read = file.readPositionalAll(context.io, &header, 0) catch return false;
        if (read != header.len) return false;
        const base = std.mem.sliceTo(header[40..104], 0);
        if (base.len == 0) return true;
        path = std.fmt.bufPrint(&path_buffer, "{s}/{s}.state", .{ directory, base }) catch return false;
    }
    return false;
}

fn run_kept(context: *Context, argv: []const []const u8) !std.process.RunResult {
    // A recursive grep reads ended timelines' events as text: their plain copies beside them.
    if (argv.len > 2 and std.mem.eql(u8, argv[0], "grep") and std.mem.indexOfScalar(u8, argv[1], 'r') != null) {
        try events_plain(context, argv[argv.len - 1]);
    }
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv });
    const status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    const output = try std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
    output_keep(context, argv, status, output);
    return result;
}

/// Every ended timeline's events under `directory` (`branch-<n>.jsonl.zst`, src/event_files.zig)
/// also as the plain `branch-<n>.jsonl` beside it, for the checks that read or grep them as text.
/// Not a directory (a single file grepped): nothing to do.
fn events_plain(context: *Context, directory_path: []const u8) !void {
    var directory = std.Io.Dir.cwd().openDir(context.io, directory_path, .{ .iterate = true }) catch return;
    defer directory.close(context.io);
    var walker = try directory.walk(context.arena);
    defer walker.deinit();
    while (try walker.next(context.io)) |item| {
        if (item.kind != .file or !std.mem.endsWith(u8, item.path, ".jsonl.zst")) continue;
        const plain = item.path[0 .. item.path.len - ".zst".len];
        directory.access(context.io, plain, .{}) catch {
            const file = try directory.openFile(context.io, item.path, .{});
            defer file.close(context.io);
            var in_buffer: [64 * 1024]u8 = undefined;
            var reader = file.reader(context.io, &in_buffer);
            // Its own window: without one it writes into the file writer's buffer, too small.
            const zstd = std.compress.zstd;
            const window = try context.arena.alloc(u8, zstd.default_window_len + zstd.block_size_max);
            var stream: zstd.Decompress = .init(&reader.interface, window, .{});
            const out = try directory.createFile(context.io, plain, .{ .truncate = true });
            defer out.close(context.io);
            var out_buffer: [64 * 1024]u8 = undefined;
            var writer = out.writer(context.io, &out_buffer);
            _ = stream.reader.streamRemaining(&writer.interface) catch |err| switch (err) {
                error.ReadFailed => return stream.err orelse error.ReadFailed,
                else => |other| return other,
            };
            try writer.interface.flush();
        };
    }
}

/// Keeps an exploration's command, exit status and output in the scratch directory, for the
/// check that judges it to name when it fails.
fn output_keep(context: *Context, argv: []const []const u8, status: u8, output: []const u8) void {
    const directory = std.fs.path.join(context.arena, &.{ context.scratch, "outputs" }) catch return;
    std.Io.Dir.cwd().createDirPath(context.io, directory) catch return;
    context.output_count += 1;
    const path = std.fmt.allocPrint(context.arena, "{s}/{d}.log", .{ directory, context.output_count }) catch return;
    const command = std.mem.join(context.arena, " ", argv) catch return;
    const header = std.fmt.allocPrint(context.arena, "$ {s}\nexit {d}\n\n", .{ command, status }) catch return;
    const contents = std.mem.concat(context.arena, u8, &.{ header, output }) catch return;
    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = contents }) catch return;
    context.outputs.append(context.arena, path) catch return;
}

/// The moment (`{"vtime_ns":..,"branches":..,"rip":"0x..","cr3":`) of the first line said
/// after `prefix` whose stop is `at` (its `"rip":"0x..","cr3":`), or null.
fn first_moment(output: []const u8, prefix: []const u8, at: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, output, from, prefix)) |line_at| {
        const start = line_at + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, output, start, '\n') orelse output.len;
        from = end;
        const line = output[start..end];
        const found = std.mem.indexOf(u8, line, at) orelse continue;
        return line[0 .. found + at.len];
    }
    return null;
}

fn parse_branches(report: []const u8, branches: []Branch) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        if (count == branches.len) break;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const index_text = std.mem.trim(u8, line["[branch ".len..close], " ");
        const hash = field(line, "events_hash=") orelse continue;
        const failing = field(line, "failing=") orelse continue;
        branches[count] = .{
            .index = std.fmt.parseInt(u32, index_text, 10) catch continue,
            .events_hash = hash,
            .failing = !std.mem.eql(u8, failing, "0"),
        };
        count += 1;
    }
    return count;
}

/// A moment inside a report's timeline (its last `[branch` line's), as `--at-vtime-ms` takes it:
/// `fraction` of the way from its setup snapshot to its end. Timelines' lengths follow the clock:
/// on taken branches the bank's tape timeline ended at 1.05 s, before the 1500 ms the check once
/// named.
fn moment_inside(arena: std.mem.Allocator, report: []const u8, fraction: f64) ![]const u8 {
    var setup_s: ?f64 = null;
    var end_s: ?f64 = null;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const key = if (std.mem.indexOf(u8, line, "snapshot at setup_complete:") != null)
            &setup_s
        else if (std.mem.startsWith(u8, line, "[branch "))
            &end_s
        else
            continue;
        const text = field(line, "vtime=") orelse continue;
        key.* = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, text, "s")) catch continue;
    }
    const end = end_s orelse return error.NoTimeline;
    const start = setup_s orelse 0;
    return std.fmt.allocPrint(arena, "{d}", .{@as(u64, @intFromFloat((start + (end - start) * fraction) * 1000))});
}

fn field(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return line[start..end];
}

/// A JSON line's number after `key` (`"vtime_ns":123,`).
fn field_u64(line: []const u8, comptime key: []const u8) ?u64 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

test field_u64 {
    try std.testing.expectEqual(@as(?u64, 123), field_u64("{\"seq\":1,\"vtime_ns\":123,\"x\":2}", "\"vtime_ns\":"));
    try std.testing.expectEqual(@as(?u64, null), field_u64("{}", "\"vtime_ns\":"));
}

fn expect(context: *Context, ok: bool, comptime format: []const u8, arguments: anytype) void {
    const status = if (ok) "PASS" else "FAIL";
    std.debug.print("{s} " ++ format ++ "\n", .{status} ++ arguments);
    if (!ok) {
        context.failures += 1;
        for (context.outputs.items) |path| std.debug.print("  output: {s}\n", .{path});
    }
    context.outputs.clearRetainingCapacity();
}

/// Whether the report has every line; prints those it lacks (why its check fails).
fn has_lines(report: []const u8, lines: []const []const u8) bool {
    var all = true;
    for (lines) |line| if (std.mem.indexOf(u8, report, line) == null) {
        std.debug.print("  missing: {s}\n", .{line});
        all = false;
    };
    return all;
}

/// Whether the report has a line of that verdict ("PASS sometimes") for that property, whatever
/// its counts; prints it when it lacks one.
fn has_prefix_line(report: []const u8, verdict: []const u8, message: []const u8) bool {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, verdict) and property_line(trimmed, message)) return true;
    }
    std.debug.print("  missing: {s} ... {s}\n", .{ verdict, message });
    return false;
}

/// A condition of a check, named: a failing check says which of its conditions failed.
const Condition = struct { []const u8, bool };

/// A check of several conditions: it passes when all hold, and a failure names those that did
/// not (and the outputs judged), never only that the whole failed.
fn expect_all(context: *Context, conditions: []const Condition, comptime format: []const u8, arguments: anytype) void {
    var ok = true;
    for (conditions) |condition| ok = ok and condition[1];
    if (!ok) {
        std.debug.print("  failed:", .{});
        for (conditions) |condition| if (!condition[1]) std.debug.print(" {s};", .{condition[0]});
        std.debug.print("\n", .{});
    }
    expect(context, ok, format, arguments);
}

test parse_branches {
    const report = "[determinismo] inputs 1\n" ++
        "[branch    3] seed=ab shutdown vtime=2.9s wall=0.4s events=488 events_hash=5167 " ++
        "failing=1  FAIL \"total\"\n" ++
        "[branch   10] seed=cd shutdown vtime=2.1s wall=0.1s events=99 events_hash=c66e " ++
        "failing=0\n";
    var branches: [branches_max]Branch = undefined;
    try std.testing.expectEqual(@as(u32, 2), parse_branches(report, &branches));
    try std.testing.expectEqual(@as(u32, 3), branches[0].index);
    try std.testing.expect(branches[0].failing);
    try std.testing.expectEqualStrings("c66e", branches[1].events_hash);
}
