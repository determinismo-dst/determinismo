// SPDX-License-Identifier: MIT
//! The race of examples/race reduced to two threads and split at its decision: `check` reads the
//! counter, `act` increments it, each its own function. Run again and again in this process, each
//! run printing its counter; a panic when both threads incremented (both checked a zero). Blind,
//! nearly never: one thread's whole update fits in a slice of the scheduler's. With both threads
//! held at `act` until both have checked (race_test.zig's scenario `held`: `det-nodes hold
//! <node> race_held.act --every`), then let go: both increment, every time.
const std = @import("std");
const linux = std.os.linux;

const threads_count = 2;
var counter: u32 = 0;

noinline fn check() bool {
    return @as(*volatile u32, &counter).* == 0;
}

noinline fn act() void {
    const shared: *volatile u32 = &counter;
    shared.* = shared.* +% 1;
}

fn update() void {
    if (check()) act();
}

fn run() u32 {
    counter = 0;
    var threads: [threads_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = std.Thread.spawn(.{}, update, .{}) catch @panic("a thread");
    for (threads) |thread| thread.join();
    if (counter == threads_count) @panic("both threads incremented the counter");
    return counter;
}

pub fn main() void {
    var runs: u64 = 1;
    while (true) : (runs += 1) {
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "run {d}: counter {d}\n", .{ runs, run() }) catch unreachable;
        _ = linux.write(1, text.ptr, text.len);
    }
}
