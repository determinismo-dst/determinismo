// SPDX-License-Identifier: MIT
//! One single-vCPU KVM virtual machine: memfd-backed RAM, legacy devices and the run loop.
//!
//! In deterministic mode (ARCHITECTURE.md §4) guest time is a function of retired guest branches:
//! the patched KVM returns tsc = base + branches * tsc_per_branch for RDTSC and stops the vCPU at
//! exact branch counts. The VMM owns the only timer (the PIT), fires it at the branch count where
//! its deadline falls, and skips idle time when the guest halts.
const std = @import("std");
const guest_memory = @import("guest_memory.zig");
const GuestMemory = guest_memory.GuestMemory;
const assert = std.debug.assert;
const linux = std.os.linux;
const kvm = @import("kvm.zig");
const boot = @import("boot.zig");
const cpuid = @import("cpuid.zig");
const Serial = @import("serial.zig");
const RTC = @import("rtc.zig");
const PIT = @import("pit.zig");
const VirtioBlock = @import("virtio_block.zig");
const Decisions = @import("decisions.zig");
const Events = @import("events.zig");
const query = @import("condition.zig");
const egress_rules = @import("egress_allow.zig");
const Snapshot = @import("snapshot.zig");
const tape = @import("tape.zig");
const mptable = @import("mptable.zig");
/// The guest-host protocol's shared part: the core's only import of the SDK (build.zig core_id).
const protocol = @import("protocol");

kvm_fd: linux.fd_t,
vm_fd: linux.fd_t,
vcpu_fd: linux.fd_t,
memory_fd: linux.fd_t,
/// False for branches: their memory_fd belongs to the snapshot they map copy-on-write.
memory_fd_owned: bool,
/// A branch of a tree's root, or of a node over it: memory_fd is the root's, and the snapshots it
/// takes hold only what differs from it (Snapshot.base_fd).
memory_over_root: bool = false,
memory: []align(std.heap.page_size_min) u8,
/// A replay's watchpoint (Options.watch), its pages read-only in KVM, and the writes logged.
watch: ?Watch = null,
watch_pages: ?struct { first: u64, last: u64 } = null,
watch_hits: u64 = 0,
run: *kvm.Run,
run_size: u64,
/// The fast VM's other vCPUs (Options.vcpus > 1, never deterministic: docs/DEVELOPING.md),
/// each run by a thread of its own; their exits handled one at a time under `exits_lock`, so
/// the devices see one exit at a time as in a one-vCPU machine.
aps: [mptable.cpus_max - 1]Ap = undefined,
ap_count: u32 = 0,
exits_lock: FutexLock = .{},
/// A fast VM (vcpus > 1), and the CPUID table its first vCPU took, its others' base.
fast: bool = false,
cpuid_fast: kvm.Cpuid2(cpuid_entries_max) = undefined,
/// The fast VM's clock: the guest's TSC (at the deterministic rate) at a host TSC, and the
/// host's rate: the VMM's PIT reads it as a deterministic machine's reads virtual time.
fast_guest_tsc0: u64 = 0,
fast_host_tsc0: u64 = 0,
fast_host_khz: u64 = 0,
/// The rate a fast vCPU's TSC really runs at: the deterministic rate (cpuid.tsc_hz) where the
/// host scales TSCs, the host's own where it cannot (phoenixNAP's E-2276G: a PIT clock at the
/// deterministic rate ran 5.5% ahead of the guest's TSC, and each snapshot's timer was that
/// share of the machine's age in the future: every timeline from it began with seconds idle).
fast_guest_khz: u64 = 0,
/// A machine from a fast VM's snapshot held: its scenario not started (Options.hold_scenario).
hold_scenario: bool = false,
/// Where the fast VM's snapshots go (Options.dev_directory), and how many it wrote.
dev_directory: ?[]const u8 = null,
dev_saved: u32 = 0,
/// The pages' hashes as of the last explore-here save: each next one writes only the pages that
/// changed since, its base the one before (a chain disk_load follows).
dev_hashes: ?Snapshot.PageHashes = null,
/// The dev control's action being given to the guest's agent (dev_action_give).
dev_action: [step_size_max]u8 = undefined,
/// A timeline's command line (its det.* settings), given to a guest restored from a fast VM's
/// snapshot as the action `det:cmdline <line>` with its explore-here answer: that guest's
/// /proc/cmdline is the fast VM's (sdk.timeline_cmdline_path).
timeline_cmdline: []const u8 = "",
timeline_action: [step_size_max]u8 = undefined,
/// Bumped at each PIT write: the fast VM's timer thread waits on it for a new deadline.
pit_generation: std.atomic.Value(u32) = .init(0),
/// The first vCPU's thread (pthread) and its run, kicked out of KVM_RUN when another vCPU ends
/// the machine (vm.run is another's while that one handles an exit).
bsp_thread: ?std.c.pthread_t = null,
bsp_run: ?*kvm.Run = null,
/// A fast VM's end, said by whichever vCPU met it first; the others stop at once.
fast_outcome: ?Outcome = null,
fast_done: std.atomic.Value(bool) = .init(false),
/// Set once a snapshot shares this VM's memory: it must never run again.
frozen: bool,
/// Branches restored from a snapshot count branches from zero; this makes moments absolute.
branches_offset: u64,
/// Stop the run when the guest signals setup_complete (to snapshot there).
stop_at_setup_complete: bool,
/// A timeline's ceiling of virtual time (TSC): past it, at the next timer interrupt (an exact
/// point, the same in a replay), the run ends as hung.
vtime_limit_tsc: ?u64,
/// The timer interrupt past the ceiling fired.
over_limit: bool,
/// Multiverse debugging: the moment (virtual TSC) to stop at, the command to run there, and
/// where that stands. Without a command the run ends at the moment.
moment_tsc: ?u64,
/// det:step's branch count to reach: its clock target re-armed while short of it.
step_until_branches: ?u64 = null,
/// det:break's hardware breakpoint (DR0: an instruction) and det:watch's (DR1: a write of 1, 2,
/// 4 or 8 bytes), each a guest virtual address in one address space or any, and whether
/// det:continue runs on to them.
breakpoint: ?struct { address: u64, cr3: ?u64 } = null,
watchpoint: ?struct { address: u64, size: u8, cr3: ?u64 } = null,
continuing: bool = false,
/// det:collect's window: every hit of the breakpoints said as it passes (no stop), counted, at
/// most collect_hits_max of them; null outside one.
collect: ?struct { hits: u32 = 0, dropped: u32 = 0 } = null,
moment_command: ?[]const u8,
moment_reached: bool,
/// Keep running after the command at the moment finished (instead of ending the run there).
moment_continue: bool,
/// The guest's agent holds the timeline already (det:hold, sent where its steps began): this
/// machine goes on from a snapshot taken after that (Options.moment_held).
moment_held: bool,
/// The agent's hold not sent yet: it goes just before the first step the agent acts on (a guest
/// command, an agent action). Until then the moment's steps only look and run the guest on, the
/// agent never woken, so a session's future is the recorded timeline's (a hold at the moment
/// ran the agent there: a session at 2.3 s of Turso's timeline panicked 12.3 us later than the
/// recording, 2026-11-18). The scenario's end meanwhile is a moment of its own (end_hit).
hold_owed: bool = false,
/// The scenario ended (det-init's scenario_end event) while a step ran the guest with no hold:
/// the step ends there, a moment, and the next step follows (the timeline held so by the VMM).
end_hit: bool = false,
/// The moment's commands began: a new timeline from there, which its tape does not describe
/// (steps after a command, `det:wait` and `det:until`, run it on).
moment_changed: bool = false,
fresh_seed: ?u64,
/// The moment can also be the first event matching a condition (`--until`, as Antithesis's
/// wait_until), the instant the guest emits it.
until: ?*const query.Condition,
until_hit: bool,
/// A det:ask's end, watched from before its sends: a reply done before its det:until is armed
/// (the relay faster than the agent's end) would be missed, and the step wait its timeout.
ask_until: ?*const query.Condition = null,
ask_until_hit: bool = false,
/// The strategy ended the timeline (its reply to an event): it stops at the next doorbell.
strategy_ended: bool = false,
/// Whether guest events are printed: from the moment until its command finishes.
moment_printing: bool,
/// What the guest agent receives on its next action request.
action_pending: ?[]const u8,
/// Interactive steps (explore's --exec-interactive): once the moment's commands are done, the
/// next step is read from here (a line each), the machine paused meanwhile, so a session is a
/// function of its steps and replays as their script. Its end releases the timeline.
steps_fd: ?linux.fd_t = null,
/// Live steps (--exec-live): the guest runs on between them, each taken from steps_fd as it
/// comes and run at a moment 1 ms of virtual time later (printed: "at moment vtime=..."), so a
/// live session replays as its steps at those moments. One at a time.
steps_live: bool = false,
/// A live session's input ended: it ends at the moment armed then (session_end there).
live_ending: bool = false,
/// The session's input ended: the run stops (.command_done), its timeline cut short; a live
/// one's 1 ms of virtual time on (live_ending), where its replay stops too.
/// What came after a person's last step is nobody's: going on to the scenario's end held the
/// machine (a paused scenario never ends; a live one, paced to the wall clock, for minutes).
session_over: bool = false,
/// Extending a timeline (explore --extend): the taped overrides this machine applies are
/// written to its own tape as they are (tape_extend_begin wrote the ones before it began), so
/// its tape holds what it was given, in order, and replays it alone.
tape_applied: bool = false,
/// The answer to the next fork index this machine is asked (sdk.fork): k in a fork's future k
/// (explore's --fork-index), else 0.
fork_index: u64 = 0,
/// Who clones this machine when its guest asks (sdk.fork): a session's explore saves it to disk
/// (saver.zig's fork mode), serve starts the futures from there. Null: nobody, the fork answered
/// 0 alone.
fork_hook: ?ForkHook = null,
/// Who saves this machine at a session's checkpoint (det:checkpoint): a session's explore, among
/// its run's replay snapshots (saver.zig's checkpoint mode, --checkpoint-snapshots), where a
/// session opened on the timeline at or after the checkpoint starts from. Null: the step's event
/// alone (a replay of the timeline, a run whose replays never start from a snapshot).
checkpoint_hook: ?CheckpointHook = null,
/// A det:checkpoint asked, its stop (1 ns on) not reached yet: its name.
checkpoint_asked: ?[]const u8 = null,
/// The steps are the session's own (after det:extend), not the timeline's replayed ones on the
/// way to its moment: only the own ones' checkpoints are saved (the replayed ones were, or a
/// snapshot of the timeline before them is where the session started).
steps_own: bool = false,
/// The moment being arrived at is inside an idle skip (the guest halted): a checkpoint saved
/// there replays as a hold point in an idle stretch does (snapshot.zig's idle).
arrival_idle: bool = false,
/// serve, for the guest's sdk.serve (a session's machine: --serve-url); null elsewhere, where
/// the guest is told it is unavailable.
serve_url: ?[]const u8 = null,
/// How a guest's request to serve is sent (the explorer's: serve_call.call): an answer from
/// outside the guest, as a connection's bytes are, given to the core as a hook.
serve_call: ?ServeCall = null,
/// What each guest process announced and asked, until its next pull (keyed by its process id: a
/// program's processes share a name, and one's label or request went to another's pull; its
/// threads are one asker, an SDK's buffered lines written by another thread than the pull's).
pending: [pending_max]Pending = @splat(.{}),
pending_stamp: u64 = 0,
/// The thread of the pull being answered (its requests are read by the answers below).
pull_tid: u32 = 0,
/// Egress in a deterministic machine (sdk.egress, explore's --egress): the guest's request (its
/// event), its answer (status, reply), whether a replay answered it from the tape, and the
/// connections this process opened.
egress_reply: std.ArrayList(u8) = .empty,
egress_reply_at: usize = 0,
egress_status: u32 = 0,
egress_taped: bool = false,
/// explore's --egress: "host", "host:port", "*.domain" or "*" (egress_rules.allow_matches); none:
/// every connection refused.
egress_allow: []const []const u8 = &.{},
egress_io: ?std.Io = null,
egress_sockets: [egress_connections_max]EgressSocket = @splat(.{}),
/// Ingress into a deterministic machine (sdk.ingress, explore's --ingress): the guest's request,
/// its answer, whether a replay answered it from the tape; the listener ("host:port") the live
/// timeline's process opens at the guest's first accept, and the connections it took.
ingress_reply: std.ArrayList(u8) = .empty,
ingress_reply_at: usize = 0,
ingress_status: u32 = 0,
ingress_taped: bool = false,
/// Ingress answered live in a replay: a session extending the timeline listens from its moment
/// on (its recorded answers dropped). Otherwise a replay's ingress answers are its tape's.
ingress_answers_live: bool = false,
ingress_listen: ?[]const u8 = null,
ingress_listener: linux.fd_t = -1,
ingress_listener_pid: linux.pid_t = 0,
ingress_next: u32 = 1,
/// When a live timeline was first paced, in wall time and the machine's: it runs no faster than
/// the wall clock from there (live_pace).
pace_wall_base_ns: u64 = 0,
pace_vtime_base_ns: u64 = 0,
ingress_sockets: [egress_connections_max]EgressSocket = @splat(.{}),
/// serve's reply, given to the guest 64 bytes a decision.
serve_reply: std.ArrayList(u8) = .empty,
serve_reply_at: usize = 0,
serve_status: u32 = 0,
/// Whether the reply under way comes from the tape (its status pull did).
serve_taped: bool = false,
/// A live step taken and not done.
live_busy: bool = false,
/// When steps_fd is looked at next (wall clock): not at every exit.
live_poll_at_ns: u64 = 0,
live_line: std.ArrayList(u8) = .empty,
/// Room for a branch point's action (branch_action_make).
branch_action_buffer: [64]u8 = undefined,
/// The moment's commands after the one running: a moment command can be several, separated by
/// NUL bytes (which no argument can contain), run one after the other (`--exec-script`).
moment_commands_rest: []const u8,
/// The names of the labeled decisions pulled before the setup's end (a VM run with
/// stop_at_setup_complete): one value for every timeline of the run (explore_snapshot says them).
setup_draws: SetupDraws,
/// The event count at the last exec_done handled: later doorbells (with no event) keep exec_done
/// as the last event, and must not finish the next command.
exec_done_handled: u64,
/// The last guest event was a background command's (det-agent's det:background): its start ends
/// its step, its end ends none.
exec_background: bool = false,
/// A step of the moment's script that is the platform's, not the guest's, is under way
/// (`det:wait <ms>`, `det:until <ms> <condition>`: multiverse debugging's branch.wait and
/// wait_until): its end is a moment again (moment_arrive), and the next step follows.
stepping: bool = false,
/// The conditions of `det:until` steps.
step_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// What the armed branch-count target is for.
target_kind: Deadline.Kind,
/// An in-run snapshot point (main.zig's holders): virtual time (TSC) where the run pauses for
/// `hold` and goes on. It stops where a replay to that moment stops (an exact branch count,
/// or within an idle skip), and the guest cannot tell: the timeline is the same as without it.
hold_tsc: ?u64,
hold: ?*const Hold,
/// KVM's count of soft stops (DetState.soft_exits) at the last target exit: one more now says
/// this exit is the timer's soft stop too.
soft_exits_seen: u64 = 0,
/// Behaviors the hold's owner was told of (Hold.behaviors).
hold_behaviors: u32,
/// Restored from a hold point inside an idle skip (Options.from_hold): the skip goes on first.
idle_pending: bool,
/// The virtual time of the next checkpoint in the events (Events.checkpoint): where an execution
/// is at each second, so that a replay that parts from it is placed within a second even where
/// no event comes for long (run 164, timeline 159: 30 s without one).
checkpoint_next_ns: u64,
deterministic: bool,
builtin_properties: bool,
/// The test program's host checks (checks.zig), run on what a timeline recorded once it ended,
/// after its guest hash: the explorer's hook (they judge a timeline, they do not run it).
end_checks: ?EndChecks,
/// Where a failing check's input is kept (checks.Options.keep): set with the events file.
check_keep: ?[]const u8 = null,
tsc_per_branch: u32,
/// CPU modulation, in branches only (Options.cpu_modulation).
modulation: ?Modulation,
timer_slack_tsc: u64,
/// Where in its slack a timer lands at the earliest (Options.timer_delay_permille), in ticks.
timer_delay_tsc: u64,
serial: Serial,
rtc: RTC,
pit: PIT,
/// Read-only disks, one virtio-mmio slot each (see virtio_block.zig).
blocks: [disks_max]VirtioBlock,
block_count: u32,
/// Branch count at which KVM stops the vCPU for the PIT deadline (0: none).
target_branches: u64,
/// The clock's state at this exit, read once (DET_GET_STATE, an ioctl, read up to five times
/// an exit before): it changes only as the guest runs or the VMM adds time (DET_ADD_TSC,
/// DET_ENABLE), which clear it.
state_cached: ?kvm.DetState = null,
/// The explorer's slot for this timeline's virtual time (a page shared with it before the fork),
/// stored at most once per virtual second: its progress line and status.json say how far each
/// running timeline has got, not only how long it has run (a smoke's timelines at 50 minutes of
/// wall time showed nothing of their virtual time until they ended, 2026-11-06). The guest
/// never sees it.
progress: ?*u64 = null,
progress_next_ns: u64 = 0,
/// The armed soft stop (a clock reading, timer_arm), 0 for none.
soft_tsc: u64,
decisions: Decisions,
/// The moment of the timeline's last randomness pull. Past it the future is fixed: every timeline
/// branched there would be the same one, so the tree explorer branches before it. The pull's own
/// moment, not the latest event's then: a state event and the draw after it are microseconds
/// apart (the e2e state maze), and the event's moment was taken for the pull's, so no return
/// fell between them.
last_pull_ns: u64,
events: Events,
stats: Stats,
/// Optional text trace of every point where the VMM changes the guest's course: timer stops,
/// idle skips and guest requests, each with branch count and RIP. Diffing two traces finds the
/// first divergence of two runs.
trace_fd: ?linux.fd_t,
/// The faults the timeline went through (det-faults' fault events), one JSON line each: what
/// causality relates to its futures' failures.
faults_record_fd: ?linux.fd_t,
rdtsc_log_fd: ?linux.fd_t,
rdtsc_log_cap: u32,
itrace_fd: ?linux.fd_t,
itrace_at: u64,
/// Exploration hooks, attached by the caller between init and run (null when not exploring):
/// the plugin that may override decisions, the tape recording what it overrode, and a tape's
/// overrides when replaying one.
/// The explorer's advice on a live timeline's pulls (its strategy, its bandit): asked only
/// where nothing replays (a replay's tape has every answer), every answer taped.
advisor: ?Advisor = null,
/// A replay's labeled pulls as its tape answered them, and its events' moments: noted, never
/// answered (explore --draws-out: which pull drew each of a failure's last faults).
pull_note: ?PullNote = null,
tape_fd: ?linux.fd_t,
/// Overrides on this timeline's tape so far (tape_override), and whether it filled.
tape_written: u32 = 0,
/// The steps on the timeline's tape, and their bytes: a step past what a replay reads is refused.
tape_steps: u32 = 0,
tape_step_bytes: u64 = 0,
tape_full: bool = false,
/// The moment its tape was full (tape_override): a return past it makes a timeline no replay
/// reaches (its chain stops at the marker), so the tree returns only before it (CE53).
tape_full_ns: ?u64 = null,
overrides: ?*tape.Overrides,
/// The driver phase's length bucket the explorer chose from the run's novelty curve: the answer
/// to det-composer's `composer.drive_ms` decision, unless a replay or a strategy answered it.
drive_k: ?u8,
/// The last events emitted (their number, moment and start): a replay that diverges from its
/// tape prints them, to compare with its timeline's own (the run's events hold those) without
/// replaying again to keep its events. Host-side: never in a snapshot, never hashed.
recent: [recent_max]Recent,
recent_count: u64,

/// The guest's real-time clock at virtual time zero by default: 2026-01-01T00:00:00Z.
pub const epoch_seconds_default: u64 = 1767225600;

/// What the guest's clock counts unless a run says (its machine.json keeps the event it booted
/// with, so that its resumes and replays count the same): retired taken branches
/// (BR_INST_RETIRED.NEAR_TAKEN). Conditional ones alone (0x01c4, rr's, before 2026-11-02) let a
/// loop without a conditional branch stop time: a JIT's `while (true) {}` (Bun's vm.test.ts,
/// whose watchdog waits on a timer) froze its timelines (Bun suite runs 547 and 593).
pub const branch_event_default: u64 = 0x20c4;

/// A replay's watchpoint (debugging, on request: docs/PLAN.md's replay watchpoints): every guest
/// write to guest physical [address, address + size) logged with its moment, RIP and CR3.
pub const Watch = struct { address: u64, size: u64 };

pub const Options = struct {
    /// Its pages mapped read-only, so each write to them exits; the VMM logs it, applies it and
    /// resumes, before the guest's own exits' handling (no modulation, no timer due): a watched
    /// replay keeps the recorded history.
    watch: ?Watch = null,
    memory_size: u64,
    kernel: []const u8,
    initrd: ?[]const u8,
    cmdline: []const u8,
    /// Unix seconds the guest's real-time clock reads at virtual time zero.
    epoch_seconds: u64 = epoch_seconds_default,
    deterministic: bool,
    /// Raw PMU event counting the branches that are the guest's clock.
    branch_event: u64 = branch_event_default,
    /// The guest's CPUID table, another host's (cpuid.table_parse: `--cpuid`), instead of this
    /// host's own deterministic one: a run recorded elsewhere replays here only with the table
    /// it booted with. Refused when this host's KVM lacks a feature it sets.
    cpuid_table: ?[]const kvm.CpuidEntry2 = null,
    /// With `cpuid_table`: the pinned MSRs' values from the same host (cpuid.pinned_msrs).
    cpuid_msrs: []const kvm.MsrEntry = &.{},
    /// The guest's CPU without a table: the host's (deterministic) or determinismo VM v1, one
    /// CPU on every host (cpuid.vm_v1).
    guest_cpu: GuestCpu = .host,
    /// vCPUs: 1, or more for the fast VM (`run --vcpus`, never deterministic), whose MP table
    /// (mptable.zig) tells the guest of them.
    vcpus: u32 = 1,
    /// Where the fast VM writes the snapshots it explores from (`run --dev <dir>`).
    dev_directory: ?[]const u8 = null,
    /// From a fast VM's snapshot, its scenario not started (`explore --hold-scenario`): a CI
    /// shard's or a sandbox replay's machine, running its own commands.
    hold_scenario: bool = false,
    /// 8 TSC ticks per branch at 4 GHz: one branch is 2 ns of virtual time.
    tsc_per_branch: u32 = 8,
    /// Nonzero: the clock's low bits jitter read to read (kvm.DetConfig.jitter_seed), as CPU-jitter
    /// entropy sources need (Go's FIPS 140-3 mode panicked at start without: its health tests saw
    /// every sample alike). A run's own, in its machine.json; 0, the exact clock (runs before it).
    tsc_jitter_seed: u64 = 0,
    /// The seed kept (an input of the timeline's tape) but the exact clock read: a run recorded
    /// with a seed while the KVM module still ignored it (srv4's runs 1351 to 1371, before the
    /// jittering module was loaded on 2026-11-07) read the exact clock.
    tsc_jitter_exact: bool = false,
    /// Branches before a stop target where KVM starts single-stepping (must exceed PMI skid:
    /// up to 65 branches on srv3's W-2295 under YugabyteDB; at 64, one stop overshot, and its
    /// timeline was another).
    margin_branches: u32 = 128,
    /// How late a timer interrupt may be: it is delivered at the first RDTSC at or past its
    /// deadline (free), or exactly this much later (single-stepping) if the guest reads no
    /// clock meanwhile. Part of a timeline's inputs. A millisecond, as a loaded host delays
    /// timers: a busy YugabyteDB guest ran at 0.99x virtual time with it, 0.62x with 100 us
    /// (fewer interrupts, timers due together firing at once, fewer exact stops; srv3).
    timer_slack_ns: u64 = std.time.ns_per_ms,
    /// How far into its slack a timer's interrupt lands at the earliest, in thousandths of the
    /// slack: the soft stop at the first clock read past deadline + this (0, the default: past
    /// the deadline itself). Interrupts later than their deadline by up to the slack, as a loaded
    /// host delivers them: what a plugin's machine may choose (Strategy.machine). Part of a
    /// timeline's inputs when not 0.
    timer_delay_permille: u16 = 0,
    /// Root of all guest randomness: seeds the guest kernel's RNG at boot and answers every
    /// randomness pull from /dev/determinismo.
    seed: u64,
    /// Where to append the guest's events as JSON lines.
    events_fd: ?linux.fd_t,
    /// Where to append its fault events only (causality's futures: `--faults-record`).
    faults_record_fd: ?linux.fd_t = null,
    /// Scratch memory for parsing guest events, reserved once by the caller (see events.zig).
    events_parse_buffer: []u8,
    trace_fd: ?linux.fd_t = null,
    /// Debugging: where the (branch count, RIP) at each RDTSC exit goes when the VM ends.
    rdtsc_log_fd: ?linux.fd_t = null,
    rdtsc_log_cap: u32 = rdtsc_log_cap_default,
    /// Debugging: every instruction's (branch count, RIP) from the RDTSC exit numbered
    /// `itrace_at` to the next, single-stepped (where two runs part, which branch went another
    /// way), written here when the VM ends.
    itrace_fd: ?linux.fd_t = null,
    itrace_at: u64 = 0,
    stop_at_setup_complete: bool = false,
    /// Stop at this virtual time, and optionally run a command in the guest there.
    moment_vtime_ns: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// VM.progress: where this timeline's virtual time is kept for the explorer.
    progress: ?*u64 = null,
    /// After the command at the moment, run on to the end of the timeline.
    moment_continue: bool = false,
    /// From a snapshot of a timeline taken after its steps began: the guest's agent held there
    /// already, its det:hold not sent again (a second one is a guest action the timeline never
    /// had: a session resumed at a checkpoint parted from the same session replayed from boot).
    moment_held: bool = false,
    /// Interactive steps from this file descriptor once the moment's commands are done (VM
    /// field steps_fd).
    steps_fd: ?linux.fd_t = null,
    /// Steps taken while the guest runs on (VM field steps_live).
    steps_live: bool = false,
    /// A fork's future: its index (VM field fork_index).
    fork_index: u64 = 0,
    /// From the moment on, decisions from this seed and no tape: the branch's own future (the
    /// guest's agent reseeds the kernel's generator first: det:reseed).
    fresh_seed: ?u64 = null,
    /// The run begins at a branch point (init_from_snapshot of a node: a moment of another
    /// timeline): the guest agent hears of it before the guest runs again (det:branch), and the
    /// fault injector perturbs the branch at once (guest/runtime/faults.zig). Every run from a
    /// node has it, timelines and the replays that make nodes alike: the same machine either way.
    branch_signal: bool = false,
    /// Or the moment is the first event matching this condition.
    until: ?*const query.Condition = null,
    disks: []const Disk = &.{},
    /// The guest runs determinismo's runtime: check the built-in properties when a timeline ends.
    builtin_properties: bool = false,
    /// The test program's host checks (checks.zig: the explorer's hook), run on what each
    /// timeline recorded; and room for their inputs, reserved once.
    end_checks: ?EndChecks = null,
    check_buffer: []u8 = &.{},
    /// Antithesis's CPU modulation: branches run slower for stretches of virtual time, each
    /// stretch's speed a decision, so preemption lands at other points of the code.
    cpu_modulation: bool = false,
    /// How long CPU modulation keeps one speed, the shortest and the longest stretch (each drawn
    /// between them): explore's --cpu-modulation-stretch-us.
    modulation_stretch_ns: [2]u64 = modulation_stretch_default,
    /// Retroactive logging: output lines with one of these texts are not written to the events
    /// file (they still count: hash, behaviors, the logging limit); a replay writes them.
    retroactive: []const []const u8 = &.{},
    /// A timeline's ceiling of virtual time: a guest that never finishes (processes wedged, a
    /// command waiting forever) ends there as hung.
    vtime_limit_ns: ?u64 = null,
    /// The snapshot is a hold point (a holder's, holders.zig) of the timeline this run replays
    /// on: it goes on as the timeline did there. Inside an idle skip the guest stays halted and
    /// the skip goes on (resuming the guest would run its idle loop once more), and the CPU
    /// modulation keeps its speed and owed time. Nodes and branches start over instead.
    from_hold: ?Hold.Point = null,
};

