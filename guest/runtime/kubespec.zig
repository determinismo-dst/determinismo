// SPDX-License-Identifier: MIT
//! det-kubespec: the base runtime spec of an imported Kubernetes cluster's containers
//! (kubernetes.zig): containerd's default spec (`ctr oci spec`, on stdin) with what Antithesis
//! gives every container added, written to stdout. K3s's containerd makes every container from
//! it (its `determinismo` runtime, the default), so the pods an operator makes (CloudNativePG's
//! PostgreSQL instances) and bare Pods (ParadeDB's drivers) have it as Deployments' do:
//!
//!   /usr/lib/libvoidstar.so     determinismo's (the node's /opt/determinismo/lib), read-only:
//!                               programs built with Antithesis's instrumentation need it
//!                               (pg_search.so names it NEEDED), its SDKs use it
//!   /dev/determinismo           the device libvoidstar reaches the guest through, allowed
//!                               after the default spec's deny-all (the last rule wins)
//!   /opt/determinismo           the node's, read-only as every node has it: det-stop-faults,
//!                               ANTITHESIS_STOP_FAULTS (and DETERMINISMO_STOP_FAULTS) in the
//!                               environment, and the fault injector's control FIFO it writes
//!                               to (made when the injector starts, after the pods: the
//!                               directory's bind finds it)
//!   /opt/determinismo/coverage  the edges reported, shared by every process of every node
//!   /opt/determinismo/sdk       the SDKs' fallback output, ANTITHESIS_SDK_LOCAL_OUTPUT in the
//!                               environment
//!
//! containerd's CRI keeps a base spec's mounts but those a pod names at the same destination,
//! appends its device rules after these, and adds the image's environment to this one.
const std = @import("std");
const linux = std.os.linux;

const device_path = "/dev/determinismo";
const voidstar_source = "/opt/determinismo/lib/libvoidstar.so"; // initramfs.zig's.
const sdk_output = "ANTITHESIS_SDK_LOCAL_OUTPUT=/opt/determinismo/sdk/output";
const stop_faults_path = "/opt/determinismo/bin/det-stop-faults"; // nodes.zig's.
const stop_faults = [_][]const u8{
    "DETERMINISMO_STOP_FAULTS=" ++ stop_faults_path,
    "ANTITHESIS_STOP_FAULTS=" ++ stop_faults_path,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, device_path, 0, .{ .TYPE = true }, &stat);
    if (linux.errno(result) != .SUCCESS) {
        std.debug.print("det-kubespec: {s}: {s}\n", .{ device_path, @tagName(linux.errno(result)) });
        std.process.exit(1);
    }
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const text = try stdin.interface.allocRemaining(arena, .limited(1 << 20));
    const spec = try spec_with(arena, text, stat.rdev_major, stat.rdev_minor);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.writeAll(spec);
    try stdout.interface.flush();
}

/// `text` (an OCI runtime spec) with the device, mounts and environment above.
pub fn spec_with(arena: std.mem.Allocator, text: []const u8, major: u32, minor: u32) ![]const u8 {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (parsed != .object) return error.NotASpec;
    const spec = &parsed.object;

    const process = try object_at(arena, spec, "process");
    const env = try array_at(arena, process, "env");
    try env.append(.{ .string = sdk_output });
    for (stop_faults) |entry| try env.append(.{ .string = entry });

    const mounts = try array_at(arena, spec, "mounts");
    // The directory before the writable ones within it.
    try mounts.append(try bind(arena, "/opt/determinismo", "/opt/determinismo", "ro"));
    try mounts.append(try bind(arena, voidstar_source, "/usr/lib/libvoidstar.so", "ro"));
    try mounts.append(try bind(arena, "/opt/determinismo/coverage", "/opt/determinismo/coverage", "rw"));
    try mounts.append(try bind(arena, "/opt/determinismo/sdk", "/opt/determinismo/sdk", "rw"));

    const linux_object = try object_at(arena, spec, "linux");
    var node: std.json.ObjectMap = .empty;
    try node.put(arena, "path", .{ .string = device_path });
    try node.put(arena, "type", .{ .string = "c" });
    try node.put(arena, "major", .{ .integer = major });
    try node.put(arena, "minor", .{ .integer = minor });
    try node.put(arena, "fileMode", .{ .integer = 0o666 });
    try node.put(arena, "uid", .{ .integer = 0 });
    try node.put(arena, "gid", .{ .integer = 0 });
    try (try array_at(arena, linux_object, "devices")).append(.{ .object = node });
    const resources = try object_at(arena, linux_object, "resources");
    var rule: std.json.ObjectMap = .empty;
    try rule.put(arena, "allow", .{ .bool = true });
    try rule.put(arena, "type", .{ .string = "c" });
    try rule.put(arena, "major", .{ .integer = major });
    try rule.put(arena, "minor", .{ .integer = minor });
    try rule.put(arena, "access", .{ .string = "rwm" });
    // After the deny-all: rules apply in order, the last that matches wins.
    try (try array_at(arena, resources, "devices")).append(.{ .object = rule });

    return std.json.Stringify.valueAlloc(arena, parsed, .{ .whitespace = .indent_4 });
}

