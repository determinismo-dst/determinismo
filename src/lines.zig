// SPDX-License-Identifier: MIT
//! Source lines of instrumented native code: C, C++ and Rust built for Antithesis (clang's
//! trace-pc-guard, linked against libvoidstar). An ELF file's DWARF line tables become one table
//! by address, which libvoidstar maps in the node to report each edge as the line it is on
//! (`line <file>:<n>`, as Go's instrumentor's symbol tables give) instead of a number: the line
//! coverage targeted runs (changed.zig) and strategies read. Built when an image is prepared
//! (prepare.zig), for every ELF file under its /symbols (Antithesis's place for symbols), and
//! named by the file's GNU build ID (`name-<file name>` without one), which libvoidstar reads
//! from the loaded module.
//!
//! A table: "DETLINES", the rows' count (u64), the rows sorted by address ({address: u64,
//! line: u32, file: u32}, the file an offset in the strings), then the strings, each ending in a
//! zero byte. Little-endian, as the guest. guest/runtime/voidstar.zig reads it.
//!
//! After the strings, the functions: rows sorted by address ({address: u64, name: u32, 0: u32},
//! the name an offset in the strings, `name_none` where no function is: an address between two
//! rows is in the earlier one's), then the table's last 24 bytes, {where the functions' rows
//! start: u64, their count: u64, "DETFUNCS"}. The innermost function of an address, an inlined
//! one before its caller, as the program's DWARF names it. The Zig SDK names an assertion's site
//! from the table (sdk/zig/determinismo.zig: file, line and function of a return address): a
//! program reads no debug information of its own (a driver is a process: each parsed its DWARF,
//! 88% of a bank timeline's exact stops, 2026-11-17).
const std = @import("std");
const assert = std.debug.assert;

pub const magic = "DETLINES";
pub const functions_magic = "DETFUNCS";
/// Images prepared by an earlier version of this are prepared again (prepare.zig).
pub const format_version = 3;
pub const tables_directory = "symbols/.determinismo";
/// A larger table (a huge C++ server's) is not made: its edges stay numbers.
pub const table_size_max = 1 << 30;

pub const Row = extern struct { address: u64, line: u32, file: u32 };
pub const FunctionRow = extern struct { address: u64, name: u32, reserved: u32 = 0 };
pub const Trailer = extern struct { functions_at: u64, functions_count: u64, magic: [8]u8 };
/// A function row's name where no function is.
pub const name_none = std.math.maxInt(u32);
/// A file with more debug information than this has no functions in its table (a large C++
/// server's: every DIE of it read to find them, for names only the Zig SDK asks for): its
/// lines only.
pub const functions_debug_info_size_max = 64 << 20;

comptime {
    assert(@sizeOf(Row) == 16);
    assert(@sizeOf(FunctionRow) == 16);
    assert(@sizeOf(Trailer) == 24);
}

pub const Table = struct { name: []const u8, bytes: []const u8 };

