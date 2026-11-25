// SPDX-License-Identifier: MIT
//! The events database (ARCHITECTURE.md §12): a run's events and timelines in DuckDB
//! (duckdb.zig), where every question about a run is asked. The UI's panels, searches (query.zig
//! compiles them to SQL), event sets and notebooks are queries over it.
//!
//! The events directory holds what the VMM writes, one JSON line per event: setup.jsonl (boot
//! and setup, shared by every timeline), fork.jsonl (a fork's history), branch-<n>.jsonl (each
//! timeline's own events, after a `{"path": ...}` line when it began inside others), and
//! timelines.jsonl (a line per timeline once it finished, written after its events). `ingest`
//! brings in the timelines that finished since it last did, in one transaction: readers see
//! whole timelines only. The database is the directory's events.duckdb, opened by one process
//! at a time (serve, for its runs; else the command asking).
//!
//! Tables (and what the panels read):
//!   events     every event once: `branch` is the timeline whose file it is in (NULL: the
//!              setup's), `kind` its top key (assert, event, output, decision, lifecycle,
//!              guidance, antithesis_assert, antithesis_sdk, raw), and typed columns for what
//!              is filtered on (name, type, condition, node, text, behavior); `event` as written.
//!   timelines  a row per finished timeline, as timelines.jsonl has it.
//!   steps      where a tree timeline begins: the ancestors' parts it shares.
//!   timeline_events (view): each timeline's events, from the setup through its ancestors' parts
//!              to its own, as `timeline`, `origin` (the file's branch) and the event columns.
//!   summaries  what a run's pages show (its properties, statistics, timelines' list, map marks,
//!              logged errors), small, made of each timeline as it is ingested: the pages read
//!              them, never the events again (summaries_tables_sql). The events are for what is
//!              asked of them: searches, logs, a timeline opened.
const std = @import("std");
const event_files = @import("event_files.zig");
const assert = std.debug.assert;
pub const duckdb = @import("duckdb.zig");

pub const file_name = "events.duckdb";
/// The tables' shape: a database of another version is rebuilt from the files.
const schema_version = 13;

/// Paths of the events' JSON that searches read most (the UI's): kept as columns, their text
/// (`->>`) and their JSON type, which a condition reads instead of parsing every event
/// (query.zig). The same expressions, so the same answers.
pub const indexed_paths = [_]Indexed{
    .of("event", "path_event"),
    .of("assert.message", "path_assert_message"),
    .of("assert.condition", "path_assert_condition"),
    .of("antithesis_assert.message", "path_antithesis_assert_message"),
    .of("antithesis_assert.condition", "path_antithesis_assert_condition"),
    .of("details.node", "path_details_node"),
    .of("details.kind", "path_details_kind"),
};

pub const Indexed = struct {
    path: []const u8,
    column: []const u8,
    type_column: []const u8,

    fn of(comptime path: []const u8, comptime column: []const u8) Indexed {
        return .{ .path = path, .column = column, .type_column = column ++ "_type" };
    }
};

/// A JSON path (`a.b`) as JSON path syntax (`$."a"."b"`).
pub fn json_path(arena: std.mem.Allocator, dotted: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("$");
    var keys = std.mem.splitScalar(u8, dotted, '.');
    while (keys.next()) |key| try out.writer.print(".\"{s}\"", .{key});
    return out.written();
}

/// The indexed paths' columns as a SELECT list over `event`: `<column>, <column>_type`.
pub fn indexed_select(arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (indexed_paths) |indexed| {
        const path = try sql_string(arena, try json_path(arena, indexed.path));
        try out.writer.print(", event ->> {s} AS {s}, json_type(event, {s}) AS {s}", .{
            path, indexed.column, path, indexed.type_column,
        });
    }
    return out.written();
}

/// A run's events database, attached to a DuckDB instance under `name` (serve attaches every
/// run's to one instance; a command attaches the one it reads).
pub const Store = struct {
    /// The events directory.
    directory: []const u8,
    /// As SQL names the database: `run_<id>`, or `events`.
    name: []const u8,

    /// Attaches (or creates) the events database of `directory`, its tables made current.
    pub fn attach(
        database: *duckdb.Database,
        arena: std.mem.Allocator,
        directory: []const u8,
        name: []const u8,
        failure: *duckdb.Failure,
    ) !Store {
        const store: Store = .{
            .directory = try arena.dupe(u8, directory),
            .name = try arena.dupe(u8, name),
        };
        const path = try std.fs.path.join(arena, &.{ directory, file_name });
        try database.attach(path, name, failure);
        errdefer database.detach(name, failure) catch {};
        var connection = try store.connect(database, arena, failure);
        defer connection.close();
        try schema_ensure(&connection, arena);
        return store;
    }

    /// A connection whose tables are this store's.
    pub fn connect(
        store: Store,
        database: *duckdb.Database,
        arena: std.mem.Allocator,
        failure: *duckdb.Failure,
    ) !duckdb.Connection {
        var connection = try database.connect(failure);
        errdefer connection.close();
        try connection.exec(try std.fmt.allocPrintSentinel(arena, "USE {s}", .{store.name}, 0));
        return connection;
    }
};

/// An events directory's database for a command (query, events, MCP): attached on its own
/// and brought up to date. Serve holds the databases of its runs: a command reaching one of
/// those is told so (DuckDB locks the file).
pub const Opened = struct {
    database: duckdb.Database,
    connection: duckdb.Connection,
    failure: duckdb.Failure,

    pub fn close(opened: *Opened) void {
        opened.connection.close();
        opened.database.close();
    }
};

pub fn open_for_command(arena: std.mem.Allocator, io: std.Io, directory: []const u8) !*Opened {
    const opened = try arena.create(Opened);
    opened.failure = .{};
    opened.database = duckdb.Database.open(":memory:", .{}, &opened.failure) catch |err| {
        std.debug.print("error: {s}\n", .{opened.failure.text()});
        return err;
    };
    errdefer opened.database.close();
    const failure = &opened.failure;
    const events = Store.attach(&opened.database, arena, directory, "events", failure) catch |err| {
        std.debug.print("error: {s}\n", .{opened.failure.text()});
        if (std.mem.indexOf(u8, opened.failure.text(), "lock") != null) {
            std.debug.print("(a `determinismo serve` holds this run's events: ask it, " ++
                "POST /runs/<id>/query)\n", .{});
        }
        return err;
    };
    opened.connection = try events.connect(&opened.database, arena, &opened.failure);
    errdefer opened.connection.close();
    _ = ingest(&opened.connection, arena, io, directory) catch |err| {
        std.debug.print("error: {s}\n", .{opened.connection.failure.text()});
        return err;
    };
    return opened;
}

fn schema_ensure(connection: *duckdb.Connection, arena: std.mem.Allocator) !void {
    try tables_ensure(connection, arena);
    try connection.exec(views_sql);
}

fn tables_ensure(connection: *duckdb.Connection, arena: std.mem.Allocator) !void {
    const Version = struct { version: u32 };
    const asked = "SELECT version FROM schema_version";
    const known = connection.row(Version, arena, asked, .{}) catch null;
    // Macros live with the database: as of this build, whatever its version.
    try connection.exec(macros_sql);
    if (known) |found| if (found.version == schema_version) return;
    // Version 3 lacks only the timelines' output (the logging property): added in place, and
    // filled from timelines.jsonl by the next ingest (a rebuild would ingest every run's events
    // again, gigabytes).
    if (known) |found| if (found.version == 3) {
        try connection.exec(
            \\ALTER TABLE timelines ADD COLUMN output_bytes UBIGINT;
            \\ALTER TABLE timelines ADD COLUMN output_span_ns UBIGINT;
            \\UPDATE schema_version SET version = 4;
        );
    };
    // Version 4 took a message's first key for its kind: the Go SDK's events and lifecycle
    // (encoding/json sorted a map's keys: {"details":...,"event":...}) were filed as "details",
    // nameless. Refiled in place (no other row changes).
    const refile = if (known) |found| found.version == 3 or found.version == 4 else false;
    if (refile) {
        try connection.exec(
            \\UPDATE events SET kind = json_keys(event)[2],
            \\    name = CASE json_keys(event)[2] WHEN 'event' THEN event ->> '$.event'
            \\        WHEN 'lifecycle' THEN event ->> '$.lifecycle' END,
            \\    node = CASE json_keys(event)[2] WHEN 'event' THEN event ->> '$.details.node' END,
            \\    behavior = CASE json_keys(event)[2] WHEN 'event' THEN event_behavior(event) END
            \\    WHERE kind = 'details' AND len(json_keys(event)) > 1;
            \\UPDATE schema_version SET version = 5;
        );
    }
    // Version 5 lacks the drawn features, version 6 the regimes' bounds (each regime's start,
    // the fault phase's, the longest fault): the tables made, or emptied, and filled in place
    // from the events (filtered by name: a column scan, no per-timeline view).
    if (known) |found| if (found.version >= 3 and found.version <= 6) {
        try connection.exec(
            \\CREATE TABLE IF NOT EXISTS drawn (branch UINTEGER, vtime_ns UBIGINT, feature VARCHAR);
            \\CREATE TABLE IF NOT EXISTS measured (branch UINTEGER, vtime_ns UBIGINT, what VARCHAR, v DOUBLE);
            \\DELETE FROM drawn; DELETE FROM measured;
        );
        try features_fill(connection, arena, "branch IS NOT NULL");
        try connection.exec("UPDATE schema_version SET version = 7");
    };
    // Version 7 lacks at_ns (an assertion judged after the fact says when it happened, its
    // failure's moment): the column added in place. No assertion carried at_ns before it, but
    // the SDK's Elle verdicts said the same in their details (window_ns: when the anomaly formed),
    // so those failed ones take it from there, in place (Citus run 1892's shard move: 158.9 s,
    // its verdict at 739 s).
    if (known) |found| if (found.version >= 3 and found.version <= 7) {
        try connection.exec(
            \\ALTER TABLE events ADD COLUMN IF NOT EXISTS at_ns UBIGINT;
            \\UPDATE events SET at_ns = TRY_CAST(event ->> '$.assert.details.window_ns[0]' AS UBIGINT)
            \\    WHERE kind = 'assert' AND condition = false
            \\    AND json_type(event, '$.assert.details.window_ns') = 'ARRAY';
            \\UPDATE schema_version SET version = 8;
        );
    };
    // Version 8 lacks the timeline a timeline extends (a session's: explore --extend, since
    // 2026-11-14): the column added in place, null for every timeline from before.
    if (known) |found| if (found.version >= 3 and found.version <= 8) {
        try connection.exec(
            \\ALTER TABLE timelines ADD COLUMN IF NOT EXISTS extends UINTEGER;
            \\UPDATE schema_version SET version = 9;
        );
    };
    // Version 12 lacks whether a timeline ran with the run's learned limit as its stop (the
    // learned limit's property, until then the explorer's alone): the column added in place,
    // null for every timeline from before (their runs list no such property, as before).
    if (known) |found| if (found.version >= 3 and found.version <= 12) {
        try connection.exec("ALTER TABLE timelines ADD COLUMN IF NOT EXISTS learned_stop BOOLEAN");
        if (found.version == 12) {
            try connection.exec("UPDATE schema_version SET version = 13");
            return;
        }
    };
    // Version 9 lacks the summaries (what a run's pages read, made as timelines are ingested:
    // summaries_tables_sql): the tables made and filled in place from its events, once, when
    // the database is next opened. 70 s for the largest (flecs's stress run 969: 15 GB, 245
    // million events) and 10 s for Valkey's run 1554 (5.8 GB), each within 6 GB of memory; 2 s
    // for a 30-minute hunt's (srv4, 2026-11-14). Made again from nothing if a fill was cut short
    // (the version is its last statement).
    if (known) |found| if (found.version >= 3 and found.version <= 9) {
        try connection.exec(summaries_drop_sql ++ summaries_tables_sql);
        try connection.exec("DROP TABLE IF EXISTS draws;\n" ++ draws_table_sql);
        try connection.exec(views_sql);
        try summaries_fill(connection, arena, .{ .events = "TRUE", .timelines = "TRUE" }, true);
        try connection.exec("UPDATE schema_version SET version = 13");
        return;
    };
    // Version 10 has the summaries but the faults' (the map's marks of them): made in place
    // from its fault events, asked by name (seconds: no other event is read).
    if (known) |found| if (found.version == 10) {
        try connection.exec("DROP VIEW IF EXISTS timeline_faults; DROP TABLE IF EXISTS faults;\n" ++ faults_table_sql);
        try summaries_fill_of(connection, arena, .{ .events = "TRUE" }, true, "faults");
        try connection.exec("UPDATE schema_version SET version = 11");
    };
    // Version 11 lacks the draws (draws.zig, since 2026-11-15): the table made in place, empty
    // for the timelines before it (nothing noted their draws), filled as later ones arrive.
    if (known) |found| if (found.version >= 10 and found.version <= 11) {
        try connection.exec("DROP VIEW IF EXISTS timeline_draws; DROP TABLE IF EXISTS draws;\n" ++ draws_table_sql);
        try connection.exec("UPDATE schema_version SET version = 13");
        return;
    };
    // Another version (or none): rebuilt, then ingested again from the files.
    try connection.exec(
        \\DROP VIEW IF EXISTS timeline_events;
        \\DROP TABLE IF EXISTS events; DROP TABLE IF EXISTS timelines; DROP TABLE IF EXISTS steps;
        \\DROP TABLE IF EXISTS replays; DROP TABLE IF EXISTS drawn; DROP TABLE IF EXISTS measured;
        \\DROP TABLE IF EXISTS schema_version; DROP TABLE IF EXISTS draws;
    );
    try connection.exec(summaries_drop_sql);
    try connection.exec(schema_sql);
}

/// `categorical`: a JSON value that names a behavior (a string or boolean). `event_behavior`:
/// an event's behavior (`{"event": name, "details": ...}`), its name and categorical details as
/// events.zig's behavior_hash; none for determinismo's own runtime events.
const macros_sql =
    \\CREATE OR REPLACE MACRO categorical(j, path) AS
    \\    CASE WHEN json_type(j, path) IN ('VARCHAR', 'BOOLEAN') THEN j ->> path END;
    \\CREATE OR REPLACE MACRO event_behavior(event) AS
    \\    CASE WHEN json_type(event, '$.event') = 'VARCHAR'
    \\        AND event ->> '$.event' NOT IN ('composer_start', 'composer_done',
    \\            'command_start', 'command_exit', 'faults_phase', 'faults_start',
    \\            'faults_stop', 'fault', 'nodes_up', 'node_start', 'node_ready',
    \\            'node_kill', 'exec_start', 'exec_output', 'exec_done',
    \\            'faults_branch')
    \\    THEN hash('event', event ->> '$.event',
    \\        categorical(event, '$.details.kind'),
    \\        categorical(event, '$.details.flavor'),
    \\        categorical(event, '$.details.mode'),
    \\        categorical(event, '$.details.name'),
    \\        categorical(event, '$.details.node'),
    \\        categorical(event, '$.details.peer'),
    \\        categorical(event, '$.details.state'))
    \\    END;
;

const schema_sql =
    \\CREATE TABLE schema_version AS SELECT 12 AS version;
    \\CREATE TABLE events (
    \\    branch UINTEGER,
    \\    seq UBIGINT NOT NULL,
    \\    vtime_ns UBIGINT NOT NULL,
    \\    branches UBIGINT,
    \\    kind VARCHAR,
    \\    name VARCHAR,
    \\    type VARCHAR,
    \\    condition BOOLEAN,
    \\    node VARCHAR,
    \\    text VARCHAR,
    \\    behavior UBIGINT,
    \\    event JSON NOT NULL,
    \\    path_event VARCHAR, path_event_type VARCHAR,
    \\    path_assert_message VARCHAR, path_assert_message_type VARCHAR,
    \\    path_assert_condition VARCHAR, path_assert_condition_type VARCHAR,
    \\    path_antithesis_assert_message VARCHAR, path_antithesis_assert_message_type VARCHAR,
    \\    path_antithesis_assert_condition VARCHAR, path_antithesis_assert_condition_type VARCHAR,
    \\    path_details_node VARCHAR, path_details_node_type VARCHAR,
    \\    path_details_kind VARCHAR, path_details_kind_type VARCHAR,
    \\    at_ns UBIGINT
    \\);
    \\CREATE TABLE timelines (
    \\    branch UINTEGER PRIMARY KEY,
    \\    seed VARCHAR,
    \\    outcome VARCHAR,
    \\    vtime_ns UBIGINT,
    \\    wall_ns UBIGINT,
    \\    events UBIGINT,
    \\    events_hash VARCHAR,
    \\    generation UINTEGER,
    \\    why VARCHAR,
    \\    parent UINTEGER,
    \\    start_ns UBIGINT,
    \\    path JSON,
    \\    output_bytes UBIGINT,
    \\    output_span_ns UBIGINT,
    \\    extends UINTEGER,
    \\    learned_stop BOOLEAN
    \\);
    \\CREATE TABLE steps (
    \\    branch UINTEGER, step UINTEGER, ancestor UINTEGER, from_ns UBIGINT, to_ns UBIGINT
    \\);
    \\CREATE TABLE replays (
++ replays_columns ++
    \\);
