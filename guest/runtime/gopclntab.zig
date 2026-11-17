// SPDX-License-Identifier: MIT
//! A Go program's own table of functions and lines (its ELF file's .gopclntab, which `-s -w`
//! leaves: a release binary's frames named without DWARF, as Go's own tracebacks are): the
//! function an address is in, and its file and line there. Go 1.16's layout and 1.18's (1.20's
//! adds a field after the ones read). Read through `Source.read` at the file offsets asked (a
//! large server's table is tens of MB: only what one lookup needs is read).
const std = @import("std");
const assert = std.debug.assert;

pub const Source = struct {
    context: *const anyopaque,
    /// Fills `buffer` from the file at `offset`; false when it cannot.
    read: *const fn (context: *const anyopaque, buffer: []u8, offset: u64) bool,

    fn bytes(source: Source, buffer: []u8, offset: u64) ?[]u8 {
        return if (source.read(source.context, buffer, offset)) buffer else null;
    }

    fn int(source: Source, comptime T: type, offset: u64) ?T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        _ = source.bytes(&buffer, offset) orelse return null;
        return std.mem.readInt(T, &buffer, .little);
    }
};

const Version = enum { go116, go118 };

pub const Table = struct {
    source: Source,
    /// The section's file offset: every offset below is from it.
    at: u64,
    version: Version,
    quantum: u8,
    functions: u64,
    /// Go 1.18's functions are offsets from it.
    text_start: u64,
    names: u64,
    units: u64,
    files: u64,
    values: u64,
    /// The function table, and the functions' records its entries point into.
    functab: u64,

    /// The table of the section at `at` (its file offset), or null: not a layout known here.
    /// `text`: the ELF file's .text address, where Go 1.22 and later start their functions (their
    /// header's start is 0: the runtime takes its module's text).
    pub fn of(source: Source, at: u64, text: u64) ?Table {
        var header: [8 + 8 * 8]u8 = undefined;
        _ = source.bytes(&header, at) orelse return null;
        const magic = std.mem.readInt(u32, header[0..4], .little);
        const version: Version = switch (magic) {
            0xfffffffa => .go116,
            0xfffffff0, 0xfffffff1 => .go118,
            else => return null,
        };
        if (header[7] != 8) return null; // 64-bit only, as the guest.
        const word = struct {
            fn read(h: []const u8, index: usize) u64 {
                return std.mem.readInt(u64, h[8 + index * 8 ..][0..8], .little);
            }
        }.read;
        // Go 1.18 put the text's start after the files' count.
        const shift: usize = if (version == .go118) 1 else 0;
        return .{
            .source = source,
            .at = at,
            .version = version,
            .quantum = header[6],
            .functions = word(&header, 0),
            .text_start = if (version == .go118) (if (word(&header, 2) != 0) word(&header, 2) else text) else 0,
            .names = word(&header, 2 + shift),
            .units = word(&header, 3 + shift),
            .files = word(&header, 4 + shift),
            .values = word(&header, 5 + shift),
            .functab = word(&header, 6 + shift),
        };
    }

    /// One function table entry: its function's first address and its record's offset.
    fn entry(table: *const Table, index: u64) ?struct { pc: u64, record: u64 } {
        const base = table.at + table.functab;
        return switch (table.version) {
            .go116 => .{
                .pc = table.source.int(u64, base + index * 16) orelse return null,
                .record = table.source.int(u64, base + index * 16 + 8) orelse return null,
            },
            .go118 => .{
                .pc = table.text_start + (table.source.int(u32, base + index * 8) orelse return null),
                .record = table.source.int(u32, base + index * 8 + 4) orelse return null,
            },
        };
    }

    pub const Found = struct { function: []const u8, file: []const u8, line: i64 };

    /// The function `pc` (a link-time address) is in, and its file and line there; the strings
    /// in `arena`.
    pub fn find(table: *const Table, arena: std.mem.Allocator, pc: u64) ?Found {
        if (table.functions == 0) return null;
        // The last entry is the text's end.
        const first = table.entry(0) orelse return null;
        const end = table.entry(table.functions) orelse return null;
        if (pc < first.pc or pc >= end.pc) return null;
        var low: u64 = 0;
        var high: u64 = table.functions;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            const at = table.entry(middle) orelse return null;
            if (at.pc <= pc) low = middle else high = middle;
        }
        const function = table.entry(low) orelse return null;
        // The function's record (runtime._func): where its fields are differs by version.
        const record = table.at + table.functab + function.record;
        const fields: struct { name: u64, file: u64, line: u64, unit: u64 } = switch (table.version) {
            .go116 => .{ .name = 8, .file = 24, .line = 28, .unit = 36 },
            .go118 => .{ .name = 4, .file = 20, .line = 24, .unit = 32 },
        };
        const name_offset = table.source.int(i32, record + fields.name) orelse return null;
        const file_values = table.source.int(u32, record + fields.file) orelse return null;
        const line_values = table.source.int(u32, record + fields.line) orelse return null;
        const unit = table.source.int(u32, record + fields.unit) orelse return null;
        if (name_offset < 0) return null;
        const function_name = table.string(arena, table.names + @as(u64, @intCast(name_offset))) orelse return null;
        const line = table.value(line_values, function.pc, pc);
        const file_index = table.value(file_values, function.pc, pc);
        const file: []const u8 = if (file_index) |index| named: {
            if (index < 0) break :named "";
            const file_at = table.source.int(u32, table.at + table.units + (@as(u64, unit) + @as(u64, @intCast(index))) * 4) orelse break :named "";
            break :named table.string(arena, table.files + file_at) orelse "";
        } else "";
        return .{ .function = function_name, .file = file, .line = line orelse 0 };
    }

    /// A table of values by address (runtime.pcvalue): from the function's entry, pairs of a
    /// zigzag value delta and an address delta in instruction quanta, each a varint; the value
    /// where `pc` falls.
    fn value(table: *const Table, offset: u32, entry_pc: u64, pc: u64) ?i64 {
        if (offset == 0) return null;
        var reader: Varints = .{ .table = table, .at = table.at + table.values + offset };
        var current: i64 = -1;
        var at_pc = entry_pc;
        var first = true;
        for (0..values_max) |_| {
            const delta = reader.next() orelse return null;
            if (delta == 0 and !first) return null;
            first = false;
            const step: i64 = if (delta & 1 != 0) ~@as(i64, @intCast(delta >> 1)) else @intCast(delta >> 1);
            current +%= step;
            at_pc += (reader.next() orelse return null) * table.quantum;
            if (pc < at_pc) return current;
        }
        return null;
    }

    fn string(table: *const Table, arena: std.mem.Allocator, offset: u64) ?[]const u8 {
        var buffer: [string_size_max]u8 = undefined;
        // A string near the file's end is read in what fits.
        var size: usize = buffer.len;
        while (size >= 16) : (size /= 2) {
            if (table.source.bytes(buffer[0..size], table.at + offset)) |read| {
                const text = std.mem.sliceTo(read, 0);
                return arena.dupe(u8, text) catch null;
            }
        }
        return null;
    }
};

