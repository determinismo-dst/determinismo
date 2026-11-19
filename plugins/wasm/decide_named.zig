// SPDX-License-Identifier: MIT
//! decide_named.py as a WebAssembly module, run inside the explorer: answers one named
//! decision with a fixed value wherever it is drawn, the setup's included. Its arguments come
//! with the hello (a module has no argv). An example of the ABI `determinismo_1`
//! (src/wasm_plugin.zig), and the e2e `wasm-plugin` check's plugin.
//!
//!     determinismo explore ... --strategy "wasm:zig-out/bin/decide_named.wasm node.start_draw 7"
const std = @import("std");

extern "determinismo_1" fn request_read(buffer: [*]u8, length: usize) i32;
extern "determinismo_1" fn reply_write(bytes: [*]const u8, length: usize) i32;
extern "determinismo_1" fn log(level: i32, bytes: [*]const u8, length: usize) void;

const request_size_max = 1 << 20;
var request: [request_size_max]u8 = undefined;
var parse_memory: [4 << 20]u8 = undefined;
var reply: [16 << 10]u8 = undefined;
/// The decision's name and the value it gets, from the hello's arguments.
var name_buffer: [128]u8 = undefined;
var name: []const u8 = "";
var value: u64 = 0;

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
    if (std.mem.eql(u8, method, "hello")) {
        const arguments = message.get("arguments") orelse return error.NoArguments;
        if (arguments != .array or arguments.array.items.len != 2) return error.NoArguments;
        const given_name = arguments.array.items[0];
        const given_value = arguments.array.items[1];
        if (given_name != .string or given_value != .string) return error.NoArguments;
        if (given_name.string.len > name_buffer.len) return error.NoArguments;
        @memcpy(name_buffer[0..given_name.string.len], given_name.string);
        name = name_buffer[0..given_name.string.len];
        value = try std.fmt.parseInt(u64, given_value.string, 10);
        const said = "decide_named.wasm: answering one named decision";
        log(2, said.ptr, said.len);
        return writer.writeAll("{\"name\":\"wasm/decide-named\",\"wants\":[\"labeled\",\"setup\"]}");
    }
    if (std.mem.eql(u8, method, "random")) {
        const decision = message.get("decision") orelse return writer.writeAll("{}");
        if (decision != .object) return writer.writeAll("{}");
        const decision_name = decision.object.get("name") orelse return writer.writeAll("{}");
        if (decision_name != .string or !std.mem.eql(u8, decision_name.string, name)) return writer.writeAll("{}");
        const default = message.get("default") orelse return error.NoDefault;
        if (default != .string or default.string.len % 2 != 0 or default.string.len > 16) return error.NoDefault;
        // The value's bytes, little endian, as many as the default's.
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        const size = default.string.len / 2;
        try writer.writeAll("{\"hex\":\"");
        for (bytes[0..size]) |byte| try writer.print("{x:0>2}", .{byte});
        return writer.print("\",\"reason\":\"{s} fixed at {d}\"}}", .{ name, value });
    }
    return writer.writeAll("{}");
}
