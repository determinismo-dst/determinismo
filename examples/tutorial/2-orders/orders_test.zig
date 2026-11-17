// SPDX-License-Identifier: MIT
//! Tutorial 2 (docs/GETTING_STARTED.md): an order service of three parts (an API, two workers,
//! PostgreSQL), tested under process kills, pauses and network faults.
//!
//! The API takes orders; the workers charge them (app/orders.py). Two properties any team
//! running such a service would sign:
//!   - no order is charged twice;
//!   - every order the API accepted is charged, once the faults are over;
//!   - and, beneath them, the API answers again once the faults are over.
//! Profiles:
//!   default   the workers as written (four statements, each committed on its own)
//!   safe      the fixes: claimed with FOR UPDATE SKIP LOCKED, charged in the claim's transaction,
//!             connections with keepalives and timeouts
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { db: sdk.Node, api: sdk.Node, @"worker-a": sdk.Node, @"worker-b": sdk.Node };
const System = sdk.System(Nodes);

const api_port = 8080;
const accepted_path = "/tmp/orders-accepted";
const orders_per_driver = 4;
/// How long the workers have to catch up once the faults are over (virtual time).
const drain_attempts_max = 120;
const drain_interval_ms = 500;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .orders = orders } });
}

fn describe(d: *System.Describe) !void {
    for ([_][]const u8{ "default", "safe" }) |name| {
        const safe = std.mem.eql(u8, name, "safe");
        const profile = try d.profile(name);
        profile.node(.db, .{
            .image = "docker.io/library/postgres:17",
            .env = &.{"POSTGRES_HOST_AUTH_METHOD=trust"},
            .ready = .{ .tcp = 5432 },
        });
        const app: System.Spec = .{ .build = .{ .context = "examples/tutorial/2-orders/app" } };
        var api = app;
        api.env = if (safe) &.{ "ROLE=api", "ORDERS_SAFE=1" } else &.{"ROLE=api"};
        api.ready = .{ .tcp = api_port };
        api.after = &.{.db};
        profile.node(.api, api);
        var worker = app;
        worker.env = if (safe) &.{ "ROLE=worker", "ORDERS_SAFE=1" } else &.{"ROLE=worker"};
        worker.after = &.{.db};
        // A worker may be killed and started again, anywhere in its loop.
        worker.faults = .{ .restart = true };
        profile.node(.@"worker-a", worker);
        profile.node(.@"worker-b", worker);
    }
}

fn orders(s: *System.Scenario) void {
    s.parallel_driver("place_orders", place_orders);
    s.eventually("orders_charged_once", orders_charged_once);
}

/// Places a few orders and remembers the ones the API accepted.
fn place_orders(context: *System.Context) !void {
    for (0..orders_per_driver) |_| {
        var buffer: [256]u8 = undefined;
        const response = sdk.tcp.http(context.nodes.api.address, api_port, "POST", "/orders", "", &buffer) catch |err| {
            if (sdk.tcp.unavailable(err)) return;
            return err;
        };
        if (response.status != 200) continue;
        const id = std.mem.trim(u8, response.body, " \n");
        var line_buffer: [32]u8 = undefined;
        sdk.record_line(accepted_path, try std.fmt.bufPrint(&line_buffer, "{s}\n", .{id}));
        sdk.sometimes(true, "an order was accepted", .{});
    }
}

/// After the faults: the workers get time to catch up, then every accepted order must be
/// charged, and none twice.
fn orders_charged_once(context: *System.Context) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const accepted = try sdk.file_read(arena_state.allocator(), accepted_path);
    var buffer: [1 << 20]u8 = undefined;
    var report: []const u8 = "";
    var answered = false;
    for (0..drain_attempts_max) |_| {
        const response = sdk.tcp.http(context.nodes.api.address, api_port, "GET", "/report", "", &buffer) catch {
            sdk.sleep_ms(drain_interval_ms);
            continue;
        };
        if (response.status == 200) {
            answered = true;
            report = response.body;
            if (all_charged(report, accepted)) break;
        }
        sdk.sleep_ms(drain_interval_ms);
    }
    // An API that never answers again is a failure of its own (a connection waiting forever on
    // a peer a network cut took away), not orders lost: nothing about them is known then.
    sdk.always(answered, "the API answers again after the faults", .{});
    if (!answered) return;
    var ids = std.mem.tokenizeScalar(u8, accepted, '\n');
    while (ids.next()) |id| {
        const row = row_of(report, id);
        const charges = if (row) |line| charges_of(line) else 0;
        sdk.always(charges <= 1, "no order is charged twice", .{ .order = id, .charges = charges });
        sdk.always(charges >= 1, "every accepted order is charged", .{ .order = id, .row = row orelse "missing" });
    }
}

fn all_charged(report: []const u8, accepted: []const u8) bool {
    var ids = std.mem.tokenizeScalar(u8, accepted, '\n');
    while (ids.next()) |id| {
        const row = row_of(report, id) orelse return false;
        if (charges_of(row) == 0) return false;
    }
    return true;
}

/// The report's line for order `id` ("<id> <status> <charges>").
fn row_of(report: []const u8, id: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (std.mem.eql(u8, words.next() orelse continue, id)) return line;
    }
    return null;
}

fn charges_of(row: []const u8) u64 {
    var words = std.mem.tokenizeScalar(u8, row, ' ');
    _ = words.next();
    _ = words.next();
    return std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch 0;
}
