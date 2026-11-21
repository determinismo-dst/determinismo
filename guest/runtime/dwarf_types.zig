// SPDX-License-Identifier: MIT
//! A global variable's type from its module's DWARF, and a field of it by its path
//! (`stats.accepted`, `table[3].key`): its offset from the variable's start, its size and what
//! kind of value it is, for `det-nodes symbol --field` (a session's watch on a field, its value
//! read as its type: docs/DEBUGGING.md). .debug_info's units (DWARF 2 to 5) walked once for the
//! variable (by its name or its linkage name), then its type followed: typedefs and qualifiers,
//! structures, classes and unions by their members, arrays by an index. A pointer is a value
//! here, never followed (that would read the process's memory). Sections read whole, bounded.
//! A function's parameters too (`det-nodes symbol` of a function: `calls` says its arguments by
//! name and type): its defining entry's formal parameters, in order.
const std = @import("std");
const assert = std.debug.assert;
const DW = std.dwarf;

pub const Kind = enum { signed, unsigned, float, boolean, pointer, aggregate, other };

pub const Field = struct {
    /// From the variable's first byte.
    offset: u64,
    size: u64,
    kind: Kind,
    /// The type's name as the module says it (empty when it has none: an anonymous struct).
    name: []const u8,
};

pub const Sections = struct {
    info: []const u8,
    abbrev: []const u8,
    str: []const u8 = "",
    line_str: []const u8 = "",
    str_offsets: []const u8 = "",
};

pub const Error = error{ NoSuchField, NotAnAggregate, NotAnArray, IndexOutOfRange, BadPath, InvalidDebugInfo, OutOfMemory };

/// The field `path` (empty: the variable itself) of the global variable `variable`, or null when
/// the module's DWARF does not describe the variable.
pub fn resolve(arena: std.mem.Allocator, sections: Sections, variable: []const u8, path: []const u8) Error!?Field {
    var types: Types = .{ .arena = arena, .sections = sections };
    try types.units_scan();
    const found = (try types.variable_find(variable)) orelse return null;
    return try types.walk(found, path);
}

/// The field `path` of the type named `type_name` (a structure, class, union or typedef: Go's
/// `github.com/hashicorp/raft.followerReplication`, C's `struct conn`'s `conn`), its offset from
/// the type's start: what a pointer to one points at, for `det-nodes hold --arg-field` (a thread
/// held only when a field behind its argument says so). Null when the module's DWARF has no type
/// of that name.
pub fn member_of(arena: std.mem.Allocator, sections: Sections, type_name: []const u8, path: []const u8) Error!?Field {
    var types: Types = .{ .arena = arena, .sections = sections };
    try types.units_scan();
    const found = (try types.type_find(type_name)) orelse return null;
    return try types.walk(found, path);
}

fn resolve_walk(types: *Types, found: u64, path: []const u8) Error!Field {
    var place: Field = try types.type_of(found);
    var type_offset = found;
    var steps = Steps{ .text = path };
    while (try steps.next()) |step| {
        const aggregate = try types.underlying(type_offset);
        switch (step) {
            .member => |name| {
                const member = (try types.member_find(aggregate, name)) orelse return error.NoSuchField;
                place.offset += member.offset;
                type_offset = member.type_offset;
            },
            .index => |index| {
                const array = try types.array_of(aggregate);
                if (array.count) |count| if (index >= count) return error.IndexOutOfRange;
                place.offset += index * array.element_size;
                type_offset = array.element;
            },
        }
        const typed = try types.type_of(type_offset);
        place.size = typed.size;
        place.kind = typed.kind;
        place.name = typed.name;
    }
    return place;
}

pub const Parameter = struct {
    /// Empty when the module does not name it.
    name: []const u8,
    size: u64,
    kind: Kind,
    /// Its type's name.
    type_name: []const u8,
};

/// The parameters of the function `function` (its name or linkage name), in order, from its
/// defining entry (one with code; an inlined-only or declared-only one is not it), names and
/// types through the entry it completes or instantiates; null when the module's DWARF has no
/// definition of it.
pub fn parameters(arena: std.mem.Allocator, sections: Sections, function: []const u8) Error!?[]const Parameter {
    var types: Types = .{ .arena = arena, .sections = sections };
    try types.units_scan();
    const found = (try types.function_find(function)) orelse return null;
    const unit = try types.unit_of(found.offset);
    var listed: std.ArrayList(Parameter) = .empty;
    if (!found.children) return listed.items;
    var at = found.next;
    var depth: u32 = 0;
    while (at < unit.end) {
        const die = try types.die_at(unit, at);
        at = die.next;
        if (die.tag == 0) {
            if (depth == 0) break; // The function's children ended.
            depth -= 1;
            continue;
        }
        if (depth == 0 and die.tag == DW.TAG.formal_parameter) {
            var name = die.name;
            var type_offset = die.type;
            if (die.specification) |origin| {
                const original = try types.die_at(try types.unit_of(origin), origin);
                name = name orelse original.name;
                type_offset = type_offset orelse original.type;
            }
            const typed: Field = if (type_offset) |offset| try types.type_of(offset) else .{ .offset = 0, .size = 0, .kind = .other, .name = "" };
            try listed.append(arena, .{ .name = name orelse "", .size = typed.size, .kind = typed.kind, .type_name = typed.name });
        }
        if (die.children) depth += 1;
    }
    return listed.items;
}

