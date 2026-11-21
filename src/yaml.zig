// SPDX-License-Identifier: MIT
//! The subset of YAML that Compose files use, read into a tree: block mappings and sequences by
//! indentation, flow sequences `[a, b]` and mappings `{a: b}` (over several lines too: Compose's
//! `test:` lists, a trailing comma allowed), plain and quoted scalars (over several lines
//! too, folded), block scalars (`|`, `>`), comments, anchors (`&name`) and their aliases (`*name`)
//! with merge keys (`<<: *name`, `<<: [*a, *b]`: the mapping's own keys first), as Compose files
//! share settings through `x-` fields. No tags, aliases inside a flow collection's scalars, or
//! multi-document streams (rejected, not misread).
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Value = union(enum) {
    scalar: []const u8,
    sequence: []const Value,
    mapping: []const Entry,
    empty,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(value: Value, key: []const u8) ?Value {
        if (value != .mapping) return null;
        for (value.mapping) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

const Line = struct { indent: u32, text: []const u8, number: u32 };

const depth_max = 64;
const lines_max = 1 << 20;

pub fn parse(arena: std.mem.Allocator, source: []const u8) !Value {
    var lines: std.ArrayList(Line) = .empty;
    var splitter = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (splitter.next()) |raw| {
        number += 1;
        if (lines.items.len == lines_max) return error.TooManyLines;
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        const content = std.mem.trimStart(u8, line, " ");
        if (std.mem.indexOfScalar(u8, line[0 .. line.len - content.len], '\t') != null) {
            return error.TabIndentation;
        }
        if (std.mem.startsWith(u8, content, "---") or std.mem.startsWith(u8, content, "...")) {
            if (lines.items.len == 0) continue; // A leading document marker.
            return error.MultipleDocuments;
        }
        try lines.append(arena, .{
            .indent = @intCast(line.len - content.len),
            .text = content,
            .number = number,
        });
    }
    var parser = Parser{ .arena = arena, .lines = lines.items };
    parser.skip_blank();
    if (parser.index == parser.lines.len) return .empty;
    const value = parser.block(parser.lines[parser.index].indent, 0) catch |err| return parser.failed(err);
    parser.skip_blank();
    if (parser.index != parser.lines.len) return parser.failed(error.UnexpectedIndentation);
    return value;
}

const Parser = struct {
    arena: std.mem.Allocator,
    /// Owned: a "- key: value" line is rewritten in place as "key: value", one level deeper.
    lines: []Line,
    index: usize = 0,
    /// Anchored values by name, as read so far: an alias names one before it.
    anchors: std.StringHashMapUnmanaged(Value) = .empty,

    /// Says where the file stopped being read: the line the parser was at (a value's own
    /// lines are consumed before what follows them is judged, so it is that line or the one
    /// before). Tests expect errors and stay quiet.
    fn failed(parser: *const Parser, err: anyerror) anyerror {
        if (builtin.is_test or parser.lines.len == 0) return err;
        const line = parser.lines[@min(parser.index, parser.lines.len - 1)];
        std.debug.print("[determinismo] yaml: {s} at line {d}: {s}\n", .{ @errorName(err), line.number, line.text });
        return err;
    }

    fn skip_blank(parser: *Parser) void {
        while (parser.index < parser.lines.len) : (parser.index += 1) {
            const text = parser.lines[parser.index].text;
            if (text.len > 0 and text[0] != '#') return;
        }
    }

    /// A block (mapping or sequence) whose lines are indented by exactly `indent`.
    fn block(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        if (depth == depth_max) return error.TooDeep;
        parser.skip_blank();
        const first = parser.lines[parser.index];
        assert(first.indent == indent);
        if (is_sequence_item(first.text)) return parser.sequence(indent, depth);
        return parser.mapping(indent, depth);
    }

    fn sequence(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            parser.skip_blank();
            if (parser.index == parser.lines.len) break;
            const line = parser.lines[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.BadSequence;
            if (!is_sequence_item(line.text)) break; // The next key of a mapping at this level.
            const rest = std.mem.trimStart(u8, line.text[1..], " ");
            if (rest.len == 0) {
                parser.index += 1;
                try items.append(parser.arena, try parser.nested(indent, depth));
            } else if (mapping_key(rest) != null) {
                // "- key: value" starts a mapping indented where `key` is.
                const item_indent = indent + @as(u32, @intCast(line.text.len - rest.len));
                parser.lines[parser.index] = .{
                    .indent = item_indent,
                    .text = rest,
                    .number = line.number,
                };
                try items.append(parser.arena, try parser.mapping(item_indent, depth + 1));
            } else {
                parser.index += 1;
                try items.append(parser.arena, try parser.scalar_or_flow(rest, indent, depth));
            }
        }
        return .{ .sequence = items.items };
    }

    fn mapping(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        var entries: std.ArrayList(Value.Entry) = .empty;
        var merged: std.ArrayList(Value) = .empty;
        while (true) {
            parser.skip_blank();
            if (parser.index == parser.lines.len) break;
            const line = parser.lines[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.UnexpectedIndentation;
            const split = mapping_key(line.text) orelse return error.ExpectedKey;
            const key = try unquote(parser.arena, split.key);
            parser.index += 1;
            const value = if (split.value.len == 0)
                try parser.nested(indent, depth)
            else
                try parser.scalar_or_flow(split.value, indent, depth);
            // A merge key's mappings, taken after: the mapping's own keys stand wherever they are.
            if (std.mem.eql(u8, split.key, "<<")) {
                try merged.append(parser.arena, value);
                continue;
            }
            try entries.append(parser.arena, .{ .key = key, .value = value });
        }
        for (merged.items) |value| switch (value) {
            .mapping => |fields| try merge(parser.arena, &entries, fields),
            .sequence => |items| for (items) |item| {
                if (item != .mapping) return error.BadMerge;
                try merge(parser.arena, &entries, item.mapping);
            },
            else => return error.BadMerge,
        };
        return .{ .mapping = entries.items };
    }

    /// A merged mapping's entries whose keys the mapping does not have yet (its own, or an earlier
    /// merged one's: the first in a merge list wins, as YAML has it).
    fn merge(arena: std.mem.Allocator, entries: *std.ArrayList(Value.Entry), fields: []const Value.Entry) !void {
        next: for (fields) |field| {
            for (entries.items) |entry| if (std.mem.eql(u8, entry.key, field.key)) continue :next;
            try entries.append(arena, field);
        }
    }

    /// What follows "key:" or "-" on the next lines: a deeper block, or nothing. Compose also
    /// writes sequences under a key at the key's own indentation.
    fn nested(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        parser.skip_blank();
        if (parser.index == parser.lines.len) return .empty;
        const next = parser.lines[parser.index];
        if (next.indent > indent and next.text.len > 0 and (next.text[0] == '[' or next.text[0] == '{')) {
            parser.index += 1;
            return parser.scalar_or_flow(next.text, indent, depth);
        }
        if (next.indent > indent) return parser.block(next.indent, depth + 1);
        if (next.indent == indent and is_sequence_item(next.text)) {
            return parser.sequence(indent, depth + 1);
        }
        return .empty;
    }

    fn scalar_or_flow(parser: *Parser, text: []const u8, indent: u32, depth: u32) anyerror!Value {
        if (text.len > 0 and (text[0] == '"' or text[0] == '\'') and quote_end(text[0], text, 1) == null) {
            return .{ .scalar = try unquote(parser.arena, try parser.quoted_text(text)) };
        }
        const value = strip_comment(text);
        if (value.len == 0) return .empty;
        if (value[0] == '!') return error.UnsupportedYaml;
        if (value[0] == '*') {
            const name = std.mem.trimEnd(u8, value[1..], " ");
            return parser.anchors.get(name) orelse error.UnknownAlias;
        }
        if (value[0] == '&') {
            // `&name`, then its value: on the line, or the block below.
            const end = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
            const name = value[1..end];
            if (name.len == 0) return error.UnsupportedYaml;
            const rest = std.mem.trimStart(u8, value[end..], " ");
            const anchored = if (rest.len == 0)
                try parser.nested(indent, depth)
            else
                try parser.scalar_or_flow(rest, indent, depth);
            try parser.anchors.put(parser.arena, name, anchored);
            return anchored;
        }
        if (value[0] == '|' or value[0] == '>') return parser.block_scalar(value[0] == '>', indent);
        if (value[0] == '[' or value[0] == '{') {
            var flow = Flow{ .arena = parser.arena, .text = try parser.flow_text(value), .aliases = &parser.anchors };
            const parsed = try flow.value(depth);
            flow.skip_spaces();
            if (flow.position != flow.text.len) return error.TrailingCharacters;
            return parsed;
        }
        if (value[0] == '"' or value[0] == '\'') return .{ .scalar = try unquote(parser.arena, value) };
        // A comment ends a plain scalar: nothing after it goes on with it.
        if (value.len != text.len) return .{ .scalar = value };
        return .{ .scalar = try parser.plain_text(value, indent) };
    }

    /// A plain scalar goes on over the next lines indented deeper than its key or dash
    /// (Vitess's Compose file: an environment entry's flags on two lines), folded as YAML folds
    /// them: a line break is a space, each blank line between two of its lines a line break. A
    /// comment ends it. A deeper line that reads as a key or a sequence item continues nothing:
    /// it stays the caller's error, as a file's mistake more often than a scalar's text.
    fn plain_text(parser: *Parser, first: []const u8, indent: u32) ![]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        while (true) {
            var next = parser.index;
            while (next < parser.lines.len and parser.lines[next].text.len == 0) next += 1;
            if (next == parser.lines.len) break;
            const line = parser.lines[next];
            if (line.indent <= indent or line.text[0] == '#') break;
            if (mapping_key(line.text) != null or is_sequence_item(line.text)) break;
            const text = strip_comment(line.text);
            if (joined.items.len == 0) try joined.appendSlice(parser.arena, first);
            const blank = next - parser.index;
            if (blank == 0) {
                try joined.append(parser.arena, ' ');
            } else {
                try joined.appendNTimes(parser.arena, '\n', blank);
            }
            try joined.appendSlice(parser.arena, text);
            parser.index = next + 1;
            if (text.len != line.text.len) break;
        }
        return if (joined.items.len == 0) first else joined.items;
    }

    /// A quoted scalar that goes on over the next lines (Vitess's Compose file: a `sh -c`
    /// command of five in single quotes), up to its closing quote, folded as a plain one's: a
    /// line break is a space, each blank line a line break. Nothing but a comment follows it.
    fn quoted_text(parser: *Parser, first: []const u8) ![]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(parser.arena, first);
        var blank: usize = 0;
        while (parser.index < parser.lines.len) {
            const text = parser.lines[parser.index].text;
            parser.index += 1;
            if (text.len == 0) {
                blank += 1;
                continue;
            }
            if (blank == 0) {
                try joined.append(parser.arena, ' ');
            } else {
                try joined.appendNTimes(parser.arena, '\n', blank);
            }
            blank = 0;
            const end = quote_end(first[0], text, 0) orelse {
                try joined.appendSlice(parser.arena, text);
                continue;
            };
            try joined.appendSlice(parser.arena, text[0..end]);
            if (strip_comment(std.mem.trimStart(u8, text[end..], " ")).len > 0) return error.TrailingCharacters;
            return joined.items;
        }
        return error.UnterminatedQuote;
    }

    /// A flow collection that goes on over the next lines (the Kafka demo's DynamoDB healthcheck,
    /// `test:` then `[` and an item a line): its lines joined by spaces until its brackets close.
    fn flow_text(parser: *Parser, first: []const u8) ![]const u8 {
        var open = flow_depth(first, 0);
        if (open <= 0) return first;
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(parser.arena, first);
        while (open > 0) {
            if (parser.index == parser.lines.len) return error.UnterminatedFlow;
            const text = strip_comment(parser.lines[parser.index].text);
            parser.index += 1;
            if (text.len == 0) continue;
            try joined.append(parser.arena, ' ');
            try joined.appendSlice(parser.arena, text);
            open = flow_depth(text, open);
        }
        return joined.items;
    }

    /// `|` keeps newlines, `>` folds them into spaces; lines deeper than the key belong to it.
    fn block_scalar(parser: *Parser, folded: bool, indent: u32) !Value {
        var text: std.ArrayList(u8) = .empty;
        var content_indent: ?u32 = null;
        while (parser.index < parser.lines.len) : (parser.index += 1) {
            const line = parser.lines[parser.index];
            if (line.text.len > 0 and line.indent <= indent) break;
            if (content_indent == null and line.text.len > 0) content_indent = line.indent;
            if (text.items.len > 0) try text.append(parser.arena, if (folded) ' ' else '\n');
            const base = content_indent orelse line.indent;
            const extra = if (line.text.len == 0) 0 else line.indent -| base;
            try text.appendNTimes(parser.arena, ' ', extra);
            try text.appendSlice(parser.arena, line.text);
        }
        return .{ .scalar = text.items };
    }
};

/// Flow collections: `[a, "b", {c: d}]`.
const Flow = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    position: usize = 0,
    /// The block parser's anchors, for aliases in the collection (a merge list `[*a, *b]`).
    aliases: ?*const std.StringHashMapUnmanaged(Value) = null,

    fn skip_spaces(flow: *Flow) void {
        while (flow.position < flow.text.len and flow.text[flow.position] == ' ') {
            flow.position += 1;
        }
    }

    fn value(flow: *Flow, depth: u32) anyerror!Value {
        if (depth == depth_max) return error.TooDeep;
        flow.skip_spaces();
        if (flow.position == flow.text.len) return error.UnexpectedEnd;
        switch (flow.text[flow.position]) {
            '[' => {
                flow.position += 1;
                var items: std.ArrayList(Value) = .empty;
                while (true) {
                    flow.skip_spaces();
                    if (flow.peek(']')) break;
                    try items.append(flow.arena, try flow.value(depth + 1));
                    flow.skip_spaces();
                    if (flow.peek(']')) break;
                    if (!flow.peek(',')) return error.ExpectedComma;
                }
                return .{ .sequence = items.items };
            },
            '{' => {
                flow.position += 1;
                var entries: std.ArrayList(Value.Entry) = .empty;
                while (true) {
                    flow.skip_spaces();
                    if (flow.peek('}')) break;
                    const key = try flow.scalar(":");
                    if (!flow.peek(':')) return error.ExpectedColon;
                    const entry_value = try flow.value(depth + 1);
                    try entries.append(flow.arena, .{ .key = key, .value = entry_value });
                    flow.skip_spaces();
                    if (flow.peek('}')) break;
                    if (!flow.peek(',')) return error.ExpectedComma;
                }
                return .{ .mapping = entries.items };
            },
            // An alias (a merge list `[*a, *b]`); an anchor or a tag here is not read (rejected,
            // not misread).
            '*' => {
                flow.position += 1;
                const name = try flow.scalar(",]}");
                const anchors = flow.aliases orelse return error.UnsupportedYaml;
                return anchors.get(name) orelse error.UnknownAlias;
            },
            '&', '!' => return error.UnsupportedYaml,
            else => return .{ .scalar = try flow.scalar(",]}") },
        }
    }

    fn peek(flow: *Flow, byte: u8) bool {
        if (flow.position < flow.text.len and flow.text[flow.position] == byte) {
            flow.position += 1;
            return true;
        }
        return false;
    }

    fn scalar(flow: *Flow, comptime stops: []const u8) ![]const u8 {
        flow.skip_spaces();
        const start = flow.position;
        if (start < flow.text.len and (flow.text[start] == '"' or flow.text[start] == '\'')) {
            const quote = flow.text[start];
            flow.position += 1;
            while (flow.position < flow.text.len) {
                const byte = flow.text[flow.position];
                if (quote == '"' and byte == '\\') {
                    flow.position += 2;
                    continue;
                }
                if (byte == quote) {
                    // '' inside single quotes is a quote.
                    const doubled = quote == '\'' and flow.position + 1 < flow.text.len and
                        flow.text[flow.position + 1] == '\'';
                    if (!doubled) break;
                    flow.position += 2;
                    continue;
                }
                flow.position += 1;
            }
            if (flow.position == flow.text.len) return error.UnterminatedString;
            flow.position += 1;
            return unquote(flow.arena, flow.text[start..flow.position]);
        }
        while (flow.position < flow.text.len and
            std.mem.indexOfScalar(u8, stops, flow.text[flow.position]) == null) flow.position += 1;
        return std.mem.trim(u8, flow.text[start..flow.position], " ");
    }
};

