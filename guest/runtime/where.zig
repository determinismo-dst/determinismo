// SPDX-License-Identifier: MIT
//! Where a process crashed, for its `crash_stack` event (cores.zig emits it beside
//! `core_dump`): the crashed thread's registers and the address its fault was on, from the
//! core's notes (the dump's first NT_PRSTATUS is the thread the signal went to, NT_SIGINFO its
//! signal's), and its stack from the core's memory: the instruction it stopped at, the return
//! addresses its frame pointers chain, and the words at its stack's top that point into code
//! (code built without frame pointers, as a libc's abort under an assertion, has no chain: the
//! caller is among those words, with whatever older calls left there). Each address is named by
//! its source line when the node has its module's table of lines (/symbols/.determinismo,
//! src/lines.zig: what names coverage's edges), else by its function, file and line when the
//! module is a Go program (its own .gopclntab, which a stripped release binary keeps:
//! gopclntab.zig), else by its function and offset from the module's ELF symbols (.symtab, else
//! a stripped library's .dynsym: libc's exit, abort; elfsyms.zig), else by its module and offset.
//!
//! The process's maps are read while it is still there (before its dump is read to its end),
//! and its modules' tables opened through its root (/proc/<pid>/root) then too.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const gopclntab = @import("gopclntab.zig");
const elfsyms = @import("elfsyms.zig");

pub const frames_max = 12;
pub const scanned_max = 8;
/// A name's length at most: the event holds them all in one message (sdk's message_size_max).
const name_size_max = 96;
const maps_size_max = 1 << 20;
const mappings_max = 1024;
const modules_max = 24;
const headers_size_max = 1 << 20;
const notes_size_max = 8 << 20;
/// How far up the stack's top its words are looked at.
const scan_size = 2048;
const frame_size_max = 1 << 20;

const pt_load = 1;
const pt_note = 4;
const et_dyn = 3;
const nt_prstatus = 1;
const nt_gnu_build_id = 3;
const nt_siginfo = 0x53494749;
/// struct elf_prstatus on x86-64: pr_reg (user_regs_struct) at 112; in it rbp is the 5th
/// register, rip the 17th, rsp the 20th.
const prstatus_registers = 112;
const prstatus_size = 336;
const register_rbp = 4;
const register_rip = 16;
const register_rsp = 19;
/// Signals whose siginfo holds the address at fault: SIGILL, SIGTRAP, SIGBUS, SIGFPE, SIGSEGV.
const signals_with_address = [_]i32{ 4, 5, 7, 8, 11 };

const Mapping = struct { start: u64, end: u64, offset: u64, executable: bool, path: []const u8 };

/// A crashing process's mappings and its modules' tables of lines, read before its dump is
/// consumed.
pub const Process = struct {
    pid: linux.pid_t,
    mappings: []const Mapping,
    modules: []const Module = &.{},

    pub fn read(arena: std.mem.Allocator, pid: linux.pid_t) Process {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/maps", .{pid}, 0) catch unreachable;
        const text = file_read(arena, path, maps_size_max) orelse return .{ .pid = pid, .mappings = &.{} };
        var mappings: std.ArrayList(Mapping) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (mappings.items.len == mappings_max) break;
            // "start-end perms offset dev inode   path"
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const range = fields.next() orelse continue;
            const permissions = fields.next() orelse continue;
            const offset_text = fields.next() orelse continue;
            _ = fields.next();
            _ = fields.next();
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
            mappings.append(arena, .{
                .start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue,
                .end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue,
                .offset = std.fmt.parseInt(u64, offset_text, 16) catch continue,
                .executable = std.mem.indexOfScalar(u8, permissions, 'x') != null,
                .path = fields.rest(),
            }) catch break;
        }
        var process: Process = .{ .pid = pid, .mappings = mappings.items };
        var modules: std.ArrayList(Module) = .empty;
        next: for (process.mappings) |mapping| {
            if (!mapping.executable or mapping.path.len == 0 or mapping.path[0] != '/') continue;
            for (modules.items) |module| if (std.mem.eql(u8, module.path, mapping.path)) continue :next;
            if (modules.items.len == modules_max) break;
            modules.append(arena, module_load(arena, &process, mapping.path)) catch break;
        }
        process.modules = modules.items;
        return process;
    }

    /// Closes its modules' files (a forwarder walks many exits' stacks in its life).
    pub fn release(process: *const Process) void {
        for (process.modules) |module| {
            if (module.table) |fd| _ = linux.close(fd);
            if (module.go) |go| _ = linux.close(go.fd);
        }
    }

    /// The addresses in memory, in [start, end), where source `line` begins: of a file whose path
    /// ends with `file` (any file when null), from the table of lines of the module at `path`
    /// (lines.zig). Each run of rows on that line counts once, at its first row: the first
    /// instruction of the line's code there (det-nodes hold's `<function>@<line>`). Null when the
    /// module has no table; empty when the line has no code in the range.
    pub fn line_starts(process: *const Process, arena: std.mem.Allocator, path: []const u8, file: ?[]const u8, line: u32, start: u64, end: u64) ?[]const u64 {
        const module = process.module_of(path) orelse return null;
        const table = module.table orelse return null;
        if (start < module.bias or end < start) return &.{};
        return line_starts_in(arena, table, module.rows, file, line, start - module.bias, end - module.bias, module.bias);
    }

    fn module_of(process: *const Process, path: []const u8) ?*const Module {
        for (process.modules) |*module| {
            if (std.mem.eql(u8, module.path, path)) return module;
        }
        return null;
    }

    fn code_at(process: *const Process, address: u64) ?Mapping {
        for (process.mappings) |mapping| {
            if (mapping.executable and address >= mapping.start and address < mapping.end) return mapping;
        }
        return null;
    }

    /// Where a module's file starts in memory: its lowest mapping.
    fn base_of(process: *const Process, path: []const u8) u64 {
        var base: u64 = std.math.maxInt(u64);
        for (process.mappings) |mapping| {
            if (std.mem.eql(u8, mapping.path, path)) base = @min(base, mapping.start - @min(mapping.start, mapping.offset));
        }
        return base;
    }
};