/// A path's steps: `.name` a member, `[n]` an index; the first member needs no dot.
const Steps = struct {
    text: []const u8,
    at: usize = 0,

    const Step = union(enum) { member: []const u8, index: u64 };

    fn next(steps: *Steps) Error!?Step {
        const text = steps.text;
        if (steps.at >= text.len) return null;
        if (text[steps.at] == '[') {
            const end = std.mem.indexOfScalarPos(u8, text, steps.at, ']') orelse return error.BadPath;
            const index = std.fmt.parseInt(u64, text[steps.at + 1 .. end], 0) catch return error.BadPath;
            steps.at = end + 1;
            return .{ .index = index };
        }
        if (text[steps.at] == '.') steps.at += 1;
        const start = steps.at;
        while (steps.at < text.len and text[steps.at] != '.' and text[steps.at] != '[') steps.at += 1;
        if (steps.at == start) return error.BadPath;
        return .{ .member = text[start..steps.at] };
    }
};

test Steps {
    var steps = Steps{ .text = "stats.table[3].key" };
    try std.testing.expectEqualStrings("stats", (try steps.next()).?.member);
    try std.testing.expectEqualStrings("table", (try steps.next()).?.member);
    try std.testing.expectEqual(@as(u64, 3), (try steps.next()).?.index);
    try std.testing.expectEqualStrings("key", (try steps.next()).?.member);
    try std.testing.expectEqual(@as(?Steps.Step, null), try steps.next());
    var bad = Steps{ .text = "a[x]" };
    _ = try bad.next();
    try std.testing.expectError(error.BadPath, bad.next());
}

const Unit = struct {
    /// Its header's offset in .debug_info, and its end.
    start: u64,
    end: u64,
    /// Its first DIE's offset.
    dies: u64,
    version: u16,
    address_size: u8,
    offset_size: u8,
    abbrev_offset: u64,
    str_offsets_base: u64 = 0,
};

const Attribute = struct { name: u64, form: u64, implicit: i64 };
const Abbrev = struct { tag: u64, children: bool, attributes: []const Attribute };
const Table = std.AutoHashMapUnmanaged(u64, Abbrev);

const Value = union(enum) {
    number: u64,
    signed: i64,
    text: []const u8,
    /// An offset in .debug_info.
    reference: u64,
    block: []const u8,
    none,
};

const Die = struct {
    offset: u64,
    tag: u64,
    children: bool,
    /// Where its first child (or next sibling) begins.
    next: u64,
    name: ?[]const u8 = null,
    linkage_name: ?[]const u8 = null,
    type: ?u64 = null,
    specification: ?u64 = null,
    byte_size: ?u64 = null,
    encoding: ?u64 = null,
    member_location: ?Value = null,
    count: ?u64 = null,
    upper_bound: ?u64 = null,
    declaration: bool = false,
    /// It has code (low_pc or ranges): a function's definition, not only its declaration or
    /// its abstract (inlined) instance.
    code: bool = false,
    str_offsets_base: ?u64 = null,
};

