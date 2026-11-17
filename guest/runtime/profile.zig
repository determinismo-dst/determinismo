// SPDX-License-Identifier: MIT
//! det-profile <node> [--ms <duration>] [--interval-us <us>] [--pid <pid>] [--all]: a sampling
//! CPU profiler (Antithesis's environment.profiler), deterministic like everything else here.
//!
//! Every interval of virtual time it stops the node's runnable threads (ptrace), reads their
//! registers and walks their stacks, then lets them go: each frame by its file's call frame
//! information (.eh_frame: unwind.zig), else by its frame pointer, so code built without frame
//! pointers (glibc's, OpenSSL's) shows its callers too. Addresses are named from the ELF symbol
//! tables of the mapped files. It prints folded stacks ("process;outer;...;inner count", most
//! samples first), which `determinismo profile` turns into a flame graph. With --all, threads that
//! wait are sampled too (a wall-clock profile). With --stacks it prints every thread's stack
//! once instead (`thread apply all bt`, jstack): what each thread is doing at the moment.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const elf = std.elf;
const nodes = @import("nodes.zig");
const unwind = @import("unwind.zig");

const processes_max = 1024;
const threads_max = 256;
const frames_max = 64;
const symbols_files_max = 64;
/// A JIT runtime's process maps many regions (jank: LLVM's libraries and each JIT allocation).
const maps_max = 4096;
const folded_shown_max = 4000;
const ptrace_detach = 17;
const wait_all = 0x40000000; // __WALL: threads too.

const Options = struct {
    node: []const u8,
    duration_ns: u64 = std.time.ns_per_s,
    interval_ns: u64 = 5 * std.time.ns_per_ms,
    pid: ?linux.pid_t = null,
    all: bool = false,
    stacks: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const options = options_parse(arguments) catch {
        std.debug.print("usage: det-profile <node> [--ms <duration>] [--interval-us <us>] " ++
            "[--pid <pid>] [--all] [--stacks]\n", .{});
        return 2;
    };
    var profile = Profile{ .arena = arena };
    if (options.stacks) {
        try profile.stacks_print(&options);
        return 0;
    }
    const start_ns = monotonic_ns();
    while (monotonic_ns() - start_ns < options.duration_ns) {
        try profile.tick(&options);
        sleep_ns(options.interval_ns);
    }
    try profile.print();
    return 0;
}

fn options_parse(arguments: []const [:0]const u8) !Options {
    if (arguments.len < 2) return error.Usage;
    var options = Options{ .node = arguments[1] };
    var index: usize = 2;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        if (std.mem.eql(u8, flag, "--all")) {
            options.all = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--stacks")) {
            options.stacks = true;
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (std.mem.eql(u8, flag, "--ms")) {
            options.duration_ns = try std.fmt.parseInt(u64, value, 10) * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, flag, "--interval-us")) {
            options.interval_ns = try std.fmt.parseInt(u64, value, 10) * std.time.ns_per_us;
        } else if (std.mem.eql(u8, flag, "--pid")) {
            options.pid = try std.fmt.parseInt(linux.pid_t, value, 10);
        } else return error.Usage;
    }
    if (options.interval_ns == 0) return error.Usage;
    return options;
}

