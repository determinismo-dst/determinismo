// SPDX-License-Identifier: MIT
//! The guest-visible CPU. Starts from what KVM supports and removes everything that would leak host
//! time, host randomness or host topology into the guest (ARCHITECTURE.md §5).
const std = @import("std");
const assert = std.debug.assert;
const kvm = @import("kvm.zig");

pub const tsc_hz: u64 = 4_000_000_000;
const crystal_hz: u32 = 25_000_000;

comptime {
    assert(tsc_hz % crystal_hz == 0); // CPUID 0x15 expresses the ratio exactly.
    assert(tsc_hz % std.time.ns_per_s == 0); // TSC ticks per nanosecond is an integer.
}

/// Filters `entries[0..count]` in place and appends leaves 0x15 and 0x16.
pub fn make_deterministic(entries: []kvm.CpuidEntry2, count: *u32) void {
    assert(count.* <= entries.len);
    var kept: u32 = 0;
    for (entries[0..count.*]) |entry| {
        // KVM paravirt leaves: kvmclock, async page faults, steal time, PV EOI.
        if (entry.function >= 0x4000_0000 and entry.function <= 0x4000_00ff) continue;
        if (entry.function == 0x15 or entry.function == 0x16) continue; // Replaced below.
        // MPX's XSAVE components (BNDREGS, BNDCSR): hidden with MPX (filter's leaf 7).
        if (entry.function == 0xd and (entry.index == 3 or entry.index == 4)) continue;
        entries[kept] = entry;
        filter(&entries[kept]);
        kept += 1;
    }
    assert(kept + 2 <= entries.len);
    // TSC frequency = crystal * ebx / eax, so the guest never calibrates against a timer.
    entries[kept] = .{
        .function = 0x15,
        .index = 0,
        .flags = 0,
        .eax = 1,
        .ebx = @intCast(tsc_hz / crystal_hz),
        .ecx = crystal_hz,
        .edx = 0,
    };
    entries[kept + 1] = .{
        .function = 0x16,
        .index = 0,
        .flags = 0,
        .eax = tsc_hz / 1_000_000,
        .ebx = tsc_hz / 1_000_000,
        .ecx = 100,
        .edx = 0,
    };
    count.* = kept + 2;
}

fn filter(entry: *kvm.CpuidEntry2) void {
    assert(entry.function < 0x4000_0000 or entry.function > 0x4000_00ff);
    switch (entry.function) {
        0 => entry.eax = @max(entry.eax, 0x16),
        1 => {
            entry.ecx &= ~(bit(30) | bit(24) | bit(15)); // RDRAND, TSC-deadline timer, PDCM
            // VMX: our guests run no VMs, and with it shown the kernel reads the IA32_VMX_*
            // capabilities at boot, which differ from one CPU generation to the next.
            entry.ecx &= ~bit(5);
            // KVM reports the APIC ID of whichever host CPU asked: present one fixed vCPU.
            entry.ebx = (entry.ebx & 0x0000_ffff) | (1 << 16); // APIC ID 0, 1 logical CPU
            entry.edx &= ~bit(28); // HTT
        },
        4 => entry.eax &= 0x0000_3fff, // One core, no cache sharing.
        6 => entry.ecx &= ~bit(0), // APERF/MPERF
        7 => if (entry.index == 0) {
            entry.ebx &= ~(bit(18) | bit(11) | bit(4) | bit(1)); // RDSEED, RTM, HLE, TSC_ADJUST
            // MPX: Linux dropped it in 5.6 and no compiler emits it by default, but its XSAVE
            // state the kernel still enables when shown, and CPUs since Ice Lake lack it: a
            // run recorded with it replays on Skylake and Cascade Lake alone (srv4's on a
            // Granite Rapids c8i: refused, 2026-11-09).
            entry.ebx &= ~bit(14);
            // SGX and its launch control: the guest has no enclave memory (the VMM gives it no
            // EPC) and the performance counters that drive virtual time do not count inside
            // enclaves; shown, a run recorded on an SGX host (phoenixNAP's E-2276G) replayed on
            // SGX hosts alone (srv4's Gold 6152 refused it, 2026-11-10).
            entry.ebx &= ~bit(2);
            entry.ecx &= ~bit(30);
            entry.ecx &= ~(bit(22) | bit(5)); // RDPID, WAITPKG (TSC-timed waits)
        },
        0x12 => {
            // SGX's own leaf (enclave memory sections, sizes), with SGX hidden (leaf 7): emptied,
            // not dropped, so a host without SGX (its leaf already zeros: srv4's) keeps the very
            // table it had.
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx = 0;
            entry.edx = 0;
        },
        0xa => {
            // No PMU for the guest: the host owns the counters that drive virtual time.
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx = 0;
            entry.edx = 0;
        },
        0xd => if (entry.index == 1) {
            // XSAVEOPT, XSAVEC, XGETBV(ECX=1) and XSAVES expose the processor's XINUSE tracking,
            // which host-side FPU save/restore perturbs at arbitrary moments (rr masks it too).
            entry.eax &= ~(bit(0) | bit(1) | bit(2) | bit(3));
        } else if (entry.index == 0) {
            entry.eax &= ~(bit(3) | bit(4)); // MPX's state components (BNDREGS, BNDCSR).
        },
        0xb, 0x1f => {
            entry.edx = 0; // x2APIC ID
            if (entry.ebx != 0) entry.ebx = 1; // One logical processor at every level.
        },
        0x8000_0001 => entry.edx &= ~bit(27), // RDTSCP
        0x8000_0007 => entry.edx |= bit(8), // Invariant TSC.
        else => {},
    }
    if (entry.function == 1) assert(entry.ebx >> 24 == 0);
    if (entry.function == 0xa) assert(entry.eax == 0);
}

