// SPDX-License-Identifier: MIT
//! det-nodes hold <node> <point> [--and <point>]... [--pid <pid>] [--timeout-ms <ms>], a point
//! being `<function> [--caller <function>] [--arg <register>=<value>]`: holds, for each point,
//! the first thread of a node's process that enters its function, at its first instruction,
//! while the process's other threads run on. `<function>+<offset>` and `<function>@<line>` (or
//! `<function>@<file>:<line>`) hold a thread inside the function instead, at that byte or at the
//! first instruction of that source line's code (Spec below: the module's table of lines names
//! it, and a `{"point":<n>,"offset":<bytes in>,"starts":<n>}` line after `armed` says where it
//! landed). Each held thread goes on when this command is told
//! (`release <point>` on its standard input, then SIGUSR1), all of them on SIGTERM or SIGINT, as
//! it ends. A race inside a process made to happen: a scenario holds the thread that would write
//! first and lets it go once the other has written; several points order several threads (one
//! held at its first step until another reached its own).
//!
//! `--caller`: only a thread with a return address in that function on its stack (the entry's
//! own caller, then up the frame pointers' chain: Go keeps frame pointers on amd64, as C built
//! with them does). `--arg`: only a thread whose register has that value at the entry (Go's
//! ABIInternal: rax, rbx, rcx, rdi, rsi, r8 to r11 in order, a method's receiver first; the
//! System V ABI: rdi, rsi, rdx, rcx, r8, r9). Other entries step over the breakpoint and go on.
//! `--arg-field <register>:<type>:<path>=<value>`: only a thread whose register points at a
//! `<type>` (its name in the module's DWARF: Go's `github.com/hashicorp/raft.followerReplication`)
//! whose field `<path>` (`peer.Address`, members and indexes, no pointer followed) has that value:
//! a number for an integer, a boolean or a pointer (of its size); the text for a Go string (its
//! pointer and length) — a call told apart by what its argument holds, not the argument itself
//! (a replication to one follower among the leader's goroutines, all in the same function).
//! `--arg-string <register>:<register>=<text>`: only a thread whose string argument, its data's
//! pointer and its length in those registers (Go passes a string in two: `target ServerAddress`
//! of NetworkTransport.RequestVote in rdi and rsi), is that text: one peer's request among the
//! goroutines sending a campaign's.
//! `--later`: the point's breakpoint is left out until `arm <point>` (on its standard input, then
//! SIGUSR1, as a release), then `{"armed_point":<n>}`: one hold a process (a single tracer), its
//! points armed as a walk needs them (a leader's replication to one follower held only once that
//! follower caught up).
//! `--repeat`: once its thread is let go, the point holds the next one that matches (a writer
//! kept from landing again while the rest goes on). `--every`: every thread that matches is held
//! until the end (all of a node's sends of a message kept from leaving). `--direct`: the caller
//! must be the immediate one (a store's Set called by persistVote itself, not through SetUint64).
//!
//! A held thread keeps what it holds: a lock, and in Go its P (a held thread with the only P
//! stops every goroutine, and a collection's stop-the-world waits for it). A Go program held
//! this way runs with GOMAXPROCS of 2 or more and its collector off (GOGC=off) for the hold.
//!
//! It prints JSON lines: `{"armed":<pid>,...}` once its breakpoints are in (a caller may then go
//! on), `{"held":<tid>,"point":<n>}` as it holds one, `{"released":<tid>,"point":<n>}` as it lets
//! one go, and `{"held":null}` (exit 1) when none came within the timeout (10 s of virtual time
//! by default, in whole seconds). The process's threads are seized (ptrace, new ones followed),
//! each entry's first byte a software breakpoint (int3) written through /proc/<pid>/mem; at the
//! end every thread is stopped, the bytes restored and each thread detached. Deterministic as the
//! guest is.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const nodes = @import("nodes.zig");
const sdk = @import("determinismo");
const symbol = @import("symbol.zig");
const dwarf_types = @import("dwarf_types.zig");
const where = @import("where.zig");

const ptrace_cont = 7;
const ptrace_singlestep = 9;
const ptrace_getregs = 12;
const ptrace_setregs = 13;
const ptrace_detach = 17;
const ptrace_seize = 0x4206;
const ptrace_interrupt = 0x4207;
const ptrace_o_traceclone = 0x8;
const ptrace_event_clone = 3;
const ptrace_event_stop = 128;
const wait_all = 0x40000000; // __WALL: threads too.
const wait_no_hang = 1; // WNOHANG
const signal_trap = 5;
const int3: u8 = 0xcc;
const processes_max = 1024;
const threads_max = 1024;
const frames_max = 32;
pub const points_max = 4;
const threads_held_max = 64;
/// The longest text an `--arg-field` compares.
const field_text_max = 256;

/// struct user_regs_struct: 27 registers.
const Regs = [27]u64;
const rbp_index = 4;
/// Go's ABIInternal keeps the running goroutine (its g) in r14.
const r14_index = 1;
const rip_index = 16;
const rsp_index = 19;

/// The registers `--arg` names, by their index in user_regs_struct.
const register_names = [_]struct { name: []const u8, index: u8 }{
    .{ .name = "r15", .index = 0 },  .{ .name = "r14", .index = 1 },  .{ .name = "r13", .index = 2 },
    .{ .name = "r12", .index = 3 },  .{ .name = "rbp", .index = 4 },  .{ .name = "rbx", .index = 5 },
    .{ .name = "r11", .index = 6 },  .{ .name = "r10", .index = 7 },  .{ .name = "r9", .index = 8 },
    .{ .name = "r8", .index = 9 },   .{ .name = "rax", .index = 10 }, .{ .name = "rcx", .index = 11 },
    .{ .name = "rdx", .index = 12 }, .{ .name = "rsi", .index = 13 }, .{ .name = "rdi", .index = 14 },
};

/// A point as written: `<function>` (its entry), `<function>+<offset>` (that many bytes in, the
/// first byte of an instruction: det-nodes where names one), `<function>@<line>` or
/// `<function>@<file>:<line>` (the first instruction of the source line's code inside the
/// function, from its module's table of lines: where.zig's line_starts; `<file>` the end of the
/// file's path, any file without it). A point inside a function holds a thread there: between a
/// test and the act it guards (Turso's Completion::set_waker, its waker stored after `finished()`
/// returned false: `...::set_waker@389`; its lost wakeup, fixed by tursodatabase/turso#11848),
/// where an entry would hold it before the test.
pub const Spec = struct {
    function: []const u8,
    offset: ?u64 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,

    fn at_entry(spec: Spec) bool {
        return spec.offset == null and spec.line == null;
    }
};