/// How many pairs of a function's value table are read at most (a huge function's lines).
const values_max = 1 << 16;
const string_size_max = 512;

const Varints = struct {
    table: *const Table,
    at: u64,
    buffer: [64]u8 = undefined,
    buffered_at: u64 = 0,
    buffered: usize = 0,

    fn byte(varints: *Varints) ?u8 {
        if (varints.at < varints.buffered_at or varints.at >= varints.buffered_at + varints.buffered) {
            // Near the file's end, a shorter read.
            var size: usize = varints.buffer.len;
            while (size > 0) : (size /= 2) {
                if (varints.table.source.read(varints.table.source.context, varints.buffer[0..size], varints.at)) break;
            } else return null;
            varints.buffered_at = varints.at;
            varints.buffered = size;
        }
        const result = varints.buffer[varints.at - varints.buffered_at];
        varints.at += 1;
        return result;
    }

    fn next(varints: *Varints) ?u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = varints.byte() orelse return null;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            if (shift >= 63) return null;
            shift += 7;
        }
    }
};

/// "pkg.Function file.go:line": the package's path to its last element, the file's to its name.
pub fn name(arena: std.mem.Allocator, found: Table.Found, size_max: usize) ?[]const u8 {
    const function = found.function[if (std.mem.lastIndexOfScalar(u8, found.function, '/')) |slash| slash + 1 else 0..];
    const file = std.fs.path.basename(found.file);
    const text = if (file.len > 0 and found.line > 0)
        std.fmt.allocPrint(arena, "{s} {s}:{d}", .{ function, file, found.line }) catch return null
    else
        arena.dupe(u8, function) catch return null;
    return text[0..@min(text.len, size_max)];
}

pub const Sections = struct { table: u64, text: u64 };

/// The file offset of an ELF file's .gopclntab and its .text's address, from its section
/// headers; null without a .gopclntab.
pub fn sections_of(source: Source) ?Sections {
    var header: [64]u8 = undefined;
    _ = source.bytes(&header, 0) orelse return null;
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2) return null;
    const sections = std.mem.readInt(u64, header[40..48], .little);
    const entry_size = std.mem.readInt(u16, header[58..60], .little);
    const count = std.mem.readInt(u16, header[60..62], .little);
    const names_index = std.mem.readInt(u16, header[62..64], .little);
    if (entry_size < 64 or count == 0 or names_index >= count) return null;
    var entry: [64]u8 = undefined;
    _ = source.bytes(&entry, sections + @as(u64, names_index) * entry_size) orelse return null;
    const names_at = std.mem.readInt(u64, entry[24..32], .little);
    var table: ?u64 = null;
    var text: u64 = 0;
    for (0..count) |index| {
        _ = source.bytes(&entry, sections + index * entry_size) orelse return null;
        const name_at = std.mem.readInt(u32, entry[0..4], .little);
        var section_name: [16]u8 = undefined;
        _ = source.bytes(&section_name, names_at + name_at) orelse continue;
        const section = std.mem.sliceTo(&section_name, 0);
        if (std.mem.eql(u8, section, ".gopclntab")) table = std.mem.readInt(u64, entry[24..32], .little);
        if (std.mem.eql(u8, section, ".text")) text = std.mem.readInt(u64, entry[16..24], .little);
    }
    return .{ .table = table orelse return null, .text = text };
}