/// The open brackets after `text`, from `open` before it: quoted brackets left out ('' inside
/// single quotes reads as two quotes, which leave the state as it was).
fn flow_depth(text: []const u8, open: i32) i32 {
    var depth = open;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |q| {
            if (q == '"' and byte == '\\') {
                index += 1;
            } else if (byte == q) quote = null;
            continue;
        }
        switch (byte) {
            '"', '\'' => quote = byte,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

test "flow collections over several lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The Kafka demo's DynamoDB healthcheck (antithesishq/demo-data-streaming at c248a3d).
    const root = try parse(arena,
        \\ddb:
        \\  healthcheck:
        \\    test:
        \\      [
        \\        "CMD-SHELL",
        \\        'if [ "$(curl -s -o /dev/null -I -w ''%{http_code}'' http://localhost:8000)" == "400" ]; then exit 0; else exit 1; fi',
        \\      ]
        \\    interval: 5s
        \\  ports: [ "8000:8000",
        \\    "9000" ]
        \\
    );
    const ddb = root.get("ddb").?;
    const check = ddb.get("healthcheck").?;
    const test_items = check.get("test").?.sequence;
    try std.testing.expectEqual(@as(usize, 2), test_items.len);
    try std.testing.expectEqualStrings("CMD-SHELL", test_items[0].scalar);
    try std.testing.expect(std.mem.indexOf(u8, test_items[1].scalar, "-w '%{http_code}' http") != null);
    try std.testing.expectEqualStrings("5s", check.get("interval").?.scalar);
    try std.testing.expectEqualStrings("9000", ddb.get("ports").?.sequence[1].scalar);
}

fn is_sequence_item(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

const Split = struct { key: []const u8, value: []const u8 };

/// `key: value` (the colon followed by a space or the end, outside quotes).
fn mapping_key(text: []const u8) ?Split {
    var quote: ?u8 = null;
    for (text, 0..) |byte, index| {
        if (quote) |open| {
            if (byte == open) quote = null;
            continue;
        }
        switch (byte) {
            '"', '\'' => if (index == 0) {
                quote = byte;
            },
            '#' => if (index > 0 and text[index - 1] == ' ') return null,
            ':' => if (index + 1 == text.len or text[index + 1] == ' ') {
                return .{
                    .key = std.mem.trim(u8, text[0..index], " "),
                    .value = std.mem.trim(u8, text[index + 1 ..], " "),
                };
            },
            '[', '{' => if (index == 0) return null,
            else => {},
        }
    }
    return null;
}

/// Where a quoted scalar ends in `text`, past its closing quote, looking from `start`; null when
/// it goes on past the line. Two single quotes are one inside single quotes; a backslash escapes
/// the next byte inside double ones.
fn quote_end(open: u8, text: []const u8, start: usize) ?usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (open == '"' and text[index] == '\\') {
            index += 1;
            continue;
        }
        if (text[index] != open) continue;
        if (open == '\'' and index + 1 < text.len and text[index + 1] == '\'') {
            index += 1;
            continue;
        }
        return index + 1;
    }
    return null;
}

