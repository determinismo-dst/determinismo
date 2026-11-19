// SPDX-License-Identifier: MIT
//! `determinismo serve`: the controller's HTTP API (ARCHITECTURE.md §9), for people, CI and
//! agents. A run is one `determinismo explore` child process with its own directory:
//!
//!   <data>/runs/<id>/request.json   what was asked
//!   <data>/runs/<id>/output.log     its output
//!   <data>/runs/<id>/record.jsonl   its results (explore --record)
//!   <data>/runs/<id>/tapes/         the tapes of its branches
//!   <data>/runs/<id>/events/        every branch's events (explore --events-dir), and their
//!                                   database (store.zig), where every question about the run
//!                                   is answered
//!
//! Endpoints (JSON in, JSON out):
//!   GET  /                   the web UI (ui/index.html): runs, properties, logs, search, map
//!   GET  /export.html        the window viewer (ui/export.html): a failing example's Export
//!                            embeds its window's document in it, a page that plays it back
//!   POST /runs               {program | compose, scenario?, profile?, seed?, branches?, jobs?,
//!                             strategy?, from_branch?, from_vtime_ms?}  -> {id}
//!   GET  /runs               every run: {id, state, scenario, system, from_branch, from_run}
//!   GET  /runs/<id>          its state, its request (as asked, its seed drawn), its record (run,
//!                             snapshot, summary, changed) and stats (timelines,
//!                             failing_timelines, vtime_ns, wall_ns, behaviors, behaviors_once
//!                             (reached by one timeline alone: over the timelines, the new ones
//!                             the next is expected to find), timelines_once (those that reached
//!                             one: over the timelines, the chance the next finds any), events)
//!   GET  /runs/<id>/timelines  every finished timeline, with the properties it violates
//!   GET  /runs/<id>/properties every property with its verdict across the timelines so far
//!   GET  /runs/<id>/logged   JSON lines {node, level, template, timelines, lines, first_timeline,
//!                            first_vtime_ns, example}: what the nodes logged as errors, as
//!                            templates (store.logged_sql), panics first
//!   GET  /runs/<id>/discovery  {points: [[timelines, behaviors], ...]}: new behavior discovery
//!   GET  /runs/<id>/output   its output, as text
//!   GET  /runs/<id>/automations  JSON lines {property, timeline, vtime_ns, exec, output}: the
//!                             request's and profile's automations (schema.Automation) run at
//!                             each failing property's first counterexample once the run ended
//!   POST /runs/<id>/replay   {branch, at_vtime_ms? | until? rewind_ms?, inject? {node, path,
//!                             content (base64), mode?}, exec? | steps? |
//!                             session?} -> its output (session: that session's script replayed);
//!                             at a moment, on from the newest snapshot of the timeline before it,
//!                             one saved just before it when that is far (replay_snapshots.zig)
//!   POST /runs/<id>/recover  {branch, vtime_ns, window_ms?} -> JSON lines: the output lines of
//!                             the 10 s (window_ms) before the moment that retroactive logging
//!                             left out while exploring, from a replay to it
//!   POST /runs/<id>/causality {branch, property, points?, futures?, refine?, moments_max?,
//!                            jump_min?, gap_min_ms?, planner?, verdict?, explain_exec?} -> {id} (in the background:
//!                            causality.zig; its snapshots kept in the run's snapshots/)
//!   POST /runs/<id>/shrink {branch, property, timelines?}  the fewest faults that failing
//!                            timeline needs (`determinismo shrink`, in the background): {id}
//!   GET  /runs/<id>/shrink    every shrinking: [{id, of, done, result, progress}]
//!   POST /runs/<id>/shrink/<n>/stop
//!   GET  /samples.json        the samples this host offers on the learn page (samples.json in
//!                            its data directory), 404 without
//!   POST /runs/<id>/explain {branch, property, faults?, variants?}  which details of a failing
//!                            timeline's last faults it needed (`determinismo explain`, in the
//!                            background): {id}
//!   GET  /runs/<id>/explain   every explanation: [{id, of, done, result, progress}]
//!   POST /runs/<id>/explain/<n>/stop
//!   GET  /runs/<id>/causality  every analysis: [{id, done, of: {branch, property, failure_ms,
//!                            snapshot_ms, futures, planner}, points: [...]}]
//!   GET  /runs/<id>/causality/<n>/explained/<k>/logs?grep=<text>  the node output of its
//!                            explanation's future k: {lines: [{vtime_ns, source, text}], matched}
//!   GET  /runs/<id>/causality/<n>  one: {id, done, of, points: [{vtime_ms, futures, failing,
//!                            probability, low, high}], fault_effects?: {faults: [{fault, with,
//!                            with_failing}], futures, failing}, line_effects?: {lines: [{line,
//!                            with, with_failing}], futures, failing}}
//!   GET  /runs/<id>/timelines?offset=<n>  the timelines after the first n ingested
//!   GET  /runs/<id>/failures  every failing evaluation, as map marks (JSON lines), kept
//!   POST /runs/<id>/extract  {branch, at_vtime_ms, node, path} -> the file's bytes at that moment
//!   GET  /runs/<id>/notebook  {source}; PUT {source}: the run's notebook (JavaScript cells)
//!   GET  /runs/<id>/findings {previous, findings: [{message, kind, finding, rare}]}: what changed
//!                             since the previous finished run of the same system and scenario
//!                             (new, ongoing, resolved, or unseen: maybe missed by chance)
//!   POST /runs/<id>/query    {condition, preceded_by?, followed_by?, not_preceded_by?,
//!                             not_followed_by?, within?, branch?, up_to_vtime?, limit?,
//!                             output?: events|count|branches} -> JSON lines (query.zig)
//!   POST /runs/<id>/events   {pipeline, branch?, limit?, output?} -> JSON lines: an event set
//!                             (event_sets.zig)
//!   POST /runs/<id>/sql      {sql}: one SELECT on the run's events database -> its rows
//!   POST /runs/<id>/stream   {properties?: [names]} -> its properties as they change, a JSON
//!                             object a line (Antithesis's run stream): NEW_PROPERTIES_ADDED,
//!                             PROPERTIES_FAILED (each with a sample: its first failing
//!                             timeline and moment), then RUN_FINALIZED with every verdict
//!
//! Each request is answered by a thread of its own (a replay takes minutes; a query over a long
//! run, seconds), with its own allocations and database connection. Runs, jobs and the
//! databases are shared: a mutex guards runs and jobs, and a run's database is attached once (a
//! DuckDB instance holds them all) and brought up to date by whoever asks first. A thread
//! watches runs meanwhile: it reaps them, and ingests the timelines that finished.
const std = @import("std");
const regex = @import("regex");
const main_zig = @import("main.zig");
const event_files = @import("event_files.zig");
const build_options = @import("build_options");
const assert = std.debug.assert;
const linux = std.os.linux;
const query = @import("query.zig");
const quint = @import("quint.zig");
/// Where sessions' timelines begin in a run's indices (tape.zig).
const event_sets = @import("event_sets.zig");
const extract = @import("extract.zig");
const duckdb = @import("duckdb.zig");
const store = @import("store.zig");
const holders = @import("holders.zig");
const replay_snapshots = @import("core").replay_snapshots;
const activity = @import("activity.zig");
const cpus = @import("cpus.zig");
const host_core = @import("host_core.zig");
const host_runs = @import("runs.zig");
const VM = @import("core").vm;
const Decisions = @import("core").decisions;
const bandit_zig = @import("bandit.zig");
const Machine = @import("machine.zig");
const egress_host = @import("egress_host.zig");
const schema = @import("determinismo").schema;

pub const Options = struct {
    /// "address:port", e.g. 127.0.0.1:7878. Bind to loopback unless the network is trusted.
    listen: []const u8,
    /// serve --ui: the UI page read from this file at each request, the built-in one without
    /// it (a UI change then ships as a copy of src/ui/index.html: no rebuild, no restart).
    ui_path: ?[]const u8 = null,
    data_directory: []const u8,
    /// How runs boot: --kernel, --initrd, --memory-mib, --cache, ... passed to every explore.
    machine: []const []const u8,
    /// This executable, to start runs with.
    self: []const u8,
    /// Run when a run finishes, through /bin/sh with {dir} and {id} replaced: long-term
    /// storage (e.g. `rclone copy {dir} s3:bucket/runs/{id}`). Null keeps runs local only.
    archive: ?[]const u8 = null,
    /// Babashka, which evaluates notebooks (Clojure cells; notebook.clj).
    bb: []const u8 = "bb",
    /// A run's snapshots on disk (causality analysis saves its timelines' moments there) go
    /// when none was saved for this long.
    snapshots_keep_ns: u64 = 24 * std.time.ns_per_hour,
    /// Each failing property's first failing timeline saved to disk as soon as it is found,
    /// unless the explorer's ladder did (`--failure-snapshots`). Off by default (2026-10-30): a
    /// replay and disk for every failing property of every run, for analyses that are rare and
    /// replay the timeline themselves when nothing is saved.
    failure_snapshots: bool = false,
    /// Each failing property's first failing timeline analyzed as soon as it is found, in the
    /// background (`--failure-analysis`; off by default: see failures_analyze).
    failure_analysis: bool = false,
    /// A session no request touched for this long is ended (`--session-idle-minutes`): its
    /// client went away (a killed script, a closed REPL) and would hold its machine and one of
    /// sessions_max slots until serve restarts.
    session_idle_ns: u64 = 30 * std.time.ns_per_min,
    /// A machine asked for is given up when it is not up after this long
    /// (`--machine-start-seconds`): it waits for a CPU of its pool, which others' VMs may hold.
    machine_start_ns: u64 = 600 * std.time.ns_per_s,
    /// How many machines share a CPU (`--machines-per-cpu`, each machine's `run` told so): fast
    /// VMs among themselves, never with a deterministic VM (cpus.zig's take_shared).
    machines_per_cpu: u32 = cpus.machines_per_cpu_default,
};

const runs_max = host_runs.runs_max;
const jobs_max = 256;
// A notebook with its actions' results, an uploaded strategy.
const request_size_max = 64 << 20;
/// Responses (and the run files they are made of) grow as needed up to this: a query over a
/// long run's every timeline is large.
const response_size_max = 256 << 20;
const arguments_max = 64;
/// Requests answered at once (each a thread); past it, 503.
const requests_max = 64;
/// Rows a request's own SQL answers with at most.
const sql_rows_max = 100_000;
/// DuckDB's share of the host: the runs need the rest.
const database_threads = 4;
/// A cap, not a reservation. One instance holds every attached run: loads of runs with GBs of
/// events at once (hunt runs 1468 and 1470: 2.8 and 1.7 GB, one alone peaking at 2.1 GB) ran
/// 4 GB out of memory, each query on them refused after.
const database_memory_mib = 16384;
/// How often the watcher reaps runs and ingests their finished timelines.
const watch_interval_ns = std.time.ns_per_s;
/// How often it removes runs' snapshots past their time (Options.snapshots_keep_ns).
const snapshots_sweep_interval = 600; // Watches.
/// How often it looks for new failures to save to disk (failures_snapshot).
const failures_watch_interval = 15; // Watches.
const detach_watch_interval = 30; // Watches.
/// How often it ends sessions idle past their time (sessions_idle_end).
const sessions_idle_interval = 60; // Watches.

const Run = struct {
    id: u32,
    pid: linux.pid_t,
    /// Exit status once finished: 0 all properties passed, 3 some failed, others errors.
    status: ?u32 = null,
    /// Its babashka nREPL server, once started (notebook.clj's names, over this API).
    nrepl_port: ?u16 = null,
    /// Stopped on request (POST /runs/<id>/stop).
    stopped: bool = false,
    /// Draining on request (POST /runs/<id>/stop?drain=1): no timeline starts, those running
    /// end; stopped once its explorer is gone (drained_mark), resumable then and not before.
    draining: bool = false,
    /// Started by an earlier server and still running: not its child, so watched with kill(0)
    /// and judged by its record once gone.
    adopted: bool = false,
    /// Nothing more for the watcher to ingest: ingested since it finished, or found finished
    /// (ingested when first asked about).
    complete: bool = false,
};

const nrepl_port_base = 17000;

/// A causality analysis (causality.zig) of a run's branch, in the background.
/// What serve started for a run: an analysis (POST /runs/<id>/causality), or a first failure saved
/// to disk (failures_snapshot).
const Job = struct {
    run: u32,
    /// An analysis's number (`causality-<n>.jsonl`); a save's timeline.
    index: u32,
    pid: linux.pid_t,
    done: bool = false,
    kind: enum { causality, snapshot, shrink, explain } = .causality,
};

/// What the threads share: runs and jobs (under `mutex`), and the runs' databases.
const Shared = struct {
    options: Options,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    runs: [runs_max]Run = undefined,
    run_count: u32 = 0,
    jobs: [jobs_max]Job = undefined,
    job_count: u32 = 0,
    /// One instance with every run's database attached (as run_<id>) once asked for.
    database: duckdb.Database,
    /// By run id: attached yet, and the lock its attach and detach hold (briefly: an attach of a
    /// database of an earlier build brings it up to date in place under it, store.schema_ensure).
    attached: [runs_max]bool = @splat(false),
    /// Connections open on each run's database (run_connect to run_release), and when it was
    /// last used: a finished run's unused one is detached (detach_idle).
    users: [runs_max]u32 = @splat(0),
    used_s: [runs_max]i64 = @splat(0),
    store_locks: [runs_max]std.Io.Mutex = @splat(.init),
    /// By run id: held by its one ingest at a time (run_update), with what it brought in so far
    /// (`ingested`, `replays_ingested`, `setup_ingested`). Taken before the store lock.
    ingest_locks: [runs_max]std.Io.Mutex = @splat(.init),
    /// By run id: its kept answers' and their generation's.
    answer_locks: [runs_max]std.Io.Mutex = @splat(.init),
    /// By run id: the newer run that took its events directory (an exploration given the same
    /// --events-dir again, emptied: a smoke script's), 0 for none. Its events went with it.
    taken: [runs_max]u32 = @splat(0),
    /// By run id: how many ingests brought timelines in, and the answers that change only
    /// then (a running run's page asks for them every few seconds).
    generations: [runs_max]u64 = @splat(0),
    /// By run id: the size of timelines.jsonl at the last ingest (it only grows: the same size,
    /// nothing to bring in).
    ingested: [runs_max]u64 = @splat(0),
    /// By run id: the size of its replays' results (record.jsonl.replays) at the last ingest.
    replays_ingested: [runs_max]u64 = @splat(0),
    /// A run ended without a timeline: its setup's events taken (run_update).
    setup_ingested: [runs_max]bool = @splat(false),
    /// By run id: whether coverage_gate has its answer (covered, asked without it, or stopped).
    coverage_known: [runs_max]bool = @splat(false),
    answers: [runs_max][@typeInfo(Kept).@"enum".field_names.len]Answer = @splat(@splat(.{})),
    requests: std.atomic.Value(u32) = .init(0),
    /// Interactive sessions (POST /runs/<id>/session): replays held at a moment, taking steps.
    sessions: [sessions_max]Session = @splat(.{}),
    session_next: u32 = 1,
    /// Machines (POST /machines): fast VMs, what agent sandboxes and CI are made of.
    machines: [machines_max]Machine = @splat(.{}),
    machine_next: u32 = 1,
    /// By run id: its moment replays saving a snapshot now (replay_snapshots_use): no removal
    /// takes what they save against.
    replays_saving: [runs_max]u16 = @splat(0),

    fn lock(shared: *Shared) void {
        shared.mutex.lockUncancelable(shared.io);
    }

    fn unlock(shared: *Shared) void {
        shared.mutex.unlock(shared.io);
    }
};

/// What a run's database answers that changes only when timelines arrive.
const Kept = enum { stats, timelines, properties, discovery, failures, logged };
const Answer = struct { generation: u64 = 0, bytes: ?[]u8 = null };

/// A request being answered: what it shares, and what it allocates (gone with it).
const sessions_max = 8;
const machines_max = 64;
/// What a session keeps of its output that no reply took yet: its tail beyond this.
const session_log_max = 64 << 20;

/// A replay held at a moment (explore --exec-interactive), its steps sent as they come: a REPL
/// into the guest (infra/host/nrepl-proxy.py's), or a person's commands one by one. The machine
/// is paused between steps, so the session is a function of its steps. A live one (--exec-live)
/// runs on between steps, each at a moment of its own. Either is a timeline of its run from its
/// moment on (explore --extend): its steps and what came from outside on its tape, its events
/// in the run's, replayed, queried and opened by another session as any timeline.
const Session = struct {
    /// 0: a free slot.
    id: u32 = 0,
    run: u32 = 0,
    pid: linux.pid_t = 0,
    input: linux.fd_t = -1,
    output: linux.fd_t = -1,
    /// One request at a time: its start, a step, its end (session_claim to session_release).
    busy: std.atomic.Value(bool) = .init(false),
    /// When its last request ended (monotonic): sessions_idle_end ends it past
    /// Options.session_idle_ns.
    used_ns: u64 = 0,
    /// Its output that no reply took yet, read as it comes (its reader thread's: a live
    /// session's machine never waits on a full pipe), and whether it ended.
    mutex: std.Io.Mutex = .init,
    log: std.ArrayList(u8) = .empty,
    ended: bool = false,
    reader: ?std.Thread = null,
    /// The timeline it records in its run (explore --extend), as its explorer said it: the one
    /// it was opened on up to its moment, its own after. `timeline_none`: not said so far.
    timeline: std.atomic.Value(u32) = .init(timeline_none),
    /// The address its relay listens on (its request's ingress.listen), from its start: its
    /// explorer opens the listener only when the guest first asks for a connection, so a
    /// second session asking for the address meanwhile finds it free (listen_claim).
    listen: [listen_size_max]u8 = undefined,
    listen_size: u8 = 0,
    /// Its forks (sdk.fork in the guest): the futures started from each saved machine, and what
    /// starting them takes (the replay's arguments without its tape, its directory, serve's).
    forks: Forks = .{},
};

const timeline_none = std.math.maxInt(u32);
const listen_size_max = 64;
const forks_max = 16;

const Forks = struct {
    /// What starting a run takes (its arena the reader's own each time): the reader starts
    /// each fork's futures as a run of the server's.
    server: ?Server = null,
    /// The count the guest asked last; its snapshot comes next.
    asked: u32 = 0,
    /// What the reader has of a line not ended yet.
    carry: std.ArrayList(u8) = .empty,
    started: [forks_max]Fork = undefined,
    count: u32 = 0,
};

const Fork = struct { snapshot: []const u8, run: u32, futures: u32 };

/// What explore prints once a session's step is done (vm.zig's steps_read).
const step_done_marker = "[determinismo] step done\n";

const Server = struct {
    shared: *Shared,
    options: Options,
    io: std.Io,
    arena: std.mem.Allocator,
    /// What DuckDB said, when a request failed on the database.
    detail: ?[]const u8 = null,
    /// The request's query string (after `?`), "" for none.
    query_string: []const u8 = "",
};

/// What DuckDB said, kept past the connection that said it: the failure lives in the connection,
/// which every handler releases (a defer) before `handle` prints the error (run 1334's SQL error
/// came back as 2048 bytes of 0xAA, freed memory).
fn database_failed(server: *Server, failure: *const duckdb.Failure) void {
    server.detail = server.arena.dupe(u8, failure.text()) catch "the database failed (no memory for its message)";
}

test "a database failure's text outlives its connection" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var server: Server = .{
        .shared = undefined,
        .options = undefined,
        .io = undefined,
        .arena = arena_state.allocator(),
    };
    var failure: duckdb.Failure = .{};
    const message = "Binder Error: no such column (DuckDB error 1)";
    @memcpy(failure.buffer[0..message.len], message);
    failure.len = message.len;
    database_failed(&server, &failure);
    @memset(&failure.buffer, 0xaa); // Its connection released.
    try std.testing.expectEqualStrings(message, server.detail.?);
}

pub fn serve(arena: std.mem.Allocator, io: std.Io, options: Options) !void {
    const shared = try arena.create(Shared);
    var failure: duckdb.Failure = .{};
    shared.* = .{
        .options = options,
        .io = io,
        .database = duckdb.Database.open(":memory:", .{
            .threads = database_threads,
            .memory_limit_mib = database_memory_mib,
            // A run's events loaded as they stream, and what does not fit spills to disk: hunt
            // run 1468's 2.8 GB of event files ran the 4 GB database (shared by every run's
            // loads and queries, in memory, with nowhere to spill) out of memory loading them,
            // every query on the run refused after; alone the load peaks at 2.1 GB.
            .preserve_insertion_order = false,
            .temp_directory = try std.fs.path.join(arena, &.{ options.data_directory, "duckdb-spill" }),
        }, &failure) catch |err| {
            std.debug.print("[determinismo] the events database: {s}\n", .{failure.text()});
            return err;
        },
    };
    const runs_directory = try std.fs.path.join(arena, &.{ options.data_directory, "runs" });
    try std.Io.Dir.cwd().createDirPath(io, runs_directory);
    var server: Server = .{ .shared = shared, .options = options, .io = io, .arena = arena };
    try runs_discover(&server);
    machines_adopt(&server);
    // The first address must be there; the others (a VPN's, as Tailscale's) may come up later.
    var addresses = std.mem.tokenizeScalar(u8, options.listen, ',');
    const first = addresses.next() orelse return error.BadListen;
    const listener = try listen(first);
    while (addresses.next()) |address| {
        const later = try std.Thread.spawn(.{}, listen_later, .{ shared, address });
        later.detach();
    }
    const watcher = try std.Thread.spawn(.{}, watch, .{shared});
    watcher.detach();
    std.debug.print("[determinismo] serving on http://{s} (data in {s})\n", .{
        first, options.data_directory,
    });
    accept_loop(shared, listener);
}

/// Listens on `address` once it can (retrying while the address is not up yet), then answers.
fn listen_later(shared: *Shared, address: []const u8) void {
    var told = false;
    const listener = while (true) {
        break listen(address) catch |err| {
            if (!told) std.debug.print("[determinismo] not on http://{s} yet ({s}): retrying\n", .{
                address, @errorName(err),
            });
            told = true;
            const pause: linux.timespec = .{ .sec = 5, .nsec = 0 };
            _ = linux.nanosleep(&pause, null);
            continue;
        };
    };
    std.debug.print("[determinismo] serving on http://{s} too\n", .{address});
    accept_loop(shared, listener);
}

fn accept_loop(shared: *Shared, listener: linux.fd_t) noreturn {
    while (true) {
        const client = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(client) != .SUCCESS) continue;
        const fd: linux.fd_t = @intCast(client);
        if (shared.requests.fetchAdd(1, .monotonic) >= requests_max) {
            _ = shared.requests.fetchSub(1, .monotonic);
            respond(fd, 503, "text/plain", "busy\n");
            _ = linux.close(fd);
            continue;
        }
        const thread = std.Thread.spawn(.{}, answer, .{ shared, fd }) catch {
            _ = shared.requests.fetchSub(1, .monotonic);
            respond(fd, 503, "text/plain", "busy\n");
            _ = linux.close(fd);
            continue;
        };
        thread.detach();
    }
}

/// A request's thread: its allocations go with it.
fn answer(shared: *Shared, client: linux.fd_t) void {
    defer _ = shared.requests.fetchSub(1, .monotonic);
    defer _ = linux.close(client);
    var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer request_arena.deinit();
    var server: Server = .{
        .shared = shared,
        .options = shared.options,
        .io = shared.io,
        .arena = request_arena.allocator(),
    };
    handle(&server, client);
}

/// The watcher: reaps runs, and ingests the timelines that finished (a running run's as they
/// do; a finished run's last ones once).
fn watch(shared: *Shared) void {
    var ids: [runs_max]u32 = undefined;
    var finals: [runs_max]bool = undefined;
    var watches: u64 = 0;
    while (true) : (watches += 1) {
        if (watches % snapshots_sweep_interval == 0) snapshots_sweep(shared);
        if (watches % sessions_idle_interval == 0) sessions_idle_end(shared);
        if (watches % detach_watch_interval == 0) {
            var detach_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer detach_arena.deinit();
            var server: Server = .{
                .shared = shared,
                .options = shared.options,
                .io = shared.io,
                .arena = detach_arena.allocator(),
            };
            detach_idle(&server);
        }
        const interval: linux.timespec = .{
            .sec = @divFloor(watch_interval_ns, std.time.ns_per_s),
            .nsec = @mod(watch_interval_ns, std.time.ns_per_s),
        };
        assert(linux.errno(linux.nanosleep(&interval, null)) != .INVAL);
        shared.lock();
        runs_discover_locked(shared);
        var ended: [16]u32 = undefined;
        const ended_count = runs_reap(shared, &ended);
        orphan_sweep_ticks += 1;
        if (orphan_sweep_ticks % orphan_sweep_every == 0) orphan_checks_kill();
        var count: usize = 0;
        for (shared.runs[0..shared.run_count]) |*run| {
            if (run.complete) continue;
            ids[count] = run.id;
            finals[count] = run.status != null;
            count += 1;
            // Finished: one last ingest brings in every timeline.
            if (run.status != null) run.complete = true;
        }
        shared.unlock();
        for (ended[0..ended_count]) |id| {
            var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer request_arena.deinit();
            var server: Server = .{
                .shared = shared,
                .options = shared.options,
                .io = shared.io,
                .arena = request_arena.allocator(),
            };
            run_repeat(&server, id) catch |err| {
                std.debug.print("[determinismo] run {d} could not repeat: {s}\n", .{
                    id, @errorName(err),
                });
            };
            automations_start(&server, id);
        }
        for (ids[0..count], finals[0..count]) |id, final| {
            var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer request_arena.deinit();
            var server: Server = .{
                .shared = shared,
                .options = shared.options,
                .io = shared.io,
                .arena = request_arena.allocator(),
            };
            // A finished run's last ingest done (each finished run's, at a serve start): detached
            // at once, unless in use (serve's start attached all 929 for detach_idle's 10 minutes).
            defer if (final) {
                _ = detach_one(&server, id, 0);
            };
            run_update(&server, id) catch |err| {
                std.debug.print("[determinismo] run {d}'s events: {s} {s}\n", .{
                    id, @errorName(err), server.detail orelse "",
                });
                continue;
            };
            // Its page's answers of before this ingest, again: its requests read them as kept.
            if (!final) answers_refresh(&server, id);
            const failures = if (server.options.failure_analysis) &failures_analyze else &failures_snapshot;
            if (watches % failures_watch_interval == 0) failures(&server, id) catch |err| {
                std.debug.print("[determinismo] run {d}'s failures not saved: {s} {s}\n", .{
                    id, @errorName(err), server.detail orelse "",
                });
            };
        }
    }
}

/// Brings the run's events database up to date: attached the first time, then the timelines
/// that finished since the last ingest (none when timelines.jsonl did not grow: no connection).
/// One ingest of a run at a time, and of a run still going no request waits behind it: the
/// watcher brings its timelines in as they finish (seconds a batch on a long run, one after the
/// other: etcd's 12-hour run 2007 at 5 to 11 s each), and every request about the run waited
/// for the batch in flight, its kept answers too. It reads what was ingested before. A run that
/// ended is waited for: its answers are whole.
fn run_update(server: *Server, id: u32) !void {
    const shared = server.shared;
    assert(id < runs_max);
    const ingesting = &shared.ingest_locks[id];
    if (!ingesting.tryLock()) {
        if (run_going(server, id)) return;
        ingesting.lockUncancelable(server.io);
    }
    defer ingesting.unlock(server.io);
    const events = try run_store(server, id);
    {
        const lock = &shared.store_locks[id];
        lock.lockUncancelable(server.io);
        defer lock.unlock(server.io);
        if (shared.taken[id] != 0) {
            server.detail = try print(server, "its events directory holds run {d}'s events now", .{shared.taken[id]});
            return error.EventsTaken;
        }
    }
    // Attached only to ingest: a run polled with nothing new (the runs list, its cached answers)
    // stays detached once idle (detach_idle).
    const timelines = try std.fs.path.join(server.arena, &.{ events.directory, "timelines.jsonl" });
    const stat = std.Io.Dir.cwd().statFile(server.io, timelines, .{});
    const size = if (stat) |known| known.size else |_| 0;
    // The timelines replayed as the run went (replays.zig), which finish after their timelines.
    const replays = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), "record.jsonl.replays" });
    const replays_stat = std.Io.Dir.cwd().statFile(server.io, replays, .{});
    const replays_size = if (replays_stat) |known| known.size else |_| 0;
    // A run over without a timeline (its setup failed): its setup's events, once, so its queries
    // see why (ScyllaDB's run 405: 20,353 events in setup.jsonl, its database empty).
    if (size == 0 and !shared.setup_ingested[id]) if (run_get(server, id)) |run| if (run.status != null or run.stopped) {
        var setup_connection = try run_connect(server, id);
        defer run_release(server, id, &setup_connection);
        store.setup_ingest(&setup_connection, server.arena, server.io, events.directory) catch |err| {
            server.detail = try server.arena.dupe(u8, setup_connection.failure.text());
            return err;
        };
        shared.setup_ingested[id] = true;
        generation_next(server, id);
    };
    // A run that ended before the coverage gate looked (fewer timelines than it waits for, or
    // all of them between two looks): judged once, here, though nothing new arrived.
    const judge_ended = !shared.coverage_known[id] and !run_going(server, id);
    if (size == shared.ingested[id] and replays_size == shared.replays_ingested[id] and !judge_ended) return;
    // Counted as any connection: its database stays attached while it ingests.
    var connection = try run_connect(server, id);
    defer run_release(server, id, &connection);
    if (size != shared.ingested[id]) {
        const directory = events.directory;
        const arrived = store.ingest(&connection, server.arena, server.io, directory) catch |err| {
            server.detail = try server.arena.dupe(u8, connection.failure.text());
            return err;
        };
        shared.ingested[id] = size;
        if (arrived > 0) generation_next(server, id);
        if (arrived > 0 and !shared.coverage_known[id]) coverage_gate(server, id, &connection);
    }
    if (judge_ended and !shared.coverage_known[id]) coverage_gate(server, id, &connection);
    if (replays_size != shared.replays_ingested[id]) {
        store.replays_ingest(&connection, server.arena, server.io, replays) catch |err| {
            server.detail = try server.arena.dupe(u8, connection.failure.text());
            return err;
        };
        shared.replays_ingested[id] = replays_size;
        generation_next(server, id);
    }
}

/// Coverage always (since 2026-11-16, after a hunt explored a system 12 hours without it and
/// 21 of 33 workloads' latest runs had none): a running run whose first
/// coverage_gate_timelines ended timelines carry no coverage event is stopped, its `stopped` file
/// saying why, unless its request says `"coverage": "off"` (a self-test's own workload). One
/// that ended by itself before the gate looked keeps its verdict and gets an `uncovered` file
/// saying the same (a CI job of a few fast timelines ended unjudged, its tests uninstrumented).
/// Both are in the run's JSON (run_show: stopped_why, uncovered), for its page and its client. A system
/// without its language's instrumentation is explored blind: no guidance from its code, no
/// thread-pause points in it. Its workload needs a build with it (Go's determinismo-toolexec,
/// rustc's or clang's trace-pc-guard with the binary in /symbols, a JVM of 24 or later for the
/// agent or jars instrumented ahead of time, Python's coverage). Whatever started the run: a
/// hunt, a calibration, a trial, explore.
const coverage_gate_timelines = 4;

fn coverage_gate(server: *Server, id: u32, connection: *duckdb.Connection) void {
    const shared = server.shared;
    const going = run_going(server, id);
    if (!going) {
        // Stopped by someone (or by this gate, at an earlier look): not this gate's to judge.
        const run = run_get(server, id) orelse return;
        if (run.stopped) {
            shared.coverage_known[id] = true;
            return;
        }
    }
    const Asked = struct { coverage: ?[]const u8 = null };
    const request = run_file(server, id, "request.json") catch return;
    const asked = std.json.parseFromSliceLeaky(Asked, server.arena, request, .{ .ignore_unknown_fields = true }) catch Asked{};
    if (asked.coverage) |set| if (std.mem.eql(u8, set, "off")) {
        shared.coverage_known[id] = true;
        return;
    };
    const Count = struct { count: u64 };
    const covered_sql = "SELECT count(*) AS count FROM (SELECT 1 FROM events WHERE name = 'coverage' LIMIT 1)";
    const covered = (connection.row(Count, server.arena, covered_sql, .{}) catch return) orelse return;
    if (covered.count > 0) {
        shared.coverage_known[id] = true;
        return;
    }
    const ended = (connection.row(Count, server.arena, "SELECT count(*) AS count FROM timelines", .{}) catch return) orelse return;
    const remedy = "its system runs without its language's instrumentation (coverage always); build its workload with it, " ++
        "or ask \"coverage\": \"off\" for a self-test\n";
    if (!going) {
        shared.coverage_known[id] = true;
        if (ended.count == 0) return; // No timeline ended (its setup failed): no code ran to cover.
        const why = std.fmt.allocPrint(server.arena, "no coverage in its {d} timelines: " ++ remedy, .{ended.count}) catch return;
        const directory = run_directory(server, id) catch return;
        const uncovered = std.fs.path.join(server.arena, &.{ directory, "uncovered" }) catch return;
        std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = uncovered, .data = why }) catch {};
        std.debug.print("[serve] run {d} ended uncovered: {s}", .{ id, why });
        return;
    }
    if (ended.count < coverage_gate_timelines) return;
    shared.coverage_known[id] = true;
    var buffer: [256]u8 = undefined;
    var reply: std.Io.Writer = .fixed(&buffer);
    // Its reason with the stop itself: a client that sees the run stopped reads why.
    const why = std.fmt.allocPrint(server.arena, "no coverage in its first {d} timelines: " ++ remedy, .{ended.count}) catch return;
    _ = run_stop(server, id, false, why, &reply) catch |err| {
        std.debug.print("[serve] run {d}: no coverage in its first {d} timelines, and its stop failed: {s}\n", .{ id, ended.count, @errorName(err) });
        return;
    };
    std.debug.print("[serve] run {d} stopped: {s}", .{ id, why });
}

/// For what a run's page shows (its kept answers, its timelines' list): a run still going is
/// brought up to date by the watcher alone, every second, and its page reads what is ingested.
/// A request that found a timeline just finished ingested it itself before answering: 4 of 120
/// requests in a minute on etcd's run 2007 took 2.7 to 6.5 s (8.3 s seen in a browser), the
/// others 0.01 to 0.2 s. A run that ended is brought up to date here: its answers are whole.
/// (A query or SQL asked of a run still ingests what finished: a session's timeline is there
/// for the request after it.)
fn run_update_unless_going(server: *Server, id: u32) !void {
    if (run_going(server, id)) return;
    return run_update(server, id);
}

/// Whether the run's explorer still runs (not ended, not stopped): its timelines still come.
fn run_going(server: *Server, id: u32) bool {
    const run = run_get(server, id) orelse return false;
    return run.status == null and !run.stopped;
}

/// The run's kept answers are of before: computed again when next asked.
fn generation_next(server: *Server, id: u32) void {
    const shared = server.shared;
    const lock = &shared.answer_locks[id];
    lock.lockUncancelable(server.io);
    defer lock.unlock(server.io);
    shared.generations[id] += 1;
}

