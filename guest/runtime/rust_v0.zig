// SPDX-License-Identifier: MIT
//! Rust's v0 symbol names (RFC 2603, `-C symbol-mangling-version=v0`: `_R...`) read as Rust
//! writes the path, as llvm-cxxfilt and rustc-demangle print them:
//! `<turso_core::io::unix::UnixIO as turso_core::io::IO>::step`, crate disambiguators left out,
//! generic arguments as `::<...>` on a value path and `<...>` in a type, closures and shims as
//! `{closure#N}`. Paths, impls, generic arguments, types, constants, function types, `dyn`
//! bounds and backreferences. Null for a name it cannot read (kept as it is, where.zig).
//! Checked against llvm-cxxfilt on Turso's 18,645 v0 symbols (tests below hold a sample).
const std = @import("std");

/// Nesting deeper than this is not read: a name crafted to recurse (backreferences into
/// themselves are refused besides).
const depth_max = 200;

pub fn demangle(arena: std.mem.Allocator, mangled: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, mangled, "_R")) return null;
    var printer: Printer = .{ .arena = arena, .symbol = mangled[2..] };
    // An encoding version would come first (a decimal number): none is defined yet.
    if (printer.peek()) |c| if (std.ascii.isDigit(c)) return null;
    printer.path(true) catch return null;
    // The instantiating crate (a path) is not part of the name; a vendor suffix after `.` (an
    // LLVM clone's `.0`) is said after it, as llvm-cxxfilt says it: `log::LOGGER (.0)`.
    if (printer.peek()) |c| if (c != '.') printer.skipPath() catch return null;
    if (printer.peek() == '.') printer.printf(" ({s})", .{printer.symbol[printer.at..]}) catch return null;
    return printer.out.items;
}

const Error = error{ Invalid, OutOfMemory };

