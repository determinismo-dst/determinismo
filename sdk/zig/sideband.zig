// SPDX-License-Identifier: MIT
//! A side channel between drivers, outside the system under test (FoundationDB's Sideband): a
//! writer posts what the system acknowledged, a checker takes it and must then read it through
//! the system. Causality a client can see without a history checker: for systems claiming
//! read-your-writes across clients (a QUORUM write then a QUORUM read, a linearizable store's
//! reads, a session's causal guarantees).
//!
//! A file in the runner (drivers are processes of their own, started again and again): posts are
//! appended lines, takes advance an offset kept beside it, both under a lock. A line taken whose
//! read the faults kept from answering is posted again, to be read later.
//!
//!   const channel: sdk.sideband.Channel = .{ .path = "/tmp/scylla-sideband" };
//!   try channel.post(line);                       // once the write is acknowledged
//!   if (try channel.take(&buffer)) |line| { ... } // read it: the system must have it
const std = @import("std");
const linux = std.os.linux;

pub const line_size_max = 512;

pub const Channel = struct {
    /// The posts' file; its taken offset is `<path>.taken`, its lock `<path>.lock`.
    path: []const u8,

    /// Appends one line (no newline in it).
    pub fn post(channel: Channel, line: []const u8) !void {
        if (line.len == 0 or line.len >= line_size_max) return error.LineSize;
        if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.LineHasNewline;
        const lock = try channel.locked();
        defer unlock(lock);
        var path_buffer: [256]u8 = undefined;
        const fd = try open_z(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{channel.path}, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true });
        defer _ = linux.close(fd);
        var record: [line_size_max + 1]u8 = undefined;
        @memcpy(record[0..line.len], line);
        record[line.len] = '\n';
        try write_all(fd, record[0 .. line.len + 1]);
    }

    /// The next line no one took yet, copied into `buffer`; null when every post was taken.
    pub fn take(channel: Channel, buffer: *[line_size_max]u8) !?[]const u8 {
        const lock = try channel.locked();
        defer unlock(lock);
        var path_buffer: [256]u8 = undefined;
        const taken_path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}.taken", .{channel.path}, 0);
        var offset_text: [24]u8 = undefined;
        const offset: u64 = if (read_small(taken_path, &offset_text)) |text|
            std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0
        else
            0;
        var posts_path_buffer: [256]u8 = undefined;
        const posts_path = try std.fmt.bufPrintSentinel(&posts_path_buffer, "{s}", .{channel.path}, 0);
        const fd = open_z(posts_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return null;
        defer _ = linux.close(fd);
        var chunk: [line_size_max + 1]u8 = undefined;
        const size = linux.pread(fd, &chunk, chunk.len, @intCast(offset));
        if (linux.errno(size) != .SUCCESS) return error.ReadFailed;
        const end = std.mem.indexOfScalar(u8, chunk[0..size], '\n') orelse return null;
        @memcpy(buffer[0..end], chunk[0..end]);
        var next_text: [24]u8 = undefined;
        const next = try std.fmt.bufPrint(&next_text, "{d}", .{offset + end + 1});
        const out = try open_z(taken_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
        defer _ = linux.close(out);
        try write_all(out, next);
        return buffer[0..end];
    }

    fn locked(channel: Channel) !linux.fd_t {
        var path_buffer: [256]u8 = undefined;
        const fd = try open_z(try std.fmt.bufPrintSentinel(&path_buffer, "{s}.lock", .{channel.path}, 0), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true });
        const lock_exclusive = 2; // LOCK_EX
        if (linux.errno(linux.flock(fd, lock_exclusive)) != .SUCCESS) {
            _ = linux.close(fd);
            return error.LockFailed;
        }
        return fd;
    }
};

fn unlock(fd: linux.fd_t) void {
    _ = linux.close(fd); // Closing releases the flock.
}

fn open_z(path: [:0]const u8, flags: linux.O) !linux.fd_t {
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    return @intCast(fd);
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS or result == 0) return error.WriteFailed;
        written += result;
    }
}

fn read_small(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = open_z(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return null;
    defer _ = linux.close(fd);
    const size = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

test "posted lines are taken once, in order, across channels on one file" {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".det-sideband-test-{d}", .{linux.getpid()});
    const writer: Channel = .{ .path = path };
    const reader: Channel = .{ .path = path };
    defer for ([_][]const u8{ "", ".taken", ".lock" }) |suffix| {
        var buffer: [128]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&buffer, "{s}{s}", .{ path, suffix }, 0) catch continue;
        _ = linux.unlink(file);
    };
    var line: [line_size_max]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try reader.take(&line));
    try writer.post("k1 7");
    try writer.post("k2 9");
    try std.testing.expectEqualStrings("k1 7", (try reader.take(&line)).?);
    try writer.post("k3 1");
    try std.testing.expectEqualStrings("k2 9", (try reader.take(&line)).?);
    try std.testing.expectEqualStrings("k3 1", (try reader.take(&line)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try reader.take(&line));
    try std.testing.expectError(error.LineHasNewline, writer.post("a\nb"));
}
