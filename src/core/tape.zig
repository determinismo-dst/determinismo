// SPDX-License-Identifier: MIT
//! Tapes (docs/PLUGINS.md): the decisions a strategy overrode in one branch, written as JSON lines
//! so the branch replays without the strategy. Replays load overrides into a fixed table.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const override_count_max = 1 << 16;
const tape_version = 2;

pub const Header = struct {
    /// What the machine booted (see `inputs_hash` in main.zig): a tape replays only on the same.
    inputs: u64,
    exploration_seed: u64,
    branch: u32,
    branch_seed: u64,
    /// Set for a branch explored from a moment of another branch (a nested snapshot).
    fork: ?Fork = null,
    /// The tree explorer's path to where this branch starts, from the setup snapshot: each
    /// ancestor (its index and seed) and the moment the next one left it. Empty: the snapshot.
    chain: []const Segment = &.{},
    /// The build of determinismo that recorded it (a hash of its executable): a replay by another
    /// may part from it for that alone (null: tapes from before 2026-10-29).
    host: ?u64 = null,
    /// The clock's jitter it ran with (VM.Options.tsc_jitter_seed, part of `inputs`): a replay
    /// from the tape boots with it (0: none, as every tape before 2026-11-07).
    tsc_jitter_seed: u64 = 0,
    /// The timeline's own clock jitter (its strategy's at its branch, else a tree child's
    /// parent's): its VM's from where it starts (the setup snapshot, or its branch point), the
    /// setup's being `tsc_jitter_seed` (in `inputs`); its ancestors' are in `chain`. A replay
    /// starts its timeline with it. Null: the run's.
    clock_jitter_seed: ?u64 = null,
    /// The machine a strategy decided for its run (its `machine` request: the guest's wall clock
    /// at boot, where timer interrupts land in their slack, CPU modulation's stretches; part of
    /// `inputs`): a replay from the tape boots it. Null: the run's options as given.
    machine: ?Machine = null,
    /// The strategy plugins that answered it, as run (one a line, an upload's kept copy named
    /// by its content's hash): what made its decisions. Null: none, or a tape from before
    /// 2026-11-19. A replay needs none of them.
    strategy: ?[]const u8 = null,
    /// Its stepper's margin, when its strategy chose one (VM.Options.margin_branches): how it was
    /// stepped, never what the guest saw (a replay steps alike, for its timings).
    margin_branches: ?u32 = null,
    /// Set for a timeline that goes on from a moment of another of its run (explore --extend:
    /// a session's): that timeline and the moment. Its tape is whole (what the other's gave it
    /// up to the moment, then its own), under a number of its own (claim_next).
    extends: ?Extends = null,
};

pub const Extends = struct { branch: u32, vtime_ns: u64 };
pub const Machine = struct {
    epoch_seconds: u64,
    timer_slack_ns: u64,
    modulation_stretch_ns: [2]u64,
    /// How far into its slack a timer lands at the earliest (VM.Options.timer_delay_permille).
    timer_delay_permille: u16 = 0,
    /// A plugin's own faults as the guest's command line gives them (`det.custom_faults=`: hex
    /// of [{"node","command"},...]); empty: none.
    custom_faults: []const u8 = "",
    /// The fault injector's wait sliced in polls of this many milliseconds, each asking
    /// "fault.now" (`det.fault_poll_ms=`): a plugin faults at moments it chooses. 0: no poll.
    fault_poll_ms: u32 = 0,
};

/// A poll at most a second apart.
pub const fault_poll_ms_max = 1000;

/// One step of a path: branch `branch` (seed `seed`) ran from the previous step's moment to
/// `vtime_ns`, where the next one branched from it.
/// An ancestor of a tree's timeline: its index and seed, the moment the next left it, and the
/// clock it ran on (its own: Header.clock_jitter_seed; null, the run's), which a replay of the
/// chain boots that segment with.
pub const Segment = struct { branch: u32, seed: u64, vtime_ns: u64, jitter_seed: ?u64 = null };
pub const chain_length_max = 64;
/// A header's strategy (Header.strategy) at most.
pub const strategy_size_max = 2048;

/// A moment of a branch of the setup snapshot, where a nested snapshot is taken.
pub const Fork = struct {
    branch: u32,
    vtime_ns: u64,
    /// A command run at the fork point before the snapshot: the branches explore its effects.
    exec: ?[]const u8 = null,
    /// Bytes the VMM wrote into guest RAM at the fork point, after `exec` and before the
    /// snapshot (`--from-poke`: "<guest physical address>=<hex bytes>[,...]"): a what-if, debugging
    /// only. Kept on the tape so the branches replay.
    pokes: ?[]const u8 = null,
};

/// The longest `--from-poke` text a tape keeps.
pub const pokes_size_max = 1024;

pub const override_size_max = 64;
/// Why a plugin chose an answer (its `reason`), kept with the decision; longer is cut.
pub const reason_size_max = 240;

pub const Override = struct { pull: u64, size: u8, kind: Kind = .decision, bytes: [override_size_max]u8 };

/// What an override answers: a decision (a strategy's, a fact's), or the outside's answer to the
/// guest. The outside's are told by their reason (the same text for each) and kept as the kind
/// alone, not in the reasons: a session relaying connections polls for them 84 times a virtual
/// second, each poll's answer on its tape (1,024 reasons lasted 12 s: TapeTooLong on its replay).
pub const Kind = enum(u8) { decision, egress, ingress, serve };
pub const egress_reason = "an egress answer to the guest (sdk.egress)";
pub const ingress_reason = "an ingress answer to the guest (sdk.ingress)";
pub const serve_reason = "serve's reply to the guest (sdk.serve)";

fn kind_of(reason: []const u8) Kind {
    if (std.mem.eql(u8, reason, ingress_reason)) return .ingress;
    if (std.mem.eql(u8, reason, egress_reason)) return .egress;
    if (std.mem.eql(u8, reason, serve_reason)) return .serve;
    return .decision;
}

/// A strategy's reason for an override, replayed with it (a `decision` event in the timeline).
pub const Reason = struct { pull: u64, size: u8, text: [reason_size_max]u8 };
pub const reason_count_max = 1024;