pub const Frame = struct { address: []const u8, at: []const u8 };

pub const Where = struct {
    rip: []const u8,
    rsp: []const u8,
    rbp: []const u8,
    /// The signal's code (si_code: SEGV_MAPERR 1, SEGV_ACCERR 2, SI_TKILL -6 for an abort).
    code: i32,
    /// The address the fault was on (a segfault's, a bus error's); null for another signal.
    fault_address: ?[]const u8,
    /// The instruction the thread stopped at, then its callers by its frame pointers.
    frames: []const Frame,
    /// Words of the stack's top that point into code and are not among the frames.
    scanned: []const Frame,
};

const Load = struct { address: u64, offset: u64, size: u64 };

/// A process's memory as a stack walk reads it: a crashed one's from its core, a live one's from
/// /proc/<pid>/mem (exits.zig: a process held at its exit).
const Memory = union(enum) {
    core: struct { fd: linux.fd_t, loads: []const Load },
    live: linux.fd_t,

    /// The 8 bytes at `address`, if the memory has them.
    fn word(memory: *const Memory, address: u64) ?u64 {
        var bytes: [8]u8 = undefined;
        switch (memory.*) {
            .core => |core| {
                for (core.loads) |load| {
                    if (address < load.address or address - load.address + 8 > load.size) continue;
                    if (!pread_all(core.fd, &bytes, load.offset + (address - load.address))) return null;
                    return std.mem.readInt(u64, &bytes, .little);
                }
                return null;
            },
            .live => |fd| {
                if (!pread_all(fd, &bytes, address)) return null;
                return std.mem.readInt(u64, &bytes, .little);
            },
        }
    }
};

/// A module's table of lines, looked into where it lies (a large server's is hundreds of MB).
const Module = struct {
    path: []const u8,
    /// What its addresses in memory are above its file's.
    bias: u64,
    table: ?linux.fd_t,
    rows: u64,
    /// A Go program's own table (gopclntab.zig): its file, the table's offset, its text's address.
    go: ?struct { fd: linux.fd_t, at: u64, text: u64 } = null,
};

/// A file read by offset (gopclntab.Source): the context is its descriptor.
fn descriptor_read(context: *const anyopaque, buffer: []u8, offset: u64) bool {
    const fd: *const linux.fd_t = @ptrCast(@alignCast(context));
    return pread_all(fd.*, buffer, offset);
}

const Names = struct {
    arena: std.mem.Allocator,
    process: *const Process,
    /// Each module's ELF symbols (by its index), read at the first frame in it that nothing
    /// else names: a walk reads a library's table once, and only the libraries its frames are in.
    symbols: []?elfsyms.Symbols,
    symbols_read: []bool,

    fn of(arena: std.mem.Allocator, process: *const Process) Names {
        const none: Names = .{ .arena = arena, .process = process, .symbols = &.{}, .symbols_read = &.{} };
        const symbols = arena.alloc(?elfsyms.Symbols, process.modules.len) catch return none;
        const read = arena.alloc(bool, symbols.len) catch return none;
        @memset(read, false);
        return .{ .arena = arena, .process = process, .symbols = symbols, .symbols_read = read };
    }

    /// `address` (a return address when `returned`: the call is the instruction before it) as
    /// its source line, its Go function and line, or its ELF function and offset, else its module
    /// and offset, else itself.
    fn name(names: *const Names, address: u64, returned: bool) []const u8 {
        const arena = names.arena;
        const fallback = std.fmt.allocPrint(arena, "0x{x}", .{address}) catch "";
        const mapping = names.process.code_at(address) orelse return fallback;
        const base = std.fs.path.basename(mapping.path);
        const offset = address - mapping.start + mapping.offset;
        const by_module = std.fmt.allocPrint(arena, "{s}+0x{x}", .{ if (base.len > 0) base else "?", offset }) catch fallback;
        const module = names.process.module_of(mapping.path) orelse return by_module;
        const at = address - module.bias - @intFromBool(returned);
        if (module.table) |table| return line_of(arena, table, module.rows, at) orelse by_module;
        if (module.go) |*go| {
            const source: gopclntab.Source = .{ .context = &go.fd, .read = descriptor_read };
            if (gopclntab.Table.of(source, go.at, go.text)) |table| if (table.find(arena, at)) |found| {
                return gopclntab.name(arena, found, name_size_max) orelse by_module;
            };
        }
        return names.function(module, base, at) orelse by_module;
    }

    /// The ELF function of `module` holding `at` (its address less the module's bias), its name
    /// demangled, and how far in; null where the module's symbols name none.
    fn function(names: *const Names, module: *const Module, base: []const u8, at: u64) ?[]const u8 {
        const index = (@intFromPtr(module) - @intFromPtr(names.process.modules.ptr)) / @sizeOf(Module);
        if (index >= names.symbols_read.len) return null;
        if (!names.symbols_read[index]) {
            names.symbols_read[index] = true;
            names.symbols[index] = symbols_load(names.arena, names.process.pid, module.path);
        }
        const symbols = names.symbols[index] orelse return null;
        const found = symbols.find(at) orelse return null;
        return elfsyms.name(names.arena, found, if (base.len > 0) base else "?", name_size_max);
    }

    /// `address`'s ELF function alone, beside the line `name` gives a module with a table of
    /// lines: null outside code or the module's symbols.
    fn function_of(names: *const Names, address: u64, returned: bool) ?[]const u8 {
        const mapping = names.process.code_at(address) orelse return null;
        const module = names.process.module_of(mapping.path) orelse return null;
        const at = address - module.bias - @intFromBool(returned);
        return names.function(module, std.fs.path.basename(mapping.path), at);
    }
};

