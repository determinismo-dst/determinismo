// SPDX-License-Identifier: MIT
//! det-nodes: the node runtime's command line (see nodes.zig).
//!
//!   det-nodes up                      start every node of /det/system.json, in order
//!   det-nodes start|kill <node>       start a node, or kill all its processes
//!   det-nodes crash|wipe <node>       a power loss (its disk keeps what was synced), or a start
//!                                     fresh from its image; then it starts again
//!   det-nodes pause|resume <node>     freeze or thaw all its processes
//!   det-nodes link <a> <b> up|down    the link between two nodes (or a node and "runner")
//!   det-nodes exec [--coverage] <node> <command>...   run a command inside a node; exits with its
//!     status (--coverage: its JVMs with determinismo's coverage agent, as the node's own)
//!   det-nodes list                    the nodes now: name, state, pid, address, image (JSON lines)
//!   det-nodes writeback               the drawn flusher of nodes with a writeback window: on,
//!                                     their disks synced each window; off, none (init runs it)
//!   det-nodes samples                 each node's CPU and memory every 2 s, as events, for good
//!                                     (init runs it)
//!   det-nodes hold <node> <function> [--caller <f>] [--arg <reg>=<v>] [--and <function> ...]
//!                                     the first thread entering each function held there until
//!                                     released (hold.zig): a race inside a process caused
const std = @import("std");
const assert = std.debug.assert;
const nodes = @import("nodes.zig");
const symbol = @import("symbol.zig");
const hold = @import("hold.zig");
const where = @import("where.zig");
const sdk = @import("determinismo");
const schema = sdk.schema;

