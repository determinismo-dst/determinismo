// SPDX-License-Identifier: MIT
//! determinismo-sandbox: agent sandboxes on determinismo (docs/SANDBOXES.md). A product on
//! determinismo, not part of it (docs/PRODUCTS.md): a sandbox is a serve machine (a fast VM:
//! POST /machines) and this binary's own record of what was done in it, in its data directory
//! (`--data`, ~/.determinismo/sandboxes by default): `<sandbox>/sandbox.json` (its machine now,
//! what it boots), `record.jsonl` (each step: exec, write, checkpoint, rewind) and `writes/` (each
//! written file's bytes, for replays).
//!
//!   determinismo-sandbox [--serve <url>] [--data <dir>] <command>:
//!     create (--compose <file> | --program <p>) [--profile p] [--scenario s] [--vcpus n] [--memory-mib n]
//!     exec <sandbox> <node> <command>         its status and output
//!     write <sandbox> <node> <path> <file> [--secret]   (`-`: stdin; --secret: no copy kept)
//!     read <sandbox> <node> <path>            the file on stdout
//!     checkpoint <sandbox>                    the machine saved, going on
//!     fork <sandbox> <checkpoint> <count>     new sandboxes, each from the checkpoint
//!     rewind <sandbox> <checkpoint>           its machine replaced by one from the checkpoint
//!     explore <sandbox> <checkpoint> [branches] [time budget]   timelines with faults (a run)
//!     replay <sandbox> <checkpoint> [until]   its steps after the checkpoint, deterministic (a run)
//!     egress <sandbox> <node> <host>...      an HTTPS proxy in the node for those hosts
//!                                             (HTTPS_PROXY: the answer's proxy)
//!     delete <sandbox>                        its machine stopped (its checkpoints stay)
//!     list
//!     mcp                                     the same as MCP tools, over stdio, for an agent
//! Each answers JSON on stdout.
const std = @import("std");
const assert = std.debug.assert;
const Client = @import("serve_client.zig").Client;

const tools_json = @embedFile("sandbox_tools.json");

const Request = struct {
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    vcpus: u32 = 4,
    memory_mib: u32 = 2048,
};