/// The ELF symbols of the module at `path`, read through the process's root.
fn symbols_load(arena: std.mem.Allocator, pid: linux.pid_t, path: []const u8) ?elfsyms.Symbols {
    var buffer: [512]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&buffer, "/proc/{d}/root{s}", .{ pid, path }, 0) catch return null;
    const opened = linux.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    return elfsyms.Symbols.load(arena, .{ .context = &fd, .read = descriptor_read });
}

fn module_load(arena: std.mem.Allocator, process: *const Process, path: []const u8) Module {
    var module: Module = .{ .path = path, .bias = 0, .table = null, .rows = 0 };
    var buffer: [512]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&buffer, "/proc/{d}/root{s}", .{ process.pid, path }, 0) catch return module;
    const headers = file_read(arena, file, 64 * 1024) orelse return module;
    if (headers.len < 64 or !std.mem.eql(u8, headers[0..4], "\x7fELF")) return module;
    if (std.mem.readInt(u16, headers[16..18], .little) == et_dyn) module.bias = process.base_of(path);
    // Its table: by its GNU build ID, else by its file's name (lines.zig's names).
    var key_buffer: [160]u8 = undefined;
    var key: []const u8 = std.fmt.bufPrint(&key_buffer, "name-{s}", .{std.fs.path.basename(path)}) catch return module;
    if (build_id_of(headers)) |id| {
        if (id.len * 2 <= key_buffer.len) {
            const digits = "0123456789abcdef";
            for (id, 0..) |byte, index| {
                key_buffer[index * 2] = digits[byte >> 4];
                key_buffer[index * 2 + 1] = digits[byte & 0xf];
            }
            key = key_buffer[0 .. id.len * 2];
        }
    }
    var table_buffer: [512]u8 = undefined;
    const table = std.fmt.bufPrintSentinel(&table_buffer, "/proc/{d}/root/symbols/.determinismo/{s}", .{ process.pid, key }, 0) catch return module;
    const fd = linux.open(table, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        module.go = go_load(file);
        return module;
    }
    var header: [16]u8 = undefined;
    if (!pread_all(@intCast(fd), &header, 0) or !std.mem.eql(u8, header[0..8], "DETLINES")) {
        _ = linux.close(@intCast(fd));
        return module;
    }
    module.table = @intCast(fd);
    module.rows = std.mem.readInt(u64, header[8..16], .little);
    return module;
}

/// A Go program's own table, if the file at `path` has one (its descriptor kept open for it).
fn go_load(path: [:0]const u8) @FieldType(Module, "go") {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    const sections = gopclntab.sections_of(.{ .context = &fd, .read = descriptor_read }) orelse {
        _ = linux.close(fd);
        return null;
    };
    if (gopclntab.Table.of(.{ .context = &fd, .read = descriptor_read }, sections.table, sections.text) == null) {
        _ = linux.close(fd);
        return null;
    }
    return .{ .fd = fd, .at = sections.table, .text = sections.text };
}

/// The GNU build ID in an ELF file's first bytes (its program headers' notes), if they hold it.
fn build_id_of(headers: []const u8) ?[]const u8 {
    const table = std.mem.readInt(u64, headers[32..40], .little);
    const entry_size = std.mem.readInt(u16, headers[54..56], .little);
    const count = std.mem.readInt(u16, headers[56..58], .little);
    if (entry_size < 56) return null;
    for (0..count) |index| {
        const at = table + index * entry_size;
        if (at + 56 > headers.len) return null;
        const header = headers[at..][0..56];
        if (std.mem.readInt(u32, header[0..4], .little) != pt_note) continue;
        const offset = std.mem.readInt(u64, header[8..16], .little);
        const size = std.mem.readInt(u64, header[32..40], .little);
        if (offset > headers.len or size > headers.len - offset) continue;
        var notes: Notes = .{ .bytes = headers[offset..][0..size] };
        while (notes.next()) |note| {
            if (note.kind == nt_gnu_build_id and std.mem.eql(u8, note.name, "GNU") and note.data.len > 0) return note.data;
        }
    }
    return null;
}