/// The machine runs `slowdown_permille` thousandths slower than its base rate (each branch
/// takes that much more virtual time) until `change_tsc`, when the next speed is drawn. The extra
/// time is added at exits the guest's execution decides (I/O, stops, halts), never at a host
/// interrupt, so that the guest reads the same clock on every replay.
pub const Modulation = struct {
    slowdown_permille: u32 = 0,
    /// How long a stretch at one speed lasts: drawn between these (Options.modulation_stretch_ns).
    stretch_ns_min: u64 = modulation_stretch_default[0],
    stretch_ns_max: u64 = modulation_stretch_default[1],
    /// Branches whose extra time is added.
    branches: u64 = 0,
    /// Extra time not yet added, in thousandths of a tick.
    remainder: u64 = 0,
    change_tsc: u64 = 0,

    /// The extra time owed for the branches since the last exit, in thousandths of a tick.
    fn owed_milli(modulation: Modulation, branches: u64, tsc_per_branch: u32) u64 {
        assert(branches >= modulation.branches);
        return (branches - modulation.branches) * tsc_per_branch *
            modulation.slowdown_permille + modulation.remainder;
    }

    /// The same modulation, for a machine whose branch count starts over (a snapshot's).
    pub fn rebased(modulation: Modulation, branches: u64, tsc_per_branch: u32) Modulation {
        var moved = modulation;
        moved.remainder = modulation.owed_milli(branches, tsc_per_branch);
        moved.branches = 0;
        return moved;
    }
};

/// Bumped whenever virtual time under CPU modulation changes (a modulated timeline's inputs
/// hash it; determinism_abi covers every timeline). 2: owed time counts in timer targets, and
/// moments and hold points do not step the modulation. 3: a soft stop that ends a stretch is
/// the timer's, never a moment's or a hold point's (they arrived early there).
pub const modulation_version: u32 = 3;
const modulation_permille_max = 1000; // Twice as slow at most.
/// A stretch of one speed: between 10 and 200 ms of virtual time (Antithesis's scale).
pub const modulation_stretch_default = [2]u64{ 10 * std.time.ns_per_ms, 200 * std.time.ns_per_ms };

/// A read-only disk image, open for the whole process (branches share it).
pub const Disk = struct { fd: linux.fd_t, size: u64 };
/// The system's disk and a node's each (schema.nodes_max): the guest's vda to vdz.
pub const disks_max = 26;

/// The clock's jitter of an exploration given none (Options.tsc_jitter_seed): from its seed, never
/// 0 (the exact clock). serve's runs too: drawn at random, two runs of one seed began apart (the
/// archive A/B's seed 7 arms, 2026-11-07), when same-seed arms must share their first timelines.
pub fn jitter_from_seed(seed: u64) u64 {
    return std.hash.Wyhash.hash(0x6a6974746572, std.mem.asBytes(&seed)) | 1;
}

test "an exploration's jitter comes from its seed, never the exact clock" {
    try std.testing.expectEqual(jitter_from_seed(7), jitter_from_seed(7));
    try std.testing.expect(jitter_from_seed(7) != jitter_from_seed(8));
    for ([_]u64{ 0, 1, 7, std.math.maxInt(u64) }) |seed| try std.testing.expect(jitter_from_seed(seed) != 0);
}

pub const Outcome = union(enum) {
    shutdown, // A triple fault: how the guest reboots with reboot=t.
    setup_complete, // Only with Options.stop_at_setup_complete.
    moment_reached, // Only with Options.moment_vtime_ns and no command.
    hung, // Past Options.vtime_limit_ns without finishing.
    command_done, // Only with Options.moment_command: the command at the moment finished.
    strategy_ended, // The strategy ended it, at an event (its reply's `end`).
    debug_exit: u8,
    hlt,
    failed: []const u8,
};

pub const Stats = struct {
    exits: std.EnumArray(Kind, u64) = .initFill(0),
    io_ports: [65536]u32 = @splat(0),
    timer_fires: u64 = 0,
    /// Timer interrupts delivered at a port or MMIO exit (see timer_due).
    exit_timer_fires: u64 = 0,
    idle_skips: u64 = 0,
    idle_tsc: u64 = 0,

    pub const Kind = enum { io_serial, io_other, mmio, hlt, intr, det_target, other };
};

const VM = @This();

/// The determinism ABI: bumped whenever the virtual-time function or the semantics of exits
/// and stops change, so that timelines recorded under one are never replayed under another.
pub const determinism_abi: u32 = 1;

/// Kernel parameters the deterministic machine needs: the PIT is the only clock-event device, the
/// TSC (virtualized by KVM) the only clocksource, and the boot seed the RNG's only entropy. No
/// I/O delay: the dummy write to port 0x80 after each slow port access (the PIT's, the PIC's,
/// on every timer tick) only waits on real hardware, and here each was an exit to the VMM: a
/// quarter of a busy YugabyteDB guest's (75,000 in 6 s, srv3 2026-10-27). And a PIT count in
/// one 16-bit write, not two (the guest kernel's det_pit_word, guest/kernel/patches): one exit
/// per timer reprogram.
pub const cmdline_deterministic = "nolapic_timer hpet=disable clocksource=tsc tsc=reliable " ++
    "random.trust_bootloader=on random.trust_cpu=off io_delay=none det_pit_word=1";

/// QEMU's isa-debug-exit convention: a guest write of v to this port ends the run with status v.
pub const port_debug_exit: u16 = 0x501;
/// The guest module writes the physical address of a request page here.
pub const port_doorbell: u16 = 0x510;
const request_operation_emit: u32 = 1;
const request_operation_random: u32 = 2;
const request_operation_action: u32 = 3;
/// The guest module wakes its agent on this ISA interrupt when an action is pending.
const irq_action: u32 = 5;
const request_header_size = 16;
const page_size = 4096;
/// The most a step (a command at a moment) can be: the guest agent reads it from one page, after
/// the request's header. A longer one is refused, not cut (moment.sh's --put of a 10 KB file ran
/// as its first 4 KB, its quote unterminated, 2026-11-06): split it (moment.sh --put does).
pub const step_size_max = page_size - request_header_size;
/// Guest RAM, reserved lazily (a branch costs what it touches).
pub const memory_size_max: u64 = 32 << 30;
pub const cpuid_entries_max = 256;

/// A fresh machine that boots the kernel in `options`.
pub fn init(vm: *VM, options: *const Options) !void {
    try vm.init_machine(options);
    vm.watch = options.watch;
    try vm.init_memory_fresh(options.memory_size);
    try vm.init_vcpu(options.cpuid_table, options.cpuid_msrs, options.guest_cpu);
    try vm.init_boot(options);
    if (options.deterministic) try vm.det_enable(options, .{ .tsc_base = 0 });
    if (options.vcpus > 1) {
        mptable.write(vm.memory, options.vcpus);
        try vm.fast_clock_rate();
        try vm.init_fast(options.vcpus);
    }
    assert(!vm.frozen);
}

/// A fast VM going on from a snapshot (explore-here's: docs/DEVELOPING.md), at full speed: an
/// agent's attempt from a checkpoint, CI's setup restored. Its first vCPU the snapshot's, its
/// memory mapped copy-on-write, its others fresh: the guest's agent, in its explore-here when
/// the snapshot was taken, learns it is a fast VM (det.explore_here answers 0 here) and brings
/// them online, INIT and SIPI as at boot.
pub fn init_fast_from_snapshot(vm: *VM, options: *const Options, snapshot: *const Snapshot) !void {
    assert(options.vcpus > 1 and !options.deterministic);
    assert(options.memory_size == snapshot.memory_size);
    try vm.init_machine(options);
    try vm.init_memory_snapshot(snapshot);
    try vm.init_vcpu(options.cpuid_table, options.cpuid_msrs, options.guest_cpu);
    try vm.fast_clock_rate(); // Before the restore writes the TSC: at the rate it was read at.
    // The other vCPUs before the interrupt controllers' state, as at a fresh boot.
    try vm.fast_aps_create(options.vcpus);
    try snapshot.restore(vm);
    // Its clock goes on from the snapshot's: its PIT's deadline is in that clock.
    var tsc: kvm.Msrs(1) = .{ .count = 1, .entries = .{.{ .index = msr_tsc, .data = snapshot.tsc }} };
    if (try kvm.ioctl(vm.vcpu_fd, kvm.SET_MSRS, @intFromPtr(&tsc)) != 1) return error.TscUnwritable;
    vm.decisions = .{ .seed = options.seed, .pulls = snapshot.decisions.pulls };
    try vm.init_fast(options.vcpus);
    assert(!vm.frozen);
}

/// The first vCPU's TSC at the deterministic rate where the host scales TSCs, else at the
/// host's (the host's rate and the guest's kept for fast_guest_tsc).
fn fast_clock_rate(vm: *VM) !void {
    assert(vm.fast);
    vm.fast_host_khz = try kvm.ioctl(vm.vcpu_fd, kvm.GET_TSC_KHZ, 0);
    const scaled = (kvm.ioctl(vm.kvm_fd, kvm.CHECK_EXTENSION, kvm.CAP_TSC_CONTROL) catch 0) > 0;
    vm.fast_guest_khz = if (scaled) cpuid.tsc_hz / 1000 else vm.fast_host_khz;
    try vm.tsc_khz_set(vm.vcpu_fd);
}

/// The fast VM's other vCPUs, APIC ids 1 to vcpus-1, waiting for the bootstrap CPU's INIT and
/// SIPI (KVM's in-kernel LAPIC), and the MP table naming them all.
fn init_fast(vm: *VM, vcpus: u32) !void {
    assert(!vm.deterministic);
    if (vcpus > mptable.cpus_max) return error.TooManyVcpus;
    // Dev mode: the guest's events in <dev_directory>/events.jsonl as they come (an nREPL
    // relay's replies among them: nrepl-proxy.py --dev reads them).
    if (vm.dev_directory) |directory| {
        var path_buffer: [4096]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/events.jsonl", .{directory}, 0);
        const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(opened) != .SUCCESS) return error.DevEventsUnwritable;
        vm.events.log_fd = @intCast(opened);
    }
    var tsc: kvm.Msrs(1) = .{ .count = 1, .entries = .{.{ .index = msr_tsc, .data = 0 }} };
    vm.fast_host_tsc0 = host_rdtsc();
    if (try kvm.ioctl(vm.vcpu_fd, kvm.GET_MSRS, @intFromPtr(&tsc)) != 1) return error.TscUnreadable;
    vm.fast_guest_tsc0 = tsc.entries[0].data;
    if (vm.ap_count == 0) try vm.fast_aps_create(vcpus);
    assert(vm.ap_count == vcpus - 1);
}

/// The other vCPUs, APIC ids 1 to vcpus-1, waiting for INIT and SIPI.
fn fast_aps_create(vm: *VM, vcpus: u32) !void {
    assert(vm.ap_count == 0);
    if (vcpus > mptable.cpus_max) return error.TooManyVcpus;
    for (1..vcpus) |id| {
        const fd = try kvm.ioctl_fd(vm.vm_fd, kvm.CREATE_VCPU, id);
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const address = try syscall(linux.mmap(null, vm.run_size, protection, .{ .TYPE = .SHARED }, fd, 0));
        vm.aps[vm.ap_count] = .{ .fd = fd, .run = @ptrFromInt(address) };
        vm.ap_count += 1;
        try vm.cpuid_set_apic(fd, @intCast(id));
    }
    assert(vm.ap_count == vcpus - 1);
}

/// A fast vCPU's CPUID: the first vCPU's table (the deterministic one) with its own APIC id,
/// its TSC at the deterministic rate.
fn cpuid_set_apic(vm: *VM, fd: linux.fd_t, apic_id: u32) !void {
    var table = vm.cpuid_fast;
    for (table.entries[0..table.count]) |*entry| switch (entry.function) {
        1 => entry.ebx = (entry.ebx & 0x00ffffff) | (apic_id << 24),
        0xb, 0x1f => entry.edx = apic_id,
        else => {},
    };
    _ = try kvm.ioctl(fd, kvm.SET_CPUID2, @intFromPtr(&table));
    try arch_capabilities_portable_set(fd);
    try vm.tsc_khz_set(fd);
}

const msr_tsc = 0x10;

fn host_rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return @as(u64, high) << 32 | low;
}

/// The fast VM's guest TSC now: its rate the deterministic one, from the host's.
fn fast_guest_tsc(vm: *const VM) u64 {
    assert(vm.fast and vm.fast_host_khz > 0);
    const host = host_rdtsc() -% vm.fast_host_tsc0;
    const guest: u128 = @as(u128, host) * vm.fast_guest_khz / vm.fast_host_khz;
    return vm.fast_guest_tsc0 +% @as(u64, @intCast(guest));
}

/// The deterministic machine's TSC rate (cpuid.tsc_hz) on a fast vCPU where the host scales
/// TSCs: its guest's clock reads the same rate before and after a fork. Elsewhere the host's
/// rate is left (fast_guest_khz): the guest's time runs that much slower than real time in the
/// fast VM (its kernel takes the TSC for the deterministic rate), never against its own timers.
fn tsc_khz_set(vm: *const VM, fd: linux.fd_t) !void {
    assert(vm.fast_guest_khz > 0);
    if (vm.fast_guest_khz == vm.fast_host_khz and vm.fast_guest_khz != cpuid.tsc_hz / 1000) return;
    _ = kvm.ioctl(fd, kvm.SET_TSC_KHZ, vm.fast_guest_khz) catch return error.TscScalingUnsupported;
}

/// A branch: a machine that continues from `snapshot`, with its own decisions from now on.
pub fn init_from_snapshot(vm: *VM, options: *const Options, snapshot: *const Snapshot) !void {
    assert(options.deterministic);
    assert(options.memory_size == snapshot.memory_size);
    try vm.init_machine(options);
    vm.watch = options.watch;
    try vm.init_memory_snapshot(snapshot);
    try vm.init_vcpu(options.cpuid_table, options.cpuid_msrs, options.guest_cpu);
    try snapshot.restore(vm);
    vm.timeline_cmdline = options.cmdline;
    try vm.det_enable(options, .{ .tsc_base = snapshot.tsc });
    var xinuse = snapshot.xinuse;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_XINUSE, @intFromPtr(&xinuse));
    if (options.cpu_modulation) {
        vm.modulation = if (options.from_hold != null) snapshot.modulation.? else .{
            .stretch_ns_min = options.modulation_stretch_ns[0],
            .stretch_ns_max = options.modulation_stretch_ns[1],
        };
    }
    vm.events.log_fd = options.events_fd;
    vm.faults_record_fd = options.faults_record_fd;
    vm.events.retroactive = options.retroactive;
    vm.decisions = .{ .seed = options.seed, .pulls = snapshot.decisions.pulls };
    vm.last_pull_ns = 0;
    vm.idle_pending = if (options.from_hold) |point| point.idle else false;
    // A timeline's checkpoints from its own start, the first at its first timer: the same in its
    // replay, whatever this VM ran before (a holder goes on with its own timeline's).
    if (options.from_hold == null) vm.checkpoint_next_ns = 0;
    assert(vm.branches_offset == snapshot.branches);
    if (options.branch_signal) {
        assert(options.from_hold == null); // A holder continues its own timeline.
        vm.action_pending = vm.branch_action_make(snapshot);
        try vm.irq_pulse(irq_action);
    }
}

/// The agent's action at a branch point (guest/runtime/agent.zig): `det:branch`, and the node of
/// the newest behavior the snapshot reached (the one the tree returned for, just before its
/// moment), where the fault injector aims its first fault. From the snapshot's own state: a
/// replay that makes the node says the same.
const branch_action = "det:branch";

fn branch_action_make(vm: *VM, snapshot: *const Snapshot) []const u8 {
    const node = snapshot.events.branch_node();
    if (node.len == 0) return branch_action;
    return std.fmt.bufPrint(&vm.branch_action_buffer, branch_action ++ " {s}", .{node}) catch branch_action;
}

pub fn deinit(vm: *VM) void {
    vm.serial.flush();
    vm.rdtsc_log_write();
    _ = linux.munmap(@ptrCast(vm.run), vm.run_size);
    _ = linux.close(vm.vcpu_fd);
    for (vm.aps[0..vm.ap_count]) |ap| {
        _ = linux.munmap(@ptrCast(ap.run), vm.run_size);
        _ = linux.close(ap.fd);
    }
    _ = linux.munmap(vm.memory.ptr, vm.memory.len);
    // A snapshot keeps the memfd of the VM it froze, and branches never own theirs.
    if (vm.memory_fd_owned and !vm.frozen) _ = linux.close(vm.memory_fd);
    _ = linux.close(vm.vm_fd);
    _ = linux.close(vm.kvm_fd);
    vm.* = undefined;
}

fn init_machine(vm: *VM, options: *const Options) !void {
    assert(options.memory_size % page_size == 0);
    assert(options.tsc_per_branch > 0);
    vm.* = .{
        .progress = options.progress,
        .kvm_fd = try open_kvm(),
        .vm_fd = undefined,
        .vcpu_fd = undefined,
        .memory_fd = undefined,
        .memory_fd_owned = undefined,
        .memory = undefined,
        .run = undefined,
        .run_size = undefined,
        .frozen = false,
        .branches_offset = 0,
        .stop_at_setup_complete = options.stop_at_setup_complete,
        .vtime_limit_tsc = if (options.vtime_limit_ns) |ns| ns * tsc_per_ns else null,
        .over_limit = false,
        .moment_tsc = if (options.moment_vtime_ns) |ns| ns * tsc_per_ns else null,
        .moment_command = options.moment_command,
        .steps_fd = options.steps_fd,
        .steps_live = options.steps_live,
        .fork_index = options.fork_index,
        .moment_reached = false,
        .moment_continue = options.moment_continue,
        .moment_held = options.moment_held,
        .fresh_seed = options.fresh_seed,
        .until = options.until,
        .until_hit = false,
        .moment_printing = false,
        .action_pending = null,
        .moment_commands_rest = "",
        .setup_draws = .{},
        .exec_done_handled = 0,
        .target_kind = .timer,
        .hold_tsc = null,
        .hold = null,
        .hold_behaviors = 0,
        .idle_pending = false,
        .checkpoint_next_ns = checkpoint_interval_ns,
        .deterministic = options.deterministic,
        .fast = options.vcpus > 1,
        .dev_directory = options.dev_directory,
        .hold_scenario = options.hold_scenario,
        .builtin_properties = options.builtin_properties,
        .end_checks = options.end_checks,
        .tsc_per_branch = options.tsc_per_branch,
        .modulation = null,
        .timer_slack_tsc = options.timer_slack_ns * tsc_per_ns,
        .timer_delay_tsc = options.timer_slack_ns * tsc_per_ns * options.timer_delay_permille / 1000,
        .serial = .{},
        .rtc = .{ .epoch_seconds = options.epoch_seconds },
        .pit = .{ .tsc_hz = cpuid.tsc_hz },
        .blocks = undefined,
        .block_count = @intCast(options.disks.len),
        .target_branches = 0,
        .soft_tsc = 0,
        .decisions = .{ .seed = options.seed },
        .last_pull_ns = 0,
        .events = undefined,
        .stats = .{},
        .trace_fd = options.trace_fd,
        .faults_record_fd = options.faults_record_fd,
        .rdtsc_log_fd = options.rdtsc_log_fd,
        .rdtsc_log_cap = options.rdtsc_log_cap,
        .itrace_fd = options.itrace_fd,
        .itrace_at = options.itrace_at,
        .advisor = null,
        .pull_note = null,
        .tape_fd = null,
        .overrides = null,
        .drive_k = null,
        .recent = undefined,
        .recent_count = 0,
    };
    vm.events.init(options.events_parse_buffer, .{
        .log_fd = options.events_fd,
        .check_buffer = options.check_buffer,
    });
    vm.events.retroactive = options.retroactive;
    if (options.disks.len > disks_max) return error.TooManyDisks;
    for (options.disks, vm.blocks[0..options.disks.len]) |disk, *block| {
        block.init(disk.fd, disk.size);
    }
    const version = try kvm.ioctl(vm.kvm_fd, kvm.GET_API_VERSION, 0);
    if (version != kvm.api_version) return error.KVMVersion;
    vm.vm_fd = try kvm.ioctl_fd(vm.kvm_fd, kvm.CREATE_VM, 0);
    try vm.init_chipset();
}

fn init_vcpu(vm: *VM, cpuid_table: ?[]const kvm.CpuidEntry2, cpuid_msrs: []const kvm.MsrEntry, guest_cpu: GuestCpu) !void {
    vm.vcpu_fd = try kvm.ioctl_fd(vm.vm_fd, kvm.CREATE_VCPU, 0);
    vm.run_size = try kvm.ioctl(vm.kvm_fd, kvm.GET_VCPU_MMAP_SIZE, 0);
    assert(vm.run_size >= @sizeOf(kvm.Run));
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const run_address = try syscall(linux.mmap(null, vm.run_size, protection, .{
        .TYPE = .SHARED,
    }, vm.vcpu_fd, 0));
    vm.run = @ptrFromInt(run_address);
    // Not in forked children (holders.zig): the mapping keeps the vCPU, so its VM and its pinned
    // branch counter, alive after this process ends the machine. The counter is bound to this
    // process: once the hardware's counters are all taken by machines gone, a new machine's does
    // not count, and its timeline is no longer deterministic.
    _ = try syscall(linux.madvise(@ptrCast(vm.run), vm.run_size, linux.MADV.DONTFORK));
    try vm.init_cpuid(cpuid_table, cpuid_msrs, guest_cpu);
}

fn det_enable(vm: *VM, options: *const Options, start: struct { tsc_base: u64 }) !void {
    assert(vm.deterministic);
    var config = kvm.DetConfig{
        .event = options.branch_event,
        .tsc_base = start.tsc_base,
        .tsc_per_branch = options.tsc_per_branch,
        .margin_branches = options.margin_branches,
        .jitter_seed = if (options.tsc_jitter_exact) 0 else options.tsc_jitter_seed,
    };
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ENABLE, @intFromPtr(&config));
    vm.state_cached = null;
    assert((try vm.det_state()).tsc == start.tsc_base);
    vm.soft_exits_seen = (try vm.det_state()).soft_exits;
    try vm.rdtsc_log_enable();
}