/// Overrides of one branch, ordered by pull. A replay consumes them in order.
/// The state of a branch at an event count: a replay that differs there has diverged.
pub const Checkpoint = struct { events: u64, branches: u64, events_hash: u64 };
pub const checkpoint_interval = 64;
/// Checkpoints a replay holds: past it, a longer tape's are thinned (checkpoint_parse), every
/// other one kept, so that a replay is still compared along all of it (Valkey's run 1523: a
/// timeline of 1.35 million events, 21,136 checkpoints, ended the explorer, TapeTooLong).
pub const checkpoint_count_max = 1 << 14;

pub const Overrides = struct {
    entries: [override_count_max]Override,
    count: u32,
    cursor: u32,
    checkpoints: [checkpoint_count_max]Checkpoint = undefined,
    checkpoint_count: u32 = 0,
    checkpoint_cursor: u32 = 0,
    /// Kept: one checkpoint in this many (a power of two), once a tape's outnumbered the array.
    checkpoint_every: u32 = 1,
    reasons: [reason_count_max]Reason = undefined,
    reason_count: u32 = 0,
    reason_cursor: u32 = 0,
    /// The steps a person's session gave the timeline, each at the moment it ran (`{"step":
    /// ..., "vtime": ...}` lines): its inputs beside the overrides, delivered again by a replay.
    steps: [steps_max]Step = undefined,
    step_count: u32 = 0,
    step_text: [step_text_max]u8 = undefined,
    step_text_used: u32 = 0,

    /// The taped steps, in the order they ran.
    pub fn steps_taped(overrides: *const Overrides) []const Step {
        return overrides.steps[0..overrides.step_count];
    }

    /// A step's text.
    pub fn step_of(overrides: *const Overrides, step: Step) []const u8 {
        return overrides.step_text[step.start..][0..step.size];
    }

    /// The kind of the override next to be applied, if it is pull `pull`'s (an outside answer is
    /// taken from the tape only by a pull of its own kind).
    pub fn kind_at(overrides: *const Overrides, pull: u64) ?Kind {
        if (overrides.cursor == overrides.count) return null;
        const entry = &overrides.entries[overrides.cursor];
        return if (entry.pull == pull) entry.kind else null;
    }

    /// The reason text an override is written back with: its kind's, or its own among the
    /// reasons (looked up, no cursor moved); "" for none.
    pub fn reason_text(overrides: *const Overrides, pull: u64, kind: Kind) []const u8 {
        switch (kind) {
            .egress => return egress_reason,
            .ingress => return ingress_reason,
            .serve => return serve_reason,
            .decision => {},
        }
        var low: u32 = 0;
        var high: u32 = overrides.reason_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (overrides.reasons[middle].pull < pull) low = middle + 1 else high = middle;
        }
        if (low == overrides.reason_count or overrides.reasons[low].pull != pull) return "";
        return overrides.reasons[low].text[0..overrides.reasons[low].size];
    }

    /// The overrides consumed so far (before the cursor) written to `fd`: a timeline extending
    /// this one starts its own tape with what its machine was given before it began.
    pub fn write_consumed(overrides: *const Overrides, fd: linux.fd_t) void {
        for (overrides.entries[0..overrides.cursor]) |*entry| {
            write_override(fd, entry.pull, entry.bytes[0..entry.size], overrides.reason_text(entry.pull, entry.kind));
        }
    }

    /// The overrides still to come of `kind` dropped: a session that listens takes the
    /// timeline's connections from its moment on, the recorded ones never coming back (left
    /// in place, the first pull past one was TapeOutOfOrder).
    pub fn drop_kind(overrides: *Overrides, kind: Kind) u32 {
        var kept: u32 = overrides.cursor;
        for (overrides.entries[overrides.cursor..overrides.count]) |entry| {
            if (entry.kind == kind) continue;
            overrides.entries[kept] = entry;
            kept += 1;
        }
        const dropped = overrides.count - kept;
        overrides.count = kept;
        return dropped;
    }

    /// The reason recorded for pull `pull`, if any. Pulls arrive in increasing order.
    pub fn reason(overrides: *Overrides, pull: u64) ?[]const u8 {
        while (overrides.reason_cursor < overrides.reason_count) {
            const entry = &overrides.reasons[overrides.reason_cursor];
            if (entry.pull > pull) return null;
            overrides.reason_cursor += 1;
            if (entry.pull == pull) return entry.text[0..entry.size];
        }
        return null;
    }

    /// Compares the replay with the tape's checkpoint at this event count, if there is one. A
    /// replay past the next checkpoint's count diverged before it: checkpoints follow guest lines
    /// only (vm.zig's checkpoint), so the tape's event there was a guest line and the replay's
    /// was not (a kernel line, a decision). Waiting for that count instead left every later
    /// checkpoint unchecked (the Lean replica of determinismo's CE13).
    pub fn check(overrides: *Overrides, now: Checkpoint) !void {
        if (overrides.checkpoint_cursor == overrides.checkpoint_count) return;
        const expected = overrides.checkpoints[overrides.checkpoint_cursor];
        if (now.events < expected.events) return;
        overrides.checkpoint_cursor += 1;
        if (expected.events != now.events or expected.branches != now.branches or
            expected.events_hash != now.events_hash)
        {
            return error.ReplayDiverged;
        }
    }

    /// For a replay from inside its segment (a holder's snapshot): the overrides and reasons of
    /// pulls before `pull` passed, and the checkpoints unchecked (their event counts are from
    /// the segment's start, the replay's from its own).
    pub fn seek_inside(overrides: *Overrides, pull: u64) void {
        while (overrides.cursor < overrides.count and overrides.entries[overrides.cursor].pull < pull) {
            overrides.cursor += 1;
        }
        while (overrides.reason_cursor < overrides.reason_count and
            overrides.reasons[overrides.reason_cursor].pull < pull)
        {
            overrides.reason_cursor += 1;
        }
        overrides.checkpoint_cursor = overrides.checkpoint_count;
    }

    /// Replaces `value` if pull `pull` was overridden. Pulls arrive in increasing order.
    pub fn apply(overrides: *Overrides, pull: u64, value: []u8) !bool {
        assert(overrides.cursor <= overrides.count);
        if (overrides.cursor == overrides.count) return false;
        const entry = &overrides.entries[overrides.cursor];
        if (entry.pull < pull) return error.TapeOutOfOrder; // The replay diverged from the tape.
        if (entry.pull > pull) return false;
        if (entry.size != value.len) return error.TapeSizeMismatch;
        @memcpy(value, entry.bytes[0..entry.size]);
        overrides.cursor += 1;
        return true;
    }
};