const Profile = struct {
    arena: std.mem.Allocator,
    /// Folded stack -> samples.
    stacks: std.StringHashMapUnmanaged(u32) = .empty,
    samples: u64 = 0,
    files: [symbols_files_max]Symbols = undefined,
    files_count: u32 = 0,
    /// JIT-compiled code's names, a process's jitdump file's (perf's format: jank's --perf,
    /// LLVM's PerfSupportPlugin, Node.js's --perf-prof, a JVM with a jitdump agent).
    jits: [processes_max]Jit = undefined,
    jits_count: u32 = 0,

    fn tick(profile: *Profile, options: *const Options) !void {
        var pids: [processes_max]linux.pid_t = undefined;
        const count = if (options.pid) |pid| one: {
            pids[0] = pid;
            break :one 1;
        } else nodes.processes(options.node, &pids) catch return error.NoSuchNode;
        for (pids[0..count]) |pid| {
            var maps: Maps = .{};
            maps.load(pid);
            var tids: [threads_max]linux.pid_t = undefined;
            const threads = nodes.threads(pid, &tids);
            for (tids[0..threads]) |tid| {
                if (!options.all and !runnable(tid)) continue;
                var frames: [frames_max]u64 = undefined;
                const depth = profile.stack_sample(pid, tid, &maps, &frames);
                if (depth == 0) continue;
                try profile.add(pid, &maps, frames[0..depth]);
            }
        }
    }

    /// Every thread's stack, innermost frame first, under its process, thread and state.
    fn stacks_print(profile: *Profile, options: *const Options) !void {
        var out: std.Io.Writer.Allocating = .init(profile.arena);
        var pids: [processes_max]linux.pid_t = undefined;
        const count = if (options.pid) |pid| one: {
            pids[0] = pid;
            break :one 1;
        } else nodes.processes(options.node, &pids) catch return error.NoSuchNode;
        for (pids[0..count]) |pid| {
            var maps: Maps = .{};
            maps.load(pid);
            var tids: [threads_max]linux.pid_t = undefined;
            const threads = nodes.threads(pid, &tids);
            for (tids[0..threads]) |tid| {
                const state: u8 = if (runnable(tid)) 'R' else 'S';
                try out.writer.print("{s} pid {d} thread {d} ({c})\n", .{
                    process_name(tid), pid, tid, state,
                });
                var frames: [frames_max]u64 = undefined;
                var depth = profile.stack_sample(pid, tid, &maps, &frames);
                if (depth == 0) {
                    // Not stoppable (dumping core, or blocked where ptrace cannot reach it).
                    depth = stack_scan(pid, tid, &maps, &frames);
                    if (depth > 0) try out.writer.writeAll("  (not stoppable: its stack read " ++
                        "from its last saved stack pointer, frames found by their links)\n");
                }
                var valid: usize = @min(depth, 1);
                while (valid < depth and maps.find(frames[valid]) != null) valid += 1;
                for (frames[0..valid], 0..) |frame, index| {
                    const address = if (index == 0) frame else frame - 1;
                    try out.writer.print("  #{d:<2} ", .{index});
                    try profile.name_write(&out.writer, pid, &maps, address);
                    try out.writer.writeByte('\n');
                }
                try out.writer.writeByte('\n');
            }
        }
        try write_stdout(out.written());
    }

    /// Names the frames (outermost first) and counts the stack.
    fn add(profile: *Profile, pid: linux.pid_t, maps: *const Maps, frames: []const u64) !void {
        var buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        writer.writeAll(process_name(pid)) catch return;
        // A frame-pointer chain through code built without them ends in garbage: keep the
        // frames up to the first return address outside any executable mapping.
        var valid: usize = 1;
        while (valid < frames.len and maps.find(frames[valid]) != null) valid += 1;
        var index = valid;
        while (index > 0) {
            index -= 1;
            // Return addresses point after the call: look up the call itself.
            const address = if (index == 0) frames[index] else frames[index] - 1;
            writer.writeByte(';') catch break;
            profile.name_write(&writer, pid, maps, address) catch break;
        }
        const entry = try profile.stacks.getOrPut(profile.arena, writer.buffered());
        if (!entry.found_existing) {
            entry.key_ptr.* = try profile.arena.dupe(u8, writer.buffered());
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        profile.samples += 1;
    }

    fn name_write(
        profile: *Profile,
        writer: *std.Io.Writer,
        pid: linux.pid_t,
        maps: *const Maps,
        address: u64,
    ) !void {
        const map = maps.find(address) orelse return writer.print("0x{x}", .{address});
        if (map.anonymous) {
            // JIT-compiled code: named by its runtime's jitdump file, when it writes one.
            if (profile.jit_of(pid, maps)) |jit| if (jit.name(address)) |name| return writer.writeAll(name);
            return writer.print("[jit]+0x{x}", .{address - map.start});
        }
        const symbols = profile.symbols_of(pid, map.path);
        const file_offset = address - map.start + map.offset;
        if (symbols) |table| {
            if (table.name(file_offset)) |name| return writer.writeAll(name);
        }
        const base = std.fs.path.basename(map.path);
        try writer.print("{s}+0x{x}", .{ base, file_offset });
    }

    /// The process's JIT code names, read again when its jitdump file grew (code compiled since).
    fn jit_of(profile: *Profile, pid: linux.pid_t, maps: *const Maps) ?*const Jit {
        const path = maps.jitdump orelse return null;
        const size = file_size(pid, path) orelse return null;
        for (profile.jits[0..profile.jits_count]) |*jit| {
            if (jit.pid != pid) continue;
            if (jit.size != size) jit.* = Jit.load(profile.arena, pid, path, size);
            return jit;
        }
        if (profile.jits_count == processes_max) return null;
        const jit = &profile.jits[profile.jits_count];
        jit.* = Jit.load(profile.arena, pid, path, size);
        profile.jits_count += 1;
        return jit;
    }

    /// The file's symbols and call frame information, loaded once.
    fn symbols_of(profile: *Profile, pid: linux.pid_t, path: []const u8) ?*const Symbols {
        for (profile.files[0..profile.files_count]) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        if (profile.files_count == symbols_files_max) return null;
        const file = &profile.files[profile.files_count];
        file.* = Symbols.load(profile.arena, pid, path);
        profile.files_count += 1;
        return file;
    }

    /// The thread's instruction pointer, then the return addresses of its callers: each frame
    /// unwound by its file's call frame information, else by its frame pointer.
    fn stack_sample(
        profile: *Profile,
        pid: linux.pid_t,
        tid: linux.pid_t,
        maps: *const Maps,
        frames: *[frames_max]u64,
    ) usize {
        if (linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) != .SUCCESS) return 0;
        defer _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
        if (linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) != .SUCCESS) return 0;
        var status: i32 = 0;
        _ = linux.wait4(tid, &status, wait_all, null);
        // struct user_regs_struct: 27 registers; rbp the 5th, rip the 17th, rsp the 20th.
        var registers: [27]u64 = undefined;
        const regs_address = @intFromPtr(&registers);
        if (linux.errno(linux.ptrace(linux.PTRACE.GETREGS, tid, 0, regs_address, 0)) != .SUCCESS) {
            return 0;
        }
        frames[0] = registers[16];
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{pid}, 0) catch
            return 1;
        const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return 1;
        defer _ = linux.close(@intCast(fd));
        const memory: linux.fd_t = @intCast(fd);
        var frame: Frame = .{ .pc = registers[16], .sp = registers[19], .bp = registers[4] };
        var depth: usize = 1;
        while (depth < frames_max) {
            // A caller's return address points after its call: its rule is the call's.
            const lookup = if (depth == 1) frame.pc else frame.pc -% 1;
            const next = profile.cfi_step(pid, maps, memory, frame, lookup) orelse
                frame_pointer_step(memory, frame) orelse break;
            if (next.pc == 0 or next.sp <= frame.sp) break; // Stacks grow down: callers are higher.
            frames[depth] = next.pc;
            depth += 1;
            frame = next;
        }
        return depth;
    }

    /// The caller's frame by the rule of the file mapped at `lookup`, if it has one there.
    fn cfi_step(
        profile: *Profile,
        pid: linux.pid_t,
        maps: *const Maps,
        memory: linux.fd_t,
        frame: Frame,
        lookup: u64,
    ) ?Frame {
        const map = maps.find(lookup) orelse return null;
        const symbols = profile.symbols_of(pid, map.path) orelse return null;
        const tables = symbols.cfi orelse return null;
        const address = symbols.address_of(lookup - map.start + map.offset) orelse return null;
        const rule = tables.rule(address) orelse return null;
        const base = if (rule.cfa_register == 7) frame.sp else frame.bp;
        const cfa: u64 = @bitCast(@as(i64, @bitCast(base)) +% rule.cfa_offset);
        const ra = switch (rule.ra) {
            .offset => |offset| word_read(memory, offset_add(cfa, offset)) orelse return null,
            else => return null, // The outermost frame.
        };
        const bp = switch (rule.bp) {
            .same => frame.bp,
            .undefined => 0,
            .offset => |offset| word_read(memory, offset_add(cfa, offset)) orelse return null,
        };
        return .{ .pc = ra, .sp = cfa, .bp = bp };
    }

    fn print(profile: *const Profile) !void {
        const Entry = struct { stack: []const u8, count: u32 };
        var entries: std.ArrayList(Entry) = .empty;
        var iterator = profile.stacks.iterator();
        while (iterator.next()) |entry| {
            try entries.append(profile.arena, .{
                .stack = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }
        const order = struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.stack, b.stack);
            }
        };
        std.mem.sort(Entry, entries.items, {}, order.before);
        var out: std.Io.Writer.Allocating = .init(profile.arena);
        try out.writer.print("# det-profile: {d} samples\n", .{profile.samples});
        const shown = entries.items[0..@min(entries.items.len, folded_shown_max)];
        for (shown) |entry| try out.writer.print("{s} {d}\n", .{ entry.stack, entry.count });
        try write_stdout(out.written());
    }
};