++ features_tables_sql ++ summaries_tables_sql ++ draws_table_sql;

/// `draws`: each timeline's named draws as the explorer answered them (draws.zig: its own part's,
/// branch null the setup's), a row a label: its kind (range or options), its range or options'
/// count, whether it is a configuration (sdk.random_config), how often drawn and overridden, its
/// values counted (labels of 16 values or fewer) and its first ones kept (`kept`: pull, the
/// moment of the event before it, value, overridden). Read through `timeline_draws`.
const draws_table_sql =
    \\CREATE TABLE draws (
    \\    branch UINTEGER, name VARCHAR, kind VARCHAR, count UBIGINT, config BOOLEAN,
    \\    options JSON, drawn UBIGINT, overridden UBIGINT, histogram UBIGINT[], kept JSON);
    \\
;

/// What a run's pages read, small, made once as each timeline is ingested (summaries_fill): its
/// events are never scanned again for them. Each answer was a scan of every event, made again
/// whenever a timeline arrived, so at each load of a run still running: on etcd's 12-hour run
/// 2007 (65 million events, a 12 GB database) the properties took 50 to 80 s, the run's summary
/// 6 to 28 s, the timelines' list up to 95 s, the logged errors 34 to 59 s, the map's marks 97 s
/// and 14 MB (srv4, 2026-11-14).
/// `timeline_properties`: each timeline's verdict on each property it evaluated, its ancestors'
/// part and the setup's included (timeline_events): its evaluations (hits), the true ones, and
/// the first moment it failed (as the property's type fails), was evaluated, was true and was
/// false (a property's examples, when it is opened, are these rows). `property_places`: where each property is
/// evaluated. `timeline_failures`: each timeline's first failing evaluation among its own events
/// (the map's marks: it drew one a timeline of the 68,894 it was sent). `behavior_reach`: the
/// behaviors each timeline's own events reached (branch null: the setup's). `logged`: its
/// error-like output lines by template (logged_sql). `guidance`: the values of each of its
/// guidance and optimize messages. `node_cpu`, `exec_cpu`: its nodes' and their commands' CPU
/// (det-init's events at a timeline's end). `branch_events`: how many events are its own.
/// `faults`: the faults injected in its own events (faults_table_sql).
/// A session's timeline (timelines.extends) has its rows as any: the readers leave it out.
const summaries_tables_sql =
    \\CREATE TABLE timeline_properties (
    \\    timeline UINTEGER, type VARCHAR, message VARCHAR,
    \\    hits UBIGINT, trues UBIGINT, failed_ns UBIGINT, hit_ns UBIGINT,
    \\    true_ns UBIGINT, false_ns UBIGINT);
    \\CREATE TABLE property_places (type VARCHAR, message VARCHAR, place JSON);
    \\CREATE TABLE timeline_failures (
    \\    branch UINTEGER, seq UBIGINT, vtime_ns UBIGINT, type VARCHAR, message VARCHAR);
    \\CREATE TABLE behavior_reach (branch UINTEGER, behavior UBIGINT);
    \\CREATE TABLE logged (
    \\    branch UINTEGER, node VARCHAR, level VARCHAR, template VARCHAR,
    \\    lines UBIGINT, first_vtime_ns UBIGINT, example VARCHAR);
    \\CREATE TABLE guidance (
    \\    branch UINTEGER, message VARCHAR, bucket VARCHAR, value_count UBIGINT, value VARCHAR);
    \\CREATE TABLE node_cpu (branch UINTEGER, node VARCHAR, usage_ms DOUBLE, uptime_ms DOUBLE);
    \\CREATE TABLE exec_cpu (
    \\    branch UINTEGER, node VARCHAR, command VARCHAR,
    \\    cpu_ms DOUBLE, uptime_ms DOUBLE, execs DOUBLE);
    \\CREATE TABLE branch_events (branch UINTEGER, events UBIGINT);
    \\
++ faults_table_sql;

/// `faults`: the faults injected in each timeline's own events, as the map marks them (a
/// timeline's with its ancestors' parts: the view timeline_faults). Asked of the events, the
/// faults of the timelines on screen were the view's join and the JSON of every fault event:
/// 3 to 8 s for 100 timelines of etcd's run 2007 (srv4, 2026-11-15).
const faults_table_sql =
    \\CREATE TABLE faults (
    \\    branch UINTEGER, seq UBIGINT, vtime_ns UBIGINT, kind VARCHAR, flavor VARCHAR,
    \\    node VARCHAR, peer VARCHAR, duration_ns JSON, why VARCHAR, injected JSON);
    \\
;

const summaries_drop_sql =
    \\DROP TABLE IF EXISTS timeline_properties; DROP TABLE IF EXISTS property_places;
    \\DROP TABLE IF EXISTS timeline_failures; DROP TABLE IF EXISTS behavior_reach;
    \\DROP TABLE IF EXISTS logged; DROP TABLE IF EXISTS guidance;
    \\DROP TABLE IF EXISTS node_cpu; DROP TABLE IF EXISTS exec_cpu;
    \\DROP TABLE IF EXISTS branch_events;
    \\DROP VIEW IF EXISTS timeline_faults; DROP TABLE IF EXISTS faults;
    \\
;

/// The timelines a run did not explore itself (a person's sessions): left out of what it found.
const extending_sql = "(SELECT branch FROM timelines WHERE extends IS NOT NULL)";

/// A summary's SQL with a condition in place of `$scope` (not a format: the SQL has braces).
fn scoped(arena: std.mem.Allocator, sql: []const u8, scope: []const u8) ![:0]const u8 {
    return arena.dupeSentinel(u8, try std.mem.replaceOwned(u8, arena, sql, "$scope", scope), 0);
}

/// What summaries_fill covers: `events`, a condition on the events' `branch` (those whose own
/// events are summarized); `timelines`, a condition on `timeline` (those whose verdicts are
/// made, with their ancestors' part: the events of all of them ingested before).
const Summarized = struct { events: ?[]const u8 = null, timelines: ?[]const u8 = null };

/// A summary table's rows of some timelines, from their events.
const Summary = struct { table: []const u8, of: enum { events, timelines }, sql: []const u8 };