pub fn write_header(fd: linux.fd_t, header: Header) void {
    assert(fd >= 0);
    assert(header.chain.len <= chain_length_max);
    var buffer: [512 + chain_length_max * 112 + pokes_size_max * 2 + strategy_size_max * 2]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"tape\":{d},\"inputs\":\"{x:0>16}\",\"exploration_seed\":\"{x:0>16}\"," ++
        "\"branch\":{d},\"branch_seed\":\"{x:0>16}\"", .{
        tape_version,  header.inputs,      header.exploration_seed,
        header.branch, header.branch_seed,
    }) catch unreachable; // The keys, three hashes, a fork and a chain fit.
    // Before what may be long (a chain, pokes): claim reads it from the tape's start.
    if (header.extends) |extends| {
        writer.print("," ++ extends_key ++ "{{\"branch\":{d},\"vtime_ns\":{d}}}", .{ extends.branch, extends.vtime_ns }) catch unreachable;
    }
    if (header.chain.len > 0) {
        writer.writeAll(",\"chain\":[") catch unreachable;
        for (header.chain, 0..) |segment, index| {
            if (index > 0) writer.writeAll(",") catch unreachable;
            writer.print("{{\"branch\":{d},\"seed\":\"{x:0>16}\",\"vtime_ns\":{d}", .{
                segment.branch, segment.seed, segment.vtime_ns,
            }) catch unreachable;
            if (segment.jitter_seed) |jitter| {
                writer.print(",\"jitter_seed\":\"{x:0>16}\"", .{jitter}) catch unreachable;
            }
            writer.writeAll("}") catch unreachable;
        }
        writer.writeAll("]") catch unreachable;
    }
    if (header.host) |host| writer.print(",\"host\":\"{x:0>16}\"", .{host}) catch unreachable;
    if (header.tsc_jitter_seed != 0) {
        writer.print(",\"tsc_jitter_seed\":\"{x:0>16}\"", .{header.tsc_jitter_seed}) catch unreachable;
    }
    if (header.clock_jitter_seed) |seed| writer.print(",\"clock_jitter_seed\":\"{x:0>16}\"", .{seed}) catch unreachable;
    if (header.machine) |machine| {
        writer.print(",\"machine\":{{\"epoch_seconds\":{d},\"timer_slack_ns\":{d},\"modulation_stretch_ns\":[{d},{d}],\"timer_delay_permille\":{d},\"custom_faults\":\"{s}\"", .{
            machine.epoch_seconds,
            machine.timer_slack_ns,
            machine.modulation_stretch_ns[0],
            machine.modulation_stretch_ns[1],
            machine.timer_delay_permille,
            machine.custom_faults,
        }) catch unreachable;
        if (machine.fault_poll_ms > 0) writer.print(",\"fault_poll_ms\":{d}", .{machine.fault_poll_ms}) catch unreachable;
        writer.writeAll("}") catch unreachable;
    }
    if (header.margin_branches) |margin| writer.print(",\"margin_branches\":{d}", .{margin}) catch unreachable;
    if (header.strategy) |text| {
        assert(text.len <= strategy_size_max);
        writer.writeAll(",\"strategy\":") catch unreachable;
        std.json.Stringify.value(text, .{}, &writer) catch unreachable;
    }
    if (header.fork) |fork| {
        writer.print(",\"from_branch\":{d},\"from_vtime_ns\":{d}", .{
            fork.branch, fork.vtime_ns,
        }) catch unreachable;
        if (fork.exec) |command| {
            writer.writeAll(",\"from_exec\":") catch unreachable;
            std.json.Stringify.value(command, .{}, &writer) catch unreachable;
        }
        if (fork.pokes) |pokes| {
            assert(pokes.len <= pokes_size_max);
            writer.writeAll(",\"from_poke\":") catch unreachable;
            std.json.Stringify.value(pokes, .{}, &writer) catch unreachable;
        }
    }
    writer.writeAll("}\n") catch unreachable;
    write_all(fd, writer.buffered());
}

pub fn write_override(fd: linux.fd_t, pull: u64, value: []const u8, reason: []const u8) void {
    assert(fd >= 0);
    assert(value.len <= override_size_max);
    assert(reason.len <= reason_size_max);
    var buffer: [96 + 2 * override_size_max + 6 * reason_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"pull\":{d},\"hex\":\"", .{pull}) catch unreachable;
    for (value) |byte| writer.print("{x:0>2}", .{byte}) catch unreachable;
    writer.writeAll("\"") catch unreachable;
    if (reason.len > 0) {
        writer.writeAll(",\"reason\":") catch unreachable;
        std.json.Stringify.value(reason, .{}, &writer) catch unreachable;
    }
    writer.writeAll("}\n") catch unreachable;
    write_all(fd, writer.buffered());
}

const extends_key = "\"extends\":";

/// A timeline's number in its run is whoever creates its tape first's, as a run's id is whoever
/// creates its directory's (runs.zig): the explorer's as it plans one (`claim`), a timeline's
/// that extends another as it starts (`claim_next`: a session's). One sequence, no range apart.
///
/// `claim`: the explorer's. True: `index` is its own, its tape created here (empty until the
/// timeline starts), or there already without another's mark (its own from before an
/// interruption: a resumed run plans the same numbers again). False: the tape there says it
/// extends a timeline: a number taken meanwhile, passed over.
pub fn claim(directory: []const u8, index: u32) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buffer, "{s}/branch-{d}.jsonl", .{ directory, index }, 0) catch return true;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
    switch (linux.errno(fd)) {
        .SUCCESS => {
            _ = linux.close(@intCast(fd));
            return true;
        },
        .EXIST => return !extends_marked(path),
        else => return true, // No tape to tell by: the timeline's own open says why.
    }
}

