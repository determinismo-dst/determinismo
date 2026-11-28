// SPDX-License-Identifier: MIT
//! The race of examples/race reduced to two threads and split at its decision: `check` reads the
//! counter, `act` increments it, each its own function. Run again and again in this process, each
//! run printing its counter; a panic when both threads incremented (both checked a zero). Blind,
//! nearly never: one thread's whole update fits in a slice of the scheduler's. With both threads
//! held at `act` until both have checked (race_test.zig's scenario `held`: `det-nodes hold
//! <node> race_held.act --every`), then let go: both increment, every time. A third thread
//! signals the workers every millisecond (SIGURG, handled by a no-op), as Go's runtime preempts
//! a goroutine that runs long: a thread held for a while has a signal pending when let go
//! (race_test.zig's scenario `held_release`, held at `check`).
const std = @import("std");
const linux = std.os.linux;

const threads_count = 2;
var counter: u32 = 0;
/// The workers' thread ids while they run, for the signaller.
var worker_tids: [threads_count]std.atomic.Value(i32) = .{ .init(0), .init(0) };

noinline fn check() bool {
    return @as(*volatile u32, &counter).* == 0;
}

noinline fn act() void {
    const shared: *volatile u32 = &counter;
    shared.* = shared.* +% 1;
}

fn update(slot: usize) void {
    worker_tids[slot].store(linux.gettid(), .release);
    defer worker_tids[slot].store(0, .release);
    const zero = check();
    if (zero) {
        // A thread here saw a zero and has not incremented yet: race_test.zig's `held_line`
        // holds both here, `race_held.update@race_held.zig:36` (this call's line: keep it
        // there), a point inside a function between its test and its act.
        act();
    }
}

fn on_urgent(_: linux.SIG) callconv(.c) void {}

/// Each running worker signalled every millisecond, as Go's sysmon signals a goroutine's thread.
fn signal_workers() void {
    const pid = linux.getpid();
    while (true) {
        for (&worker_tids) |*slot| {
            const tid = slot.load(.acquire);
            if (tid != 0) _ = linux.tgkill(pid, tid, .URG);
        }
        var delay: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&delay, null);
    }
}

fn run() u32 {
    counter = 0;
    var threads: [threads_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, slot| thread.* = std.Thread.spawn(.{}, update, .{slot}) catch @panic("a thread");
    for (threads) |thread| thread.join();
    if (counter == threads_count) @panic("both threads incremented the counter");
    return counter;
}

pub fn main() void {
    const urgent: linux.Sigaction = .{ .handler = .{ .handler = on_urgent }, .mask = linux.sigemptyset(), .flags = linux.SA.RESTART };
    _ = linux.sigaction(.URG, &urgent, null);
    const signaller = std.Thread.spawn(.{}, signal_workers, .{}) catch @panic("a thread");
    signaller.detach();
    var runs: u64 = 1;
    while (true) : (runs += 1) {
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "run {d}: counter {d}\n", .{ runs, run() }) catch unreachable;
        _ = linux.write(1, text.ptr, text.len);
    }
}
