// SPDX-License-Identifier: MIT
//! libdeterminismo's interface as data: every function it exports, with its parameters' types
//! and what it does. ffi.zig implements them and checks each against this at compile time (a
//! function missing, extra or of another signature does not build), and `zig build guest` writes
//! it as libdeterminismo.json beside the library: what bindings in any language are made from
//! (sdk/clojure's determinismo.ffi makes its functions from it as it loads). And as
//! libdeterminismo.h, its C declarations, for C, C++ and what includes C headers (jank's
//! `(:include "libdeterminismo.h")`, Rust's bindgen).
//!
//! Types, as C sees them: `string` and `json` are two parameters, a pointer to UTF-8 bytes and
//! their length (`json`: JSON text, checked: what is not JSON is replaced by a string saying
//! so); `buffer` is a pointer to bytes the function writes and their capacity, the function
//! returning the size of what it has (written when it fits: call again with more room when
//! larger); `u64`, `i32`, `f64` and `bool` are themselves. A function's `i32` result is 0 when
//! it did what was asked, negative when it refused (`errors`).
const std = @import("std");

pub const version: u32 = 1;

pub const Type = enum { string, json, buffer, u64, i32, f64, bool };

pub const Param = struct { name: []const u8, type: Type };

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    /// Null: nothing.
    returns: ?Type,
    doc: []const u8,
};

/// What an `i32` result below 0 means.
pub const errors = [_]struct { code: i32, name: []const u8 }{
    .{ .code = -1, .name = "invalid_argument" },
    .{ .code = -2, .name = "unavailable" },
    .{ .code = -3, .name = "failed" },
};

fn p(name: []const u8, comptime t: Type) Param {
    return .{ .name = name, .type = t };
}

