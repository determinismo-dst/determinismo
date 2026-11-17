// SPDX-License-Identifier: MIT
//! Unwinding by call frame information: an ELF file's .eh_frame (DWARF CFI, as compilers emit it
//! for exceptions, so it is there in code built without frame pointers: glibc's, OpenSSL's) and
//! its .eh_frame_hdr's sorted table. For a program counter, the rule of its frame: where the
//! canonical frame address (CFA) is (a register, rsp or rbp, plus an offset), and where the
//! return address and the caller's rbp were saved (at the CFA plus an offset). det-profile walks
//! a stack with it, frame pointers where a file has none. x86-64; a rule this does not follow (a
//! DWARF expression, a CFA in another register, a signal frame's) is no rule: the caller then
//! falls back to the frame pointer.
const std = @import("std");

/// DWARF's x86-64 register numbers.
const register_bp = 6;
const register_sp = 7;
const register_ra = 16;
const remembered_max = 8;

/// Where a register of the caller is: unchanged, lost, or saved at the CFA plus an offset.
pub const Saved = union(enum) {
    same,
    undefined,
    offset: i64,
};

/// The frame at a program counter.
pub const Rule = struct {
    /// rsp (7) or rbp (6).
    cfa_register: u8,
    cfa_offset: i64,
    ra: Saved,
    bp: Saved,
};

