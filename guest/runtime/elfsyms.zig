// SPDX-License-Identifier: MIT
//! A module's own ELF symbol tables: the function an address is in, by name and offset, where
//! no table of lines names it and it is no Go program (where.zig). Its .symtab when it has one
//! (a binary built with symbols: every function), else its .dynsym (a stripped library keeps
//! its exported functions: libc's exit, abort, raise). Only an address inside a function's own
//! extent (its symbol's value and size) is named: one past an exported function's end is a
//! static function's, and the exported one before it would be a wrong name.
const std = @import("std");
const gopclntab = @import("gopclntab.zig");
const cxx = @import("cxx.zig");

pub const Source = gopclntab.Source;

const sht_symtab = 2;
const sht_dynsym = 11;
const stt_func = 2;
const stt_gnu_ifunc = 10;
const section_header_size = 64;
const symbol_size = 24;
/// A table larger than this is not read (a huge C++ server's, hundreds of MB with debug info):
/// its frames stay module and offset.
const table_size_max = 64 << 20;
const sections_max = 4096;

pub const Function = struct { start: u64, size: u64, name: u32 };

pub const Symbols = struct {
    /// By start address.
    functions: []const Function,
    strings: []const u8,

    /// The table of the ELF file `source` reads, or null: not a 64-bit ELF, no symbols.
    pub fn load(arena: std.mem.Allocator, source: Source) ?Symbols {
        var header: [64]u8 = undefined;
        if (!source.read(source.context, &header, 0)) return null;
        if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1) return null;
        const sections_at = std.mem.readInt(u64, header[40..48], .little);
        const entry_size = std.mem.readInt(u16, header[58..60], .little);
        const count = std.mem.readInt(u16, header[60..62], .little);
        if (entry_size < section_header_size or count == 0 or count > sections_max) return null;
        const sections = arena.alloc(u8, @as(usize, count) * entry_size) catch return null;
        if (!source.read(source.context, sections, sections_at)) return null;
        const Section = struct { kind: u32, offset: u64, size: u64, link: u32 };
        const section = struct {
            fn at(bytes: []const u8, size: usize, index: usize) Section {
                const entry = bytes[index * size ..][0..section_header_size];
                return .{
                    .kind = std.mem.readInt(u32, entry[4..8], .little),
                    .offset = std.mem.readInt(u64, entry[24..32], .little),
                    .size = std.mem.readInt(u64, entry[32..40], .little),
                    .link = std.mem.readInt(u32, entry[40..44], .little),
                };
            }
        }.at;
        // The full table when it is there, else the dynamic one.
        var chosen: ?Section = null;
        for (0..count) |index| {
            const candidate = section(sections, entry_size, index);
            if (candidate.kind == sht_symtab) chosen = candidate;
            if (candidate.kind == sht_dynsym and chosen == null) chosen = candidate;
        }
        const table = chosen orelse return null;
        if (table.link >= count or table.size > table_size_max or table.size % symbol_size != 0) return null;
        const names = section(sections, entry_size, table.link);
        if (names.size > table_size_max) return null;
        const symbols = arena.alloc(u8, @intCast(table.size)) catch return null;
        const strings = arena.alloc(u8, @intCast(names.size)) catch return null;
        if (!source.read(source.context, symbols, table.offset)) return null;
        if (!source.read(source.context, strings, names.offset)) return null;
        var functions: std.ArrayList(Function) = .empty;
        var at: usize = 0;
        while (at < symbols.len) : (at += symbol_size) {
            const symbol = symbols[at..][0..symbol_size];
            const kind = symbol[4] & 0xf;
            if (kind != stt_func and kind != stt_gnu_ifunc) continue;
            const name_at = std.mem.readInt(u32, symbol[0..4], .little);
            const start = std.mem.readInt(u64, symbol[8..16], .little);
            const size = std.mem.readInt(u64, symbol[16..24], .little);
            if (start == 0 or size == 0 or name_at == 0 or name_at >= strings.len) continue;
            functions.append(arena, .{ .start = start, .size = size, .name = name_at }) catch return null;
        }
        if (functions.items.len == 0) return null;
        std.mem.sort(Function, functions.items, {}, struct {
            fn less(_: void, a: Function, b: Function) bool {
                return a.start < b.start;
            }
        }.less);
        return .{ .functions = functions.items, .strings = strings };
    }

    pub const Found = struct { name: []const u8, offset: u64 };

    /// The function `address` (a link-time address) is inside, and how far into it.
    pub fn find(symbols: *const Symbols, address: u64) ?Found {
        var low: usize = 0;
        var high: usize = symbols.functions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (symbols.functions[middle].start <= address) low = middle + 1 else high = middle;
        }
        // Aliases share a start: any whose extent holds the address.
        var index = low;
        while (index > 0) {
            index -= 1;
            const function = symbols.functions[index];
            if (address - function.start < function.size) {
                return .{ .name = std.mem.sliceTo(symbols.strings[function.name..], 0), .offset = address - function.start };
            }
            if (index == 0 or symbols.functions[index - 1].start != function.start) break;
        }
        return null;
    }
};