pub const functions = [_]Function{
    // Randomness and decisions: platform decisions inside determinismo (replayed by tapes,
    // steered by strategies), the OS's randomness outside it.
    .{ .name = "det_random_u64", .params = &.{}, .returns = .u64, .doc = "A random 64-bit value." },
    .{ .name = "det_random_below", .params = &.{p("count", .u64)}, .returns = .u64, .doc = "A uniformly random integer in [0, count); 0 when count is 0." },
    .{ .name = "det_random_float", .params = &.{}, .returns = .f64, .doc = "A float in [0, 1) from 53 random bits." },
    .{ .name = "det_random_bytes", .params = &.{p("target", .buffer)}, .returns = .u64, .doc = "Fills target with random bytes." },
    .{ .name = "det_decide", .params = &.{ p("name", .string), p("options", .string) }, .returns = .u64, .doc = "A named decision among options (one a line): the index chosen. Strategies see the name and the options." },
    .{ .name = "det_random_below_named", .params = &.{ p("name", .string), p("count", .u64) }, .returns = .u64, .doc = "det_random_below, named for strategies (\"retry.jitter_ms\")." },
    .{ .name = "det_random_near", .params = &.{ p("name", .string), p("limit", .u64), p("max", .u64) }, .returns = .u64, .doc = "A value up to max drawn around a limit the workload declares (a batch size, a buffer): half the time uniform, else one of the limit's edges (0, 1, limit - 1, limit, limit + 1, twice it), named decisions (the Zig SDK's random_near)." },
    .{ .name = "det_swarm_index", .params = &.{ p("name", .string), p("count", .u64) }, .returns = .u64, .doc = "An index below count (64 at most) by swarm testing: among the options this timeline keeps for the name, weighted, in runs (the Zig SDK's swarm_index)." },
    .{ .name = "det_buggify", .params = &.{p("name", .string)}, .returns = .bool, .doc = "A buggify point (FoundationDB's BUGGIFY): true, rarely, while the point is active; always false outside determinismo. Up to 64 points." },
    .{ .name = "det_crash_point", .params = &.{p("name", .string)}, .returns = null, .doc = "A moment worth a crash (the Zig SDK's crash_point): inside determinismo and in a node, armed one two-second stretch in eight, its first evaluation then asks the fault injector to crash this node now and waits for it, up to half a second; refused at once where the injector would refuse." },
    .{ .name = "det_buggify_pause", .params = &.{p("name", .string)}, .returns = null, .doc = "At a buggify point, a pause of up to 9 ms, rarely." },
    // Properties.
    .{ .name = "det_assert", .params = &.{ p("kind", .string), p("condition", .bool), p("message", .string), p("details", .json) }, .returns = .i32, .doc = "An assertion: kind is always, always_or_unreachable, sometimes, reachable or unreachable; the message is the property's identity." },
    .{ .name = "det_declare", .params = &.{ p("kind", .string), p("message", .string) }, .returns = .i32, .doc = "Declares an assertion before it runs (the program's catalog): one never reached, or never true, in any timeline fails too." },
    .{ .name = "det_optimize", .params = &.{ p("message", .string), p("bucket", .json), p("value", .f64), p("goal", .string) }, .returns = .i32, .doc = "An objective for exploration: bucket's strings and booleans split states, each keeping the one that scored best on value (goal maximize or minimize)." },
    .{ .name = "det_event", .params = &.{ p("name", .string), p("details", .json) }, .returns = .i32, .doc = "A structured event." },
    .{ .name = "det_setup_complete", .params = &.{p("details", .json)}, .returns = null, .doc = "The system is ready: the platform snapshots here and starts exploring." },
    .{ .name = "det_record", .params = &.{ p("check", .string), p("value", .json) }, .returns = .i32, .doc = "A record for the program's host check named check: one JSON line, which the host check gets with the others once the timeline ends." },
    // Time and faults.
    .{ .name = "det_sleep_ms", .params = &.{p("duration_ms", .u64)}, .returns = null, .doc = "Sleeps for duration_ms of virtual time." },
    .{ .name = "det_stop_faults", .params = &.{p("duration_ns", .u64)}, .returns = null, .doc = "A quiet period: faults stop (the one under way is undone) for duration_ns, except clock skips; 0 ends it." },
    .{ .name = "det_fault", .params = &.{p("request", .json)}, .returns = .i32, .doc = "A fault now, from the scenario: {\"kind\":\"pause\",\"node\":\"db\",\"duration_ms\":2000}, kill, crash, partitions, degraded links (guest/runtime/faults.zig lists them). Only while the fault injector runs." },
    .{ .name = "det_fork", .params = &.{p("count", .u64)}, .returns = .u64, .doc = "Clones this machine where it stands, as Unix's fork: count futures from this moment, each its own randomness, on other cores, while this one goes on. Returns 0 here and k (1 to count) in future k. In a session (serve's: a REPL inside the guest) the platform clones the machine; elsewhere nothing is cloned and it returns 0." },
    .{ .name = "det_runner", .params = &.{p("request", .json)}, .returns = .i32, .doc = "A command run by the guest's runner, which sees every node (det-nodes start, stop, kill, crash, pause, exec; the network, the disks), from a program in any node: request {\"argv\":[...],\"stdin\":\"...\"}. Its reply ({\"status\",\"stdout\",\"stderr\",\"truncated\"}) is kept for det_runner_reply until the next request. What a platform mechanic in another language is built from: its choices from det_decide, its effects these commands, each a runner_request event. Unavailable outside a guest." },
    .{ .name = "det_runner_reply", .params = &.{p("target", .buffer)}, .returns = .u64, .doc = "The last det_runner request's reply, as JSON." },
    .{ .name = "det_serve", .params = &.{ p("method", .string), p("path", .string), p("body", .json) }, .returns = .i32, .doc = "serve's API from inside a session's machine (a REPL in the guest): POST /runs starts a run, GET /runs/<id> follows it, any route but /sessions. Returns the reply's HTTP status; its body is kept for det_serve_reply until the next call. The reply is on the tape: a replay repeats it without serve. Unavailable outside a session." },
    .{ .name = "det_serve_reply", .params = &.{p("target", .buffer)}, .returns = .u64, .doc = "The last det_serve call's reply body (JSON)." },
    .{ .name = "det_fault_aim", .params = &.{p("node", .string)}, .returns = null, .doc = "Aims half the injector's faults at node from now on (\"\" for none)." },
    // The system.
    .{ .name = "det_system", .params = &.{p("target", .buffer)}, .returns = .u64, .doc = "The running system, resolved (schema.System: its profile, nodes with their addresses, scenarios) as JSON; 0 outside determinismo." },
    .{ .name = "det_describe", .params = &.{p("definition", .json)}, .returns = .i32, .doc = "A test program's --describe: the definition ({\"profiles\":[{\"name\",\"nodes\":[{\"name\",\"spec\"}]}],\"scenarios\":[...],\"checks\":[...]}, as Zig's System: each spec a NodeSpec with after as node names) checked and converted as Zig programs' are, printed on standard output." },
    // Elle (Jepsen's checker) on transaction histories.
    .{ .name = "det_elle_process_new", .params = &.{}, .returns = .u64, .doc = "A process id for Elle: a driver takes a new one after an unknown outcome." },
    .{ .name = "det_elle_note", .params = &.{ p("check", .string), p("process", .u64), p("type", .string), p("value", .json) }, .returns = .i32, .doc = "One history line for the check named check (usually elle): type invoke, ok, fail or info; value the transaction's micro-operations ([[\"append\",3,17],[\"r\",4,null]]), at this moment." },
    .{ .name = "det_elle_declare", .params = &.{p("options", .json)}, .returns = .i32, .doc = "Declares an Elle check's properties in the program's catalog, as Zig's sdk.elle.check does as it builds: call it where the check is defined, with det_elle_check's options." },
    .{ .name = "det_elle_check", .params = &.{ p("scenario", .string), p("history", .string), p("options", .json) }, .returns = .i32, .doc = "A host check: Elle on a timeline's history, its verdict asserted (sdk.elle.check). Options as sdk.elle.CheckOptions: model, consistency, by_scenario, allowed, message, realtime_reads, linearizable_keys." },
};