/// The table of an ELF file with DWARF line information, or null: not ELF, no lines, too large.
pub fn of(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, path: []const u8) !?Table {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var loaded = std.debug.ElfFile.load(gpa, io, file, null, &.none) catch return null;
    defer loaded.deinit(gpa);
    const dwarf = loaded.dwarf orelse return null;
    if (loaded.endian != .little) return null;
    const sections: Sections = .{
        .line = dwarf.section(.debug_line) orelse return null,
        .line_str = dwarf.section(.debug_line_str) orelse "",
        .str = dwarf.section(.debug_str) orelse "",
    };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(gpa);
    var offsets: std.StringHashMapUnmanaged(u32) = .empty;
    var at: usize = 0;
    while (at < sections.line.len) {
        // One unit's line program; one that cannot be read is skipped.
        var reader: Reader = .{ .bytes = sections.line, .at = at };
        const unit = unit_read(arena, &reader, sections) catch break;
        at = unit.end;
        program_run(gpa, &rows, &strings, &offsets, arena, unit, sections.line[unit.program..unit.end]) catch continue;
    }
    if (rows.items.len == 0) return null;
    std.mem.sort(Row, rows.items, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return a.address < b.address;
        }
    }.less);
    // A row only where the line changes: an address between two rows is the earlier one's.
    var kept: usize = 0;
    for (rows.items) |row| {
        if (kept > 0) {
            const last = rows.items[kept - 1];
            if (last.line == row.line and last.file == row.file) continue;
            if (last.address == row.address) {
                // A sequence's end (line 0) gives way to code starting there.
                if (row.line != 0) rows.items[kept - 1] = row;
                continue;
            }
        }
        rows.items[kept] = row;
        kept += 1;
    }
    var functions: std.ArrayList(FunctionRow) = .empty;
    defer functions.deinit(gpa);
    // A file whose functions cannot be read keeps its lines.
    functions_read(gpa, arena, &loaded.dwarf.?, &functions, &strings, &offsets) catch functions.clearRetainingCapacity();
    const rows_start = magic.len + 8;
    const strings_start = rows_start + kept * @sizeOf(Row);
    const functions_start = strings_start + strings.items.len;
    const trailer_start = functions_start + functions.items.len * @sizeOf(FunctionRow);
    const size = trailer_start + @sizeOf(Trailer);
    if (size > table_size_max) return null;
    const bytes = try arena.alloc(u8, size);
    @memcpy(bytes[0..magic.len], magic);
    std.mem.writeInt(u64, bytes[magic.len..][0..8], kept, .little);
    @memcpy(bytes[rows_start..strings_start], std.mem.sliceAsBytes(rows.items[0..kept]));
    @memcpy(bytes[strings_start..functions_start], strings.items);
    @memcpy(bytes[functions_start..trailer_start], std.mem.sliceAsBytes(functions.items));
    const trailer: Trailer = .{ .functions_at = functions_start, .functions_count = functions.items.len, .magic = functions_magic.* };
    @memcpy(bytes[trailer_start..], std.mem.asBytes(&trailer));
    const name = if (build_id(loaded.mapped_file)) |id|
        try std.fmt.allocPrint(arena, "{x}", .{id})
    else
        try std.fmt.allocPrint(arena, "name-{s}", .{std.fs.path.basename(path)});
    return .{ .name = name, .bytes = bytes };
}

const Sections = struct { line: []const u8, line_str: []const u8, str: []const u8 };

/// The functions of a file's DWARF as rows by address: at each address the innermost function
/// there, as std.debug names an address (Dwarf.getSymbolName: the last of its list whose range
/// holds it, an inlined function after its caller).
fn functions_read(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    dwarf: *std.debug.Dwarf,
    functions: *std.ArrayList(FunctionRow),
    strings: *std.ArrayList(u8),
    offsets: *std.StringHashMapUnmanaged(u32),
) !void {
    const info = dwarf.section(.debug_info) orelse return;
    if (info.len > functions_debug_info_size_max) return;
    try dwarf.open(gpa, .little);
    const Edge = struct { address: u64, function: u32, starts: bool };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for (dwarf.func_list.items, 0..) |function, index| {
        const range = function.pc_range orelse continue;
        if (range.start == 0 or range.start >= range.end) continue; // Discarded code.
        try edges.append(gpa, .{ .address = range.start, .function = @intCast(index), .starts = true });
        try edges.append(gpa, .{ .address = range.end, .function = @intCast(index), .starts = false });
    }
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, a: Edge, b: Edge) bool {
            return a.address < b.address;
        }
    }.less);
    // The functions an address is in, the last of the list on top: a heap of their numbers,
    // one that ended left in it until it reaches the top.
    const inside = try gpa.alloc(bool, dwarf.func_list.items.len);
    defer gpa.free(inside);
    @memset(inside, false);
    var heap: std.ArrayList(u32) = .empty;
    defer heap.deinit(gpa);
    var named: u32 = name_none;
    var at: usize = 0;
    while (at < edges.items.len) {
        const address = edges.items[at].address;
        while (at < edges.items.len and edges.items[at].address == address) : (at += 1) {
            const edge = edges.items[at];
            inside[edge.function] = edge.starts;
            if (edge.starts) try heap_push(gpa, &heap, edge.function);
        }
        while (heap.items.len > 0 and !inside[heap.items[0]]) heap_pop(&heap);
        var name: u32 = name_none;
        if (heap.items.len > 0) {
            if (dwarf.func_list.items[heap.items[0]].name) |text| {
                const known = try offsets.getOrPut(arena, text);
                if (!known.found_existing) {
                    known.value_ptr.* = @intCast(strings.items.len);
                    try strings.appendSlice(gpa, text);
                    try strings.append(gpa, 0);
                }
                name = known.value_ptr.*;
            }
        }
        if (name == named and functions.items.len > 0) continue;
        try functions.append(gpa, .{ .address = address, .name = name });
        named = name;
    }
}