fn strip_comment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (text, 0..) |byte, index| {
        if (quote) |open| {
            if (byte == open) quote = null;
            continue;
        }
        if ((byte == '"' or byte == '\'') and index == 0) quote = byte;
        if (byte == '#' and (index == 0 or text[index - 1] == ' ')) {
            return std.mem.trimEnd(u8, text[0..index], " ");
        }
    }
    return text;
}

fn unquote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        return std.mem.replaceOwned(u8, arena, text[1 .. text.len - 1], "''", "'");
    }
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return text;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < text.len - 1) : (index += 1) {
        if (text[index] != '\\' or index + 1 == text.len - 1) {
            try out.append(arena, text[index]);
            continue;
        }
        index += 1;
        try out.append(arena, switch (text[index]) {
            'n' => '\n',
            't' => '\t',
            else => text[index],
        });
    }
    return out.items;
}

test "a compose file" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\# The shop.
        \\services:
        \\  postgres:
        \\    image: "postgres:17-alpine"
        \\    environment:
        \\      POSTGRES_HOST_AUTH_METHOD: trust
        \\    ports: ["5432"]
        \\  client:
        \\    build:
        \\      context: ./client
        \\    command: [sleep, infinity]   # Tests exec into it.
        \\    depends_on:
        \\    - postgres
        \\    healthcheck:
        \\      test: |
        \\        pg_isready -h postgres
        \\        echo ok
    ;
    const root = try parse(arena_state.allocator(), source);
    const services = root.get("services").?;
    const postgres = services.get("postgres").?;
    try std.testing.expectEqualStrings("postgres:17-alpine", postgres.get("image").?.scalar);
    const environment = postgres.get("environment").?;
    const method = environment.get("POSTGRES_HOST_AUTH_METHOD").?.scalar;
    try std.testing.expectEqualStrings("trust", method);
    try std.testing.expectEqualStrings("5432", postgres.get("ports").?.sequence[0].scalar);
    const client = services.get("client").?;
    try std.testing.expectEqualStrings("infinity", client.get("command").?.sequence[1].scalar);
    try std.testing.expectEqualStrings("postgres", client.get("depends_on").?.sequence[0].scalar);
    const test_script = client.get("healthcheck").?.get("test").?.scalar;
    try std.testing.expectEqualStrings("pg_isready -h postgres\necho ok", test_script);
}