pub fn spec_parse(text: []const u8) error{Usage}!Spec {
    if (text.len == 0) return error.Usage;
    if (std.mem.lastIndexOfScalar(u8, text, '@')) |at| {
        if (at == 0) return error.Usage;
        const place = text[at + 1 ..];
        const colon = std.mem.lastIndexOfScalar(u8, place, ':');
        const line = std.fmt.parseInt(u32, if (colon) |c| place[c + 1 ..] else place, 10) catch return error.Usage;
        if (line == 0) return error.Usage;
        const file: ?[]const u8 = if (colon) |c| place[0..c] else null;
        if (file != null and file.?.len == 0) return error.Usage;
        return .{ .function = text[0..at], .file = file, .line = line };
    }
    // An offset is a number after the last plus (`operator+` and `operator+=` are names).
    if (std.mem.lastIndexOfScalar(u8, text, '+')) |plus| if (plus > 0) {
        if (std.fmt.parseInt(u64, text[plus + 1 ..], 0)) |offset| {
            return .{ .function = text[0..plus], .offset = offset };
        } else |_| {}
    };
    return .{ .function = text };
}

pub const Arg = struct { index: u8, value: u64 };

/// `--arg-string`: a string argument by its pointer's and its length's registers.
pub const ArgString = struct { pointer: u8, length: u8, value: []const u8 };

/// `--arg-field`, as given.
pub const ArgField = struct { index: u8, type_name: []const u8, path: []const u8, value: []const u8 };

/// `--arg-field`, resolved: where the field is from what the register points at, and what it
/// must hold.
const FieldMatch = struct {
    index: u8,
    offset: u64,
    size: u64,
    want: union(enum) { number: u64, text: []const u8 },
};

pub const PointOptions = struct {
    function: []const u8,
    caller: ?[]const u8 = null,
    arg: ?Arg = null,
    field: ?ArgField = null,
    string: ?ArgString = null,
    /// Once its thread is let go, the point holds the next one that matches.
    repeat: bool = false,
    /// Every thread that matches is held (until the end), not only the first.
    every: bool = false,
    /// `caller` must be the immediate caller (the entry's return address), not one further up.
    direct: bool = false,
    /// Its breakpoint left out until `arm <point>`.
    later: bool = false,
};

pub const Options = struct {
    node: []const u8,
    points: [points_max]PointOptions = undefined,
    count: u32 = 0,
    pid: ?linux.pid_t = null,
    timeout_ms: u64 = 10_000,
};

pub fn parse(node: []const u8, function: []const u8, rest: []const []const u8) !Options {
    var options: Options = .{ .node = node };
    options.points[0] = .{ .function = function };
    options.count = 1;
    var option = rest;
    while (option.len > 0) {
        const point = &options.points[options.count - 1];
        if (std.mem.eql(u8, option[0], "--repeat")) {
            point.repeat = true;
            option = option[1..];
            continue;
        }
        if (std.mem.eql(u8, option[0], "--every")) {
            point.every = true;
            option = option[1..];
            continue;
        }
        if (std.mem.eql(u8, option[0], "--direct")) {
            point.direct = true;
            option = option[1..];
            continue;
        }
        if (std.mem.eql(u8, option[0], "--later")) {
            point.later = true;
            option = option[1..];
            continue;
        }
        if (option.len < 2) return error.Usage;
        const name = option[0];
        const value = option[1];
        if (std.mem.eql(u8, name, "--and")) {
            if (options.count == points_max) return error.TooManyPoints;
            options.points[options.count] = .{ .function = value };
            options.count += 1;
        } else if (std.mem.eql(u8, name, "--caller")) {
            point.caller = value;
        } else if (std.mem.eql(u8, name, "--arg")) {
            point.arg = try arg_parse(value);
        } else if (std.mem.eql(u8, name, "--arg-field")) {
            point.field = try arg_field_parse(value);
        } else if (std.mem.eql(u8, name, "--arg-string")) {
            point.string = try arg_string_parse(value);
        } else if (std.mem.eql(u8, name, "--pid")) {
            options.pid = try std.fmt.parseInt(linux.pid_t, value, 10);
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            options.timeout_ms = try std.fmt.parseInt(u64, value, 10);
        } else return error.Usage;
        option = option[2..];
    }
    for (options.points[0..options.count]) |point| {
        const spec = try spec_parse(point.function);
        // `--direct` names the entry's own caller: no return address is at rsp inside a function.
        if (point.direct and !spec.at_entry()) return error.Usage;
    }
    return options;
}

/// `<register>=<value>`, the value decimal or 0x-hexadecimal.
fn arg_parse(text: []const u8) !Arg {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.Usage;
    const index = register_index(text[0..equals]) orelse return error.UnknownRegister;
    return .{ .index = index, .value = try std.fmt.parseInt(u64, text[equals + 1 ..], 0) };
}

/// `<register>:<type>:<path>=<value>`: the type's name has no colon (Go's and C's do not), the
/// path no colon or equals sign; the value is the rest (an address's colon among it).
fn arg_field_parse(text: []const u8) !ArgField {
    const first = std.mem.indexOfScalar(u8, text, ':') orelse return error.Usage;
    const index = register_index(text[0..first]) orelse return error.UnknownRegister;
    const rest = text[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return error.Usage;
    const field = rest[second + 1 ..];
    const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.Usage;
    if (second == 0 or equals == 0) return error.Usage;
    const value = field[equals + 1 ..];
    if (value.len > field_text_max) return error.Usage;
    return .{ .index = index, .type_name = rest[0..second], .path = field[0..equals], .value = value };
}

/// `<register>:<register>=<text>`: the pointer's register, the length's, then the text.
fn arg_string_parse(text: []const u8) !ArgString {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.Usage;
    const registers = text[0..equals];
    const colon = std.mem.indexOfScalar(u8, registers, ':') orelse return error.Usage;
    const pointer = register_index(registers[0..colon]) orelse return error.UnknownRegister;
    const length = register_index(registers[colon + 1 ..]) orelse return error.UnknownRegister;
    const value = text[equals + 1 ..];
    if (value.len > field_text_max) return error.Usage;
    return .{ .pointer = pointer, .length = length, .value = value };
}

/// The field's place in the module's DWARF and the value it must hold, as its kind reads it.
fn field_match(arena: std.mem.Allocator, sections: dwarf_types.Sections, asked: ArgField) !FieldMatch {
    const field = (try dwarf_types.member_of(arena, sections, asked.type_name, asked.path)) orelse return error.UnknownType;
    switch (field.kind) {
        .signed, .unsigned, .boolean, .pointer => {
            if (field.size == 0 or field.size > 8) return error.UnsupportedField;
            const number: u64 = if (std.mem.eql(u8, asked.value, "true"))
                1
            else if (std.mem.eql(u8, asked.value, "false"))
                0
            else if (field.kind == .signed)
                @bitCast(try std.fmt.parseInt(i64, asked.value, 0))
            else
                try std.fmt.parseInt(u64, asked.value, 0);
            return .{ .index = asked.index, .offset = field.offset, .size = field.size, .want = .{ .number = number } };
        },
        // A Go string: its data's pointer, then its length (Go's DWARF says `string`, a structure
        // of `str` and `len`; a named string type is a typedef of it).
        .aggregate => {
            if (field.size != 16) return error.UnsupportedField;
            return .{ .index = asked.index, .offset = field.offset, .size = 16, .want = .{ .text = asked.value } };
        },
        .float, .other => return error.UnsupportedField,
    }
}

/// The low `size` bytes of `word`, sign-extended for a signed field (so `-1` matches an i32's).
fn field_number(word: u64, size: u64) u64 {
    if (size >= 8) return word;
    const bits: u6 = @intCast(size * 8);
    return word & ((@as(u64, 1) << bits) - 1);
}

fn register_index(name: []const u8) ?u8 {
    for (register_names) |register| {
        if (std.mem.eql(u8, register.name, name)) return register.index;
    }
    return null;
}

/// Whether `address` is a return address into [start, end): a call's return address is just
/// after it, so the function's last byte's call returns to its end.
fn returns_into(address: u64, start: u64, end: u64) bool {
    return address > start and address <= end;
}

/// The point numbers of `release <n>` and `arm <n>` lines in `text` (a command each line).
fn commands_parse(text: []const u8, released: *[points_max]bool, armed: *[points_max]bool) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const word, const asked = if (std.mem.startsWith(u8, line, "release "))
            .{ "release ", released }
        else if (std.mem.startsWith(u8, line, "arm "))
            .{ "arm ", armed }
        else
            continue;
        const point = std.fmt.parseInt(u32, std.mem.trim(u8, line[word.len..], " \r"), 10) catch continue;
        if (point < points_max) asked[point] = true;
    }
}

