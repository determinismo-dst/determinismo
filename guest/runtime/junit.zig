// SPDX-License-Identifier: MIT
//! A JUnit XML report's test cases (pytest's --junitxml, clojure.test.junit, Jest's jest-junit,
//! go-junit-report): each `<testcase>`'s classname and name, whether it holds a `<failure>` or
//! an `<error>` (skipped ones pass), and that element's message: its message attribute and its
//! text, both (the attribute alone when there is no text). Read by `det-assert junit`:
//! each test a property of its own.
const std = @import("std");

pub const Case = struct { name: []const u8, failed: bool, message: []const u8 = "" };

pub fn cases(arena: std.mem.Allocator, report: []const u8) ![]const Case {
    var out: std.ArrayList(Case) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, report, at, "<testcase")) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, report, open, '>') orelse break;
        const tag = report[open..tag_end];
        const closed = tag.len > 0 and tag[tag.len - 1] == '/';
        var body: []const u8 = "";
        at = tag_end + 1;
        if (!closed) {
            const close = std.mem.indexOfPos(u8, report, at, "</testcase>") orelse report.len;
            body = report[at..close];
            at = close;
        }
        const class = attribute(tag, "classname") orelse "";
        const named = attribute(tag, "name") orelse continue;
        // Kaocha's kaocha-junit-xml names a test by its whole id (`ns/var`) beside the namespace
        // as the classname: the namespace once (`ns::var`, as clojure.test.junit's reads).
        const name = if (class.len > 0 and named.len > class.len + 1 and
            std.mem.startsWith(u8, named, class) and named[class.len] == '/') named[class.len + 1 ..] else named;
        const full = if (class.len > 0) try std.fmt.allocPrint(arena, "{s}::{s}", .{ class, name }) else name;
        const failure = element_index(body, "<failure") orelse element_index(body, "<error");
        var message: []const u8 = "";
        if (failure) |start| {
            const element_end = std.mem.indexOfScalarPos(u8, body, start, '>') orelse body.len;
            const summary = try unescape(arena, attribute(body[start..element_end], "message") orelse "");
            var text: []const u8 = "";
            if (element_end < body.len and body[element_end - 1] != '/') {
                const text_end = std.mem.indexOfScalarPos(u8, body, element_end, '<') orelse body.len;
                text = try unescape(arena, std.mem.trim(u8, body[element_end + 1 .. text_end], " \t\r\n"));
            }
            // Both, as producers write them: the attribute a summary (often cut short: a runner's
            // 200 characters lost jank CI run 1898's cases), the text the whole (expected and
            // actual, a stack trace; clojure.test.junit's only). An attribute the text starts
            // with is a cut copy of it: the text alone.
            message = if (text.len == 0)
                summary
            else if (summary.len == 0 or std.mem.startsWith(u8, text, summary))
                text
            else
                try std.fmt.allocPrint(arena, "{s}\n{s}", .{ summary, text });
        }
        try out.append(arena, .{ .name = try unescape(arena, full), .failed = failure != null, .message = message });
    }
    return out.items;
}

/// Where a case's body opens the element `opening` (`<failure`, `<error`), outside what the
/// test printed: its `<system-out>` and `<system-err>` and any CDATA section. Surefire, jest-junit
/// and go-junit-report write a case's output in CDATA, as is, and a passing test that printed an
/// `<error` was judged failing in every timeline (CE16, the Lean replica of determinismo).
fn element_index(body: []const u8, opening: []const u8) ?usize {
    var at: usize = 0;
    scan: while (std.mem.indexOfScalarPos(u8, body, at, '<')) |next| {
        const rest = body[next..];
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, body, next, "]]>") orelse return null;
            at = end + "]]>".len;
            continue;
        }
        inline for (.{ "system-out", "system-err" }) |captured| {
            if (std.mem.startsWith(u8, rest, "<" ++ captured)) {
                const tag_end = std.mem.indexOfScalarPos(u8, body, next, '>') orelse return null;
                if (body[tag_end - 1] == '/') {
                    at = tag_end + 1;
                } else {
                    const end = captured_end(body, tag_end, "</" ++ captured ++ ">") orelse return null;
                    at = end + "</".len + captured.len + ">".len;
                }
                continue :scan;
            }
        }
        if (std.mem.startsWith(u8, rest, opening)) return next;
        at = next + 1;
    }
    return null;
}

