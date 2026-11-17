// SPDX-License-Identifier: MIT
//! The JVM SDK's coverage agent (DeterminismoCoverage.java), compiled and run with the JDK on
//! the path (24 or later: java.lang.classfile; skipped without one).
//!
//! A probe waits for no lock: its first report of a line returns while another thread holds the
//! SDK's monitor (its emit's), the report sent by the agent's own thread. A probe that called
//! the SDK deadlocked JVMs (core.async, hunt runs 1115 and 1122): an instrumented class
//! initializer's first probe waited for a monitor held by a virtual thread that needed the only
//! carrier, pinned waiting for that initialization. Nothing ran again, and "the service never
//! answers again" failed.

const std = @import("std");

const sources = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "Determinismo.java", .text = @embedFile("Determinismo.java") },
    .{ .name = "DeterminismoCatalog.java", .text = @embedFile("DeterminismoCatalog.java") },
    .{ .name = "DeterminismoCoverage.java", .text = @embedFile("DeterminismoCoverage.java") },
    .{ .name = "CoverageLockCheck.java", .text = lock_check },
};

/// Exit 0 when a probe's first report of a line returns while the SDK's monitor (its emit's) is
/// held by another thread, 1 when the probe waits for it.
const lock_check =
    \\import java.lang.reflect.Method;
    \\import java.util.concurrent.CountDownLatch;
    \\
    \\public class CoverageLockCheck {
    \\  public static void main(String[] arguments) throws Exception {
    \\    Method register = DeterminismoCoverage.class.getDeclaredMethod("register", String.class);
    \\    register.setAccessible(true);
    \\    int id = (int) register.invoke(null, "CoverageLockCheck:1");
    \\    CountDownLatch held = new CountDownLatch(1);
    \\    CountDownLatch release = new CountDownLatch(1);
    \\    Thread holder = new Thread(() -> {
    \\      synchronized (Determinismo.class) { // emit's monitor
    \\        held.countDown();
    \\        try { release.await(); } catch (InterruptedException ignored) { }
    \\      }
    \\    });
    \\    holder.start();
    \\    held.await();
    \\    Thread probe = new Thread(() -> DeterminismoCoverage.line(id)); // its first report
    \\    probe.start();
    \\    probe.join(5000);
    \\    boolean returned = !probe.isAlive();
    \\    release.countDown();
    \\    probe.join();
    \\    holder.join();
    \\    System.out.println(returned ? "returned" : "waited");
    \\    System.exit(returned ? 0 : 1);
    \\  }
    \\}
    \\
;

/// The JDK's major version from `java -version`, or null without one.
fn java_major(arena: std.mem.Allocator, io: std.Io) ?u32 {
    const result = std.process.run(arena, io, .{ .argv = &.{ "java", "-version" } }) catch return null;
    const text = if (result.stderr.len > 0) result.stderr else result.stdout;
    const at = std.mem.indexOf(u8, text, "version \"") orelse return null;
    var digits = text[at + "version \"".len ..];
    var end: usize = 0;
    while (end < digits.len and std.ascii.isDigit(digits[end])) end += 1;
    digits = digits[0..end];
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

test "a probe's first report of a line returns while the SDK's emit is held" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const major = java_major(arena, io) orelse return error.SkipZigTest;
    if (major < 24) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "javac", "-d", directory });
    for (sources) |source| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, source.name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source.text });
        try argv.append(arena, path);
    }
    const compiled = try std.process.run(arena, io, .{ .argv = argv.items });
    if (compiled.term != .exited or compiled.term.exited != 0) {
        std.debug.print("javac: {s}\n", .{compiled.stderr});
        return error.TestUnexpectedResult;
    }
    const ran = try std.process.run(arena, io, .{ .argv = &.{ "java", "-cp", directory, "CoverageLockCheck" } });
    std.debug.print("CoverageLockCheck: {s}", .{ran.stdout});
    try std.testing.expect(ran.term == .exited and ran.term.exited == 0);
}

/// A class instrumented ahead of time: its line, run with no agent, is reported by name.
const probe_java =
    \\public class Probe {
    \\  public static void main(String[] arguments) {
    \\    int sum = 0;
    \\    for (int i = 0; i < 3; i++) sum += i;
    \\    System.out.println("sum " + sum);
    \\  }
    \\}
    \\
;

