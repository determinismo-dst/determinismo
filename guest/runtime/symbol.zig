// SPDX-License-Identifier: MIT
//! Where a named variable (or function) of a running process is: `det-nodes symbol`, for a
//! session's watch on a node's variable by its name (docs/DEBUGGING.md, det:watch). The modules
//! the process maps (its own program first, then its libraries, in /proc/<pid>/maps's order),
//! each one's ELF symbol table (.symtab, else .dynsym) searched for the name; the address the
//! process sees it at (the module's link-time value plus where a position-independent module was
//! loaded), its size, and the guest physical address of its first byte now (/proc/<pid>/pagemap:
//! none until the process first touched its page, as a .bss variable's before its first write).
//! A thread-local variable has no one address: refused. Read from the guest's own root (a node's
//! files through /proc/<pid>/root), raw system calls, sizes bounded.
const std = @import("std");
const linux = std.os.linux;
const dwarf_types = @import("dwarf_types.zig");
const assert = std.debug.assert;

const sht_symtab = 2;
const sht_dynsym = 11;
const stt_object = 1;
const stt_func = 2;
const stt_tls = 6;
const stt_gnu_ifunc = 10;
const et_dyn = 3;
const pt_load = 1;
const section_header_size = 64;
const program_header_size = 56;
const symbol_size = 24;
const sections_max = 4096;
const programs_max = 256;
/// The largest symbol table or string table read (a huge C++ server's with debug info is
/// hundreds of MB: such a table is not searched, as elfsyms.zig does).
const table_size_max = 64 << 20;
const maps_size_max = 4 << 20;
const modules_max = 512;
const page_size = 4096;

pub const Kind = enum { object, function, other };

pub const Found = struct {
    pid: linux.pid_t,
    /// The module's path as the process maps it.
    module: []const u8,
    address: u64,
    size: u64,
    kind: Kind,
    /// Where its first byte is in guest memory now; null when its page is not there yet.
    physical: ?u64,
    /// Its type from the module's DWARF (a field's, with a field asked for); null without it.
    type: ?Type = null,
    /// The field asked for (`stats.accepted`): `address` and `size` are its own.
    field: ?[]const u8 = null,
    /// A page of the process's own (its main stack's top, always there and never shared): its
    /// address and physical address, so that a stop in any address space can be told the
    /// process's (the address translated there lands on that page) or not. A function's
    /// code and a library's pages are shared by every process mapping them: no test of theirs.
    probe: ?Probe,
};

pub const Probe = struct { address: u64, physical: u64 };

pub const Type = struct { kind: dwarf_types.Kind, size: u64, name: []const u8 };

pub const Error = error{
    ThreadLocal,
    OutOfMemory,
    /// A field asked for of a module without DWARF (stripped), or whose DWARF does not
    /// describe the variable.
    NoType,
    NoSuchField,
    NotAnAggregate,
    NotAnArray,
    IndexOutOfRange,
    BadPath,
};