const Printer = struct {
    arena: std.mem.Allocator,
    symbol: []const u8,
    at: usize = 0,
    out: std.ArrayList(u8) = .empty,
    depth: u32 = 0,
    /// Lifetimes bound by `for<...>` binders so far (named 'a, 'b, ... by depth).
    bound: u32 = 0,

    fn peek(p: *Printer) ?u8 {
        return if (p.at < p.symbol.len) p.symbol[p.at] else null;
    }

    fn eat(p: *Printer, c: u8) bool {
        if (p.peek() != c) return false;
        p.at += 1;
        return true;
    }

    fn next(p: *Printer) Error!u8 {
        const c = p.peek() orelse return error.Invalid;
        p.at += 1;
        return c;
    }

    fn print(p: *Printer, text: []const u8) Error!void {
        try p.out.appendSlice(p.arena, text);
    }

    fn printf(p: *Printer, comptime format: []const u8, arguments: anytype) Error!void {
        try p.out.print(p.arena, format, arguments);
    }

    fn enter(p: *Printer) Error!void {
        p.depth += 1;
        if (p.depth > depth_max) return error.Invalid;
    }

    /// base-62-number: `_` is 0, else the digits' value plus one.
    fn base62(p: *Printer) Error!u64 {
        if (p.eat('_')) return 0;
        var value: u64 = 0;
        while (true) {
            const c = try p.next();
            if (c == '_') break;
            const digit: u64 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'z' => 10 + @as(u64, c - 'a'),
                'A'...'Z' => 36 + @as(u64, c - 'A'),
                else => return error.Invalid,
            };
            value = std.math.mul(u64, value, 62) catch return error.Invalid;
            value = std.math.add(u64, value, digit) catch return error.Invalid;
        }
        return std.math.add(u64, value, 1) catch error.Invalid;
    }

    /// An optional `<tag>` base-62 number: 0 when absent, else its value plus one.
    fn optional62(p: *Printer, tag: u8) Error!u64 {
        if (!p.eat(tag)) return 0;
        return std.math.add(u64, try p.base62(), 1) catch error.Invalid;
    }

    fn decimal(p: *Printer) Error!usize {
        const first = try p.next();
        if (!std.ascii.isDigit(first)) return error.Invalid;
        if (first == '0') return 0;
        var value: usize = first - '0';
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.at += 1;
            value = std.math.mul(usize, value, 10) catch return error.Invalid;
            value = std.math.add(usize, value, c - '0') catch return error.Invalid;
        }
        return value;
    }

    const Identifier = struct { text: []const u8, punycode: bool };

    /// undisambiguated-identifier: [`u`] length [`_`] bytes (the `_` when the bytes start with
    /// a digit or an underscore).
    fn identifier(p: *Printer) Error!Identifier {
        const punycode = p.eat('u');
        const length = try p.decimal();
        _ = p.eat('_');
        if (length > p.symbol.len - p.at) return error.Invalid;
        const text = p.symbol[p.at..][0..length];
        p.at += length;
        return .{ .text = text, .punycode = punycode };
    }

    fn printIdentifier(p: *Printer, found: Identifier) Error!void {
        if (!found.punycode) return p.print(found.text);
        // A non-ASCII name (rare): its Punycode form, marked as such.
        try p.printf("punycode{{{s}}}", .{found.text});
    }

    /// A backreference: what was written at an earlier offset, read again there.
    fn backref(p: *Printer, comptime what: enum { path, type, constant }, in_value: bool) Error!void {
        const start = p.at - 1; // Its `B`.
        const target = try p.base62();
        if (target >= start) return error.Invalid;
        const resume_at = p.at;
        p.at = @intCast(target);
        switch (what) {
            .path => try p.path(in_value),
            .type => try p.typeOf(),
            .constant => try p.constant(),
        }
        p.at = resume_at;
    }

    /// A path read but not printed (an impl's own path: where it is defined, not shown).
    fn skipPath(p: *Printer) Error!void {
        const kept = p.out;
        p.out = .empty;
        defer p.out = kept;
        try p.path(false);
    }

    fn path(p: *Printer, in_value: bool) Error!void {
        try p.enter();
        defer p.depth -= 1;
        switch (try p.next()) {
            'C' => {
                _ = try p.optional62('s');
                try p.printIdentifier(try p.identifier());
            },
            'M' => {
                _ = try p.optional62('s');
                try p.skipPath();
                try p.print("<");
                try p.typeOf();
                try p.print(">");
            },
            'X' => {
                _ = try p.optional62('s');
                try p.skipPath();
                try p.print("<");
                try p.typeOf();
                try p.print(" as ");
                try p.path(false);
                try p.print(">");
            },
            'Y' => {
                try p.print("<");
                try p.typeOf();
                try p.print(" as ");
                try p.path(false);
                try p.print(">");
            },
            'N' => {
                const namespace = try p.next();
                if (!std.ascii.isAlphabetic(namespace)) return error.Invalid;
                try p.path(in_value);
                const disambiguator = try p.optional62('s');
                const name = try p.identifier();
                if (std.ascii.isUpper(namespace)) {
                    try p.print("::{");
                    switch (namespace) {
                        'C' => try p.print("closure"),
                        'S' => try p.print("shim"),
                        else => try p.printf("{c}", .{namespace}),
                    }
                    if (name.text.len > 0) {
                        try p.print(":");
                        try p.printIdentifier(name);
                    }
                    try p.printf("#{d}}}", .{disambiguator});
                } else if (name.text.len > 0) {
                    try p.print("::");
                    try p.printIdentifier(name);
                }
            },
            'I' => {
                try p.path(in_value);
                if (in_value) try p.print("::");
                try p.print("<");
                var count: usize = 0;
                while (!p.eat('E')) : (count += 1) {
                    if (count > 0) try p.print(", ");
                    try p.genericArgument();
                }
                try p.print(">");
            },
            'B' => try p.backref(.path, in_value),
            else => return error.Invalid,
        }
    }

    fn genericArgument(p: *Printer) Error!void {
        if (p.eat('L')) return p.lifetime(try p.base62());
        if (p.eat('K')) return p.constant();
        return p.typeOf();
    }

    /// A lifetime by its index: 0 is erased (`'_`), else counted back from the binders so far.
    fn lifetime(p: *Printer, index: u64) Error!void {
        if (index == 0) return p.print("'_");
        if (index > p.bound) return error.Invalid;
        const depth = p.bound - @as(u32, @intCast(index));
        if (depth < 26) return p.printf("'{c}", .{@as(u8, 'a') + @as(u8, @intCast(depth))});
        try p.printf("'_{d}", .{depth});
    }

    fn basic(c: u8) ?[]const u8 {
        return switch (c) {
            'a' => "i8",
            'b' => "bool",
            'c' => "char",
            'd' => "f64",
            'e' => "str",
            'f' => "f32",
            'h' => "u8",
            'i' => "isize",
            'j' => "usize",
            'l' => "i32",
            'm' => "u32",
            'n' => "i128",
            'o' => "u128",
            's' => "i16",
            't' => "u16",
            'u' => "()",
            'v' => "...",
            'x' => "i64",
            'y' => "u64",
            'z' => "!",
            'p' => "_",
            else => null,
        };
    }

    fn typeOf(p: *Printer) Error!void {
        try p.enter();
        defer p.depth -= 1;
        const c = try p.next();
        if (basic(c)) |name| return p.print(name);
        switch (c) {
            'R', 'Q' => {
                try p.print("&");
                if (p.eat('L')) {
                    const index = try p.base62();
                    if (index != 0) {
                        try p.lifetime(index);
                        try p.print(" ");
                    }
                }
                if (c == 'Q') try p.print("mut ");
                try p.typeOf();
            },
            'P' => {
                try p.print("*const ");
                try p.typeOf();
            },
            'O' => {
                try p.print("*mut ");
                try p.typeOf();
            },
            'A' => {
                try p.print("[");
                try p.typeOf();
                try p.print("; ");
                try p.constant();
                try p.print("]");
            },
            'S' => {
                try p.print("[");
                try p.typeOf();
                try p.print("]");
            },
            'T' => {
                try p.print("(");
                var count: usize = 0;
                while (!p.eat('E')) : (count += 1) {
                    if (count > 0) try p.print(", ");
                    try p.typeOf();
                }
                if (count == 1) try p.print(",");
                try p.print(")");
            },
            'F' => try p.functionType(),
            'D' => try p.dynamic(),
            'B' => try p.backref(.type, false),
            else => {
                p.at -= 1;
                try p.path(false);
            },
        }
    }

    /// `for<'a, ...> ` when a binder comes first: its lifetimes counted in.
    fn binder(p: *Printer) Error!u32 {
        const count = try p.optional62('G');
        if (count == 0) return 0;
        const bound: u32 = std.math.cast(u32, count) orelse return error.Invalid;
        try p.print("for<");
        for (0..bound) |index| {
            if (index > 0) try p.print(", ");
            p.bound += 1;
            try p.lifetime(1);
        }
        try p.print("> ");
        return bound;
    }

    fn functionType(p: *Printer) Error!void {
        const bound = try p.binder();
        defer p.bound -= bound;
        if (p.eat('U')) try p.print("unsafe ");
        if (p.eat('K')) {
            if (p.eat('C')) {
                try p.print("extern \"C\" ");
            } else {
                const abi = try p.identifier();
                try p.print("extern \"");
                for (abi.text) |c| try p.out.append(p.arena, if (c == '_') '-' else c);
                try p.print("\" ");
            }
        }
        try p.print("fn(");
        var count: usize = 0;
        while (!p.eat('E')) : (count += 1) {
            if (count > 0) try p.print(", ");
            try p.typeOf();
        }
        try p.print(")");
        if (p.eat('u')) return; // `-> ()` left out.
        try p.print(" -> ");
        try p.typeOf();
    }

    fn dynamic(p: *Printer) Error!void {
        try p.print("dyn ");
        const bound = try p.binder();
        defer p.bound -= bound;
        var count: usize = 0;
        while (!p.eat('E')) : (count += 1) {
            if (count > 0) try p.print(" + ");
            try p.dynamicTrait();
        }
        // The object's own lifetime bound: printed only when named.
        if (!p.eat('L')) return error.Invalid;
        const index = try p.base62();
        if (index != 0) {
            try p.print(" + ");
            try p.lifetime(index);
        }
    }

    /// A trait of a `dyn`: its path, then its associated types' bindings among its generic
    /// arguments (`Iterator<Item = u8>`).
    fn dynamicTrait(p: *Printer) Error!void {
        const open = try p.pathMaybeOpen();
        var count: usize = 0;
        while (p.eat('p')) : (count += 1) {
            if (count == 0 and !open) try p.print("<") else try p.print(", ");
            try p.printIdentifier(try p.identifier());
            try p.print(" = ");
            try p.typeOf();
        }
        if (open or count > 0) try p.print(">");
    }

    /// A path as a type, its closing `>` left for the caller when it ends in generic arguments
    /// (so associated bindings join them): whether it did.
    fn pathMaybeOpen(p: *Printer) Error!bool {
        if (p.peek() == 'I') {
            p.at += 1;
            try p.path(false);
            try p.print("<");
            var count: usize = 0;
            while (!p.eat('E')) : (count += 1) {
                if (count > 0) try p.print(", ");
                try p.genericArgument();
            }
            return true;
        }
        if (p.peek() == 'B') {
            // A backreference to an `I...` path keeps the same shape.
            const start = p.at;
            p.at += 1;
            const target = try p.base62();
            if (target >= start) return error.Invalid;
            const resume_at = p.at;
            p.at = @intCast(target);
            const open = try p.pathMaybeOpen();
            p.at = resume_at;
            return open;
        }
        try p.path(false);
        return false;
    }

    fn constant(p: *Printer) Error!void {
        try p.enter();
        defer p.depth -= 1;
        if (p.eat('p')) return p.print("_");
        if (p.eat('B')) return p.backref(.constant, false);
        const kind = try p.next();
        const negative = p.eat('n');
        const digits_at = p.at;
        while (p.peek()) |c| {
            if (c == '_') break;
            if (!std.ascii.isHex(c)) return error.Invalid;
            p.at += 1;
        }
        const digits = p.symbol[digits_at..p.at];
        if (!p.eat('_')) return error.Invalid;
        const value: u128 = if (digits.len == 0) 0 else std.fmt.parseInt(u128, digits, 16) catch return error.Invalid;
        switch (kind) {
            'b' => try p.print(if (value != 0) "true" else "false"),
            'c' => {
                const code: u21 = std.math.cast(u21, value) orelse return error.Invalid;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(code, &buffer) catch return error.Invalid;
                try p.printf("'{s}'", .{buffer[0..length]});
            },
            'a', 'h', 'i', 'j', 'l', 'm', 'n', 'o', 's', 't', 'x', 'y' => try p.printf("{s}{d}", .{ if (negative) "-" else "", value }),
            else => return error.Invalid,
        }
    }
};