/// Whether the tape at `path` begins with a header that says it extends a timeline.
pub fn extends_marked(path: [*:0]const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var start: [512]u8 = undefined;
    const size = linux.read(@intCast(fd), &start, start.len);
    if (linux.errno(size) != .SUCCESS) return false;
    const line_end = std.mem.indexOfScalar(u8, start[0..size], '\n') orelse size;
    return std.mem.indexOf(u8, start[0..line_end], extends_key) != null;
}

const claim_tries_max = 1 << 20;

/// A number for a timeline extending another (`header.extends`), taken with its header written:
/// the first free one after the timeline it extends (the explorer's are there as planned, tapes
/// are never removed one by one: the run's next). Linked into place whole, never there empty:
/// the explorer tells a number taken by what its tape says. The number is in `header.branch`,
/// the tape's fd open for its lines to come.
pub fn claim_next(directory: []const u8, header: *Header) !linux.fd_t {
    assert(header.extends != null);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&temporary_buffer, "{s}/.extending-{d}", .{ directory, linux.getpid() }, 0);
    const opened = linux.open(temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.TapeOpen;
    const fd: linux.fd_t = @intCast(opened);
    errdefer _ = linux.close(fd);
    defer _ = linux.unlink(temporary);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    header.branch = header.extends.?.branch;
    for (0..claim_tries_max) |_| {
        header.branch += 1;
        if (linux.errno(linux.ftruncate(fd, 0)) != .SUCCESS) return error.TapeWrite;
        write_header(fd, header.*);
        const path = try std.fmt.bufPrintSentinel(&buffer, "{s}/branch-{d}.jsonl", .{ directory, header.branch }, 0);
        switch (linux.errno(linux.linkat(linux.AT.FDCWD, temporary, linux.AT.FDCWD, path, 0))) {
            .SUCCESS => return fd,
            .EXIST => continue,
            else => return error.TapeOpen,
        }
    }
    return error.NoTimelineNumber;
}

/// A taped step: when it ran, and its text (in Overrides.step_text).
pub const Step = struct { vtime_ns: u64, start: u32, size: u32 };
pub const steps_max = 1 << 16;
pub const step_text_max = 16 << 20;

/// A step a session gave the timeline, at the moment it ran.
pub fn write_step(fd: linux.fd_t, step: []const u8, vtime_ns: u64) void {
    assert(fd >= 0);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"vtime\":{d},\"step\":", .{vtime_ns}) catch unreachable;
    write_all(fd, writer.buffered());
    var text_buffer: [2 * 65536]u8 = undefined;
    var text: std.Io.Writer = .fixed(&text_buffer);
    std.json.Stringify.value(step, .{}, &text) catch return;
    text.writeAll("}\n") catch return;
    write_all(fd, text.buffered());
}

fn step_parse(overrides: *Overrides, value: std.json.Value) !void {
    const text = (value.object.get("step") orelse return error.BadTape).string;
    const vtime_ns: u64 = @intCast((value.object.get("vtime") orelse return error.BadTape).integer);
    if (overrides.step_count == steps_max or overrides.step_text_used + text.len > step_text_max) return error.TapeTooLong;
    if (overrides.step_count > 0 and overrides.steps[overrides.step_count - 1].vtime_ns > vtime_ns) return error.BadTape;
    @memcpy(overrides.step_text[overrides.step_text_used..][0..text.len], text);
    overrides.steps[overrides.step_count] = .{ .vtime_ns = vtime_ns, .start = overrides.step_text_used, .size = @intCast(text.len) };
    overrides.step_count += 1;
    overrides.step_text_used += @intCast(text.len);
}

/// Parses a tape file's contents into its header and `overrides`.
/// A tape's header alone (its first line): what it points into (its chain) is in `scratch`.
pub fn header_of(source: []const u8, scratch: []u8) !Header {
    assert(scratch.len > 0);
    const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    if (line_end == 0) return error.EmptyTape;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return header_take(source[0..line_end], &fba);
}

fn header_take(header_line: []const u8, fba: *std.heap.FixedBufferAllocator) !Header {
    const header = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), header_line, .{});
    if (header != .object) return error.BadTape;
    if ((header.object.get("tape") orelse return error.BadTape).integer != tape_version) {
        return error.UnsupportedTape;
    }
    var result = Header{
        .inputs = try hex_field(header.object, "inputs"),
        .exploration_seed = try hex_field(header.object, "exploration_seed"),
        .branch = @intCast((header.object.get("branch") orelse return error.BadTape).integer),
        .branch_seed = try hex_field(header.object, "branch_seed"),
        .fork = if (header.object.get("from_branch")) |from_branch| .{
            .branch = @intCast(from_branch.integer),
            .vtime_ns = @intCast((header.object.get("from_vtime_ns") orelse
                return error.BadTape).integer),
            .exec = if (header.object.get("from_exec")) |command| command.string else null,
            .pokes = if (header.object.get("from_poke")) |pokes| pokes.string else null,
        } else null,
        .host = if (header.object.get("host") != null) try hex_field(header.object, "host") else null,
        .extends = if (header.object.get("extends")) |extends| .{
            .branch = @intCast((extends.object.get("branch") orelse return error.BadTape).integer),
            .vtime_ns = @intCast((extends.object.get("vtime_ns") orelse return error.BadTape).integer),
        } else null,
        .tsc_jitter_seed = if (header.object.get("tsc_jitter_seed") != null)
            try hex_field(header.object, "tsc_jitter_seed")
        else
            0,
        .clock_jitter_seed = if (header.object.get("clock_jitter_seed") != null)
            try hex_field(header.object, "clock_jitter_seed")
        else
            null,
        .machine = if (header.object.get("machine")) |machine| try machine_parse(machine) else null,
        .margin_branches = if (header.object.get("margin_branches")) |margin|
            (if (margin == .integer and margin.integer > 0 and margin.integer <= std.math.maxInt(u32)) @intCast(margin.integer) else return error.BadTape)
        else
            null,
        .strategy = if (header.object.get("strategy")) |text|
            (if (text == .string) text.string else return error.BadTape)
        else
            null,
    };
    if (header.object.get("chain")) |chain| {
        if (chain != .array or chain.array.items.len > chain_length_max) return error.BadTape;
        const segments = try fba.allocator().alloc(Segment, chain.array.items.len);
        for (chain.array.items, segments) |item, *segment| {
            if (item != .object) return error.BadTape;
            segment.* = .{
                .branch = @intCast((item.object.get("branch") orelse return error.BadTape).integer),
                .seed = try hex_field(item.object, "seed"),
                .vtime_ns = @intCast((item.object.get("vtime_ns") orelse
                    return error.BadTape).integer),
                .jitter_seed = if (item.object.get("jitter_seed") != null)
                    try hex_field(item.object, "jitter_seed")
                else
                    null,
            };
        }
        result.chain = segments;
    }
    return result;
}