fn bit(comptime index: u5) u32 {
    return @as(u32, 1) << index;
}

test "SGX hidden, its leaf emptied" {
    var entries = [_]kvm.CpuidEntry2{
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0x009c27af, .ecx = 0x40000004, .edx = 0 },
        .{ .function = 0x12, .index = 0, .flags = 1, .eax = 1, .ebx = 0, .ecx = 0, .edx = 0x241f },
        .{ .function = 0x12, .index = 2, .flags = 1, .eax = 0x70200001, .ebx = 0, .ecx = 0x5d80001, .edx = 0 },
        undefined,
        undefined,
    };
    var count: u32 = 3;
    make_deterministic(&entries, &count);
    try std.testing.expectEqual(@as(u32, 5), count); // Leaf 7 and both 0x12 kept, 0x15 and 0x16 added.
    try std.testing.expectEqual(@as(u32, 0), entries[0].ebx & bit(2));
    try std.testing.expectEqual(@as(u32, 0), entries[0].ecx & bit(30));
    for (entries[0..count]) |entry| if (entry.function == 0x12) {
        try std.testing.expectEqual(@as(u32, 0), entry.eax | entry.ebx | entry.ecx | entry.edx);
    };
}

test "MPX and VMX hidden, MPX's XSAVE components dropped" {
    var entries = [_]kvm.CpuidEntry2{
        .{ .function = 1, .index = 0, .flags = 0, .eax = 0x50654, .ebx = 0, .ecx = 0x36fa3223, .edx = 0 },
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0xd19b67e9, .ecx = 0xc, .edx = 0 },
        .{ .function = 0xd, .index = 0, .flags = 1, .eax = 0x2ff, .ebx = 0xa88, .ecx = 0xa88, .edx = 0 },
        .{ .function = 0xd, .index = 3, .flags = 1, .eax = 0x40, .ebx = 0x3c0, .ecx = 0, .edx = 0 },
        .{ .function = 0xd, .index = 4, .flags = 1, .eax = 0x40, .ebx = 0x400, .ecx = 0, .edx = 0 },
        undefined,
        undefined,
    };
    var count: u32 = 5;
    make_deterministic(&entries, &count);
    try std.testing.expectEqual(@as(u32, 5), count); // Three kept, 0x15 and 0x16 added.
    try std.testing.expectEqual(@as(u32, 0), entries[0].ecx & bit(5));
    try std.testing.expectEqual(@as(u32, 0), entries[1].ebx & bit(14));
    try std.testing.expectEqual(@as(u32, 0x2e7), entries[2].eax);
    for (entries[0..count]) |entry| try std.testing.expect(!(entry.function == 0xd and entry.index >= 3 and entry.index <= 4));
}

