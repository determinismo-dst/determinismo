// SPDX-License-Identifier: MIT
//! An Intel MultiProcessor table (MP spec 1.4): how a guest booted with `acpi=off` learns of its
//! CPUs and its I/O APIC. Only the fast VM (`run --vcpus N`, docs/DEVELOPING.md) writes one:
//! a deterministic machine has none, so its kernel sees one CPU and the 8259 PIC, as always.
//!
//! The floating pointer goes where Linux looks for it, the last KiB of base memory (639 KiB, not
//! RAM in boot.zig's e820 map), the configuration table right after it: the CPUs (APIC ids 0 to
//! N-1, the first the bootstrap one), one ISA bus, the I/O APIC (id N) with ISA IRQs 0 to 15 on
//! its pins of the same number, and the local interrupts (ExtINT on the BSP's LINT0, NMI on
//! every LINT1), as Firecracker's mptable.
const std = @import("std");
const assert = std.debug.assert;

pub const address = 0x9fc00;
/// What fits below 640 KiB with the floating pointer and the fixed entries.
pub const cpus_max = 32;
pub const ioapic_address = 0xfec00000;
const lapic_address = 0xfee00000;
const irqs_isa = 16;

const header_size = 44;
const processor_size = 20;
const entry_size = 8;

pub fn size(cpus: u32) usize {
    return 16 + header_size + cpus * processor_size + entry_size * (2 + irqs_isa + 2);
}

comptime {
    assert(address + size(cpus_max) <= 0xa0000);
}

/// Writes the table for `cpus` CPUs into `memory` (guest-physical from 0).
pub fn write(memory: []u8, cpus: u32) void {
    assert(cpus >= 1 and cpus <= cpus_max);
    assert(memory.len >= address + size(cpus));
    const table = memory[address..][0..size(cpus)];
    @memset(table, 0);
    const config_address: u32 = address + 16;

    // The floating pointer.
    const floating = table[0..16];
    @memcpy(floating[0..4], "_MP_");
    std.mem.writeInt(u32, floating[4..8], config_address, .little);
    floating[8] = 1; // Length, in 16-byte units.
    floating[9] = 4; // Spec revision 1.4.
    floating[10] = checksum(floating);

    // The configuration table: its header, then the entries.
    const config = table[16..];
    var at: usize = header_size;
    var entries: u16 = 0;
    for (0..cpus) |cpu| {
        const entry = config[at..][0..processor_size];
        entry[0] = 0; // Processor.
        entry[1] = @intCast(cpu); // Local APIC id.
        entry[2] = 0x14; // Local APIC version.
        entry[3] = if (cpu == 0) 0b11 else 0b01; // Enabled, bootstrap.
        std.mem.writeInt(u32, entry[4..8], 0x600, .little); // Family 6.
        std.mem.writeInt(u32, entry[8..12], 0x201, .little); // FPU, APIC.
        at += processor_size;
        entries += 1;
    }
    {
        const entry = config[at..][0..entry_size];
        entry[0] = 1; // Bus.
        entry[1] = 0;
        @memcpy(entry[2..8], "ISA   ");
        at += entry_size;
        entries += 1;
    }
    const ioapic_id: u8 = @intCast(cpus);
    {
        const entry = config[at..][0..entry_size];
        entry[0] = 2; // I/O APIC.
        entry[1] = ioapic_id;
        entry[2] = 0x11; // Version.
        entry[3] = 1; // Enabled.
        std.mem.writeInt(u32, entry[4..8], ioapic_address, .little);
        at += entry_size;
        entries += 1;
    }
    for (0..irqs_isa) |irq| {
        const entry = config[at..][0..entry_size];
        entry[0] = 3; // I/O interrupt.
        entry[1] = 0; // INT.
        // Flags 0: the bus's own polarity and trigger.
        entry[4] = 0; // Source bus.
        entry[5] = @intCast(irq);
        entry[6] = ioapic_id;
        entry[7] = @intCast(irq); // Its pin.
        at += entry_size;
        entries += 1;
    }
    for ([_][2]u8{ .{ 3, 0 }, .{ 1, 0xff } }, 0..) |local, lint| {
        const entry = config[at..][0..entry_size];
        entry[0] = 4; // Local interrupt.
        entry[1] = local[0]; // ExtINT, then NMI.
        entry[4] = 0;
        entry[5] = 0;
        entry[6] = local[1]; // The BSP, then every CPU.
        entry[7] = @intCast(lint);
        at += entry_size;
        entries += 1;
    }
    assert(16 + at == table.len);
    const header = config[0..header_size];
    @memcpy(header[0..4], "PCMP");
    std.mem.writeInt(u16, header[4..6], @intCast(at), .little);
    header[6] = 4;
    @memcpy(header[8..16], "DETERMIN");
    @memcpy(header[16..28], "FASTVM      ");
    std.mem.writeInt(u16, header[34..36], entries, .little);
    std.mem.writeInt(u32, header[36..40], lapic_address, .little);
    header[7] = checksum(config[0..at]);
}

/// The byte that makes `bytes` (with it still 0) sum to 0 mod 256.
fn checksum(bytes: []const u8) u8 {
    return 0 -% sum(bytes);
}

fn sum(bytes: []const u8) u8 {
    var total: u8 = 0;
    for (bytes) |byte| total +%= byte;
    return total;
}

test "the table Linux reads: checksums, counts, ids" {
    var memory: [0xa0000]u8 = undefined;
    for ([_]u32{ 1, 2, 6, cpus_max }) |cpus| {
        @memset(&memory, 0xaa);
        write(&memory, cpus);
        const floating = memory[address..][0..16];
        try std.testing.expectEqualStrings("_MP_", floating[0..4]);
        try std.testing.expectEqual(@as(u8, 0), sum(floating));
        const config_address = std.mem.readInt(u32, floating[4..8], .little);
        try std.testing.expectEqual(@as(u32, address + 16), config_address);
        const length = std.mem.readInt(u16, memory[config_address + 4 ..][0..2], .little);
        const config = memory[config_address..][0..length];
        try std.testing.expectEqualStrings("PCMP", config[0..4]);
        try std.testing.expectEqual(@as(u8, 0), sum(config));
        try std.testing.expectEqual(size(cpus), 16 + length);
        const entries = std.mem.readInt(u16, config[34..36], .little);
        try std.testing.expectEqual(@as(u16, @intCast(cpus + 2 + irqs_isa + 2)), entries);
        // The CPUs: ids in order, only the first the bootstrap one.
        for (0..cpus) |cpu| {
            const entry = config[header_size + cpu * processor_size ..];
            try std.testing.expectEqual(@as(u8, 0), entry[0]);
            try std.testing.expectEqual(@as(u8, @intCast(cpu)), entry[1]);
            try std.testing.expectEqual(cpu == 0, entry[3] & 0b10 != 0);
        }
        // The I/O APIC after the bus, with the id after the CPUs'.
        const ioapic = config[header_size + cpus * processor_size + entry_size ..];
        try std.testing.expectEqual(@as(u8, 2), ioapic[0]);
        try std.testing.expectEqual(@as(u8, @intCast(cpus)), ioapic[1]);
        try std.testing.expectEqual(@as(u32, ioapic_address), std.mem.readInt(u32, ioapic[4..8], .little));
        // Nothing written past the table.
        try std.testing.expectEqual(@as(u8, 0xaa), memory[address + size(cpus)]);
    }
}
