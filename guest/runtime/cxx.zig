// SPDX-License-Identifier: MIT
//! C++ names as their source writes them (the Itanium ABI's mangling, every Linux compiler's):
//! `ns::Class::method(Type const&, int)`, templates and the substitutions that refer back to
//! earlier parts included, for a crash's or an exit's frames (elfsyms.zig). A subset: names,
//! nested names, templates with type and integer arguments, abi tags, constructors,
//! destructors, common operators; parameter types builtin, qualified, pointers, references,
//! classes. Anything else (function and array types, member pointers, packs, expressions, local
//! names) is refused (null): elfsyms.zig then shows the name's parts alone, never a wrong one.
const std = @import("std");

const Unsupported = error{ Unsupported, OutOfMemory };

const Parser = struct {
    arena: std.mem.Allocator,
    s: []const u8,
    at: usize = 0,
    /// What S_ and S<n>_ refer back to, in the order the ABI adds them.
    subs: std.ArrayList([]const u8) = .empty,
    /// The last template arguments: what T_ and T<n>_ name.
    template_args: std.ArrayList([]const u8) = .empty,
    /// The last unqualified name read was a constructor's or a destructor's (no return type).
    structor: bool = false,
    /// The last nested name ended with template arguments.
    nested_template: bool = false,

    fn peek(p: *Parser) u8 {
        return if (p.at < p.s.len) p.s[p.at] else 0;
    }

    fn peekAt(p: *Parser, offset: usize) u8 {
        return if (p.at + offset < p.s.len) p.s[p.at + offset] else 0;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() != c) return false;
        p.at += 1;
        return true;
    }

    fn eatStr(p: *Parser, prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, p.s[p.at..], prefix)) return false;
        p.at += prefix.len;
        return true;
    }

    fn print(p: *Parser, comptime format: []const u8, args: anytype) Unsupported![]const u8 {
        return std.fmt.allocPrint(p.arena, format, args);
    }

    fn number(p: *Parser) Unsupported!usize {
        const start = p.at;
        var n: usize = 0;
        while (std.ascii.isDigit(p.peek())) : (p.at += 1) n = n * 10 + (p.peek() - '0');
        if (p.at == start) return error.Unsupported;
        return n;
    }

    fn sourceName(p: *Parser) Unsupported![]const u8 {
        const length = try p.number();
        if (length > p.s.len - p.at) return error.Unsupported;
        const name = p.s[p.at..][0..length];
        p.at += length;
        if (std.mem.startsWith(u8, name, "_GLOBAL__N")) return "(anonymous namespace)";
        return name;
    }

    /// <substitution>: S_, S<seq>_, and the abbreviations.
    fn substitution(p: *Parser) Unsupported![]const u8 {
        if (!p.eat('S')) return error.Unsupported;
        const abbreviations = [_]struct { u8, []const u8 }{
            .{ 'a', "std::allocator" }, .{ 'b', "std::basic_string" }, .{ 's', "std::string" },
            .{ 'i', "std::istream" },   .{ 'o', "std::ostream" },      .{ 'd', "std::iostream" },
        };
        for (abbreviations) |a| if (p.eat(a[0])) return a[1];
        if (p.eat('_')) return if (p.subs.items.len > 0) p.subs.items[0] else error.Unsupported;
        var n: usize = 0;
        var digits: usize = 0;
        while (p.peek() != '_') : (p.at += 1) {
            const c = p.peek();
            const value: usize = if (std.ascii.isDigit(c)) c - '0' else if (c >= 'A' and c <= 'Z') c - 'A' + 10 else return error.Unsupported;
            n = n * 36 + value;
            digits += 1;
        }
        p.at += 1;
        if (digits == 0 or n + 1 >= p.subs.items.len) return error.Unsupported;
        return p.subs.items[n + 1];
    }

    fn abiTags(p: *Parser, name: []const u8) Unsupported![]const u8 {
        var out = name;
        while (p.eat('B')) out = try p.print("{s}[abi:{s}]", .{ out, try p.sourceName() });
        return out;
    }

    const operators = [_]struct { []const u8, []const u8 }{
        .{ "nw", "operator new" }, .{ "na", "operator new[]" }, .{ "dl", "operator delete" }, .{ "da", "operator delete[]" },
        .{ "ps", "operator+" },    .{ "ng", "operator-" },      .{ "ad", "operator&" },       .{ "de", "operator*" },
        .{ "co", "operator~" },    .{ "pl", "operator+" },      .{ "mi", "operator-" },       .{ "ml", "operator*" },
        .{ "dv", "operator/" },    .{ "rm", "operator%" },      .{ "an", "operator&" },       .{ "or", "operator|" },
        .{ "eo", "operator^" },    .{ "aS", "operator=" },      .{ "pL", "operator+=" },      .{ "mI", "operator-=" },
        .{ "mL", "operator*=" },   .{ "dV", "operator/=" },     .{ "rM", "operator%=" },      .{ "aN", "operator&=" },
        .{ "oR", "operator|=" },   .{ "eO", "operator^=" },     .{ "ls", "operator<<" },      .{ "rs", "operator>>" },
        .{ "lS", "operator<<=" },  .{ "rS", "operator>>=" },    .{ "eq", "operator==" },      .{ "ne", "operator!=" },
        .{ "lt", "operator<" },    .{ "gt", "operator>" },      .{ "le", "operator<=" },      .{ "ge", "operator>=" },
        .{ "ss", "operator<=>" },  .{ "nt", "operator!" },      .{ "aa", "operator&&" },      .{ "oo", "operator||" },
        .{ "pp", "operator++" },   .{ "mm", "operator--" },     .{ "cm", "operator," },       .{ "pm", "operator->*" },
        .{ "pt", "operator->" },   .{ "cl", "operator()" },     .{ "ix", "operator[]" },
    };

    /// <unqualified-name> within a nested name; `last` the enclosing class's name (constructors).
    fn unqualified(p: *Parser, last: []const u8) Unsupported![]const u8 {
        p.structor = false;
        const c = p.peek();
        if (std.ascii.isDigit(c)) return p.abiTags(try p.sourceName());
        if (c == 'C' and (p.peekAt(1) == '1' or p.peekAt(1) == '2' or p.peekAt(1) == '3')) {
            p.at += 2;
            p.structor = true;
            return p.abiTags(baseName(last));
        }
        if (c == 'D' and (p.peekAt(1) == '0' or p.peekAt(1) == '1' or p.peekAt(1) == '2')) {
            p.at += 2;
            p.structor = true;
            return p.abiTags(try p.print("~{s}", .{baseName(last)}));
        }
        if (c == 'L') { // An internal-linkage name, its marker before it.
            p.at += 1;
            return p.unqualified(last);
        }
        // A lambda's closure type (Ul <its parameters> E [n] _) and an unnamed type (Ut [n] _), as
        // GCC and c++filt write them: {lambda(int)#2}, {unnamed type#1}.
        if (c == 'U' and (p.peekAt(1) == 'l' or p.peekAt(1) == 't')) {
            const lambda = p.peekAt(1) == 'l';
            p.at += 2;
            var parameters: std.ArrayList(u8) = .empty;
            if (lambda) {
                if (p.peek() == 'v' and p.peekAt(1) == 'E') p.at += 1 else {
                    var first = true;
                    while (p.peek() != 'E') {
                        if (p.at >= p.s.len) return error.Unsupported;
                        if (!first) try parameters.appendSlice(p.arena, ", ");
                        try parameters.appendSlice(p.arena, try p.typeOf());
                        first = false;
                    }
                }
                if (!p.eat('E')) return error.Unsupported;
            }
            const index = if (std.ascii.isDigit(p.peek())) try p.number() + 2 else 1;
            if (!p.eat('_')) return error.Unsupported;
            return if (lambda) p.print("{{lambda({s})#{d}}}", .{ parameters.items, index }) else p.print("{{unnamed type#{d}}}", .{index});
        }
        for (operators) |o| if (p.eatStr(o[0])) return p.abiTags(o[1]);
        return error.Unsupported;
    }

    /// A class's own name for its constructors: the last part, without its template arguments.
    fn baseName(name: []const u8) []const u8 {
        var depth: usize = 0;
        var end = name.len;
        var i = name.len;
        while (i > 0) {
            i -= 1;
            switch (name[i]) {
                '>' => depth += 1,
                '<' => {
                    depth -= 1;
                    if (depth == 0) end = i;
                },
                ':' => if (depth == 0) return name[i + 1 .. end],
                else => {},
            }
        }
        return name[0..end];
    }

    /// <nested-name>: N [CV] <prefix>... E. A prefix is recorded (a substitution) once something
    /// extends it; a substitution or std is not recorded again; the whole name only as a type.
    fn nested(p: *Parser, as_type: bool, method_const: *bool) Unsupported![]const u8 {
        if (!p.eat('N')) return error.Unsupported;
        while (true) {
            if (p.eat('K')) method_const.* = true else if (p.eat('V') or p.eat('r')) {} else break;
        }
        _ = p.eat('R') or p.eat('O');
        var name: []const u8 = "";
        var record = false;
        p.nested_template = false;
        while (!p.eat('E')) {
            if (p.at >= p.s.len) return error.Unsupported;
            if (p.peek() == 'S' and p.peekAt(1) == 't') {
                if (name.len != 0) return error.Unsupported;
                p.at += 2;
                name = "std";
                record = false;
                p.nested_template = false;
            } else if (p.peek() == 'S') {
                if (name.len != 0) return error.Unsupported;
                name = try p.substitution();
                record = false;
                p.nested_template = false;
            } else if (p.peek() == 'I') {
                if (name.len == 0) return error.Unsupported;
                if (record) try p.subs.append(p.arena, name);
                name = try p.print("{s}{s}", .{ name, try p.templateArgs() });
                record = true;
                p.nested_template = true;
            } else {
                const part = try p.unqualified(name);
                if (record) try p.subs.append(p.arena, name);
                name = if (name.len == 0) part else try p.print("{s}::{s}", .{ name, part });
                record = true;
                p.nested_template = false;
            }
        }
        if (as_type and record) try p.subs.append(p.arena, name);
        return name;
    }

    /// <template-args>: I <arg>+ E, as written: <a, b>; they become what T_ names.
    fn templateArgs(p: *Parser) Unsupported![]const u8 {
        if (!p.eat('I')) return error.Unsupported;
        var args: std.ArrayList([]const u8) = .empty;
        while (!p.eat('E')) {
            if (p.at >= p.s.len) return error.Unsupported;
            if (p.eat('L')) {
                const kind = p.peek();
                p.at += 1;
                const negative = p.eat('n');
                const value = try p.number();
                if (!p.eat('E')) return error.Unsupported;
                try args.append(p.arena, switch (kind) {
                    'i' => try p.print("{s}{d}", .{ if (negative) "-" else "", value }),
                    'j' => try p.print("{d}u", .{value}),
                    'l' => try p.print("{s}{d}l", .{ if (negative) "-" else "", value }),
                    'm' => try p.print("{d}ul", .{value}),
                    'b' => if (value == 0) "false" else "true",
                    else => return error.Unsupported,
                });
            } else try args.append(p.arena, try p.typeOf());
        }
        p.template_args = args;
        var out: std.ArrayList(u8) = .empty;
        try out.append(p.arena, '<');
        for (args.items, 0..) |arg, i| {
            if (i > 0) try out.appendSlice(p.arena, ", ");
            try out.appendSlice(p.arena, arg);
        }
        try out.append(p.arena, '>');
        return out.items;
    }

    const builtins = [_]struct { u8, []const u8 }{
        .{ 'v', "void" },        .{ 'w', "wchar_t" },            .{ 'b', "bool" },        .{ 'c', "char" },
        .{ 'a', "signed char" }, .{ 'h', "unsigned char" },      .{ 's', "short" },       .{ 't', "unsigned short" },
        .{ 'i', "int" },         .{ 'j', "unsigned int" },       .{ 'l', "long" },        .{ 'm', "unsigned long" },
        .{ 'x', "long long" },   .{ 'y', "unsigned long long" }, .{ 'n', "__int128" },    .{ 'o', "unsigned __int128" },
        .{ 'f', "float" },       .{ 'd', "double" },             .{ 'e', "long double" }, .{ 'z', "..." },
    };

    fn typeOf(p: *Parser) Unsupported![]const u8 {
        const c = p.peek();
        for (builtins) |b| if (c == b[0]) {
            p.at += 1;
            return b[1];
        };
        switch (c) {
            'D' => {
                const extended = [_]struct { u8, []const u8 }{ .{ 's', "char16_t" }, .{ 'i', "char32_t" }, .{ 'u', "char8_t" }, .{ 'n', "std::nullptr_t" } };
                for (extended) |b| if (p.peekAt(1) == b[0]) {
                    p.at += 2;
                    return b[1];
                };
                return error.Unsupported;
            },
            'P', 'R', 'O' => {
                p.at += 1;
                const inner = try p.typeOf();
                const out = try p.print("{s}{s}", .{ inner, switch (c) {
                    'P' => "*",
                    'R' => "&",
                    else => "&&",
                } });
                try p.subs.append(p.arena, out);
                return out;
            },
            'K', 'V', 'r' => {
                var qualifiers: std.ArrayList(u8) = .empty;
                while (true) {
                    if (p.eat('r')) try qualifiers.appendSlice(p.arena, " restrict") else if (p.eat('V')) try qualifiers.appendSlice(p.arena, " volatile") else if (p.eat('K')) try qualifiers.appendSlice(p.arena, " const") else break;
                }
                const out = try p.print("{s}{s}", .{ try p.typeOf(), qualifiers.items });
                try p.subs.append(p.arena, out);
                return out;
            },
            'T' => {
                p.at += 1;
                var index: usize = 0;
                if (!p.eat('_')) {
                    index = try p.number() + 1;
                    if (!p.eat('_')) return error.Unsupported;
                }
                if (index >= p.template_args.items.len) return error.Unsupported;
                const out = p.template_args.items[index];
                try p.subs.append(p.arena, out);
                return out;
            },
            'S' => {
                var named: []const u8 = undefined;
                if (p.peekAt(1) == 't') {
                    p.at += 2;
                    named = try p.print("std::{s}", .{try p.unqualified("")});
                    try p.subs.append(p.arena, named);
                } else named = try p.substitution();
                if (p.peek() == 'I') {
                    const out = try p.print("{s}{s}", .{ named, try p.templateArgs() });
                    try p.subs.append(p.arena, out);
                    return out;
                }
                return named;
            },
            'N' => {
                var ignored = false;
                return p.nested(true, &ignored);
            },
            '0'...'9' => {
                const name = try p.abiTags(try p.sourceName());
                try p.subs.append(p.arena, name);
                if (p.peek() == 'I') {
                    const out = try p.print("{s}{s}", .{ name, try p.templateArgs() });
                    try p.subs.append(p.arena, out);
                    return out;
                }
                return name;
            },
            else => return error.Unsupported,
        }
    }
};

