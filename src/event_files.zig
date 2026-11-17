//! A timeline's events on disk: `branch-<n>.jsonl` while it runs (appended as they come), then
//! `branch-<n>.jsonl.zst` once it ended, compressed by its own process before the explorer hears
//! of its end (main.zig). zstd's level 3 keeps a TiDB timeline's 28 MB in 2.1 MB, 13.7 times
//! smaller: srv4 kept 1.7 TB of them in plain JSON (2026-11-14, 407,016 files), its disk past
//! the reserve below which no holder goes to disk (holders.disk_room), and a TiDB pass's
//! judgment made all six of its nodes by replays (run 1994, judged in 1451 s of 30 minutes).
//!
//! Which one a reader opens is the timeline's state, not a fallback: an ended timeline has its
//! `.zst` alone (written beside under a temporary name, renamed, the plain one removed after),
//! a running one its plain file alone. Neither: the timeline wrote no events (or never ran).
//! Compression is zstd's C library (build.zig's zstd_link, determinismo alone: the writer);
//! reading back is Zig's own (std.compress.zstd), for any reader.

const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;

pub const running_suffix = ".jsonl";
pub const ended_suffix = ".jsonl.zst";
const temporary_suffix = ".jsonl.zst.writing";

/// zstd's level: 3, its default, at about 0.1 s of CPU for a 28 MB timeline (srv4).
const level = 3;
const chunk_size = 1 << 20;

/// The path of a timeline's events, as `state` names them.
pub fn path(
    buffer: []u8,
    directory: []const u8,
    index: u32,
    state: enum { running, ended },
) ![:0]const u8 {
    const suffix = if (state == .running) running_suffix else ended_suffix;
    return std.fmt.bufPrintSentinel(buffer, "{s}/branch-{d}{s}", .{ directory, index, suffix }, 0);
}

/// The timeline index a directory entry names (`branch-<n>.jsonl` or `.jsonl.zst`), or null.
pub fn index_of(name: []const u8) ?u32 {
    const prefix = "branch-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const suffix = if (std.mem.endsWith(u8, name, ended_suffix))
        ended_suffix
    else if (std.mem.endsWith(u8, name, running_suffix)) running_suffix else return null;
    return std.fmt.parseInt(u32, name[prefix.len .. name.len - suffix.len], 10) catch null;
}

test index_of {
    try std.testing.expectEqual(@as(?u32, 12), index_of("branch-12.jsonl"));
    try std.testing.expectEqual(@as(?u32, 12), index_of("branch-12.jsonl.zst"));
    try std.testing.expectEqual(@as(?u32, null), index_of("branch-12.jsonl.zst.writing"));
    try std.testing.expectEqual(@as(?u32, null), index_of("setup.jsonl"));
    try std.testing.expectEqual(@as(?u32, null), index_of("branch-x.jsonl"));
}

const CCtx = opaque {};
const InBuffer = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const OutBuffer = extern struct { dst: ?*anyopaque, size: usize, pos: usize };
const c_compression_level = 100; // ZSTD_c_compressionLevel
const c_checksum_flag = 201; // ZSTD_c_checksumFlag
const e_continue = 0; // ZSTD_e_continue
const e_end = 2; // ZSTD_e_end
extern fn ZSTD_createCCtx() ?*CCtx;
extern fn ZSTD_freeCCtx(context: *CCtx) usize;
extern fn ZSTD_CCtx_setParameter(context: *CCtx, parameter: c_int, value: c_int) usize;
extern fn ZSTD_compressStream2(context: *CCtx, output: *OutBuffer, input: *InBuffer, end: c_int) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_CStreamOutSize() usize;

