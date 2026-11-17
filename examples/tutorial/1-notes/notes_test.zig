// SPDX-License-Identifier: MIT
//! Tutorial 1 (docs/GETTING_STARTED.md): a small notes service tested under power losses.
//!
//! The system is one node, app/notes.py: it stores notes in one JSON file, rewritten through a
//! temporary file and a rename. The test adds notes from many drivers at once, remembers every
//! note the service acknowledged, and after the faults checks two things a user of any storage
//! service expects:
//!   - the service comes back after a power loss;
//!   - every note it acknowledged is still there.
//! Profiles:
//!   default   the service as written (nothing synced before the reply)
//!   durable   the fixes: the file synced before the rename and the directory after it; and
//!             Python told not to write bytecode as it runs (PYTHONDONTWRITEBYTECODE): its
//!             own .pyc files, written unsynced at a module's first import, can be left short
//!             by a power loss, and Python then refuses to start ("EOFError: marshal data too
//!             short", ai-analysis/cpython-3.12.16.md's 3.1), found again by this tutorial's
//!             first run on a fresh machine (2026-11-10)
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { app: sdk.Node };
const System = sdk.System(Nodes);

const port = 8080;
/// Where the drivers note what the service acknowledged: the runner's files outlive each
/// driver, so the final check reads all of them.
const acknowledged_path = "/tmp/notes-acknowledged";
const notes_per_driver = 5;
const back_attempts_max = 120;
const back_interval_ms = 500;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .notes = notes } });
}

fn describe(d: *System.Describe) !void {
    for ([_][]const u8{ "default", "durable" }) |name| {
        const profile = try d.profile(name);
        profile.node(.app, .{
            // Paths are relative to where determinismo runs (the repository's root).
            .build = .{ .context = "examples/tutorial/1-notes/app" },
            .ready = .{ .tcp = port },
            .env = if (std.mem.eql(u8, name, "durable")) &.{ "NOTES_DURABLE=1", "PYTHONDONTWRITEBYTECODE=1" } else &.{},
            // Power losses: the node's disk keeps what was synced and loses the rest, then the
            // node starts again. Pauses and network cuts stay on, as by default.
            .faults = .{ .crash = true },
        });
    }
}

fn notes(s: *System.Scenario) void {
    s.parallel_driver("add_notes", add_notes);
    s.eventually("all_notes_kept", all_notes_kept);
}

/// Adds a few notes and remembers each one the service acknowledged (a 200 reply).
fn add_notes(context: *System.Context) !void {
    for (0..notes_per_driver) |_| {
        // Ids unique across every driver of a timeline (40 bits: no two drivers draw the same).
        const id = sdk.random_below(1 << 40);
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/notes/{d}", .{id});
        var buffer: [4096]u8 = undefined;
        const response = sdk.tcp.http(context.nodes.app.address, port, "POST", path, "a note", &buffer) catch |err| {
            // Unreachable during a fault: not acknowledged, so nothing is promised.
            if (sdk.tcp.unavailable(err)) return;
            return err;
        };
        if (response.status != 200) continue;
        var line_buffer: [32]u8 = undefined;
        sdk.record_line(acknowledged_path, try std.fmt.bufPrint(&line_buffer, "{d}\n", .{id}));
        sdk.sometimes(true, "a note was acknowledged", .{});
    }
}

/// After the faults stop: the service answers again (within a minute: a node that lost power
/// is starting again), and lists every acknowledged note.
fn all_notes_kept(context: *System.Context) !void {
    var buffer: [1 << 20]u8 = undefined;
    var answered: ?sdk.tcp.Response = null;
    var last_error: []const u8 = "";
    for (0..back_attempts_max) |_| {
        answered = sdk.tcp.http(context.nodes.app.address, port, "GET", "/notes", "", &buffer) catch |err| {
            last_error = @errorName(err);
            sdk.sleep_ms(back_interval_ms);
            continue;
        };
        break;
    }
    const response = answered orelse {
        sdk.always(false, "the service comes back after the faults", .{ .@"error" = last_error });
        return;
    };
    sdk.always(response.status == 200, "the service comes back after the faults", .{ .status = response.status });
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const acknowledged = try sdk.file_read(arena_state.allocator(), acknowledged_path);
    var ids = std.mem.tokenizeScalar(u8, acknowledged, '\n');
    var checked: u32 = 0;
    while (ids.next()) |id| {
        const listed = line_present(response.body, id);
        sdk.always(listed, "every acknowledged note is still there", .{ .id = id });
        checked += 1;
    }
    sdk.sometimes(checked > 0, "acknowledged notes were checked", .{ .count = checked });
}

fn line_present(text: []const u8, line: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |candidate| if (std.mem.eql(u8, candidate, line)) return true;
    return false;
}