fn init_chipset(vm: *VM) !void {
    assert(vm.vm_fd >= 0);
    _ = try kvm.ioctl(vm.vm_fd, kvm.SET_TSS_ADDR, 0xfffbd000);
    var identity_map_address: u64 = 0xfffbc000;
    _ = try kvm.ioctl(vm.vm_fd, kvm.SET_IDENTITY_MAP_ADDR, @intFromPtr(&identity_map_address));
    _ = try kvm.ioctl(vm.vm_fd, kvm.CREATE_IRQCHIP, 0);
    if (vm.deterministic or vm.fast) {
        // The VMM's PIT is the only timer: KVM's would run on host time. The fast VM's runs on
        // host time too, but is the VMM's, so that a fork carries it to a deterministic machine.
    } else {
        var pit_config = kvm.PitConfig{ .flags = kvm.pit_speaker_dummy };
        _ = try kvm.ioctl(vm.vm_fd, kvm.CREATE_PIT2, @intFromPtr(&pit_config));
    }
}

/// Guest RAM lives in a memfd so that snapshots can map it copy-on-write.
fn init_memory_fresh(vm: *VM, memory_size: u64) !void {
    assert(memory_size >= 64 << 20);
    assert(memory_size <= memory_size_max);
    vm.memory_fd = @intCast(try syscall(linux.memfd_create("guest-ram", 0)));
    vm.memory_fd_owned = true;
    _ = try syscall(linux.ftruncate(vm.memory_fd, @intCast(memory_size)));
    try vm.init_memory_map(.SHARED, memory_size);
}

/// A branch's memory: the snapshot's mapped copy-on-write, or the root's with the snapshot's
/// differences from it read in (Snapshot.overlay_apply).
fn init_memory_snapshot(vm: *VM, snapshot: *const Snapshot) !void {
    try vm.init_memory_private(snapshot.map_fd(), snapshot.memory_size);
    try snapshot.overlay_apply(vm.memory);
    vm.memory_over_root = snapshot.root or snapshot.base_fd >= 0;
}

/// A branch writes to private copies of the snapshot's pages, which stays untouched.
fn init_memory_private(vm: *VM, snapshot_memory_fd: linux.fd_t, memory_size: u64) !void {
    assert(snapshot_memory_fd >= 0);
    vm.memory_fd = snapshot_memory_fd;
    vm.memory_fd_owned = false;
    try vm.init_memory_map(.PRIVATE, memory_size);
}

fn init_memory_map(vm: *VM, sharing: linux.MAP_TYPE, memory_size: u64) !void {
    assert(memory_size % page_size == 0);
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const address = try syscall(linux.mmap(null, memory_size, protection, .{
        .TYPE = sharing,
        .NORESERVE = true,
    }, vm.memory_fd, 0));
    vm.memory = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(address))[0..memory_size];
    // DETERMINISMO_HUGEPAGES=1 (a trial, off by default): transparent huge pages asked for the
    // guest's memory. Each first write a timeline makes to a page is an EPT violation and, on a
    // branch's private mapping, a page copy: about 110,000 a second a VM for jank compiling C++
    // (phoenixNAP, 2026-11-12). A shared mapping's huge pages need the host's shmem_enabled at
    // advise; a private mapping's copies may stay 4 KB whatever the source's size (measured, not
    // assumed). Advice only: refused or ignored, the guest runs on 4 KB pages as before.
    if (std.c.getenv("DETERMINISMO_HUGEPAGES")) |value| {
        if (value[0] == '1') _ = linux.madvise(@ptrFromInt(address), memory_size, linux.MADV.HUGEPAGE);
    }
    // One mapping, two guest ranges: below the 32-bit hole, and from 4 GiB (GuestMemory).
    const guest = GuestMemory{ .bytes = vm.memory };
    var regions = [_]kvm.UserspaceMemoryRegion{
        .{
            .slot = 0,
            .flags = 0,
            .guest_phys_addr = 0,
            .memory_size = guest.low_size(),
            .userspace_addr = address,
        },
        .{
            .slot = 1,
            .flags = 0,
            .guest_phys_addr = guest_memory.high_start,
            .memory_size = guest.high_size(),
            .userspace_addr = address + guest.low_size(),
        },
    };
    if (vm.watch) |watch| return vm.init_memory_watched(&regions, watch);
    for (&regions) |*region| {
        if (region.memory_size == 0) continue;
        _ = try kvm.ioctl(vm.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(region));
    }
}

/// The two RAM regions with the watched pages carved out of the one holding them, read-only
/// (KVM_MEM_READONLY: a write exits as MMIO), the rest as before.
fn init_memory_watched(vm: *VM, regions: *[2]kvm.UserspaceMemoryRegion, watch: Watch) !void {
    assert(watch.size > 0);
    const first = watch.address / page_size * page_size;
    const last = (watch.address + watch.size + page_size - 1) / page_size * page_size;
    var slot: u32 = 0;
    var carved = false;
    for (regions) |region| {
        if (region.memory_size == 0) continue;
        const start = region.guest_phys_addr;
        const end = start + region.memory_size;
        if (first < start or last > end) {
            var whole = region;
            whole.slot = slot;
            slot += 1;
            _ = try kvm.ioctl(vm.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&whole));
            continue;
        }
        const parts = [_]struct { from: u64, to: u64, flags: u32 }{
            .{ .from = start, .to = first, .flags = 0 },
            .{ .from = first, .to = last, .flags = kvm.mem_readonly },
            .{ .from = last, .to = end, .flags = 0 },
        };
        for (parts) |part| {
            if (part.to == part.from) continue;
            const piece: kvm.UserspaceMemoryRegion = .{
                .slot = slot,
                .flags = part.flags,
                .guest_phys_addr = part.from,
                .memory_size = part.to - part.from,
                .userspace_addr = region.userspace_addr + (part.from - start),
            };
            slot += 1;
            _ = try kvm.ioctl(vm.vm_fd, kvm.SET_USER_MEMORY_REGION, @intFromPtr(&piece));
        }
        carved = true;
    }
    if (!carved) return error.WatchNotInRam;
    vm.watch_pages = .{ .first = first, .last = last };
}

/// A write to the watched pages (an MMIO exit there): applied to the guest's memory, and logged
/// when it touches the watched bytes, with its moment, the instruction (RIP) and the address
/// space (CR3). The timeline's own exit handling is skipped: the guest made no exit there.
fn watch_write(vm: *VM) !void {
    const mmio = &vm.run.exit.mmio;
    assert(mmio.is_write != 0 and mmio.len >= 1 and mmio.len <= 8);
    const guest = GuestMemory{ .bytes = vm.memory };
    const target = guest.range(mmio.phys_addr, mmio.len) orelse return error.WatchOutsideRam;
    const before_value = std.mem.readVarInt(u64, target, .little);
    @memcpy(target, mmio.data[0..mmio.len]);
    const watch = vm.watch.?;
    if (mmio.phys_addr + mmio.len <= watch.address or mmio.phys_addr >= watch.address + watch.size) return;
    vm.watch_hits += 1;
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    const now = try vm.moment();
    std.debug.print("[determinismo] watch: {{\"vtime_ns\":{d},\"branches\":{d},\"address\":\"0x{x}\",\"size\":{d}," ++
        "\"before\":\"0x{x}\",\"after\":\"0x{x}\",\"rip\":\"0x{x}\",\"cr3\":\"0x{x}\"}}\n", .{
        now.vtime_ns,   now.branches,
        mmio.phys_addr, mmio.len,
        before_value,   std.mem.readVarInt(u64, mmio.data[0..mmio.len], .little),
        regs.rip,       sregs.cr3,
    });
}

fn watched(vm: *const VM, address: u64) bool {
    const pages = vm.watch_pages orelse return false;
    return address >= pages.first and address < pages.last;
}

fn init_cpuid(vm: *VM, given: ?[]const kvm.CpuidEntry2, msrs: []const kvm.MsrEntry, guest_cpu: GuestCpu) !void {
    var cpuid_table: kvm.Cpuid2(cpuid_entries_max) = .{
        .count = cpuid_entries_max - 2, // Room for the leaves make_deterministic appends.
        .entries = undefined,
    };
    _ = try kvm.ioctl(vm.kvm_fd, kvm.GET_SUPPORTED_CPUID, @intFromPtr(&cpuid_table));
    assert(cpuid_table.count <= cpuid_entries_max - 2);
    if (given) |entries| {
        assert(vm.deterministic);
        if (entries.len > cpuid_entries_max) return error.CpuidTableTooLarge;
        if (cpuid.missing_feature(entries, cpuid_table.entries[0..cpuid_table.count])) |missing| {
            std.debug.print("error: this host lacks CPUID {x}.{x} {s} bits {x} of the given table\n", .{
                missing.function, missing.index, missing.register, missing.bits,
            });
            return error.CpuidNotSupported;
        }
        @memcpy(cpuid_table.entries[0..entries.len], entries);
        cpuid_table.count = @intCast(entries.len);
    } else if (vm.deterministic or vm.fast) {
        // The fast VM's too: forked into a deterministic machine, its guest finds the CPU it
        // started on (code that chose its instructions then: RDRAND hidden, AVX-512 kept).
        cpuid.make_deterministic(&cpuid_table.entries, &cpuid_table.count);
        if (guest_cpu == .vm_v1) cpuid.vm_v1(&cpuid_table.entries, &cpuid_table.count);
    }
    assert(cpuid_table.count <= cpuid_entries_max);
    if (vm.fast) vm.cpuid_fast = cpuid_table;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_CPUID2, @intFromPtr(&cpuid_table));
    if (given == null and (vm.deterministic or vm.fast)) try arch_capabilities_portable_set(vm.vcpu_fd);
    if (msrs.len == 0) return;
    assert(given != null);
    // The other host's values (KVM takes a host-initiated write that this host supports).
    var table: kvm.Msrs(cpuid.pinned_msrs.len) = .{ .count = @intCast(msrs.len), .entries = undefined };
    if (msrs.len > table.entries.len) return error.CpuidTableTooLarge;
    @memcpy(table.entries[0..msrs.len], msrs);
    const set = try kvm.ioctl(vm.vcpu_fd, kvm.SET_MSRS, @intFromPtr(&table));
    if (set != msrs.len) {
        std.debug.print("error: this host refuses MSR {x} = {x} of the given table\n", .{ msrs[set].index, msrs[set].data });
        return error.CpuidNotSupported;
    }
}

/// A deterministic guest's IA32_ARCH_CAPABILITIES: its vCPU's, without RSBA (cpuid.zig).
fn arch_capabilities_portable_set(vcpu_fd: linux.fd_t) !void {
    var msr: kvm.Msrs(1) = .{ .count = 1, .entries = .{.{ .index = cpuid.arch_capabilities, .data = 0 }} };
    if (try kvm.ioctl(vcpu_fd, kvm.GET_MSRS, @intFromPtr(&msr)) != 1) return;
    const portable = cpuid.arch_capabilities_portable(msr.entries[0].data);
    if (portable == msr.entries[0].data) return;
    msr.entries[0].data = portable;
    if (try kvm.ioctl(vcpu_fd, kvm.SET_MSRS, @intFromPtr(&msr)) != 1) return error.ArchCapabilitiesRefused;
}

/// This host's deterministic guest CPUID table (what a VM here boots with): `determinismo
/// cpuid`'s, for another host to replay this one's runs.
pub const GuestCpu = enum { host, vm_v1 };

pub fn cpuid_table_host(entries: []kvm.CpuidEntry2, msrs: []kvm.MsrEntry, guest_cpu: GuestCpu) !struct { entries: u32, msrs: u32 } {
    assert(entries.len >= cpuid_entries_max);
    assert(msrs.len >= cpuid.pinned_msrs.len);
    const kvm_fd = linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(kvm_fd) != .SUCCESS) return error.KvmUnavailable;
    defer _ = linux.close(@intCast(kvm_fd));
    var cpuid_table: kvm.Cpuid2(cpuid_entries_max) = .{ .count = cpuid_entries_max - 2, .entries = undefined };
    _ = try kvm.ioctl(@intCast(kvm_fd), kvm.GET_SUPPORTED_CPUID, @intFromPtr(&cpuid_table));
    cpuid.make_deterministic(&cpuid_table.entries, &cpuid_table.count);
    if (guest_cpu == .vm_v1) cpuid.vm_v1(&cpuid_table.entries, &cpuid_table.count);
    @memcpy(entries[0..cpuid_table.count], cpuid_table.entries[0..cpuid_table.count]);
    // What a vCPU here reads with that table: KVM adjusts a vCPU's VMX capabilities to its
    // CPUID (secondary controls and entry/exit bits of features the table hides), so /dev/kvm's
    // system-wide values are not the guest's (a review from another session).
    const vm_fd = try kvm.ioctl_fd(@intCast(kvm_fd), kvm.CREATE_VM, 0);
    defer _ = linux.close(vm_fd);
    const vcpu_fd = try kvm.ioctl_fd(vm_fd, kvm.CREATE_VCPU, 0);
    defer _ = linux.close(vcpu_fd);
    _ = try kvm.ioctl(vcpu_fd, kvm.SET_CPUID2, @intFromPtr(&cpuid_table));
    try arch_capabilities_portable_set(vcpu_fd); // As a VM here boots.
    // Each alone (GET_MSRS stops at the first it cannot read), kept when the table makes it
    // visible to the guest.
    var count: u32 = 0;
    for (cpuid.pinned_msrs) |index| {
        if (!cpuid.msr_gated_on(cpuid_table.entries[0..cpuid_table.count], index)) continue;
        var one: kvm.Msrs(1) = .{ .count = 1, .entries = .{.{ .index = index, .data = 0 }} };
        if (try kvm.ioctl(vcpu_fd, kvm.GET_MSRS, @intFromPtr(&one)) != 1) continue;
        msrs[count] = one.entries[0];
        count += 1;
    }
    return .{ .entries = cpuid_table.count, .msrs = count };
}

fn init_boot(vm: *VM, options: *const Options) !void {
    var boot_options = boot.Options{
        .kernel = options.kernel,
        .initrd = options.initrd,
        .cmdline = options.cmdline,
        .rng_seed = undefined,
    };
    var prng: std.Random.DefaultPrng = .init(options.seed);
    prng.random().bytes(&boot_options.rng_seed);
    const entry = try boot.load(.{ .bytes = vm.memory }, &boot_options);
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    boot.long_mode_sregs(&sregs);
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_SREGS, @intFromPtr(&sregs));
    var regs = kvm.Regs{
        .rflags = 0x2,
        .rip = entry.rip,
        .rsi = entry.rsi,
        .rsp = boot.stack_top_address,
        .rbp = boot.stack_top_address,
    };
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_REGS, @intFromPtr(&regs));
}

/// The explorer's host checks of a timeline that ended (checks.zig's Hook): its recorded inputs
/// judged, after its guest hash; `keep` is where a failing one's input goes.
pub const EndChecks = struct {
    context: *const anyopaque,
    run: *const fn (context: *const anyopaque, events: *Events, end: Events.Moment, keep: ?[]const u8) anyerror!void,
};

/// Runs the VM until it powers off, reboots, fails or reaches a requested stop; then checks the
/// built-in properties of a timeline that ended (not of one stopped at setup or at a moment).
pub fn run_until_exit(vm: *VM) !Outcome {
    const outcome = if (vm.ap_count > 0) try vm.run_loop_fast() else try vm.run_loop();
    if (vm.builtin_properties and outcome != .setup_complete) {
        const cut_short = outcome == .moment_reached or outcome == .command_done or
            outcome == .strategy_ended;
        const end = try vm.moment();
        if (!cut_short) if (vm.end_checks) |hook| {
            var guest = vm.events.hash;
            vm.events.guest_hash = guest.final();
            try hook.run(hook.context, &vm.events, end, vm.check_keep);
        };
        try vm.events.finish(end, if (cut_short) .cut_short else .ended);
        if (!cut_short) vm.events.checks_keep(end, vm.events.announcements_log(end));
        vm.events.check_release();
    }
    return outcome;
}

/// The VM's event loop: it ends only when the guest powers off, reboots or fails.
fn run_loop(vm: *VM) !Outcome {
    assert(!vm.frozen);
    defer vm.serial.flush();
    while (true) {
        if (vm.over_limit) return .hung;
        if (vm.steps_live) try vm.steps_poll();
        if (vm.session_over) return .command_done;
        if (vm.idle_pending) {
            vm.idle_pending = false;
            if (try vm.idle()) |outcome| return outcome;
            continue;
        }
        if (vm.deterministic) try vm.timer_arm();
        vm.state_cached = null; // The guest runs.
        _ = kvm.ioctl(vm.vcpu_fd, kvm.RUN, 0) catch |err| switch (err) {
            error.Interrupted => {
                vm.stats.exits.getPtr(.intr).* += 1;
                continue;
            },
            else => return err,
        };
        // Whether this target exit is the timer's soft stop, read before modulate: a stretch's
        // end there re-arms the target (target_set(0)), and the soft stop then read as the
        // moment's or the hold point's own, which arrived that early (a replay's moment 107 to
        // 144 us early, run 356's two replays that parted from their timelines, srv4 2026-11-01).
        // A breakpoint's exit is the VMM's: the stop det:continue asked for (the session's moment
        // from here), or passed (RF) and gone on from.
        if (vm.run.exit_reason == .debug) {
            if (try vm.debug_breakpoint_hit()) {
                if (try vm.moment_arrive()) |outcome| return outcome;
            }
            continue;
        }
        // A write to watched pages is the VMM's, not the timeline's: applied and gone on from.
        if (vm.run.exit_reason == .mmio and vm.run.exit.mmio.is_write != 0 and vm.watched(vm.run.exit.mmio.phys_addr)) {
            try vm.watch_write();
            continue;
        }
        const soft_stop = vm.run.exit_reason == .det_target and try vm.soft_stopped();
        // At the guest's own exits: a moment's or a hold point's stop is not one (a timeline
        // without that stop has no exit there).
        switch (vm.run.exit_reason) {
            .io, .mmio, .hlt => try vm.modulate(),
            .det_target => if (vm.target_kind == .timer or soft_stop) try vm.modulate(),
            else => {},
        }
        switch (vm.run.exit_reason) {
            .io => {
                if (try vm.handle_io()) |outcome| return outcome;
                try vm.timer_due();
                try vm.hold_notice();
            },
            .mmio => {
                try vm.handle_mmio();
                try vm.timer_due();
            },
            .det_target => {
                assert(vm.deterministic);
                vm.stats.exits.getPtr(.det_target).* += 1;
                const soft_exits = (try vm.det_state()).soft_exits;
                const soft = soft_exits != vm.soft_exits_seen;
                vm.soft_exits_seen = soft_exits;
                // The timer's soft stop while a hold point or a moment is the target.
                if (vm.target_kind != .timer and soft_stop) {
                    try vm.target_set(0); // Re-armed next loop.
                    if (vm.pit.armed) try vm.timer_fire();
                    continue;
                }
                switch (vm.target_kind) {
                    .moment => {
                        vm.target_branches = 0;
                        if (try vm.moment_arrive()) |outcome| return outcome;
                    },
                    .hold => {
                        vm.target_branches = 0;
                        try vm.hold_reach(.{ .idle = false });
                        // The hold point fell on the clock read that is the timer's soft stop: the
                        // timer fires here, after the holder saw the moment (as a replay stopping
                        // there sees it, the timer not fired yet), as in the timeline without
                        // the hold point. Not firing it moved the timer to the next clock read, and
                        // the timeline parted from its replays (srv4, 2026-10-31: 59 of 600).
                        if (soft and vm.pit.armed) {
                            try vm.target_set(0);
                            try vm.timer_fire();
                        }
                    },
                    .timer => {
                        try vm.target_set(0); // A soft stop leaves the hard one armed.
                        if (vm.pit.armed) try vm.timer_fire();
                    },
                }
            },
            .hlt => {
                vm.stats.exits.getPtr(.hlt).* += 1;
                if (!vm.deterministic) return .hlt;
                if (try vm.idle()) |outcome| return outcome;
            },
            .shutdown => return .shutdown,
            .intr => vm.stats.exits.getPtr(.intr).* += 1,
            .fail_entry => return .{ .failed = "VM entry failed" },
            .internal_error => return .{ .failed = "KVM internal error" },
            else => {
                vm.stats.exits.getPtr(.other).* += 1;
                std.log.warn("unhandled exit {d}", .{@backingInt(vm.run.exit_reason)});
                return .{ .failed = "unhandled exit" };
            },
        }
    }
    comptime unreachable;
}

/// The fast VM's loop (Options.vcpus > 1): every vCPU in a thread of its own, the first in
/// this one; KVM's in-kernel LAPICs, I/O APIC and PIT keep time and route interrupts on host
/// time; port and MMIO exits go to the same devices as a one-vCPU machine's, one at a time.
/// It ends at the first vCPU's end (a reboot, a debug exit, a failure); the others are kicked
/// out of KVM_RUN and joined.
fn run_loop_fast(vm: *VM) !Outcome {
    assert(!vm.deterministic and vm.ap_count > 0);
    defer vm.serial.flush();
    const kick: linux.Sigaction = .{ .handler = .{ .handler = kick_handler }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(kick_signal, &kick, null);
    vm.bsp_thread = std.c.pthread_self();
    vm.bsp_run = vm.run;
    var threads: [mptable.cpus_max - 1]?std.Thread = @splat(null);
    for (vm.aps[0..vm.ap_count], threads[0..vm.ap_count]) |*ap, *thread| {
        thread.* = try std.Thread.spawn(.{}, ap_main, .{ vm, ap });
    }
    const timer = try std.Thread.spawn(.{}, fast_timer_main, .{vm});
    if (vm.dev_directory) |directory| {
        const control = try std.Thread.spawn(.{}, dev_control_main, .{ vm, directory });
        control.detach(); // Blocked reading its FIFO: it ends with the process.
    }
    vm.vcpu_main(vm.vcpu_fd, vm.run);
    _ = vm.pit_generation.fetchAdd(1, .release);
    _ = linux.futex_3arg(&vm.pit_generation.raw, .{ .cmd = .WAKE, .private = true }, 1);
    timer.join();
    for (vm.aps[0..vm.ap_count], threads[0..vm.ap_count]) |*ap, *thread| {
        ap.run.immediate_exit = 1;
        if (thread.*) |t| {
            _ = std.c.pthread_kill(t.getHandle(), kick_signal);
            t.join();
        }
    }
    return vm.fast_outcome orelse .shutdown;
}

const kick_signal = linux.SIG.USR2;

fn kick_handler(_: linux.SIG) callconv(.c) void {}

/// The fast VM's PIT: its interrupt fired at its deadline in host time (the guest's TSC read
/// as fast_guest_tsc), a new deadline taken at each PIT write (pit_generation).
fn fast_timer_main(vm: *VM) void {
    var directory_checked_ns: u64 = 0;
    while (!vm.fast_done.load(.acquire)) {
        // A machine whose directory was deleted is no one's (serve's DELETE removes it with
        // the machine; one deleted by hand left three machines running for good, 2026-11-11):
        // it ends, checked once a second.
        if (vm.dev_directory) |directory| if (monotonic_ns() - directory_checked_ns >= std.time.ns_per_s) {
            directory_checked_ns = monotonic_ns();
            if (!dev_directory_exists(directory)) {
                std.debug.print("[determinismo] dev mode: {s} is gone: the machine ends\n", .{directory});
                vm.fast_end(.shutdown);
                return;
            }
        };
        const generation = vm.pit_generation.load(.acquire);
        vm.exits_lock.lock();
        const deadline = vm.pit.deadline_tsc();
        const now = vm.fast_guest_tsc();
        if (deadline) |due| if (due <= now) {
            vm.pit.fire();
            vm.stats.timer_fires += 1;
            vm.irq_pulse(PIT.irq) catch {};
            vm.exits_lock.unlock();
            continue;
        };
        vm.exits_lock.unlock();
        // Until the deadline (at most a second), or the next PIT write.
        // TSC ticks to nanoseconds by division (a multiplication overflowed past 4.6 s of ticks).
        const wait_ns: u64 = if (deadline) |due|
            @min((due - now) / (cpuid.tsc_hz / std.time.ns_per_s), std.time.ns_per_s)
        else
            std.time.ns_per_s;
        const timeout: linux.timespec = .{ .sec = @intCast(wait_ns / std.time.ns_per_s), .nsec = @intCast(wait_ns % std.time.ns_per_s) };
        _ = linux.futex_4arg(&vm.pit_generation.raw, .{ .cmd = .WAIT, .private = true }, generation, &timeout);
    }
}

fn dev_directory_exists(directory: []const u8) bool {
    var path_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return true;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) != .NOENT;
}