const State = struct { machine: u32, request: Request };

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    client: Client,
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var serve_url: []const u8 = "http://127.0.0.1:7878";
    var data: ?[]const u8 = null;
    var index: usize = 1;
    while (index + 1 < argv.len) {
        if (std.mem.eql(u8, argv[index], "--serve")) {
            serve_url = argv[index + 1];
        } else if (std.mem.eql(u8, argv[index], "--data")) {
            data = argv[index + 1];
        } else break;
        index += 2;
    }
    if (index >= argv.len) usage();
    const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
    const context: Context = .{
        .arena = arena,
        .io = init.io,
        .client = .{ .arena = arena, .io = init.io, .url = serve_url },
        .data = data orelse try std.fs.path.join(arena, &.{ home, ".determinismo", "sandboxes" }),
    };
    try std.Io.Dir.cwd().createDirPath(init.io, context.data);
    const command = argv[index];
    const rest = argv[index + 1 ..];
    if (std.mem.eql(u8, command, "mcp")) return mcp_serve(context);
    const answer = command_run(context, command, rest) catch |err| {
        std.debug.print("determinismo-sandbox: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.writeAll(answer);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

/// A command (the CLI's or a tool's, its arguments as strings): its JSON answer.
fn command_run(context: Context, command: []const u8, args: []const []const u8) ![]const u8 {
    const eql = std.mem.eql;
    const arena = context.arena;
    if (eql(u8, command, "create")) {
        var request: Request = .{};
        var at: usize = 0;
        while (at + 1 < args.len) : (at += 2) {
            const flag = args[at];
            const value = args[at + 1];
            if (eql(u8, flag, "--compose")) {
                request.compose = try absolute(arena, value);
            } else if (eql(u8, flag, "--program")) {
                request.program = try absolute(arena, value);
            } else if (eql(u8, flag, "--profile")) {
                request.profile = value;
            } else if (eql(u8, flag, "--scenario")) {
                request.scenario = value;
            } else if (eql(u8, flag, "--vcpus")) {
                request.vcpus = try std.fmt.parseInt(u32, value, 10);
            } else if (eql(u8, flag, "--memory-mib")) {
                request.memory_mib = try std.fmt.parseInt(u32, value, 10);
            } else return error.Usage;
        }
        const id = try sandbox_new(context, request, null);
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .sandbox = id }, .{})});
    }
    if (eql(u8, command, "list")) return list(context);
    if (args.len == 0) return error.Usage;
    const id = std.fmt.parseInt(u32, args[0], 10) catch return error.Usage;
    var state = try state_read(context, id);
    if (eql(u8, command, "exec")) {
        if (args.len != 3) return error.Usage;
        const result = try context.client.exec(state.machine, args[1], args[2], 600);
        try record(context, id, .{ .op = "exec", .node = args[1], .command = args[2], .status = result.status });
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(result, .{})});
    }
    if (eql(u8, command, "write")) {
        // `--secret` after the file: written, never kept (no copy beside the record, the record
        // says only that a secret went there): a key for the agent inside.
        const secret = args.len == 5 and eql(u8, args[4], "--secret");
        if (args.len != 4 and !secret) return error.Usage;
        const bytes = if (eql(u8, args[3], "-")) stdin: {
            var buffer: [64 * 1024]u8 = undefined;
            var reader = std.Io.File.stdin().reader(context.io, &buffer);
            break :stdin try reader.interface.allocRemaining(arena, .limited(64 << 20));
        } else try std.Io.Dir.cwd().readFileAlloc(context.io, args[3], arena, .limited(64 << 20));
        if (secret) {
            const reply = try context.client.call("PUT", try files_path(arena, state.machine, args[1], args[2]), bytes);
            if (reply.status / 100 != 2) return error.WriteFailed;
            try record(context, id, .{ .op = "secret", .node = args[1], .path = args[2] });
            return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .written = bytes.len, .kept = false }, .{})});
        }
        return write(context, id, state, args[1], args[2], bytes);
    }
    if (eql(u8, command, "read")) {
        if (args.len != 3) return error.Usage;
        const reply = try context.client.call("GET", try files_path(arena, state.machine, args[1], args[2]), null);
        if (reply.status != 200) return error.ReadFailed;
        return reply.body;
    }
    if (eql(u8, command, "checkpoint")) {
        const name = try context.client.checkpoint(state.machine);
        try record(context, id, .{ .op = "checkpoint", .checkpoint = name });
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .checkpoint = name }, .{})});
    }
    if (eql(u8, command, "fork")) {
        if (args.len != 3) return error.Usage;
        const count = try std.fmt.parseInt(u32, args[2], 10);
        if (count == 0 or count > 32) return error.Usage;
        var ids: std.ArrayList(u32) = .empty;
        for (0..count) |_| try ids.append(arena, try sandbox_new(context, state.request, args[1]));
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .sandboxes = ids.items }, .{})});
    }
    if (eql(u8, command, "rewind")) {
        if (args.len != 2) return error.Usage;
        try context.client.delete(state.machine);
        state.machine = try machine_new(context, state.request, args[1]);
        try state_write(context, id, state);
        try record(context, id, .{ .op = "rewind", .checkpoint = args[1] });
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .sandbox = id, .machine = state.machine }, .{})});
    }
    if (eql(u8, command, "explore")) {
        if (args.len < 2) return error.Usage;
        const branches: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 16;
        return run_start(context, state.request, args[1], .{ .branches = branches, .time_budget = if (args.len > 3) args[3] else null });
    }
    if (eql(u8, command, "replay")) {
        if (args.len < 2) return error.Usage;
        const until: ?u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else null;
        const steps = try replay_steps(context, id, args[1], until);
        return run_start(context, state.request, args[1], .{ .branches = 1, .steps = steps });
    }
    if (eql(u8, command, "egress")) {
        // A way out for a node: an HTTPS proxy in it for the hosts named (serve's egress).
        if (args.len < 3) return error.Usage;
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .node = args[1], .allow = args[2..] }, .{})});
        const reply = try context.client.call("POST", try std.fmt.allocPrint(arena, "/machines/{d}/egress", .{state.machine}), body);
        if (reply.status != 200) return error.EgressRefused;
        try record(context, id, .{ .op = "egress", .node = args[1], .allow = args[2..] });
        return reply.body;
    }
    if (eql(u8, command, "delete")) {
        try context.client.delete(state.machine);
        try record(context, id, .{ .op = "delete" });
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .sandbox = id, .deleted = true }, .{})});
    }
    return error.Usage;
}