test make_deterministic {
    const zero = kvm.CpuidEntry2{
        .function = 0,
        .index = 0,
        .flags = 0,
        .eax = 0,
        .ebx = 0,
        .ecx = 0,
        .edx = 0,
    };
    var entries = [_]kvm.CpuidEntry2{ zero, zero, zero, zero };
    entries[0].function = 1;
    entries[0].ebx = 0x0302_0800; // APIC ID 3 from the host.
    entries[0].ecx = bit(30);
    entries[1].function = 0x4000_0000;
    var count: u32 = 2;
    make_deterministic(&entries, &count);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 0), entries[0].ebx >> 24);
    try std.testing.expectEqual(@as(u32, 0), entries[0].ecx & bit(30));
    try std.testing.expectEqual(@as(u32, 0x15), entries[1].function);
}

/// A guest's CPUID table as text, one entry a line: function, index, flags, eax, ebx, ecx, edx
/// in hex. A run recorded on one host replays on another CPU model only with the same table
/// (glibc, JITs and runtimes choose their code by it, and with it their branch counts): the
/// recording host's, dumped with `determinismo cpuid` and booted with `--cpuid <file>`.
pub fn table_write(entries: []const kvm.CpuidEntry2, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (entries) |entry| {
        try writer.print("{x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
            entry.function, entry.index, entry.flags, entry.eax, entry.ebx, entry.ecx, entry.edx,
        });
    }
}

/// The model-specific registers that, with CPUID, choose the guest kernel's code, all filled by
/// KVM from the host: IA32_ARCH_CAPABILITIES (the kernel's mitigations: IBRS or eIBRS, return
/// thunks, other code on every entry), IA32_CORE_CAPABILITIES, and with VMX visible (srv4's
/// nested=Y) the IA32_VMX_* capabilities the kernel reads at boot (feat_ctl.c), richer on Granite
/// Rapids than on Skylake-SP. A table from another host carries its values, set on the vCPU with
/// it (a review from another session, 2026-11-09).
pub const arch_capabilities: u32 = 0x10a;
/// RSBA ("RET may use alternative branch predictors"): a hint a Skylake-family guest's kernel
/// derives from its CPU model anyway, set by Skylake hosts and not settable on newer ones (a
/// Granite Rapids c8i refused srv4's): hidden, as MPX and VMX are, so a run's guest can be shown
/// on CPUs of later generations.
const arch_capabilities_rsba: u64 = 1 << 2;

/// The IA32_ARCH_CAPABILITIES a deterministic guest sees: its vCPU's, without RSBA.
pub fn arch_capabilities_portable(value: u64) u64 {
    return value & ~arch_capabilities_rsba;
}
const core_capabilities: u32 = 0xcf;
const vmx_first: u32 = 0x480; // IA32_VMX_BASIC
const vmx_last: u32 = 0x491; // IA32_VMX_VMFUNC
/// The VMX capabilities KVM lets userspace set (vmx_set_vmx_msr): the non-"true" controls
/// (0x481 to 0x484) and CR0/CR4_FIXED1 (0x487, 0x489) it derives from these and from CPUID, and
/// refuses (srv4 refused its own 0x481).
const vmx_writable = [_]u32{ 0x480, 0x485, 0x486, 0x488, 0x48a, 0x48b, 0x48c, 0x48d, 0x48e, 0x48f, 0x490, 0x491 };
pub const pinned_msrs = [_]u32{ arch_capabilities, core_capabilities } ++ vmx_writable;

/// Whether the table makes the MSR visible to the guest: VMX's when leaf 1 sets VMX, CORE_CAPABILITIES
/// when leaf 7 sets it, ARCH_CAPABILITIES always (KVM gives it every guest).
pub fn msr_gated_on(entries: []const kvm.CpuidEntry2, index: u32) bool {
    if (index >= vmx_first and index <= vmx_last) {
        const leaf = find(entries, 1, 0) orelse return false;
        return leaf.ecx & (1 << 5) != 0;
    }
    if (index == core_capabilities) {
        const leaf = find(entries, 7, 0) orelse return false;
        return leaf.edx & (1 << 30) != 0;
    }
    return index == arch_capabilities;
}

/// The pinned MSRs' lines of a table's text: `msr <index> <value>`, in hex.
pub fn msrs_write(msrs: []const kvm.MsrEntry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (msrs) |msr| try writer.print("msr {x:0>8} {x:0>16}\n", .{ msr.index, msr.data });
}