const Memory = struct {
    bytes: []const u8,

    fn read(context: *const anyopaque, buffer: []u8, offset: u64) bool {
        const memory: *const Memory = @ptrCast(@alignCast(context));
        if (offset > memory.bytes.len or buffer.len > memory.bytes.len - offset) return false;
        @memcpy(buffer, memory.bytes[offset..][0..buffer.len]);
        return true;
    }
};

test "a Go 1.20 table names an address's function, file and line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two functions at 0x401000 and 0x401040, the text ending at 0x401080; the first's lines:
    // 10 up to +0x10, 12 up to +0x30, 13 after; its file, the unit's second.
    var blob: [512]u8 = @splat(0);
    const header_size = 8 + 8 * 8;
    const names = header_size;
    const units = names + 64;
    const files = units + 16;
    const values = files + 64;
    const functab = values + 64;
    std.mem.writeInt(u32, blob[0..4], 0xfffffff1, .little);
    blob[6] = 1;
    blob[7] = 8;
    const words = [_]u64{ 2, 2, 0x401000, names, units, files, values, functab };
    for (words, 0..) |word, index| std.mem.writeInt(u64, blob[8 + index * 8 ..][0..8], word, .little);
    @memcpy(blob[names..][0..22], "example.com/x/pkg.Main");
    @memcpy(blob[names + 32 ..][0..9], "pkg.Other");
    std.mem.writeInt(u32, blob[units..][0..4], 0, .little);
    std.mem.writeInt(u32, blob[units + 4 ..][0..4], 8, .little);
    @memcpy(blob[files..][0..7], "a/zz.go");
    @memcpy(blob[files + 8 ..][0..13], "src/x/main.go");
    // Lines: value -1 + 11 = 10 over 0x10, +2 = 12 over 0x20, +1 = 13 over 0x50; then the end.
    const line_table = [_]u8{ 22, 0x10, 4, 0x20, 2, 0x50, 0 };
    @memcpy(blob[values + 1 ..][0..line_table.len], &line_table);
    // Files: index -1 + 2 = 1 over the whole function.
    const file_table = [_]u8{ 4, 0x80, 0x01, 0 };
    @memcpy(blob[values + 16 ..][0..file_table.len], &file_table);
    const entries = [_][2]u32{ .{ 0, 24 }, .{ 0x40, 64 }, .{ 0x80, 0 } };
    for (entries, 0..) |pair, index| {
        std.mem.writeInt(u32, blob[functab + index * 8 ..][0..4], pair[0], .little);
        std.mem.writeInt(u32, blob[functab + index * 8 + 4 ..][0..4], pair[1], .little);
    }
    const record = functab + 24;
    std.mem.writeInt(i32, blob[record + 4 ..][0..4], 0, .little);
    std.mem.writeInt(u32, blob[record + 20 ..][0..4], 16, .little);
    std.mem.writeInt(u32, blob[record + 24 ..][0..4], 1, .little);
    std.mem.writeInt(u32, blob[record + 32 ..][0..4], 0, .little);
    const other = functab + 64;
    std.mem.writeInt(i32, blob[other + 4 ..][0..4], 32, .little);
    const memory: Memory = .{ .bytes = &blob };
    const table = Table.of(.{ .context = &memory, .read = Memory.read }, 0, 0x500000).?;
    const found = table.find(arena, 0x401020).?;
    try std.testing.expectEqualStrings("example.com/x/pkg.Main", found.function);
    try std.testing.expectEqualStrings("src/x/main.go", found.file);
    try std.testing.expectEqual(@as(i64, 12), found.line);
    try std.testing.expectEqualStrings("pkg.Main main.go:12", name(arena, found, 96).?);
    try std.testing.expectEqual(@as(i64, 10), table.find(arena, 0x401000).?.line);
    try std.testing.expectEqualStrings("pkg.Other", table.find(arena, 0x401050).?.function);
    try std.testing.expect(table.find(arena, 0x401080) == null);
    try std.testing.expect(table.find(arena, 0x400fff) == null);
    // Go 1.22 and later: no start in the header, the file's .text address instead.
    std.mem.writeInt(u64, blob[8 + 2 * 8 ..][0..8], 0, .little);
    const later = Table.of(.{ .context = &memory, .read = Memory.read }, 0, 0x401000).?;
    try std.testing.expectEqualStrings("pkg.Main main.go:12", name(arena, later.find(arena, 0x401020).?, 96).?);
}