const Types = struct {
    arena: std.mem.Allocator,
    sections: Sections,
    units: std.ArrayList(Unit) = .empty,
    tables: std.AutoHashMapUnmanaged(u64, Table) = .empty,

    fn units_scan(types: *Types) Error!void {
        const info = types.sections.info;
        var at: u64 = 0;
        while (at + 11 <= info.len) {
            var reader = Reader{ .bytes = info, .at = @intCast(at) };
            var length: u64 = try reader.fixed(u32);
            var offset_size: u8 = 4;
            if (length == 0xffff_ffff) {
                length = try reader.fixed(u64);
                offset_size = 8;
            }
            const end = reader.at + length;
            if (end > info.len or length < 7) return error.InvalidDebugInfo;
            const version = try reader.fixed(u16);
            if (version < 2 or version > 5) return error.InvalidDebugInfo;
            var unit: Unit = .{ .start = at, .end = end, .dies = 0, .version = version, .address_size = 8, .offset_size = offset_size, .abbrev_offset = 0 };
            var kind: u8 = DW.UT.compile;
            if (version >= 5) {
                kind = try reader.byte();
                unit.address_size = try reader.byte();
                unit.abbrev_offset = try reader.sized(offset_size);
                // Skeleton and split units carry an id; type units a signature and an offset.
                switch (kind) {
                    DW.UT.skeleton, DW.UT.split_compile => try reader.skip(8),
                    DW.UT.type, DW.UT.split_type => try reader.skip(8 + offset_size),
                    else => {},
                }
            } else {
                unit.abbrev_offset = try reader.sized(offset_size);
                unit.address_size = try reader.byte();
            }
            unit.dies = reader.at;
            at = end;
            if (kind != DW.UT.compile and kind != DW.UT.partial) continue;
            // The unit's own DIE says where its indexed strings are (DWARF 5).
            if (unit.dies < unit.end) {
                const first = try types.die_at(&unit, unit.dies);
                if (first.str_offsets_base) |base| unit.str_offsets_base = base;
            }
            try types.units.append(types.arena, unit);
        }
    }

    /// The unit a .debug_info offset is in.
    fn unit_of(types: *Types, offset: u64) Error!*Unit {
        for (types.units.items) |*unit| {
            if (offset >= unit.dies and offset < unit.end) return unit;
        }
        return error.InvalidDebugInfo;
    }

    fn table_of(types: *Types, offset: u64) Error!*const Table {
        const known = try types.tables.getOrPut(types.arena, offset);
        if (known.found_existing) return known.value_ptr;
        known.value_ptr.* = .empty;
        var reader = Reader{ .bytes = types.sections.abbrev, .at = @intCast(offset) };
        while (true) {
            const code = try reader.uleb();
            if (code == 0) break;
            const tag = try reader.uleb();
            const children = (try reader.byte()) != 0;
            var attributes: std.ArrayList(Attribute) = .empty;
            while (true) {
                const name = try reader.uleb();
                const form = try reader.uleb();
                if (name == 0 and form == 0) break;
                const implicit = if (form == DW.FORM.implicit_const) try reader.sleb() else 0;
                try attributes.append(types.arena, .{ .name = name, .form = form, .implicit = implicit });
            }
            try known.value_ptr.put(types.arena, code, .{ .tag = tag, .children = children, .attributes = attributes.items });
        }
        return known.value_ptr;
    }

    /// The DIE at `offset` with the attributes this file reads; null for a null entry (the
    /// end of a run of siblings), whose `next` is offset + 1.
    fn die_at(types: *Types, unit: *const Unit, offset: u64) Error!Die {
        var reader = Reader{ .bytes = types.sections.info, .at = @intCast(offset) };
        if (offset >= unit.end) return error.InvalidDebugInfo;
        const code = try reader.uleb();
        if (code == 0) return .{ .offset = offset, .tag = 0, .children = false, .next = reader.at };
        const table = try types.table_of(unit.abbrev_offset);
        const abbrev = table.get(code) orelse return error.InvalidDebugInfo;
        var die: Die = .{ .offset = offset, .tag = abbrev.tag, .children = abbrev.children, .next = 0 };
        for (abbrev.attributes) |attribute| {
            const value = try types.form_read(&reader, unit, attribute.form, attribute.implicit);
            switch (attribute.name) {
                DW.AT.name => die.name = types.text_of(unit, value),
                DW.AT.linkage_name, DW.AT.MIPS_linkage_name => die.linkage_name = types.text_of(unit, value),
                DW.AT.type => die.type = reference_of(value),
                DW.AT.specification, DW.AT.abstract_origin => die.specification = reference_of(value),
                DW.AT.byte_size => die.byte_size = number_of(value),
                DW.AT.encoding => die.encoding = number_of(value),
                DW.AT.data_member_location => die.member_location = value,
                DW.AT.count => die.count = number_of(value),
                DW.AT.upper_bound => die.upper_bound = number_of(value),
                DW.AT.declaration => die.declaration = true,
                DW.AT.low_pc, DW.AT.ranges => die.code = true,
                DW.AT.str_offsets_base => die.str_offsets_base = number_of(value),
                else => {},
            }
        }
        die.next = reader.at;
        return die;
    }

    fn text_of(types: *Types, unit: *const Unit, value: Value) ?[]const u8 {
        return switch (value) {
            .text => |text| text,
            // An indexed string (DWARF 5's strx): through the unit's string offsets.
            .number => |index| blk: {
                const at = unit.str_offsets_base + index * unit.offset_size;
                if (at + unit.offset_size > types.sections.str_offsets.len) break :blk null;
                var reader = Reader{ .bytes = types.sections.str_offsets, .at = @intCast(at) };
                const offset = reader.sized(unit.offset_size) catch break :blk null;
                break :blk string_at(types.sections.str, offset);
            },
            else => null,
        };
    }

    /// A form's value; a string index (strx) as its number, read by text_of.
    fn form_read(types: *Types, reader: *Reader, unit: *const Unit, form: u64, implicit: i64) Error!Value {
        const F = DW.FORM;
        const sections = types.sections;
        return switch (form) {
            F.addr => .{ .number = try reader.sized(unit.address_size) },
            F.data1, F.ref1, F.flag, F.strx1, F.addrx1 => blk: {
                const number: u64 = try reader.byte();
                break :blk if (form == F.ref1) .{ .reference = unit.start + number } else .{ .number = number };
            },
            F.data2, F.ref2, F.strx2, F.addrx2 => blk: {
                const number: u64 = try reader.fixed(u16);
                break :blk if (form == F.ref2) .{ .reference = unit.start + number } else .{ .number = number };
            },
            F.strx3, F.addrx3 => blk: {
                const low: u64 = try reader.fixed(u16);
                const high: u64 = try reader.byte();
                break :blk .{ .number = low | high << 16 };
            },
            F.data4, F.ref4, F.strx4, F.addrx4, F.ref_sup4 => blk: {
                const number: u64 = try reader.fixed(u32);
                break :blk if (form == F.ref4) .{ .reference = unit.start + number } else .{ .number = number };
            },
            F.data8, F.ref8, F.ref_sig8, F.ref_sup8 => blk: {
                const number = try reader.fixed(u64);
                break :blk if (form == F.ref8) .{ .reference = unit.start + number } else .{ .number = number };
            },
            F.data16 => blk: {
                try reader.skip(16);
                break :blk .none;
            },
            F.sdata => .{ .signed = try reader.sleb() },
            F.udata, F.strx, F.addrx, F.loclistx, F.rnglistx => .{ .number = try reader.uleb() },
            F.ref_udata => .{ .reference = unit.start + try reader.uleb() },
            F.ref_addr => .{ .reference = try reader.sized(if (unit.version <= 2) unit.address_size else unit.offset_size) },
            F.sec_offset => .{ .number = try reader.sized(unit.offset_size) },
            F.string => .{ .text = try reader.string() },
            F.strp, F.strp_sup => .{ .text = string_at(sections.str, try reader.sized(unit.offset_size)) orelse "" },
            F.line_strp => .{ .text = string_at(sections.line_str, try reader.sized(unit.offset_size)) orelse "" },
            F.flag_present => .{ .number = 1 },
            F.implicit_const => .{ .signed = implicit },
            F.exprloc, F.block => .{ .block = try reader.block(try reader.uleb()) },
            F.block1 => .{ .block = try reader.block(try reader.byte()) },
            F.block2 => .{ .block = try reader.block(try reader.fixed(u16)) },
            F.block4 => .{ .block = try reader.block(try reader.fixed(u32)) },
            F.indirect => types.form_read(reader, unit, try reader.uleb(), implicit),
            else => error.InvalidDebugInfo,
        };
    }

    /// The type offset of the global variable named `name` (its name or its linkage name; a
    /// definition's, through the declaration it completes when that carries the type).
    fn walk(types: *Types, found: u64, path: []const u8) Error!Field {
        return resolve_walk(types, found, path);
    }

    /// A type by its name: a structure's, class's or union's definition, or a typedef's; the
    /// one so named (Go's carry their package path: `github.com/hashicorp/raft.followerReplication`),
    /// else the first named by the name's last segment (Zig's own DWARF names `hold.TestPeer`
    /// `TestPeer` under its file's entry, C++ `ns::conn` `conn` under its namespace's).
    fn type_find(types: *Types, name: []const u8) Error!?u64 {
        if (try types.type_named(name)) |found| return found;
        const dot = if (std.mem.lastIndexOfScalar(u8, name, '.')) |at| at + 1 else 0;
        const colons = if (std.mem.lastIndexOf(u8, name, "::")) |at| at + 2 else 0;
        const last = name[@max(dot, colons)..];
        if (last.len == 0 or last.len == name.len) return null;
        return try types.type_named(last);
    }

    fn type_named(types: *Types, name: []const u8) Error!?u64 {
        for (types.units.items) |*unit| {
            var at = unit.dies;
            while (at < unit.end) {
                const die = try types.die_at(unit, at);
                at = die.next;
                switch (die.tag) {
                    DW.TAG.structure_type, DW.TAG.class_type, DW.TAG.union_type, DW.TAG.typedef => {},
                    else => continue,
                }
                if (die.declaration) continue;
                const named = die.name orelse continue;
                if (std.mem.eql(u8, named, name)) return die.offset;
            }
        }
        return null;
    }

    fn variable_find(types: *Types, name: []const u8) Error!?u64 {
        for (types.units.items) |*unit| {
            var at = unit.dies;
            while (at < unit.end) {
                const die = try types.die_at(unit, at);
                at = die.next;
                if (die.tag != DW.TAG.variable or die.declaration) continue;
                var named = die.name;
                var linkage = die.linkage_name;
                var type_offset = die.type;
                if (die.specification) |declared| {
                    const declaration = try types.die_at(try types.unit_of(declared), declared);
                    named = named orelse declaration.name;
                    linkage = linkage orelse declaration.linkage_name;
                    type_offset = type_offset orelse declaration.type;
                }
                const matches = (named != null and std.mem.eql(u8, named.?, name)) or
                    (linkage != null and std.mem.eql(u8, linkage.?, name));
                if (matches) if (type_offset) |found| return found;
            }
        }
        return null;
    }

    /// The defining entry of the function named `name` (its name or linkage name, its own or
    /// that of the entry it completes or instantiates): the first with code.
    fn function_find(types: *Types, name: []const u8) Error!?Die {
        for (types.units.items) |*unit| {
            var at = unit.dies;
            while (at < unit.end) {
                const die = try types.die_at(unit, at);
                at = die.next;
                if (die.tag != DW.TAG.subprogram or !die.code) continue;
                var named = die.name;
                var linkage = die.linkage_name;
                // A definition's or an instance's names are on its declaration or abstract
                // entry, and that one's may be on its own declaration.
                var origin = die.specification;
                for (0..4) |_| {
                    const offset = origin orelse break;
                    const original = try types.die_at(try types.unit_of(offset), offset);
                    named = named orelse original.name;
                    linkage = linkage orelse original.linkage_name;
                    origin = original.specification;
                }
                const matches = (named != null and std.mem.eql(u8, named.?, name)) or
                    (linkage != null and std.mem.eql(u8, linkage.?, name));
                if (matches) return die;
            }
        }
        return null;
    }

    /// Past typedefs and qualifiers: the type a value of `offset`'s type is.
    fn underlying(types: *Types, offset: u64) Error!Die {
        var at = offset;
        for (0..64) |_| {
            const die = try types.die_at(try types.unit_of(at), at);
            switch (die.tag) {
                DW.TAG.typedef, DW.TAG.const_type, DW.TAG.volatile_type, DW.TAG.restrict_type, DW.TAG.atomic_type => {
                    at = die.type orelse return die;
                },
                else => return die,
            }
        }
        return error.InvalidDebugInfo;
    }

    fn type_of(types: *Types, offset: u64) Error!Field {
        const named = try types.die_at(try types.unit_of(offset), offset);
        const die = try types.underlying(offset);
        const name = named.name orelse die.name orelse "";
        return switch (die.tag) {
            DW.TAG.base_type => .{
                .offset = 0,
                .size = die.byte_size orelse 0,
                .name = name,
                .kind = switch (die.encoding orelse 0) {
                    DW.ATE.signed, DW.ATE.signed_char => .signed,
                    DW.ATE.unsigned, DW.ATE.unsigned_char, DW.ATE.UTF => .unsigned,
                    DW.ATE.float => .float,
                    DW.ATE.boolean => .boolean,
                    else => .other,
                },
            },
            DW.TAG.pointer_type, DW.TAG.reference_type, DW.TAG.rvalue_reference_type, DW.TAG.ptr_to_member_type => .{
                .offset = 0,
                .size = die.byte_size orelse (try types.unit_of(offset)).address_size,
                .name = name,
                .kind = .pointer,
            },
            DW.TAG.enumeration_type => blk: {
                const base = if (die.type) |base| try types.type_of(base) else Field{ .offset = 0, .size = 0, .kind = .signed, .name = "" };
                break :blk .{ .offset = 0, .size = die.byte_size orelse base.size, .name = name, .kind = base.kind };
            },
            DW.TAG.structure_type, DW.TAG.class_type, DW.TAG.union_type => .{
                .offset = 0,
                .size = die.byte_size orelse 0,
                .name = name,
                .kind = .aggregate,
            },
            DW.TAG.array_type => blk: {
                const array = try types.array_of(die);
                const count = array.count orelse 0;
                break :blk .{ .offset = 0, .size = die.byte_size orelse count * array.element_size, .name = name, .kind = .aggregate };
            },
            else => .{ .offset = 0, .size = die.byte_size orelse 0, .name = name, .kind = .other },
        };
    }

    const Member = struct { offset: u64, type_offset: u64 };

    /// A structure's (class's, union's) member by its name: its offset and type. A member of an
    /// anonymous structure or union inside it counts as its own.
    fn member_find(types: *Types, aggregate: Die, name: []const u8) Error!?Member {
        switch (aggregate.tag) {
            DW.TAG.structure_type, DW.TAG.class_type, DW.TAG.union_type => {},
            else => return error.NotAnAggregate,
        }
        if (!aggregate.children) return null;
        const unit = try types.unit_of(aggregate.offset);
        var at = aggregate.next;
        var depth: u32 = 0;
        while (at < unit.end) {
            const die = try types.die_at(unit, at);
            if (die.tag == 0) {
                if (depth == 0) return null; // The aggregate's children ended.
                depth -= 1;
                at = die.next;
                continue;
            }
            if (depth == 0 and die.tag == DW.TAG.member) {
                const offset = location_of(die.member_location) orelse 0;
                if (die.name) |member| {
                    if (std.mem.eql(u8, member, name)) return .{ .offset = offset, .type_offset = die.type orelse return error.InvalidDebugInfo };
                } else if (die.type) |inner_type| {
                    const inner = try types.underlying(inner_type);
                    if (inner.tag == DW.TAG.structure_type or inner.tag == DW.TAG.union_type) {
                        if (try types.member_find(inner, name)) |found| return .{ .offset = offset + found.offset, .type_offset = found.type_offset };
                    }
                }
            }
            if (die.children) depth += 1;
            at = die.next;
        }
        return null;
    }

    const Array = struct { element: u64, element_size: u64, count: ?u64 };

    fn array_of(types: *Types, array: Die) Error!Array {
        if (array.tag != DW.TAG.array_type) return error.NotAnArray;
        const element = array.type orelse return error.InvalidDebugInfo;
        const element_size = (try types.type_of(element)).size;
        var count: ?u64 = null;
        if (array.children) {
            const unit = try types.unit_of(array.offset);
            // Its first subrange: the outermost dimension.
            const first = try types.die_at(unit, array.next);
            if (first.tag == DW.TAG.subrange_type) {
                count = first.count orelse if (first.upper_bound) |bound| bound + 1 else null;
            }
        }
        return .{ .element = element, .element_size = element_size, .count = count };
    }
};

