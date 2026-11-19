// SPDX-License-Identifier: MIT
//! One WebAssembly plugin at every hook point a strategy has (docs/PLUGINS.md), run inside the
//! explorer (the ABI `determinismo_1`, src/wasm_plugin.zig):
//!
//!   machine   the guest's wall clock at 2000-02-29, and a fault of its own in Redis's node
//!             (`CLIENT PAUSE 200`), drawn by the fault injector among the node's
//!   setup     the setup's `node.start_draw` answered 7 (every timeline starts from it)
//!   device    the network's baseline delay answered (`network.baseline_delay_ns`: 1 ms)
//!   events    the timeline's faults counted as they happen
//!   check     the timeline judged at its end: its own fault ran; at most 3 faults
//!
//!     (def module (d/wasm-build "plugins/wasm/all_hooks.zig"))
//!     (d/upload-strategy! "all-hooks" (:module module))
//!     (d/start-run {... :strategy "@all-hooks"})
const std = @import("std");

extern "determinismo_1" fn request_read(buffer: [*]u8, length: usize) i32;
extern "determinismo_1" fn reply_write(bytes: [*]const u8, length: usize) i32;

var request: [4 << 20]u8 = undefined;
var parse_memory: [16 << 20]u8 = undefined;
var reply: [16 << 10]u8 = undefined;
/// This timeline's (reset at each `branch`).
var faults: u32 = 0;
var own_faults: u32 = 0;

export fn det_call(size: u32) i32 {
    if (size > request.len) return 1;
    var read: usize = 0;
    while (read < size) {
        const count = request_read(request[read..].ptr, size - read);
        if (count <= 0) return 1;
        read += @intCast(count);
    }
    var fba: std.heap.FixedBufferAllocator = .init(&parse_memory);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), request[0..size], .{}) catch return 1;
    if (parsed != .object) return 1;
    const method = parsed.object.get("method") orelse return 1;
    if (method != .string) return 1;
    var writer: std.Io.Writer = .fixed(&reply);
    answer(method.string, parsed.object, &writer) catch return 1;
    return reply_write(writer.buffered().ptr, writer.buffered().len);
}

fn answer(method: []const u8, message: std.json.ObjectMap, writer: *std.Io.Writer) !void {
    const eql = std.mem.eql;
    if (eql(u8, method, "hello")) {
        return writer.writeAll("{\"name\":\"wasm/all-hooks\",\"wants\":[\"labeled\",\"setup\",\"machine\",\"check\",\"batched\"]}");
    }
    if (eql(u8, method, "machine")) {
        return writer.writeAll("{\"epoch_seconds\":951782400,\"custom_faults\":[" ++
            "{\"node\":\"redis\",\"command\":\"/usr/local/bin/redis-cli CLIENT PAUSE 200\"}]}");
    }
    if (eql(u8, method, "branch")) {
        faults = 0;
        own_faults = 0;
        return writer.writeAll("{}");
    }
    if (eql(u8, method, "random")) {
        const decision = message.get("decision") orelse return writer.writeAll("{}");
        if (decision != .object) return writer.writeAll("{}");
        const name = decision.object.get("name") orelse return writer.writeAll("{}");
        if (name != .string) return writer.writeAll("{}");
        const value: u64 = if (eql(u8, name.string, "node.start_draw"))
            7
        else if (eql(u8, name.string, "network.baseline_delay_ns"))
            900_000 // Past the baseline's least, 100 us: 1 ms in all.
        else
            return writer.writeAll("{}");
        return hex_answer(writer, message, value, name.string);
    }
    if (eql(u8, method, "event")) {
        if (message.get("event")) |event| fault_count(event);
        return writer.writeAll("{}");
    }
    if (eql(u8, method, "events")) {
        if (message.get("events")) |events| if (events == .array) for (events.array.items) |item| {
            if (item == .object) if (item.object.get("event")) |event| fault_count(event);
        };
        return writer.writeAll("{}");
    }
    if (eql(u8, method, "check")) {
        return writer.print("{{\"assertions\":[" ++
            "{{\"type\":\"sometimes\",\"message\":\"the plugin's own fault ran in a timeline\",\"condition\":{},\"details\":{{\"runs\":{d}}}}}," ++
            "{{\"type\":\"always\",\"message\":\"at most 3 faults in a timeline\",\"condition\":{},\"details\":{{\"faults\":{d}}}}}]}}", .{
            own_faults > 0, own_faults, faults <= 3, faults,
        });
    }
    return writer.writeAll("{}");
}

/// A guest event: a fault applied (`fault`), and its own when it ran (`fault_custom_done`).
fn fault_count(event: std.json.Value) void {
    if (event != .object) return;
    const name = event.object.get("event") orelse return;
    if (name != .string) return;
    if (std.mem.eql(u8, name.string, "fault")) faults += 1;
    if (std.mem.eql(u8, name.string, "fault_custom_done")) own_faults += 1;
}

/// The answer to a decision: `value` in the default's size, little endian.
fn hex_answer(writer: *std.Io.Writer, message: std.json.ObjectMap, value: u64, name: []const u8) !void {
    const default = message.get("default") orelse return error.NoDefault;
    if (default != .string or default.string.len % 2 != 0 or default.string.len > 16) return error.NoDefault;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.writeAll("{\"hex\":\"");
    for (bytes[0 .. default.string.len / 2]) |byte| try writer.print("{x:0>2}", .{byte});
    return writer.print("\",\"reason\":\"{s} at {d}, the uploaded plugin's\"}}", .{ name, value });
}
