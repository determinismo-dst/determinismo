// SPDX-License-Identifier: MIT
const std = @import("std");

/// The guest's binaries without their debug sections (.debug_*, .zdebug_*): DWARF names the
/// directory a binary was built in (its compilation directories; Zig's cache, keyed by content,
/// hands an object built in one tree to the next, its path with it), so the image's bytes, and
/// the histories hashed from the guest's announcements, depended on where it was built (PLAN,
/// 2026-11-15). Nothing a loader reads holds a path: the bytes up to the last loaded one stay as
/// they are, and the symbol table and the section names after them; the host keeps each binary
/// whole (zig-out/bin). Not an ELF64 little-endian file, or nothing to strip: its bytes as they are.
pub fn elf_debug_stripped(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    if (data.len < elf_header_size or !std.mem.eql(u8, data[0..4], "\x7fELF") or data[4] != 2 or data[5] != 1) return data;
    const phoff = read(u64, data, 0x20);
    const shoff = read(u64, data, 0x28);
    const phentsize = read(u16, data, 0x36);
    const phnum = read(u16, data, 0x38);
    const shentsize = read(u16, data, 0x3A);
    const shnum = read(u16, data, 0x3C);
    const shstrndx = read(u16, data, 0x3E);
    if (shnum == 0) return data;
    if (shentsize != section_header_size or shstrndx >= shnum or shoff + @as(u64, shnum) * section_header_size > data.len or
        phoff + @as(u64, phnum) * phentsize > data.len or (phnum > 0 and phentsize < program_header_size)) return error.ElfHeaders;
    const sections = try arena.alloc(Section, shnum);
    for (sections, 0..) |*section, index| section.* = .read(data[shoff + index * section_header_size ..][0..section_header_size]);
    const names = sections[shstrndx];
    if (names.offset + names.size > data.len) return error.ElfHeaders;
    const going = try arena.alloc(bool, shnum);
    for (sections, going) |section, *goes| {
        const name = section_name(data, names, section.name) orelse return error.ElfHeaders;
        goes.* = section.flags & shf_alloc == 0 and
            (std.mem.startsWith(u8, name, ".debug") or std.mem.startsWith(u8, name, ".zdebug"));
    }
    // A relocation section of a section that goes goes with it.
    for (sections, going) |section, *goes| {
        if ((section.type == sht_rel or section.type == sht_rela) and section.info < shnum and going[section.info]) goes.* = true;
    }
    const index_new = try arena.alloc(?u16, shnum);
    var kept: u16 = 0;
    for (going, index_new) |goes, *new| {
        new.* = if (goes) null else kept;
        if (!goes) kept += 1;
    }
    if (kept == shnum) return data;

    // Everything a loader reads, as it is: the headers, every segment, every loaded section.
    var head: u64 = elf_header_size;
    if (phnum > 0) head = @max(head, phoff + @as(u64, phnum) * phentsize);
    for (0..phnum) |index| {
        const program = data[phoff + index * phentsize ..];
        head = @max(head, read(u64, program, 0x08) + read(u64, program, 0x20));
    }
    for (sections, going) |section, goes| {
        if (!goes and section.flags & shf_alloc != 0 and section.type != sht_nobits) head = @max(head, section.offset + section.size);
    }
    if (head > data.len) return error.ElfHeaders;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, data[0..head]);
    const offset_new = try arena.alloc(u64, shnum);
    for (sections, going, offset_new) |section, goes, *offset| {
        if (goes) continue;
        if (section.type == sht_nobits) {
            offset.* = if (section.flags & shf_alloc != 0) section.offset else out.items.len;
        } else if (section.offset + section.size <= head) {
            offset.* = section.offset;
        } else {
            if (section.offset + section.size > data.len) return error.ElfHeaders;
            try align_to(arena, &out, @max(section.addralign, 1));
            offset.* = out.items.len;
            try out.appendSlice(arena, data[section.offset..][0..section.size]);
        }
    }
    // Symbols name their sections by index: those that went say none.
    for (sections, going, offset_new) |section, goes, offset| {
        if (goes or (section.type != sht_symtab and section.type != sht_dynsym)) continue;
        if (section.entsize != symbol_size or section.size % symbol_size != 0) return error.ElfSymbols;
        var at = offset;
        while (at < offset + section.size) : (at += symbol_size) {
            const index = read(u16, out.items, at + 6);
            if (index == shn_xindex) return error.ElfSymbols;
            if (index == 0 or index >= shn_loreserve) continue;
            if (index >= shnum) return error.ElfSymbols;
            write(u16, out.items, at + 6, index_new[index] orelse 0);
        }
    }
    try align_to(arena, &out, 8);
    const shoff_new = out.items.len;
    for (sections, going, offset_new) |section, goes, offset| {
        if (goes) continue;
        var header = section;
        header.offset = offset;
        if (header.link != 0 and header.link < shnum) header.link = index_new[header.link] orelse 0;
        if ((header.type == sht_rel or header.type == sht_rela or header.flags & shf_info_link != 0) and header.info < shnum)
            header.info = index_new[header.info] orelse 0;
        try header.append(arena, &out);
    }
    write(u64, out.items, 0x28, shoff_new);
    write(u16, out.items, 0x3C, kept);
    write(u16, out.items, 0x3E, index_new[shstrndx] orelse return error.ElfHeaders);
    return out.items;
}