/// The `msr` lines of a table's text into `msrs`: how many.
pub fn msrs_parse(text: []const u8, msrs: []kvm.MsrEntry) error{ CpuidTableInvalid, CpuidTableTooLarge }!u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        if (!std.mem.eql(u8, first, "msr")) continue;
        if (count == msrs.len) return error.CpuidTableTooLarge;
        const index = std.fmt.parseInt(u32, words.next() orelse return error.CpuidTableInvalid, 16) catch return error.CpuidTableInvalid;
        const data = std.fmt.parseInt(u64, words.next() orelse return error.CpuidTableInvalid, 16) catch return error.CpuidTableInvalid;
        if (words.next() != null) return error.CpuidTableInvalid;
        msrs[count] = .{ .index = index, .data = data };
        count += 1;
    }
    return count;
}

/// Parses table_write's text into `entries` (its `msr` lines left to msrs_parse): how many.
pub fn table_parse(text: []const u8, entries: []kvm.CpuidEntry2) error{ CpuidTableInvalid, CpuidTableTooLarge }!u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (std.mem.startsWith(u8, line, "msr ")) continue;
        if (count == entries.len) return error.CpuidTableTooLarge;
        var fields: [7]u32 = undefined;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        for (&fields) |*field| {
            const word = words.next() orelse return error.CpuidTableInvalid;
            field.* = std.fmt.parseInt(u32, word, 16) catch return error.CpuidTableInvalid;
        }
        if (words.next() != null) return error.CpuidTableInvalid;
        entries[count] = .{
            .function = fields[0],
            .index = fields[1],
            .flags = fields[2],
            .eax = fields[3],
            .ebx = fields[4],
            .ecx = fields[5],
            .edx = fields[6],
        };
        count += 1;
    }
    return count;
}

/// The registers that are feature flags, by leaf and subleaf: a table from another host may set
/// only what this host's KVM supports.
const FeatureRegisters = struct { function: u32, index: u32, eax: bool = false, ebx: bool = false, ecx: bool = false, edx: bool = false };
const feature_registers = [_]FeatureRegisters{
    .{ .function = 1, .index = 0, .ecx = true, .edx = true },
    .{ .function = 7, .index = 0, .ebx = true, .ecx = true, .edx = true },
    .{ .function = 7, .index = 1, .eax = true, .edx = true },
    .{ .function = 0xd, .index = 0, .eax = true, .edx = true }, // XSAVE state components.
    .{ .function = 0xd, .index = 1, .eax = true },
    .{ .function = 0x8000_0001, .index = 0, .ecx = true, .edx = true },
};

pub const Missing = struct { function: u32, index: u32, register: []const u8, bits: u32 };

/// The first feature `wanted` sets that `supported` (this host's KVM) lacks, or null: a table
/// this host can present.
pub fn missing_feature(wanted: []const kvm.CpuidEntry2, supported: []const kvm.CpuidEntry2) ?Missing {
    for (feature_registers) |leaf| {
        const want = find(wanted, leaf.function, leaf.index) orelse continue;
        const have = find(supported, leaf.function, leaf.index) orelse kvm.CpuidEntry2{
            .function = leaf.function,
            .index = leaf.index,
            .flags = 0,
            .eax = 0,
            .ebx = 0,
            .ecx = 0,
            .edx = 0,
        };
        const checks = [_]struct { bool, []const u8, u32, u32 }{
            .{ leaf.eax, "eax", want.eax, have.eax },
            .{ leaf.ebx, "ebx", want.ebx, have.ebx },
            .{ leaf.ecx, "ecx", want.ecx, have.ecx },
            .{ leaf.edx, "edx", want.edx, have.edx },
        };
        for (checks) |check| {
            if (!check[0]) continue;
            const bits = check[2] & ~check[3];
            if (bits != 0) return .{ .function = leaf.function, .index = leaf.index, .register = check[1], .bits = bits };
        }
    }
    return null;
}

fn find(entries: []const kvm.CpuidEntry2, function: u32, index: u32) ?kvm.CpuidEntry2 {
    for (entries) |entry| {
        if (entry.function == function and entry.index == index) return entry;
    }
    return null;
}