/// The run whose database (`run_<id>`) holds a file, by DuckDB's "already attached by database
/// \"run_<id>\"" failure; null if it says nothing of the kind.
fn attached_by(text: []const u8) ?u32 {
    const marker = "already attached by database \"run_";
    const start = (std.mem.indexOf(u8, text, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    return std.fmt.parseInt(u32, text[start..end], 10) catch null;
}

test attached_by {
    try std.testing.expectEqual(@as(?u32, 206), attached_by("Resource In Use Error: Unique file handle conflict: " ++
        "Cannot attach \"run_226\" - the database file \"/x/events.duckdb\" is already attached by database \"run_206\""));
    try std.testing.expectEqual(@as(?u32, null), attached_by("Catalog Error: something else"));
}

/// Run `newer` takes run `older`'s events directory: older's database detached, its answers
/// forgotten, and its queries told whose events the directory holds now.
fn events_take(server: *Server, older: u32, newer: u32) !void {
    const shared = server.shared;
    assert(older < newer);
    // After an ingest of its own, if one is going (never during it).
    const ingesting = &shared.ingest_locks[older];
    ingesting.lockUncancelable(server.io);
    defer ingesting.unlock(server.io);
    const lock = &shared.store_locks[older];
    lock.lockUncancelable(server.io);
    defer lock.unlock(server.io);
    var failure: duckdb.Failure = .{};
    try shared.database.detach(try print(server, "run_{d}", .{older}), &failure);
    shared.attached[older] = false;
    shared.taken[older] = newer;
    shared.ingested[older] = 0;
    shared.replays_ingested[older] = 0;
    generation_next(server, older);
    std.debug.print("[determinismo] run {d} took run {d}'s events directory\n", .{ newer, older });
}

fn run_store(server: *Server, id: u32) !store.Store {
    return .{
        .directory = try std.fs.path.join(server.arena, &.{
            try run_directory(server, id), "events",
        }),
        .name = try print(server, "run_{d}", .{id}),
    };
}

/// A connection to the run's events database, up to date.
fn run_database(server: *Server, id: u32) !duckdb.Connection {
    try run_update(server, id);
    return run_connect(server, id);
}

/// A connection to the run's events database, attached again if it was detached (idle), counted
/// until run_release.
fn run_connect(server: *Server, id: u32) !duckdb.Connection {
    const shared = server.shared;
    const lock = &shared.store_locks[id];
    lock.lockUncancelable(server.io);
    defer lock.unlock(server.io);
    var failure: duckdb.Failure = .{};
    const events = try run_store(server, id);
    try run_attach(server, id, events);
    const connection = events.connect(&shared.database, server.arena, &failure) catch |err| {
        server.detail = try server.arena.dupe(u8, failure.text());
        return err;
    };
    shared.users[id] += 1;
    shared.used_s[id] = seconds_now(server);
    return connection;
}

/// Closes a connection run_connect gave.
fn run_release(server: *Server, id: u32, connection: *duckdb.Connection) void {
    connection.close();
    const shared = server.shared;
    const lock = &shared.store_locks[id];
    lock.lockUncancelable(server.io);
    defer lock.unlock(server.io);
    assert(shared.users[id] > 0);
    shared.users[id] -= 1;
    shared.used_s[id] = seconds_now(server);
}

fn seconds_now(server: *Server) i64 {
    return std.Io.Timestamp.now(server.io, .real).toSeconds();
}

/// The run's database attached, if it is not (its store lock held): the first time, or again
/// after detach_idle.
fn run_attach(server: *Server, id: u32, events: store.Store) !void {
    const shared = server.shared;
    if (shared.attached[id]) return;
    var failure: duckdb.Failure = .{};
    // An exploration given --events-dir links its run's events there: a symlink to a
    // directory, which createDirPath takes for NotDir (runs 65 to 71 on srv3 never opened).
    std.Io.Dir.cwd().access(server.io, events.directory, .{}) catch
        try std.Io.Dir.cwd().createDirPath(server.io, events.directory);
    const database = &shared.database;
    const arena = server.arena;
    const name = events.name;
    _ = store.Store.attach(database, arena, events.directory, name, &failure) catch |err| retry: {
        // An older run named the same directory: this one, newer, holds it now (DuckDB
        // attaches a file once, and says to which database).
        const older = attached_by(failure.text()) orelse 0;
        if (older == 0 or older >= id) {
            server.detail = try server.arena.dupe(u8, failure.text());
            return err;
        }
        events_take(server, older, id) catch |take_err| {
            server.detail = try server.arena.dupe(u8, failure.text());
            return take_err;
        };
        failure = .{};
        break :retry store.Store.attach(database, arena, events.directory, name, &failure) catch |again| {
            server.detail = try server.arena.dupe(u8, failure.text());
            return again;
        };
    };
    shared.attached[id] = true;
}

/// A finished run's database unused this long is detached: each attached one keeps its tables'
/// indexes in DuckDB's memory, which cannot spill. Serve had 938 attached (1,870 primary keys,
/// 862 MiB of index of its 4 GiB), and run 1049's ingest (RedisRaft, 3.7 GB of events) and every
/// query after it ran out of memory. The next use attaches it again.
const detach_idle_s = 10 * 60;

fn detach_idle(server: *Server) void {
    const shared = server.shared;
    const now = seconds_now(server);
    shared.lock();
    var ids: [runs_max]u32 = undefined;
    var count: usize = 0;
    for (shared.runs[0..shared.run_count]) |run| {
        const finished = run.status != null or run.stopped;
        if (finished and run.complete) {
            ids[count] = run.id;
            count += 1;
        }
    }
    shared.unlock();
    for (ids[0..count]) |id| {
        if (now - shared.used_s[id] < detach_idle_s) continue;
        _ = detach_one(server, id, detach_idle_s);
    }
}

/// The run's database detached if attached, unused for `idle_s` and in no connection's use;
/// whether it was.
fn detach_one(server: *Server, id: u32, idle_s: i64) bool {
    const shared = server.shared;
    const lock = &shared.store_locks[id];
    if (!lock.tryLock()) return false;
    defer lock.unlock(server.io);
    if (!shared.attached[id] or shared.users[id] > 0) return false;
    if (seconds_now(server) - shared.used_s[id] < idle_s) return false;
    var failure: duckdb.Failure = .{};
    const name = print(server, "run_{d}", .{id}) catch return false;
    shared.database.detach(name, &failure) catch {
        std.debug.print("[determinismo] run {d}'s database not detached: {s}\n", .{ id, failure.text() });
        return false;
    };
    shared.attached[id] = false;
    return true;
}

/// The run's answer of a kind: as kept, when no timeline arrived since; else computed by
/// `compute` and kept. A kept one waits for nothing of the run's database (its attach, an ingest
/// going on). Of a run still going, the kept one even when timelines arrived since: the watcher
/// computes it again after each of its ingests (answers_refresh), when nothing else asks the
/// database. Computed at the request, the first one after an ingest that came during the next
/// took seconds: etcd's run 2007's properties 4.2 to 5.2 s, 1 computation of 40 (0.25 s alone).
fn answer_kept(
    server: *Server,
    id: u32,
    kept: Kept,
    compute: *const fn (*Server, *duckdb.Connection, *std.Io.Writer) anyerror!void,
) ![]const u8 {
    const going = run_going(server, id);
    if (!going) try run_update(server, id);
    const shared = server.shared;
    const lock = &shared.answer_locks[id];
    lock.lockUncancelable(server.io);
    const slot = &shared.answers[id][@backingInt(kept)];
    const generation = shared.generations[id];
    if (slot.bytes) |bytes| if (slot.generation == generation or going) {
        defer lock.unlock(server.io);
        return server.arena.dupe(u8, bytes);
    };
    lock.unlock(server.io);
    return answer_compute(server, id, kept, compute, generation);
}

/// An answer computed and kept, as of `generation` (read before it: a timeline arriving
/// meanwhile makes it one to compute again).
fn answer_compute(
    server: *Server,
    id: u32,
    kept: Kept,
    compute: *const fn (*Server, *duckdb.Connection, *std.Io.Writer) anyerror!void,
    generation: u64,
) ![]const u8 {
    const shared = server.shared;
    var connection = try run_connect(server, id);
    defer run_release(server, id, &connection);
    var out: std.Io.Writer.Allocating = .init(server.arena);
    compute(server, &connection, &out.writer) catch |err| {
        if (err == error.DuckDB) database_failed(server, &connection.failure);
        return err;
    };
    const bytes = try std.heap.page_allocator.dupe(u8, out.written());
    const lock = &shared.answer_locks[id];
    lock.lockUncancelable(server.io);
    defer lock.unlock(server.io);
    const slot = &shared.answers[id][@backingInt(kept)];
    if (slot.bytes) |old| std.heap.page_allocator.free(old);
    slot.* = .{ .generation = generation, .bytes = bytes };
    return out.written();
}

fn kept_compute(kept: Kept) *const fn (*Server, *duckdb.Connection, *std.Io.Writer) anyerror!void {
    return switch (kept) {
        .stats => &stats_compute,
        .timelines => &timelines_compute,
        .properties => &properties_compute,
        .discovery => &discovery_compute,
        .failures => &failures_compute,
        .logged => &logged_compute,
    };
}

/// A running run's kept answers of before its last ingest, computed again: the watcher's, right
/// after that ingest. Only those someone asked for since serve started (a run nobody looks at
/// costs nothing).
fn answers_refresh(server: *Server, id: u32) void {
    const shared = server.shared;
    for (std.enums.values(Kept)) |kept| {
        const lock = &shared.answer_locks[id];
        lock.lockUncancelable(server.io);
        const slot = shared.answers[id][@backingInt(kept)];
        const generation = shared.generations[id];
        lock.unlock(server.io);
        if (slot.bytes == null or slot.generation == generation) continue;
        _ = answer_compute(server, id, kept, kept_compute(kept), generation) catch |err| {
            std.debug.print("[determinismo] run {d}'s {s} not computed again: {s}\n", .{ id, @tagName(kept), @errorName(err) });
            return;
        };
    }
}

fn stats_compute(_: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    try connection.json(out, store.stats_sql, .{});
}

fn timelines_compute(_: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    try connection.json(out, store.timelines_sql, .{});
}

fn properties_compute(_: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    try connection.json(out, store.properties_sql, .{});
}

/// Each timeline's first failing evaluation among its own events, as map marks (query.zig's
/// `marks`, from the store's summary: store.failures_sql): GET /runs/<id>/failures. The map draws
/// one a timeline; every failing evaluation, asked of the events at each load, was 97 s and
/// 14 MB on etcd's run 2007.
fn failures_compute(server: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    const Row = struct { branch: u32, seq: u64, vtime_ns: u64, mark: []const u8 };
    const rows = try connection.rows(Row, server.arena, store.failures_sql, .{});
    for (rows) |row| {
        try out.print("{{\"branch\":{d},\"seq\":{d},\"vtime_ns\":{d},\"mark\":{s}}}\n", .{
            row.branch, row.seq, row.vtime_ns, row.mark,
        });
    }
}

/// What the nodes logged as errors (store.logged_sql), JSON lines: GET /runs/<id>/logged.
fn logged_compute(_: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    try connection.json(out, store.logged_sql, .{});
}

fn discovery_compute(server: *Server, connection: *duckdb.Connection, out: *std.Io.Writer) !void {
    const Point = struct { timelines: u64, behaviors: u64 };
    const points = try connection.rows(Point, server.arena, store.discovery_sql, .{});
    try out.writeAll("{\"points\":[");
    for (points, 0..) |point, index| {
        if (index > 0) try out.writeAll(",");
        try out.print("[{d},{d}]", .{ point.timelines, point.behaviors });
    }
    try out.writeAll("]}\n");
}

fn listen(address_text: []const u8) !linux.fd_t {
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.BadListen;
    const port = try std.fmt.parseInt(u16, address_text[colon + 1 ..], 10);
    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, address_text[0..colon], '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadListen, 10);
    }
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    errdefer _ = linux.close(fd);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Bind;
    }
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.Listen;
    return fd;
}

const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    /// The client takes gzip (Accept-Encoding): large answers go compressed.
    gzip: bool = false,
};

/// The web UI: one page, no build step, talking to this API.
const ui_html = @embedFile("ui/index.html");
/// The Learn page (/learn): every technique a run uses and how they combine.
const learn_html = @embedFile("ui/learn.html");
/// The window viewer the UI's exports embed their document in (runs_cli.zig's --html too).
const export_html = @embedFile("ui/export.html");
/// The UI's text face, served by the binary itself (an inspection machine may have no
/// network): TeX Gyre Schola (GUST Font License, from CTAN), as the analysis pages set theirs.
const ui_fonts = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "/fonts/texgyreschola-regular.otf", .data = @embedFile("ui/fonts/texgyreschola-regular.otf") },
    .{ .name = "/fonts/texgyreschola-bold.otf", .data = @embedFile("ui/fonts/texgyreschola-bold.otf") },
    .{ .name = "/fonts/texgyreschola-italic.otf", .data = @embedFile("ui/fonts/texgyreschola-italic.otf") },
};

fn handle(server: *Server, client: linux.fd_t) void {
    const request = request_read(server, client) catch {
        return respond(client, 400, "text/plain", "bad request\n");
    };
    if (stream_id(request)) |id| return run_stream(server, client, id, request.body);
    // The page with a query string too (a property's link: `/?property=<message>#<run>`).
    const page_path = request.path[0 .. std.mem.indexOfScalar(u8, request.path, '?') orelse request.path.len];
    const page = std.mem.eql(u8, page_path, "/") or std.mem.eql(u8, page_path, "/index.html");
    if (page and std.mem.eql(u8, request.method, "GET")) {
        const path = server.options.ui_path orelse return respond_to(server, request, client, 200, "text/html; charset=utf-8", ui_html);
        // The file asked for, or an error that says so (never the built-in page instead).
        const html = std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, .limited(16 << 20)) catch |err| {
            const text = std.fmt.allocPrint(server.arena, "serve --ui {s}: {t}\n", .{ path, err }) catch "serve --ui: unreadable\n";
            return respond_to(server, request, client, 500, "text/plain; charset=utf-8", text);
        };
        return respond_to(server, request, client, 200, "text/html; charset=utf-8", html);
    }
    if (std.mem.eql(u8, request.method, "GET")) for (ui_fonts) |font| {
        if (std.mem.eql(u8, page_path, font.name)) return respond_to(server, request, client, 200, "font/otf", font.data);
    };
    if (std.mem.eql(u8, page_path, "/learn") and std.mem.eql(u8, request.method, "GET")) {
        return respond_to(server, request, client, 200, "text/html; charset=utf-8", learn_html);
    }
    // The samples this host offers on the learn page (`samples.json` in its data directory: a
    // deployment's own, never the repository's), none without it.
    if (std.mem.eql(u8, page_path, "/samples.json") and std.mem.eql(u8, request.method, "GET")) {
        const missing = "{\"error\":\"NotFound\"}\n";
        const path = std.fs.path.join(server.arena, &.{ server.options.data_directory, "samples.json" }) catch
            return respond_to(server, request, client, 404, "application/json", missing);
        const samples = std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, .limited(1 << 20)) catch
            return respond_to(server, request, client, 404, "application/json", missing);
        return respond_to(server, request, client, 200, "application/json", samples);
    }
    if (std.mem.eql(u8, page_path, "/export.html") and std.mem.eql(u8, request.method, "GET")) {
        return respond_to(server, request, client, 200, "text/html; charset=utf-8", export_html);
    }
    var response: std.Io.Writer.Allocating = .init(server.arena);
    const writer = &response.writer;
    const status = route(server, request, writer) catch |err| blk: {
        response.clearRetainingCapacity();
        writer.print("{{\"error\":\"{s}\"", .{@errorName(err)}) catch {};
        if (server.detail) |detail| {
            writer.print(",\"detail\":{f}", .{std.json.fmt(detail, .{})}) catch {};
        }
        writer.writeAll("}\n") catch {};
        break :blk @as(u16, switch (err) {
            error.NotFound => 404,
            error.BadRequest, error.SyntaxError, error.UnexpectedToken => 400,
            error.AddressInUse, error.ExplorerTooOld, error.NoFreeCpu => 409,
            else => 500,
        });
    };
    const text = std.mem.startsWith(u8, writer.buffered(), "{") or
        std.mem.startsWith(u8, writer.buffered(), "[");
    respond_to(server, request, client, status, if (text) "application/json" else "text/plain", writer.buffered());
}

/// POST /runs/<id>/stream: the run's id, else null (any other request).
fn stream_id(request: Request) ?u32 {
    if (!std.mem.eql(u8, request.method, "POST")) return null;
    var parts = std.mem.tokenizeScalar(u8, request.path, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "runs")) return null;
    const id = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "stream")) return null;
    if (parts.next() != null) return null;
    return id;
}

/// How often a stream looks at its run's properties: the same answer as GET /properties, kept
/// until new timelines come in.
const stream_interval_ns = 2 * std.time.ns_per_s;

/// A property as GET /properties lists it: what a stream compares and says.
const StreamRow = struct {
    type: []const u8,
    message: []const u8,
    status: []const u8,
    timelines_true: ?u64 = null,
    timelines_failing: ?u64 = null,
    first_failing_timeline: ?u64 = null,
    first_failure_ns: ?u64 = null,
};

/// The run's properties as they change, a line each (Antithesis's run stream, `snouty runs
/// stream`): against those it had when the stream opened (GET /properties has those), the ones
/// first seen (NEW_PROPERTIES_ADDED) and those with a first counterexample (PROPERTIES_FAILED,
/// a sample with it: its first failing timeline and moment, for `runs logs`), then every verdict
/// once the run ended (RUN_FINALIZED, a `sometimes` never true failing there), and the stream
/// ends. Only the named properties, when some are. A client gone ends it too.
fn run_stream(server: *Server, client: linux.fd_t, id: u32, body: []const u8) void {
    if (run_get(server, id) == null) return respond(client, 404, "application/json", "{\"error\":\"NotFound\"}\n");
    const Asked = struct { properties: []const []const u8 = &.{} };
    const asked: Asked = if (std.mem.trim(u8, body, " \r\n").len == 0) .{} else std.json.parseFromSliceLeaky(
        Asked,
        server.arena,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return respond(client, 400, "application/json", "{\"error\":\"BadRequest\"}\n");
    const head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-cache\r\n" ++
        "Connection: close\r\n\r\n";
    if (!send_all(client, head)) return;
    // What it saw (each property's name, and whether it had failed), past each look's arena.
    var kept_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer kept_state.deinit();
    const kept = kept_state.allocator();
    var known: std.StringHashMapUnmanaged(bool) = .empty;
    const arena_given = server.arena;
    defer server.arena = arena_given;
    var first = true;
    while (true) {
        var look_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer look_state.deinit();
        server.arena = look_state.allocator();
        const run = run_get(server, id) orelse return;
        const ended = run.status != null and run.complete;
        const text = answer_kept(server, id, .properties, &properties_compute) catch return;
        const rows = std.json.parseFromSliceLeaky([]const StreamRow, server.arena, text, .{
            .ignore_unknown_fields = true,
        }) catch return;
        var added: std.ArrayList(StreamRow) = .empty;
        var failed: std.ArrayList(StreamRow) = .empty;
        var all: std.ArrayList(StreamRow) = .empty;
        for (rows) |row| {
            if (asked.properties.len > 0) {
                const named = for (asked.properties) |name| {
                    if (std.mem.eql(u8, name, row.message)) break true;
                } else false;
                if (!named) continue;
            }
            all.append(server.arena, row) catch return;
            const failing = (row.timelines_failing orelse 0) > 0;
            const entry = known.getOrPut(kept, row.message) catch return;
            if (!entry.found_existing) {
                entry.key_ptr.* = kept.dupe(u8, row.message) catch return;
                entry.value_ptr.* = failing;
                if (!first) added.append(server.arena, row) catch return;
                if (!first and failing) failed.append(server.arena, row) catch return;
            } else if (failing and !entry.value_ptr.*) {
                entry.value_ptr.* = true;
                failed.append(server.arena, row) catch return;
            }
        }
        first = false;
        if (added.items.len > 0 and !stream_event(server, client, "NEW_PROPERTIES_ADDED", added.items)) return;
        if (failed.items.len > 0 and !stream_event(server, client, "PROPERTIES_FAILED", failed.items)) return;
        if (ended) {
            _ = stream_event(server, client, "RUN_FINALIZED", all.items);
            return;
        }
        if (client_gone(client)) return;
        const interval: linux.timespec = .{ .sec = @divFloor(stream_interval_ns, std.time.ns_per_s), .nsec = 0 };
        _ = linux.nanosleep(&interval, null);
    }
}

/// One stream line: `{"type": ..., "data": [{name, type, status, example_count,
/// counterexample_count, sample?}]}`; false when the client is gone.
fn stream_event(server: *Server, client: linux.fd_t, kind: []const u8, rows: []const StreamRow) bool {
    const Sample = struct { timeline: u64, vtime_ns: u64 };
    const Property = struct {
        name: []const u8,
        type: []const u8,
        status: []const u8,
        example_count: u64,
        counterexample_count: u64,
        sample: ?Sample,
    };
    const data = server.arena.alloc(Property, rows.len) catch return false;
    for (rows, data) |row, *property| property.* = .{
        .name = row.message,
        .type = row.type,
        .status = row.status,
        .example_count = row.timelines_true orelse 0,
        .counterexample_count = row.timelines_failing orelse 0,
        .sample = if (row.first_failing_timeline) |timeline| .{
            .timeline = timeline,
            .vtime_ns = row.first_failure_ns orelse 0,
        } else null,
    };
    const line = std.fmt.allocPrint(server.arena, "{f}\n", .{std.json.fmt(.{ .type = kind, .data = data }, .{})}) catch return false;
    return send_all(client, line);
}

fn send_all(client: linux.fd_t, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const written = linux.sendto(client, bytes[done..].ptr, bytes.len - done, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(written) != .SUCCESS or written == 0) return false;
        done += written;
    }
    return true;
}

/// The client closed its side: a read that would wait returns nothing at all.
fn client_gone(client: linux.fd_t) bool {
    var byte: [1]u8 = undefined;
    const read = linux.recvfrom(client, &byte, 1, linux.MSG.PEEK | linux.MSG.DONTWAIT, null, null);
    return linux.errno(read) == .SUCCESS and read == 0;
}

/// `respond`, gzipped when large and the client takes it.
fn respond_to(
    server: *Server,
    request: Request,
    client: linux.fd_t,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) void {
    if (request.gzip and body.len >= gzip_size_min) {
        if (gzipped(server.arena, body)) |compressed| {
            return respond_encoded(client, status, content_type, "Content-Encoding: gzip\r\n", compressed);
        }
    }
    respond(client, status, content_type, body);
}

fn route(server: *Server, request: Request, out: *std.Io.Writer) !u16 {
    const eql = std.mem.eql;
    // A query string (`?after=N`) is the action's, apart.
    const question = std.mem.indexOfScalar(u8, request.path, '?');
    const path = request.path[0 .. question orelse request.path.len];
    server.query_string = if (question) |at| request.path[at + 1 ..] else "";
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    const first = parts.next() orelse return error.NotFound;
    if (eql(u8, first, "strategies")) return strategies_route(server, parts.next(), request, out);
    if (eql(u8, first, "sessions")) return sessions_route(server, &parts, request, out);
    if (eql(u8, first, "machines")) return machines_route(server, &parts, request, out);
    if (eql(u8, first, "build") and eql(u8, request.method, "GET")) return build_show(server, out);
    if (eql(u8, first, "checkpoints") and eql(u8, request.method, "GET")) {
        // GET /checkpoints/<machine>/<name>: 200 while its snapshot is on disk (the products
        // keep references: determinismo-ci's setup cache).
        const machine = parts.next() orelse return error.NotFound;
        const name = parts.next() orelse return error.NotFound;
        const snapshot = try checkpoint_path(server, try print(server, "{s}/{s}", .{ machine, name }));
        std.Io.Dir.cwd().access(server.io, try print(server, "{s}.state", .{snapshot}), .{}) catch return error.NotFound;
        try out.writeAll("{}");
        return 200;
    }
    if (!eql(u8, first, "runs")) return error.NotFound;
    const id_text = parts.next() orelse {
        if (eql(u8, request.method, "POST")) return run_create(server, request.body, out);
        if (eql(u8, request.method, "GET")) return runs_list(server, out);
        return error.NotFound;
    };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return error.NotFound;
    const run = run_get(server, id) orelse return error.NotFound;
    const action = parts.next() orelse {
        if (!eql(u8, request.method, "GET")) return error.NotFound;
        return run_show(server, &run, out);
    };
    return run_route(server, &run, action, &parts, request, out);
}

/// /runs/<id>/<action>[/...]: what one run offers.
fn run_route(
    server: *Server,
    run: *const Run,
    action: []const u8,
    parts: *std.mem.TokenIterator(u8, .scalar),
    request: Request,
    out: *std.Io.Writer,
) !u16 {
    const eql = std.mem.eql;
    if (eql(u8, action, "triage") and eql(u8, request.method, "GET")) {
        // The run's triage report (infra/host/triage.py), markdown: 404 before one is written.
        const text = run_file(server, run.id, "triage.md") catch return 404;
        try out.writeAll(text);
        return 200;
    }
    if (eql(u8, action, "ranges") and eql(u8, request.method, "GET")) {
        // The learned ranges (events.zig ranges_note) its explorer wrote at its end: each
        // bucket's label, its record and the timeline holding it, in a JSON array.
        const text = run_file(server, run.id, "record.jsonl.behaviors") catch "";
        try out.writeAll("[");
        var first = true;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"label\":\"highest \\\"") == null and
                std.mem.indexOf(u8, line, "\"label\":\"lowest \\\"") == null) continue;
            if (std.mem.indexOf(u8, line, "\"best\":") == null) continue;
            if (!first) try out.writeAll(",");
            first = false;
            try out.writeAll(line);
        }
        try out.writeAll("]\n");
        return 200;
    }
    if (eql(u8, action, "activity") and eql(u8, request.method, "GET")) {
        // Where its workers' time went, minute by minute (activity.zig): what its explorer, node
        // makers, holders and verifier wrote. A run from before it was written: no minutes.
        const text = run_file(server, run.id, "activity.jsonl") catch "";
        try activity.write_json(try activity.minutes(server.arena, text), out);
        return 200;
    }
    if (eql(u8, action, "output") and eql(u8, request.method, "GET")) {
        const text = try run_file(server, run.id, "output.log");
        // `?lines=<n>`: its last n lines; `&explorer=1`: the explorer's own (its progress, its
        // timelines, its verdicts), not the guests' consoles.
        const lines_text = query_value(server.query_string, "lines") orelse {
            try out.writeAll(text);
            return 200;
        };
        const wanted = std.fmt.parseInt(usize, lines_text, 10) catch return error.BadRequest;
        const explorer_only = query_value(server.query_string, "explorer") != null;
        var kept: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (kept.items.len == wanted) break;
            if (line.len == 0) continue;
            if (explorer_only and !explorer_line(line)) continue;
            try kept.append(server.arena, line);
        }
        var at = kept.items.len;
        while (at > 0) : (at -= 1) try out.print("{s}\n", .{kept.items[at - 1]});
        return 200;
    }
    if (eql(u8, action, "replay") and eql(u8, request.method, "POST")) {
        return run_replay(server, run, request.body, out);
    }
    if (eql(u8, action, "recover") and eql(u8, request.method, "POST")) {
        return run_recover(server, run, request.body, out);
    }
    if (eql(u8, action, "automations")) {
        // Written as they run, once the run ended: none yet, or none asked for, is empty.
        try out.writeAll(run_file(server, run.id, automations_file) catch "");
        return 200;
    }
    if (eql(u8, action, "session") and eql(u8, request.method, "POST")) {
        return session_start(server, run, request.body, out);
    }
    if (eql(u8, action, "stop") and eql(u8, request.method, "POST")) {
        return run_stop(server, run.id, query_value(server.query_string, "drain") != null, "", out);
    }
    if (eql(u8, action, "resume") and eql(u8, request.method, "POST")) {
        return run_resume(server, run.id, out);
    }
    if (eql(u8, action, "extract") and eql(u8, request.method, "POST")) {
        return run_extract(server, run, request.body, out);
    }
    if (eql(u8, action, "findings") and eql(u8, request.method, "GET")) {
        return findings_show(server, run, out);
    }
    if (eql(u8, action, "notebook")) {
        const what = parts.next() orelse return notebook(server, run, request, out);
        if (!eql(u8, what, "evaluate") or !eql(u8, request.method, "POST")) return error.NotFound;
        return notebook_evaluate(server, run, request.body, out);
    }
    if (eql(u8, action, "nrepl") and eql(u8, request.method, "POST")) {
        return nrepl_start(server, run.id, out);
    }
    if (eql(u8, action, "causality")) {
        const index_text = parts.next() orelse {
            if (eql(u8, request.method, "POST")) return causality_start(server, run, request.body, out);
            return causality_list(server, run, out);
        };
        const index = std.fmt.parseInt(u32, index_text, 10) catch return error.NotFound;
        if (parts.next()) |verb| {
            if (eql(u8, verb, "stop") and eql(u8, request.method, "POST")) return causality_stop(server, run, index, out);
            // GET /runs/<id>/causality/<n>/explained/<k>/logs?grep=<text>: the node output of
            // its explanation's future k (lines holding the text), as its events have it.
            if (eql(u8, verb, "explained")) {
                const future = std.fmt.parseInt(usize, parts.next() orelse return error.NotFound, 10) catch return error.NotFound;
                const what = parts.next() orelse return error.NotFound;
                if (!eql(u8, what, "logs")) return error.NotFound;
                return explained_logs(server, run, index, future, out);
            }
            return error.NotFound;
        }
        return causality_show(server, run, index, out);
    }
    if (eql(u8, action, "shrink") or eql(u8, action, "explain")) {
        const index_text = parts.next() orelse {
            if (eql(u8, request.method, "POST")) {
                if (eql(u8, action, "explain")) return explain_start(server, run, request.body, out);
                return shrink_start(server, run, request.body, out);
            }
            return job_list(server, run, action, out);
        };
        const index = std.fmt.parseInt(u32, index_text, 10) catch return error.NotFound;
        const verb = parts.next() orelse return error.NotFound;
        if (eql(u8, verb, "stop") and eql(u8, request.method, "POST")) return job_stop(server, run, action, index, out);
        return error.NotFound;
    }
    // A timeline's own events as a run of a Quint spec's actions (docs/QUINT.md): the module
    // `determinismo quint` writes, for a spec and a Quint that are somewhere else (an agent's
    // machine), and what Quint's result on it means.
    if (eql(u8, action, "quint")) {
        if (!eql(u8, request.method, "POST")) return error.NotFound;
        const asked = std.json.parseFromSliceLeaky(quint.Asked, server.arena, request.body, .{ .ignore_unknown_fields = true }) catch return error.BadRequest;
        const events = try std.fs.path.join(server.arena, &.{ try run_directory(server, run.id), "events" });
        quint.answer(server.arena, server.io, events, asked, out) catch |err| switch (err) {
            error.BadRequest, error.FieldNotAnIdentifier, error.EmptyRecord, error.UnsupportedValue, error.DetailsNotARecord => return error.BadRequest,
            error.FileNotFound => return error.NotFound,
            else => return err,
        };
        return 200;
    }
    // The rest is the run's events database's.
    const reads = [_][]const u8{ "timelines", "properties", "discovery", "failures", "logged" };
    const writes = [_][]const u8{ "query", "events", "sql" };
    const database_read = for (reads) |name| {
        if (eql(u8, action, name)) break eql(u8, request.method, "GET");
    } else for (writes) |name| {
        if (eql(u8, action, name)) break eql(u8, request.method, "POST");
    } else false;
    if (!database_read) return error.NotFound;
    // The timelines after the first `offset` ingested (a page keeps those): a long run's whole
    // list is megabytes, and a page polling it every few seconds fills a slow link. In the order
    // they were ingested, the order they finished: a tree's do not finish in order.
    if (eql(u8, action, "timelines")) if (query_value(server.query_string, "offset")) |offset_text| {
        const offset = std.fmt.parseInt(u32, offset_text, 10) catch return error.BadRequest;
        try run_update_unless_going(server, run.id);
        var connection = try run_connect(server, run.id);
        defer run_release(server, run.id, &connection);
        const order = try print(server, "ORDER BY t.rowid OFFSET {d}", .{offset});
        const sql = try std.mem.replaceOwned(u8, server.arena, store.timelines_sql, "ORDER BY t.branch", order);
        const sql_z = try std.fmt.allocPrintSentinel(server.arena, "{s}", .{sql}, 0);
        var rows: std.Io.Writer.Allocating = .init(server.arena);
        connection.json(&rows.writer, sql_z, .{}) catch |err| {
            if (err == error.DuckDB) database_failed(server, &connection.failure);
            return err;
        };
        try out.writeAll(if (rows.written().len == 0) "[]\n" else rows.written()); // None new.
        return 200;
    };
    const kept: ?Kept = std.meta.stringToEnum(Kept, action);
    if (kept) |kind| {
        if (kind == .stats) return error.NotFound; // Part of GET /runs/<id>.
        try out.writeAll(try answer_kept(server, run.id, kind, kept_compute(kind)));
        return 200;
    }
    // A page's own SQL (`?page=1`: a property's examples, the map's faults, a section opened)
    // reads what is ingested, as the page's kept answers do (run_update_unless_going). Any other
    // request brings the run up to date first: a session's timeline is there for the query
    // after it. The map's first request of faults on etcd's run 2007 took 4.5 s for a batch it
    // ingested itself, the next ones 0.34 to 0.64 s.
    var connection = if (query_value(server.query_string, "page") != null) page: {
        try run_update_unless_going(server, run.id);
        break :page try run_connect(server, run.id);
    } else try run_database(server, run.id);
    defer run_release(server, run.id, &connection);
    database_answer(server, &connection, action, request.body, out) catch |err| {
        if (err == error.DuckDB) database_failed(server, &connection.failure);
        return err;
    };
    return 200;
}

/// What the run's events database answers (store.zig, query.zig, event_sets.zig).
fn database_answer(
    server: *Server,
    connection: *duckdb.Connection,
    action: []const u8,
    body: []const u8,
    out: *std.Io.Writer,
) !void {
    const eql = std.mem.eql;
    const arena = server.arena;
    const options_json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (eql(u8, action, "query")) {
        const asked = try std.json.parseFromSliceLeaky(query.Request, arena, body, options_json);
        const search = try query.query_of(arena, asked);
        _ = try query.answer(connection, arena, &search, out, true);
        return;
    }
    if (eql(u8, action, "events")) {
        const Asked = event_sets.Request;
        const asked = try std.json.parseFromSliceLeaky(Asked, arena, body, options_json);
        return event_sets.request_answer(connection, arena, server.io, asked, out);
    }
    assert(eql(u8, action, "sql"));
    const Asked = struct { sql: []const u8 };
    const asked = try std.json.parseFromSliceLeaky(Asked, arena, body, options_json);
    _ = try connection.select_json(out, try arena.dupeSentinel(u8, asked.sql, 0), sql_rows_max);
}