const summaries = [_]Summary{
    .{ .table = "timeline_failures", .of = .events, .sql =
    \\INSERT INTO timeline_failures
    \\    SELECT branch, arg_min(seq, (vtime_ns, seq)), min(vtime_ns),
    \\        arg_min(type, (vtime_ns, seq)), arg_min(name, (vtime_ns, seq))
    \\    FROM events
    \\    WHERE ($scope) AND branch IS NOT NULL AND kind IN ('assert', 'antithesis_assert')
    \\        AND ((type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\            OR (type = 'unreachable' AND condition IS NOT NULL))
    \\    GROUP BY branch
    },
    .{ .table = "behavior_reach", .of = .events, .sql =
    \\INSERT INTO behavior_reach
    \\    SELECT DISTINCT branch, behavior FROM events WHERE ($scope) AND behavior IS NOT NULL
    },
    .{ .table = "node_cpu", .of = .events, .sql =
    \\INSERT INTO node_cpu
    \\    SELECT branch, event->'details'->>'node',
    \\        CAST(event->'details'->>'usage_ms' AS DOUBLE), CAST(event->'details'->>'uptime_ms' AS DOUBLE)
    \\    FROM events WHERE ($scope) AND branch IS NOT NULL AND kind = 'event' AND name = 'node_cpu'
    },
    .{ .table = "exec_cpu", .of = .events, .sql =
    \\INSERT INTO exec_cpu
    \\    SELECT branch, event->'details'->>'node', event->'details'->>'command',
    \\        CAST(event->'details'->>'cpu_ms' AS DOUBLE), CAST(event->'details'->>'uptime_ms' AS DOUBLE),
    \\        CAST(event->'details'->>'execs' AS DOUBLE)
    \\    FROM events WHERE ($scope) AND branch IS NOT NULL AND kind = 'event' AND name = 'exec_cpu'
    },
    .{ .table = "branch_events", .of = .events, .sql =
    \\INSERT INTO branch_events SELECT branch, count(*) FROM events WHERE ($scope) GROUP BY branch
    },
    .{ .table = "faults", .of = .events, .sql =
    \\INSERT INTO faults
    \\    SELECT branch, seq, vtime_ns, event ->> '$.details.kind', event ->> '$.details.flavor',
    \\        event ->> '$.details.node', event ->> '$.details.peer', event -> '$.details.duration_ns',
    \\        event ->> '$.details.why', event -> '$.details.injected'
    \\    FROM events WHERE ($scope) AND kind = 'event' AND name = 'fault'
    },
    .{ .table = "logged", .of = .events, .sql = logged_summary_sql },
    .{ .table = "guidance", .of = .events, .sql = guidance_summary_sql },
    // Each timeline's verdicts (properties_sql's): again for a timeline that has some (a run
    // without a timeline has its setup's as timeline 0, until its first one arrives). Through
    // the view, each ancestor's part read for each timeline that has it: judged once a part and
    // added up (2,476 steps of flecs's run 969 are 285 parts) it was no faster, 12 s against 7
    // over that run's 224 million assertions (reading them is the cost) and the same over
    // Valkey's run 1554 (depth 6), 2026-11-14.
    .{ .table = "timeline_properties", .of = .timelines, .sql =
    \\DELETE FROM timeline_properties WHERE $scope;
    \\INSERT INTO timeline_properties
    \\    SELECT timeline, type, name,
    \\        count(condition), count(*) FILTER (WHERE condition),
    \\        -- An assertion judged after the fact says when it happened (at_ns): its moment.
    \\        min(coalesce(at_ns, vtime_ns)) FILTER (WHERE
    \\            (type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\            OR (type = 'unreachable' AND condition IS NOT NULL)),
    \\        min(vtime_ns) FILTER (WHERE condition IS NOT NULL),
    \\        min(vtime_ns) FILTER (WHERE condition), min(vtime_ns) FILTER (WHERE NOT condition)
    \\    FROM timeline_events
    \\    WHERE ($scope) AND kind IN ('assert', 'antithesis_assert')
    \\        AND type IS NOT NULL AND name IS NOT NULL
    \\    GROUP BY ALL
    },
};

/// What the nodes logged as errors (logged_sql's lines and templates), by timeline: of each at
/// most `logged_templates_max`, the panics first, then those of the most lines.
const logged_summary_sql =
    \\INSERT INTO logged
    \\    SELECT * FROM (
    \\        SELECT branch, node,
    \\            CASE WHEN regexp_matches(text, '(?i)panic|fatal|assertion failed|assertion `|AssertionError')
    \\                OR regexp_matches(text, 'is not true$') THEN 'panic' ELSE 'error' END AS level,
    \\            regexp_replace(regexp_replace(substr(text, 1, 300), '[0-9a-fA-F]{8,}|[0-9]+', '#', 'g'),
    \\                '^\[?#[#/:. +TZ-]*\]? *', '') AS template,
    \\            count(*) AS lines, min(vtime_ns), arg_min(substr(text, 1, 2000), vtime_ns)
    \\        FROM events
    \\        WHERE ($scope) AND kind = 'output' AND node IS NOT NULL AND node <> 'kernel' AND text IS NOT NULL
    \\            AND NOT regexp_matches(text, '^\s')
    \\            AND (regexp_matches(text, '(?i)panic|fatal|exception|assertion|\[error\]|level=error|"level":"error"')
    \\                OR regexp_matches(text, '\bERROR\b|\bSEVERE\b|\bCRIT|^E[0-9]{4} |is not true$'))
    \\        GROUP BY ALL)
    \\    QUALIFY row_number() OVER (PARTITION BY branch
    \\        ORDER BY level = 'panic' DESC, lines DESC, node, template) <= 
++ std.fmt.comptimePrint("{d}", .{logged_templates_max});
const logged_templates_max = 500;

/// Each timeline's guidance and optimize messages: how many values each took there, and one.
/// Each kind by itself: a kind asked by equality is found by the scan, and the events of the
/// rest are never read (asked as one of two, every event was: 18 s over flecs's run 969 for no
/// row, 40 s over etcd's run 2007).
const guidance_summary_sql =
    \\INSERT INTO guidance
    \\    SELECT branch, message, bucket, count(DISTINCT value), any_value(value) FROM (
    \\        SELECT branch, event ->> '$.guidance.message' AS message, NULL AS bucket,
    \\            event ->> '$.guidance.distance' AS value
    \\        FROM events WHERE ($scope) AND kind = 'guidance'
    \\        UNION ALL
    \\        SELECT branch, event ->> '$.optimize.message', event ->> '$.optimize.bucket',
    \\            event ->> '$.optimize.value'
    \\        FROM events WHERE ($scope) AND kind = 'optimize')
    \\    GROUP BY ALL
;

/// Where each property not placed yet is evaluated: the location in one of its events. Which
/// properties are new, and a row of each, from the events' narrow columns; then those rows'
/// events alone. Taken in one statement from every assertion's event, it read every event of
/// flecs's stress run 969 (224 million assertions, the 15 GB of its database) for 33 properties,
/// and the whole event of each of run 1468's assertions was 4 GB and out of memory.
fn places_fill(connection: *duckdb.Connection, arena: std.mem.Allocator, events: []const u8) !void {
    const Row = struct { row: u64 };
    const rows = try connection.rows(Row, arena, try scoped(arena,
        \\SELECT min(e.rowid)::UBIGINT AS row FROM events e
        \\WHERE ($scope) AND kind IN ('assert', 'antithesis_assert')
        \\    AND type IS NOT NULL AND name IS NOT NULL
        \\    AND NOT EXISTS (SELECT 1 FROM property_places p
        \\        WHERE p.type = e.type AND p.message = e.name)
        \\GROUP BY type, name
    , events), .{});
    for (rows) |found| {
        try connection.exec(try std.fmt.allocPrintSentinel(arena,
            \\INSERT INTO property_places
            \\    SELECT type, name, CASE kind WHEN 'assert'
            \\        THEN event -> '$.assert.location' ELSE event -> '$.antithesis_assert.location' END
            \\    FROM events WHERE rowid = {d}
        , .{found.row}, 0));
    }
}

/// The summaries of some timelines made (summaries_tables_sql). `said`: each that took a
/// second or more is said (a database of an earlier build brought up to date in place).
fn summaries_fill(connection: *duckdb.Connection, arena: std.mem.Allocator, scope: Summarized, said: bool) !void {
    return summaries_fill_of(connection, arena, scope, said, null);
}

/// `only`: that summary alone (a database of a build that had the others).
fn summaries_fill_of(connection: *duckdb.Connection, arena: std.mem.Allocator, scope: Summarized, said: bool, only: ?[]const u8) !void {
    if (only == null) if (scope.events) |events| {
        const started_s = monotonic_s();
        try places_fill(connection, arena, events);
        const took_s = monotonic_s() - started_s;
        if (said and took_s >= 1) {
            std.debug.print("[determinismo] events database: property_places made in place in {d} s\n", .{took_s});
        }
    };
    for (summaries) |summary| {
        if (only) |table| if (!std.mem.eql(u8, table, summary.table)) continue;
        const condition = switch (summary.of) {
            .events => scope.events,
            .timelines => scope.timelines,
        } orelse continue;
        const started_s = monotonic_s();
        try connection.exec(try scoped(arena, summary.sql, condition));
        const took_s = monotonic_s() - started_s;
        if (said and took_s >= 1) {
            std.debug.print("[determinismo] events database: {s} made in place in {d} s\n", .{ summary.table, took_s });
        }
    }
}

fn monotonic_s() i64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return now.sec;
}

/// What each timeline drew (its swarm's features: docs/PRODUCTS.md, triggers and suppressors),
/// filled at ingest from its own events: `drawn`, a feature's presence (a fault kind kept, a
/// command kept, a load shape or parallelism, the fault durations' shape, a knob's value);
/// `measured`, a drawn length (the driver phase, the gaps between faults) the reader splits at
/// the run's median. A tree timeline's inherited ones are its ancestors' rows within its steps.
/// Small: the panel reads these, not the events (on srv4's largest run that was 27 s and 2.7 GB).
const features_tables_sql =
    \\CREATE TABLE drawn (branch UINTEGER, vtime_ns UBIGINT, feature VARCHAR);
    \\CREATE TABLE measured (branch UINTEGER, vtime_ns UBIGINT, what VARCHAR, v DOUBLE);
    \\
;

/// The features of the events matching `where` (a condition on events' columns) into drawn and
/// measured.
fn features_fill(connection: *duckdb.Connection, arena: std.mem.Allocator, where: []const u8) !void {
    try connection.exec(try std.fmt.allocPrintSentinel(arena,
        \\INSERT INTO drawn
        \\    SELECT branch, vtime_ns, feature FROM (
        \\        SELECT branch, vtime_ns, 'fault ' || split_part(k.entry, ':', 1) AS feature
        \\            FROM events, unnest(string_split(event ->> '$.details.kinds', ' ')) AS k(entry)
        \\            WHERE name = 'fault_swarm' AND k.entry <> '' AND ({s})
        \\        UNION ALL SELECT branch, vtime_ns, 'command ' || (event ->> '$.details.name')
        \\            FROM events WHERE name = 'command_weight' AND ({s})
        \\        UNION ALL SELECT branch, vtime_ns, 'load ' || (event ->> '$.details.shape')
        \\            FROM events WHERE name = 'composer_load' AND ({s})
        \\        UNION ALL SELECT branch, vtime_ns, 'parallelism ' || (event ->> '$.details.parallelism')
        \\            FROM events WHERE name = 'composer_load' AND ({s})
        \\        UNION ALL SELECT branch, vtime_ns, 'fault durations ' || (event ->> '$.details.duration_shape')
        \\            FROM events WHERE name = 'fault_regime' AND ({s})
        \\        UNION ALL SELECT branch, vtime_ns, (event ->> '$.details.knob') || ' = ' ||
        \\                coalesce(event ->> '$.details.env', event ->> '$.details.statement')
        \\            FROM events WHERE name IN ('node_knob', 'cluster_setting_drawn') AND ({s}))
        \\    WHERE feature IS NOT NULL;
        \\INSERT INTO measured
        \\    SELECT branch, vtime_ns, 'driver phase', (event ->> '$.details.ms')::DOUBLE
        \\        FROM events WHERE name = 'drive_drawn' AND ({s})
        \\    UNION ALL SELECT branch, vtime_ns, 'gaps between faults', (event ->> '$.details.gap_mean_ms')::DOUBLE
        \\        FROM events WHERE name = 'fault_regime' AND ({s})
        \\    UNION ALL SELECT branch, vtime_ns, 'longest fault', (event ->> '$.details.duration_max_ms')::DOUBLE
        \\        FROM events WHERE name = 'fault_regime' AND ({s})
        \\    UNION ALL SELECT branch, vtime_ns, 'regime', 1
        \\        FROM events WHERE name = 'fault_regime' AND ({s})
        \\    UNION ALL SELECT branch, vtime_ns, 'faults', CASE event ->> '$.details.state' WHEN 'start' THEN 1 ELSE 0 END
        \\        FROM events WHERE name = 'faults_phase' AND ({s});
    , .{ where, where, where, where, where, where, where, where, where, where, where }, 0));
}

/// Each timeline's events (queries search it), as of this build whatever the database's version
/// (made on every open, as the macros): a run without a timeline (its setup failed, or setup
/// mode) shows its setup's events as timeline 0, which the setup's pairing with each timeline
/// gave none of (setup mode's run 905: 35 events, no search found one).
const views_sql =
    \\CREATE OR REPLACE VIEW timeline_events AS
    \\    SELECT t.branch AS timeline, NULL::UINTEGER AS origin, e.* EXCLUDE (branch)
    \\        FROM timelines t, events e WHERE e.branch IS NULL
    \\    UNION ALL
    \\    SELECT 0::UINTEGER AS timeline, NULL::UINTEGER AS origin, e.* EXCLUDE (branch)
    \\        FROM events e WHERE e.branch IS NULL AND NOT EXISTS (SELECT 1 FROM timelines)
    \\    UNION ALL
    \\    SELECT s.branch AS timeline, e.branch AS origin, e.* EXCLUDE (branch)
    \\        FROM steps s JOIN events e
    \\        ON e.branch = s.ancestor AND e.vtime_ns >= s.from_ns AND e.vtime_ns <= s.to_ns
    \\    UNION ALL
    \\    SELECT e.branch AS timeline, e.branch AS origin, e.* EXCLUDE (branch)
    \\        FROM events e WHERE e.branch IS NOT NULL;
    \\-- What the run explored: its timelines but those that extend one (a person's sessions,
    \\-- timelines.extends), their events too. What a run found is judged over these (its
    \\-- properties, findings, statistics, logged errors): a crash someone caused at a REPL is in
    \\-- its own timeline's events, the map and the queries, never among the run's findings.
    \\CREATE OR REPLACE VIEW explored AS SELECT * FROM timelines WHERE extends IS NULL;
    \\CREATE OR REPLACE VIEW explored_events AS
    \\    SELECT * FROM events WHERE branch IS NULL
    \\        OR branch NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL);
    \\CREATE OR REPLACE VIEW explored_timeline_events AS
    \\    SELECT * FROM timeline_events
    \\    WHERE timeline NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL);
    \\-- Each timeline's faults, as timeline_events has its events: the setup's, its ancestors'
    \\-- parts and its own (the map's marks: faults_table_sql).
    \\CREATE OR REPLACE VIEW timeline_faults AS
    \\    SELECT t.branch AS timeline, f.* EXCLUDE (branch) FROM timelines t, faults f WHERE f.branch IS NULL
    \\    UNION ALL
    \\    SELECT s.branch AS timeline, f.* EXCLUDE (branch)
    \\        FROM steps s JOIN faults f
    \\        ON f.branch = s.ancestor AND f.vtime_ns >= s.from_ns AND f.vtime_ns <= s.to_ns
    \\    UNION ALL
    \\    SELECT f.branch AS timeline, f.* EXCLUDE (branch) FROM faults f WHERE f.branch IS NOT NULL;
    \\-- Each draw kept (draws' `kept`), a row a value: its timeline's part, its label, its value,
    \\-- and what it drew as one says it (`drew`): an option's name (a decision among a varying
    \\-- subset, sdk.decide's "fault": an index means another option in another subset), else the
    \\-- number.
    \\CREATE OR REPLACE VIEW draw_values AS
    \\    SELECT branch, name, kind, count, config, options, pull, after_ns, value, overridden,
    \\        CASE WHEN kind = 'options' THEN json_extract_string(options, '$[' || value || ']')
    \\            ELSE value::VARCHAR END AS drew
    \\    FROM (SELECT d.branch, d.name, d.kind, d.count, d.config, d.options,
    \\        (v ->> 'pull')::UBIGINT AS pull, (v ->> 'after_ns')::UBIGINT AS after_ns,
    \\        (v ->> 'value')::UBIGINT AS value, (v ->> 'overridden')::BOOLEAN AS overridden
    \\        FROM draws d, unnest(CAST(d.kept AS JSON[])) AS u(v));
    \\-- Each timeline's draws, as timeline_events has its events: the setup's, its ancestors'
    \\-- parts (a draw after the last event before the moment it left them) and its own.
    \\CREATE OR REPLACE VIEW timeline_draws AS
    \\    SELECT t.branch AS timeline, 'setup' AS part, v.* EXCLUDE (branch)
    \\        FROM timelines t, draw_values v WHERE v.branch IS NULL
    \\    UNION ALL
    \\    SELECT s.branch AS timeline, 'ancestor' AS part, v.* EXCLUDE (branch)
    \\        FROM steps s JOIN draw_values v
    \\        ON v.branch = s.ancestor AND v.after_ns >= s.from_ns AND v.after_ns < s.to_ns
    \\    UNION ALL
    \\    SELECT v.branch AS timeline, 'own' AS part, v.* EXCLUDE (branch)
    \\        FROM draw_values v WHERE v.branch IS NOT NULL;
;

/// Events read from their files, with their typed columns: `files` is a SQL list of paths.
/// What a behavior is (discovery): an assertion with its outcome; an event with its categorical
/// details (strings and booleans of kind, flavor, mode, name, node, peer, state), not the
/// runtime's own (commands, faults, lifecycle).
/// An assertion judged after the fact: when it happened (the SDK's at_ns), in vtime: the guest's
/// monotonic at_ns moved by the event's own vtime less its monotonic now (now_ns), the clock ~0.1 s
/// behind vtime (it starts with the guest kernel's timekeeping). A now_ns past the event's vtime
/// is no guest's clock: a check the explorer ran on the host wrote its host's (DuckDB's hunt run
/// 1983: srv4's 48,000 s against 183 s, the subtraction overflowing and every query of the run
/// failing), and the at_ns, the guest's from the history, is taken as it is.
const at_ns_sql =
    \\        CASE WHEN TRY_CAST(assertion ->> '$.now_ns' AS UBIGINT) <= vtime_ns
    \\            THEN vtime_ns - (TRY_CAST(assertion ->> '$.now_ns' AS UBIGINT)
    \\                - least(TRY_CAST(assertion ->> '$.at_ns' AS UBIGINT), TRY_CAST(assertion ->> '$.now_ns' AS UBIGINT)))
    \\            ELSE TRY_CAST(assertion ->> '$.at_ns' AS UBIGINT) END
;

fn events_select(
    arena: std.mem.Allocator,
    files: []const u8,
    branch_sql: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena,
        \\WITH lines AS (
        \\    SELECT {s} AS branch, seq, vtime_ns, branches, event,
        \\        -- Its first key but "details", the kind's sibling in any order (Go's
        \\        -- encoding/json sorted them: "details" first, then "event").
        \\        CASE WHEN json_keys(event)[1] = 'details' AND len(json_keys(event)) > 1
        \\            THEN json_keys(event)[2] ELSE json_keys(event)[1] END AS kind
        \\    FROM read_json({s}, format = 'newline_delimited', filename = true,
        \\        columns = {{
        \\            seq: 'UBIGINT', vtime_ns: 'UBIGINT', branches: 'UBIGINT', event: 'JSON'
        \\        }})
        \\    WHERE seq IS NOT NULL
        \\), typed AS (
        \\    SELECT *,
        \\        CASE kind WHEN 'assert' THEN event -> '$.assert'
        \\            WHEN 'antithesis_assert' THEN event -> '$.antithesis_assert' END AS assertion
        \\    FROM lines
        \\), columns AS (
        \\    SELECT branch, seq, vtime_ns, branches, kind,
        \\        CASE kind
        \\            WHEN 'assert' THEN assertion ->> '$.message'
        \\            WHEN 'antithesis_assert' THEN assertion ->> '$.message'
        \\            WHEN 'guidance' THEN event ->> '$.guidance.message'
        \\            WHEN 'event' THEN event ->> '$.event'
        \\            WHEN 'lifecycle' THEN event ->> '$.lifecycle'
        \\            WHEN 'decision' THEN event ->> '$.decision.name'
        \\            WHEN 'output' THEN event ->> '$.output.stream'
        \\        END AS name,
        \\        CASE kind
        \\            WHEN 'assert' THEN assertion ->> '$.type'
        \\            WHEN 'antithesis_assert' THEN CASE assertion ->> '$.display_type'
        \\                WHEN 'Always' THEN 'always'
        \\                WHEN 'AlwaysOrUnreachable' THEN 'always_or_unreachable'
        \\                WHEN 'Sometimes' THEN 'sometimes' WHEN 'Reachable' THEN 'reachable'
        \\                WHEN 'Unreachable' THEN 'unreachable' END
        \\        END AS type,
        \\        CASE WHEN assertion IS NULL THEN NULL
        \\            WHEN json_type(assertion, '$.hit') = 'BOOLEAN'
        \\                AND NOT (assertion ->> '$.hit')::BOOLEAN THEN NULL
        \\            WHEN json_type(assertion, '$.condition') IS NULL THEN true
        \\            WHEN json_type(assertion, '$.condition') = 'BOOLEAN'
        \\                THEN (assertion ->> '$.condition')::BOOLEAN
        \\        END AS condition,
        \\        CASE kind
        \\            WHEN 'event' THEN event ->> '$.details.node'
        \\            WHEN 'output' THEN event ->> '$.output.source'
        \\        END AS node,
        \\        CASE kind
        \\            WHEN 'output' THEN event ->> '$.output.text'
        \\            WHEN 'raw' THEN event ->> '$.raw'
        \\        END AS text,
        \\        CASE
        \\            WHEN kind = 'assert' THEN hash('assert',
        \\                categorical(assertion, '$.type'), categorical(assertion, '$.message'),
        \\                categorical(assertion, '$.condition'))
        \\            -- An Antithesis SDK's evaluation (not a declaration), as events.zig counts it.
        \\            WHEN kind = 'antithesis_assert'
        \\                AND coalesce(TRY_CAST(assertion ->> '$.hit' AS BOOLEAN), true) THEN hash('antithesis_assert',
        \\                categorical(assertion, '$.display_type'), categorical(assertion, '$.message'),
        \\                categorical(assertion, '$.condition'))
        \\            WHEN kind = 'event' THEN event_behavior(event)
        \\        END AS behavior,
        \\        event{s},
    ++ "\n" ++ at_ns_sql ++ " AS at_ns\n" ++
        \\    FROM typed
        \\)
        \\SELECT * FROM columns
    , .{ branch_sql, files, try indexed_select(arena) }, 0);
}

/// Brings in the timelines that finished since the last ingest (and the setup's events with the
/// first): how many.
/// A run's setup events (setup.jsonl, fork.jsonl), when it ended without a timeline (its setup
/// failed) and nothing was ingested: ingest takes them with its first timelines only.
pub fn setup_ingest(connection: *duckdb.Connection, arena: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    const Count = struct { count: u64 };
    const known = (try connection.row(Count, arena, "SELECT count(*) FROM events", .{})).?;
    if (known.count > 0) return;
    var shared: std.Io.Writer.Allocating = .init(arena);
    var shared_count: usize = 0;
    for ([_][]const u8{ "setup.jsonl", "fork.jsonl" }) |name| {
        const path = try std.fs.path.join(arena, &.{ directory, name });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        try shared.writer.print("{s}{s}", .{ if (shared_count == 0) "" else ",", try sql_string(arena, path) });
        shared_count += 1;
    }
    if (shared_count == 0) return;
    const list = try std.fmt.allocPrint(arena, "[{s}]", .{shared.written()});
    const select = try events_select(arena, list, "NULL::UINTEGER");
    try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO events {s}", .{select}, 0));
    // Its summaries: the setup's own, and its verdicts as timeline 0's (timeline_events).
    try summaries_fill(connection, arena, .{ .events = "branch IS NULL", .timelines = "timeline = 0" }, false);
}

pub fn ingest(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
) !u32 {
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    std.Io.Dir.cwd().access(io, timelines_path, .{}) catch return 0; // No timeline finished yet.
    const timelines = try sql_string(arena, timelines_path);
    const timelines_read = try std.fmt.allocPrint(arena,
        \\read_json({s}, format = 'newline_delimited', columns = {{
        \\    "index": 'UINTEGER', seed: 'VARCHAR', outcome: 'VARCHAR', vtime_ns: 'UBIGINT',
        \\    wall_ns: 'UBIGINT', events: 'UBIGINT', events_hash: 'VARCHAR', generation: 'UINTEGER',
        \\    why: 'VARCHAR', path: 'STRUCT(branch UINTEGER, seed UBIGINT, vtime_ns UBIGINT)[]',
        \\    output_bytes: 'UBIGINT', output_span_ns: 'UBIGINT',
        \\    extends: 'STRUCT(branch UINTEGER, vtime_ns UBIGINT)', learned_stop: 'BOOLEAN'}})
    , .{timelines});
    // Timelines ingested under schema 3 lack their output (the logging property's): taken from
    // the file, once, so runs from before the property show it too.
    const Missing = struct { count: u64 };
    const missing_sql = "SELECT count(*) FROM timelines WHERE output_span_ns IS NULL";
    const missing = (try connection.row(Missing, arena, missing_sql, .{})).?;
    if (missing.count > 0) try connection.exec(try std.fmt.allocPrintSentinel(arena,
        \\UPDATE timelines SET output_bytes = given.output_bytes,
        \\    output_span_ns = given.output_span_ns
        \\FROM (SELECT "index", any_value(output_bytes) AS output_bytes,
        \\          any_value(output_span_ns) AS output_span_ns
        \\      FROM {s} WHERE output_span_ns IS NOT NULL GROUP BY "index") AS given
        \\WHERE timelines.branch = given."index" AND timelines.output_span_ns IS NULL
    , .{timelines_read}, 0));
    const arrived = try connection.rows(Arrived, arena, try std.fmt.allocPrintSentinel(arena,
        \\SELECT DISTINCT "index" FROM {s}
        \\WHERE "index" NOT IN (SELECT branch FROM timelines) ORDER BY 1
    , .{timelines_read}, 0), .{});
    if (arrived.len == 0) return 0;
    // In transactions of at most ingest_batch_bytes of event files: one of hundreds of
    // timelines at once (a run's every one, after its ingests failed) holds them all in its
    // transaction (RedisRaft's hunt run 1049: 3.7 GB, DuckDB out of memory at every try).
    // An ended timeline's events are compressed (event_files.zig), and DuckDB's read_json reads
    // no zstd here: each batch's plain copies in a directory of their own, removed after it.
    const copies = try std.fs.path.join(arena, &.{ directory, ingest_copies_name });
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, copies) catch {};
    try cwd.createDirPath(io, copies);
    defer cwd.deleteTree(io, copies) catch {};
    var at: usize = 0;
    while (at < arrived.len) {
        var batch_bytes: u64 = 0;
        var batch_end = at;
        while (batch_end < arrived.len) {
            const size = try ingest_copy(arena, io, directory, copies, arrived[batch_end].index);
            batch_bytes += size;
            batch_end += 1;
            if (batch_bytes >= ingest_batch_bytes) break;
        }
        try ingest_batch(connection, arena, io, directory, copies, timelines_read, arrived[at..batch_end]);
        for (arrived[at..batch_end]) |timeline| {
            const name = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ copies, timeline.index });
            cwd.deleteFile(io, name) catch {};
        }
        at = batch_end;
    }
    return @intCast(arrived.len);
}