var release_all: std.atomic.Value(bool) = .init(false);
var release_some: std.atomic.Value(bool) = .init(false);
var timed_out: std.atomic.Value(bool) = .init(false);

fn on_release_all(_: linux.SIG) callconv(.c) void {
    release_all.store(true, .release);
}

fn on_release_some(_: linux.SIG) callconv(.c) void {
    release_some.store(true, .release);
}

fn on_alarm(_: linux.SIG) callconv(.c) void {
    timed_out.store(true, .release);
}

/// SIGCHLD (a tracee stopped or exited): only to wake the wait below.
fn on_child(_: linux.SIG) callconv(.c) void {}

/// x86-64's longest instruction.
const instruction_size_max = 15;

const Point = struct {
    /// Its breakpoint's address: the function's entry, or an instruction inside it (Spec).
    entry: u64,
    /// At the function's entry: its return address is at rsp (inside it, only the frame
    /// pointers' chain names callers).
    at_entry: bool = true,
    original: u8,
    caller: ?[2]u64,
    arg: ?Arg,
    field: ?FieldMatch = null,
    string: ?ArgString = null,
    repeat: bool,
    every: bool,
    direct: bool,
    /// Its breakpoint left out until `arm <point>` (then false).
    later: bool = false,
    inserted: bool = false,
    held: ?linux.pid_t = null,
    /// With `every`, the threads held besides `held` (the first), until the end.
    others: [threads_held_max]linux.pid_t = undefined,
    others_count: u32 = 0,
    /// Held once and let go: the point is done (its byte stays restored).
    done: bool = false,
    /// A thread stepped over the entry (let go, or not one to hold) whose step went into a
    /// signal handler instead (a signal pending, as Go's preemption leaves on a thread held a
    /// while): back at the entry from the handler it is stepped over again, never held.
    passing: ?linux.pid_t = null,
    /// In a Go process, the passing thread's goroutine (r14): Go's preemption handler can return
    /// through asyncPreempt and the goroutine go on on another thread, back at the entry there
    /// (a raft walk's late write: 42 of 42 misses, a second thread held as the first went into
    /// its handler; jtl-data run 12's `hold` events).
    passing_g: u64 = 0,
};