/// The dev mode's control: `<dev_directory>/control`, a FIFO; a line `explore-here` there asks
/// the guest's agent to explore from here (det:explore-here), the action given as a session's
/// step is (action_pending, its interrupt).
fn dev_control_main(vm: *VM, directory: []const u8) void {
    var path_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/control", .{directory}, 0) catch return;
    _ = linux.unlink(path);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, path, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return;
    // Read and write: no end of input when a writer closes.
    const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(opened);
    std.debug.print("[determinismo] dev mode: `echo explore-here > {s}` explores from the machine as it is\n", .{path});
    // Lines: `explore-here`, or `action <text>`, an action for the guest's agent as a session's
    // step gives it (a command, det:background, det:send: infra/host/nrepl-proxy.py --dev's).
    const buffer = std.heap.page_allocator.alloc(u8, dev_control_line_max * 2) catch return;
    var used: usize = 0;
    while (!vm.fast_done.load(.acquire)) {
        if (used == buffer.len) used = 0; // A line past the most: dropped.
        const result = linux.read(fd, buffer[used..].ptr, buffer.len - used);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        used += result;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..used], start, '\n')) |end| {
            const line = std.mem.trim(u8, buffer[start..end], " \r");
            start = end + 1;
            const action: []const u8 = if (std.mem.eql(u8, line, "explore-here"))
                explore_here_action
            else if (std.mem.startsWith(u8, line, "action "))
                line["action ".len..]
            else {
                std.debug.print("[determinismo] dev mode: unknown command {s}\n", .{line});
                continue;
            };
            if (action.len == 0 or action.len > vm.dev_action.len) continue;
            vm.dev_action_give(action);
        }
        std.mem.copyForwards(u8, buffer[0 .. used - start], buffer[start..used]);
        used -= start;
    }
}

const dev_control_line_max = step_size_max + 64;

/// An action for the guest's agent, once the one before it was taken (the agent asks for one
/// at a time): copied into dev_action, the agent's interrupt raised.
fn dev_action_give(vm: *VM, action: []const u8) void {
    while (!vm.fast_done.load(.acquire)) {
        vm.exits_lock.lock();
        if (vm.action_pending == null) {
            @memcpy(vm.dev_action[0..action.len], action);
            vm.action_pending = vm.dev_action[0..action.len];
            vm.irq_pulse(irq_action) catch {};
            vm.exits_lock.unlock();
            return;
        }
        vm.exits_lock.unlock();
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
}

const explore_here_action = "det:explore-here";

fn ap_main(vm: *VM, ap: *Ap) void {
    vm.vcpu_main(ap.fd, ap.run);
}

/// One fast vCPU, to the machine's end.
fn vcpu_main(vm: *VM, fd: linux.fd_t, run: *kvm.Run) void {
    const outcome = vm.vcpu_loop(fd, run) catch |err| Outcome{ .failed = @errorName(err) };
    vm.fast_end(outcome);
}

/// The fast VM ended with `outcome` (the first to end it decides): every vCPU stops.
fn fast_end(vm: *VM, outcome: Outcome) void {
    if (vm.fast_done.swap(true, .acq_rel)) return; // Another ended it first.
    vm.fast_outcome = outcome;
    // Every vCPU stops: the first's thread too, when another ended it.
    vm.bsp_run.?.immediate_exit = 1;
    for (vm.aps[0..vm.ap_count]) |ap| ap.run.immediate_exit = 1;
    if (vm.bsp_thread) |bsp| if (bsp != std.c.pthread_self()) {
        _ = std.c.pthread_kill(bsp, kick_signal);
    };
}

fn vcpu_loop(vm: *VM, fd: linux.fd_t, run: *kvm.Run) !Outcome {
    while (!vm.fast_done.load(.acquire)) {
        _ = kvm.ioctl(fd, kvm.RUN, 0) catch |err| switch (err) {
            error.Interrupted, error.Again => continue,
            else => return err,
        };
        switch (run.exit_reason) {
            .io, .mmio => {
                vm.exits_lock.lock();
                defer vm.exits_lock.unlock();
                // The devices read the exit from vm.run: this vCPU's, while it holds the lock.
                const own = vm.run;
                vm.run = run;
                defer vm.run = own;
                if (run.exit_reason == .io) {
                    const port = run.exit.io.port;
                    if (try vm.handle_io()) |outcome| return outcome;
                    if (port == PIT.port_channel_0 or port == PIT.port_mode) {
                        _ = vm.pit_generation.fetchAdd(1, .release);
                        _ = linux.futex_3arg(&vm.pit_generation.raw, .{ .cmd = .WAKE, .private = true }, 1);
                    }
                } else try vm.handle_mmio();
            },
            .hlt, .intr => {},
            .shutdown => return .shutdown,
            .fail_entry => return .{ .failed = "VM entry failed" },
            .internal_error => return .{ .failed = "KVM internal error" },
            else => {
                std.log.warn("unhandled exit {d}", .{@backingInt(run.exit_reason)});
                return .{ .failed = "unhandled exit" };
            },
        }
    }
    return vm.fast_outcome orelse .shutdown;
}

/// The fast VM's machine as a snapshot on disk (`<dev_directory>/here-<n>`), at its first
/// vCPU's exit where the guest asked (det:explore-here, its other CPUs offline): explore
/// --from-snapshot runs timelines from it. Every vCPU is stopped meanwhile (this one in its
/// exit; the others offline in the guest, and none runs while the exits lock is held).
fn explore_here_save(vm: *VM) !void {
    assert(vm.fast);
    const directory = vm.dev_directory orelse {
        std.debug.print("[determinismo] explore here asked: no --dev directory to write it to\n", .{});
        return;
    };
    const started_ns = monotonic_ns();
    const snapshot = try std.heap.page_allocator.create(Snapshot);
    defer std.heap.page_allocator.destroy(snapshot);
    try snapshot.capture_fast(vm);
    // The PIT's clock against the guest's own TSC, as captured: their skew is how far in the
    // future (or past) the snapshot's timer lands for the timelines from it.
    const skew_ticks: i64 = @bitCast(vm.fast_guest_tsc() -% snapshot.tsc);
    const skew_us = @divTrunc(skew_ticks * 1000, @as(i64, @intCast(vm.fast_guest_khz)));
    // Fresh hashes (the first save, or one after a failed save) mean every page written and
    // no base: against a base, an unwritten page would be read from it.
    const fresh = vm.dev_hashes == null;
    if (fresh) vm.dev_hashes = try Snapshot.PageHashes.init(vm.memory.len);
    var base_buffer: [32]u8 = undefined;
    const base = if (fresh) null else try std.fmt.bufPrint(&base_buffer, "here-{d}", .{vm.dev_saved});
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "here-{d}", .{vm.dev_saved + 1});
    snapshot.disk_save(vm.memory, vm.memory_fd, vm.dev_hashes.?.hashes, directory, name, base, false) catch |err| {
        // The hashes were half updated: the next save writes everything again.
        vm.dev_hashes.?.deinit();
        vm.dev_hashes = null;
        return err;
    };
    vm.dev_saved += 1;
    std.debug.print("[determinismo] explore from here: {s}/{s} ({d} ms, clock skew {d} us; determinismo explore --from-snapshot {s}/{s} ...)\n", .{
        directory, name, (monotonic_ns() - started_ns) / std.time.ns_per_ms, skew_us, directory, name,
    });
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// A fast VM's other vCPU.
const Ap = struct { fd: linux.fd_t, run: *kvm.Run };

/// A futex lock for the fast VM's exits: a vCPU waiting for another's sleeps, not spins.
const FutexLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    /// 0 free, 1 held, 2 held with waiters (Drepper's "Futexes Are Tricky", mutex 3). A waiter
    /// that wakes takes it as 2, never 1: other waiters may still sleep, and 1 would make the
    /// unlock wake none (the first version did: vCPU 0 asleep for good at boot).
    fn lock(self: *FutexLock) void {
        var state = self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) orelse return;
        if (state != 2) state = self.state.swap(2, .acquire);
        while (state != 0) {
            _ = linux.futex_4arg(&self.state.raw, .{ .cmd = .WAIT, .private = true }, 2, null);
            state = self.state.swap(2, .acquire);
        }
    }

    fn unlock(self: *FutexLock) void {
        if (self.state.swap(0, .release) == 2) {
            _ = linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

pub fn det_state(vm: *VM) !kvm.DetState {
    assert(vm.deterministic);
    if (vm.state_cached) |state| return state;
    var state: kvm.DetState = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_GET_STATE, @intFromPtr(&state));
    assert(state.tsc >= state.branches * vm.tsc_per_branch);
    vm.state_cached = state;
    return state;
}

const Deadline = struct {
    tsc: u64,
    kind: Kind,

    const Kind = enum {
        timer,
        moment,
        hold,

        /// Moments and hold points stop at their exact branch count; timers have slack.
        fn exact(kind: Kind) bool {
            return kind != .timer;
        }
    };
};
const tsc_per_ns = cpuid.tsc_hz / std.time.ns_per_s;

/// The next thing the VMM must do at a precise moment: fire the PIT, reach the moment, or pause
/// at a hold point. The earliest; at the same time the moment, then the timer: a timer may fire
/// at a clock read past its deadline, and a hold point stopping first would move it.
fn deadline_next(vm: *const VM) ?Deadline {
    const timer: ?Deadline = if (vm.pit.deadline_tsc()) |tsc| .{
        .tsc = tsc,
        .kind = .timer,
    } else null;
    const stop: ?Deadline = if (vm.moment_reached) null else if (vm.moment_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .moment,
    } else null;
    const hold: ?Deadline = if (vm.hold_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .hold,
    } else null;
    var next: ?Deadline = null;
    for ([_]?Deadline{ stop, timer, hold }) |candidate| {
        const deadline = candidate orelse continue;
        if (next == null or deadline.tsc < next.?.tsc) next = deadline;
    }
    return next;
}

/// Asks KVM to stop the vCPU at the next deadline. A moment stops at its exact branch count, and
/// so does a hold point. A timer stops at the first RDTSC at or past its deadline (a soft stop,
/// free), or at most `timer_slack` later at an exact branch count (a hard stop, which costs
/// single-stepping): both are exact points of the guest's execution, so replays deliver it at
/// the same place. A hold point or a moment within a timer's slack is the target, and the timer
/// keeps its soft stop and then its hard one: the timer fires where a timeline without the hold
/// point fires it (passing it, the hold point was dropped: a causality replay with a 1 ms slack
/// saved 3 of 5 moments).
fn timer_arm(vm: *VM) !void {
    assert(vm.deterministic);
    if (vm.target_branches != 0) return;
    const state = try vm.det_state();
    if (vm.progress) |slot| {
        const now_ns = state.tsc / tsc_per_ns;
        if (now_ns >= vm.progress_next_ns) {
            @atomicStore(u64, slot, now_ns, .monotonic);
            vm.progress_next_ns = now_ns + std.time.ns_per_s;
        }
    }
    // Virtual time in thousandths of a tick: the guest's clock and what the CPU modulation owes
    // it (added at the next exit). It grows by per_branch a branch, so a stop computed from it
    // is the same wherever it is computed: at a hold point as at the exit before it.
    const owed_milli = if (vm.modulation) |m|
        m.owed_milli(state.branches, vm.tsc_per_branch)
    else
        0;
    const now_milli = state.tsc * 1000 + owed_milli;
    // The next exact deadline, past ones dealt with.
    const exact: ?Deadline = while (vm.exact_next()) |next| {
        if (next.tsc * 1000 > now_milli) break next;
        switch (next.kind) {
            .moment => {
                try vm.trace("moment-past", next.tsc);
                vm.moment_tsc = state.tsc; // Already past: the moment is now.
                vm.target_kind = .moment;
                return vm.target_set(state.branches + 1); // Stop right after the next branch.
            },
            .hold => vm.hold_tsc = null, // Past (not where a replay would stop): none, a replay makes the node.
            .timer => unreachable,
        }
    } else null;
    const timer_tsc = vm.pit.deadline_tsc();
    var stop = exact;
    if (timer_tsc) |deadline| {
        const hard_tsc = deadline + vm.timer_slack_tsc;
        if (hard_tsc * 1000 <= now_milli) {
            // Its hard stop is now: fired, and the next deadline armed (a hold point next must
            // not wait for the guest's next exit).
            try vm.timer_fire();
            return vm.timer_arm();
        }
        if (stop == null or hard_tsc < stop.?.tsc) stop = .{ .tsc = hard_tsc, .kind = .timer };
    }
    const target = stop orelse return;
    // With CPU modulation a branch takes more virtual time than the guest's clock shows until
    // the next exit adds it: count branches at the modulated rate, and place the soft stop at
    // the first clock read that, its owed time added, reads the deadline.
    const permille: u64 = 1000 + if (vm.modulation) |m| m.slowdown_permille else 0;
    const per_branch = @as(u64, vm.tsc_per_branch) * permille;
    const branches_left = @divCeil(target.tsc * 1000 - now_milli, per_branch);
    assert(branches_left > 0);
    vm.target_kind = target.kind;
    try vm.target_set(state.branches + branches_left);
    switch (target.kind) {
        inline else => |kind| try vm.trace("target-" ++ @tagName(kind), state.branches + branches_left),
    }
    if (timer_tsc) |deadline| if (vm.timer_slack_tsc > 0) {
        // Its landing point: the deadline, or as far into its slack as the machine says.
        const landing = deadline + vm.timer_delay_tsc;
        // Due already (a hold point within its slack stopped first): the next clock read.
        const soft_tsc = if (landing * 1000 <= now_milli)
            state.tsc
        else
            state.tsc + @divCeil(landing * 1000 - now_milli, permille);
        try vm.soft_set(soft_tsc);
    };
}

/// The next moment or hold point, whichever comes first (at the same time the moment).
fn exact_next(vm: *const VM) ?Deadline {
    const stop: ?Deadline = if (vm.moment_reached) null else if (vm.moment_tsc) |tsc| .{
        .tsc = tsc,
        .kind = .moment,
    } else null;
    const hold: ?Deadline = if (vm.hold_tsc) |tsc| .{ .tsc = tsc, .kind = .hold } else null;
    const first = stop orelse return hold;
    const other = hold orelse return first;
    return if (other.tsc < first.tsc) other else first;
}

/// Whether this target exit is a soft stop (a clock read at or past the timer's deadline, before
/// the exact target): the timer's, whatever the target is.
fn soft_stopped(vm: *VM) !bool {
    if (vm.target_branches == 0) return false;
    return (try vm.det_state()).branches < vm.target_branches;
}

/// Adds the extra virtual time of the branches run since the last exit, and at the end of a
/// stretch draws the next speed (a stop armed at the old speed is re-armed).
fn modulate(vm: *VM) !void {
    const modulation = if (vm.modulation) |*m| m else return;
    const state = try vm.det_state();
    const owed = modulation.owed_milli(state.branches, vm.tsc_per_branch);
    modulation.branches = state.branches;
    modulation.remainder = owed % 1000;
    var extra_tsc = owed / 1000;
    try vm.trace("modulate", extra_tsc);
    if (extra_tsc > 0) {
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ADD_TSC, @intFromPtr(&extra_tsc));
        vm.state_cached = null;
        // A soft stop is a clock reading: it moves with the clock, to where timer_arm would put
        // it now (and does, after a hold point re-arms it: the timeline is the same either way).
        if (vm.soft_tsc != 0) try vm.soft_set(vm.soft_tsc + extra_tsc);
    }
    const tsc = state.tsc + extra_tsc;
    if (tsc < modulation.change_tsc) return;
    var draw: [8]u8 = undefined;
    vm.pull_tid = 0; // The platform's own pull: no thread's label or request.
    try vm.decide_random(&draw, "cpu-modulation");
    const value = std.mem.readInt(u64, &draw, .little);
    // A quarter of the stretches at full speed.
    modulation.slowdown_permille = if (value % 4 == 0)
        0
    else
        @intCast((value >> 2) % (modulation_permille_max + 1));
    const stretch_ns = modulation.stretch_ns_min +
        (value >> 16) % (modulation.stretch_ns_max - modulation.stretch_ns_min);
    modulation.change_tsc = tsc + stretch_ns * tsc_per_ns;
    if (vm.target_branches != 0) try vm.target_set(0);
}

/// The moment arrived: end the run there, or push the command to the guest agent and keep
/// running until it reports completion.
fn moment_arrive(vm: *VM) !?Outcome {
    assert(!vm.moment_reached);
    vm.moment_reached = true;
    vm.continuing = false; // A det:continue's breakpoint, or its time out: either way, here.
    if (vm.collect) |collect| {
        std.debug.print("[determinismo] collect: {{\"hits\":{d},\"dropped\":{d}}}\n", .{ collect.hits, collect.dropped });
        vm.collect = null;
    }
    vm.target_kind = .timer;
    const moment_now = try vm.moment();
    try vm.trace("moment", moment_now.vtime_ns);
    if (vm.until != null and !vm.until_hit) {
        std.debug.print("[determinismo] until: timed out, the condition did not hold\n", .{});
    }
    std.debug.print("[determinismo] at moment vtime={d}ns branches={d}\n", .{
        moment_now.vtime_ns, moment_now.branches,
    });
    if (vm.step_until_branches) |want| {
        if (moment_now.branches < want) {
            // The guest idled (its clock ran on without branches): on for the rest.
            vm.moment_reached = true;
            try vm.step_arm_branches(want - moment_now.branches);
            return null;
        }
        vm.step_until_branches = null;
    }
    if (vm.stepping) {
        vm.stepping = false;
        if (vm.live_ending) {
            vm.live_ending = false;
            try vm.session_end();
            return null;
        }
        if (vm.checkpoint_asked) |name| if (try vm.session_checkpoint(name)) return null;
        return vm.steps_next();
    }
    const given = vm.moment_command orelse return .moment_reached;
    vm.moment_changed = true;
    // A fresh future: the timeline's randomness and tape end here, the guest's kernel generator
    // reseeded from the new seed, and the fault injector told, as at a tree's branch point. Its
    // seed is taken by a step (det:fresh), so a session recorded as a timeline has it on its
    // tape, and its replay takes the same seed at the same moment.
    const commands = if (vm.fresh_seed) |seed| blk: {
        vm.overrides = null;
        std.debug.print("[determinismo] a fresh future from here (seed {d})\n", .{seed});
        var fresh: [step_fresh.len + 20]u8 = undefined;
        const taking = std.fmt.bufPrint(&fresh, step_fresh ++ "{d}", .{seed}) catch unreachable;
        // The guest's own reseed after it: a no-op in the shell of a guest older than det:reseed.
        break :blk try std.mem.concat(vm.step_arena.allocator(), u8, &.{ taking, "\x00: det:reseed\x00", given });
    } else given;
    vm.moment_printing = true;
    // Steps of the platform's: the guest's agent holds the timeline from its end meanwhile.
    const stepped = std.mem.indexOf(u8, commands, step_wait) != null or
        std.mem.indexOf(u8, commands, step_until) != null or
        std.mem.indexOf(u8, commands, step_at) != null or
        std.mem.indexOf(u8, commands, "det:background ") != null;
    // A live session's first step is the moment's own commands: done, said so.
    if (vm.steps_live) vm.live_busy = true;
    // The agent's hold, owed: sent before the first step it acts on (moment_command_one), not
    // here, where it would run the guest at the moment.
    vm.hold_owed = !vm.moment_held;
    vm.moment_commands_rest = if (vm.steps_fd != null)
        // Released when the steps' input ends (steps_read).
        commands
    else if (stepped or vm.moment_continue)
        // A timeline continued after its commands runs on to its own end: held, the scenario's
        // end waited on the hold to the timeline's limit (a plain `--exec <cmd> --continue`,
        // every such timeline read as hung: e2e continue).
        try std.mem.concat(vm.step_arena.allocator(), u8, &.{ commands, "\x00det:release" })
    else
        commands;
    try vm.moment_command_next();
    return null;
}

/// Pushes the next of the moment's commands to the guest agent.
fn moment_command_next(vm: *VM) !void {
    // A loop, not recursion: a debugger step hands the next one on with the vCPU stopped, as
    // many as a session sends (the x86_64 backend has no tail calls).
    while (try vm.moment_command_one()) {}
}