/// Where ingest decompresses a batch's events, in the run's events directory.
const ingest_copies_name = ".ingest";

/// An ended timeline's events decompressed into `copies` (`branch-<n>.jsonl`): their size, 0
/// for a timeline that wrote none. Its events still plain: compression never ran on them, a
/// timeline that ended as no ended one does (error.EventsNotCompressed, never ingested as is).
fn ingest_copy(arena: std.mem.Allocator, io: std.Io, directory: []const u8, copies: []const u8, index: u32) !u64 {
    const copy = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ copies, index });
    var buffer: [4096]u8 = undefined;
    if (!event_files.ended(io, directory, index)) {
        const running = try event_files.path(&buffer, directory, index, .running);
        if (std.Io.Dir.cwd().access(io, running, .{})) |_| return error.EventsNotCompressed else |_| return 0;
    }
    try event_files.decompress_to(io, try event_files.path(&buffer, directory, index, .ended), copy);
    return (try std.Io.Dir.cwd().statFile(io, copy, .{})).size;
}

/// Event files ingested in one transaction at most (but one timeline's whole, however large):
/// their rows held in the transaction take several times their JSON (512 MiB of run 1049's held
/// 2.7 GB of serve's 4 GiB).
const ingest_batch_bytes: u64 = 64 << 20;

/// A timeline finished and not ingested yet.
const Arrived = struct { index: u32 };

/// Timelines that arrived, in one transaction: their events (and the shared prefix's, the
/// first time), their steps and their rows.
fn ingest_batch(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    copies: []const u8,
    timelines_read: []const u8,
    arrived: []const Arrived,
) !void {
    var files: std.Io.Writer.Allocating = .init(arena);
    var indices: std.Io.Writer.Allocating = .init(arena);
    var count: usize = 0;
    for (arrived, 0..) |timeline, at| {
        try indices.writer.print("{s}{d}", .{ if (at == 0) "" else ",", timeline.index });
        const name = try std.fmt.allocPrint(arena, "branch-{d}.jsonl", .{timeline.index});
        const path = try std.fs.path.join(arena, &.{ copies, name });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue; // A timeline that wrote no events.
        const quoted = try sql_string(arena, path);
        try files.writer.print("{s}{s}", .{ if (count == 0) "" else ",", quoted });
        count += 1;
    }

    try connection.exec("BEGIN TRANSACTION");
    errdefer connection.exec("ROLLBACK") catch {};
    const Count = struct { count: u64 };
    const prefix_sql = "SELECT count(*) FROM events WHERE branch IS NULL";
    const prefix = (try connection.row(Count, arena, prefix_sql, .{})).?;
    const known_sql = "SELECT count(*) FROM timelines";
    const timelines_known = (try connection.row(Count, arena, known_sql, .{})).?;
    if (prefix.count == 0 and timelines_known.count == 0) {
        var shared: std.Io.Writer.Allocating = .init(arena);
        var shared_count: usize = 0;
        for ([_][]const u8{ "setup.jsonl", "fork.jsonl" }) |name| {
            const path = try std.fs.path.join(arena, &.{ directory, name });
            std.Io.Dir.cwd().access(io, path, .{}) catch continue;
            const quoted = try sql_string(arena, path);
            try shared.writer.print("{s}{s}", .{ if (shared_count == 0) "" else ",", quoted });
            shared_count += 1;
        }
        if (shared_count > 0) {
            const list = try std.fmt.allocPrint(arena, "[{s}]", .{shared.written()});
            const select = try events_select(arena, list, "NULL::UINTEGER");
            try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO events {s}", .{
                select,
            }, 0));
            try summaries_fill(connection, arena, .{ .events = "branch IS NULL" }, false);
        }
        try draws_insert(connection, arena, io, &.{try std.fs.path.join(arena, &.{ directory, "draws-setup.jsonl" })});
    }
    // The run's first timelines: a setup shown as timeline 0 until now (setup_ingest) is theirs.
    if (timelines_known.count == 0) try connection.exec("DELETE FROM timeline_properties");
    if (count > 0) {
        const branch = "regexp_extract(filename, 'branch-([0-9]+)\\.jsonl$', 1)::UINTEGER";
        const list = try std.fmt.allocPrint(arena, "[{s}]", .{files.written()});
        const select = try events_select(arena, list, branch);
        try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO events {s}", .{
            select,
        }, 0));
        try features_fill(connection, arena, try std.fmt.allocPrint(arena, "branch IN ({s})", .{indices.written()}));
    }
    const draws_paths = try arena.alloc([]const u8, arrived.len);
    for (arrived, draws_paths) |timeline, *path| {
        path.* = try std.fmt.allocPrint(arena, "{s}/draws-{d}.jsonl", .{ directory, timeline.index });
    }
    try draws_insert(connection, arena, io, draws_paths);
    try connection.exec(try std.fmt.allocPrintSentinel(arena,
        \\INSERT INTO steps
        \\    SELECT "index", step, (step_path).branch,
        \\        coalesce(lag((step_path).vtime_ns) OVER (PARTITION BY "index" ORDER BY step), 0),
        \\        (step_path).vtime_ns
        \\    FROM (SELECT "index", unnest(path) AS step_path, generate_subscripts(path, 1) AS step
        \\          FROM {s} WHERE "index" IN ({s}));
        \\INSERT INTO timelines
        \\    SELECT "index", any_value(seed), any_value(outcome), any_value(vtime_ns),
        \\        any_value(wall_ns),
        \\        any_value(events), any_value(events_hash), any_value(generation), any_value(why),
        \\        any_value(path[-1].branch), coalesce(any_value(path[-1].vtime_ns), 0),
        \\        any_value(path)::JSON, any_value(output_bytes), any_value(output_span_ns),
        \\        any_value(extends.branch), any_value(learned_stop)
        \\    FROM {s} WHERE "index" IN ({s}) GROUP BY "index";
    , .{ timelines_read, indices.written(), timelines_read, indices.written() }, 0));
    // What the run's pages read of these timelines, made once here (summaries_tables_sql): after
    // their steps and rows, which their verdicts go through (timeline_events).
    try summaries_fill(connection, arena, .{
        .events = try std.fmt.allocPrint(arena, "branch IN ({s})", .{indices.written()}),
        .timelines = try std.fmt.allocPrint(arena, "timeline IN ({s})", .{indices.written()}),
    }, false);
    try connection.exec("COMMIT");
}

/// Draws files (draws.zig: `draws-<n>.jsonl`, the setup's `draws-setup.jsonl`) into `draws`,
/// those that exist with a line: a timeline from before them, or that drew nothing, has none.
fn draws_insert(connection: *duckdb.Connection, arena: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
    var list: std.Io.Writer.Allocating = .init(arena);
    var count: usize = 0;
    for (paths) |path| {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        if (stat.size == 0) continue;
        try list.writer.print("{s}{s}", .{ if (count == 0) "" else ",", try sql_string(arena, path) });
        count += 1;
    }
    if (count == 0) return;
    try connection.exec(try std.fmt.allocPrintSentinel(arena,
        \\INSERT INTO draws SELECT
        \\    TRY_CAST(NULLIF(regexp_extract(filename, 'draws-([0-9]+)\.jsonl$', 1), '') AS UINTEGER),
        \\    name, kind, count, config, options, drawn, overridden, histogram, kept
        \\FROM read_json([{s}], format = 'newline_delimited', filename = true, columns = {{
        \\    name: 'VARCHAR', kind: 'VARCHAR', count: 'UBIGINT', config: 'BOOLEAN',
        \\    options: 'JSON', drawn: 'UBIGINT', overridden: 'UBIGINT', histogram: 'UBIGINT[]',
        \\    kept: 'JSON'}})
        \\WHERE name IS NOT NULL
    , .{list.written()}, 0));
}

/// The replays table's columns: `same` when the guest's history replayed (a rejudged replay too:
/// the host checks' verdicts alone differ, `rejudged`).
const replays_columns =
    \\    timeline UINTEGER PRIMARY KEY, same BOOLEAN, rejudged BOOLEAN, recorded VARCHAR,
    \\    replayed VARCHAR, why VARCHAR
    \\
;

/// The run's replays (replays.zig's results: "<timeline> same <hash>" or "<timeline> different
/// <recorded> <replayed> <why>" lines), all of them again: there are at most replays_max. One
/// killed or that could not run ("<timeline> killed|failed ...") is no replay, as replays.zig
/// counts them: read as one that parted, it failed the run's determinism property (run 381's
/// five, refused by a deploy that changed the guest under them).
pub fn replays_ingest(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return;
    var values: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |result| {
        var words = std.mem.tokenizeScalar(u8, result, ' ');
        const timeline = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        const verdict = words.next() orelse continue;
        if (std.mem.eql(u8, verdict, "killed") or std.mem.eql(u8, verdict, "failed")) continue;
        const exact = std.mem.eql(u8, verdict, "same");
        const rejudged = std.mem.eql(u8, verdict, "rejudged");
        const recorded = words.next() orelse "";
        const replayed = if (exact) recorded else words.next() orelse "";
        const why = std.mem.trim(u8, words.rest(), " ");
        try values.writer.print("{s}({d}, {}, {}, {s}, {s}, {s})", .{
            if (values.written().len == 0) "" else ",",
            timeline,
            exact or rejudged,
            rejudged,
            try sql_string(arena, recorded),
            try sql_string(arena, replayed),
            try sql_string(arena, why),
        });
    }
    try connection.exec("BEGIN TRANSACTION");
    errdefer connection.exec("ROLLBACK") catch {};
    // Made anew, its columns this build's (a run's database made before `rejudged`).
    try connection.exec("CREATE OR REPLACE TABLE replays (" ++ replays_columns ++ ")");
    if (values.written().len > 0) {
        try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO replays VALUES {s}", .{
            values.written(),
        }, 0));
    }
    try connection.exec("COMMIT");
}

/// A string as a SQL literal.
fn sql_string(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try out.writer.writeByte('\'');
        try out.writer.writeByte(byte);
    }
    try out.writer.writeByte('\'');
    return out.written();
}

/// Each property (an assertion, by its type and message) across the timelines, with its
/// verdict, as Antithesis judges it (report.property_failing): an `always` fails where a
/// timeline made it false, `always_or_unreachable` and `unreachable` where a timeline violated
/// them, a `sometimes` that no timeline made true; one that must be reached and was not
/// (`always`, `sometimes`, `reachable`) is "unreached" (judged across scenarios).
/// Each guidance message (and optimize bucket) of a run, `stuck` when its value is the same in
/// each of 8 timelines or more that reported it, and not 0 (an assertion already met).
const guidance_stuck_sql =
    \\    SELECT message,
    \\        count(DISTINCT branch) >= 8
    \\        -- One value over the run: one in each timeline, the same in all (guidance_summary_sql).
    \\        AND count(DISTINCT value) = 1 AND max(value_count) = 1
    \\        AND any_value(value) NOT IN ('0', '0.0', '-0')
    \\        AS stuck
    \\    FROM guidance WHERE branch IS NULL OR branch NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL)
    \\    GROUP BY message, bucket
    \\
;

/// The learned limit's property, as the explorer names it (report.learned_limit_property: a test
/// in main.zig holds the two the same), and as a SQL string's text.
pub const learned_limit_property = "timelines end within the run's learned limit (twice its normal ends' 99th percentile past a branch point)";
const learned_limit_property_sql = sql_text(learned_limit_property);

/// `text` inside a SQL string literal: each single quote doubled.
fn sql_text(comptime text: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (text) |c| out = out ++ (if (c == '\'') "''" else &[_]u8{c});
        return out;
    }
}