fn heap_push(gpa: std.mem.Allocator, heap: *std.ArrayList(u32), value: u32) !void {
    try heap.append(gpa, value);
    var at = heap.items.len - 1;
    while (at > 0) {
        const parent = (at - 1) / 2;
        if (heap.items[parent] >= heap.items[at]) break;
        std.mem.swap(u32, &heap.items[parent], &heap.items[at]);
        at = parent;
    }
}

fn heap_pop(heap: *std.ArrayList(u32)) void {
    assert(heap.items.len > 0);
    heap.items[0] = heap.items[heap.items.len - 1];
    heap.items.len -= 1;
    var at: usize = 0;
    while (true) {
        var largest = at;
        for ([_]usize{ 2 * at + 1, 2 * at + 2 }) |child| {
            if (child < heap.items.len and heap.items[child] > heap.items[largest]) largest = child;
        }
        if (largest == at) break;
        std.mem.swap(u32, &heap.items[largest], &heap.items[at]);
        at = largest;
    }
}

/// A table's parts, for a reader on the host (the SDK and the guest have their own, on a
/// mapped file).
pub const View = struct {
    rows: []align(1) const Row,
    strings: []const u8,
    functions: []align(1) const FunctionRow,

    pub fn of(bytes: []const u8) ?View {
        const head = magic.len + 8;
        if (bytes.len < head + @sizeOf(Trailer) or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
        const count = std.mem.readInt(u64, bytes[magic.len..][0..8], .little);
        if (count > (bytes.len - head) / @sizeOf(Row)) return null;
        const rows_end = head + count * @sizeOf(Row);
        const trailer = std.mem.bytesToValue(Trailer, bytes[bytes.len - @sizeOf(Trailer) ..]);
        if (!std.mem.eql(u8, &trailer.magic, functions_magic)) return null;
        const functions_end = bytes.len - @sizeOf(Trailer);
        if (trailer.functions_at < rows_end or trailer.functions_at > functions_end) return null;
        if (trailer.functions_count != (functions_end - trailer.functions_at) / @sizeOf(FunctionRow)) return null;
        return .{
            .rows = std.mem.bytesAsSlice(Row, bytes[head..rows_end]),
            .strings = bytes[rows_end..trailer.functions_at],
            .functions = std.mem.bytesAsSlice(FunctionRow, bytes[trailer.functions_at..functions_end]),
        };
    }

    /// The line an address is on (the last row at or before it), null past a sequence's end.
    pub fn line(view: View, address: u64) ?struct { file: []const u8, line: u32 } {
        var low: usize = 0;
        var high: usize = view.rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (view.rows[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const found = view.rows[low - 1];
        if (found.line == 0 or found.file >= view.strings.len) return null;
        return .{ .file = std.mem.sliceTo(view.strings[found.file..], 0), .line = found.line };
    }

    /// The function an address is in, null where none is.
    pub fn function(view: View, address: u64) ?[]const u8 {
        var low: usize = 0;
        var high: usize = view.functions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (view.functions[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const found = view.functions[low - 1];
        if (found.name == name_none or found.name >= view.strings.len) return null;
        return std.mem.sliceTo(view.strings[found.name..], 0);
    }
};

/// A unit of .debug_line: its header's facts and its files' paths.
const Unit = struct {
    end: usize,
    program: usize,
    version: u16,
    address_size: u8,
    minimum_length: u8,
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    standard_lengths: []const u8,
    /// Paths by the program's file numbers (from 1 before DWARF 5, from 0 since).
    files: []const []const u8,
};

const Reader = struct {
    bytes: []const u8,
    at: usize,

    fn byte(reader: *Reader) !u8 {
        if (reader.at >= reader.bytes.len) return error.InvalidDebugInfo;
        reader.at += 1;
        return reader.bytes[reader.at - 1];
    }

    fn fixed(reader: *Reader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (reader.at + size > reader.bytes.len) return error.InvalidDebugInfo;
        defer reader.at += size;
        return std.mem.readInt(T, reader.bytes[reader.at..][0..size], .little);
    }

    fn sized(reader: *Reader, size: usize) !u64 {
        return switch (size) {
            1 => try reader.byte(),
            2 => try reader.fixed(u16),
            4 => try reader.fixed(u32),
            8 => try reader.fixed(u64),
            else => error.InvalidDebugInfo,
        };
    }

    fn skip(reader: *Reader, size: usize) !void {
        if (reader.at + size > reader.bytes.len) return error.InvalidDebugInfo;
        reader.at += size;
    }

    fn uleb(reader: *Reader) !u64 {
        var value: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const next = try reader.byte();
            if (shift < 64) value |= @as(u64, next & 0x7f) << @intCast(shift);
            shift += 7;
            if (next & 0x80 == 0) return value;
        }
    }

    fn sleb(reader: *Reader) !i64 {
        var value: i64 = 0;
        var shift: u32 = 0;
        while (true) {
            const next = try reader.byte();
            if (shift < 64) value |= @as(i64, next & 0x7f) << @intCast(shift);
            shift += 7;
            if (next & 0x80 == 0) {
                if (shift < 64 and next & 0x40 != 0) value |= @as(i64, -1) << @intCast(shift);
                return value;
            }
        }
    }

    fn string(reader: *Reader) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, reader.bytes, reader.at, 0) orelse return error.InvalidDebugInfo;
        defer reader.at = end + 1;
        return reader.bytes[reader.at..end];
    }
};

fn string_at(section: []const u8, offset: u64) []const u8 {
    if (offset >= section.len) return "";
    return std.mem.sliceTo(section[@intCast(offset)..], 0);
}

fn unit_read(arena: std.mem.Allocator, reader: *Reader, sections: Sections) !Unit {
    var length: u64 = try reader.fixed(u32);
    var offset_size: usize = 4;
    if (length == 0xffff_ffff) {
        length = try reader.fixed(u64);
        offset_size = 8;
    }
    const end = reader.at + length;
    if (end > reader.bytes.len) return error.InvalidDebugInfo;
    const version = try reader.fixed(u16);
    if (version < 2 or version > 5) {
        reader.at = end;
        return error.InvalidDebugInfo;
    }
    var address_size: u8 = 8;
    if (version >= 5) {
        address_size = try reader.byte();
        _ = try reader.byte(); // Segment selector size.
    }
    const header_length = try reader.sized(offset_size);
    const program: usize = @intCast(reader.at + header_length);
    const minimum_length = try reader.byte();
    if (version >= 4) _ = try reader.byte(); // Operations per instruction (VLIW only).
    const default_is_stmt = try reader.byte() != 0;
    const line_base: i8 = @bitCast(try reader.byte());
    const line_range = try reader.byte();
    const opcode_base = try reader.byte();
    if (line_range == 0 or opcode_base == 0) return error.InvalidDebugInfo;
    const standard_lengths = reader.bytes[reader.at..][0 .. opcode_base - 1];
    try reader.skip(opcode_base - 1);
    var directories: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    if (version >= 5) {
        const directory_entries = try entries_read(arena, reader, sections, offset_size, &.{});
        for (directory_entries) |entry| try directories.append(arena, entry.path);
        // A directory other than the first (the unit's own) is relative to the first.
        for (directories.items[@min(1, directories.items.len)..]) |*directory| {
            if (!std.fs.path.isAbsolute(directory.*) and directories.items[0].len > 0) {
                directory.* = try std.fs.path.join(arena, &.{ directories.items[0], directory.* });
            }
        }
        const file_entries = try entries_read(arena, reader, sections, offset_size, directories.items);
        for (file_entries) |entry| try files.append(arena, entry.path);
    } else {
        try directories.append(arena, ""); // The unit's own directory: in .debug_info.
        while (true) {
            const directory = try reader.string();
            if (directory.len == 0) break;
            try directories.append(arena, directory);
        }
        try files.append(arena, ""); // Files are numbered from 1.
        while (true) {
            const name = try reader.string();
            if (name.len == 0) break;
            const directory_index = try reader.uleb();
            _ = try reader.uleb(); // Modification time.
            _ = try reader.uleb(); // Size.
            try files.append(arena, try path_of(arena, directories.items, directory_index, name));
        }
    }
    return .{
        .end = end,
        .program = program,
        .version = version,
        .address_size = address_size,
        .minimum_length = minimum_length,
        .default_is_stmt = default_is_stmt,
        .line_base = line_base,
        .line_range = line_range,
        .opcode_base = opcode_base,
        .standard_lengths = standard_lengths,
        .files = files.items,
    };
}

fn path_of(arena: std.mem.Allocator, directories: []const []const u8, index: u64, name: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name) or index >= directories.len) return name;
    const directory = directories[@intCast(index)];
    if (directory.len == 0) return name;
    return std.fs.path.join(arena, &.{ directory, name });
}

