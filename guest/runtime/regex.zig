// SPDX-License-Identifier: MIT
//! A regular expression, Rust's regex syntax in the part names need (Antithesis's
//! `fault_exclusions`, "a regular expression that uses Rust regex syntax. It matches container
//! names, or pod names on Kubernetes"): literals and escapes, `.`, classes (`[a-z_]`, `[^0-9]`,
//! `\d \w \s` and their negations), anchors `^ $`, groups `( )` and `(?: )`, alternation `|`,
//! and the quantifiers `* + ?` (a lazy one's `?` read and ignored: whether it matches is the
//! same). A match is anywhere in the text, as Rust's `is_match`. What it does not take (counted
//! repetition `{n,m}`, flags, look-around) is an error, never a different meaning. Bytes, not
//! characters: names are ASCII. Compiled to a program of at most `instructions_max` steps and run
//! as Pike's virtual machine, linear in the text, no allocation: the guest's fault picker runs
//! it on every pod it draws.
const std = @import("std");

pub const pattern_size_max = 256;
const instructions_max = 4 * pattern_size_max;
const classes_max = 32;

const Op = enum(u8) { byte, any, class, split, jump, match, start, end };

const Instruction = struct {
    op: Op,
    /// The byte (byte), the class's index (class), or the first target (split, jump).
    a: u16 = 0,
    /// The second target (split).
    b: u16 = 0,
};

const Class = std.StaticBitSet(256);

pub const Error = error{ PatternTooLong, TooComplex, Unbalanced, Unsupported, Empty };

pub const Regex = struct {
    instructions: [instructions_max]Instruction = undefined,
    count: u16 = 0,
    classes: [classes_max]Class = undefined,
    class_count: u8 = 0,

    pub fn compile(pattern: []const u8) Error!Regex {
        if (pattern.len == 0) return error.Empty;
        if (pattern.len > pattern_size_max) return error.PatternTooLong;
        var regex: Regex = .{};
        var parser: Parser = .{ .pattern = pattern };
        try parser.alternation(&regex);
        if (parser.at != pattern.len) return error.Unbalanced; // A `)` with no `(`.
        try regex.emit(.{ .op = .match });
        return regex;
    }

    /// Whether the pattern matches anywhere in `text`.
    pub fn is_match(regex: *const Regex, text: []const u8) bool {
        var lists: [2]List = .{ .{}, .{} };
        var current: *List = &lists[0];
        var next: *List = &lists[1];
        var at: usize = 0;
        while (true) : (at += 1) {
            // A thread starts at every position: the match may begin anywhere.
            if (regex.follow(current, 0, at, text)) return true;
            if (at == text.len) return false;
            next.clear();
            for (current.pcs[0..current.count]) |pc| {
                const instruction = regex.instructions[pc];
                const taken = switch (instruction.op) {
                    .byte => text[at] == instruction.a,
                    .any => text[at] != '\n',
                    .class => regex.classes[instruction.a].isSet(text[at]),
                    else => false,
                };
                if (taken and regex.follow(next, pc + 1, at + 1, text)) return true;
            }
            const swapped = current;
            current = next;
            next = swapped;
        }
    }

    /// Adds `pc` to `list` with every step it leads to without reading a byte; whether one is
    /// the match.
    fn follow(regex: *const Regex, list: *List, pc: u16, at: usize, text: []const u8) bool {
        // A step is pushed at most once for each split or jump leading to it: twice the steps.
        var stack: [2 * instructions_max + 1]u16 = undefined;
        stack[0] = pc;
        var depth: usize = 1;
        while (depth > 0) {
            depth -= 1;
            const here = stack[depth];
            if (list.has(here)) continue;
            list.add(here);
            const instruction = regex.instructions[here];
            switch (instruction.op) {
                .match => return true,
                .jump => {
                    stack[depth] = instruction.a;
                    depth += 1;
                },
                .split => {
                    stack[depth] = instruction.b;
                    stack[depth + 1] = instruction.a;
                    depth += 2;
                },
                .start => if (at == 0) {
                    stack[depth] = here + 1;
                    depth += 1;
                },
                .end => if (at == text.len) {
                    stack[depth] = here + 1;
                    depth += 1;
                },
                .byte, .any, .class => {},
            }
        }
        return false;
    }

    fn emit(regex: *Regex, instruction: Instruction) Error!void {
        if (regex.count == instructions_max) return error.TooComplex;
        regex.instructions[regex.count] = instruction;
        regex.count += 1;
    }

    /// Puts `instruction` at `at`, the ones from there one further on (their targets from `at`
    /// on with them: nothing before `at` points past it yet).
    fn insert(regex: *Regex, at: u16, instruction: Instruction) Error!void {
        if (regex.count == instructions_max) return error.TooComplex;
        var index = regex.count;
        while (index > at) : (index -= 1) regex.instructions[index] = regex.instructions[index - 1];
        regex.count += 1;
        for (regex.instructions[at + 1 .. regex.count]) |*moved| switch (moved.op) {
            .jump => {
                if (moved.a >= at) moved.a += 1;
            },
            .split => {
                if (moved.a >= at) moved.a += 1;
                if (moved.b >= at) moved.b += 1;
            },
            else => {},
        };
        regex.instructions[at] = instruction;
    }

    fn class_add(regex: *Regex, class: Class) Error!u16 {
        if (regex.class_count == classes_max) return error.TooComplex;
        regex.classes[regex.class_count] = class;
        regex.class_count += 1;
        return regex.class_count - 1;
    }
};

