// SPDX-License-Identifier: MIT
//! The race of examples/race in Zig, instrumented for coverage (the Zig SDK's callbacks, where
//! thread pausing pauses threads): 64 threads, each incrementing a shared counter if it is still
//! zero; a panic when all 64 did. Runs again and again in this process, printing every run's
//! counter (the same line each run: no hint for the explorer). In one process, as the Java and
//! Python races: Zig instruments its standard library too, and a fresh process a run reported
//! thousands of edges again each time (two runs a timeline).
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

comptime {
    _ = sdk.coverage;
}

const threads_count = 64;
var counter: u32 = 0;

/// C's `counter++` (no overflow check: Zig's would split the increment into blocks, and LLVM's
/// coverage pass would leave the block with the load without its callback, implied by those
/// after it). Built in Debug (build.zig), as race.cpp at -O0.
fn update() void {
    if (counter == 0) counter +%= 1;
}

fn run() u32 {
    counter = 0;
    var threads: [threads_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = std.Thread.spawn(.{}, update, .{}) catch @panic("a thread");
    for (threads) |thread| thread.join();
    if (counter == threads_count) @panic("all 64 threads incremented the counter");
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
