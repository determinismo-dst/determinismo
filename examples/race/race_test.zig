// SPDX-License-Identifier: MIT
//! Example test program: the 64-thread check-then-act race of "Hillel joins Antithesis"
//! (examples/race/race.cpp). One node runs the program again and again, each run a fresh process
//! whose own assert fails when all 64 threads incremented the counter: the abort fails "no process
//! crashes: race". Blind: no assertion or guidance beyond that assert.
//!
//! A single process's behavior varies with scheduling alone: the faults are the interleave fault
//! (the guest scheduler's choices drawn), pauses of the process or of one of its threads, and CPU
//! throttling. Profile `instrumented`: the program built for coverage, as Antithesis's thread
//! pausing needs, which then pauses threads at its edges (the C SDK's callbacks). Profile `go`:
//! the race in Go (examples/race/go) built with the Go SDK's instrumentation
//! (determinismo-toolexec), thread pausing pausing goroutines. Profile `java`: the race in Java
//! (examples/race/java) under the JVM SDK's coverage agent. Profile `python`: the race in Python
//! (examples/race/python) under the Python SDK's coverage. Profile `javascript`: the race in
//! Node.js worker threads (examples/race/javascript) under the JavaScript SDK's coverage, thread
//! pausing pausing them through the inspector. Profile `dotnet`: the race in C#
//! (examples/race/dotnet), instrumented after its build by determinismo-dotnet-instrument.
//! Profile `rust`: the race in Rust
//! (examples/race/rust) with rustc's trace-pc-guard and the Rust SDK's callbacks. Profile `zig`:
//! the race in Zig (examples/race/race.zig) with Zig's trace-pc-guard and the Zig SDK's.
//!
//!   determinismo explore ... --program zig-out/bin/race-test --scenario race
//!     [--profile instrumented|go|java|python|javascript|dotnet|rust|zig]
const std = @import("std");
const sdk = @import("determinismo");
const linux = std.os.linux;

const Nodes = struct { race: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .race = race, .held = held, .held_release = held_release, .held_later = held_later } });
}

fn describe(d: *System.Describe) !void {
    const faults: sdk.schema.Faults = .{
        .isolate = false,
        .partition = false,
        .degrade = false,
        .sync_stall = false,
    };
    const plain = try d.profile("default");
    plain.node(.race, .{ .binary = "zig-out/bin/race", .faults = faults });
    const instrumented = try d.profile("instrumented");
    instrumented.node(.race, .{ .binary = "zig-out/bin/race-instrumented", .faults = faults });
    // The same build with a coverage set no edge is in (an include no source file starts with,
    // and an edge whose line is unknown has the empty name): no coverage, no thread pausing
    // (e2e `coverage-set`).
    const uncovered = try d.profile("instrumented-uncovered");
    uncovered.node(.race, .{
        .binary = "zig-out/bin/race-instrumented",
        .faults = faults,
        .coverage = .{ .include = &.{"/nothing/"} },
    });
    const go = try d.profile("go");
    go.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.go" },
        .faults = faults,
    });
    const java = try d.profile("java");
    java.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.java" },
        .faults = faults,
    });
    const python = try d.profile("python");
    python.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.python" },
        .faults = faults,
    });
    const javascript = try d.profile("javascript");
    javascript.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.javascript" },
        .faults = faults,
    });
    const dotnet = try d.profile("dotnet");
    dotnet.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.dotnet" },
        .faults = faults,
    });
    const rust = try d.profile("rust");
    rust.node(.race, .{
        .build = .{ .context = ".", .dockerfile = "examples/race/Dockerfile.rust" },
        .faults = faults,
    });
    const zig = try d.profile("zig");
    zig.node(.race, .{ .binary = "zig-out/bin/race-zig", .faults = faults });
    // The two-thread race (examples/race/race_held.zig) for scenario `held`: no fault drawn,
    // its threads ordered by Node.hold alone.
    const held_profile = try d.profile("held");
    held_profile.node(.race, .{ .binary = "zig-out/bin/race-held", .faults = faults });
}

/// Scenario `held` (profile `held`): Node.hold on `race_held.act`, every thread that enters it
/// held until both of a run's threads did, then all let go: both checked a zero, both
/// increment, and the program panics, in every timeline. The platform's control for a race
/// inside a process (det-nodes hold), where blind exploration nearly never finds it.
fn held(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("hold", hold_both);
}

fn hold_both(context: *System.Context) !void {
    sdk.sleep_ms(200 + sdk.random_below(800));
    const hold = try context.nodes.race.hold(&.{ "race_held.act", "--every" }, 10_000);
    if (!hold.armed()) {
        hold.release();
        return error.NotArmed;
    }
    const first = hold.held(0);
    const second = first and hold.held(0);
    hold.release();
    sdk.event("race_held", .{ .first = first, .second = second });
    // The program's run goes on from the threads' release to its check (and panic) within the
    // timeline: a driver that returned at once ended it first.
    sdk.sleep_ms(1000);
}