const Entry = struct { path: []const u8 };

/// DWARF 5's directory or file entries: their formats, then the entries (paths joined with
/// their directories when `directories` is given).
fn entries_read(
    arena: std.mem.Allocator,
    reader: *Reader,
    sections: Sections,
    offset_size: usize,
    directories: []const []const u8,
) ![]Entry {
    const format_count = try reader.byte();
    var kinds: [16]u64 = undefined;
    var forms: [16]u64 = undefined;
    if (format_count > kinds.len) return error.InvalidDebugInfo;
    for (0..format_count) |index| {
        kinds[index] = try reader.uleb();
        forms[index] = try reader.uleb();
    }
    const count = try reader.uleb();
    if (count > reader.bytes.len) return error.InvalidDebugInfo;
    const found = try arena.alloc(Entry, @intCast(count));
    for (found) |*entry| {
        var name: []const u8 = "";
        var directory_index: u64 = 0;
        for (kinds[0..format_count], forms[0..format_count]) |kind, form| {
            const value = try form_read(reader, sections, offset_size, form);
            switch (kind) {
                std.dwarf.LNCT.path => name = value.text,
                std.dwarf.LNCT.directory_index => directory_index = value.number,
                else => {},
            }
        }
        entry.path = if (directories.len == 0) name else try path_of(arena, directories, directory_index, name);
    }
    return found;
}