pub fn parse(source: []const u8, scratch: []u8, overrides: *Overrides) !Header {
    assert(scratch.len > 0);
    overrides.count = 0;
    overrides.cursor = 0;
    overrides.reason_count = 0;
    overrides.reason_cursor = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header_line = lines.next() orelse return error.EmptyTape;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const Value = std.json.Value;
    const result = try header_take(header_line, &fba);
    // What the header points into stays; the overrides are parsed after it.
    var rest = std.heap.FixedBufferAllocator.init(scratch[fba.end_index..]);
    overrides.checkpoint_count = 0;
    overrides.checkpoint_cursor = 0;
    overrides.checkpoint_every = 1;
    overrides.step_count = 0;
    overrides.step_text_used = 0;
    while (lines.next()) |line| {
        rest.reset();
        const value = try std.json.parseFromSliceLeaky(Value, rest.allocator(), line, .{});
        if (value.object.get("checkpoint")) |checkpoint| {
            try checkpoint_parse(overrides, checkpoint);
            continue;
        }
        if (value.object.get("step") != null) {
            try step_parse(overrides, value);
            continue;
        }
        try override_parse(overrides, value);
    }
    return result;
}

fn override_parse(overrides: *Overrides, value: std.json.Value) !void {
    if (overrides.count == override_count_max) return error.TapeTooLong;
    const entry = &overrides.entries[overrides.count];
    entry.pull = @intCast((value.object.get("pull") orelse return error.BadTape).integer);
    const hex = (value.object.get("hex") orelse return error.BadTape).string;
    if (hex.len > 2 * override_size_max) return error.BadTape;
    entry.size = @intCast((try std.fmt.hexToBytes(&entry.bytes, hex)).len);
    entry.kind = .decision;
    if (value.object.get("reason")) |reason| if (reason == .string) {
        entry.kind = kind_of(reason.string);
    };
    if (value.object.get("reason")) |reason| if (reason == .string and entry.kind == .decision) {
        if (overrides.reason_count == reason_count_max) return error.TapeTooLong;
        const kept = &overrides.reasons[overrides.reason_count];
        kept.pull = entry.pull;
        kept.size = @intCast(@min(reason.string.len, reason_size_max));
        @memcpy(kept.text[0..kept.size], reason.string[0..kept.size]);
        overrides.reason_count += 1;
    };
    if (overrides.count > 0) {
        if (overrides.entries[overrides.count - 1].pull >= entry.pull) return error.BadTape;
    }
    overrides.count += 1;
}

fn checkpoint_parse(overrides: *Overrides, value: std.json.Value) !void {
    if (value != .object) return error.BadTape;
    const checkpoint: Checkpoint = .{
        .events = @intCast((value.object.get("events") orelse return error.BadTape).integer),
        .branches = @intCast((value.object.get("branches") orelse return error.BadTape).integer),
        .events_hash = try hex_field(value.object, "events_hash"),
    };
    checkpoint_keep(overrides, checkpoint);
}

/// Keeps a tape's checkpoint, in order: one in `checkpoint_every`, which doubles (the kept ones
/// thinned to every other) whenever the array is full. Never a limit on a tape's length.
fn checkpoint_keep(overrides: *Overrides, checkpoint: Checkpoint) void {
    if (!checkpoint_kept(checkpoint, overrides.checkpoint_every)) return;
    if (overrides.checkpoint_count == checkpoint_count_max) {
        overrides.checkpoint_every *= 2;
        var kept: u32 = 0;
        for (overrides.checkpoints[0..overrides.checkpoint_count]) |entry| {
            if (!checkpoint_kept(entry, overrides.checkpoint_every)) continue;
            overrides.checkpoints[kept] = entry;
            kept += 1;
        }
        overrides.checkpoint_count = kept;
        if (!checkpoint_kept(checkpoint, overrides.checkpoint_every)) return;
    }
    assert(overrides.checkpoint_count < checkpoint_count_max);
    overrides.checkpoints[overrides.checkpoint_count] = checkpoint;
    overrides.checkpoint_count += 1;
}

fn checkpoint_kept(checkpoint: Checkpoint, every: u32) bool {
    return (checkpoint.events / checkpoint_interval) % every == 0;
}

test "a tape's checkpoints past the array are thinned, never refused" {
    const overrides = try std.testing.allocator.create(Overrides);
    defer std.testing.allocator.destroy(overrides);
    overrides.checkpoint_count = 0;
    overrides.checkpoint_cursor = 0;
    overrides.checkpoint_every = 1;
    const total = 3 * checkpoint_count_max + 7;
    for (1..total + 1) |index| checkpoint_keep(overrides, .{
        .events = index * checkpoint_interval,
        .branches = index,
        .events_hash = index,
    });
    try std.testing.expectEqual(@as(u32, 4), overrides.checkpoint_every);
    try std.testing.expect(overrides.checkpoint_count > checkpoint_count_max / 2);
    try std.testing.expect(overrides.checkpoint_count <= checkpoint_count_max);
    // In order, evenly spread, the tape's end among them.
    for (overrides.checkpoints[1..overrides.checkpoint_count], 0..) |entry, at| {
        try std.testing.expectEqual(overrides.checkpoints[at].events + 4 * checkpoint_interval, entry.events);
    }
    try std.testing.expect(overrides.checkpoints[overrides.checkpoint_count - 1].events + 4 * checkpoint_interval > total * checkpoint_interval);
    // A replay checks the kept ones and passes over the others.
    for (1..total + 1) |index| try overrides.check(.{ .events = index * checkpoint_interval, .branches = index, .events_hash = index });
    try std.testing.expectEqual(overrides.checkpoint_count, overrides.checkpoint_cursor);
}