const elf_header_size = 64;
const program_header_size = 56;
const section_header_size = 64;
const symbol_size = 24;
const shf_alloc = 0x2;
const shf_info_link = 0x40;
const sht_symtab = 2;
const sht_rela = 4;
const sht_nobits = 8;
const sht_rel = 9;
const sht_dynsym = 11;
const shn_loreserve = 0xff00;
const shn_xindex = 0xffff;

const Section = struct {
    name: u32,
    type: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,

    fn read(bytes: *const [section_header_size]u8) Section {
        return .{
            .name = std.mem.readInt(u32, bytes[0x00..0x04], .little),
            .type = std.mem.readInt(u32, bytes[0x04..0x08], .little),
            .flags = std.mem.readInt(u64, bytes[0x08..0x10], .little),
            .addr = std.mem.readInt(u64, bytes[0x10..0x18], .little),
            .offset = std.mem.readInt(u64, bytes[0x18..0x20], .little),
            .size = std.mem.readInt(u64, bytes[0x20..0x28], .little),
            .link = std.mem.readInt(u32, bytes[0x28..0x2C], .little),
            .info = std.mem.readInt(u32, bytes[0x2C..0x30], .little),
            .addralign = std.mem.readInt(u64, bytes[0x30..0x38], .little),
            .entsize = std.mem.readInt(u64, bytes[0x38..0x40], .little),
        };
    }

    fn append(section: Section, arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var bytes: [section_header_size]u8 = undefined;
        std.mem.writeInt(u32, bytes[0x00..0x04], section.name, .little);
        std.mem.writeInt(u32, bytes[0x04..0x08], section.type, .little);
        std.mem.writeInt(u64, bytes[0x08..0x10], section.flags, .little);
        std.mem.writeInt(u64, bytes[0x10..0x18], section.addr, .little);
        std.mem.writeInt(u64, bytes[0x18..0x20], section.offset, .little);
        std.mem.writeInt(u64, bytes[0x20..0x28], section.size, .little);
        std.mem.writeInt(u32, bytes[0x28..0x2C], section.link, .little);
        std.mem.writeInt(u32, bytes[0x2C..0x30], section.info, .little);
        std.mem.writeInt(u64, bytes[0x30..0x38], section.addralign, .little);
        std.mem.writeInt(u64, bytes[0x38..0x40], section.entsize, .little);
        try out.appendSlice(arena, &bytes);
    }
};