const Hold = struct {
    pid: linux.pid_t,
    memory: linux.fd_t,
    /// For its events (`hold`): what it did, in the timeline beside the nodes' own.
    node: []const u8 = "",
    /// A Go process (runtime.main defined): a passing goroutine is known by its g (r14).
    go: bool = false,
    points: [points_max]Point = undefined,
    count: u32 = 0,
    tids: [threads_max]linux.pid_t = undefined,
    threads: u32 = 0,
    /// Threads found stopped at a point's breakpoint while others stepped past it (others_stop),
    /// left stopped there for the main loop, first in first out. Rewound and let go instead,
    /// they hit it again at once and the next step past found them again: in race_test.zig's
    /// `held_crowd` the three threads stepping past all along kept the eight with the held
    /// argument from ever being held (none in 4 of 4 timelines).
    queued: [threads_max]linux.pid_t = undefined,
    queued_count: u32 = 0,

    fn track(hold: *Hold, tid: linux.pid_t) void {
        for (hold.tids[0..hold.threads]) |known| if (known == tid) return;
        if (hold.threads == threads_max) return;
        hold.tids[hold.threads] = tid;
        hold.threads += 1;
    }

    fn forget(hold: *Hold, tid: linux.pid_t) void {
        for (hold.tids[0..hold.threads], 0..) |known, index| {
            if (known != tid) continue;
            hold.tids[index] = hold.tids[hold.threads - 1];
            hold.threads -= 1;
            break;
        }
        hold.unqueue(tid);
        for (hold.points[0..hold.count]) |*point| {
            if (point.held != null and point.held.? == tid) point.held = null;
        }
    }

    fn byte_write(hold: *Hold, address: u64, byte: u8) bool {
        const bytes = [1]u8{byte};
        const result = linux.pwrite(hold.memory, &bytes, 1, @bitCast(address));
        return linux.errno(result) == .SUCCESS and result == 1;
    }

    fn word_read(hold: *const Hold, address: u64) ?u64 {
        var word: u64 = undefined;
        const bytes = std.mem.asBytes(&word);
        const read = linux.pread(hold.memory, bytes, bytes.len, @bitCast(address));
        if (linux.errno(read) != .SUCCESS or read != bytes.len) return null;
        return word;
    }

    fn bytes_read(hold: *const Hold, address: u64, bytes: []u8) bool {
        const read = linux.pread(hold.memory, bytes.ptr, bytes.len, @bitCast(address));
        return linux.errno(read) == .SUCCESS and read == bytes.len;
    }

    /// Whether `length` bytes at `data` are `text`.
    fn text_at(hold: *const Hold, data: u64, length: u64, text: []const u8) bool {
        if (length != text.len) return false;
        if (text.len == 0) return true;
        var buffer: [field_text_max]u8 = undefined;
        if (!hold.bytes_read(data, buffer[0..text.len])) return false;
        return std.mem.eql(u8, buffer[0..text.len], text);
    }

    /// Whether the field behind a register holds the value asked for.
    fn field_holds(hold: *const Hold, field: *const FieldMatch, regs: *const Regs) bool {
        const base = regs[field.index];
        if (base == 0) return false;
        const at = std.math.add(u64, base, field.offset) catch return false;
        switch (field.want) {
            .number => |number| {
                var word: u64 = 0;
                const bytes = std.mem.asBytes(&word)[0..@intCast(field.size)];
                if (!hold.bytes_read(at, bytes)) return false;
                return field_number(word, field.size) == field_number(number, field.size);
            },
            .text => |text| {
                const data = hold.word_read(at) orelse return false;
                const length = hold.word_read(at + 8) orelse return false;
                return hold.text_at(data, length, text);
            },
        }
    }

    /// The point whose breakpoint a thread stopped at (its rip just after the int3), if any.
    fn point_at(hold: *Hold, rip: u64) ?u32 {
        for (hold.points[0..hold.count], 0..) |point, index| {
            if (rip == point.entry + 1) return @intCast(index);
        }
        return null;
    }

    /// Whether a thread at a point's entry is one to hold: its argument register, then a return
    /// address into the caller on its stack ([rsp] at the entry, then the frame pointers').
    fn matches(hold: *const Hold, point: *const Point, regs: *const Regs) bool {
        if (point.arg) |arg| {
            if (regs[arg.index] != arg.value) return false;
        }
        if (point.field) |*field| {
            if (!hold.field_holds(field, regs)) return false;
        }
        if (point.string) |string| {
            if (!hold.text_at(regs[string.pointer], regs[string.length], string.value)) return false;
        }
        const range = point.caller orelse return true;
        if (point.at_entry) {
            const first = hold.word_read(regs[rsp_index]) orelse return false;
            if (returns_into(first, range[0], range[1])) return true;
            if (point.direct) return false;
        }
        var frame = regs[rbp_index];
        for (0..frames_max) |_| {
            if (frame == 0) return false;
            const returned = hold.word_read(frame + 8) orelse return false;
            if (returns_into(returned, range[0], range[1])) return true;
            const next = hold.word_read(frame) orelse return false;
            if (next <= frame) return false; // Stacks grow down: callers' frames are higher.
            frame = next;
        }
        return false;
    }

    /// A thread stopped at a point's breakpoint: back to the entry, then held (the point's first
    /// match), or stepped over the restored instruction and the breakpoint put back; at a point
    /// whose byte is already restored, back to the entry and on.
    fn hit(hold: *Hold, tid: linux.pid_t, index: u32, regs: *Regs) void {
        const point = &hold.points[index];
        regs[rip_index] = point.entry;
        _ = linux.ptrace(ptrace_setregs, tid, 0, @intFromPtr(regs), 0);
        const same_thread = point.passing != null and point.passing.? == tid;
        const same_goroutine = hold.go and point.passing_g != 0 and regs[r14_index] == point.passing_g;
        if (same_thread or same_goroutine) {
            point.passing = null;
            point.passing_g = 0;
            hold.note(if (same_thread) "passing_back" else "passing_moved", index, tid, 0);
            if (point.inserted) {
                hold.step_past(tid, point);
                return;
            }
        }
        if (!point.inserted) {
            _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
            return;
        }
        if (point.every and !point.done and hold.matches(point, regs)) {
            // Held where it stands, the breakpoint kept for the next one (each goes on from the
            // entry at the end, the byte restored then).
            if (point.held == null) {
                point.held = tid;
            } else if (point.others_count < threads_held_max) {
                point.others[point.others_count] = tid;
                point.others_count += 1;
            } else {
                _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
                return;
            }
            out("{{\"held\":{d},\"point\":{d}}}\n", .{ tid, index });
            hold.note("held", index, tid, 0);
            return; // Left stopped.
        }
        if (point.held == null and !point.done and hold.matches(point, regs)) {
            point.held = tid;
            if (hold.byte_write(point.entry, point.original)) point.inserted = false;
            out("{{\"held\":{d},\"point\":{d}}}\n", .{ tid, index });
            hold.note("held", index, tid, 0);
            return; // Left stopped.
        }
        hold.step_past(tid, point);
    }

    /// The threads stopped while a point's byte is out for one thread's step past its entry:
    /// running, another passed the entry unseen (jtl-data run 14: the Raft PoC walk's vote
    /// request from O to C, sent beside its request to V while that one stepped past the point,
    /// in 10 of 86 walks; race_test.zig's `held_crowd`). Each gives back the stop it was found
    /// in (its signal); one stopped at a breakpoint stays stopped, queued for the main loop.
    const Paused = struct {
        tids: [threads_max]linux.pid_t = undefined,
        signals: [threads_max]u32 = undefined,
        count: u32 = 0,
    };

    fn others_stop(hold: *Hold, tid: linux.pid_t, paused: *Paused) void {
        var tids: [threads_max]linux.pid_t = undefined;
        const threads = hold.threads;
        @memcpy(tids[0..threads], hold.tids[0..threads]);
        for (tids[0..threads]) |other| {
            // Held or queued: stopped already.
            if (other == tid or hold.held_by(other) != null or hold.is_queued(other)) continue;
            if (linux.errno(linux.ptrace(ptrace_interrupt, other, 0, 0, 0)) != .SUCCESS) continue;
            var status: i32 = 0;
            if (linux.errno(linux.wait4(other, &status, wait_all, null)) != .SUCCESS) continue;
            const word: u32 = @bitCast(status);
            if (!linux.W.IFSTOPPED(word)) {
                hold.forget(other);
                continue;
            }
            const stop: u32 = @backingInt(linux.W.STOPSIG(word));
            const event = word >> 16;
            var signal: u32 = 0;
            if (event == 0 and stop == signal_trap) {
                var regs: Regs = undefined;
                const read = linux.errno(linux.ptrace(ptrace_getregs, other, 0, @intFromPtr(&regs), 0)) == .SUCCESS;
                if (read and hold.point_at(regs[rip_index]) != null) {
                    // A hit not seen yet: left stopped for the main loop, which takes it first.
                    hold.queue(other);
                    continue;
                }
                signal = stop;
            } else if (event == 0) {
                signal = stop;
            }
            // An event's stop (this interrupt, a clone) gives nothing back; a clone's new thread
            // waits stopped for the main loop.
            paused.tids[paused.count] = other;
            paused.signals[paused.count] = signal;
            paused.count += 1;
        }
    }

    fn others_resume(paused: *const Paused) void {
        for (paused.tids[0..paused.count], paused.signals[0..paused.count]) |other, signal| {
            _ = linux.ptrace(ptrace_cont, other, 0, signal, 0);
        }
    }

    /// `tid` past a point's entry, its byte out meanwhile and every other thread stopped.
    fn step_past(hold: *Hold, tid: linux.pid_t, point: *Point) void {
        var paused: Paused = .{};
        hold.others_stop(tid, &paused);
        defer others_resume(&paused);
        if (!hold.byte_write(point.entry, point.original)) return;
        point.inserted = false;
        hold.step_over(tid, point);
    }

    /// A thread at a point's entry (its byte restored) past its first instruction, the
    /// breakpoint put back, and on. A signal pending is given with the step, which then stops
    /// at its handler's first instruction, the entry's not run: the thread is `passing` (the
    /// handler returns to the entry, its breakpoint back by then).
    fn step_over(hold: *Hold, tid: linux.pid_t, point: *Point) void {
        var signal: usize = 0;
        var gone = false;
        while (true) {
            if (linux.errno(linux.ptrace(ptrace_singlestep, tid, 0, signal, 0)) != .SUCCESS) return;
            var status: i32 = 0;
            if (linux.errno(linux.wait4(tid, &status, wait_all, null)) != .SUCCESS) return;
            if (!linux.W.IFSTOPPED(@bitCast(status))) {
                hold.forget(tid);
                gone = true;
                break;
            }
            const stop: u32 = @backingInt(linux.W.STOPSIG(@bitCast(status)));
            if (stop == signal_trap) break;
            signal = stop; // A signal came first: given with the step.
        }
        if (signal != 0 and !gone) {
            // Past the entry's instruction (within the function's first bytes), or in a handler.
            var regs: Regs = undefined;
            const read = linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) == .SUCCESS;
            const past = read and regs[rip_index] > point.entry and regs[rip_index] <= point.entry + instruction_size_max;
            if (!past) {
                point.passing = tid;
                point.passing_g = if (read and hold.go) regs[r14_index] else 0;
            }
            hold.note(if (past) "stepped_signal" else "into_handler", hold.index_of(point), tid, @intCast(signal));
        }
        if (hold.byte_write(point.entry, int3)) point.inserted = true;
        _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
    }

    /// A `--later` point's breakpoint put in: it holds from now on.
    fn arm_later(hold: *Hold, index: u32) void {
        const point = &hold.points[index];
        if (!point.later) return;
        point.later = false;
        if (hold.byte_write(point.entry, int3)) point.inserted = true;
        out("{{\"armed_point\":{d}}}\n", .{index});
        hold.note("armed", index, 0, 0);
    }

    fn release(hold: *Hold, index: u32) void {
        const point = &hold.points[index];
        const tid = point.held orelse return;
        point.held = null;
        out("{{\"released\":{d},\"point\":{d}}}\n", .{ tid, index });
        hold.note("released", index, tid, 0);
        if (point.repeat) {
            hold.step_over(tid, point); // Armed again for the next thread.
            return;
        }
        point.done = true;
        _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
    }

    /// What it did, as an event of the timeline's (`hold`): a release that did not land is
    /// read from these (held, released, armed, a step into a signal handler, its way back).
    fn note(hold: *const Hold, what: []const u8, index: u32, tid: linux.pid_t, signal: u32) void {
        sdk.event("hold", .{ .node = hold.node, .what = what, .point = index, .tid = tid, .signal = signal });
    }

    fn index_of(hold: *const Hold, point: *const Point) u32 {
        return @intCast((@intFromPtr(point) - @intFromPtr(&hold.points[0])) / @sizeOf(Point));
    }

    fn held_any(hold: *const Hold) bool {
        for (hold.points[0..hold.count]) |point| if (point.held != null or point.done) return true;
        return false;
    }

    /// Every thread stopped, every point's byte back, each thread detached: the held ones go on
    /// from their entries with the process.
    fn finish(hold: *Hold) void {
        for (hold.tids[0..hold.threads]) |tid| {
            if (hold.held_by(tid) != null) continue;
            // A queued thread is stopped already (at its breakpoint, rewound below).
            if (!hold.is_queued(tid)) {
                if (linux.errno(linux.ptrace(ptrace_interrupt, tid, 0, 0, 0)) != .SUCCESS) continue;
                var status: i32 = 0;
                if (linux.errno(linux.wait4(tid, &status, wait_all, null)) != .SUCCESS) continue;
                if (!linux.W.IFSTOPPED(@bitCast(status))) continue;
            }
            var regs: Regs = undefined;
            if (linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) != .SUCCESS) continue;
            if (hold.point_at(regs[rip_index])) |index| {
                regs[rip_index] = hold.points[index].entry;
                _ = linux.ptrace(ptrace_setregs, tid, 0, @intFromPtr(&regs), 0);
            }
        }
        for (hold.points[0..hold.count], 0..) |*point, index| {
            if (point.inserted and hold.byte_write(point.entry, point.original)) point.inserted = false;
            if (point.held) |tid| out("{{\"released\":{d},\"point\":{d}}}\n", .{ tid, index });
        }
        for (hold.tids[0..hold.threads]) |tid| _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
    }

    fn queue(hold: *Hold, tid: linux.pid_t) void {
        assert(!hold.is_queued(tid));
        assert(hold.queued_count < threads_max);
        hold.queued[hold.queued_count] = tid;
        hold.queued_count += 1;
    }

    fn is_queued(hold: *const Hold, tid: linux.pid_t) bool {
        for (hold.queued[0..hold.queued_count]) |queued| if (queued == tid) return true;
        return false;
    }

    fn unqueue(hold: *Hold, tid: linux.pid_t) void {
        for (hold.queued[0..hold.queued_count], 0..) |queued, index| {
            if (queued != tid) continue;
            std.mem.copyForwards(linux.pid_t, hold.queued[index .. hold.queued_count - 1], hold.queued[index + 1 .. hold.queued_count]);
            hold.queued_count -= 1;
            return;
        }
    }

    /// The first queued thread, out of the queue.
    fn dequeue(hold: *Hold) ?linux.pid_t {
        if (hold.queued_count == 0) return null;
        const tid = hold.queued[0];
        hold.unqueue(tid);
        return tid;
    }

    fn held_by(hold: *const Hold, tid: linux.pid_t) ?u32 {
        for (hold.points[0..hold.count], 0..) |point, index| {
            if (point.held != null and point.held.? == tid) return @intCast(index);
            for (point.others[0..point.others_count]) |other| if (other == tid) return @intCast(index);
        }
        return null;
    }
};