const Note = struct { kind: u32, name: []const u8, data: []const u8 };

const Notes = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(notes: *Notes) ?Note {
        const bytes = notes.bytes;
        if (notes.at + 12 > bytes.len) return null;
        const name_size = std.mem.readInt(u32, bytes[notes.at..][0..4], .little);
        const data_size = std.mem.readInt(u32, bytes[notes.at + 4 ..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[notes.at + 8 ..][0..4], .little);
        const name_start = notes.at + 12;
        const data_start = name_start + std.mem.alignForward(usize, name_size, 4);
        if (data_start > bytes.len or data_size > bytes.len - data_start) return null;
        notes.at = data_start + std.mem.alignForward(usize, data_size, 4);
        const name = bytes[name_start..][0..name_size];
        return .{ .kind = kind, .name = std.mem.trimEnd(u8, name, "\x00"), .data = bytes[data_start..][0..data_size] };
    }
};

/// "<file>:<line>" of a file address in a table of lines (lines.zig: "DETLINES", the rows'
/// count, rows by address {address: u64, line: u32, file: u32}, then the files' names): the
/// last row at or before it.
fn line_of(arena: std.mem.Allocator, table: linux.fd_t, rows: u64, address: u64) ?[]const u8 {
    var low: u64 = 0;
    var high: u64 = rows;
    var row: [16]u8 = undefined;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (!pread_all(table, &row, 16 + middle * 16)) return null;
        if (std.mem.readInt(u64, row[0..8], .little) <= address) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    if (!pread_all(table, &row, 16 + (low - 1) * 16)) return null;
    const line = std.mem.readInt(u32, row[8..12], .little);
    const file_at = std.mem.readInt(u32, row[12..16], .little);
    if (line == 0) return null;
    var file_buffer: [512]u8 = undefined;
    const read = linux.pread(table, &file_buffer, file_buffer.len, @intCast(16 + rows * 16 + file_at));
    if (linux.errno(read) != .SUCCESS or read == 0) return null;
    const file = std.mem.sliceTo(file_buffer[0..read], 0);
    // A long path's end: the file's name is what tells.
    const room = name_size_max - 12;
    const shown = if (file.len > room) file[file.len - room ..] else file;
    return std.fmt.allocPrint(arena, "{s}:{d}", .{ shown, line }) catch null;
}

/// The file addresses in [low, high) where `line` of a file ending with `file` begins, in a table
/// of lines (as line_of reads it), each plus `bias`: the rows from the first at or above `low`, a
/// run of rows on the line counted at its first. Null when the table cannot be read.
fn line_starts_in(arena: std.mem.Allocator, table: linux.fd_t, rows: u64, file: ?[]const u8, line: u32, low: u64, high: u64, bias: u64) ?[]const u64 {
    // The first row at or above `low`.
    var first: u64 = 0;
    var last: u64 = rows;
    var row: [16]u8 = undefined;
    while (first < last) {
        const middle = first + (last - first) / 2;
        if (!pread_all(table, &row, 16 + middle * 16)) return null;
        if (std.mem.readInt(u64, row[0..8], .little) < low) first = middle + 1 else last = middle;
    }
    // A file's name is read once: the files of a function's rows are few.
    const Known = struct { at: u32, matches: bool };
    var known: [16]Known = undefined;
    var known_count: usize = 0;
    var starts: std.ArrayList(u64) = .empty;
    var on_line = false;
    var index = first;
    while (index < rows) : (index += 1) {
        if (!pread_all(table, &row, 16 + index * 16)) return null;
        const address = std.mem.readInt(u64, row[0..8], .little);
        if (address >= high) break;
        const row_line = std.mem.readInt(u32, row[8..12], .little);
        const file_at = std.mem.readInt(u32, row[12..16], .little);
        var matches = row_line == line;
        if (matches) if (file) |suffix| {
            const seen = for (known[0..known_count]) |entry| {
                if (entry.at == file_at) break entry.matches;
            } else seen: {
                var name_buffer: [512]u8 = undefined;
                const read = linux.pread(table, &name_buffer, name_buffer.len, @intCast(16 + rows * 16 + file_at));
                if (linux.errno(read) != .SUCCESS) return null;
                const name = std.mem.sliceTo(name_buffer[0..read], 0);
                const result = path_ends_with(name, suffix);
                if (known_count < known.len) {
                    known[known_count] = .{ .at = file_at, .matches = result };
                    known_count += 1;
                }
                break :seen result;
            };
            matches = seen;
        };
        if (matches and !on_line) starts.append(arena, address + bias) catch return null;
        on_line = matches;
    }
    return starts.items;
}