fn write_stdout(text: []const u8) !void {
    var written: usize = 0;
    while (written < text.len) {
        const result = linux.write(1, text[written..].ptr, text.len - written);
        if (linux.errno(result) != .SUCCESS) return error.Write;
        written += result;
    }
}

/// Whether the thread is running or ready to (state R in /proc/<tid>/stat).
fn runnable(tid: linux.pid_t) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{tid}, 0) catch
        return false;
    var buffer: [512]u8 = undefined;
    const text = read_file(path, &buffer) orelse return false;
    // "<tid> (<comm>) <state> ...": comm may hold spaces and parentheses; the last ')' ends it.
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    return close + 2 < text.len and text[close + 2] == 'R';
}

const Frame = struct { pc: u64, sp: u64, bp: u64 };

/// The caller's frame by the frame pointer: the saved frame pointer, then the return address.
fn frame_pointer_step(memory: linux.fd_t, frame: Frame) ?Frame {
    if (frame.bp == 0 or frame.bp % 8 != 0 or frame.bp < frame.sp) return null;
    var pair: [2]u64 = undefined;
    const bytes = std.mem.asBytes(&pair);
    const read = linux.pread(memory, bytes, bytes.len, @intCast(frame.bp));
    if (linux.errno(read) != .SUCCESS or read != bytes.len) return null;
    return .{ .pc = pair[1], .sp = frame.bp + 16, .bp = pair[0] };
}