fn read(comptime T: type, bytes: []const u8, at: u64) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn write(comptime T: type, bytes: []u8, at: u64, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

fn section_name(data: []const u8, names: Section, at: u32) ?[]const u8 {
    if (at >= names.size) return null;
    const table = data[names.offset..][0..names.size];
    const end = std.mem.indexOfScalarPos(u8, table, at, 0) orelse return null;
    return table[at..end];
}

fn align_to(arena: std.mem.Allocator, out: *std.ArrayList(u8), alignment: u64) !void {
    while (out.items.len % alignment != 0) try out.append(arena, 0);
}

/// An executable of one loaded segment (.text) and, after it, .debug_info (a build path), a
/// symbol table (a function in .text, a section symbol of .debug_info), its strings and the
/// section names.
fn test_elf(arena: std.mem.Allocator) ![]u8 {
    const shstrtab = "\x00.text\x00.debug_info\x00.symtab\x00.strtab\x00.shstrtab\x00";
    const strtab = "\x00main\x00";
    const path = "/home/det/determinismo-check\x00";
    var bytes = try arena.alloc(u8, 0x200);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    write(u16, bytes, 0x10, 2);
    write(u16, bytes, 0x12, 62);
    write(u64, bytes, 0x20, 64);
    write(u16, bytes, 0x34, 64);
    write(u16, bytes, 0x36, program_header_size);
    write(u16, bytes, 0x38, 1);
    write(u16, bytes, 0x3A, section_header_size);
    write(u16, bytes, 0x3C, 6);
    write(u16, bytes, 0x3E, 5);
    write(u32, bytes, 64, 1); // PT_LOAD of [0, 0x90).
    write(u64, bytes, 64 + 0x20, 0x90);
    @memset(bytes[0x80..0x90], 0xCC);
    @memcpy(bytes[0x90..][0..path.len], path);
    write(u64, bytes, 0xC0 + 24 + 8, 0x401000); // main: in .text (1).
    write(u32, bytes, 0xC0 + 24, 1);
    write(u16, bytes, 0xC0 + 24 + 6, 1);
    bytes[0xC0 + 48 + 4] = 3; // .debug_info's section symbol (2).
    write(u16, bytes, 0xC0 + 48 + 6, 2);
    @memcpy(bytes[0x108..][0..strtab.len], strtab);
    @memcpy(bytes[0x110..][0..shstrtab.len], shstrtab);
    var headers: std.ArrayList(u8) = .empty;
    const sections = [_]Section{
        std.mem.zeroes(Section),
        .{ .name = 1, .type = 1, .flags = 0x6, .addr = 0x401000, .offset = 0x80, .size = 0x10, .link = 0, .info = 0, .addralign = 16, .entsize = 0 },
        .{ .name = 7, .type = 1, .flags = 0, .addr = 0, .offset = 0x90, .size = path.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
        .{ .name = 19, .type = sht_symtab, .flags = 0, .addr = 0, .offset = 0xC0, .size = 72, .link = 4, .info = 2, .addralign = 8, .entsize = symbol_size },
        .{ .name = 27, .type = 3, .flags = 0, .addr = 0, .offset = 0x108, .size = strtab.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
        .{ .name = 35, .type = 3, .flags = 0, .addr = 0, .offset = 0x110, .size = shstrtab.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
    };
    for (sections) |section| try section.append(arena, &headers);
    const shoff = 0x140;
    bytes = try arena.realloc(bytes, shoff + headers.items.len);
    @memcpy(bytes[shoff..], headers.items);
    write(u64, bytes, 0x28, shoff);
    return bytes;
}

test "the guest's binaries lose their debug sections, and the build path in them, alone" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const elf = try test_elf(arena);
    try std.testing.expect(std.mem.indexOf(u8, elf, "/home/det/determinismo-check") != null);
    const stripped = try elf_debug_stripped(arena, elf);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "/home/det/determinismo-check") == null);
    // What a loader reads, the same bytes at the same offsets.
    try std.testing.expectEqualSlices(u8, elf[0x40..0x90], stripped[0x40..0x90]);
    try std.testing.expectEqual(@as(u16, 5), read(u16, stripped, 0x3C));
    try std.testing.expectEqual(@as(u16, 4), read(u16, stripped, 0x3E));
    const shoff = read(u64, stripped, 0x28);
    const header = struct {
        fn at(bytes: []const u8, offset: u64, index: usize) Section {
            return .read(bytes[offset + index * section_header_size ..][0..section_header_size]);
        }
    }.at;
    const symtab = header(stripped, shoff, 2);
    try std.testing.expectEqual(@as(u32, sht_symtab), symtab.type);
    try std.testing.expectEqual(@as(u32, 3), symtab.link); // .strtab, one down.
    try std.testing.expectEqual(@as(u16, 1), read(u16, stripped, symtab.offset + 24 + 6)); // main still in .text.
    try std.testing.expectEqual(@as(u16, 0), read(u16, stripped, symtab.offset + 48 + 6)); // .debug_info's: none.
    const names = header(stripped, shoff, 4);
    try std.testing.expectEqualStrings(".symtab", section_name(stripped, names, symtab.name).?);
    try std.testing.expectEqualStrings("\x00main\x00", stripped[header(stripped, shoff, 3).offset..][0..6]);
    // Stripped again, or never anything to strip: the very bytes.
    try std.testing.expect((try elf_debug_stripped(arena, stripped)).ptr == stripped.ptr);
    const text = "#!/bin/sh\nexec true\n";
    try std.testing.expect((try elf_debug_stripped(arena, text)).ptr == text.ptr);
}