/// What a client may ask for; mirrors explore's flags.
pub const RunRequest = struct {
    /// The system: a test program, a Compose file, or a directory of Kubernetes manifests
    /// (exactly one).
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    kubernetes: ?[]const u8 = null,
    /// With kubernetes: images loaded beside those its manifests name (explore's --images).
    images: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    /// Absent: a fresh one, drawn by the server and kept in the run's request.json (as
    /// Antithesis's runs: each explores anew, and every moment of it replays).
    seed: ?u64 = null,
    /// When the run ends on its own (its budget), another starts: the same request, a fresh
    /// seed. Continuous testing; a run stopped on request does not repeat.
    repeat: bool = false,
    /// In its system's findings history (Antithesis's "Show in Findings History"): false for a
    /// what-if run (a trial, an A/B arm), compared with the history but never what a later run
    /// is compared with, nor a tick in a finding's history.
    findings_history: bool = true,
    /// Setup mode (Antithesis's): the system built and booted, its setup run to setup_complete,
    /// no timeline (explore's --setup-only); out of the findings history, as it judges nothing.
    setup_only: bool = false,
    /// The program as asked, when `program` is the copy the run kept (artifact_keep): a
    /// repeat starts from the program as asked, the host's current build.
    program_asked: ?[]const u8 = null,
    /// The strategy as asked (`@<name> [arguments]`, an upload) when `strategy` is its kept copy:
    /// the upload's bytes by content (strategy_resolve), a later upload of the name never this
    /// run's.
    strategy_asked: ?[]const u8 = null,
    /// Timelines (at most, with a time budget).
    branches: ?u32 = null,
    /// Explore until then: "90s", "10m", "2h".
    time_budget: ?[]const u8 = null,
    /// "flat" or "tree" (explore's --branching).
    branching: ?[]const u8 = null,
    /// Fault kinds every node also allows, nodes that allow none (explore's --faults,
    /// --no-faults).
    faults: ?[]const u8 = null,
    no_faults: ?[]const u8 = null,
    /// Every node's coverage set in place of its own (explore's --coverage): "off" measures the
    /// instrumentation's cost on the same build.
    coverage: ?[]const u8 = null,
    /// How long each timeline's drivers run, in virtual time (explore's --timeline).
    timeline: ?[]const u8 = null,
    /// The most an eventually ending's drawn minimum drive can be (explore's --min-drive).
    min_drive: ?[]const u8 = null,
    drivers_cpu_weight: ?[]const u8 = null,
    /// Fault kinds made common in half the timelines, "kind=weight,..." (explore's
    /// --fault-weights: a causality analysis's kinds, for a run that finds its bug more often).
    fault_weights: ?[]const u8 = null,
    /// Antithesis's fault_exclusions: explore's --fault-exclusions.
    fault_exclusions: ?[]const u8 = null,
    /// Named decisions fixed in every timeline, "name=value,..." (explore's --decide): a what if
    /// of the run with that choice.
    decide: ?[]const u8 = null,
    /// What it would do, done nothing (run_plan): the same request without it starts it.
    plan: bool = false,
    /// Commands the composer's swarm keeps in every timeline (explore's --keep).
    keep: ?[]const u8 = null,
    /// System calls failing with this errno as syscall_error events (explore's --trace-errno).
    trace_errno: ?u16 = null,
    /// A scenario without a length's driver phase drawn up to this (explore's --drive-max).
    drive_max: ?[]const u8 = null,
    /// Timelines per tree generation (explore's --generation).
    generation: ?u32 = null,
    /// A tree's returns run this long past their moment, then stop (explore's --horizon), and
    /// its generations in flight (--pipeline).
    horizon: ?[]const u8 = null,
    /// The kept holders' room on disk in GB (explore's --holders-budget): a trial of the trims.
    holders_budget: ?u32 = null,
    /// Every holder written to disk (explore's --holders-on-disk), as while memory runs low: with
    /// memory to spare none is, and a trial of the trims trims nothing.
    holders_on_disk: bool = false,
    /// Offsets a tree's return lands before its moment, one drawn per return (explore's
    /// --return-offsets).
    return_offsets: ?[]const u8 = null,
    /// A tree's branches from each moment it returns to (explore's --return-branches).
    return_branches: ?u32 = null,
    /// A tree's returns go first to a `sometimes` or `reachable` made true (explore's default);
    /// false: every new behavior alike (--no-prefer-sometimes, for comparisons).
    prefer_sometimes: bool = true,
    /// false: a severe kind of output line weighs as any other (--no-prefer-severe).
    prefer_severe: bool = true,
    /// false: no learned ranges (--no-ranges), for comparisons.
    ranges: bool = true,
    /// false: the nodes' memory-growth objective not counted (--no-memory-objective), for
    /// comparisons.
    memory_objective: bool = true,
    /// false: a tree's return to an objective's best ends when its parent would
    /// (--no-objective-extend), for comparisons.
    objective_extend: bool = true,
    /// A CI job's (determinismo-ci): where its tests come from, for the UI's CI page (each
    /// repository's jobs, each test's verdict across them).
    ci: ?CiJob = null,
    /// false: no history (the behaviors of the system's last runs, `--history`), for comparisons.
    history: bool = true,
    /// Each timeline some of the fault kinds (explore's default); false: --no-swarm.
    swarm: bool = true,
    pipeline: ?u32 = null,
    jobs: ?u32 = null,
    strategy: ?[]const u8 = null,
    /// A targeted run: a diff file or git range on the server (explore's --changed).
    changed: ?[]const u8 = null,
    /// Where the range is: a repository's directory on the server or its URL
    /// (explore's --changed-repository).
    changed_repository: ?[]const u8 = null,
    /// Retroactive logging (explore's --retroactive): output lines with these texts are left
    /// out of the run's events; replays write them.
    retroactive: []const []const u8 = &.{},
    /// Where the timelines' egress may connect (explore's --egress; sdk.egress): "host",
    /// "host:port", "*.domain", "*". None: every connection refused.
    egress: []const []const u8 = &.{},
    /// Commands run at each failing property's first counterexample once the run ends on its
    /// own (schema.Automation; the profile's too): their output in automations.jsonl.
    automations: []const schema.Automation = &.{},
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    /// A session's fork (sdk.fork): its futures, a run from the machine the session saved
    /// (explore's --from-snapshot --fork-futures), released at from_vtime_ms; from_run is the
    /// session's run.
    from_snapshot: ?[]const u8 = null,
    /// A machine's checkpoint (`<machine>/here-<n>`, POST /machines/<id>/checkpoint): timelines
    /// from it, flat (explore --from-snapshot), its scenario's; or held (its scenario not
    /// started) running `checkpoint_exec` (a CI shard's), or `checkpoint_steps` in order (a
    /// sandbox's replay), at the checkpoint's moment.
    checkpoint: ?[]const u8 = null,
    checkpoint_exec: ?[]const u8 = null,
    checkpoint_steps: []const []const u8 = &.{},
    from_run: ?u32 = null,
    /// Branches at varying CPU speeds (and so their replays too): explore's default when the
    /// request does not say; runs from before it was had none (their request.json: false).
    cpu_modulation: bool = true,
    /// CPU modulation's stretches when not the default ("<min>-<max>" microseconds: explore's
    /// --cpu-modulation-stretch-us), so that its replays run them.
    cpu_modulation_stretch_us: ?[]const u8 = null,
    /// The guest's memory, instead of the server's (explore's --memory-mib): for systems of
    /// several large nodes. Kept in the run's machine arguments, so its replays boot the same.
    memory_mib: ?u32 = null,
    /// The share of timelines replayed as the run goes, in percent (explore's --verify-replays;
    /// 20 by default): 100 makes the run a determinism check of the system.
    verify_replays: ?u32 = null,
    /// Its VMs take CPUs before other runs' (DETERMINISMO_CPU_PRIORITY, cpus.zig): a check
    /// beside a hunt, which goes on with the CPUs it leaves.
    priority: bool = false,
    /// The commit of the determinismo that ran it ("-dirty": with uncommitted changes).
    build: ?[]const u8 = null,
    /// The explorer that ran it, kept by content as its kernel and initramfs are (artifacts/):
    /// its resumes, replays, extracts, analyses and shrinks run on it, so a deploy never makes a
    /// run's evidence diverge (runs 1488 and 1506, 2026-11-08: replays after a deploy parted from
    /// their tapes, and the builds that made them were gone). Null for runs from before.
    explorer: ?[]const u8 = null,
    /// What the run pins (PLAN: a run pins its core, not its whole explorer): its core's identity
    /// (build_options.core_id), the host's KVM modules' (host_core.zig) and the explorer's
    /// persisted formats' version (runs.state_format). Where all three are a server's, its own
    /// explorer resumes and replays the run (explorer_of); else the run's own. Null for runs
    /// from before: their own.
    core: ?[]const u8 = null,
    host_kvm: ?[]const u8 = null,
    state_format: ?u32 = null,
};

/// The environment a run's explorer starts with: its priority, and serve's own choice of
/// hyperthreads (DETERMINISMO_SMT, serve.sh's `--siblings`), which the CPU pool reads (cpus.zig).
/// Explorers start with a fresh environment: without it, `--siblings on` reached no run started
/// here (srv3, 2026-10-28).
fn run_environment(arena: std.mem.Allocator, asked: *const RunRequest) ![]const []const u8 {
    var environment: std.ArrayList([]const u8) = .empty;
    // A setup run is someone waiting on its logs (setup mode, Antithesis's assistant): its one
    // VM takes a CPU before a hunt's next timeline, as a priority run's do.
    if (asked.priority or asked.setup_only) try environment.append(arena, "DETERMINISMO_CPU_PRIORITY=1");
    if (std.c.getenv("DETERMINISMO_SMT")) |value| {
        try environment.append(arena, try std.fmt.allocPrint(arena, "DETERMINISMO_SMT={s}", .{std.mem.span(value)}));
    }
    return environment.items;
}

fn run_create(server: *Server, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(RunRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    if (asked.from_snapshot != null) return error.BadRequest; // A session's fork's alone.
    // Refused here, as the explorer would refuse it at its start (det-faults' regex.zig).
    if (asked.fault_exclusions) |pattern| _ = regex.Regex.compile(pattern) catch return error.BadRequest;
    if (asked.plan) return run_plan(server, asked, out);
    var run = asked;
    // A machine's checkpoint, as named (refused outside the machines' directory): flat branches.
    if (asked.checkpoint) |reference| {
        run.checkpoint = try checkpoint_path(server, reference);
        run.branching = "flat";
    }
    _ = try run_start(server, run, out);
    return 201;
}

/// A run's plan (`plan: true`), nothing started. Its timelines are known only as they run (the
/// tree follows what turns out new), so what it says is from the run of the same program and
/// scenario that ended last: how many timelines that one's budget bought (`like`), as many for
/// this budget at that rate (`timelines_expected`; a run of `branches` that many), and the named
/// choices that run's timelines drew (`sets`: label, kind, range or options' count, how many
/// timelines drew it), what this one draws from. None like it: only the request said back.
fn run_plan(server: *Server, asked_as_given: RunRequest, out: *std.Io.Writer) !u16 {
    // Its seed fixed here, so that the run its plan starts is the one it imagined.
    var asked = asked_as_given;
    if (asked.seed == null) {
        var seed: u64 = 0;
        std.Io.random(server.io, std.mem.asBytes(&seed));
        asked.seed = seed;
    }
    const program = std.fs.path.basename(asked.program orelse asked.compose orelse asked.kubernetes orelse "");
    const Asked = struct { program: ?[]const u8 = null, program_asked: ?[]const u8 = null, compose: ?[]const u8 = null, scenario: ?[]const u8 = null, time_budget: ?[]const u8 = null, branches: ?u32 = null };
    var ids: std.ArrayList(u32) = .empty;
    // What its configuration bandit would start from: the runs its history would gather (a run
    // asked without history starts cold).
    var learned: ?*bandit_zig.Bandit = null;
    {
        const shared = server.shared;
        shared.lock();
        defer shared.unlock();
        for (shared.runs[0..shared.run_count]) |run| if (run.status != null) try ids.append(server.arena, run.id);
        if (asked.history) {
            const history = try history_gather(server, shared.runs[0..shared.run_count], try identity_of(server, asked), std.math.maxInt(u32));
            const warm = try server.arena.create(bandit_zig.Bandit);
            warm.* = .{};
            bandit_zig.warm(warm, server.arena, history.learned);
            learned = warm;
        }
    }
    std.mem.sortUnstable(u32, ids.items, {}, std.sort.desc(u32));
    const Like = struct { run: u32, timelines: u64, budget: ?[]const u8, branches: ?u32 };
    var like: ?Like = null;
    for (ids.items[0..@min(ids.items.len, 64)]) |id| {
        const json = run_file(server, id, "request.json") catch continue;
        const request = std.json.parseFromSliceLeaky(Asked, server.arena, json, .{ .ignore_unknown_fields = true }) catch continue;
        const theirs = std.fs.path.basename(request.program_asked orelse request.program orelse request.compose orelse "");
        if (!std.mem.eql(u8, theirs, program)) continue;
        if (!std.mem.eql(u8, request.scenario orelse "", asked.scenario orelse "")) continue;
        var connection = run_database(server, id) catch continue;
        defer run_release(server, id, &connection);
        const Count = struct { count: u64 };
        const counted = connection.row(Count, server.arena, "SELECT count(*) AS count FROM explored", .{}) catch continue;
        like = .{ .run = id, .timelines = (counted orelse continue).count, .budget = request.time_budget, .branches = request.branches };
        break;
    }
    const Set = struct { name: []const u8, kind: []const u8, count: u64, timelines: u64 };
    var sets: []const Set = &.{};
    var expected: ?u64 = if (asked.branches) |count| count else null;
    if (like) |found| {
        var connection = try run_database(server, found.run);
        defer run_release(server, found.run, &connection);
        sets = connection.rows(Set, server.arena,
            \\SELECT name, any_value(kind) AS kind, max(count) AS count, count(DISTINCT timeline) AS timelines
            \\FROM timeline_draws WHERE timeline IN (SELECT branch FROM explored) GROUP BY name ORDER BY name
        , .{}) catch &.{};
        if (expected == null) if (asked.time_budget) |budget| if (found.budget) |theirs| {
            const ours_ns = main_zig.duration_parse(budget) catch 0;
            const theirs_ns = main_zig.duration_parse(theirs) catch 0;
            if (theirs_ns > 0) expected = @intFromFloat(@round(@as(f64, @floatFromInt(found.timelines)) * @as(f64, @floatFromInt(ours_ns)) / @as(f64, @floatFromInt(theirs_ns))));
        };
    }
    const setups: []const Setup = if (like) |found| run_plan_setups(server, found.run, asked, learned) else &.{};
    try out.print("{f}", .{std.json.fmt(.{
        .plan = true,
        .setups = setups,
        .program = asked.program_asked orelse asked.program orelse asked.compose,
        .scenario = asked.scenario,
        .profile = asked.profile,
        .seed = asked.seed,
        .branching = asked.branching orelse "tree",
        .time_budget = asked.time_budget,
        .branches = asked.branches,
        .decide = asked.decide,
        .like = like,
        .timelines_expected = expected,
        .sets = sets,
    }, .{})});
    return 200;
}

/// An imagined timeline of a run's first generation: its index and seed, and the choices it would
/// draw first: the named draws every first timeline of the run like it made in the same order at
/// the same pulls, up to where they part (what follows depends on the values drawn: the
/// composer's load drawn "spike" draws its length too, so the fault injector's choices come at
/// pull 16 in one timeline and 20 in another), or up to a choice `decide` fixes. Each is the
/// seed's value at its pull (decisions.zig: a pure function of the two), a configuration draw's as
/// the configuration bandit answers it (warm from the runs the run's history gathers, credited
/// only when a generation is judged: the same for every first timeline), or the fixed value.
/// Each label's first draw only.
const Setup = struct {
    index: u32,
    seed: []const u8,
    draws: []const struct { name: []const u8, drew: []const u8, fixed: bool },
};

fn run_plan_setups(server: *Server, like: u32, asked: RunRequest, learned: ?*const bandit_zig.Bandit) []const Setup {
    const arena = server.arena;
    var connection = run_database(server, like) catch return &.{};
    defer run_release(server, like, &connection);
    const Count = struct { count: u64 };
    const roots = (connection.row(Count, arena, "SELECT count(*) AS count FROM timelines WHERE generation = 0 AND extends IS NULL", .{}) catch return &.{}) orelse return &.{};
    if (roots.count == 0) return &.{};
    const Label = struct { timeline: u64, name: []const u8, kind: []const u8, count: u64, options: ?[]const u8 = null, pull: u64, config: bool };
    const drawn_first = connection.rows(Label, arena,
        \\SELECT d.timeline, d.name, d.kind, d.count, d.options::VARCHAR AS options, d.pull, d.config
        \\FROM timeline_draws d JOIN timelines t ON t.branch = d.timeline
        \\WHERE t.generation = 0 AND t.extends IS NULL AND d.part = 'own' AND d.pull < $1
        \\ORDER BY d.timeline, d.pull
    , .{setup_pulls_max}) catch return &.{};
    const fixed = decide_parse(arena, asked.decide orelse "");
    // The order every first timeline shares: the first one's, cut where another's parts from it.
    var reference_size: usize = 0;
    while (reference_size < drawn_first.len and drawn_first[reference_size].timeline == drawn_first[0].timeline) reference_size += 1;
    const reference = drawn_first[0..reference_size];
    var shared = reference.len;
    var timelines: u64 = 0;
    var at: usize = 0;
    while (at < drawn_first.len) {
        const start = at;
        while (at < drawn_first.len and drawn_first[at].timeline == drawn_first[start].timeline) at += 1;
        const rows = drawn_first[start..at];
        var same: usize = 0;
        while (same < @min(shared, rows.len) and reference[same].pull == rows[same].pull and
            reference[same].count == rows[same].count and std.mem.eql(u8, reference[same].name, rows[same].name)) same += 1;
        shared = same;
        timelines += 1;
    }
    if (timelines != roots.count) shared = 0; // A first timeline that drew nothing named.
    // Past a fixed choice, what follows may depend on it.
    for (reference[0..shared], 0..) |label, index| {
        if (for (fixed) |one| {
            if (std.mem.eql(u8, one.name, label.name)) break true;
        } else false) {
            shared = index + 1;
            break;
        }
    }
    var labels_list: std.ArrayList(Label) = .empty;
    for (reference[0..shared]) |label| {
        const again = for (labels_list.items) |known| {
            if (std.mem.eql(u8, known.name, label.name)) break true;
        } else false;
        if (!again) labels_list.append(arena, label) catch return &.{};
    }
    const labels = labels_list.items;
    const total: u32 = @intCast(@min(roots.count, if (asked.branches) |count| count else roots.count));
    const setups = arena.alloc(Setup, total) catch return &.{};
    for (setups, 0..) |*setup, index| {
        const seed = main_zig.branch_seed(asked.seed.?, @intCast(index));
        const draws = arena.alloc(@typeInfo(@TypeOf(setup.draws)).pointer.child, labels.len) catch return &.{};
        for (labels, draws) |label, *draw| {
            var decisions: Decisions = .{ .seed = seed, .pulls = label.pull };
            var bytes: [8]u8 = undefined;
            decisions.random(&bytes);
            const raw = std.mem.readInt(u64, &bytes, .little);
            const answered: u64 = if (label.config) if (learned) |bandit| bandit.choose(bandit_zig.name_hash(label.name), label.count, raw) orelse raw else raw else raw;
            const value = answered % @max(label.count, 1);
            const options = if (label.options) |text| std.json.parseFromSliceLeaky([]const []const u8, arena, text, .{}) catch &.{} else &.{};
            const drawn = if (std.mem.eql(u8, label.kind, "options") and value < options.len) options[value] else std.fmt.allocPrint(arena, "{d}", .{value}) catch "";
            const forced = for (fixed) |one| {
                if (std.mem.eql(u8, one.name, label.name)) break one.value;
            } else null;
            draw.* = .{ .name = label.name, .drew = forced orelse drawn, .fixed = forced != null };
        }
        setup.* = .{ .index = @intCast(index), .seed = std.fmt.allocPrint(arena, "{x:0>16}", .{seed}) catch "", .draws = draws };
    }
    return setups;
}

const Fixed = struct { name: []const u8, value: []const u8 };

/// How far into a first timeline's draws its setup is imagined at most.
const setup_pulls_max = 4096;

/// `decide`'s "name=value,..." (explore's --decide).
fn decide_parse(arena: std.mem.Allocator, text: []const u8) []const Fixed {
    var fixed: std.ArrayList(Fixed) = .empty;
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |part| {
        const at = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        fixed.append(arena, .{ .name = part[0..at], .value = part[at + 1 ..] }) catch break;
    }
    return fixed.items;
}

/// A run started as asked: its id (written on `out` too).
fn run_start(server: *Server, asked_as_given: RunRequest, out: *std.Io.Writer) !u32 {
    var asked = asked_as_given;
    if (asked.seed == null) {
        var seed: u64 = 0;
        std.Io.random(server.io, std.mem.asBytes(&seed));
        asked.seed = seed;
    }
    // The files it boots, kept by content: a deploy replaces the host's, never a run's. A fork's
    // is its session's run's, kept already.
    if (asked.program) |path| if (asked.from_snapshot == null) {
        if (asked.program_asked == null) asked.program_asked = path;
        asked.program = try artifact_keep(server, asked.program_asked.?);
    };
    // An uploaded strategy kept by content as the program is: its record says which bytes
    // answered, and a resume runs them, whatever was uploaded under its name since.
    if (asked.strategy) |strategy| if (std.mem.startsWith(u8, strategy, "@")) {
        asked.strategy_asked = strategy;
        asked.strategy = try strategy_resolve(server, strategy);
    };
    const machine = try machine_kept(server, asked.memory_mib, asked.seed.?);
    // As run: the seed drawn is in it, and the program it ran, for its replays.
    asked.build = build_options.commit; // The run's explorer is this binary.
    asked.core = build_options.core_id;
    asked.host_kvm = host_core.kvm_identity(server.arena);
    asked.state_format = host_runs.state_format;
    if (asked.explorer == null) asked.explorer = try artifact_keep(server, server.options.self);
    try host_runs.library_keep(server.arena, server.io, asked.explorer.?, server.options.self);
    const request_json = try std.fmt.allocPrint(server.arena, "{f}", .{std.json.fmt(asked, .{})});
    const shared = server.shared;
    shared.lock();
    defer shared.unlock(); // Until the run is in the list.
    if (shared.run_count == runs_max) return error.TooManyRuns;
    // Claimed as every exploration claims its run (runs.zig): ids are given once, whoever asks.
    const claimed = try host_runs.claim(server.arena, server.io, server.options.data_directory);
    const id = claimed.id;
    const directory = claimed.directory;
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, "request.json" }),
        .data = request_json,
    });
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, "machine.json" }),
        .data = try std.fmt.allocPrint(server.arena, "{f}", .{std.json.fmt(machine, .{})}),
    });
    // Its strategy may query the run as it goes (its events, SQL, earlier runs): where.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, try explore_arguments(server, &asked, directory, machine));
    try argv.appendSlice(server.arena, &.{
        "--run-url", try print(server, "http://{s}/runs/{d}", .{ listen_address(server), id }),
    });
    if (asked.history) if (try history_write(server, shared.runs[0..shared.run_count], id, directory)) |path| {
        try argv.appendSlice(server.arena, &.{ "--history", path });
    };
    const output = try std.fs.path.join(server.arena, &.{ directory, "output.log" });
    // Its explorer holds the run's pid file (runs.zig): how a restarted server finds it running.
    // A session's fork's futures are someone's looking, not a hunt: on the reserved cores.
    const launched = if (asked.from_snapshot != null) try reserved(server, argv.items) else argv.items;
    const pid = try spawn(server, launched, output, try run_environment(server.arena, &asked), .fresh);
    pid_note(server, directory, pid);
    runs_insert(shared, .{ .id = id, .pid = pid });
    try out.print("{{\"id\":{d}}}\n", .{id});
    return id;
}

/// The explore command of a run asked for, writing into its directory.
fn explore_arguments(
    server: *Server,
    asked: *const RunRequest,
    directory: []const u8,
    machine: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ try explorer_of(server, asked), "explore" });
    try argv.appendSlice(server.arena, machine);
    try system_arguments(server.arena, &argv, asked);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{asked.seed.?}) });
    if (asked.time_budget) |budget| {
        try argv.appendSlice(server.arena, &.{ "--time-budget", budget });
    }
    if (asked.branching) |branching| {
        try argv.appendSlice(server.arena, &.{ "--branching", branching });
    }
    if (asked.horizon) |horizon| try argv.appendSlice(server.arena, &.{ "--horizon", horizon });
    if (asked.holders_budget) |gb| try argv.appendSlice(server.arena, &.{ "--holders-budget", try std.fmt.allocPrint(server.arena, "{d}", .{gb}) });
    if (asked.holders_on_disk) try argv.append(server.arena, "--holders-on-disk");
    if (asked.return_offsets) |offsets| try argv.appendSlice(server.arena, &.{ "--return-offsets", offsets });
    if (asked.return_branches) |count| {
        try argv.appendSlice(server.arena, &.{ "--return-branches", try print(server, "{d}", .{count}) });
    }
    if (!asked.prefer_sometimes) try argv.append(server.arena, "--no-prefer-sometimes");
    if (!asked.prefer_severe) try argv.append(server.arena, "--no-prefer-severe");
    if (!asked.ranges) try argv.append(server.arena, "--no-ranges");
    if (!asked.memory_objective) try argv.append(server.arena, "--no-memory-objective");
    if (!asked.objective_extend) try argv.append(server.arena, "--no-objective-extend");
    if (asked.pipeline) |depth| {
        try argv.appendSlice(server.arena, &.{ "--pipeline", try print(server, "{d}", .{depth}) });
    }
    if (asked.generation) |size| {
        try argv.appendSlice(server.arena, &.{ "--generation", try print(server, "{d}", .{size}) });
    }

    if (asked.branches != null or asked.time_budget == null) {
        const branches = try print(server, "{d}", .{asked.branches orelse 16});
        try argv.appendSlice(server.arena, &.{ "--branches", branches });
    }
    // Its record, events and tapes go there (runs.zig), its pid file too.
    try argv.appendSlice(server.arena, &.{ "--run-directory", directory });
    if (asked.scenario) |scenario| try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    if (asked.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    if (asked.strategy) |strategy| {
        const command = try strategy_resolve(server, strategy);
        try argv.appendSlice(server.arena, &.{ "--strategy", command });
    }
    if (asked.jobs) |jobs| {
        try argv.appendSlice(server.arena, &.{ "--jobs", try print(server, "{d}", .{jobs}) });
    }
    if (asked.changed) |source| try argv.appendSlice(server.arena, &.{ "--changed", source });
    if (asked.changed_repository) |where| {
        try argv.appendSlice(server.arena, &.{ "--changed-repository", where });
    }
    if (asked.verify_replays) |percent| {
        try argv.appendSlice(server.arena, &.{ "--verify-replays", try print(server, "{d}", .{percent}) });
    }
    for (asked.retroactive) |text| try argv.appendSlice(server.arena, &.{ "--retroactive", text });
    if (asked.egress.len > 0) {
        try argv.appendSlice(server.arena, &.{ "--egress", try std.mem.join(server.arena, ",", asked.egress) });
    }
    if (asked.setup_only) try argv.append(server.arena, "--setup-only");
    if (asked.checkpoint_steps.len > 0) {
        // One a line, a command's own lines continued (explore's script).
        var script: std.ArrayList(u8) = .empty;
        for (asked.checkpoint_steps) |step| {
            try script.appendSlice(server.arena, try std.mem.replaceOwned(u8, server.arena, step, "\n", "\\\n"));
            try script.append(server.arena, '\n');
        }
        const path = try std.fs.path.join(server.arena, &.{ directory, "checkpoint-steps.script" });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = script.items });
    }
    if (asked.checkpoint_exec) |command| {
        // In the background, the platform waiting for its end: the guest's agent stays free, so
        // a replay can stop at any moment of it and run a command there, a session too (explore's
        // --start-script); in the foreground the agent took nothing else until it ended.
        const script = try std.fmt.allocPrint(server.arena, "det:background {s}\ndet:until {d} " ++ checkpoint_exec_done ++ "\n", .{
            try std.mem.replaceOwned(u8, server.arena, command, "\n", "\\\n"), checkpoint_exec_timeout_ms,
        });
        const path = try std.fs.path.join(server.arena, &.{ directory, checkpoint_exec_script });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = script });
    }
    try checkpoint_arguments(server, &argv, asked, directory);
    if (asked.from_snapshot) |snapshot| {
        try argv.appendSlice(server.arena, &.{
            "--from-snapshot",                                                               snapshot,
            "--fork-futures",                                                                "--at-vtime-ms",
            try print(server, "{d}", .{asked.from_vtime_ms orelse return error.BadRequest}), "--exec",
            "det:release",                                                                   "--continue",
        });
    }
    if (asked.from_branch) |branch| {
        try argv.appendSlice(server.arena, &.{
            "--from-branch",   try print(server, "{d}", .{branch}),
            "--from-vtime-ms",
            try print(server, "{d}", .{
                asked.from_vtime_ms orelse return error.BadRequest,
            }),
        });
    }
    return argv.items;
}

/// Every run, with what tells it apart (its system and scenario).
pub const CiJob = struct {
    repository: []const u8 = "",
    branch: []const u8 = "",
    commit: []const u8 = "",
    subject: []const u8 = "",
};

fn runs_list(server: *Server, out: *std.Io.Writer) !u16 {
    const runs = runs_copy(server);
    try out.writeAll("[");
    for (runs, 0..) |*run, index| {
        if (index > 0) try out.writeAll(",");
        try out.print("{{\"id\":{d},\"state\":\"{s}\"", .{ run.id, state(run) });
        const request_json = run_file(server, run.id, "request.json") catch "";
        if (std.json.parseFromSliceLeaky(RunRequest, server.arena, request_json, .{
            .ignore_unknown_fields = true,
        })) |asked| {
            const system = std.fs.path.basename(asked.program orelse asked.compose orelse asked.kubernetes orelse "");
            // from_run: a session's fork's futures name the run the session replays (a REPL in
            // the guest finds its forks' runs here: sdk.serve).
            try out.print(",\"system\":{f},\"scenario\":{f},\"from_branch\":{f},\"from_run\":{f}", .{
                std.json.fmt(system, .{}),            std.json.fmt(asked.scenario, .{}),
                std.json.fmt(asked.from_branch, .{}), std.json.fmt(asked.from_run, .{}),
            });
            // A run from a machine's checkpoint: its name as the API takes it (<machine>/here-<n>).
            if (asked.checkpoint) |path| {
                const machine = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
                try out.print(",\"checkpoint\":{f}", .{std.json.fmt(try print(server, "{s}/{s}", .{ machine, std.fs.path.basename(path) }), .{})});
            }
            if (asked.ci) |job| try out.print(",\"ci\":{f}", .{std.json.fmt(job, .{})});
        } else |_| {}
        try out.writeAll("}");
    }
    try out.writeAll("]\n");
    return 200;
}

/// The run's state, its record's lines but the timelines' (run, snapshot, summary, changed),
/// and its stats from its events database.
fn run_show(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    const record = run_file(server, run.id, "record.jsonl") catch "";
    try out.print("{{\"id\":{d},\"state\":\"{s}\"", .{ run.id, state(run) });
    if (run.draining) try out.writeAll(",\"draining\":true");
    if (run.status) |status| try out.print(",\"status\":{d}", .{status});
    // Why serve stopped it (the coverage gate's reason in its `stopped` file; someone's stop
    // leaves the file empty), and that it ended without coverage (its `uncovered` file).
    inline for (.{ .{ "stopped", "stopped_why" }, .{ "uncovered", "uncovered" } }) |pair| {
        if (run_file(server, run.id, pair[0])) |text| {
            const said = std.mem.trim(u8, text, " \n");
            if (said.len > 0) try out.print(",\"{s}\":{f}", .{ pair[1], std.json.fmt(said, .{}) });
        } else |_| {}
    }
    // When (seconds since the epoch, from its files): asked (its request, written once), last
    // started (its pid file, written by each explorer: a resume too), ended (its record's
    // last write, once it is not running).
    const directory = try run_directory(server, run.id);
    const times = [_]struct { []const u8, []const u8, bool }{
        .{ "created_s", "request.json", true },
        .{ "started_s", "pid", true },
        .{ "ended_s", "record.jsonl", run.status != null },
    };
    for (times) |time| {
        if (!time[2]) continue;
        const path = try std.fs.path.join(server.arena, &.{ directory, time[1] });
        if (mtime_s(server.arena, path)) |seconds| try out.print(",\"{s}\":{d}", .{ time[0], seconds });
    }
    // What its explorer says it is doing (a tree's status.json), while it runs; and how long it
    // has not said so, past what judging a generation takes (its nodes made by replays): an
    // explorer stalled (runs 177 and 200 sat hours in a deadlock, nothing showing it).
    if (run.status == null) if (run_file(server, run.id, "status.json")) |status| {
        const trimmed = std.mem.trim(u8, status, " \n");
        if (trimmed.len > 0 and trimmed[0] == '{') try out.print(",\"progress\":{s}", .{trimmed});
        const status_path = try std.fs.path.join(server.arena, &.{ directory, "status.json" });
        const silent_s = age_s(server.arena, status_path);
        if (silent_s >= stall_after_s) try out.print(",\"stalled_s\":{d}", .{silent_s});
    } else |_| {};
    // As asked (POST /runs, its seed drawn): what a run again starts from.
    if (run_file(server, run.id, "request.json")) |request| {
        const trimmed = std.mem.trim(u8, request, " \n");
        if (trimmed.len > 0 and trimmed[0] == '{') try out.print(",\"request\":{s}", .{trimmed});
    } else |_| {}
    // Its strategy's own name (its hello's), beside the command the request gives.
    if (run_file(server, run.id, "strategy-name")) |name| {
        try out.writeAll(",\"strategy_name\":");
        try std.json.Stringify.value(std.mem.trim(u8, name, " \n"), .{}, out);
    } else |_| {}
    // Its profile's command that turns the system's logs up: its analyses' explanation unless
    // one asks for another.
    if (system_explain(server, run.id)) |command| {
        try out.writeAll(",\"explain\":");
        try std.json.Stringify.value(command, .{}, out);
    }
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "run", "summary", "snapshot", "changed" }) |key| {
            const prefix = try print(server, "{{\"{s}\":", .{key});
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            try out.print(",\"{s}\":{s}", .{ key, line[prefix.len .. line.len - 1] });
        }
    }
    // Serve's own build, beside the run's (its request's `build`: a run keeps the explorer it
    // was created with, a resume too, so what changed since is not in it).
    try out.writeAll(",\"serve_build\":");
    try std.json.Stringify.value(build_options.commit, .{}, out);
    try out.writeAll(",\"stats\":");
    // One row: the object. A run whose events cannot be read (its explorer failed before any)
    // is still shown: the self-test's controller answered 500 about such runs, "lost".
    const text = answer_kept(server, run.id, .stats, &stats_compute) catch |err| {
        try out.print("null,\"stats_error\":\"{s}\"}}\n", .{@errorName(err)});
        return 200;
    };
    try out.writeAll(text[1 .. text.len - 1]);
    try out.writeAll("}\n");
    return 200;
}

pub const ReplayRequest = struct {
    branch: u32,
    at_vtime_ms: ?u64 = null,
    /// Or the moment is the first event matching this condition (query.zig).
    until: ?[]const u8 = null,
    /// With until, its temporal conditions (MomentQuery): the moment is then found in the run's
    /// events, not waited for by the replay.
    preceded_by: ?[]const u8 = null,
    not_preceded_by: ?[]const u8 = null,
    followed_by: ?[]const u8 = null,
    not_followed_by: ?[]const u8 = null,
    within: ?f64 = null,
    /// With until: this long (virtual time) before the condition holds.
    rewind_ms: ?u64 = null,
    exec: ?[]const u8 = null,
    /// Or a branch grown from the moment, step by step (Antithesis's advanced multiverse
    /// debugging: bash commands run or run in the background, branch.wait, branch.wait_until):
    /// each step's end is a moment, printed ("at moment"), the next step from it.
    steps: []const Step = &.{},
    /// A file put into a node at the moment, before the command or the steps (extract.zig's
    /// inject): a patched binary, a config, as `determinismo inject` puts one.
    inject: ?Inject = null,
    /// After the steps (or the command): on to the timeline's end.
    @"continue": bool = false,
    /// A fresh future from the moment (explore's --fresh-seed): the branch's own randomness, as
    /// Antithesis's branches diverge from their timeline; without it, the timeline's.
    fresh_seed: ?u64 = null,

    /// `content`: the file's bytes in base64 (standard, padded); `mode`: octal.
    pub const Inject = struct { node: []const u8, path: []const u8, content: []const u8, mode: []const u8 = "644" };

    pub const Step = struct {
        /// A command, in the runner, or in `node` (as docker exec runs it); in the background
        /// it runs beside the next steps.
        exec: ?[]const u8 = null,
        node: ?[]const u8 = null,
        background: bool = false,
        /// Run on this long (virtual time).
        wait_ms: ?u64 = null,
        /// Or until an event matches (query.zig), within timeout_ms unless 0.
        until: ?[]const u8 = null,
        timeout_ms: u64 = 0,
    };
};

/// A replay's steps as explore's --exec-script lines (vm.zig: det:wait, det:until; det-agent:
/// det:background).
pub fn steps_script(arena: std.mem.Allocator, steps: []const ReplayRequest.Step) ![]const u8 {
    var script: std.ArrayList(u8) = .empty;
    for (steps) |step| {
        const start = script.items.len;
        if (step.wait_ms) |ms| {
            try script.print(arena, "det:wait {d}\n", .{ms});
        } else if (step.until) |condition| {
            if (std.mem.indexOfScalar(u8, condition, '\n') != null) return error.BadRequest;
            try script.print(arena, "det:until {d} {s}\n", .{ step.timeout_ms, condition });
        } else if (step.exec) |command| {
            if (std.mem.indexOfAny(u8, command, "\n\x00") != null) return error.BadRequest;
            if (step.background) try script.appendSlice(arena, "det:background ");
            if (step.node) |node| {
                try script.print(arena, "det-nodes exec {s} sh -c {s}\n", .{ node, try shell_quote(arena, command) });
            } else {
                try script.print(arena, "{s}\n", .{command});
            }
        } else return error.BadRequest;
        // Its line, less the newline: what reaches the guest in one page (VM.step_size_max).
        if (script.items.len - start - 1 > VM.step_size_max) return error.BadRequest;
    }
    return script.items;
}

fn shell_quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, byte);
    }
    try quoted.append(arena, '\'');
    return quoted.items;
}

test steps_script {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const steps = [_]ReplayRequest.Step{
        .{ .exec = "echo it's", .node = "redis" },
        .{ .exec = "sleep 1; echo late", .background = true },
        .{ .wait_ms = 500 },
        .{ .until = "output.source=redis", .timeout_ms = 2000 },
    };
    try std.testing.expectEqualStrings("det-nodes exec redis sh -c 'echo it'\\''s'\n" ++
        "det:background sleep 1; echo late\ndet:wait 500\ndet:until 2000 output.source=redis\n", try steps_script(arena_state.allocator(), &steps));
    // A step longer than a page's worth is refused, not cut on its way to the guest.
    const long: [VM.step_size_max + 1]u8 = @splat('x');
    const fits = [_]ReplayRequest.Step{.{ .exec = long[0..VM.step_size_max] }};
    _ = try steps_script(arena_state.allocator(), &fits);
    const over = [_]ReplayRequest.Step{.{ .exec = &long }};
    try std.testing.expectError(error.BadRequest, steps_script(arena_state.allocator(), &over));
}

/// Replays one branch of a run (synchronously) and returns its output.
fn run_replay(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    var asked = try std.json.parseFromSliceLeaky(ReplayRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    // A timeline that extends another (a session's) has a person's steps on its tape, each
    // delivered at its moment: its replay's moment is a time, an event's found in the run's
    // events (as a session's is), not waited for.
    // The same for a moment named with temporal conditions (the event before or after another):
    // a query over the timeline's events.
    if (MomentQuery.of(asked)) |named| if (named.temporal() or try timeline_extends(server, run.id, asked.branch)) {
        asked.at_vtime_ms = try moment_of(server, run.id, asked.branch, named, asked.rewind_ms orelse 0);
        asked.until = null;
        asked.rewind_ms = null;
    };
    var argv = try replay_argv(server, run, &asked);
    const moment = asked.at_vtime_ms != null or asked.until != null;
    const saving = if (asked.at_vtime_ms) |ms|
        try replay_snapshots_use(server, run.id, &argv, asked.branch, ms, true)
    else
        false;
    defer if (saving) replay_snapshots_done(server, run.id);
    if (asked.exec) |command| {
        if (command.len > VM.step_size_max) return error.BadRequest;
        // With a file to put in first, the command follows it in the script (below).
        if (moment and asked.inject == null) try argv.appendSlice(server.arena, &.{ "--exec", command });
    }
    var script_path: ?[]const u8 = null;
    if (asked.steps.len > 0 or asked.inject != null) {
        if (!moment or (asked.exec != null and asked.steps.len > 0)) return error.BadRequest;
        var script: std.ArrayList(u8) = .empty;
        if (asked.inject) |file| {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(file.content) catch return error.BadRequest;
            const bytes = try server.arena.alloc(u8, size);
            decoder.decode(bytes, file.content) catch return error.BadRequest;
            const target = try print(server, "{s}:{s}", .{ file.node, file.path });
            try script.appendSlice(server.arena, extract.inject_lines(server.arena, bytes, target, file.mode, null) catch return error.BadRequest);
        }
        if (asked.exec) |command| try script.print(server.arena, "{s}\n", .{command});
        try script.appendSlice(server.arena, try steps_script(server.arena, asked.steps));
        var unique: u64 = 0;
        std.Io.random(server.io, std.mem.asBytes(&unique));
        const path = try std.fmt.allocPrint(server.arena, "{s}/steps-{x:0>16}.txt", .{ try run_directory(server, run.id), unique });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = script.items });
        try argv.appendSlice(server.arena, &.{ "--exec-script", path });
        script_path = path;
    }
    defer if (script_path) |path| std.Io.Dir.cwd().deleteFile(server.io, path) catch {};
    const acts = asked.exec != null or asked.steps.len > 0 or asked.inject != null;
    if (asked.@"continue" and acts) try argv.append(server.arena, "--continue");
    if (asked.fresh_seed) |seed| {
        if (!acts) return error.BadRequest;
        try argv.appendSlice(server.arena, &.{ "--fresh-seed", try print(server, "{d}", .{seed}) });
    }
    const result = try replay_run(server, argv.items);
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    return 200;
}

