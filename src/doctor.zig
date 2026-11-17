// SPDX-License-Identifier: MIT
//! `determinismo doctor`: whether this machine can run determinismo, each requirement checked and,
//! when one is not met, what to do about it. For someone setting up a host of their own: a
//! rented bare-metal Intel server (docs/GETTING_STARTED.md), set up with infra/host/setup.sh.
//! No root needed; the VMX controls themselves are read from MSRs, as root, by
//! infra/host/m0-check.sh (setup.sh runs it). Exit 1 when something blocks a run.
const std = @import("std");
const linux = std.os.linux;
const holders = @import("holders.zig");

var blocking: u32 = 0;
var warnings: u32 = 0;

const Verdict = enum { ok, warn, fail };

fn report(verdict: Verdict, name: []const u8, comptime format: []const u8, arguments: anytype) void {
    switch (verdict) {
        .ok => {},
        .warn => warnings += 1,
        .fail => blocking += 1,
    }
    const tag = switch (verdict) {
        .ok => "ok  ",
        .warn => "warn",
        .fail => "FAIL",
    };
    std.debug.print("  {s}  {s:<34} " ++ format ++ "\n", .{ tag, name } ++ arguments);
}

/// A small file whole (procfs, sysfs), or null.
fn read_small(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var length: usize = 0;
    while (length < buffer.len) {
        const read = linux.read(fd, buffer[length..].ptr, buffer.len - length);
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        length += read;
    }
    return buffer[0..length];
}

fn exists(path: []const u8, mode: u32) bool {
    var buffer: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0) catch return false;
    return linux.errno(linux.access(z, mode)) == .SUCCESS;
}

/// Whether `name` is an executable on PATH.
fn on_path(name: []const u8) bool {
    const path = std.mem.span(std.c.getenv("PATH") orelse return false);
    var directories = std.mem.tokenizeScalar(u8, path, ':');
    while (directories.next()) |directory| {
        var buffer: [4096]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ directory, name }) catch continue;
        if (exists(candidate, linux.X_OK)) return true;
    }
    return false;
}

/// A /proc/meminfo field, in GiB.
fn meminfo_gib(text: []const u8, field: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var words = std.mem.tokenizeScalar(u8, line[field.len..], ' ');
        const kib = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
        return kib >> 20;
    }
    return null;
}

