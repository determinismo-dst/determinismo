// SPDX-License-Identifier: MIT
//! libdeterminismo: the Zig SDK behind a C ABI, for test programs in any language with a C FFI
//! (Java's FFM, Python's ctypes, ...): the same definitions (`det_describe` checks and converts
//! a system as Zig's System does), decisions, assertions, records, faults and Elle histories
//! and checks as Zig programs have, one implementation. No libc: any process loads it.
//!
//! Its interface is bindings.zig's table, which this file is checked against at compile time:
//! every function there is here with the signature its types make, and nothing else is exported.
//! The build writes the table as libdeterminismo.json, which bindings are made from.
//!
//! Its callers are other languages' programs: what they pass is checked rather than asserted
//! (a JVM aborted by an assertion here loses its stack), refusals are negative results.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo.zig");
const schema = @import("schema.zig");
const elle = @import("elle.zig");
const system = @import("system.zig");
const bindings = @import("bindings.zig");

const invalid_argument: i32 = -1;
const unavailable: i32 = -2;
const failed: i32 = -3;

comptime {
    @setEvalBranchQuota(100_000);
    for (bindings.functions) |function| {
        if (!@hasDecl(implementations, function.name)) {
            @compileError("libdeterminismo: " ++ function.name ++ " is in bindings.zig, not here");
        }
        const implementation = @field(implementations, function.name);
        const info = @typeInfo(@TypeOf(implementation)).@"fn";
        var expected: []const type = &.{};
        for (function.params) |param| expected = expected ++ c_types(param.type);
        const returns = if (function.returns) |t| c_types(t)[0] else void;
        var matches = info.param_types.len == expected.len and info.return_type.? == returns and
            info.attrs.@"callconv".eql(.c);
        if (matches) for (info.param_types, expected) |param, Expected| {
            if (param.? != Expected) matches = false;
        };
        if (!matches) @compileError("libdeterminismo: " ++ function.name ++ "'s signature is not " ++
            "what bindings.zig's types make");
        @export(&implementation, .{ .name = function.name });
    }
    for (std.meta.declarations(implementations)) |name| {
        if (bindings.find(name) == null) {
            @compileError("libdeterminismo: " ++ name ++ " is not in bindings.zig");
        }
    }
}

/// The C parameters a binding type makes.
fn c_types(comptime t: bindings.Type) []const type {
    return switch (t) {
        .string, .json => &.{ ?[*]const u8, usize },
        .buffer => &.{ ?[*]u8, usize },
        .u64 => &.{u64},
        .i32 => &.{i32},
        .f64 => &.{f64},
        .bool => &.{bool},
    };
}

fn text(pointer: ?[*]const u8, size: usize) []const u8 {
    const start = pointer orelse return "";
    return start[0..size];
}

fn target(pointer: ?[*]u8, size: usize) []u8 {
    const start = pointer orelse return &.{};
    return start[0..size];
}

fn json_valid(source: []const u8) bool {
    if (source.len == 0) return false;
    var stack: [16 * 1024]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&stack);
    return std.json.validate(allocator.allocator(), source) catch false;
}

/// Details as they go out: "{}" for none, a string saying so for what is not JSON (the event
/// still goes out: the assertion is never lost).
fn details(pointer: ?[*]const u8, size: usize) sdk.RawJson {
    const source = text(pointer, size);
    if (source.len == 0) return .{ .text = "{}" };
    if (!json_valid(source)) return .{ .text = "\"<details not JSON>\"" };
    return .{ .text = source };
}

/// The SDK keeps a little state (declared assertions, buggify points) that the JVM's threads
/// would share: one at a time.
var state_lock: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (state_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    state_lock.store(false, .release);
}

/// det_runner's last reply, for det_runner_reply: the process's (a thread's request and its
/// reply are one as long as no other thread asks between them). Swapped under the state lock
/// only: the request itself may take long, other calls go on meanwhile.
var runner_reply: std.ArrayList(u8) = .empty;

/// det_serve's last reply, for det_serve_reply (as runner_reply).
var serve_reply: std.ArrayList(u8) = .empty;

