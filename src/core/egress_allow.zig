// SPDX-License-Identifier: MIT
//! Which hosts a guest may reach outside (explore's --egress): core, as whether a guest's
//! connection goes through is part of its execution (egress_host.zig relays the allowed ones).
const std = @import("std");

/// Whether `host:port` is allowed: an entry `*` (everything), `host`, `host:port`, or
/// `*.domain` (any name under it, at any port; `domain` itself is not under it).
pub fn allow_matches(allow: []const []const u8, host: []const u8, port: u16) bool {
    var buffer: [300]u8 = undefined;
    const with_port = std.fmt.bufPrint(&buffer, "{s}:{d}", .{ host, port }) catch return false;
    for (allow) |entry| {
        if (std.mem.eql(u8, entry, "*")) return true;
        if (std.ascii.eqlIgnoreCase(entry, host) or std.ascii.eqlIgnoreCase(entry, with_port)) return true;
        if (std.mem.startsWith(u8, entry, "*.") and host.len > entry.len - 1 and
            std.ascii.endsWithIgnoreCase(host, entry[1..])) return true;
    }
    return false;
}

test "egress allowlists" {
    const allow = [_][]const u8{ "api.anthropic.com", "example.org:8443", "*.amazonaws.com" };
    try std.testing.expect(allow_matches(&allow, "api.anthropic.com", 443));
    try std.testing.expect(allow_matches(&allow, "API.Anthropic.com", 443));
    try std.testing.expect(allow_matches(&allow, "example.org", 8443));
    try std.testing.expect(!allow_matches(&allow, "example.org", 443));
    try std.testing.expect(allow_matches(&allow, "s3.us-east-1.amazonaws.com", 443));
    try std.testing.expect(!allow_matches(&allow, "amazonaws.com", 443));
    try std.testing.expect(!allow_matches(&allow, "evil-amazonaws.com", 443));
    try std.testing.expect(!allow_matches(&allow, "github.com", 443));
    try std.testing.expect(allow_matches(&[_][]const u8{"*"}, "github.com", 22));
}