/// One step of the moment's commands; true when the next is to run at once, the vCPU stopped.
fn moment_command_one(vm: *VM) !bool {
    assert(vm.moment_commands_rest.len > 0);
    const rest = vm.moment_commands_rest;
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const raw = rest[0..end];
    vm.moment_commands_rest = if (end == rest.len) "" else rest[end + 1 ..];
    // A step another expanded into (det:ask's): run, not recorded (the one it came from is).
    const expanded = raw.len > 0 and raw[0] == expansion_mark;
    const step = if (expanded) raw[1..] else raw;
    if (std.mem.startsWith(u8, step, step_ask)) {
        // "<fifo> <id> <base64 part>...": a REPL's message (det-nrepl-relay serve's fast path),
        // each part written to the relay's FIFO (the agent's det:send, no process started),
        // then on until the relay says the message is done.
        try vm.step_record(step);
        const allocator = vm.step_arena.allocator();
        var words = std.mem.tokenizeScalar(u8, step[step_ask.len..], ' ');
        const fifo = words.next() orelse return error.BadStep;
        const id = words.next() orelse return error.BadStep;
        var steps: std.ArrayList(u8) = .empty;
        while (words.next()) |part| try steps.print(allocator, "{c}det:send {s} {s}\x00", .{ expansion_mark, fifo, part });
        // Its end: the server's done reply, or no reply ever coming: the relay's connection
        // closed (the server's process died: a crash in what the REPL ran), or a part not
        // written (no relay reads the FIFO any more). Then the session answers at once, not
        // after ask_timeout_ms of a machine waiting on nothing (a jank crash's 10 silent
        // minutes, phoenixNAP 2026-11-10).
        const done = try std.fmt.allocPrint(allocator, "event=nrepl_done details.id=\"{s}\" or " ++
            "event=nrepl_relay_closed or event=exec_done details.status!=0 details.background!?", .{id});
        try steps.print(allocator, "{c}" ++ step_until ++ "{d} {s}", .{ expansion_mark, ask_timeout_ms, done });
        const condition = try allocator.create(query.Condition);
        condition.* = try query.parse(allocator, done);
        vm.ask_until = condition;
        vm.ask_until_hit = false;
        if (vm.moment_commands_rest.len > 0) {
            try steps.append(allocator, 0);
            try steps.appendSlice(allocator, vm.moment_commands_rest);
        }
        vm.moment_commands_rest = steps.items;
        return true;
    }
    if (std.mem.startsWith(u8, step, step_at)) {
        // "<vtime ns>": on to that moment, or on at once from one already there.
        const ns = std.fmt.parseInt(u64, std.mem.trim(u8, step[step_at.len..], " "), 10) catch
            return error.BadStep;
        const now = try vm.moment();
        if (ns > now.vtime_ns) {
            try vm.step_arm_at(ns, null);
            return false;
        }
        if (vm.moment_commands_rest.len > 0) return true;
        return false;
    }
    if (!expanded) try vm.step_record(step);
    if (std.mem.eql(u8, step, step_here)) {
        // The moment itself, nothing done: an interactive session's first step when none was
        // asked (a guest no-op, ":", woke the agent at the moment and parted the session's future
        // from the recorded one).
        if (vm.moment_commands_rest.len > 0) return true;
        if (!vm.steps_live and vm.steps_fd != null and try vm.steps_read()) return true;
        try vm.step_arm(0, null);
        return false;
    }
    // The debugger's steps (docs/DEBUGGING.md): the VMM's, the vCPU stopped, then on at once. A
    // bad one is said and the session goes on (a person typing, not a script to abort).
    if (std.mem.eql(u8, step, step_regs) or std.mem.startsWith(u8, step, step_mem) or
        std.mem.startsWith(u8, step, step_poke) or std.mem.startsWith(u8, step, step_translate))
    {
        vm.debug_step(step) catch |err| {
            std.debug.print("[determinismo] debug: {{\"step\":\"{s}\",\"error\":\"{s}\"}}\n", .{ step, @errorName(err) });
        };
        // Looking moves nothing: the next step queued runs with the vCPU where it is; the last
        // of a request waits for the session's next one as a step does (the guest runs on).
        if (vm.moment_commands_rest.len > 0) return true;
        // A session's next step, the machine stopped meanwhile (not live: steps_read blocks with
        // the vCPU out of the guest), so a person's looks between requests see one state.
        if (!vm.steps_live and vm.steps_fd != null and try vm.steps_read()) return true;
        try vm.step_arm(0, null);
        return false;
    }
    if (std.mem.eql(u8, step, step_checkpoint) or std.mem.startsWith(u8, step, step_checkpoint ++ " ")) {
        // "[name]": on 1 ns, exactly, to where the checkpoint is (session_checkpoint).
        const name = std.mem.trim(u8, step[step_checkpoint.len..], " ");
        if (name.len > checkpoint_name_max) return error.BadStep;
        for (name) |c| if (c < 0x20 or c == '"' or c == '\\') return error.BadStep;
        vm.checkpoint_asked = try vm.step_arena.allocator().dupe(u8, name);
        try vm.step_arm_at((try vm.moment()).vtime_ns + 1, null);
        return false;
    }
    if (std.mem.eql(u8, step, step_extend)) {
        vm.steps_own = true;
        if (vm.ingress_listen != null) if (vm.overrides) |overrides| {
            vm.ingress_answers_live = true;
            const dropped = overrides.drop_kind(.ingress);
            if (dropped > 0) std.debug.print("[determinismo] extend: {d} recorded ingress answers to come dropped (this session listens)\n", .{dropped});
        };
        if (vm.moment_commands_rest.len > 0) return true;
        if (!vm.steps_live and vm.steps_fd != null and try vm.steps_read()) return true;
        try vm.step_arm(0, null);
        return false;
    }
    if (std.mem.startsWith(u8, step, step_fresh)) {
        // "<seed>": the timeline's decisions are drawn from this seed from here on.
        vm.decisions.seed = std.fmt.parseInt(u64, std.mem.trim(u8, step[step_fresh.len..], " "), 10) catch return error.BadStep;
        if (vm.moment_commands_rest.len > 0) return true;
        if (!vm.steps_live and vm.steps_fd != null and try vm.steps_read()) return true;
        try vm.step_arm(0, null);
        return false;
    }
    if (std.mem.eql(u8, step, step_over)) {
        // Where the session that recorded this timeline ended: its replay's end.
        vm.steps_fd = null;
        vm.session_over = true;
        return false;
    }
    if (std.mem.startsWith(u8, step, step_branches)) {
        // "<n>": the guest runs on n taken branches (jumps, calls, returns) and stops there,
        // exactly, timers firing where they would (moment stops on its clock, re-armed while an
        // idle guest's clock ran ahead of its branches: moment_arrive); det:regs shows where.
        const n = std.fmt.parseInt(u64, std.mem.trim(u8, step[step_branches.len..], " "), 0) catch return error.BadStep;
        if (n == 0) return error.BadStep;
        vm.step_until_branches = (try vm.moment()).branches + n;
        try vm.step_arm_branches(n);
        return false;
    }
    if (std.mem.startsWith(u8, step, step_break) or std.mem.startsWith(u8, step, step_watch)) {
        // det:break "<virtual address> [cr3]" or "off": a hardware execute breakpoint (DR0), the
        // next det:continue stopping there, before the instruction. det:watch "<virtual address>
        // <bytes> [cr3]" or "off": a hardware write watchpoint (DR1; 1, 2, 4 or 8 bytes, aligned
        // to their size, as the CPU matches them), det:continue stopping after a write there.
        const watch = std.mem.startsWith(u8, step, step_watch);
        const arguments = if (watch) step[step_watch.len..] else step[step_break.len..];
        var words = std.mem.tokenizeScalar(u8, arguments, ' ');
        const first = words.next() orelse return error.BadStep;
        if (std.mem.eql(u8, first, "off")) {
            if (watch) vm.watchpoint = null else vm.breakpoint = null;
        } else {
            const address = std.fmt.parseInt(u64, first, 0) catch return error.BadStep;
            const size: u8 = if (watch) std.fmt.parseInt(u8, words.next() orelse return error.BadStep, 0) catch return error.BadStep else 1;
            if (watch and (watch_length(size) == null or address % size != 0)) return error.BadStep;
            const cr3 = if (words.next()) |text| std.fmt.parseInt(u64, text, 0) catch return error.BadStep else null;
            if (watch) {
                vm.watchpoint = .{ .address = address, .size = size, .cr3 = cr3 };
            } else {
                vm.breakpoint = .{ .address = address, .cr3 = cr3 };
            }
        }
        try vm.debug_breakpoint_apply();
        std.debug.print("[determinismo] break: {{\"armed\":{},\"watching\":{}}}\n", .{ vm.breakpoint != null, vm.watchpoint != null });
        if (vm.moment_commands_rest.len > 0) return true;
        try vm.step_arm(0, null);
        return false;
    }
    if (std.mem.startsWith(u8, step, step_continue)) {
        // "[ms]": on until the breakpoint or a watched write (or ms of virtual time, 60 s by
        // default), stopped there.
        const text = std.mem.trim(u8, step[step_continue.len..], " ");
        const ms = if (text.len == 0) 60_000 else std.fmt.parseInt(u64, text, 0) catch return error.BadStep;
        if (vm.breakpoint == null and vm.watchpoint == null) return error.NoBreakpoint;
        vm.continuing = true;
        try vm.step_arm(ms, null);
        return false;
    }
    if (std.mem.startsWith(u8, step, step_collect)) {
        // "[ms]": on for ms of virtual time (10 s by default), each hit of the breakpoint or the
        // watched write said as it passes, the guest stopping only at the window's end: many
        // hits for one request (a session's det:continue is one a hit).
        const text = std.mem.trim(u8, step[step_collect.len..], " ");
        const ms = if (text.len == 0) 10_000 else std.fmt.parseInt(u64, text, 0) catch return error.BadStep;
        if (vm.breakpoint == null and vm.watchpoint == null) return error.NoBreakpoint;
        vm.collect = .{};
        try vm.step_arm(ms, null);
        return false;
    }
    if (std.mem.startsWith(u8, step, step_wait)) {
        const ms = std.fmt.parseInt(u64, std.mem.trim(u8, step[step_wait.len..], " "), 10) catch
            return error.BadStep;
        {
            try vm.step_arm(ms, null);
            return false;
        }
    }
    if (expanded and std.mem.startsWith(u8, step, step_until)) if (vm.ask_until != null) {
        // det:ask's end: done already (during its sends), or from here on.
        const hit = vm.ask_until_hit;
        const condition = vm.ask_until.?;
        vm.ask_until = null;
        if (hit) {
            try vm.step_arm(0, null);
            return false;
        }
        {
            try vm.step_arm(ask_timeout_ms, condition);
            return false;
        }
    };
    if (std.mem.startsWith(u8, step, step_until)) {
        // "<timeout ms> <condition>": 0 for no timeout.
        const text = std.mem.trimStart(u8, step[step_until.len..], " ");
        const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadStep;
        const ms = std.fmt.parseInt(u64, text[0..space], 10) catch return error.BadStep;
        const condition = try vm.step_arena.allocator().create(query.Condition);
        condition.* = try query.parse(vm.step_arena.allocator(), text[space + 1 ..]);
        {
            try vm.step_arm(ms, condition);
            return false;
        }
    }
    if (step.len > step_size_max) {
        std.debug.print("[determinismo] a step of {d} bytes: at most {d} reach the guest, split it\n", .{ step.len, step_size_max });
        return error.StepTooLong;
    }
    if (vm.hold_owed and !std.mem.eql(u8, step, "det:release")) {
        // The first step the agent acts on: its hold first, then this step again, marked (it is
        // recorded once already; the hold is the platform's, never on the tape). A release with
        // no hold sent goes as it is (the agent unlinks a marker that is not there).
        vm.hold_owed = false;
        const allocator = vm.step_arena.allocator();
        const again = try std.mem.concat(allocator, u8, &.{ &[_]u8{expansion_mark}, step });
        vm.moment_commands_rest = if (vm.moment_commands_rest.len > 0)
            try std.mem.concat(allocator, u8, &.{ again, "\x00", vm.moment_commands_rest })
        else
            again;
        vm.action_pending = "det:hold";
        try vm.irq_pulse(irq_action);
        return false;
    }
    vm.action_pending = step;
    try vm.irq_pulse(irq_action);
    return false;
}

/// An interactive session's next step (steps_fd), once the ones before it are done: "step done"
/// said, then a line read, the machine paused meanwhile. False once there are none: the input
/// ended, its last step the hold's release. Empty lines are skipped.
fn steps_read(vm: *VM) !bool {
    if (vm.steps_live) {
        // Live: the guest runs on; the next step is taken as it comes (steps_poll).
        if (vm.live_busy) std.debug.print("[determinismo] step done\n", .{});
        vm.live_busy = false;
        return false;
    }
    const fd = vm.steps_fd orelse return false;
    std.debug.print("[determinismo] step done\n", .{});
    // The steps before are done, what they held with them (their lines, conditions): a
    // session's memory bounded by its longest step, not by how many it took.
    assert(vm.moment_commands_rest.len == 0);
    vm.until = null;
    vm.ask_until = null;
    _ = vm.step_arena.reset(.retain_capacity);
    const allocator = vm.step_arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        var byte: [1]u8 = undefined;
        const result = linux.read(fd, &byte, 1);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.StepsInput,
        }
        if (result == 0) {
            try vm.session_end();
            return false;
        }
        if (byte[0] != '\n') {
            try line.append(allocator, byte[0]);
            continue;
        }
        if (line.items.len == 0) continue;
        vm.moment_commands_rest = line.items;
        return true;
    }
}

/// A live session's next step, when one has come and none runs: armed 1 ms of virtual time from
/// now (step_arm), where it runs (moment_arrive). Its input's end releases the timeline.
fn steps_poll(vm: *VM) !void {
    const fd = vm.steps_fd orelse return;
    if (!vm.moment_reached or vm.stepping or vm.live_busy or vm.moment_commands_rest.len > 0) return;
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    const now_ns: u64 = @intCast(now.sec * std.time.ns_per_s + now.nsec);
    if (now_ns < vm.live_poll_at_ns) return;
    vm.live_poll_at_ns = now_ns + 20 * std.time.ns_per_ms;
    const allocator = vm.step_arena.allocator();
    while (std.mem.indexOfScalar(u8, vm.live_line.items, '\n') == null) {
        var chunk: [4096]u8 = undefined;
        const result = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .AGAIN, .INTR => return,
            else => return error.StepsInput,
        }
        if (result == 0) {
            // The release is the platform's, not a step: no "step done" for it. Its moment is
            // on the tape (det:over), so a replay runs the live stretch after the last step too,
            // what came from outside meanwhile (an ingress connection) from the tape.
            // It ends at a moment reached by the clock, 1 ms on, as a replay reaches det:over's:
            // ended at the exit where the input's end was seen, a replay stopped by its clock a
            // few instructions short of it, one guest event fewer (e2e session, now and then).
            vm.live_busy = false;
            vm.steps_fd = null;
            vm.live_ending = true;
            try vm.step_arm_at((try vm.moment()).vtime_ns + std.time.ns_per_ms, null);
            return;
        }
        try vm.live_line.appendSlice(allocator, chunk[0..result]);
    }
    const end = std.mem.indexOfScalar(u8, vm.live_line.items, '\n').?;
    const line = try allocator.dupe(u8, vm.live_line.items[0..end]);
    const rest = vm.live_line.items[end + 1 ..];
    std.mem.copyForwards(u8, vm.live_line.items[0..rest.len], rest);
    vm.live_line.items.len = rest.len;
    if (line.len == 0) return;
    vm.live_busy = true;
    vm.moment_commands_rest = line;
    try vm.step_arm(1, null);
}

/// A step the moment runs, on the timeline's own tape at the moment it ran: a replay of the
/// timeline runs it there again.
/// A step past what a replay of the tape reads (65,536 steps, 16 MiB) is refused before it runs,
/// room kept for the session's det:over, instead of a tape no replay can read (CE52, the Lean
/// replica of determinismo: nothing capped the steps a session recorded).
fn step_record(vm: *VM, step: []const u8) !void {
    const fd = vm.tape_fd orelse return;
    if (!step_taped(step)) return;
    if (!tape.step_fits(vm.tape_steps + 1, vm.tape_step_bytes + step_over.len, step.len)) return error.TapeStepsFull;
    tape.write_step(fd, step, (try vm.moment()).vtime_ns);
    vm.tape_steps += 1;
    vm.tape_step_bytes += step.len;
}

/// A session's checkpoint (det:checkpoint [name]), at the stop 1 ns after the step: its event
/// there, in every replay of the timeline as in the session (a snapshot of the timeline counts
/// its events, and a replay from one parts from its tape on a count that differs), then, a
/// session's own step with someone to save it (checkpoint_hook), the machine saved: a session
/// opened on the timeline at the event (`until event=session_checkpoint details.name=<name>`)
/// starts from it, not from boot. The event at the stop, not the step: the moment the event
/// names is then never before the machine saved (moment_ms rounds up), even on a millisecond's
/// edge. Then on to that millisecond's end, the step's end: the session's next step begins
/// there, at the moment a session opened at the event is held (a step begun inside the
/// millisecond replayed on the way to it: what the session did after the checkpoint). True
/// when that stop is armed.
fn session_checkpoint(vm: *VM, name: []const u8) !bool {
    vm.checkpoint_asked = null;
    var buffer: [checkpoint_name_max + 96]u8 = undefined;
    const event = try std.fmt.bufPrint(&buffer, "{{\"event\":\"session_checkpoint\",\"details\":{{\"name\":\"{s}\"}}}}", .{name});
    const now = try vm.moment();
    try vm.events.emit(now, event);
    vm.recent_note(now, event);
    const saving = vm.steps_own and vm.checkpoint_hook != null;
    std.debug.print("[determinismo] checkpoint: {{\"name\":\"{s}\",\"vtime_ns\":{d},\"saved\":{}}}\n", .{ name, now.vtime_ns, saving });
    if (saving) {
        const hook = vm.checkpoint_hook.?;
        try hook.save(hook.context, vm, .{ .idle = vm.arrival_idle });
    }
    const edge_ns = (now.vtime_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms * std.time.ns_per_ms;
    if (edge_ns == now.vtime_ns) return false;
    try vm.step_arm_at(edge_ns, null);
    return true;
}

/// A session's end (its input's), on its timeline's tape with its moment: the timeline ends
/// there, its replay too (det:over), what came from outside up to it from the tape.
fn session_end(vm: *VM) !void {
    vm.steps_fd = null;
    vm.session_over = true;
    if (vm.tape_fd) |fd| {
        assert(tape.step_fits(vm.tape_steps, vm.tape_step_bytes, step_over.len)); // Kept by step_record.
        tape.write_step(fd, step_over, (try vm.moment()).vtime_ns);
        vm.tape_steps += 1;
        vm.tape_step_bytes += step_over.len;
    }
}

/// Whether a step goes on its timeline's tape: every step a session ran, its waits and looks
/// too (det:until, det:wait, det:step, det:continue: the VMM's own), since where one stops is
/// where the next begins, exactly: a wait for an event stops at the event's own exit, and a
/// replay without it reached the next step's moment by its clock, a few instructions before
/// that exit (an interactive REPL session's replay: its relay's ready event 776 ns later, then
/// TapeSizeMismatch; phoenixNAP e2e, 2026-11-14). Not on it: the replay's own way to a step's
/// moment (det:at), and the platform's own (its hold and release, a session taking its
/// timeline over, its end).
fn step_taped(step: []const u8) bool {
    const platform = [_][]const u8{ "det:hold", "det:release", step_extend, step_over };
    for (platform) |own| if (std.mem.eql(u8, step, own)) return false;
    return !std.mem.startsWith(u8, step, step_at);
}

test step_taped {
    try std.testing.expect(step_taped("det:poke 0x1000=0f0b"));
    try std.testing.expect(step_taped("det-nodes exec redis redis-cli get a"));
    try std.testing.expect(step_taped("det:scenario-pause"));
    try std.testing.expect(step_taped("det:until 1500 event=nrepl_relay_ready"));
    try std.testing.expect(step_taped("det:wait 300"));
    try std.testing.expect(step_taped("det:regs"));
    try std.testing.expect(step_taped("det:fresh 7"));
    try std.testing.expect(step_taped("det:checkpoint loaded"));
    try std.testing.expect(!step_taped("det:at 15000000000"));
    try std.testing.expect(!step_taped("det:release"));
    try std.testing.expect(!step_taped("det:over"));
}

/// `det:extend`: where a session takes its timeline over (explore --extend puts it before the
/// session's own steps): one that listens for connections drops the recorded ones to come.
const step_extend = "det:extend";
/// `det:over`: where a session's timeline ended (its input's end, taped: session_end), its
/// replay's end too.
const step_over = "det:over";
/// `det:fresh <seed>`: a fresh future's seed taken (Options.fresh_seed puts it first at the
/// moment; a recorded session's tape has it, at that moment).
const step_fresh = "det:fresh ";
const step_at = "det:at ";
const step_ask = "det:ask ";
/// Marks a step another expanded into (det:ask's): run, not recorded.
const expansion_mark: u8 = 1;
/// How long a REPL's message may run, in virtual time, before its step ends without it (its
/// replies then come with the next steps').
const ask_timeout_ms = 600_000;
const step_wait = "det:wait ";
const step_until = "det:until ";
const step_regs = "det:regs";
const step_mem = "det:mem ";
const step_poke = "det:poke ";
const step_translate = "det:translate ";
const step_branches = "det:step ";
const step_break = "det:break ";
const step_watch = "det:watch ";
const step_continue = "det:continue";
/// The moment, nothing done (an interactive session's first step when none is asked).
pub const step_here = "det:here";
const step_collect = "det:collect";
/// The hits one det:collect says at most; the rest are counted (its window too long for what
/// it watches).
const collect_hits_max = 10_000;
/// `det:checkpoint [name]`: the machine saved where a session can come back to (session_checkpoint).
const step_checkpoint = "det:checkpoint";
/// A checkpoint's name, at most (it is queried: details.name=...).
const checkpoint_name_max = 128;

/// DR7's LEN field for a watched write of `size` bytes (the CPU's encoding), or null.
fn watch_length(size: u8) ?u64 {
    return switch (size) {
        1 => 0b00,
        2 => 0b01,
        8 => 0b10,
        4 => 0b11,
        else => null,
    };
}

test watch_length {
    try std.testing.expectEqual(@as(?u64, 0b11), watch_length(4));
    try std.testing.expectEqual(@as(?u64, 0b10), watch_length(8));
    try std.testing.expectEqual(@as(?u64, null), watch_length(3));
}

/// det:break's and det:watch's breakpoints given to KVM (KVM_SET_GUEST_DEBUG: DR0 an execute
/// breakpoint of one byte, DR1 a write of the watched size), or none.
fn debug_breakpoint_apply(vm: *VM) !void {
    var debug: kvm.GuestDebug = .{ .control = 0 };
    if (vm.breakpoint != null or vm.watchpoint != null) {
        debug.control = kvm.guestdbg_enable | kvm.guestdbg_use_hw_bp;
    }
    if (vm.breakpoint) |breakpoint| {
        debug.debugreg[0] = breakpoint.address;
        debug.debugreg[7] |= 0x1; // L0: DR0, an execute breakpoint (RW0 = LEN0 = 0).
    }
    if (vm.watchpoint) |watchpoint| {
        debug.debugreg[1] = watchpoint.address;
        // L1 (bit 2); RW1 (bits 20-21) 01, data writes; LEN1 (bits 22-23) the size's.
        debug.debugreg[7] |= (1 << 2) | (0b01 << 20) | (watch_length(watchpoint.size).? << 22);
    }
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_GUEST_DEBUG, @intFromPtr(&debug));
}

/// A breakpoint's hit (KVM_EXIT_DEBUG, DR6 saying which). An instruction's (DR0): not run yet,
/// RF set so that it runs once resumed without hitting again; its line has the calling
/// convention's argument registers. A watched write's (DR1): a trap, the writing instruction
/// done, the bytes written read at the hit. True when it is the stop det:continue asked for; in
/// a det:collect window it is said ("hit") and passed; any other hit is passed, the guest none
/// the wiser.
fn debug_breakpoint_hit(vm: *VM) !bool {
    const dr6 = vm.run.exit.debug.dr6;
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    const address_mask: u64 = 0x000f_ffff_ffff_f000;
    const execute = dr6 & 0b01 != 0;
    if (!execute and dr6 & 0b10 == 0) return false;
    if (execute) {
        regs.rflags |= 1 << 16; // RF: the breakpoint passes this instruction once.
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.SET_REGS, @intFromPtr(&regs));
    }
    const space: ?u64 = if (execute)
        (vm.breakpoint orelse return false).cr3
    else
        (vm.watchpoint orelse return false).cr3;
    if (space) |cr3| if (cr3 & address_mask != sregs.cr3 & address_mask) return false;
    if (vm.moment_reached) return false;
    const stopping = vm.continuing;
    if (!stopping) {
        const collect = if (vm.collect) |*collect| collect else return false;
        if (collect.hits == collect_hits_max) {
            collect.dropped += 1;
            return false;
        }
        collect.hits += 1;
    }
    const now = try vm.moment();
    var buffer: [1024]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    line.print("[determinismo] {s}: {{\"vtime_ns\":{d},\"branches\":{d},\"rip\":\"0x{x}\",\"cr3\":\"0x{x}\"", .{
        if (stopping) "break" else "hit", now.vtime_ns, now.branches, regs.rip, sregs.cr3,
    }) catch unreachable;
    if (execute) {
        line.print(",\"rdi\":\"0x{x}\",\"rsi\":\"0x{x}\",\"rdx\":\"0x{x}\",\"rcx\":\"0x{x}\",\"r8\":\"0x{x}\",\"r9\":\"0x{x}\"", .{
            regs.rdi, regs.rsi, regs.rdx, regs.rcx, regs.r8, regs.r9,
        }) catch unreachable;
        const vectors = try vm.vector_registers();
        for (vectors, 0..) |vector, index| line.print(",\"xmm{d}\":\"0x{x}\"", .{ index, vector }) catch unreachable;
    } else {
        const watchpoint = vm.watchpoint.?;
        const guest = GuestMemory{ .bytes = vm.memory };
        const bytes: ?[]const u8 = if (translate_space(guest, sregs.cr3, watchpoint.address)) |physical|
            guest.range(physical, watchpoint.size)
        else
            null;
        // The value as the guest's bytes (little-endian: hex in memory order, as det:mem's).
        line.print(",\"watch\":\"0x{x}\",\"size\":{d},\"hex\":", .{ watchpoint.address, watchpoint.size }) catch unreachable;
        if (bytes) |written| line.print("\"{x}\"", .{written}) catch unreachable else line.writeAll("null") catch unreachable;
    }
    line.writeAll("}\n") catch unreachable;
    std.debug.print("{s}", .{line.buffered()});
    if (!stopping) return false;
    vm.continuing = false;
    if (vm.target_branches != 0) try vm.target_set(0);
    return true;
}

/// On about `n` taken branches: a clock target n branches on (the guest's clock grows by
/// tsc_per_branch a branch, and by the modulation's share), the moment's own exact stop there.
fn step_arm_branches(vm: *VM, n: u64) !void {
    assert(vm.moment_reached);
    const state = try vm.det_state();
    const owed = if (vm.modulation) |m| m.owed_milli(state.branches, vm.tsc_per_branch) else 0;
    const slowdown: u64 = if (vm.modulation) |m| m.slowdown_permille else 0;
    const target_milli = state.tsc * 1000 + owed + n * vm.tsc_per_branch * (1000 + slowdown);
    vm.moment_tsc = (target_milli + 999) / 1000;
    vm.until = null;
    vm.until_hit = false;
    vm.moment_reached = false;
    vm.stepping = true;
    if (vm.target_branches != 0) try vm.target_set(0); // Re-armed at the next loop.
}

/// A guest virtual address's physical one through the 4-level page tables at `cr3` (the address
/// space det:regs and watch hits name); null when not mapped. 2 MiB and 1 GiB pages followed.
pub fn translate(guest: GuestMemory, cr3: u64, virtual: u64) ?u64 {
    const address_mask: u64 = 0x000f_ffff_ffff_f000;
    var table = cr3 & address_mask;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    for (shifts, 0..) |shift, level| {
        const index = (virtual >> shift) & 0x1ff;
        const bytes = guest.range(table + index * 8, 8) orelse return null;
        const entry = std.mem.readInt(u64, bytes[0..8], .little);
        if (entry & 1 == 0) return null; // Not present.
        const huge = level == 1 or level == 2;
        if (huge and entry & (1 << 7) != 0) {
            const size = @as(u64, 1) << shift;
            return (entry & address_mask & ~(size - 1)) | (virtual & (size - 1));
        }
        table = entry & address_mask;
    }
    return table | (virtual & 0xfff);
}

/// `translate`, and for a kernel-half address the space's kernel page table too: with page-table
/// isolation (PTI, on CPUs Meltdown affects: srv4's), a process's user CR3 is its kernel one with
/// bit 12 set, and maps no kernel half (the e2e debugging check stopped in user mode on srv4:
/// jiffies through CR3 0x8e41804 unmapped). Tried as given first: without PTI a page directory
/// is only 4 KiB aligned, bit 12 its own.
pub fn translate_space(guest: GuestMemory, cr3: u64, virtual: u64) ?u64 {
    if (translate(guest, cr3, virtual)) |physical| return physical;
    const kernel_half = virtual >= 0xffff_8000_0000_0000;
    const pti_user = cr3 & (1 << 12) != 0;
    if (!kernel_half or !pti_user) return null;
    return translate(guest, cr3 & ~@as(u64, 1 << 12), virtual);
}

test translate_space {
    // PTI's pair: the kernel PML4 at 0x2000 maps kernel address 0xffff_8000_0000_1234 (PML4
    // index 256 -> PDPT 0x4000 -> a 1 GiB page at 0), the user one at 0x3000 maps nothing there.
    var ram: [5 * 4096]u8 align(8) = @splat(0);
    const guest = GuestMemory{ .bytes = &ram };
    std.mem.writeInt(u64, ram[0x2000 + 256 * 8 ..][0..8], 0x4000 | 1, .little);
    std.mem.writeInt(u64, ram[0x4000..][0..8], 0x0 | 1 | (1 << 7), .little);
    const kernel: u64 = 0xffff_8000_0000_1234;
    const user_cr3: u64 = 0x3000 | 4; // Bit 12 set, PCID 4: srv4's 0x8e41804 in small.
    try std.testing.expectEqual(@as(?u64, null), translate(guest, user_cr3, kernel));
    try std.testing.expectEqual(@as(?u64, 0x1234), translate_space(guest, user_cr3, kernel));
    try std.testing.expectEqual(@as(?u64, 0x1234), translate_space(guest, 0x2000, kernel));
    // A user address is never looked up in the kernel half.
    try std.testing.expectEqual(@as(?u64, null), translate_space(guest, user_cr3, 0x1234));
}