/// Where a captured element's closing tag is, past `from`: a CDATA section before it is the
/// output's, whatever it holds (its own closing tag, printed by a test of something that writes
/// JUnit XML: CE41, the Lean replica of determinismo).
fn captured_end(body: []const u8, from: usize, closing: []const u8) ?usize {
    var at = from;
    while (true) {
        const close = std.mem.indexOfPos(u8, body, at, closing) orelse return null;
        if (std.mem.indexOfPos(u8, body, at, "<![CDATA[")) |cdata| if (cdata < close) {
            const end = std.mem.indexOfPos(u8, body, cdata, "]]>") orelse return null;
            at = end + "]]>".len;
            continue;
        };
        return close;
    }
}

fn attribute(tag: []const u8, comptime key: []const u8) ?[]const u8 {
    const marker = " " ++ key ++ "=\"";
    const start = (std.mem.indexOf(u8, tag, marker) orelse return null) + marker.len;
    const stop = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..stop];
}

fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    outer: while (at < text.len) {
        if (text[at] == '&') {
            for ([_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } }) |entity| {
                if (std.mem.startsWith(u8, text[at..], entity[0])) {
                    try out.appendSlice(arena, entity[1]);
                    at += entity[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(arena, text[at]);
        at += 1;
    }
    return out.items;
}

test "a JUnit report's cases: failures and errors fail with their message, skips pass, names unescaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="1" failures="1">
        \\<testcase classname="test.test_util.TestUtil" name="test_ok[a&amp;b]" time="0.001" />
        \\<testcase classname="test.test_util.TestUtil" name="test_bad" time="0.1"><failure message="assert 1 == 2">x</failure></testcase>
        \\<testcase classname="test.test_tls" name="test_err" time="0.1"><error message="boom &lt;here&gt;">y</error></testcase>
        \\<testcase classname="test.test_tls" name="test_skip" time="0"><skipped message="no"/></testcase>
        \\<testcase name="test-run!" classname="clojure.core-test.run-bang">
        \\</testcase>
        \\<testcase name="test-abs" classname="clojure.core-test.abs"><failure>expected: (= 1 (abs -2))
        \\  actual: (not (= 1 2))</failure></testcase>
        \\</testsuite></testsuites>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqual(@as(usize, 6), found.len);
    try std.testing.expectEqualStrings("test.test_util.TestUtil::test_ok[a&b]", found[0].name);
    try std.testing.expect(!found[0].failed);
    try std.testing.expect(found[1].failed);
    try std.testing.expectEqualStrings("assert 1 == 2\nx", found[1].message);
    try std.testing.expect(found[2].failed);
    try std.testing.expectEqualStrings("boom <here>\ny", found[2].message);
    try std.testing.expect(!found[3].failed);
    try std.testing.expectEqualStrings("clojure.core-test.run-bang::test-run!", found[4].name);
    try std.testing.expect(!found[4].failed);
    try std.testing.expect(found[5].failed);
    try std.testing.expectEqualStrings("expected: (= 1 (abs -2))\n  actual: (not (= 1 2))", found[5].message);
}

test "a name that repeats its classname (Kaocha's ns/var ids) is not prefixed twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<testsuite>
        \\<testcase name="determinismo-demo.failures-test/racy-counter" classname="determinismo-demo.failures-test"><failure>no</failure></testcase>
        \\<testcase name="clojure.core-test.add-watch/test-add-watch" classname="clojure.core-test.add-watch"></testcase>
        \\<testcase name="clojure.core-test.add-watcher/x" classname="clojure.core-test.add-watch"></testcase>
        \\</testsuite>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("determinismo-demo.failures-test::racy-counter", found[0].name);
    try std.testing.expect(found[0].failed);
    try std.testing.expectEqualStrings("clojure.core-test.add-watch::test-add-watch", found[1].name);
    // Another namespace that only starts like the classname keeps its whole name.
    try std.testing.expectEqualStrings("clojure.core-test.add-watch::clojure.core-test.add-watcher/x", found[2].name);
}