fn out(comptime format: []const u8, arguments: anytype) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, arguments) catch return;
    var written: usize = 0;
    while (written < text.len) {
        const result = linux.write(1, text[written..].ptr, text.len - written);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        written += result;
    }
}

fn symbol_in(arena: std.mem.Allocator, pids: []const linux.pid_t, name: []const u8) ?symbol.Found {
    for (pids) |pid| {
        if (symbol.find(arena, pid, name, null) catch null) |found| return found;
    }
    return null;
}

pub fn run(arena: std.mem.Allocator, options: Options) !u8 {
    assert(options.count > 0 and options.count <= points_max);
    var pids_buffer: [processes_max]linux.pid_t = undefined;
    const pids = if (options.pid) |pid| blk: {
        pids_buffer[0] = pid;
        break :blk pids_buffer[0..1];
    } else pids_buffer[0..try nodes.processes(options.node, &pids_buffer)];
    const first_spec = try spec_parse(options.points[0].function);
    const first = symbol_in(arena, pids, first_spec.function) orelse return error.UnknownFunction;
    var path_buffer: [48]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{first.pid}, 0) catch unreachable;
    const fd = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Memory;
    var hold: Hold = .{ .pid = first.pid, .memory = @intCast(fd), .node = options.node };
    defer _ = linux.close(hold.memory);
    // runtime.main, a Go function every Go program has (runtime.goexit is assembly: its symbol
    // runtime.goexit.abi0, not found by that name, and no goroutine was ever matched).
    hold.go = ((symbol.find(arena, hold.pid, "runtime.main", null) catch null) orelse null) != null;
    // The process's modules and their tables of lines, read for the first `@<line>` point; each
    // line point's place, printed after the `armed` line (Node.hold reads that one first).
    var process: ?where.Process = null;
    var resolved: [points_max]?struct { offset: u64, starts: usize } = @splat(null);
    defer if (process) |*read| read.release();
    for (options.points[0..options.count]) |asked| {
        const spec = try spec_parse(asked.function);
        const found = (symbol.find(arena, hold.pid, spec.function, null) catch null) orelse return error.UnknownFunction;
        const address: u64 = if (spec.offset) |offset| address: {
            if (found.size > 0 and offset >= found.size) return error.OffsetOutsideFunction;
            break :address found.address + offset;
        } else if (spec.line) |line| address: {
            if (found.size == 0) return error.UnknownFunctionSize;
            if (process == null) process = where.Process.read(arena, hold.pid);
            const starts = process.?.line_starts(arena, found.module, spec.file, line, found.address, found.address + found.size) orelse return error.NoLineTable;
            if (starts.len == 0) return error.NoSuchLine;
            // The line's first start; the others are in the event (a line split in two by the
            // compiler: `+<offset>` names another).
            sdk.event("hold", .{ .node = options.node, .what = "resolved", .point = hold.count, .address = starts[0], .offset = starts[0] - found.address, .starts = starts.len });
            resolved[hold.count] = .{ .offset = starts[0] - found.address, .starts = starts.len };
            break :address starts[0];
        } else found.address;
        var caller: ?[2]u64 = null;
        if (asked.caller) |name| {
            const site = (symbol.find(arena, hold.pid, name, null) catch null) orelse return error.UnknownCaller;
            caller = .{ site.address, site.address + site.size };
        }
        var field: ?FieldMatch = null;
        if (asked.field) |wanted| {
            // The type from the DWARF of the module the function is in.
            const module_path = std.fmt.allocPrintSentinel(arena, "/proc/{d}/root{s}", .{ hold.pid, found.module }, 0) catch return error.OutOfMemory;
            const module = linux.open(module_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(module) != .SUCCESS) return error.UnknownType;
            defer _ = linux.close(@intCast(module));
            const sections = (try dwarf_types.sections_of(arena, @intCast(module))) orelse return error.UnknownType;
            field = field_match(arena, sections, wanted) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownType, error.UnsupportedField => |e| return e,
                error.InvalidCharacter, error.Overflow => return error.Usage,
                else => return error.UnknownField,
            };
        }
        var original: [1]u8 = undefined;
        if (linux.pread(hold.memory, &original, 1, @bitCast(address)) != 1) return error.Memory;
        assert(original[0] != int3);
        hold.points[hold.count] = .{ .entry = address, .at_entry = spec.at_entry(), .original = original[0], .caller = caller, .arg = asked.arg, .field = field, .string = asked.string, .repeat = asked.repeat, .every = asked.every, .direct = asked.direct, .later = asked.later };
        hold.count += 1;
    }

    // Seized, each stopped, before the breakpoints go in.
    var tids: [threads_max]linux.pid_t = undefined;
    const threads = nodes.threads(hold.pid, &tids);
    for (tids[0..threads]) |tid| {
        if (linux.errno(linux.ptrace(ptrace_seize, tid, 0, ptrace_o_traceclone, 0)) != .SUCCESS) continue;
        if (linux.errno(linux.ptrace(ptrace_interrupt, tid, 0, 0, 0)) != .SUCCESS) continue;
        var status: i32 = 0;
        _ = linux.wait4(tid, &status, wait_all, null);
        hold.track(tid);
    }
    if (hold.threads == 0) return error.Ptrace;
    // No SA_RESTART: the wait returns on a signal.
    const all_action = linux.Sigaction{ .handler = .{ .handler = on_release_all }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.TERM, &all_action, null);
    _ = linux.sigaction(.INT, &all_action, null);
    const some_action = linux.Sigaction{ .handler = .{ .handler = on_release_some }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.USR1, &some_action, null);
    const alarm_action = linux.Sigaction{ .handler = .{ .handler = on_alarm }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.ALRM, &alarm_action, null);
    const child_action = linux.Sigaction{ .handler = .{ .handler = on_child }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.CHLD, &child_action, null);
    // Blocked but while waiting (ppoll below unblocks them atomically): a release asked between
    // the loop's checks and its wait is pending, not lost. Before, the wait was a blocking
    // wait4, and a SIGUSR1 landing just before it was seen only at the tracees' next stop (a
    // walk's late write let go only when the walk ended: two_leaders_trace, tl-data run 1).
    var waking = linux.sigemptyset();
    inline for (.{ linux.SIG.TERM, linux.SIG.INT, linux.SIG.USR1, linux.SIG.ALRM, linux.SIG.CHLD }) |signal| linux.sigaddset(&waking, signal);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &waking, null);
    const open = linux.sigemptyset();
    _ = linux.syscall1(.alarm, @max(1, (options.timeout_ms + 999) / 1000));
    // The release commands' input, read without waiting.
    const input_flags = linux.fcntl(0, linux.F.GETFL, 0);
    if (linux.errno(input_flags) == .SUCCESS) _ = linux.fcntl(0, linux.F.SETFL, input_flags | 0o4000); // O_NONBLOCK
    var inserted: u32 = 0;
    for (hold.points[0..hold.count]) |*point| {
        if (point.later) continue; // Armed by `arm <point>`.
        if (hold.byte_write(point.entry, int3)) {
            point.inserted = true;
            inserted += 1;
        }
    }
    for (hold.tids[0..hold.threads]) |tid| _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
    out("{{\"armed\":{d},\"threads\":{d},\"breakpoints\":{d}}}\n", .{ hold.pid, hold.threads, inserted });
    for (resolved[0..hold.count], 0..) |place, index| if (place) |line_point| {
        out("{{\"point\":{d},\"offset\":{d},\"starts\":{d}}}\n", .{ index, line_point.offset, line_point.starts });
    };
    hold.note(if (hold.go) "start_go" else "start", 0, hold.pid, 0);

    // Queued hits and new stops take turns (below).
    var serve_queue = false;
    while (!release_all.load(.acquire)) {
        // The blocked signals let through at every turn, without waiting: a queue the stepping
        // threads refill all along kept the loop from the wait below, the only place they were
        // let through, and a release asked meanwhile (SIGTERM, SIGUSR1) waited forever
        // (race_test.zig's held_crowd at seed 1: timeline 2 ran on for minutes past its eight
        // holds, its driver's release never seen).
        var no_wait: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.ppoll(&.{}, 0, &no_wait, &open);
        if (release_all.load(.acquire)) break;
        if (timed_out.load(.acquire) and !hold.held_any()) break;
        if (release_some.swap(false, .acq_rel)) {
            var commands: [256]u8 = undefined;
            const size = linux.read(0, &commands, commands.len);
            if (linux.errno(size) == .SUCCESS and size > 0) {
                var released: [points_max]bool = @splat(false);
                var armed: [points_max]bool = @splat(false);
                commands_parse(commands[0..size], &released, &armed);
                for (armed[0..hold.count], 0..) |arm, index| if (arm) hold.arm_later(@intCast(index));
                for (released[0..hold.count], 0..) |release, index| if (release) hold.release(@intCast(index));
            }
        }
        // Hits others_stop found, in order, in turn with new stops: queued ones only after new
        // stops would starve behind the threads stepping past all along, and new stops only
        // after an empty queue would never come (a clone's new thread left at its first stop
        // while the stepping threads refill the queue).
        serve_queue = !serve_queue;
        const queued = if (serve_queue) hold.dequeue() else null;
        if (queued) |tid| {
            var regs: Regs = undefined;
            if (linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) == .SUCCESS) {
                if (hold.point_at(regs[rip_index])) |index| {
                    hold.hit(tid, index, &regs);
                    continue;
                }
            }
            _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
            continue;
        }
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, wait_all | wait_no_hang, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) break; // No tracee left.
        if (result == 0) {
            // Nothing stopped and queued threads left: their turn, no wait (stopped, they send
            // no SIGCHLD, and all of a process's threads may be among them).
            if (hold.queued_count > 0) continue;
            // Nothing stopped: wait for a signal (a tracee's stop is SIGCHLD), the blocked ones
            // let through for the wait.
            _ = linux.ppoll(&.{}, 0, null, &open);
            continue;
        }
        const tid: linux.pid_t = @intCast(result);
        const word: u32 = @bitCast(status);
        if (!linux.W.IFSTOPPED(word)) {
            hold.forget(tid);
            continue;
        }
        hold.track(tid);
        const stop: u32 = @backingInt(linux.W.STOPSIG(word));
        const event = word >> 16;
        if (event == ptrace_event_clone or event == ptrace_event_stop) {
            _ = linux.ptrace(ptrace_cont, tid, 0, 0, 0);
            continue;
        }
        if (stop == signal_trap and event == 0) {
            var regs: Regs = undefined;
            if (linux.errno(linux.ptrace(ptrace_getregs, tid, 0, @intFromPtr(&regs), 0)) == .SUCCESS) {
                if (hold.point_at(regs[rip_index])) |index| {
                    hold.hit(tid, index, &regs);
                    continue;
                }
            }
        }
        _ = linux.ptrace(ptrace_cont, tid, 0, stop, 0); // Its signal given back.
    }
    const any = hold.held_any();
    hold.finish();
    if (any) return 0;
    out("{{\"held\":null}}\n", .{});
    return 1;
}