/// An ended timeline's events compressed: `branch-<n>.jsonl` into `branch-<n>.jsonl.zst`, the
/// plain one removed. Nothing to compress (it wrote no events): nothing done.
pub fn compress(directory: []const u8, index: u32) !void {
    var plain_buffer: [4096]u8 = undefined;
    const plain = try path(&plain_buffer, directory, index, .running);
    var ended_buffer: [4096]u8 = undefined;
    const ended_path = try path(&ended_buffer, directory, index, .ended);
    var temporary_buffer: [4096]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&temporary_buffer, "{s}/branch-{d}{s}", .{
        directory, index, temporary_suffix,
    }, 0);
    const input = linux.open(plain, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(input) == .NOENT) return;
    if (linux.errno(input) != .SUCCESS) return error.EventsUnreadable;
    defer _ = linux.close(@intCast(input));
    const output = linux.open(temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(output) != .SUCCESS) return error.EventsUnwritable;
    errdefer _ = linux.unlink(temporary);
    {
        defer _ = linux.close(@intCast(output));
        try compress_fd(@intCast(input), @intCast(output));
    }
    if (linux.errno(linux.rename(temporary, ended_path)) != .SUCCESS) return error.EventsUnwritable;
    _ = linux.unlink(plain);
}

fn compress_fd(input: linux.fd_t, output: linux.fd_t) !void {
    const context = ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeCCtx(context);
    if (ZSTD_isError(ZSTD_CCtx_setParameter(context, c_compression_level, level)) != 0) return error.Compression;
    // A checksum in each frame, for `zstd -t` (Zig's reader leaves it unverified: decompress).
    if (ZSTD_isError(ZSTD_CCtx_setParameter(context, c_checksum_flag, 1)) != 0) return error.Compression;
    const in_bytes = try std.heap.page_allocator.alloc(u8, chunk_size);
    defer std.heap.page_allocator.free(in_bytes);
    const out_bytes = try std.heap.page_allocator.alloc(u8, @max(ZSTD_CStreamOutSize(), chunk_size));
    defer std.heap.page_allocator.free(out_bytes);
    while (true) {
        const count = linux.read(input, in_bytes.ptr, in_bytes.len);
        if (linux.errno(count) != .SUCCESS) return error.EventsUnreadable;
        const last = count == 0;
        var in: InBuffer = .{ .src = in_bytes.ptr, .size = count, .pos = 0 };
        while (true) {
            var out: OutBuffer = .{ .dst = out_bytes.ptr, .size = out_bytes.len, .pos = 0 };
            const left = ZSTD_compressStream2(context, &out, &in, if (last) e_end else e_continue);
            if (ZSTD_isError(left) != 0) return error.Compression;
            try write_all(output, out_bytes[0..out.pos]);
            const done = if (last) left == 0 else in.pos == in.size;
            if (done) break;
        }
        if (last) return;
    }
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) == .NOSPC) return error.NoSpaceLeft;
        if (linux.errno(result) != .SUCCESS) return error.EventsUnwritable;
        written += result;
    }
}

/// Whether the timeline's events are in their ended form.
pub fn ended(io: std.Io, directory: []const u8, index: u32) bool {
    var buffer: [4096]u8 = undefined;
    const ended_path = path(&buffer, directory, index, .ended) catch return false;
    std.Io.Dir.cwd().access(io, ended_path, .{}) catch return false;
    return true;
}