pub fn find(name: []const u8) ?*const Function {
    for (&functions) |*function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

/// libdeterminismo.json.
pub fn write(writer: *std.Io.Writer) !void {
    const Error = struct { code: i32, name: []const u8 };
    var error_list: [errors.len]Error = undefined;
    for (errors, &error_list) |entry, *target| target.* = .{ .code = entry.code, .name = entry.name };
    const Description = struct {
        library: []const u8,
        version: u32,
        types: []const []const u8,
        errors: []const Error,
        functions: []const Function,
    };
    try std.json.Stringify.value(Description{
        .library = "libdeterminismo",
        .version = version,
        .types = std.meta.fieldNames(Type),
        .errors = &error_list,
        .functions = &functions,
    }, .{ .whitespace = .indent_1 }, writer);
    try writer.writeByte('\n');
}

/// libdeterminismo.h: each function's C declaration with its doc, the errors as macros.
pub fn write_header(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\/* SPDX-License-Identifier: MIT */
        \\/* libdeterminismo: determinismo's SDK behind a C ABI (sdk/zig/ffi.zig). Generated from
        \\ * sdk/zig/bindings.zig, as libdeterminismo.json is. A string or JSON is a pointer to UTF-8
        \\ * bytes and their size; a buffer is a pointer to bytes the function writes and their
        \\ * capacity, the function returning the size it has (written when it fits). An int32_t
        \\ * result below 0 is an error. */
        \\#ifndef LIBDETERMINISMO_H
        \\#define LIBDETERMINISMO_H
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\
    );
    try writer.print("#define DET_INTERFACE_VERSION {d}\n", .{version});
    for (errors) |entry| {
        var name_buffer: [32]u8 = undefined;
        const name = std.ascii.upperString(&name_buffer, entry.name);
        try writer.print("#define DET_ERROR_{s} ({d})\n", .{ name, entry.code });
    }
    for (functions) |function| {
        try writer.print("\n/* {s} */\n{s} {s}(", .{ function.doc, c_result(function.returns), function.name });
        if (function.params.len == 0) try writer.writeAll("void");
        for (function.params, 0..) |param, index| {
            if (index > 0) try writer.writeAll(", ");
            switch (param.type) {
                .string, .json => try writer.print("const char *{s}, size_t {s}_size", .{ param.name, param.name }),
                .buffer => try writer.print("uint8_t *{s}, size_t {s}_capacity", .{ param.name, param.name }),
                .u64 => try writer.print("uint64_t {s}", .{param.name}),
                .i32 => try writer.print("int32_t {s}", .{param.name}),
                .f64 => try writer.print("double {s}", .{param.name}),
                .bool => try writer.print("bool {s}", .{param.name}),
            }
        }
        try writer.writeAll(");\n");
    }
    try writer.writeAll(
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
        \\
    );
}

fn c_result(returns: ?Type) []const u8 {
    const t = returns orelse return "void";
    return switch (t) {
        .u64, .buffer => "uint64_t",
        .i32 => "int32_t",
        .f64 => "double",
        .bool => "bool",
        .string, .json => unreachable, // No function returns text: it writes a buffer.
    };
}

/// det-bindings <out.json | out.h>: the interface as JSON, or as a C header.
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return error.Usage;
    var file = try std.Io.Dir.cwd().createFile(init.io, arguments[1], .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(init.io, &buffer);
    if (std.mem.endsWith(u8, arguments[1], ".h")) try write_header(&writer.interface) else try write(&writer.interface);
    try writer.interface.flush();
}

test write_header {
    var buffer: [64 << 10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_header(&writer);
    const header = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, header, "uint64_t det_random_below(uint64_t count);") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "int32_t det_event(const char *name, size_t name_size, const char *details, size_t details_size);") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define DET_ERROR_UNAVAILABLE (-2)") != null);
}

test "every function has a unique name and a doc" {
    for (functions, 0..) |function, index| {
        try std.testing.expect(std.mem.startsWith(u8, function.name, "det_"));
        try std.testing.expect(function.doc.len > 0);
        for (functions[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, function.name, other.name));
    }
}