test returns_into {
    try std.testing.expect(returns_into(0x1010, 0x1000, 0x1100));
    try std.testing.expect(returns_into(0x1100, 0x1000, 0x1100)); // A call as the last instruction.
    try std.testing.expect(!returns_into(0x1000, 0x1000, 0x1100)); // Its entry is no return address.
    try std.testing.expect(!returns_into(0x1101, 0x1000, 0x1100));
}

test parse {
    const options = try parse("raft-node-1", "f", &.{ "--caller", "g", "--every", "--and", "h", "--repeat", "--arg", "rbx=0x18", "--timeout-ms", "2500" });
    try std.testing.expect(!options.points[0].repeat and options.points[1].repeat);
    const later = try parse("raft-node-1", "f", &.{ "--and", "g", "--later", "--repeat" });
    try std.testing.expect(!later.points[0].later and later.points[1].later and later.points[1].repeat);
    try std.testing.expect(options.points[0].every and !options.points[1].every);
    const direct = try parse("n", "f", &.{ "--caller", "g", "--direct" });
    try std.testing.expect(direct.points[0].direct);
    try std.testing.expectEqual(@as(u32, 2), options.count);
    try std.testing.expectEqualStrings("g", options.points[0].caller.?);
    try std.testing.expect(options.points[0].arg == null);
    try std.testing.expectEqualStrings("h", options.points[1].function);
    try std.testing.expectEqual(@as(u8, 5), options.points[1].arg.?.index);
    try std.testing.expectEqual(@as(u64, 24), options.points[1].arg.?.value);
    try std.testing.expectEqual(@as(u64, 2500), options.timeout_ms);
    try std.testing.expectError(error.UnknownRegister, parse("n", "f", &.{ "--arg", "xmm0=1" }));
    try std.testing.expectError(error.Usage, parse("n", "f", &.{"--caller"}));
}

