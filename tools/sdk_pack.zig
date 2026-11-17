// SPDX-License-Identifier: MIT
//! sdk_pack <out.tar> <sdk directory> [<path in tar>=<file>]...: the SDK as a tar the explorer
//! carries (src/prepare.zig's sdk_context): node images built from a Dockerfile take it as the
//! build context `determinismo-sdk` (`COPY --from=determinismo-sdk go /sdk`), so an image gets the
//! SDK of the platform that builds it, wherever its Dockerfile lives. Each `<path>=<file>` adds a
//! file built beside the SDK's sources (build.zig's libvoidstar object, `lib/libvoidstar.o`).
//! Reproducible: paths sorted, mtime 0, the executable bit kept.
const std = @import("std");

const Entry = struct {
    /// Its path in the tar.
    path: []const u8,
    /// Where its content is: under the SDK directory (`path` again), or a file given.
    file: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 3) return error.Usage;
    var root = try std.Io.Dir.cwd().openDir(io, argv[2], .{ .iterate = true });
    defer root.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try entries.append(arena, .{ .path = try arena.dupe(u8, entry.path), .file = null });
    }
    for (argv[3..]) |argument| {
        const equals = std.mem.indexOfScalar(u8, argument, '=') orelse return error.Usage;
        if (equals == 0 or equals + 1 == argument.len) return error.Usage;
        try entries.append(arena, .{ .path = argument[0..equals], .file = argument[equals + 1 ..] });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    // A file given over one of the directory's: one of them would be lost.
    for (entries.items[0 .. entries.items.len -| 1], entries.items[1..]) |a, b| {
        if (std.mem.eql(u8, a.path, b.path)) return error.DuplicatePath;
    }
    var out = try std.Io.Dir.cwd().createFile(io, argv[1], .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    var tar: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
    for (entries.items) |entry| {
        const dir = if (entry.file == null) root else std.Io.Dir.cwd();
        const source = entry.file orelse entry.path;
        const content = try dir.readFileAlloc(io, source, arena, .limited(16 << 20));
        const stat = try dir.statFile(io, source, .{});
        const executable = stat.permissions.toMode() & 0o111 != 0;
        try tar.writeFileBytes(entry.path, content, .{ .mode = if (executable) 0o755 else 0o644, .mtime = 0 });
    }
    try tar.finishPedantically();
    try file_writer.interface.flush();
}