test "sequences of mappings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\volumes:
        \\  - type: bind
        \\    source: ./data
        \\  - name: x
    ;
    const root = try parse(arena_state.allocator(), source);
    const volumes = root.get("volumes").?.sequence;
    try std.testing.expectEqual(@as(usize, 2), volumes.len);
    try std.testing.expectEqualStrings("./data", volumes[0].get("source").?.scalar);
    try std.testing.expectEqualStrings("x", volumes[1].get("name").?.scalar);
}

test "anchors, aliases and merge keys, as Compose files share settings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Antithesis's formalized Raft projects' shape: x- fields anchored, merged into each service,
    // its own keys over the merged ones wherever they stand.
    const root = try parse(arena,
        \\x-raft: &raft
        \\  platform: linux/amd64
        \\  image: hashicorp-raft:latest
        \\x-env: &env
        \\  PEERS: raft1=raft1:7000
        \\  NODE_ID: none
        \\port: &port 7000
        \\services:
        \\  raft1:
        \\    image: own:1
        \\    <<: *raft
        \\    environment:
        \\      <<: *env
        \\      NODE_ID: raft1
        \\  raft2:
        \\    <<: [*raft, {hostname: two}]
        \\    port: *port
        \\
    );
    const services = root.get("services").?;
    const raft1 = services.get("raft1").?;
    try std.testing.expectEqualStrings("own:1", raft1.get("image").?.scalar);
    try std.testing.expectEqualStrings("linux/amd64", raft1.get("platform").?.scalar);
    const environment = raft1.get("environment").?;
    try std.testing.expectEqualStrings("raft1", environment.get("NODE_ID").?.scalar);
    try std.testing.expectEqualStrings("raft1=raft1:7000", environment.get("PEERS").?.scalar);
    try std.testing.expectEqual(@as(usize, 2), environment.mapping.len); // NODE_ID once.
    const raft2 = services.get("raft2").?;
    try std.testing.expectEqualStrings("hashicorp-raft:latest", raft2.get("image").?.scalar);
    try std.testing.expectEqualStrings("two", raft2.get("hostname").?.scalar);
    try std.testing.expectEqualStrings("7000", raft2.get("port").?.scalar);
    // An alias in a flow collection too; never misread: an alias of no anchor, an anchor inside a
    // flow collection, a tag.
    const flow = try parse(arena, "a: &x 1\nb: [*x, y]");
    try std.testing.expectEqualStrings("1", flow.get("b").?.sequence[0].scalar);
    try std.testing.expectError(error.UnknownAlias, parse(arena, "a: *nothing"));
    try std.testing.expectError(error.UnsupportedYaml, parse(arena, "a: [&x 1]"));
    try std.testing.expectError(error.UnsupportedYaml, parse(arena, "a: !tag 1"));
}