/// The steps reached at one position of the text, each once.
const List = struct {
    pcs: [instructions_max]u16 = undefined,
    count: usize = 0,
    seen: std.StaticBitSet(instructions_max) = .empty,

    fn has(list: *const List, pc: u16) bool {
        return list.seen.isSet(pc);
    }

    fn add(list: *List, pc: u16) void {
        list.seen.set(pc);
        list.pcs[list.count] = pc;
        list.count += 1;
    }

    fn clear(list: *List) void {
        for (list.pcs[0..list.count]) |pc| list.seen.unset(pc);
        list.count = 0;
    }
};

const Parser = struct {
    pattern: []const u8,
    at: usize = 0,
    depth: u32 = 0,

    fn peek(parser: *const Parser) ?u8 {
        return if (parser.at < parser.pattern.len) parser.pattern[parser.at] else null;
    }

    /// a|b|c: split to each, each jumping past the last.
    fn alternation(parser: *Parser, regex: *Regex) Error!void {
        var jumps: [pattern_size_max]u16 = undefined;
        var jump_count: usize = 0;
        var start = regex.count;
        try parser.sequence(regex);
        while (parser.peek() == '|') {
            parser.at += 1;
            try regex.insert(start, .{ .op = .split, .a = start + 1 });
            jumps[jump_count] = regex.count;
            jump_count += 1;
            try regex.emit(.{ .op = .jump });
            regex.instructions[start].b = regex.count;
            start = regex.count;
            try parser.sequence(regex);
        }
        for (jumps[0..jump_count]) |jump| regex.instructions[jump].a = regex.count;
    }

    fn sequence(parser: *Parser, regex: *Regex) Error!void {
        while (parser.peek()) |byte| {
            if (byte == '|' or byte == ')') return;
            try parser.piece(regex);
        }
    }

    fn piece(parser: *Parser, regex: *Regex) Error!void {
        const start = regex.count;
        try parser.atom(regex);
        const quantifier = parser.peek() orelse return;
        switch (quantifier) {
            '*' => {
                try regex.insert(start, .{ .op = .split, .a = start + 1 });
                try regex.emit(.{ .op = .jump, .a = start });
                regex.instructions[start].b = regex.count;
            },
            '+' => try regex.emit(.{ .op = .split, .a = start, .b = regex.count + 1 }),
            '?' => {
                try regex.insert(start, .{ .op = .split, .a = start + 1 });
                regex.instructions[start].b = regex.count;
            },
            '{' => return error.Unsupported,
            else => return,
        }
        parser.at += 1;
        if (parser.peek() == '?') parser.at += 1; // Lazy: the same verdict.
        if (parser.peek()) |next| if (next == '*' or next == '+' or next == '{') return error.Unsupported;
    }

    fn atom(parser: *Parser, regex: *Regex) Error!void {
        const byte = parser.peek() orelse return error.Unbalanced;
        parser.at += 1;
        switch (byte) {
            '(' => {
                if (std.mem.startsWith(u8, parser.pattern[parser.at..], "?:")) {
                    parser.at += 2;
                } else if (parser.peek() == '?') return error.Unsupported; // Flags, names.
                parser.depth += 1;
                if (parser.depth > 32) return error.TooComplex;
                try parser.alternation(regex);
                if (parser.peek() != ')') return error.Unbalanced;
                parser.at += 1;
                parser.depth -= 1;
            },
            ')' => return error.Unbalanced,
            '*', '+', '?', '{' => return error.Unsupported, // Nothing to repeat.
            '.' => try regex.emit(.{ .op = .any }),
            '^' => try regex.emit(.{ .op = .start }),
            '$' => try regex.emit(.{ .op = .end }),
            '[' => try regex.emit(.{ .op = .class, .a = try regex.class_add(try parser.class()) }),
            '\\' => {
                const escaped = parser.peek() orelse return error.Unbalanced;
                parser.at += 1;
                if (shorthand(escaped)) |set| {
                    try regex.emit(.{ .op = .class, .a = try regex.class_add(set) });
                } else if (std.ascii.isAlphanumeric(escaped)) {
                    return error.Unsupported; // \b, \A, \x..: meanings not taken.
                } else try regex.emit(.{ .op = .byte, .a = escaped });
            },
            else => try regex.emit(.{ .op = .byte, .a = byte }),
        }
    }

    /// `[...]` after its `[`: bytes, ranges, shorthands, `^` first for its complement.
    fn class(parser: *Parser) Error!Class {
        var set: Class = .empty;
        const negated = parser.peek() == '^';
        if (negated) parser.at += 1;
        var first = true;
        while (true) {
            const byte = parser.peek() orelse return error.Unbalanced;
            if (byte == ']' and !first) {
                parser.at += 1;
                break;
            }
            first = false;
            parser.at += 1;
            var low = byte;
            if (byte == '\\') {
                const escaped = parser.peek() orelse return error.Unbalanced;
                parser.at += 1;
                if (shorthand(escaped)) |shorthand_set| {
                    set.setUnion(shorthand_set);
                    continue;
                }
                if (std.ascii.isAlphanumeric(escaped)) return error.Unsupported;
                low = escaped;
            } else if (byte == '[') return error.Unsupported; // [[:alpha:]], nested classes.
            var high = low;
            if (parser.peek() == '-' and parser.at + 1 < parser.pattern.len and parser.pattern[parser.at + 1] != ']') {
                parser.at += 1;
                high = parser.peek().?;
                parser.at += 1;
                if (high == '\\') {
                    high = parser.peek() orelse return error.Unbalanced;
                    parser.at += 1;
                }
                if (high < low) return error.Unsupported;
            }
            set.setRangeValue(.{ .start = low, .end = @as(usize, high) + 1 }, true);
        }
        if (negated) set.toggleAll();
        return set;
    }
};

