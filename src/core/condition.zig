// SPDX-License-Identifier: MIT
//! The condition language of events (query.zig's searches, a replay's moment `--until`, a step's
//! det:until): parsed and matched live here. Core (PLAN: a run pins its core): a replay
//! re-evaluates a step's condition rather than reading a taped time, so how a condition matches
//! decides a session timeline's history. Its SQL rendering, over the events database, is
//! query.zig's.
//!
//! A condition is terms joined by `and` and `or` (`or` binds loosest). A term is `path op value`
//! over the event's JSON (`event=fault`, `details.kind=partition`, `output.text~refused`,
//! `assert.condition=false`), or over `vtime` (seconds), `branch` and `seq`. Operators: `=`,
//! `!=`, `~` (contains), `!~`, `=~` (matches a regular expression, see regex.zig), `!=~`, `<`,
//! `<=`, `>`, `>=`, `?` (present), `!?` (absent). Values are words or "quoted strings" (where a
//! backslash escapes the next character: `\\d` for a regex's `\d`); numbers and booleans compare
//! as such. Events without the field never match, negative operators included (as in
//! Antithesis).
const std = @import("std");
const assert = std.debug.assert;
const Regex = @import("regex.zig").Regex;

const terms_max = 32;
const testing = std.testing;

pub const Operator = enum {
    matches,
    not_matches,
    equal,
    not_equal,
    contains,
    excludes,
    less,
    less_equal,
    greater,
    greater_equal,
    present,
    absent,
};

pub const Term = struct {
    path: []const []const u8,
    operator: Operator,
    value: []const u8 = "",
    /// The compiled pattern of `=~` and `!=~` (it checks the pattern, and matches live).
    regex: ?*const Regex = null,
};

/// An event as it happens (a replay's, before any database has it): its JSON and its place.
pub const Event = struct { value: std.json.Value, vtime_ns: u64, branch: u32 = 0, seq: u64 };

/// Alternatives (or) of conjunctions (and).
pub const Condition = struct {
    alternatives: []const []const Term,

    /// Whether the event matches, live.
    pub fn matches(condition: *const Condition, event: Event) bool {
        for (condition.alternatives) |terms| {
            const all = for (terms) |*term| {
                if (!term_matches(term, event)) break false;
            } else true;
            if (all) return true;
        }
        return false;
    }

    /// Whether the event's line has the text some alternative needs: a term `path=value` or
    /// `path~value` needs `value` in it (as JSON writes strings, numbers and booleans, when it
    /// has no characters JSON escapes); other terms need nothing. Most lines are told apart on
    /// it, without parsing their JSON.
    pub fn may_match(condition: *const Condition, line: []const u8) bool {
        for (condition.alternatives) |terms| {
            const possible = for (terms) |*term| {
                if (term_needs(term)) |needed| {
                    if (std.mem.indexOf(u8, line, needed) == null) break false;
                }
            } else true;
            if (possible) return true;
        }
        return false;
    }
};

pub fn term_needs(term: *const Term) ?[]const u8 {
    if (term.operator != .equal and term.operator != .contains) return null;
    if (pseudo_of(term.path) != null) return null; // Not in the event's JSON.
    if (term.value.len == 0) return null;
    // A number equals others written otherwise (300 and 300.0; 1 and true).
    const number = if (std.fmt.parseFloat(f64, term.value)) |_| true else |_| false;
    if (term.operator == .equal and number) return null;
    for (term.value) |byte| if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) {
        return null; // Written escaped.
    };
    return term.value;
}

/// Fields that are the event's place, not its JSON.
pub const Pseudo = enum { vtime, branch, seq };

pub fn pseudo_of(path: []const []const u8) ?Pseudo {
    if (path.len != 1) return null;
    return std.meta.stringToEnum(Pseudo, path[0]);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) !Condition {
    var tokens = try tokenize(arena, text);
    var alternatives: std.ArrayList([]const Term) = .empty;
    var terms: std.ArrayList(Term) = .empty;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "or")) {
            if (terms.items.len == 0) return error.EmptyAlternative;
            try alternatives.append(arena, try terms.toOwnedSlice(arena));
            continue;
        }
        if (std.mem.eql(u8, token, "and")) continue;
        if (terms.items.len == terms_max) return error.TooManyTerms;
        try terms.append(arena, try term_parse(arena, token, &tokens));
    }
    if (terms.items.len == 0) return error.EmptyCondition;
    try alternatives.append(arena, try terms.toOwnedSlice(arena));
    return .{ .alternatives = alternatives.items };
}