/// One file's tables: its sections' bytes and their (ELF virtual) addresses.
pub const Tables = struct {
    frame: []const u8,
    frame_address: u64,
    /// Empty without one: every FDE is then searched in order.
    hdr: []const u8 = &.{},
    hdr_address: u64 = 0,

    /// The rule at `pc`, an address in this file's ELF space; null without an FDE covering it,
    /// or with one this does not follow.
    pub fn rule(tables: Tables, pc: u64) ?Rule {
        const fde_offset = tables.fde_find(pc) orelse return null;
        return tables.fde_rule(fde_offset, pc) catch null;
    }

    fn fde_find(tables: Tables, pc: u64) ?usize {
        if (tables.hdr.len >= 4 and tables.hdr[0] == 1 and tables.hdr[3] == pointer_datarel_sdata4) {
            return tables.hdr_search(pc) catch null;
        }
        return tables.frame_search(pc) catch null;
    }

    /// .eh_frame_hdr's table: (initial location, FDE address) pairs, relative to it, sorted.
    fn hdr_search(tables: Tables, pc: u64) !?usize {
        var reader: Reader = .{ .bytes = tables.hdr, .at = 4, .address = tables.hdr_address };
        _ = try reader.pointer(tables.hdr[1], tables.hdr_address);
        const count = try reader.pointer(tables.hdr[2], tables.hdr_address);
        const table = reader.at;
        if (table + count * 8 > tables.hdr.len) return error.Truncated;
        var low: u64 = 0;
        var high: u64 = count;
        while (low < high) {
            const middle = (low + high) / 2;
            if (tables.hdr_location(table, middle) <= pc) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const pair = table + (low - 1) * 8 + 4;
        const relative = std.mem.readInt(i32, tables.hdr[pair..][0..4], .little);
        const fde_address = signed_add(tables.hdr_address, relative);
        if (fde_address < tables.frame_address) return error.OutOfFrame;
        const offset = fde_address - tables.frame_address;
        if (offset >= tables.frame.len) return error.OutOfFrame;
        return offset;
    }

    fn hdr_location(tables: Tables, table: usize, index: u64) u64 {
        const at = table + index * 8;
        return signed_add(tables.hdr_address, std.mem.readInt(i32, tables.hdr[at..][0..4], .little));
    }

    /// Without a table: every FDE in order.
    fn frame_search(tables: Tables, pc: u64) !?usize {
        var at: usize = 0;
        while (at + 8 <= tables.frame.len) {
            const header = try tables.entry(at);
            if (header.length == 0) return null; // The terminator.
            if (header.id != 0) { // An FDE.
                const fde = try tables.fde_parse(at);
                if (pc >= fde.pc_begin and pc < fde.pc_begin + fde.pc_range) return at;
            }
            at = header.end;
        }
        return null;
    }

    const Entry = struct { length: u64, id: u32, body: usize, end: usize };

    /// An entry's length and the word after it (0 for a CIE; for an FDE, its CIE's distance).
    fn entry(tables: Tables, at: usize) !Entry {
        if (at + 4 > tables.frame.len) return error.Truncated;
        var length: u64 = std.mem.readInt(u32, tables.frame[at..][0..4], .little);
        var body = at + 4;
        if (length == 0xffffffff) {
            if (at + 12 > tables.frame.len) return error.Truncated;
            length = std.mem.readInt(u64, tables.frame[at + 4 ..][0..8], .little);
            body = at + 12;
        }
        if (length == 0) return .{ .length = 0, .id = 0, .body = body, .end = body };
        const end = body + length;
        if (end > tables.frame.len or body + 4 > end) return error.Truncated;
        return .{
            .length = length,
            .id = std.mem.readInt(u32, tables.frame[body..][0..4], .little),
            .body = body,
            .end = end,
        };
    }

    const Cie = struct {
        code_align: u64,
        data_align: i64,
        ra_register: u64,
        fde_encoding: u8 = pointer_absptr,
        augmented: bool = false,
        signal: bool = false,
        instructions: []const u8,
    };

    fn cie_parse(tables: Tables, at: usize) !Cie {
        const header = try tables.entry(at);
        if (header.id != 0) return error.NotCie;
        var reader: Reader = .{
            .bytes = tables.frame[0..header.end],
            .at = header.body + 4,
            .address = tables.frame_address,
        };
        const version = try reader.byte();
        if (version != 1 and version != 3) return error.Version;
        const augmentation_start = reader.at;
        while (try reader.byte() != 0) {}
        const augmentation = tables.frame[augmentation_start .. reader.at - 1];
        var cie: Cie = .{
            .code_align = try reader.uleb(),
            .data_align = try reader.sleb(),
            .ra_register = if (version == 1) try reader.byte() else try reader.uleb(),
            .instructions = &.{},
        };
        if (augmentation.len > 0 and augmentation[0] == 'z') {
            cie.augmented = true;
            const length = try reader.uleb();
            const data_end = reader.at + length;
            for (augmentation[1..]) |letter| switch (letter) {
                'R' => cie.fde_encoding = try reader.byte(),
                'P' => {
                    const encoding = try reader.byte();
                    _ = try reader.pointer(encoding, tables.frame_address);
                },
                'L' => _ = try reader.byte(),
                'S' => cie.signal = true,
                else => return error.Augmentation,
            };
            reader.at = data_end;
        } else if (augmentation.len > 0) return error.Augmentation;
        cie.instructions = tables.frame[reader.at..header.end];
        return cie;
    }

    const Fde = struct { cie: Cie, pc_begin: u64, pc_range: u64, instructions: []const u8 };

    fn fde_parse(tables: Tables, at: usize) !Fde {
        const header = try tables.entry(at);
        if (header.id == 0) return error.NotFde;
        // The CIE pointer: its distance back from the field.
        if (header.id > header.body) return error.BadCie;
        const cie = try tables.cie_parse(header.body - header.id);
        var reader: Reader = .{
            .bytes = tables.frame[0..header.end],
            .at = header.body + 4,
            .address = tables.frame_address,
        };
        const pc_begin = try reader.pointer(cie.fde_encoding, tables.frame_address);
        // The range: the same format, no base.
        const pc_range = try reader.pointer(cie.fde_encoding & 0x0f, tables.frame_address);
        if (cie.augmented) reader.at += try reader.uleb();
        if (reader.at > header.end) return error.Truncated;
        return .{
            .cie = cie,
            .pc_begin = pc_begin,
            .pc_range = pc_range,
            .instructions = tables.frame[reader.at..header.end],
        };
    }

    fn fde_rule(tables: Tables, at: usize, pc: u64) !Rule {
        const fde = try tables.fde_parse(at);
        if (pc < fde.pc_begin or pc >= fde.pc_begin + fde.pc_range) return error.NotCovered;
        if (fde.cie.signal or fde.cie.ra_register != register_ra) return error.Unfollowed;
        var machine: Machine = .{ .cie = fde.cie, .frame_address = tables.frame_address };
        try machine.run(fde.cie.instructions, std.math.maxInt(u64));
        machine.initial = machine.row;
        machine.location = fde.pc_begin;
        try machine.run(fde.instructions, pc);
        const row = machine.row;
        if (!row.cfa_known) return error.Unfollowed;
        if (row.cfa_register != register_sp and row.cfa_register != register_bp) return error.Unfollowed;
        return .{
            .cfa_register = row.cfa_register,
            .cfa_offset = row.cfa_offset,
            .ra = row.ra orelse return error.Unfollowed,
            .bp = row.bp orelse return error.Unfollowed,
        };
    }
};

/// The row the instructions build: null registers have a rule this does not follow.
const Row = struct {
    cfa_register: u8 = register_sp,
    cfa_offset: i64 = 8,
    cfa_known: bool = true,
    ra: ?Saved = .undefined,
    bp: ?Saved = .same,
};

const Machine = struct {
    cie: Tables.Cie,
    frame_address: u64,
    location: u64 = 0,
    row: Row = .{},
    initial: Row = .{},
    remembered: [remembered_max]Row = undefined,
    remembered_count: u8 = 0,

    /// Runs the instructions until the location passes `pc` (all of them for a CIE's).
    fn run(machine: *Machine, instructions: []const u8, pc: u64) !void {
        var reader: Reader = .{ .bytes = instructions, .at = 0, .address = 0 };
        while (reader.at < instructions.len) {
            const op = try reader.byte();
            const low: u8 = op & 0x3f;
            switch (op >> 6) {
                1 => { // DW_CFA_advance_loc
                    if (try machine.advance(low * machine.cie.code_align, pc)) return;
                    continue;
                },
                2 => { // DW_CFA_offset
                    machine.saved(low, .{ .offset = @as(i64, @intCast(try reader.uleb())) * machine.cie.data_align });
                    continue;
                },
                3 => { // DW_CFA_restore
                    machine.restore(low);
                    continue;
                },
                else => {},
            }
            switch (op) {
                0x00 => {}, // nop
                0x01 => { // set_loc
                    const location = try reader.pointer(machine.cie.fde_encoding, machine.frame_address);
                    if (location > pc) return;
                    machine.location = location;
                },
                0x02 => if (try machine.advance(try reader.byte() * machine.cie.code_align, pc)) return,
                0x03 => if (try machine.advance(try reader.int(u16) * machine.cie.code_align, pc)) return,
                0x04 => if (try machine.advance(try reader.int(u32) * machine.cie.code_align, pc)) return,
                0x05 => { // offset_extended
                    const register = try reader.uleb();
                    machine.saved(register, .{ .offset = @as(i64, @intCast(try reader.uleb())) * machine.cie.data_align });
                },
                0x06 => machine.restore(try reader.uleb()),
                0x07 => machine.saved(try reader.uleb(), .undefined),
                0x08 => machine.saved(try reader.uleb(), .same),
                0x09 => { // register: in another register, not followed.
                    const register = try reader.uleb();
                    _ = try reader.uleb();
                    machine.unfollowed(register);
                },
                0x0a => { // remember_state
                    if (machine.remembered_count == remembered_max) return error.TooDeep;
                    machine.remembered[machine.remembered_count] = machine.row;
                    machine.remembered_count += 1;
                },
                0x0b => { // restore_state
                    if (machine.remembered_count == 0) return error.Underflow;
                    machine.remembered_count -= 1;
                    const cfa = machine.remembered[machine.remembered_count];
                    machine.row = cfa;
                },
                0x0c => { // def_cfa
                    machine.row.cfa_register = @intCast(@min(try reader.uleb(), 255));
                    machine.row.cfa_offset = @intCast(try reader.uleb());
                    machine.row.cfa_known = true;
                },
                0x0d => machine.row.cfa_register = @intCast(@min(try reader.uleb(), 255)),
                0x0e => machine.row.cfa_offset = @intCast(try reader.uleb()),
                0x0f => { // def_cfa_expression
                    reader.at += try reader.uleb();
                    machine.row.cfa_known = false;
                },
                0x10 => { // expression
                    const register = try reader.uleb();
                    reader.at += try reader.uleb();
                    machine.unfollowed(register);
                },
                0x11 => { // offset_extended_sf
                    const register = try reader.uleb();
                    machine.saved(register, .{ .offset = try reader.sleb() * machine.cie.data_align });
                },
                0x12 => { // def_cfa_sf
                    machine.row.cfa_register = @intCast(@min(try reader.uleb(), 255));
                    machine.row.cfa_offset = try reader.sleb() * machine.cie.data_align;
                    machine.row.cfa_known = true;
                },
                0x13 => machine.row.cfa_offset = try reader.sleb() * machine.cie.data_align,
                0x14, 0x15 => { // val_offset, val_offset_sf: a value, not a save.
                    const register = try reader.uleb();
                    if (op == 0x14) _ = try reader.uleb() else _ = try reader.sleb();
                    machine.unfollowed(register);
                },
                0x16 => { // val_expression
                    const register = try reader.uleb();
                    reader.at += try reader.uleb();
                    machine.unfollowed(register);
                },
                0x2e => _ = try reader.uleb(), // GNU_args_size
                0x2f => { // GNU_negative_offset_extended
                    const register = try reader.uleb();
                    machine.saved(register, .{ .offset = -@as(i64, @intCast(try reader.uleb())) * machine.cie.data_align });
                },
                else => return error.Opcode,
            }
        }
    }

    /// Whether the new location passes `pc`: then the row is the one at `pc`.
    fn advance(machine: *Machine, delta: u64, pc: u64) !bool {
        const location = machine.location + delta;
        if (location > pc) return true;
        machine.location = location;
        return false;
    }

    fn saved(machine: *Machine, register: u64, rule: Saved) void {
        if (register == register_ra) machine.row.ra = rule;
        if (register == register_bp) machine.row.bp = rule;
    }

    fn unfollowed(machine: *Machine, register: u64) void {
        if (register == register_ra) machine.row.ra = null;
        if (register == register_bp) machine.row.bp = null;
    }

    fn restore(machine: *Machine, register: u64) void {
        if (register == register_ra) machine.row.ra = machine.initial.ra;
        if (register == register_bp) machine.row.bp = machine.initial.bp;
    }
};

// DW_EH_PE pointer encodings.
const pointer_absptr = 0x00;
const pointer_datarel_sdata4 = 0x3b;
const pointer_omit = 0xff;

const Reader = struct {
    bytes: []const u8,
    at: usize,
    /// The bytes' address: where a pc-relative pointer is measured from.
    address: u64,

    fn byte(reader: *Reader) !u8 {
        if (reader.at >= reader.bytes.len) return error.Truncated;
        reader.at += 1;
        return reader.bytes[reader.at - 1];
    }

    fn int(reader: *Reader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (reader.at + size > reader.bytes.len) return error.Truncated;
        defer reader.at += size;
        return std.mem.readInt(T, reader.bytes[reader.at..][0..size], .little);
    }

    fn uleb(reader: *Reader) !u64 {
        var value: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const next = try reader.byte();
            if (shift < 64) value |= @as(u64, next & 0x7f) << @intCast(shift);
            if (next & 0x80 == 0) return value;
            shift += 7;
            if (shift > 70) return error.Overlong;
        }
    }

    fn sleb(reader: *Reader) !i64 {
        var value: i64 = 0;
        var shift: u7 = 0;
        var next: u8 = 0;
        while (true) {
            next = try reader.byte();
            if (shift < 64) value |= @as(i64, next & 0x7f) << @intCast(shift);
            shift += 7;
            if (next & 0x80 == 0) break;
            if (shift > 70) return error.Overlong;
        }
        if (shift < 64 and next & 0x40 != 0) value |= @as(i64, -1) << @intCast(shift);
        return value;
    }

    /// A pointer in `encoding`: its format (low four bits), then what it is relative to (pc:
    /// this field's address; data: `data_base`).
    fn pointer(reader: *Reader, encoding: u8, data_base: u64) !u64 {
        if (encoding == pointer_omit) return 0;
        const field = reader.address + reader.at;
        const raw: u64 = switch (encoding & 0x0f) {
            0x00 => try reader.int(u64),
            0x01 => try reader.uleb(),
            0x02 => try reader.int(u16),
            0x03 => try reader.int(u32),
            0x04 => try reader.int(u64),
            0x09 => @bitCast(try reader.sleb()),
            0x0a => @bitCast(@as(i64, try reader.int(i16))),
            0x0b => @bitCast(@as(i64, try reader.int(i32))),
            0x0c => @bitCast(try reader.int(i64)),
            else => return error.Encoding,
        };
        return switch (encoding & 0x70) {
            0x00 => raw,
            0x10 => raw +% field,
            0x30 => raw +% data_base,
            else => error.Encoding,
        };
    }
};