/// `name` in process `pid`'s modules, or null when none of them defines it; with `field` (a path:
/// `stats.accepted`, `table[2].key`), that field of it, by the module's DWARF.
pub fn find(arena: std.mem.Allocator, pid: linux.pid_t, name: []const u8, field: ?[]const u8) Error!?Found {
    assert(name.len > 0);
    var path_buffer: [64]u8 = undefined;
    const maps_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/maps", .{pid}, 0) catch unreachable;
    const maps = file_read(arena, maps_path, maps_size_max) orelse return null;
    const modules = try modules_of(arena, maps);
    for (modules) |module| {
        const root_path = std.fmt.allocPrintSentinel(arena, "/proc/{d}/root{s}", .{ pid, module.path }, 0) catch return error.OutOfMemory;
        const fd_or_error = linux.open(root_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd_or_error) != .SUCCESS) continue;
        const fd: linux.fd_t = @intCast(fd_or_error);
        defer _ = linux.close(fd);
        const symbol = try symbol_find(arena, fd, name) orelse continue;
        if (symbol.kind_raw == stt_tls) return error.ThreadLocal;
        const bias: u64 = if (symbol.position_independent) bias: {
            const loaded = module.loaded orelse continue;
            if (loaded < symbol.first_load) continue;
            break :bias loaded - symbol.first_load;
        } else 0;
        // Its type, and a field's place, when the module has DWARF that describes it.
        const sections = dwarf_types.sections_of(arena, fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        const typed: ?dwarf_types.Field = if (sections) |known| dwarf_types.resolve(arena, known, name, field orelse "") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidDebugInfo => null,
            error.NoSuchField, error.NotAnAggregate, error.NotAnArray, error.IndexOutOfRange, error.BadPath => |asked| if (field != null) return asked else null,
        } else null;
        if (field != null and typed == null) return error.NoType;
        const address = symbol.value +% bias +% if (field != null) typed.?.offset else 0;
        return .{
            .pid = pid,
            .module = module.path,
            .address = address,
            .size = if (field != null) typed.?.size else symbol.size,
            .type = if (typed) |t| .{ .kind = t.kind, .size = t.size, .name = t.name } else null,
            .field = field,
            .kind = switch (symbol.kind_raw) {
                stt_object => .object,
                stt_func, stt_gnu_ifunc => .function,
                else => .other,
            },
            .physical = physical_of(pid, address),
            .probe = probe_of(pid, maps),
        };
    }
    return null;
}

/// The last page of the process's [stack] mapping, where its arguments and environment are.
fn probe_of(pid: linux.pid_t, maps: []const u8) ?Probe {
    var lines = std.mem.tokenizeScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), "[stack]")) continue;
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse return null;
        const space = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse return null;
        const end = std.fmt.parseInt(u64, line[dash + 1 .. space], 16) catch return null;
        if (end < page_size) return null;
        const address = end - page_size;
        return .{ .address = address, .physical = physical_of(pid, address) orelse return null };
    }
    return null;
}

const Module = struct {
    path: []const u8,
    /// Where its mapping from file offset 0 starts (its first loadable segment's page).
    loaded: ?u64,
};

/// The files a process maps, in /proc/<pid>/maps's order (its program's own first), each once.
fn modules_of(arena: std.mem.Allocator, maps: []const u8) Error![]const Module {
    var modules: std.ArrayList(Module) = .empty;
    var lines = std.mem.tokenizeScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        // "start-end perms offset dev inode   path"
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        _ = fields.next() orelse continue; // perms
        const offset_text = fields.next() orelse continue;
        _ = fields.next() orelse continue; // dev
        _ = fields.next() orelse continue; // inode
        const path = std.mem.trim(u8, fields.rest(), " ");
        if (path.len == 0 or path[0] != '/') continue; // Anonymous, [heap], [stack], [vdso].
        if (std.mem.endsWith(u8, path, " (deleted)")) continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue;
        const offset = std.fmt.parseInt(u64, offset_text, 16) catch continue;
        const known = for (modules.items) |*module| {
            if (std.mem.eql(u8, module.path, path)) break module;
        } else null;
        if (known) |module| {
            if (offset == 0 and (module.loaded == null or start < module.loaded.?)) module.loaded = start;
            continue;
        }
        if (modules.items.len == modules_max) break;
        try modules.append(arena, .{ .path = path, .loaded = if (offset == 0) start else null });
    }
    return modules.items;
}

test modules_of {
    const maps =
        \\555555554000-555555556000 r--p 00000000 00:1f 12 /usr/bin/node
        \\555555556000-555555558000 r-xp 00002000 00:1f 12 /usr/bin/node
        \\555555559000-55555557a000 rw-p 00000000 00:00 0  [heap]
        \\7ffff7d80000-7ffff7da8000 r--p 00000000 00:1f 34 /usr/lib/libc.so.6
        \\7ffff7fc1000-7ffff7fc5000 r--p 00000000 00:00 0  [vvar]
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const modules = try modules_of(arena_state.allocator(), maps);
    try std.testing.expectEqual(@as(usize, 2), modules.len);
    try std.testing.expectEqualStrings("/usr/bin/node", modules[0].path);
    try std.testing.expectEqual(@as(?u64, 0x555555554000), modules[0].loaded);
    try std.testing.expectEqualStrings("/usr/lib/libc.so.6", modules[1].path);
}