pub fn write_checkpoint(fd: linux.fd_t, checkpoint: Checkpoint) void {
    var buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{{\"checkpoint\":{{\"events\":{d},\"branches\":{d}," ++
        "\"events_hash\":\"{x:0>16}\"}}}}\n", .{
        checkpoint.events, checkpoint.branches, checkpoint.events_hash,
    }) catch unreachable;
    write_all(fd, line);
}

fn machine_parse(value: std.json.Value) !Machine {
    if (value != .object) return error.BadTape;
    const epoch = value.object.get("epoch_seconds") orelse return error.BadTape;
    const slack = value.object.get("timer_slack_ns") orelse return error.BadTape;
    const stretch = value.object.get("modulation_stretch_ns") orelse return error.BadTape;
    if (epoch != .integer or slack != .integer or stretch != .array or stretch.array.items.len != 2) return error.BadTape;
    for (stretch.array.items) |item| if (item != .integer or item.integer < 0) return error.BadTape;
    if (epoch.integer < 0 or slack.integer < 0) return error.BadTape;
    const delay: i64 = if (value.object.get("timer_delay_permille")) |given| if (given == .integer) given.integer else return error.BadTape else 0;
    if (delay < 0 or delay > 1000) return error.BadTape;
    const custom: []const u8 = if (value.object.get("custom_faults")) |given| if (given == .string) given.string else return error.BadTape else "";
    for (custom) |c| if (!std.ascii.isHex(c)) return error.BadTape;
    const poll: i64 = if (value.object.get("fault_poll_ms")) |given| if (given == .integer) given.integer else return error.BadTape else 0;
    if (poll < 0 or poll > fault_poll_ms_max) return error.BadTape;
    return .{
        .epoch_seconds = @intCast(epoch.integer),
        .timer_slack_ns = @intCast(slack.integer),
        .modulation_stretch_ns = .{ @intCast(stretch.array.items[0].integer), @intCast(stretch.array.items[1].integer) },
        .timer_delay_permille = @intCast(delay),
        .custom_faults = custom,
        .fault_poll_ms = @intCast(poll),
    };
}

/// The machine a strategy decided for a tape's run (its header's), null for none: read before the
/// machine is made, which boots with it.
pub fn machine_of(source: []const u8, scratch: []u8) !?Machine {
    const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const header = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), source[0..line_end], .{});
    if (header != .object) return error.BadTape;
    const machine = header.object.get("machine") orelse return null;
    return try machine_parse(machine);
}

/// The clock's jitter a tape ran with (its header's), 0 for none: read before the machine is
/// made, which boots with it.
pub fn jitter_seed(source: []const u8, scratch: []u8) !u64 {
    const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const header = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), source[0..line_end], .{});
    if (header != .object) return error.BadTape;
    if (header.object.get("tsc_jitter_seed") == null) return 0;
    return hex_field(header.object, "tsc_jitter_seed");
}

test "a tape keeps the clock's jitter its timeline ran with" {
    const allocator = std.testing.allocator;
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{})));
    write_header(pipe[1], .{ .inputs = 0xaa, .exploration_seed = 3, .branch = 1, .branch_seed = 9, .tsc_jitter_seed = 0x1235 });
    _ = linux.close(pipe[1]);
    var buffer: [1024]u8 = undefined;
    const size = linux.read(pipe[0], &buffer, buffer.len);
    _ = linux.close(pipe[0]);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    try std.testing.expectEqual(@as(u64, 0x1235), try jitter_seed(buffer[0..size], scratch));
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const header = try parse(buffer[0..size], scratch, overrides);
    try std.testing.expectEqual(@as(u64, 0x1235), header.tsc_jitter_seed);
    try std.testing.expectEqual(@as(?u64, null), header.clock_jitter_seed);
    // A timeline's own clock, beside the run's.
    var own: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&own, .{})));
    write_header(own[1], .{ .inputs = 0xaa, .exploration_seed = 3, .branch = 2, .branch_seed = 9, .tsc_jitter_seed = 0x1235, .clock_jitter_seed = 0x77 });
    _ = linux.close(own[1]);
    const own_size = linux.read(own[0], &buffer, buffer.len);
    _ = linux.close(own[0]);
    const owned = try parse(buffer[0..own_size], scratch, overrides);
    try std.testing.expectEqual(@as(?u64, 0x77), owned.clock_jitter_seed);
    try std.testing.expectEqual(@as(u64, 0x1235), owned.tsc_jitter_seed);
    // A tape from before it: none.
    try std.testing.expectEqual(@as(u64, 0), try jitter_seed("{\"tape\":2,\"inputs\":\"00000000000000aa\"}\n", scratch));
    // A tree child's: its chain says each ancestor's clock (a root on its own, a child of it on
    // the run's), beside its own.
    const chain = [_]Segment{
        .{ .branch = 0, .seed = 0x11, .vtime_ns = 2_000_000_000, .jitter_seed = 0xab },
        .{ .branch = 4, .seed = 0x44, .vtime_ns = 5_000_000_000 },
    };
    var child: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&child, .{})));
    write_header(child[1], .{ .inputs = 0xaa, .exploration_seed = 3, .branch = 9, .branch_seed = 9, .tsc_jitter_seed = 0x1235, .clock_jitter_seed = 0xcd, .chain = &chain });
    _ = linux.close(child[1]);
    const child_size = linux.read(child[0], &buffer, buffer.len);
    _ = linux.close(child[0]);
    const chained = try parse(buffer[0..child_size], scratch, overrides);
    try std.testing.expectEqualSlices(Segment, &chain, chained.chain);
    try std.testing.expectEqual(@as(?u64, 0xcd), chained.clock_jitter_seed);
}

fn hex_field(object: std.json.ObjectMap, key: []const u8) !u64 {
    assert(key.len > 0);
    const value = object.get(key) orelse return error.BadTape;
    if (value != .string) return error.BadTape;
    return std.fmt.parseInt(u64, value.string, 16);
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return; // Reported when the tape fails to replay.
        written += result;
    }
    assert(written == bytes.len);
}