fn signed_add(base: u64, delta: i32) u64 {
    return @bitCast(@as(i64, @bitCast(base)) +% delta);
}

/// A CIE and an FDE as compilers write them for `push rbp; mov rbp, rsp`: CFA rsp+8 and the
/// return address at CFA-8 at entry; CFA rsp+16 and rbp at CFA-16 after the push (+1); CFA
/// rbp+16 after the move (+4). With an .eh_frame_hdr table, and without one.
fn tables_test(frame: []u8, hdr: []u8) Tables {
    const frame_address: u64 = 0x2000;
    const pc_begin: u64 = 0x1000;
    // The CIE (at 0): length 20, id 0, version 1, "zR", code align 1, data align -8, ra 16,
    // augmentation length 1, FDE encoding pcrel|sdata4; def_cfa r7+8, offset r16 at 1*-8, pad.
    const cie = [_]u8{ 20, 0, 0, 0, 0, 0, 0, 0, 1, 'z', 'R', 0, 1, 0x78, 16, 1, 0x1b, 0x0c, 7, 8, 0x90, 1, 0, 0 };
    @memcpy(frame[0..cie.len], &cie);
    // The FDE (at 24): length 24, its CIE 28 bytes back, pc_begin (pc-relative), range 16,
    // augmentation length 0; advance 1, def_cfa_offset 16, offset r6 at 2*-8, advance 3,
    // def_cfa_register r6, pad.
    const at = cie.len;
    std.mem.writeInt(u32, frame[at..][0..4], 24, .little);
    std.mem.writeInt(u32, frame[at + 4 ..][0..4], @intCast(at + 4), .little);
    const field = frame_address + at + 8;
    std.mem.writeInt(i32, frame[at + 8 ..][0..4], distance(pc_begin, field), .little);
    std.mem.writeInt(u32, frame[at + 12 ..][0..4], 16, .little);
    const instructions = [_]u8{ 0, 0x41, 0x0e, 16, 0x86, 2, 0x43, 0x0d, 6, 0, 0, 0 };
    @memcpy(frame[at + 16 ..][0..instructions.len], &instructions);
    std.mem.writeInt(u32, frame[at + 28 ..][0..4], 0, .little); // The terminator.
    // The header: version 1, eh_frame pointer pcrel|sdata4, count udata4, table datarel|sdata4.
    const hdr_address: u64 = 0x3000;
    hdr[0] = 1;
    hdr[1] = 0x1b;
    hdr[2] = 0x03;
    hdr[3] = 0x3b;
    std.mem.writeInt(i32, hdr[4..][0..4], distance(frame_address, hdr_address + 4), .little);
    std.mem.writeInt(u32, hdr[8..][0..4], 1, .little);
    std.mem.writeInt(i32, hdr[12..][0..4], distance(pc_begin, hdr_address), .little);
    std.mem.writeInt(i32, hdr[16..][0..4], distance(frame_address + at, hdr_address), .little);
    return .{ .frame = frame, .frame_address = frame_address, .hdr = hdr, .hdr_address = hdr_address };
}