test spec_parse {
    const entry = try spec_parse("turso_core::io::completions::Completion::set_waker");
    try std.testing.expectEqualStrings("turso_core::io::completions::Completion::set_waker", entry.function);
    try std.testing.expect(entry.at_entry());
    const line = try spec_parse("turso_core::io::completions::Completion::set_waker@389");
    try std.testing.expectEqualStrings("turso_core::io::completions::Completion::set_waker", line.function);
    try std.testing.expectEqual(@as(?u32, 389), line.line);
    try std.testing.expect(line.file == null and !line.at_entry());
    const file_line = try spec_parse("set_waker@core/io/completions.rs:389");
    try std.testing.expectEqualStrings("set_waker", file_line.function);
    try std.testing.expectEqualStrings("core/io/completions.rs", file_line.file.?);
    try std.testing.expectEqual(@as(?u32, 389), file_line.line);
    const offset = try spec_parse("race_held.act+0x1a");
    try std.testing.expectEqualStrings("race_held.act", offset.function);
    try std.testing.expectEqual(@as(?u64, 0x1a), offset.offset);
    // Names with a plus are names (no number after it).
    try std.testing.expectEqualStrings("Vec::operator+", (try spec_parse("Vec::operator+")).function);
    try std.testing.expectEqualStrings("Vec::operator+=", (try spec_parse("Vec::operator+=")).function);
    try std.testing.expectError(error.Usage, spec_parse("f@"));
    try std.testing.expectError(error.Usage, spec_parse("f@x"));
    try std.testing.expectError(error.Usage, spec_parse("f@:3"));
    try std.testing.expectError(error.Usage, spec_parse("f@0"));
    try std.testing.expectError(error.Usage, spec_parse("@3"));
    // `--direct` only at an entry; a line point takes `--caller` by its frame pointers.
    try std.testing.expectError(error.Usage, parse("n", "f@3", &.{ "--caller", "g", "--direct" }));
    const inside = try parse("n", "f@3", &.{ "--caller", "g", "--and", "h+8" });
    try std.testing.expectEqualStrings("f@3", inside.points[0].function);
    try std.testing.expectEqualStrings("h+8", inside.points[1].function);
}