/// Scenario `held_release` (profile `held`): Node.hold on `race_held.check` with `--repeat`, its
/// first thread let go alone (release_point) with a signal pending (race_held.zig's signaller,
/// as Go's preemption): that thread finishes its run (it checks after the other incremented: no
/// race), the program's next runs enter `check` again, and the point holds another thread. Back at the entry from its signal handler, the
/// first was held again instead (det-nodes hold's step over the entry went into the handler):
/// its run never ended, and no other thread came (a hashicorp/raft walk's late write never
/// landed: two_leaders_trace's step 8).
fn held_release(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("hold", hold_release_one);
}

/// The next thread held at point 0 in the hold's lines (`{"held":<tid>,"point":0}`); null at
/// their end.
fn held_thread(hold: anytype) ?i64 {
    while (true) {
        var buffer: [256]u8 = undefined;
        var size: usize = 0;
        while (size < buffer.len) {
            const result = linux.read(hold.output, buffer[size..].ptr, 1);
            if (linux.errno(result) != .SUCCESS or result == 0) break;
            if (buffer[size] == '\n') break;
            size += 1;
        }
        const said = buffer[0..size];
        if (said.len == 0 or std.mem.startsWith(u8, said, "{\"held\":null")) return null;
        const prefix = "{\"held\":";
        const suffix = ",\"point\":0}";
        if (!std.mem.startsWith(u8, said, prefix) or !std.mem.endsWith(u8, said, suffix)) continue;
        return std.fmt.parseInt(i64, said[prefix.len .. said.len - suffix.len], 10) catch continue;
    }
}

fn hold_release_one(context: *System.Context) !void {
    sdk.sleep_ms(200 + sdk.random_below(800));
    const hold = try context.nodes.race.hold(&.{ "race_held.check", "--repeat" }, 10_000);
    if (!hold.armed()) {
        hold.release();
        return error.NotArmed;
    }
    const first = held_thread(hold);
    // Held a while (signals pending), then let go alone.
    sdk.sleep_ms(100);
    if (first != null) hold.release_point(0);
    sdk.sleep_ms(2000);
    // Stopped, its lines read to their end: another thread held, or the first again, or none.
    _ = linux.kill(hold.pid, .TERM);
    var again: ?i64 = null;
    var first_again = false;
    while (held_thread(hold)) |tid| {
        if (first != null and tid == first.?) {
            first_again = true;
            continue;
        }
        again = tid;
        break;
    }
    hold.release();
    sdk.event("race_held_release", .{ .first = first, .again = again, .first_again = first_again });
    sdk.always(first != null and again != null, "a hold point let go alone holds the next thread", .{ .first = first, .first_again = first_again });
}

/// Scenario `held_later` (profile `held`): Node.hold on `race_held.check` with `--later`: no
/// thread held while its point waits (the program's runs go on), then `arm 0`, and the next
/// thread that checks is held. One hold a process, its points armed as a walk needs them.
fn held_later(s: *System.Scenario) void {
    s.faults = false;
    s.singleton_driver("hold", hold_later_armed);
}

/// The hold's next line; empty at its end.
fn hold_line(hold: anytype, buffer: []u8) []const u8 {
    var size: usize = 0;
    while (size < buffer.len) {
        const result = linux.read(hold.output, buffer[size..].ptr, 1);
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        if (buffer[size] == '\n') break;
        size += 1;
    }
    return buffer[0..size];
}

fn hold_later_armed(context: *System.Context) !void {
    sdk.sleep_ms(200 + sdk.random_below(800));
    const hold = try context.nodes.race.hold(&.{ "race_held.check", "--later" }, 10_000);
    if (!hold.armed()) {
        hold.release();
        return error.NotArmed;
    }
    // Runs of the program go on meanwhile: none may be held before the point is armed.
    sdk.sleep_ms(500);
    const command = "arm 0\n";
    _ = linux.write(hold.input, command.ptr, command.len);
    _ = linux.kill(hold.pid, .USR1);
    var armed_seen = false;
    var held_before = false;
    var held_after = false;
    while (!held_after) {
        var buffer: [256]u8 = undefined;
        const said = hold_line(hold, &buffer);
        if (said.len == 0 or std.mem.startsWith(u8, said, "{\"held\":null")) break;
        if (std.mem.eql(u8, said, "{\"armed_point\":0}")) armed_seen = true;
        if (std.mem.startsWith(u8, said, "{\"held\":")) {
            if (armed_seen) held_after = true else held_before = true;
        }
    }
    hold.release();
    sdk.event("race_held_later", .{ .armed = armed_seen, .held_before = held_before, .held_after = held_after });
    sdk.always(armed_seen and held_after and !held_before, "a later hold point holds only once armed", .{ .armed = armed_seen, .held_before = held_before });
}

fn race(s: *System.Scenario) void {
    // The node works on its own; the timeline lasts while drivers wait.
    s.singleton_driver("wait", wait);
}

fn wait(context: *System.Context) !void {
    // Node.js builds its pool of 64 workers in about 7 s of the guest's time (racerun.js), the
    // other languages start racing within milliseconds: a timeline of 1 to 10 s ended before or
    // just after JavaScript's first run, no stretch of pausing left in it (hunt run 938: 951
    // timelines, at most 10.7 s, 274 with a pausing decision, the race never found). Its
    // timelines last its pool's start beside the others' 1 to 10 s of racing.
    const start_ms: u64 = if (std.mem.eql(u8, context.profile, "javascript")) 8000 else 0;
    sdk.sleep_ms(start_ms + 1000 + sdk.random_below(9000));
}