test "a plain scalar over several lines is one, folded" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Vitess's Compose file: an environment entry's flags go on over a second line.
    const source =
        \\services:
        \\  vtorc:
        \\    environment:
        \\      - TOPOLOGY_FLAGS=--topo_implementation etcd2 --topo_global_server_address etcd:2379
        \\        --topo_global_root /vitess/global
        \\      - WEB_PORT=8080
        \\    command: sh -c
        \\      /script/vtorc-up.sh
        \\
        \\      --verbose
        \\    image: docker.io/vitess/lite:latest
        \\    healthcheck:
        \\      test: /usr/bin/mysql --user=root --execute
        \\        "SHOW DATABASES;"
        \\      timeout: 10s
    ;
    const vtorc = (try parse(arena, source)).get("services").?.get("vtorc").?;
    const environment = vtorc.get("environment").?.sequence;
    try std.testing.expectEqual(@as(usize, 2), environment.len);
    try std.testing.expectEqualStrings(
        "TOPOLOGY_FLAGS=--topo_implementation etcd2 --topo_global_server_address etcd:2379 --topo_global_root /vitess/global",
        environment[0].scalar,
    );
    try std.testing.expectEqualStrings("WEB_PORT=8080", environment[1].scalar);
    // A line break folds into a space, a blank line into a line break.
    try std.testing.expectEqualStrings("sh -c /script/vtorc-up.sh\n--verbose", vtorc.get("command").?.scalar);
    try std.testing.expectEqualStrings("docker.io/vitess/lite:latest", vtorc.get("image").?.scalar);
    // A quote inside a plain scalar is its text.
    const healthcheck = vtorc.get("healthcheck").?;
    try std.testing.expectEqualStrings(
        "/usr/bin/mysql --user=root --execute \"SHOW DATABASES;\"",
        healthcheck.get("test").?.scalar,
    );
    try std.testing.expectEqualStrings("10s", healthcheck.get("timeout").?.scalar);
    // A deeper line that reads as a key is no scalar's continuation, nor is one after a quoted
    // scalar: both stay errors.
    try std.testing.expectError(error.UnexpectedIndentation, parse(arena, "a: b\n  c: d\n"));
    try std.testing.expectError(error.UnexpectedIndentation, parse(arena, "a: \"b\"\n  c\n"));
    try std.testing.expectError(error.BadSequence, parse(arena, "- a\n  c: d\n"));
    // A comment ends a plain scalar.
    try std.testing.expectError(error.UnexpectedIndentation, parse(arena, "a: b # c\n  d\n"));
}