/// Whether `path` is `suffix` or ends with it after a slash: `core/io/completions.rs` names
/// `/app/core/io/completions.rs`, not `/app/core/io/xcompletions.rs`.
fn path_ends_with(path: []const u8, suffix: []const u8) bool {
    if (!std.mem.endsWith(u8, path, suffix)) return false;
    return path.len == suffix.len or path[path.len - suffix.len - 1] == '/' or suffix[0] == '/';
}

/// Where the process whose core is at `core_path` crashed; null when the core does not say
/// (cut before its notes, not an x86-64 one).
pub fn of(arena: std.mem.Allocator, core_path: [:0]const u8, process: *const Process) ?Where {
    const fd = linux.open(core_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const headers = fd_read(arena, @intCast(fd), 0, headers_size_max) orelse return null;
    if (headers.len < 64 or !std.mem.eql(u8, headers[0..4], "\x7fELF")) return null;
    const table = std.mem.readInt(u64, headers[32..40], .little);
    const entry_size = std.mem.readInt(u16, headers[54..56], .little);
    const count = std.mem.readInt(u16, headers[56..58], .little);
    if (entry_size < 56) return null;
    var loads: std.ArrayList(Load) = .empty;
    var registers: ?[]const u8 = null;
    var code: i32 = 0;
    var fault: ?u64 = null;
    for (0..count) |index| {
        const at = table + index * entry_size;
        if (at + 56 > headers.len) break;
        const header = headers[at..][0..56];
        const kind = std.mem.readInt(u32, header[0..4], .little);
        const offset = std.mem.readInt(u64, header[8..16], .little);
        const size = std.mem.readInt(u64, header[32..40], .little);
        if (kind == pt_load and size > 0) {
            loads.append(arena, .{ .address = std.mem.readInt(u64, header[16..24], .little), .offset = offset, .size = size }) catch {};
        }
        if (kind != pt_note or registers != null) continue;
        const bytes = fd_read(arena, @intCast(fd), offset, @min(size, notes_size_max)) orelse continue;
        var notes: Notes = .{ .bytes = bytes };
        while (notes.next()) |note| {
            if (!std.mem.eql(u8, note.name, "CORE")) continue;
            // The first thread's status: the one the signal went to.
            if (note.kind == nt_prstatus and registers == null and note.data.len >= prstatus_size) registers = note.data;
            if (note.kind == nt_siginfo and note.data.len >= 24) {
                const signal = std.mem.readInt(i32, note.data[0..4], .little);
                code = std.mem.readInt(i32, note.data[8..12], .little);
                if (std.mem.indexOfScalar(i32, &signals_with_address, signal) != null and code > 0) {
                    fault = std.mem.readInt(u64, note.data[16..24], .little);
                }
            }
        }
    }
    const saved = registers orelse return null;
    const register = struct {
        fn of(bytes: []const u8, index: usize) u64 {
            return std.mem.readInt(u64, bytes[prstatus_registers + index * 8 ..][0..8], .little);
        }
    }.of;
    const rip = register(saved, register_rip);
    const rsp = register(saved, register_rsp);
    const rbp = register(saved, register_rbp);
    const memory: Memory = .{ .core = .{ .fd = @intCast(fd), .loads = loads.items } };
    const walked = walk(arena, process, &memory, rip, rsp, rbp) orelse return null;
    return .{
        .rip = hex(arena, rip),
        .rsp = hex(arena, rsp),
        .rbp = hex(arena, rbp),
        .code = code,
        .fault_address = if (fault) |address| hex(arena, address) else null,
        .frames = walked.frames,
        .scanned = walked.scanned,
    };
}

/// Where a live process is (exits.zig: held at its exit_group), from its memory through
/// /proc/<pid>/mem (`memory`): the instruction it is at, its callers by frame pointers when its
/// frame pointer is known (`rbp`), and the words of its stack's top that point into code.
pub fn live(arena: std.mem.Allocator, process: *const Process, memory_fd: linux.fd_t, rip: u64, rsp: u64, rbp: ?u64) ?Walked {
    const memory: Memory = .{ .live = memory_fd };
    return walk(arena, process, &memory, rip, rsp, rbp orelse 0);
}

pub const Walked = struct { frames: []const Frame, scanned: []const Frame };

/// An address named: `at` as a walk names its frames, `function` its ELF function beside it
/// (where `at` is a source line, the function holding it).
pub const Named = struct { at: ?[]const u8, function: ?[]const u8 };

/// Each of `addresses` in a live process (det-nodes where: a stopped process's stack, read by the
/// VMM, named in the guest): `at` its source line, its Go function and line, its ELF function and
/// offset, else its module and offset, and `function` its ELF function; both null for an address
/// no code mapping of the process holds. `returned`: each a return address, the call before it
/// named.
pub fn named(arena: std.mem.Allocator, process: *const Process, addresses: []const u64, returned: bool) ![]const Named {
    const names: Names = .of(arena, process);
    const found = try arena.alloc(Named, addresses.len);
    for (addresses, found) |address, *one| {
        one.* = if (process.code_at(address) == null) .{ .at = null, .function = null } else .{
            .at = names.name(address, returned),
            .function = names.function_of(address, returned),
        };
    }
    return found;
}

/// How the frame an address is in finds its caller (det-nodes cfi): its canonical frame address
/// (the caller's stack pointer) as a register plus an offset, the return address and the
/// caller's rbp as offsets from it. From the module's call-frame information (.eh_frame) when it
/// has a row for the address, else the frame pointers' rule (CFA rbp+16, the return address at
/// CFA-8, rbp at CFA-16: a module without call frames, Go's).
pub const Rule = struct {
    /// DWARF's x86-64 numbering: 6 rbp, 7 rsp.
    cfa_register: u8,
    cfa_offset: i64,
    return_at: i64,
    /// Where the caller's rbp was saved, from the CFA; null: rbp as it is (not saved here).
    rbp_at: ?i64,
    /// Whether it came from the module's .eh_frame (else the frame pointers' rule).
    cfi: bool,
};

const dwarf_rbp = 6;
const dwarf_rsp = 7;
const dwarf_return = 16;
const frame_pointers: Rule = .{ .cfa_register = dwarf_rbp, .cfa_offset = 16, .return_at = -8, .rbp_at = -16, .cfi = false };

/// A module's .eh_frame, read from its file through the process's root, ready for lookups; null
/// without one.
fn eh_frame_of(arena: std.mem.Allocator, pid: linux.pid_t, path: []const u8) ?std.debug.Dwarf.Unwind {
    var buffer: [512]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&buffer, "/proc/{d}/root{s}", .{ pid, path }, 0) catch return null;
    const opened = linux.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var header: [64]u8 = undefined;
    if (!pread_all(fd, &header, 0) or !std.mem.eql(u8, header[0..4], "\x7fELF")) return null;
    const sections_at = std.mem.readInt(u64, header[40..48], .little);
    const entry_size = std.mem.readInt(u16, header[58..60], .little);
    const count = std.mem.readInt(u16, header[60..62], .little);
    const names_index = std.mem.readInt(u16, header[62..64], .little);
    if (entry_size < 64 or count == 0 or names_index >= count) return null;
    const sections = fd_read(arena, fd, sections_at, @as(u64, entry_size) * count) orelse return null;
    if (sections.len < @as(usize, entry_size) * count) return null;
    const names_header = sections[@as(usize, names_index) * entry_size ..][0..64];
    const names = fd_read(arena, fd, std.mem.readInt(u64, names_header[24..32], .little), std.mem.readInt(u64, names_header[32..40], .little)) orelse return null;
    for (0..count) |index| {
        const section = sections[index * entry_size ..][0..64];
        const name_at = std.mem.readInt(u32, section[0..4], .little);
        if (name_at >= names.len) continue;
        if (!std.mem.eql(u8, std.mem.sliceTo(names[name_at..], 0), ".eh_frame")) continue;
        const address = std.mem.readInt(u64, section[16..24], .little);
        const size = std.mem.readInt(u64, section[32..40], .little);
        const bytes = fd_read(arena, fd, std.mem.readInt(u64, section[24..32], .little), size) orelse return null;
        if (bytes.len != size) return null;
        var unwind: std.debug.Dwarf.Unwind = .initSection(.eh_frame, address, bytes);
        unwind.prepare(arena, 8, .little, true, false) catch return null;
        return unwind;
    }
    return null;
}