fn reference_of(value: Value) ?u64 {
    return switch (value) {
        .reference => |offset| offset,
        else => null,
    };
}

fn number_of(value: Value) ?u64 {
    return switch (value) {
        .number => |number| number,
        .signed => |signed| if (signed >= 0) @intCast(signed) else null,
        else => null,
    };
}

/// A member's offset: a constant, or DWARF 2's DW_OP_plus_uconst expression.
fn location_of(value: ?Value) ?u64 {
    const known = value orelse return null;
    return switch (known) {
        .number => |number| number,
        .signed => |signed| if (signed >= 0) @intCast(signed) else null,
        .block => |block| blk: {
            if (block.len < 2 or block[0] != DW.OP.plus_uconst) break :blk null;
            var reader = Reader{ .bytes = block, .at = 1 };
            break :blk reader.uleb() catch null;
        },
        else => null,
    };
}

fn string_at(strings: []const u8, offset: u64) ?[]const u8 {
    if (offset >= strings.len) return null;
    return std.mem.sliceTo(strings[@intCast(offset)..], 0);
}

const Reader = struct {
    bytes: []const u8,
    at: usize,

    fn byte(reader: *Reader) Error!u8 {
        if (reader.at >= reader.bytes.len) return error.InvalidDebugInfo;
        defer reader.at += 1;
        return reader.bytes[reader.at];
    }

    fn fixed(reader: *Reader, comptime T: type) Error!T {
        const size = @sizeOf(T);
        if (reader.at + size > reader.bytes.len) return error.InvalidDebugInfo;
        defer reader.at += size;
        return std.mem.readInt(T, reader.bytes[reader.at..][0..size], .little);
    }

    fn sized(reader: *Reader, size: u8) Error!u64 {
        return switch (size) {
            1 => try reader.byte(),
            2 => try reader.fixed(u16),
            4 => try reader.fixed(u32),
            8 => try reader.fixed(u64),
            else => error.InvalidDebugInfo,
        };
    }

    fn skip(reader: *Reader, count: u64) Error!void {
        if (reader.at + count > reader.bytes.len) return error.InvalidDebugInfo;
        reader.at += @intCast(count);
    }

    fn block(reader: *Reader, count: u64) Error![]const u8 {
        if (reader.at + count > reader.bytes.len) return error.InvalidDebugInfo;
        defer reader.at += @intCast(count);
        return reader.bytes[reader.at..][0..@intCast(count)];
    }

    fn string(reader: *Reader) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, reader.bytes, reader.at, 0) orelse return error.InvalidDebugInfo;
        defer reader.at = end + 1;
        return reader.bytes[reader.at..end];
    }

    fn uleb(reader: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try reader.byte();
            if (shift < 64) result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn sleb(reader: *Reader) Error!i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try reader.byte();
            if (shift < 64) result |= @as(i64, b & 0x7f) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) {
                if (shift < 64 and b & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
                return result;
            }
        }
    }
};

