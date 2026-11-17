// SPDX-License-Identifier: MIT
//! The built-in crash and exit properties' names, as det-init and det-core judge them: one
//! property a process (a known one counted, not failed). The known ones' are the schema's, which
//! the host's report reads too.
const schema = @import("determinismo").schema;
pub const crash_prefix = "no process crashes: ";
/// An OOM kill: judged as the node's sampler sees it (nodes.zig's samples_loop, its cgroup's
/// memory.events) and at the timeline's end with the kernel's report (init.zig).
pub const oom_property = "the kernel kills no process for lack of memory";
pub const known_crash_prefix = schema.known_crash_prefix;
pub const known_exit_prefix = schema.known_exit_prefix;
pub const known_panic_prefix = schema.known_panic_prefix;