test "a quoted scalar over several lines is one, folded, up to its closing quote" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Vitess's Compose file: a `sh -c` command of several lines in single quotes.
    const source =
        \\services:
        \\  vtctld:
        \\    command:
        \\      - sh
        \\      - -c
        \\      - ' /vt/bin/vtctld --topo_global_server_address etcd:2379
        \\        --topo_global_root /vitess/global --cell test
        \\        --service_map ''grpc-vtctl,grpc-vtctld'' --port 8080 '
        \\    depends_on:
        \\      etcd:
        \\          condition: service_healthy
        \\    labels:
        \\      note: "a: b
        \\
        \\        c \"d\" # e"   # A comment after it.
        \\      last: x
    ;
    const vtctld = (try parse(arena, source)).get("services").?.get("vtctld").?;
    const command = vtctld.get("command").?.sequence;
    try std.testing.expectEqual(@as(usize, 3), command.len);
    try std.testing.expectEqualStrings(
        " /vt/bin/vtctld --topo_global_server_address etcd:2379 --topo_global_root /vitess/global --cell test " ++
            "--service_map 'grpc-vtctl,grpc-vtctld' --port 8080 ",
        command[2].scalar,
    );
    try std.testing.expectEqualStrings("service_healthy", vtctld.get("depends_on").?.get("etcd").?.get("condition").?.scalar);
    // In double quotes: a blank line is a line break; a `#` inside is its text.
    try std.testing.expectEqualStrings("a: b\nc \"d\" # e", vtctld.get("labels").?.get("note").?.scalar);
    try std.testing.expectEqualStrings("x", vtctld.get("labels").?.get("last").?.scalar);
    try std.testing.expectError(error.UnterminatedQuote, parse(arena, "a: 'b\n  c\n"));
    try std.testing.expectError(error.TrailingCharacters, parse(arena, "a: 'b\n  c' d\n"));
}