// A test variable whose type this file reads back from the test binary's own DWARF.
const TestStats = extern struct { accepted: u64, table: [3]i16, ratio: f64, inner: extern struct { flag: bool, code: i32 } };
export var det_types_test: TestStats = .{ .accepted = 1, .table = .{ 1, 2, 3 }, .ratio = 0.5, .inner = .{ .flag = true, .code = -1 } };

test "a variable's fields by their paths, from this test binary's DWARF" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.mem.doNotOptimizeAway(&det_types_test);
    const sections = (try sections_of_self(arena)) orelse return error.SkipZigTest;
    const whole = (try resolve(arena, sections, "det_types_test", "")).?;
    try std.testing.expectEqual(@as(u64, @sizeOf(TestStats)), whole.size);
    try std.testing.expectEqual(Kind.aggregate, whole.kind);
    const accepted = (try resolve(arena, sections, "det_types_test", "accepted")).?;
    try std.testing.expectEqual(@as(u64, 0), accepted.offset);
    try std.testing.expectEqual(@as(u64, 8), accepted.size);
    try std.testing.expectEqual(Kind.unsigned, accepted.kind);
    const element = (try resolve(arena, sections, "det_types_test", "table[2]")).?;
    try std.testing.expectEqual(@as(u64, @offsetOf(TestStats, "table") + 2 * 2), element.offset);
    try std.testing.expectEqual(@as(u64, 2), element.size);
    try std.testing.expectEqual(Kind.signed, element.kind);
    const ratio = (try resolve(arena, sections, "det_types_test", "ratio")).?;
    try std.testing.expectEqual(@as(u64, @offsetOf(TestStats, "ratio")), ratio.offset);
    try std.testing.expectEqual(Kind.float, ratio.kind);
    const code = (try resolve(arena, sections, "det_types_test", "inner.code")).?;
    try std.testing.expectEqual(@as(u64, @offsetOf(TestStats, "inner") + 4), code.offset);
    try std.testing.expectEqual(Kind.signed, code.kind);
    try std.testing.expectError(error.NoSuchField, resolve(arena, sections, "det_types_test", "missing"));
    try std.testing.expectError(error.IndexOutOfRange, resolve(arena, sections, "det_types_test", "table[3]"));
    try std.testing.expectError(error.NotAnArray, resolve(arena, sections, "det_types_test", "ratio[0]"));
    try std.testing.expectEqual(@as(?Field, null), try resolve(arena, sections, "det_no_such_variable", ""));
}