test arg_field_parse {
    const options = try parse("n", "github.com/hashicorp/raft.(*Raft).replicateTo", &.{ "--arg-field", "rbx:github.com/hashicorp/raft.followerReplication:peer.Address=10.0.0.5:8300" });
    const field = options.points[0].field.?;
    try std.testing.expectEqual(@as(u8, 5), field.index);
    try std.testing.expectEqualStrings("github.com/hashicorp/raft.followerReplication", field.type_name);
    try std.testing.expectEqualStrings("peer.Address", field.path);
    try std.testing.expectEqualStrings("10.0.0.5:8300", field.value);
    try std.testing.expectError(error.Usage, parse("n", "f", &.{ "--arg-field", "rbx:T=1" }));
    try std.testing.expectError(error.Usage, parse("n", "f", &.{ "--arg-field", "rbx:T:=1" }));
    try std.testing.expectError(error.UnknownRegister, parse("n", "f", &.{ "--arg-field", "xmm0:T:a=1" }));
}

test "a string argument by its registers" {
    const options = try parse("n", "github.com/hashicorp/raft.(*NetworkTransport).RequestVote", &.{ "--arg-string", "rdi:rsi=raft-node-1:8300" });
    const string = options.points[0].string.?;
    try std.testing.expectEqual(@as(u8, 14), string.pointer);
    try std.testing.expectEqual(@as(u8, 13), string.length);
    try std.testing.expectEqualStrings("raft-node-1:8300", string.value);
    try std.testing.expectError(error.Usage, parse("n", "f", &.{ "--arg-string", "rdi=x" }));
    try std.testing.expectError(error.UnknownRegister, parse("n", "f", &.{ "--arg-string", "rdi:xmm1=x" }));
    // Matched against this process's memory: the text's own bytes, then another length.
    const memory = linux.open("/proc/self/mem", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(memory));
    defer _ = linux.close(@intCast(memory));
    const hold: Hold = .{ .pid = linux.getpid(), .memory = @intCast(memory) };
    const text: []const u8 = "raft-node-1:8300";
    try std.testing.expect(hold.text_at(@intFromPtr(text.ptr), text.len, "raft-node-1:8300"));
    try std.testing.expect(!hold.text_at(@intFromPtr(text.ptr), text.len, "raft-node-2:8300"));
    try std.testing.expect(!hold.text_at(@intFromPtr(text.ptr), text.len - 1, "raft-node-1:8300"));
}

test field_number {
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), field_number(@bitCast(@as(i64, -1)), 4));
    try std.testing.expectEqual(@as(u64, 0x34), field_number(0x1234, 1));
    try std.testing.expectEqual(@as(u64, 0x1234), field_number(0x1234, 8));
}

// What a held argument points at, for the field match below: a structure whose DWARF the test
// binary carries, by its type's name.
const TestPeer = extern struct { id: u32, code: i32, address: extern struct { ptr: [*]const u8, len: u64 } };
export var det_hold_test_peer: TestPeer = .{ .id = 7, .code = -3, .address = .{ .ptr = "10.0.0.5:8300", .len = 13 } };

test "a field behind a register, matched as its DWARF type reads it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.mem.doNotOptimizeAway(&det_hold_test_peer);
    const self = linux.open("/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(self) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(@intCast(self));
    const sections = (try dwarf_types.sections_of(arena, @intCast(self))) orelse return error.SkipZigTest;
    const memory = linux.open("/proc/self/mem", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(memory));
    defer _ = linux.close(@intCast(memory));
    const hold: Hold = .{ .pid = linux.getpid(), .memory = @intCast(memory) };
    var regs: Regs = @splat(0);
    regs[5] = @intFromPtr(&det_hold_test_peer); // rbx
    const type_name = "hold.TestPeer";
    const id = try field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "id", .value = "7" });
    try std.testing.expect(hold.field_holds(&id, &regs));
    const other = try field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "id", .value = "8" });
    try std.testing.expect(!hold.field_holds(&other, &regs));
    const code = try field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "code", .value = "-3" });
    try std.testing.expect(hold.field_holds(&code, &regs));
    const address = try field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "address", .value = "10.0.0.5:8300" });
    try std.testing.expect(hold.field_holds(&address, &regs));
    const elsewhere = try field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "address", .value = "10.0.0.6:8300" });
    try std.testing.expect(!hold.field_holds(&elsewhere, &regs));
    regs[5] = 0;
    try std.testing.expect(!hold.field_holds(&id, &regs)); // A nil receiver: no match.
    try std.testing.expectError(error.UnknownType, field_match(arena, sections, .{ .index = 5, .type_name = "hold.NoSuchType", .path = "id", .value = "1" }));
    try std.testing.expectError(error.NoSuchField, field_match(arena, sections, .{ .index = 5, .type_name = type_name, .path = "missing", .value = "1" }));
}

test commands_parse {
    var released: [points_max]bool = @splat(false);
    var armed: [points_max]bool = @splat(false);
    commands_parse("release 1\nnoise\narm 2\nrelease 3\nrelease 9\narm x\n", &released, &armed);
    try std.testing.expect(!released[0] and released[1] and !released[2] and released[3]);
    try std.testing.expect(!armed[0] and !armed[1] and armed[2] and !armed[3]);
}

test "queued hits come back first in, first out, and a thread gone leaves the queue" {
    var hold: Hold = .{ .node = "n", .pid = 1, .memory = -1 };
    hold.queue(11);
    hold.queue(12);
    hold.queue(13);
    try std.testing.expect(hold.is_queued(12));
    hold.unqueue(12);
    try std.testing.expect(!hold.is_queued(12));
    try std.testing.expectEqual(@as(?linux.pid_t, 11), hold.dequeue());
    try std.testing.expectEqual(@as(?linux.pid_t, 13), hold.dequeue());
    try std.testing.expectEqual(@as(?linux.pid_t, null), hold.dequeue());
}