fn word_read(memory: linux.fd_t, address: u64) ?u64 {
    var word: u64 = undefined;
    const bytes = std.mem.asBytes(&word);
    const read = linux.pread(memory, bytes, bytes.len, @bitCast(address));
    if (linux.errno(read) != .SUCCESS or read != bytes.len) return null;
    return word;
}

fn offset_add(address: u64, offset: i64) u64 {
    return @bitCast(@as(i64, @bitCast(address)) +% offset);
}

/// The stack of a thread ptrace cannot stop: its stack and instruction pointers from
/// /proc/<pid>/task/<tid>/syscall (kept while it is in the kernel), then the longest chain of
/// frame links (a saved frame pointer above it, then a return address into executable code)
/// in the stack memory above the stack pointer.
fn stack_scan(pid: linux.pid_t, tid: linux.pid_t, maps: *const Maps, frames: *[frames_max]u64) usize {
    var path_buffer: [64]u8 = undefined;
    const syscall_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task/{d}/syscall", .{
        pid, tid,
    }, 0) catch return 0;
    var text_buffer: [256]u8 = undefined;
    const text = read_file(syscall_path, &text_buffer) orelse return 0;
    const pointers = syscall_pointers(text) orelse return 0;
    frames[0] = pointers.pc;
    const mem_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{pid}, 0) catch return 1;
    const fd = linux.open(mem_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    var words: [stack_scan_size / 8]u64 = undefined;
    const base = pointers.sp & ~@as(u64, 7);
    var count: usize = 0;
    while (count < words.len) { // Page by page: the stack's mapping may end before the buffer.
        const chunk = std.mem.sliceAsBytes(words[count..@min(words.len, count + 512)]);
        const read = linux.pread(@intCast(fd), chunk.ptr, chunk.len, @intCast(base + count * 8));
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        count += read / 8;
        if (read < chunk.len) break;
    }
    return frames_link(words[0..count], base, maps, frames);
}

const stack_scan_size = 64 * 1024;

const Pointers = struct { sp: u64, pc: u64 };

/// The last two fields of /proc/<pid>/task/<tid>/syscall: "<nr> <args...> <sp> <pc>", or
/// "-1 <sp> <pc>" outside a system call; "running" has none.
fn syscall_pointers(text: []const u8) ?Pointers {
    var fields: [9][]const u8 = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \n");
    while (tokens.next()) |token| {
        if (count == fields.len) return null;
        fields[count] = token;
        count += 1;
    }
    if (count < 3) return null;
    const sp = std.fmt.parseInt(u64, fields[count - 2], 0) catch return null;
    const pc = std.fmt.parseInt(u64, fields[count - 1], 0) catch return null;
    return .{ .sp = sp, .pc = pc };
}

/// The longest chain of frame links in `words` (the stack from `base`): each a saved frame
/// pointer to a higher link, then a return address into executable code. Fills frames[1..].
fn frames_link(words: []const u64, base: u64, maps: *const Maps, frames: *[frames_max]u64) usize {
    var best_start: ?usize = null;
    var best_length: usize = 0;
    var start: usize = 0;
    while (start + 1 < words.len) : (start += 1) {
        const length = chain_length(words, base, maps, start);
        if (length > best_length) {
            best_length = length;
            best_start = start;
        }
    }
    var depth: usize = 1;
    var at = best_start orelse return depth;
    while (depth < frames_max) {
        frames[depth] = words[at + 1];
        depth += 1;
        const next = link_next(words, base, maps, at) orelse break;
        at = next;
    }
    return depth;
}

