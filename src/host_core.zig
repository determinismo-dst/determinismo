// SPDX-License-Identifier: MIT
//! The host's part of a run's core: its KVM modules (the KVM patch, infra/host/load-kvm.sh),
//! identified by their ELF build IDs (/sys/module/<module>/notes). A run records it beside its
//! core_id (PLAN: a run pins its core); a resume or a replay runs a newer explorer only on the
//! same, as the modules decide how a guest's exits and clocks behave.
const std = @import("std");
const linux = std.os.linux;

/// "kvm:<id>,kvm_intel:<id>", or "unknown" where a module or its note cannot be read (never the
/// same as any run's: an unknown host keeps every run on its own explorer).
pub fn kvm_identity(arena: std.mem.Allocator) []const u8 {
    var ids: [2][]const u8 = undefined;
    for ([_][]const u8{ "kvm", "kvm_intel" }, 0..) |module, at| {
        ids[at] = build_id(arena, module) orelse return "unknown";
    }
    return std.fmt.allocPrint(arena, "kvm:{s},kvm_intel:{s}", .{ ids[0], ids[1] }) catch "unknown";
}

fn build_id(arena: std.mem.Allocator, module: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrintSentinel(arena, "/sys/module/{s}/notes/.note.gnu.build-id", .{module}, 0) catch return null;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [256]u8 = undefined;
    const size = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return note_id(arena, buffer[0..size]);
}

/// An ELF note's descriptor as hex: namesz, descsz and type (4 bytes each), the name padded to 4,
/// then the descriptor (a GNU build ID: 20 bytes).
fn note_id(arena: std.mem.Allocator, note: []const u8) ?[]const u8 {
    if (note.len < 12) return null;
    const name_size = std.mem.readInt(u32, note[0..4], .little);
    const desc_size = std.mem.readInt(u32, note[4..8], .little);
    const desc_at = 12 + std.mem.alignForward(usize, name_size, 4);
    if (desc_size == 0 or desc_at + desc_size > note.len) return null;
    return std.fmt.allocPrint(arena, "{x}", .{note[desc_at .. desc_at + desc_size]}) catch null;
}

test note_id {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // kvm's on srv4 (2026-11-15): "GNU\0", a 20-byte build ID.
    const note = [_]u8{ 4, 0, 0, 0, 20, 0, 0, 0, 3, 0, 0, 0, 'G', 'N', 'U', 0 } ++
        [_]u8{ 0x4e, 0x3e, 0x0a, 0x38, 0x1d, 0x38, 0x12, 0x5f, 0x67, 0xe0, 0x04, 0x6a, 0xd9, 0xd3, 0xa9, 0x96, 0x31, 0xe6, 0xf4, 0xc5 };
    try std.testing.expectEqualStrings("4e3e0a381d38125f67e0046ad9d3a99631e6f4c5", note_id(arena.allocator(), &note).?);
    try std.testing.expectEqual(@as(?[]const u8, null), note_id(arena.allocator(), note[0..20]));
}