const Value = struct { text: []const u8 = "", number: u64 = 0 };

fn form_read(reader: *Reader, sections: Sections, offset_size: usize, form: u64) !Value {
    const FORM = std.dwarf.FORM;
    return switch (form) {
        FORM.string => .{ .text = try reader.string() },
        FORM.line_strp => .{ .text = string_at(sections.line_str, try reader.sized(offset_size)) },
        FORM.strp => .{ .text = string_at(sections.str, try reader.sized(offset_size)) },
        FORM.udata => .{ .number = try reader.uleb() },
        FORM.data1 => .{ .number = try reader.byte() },
        FORM.data2 => .{ .number = try reader.fixed(u16) },
        FORM.data4 => .{ .number = try reader.fixed(u32) },
        FORM.data8 => .{ .number = try reader.fixed(u64) },
        FORM.data16 => blk: {
            try reader.skip(16);
            break :blk .{};
        },
        FORM.block => blk: {
            try reader.skip(@intCast(try reader.uleb()));
            break :blk .{};
        },
        // Indexed strings need the unit's .debug_info: such a path stays empty.
        FORM.strx1 => blk: {
            try reader.skip(1);
            break :blk .{};
        },
        FORM.strx2 => blk: {
            try reader.skip(2);
            break :blk .{};
        },
        FORM.strx3 => blk: {
            try reader.skip(3);
            break :blk .{};
        },
        FORM.strx4 => blk: {
            try reader.skip(4);
            break :blk .{};
        },
        FORM.strx => blk: {
            _ = try reader.uleb();
            break :blk .{};
        },
        else => error.InvalidDebugInfo,
    };
}