fn chain_length(words: []const u64, base: u64, maps: *const Maps, start: usize) usize {
    if (maps.find(words[start + 1]) == null) return 0;
    var length: usize = 1;
    var at = start;
    while (length < frames_max) {
        at = link_next(words, base, maps, at) orelse break;
        length += 1;
    }
    return length;
}

/// The link a frame pointer at `at` points to, if it is a link higher in the stack.
fn link_next(words: []const u64, base: u64, maps: *const Maps, at: usize) ?usize {
    const pointer = words[at];
    const here = base + at * 8;
    if (pointer <= here or pointer % 8 != 0) return null;
    const next = (pointer - base) / 8;
    if (next + 1 >= words.len) return null;
    if (maps.find(words[next + 1]) == null) return null;
    return next;
}

fn process_name(pid: linux.pid_t) []const u8 {
    const State = struct {
        var buffer: [64]u8 = undefined;
    };
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch
        return "?";
    const text = read_file(path, &State.buffer) orelse return "?";
    return std.mem.trimEnd(u8, text, "\n");
}

/// A process's executable mappings (/proc/<pid>/maps), each with the file mapped there.
const Maps = struct {
    entries: [maps_max]Map = undefined,
    count: u32 = 0,
    text: [512 * 1024]u8 = undefined,

    /// Its JIT runtime's jitdump file (`jit-<pid>.dump`, mapped so perf finds it), if any.
    jitdump: ?[]const u8 = null,

    /// Executable memory: a file's, or anonymous (`anonymous`, no path: JIT-compiled code).
    const Map = struct { start: u64, end: u64, offset: u64, path: []const u8, anonymous: bool = false };

    fn load(maps: *Maps, pid: linux.pid_t) void {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/maps", .{pid}, 0) catch
            return;
        const text = read_file(path, &maps.text) orelse return;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (maps.count == maps_max) return;
            // "start-end perms offset dev inode path"
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const range = fields.next() orelse continue;
            const perms = fields.next() orelse continue;
            const offset = fields.next() orelse continue;
            _ = fields.next(); // dev
            _ = fields.next(); // inode
            const file = fields.rest();
            if (perms.len < 3 or perms[2] != 'x') continue;
            const base = std.fs.path.basename(file);
            if (file.len > 0 and file[0] == '/' and std.mem.startsWith(u8, base, "jit-") and std.mem.endsWith(u8, base, ".dump")) {
                maps.jitdump = file; // Mapped for perf to find, not code.
                continue;
            }
            const anonymous = file.len == 0;
            if (!anonymous and file[0] != '/') continue; // [vdso], [vsyscall]
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
            maps.entries[maps.count] = .{
                .start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue,
                .end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue,
                .offset = std.fmt.parseInt(u64, offset, 16) catch continue,
                .path = file,
                .anonymous = anonymous,
            };
            maps.count += 1;
        }
    }

    fn find(maps: *const Maps, address: u64) ?*const Map {
        for (maps.entries[0..maps.count]) |*map| {
            if (address >= map.start and address < map.end) return map;
        }
        return null;
    }
};

