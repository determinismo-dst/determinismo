// SPDX-License-Identifier: MIT
//! A reactive fault plugin: the injector's next fault lands just after an event of a given name.
//! It asks for the injector's waits to be polled (its machine's `fault_poll_ms`), keeps them long
//! (`fault.wait_ns` answered its range's top: the SDK takes a value modulo its range), and once it
//! has been told an event named so,
//! answers the next poll's `fault.now` with 0: the fault comes within a poll of that event.
//! Arguments (with the hello): the event's name and the poll in milliseconds.
//!
//!     determinismo explore ... --strategy "wasm:zig-out/bin/react.wasm network_baseline 10"
const std = @import("std");

extern "determinismo_1" fn request_read(buffer: [*]u8, length: usize) i32;
extern "determinismo_1" fn reply_write(bytes: [*]const u8, length: usize) i32;

var request: [1 << 20]u8 = undefined;
var parse_memory: [1 << 20]u8 = undefined;
var reply: [1024]u8 = undefined;
/// `"event":"<name>"`, as the event's line has it.
var marker_buffer: [160]u8 = undefined;
var marker: []const u8 = "";
var poll_ms: u32 = 10;
/// Told the event since its last fault: the next poll is its moment.
var armed = false;

export fn det_call(size: u32) i32 {
    if (size > request.len) return 1;
    var read: usize = 0;
    while (read < size) {
        const count = request_read(request[read..].ptr, size - read);
        if (count <= 0) return 1;
        read += @intCast(count);
    }
    const message = request[0..size];
    var writer: std.Io.Writer = .fixed(&reply);
    answer(message, &writer) catch return 1;
    return reply_write(writer.buffered().ptr, writer.buffered().len);
}

fn answer(message: []const u8, writer: *std.Io.Writer) !void {
    const has = std.mem.indexOf;
    if (has(u8, message, "\"method\":\"hello\"") != null) return hello(message, writer);
    if (has(u8, message, "\"method\":\"machine\"") != null) {
        return writer.print("{{\"fault_poll_ms\":{d}}}", .{poll_ms});
    }
    if (has(u8, message, "\"method\":\"branch\"") != null) {
        armed = false;
        return writer.writeAll("{}");
    }
    // Events, one or a batch: armed by the first named so.
    if (has(u8, message, "\"method\":\"event") != null) {
        if (marker.len > 0 and has(u8, message, marker) != null) armed = true;
        return writer.writeAll("{}");
    }
    if (has(u8, message, "\"method\":\"random\"") != null) {
        if (has(u8, message, "\"name\":\"fault.now\"") != null) {
            if (!armed) return writer.writeAll("{}");
            armed = false;
            return hex_answer(writer, message, 0, "the event came: now");
        }
        if (has(u8, message, "\"name\":\"fault.wait_ns\"") != null) {
            const range = range_of(message) orelse return writer.writeAll("{}");
            return hex_answer(writer, message, range - 1, "waits long: faults come at events");
        }
    }
    return writer.writeAll("{}");
}

fn hello(message: []const u8, writer: *std.Io.Writer) !void {
    var fba: std.heap.FixedBufferAllocator = .init(&parse_memory);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), message, .{});
    const arguments = parsed.object.get("arguments") orelse return error.NoArguments;
    if (arguments != .array or arguments.array.items.len != 2) return error.NoArguments;
    const name = arguments.array.items[0];
    const poll = arguments.array.items[1];
    if (name != .string or poll != .string) return error.NoArguments;
    marker = try std.fmt.bufPrint(&marker_buffer, "\"event\":\"{s}\"", .{name.string});
    poll_ms = try std.fmt.parseInt(u32, poll.string, 10);
    return writer.writeAll("{\"name\":\"wasm/react\",\"wants\":[\"labeled\",\"machine\",\"batched\"]}");
}

/// The decision's range (its label's `"range":N`), if it has one past 0.
fn range_of(message: []const u8) ?u64 {
    const key = "\"range\":";
    const at = std.mem.indexOf(u8, message, key) orelse return null;
    const rest = message[at + key.len ..];
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    const range = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
    return if (range > 0) range else null;
}

/// `value` in the default's size, little endian.
fn hex_answer(writer: *std.Io.Writer, message: []const u8, value: u64, reason: []const u8) !void {
    const key = "\"default\":\"";
    const at = std.mem.indexOf(u8, message, key) orelse return error.NoDefault;
    const rest = message[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoDefault;
    if (end % 2 != 0 or end > 16) return error.NoDefault;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.writeAll("{\"hex\":\"");
    for (bytes[0 .. end / 2]) |byte| try writer.print("{x:0>2}", .{byte});
    return writer.print("\",\"reason\":\"{s}\"}}", .{reason});
}