test "a failure's message keeps its element's text: a cut attribute gives way to the whole text, a summary comes first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<testsuite>
        \\<testcase classname="a" name="cut"><failure message="the case: {:form (let [a 1">the case: {:form (let [a 1] (* a 2)) :answer 3}</failure></testcase>
        \\<testcase classname="a" name="summary"><error message="boom">at f (x.py:3)
        \\at g (x.py:9)</error></testcase>
        \\<testcase classname="a" name="same"><failure message="same">same</failure></testcase>
        \\</testsuite>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqualStrings("the case: {:form (let [a 1] (* a 2)) :answer 3}", found[0].message);
    try std.testing.expectEqualStrings("boom\nat f (x.py:3)\nat g (x.py:9)", found[1].message);
    try std.testing.expectEqualStrings("same", found[2].message);
}

test "a test case's captured output never fails it" {
    // CE16 (the Lean replica of determinismo): Surefire, jest-junit and go-junit-report write a
    // case's output in CDATA, as is; a passing test that printed an `<error` or `<failure` element
    // was judged failing in every timeline. A failure's own text in CDATA still fails its case.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<testsuite>
        \\<testcase classname="api.ErrorsTest" name="renders_503" time="0.1"><system-out><![CDATA[<error code="503">unavailable</error>]]></system-out></testcase>
        \\<testcase classname="api.ErrorsTest" name="logs_failure" time="0.1"><system-err><![CDATA[<failure reason="timeout"/>]]></system-err></testcase>
        \\<testcase classname="api.ErrorsTest" name="fails" time="0.1"><system-out><![CDATA[ok]]></system-out><failure message="no">x</failure></testcase>
        \\<testcase classname="api.ErrorsTest" name="errs" time="0.1"><error message="boom"><![CDATA[at f (x.py:3)]]></error></testcase>
        \\<testcase classname="api.ErrorsTest" name="quiet" time="0.1"><system-out/><system-err/></testcase>
        \\</testsuite>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expect(!found[0].failed);
    try std.testing.expect(!found[1].failed);
    try std.testing.expect(found[2].failed);
    try std.testing.expectEqualStrings("no\nx", found[2].message);
    try std.testing.expect(found[3].failed);
    try std.testing.expect(!found[4].failed);
}

// CE41 (the Lean replica of determinismo): a CDATA section of captured output holding the element's
// own closing tag.
test "captured output that prints its own closing tag never fails its test" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<testsuite>
        \\<testcase classname="report.WriterTest" name="writes_an_error" time="0.1"><system-out><![CDATA[expected:
        \\<system-out>log</system-out><error message="boom"/>
        \\]]></system-out></testcase>
        \\<testcase classname="report.WriterTest" name="writes_a_failure" time="0.1"><system-err><![CDATA[</system-err><failure message="no"/>]]></system-err></testcase>
        \\</testsuite>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expect(!found[0].failed);
    try std.testing.expect(!found[1].failed);
}

test "captured output that prints test cases makes no test of its own and hides no failure" {
    // CE49 (the Lean replica of determinismo): a case's body ended at the first `</testcase>`
    // after its tag, through any CDATA, and the next case was looked for from there: a test that
    // printed test cases had them judged as tests of their own (failing in every timeline), and
    // a real failure after printed output was never seen.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const report =
        \\<testsuite>
        \\<testcase classname="report.WriterTest" name="writes_a_report" time="0.1"><system-out><![CDATA[<testsuite>
        \\<testcase classname="printed" name="ok"></testcase>
        \\<testcase classname="printed" name="bad"><failure message="x"/></testcase>
        \\</testsuite>]]></system-out></testcase>
        \\<testcase classname="report.WriterTest" name="closes_a_case" time="0.1"><system-out><![CDATA[</testcase>]]></system-out><failure message="expected two cases"/></testcase>
        \\</testsuite>
    ;
    const found = try cases(arena_state.allocator(), report);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("report.WriterTest::writes_a_report", found[0].name);
    try std.testing.expect(!found[0].failed);
    try std.testing.expectEqualStrings("report.WriterTest::closes_a_case", found[1].name);
    try std.testing.expect(found[1].failed);
    // A suite's own output (go-junit-report writes a package's there) and a comment print none.
    const suite_output =
        \\<testsuite><testcase classname="pkg" name="TestA"/>
        \\<!-- <testcase classname="commented" name="out"><failure/></testcase> -->
        \\<system-out><![CDATA[<testcase classname="printed" name="bad"><failure message="x"/></testcase>]]></system-out></testsuite>
    ;
    const suite_found = try cases(arena_state.allocator(), suite_output);
    try std.testing.expectEqual(@as(usize, 1), suite_found.len);
    try std.testing.expectEqualStrings("pkg::TestA", suite_found[0].name);
}