test translate {
    // Four tables in 5 pages of guest RAM: PML4 at 0x1000 -> PDPT 0x2000 -> PD 0x3000 -> PT 0x4000
    // -> the page at 0x0 for virtual 0x40_0000_1234 (indexes 0, 1, 0, 1 here), and a 2 MiB page.
    var ram: [5 * 4096]u8 align(8) = @splat(0);
    const guest = GuestMemory{ .bytes = &ram };
    const put = struct {
        fn at(bytes: []u8, address: u64, value: u64) void {
            std.mem.writeInt(u64, bytes[@intCast(address)..][0..8], value, .little);
        }
    }.at;
    const virtual: u64 = (1 << 30) | (1 << 12) | 0x234; // PDPT index 1, PT index 1.
    put(&ram, 0x1000, 0x2000 | 1);
    put(&ram, 0x2000 + 1 * 8, 0x3000 | 1);
    put(&ram, 0x3000, 0x4000 | 1);
    put(&ram, 0x4000 + 1 * 8, 0x0000 | 1);
    try std.testing.expectEqual(@as(?u64, 0x234), translate(guest, 0x1000, virtual));
    // Not present: PDPT index 2.
    try std.testing.expectEqual(@as(?u64, null), translate(guest, 0x1000, 2 << 30));
    // A 2 MiB page at PD index 1 (PDPT index 1 again): its frame 0x20_0000.
    put(&ram, 0x3000 + 1 * 8, 0x20_0000 | 1 | (1 << 7));
    try std.testing.expectEqual(@as(?u64, 0x20_0000 + 0x1234), translate(guest, 0x1000, (1 << 30) | (1 << 21) | 0x1234));
}

/// One debugger step (det:regs, det:mem, det:poke, det:translate), its answer printed.
fn debug_step(vm: *VM, step: []const u8) !void {
    if (std.mem.eql(u8, step, step_regs)) return vm.debug_regs();
    if (std.mem.startsWith(u8, step, step_mem)) {
        var words = std.mem.tokenizeScalar(u8, step[step_mem.len..], ' ');
        const address = try std.fmt.parseInt(u64, words.next() orelse return error.BadStep, 0);
        const size = try std.fmt.parseInt(u64, words.next() orelse "64", 0);
        return vm.debug_mem(address, size);
    }
    if (std.mem.startsWith(u8, step, step_poke)) return vm.debug_poke(std.mem.trim(u8, step[step_poke.len..], " "));
    var words = std.mem.tokenizeScalar(u8, step[step_translate.len..], ' ');
    const space = words.next() orelse return error.BadStep;
    const cr3 = if (std.mem.eql(u8, space, "current")) blk: {
        var sregs: kvm.Sregs = undefined;
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
        break :blk sregs.cr3;
    } else try std.fmt.parseInt(u64, space, 0);
    const virtual = try std.fmt.parseInt(u64, words.next() orelse return error.BadStep, 0);
    const guest = GuestMemory{ .bytes = vm.memory };
    if (translate_space(guest, cr3, virtual)) |physical| {
        std.debug.print("[determinismo] translate: {{\"cr3\":\"0x{x}\",\"virtual\":\"0x{x}\",\"physical\":\"0x{x}\"}}\n", .{ cr3, virtual, physical });
    } else {
        std.debug.print("[determinismo] translate: {{\"cr3\":\"0x{x}\",\"virtual\":\"0x{x}\",\"physical\":null}}\n", .{ cr3, virtual });
    }
}

/// The vCPU's registers at the moment, a JSON line (det:regs).
fn debug_regs(vm: *VM) !void {
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_SREGS, @intFromPtr(&sregs));
    const vectors = try vm.vector_registers();
    const now = try vm.moment();
    std.debug.print("[determinismo] regs: {{\"vtime_ns\":{d},\"branches\":{d},\"rip\":\"0x{x}\",\"rsp\":\"0x{x}\"," ++
        "\"rbp\":\"0x{x}\",\"rax\":\"0x{x}\",\"rbx\":\"0x{x}\",\"rcx\":\"0x{x}\",\"rdx\":\"0x{x}\",\"rsi\":\"0x{x}\"," ++
        "\"rdi\":\"0x{x}\",\"r8\":\"0x{x}\",\"r9\":\"0x{x}\",\"rflags\":\"0x{x}\",\"cr3\":\"0x{x}\",\"xmm0\":\"0x{x}\"," ++
        "\"xmm1\":\"0x{x}\",\"xmm2\":\"0x{x}\",\"xmm3\":\"0x{x}\",\"xmm4\":\"0x{x}\",\"xmm5\":\"0x{x}\",\"xmm6\":\"0x{x}\"," ++
        "\"xmm7\":\"0x{x}\"}}\n", .{
        now.vtime_ns, now.branches, regs.rip,   regs.rsp,   regs.rbp,    regs.rax,  regs.rbx,   regs.rcx,   regs.rdx,
        regs.rsi,     regs.rdi,     regs.r8,    regs.r9,    regs.rflags, sregs.cr3, vectors[0], vectors[1], vectors[2],
        vectors[3],   vectors[4],   vectors[5], vectors[6], vectors[7],
    });
}

/// The low 64 bits of xmm0 to xmm7, where x86-64's calling convention passes floating-point
/// arguments (a double whole, a float in the low 32), from the vCPU's XSAVE area (its legacy
/// region: xmm0 at byte 160, 16 bytes each).
fn vector_registers(vm: *VM) ![8]u64 {
    var xsave: kvm.Xsave = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_XSAVE, @intFromPtr(&xsave));
    var low: [8]u64 = undefined;
    for (&low, 0..) |*vector, index| {
        const at = 160 / 4 + 4 * index; // In u32s.
        vector.* = @as(u64, xsave.region[at]) | @as(u64, xsave.region[at + 1]) << 32;
    }
    return low;
}

/// Guest physical [address, address + size) at the moment, hex (det:mem): 4 KiB at most.
fn debug_mem(vm: *VM, address: u64, size: u64) !void {
    if (size == 0 or size > 4096) return error.BadStep;
    const guest = GuestMemory{ .bytes = vm.memory };
    const bytes = guest.range(address, size) orelse return error.BadStep;
    std.debug.print("[determinismo] mem: {{\"address\":\"0x{x}\",\"size\":{d},\"hex\":\"{x}\"}}\n", .{ address, size, bytes });
}

/// "<address>=<hex>[,...]" written into guest RAM at the moment (det:poke): a step, so a
/// session's script replays it where it ran.
fn debug_poke(vm: *VM, text: []const u8) !void {
    const guest = GuestMemory{ .bytes = vm.memory };
    var entries = std.mem.splitScalar(u8, text, ',');
    while (entries.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadStep;
        const address = std.fmt.parseInt(u64, entry[0..equals], 0) catch return error.BadStep;
        var bytes: [4096]u8 = undefined;
        const hex = entry[equals + 1 ..];
        if (hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > bytes.len) return error.BadStep;
        const value = std.fmt.hexToBytes(&bytes, hex) catch return error.BadStep;
        const target = guest.range(address, value.len) orelse return error.BadStep;
        @memcpy(target, value);
        std.debug.print("[determinismo] poke: 0x{x} = {s} ({d} bytes)\n", .{ address, hex, value.len });
    }
}

/// Runs on from now: for `ms` of virtual time, or until an event matches `condition` (within
/// `ms`, unless 0); the moment that ends it continues the script (moment_arrive).
fn step_arm(vm: *VM, ms: u64, condition: ?*const query.Condition) !void {
    const now = try vm.moment();
    const limited = condition == null or ms > 0;
    return vm.step_arm_at(if (limited) now.vtime_ns + ms * std.time.ns_per_ms else null, condition);
}

/// Runs on to a moment of virtual time (null: none, the condition alone), or until an event
/// matches `condition` before it.
fn step_arm_at(vm: *VM, vtime_ns: ?u64, condition: ?*const query.Condition) !void {
    assert(vm.moment_reached);
    vm.moment_tsc = if (vtime_ns) |ns| ns * tsc_per_ns else null;
    vm.until = condition;
    vm.until_hit = false;
    vm.moment_reached = false;
    vm.stepping = true;
    if (vm.target_branches != 0) try vm.target_set(0); // Re-armed at the next loop.
}

/// After a step: the next one, or the script's end (the run's end, unless it continues).
fn steps_next(vm: *VM) !?Outcome {
    if (vm.moment_commands_rest.len > 0 or try vm.steps_read()) {
        try vm.moment_command_next();
        return null;
    }
    if (!vm.steps_live) vm.moment_printing = false;
    if (!vm.moment_continue) return .command_done;
    return null;
}

/// Arms (or with 0 cancels, together with any soft deadline) the exact branch-count stop.
pub fn target_set(vm: *VM, target_branches: u64) !void {
    assert(vm.deterministic);
    var target = target_branches;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_TARGET, @intFromPtr(&target));
    if (target_branches == 0) try vm.soft_set(0);
    vm.target_branches = target_branches;
}

fn soft_set(vm: *VM, soft_tsc: u64) !void {
    var soft = soft_tsc;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_SET_SOFT_TSC, @intFromPtr(&soft));
    vm.soft_tsc = soft_tsc;
}

/// At an exit the VMM handles anyway (an exact point, like a soft stop): fire a timer whose
/// deadline has passed instead of waiting for its soft or hard stop.
fn timer_due(vm: *VM) !void {
    if (!vm.deterministic or vm.timer_slack_tsc == 0) return; // No slack: stops are exact.
    const deadline = vm.pit.deadline_tsc() orelse return;
    const state = try vm.det_state();
    if (state.tsc < deadline + vm.timer_delay_tsc) return;
    // Whatever the target: a hold point or a moment armed before the timer's hard stop does not
    // move where it fires.
    try vm.target_set(0);
    try vm.timer_fire();
    vm.stats.exit_timer_fires += 1;
}

fn timer_fire(vm: *VM) !void {
    assert(vm.pit.armed);
    if (vm.vtime_limit_tsc) |limit| if (vm.pit.deadline_tsc()) |tsc| {
        if (tsc >= limit) vm.over_limit = true;
    };
    // The timer fires at a point of the execution's own (its deadline), idle or not: the first
    // past each second is a checkpoint.
    if (vm.events.log_fd != null) if (vm.pit.deadline_tsc()) |tsc| {
        if (tsc / tsc_per_ns >= vm.checkpoint_next_ns) {
            const now = try vm.moment();
            vm.events.checkpoint(now);
            vm.checkpoint_next_ns = (now.vtime_ns / checkpoint_interval_ns + 1) * checkpoint_interval_ns;
        }
    };
    try vm.trace("timer", vm.pit.fired);
    vm.pit.fire();
    vm.stats.timer_fires += 1;
    try vm.irq_pulse(PIT.irq);
}

/// A line the guest wrote to its console, done: the kernel's (printk's, "[   13.006075] ...") an
/// event at its moment, from source "kernel" (Antithesis's journal: ext4 aborting its journal,
/// the OOM killer, a task hung), beside the nodes' output. The console's writes are the guest's
/// own exits: the same moments in every replay.
fn console_line(vm: *VM) !void {
    defer {
        vm.serial.line_count = 0;
        vm.serial.line_done = false;
    }
    if (!vm.deterministic) return;
    const line = std.mem.trimEnd(u8, vm.serial.line[0..vm.serial.line_count], "\r");
    if (!kernel_line(line)) return;
    var buffer: [Serial.line_size_max * 6 + 128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"output\":{{\"source\":\"kernel\",\"stream\":\"console\",\"text\":{f}}}}}", .{
        std.json.fmt(line, .{}),
    }) catch return;
    try vm.events.emit(try vm.moment(), writer.buffered());
}

/// printk's own: "[" then the seconds since boot, right-aligned, then "] ".
fn kernel_line(line: []const u8) bool {
    if (line.len < 3 or line[0] != '[') return false;
    const close = std.mem.indexOfScalar(u8, line[0..@min(line.len, 20)], ']') orelse return false;
    for (line[1..close]) |byte| if (!std.ascii.isDigit(byte) and byte != ' ' and byte != '.') return false;
    return close > 1;
}

test kernel_line {
    try std.testing.expect(kernel_line("[   13.006075] Aborting journal on device dm-0-8."));
    try std.testing.expect(kernel_line("[12345.000001] Out of memory: Killed process 42"));
    try std.testing.expect(!kernel_line("[guest] done, status 0"));
    try std.testing.expect(!kernel_line("[] nothing"));
    try std.testing.expect(!kernel_line("Booting the kernel"));
}

/// Virtual time between checkpoints in the events.
const checkpoint_interval_ns = std.time.ns_per_s;

const Idle = enum { timer, moment, none };

/// The guest halted with nothing to do: skip to what wakes it, or to the moment.
fn idle(vm: *VM) !?Outcome {
    assert(vm.deterministic);
    // A live session past its moment: at a person's pace, not an idle guest's.
    if (vm.steps_live and vm.steps_fd != null and vm.moment_reached) try vm.live_pace(true);
    return switch (try vm.idle_skip()) {
        .timer => null,
        .moment => blk: {
            // A moment in an idle stretch: its steps run with the guest halted, and when they
            // gave it nothing to do (the VMM's own: a wait, a debugger's look or step), the skip
            // goes on as a timeline without the moment's (run_loop): resuming the guest would
            // run its idle loop once more, and the timeline part from the recorded one (a
            // det:wait 1 in idle moved every later event by 106 branches, phoenixNAP 2026-11-13).
            vm.arrival_idle = true;
            defer vm.arrival_idle = false;
            const outcome = try vm.moment_arrive();
            if (outcome == null and vm.action_pending == null) vm.idle_pending = true;
            break :blk outcome;
        },
        .none => .hlt, // Halted with no timer: never wakes.
    };
}

/// The guest halted with nothing to do: jump virtual time to the next deadline. A hold point on
/// the way pauses there and the skip goes on: the guest does not wake (resuming it would run its
/// idle loop once more, which a timeline without the hold point does not).
fn idle_skip(vm: *VM) !Idle {
    assert(vm.deterministic);
    while (true) {
        const deadline = vm.deadline_next() orelse return .none;
        const state = try vm.det_state();
        if (deadline.tsc > state.tsc) {
            var skipped_tsc = deadline.tsc - state.tsc;
            _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ADD_TSC, @intFromPtr(&skipped_tsc));
            vm.state_cached = null;
            vm.stats.idle_tsc += skipped_tsc;
        }
        if (vm.target_branches != 0) try vm.target_set(0);
        assert(vm.target_branches == 0);
        try vm.trace("idle", deadline.tsc);
        vm.stats.idle_skips += 1;
        switch (deadline.kind) {
            .moment => return .moment,
            .hold => try vm.hold_reach(.{ .idle = true }),
            .timer => {
                try vm.timer_fire();
                return .timer;
            },
        }
    }
}

/// Owner of a timeline's hold points (main.zig's holders): told when the timeline reached new
/// behaviors (it may arm a hold point then, `hold_arm`), and called at the hold point.
pub const ForkHook = struct {
    context: *anyopaque,
    /// A fork asked at `vtime_ns`: the machine saved just after, before its next pull (the
    /// fork's index).
    request: *const fn (context: *anyopaque, vm: *VM, vtime_ns: u64) anyerror!void,
};

/// Who saves a session's machine at its checkpoints (det:checkpoint): `save` writes it as it is
/// now, at the checkpoint's stop (a child writes its pages, the session going on).
pub const CheckpointHook = struct {
    context: *anyopaque,
    save: *const fn (context: *anyopaque, vm: *VM, point: Hold.Point) anyerror!void,
};

pub const Hold = struct {
    context: *anyopaque,
    behaviors: *const fn (context: *anyopaque, vm: *VM, first_new: u32) anyerror!void,
    reached: *const fn (context: *anyopaque, vm: *VM, point: Point) anyerror!void,

    pub const Point = struct {
        /// Inside an idle skip: the guest is halted, and a replay from here goes on skipping
        /// (Options.from_hold). Else the guest stopped at an exact branch count.
        idle: bool,
    };
};

/// Pauses the run at `vtime_ns` (later than now) for the hold's owner, in place of a hold point
/// armed already (one at a time).
pub fn hold_arm(vm: *VM, vtime_ns: u64) !void {
    assert(vm.deterministic);
    assert(vm.hold != null);
    vm.hold_tsc = vtime_ns * tsc_per_ns;
    // An armed stop is re-armed with the new hold point in view (a timer's at the same branch
    // count: timer_arm counts from the deadline, not from now).
    if (vm.target_branches != 0 and vm.target_kind != .moment) try vm.target_set(0);
}

/// After an exit that may have brought events: new behaviors are the hold point owner's news.
fn hold_notice(vm: *VM) !void {
    const hold = vm.hold orelse return;
    const count = vm.events.behavior_count;
    if (count == vm.hold_behaviors) return;
    const first_new = vm.hold_behaviors;
    vm.hold_behaviors = count;
    try hold.behaviors(hold.context, vm, first_new);
}

fn hold_reach(vm: *VM, point: Hold.Point) !void {
    vm.hold_tsc = null;
    vm.target_kind = .timer;
    const hold = vm.hold orelse return;
    try hold.reached(hold.context, vm, point);
}

fn now_tsc(vm: *VM) !u64 {
    if (vm.deterministic) return (try vm.det_state()).tsc;
    if (vm.fast) return vm.fast_guest_tsc(); // The VMM's PIT on host time.
    return 0; // KVM's own PIT handles the ports; the RTC reads the epoch.
}

fn handle_mmio(vm: *VM) !void {
    assert(vm.run.exit_reason == .mmio);
    vm.stats.exits.getPtr(.mmio).* += 1;
    const mmio = &vm.run.exit.mmio;
    assert(mmio.len >= 1 and mmio.len <= 8);
    const data = mmio.data[0..mmio.len];
    const index = vm.disk_index(mmio.phys_addr) orelse {
        if (mmio.is_write == 0) @memset(data, 0xff); // Nothing else is memory-mapped.
        return;
    };
    const block = &vm.blocks[index];
    const offset = mmio.phys_addr - VirtioBlock.address_base - index * VirtioBlock.address_size;
    if (mmio.is_write == 0) return block.read(offset, data);
    if (block.write(offset, data, .{ .bytes = vm.memory })) {
        try vm.trace("disk", index);
        try vm.irq_pulse(VirtioBlock.irq);
    }
}

fn disk_index(vm: *const VM, address: u64) ?u32 {
    const base = VirtioBlock.address_base;
    if (address < base) return null;
    const index = (address - base) / VirtioBlock.address_size;
    if (index >= vm.block_count) return null;
    return @intCast(index);
}

/// Kernel parameters announcing `count` disks to the guest's virtio_mmio driver.
pub fn disks_cmdline(arena: std.mem.Allocator, count: u32) ![]const u8 {
    assert(count <= disks_max);
    var parts: [disks_max][]const u8 = undefined;
    for (parts[0..count], 0..) |*part, index| {
        const address = VirtioBlock.address_base + index * VirtioBlock.address_size;
        part.* = try std.fmt.allocPrint(arena, "virtio_mmio.device=4K@0x{x}:{d}", .{
            address, VirtioBlock.irq,
        });
    }
    return std.mem.join(arena, " ", parts[0..count]);
}

fn handle_io(vm: *VM) !?Outcome {
    const io = vm.run.exit.io;
    assert(io.size == 1 or io.size == 2 or io.size == 4);
    assert(io.count >= 1 and io.count <= page_size);
    const data: [*]u8 = @ptrFromInt(@intFromPtr(vm.run) + io.data_offset);
    vm.stats.exits.getPtr(if (Serial.contains(io.port)) .io_serial else .io_other).* += 1;
    vm.stats.io_ports[io.port] +|= 1;
    for (0..io.count) |index| {
        const bytes = data[index * io.size ..][0..io.size];
        if (io.direction == kvm.Run.io_out) {
            if (try vm.io_out(io.port, bytes)) |outcome| return outcome;
        } else {
            try vm.io_in(io.port, bytes);
        }
    }
    return null;
}

fn io_out(vm: *VM, port: u16, bytes: []const u8) !?Outcome {
    assert(bytes.len >= 1 and bytes.len <= 4);
    if (Serial.contains(port)) {
        if (vm.serial.write(port, bytes[0])) try vm.irq_pulse(Serial.irq);
        if (vm.serial.line_done) try vm.console_line();
        return null;
    }
    switch (port) {
        RTC.port_index, RTC.port_data => vm.rtc.write(port, bytes[0]),
        PIT.port_mode => vm.pit.write_mode(bytes[0], try vm.now_tsc()),
        // A 16-bit write is a count's low byte then its high byte (det_pit_word).
        PIT.port_channel_0 => for (bytes) |byte| {
            const loaded = vm.pit.write_count(byte, try vm.now_tsc());
            if (loaded and vm.target_branches != 0) try vm.target_set(0); // Re-armed next loop.
        },
        port_doorbell => {
            if (bytes.len != 4) return error.BadGuestRequest;
            const setup_was_complete = vm.events.setup_complete != null;
            try vm.handle_request(std.mem.readInt(u32, bytes[0..4], .little));
            if (vm.until_hit and !vm.moment_reached) {
                if (try vm.moment_arrive()) |outcome| return outcome;
            }
            if (vm.end_hit and !vm.moment_reached) {
                vm.end_hit = false;
                std.debug.print("[determinismo] the scenario ended: held here, the next step from its end\n", .{});
                if (try vm.moment_arrive()) |outcome| return outcome;
            }
            if (vm.strategy_ended) return .strategy_ended;
            // A step ends: a command's end, or a background command's start (its end ends none).
            const step_ended = if (vm.exec_background)
                vm.events.last_event_is("exec_start")
            else
                vm.events.last_event_is("exec_done");
            const command_finished = step_ended and vm.events.count != vm.exec_done_handled and
                vm.moment_reached and !vm.stepping;
            if (command_finished) vm.exec_done_handled = vm.events.count;
            if (command_finished and (vm.moment_commands_rest.len > 0 or try vm.steps_read())) {
                try vm.moment_command_next();
            } else if (command_finished) {
                if (vm.moment_command != null) {
                    if (!vm.steps_live) vm.moment_printing = false;
                    if (!vm.moment_continue) return .command_done;
                }
            }
            if (vm.stop_at_setup_complete) {
                const setup_is_complete = vm.events.setup_complete != null;
                if (!setup_was_complete and setup_is_complete) return .setup_complete;
            }
        },
        port_debug_exit => return .{ .debug_exit = bytes[0] },
        else => {}, // Writes to absent devices are dropped, as on an ISA bus.
    }
    return null;
}

fn io_in(vm: *VM, port: u16, bytes: []u8) !void {
    assert(bytes.len >= 1 and bytes.len <= 4);
    if (Serial.contains(port)) {
        bytes[0] = vm.serial.read(port);
        return;
    }
    switch (port) {
        RTC.port_index, RTC.port_data => {
            bytes[0] = vm.rtc.read(port, try vm.now_tsc() / cpuid.tsc_hz);
        },
        PIT.port_channel_0 => bytes[0] = vm.pit.read_count(try vm.now_tsc()),
        0x61 => bytes[0] = 0, // Speaker and PIT channel 2 gate: unused.
        else => @memset(bytes, 0xff), // Absent devices float high, as on an ISA bus.
    }
}

pub fn moment(vm: *VM) !Events.Moment {
    if (!vm.deterministic) return .{ .vtime_ns = 0, .branches = 0 };
    const state = try vm.det_state();
    // With CPU modulation, the time the next exit adds to the guest's clock for the branches
    // run since the last one (modulate): none at the guest's own exits, which add it first; at a
    // moment's stop, between them, the moment is that much later than the clock reads (a rewind
    // read 180 us early, a deadline 1.7 us).
    const owed_tsc = if (vm.modulation) |m| m.owed_milli(state.branches, vm.tsc_per_branch) / 1000 else 0;
    return .{
        .vtime_ns = @divFloor(state.tsc + owed_tsc, tsc_per_ns),
        .branches = vm.branches_offset + state.branches,
    };
}

/// Whether an event matches `--until` (the events' parse buffer is free again after emit).
fn until_matches(vm: *VM, moment_now: Events.Moment, line: []const u8) bool {
    const condition = vm.until orelse return false;
    if (!vm.condition_matches(condition, moment_now, line)) return false;
    std.debug.print("[determinismo] until: {s}\n", .{line});
    return true;
}