fn distance(to: u64, from: u64) i32 {
    return @intCast(@as(i64, @intCast(to)) - @as(i64, @intCast(from)));
}

test "rules of a push rbp; mov rbp, rsp prologue, through the header and without it" {
    var frame: [64]u8 = @splat(0);
    var hdr: [20]u8 = @splat(0);
    const with_header = tables_test(&frame, &hdr);
    var without_header = with_header;
    without_header.hdr = &.{};
    for ([_]Tables{ with_header, without_header }) |tables| {
        const entry = tables.rule(0x1000).?;
        try std.testing.expectEqual(register_sp, entry.cfa_register);
        try std.testing.expectEqual(8, entry.cfa_offset);
        try std.testing.expectEqual(Saved{ .offset = -8 }, entry.ra);
        try std.testing.expectEqual(Saved.same, entry.bp);
        const pushed = tables.rule(0x1001).?;
        try std.testing.expectEqual(16, pushed.cfa_offset);
        try std.testing.expectEqual(Saved{ .offset = -16 }, pushed.bp);
        const moved = tables.rule(0x100a).?;
        try std.testing.expectEqual(register_bp, moved.cfa_register);
        try std.testing.expectEqual(16, moved.cfa_offset);
        try std.testing.expectEqual(Saved{ .offset = -16 }, moved.bp);
        try std.testing.expectEqual(null, tables.rule(0x1010)); // Past the FDE's range.
        try std.testing.expectEqual(null, tables.rule(0x0fff));
    }
}

test "leb128" {
    var reader: Reader = .{ .bytes = &.{ 0xe5, 0x8e, 0x26, 0x78, 0x7f, 0x80, 0x7f }, .at = 0, .address = 0 };
    try std.testing.expectEqual(624485, try reader.uleb());
    try std.testing.expectEqual(-8, try reader.sleb());
    try std.testing.expectEqual(-1, try reader.sleb());
    try std.testing.expectEqual(-128, try reader.sleb());
}
