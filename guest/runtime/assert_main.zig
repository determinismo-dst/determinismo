// SPDX-License-Identifier: MIT
//! det-assert: a property stated from a shell, in the guest's runner (where the platform's
//! device is): a CI shard's verdict (docs/PRODUCTS.md), a script's own check.
//!
//!   det-assert always|sometimes|reachable <message> <true|false|0|status> [details JSON]
//!   det-assert junit <report.xml>
//!
//! `junit`: each test of a JUnit XML report an always property of its own, "test passes: <its
//! class and name>", false when it failed or errored (its message in the details' `said`):
//! a test suite's tests judged across timelines as any property (determinismo-ci).
//!
//! The condition is true for `true` or `0` (an exit status: success), false otherwise. The
//! message is the property's name across timelines, as an SDK's assertion's.
const std = @import("std");
const sdk = @import("determinismo");
const junit = @import("junit.zig");

pub const test_prefix = "test passes: ";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "junit")) return junit_assert(arena, init.io, arguments[2]);
    if (arguments.len < 4 or arguments.len > 5) usage();
    const kind = std.meta.stringToEnum(sdk.Kind, arguments[1]) orelse usage();
    const given = arguments[3];
    const condition = std.mem.eql(u8, given, "true") or std.mem.eql(u8, given, "0");
    const details = if (arguments.len == 5) arguments[4] else "{}";
    // The details must be JSON (they go into the event as they are).
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, details, .{}) catch usage();
    sdk.assert_computed(kind, condition, arguments[2], sdk.RawJson{ .text = details });
}

fn junit_assert(arena: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const report = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20));
    const found = try junit.cases(arena, report);
    if (found.len == 0) {
        std.debug.print("det-assert junit: no test cases in {s}\n", .{path});
        std.process.exit(1);
    }
    for (found) |case| {
        const message = try std.fmt.allocPrint(arena, test_prefix ++ "{s}", .{case.name});
        // The whole message: the SDK cuts details that don't fit an event (~4 KB) itself, marked
        // as cut. A cap of 500 here lost generated cases' forms and C++ (run 1896's native
        // operator failure, its case unreadable).
        sdk.assert_computed(.always, !case.failed, message, .{ .said = case.message });
    }
}

fn usage() noreturn {
    std.debug.print("usage: det-assert always|sometimes|reachable <message> <true|false|0|status> [details JSON]\n" ++
        "       det-assert junit <report.xml>\n", .{});
    std.process.exit(2);
}