test "a class instrumented ahead of time reports its lines with no agent" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const major = java_major(arena, io) orelse return error.SkipZigTest;
    if (major < 24) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const sdk_classes = try std.fmt.allocPrint(arena, "{s}/sdk", .{directory});
    const probe_classes = try std.fmt.allocPrint(arena, "{s}/probe", .{directory});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "javac", "-d", sdk_classes });
    for (sources[0..3]) |source| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, source.name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source.text });
        try argv.append(arena, path);
    }
    try run_ok(arena, io, argv.items);
    const probe_path = try std.fmt.allocPrint(arena, "{s}/Probe.java", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = probe_path, .data = probe_java });
    try run_ok(arena, io, &.{ "javac", "-g", "-d", probe_classes, probe_path });
    const plain = try std.fmt.allocPrint(arena, "{s}/probe.jar", .{directory});
    const instrumented = try std.fmt.allocPrint(arena, "{s}/probe-instrumented.jar", .{directory});
    try run_ok(arena, io, &.{ "jar", "cf", plain, "-C", probe_classes, "." });
    try run_ok(arena, io, &.{ "java", "-cp", sdk_classes, "DeterminismoCoverage", "instrument", "Probe", plain, instrumented });
    // Run with no agent, the SDK's events to a local file (outside determinismo).
    const events = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{directory});
    const classpath = try std.fmt.allocPrint(arena, "{s}:{s}", .{ instrumented, sdk_classes });
    var environment = std.process.Environ.Map.init(arena);
    try environment.put("DETERMINISMO_SDK_LOCAL_OUTPUT", events);
    try environment.put("PATH", "/usr/bin:/bin");
    const ran = try std.process.run(arena, io, .{ .argv = &.{ "java", "-cp", classpath, "Probe" }, .environ_map = &environment });
    try std.testing.expect(ran.term == .exited and ran.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, ran.stdout, "sum 3") != null);
    const reported = try std.Io.Dir.cwd().readFileAlloc(io, events, arena, .limited(1 << 20));
    std.debug.print("events: {s}", .{reported});
    try std.testing.expect(std.mem.indexOf(u8, reported, "\"name\":\"line Probe:4\"") != null);
}

/// An if/else taken one way 3,000 times, then the other once (line 4: its branch; 5 and 7 its sides).
const rare_probe_java =
    \\public class RareProbe {
    \\  static int f(int x) {
    \\    int r;
    \\    if (x > 0) {
    \\      r = 1;
    \\    } else {
    \\      r = 2;
    \\    }
    \\    return r;
    \\  }
    \\  public static void main(String[] arguments) {
    \\    int sum = 0;
    \\    for (int i = 0; i < 3000; i++) sum += f(1);
    \\    sum += f(-1);
    \\    System.out.println("sum " + sum);
    \\  }
    \\}
    \\
;

test "a branch's sides are blocks of their own: the instrumented class runs, no rare-line events" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const major = java_major(arena, io) orelse return error.SkipZigTest;
    if (major < 24) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const sdk_classes = try std.fmt.allocPrint(arena, "{s}/sdk", .{directory});
    const probe_classes = try std.fmt.allocPrint(arena, "{s}/probe", .{directory});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "javac", "-d", sdk_classes });
    for (sources[0..3]) |source| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, source.name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source.text });
        try argv.append(arena, path);
    }
    try run_ok(arena, io, argv.items);
    const probe_path = try std.fmt.allocPrint(arena, "{s}/RareProbe.java", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = probe_path, .data = rare_probe_java });
    try run_ok(arena, io, &.{ "javac", "-g", "-d", probe_classes, probe_path });
    const plain = try std.fmt.allocPrint(arena, "{s}/rare.jar", .{directory});
    const instrumented = try std.fmt.allocPrint(arena, "{s}/rare-instrumented.jar", .{directory});
    try run_ok(arena, io, &.{ "jar", "cf", plain, "-C", probe_classes, "." });
    try run_ok(arena, io, &.{ "java", "-cp", sdk_classes, "DeterminismoCoverage", "instrument", "RareProbe", plain, instrumented });
    const events = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{directory});
    const classpath = try std.fmt.allocPrint(arena, "{s}:{s}", .{ instrumented, sdk_classes });
    var environment = std.process.Environ.Map.init(arena);
    try environment.put("DETERMINISMO_SDK_LOCAL_OUTPUT", events);
    try environment.put("PATH", "/usr/bin:/bin");
    const ran = try std.process.run(arena, io, .{ .argv = &.{ "java", "-cp", classpath, "RareProbe" }, .environ_map = &environment });
    try std.testing.expect(ran.term == .exited and ran.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, ran.stdout, "sum 3002") != null);
    const reported = try std.Io.Dir.cwd().readFileAlloc(io, events, arena, .limited(1 << 20));
    // Both sides' lines reached; rare directions are the explorer's, counted across the run's
    // timelines (the per-JVM 1,000-to-1 "rare line" events gone: the rare-branch A/B, 2026-11-10).
    std.debug.print("events: {s}", .{reported});
    try std.testing.expect(std.mem.indexOf(u8, reported, "\"name\":\"line RareProbe:5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reported, "\"name\":\"line RareProbe:7\"") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, reported, "rare line"));
}