test "v0 names read as llvm-cxxfilt prints them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "_RNvXs0_NtNtCs52BZkLu9GJS_10turso_core2io4unixNtB5_6UnixIONtB7_2IO4step", "<turso_core::io::unix::UnixIO as turso_core::io::IO>::step" },
        .{ "_RNvMsg_NtNtCs52BZkLu9GJS_10turso_core7storage5btreeNtB5_11BTreeCursor16balance_non_root", "<turso_core::storage::btree::BTreeCursor>::balance_non_root" },
        .{ "_RINvCs1EkzfkbpQvj_6subtle9black_boxhECs52BZkLu9GJS_10turso_core", "subtle::black_box::<u8>" },
        .{ "_RINvMsi_NtCs52BZkLu9GJS_10turso_core4vdbeNtB6_7Program23maybe_request_interruptDNtNtB8_2io2IOEL_EB8_", "<turso_core::vdbe::Program>::maybe_request_interrupt::<dyn turso_core::io::IO>" },
        .{ "_RINvMNtNtCsDd5LsGeNsU_12regex_syntax3ast5parseNtB3_9Primitive18into_class_literalQNtB3_6ParserEB7_", "<regex_syntax::ast::parse::Primitive>::into_class_literal::<&mut regex_syntax::ast::parse::Parser>" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], demangle(arena, case[0]) orelse "(null)");
    try std.testing.expect(demangle(arena, "_ZN3foo3barE") == null);
    try std.testing.expect(demangle(arena, "_RNvB0_3foo") == null); // A backreference to itself.
}