/// A moment replay's snapshots (replay_snapshots.zig): it goes on from the newest saved of its
/// timeline before `needed_ms` (--tape-snapshot), and saves the timeline just before it when that
/// one is far (`save`; a session's forks have a saver of their own). True when it saves: its run
/// is then busy (no removal takes what it saves against) until replay_snapshots_done. None for a
/// run from a machine's checkpoint (a CI shard's, a session's): its timelines start from that
/// snapshot, and explore refuses saving or starting from another there (every replay of a CI
/// timeline at a far moment was refused, its usage printed: run 4 of ci-jank, 2026-11-12).
fn replay_snapshots_use(server: *Server, id: u32, argv: *std.ArrayList([]const u8), branch: u32, needed_ms: u64, save: bool) !bool {
    if (try run_from_checkpoint(server, id)) return false;
    const planned = try replay_snapshots.plan(server.arena, server.io, try run_directory(server, id), branch, needed_ms);
    if (planned.from) |path| try argv.appendSlice(server.arena, &.{ "--tape-snapshot", path });
    if (!save) return false;
    const at_ms = planned.save_at_ms orelse return false;
    const shared = server.shared;
    var busy: std.ArrayList(u32) = .empty;
    shared.lock();
    shared.replays_saving[id] += 1;
    for (shared.replays_saving, 0..) |count, run| {
        if (count > 0) busy.append(server.arena, @intCast(run)) catch {};
    }
    shared.unlock();
    errdefer replay_snapshots_done(server, id);
    const runs = try std.fs.path.join(server.arena, &.{ server.options.data_directory, "runs" });
    replay_snapshots.evict(server.arena, server.io, runs, busy.items, replay_snapshots.budget_bytes);
    try argv.appendSlice(server.arena, &.{
        "--save-snapshots", planned.directory,
        "--save-at-ms",     try print(server, "{d}", .{at_ms}),
    });
    return true;
}

/// Whether a run's timelines start from a machine's checkpoint (its request.json's checkpoint).
fn run_from_checkpoint(server: *Server, id: u32) !bool {
    // No request: a run serve did not start (explore's own), never from a checkpoint.
    const json = run_file(server, id, "request.json") catch return false;
    const request = try std.json.parseFromSliceLeaky(struct { checkpoint: ?[]const u8 = null }, server.arena, json, .{
        .ignore_unknown_fields = true,
    });
    return request.checkpoint != null;
}

fn replay_snapshots_done(server: *Server, id: u32) void {
    server.shared.lock();
    defer server.shared.unlock();
    assert(server.shared.replays_saving[id] > 0);
    server.shared.replays_saving[id] -= 1;
}

/// A replay is someone looking (a debugging session, a triage's experiment): its VM takes a CPU
/// before the hunt's next ones, as checks and analyses do, or it queued for minutes behind a
/// 42-worker hunt (a triage's three experiments came back empty).
fn replay_run(server: *Server, argv: []const []const u8) !std.process.RunResult {
    var environment = std.process.Environ.Map.init(server.arena);
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    try environment.put("DETERMINISMO_DATA", server.options.data_directory);
    if (std.c.getenv("HOME")) |home| try environment.put("HOME", std.mem.span(home));
    try environment.put("DETERMINISMO_CPU_PRIORITY", "1");
    if (std.c.getenv("XDG_RUNTIME_DIR")) |value| try environment.put("XDG_RUNTIME_DIR", std.mem.span(value));
    return std.process.run(server.arena, server.io, .{ .argv = try reserved(server, argv), .environ_map = &environment });
}

/// How far before a moment Recover filtered logs looks, by default (Antithesis's: 10 s).
const recover_window_ms = 10_000;
/// The longest event line a recovery reads (an output line is cut well before it).
const recover_line_max = 1 << 22;

const RecoverRequest = struct { branch: u32, vtime_ns: u64, window_ms: u64 = recover_window_ms };

/// POST /runs/<id>/recover {branch, vtime_ns, window_ms?}: Antithesis's "Recover filtered logs".
/// The timeline replayed to just past the moment, its events written (a replay writes what
/// retroactive logging left out while exploring), and the output lines of the window before
/// the moment with one of the run's retroactive texts (its --retroactive and its profile's) ->
/// those events as queries give them, oldest first: none when nothing was left out there.
fn run_recover(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(RecoverRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    const texts = try retroactive_texts(server, run.id);
    if (texts.len == 0) return 200; // Nothing was left out: no replay.
    var argv = try replay_argv(server, run, &.{ .branch = asked.branch, .at_vtime_ms = asked.vtime_ns / std.time.ns_per_ms + 1 });
    // Its events from the window's start on.
    const needed_ms = (asked.vtime_ns -| asked.window_ms * std.time.ns_per_ms) / std.time.ns_per_ms;
    const saving = try replay_snapshots_use(server, run.id, &argv, asked.branch, needed_ms, true);
    defer if (saving) replay_snapshots_done(server, run.id);
    var unique: u64 = 0;
    std.Io.random(server.io, std.mem.asBytes(&unique));
    const path = try std.fmt.allocPrint(server.arena, "{s}/recover-{x:0>16}.jsonl", .{ try run_directory(server, run.id), unique });
    defer std.Io.Dir.cwd().deleteFile(server.io, path) catch {};
    try argv.appendSlice(server.arena, &.{ "--events", path });
    const result = try replay_run(server, argv.items);
    const file = std.Io.Dir.cwd().openFile(server.io, path, .{}) catch {
        try out.writeAll(result.stderr); // The replay failed before its first event: say why.
        return 500;
    };
    defer file.close(server.io);
    const buffer = try server.arena.alloc(u8, recover_line_max);
    var reader = file.reader(server.io, buffer);
    const start_ns = asked.vtime_ns -| asked.window_ms * std.time.ns_per_ms;
    const Line = struct { vtime_ns: u64 = 0, event: struct { output: ?struct { text: []const u8 = "" } = null } = .{} };
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.indexOf(u8, line, "\"output\"") == null) continue;
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const parsed = std.json.parseFromSliceLeaky(Line, scratch.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.vtime_ns < start_ns or parsed.vtime_ns > asked.vtime_ns) continue;
        const output = parsed.event.output orelse continue;
        for (texts) |text| {
            if (std.mem.indexOf(u8, output.text, text) == null) continue;
            try out.print("{s}\n", .{line});
            break;
        }
    }
    return 200;
}

/// A run's retroactive texts: its request's (--retroactive) and its pinned profile's.
fn retroactive_texts(server: *Server, id: u32) ![]const []const u8 {
    const Fields = struct { retroactive: []const []const u8 = &.{} };
    const request = try request_and_pin(server, id, Fields);
    return std.mem.concat(server.arena, []const u8, &.{ request[0].retroactive, request[1].retroactive });
}

/// Fields of a run's request (request.json) and of its pinned system (its profile's): the pin's
/// empty for a run from before pins.
fn request_and_pin(server: *Server, id: u32, comptime Fields: type) !struct { Fields, Fields } {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const request = try std.json.parseFromSliceLeaky(Fields, server.arena, try run_file(server, id, "request.json"), options);
    const pin_json = run_file(server, id, "events/system.pin.json") catch return .{ request, .{} };
    const pin = try std.json.parseFromSliceLeaky(struct { system_json: []const u8 = "{}" }, server.arena, pin_json, options);
    return .{ request, try std.json.parseFromSliceLeaky(Fields, server.arena, pin.system_json, options) };
}

const automations_file = "automations.jsonl";
/// At most this many replays a run's automations make (failing properties times automations).
const automation_replays_max = 32;
/// Of a replay's output, an automation keeps this much (its end: the command's output is last).
const automation_output_max = 1 << 16;

/// A run that ended on its own, with automations (its request's or its profile's): run on a
/// thread of their own (a replay each, minutes), the watcher going on.
fn automations_start(server: *Server, id: u32) void {
    const Fields = struct { automations: []const schema.Automation = &.{} };
    const both = request_and_pin(server, id, Fields) catch return;
    if (both[0].automations.len + both[1].automations.len == 0) return;
    const thread = std.Thread.spawn(.{}, automations_run, .{ server.shared, id }) catch |err| {
        std.debug.print("[determinismo] run {d}: automations not started: {s}\n", .{ id, @errorName(err) });
        return;
    };
    thread.detach();
}

/// Each automation at the first counterexample of each failing property it is for: the failing
/// timeline replayed to the moment (less its rewind), the command run there, a line each in
/// automations.jsonl {property, timeline, vtime_ns, exec, output} as it ends.
fn automations_run(shared: *Shared, id: u32) void {
    var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer request_arena.deinit();
    var server: Server = .{ .shared = shared, .options = shared.options, .io = shared.io, .arena = request_arena.allocator() };
    automations_each(&server, id) catch |err| {
        std.debug.print("[determinismo] run {d}: automations stopped: {s}\n", .{ id, @errorName(err) });
    };
}

fn automations_each(server: *Server, id: u32) !void {
    const Fields = struct { automations: []const schema.Automation = &.{} };
    const both = try request_and_pin(server, id, Fields);
    const automations = try std.mem.concat(server.arena, schema.Automation, &.{ both[0].automations, both[1].automations });
    const run = run_get(server, id) orelse return error.NotFound;
    const properties_json = try answer_kept(server, id, .properties, properties_compute);
    const rows = try std.json.parseFromSliceLeaky([]const StreamRow, server.arena, properties_json, .{ .ignore_unknown_fields = true });
    const path = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), automations_file });
    const file = try std.Io.Dir.cwd().createFile(server.io, path, .{ .truncate = true });
    defer file.close(server.io);
    var replays: u32 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.status, "failing")) continue;
        const timeline = row.first_failing_timeline orelse continue;
        const failure_ns = row.first_failure_ns orelse continue; // A sometimes never true.
        for (automations) |automation| {
            if (!automation_for(automation, row.message)) continue;
            if (replays == automation_replays_max) return;
            replays += 1;
            const at_ms = (failure_ns / std.time.ns_per_ms) -| automation.rewind_ms;
            var argv = try replay_argv(server, &run, &.{ .branch = @intCast(timeline), .at_vtime_ms = at_ms });
            try argv.appendSlice(server.arena, &.{ "--exec", automation.exec });
            const saving = try replay_snapshots_use(server, id, &argv, @intCast(timeline), at_ms, true);
            const ran = replay_run(server, argv.items);
            if (saving) replay_snapshots_done(server, id);
            const result = try ran;
            const output: []const u8 = try std.mem.concat(server.arena, u8, &.{ result.stdout, result.stderr });
            const line = try std.fmt.allocPrint(server.arena, "{f}\n", .{std.json.fmt(.{
                .property = row.message,
                .timeline = timeline,
                .vtime_ns = at_ms * std.time.ns_per_ms,
                .exec = automation.exec,
                .output = try utf8_valid(server.arena, output[output.len -| automation_output_max..]),
            }, .{})});
            try file.writeStreamingAll(server.io, line);
        }
    }
}

/// Whether an automation is for a failing property: its own, or every one when it names none.
fn automation_for(automation: schema.Automation, message: []const u8) bool {
    const property = automation.property orelse return true;
    return std.mem.eql(u8, property, message);
}

test automation_for {
    try std.testing.expect(automation_for(.{ .exec = "det-nodes list" }, "conserved"));
    try std.testing.expect(automation_for(.{ .property = "conserved", .exec = "x" }, "conserved"));
    try std.testing.expect(!automation_for(.{ .property = "conserved", .exec = "x" }, "ordered"));
}

/// The explore arguments that replay a run's timeline to a moment: its machine, system and
/// options rebuilt from its request, its branch's tape; the moment's commands are the caller's.
/// The explorer a run's work runs on: the one that ran it (kept), or this server's for runs from
/// before runs kept theirs.
fn explorer_of(server: *Server, original: *const RunRequest) ![]const u8 {
    // Its core this server's: this server's explorer, whatever else changed since.
    if (core_same(original, build_options.core_id, host_core.kvm_identity(server.arena), host_runs.state_format)) {
        return server.options.self;
    }
    const explorer = original.explorer orelse return server.options.self;
    // Runs kept before their explorers kept their library: given this build's.
    try host_runs.library_keep(server.arena, server.io, explorer, server.options.self);
    return explorer;
}

/// Whether a run's core is this server's (PLAN: a run pins its core): its core_id, the host's
/// KVM modules and the explorer's persisted formats, all three the same. An unknown on either
/// side is never the same.
pub fn core_same(original: *const RunRequest, core_id: []const u8, kvm: []const u8, format: u32) bool {
    const run_core = original.core orelse return false;
    const run_kvm = original.host_kvm orelse return false;
    const run_format = original.state_format orelse return false;
    if (std.mem.eql(u8, core_id, "unknown") or std.mem.eql(u8, kvm, "unknown")) return false;
    return std.mem.eql(u8, run_core, core_id) and std.mem.eql(u8, run_kvm, kvm) and run_format == format;
}

test core_same {
    const run: RunRequest = .{ .core = "c0", .host_kvm = "kvm:a,kvm_intel:b", .state_format = 1 };
    try std.testing.expect(core_same(&run, "c0", "kvm:a,kvm_intel:b", 1));
    // Another core, another KVM module, another format: the run's own explorer.
    try std.testing.expect(!core_same(&run, "c1", "kvm:a,kvm_intel:b", 1));
    try std.testing.expect(!core_same(&run, "c0", "kvm:x,kvm_intel:b", 1));
    try std.testing.expect(!core_same(&run, "c0", "kvm:a,kvm_intel:b", 2));
    // Unknown here, or a run from before (none recorded): its own.
    try std.testing.expect(!core_same(&run, "unknown", "kvm:a,kvm_intel:b", 1));
    try std.testing.expect(!core_same(&run, "c0", "unknown", 1));
    const before: RunRequest = .{};
    try std.testing.expect(!core_same(&before, "c0", "kvm:a,kvm_intel:b", 1));
}

/// A run from a machine's checkpoint (POST /runs {checkpoint, checkpoint_exec |
/// checkpoint_steps}): its timelines start from the checkpoint, held for the command or the
/// steps when given. The run's explore and every replay of its timelines alike (a session's
/// replay booted the system fresh instead, its tape a stranger's: ReplayDiverged, clj-orders).
const checkpoint_exec_script = "checkpoint-exec.script";
/// The start's command ended: the only command the agent runs in the background there.
const checkpoint_exec_done = "event=exec_done details.background=true";
/// How long the start's command may run (virtual time): a day, past any shard's budget.
const checkpoint_exec_timeout_ms = 24 * std.time.ms_per_hour;

fn checkpoint_arguments(server: *Server, argv: *std.ArrayList([]const u8), request: *const RunRequest, directory: []const u8) !void {
    try run_checkpoint_arguments(server.arena, server.io, argv, request, directory);
}

/// A run from a machine's checkpoint: its timelines' start (the snapshot, held for the start's
/// command or steps). Serve's replays and explore's and verify's `--run` alike: without it a CI
/// timeline replayed from the CLI started elsewhere ("scenario none", another timeline).
pub fn run_checkpoint_arguments(arena: std.mem.Allocator, io: std.Io, argv: *std.ArrayList([]const u8), request: *const RunRequest, directory: []const u8) !void {
    const snapshot = request.checkpoint orelse return;
    try argv.appendSlice(arena, &.{ "--from-snapshot", snapshot, "--branching", "flat" });
    if (request.checkpoint_exec) |command| {
        // Its start as it ran: in the background (checkpoint_exec_script, written as the run was
        // asked for), or in the foreground for a run asked for before.
        const script = try std.fs.path.join(arena, &.{ directory, checkpoint_exec_script });
        if (std.Io.Dir.cwd().access(io, script, .{})) |_| {
            try argv.appendSlice(arena, &.{ "--hold-scenario", "--exec-at-start", "--start-script", script });
        } else |_| {
            try argv.appendSlice(arena, &.{ "--hold-scenario", "--exec-at-start", "--exec", command });
        }
    }
    if (request.checkpoint_steps.len > 0) {
        const path = try std.fs.path.join(arena, &.{ directory, "checkpoint-steps.script" });
        try argv.appendSlice(arena, &.{ "--hold-scenario", "--exec-at-start", "--exec-script", path });
    }
}

fn replay_argv(server: *Server, run: *const Run, asked: *const ReplayRequest) !std.ArrayList([]const u8) {
    const request_json = try run_file(server, run.id, "request.json");
    const original = try std.json.parseFromSliceLeaky(RunRequest, server.arena, request_json, .{
        .ignore_unknown_fields = true,
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ try explorer_of(server, &original), "explore" });
    try argv.appendSlice(server.arena, try run_machine(server, run.id));
    try system_arguments(server.arena, &argv, &original);
    try pin_arguments(server, &argv, run.id);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{original.seed orelse 0}) });
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| {
        try argv.appendSlice(server.arena, &.{ "--profile", profile });
    }
    try checkpoint_arguments(server, &argv, &original, try run_directory(server, run.id));
    const tape = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{
        try run_directory(server, run.id), asked.branch,
    });
    try argv.appendSlice(server.arena, &.{ "--tape", tape });
    if (asked.at_vtime_ms) |ms| {
        try argv.appendSlice(server.arena, &.{ "--at-vtime-ms", try print(server, "{d}", .{ms}) });
    }
    if (asked.until) |condition| {
        try argv.appendSlice(server.arena, &.{ "--until", condition });
        if (asked.rewind_ms) |ms| {
            const text = try print(server, "{d}", .{ms});
            try argv.appendSlice(server.arena, &.{ "--rewind-ms", text });
        }
    }
    return argv;
}

/// Whether the run's timeline extends another (its tape's header says so: tape.Header.extends).
fn timeline_extends(server: *Server, run_id: u32, branch: u32) !bool {
    const path = try std.fmt.allocPrintSentinel(server.arena, "{s}/tapes/branch-{d}.jsonl", .{ try run_directory(server, run_id), branch }, 0);
    return @import("core").tape.extends_marked(path);
}

/// A moment named by events: `until`, a condition of the query language, with its temporal
/// conditions (query.Request's: the event preceded or followed by another, or not, `within`
/// seconds of virtual time): "the last connection opened before the crash" is until
/// event=ingress_open, not_followed_by event=ingress_open.
const MomentQuery = struct {
    until: []const u8,
    preceded_by: ?[]const u8 = null,
    not_preceded_by: ?[]const u8 = null,
    followed_by: ?[]const u8 = null,
    not_followed_by: ?[]const u8 = null,
    within: ?f64 = null,

    /// From a request's fields of the same names (a session's, a replay's); null without `until`.
    fn of(asked: anytype) ?MomentQuery {
        return .{
            .until = asked.until orelse return null,
            .preceded_by = asked.preceded_by,
            .not_preceded_by = asked.not_preceded_by,
            .followed_by = asked.followed_by,
            .not_followed_by = asked.not_followed_by,
            .within = asked.within,
        };
    }

    fn temporal(named: MomentQuery) bool {
        return named.preceded_by != null or named.not_preceded_by != null or
            named.followed_by != null or named.not_followed_by != null;
    }
};

/// The moment events name in a timeline, in ms: the first of its events (its ancestors' too)
/// that matches, `rewind_ms` before it (the millisecond it falls in or the next: it has happened
/// by then).
fn moment_of(server: *Server, run_id: u32, branch: u32, named: MomentQuery, rewind_ms: u64) !u64 {
    var connection = try run_database(server, run_id);
    defer run_release(server, run_id, &connection);
    const search = query.query_of(server.arena, .{
        .condition = named.until,
        .preceded_by = named.preceded_by,
        .not_preceded_by = named.not_preceded_by,
        .followed_by = named.followed_by,
        .not_followed_by = named.not_followed_by,
        .within = named.within,
        .branch = branch,
        .limit = 1,
    }) catch return error.BadRequest;
    var found: std.Io.Writer.Allocating = .init(server.arena);
    _ = query.answer(&connection, server.arena, &search, &found.writer, true) catch |err| {
        if (err == error.DuckDB) database_failed(server, &connection.failure);
        return err;
    };
    const line = std.mem.sliceTo(found.written(), '\n');
    const event = std.json.parseFromSliceLeaky(struct { vtime_ns: u64 }, server.arena, line, .{ .ignore_unknown_fields = true }) catch {
        server.detail = "no event of the timeline matches the condition";
        return error.NotFound;
    };
    return moment_ms(event.vtime_ns, rewind_ms);
}

fn moment_ms(event_ns: u64, rewind_ms: u64) u64 {
    return (event_ns -| rewind_ms * std.time.ns_per_ms + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
}

test moment_ms {
    try std.testing.expectEqual(@as(u64, 15_227), moment_ms(15_226_898_855, 0)); // It has happened.
    try std.testing.expectEqual(@as(u64, 15_177), moment_ms(15_226_898_855, 50));
    try std.testing.expectEqual(@as(u64, 0), moment_ms(10_000_000, 50)); // Never before the start.
}

const SessionRequest = struct {
    branch: u32,
    at_vtime_ms: ?u64 = null,
    /// Or the moment is an event's (MomentQuery: `until` and its temporal conditions), found in
    /// the run's events, `rewind_ms` before it.
    until: ?[]const u8 = null,
    preceded_by: ?[]const u8 = null,
    not_preceded_by: ?[]const u8 = null,
    followed_by: ?[]const u8 = null,
    not_followed_by: ?[]const u8 = null,
    within: ?f64 = null,
    rewind_ms: ?u64 = null,
    fresh_seed: ?u64 = null,
    exec: ?[]const u8 = null,
    /// The guest runs on between steps (explore --exec-live).
    live: bool = false,
    /// Connections from outside into a node's port (explore --ingress, det-ingress in the node):
    /// the session listens on `listen` ("ip:port", serve's host), each connection's bytes on
    /// its tape, the session's script replaying them. A live session (it must run to answer).
    ingress: ?Ingress = null,
    /// "paused" (a live session's default): the scenario's drivers and fault injector held at
    /// the moment (det:scenario-pause), the nodes answering the session alone; "running": the
    /// system under its workload, as a run's timeline goes on. A session that is not live stops
    /// the machine between its steps already.
    scenario: ?[]const u8 = null,
    /// What it would do, done nothing (session_plan): the same request without it does it.
    plan: bool = false,
};

const Ingress = struct { node: []const u8, port: u16, listen: []const u8 };

/// POST /runs/<id>/session {branch, at_vtime_ms | until, fresh_seed?, exec?, live?, ingress?}: the
/// timeline replayed to the moment and held there (or, live, running on), `exec` its first
/// command -> {session, output, done} once it is (the replay's output so far).
fn session_start(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(SessionRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    if ((asked.at_vtime_ms == null) == (asked.until == null)) return error.BadRequest;
    // Its moment as a time: an event's (until, rewind_ms before it) found in the run's events,
    // the timeline's and its ancestors' (a session's timeline is recorded from a time).
    const replay: ReplayRequest = .{
        .branch = asked.branch,
        .at_vtime_ms = asked.at_vtime_ms orelse try moment_of(server, run.id, asked.branch, MomentQuery.of(asked).?, asked.rewind_ms orelse 0),
    };
    if (asked.plan) return session_plan(server, run, asked, replay.at_vtime_ms.?, out);
    const shared = server.shared;
    const slot = session_claim(shared, run.id) orelse return 503; // Too many at once: end one.
    const id = slot.id;
    defer session_release(shared, slot, id);
    errdefer slot.id = 0;
    const directory = try std.fmt.allocPrint(server.arena, "{s}/sessions", .{try run_directory(server, run.id)});
    try std.Io.Dir.cwd().createDirPath(server.io, directory);
    var argv = try replay_argv(server, run, &replay);
    if (replay.at_vtime_ms) |ms| _ = try replay_snapshots_use(server, run.id, &argv, asked.branch, ms, false);
    // A timeline of the run from here on, under the run's next number, which its explorer takes
    // and says (session_scan): a fresh future's too, its seed a step on its tape.
    try argv.append(server.arena, "--extend");
    slot.forks.server = server.*;
    try argv.appendSlice(server.arena, &.{
        "--fork-snapshots", try std.fmt.allocPrint(server.arena, "{s}/{d}.forks", .{ directory, slot.id }),
        // The guest's sdk.serve: runs started and followed from inside the machine.
        "--serve-url",      try print(server, "http://{s}", .{listen_address(server)}),
    });
    // Its checkpoints (det:checkpoint) among the run's replay snapshots: a session opened on its
    // timeline at one starts from it (replay_snapshots_use), not from boot. None in a run from a
    // machine's checkpoint, whose replays never start from a snapshot of their own.
    if (!try run_from_checkpoint(server, run.id)) {
        try argv.appendSlice(server.arena, &.{ "--checkpoint-snapshots", try replay_snapshots.directory_of(server.arena, try run_directory(server, run.id)) });
    }
    if (asked.ingress) |ingress| {
        if (asked.exec != null) return error.BadRequest; // Its first step starts the relay.
        if (!listen_claim(shared, slot, ingress.listen) or !listen_free(ingress.listen)) {
            server.detail = try print(server, "{s} is held (another session's relay?): end it, or listen elsewhere", .{ingress.listen});
            return error.AddressInUse;
        }
        try argv.appendSlice(server.arena, &.{ "--ingress", ingress.listen });
    }
    try argv.append(server.arena, if (asked.live or asked.ingress != null) "--exec-live" else "--exec-interactive");
    // Its opening steps: the scenario paused (a live session's default), its relay started, the
    // command asked.
    const live = asked.live or asked.ingress != null;
    const scenario = asked.scenario orelse if (live) "paused" else "running";
    if (!std.mem.eql(u8, scenario, "paused") and !std.mem.eql(u8, scenario, "running")) return error.BadRequest;
    var opening: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, scenario, "paused")) try opening.appendSlice(server.arena, "det:scenario-pause\n");
    if (asked.ingress) |ingress| try opening.print(server.arena, "det:background /opt/determinismo/bin/det-ingress serve {s} {d}\n", .{ ingress.node, ingress.port });
    if (asked.exec) |command| try opening.print(server.arena, "{s}\n", .{command});
    if (opening.items.len > 0) {
        const path = try std.fmt.allocPrint(server.arena, "{s}/{d}.open.script", .{ directory, slot.id });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = opening.items });
        try argv.appendSlice(server.arena, &.{ "--exec-script", path });
    }
    if (asked.fresh_seed) |seed| try argv.appendSlice(server.arena, &.{ "--fresh-seed", try print(server, "{d}", .{seed}) });
    try session_spawn(server, slot, argv.items);
    slot.reader = try std.Thread.spawn(.{}, session_drain, .{ slot, server.io });
    return session_reply(server, slot, try session_wait(server, slot), out);
}

/// A session's plan (`plan: true`), the session's own choices up to its start, nothing done: its
/// moment, the timeline it would be (the first number free after the one it extends: another
/// session opened meanwhile may take it), where its replay would start (a replay snapshot of the
/// run's, as replay_snapshots_use chooses, or boot) and how much of the timeline that replays,
/// about that long in wall time at the timeline's own pace (its wall time over its virtual time,
/// as recorded; none for a timeline not ingested yet).
fn session_plan(server: *Server, run: *const Run, asked: SessionRequest, at_ms: u64, out: *std.Io.Writer) !u16 {
    const directory = try run_directory(server, run.id);
    const from_ms: ?u64 = if (try run_from_checkpoint(server, run.id)) null else from: {
        const planned = try replay_snapshots.plan(server.arena, server.io, directory, asked.branch, at_ms);
        const path = planned.from orelse break :from null;
        const name = std.fs.path.basename(path); // b<branch>-<ms>
        const dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse break :from null;
        break :from std.fmt.parseInt(u64, name[dash + 1 ..], 10) catch null;
    };
    var timeline = asked.branch;
    while (timeline < std.math.maxInt(u32)) {
        timeline += 1;
        const tape_path = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{ directory, timeline });
        std.Io.Dir.cwd().access(server.io, tape_path, .{}) catch break;
    }
    const replay_ms = at_ms -| (from_ms orelse 0);
    const Pace = struct { wall_ns: ?u64 = null, vtime_ns: ?u64 = null };
    const pace: ?Pace = pace: {
        var connection = run_database(server, run.id) catch break :pace null;
        defer run_release(server, run.id, &connection);
        break :pace connection.row(Pace, server.arena, "SELECT wall_ns, vtime_ns FROM timelines WHERE branch = $1", .{asked.branch}) catch null;
    };
    const wall_ms: ?u64 = if (pace) |row| if (row.wall_ns != null and row.vtime_ns != null and row.vtime_ns.? > 0)
        @intFromFloat(@as(f64, @floatFromInt(replay_ms)) * @as(f64, @floatFromInt(row.wall_ns.?)) / @as(f64, @floatFromInt(row.vtime_ns.?)))
    else
        null else null;
    const preview = session_preview(server, run.id, asked.branch, at_ms * std.time.ns_per_ms);
    try out.print("{f}", .{std.json.fmt(.{
        .plan = true,
        .timeline = timeline,
        .extends = asked.branch,
        .at_vtime_ms = at_ms,
        .from = if (from_ms != null) "snapshot" else "boot",
        .from_vtime_ms = from_ms orelse 0,
        .replay_ms = replay_ms,
        .wall_ms = wall_ms,
        .live = asked.live or asked.ingress != null,
        .faults = preview.faults,
        .nodes = preview.nodes,
        .failures = preview.failures,
        .draws = preview.draws,
        .frame = preview.frame,
    }, .{})});
    return 200;
}

/// What a moment of a timeline holds, from its recorded history alone (the run's database: no
/// machine runs), for a session's plan: the faults on at the moment or ended in the second
/// before it, each node's last start or end before it, the failed assertions and crashes of the
/// ten seconds before it, the timeline's choices made by then (each label's last value: its
/// setup's, its ancestors' and its own, labels of a few values), and its last frame (a game's
/// board). Each part empty when the run's database cannot say (a timeline not ingested yet).
const Preview = struct {
    const Fault = struct { vtime_ns: u64 = 0, kind: []const u8 = "", node: ?[]const u8 = null, peer: ?[]const u8 = null, duration_ns: ?u64 = null };
    const NodeState = struct { node: []const u8 = "", state: []const u8 = "", vtime_ns: u64 = 0 };
    const Failure = struct { vtime_ns: u64 = 0, kind: []const u8 = "", what: ?[]const u8 = null };
    const Draw = struct { name: []const u8 = "", drew: []const u8 = "" };
    const Frame = struct { vtime_ns: u64 = 0, board: ?[]const u8 = null };
    faults: []const Fault = &.{},
    nodes: []const NodeState = &.{},
    failures: []const Failure = &.{},
    draws: []const Draw = &.{},
    frame: ?Frame = null,
};

fn session_preview(server: *Server, run: u32, branch: u32, at_ns: u64) Preview {
    var connection = run_database(server, run) catch return .{};
    defer run_release(server, run, &connection);
    const arena = server.arena;
    var preview: Preview = .{};
    preview.faults = connection.rows(Preview.Fault, arena,
        \\SELECT vtime_ns, kind, node, peer, TRY_CAST(duration_ns AS UBIGINT) AS duration_ns
        \\FROM timeline_faults WHERE timeline = $1 AND vtime_ns <= $2
        \\    AND vtime_ns + coalesce(TRY_CAST(duration_ns AS UBIGINT), 0) + 1000000000 >= $2
        \\ORDER BY vtime_ns DESC LIMIT 8
    , .{ branch, at_ns }) catch &.{};
    preview.nodes = connection.rows(Preview.NodeState, arena,
        \\SELECT node, arg_max(name, vtime_ns) AS state, max(vtime_ns) AS vtime_ns
        \\FROM timeline_events WHERE timeline = $1 AND vtime_ns <= $2 AND node IS NOT NULL
        \\    AND name IN ('node_start', 'node_ready', 'node_kill', 'node_crash', 'node_stop', 'core_dump')
        \\GROUP BY node ORDER BY node
    , .{ branch, at_ns }) catch &.{};
    preview.failures = connection.rows(Preview.Failure, arena,
        \\SELECT vtime_ns, CASE WHEN kind = 'assert' THEN 'failed' ELSE name END AS kind,
        \\    CASE WHEN kind = 'assert' THEN name ELSE coalesce(event ->> '$.details.process', node) END AS what
        \\FROM timeline_events WHERE timeline = $1 AND vtime_ns <= $2 AND vtime_ns + 10000000000 >= $2
        \\    AND ((kind = 'assert' AND condition = false AND type = 'always') OR name IN ('core_dump', 'exit_stack'))
        \\ORDER BY vtime_ns DESC LIMIT 6
    , .{ branch, at_ns }) catch &.{};
    preview.draws = connection.rows(Preview.Draw, arena,
        \\SELECT name, arg_max(drew, pull) AS drew FROM timeline_draws
        \\WHERE timeline = $1 AND after_ns <= $2 AND (kind = 'options' OR count <= 16)
        \\GROUP BY name ORDER BY name
    , .{ branch, at_ns }) catch &.{};
    const frames = connection.rows(Preview.Frame, arena,
        \\SELECT vtime_ns, event ->> '$.details.board' AS board FROM timeline_events
        \\WHERE timeline = $1 AND vtime_ns <= $2 AND name = 'frame' ORDER BY vtime_ns DESC LIMIT 1
    , .{ branch, at_ns }) catch &.{};
    if (frames.len == 1) preview.frame = frames[0];
    return preview;
}

/// /sessions/<id>/step {exec} -> {output, done}; /sessions/<id>/end -> {output, done: true}.
/// What a machine boots (POST /machines): a system as a run names one, the fast VM's size,
/// and the checkpoint it goes on from (`<machine>/here-<n>`, as POST /machines/<id>/checkpoint
/// answers), if any.
const MachineRequest = struct {
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    vcpus: u32 = 4,
    memory_mib: u32 = 2048,
    from: ?[]const u8 = null,
};