test "a CPUID table round-trips as text" {
    const entries = [_]kvm.CpuidEntry2{
        .{ .function = 1, .index = 0, .flags = 0, .eax = 0x50654, .ebx = 0x800, .ecx = 0xfffa3203, .edx = 0x178bfbff },
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0xd19f4fbb, .ecx = 0x8, .edx = 0 },
    };
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table_write(&entries, &writer);
    var parsed: [4]kvm.CpuidEntry2 = undefined;
    const count = try table_parse(writer.buffered(), &parsed);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqualDeep(entries[0], parsed[0]);
    try std.testing.expectEqualDeep(entries[1], parsed[1]);
    try std.testing.expectError(error.CpuidTableInvalid, table_parse("1 2 3\n", &parsed));
    // The pinned MSRs ride along, skipped by table_parse.
    const msrs = [_]kvm.MsrEntry{.{ .index = arch_capabilities, .data = 0x2000_0c04 }};
    try msrs_write(&msrs, &writer);
    try std.testing.expectEqual(@as(u32, 2), try table_parse(writer.buffered(), &parsed));
    var parsed_msrs: [2]kvm.MsrEntry = undefined;
    try std.testing.expectEqual(@as(u32, 1), try msrs_parse(writer.buffered(), &parsed_msrs));
    try std.testing.expectEqual(@as(u64, 0x2000_0c04), parsed_msrs[0].data);
    try std.testing.expectEqual(arch_capabilities, parsed_msrs[0].index);
    try std.testing.expectError(error.CpuidTableTooLarge, table_parse(writer.buffered(), parsed[0..1]));
    try std.testing.expectError(error.CpuidTableInvalid, msrs_parse("msr 10a\n", &parsed_msrs));
}

test "a table this host lacks a feature of is refused, by leaf and register" {
    const skylake = [_]kvm.CpuidEntry2{
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0x0001_0000, .ecx = 0, .edx = 0 }, // AVX512F.
    };
    const coffee_lake = [_]kvm.CpuidEntry2{
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0x0000_0020, .ecx = 0, .edx = 0 }, // AVX2 only.
    };
    const granite_rapids = [_]kvm.CpuidEntry2{
        .{ .function = 7, .index = 0, .flags = 1, .eax = 0, .ebx = 0x0001_0020, .ecx = 0, .edx = 0 },
    };
    const missing = missing_feature(&skylake, &coffee_lake).?;
    try std.testing.expectEqual(@as(u32, 7), missing.function);
    try std.testing.expectEqualStrings("ebx", missing.register);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), missing.bits);
    try std.testing.expectEqual(@as(?Missing, null), missing_feature(&skylake, &granite_rapids));
}

test "an MSR is pinned only when the table makes it visible" {
    const vmx_on = [_]kvm.CpuidEntry2{.{ .function = 1, .index = 0, .flags = 0, .eax = 0x50654, .ebx = 0, .ecx = 0x36fa3223, .edx = 0 }};
    const vmx_off = [_]kvm.CpuidEntry2{.{ .function = 1, .index = 0, .flags = 0, .eax = 0x50654, .ebx = 0, .ecx = 0x36fa3203, .edx = 0 }};
    try std.testing.expect(msr_gated_on(&vmx_on, 0x480));
    try std.testing.expect(!msr_gated_on(&vmx_off, 0x480));
    try std.testing.expect(msr_gated_on(&vmx_off, arch_capabilities));
    try std.testing.expect(!msr_gated_on(&vmx_on, core_capabilities));
}

/// determinismo VM v1: one guest CPU every host presents, so that a run replays on any Xeon
/// Scalable (Skylake to Granite Rapids), its spec Antithesis's published "Antithesis VM v1"
/// (antithesis.com/docs/configuration/cpuid.md): GenuineIntel family 6 model 85 stepping 7, cpuid
/// level 22, AVX-512 F and CD only (glibc's EVEX variants, the JVM and simdjson then take their
/// AVX2 paths, the same everywhere), no MPX, TSX, VMX, RDRAND, RDSEED, RDTSCP, no speculation
/// control bits (so ARCH_CAPABILITIES is never read), fixed caches and topology. Applied after
/// make_deterministic, so a bit is kept only where VM v1 lists it and this host's KVM gives it
/// (VM v1's dtes64, ds_cpl, sdbg, xtpr, dca and RDT KVM does not virtualize: left out, a guest
/// must not touch MSRs that are not there); a host lacking one of the rest replays differently,
/// which `--cpuid` coverage checks catch when a table is carried. xsaveopt stays hidden (its
/// XINUSE leak, make_deterministic).
pub fn vm_v1(entries: []kvm.CpuidEntry2, count: *u32) void {
    var kept: u32 = 0;
    for (entries[0..count.*]) |entry| {
        const basic = entry.function < 0x4000_0000;
        if (basic and entry.function > vm_v1_level) continue; // Leaves past level 22.
        if (entry.function == 2 or entry.function == 4) continue; // Replaced below.
        if (entry.function >= 0x8000_0002 and entry.function <= 0x8000_0004) continue; // Brand.
        if (entry.function == 0x8000_0006) continue; // Replaced below.
        var kept_entry = entry;
        vm_v1_filter(&kept_entry);
        entries[kept] = kept_entry;
        kept += 1;
    }
    for (vm_v1_fixed) |fixed| {
        assert(kept < entries.len);
        entries[kept] = fixed;
        kept += 1;
    }
    count.* = kept;
}

