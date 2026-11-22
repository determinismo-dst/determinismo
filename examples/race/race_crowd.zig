// SPDX-License-Identifier: MIT
//! Threads at one function with arguments a hold lets go, beside threads with the one it holds
//! (race_test.zig's scenario `held_crowd`). Three threads call `visit` with their own ids again
//! and again; once a hold's breakpoint is in `visit` (its first byte reads int3), eight more
//! call it with 1000, each after a delay of its own drawn up to `spread_ms` (the timeline's
//! randomness), so they come while the three step past it. Held with `--arg rdi=0x3e8 --every`,
//! the eight stop at its entry. Before det-nodes hold stopped a process's other threads during
//! a step past an entry (the entry's byte restored for one instruction), a thread could pass the
//! entry then, unseen: the Raft PoC walk's vote request to C (jtl-data run 14: 10 of the 86 walks
//! with a whole record).
//! Released on the breakpoint, not on the tracer: TracerPid turns nonzero as the hold seizes the
//! process's first thread, before the byte is written, and eight threads let go then passed
//! `visit` on its original byte, none held, with or without the fix.
const std = @import("std");
const linux = std.os.linux;

const busy_count = 3;
const marked_count = 8;
const marked_id = 1000;
/// x86-64's breakpoint instruction, as a hold writes it over a point's entry.
const int3 = 0xcc;
/// The marked threads' arrivals spread over this long: let go at once, the eight reached the
/// entry within microseconds, before any of the three stepped past it, and all were held with
/// or without the fix.
const spread_ms = 300;

var last: u64 = 0;
/// The round the marked threads may go in: one a hold.
var round: std.atomic.Value(u32) = .init(0);

noinline fn visit(id: u64) callconv(.c) void {
    @as(*volatile u64, &last).* = id;
}

fn busy(id: u64) void {
    while (true) {
        visit(id);
        _ = linux.sched_yield();
    }
}

fn marked(at: u32) void {
    while (round.load(.acquire) < at) {
        _ = linux.futex_4arg(&round.raw, .{ .cmd = .WAIT, .private = true }, at - 1, null);
    }
    var drawn: [8]u8 = undefined;
    _ = linux.getrandom(&drawn, drawn.len, 0);
    sleep_ms(std.mem.readInt(u64, &drawn, .little) % spread_ms);
    visit(marked_id);
}

/// Whether a hold's breakpoint is in `visit`: its first byte, read through this process's own
/// mapping of the code (the tracer's write made the page this process's copy).
fn breakpoint_in() bool {
    const entry: *const volatile u8 = @ptrFromInt(@intFromPtr(&visit));
    return entry.* == int3;
}

fn sleep_ms(ms: u64) void {
    var delay: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&delay, null);
}

pub fn main() void {
    for (0..busy_count) |index| {
        const thread = std.Thread.spawn(.{}, busy, .{@as(u64, index + 1)}) catch @panic("a thread");
        thread.detach();
    }
    var at: u32 = 1;
    while (true) : (at += 1) {
        var threads: [marked_count]std.Thread = undefined;
        for (&threads) |*thread| thread.* = std.Thread.spawn(.{}, marked, .{at}) catch @panic("a thread");
        while (!breakpoint_in()) sleep_ms(5);
        round.store(at, .release);
        _ = linux.futex_3arg(&round.raw, .{ .cmd = .WAKE, .private = true }, marked_count);
        for (threads) |thread| thread.join();
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "round {d}\n", .{at}) catch unreachable;
        _ = linux.write(1, text.ptr, text.len);
        // The next round once this hold is gone (its byte restored as it lets go).
        while (breakpoint_in()) sleep_ms(5);
    }
}