/// Buggify points by name: the SDK keeps each name's slice, which a caller's memory is not.
const buggify_names_max = 64;
const buggify_name_size_max = 64;
var buggify_names: [buggify_names_max][buggify_name_size_max]u8 = undefined;
var buggify_sizes: [buggify_names_max]u8 = undefined;
var buggify_count: u32 = 0;

fn buggify_name(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > buggify_name_size_max) return null;
    for (buggify_names[0..buggify_count], buggify_sizes[0..buggify_count]) |*stored, size| {
        if (std.mem.eql(u8, stored[0..size], name)) return stored[0..size];
    }
    if (buggify_count == buggify_names_max) return null;
    const index = buggify_count;
    @memcpy(buggify_names[index][0..name.len], name);
    buggify_sizes[index] = @intCast(name.len);
    buggify_count += 1;
    return buggify_names[index][0..name.len];
}

/// An arena for one call.
fn arena_new() std.heap.ArenaAllocator {
    return .init(std.heap.page_allocator);
}

fn stdout_write(bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const result = linux.write(1, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .SUCCESS => rest = rest[result..],
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

fn complain(comptime format: []const u8, arguments: anytype) i32 {
    std.debug.print("libdeterminismo: " ++ format ++ "\n", arguments);
    return invalid_argument;
}

const implementations = struct {
    pub fn det_random_u64() callconv(.c) u64 {
        return sdk.random_u64();
    }

    pub fn det_random_below(count: u64) callconv(.c) u64 {
        if (count == 0) return 0;
        return sdk.random_below(count);
    }

    pub fn det_random_float() callconv(.c) f64 {
        return sdk.random_float();
    }

    pub fn det_random_bytes(pointer: ?[*]u8, size: usize) callconv(.c) u64 {
        var rest = target(pointer, size);
        while (rest.len > 0) {
            const chunk = @min(rest.len, sdk.message_size_max);
            sdk.random_bytes(rest[0..chunk]);
            rest = rest[chunk..];
        }
        return size;
    }

    pub fn det_decide(
        name_pointer: ?[*]const u8,
        name_size: usize,
        options_pointer: ?[*]const u8,
        options_size: usize,
    ) callconv(.c) u64 {
        const name = text(name_pointer, name_size);
        var options: [256][]const u8 = undefined;
        var count: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, text(options_pointer, options_size), '\n');
        while (lines.next()) |line| {
            if (count == options.len) break;
            options[count] = line;
            count += 1;
        }
        if (count == 0 or name.len == 0) return 0;
        return sdk.decide(name, options[0..count]);
    }

    pub fn det_random_below_named(name_pointer: ?[*]const u8, name_size: usize, count: u64) callconv(.c) u64 {
        const name = text(name_pointer, name_size);
        if (count == 0) return 0;
        if (name.len == 0) return sdk.random_below(count);
        return sdk.random_below_named(name, count);
    }

    pub fn det_random_near(name_pointer: ?[*]const u8, name_size: usize, limit: u64, max: u64) callconv(.c) u64 {
        const name = text(name_pointer, name_size);
        if (max == 0 or max == std.math.maxInt(u64)) return @min(limit, max);
        if (name.len == 0) return sdk.random_below(max + 1);
        return sdk.random_near(name, limit, max);
    }

    pub fn det_swarm_index(name_pointer: ?[*]const u8, name_size: usize, count: u64) callconv(.c) u64 {
        const name = text(name_pointer, name_size);
        if (count == 0) return 0;
        if (name.len == 0 or count > sdk.swarm_options_max) return sdk.random_below(count);
        return sdk.swarm_index(name, count);
    }

    pub fn det_crash_point(name_pointer: ?[*]const u8, name_size: usize) callconv(.c) void {
        // The name kept (the SDK's table holds it past the call), the decision under the lock,
        // the wait for the crash outside it (other threads' calls go on meanwhile).
        lock();
        const name = buggify_name(text(name_pointer, name_size));
        const due = if (name) |stored| sdk.crash_point_due(stored) else null;
        unlock();
        if (due) |now_ns| sdk.crash_point_ask(name.?, now_ns);
    }

    pub fn det_buggify(name_pointer: ?[*]const u8, name_size: usize) callconv(.c) bool {
        lock();
        defer unlock();
        const name = buggify_name(text(name_pointer, name_size)) orelse return false;
        return sdk.buggify(name);
    }

    pub fn det_buggify_pause(name_pointer: ?[*]const u8, name_size: usize) callconv(.c) void {
        lock();
        const name = buggify_name(text(name_pointer, name_size));
        unlock();
        if (name) |stored| sdk.buggify_pause(stored);
    }

    pub fn det_assert(
        kind_pointer: ?[*]const u8,
        kind_size: usize,
        condition: bool,
        message_pointer: ?[*]const u8,
        message_size: usize,
        details_pointer: ?[*]const u8,
        details_size: usize,
    ) callconv(.c) i32 {
        const kind = std.meta.stringToEnum(sdk.Kind, text(kind_pointer, kind_size)) orelse
            return invalid_argument;
        const message = text(message_pointer, message_size);
        if (message.len == 0) return invalid_argument;
        sdk.assert_computed(kind, condition, message, details(details_pointer, details_size));
        return 0;
    }

    pub fn det_declare(
        kind_pointer: ?[*]const u8,
        kind_size: usize,
        message_pointer: ?[*]const u8,
        message_size: usize,
    ) callconv(.c) i32 {
        const kind = std.meta.stringToEnum(sdk.Kind, text(kind_pointer, kind_size)) orelse
            return invalid_argument;
        const message = text(message_pointer, message_size);
        if (message.len == 0) return invalid_argument;
        lock();
        defer unlock();
        switch (kind) {
            inline else => |known| sdk.declare(@tagName(known), message),
        }
        return 0;
    }

    pub fn det_optimize(
        message_pointer: ?[*]const u8,
        message_size: usize,
        bucket_pointer: ?[*]const u8,
        bucket_size: usize,
        value: f64,
        goal_pointer: ?[*]const u8,
        goal_size: usize,
    ) callconv(.c) i32 {
        const message = text(message_pointer, message_size);
        const goal = std.meta.stringToEnum(sdk.Goal, text(goal_pointer, goal_size)) orelse
            return invalid_argument;
        if (message.len == 0) return invalid_argument;
        sdk.optimize_computed(message, details(bucket_pointer, bucket_size), value, goal);
        return 0;
    }

    pub fn det_event(
        name_pointer: ?[*]const u8,
        name_size: usize,
        details_pointer: ?[*]const u8,
        details_size: usize,
    ) callconv(.c) i32 {
        const name = text(name_pointer, name_size);
        if (name.len == 0) return invalid_argument;
        sdk.event(name, details(details_pointer, details_size));
        return 0;
    }

    pub fn det_setup_complete(details_pointer: ?[*]const u8, details_size: usize) callconv(.c) void {
        sdk.setup_complete(details(details_pointer, details_size));
    }

    pub fn det_record(
        check_pointer: ?[*]const u8,
        check_size: usize,
        value_pointer: ?[*]const u8,
        value_size: usize,
    ) callconv(.c) i32 {
        var path_buffer: [256]u8 = undefined;
        const path = schema.record_path_format(&path_buffer, text(check_pointer, check_size)) catch
            return invalid_argument;
        const value = text(value_pointer, value_size);
        if (value.len + 1 > sdk.record_size_max or std.mem.indexOfScalar(u8, value, '\n') != null or
            !json_valid(value)) return invalid_argument;
        var line: [sdk.record_size_max]u8 = undefined;
        @memcpy(line[0..value.len], value);
        line[value.len] = '\n';
        sdk.record_line(path, line[0 .. value.len + 1]);
        return 0;
    }

    pub fn det_sleep_ms(duration_ms: u64) callconv(.c) void {
        sdk.sleep_ms(duration_ms);
    }

    pub fn det_stop_faults(duration_ns: u64) callconv(.c) void {
        sdk.stop_faults(duration_ns);
    }

    pub fn det_fault(request_pointer: ?[*]const u8, request_size: usize) callconv(.c) i32 {
        const request = text(request_pointer, request_size);
        if (!json_valid(request)) return invalid_argument;
        sdk.fault(sdk.RawJson{ .text = request });
        return 0;
    }

    pub fn det_fork(count: u64) callconv(.c) u64 {
        if (count == 0 or count > 1024) return 0;
        return sdk.fork(@intCast(count));
    }

    pub fn det_fault_aim(node_pointer: ?[*]const u8, node_size: usize) callconv(.c) void {
        sdk.fault_aim(text(node_pointer, node_size));
    }

    pub fn det_system(pointer: ?[*]u8, size: usize) callconv(.c) u64 {
        const buffer = target(pointer, size);
        const fd = linux.open(schema.system_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return 0;
        defer _ = linux.close(@intCast(fd));
        const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
        if (linux.errno(end) != .SUCCESS) return 0;
        if (end > buffer.len) return end;
        var read: usize = 0;
        while (read < end) {
            const result = linux.pread(@intCast(fd), buffer[read..].ptr, end - read, @intCast(read));
            if (linux.errno(result) != .SUCCESS or result == 0) return 0;
            read += result;
        }
        return end;
    }

    pub fn det_runner(request_pointer: ?[*]const u8, request_size: usize) callconv(.c) i32 {
        const allocator = std.heap.page_allocator;
        const source = text(request_pointer, request_size);
        if (source.len == 0 or !json_valid(source)) return invalid_argument;
        // One line: a newline in JSON text is whitespace (in its strings it is escaped).
        const request = allocator.dupe(u8, source) catch return failed;
        defer allocator.free(request);
        std.mem.replaceScalar(u8, request, '\n', ' ');
        var reply: std.ArrayList(u8) = .empty;
        sdk.runner(allocator, request, &reply) catch |err| {
            reply.deinit(allocator);
            return switch (err) {
                error.RunnerUnavailable => unavailable,
                else => failed,
            };
        };
        lock();
        defer unlock();
        runner_reply.deinit(allocator);
        runner_reply = reply;
        return 0;
    }

    pub fn det_serve(
        method_pointer: ?[*]const u8,
        method_size: usize,
        path_pointer: ?[*]const u8,
        path_size: usize,
        body_pointer: ?[*]const u8,
        body_size: usize,
    ) callconv(.c) i32 {
        const allocator = std.heap.page_allocator;
        const method = text(method_pointer, method_size);
        const path = text(path_pointer, path_size);
        const body = text(body_pointer, body_size);
        if (method.len == 0 or path.len == 0 or path[0] != '/') return invalid_argument;
        if (body.len > 0 and !json_valid(body)) return invalid_argument;
        // Held across the call: its request and its reply's decisions are one sequence, which
        // another thread's decision in between would break (the machine waits meanwhile).
        lock();
        defer unlock();
        var reply: std.ArrayList(u8) = .empty;
        const status = sdk.serve(allocator, method, path, body, &reply) catch |err| {
            reply.deinit(allocator);
            return switch (err) {
                error.Unavailable => unavailable,
                error.RequestTooLarge => invalid_argument,
                else => failed,
            };
        };
        serve_reply.deinit(allocator);
        serve_reply = reply;
        return status;
    }

    pub fn det_serve_reply(pointer: ?[*]u8, size: usize) callconv(.c) u64 {
        const buffer = target(pointer, size);
        lock();
        defer unlock();
        if (serve_reply.items.len <= buffer.len) @memcpy(buffer[0..serve_reply.items.len], serve_reply.items);
        return serve_reply.items.len;
    }

    pub fn det_runner_reply(pointer: ?[*]u8, size: usize) callconv(.c) u64 {
        const buffer = target(pointer, size);
        lock();
        defer unlock();
        const reply = std.mem.trimEnd(u8, runner_reply.items, "\n");
        if (reply.len <= buffer.len) @memcpy(buffer[0..reply.len], reply);
        return reply.len;
    }

    pub fn det_describe(definition_pointer: ?[*]const u8, definition_size: usize) callconv(.c) i32 {
        var arena_state = arena_new();
        defer arena_state.deinit();
        return describe(arena_state.allocator(), text(definition_pointer, definition_size)) catch |err|
            complain("describe: {t}", .{err});
    }

    pub fn det_elle_process_new() callconv(.c) u64 {
        return elle.process_new();
    }

    pub fn det_elle_note(
        check_pointer: ?[*]const u8,
        check_size: usize,
        process: u64,
        type_pointer: ?[*]const u8,
        type_size: usize,
        value_pointer: ?[*]const u8,
        value_size: usize,
    ) callconv(.c) i32 {
        var path_buffer: [256]u8 = undefined;
        const path = schema.record_path_format(&path_buffer, text(check_pointer, check_size)) catch
            return invalid_argument;
        const kind = std.meta.stringToEnum(elle.Kind, text(type_pointer, type_size)) orelse
            return invalid_argument;
        const value = text(value_pointer, value_size);
        if (value.len == 0 or value[0] != '[' or std.mem.indexOfScalar(u8, value, '\n') != null or
            !json_valid(value)) return invalid_argument;
        const history: elle.History = .{ .path = path };
        history.note_json(std.heap.page_allocator, process, kind, value) catch return failed;
        return 0;
    }

    pub fn det_elle_declare(options_pointer: ?[*]const u8, options_size: usize) callconv(.c) i32 {
        var arena_state = arena_new();
        defer arena_state.deinit();
        const source = text(options_pointer, options_size);
        const options: elle.CheckOptions = if (source.len == 0) .{} else std.json.parseFromSliceLeaky(
            elle.CheckOptions,
            arena_state.allocator(),
            source,
            .{ .allocate = .alloc_always },
        ) catch |err| return complain("elle options: {t}", .{err});
        lock();
        defer unlock();
        elle.declare(options);
        return 0;
    }

    pub fn det_elle_check(
        scenario_pointer: ?[*]const u8,
        scenario_size: usize,
        history_pointer: ?[*]const u8,
        history_size: usize,
        options_pointer: ?[*]const u8,
        options_size: usize,
    ) callconv(.c) i32 {
        var arena_state = arena_new();
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const source = text(options_pointer, options_size);
        const options: elle.CheckOptions = if (source.len == 0) .{} else std.json.parseFromSliceLeaky(
            elle.CheckOptions,
            arena,
            source,
            .{ .allocate = .alloc_always },
        ) catch |err| return complain("elle options: {t}", .{err});
        var threaded = io_threaded(arena) catch return failed;
        var context: sdk.Check = .{
            .arena = arena,
            .io = threaded.io(),
            .scenario = text(scenario_pointer, scenario_size),
        };
        elle.check_history(&context, text(history_pointer, history_size), options) catch |err| {
            std.debug.print("libdeterminismo: elle: {t}\n", .{err});
            return failed;
        };
        return 0;
    }
};

/// An Io for the host checks that start processes (Elle's service): single-threaded, so that
/// no signal handler of its replaces the caller's (a JVM's), with this process's environment
/// (PATH for podman), read from /proc: a library has no start code that would hand it over.
fn io_threaded(arena: std.mem.Allocator) !std.Io.Threaded {
    const fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoEnvironment;
    defer _ = linux.close(@intCast(fd));
    var source: std.ArrayList(u8) = .empty;
    while (true) {
        try source.ensureUnusedCapacity(arena, 64 * 1024);
        const free = source.unusedCapacitySlice();
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.NoEnvironment;
        if (result == 0) break;
        source.items.len += result;
    }
    var entries: std.ArrayList(?[*:0]const u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, source.items, 0);
    while (parts.next()) |entry| try entries.append(arena, try arena.dupeSentinel(u8, entry, 0));
    const block = try entries.toOwnedSliceSentinel(arena, null);
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.environ = .{ .process_environ = .{ .block = .{ .slice = block } } };
    threaded.environ_initialized = block.len == 0;
    return threaded;
}

/// A definition as other languages give it: Zig System's, with nodes named in lists.
const Definition = struct {
    profiles: []const ProfileDefinition,
    scenarios: []const schema.Scenario,
    checks: []const []const u8 = &.{},
};

const ProfileDefinition = struct {
    name: []const u8,
    nodes: []const NodeDefinition,
    explain: ?[]const u8 = null,
    retroactive: []const []const u8 = &.{},
    epoch_seconds: ?u64 = null,
};

const NodeDefinition = struct {
    name: []const u8,
    spec: system.NodeSpec([]const u8),
};

fn describe(arena: std.mem.Allocator, source: []const u8) !i32 {
    const definition = std.json.parseFromSliceLeaky(Definition, arena, source, .{
        .allocate = .alloc_always,
    }) catch |err| return complain("the definition is not one ({t}): {s}", .{ err, source[0..@min(source.len, 200)] });
    const description = try description_make(arena, definition) orelse return invalid_argument;
    var output: std.Io.Writer.Allocating = .init(arena);
    try system.description_write(&output.writer, description);
    if (!stdout_write(output.written())) return failed;
    return 0;
}

/// The description a definition makes, checked as Zig's System checks its own (most of it at
/// compile time there): null, said, when it is not one.
fn description_make(arena: std.mem.Allocator, definition: Definition) !?schema.Description {
    if (definition.profiles.len == 0) return null_after(complain("no profiles", .{}));
    if (definition.profiles.len > 16) return null_after(complain("too many profiles", .{}));
    if (definition.scenarios.len == 0 or definition.scenarios.len > schema.scenarios_max) {
        return null_after(complain("{d} scenarios, 1 to {d}", .{ definition.scenarios.len, schema.scenarios_max }));
    }
    if (definition.checks.len > schema.checks_max) return null_after(complain("too many checks", .{}));
    const profiles = try arena.alloc(schema.Profile, definition.profiles.len);
    for (definition.profiles, profiles, 0..) |profile, *converted, index| {
        if (profile.name.len == 0) return null_after(complain("a profile without a name", .{}));
        for (definition.profiles[0..index]) |other| if (std.mem.eql(u8, other.name, profile.name)) {
            return null_after(complain("profile {s} twice", .{profile.name}));
        };
        if (profile.nodes.len == 0 or profile.nodes.len > schema.nodes_max) {
            return null_after(complain("profile {s}: {d} nodes, 1 to {d}", .{ profile.name, profile.nodes.len, schema.nodes_max }));
        }
        const nodes = try arena.alloc(schema.Node, profile.nodes.len);
        for (profile.nodes, nodes, 0..) |node, *target_node, at| {
            if (!schema.name_valid(node.name)) {
                return null_after(complain("profile {s}: node name {s} (lower case, digits and -, 12 at most)", .{ profile.name, node.name }));
            }
            for (profile.nodes[0..at]) |other| if (std.mem.eql(u8, other.name, node.name)) {
                return null_after(complain("profile {s}: node {s} twice", .{ profile.name, node.name }));
            };
            for (node.spec.after) |dependency| if (!nodes_have(profile.nodes, dependency)) {
                return null_after(complain("profile {s}: node {s} after {s}, not a node", .{ profile.name, node.name, dependency }));
            };
            target_node.* = try system.node_convert(arena, node.name, node.spec);
        }
        converted.* = .{
            .name = profile.name,
            .nodes = nodes,
            .explain = profile.explain,
            .retroactive = profile.retroactive,
            .epoch_seconds = profile.epoch_seconds,
        };
    }
    for (definition.scenarios, 0..) |scenario, index| {
        if (scenario.name.len == 0 or std.mem.eql(u8, scenario.name, "all")) {
            return null_after(complain("scenario name \"{s}\" (\"all\" explores every scenario)", .{scenario.name}));
        }
        for (definition.scenarios[0..index]) |other| if (std.mem.eql(u8, other.name, scenario.name)) {
            return null_after(complain("scenario {s} twice", .{scenario.name}));
        };
        if (scenario.commands.len == 0 or scenario.commands.len > schema.commands_max) {
            return null_after(complain("scenario {s}: {d} commands, 1 to {d}", .{ scenario.name, scenario.commands.len, schema.commands_max }));
        }
        if (scenario.program != null and scenario.node == null) {
            return null_after(complain("scenario {s}: a program needs the node it runs in", .{scenario.name}));
        }
        if (scenario.node) |node| for (definition.profiles) |profile| if (!nodes_have(profile.nodes, node)) {
            return null_after(complain("scenario {s} runs in {s}, not a node of profile {s}", .{ scenario.name, node, profile.name }));
        };
        var setups: u32 = 0;
        for (scenario.commands, 0..) |command, at| {
            if (command.name.len == 0) return null_after(complain("scenario {s}: a command without a name", .{scenario.name}));
            for (scenario.commands[0..at]) |other| if (std.mem.eql(u8, other.name, command.name)) {
                return null_after(complain("scenario {s}: command {s} twice", .{ scenario.name, command.name }));
            };
            if (command.kind == .setup) setups += 1;
            const path_needed = scenario.node != null and scenario.program == null;
            if ((command.path != null) != path_needed) {
                return null_after(complain("scenario {s}: command {s} has a path only when its node holds the commands", .{ scenario.name, command.name }));
            }
        }
        if (setups > 1) return null_after(complain("scenario {s}: several setup commands", .{scenario.name}));
    }
    const checks = try arena.alloc(schema.Check, definition.checks.len);
    for (definition.checks, checks, 0..) |name, *check, index| {
        var path_buffer: [256]u8 = undefined;
        const path = schema.record_path_format(&path_buffer, name) catch
            return null_after(complain("check name {s} (letters, digits, _ and -)", .{name}));
        for (definition.checks[0..index]) |other| if (std.mem.eql(u8, other, name)) {
            return null_after(complain("check {s} twice", .{name}));
        };
        check.* = .{ .name = name, .file = try arena.dupe(u8, path) };
    }
    return .{ .profiles = profiles, .scenarios = definition.scenarios, .checks = checks };
}

fn null_after(_: i32) ?schema.Description {
    return null;
}

fn nodes_have(nodes: []const NodeDefinition, name: []const u8) bool {
    for (nodes) |node| if (std.mem.eql(u8, node.name, name)) return true;
    return false;
}

test "a definition becomes the description Zig's System makes" {
    var arena_state = arena_new();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\{"profiles":[{"name":"default","nodes":[
        \\  {"name":"pg","spec":{"image":"postgres:18","ready":{"tcp":5432}}},
        \\  {"name":"client","spec":{"build":{"context":".","dockerfile":"Dockerfile"},
        \\   "coverage":{"include":["datomic"]},"after":["pg"]}}]}],
        \\ "scenarios":[{"name":"append","node":"client","program":"/opt/workload/run",
        \\   "commands":[{"kind":"parallel_driver","name":"txn"},{"kind":"eventually","name":"final"}]}],
        \\ "checks":["elle"]}
    ;
    const definition = try std.json.parseFromSliceLeaky(Definition, arena, source, .{ .allocate = .alloc_always });
    const description = (try description_make(arena, definition)).?;
    const client = description.profiles[0].nodes[1];
    try std.testing.expectEqualStrings("pg", client.after[0]);
    try std.testing.expectEqualStrings("DETERMINISMO_COVERAGE=datomic", client.env[0]);
    try std.testing.expectEqualStrings("/opt/workload/run", description.scenarios[0].program.?);
    try std.testing.expectEqualStrings(schema.record_path("elle"), description.checks[0].file);
}

test "a definition that is not one is refused" {
    var arena_state = arena_new();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][]const u8{
        // A dependency that is no node.
        \\{"profiles":[{"name":"d","nodes":[{"name":"a","spec":{"image":"x","after":["b"]}}]}],
        \\ "scenarios":[{"name":"s","commands":[{"kind":"first","name":"c"}]}]}
        ,
        // A program without its node.
        \\{"profiles":[{"name":"d","nodes":[{"name":"a","spec":{"image":"x"}}]}],
        \\ "scenarios":[{"name":"s","program":"/p","commands":[{"kind":"first","name":"c"}]}]}
        ,
        // The scenario every scenario is.
        \\{"profiles":[{"name":"d","nodes":[{"name":"a","spec":{"image":"x"}}]}],
        \\ "scenarios":[{"name":"all","commands":[{"kind":"first","name":"c"}]}]}
        ,
        // A node name a host name cannot be.
        \\{"profiles":[{"name":"d","nodes":[{"name":"Db","spec":{"image":"x"}}]}],
        \\ "scenarios":[{"name":"s","commands":[{"kind":"first","name":"c"}]}]}
    };
    for (sources) |source| {
        const definition = try std.json.parseFromSliceLeaky(Definition, arena, source, .{ .allocate = .alloc_always });
        try std.testing.expectEqual(null, try description_make(arena, definition));
    }
}