pub fn main(init: std.process.Init, argv: []const [:0]const u8) !void {
    _ = init;
    if (argv.len > 0) {
        std.debug.print("usage: determinismo doctor (no options): checks this machine for determinismo\n", .{});
        std.process.exit(2);
    }
    std.debug.print("determinismo doctor: can this machine run determinismo?\n\n== CPU\n", .{});
    var cpuinfo_buffer: [1 << 20]u8 = undefined;
    const cpuinfo = read_small("/proc/cpuinfo", &cpuinfo_buffer) orelse "";
    const model = field_of(cpuinfo, "model name") orelse "unknown";
    const vendor = field_of(cpuinfo, "vendor_id") orelse "unknown";
    const flags = field_of(cpuinfo, "flags") orelse "";
    if (std.mem.eql(u8, vendor, "GenuineIntel"))
        report(.ok, "Intel CPU", "{s}", .{model})
    else
        report(.fail, "Intel CPU", "{s} ({s}): determinismo's hypervisor is Intel VT-x only (AMD is not supported)", .{ model, vendor });
    if (has_flag(flags, "vmx"))
        report(.ok, "VT-x (vmx)", "", .{})
    else
        report(.fail, "VT-x (vmx)", "not visible: enable virtualization in the BIOS, or this is a VM without nested VT-x (use bare metal)", .{});
    if (has_flag(flags, "constant_tsc") and has_flag(flags, "nonstop_tsc"))
        report(.ok, "invariant TSC", "", .{})
    else
        report(.fail, "invariant TSC", "missing: virtual time is the TSC's (constant_tsc and nonstop_tsc needed)", .{});
    const logical = count_lines(cpuinfo, "processor");
    const physical = physical_cores(cpuinfo);
    if (physical >= 8)
        report(.ok, "cores", "{d} physical ({d} logical): one VM per physical core", .{ physical, logical })
    else
        report(.warn, "cores", "{d} physical ({d} logical): runs work, few timelines at once", .{ physical, logical });
    std.debug.print("  (VMX controls: RDTSC exiting, EPT, the preemption timer: `sudo infra/host/m0-check.sh`)\n", .{});

    std.debug.print("\n== Memory and disk\n", .{});
    var meminfo_buffer: [16 << 10]u8 = undefined;
    const meminfo = read_small("/proc/meminfo", &meminfo_buffer) orelse "";
    const total = meminfo_gib(meminfo, "MemTotal:") orelse 0;
    if (total >= 64)
        report(.ok, "memory", "{d} GiB", .{total})
    else if (total >= 16)
        report(.warn, "memory", "{d} GiB: a VM takes 2 to 8 GiB, so few run at once (64 GiB or more for hunts)", .{total})
    else
        report(.fail, "memory", "{d} GiB: below 16 GiB, most systems' VMs do not fit", .{total});
    const home = std.mem.span(std.c.getenv("HOME") orelse "/");
    var free_gib: u64 = 0;
    var total_gib: u64 = 0;
    if (disk_of(home)) |disk| {
        free_gib = disk.free >> 30;
        total_gib = disk.total >> 30;
    }
    const reserve_gib = @max(holders.disk_reserve_min, (total_gib << 30) / 100 * holders.disk_reserve_percent) >> 30;
    if (free_gib >= reserve_gib + 100)
        report(.ok, "disk", "{d} GB free of {d} under {s}", .{ free_gib, total_gib, home })
    else if (free_gib >= 30)
        report(.warn, "disk", "{d} GB free of {d}: under the in-run snapshots' reserve ({d} GB) they stay in memory or are replayed", .{ free_gib, total_gib, reserve_gib })
    else
        report(.fail, "disk", "{d} GB free: runs keep tapes, events and snapshots (30 GB at least)", .{free_gib});

    std.debug.print("\n== KVM\n", .{});
    if (exists("/dev/kvm", linux.R_OK | linux.W_OK))
        report(.ok, "/dev/kvm", "readable and writable", .{})
    else if (exists("/dev/kvm", linux.F_OK))
        report(.fail, "/dev/kvm", "not yours: add this user to the kvm group (sudo usermod -aG kvm $USER), log in again", .{})
    else
        report(.fail, "/dev/kvm", "absent: KVM not loaded (infra/host/setup.sh builds and loads ours)", .{});
    var taint_buffer: [64]u8 = undefined;
    const taint = read_small("/sys/module/kvm/taint", &taint_buffer) orelse "";
    if (std.mem.indexOfScalar(u8, taint, 'O') != null and exists("/run/determinismo-kvm", linux.F_OK))
        report(.ok, "determinismo's KVM", "loaded (kernel/patches: deterministic exits)", .{})
    else if (taint.len > 0)
        report(.fail, "determinismo's KVM", "the stock KVM is loaded: runs need ours (infra/host/build-kvm.sh, then sudo infra/host/load-kvm.sh)", .{})
    else
        report(.fail, "determinismo's KVM", "no KVM module loaded (infra/host/setup.sh builds and loads ours, at every boot)", .{});
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const release = std.mem.sliceTo(&uts.release, 0);
    var build_buffer: [512]u8 = undefined;
    const build = std.fmt.bufPrint(&build_buffer, "/lib/modules/{s}/build", .{release}) catch "";
    if (exists(build, linux.F_OK))
        report(.ok, "kernel headers", "{s} (ours is built against them)", .{release})
    else
        report(.warn, "kernel headers", "none for {s}: building our KVM needs them (apt install linux-headers-{s})", .{ release, release });

    std.debug.print("\n== Guest and containers\n", .{});
    var guest_buffer: [4096]u8 = undefined;
    for ([_][]const u8{ "vmlinuz", "base.cpio" }) |name| {
        const path = std.fmt.bufPrint(&guest_buffer, "{s}/guest/{s}", .{ home, name }) catch "";
        if (exists(path, linux.R_OK))
            report(.ok, name, "{s}", .{path})
        else
            report(.fail, name, "{s} missing: the guest (zig build guest, or infra/host/setup.sh)", .{path});
    }
    if (on_path("podman"))
        report(.ok, "podman", "builds the system's images from its Dockerfiles", .{})
    else
        report(.fail, "podman", "not on PATH: systems' nodes are built with it (apt install podman)", .{});
    var controllers_buffer: [512]u8 = undefined;
    const controllers = read_small("/sys/fs/cgroup/cgroup.controllers", &controllers_buffer) orelse "";
    if (std.mem.indexOf(u8, controllers, "cpuset") != null)
        report(.ok, "cgroup v2 with cpuset", "VMs pinned to their cores", .{})
    else
        report(.warn, "cgroup v2 with cpuset", "not found: VMs are not pinned (timelines share cores, slower)", .{});

    std.debug.print("\n", .{});
    if (blocking == 0) {
        std.debug.print("Ready: {d} warning(s). Next: docs/GETTING_STARTED.md's first example.\n", .{warnings});
    } else {
        std.debug.print("Not ready: {d} problem(s) to fix first, {d} warning(s).\n", .{ blocking, warnings });
        std.process.exit(1);
    }
}

/// The first `name : value` field of /proc/cpuinfo.
fn field_of(cpuinfo: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, cpuinfo, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn has_flag(flags: []const u8, flag: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, flags, ' ');
    while (words.next()) |word| if (std.mem.eql(u8, word, flag)) return true;
    return false;
}

fn count_lines(text: []const u8, prefix: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix) and std.mem.indexOfScalar(u8, line, ':') != null) count += 1;
    }
    return count;
}

/// Distinct (physical id, core id) pairs: the physical cores.
fn physical_cores(cpuinfo: []const u8) u32 {
    var seen: [1024]u64 = undefined;
    var count: u32 = 0;
    var package: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, cpuinfo, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const value = std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch continue;
        if (std.mem.startsWith(u8, line, "physical id")) package = value;
        if (!std.mem.startsWith(u8, line, "core id")) continue;
        const key = package << 32 | value;
        if (std.mem.indexOfScalar(u64, seen[0..count], key) == null and count < seen.len) {
            seen[count] = key;
            count += 1;
        }
    }
    return count;
}

const Disk = struct { free: u64, total: u64 };

fn disk_of(directory: []const u8) ?Disk {
    var path_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return null;
    var buffer: holders.Statfs = undefined;
    const result = linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&buffer));
    if (linux.errno(result) != .SUCCESS) return null;
    const block: u64 = @intCast(buffer.bsize);
    return .{ .free = buffer.bavail * block, .total = buffer.blocks * block };
}

test physical_cores {
    const two_threads_one_core = "processor\t: 0\nphysical id\t: 0\ncore id\t\t: 0\n" ++
        "processor\t: 1\nphysical id\t: 0\ncore id\t\t: 0\nprocessor\t: 2\nphysical id\t: 1\ncore id\t\t: 0\n";
    try std.testing.expectEqual(@as(u32, 2), physical_cores(two_threads_one_core));
    try std.testing.expectEqual(@as(u32, 3), count_lines(two_threads_one_core, "processor"));
}