const vm_v1_level: u32 = 0x16;
const vm_v1_signature: u32 = 0x0005_0657; // Family 6, model 85, stepping 7.

fn vm_v1_filter(entry: *kvm.CpuidEntry2) void {
    switch (entry.function) {
        0 => entry.eax = vm_v1_level,
        1 => {
            entry.eax = vm_v1_signature;
            // sse3 pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 movbe popcnt aes xsave osxsave avx
            // f16c, and hypervisor (31).
            entry.ecx &= bit(0) | bit(1) | bit(9) | bit(12) | bit(13) | bit(17) | bit(19) | bit(20) |
                bit(22) | bit(23) | bit(25) | bit(26) | bit(27) | bit(28) | bit(29);
            entry.ecx |= bit(31);
            // fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx
            // fxsr sse sse2 ss ht pbe.
            entry.edx &= bit(0) | bit(1) | bit(2) | bit(3) | bit(4) | bit(5) | bit(6) | bit(7) | bit(8) |
                bit(9) | bit(11) | bit(12) | bit(13) | bit(14) | bit(15) | bit(16) | bit(17) | bit(19) |
                bit(23) | bit(24) | bit(25) | bit(26) | bit(27) | bit(28) | bit(31);
        },
        7 => if (entry.index == 0) {
            entry.eax = 0; // No subleaf 1.
            // fsgsbase bmi1 avx2 bmi2 erms invpcid avx512f avx512cd.
            entry.ebx &= bit(0) | bit(3) | bit(5) | bit(8) | bit(9) | bit(10) | bit(16) | bit(28);
            entry.ecx = 0;
            entry.edx = 0; // No speculation control: IBRS, STIBP, SSBD, MD_CLEAR, ARCH_CAPABILITIES.
        } else {
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx = 0;
            entry.edx = 0;
        },
        0xd => if (entry.index == 0) {
            entry.eax &= bit(0) | bit(1) | bit(2) | bit(5) | bit(6) | bit(7); // x87 SSE AVX, AVX-512's.
            entry.edx = 0;
        },
        0x8000_0001 => {
            entry.ecx &= bit(0) | bit(5) | bit(8); // lahf_lm abm 3dnowprefetch
            entry.edx &= bit(11) | bit(20) | bit(26) | bit(29); // syscall nx pdpe1gb lm
        },
        0x8000_0008 => {
            entry.eax = (entry.eax & ~@as(u32, 0xffff)) | (48 << 8) | 46; // 46 physical, 48 virtual.
        },
        else => {},
    }
}

/// VM v1's fixed leaves: caches as one core of a Cascade Lake (32 KiB L1s, 1 MiB L2, 33 MiB L3:
/// glibc's memcpy thresholds come from them), leaf 2 pointing to leaf 4, its brand.
const vm_v1_fixed = [_]kvm.CpuidEntry2{
    .{ .function = 2, .index = 0, .flags = 0, .eax = 0x0000_ff01, .ebx = 0, .ecx = 0, .edx = 0 },
    cache_leaf(0, 1, 1, 8, 32 * 1024), // L1 data
    cache_leaf(1, 2, 1, 8, 32 * 1024), // L1 instruction
    cache_leaf(2, 3, 2, 16, 1024 * 1024), // L2
    cache_leaf(3, 3, 3, 11, 33 * 1024 * 1024), // L3
    .{ .function = 4, .index = 4, .flags = 1, .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 }, // No more.
    brand_leaf(0x8000_0002, 0),
    brand_leaf(0x8000_0003, 1),
    brand_leaf(0x8000_0004, 2),
    // L2 for software that reads AMD's leaf: 1 MiB, 16-way (code 8), 64-byte lines.
    .{ .function = 0x8000_0006, .index = 0, .flags = 0, .eax = 0, .ebx = 0, .ecx = (1024 << 16) | (8 << 12) | 64, .edx = 0 },
};