/// "<function>+0x<offset> <module>", at most `size_max` bytes.
pub fn name(arena: std.mem.Allocator, found: Symbols.Found, module: []const u8, size_max: usize) ?[]const u8 {
    // Rust's legacy names first (their last part its hash: C++ would read it as a name), then
    // C++'s whole signature (cxx.zig), else a nested name's parts, else the symbol as it is.
    const function = (if (rust_hashed(found.name)) demangled(arena, found.name) else cxx.demangle(arena, found.name) orelse demangled(arena, found.name)) orelse found.name;
    const text = std.fmt.allocPrint(arena, "{s}+0x{x} {s}", .{ function, found.offset, module }) catch return null;
    return text[0..@min(text.len, size_max)];
}

/// A nested name as it reads in its language: Itanium's `_ZN<len><part>...E` (C++'s
/// namespaces, Rust's legacy mangling: the default of stable Rust) as its parts joined by `::`,
/// Rust's trailing hash part (`h` and 16 hex digits) dropped and its escapes (`$LT$`, `$u20$`,
/// `..`) read back; what follows the `E` (a C++ function's parameter types) left out. Null for
/// any other name (a C function's, kept as it is).
pub fn demangled(arena: std.mem.Allocator, mangled: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, mangled, "_ZN")) return null;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 3;
    // A const or volatile method's qualifiers before its first part.
    while (at < mangled.len and (mangled[at] == 'K' or mangled[at] == 'V')) at += 1;
    var parts: u32 = 0;
    if (std.mem.startsWith(u8, mangled[at..], "St")) {
        out.appendSlice(arena, "std") catch return null;
        at += 2;
        parts += 1;
    }
    while (at < mangled.len and mangled[at] != 'E') {
        // Template arguments: skipped whole (their own nested names and literals end in E too).
        if (mangled[at] == 'I') {
            var depth: usize = 0;
            while (at < mangled.len) : (at += 1) {
                switch (mangled[at]) {
                    'I', 'N' => depth += 1,
                    'L' => if (at + 1 < mangled.len and mangled[at + 1] != 'Z') {
                        depth += 1;
                    },
                    'E' => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    else => {},
                }
            }
            if (at >= mangled.len) break;
            at += 1;
            continue;
        }
        if (!std.ascii.isDigit(mangled[at])) break; // A part not read here: the parts so far.
        var length: usize = 0;
        while (at < mangled.len and std.ascii.isDigit(mangled[at])) : (at += 1) length = length * 10 + (mangled[at] - '0');
        if (length == 0 or length > mangled.len - at) return null;
        const part = mangled[at..][0..length];
        at += length;
        const rust_hash = part.len == 17 and part[0] == 'h' and for (part[1..]) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (rust_hash and at < mangled.len and mangled[at] == 'E') break;
        if (parts > 0) out.appendSlice(arena, "::") catch return null;
        unescaped(arena, &out, part) catch return null;
        parts += 1;
    }
    if (parts == 0) return null;
    return out.items;
}