pub const properties_sql =
    \\WITH RECURSIVE per AS (
    \\    -- Each timeline's verdicts, made once at its ingest (summaries_fill), never from its
    \\    -- events here; a session's timeline is not the run's.
    \\    SELECT timeline, type, message, hits, trues, failed_ns, hit_ns FROM timeline_properties
    \\    WHERE timeline NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL)
    \\), judged AS (
    \\    SELECT type, message,
    \\        count(*) FILTER (WHERE hits > 0) AS timelines_hit,
    \\        count(*) FILTER (WHERE trues > 0) AS timelines_true,
    \\        count(*) FILTER (WHERE failed_ns IS NOT NULL) AS timelines_failing,
    \\        min(timeline) FILTER (WHERE failed_ns IS NOT NULL) AS first_failing_timeline,
    \\        arg_min(failed_ns, timeline) FILTER (WHERE failed_ns IS NOT NULL) AS first_failure_ns,
    \\        min(timeline) FILTER (WHERE hits > 0) AS first_hit_timeline,
    \\        sum(hits) AS hits, sum(trues) AS trues
    \\    FROM per GROUP BY ALL
    \\), places AS (
    \\    -- Where each property is evaluated: one location a property (summaries_fill).
    \\    SELECT type, message, any_value(place) AS place FROM property_places GROUP BY ALL
    \\), failing_timelines AS (
    \\    SELECT DISTINCT type, message, timeline FROM per WHERE failed_ns IS NOT NULL
    \\), ancestry(timeline, ancestor) AS (
    \\    -- A tree's timeline and every timeline it branched from.
    \\    SELECT branch, parent FROM timelines WHERE parent IS NOT NULL
    \\    UNION ALL
    \\    SELECT a.timeline, t.parent FROM ancestry a JOIN timelines t ON t.branch = a.ancestor
    \\    WHERE t.parent IS NOT NULL
    \\), independent AS (
    \\    -- Antithesis's findability: a failure counted once a subtree, where no timeline it
    \\    -- branched from failed the property too (siblings' failures are not independent).
    \\    SELECT type, message, count(*) AS finds FROM failing_timelines f
    \\    WHERE NOT EXISTS (SELECT 1 FROM ancestry a JOIN failing_timelines g
    \\        ON g.timeline = a.ancestor AND g.type = f.type AND g.message = f.message
    \\        WHERE a.timeline = f.timeline)
    \\    GROUP BY ALL
    \\), cpu AS (
    \\    SELECT sum(wall_ns) AS cpu_ns FROM explored
    \\), listed AS (
    \\SELECT type, message,
    \\    CASE
    \\        WHEN timelines_failing > 0 THEN 'failing'
    \\        WHEN type IN ('always', 'sometimes', 'reachable') AND timelines_hit = 0
    \\            THEN 'unreached'
    \\        WHEN type = 'sometimes' AND timelines_true = 0 THEN 'failing'
    \\        ELSE 'passing'
    \\    END AS status,
    \\    timelines_hit, timelines_true, timelines_failing, first_failing_timeline,
    \\    first_failure_ns,
    \\    first_hit_timeline, hits, trues,
    \\    regexp_extract(coalesce(place ->> '$.file', place ->> '$.file_name'), '[^/]*$') || ':'
    \\        || coalesce(place ->> '$.line', place ->> '$.begin_line', '0')
    \\        || coalesce(' ' || coalesce(place ->> '$.function', place ->> '$.function_name'), '')
    \\        AS location,
    \\    finds AS independent_finds,
    \\    -- Mean CPU time to find it: the timelines' time over its independent finds.
    \\    (SELECT cpu_ns FROM cpu) // finds AS mean_cpu_ns_to_find,
    \\    -- Its finds per CPU-hour, a 95% interval (Poisson, Breslow and Day's approximation;
    \\    -- none found: the upper bound alone, about 3.7 over the run's CPU time).
    \\    CASE WHEN finds > 0 THEN finds * pow(1 - 1 / (9.0 * finds) - 1.96 / (3 * sqrt(finds)), 3)
    \\        ELSE 0 END * 3.6e12 / (SELECT cpu_ns FROM cpu) AS finds_per_cpu_hour_low,
    \\    (coalesce(finds, 0) + 1) * pow(1 - 1 / (9.0 * (coalesce(finds, 0) + 1))
    \\        + 1.96 / (3 * sqrt(coalesce(finds, 0) + 1)), 3) * 3.6e12 / (SELECT cpu_ns FROM cpu)
    \\        AS finds_per_cpu_hour_high
    \\FROM judged LEFT JOIN independent USING (type, message) LEFT JOIN places USING (type, message)
    \\UNION ALL
    \\-- The run's timelines replayed as it ran (replays.zig): determinismo's own property.
    \\SELECT 'always', 'timelines replay to their recorded history', -- report.replays_property
    \\    CASE WHEN bool_and(same) THEN 'passing' ELSE 'failing' END,
    \\    count(*), count(*) FILTER (WHERE same), count(*) FILTER (WHERE NOT same),
    \\    min(timeline) FILTER (WHERE NOT same), NULL, min(timeline), count(*),
    \\    count(*) FILTER (WHERE same), 'replays.zig', NULL, NULL, NULL, NULL
    \\FROM replays HAVING count(*) > 0
    \\UNION ALL
    \\-- Logging volume over all the timelines (report.logging_judge: 200 MB an hour of virtual
    \\-- time, a run's property that no timeline fails alone).
    \\SELECT 'always', 'logging output stays under 200 MB per hour of virtual time',
    \\    CASE WHEN sum(output_bytes) * 3600000000000 >= 200000000 * sum(output_span_ns)
    \\        AND sum(output_span_ns) >= 1000000000 THEN 'failing' ELSE 'passing' END,
    \\    count(*), count(*), 0, NULL, NULL, min(branch), count(*), count(*), 'report.zig', NULL, NULL,
    \\    NULL, NULL
    \\FROM explored HAVING count(output_span_ns) > 0
    \\UNION ALL
    \\-- The run's learned timeline limit (timeline_limit.zig, report.learned_limit_judge): of the
    \\-- timelines that ran with it as their stop, those cut there (moment_reached) fail it, the
    \\-- cut's moment the failure's. Until 2026-11-24 the explorer's report alone said it (run
    \\-- 2165's 138 cuts, absent from its properties here).
    \\SELECT 'always', '
++ learned_limit_property_sql ++
    \\',
    \\    CASE WHEN count(*) FILTER (WHERE outcome = 'moment_reached') > 0 THEN 'failing'
    \\        ELSE 'passing' END,
    \\    count(*), count(*) FILTER (WHERE outcome <> 'moment_reached'),
    \\    count(*) FILTER (WHERE outcome = 'moment_reached'),
    \\    min(branch) FILTER (WHERE outcome = 'moment_reached'),
    \\    arg_min(vtime_ns, branch) FILTER (WHERE outcome = 'moment_reached'), min(branch), count(*),
    \\    count(*) FILTER (WHERE outcome <> 'moment_reached'), 'timeline_limit.zig', NULL, NULL,
    \\    NULL, NULL
    \\FROM explored WHERE learned_stop HAVING count(*) > 0
    \\UNION ALL
    \\-- Guidance that cannot be guiding (docs/ANTITHESIS_EXPLORATION.md, F; Antithesis's Tetris,
    \\-- six years capped by a misread line count): a guidance assertion's distance, or an
    \\-- optimize bucket's value, the same in each of 8 timelines or more that reported it. A
    \\-- distance of 0 throughout is an assertion already met, not a broken signal. Counted by
    \\-- message (and bucket), not by timeline.
    \\SELECT 'always', 'guidance values move across the run''s timelines',
    \\    CASE WHEN count(*) FILTER (WHERE stuck) > 0 THEN 'failing' ELSE 'passing' END,
    \\    count(*), count(*) FILTER (WHERE NOT stuck), count(*) FILTER (WHERE stuck), NULL, NULL,
    \\    NULL, count(*), count(*) FILTER (WHERE NOT stuck), 'store.zig', NULL, NULL, NULL, NULL
    \\FROM (
++ guidance_stuck_sql ++
    \\) HAVING count(*) > 0
    \\)
    \\SELECT * FROM listed
    \\ORDER BY status = 'failing' DESC, timelines_failing DESC, message
;

/// The timelines, each with the properties it violates (Events.Property.passing): an `always`
/// made false, an `unreachable` reached.
/// Each failing property's first failing timeline (the lowest index; the failing evaluations
/// of timelines_sql): what serve snapshots as soon as it is found.
/// Each failing property's first failing timeline, the rarest failures first (fewest failing
/// timelines): what serve analyzes on its own, one at a time, a failure every timeline has (a
/// crash at every exit) last.
pub const first_failures_sql =
    \\SELECT message AS property, min(timeline) AS branch, count(DISTINCT timeline) AS timelines
    \\FROM timeline_properties
    \\WHERE failed_ns IS NOT NULL
    \\    AND timeline NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL)
    \\GROUP BY message
    \\ORDER BY timelines, branch
;

pub const timelines_sql =
    \\WITH failing AS (
    \\    SELECT timeline, list(DISTINCT message ORDER BY message) AS failing
    \\    FROM timeline_properties WHERE failed_ns IS NOT NULL
    \\    GROUP BY timeline
    \\)
    \\SELECT t.branch AS "index", t.seed, t.outcome, t.vtime_ns, t.wall_ns, t.events, t.events_hash,
    \\    t.generation, t.why, t.parent, t.start_ns, t.path, t.extends,
    \\    to_json(coalesce(f.failing, []::VARCHAR[])) AS failing
    \\FROM timelines t LEFT JOIN failing f ON f.timeline = t.branch
    \\ORDER BY t.branch
;

/// New behavior discovery (Antithesis's utilization chart): after each timeline, in index order,
/// What the system's nodes logged as errors, across the run: each error-like output line
/// (a panic, fatal, exception, assertion, or an ERROR, SEVERE or CRIT level; a failed assertion,
/// Redis's and Valkey's "'<expression>' is not true" too, at the panic level) made a template (its
/// first 300 characters, each number and long hex id `#`, a leading timestamp out), by node, with the timelines that logged
/// it, its lines, its first timeline and moment there, and an example line. Panics and fatals
/// first, then by timelines. What no property reads: TiDB's recovered auto-analyze panic, #64466,
/// in a third of a hunt's timelines, was seen only by reading logs (2026-11-08). Lines that begin
/// with a space or tab are a stack's continuation (a Rust backtrace's frames, Go's, Java's `at`),
/// left out: one line a failure. The kernel's
/// console is the platform's (its own faults' messages: aborted journals after power losses).
pub const logged_sql =
    \\SELECT node, level, template,
    \\    count(DISTINCT branch) AS timelines,
    \\    sum(lines)::UBIGINT AS lines,
    \\    min(branch) AS first_timeline,
    \\    arg_min(first_vtime_ns, branch) AS first_vtime_ns,
    \\    arg_min(example, branch) AS example
    \\FROM logged
    \\WHERE branch IS NULL OR branch NOT IN (SELECT branch FROM timelines WHERE extends IS NOT NULL)
    \\GROUP BY node, level, template
    \\ORDER BY level = 'panic' DESC, timelines DESC, lines DESC, node, template
    \\LIMIT 500
    \\
;

/// JVM starts that refused their AOT cache because of our coverage agent: its -javaagent puts
/// java.instrument among the modules at runtime, and a cache trained without it is refused (the
/// JDK's own line, read from `logged`: aws-hunt run 18's Datalevin, 1,255 of 1,441 starts, a
/// restarted server serving a median 75 virtual s later). Our doing, not the system's: a note of
/// the run's (serve's jvm-cache file), never a property. docs/CI.md has the image's recipe.
pub const jvm_cache_refused_sql =
    \\SELECT coalesce(sum(lines), 0)::UBIGINT AS starts, count(DISTINCT branch)::UBIGINT AS timelines
    \\FROM logged
    \\WHERE template LIKE '%java.instrument specified during runtime but not during dump time%'
;

/// how many distinct behaviors the exploration has seen. A timeline's ancestors finished before
/// it began, so a behavior is first seen at the lowest index whose own events (or the setup's,
/// for every timeline) have it.
pub const discovery_sql =
    \\WITH ordered AS (
    \\    SELECT branch, row_number() OVER (ORDER BY branch) AS n FROM explored
    \\), first_seen AS (
    \\    SELECT behavior, min(n) AS n FROM (
    \\        SELECT r.behavior, o.n FROM behavior_reach r JOIN ordered o ON r.branch = o.branch
    \\        UNION ALL
    \\        SELECT behavior, 1 FROM behavior_reach WHERE branch IS NULL
    \\    ) GROUP BY behavior
    \\), new AS (SELECT n, count(*) AS new FROM first_seen GROUP BY n)
    \\SELECT o.n AS timelines, sum(coalesce(new.new, 0)) OVER (ORDER BY o.n) AS behaviors
    \\FROM ordered o LEFT JOIN new USING (n)
    \\ORDER BY o.n
;

/// Each timeline's first failing evaluation among its own events, as a map mark: what the map
/// draws of them (a timeline's first failure past its branch point). Every failing evaluation
/// was 68,894 marks and 14 MB on etcd's run 2007, for 1,246 timelines.
pub const failures_sql =
    \\SELECT branch, seq, vtime_ns, json_object('type', type, 'message', message)::VARCHAR AS mark
    \\FROM timeline_failures ORDER BY branch
;

/// The run at a glance: its timelines, those failing a property, virtual and wall time, and
/// distinct behaviors.
pub const stats_sql =
    \\WITH extending AS (
    \\    -- A person's sessions: not what the run explored.
    \\    SELECT branch FROM timelines WHERE extends IS NOT NULL
    \\), once AS (
    \\    -- Behaviors only one timeline reached (none in setup), with that timeline.
    \\    SELECT any_value(branch) AS branch FROM behavior_reach
    \\    WHERE branch IS NOT NULL AND branch NOT IN (SELECT branch FROM extending)
    \\        AND behavior NOT IN (SELECT behavior FROM behavior_reach WHERE branch IS NULL)
    \\    GROUP BY behavior HAVING count(*) = 1)
    \\SELECT
    \\    (SELECT count(*) FROM explored) AS timelines,
    \\    -- Those that extend one (sessions), beside what the run explored.
    \\    (SELECT count(*) FROM extending) AS extending,
    \\    (SELECT count(DISTINCT timeline) FROM timeline_properties
    \\        WHERE failed_ns IS NOT NULL
    \\            AND timeline NOT IN (SELECT branch FROM extending)) AS failing_timelines,
    \\    (SELECT coalesce(sum(vtime_ns), 0) FROM explored) AS vtime_ns,
    \\    (SELECT coalesce(sum(wall_ns), 0) FROM explored) AS wall_ns,
    \\    (SELECT count(DISTINCT behavior) FROM behavior_reach
    \\        WHERE branch IS NULL OR branch NOT IN (SELECT branch FROM extending)) AS behaviors,
    \\    -- Over the timelines, the behaviors only one timeline reached: how many new ones the
    \\    -- next timeline is expected to find (Good-Turing; Böhme et al., "Estimating Residual
    \\    -- Risk in Greybox Fuzzing", FSE 2021), many when each timeline reaches many.
    \\    (SELECT count(*) FROM once) AS behaviors_once,
    \\    -- Over the timelines, those that reached one: the chance that the next finds any (left
    \\    -- out, a timeline would have found something new exactly when it reached a behavior no
    \\    -- other did). When exploring more stops paying.
    \\    (SELECT count(DISTINCT branch) FROM once) AS timelines_once,
    \\    (SELECT coalesce(sum(events), 0)::UBIGINT FROM branch_events
    \\        WHERE branch IS NULL OR branch NOT IN (SELECT branch FROM extending)) AS events,
    \\    -- Each node's CPU time over the guest's uptime, averaged over the timelines (det-init's
    \\    -- node_cpu events at a timeline's end): where a slow simulation spends its time.
    \\    (SELECT coalesce(json_group_object(node, share), '{}') FROM (
    \\        SELECT node, round(avg(usage_ms / nullif(uptime_ms, 0)), 3) AS share
    \\        FROM node_cpu WHERE branch NOT IN (SELECT branch FROM extending)
    \\        GROUP BY 1 ORDER BY 2 DESC)) AS cpu_by_node,
    \\    -- Commands run in nodes (det-init's exec_cpu events): by node and command, their CPU
    \\    -- over the uptime and how many ran, a timeline's on average (none in a timeline: 0), the
    \\    -- costliest first. Within their node's share: a runtime started per call (Cassandra's
    \\    -- nodetool, a JVM each) looks like the node's work there.
    \\    (SELECT coalesce(json_group_object(name, json_object('share', share, 'execs', execs)), '{}') FROM (
    \\        SELECT node || ' ' || command AS name,
    \\            round(sum(cpu_ms / nullif(uptime_ms, 0)) / any_value(t.n), 3) AS share,
    \\            round(sum(execs) / any_value(t.n), 1) AS execs
    \\        FROM exec_cpu,
    \\            (SELECT greatest(count(DISTINCT branch), 1) AS n FROM node_cpu
    \\                WHERE branch NOT IN (SELECT branch FROM extending)) t
    \\        WHERE branch NOT IN (SELECT branch FROM extending)
    \\        GROUP BY 1 ORDER BY 2 DESC LIMIT 12)) AS cpu_by_exec
;

const testing = std.testing;

/// An event line as the VMM writes it.
fn line(comptime seq: u64, comptime vtime_ns: u64, comptime event: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"seq\":{d},\"vtime_ns\":{d},\"event\":{s}}}\n", .{
        seq, vtime_ns, event,
    });
}

/// A timelines.jsonl line as the explorer writes it (the fields the database reads).
fn timeline_line(
    comptime index: u32,
    comptime vtime_ns: u64,
    comptime path: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"index\":{d},\"outcome\":\"shutdown\",\"vtime_ns\":{d},\"wall_ns\":10,\"path\":{s}}}\n",
        .{ index, vtime_ns, path },
    );
}

const fixture_timelines = timeline_line(1, 700, "[]") ++ timeline_line(2, 470, "[]");
const fixture_path = "[{\"branch\":1,\"seed\":7,\"vtime_ns\":550}]";

/// An events directory as an exploration writes it: a setup, two timelines from the setup
/// snapshot, and a third that began inside the first.
fn fixture_write(io: std.Io, directory: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    const files = comptime [_]struct { []const u8, []const u8 }{
        .{
            "setup.jsonl",
            line(1, 100,
                \\{"event":"node_start","details":{"node":"db"}}
            ) ++ line(2, 200,
                \\{"assert":{"type":"sometimes","message":"leader elected","hit":false}}
            ) ++ line(3, 300,
                \\{"assert":{"type":"always","message":"log matches","condition":true}}
            ),
        },
        .{
            "branch-1.jsonl",
            line(4, 400,
                \\{"output":{"source":"db","stream":"stdout","text":"became leader"}}
            ) ++ line(5, 500,
                \\{"assert":{"type":"sometimes","message":"leader elected","condition":true}}
            ) ++ line(6, 600,
                \\{"event":"partition","details":{"node":"db","kind":"split"}}
            ),
        },
        .{
            "branch-2.jsonl",
            line(4, 450,
                \\{"assert":{"type":"always","message":"log matches","condition":false}}
            ) ++ line(5, 460,
                \\{"raw":"not json"}
            ),
        },
        .{
            "branch-3.jsonl",
            "{\"path\":" ++ fixture_path ++ "}\n" ++ line(6, 560,
                \\{"antithesis_assert":{"display_type":"Unreachable","message":"split brain",
            ++
                \\"condition":true,"hit":true}}
            ),
        },
        .{ "timelines.jsonl", fixture_timelines },
    };
    for (files) |file| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, file[0] });
        defer testing.allocator.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = file[1] });
        // Ended timelines' events, compressed as their timelines left them.
        if (event_files.index_of(file[0])) |index| try event_files.compress(directory, index);
    }
}