/// `name` (`_Z...`) as C++ writes it, or null: not Itanium's, or outside the subset read here.
pub fn demangle(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "_Z")) return null;
    // A clone's suffix (.cold, .isra.0, .llvm.<n>): the function it was cloned from.
    const end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    var p: Parser = .{ .arena = arena, .s = name[0..end], .at = 2 };
    const read = encoding(&p, false) catch return null;
    return if (p.at == p.s.len) read else null;
}

/// An encoding: a name, and a function's parameter types after it. `inner`: a local name's
/// enclosing function, ended by the local name's E rather than by the symbol's end.
fn encoding(p: *Parser, inner: bool) Unsupported![]const u8 {
    var method_const = false;
    var is_template = false;
    var function_name: []const u8 = undefined;
    switch (p.peek()) {
        'N' => {
            function_name = try p.nested(false, &method_const);
            is_template = p.nested_template;
        },
        'Z' => {
            function_name = try localName(p, &method_const);
            is_template = p.nested_template;
        },
        'L' => {
            p.at += 1;
            function_name = try p.abiTags(try p.sourceName());
        },
        'S' => {
            if (!p.eatStr("St")) return error.Unsupported;
            function_name = try p.print("std::{s}", .{try p.unqualified("")});
        },
        '0'...'9' => function_name = try p.abiTags(try p.sourceName()),
        else => return error.Unsupported,
    }
    if (p.peek() == 'I') {
        try p.subs.append(p.arena, function_name);
        function_name = try p.print("{s}{s}", .{ function_name, try p.templateArgs() });
        is_template = true;
    }
    const ended = struct {
        fn at(q: *Parser, local: bool, offset: usize) bool {
            return q.at + offset >= q.s.len or (local and q.peekAt(offset) == 'E');
        }
    }.at;
    if (ended(p, inner, 0)) return function_name; // Data, not a function.
    // A function template's mangling begins with its return type; constructors and destructors
    // have none.
    const returned: ?[]const u8 = if (is_template and !p.structor) try p.typeOf() else null;
    var parameters: std.ArrayList(u8) = .empty;
    if (p.peek() == 'v' and ended(p, inner, 1)) {
        p.at += 1;
    } else {
        var first = true;
        while (!ended(p, inner, 0)) {
            if (!first) try parameters.appendSlice(p.arena, ", ");
            try parameters.appendSlice(p.arena, try p.typeOf());
            first = false;
        }
    }
    return p.print("{s}{s}{s}({s}){s}", .{
        returned orelse "",                 if (returned != null) " " else "",
        function_name,                      parameters.items,
        if (method_const) " const" else "",
    });
}