fn shorthand(escaped: u8) ?Class {
    var set: Class = .empty;
    switch (std.ascii.toLower(escaped)) {
        'd' => set.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
        'w' => {
            set.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true);
            set.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true);
            set.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true);
            set.set('_');
        },
        's' => for (" \t\n\r\x0b\x0c") |byte| set.set(byte),
        else => return null,
    }
    if (std.ascii.isUpper(escaped)) set.toggleAll();
    return set;
}

fn matches(pattern: []const u8, text: []const u8) !bool {
    const regex = try Regex.compile(pattern);
    return regex.is_match(text);
}

test "Antithesis's example and ParadeDB's patterns: anchored names, and names anywhere" {
    // docs product/writing_tests/controlling_faults: `^(raft-client|raft-monitor)$`.
    try std.testing.expect(try matches("^(raft-client|raft-monitor)$", "raft-client"));
    try std.testing.expect(try matches("^(raft-client|raft-monitor)$", "raft-monitor"));
    try std.testing.expect(!try matches("^(raft-client|raft-monitor)$", "raft-client-2"));
    try std.testing.expect(!try matches("^(raft-client|raft-monitor)$", "raft-server"));
    // Unanchored, as Rust's is_match: anywhere in the name.
    const parade = "coredns|stressgres|cloudnative-pg|logical-replication-publisher";
    try std.testing.expect(try matches(parade, "coredns-7c9b5d8d4f-x2k8q"));
    try std.testing.expect(try matches(parade, "cnpg-system-cloudnative-pg-6f9"));
    try std.testing.expect(try matches(parade, "logical-replication-publisher-0"));
    try std.testing.expect(!try matches(parade, "paradedb-1"));
}