fn condition_matches(vm: *VM, condition: *const query.Condition, moment_now: Events.Moment, line: []const u8) bool {
    if (!condition.may_match(line)) return false;
    var fba = std.heap.FixedBufferAllocator.init(vm.events.parse_buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch
        return false;
    const event: query.Event = .{
        .value = value,
        .vtime_ns = moment_now.vtime_ns,
        .seq = vm.events.count,
    };
    return condition.matches(event);
}

/// One request from the guest module: a page holding { op: u32, len: u32, result: u64, data }.
fn handle_request(vm: *VM, address: u32) !void {
    if (address % page_size != 0) return error.BadGuestRequest;
    // The guest module's page is below 4 GiB (its doorbell carries 32 bits): low RAM.
    const guest = GuestMemory{ .bytes = vm.memory };
    if (address + page_size > guest.low_size()) return error.BadGuestRequest;
    const page = vm.memory[address..][0..page_size];
    const operation = std.mem.readInt(u32, page[0..4], .little);
    const size = std.mem.readInt(u32, page[4..8], .little);
    if (size > page_size - request_header_size) return error.BadGuestRequest;
    const data = page[request_header_size..][0..size];
    try vm.trace("request", @as(u64, operation) << 32 | size);
    switch (operation) {
        request_operation_emit => {
            // The writing thread's name and id follow the data when the guest module had room.
            const has_source = std.mem.readInt(u64, page[8..16], .little) == 2 and
                size + source_size_max + 4 <= page_size - request_header_size;
            const source = if (has_source)
                source_trim(page[request_header_size + size ..][0..source_size_max])
            else
                "";
            const tid: u32 = if (has_source)
                std.mem.readInt(u32, page[request_header_size + size + source_size_max ..][0..4], .little)
            else
                0;
            // One event per line: SDKs that buffer may write several lines at once.
            const moment_now = try vm.moment();
            var lines = std.mem.tokenizeScalar(u8, data, '\n');
            while (lines.next()) |line| {
                vm.decision_note(line, tid);
                try vm.events.emit(moment_now, line);
                vm.recent_note(moment_now, line);
                // A fork asked (sdk.fork), where someone clones machines (a session's explore).
                for ([_]RequestKind{ .serve, .egress, .ingress }) |kind| {
                    if (std.mem.startsWith(u8, line, request_prefixes[@backingInt(kind)])) try vm.request_note(tid, kind, line);
                }
                if (vm.fork_hook) |hook| if (std.mem.startsWith(u8, line, "{\"fork\":")) {
                    try hook.request(hook.context, vm, moment_now.vtime_ns);
                };
                // The fast VM explored from here (det:explore-here: its other CPUs offline).
                if (vm.fast) if (std.mem.startsWith(u8, line, "{\"explore_here\":")) try vm.explore_here_save();
                // The dev mode's moments, said (`run` prints no guest events otherwise).
                if (vm.fast) for ([_][]const u8{ "dev_waiting", "dev_go", "explore_here_done" }) |name| {
                    if (std.mem.indexOf(u8, line, name) != null and std.mem.startsWith(u8, line, "{\"event\":")) {
                        std.debug.print("[determinismo] dev mode: {s}\n", .{line});
                    }
                };
                vm.exec_background = std.mem.startsWith(u8, line, "{\"event\":\"exec_") and
                    std.mem.indexOf(u8, line, "\"background\":true") != null;
                // Causality's futures: their faults, and the code they ran (coverage events) for
                // the lines' effects (statistical debugging).
                if (vm.faults_record_fd) |fd| if (std.mem.startsWith(u8, line, "{\"event\":\"fault\",") or
                    std.mem.startsWith(u8, line, "{\"event\":\"coverage\","))
                {
                    _ = linux.write(fd, line.ptr, line.len);
                    _ = linux.write(fd, "\n", 1);
                };
                try vm.checkpoint(moment_now);
                if (vm.until != null and !vm.until_hit and !vm.moment_reached) {
                    vm.until_hit = vm.until_matches(moment_now, line);
                }
                if (vm.hold_owed and !vm.moment_reached and std.mem.startsWith(u8, line, "{\"event\":\"scenario_end\"")) {
                    vm.end_hit = true;
                }
                if (vm.ask_until) |condition| if (!vm.ask_until_hit) {
                    vm.ask_until_hit = vm.condition_matches(condition, moment_now, line);
                };
                if (vm.advisor) |advisor| {
                    if (try advisor.event(advisor.context, moment_now, source, line)) vm.strategy_ended = true;
                }
                if (vm.pull_note) |note| note.event(note.context, moment_now.vtime_ns);
                if (vm.moment_printing) {
                    std.debug.print("[guest @ {d}ns] {s}\n", .{ moment_now.vtime_ns, line });
                }
            }
        },
        request_operation_action => {
            const action = vm.action_pending orelse "";
            vm.action_pending = null;
            assert(action.len <= step_size_max);
            const action_size: u32 = @intCast(action.len);
            @memcpy(page[request_header_size..][0..action_size], action[0..action_size]);
            std.mem.writeInt(u32, page[4..8], action_size, .little);
        },
        request_operation_random => {
            if (size == 0) return error.BadGuestRequest;
            // The guest module puts the asking process's name first; the answer replaces it.
            var source_buffer: [source_size_max]u8 = undefined;
            const source = source_trim(page[request_header_size..][0..source_size_max]);
            @memcpy(source_buffer[0..source.len], source);
            // The asking thread's id after its name (the guest module flags it): read before the
            // answer overwrites the page.
            if (std.mem.readInt(u64, page[8..16], .little) != 2) return error.BadGuestRequest;
            vm.pull_tid = std.mem.readInt(u32, page[request_header_size + source_size_max ..][0..4], .little);
            try vm.decide_random(data, source_buffer[0..source.len]);
        },
        else => return error.BadGuestRequest,
    }
}

pub const ServeReply = struct { status: u16, body: []const u8 };
pub const ServeCall = *const fn (arena: std.mem.Allocator, url: []const u8, request: []const u8) anyerror!ServeReply;
pub const serve_reply_size_max = 16 << 10;

/// The guest's request to serve, answered (serve_status, serve_reply): 0 when there is no serve
/// (not a session) or no request.
fn serve_answer(vm: *VM) !void {
    vm.serve_reply.clearRetainingCapacity();
    vm.serve_reply_at = 0;
    vm.serve_status = 0;
    const url = vm.serve_url orelse return;
    const call = vm.serve_call orelse return;
    const request = vm.request_of(.serve);
    if (request.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const reply = call(arena_state.allocator(), url, request) catch |err| reply: {
        std.debug.print("[determinismo] the guest's call to serve: {t}\n", .{err});
        break :reply ServeReply{ .status = 502, .body = "{\"error\":\"the call to serve failed\"}" };
    };
    vm.serve_status = reply.status;
    try vm.serve_reply.appendSlice(std.heap.page_allocator, reply.body[0..@min(reply.body.len, serve_reply_size_max)]);
}

const egress_connections_max = 64;
const egress_wait_ms = 1000;

const EgressSocket = struct {
    id: u32 = 0,
    fd: linux.fd_t = -1,
    /// The process that connected it: a branch forked from a holder inherits the descriptor,
    /// and two processes on one TLS connection would garble it (the child answers reset).
    pid: linux.pid_t = 0,
    /// A send since the last bytes received: a recv waits for the reply (up to egress_wait_ms
    /// of wall time, the machine paused: none of its virtual time passes).
    awaiting: bool = false,
};

/// The guest's egress request (sdk.egress), answered (egress_status, egress_reply).
fn egress_answer(vm: *VM) !void {
    vm.egress_reply.clearRetainingCapacity();
    vm.egress_reply_at = 0;
    vm.egress_status = @backingInt(EgressStatus.refused);
    const request = vm.request_of(.egress);
    if (request.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Request = struct { egress: struct { op: []const u8 = "", id: u32 = 0, target: []const u8 = "", data: []const u8 = "" } = .{} };
    const asked = (std.json.parseFromSliceLeaky(Request, arena, request, .{ .ignore_unknown_fields = true }) catch return).egress;
    const op = asked.op;
    if (std.mem.eql(u8, op, "open")) return vm.egress_open(asked.id, asked.target);
    const slot = for (&vm.egress_sockets) |*slot| {
        if (slot.id == asked.id and slot.fd >= 0) break slot;
    } else {
        vm.egress_status = @backingInt(EgressStatus.reset); // Opened before a branch point.
        return;
    };
    if (slot.pid != linux.getpid()) {
        _ = linux.close(slot.fd); // This process's copy only: the socket is another's.
        slot.* = .{};
        vm.egress_status = @backingInt(EgressStatus.reset);
        return;
    }
    if (std.mem.eql(u8, op, "close")) {
        _ = linux.close(slot.fd);
        slot.* = .{};
        vm.egress_status = @backingInt(EgressStatus.ok);
    } else if (std.mem.eql(u8, op, "send")) {
        const bytes = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(asked.data) catch return);
        std.base64.standard.Decoder.decode(bytes, asked.data) catch return;
        var rest: []const u8 = bytes;
        while (rest.len > 0) {
            const result = linux.write(slot.fd, rest.ptr, rest.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS) {
                vm.egress_status = @backingInt(EgressStatus.end);
                return;
            }
            rest = rest[result..];
        }
        slot.awaiting = true;
        vm.egress_status = @backingInt(EgressStatus.ok);
    } else if (std.mem.eql(u8, op, "recv")) {
        var fds = [_]linux.pollfd{.{ .fd = slot.fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, if (slot.awaiting) egress_wait_ms else 0);
        vm.egress_status = @backingInt(EgressStatus.ok);
        if (linux.errno(ready) != .SUCCESS or ready == 0) return; // Nothing yet.
        var buffer: [protocol.egress_recv_max]u8 = undefined;
        const result = linux.read(slot.fd, &buffer, buffer.len);
        if (linux.errno(result) != .SUCCESS or result == 0) {
            vm.egress_status = @backingInt(EgressStatus.end);
            return;
        }
        slot.awaiting = false;
        try vm.egress_reply.appendSlice(std.heap.page_allocator, buffer[0..result]);
    }
}

fn egress_open(vm: *VM, id: u32, target: []const u8) void {
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return;
    const host = target[0..colon];
    const port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch return;
    if (!egress_rules.allow_matches(vm.egress_allow, host, port)) {
        std.debug.print("[determinismo] egress to {s} refused (explore --egress allows {d} entries)\n", .{ target, vm.egress_allow.len });
        return;
    }
    const io = vm.egress_io orelse return;
    const slot = for (&vm.egress_sockets) |*slot| {
        if (slot.fd < 0) break slot;
    } else return;
    const name = std.Io.net.HostName.init(host) catch return;
    const stream = name.connect(io, port, .{ .mode = .stream }) catch |err| {
        std.debug.print("[determinismo] egress to {s}: {t}\n", .{ target, err });
        return;
    };
    slot.* = .{ .id = id, .fd = stream.socket.handle, .pid = linux.getpid() };
    vm.egress_status = @backingInt(EgressStatus.ok);
}

const EgressStatus = protocol.EgressStatus;

/// The guest's ingress request (sdk.ingress), answered (ingress_status, ingress_reply) from the
/// listener explore's --ingress names. Only the process that opened it answers from it: a
/// branch forked after inherits the descriptors, and two processes taking one listener's
/// connections would split them; the others see no connection (refused for one they name).
fn ingress_answer(vm: *VM) !void {
    vm.ingress_reply.clearRetainingCapacity();
    vm.ingress_reply_at = 0;
    vm.ingress_status = @backingInt(EgressStatus.refused);
    const request = vm.request_of(.ingress);
    if (request.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Request = struct { ingress: struct { op: []const u8 = "", id: u32 = 0, data: []const u8 = "" } = .{} };
    const asked = (std.json.parseFromSliceLeaky(Request, arena, request, .{ .ignore_unknown_fields = true }) catch return).ingress;
    const op = asked.op;
    if (vm.ingress_listener_open() != null) try vm.live_pace(false);
    if (std.mem.eql(u8, op, "accept")) {
        vm.ingress_status = @backingInt(EgressStatus.ok);
        const listener = vm.ingress_listener_open() orelse return;
        var fds = [_]linux.pollfd{.{ .fd = listener, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, 0);
        if (linux.errno(ready) != .SUCCESS or ready == 0) return; // Nobody yet.
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) return;
        const slot = for (&vm.ingress_sockets) |*slot| {
            if (slot.fd < 0) break slot;
        } else {
            _ = linux.close(@intCast(accepted)); // As many as egress's; the client sees a close.
            return;
        };
        slot.* = .{ .id = vm.ingress_next, .fd = @intCast(accepted), .pid = linux.getpid() };
        vm.ingress_next += 1;
        var id: [4]u8 = undefined;
        std.mem.writeInt(u32, &id, slot.id, .little);
        try vm.ingress_reply.appendSlice(std.heap.page_allocator, &id);
        return;
    }
    const slot = for (&vm.ingress_sockets) |*slot| {
        if (slot.id == asked.id and slot.fd >= 0) break slot;
    } else {
        vm.ingress_status = @backingInt(EgressStatus.reset); // Taken before a branch point.
        return;
    };
    if (slot.pid != linux.getpid()) {
        _ = linux.close(slot.fd);
        slot.* = .{};
        vm.ingress_status = @backingInt(EgressStatus.reset);
        return;
    }
    if (std.mem.eql(u8, op, "close")) {
        _ = linux.close(slot.fd);
        slot.* = .{};
        vm.ingress_status = @backingInt(EgressStatus.ok);
    } else if (std.mem.eql(u8, op, "send")) {
        const bytes = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(asked.data) catch return);
        std.base64.standard.Decoder.decode(bytes, asked.data) catch return;
        var rest: []const u8 = bytes;
        while (rest.len > 0) {
            const result = linux.write(slot.fd, rest.ptr, rest.len);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS) {
                vm.ingress_status = @backingInt(EgressStatus.end);
                return;
            }
            rest = rest[result..];
        }
        vm.ingress_status = @backingInt(EgressStatus.ok);
    } else if (std.mem.eql(u8, op, "recv")) {
        var fds = [_]linux.pollfd{.{ .fd = slot.fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, 0);
        vm.ingress_status = @backingInt(EgressStatus.ok);
        if (linux.errno(ready) != .SUCCESS or ready == 0) return; // Nothing yet.
        var buffer: [protocol.egress_recv_max]u8 = undefined;
        const result = linux.read(slot.fd, &buffer, buffer.len);
        if (linux.errno(result) != .SUCCESS or result == 0) {
            vm.ingress_status = @backingInt(EgressStatus.end);
            return;
        }
        try vm.ingress_reply.appendSlice(std.heap.page_allocator, buffer[0..result]);
    }
}

/// An ingress status answer saying nothing came (status ok, no bytes): an idle poll's.
fn ingress_nothing(value: []u8) void {
    std.mem.writeInt(u32, value[0..4], @backingInt(EgressStatus.ok), .little);
    std.mem.writeInt(u32, value[4..8], 0, .little);
}

fn ingress_is_nothing(value: []const u8) bool {
    return value.len == 8 and std.mem.readInt(u32, value[0..4], .little) == @backingInt(EgressStatus.ok) and
        std.mem.readInt(u32, value[4..8], .little) == 0;
}

test ingress_is_nothing {
    var value: [8]u8 = undefined;
    ingress_nothing(&value);
    try std.testing.expect(ingress_is_nothing(&value));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, &value); // As taped: "0100000000000000".
    std.mem.writeInt(u32, value[4..8], 3, .little);
    try std.testing.expect(!ingress_is_nothing(&value)); // Bytes came.
    std.mem.writeInt(u32, value[0..4], @backingInt(EgressStatus.end), .little);
    std.mem.writeInt(u32, value[4..8], 0, .little);
    try std.testing.expect(!ingress_is_nothing(&value)); // The connection ended: taped.
}

/// The connection id in a guest's ingress request ({"ingress":{"op":...,"id":N,...}}), 0 for
/// none (an accept). A session on a timeline with a connection still open (an editor's REPL
/// connection, taken by the session it extends) numbered its own first connection 1 again:
/// the guest's relay had two connections of one id, the old one's process reading the new
/// one's bytes until its next poll was told the connection was gone.
fn ingress_id_seen(request: []const u8) u32 {
    const key = "\"id\":";
    const at = std.mem.indexOf(u8, request, key) orelse return 0;
    const digits = request[at + key.len ..];
    const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
    return std.fmt.parseInt(u32, digits[0..end], 10) catch 0;
}

test ingress_id_seen {
    try std.testing.expectEqual(@as(u32, 5), ingress_id_seen("{\"ingress\":{\"op\":\"recv\",\"id\":5,\"target\":\"\",\"data\":\"\"}}"));
    try std.testing.expectEqual(@as(u32, 0), ingress_id_seen("{\"ingress\":{\"op\":\"accept\",\"id\":0,\"target\":\"\",\"data\":\"\"}}"));
    try std.testing.expectEqual(@as(u32, 0), ingress_id_seen(""));
}

/// A live timeline runs at a person's pace: its virtual time never ahead of the wall clock since
/// it was first paced (an idle guest's sleeps would otherwise pass in an instant: a person
/// reading a page, the timeline hours on, its tape and events growing with each idle second).
/// Ahead, it waits the difference, ending as soon as anything comes from outside (a session's
/// step or its end, a connection, bytes). A busy machine, behind the clock, never waits; a
/// replay answers from the tape and never comes here. Paced in two places: where the guest asks
/// the outside (an ingress poll: a second at most a poll, `whole` false), and where a live
/// session's guest has nothing to do (idle: the whole difference). The second since a session
/// whose relay died with its node (a crash at the REPL) was polled by nothing: its timeline ran
/// 716 virtual seconds in a minute, each with its samples (phoenixNAP run 44, 2026-11-14).
fn live_pace(vm: *VM, whole: bool) !void {
    const vtime_ns = (try vm.moment()).vtime_ns;
    if (vm.pace_wall_base_ns == 0) {
        vm.pace_wall_base_ns = monotonic_ns();
        vm.pace_vtime_base_ns = vtime_ns;
        return;
    }
    while (true) {
        const ahead_ns = (vtime_ns -| vm.pace_vtime_base_ns) -| (monotonic_ns() - vm.pace_wall_base_ns);
        if (ahead_ns < std.time.ns_per_ms) return;
        var fds: [2 + egress_connections_max]linux.pollfd = undefined;
        var count: usize = 0;
        if (vm.steps_live) if (vm.steps_fd) |fd| {
            fds[count] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            count += 1;
        };
        if (vm.ingress_listener_open()) |listener| {
            fds[count] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
            count += 1;
        }
        for (vm.ingress_sockets) |slot| if (slot.fd >= 0 and slot.pid == linux.getpid()) {
            fds[count] = .{ .fd = slot.fd, .events = linux.POLL.IN, .revents = 0 };
            count += 1;
        };
        const wait_ms: i32 = @intCast(@min(ahead_ns / std.time.ns_per_ms, live_pace_max_ms));
        const ready = linux.poll(&fds, count, wait_ms);
        // Something came (or the wait failed): on. A poll's share waited: on too.
        if (!whole or linux.errno(ready) != .SUCCESS or ready > 0) return;
    }
}

const live_pace_max_ms = 1000;

/// The listener explore's --ingress names, opened by the first process to need it; null for
/// none named or another process's.
fn ingress_listener_open(vm: *VM) ?linux.fd_t {
    const listen = vm.ingress_listen orelse return null;
    if (vm.ingress_listener >= 0) return if (vm.ingress_listener_pid == linux.getpid()) vm.ingress_listener else null;
    const colon = std.mem.lastIndexOfScalar(u8, listen, ':') orelse return null;
    const port = std.fmt.parseInt(u16, listen[colon + 1 ..], 10) catch return null;
    const address = std.Io.net.IpAddress.parse(listen[0..colon], port) catch return null;
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(socket) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(socket);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));
    const ip4 = switch (address) {
        .ip4 => |ip4| ip4,
        .ip6 => {
            _ = linux.close(fd);
            return null;
        },
    };
    const raw: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip4.bytes) };
    if (linux.errno(linux.bind(fd, @ptrCast(&raw), @sizeOf(linux.sockaddr.in))) != .SUCCESS or
        linux.errno(linux.listen(fd, 64)) != .SUCCESS)
    {
        std.debug.print("[determinismo] ingress: cannot listen on {s}\n", .{listen});
        _ = linux.close(fd);
        vm.ingress_listen = null;
        return null;
    }
    std.debug.print("[determinismo] ingress: listening on {s}\n", .{listen});
    vm.ingress_listener = fd;
    vm.ingress_listener_pid = linux.getpid();
    return fd;
}

/// Every `checkpoint_interval` events: recorded in the tape being written, or compared with
/// the tape being replayed (a mismatch ends the replay where it diverged).
fn checkpoint(vm: *VM, moment_now: Events.Moment) !void {
    if (vm.events.count % tape.checkpoint_interval != 0) return;
    const now = tape.Checkpoint{
        .events = vm.events.count,
        .branches = moment_now.branches,
        .events_hash = vm.events.hash.final(),
    };
    if (vm.tape_fd) |fd| tape.write_checkpoint(fd, now);
    // A command run at the moment makes a new timeline from there: the tape describes the one
    // without it (a replay to look inside a timeline, --exec, must not stop at its own change,
    // nor its steps after it: an until after an exec parted from the tape at its first
    // checkpoint).
    if (vm.moment_changed) return;
    if (vm.overrides) |overrides| overrides.check(now) catch |err| {
        const message = "[determinismo] replay diverged from its tape at event {d}\n";
        std.debug.print(message, .{now.events});
        vm.recent_print();
        // What could have perturbed the guest's clock on the way (the KVM patch's counts).
        if (vm.det_state()) |state| {
            std.debug.print("[determinismo] its clock's hazards: {d} counter throttles restarted, " ++
                "{d} reached at another exit, {d} overshoots (largest skid {d}), {d} drifts, " ++
                "XINUSE restored {d} times ({d} not)\n", .{
                state.throttles, state.late_steps,   state.overshoots,     state.skid_max,
                state.drifts,    state.xinuse_fixes, state.xinuse_unfixed,
            });
        } else |_| {}
        return err;
    };
}

/// The name of the process behind a request (Linux's TASK_COMM_LEN, without its NUL).
const source_size_max = 16;

fn source_trim(comm: *const [source_size_max]u8) []const u8 {
    return comm[0 .. std.mem.indexOfScalar(u8, comm, 0) orelse source_size_max];
}

/// A live timeline's pull, as the explorer is asked about it (Advisor.pull).
pub const Pull = struct {
    pull: u64,
    /// The pull's moment, when the advisor wants it (Advisor.wants_moment); else zero.
    moment: Events.Moment,
    source: []const u8,
    label: ?[]const u8,
    /// The seeded default: the advisor may overwrite it with its answer.
    value: []u8,
    /// Whether the timeline has a tape (an answer nothing records no replay could repeat).
    taped: bool,
};

/// The explorer's answer to a pull.
pub const Advice = struct {
    /// It overwrote the value: taped with `reason`.
    overridden: bool = false,
    reason: []const u8 = "",
    /// A decision event says it (when its reason is not empty).
    decision: bool = false,
    /// The pull is answered: nothing after the advisor's turn is asked.
    done: bool = false,
    /// The advisor ended the timeline (Outcome.strategy_ended).
    ended: bool = false,
};

/// The explorer's side of a live timeline's pulls and events (advisor.zig: its strategy and
/// its bandit): the core asks, the explorer answers, the tape keeps it.
pub const Advisor = struct {
    context: *anyopaque,
    wants_moment: bool,
    pull: *const fn (context: *anyopaque, pull: Pull) anyerror!Advice,
    /// An event line of the timeline: whether the advisor ended it.
    event: *const fn (context: *anyopaque, moment: Events.Moment, source: []const u8, line: []const u8) anyerror!bool,
    /// In a fork of the worker (a holder, its disk writer): lets go of what the advisor reaches
    /// outside (a strategy plugin's connection, which would otherwise never see its input end).
    forget: *const fn (context: *anyopaque) void,
};

/// What a replay's pulls and events tell an observer (draws.zig's recorder): it sees each labeled
/// pull's value as the guest takes it, after the tape's answer, and changes nothing.
pub const PullNote = struct {
    context: *anyopaque,
    pull: *const fn (context: *anyopaque, pull: u64, label: []const u8, value: []const u8, overridden: bool) void,
    event: *const fn (context: *anyopaque, vtime_ns: u64) void,
};

/// One randomness pull: the seeded default, unless a replayed tape or the strategy overrides it.
const decision_label_size_max = 2048;

/// det-composer's driver phase length decision (composer.zig's drive_drawn_ns): its bucket k,
/// the length drawn between `max >> k` and half that.
const drive_label_prefix = "{\"name\":\"composer.drive_ms\"";

/// sdk.fork's index decision (sdk.fork_decision).
const fork_label_prefix = "{\"name\":\"det.fork_index\"";
const egress_status_prefix = "{\"name\":\"det.egress_status\"";
const egress_reply_prefix = "{\"name\":\"det.egress_reply\"";
const egress_channel_prefix = "{\"name\":\"det.egress_channel\"";
const egress_reason = tape.egress_reason;
const ingress_status_prefix = "{\"name\":\"det.ingress_status\"";
const ingress_reply_prefix = "{\"name\":\"det.ingress_reply\"";
const ingress_reason = tape.ingress_reason;
const egress_channel_reason = "how the machine's egress goes: 0 the host's relay, 1 egress decisions";
const serve_status_prefix = "{\"name\":\"det.serve_status\"";
const serve_reply_prefix = "{\"name\":\"det.serve_reply\"";
const serve_reason = tape.serve_reason;
const fork_reason = "a fork's index: 0 where it was asked, k in its future k";
const explore_here_label_prefix = "{\"name\":\"det.explore_here\"";
const explore_here_reason = "where a fast VM's snapshot goes on: 0 a fast VM, 1 a timeline, 2 held";

