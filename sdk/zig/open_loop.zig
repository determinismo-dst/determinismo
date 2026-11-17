// SPDX-License-Identifier: MIT
//! Open-loop load (docs/PLAN.md's M; Peter Alvaro's Bug Bash 2026 talk; Huang et al., OSDI 2022:
//! metastable failures). Drivers are closed-loop: each waits for its answer, so none offers more
//! than the system completes and no retry storm forms. Here requests arrive at a rate that does
//! not wait for answers, each client retrying by a policy: a trigger (a spike of load, a fault)
//! can push the system into a state that the offered load alone keeps it in once the trigger is
//! gone, timeouts and retries amplifying the work (requests "in orbit").
//!
//!   const load = sdk.open_loop.Load.draw("queue", .{ .base_milli = 500, .timeout_ms_min = 2000,
//!       .timeout_ms_max = 20_000 });
//!   const result = sdk.open_loop.run(client, Client.call, load);
//!   if (result.served_before()) sdk.always(result.recovered(60, 120, 80),
//!       "goodput recovers after a trigger", result.summary(&buffer));
//!
//! `call(context, timeout_ms)` makes one attempt and says how it ended. Each request is a thread
//! of its own (64 KiB of stack), at most `in_flight_max` at once: beyond, a request is counted
//! `unstarted`, the generator's limit and not the system's.
const std = @import("std");
const sdk = @import("determinismo.zig");
const linux = std.os.linux;

pub const Outcome = enum { done, refused, timed_out, failed };

/// How a client retries: a timeout at once (it already waited), a refusal or a failure after
/// `backoff_ms`, doubled each retry when exponential.
pub const Retry = struct {
    timeout_ms: u32,
    retries: u32,
    backoff_ms: u32,
    exponential: bool,

    /// The wait before attempt `attempt` (1 for the first retry) after `outcome`.
    pub fn wait_ms(retry: Retry, outcome: Outcome, attempt: u32) u64 {
        std.debug.assert(attempt >= 1);
        if (outcome == .timed_out or outcome == .done) return 0;
        if (!retry.exponential) return retry.backoff_ms;
        const shift: u6 = @intCast(@min(attempt - 1, 16));
        return @min(@as(u64, retry.backoff_ms) << shift, 60 * std.time.ms_per_s);
    }
};

pub const policies = [_][]const u8{ "none", "few", "storm", "exponential" };

/// The load's phases and its clients' retry policy: a base rate before and after a trigger, the
/// trigger a spike of it.
pub const Load = struct {
    /// Requests offered a second outside the trigger, in thousandths (500: one every 2 s).
    base_milli: u32,
    /// During the trigger, times the base rate.
    spike: u32,
    before_s: u32,
    trigger_s: u32,
    after_s: u32,
    retry: Retry,
    policy: []const u8,

    pub const Bounds = struct {
        base_milli: u32,
        timeout_ms_min: u32,
        timeout_ms_max: u32,
        after_s: u32 = 240,
    };

    /// Drawn per timeline, each a named draw (`<name>.spike`, `.trigger_s`, `.policy`,
    /// `.timeout_ms`; strategies steer them, replays repeat them): a spike of 2 to 8 times the
    /// base rate for 10 to 90 s after 30 s of the base rate, then `after_s` of it again; a policy
    /// of none (no retry), few (3 at once), storm (20 at once) or exponential (6, from 100 ms);
    /// the timeout between the bounds on a log scale.
    pub fn draw(name: []const u8, bounds: Bounds) Load {
        std.debug.assert(bounds.timeout_ms_min > 0 and bounds.timeout_ms_min <= bounds.timeout_ms_max);
        var buffer: [96]u8 = undefined;
        const spike: u32 = @intCast(2 + sdk.random_below_named(named(&buffer, name, "spike"), 7));
        const trigger_s: u32 = @intCast(10 + sdk.random_below_named(named(&buffer, name, "trigger_s"), 81));
        const policy = sdk.decide(named(&buffer, name, "policy"), &policies);
        const steps: u64 = 16;
        const step = sdk.random_below_named(named(&buffer, name, "timeout_ms"), steps + 1);
        const ratio = @as(f64, @floatFromInt(bounds.timeout_ms_max)) / @as(f64, @floatFromInt(bounds.timeout_ms_min));
        const timeout = @as(f64, @floatFromInt(bounds.timeout_ms_min)) *
            std.math.pow(f64, ratio, @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps)));
        const timeout_ms: u32 = @intFromFloat(@round(timeout));
        const retry: Retry = switch (policy) {
            0 => .{ .timeout_ms = timeout_ms, .retries = 0, .backoff_ms = 0, .exponential = false },
            1 => .{ .timeout_ms = timeout_ms, .retries = 3, .backoff_ms = 0, .exponential = false },
            2 => .{ .timeout_ms = timeout_ms, .retries = 20, .backoff_ms = 0, .exponential = false },
            else => .{ .timeout_ms = timeout_ms, .retries = 6, .backoff_ms = 100, .exponential = true },
        };
        return .{
            .base_milli = bounds.base_milli,
            .spike = spike,
            .before_s = 30,
            .trigger_s = trigger_s,
            .after_s = bounds.after_s,
            .retry = retry,
            .policy = policies[policy],
        };
    }

    fn total_s(load: Load) u32 {
        return load.before_s + load.trigger_s + load.after_s;
    }
};

