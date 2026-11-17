// SPDX-License-Identifier: MIT
//! Values with checksummed bodies (Antithesis's property catalogs' "no data corruption", on the
//! paths a workload's small values never take): a value is its identity alone, or "<identity>
//! <its body's CRC-32, 8 hex digits> <body>", the body random bytes of a drawn size. Readers split
//! a value back into its identity (what the workload tracks) and whether its body still matches.
//!
//!   const value = sdk.payloads.with_body(&buffer, identity, prng.random(), .{ .large_max = 16 * 1024 });
//!   const parts = sdk.payloads.parts(read);   // parts.identity, parts.intact
//!
//! A client in another language builds the value itself from a size drawn here (`body_size`),
//! so a large body never crosses the driver's line protocol: the same format, its CRC-32 the
//! IEEE one (java.util.zip.CRC32, zlib's crc32), its bytes any the client likes.
const std = @import("std");
const sdk = @import("determinismo.zig");

pub const Sizes = struct {
    /// Bodies up to this size, one value in five.
    small_max: usize = 4096,
    /// Bodies up to this size, one value in twenty (the buffer holds it with its identity).
    large_max: usize = 48 * 1024,
};

/// A value for `identity` in `buffer`: three in four the identity alone, else with a body (the
/// draw a platform decision, its bytes from `random`, a generator seeded once: one decision for
/// a large body, not thousands).
pub fn with_body(buffer: []u8, identity: []const u8, random: std.Random, sizes: Sizes) []const u8 {
    const size = body_size(sizes);
    if (size == 0) return identity;
    return with_body_of_size(buffer, identity, random, size);
}

/// A value's body size, drawn (a platform decision): 0, the identity alone, three in four.
pub fn body_size(sizes: Sizes) usize {
    const draw = sdk.random_below(100);
    if (draw < 75) return 0;
    return 1 + if (draw < 95) sdk.random_below(sizes.small_max) else sdk.random_below(sizes.large_max);
}

fn with_body_of_size(buffer: []u8, identity: []const u8, random: std.Random, size: usize) []const u8 {
    const head = identity.len + 10;
    std.debug.assert(head + size <= buffer.len);
    const body = buffer[head..][0..size];
    random.bytes(body);
    _ = std.fmt.bufPrint(buffer, "{s} {x:0>8} ", .{ identity, std.hash.Crc32.hash(body) }) catch unreachable;
    return buffer[0 .. head + size];
}

pub const Parts = struct { identity: []const u8, intact: bool };

/// A value's identity, and whether its body (if it has one) still matches its checksum.
pub fn parts(value: []const u8) Parts {
    const space = std.mem.indexOfScalar(u8, value, ' ') orelse return .{ .identity = value, .intact = true };
    const identity = value[0..space];
    const rest = value[space + 1 ..];
    if (rest.len < 9 or rest[8] != ' ') return .{ .identity = identity, .intact = false };
    const checksum = std.fmt.parseInt(u32, rest[0..8], 16) catch return .{ .identity = identity, .intact = false };
    return .{ .identity = identity, .intact = std.hash.Crc32.hash(rest[9..]) == checksum };
}

test parts {
    var buffer: [512]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    const value = with_body_of_size(&buffer, "0a0b0c0d-5", prng.random(), 100);
    try std.testing.expectEqualStrings("0a0b0c0d-5", parts(value).identity);
    try std.testing.expect(parts(value).intact);
    // A flipped byte in its body fails it; an identity alone is whole.
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..value.len], value);
    copy[value.len - 1] ^= 1;
    try std.testing.expect(!parts(copy[0..value.len]).intact);
    try std.testing.expect(parts("0a0b0c0d-5").intact);
    try std.testing.expect(!parts("0a0b0c0d-5 00000000 x").intact);
}
