// SPDX-License-Identifier: MIT
//! det-program-pack: a test program in Clojure or jank as one file (zig build's step for each in
//! build.zig's clojure_programs and jank_programs): a shell script that runs itself as a jar,
//! the program's sources and its SDK's (sdk/clojure, sdk/jank) in it. One file, so that what
//! determinismo keeps of a run's program (its artifacts) is the whole program: a replay's
//! --describe and a timeline's checks run it anywhere. libdeterminismo from the platform
//! (DETERMINISMO_LIBRARY on the host, the guest's in a node).
//!
//! Clojure's libraries: the host's (Debian's clojure package, infra/host/provision.sh), or the
//! node image's (/opt/workload/classpath, deps.edn resolved as it was built). jank: the host's
//! (~/opt/jank, infra/host/tools.sh; DETERMINISMO_JANK), libdeterminismo included and linked by
//! its path; in a node the image runs its commands (its /opt/workload/run).
//!
//!   det-program-pack <out> <clojure | jank> <main namespace> <source directory>...
//!
//! Each directory's .clj (.jank) files go in at their paths below it. The jar is stored (no
//! compression) and its entries dated 1980: the same sources, the same file. Java and jank read
//! a jar from its end, so the script before it is no matter (jank takes it by a name in .jar:
//! the script links itself as one).
const std = @import("std");

const clojure_header =
    \\#!/bin/sh
    \\# SPDX-License-Identifier: MIT
    \\# A determinismo test program in Clojure (sdk/clojure's determinismo.workload): this file is
    \\# a shell script and, after it, a jar of its sources (tools/program_pack.zig).
    \\classpath=/usr/share/java/clojure.jar:/usr/share/java/spec.alpha.jar:/usr/share/java/core.specs.alpha.jar
    \\[ -f /opt/workload/classpath ] && classpath=$(cat /opt/workload/classpath)
    \\exec java --enable-native-access=ALL-UNNAMED -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xmx160m \
    \\  -cp "$0:$classpath" clojure.main -m {s} "$@"
    \\
;

const jank_header =
    \\#!/bin/sh
    \\# SPDX-License-Identifier: MIT
    \\# A determinismo test program in jank (sdk/jank's determinismo.workload): this file is a
    \\# shell script and, after it, a jar of its sources (tools/program_pack.zig), which jank
    \\# reads by a name in .jar: the hard link beside it (a symbolic one jank resolves to this
    \\# name). jank from DETERMINISMO_JANK or ~/opt/jank,
    \\# libdeterminismo from DETERMINISMO_LIBRARY (determinismo gives it to the programs it runs).
    \\jank=${{DETERMINISMO_JANK:-$HOME/opt/jank/usr/local/bin/jank}}
    \\self=$(readlink -f "$0")
    \\ln -f "$self" "$self.jar"
    \\# The library's header beside it (<dir>/libdeterminismo.h, or a run's kept explorer's
    \\# <explorer>.libdeterminismo.h), under the name the SDK includes, in a directory of its own.
    \\include="$self.include"
    \\mkdir -p "$include"
    \\ln -sf "${{DETERMINISMO_LIBRARY%.so}}.h" "$include/libdeterminismo.h"
    \\exec "$jank" --module-path "$self.jar" -I "$include" \
    \\  "-l$DETERMINISMO_LIBRARY" run-main {s} -- "$@"
    \\
;

const Entry = struct { name: []const u8, data: []const u8, offset: u32, crc: u32 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 5) {
        std.debug.print("usage: det-program-pack <out> <clojure | jank> <main namespace> <source directory>...\n", .{});
        std.process.exit(2);
    }
    const jank = std.mem.eql(u8, arguments[2], "jank");
    if (!jank and !std.mem.eql(u8, arguments[2], "clojure")) {
        std.debug.print("det-program-pack: {s}: clojure or jank\n", .{arguments[2]});
        std.process.exit(2);
    }
    const extension = if (jank) ".jank" else ".clj";
    var entries: std.ArrayList(Entry) = .empty;
    for (arguments[4..]) |directory_path| {
        var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |item| {
            if (item.kind != .file or !std.mem.endsWith(u8, item.path, extension)) continue;
            const name = try arena.dupe(u8, item.path);
            std.mem.replaceScalar(u8, name, '\\', '/');
            const data = try directory.readFileAlloc(io, item.path, arena, .limited(16 << 20));
            try entries.append(arena, .{ .name = name, .data = data, .offset = 0, .crc = std.hash.Crc32.hash(data) });
        }
    }
    // The same order on every machine.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    if (jank) try writer.print(jank_header, .{arguments[3]}) else try writer.print(clojure_header, .{arguments[3]});
    const zip_start = out.written().len;
    for (entries.items) |*entry| {
        entry.offset = @intCast(out.written().len - zip_start);
        try local_header(writer, entry.*);
        try writer.writeAll(entry.data);
    }
    const directory_start = out.written().len - zip_start;
    for (entries.items) |entry| try central_header(writer, entry);
    const directory_size = out.written().len - zip_start - directory_start;
    // The end of central directory record.
    try writer.writeInt(u32, 0x06054b50, .little);
    try writer.writeInt(u16, 0, .little); // This disk.
    try writer.writeInt(u16, 0, .little); // The directory's disk.
    try writer.writeInt(u16, @intCast(entries.items.len), .little);
    try writer.writeInt(u16, @intCast(entries.items.len), .little);
    try writer.writeInt(u32, @intCast(directory_size), .little);
    try writer.writeInt(u32, @intCast(directory_start), .little);
    try writer.writeInt(u16, 0, .little); // No comment.
    var file = try std.Io.Dir.cwd().createFile(io, arguments[1], .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, out.written());
}

/// Version 1.0, stored, dated 1980-01-01.
fn local_header(writer: *std.Io.Writer, entry: Entry) !void {
    try writer.writeInt(u32, 0x04034b50, .little);
    try writer.writeInt(u16, 10, .little); // Needed to extract.
    try writer.writeInt(u16, 0, .little); // Flags.
    try writer.writeInt(u16, 0, .little); // Stored.
    try writer.writeInt(u16, 0, .little); // Time.
    try writer.writeInt(u16, 0x21, .little); // Date: 1980-01-01.
    try writer.writeInt(u32, entry.crc, .little);
    try writer.writeInt(u32, @intCast(entry.data.len), .little);
    try writer.writeInt(u32, @intCast(entry.data.len), .little);
    try writer.writeInt(u16, @intCast(entry.name.len), .little);
    try writer.writeInt(u16, 0, .little); // No extra field.
    try writer.writeAll(entry.name);
}

fn central_header(writer: *std.Io.Writer, entry: Entry) !void {
    try writer.writeInt(u32, 0x02014b50, .little);
    try writer.writeInt(u16, 10, .little); // Made by.
    try writer.writeInt(u16, 10, .little); // Needed to extract.
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0x21, .little);
    try writer.writeInt(u32, entry.crc, .little);
    try writer.writeInt(u32, @intCast(entry.data.len), .little);
    try writer.writeInt(u32, @intCast(entry.data.len), .little);
    try writer.writeInt(u16, @intCast(entry.name.len), .little);
    try writer.writeInt(u16, 0, .little); // Extra.
    try writer.writeInt(u16, 0, .little); // Comment.
    try writer.writeInt(u16, 0, .little); // Disk.
    try writer.writeInt(u16, 0, .little); // Internal attributes.
    try writer.writeInt(u32, 0, .little); // External attributes.
    try writer.writeInt(u32, entry.offset, .little);
    try writer.writeAll(entry.name);
}