const Symbol = struct {
    value: u64,
    size: u64,
    kind_raw: u8,
    position_independent: bool,
    /// The first loadable segment's page (its link-time address): a position-independent
    /// module's addresses are its value plus where that page was mapped, less this.
    first_load: u64,
};

/// `name` defined in the ELF file `fd` (its .symtab, else its .dynsym), or null.
fn symbol_find(arena: std.mem.Allocator, fd: linux.fd_t, name: []const u8) Error!?Symbol {
    var header: [64]u8 = undefined;
    if (!pread_all(fd, &header, 0)) return null;
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1) return null;
    const kind = std.mem.readInt(u16, header[16..18], .little);
    const programs_at = std.mem.readInt(u64, header[32..40], .little);
    const sections_at = std.mem.readInt(u64, header[40..48], .little);
    const program_entry = std.mem.readInt(u16, header[54..56], .little);
    const program_count = std.mem.readInt(u16, header[56..58], .little);
    const section_entry = std.mem.readInt(u16, header[58..60], .little);
    const section_count = std.mem.readInt(u16, header[60..62], .little);
    if (section_entry < section_header_size or section_count == 0 or section_count > sections_max) return null;
    if (program_entry < program_header_size or program_count > programs_max) return null;
    // The first loadable segment's page.
    var first_load: ?u64 = null;
    const programs = try arena.alloc(u8, @as(usize, program_count) * program_entry);
    if (!pread_all(fd, programs, programs_at)) return null;
    for (0..program_count) |index| {
        const entry = programs[index * program_entry ..][0..program_header_size];
        if (std.mem.readInt(u32, entry[0..4], .little) != pt_load) continue;
        const address = std.mem.readInt(u64, entry[16..24], .little) / page_size * page_size;
        if (first_load == null or address < first_load.?) first_load = address;
    }
    const sections = try arena.alloc(u8, @as(usize, section_count) * section_entry);
    if (!pread_all(fd, sections, sections_at)) return null;
    // Both tables, the full one first: a stripped module keeps its exported names only.
    for ([_]u32{ sht_symtab, sht_dynsym }) |wanted| {
        for (0..section_count) |index| {
            const entry = sections[index * section_entry ..][0..section_header_size];
            if (std.mem.readInt(u32, entry[4..8], .little) != wanted) continue;
            const offset = std.mem.readInt(u64, entry[24..32], .little);
            const size = std.mem.readInt(u64, entry[32..40], .little);
            const link = std.mem.readInt(u32, entry[40..44], .little);
            if (link >= section_count or size > table_size_max or size % symbol_size != 0) continue;
            const names_entry = sections[link * section_entry ..][0..section_header_size];
            const names_offset = std.mem.readInt(u64, names_entry[24..32], .little);
            const names_size = std.mem.readInt(u64, names_entry[32..40], .little);
            if (names_size > table_size_max) continue;
            const symbols = try arena.alloc(u8, @intCast(size));
            const strings = try arena.alloc(u8, @intCast(names_size));
            if (!pread_all(fd, symbols, offset) or !pread_all(fd, strings, names_offset)) continue;
            var at: usize = 0;
            while (at < symbols.len) : (at += symbol_size) {
                const symbol = symbols[at..][0..symbol_size];
                const name_at = std.mem.readInt(u32, symbol[0..4], .little);
                const defined_in = std.mem.readInt(u16, symbol[6..8], .little);
                if (defined_in == 0 or name_at >= strings.len) continue; // Undefined: another module's.
                if (!std.mem.eql(u8, std.mem.sliceTo(strings[name_at..], 0), name)) continue;
                return .{
                    .value = std.mem.readInt(u64, symbol[8..16], .little),
                    .size = std.mem.readInt(u64, symbol[16..24], .little),
                    .kind_raw = symbol[4] & 0xf,
                    .position_independent = kind == et_dyn,
                    .first_load = first_load orelse 0,
                };
            }
        }
    }
    return null;
}