/// A new sandbox: its machine (from a checkpoint for a fork), its state, its record begun.
fn sandbox_new(context: Context, request: Request, from: ?[]const u8) !u32 {
    const machine = try machine_new(context, request, from);
    var highest: u32 = 0;
    var directory = try std.Io.Dir.cwd().openDir(context.io, context.data, .{ .iterate = true });
    defer directory.close(context.io);
    var entries = directory.iterate();
    while (try entries.next(context.io)) |entry| highest = @max(highest, std.fmt.parseInt(u32, entry.name, 10) catch 0);
    const id = highest + 1;
    try std.Io.Dir.cwd().createDirPath(context.io, try sandbox_path(context, id, ""));
    try state_write(context, id, .{ .machine = machine, .request = request });
    if (from) |checkpoint| try record(context, id, .{ .op = "forked", .checkpoint = checkpoint });
    return id;
}

fn machine_new(context: Context, request: Request, from: ?[]const u8) !u32 {
    const Made = struct { machine: u32 = 0 };
    const body = try std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(.{
        .program = request.program,
        .compose = request.compose,
        .profile = request.profile,
        .scenario = request.scenario,
        .vcpus = request.vcpus,
        .memory_mib = request.memory_mib,
        .from = from,
    }, .{ .emit_null_optional_fields = false })});
    return (try context.client.json(Made, "POST", "/machines", body)).machine;
}

fn write(context: Context, id: u32, state: State, node: []const u8, path: []const u8, bytes: []const u8) ![]const u8 {
    const reply = try context.client.call("PUT", try files_path(context.arena, state.machine, node, path), bytes);
    if (reply.status / 100 != 2) return error.WriteFailed;
    // Its bytes kept beside the record: a replay writes them again.
    const writes = try sandbox_path(context, id, "writes");
    try std.Io.Dir.cwd().createDirPath(context.io, writes);
    const name = try std.fmt.allocPrint(context.arena, "writes/{d}.bin", .{monotonic_ns()});
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = try sandbox_path(context, id, name), .data = bytes });
    try record(context, id, .{ .op = "write", .node = node, .path = path, .bytes = bytes.len, .file = name });
    return std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(.{ .written = bytes.len }, .{})});
}

const RunOptions = struct { branches: u32, time_budget: ?[]const u8 = null, steps: []const []const u8 = &.{} };

/// A run of serve's from a checkpoint: its scenario's timelines, or (with steps) held timelines
/// running them in order. Its id.
fn run_start(context: Context, request: Request, checkpoint: []const u8, options: RunOptions) ![]const u8 {
    const Started = struct { id: u32 = 0 };
    const body = try std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(.{
        .program = request.program,
        .compose = request.compose,
        .profile = request.profile,
        .scenario = request.scenario,
        .memory_mib = request.memory_mib,
        .branches = options.branches,
        .time_budget = options.time_budget,
        .checkpoint = checkpoint,
        .checkpoint_steps = options.steps,
    }, .{ .emit_null_optional_fields = false })});
    const started = try context.client.json(Started, "POST", "/runs", body);
    return std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(.{ .run = started.id }, .{})});
}

/// The steps after `checkpoint` in the sandbox's record, as guest commands: each exec its
/// command in its node, each write its bytes again (in parts a step holds); `until`, those
/// before that one (0-based). Up to a rewind (the machine after it went on from elsewhere).
fn replay_steps(context: Context, id: u32, checkpoint: []const u8, until: ?u32) ![]const []const u8 {
    const arena = context.arena;
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, try sandbox_path(context, id, "record.jsonl"), arena, .limited(64 << 20)) catch "";
    const Step = struct { op: []const u8 = "", node: []const u8 = "", command: []const u8 = "", path: []const u8 = "", file: []const u8 = "", checkpoint: []const u8 = "" };
    var steps: std.ArrayList([]const u8) = .empty;
    var after = false;
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const step = std.json.parseFromSliceLeaky(Step, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const eql = std.mem.eql;
        if (eql(u8, step.op, "checkpoint") or eql(u8, step.op, "forked")) {
            if (eql(u8, step.checkpoint, checkpoint)) after = true;
            continue;
        }
        if (!after) continue;
        if (eql(u8, step.op, "rewind")) break;
        if (until) |stop| if (count >= stop) break;
        count += 1;
        if (eql(u8, step.op, "exec")) {
            try steps.append(arena, try node_command(arena, step.node, step.command));
        } else if (eql(u8, step.op, "write")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, try sandbox_path(context, id, step.file), arena, .limited(64 << 20));
            var quoted: std.ArrayList(u8) = .empty;
            try shell_quote(arena, &quoted, step.path);
            try steps.append(arena, try node_command(arena, step.node, try std.fmt.allocPrint(arena, "mkdir -p \"$(dirname {s})\" && : > {s}", .{ quoted.items, quoted.items })));
            var at: usize = 0;
            while (at < bytes.len) : (at += 2048) {
                const part = bytes[at..@min(bytes.len, at + 2048)];
                const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(part.len));
                _ = std.base64.standard.Encoder.encode(encoded, part);
                try steps.append(arena, try node_command(arena, step.node, try std.fmt.allocPrint(arena, "echo {s} | base64 -d >> {s}", .{ encoded, quoted.items })));
            }
        }
    }
    if (!after) return error.NoSuchCheckpoint;
    return steps.items;
}