const operators = [_]struct { []const u8, Operator }{
    // Longest first, so that `<=` is not read as `<`.
    .{ "!=~", .not_matches }, .{ "=~", .matches },
    .{ "!=", .not_equal },    .{ "!~", .excludes },
    .{ "<=", .less_equal },   .{ ">=", .greater_equal },
    .{ "!?", .absent },       .{ "=", .equal },
    .{ "~", .contains },      .{ "<", .less },
    .{ ">", .greater },       .{ "?", .present },
};

/// `path op value`, written as one token (`a.b=c`) or as several (`a.b = "c d"`).
fn term_parse(arena: std.mem.Allocator, first: []const u8, tokens: *Tokens) !Term {
    for (first, 0..) |_, at| {
        for (operators) |entry| {
            if (!std.mem.startsWith(u8, first[at..], entry[0])) continue;
            const path_text = first[0..at];
            if (path_text.len == 0) return error.TermWithoutPath;
            var value = first[at + entry[0].len ..];
            if (value_needed(entry[1]) and value.len == 0) {
                value = tokens.next() orelse return error.TermWithoutValue;
            }
            return term_make(arena, try path_split(arena, path_text), entry[1], value);
        }
    }
    // The operator in the next token: `path = value`.
    const operator_text = tokens.next() orelse return error.TermWithoutOperator;
    for (operators) |entry| {
        if (!std.mem.eql(u8, operator_text, entry[0])) continue;
        const value = if (value_needed(entry[1]))
            tokens.next() orelse return error.TermWithoutValue
        else
            "";
        return term_make(arena, try path_split(arena, first), entry[1], value);
    }
    return error.UnknownOperator;
}

fn term_make(
    arena: std.mem.Allocator,
    path: []const []const u8,
    operator: Operator,
    value: []const u8,
) !Term {
    var term = Term{ .path = path, .operator = operator, .value = value };
    if (operator == .matches or operator == .not_matches) {
        const regex = try arena.create(Regex);
        regex.* = try Regex.compile(arena, value);
        term.regex = regex;
    }
    return term;
}

fn value_needed(operator: Operator) bool {
    return operator != .present and operator != .absent;
}

fn path_split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, text, '.');
    while (pieces.next()) |piece| {
        if (piece.len == 0) return error.BadPath;
        try parts.append(arena, piece);
    }
    return parts.items;
}

const Tokens = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(tokens: *Tokens) ?[]const u8 {
        if (tokens.index == tokens.items.len) return null;
        tokens.index += 1;
        return tokens.items[tokens.index - 1];
    }
};

/// Words and "quoted strings" (backslash escapes the next character); a quote may follow an
/// operator in the same word (`output.text~"connection refused"`).
fn tokenize(arena: std.mem.Allocator, text: []const u8) !Tokens {
    var items: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quoted = false;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quoted) {
            if (byte == '"') {
                quoted = false;
            } else if (byte == '\\' and index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
            } else try word.append(arena, byte);
            continue;
        }
        switch (byte) {
            ' ', '\t', '\n' => if (in_word) {
                try items.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '"' => {
                quoted = true;
                in_word = true;
            },
            else => {
                try word.append(arena, byte);
                in_word = true;
            },
        }
    }
    if (quoted) return error.UnterminatedQuote;
    if (in_word) try items.append(arena, try word.toOwnedSlice(arena));
    return .{ .items = items.items };
}

fn term_matches(term: *const Term, event: Event) bool {
    const field = field_get(event, term.path);
    switch (term.operator) {
        .present => return field != null,
        .absent => return field == null,
        else => {},
    }
    // Events without the field never match, negative operators included (as in Antithesis).
    const value = field orelse return false;
    return switch (term.operator) {
        .equal => equals(value, term.value),
        .not_equal => !equals(value, term.value),
        .matches => if (text_of(value)) |text| term.regex.?.matches(text) else false,
        .not_matches => if (text_of(value)) |text| !term.regex.?.matches(text) else false,
        .contains => contains(value, term.value) orelse false,
        .excludes => if (contains(value, term.value)) |found| !found else false,
        .less, .less_equal, .greater, .greater_equal => compare(value, term.operator, term.value),
        .present, .absent => unreachable,
    };
}

const Field = union(enum) { json: std.json.Value, number: f64 };

fn field_get(event: Event, path: []const []const u8) ?Field {
    assert(path.len > 0);
    if (pseudo_of(path)) |pseudo| return .{ .number = switch (pseudo) {
        .vtime => @as(f64, @floatFromInt(event.vtime_ns)) / std.time.ns_per_s,
        .branch => @floatFromInt(event.branch),
        .seq => @floatFromInt(event.seq),
    } };
    var value = event.value;
    for (path) |key| {
        if (value != .object) return null;
        value = value.object.get(key) orelse return null;
    }
    return .{ .json = value };
}

