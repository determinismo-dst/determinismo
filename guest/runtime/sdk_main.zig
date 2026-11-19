// SPDX-License-Identifier: MIT
//! det-sdk: the SDK's decisions and events from a shell, in the guest's runner (where the
//! platform's device is): a fault injector of a run's own written as a script (composer.zig's
//! /det/injectors), a driver in sh.
//!
//!   det-sdk decide <name> <option>...   prints the option chosen (a named decision: steerable,
//!                                       replayed)
//!   det-sdk random <name> <range>       prints a value below the range (named, as above)
//!   det-sdk event <name> [details JSON] an event in the timeline
//!
//! Its draws come from the timeline's randomness as any SDK's: deterministic, on the tape, a
//! strategy's to answer by their names.
const std = @import("std");
const sdk = @import("determinismo");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 3) usage();
    const verb = arguments[1];
    const name = arguments[2];
    var out: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out);
    if (std.mem.eql(u8, verb, "decide")) {
        if (arguments.len < 4) usage();
        const options = try arena.alloc([]const u8, arguments.len - 3);
        for (arguments[3..], options) |given, *option| option.* = given;
        const chosen = sdk.decide(name, options);
        try stdout.interface.print("{s}\n", .{options[chosen]});
        return stdout.interface.flush();
    }
    if (std.mem.eql(u8, verb, "random")) {
        if (arguments.len != 4) usage();
        const range = std.fmt.parseInt(u64, arguments[3], 10) catch usage();
        if (range == 0) usage();
        try stdout.interface.print("{d}\n", .{sdk.random_below_named(name, range)});
        return stdout.interface.flush();
    }
    if (std.mem.eql(u8, verb, "event")) {
        if (arguments.len > 4) usage();
        const details = if (arguments.len == 4) arguments[3] else "{}";
        // The details must be JSON (they go into the event as they are).
        _ = std.json.parseFromSliceLeaky(std.json.Value, arena, details, .{}) catch usage();
        sdk.event(name, sdk.RawJson{ .text = details });
        return;
    }
    usage();
}

fn usage() noreturn {
    std.debug.print("usage: det-sdk decide <name> <option>...\n" ++
        "       det-sdk random <name> <range>\n" ++
        "       det-sdk event <name> [details JSON]\n", .{});
    std.process.exit(2);
}