/// /machines: fast VMs (docs/DEVELOPING.md), the primitive the products on determinismo work
/// with (docs/PRODUCTS.md: agent sandboxes, CI).
///   POST   /machines                     {program | compose, profile?, scenario?, vcpus?, memory_mib?,
///                                          from?} -> {machine}: booted (or restored from the
///                                          checkpoint `from`) and ready
///   GET    /machines                     [{machine, alive, directory, checkpoints}]
///   POST   /machines/<id>/exec           {node, command, timeout_s?} -> {status, output, truncated}
///   PUT    /machines/<id>/files?node=&path=   the body as that file
///   GET    /machines/<id>/files?node=&path=   that file
///   POST   /machines/<id>/checkpoint     -> {checkpoint}: the machine saved, going on
///   DELETE /machines/<id>                its machine stopped (its checkpoints stay)
/// Timelines from a checkpoint are runs: POST /runs with {checkpoint, checkpoint_exec |
/// checkpoint_steps} (held: the scenario not started) or {checkpoint} alone (the scenario).
fn machines_route(server: *Server, parts: *std.mem.TokenIterator(u8, .scalar), request: Request, out: *std.Io.Writer) !u16 {
    const eql = std.mem.eql;
    const id_text = parts.next() orelse {
        if (eql(u8, request.method, "POST")) {
            const asked = try std.json.parseFromSliceLeaky(MachineRequest, server.arena, request.body, .{ .ignore_unknown_fields = true });
            const id = try machine_create(server, asked);
            try out.print("{f}", .{std.json.fmt(.{ .machine = id }, .{})});
            return 201;
        }
        if (!eql(u8, request.method, "GET")) return error.NotFound;
        try out.writeAll("[");
        var first = true;
        for (&server.shared.machines) |*machine| {
            if (machine.id == 0) continue;
            if (!first) try out.writeAll(",");
            first = false;
            try out.print("{f}", .{std.json.fmt(.{
                .machine = machine.id,
                .alive = machine.alive(),
                .directory = machine.directory(),
                .checkpoints = machine.checkpoints,
            }, .{})});
        }
        try out.writeAll("]");
        return 200;
    };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return error.NotFound;
    const machine = for (&server.shared.machines) |*machine| {
        if (machine.id == id) break machine;
    } else return error.NotFound;
    const verb = parts.next() orelse {
        if (!eql(u8, request.method, "DELETE")) return error.NotFound;
        machine_stop(machine);
        machine.id = 0;
        return 204;
    };
    // One conversation with a machine at a time: its events are read in order.
    if (machine.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return 409;
    defer machine.busy.store(false, .release);
    const arena = server.arena;
    if (eql(u8, verb, "exec") and eql(u8, request.method, "POST")) {
        const Asked = struct { node: []const u8, command: []const u8, timeout_s: u32 = 600 };
        const asked = try std.json.parseFromSliceLeaky(Asked, arena, request.body, .{ .ignore_unknown_fields = true });
        const result = try machine.exec(arena, asked.node, asked.command, asked.timeout_s);
        try out.print("{f}", .{std.json.fmt(.{ .status = result.status, .output = result.output, .truncated = result.truncated }, .{})});
        return 200;
    }
    if (eql(u8, verb, "files")) {
        const node = query_value(server.query_string, "node") orelse return error.BadRequest;
        const path_raw = query_value(server.query_string, "path") orelse return error.BadRequest;
        const path = try percent_decode(arena, path_raw);
        if (eql(u8, request.method, "PUT")) {
            try machine.file_write(arena, node, path, request.body);
            return 204;
        }
        if (eql(u8, request.method, "GET")) {
            try out.writeAll(try machine.file_read(arena, node, path));
            return 200;
        }
        return error.NotFound;
    }
    if (eql(u8, verb, "egress") and eql(u8, request.method, "POST")) {
        // A way out for a node (docs/PRODUCTS.md, egress): det-egress in it, an HTTPS proxy on
        // 127.0.0.1:<port> (HTTPS_PROXY=http://127.0.0.1:<port>), and the host's relay making
        // the connections its allowlist names, for the machine's life.
        const Asked = struct { node: []const u8, port: u16 = 3128, allow: []const []const u8 };
        const asked = try std.json.parseFromSliceLeaky(Asked, arena, request.body, .{ .ignore_unknown_fields = true });
        if (asked.allow.len == 0) return error.BadRequest;
        const relay = try std.heap.page_allocator.create(egress_host.Relay);
        const allow = try std.heap.page_allocator.alloc([]const u8, asked.allow.len);
        for (asked.allow, allow) |entry, *kept| kept.* = try std.heap.page_allocator.dupe(u8, entry);
        relay.* = .{ .io = server.io, .machine = machine, .allow = allow };
        // Its events from now on: the proxy's start and its connections.
        relay.offset = machine.events_end();
        const started = try machine.exec_background(arena, try print(server, "det-nodes exec {s} /opt/determinismo/bin/det-egress serve {d}", .{ asked.node, asked.port }));
        _ = started;
        try machine.event_wait(arena, "egress_ready", 60);
        const thread = try std.Thread.spawn(.{}, egress_host.Relay.main, .{relay});
        thread.detach();
        try out.print("{f}", .{std.json.fmt(.{ .proxy = try print(server, "http://127.0.0.1:{d}", .{asked.port}) }, .{})});
        return 200;
    }
    if (eql(u8, verb, "checkpoint") and eql(u8, request.method, "POST")) {
        const name = try machine.checkpoint(arena);
        const reference = try std.fmt.allocPrint(arena, "{s}/{s}", .{ machine_reference(server, machine), name });
        try out.print("{f}", .{std.json.fmt(.{ .checkpoint = reference }, .{})});
        return 200;
    }
    return error.NotFound;
}

/// A machine started (`run --vcpus N --dev <its directory>`, from a checkpoint when asked) and
/// ready: its id. Its directory `<data>/machines/<id>`: its request, pid, events, output and
/// checkpoints.
fn machine_create(server: *Server, asked: MachineRequest) !u32 {
    const arena = server.arena;
    if ((asked.program == null) == (asked.compose == null)) return error.BadRequest;
    if (asked.vcpus < 2 or asked.vcpus > 32) return error.BadRequest;
    const shared = server.shared;
    // A machine holds a place on a CPU of its pool for its life (`run` takes it as it starts,
    // and a machine does not end by itself), machines_per_cpu of them a CPU: with every place
    // held, another waited ten minutes for one that could not come and failed without a word
    // (MachineFailed: the agent demo's fourth sandbox, on three reserved cores, when a machine
    // had a CPU to itself). Refused at once, saying so.
    const pool_cpus = try machine_cpus(server);
    const places = pool_cpus * server.options.machines_per_cpu;
    shared.lock();
    var alive: u32 = 0;
    for (&shared.machines) |*other| {
        // One being made (its slot taken, its process not started yet) will hold a CPU too.
        if (other.id != 0 and (other.pid <= 0 or other.alive())) alive += 1;
    }
    if (alive >= places) {
        shared.unlock();
        server.detail = try print(server, "every place for a machine is taken ({d} of {d}: {d} CPUs, {d} machines a CPU): delete one first", .{
            alive, places, pool_cpus, server.options.machines_per_cpu,
        });
        return error.NoFreeCpu;
    }
    const machine = for (&shared.machines) |*slot| {
        if (slot.id == 0) {
            slot.* = .{ .id = shared.machine_next };
            shared.machine_next += 1;
            break slot;
        }
    } else {
        shared.unlock();
        return error.TooManyMachines;
    };
    shared.unlock();
    errdefer machine.id = 0;
    const directory = try std.fs.path.join(arena, &.{ server.options.data_directory, "machines", try print(server, "{d}", .{machine.id}) });
    try std.Io.Dir.cwd().createDirPath(server.io, directory);
    try machine.directory_set(directory);
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, "request.json" }),
        .data = try print(server, "{f}", .{std.json.fmt(asked, .{})}),
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ server.options.self, "run" });
    try argv.appendSlice(arena, server.options.machine);
    if (asked.program) |program| try argv.appendSlice(arena, &.{ "--program", program });
    if (asked.compose) |compose| try argv.appendSlice(arena, &.{ "--compose", compose });
    if (asked.profile) |profile| try argv.appendSlice(arena, &.{ "--profile", profile });
    if (asked.scenario) |scenario| try argv.appendSlice(arena, &.{ "--scenario", scenario });
    try argv.appendSlice(arena, &.{
        "--vcpus",            try print(server, "{d}", .{asked.vcpus}),
        "--memory-mib",       try print(server, "{d}", .{asked.memory_mib}),
        "--dev",              directory,
        "--machines-per-cpu", try print(server, "{d}", .{server.options.machines_per_cpu}),
    });
    if (asked.from) |reference| try argv.appendSlice(arena, &.{ "--from-snapshot", try checkpoint_path(server, reference) });
    const output = try std.fs.path.join(arena, &.{ directory, "output.log" });
    machine.pid = try spawn_logged(server, try reserved(server, argv.items), output);
    // Given up, it is stopped: one left waiting took a CPU when one came free and ran on, a
    // machine of no one's, on a core its neighbours' VMs then waited for (2026-11-17).
    errdefer machine_stop(machine);
    // Its pid with it: a serve started again adopts the machine (machines_adopt).
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, "pid" }),
        .data = try print(server, "{d}\n", .{machine.pid}),
    });
    machine.events_offset = 0;
    machine.checkpoints = 0;
    // Its events file appears once its machine is up.
    const events = try std.fs.path.join(arena, &.{ directory, "events.jsonl" });
    const start_seconds = server.options.machine_start_ns / std.time.ns_per_s;
    for (0..start_seconds * 10) |_| {
        std.Io.Dir.cwd().access(server.io, events, .{}) catch {
            if (!machine.alive()) {
                server.detail = try print(server, "the machine ended as it started: {s}", .{try output_last(server, output)});
                return error.MachineFailed;
            }
            sleep_ms(100);
            continue;
        };
        break;
    } else {
        server.detail = try print(server, "the machine was not up after {d} s and was stopped (before its boot it waits " ++
            "for a CPU of its pool and for memory, which others' VMs may hold): {s}", .{ start_seconds, try output_last(server, output) });
        return error.MachineFailed;
    }
    machine.ready_wait(arena, asked.from != null, 1800) catch {
        server.detail = try print(server, "the machine's system was not ready and it was stopped: {s}", .{try output_last(server, output)});
        return error.MachineFailed;
    };
    try machine_watch(server, machine);
    return machine.id;
}

/// The machine's requests from inside it (its guest's events), for its life, in a thread of
/// their own (an events offset of its own): `explore_request` (sdk.explore_here_request, the
/// Clojure SDK's `w/explore-here!`): the machine checkpointed and a run of timelines from it
/// started, as asked; its id written back to the asker's FIFO.
fn machine_watch(server: *Server, machine: *Machine) !void {
    const watcher = try std.heap.page_allocator.create(MachineWatcher);
    watcher.* = .{ .shared = server.shared, .options = server.options, .io = server.io, .machine = machine, .offset = machine.events_end() };
    const thread = try std.Thread.spawn(.{}, MachineWatcher.main, .{watcher});
    thread.detach();
}

const MachineWatcher = struct {
    shared: *Shared,
    options: Options,
    io: std.Io,
    machine: *Machine,
    offset: u64,

    fn main(watcher: *MachineWatcher) void {
        var pending: std.ArrayList(u8) = .empty;
        var chunk: [64 * 1024]u8 = undefined;
        var path_buffer: [Machine.directory_max + 16]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/events.jsonl", .{watcher.machine.directory()}, 0) catch return;
        while (watcher.machine.alive()) {
            const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(opened) != .SUCCESS) return;
            const read = linux.pread(@intCast(opened), &chunk, chunk.len, @intCast(watcher.offset + pending.items.len));
            _ = linux.close(@intCast(opened));
            if (linux.errno(read) != .SUCCESS) return;
            if (read == 0) {
                sleep_ms(20);
                continue;
            }
            pending.appendSlice(std.heap.page_allocator, chunk[0..read]) catch return;
            const last = std.mem.lastIndexOfScalar(u8, pending.items, '\n') orelse continue;
            var lines = std.mem.splitScalar(u8, pending.items[0..last], '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "\"explore_request\"") == null) continue;
                watcher.explore(line) catch |err| std.debug.print("[determinismo] machine {d}: explore request: {s}\n", .{ watcher.machine.id, @errorName(err) });
            }
            watcher.offset += last + 1;
            const rest = pending.items.len - last - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[last + 1 ..]);
            pending.items.len = rest;
        }
    }

    fn explore(watcher: *MachineWatcher, line: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        var server: Server = .{ .shared = watcher.shared, .options = watcher.options, .io = watcher.io, .arena = arena_state.allocator() };
        const arena = server.arena;
        const Details = struct { branches: u32 = 16, time_budget: ?[]const u8 = null, reply: []const u8 = "" };
        const Line = struct { event: struct { event: []const u8 = "", details: Details = .{} } = .{} };
        const asked = (try std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true })).event.details;
        const machine = watcher.machine;
        // The machine free (a request of the API's may be talking to it), then checkpointed.
        while (machine.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) sleep_ms(50);
        const name = name: {
            defer machine.busy.store(false, .release);
            break :name try machine.checkpoint(arena);
        };
        const reference = try print(&server, "{s}/{s}", .{ machine_reference(&server, machine), name });
        const request_text = try std.Io.Dir.cwd().readFileAlloc(server.io, try std.fs.path.join(arena, &.{ machine.directory(), "request.json" }), arena, .limited(1 << 16));
        const made = try std.json.parseFromSliceLeaky(MachineRequest, arena, request_text, .{ .ignore_unknown_fields = true });
        var discard: std.Io.Writer.Discarding = .init(&.{});
        const run_id = try run_start(&server, .{
            .program = made.program,
            .compose = made.compose,
            .profile = made.profile,
            .scenario = made.scenario,
            .memory_mib = made.memory_mib,
            .branches = asked.branches,
            .time_budget = asked.time_budget,
            .branching = "flat",
            .checkpoint = try checkpoint_path(&server, reference),
        }, &discard.writer);
        if (asked.reply.len == 0 or asked.reply.len > 200) return;
        const reply = try print(&server, "{f}\n", .{std.json.fmt(.{ .run = run_id, .checkpoint = reference }, .{})});
        const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(reply.len));
        _ = std.base64.standard.Encoder.encode(encoded, reply);
        try machine.action(try print(&server, "det:send {s} {s}", .{ asked.reply, encoded }));
    }
};

/// Machines that outlived a serve (each in its own session): taken back at start from their
/// directories (their pid, their checkpoints, their events read from their end). A dead one is
/// left on disk, its checkpoints still usable.
fn machines_adopt(server: *Server) void {
    const arena = server.arena;
    const root = std.fs.path.join(arena, &.{ server.options.data_directory, "machines" }) catch return;
    var directory = std.Io.Dir.cwd().openDir(server.io, root, .{ .iterate = true }) catch return;
    defer directory.close(server.io);
    var entries = directory.iterate();
    var adopted: u32 = 0;
    while (entries.next(server.io) catch null) |entry| {
        const id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        server.shared.machine_next = @max(server.shared.machine_next, id + 1);
        const machine_directory = std.fs.path.join(arena, &.{ root, entry.name }) catch continue;
        const pid_text = std.Io.Dir.cwd().readFileAlloc(server.io, std.fs.path.join(arena, &.{ machine_directory, "pid" }) catch continue, arena, .limited(64)) catch continue;
        const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, pid_text, " \n"), 10) catch continue;
        const slot = for (&server.shared.machines) |*slot| {
            if (slot.id == 0) break slot;
        } else return;
        slot.* = .{ .id = id, .pid = pid };
        slot.directory_set(machine_directory) catch {
            slot.id = 0;
            continue;
        };
        if (!slot.alive()) {
            slot.* = .{};
            continue;
        }
        const events = std.Io.Dir.cwd().statFile(server.io, std.fs.path.join(arena, &.{ machine_directory, "events.jsonl" }) catch continue, .{}) catch null;
        slot.events_offset = if (events) |stat| stat.size else 0;
        var checkpoints: u32 = 0;
        while (true) : (checkpoints += 1) {
            const saved = std.fs.path.join(arena, &.{ machine_directory, print(server, "here-{d}.state", .{checkpoints + 1}) catch break }) catch break;
            std.Io.Dir.cwd().access(server.io, saved, .{}) catch break;
        }
        slot.checkpoints = checkpoints;
        machine_watch(server, slot) catch {};
        adopted += 1;
    }
    if (adopted > 0) std.debug.print("[determinismo] machines: {d} running, taken back\n", .{adopted});
}

/// `<machine>`: how its checkpoints are named (`<machine>/here-<n>`), under the data
/// directory's machines.
fn machine_reference(server: *Server, machine: *const Machine) []const u8 {
    _ = server;
    return std.fs.path.basename(machine.directory());
}

/// A checkpoint's snapshot on disk (`<machine>/here-<n>`), refused outside the machines'
/// directory.
fn checkpoint_path(server: *Server, reference: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, reference, "..") != null or reference.len == 0 or reference[0] == '/') return error.BadRequest;
    return std.fs.path.join(server.arena, &.{ server.options.data_directory, "machines", reference });
}

/// How many CPUs machines can take: their pool's size, asked where they run (`reserved`: the
/// reserved cores' scope when serve has them; serve's own CPUs, the runs', are not theirs).
fn machine_cpus(server: *Server) !u32 {
    const result = try replay_run(server, &.{ server.options.self, "cpus" });
    const Pool = struct { cpus: u32 = 0 };
    const pool = std.json.parseFromSliceLeaky(Pool, server.arena, result.stdout, .{ .ignore_unknown_fields = true }) catch Pool{};
    if (pool.cpus == 0) {
        server.detail = try print(server, "`{s} cpus` did not say how many CPUs machines have: {s}", .{
            server.options.self, std.mem.trim(u8, result.stderr[0..@min(result.stderr.len, 300)], " \n"),
        });
        return error.MachineCpusUnknown;
    }
    return pool.cpus;
}

/// The last line of a machine's output (what it said before it ended or was given up), or
/// that it said nothing.
fn output_last(server: *Server, path: []const u8) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, .limited(16 << 20)) catch "";
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var last: []const u8 = "";
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len > 0) last = line;
    }
    if (last.len == 0) return "it printed nothing";
    return print(server, "its output's last line: {s}", .{last[0..@min(last.len, 300)]});
}

fn machine_stop(machine: *Machine) void {
    if (machine.pid <= 0) return;
    _ = linux.kill(-machine.pid, linux.SIG.TERM); // Its process group (setsid'd).
    _ = linux.kill(machine.pid, linux.SIG.TERM);
    for (0..100) |_| {
        var status: i32 = 0;
        const reaped = linux.waitpid(machine.pid, &status, linux.W.NOHANG);
        if (linux.errno(reaped) != .SUCCESS or reaped == machine.pid) break;
        sleep_ms(50);
    } else _ = linux.kill(machine.pid, linux.SIG.KILL);
    machine.pid = 0;
}

/// A child in its own session, its output and errors in `log`: its pid.
fn spawn_logged(server: *Server, argv: []const []const u8, log: []const u8) !linux.pid_t {
    const arena = server.arena;
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/";
    const environment = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_DATA={s}", .{server.options.data_directory}, 0),
        try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0),
        try runtime_directory_entry(arena),
    };
    const log_z = try arena.dupeSentinel(u8, log, 0);
    const log_fd = linux.open(log_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(log_fd) != .SUCCESS) return error.LogUnwritable;
    defer _ = linux.close(@intCast(log_fd));
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        _ = linux.dup2(@intCast(null_fd), 0);
        _ = linux.dup2(@intCast(log_fd), 1);
        _ = linux.dup2(@intCast(log_fd), 2);
        _ = linux.setsid();
        _ = linux.execve(argv_z[0].?, argv_z.ptr, &environment);
        linux.exit_group(127);
    }
    return @intCast(pid);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_ms(ms: u64) void {
    const pause: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}

/// `%xx` sequences decoded (a query value's path).
fn percent_decode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        if (text[at] == '%' and at + 2 < text.len + 0 and at + 2 <= text.len - 1) {
            const byte = std.fmt.parseInt(u8, text[at + 1 .. at + 3], 16) catch {
                try out.append(arena, text[at]);
                continue;
            };
            try out.append(arena, byte);
            at += 2;
        } else if (text[at] == '+') {
            try out.append(arena, ' ');
        } else try out.append(arena, text[at]);
    }
    return out.items;
}

fn sessions_route(server: *Server, parts: *std.mem.TokenIterator(u8, .scalar), request: Request, out: *std.Io.Writer) !u16 {
    const id = std.fmt.parseInt(u32, parts.next() orelse return error.NotFound, 10) catch return error.NotFound;
    const verb = parts.next() orelse return error.NotFound;
    if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, verb, "latest")) return session_latest(server, id, out);
    if (!std.mem.eql(u8, request.method, "POST")) return error.NotFound;
    const session = for (&server.shared.sessions) |*session| {
        if (session.id == id) break session;
    } else return error.NotFound;
    if (session.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return 409; // A request runs.
    defer session_release(server.shared, session, id);
    if (std.mem.eql(u8, verb, "step")) {
        // One step (exec), or several in order (steps): a command made of steps, as a
        // composite step is (det:ask), in one request; each recorded with its moment.
        const Step = struct { exec: []const u8 = "", steps: []const []const u8 = &.{} };
        const asked = try std.json.parseFromSliceLeaky(Step, server.arena, request.body, .{ .ignore_unknown_fields = true });
        const steps = if (asked.exec.len > 0) &.{asked.exec} else asked.steps;
        if (steps.len == 0 or (asked.exec.len > 0 and asked.steps.len > 0)) return error.BadRequest;
        var lines: std.ArrayList(u8) = .empty;
        for (steps) |step| {
            if (step.len == 0 or step.len > VM.step_size_max or std.mem.indexOfScalar(u8, step, '\n') != null) return error.BadRequest;
            try lines.print(server.arena, "{s}\n", .{step});
        }
        if (!fd_write_all(session.input, lines.items)) return session_reply(server, session, try session_wait(server, session), out);
        var whole: std.ArrayList(u8) = .empty;
        for (steps) |_| {
            const reply = try session_wait(server, session);
            try whole.appendSlice(server.arena, reply.output);
            if (reply.done) return session_reply(server, session, .{ .output = whole.items, .done = true }, out);
        }
        return session_reply(server, session, .{ .output = whole.items, .done = false }, out);
    }
    if (std.mem.eql(u8, verb, "forks")) return session_forks_list(server, session, out);
    if (std.mem.eql(u8, verb, "end")) return session_end(server, session, out);
    return error.NotFound;
}

/// GET /sessions/<id>/latest?event=<name>: the last event of that name the session's timeline
/// said so far, as its events file has it (one JSON line: seq, vtime_ns, event), read from the
/// file's end while the session runs (a window following a session: a game's `frame` events,
/// drawn as they come); 204 for none yet. Whatever step the session is in: it only reads.
fn session_latest(server: *Server, id: u32, out: *std.Io.Writer) !u16 {
    const session = for (&server.shared.sessions) |*session| {
        if (session.id == id) break session;
    } else return error.NotFound;
    const name = query_value(server.query_string, "event") orelse return error.BadRequest;
    if (name.len == 0 or name.len > 64 or std.mem.indexOfAny(u8, name, "\"\\") != null) return error.BadRequest;
    const timeline = session.timeline.load(.acquire);
    if (timeline == timeline_none) return 204;
    const path = try std.fmt.allocPrintSentinel(server.arena, "{s}/events/branch-{d}.jsonl", .{ try run_directory(server, session.run), timeline }, 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 204;
    defer _ = linux.close(@intCast(fd));
    const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return 204;
    const size: u64 = @intCast(end);
    const tail = try server.arena.alloc(u8, @intCast(@min(size, latest_tail_bytes)));
    const read = linux.pread(@intCast(fd), tail.ptr, tail.len, @intCast(size - tail.len));
    if (linux.errno(read) != .SUCCESS) return 204;
    // Whole lines only: the last may be half written (an event's parts are written one by one).
    const whole = tail[0 .. (std.mem.lastIndexOfScalar(u8, tail[0..read], '\n') orelse return 204) + 1];
    const needle = try std.fmt.allocPrint(server.arena, "\"event\":{{\"event\":\"{s}\"", .{name});
    var lines = std.mem.splitBackwardsScalar(u8, whole, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        try out.writeAll(line);
        return 200;
    }
    return 204;
}

/// How much of a session's events file `latest` reads from its end.
const latest_tail_bytes = 256 << 10;

/// Its input closed (the machine stops at its next step's read), its output to its end.
fn session_end(server: *Server, session: *Session, out: *std.Io.Writer) !u16 {
    assert(session.busy.load(.acquire));
    if (session.input >= 0) _ = linux.close(session.input);
    session.input = -1;
    var reply = try session_wait(server, session);
    var whole: std.ArrayList(u8) = .empty;
    try whole.appendSlice(server.arena, reply.output);
    while (!reply.done) {
        reply = try session_wait(server, session);
        try whole.appendSlice(server.arena, reply.output);
    }
    return session_reply(server, session, .{ .output = whole.items, .done = true }, out);
}

/// A free slot taken for a session of `run`, busy (held by the request starting it: a step or
/// an end of the same id waits for its start, 409), or null with all sessions_max in use. A
/// start that was not busy, ended at once by a concurrent end, freed its log twice and took
/// serve down (pnap 2026-11-14 04:03).
fn session_claim(shared: *Shared, run: u32) ?*Session {
    shared.lock();
    defer shared.unlock();
    const slot = for (&shared.sessions) |*session| {
        if (session.id == 0) break session;
    } else return null;
    slot.* = .{ .id = shared.session_next, .run = run, .busy = .init(true), .used_ns = monotonic_ns() };
    shared.session_next += 1;
    return slot;
}

/// A request on session `id` over: busy released and its idle time counted from now, unless
/// the request ended it (its slot free, or another session's by now: left alone).
fn session_release(shared: *Shared, session: *Session, id: u32) void {
    shared.lock();
    defer shared.unlock();
    if (session.id != id) return;
    assert(session.busy.load(.acquire));
    session.used_ns = monotonic_ns();
    session.busy.store(false, .release);
}

/// Whether the session ended its last request `idle_ns` or more before `now_ns` and none runs.
fn session_idle(session: *const Session, now_ns: u64, idle_ns: u64) bool {
    return session.id != 0 and !session.busy.load(.acquire) and now_ns -| session.used_ns >= idle_ns;
}

/// Sessions idle past Options.session_idle_ns ended, each on a thread of its own (an end waits
/// for its machine to stop; the watcher goes on). Hunt-free: sessions are a person's.
fn sessions_idle_end(shared: *Shared) void {
    const now = monotonic_ns();
    for (&shared.sessions) |*session| {
        shared.lock();
        const id = session.id;
        const claimed = session_idle(session, now, shared.options.session_idle_ns) and
            session.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
        shared.unlock();
        if (!claimed) continue;
        const thread = std.Thread.spawn(.{}, session_idle_end_one, .{ shared, session, id }) catch {
            session_release(shared, session, id);
            continue;
        };
        thread.detach();
    }
}

fn session_idle_end_one(shared: *Shared, session: *Session, id: u32) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    var server: Server = .{ .shared = shared, .options = shared.options, .io = shared.io, .arena = arena_state.allocator() };
    var discard: std.Io.Writer.Allocating = .init(server.arena);
    std.debug.print("[determinismo] session {d} ended: no request for {d} min\n", .{ id, shared.options.session_idle_ns / std.time.ns_per_min });
    _ = session_end(&server, session, &discard.writer) catch {};
    session_release(shared, session, id);
}

test "a session is busy from its start, and idle only past its time with no request running" {
    const shared = try std.testing.allocator.create(Shared);
    defer std.testing.allocator.destroy(shared);
    shared.mutex = .init;
    shared.io = std.testing.io;
    shared.sessions = @splat(.{});
    shared.session_next = 1;
    const slot = session_claim(shared, 13).?;
    const id = slot.id;
    // A step or an end of the session being started is refused (409), as sessions_route asks.
    try std.testing.expect(slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null);
    try std.testing.expect(!session_idle(slot, slot.used_ns + std.time.ns_per_hour, std.time.ns_per_min));
    session_release(shared, slot, id);
    try std.testing.expect(!slot.busy.load(.acquire));
    try std.testing.expect(!session_idle(slot, slot.used_ns + std.time.ns_per_s, std.time.ns_per_min));
    try std.testing.expect(session_idle(slot, slot.used_ns + std.time.ns_per_hour, std.time.ns_per_min));
    // Ended by its request (the slot taken by another since): the release leaves it alone.
    for (&shared.sessions) |*other| other.id = 1; // All in use.
    try std.testing.expect(session_claim(shared, 13) == null);
    slot.* = .{ .id = 99, .busy = .init(true) };
    session_release(shared, slot, id);
    try std.testing.expect(slot.busy.load(.acquire));
}

const SessionRead = struct { output: []const u8, done: bool };

/// The session's output up to its step's end (the marker, left out), or to its end: taken from
/// what its reader gathered.
fn session_wait(server: *Server, session: *Session) !SessionRead {
    while (true) {
        session.mutex.lockUncancelable(server.io);
        if (std.mem.indexOf(u8, session.log.items, step_done_marker)) |at| {
            const output = try server.arena.dupe(u8, session.log.items[0..at]);
            const rest = session.log.items[at + step_done_marker.len ..];
            std.mem.copyForwards(u8, session.log.items[0..rest.len], rest);
            session.log.items.len = rest.len;
            session.mutex.unlock(server.io);
            return .{ .output = output, .done = false };
        }
        if (session.ended) {
            const output = try server.arena.dupe(u8, session.log.items);
            session.log.items.len = 0;
            session.mutex.unlock(server.io);
            return .{ .output = output, .done = true };
        }
        session.mutex.unlock(server.io);
        // A REPL's step answers in milliseconds: looked at as often.
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
}

/// The session's reader: its output into its log as it comes, the log's tail kept.
fn session_drain(session: *Session, io: std.Io) void {
    const allocator = std.heap.page_allocator;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const result = linux.read(session.output, &chunk, chunk.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => break,
        }
        if (result == 0) break;
        session_scan(session, chunk[0..result]);
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);
        session.log.appendSlice(allocator, chunk[0..result]) catch break;
        if (session.log.items.len > session_log_max) {
            const drop = session.log.items.len - session_log_max;
            std.mem.copyForwards(u8, session.log.items[0..session_log_max], session.log.items[drop..]);
            session.log.items.len = session_log_max;
        }
    }
    session.mutex.lockUncancelable(io);
    session.ended = true;
    session.mutex.unlock(io);
}

/// The session's output, line by line as it comes: the timeline it records (its explorer's
/// first word); a fork the guest asked (its count), then its machine saved ("snapshot
/// written"): its futures started.
fn session_scan(session: *Session, chunk: []const u8) void {
    const allocator = std.heap.page_allocator;
    const forks = &session.forks;
    forks.carry.appendSlice(allocator, chunk) catch return;
    while (std.mem.indexOfScalar(u8, forks.carry.items, '\n')) |end| {
        const line = forks.carry.items[0..end];
        if (timeline_said(line)) |index| session.timeline.store(index, .release);
        const asked = "{\"fork\":{\"count\":";
        if (std.mem.indexOf(u8, line, asked)) |at| {
            const digits = line[at + asked.len ..];
            const stop = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
            forks.asked = std.fmt.parseInt(u32, digits[0..stop], 10) catch 0;
        }
        const written = "[determinismo] snapshot written ";
        if (std.mem.startsWith(u8, line, written) and forks.asked > 0) {
            session_futures_start(session, std.mem.trim(u8, line[written.len..], " \r")) catch |err| {
                std.debug.print("[determinismo] a session's futures: {t}\n", .{err});
            };
            forks.asked = 0;
        }
        const rest = forks.carry.items[end + 1 ..];
        std.mem.copyForwards(u8, forks.carry.items[0..rest.len], rest);
        forks.carry.items.len = rest.len;
    }
}

/// The address a session's relay will listen on, its own from here to its end: false when
/// another session of serve's asked for it (whether or not its explorer listens yet), or it is
/// too long to keep.
fn listen_claim(shared: *Shared, slot: *Session, address: []const u8) bool {
    if (address.len == 0 or address.len > listen_size_max) return false;
    shared.lock();
    defer shared.unlock();
    for (&shared.sessions) |*other| {
        if (other == slot or other.id == 0) continue;
        if (std.mem.eql(u8, other.listen[0..other.listen_size], address)) return false;
    }
    @memcpy(slot.listen[0..address.len], address);
    slot.listen_size = @intCast(address.len);
    return true;
}

test "a relay's address is one session's: asked again while the first has not listened yet, refused" {
    const shared = try std.testing.allocator.create(Shared);
    defer std.testing.allocator.destroy(shared);
    shared.mutex = .init;
    shared.io = std.testing.io;
    shared.sessions = @splat(.{});
    shared.session_next = 1;
    const first = session_claim(shared, 1).?;
    const second = session_claim(shared, 1).?;
    try std.testing.expect(listen_claim(shared, first, "127.0.0.1:7900"));
    try std.testing.expect(!listen_claim(shared, second, "127.0.0.1:7900"));
    try std.testing.expect(listen_claim(shared, second, "127.0.0.1:7901"));
    // The first ended: its address free again.
    first.* = .{};
    const third = session_claim(shared, 1).?;
    try std.testing.expect(listen_claim(shared, third, "127.0.0.1:7900"));
}

/// Whether `address` ("ip:port", IPv4) can be listened on now, as a session's explorer will
/// (its relay's address). A session whose address was held started all the same: its explorer said
/// "cannot listen" in its log and ran on with no listener, and its client reached the older
/// session holding the port (phoenixNAP run 42, 2026-11-14: evaluations meant for the new
/// session's timeline went into another's).
fn listen_free(address: []const u8) bool {
    const fd = listen(address) catch return false;
    _ = linux.close(fd);
    return true;
}

test "an address held is not free to listen on" {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    var raw: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(fd, @ptrCast(&raw), @sizeOf(linux.sockaddr.in))));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(fd, 1)));
    var size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(fd, @ptrCast(&raw), &size);
    var buffer: [32]u8 = undefined;
    const held = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{std.mem.bigToNative(u16, raw.port)});
    try std.testing.expect(!listen_free(held));
    try std.testing.expect(!listen_free("not an address"));
}

/// The number in an explorer's "[determinismo] timeline <n>: ..." (explore --extend, as it takes
/// the run's next number for the timeline it records).
fn timeline_said(line: []const u8) ?u32 {
    const said = "[determinismo] timeline ";
    if (!std.mem.startsWith(u8, line, said)) return null;
    const digits = line[said.len..];
    const stop = std.mem.indexOfScalar(u8, digits, ':') orelse return null;
    return std.fmt.parseInt(u32, digits[0..stop], 10) catch null;
}

test "a session's timeline, as its explorer says it" {
    try std.testing.expectEqual(@as(?u32, 57), timeline_said("[determinismo] timeline 57: timeline 0 from 15000 ms on, extended"));
    try std.testing.expectEqual(@as(?u32, null), timeline_said("[determinismo] timelines: 57"));
    try std.testing.expectEqual(@as(?u32, null), timeline_said("[   15.000] timeline 57: said by the guest"));
}

/// A fork's futures: a run of their own from its snapshot (the session's run's request, from
/// the machine the session saved), branch i future i + 1 (explore's --fork-futures), each
/// releasing the session's hold at its first moment and playing out to its timeline's end.
fn session_futures_start(session: *Session, snapshot: []const u8) !void {
    const forks = &session.forks;
    if (forks.count == forks_max) return error.TooManyForks;
    const name = std.fs.path.basename(snapshot);
    const vtime_ns = std.fmt.parseInt(u64, name["fork-".len..], 10) catch return error.BadSnapshotName;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var server = forks.server orelse return error.NoServer;
    server.arena = arena_state.allocator();
    const request_json = try run_file(&server, session.run, "request.json");
    const original = try std.json.parseFromSliceLeaky(RunRequest, server.arena, request_json, .{
        .ignore_unknown_fields = true,
    });
    const kept = try std.heap.page_allocator.dupe(u8, snapshot);
    const asked: RunRequest = .{
        // The program the session's run kept, not the host's build since.
        .program = original.program,
        .program_asked = original.program_asked,
        .compose = original.compose,
        .kubernetes = original.kubernetes,
        .images = original.images,
        .scenario = original.scenario,
        .profile = original.profile,
        .seed = original.seed,
        .branches = forks.asked,
        .branching = "flat",
        .faults = original.faults,
        .no_faults = original.no_faults,
        .coverage = original.coverage,
        .timeline = original.timeline,
        .min_drive = original.min_drive,
        .drivers_cpu_weight = original.drivers_cpu_weight,
        .fault_weights = original.fault_weights,
        .fault_exclusions = original.fault_exclusions,
        .decide = original.decide,
        .keep = original.keep,
        .trace_errno = original.trace_errno,
        .drive_max = original.drive_max,
        .history = false,
        .cpu_modulation = original.cpu_modulation,
        .memory_mib = original.memory_mib,
        .from_run = session.run,
        .from_snapshot = kept,
        .from_vtime_ms = vtime_ns / std.time.ns_per_ms + 1,
    };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const id = try run_start(&server, asked, &discard.writer);
    forks.started[forks.count] = .{ .snapshot = kept, .run = id, .futures = forks.asked };
    forks.count += 1;
}

/// POST /sessions/<n>/forks: each fork's run (its futures), its state and verdicts.
fn session_forks_list(server: *Server, session: *Session, out: *std.Io.Writer) !u16 {
    const Item = struct { snapshot: []const u8, run: u32, futures: u32, state: []const u8, done: bool, verdict: []const []const u8 };
    var items: std.ArrayList(Item) = .empty;
    for (session.forks.started[0..session.forks.count]) |fork| {
        const run = run_get(server, fork.run) orelse continue;
        const run_state = state(&run);
        const text = run_file(server, fork.run, "output.log") catch "";
        var verdict: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "multiverse:") != null or std.mem.startsWith(u8, line, "  FAIL") or
                std.mem.startsWith(u8, line, "[branch ")) try verdict.append(server.arena, line);
        }
        try items.append(server.arena, .{
            .snapshot = fork.snapshot,
            .run = fork.run,
            .futures = fork.futures,
            .state = run_state,
            .done = !std.mem.eql(u8, run_state, "running"),
            .verdict = verdict.items,
        });
    }
    try std.json.Stringify.value(items.items, .{}, out);
    return 200;
}

/// The reply; a session that ended is reaped and its slot freed.
fn session_reply(server: *Server, session: *Session, reply: SessionRead, out: *std.Io.Writer) !u16 {
    const id = session.id;
    const taken = session.timeline.load(.acquire);
    const timeline: ?u32 = if (taken == timeline_none) null else taken;
    if (reply.done) {
        if (session.input >= 0) _ = linux.close(session.input);
        if (session.reader) |thread| thread.join();
        _ = linux.close(session.output);
        var status: i32 = 0;
        _ = linux.wait4(session.pid, &status, 0, null);
        assert(session.busy.load(.acquire)); // Its request's alone: one cleanup.
        session.log.deinit(std.heap.page_allocator);
        session.forks.carry.deinit(std.heap.page_allocator);
        server.shared.lock();
        session.* = .{};
        server.shared.unlock();
    }
    const output = try utf8_valid(server.arena, reply.output);
    try std.json.Stringify.value(.{ .session = id, .timeline = timeline, .output = output, .done = reply.done }, .{}, out);
    return 200;
}