test "a written tape parses back" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\"," ++
        "\"exploration_seed\":\"0000000000000007\",\"branch\":3," ++
        "\"branch_seed\":\"00000000000000ff\"}\n" ++
        "{\"pull\":10,\"hex\":\"0102\"}\n" ++
        "{\"pull\":12,\"hex\":\"ff\"}\n";
    const header = try parse(source, scratch, overrides);
    try std.testing.expectEqual(@as(u64, 7), header.exploration_seed);
    try std.testing.expectEqual(@as(u32, 3), header.branch);
    try std.testing.expectEqual(@as(u32, 2), overrides.count);
    var value: [2]u8 = .{ 0, 0 };
    try std.testing.expect(!try overrides.apply(9, &value));
    try std.testing.expect(try overrides.apply(10, &value));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &value);
}

test "a session's steps on its timeline's tape parse back, with their moments" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\"," ++
        "\"exploration_seed\":\"0000000000000007\",\"branch\":0," ++
        "\"branch_seed\":\"00000000000000ff\",\"from_branch\":0,\"from_vtime_ns\":15000000000}\n" ++
        "{\"vtime\":15000019720,\"step\":\"det:scenario-pause\"}\n" ++
        "{\"pull\":606,\"vtime\":15100000000,\"hex\":\"01\"}\n" ++
        "{\"vtime\":15227000000,\"step\":\"det:poke 0x1000=0f0b\"}\n";
    const header = try parse(source, scratch, overrides);
    try std.testing.expectEqual(@as(u64, 15_000_000_000), header.fork.?.vtime_ns);
    const steps = overrides.steps_taped();
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqual(@as(u64, 15_000_019_720), steps[0].vtime_ns);
    try std.testing.expectEqualStrings("det:scenario-pause", overrides.step_of(steps[0]));
    try std.testing.expectEqualStrings("det:poke 0x1000=0f0b", overrides.step_of(steps[1]));
    try std.testing.expectEqual(@as(u32, 1), overrides.count); // The override beside them.
}

test "a relayed session's polls, thousands of ingress answers, parse: their reason is their kind" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "{\"tape\":2,\"inputs\":\"00000000000000aa\",\"exploration_seed\":\"0000000000000007\"," ++
        "\"branch\":0,\"branch_seed\":\"00000000000000ff\"}\n");
    for (0..5000) |poll| {
        try source.print(allocator, "{{\"pull\":{d},\"hex\":\"0100000000000000\",\"reason\":\"{s}\"}}\n", .{ 700 + poll, ingress_reason });
    }
    try source.appendSlice(allocator, "{\"pull\":9000,\"hex\":\"07\",\"reason\":\"a strategy's own\"}\n");
    _ = try parse(source.items, scratch, overrides);
    try std.testing.expectEqual(@as(u32, 5001), overrides.count);
    try std.testing.expectEqual(@as(u32, 1), overrides.reason_count); // The strategy's alone.
    try std.testing.expectEqual(@as(?Kind, .ingress), overrides.kind_at(700));
    try std.testing.expectEqual(@as(?Kind, null), overrides.kind_at(699)); // Not this pull's.
    var value: [8]u8 = undefined;
    try std.testing.expect(try overrides.apply(700, &value));
    try std.testing.expectEqual(@as(?Kind, .ingress), overrides.kind_at(701));
}

test "an extending timeline's tape: what was consumed written back, the connections to come dropped" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\",\"exploration_seed\":\"0000000000000007\"," ++
        "\"branch\":0,\"branch_seed\":\"00000000000000ff\"}\n" ++
        "{\"pull\":10,\"hex\":\"07\",\"reason\":\"a strategy's own\"}\n" ++
        "{\"pull\":20,\"hex\":\"0100000000000000\",\"reason\":\"" ++ ingress_reason ++ "\"}\n" ++
        "{\"pull\":30,\"hex\":\"08\",\"reason\":\"a later decision\"}\n" ++
        "{\"pull\":40,\"hex\":\"0100000000000000\",\"reason\":\"" ++ ingress_reason ++ "\"}\n" ++
        "{\"pull\":41,\"hex\":\"aa\",\"reason\":\"" ++ ingress_reason ++ "\"}\n";
    _ = try parse(source, scratch, overrides);
    var one: [1]u8 = undefined;
    var eight: [8]u8 = undefined;
    try std.testing.expect(try overrides.apply(10, &one));
    try std.testing.expect(try overrides.apply(20, &eight));
    try std.testing.expectEqualStrings("a strategy's own", overrides.reason_text(10, .decision));
    try std.testing.expectEqualStrings(ingress_reason, overrides.reason_text(20, .ingress));
    // The session takes over: the two ingress answers to come go, the decision stays.
    try std.testing.expectEqual(@as(u32, 2), overrides.drop_kind(.ingress));
    try std.testing.expect(!try overrides.apply(25, &one));
    try std.testing.expect(try overrides.apply(30, &one));
    try std.testing.expect(!try overrides.apply(40, &eight)); // Gone: answered live.
    try std.testing.expect(!try overrides.apply(50, &one)); // And no TapeOutOfOrder past them.
}