fn named(buffer: []u8, name: []const u8, part: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}.{s}", .{ name, part }) catch name;
}

pub const seconds_max = 1024;
pub const in_flight_max = 1024;

const Counter = std.atomic.Value(u32);

/// What a load did: successes by the second they completed in (from the load's start), and each
/// attempt's outcome. Kept on the heap of `run`'s caller (a few KiB).
pub const Result = struct {
    load: Load,
    done_by_second: [seconds_max]Counter = @splat(.init(0)),
    offered: Counter = .init(0),
    attempts: Counter = .init(0),
    done: Counter = .init(0),
    refused: Counter = .init(0),
    timed_out: Counter = .init(0),
    failed: Counter = .init(0),
    gave_up: Counter = .init(0),
    unstarted: Counter = .init(0),
    in_flight: Counter = .init(0),
    start_ns: u64 = 0,

    /// Goodput a second in the `window_s` from `settle_s` after the trigger ended, against the
    /// system's own goodput a second before the trigger (the same base rate offered): at least
    /// `percent` of it. Judged against the system before, not the rate offered: a timeout drawn
    /// under what a request takes fails every request before the trigger and after alike, which
    /// is no metastable failure. True when nothing succeeded before (see `served_before`).
    pub fn recovered(result: *const Result, settle_s: u32, window_s: u32, percent: u32) bool {
        const before = result.goodput(0, result.load.before_s);
        if (before == 0) return true;
        const after = result.goodput(result.load.before_s + result.load.trigger_s + settle_s, window_s);
        // after / window_s >= percent% of before / before_s, in integers.
        return @as(u64, after) * result.load.before_s * 100 >= @as(u64, before) * window_s * percent;
    }

    /// Whether the system served the base rate before the trigger at all: the recovery judgment
    /// means something only then.
    pub fn served_before(result: *const Result) bool {
        return result.goodput(0, result.load.before_s) > 0;
    }

    /// Successes completed in the `window_s` seconds from second `from` of the load.
    pub fn goodput(result: *const Result, from: u32, window_s: u32) u32 {
        var sum: u32 = 0;
        for (@min(from, seconds_max)..@min(from + window_s, seconds_max)) |second| sum += result.done_by_second[second].load(.acquire);
        return sum;
    }

    pub const Summary = struct {
        policy: []const u8,
        timeout_ms: u32,
        retries: u32,
        spike: u32,
        trigger_s: u32,
        offered: u32,
        attempts: u32,
        done: u32,
        refused: u32,
        timed_out: u32,
        failed: u32,
        gave_up: u32,
        unstarted: u32,
        /// Successes in each 10 s from the load's start.
        goodput_by_10s: []const u32,
    };

    /// The load and its counts, for an assertion's details (`buffer` holds the goodput series).
    pub fn summary(result: *const Result, buffer: []u32) Summary {
        const tens = @min(buffer.len, (result.load.total_s() + 9) / 10);
        for (0..tens) |ten| {
            var sum: u32 = 0;
            for (ten * 10..@min(ten * 10 + 10, seconds_max)) |second| sum += result.done_by_second[second].load(.acquire);
            buffer[ten] = sum;
        }
        return .{
            .policy = result.load.policy,
            .timeout_ms = result.load.retry.timeout_ms,
            .retries = result.load.retry.retries,
            .spike = result.load.spike,
            .trigger_s = result.load.trigger_s,
            .offered = result.offered.load(.acquire),
            .attempts = result.attempts.load(.acquire),
            .done = result.done.load(.acquire),
            .refused = result.refused.load(.acquire),
            .timed_out = result.timed_out.load(.acquire),
            .failed = result.failed.load(.acquire),
            .gave_up = result.gave_up.load(.acquire),
            .unstarted = result.unstarted.load(.acquire),
            .goodput_by_10s = buffer[0..tens],
        };
    }
};