const usage =
    \\usage: det-nodes up
    \\       det-nodes start|kill|crash|wipe|pause|resume <node>
    \\       det-nodes link <a> <b> up|down
    \\       det-nodes upgrade <node> next|base
    \\       det-nodes exec [--coverage] <node> <command>...
    \\       det-nodes list
    \\       det-nodes symbol <node> <name> [--field <path>] [--pid <pid>]
    \\       det-nodes hold <node> <function> [--caller <function>] [--arg <register>=<value>]
    \\                      [--arg-field <register>:<type>:<path>=<value>] [--repeat] [--every] [--direct]
    \\                      [--and <function> [--caller ...] [--arg ...]]... [--pid <pid>] [--timeout-ms <ms>]
    \\       det-nodes where <node> <address>... [--pid <pid>] [--return]
    \\       det-nodes cfi <node> <pc> <return address>... [--pid <pid>]
    \\       det-nodes writeback
    \\       det-nodes samples
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 2) return usage_exit();
    const command = arguments[1];
    const eql = std.mem.eql;
    // An action on the platform is done whole, whatever becomes of who asked for it: out of its
    // requester's process group, which the composer kills with the requester at a timeline's
    // length. A driver's power loss killed in its wait for the freeze left the node frozen, and
    // one killed after its cut left the disk dropping writes ("faults leave nothing behind once
    // they stop": local-fs run 744, 15 finds, timeline 165's two crashes in their drivers'
    // groups at 41.56 s, gone at the length with the node frozen). `exec` stays in it: what it
    // runs in the node is the requester's own, and goes with it.
    if (!eql(u8, command, "exec")) _ = std.os.linux.setpgid(0, 0);
    const system = try nodes.system_load(arena);
    if (eql(u8, command, "link")) {
        if (arguments.len != 5) return usage_exit();
        const up = eql(u8, arguments[4], "up");
        if (!up and !eql(u8, arguments[4], "down")) return usage_exit();
        return nodes.link_set(&system, arguments[2], arguments[3], if (up) .up else .down);
    }
    if (eql(u8, command, "up")) return nodes.up(arena, &system);
    if (eql(u8, command, "list")) return list(arena, &system);
    if (eql(u8, command, "writeback")) nodes.writeback_loop(&system);
    if (eql(u8, command, "samples")) nodes.samples_loop(&system);
    if (eql(u8, command, "exec")) {
        // `exec --coverage <node> <command>...`: its JVMs with the coverage agent (nodes.ExecOptions).
        const covered = arguments.len > 2 and eql(u8, arguments[2], "--coverage");
        const first: usize = if (covered) 3 else 2;
        if (arguments.len < first + 2) return usage_exit();
        const node = system.node(arguments[first]) orelse return error.UnknownNode;
        const argv = try arena.alloc([]const u8, arguments.len - first - 1);
        for (arguments[first + 1 ..], argv) |argument, *target| target.* = argument;
        std.process.exit(try nodes.exec(arena, node, argv, .{ .coverage = covered }));
    }
    if (eql(u8, command, "upgrade")) {
        if (arguments.len != 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        const next = eql(u8, arguments[3], "next");
        if (!next and !eql(u8, arguments[3], "base")) return usage_exit();
        return nodes.upgrade(arena, &system, node, next);
    }
    if (eql(u8, command, "hold")) {
        // `hold <node> <function> ...`: the first thread entering the function (with the caller
        // and argument asked) held there until this command is stopped (hold.zig).
        if (arguments.len < 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        const options = hold.parse(node.name, arguments[3], arguments[4..]) catch return usage_exit();
        std.process.exit(try hold.run(arena, options));
    }
    if (eql(u8, command, "symbol")) {
        // `symbol <node> <name> [--field <path>] [--pid <pid>]`: where a variable (or function)
        // of the node's processes is (symbol.zig), a JSON line, with its type when the module has
        // DWARF; a field of it by its path (`stats.accepted`, `table[2]`); the first of the
        // node's processes that defines the name, or the one given.
        if (arguments.len < 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        var field: ?[]const u8 = null;
        var given: ?std.os.linux.pid_t = null;
        var option = arguments[4..];
        while (option.len > 0) {
            if (option.len < 2) return usage_exit();
            if (eql(u8, option[0], "--field")) {
                field = option[1];
            } else if (eql(u8, option[0], "--pid")) {
                given = try std.fmt.parseInt(std.os.linux.pid_t, option[1], 10);
            } else return usage_exit();
            option = option[2..];
        }
        var found_pids: [1024]std.os.linux.pid_t = undefined;
        const pids = if (given) |pid| blk: {
            found_pids[0] = pid;
            break :blk found_pids[0..1];
        } else found_pids[0..try nodes.processes(node.name, &found_pids)];
        for (pids) |pid| {
            const found = symbol.find(arena, pid, arguments[3], field) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.debug.print("det-nodes: {s} in {s} (process {d}): {s}\n", .{ arguments[3], node.name, pid, @errorName(err) });
                    std.process.exit(1);
                },
            } orelse continue;
            var out: std.Io.Writer.Allocating = .init(arena);
            try symbol.print(&out.writer, found);
            const text = out.written();
            var written: usize = 0;
            while (written < text.len) {
                const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
                if (std.os.linux.errno(result) != .SUCCESS) return error.Write;
                written += result;
            }
            return;
        }
        std.debug.print("det-nodes: no process of {s} defines {s}\n", .{ node.name, arguments[3] });
        std.process.exit(1);
    }
    if (eql(u8, command, "cfi")) {
        // `cfi <node> <pc> <return address>... [--pid <pid>]`: how each frame finds its caller
        // (where.zig's Rule: the CFA as a register plus an offset, the return address and the
        // caller's rbp from it; the module's .eh_frame, else the frame pointers' rule), with its
        // name, from the first of the node's processes (or the one given) whose code holds the
        // pc: a JSON line each, {"address","at","function","cfa_register","cfa_offset",
        // "return_at","rbp_at","cfi"}, the rule's fields null outside code. A stack read at a
        // stop is unwound from these where it was read (debug.cljc's frames).
        if (arguments.len < 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        var given: ?std.os.linux.pid_t = null;
        var addresses: std.ArrayList(u64) = .empty;
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            if (eql(u8, arguments[index], "--pid")) {
                if (index + 1 >= arguments.len) return usage_exit();
                given = try std.fmt.parseInt(std.os.linux.pid_t, arguments[index + 1], 10);
                index += 1;
                continue;
            }
            try addresses.append(arena, try std.fmt.parseInt(u64, arguments[index], 0));
        }
        if (addresses.items.len == 0) return usage_exit();
        var found_pids: [1024]std.os.linux.pid_t = undefined;
        const pids = if (given) |pid| blk: {
            found_pids[0] = pid;
            break :blk found_pids[0..1];
        } else found_pids[0..try nodes.processes(node.name, &found_pids)];
        if (pids.len == 0) {
            std.debug.print("det-nodes: {s} has no process\n", .{node.name});
            std.process.exit(1);
        }
        // The process whose code holds the pc: its frames are all its own.
        const found = for (pids) |pid| {
            const process: where.Process = .read(arena, pid);
            const unwound = try where.unwinding(arena, &process, addresses.items);
            if (unwound[0].named.at != null) break unwound;
            process.release();
        } else {
            std.debug.print("det-nodes: no process of {s} holds 0x{x}\n", .{ node.name, addresses.items[0] });
            std.process.exit(1);
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        for (addresses.items, found) |address, one| {
            try out.writer.print("{{\"address\":\"0x{x}\",\"at\":", .{address});
            if (one.named.at) |text| try std.json.Stringify.value(text, .{}, &out.writer) else try out.writer.writeAll("null");
            try out.writer.writeAll(",\"function\":");
            if (one.named.function) |text| try std.json.Stringify.value(text, .{}, &out.writer) else try out.writer.writeAll("null");
            if (one.rule) |rule| {
                try out.writer.print(",\"cfa_register\":{d},\"cfa_offset\":{d},\"return_at\":{d},\"rbp_at\":", .{
                    rule.cfa_register, rule.cfa_offset, rule.return_at,
                });
                if (rule.rbp_at) |at| try out.writer.print("{d}", .{at}) else try out.writer.writeAll("null");
                try out.writer.print(",\"cfi\":{}}}\n", .{rule.cfi});
            } else try out.writer.writeAll(",\"cfa_register\":null}\n");
        }
        const text = out.written();
        var written: usize = 0;
        while (written < text.len) {
            const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
            if (std.os.linux.errno(result) != .SUCCESS) return error.Write;
            written += result;
        }
        return;
    }
    if (eql(u8, command, "where")) {
        // `where <node> <address>... [--pid <pid>] [--return]`: each address named as a crash's
        // stack names its frames (where.zig: its source line, its Go function and line, its ELF
        // function and offset, else its module and offset), from the first of the node's
        // processes (or the one given) whose code holds it; a JSON line each,
        // {"address","at","function"} (`function` its ELF function beside a source line), null
        // outside their code. `--return`: each a return address (a stack's words),
        // the call before it named.
        if (arguments.len < 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        var given: ?std.os.linux.pid_t = null;
        var returned = false;
        var addresses: std.ArrayList(u64) = .empty;
        var index: usize = 3;
        while (index < arguments.len) : (index += 1) {
            if (eql(u8, arguments[index], "--return")) {
                returned = true;
                continue;
            }
            if (eql(u8, arguments[index], "--pid")) {
                if (index + 1 >= arguments.len) return usage_exit();
                given = try std.fmt.parseInt(std.os.linux.pid_t, arguments[index + 1], 10);
                index += 1;
                continue;
            }
            try addresses.append(arena, try std.fmt.parseInt(u64, arguments[index], 0));
        }
        var found_pids: [1024]std.os.linux.pid_t = undefined;
        const pids = if (given) |pid| blk: {
            found_pids[0] = pid;
            break :blk found_pids[0..1];
        } else found_pids[0..try nodes.processes(node.name, &found_pids)];
        if (pids.len == 0) {
            std.debug.print("det-nodes: {s} has no process\n", .{node.name});
            std.process.exit(1);
        }
        const names = try arena.alloc(where.Named, addresses.items.len);
        @memset(names, .{ .at = null, .function = null });
        for (pids) |pid| {
            const process: where.Process = .read(arena, pid);
            defer process.release();
            const found = try where.named(arena, &process, addresses.items, returned);
            var unnamed: u32 = 0;
            for (names, found) |*name, one| {
                if (name.at == null) name.* = one;
                unnamed += @intFromBool(name.at == null);
            }
            if (unnamed == 0) break;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        for (addresses.items, names) |address, name| {
            try out.writer.print("{{\"address\":\"0x{x}\",\"at\":", .{address});
            if (name.at) |text| try std.json.Stringify.value(text, .{}, &out.writer) else try out.writer.writeAll("null");
            try out.writer.writeAll(",\"function\":");
            if (name.function) |text| try std.json.Stringify.value(text, .{}, &out.writer) else try out.writer.writeAll("null");
            try out.writer.writeAll("}\n");
        }
        const text = out.written();
        var written: usize = 0;
        while (written < text.len) {
            const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
            if (std.os.linux.errno(result) != .SUCCESS) return error.Write;
            written += result;
        }
        return;
    }
    if (arguments.len != 3) return usage_exit();
    const name = arguments[2];
    if (eql(u8, command, "start")) {
        const node = system.node(name) orelse return error.UnknownNode;
        return nodes.start(arena, &system, node);
    }
    if (eql(u8, command, "kill")) return nodes.kill(name);
    if (eql(u8, command, "crash") or eql(u8, command, "wipe")) {
        const node = system.node(name) orelse return error.UnknownNode;
        // A driver's power loss persists part of what was not synced as a fault's does (1 in 2,
        // the journal committed after in 1 in 2: faults.zig's partial_draw), unless the node
        // turned it off: local-fs's own power losses, 42,000 of its 44,690 in hunt run 1035,
        // had never had it.
        const partial: ?nodes.Partial = if (node.faults.partial_persistence and
            sdk.random_below_named("crash.partial", 2) == 0) .{
            .seed = sdk.random_u64() | 1,
            .commit = sdk.random_below_named("crash.partial_commit", 2) == 0,
        } else null;
        try if (eql(u8, command, "crash")) nodes.crash(name, partial) else nodes.wipe(name);
        // Another start (a fault's restart) between the stop and this one: the node runs, from
        // what this left (a wiped node's layers already gone), as asked. Redpanda's membership
        // smoke (run 389) failed its member command on that race.
        // Or a fault's kill between its process's clone and its network (start's netlink found
        // its namespace gone): the node was started and killed, the fault starting it again as
        // it does. rqlite's member driver failed its wipe on that race (run 427, 45.8 s).
        return nodes.start(arena, &system, node) catch |err| switch (err) {
            error.AlreadyRunning, error.NoSuchNamespace => {},
            else => err,
        };
    }
    if (eql(u8, command, "pause")) return nodes.freeze(name, .frozen);
    if (eql(u8, command, "resume")) return nodes.freeze(name, .thawed);
    return usage_exit();
}

/// Antithesis's containers.list, at the moment it runs.
fn list(arena: std.mem.Allocator, system: *const schema.System) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (system.nodes) |node| {
        const pid = nodes.pid_recorded(node.name);
        try std.json.Stringify.value(.{
            .name = node.name,
            .state = @tagName(nodes.state_of(node.name)),
            .pid = pid,
            .address = node.address,
            .image = node.digest,
        }, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    const text = out.written();
    var written: usize = 0;
    while (written < text.len) {
        const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
        if (std.os.linux.errno(result) != .SUCCESS) return error.Write;
        written += result;
    }
}

fn usage_exit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