test "a type's field by its path, from this test binary's DWARF" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.mem.doNotOptimizeAway(&det_types_test);
    const sections = (try sections_of_self(arena)) orelse return error.SkipZigTest;
    const code = (try member_of(arena, sections, "dwarf_types.TestStats", "inner.code")).?;
    try std.testing.expectEqual(@as(u64, @offsetOf(TestStats, "inner") + 4), code.offset);
    try std.testing.expectEqual(Kind.signed, code.kind);
    try std.testing.expectEqual(@as(?Field, null), try member_of(arena, sections, "dwarf_types.NoSuchType", "accepted"));
    try std.testing.expectError(error.NoSuchField, member_of(arena, sections, "dwarf_types.TestStats", "missing"));
}

// A test function whose parameters this file reads back from the test binary's own DWARF.
export fn det_types_test_function(client: i32, ratio: f64, stats: *const TestStats, flag: bool) callconv(.c) u64 {
    return @as(u64, @intCast(@max(client, 0))) + @as(u64, @intFromFloat(@max(ratio, 0))) + stats.accepted + @intFromBool(flag);
}

test "a function's parameters, from this test binary's DWARF" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.mem.doNotOptimizeAway(&det_types_test_function);
    const sections = (try sections_of_self(arena)) orelse return error.SkipZigTest;
    const listed = (try parameters(arena, sections, "det_types_test_function")).?;
    try std.testing.expectEqual(@as(usize, 4), listed.len);
    try std.testing.expectEqualStrings("client", listed[0].name);
    try std.testing.expectEqual(Kind.signed, listed[0].kind);
    try std.testing.expectEqual(@as(u64, 4), listed[0].size);
    try std.testing.expectEqualStrings("ratio", listed[1].name);
    try std.testing.expectEqual(Kind.float, listed[1].kind);
    try std.testing.expectEqual(@as(u64, 8), listed[1].size);
    try std.testing.expectEqualStrings("stats", listed[2].name);
    try std.testing.expectEqual(Kind.pointer, listed[2].kind);
    try std.testing.expectEqualStrings("flag", listed[3].name);
    try std.testing.expectEqual(Kind.boolean, listed[3].kind);
    try std.testing.expectEqual(@as(?[]const Parameter, null), try parameters(arena, sections, "det_no_such_function"));
}