/// Offers `load` to `call` (one attempt: `call(context, timeout_ms)`), then waits for the
/// requests still in flight (each bounded by its timeouts and waits). `context` is copied into
/// each request's thread.
pub fn run(context: anytype, comptime call: fn (@TypeOf(context), u32) Outcome, load: Load, result: *Result) void {
    std.debug.assert(load.total_s() < seconds_max);
    std.debug.assert(load.base_milli > 0 and load.spike >= 1);
    result.* = .{ .load = load, .start_ns = now_ns() };
    sdk.event("open_loop", .{
        .policy = load.policy,
        .timeout_ms = load.retry.timeout_ms,
        .retries = load.retry.retries,
        .base_milli = load.base_milli,
        .spike = load.spike,
        .trigger_s = load.trigger_s,
    });
    const Client = struct {
        fn request(client_context: @TypeOf(context), shared: *Result, retry: Retry) void {
            defer _ = shared.in_flight.fetchSub(1, .acq_rel);
            var attempt: u32 = 0;
            while (true) : (attempt += 1) {
                _ = shared.attempts.fetchAdd(1, .acq_rel);
                const outcome = call(client_context, retry.timeout_ms);
                switch (outcome) {
                    .done => {
                        _ = shared.done.fetchAdd(1, .acq_rel);
                        const second = (now_ns() - shared.start_ns) / std.time.ns_per_s;
                        if (second < seconds_max) _ = shared.done_by_second[second].fetchAdd(1, .acq_rel);
                        return;
                    },
                    .refused => _ = shared.refused.fetchAdd(1, .acq_rel),
                    .timed_out => _ = shared.timed_out.fetchAdd(1, .acq_rel),
                    .failed => _ = shared.failed.fetchAdd(1, .acq_rel),
                }
                if (attempt == retry.retries) {
                    _ = shared.gave_up.fetchAdd(1, .acq_rel);
                    return;
                }
                const wait = retry.wait_ms(outcome, attempt + 1);
                if (wait > 0) sdk.sleep_ms(wait);
            }
        }
    };
    const phases = [_]struct { seconds: u32, milli: u64 }{
        .{ .seconds = load.before_s, .milli = load.base_milli },
        .{ .seconds = load.trigger_s, .milli = @as(u64, load.base_milli) * load.spike },
        .{ .seconds = load.after_s, .milli = load.base_milli },
    };
    for (phases) |phase| {
        const gap_ns = std.time.ns_per_s * 1000 / phase.milli;
        const end_ns = now_ns() + @as(u64, phase.seconds) * std.time.ns_per_s;
        var next_ns = now_ns();
        while (next_ns < end_ns) : (next_ns += gap_ns) {
            sleep_until(next_ns);
            _ = result.offered.fetchAdd(1, .acq_rel);
            if (result.in_flight.load(.acquire) >= in_flight_max) {
                _ = result.unstarted.fetchAdd(1, .acq_rel);
                continue;
            }
            _ = result.in_flight.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Client.request, .{ context, result, load.retry }) catch {
                _ = result.in_flight.fetchSub(1, .acq_rel);
                _ = result.unstarted.fetchAdd(1, .acq_rel);
                continue;
            };
            thread.detach();
        }
        sleep_until(end_ns);
    }
    // The requests still in flight: each ends within its attempts' timeouts and waits.
    while (result.in_flight.load(.acquire) > 0) sdk.sleep_ms(100);
}

/// Closed-loop throughput, for a base rate the system can serve (one vCPU runs the system and the
/// generator both: measured per timeline, not assumed): `clients` threads calling back to back
/// for `seconds`; completions a second, in thousandths.
pub fn capacity_milli(context: anytype, comptime call: fn (@TypeOf(context), u32) Outcome, clients: u32, seconds: u32, timeout_ms: u32) u32 {
    std.debug.assert(clients > 0 and clients <= 64 and seconds > 0);
    var done = Counter.init(0);
    const end_ns = now_ns() + @as(u64, seconds) * std.time.ns_per_s;
    const Client = struct {
        fn loop(client_context: @TypeOf(context), count: *Counter, until_ns: u64, timeout: u32) void {
            while (now_ns() < until_ns) {
                if (call(client_context, timeout) == .done) _ = count.fetchAdd(1, .acq_rel) else sdk.sleep_ms(10);
            }
        }
    };
    var threads: [64]std.Thread = undefined;
    var started: usize = 0;
    for (0..clients) |_| {
        threads[started] = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Client.loop, .{ context, &done, end_ns, timeout_ms }) catch break;
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    const milli: u32 = @intCast(@as(u64, done.load(.acquire)) * 1000 / seconds);
    sdk.event("open_loop_capacity", .{ .clients = started, .seconds = seconds, .per_second_milli = milli });
    return milli;
}

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now); // Virtual time inside determinismo.
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_until(deadline_ns: u64) void {
    const now = now_ns();
    if (now >= deadline_ns) return;
    const wait = deadline_ns - now;
    const request = linux.timespec{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) };
    _ = linux.nanosleep(&request, null);
}

