// SPDX-License-Identifier: MIT
//! The core: what decides a timeline's execution given its inputs (its start snapshot, seed,
//! tape and options), and nothing else. The VMM and its devices, the snapshot and its layout,
//! the tape's semantics, the events recorded and hashed, the condition language a replay
//! re-evaluates, the snapshots written during replays, which hosts a guest may reach. A run pins
//! it (PLAN: a run pins its core, not its whole explorer); the explorer reaches in only through
//! the hooks the core declares (VM.Advisor, VM.EndChecks, VM.ServeCall, Saver.unpin), and the
//! core imports nothing of the explorer's: its own module, a stray import a build error.
const std = @import("std");

pub const boot = @import("boot.zig");
pub const condition = @import("condition.zig");
pub const cpuid = @import("cpuid.zig");
pub const decisions = @import("decisions.zig");
pub const egress_allow = @import("egress_allow.zig");
pub const events = @import("events.zig");
pub const guest_memory = @import("guest_memory.zig");
pub const kvm = @import("kvm.zig");
pub const mptable = @import("mptable.zig");
pub const node = @import("node.zig");
pub const pit = @import("pit.zig");
pub const regex = @import("regex.zig");
pub const replay_snapshots = @import("replay_snapshots.zig");
pub const rtc = @import("rtc.zig");
pub const saver = @import("saver.zig");
pub const serial = @import("serial.zig");
pub const snapshot = @import("snapshot.zig");
pub const tape = @import("tape.zig");
pub const virtio_block = @import("virtio_block.zig");
pub const vm = @import("vm.zig");

test {
    std.testing.refAllDecls(@This());
}
