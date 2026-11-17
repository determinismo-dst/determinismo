//! What the host's VMM and the guest's SDK both read of the guest-host protocol: the core
//! (src/core) imports this module and nothing else of the SDK, so a run's pin (build.zig's
//! core_id) moves with these and not with the SDK's other files. The SDK re-exports them.

/// An egress or ingress answer's status: the VMM writes it, the guest's SDK reads it.
pub const EgressStatus = enum(u32) {
    /// Refused: not allowed (explore's --egress), unreachable, or no such connection here.
    refused = 0,
    ok = 1,
    /// The server closed its side: no more bytes.
    end = 2,
    /// Unknown to this machine's VM: opened before a branch point or a restore, the socket
    /// another process's. The guest's client sees its connection reset.
    reset = 3,
};

/// A recv's most: the VMM's buffer for an answer, the guest's for reading it.
pub const egress_recv_max = 16 << 10;