fn object_at(arena: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    const entry = try object.getOrPut(arena, key);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    if (entry.value_ptr.* != .object) return error.NotASpec;
    return &entry.value_ptr.object;
}

fn array_at(arena: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.Array {
    const entry = try object.getOrPut(arena, key);
    if (!entry.found_existing or entry.value_ptr.* == .null) entry.value_ptr.* = .{ .array = .init(arena) };
    if (entry.value_ptr.* != .array) return error.NotASpec;
    return &entry.value_ptr.array;
}

fn bind(arena: std.mem.Allocator, source: []const u8, destination: []const u8, access: []const u8) !std.json.Value {
    var mount: std.json.ObjectMap = .empty;
    try mount.put(arena, "destination", .{ .string = destination });
    try mount.put(arena, "type", .{ .string = "bind" });
    try mount.put(arena, "source", .{ .string = source });
    var options: std.json.Array = .init(arena);
    try options.append(.{ .string = "rbind" });
    try options.append(.{ .string = access });
    try mount.put(arena, "options", .{ .array = options });
    return .{ .object = mount };
}

test "containerd's default spec given libvoidstar, the device after the deny-all, determinismo's directory, the coverage, the SDK's output and the quiet-period command" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // K3s v1.36.5's `ctr oci spec`, its capabilities and most mounts left out.
    const default =
        \\{"ociVersion": "1.3.0",
        \\ "process": {"user": {"uid": 0, "gid": 0}, "cwd": "/", "noNewPrivileges": true},
        \\ "root": {"path": "rootfs"},
        \\ "mounts": [{"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid"]}],
        \\ "linux": {"resources": {"devices": [{"allow": false, "access": "rwm"}]},
        \\           "cgroupsPath": "/k8s.io", "namespaces": [{"type": "pid"}]}}
    ;
    const text = try spec_with(arena, default, 10, 123);
    const Spec = struct {
        ociVersion: []const u8,
        process: struct { env: []const []const u8, cwd: []const u8 },
        mounts: []const struct { destination: []const u8, type: []const u8, source: []const u8, options: []const []const u8 },
        linux: struct {
            devices: []const struct { path: []const u8, type: []const u8, major: u32, minor: u32 },
            resources: struct { devices: []const struct { allow: bool, type: ?[]const u8 = null, major: ?u32 = null, minor: ?u32 = null, access: []const u8 } },
            cgroupsPath: []const u8,
        },
    };
    const spec = try std.json.parseFromSliceLeaky(Spec, arena, text, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("1.3.0", spec.ociVersion); // The rest kept.
    try std.testing.expectEqualStrings("/k8s.io", spec.linux.cgroupsPath);
    try std.testing.expectEqual(@as(usize, 3), spec.process.env.len);
    try std.testing.expectEqualStrings(sdk_output, spec.process.env[0]);
    try std.testing.expectEqualStrings("DETERMINISMO_STOP_FAULTS=/opt/determinismo/bin/det-stop-faults", spec.process.env[1]);
    try std.testing.expectEqualStrings("ANTITHESIS_STOP_FAULTS=/opt/determinismo/bin/det-stop-faults", spec.process.env[2]);
    try std.testing.expectEqual(@as(usize, 5), spec.mounts.len);
    try std.testing.expectEqualStrings("/proc", spec.mounts[0].destination);
    // Determinismo's directory first, read-only: the writable binds within it come after.
    try std.testing.expectEqualStrings("/opt/determinismo", spec.mounts[1].destination);
    try std.testing.expectEqualStrings("ro", spec.mounts[1].options[1]);
    try std.testing.expectEqualStrings("/usr/lib/libvoidstar.so", spec.mounts[2].destination);
    try std.testing.expectEqualStrings(voidstar_source, spec.mounts[2].source);
    try std.testing.expectEqualStrings("ro", spec.mounts[2].options[1]);
    try std.testing.expectEqualStrings("/opt/determinismo/coverage", spec.mounts[3].destination);
    try std.testing.expectEqualStrings("rw", spec.mounts[3].options[1]);
    try std.testing.expectEqualStrings("/opt/determinismo/sdk", spec.mounts[4].destination);
    try std.testing.expectEqualStrings(device_path, spec.linux.devices[0].path);
    try std.testing.expectEqual(@as(u32, 123), spec.linux.devices[0].minor);
    // The deny-all first, then the device allowed: the last rule that matches wins.
    try std.testing.expectEqual(@as(usize, 2), spec.linux.resources.devices.len);
    try std.testing.expect(!spec.linux.resources.devices[0].allow);
    try std.testing.expect(spec.linux.resources.devices[1].allow);
    try std.testing.expectEqual(@as(?u32, 10), spec.linux.resources.devices[1].major);
    try std.testing.expectError(error.NotASpec, spec_with(arena, "[]", 10, 123));
}