fn contains(field: Field, wanted: []const u8) ?bool {
    const text = text_of(field) orelse return null;
    return std.mem.indexOf(u8, text, wanted) != null;
}

fn text_of(field: Field) ?[]const u8 {
    return switch (field) {
        .json => |value| if (value == .string) value.string else null,
        .number => null,
    };
}

fn number_of(field: Field) ?f64 {
    return switch (field) {
        .number => |number| number,
        .json => |value| switch (value) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
            .bool => |flag| if (flag) 1 else 0, // As Antithesis coerces.
            else => null,
        },
    };
}

fn equals(field: Field, expected: []const u8) bool {
    if (text_of(field)) |text| return std.mem.eql(u8, text, expected);
    if (field == .json and field.json == .bool) {
        if (std.mem.eql(u8, expected, "true")) return field.json.bool;
        if (std.mem.eql(u8, expected, "false")) return !field.json.bool;
    }
    if (field == .json and field.json == .null) return std.mem.eql(u8, expected, "null");
    const number = number_of(field) orelse return false;
    const wanted = std.fmt.parseFloat(f64, expected) catch return false;
    return number == wanted; // 17.0 matches 17.
}

fn compare(field: Field, operator: Operator, expected: []const u8) bool {
    const number = number_of(field) orelse return false;
    const wanted = std.fmt.parseFloat(f64, expected) catch return false;
    return switch (operator) {
        .less => number < wanted,
        .less_equal => number <= wanted,
        .greater => number > wanted,
        .greater_equal => number >= wanted,
        else => unreachable,
    };
}

// SQL: each term as the live matcher judges it, NULL-free (a missing field matches nothing).

/// How SQL reads a term's field: its text (`->>`) and its JSON type (NULL when absent).
pub fn event_test(arena: std.mem.Allocator, vtime_ns: u64, json: []const u8) !Event {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return .{ .value = value, .vtime_ns = vtime_ns, .seq = 1 };
}

test "a condition skips lines without the text it needs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const condition = try parse(arena, "event=fault or output.text~refused");
    try testing.expect(condition.may_match("{\"event\":\"fault\"}"));
    try testing.expect(condition.may_match("{\"output\":{\"text\":\"refused\"}}"));
    try testing.expect(!condition.may_match("{\"output\":{\"text\":\"fine\"}}"));
    const numeric = try parse(arena, "vtime>2 and branch=3");
    try testing.expect(numeric.may_match("{}"));
}

pub const condition_checks = [_]struct { []const u8, bool, bool }{
    .{ "event=fault", true, false },
    .{ "event=fault details.kind=partition", true, false },
    .{ "event = fault and details.node != redis", false, false },
    .{ "details.duration_ns>=300 vtime<3", true, false },
    .{ "details.duration_ns=300.0", true, false },
    .{ "details.healed=1 details.healed=true", true, false },
    .{ "details.until=null", true, false },
    .{ "output.text~\"connection refused\"", false, true },
    .{ "output.text!~refused", false, false },
    .{ "output.text=~\"^conn.*re(f|d)used\"", false, true },
    .{ "output.text!=~\"(?i)REFUSED\"", false, false },
    .{ "event=fault or output.stream=stderr", true, true },
    .{ "output?", false, true },
    .{ "output!?", true, false },
    .{ "seq=1 branch=0 vtime>=2.5", true, true },
    .{ "details.kind!=partition", false, false },
    .{ "details.node=redis event!=decision", true, false },
    .{ "details.kind~arti details.node?", true, false },
};
pub const condition_events = [_]struct { u64, []const u8 }{
    .{
        2_500_000_000,
        \\{"event":"fault","details":{"kind":"partition","node":"redis","duration_ns":300,
        ++
            \\"healed":true,"until":null}}
    },
    .{
        3_000_000_000,
        \\{"output":{"source":"bank","stream":"stderr","text":"connection refused by redis"}}
    },
};

test "conditions: paths, operators, and/or, quoted values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fault = try event_test(arena, condition_events[0][0], condition_events[0][1]);
    const output = try event_test(arena, condition_events[1][0], condition_events[1][1]);
    for (condition_checks) |check| {
        const condition = try parse(arena, check[0]);
        testing.expectEqual(check[1], condition.matches(fault)) catch |err| {
            std.debug.print("live, fault: {s}\n", .{check[0]});
            return err;
        };
        testing.expectEqual(check[2], condition.matches(output)) catch |err| {
            std.debug.print("live, output: {s}\n", .{check[0]});
            return err;
        };
    }
}