/// A timeline's events whole: an ended one's decompressed, a running one's as written so far.
/// error.FileNotFound: neither (no events).
pub fn read(arena: std.mem.Allocator, io: std.Io, directory: []const u8, index: u32, limit: std.Io.Limit) ![]u8 {
    var buffer: [4096]u8 = undefined;
    if (!ended(io, directory, index)) {
        const running = try path(&buffer, directory, index, .running);
        return std.Io.Dir.cwd().readFileAlloc(io, running, arena, limit);
    }
    const ended_path = try path(&buffer, directory, index, .ended);
    const file = try std.Io.Dir.cwd().openFile(io, ended_path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var out: std.Io.Writer.Allocating = .init(arena);
    try decompress(&reader.interface, &out.writer, limit);
    return out.written();
}

/// An ended timeline's events into a plain file at `to` (DuckDB's read_json reads no zstd without
/// its parquet extension, which determinismo does not link): ingest's copy, removed after.
pub fn decompress_to(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, from, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const out_file = try cwd.createFile(io, to, .{ .truncate = true });
    defer out_file.close(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = out_file.writer(io, &out_buffer);
    try decompress(&reader.interface, &writer.interface, .unlimited);
    try writer.interface.flush();
}

fn decompress(input: *std.Io.Reader, output: *std.Io.Writer, limit: std.Io.Limit) !void {
    // Its own window: without one it writes into `output`'s buffer, which must then hold a
    // window whole (8 MiB and a block), and a file's writer does not.
    const zstd = std.compress.zstd;
    const window = try std.heap.page_allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
    defer std.heap.page_allocator.free(window);
    // Its checksum unverified: Zig 0.17's zstd does not verify with a window of its own (a TODO
    // panic). A torn file still fails, its last frame cut short.
    var stream: zstd.Decompress = .init(input, window, .{});
    const most = limit.toInt();
    var total: usize = 0;
    while (true) {
        // One byte past the limit asked for: a file larger than it says so.
        const asked: std.Io.Limit = if (most) |bytes| .limited(bytes + 1 - total) else .unlimited;
        total += stream.reader.stream(output, asked) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return stream.err orelse error.ReadFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        if (most) |bytes| if (total > bytes) return error.StreamTooLong;
    }
}

test "an ended timeline's events read back as written, and its plain file is gone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_buffer: [4096]u8 = undefined;
    const directory = directory_buffer[0..try tmp.dir.realPathFile(io, ".", &directory_buffer)];
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Several of zstd's blocks and of compress's chunks: lines like the guest's, each different.
    var written: std.Io.Writer.Allocating = .init(arena);
    for (0..60_000) |line| try written.writer.print(
        "{{\"seq\":{d},\"vtime_ns\":{d},\"event\":{{\"name\":\"node_start\",\"node\":\"n{d}\"}}}}\n",
        .{ line, line * 7_919, line % 5 },
    );
    var plain_buffer: [4096]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try path(&plain_buffer, directory, 3, .running), .data = written.written() });
    // Running: the plain file.
    try std.testing.expect(!ended(io, directory, 3));
    try std.testing.expectEqualSlices(u8, written.written(), try read(arena, io, directory, 3, .unlimited));
    try compress(directory, 3);
    try std.testing.expect(ended(io, directory, 3));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try path(&plain_buffer, directory, 3, .running), .{}));
    try std.testing.expectEqualSlices(u8, written.written(), try read(arena, io, directory, 3, .unlimited));
    try std.testing.expectError(error.StreamTooLong, read(arena, io, directory, 3, .limited(1000)));
    var ended_buffer: [4096]u8 = undefined;
    const ended_size = (try std.Io.Dir.cwd().statFile(io, try path(&ended_buffer, directory, 3, .ended), .{})).size;
    try std.testing.expect(ended_size * 5 < written.written().len);
    // Ingest's plain copy.
    var copy_buffer: [4096]u8 = undefined;
    const copy = try std.fmt.bufPrint(&copy_buffer, "{s}/copy.jsonl", .{directory});
    try decompress_to(io, try path(&ended_buffer, directory, 3, .ended), copy);
    try std.testing.expectEqualSlices(u8, written.written(), try std.Io.Dir.cwd().readFileAlloc(io, copy, arena, .unlimited));
    // A timeline with no events: nothing compressed, nothing to read.
    try compress(directory, 4);
    try std.testing.expectError(error.FileNotFound, read(arena, io, directory, 4, .unlimited));
}

test "a torn ended file is named as such, never read as fewer events" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_buffer: [4096]u8 = undefined;
    const directory = directory_buffer[0..try tmp.dir.realPathFile(io, ".", &directory_buffer)];
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var written: std.Io.Writer.Allocating = .init(arena);
    for (0..20_000) |line| try written.writer.print("{{\"seq\":{d}}}\n", .{line});
    var plain_buffer: [4096]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try path(&plain_buffer, directory, 0, .running), .data = written.written() });
    try compress(directory, 0);
    var ended_buffer: [4096]u8 = undefined;
    const ended_path = try path(&ended_buffer, directory, 0, .ended);
    const whole = try std.Io.Dir.cwd().readFileAlloc(io, ended_path, arena, .unlimited);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ended_path, .data = whole[0 .. whole.len - 7] });
    if (read(arena, io, directory, 0, .unlimited)) |_| return error.TestUnexpectedResult else |_| {}
}