/// The rule of `address` (`returned`: a return address, its call's row: the instruction before
/// it) in `unwind`, or null where it has no row for it.
fn rule_in(arena: std.mem.Allocator, unwind: *const std.debug.Dwarf.Unwind, at: u64) ?Rule {
    const fde_offset = (unwind.lookupPc(at, 8, .little) catch return null) orelse return null;
    const cie, const fde = unwind.getFde(fde_offset, .little) catch return null;
    if (at < fde.pc_begin or at >= fde.pc_begin + fde.pc_range) return null;
    var machine: std.debug.Dwarf.Unwind.VirtualMachine = .{};
    const row = machine.runTo(arena, at, cie, &fde, 8, .little) catch return null;
    const cfa = switch (row.cfa) {
        .reg_off => |register_offset| register_offset,
        else => return null, // An expression's CFA (a signal frame's): not followed.
    };
    if (cfa.register != dwarf_rsp and cfa.register != dwarf_rbp) return null;
    var rule: Rule = .{ .cfa_register = cfa.register, .cfa_offset = cfa.offset, .return_at = 0, .rbp_at = null, .cfi = true };
    var return_found = false;
    for (machine.rowColumns(&row)) |column| {
        switch (column.rule) {
            .offset => |offset| {
                if (column.register == dwarf_return) {
                    rule.return_at = offset;
                    return_found = true;
                }
                if (column.register == dwarf_rbp) rule.rbp_at = offset;
            },
            else => {},
        }
    }
    // x86-64's CIEs leave the return address at CFA-8 implicitly in some compilers' output.
    if (!return_found) rule.return_at = -8;
    return rule;
}

/// Each of `addresses`' rules and names in a live process (det-nodes cfi): the first the
/// instruction a stop is at, the rest return addresses (their calls' rows). Null for an address
/// no code mapping of the process holds.
pub const Unwinding = struct { named: Named, rule: ?Rule };