test "a timeline's number is whoever creates its tape first's: the explorer passes over one an extending timeline took" {
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/det-tape-claim-{d}", .{linux.getpid()}, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(directory, 0o755)));
    var path_buffer: [96]u8 = undefined;
    defer {
        for (0..5) |index| {
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/branch-{d}.jsonl", .{ directory, index }, 0) catch unreachable;
            _ = linux.unlink(path);
        }
        _ = linux.rmdir(directory);
    }
    // The explorer plans 0 and 1.
    try std.testing.expect(claim(directory, 0));
    try std.testing.expect(claim(directory, 1));
    // A timeline extending 0 takes the run's next, 2, its header there at once.
    var header: Header = .{
        .inputs = 0xaa,
        .exploration_seed = 7,
        .branch = 0,
        .branch_seed = 0xff,
        .extends = .{ .branch = 0, .vtime_ns = 15_000_000_000 },
    };
    _ = linux.close(try claim_next(directory, &header));
    try std.testing.expectEqual(@as(u32, 2), header.branch);
    // The explorer passes over 2 and goes on with 3; resumed, it plans the same numbers again.
    for (0..2) |_| {
        try std.testing.expect(claim(directory, 0));
        try std.testing.expect(claim(directory, 1));
        try std.testing.expect(!claim(directory, 2));
        try std.testing.expect(claim(directory, 3));
    }
    // A timeline extending the extending one: after the explorer's 3.
    var second = header;
    second.extends = .{ .branch = 2, .vtime_ns = 20_000_000_000 };
    _ = linux.close(try claim_next(directory, &second));
    try std.testing.expectEqual(@as(u32, 4), second.branch);
    // Its tape says what it extends.
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/branch-4.jsonl", .{directory}, 0);
    const fd: linux.fd_t = @intCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    defer _ = linux.close(fd);
    var source: [512]u8 = undefined;
    const size = linux.read(fd, &source, source.len);
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const parsed = try parse(source[0..size], scratch, overrides);
    try std.testing.expectEqual(@as(u32, 4), parsed.branch);
    try std.testing.expectEqual(@as(u32, 2), parsed.extends.?.branch);
    try std.testing.expectEqual(@as(u64, 20_000_000_000), parsed.extends.?.vtime_ns);
}

test "a replay from inside its segment takes the tape from its pull on" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\"," ++
        "\"exploration_seed\":\"0000000000000007\",\"branch\":3," ++
        "\"branch_seed\":\"00000000000000ff\"}\n" ++
        "{\"pull\":10,\"hex\":\"01\"}\n" ++
        "{\"pull\":20,\"hex\":\"02\"}\n" ++
        "{\"checkpoint\":{\"events\":64,\"branches\":5,\"events_hash\":\"0000000000000009\"}}\n";
    _ = try parse(source, scratch, overrides);
    // From the start, pull 15 comes after the override of pull 10: the replay parted.
    var value: [1]u8 = .{0};
    try std.testing.expectError(error.TapeOutOfOrder, overrides.apply(15, &value));
    // A holder's snapshot at pull 15: what came before it passed, its checkpoints unchecked.
    _ = try parse(source, scratch, overrides);
    overrides.seek_inside(15);
    try std.testing.expect(!try overrides.apply(15, &value));
    try std.testing.expect(try overrides.apply(20, &value));
    try std.testing.expectEqual(@as(u8, 2), value[0]);
    try overrides.check(.{ .events = 64, .branches = 6, .events_hash = 1 });
}

test "a path round-trips through the header" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe(&pipe));
    defer _ = linux.close(pipe[0]);
    const chain = [_]Segment{
        .{ .branch = 0, .seed = 0xa, .vtime_ns = 1_200_000_000 },
        .{ .branch = 17, .seed = 0xb, .vtime_ns = 3_410_000_000 },
    };
    write_header(pipe[1], .{
        .inputs = 1,
        .exploration_seed = 2,
        .branch = 42,
        .branch_seed = 3,
        .chain = &chain,
        .host = 0xfeed,
    });
    _ = linux.close(pipe[1]);
    var source: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &source, source.len);
    const header = try parse(source[0..size], scratch, overrides);
    try std.testing.expectEqual(@as(u32, 42), header.branch);
    try std.testing.expectEqual(@as(usize, 2), header.chain.len);
    try std.testing.expectEqual(chain[1], header.chain[1]);
    try std.testing.expectEqual(@as(?u64, 0xfeed), header.host);
}

test "a tape keeps the machine a strategy decided for its run" {
    const allocator = std.testing.allocator;
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{})));
    const machine: Machine = .{ .epoch_seconds = 951782400, .timer_slack_ns = 250_000, .modulation_stretch_ns = .{ 5_000_000, 90_000_000 }, .timer_delay_permille = 600, .custom_faults = "5b5d" };
    write_header(pipe[1], .{ .inputs = 0xaa, .exploration_seed = 3, .branch = 1, .branch_seed = 9, .machine = machine });
    _ = linux.close(pipe[1]);
    var buffer: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &buffer, buffer.len);
    _ = linux.close(pipe[0]);
    try std.testing.expectEqual(.SUCCESS, linux.errno(size));
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    const read = (try machine_of(buffer[0..size], scratch)).?;
    try std.testing.expectEqual(machine.epoch_seconds, read.epoch_seconds);
    try std.testing.expectEqual(machine.timer_delay_permille, read.timer_delay_permille);
    try std.testing.expectEqualStrings(machine.custom_faults, read.custom_faults);
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const header = try parse(buffer[0..size], scratch, overrides);
    try std.testing.expectEqual(machine.modulation_stretch_ns, header.machine.?.modulation_stretch_ns);
    try std.testing.expectEqualStrings(machine.custom_faults, header.machine.?.custom_faults);
}


test "a replay past a checkpoint's count diverged" {
    const overrides = try std.testing.allocator.create(Overrides);
    defer std.testing.allocator.destroy(overrides);
    overrides.* = .{ .entries = undefined, .count = 0, .cursor = 0 };
    // The tape's checkpoints at events 64, 128 and 192 (guest lines there).
    for ([_]u64{ 64, 128, 192 }, 1..) |events, hash| {
        overrides.checkpoints[overrides.checkpoint_count] = .{ .events = events, .branches = 0, .events_hash = hash };
        overrides.checkpoint_count += 1;
    }
    // The replay's event 64 is a kernel line (no check), its guest lines go on from 65: the
    // first check, at 128, finds the replay past the tape's 64.
    try std.testing.expectError(error.ReplayDiverged, overrides.check(.{ .events = 128, .branches = 0, .events_hash = 2 }));
    // Below the next checkpoint's count: nothing to compare yet.
    overrides.checkpoint_cursor = 0;
    try overrides.check(.{ .events = 0, .branches = 0, .events_hash = 0 });
    try std.testing.expectEqual(@as(u32, 0), overrides.checkpoint_cursor);
    // At it, the same: compared.
    try overrides.check(.{ .events = 64, .branches = 0, .events_hash = 1 });
    try std.testing.expectEqual(@as(u32, 1), overrides.checkpoint_cursor);
}