/// Named decisions a setup drew (VM.setup_draws): their names, each once, up to count_max.
pub const SetupDraws = struct {
    pub const count_max = 32;
    pub const name_size_max = 64;
    names: [count_max][name_size_max]u8 = undefined,
    sizes: [count_max]u8 = @splat(0),
    count: u32 = 0,
    /// Names past count_max, not kept.
    dropped: u32 = 0,

    pub fn note(draws: *SetupDraws, label: []const u8) void {
        const drawn = label_name(label) orelse return;
        const size = @min(drawn.len, name_size_max);
        for (0..draws.count) |index| {
            if (std.mem.eql(u8, draws.name(index), drawn[0..size])) return;
        }
        if (draws.count == count_max) {
            draws.dropped += 1;
            return;
        }
        @memcpy(draws.names[draws.count][0..size], drawn[0..size]);
        draws.sizes[draws.count] = @intCast(size);
        draws.count += 1;
    }

    pub fn name(draws: *const SetupDraws, index: usize) []const u8 {
        assert(index < draws.count);
        return draws.names[index][0..draws.sizes[index]];
    }

    /// A label's name ({"name":"sim.tables",...}).
    fn label_name(label: []const u8) ?[]const u8 {
        const key = "\"name\":\"";
        const start = (std.mem.indexOf(u8, label, key) orelse return null) + key.len;
        const end = std.mem.indexOfScalarPos(u8, label, start, '"') orelse return null;
        return label[start..end];
    }
};

test SetupDraws {
    var draws: SetupDraws = .{};
    draws.note("{\"name\":\"sim.tables\",\"range\":2}");
    draws.note("{\"name\":\"sim.columns\",\"range\":4}");
    draws.note("{\"name\":\"sim.tables\",\"range\":2}");
    draws.note("{\"options\":[\"a\"]}");
    try std.testing.expectEqual(@as(u32, 2), draws.count);
    try std.testing.expectEqualStrings("sim.tables", draws.name(0));
    try std.testing.expectEqualStrings("sim.columns", draws.name(1));
    for (0..SetupDraws.count_max) |index| {
        var buffer: [32]u8 = undefined;
        draws.note(std.fmt.bufPrint(&buffer, "{{\"name\":\"n{d}\"}}", .{index}) catch unreachable);
    }
    try std.testing.expectEqual(@as(u32, SetupDraws.count_max), draws.count);
    try std.testing.expectEqual(@as(u32, 2), draws.dropped);
}

/// What a guest thread announced and asked, until its next pull.
const Pending = struct {
    tid: u32 = 0,
    stamp: u64 = 0,
    /// A labeled decision (`{"decision": {...}}` from the SDK's `decide`): the label of the
    /// thread's next randomness pull, sent to the strategy with it.
    label: [decision_label_size_max]u8 = undefined,
    label_size: u32 = 0,
    /// Its request to the platform (sdk.serve, sdk.egress, sdk.ingress), until its answer's
    /// status pull.
    request: std.ArrayList(u8) = .empty,
    kind: RequestKind = .none,
};
const pending_max = 32;
const RequestKind = enum(u8) { serve, egress, ingress, none };
const request_prefixes = [_][]const u8{ "{\"serve\":", "{\"egress\":", "{\"ingress\":" };

/// The thread's entry, made (the least recently used one taken) when asked to.
fn pending_of(vm: *VM, tid: u32, make: bool) ?*Pending {
    if (tid == 0) return null;
    vm.pending_stamp += 1;
    var oldest: *Pending = &vm.pending[0];
    for (&vm.pending) |*entry| {
        if (entry.tid == tid and entry.stamp != 0) {
            entry.stamp = vm.pending_stamp;
            return entry;
        }
        if (entry.stamp < oldest.stamp) oldest = entry;
    }
    if (!make) return null;
    oldest.tid = tid;
    oldest.stamp = vm.pending_stamp;
    oldest.label_size = 0;
    oldest.request.clearRetainingCapacity();
    oldest.kind = .none;
    return oldest;
}

/// Keeps a decision's label for the next pull of the thread that announced it.
fn decision_note(vm: *VM, line: []const u8, tid: u32) void {
    const prefix = "{\"decision\":";
    if (!std.mem.startsWith(u8, line, prefix) or line[line.len - 1] != '}') return;
    const label = line[prefix.len .. line.len - 1];
    if (label.len > decision_label_size_max or tid == 0) return; // 0: no thread said (no room).
    const entry = vm.pending_of(tid, true) orelse return;
    @memcpy(entry.label[0..label.len], label);
    entry.label_size = @intCast(label.len);
}

/// The label of this pull, if its thread announced one (used once).
fn decision_take(vm: *VM) ?[]const u8 {
    const entry = vm.pending_of(vm.pull_tid, false) orelse return null;
    if (entry.label_size == 0) return null;
    const label = entry.label[0..entry.label_size];
    entry.label_size = 0;
    return label;
}

/// A thread's request to the platform, kept for its answer.
fn request_note(vm: *VM, tid: u32, kind: RequestKind, line: []const u8) !void {
    const entry = vm.pending_of(tid, true) orelse return;
    entry.request.clearRetainingCapacity();
    try entry.request.appendSlice(std.heap.page_allocator, line);
    entry.kind = kind;
}

/// The pulling thread's request of that kind ("" for none).
fn request_of(vm: *VM, kind: RequestKind) []const u8 {
    const entry = vm.pending_of(vm.pull_tid, false) orelse return "";
    return if (entry.kind == kind) entry.request.items else "";
}

fn request_clear(vm: *VM, kind: RequestKind) void {
    const entry = vm.pending_of(vm.pull_tid, false) orelse return;
    if (entry.kind != kind) return;
    entry.request.clearRetainingCapacity();
    entry.kind = .none;
}

/// A taped override applied to pull `pull`, if the tape has one for it; written to this
/// machine's own tape when it extends the timeline (tape_applied).
fn override_apply(vm: *VM, overrides: *tape.Overrides, pull: u64, value: []u8) !bool {
    const kind = overrides.kind_at(pull) orelse .decision;
    if (!try overrides.apply(pull, value)) return false;
    if (vm.tape_applied) if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, overrides.reason_text(pull, kind));
    return true;
}

/// This machine extends the timeline its tape replays (explore --extend): what the tape gave
/// before it began goes on its own tape first, what it applies from now on as it does.
pub fn tape_extend_begin(vm: *VM) void {
    const fd = vm.tape_fd.?;
    if (vm.overrides) |overrides| {
        overrides.write_consumed(fd);
        vm.tape_written += overrides.cursor;
    }
    vm.tape_applied = true;
}

/// The timeline's tape (none: nothing taped), its count of overrides from zero.
pub fn tape_attach(vm: *VM, fd: ?linux.fd_t) void {
    vm.tape_fd = fd;
    vm.tape_written = 0;
    vm.tape_full = false;
    vm.tape_full_ns = null;
    vm.tape_steps = 0;
    vm.tape_step_bytes = 0;
}

/// An override onto the timeline's tape, override_count_max at most: there the tape says it
/// is full (a replay stops at that pull, TapeFull) and the timeline says so (`tape_full`),
/// instead of a tape no replay can read (CE20, the Lean replica of determinismo).
fn tape_override(vm: *VM, fd: linux.fd_t, pull: u64, value: []const u8, reason: []const u8) !void {
    if (vm.tape_written >= tape.override_count_max) {
        if (vm.tape_full) return;
        vm.tape_full = true;
        vm.tape_full_ns = (try vm.moment()).vtime_ns;
        tape.write_full(fd, pull);
        var buffer: [96]u8 = undefined;
        const event = std.fmt.bufPrint(&buffer, "{{\"event\":\"tape_full\",\"pull\":{d},\"overrides\":{d}}}", .{ pull, vm.tape_written }) catch unreachable;
        try vm.events.emit(try vm.moment(), event);
        return;
    }
    tape.write_override(fd, pull, value, reason);
    vm.tape_written += 1;
}

fn decide_random(vm: *VM, value: []u8, source: []const u8) !void {
    assert(value.len > 0);
    const label = vm.decision_take();
    if (vm.stop_at_setup_complete and vm.events.setup_complete == null) {
        if (label) |text| vm.setup_draws.note(text);
    }
    const pull = vm.decisions.pulls;
    // Past where the tape's recorder stopped taping, nothing answers this replay as its run was.
    if (vm.overrides) |overrides| if (overrides.past_full(pull)) return error.TapeFull;
    vm.decisions.random(value);
    assert(vm.decisions.pulls == pull + 1);
    vm.last_pull_ns = (try vm.moment()).vtime_ns;
    // A fork's index (sdk.fork): this machine's, 0 unless it is future k of a fork, once; on the
    // tape, so a replay repeats it. Not a strategy's to steer, nor a tape's but the one that
    // recorded it (a session replays its run's tape, whose pull of that number was another).
    // Whether this machine is a timeline (1) or the fast VM it was forked from (0), asked once
    // where a fast VM explored from here (sdk.explore_here_decision): a fact, not a draw.
    if (label) |text| if (std.mem.startsWith(u8, text, explore_here_label_prefix) and value.len == 8) {
        // A replay's from its tape (the same fact; the tape's cursor past it: left there, the
        // next pull found an entry behind it, TapeOutOfOrder).
        const taped = if (vm.overrides) |overrides| try vm.override_apply(overrides, pull, value) else false;
        if (!taped) {
            const fact: u64 = if (!vm.deterministic) 0 else if (vm.hold_scenario) 2 else 1;
            std.mem.writeInt(u64, value[0..8], fact, .little);
        }
        const answer = std.mem.readInt(u64, value[0..8], .little);
        if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, explore_here_reason);
        try vm.decision_event(pull, source, label, explore_here_reason);
        if (answer == 1) {
            // Its settings, the agent's next action (it waits for it before the scenario).
            const action = std.fmt.bufPrint(&vm.timeline_action, "det:cmdline {s}", .{vm.timeline_cmdline}) catch
                return error.CmdlineTooLong;
            assert(vm.action_pending == null);
            vm.action_pending = action;
            try vm.irq_pulse(irq_action);
        }
        return;
    };
    if (label) |text| if (std.mem.startsWith(u8, text, fork_label_prefix) and value.len == 8) {
        const taped = if (vm.overrides) |overrides| taped: {
            const recorded = overrides.reason(pull) orelse break :taped false;
            if (!std.mem.eql(u8, recorded, fork_reason)) break :taped false;
            break :taped try vm.override_apply(overrides, pull, value);
        } else false;
        if (!taped) {
            std.mem.writeInt(u64, value[0..8], vm.fork_index, .little);
            vm.fork_index = 0;
            if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, fork_reason);
        }
        // Its event whether answered or replayed, as egress's: a replay's history is the run's
        // (without it a replay of a forked timeline was one event short from there: the Lean
        // replica of determinismo's CE12).
        try vm.decision_event(pull, source, label, fork_reason);
        return;
    };
    // The machine's egress channel (sdk.egress_channel): a fact, a replay's from its tape.
    if (label) |text| if (std.mem.startsWith(u8, text, egress_channel_prefix) and value.len == 8) {
        const taped = if (vm.overrides) |overrides| try vm.override_apply(overrides, pull, value) else false;
        if (!taped) std.mem.writeInt(u64, value[0..8], @intFromBool(vm.deterministic), .little);
        if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, egress_channel_reason);
        try vm.decision_event(pull, source, label, egress_channel_reason);
        return;
    };
    // An egress answer (sdk.egress): its status and size, then its bytes; on the tape, so a
    // replay answers from it and never connects (as serve's, below).
    if (label) |text| if (std.mem.startsWith(u8, text, egress_status_prefix) or std.mem.startsWith(u8, text, egress_reply_prefix)) {
        const status = std.mem.startsWith(u8, text, egress_status_prefix);
        const taped = if (vm.overrides) |overrides| taped: {
            if (!status) break :taped vm.egress_taped and try vm.override_apply(overrides, pull, value);
            if (overrides.kind_at(pull) != .egress) break :taped false;
            break :taped try vm.override_apply(overrides, pull, value);
        } else false;
        if (status) vm.egress_taped = taped;
        if (!taped) {
            if (vm.egress_taped) return error.TapeEgressReplyShort;
            if (status) {
                if (value.len != 8) return error.BadGuestRequest;
                try vm.egress_answer();
                std.mem.writeInt(u32, value[0..4], vm.egress_status, .little);
                std.mem.writeInt(u32, value[4..8], @intCast(vm.egress_reply.items.len), .little);
            } else {
                const rest = vm.egress_reply.items[@min(vm.egress_reply_at, vm.egress_reply.items.len)..];
                if (value.len > rest.len) return error.BadGuestRequest;
                @memcpy(value, rest[0..value.len]);
                vm.egress_reply_at += value.len;
            }
            // Its bytes too carry the reason (their kind: tape.Kind, no reason kept for it).
            const reason = egress_reason;
            if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, reason);
        }
        // Its event whether answered or replayed: a replay's history is the run's.
        if (status) try vm.decision_event(pull, source, label, egress_reason);
        if (status) vm.request_clear(.egress);
        return;
    };
    // An ingress answer (sdk.ingress): as egress's, the outside's connections and bytes on the
    // tape, so a replay delivers them again with nobody outside. Its event only when something
    // came (a connection, bytes, an end): an idle node's polls leave none.
    if (label) |text| if (std.mem.startsWith(u8, text, ingress_status_prefix) or std.mem.startsWith(u8, text, ingress_reply_prefix)) {
        const status = std.mem.startsWith(u8, text, ingress_status_prefix);
        // A connection the guest speaks of (its id in the request), answered from a tape or
        // live: the next one taken here is numbered after it (ingress_id_seen).
        if (status) vm.ingress_next = @max(vm.ingress_next, ingress_id_seen(vm.request_of(.ingress)) +| 1);
        const taped = if (vm.overrides) |overrides| taped: {
            if (!status) break :taped vm.ingress_taped and try vm.override_apply(overrides, pull, value);
            if (overrides.kind_at(pull) != .ingress) {
                // An idle poll's nothing is never taped (below): a replay answers a status pull
                // its tape lacks with it, as the run was answered. Never one the tape has an
                // answer before: the replay passed it, diverged.
                if (vm.ingress_answers_live) break :taped false;
                if (overrides.passed(pull)) return error.TapeOutOfOrder;
                if (value.len != 8) return error.BadGuestRequest;
                ingress_nothing(value);
                break :taped true;
            }
            break :taped try vm.override_apply(overrides, pull, value);
        } else false;
        if (status) vm.ingress_taped = taped;
        if (!taped) {
            if (vm.ingress_taped) return error.TapeIngressReplyShort;
            if (status) {
                if (value.len != 8) return error.BadGuestRequest;
                try vm.ingress_answer();
                std.mem.writeInt(u32, value[0..4], vm.ingress_status, .little);
                std.mem.writeInt(u32, value[4..8], @intCast(vm.ingress_reply.items.len), .little);
            } else {
                const rest = vm.ingress_reply.items[@min(vm.ingress_reply_at, vm.ingress_reply.items.len)..];
                if (value.len > rest.len) return error.BadGuestRequest;
                @memcpy(value, rest[0..value.len]);
                vm.ingress_reply_at += value.len;
            }
            // Its bytes too carry the reason (their kind: tape.Kind, no reason kept for it). An
            // idle poll's nothing (84 a virtual second) not: a replay answers it alike, and taped
            // it outgrew what a replay could read in 13 virtual minutes (CE20, the Lean replica
            // of determinismo).
            const reason = ingress_reason;
            if (!(status and ingress_is_nothing(value))) if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, reason);
        }
        if (status) {
            const answered = std.mem.readInt(u32, value[0..4], .little);
            const size = std.mem.readInt(u32, value[4..8], .little);
            if (size > 0 or answered != @backingInt(EgressStatus.ok)) try vm.decision_event(pull, source, label, ingress_reason);
            vm.request_clear(.ingress);
        }
        return;
    };
    // serve's reply to the guest (sdk.serve): its status and size, then its bytes. On the tape,
    // so a replay answers from it and never calls serve.
    if (label) |text| if (std.mem.startsWith(u8, text, serve_status_prefix) or std.mem.startsWith(u8, text, serve_reply_prefix)) {
        const status = std.mem.startsWith(u8, text, serve_status_prefix);
        // Its status pull is recognized by its reason; the bytes that follow come from where it
        // came from (a reason a chunk would fill the tape's few).
        const taped = if (vm.overrides) |overrides| taped: {
            if (!status) break :taped vm.serve_taped and try vm.override_apply(overrides, pull, value);
            if (overrides.kind_at(pull) != .serve) break :taped false;
            break :taped try vm.override_apply(overrides, pull, value);
        } else false;
        if (status) vm.serve_taped = taped;
        if (!taped) {
            if (vm.serve_taped) return error.TapeServeReplyShort; // Taped then, taped to its end.
            if (status) {
                if (value.len != 8) return error.BadGuestRequest;
                try vm.serve_answer();
                std.mem.writeInt(u32, value[0..4], vm.serve_status, .little);
                std.mem.writeInt(u32, value[4..8], @intCast(vm.serve_reply.items.len), .little);
            } else {
                const rest = vm.serve_reply.items[@min(vm.serve_reply_at, vm.serve_reply.items.len)..];
                if (value.len > rest.len) return error.BadGuestRequest;
                @memcpy(value, rest[0..value.len]);
                vm.serve_reply_at += value.len;
            }
            // Its bytes too carry the reason (their kind: tape.Kind, no reason kept for it).
            const reason = serve_reason;
            if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, reason);
        }
        // Its event whether answered or replayed, as egress's (CE12, as the fork's above).
        if (status) try vm.decision_event(pull, source, label, serve_reason);
        if (status) vm.request_clear(.serve);
        return;
    };
    if (vm.overrides) |overrides| {
        assert(vm.advisor == null); // A replay never consults the explorer.
        const overridden = try vm.override_apply(overrides, pull, value);
        if (overridden) {
            if (overrides.reason(pull)) |reason| try vm.decision_event(pull, source, label, reason);
        }
        if (vm.pull_note) |note| if (label) |text| note.pull(note.context, pull, text, value, overridden);
    } else if (vm.advisor) |advisor| {
        // The explorer's advice (a strategy's plan or answer, the bandit's configuration draw):
        // it may overwrite the value; on the tape then, so every replay repeats it unasked.
        const moment_now: Events.Moment = if (advisor.wants_moment) try vm.moment() else .{ .vtime_ns = 0, .branches = 0 };
        const advice = try advisor.pull(advisor.context, .{
            .pull = pull,
            .moment = moment_now,
            .source = source,
            .label = label,
            .value = value,
            .taped = vm.tape_fd != null,
        });
        if (advice.ended) vm.strategy_ended = true;
        if (advice.overridden) {
            if (vm.tape_fd) |fd| try vm.tape_override(fd, pull, value, advice.reason);
            if (advice.decision and advice.reason.len > 0) try vm.decision_event(pull, source, label, advice.reason);
        }
        if (advice.done) return;
    }
    // The explorer's own answer to the driver phase's length (main.zig's Novelty), on the tape
    // as a strategy's: every replay repeats it (main.zig's Recorded). Only into a tape: an
    // override nothing records no replay could repeat.
    if (vm.overrides == null) if (vm.tape_fd) |fd| if (vm.drive_k) |k| if (label) |text| {
        if (!std.mem.startsWith(u8, text, drive_label_prefix) or value.len != 8) return;
        std.mem.writeInt(u64, value[0..8], k, .little);
        const reason = "the driver phase's length from the run's novelty curve";
        try vm.tape_override(fd, pull, value, reason);
        try vm.decision_event(pull, source, label, reason);
    };
}

/// A strategy's decision and why, in the timeline (its replay from the tape has it too).
fn decision_event(
    vm: *VM,
    pull: u64,
    source: []const u8,
    label: ?[]const u8,
    reason: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"event\":\"decision\",\"details\":{{\"pull\":{d},\"source\":{f}," ++
        "\"by\":\"strategy\",\"reason\":{f}", .{
        pull, std.json.fmt(source, .{}), std.json.fmt(reason, .{}),
    }) catch return;
    if (label) |decision| writer.print(",\"decision\":{s}", .{decision}) catch return;
    writer.writeAll("}}") catch return;
    const moment_now = try vm.moment();
    try vm.events.emit(moment_now, writer.buffered());
    vm.recent_note(moment_now, writer.buffered());
}

const recent_max = tape.checkpoint_interval;
const recent_text_max = 120;
const Recent = struct { sequence: u64, moment: Events.Moment, size: u8, text: [recent_text_max]u8 };

fn recent_note(vm: *VM, at: Events.Moment, data: []const u8) void {
    const slot = &vm.recent[vm.recent_count % recent_max];
    vm.recent_count += 1;
    const size = @min(data.len, recent_text_max);
    slot.sequence = vm.events.count;
    slot.moment = at;
    slot.size = @intCast(size);
    @memcpy(slot.text[0..size], data[0..size]);
}

/// The events since the last checkpoint (the window a divergence lies in), oldest first, as the
/// run's events file has them: its "seq", "vtime_ns" and "branches", and the event's start.
fn recent_print(vm: *const VM) void {
    const count = @min(vm.recent_count, recent_max);
    std.debug.print("[determinismo] its last {d} events (seq vtime_ns branches event), to compare " ++
        "with its timeline's:\n", .{count});
    for (vm.recent_count - count..vm.recent_count) |index| {
        const event = &vm.recent[index % recent_max];
        std.debug.print("[determinismo]   {d} {d} {d} {s}\n", .{
            event.sequence, event.moment.vtime_ns, event.moment.branches, event.text[0..event.size],
        });
    }
}

fn trace(vm: *VM, comptime kind: []const u8, value: u64) !void {
    const fd = vm.trace_fd orelse return;
    assert(vm.deterministic);
    const state = try vm.det_state();
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.GET_REGS, @intFromPtr(&regs));
    var line_buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, kind ++ " {d} branches={d} rip={x} rdtsc={d} " ++
        "steps={d} overflows={d} soft={d} drifts={d} drift={d}\n", .{
        value,            state.branches,  regs.rip,         state.rdtsc_exits,
        state.mtf_steps,  state.overflows, state.soft_exits, state.drifts,
        state.drift_last,
    }) catch unreachable;
    _ = linux.write(fd, line.ptr, line.len); // Best effort: a debugging aid.
}

/// Debugging: the log of RDTSC exits, (branch count, RIP) pairs, appended to rdtsc_log_fd: the
/// first `rdtsc_log_cap` of them.
pub const rdtsc_log_cap_default = 1 << 22;

fn rdtsc_log_enable(vm: *VM) !void {
    if (vm.itrace_fd != null and vm.itrace_at > 0) {
        var window: kvm.DetItrace = .{ .at = vm.itrace_at, .cap = itrace_cap };
        _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_ITRACE_ENABLE, @intFromPtr(&window));
    }
    if (vm.rdtsc_log_fd == null) return;
    var cap: u64 = vm.rdtsc_log_cap;
    _ = try kvm.ioctl(vm.vcpu_fd, kvm.DET_LOG_ENABLE, @intFromPtr(&cap));
}

const itrace_cap = 1 << 22;

fn rdtsc_log_write(vm: *VM) void {
    const fd = vm.rdtsc_log_fd orelse return;
    const pairs = std.heap.page_allocator.alloc(u64, 2 * @max(vm.rdtsc_log_cap, itrace_cap)) catch return;
    defer std.heap.page_allocator.free(pairs);
    var request: kvm.DetLog = .{ .buf = @intFromPtr(pairs.ptr), .cap = vm.rdtsc_log_cap, .len = 0 };
    _ = kvm.ioctl(vm.vcpu_fd, kvm.DET_LOG_READ, @intFromPtr(&request)) catch return;
    const bytes = std.mem.sliceAsBytes(pairs[0 .. 2 * request.len]);
    _ = linux.write(fd, bytes.ptr, bytes.len);
    const itrace = vm.itrace_fd orelse return;
    var traced: kvm.DetLog = .{ .buf = @intFromPtr(pairs.ptr), .cap = itrace_cap, .len = 0 };
    _ = kvm.ioctl(vm.vcpu_fd, kvm.DET_ITRACE_READ, @intFromPtr(&traced)) catch return;
    const traced_bytes = std.mem.sliceAsBytes(pairs[0 .. 2 * traced.len]);
    _ = linux.write(itrace, traced_bytes.ptr, traced_bytes.len);
}

fn irq_pulse(vm: *VM, irq: u32) !void {
    assert(irq < 16);
    var level = kvm.IrqLevel{ .irq = irq, .level = 1 };
    _ = try kvm.ioctl(vm.vm_fd, kvm.IRQ_LINE, @intFromPtr(&level));
    level.level = 0;
    _ = try kvm.ioctl(vm.vm_fd, kvm.IRQ_LINE, @intFromPtr(&level));
}

fn open_kvm() !linux.fd_t {
    const fd = try syscall(linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    assert(fd <= std.math.maxInt(i32));
    return @intCast(fd);
}

fn syscall(result: usize) !usize {
    switch (linux.errno(result)) {
        .SUCCESS => return result,
        else => |errno| {
            std.log.err("syscall failed: {s}", .{@tagName(errno)});
            return error.SyscallFailed;
        },
    }
}