test "ingest brings whole timelines; properties, timelines and discovery read them" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try testing.expectEqual(2, try ingest(&connection, arena, io, directory));
    try testing.expectEqual(0, try ingest(&connection, arena, io, directory)); // Nothing new.

    // The third finishes: ingested on its own, the setup's events not again.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    const more = comptime fixture_timelines ++ timeline_line(3, 580, fixture_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = more });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));

    const Count = struct { events: u64, setup: u64, raw: u64 };
    const counted = (try connection.row(Count, arena,
        \\SELECT count(*), count(*) FILTER (WHERE branch IS NULL),
        \\    count(*) FILTER (WHERE kind = 'raw')
        \\FROM events
    , .{})).?;
    try testing.expectEqual(Count{ .events = 9, .setup = 3, .raw = 1 }, counted);

    // Timeline 3: the setup, timeline 1 up to 550 ns, then its own.
    const Event = struct { seq: u64, origin: ?u32 };
    const third = try connection.rows(Event, arena,
        \\SELECT seq, origin FROM timeline_events WHERE timeline = 3 ORDER BY vtime_ns, seq
    , .{});
    try testing.expectEqual(6, third.len);
    try testing.expectEqual(Event{ .seq = 5, .origin = 1 }, third[4]);
    try testing.expectEqual(Event{ .seq = 6, .origin = 3 }, third[5]);

    const Property = struct {
        type: []const u8,
        message: []const u8,
        status: []const u8,
        failing: u64,
        first: ?u32,
    };
    const properties = try connection.rows(Property, arena,
        \\SELECT type, message, status, timelines_failing, first_failing_timeline
        \\FROM (
    ++ properties_sql ++
        \\) ORDER BY message
    , .{});
    try testing.expectEqual(3, properties.len);
    try testing.expectEqualStrings("leader elected", properties[0].message);
    try testing.expectEqualStrings("passing", properties[0].status); // True in timelines 1 and 3.
    try testing.expectEqualStrings("log matches", properties[1].message);
    try testing.expectEqualStrings("failing", properties[1].status);
    try testing.expectEqual(1, properties[1].failing);
    try testing.expectEqual(2, properties[1].first.?);
    try testing.expectEqualStrings("unreachable", properties[2].type);
    try testing.expectEqualStrings("failing", properties[2].status);

    // The timelines replayed as the run went: one more property, determinismo's, failing in
    // the one that did not replay (ingested twice: the second replaces the first).
    const replays_path = try std.fs.path.join(arena, &.{ directory, "record.jsonl.replays" });
    // Timelines 5 and 7 not replayed (killed, could not run): not replays, not failing.
    const replays_text = "1 same 2e30973b224051a4\n3 different 12 34 events 812 of 900\n" ++
        "5 killed ab\n7 failed cd\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = replays_path, .data = replays_text[0..24] });
    try replays_ingest(&connection, arena, io, replays_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = replays_path, .data = replays_text });
    try replays_ingest(&connection, arena, io, replays_path);
    const with_replays = try connection.rows(Property, arena,
        \\SELECT type, message, status, timelines_failing, first_failing_timeline
        \\FROM (
    ++ properties_sql ++
        \\) WHERE message LIKE 'timelines replay%'
    , .{});
    try testing.expectEqual(1, with_replays.len);
    try testing.expectEqualStrings("failing", with_replays[0].status);
    try testing.expectEqual(1, with_replays[0].failing);
    try testing.expectEqual(3, with_replays[0].first.?);
    const Why = struct { why: []const u8, replayed: []const u8 };
    const why = (try connection.row(Why, arena, "SELECT why, replayed FROM replays WHERE NOT same", .{})).?;
    try testing.expectEqualStrings("events 812 of 900", why.why);
    try testing.expectEqualStrings("34", why.replayed);

    const Timeline = struct { index: u32, failing: []const u8, parent: ?u32 };
    const timelines = try connection.rows(Timeline, arena,
        \\SELECT "index", failing::VARCHAR, parent FROM (
    ++ timelines_sql ++
        \\)
    , .{});
    try testing.expectEqual(3, timelines.len);
    try testing.expectEqualStrings("[]", timelines[0].failing);
    try testing.expectEqualStrings("[\"log matches\"]", timelines[1].failing);
    try testing.expectEqualStrings("[\"split brain\"]", timelines[2].failing);
    try testing.expectEqual(1, timelines[2].parent.?);

    // Behaviors: the setup's two assertions (the declaration and the evaluation) and node_start
    // is the runtime's; timeline 1 adds its sometimes and the partition; 2 its false always; 3
    // its Antithesis SDK's unreachable.
    const Point = struct { timelines: u64, behaviors: i128 };
    const points = try connection.rows(Point, arena, discovery_sql, .{});
    try testing.expectEqual(3, points.len);
    try testing.expectEqual(Point{ .timelines = 1, .behaviors = 4 }, points[0]);
    try testing.expectEqual(Point{ .timelines = 2, .behaviors = 5 }, points[1]);
    try testing.expectEqual(Point{ .timelines = 3, .behaviors = 6 }, points[2]);
    // Good-Turing's singletons: each timeline's 4 behaviors its own, the setup's left out; all
    // three timelines reached one (the chance the next finds any: 3 of 3).
    const Once = struct { behaviors_once: u64, timelines_once: u64 };
    const once = (try connection.row(Once, arena, "SELECT behaviors_once, timelines_once FROM (" ++ stats_sql ++ ")", .{})).?;
    try testing.expectEqual(4, once.behaviors_once);
    try testing.expectEqual(3, once.timelines_once);

    // Logging volume, a run's property: the timelines' output over their output span. These
    // timelines had no such fields (older lines): no row. Timeline 4 logs 2 GB in an hour:
    // over 200 MB an hour, the run fails it (no timeline alone).
    const logging = "logging output stays under 200 MB per hour of virtual time";
    const before = try connection.rows(Property, arena,
        \\SELECT type, message, status, timelines_failing, first_failing_timeline FROM (
    ++ properties_sql ++
        \\) WHERE message LIKE 'logging output%'
    , .{});
    try testing.expectEqual(0, before.len);
    const loud = comptime more ++
        "{\"index\":4,\"outcome\":\"shutdown\",\"vtime_ns\":3600000000000,\"wall_ns\":10,\"path\":[]," ++
        "\"output_bytes\":2000000000,\"output_span_ns\":3600000000000}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = loud });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));
    const after = try connection.rows(Property, arena,
        \\SELECT type, message, status, timelines_failing, first_failing_timeline FROM (
    ++ properties_sql ++
        \\) WHERE message LIKE 'logging output%'
    , .{});
    try testing.expectEqual(1, after.len);
    try testing.expectEqualStrings(logging, after[0].message);
    try testing.expectEqualStrings("failing", after[0].status);
    try testing.expectEqual(0, after[0].failing);

    // CPU by node (det-init's node_cpu events at a timeline's end): each node's CPU time over
    // the uptime, averaged over the timelines, the busiest first. None yet: an empty object.
    const Cpu = struct { cpu_by_node: []const u8 };
    const cpu_sql = "SELECT cpu_by_node::VARCHAR FROM (" ++ stats_sql ++ ")";
    const none = (try connection.row(Cpu, arena, cpu_sql, .{})).?;
    try testing.expectEqualStrings("{}", none.cpu_by_node);
    const Exec = struct { cpu_by_exec: []const u8 };
    const exec_sql = "SELECT cpu_by_exec::VARCHAR FROM (" ++ stats_sql ++ ")";
    try testing.expectEqualStrings("{}", (try connection.row(Exec, arena, exec_sql, .{})).?.cpu_by_exec);
    const branch_5 = try std.fs.path.join(arena, &.{ directory, "branch-5.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = branch_5, .data = comptime line(7, 900,
        \\{"event":"node_cpu","details":{"node":"db","usage_ms":600,"uptime_ms":1000}}
    ) ++ line(8, 900,
        \\{"event":"node_cpu","details":{"node":"app","usage_ms":100,"uptime_ms":1000}}
    ) ++ line(9, 900,
        \\{"event":"exec_cpu","details":{"node":"db","command":"nodetool","execs":30,"cpu_ms":400,"uptime_ms":1000}}
    ) ++ line(10, 900,
        \\{"event":"exec_cpu","details":{"node":"db","command":"sh","execs":3,"cpu_ms":10,"uptime_ms":1000}}
    ) });
    const branch_6 = try std.fs.path.join(arena, &.{ directory, "branch-6.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = branch_6, .data = comptime line(7, 2000,
        \\{"event":"node_cpu","details":{"node":"db","usage_ms":400,"uptime_ms":2000}}
    ) });
    try event_files.compress(directory, 5);
    try event_files.compress(directory, 6);
    const with_cpu = comptime loud ++ timeline_line(5, 900, "[]") ++ timeline_line(6, 2000, "[]");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = with_cpu });
    try testing.expectEqual(2, try ingest(&connection, arena, io, directory));
    const cpu = (try connection.row(Cpu, arena, cpu_sql, .{})).?;
    try testing.expectEqualStrings("{\"db\":0.4,\"app\":0.1}", cpu.cpu_by_node);

    // Commands run in nodes (exec_cpu events, in timeline 5 alone): over every timeline with a
    // node_cpu, timeline 6's none counting as 0.
    try testing.expectEqualStrings(
        "{\"db nodetool\":{\"share\":0.2,\"execs\":15.0},\"db sh\":{\"share\":0.005,\"execs\":1.5}}",
        (try connection.row(Exec, arena, exec_sql, .{})).?.cpu_by_exec,
    );
}

/// What a run's pages ask (serve's kept answers), each as its JSON.
fn pages_json(connection: *duckdb.Connection, arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for ([_][:0]const u8{ properties_sql, timelines_sql, stats_sql, discovery_sql, logged_sql, failures_sql }) |sql| {
        try connection.json(&out.writer, sql, .{});
        try out.writer.writeAll("\n--\n");
    }
    return out.written();
}

test "a run's pages read what its ingest summarized, never its events again" {
    // Each answer was a scan of every event, made again at each ingest of a run still running:
    // 50 to 80 s for the properties of etcd's run 2007 (65 million events). With the events
    // gone after the ingest, every page still answers the same.
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    const all = comptime fixture_timelines ++ timeline_line(3, 580, fixture_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = all });

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try testing.expectEqual(3, try ingest(&connection, arena, io, directory));
    const before = try pages_json(&connection, arena);
    // They say something: a failing property, a failing timeline's mark.
    try testing.expect(std.mem.indexOf(u8, before, "\"failing\"") != null);
    try testing.expect(std.mem.indexOf(u8, before, "log matches") != null);
    try connection.exec("DELETE FROM events");
    try testing.expectEqualStrings(before, try pages_json(&connection, arena));
}

test "each timeline's verdicts, with its ancestor's part and the setup's: what a property's examples read" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try testing.expectEqual(2, try ingest(&connection, arena, io, directory));
    // The third (from the first, at 550) arrives in a batch of its own.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    const more = comptime fixture_timelines ++ timeline_line(3, 580, fixture_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = more });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));

    const Row = struct { timeline: u32, message: []const u8, hits: u64, trues: u64, failed_ns: ?u64, hit_ns: ?u64, true_ns: ?u64, false_ns: ?u64 };
    const rows = try connection.rows(Row, arena,
        \\SELECT timeline, message, hits, trues, failed_ns, hit_ns, true_ns, false_ns
        \\FROM timeline_properties ORDER BY timeline, message
    , .{});
    const expected = [_]Row{
        // The first: the setup's true "log matches" (300), its own "leader elected" (500).
        .{ .timeline = 1, .message = "leader elected", .hits = 1, .trues = 1, .failed_ns = null, .hit_ns = 500, .true_ns = 500, .false_ns = null },
        .{ .timeline = 1, .message = "log matches", .hits = 1, .trues = 1, .failed_ns = null, .hit_ns = 300, .true_ns = 300, .false_ns = null },
        // The second: the setup's declaration of "leader elected" (no evaluation), "log matches"
        // true in the setup and false at 450.
        .{ .timeline = 2, .message = "leader elected", .hits = 0, .trues = 0, .failed_ns = null, .hit_ns = null, .true_ns = null, .false_ns = null },
        .{ .timeline = 2, .message = "log matches", .hits = 2, .trues = 1, .failed_ns = 450, .hit_ns = 300, .true_ns = 300, .false_ns = 450 },
        // The third: the first's part until 550 (its "leader elected" at 500), then its own.
        .{ .timeline = 3, .message = "leader elected", .hits = 1, .trues = 1, .failed_ns = null, .hit_ns = 500, .true_ns = 500, .false_ns = null },
        .{ .timeline = 3, .message = "log matches", .hits = 1, .trues = 1, .failed_ns = null, .hit_ns = 300, .true_ns = 300, .false_ns = null },
        .{ .timeline = 3, .message = "split brain", .hits = 1, .trues = 1, .failed_ns = 560, .hit_ns = 560, .true_ns = 560, .false_ns = null },
    };
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, got| {
        try testing.expectEqual(want.timeline, got.timeline);
        try testing.expectEqualStrings(want.message, got.message);
        try testing.expectEqual(want.hits, got.hits);
        try testing.expectEqual(want.trues, got.trues);
        try testing.expectEqual(want.failed_ns, got.failed_ns);
        try testing.expectEqual(want.hit_ns, got.hit_ns);
        try testing.expectEqual(want.true_ns, got.true_ns);
        try testing.expectEqual(want.false_ns, got.false_ns);
    }
    // The map's marks: each timeline's first failure among its own events.
    const Mark = struct { branch: u32, vtime_ns: u64, message: []const u8 };
    const marks = try connection.rows(Mark, arena, "SELECT branch, vtime_ns, message FROM timeline_failures ORDER BY branch", .{});
    try testing.expectEqual(2, marks.len);
    try testing.expectEqual(2, marks[0].branch);
    try testing.expectEqual(450, marks[0].vtime_ns);
    try testing.expectEqualStrings("log matches", marks[0].message);
    try testing.expectEqual(3, marks[1].branch);
    try testing.expectEqualStrings("split brain", marks[1].message);
}

test "a timeline's faults are its ancestor's part and its own, from the summary; a version 10 database gains them in place" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // Timeline 2 left timeline 1 at 550: 1's fault at 100 is 2's too, the one at 600 is not.
    try connection.exec(
        \\INSERT INTO timelines (branch, outcome, wall_ns) VALUES (1, 'shutdown', 1), (2, 'shutdown', 1);
        \\INSERT INTO steps VALUES (2, 0, 1, 0, 550);
        \\INSERT INTO events (branch, seq, vtime_ns, kind, name, event) VALUES
        \\ (1, 1, 100, 'event', 'fault', '{"event":"fault","details":{"kind":"partition","node":"n1","peer":"n2","duration_ns":5,"injected":true,"why":"drawn"}}'),
        \\ (1, 2, 600, 'event', 'fault', '{"event":"fault","details":{"kind":"pause","node":"n3","duration_ns":7}}'),
        \\ (1, 3, 610, 'event', 'faults_stop', '{"event":"faults_stop","details":{}}'),
        \\ (2, 2, 700, 'event', 'fault', '{"event":"fault","details":{"kind":"kill","flavor":"sigkill","node":"n1"}}');
    );
    try summaries_fill(&connection, arena, .{ .events = "TRUE", .timelines = "TRUE" }, false); // As an ingest does.
    const marks_sql =
        \\SELECT timeline, vtime_ns, kind, coalesce(flavor, '') AS flavor, node, coalesce(peer, '') AS peer,
        \\    coalesce(duration_ns::VARCHAR, '') AS duration_ns, coalesce(injected::VARCHAR, '') AS injected
        \\FROM timeline_faults ORDER BY timeline, vtime_ns
    ;
    const Row = struct { timeline: u32, vtime_ns: u64, kind: []const u8, flavor: []const u8, node: []const u8, peer: []const u8, duration_ns: []const u8, injected: []const u8 };
    const expected = [_]Row{
        .{ .timeline = 1, .vtime_ns = 100, .kind = "partition", .flavor = "", .node = "n1", .peer = "n2", .duration_ns = "5", .injected = "true" },
        .{ .timeline = 1, .vtime_ns = 600, .kind = "pause", .flavor = "", .node = "n3", .peer = "", .duration_ns = "7", .injected = "" },
        .{ .timeline = 2, .vtime_ns = 100, .kind = "partition", .flavor = "", .node = "n1", .peer = "n2", .duration_ns = "5", .injected = "true" },
        .{ .timeline = 2, .vtime_ns = 700, .kind = "kill", .flavor = "sigkill", .node = "n1", .peer = "", .duration_ns = "", .injected = "" },
    };
    // Twice: as ingested, then as a version 10 database (no faults table) brought up to date.
    for (0..2) |round| {
        if (round == 1) {
            try connection.exec("DROP VIEW timeline_faults; DROP TABLE faults; UPDATE schema_version SET version = 10;");
            try schema_ensure(&connection, arena);
            const Version = struct { version: u32 };
            try testing.expectEqual(@as(u32, schema_version), (try connection.row(Version, arena, "SELECT version FROM schema_version", .{})).?.version);
        }
        const rows = try connection.rows(Row, arena, marks_sql, .{});
        try testing.expectEqual(expected.len, rows.len);
        for (expected, rows) |want, got| {
            try testing.expectEqual(want.timeline, got.timeline);
            try testing.expectEqual(want.vtime_ns, got.vtime_ns);
            try testing.expectEqualStrings(want.kind, got.kind);
            try testing.expectEqualStrings(want.flavor, got.flavor);
            try testing.expectEqualStrings(want.node, got.node);
            try testing.expectEqualStrings(want.peer, got.peer);
            try testing.expectEqualStrings(want.duration_ns, got.duration_ns);
            try testing.expectEqualStrings(want.injected, got.injected);
        }
    }
}

