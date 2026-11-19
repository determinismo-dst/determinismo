// SPDX-License-Identifier: MIT
//! A WebAssembly plugin that fails on purpose when asked for a decision: it traps (`trap`) or
//! loops past its call's deadline once (`loop`), its argument in the hello. The explorer answers
//! those calls with the defaults and goes on: a module's failure is its answer's, never the
//! exploration's. The e2e `wasm-misbehaving` check's plugin (src/wasm_plugin.zig).
const std = @import("std");

extern "determinismo_1" fn request_read(buffer: [*]u8, length: usize) i32;
extern "determinismo_1" fn reply_write(bytes: [*]const u8, length: usize) i32;

var request: [1 << 20]u8 = undefined;
var looping = false;
/// Looped already: once is the test (each loop takes the call's deadline, 2 s).
var looped = false;

export fn det_call(size: u32) i32 {
    if (size > request.len) return 1;
    var read: usize = 0;
    while (read < size) {
        const count = request_read(request[read..].ptr, size - read);
        if (count <= 0) return 1;
        read += @intCast(count);
    }
    const message = request[0..size];
    if (std.mem.indexOf(u8, message, "\"method\":\"hello\"") != null) {
        looping = std.mem.indexOf(u8, message, "\"arguments\":[\"loop\"]") != null;
        const hello = "{\"name\":\"wasm/misbehave\",\"wants\":[\"labeled\"]}";
        return reply_write(hello, hello.len);
    }
    if (std.mem.indexOf(u8, message, "\"method\":\"random\"") != null) {
        if (!looping) @trap();
        // Volatile, both ways: its only write is on a path that never returns, so a plain
        // read may be folded to false and a plain store sunk past the loop, never made. The
        // module's memory outlives the call its deadline ended: the flag is kept.
        const flag: *volatile bool = &looped;
        if (!flag.*) {
            flag.* = true;
            var spins: u64 = 0;
            while (@as(*volatile u64, &spins).* != std.math.maxInt(u64)) spins += 1;
        }
    }
    return reply_write("{}", 2);
}