/// This test binary's debug sections (the test reads its own DWARF), or null without them.
fn sections_of_self(arena: std.mem.Allocator) !?Sections {
    const linux = std.os.linux;
    const fd_or_error = linux.open("/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd_or_error) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(fd_or_error);
    defer _ = linux.close(fd);
    return sections_of(arena, fd);
}

/// The DWARF sections of the ELF file `fd` this file reads, or null: no .debug_info (stripped)
/// or a compressed one (SHF_COMPRESSED: not read).
pub fn sections_of(arena: std.mem.Allocator, fd: std.os.linux.fd_t) !?Sections {
    var header: [64]u8 = undefined;
    if (!pread_all(fd, &header, 0)) return null;
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1) return null;
    const sections_at = std.mem.readInt(u64, header[40..48], .little);
    const entry_size = std.mem.readInt(u16, header[58..60], .little);
    const count = std.mem.readInt(u16, header[60..62], .little);
    const names_index = std.mem.readInt(u16, header[62..64], .little);
    if (entry_size < 64 or count == 0 or count > 4096 or names_index >= count) return null;
    const table = try arena.alloc(u8, @as(usize, count) * entry_size);
    if (!pread_all(fd, table, sections_at)) return null;
    const Header = struct { name: u32, flags: u64, offset: u64, size: u64 };
    const at = struct {
        fn f(bytes: []const u8, size: usize, index: usize) Header {
            const entry = bytes[index * size ..][0..64];
            return .{
                .name = std.mem.readInt(u32, entry[0..4], .little),
                .flags = std.mem.readInt(u64, entry[8..16], .little),
                .offset = std.mem.readInt(u64, entry[24..32], .little),
                .size = std.mem.readInt(u64, entry[32..40], .little),
            };
        }
    }.f;
    const names_header = at(table, entry_size, names_index);
    if (names_header.size > 1 << 20) return null;
    const names = try arena.alloc(u8, @intCast(names_header.size));
    if (!pread_all(fd, names, names_header.offset)) return null;
    var sections: Sections = .{ .info = "", .abbrev = "" };
    const shf_compressed = 0x800;
    for (0..count) |index| {
        const section = at(table, entry_size, index);
        if (section.name >= names.len) continue;
        const name = std.mem.sliceTo(names[section.name..], 0);
        const slot: *[]const u8 = if (std.mem.eql(u8, name, ".debug_info"))
            &sections.info
        else if (std.mem.eql(u8, name, ".debug_abbrev"))
            &sections.abbrev
        else if (std.mem.eql(u8, name, ".debug_str"))
            &sections.str
        else if (std.mem.eql(u8, name, ".debug_line_str"))
            &sections.line_str
        else if (std.mem.eql(u8, name, ".debug_str_offsets"))
            &sections.str_offsets
        else
            continue;
        if (section.flags & shf_compressed != 0) return null;
        if (section.size > section_size_max) return null;
        const bytes = try arena.alloc(u8, @intCast(section.size));
        if (!pread_all(fd, bytes, section.offset)) return null;
        slot.* = bytes;
    }
    if (sections.info.len == 0 or sections.abbrev.len == 0) return null;
    return sections;
}

/// The largest debug section read (a large C++ server's .debug_info is hundreds of MB: its
/// variables' types are not looked up).
const section_size_max = 256 << 20;

fn pread_all(fd: std.os.linux.fd_t, buffer: []u8, offset: u64) bool {
    const linux = std.os.linux;
    var done: usize = 0;
    while (done < buffer.len) {
        const count = linux.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (linux.errno(count) != .SUCCESS or count == 0) return false;
        done += count;
    }
    return true;
}