fn node_command(arena: std.mem.Allocator, node: []const u8, command: []const u8) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    try line.print(arena, "det-nodes exec {s} /bin/sh -c ", .{node});
    try shell_quote(arena, &line, command);
    return line.items;
}

fn list(context: Context) ![]const u8 {
    const arena = context.arena;
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    var directory = try std.Io.Dir.cwd().openDir(context.io, context.data, .{ .iterate = true });
    defer directory.close(context.io);
    var entries = directory.iterate();
    var first = true;
    while (try entries.next(context.io)) |entry| {
        const id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const state = state_read(context, id) catch continue;
        if (!first) try out.append(arena, ',');
        first = false;
        try out.print(arena, "{f}", .{std.json.fmt(.{ .sandbox = id, .machine = state.machine }, .{})});
    }
    try out.append(arena, ']');
    return out.items;
}

fn state_read(context: Context, id: u32) !State {
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, try sandbox_path(context, id, "sandbox.json"), context.arena, .limited(1 << 16)) catch return error.NoSuchSandbox;
    return std.json.parseFromSliceLeaky(State, context.arena, text, .{ .ignore_unknown_fields = true });
}

fn state_write(context: Context, id: u32, state: State) !void {
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = try sandbox_path(context, id, "sandbox.json"),
        .data = try std.fmt.allocPrint(context.arena, "{f}", .{std.json.fmt(state, .{})}),
    });
}

/// A step appended to the sandbox's record.
fn record(context: Context, id: u32, step: anytype) !void {
    const path = try sandbox_path(context, id, "record.jsonl");
    const line = try std.fmt.allocPrint(context.arena, "{f}\n", .{std.json.fmt(step, .{})});
    const existing = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .limited(64 << 20)) catch "";
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = try std.mem.concat(context.arena, u8, &.{ existing, line }) });
}

fn sandbox_path(context: Context, id: u32, name: []const u8) ![]const u8 {
    return std.fs.path.join(context.arena, &.{ context.data, try std.fmt.allocPrint(context.arena, "{d}", .{id}), name });
}

fn files_path(arena: std.mem.Allocator, machine: u32, node: []const u8, path: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '.' or byte == '-' or byte == '_') {
            try encoded.append(arena, byte);
        } else try encoded.print(arena, "%{X:0>2}", .{byte});
    }
    return std.fmt.allocPrint(arena, "/machines/{d}/files?node={s}&path={s}", .{ machine, node, encoded.items });
}

fn absolute(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = std.os.linux.getcwd(&buffer, buffer.len);
    if (std.os.linux.errno(size) != .SUCCESS) return error.NoWorkingDirectory;
    return std.fs.path.resolve(arena, &.{ std.mem.sliceTo(&buffer, 0), path });
}

fn shell_quote(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, byte);
    }
    try out.append(arena, '\'');
}

fn monotonic_ns() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

// MCP (JSON-RPC 2.0 over stdio, a message a line): the commands above as tools. --------------

fn mcp_serve(context: Context) !void {
    var stdin_buffer: [1 << 20]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(context.io, &stdin_buffer);
    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(context.io, &stdout_buffer);
    while (true) {
        const line = stdin.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        _ = stdin.interface.take(1) catch {};
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        var call_context = context;
        call_context.arena = arena_state.allocator();
        call_context.client.arena = call_context.arena;
        const reply = mcp_answer(call_context, line) catch |err| try std.fmt.allocPrint(call_context.arena, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}", .{@errorName(err)});
        if (reply.len == 0) continue; // A notification.
        try stdout.interface.writeAll(reply);
        try stdout.interface.writeAll("\n");
        try stdout.interface.flush();
    }
}