/// A process's JIT-compiled functions, from its jitdump file (perf's format: a header, then
/// records; a code load names a function at an address: tools/perf/Documentation/jitdump-
/// specification.txt), sorted by address.
const Jit = struct {
    pid: linux.pid_t,
    size: u64,
    functions: []const Symbols.Function = &.{},

    fn load(arena: std.mem.Allocator, pid: linux.pid_t, path: []const u8, size: u64) Jit {
        var jit = Jit{ .pid = pid, .size = size };
        var path_buffer: [nodes.path_size_max]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/root{s}", .{ pid, path }, 0) catch return jit;
        const bytes = arena.alloc(u8, @min(size, jitdump_size_max)) catch return jit;
        const text = read_file(full, bytes) orelse return jit;
        jit.functions = jitdump_functions(arena, text) catch &.{};
        return jit;
    }

    fn name(jit: *const Jit, address: u64) ?[]const u8 {
        // The last function starting at or before the address, if the address is inside it.
        var low: usize = 0;
        var high: usize = jit.functions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (jit.functions[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const function = jit.functions[low - 1];
        return if (address < function.address + function.size) function.name else null;
    }
};

const jitdump_size_max = 256 << 20;
const jitdump_magic = 0x4A695444; // "JiTD", written in the host's byte order.
const jitdump_code_load = 0;

/// The code-load records of a jitdump file: each function's address, size and name.
fn jitdump_functions(arena: std.mem.Allocator, bytes: []const u8) ![]const Symbols.Function {
    if (bytes.len < 40 or std.mem.readInt(u32, bytes[0..4], .little) != jitdump_magic) return error.NotJitdump;
    const header_size = std.mem.readInt(u32, bytes[8..12], .little);
    var functions: std.ArrayList(Symbols.Function) = .empty;
    var at: usize = header_size;
    while (at + 16 <= bytes.len) {
        const id = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const total = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        if (total < 16 or at + total > bytes.len) break; // Being written: what came before stands.
        if (id == jitdump_code_load and total >= 16 + 40 + 1) {
            const record = bytes[at + 16 .. at + total];
            const code_address = std.mem.readInt(u64, record[16..24], .little);
            const code_size = std.mem.readInt(u64, record[24..32], .little);
            const name_bytes = record[40..];
            const end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
            try functions.append(arena, .{ .address = code_address, .size = code_size, .name = name_bytes[0..end] });
        }
        at += total;
    }
    std.mem.sort(Symbols.Function, functions.items, {}, struct {
        fn before(_: void, a: Symbols.Function, b: Symbols.Function) bool {
            return a.address < b.address;
        }
    }.before);
    return functions.items;
}

fn file_size(pid: linux.pid_t, path: []const u8) ?u64 {
    var path_buffer: [nodes.path_size_max]u8 = undefined;
    const full = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/root{s}", .{ pid, path }, 0) catch return null;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, full, 0, .{ .SIZE = true }, &stat)) != .SUCCESS) return null;
    return stat.size;
}

test jitdump_functions {
    // A header (40 bytes), a code load (16 + 40 + "jank_fn_a\0" + code), a debug-info record
    // skipped, a second code load, then a record cut short (being written).
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    var header: [40]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], jitdump_magic, .little);
    std.mem.writeInt(u32, header[4..8], 1, .little);
    std.mem.writeInt(u32, header[8..12], 40, .little);
    try bytes.appendSlice(a, &header);
    for ([_]struct { id: u32, address: u64, size: u64, name: []const u8 }{
        .{ .id = 0, .address = 0x7000_2000, .size = 0x40, .name = "user_square" },
        .{ .id = 2, .address = 0, .size = 0, .name = "" },
        .{ .id = 0, .address = 0x7000_1000, .size = 0x100, .name = "clojure_core_map" },
    }) |r| {
        const body = 40 + r.name.len + 1 + 4;
        var record: [16]u8 = @splat(0);
        std.mem.writeInt(u32, record[0..4], r.id, .little);
        std.mem.writeInt(u32, record[4..8], @intCast(16 + body), .little);
        try bytes.appendSlice(a, &record);
        var fields: [40]u8 = @splat(0);
        std.mem.writeInt(u64, fields[16..24], r.address, .little);
        std.mem.writeInt(u64, fields[24..32], r.size, .little);
        try bytes.appendSlice(a, &fields);
        try bytes.appendSlice(a, r.name);
        try bytes.appendSlice(a, &[_]u8{ 0, 0x90, 0x90, 0x90, 0x90 });
    }
    try bytes.appendSlice(a, &[_]u8{ 0, 0, 0, 0, 0xff, 0, 0, 0 }); // Cut short.
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const functions = try jitdump_functions(arena_state.allocator(), bytes.items);
    try std.testing.expectEqual(@as(usize, 2), functions.len);
    const jit = Jit{ .pid = 1, .size = bytes.items.len, .functions = functions };
    try std.testing.expectEqualStrings("clojure_core_map", jit.name(0x7000_1080).?);
    try std.testing.expectEqualStrings("user_square", jit.name(0x7000_2000).?);
    try std.testing.expectEqual(@as(?[]const u8, null), jit.name(0x7000_1100));
    try std.testing.expectEqual(@as(?[]const u8, null), jit.name(0x6fff_ffff));
}