pub fn unwinding(arena: std.mem.Allocator, process: *const Process, addresses: []const u64) ![]const Unwinding {
    const names: Names = .of(arena, process);
    const found = try arena.alloc(Unwinding, addresses.len);
    const tables = try arena.alloc(?std.debug.Dwarf.Unwind, process.modules.len);
    const tables_read = try arena.alloc(bool, process.modules.len);
    @memset(tables_read, false);
    for (addresses, found, 0..) |address, *one, index| {
        const returned = index > 0;
        const mapping = process.code_at(address) orelse {
            one.* = .{ .named = .{ .at = null, .function = null }, .rule = null };
            continue;
        };
        one.named = .{ .at = names.name(address, returned), .function = names.function_of(address, returned) };
        one.rule = frame_pointers;
        const module = process.module_of(mapping.path) orelse continue;
        const module_index = (@intFromPtr(module) - @intFromPtr(process.modules.ptr)) / @sizeOf(Module);
        if (!tables_read[module_index]) {
            tables_read[module_index] = true;
            tables[module_index] = eh_frame_of(arena, process.pid, module.path);
        }
        if (tables[module_index]) |*unwind| {
            if (rule_in(arena, unwind, address - module.bias - @intFromBool(returned))) |rule| one.rule = rule;
        }
    }
    return found;
}

fn walk(arena: std.mem.Allocator, process: *const Process, memory: *const Memory, rip: u64, rsp: u64, rbp: u64) ?Walked {
    const names: Names = .of(arena, process);
    var addresses: [frames_max]u64 = undefined;
    var frames: std.ArrayList(Frame) = .empty;
    addresses[0] = rip;
    frames.append(arena, .{ .address = hex(arena, rip), .at = names.name(rip, false) }) catch return null;
    // Its callers, while the chain of frame pointers holds: each frame above the last, its
    // return address in code.
    var frame = rbp;
    while (frame != 0 and frames.items.len < frames_max) {
        const returned = memory.word(frame +% 8) orelse break;
        const next = memory.word(frame) orelse break;
        if (process.code_at(returned) == null) break;
        addresses[frames.items.len] = returned;
        frames.append(arena, .{ .address = hex(arena, returned), .at = names.name(returned, true) }) catch break;
        if (next <= frame or next - frame > frame_size_max) break;
        frame = next;
    }
    var scanned: std.ArrayList(Frame) = .empty;
    var at: u64 = 0;
    scan: while (at < scan_size and scanned.items.len < scanned_max) : (at += 8) {
        const word = memory.word(rsp +% at) orelse break;
        const mapping = process.code_at(word) orelse continue;
        // A mapping's own start is a pointer to it (the vDSO's, among a process's first words),
        // not a return into it.
        if (word == mapping.start) continue;
        for (addresses[0..frames.items.len]) |known| if (known == word) continue :scan;
        const address = hex(arena, word);
        for (scanned.items) |seen| if (std.mem.eql(u8, seen.address, address)) continue :scan;
        scanned.append(arena, .{ .address = address, .at = names.name(word, true) }) catch break;
    }
    return .{ .frames = frames.items, .scanned = scanned.items };
}

fn hex(arena: std.mem.Allocator, value: u64) []const u8 {
    return std.fmt.allocPrint(arena, "0x{x}", .{value}) catch "";
}

fn pread_all(fd: linux.fd_t, buffer: []u8, offset: u64) bool {
    var done: usize = 0;
    while (done < buffer.len) {
        const read = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(read) != .SUCCESS or read == 0) return false;
        done += read;
    }
    return true;
}

/// Up to `size_max` bytes of `fd` from `offset`.
fn fd_read(arena: std.mem.Allocator, fd: linux.fd_t, offset: u64, size_max: u64) ?[]const u8 {
    const buffer = arena.alloc(u8, @intCast(size_max)) catch return null;
    var done: usize = 0;
    while (done < buffer.len) {
        const read = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        done += read;
    }
    return buffer[0..done];
}

fn file_read(arena: std.mem.Allocator, path: [:0]const u8, size_max: usize) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    // A /proc file has no size to ask for: read until it ends.
    const buffer = arena.alloc(u8, size_max) catch return null;
    var done: usize = 0;
    while (done < buffer.len) {
        const read = linux.read(@intCast(fd), buffer[done..].ptr, buffer.len - done);
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        done += read;
    }
    return buffer[0..done];
}