fn mcp_answer(context: Context, line: []const u8) ![]const u8 {
    const arena = context.arena;
    const message = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    if (message != .object) return error.BadMessage;
    const method = (message.object.get("method") orelse return "").string;
    const id = message.object.get("id") orelse return ""; // A notification: no answer.
    const id_text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(id, .{})});
    if (std.mem.eql(u8, method, "initialize")) {
        return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"determinismo-sandbox\",\"version\":\"0.1\"}}}}}}", .{id_text});
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":{s}}}}}", .{ id_text, tools_json });
    }
    if (!std.mem.eql(u8, method, "tools/call")) {
        return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}", .{id_text});
    }
    const params = (message.object.get("params") orelse return error.BadMessage).object;
    const name = params.get("name").?.string;
    const arguments = if (params.get("arguments")) |found| found.object else std.json.ObjectMap.empty;
    const text = tool_call(context, name, arguments) catch |err| try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)});
    const failed = std.mem.startsWith(u8, text, "error: ");
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}}}", .{ id_text, std.json.fmt(text, .{}), failed });
}

/// A tool call as the command it stands for.
fn tool_call(context: Context, name: []const u8, args: std.json.ObjectMap) ![]const u8 {
    const arena = context.arena;
    const string = struct {
        fn of(a: std.mem.Allocator, map: std.json.ObjectMap, key: []const u8) ![]const u8 {
            const value = map.get(key) orelse return error.MissingArgument;
            return switch (value) {
                .string => |text| text,
                .integer => |number| std.fmt.allocPrint(a, "{d}", .{number}),
                else => error.BadArgument,
            };
        }
    }.of;
    const eql = std.mem.eql;
    if (!std.mem.startsWith(u8, name, "sandbox_")) return error.NoSuchTool;
    const verb = name["sandbox_".len..];
    if (eql(u8, verb, "create")) {
        var flags: std.ArrayList([]const u8) = .empty;
        for ([_][2][]const u8{ .{ "compose", "--compose" }, .{ "program", "--program" }, .{ "profile", "--profile" }, .{ "scenario", "--scenario" }, .{ "vcpus", "--vcpus" }, .{ "memory_mib", "--memory-mib" } }) |pair| {
            if (args.get(pair[0]) != null) try flags.appendSlice(arena, &.{ pair[1], try string(arena, args, pair[0]) });
        }
        return command_run(context, "create", flags.items);
    }
    if (eql(u8, verb, "list")) return command_run(context, "list", &.{});
    const sandbox = try string(arena, args, "sandbox");
    if (eql(u8, verb, "write_file")) {
        const id = try std.fmt.parseInt(u32, sandbox, 10);
        return write(context, id, try state_read(context, id), try string(arena, args, "node"), try string(arena, args, "path"), try string(arena, args, "content"));
    }
    const fields: []const []const u8 = if (eql(u8, verb, "exec"))
        &.{ "node", "command" }
    else if (eql(u8, verb, "read_file"))
        &.{ "node", "path" }
    else if (eql(u8, verb, "fork"))
        &.{ "checkpoint", "count" }
    else if (eql(u8, verb, "rewind") or eql(u8, verb, "explore") or eql(u8, verb, "replay"))
        &.{"checkpoint"}
    else
        &.{};
    var command_args: std.ArrayList([]const u8) = .empty;
    try command_args.append(arena, sandbox);
    for (fields) |field| try command_args.append(arena, try string(arena, args, field));
    if (eql(u8, verb, "explore")) {
        try command_args.append(arena, if (args.get("branches") != null) try string(arena, args, "branches") else "16");
        if (args.get("time_budget") != null) try command_args.append(arena, try string(arena, args, "time_budget"));
    }
    if (eql(u8, verb, "replay") and args.get("until") != null) try command_args.append(arena, try string(arena, args, "until"));
    const command = if (eql(u8, verb, "read_file")) "read" else verb;
    return command_run(context, command, command_args.items);
}

fn usage() noreturn {
    std.debug.print(
        \\usage: determinismo-sandbox [--serve <url>] [--data <dir>] <command>
        \\  create (--compose <file> | --program <p>) [--profile p] [--scenario s] [--vcpus n] [--memory-mib n]
        \\  exec <sandbox> <node> <command> | write <sandbox> <node> <path> <file|-> | read <sandbox> <node> <path>
        \\  checkpoint <sandbox> | fork <sandbox> <checkpoint> <count> | rewind <sandbox> <checkpoint>
        \\  explore <sandbox> <checkpoint> [branches] [time budget] | replay <sandbox> <checkpoint> [until]
        \\  egress <sandbox> <node> <host>... | delete <sandbox> | list | mcp
        \\
    , .{});
    std.process.exit(2);
}