test "a timeline's draws are the setup's, its ancestor's part and its own; a version 11 database gains the table in place" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // As a version 11 database: no draws table, brought up to date.
    try connection.exec("DROP VIEW timeline_draws; DROP VIEW draw_values; DROP TABLE draws; UPDATE schema_version SET version = 11;");
    try schema_ensure(&connection, arena);
    const Version = struct { version: u32 };
    try testing.expectEqual(@as(u32, schema_version), (try connection.row(Version, arena, "SELECT version FROM schema_version", .{})).?.version);
    // The setup drew a knob; timeline 1 a fault twice (at 100 and 600); timeline 2 left it at
    // 550 and drew its own; the dropped line and an empty file are no rows.
    const files = [_][2][]const u8{
        .{ "draws-setup.jsonl", "{\"name\":\"knob.flush\",\"kind\":\"range\",\"count\":3,\"config\":false,\"drawn\":1,\"overridden\":0,\"histogram\":[0,0,1],\"kept\":[{\"pull\":4,\"after_ns\":10,\"value\":2,\"overridden\":false}]}\n" },
        .{ "draws-1.jsonl", "{\"name\":\"fault\",\"kind\":\"options\",\"count\":2,\"config\":false,\"options\":[\"kill\",\"pause\"],\"drawn\":2,\"overridden\":1,\"histogram\":[1,1],\"kept\":[{\"pull\":20,\"after_ns\":100,\"value\":0,\"overridden\":false},{\"pull\":30,\"after_ns\":600,\"value\":1,\"overridden\":true}]}\n{\"dropped\":3}\n" },
        .{ "draws-2.jsonl", "{\"name\":\"swarm.op\",\"kind\":\"range\",\"count\":4,\"config\":true,\"drawn\":1,\"overridden\":1,\"histogram\":[0,0,0,1],\"kept\":[{\"pull\":25,\"after_ns\":560,\"value\":3,\"overridden\":true}]}\n" },
        .{ "draws-3.jsonl", "" },
    };
    var paths: [files.len][]const u8 = undefined;
    for (files, &paths) |file, *path| {
        path.* = try std.fs.path.join(arena, &.{ directory, file[0] });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path.*, .data = file[1] });
    }
    try connection.exec(
        \\INSERT INTO timelines (branch, outcome, wall_ns) VALUES (1, 'shutdown', 1), (2, 'shutdown', 1);
        \\INSERT INTO steps VALUES (2, 0, 1, 0, 550);
    );
    try draws_insert(&connection, arena, io, &paths);
    const Row = struct { timeline: u32, part: []const u8, name: []const u8, value: u64, drew: []const u8, after_ns: u64 };
    const rows = try connection.rows(Row, arena,
        \\SELECT timeline, part, name, value, drew, after_ns FROM timeline_draws ORDER BY timeline, pull
    , .{});
    const expected = [_]Row{
        .{ .timeline = 1, .part = "setup", .name = "knob.flush", .value = 2, .drew = "2", .after_ns = 10 },
        .{ .timeline = 1, .part = "own", .name = "fault", .value = 0, .drew = "kill", .after_ns = 100 },
        .{ .timeline = 1, .part = "own", .name = "fault", .value = 1, .drew = "pause", .after_ns = 600 },
        .{ .timeline = 2, .part = "setup", .name = "knob.flush", .value = 2, .drew = "2", .after_ns = 10 },
        .{ .timeline = 2, .part = "ancestor", .name = "fault", .value = 0, .drew = "kill", .after_ns = 100 },
        .{ .timeline = 2, .part = "own", .name = "swarm.op", .value = 3, .drew = "3", .after_ns = 560 },
    };
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, got| {
        try testing.expectEqual(want.timeline, got.timeline);
        try testing.expectEqualStrings(want.part, got.part);
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqual(want.value, got.value);
        try testing.expectEqualStrings(want.drew, got.drew);
        try testing.expectEqual(want.after_ns, got.after_ns);
    }
}

test "a version 9 database gains its summaries in place, its pages answering as a new ingest's" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    const all = comptime fixture_timelines ++ timeline_line(3, 580, fixture_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = all });

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try testing.expectEqual(3, try ingest(&connection, arena, io, directory));
    const ingested = try pages_json(&connection, arena);
    // As version 9 had it: its events, timelines and steps, no summary.
    try connection.exec(summaries_drop_sql ++ "UPDATE schema_version SET version = 9;");
    try schema_ensure(&connection, arena);
    const Version = struct { version: u32 };
    try testing.expectEqual(@as(u32, schema_version), (try connection.row(Version, arena, "SELECT version FROM schema_version", .{})).?.version);
    try testing.expectEqualStrings(ingested, try pages_json(&connection, arena));
    // Opened again: nothing made twice.
    try schema_ensure(&connection, arena);
    try testing.expectEqualStrings(ingested, try pages_json(&connection, arena));
}

test "a CI shard's verdict counts the run's timelines, never a session's" {
    // CE28 (the Lean replica of determinismo): a session on a CI job's run (a fix tried at a failing
    // timeline's REPL) changed its shard's verdict: 3 failing timelines and a passing session read
    // flaky, and the job passed with --flaky-passes.
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    const failed =
        \\{"assert":{"type":"always","message":"the CI shard's tests pass","condition":false,"details":{"shard":1,"status":1}}}
    ;
    const passed =
        \\{"assert":{"type":"always","message":"the CI shard's tests pass","condition":true,"details":{"shard":1,"status":0}}}
    ;
    const files = comptime [_]struct { []const u8, []const u8 }{
        .{ "setup.jsonl", line(1, 100, "{\"event\":\"node_start\",\"details\":{\"node\":\"app\"}}") },
        .{ "branch-0.jsonl", line(2, 900, failed) },
        .{ "branch-1.jsonl", line(3, 900, failed) },
        .{ "branch-2.jsonl", line(4, 900, failed) },
        // Timeline 3: a session on timeline 0 from 500, its run passing after a fix at its REPL.
        .{ "branch-3.jsonl", line(5, 950, passed) },
        .{ "timelines.jsonl", timeline_line(0, 1000, "[]") ++ timeline_line(1, 1000, "[]") ++ timeline_line(2, 1000, "[]") ++
            "{\"index\":3,\"outcome\":\"command_done\",\"vtime_ns\":1000,\"wall_ns\":10," ++
            "\"path\":[{\"branch\":0,\"seed\":7,\"vtime_ns\":500}],\"extends\":{\"branch\":0,\"vtime_ns\":500}}\n" },
    };
    inline for (files) |file| {
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ directory, file[0] }), .data = file[1] });
        if (event_files.index_of(file[0])) |index| try event_files.compress(directory, index);
    }
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var attached = try store.connect(&database, arena, &failure);
    defer attached.close();
    _ = try ingest(&attached, arena, io, directory);
    const Row = struct { shard: u32, failing: u64, timelines: u64 };
    const rows = try attached.rows(Row, arena, @import("products/ci.zig").shard_sql, .{});
    try testing.expectEqual(1, rows.len);
    // The shard failed in every one of its 3 timelines: "fail" (ci.zig:291).
    try testing.expectEqual(Row{ .shard = 1, .failing = 3, .timelines = 3 }, rows[0]);
}

test "a timeline that extends another (a session's) is queried as any, and never among what the run found" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    // Timeline 0, the run's own: the property holds. Timeline 1, a session on it from 550: the
    // person made it fail there (a crash at a REPL), and logged an error.
    const files = comptime [_]struct { []const u8, []const u8 }{
        .{
            "setup.jsonl",
            line(1, 100,
                \\{"event":"node_start","details":{"node":"db"}}
            ),
        },
        .{
            "branch-0.jsonl",
            line(2, 400,
                \\{"assert":{"type":"always","message":"no process crashes","condition":true}}
            ) ++ line(3, 600,
                \\{"event":"past the session's moment","details":{}}
            ),
        },
        .{
            "branch-1.jsonl",
            line(3, 580,
                \\{"assert":{"type":"always","message":"no process crashes","condition":false}}
            ) ++ line(4, 590,
                \\{"output":{"source":"db","stream":"stderr","text":"FATAL: crashed by hand"}}
            ),
        },
        .{ "timelines.jsonl", timeline_line(0, 700, "[]") ++
            "{\"index\":1,\"outcome\":\"command_done\",\"vtime_ns\":650,\"wall_ns\":10," ++
            "\"path\":[{\"branch\":0,\"seed\":7,\"vtime_ns\":550}],\"extends\":{\"branch\":0,\"vtime_ns\":550}}\n" },
    };
    inline for (files) |file| {
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ directory, file[0] }), .data = file[1] });
        if (event_files.index_of(file[0])) |index| try event_files.compress(directory, index);
    }
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var attached = try store.connect(&database, arena, &failure);
    defer attached.close();
    const connection = &attached;
    try testing.expectEqual(2, try ingest(connection, arena, io, directory));
    // Listed with what it extends and what it fails; its history is timeline 0's to its moment
    // (the assertion at 400, not the event at 600), then its own.
    const Listed = struct { index: u32, extends: ?u32, failing: []const u8 };
    const listed = try connection.rows(Listed, arena, "SELECT \"index\", extends, failing::VARCHAR AS failing FROM (" ++ timelines_sql ++ ")", .{});
    try testing.expectEqual(2, listed.len);
    try testing.expectEqual(@as(?u32, null), listed[0].extends);
    try testing.expectEqual(@as(?u32, 0), listed[1].extends);
    try testing.expectEqualStrings("[\"no process crashes\"]", listed[1].failing);
    const Seq = struct { seq: u64 };
    const history = try connection.rows(Seq, arena, "SELECT seq FROM timeline_events WHERE timeline = 1 ORDER BY vtime_ns, seq", .{});
    try testing.expectEqual(4, history.len); // 1 (setup), 2 (timeline 0's), 3 and 4 (its own).
    try testing.expectEqual(@as(u64, 4), history[3].seq);
    // What the run found: one timeline, the property passing, nothing logged, no first failure.
    const Judged = struct { message: []const u8, status: []const u8, timelines_failing: u64 };
    const judged = try connection.rows(Judged, arena, "SELECT message, status, timelines_failing FROM (" ++ properties_sql ++ ") WHERE message = 'no process crashes'", .{});
    try testing.expectEqual(1, judged.len);
    try testing.expectEqualStrings("passing", judged[0].status);
    try testing.expectEqual(0, judged[0].timelines_failing);
    const Stats = struct { timelines: u64, extending: u64, failing_timelines: u64, vtime_ns: u64 };
    const stats = (try connection.row(Stats, arena, "SELECT timelines, extending, failing_timelines, vtime_ns::UBIGINT AS vtime_ns FROM (" ++ stats_sql ++ ")", .{})).?;
    try testing.expectEqual(Stats{ .timelines = 1, .extending = 1, .failing_timelines = 0, .vtime_ns = 700 }, stats);
    const Count = struct { count: u64 };
    try testing.expectEqual(0, (try connection.row(Count, arena, "SELECT count(*) FROM (" ++ logged_sql ++ ")", .{})).?.count);
    try testing.expectEqual(0, (try connection.row(Count, arena, "SELECT count(*) FROM (" ++ first_failures_sql ++ ")", .{})).?.count);
}

test "a run without a timeline shows its setup's events as timeline 0 (setup mode, a failed setup)" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    const setup = comptime line(1, 100,
        \\{"event":"node_start","details":{"node":"db"}}
    ) ++ line(2, 200,
        \\{"lifecycle":"setup_complete","details":{}}
    );
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ directory, "setup.jsonl" }), .data = setup });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" }), .data = "" });

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try setup_ingest(&connection, arena, io, directory);
    const Event = struct { timeline: u32, seq: u64 };
    const seen = try connection.rows(Event, arena,
        \\SELECT timeline, seq FROM timeline_events ORDER BY seq
    , .{});
    try testing.expectEqual(2, seen.len);
    try testing.expectEqual(Event{ .timeline = 0, .seq = 2 }, seen[1]);
}

test "the learned limit's property: of the timelines that ran with its stop, those cut there fail it" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    const Property = struct { status: []const u8, hit: u64, failing: u64, first: ?u32, first_ns: ?u64 };
    const learned_sql = "SELECT status, timelines_hit, timelines_failing, first_failing_timeline, " ++
        "first_failure_ns FROM (" ++ properties_sql ++ ") WHERE message = 'timelines end within the run''s learned limit (twice its normal ends'' 99th percentile past a branch point)'";
    // Timeline 1 ran before the run learned a limit (no stop of its own): no row yet.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = timeline_line(1, 700, "[]") });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));
    try testing.expectEqual(0, (try connection.rows(Property, arena, learned_sql, .{})).len);
    // Timeline 2 ran with the learned stop and was cut there, timeline 3 with it and ended
    // before it: the property fails in 2, its moment the cut's.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = comptime timeline_line(1, 700, "[]") ++
        "{\"index\":2,\"outcome\":\"moment_reached\",\"vtime_ns\":470,\"wall_ns\":10,\"path\":[],\"learned_stop\":true}\n" ++
        "{\"index\":3,\"outcome\":\"shutdown\",\"vtime_ns\":580,\"wall_ns\":10,\"path\":" ++ fixture_path ++ ",\"learned_stop\":true}\n" });
    try testing.expectEqual(2, try ingest(&connection, arena, io, directory));
    const judged = try connection.rows(Property, arena, learned_sql, .{});
    try testing.expectEqual(1, judged.len);
    try testing.expectEqualStrings("failing", judged[0].status);
    try testing.expectEqual(2, judged[0].hit);
    try testing.expectEqual(1, judged[0].failing);
    try testing.expectEqual(2, judged[0].first.?);
    try testing.expectEqual(470, judged[0].first_ns.?);
}

test "a version 12 database gains learned_stop in place, its timelines from before without it" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // As version 12 left it: a timeline, no learned_stop.
    try connection.exec(
        \\ALTER TABLE timelines DROP COLUMN learned_stop;
        \\UPDATE schema_version SET version = 12;
        \\INSERT INTO timelines (branch, outcome) VALUES (7, 'moment_reached');
    );
    try schema_ensure(&connection, arena);
    const Kept = struct { branch: u32, version: u32, learned_stop: ?bool };
    const kept = (try connection.row(Kept, arena,
        \\SELECT branch, (SELECT version FROM schema_version), learned_stop FROM timelines
    , .{})).?;
    try testing.expectEqual(Kept{ .branch = 7, .version = schema_version, .learned_stop = null }, kept);
    // Its columns in the order an ingest inserts them: a new timeline's learned_stop lands there.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = "{\"index\":1,\"outcome\":\"moment_reached\"," ++
        "\"vtime_ns\":700,\"wall_ns\":10,\"path\":[],\"learned_stop\":true}\n" });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));
    const Stop = struct { learned_stop: ?bool };
    const stop = (try connection.row(Stop, arena, "SELECT learned_stop FROM timelines WHERE branch = 1", .{})).?;
    try testing.expectEqual(true, stop.learned_stop.?);
}