fn run_ok(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}: {s}{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
}

/// A JVM already shutting down as the coverage agent loads (a node stopped during its start:
/// CrateDB, hunt run 1893, SIGTERM 0.4 s after the JVM began). The first agent starts the exit on
/// another thread and returns once shutdown is in progress (its hook holds the JVM open until
/// main has run); the coverage agent loads next, as in that timeline.
const exiting_agent_java =
    \\import java.lang.instrument.Instrumentation;
    \\
    \\public class ExitingAgent {
    \\  public static volatile boolean mainRan;
    \\  public static void premain(String arguments, Instrumentation instrumentation) throws Exception {
    \\    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    \\      long end = System.nanoTime() + 10_000_000_000L;
    \\      while (!mainRan && System.nanoTime() < end) {
    \\        try { Thread.sleep(5); } catch (InterruptedException stopped) { return; }
    \\      }
    \\    }));
    \\    new Thread(() -> System.exit(0)).start();
    \\    while (true) {
    \\      Thread probe = new Thread(() -> { });
    \\      try {
    \\        Runtime.getRuntime().addShutdownHook(probe);
    \\        Runtime.getRuntime().removeShutdownHook(probe);
    \\      } catch (IllegalStateException inProgress) {
    \\        return;
    \\      }
    \\      Thread.sleep(1);
    \\    }
    \\  }
    \\}
    \\
;

const exiting_main_java =
    \\public class ExitingMain {
    \\  public static void main(String[] arguments) {
    \\    System.out.println("main ran");
    \\    ExitingAgent.mainRan = true;
    \\  }
    \\}
    \\
;

test "the coverage agent loading while the JVM shuts down: no error, the JVM exits as asked" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const major = java_major(arena, io) orelse return error.SkipZigTest;
    if (major < 24) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const classes = try std.fmt.allocPrint(arena, "{s}/classes", .{directory});
    const files = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = sources[0].name, .text = sources[0].text },
        .{ .name = sources[2].name, .text = sources[2].text },
        .{ .name = "DeterminismoCoverageBoot.java", .text = @embedFile("DeterminismoCoverageBoot.java") },
        .{ .name = "ExitingAgent.java", .text = exiting_agent_java },
        .{ .name = "ExitingMain.java", .text = exiting_main_java },
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "javac", "-d", classes });
    for (files) |file| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, file.name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.text });
        try argv.append(arena, path);
    }
    try run_ok(arena, io, argv.items);
    var agents: [2][]const u8 = undefined;
    const premain_classes = [_][]const u8{ "ExitingAgent", "DeterminismoCoverageBoot" };
    for (premain_classes, 0..) |premain_class, index| {
        const manifest = try std.fmt.allocPrint(arena, "{s}/{s}.mf", .{ directory, premain_class });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = try std.fmt.allocPrint(arena, "Premain-Class: {s}\n", .{premain_class}) });
        agents[index] = try std.fmt.allocPrint(arena, "{s}/{s}.jar", .{ directory, premain_class });
        try run_ok(arena, io, &.{ "jar", "--create", "--file", agents[index], "--manifest", manifest, "-C", classes, "." });
    }
    var environment = std.process.Environ.Map.init(arena);
    try environment.put("DETERMINISMO_SDK_LOCAL_OUTPUT", try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{directory}));
    try environment.put("PATH", "/usr/bin:/bin");
    const java = try std.fmt.allocPrint(arena, "-javaagent:{s}", .{agents[0]});
    const coverage = try std.fmt.allocPrint(arena, "-javaagent:{s}", .{agents[1]});
    const ran = try std.process.run(arena, io, .{
        .argv = &.{ "java", java, coverage, "-cp", classes, "ExitingMain" },
        .environ_map = &environment,
    });
    std.debug.print("exiting JVM: {any}\n{s}{s}", .{ ran.term, ran.stdout, ran.stderr });
    try std.testing.expect(ran.term == .exited and ran.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, ran.stdout, "main ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, ran.stderr, "Exception") == null);
    try std.testing.expect(std.mem.indexOf(u8, ran.stdout, "FATAL") == null);
}