/// Runs a unit's line program: a row for each line, and a line-0 row at each sequence's end
/// (an address past it is no line).
fn program_run(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    strings: *std.ArrayList(u8),
    offsets: *std.StringHashMapUnmanaged(u32),
    arena: std.mem.Allocator,
    unit: Unit,
    program: []const u8,
) !void {
    const named = try arena.alloc(u32, unit.files.len);
    @memset(named, std.math.maxInt(u32));
    var reader: Reader = .{ .bytes = program, .at = 0 };
    var address: u64 = 0;
    var file: u64 = 1;
    var line: i64 = 1;
    const State = struct {
        fn emit(
            g: std.mem.Allocator,
            r: *std.ArrayList(Row),
            s: *std.ArrayList(u8),
            o: *std.StringHashMapUnmanaged(u32),
            a: std.mem.Allocator,
            u: Unit,
            n: []u32,
            at_address: u64,
            at_file: u64,
            at_line: i64,
        ) !void {
            if (at_address == 0 or at_address == std.math.maxInt(u64)) return; // Discarded code.
            if (at_file >= u.files.len or at_line < 0) return;
            const index: usize = @intCast(at_file);
            if (n[index] == std.math.maxInt(u32)) {
                const path = u.files[index];
                if (path.len == 0) return;
                const known = try o.getOrPut(a, path);
                if (!known.found_existing) {
                    known.value_ptr.* = @intCast(s.items.len);
                    try s.appendSlice(g, path);
                    try s.append(g, 0);
                }
                n[index] = known.value_ptr.*;
            }
            try r.append(g, .{ .address = at_address, .line = @intCast(@min(at_line, std.math.maxInt(u32))), .file = n[index] });
        }
    };
    while (reader.at < program.len) {
        const opcode = try reader.byte();
        if (opcode >= unit.opcode_base) {
            const adjusted = opcode - unit.opcode_base;
            address +%= @as(u64, adjusted / unit.line_range) * unit.minimum_length;
            line += unit.line_base + @as(i64, adjusted % unit.line_range);
            try State.emit(gpa, rows, strings, offsets, arena, unit, named, address, file, line);
            continue;
        }
        switch (opcode) {
            0 => { // Extended.
                const size = try reader.uleb();
                if (size == 0) continue;
                const start = reader.at;
                const sub = try reader.byte();
                switch (sub) {
                    std.dwarf.LNE.end_sequence => {
                        if (address != 0 and file < unit.files.len and named[@intCast(file)] != std.math.maxInt(u32)) {
                            try rows.append(gpa, .{ .address = address, .line = 0, .file = named[@intCast(file)] });
                        }
                        address = 0;
                        file = 1;
                        line = 1;
                    },
                    std.dwarf.LNE.set_address => address = try reader.sized(@intCast(size - 1)),
                    else => {},
                }
                reader.at = start + @as(usize, @intCast(size));
            },
            std.dwarf.LNS.copy => try State.emit(gpa, rows, strings, offsets, arena, unit, named, address, file, line),
            std.dwarf.LNS.advance_pc => address +%= try reader.uleb() * unit.minimum_length,
            std.dwarf.LNS.advance_line => line += try reader.sleb(),
            std.dwarf.LNS.set_file => file = try reader.uleb(),
            std.dwarf.LNS.const_add_pc => address +%= @as(u64, (255 - unit.opcode_base) / unit.line_range) * unit.minimum_length,
            std.dwarf.LNS.fixed_advance_pc => address +%= try reader.fixed(u16),
            else => for (0..unit.standard_lengths[opcode - 1]) |_| {
                _ = try reader.uleb(); // An opcode's operands, known by count only.
            },
        }
    }
}