/// `text` with each byte that is not UTF-8 replaced (U+FFFD): a guest's console has such bytes,
/// and JSON writes text that is not UTF-8 as an array of numbers, which no client reads as text.
fn utf8_valid(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;
    var valid: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[at]) catch 0;
        if (size > 0 and at + size <= text.len and std.unicode.utf8ValidateSlice(text[at .. at + size])) {
            try valid.appendSlice(arena, text[at .. at + size]);
            at += size;
        } else {
            try valid.appendSlice(arena, "\u{FFFD}");
            at += 1;
        }
    }
    return valid.items;
}

test utf8_valid {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("ok", try utf8_valid(arena_state.allocator(), "ok"));
    try std.testing.expectEqualStrings("a\u{FFFD}b", try utf8_valid(arena_state.allocator(), "a\xffb"));
}

fn fd_write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

/// The session's explore: its steps from a pipe, its output (both streams) to another. A
/// replay is someone looking: its VM first on the CPUs, as replays' (DETERMINISMO_CPU_PRIORITY).
fn session_spawn(server: *Server, session: *Session, argv_given: []const []const u8) !void {
    assert(argv_given.len > 0 and argv_given.len < arguments_max);
    const arena = server.arena;
    const argv = try reserved(server, argv_given);
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/";
    const environment = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_DATA={s}", .{server.options.data_directory}, 0),
        try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0),
        "DETERMINISMO_CPU_PRIORITY=1",
        try runtime_directory_entry(arena),
    };
    var input: [2]i32 = undefined;
    var output: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&input, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    if (linux.errno(linux.pipe2(&output, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        _ = linux.dup2(input[0], 0);
        _ = linux.dup2(output[1], 1);
        _ = linux.dup2(output[1], 2);
        _ = linux.setsid();
        _ = linux.execve(argv_z[0].?, argv_z.ptr, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(input[0]);
    _ = linux.close(output[1]);
    session.pid = @intCast(pid);
    session.input = input[1];
    session.output = output[0];
}

const ExtractRequest = struct { branch: u32, at_vtime_ms: u64, node: []const u8, path: []const u8 };

/// A node's file at a moment of a branch (extract.zig), replayed from the branch's tape.
fn run_extract(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(ExtractRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    const original = try std.json.parseFromSliceLeaky(
        RunRequest,
        server.arena,
        try run_file(server, run.id, "request.json"),
        .{ .ignore_unknown_fields = true },
    );
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, try run_machine(server, run.id));
    try system_arguments(server.arena, &argv, &original);
    try pin_arguments(server, &argv, run.id);
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    try checkpoint_arguments(server, &argv, &original, try run_directory(server, run.id));
    const tape = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{
        try run_directory(server, run.id), asked.branch,
    });
    try argv.appendSlice(server.arena, &.{
        "--tape",        tape,
        "--at-vtime-ms", try print(server, "{d}", .{asked.at_vtime_ms}),
    });
    const saving = try replay_snapshots_use(server, run.id, &argv, asked.branch, asked.at_vtime_ms, true);
    defer if (saving) replay_snapshots_done(server, run.id);
    const file = try print(server, "{s}:{s}", .{ asked.node, asked.path });
    const bytes = try extract.read(server.arena, server.io, try explorer_of(server, &original), argv.items, file);
    try out.writeAll(bytes);
    return 200;
}

/// POST /runs/<id>/causality: causality.zig's parameters (its defaults when left out).
const CausalityRequest = struct {
    branch: u32,
    /// What the analysis is of (its label); the bug, unless `verdict` says otherwise.
    property: []const u8 = "",
    /// An event condition that is the bug (query.zig's language); null: the property failing.
    verdict: ?[]const u8 = null,
    points: u32 = 8,
    futures: u32 = 16,
    refine: u32 = 6,
    moments_max: u32 = 40,
    jump_min: f64 = 0.2,
    gap_min_ms: u64 = 20,
    /// A future not failing this long past the failure's moment ends there; null: causality's
    /// default (the failure's distance from the setup snapshot), 0: every future to its end.
    horizon_ms: ?u64 = null,
    /// A planner plugin: a command, `tcp://host:port`, `image:<reference>`, or `@<name>` (an uploaded strategy
    /// executable, PUT /strategies/<name>). Null: the built-in one.
    planner: ?[]const u8 = null,
    /// A command that turns the system's logs up, for futures inside the narrowest jump once
    /// the analysis is done (causality's --explain-exec): their events in the run's
    /// snapshots/explain.
    explain_exec: ?[]const u8 = null,
};

/// Removes the snapshots of runs where none was saved for `snapshots_keep_ns` (the newest
/// file's age: a directory's snapshots are chains, kept or removed together).
fn snapshots_sweep(shared: *Shared) void {
    var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer request_arena.deinit();
    const arena = request_arena.allocator();
    const io = shared.io;
    const cwd = std.Io.Dir.cwd();
    const now_s = std.Io.Timestamp.now(io, .real).toSeconds();
    const keep_s: i64 = @intCast(shared.options.snapshots_keep_ns / std.time.ns_per_s);
    shared.lock();
    const count = shared.run_count;
    shared.unlock();
    for (1..count + 1) |id| {
        const directory = std.fmt.allocPrint(arena, "{s}/runs/{d}/snapshots", .{
            shared.options.data_directory, id,
        }) catch return;
        var dir = cwd.openDir(io, directory, .{ .iterate = true }) catch continue;
        var newest_s: i64 = 0;
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            newest_s = @max(newest_s, stat.mtime.toSeconds());
        }
        dir.close(io);
        if (now_s - newest_s < keep_s) continue;
        cwd.deleteTree(io, directory) catch |err| {
            std.debug.print("[determinismo] removing {s} failed: {s}\n", .{ directory, @errorName(err) });
            continue;
        };
        std.debug.print("[determinismo] removed run {d}'s snapshots (none saved for {d}h)\n", .{
            id, @divFloor(keep_s, 3600),
        });
    }
}

fn causality_start(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(CausalityRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    const index = try causality_launch(server, run, &asked, .waited_for);
    try out.print("{{\"id\":{d}}}\n", .{index});
    return 201;
}

/// Who an analysis is for: someone waiting (its futures take the CPUs before any hunt's), or
/// the run itself (a property's first failure, analyzed as soon as it is found: beside the
/// hunt, on a few CPUs).
const Urgency = enum { waited_for, background };

/// Futures at once of an analysis in the background: the hunt keeps the rest of the host.
const background_jobs = 4;

/// Starts an analysis of the run (`causality-<n>.jsonl`, its pid beside it): returns its number.
fn causality_launch(server: *Server, run: *const Run, asked: *const CausalityRequest, urgency: Urgency) !u32 {
    var argv_list: std.ArrayList([]const u8) = .empty;
    try argv_list.appendSlice(server.arena, try causality_argv(server, run, asked));
    if (urgency == .background) try argv_list.appendSlice(server.arena, &.{ "--jobs", try print(server, "{d}", .{background_jobs}) });
    const argv = argv_list.items;
    // After the analyses on disk (a server before a restart had its own jobs).
    var index: u32 = 0;
    for (try causality_indices(server, run.id)) |earlier| index = @max(index, earlier + 1);
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    if (shared.job_count == jobs_max) return error.TooManyJobs;
    for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == run.id and job.kind == .causality) index = @max(index, job.index + 1);
    }
    const name = try print(server, "causality-{d}.jsonl", .{index});
    const directory = try run_directory(server, run.id);
    const output = try std.fs.path.join(server.arena, &.{ directory, name });
    // Someone waits for it: its futures take the CPUs before any hunt's timelines (cpus.zig),
    // which go on as they free up. Beside a hunt it once got half the host, an hour for 128
    // futures of a YugabyteDB timeline (srv3, 2026-10-27).
    const priority: []const []const u8 = if (urgency == .waited_for) &.{"DETERMINISMO_CPU_PRIORITY=1"} else &.{};
    const pid = try spawn(server, try reserved(server, argv), output, priority, .fresh);
    // Its pid on disk: a server after a restart still knows it runs.
    const pid_name = try print(server, "causality-{d}.pid", .{index});
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, pid_name }),
        .data = try print(server, "{d}\n", .{pid}),
    });
    // One nobody asked for says so (the page: "started on its first failure").
    if (urgency == .background) try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, try print(server, "causality-{d}.automatic", .{index}) }),
        .data = "",
    });
    shared.jobs[shared.job_count] = .{ .run = run.id, .index = index, .pid = pid };
    shared.job_count += 1;
    return index;
}

/// `determinismo causality` for a run's timeline: the run's machine, system and seed, the
/// branch's tape, the run's snapshots directory and API.
/// When the property first failed in the timeline (its ancestors' parts included: a tree's
/// timeline begins inside them) and when setup completed, from the run's events; null when they
/// do not say (not ingested yet: causality's replay finds them). Not when a failure says it
/// formed (`details.window_ns`, Elle's: its anomalies' operations): those times are the guest's
/// clock, which CPU modulation leaves behind virtual time, so the window's end came before the
/// anomaly existed (run 43, srv3: a cycle complete at 101.3 s by the guest's clock; futures from
/// 101.3 s of virtual time all passed, from 125 s all failed). The analysis's rounds narrow the
/// jump down from the check's moment.
fn failure_moments(server: *Server, id: u32, branch: u32, property: []const u8) !?struct { failure_ns: u64, setup_ns: u64 } {
    try run_update(server, id);
    var connection = try run_database(server, id);
    defer run_release(server, id, &connection);
    const Row = struct { failure_ns: ?u64, setup_ns: ?u64 };
    const found = connection.row(Row, server.arena,
        \\SELECT (SELECT vtime_ns FROM timeline_events WHERE timeline = $1 AND kind = 'assert'
        \\        AND name = $2 AND condition = false ORDER BY vtime_ns LIMIT 1),
        \\       (SELECT min(vtime_ns) FROM events WHERE branch IS NULL AND kind = 'lifecycle'
        \\        AND name = 'setup_complete')
    , .{ branch, property }) catch return null;
    const row = found orelse return null;
    const failure_ns = row.failure_ns orelse return null;
    const setup_ns = row.setup_ns orelse return null;
    return .{ .failure_ns = failure_ns, .setup_ns = setup_ns };
}

fn causality_argv(server: *Server, run: *const Run, asked: *const CausalityRequest) ![]const []const u8 {
    const original = try std.json.parseFromSliceLeaky(
        RunRequest,
        server.arena,
        try run_file(server, run.id, "request.json"),
        .{ .ignore_unknown_fields = true },
    );
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ try explorer_of(server, &original), "causality" });
    try argv.appendSlice(server.arena, try run_machine(server, run.id));
    try system_arguments(server.arena, &argv, &original);
    try pin_arguments(server, &argv, run.id);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{original.seed orelse 0}) });
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    // The branch's tape: a tree's branch starts inside its ancestors (the tape has its path).
    const tape = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{
        try run_directory(server, run.id), asked.branch,
    });
    if (std.Io.Dir.cwd().access(server.io, tape, .{})) |_| {
        try argv.appendSlice(server.arena, &.{ "--tape", tape });
    } else |_| {}
    // Its moments saved with the run: a later analysis of the timeline starts from them.
    const snapshots = try std.fs.path.join(server.arena, &.{ try run_directory(server, run.id), "snapshots" });
    // The run's API for planners: this server, at its first address.
    const listen_first = listen_address(server);
    try argv.appendSlice(server.arena, &.{
        "--branch",      try print(server, "{d}", .{asked.branch}),
        "--property",    asked.property,
        "--points",      try print(server, "{d}", .{asked.points}),
        "--futures",     try print(server, "{d}", .{asked.futures}),
        "--refine",      try print(server, "{d}", .{asked.refine}),
        "--moments-max", try print(server, "{d}", .{asked.moments_max}),
        "--jump-min",    try print(server, "{d}", .{asked.jump_min}),
        "--gap-min-ms",  try print(server, "{d}", .{asked.gap_min_ms}),
        "--snapshots",   snapshots,
        "--run-url",     try print(server, "http://{s}/runs/{d}", .{ listen_first, run.id }),
        "--json",
    });
    if (asked.planner) |planner| {
        try argv.appendSlice(server.arena, &.{ "--planner", try strategy_resolve(server, planner) });
    }
    if (asked.horizon_ms) |ms| try argv.appendSlice(server.arena, &.{ "--horizon-ms", try print(server, "{d}", .{ms}) });
    // Asked for, or the profile's own (its test program's `explain`, in the run's pin).
    if (asked.explain_exec orelse system_explain(server, run.id)) |command| {
        try argv.appendSlice(server.arena, &.{ "--explain-exec", command });
    }
    if (asked.verdict) |verdict| {
        try argv.appendSlice(server.arena, &.{ "--verdict", verdict });
    } else if (try failure_moments(server, run.id, asked.branch, asked.property)) |moments| {
        // The moments the run's events have: causality skips the replay that finds them.
        try argv.appendSlice(server.arena, &.{
            "--failure-ms",  try print(server, "{d}", .{moments.failure_ns / std.time.ns_per_ms}),
            "--snapshot-ms", try print(server, "{d}", .{moments.setup_ns / std.time.ns_per_ms}),
        });
    }
    return argv.items;
}

/// With `--failure-analysis` (off by default: the ladder or failures_snapshot puts a failure on
/// disk, and an analysis from the page starts from it at once; this spends cores of the hunt on
/// curves nobody may look at): analyzes each failing property's first failing timeline as soon
/// as it is found (causality, in the background: `background_jobs` futures at once, no CPU
/// priority over the hunt), so that its curve is there, or on its way, when someone looks.
/// A running run's, one analysis at a time, once per property: `snapshots/analyzed-<the
/// property's hash>` says it was started (`POST /runs/<id>/causality/<n>/stop` stops one).
fn failures_analyze(server: *Server, id: u32) !void {
    const shared = server.shared;
    shared.lock();
    const busy = for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == id and !job.done) break true;
    } else false;
    const found: ?Run = for (shared.runs[0..shared.run_count]) |known| {
        if (known.id == id) break known;
    } else null;
    const room = shared.job_count < jobs_max;
    shared.unlock();
    const run = found orelse return;
    // A running run's: a finished one's failures were there to analyze while it ran (a serve
    // restart visits every run once: it analyzed runs stopped hours before).
    if (run.status != null or run.stopped) return;
    if (busy or !room) return;
    // The analyses on disk: one running (an earlier server's, whose jobs this one never had)
    // makes it wait; the properties they analyze (whoever asked) are done.
    var analyzed: std.StringHashMapUnmanaged(void) = .empty;
    for (try causality_indices(server, id)) |index| {
        const pid_name = try print(server, "causality-{d}.pid", .{index});
        if (run_file(server, id, pid_name)) |text| {
            if (process_alive(server, text, "causality")) return;
        } else |_| {}
        const name = try print(server, "causality-{d}.jsonl", .{index});
        const output = run_file(server, id, name) catch continue;
        const header_end = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
        const Header = struct { causality: struct { property: []const u8 = "" } };
        const header = std.json.parseFromSliceLeaky(Header, server.arena, output[0..header_end], .{
            .ignore_unknown_fields = true,
        }) catch continue;
        try analyzed.put(server.arena, header.causality.property, {});
    }
    const rows = rows: {
        var connection = try run_connect(server, id);
        defer run_release(server, id, &connection);
        const Row = struct { property: []const u8, branch: u32, timelines: u64 };
        break :rows connection.rows(Row, server.arena, store.first_failures_sql, .{}) catch |err| {
            if (err == error.DuckDB) database_failed(server, &connection.failure);
            return err;
        };
    };
    const directory = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), "snapshots" });
    for (rows) |row| {
        // Once per property: its first failing timeline can change as earlier ones are ingested.
        if (analyzed.contains(row.property)) continue;
        const marker = try print(server, "{s}/analyzed-{x:0>16}", .{ directory, std.hash.Wyhash.hash(0, row.property) });
        if (std.Io.Dir.cwd().access(server.io, marker, .{})) |_| continue else |_| {}
        try std.Io.Dir.cwd().createDirPath(server.io, directory);
        const asked: CausalityRequest = .{ .branch = row.branch, .property = row.property };
        const index = try causality_launch(server, &run, &asked, .background);
        try std.Io.Dir.cwd().writeFile(server.io, .{
            .sub_path = marker,
            .data = try print(server, "causality {d}: {s}\n", .{ index, row.property }),
        });
        std.debug.print("[determinismo] run {d}: analyzing timeline {d} (its first failure of " ++
            "'{s}'), causality {d}\n", .{ id, row.branch, row.property, index });
        return;
    }
}

/// Saves each failing property's first failing timeline to disk as soon as it is found, unless
/// the explorer did (its failure ladder, from the timeline's holders): `causality --save-only`
/// (the moment after setup and the first round's moments, a replay each, on one CPU), so that an
/// analysis of it forks its futures at once and the failure is kept for `snapshots_keep_ns`. A
/// running run's, one save at a time, the rarest failures first; `snapshots/failure-<timeline>.log`
/// says it was saved, by the ladder or by this (and what it said).
fn failures_snapshot(server: *Server, id: u32) !void {
    if (!server.options.failure_snapshots) return;
    const shared = server.shared;
    shared.lock();
    const busy = for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == id and job.kind == .snapshot and !job.done) break true;
    } else false;
    const found: ?Run = for (shared.runs[0..shared.run_count]) |known| {
        if (known.id == id) break known;
    } else null;
    const room = shared.job_count < jobs_max;
    shared.unlock();
    const run = found orelse return;
    // A running run's: a serve restart visits every run once, and saved runs stopped hours before.
    if (run.status != null or run.stopped) return;
    if (busy or !room) return;
    const rows = rows: {
        var connection = try run_connect(server, id);
        defer run_release(server, id, &connection);
        const Row = struct { property: []const u8, branch: u32, timelines: u64 };
        break :rows connection.rows(Row, server.arena, store.first_failures_sql, .{}) catch |err| {
            if (err == error.DuckDB) database_failed(server, &connection.failure);
            return err;
        };
    };
    const directory = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), "snapshots" });
    for (rows) |row| {
        const log = try print(server, "{s}/failure-{d}.log", .{ directory, row.branch });
        if (std.Io.Dir.cwd().access(server.io, log, .{})) |_| continue else |_| {}
        try std.Io.Dir.cwd().createDirPath(server.io, directory);
        const asked: CausalityRequest = .{ .branch = row.branch, .property = row.property };
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(server.arena, try causality_argv(server, &run, &asked));
        try argv.append(server.arena, "--save-only");
        const pid = try spawn(server, argv.items, log, &.{}, .fresh);
        shared.lock();
        defer shared.unlock();
        if (shared.job_count == jobs_max) return; // Reaped next time.
        shared.jobs[shared.job_count] = .{ .run = id, .index = row.branch, .pid = pid, .kind = .snapshot };
        shared.job_count += 1;
        std.debug.print("[determinismo] run {d}: saving timeline {d} to disk (its first failure " ++
            "of '{s}', no ladder)\n", .{ id, row.branch, row.property });
        return;
    }
}

/// The causality analyses on disk (causality-<n>.jsonl): their numbers.
fn causality_indices(server: *Server, id: u32) ![]const u32 {
    var indices: std.ArrayList(u32) = .empty;
    var dir = std.Io.Dir.cwd().openDir(server.io, try run_directory(server, id), .{ .iterate = true }) catch
        return indices.items;
    defer dir.close(server.io);
    var iterator = dir.iterate();
    while (try iterator.next(server.io)) |entry| {
        const prefix = "causality-";
        const suffix = ".jsonl";
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        const digits = entry.name[prefix.len .. entry.name.len - suffix.len];
        try indices.append(server.arena, std.fmt.parseInt(u32, digits, 10) catch continue);
    }
    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    return indices.items;
}

/// One analysis: what it analyzes (branch, property, the failure's moment), whether it is done
/// (no job of this server runs it), and its points so far.
fn causality_write(server: *Server, run: *const Run, index: u32, out: *std.Io.Writer) !void {
    const shared = server.shared;
    shared.lock();
    const ours = for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == run.id and job.kind == .causality and job.index == index) break !job.done;
    } else null;
    shared.unlock();
    // One an earlier server started: running while its process is.
    const running = ours orelse running: {
        const pid_name = try print(server, "causality-{d}.pid", .{index});
        const text = run_file(server, run.id, pid_name) catch break :running false;
        break :running process_alive(server, text, "causality");
    };
    const name = try print(server, "causality-{d}.jsonl", .{index});
    const output = run_file(server, run.id, name) catch return error.NotFound;
    const automatic_name = try print(server, "causality-{d}.automatic", .{index});
    const automatic = if (run_file(server, run.id, automatic_name)) |_| true else |_| false;
    try out.print("{{\"id\":{d},\"done\":{},\"automatic\":{}", .{ index, !running, automatic });
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const header_key = "{\"causality\":";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, header_key) or line.len < header_key.len + 1) continue;
        try out.print(",\"of\":{s}", .{line[header_key.len .. line.len - 1]});
        break;
    }
    // A moment's latest point: each of its futures updates it as it finishes (causality.zig).
    var latest: std.AutoArrayHashMapUnmanaged(u64, []const u8) = .empty;
    lines.reset();
    while (lines.next()) |line| {
        const key = "{\"vtime_ms\":";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const end = std.mem.indexOfScalarPos(u8, line, key.len, ',') orelse continue;
        const vtime_ms = std.fmt.parseInt(u64, line[key.len..end], 10) catch continue;
        try latest.put(server.arena, vtime_ms, line);
    }
    try out.writeAll(",\"points\":[");
    for (latest.values(), 0..) |line, at| {
        if (at > 0) try out.writeAll(",");
        try out.writeAll(line);
    }
    try out.writeAll("]");
    // The faults' effects on the futures, the latest count (causality.zig: one a round).
    var effects: ?[]const u8 = null;
    var line_effects: ?[]const u8 = null;
    lines.reset();
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "{\"faults\":")) effects = line;
        if (std.mem.startsWith(u8, line, "{\"lines\":")) line_effects = line;
    }
    if (effects) |line| try out.print(",\"fault_effects\":{s}", .{line});
    // The code's (coverage events: statistical debugging), when the system has coverage on.
    if (line_effects) |line| try out.print(",\"line_effects\":{s}", .{line});
    // Its explanation's futures (explain_exec): each moment, whether it failed, its events.
    lines.reset();
    const explained_key = "{\"explained\":";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, explained_key) or line.len < explained_key.len + 1) continue;
        try out.print(",\"explained\":{s}", .{line[explained_key.len .. line.len - 1]});
    }
    try out.writeAll("}");
}

/// Output lines of an explanation's future, at most this many (the latest kept past it).
const explained_lines_max = 2000;

/// The node output an analysis's explanation future wrote (causality.zig's explain: its events
/// directory, named in the analysis's own output, never by the request), `grep` filtering:
/// `{"lines": [{"vtime_ns", "source", "text"}], "matched": n}`.
fn explained_logs(server: *Server, run: *const Run, index: u32, future: usize, out: *std.Io.Writer) !u16 {
    const name = try print(server, "causality-{d}.jsonl", .{index});
    const output = run_file(server, run.id, name) catch return error.NotFound;
    const Explained = struct { explained: []const struct { vtime_ms: u64, fails: bool, events: []const u8 } };
    var events: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"explained\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(Explained, server.arena, line, .{}) catch continue;
        if (future < parsed.explained.len) events = parsed.explained[future].events;
    }
    const directory_path = events orelse return error.NotFound;
    const grep = if (query_value(server.query_string, "grep")) |encoded| grep: {
        const copy = try server.arena.dupe(u8, encoded);
        std.mem.replaceScalar(u8, copy, '+', ' ');
        break :grep std.Uri.percentDecodeInPlace(copy);
    } else "";
    var directory = std.Io.Dir.cwd().openDir(server.io, directory_path, .{ .iterate = true }) catch return error.NotFound;
    defer directory.close(server.io);
    const Line = struct { vtime_ns: u64 = 0, event: struct { output: ?struct { source: []const u8 = "", text: []const u8 = "" } = null } = .{} };
    var kept: std.ArrayList(Line) = .empty;
    var matched: u64 = 0;
    var entries = directory.iterate();
    while (try entries.next(server.io)) |entry| {
        const limit: std.Io.Limit = .limited(1 << 30);
        const text = if (std.mem.eql(u8, entry.name, "fork.jsonl"))
            directory.readFileAlloc(server.io, entry.name, server.arena, limit) catch continue
        else if (event_files.index_of(entry.name)) |timeline| text: {
            // Each timeline once: the running one's plain file, the ended one's compressed.
            if (std.mem.endsWith(u8, entry.name, event_files.running_suffix) and event_files.ended(server.io, directory_path, timeline)) continue;
            break :text event_files.read(server.arena, server.io, directory_path, timeline, limit) catch continue;
        } else continue;
        var event_lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (event_lines.next()) |event_line| {
            if (std.mem.indexOf(u8, event_line, "\"output\"") == null) continue;
            if (grep.len > 0 and std.mem.indexOf(u8, event_line, grep) == null) continue;
            const parsed = std.json.parseFromSliceLeaky(Line, server.arena, event_line, .{ .ignore_unknown_fields = true }) catch continue;
            if (parsed.event.output == null) continue;
            matched += 1;
            if (kept.items.len == explained_lines_max) _ = kept.orderedRemove(0);
            try kept.append(server.arena, parsed);
        }
    }
    try out.writeAll("{\"lines\":[");
    for (kept.items, 0..) |line, at| {
        if (at > 0) try out.writeAll(",");
        try out.print("{f}", .{std.json.fmt(.{ .vtime_ns = line.vtime_ns, .source = line.event.output.?.source, .text = line.event.output.?.text }, .{})});
    }
    try out.print("],\"matched\":{d}}}\n", .{matched});
    return 200;
}

// Shrinking ------------------------------------------------------------------------------------

/// POST /runs/<id>/shrink: a failing timeline's fewest faults (`determinismo shrink`).
const ShrinkRequest = struct {
    branch: u32,
    property: []const u8,
    /// Timelines each candidate is judged over (shrink's --timelines).
    timelines: u32 = 16,
};

/// Starts shrinking a failing timeline of the run, in the background (`shrink-<n>.jsonl` its
/// output, its request and pid beside it); someone waits for it: its explorations take the CPUs
/// before a hunt's timelines.
fn shrink_start(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = std.json.parseFromSliceLeaky(ShrinkRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadRequest;
    if (asked.property.len == 0 or asked.timelines == 0) return error.BadRequest;
    const original = try std.json.parseFromSliceLeaky(RunRequest, server.arena, try run_file(server, run.id, "request.json"), .{
        .ignore_unknown_fields = true,
    });
    const directory = try run_directory(server, run.id);
    var index: u32 = 0;
    for (try job_indices(server, run.id, "shrink-")) |earlier| index = @max(index, earlier + 1);
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    if (shared.job_count == jobs_max) return error.TooManyJobs;
    for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == run.id and job.kind == .shrink) index = @max(index, job.index + 1);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ try explorer_of(server, &original), "shrink" });
    try argv.appendSlice(server.arena, try run_machine(server, run.id));
    try system_arguments(server.arena, &argv, &original);
    try pin_arguments(server, &argv, run.id);
    if (original.scenario) |scenario| try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    // The branch's tape (a tree's branch starts inside its ancestors), else the run's seed.
    const tape = try print(server, "{s}/tapes/branch-{d}.jsonl", .{ directory, asked.branch });
    if (std.Io.Dir.cwd().access(server.io, tape, .{})) |_| {
        try argv.appendSlice(server.arena, &.{ "--tape", tape });
    } else |_| try argv.appendSlice(server.arena, &.{
        "--seed",   try print(server, "{d}", .{original.seed orelse 0}),
        "--branch", try print(server, "{d}", .{asked.branch}),
    });
    try argv.appendSlice(server.arena, &.{
        "--property",  asked.property,
        "--timelines", try print(server, "{d}", .{asked.timelines}),
        "--out",       try std.fs.path.join(server.arena, &.{ directory, try print(server, "shrink-{d}.script.json", .{index}) }),
        "--json",
    });
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, try print(server, "shrink-{d}.request.json", .{index}) }),
        .data = try print(server, "{f}\n", .{std.json.fmt(asked, .{})}),
    });
    const output = try std.fs.path.join(server.arena, &.{ directory, try print(server, "shrink-{d}.jsonl", .{index}) });
    const pid = try spawn(server, try reserved(server, argv.items), output, &.{"DETERMINISMO_CPU_PRIORITY=1"}, .fresh);
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, try print(server, "shrink-{d}.pid", .{index}) }),
        .data = try print(server, "{d}\n", .{pid}),
    });
    shared.jobs[shared.job_count] = .{ .run = run.id, .index = index, .pid = pid, .kind = .shrink };
    shared.job_count += 1;
    try out.print("{{\"id\":{d}}}\n", .{index});
    return 200;
}

/// POST /runs/<id>/explain: which details of a failing timeline's last faults it needed
/// (`determinismo explain`).
const ExplainRequest = struct {
    branch: u32,
    property: []const u8,
    /// The last faults explained, and the variants of each of their details (explain's --faults,
    /// --variants).
    faults: u32 = 3,
    variants: u32 = 6,
};

/// Starts explaining a failing timeline of the run, in the background (`explain-<n>.jsonl` its
/// output, its request and pid beside it); someone waits for it: its variants take the CPUs
/// before a hunt's timelines.
fn explain_start(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = std.json.parseFromSliceLeaky(ExplainRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadRequest;
    if (asked.property.len == 0 or asked.faults == 0 or asked.variants == 0) return error.BadRequest;
    const original = try std.json.parseFromSliceLeaky(RunRequest, server.arena, try run_file(server, run.id, "request.json"), .{
        .ignore_unknown_fields = true,
    });
    const directory = try run_directory(server, run.id);
    // A timeline's own tape: what explain varies (every run serve made keeps one per timeline).
    const tape = try print(server, "{s}/tapes/branch-{d}.jsonl", .{ directory, asked.branch });
    std.Io.Dir.cwd().access(server.io, tape, .{}) catch return error.NotFound;
    var index: u32 = 0;
    for (try job_indices(server, run.id, "explain-")) |earlier| index = @max(index, earlier + 1);
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    if (shared.job_count == jobs_max) return error.TooManyJobs;
    for (shared.jobs[0..shared.job_count]) |job| {
        if (job.run == run.id and job.kind == .explain) index = @max(index, job.index + 1);
    }
    // A run keeps the explorer of its core: one from before explain (and its replays'
    // --draws-out) cannot explain it.
    const explorer = try explorer_of(server, &original);
    if (!explorer_explains(server, explorer)) {
        server.detail = "this run keeps an explorer from before explain (its core is older): " ++
            "explain works on runs started since";
        return error.ExplorerTooOld;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ explorer, "explain" });
    try argv.appendSlice(server.arena, try run_machine(server, run.id));
    try system_arguments(server.arena, &argv, &original);
    try pin_arguments(server, &argv, run.id);
    if (original.scenario) |scenario| try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    try argv.appendSlice(server.arena, &.{
        "--tape",     tape,
        "--property", asked.property,
        "--faults",   try print(server, "{d}", .{asked.faults}),
        "--variants", try print(server, "{d}", .{asked.variants}),
        "--json",
    });
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, try print(server, "explain-{d}.request.json", .{index}) }),
        .data = try print(server, "{f}\n", .{std.json.fmt(asked, .{})}),
    });
    const output = try std.fs.path.join(server.arena, &.{ directory, try print(server, "explain-{d}.jsonl", .{index}) });
    const pid = try spawn(server, try reserved(server, argv.items), output, &.{"DETERMINISMO_CPU_PRIORITY=1"}, .fresh);
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, try print(server, "explain-{d}.pid", .{index}) }),
        .data = try print(server, "{d}\n", .{pid}),
    });
    shared.jobs[shared.job_count] = .{ .run = run.id, .index = index, .pid = pid, .kind = .explain };
    shared.job_count += 1;
    try out.print("{{\"id\":{d}}}\n", .{index});
    return 200;
}

/// Whether an explorer has `explain` (its usage names it): this server's has.
fn explorer_explains(server: *Server, explorer: []const u8) bool {
    if (std.mem.eql(u8, explorer, server.options.self)) return true;
    const result = std.process.run(server.arena, server.io, .{ .argv = &.{ explorer, "explain" } }) catch return false;
    return std.mem.indexOf(u8, result.stderr, "determinismo explain ") != null or
        std.mem.indexOf(u8, result.stdout, "determinismo explain ") != null;
}

/// The numbers of a run's jobs of a kind, from their outputs (`<prefix><n>.jsonl`).
fn job_indices(server: *Server, id: u32, prefix: []const u8) ![]const u32 {
    var indices: std.ArrayList(u32) = .empty;
    var dir = std.Io.Dir.cwd().openDir(server.io, try run_directory(server, id), .{ .iterate = true }) catch
        return indices.items;
    defer dir.close(server.io);
    var iterator = dir.iterate();
    while (try iterator.next(server.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const digits = entry.name[prefix.len .. entry.name.len - ".jsonl".len];
        try indices.append(server.arena, std.fmt.parseInt(u32, digits, 10) catch continue);
    }
    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    return indices.items;
}

/// GET /runs/<id>/shrink, /runs/<id>/explain: every shrinking or explanation of the run, oldest
/// first: {id, of: its request, done, result (the command's --json line: shrink's faults kept,
/// failure counts and shrunk script; explain's faults and their details' verdicts) or null, and
/// its last line of progress}.
fn job_list(server: *Server, run: *const Run, kind: []const u8, out: *std.Io.Writer) !u16 {
    const result_key = try print(server, "{{\"{s}\":", .{kind});
    try out.writeAll("[");
    for (try job_indices(server, run.id, try print(server, "{s}-", .{kind})), 0..) |index, position| {
        if (position > 0) try out.writeAll(",");
        const of = run_file(server, run.id, try print(server, "{s}-{d}.request.json", .{ kind, index })) catch "null";
        const output = run_file(server, run.id, try print(server, "{s}-{d}.jsonl", .{ kind, index })) catch "";
        const pid_text = run_file(server, run.id, try print(server, "{s}-{d}.pid", .{ kind, index })) catch "";
        const running = process_alive(server, pid_text, kind);
        var result: []const u8 = "null";
        var progress: []const u8 = "";
        // Its last word: the last of determinismo's own lines, which says why, rather than the
        // error name a failed job ends with ("error: ReplayFailed" under "the tape was recorded
        // with inputs ...": the page showed the name alone).
        var said: []const u8 = "";
        var lines = std.mem.tokenizeScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, result_key)) {
                result = line;
                continue;
            }
            progress = line;
            if (std.mem.startsWith(u8, line, "[determinismo] ")) said = line;
        }
        if (!running and std.mem.startsWith(u8, progress, "error: ") and said.len > 0) {
            progress = try print(server, "{s} ({s})", .{ said["[determinismo] ".len..], progress["error: ".len..] });
        }
        try out.print("{{\"id\":{d},\"of\":{s},\"done\":{},\"result\":{s},\"progress\":{f}}}", .{
            index, std.mem.trim(u8, of, " \n"), !running, result, std.json.fmt(progress, .{}),
        });
    }
    try out.writeAll("]\n");
    return 200;
}

/// Stops a shrinking or an explanation and its explorations (its session's process group: spawn).
fn job_stop(server: *Server, run: *const Run, kind: []const u8, index: u32, out: *std.Io.Writer) !u16 {
    const text = run_file(server, run.id, try print(server, "{s}-{d}.pid", .{ kind, index })) catch return error.NotFound;
    if (!process_alive(server, text, kind)) return error.NotRunning;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return error.NotFound;
    if (linux.errno(linux.kill(-pid, .TERM)) != .SUCCESS) return error.NotRunning;
    try out.print("{{\"id\":{d},\"stopped\":true}}\n", .{index});
    return 200;
}

/// Stops an analysis, and its futures: it runs in a session of its own (spawn), its futures in its
/// process group. What it found so far stays.
fn causality_stop(server: *Server, run: *const Run, index: u32, out: *std.Io.Writer) !u16 {
    const pid_name = try print(server, "causality-{d}.pid", .{index});
    const text = run_file(server, run.id, pid_name) catch return error.NotFound;
    if (!process_alive(server, text, "causality")) return error.NotRunning;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return error.NotFound;
    if (linux.errno(linux.kill(-pid, .TERM)) != .SUCCESS) return error.NotRunning;
    try out.print("{{\"id\":{d},\"stopped\":true}}\n", .{index});
    return 200;
}

fn causality_show(server: *Server, run: *const Run, index: u32, out: *std.Io.Writer) !u16 {
    try causality_write(server, run, index, out);
    try out.writeAll("\n");
    return 200;
}

/// Every analysis of the run, oldest first.
fn causality_list(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    try out.writeAll("[");
    for (try causality_indices(server, run.id), 0..) |index, position| {
        if (position > 0) try out.writeAll(",");
        try causality_write(server, run, index, out);
    }
    try out.writeAll("]\n");
    return 200;
}