test "a version 3 database gains the timelines' output in place, filled by the next ingest" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // As version 3 left it: a timeline, no output columns.
    try connection.exec(
        \\ALTER TABLE timelines DROP COLUMN output_bytes;
        \\ALTER TABLE timelines DROP COLUMN output_span_ns;
        \\UPDATE schema_version SET version = 3;
        \\INSERT INTO timelines (branch, outcome) VALUES (7, 'shutdown');
    );
    try schema_ensure(&connection, arena);
    const Kept = struct { branch: u32, version: u32, output: ?u64 };
    const kept = (try connection.row(Kept, arena,
        \\SELECT branch, (SELECT version FROM schema_version), output_bytes FROM timelines
    , .{})).?;
    try testing.expectEqual(Kept{ .branch = 7, .version = schema_version, .output = null }, kept);

    // Its line in timelines.jsonl has the output (an exploration writes it): the next ingest,
    // with nothing new arrived, fills it.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = "{\"index\":7," ++
        "\"outcome\":\"shutdown\",\"path\":[],\"output_bytes\":5,\"output_span_ns\":9}\n" });
    try testing.expectEqual(0, try ingest(&connection, arena, io, directory));
    const filled = (try connection.row(Kept, arena,
        \\SELECT branch, (SELECT version FROM schema_version), output_bytes FROM timelines
    , .{})).?;
    try testing.expectEqual(Kept{ .branch = 7, .version = schema_version, .output = 5 }, filled);
}

test "a version 4 database refiles messages whose first key was \"details\" (Go's), in place" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // As version 4 filed the Go SDK's coverage event; a fault event as it filed it, right.
    try connection.exec(
        \\UPDATE schema_version SET version = 4;
        \\INSERT INTO events (branch, seq, vtime_ns, kind, event) VALUES
        \\    (1, 1, 10, 'details', '{"details":{"name":"line /src/raft.go:7"},"event":"coverage"}'),
        \\    (1, 2, 20, 'event', '{"event":"fault","details":{"node":"db"}}'),
        \\    (1, 3, 30, 'details', '{"details":{},"lifecycle":"setup_complete"}');
    );
    try schema_ensure(&connection, arena);
    const Row = struct { seq: u64, kind: []const u8, name: ?[]const u8, behavior: bool };
    const rows = try connection.rows(Row, arena,
        \\SELECT seq, kind, name, behavior IS NOT NULL AS behavior FROM events ORDER BY seq
    , .{});
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("event", rows[0].kind);
    try testing.expectEqualStrings("coverage", rows[0].name.?);
    try testing.expect(rows[0].behavior);
    try testing.expectEqualStrings("event", rows[1].kind);
    try testing.expect(rows[1].name == null); // Not refiled: it was right.
    try testing.expectEqualStrings("lifecycle", rows[2].kind);
    try testing.expectEqualStrings("setup_complete", rows[2].name.?);
}

test "a version 5 database gains the timelines' drawn features in place, from their own events" {
    // (Version 6's are emptied and filled the same way, with the regimes' bounds.)
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // As version 5 had it: no drawn or measured; a setup's swarm (every timeline's: left out) and
    // two timelines' own draws.
    try connection.exec(
        \\DROP TABLE drawn; DROP TABLE measured; UPDATE schema_version SET version = 5;
        \\INSERT INTO events (branch, seq, vtime_ns, kind, name, event) VALUES
        \\    (NULL, 1, 5, 'event', 'fault_swarm', '{"event":"fault_swarm","details":{"kinds":"pause:4"}}'),
        \\    (1, 2, 10, 'event', 'fault_swarm', '{"event":"fault_swarm","details":{"kinds":"pause:4 partition:2"}}'),
        \\    (1, 3, 11, 'event', 'drive_drawn', '{"event":"drive_drawn","details":{"ms":1500,"max_ms":1200000}}'),
        \\    (2, 4, 10, 'event', 'composer_load', '{"event":"composer_load","details":{"shape":"spike","parallelism":8}}'),
        \\    (2, 5, 12, 'event', 'command_weight', '{"event":"command_weight","details":{"name":"driver.sh","weight":3}}');
    );
    try schema_ensure(&connection, arena);
    const Feature = struct { branch: u32, feature: []const u8 };
    const drawn = try connection.rows(Feature, arena, "SELECT branch, feature FROM drawn ORDER BY branch, feature", .{});
    try testing.expectEqual(@as(usize, 5), drawn.len);
    try testing.expectEqualStrings("fault partition", drawn[0].feature);
    try testing.expectEqualStrings("fault pause", drawn[1].feature);
    try testing.expectEqual(@as(u32, 2), drawn[2].branch);
    try testing.expectEqualStrings("command driver.sh", drawn[2].feature);
    try testing.expectEqualStrings("load spike", drawn[3].feature);
    try testing.expectEqualStrings("parallelism 8", drawn[4].feature);
    const Measured = struct { branch: u32, what: []const u8, v: f64 };
    const measured = try connection.rows(Measured, arena, "SELECT branch, what, v FROM measured", .{});
    try testing.expectEqual(@as(usize, 1), measured.len);
    try testing.expectEqualStrings("driver phase", measured[0].what);
    try testing.expectEqual(@as(f64, 1500), measured[0].v);
    const Version = struct { version: u32 };
    try testing.expectEqual(@as(u32, schema_version), (try connection.row(Version, arena, "SELECT version FROM schema_version", .{})).?.version);
}

test "logged errors are templates by node, panics first, the kernel's and plain lines left out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec("CREATE TABLE events (branch UINTEGER, vtime_ns UBIGINT, kind VARCHAR, node VARCHAR, text VARCHAR)");
    try connection.exec("CREATE TABLE timelines (branch UINTEGER, extends UINTEGER)"); // No session's timeline here.
    try connection.exec(summaries_tables_sql);
    try connection.exec(
        \\INSERT INTO events VALUES
        \\ (3, 500, 'output', 'n1', '[ERROR] ["panic in the recoverable goroutine"] [r="divide by zero"] [id=12]'),
        \\ (5, 900, 'output', 'n2', '[ERROR] ["panic in the recoverable goroutine"] [r="divide by zero"] [id=99]'),
        \\ (5, 950, 'output', 'n2', '[ERROR] [store.go:42] ["loadStore failed"] [id=7]'),
        \\ (6, 960, 'output', 'n2', '[ERROR] [store.go:42] ["loadStore failed"] [id=8]'),
        \\ (7, 970, 'output', 'n2', '[2026/11/08 00:00:24.726 +00:00] [ERROR] [store.go:42] ["loadStore failed"] [id=9]'),
        \\ (2, 100, 'output', 'n1', '[INFO] all is well, error=nil'),
        \\ (2, 100, 'output', 'q3', '   12: core::panicking::panic_fmt'),
        \\ (2, 100, 'output', 'kernel', 'EXT4-fs error (device dm-2): Detected aborted journal'),
        \\ (4, 100, 'assert', 'n1', 'ERROR not output')
    );
    try connection.exec(try scoped(arena, logged_summary_sql, "TRUE")); // As each ingest does, of its timelines.
    const Row = struct { node: []const u8, level: []const u8, template: []const u8, timelines: u64, lines: u64, first_timeline: u64, first_vtime_ns: u64, example: []const u8 };
    const rows = try connection.rows(Row, arena, logged_sql, .{});
    try testing.expectEqual(3, rows.len);
    // The panic first, though fewer timelines logged it; one template whatever its numbers.
    try testing.expectEqualStrings("panic", rows[0].level);
    try testing.expectEqual(1, rows[0].timelines);
    try testing.expectEqualStrings("n1", rows[0].node);
    try testing.expectEqual(3, rows[0].first_timeline);
    try testing.expectEqual(500, rows[0].first_vtime_ns);
    try testing.expectEqualStrings("[ERROR] [\"panic in the recoverable goroutine\"] [r=\"divide by zero\"] [id=#]", rows[0].template);
    try testing.expectEqualStrings("n2", rows[1].node);
    try testing.expectEqualStrings("panic", rows[1].level);
    try testing.expectEqualStrings("[ERROR] [store.go:#] [\"loadStore failed\"] [id=#]", rows[2].template);
    try testing.expectEqual(3, rows[2].timelines);
    try testing.expectEqual(5, rows[2].first_timeline);
}

test "a JVM's refused AOT cache is counted from its own line: starts and timelines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec("CREATE TABLE events (branch UINTEGER, vtime_ns UBIGINT, kind VARCHAR, node VARCHAR, text VARCHAR)");
    try connection.exec("CREATE TABLE timelines (branch UINTEGER, extends UINTEGER)");
    try connection.exec(summaries_tables_sql);
    // aws-hunt run 18's timeline 71, as recorded (two starts of dl1, one of dl2 in another).
    try connection.exec(
        \\INSERT INTO events VALUES
        \\ (71, 226922049994, 'output', 'dl1', '[0.129s][error][aot] Mismatched values for property jdk.module.addmods: java.instrument specified during runtime but not during dump time'),
        \\ (71, 226922049995, 'output', 'dl1', '[0.129s][error][aot] Unable to map shared spaces'),
        \\ (71, 232622649952, 'output', 'dl1', '[0.134s][error][aot] Mismatched values for property jdk.module.addmods: java.instrument specified during runtime but not during dump time'),
        \\ (72, 100, 'output', 'dl2', '[0.131s][error][aot] Mismatched values for property jdk.module.addmods: java.instrument specified during runtime but not during dump time'),
        \\ (73, 100, 'output', 'dl3', '[0.140s][error][aot] Unable to map shared spaces')
    );
    try connection.exec(try scoped(arena, logged_summary_sql, "TRUE"));
    const Refused = struct { starts: u64, timelines: u64 };
    const refused = (try connection.row(Refused, arena, jvm_cache_refused_sql, .{})).?;
    try testing.expectEqual(3, refused.starts);
    try testing.expectEqual(2, refused.timelines);
}

test "logged failed assertions are panics, Valkey's expression line among them" {
    // Valkey's crash in every append hunt (= #5182) logged "=== ASSERTION FAILED ===" and then
    // "==> server.c:3605 '<expression>' is not true": the first counted as an error, the second
    // not at all, and the summary's panics never named it (2026-11-08).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec("CREATE TABLE events (branch UINTEGER, vtime_ns UBIGINT, kind VARCHAR, node VARCHAR, text VARCHAR)");
    try connection.exec("CREATE TABLE timelines (branch UINTEGER, extends UINTEGER)"); // No session's timeline here.
    try connection.exec(summaries_tables_sql);
    try connection.exec(
        \\INSERT INTO events VALUES
        \\ (4, 100, 'output', 'v1', '2:M 27 Oct 2026 00:00:50.931 # === ASSERTION FAILED ==='),
        \\ (4, 100, 'output', 'v1', '2:M 27 Oct 2026 00:00:50.931 # ==> server.c:3605 ''!isPausedActions(PAUSE_ACTION_REPLICA) || server.server_del_keys_in_slot'' is not true'),
        \\ (5, 200, 'output', 'v2', 'Fatal glibc error: pthread_mutex_lock.c:94 (___pthread_mutex_lock): assertion failed: mutex->__data.__owner == 0'),
        \\ (6, 300, 'output', 'n1', '[ERROR] [store.go:42] ["loadStore failed"]')
    );
    try connection.exec(try scoped(arena, logged_summary_sql, "TRUE")); // As each ingest does, of its timelines.
    const Row = struct { node: []const u8, level: []const u8, template: []const u8, timelines: u64, lines: u64, first_timeline: u64, first_vtime_ns: u64, example: []const u8 };
    const rows = try connection.rows(Row, arena, logged_sql, .{});
    try testing.expectEqual(4, rows.len);
    var expression = false;
    for (rows[0..3]) |row| {
        try testing.expectEqualStrings("panic", row.level);
        if (std.mem.indexOf(u8, row.template, "isPausedActions") != null) expression = true;
    }
    try testing.expect(expression);
    try testing.expectEqualStrings("error", rows[3].level);
}

test "a failure's moment is when its assertion says it happened (at_ns), not when it was judged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try schema_ensure(&connection, arena);
    // Timeline 1: a checker's verdict at 739 s on what happened at 158.9 s; timeline 2: a plain
    // failure at 240 s.
    try connection.exec(
        \\INSERT INTO timelines (branch, outcome, wall_ns) VALUES (1, 'shutdown', 1000000000), (2, 'shutdown', 1000000000);
        \\INSERT INTO events (branch, seq, vtime_ns, kind, name, type, condition, event, at_ns) VALUES
        \\ (1, 1, 739068000000, 'assert', 'Elle finds no anomaly', 'always', false, '{"assert":{}}', 158928868225),
        \\ (2, 1, 240140000000, 'assert', 'no unexpected container exits', 'always', false, '{"assert":{}}', NULL);
    );
    try summaries_fill(&connection, arena, .{ .events = "TRUE", .timelines = "TRUE" }, false); // As an ingest does.
    const Row = struct { message: []const u8, first_failure_ns: u64 };
    const rows = try connection.rows(Row, arena, "SELECT message, first_failure_ns FROM (" ++ properties_sql ++ ") ORDER BY message", .{});
    try testing.expectEqual(2, rows.len);
    try testing.expectEqualStrings("Elle finds no anomaly", rows[0].message);
    try testing.expectEqual(158928868225, rows[0].first_failure_ns);
    try testing.expectEqual(240140000000, rows[1].first_failure_ns);
}

test "an assertion's at_ns in vtime: moved by the guest's now, a now past the event's vtime ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    // DuckDB run 1950's timeline 241 (the guest's clock 0.098 s behind); run 1983's host check
    // (srv4's monotonic now, 48,148 s, against 183 s); no now; no at_ns.
    try connection.exec(
        \\CREATE TABLE typed (n INTEGER, vtime_ns UBIGINT, assertion JSON);
        \\INSERT INTO typed VALUES
        \\ (1, 182548997838, '{"at_ns":138105038105,"now_ns":182450997838}'),
        \\ (2, 183077497201, '{"at_ns":157052964447,"now_ns":48148643824986}'),
        \\ (3, 739068000000, '{"at_ns":158928868225}'),
        \\ (4, 240140000000, '{}');
    );
    const Row = struct { n: i32, at_ns: ?u64 };
    const rows = try connection.rows(Row, arena, "SELECT n, " ++ at_ns_sql ++ " AS at_ns FROM typed ORDER BY n", .{});
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(@as(?u64, 138203038105), rows[0].at_ns);
    try testing.expectEqual(@as(?u64, 157052964447), rows[1].at_ns);
    try testing.expectEqual(@as(?u64, 158928868225), rows[2].at_ns);
    try testing.expectEqual(@as(?u64, null), rows[3].at_ns);
}

test "guidance that never moves across 8 timelines is stuck, moving or met guidance is not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec("CREATE TABLE events (branch UINTEGER, kind VARCHAR, event JSON)");
    try connection.exec("CREATE TABLE timelines (branch UINTEGER, extends UINTEGER)"); // No session's timeline here.
    try connection.exec(summaries_tables_sql);
    // "flat": distance 3 in all 8; "moving": 8 distances; "met": 0 in all 8; "few": 3 timelines;
    // an optimize bucket's value 5 in all 8.
    for (0..8) |branch| {
        const statement = try std.fmt.allocPrintSentinel(arena,
            \\INSERT INTO events VALUES
            \\ ({d}, 'guidance', '{{"guidance":{{"message":"flat","distance":3}}}}'),
            \\ ({d}, 'guidance', '{{"guidance":{{"message":"moving","distance":{d}}}}}'),
            \\ ({d}, 'guidance', '{{"guidance":{{"message":"met","distance":0}}}}'),
            \\ ({d}, 'optimize', '{{"optimize":{{"message":"backlog","bucket":"n1","value":5,"goal":"maximize"}}}}')
        , .{ branch, branch, branch, branch, branch }, 0);
        try connection.exec(statement);
    }
    for (0..3) |branch| {
        const statement = try std.fmt.allocPrintSentinel(arena,
            \\INSERT INTO events VALUES ({d}, 'guidance', '{{"guidance":{{"message":"few","distance":7}}}}')
        , .{branch}, 0);
        try connection.exec(statement);
    }
    try connection.exec(try scoped(arena, guidance_summary_sql, "TRUE")); // As each ingest does, of its timelines.
    const Row = struct { message: []const u8, stuck: bool };
    const rows = try connection.rows(Row, arena, "SELECT message, stuck FROM (" ++ guidance_stuck_sql ++ ") ORDER BY message", .{});
    try testing.expectEqual(5, rows.len);
    const expected = [_]Row{
        .{ .message = "backlog", .stuck = true },
        .{ .message = "few", .stuck = false },
        .{ .message = "flat", .stuck = true },
        .{ .message = "met", .stuck = false },
        .{ .message = "moving", .stuck = false },
    };
    for (expected, rows) |want, got| {
        try testing.expectEqualStrings(want.message, got.message);
        try testing.expectEqual(want.stuck, got.stuck);
    }
}