/// The guest physical address of `address` in process `pid` now: its page's frame from
/// /proc/<pid>/pagemap (present, and a frame number the reader may see: root's), else null.
fn physical_of(pid: linux.pid_t, address: u64) ?u64 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/pagemap", .{pid}, 0) catch unreachable;
    const fd_or_error = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd_or_error) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(fd_or_error);
    defer _ = linux.close(fd);
    var entry_bytes: [8]u8 = undefined;
    if (!pread_all(fd, &entry_bytes, address / page_size * 8)) return null;
    const entry = std.mem.readInt(u64, &entry_bytes, .little);
    const present = entry >> 63 & 1 == 1;
    const frame = entry & ((@as(u64, 1) << 55) - 1);
    if (!present or frame == 0) return null; // Not there yet, or a reader without the frames.
    return frame * page_size + address % page_size;
}

fn file_read(arena: std.mem.Allocator, path: [:0]const u8, size_max: usize) ?[]const u8 {
    const fd_or_error = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd_or_error) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(fd_or_error);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buffer: [16 * 1024]u8 = undefined;
    while (out.items.len < size_max) {
        const count = linux.read(fd, &buffer, buffer.len);
        if (linux.errno(count) != .SUCCESS) return null;
        if (count == 0) break;
        out.appendSlice(arena, buffer[0..count]) catch return null;
    }
    return out.items;
}

fn pread_all(fd: linux.fd_t, buffer: []u8, offset: u64) bool {
    var done: usize = 0;
    while (done < buffer.len) {
        const count = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(count) != .SUCCESS or count == 0) return false;
        done += count;
    }
    return true;
}

/// A JSON line for `det-nodes symbol`: {"pid","module","address","size","kind","physical",
/// "probe":{"address","physical"}}.
pub fn print(writer: *std.Io.Writer, found: Found) !void {
    try writer.print("{{\"pid\":{d},\"module\":", .{found.pid});
    try std.json.Stringify.value(found.module, .{}, writer);
    try writer.print(",\"address\":\"0x{x}\",\"size\":{d},\"kind\":\"{s}\",\"physical\":", .{ found.address, found.size, @tagName(found.kind) });
    if (found.physical) |physical| try writer.print("\"0x{x}\"", .{physical}) else try writer.writeAll("null");
    try writer.writeAll(",\"type\":");
    if (found.type) |t| {
        try writer.print("{{\"kind\":\"{s}\",\"size\":{d},\"name\":", .{ @tagName(t.kind), t.size });
        try std.json.Stringify.value(t.name, .{}, writer);
        try writer.writeAll("}");
    } else try writer.writeAll("null");
    try writer.writeAll(",\"field\":");
    if (found.field) |path| try std.json.Stringify.value(path, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"probe\":");
    if (found.probe) |probe| {
        try writer.print("{{\"address\":\"0x{x}\",\"physical\":\"0x{x}\"}}", .{ probe.address, probe.physical });
    } else try writer.writeAll("null");
    try writer.writeAll("}\n");
}

export var det_symbol_test_value: u64 = 0x5eed;

test "a variable of this process, found by its name where the process sees it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const self = linux.getpid();
    const found = (try find(arena, self, "det_symbol_test_value", null)).?;
    try std.testing.expectEqual(@intFromPtr(&det_symbol_test_value), found.address);
    try std.testing.expectEqual(@as(u64, 8), found.size);
    try std.testing.expectEqual(Kind.object, found.kind);
    try std.testing.expectEqual(@as(?Found, null), try find(arena, self, "det_symbol_no_such_name", null));
    // Its type from the test binary's DWARF.
    try std.testing.expectEqual(dwarf_types.Kind.unsigned, found.type.?.kind);
    try std.testing.expectEqual(@as(u64, 8), found.type.?.size);
    // Its page is there (it was read above); its frame only a privileged reader sees.
    if (linux.geteuid() == 0) try std.testing.expect(found.physical != null and found.probe != null);
}