/// A property as a run's events database judges it (store.properties_sql).
const Judged = struct {
    kind: []const u8,
    message: []const u8,
    failing: bool,
    branches_failing: u32,
    /// Its finds per CPU-hour, a 95% interval (store.properties_sql).
    rate_low: f64 = 0,
    rate_high: f64 = 0,
};

/// A run's properties, how many timelines it has and their CPU time.
const Verdicts = struct { timelines: u32, cpu_hours: f64 = 0, properties: []const Judged };

fn verdicts_read(server: *Server, id: u32) !Verdicts {
    // From the run's kept properties answer (store.properties_sql's, computed once while serve
    // runs): the findings of run 866 took 2.1 s warm, its own and the previous run's properties
    // asked of their databases again on each load.
    const json = try answer_kept(server, id, .properties, properties_compute);
    const Row = struct {
        type: []const u8,
        message: []const u8,
        status: []const u8,
        timelines_failing: ?u32 = null,
        finds_per_cpu_hour_low: ?f64 = null,
        finds_per_cpu_hour_high: ?f64 = null,
    };
    const rows = try std.json.parseFromSliceLeaky([]const Row, server.arena, json, .{
        .ignore_unknown_fields = true,
    });
    const properties = try server.arena.alloc(Judged, rows.len);
    for (rows, properties) |row, *property| property.* = .{
        .kind = row.type,
        .message = row.message,
        .failing = std.mem.eql(u8, row.status, "failing"),
        .branches_failing = row.timelines_failing orelse 0,
        .rate_low = row.finds_per_cpu_hour_low orelse 0,
        .rate_high = row.finds_per_cpu_hour_high orelse 0,
    };
    var connection = try run_database(server, id);
    defer run_release(server, id, &connection);
    const Count = struct { count: u32, cpu_ns: ?f64 };
    const counting = "SELECT count(*), sum(wall_ns)::DOUBLE FROM explored"; // Not a person's sessions.
    const count = (try connection.row(Count, server.arena, counting, .{})).?;
    return .{
        .timelines = count.count,
        .cpu_hours = (count.cpu_ns orelse 0) / 3.6e12,
        .properties = properties,
    };
}

/// The previous run of the same system and scenario that ended (finished or stopped), as
/// Antithesis compares runs.
fn run_previous(server: *Server, run: *const Run) !?u32 {
    const earlier = try runs_previous(server, run, 1);
    return if (earlier.len > 0) earlier[0] else null;
}

/// Up to `count` earlier runs of the same system and scenario that ended, the latest first.
fn runs_previous(server: *Server, run: *const Run, count: usize) ![]const u32 {
    const mine = try run_identity(server, run.id);
    const runs = runs_copy(server);
    var found: std.ArrayList(u32) = .empty;
    var index = runs.len;
    while (index > 0 and found.items.len < count) {
        index -= 1;
        const other = &runs[index];
        if (other.id >= run.id or (other.status == null and !other.stopped)) continue;
        const theirs = run_identity(server, other.id) catch continue;
        if (!std.mem.eql(u8, mine, theirs) or !in_findings_history(server, other.id)) continue;
        try found.append(server.arena, other.id);
    }
    return found.items;
}

/// Whether a run is in its system's findings history (RunRequest.findings_history).
fn in_findings_history(server: *Server, id: u32) bool {
    const request_json = run_file(server, id, "request.json") catch return true;
    const Fields = struct { findings_history: bool = true, setup_only: bool = false };
    const fields = std.json.parseFromSliceLeaky(Fields, server.arena, request_json, .{ .ignore_unknown_fields = true }) catch return true;
    // A setup run judges nothing: no run is compared with it.
    return fields.findings_history and !fields.setup_only;
}

/// How many earlier runs a finding's history shows (Antithesis's run history: a red tick for a
/// run it failed in, a green one for a run it passed in).
const finding_history_runs = 10;

/// An earlier run's verdict on each property, from its kept properties answer (computed once
/// while serve runs: a finding's history over ten runs asked each database again otherwise).
const Earlier = struct { id: u32, rows: []const StreamRow };

fn earlier_verdicts(server: *Server, run: *const Run) ![]const Earlier {
    const ids = try runs_previous(server, run, finding_history_runs);
    const earlier = try server.arena.alloc(Earlier, ids.len);
    for (ids, 0..) |id, index| {
        // Oldest first.
        const json = answer_kept(server, id, .properties, properties_compute) catch "[]";
        const rows = std.json.parseFromSliceLeaky([]const StreamRow, server.arena, json, .{ .ignore_unknown_fields = true }) catch &.{};
        earlier[ids.len - 1 - index] = .{ .id = id, .rows = rows };
    }
    return earlier;
}

/// A finding's history: in each earlier run, failing, passing, or absent (null).
fn history_print(out: *std.Io.Writer, earlier: []const Earlier, message: []const u8) !void {
    try out.writeAll("[");
    for (earlier, 0..) |run, index| {
        if (index > 0) try out.writeAll(",");
        const row = for (run.rows) |row| {
            if (std.mem.eql(u8, row.message, message)) break row;
        } else null;
        try out.print("{{\"run\":{d},\"failing\":", .{run.id});
        if (row) |found| try out.print("{}}}", .{std.mem.eql(u8, found.status, "failing")}) else try out.writeAll("null}");
    }
    try out.writeAll("]");
}

/// Runs of a system whose behaviors make a new run's history.
const history_runs = 5;

/// A new run's history (`--history`): the behaviors the system's last runs of the same scenario
/// and profile reached (each run's record.jsonl.behaviors, up to `history_runs`), in one file of
/// its directory; null when none has them. `runs`: the server's, its lock held by the caller
/// (run_create: runs_copy would wait for it forever, as serve did on srv4, 2026-10-31).
fn history_write(server: *Server, runs: []const Run, id: u32, directory: []const u8) !?[]const u8 {
    const history = try history_gather(server, runs, try run_identity(server, id), id);
    if (history.runs == 0) return null;
    const text = history.behaviors;
    const learned = history.learned;
    const path = try std.fs.path.join(server.arena, &.{ directory, "history.jsonl" });
    try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = text });
    if (learned.len > 0) {
        const bandit_path = try std.fmt.allocPrint(server.arena, "{s}.bandit", .{path});
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = bandit_path, .data = learned });
    }
    return path;
}

/// The system's last runs of the same scenario and profile, ended, before run `before` (up to
/// `history_runs`, each with its record.jsonl.behaviors): their behaviors and their configuration
/// bandits (record.jsonl.bandit), concatenated: what a new run starts from (history_write), and
/// what a run's plan imagines its first timelines' configuration from (run_plan).
fn history_gather(server: *Server, runs: []const Run, mine: []const u8, before: u32) !struct { runs: u32, behaviors: []const u8, learned: []const u8 } {
    var behaviors: std.ArrayList(u8) = .empty;
    var learned: std.ArrayList(u8) = .empty;
    var found: u32 = 0;
    var index = runs.len;
    while (index > 0 and found < history_runs) {
        index -= 1;
        const other = &runs[index];
        if (other.id >= before or (other.status == null and !other.stopped)) continue;
        const theirs = run_identity(server, other.id) catch continue;
        if (!std.mem.eql(u8, mine, theirs)) continue;
        const known = run_file(server, other.id, "record.jsonl.behaviors") catch continue;
        try behaviors.appendSlice(server.arena, known);
        if (run_file(server, other.id, "record.jsonl.bandit")) |bandit| {
            try learned.appendSlice(server.arena, bandit);
        } else |_| {}
        found += 1;
    }
    return .{ .runs = found, .behaviors = behaviors.items, .learned = learned.items };
}

/// A run's system, as runs of it compare (findings, history): the test program as asked (not its
/// artifact, whose path is its build's hash: each rebuild had made a system of its own, with no
/// previous run and no history; srv4, 2026-10-31), its scenario, profile and coverage set.
fn run_identity(server: *Server, id: u32) ![]const u8 {
    const asked = try std.json.parseFromSliceLeaky(RunRequest, server.arena, try run_file(
        server,
        id,
        "request.json",
    ), .{ .ignore_unknown_fields = true });
    return identity_of(server, asked);
}

fn identity_of(server: *Server, asked: RunRequest) ![]const u8 {
    return print(server, "{s}|{s}|{s}|{s}|{s}|{s}", .{
        asked.program_asked orelse asked.program orelse "", asked.compose orelse "",
        asked.scenario orelse "",                           asked.profile orelse "",
        asked.kubernetes orelse "",                         asked.coverage orelse "",
    });
}

/// New (fails now, not in the previous run; `missed_before` when that run could have missed as
/// rare a failure by chance: its odds), ongoing (fails in both), resolved (failed before, passes
/// now, and that is unlikely to be luck) or unseen (passes now, but as rare a failure could have
/// been missed); rare when only one timeline showed it. Resolved and unseen once the run ended.
fn findings_show(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    // A running run's findings so far: what fails now, new or ongoing. A failure of the previous
    // run that is gone is judged (resolved, unseen) only once the run ends, by its whole CPU time.
    const running = run.status == null and !run.stopped;
    const verdicts_now = try verdicts_read(server, run.id);
    const now = verdicts_now.properties;
    const previous_id = try run_previous(server, run);
    const verdicts_before: Verdicts = if (previous_id) |id|
        try verdicts_read(server, id)
    else
        .{ .timelines = 0, .properties = &.{} };
    const before = verdicts_before.properties;
    const earlier_runs = try earlier_verdicts(server, run);
    try out.print("{{\"running\":{},\"previous\":", .{running});
    if (previous_id) |id| try out.print("{d}", .{id}) else try out.writeAll("null");
    try out.writeAll(",\"findings\":[");
    var first = true;
    for (now) |property| {
        const earlier = for (before) |other| {
            if (std.mem.eql(u8, other.message, property.message)) break other;
        } else null;
        const failed_before = if (earlier) |other| other.failing else false;
        const finding: ?[]const u8 = if (property.failing)
            (if (failed_before) "ongoing" else "new")
        else if (failed_before and !running)
            resolution(earlier.?, verdicts_now.cpu_hours)
        else
            null;
        const kind = finding orelse continue;
        if (!first) try out.writeAll(",");
        first = false;
        try out.print("{{\"message\":{f},\"kind\":{f},\"finding\":\"{s}\",\"rare\":{},\"trend\":", .{
            std.json.fmt(property.message, .{}),
            std.json.fmt(property.kind, .{}),
            kind,
            property.failing and property.branches_failing == 1,
        });
        if (earlier != null and property.failing and failed_before) {
            try out.print("{f}", .{std.json.fmt(trend(earlier.?, property), .{})});
        } else try out.writeAll("null");
        // Unseen: how much more testing without it would make it resolved (the findability
        // Antithesis graphs for a rare finding).
        // New, in a property the previous run had and passed: the odds that it missed the
        // failure by chance, when they say so (missed_before).
        if (std.mem.eql(u8, kind, "new") and earlier != null) {
            if (missed_before(property, verdicts_before.cpu_hours)) |odds| try out.print(",\"missed_before\":{d:.2}", .{odds});
        }
        if (std.mem.eql(u8, kind, "unseen")) {
            const more = confirm_cpu_hours(earlier.?, verdicts_now.cpu_hours);
            // No rate known (no finds per CPU-hour): no estimate, not JSON's missing infinity.
            if (std.math.isFinite(more)) try out.print(",\"confirm_cpu_hours\":{d:.2}", .{more}) else try out.writeAll(",\"confirm_cpu_hours\":null");
        }
        try out.writeAll(",\"history\":");
        try history_print(out, earlier_runs, property.message);
        try out.writeAll("}");
    }
    // Properties that failed before and no longer exist (code removed) are resolved too.
    for (before) |other| {
        if (!other.failing or running) continue;
        const still = for (now) |property| {
            if (std.mem.eql(u8, property.message, other.message)) break true;
        } else false;
        if (still) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try out.print("{{\"message\":{f},\"kind\":{f},\"finding\":\"resolved\",\"rare\":false,\"trend\":null,\"history\":", .{
            std.json.fmt(other.message, .{}), std.json.fmt(other.kind, .{}),
        });
        try history_print(out, earlier_runs, other.message);
        try out.writeAll("}");
    }
    try out.writeAll("]}\n");
    return 200;
}

/// Whether a failure that is gone is gone for sure. A failure of a property judged per timeline
/// (always, unreachable), found before at a rate of at least `rate_low` per CPU-hour (its 95%
/// interval's lower bound: a rate measured from few finds is uncertain), is missed by a run of
/// `cpu_hours` with probability exp(-rate_low * cpu_hours): below 5% it is resolved, else only
/// unseen. A property judged over the multiverse (sometimes, reachable) that now holds is
/// resolved.
fn resolution(before: Judged, cpu_hours: f64) []const u8 {
    const per_timeline = std.mem.startsWith(u8, before.kind, "always") or
        std.mem.eql(u8, before.kind, "unreachable");
    if (!per_timeline or before.branches_failing == 0) return "resolved";
    const missed = @exp(-before.rate_low * cpu_hours);
    return if (missed < 0.05) "resolved" else "unseen";
}

/// For a failure the previous run never showed: the odds that it missed it by chance
/// (resolution's mirror), when that is likely enough to say. Found now at a rate of at least
/// `rate_low` per CPU-hour (its 95% interval's lower bound), the previous run's
/// `cpu_hours_before` would have missed it with probability exp(-rate_low * cpu_hours_before):
/// under 5% that run would have shown it (something changed since: nothing to add), else the
/// finding says the odds beside its NEW. etcd's 12-hour run 2007 found two failures in 20
/// timelines and in 1 over 75 CPU-hours, against a previous run of 6 CPU-hours, which finds
/// neither more often than not: new all the same (they never failed before), and not a
/// regression's evidence. A label of its own for them ("first seen") was tried and taken back
/// the same day (2026-11-15): new is what they are. A property judged over the
/// multiverse (sometimes, reachable), or one of determinismo's own (no rate): none.
fn missed_before(now: Judged, cpu_hours_before: f64) ?f64 {
    const per_timeline = std.mem.startsWith(u8, now.kind, "always") or
        std.mem.eql(u8, now.kind, "unreachable");
    if (!per_timeline or now.rate_low <= 0) return null;
    const odds = @exp(-now.rate_low * cpu_hours_before);
    return if (odds < 0.05) null else odds;
}

test missed_before {
    // Found in 20 timelines over 75 CPU-hours: at least 0.16 an hour.
    const rare: Judged = .{ .kind = "always", .message = "m", .failing = true, .branches_failing = 20, .rate_low = 0.163, .rate_high = 0.41 };
    // A previous run of 6 CPU-hours missed it with odds of exp(-0.98) = 0.38: said.
    try std.testing.expectApproxEqAbs(@as(f64, 0.38), missed_before(rare, 6).?, 0.01);
    // One of 75 would have shown it (exp(-12.2)): nothing to say.
    try std.testing.expectEqual(@as(?f64, null), missed_before(rare, 75));
    // Failing in every timeline of a short run: any previous run of the kind had shown it.
    const common: Judged = .{ .kind = "always", .message = "m", .failing = true, .branches_failing = 40, .rate_low = 30, .rate_high = 55 };
    try std.testing.expectEqual(@as(?f64, null), missed_before(common, 0.5));
    // A sometimes never true now, true before: no rate to compare.
    const sometimes: Judged = .{ .kind = "sometimes", .message = "m", .failing = true, .branches_failing = 0 };
    try std.testing.expectEqual(@as(?f64, null), missed_before(sometimes, 100));
    // determinismo's own properties (replays, logging) have no rate.
    const own: Judged = .{ .kind = "always", .message = "timelines replay to their recorded history", .failing = true, .branches_failing = 2 };
    try std.testing.expectEqual(@as(?f64, null), missed_before(own, 100));
}

/// For an unseen failure, the CPU-hours more without it that make it resolved: until missing it
/// by chance at its lowest rate (resolution's) is under 5%, ln(20) / rate_low in all.
fn confirm_cpu_hours(before: Judged, cpu_hours: f64) f64 {
    if (before.rate_low <= 0) return std.math.inf(f64);
    return @max(0, @log(20.0) / before.rate_low - cpu_hours);
}

test confirm_cpu_hours {
    const rare: Judged = .{ .kind = "always", .message = "m", .failing = true, .branches_failing = 1, .rate_low = 0.5, .rate_high = 6 };
    // ln(20) / 0.5 = 5.99 CPU-hours in all; one done, 4.99 to go (resolution's 1 h: unseen).
    try std.testing.expectApproxEqAbs(@as(f64, 4.99), confirm_cpu_hours(rare, 1), 0.01);
    try std.testing.expectEqual(@as(f64, 0), confirm_cpu_hours(rare, 10));
}

/// How a failure in both runs changed: "rarer" or "more frequent" when the 95% intervals of its
/// finds per CPU-hour do not overlap, else "same".
fn trend(before: Judged, now: Judged) []const u8 {
    if (now.rate_high < before.rate_low) return "rarer";
    if (now.rate_low > before.rate_high) return "more frequent";
    return "same";
}

test resolution {
    const always: Judged = .{
        .kind = "always",
        .message = "m",
        .failing = true,
        .branches_failing = 1,
        .rate_low = 0.5, // Found once in two CPU-hours: at least 0.5 an hour, at 95%... roughly.
        .rate_high = 6,
    };
    // A clean run of one CPU-hour could easily have missed it (exp(-0.5) = 0.61).
    try std.testing.expectEqualStrings("unseen", resolution(always, 1));
    // Ten CPU-hours clean: missed with probability exp(-5) = 0.007.
    try std.testing.expectEqualStrings("resolved", resolution(always, 10));
    const sometimes: Judged = .{
        .kind = "sometimes",
        .message = "m",
        .failing = true,
        .branches_failing = 0,
    };
    try std.testing.expectEqualStrings("resolved", resolution(sometimes, 0.01));
}

test trend {
    const before: Judged = .{ .kind = "always", .message = "m", .failing = true, .branches_failing = 40, .rate_low = 30, .rate_high = 55 };
    var now = before;
    now.rate_low = 2;
    now.rate_high = 9;
    try std.testing.expectEqualStrings("rarer", trend(before, now));
    now.rate_low = 70;
    now.rate_high = 90;
    try std.testing.expectEqualStrings("more frequent", trend(before, now));
    now.rate_low = 40;
    now.rate_high = 60;
    try std.testing.expectEqualStrings("same", trend(before, now));
}

/// The run's notebook (the UI's, or an agent's): JavaScript cells, kept in the run's directory
/// so that whoever opens the run sees it. GET answers {source} (null before any save); PUT
/// takes {source}.
fn notebook(server: *Server, run: *const Run, request: Request, out: *std.Io.Writer) !u16 {
    const path = try std.fs.path.join(server.arena, &.{
        try run_directory(server, run.id), "notebook.js",
    });
    if (std.mem.eql(u8, request.method, "PUT")) {
        const Saved = struct { source: []const u8 };
        const saved = try std.json.parseFromSliceLeaky(Saved, server.arena, request.body, .{
            .ignore_unknown_fields = true,
        });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = saved.source });
        try out.writeAll("{\"saved\":true}\n");
        return 200;
    }
    if (!std.mem.eql(u8, request.method, "GET")) return error.NotFound;
    const limit: std.Io.Limit = .limited(request_size_max);
    const source = std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, limit) catch |err|
        switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    try out.print("{{\"source\":{f}}}\n", .{std.json.fmt(source, .{})});
    return 200;
}

/// Strategies uploaded to this server (`PUT /strategies/<name>`, the executable as the body, or
/// its base64 with `?encoding=base64`: a client that sends text, jank's and babashka's;
/// `GET /strategies` lists them). A run names one as `@<name> [arguments]`. An executable
/// runs on this host as any `--strategy` command does, so serve should listen where only
/// trusted users reach; a WebAssembly module (its first bytes `\0asm`) runs inside the
/// explorer, sandboxed (`wasm:`, src/wasm_plugin.zig).
fn strategies_route(
    server: *Server,
    name: ?[]const u8,
    request: Request,
    out: *std.Io.Writer,
) !u16 {
    const eql = std.mem.eql;
    const directory = try std.fs.path.join(server.arena, &.{
        server.options.data_directory, "strategies",
    });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(server.io, directory);
    const given = name orelse {
        if (!eql(u8, request.method, "GET")) return error.NotFound;
        var dir = try cwd.openDir(server.io, directory, .{ .iterate = true });
        defer dir.close(server.io);
        var iterator = dir.iterate();
        try out.writeAll("[");
        var count: u32 = 0;
        while (try iterator.next(server.io)) |entry| {
            if (count > 0) try out.writeAll(",");
            try out.print("{f}", .{std.json.fmt(entry.name, .{})});
            count += 1;
        }
        try out.writeAll("]\n");
        return 200;
    };
    if (!eql(u8, request.method, "PUT")) return error.NotFound;
    if (!strategy_name_valid(given) or request.body.len == 0) return error.BadRequest;
    const base64 = if (query_value(server.query_string, "encoding")) |encoding|
        if (eql(u8, encoding, "base64")) true else return error.BadRequest
    else
        false;
    const bytes = if (base64) try base64_decoded(server.arena, request.body) else request.body;
    if (bytes.len == 0) return error.BadRequest;
    const path = try std.fs.path.join(server.arena, &.{ directory, given });
    try cwd.writeFile(server.io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .permissions = .executable_file },
    });
    const kind = if (wasm_module(bytes)) "wasm" else "executable";
    // Its content's hash: the name of the copy a run keeps of it (runs.artifact_keep's).
    try out.print("{{\"strategy\":\"@{s}\",\"bytes\":{d},\"kind\":\"{s}\",\"hash\":\"{x:0>16}\"}}\n", .{
        given, bytes.len, kind, std.hash.Wyhash.hash(0, bytes),
    });
    return 201;
}

fn strategy_name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// `@<name> args` names an uploaded strategy: its bytes kept by content (artifacts/<hash>-<name>,
/// as a run's program), with the arguments (`wasm:` before a WebAssembly module's: run inside
/// the explorer). Anything else is a command as given.
fn strategy_resolve(server: *Server, strategy: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, strategy, "@")) return strategy;
    const end = std.mem.indexOfScalar(u8, strategy, ' ') orelse strategy.len;
    const name = strategy[1..end];
    if (!strategy_name_valid(name)) return error.BadRequest;
    const uploaded = try print(server, "{s}/strategies/{s}", .{ server.options.data_directory, name });
    const kept = artifact_keep(server, uploaded) catch |err| switch (err) {
        error.BadRequest => {
            server.detail = try print(server, "no strategy uploaded as {s}", .{name});
            return error.BadRequest;
        },
        else => return err,
    };
    var magic: [4]u8 = @splat(0);
    file_start(server.arena, kept, &magic);
    return print(server, "{s}{s}{s}", .{ if (wasm_module(&magic)) "wasm:" else "", kept, strategy[end..] });
}

/// A WebAssembly module's bytes start so (its magic, `\0asm`).
fn wasm_module(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x00asm");
}

/// A file's first bytes, into `start` (left as it was when the file cannot be read).
fn file_start(arena: std.mem.Allocator, path: []const u8, start: []u8) void {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return;
    const opened = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    defer _ = linux.close(@intCast(opened));
    _ = linux.read(@intCast(opened), start.ptr, start.len);
}

/// A base64 body (standard alphabet, padded; line breaks ignored), decoded.
fn base64_decoded(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var compact: std.ArrayList(u8) = .empty;
    for (text) |c| if (c != '\n' and c != '\r' and c != ' ') try compact.append(arena, c);
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(compact.items) catch return error.BadRequest;
    const bytes = try arena.alloc(u8, size);
    decoder.decode(bytes, compact.items) catch return error.BadRequest;
    return bytes;
}

test base64_decoded {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const decoded = try base64_decoded(arena_state.allocator(), "AGFzbQ\nEAAAA=\n");
    try std.testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", decoded);
    try std.testing.expect(wasm_module(decoded));
    try std.testing.expect(!wasm_module("#!/bin/sh\n"));
    try std.testing.expectError(error.BadRequest, base64_decoded(arena_state.allocator(), "not base64!"));
}

test strategy_name_valid {
    try std.testing.expect(strategy_name_valid("llm.py"));
    try std.testing.expect(!strategy_name_valid("../x"));
    try std.testing.expect(!strategy_name_valid(".hidden"));
}

pub fn system_arguments(
    arena: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    asked: *const RunRequest,
) !void {
    const sources = @as(u32, @intFromBool(asked.program != null)) + @intFromBool(asked.compose != null) +
        @intFromBool(asked.kubernetes != null);
    if (sources != 1) return error.BadRequest;
    if (asked.program) |program| try argv.appendSlice(arena, &.{ "--program", program });
    if (asked.compose) |compose| try argv.appendSlice(arena, &.{ "--compose", compose });
    if (asked.kubernetes) |manifests| try argv.appendSlice(arena, &.{ "--kubernetes", manifests });
    if (asked.images) |list| try argv.appendSlice(arena, &.{ "--images", list });
    try argv.append(arena, if (asked.cpu_modulation) "--cpu-modulation" else "--no-cpu-modulation");
    if (asked.cpu_modulation_stretch_us) |stretch| try argv.appendSlice(arena, &.{ "--cpu-modulation-stretch-us", stretch });
    // They change the system (what its nodes allow): runs and their replays both.
    if (asked.faults) |kinds| try argv.appendSlice(arena, &.{ "--faults", kinds });
    if (asked.no_faults) |names| try argv.appendSlice(arena, &.{ "--no-faults", names });
    if (asked.coverage) |set| try argv.appendSlice(arena, &.{ "--coverage", set });
    // Part of the inputs (the guest's command line): replays need it too.
    if (asked.timeline) |length| try argv.appendSlice(arena, &.{ "--timeline", length });
    // `det.swarm=0`, as the run had it: given to the run alone, every replay and session of a
    // swarm-less run was refused (TapeInputsDiffer, a session from the REPL on a demo run).
    if (!asked.swarm) try argv.append(arena, "--no-swarm");
    if (asked.min_drive) |length| try argv.appendSlice(arena, &.{ "--min-drive", length });
    if (asked.drivers_cpu_weight) |weight| try argv.appendSlice(arena, &.{ "--drivers-cpu-weight", weight });
    if (asked.fault_weights) |weights| try argv.appendSlice(arena, &.{ "--fault-weights", weights });
    if (asked.fault_exclusions) |pattern| try argv.appendSlice(arena, &.{ "--fault-exclusions", pattern });
    if (asked.decide) |fixed| try argv.appendSlice(arena, &.{ "--decide", fixed });
    if (asked.keep) |names| try argv.appendSlice(arena, &.{ "--keep", names });
    if (asked.drive_max) |length| try argv.appendSlice(arena, &.{ "--drive-max", length });
    if (asked.trace_errno) |errno| try argv.appendSlice(arena, &.{ "--trace-errno", try std.fmt.allocPrint(arena, "{d}", .{errno}) });
}

/// The run, as it is now (a copy: the watcher updates the list).
fn run_get(server: *Server, id: u32) ?Run {
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    for (shared.runs[0..shared.run_count]) |run| {
        if (run.id == id) return run;
    }
    return null;
}

/// Every run, as they are now.
fn runs_copy(server: *Server) []const Run {
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    return server.arena.dupe(Run, shared.runs[0..shared.run_count]) catch &.{};
}

/// Stops a running run: SIGTERM to its explorer (its workers and verifier die with it), whoever
/// started it. Marked stopped, on disk too.
/// POST /runs/<id>/stop: its explorer ends now (SIGTERM), the timelines running with it,
/// discarded; with `?drain=1`, it starts none more and ends once those running end, each
/// recorded (SIGUSR2, main.zig's drain_requested). Either way the run is stopped: resumable.
/// `why`: serve's own reason, kept in the run's `stopped` file (empty for someone's stop).
fn run_stop(server: *Server, id: u32, drain: bool, why: []const u8, out: *std.Io.Writer) !u16 {
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    const run = for (shared.runs[0..shared.run_count]) |*run| {
        if (run.id == id) break run;
    } else return error.NotFound;
    if (run.status != null) return error.NotRunning;
    if (linux.errno(linux.kill(run.pid, if (drain) .USR2 else .TERM)) != .SUCCESS) return error.NotRunning;
    const directory = try run_directory(server, run.id);
    const path = try std.fs.path.join(server.arena, &.{ directory, if (drain) "draining" else "stopped" });
    // The file, then the state: a reader that finds the run stopped finds its reason there.
    // Signalled already, it is stopped whatever the write says.
    const written = std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = why });
    if (drain) run.draining = true else run.stopped = true;
    try written;
    try out.print("{{\"id\":{d},\"state\":\"{s}\"}}\n", .{ run.id, if (drain) "draining" else "stopped" });
    return 200;
}

/// A draining run whose explorer is gone: stopped, as a stop leaves it (resumable), its
/// `draining` mark replaced by `stopped`.
fn drained_mark(server: *Server, run: *Run) void {
    if (!run.draining) return;
    run.draining = false;
    run.stopped = true;
    const directory = run_directory(server, run.id) catch return;
    const stopped = std.fs.path.join(server.arena, &.{ directory, "stopped" }) catch return;
    std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = stopped, .data = "" }) catch return;
    const draining = std.fs.path.join(server.arena, &.{ directory, "draining" }) catch return;
    std.Io.Dir.cwd().deleteFile(server.io, draining) catch {};
}

/// Continues a run that ended before its end (stopped, or its explorer interrupted): its
/// explorer again, as it was asked and with the files it kept (a deploy since changes nothing
/// of it), skipping the timelines its record has (explore --resume). Flat runs, and trees that
/// recorded their timelines' summaries.
fn run_resume(server: *Server, id: u32, out: *std.Io.Writer) !u16 {
    const shared = server.shared;
    shared.lock();
    defer shared.unlock();
    const run = for (shared.runs[0..shared.run_count]) |*run| {
        if (run.id == id) break run;
    } else return error.NotFound;
    const interrupted = run.stopped or run.status == status_interrupted;
    if (run.status == null and !run.stopped) {
        server.detail = "the run is running";
        return error.BadRequest;
    }
    if (!interrupted) {
        server.detail = "the run finished: nothing to continue";
        return error.BadRequest;
    }
    const asked = try std.json.parseFromSliceLeaky(RunRequest, server.arena, try run_file(server, id, "request.json"), .{
        .ignore_unknown_fields = true,
    });
    if (!std.mem.eql(u8, asked.branching orelse "tree", "flat")) {
        // A tree continues from its timelines' summaries (recorded since resume came): there, not
        // read (a long run's pass the response limit: Kafka 1919's 360 MB, "no summaries").
        const summaries = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), "record.jsonl.summaries" });
        std.Io.Dir.cwd().access(server.io, summaries, .{}) catch {
            server.detail = "this tree run has no timeline summaries to continue from (an older run)";
            return error.BadRequest;
        };
        if (asked.strategy != null) {
            server.detail = "a tree run with a strategy does not resume (its state was the strategy's)";
            return error.BadRequest;
        }
    }
    const machine = try machine_exact_unless_jittered(server.arena, try std.json.parseFromSliceLeaky([]const []const u8, server.arena, try run_file(server, id, "machine.json"), .{}));
    const directory = try run_directory(server, id);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, try explore_arguments(server, &asked, directory, machine));
    // The system it booted (its pin), not the one its images and Dockerfiles make now: the hunt
    // queue's workload build gave ParticleDB's image another digest, and every resume of its
    // eight runs was refused as the record of another run (runs 1877 and 1873, 2026-11-11).
    try pin_arguments(server, &argv, run.id);
    try argv.append(server.arena, "--resume");
    const output = try std.fs.path.join(server.arena, &.{ directory, "output.log" });
    // The explorer it resumes on is its own, the one it was created with (its record continues
    // only as the same build plans): said in its output and in the answer, with serve's build
    // when another. etcd's run 2007, created at 19:04 and resumed at 20:41 after a deploy at
    // 20:32, was taken for a run on the deployed build, whose holders' budget it never had.
    const run_build = asked.build orelse "unknown";
    const same_build = std.mem.eql(u8, run_build, build_options.commit);
    const same_core = core_same(&asked, build_options.core_id, host_core.kvm_identity(server.arena), host_runs.state_format);
    resume_note(server, output, run_build, same_build, same_core);
    const pid = try spawn(server, argv.items, output, try run_environment(server.arena, &asked), .appended);
    const stopped_path = try std.fs.path.join(server.arena, &.{ directory, "stopped" });
    std.Io.Dir.cwd().deleteFile(server.io, stopped_path) catch {};
    run.* = .{ .id = id, .pid = pid };
    try out.print("{{\"id\":{d},\"state\":\"running\",\"build\":{f},\"serve_build\":{f},\"same_core\":{}}}\n", .{
        id, std.json.fmt(if (same_core) build_options.commit else run_build, .{}), std.json.fmt(build_options.commit, .{}), same_core,
    });
    return 200;
}

/// A line in a resumed run's output: the build of the explorer it goes on with.
fn resume_note(server: *Server, output: []const u8, run_build: []const u8, same_build: bool, same_core: bool) void {
    const path = server.arena.dupeSentinel(u8, output, 0) catch return;
    const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const line = (if (same_build)
        print(server, "[serve] resumed on its explorer, build {s}\n", .{run_build})
    else if (same_core)
        print(server, "[serve] resumed on serve's explorer, build {s} (the run's was {s}): its core is the run's ({s}), so what changed since outside the core is in this run\n", .{ build_options.commit, run_build, build_options.core_id })
    else
        print(server, "[serve] resumed on its explorer, build {s}: serve's is {s}, and what changed since is not in this run\n", .{ run_build, build_options.commit })) catch return;
    _ = linux.write(fd, line.ptr, line.len);
}

/// A run this server started has its pid file at once (its explorer takes it over, the same
/// pid, and holds its lock while it runs): a server started later lists it whatever happened to
/// its explorer. Without it, one whose explorer ended without writing the file waited out the
/// claim's grace (runs_discover), unlisted: after the self-test controller's restart, every run
/// it had accepted was "lost".
fn pid_note(server: *Server, directory: []const u8, pid: linux.pid_t) void {
    const path = std.fmt.allocPrintSentinel(server.arena, "{s}/pid", .{directory}, 0) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return; // Its explorer wrote it first.
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const text = std.fmt.allocPrint(server.arena, "{d}\n", .{pid}) catch return;
    _ = linux.write(fd, text.ptr, text.len);
}

/// The runs in the data directory this server does not list yet: at its start every one, then
/// those that appear (explorations started at a terminal or by a script: runs.zig). One whose
/// explorer runs (it holds the run's pid file) is adopted: running, whatever its record says
/// (`--scenario all` records a summary per scenario), or killed if it was stopped. Of the
/// others, one whose record has its summary passed or failed by that summary; the rest were
/// interrupted (an error), or stopped on request. A directory just claimed, with no pid file
/// yet, waits for the next look (a minute at most: then its explorer ended before writing it).
fn runs_discover(server: *Server) !void {
    const shared = server.shared;
    const runs_path = try std.fs.path.join(server.arena, &.{ server.options.data_directory, "runs" });
    for (try host_runs.ids(server.arena, runs_path)) |id| {
        const known = for (shared.runs[0..shared.run_count]) |run| {
            if (run.id == id) break true;
        } else false;
        if (known) continue;
        if (shared.run_count == runs_max) return;
        const directory = try run_directory(server, id);
        const pid_path = try std.fs.path.join(server.arena, &.{ directory, "pid" });
        const has_pid = if (std.Io.Dir.cwd().access(server.io, pid_path, .{})) |_| true else |_| false;
        if (!has_pid and age_s(server.arena, directory) < claim_grace_s) continue;
        const record = run_file(server, id, "record.jsonl") catch "";
        const stopped = if (run_file(server, id, "stopped")) |_| true else |_| false;
        const draining = if (run_file(server, id, "draining")) |_| true else |_| false;
        // How its explorer ended, when a server reaped it (exit_note); else what it recorded.
        const noted = if (run_file(server, id, "exit")) |text|
            std.fmt.parseInt(u32, text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len], 10) catch null
        else |_|
            null;
        var run = Run{ .id = id, .pid = 0, .status = noted orelse recorded_status(record), .stopped = stopped, .draining = draining };
        // A drain whose explorer ended while no server watched: stopped now.
        if (draining and host_runs.running_pid(server.arena, directory) == null) drained_mark(server, &run);
        if (host_runs.running_pid(server.arena, directory)) |pid| {
            if (stopped) {
                _ = linux.kill(pid, .KILL);
            } else {
                run.pid = pid;
                run.status = null;
                run.adopted = true;
            }
        }
        // One that ended before a server saw it end (stopped meanwhile, or before servers
        // dropped them: run 177's 107 GB, srv3 2026-10-29) leaves no holders behind either.
        if (run.status != null) holders_drop(server, &run);
        // And nothing for the watcher: its timelines are ingested when it is first asked about
        // (run_update at each request). The watcher attached every run's database at serve's
        // start, one after the other (srv4's 2,000), and an attach brings a database of an
        // earlier build up to date in place (store.schema_ensure: minutes for a long run's):
        // the running run's ingests and the reaping behind them all.
        if (run.status != null) run.complete = true;
        // Nor for the coverage gate: it judges the runs this serve sees end, not the host's
        // history (each ended run's events read once more at its first request).
        if (run.status != null or run.stopped) shared.coverage_known[id] = true;
        runs_insert(shared, run);
    }
}