fn cache_leaf(index: u32, kind: u32, level: u32, ways: u32, size: u32) kvm.CpuidEntry2 {
    const line = 64;
    const sets = size / (ways * line);
    return .{
        .function = 4,
        .index = index,
        .flags = 1, // KVM_CPUID_FLAG_SIGNIFCANT_INDEX
        .eax = kind | (level << 5) | bit(8), // Self-initializing; one core, one thread.
        .ebx = ((ways - 1) << 22) | (line - 1),
        .ecx = sets - 1,
        .edx = 0,
    };
}

const vm_v1_brand_text = "determinismo VM v1";
const vm_v1_brand: [48]u8 = vm_v1_brand_text.* ++ @as([48 - vm_v1_brand_text.len]u8, @splat(0));
const vm_v1_brand_words: [12]u32 = @bitCast(vm_v1_brand);

fn brand_leaf(function: u32, part: usize) kvm.CpuidEntry2 {
    const words = vm_v1_brand_words;
    return .{ .function = function, .index = 0, .flags = 0, .eax = words[part * 4], .ebx = words[part * 4 + 1], .ecx = words[part * 4 + 2], .edx = words[part * 4 + 3] };
}

test vm_v1 {
    var entries: [32]kvm.CpuidEntry2 = undefined;
    const host = [_]kvm.CpuidEntry2{
        .{ .function = 0, .index = 0, .flags = 0, .eax = 0x20, .ebx = 0x756e6547, .ecx = 0x6c65746e, .edx = 0x49656e69 },
        .{ .function = 1, .index = 0, .flags = 0, .eax = 0xa06d1, .ebx = 0x10800, .ecx = 0xf6fa3203, .edx = 0x0f8bfbff },
        .{ .function = 7, .index = 0, .flags = 1, .eax = 2, .ebx = 0xf1bb27e9, .ecx = 0x1b005f4e, .edx = 0xbfc04400 },
        .{ .function = 0x1d, .index = 0, .flags = 0, .eax = 1, .ebx = 0, .ecx = 0, .edx = 0 }, // AMX: past level 22.
        .{ .function = 0xd, .index = 0, .flags = 1, .eax = 0x602e7, .ebx = 0xa88, .ecx = 0x2b00, .edx = 0 },
    };
    @memcpy(entries[0..host.len], &host);
    var count: u32 = host.len;
    vm_v1(&entries, &count);
    const leaf1 = find(entries[0..count], 1, 0).?;
    try std.testing.expectEqual(vm_v1_signature, leaf1.eax);
    try std.testing.expect(leaf1.ecx & bit(31) != 0); // hypervisor
    try std.testing.expect(leaf1.ecx & bit(30) == 0); // rdrand
    const leaf7 = find(entries[0..count], 7, 0).?;
    try std.testing.expectEqual(@as(u32, bit(16) | bit(28)), leaf7.ebx & (bit(16) | bit(17) | bit(28) | bit(30) | bit(31))); // F, CD only
    try std.testing.expectEqual(@as(u32, 0), leaf7.edx);
    try std.testing.expectEqual(@as(?kvm.CpuidEntry2, null), find(entries[0..count], 0x1d, 0));
    try std.testing.expectEqual(@as(u32, 0xe7), find(entries[0..count], 0xd, 0).?.eax);
    try std.testing.expectEqual(vm_v1_level, find(entries[0..count], 0, 0).?.eax);
    const l3 = find(entries[0..count], 4, 3).?;
    try std.testing.expectEqual(@as(u32, 33 * 1024 * 1024 / (11 * 64) - 1), l3.ecx);
    var brand: [48]u8 = undefined;
    for (0..3) |part| {
        const leaf = find(entries[0..count], 0x8000_0002 + @as(u32, @intCast(part)), 0).?;
        @memcpy(brand[part * 16 ..][0..16], std.mem.asBytes(&[4]u32{ leaf.eax, leaf.ebx, leaf.ecx, leaf.edx }));
    }
    try std.testing.expectEqualStrings("determinismo VM v1", std.mem.sliceTo(&brand, 0));
}
