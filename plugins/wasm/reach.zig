// SPDX-License-Identifier: MIT
//! A WebAssembly plugin that reaches outside its messages (docs/PLUGINS.md: WASI and `http`):
//! at its hello it reads its arguments and the wall clock (WASI), fetches the URL its first
//! argument names (the `http` host function), and writes what it found to /state/reached.txt
//! (kept across runs). The e2e `wasm-reach` check's plugin; built for wasm32-wasi.
const std = @import("std");
const wasi = std.os.wasi;

extern "determinismo_1" fn request_read(buffer: [*]u8, length: usize) i32;
extern "determinismo_1" fn reply_write(bytes: [*]const u8, length: usize) i32;
extern "determinismo_1" fn http(request: [*]const u8, length: usize) i32;
extern "determinismo_1" fn response_read(buffer: [*]u8, length: usize) i32;

var request: [1 << 20]u8 = undefined;
var response: [1 << 20]u8 = undefined;
var scratch: [8 << 10]u8 = undefined;
var line: [8 << 10]u8 = undefined;

export fn det_call(size: u32) i32 {
    if (size > request.len) return 1;
    var read: usize = 0;
    while (read < size) {
        const count = request_read(request[read..].ptr, size - read);
        if (count <= 0) return 1;
        read += @intCast(count);
    }
    if (std.mem.indexOf(u8, request[0..size], "\"method\":\"hello\"") != null) {
        reach() catch |err| {
            const failed = std.fmt.bufPrint(&line, "error={s}\n", .{@errorName(err)}) catch return 1;
            state_write(failed) catch {};
        };
        const hello = "{\"name\":\"wasm/reach\",\"wants\":[]}";
        return reply_write(hello, hello.len);
    }
    return reply_write("{}", 2);
}

fn reach() !void {
    // Its arguments, from WASI: its name, then the ones after its path.
    var argc: usize = 0;
    var argv_size: usize = 0;
    if (wasi.args_sizes_get(&argc, &argv_size) != .SUCCESS) return error.Arguments;
    var argv_buffer: [4096]u8 = undefined;
    var argv: [16][*:0]u8 = undefined;
    if (argc > argv.len or argv_size > argv_buffer.len) return error.Arguments;
    if (wasi.args_get(&argv, &argv_buffer) != .SUCCESS) return error.Arguments;
    if (argc < 2) return error.NoUrl;
    const url = std.mem.span(argv[1]);
    var now: wasi.timestamp_t = 0;
    if (wasi.clock_time_get(.REALTIME, 1, &now) != .SUCCESS) return error.Clock;

    const asked = try std.fmt.bufPrint(&scratch, "{{\"method\":\"GET\",\"url\":\"{s}\"}}", .{url});
    const size = http(asked.ptr, asked.len);
    if (size < 0) return error.Http;
    var read: usize = 0;
    while (read < @as(usize, @intCast(size))) {
        const count = response_read(response[read..].ptr, response.len - read);
        if (count <= 0) break;
        read += @intCast(count);
    }
    const found = try std.fmt.bufPrint(&line, "name={s} argument={s} clock_ns={d} response={s}\n", .{
        std.mem.span(argv[0]), url, now, response[0..@min(read, 200)],
    });
    try state_write(found);
}

/// Into /state/reached.txt: the directory the explorer preopened under that name.
fn state_write(bytes: []const u8) !void {
    const directory = try preopened("/state");
    var fd: wasi.fd_t = undefined;
    const name = "reached.txt";
    if (wasi.path_open(directory, .{}, name, name.len, .{ .CREAT = true, .TRUNC = true }, .{ .FD_WRITE = true }, .{}, .{}, &fd) != .SUCCESS) return error.Open;
    defer _ = wasi.fd_close(fd);
    const parts = [_]wasi.ciovec_t{.{ .base = bytes.ptr, .len = bytes.len }};
    var written: usize = 0;
    if (wasi.fd_write(fd, &parts, parts.len, &written) != .SUCCESS or written != bytes.len) return error.Write;
}

fn preopened(wanted: []const u8) !wasi.fd_t {
    var fd: wasi.fd_t = 3;
    while (fd < 32) : (fd += 1) {
        var prestat: wasi.prestat_t = undefined;
        if (wasi.fd_prestat_get(fd, &prestat) != .SUCCESS) continue;
        var path: [256]u8 = undefined;
        const length = prestat.u.dir.pr_name_len;
        if (length > path.len) continue;
        if (wasi.fd_prestat_dir_name(fd, &path, length) != .SUCCESS) continue;
        if (std.mem.eql(u8, path[0..length], wanted)) return fd;
    }
    return error.NoPreopen;
}
