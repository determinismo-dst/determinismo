// SPDX-License-Identifier: MIT
//! sdk_pack <out.tar> <sdk directory>: the SDK as a tar the explorer carries (src/prepare.zig's
//! sdk_context): node images built from a Dockerfile take it as the build context
//! `determinismo-sdk` (`COPY --from=determinismo-sdk go /sdk`), so an image gets the SDK of the
//! platform that builds it, wherever its Dockerfile lives. Reproducible: paths sorted, mtime 0,
//! the executable bit kept.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3) return error.Usage;
    var root = try std.Io.Dir.cwd().openDir(io, argv[2], .{ .iterate = true });
    defer root.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out = try std.Io.Dir.cwd().createFile(io, argv[1], .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    var tar: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
    for (paths.items) |path| {
        const content = try root.readFileAlloc(io, path, arena, .limited(16 << 20));
        const stat = try root.statFile(io, path, .{});
        const executable = stat.permissions.toMode() & 0o111 != 0;
        try tar.writeFileBytes(path, content, .{ .mode = if (executable) 0o755 else 0o644, .mtime = 0 });
    }
    try tar.finishPedantically();
    try file_writer.interface.flush();
}