test "a retry waits after refusals, at once after timeouts, doubling when exponential" {
    const plain: Retry = .{ .timeout_ms = 1000, .retries = 3, .backoff_ms = 250, .exponential = false };
    try std.testing.expectEqual(@as(u64, 250), plain.wait_ms(.refused, 1));
    try std.testing.expectEqual(@as(u64, 250), plain.wait_ms(.failed, 3));
    try std.testing.expectEqual(@as(u64, 0), plain.wait_ms(.timed_out, 2));
    const exponential: Retry = .{ .timeout_ms = 1000, .retries = 6, .backoff_ms = 100, .exponential = true };
    try std.testing.expectEqual(@as(u64, 100), exponential.wait_ms(.refused, 1));
    try std.testing.expectEqual(@as(u64, 400), exponential.wait_ms(.refused, 3));
    try std.testing.expectEqual(@as(u64, 60_000), exponential.wait_ms(.refused, 30));
}

test "recovery judges goodput after the trigger against goodput before it" {
    var result: Result = .{ .load = .{
        .base_milli = 500,
        .spike = 4,
        .before_s = 30,
        .trigger_s = 60,
        .after_s = 240,
        .retry = .{ .timeout_ms = 8000, .retries = 20, .backoff_ms = 1000, .exponential = false },
        .policy = "storm",
    } };
    // Nothing served before the trigger: nothing to judge.
    try std.testing.expect(!result.served_before());
    try std.testing.expect(result.recovered(60, 120, 80));
    // Before: one success every 2 s (15 in 30 s). From 60 s to 180 s after the trigger, the same
    // rate (60 in 120 s): recovered.
    var second: usize = 0;
    while (second < 30) : (second += 2) result.done_by_second[second].store(1, .release);
    second = 150;
    while (second < 270) : (second += 2) result.done_by_second[second].store(1, .release);
    try std.testing.expect(result.served_before());
    try std.testing.expectEqual(@as(u32, 60), result.goodput(150, 120));
    try std.testing.expect(result.recovered(60, 120, 80));
    // A fifth of it: collapsed.
    for (result.done_by_second[30..]) |*counter| counter.store(0, .release);
    second = 150;
    while (second < 270) : (second += 10) result.done_by_second[second].store(1, .release);
    try std.testing.expect(!result.recovered(60, 120, 80));
    var buffer: [40]u32 = undefined;
    const summary = result.summary(&buffer);
    try std.testing.expectEqual(@as(usize, 33), summary.goodput_by_10s.len);
    try std.testing.expectEqual(@as(u32, 1), summary.goodput_by_10s[15]);
}

test "capacity counts closed-loop completions a second" {
    const Fake = struct {
        fn call(fake: void, timeout_ms: u32) Outcome {
            _ = fake;
            _ = timeout_ms;
            sdk.sleep_ms(10);
            return .done;
        }
    };
    // 4 clients, each about 100 a second.
    const milli = capacity_milli({}, Fake.call, 4, 1, 1000);
    try std.testing.expect(milli >= 300_000 and milli <= 410_000);
}

test "a load offers its phases' rates and every request ends" {
    const Fake = struct {
        calls: *std.atomic.Value(u32),
        fn call(fake: @This(), timeout_ms: u32) Outcome {
            _ = timeout_ms;
            // Every third attempt refused: retried after the backoff, then done.
            return if (fake.calls.fetchAdd(1, .acq_rel) % 3 == 2) .refused else .done;
        }
    };
    var calls = std.atomic.Value(u32).init(0);
    const result = try std.testing.allocator.create(Result);
    defer std.testing.allocator.destroy(result);
    run(Fake{ .calls = &calls }, Fake.call, .{
        .base_milli = 20_000,
        .spike = 2,
        .before_s = 1,
        .trigger_s = 1,
        .after_s = 1,
        .retry = .{ .timeout_ms = 100, .retries = 2, .backoff_ms = 10, .exponential = false },
        .policy = "few",
    }, result);
    // 20 a second for 2 s and 40 for 1: 80, give or take the phases' edges.
    const offered = result.offered.load(.acquire);
    try std.testing.expect(offered >= 76 and offered <= 84);
    try std.testing.expectEqual(offered, result.done.load(.acquire) + result.gave_up.load(.acquire) + result.unstarted.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), result.in_flight.load(.acquire));
    try std.testing.expectEqual(calls.load(.acquire), result.attempts.load(.acquire));
}