/// Whether `mangled` is Rust's legacy mangling: a nested name whose last part is its hash
/// (`17h` and 16 hex digits, then `E`, a clone's `.llvm.<n>` suffix after it).
fn rust_hashed(mangled: []const u8) bool {
    if (!std.mem.startsWith(u8, mangled, "_ZN")) return false;
    const end = std.mem.indexOfScalar(u8, mangled, '.') orelse mangled.len;
    if (end < 20 or mangled[end - 1] != 'E') return false;
    const hash = mangled[end - 20 .. end - 1];
    if (!std.mem.startsWith(u8, hash, "17h")) return false;
    for (hash[3..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A Rust legacy part's escapes read back: `$LT$` <, `$GT$` >, `$RF$` &, `$BP$` *, `$C$` ,,
/// `$SP$` @, `$u<hex>$` that character, `..` ::, a leading `_$` the `$` alone.
fn unescaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), part: []const u8) !void {
    const named = [_]struct { []const u8, []const u8 }{
        .{ "$LT$", "<" }, .{ "$GT$", ">" }, .{ "$RF$", "&" }, .{ "$BP$", "*" },
        .{ "$C$", "," },  .{ "$SP$", "@" }, .{ "$LP$", "(" }, .{ "$RP$", ")" },
    };
    var at: usize = if (std.mem.startsWith(u8, part, "_$")) 1 else 0;
    outer: while (at < part.len) {
        if (part[at] == '$') {
            for (named) |pair| if (std.mem.startsWith(u8, part[at..], pair[0])) {
                try out.appendSlice(arena, pair[1]);
                at += pair[0].len;
                continue :outer;
            };
            if (at + 1 < part.len and part[at + 1] == 'u') if (std.mem.indexOfScalarPos(u8, part, at + 2, '$')) |end| {
                if (std.fmt.parseInt(u21, part[at + 2 .. end], 16)) |code| {
                    var buffer: [4]u8 = undefined;
                    const size = std.unicode.utf8Encode(code, &buffer) catch 0;
                    if (size > 0) {
                        try out.appendSlice(arena, buffer[0..size]);
                        at = end + 1;
                        continue :outer;
                    }
                } else |_| {}
            };
        }
        if (std.mem.startsWith(u8, part[at..], "..")) {
            try out.appendSlice(arena, "::");
            at += 2;
            continue;
        }
        try out.append(arena, part[at]);
        at += 1;
    }
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

test "a function is named only inside its own extent, .symtab before .dynsym" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An ELF file: its header, then a .dynsym (exit, 0x1000 + 0x20), a .symtab (exit, and a
    // static helper at 0x1040 + 0x10, and an object), their strings, then the section headers.
    var blob: [1024]u8 = @splat(0);
    @memcpy(blob[0..4], "\x7fELF");
    blob[4] = 2;
    blob[5] = 1;
    const strings_at = 64;
    const strings = "\x00exit\x00helper\x00table\x00";
    @memcpy(blob[strings_at..][0..strings.len], strings);
    const dynsym_at = 128;
    const symtab_at = 192;
    const write_symbol = struct {
        fn at(b: []u8, offset: usize, name_at: u32, kind: u8, value: u64, size: u64) void {
            std.mem.writeInt(u32, b[offset..][0..4], name_at, .little);
            b[offset + 4] = kind;
            std.mem.writeInt(u64, b[offset + 8 ..][0..8], value, .little);
            std.mem.writeInt(u64, b[offset + 16 ..][0..8], size, .little);
        }
    }.at;
    write_symbol(&blob, dynsym_at, 1, stt_func, 0x1000, 0x20);
    write_symbol(&blob, symtab_at, 1, stt_func, 0x1000, 0x20);
    write_symbol(&blob, symtab_at + 24, 6, stt_func, 0x1040, 0x10);
    write_symbol(&blob, symtab_at + 48, 13, 1, 0x2000, 0x100); // An object, not a function.
    const sections_at = 512;
    std.mem.writeInt(u64, blob[40..48], sections_at, .little);
    std.mem.writeInt(u16, blob[58..60], section_header_size, .little);
    std.mem.writeInt(u16, blob[60..62], 4, .little);
    const write_section = struct {
        fn at(b: []u8, index: usize, kind: u32, offset: u64, size: u64, link: u32) void {
            const entry = b[512 + index * section_header_size ..][0..section_header_size];
            std.mem.writeInt(u32, entry[4..8], kind, .little);
            std.mem.writeInt(u64, entry[24..32], offset, .little);
            std.mem.writeInt(u64, entry[32..40], size, .little);
            std.mem.writeInt(u32, entry[40..44], link, .little);
        }
    }.at;
    write_section(&blob, 1, sht_dynsym, dynsym_at, 24, 3);
    write_section(&blob, 2, sht_symtab, symtab_at, 72, 3);
    write_section(&blob, 3, 3, strings_at, strings.len, 0);
    const memory: Memory = .{ .bytes = &blob };
    const symbols = Symbols.load(arena, .{ .context = &memory, .read = Memory.read }).?;
    try std.testing.expectEqual(@as(usize, 2), symbols.functions.len);
    try std.testing.expectEqualStrings("exit+0x16 libc.so.6", name(arena, symbols.find(0x1016).?, "libc.so.6", 96).?);
    try std.testing.expectEqualStrings("helper", symbols.find(0x1044).?.name);
    try std.testing.expect(symbols.find(0x1020) == null); // Past exit's end: no name.
    try std.testing.expect(symbols.find(0x0fff) == null);
    try std.testing.expect(symbols.find(0x2010) == null); // The object's.
    // Without the .symtab: the .dynsym's exit alone.
    write_section(&blob, 2, 0, 0, 0, 0);
    const exported = Symbols.load(arena, .{ .context = &memory, .read = Memory.read }).?;
    try std.testing.expectEqual(@as(usize, 1), exported.functions.len);
    try std.testing.expect(exported.find(0x1044) == null);
}

test "a nested name reads as its language writes it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Rust legacy, as the e2e race's exit stack had them.
    try std.testing.expectEqualStrings("std::process::exit", demangled(arena, "_ZN3std7process4exit17h0ba5b660d81e6caeE").?);
    try std.testing.expectEqualStrings("race::main", demangled(arena, "_ZN4race4main17h36cc26e430779c6bE").?);
    // Rust escapes: a trait implementation's path.
    try std.testing.expectEqualStrings("<alloc::vec::Vec<T> as core::ops::drop::Drop>::drop", demangled(arena, "_ZN66_$LT$alloc..vec..Vec$LT$T$GT$$u20$as$u20$core..ops..drop..Drop$GT$4drop17h0123456789abcdefE").?);
    // C++: its namespaces, its parameter types left out.
    try std.testing.expectEqualStrings("leveldb::DBImpl::Write", demangled(arena, "_ZN7leveldb6DBImpl5WriteERKNS_12WriteOptionsEPNS_10WriteBatchE").?);
    // Not nested, or not mangled: kept as they are.
    try std.testing.expect(demangled(arena, "exit") == null);
    try std.testing.expect(demangled(arena, "_Z3fooi") == null);
    try std.testing.expectEqualStrings("foo", demangled(arena, "_ZN3foo").?);
    try std.testing.expectEqualStrings("std::process::exit+0x13 race", name(arena, .{ .name = "_ZN3std7process4exit17h0ba5b660d81e6caeE", .offset = 0x13 }, "race", 96).?);
    // C++: its whole signature (cxx.zig), an overload told apart by it.
    try std.testing.expectEqualStrings("leveldb::DBImpl::Write(leveldb::WriteOptions const&, leveldb::WriteBatch*)+0x2a db_bench", name(arena, .{ .name = "_ZN7leveldb6DBImpl5WriteERKNS_12WriteOptionsEPNS_10WriteBatchE", .offset = 0x2a }, "db_bench", 200).?);
    // Outside cxx.zig's subset (a parameter pack): the parts alone.
    try std.testing.expectEqualStrings("std::__1::make_shared+0x1 libc++.so", name(arena, .{ .name = "_ZNSt3__111make_sharedIiJiEEENS_10shared_ptrIT_EEDpOT0_", .offset = 1 }, "libc++.so", 200).?);
}