/// The GNU build ID of a 64-bit little-endian ELF file: its NT_GNU_BUILD_ID note's bytes.
pub fn build_id(bytes: []const u8) ?[]const u8 {
    if (bytes.len < @sizeOf(std.elf.Elf64_Ehdr)) return null;
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return null;
    if (bytes[std.elf.EI.CLASS] != std.elf.ELFCLASS64 or bytes[std.elf.EI.DATA] != std.elf.ELFDATA2LSB) return null;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, bytes[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    const entry_size = @sizeOf(std.elf.Elf64_Shdr);
    for (0..header.e_shnum) |index| {
        const at = header.e_shoff + index * entry_size;
        if (at + entry_size > bytes.len) return null;
        const section = std.mem.bytesToValue(std.elf.Elf64_Shdr, bytes[at..][0..entry_size]);
        if (section.sh_type != std.elf.SHT_NOTE) continue;
        if (section.sh_offset + section.sh_size > bytes.len) continue;
        if (note_build_id(bytes[section.sh_offset..][0..section.sh_size])) |id| return id;
    }
    return null;
}

/// NT_GNU_BUILD_ID's bytes among a note section's notes.
pub fn note_build_id(notes: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + 12 <= notes.len) {
        const name_size = std.mem.readInt(u32, notes[at..][0..4], .little);
        const description_size = std.mem.readInt(u32, notes[at + 4 ..][0..4], .little);
        const kind = std.mem.readInt(u32, notes[at + 8 ..][0..4], .little);
        const name_start = at + 12;
        const description_start = name_start + std.mem.alignForward(usize, name_size, 4);
        const end = description_start + std.mem.alignForward(usize, description_size, 4);
        if (description_start + description_size > notes.len) return null;
        const name = notes[name_start..][0..name_size];
        if (kind == std.elf.NT_GNU_BUILD_ID and std.mem.eql(u8, name, "GNU\x00")) {
            return notes[description_start..][0..description_size];
        }
        at = end;
    }
    return null;
}

test "the test program's own lines, by address" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const table = (try of(std.testing.allocator, state.allocator(), std.testing.io, "/proc/self/exe")).?;
    try std.testing.expectEqualStrings(magic, table.bytes[0..magic.len]);
    const count = std.mem.readInt(u64, table.bytes[magic.len..][0..8], .little);
    try std.testing.expect(count > 1000);
    const rows_end = magic.len + 8 + count * @sizeOf(Row);
    try std.testing.expect(std.mem.indexOf(u8, table.bytes[rows_end..], "lines.zig\x00") != null);
    var previous: u64 = 0;
    for (0..count) |index| {
        const row = std.mem.bytesToValue(Row, table.bytes[magic.len + 8 + index * @sizeOf(Row) ..][0..@sizeOf(Row)]);
        try std.testing.expect(row.address > previous);
        previous = row.address;
    }
}

test "the test program's own functions: an address's line and function as std.debug names them" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const table = (try of(std.testing.allocator, arena, std.testing.io, "/proc/self/exe")).?;
    const view = View.of(table.bytes).?;
    try std.testing.expect(view.functions.len > 100);
    var previous: u64 = 0;
    for (view.functions) |row| {
        try std.testing.expect(row.address > previous);
        previous = row.address;
    }
    // Here, as the SDK asks: a return address, less one (the call), less where the program is
    // loaded.
    const here = return_address();
    var offset: usize = 0;
    // (An error set of its own: with libc linked, as here, std's needs one that is not empty.)
    const Never = error{Never};
    std.posix.dl_iterate_phdr(&offset, Never, struct {
        fn first(info: *std.posix.dl_phdr_info, _: usize, found: *usize) Never!void {
            if (found.* == 0) found.* = info.addr; // The program comes first.
        }
    }.first) catch {};
    const address = here - offset - 1;
    const place = view.line(address).?;
    try std.testing.expect(std.mem.endsWith(u8, place.file, "lines.zig"));
    // What std.debug says of the same address.
    const info = try std.debug.getSelfDebugInfo();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try info.getSymbols(std.testing.io, arena, arena, here - 1, false, &symbols);
    try std.testing.expect(symbols.items.len > 0);
    try std.testing.expectEqualStrings(symbols.items[0].name.?, view.function(address).?);
    try std.testing.expectEqual(symbols.items[0].source_location.?.line, place.line);
}

/// An address in its caller: where the call returns to.
noinline fn return_address() usize {
    return @returnAddress();
}

test note_build_id {
    const notes = "\x04\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00GNU\x00\xab\xcd\xef\x00";
    try std.testing.expectEqualSlices(u8, "\xab\xcd\xef", note_build_id(notes).?);
    try std.testing.expectEqual(@as(?[]const u8, null), note_build_id("\x04\x00\x00\x00"));
}