test "classes, shorthands, quantifiers, groups" {
    try std.testing.expect(try matches("^paradedb-\\d+$", "paradedb-12"));
    try std.testing.expect(!try matches("^paradedb-\\d+$", "paradedb-"));
    try std.testing.expect(try matches("^node[0-2]$", "node2"));
    try std.testing.expect(!try matches("^node[0-2]$", "node3"));
    try std.testing.expect(try matches("^[^-]+$", "kafka"));
    try std.testing.expect(!try matches("^[^-]+$", "kafka-1"));
    try std.testing.expect(try matches("^a(bc)*d$", "ad"));
    try std.testing.expect(try matches("^a(bc)*d$", "abcbcd"));
    try std.testing.expect(!try matches("^a(bc)*d$", "abd"));
    try std.testing.expect(try matches("^colou?r$", "color"));
    try std.testing.expect(try matches("^colou?r$", "colour"));
    try std.testing.expect(try matches("^(?:a|b)+?$", "abba"));
    try std.testing.expect(try matches("^x.z$", "x-z"));
    try std.testing.expect(!try matches("^x.z$", "x\nz"));
    try std.testing.expect(try matches("\\.", "a.b"));
    try std.testing.expect(!try matches("\\.", "ab"));
    try std.testing.expect(try matches("^[\\w-]+$", "my_pod-1"));
    try std.testing.expect(try matches("a|", "zzz")); // An empty alternative matches anywhere.
    try std.testing.expect(try matches("(a*)*$", "b")); // Nested repetition: no endless loop.
    try std.testing.expect(try matches("^$", ""));
}

test "what it does not take is an error, never another meaning" {
    try std.testing.expectError(error.Unsupported, Regex.compile("a{2}"));
    try std.testing.expectError(error.Unsupported, Regex.compile("(?i)a"));
    try std.testing.expectError(error.Unsupported, Regex.compile("\\bword"));
    try std.testing.expectError(error.Unsupported, Regex.compile("*a"));
    try std.testing.expectError(error.Unsupported, Regex.compile("a**"));
    try std.testing.expectError(error.Unbalanced, Regex.compile("(a"));
    try std.testing.expectError(error.Unbalanced, Regex.compile("a)"));
    try std.testing.expectError(error.Unbalanced, Regex.compile("[ab"));
    try std.testing.expectError(error.Empty, Regex.compile(""));
    const long: [pattern_size_max + 1]u8 = @splat('a');
    try std.testing.expectError(error.PatternTooLong, Regex.compile(&long));
}