test "a core's notes: the first thread's registers, the fault's address" {
    // One note of each kind, as the kernel writes them: name "CORE", data padded to 4.
    var status: [prstatus_size]u8 = @splat(0);
    std.mem.writeInt(u64, status[prstatus_registers + register_rip * 8 ..][0..8], 0x401234, .little);
    std.mem.writeInt(u64, status[prstatus_registers + register_rsp * 8 ..][0..8], 0x7ffd0000, .little);
    var bytes: [12 + 8 + prstatus_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 5, .little);
    std.mem.writeInt(u32, bytes[4..8], prstatus_size, .little);
    std.mem.writeInt(u32, bytes[8..12], nt_prstatus, .little);
    @memcpy(bytes[12..20], "CORE\x00\x00\x00\x00");
    @memcpy(bytes[20..], &status);
    var notes: Notes = .{ .bytes = &bytes };
    const note = notes.next().?;
    try std.testing.expectEqual(@as(u32, nt_prstatus), note.kind);
    try std.testing.expectEqualStrings("CORE", note.name);
    try std.testing.expectEqual(@as(u64, 0x401234), std.mem.readInt(u64, note.data[prstatus_registers + register_rip * 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(?Note, null), notes.next());
}

/// A function of the test's own, named by its ELF symbol.
export fn det_where_named_test_function() callconv(.c) u32 {
    return 7;
}

test "named: a function of the process by its ELF symbol, a stack address outside its code" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const process: Process = .read(arena, linux.getpid());
    defer process.release();
    var local: u64 = det_where_named_test_function();
    const addresses = [_]u64{ @intFromPtr(&det_where_named_test_function), @intFromPtr(&local) };
    const found = try named(arena, &process, &addresses, false);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const at = found[0].at orelse return error.TestUnnamed;
    const function = found[0].function orelse return error.TestUnnamed;
    try std.testing.expect(std.mem.startsWith(u8, at, "det_where_named_test_function+0x0 "));
    try std.testing.expectEqualStrings(at, function);
    try std.testing.expectEqual(@as(?[]const u8, null), found[1].at);
    try std.testing.expectEqual(@as(?[]const u8, null), found[1].function);
    local += 1;
}

test "unwinding: a function's entry by its .eh_frame (the CFA rsp+8, the return address below it)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const process: Process = .read(arena, linux.getpid());
    defer process.release();
    const entry = @intFromPtr(&det_where_named_test_function);
    const found = try unwinding(arena, &process, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const rule = found[0].rule orelse return error.TestNoRule;
    try std.testing.expect(rule.cfi);
    try std.testing.expectEqual(@as(u8, dwarf_rsp), rule.cfa_register);
    try std.testing.expectEqual(@as(i64, 8), rule.cfa_offset);
    try std.testing.expectEqual(@as(i64, -8), rule.return_at);
    try std.testing.expect(found[0].named.at != null);
}

test "a line's starts in a table of lines: each run once, its file by its path's end, in the range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "DETLINES", the rows' count, the rows by address {address, line, file}, then the names.
    const names = "/app/core/io/completions.rs\x00/app/core/io/other.rs\x00";
    const other: u32 = 28; // The second name's offset.
    const Row = struct { address: u64, line: u32, file: u32 };
    const rows = [_]Row{
        .{ .address = 0x1000, .line = 385, .file = 0 },
        .{ .address = 0x1004, .line = 386, .file = 0 },
        .{ .address = 0x1010, .line = 389, .file = 0 }, // A run of two rows: one start.
        .{ .address = 0x1014, .line = 389, .file = 0 },
        .{ .address = 0x1020, .line = 387, .file = 0 },
        .{ .address = 0x1030, .line = 389, .file = 0 }, // The line again: a second start.
        .{ .address = 0x1040, .line = 389, .file = other }, // Another file's line 389.
        .{ .address = 0x2000, .line = 389, .file = 0 }, // Beyond the range.
    };
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, "DETLINES");
    try bytes.appendSlice(arena, std.mem.asBytes(&@as(u64, rows.len)));
    for (rows) |row| {
        try bytes.appendSlice(arena, std.mem.asBytes(&row.address));
        try bytes.appendSlice(arena, std.mem.asBytes(&row.line));
        try bytes.appendSlice(arena, std.mem.asBytes(&row.file));
    }
    try bytes.appendSlice(arena, names);
    const table: linux.fd_t = @intCast(linux.memfd_create("lines", 0));
    defer _ = linux.close(table);
    try std.testing.expectEqual(bytes.items.len, linux.write(table, bytes.items.ptr, bytes.items.len));
    const bias = 0x5000;
    const starts = line_starts_in(arena, table, rows.len, "core/io/completions.rs", 389, 0x1000, 0x1100, bias).?;
    try std.testing.expectEqualSlices(u64, &.{ 0x6010, 0x6030 }, starts);
    // Any file: the other file's row goes on the second run.
    const any = line_starts_in(arena, table, rows.len, null, 389, 0x1000, 0x1100, bias).?;
    try std.testing.expectEqualSlices(u64, &.{ 0x6010, 0x6030 }, any);
    const other_file = line_starts_in(arena, table, rows.len, "io/other.rs", 389, 0x1000, 0x1100, bias).?;
    try std.testing.expectEqualSlices(u64, &.{0x6040}, other_file);
    // A range from the middle of the first run: the range's first row on the line is a start.
    const middle = line_starts_in(arena, table, rows.len, "core/io/completions.rs", 389, 0x1014, 0x1100, bias).?;
    try std.testing.expectEqualSlices(u64, &.{ 0x6014, 0x6030 }, middle);
    try std.testing.expectEqual(@as(usize, 0), line_starts_in(arena, table, rows.len, null, 999, 0x1000, 0x1100, bias).?.len);
    try std.testing.expect(path_ends_with("/app/core/io/completions.rs", "core/io/completions.rs"));
    try std.testing.expect(path_ends_with("/app/core/io/completions.rs", "completions.rs"));
    try std.testing.expect(!path_ends_with("/app/core/io/xcompletions.rs", "completions.rs"));
    try std.testing.expect(path_ends_with("completions.rs", "completions.rs"));
}