/// How long a claimed run directory may go without its pid file.
const claim_grace_s = 60;

/// runs_discover from the watcher, with the lock held.
fn runs_discover_locked(shared: *Shared) void {
    var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer request_arena.deinit();
    var server: Server = .{
        .shared = shared,
        .options = shared.options,
        .io = shared.io,
        .arena = request_arena.allocator(),
    };
    runs_discover(&server) catch |err| {
        std.debug.print("[determinismo] looking for new runs: {s}\n", .{@errorName(err)});
    };
}

/// Into the list, which stays in id order.
fn runs_insert(shared: *Shared, run: Run) void {
    assert(shared.run_count < runs_max);
    var at = shared.run_count;
    while (at > 0 and shared.runs[at - 1].id > run.id) : (at -= 1) {
        shared.runs[at] = shared.runs[at - 1];
    }
    shared.runs[at] = run;
    shared.run_count += 1;
}

/// When the path last changed, in seconds since the epoch.
fn mtime_s(arena: std.mem.Allocator, path: []const u8) ?i64 {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return null;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path_z, 0, .{ .MTIME = true }, &stat)) != .SUCCESS) return null;
    return stat.mtime.sec;
}

/// A running explorer's status unchanged this long: it is stalled (it writes it every half minute
/// while timelines run; judging a generation, nodes made by long replays, can take minutes).
const stall_after_s = 30 * 60;

/// Seconds since the path changed (0 if it cannot tell).
fn age_s(arena: std.mem.Allocator, path: []const u8) u64 {
    const path_z = arena.dupeSentinel(u8, path, 0) catch return 0;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path_z, 0, .{ .MTIME = true }, &stat)) != .SUCCESS) return 0;
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    const changed: i64 = stat.mtime.sec;
    return if (now.sec > changed) @intCast(now.sec - changed) else 0;
}

const status_interrupted = 255;

/// Whether `pid_text` names a live process whose command line has `needle` (not another that
/// took its number since).
fn process_alive(server: *Server, pid_text: []const u8, needle: []const u8) bool {
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, pid_text, " \n"), 10) catch return false;
    const arena = server.arena;
    const cmdline_path = std.fmt.allocPrintSentinel(arena, "/proc/{d}/cmdline", .{pid}, 0) catch
        return false;
    // Read until the end: procfs files report no size.
    const fd = linux.open(cmdline_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var cmdline_buffer: [1 << 16]u8 = undefined;
    var size: usize = 0;
    while (size < cmdline_buffer.len) {
        const free = cmdline_buffer[size..];
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        size += result;
    }
    const cmdline = cmdline_buffer[0..size];
    return std.mem.indexOf(u8, cmdline, needle) != null;
}

fn recorded_status(record: []const u8) u32 {
    const key = "{\"summary\":";
    const start = std.mem.lastIndexOf(u8, record, key) orelse return status_interrupted;
    const failing_key = "\"failing_branches\":";
    const failing = std.mem.indexOfPos(u8, record, start, failing_key) orelse
        return status_interrupted;
    const digit = failing + failing_key.len;
    if (digit >= record.len) return status_interrupted;
    // A failing property fails the run, as explore exits: a sometimes never true too, not only
    // the timelines where an always failed (Datomic's runs 441, 445, 447 read as passed).
    const summary_end = std.mem.indexOfScalarPos(u8, record, start, '\n') orelse record.len;
    if (std.mem.indexOf(u8, record[start..summary_end], "\"failing\":true") != null) return 3;
    return if (record[digit] == '0') 0 else 3;
}

/// How a run's explorer ended, kept in its directory (`exit`: the status, then in words) for a
/// server started later; when not as explore ends (0, 3), said in its output.log too. Only the
/// parent learns a signal: run 31 (Dgraph, srv3 2026-10-28) ended at 09:15 with nothing in its
/// output or the kernel's log, and the restarted server could only say it was interrupted.
fn exit_note(server: *Server, id: u32, bits: u32) void {
    const signal = bits & 0x7f;
    const code = (bits >> 8) & 0xff;
    const status = if (signal == 0) code else 128 + signal;
    const text = (if (signal == 0)
        print(server, "{d} exited with status {d}\n", .{ status, code })
    else
        print(server, "{d} ended by signal {d} ({s})\n", .{ status, signal, signal_name(signal) })) catch return;
    const directory = run_directory(server, id) catch return;
    const cwd = std.Io.Dir.cwd();
    const path = std.fs.path.join(server.arena, &.{ directory, "exit" }) catch return;
    cwd.writeFile(server.io, .{ .sub_path = path, .data = text }) catch {};
    if (signal == 0 and (code == 0 or code == 3)) return;
    const output = std.fs.path.joinZ(server.arena, &.{ directory, "output.log" }) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true };
    const opened = linux.open(output, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const line = print(server, "[serve] the explorer {s}", .{text[std.mem.indexOfScalar(u8, text, ' ').? + 1 ..]}) catch return;
    _ = linux.write(fd, line.ptr, line.len);
}

fn signal_name(signal: u32) []const u8 {
    return switch (signal) {
        @backingInt(linux.SIG.KILL) => "SIGKILL: the OOM killer, or a kill",
        @backingInt(linux.SIG.TERM) => "SIGTERM",
        @backingInt(linux.SIG.INT) => "SIGINT",
        @backingInt(linux.SIG.SEGV) => "SIGSEGV",
        @backingInt(linux.SIG.ABRT) => "SIGABRT: a panic",
        @backingInt(linux.SIG.BUS) => "SIGBUS",
        @backingInt(linux.SIG.PIPE) => "SIGPIPE",
        else => "another signal",
    };
}

/// Marks the runs and jobs that ended (the watcher's, under the lock); the runs that ended on
/// their own (passed or failed: not stopped, not an error) go in `ended`, how many returned.
fn runs_reap(shared: *Shared, ended: []u32) usize {
    var ended_count: usize = 0;
    var request_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer request_arena.deinit();
    var server: Server = .{
        .shared = shared,
        .options = shared.options,
        .io = shared.io,
        .arena = request_arena.allocator(),
    };
    for (shared.jobs[0..shared.job_count]) |*job| {
        if (job.done) continue;
        var status: i32 = 0;
        const result = linux.wait4(job.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(result) == .SUCCESS and result != 0) job.done = true;
    }
    for (shared.runs[0..shared.run_count]) |*run| {
        if (run.status != null) continue;
        if (run.adopted) {
            const directory = run_directory(&server, run.id) catch continue;
            if (host_runs.running_pid(server.arena, directory) != null) continue;
            const record = run_file(&server, run.id, "record.jsonl") catch "";
            run.status = recorded_status(record);
            drained_mark(&server, run);
            // Not this serve's child: what its explorer left is found by its session.
            if (std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, run_file(&server, run.id, "pid") catch "", " \n"), 10)) |explorer| {
                session_kill(explorer, run.id);
            } else |_| {}
            holders_drop(&server, run);
            if (run_ended_itself(run) and ended_count < ended.len) {
                ended[ended_count] = run.id;
                ended_count += 1;
            }
            continue;
        }
        var status: i32 = 0;
        const result = linux.wait4(run.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(result) != .SUCCESS or result == 0) continue;
        const bits: u32 = @bitCast(status);
        run.status = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
        exit_note(&server, run.id, bits);
        drained_mark(&server, run);
        // What the explorer left in its process group (it leads its session): holders of
        // timelines it stopped waiting for, workers of a killed explorer; and in its session,
        // what leads a group of its own.
        _ = linux.kill(-run.pid, .KILL);
        session_kill(run.pid, run.id);
        holders_drop(&server, run);
        archive(&server, run) catch |err| {
            std.debug.print("[determinismo] archiving run {d} failed: {s}\n", .{
                run.id, @errorName(err),
            });
        };
        if (run_ended_itself(run) and ended_count < ended.len) {
            ended[ended_count] = run.id;
            ended_count += 1;
        }
    }
    return ended_count;
}

/// Every explorer process still in the session `explorer` led (its workers, holders and
/// replays: a replay leads a process group of its own, and a kill of the explorer's group missed
/// it; run 1187's verification replay ran on orphaned at 6.5 GB after its run was stopped, the
/// run adopted by a serve a deploy had restarted). Only `explore` processes naming the run
/// (`runs/<id>`): a pid reused since is another's.
fn session_kill(explorer: linux.pid_t, id: u32) void {
    const opened = linux.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const proc: linux.fd_t = @intCast(opened);
    defer _ = linux.close(proc);
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(proc, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const pid = std.fmt.parseInt(linux.pid_t, name, 10) catch continue;
            if (pid == linux.getpid()) continue;
            var path_buffer: [48]u8 = undefined;
            var text_buffer: [512]u8 = undefined;
            const stat = proc_read(std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch continue, &text_buffer) orelse continue;
            if (session_of(stat) != explorer) continue;
            const cmdline = proc_read(std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cmdline", .{pid}, 0) catch continue, &text_buffer) orelse continue;
            if (!ends_with_run(cmdline, id)) continue;
            _ = linux.kill(pid, .KILL);
        }
    }
}

fn proc_read(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const read = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(read) != .SUCCESS) return null;
    return buffer[0..read];
}

/// A process's session, from its /proc stat: after the command's `)` come its state, parent,
/// group and session.
fn session_of(stat: []const u8) ?linux.pid_t {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    for (0..3) |_| _ = fields.next() orelse return null;
    return std.fmt.parseInt(linux.pid_t, fields.next() orelse return null, 10) catch null;
}

/// Whether a command line names run `id` (`runs/<id>`, a path's part, not `runs/<id>7`).
fn names_run(cmdline: []const u8, id: u32) bool {
    var needle_buffer: [24]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "runs/{d}", .{id}) catch return false;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, cmdline, at, needle)) |found| {
        const after = found + needle.len;
        if (after == cmdline.len or !std.ascii.isDigit(cmdline[after])) return true;
        at = after;
    }
    return false;
}

/// The watcher's ticks (a second each), the orphaned checks' sweep every this many.
var orphan_sweep_ticks: u64 = 0;
const orphan_sweep_every = 30;

/// Host checks whose run is gone: reparented to init, their session's leader (the explorer) no
/// longer there, so their verdict reaches no one. Whatever left them (a run ended before checks
/// went with it, an explorer killed outright), they would hold the Elle service's slots on (hunt
/// run 1202's 13, for 44 min).
fn orphan_checks_kill() void {
    const opened = linux.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const proc: linux.fd_t = @intCast(opened);
    defer _ = linux.close(proc);
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(proc, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const pid = std.fmt.parseInt(linux.pid_t, name, 10) catch continue;
            var path_buffer: [48]u8 = undefined;
            var text_buffer: [512]u8 = undefined;
            const stat = proc_read(std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch continue, &text_buffer) orelse continue;
            if (parent_of(stat) != 1) continue;
            const session = session_of(stat) orelse continue;
            const cmdline = proc_read(std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cmdline", .{pid}, 0) catch continue, &text_buffer) orelse continue;
            if (!is_check(cmdline)) continue;
            const leader = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}", .{session}, 0) catch continue;
            if (linux.errno(linux.access(leader, linux.F_OK)) == .SUCCESS) continue;
            _ = linux.kill(pid, .KILL);
        }
    }
}

/// A process's parent, from its /proc stat (the field after its state).
fn parent_of(stat: []const u8) ?linux.pid_t {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = fields.next() orelse return null;
    return std.fmt.parseInt(linux.pid_t, fields.next() orelse return null, 10) catch null;
}

/// Whether a process of the run's explorer session goes with the run: an explorer naming it, or
/// one of its host checks (`<program> check <name> <scenario>`, which names no run: hunt run
/// 1202's 13 Elle checks ran on 44 min after it was stopped, orphans holding the Elle service's
/// slots). The session is the run's own (its explorer's), so its checks are this run's.
fn ends_with_run(cmdline: []const u8, id: u32) bool {
    return (is_explore(cmdline) and names_run(cmdline, id)) or is_check(cmdline);
}

/// Whether a command line (NUL-separated) is a test program's host check: its first argument
/// `check`.
fn is_check(cmdline: []const u8) bool {
    var arguments = std.mem.splitScalar(u8, cmdline, 0);
    _ = arguments.next() orelse return false;
    return std.mem.eql(u8, arguments.next() orelse return false, "check");
}

/// Whether a command line (NUL-separated) is an explorer's: its first argument `explore`.
fn is_explore(cmdline: []const u8) bool {
    var arguments = std.mem.splitScalar(u8, cmdline, 0);
    _ = arguments.next() orelse return false;
    return std.mem.eql(u8, arguments.next() orelse return false, "explore");
}

test ends_with_run {
    try std.testing.expect(ends_with_run("/proc/self/exe\x00explore\x00--run\x00/d/runs/12\x00", 12));
    try std.testing.expect(!ends_with_run("/proc/self/exe\x00explore\x00--run\x00/d/runs/12\x00", 13));
    // A run's host check names no run: its session says whose it is.
    try std.testing.expect(ends_with_run("/a/ffd0-rethinkdb-test\x00check\x00elle\x00cas\x00", 12));
    try std.testing.expect(!ends_with_run("/usr/bin/sleep\x0060\x00", 12));
}

test parent_of {
    try std.testing.expectEqual(@as(?linux.pid_t, 1), parent_of("2940694 (a (b) c) S 1 2932447 2927455 0"));
    try std.testing.expectEqual(@as(?linux.pid_t, null), parent_of("9 (exe) S"));
}

test session_of {
    try std.testing.expectEqual(@as(?linux.pid_t, 2927455), session_of("2940694 (exe) S 1 2932447 2927455 0 -1 4194560 12"));
    // A command with spaces and parentheses of its own.
    try std.testing.expectEqual(@as(?linux.pid_t, 7), session_of("9 (a (b) c) R 1 5 7 0"));
    try std.testing.expectEqual(@as(?linux.pid_t, null), session_of("9 (exe) S 1"));
    try std.testing.expect(is_explore("/proc/self/exe\x00explore\x00--kernel\x00k\x00"));
    try std.testing.expect(!is_explore("/usr/bin/sleep\x0060\x00"));
    try std.testing.expect(names_run("x\x00--program\x00/d/runs/1187/tapes/program\x00", 1187));
    try std.testing.expect(names_run("x\x00--run\x00/d/runs/1187\x00", 1187));
    try std.testing.expect(!names_run("x\x00--run\x00/d/runs/11870\x00", 1187));
}

fn run_ended_itself(run: *const Run) bool {
    const status = run.status orelse return false;
    return !run.stopped and (status == 0 or status == 3);
}

/// A run asked to repeat that ended on its own: the next, with its request and a fresh seed.
fn run_repeat(server: *Server, id: u32) !void {
    const request_json = run_file(server, id, "request.json") catch return;
    var asked = std.json.parseFromSliceLeaky(RunRequest, server.arena, request_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (!asked.repeat) return;
    asked.seed = null;
    asked.program = asked.program_asked orelse asked.program; // The current build.
    // And the strategy's latest upload under its name.
    if (asked.strategy_asked) |strategy| asked.strategy = strategy;
    asked.strategy_asked = null;
    const body = try std.fmt.allocPrint(server.arena, "{f}", .{std.json.fmt(asked, .{})});
    var out: std.Io.Writer.Allocating = .init(server.arena);
    _ = try run_create(server, body, &out.writer);
    std.debug.print("[determinismo] run {d} repeats as {s}", .{ id, out.written() });
}

/// Hands a finished run's directory to the archive command (in the background).
/// A run's holders on disk serve only its explorer: one stopped (SIGTERM, no defers run) left
/// them, 209 GB of run 173's until srv3's disk was full. A resume starts without them anyway.
fn holders_drop(server: *Server, run: *const Run) void {
    const directory = run_directory(server, run.id) catch return;
    const path = std.fs.path.join(server.arena, &.{ directory, "holders" }) catch return;
    const disk: holders.Disk = .{ .directory = path };
    // Off serve's shared lock, which the reap holds (an ended long run's holders are hundreds
    // of GB: run 2019's held every request for minutes).
    disk.delete_detached();
}

fn archive(server: *Server, run: *const Run) !void {
    const template = server.options.archive orelse return;
    const directory = try run_directory(server, run.id);
    const id = try print(server, "{d}", .{run.id});
    const with_dir = try std.mem.replaceOwned(u8, server.arena, template, "{dir}", directory);
    const command = try std.mem.replaceOwned(u8, server.arena, with_dir, "{id}", id);
    const log = try std.fs.path.join(server.arena, &.{ directory, "archive.log" });
    _ = try spawn(server, &.{ "/bin/sh", "-c", command }, log, &.{}, .fresh);
}

fn state(run: *const Run) []const u8 {
    if (run.stopped) return "stopped";
    const status = run.status orelse return "running";
    return switch (status) {
        0 => "passed",
        3 => "failed",
        status_interrupted => "interrupted",
        else => "error",
    };
}

fn run_directory(server: *Server, id: u32) ![]const u8 {
    return std.fmt.allocPrint(server.arena, "{s}/runs/{d}", .{ server.options.data_directory, id });
}

const notebook_clj = @embedFile("notebook.clj");

fn notebook_script(server: *Server) ![]const u8 {
    const script = try std.fs.path.join(server.arena, &.{
        server.options.data_directory, "notebook.clj",
    });
    try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = script, .data = notebook_clj });
    return script;
}

/// A babashka nREPL server for the run (started once, on loopback): the notebook's names in
/// `user`, over the run's events and record, with actions that run at once through this API.
/// Editors connect through a tunnel to its port.
fn nrepl_start(server: *Server, id: u32, out: *std.Io.Writer) !u16 {
    const shared = server.shared;
    shared.lock();
    defer shared.unlock(); // Started once.
    const run = for (shared.runs[0..shared.run_count]) |*run| {
        if (run.id == id) break run;
    } else return error.NotFound;
    if (run.nrepl_port == null) {
        const arena = server.arena;
        const port: u16 = nrepl_port_base + @as(u16, @intCast(run.id % 1000));
        const directory = try run_directory(server, run.id);
        const address = try print(server, "127.0.0.1:{d}", .{port});
        const argv = [_][]const u8{
            server.options.bb, "--init", try notebook_script(server), "nrepl-server", address,
        };
        const environment = [_][]const u8{
            try print(server, "DETERMINISMO={s}", .{server.options.self}),
            try print(server, "DETERMINISMO_RECORD={s}/record.jsonl", .{directory}),
            try print(server, "DETERMINISMO_SERVE=http://{s}", .{listen_address(server)}),
            try print(server, "DETERMINISMO_API=http://{s}", .{listen_address(server)}),
            try print(server, "DETERMINISMO_RUN={d}", .{run.id}),
        };
        const log = try std.fs.path.join(arena, &.{ directory, "nrepl.log" });
        _ = try spawn(server, &argv, log, &environment, .fresh);
        run.nrepl_port = port;
    }
    try out.print("{{\"port\":{d}}}\n", .{run.nrepl_port.?});
    return 200;
}

/// Evaluates a notebook's cells (Clojure, with babashka: notebook.clj), the request's body as
/// its input: {"cells": [...], "results": {...}}; answers each cell's outputs.
fn notebook_evaluate(
    server: *Server,
    run: *const Run,
    body: []const u8,
    out: *std.Io.Writer,
) !u16 {
    const arena = server.arena;
    const directory = try run_directory(server, run.id);
    const cwd = std.Io.Dir.cwd();
    const script = try notebook_script(server);
    const input = try std.fs.path.join(server.arena, &.{ directory, "notebook-input.json" });
    try cwd.writeFile(server.io, .{ .sub_path = input, .data = body });
    var environment = std.process.Environ.Map.init(server.arena);
    try environment.put("DETERMINISMO", server.options.self);
    const record = try std.fs.path.join(arena, &.{ directory, "record.jsonl" });
    try environment.put("DETERMINISMO_RECORD", record);
    const serve_url = try print(server, "http://{s}", .{listen_address(server)});
    try environment.put("DETERMINISMO_SERVE", serve_url);
    try environment.put("DETERMINISMO_RUN", try print(server, "{d}", .{run.id}));
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    const result = try std.process.run(server.arena, server.io, .{
        .argv = &.{ server.options.bb, script, input },
        .environ_map = &environment,
    });
    if (result.stdout.len == 0) {
        try out.print("{{\"error\":{f}}}\n", .{std.json.fmt(result.stderr, .{})});
        return 500;
    }
    try out.writeAll(result.stdout);
    return 200;
}

/// The system a run booted (its pin, in its events): its replays boot the same node disks,
/// whatever the images and Dockerfiles have become since.
/// The run's profile's command that turns its logs up (schema.Profile.explain), from its pin.
fn system_explain(server: *Server, id: u32) ?[]const u8 {
    const pin_path = std.fs.path.join(server.arena, &.{ run_directory(server, id) catch return null, "events", "system.pin.json" }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(server.io, pin_path, server.arena, .limited(16 << 20)) catch return null;
    const Pin = struct { system_json: []const u8 = "" };
    const pin = std.json.parseFromSliceLeaky(Pin, server.arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    const System = struct { explain: ?[]const u8 = null };
    const system = std.json.parseFromSliceLeaky(System, server.arena, pin.system_json, .{ .ignore_unknown_fields = true }) catch return null;
    return system.explain;
}

fn pin_arguments(server: *Server, argv: *std.ArrayList([]const u8), id: u32) !void {
    const pin = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), "events", "system.pin.json" });
    std.Io.Dir.cwd().access(server.io, pin, .{}) catch return; // A run from before pins.
    try argv.appendSlice(server.arena, &.{ "--system", pin });
}

/// The machine arguments a run booted with (machine.json: its kept kernel and initramfs); for a
/// run from before they were kept, the host's. The host's --margin-branches wins over the run's:
/// how precisely a guest stops is this host's, not the recording one's (srv4's 48 overshot ~100
/// stops on a nested c8i and replayed DuckDB run 1950's timeline 241 into another history; 256
/// there was exact, 2026-11-13).
fn run_machine(server: *Server, id: u32) ![]const []const u8 {
    const json = run_file(server, id, "machine.json") catch return server.options.machine;
    const machine = try machine_exact_unless_jittered(server.arena, try std.json.parseFromSliceLeaky([]const []const u8, server.arena, json, .{}));
    return machine_with_host_margin(server.arena, machine, server.options.machine);
}

/// `machine` with the host's --margin-branches after it (explore takes a flag's last value),
/// when the host gives one.
fn machine_with_host_margin(arena: std.mem.Allocator, machine: []const []const u8, host: []const []const u8) ![]const []const u8 {
    for (host, 0..) |flag, index| {
        if (std.mem.eql(u8, flag, "--margin-branches") and index + 1 < host.len) {
            return std.mem.concat(arena, []const u8, &.{ machine, &.{ "--margin-branches", host[index + 1] } });
        }
    }
    return machine;
}

test machine_with_host_margin {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const run: []const []const u8 = &.{ "--kernel", "k", "--margin-branches", "48" };
    // A nested host's margin after the run's: explore's last value wins.
    const nested = try machine_with_host_margin(arena, run, &.{ "--cache", "c", "--margin-branches", "256" });
    try std.testing.expectEqual(@as(usize, 6), nested.len);
    try std.testing.expectEqualStrings("256", nested[5]);
    // A host that says none: the run's own.
    const metal = try machine_with_host_margin(arena, run, &.{ "--cache", "c" });
    try std.testing.expectEqual(run.len, metal.len);
}

/// Whether a run's machine arguments give its clock's jitter.
pub fn machine_has_jitter(machine: []const []const u8) bool {
    for (machine) |flag| {
        if (std.mem.eql(u8, flag, "--tsc-jitter-seed")) return true;
    }
    return false;
}

/// A run from before the clock's jitter kept none in machine.json: its replays and resumes read
/// the exact clock, said (explore draws a seed's jitter when given none).
fn machine_exact_unless_jittered(arena: std.mem.Allocator, machine: []const []const u8) ![]const []const u8 {
    if (machine_has_jitter(machine)) return machine;
    return std.mem.concat(arena, []const u8, &.{ machine, &.{ "--tsc-jitter-seed", "0" } });
}

/// The host's machine arguments, with the kernel and the initramfs kept (artifact_keep), the
/// memory asked for (the last --memory-mib is explore's), and the clock's event (unless the
/// host's give one): its resumes and replays count the same, whatever the default becomes.
fn machine_kept(server: *Server, memory_mib: ?u32, seed: u64) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, server.options.machine);
    for (server.options.machine) |flag| {
        if (std.mem.eql(u8, flag, "--branch-event")) break;
    } else try argv.appendSlice(server.arena, &.{ "--branch-event", try print(server, "0x{x}", .{VM.branch_event_default}) });
    // Its clock's jitter (VM.Options.tsc_jitter_seed), from the run's seed and kept with it, so its
    // replays read the same and runs of one seed begin alike; unless the host's machine gives one.
    for (server.options.machine) |flag| {
        if (std.mem.eql(u8, flag, "--tsc-jitter-seed")) break;
    } else {
        try argv.appendSlice(server.arena, &.{ "--tsc-jitter-seed", try print(server, "0x{x}", .{VM.jitter_from_seed(seed)}) });
    }
    var index: usize = 0;
    while (index + 1 < argv.items.len) : (index += 1) {
        const flag = argv.items[index];
        if (!std.mem.eql(u8, flag, "--kernel") and !std.mem.eql(u8, flag, "--initrd")) continue;
        argv.items[index + 1] = try artifact_keep(server, argv.items[index + 1]);
        index += 1;
    }
    if (memory_mib) |mib| try argv.appendSlice(server.arena, &.{ "--memory-mib", try print(server, "{d}", .{mib}) });
    return argv.items;
}

/// GET /build: the commit serve was built from and the guest it boots (its kernel and initramfs,
/// each by its content-named copy): what a product's cache keys on, since a machine's snapshot
/// holds the guest's tools as they were (determinismo-ci's setup: an update's det-faults never
/// reached shards started from a setup cached before it).
fn build_show(server: *Server, out: *std.Io.Writer) !u16 {
    try out.writeAll("{\"commit\":");
    try std.json.Stringify.value(build_options.commit, .{}, out);
    // The explorer that writes and reads machines' snapshots, by its content: a snapshot is
    // refused by another build (SnapshotOfAnotherBuild), and the commit says nothing of a build
    // made on a host ("unknown": a CI setup cached by the build before was refused, run 163).
    const explorer = try artifact_keep(server, server.options.self);
    try out.writeAll(",\"explorer\":");
    try std.json.Stringify.value(std.fs.path.basename(explorer), .{}, out);
    const machine = server.options.machine;
    var index: usize = 0;
    while (index + 1 < machine.len) : (index += 1) {
        const name = if (std.mem.eql(u8, machine[index], "--kernel")) "kernel" else if (std.mem.eql(u8, machine[index], "--initrd")) "initrd" else continue;
        const kept = try artifact_keep(server, machine[index + 1]);
        try out.print(",\"{s}\":", .{name});
        try std.json.Stringify.value(std.fs.path.basename(kept), .{}, out);
        index += 1;
    }
    try out.writeAll("}\n");
    return 200;
}

/// A copy of the file named by its content, under the data directory's `artifacts` (runs.zig).
fn artifact_keep(server: *Server, path: []const u8) ![]const u8 {
    return host_runs.artifact_keep(server.arena, server.io, server.options.data_directory, path) catch |err| switch (err) {
        // The client named it: its mistake, said as such.
        error.FileNotFound => {
            server.detail = try std.fmt.allocPrint(server.arena, "no such file: {s}", .{path});
            return error.BadRequest;
        },
        else => return err,
    };
}

/// A line of the explorer's own (`[determinismo] ...`, `[branch n] ...`, a property's verdict),
/// not of a guest's console.
fn explorer_line(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, "\x00");
    for ([_][]const u8{ "[determinismo]", "[branch ", "  PASS ", "  FAIL " }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }
    return false;
}

/// A query string's value for `name` (`offset=12&x=1`), if there.
fn query_value(query_string: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.tokenizeScalar(u8, query_string, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return null;
}

test query_value {
    try std.testing.expectEqualStrings("12", query_value("offset=12&x=1", "offset").?);
    try std.testing.expect(query_value("x=1", "offset") == null);
}

fn run_file(server: *Server, id: u32, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), name });
    const limit: std.Io.Limit = .limited(response_size_max);
    return std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, limit);
}

/// The first of the addresses serve listens on (`--listen a,b`): the one its own tools call (a
/// notebook's queries went to "http://127.0.0.1:7878,100.120.48.124:7878/...": srv3).
fn listen_address(server: *const Server) []const u8 {
    const addresses = server.options.listen;
    return addresses[0 .. std.mem.indexOfScalar(u8, addresses, ',') orelse addresses.len];
}

fn print(server: *Server, comptime format: []const u8, arguments: anytype) ![]const u8 {
    return std.fmt.allocPrint(server.arena, format, arguments);
}

/// Starts `argv` in the background with its output (both streams) in `output_path`.
/// Starts `argv` in the background, its output to `output_path`; `extra` adds "NAME=value"
/// to its environment.
/// A child of serve, with a fresh environment: a path, serve's data directory (a shrink's
/// explorations are runs of the host's store too: without it they found no store, "NoHome", and
/// every shrink from a run's page failed at once, srv4 2026-11-01), and `extra`.
/// What someone asked for while hunts run (a replay, a session, a fork's futures, an analysis):
/// on the reserved cores, a scope of the user's manager (its slice's CPUs: isolate.sh), out of
/// serve's cgroup, whose CPUs are the hunt's alone. On with reserved cores
/// (DETERMINISMO_RESERVED_SCOPE, serve.sh); systemd-run --scope execs the command itself, its
/// pid and descriptors the caller's.
fn reserved(server: *Server, argv: []const []const u8) ![]const []const u8 {
    const on = std.c.getenv("DETERMINISMO_RESERVED_SCOPE") orelse return argv;
    if (std.mem.span(on).len == 0) return argv; // No reserved cores: serve.sh leaves it empty.
    const prefix = [_][]const u8{ "/usr/bin/systemd-run", "--user", "--scope", "--quiet", "--collect", "--" };
    return std.mem.concat(server.arena, []const u8, &.{ &prefix, argv });
}

/// The user manager's runtime directory, for systemd-run --user (reserved).
fn runtime_directory_entry(arena: std.mem.Allocator) ![:0]const u8 {
    const value = if (std.c.getenv("XDG_RUNTIME_DIR")) |found| std.mem.span(found) else "";
    return std.fmt.allocPrintSentinel(arena, "XDG_RUNTIME_DIR={s}", .{value}, 0);
}

fn spawn(
    server: *Server,
    argv: []const []const u8,
    output_path: []const u8,
    extra: []const []const u8,
    output: enum { fresh, appended },
) !linux.pid_t {
    assert(argv.len > 0 and argv.len < arguments_max);
    const arena = server.arena;
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const output_z = try arena.dupeSentinel(u8, output_path, 0);
    // HOME as a replay has it (replay_run): a test program finds its tools there, a jank one its
    // jank (program_pack.zig's ~/opt/jank); without it every jank workload's describe failed
    // ("exec: /opt/jank/usr/local/bin/jank: not found", phoenixNAP run 1900).
    const home = std.c.getenv("HOME");
    const fixed: usize = if (home != null) 4 else 3;
    const environment = try arena.allocSentinel(?[*:0]const u8, extra.len + fixed, null);
    environment[0] = "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    environment[1] = try std.fmt.allocPrintSentinel(arena, "DETERMINISMO_DATA={s}", .{server.options.data_directory}, 0);
    environment[2] = try runtime_directory_entry(arena);
    if (home) |value| environment[3] = try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{std.mem.span(value)}, 0);
    for (extra, environment[fixed..]) |entry, *slot| slot.* = try arena.dupeSentinel(u8, entry, 0);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = output == .fresh,
            .APPEND = output == .appended,
        };
        const fd = linux.open(output_z, flags, 0o644);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.dup2(@intCast(fd), 1);
            _ = linux.dup2(@intCast(fd), 2);
        }
        _ = linux.setsid(); // Not killed with the server's terminal.
        _ = linux.execve(argv_z[0].?, argv_z.ptr, environment.ptr);
        linux.exit_group(127);
    }
    return @intCast(pid);
}

fn request_read(server: *Server, client: linux.fd_t) !Request {
    var buffer = try server.arena.alloc(u8, 64 * 1024);
    var size: usize = 0;
    while (true) {
        if (size == buffer.len) {
            if (buffer.len == request_size_max) return error.BadRequest;
            buffer = try server.arena.realloc(buffer, @min(buffer.len * 4, request_size_max));
        }
        const result = linux.read(client, buffer[size..].ptr, buffer.len - size);
        if (linux.errno(result) != .SUCCESS or result == 0) return error.BadRequest;
        size += result;
        const text = buffer[0..size];
        const header_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse continue;
        const length = content_length(text[0..header_end]);
        const total = header_end + 4 + length;
        if (total > request_size_max) return error.BadRequest;
        if (size < total) {
            if (total > buffer.len) buffer = try server.arena.realloc(buffer, total);
            continue;
        }
        var line = std.mem.tokenizeScalar(u8, text[0..header_end], ' ');
        return .{
            .method = line.next() orelse return error.BadRequest,
            .path = line.next() orelse return error.BadRequest,
            .body = text[header_end + 4 .. total],
            .gzip = accepts_gzip(text[0..header_end]),
        };
    }
}

fn accepts_gzip(headers: []const u8) bool {
    var lines = std.mem.tokenizeSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "accept-encoding")) continue;
        return std.mem.indexOf(u8, line[colon + 1 ..], "gzip") != null;
    }
    return false;
}

test accepts_gzip {
    try std.testing.expect(accepts_gzip("GET / HTTP/1.1\r\nAccept-Encoding: gzip, deflate, br"));
    try std.testing.expect(!accepts_gzip("GET / HTTP/1.1\r\nAccept: */*"));
}

/// Answers this large and up go gzipped to a client that takes it: a run's timelines, marks
/// and events are megabytes of JSON (about a tenth compressed), and a page may be at the far
/// end of a slow link.
const gzip_size_min = 1024;

/// `body` gzipped (std's deflate at its fastest), or null if compressing failed.
fn gzipped(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const flate = std.compress.flate;
    var out = std.Io.Writer.Allocating.initCapacity(arena, body.len / 4 + 4096) catch return null;
    const window = arena.alloc(u8, flate.max_window_len) catch return null;
    var compress = flate.Compress.init(&out.writer, window, .gzip, .level_1) catch return null;
    compress.writer.writeAll(body) catch return null;
    compress.finish() catch return null;
    return out.written();
}

test gzipped {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.append(arena, '[');
    for (0..300) |index| try text.print(arena, "{{\"index\":{d},\"why\":\"A random moment of #7249\"}},", .{index});
    try text.appendSlice(arena, "{}]");
    const body = text.items;
    const compressed = gzipped(arena, body).?;
    try std.testing.expect(compressed.len < body.len / 10);
    var input: std.Io.Reader = .fixed(compressed);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, window);
    const back = try decompress.reader.allocRemaining(arena, .unlimited);
    try std.testing.expectEqualStrings(body, back);
}

fn content_length(headers: []const u8) u32 {
    var lines = std.mem.tokenizeSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch 0;
    }
    return 0;
}

fn respond(client: linux.fd_t, status: u16, content_type: []const u8, body: []const u8) void {
    respond_encoded(client, status, content_type, "", body);
}

fn respond_encoded(
    client: linux.fd_t,
    status: u16,
    content_type: []const u8,
    encoding: []const u8,
    body: []const u8,
) void {
    var header: [320]u8 = undefined;
    const reason = switch (status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        503 => "Service Unavailable",
        else => "Internal Server Error",
    };
    const head = std.fmt.bufPrint(&header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n{s}" ++
        "Content-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{
        status, reason, content_type, encoding, body.len,
    }) catch unreachable;
    write_all(client, head);
    write_all(client, body);
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) != .SUCCESS) return;
        done += result;
    }
}

test recorded_status {
    try std.testing.expectEqual(@as(u32, 255), recorded_status("{\"run\":{}}\n"));
    const passed = "{\"summary\":{\"branches\":2,\"failing_branches\":0}}\n";
    try std.testing.expectEqual(@as(u32, 0), recorded_status(passed));
    const failed = "{\"summary\":{\"branches\":2,\"failing_branches\":1}}\n";
    try std.testing.expectEqual(@as(u32, 3), recorded_status(failed));
    // A sometimes never true fails the run, its timelines all without a failing always.
    const never_true = "{\"summary\":{\"branches\":1,\"failing_branches\":0,\"properties\":[{\"failing\":true}]}}\n";
    try std.testing.expectEqual(@as(u32, 3), recorded_status(never_true));
    const all_true = "{\"summary\":{\"branches\":1,\"failing_branches\":0,\"properties\":[{\"failing\":false}]}}\n";
    try std.testing.expectEqual(@as(u32, 0), recorded_status(all_true));
}

test content_length {
    const post = "POST /runs HTTP/1.1\r\nContent-Length: 12";
    try std.testing.expectEqual(@as(u32, 12), content_length(post));
    try std.testing.expectEqual(@as(u32, 0), content_length("GET /runs HTTP/1.1\r\nHost: x"));
}