/// <local-name>: Z <its function's encoding> E <entity> [<discriminator>]: a name inside a
/// function (a static, a local class, a lambda's closure), as function::entity.
fn localName(p: *Parser, method_const: *bool) Unsupported![]const u8 {
    if (!p.eat('Z')) return error.Unsupported;
    const function = try encoding(p, true);
    if (!p.eat('E')) return error.Unsupported;
    p.nested_template = false;
    const entity: []const u8 = if (p.eat('s')) "string literal" else switch (p.peek()) {
        'N' => try p.nested(false, method_const),
        'Z' => try localName(p, method_const),
        else => try p.unqualified(""),
    };
    // Its discriminator (the nth of that name in the function): not written.
    if (p.peek() == '_') {
        if (p.peekAt(1) == '_') {
            p.at += 2;
            _ = try p.number();
            if (!p.eat('_')) return error.Unsupported;
        } else if (std.ascii.isDigit(p.peekAt(1))) p.at += 2;
    }
    return p.print("{s}::{s}", .{ function, entity });
}

test "C++ names as their source writes them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "_ZN7leveldb6DBImpl5WriteERKNS_12WriteOptionsEPNS_10WriteBatchE", "leveldb::DBImpl::Write(leveldb::WriteOptions const&, leveldb::WriteBatch*)" },
        .{ "_Z3fooi", "foo(int)" },
        .{ "_ZN5store5Table3putERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERKNS1_6vectorIcNS5_IcEEEERKNS_7OptionsE", "store::Table::put(std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char>> const&, std::__1::vector<char, std::__1::allocator<char>> const&, store::Options const&)" },
        .{ "_ZNK3foo3barEv", "foo::bar() const" },
        .{ "_ZN3fooC2Ev", "foo::foo()" },
        .{ "_ZN3fooD1Ev", "foo::~foo()" },
        .{ "_Z5twiceIiET_S0_", "int twice<int>(int)" },
        .{ "_ZN3foo3bar5cold_Ev.cold", "foo::bar::cold_()" },
    };
    for (cases) |case| {
        const got = demangle(arena, case[0]) orelse {
            std.debug.print("refused: {s}\n", .{case[0]});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(case[1], got);
    }
    // Local names: a static, a closure's call operator, a GCC lambda.
    try std.testing.expectEqualStrings("main::x", demangle(arena, "_ZZ4mainE1x").?);
    try std.testing.expectEqualStrings("main::$_0::operator()(int) const", demangle(arena, "_ZZ4mainENK3$_0clEi").?);
    try std.testing.expectEqualStrings("foo(int)::{lambda(int)#1}::operator()(int) const", demangle(arena, "_ZZ3fooiENKUliE_clEi").?);
    // Outside the subset: refused, never a wrong name.
    try std.testing.expect(demangle(arena, "_Z1fPFviE") == null);
    try std.testing.expect(demangle(arena, "exit") == null);
}