/// A file's functions, from its ELF symbol table (or its dynamic one), sorted by address, and
/// its loadable segments, which turn file offsets into those addresses.
const Symbols = struct {
    path: []const u8,
    functions: []const Function = &.{},
    segments: []const Segment = &.{},
    /// Its .eh_frame and .eh_frame_hdr, when it has them.
    cfi: ?unwind.Tables = null,

    const Function = struct { address: u64, size: u64, name: []const u8 };
    const Segment = struct { offset: u64, size: u64, address: u64 };

    fn load(arena: std.mem.Allocator, pid: linux.pid_t, path: []const u8) Symbols {
        var symbols = Symbols{ .path = arena.dupe(u8, path) catch path };
        var path_buffer: [nodes.path_size_max]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/root{s}", .{
            pid, path,
        }, 0) catch return symbols;
        const fd = linux.open(full, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return symbols;
        defer _ = linux.close(@intCast(fd));
        symbols.read(arena, @intCast(fd)) catch {};
        return symbols;
    }

    fn read(symbols: *Symbols, arena: std.mem.Allocator, fd: linux.fd_t) !void {
        const header = try pread_struct(elf.Elf64_Ehdr, fd, 0);
        if (!std.mem.eql(u8, header.e_ident[0..4], elf.MAGIC)) return error.NotElf;
        var segments: std.ArrayList(Segment) = .empty;
        for (0..header.e_phnum) |index| {
            const at = header.e_phoff + index * header.e_phentsize;
            const program = try pread_struct(elf.Elf64.Phdr, fd, at);
            if (program.type != .LOAD) continue;
            try segments.append(arena, .{
                .offset = program.offset,
                .size = program.filesz,
                .address = program.vaddr,
            });
        }
        symbols.segments = segments.items;
        const sections = try arena.alloc(elf.Elf64_Shdr, header.e_shnum);
        for (sections, 0..) |*section, index| {
            const at = header.e_shoff + index * header.e_shentsize;
            section.* = try pread_struct(elf.Elf64_Shdr, fd, at);
        }
        symbols.cfi_read(arena, fd, header, sections) catch {};
        // The full table when the file keeps it, else the dynamic one.
        const table = section_find(sections, elf.SHT_SYMTAB) orelse
            section_find(sections, elf.SHT_DYNSYM) orelse return;
        if (table.sh_link >= sections.len) return error.BadElf;
        const strings = try pread_alloc(arena, fd, sections[table.sh_link]);
        const raw = try pread_alloc(arena, fd, table);
        try symbols.functions_collect(arena, raw, strings);
    }

    fn functions_collect(
        symbols: *Symbols,
        arena: std.mem.Allocator,
        raw: []const u8,
        strings: []const u8,
    ) !void {
        var functions: std.ArrayList(Function) = .empty;
        var at: usize = 0;
        while (at + @sizeOf(elf.Elf64_Sym) <= raw.len) : (at += @sizeOf(elf.Elf64_Sym)) {
            const bytes = raw[at..][0..@sizeOf(elf.Elf64_Sym)];
            const symbol = std.mem.bytesToValue(elf.Elf64_Sym, bytes);
            if (symbol.st_type() != elf.STT_FUNC or symbol.st_value == 0) continue;
            if (symbol.st_name >= strings.len) continue;
            try functions.append(arena, .{
                .address = symbol.st_value,
                .size = symbol.st_size,
                .name = std.mem.sliceTo(strings[symbol.st_name..], 0),
            });
        }
        const order = struct {
            fn before(_: void, a: Function, b: Function) bool {
                return a.address < b.address;
            }
        };
        std.mem.sort(Function, functions.items, {}, order.before);
        symbols.functions = functions.items;
    }

    /// .eh_frame and .eh_frame_hdr, by their section names.
    fn cfi_read(
        symbols: *Symbols,
        arena: std.mem.Allocator,
        fd: linux.fd_t,
        header: elf.Elf64_Ehdr,
        sections: []const elf.Elf64_Shdr,
    ) !void {
        if (header.e_shstrndx >= sections.len) return error.BadElf;
        const names = try pread_alloc(arena, fd, sections[header.e_shstrndx]);
        var frame: ?elf.Elf64_Shdr = null;
        var hdr: ?elf.Elf64_Shdr = null;
        for (sections) |section| {
            if (section.sh_name >= names.len or section.sh_type == elf.SHT_NOBITS) continue;
            const name_of = std.mem.sliceTo(names[section.sh_name..], 0);
            if (std.mem.eql(u8, name_of, ".eh_frame")) frame = section;
            if (std.mem.eql(u8, name_of, ".eh_frame_hdr")) hdr = section;
        }
        const frame_section = frame orelse return;
        var tables: unwind.Tables = .{
            .frame = try pread_alloc(arena, fd, frame_section),
            .frame_address = frame_section.sh_addr,
        };
        if (hdr) |hdr_section| {
            tables.hdr = try pread_alloc(arena, fd, hdr_section);
            tables.hdr_address = hdr_section.sh_addr;
        }
        symbols.cfi = tables;
    }

    /// A file offset's address in the file's ELF space (its loadable segments).
    fn address_of(symbols: *const Symbols, file_offset: u64) ?u64 {
        for (symbols.segments) |segment| {
            if (file_offset >= segment.offset and file_offset < segment.offset + segment.size) {
                return file_offset - segment.offset + segment.address;
            }
        }
        return null;
    }

    /// The function at a file offset: the last one starting at or before its address, if the
    /// address falls inside it (or it has no size).
    fn name(symbols: *const Symbols, file_offset: u64) ?[]const u8 {
        const address = symbols.address_of(file_offset) orelse return null;
        var low: usize = 0;
        var high: usize = symbols.functions.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (symbols.functions[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const function = symbols.functions[low - 1];
        if (function.size > 0 and address >= function.address + function.size) return null;
        return function.name;
    }
};

fn section_find(sections: []const elf.Elf64_Shdr, kind: u32) ?elf.Elf64_Shdr {
    for (sections) |section| {
        if (section.sh_type == kind) return section;
    }
    return null;
}

fn pread_struct(comptime T: type, fd: linux.fd_t, offset: u64) !T {
    var value: T = undefined;
    const bytes = std.mem.asBytes(&value);
    const read = linux.pread(fd, bytes.ptr, bytes.len, @intCast(offset));
    if (linux.errno(read) != .SUCCESS or read != bytes.len) return error.ShortRead;
    return value;
}

fn pread_alloc(arena: std.mem.Allocator, fd: linux.fd_t, section: elf.Elf64_Shdr) ![]u8 {
    const buffer = try arena.alloc(u8, section.sh_size);
    var done: usize = 0;
    while (done < buffer.len) {
        const at: i64 = @intCast(section.sh_offset + done);
        const read = linux.pread(fd, buffer[done..].ptr, buffer.len - done, at);
        if (linux.errno(read) != .SUCCESS or read == 0) return error.ShortRead;
        done += read;
    }
    return buffer;
}

fn read_file(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < buffer.len) {
        const read = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        size += read;
    }
    return buffer[0..size];
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_ns(duration_ns: u64) void {
    var request = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

test syscall_pointers {
    const blocked = syscall_pointers("-1 0x7ffec13c2320 0x126e816\n").?;
    try std.testing.expectEqual(0x7ffec13c2320, blocked.sp);
    try std.testing.expectEqual(0x126e816, blocked.pc);
    const waiting = syscall_pointers("7 0x1 0x2 0x3 0x0 0x0 0x0 0x7ffc00001000 0x401000\n").?;
    try std.testing.expectEqual(0x401000, waiting.pc);
    try std.testing.expectEqual(null, syscall_pointers("running\n"));
}

test frames_link {
    // Code at 0x1000-0x2000; a stack from 0x8000 with noise, then links 0x8010 -> 0x8030 -> 0x8050.
    var maps: Maps = .{};
    maps.entries[0] = .{ .start = 0x1000, .end = 0x2000, .offset = 0, .path = "/bin/x" };
    maps.count = 1;
    const words = [_]u64{ 0x1234, 0x1500, 0x8030, 0x1100, 0, 0, 0x8050, 0x1200, 0, 0, 0, 0x1300 };
    var frames: [frames_max]u64 = undefined;
    frames[0] = 0x1001;
    const depth = frames_link(&words, 0x8000, &maps, &frames);
    try std.testing.expectEqual(4, depth);
    try std.testing.expectEqualSlices(u64, &.{ 0x1001, 0x1100, 0x1200, 0x1300 }, frames[0..depth]);
}

test "options" {
    const arguments = [_][:0]const u8{ "det-profile", "redis", "--ms", "200", "--all" };
    const options = try options_parse(&arguments);
    try std.testing.expectEqualStrings("redis", options.node);
    try std.testing.expectEqual(200 * std.time.ns_per_ms, options.duration_ns);
    try std.testing.expect(options.all);
    const bad = [_][:0]const u8{ "det-profile", "redis", "--ms" };
    try std.testing.expectError(error.Usage, options_parse(&bad));
}

test {
    _ = unwind;
}

test "symbols name file offsets" {
    const functions = [_]Symbols.Function{
        .{ .address = 0x1000, .size = 0x10, .name = "first" },
        .{ .address = 0x1020, .size = 0, .name = "second" },
    };
    const segments = [_]Symbols.Segment{.{ .offset = 0, .size = 0x2000, .address = 0x0 }};
    const symbols = Symbols{ .path = "/bin/x", .functions = &functions, .segments = &segments };
    try std.testing.expectEqualStrings("first", symbols.name(0x1008).?);
    try std.testing.expectEqual(null, symbols.name(0x1018));
    try std.testing.expectEqualStrings("second", symbols.name(0x1fff).?);
    try std.testing.expectEqual(null, symbols.name(0x0fff));
}
