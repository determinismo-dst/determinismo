// SPDX-License-Identifier: MIT
//! The determinismo command line.
//!
//!   run       boot one timeline from scratch
//!   explore   boot once, snapshot at setup_complete, then run many branches from the snapshot,
//!             each with its own decisions, and report properties across the multiverse
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("core").vm;
const mptable = @import("core").mptable;
const kvm = @import("core").kvm;
const Snapshot = @import("core").snapshot;
const Events = @import("core").events;
const report = @import("report.zig");
const Strategy = @import("strategy.zig");
const Strategies = @import("strategies.zig");
const tape = @import("core").tape;
const guest_memory = @import("core").guest_memory;
const regex = @import("regex");
const fd_pass = @import("fd_pass.zig");
const holders = @import("holders.zig");
const event_files = @import("event_files.zig");
const label_command = @import("label.zig");
const bandit_zig = @import("bandit.zig");
const activity = @import("activity.zig");
const saver_zig = @import("core").saver;
const build_options = @import("build_options");
const prepare = @import("prepare.zig");
const schema = @import("determinismo").schema;
const kubernetes = @import("kubernetes.zig");
const serve = @import("serve.zig");
const mcp = @import("mcp.zig");
const merge = @import("merge.zig");
const script = @import("script.zig");
const tla = @import("tla.zig");
const quint = @import("quint.zig");
const veil = @import("veil.zig");
const advisor_zig = @import("advisor.zig");
const draws_zig = @import("draws.zig");
const serve_call = @import("serve_call.zig");
const query = @import("query.zig");
const runs_cli = @import("runs_cli.zig");
const bundle = @import("bundle.zig");
const cpus = @import("cpus.zig");
const timeline_limit = @import("timeline_limit.zig");
const checks = @import("checks.zig");
const causality = @import("causality.zig");
const explain = @import("explain.zig");
const shrink = @import("shrink.zig");
const mutate = @import("mutate.zig");
const verify = @import("verify.zig");
const replays = @import("replays.zig");
const runs = @import("runs.zig");
const changed = @import("changed.zig");
const extract = @import("extract.zig");
const event_sets = @import("event_sets.zig");
const profiler = @import("profile.zig");

const usage =
    \\usage: determinismo run     <machine options> [--trace <out.txt>] [--events <out.jsonl>]
    \\       determinismo serve   [--listen <address:port>[,<address:port>...]] [--public-listen <address:port>] [--data <dir>]
    \\                            [--archive "<cmd>"] [--ui <index.html>]
    \\                            [--snapshots-keep-hours <h>]   (runs' snapshots on disk, from
    \\                            causality analyses: removed when none was saved for that long;
    \\                            24 by default) [--failure-snapshots]   (each failing
    \\                            property's first failing timeline saved to disk as soon as it
    \\                            is found, for analyses to start at once; off: a replay each)
    \\                            [--failure-analysis]   (each analyzed at once, in the background,
    \\                            on 4 CPUs beside the runs)
    \\                            [--machine-start-seconds <s>]   (how long a machine asked for
    \\                            may wait for a CPU before it is given up, 600 by default)
    \\                            [--machines-per-cpu <n>]   (how many machines share a CPU,
    \\                            4 by default: sandboxes are idle most of the time; never
    \\                            with a timeline's deterministic VM)
    \\                            <machine options>
    \\       determinismo mcp     <machine options>   (an MCP server on stdio, for agents)
    \\       determinismo verify  <explore options> --record <run.jsonl> --tape-dir <dir>
    \\                            [--sample <n>] [--jobs <n>]   (a sample of a run's timelines
    \\                            replayed from their tapes, beside whatever else runs: each must
    \\                            replay to its recorded history); or --run <run directory>
    \\                            for a run serve made: its options, record and tapes
    \\       determinismo mutate  <explore options> --mutants <mutants.jsonl> [--out <dir>]
    \\                            (each mutant a patch to a node's build: caught, never ran, or
    \\                            unnoticed)
    \\       determinismo explore <machine options> [--branches <n>] [--branch <index>] [--jobs <n>]
    \\                            [--time-budget <duration>]   (e.g. 90s, 10m, 2h: timelines until
    \\                            then, --branches at most)
    \\                            [--timeline <duration>]   (each timeline's drivers run that long
    \\                            in virtual time; part of the inputs)
    \\                            [--clock-start-max <duration | 0>]   (each timeline's wall clock
    \\                            moved forward up to this as its commands begin, log-uniform
    \\                            from 1 s, so what seeds from the time differs; 30m by default)
    \\                            [--drive-max <duration | none>]   (a scenario without a length
    \\                            of its own: its driver phase drawn up to that long; 20m by
    \\                            default, none: a drawn number of starts; part of the inputs)
    \\                            [--trace-errno <n>]   (every system call failing with errno n
    \\                            becomes a syscall_error event: 13, EACCES; 28, ENOSPC; 0, any
    \\                            but EAGAIN, EINTR and ETIMEDOUT)
    \\                            [--epoch <unix seconds | YYYY-MM-DD>]   (the guest's wall clock
    \\                            at boot: the profile's, else the day after its newest image was
    \\                            made, else 2026-01-01)
    \\                            [--min-drive <duration>]   (before an eventually command, the
    \\                            drivers run at least a drawn time, a tenth of this up to it, or
    \\                            until they end; default the scenario's, else 10s; 0 none)
    \\                            [--drivers-cpu-weight <n>]   (the test commands' cgroup's CPU
    \\                            weight beside the nodes' (100 each), 0 none: in the root
    \\                            cgroup; default drawn per timeline: 0, 100 or 25)
    \\                            [--return-branches <n>]   (a tree's branches from each moment it
    \\                            returns to: 4; fewer branches, more moments a generation)
    \\                            [--horizon <duration>]   (a tree's returns run that long past
    \\                            their moment, then stop: short branches, extended when they
    \\                            find something; each drawn from half to one and a half
    \\                            times it; default: to the timeline's end)
    \\                            [--return-offsets <duration,...>]   (a return just after a
    \\                            behavior lands that long before it, one drawn per return;
    \\                            default 0,0,0,1s,5s,30s; 0: always just after)
    \\                            [--no-archive]   (Go-Explore's archive, on by default: half the
    \\                            returns to the newest frontier, the rest to the least visited
    \\                            behaviors of any generation; without it, the frontier only)
    \\                            [--no-prefer-sometimes]   (on by default, as Antithesis does:
    \\                            returns go first to just after a `sometimes` or `reachable`
    \\                            assertion made true, the states the program marks worth
    \\                            reaching; without it, every new behavior weighs the same)
    \\                            [--no-prefer-severe]   (on by default: a new kind of output
    \\                            line that reads as trouble, an error, exception, panic, timeout,
    \\                            weighs as a `sometimes` made true; without it, as any line)
    \\                            [--no-ranges]   (on by default: each number a system's events
    \\                            carry is a learned range, its highest and lowest kept, a
    \\                            timeline past either returned to; without it, numbers count
    \\                            for nothing)
    \\                            [--no-memory-objective]   (on by default: each node's anonymous
    \\                            memory above its least is an objective the tree climbs, a slow
    \\                            leak grown into an OOM kill; without it, not counted)
    \\                            [--no-objective-extend]   (on by default: a timeline the tree
    \\                            returns to an objective's best drives one more phase past its
    \\                            parent's end, so a path grows a phase a generation; without
    \\                            it, a return ends when its parent would)
    \\                            [--no-config-bandit]   (on by default: a tree's configuration
    \\                            draws, fault regimes' and the composer's, come more often at the
    \\                            values that found new behaviors or failures, never only those;
    \\                            without it, independent draws)
    \\                            [--no-swarm]   (each timeline some of the fault kinds, weighted,
    \\                            in regimes of rate and duration redrawn as it goes, its drivers
    \\                            and load swarmed too: swarm testing; without it, every kind
    \\                            alike at a fixed rate, every driver)
    \\                            [--keep <command,...>]   (the composer's swarm keeps them in every
    \\                            timeline: a trial of a new driver)
    \\                            [--fault-weights <kind=weight,...>]   (half the timelines keep
    \\                            these kinds at these weights, 1 to 64: the kinds a causality
    \\                            analysis found inside a failure's jump, made common)
    \\                            [--fault-exclusions <regex>]   (Antithesis's fault_exclusions:
    \\                            nodes, and pods on Kubernetes, whose names match it, Rust's
    \\                            regex syntax, anywhere in the name, get no faults)
    \\                            [--pipeline <n>]   (a tree's generations of timelines planned
    \\                            from the setup snapshot before its first returns, 1 to 4, and
    \\                            queued ahead after: default 2 up to 16 workers, else 3)
    \\                            [--generation <n>]   (a tree's timelines per generation: 16,
    \\                            or a multiple of it for machines with more CPUs)
    \\                            [--timeline-limit <duration>]   (1h: a timeline not finished by
    \\                            then, in virtual time, ends as hung)
    \\                            [--timeline-limit-learned <multiple>]   (2: a tree's timeline
    \\                            stops, cut short and without a verdict, this many times the
    \\                            normal ends' 99th percentile past the branch point, once 40 ended,
    \\                            never under 5 minutes until 400 ended, 30 s after; 0: off)
    \\                            [--retroactive '<text>']...   (output lines with it are left out
    \\                            of the events; a replay of a timeline writes them)
    \\                            [--changed <diff file | git range>]   (a targeted run: the tree
    \\                            returns first to timelines that ran changed lines, and says
    \\                            which hunks ran and which never did)
    \\                            [--changed-repository <directory | URL>]   (where the range
    \\                            is: a commit, a.b, v1.6.0..v1.7.0; a URL is fetched into the
    \\                            cache; one revision is that commit's change)
    \\                            [--branching tree|flat]   (tree, the default: also from moments
    \\                            of earlier branches that reached new behaviors; replay one by
    \\                            its tape)
    \\                            [--strategy "<plugin> <args>"]...   (several: each asked in
    \\                            order, strategies.zig) [--strategy-follow]   (their files
    \\                            followed: new bytes reach the next timelines) [--tape-dir <dir>]
    \\                            [--run-url <url>]   (the run's HTTP API, told to the strategy:
    \\                            serve gives it) [--history <file>]   (the behaviors the
    \\                            system's last runs reached, record.jsonl.behaviors: one they
    \\                            never reached weighs as a sought one; serve gives it)
    \\                            [--tape <branch.jsonl> [--draws-out <file>]]   (with
    \\                            --draws-out, the replay's named draws as it stops: each
    \\                            label's last values, with their pulls)
    \\                            [--run <run directory> [--branch <n>]]   (the run's own options:
    \\                            its machine, system, seed, scenario, profile; with --branch,
    \\                            that timeline's tape, for a moment of it)
    \\                            [--at-vtime-ms <ms>] [--until '<condition>' [--rewind-ms <ms>]]
    \\                            (both: the condition, or that time at the latest)
    \\                            [--exec "<cmd>" | --exec-script <file>]   (a command a line, a
    \\                            line ending in a backslash going on in the next one, run
    \\                            in turn, each at most 4080 bytes (what reaches the guest in a
    \\                            page: a longer one is refused); or a step: "det:background
    \\                            <cmd>" runs beside the next ones, "det:wait <ms>" runs on,
    \\                            "det:until <ms> <condition>"
    \\                            runs on until an event matches, <ms> at most (0: no limit);
    \\                            "det:frozen <cmd>" runs the command with the nodes and the
    \\                            runner's side frozen meanwhile: it reads the moment itself, not
    \\                            one its own run let the system reach (a node entered with
    \\                            det-nodes exec waits; read it from outside, /proc and the node's
    \\                            root under /run/det/nodes))
    \\                            [--exec-interactive]   (then steps from standard input, a line
    \\                            each, the machine paused between them: "[determinismo] step
    \\                            done" after each; its end ends the session. Serve's sessions)
    \\                            [--exec-live]   (the same, the guest running on between them:
    \\                            each step at a moment 1 ms after it came, printed)
    \\                            [--extend]   (with --tape and --at-vtime-ms: from the moment
    \\                            on, recorded as another timeline of the tape's run, under the
    \\                            run's next number: its tape, events and record line. A
    \\                            session is a timeline)
    \\                            [--fork-snapshots <dir>]   (the guest's forks, sdk.fork, saved
    \\                            there: fork-<vtime ns>, for its futures)
    \\                            [--checkpoint-snapshots <dir>]   (with --extend: a step
    \\                            "det:checkpoint [name]" saves the machine there, as the
    \\                            timeline's replay snapshot at that moment: b<timeline>-<ms>)
    \\                            [--fork-futures]   (with --from-snapshot of a fork's: branch i
    \\                            is future i + 1, its fork's index answered so)
    \\                            [--continue]   (after --exec, run on to the end)
    \\                            [--fresh-seed <n>]   (with --exec: from the moment on,
    \\                            randomness from n, the guest kernel's generator reseeded:
    \\                            the branch's own future, as Antithesis's branches)
    \\                            [--from-branch <index> --from-vtime-ms <ms> [--from-exec "<cmd>"]
    \\                            [--from-poke <guest physical address>=<hex bytes>[,...]]]   (the
    \\                            VMM writes those bytes at the fork point: a what-if)
    \\                            [--save-snapshots <dir> --save-at-ms <ms,ms,...>]   (with --tape
    \\                            or --branch: the replay saved to disk at those moments, each
    \\                            the pages changed since the one before)
    \\                            [--from-snapshot <dir>/<name>]   (branches from one saved)
    \\                            [--tape-snapshot <dir>/<name>]   (with --tape: the timeline on
    \\                            from a snapshot saved of it, b<branch>-<ms>, not replayed to it)
    \\                            [--record <results.jsonl>] [--shard <k>/<n>]
    \\                            [--verify-replays <percent>]   (with --record and --tape-dir:
    \\                            that share of the timelines replayed from their tapes as the
    \\                            run goes, beside its workers, and each failing property's first
    \\                            failing timeline at its end: "timelines replay to their recorded
    \\                            history"; 20 by default, 0 for none)
    \\                            [--run-key <pid>]   (a verify replay's: the run it belongs to,
    \\                            its explorer's pid, for its CPU and memory; taken from an
    \\                            ancestor only)
    \\                            [--resume]   (with --record: continue that run, its recorded
    \\                            timelines skipped; the same inputs, seed and branching; a tree
    \\                            without a strategy, from its timelines' summaries)
    \\                            [--no-cpu-modulation]   (branches at one speed: they run at
    \\                            varying speeds by default, as Antithesis's with faults)
    \\                            [--cpu-modulation-stretch-us <min>-<max>]   (how long a speed
    \\                            lasts: 10000-200000 by default)
    \\                            [--no-holders]   (no in-run snapshots: every node made by a
    \\                            replay of its parent, as a branch's replay makes it)
    \\                            [--verify-holders]   (remake every node an in-run snapshot made
    \\                            by a replay and compare them, to check holders; slower)
    \\                            [--holders-on-disk]   (every in-run snapshot written to the
    \\                            run's directory, as while memory runs low: to check them)
    \\                            [--holders-on-disk-sync]   (the same, each written by the
    \\                            timeline's own process, as below the memory reserve)
    \\                            [--holders-leave]   (every in-run snapshot in memory leaves at
    \\                            once, written to disk first, as under memory pressure: to check it)
    \\                            [--holders-retain]   (in-run snapshots in memory kept past their
    \\                            generation's judgment, until room is needed: an arm to measure)
    \\                            [--no-holders-writeback]   (a snapshot written to disk left to the
    \\                            kernel's dirty thresholds, not started at once: an arm to measure)
    \\                            [--keep-passing-checks <N>]   (a passing host check's input
    \\                            kept, compressed, in one timeline of N, for a fixed checker to
    \\                            judge again; default 16, 0 for none)
    \\                            [--holders-budget <GB>]   (the kept snapshots' room on disk;
    \\                            default: half the disk's free space above its reserve)
    \\                            [--data <dir>]   (the host's runs, where this one goes:
    \\                            $DETERMINISMO_DATA, else ~/.determinismo; serve shows them)
    \\                            [--events-dir <dir>]   (every branch's events, for query, and
    \\                            the system's pin)
    \\                            [--system <pin.json>]   (a pinned system and its node disks,
    \\                            booted as is: replays on another host of the same CPU model)
    \\       determinismo merge   <results.jsonl>...   (the records of an exploration's shards)
    \\       determinismo validate (--program <p> | --compose <file> | --kubernetes <dir>)
    \\                            [--profile <p>] [--cache <dir>] [--no-faults ...]   (the system
    \\                            resolved without booting it, and what would keep a run from
    \\                            testing it: invalid commands, scenarios with nothing to start)
    \\       determinismo script  <events.jsonl>       (a branch's shape, for --script)
    \\       determinismo tla     --spec <Spec.tla> --events <events.jsonl> [--tla2tools <jar>]
    \\       determinismo quint   --spec <Spec.qnt> --events <events.jsonl[.zst] | directory>
    \\                            [--branch <n>] [--main <module>] [--invariant <name>]
    \\                            [--quint <command>] [--piece <steps>]   (a timeline's own
    \\                            events, those named like an action of the spec, as a run of
    \\                            it, a long one in pieces: docs/QUINT.md)
    \\       determinismo veil    --module <M.lean> --map <map.json> --instance '<{ node := Fin 3 }>'
    \\                            --events <directory> --branch <n> --veil <checkout> [--theory <t>]
    \\                            [--lake <command>]   (a timeline's lines as a Veil model's action
    \\                            labels, replayed by its #replay: docs/VEIL.md)
    \\       determinismo runs    list | show <id> | properties <id> [--details] |
    \\                            logs <id> <timeline> <seconds> | search <id> '<condition>' |
    \\                            export <id> <timeline> <seconds | failure> [--property <message>] [--html] |
    \\                            exec <id> <timeline> <seconds> --node <node> '<command>' |
    \\                            logged <id>   (what its nodes logged as errors, as templates) |
    \\                            start (--program | --compose) <path> [...] | stop <id>
    \\                            [--url http://host:port]   (serve's runs from a terminal,
    \\                            as Antithesis's Snouty: see runs_cli.zig)
    \\       determinismo bundle  <run directory> <timeline> <out> [--store <dir>]   (the
    \\                            timeline with all it replays on, for another host: explore
    \\                            --run . --branch <n> inside it; with --store, its inputs kept
    \\                            once by digest there; see bundle.zig)
    \\       determinismo bundle  fetch <bundle> <store>   (a stored bundle's inputs put back,
    \\                            each checked against its digest)
    \\       determinismo query   <events-dir> '<condition>' [temporal conditions] (see query.zig)
    \\       determinismo events  <events-dir> '<pipeline>' (event sets, see event_sets.zig)
    \\       determinismo shrink <options> --property '<message>' (--script <script.json> |
    \\                            --seed <s> --branch <n> | --tape <tape>) [--timelines <n>]
    \\                            [--out <path>] [--json]   (the fewest faults the failure needs:
    \\                            see shrink.zig)
    \\       determinismo causality <options> --branch <n> --property '<message>' [--points <k>]
    \\                            [--futures <m>] [--refine <rounds>] [--moments-max <n>]
    \\                            [--jump-min <0..1>] [--gap-min-ms <ms>] [--tape <tape>]
    \\                            [--planner <cmd> | tcp://host:port] [--run-url <url>]
    \\                            [--verdict '<condition>']   (the bug, instead of the property)
    \\                            [--snapshots <dir>] [--json]   (see causality.zig)
    \\                            [--explain-exec '<command>' [--explain-dir <dir>]]   (futures
    \\                            inside the jump with the command at their moment: logs up)
    \\       determinismo explain <options> (--tape <tape> | --run <run directory> --branch <n>)
    \\                            --property '<message>' [--faults <k>] [--variants <m>]
    \\                            [--jobs <j>] [--json]   (which details of the failure's last k
    \\                            faults it needed: each drawn again m times against a
    \\                            control; see explain.zig)
    \\                            [--draw <name>[=<v>,<v>...]]   (a named draw of the scenario's
    \\                            own varied too, or set to each value: a clock step's size)
    \\       determinismo extract <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --to <local file>
    \\       determinismo inject  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --from <local file> [--mode <octal>]
    \\                            [--then '<command>'] [--continue]
    \\       determinismo profile <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--ms <duration>] [--interval-us <us>] [--all]
    \\                            [--pid <pid>] [--svg <flame graph.svg>] [--folded <file>]
    \\       determinismo stacks  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--pid <pid>]   (every thread's stack there)
    \\
    \\system options (instead of --disk; see ARCHITECTURE.md §10):
    \\  (--program <test program> | --compose <compose.yaml> | --kubernetes <manifests dir>)
    \\  [--images <ref,...>]   (with --kubernetes: images loaded beside those the manifests name,
    \\                         fully qualified, as Antithesis's launch lists them: an operator's)
    \\  [--profile <name>|<a,b,..>|all]
    \\  [--scenario <name>|all] [--cache <dir>] [--script <script.json>] [--injector <executable>]...
    \\  [--faults +restart,+crash,-interleave,...]   (fault kinds every node also allows, or none
    \\                            does: -)
    \\  [--no-faults <node>,...]   (nodes that get no faults: a client, a monitor)
    \\  [--coverage <set>|off]     (every node's coverage set: "include,-exclude"; off: none,
    \\                            the instrumentation's cost measured on the same build)
    \\
    \\machine options:
    \\  --kernel <bzImage> [--initrd <file>] [--memory-mib <n>] [--disk <image>]...
    \\  [--cmdline <text> | --append <text>] [--deterministic] [--seed <n>]
    \\  [--margin-branches <n>] [--timer-slack-us <n>] [--timer-landing-permille <0-1000>] [--branch-event <raw PMU event>]
    \\  [--watch <guest physical address>[:<bytes>]]   (debugging a replay: every write to those
    \\                   bytes logged, its moment, RIP and CR3; the history stays the recorded one)
    \\  [--tsc-jitter-seed <n>] [--tsc-jitter-exact] [--cpuid <file>] [--guest-cpu host|vm_v1]
    \\  [--vcpus <n>]   (run only: the fast VM for developing, n vCPUs on host time, not
    \\                   deterministic: docs/DEVELOPING.md; up to 32)
    \\
    \\--deterministic needs the determinismo-patched KVM; explore implies it.
    \\--branch-event: what the guest's clock counts (default 0x20c4, retired taken branches;
    \\0x01c4, conditional ones, was the default until 2026-11-02). A run keeps it in its
    \\machine.json, so that its resumes and replays count the same.
    \\--cpuid: the guest's CPUID table from a file (`determinismo cpuid` on the recording host),
    \\to replay another CPU model's runs here: the guest then runs the code it ran there.
    \\Refused when this host lacks a feature of it.
    \\--guest-cpu vm_v1: determinismo VM v1, one guest CPU on every host (Antithesis's VM v1: family 6
    \\model 85 stepping 7, AVX-512 F and CD only, fixed caches), kept in machine.json.
    \\--tsc-jitter-exact: the seed kept (its tape's input), the exact clock read: a run recorded
    \\with a seed while KVM still ignored it.
    \\--tsc-jitter-seed: the clock's low bits jitter read to read, from this seed (CPU-jitter
    \\entropy sources need it: Go's FIPS mode). Not given: from --seed (a replay by seed and
    \\branch reads its run's), a tape's, or a run's (machine.json, its record); 0, or a run from
    \\before it, reads the exact clock.
    \\
;

/// print-fatal-signals: the kernel logs every process killed by a core-dumping signal (segfault,
/// abort, ...), even after a handler printed a trace: det-init's "no process crashes" reads it.
const cmdline_default = "console=ttyS0 earlyprintk=serial,ttyS0 acpi=off pci=off nokaslr " ++
    "reboot=t panic=-1 i8042.nokbd i8042.noaux tsc=reliable no_timer_check " ++
    "print-fatal-signals=1";
const memory_mib_min = 64;
const memory_mib_max = VM.memory_size_max >> 20;
const arguments_max = 64;
const branches_max = 100_000;

const Command = enum { run, explore, validate };

const Arguments = struct {
    command: Command,
    kernel_path: []const u8 = "",
    initrd_path: ?[]const u8 = null,
    memory_mib: u32 = 1024,
    cmdline: []const u8 = cmdline_default,
    /// The command line as given (--cmdline, --append), before --deterministic adds its own:
    /// what a run keeps (machine.json) for its replays, which add them again.
    cmdline_given: []const u8 = cmdline_default,
    deterministic: bool = false,
    seed: u64 = 0,
    margin_branches: u32 = 128,
    /// A replay's watchpoint (`--watch <guest physical address>[:<size>]`, debugging only).
    watch: ?VM.Watch = null,
    timer_slack_us: u64 = 1000,
    /// How far into its slack a timer lands at the earliest (VM.Options.timer_delay_permille).
    timer_delay_permille: u16 = 0,
    /// A plugin's own faults for the guest (`det.custom_faults=`, hex), adopted from a tape or a
    /// record (tape.Machine.custom_faults).
    custom_faults: ?[]const u8 = null,
    /// The fault injector's poll (`det.fault_poll_ms=`, tape.Machine.fault_poll_ms): 0, none.
    fault_poll_ms: u32 = 0,
    /// The raw PMU event that is the guest's clock (see VM.Options.branch_event).
    branch_event: u64 = VM.branch_event_default,
    /// Another host's guest CPUID table (`determinismo cpuid`'s), to replay its runs here.
    cpuid_path: ?[]const u8 = null,
    /// The guest's CPU: the host's (deterministic) or determinismo VM v1 (`--guest-cpu vm_v1`).
    guest_cpu: VM.GuestCpu = .host,
    /// `run --vcpus <n>`: the fast VM's vCPUs (1: a one-vCPU machine as always).
    vcpus: u32 = 1,
    /// `run --dev <dir>`: the fast VM in dev mode, its "explore from here" snapshots written there.
    dev_directory: ?[]const u8 = null,
    /// `explore --hold-scenario`: from a fast VM's snapshot, its scenario not started.
    hold_scenario: bool = false,
    /// `explore --exec-at-start`: --exec's moment the snapshot's own, a millisecond on.
    exec_at_start: bool = false,
    /// The clock's jitter (VM.Options.tsc_jitter_seed): null, not given (a new run draws one, a
    /// run's own replays take its machine.json's, none there meaning the exact clock).
    tsc_jitter_seed: ?u64 = null,
    /// `--tsc-jitter-exact`: the seed kept, the exact clock read (VM.Options.tsc_jitter_exact).
    tsc_jitter_exact: bool = false,
    events_path: ?[]const u8 = null,
    /// The timeline's fault events only (`--faults-record`: causality's futures).
    faults_record_path: ?[]const u8 = null,
    /// The resolved system (nodes, scenarios), recorded with the run: its environment.
    system: ?std.json.Value = null,
    /// The moment is the first event matching this (`--until '<condition>'`, query.zig).
    until: ?*const query.Condition = null,
    /// Every branch's events: setup.jsonl (boot and setup, shared), fork.jsonl (from the
    /// snapshot to a fork point), branch-<index>.jsonl (each branch after them).
    events_directory: ?[]const u8 = null,
    trace_path: ?[]const u8 = null,
    branches: u32 = 16,
    branches_given: bool = false,
    /// `<node>=<patch>`: that node built from a patched copy of its build context (a mutant).
    mutant: ?[]const u8 = null,
    /// A pinned system (`--system <pin.json>`, prepare.zig): booted as is, nothing built.
    pinned: ?[]const u8 = null,
    /// Fault kinds every node also allows, and nodes that allow none (prepare.zig).
    faults_added: ?[]const u8 = null,
    faults_none: ?[]const u8 = null,
    coverage: ?[]const u8 = null,
    /// flat: every branch from the setup snapshot; tree (the default when nothing else plans
    /// the branches): from moments of earlier branches too.
    branching: enum { flat, tree } = .tree,
    branching_given: bool = false,
    /// Explore until this much wall time has passed (from the start, boot included), at most
    /// `branches` timelines: as many as fit, as an Antithesis run's duration.
    time_budget_ns: ?u64 = null,
    time_budget_text: ?[]const u8 = null,
    /// How long (virtual time) each timeline's drivers run: commands keep starting until then
    /// (Antithesis's long timelines). Without it, a drawn number of starts (4 to 64).
    timeline_ms: ?u64 = null,
    /// The most an eventually ending's drawn minimum drive can be (det-composer's), if given.
    min_drive_ms: ?u64 = null,
    drivers_cpu_weight: ?u64 = null,
    drivers_cpu_weight_text: ?[]const u8 = null,
    /// Fault kinds made common in half the timelines (`--fault-weights partition=64,pause=32`),
    /// for det-faults' swarm (`det.fault_weights=` on the guest's command line).
    fault_weights: ?[]const u8 = null,
    /// Antithesis's `fault_exclusions` (`--fault-exclusions '^(client|monitor)$'`): a regular
    /// expression over node names, and pod names on Kubernetes; a match gets no faults
    /// (det-faults' `excluded`, `det.fault_exclusions=` on the guest's command line in hex).
    fault_exclusions: ?[]const u8 = null,
    /// Commands the composer's swarm keeps in every timeline (`--keep compact,member`:
    /// `det.keep=` on the guest's command line): a trial of a new driver runs it, where the swarm
    /// left etcd's compaction driver out of both timelines of trial run 1521.
    keep: ?[]const u8 = null,
    /// A scenario's driver phase drawn up to this long (virtual time) when it sets no length of
    /// its own (Scenario.drive_ms_max) and --timeline is not given: det-composer's drawn length
    /// (composer.drive_ms), so no timeline runs as long as its slowest commands take (Galera's
    /// run 410: a median of 6 minutes, up to 33, its new behaviors about none past the 7th).
    /// `--drive-max none`: a drawn number of starts, as before.
    drive_max_ms: ?u64 = drive_max_ms_default,
    drive_max_text: ?[]const u8 = null,
    /// `--clock-start-max`: each timeline's wall clock moved forward up to this (virtual time,
    /// log-uniform from a second) as its commands begin, so a system seeding from the time draws
    /// apart in each (det-composer's clock_start). Null: the composer's 30 minutes; 0: none.
    clock_start_max_ms: ?u64 = null,
    /// `--clock-start-max` as given, for the run's request (serve's analyses boot its timelines
    /// with it: their guest's command line has it).
    clock_start_max_text: ?[]const u8 = null,
    /// `--timeline-limit` as given, for the run's request (in the guest's command line).
    timeline_limit_text: ?[]const u8 = null,
    /// The longest a scenario's driver phase is drawn in this exploration (its own drive_ms_max,
    /// else --drive-max), null with --timeline or none: the length the explorer steers (Novelty).
    drive_steered_max_ms: ?u64 = null,
    /// `--epoch`: the guest's wall clock at boot, over the profile's.
    epoch_seconds: ?u64 = null,
    /// The machine a strategy decided, adopted by a replay from its tape or a resume from its
    /// record (its wall clock, timer slack and CPU modulation's stretches set from it).
    machine_adopted: ?tape.Machine = null,
    /// `--trace-errno`: system calls failing with this errno, as syscall_error events.
    trace_errno: ?u16 = null,
    min_drive_text: ?[]const u8 = null,
    /// Timelines per tree generation (`--generation`, a multiple of 16): by default the workers,
    /// rounded up (a generation is judged once its slowest timeline ends: with 16 on a 36-thread
    /// host, about 10 timelines ran at once), with more moments returned to.
    generation_size: u32 = tree.generation_base,
    generation_given: bool = false,
    /// Branches from each moment a tree returns to (`--return-branches`): fewer branches, more
    /// moments per generation.
    return_branches: u32 = tree.children,
    /// A tree's branches returned to a moment run this long past it, then stop (`--horizon`):
    /// short branches, many of them, around the moments that mattered (Antithesis returns to
    /// decision points often; a branch is extended only when it found something). Null: to the
    /// timeline's end.
    horizon_ns: ?u64 = null,
    horizon_text: ?[]const u8 = null,
    /// Offsets a tree's return just after a behavior lands before it, one drawn per return
    /// (`--return-offsets 0,0,0,1s,5s,30s`, the default; `0`: always just after).
    return_offsets_ns: []const u64 = &return_offsets_default,
    return_offsets_text: ?[]const u8 = null,
    /// Generations planned ahead (`--pipeline`): that many start from the setup snapshot, and the
    /// queue keeps that many while one fills (explore_tree); enough keeps every worker busy.
    pipeline: u32 = pipeline_depth_default,
    pipeline_given: bool = false,
    /// Go-Explore's archive (on unless `--no-archive`): the tree keeps every behavior any timeline
    /// reached, where (just after it), and how often it returned there; each generation returns
    /// to the newest frontier with up to half its nodes and to the least visited cells of any
    /// generation with the rest (a timeline of an earlier one is rebuilt by replaying its path).
    /// Off, only to what the last generation found new: a promising state found earlier is
    /// forgotten once newer ones come, and a bug needing a second rare event after it is lost.
    archive: bool = true,
    archive_given: bool = false,
    /// Returns go first to just after a `sometimes` or `reachable` made true (`--no-prefer-
    /// sometimes`: every new behavior alike): Antithesis restarts tests from where one is hit.
    prefer_sometimes: bool = true,
    prefer_sometimes_given: bool = false,
    prefer_severe: bool = true,
    prefer_severe_given: bool = false,
    /// Learned ranges (events.zig ranges_note): each number a system's events carry, its
    /// highest and lowest as scored buckets (`--no-ranges`: none, for comparisons).
    ranges: bool = true,
    ranges_given: bool = false,
    /// The nodes' memory-growth objective (Events.memory_growth_objective: a leak too slow for
    /// the OOM killer climbed by the tree), `--no-memory-objective`: not counted, for comparisons.
    memory_objective: bool = true,
    memory_objective_given: bool = false,
    /// A tree's return to an objective's best goes on a driver phase past its parent's end
    /// (composer.zig's drive_again asks, advisor.zig answers), `--no-objective-extend`: it ends
    /// when its parent would, for comparisons.
    objective_extend: bool = true,
    objective_extend_given: bool = false,
    /// The tree's bandit over configuration draws (`--no-config-bandit`: independent draws).
    config_bandit: bool = true,
    /// Setup mode (`--setup-only`, Antithesis's): the system built and booted, its setup run to
    /// setup_complete, its logs and events kept, and no timeline: a system's setup tried out
    /// before a full run.
    setup_only: bool = false,
    /// The run's HTTP API (serve gives it), told to a strategy in its hello.
    run_url: ?[]const u8 = null,
    /// The system's history (serve gives it): the behaviors its last runs reached, one JSON
    /// line each ({"hash","timelines"}); one they never reached is preferred, as a sought one.
    history_path: ?[]const u8 = null,
    /// Each timeline some of the fault kinds (det-faults' swarm testing; `--no-swarm`: every kind
    /// in every timeline, for comparisons: `det.swarm=0` on the guest's command line).
    swarm: bool = true,
    timeline_text: ?[]const u8 = null,
    /// A targeted run: a diff file or git range whose changed lines the tree explores first.
    changed: ?[]const u8 = null,
    /// Where --changed's range is: a repository's directory or URL (else the working directory).
    changed_repository: ?[]const u8 = null,
    /// A timeline's ceiling of virtual time: one that has not finished by then ends as hung.
    timeline_limit_ns: ?u64 = std.time.ns_per_hour,
    /// The learned timeline limit's multiple of the normal ends' 99th percentile (timeline_limit.zig); 0:
    /// the explicit limit alone.
    timeline_limit_learned: u32 = (timeline_limit.Learner{}).multiple,
    /// Retroactive logging: output lines with these texts are left out of an exploration's
    /// events (a replay of one timeline writes them).
    retroactive: [retroactive_max][]const u8 = undefined,
    retroactive_count: u32 = 0,
    /// Run only this branch (to replay one timeline of an exploration).
    branch_only: ?u32 = null,
    strategy_command: ?[]const u8 = null,
    /// Its plugins' files followed (strategies.zig): new bytes reach the next timelines.
    strategy_follow: bool = false,
    tape_directory: ?[]const u8 = null,
    /// Replay the branch recorded in this tape.
    tape_path: ?[]const u8 = null,
    /// A replay's named draws written here as it stops (draws.zig, each label's last values: with
    /// --until, the pulls of a failure's last faults, which an explanation varies one at a time).
    draws_out: ?[]const u8 = null,
    /// Explore from a moment of a branch: replay branch `from_branch` to `from_vtime_ms`,
    /// snapshot there, and branch from that snapshot.
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    /// A command to run at the fork point before exploring its futures.
    from_exec: ?[]const u8 = null,
    /// Bytes written into guest RAM at the fork point (`--from-poke`, tape.Fork.pokes).
    from_poke: ?[]const u8 = null,
    /// Save the replayed branch (`--tape`, `--branch`) to disk at these moments
    /// (`--save-snapshots <dir> --save-at-ms <a,b,...>`, saver.zig).
    save_directory: ?[]const u8 = null,
    save_at_ms: []const u64 = &.{},
    /// Branch from a snapshot saved to disk (`<dir>/<name>`) instead of booting.
    from_snapshot: ?[]const u8 = null,
    /// With --tape: the taped timeline goes on from a snapshot saved of it (a saver's
    /// `b<branch>-<ms>`, `<dir>/<name>`), as its replay would have from there, instead of booting
    /// and replaying to it (serve's moment replays, minutes each from the start).
    tape_snapshot: ?[]const u8 = null,
    /// After --exec at the moment, run on to the end of the timeline.
    moment_continue: bool = false,
    /// Not a flag: on from a snapshot taken after the timeline's steps began (VM.Options's).
    moment_held: bool = false,
    /// From the moment on, randomness from this seed instead of the timeline's (and the guest
    /// kernel's generator reseeded): the branch's own future, as Antithesis's branches diverge
    /// from their timeline at once.
    fresh_seed: ?u64 = null,
    /// Branches at varying speeds (VM.Modulation): on by default for explorations, as
    /// Antithesis turns it on with faults (the Raft POC's double vote needed it); a run keeps
    /// whether it had it (request.json), and its replays and tapes follow.
    cpu_modulation: bool = false,
    cpu_modulation_given: ?bool = null,
    /// --cpu-modulation-stretch-us <min>-<max>: how long a speed lasts (VM.Options).
    cpu_modulation_stretch_ns: [2]u64 = VM.modulation_stretch_default,
    /// Remake every tree node an in-run snapshot made (holders.zig) by a replay, and print how
    /// the two differ in what the guest can see ("verify ... DIFFERENT"): a check of holders.
    verify_holders: bool = false,
    /// In-run snapshots (holders.zig), on by default; `--no-holders`: every node made by a
    /// replay, as a replay of a branch makes it (comparisons, determinism checks).
    holders: bool = true,
    /// Every holder on disk (holders.Disk), as while memory runs low: what checks use.
    holders_on_disk: bool = false,
    /// Each written by the timeline's own process (holders.Owner.disk_sync_always): what memory
    /// below the reserve does.
    holders_on_disk_sync: bool = false,
    /// --holders-retain: holders in memory kept past their generation's judgment (holders.zig
    /// Registry.retain), an arm to measure; off by default.
    holders_retain: bool = false,
    /// --no-holders-writeback: a saved holder's writeback left to the kernel's dirty thresholds
    /// (holders.writeback), an arm to measure; on by default.
    holders_writeback: bool = true,
    /// Every holder in memory leaves at once, written to disk first (holders.Owner.leave_always).
    holders_leave: bool = false,
    /// The kept holders' budget on disk, in GB (`--holders-budget`); null: half the disk's free
    /// space above its reserve at the first judgment (holders.Registry.kept_trim). A small one
    /// makes a short run trim as a long one does: what trials of the trims use.
    holders_budget_gb: ?u64 = null,
    /// A passing host check's input kept in one timeline of this many (checks.Options
    /// .passing_one_in; `--keep-passing-checks`, 0 for none): a checker fixed later judges them
    /// again.
    keep_passing_checks: u32 = 16,
    /// The host's runs (runs.zig): an exploration is one of them, in its own directory there.
    data_directory: ?[]const u8 = null,
    /// The run's directory, claimed already (serve's runs); else the exploration claims one.
    run_directory: ?[]const u8 = null,
    /// This host runs the branches whose index modulo `shard_count` is `shard_index`
    /// (`--shard k/n`); `determinismo merge` combines the shards' records.
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    /// Write results as JSON lines here (see report.record).
    record_path: ?[]const u8 = null,
    /// The command line as given (the replays' verifier boots the system the same way).
    raw_argv: []const [:0]const u8 = &.{},
    /// While exploring with a record and tapes, every this many timelines one is replayed from
    /// its tape (replays.zig); 0: none.
    verify_percent: u32 = verify_percent_default,
    /// The run this process belongs to (`--run-key`, a verify replay's: its explorer's pid),
    /// taken when that process is one of its ancestors.
    run_key: ?linux.pid_t = null,
    /// Continue the run whose record is `record_path`: its timelines already recorded are
    /// skipped (flat branching; the same inputs and seed).
    resume_run: bool = false,
    /// Parallel workers for branches (default: one per available CPU).
    jobs: ?u32 = null,
    /// Multiverse debugging: stop the (single) branch at this virtual time, run this there.
    moment_vtime_ms: ?u64 = null,
    /// A replay's (replays.zig, `--stop-at-ns`): where the timeline it replays was to stop, its
    /// horizon, to the nanosecond as it was drawn. Its own moment, as the horizon was.
    stop_ns: ?u64 = null,
    /// With --until: the moment this long (virtual time) before the condition first holds.
    rewind_ms: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// Commands for the moment, one per line, run one after the other (instead of --exec).
    moment_script_path: ?[]const u8 = null,
    /// `--start-script`: a run's own steps at its start (with --exec-at-start: a CI shard's
    /// `det:background <command>` then `det:until` its end). A moment given too (--at-vtime-ms,
    /// --until) comes inside them: their steps up to their final waits, then the moment's
    /// (start_compose). The guest sees what the run's timeline saw up to the moment.
    start_script_path: ?[]const u8 = null,
    /// --until's text, as given (start_compose's det:until step).
    until_text: ?[]const u8 = null,
    /// After them, steps from standard input as they come (--exec-interactive).
    moment_interactive: bool = false,
    /// And the guest running on between them (--exec-live).
    moment_live: bool = false,
    /// `--extend` (with --tape, --at-vtime-ms): the replayed timeline, from the moment on,
    /// recorded as another timeline of its run, under the run's next number (tape.claim_next):
    /// its tape beside the others, its events from the moment, its line in the record. A session
    /// is a timeline: the one it was opened on up to the moment, its own after.
    extend: bool = false,
    /// The futures of a fork (--fork-futures, with --from-snapshot of its snapshot): branch i is
    /// future i + 1, its machine answering that to the fork's index.
    fork_futures: bool = false,
    /// Where a session's forks are saved (--fork-snapshots): the guest's sdk.fork clones the
    /// machine there, for serve to start its futures from.
    fork_directory: ?[]const u8 = null,
    /// Where a session's checkpoints are saved (--checkpoint-snapshots, the run's replay
    /// snapshots): det:checkpoint saves the machine there as one of its timeline's moments.
    checkpoint_directory: ?[]const u8 = null,
    /// serve, for a session's machine (--serve-url): the guest's sdk.serve calls it there.
    serve_url: ?[]const u8 = null,
    /// explore --egress (sdk.egress): where a deterministic machine may connect.
    egress_allow: []const []const u8 = &.{},
    /// explore --decide "name=value,...": named decisions fixed in every timeline (advisor.zig).
    decide: []const advisor_zig.Fixed = &.{},
    /// explore --ingress (sdk.ingress, det-ingress in a node): where the live timeline listens for
    /// connections from outside, "ip:port"; each one's bytes taped, a replay delivering them again.
    ingress_listen: ?[]const u8 = null,
    /// Read-only disk images, in guest order (/dev/vda first).
    disk_paths: [VM.disks_max][]const u8 = undefined,
    disk_count: u32 = 0,
    /// A test program: its system becomes the disks, its scenario the guest's work.
    program_path: ?[]const u8 = null,
    /// Or a Compose file: services become nodes, Antithesis test templates scenarios.
    compose_path: ?[]const u8 = null,
    /// Or a directory of Kubernetes manifests: a K3s node runs them (kubernetes.zig).
    kubernetes_path: ?[]const u8 = null,
    /// With kubernetes_path: images loaded into the cluster beside those its manifests name in
    /// `image:` fields (`--images a,b`, Antithesis's launch `images`): an operator's, named in a
    /// custom resource (CloudNativePG's Cluster `imageName:`, ParadeDB's PostgreSQL).
    kubernetes_images: ?[]const u8 = null,
    /// Commands and faults follow this script (determinismo script) instead of choosing.
    script_path: ?[]const u8 = null,
    /// Fault injectors of the run's own (`--injector <executable>`, again for each): each
    /// timeline's injector a named decision among det-faults and them (prepare.zig, composer.zig).
    injectors: []const []const u8 = &.{},
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    /// The scenarios explored after this one in a run of several (its request's, CE63).
    scenarios_next: ?[]const []const u8 = null,
    /// Explored with other scenarios: a complete run resumed goes on to the next (resume_read).
    scenario_chain: bool = false,
    cache_directory: []const u8 = ".determinismo-cache",
};

/// The share of its timelines a run replays as it goes (--verify-replays, percent).
const verify_percent_default = 20;

/// `--from-poke`'s text, "<address>=<hex bytes>[,<address>=<hex bytes>...]": checked, and with a
/// VM, written into its guest RAM (at the fork point, the vCPU stopped). Returns how many.
fn pokes_parse(text: []const u8, vm: ?*VM) !usize {
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, text, ',');
    while (entries.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return error.PokeSyntax;
        const address = try std.fmt.parseInt(u64, entry[0..equals], 0);
        const hex = entry[equals + 1 ..];
        if (hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > 4096) return error.PokeSyntax;
        var bytes: [4096]u8 = undefined;
        const value = try std.fmt.hexToBytes(&bytes, hex);
        if (vm) |machine| {
            const guest = guest_memory.GuestMemory{ .bytes = machine.memory };
            const target = guest.range(address, value.len) orelse return error.PokeOutsideRam;
            @memcpy(target, value);
            say("[determinismo] poke: 0x{x} = {s} ({d} bytes)\n", .{ address, hex, value.len });
        }
        count += 1;
    }
    return count;
}

test pokes_parse {
    try std.testing.expectEqual(@as(usize, 2), try pokes_parse("0x1000=00ff,4096=01", null));
    try std.testing.expectError(error.PokeSyntax, pokes_parse("0x1000=0", null));
    try std.testing.expectError(error.PokeSyntax, pokes_parse("0x1000", null));
}

/// `--watch`'s value: a guest physical address (0x hex or decimal) and, after a colon, how many
/// bytes from it (8 by default).
fn watch_parse(text: []const u8) !VM.Watch {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const address = try std.fmt.parseInt(u64, text[0 .. colon orelse text.len], 0);
    const size = if (colon) |at| try std.fmt.parseInt(u64, text[at + 1 ..], 0) else 8;
    if (size == 0 or size > 1 << 20) return error.WatchSize;
    return .{ .address = address, .size = size };
}

test watch_parse {
    try std.testing.expectEqual(VM.Watch{ .address = 0x1f2000, .size = 8 }, try watch_parse("0x1f2000"));
    try std.testing.expectEqual(VM.Watch{ .address = 4096, .size = 16 }, try watch_parse("4096:16"));
    try std.testing.expectError(error.WatchSize, watch_parse("0x1000:0"));
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return command_serve(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "mcp")) return command_mcp(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "doctor")) return @import("doctor.zig").main(init, argv[2..]);
    // From the start: a drain asked during the setup (SIGUSR2's default action ends the process)
    // drains it as soon as it explores.
    drain_install();
    if (argv.len >= 2) {
        if (try command_tool(arena, init.io, init.minimal.environ.block.slice, argv)) |status| std.process.exit(status);
    }
    if (argv.len == 3 and std.mem.eql(u8, argv[1], "script")) {
        return script.extract(arena, init.io, argv[2]);
    }
    if (argv.len == 6 and std.mem.eql(u8, argv[1], "snapshot-diff")) {
        return snapshot_diff(init, argv[2..6]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "merge")) {
        const failing = try merge.merge(arena, init.io, argv[2..]);
        if (failing > 0) std.process.exit(3);
        return;
    }
    var arguments = parse_arguments(arena, try run_expand(arena, init.io, argv)) catch {
        say("{s}", .{usage});
        std.process.exit(2);
    };
    if (arguments.command == .validate) std.process.exit(try command_validate(arena, init.io, &arguments));
    // This process and everything it forks are one run sharing the host's CPUs (cpus.zig), and
    // its memory: each of its VMs claims its guest's size with the CPU it runs on.
    // A verify replay is its explorer's run (`--run-key`, named by the verifier): one of its
    // ancestors, or the key is not taken.
    cpus.run_key = if (arguments.run_key) |key| (if (cpus.run_key_take(key)) key else linux.getpid()) else linux.getpid();
    cpus.claim_bytes = @as(u64, arguments.memory_mib) << 20;
    const vm = try arena.create(VM); // Large (port statistics): never on the stack.
    const profile = arguments.profile orelse "";
    const all = std.mem.eql(u8, profile, "all");
    const several = std.mem.indexOfScalar(u8, profile, ',') != null;
    if (!all and !several) {
        if (try system_run(init, vm, arguments) > 0) std.process.exit(3);
        return;
    }
    // Several profiles (e.g. a system and its mutants): their own disks, snapshot and verdict.
    const names = if (all) try prepare.profile_names(arena, init.io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .kubernetes = arguments.kubernetes_path,
        .cache_directory = arguments.cache_directory,
    }) else try list_split(arena, profile);
    const verdicts = try arena.alloc(u32, names.len);
    for (names, verdicts) |name, *failing| {
        say("[determinismo] profile {s}\n", .{name});
        var copy = arguments;
        copy.profile = name;
        failing.* = try system_run(init, vm, copy);
    }
    say("[determinismo] profiles:\n", .{});
    for (names, verdicts) |name, failing| {
        const status = if (failing > 0) "FAIL" else "PASS";
        const line = "  {s} {s} ({d} scenarios with failing properties)\n";
        say(line, .{ status, name, failing });
    }
    for (verdicts) |failing| if (failing > 0) std.process.exit(3);
}

/// `determinismo cpus`: how many CPUs this process's VMs can take (its pool: the CPUs it was
/// given, one thread per core), as JSON. serve asks it where machines run (the reserved cores'
/// scope when it has them), whose CPUs are not serve's own.
fn cpus_print(io: std.Io) !u8 {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("{{\"cpus\":{d}}}\n", .{cpus.usable_count()});
    try stdout.interface.flush();
    return 0;
}

/// `determinismo cpuid`: this host's deterministic guest CPUID table (cpuid.table_write's
/// text), for another CPU model to replay this host's runs with `--cpuid <file>`.
fn cpuid_print(io: std.Io, rest: []const [:0]const u8) !u8 {
    const guest_cpu: VM.GuestCpu = if (rest.len == 2 and std.mem.eql(u8, rest[0], "--guest-cpu"))
        std.meta.stringToEnum(VM.GuestCpu, rest[1]) orelse return error.UnknownGuestCpu
    else
        .host;
    var entries: [VM.cpuid_entries_max]kvm.CpuidEntry2 = undefined;
    var msrs: [@import("core").cpuid.pinned_msrs.len]kvm.MsrEntry = undefined;
    const count = try VM.cpuid_table_host(&entries, &msrs, guest_cpu);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try @import("core").cpuid.table_write(entries[0..count.entries], &stdout.interface);
    try @import("core").cpuid.msrs_write(msrs[0..count.msrs], &stdout.interface);
    try stdout.interface.flush();
    return 0;
}

/// The commands that read what explorations wrote (tla, query, causality): their exit status,
/// or null for other commands. An error exits with 2 (`runs search` keeps 1 for no match).
fn command_tool(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: [:null]const ?[*:0]const u8,
    argv: []const [:0]const u8,
) !?u8 {
    const eql = std.mem.eql;
    const name = argv[1];
    const rest = argv[2..];
    const result = if (eql(u8, name, "causality"))
        causality.run(arena, io, argv[0], environ, rest)
    else if (eql(u8, name, "explain"))
        explain.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "shrink"))
        shrink.run(arena, io, argv[0], environ, rest)
    else if (eql(u8, name, "mutate"))
        mutate.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "verify"))
        verify.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "extract"))
        extract.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "inject"))
        extract.inject_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "profile"))
        profiler.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "stacks"))
        profiler.stacks_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "query"))
        query.run(arena, io, rest)
    else if (eql(u8, name, "label"))
        label_command.run(arena, io, environ, rest)
    else if (eql(u8, name, "events"))
        event_sets.run(arena, io, rest)
    else if (eql(u8, name, "tla"))
        tla.check(arena, io, rest)
    else if (eql(u8, name, "quint"))
        quint.check(arena, io, rest)
    else if (eql(u8, name, "veil"))
        veil.check(arena, io, rest)
    else if (eql(u8, name, "runs"))
        runs_cli.run(arena, io, rest)
    else if (eql(u8, name, "bundle"))
        bundle.run(arena, io, rest)
    else if (eql(u8, name, "cpuid"))
        cpuid_print(io, rest)
    else if (eql(u8, name, "cpus"))
        cpus_print(io)
    else
        return null;
    // The usage for a usage error only: after another (a run's events held by serve, a missing
    // file) it buried what was said in a hundred lines.
    return result catch |err| {
        if (err == error.Usage) {
            say("{s}", .{usage});
            return 2;
        }
        say("error: {s}\n", .{@errorName(err)});
        return 2;
    };
}

fn list_split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |name| try names.append(arena, name);
    return names.items;
}

/// Prepares the system (if any), then runs or explores its scenarios. Returns the number of
/// scenarios with failing properties.
/// The CPU this process runs its own VMs on (the boot and setup, branches run in-process): a
/// CPU of the host's pool (cpus.zig), never shared with another VM's core. Given back, and the
/// process unpinned, before forking processes that take CPUs of their own.
const OwnCpu = struct {
    pool: cpus.Pool = undefined,
    opened: bool = false,
    held: ?cpus.Held = null,

    fn take(own: *OwnCpu) void {
        if (own.held != null) return;
        if (!own.opened) {
            own.pool.open() catch |err| {
                say("[determinismo] the CPU pool: {s}\n", .{@errorName(err)});
                linux.exit_group(1);
            };
            own.opened = true;
        }
        own.held = own.pool.take();
    }

    /// A fast machine's place: on a CPU with other machines, never a deterministic VM's
    /// (cpus.Pool.take_shared).
    fn take_shared(own: *OwnCpu) void {
        if (own.held != null) return;
        if (!own.opened) {
            own.pool.open() catch |err| {
                say("[determinismo] the CPU pool: {s}\n", .{@errorName(err)});
                linux.exit_group(1);
            };
            own.opened = true;
        }
        own.held = own.pool.take_shared();
    }

    fn give(own: *OwnCpu) void {
        const held = own.held orelse return;
        own.pool.give(held);
        own.held = null;
        cpus.unpin();
    }
};
var own_cpu: OwnCpu = .{};
/// The setup's waits before its VM could start (cpus.Held: other runs' VMs claiming the host's
/// memory, or every CPU busy), said with its time: run 2044's "boot + setup took 1556s" was mostly
/// a wait beside a 40-VM run, read as a slow setup.
var setup_waited: cpus.Held = .{ .slot = 0 };

fn system_run(init: std.process.Init, vm: *VM, arguments_given: Arguments) !u32 {
    const arena = init.arena.allocator();
    var arguments = arguments_given;
    if (exploration_is_run(&arguments)) try run_register(arena, init.io, &arguments);
    // A replay or a future (one VM, not a run's explorer): the OOM killer's before the host's
    // own processes, as a run's timelines are (one killed by it once took podman's pause
    // process down with it: user@.service's OOM policy).
    if (arguments.command == .explore and !exploration_is_run(&arguments)) oom_before_the_host();
    if (arguments.resume_run) try resume_settings_adopt(arena, init.io, &arguments);
    const has_system = arguments.program_path != null or arguments.compose_path != null or
        arguments.kubernetes_path != null or
        arguments.pinned != null;
    const prepared = if (has_system) try system_prepare(arena, init.io, &arguments) else null;
    const cwd = std.Io.Dir.cwd();
    if (arguments.moment_script_path) |path| {
        const lines = try cwd.readFileAlloc(init.io, path, arena, .unlimited);
        arguments.moment_command = try commands_join(arena, lines);
    }
    if (arguments.start_script_path) |path| {
        const start = try commands_join(arena, try cwd.readFileAlloc(init.io, path, arena, .unlimited));
        try start_compose(arena, &arguments, start);
    }
    // A replay from a tape boots the clock its timeline had (the tape's jitter seed, part of its
    // inputs), unless one is given: drawn only for a new run, it was 0 here, and every replay of
    // a run's tape was refused as other inputs (the e2e python check, 2026-11-07).
    // A tape's 0: one from before the jitter, the exact clock.
    if (arguments.tape_path) |path| {
        const source = try cwd.readFileAlloc(init.io, path, arena, .unlimited);
        if (arguments.tsc_jitter_seed == null) arguments.tsc_jitter_seed = try tape.jitter_seed(source, try arena.alloc(u8, 64 * 1024));
        // And the machine its run's strategy decided, if one did.
        if (try tape.machine_of(source, try arena.alloc(u8, 64 * 1024))) |machine| machine_adopt(&arguments, machine);
    }
    // Otherwise from the seed, as a run's: a replay by seed and branch alone (no run, no tape)
    // reads the clock its run read (it ran exact, and parted from the run's own timelines: the
    // setup's e2e bank check on the jittering KVM, 2026-11-07).
    if (arguments.tsc_jitter_seed == null) arguments.tsc_jitter_seed = jitter_from_seed(arguments.seed);
    const kernel = try cwd.readFileAlloc(init.io, arguments.kernel_path, arena, .unlimited);
    const cpuid_text: ?[]const u8 = if (arguments.cpuid_path) |path| try cwd.readFileAlloc(init.io, path, arena, .limited(1 << 20)) else null;
    const cpuid_table: ?[]const kvm.CpuidEntry2 = if (cpuid_text) |text| table: {
        const entries = try arena.alloc(kvm.CpuidEntry2, VM.cpuid_entries_max);
        break :table entries[0..try @import("core").cpuid.table_parse(text, entries)];
    } else null;
    const cpuid_msrs: []const kvm.MsrEntry = if (cpuid_text) |text| msrs: {
        const msrs = try arena.alloc(kvm.MsrEntry, @import("core").cpuid.pinned_msrs.len);
        break :msrs msrs[0..try @import("core").cpuid.msrs_parse(text, msrs)];
    } else &.{};
    const initrd = if (arguments.initrd_path) |path|
        try cwd.readFileAlloc(init.io, path, arena, .unlimited)
    else
        null;
    var options = VM.Options{
        .memory_size = @as(u64, arguments.memory_mib) << 20,
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = arguments.cmdline,
        .deterministic = arguments.deterministic,
        .seed = arguments.seed,
        .margin_branches = arguments.margin_branches,
        .watch = arguments.watch,
        .timer_slack_ns = arguments.timer_slack_us * std.time.ns_per_us,
        .timer_delay_permille = arguments.timer_delay_permille,
        .branch_event = arguments.branch_event,
        .cpuid_table = cpuid_table,
        .cpuid_msrs = cpuid_msrs,
        .guest_cpu = arguments.guest_cpu,
        .vcpus = arguments.vcpus,
        .dev_directory = arguments.dev_directory,
        .hold_scenario = arguments.hold_scenario,
        .tsc_jitter_seed = arguments.tsc_jitter_seed orelse 0,
        .tsc_jitter_exact = arguments.tsc_jitter_exact,
        .events_fd = if (arguments.events_path) |path| try open_for_writing(arena, path) else null,
        .faults_record_fd = if (arguments.faults_record_path) |path| try open_for_writing(arena, path) else null,
        .events_parse_buffer = try arena.alloc(u8, Events.parse_buffer_size),
        .trace_fd = if (arguments.trace_path) |path| try open_for_writing(arena, path) else null,
        .rdtsc_log_fd = if (arguments.trace_path) |path|
            try open_for_writing(arena, try std.fmt.allocPrint(arena, "{s}.rdtsc", .{path}))
        else
            null,
        // Debugging (with --trace): DETERMINISMO_ITRACE_AT=<RDTSC exit> traces every
        // instruction from there to the next RDTSC exit into <trace>.itrace.
        .itrace_fd = if (arguments.trace_path != null and std.c.getenv("DETERMINISMO_ITRACE_AT") != null)
            try open_for_writing(arena, try std.fmt.allocPrint(arena, "{s}.itrace", .{arguments.trace_path.?}))
        else
            null,
        .itrace_at = if (std.c.getenv("DETERMINISMO_ITRACE_AT")) |text|
            std.fmt.parseInt(u64, std.mem.span(text), 10) catch 0
        else
            0,
        // With --trace: RDTSC exits logged, the first 4M by default (DETERMINISMO_RDTSC_LOG_CAP:
        // more, for a divergence later in a long timeline; 16 bytes each, in the host kernel).
        .rdtsc_log_cap = if (std.c.getenv("DETERMINISMO_RDTSC_LOG_CAP")) |text|
            std.fmt.parseInt(u32, std.mem.span(text), 10) catch VM.rdtsc_log_cap_default
        else
            VM.rdtsc_log_cap_default,
        .moment_vtime_ns = if (arguments.moment_vtime_ms) |ms| ms * std.time.ns_per_ms else null,
        .moment_command = arguments.moment_command,
        .until = arguments.until,
        .disks = try open_disks(arena, arguments.disk_paths[0..arguments.disk_count]),
        .builtin_properties = has_system,
        .check_buffer = if (prepared != null and prepared.?.system.checks.len > 0)
            try std.heap.page_allocator.alloc(u8, checks.input_size_max) // Touched as used.
        else
            &.{},
        .cpu_modulation = arguments.cpu_modulation,
        .modulation_stretch_ns = arguments.cpu_modulation_stretch_ns,
        .retroactive = try retroactive_texts(arena, &arguments, if (prepared) |system| system.system.retroactive else &.{}),
        .epoch_seconds = arguments.epoch_seconds orelse
            (if (prepared) |system| system.system.epoch_seconds else null) orelse VM.epoch_seconds_default,
        .vtime_limit_ns = arguments.timeline_limit_ns,
    };
    const context = Context{
        .arena = arena,
        .io = init.io,
        .environ = init.minimal.environ.block.slice,
    };
    const base_cmdline = arguments.cmdline;
    var failing_scenarios: u32 = 0;
    var catalog = report.Catalog{ .arena = arena };
    // The `sometimes` each scenario without other failures reached and never made true: it
    // fails only when no scenario explored made them true, judged once all ran.
    var unmet: std.ArrayList([]const []const u8) = .empty;
    const scenarios = try scenarios_selected(arena, init.io, &arguments, prepared);
    arguments.scenario_chain = scenarios.len > 1;
    for (scenarios, 0..) |scenario, index| {
        // Several scenarios explored: each its own run (its record, events and tapes, branch
        // numbers of its own); in one run, each scenario's timelines took the same files, and the
        // last scenario's were all that stayed (Quint, srv3 run 25).
        if (scenarios.len > 1 and exploration_is_run(&arguments)) {
            const next = try arena.alloc([]const u8, scenarios.len - index - 1);
            for (next, scenarios[index + 1 ..]) |*name, after| name.* = after.?;
            arguments.scenarios_next = next;
            try run_scenario(arena, init.io, &arguments, scenario.?, index == 0);
        }
        options.cmdline = try cmdline_build(arena, base_cmdline, &arguments, scenario);
        // The fast VM boots as a deterministic machine does (every CPU on the PIT, its tick
        // broadcast to the others): a fork continues the same kernel (docs/DEVELOPING.md).
        if (arguments.vcpus > 1) options.cmdline = try std.fmt.allocPrint(arena, "{s} {s}", .{ options.cmdline, VM.cmdline_deterministic });
        // Dev mode: the composer waits after the setup for a timeline explored from here.
        if (arguments.dev_directory != null) options.cmdline = try std.fmt.allocPrint(arena, "{s} det.dev=1", .{options.cmdline});
        // The test program's host checks, by the program itself in the scenario's name.
        if (arguments.program_path) |program| {
            const host_checks = try arena.create(checks.Hook);
            host_checks.* = .{
                .checks = if (prepared) |system| system.system.checks else &.{},
                .program = program,
                .scenario = scenario orelse "",
                .lines = if (prepared) |system| system.program_lines else null,
                .passing_one_in = arguments.keep_passing_checks,
            };
            options.end_checks = host_checks.end_checks();
        }
        arguments.drive_steered_max_ms = if (arguments.timeline_ms != null) null else if (prepared) |known| steered: {
            const own = if (scenario) |name| if (known.system.scenario(name)) |found| found.drive_ms_max else null else null;
            break :steered if (own) |ms| ms else arguments.drive_max_ms;
        } else null;
        if (scenario) |name| say("[determinismo] scenario {s}\n", .{name});
        switch (arguments.command) {
            .validate => unreachable, // main's: it boots nothing.
            .run => try command_run(context, vm, &options, arguments.from_snapshot),
            .explore => {
                const multiverse = try command_explore(context, vm, &options, &arguments);
                try multiverse.catalog_reached(&catalog);
                if (multiverse.failing_violations() > 0) {
                    failing_scenarios += 1;
                } else try unmet.append(arena, try multiverse.sometimes_unmet(arena));
            },
        }
    }
    for (unmet.items) |messages| {
        for (messages) |message| if (!catalog.made_true(.sometimes, message)) {
            failing_scenarios += 1;
            break;
        };
    }
    // Catalogs span scenarios (a test program's, a service serving several): an assertion
    // must be reached in some scenario, judged once all ran.
    const all_scenarios = if (prepared) |known| known.system.scenarios.len else scenarios.len;
    const every_scenario = scenarios.len == all_scenarios;
    // Setup mode judges no catalog: no assertion ran past the setup (setup_complete reached is
    // its verdict, explore_snapshot's exit status otherwise).
    const catalog_failing = if (arguments.setup_only) 0 else catalog.judge(every_scenario);
    if (catalog_failing > 0) failing_scenarios += 1;
    // In the record too: a complete run resumed again is judged from its record, and its
    // catalog's verdict was nowhere in it (CE45, the blind Lean replica of the platform: one
    // failing only an assertion no timeline reached read "passed").
    if (!arguments.setup_only) report.record(.{ .catalog = .{ .failing = catalog_failing } });
    // How it ends, in its run's directory: serve learned it only from runs it reaped itself, and
    // read the others' (a trial's, every run adopted across a restart) from their timelines'
    // failing always properties alone. Datomic's runs 441, 445 and 447 showed "passed" while no
    // transaction ever committed (a sometimes never true).
    if (exploration_is_run(&arguments)) if (arguments.run_directory) |directory| {
        const status: u32 = if (failing_scenarios > 0) 3 else 0;
        const text = try std.fmt.allocPrint(arena, "{d} exited with status {d}\n", .{ status, status });
        const path = try std.fs.path.join(arena, &.{ directory, "exit" });
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text }) catch {};
    };
    return failing_scenarios;
}

/// Whether the command is an exploration, which is one of the host's runs (runs.zig): not a
/// replay of one timeline (a tape, a branch), nor futures forked from a saved snapshot unless
/// serve made them a run (a session's fork: `--run-directory`).
fn exploration_is_run(arguments: *const Arguments) bool {
    return arguments.command == .explore and arguments.tape_path == null and
        arguments.branch_only == null and
        (arguments.from_snapshot == null or arguments.run_directory != null);
}

/// The exploration as one of the host's runs (runs.zig): its directory claimed, unless serve
/// gave it one (`--run-directory`), its output kept there too, its request and machine written
/// (what serve replays and continues it with); its pid held; its record, events and tapes there,
/// or, asked elsewhere, named from there.
/// `argv` with `flag`'s value replaced, for the processes the run starts (its replays).
fn argv_with(arena: std.mem.Allocator, argv: []const [:0]const u8, flag: []const u8, value: []const u8) ![]const [:0]const u8 {
    const out = try arena.dupe([:0]const u8, argv);
    const kept = try arena.dupeSentinel(u8, value, 0);
    for (out[0..out.len -| 1], 0..) |word, index| {
        if (std.mem.eql(u8, word, flag)) out[index + 1] = kept;
    }
    return out;
}

/// `argv` with `flag` set to `value`: its value replaced, or both appended when it is not there.
fn argv_set(arena: std.mem.Allocator, argv: []const [:0]const u8, flag: []const u8, value: []const u8) ![]const [:0]const u8 {
    for (argv[0..argv.len -| 1]) |word| {
        if (std.mem.eql(u8, word, flag)) return argv_with(arena, argv, flag, value);
    }
    const out = try arena.alloc([:0]const u8, argv.len + 2);
    @memcpy(out[0..argv.len], argv);
    out[argv.len] = try arena.dupeSentinel(u8, flag, 0);
    out[argv.len + 1] = try arena.dupeSentinel(u8, value, 0);
    return out;
}

test argv_set {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "determinismo", "explore", "--seed", "7" };
    const added = try argv_set(arena.allocator(), &argv, "--tsc-jitter-seed", "0x5");
    try std.testing.expectEqual(@as(usize, 6), added.len);
    try std.testing.expectEqualStrings("0x5", added[5]);
    const replaced = try argv_set(arena.allocator(), added, "--tsc-jitter-seed", "0x9");
    try std.testing.expectEqual(@as(usize, 6), replaced.len);
    try std.testing.expectEqualStrings("0x9", replaced[5]);
}

test argv_with {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "determinismo", "explore", "--kernel", "k", "--initrd", "i" };
    const out = try argv_with(arena.allocator(), &argv, "--initrd", "kept");
    try std.testing.expectEqualStrings("kept", out[5]);
    try std.testing.expectEqualStrings("k", out[3]);
}

fn run_register(arena: std.mem.Allocator, io: std.Io, arguments: *Arguments) !void {
    const directory = arguments.run_directory orelse claimed: {
        const data = try runs.data_directory(arena, arguments.data_directory);
        // A resume continues the run whose record it names, once that run's explorer is gone:
        // its directory again, not another run refused its record (e2e `resume`, 2026-10-29).
        if (arguments.resume_run) if (arguments.record_path) |path| {
            if (try runs.linked_by(arena, data, "record.jsonl", try runs.absolute(arena, path))) |id| {
                const own = try runs.directory_of(arena, data, id);
                if (runs.running_pid(arena, own) == null) {
                    try runs.output_tee(arena, try std.fs.path.join(arena, &.{ own, "output.log" }));
                    say("[determinismo] run {d} resumed: {s}\n", .{ id, own });
                    break :claimed own;
                }
            }
        };
        // Never over another run's events, record or tapes: they would be its no more.
        for ([_]struct { []const u8, ?[]const u8, []const u8 }{
            .{ "events", arguments.events_directory, "--events-dir" },
            .{ "record.jsonl", arguments.record_path, "--record" },
            .{ "tapes", arguments.tape_directory, "--tape-dir" },
        }) |asked| {
            const path = asked[1] orelse continue;
            const target = try runs.absolute(arena, path);
            if (try runs.linked_by(arena, data, asked[0], target)) |id| {
                // Deleted since, it is that run's no more: its link goes (or it would show this
                // run's), and this run takes the path. Still there, it is refused.
                const target_z = try arena.dupeSentinel(u8, target, 0);
                const kept = linux.errno(linux.access(target_z, linux.F_OK)) == .SUCCESS;
                if (kept) {
                    say("error: {s} {s} holds run {d}'s; give another, or delete it " ++
                        "(its run then keeps none)\n", .{ asked[2], path, id });
                    return error.DirectoryOfAnotherRun;
                }
                try runs.link_drop(arena, data, id, asked[0]);
                say("[determinismo] {s} {s} was run {d}'s, deleted since: that run " ++
                    "keeps none\n", .{ asked[2], path, id });
            }
        }
        const run = try runs.claim(arena, io, data);
        try runs.output_tee(arena, try std.fs.path.join(arena, &.{ run.directory, "output.log" }));
        say("[determinismo] run {d}: {s}\n", .{ run.id, run.directory });
        // A new run's clock jitters (VM.Options.tsc_jitter_seed), from its seed unless given.
        if (arguments.tsc_jitter_seed == null) {
            const drawn = jitter_from_seed(arguments.seed);
            arguments.tsc_jitter_seed = drawn;
            // Its own re-runs (replays, verification) too.
            arguments.raw_argv = try argv_set(arena, arguments.raw_argv, "--tsc-jitter-seed", try std.fmt.allocPrint(arena, "0x{x}", .{drawn}));
        }
        try run_request_write(arena, io, data, run.directory, arguments);
        break :claimed run.directory;
    };
    try runs.running_mark(arena, directory);
    // A resume, said to serve once its explorer holds the run (runs.adopt_note): it showed the
    // run ended. Its own resumes say it too, and serve has them running already.
    if (arguments.resume_run) {
        // Its last end's exit is not this resume's: gone before serve is told, so the one this
        // explorer writes as it ends is the run's (serve deleted it as it adopted the resume, and
        // a resume that had already ended read "passed" from its record: CE47).
        const stale = try std.fs.path.joinZ(arena, &.{ directory, "exit" });
        _ = linux.unlink(stale);
        const data = try runs.data_directory(arena, arguments.data_directory);
        if (runs.id_in(data, try runs.absolute(arena, directory))) |id| runs.adopt_note(arena, data, id) catch |err| {
            say("[determinismo] serve not told of this resume ({s}): it shows the run ended\n", .{@errorName(err)});
        };
    }
    arguments.run_directory = directory;
    const Placed = struct { name: []const u8, path: *?[]const u8 };
    for ([_]Placed{
        .{ .name = "events", .path = &arguments.events_directory },
        .{ .name = "record.jsonl", .path = &arguments.record_path },
        .{ .name = "tapes", .path = &arguments.tape_directory },
    }) |placed| {
        const own = try std.fs.path.join(arena, &.{ directory, placed.name });
        const elsewhere = placed.path.* orelse {
            placed.path.* = own;
            continue;
        };
        const target = try runs.absolute(arena, elsewhere);
        if (std.mem.eql(u8, target, own)) continue;
        const target_z = try arena.dupeSentinel(u8, target, 0);
        _ = linux.symlinkat(target_z, linux.AT.FDCWD, try arena.dupeSentinel(u8, own, 0));
    }
}

/// One scenario of an exploration of several, as a run of its own: the first keeps the run
/// already claimed (its request now naming the scenario), each next one claims another, with
/// its own output, request, record, events and tapes, the one before ending.
fn run_scenario(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
    scenario: []const u8,
    first: bool,
) !void {
    const data = try runs.data_directory(arena, arguments.data_directory);
    arguments.scenario = scenario;
    if (first) {
        // The run's request as asked (serve's, or the explorer's own): every later scenario's run
        // keeps it where its explorer's arguments say nothing (run_request_write).
        request_base = try std.fs.path.join(arena, &.{ arguments.run_directory.?, "request.json" });
        try run_request_write(arena, io, data, arguments.run_directory.?, arguments);
        return;
    }
    // A resume follows the chain: the scenario's run the interrupted explorer had started (its
    // id in the record before), resumed; none, the rest are new runs (a resume of the first
    // scenario's run explored the first alone, the others never: CE63, the blind Lean replica of
    // the platform).
    const followed: ?[]const u8 = if (arguments.resume_run) followed: {
        const id = try next_run_read(arena, io, arguments.record_path orelse break :followed null) orelse {
            arguments.resume_run = false;
            break :followed null;
        };
        break :followed try chain_follow(arena, io, data, id, scenario);
    } else null;
    const directory = followed orelse claimed: {
        const run = try runs.claim(arena, io, data);
        // In the record of the scenario's run before: a resume of it goes on here.
        report.record(.{ .next_run = run.id });
        try runs.output_tee(arena, try std.fs.path.join(arena, &.{ run.directory, "output.log" }));
        say("[determinismo] run {d}: {s} (scenario {s})\n", .{ run.id, run.directory, scenario });
        try run_request_write(arena, io, data, run.directory, arguments);
        break :claimed run.directory;
    };
    try runs.running_mark(arena, directory);
    // The record is opened once per run (command_explore): this one's anew.
    if (report.record_fd) |fd| {
        close(fd);
        report.record_fd = null;
    }
    arguments.run_directory = directory;
    arguments.events_directory = try std.fs.path.join(arena, &.{ directory, "events" });
    arguments.record_path = try std.fs.path.join(arena, &.{ directory, "record.jsonl" });
    arguments.tape_directory = try std.fs.path.join(arena, &.{ directory, "tapes" });
}

/// The run a scenario's record names as the next scenario's (`{"next_run":id}`), or null.
fn next_run_read(arena: std.mem.Allocator, io: std.Io, record_path: []const u8) !?u32 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, record_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return next_run_in(arena, source);
}

fn next_run_in(arena: std.mem.Allocator, source: []const u8) ?u32 {
    var found: ?u32 = null;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        if (std.mem.indexOf(u8, text, "\"next_run\"") == null) continue;
        const line = std.json.parseFromSliceLeaky(struct { next_run: ?u32 = null }, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (line.next_run) |id| found = id;
    }
    return found;
}

/// The next scenario's run of a chain, resumed: its directory, once no explorer holds it and
/// its request is that scenario's.
fn chain_follow(arena: std.mem.Allocator, io: std.Io, data: []const u8, id: u32, scenario: []const u8) ![]const u8 {
    const directory = try runs.directory_of(arena, data, id);
    if (runs.running_pid(arena, directory)) |pid| {
        say("[determinismo] run {d}, scenario {s}'s, is running (pid {d}): resume it once it ends\n", .{ id, scenario, pid });
        return error.RunRunning;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ directory, "request.json" }), arena, .limited(1 << 20));
    const asked = try std.json.parseFromSliceLeaky(serve.RunRequest, arena, text, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, asked.scenario orelse "", scenario)) {
        say("[determinismo] run {d} is scenario {s}'s, not {s}'s: the chain does not go on\n", .{ id, asked.scenario orelse "?", scenario });
        return error.Usage;
    }
    try runs.output_tee(arena, try std.fs.path.join(arena, &.{ directory, "output.log" }));
    say("[determinismo] run {d} resumed: {s} (scenario {s})\n", .{ id, directory, scenario });
    // Its last end's exit is not this resume's, and serve is told it runs (run_register's).
    _ = linux.unlink(try std.fs.path.joinZ(arena, &.{ directory, "exit" }));
    runs.adopt_note(arena, data, id) catch |err| {
        say("[determinismo] serve not told of this resume ({s}): it shows the run ended\n", .{@errorName(err)});
    };
    return directory;
}

test "a scenario's record names the next scenario's run, its last such line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(?u32, null), next_run_in(arena, "{\"run\":{}}\n{\"branch\":{\"index\":0}}\n"));
    try std.testing.expectEqual(@as(?u32, 12), next_run_in(arena, "{\"run\":{}}\n{\"next_run\":12}\n"));
    // A line cut short by an interruption is none.
    try std.testing.expectEqual(@as(?u32, 12), next_run_in(arena, "{\"next_run\":12}\n{\"next_run\":1"));
}

test "a run's request keeps what its guest's command line needs: the wall clock's start" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const kernel = try std.fs.path.joinZ(arena, &.{ directory, "vmlinuz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kernel, .data = "a kernel" });
    var arguments = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", kernel, "--clock-start-max", "0" });
    try run_request_write(arena, io, directory, directory, &arguments);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ directory, "request.json" }), arena, .limited(1 << 20));
    const asked = try std.json.parseFromSliceLeaky(serve.RunRequest, arena, text, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("0", asked.clock_start_max.?);
}

test "a run's request and machine keep every input its analyses boot with (CE51)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const kernel = try std.fs.path.joinZ(arena, &.{ directory, "vmlinuz" });
    const injector = try std.fs.path.joinZ(arena, &.{ directory, "injector" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kernel, .data = "a kernel" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = injector, .data = "an injector" });
    var arguments = try parse_arguments(arena, &.{
        "determinismo", "explore",    "--kernel",         kernel, "--timeline-limit",         "30s", "--no-swarm",
        "--epoch",      "2026-01-01", "--timer-slack-us", "250",  "--timer-landing-permille", "50",  "--injector",
        injector,
    });
    try run_request_write(arena, io, directory, directory, &arguments);
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ directory, "request.json" }), arena, .limited(1 << 20));
    const asked = try std.json.parseFromSliceLeaky(serve.RunRequest, arena, text, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("30s", asked.timeline_limit.?);
    try std.testing.expect(!asked.swarm);
    try std.testing.expectEqual(@as(usize, 1), asked.injectors.?.len);
    const machine = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ directory, "machine.json" }), arena, .limited(1 << 20));
    for ([_][]const u8{ "\"--epoch\"", "\"--timer-slack-us\",\"250\"", "\"--timer-landing-permille\",\"50\"" }) |word| {
        try std.testing.expect(std.mem.indexOf(u8, machine, word) != null);
    }
}

/// A run started here: what was asked (serve's request: the program kept by its content, as
/// serve keeps it) and the machine it boots (its kernel and initramfs kept the same way).
/// The run's request and machine; its kernel and initramfs kept, and the run boots those.
/// The request a run of several scenarios started from (its first run's request.json): a later
/// scenario's run keeps what it asked (run_request_write); null outside such a run.
var request_base: ?[]const u8 = null;

/// `asked`'s fields at their defaults take `base`'s: the explorer's own where it has them,
/// serve's elsewhere.
fn request_merge(asked: *serve.RunRequest, base: *const serve.RunRequest) void {
    const info = @typeInfo(serve.RunRequest).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        const default = attrs.defaultValue(T).?;
        const mine = @field(asked, name);
        const theirs = @field(base, name);
        if (field_default(T, mine, default) and !field_default(T, theirs, default)) {
            @field(asked, name) = theirs;
        }
    }
}

fn field_default(comptime T: type, value: T, default: T) bool {
    return switch (@typeInfo(T)) {
        .optional => value == null,
        .pointer => |pointer| if (pointer.size == .slice) value.len == 0 else value == default,
        else => std.meta.eql(value, default),
    };
}

test "a run's request keeps what serve asked where the explorer says nothing (CE63)" {
    var asked: serve.RunRequest = .{ .scenario = "first", .branching = "tree" };
    const base: serve.RunRequest = .{
        .scenario = "all",
        .return_branches = 2,
        .holders_on_disk = true,
        .checkpoint = "/data/machines/3/checkpoints/c1",
        .egress = &.{"10.0.0.0/8"},
    };
    request_merge(&asked, &base);
    // The explorer's own stay; serve's fill what it left at its defaults.
    try std.testing.expectEqualStrings("first", asked.scenario.?);
    try std.testing.expectEqualStrings("tree", asked.branching.?);
    try std.testing.expectEqual(@as(?u32, 2), asked.return_branches);
    try std.testing.expect(asked.holders_on_disk);
    try std.testing.expectEqualStrings("/data/machines/3/checkpoints/c1", asked.checkpoint.?);
    try std.testing.expectEqual(@as(usize, 1), asked.egress.len);
}

fn run_request_write(
    arena: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    directory: []const u8,
    arguments: *Arguments,
) !void {
    var asked: serve.RunRequest = .{
        .program = if (arguments.program_path) |path| try runs.artifact_keep(arena, io, data, path) else null,
        .program_asked = if (arguments.program_path) |path| try runs.absolute(arena, path) else null,
        .compose = if (arguments.compose_path) |path| try runs.absolute(arena, path) else null,
        .kubernetes = if (arguments.kubernetes_path) |path| try runs.absolute(arena, path) else null,
        .images = arguments.kubernetes_images,
        .scenario = arguments.scenario,
        .scenarios_next = arguments.scenarios_next,
        .profile = arguments.profile,
        .seed = arguments.seed,
        .branches = if (arguments.branches_given) arguments.branches else null,
        .time_budget = arguments.time_budget_text,
        .branching = @tagName(arguments.branching),
        .faults = arguments.faults_added,
        .no_faults = arguments.faults_none,
        // The coverage set changes the system (what its nodes report and pause at): serve's
        // replays of the run need it, and its coverage gate reads "off" here (a terminal's run
        // with --coverage off was stopped after its fourth timeline, 2026-11-18).
        .coverage = arguments.coverage,
        .timeline = arguments.timeline_text,
        .min_drive = arguments.min_drive_text,
        .drivers_cpu_weight = arguments.drivers_cpu_weight_text,
        .drive_max = arguments.drive_max_text, // In the guest's command line: replays need it.
        // In the guest's command line too: left out, serve's analyses of a run started with
        // --clock-start-max 0 booted another guest line, and its tapes were refused
        // (TapeInputsDiffer, run 2219's causality, 2026-11-26).
        .clock_start_max = arguments.clock_start_max_text,
        // The same for these: in the guest's command line or its initramfs, so an analysis of a
        // run started with one booted other inputs and was refused (CE51, the blind Lean replica
        // of the platform). Its injectors kept by content, as its kernel is.
        .timeline_limit = arguments.timeline_limit_text,
        .swarm = arguments.swarm,
        .injectors = if (arguments.injectors.len == 0) null else try runs.injectors_keep(arena, io, data, arguments.injectors),
        .trace_errno = arguments.trace_errno, // In the guest's command line: replays need it.
        .generation = arguments.generation_size,
        .horizon = arguments.horizon_text,
        .return_offsets = arguments.return_offsets_text,
        // In the guest's command line: replays need them.
        .fault_weights = arguments.fault_weights,
        .fault_exclusions = arguments.fault_exclusions,
        .keep = arguments.keep,
        .pipeline = arguments.pipeline,
        .jobs = arguments.jobs,
        .strategy = arguments.strategy_command,
        .changed = arguments.changed,
        .changed_repository = arguments.changed_repository,
        .retroactive = arguments.retroactive[0..arguments.retroactive_count],
        .from_branch = arguments.from_branch,
        .from_vtime_ms = arguments.from_vtime_ms,
        .cpu_modulation = arguments.cpu_modulation,
        .cpu_modulation_stretch_us = if (std.mem.eql(u64, &arguments.cpu_modulation_stretch_ns, &VM.modulation_stretch_default))
            null
        else
            try std.fmt.allocPrint(arena, "{d}-{d}", .{
                arguments.cpu_modulation_stretch_ns[0] / std.time.ns_per_us,
                arguments.cpu_modulation_stretch_ns[1] / std.time.ns_per_us,
            }),
        .memory_mib = arguments.memory_mib,
        .verify_replays = if (arguments.verify_percent != verify_percent_default) arguments.verify_percent else null,
        .priority = std.c.getenv("DETERMINISMO_CPU_PRIORITY") != null,
        .build = build_options.commit,
        .core = build_options.core_id,
        .host_kvm = @import("host_core.zig").kvm_identity(arena),
        .state_format = @import("runs.zig").state_format,
        // This explorer, kept by content as its kernel is (serve's replays of the run use it).
        .explorer = explorer: {
            var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
            if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
            break :explorer try runs.artifact_keep(arena, io, data, self_buffer[0..self_size]);
        },
    };
    var machine: std.ArrayList([]const u8) = .empty;
    // The run's own VMs and replays boot the kept copies too: a deploy that rebuilt the guest
    // mid-run made a direct run's later replays other inputs (run 381: 5 of them refused,
    // TapeInputsDiffer; serve's runs were kept already).
    const kernel_kept = try runs.artifact_keep(arena, io, data, arguments.kernel_path);
    try machine.appendSlice(arena, &.{ "--kernel", kernel_kept });
    arguments.kernel_path = kernel_kept;
    arguments.raw_argv = try argv_with(arena, arguments.raw_argv, "--kernel", kernel_kept);
    if (arguments.initrd_path) |path| {
        const initrd_kept = try runs.initrd_keep(arena, io, data, path);
        try machine.appendSlice(arena, &.{ "--initrd", initrd_kept });
        arguments.initrd_path = initrd_kept;
        arguments.raw_argv = try argv_with(arena, arguments.raw_argv, "--initrd", initrd_kept);
    }
    try machine.appendSlice(arena, &.{
        "--cmdline",      arguments.cmdline_given,
        "--cache",        try runs.absolute(arena, arguments.cache_directory),
        "--memory-mib",   try std.fmt.allocPrint(arena, "{d}", .{arguments.memory_mib}),
        // What its time is made of: its resumes and replays count the same, whatever the default
        // becomes.
        "--branch-event", try std.fmt.allocPrint(arena, "0x{x}", .{arguments.branch_event}),
    });
    if (arguments.tsc_jitter_seed) |seed| {
        try machine.appendSlice(arena, &.{ "--tsc-jitter-seed", try std.fmt.allocPrint(arena, "0x{x}", .{seed}) });
    }
    if (arguments.tsc_jitter_exact) try machine.append(arena, "--tsc-jitter-exact");
    // The guest's wall clock at boot and its timers, when asked: they make its inputs too (CE51).
    if (arguments.epoch_seconds) |seconds| try machine.appendSlice(arena, &.{ "--epoch", try std.fmt.allocPrint(arena, "{d}", .{seconds}) });
    if (arguments.timer_slack_us != 1000) try machine.appendSlice(arena, &.{ "--timer-slack-us", try std.fmt.allocPrint(arena, "{d}", .{arguments.timer_slack_us}) });
    if (arguments.timer_delay_permille != 0) try machine.appendSlice(arena, &.{ "--timer-landing-permille", try std.fmt.allocPrint(arena, "{d}", .{arguments.timer_delay_permille}) });
    // A guest CPU of another host's: its resumes and replays boot the same.
    if (arguments.cpuid_path) |path| try machine.appendSlice(arena, &.{ "--cpuid", try runs.absolute(arena, path) });
    if (arguments.guest_cpu != .host) try machine.appendSlice(arena, &.{ "--guest-cpu", @tagName(arguments.guest_cpu) });
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        try machine.appendSlice(arena, &.{ "--disk", try runs.absolute(arena, path) });
    }
    const cwd = std.Io.Dir.cwd();
    const request_path = try std.fs.path.join(arena, &.{ directory, "request.json" });
    // What serve asked for this run (its own request.json, or for a later scenario's run the
    // first's): kept where the explorer's arguments say nothing. Written over, a run of several
    // scenarios lost every field serve alone records (a CI job's, return branches, a checkpoint:
    // CE63, the blind Lean replica of the platform).
    const base_path = request_base orelse request_path;
    if (cwd.readFileAlloc(io, base_path, arena, .limited(1 << 20))) |text| {
        if (std.json.parseFromSliceLeaky(serve.RunRequest, arena, text, .{ .ignore_unknown_fields = true })) |base| {
            request_merge(&asked, &base);
        } else |_| {}
    } else |_| {}
    try cwd.writeFile(io, .{
        .sub_path = request_path,
        .data = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(asked, .{})}),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, "machine.json" }),
        .data = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(machine.items, .{})}),
    });
}

/// `determinismo serve [--listen <address:port>] [--data <dir>] <machine options>`: the HTTP
/// API (serve.zig). Machine options are passed to every run it starts.
fn command_serve(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var listen: []const u8 = "127.0.0.1:7878";
    var public_listen: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var explorer: ?[]const u8 = null;
    var archive: ?[]const u8 = null;
    var snapshots_keep_hours: u64 = 24;
    var ui_path: ?[]const u8 = null;
    var failure_snapshots = false;
    var failure_analysis = false;
    var session_idle_minutes: u64 = 30;
    var machine_start_seconds: u64 = 600;
    var machines_per_cpu: u32 = cpus.machines_per_cpu_default;
    var bb: []const u8 = "bb";
    var machine: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const flag = argv[index];
        const value = if (index + 1 < argv.len) argv[index + 1] else "";
        if (std.mem.eql(u8, flag, "--listen")) {
            listen = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--public-listen")) {
            public_listen = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--data")) {
            data = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--archive")) {
            archive = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--ui")) {
            // The UI page from this file, read at each request (a UI change ships as a file
            // copy, serve not rebuilt nor restarted); the built-in page without it.
            ui_path = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--snapshots-keep-hours")) {
            snapshots_keep_hours = try std.fmt.parseInt(u64, value, 10);
            index += 1;
        } else if (std.mem.eql(u8, flag, "--failure-snapshots")) {
            failure_snapshots = true;
        } else if (std.mem.eql(u8, flag, "--failure-analysis")) {
            failure_analysis = true;
        } else if (std.mem.eql(u8, flag, "--session-idle-minutes")) {
            session_idle_minutes = try std.fmt.parseInt(u64, value, 10);
            if (session_idle_minutes == 0) return error.SessionIdleMinutes;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--machine-start-seconds")) {
            machine_start_seconds = try std.fmt.parseInt(u64, value, 10);
            if (machine_start_seconds == 0) return error.MachineStartSeconds;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--machines-per-cpu")) {
            machines_per_cpu = try std.fmt.parseInt(u32, value, 10);
            if (machines_per_cpu == 0) return error.MachinesPerCpu;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--explorer")) {
            explorer = value; // Self-tests: a stand-in for `determinismo explore`.
            index += 1;
        } else if (std.mem.eql(u8, flag, "--bb")) {
            bb = value;
            index += 1;
        } else {
            try machine.append(arena, flag);
        }
    }
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try serve.serve(arena, init.io, .{
        .listen = listen,
        .public_listen = public_listen,
        .data_directory = try runs.data_directory(arena, data),
        .machine = machine.items,
        .self = explorer orelse self_buffer[0..self_size],
        .archive = archive,
        .bb = bb,
        .snapshots_keep_ns = snapshots_keep_hours * std.time.ns_per_hour,
        .ui_path = ui_path,
        .failure_snapshots = failure_snapshots,
        .failure_analysis = failure_analysis,
        .session_idle_ns = session_idle_minutes * std.time.ns_per_min,
        .machine_start_ns = machine_start_seconds * std.time.ns_per_s,
        .machines_per_cpu = machines_per_cpu,
    });
}

/// `determinismo mcp <machine options>`: an MCP server on stdio (mcp.zig).
fn command_mcp(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const machine = try arena.alloc([]const u8, argv.len);
    for (argv, machine) |argument, *target| target.* = argument;
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try mcp.serve(arena, init.io, .{
        .machine = machine,
        .self = self_buffer[0..self_size],
        .scratch_directory = "/tmp/determinismo-mcp",
    });
}

/// `determinismo validate (--program <p> | --compose <file> | --kubernetes <dir>) [--profile <p>]
/// [--cache <dir>] [--faults ...] [--no-faults ...]`: the system resolved, its images pulled or
/// built and its test templates found, without booting it, and what would keep a run from
/// testing it, as Antithesis's `snouty validate` checks a configuration before a launch: a
/// scenario with nothing to start (no driver and no first command), several setup commands, files
/// named as commands that cannot run. Its nodes and scenarios listed; exit status 1 with any
/// problem (a system that does not resolve fails as explore would, with its error).
fn command_validate(arena: std.mem.Allocator, io: std.Io, arguments: *Arguments) !u8 {
    const prepared = try system_prepare(arena, io, arguments);
    const system = &prepared.system;
    const print = std.debug.print;
    for (system.nodes) |node| {
        print("  node {s}  {s}  {s}\n", .{ node.name, node.address, if (node.digest.len > 0) node.digest else "(no image)" });
    }
    var problems: u32 = 0;
    for (system.scenarios) |scenario| {
        print("  scenario {s}{s}{s}\n", .{ scenario.name, if (scenario.node != null) " in " else "", scenario.node orelse "" });
        var setups: u32 = 0;
        for (scenario.commands) |command| {
            print("    {s:<17} {s}\n", .{ @tagName(command.kind), command.name });
            setups += @intFromBool(command.kind == .setup);
        }
        for (scenario.invalid) |invalid| {
            print("    INVALID  {s}: {s} (never run: \"test templates hold only valid commands\" fails)\n", .{ invalid.path, invalid.why });
            problems += 1;
        }
        switch (validate_driverless(scenario.commands)) {
            .drivers => {},
            .note => print("    NOTE     no driver command: after its first_ command the composer starts " ++
                "nothing, the system's own processes the workload (Antithesis's docs ask for a driver)\n", .{}),
            .problem => {
                print("    PROBLEM  no driver command (parallel_driver_, serial_driver_, singleton_driver_ or " ++
                    "anytime_) and no first_ command: nothing starts the workload\n", .{});
                problems += 1;
            },
        }
        if (setups > 1) {
            print("    PROBLEM  {d} setup commands: the composer takes one\n", .{setups});
            problems += 1;
        }
    }
    print("[determinismo] validate: {d} nodes, {d} scenarios, {d} {s}\n", .{
        system.nodes.len, system.scenarios.len, problems, if (problems == 1) "problem" else "problems",
    });
    return @intFromBool(problems > 0);
}

/// What validate says of a scenario with no driver command. Antithesis's docs ask for one, and
/// say nothing of refusing a template without: their formalized Raft projects run one of a single
/// first_start_workload, which touches a file while the driver container's own process runs the
/// workload (calibration lines 19-21; validate called it refused while run 2125 ran it). A
/// first_ command is a note; nothing at all to start is a problem.
const Driverless = enum { drivers, note, problem };

fn validate_driverless(commands: []const schema.Command) Driverless {
    var first = false;
    for (commands) |command| switch (command.kind) {
        .parallel_driver, .serial_driver, .singleton_driver, .anytime => return .drivers,
        .first => first = true,
        else => {},
    };
    return if (first) .note else .problem;
}

test validate_driverless {
    const driver: schema.Command = .{ .kind = .parallel_driver, .name = "parallel_driver_ops" };
    const first: schema.Command = .{ .kind = .first, .name = "first_start_workload" };
    const finally: schema.Command = .{ .kind = .finally, .name = "finally_check" };
    try std.testing.expectEqual(.drivers, validate_driverless(&.{ first, driver }));
    // Antithesis's formalized Raft projects: first_start_workload alone, the driver
    // container's own process the workload (calibration lines 19-21, run 2125).
    try std.testing.expectEqual(.note, validate_driverless(&.{first}));
    try std.testing.expectEqual(.problem, validate_driverless(&.{finally}));
    try std.testing.expectEqual(.problem, validate_driverless(&.{}));
}

/// Builds the disks of the program's system and records what was resolved.
fn system_prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
) !prepare.Prepared {
    if (arguments.disk_count > 0) return error.DisksAndProgram;
    const sources = @as(u32, @intFromBool(arguments.program_path != null)) +
        @intFromBool(arguments.compose_path != null) + @intFromBool(arguments.kubernetes_path != null);
    if (sources > 1) return error.Usage;
    if (arguments.kubernetes_images != null and arguments.kubernetes_path == null) return error.Usage;
    const prepared = try prepare.prepare(arena, io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .kubernetes = arguments.kubernetes_path,
        .kubernetes_images = arguments.kubernetes_images,
        .script = arguments.script_path,
        .injectors = arguments.injectors,
        .profile = arguments.profile,
        .cache_directory = arguments.cache_directory,
        .mutant = arguments.mutant,
        .faults_added = arguments.faults_added,
        .faults_none = arguments.faults_none,
        .coverage = arguments.coverage,
        .pinned = arguments.pinned,
        .scenario_none = arguments.dev_directory != null or arguments.hold_scenario,
    });
    if (prepared.disk_paths.len > VM.disks_max) return error.TooManyDisks;
    // With the run's events: what replays it (serve's replays, a kit for another host). Not on a
    // resume: the pin is its record's, and a resume refused as another run's (its images rebuilt
    // since) had overwritten it with the new system, losing the one its timelines ran on (runs
    // 1873-1880, 2026-11-11).
    if (arguments.events_directory) |directory| if (!arguments.resume_run) {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, directory);
        const pin = try std.fs.path.join(arena, &.{ directory, "system.pin.json" });
        try cwd.copyFile(prepared.pin_path, cwd, pin, io, .{});
    };
    const system_json = prepared.system_json;
    arguments.system = try std.json.parseFromSliceLeaky(std.json.Value, arena, system_json, .{});
    for (prepared.disk_paths, 0..) |path, index| arguments.disk_paths[index] = path;
    arguments.disk_count = @intCast(prepared.disk_paths.len);
    say("[determinismo] system {x:0>16}: profile {s}, {d} nodes, disk {s}, pin {s}\n", .{
        prepared.hash,          prepared.system.profile, prepared.system.nodes.len,
        prepared.disk_paths[0], prepared.pin_path,
    });
    return prepared;
}

/// How many nodes the system has (its JSON's `nodes`); 0 when unknown.
fn system_nodes(system: ?std.json.Value) u32 {
    const object = switch (system orelse return 0) {
        .object => |object| object,
        else => return 0,
    };
    const nodes = object.get("nodes") orelse return 0;
    return switch (nodes) {
        .array => |array| @intCast(array.items.len),
        else => 0,
    };
}

/// The scenarios to run, one at a time (null: the guest decides, as without --program).
fn scenarios_selected(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *const Arguments,
    prepared: ?prepare.Prepared,
) ![]const ?[]const u8 {
    const system = (prepared orelse return &.{null}).system;
    // A resume of a scenario's run of several: that scenario, then those its request names after
    // it (the chain run_scenario follows).
    if (arguments.resume_run) if (arguments.run_directory) |directory| {
        const path = try std.fs.path.join(arena, &.{ directory, "request.json" });
        if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20))) |text| {
            const asked = try std.json.parseFromSliceLeaky(serve.RunRequest, arena, text, .{ .ignore_unknown_fields = true });
            if (asked.scenarios_next) |next| if (next.len > 0) if (asked.scenario) |own| {
                const chain = try arena.alloc(?[]const u8, next.len + 1);
                chain[0] = own;
                for (chain[1..], next) |*slot, name| {
                    const scenario = system.scenario(name) orelse {
                        say("[determinismo] the run's next scenario {s} is no scenario of the system\n", .{name});
                        return error.Usage;
                    };
                    try quorum_known(system, scenario);
                    slot.* = name;
                }
                if (arguments.scenario) |wanted| if (!std.mem.eql(u8, wanted, own)) {
                    say("[determinismo] --scenario {s}: the resumed run is scenario {s}'s\n", .{ wanted, own });
                    return error.Usage;
                };
                return chain;
            };
        } else |_| {}
    };
    const wanted = arguments.scenario orelse if (system.scenarios.len == 1)
        system.scenarios[0].name
    else {
        say("[determinismo] pick a scenario with --scenario (or all)\n", .{});
        return error.Usage;
    };
    if (std.mem.eql(u8, wanted, "all") and system.scenario("all") != null) {
        say("[determinismo] a scenario is named all: rename it (--scenario all " ++
            "explores every scenario, so it would never run alone)\n", .{});
        return error.Usage;
    }
    if (std.mem.eql(u8, wanted, "all")) {
        const all = try arena.alloc(?[]const u8, system.scenarios.len);
        for (system.scenarios, all) |scenario, *name| {
            try quorum_known(system, scenario);
            name.* = scenario.name;
        }
        return all;
    }
    const scenario = system.scenario(wanted) orelse {
        say("[determinismo] no scenario named {s}\n", .{wanted});
        return error.Usage;
    };
    try quorum_known(system, scenario);
    alternatives_say(scenario);
    const one = try arena.alloc(?[]const u8, 1);
    one[0] = wanted;
    return one;
}

/// A scenario run names only nodes of the system in its quorum (schema.Scenario.quorum): an
/// unknown name would leave the fault injector's cap counting fewer. Checked for the scenario
/// run, not in prepare: a program's scenarios serve all its profiles, which differ in nodes.
fn quorum_known(system: anytype, scenario: anytype) !void {
    for (scenario.quorum) |name| {
        if (system.node(name) == null) {
            say("[determinismo] scenario {s}'s quorum names {s}, no node of this profile\n", .{ scenario.name, name });
            return error.Usage;
        }
    }
}

/// A scenario's commands of which a timeline runs one (a first; an eventually or a finally:
/// Antithesis's rule), said when there are several: checks meant to all run belong in one
/// command (Comdb2's judgment and its generations check ran each in about half the timelines).
fn alternatives_say(scenario: anytype) void {
    var first: u32 = 0;
    var ending: u32 = 0;
    for (scenario.commands) |command| switch (command.kind) {
        .first => first += 1,
        .eventually, .finally => ending += 1,
        else => {},
    };
    if (first > 1) say("[determinismo] scenario {s}: {d} first commands, a timeline runs one of them\n", .{ scenario.name, first });
    if (ending > 1) say("[determinismo] scenario {s}: {d} eventually and finally commands, a timeline runs one of them\n", .{ scenario.name, ending });
}

/// Whether the explorer answers its timelines' composers' asks for another driver phase
/// (advisor.zig): an exploration with the extension on. Nothing of it is in what a machine
/// boots with: a replay boots its tape's inputs, and the answers are on the tape.
fn objective_extends(arguments: *const Arguments) bool {
    return arguments.command == .explore and arguments.objective_extend;
}

test "fault exclusions: a pattern det-faults would not take is a usage error; one it takes is on the guest's command line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.Usage, parse_arguments(arena, &.{ "determinismo", "explore", "--fault-exclusions", "a{2}" }));
    try std.testing.expectError(error.Usage, parse_arguments(arena, &.{ "determinismo", "explore", "--fault-exclusions", "(a" }));
    // ParadeDB's: spaces and characters a command-line word could not carry go as hex.
    const pattern = "coredns|stressgres|cloudnative-pg|logical-replication-publisher";
    const arguments = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", "vmlinuz", "--fault-exclusions", pattern });
    try std.testing.expectEqualStrings(pattern, arguments.fault_exclusions.?);
    const line = try cmdline_build(arena, "console=ttyS0", &arguments, null);
    const key = "det.fault_exclusions=";
    const at = std.mem.indexOf(u8, line, key) orelse return error.TestUnexpectedResult;
    var words = std.mem.tokenizeScalar(u8, line[at + key.len ..], ' ');
    var decoded: [regex.pattern_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(pattern, try std.fmt.hexToBytes(&decoded, words.next().?));
    // None asked: no word.
    const plain = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", "vmlinuz" });
    // The holders' two arms: retention off and writeback on unless asked.
    try std.testing.expect(!plain.holders_retain and plain.holders_writeback);
    const arms = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", "vmlinuz", "--holders-retain", "--no-holders-writeback" });
    try std.testing.expect(arms.holders_retain and !arms.holders_writeback);
    // The wall clock's drawn start: the composer's hour unless asked, 0 none, a duration otherwise.
    try std.testing.expectEqual(@as(?u64, null), plain.clock_start_max_ms);
    const clock_off = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", "vmlinuz", "--clock-start-max", "0" });
    try std.testing.expectEqual(@as(?u64, 0), clock_off.clock_start_max_ms);
    try std.testing.expectEqualStrings("0", clock_off.clock_start_max_text.?);
    const clock_ten = try parse_arguments(arena, &.{ "determinismo", "explore", "--kernel", "vmlinuz", "--clock-start-max", "10m" });
    try std.testing.expectEqual(@as(?u64, 600_000), clock_ten.clock_start_max_ms);
    try std.testing.expect(std.mem.indexOf(u8, try cmdline_build(arena, "console=ttyS0", &clock_ten, null), "det.clock_start_max_ms=600000") != null);
    try std.testing.expect(std.mem.indexOf(u8, try cmdline_build(arena, "console=ttyS0", &plain, null), key) == null);
}

fn cmdline_build(
    arena: std.mem.Allocator,
    base: []const u8,
    arguments: *const Arguments,
    scenario: ?[]const u8,
) ![]const u8 {
    var parts: [16][]const u8 = undefined; // The base and each word below: 15, room to spare.
    var count: u32 = 0;
    parts[count] = base;
    count += 1;
    if (arguments.disk_count > 0) {
        parts[count] = try VM.disks_cmdline(arena, arguments.disk_count);
        count += 1;
    }
    if (scenario) |name| {
        parts[count] = try std.fmt.allocPrint(arena, "det.scenario={s}", .{name});
        count += 1;
    }
    if (arguments.timeline_ms) |ms| { // det-composer's.
        parts[count] = try std.fmt.allocPrint(arena, "det.timeline_ms={d}", .{ms});
        count += 1;
    }
    if (arguments.min_drive_ms) |ms| { // det-composer's.
        parts[count] = try std.fmt.allocPrint(arena, "det.min_drive_ms={d}", .{ms});
        count += 1;
    }
    if (arguments.drivers_cpu_weight) |weight| { // det-composer's.
        parts[count] = try std.fmt.allocPrint(arena, "det.drivers_cpu_weight={d}", .{weight});
        count += 1;
    }
    if (arguments.clock_start_max_ms) |ms| { // det-composer's: each timeline's wall clock start.
        parts[count] = try std.fmt.allocPrint(arena, "det.clock_start_max_ms={d}", .{ms});
        count += 1;
    }
    if (arguments.drive_max_ms) |ms| { // det-composer's: a scenario without a length's.
        parts[count] = try std.fmt.allocPrint(arena, "det.drive_ms_max={d}", .{ms});
        count += 1;
    }
    if (arguments.trace_errno) |errno| { // det-composer's: syscall_error events.
        parts[count] = try std.fmt.allocPrint(arena, "det.trace_errno={d}", .{errno});
        count += 1;
    }
    if (arguments.timeline_limit_ns) |ns| { // det-composer's: no driver starts past its half.
        parts[count] = try std.fmt.allocPrint(arena, "det.timeline_limit_ms={d}", .{ns / std.time.ns_per_ms});
        count += 1;
    }
    if (!arguments.swarm) { // det-faults': every fault kind in every timeline.
        parts[count] = "det.swarm=0";
        count += 1;
    }
    if (arguments.fault_weights) |weights| { // det-faults': kinds made common in half the timelines.
        parts[count] = try std.fmt.allocPrint(arena, "det.fault_weights={s}", .{weights});
        count += 1;
    }
    if (arguments.fault_exclusions) |pattern| { // det-faults': names that get no faults.
        parts[count] = try std.fmt.allocPrint(arena, "det.fault_exclusions={x}", .{pattern});
        count += 1;
    }
    if (arguments.keep) |names| { // det-composer's: commands kept in every timeline.
        parts[count] = try std.fmt.allocPrint(arena, "det.keep={s}", .{names});
        count += 1;
    }
    // Last: a strategy's machine appends it so to a fresh run's (command_explore), which its
    // replays then build alike.
    if (arguments.custom_faults) |hex| { // det-faults': a plugin's own faults (tape.Machine).
        parts[count] = try std.fmt.allocPrint(arena, "det.custom_faults={s}", .{hex});
        count += 1;
    }
    if (arguments.fault_poll_ms > 0) { // det-faults': its waits polled (tape.Machine).
        parts[count] = try std.fmt.allocPrint(arena, "det.fault_poll_ms={d}", .{arguments.fault_poll_ms});
        count += 1;
    }
    return std.mem.join(arena, " ", parts[0..count]);
}

fn command_run(context: Context, vm: *VM, options: *const VM.Options, from_snapshot: ?[]const u8) !void {
    assert(!options.stop_at_setup_complete);
    // A fast VM (several vCPUs, never deterministic: a sandbox, a CI job's setup) shares its CPU
    // with other machines; a deterministic one has a CPU of its own.
    if (options.vcpus > 1) own_cpu.take_shared() else own_cpu.take();
    if (from_snapshot) |path| {
        // A fast VM going on from a saved snapshot (`run --vcpus N --from-snapshot`).
        assert(options.vcpus > 1);
        const snapshot = try context.arena.create(Snapshot);
        try snapshot.disk_load(context.arena, context.io, std.fs.path.dirname(path) orelse ".", std.fs.path.basename(path), options.check_buffer, null);
        if (snapshot.memory_size != options.memory_size) return error.SnapshotMemoryDiffers;
        try vm.init_fast_from_snapshot(options, snapshot);
    } else try vm.init(options);
    defer vm.deinit();
    const time_start_ns = monotonic_ns();
    const outcome = try vm.run_until_exit();
    try report.run(vm, .{ .outcome = outcome, .wall_ns = monotonic_ns() - time_start_ns });
    switch (outcome) {
        .failed => std.process.exit(1),
        .debug_exit => |status| std.process.exit(status),
        .shutdown, .hlt, .moment_reached, .command_done, .hung => {},
        .setup_complete, .strategy_ended => unreachable, // No strategy runs here.
    }
}

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// determinismo's environment, which strategy plugins inherit.
    environ: [:null]const ?[*:0]const u8,
};

/// What drives the branches of one exploration besides the seed.
const Exploration = struct {
    /// Set when branching from a moment of another branch.
    fork: ?tape.Fork = null,
    /// Identifies what the machine boots; recorded in tapes.
    inputs: u64 = 0,
    /// The clock's jitter (VM.Options.tsc_jitter_seed, in `inputs`): recorded in tapes, whose
    /// replays boot with it.
    tsc_jitter_seed: u64 = 0,
    /// The machine a strategy decided for the run (Strategy.machine), on every tape: null for
    /// the run's options as given.
    machine: ?tape.Machine = null,
    /// This build of determinismo (a hash of its executable): recorded in tapes and the run's
    /// record, so that a replay by another build says so.
    host: u64 = 0,
    exploration_seed: u64,
    strategy: ?*Strategies = null,
    tape_directory: ?[]const u8 = null,
    /// Set when replaying one recorded branch.
    replay: ?struct { header: tape.Header, overrides: *tape.Overrides } = null,
    /// The replayed timeline extended as another (--extend): the one it was opened on and the
    /// moment, the new one's lineage (the parent's, then the parent up to the moment), and its
    /// tape, its header written as its number was taken.
    extend: ?Extend = null,
    /// A resumed run's (--resume): its timelines already recorded, skipped.
    done: ?*const Resumed = null,
};

/// `determinismo snapshot-diff <dir> <name> <dir> <name>`: how two saved moments' guest memory
/// differs (two runs of one timeline, saved at the same moment, should not). Each differing
/// 8-byte word is classed by its XOR: the bits a processor sets on its own in page-table
/// entries (Accessed 0x20, Dirty 0x40), or other data; the first pages are listed.
fn snapshot_diff(init: std.process.Init, names: []const []const u8) !void {
    const arena = init.arena.allocator();
    var snapshots: [2]Snapshot = undefined;
    const check_buffer = try std.heap.page_allocator.alloc(u8, checks.input_size_max); // Touched as used.
    for (&snapshots, 0..) |*snapshot, side| {
        try snapshot.disk_load(arena, init.io, names[2 * side], names[2 * side + 1], check_buffer, null);
    }
    if (snapshots[0].memory_size != snapshots[1].memory_size) return error.SizesDiffer;
    const size = snapshots[0].memory_size;
    var memories: [2][]const u8 = undefined;
    for (&memories, snapshots) |*memory, snapshot| {
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, snapshot.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.OutOfMemory;
        memory.* = @as([*]const u8, @ptrFromInt(address))[0..size];
    }
    const page = std.heap.page_size_min;
    var pages_differing: u64 = 0;
    var accessed_only: u64 = 0; // Words differing only in bit 5.
    var dirty_only: u64 = 0; // Only in bit 6.
    var both: u64 = 0;
    var other: u64 = 0;
    var listed: u32 = 0;
    var offset: usize = 0;
    while (offset < size) : (offset += page) {
        const a = memories[0][offset..][0..page];
        const b = memories[1][offset..][0..page];
        if (std.mem.eql(u8, a, b)) continue;
        pages_differing += 1;
        var words_ad: u32 = 0;
        var words_other: u32 = 0;
        var first_other: ?usize = null;
        var word: usize = 0;
        while (word < page) : (word += 8) {
            const x = std.mem.readInt(u64, a[word..][0..8], .little) ^ std.mem.readInt(u64, b[word..][0..8], .little);
            if (x == 0) continue;
            switch (x) {
                0x20 => accessed_only += 1,
                0x40 => dirty_only += 1,
                0x60 => both += 1,
                else => {
                    other += 1;
                    words_other += 1;
                    first_other = first_other orelse word;
                    continue;
                },
            }
            words_ad += 1;
        }
        if (listed < 40) {
            listed += 1;
            say("page 0x{x}: {d} words differ in Accessed/Dirty bits, {d} otherwise", .{ offset, words_ad, words_other });
            if (first_other) |at| {
                say(" (first at +0x{x}: {x:0>16} vs {x:0>16})", .{
                    at, std.mem.readInt(u64, a[at..][0..8], .little), std.mem.readInt(u64, b[at..][0..8], .little),
                });
            }
            say("\n", .{});
        }
    }
    say("{d} pages differ; words: {d} only Accessed, {d} only Dirty, {d} both, {d} otherwise\n", .{
        pages_differing, accessed_only, dirty_only, both, other,
    });
}

/// What a resumed run (--resume) takes from its record: the timelines it has, and for a tree
/// each one's summary (`<record>.summaries`), how many recorded timelines each return (its
/// generation, parent and moment) started, and the timelines of each generation judged, in order.
const Resumed = struct {
    done: std.AutoHashMapUnmanaged(u32, void) = .empty,
    summaries: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// The summaries file up to its last whole record (appended to from there).
    summaries_size: u64 = 0,
    /// Each return the interrupted run planned (RecordLine.planned): its children's numbers, in
    /// order, whether they ran or not. A resumed run gives them those numbers again, whatever order
    /// its nodes come in (judge_plan_one), and passes over them for any other (index_settle).
    planned: std.AutoHashMapUnmanaged(ReturnKey, []const u32) = .empty,
    planned_indices: std.AutoHashMapUnmanaged(u32, void) = .empty,
    generations: std.ArrayList([]const u32) = .empty,
    /// The fresh timelines taken while each generation was judged (queue_take), in order.
    fresh: std.ArrayList(Fresh) = .empty,
    /// The recorded timelines' properties (report.Recorded), counted in the resumed run's
    /// verdict as its own timelines' are (Multiverse.recorded_merge).
    recorded: std.ArrayList(RecordedOf) = .empty,
    /// Recorded timelines whose properties the record lacks (an older record's, or past its
    /// line's room): their verdicts are not counted, and the resume says how many.
    recorded_partial: u32 = 0,
    /// The catalog's failing assertions as the run last judged them (RecordLine.catalog), when the
    /// record has its verdict (`catalog_seen`: a run stopped before its end has none).
    catalog_failing: u32 = 0,
    catalog_seen: bool = false,
    /// The assertions the run declared and had not reached (RecordLine.declared): in a resume's
    /// catalog as the skipped timelines' declarations.
    declared: std.ArrayList(report.Recorded) = .empty,

    /// A record line (its run line checked by resume_read), in the record's order.
    fn note(resumed: *Resumed, arena: std.mem.Allocator, line: *const RecordLine) !void {
        if (line.generation) |judged| {
            if (judged.number == resumed.generations.items.len) {
                try resumed.generations.append(arena, judged.branches);
            }
        }
        if (line.fresh) |fresh| try resumed.fresh.append(arena, fresh);
        if (line.catalog) |judged| {
            resumed.catalog_failing = judged.failing;
            resumed.catalog_seen = true;
        }
        if (line.declared) |declared| try resumed.declared.append(arena, declared);
        if (line.branch) |branch| {
            // A timeline extending one of the run's (a session's): not the explorer's to resume.
            if (branch.extends != null) return;
            // Recorded after the catalog's verdict: that verdict judged fewer timelines (a drained
            // run's end, then a resume's own timelines): stale until a later end judges again
            // (CE61, the blind Lean replica of the platform).
            resumed.catalog_seen = false;
            try resumed.done.put(arena, branch.index, {});
            if (branch.properties) |properties| {
                for (properties) |property| try resumed.recorded.append(arena, .{ .index = branch.index, .property = property });
                if (!branch.properties_all) resumed.recorded_partial += 1;
            } else resumed.recorded_partial += 1;
        }
        if (line.planned) |planned| try resumed.plan_note(arena, planned);
    }

    fn plan_note(resumed: *Resumed, arena: std.mem.Allocator, planned: PlannedLine) !void {
        const key: ReturnKey = .{ .generation = planned.generation, .branch = planned.branch, .vtime_ns = planned.vtime_ns };
        try resumed.planned.put(arena, key, try arena.dupe(u32, planned.indices));
        for (planned.indices) |index| try resumed.planned_indices.put(arena, index, {});
    }

    /// Whether every timeline the interrupted run planned for a return is recorded: none runs
    /// again, and no node is made for it.
    fn return_recorded(resumed: *const Resumed, key: ReturnKey) bool {
        const indices = resumed.planned.get(key) orelse return false;
        for (indices) |index| if (!resumed.done.contains(index)) return false;
        return true;
    }

    /// The recorded timelines' properties in the run's verdict: those still recorded (one whose
    /// summary the interruption cut runs again, and counts then).
    fn merge_into(resumed: *const Resumed, multiverse: *report.Multiverse) !void {
        for (resumed.recorded.items) |*entry| {
            if (resumed.done.contains(entry.index)) try multiverse.recorded_merge(&entry.property, entry.index);
        }
        // Declarations alone: in the catalog, reached only if some timeline reached them.
        for (resumed.declared.items) |*declared| try multiverse.recorded_merge(declared, 0);
    }
};
const RecordedOf = struct { index: u32, property: report.Recorded };
const Fresh = struct { generation: u32, index: u32 };
/// A return's children as numbered (judge_plan_one): its generation, parent and moment, and their
/// numbers in order. Keyed by the timelines that ran, a resumed tree lost a return none of whose
/// children had (the rest renumbered: one then judged under another's plan, one started from the
/// setup snapshot inside another's path), and numbered its returns in the order its nodes came
/// (CE32-CE34, the blind Lean replica of the platform).
const PlannedLine = struct { generation: u32, branch: u32, vtime_ns: u64, indices: []const u32 };
const ReturnKey = struct { generation: u32, branch: u32, vtime_ns: u64 };

/// A complete run's verdict from its record: its timelines' properties merged, and its
/// catalog's assertions no timeline reached (RecordLine.catalog).
fn complete_verdict(arena: std.mem.Allocator, resumed: *const Resumed) !struct { properties: u32, status: u8 } {
    const multiverse = try arena.create(report.Multiverse);
    multiverse.* = .{};
    try resumed.merge_into(multiverse);
    const failing = multiverse.failing_properties();
    return .{ .properties = failing, .status = if (failing > 0 or resumed.catalog_failing > 0) 3 else 0 };
}

test "a resume's catalog has the skipped timelines' declarations, unreached unless one reached them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Timeline 0 declared reachable "r" and never reached it; the resumed run's timelines don't
    // declare it.
    var resumed: Resumed = .{};
    try resumed.done.put(arena, 0, {});
    try resumed.declared.append(arena, .{ .message = "r", .hash = 0, .kind = .reachable, .hits = 0, .trues = 0, .failure = null });
    const multiverse = try arena.create(report.Multiverse);
    multiverse.* = .{};
    try resumed.merge_into(multiverse);
    var catalog = report.Catalog{ .arena = arena };
    try multiverse.catalog_reached(&catalog);
    try std.testing.expectEqual(@as(u32, 1), catalog.judge(true));
}

test "a catalog verdict a later timeline follows is stale (CE61)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = [_][]const u8{
        // A drained run's end: two timelines, its catalog judged then (one failing).
        "{\"branch\":{\"index\":0}}",
        "{\"branch\":{\"index\":1}}",
        "{\"catalog\":{\"failing\":1}}",
        // A resume's timelines, interrupted before its own end: no verdict for them.
        "{\"branch\":{\"index\":2}}",
    };
    var resumed: Resumed = .{};
    for (texts) |text| {
        const line = try std.json.parseFromSliceLeaky(RecordLine, arena, text, .{ .ignore_unknown_fields = true });
        try resumed.note(arena, &line);
    }
    try std.testing.expect(!resumed.catalog_seen);
    // A later end's verdict judges them all.
    const judged = try std.json.parseFromSliceLeaky(RecordLine, arena, "{\"catalog\":{\"failing\":0}}", .{});
    try resumed.note(arena, &judged);
    try std.testing.expect(resumed.catalog_seen);
    try std.testing.expectEqual(@as(u32, 0), resumed.catalog_failing);
}

test "a complete run resumed again fails for its catalog too" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // Every recorded timeline passed; the run's catalog had an assertion no timeline reached.
    var resumed: Resumed = .{ .catalog_failing = 1 };
    const verdict = try complete_verdict(arena_state.allocator(), &resumed);
    try std.testing.expectEqual(@as(u32, 0), verdict.properties);
    try std.testing.expectEqual(@as(u8, 3), verdict.status);
}

/// What a run's record already has, for --resume: its run must be this one (the same inputs,
/// seed, branching and, for a tree, how it plans), or there is nothing to continue.
/// A resumed tree keeps the settings its record says it ran with (its archive, its pipeline),
/// unless given again: a run started under other defaults still continues.
fn resume_settings_adopt(arena: std.mem.Allocator, io: std.Io, arguments: *Arguments) !void {
    const path = arguments.record_path orelse return;
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return;
    const first = source[0 .. std.mem.indexOfScalar(u8, source, '\n') orelse source.len];
    const Line = struct { run: ?struct { pipeline: ?u32 = null, archive: ?bool = null, prefer_sometimes: ?bool = null, prefer_severe: ?bool = null, ranges: ?bool = null, memory_objective: ?bool = null, objective_extend: ?bool = null, tsc_jitter_seed: ?[]const u8 = null, machine: ?tape.Machine = null } = null };
    const line = std.json.parseFromSliceLeaky(Line, arena, first, .{ .ignore_unknown_fields = true }) catch return;
    const run = line.run orelse return;
    if (!arguments.archive_given) if (run.archive) |archive| {
        arguments.archive = archive;
    };
    // Recorded before it existed: it ran without.
    if (!arguments.prefer_sometimes_given) arguments.prefer_sometimes = run.prefer_sometimes orelse false;
    if (!arguments.prefer_severe_given) arguments.prefer_severe = run.prefer_severe orelse false;
    if (!arguments.ranges_given) arguments.ranges = run.ranges orelse false;
    // On since 2026-11-08, recorded since 2026-11-12: a run recorded between had it.
    if (!arguments.memory_objective_given) arguments.memory_objective = run.memory_objective orelse true;
    // Recorded before it existed: it ran without.
    if (!arguments.objective_extend_given) arguments.objective_extend = run.objective_extend orelse false;
    if (!arguments.pipeline_given) if (run.pipeline) |pipeline| {
        arguments.pipeline = pipeline;
    };
    // The clock's jitter the run had (part of its inputs: drawn for a new run only, a resume
    // ran without it and was refused as another run's record, the e2e resume check).
    // None in the record: a run from before the jitter, the exact clock.
    if (arguments.tsc_jitter_seed == null) arguments.tsc_jitter_seed = if (run.tsc_jitter_seed) |hex|
        std.fmt.parseInt(u64, hex, 16) catch return error.Usage
    else
        0;
    // The machine its strategy decided, if one did: a resume is not asked again (its first
    // timelines had this one).
    if (run.machine) |machine| machine_adopt(arguments, machine);
}

/// A machine a strategy decided, as the run's options: a replay's (from its tape) or a resume's
/// (from its record).
fn machine_adopt(arguments: *Arguments, machine: tape.Machine) void {
    arguments.epoch_seconds = machine.epoch_seconds;
    arguments.timer_slack_us = machine.timer_slack_ns / std.time.ns_per_us;
    arguments.cpu_modulation_stretch_ns = machine.modulation_stretch_ns;
    arguments.timer_delay_permille = machine.timer_delay_permille;
    arguments.custom_faults = if (machine.custom_faults.len > 0) machine.custom_faults else null;
    arguments.fault_poll_ms = machine.fault_poll_ms;
    arguments.machine_adopted = machine;
}

const jitter_from_seed = VM.jitter_from_seed;

/// A record line as a resume reads it back (resume_load): part of what an explorer persists
/// (persisted_layout).
const RecordLine = struct {
    run: ?struct {
        inputs: ?[]const u8 = null,
        seed: ?[]const u8 = null,
        branching: ?[]const u8 = null,
        generation: ?u32 = null,
        pipeline: ?u32 = null,
        archive: ?bool = null,
        horizon_ns: ?u64 = null,
        /// Before --return-branches, every record's: 4.
        return_branches: u32 = tree.children,
        queue: bool = false,
    } = null,
    branch: ?struct {
        index: u32,
        generation: u32 = 0,
        path: []const struct { branch: u32, vtime_ns: u64 } = &.{},
        extends: ?tape.Extends = null,
        /// Null in a record from before timelines kept them (report.Recorded).
        properties: ?[]const report.Recorded = null,
        properties_all: bool = true,
    } = null,
    generation: ?struct { number: u32, branches: []const u32 } = null,
    fresh: ?Fresh = null,
    planned: ?PlannedLine = null,
    /// An assertion declared and not reached, the first time the run saw it (report.zig).
    declared: ?report.Recorded = null,
    /// The run's catalog judged (main's catalog.judge: its assertions no timeline reached), the
    /// last such line the run's verdict.
    catalog: ?struct { failing: u32 = 0 } = null,
};

fn resume_read(context: Context, arguments: *const Arguments, inputs: u64) !*const Resumed {
    const path = arguments.record_path orelse {
        say("[determinismo] --resume continues the run of a record: give --record\n", .{});
        return error.Usage;
    };
    const tree_run = arguments.branching == .tree;
    if (tree_run and arguments.strategy_command != null) {
        say("[determinismo] --resume continues trees without a strategy (a strategy's " ++
            "state was its own process's)\n", .{});
        return error.Usage;
    }
    const Line = RecordLine;
    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .unlimited);
    const resumed = try context.arena.create(Resumed);
    resumed.* = .{};
    var run_seen = false;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        // A line cut short by the interruption is not a timeline.
        const line = std.json.parseFromSliceLeaky(Line, context.arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (line.run) |run| {
            run_seen = true;
            const same = std.mem.eql(u8, run.inputs orelse "", &hex16(inputs)) and
                std.mem.eql(u8, run.seed orelse "", &hex16(arguments.seed)) and
                std.mem.eql(u8, run.branching orelse "", @tagName(arguments.branching)) and
                (!tree_run or (run.generation == arguments.generation_size and
                    run.pipeline == arguments.pipeline and run.archive == arguments.archive and
                    run.horizon_ns == arguments.horizon_ns and
                    run.return_branches == arguments.return_branches and run.queue));
            if (!same) {
                say("[determinismo] {s} is the record of another run (inputs {s}, " ++
                    "seed {s}, {s} branching; these: {s}, {s}, {s}; a tree's generation, " ++
                    "pipeline, archive, horizon, return branches and queue too): start a new run\n", .{
                    path,                          run.inputs orelse "?", run.seed orelse "?",
                    run.branching orelse "?",      &hex16(inputs),        &hex16(arguments.seed),
                    @tagName(arguments.branching),
                });
                return error.RecordOfAnotherRun;
            }
        }
        try resumed.note(context.arena, &line);
    }
    if (!run_seen) {
        say("[determinismo] {s} has no run to continue\n", .{path});
        return error.Usage;
    }
    if (tree_run) {
        const summaries_path = try std.fmt.allocPrint(context.arena, "{s}.summaries", .{path});
        const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, summaries_path, context.arena, .unlimited) catch |err| {
            say("[determinismo] {s}: {s} (a tree continues from its timelines' " ++
                "summaries, recorded since this version)\n", .{ summaries_path, @errorName(err) });
            return error.Usage;
        };
        resumed.summaries_size = try summaries_index(context.arena, bytes, &resumed.summaries);
        // A timeline without its summary (the interruption cut it) runs again.
        var indices = resumed.done.keyIterator();
        var missing: std.ArrayList(u32) = .empty;
        while (indices.next()) |index| {
            if (!resumed.summaries.contains(index.*)) try missing.append(context.arena, index.*);
        }
        for (missing.items) |index| _ = resumed.done.remove(index);
    }
    say("[determinismo] resuming {s}: {d} timelines recorded, skipped, their properties counted\n", .{ path, resumed.done.count() });
    if (resumed.recorded_partial > 0) say("[determinismo] {d} of them without their properties in " ++
        "the record (an older record, or more than its line holds): their verdicts not counted\n", .{resumed.recorded_partial});
    const left = for (0..arguments.branches) |index| {
        if (!resumed.done.contains(@intCast(index))) break true;
    } else false;
    // Complete, its catalog judged in its record: judged from the record. Without that verdict (a
    // run stopped after its last timeline, before its end) it ends as a run does, its catalog
    // judged with its scenarios (CE45's remainder). In a chain of scenarios, it ends as a run
    // does too: the next scenario's run follows, and the catalog spans them all.
    if (!left and resumed.catalog_seen and !arguments.scenario_chain) {
        // Judged from its record, as the run that recorded it would have been (a complete run
        // resumed once exited 0 here whatever its timelines failed: CE29). A catalog's
        // assertions no timeline reached are judged by the runs that ran timelines.
        const verdict = try complete_verdict(context.arena, resumed);
        say("[determinismo] the run is complete: all {d} timelines recorded, {d} properties failing in them, " ++
            "{d} of its catalog's\n", .{ arguments.branches, verdict.properties, resumed.catalog_failing });
        const status = verdict.status;
        if (exploration_is_run(arguments)) if (arguments.run_directory) |directory| {
            const text = try std.fmt.allocPrint(context.arena, "{d} exited with status {d}\n", .{ status, status });
            const exit_path = try std.fs.path.join(context.arena, &.{ directory, "exit" });
            std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = exit_path, .data = text }) catch {};
        };
        std.process.exit(status);
    }
    return resumed;
}

/// Where a tree's timelines write their summaries as they end (`<record>.summaries`, for
/// --resume): opened by the explorer before its workers fork, written by them.
var tree_summaries_fd: ?linux.fd_t = null;

/// A tree timeline's summary on disk (`<record>.summaries`, for --resume): this, then the
/// behaviors it reached (only those); its holders were processes of the run.
const SummaryHeader = extern struct {
    index: u32,
    behavior_count: u32,
    start_ns: u64,
    end_ns: u64,
    trace_hash: u64,
    last_pull_ns: u64,
    cut: u8,
    /// The behaviors' layout (summary_format): another build's are refused.
    format: u8 = summary_format,
    /// 1: `jitter_seed` is its own clock (Summary.jitter_seed); 0: the run's.
    own_clock: u8 = 0,
    /// 1: `seed` is the seed it ran with (Summary.seed).
    own_seed: u8 = 0,
    /// 1: `tape_full_ns` is when its tape was full (Summary.tape_full_ns).
    tape_full: u8 = 0,
    reserved: [3]u8 = @splat(0),
    jitter_seed: u64 = 0,
    seed: u64 = 0,
    tape_full_ns: u64 = 0,
};

/// Bumped whenever Events.Behavior changes. 1: `sought`. 2: `score`. (SummaryHeader's own
/// fields move runs.state_format: 2, a timeline's own clock.)
const summary_format = 2;

/// What an explorer persists and a later one reads back on a resume, by layout (persisted_hash): the timelines' summaries and the behaviors they carry, the record's
/// lines as read back, a holder's place in the registry, the bandit's state. Any change to them
/// is a change of runs.state_format (its test): a run made with another keeps its own explorer.
const persisted_layout: u64 = layout: {
    @setEvalBranchQuota(10_000_000);
    var hasher = std.hash.Wyhash.init(0);
    for (.{ SummaryHeader, Events.Behavior, RecordLine, holders.Held, bandit_zig.Bandit }) |T| {
        persisted_hash(T, &hasher);
    }
    break :layout hasher.final();
};

/// A type's layout into `hasher`: its size, a struct's fields' names, offsets and types in turn, an
/// array's, an optional's, a pointer's or a union's what it holds, an enum's tag and fields, a
/// number's name; never a compound type's name, which the compiler numbers by analysis order
/// (the explorer's own variant of the core's snapshot.layout_hash: an edit of the core moves
/// every run's pin).
fn persisted_hash(comptime T: type, hasher: *std.hash.Wyhash) void {
    hasher.update(std.mem.asBytes(&@as(u64, @sizeOf(T))));
    switch (@typeInfo(T)) {
        // A struct's or a union's by its fields, never its name: an anonymous one's (RecordLine's
        // own) carries its place in the source, which every edit above it moves.
        .@"struct" => |info| {
            hasher.update("struct");
            for (info.field_names, info.field_types) |name, field| {
                hasher.update(name);
                if (info.layout != .@"packed") hasher.update(std.mem.asBytes(&@as(u64, @offsetOf(T, name))));
                persisted_hash(field, hasher);
            }
        },
        .@"union" => |info| {
            hasher.update("union");
            for (info.field_names, info.field_types) |name, field| {
                hasher.update(name);
                persisted_hash(field, hasher);
            }
        },
        .array => |info| {
            hasher.update("array");
            persisted_hash(info.child, hasher);
        },
        .optional => |info| {
            hasher.update("optional");
            persisted_hash(info.child, hasher);
        },
        // A slice's or a pointer's by its size and what it points to: a slice of an anonymous
        // struct (RecordLine's path) is named by the compiler's analysis order, which an
        // unrelated edit moves (2026-11-15: another tree's src-main failed with no format
        // changed).
        .pointer => |info| {
            hasher.update("pointer");
            hasher.update(@tagName(info.size));
            persisted_hash(info.child, hasher);
        },
        .@"enum" => |info| {
            hasher.update("enum");
            persisted_hash(info.tag_type, hasher);
            for (info.field_names, info.field_values) |name, value| {
                hasher.update(name);
                hasher.update(std.mem.asBytes(&@as(i128, value)));
            }
        },
        // Numbers and truth values by name (u32, f64, bool: names nothing moves).
        .int, .float, .bool => hasher.update(@typeName(T)),
        else => @compileError("persisted_hash: no layout rule for " ++ @typeName(T)),
    }
}

test "what an explorer persists changes only with runs.state_format" {
    // A failure here: the layout changed. Bump runs.state_format and set both below to the new
    // values (a run made before then resumes on its own explorer, never on one that misreads it).
    try std.testing.expectEqual(@as(u32, 8), runs.state_format);
    try std.testing.expectEqual(@as(u64, 822319605095176114), persisted_layout);
}

fn summary_write(fd: linux.fd_t, summary: *const Summary) void {
    const header: SummaryHeader = .{
        .index = summary.index,
        .behavior_count = summary.behavior_count,
        .start_ns = summary.start_ns,
        .end_ns = summary.end_ns,
        .trace_hash = summary.trace_hash,
        .last_pull_ns = summary.last_pull_ns,
        .cut = @intFromBool(summary.cut),
        .own_clock = @intFromBool(summary.jitter_seed != null),
        .jitter_seed = summary.jitter_seed orelse 0,
        .own_seed = @intFromBool(summary.seed != null),
        .seed = summary.seed orelse 0,
        .tape_full = @intFromBool(summary.tape_full_ns != null),
        .tape_full_ns = summary.tape_full_ns orelse 0,
    };
    const behaviors = std.mem.sliceAsBytes(summary.behaviors[0..summary.behavior_count]);
    const vectors = [_]std.posix.iovec_const{
        .{ .base = std.mem.asBytes(&header), .len = @sizeOf(SummaryHeader) },
        .{ .base = behaviors.ptr, .len = behaviors.len },
    };
    _ = linux.writev(fd, &vectors, vectors.len); // One write: a record whole, or cut at its end.
}

/// Each whole summary record's bytes, by its timeline (a last one the interruption cut is left);
/// returns where the whole records end.
fn summaries_index(arena: std.mem.Allocator, bytes: []const u8, out: *std.AutoHashMapUnmanaged(u32, []const u8)) !usize {
    var at: usize = 0;
    while (bytes.len - at >= @sizeOf(SummaryHeader)) {
        const header = std.mem.bytesToValue(SummaryHeader, bytes[at..][0..@sizeOf(SummaryHeader)]);
        if (header.format != summary_format) return error.SummariesOfAnotherBuild;
        if (header.behavior_count > Events.behavior_count_max) return error.BadSummaries;
        const size = @sizeOf(SummaryHeader) + header.behavior_count * @sizeOf(Events.Behavior);
        if (bytes.len - at < size) break;
        try out.put(arena, header.index, bytes[at..][0..size]);
        at += size;
    }
    return at;
}

fn summary_load(summary: *Summary, bytes: []const u8) void {
    const header = std.mem.bytesToValue(SummaryHeader, bytes[0..@sizeOf(SummaryHeader)]);
    summary.index = header.index;
    summary.start_ns = header.start_ns;
    summary.end_ns = header.end_ns;
    summary.trace_hash = header.trace_hash;
    summary.last_pull_ns = header.last_pull_ns;
    summary.cut = header.cut != 0;
    summary.jitter_seed = if (header.own_clock != 0) header.jitter_seed else null;
    summary.seed = if (header.own_seed != 0) header.seed else null;
    summary.tape_full_ns = if (header.tape_full != 0) header.tape_full_ns else null;
    summary.ended_early = false;
    summary.again_ns = null;
    summary.holder_count = 0; // Gone with the run: its moments are made again by replay.
    summary.failing_count = 0; // Its holders went with the run: no ladder to save.
    summary.bandit_use_count = 0; // Not on disk: nothing to credit.
    summary.behavior_count = header.behavior_count;
    @memcpy(std.mem.sliceAsBytes(summary.behaviors[0..header.behavior_count]), bytes[@sizeOf(SummaryHeader)..]);
}

test "a resumed run keeps the archive and pipeline its record says, unless given again" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const record = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/record.jsonl", .{&tmp.sub_path});
    // Recorded under the old defaults: no archive, three generations in flight.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = record,
        .data = "{\"run\":{\"seed\":\"0000000000000002\",\"pipeline\":3,\"archive\":false}}\n",
    });
    var kept: Arguments = .{ .command = .explore, .record_path = record, .pipeline = 2 };
    try resume_settings_adopt(arena, io, &kept);
    try std.testing.expect(!kept.archive);
    try std.testing.expectEqual(3, kept.pipeline);
    var given: Arguments = .{
        .command = .explore,
        .record_path = record,
        .archive_given = true,
        .pipeline = 2,
        .pipeline_given = true,
    };
    try resume_settings_adopt(arena, io, &given);
    try std.testing.expect(given.archive);
    try std.testing.expectEqual(2, given.pipeline);
}

test "summaries round trip, a cut last one left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const summary = try arena.allocator().create(Summary);
    summary.index = 7;
    summary.start_ns = 1;
    summary.end_ns = 9;
    summary.trace_hash = 0xabc;
    summary.last_pull_ns = 5;
    summary.cut = true;
    summary.tape_full_ns = 4;
    summary.jitter_seed = null;
    summary.seed = null;
    summary.behavior_count = 2;
    summary.behaviors[0] = .{ .hash = 11, .vtime_ns = 3 };
    summary.behaviors[1] = .{ .hash = 12, .vtime_ns = 4 };
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{})));
    summary_write(pipe[1], summary);
    summary_write(pipe[1], summary);
    _ = linux.close(pipe[1]);
    var buffer: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &buffer, buffer.len);
    _ = linux.close(pipe[0]);
    const record_size = @sizeOf(SummaryHeader) + 2 * @sizeOf(Events.Behavior);
    try std.testing.expectEqual(2 * record_size, size);
    var index: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const whole = try summaries_index(arena.allocator(), buffer[0 .. size - 1], &index); // The second cut.
    try std.testing.expectEqual(1, index.count());
    try std.testing.expectEqual(record_size, whole);
    const loaded = try arena.allocator().create(Summary);
    summary_load(loaded, index.get(7).?);
    try std.testing.expectEqual(2, loaded.behavior_count);
    try std.testing.expectEqual(12, loaded.behaviors[1].hash);
    try std.testing.expect(loaded.cut);
    try std.testing.expectEqual(@as(?u64, 4), loaded.tape_full_ns);
    try std.testing.expectEqual(0, loaded.holder_count);
}

/// Boots once to setup_complete, snapshots, then runs every branch from the snapshot.
/// Returns the multiverse: its verdict, and what the test program's catalog saw.
fn command_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    arguments: *const Arguments,
) !*const report.Multiverse {
    assert(options.deterministic);
    var exploration = Exploration{
        .exploration_seed = arguments.seed,
        .tape_directory = arguments.tape_directory,
    };
    // What the branches read (--exec-at-start's moment set once the snapshot is known).
    var branch_arguments: *const Arguments = arguments;
    if (arguments.tape_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    }
    // A strategy decides the machine the run boots too, when it wants (Strategy.machine: the
    // guest's wall clock, where timer interrupts land in their slack, the clock's jitter, CPU
    // modulation's stretches), asked before the inputs are known; on every tape and in the
    // record, which a replay or a resume boots with (not asked again). Not a run from a
    // snapshot: its machine is the snapshot's.
    const fresh_setup = arguments.from_snapshot == null and arguments.tape_snapshot == null;
    if (arguments.machine_adopted) |machine| {
        exploration.machine = machine;
    } else if (arguments.strategy_command != null and arguments.tape_path == null and !arguments.resume_run and fresh_setup) {
        try strategy_start(context, arguments, &exploration);
        if (exploration.strategy.?.wants_machine) {
            const decided = try exploration.strategy.?.machine(context.arena, .{
                .machine = .{
                    .epoch_seconds = options.epoch_seconds,
                    .timer_slack_ns = options.timer_slack_ns,
                    .modulation_stretch_ns = options.modulation_stretch_ns,
                    .timer_delay_permille = options.timer_delay_permille,
                },
                .tsc_jitter_seed = options.tsc_jitter_seed,
            });
            options.epoch_seconds = decided.machine.epoch_seconds;
            options.timer_slack_ns = decided.machine.timer_slack_ns;
            options.modulation_stretch_ns = decided.machine.modulation_stretch_ns;
            options.timer_delay_permille = decided.machine.timer_delay_permille;
            options.tsc_jitter_seed = decided.tsc_jitter_seed;
            // Its own faults, to the guest's injector on its command line (in the inputs).
            if (decided.machine.custom_faults.len > 0) {
                options.cmdline = try std.fmt.allocPrint(context.arena, "{s} det.custom_faults={s}", .{ options.cmdline, decided.machine.custom_faults });
            }
            // And its poll of the injector's waits (after it, as cmdline_build puts it).
            if (decided.machine.fault_poll_ms > 0) {
                options.cmdline = try std.fmt.allocPrint(context.arena, "{s} det.fault_poll_ms={d}", .{ options.cmdline, decided.machine.fault_poll_ms });
            }
            exploration.machine = decided.machine;
            say("[determinismo] the machine its strategy decided: wall clock {d}, timer slack {d} us landing at {d}/1000 of it, jitter {x:0>16}, stretches {d}-{d} us\n", .{
                decided.machine.epoch_seconds,                                 decided.machine.timer_slack_ns / std.time.ns_per_us,           decided.machine.timer_delay_permille, decided.tsc_jitter_seed,
                decided.machine.modulation_stretch_ns[0] / std.time.ns_per_us, decided.machine.modulation_stretch_ns[1] / std.time.ns_per_us,
            });
        }
    }
    exploration.inputs = inputs_hash(options, arguments);
    exploration.tsc_jitter_seed = options.tsc_jitter_seed;
    exploration.host = host_build();
    const signature = guest_cpu_signature(options)[3];
    const host_signature = host_cpu_signature()[3];
    if (options.cpuid_table != null) {
        // A replay on another model says so: the guest is shown the table's CPU, the host is
        // another.
        say("[determinismo] inputs {x:0>16} (determinism ABI {d}, CPU signature {x:0>8} " ++
            "the given table's, on a host of {x:0>8})\n", .{ exploration.inputs, VM.determinism_abi, signature, host_signature });
    } else say("[determinismo] inputs {x:0>16} (determinism ABI {d}, CPU signature " ++
        "{x:0>8})\n", .{ exploration.inputs, VM.determinism_abi, signature });
    if (arguments.resume_run) {
        exploration.done = try resume_read(context, arguments, exploration.inputs);
    }
    if (arguments.record_path) |path| {
        if (report.record_fd == null) {
            report.record_fd = try open_for_appending(context.arena, path, if (arguments.resume_run) .resumed else .fresh);
            report.declared_seen_open();
        }
    }
    if (arguments.record_path != null and !arguments.resume_run) {
        const jitter_hex = hex16(exploration.tsc_jitter_seed);
        report.record(.{
            .run = .{
                .scenario = scenario_of(options.cmdline),
                .profile = arguments.profile,
                .program = arguments.program_path,
                .compose = arguments.compose_path,
                .kubernetes = arguments.kubernetes_path,
                .system = arguments.system,
                .inputs = &hex16(exploration.inputs),
                .seed = &hex16(arguments.seed),
                .branches = arguments.branches,
                .from_branch = arguments.from_branch,
                .from_vtime_ms = arguments.from_vtime_ms,
                .shard = &.{ arguments.shard_index, arguments.shard_count },
                .time_budget_s = if (arguments.time_budget_ns) |ns| ns / std.time.ns_per_s else null,
                .timeline_ms = arguments.timeline_ms,
                .generation = arguments.generation_size,
                .pipeline = arguments.pipeline,
                .archive = arguments.archive,
                .prefer_sometimes = arguments.prefer_sometimes,
                .prefer_severe = arguments.prefer_severe,
                .ranges = arguments.ranges,
                .memory_objective = arguments.memory_objective,
                .objective_extend = arguments.objective_extend,
                .horizon_ns = arguments.horizon_ns,
                .return_branches = arguments.return_branches,
                .jobs = jobs_count(arguments),
                .strategy = arguments.strategy_command,
                .branching = @tagName(arguments.branching),
                .host = &hex16(exploration.host),
                // The clock's jitter it ran with (part of its inputs): a resume runs with it.
                .tsc_jitter_seed = if (exploration.tsc_jitter_seed != 0) &jitter_hex else null,
                // The machine its strategy decided: a resume boots it, not asked again.
                .machine = exploration.machine,
                // A tree's generations are the timelines that finished together, recorded as
                // judged (explore_tree): a record without them is not one to resume.
                .queue = true,
            },
        });
    }
    if (arguments.tape_path) |path| {
        const overrides = try tape.Overrides.create(context.arena);
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAlloc(context.io, path, context.arena, .unlimited);
        const scratch = try context.arena.alloc(u8, 64 * 1024);
        const header = try tape.parse(source, scratch, overrides);
        if (header.inputs != exploration.inputs) {
            say("[determinismo] the tape was recorded with inputs {x:0>16}; " ++
                "these are {x:0>16} (kernel, initramfs, command line, disks or CPU modulation " ++
                "differ: runs before 2026-10-28 had none, --no-cpu-modulation; modulated runs before " ++
                "2026-11-01 another modulation version, " ++ std.fmt.comptimePrint("{d}", .{VM.modulation_version}) ++ " now)\n", .{
                header.inputs, exploration.inputs,
            });
            return error.TapeInputsDiffer;
        }
        // Recorded by another build: allowed (most changes leave timelines as they were), but a
        // replay that parts from the tape may then be the build's doing (run 56, recorded the day
        // before: the same 26 of 64 parted, at the same events, with or without hyperthreads).
        if (header.host) |host| if (host != exploration.host) {
            say("[determinismo] the tape was recorded by another build of determinismo " ++
                "({x:0>16}; this is {x:0>16}): a replay that parts from it may be the build's " ++
                "doing\n", .{ host, exploration.host });
        };
        exploration.exploration_seed = header.exploration_seed;
        exploration.replay = .{ .header = header, .overrides = overrides };
        exploration.fork = header.fork;
        // Extended as another timeline of the run: its number taken here (the run's next), its
        // own from here on (its tape, its events, its line in the record), the parent's seed and
        // ancestors as they are.
        if (arguments.extend) {
            const moment_ms = arguments.moment_vtime_ms orelse return error.Usage;
            // Not with the run's own outputs (--events-dir rewrites its setup's events, --record
            // its record).
            if (arguments.tape_directory != null or arguments.events_directory != null or
                arguments.record_path != null) return error.Usage;
            // Its files in the run the tape is of: <run>/tapes/branch-<parent>.jsonl.
            const tapes = std.fs.path.dirname(path) orelse return error.Usage;
            const run_directory = std.fs.path.dirname(tapes) orelse return error.Usage;
            const before = try lineage_of(context.arena, context.io, tapes, header);
            const lineage = try context.arena.alloc(tape.Segment, before.len + 1);
            @memcpy(lineage[0..before.len], before);
            lineage[before.len] = .{ .branch = header.branch, .seed = header.branch_seed, .vtime_ns = moment_ms * std.time.ns_per_ms, .jitter_seed = header.clock_jitter_seed };
            var own = header;
            own.host = exploration.host;
            own.extends = .{ .branch = header.branch, .vtime_ns = moment_ms * std.time.ns_per_ms };
            const tape_fd = try tape.claim_next(tapes, &own);
            // Said to whoever started it (serve's session: its reply's timeline).
            say("[determinismo] timeline {d}: timeline {d} from {d} ms on, extended\n", .{ own.branch, header.branch, moment_ms });
            exploration.extend = .{
                .extends = own.extends.?,
                .lineage = lineage,
                .events_directory = try std.fs.path.join(context.arena, &.{ run_directory, "events" }),
                .tape_fd = tape_fd,
            };
            exploration.replay.?.header.branch = own.branch;
            exploration.tape_directory = tapes;
            report.declared_seen_open();
            report.record_fd = try open_for_appending(context.arena, try std.fs.path.join(context.arena, &.{ run_directory, "record.jsonl" }), .resumed);
            report.record_branches_only = true;
            // Its line among the run's timelines as it ends: what serve ingests from.
            report.timelines_fd = try open_for_appending(context.arena, try std.fs.path.join(context.arena, &.{ exploration.extend.?.events_directory, "timelines.jsonl" }), .resumed);
        }
    }
    // Draws are noted from a replay only (a live timeline's go beside its events).
    if (arguments.draws_out != null and exploration.replay == null) return error.Usage;
    if (arguments.from_branch) |branch| {
        if (exploration.replay != null) return error.Usage; // The tape says where it forked.
        exploration.fork = .{
            .branch = branch,
            .vtime_ns = arguments.from_vtime_ms.? * 1_000_000,
            .exec = arguments.from_exec,
            .pokes = arguments.from_poke,
        };
    }
    if (arguments.strategy_command != null and exploration.replay != null) {
        return error.ReplayWithStrategy; // Tapes replace plugins.
    }
    const time_start_ns = monotonic_ns();
    options.seed = exploration.exploration_seed;
    const snapshot = try context.arena.create(Snapshot);
    // What the setup reached, when it ran here (not from a snapshot on disk): the tree's first
    // known set (explore_snapshot).
    var setup_behaviors: ?*const std.AutoHashMapUnmanaged(u64, void) = null;
    if (arguments.events_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        options.events_fd = try events_file(context.arena, directory, "setup.jsonl");
        const timelines = try std.fs.path.join(context.arena, &.{ directory, "timelines.jsonl" });
        report.timelines_fd = try open_for_appending(context.arena, timelines, if (arguments.resume_run) .resumed else .fresh);
    }
    if (arguments.from_snapshot) |path| {
        const directory = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(path);
        try snapshot.disk_load(context.arena, context.io, directory, name, options.check_buffer, null);
        if (snapshot.memory_size != options.memory_size) return error.SnapshotMemoryDiffers;
        exploration.exploration_seed = futures_seed(arguments.seed, snapshot);
        options.seed = exploration.exploration_seed;
        // The timeline limit from where the timelines start: a fast VM's snapshot carries the
        // machine's life in its clock (every timeline from an hour-old REPL checkpoint was a
        // hang at its start, 2026-11-11).
        if (options.vtime_limit_ns) |limit_ns| options.vtime_limit_ns = limit_ns + snapshot.tsc / report.tsc_per_ns;
        // --exec once the snapshot's machine is held (a CI shard's command). (Each branch takes
        // its moment from the arguments: a copy given them carries it.)
        if (arguments.exec_at_start) {
            // Its moment: the guest's agent held (explore_here_held, said after its step's end):
            // a time a millisecond on raced the agent's step and took its end for the command's.
            const at_start = try context.arena.create(Arguments);
            at_start.* = arguments.*;
            const held = try context.arena.create(query.Condition);
            held.* = try query.parse(context.arena, "event=explore_here_held");
            at_start.until = held;
            branch_arguments = at_start;
        }
    } else if (arguments.tape_snapshot) |path| {
        // The taped timeline's own state at a moment of it: its seed and tape go on from there.
        const directory = std.fs.path.dirname(path) orelse ".";
        try snapshot.disk_load(context.arena, context.io, directory, std.fs.path.basename(path), options.check_buffer, null);
        if (snapshot.memory_size != options.memory_size) return error.SnapshotMemoryDiffers;
        say("[determinismo] on from {s}: the timeline at {d}ns, not from boot\n", .{
            std.fs.path.basename(path), snapshot.tsc / report.tsc_per_ns,
        });
    } else {
        const collected = try context.arena.create(Events.Collected);
        collected.* = .{ .allocator = context.arena };
        // The setup's named draws (a node's knobs as it first starts, the swarm's seed), shared by
        // every timeline from its snapshot: noted as a timeline's are (draws.zig).
        // The setup's decisions are a strategy's too when it wants them: asked here, recorded on the setup's tape
        // (setup.jsonl, beside the timelines'), which a replay's setup applies (a timeline's
        // pulls count from boot, after the setup's: the two tapes never meet).
        const recording = if (exploration.strategy) |strategy| strategy.wants_setup and exploration.replay == null else false;
        if (recording) try exploration.strategy.?.setup(exploration.exploration_seed);
        const setup_tape: ?linux.fd_t = if (recording) if (exploration.tape_directory) |directory| tape_fd: {
            const fd = try open_for_writing(context.arena, try std.fs.path.join(context.arena, &.{ directory, setup_tape_name }));
            tape.write_header(fd, .{
                .inputs = exploration.inputs,
                .exploration_seed = exploration.exploration_seed,
                .branch = 0,
                .branch_seed = 0,
                .fork = exploration.fork,
                .chain = &.{},
                .host = exploration.host,
                .tsc_jitter_seed = exploration.tsc_jitter_seed,
                .machine = exploration.machine,
            });
            break :tape_fd fd;
        } else null else null;
        defer if (setup_tape) |fd| close(fd);
        const setup_taped: ?*tape.Overrides = if (exploration.replay) |replay|
            try setup_tape_load(context, arguments.tape_path.?, replay.header)
        else
            null;
        var setup_advice: advisor_zig.Explorer = .{
            .strategy = if (recording) exploration.strategy else null,
            .learned = null,
            .draws = if (arguments.events_directory != null) try context.arena.create(draws_zig.Draws) else null,
            .fixed = arguments.decide,
        };
        if (setup_advice.draws) |draws| draws.reset(.first);
        try explore_snapshot(vm, options, snapshot, collected, setup_advice.advisor(), setup_tape, setup_taped);
        if (setup_advice.draws) |draws| try draws_write(context.arena, arguments.events_directory.?, "draws-setup.jsonl", draws);
        setup_behaviors = &collected.set;
    }
    report.snapshot_taken(snapshot, monotonic_ns() - time_start_ns, setup_waited.memory_wait_ns, setup_waited.cpu_wait_ns);
    report.record(.{ .snapshot = .{
        .vtime_ns = snapshot.tsc / report.tsc_per_ns,
        .wall_ns = monotonic_ns() - time_start_ns,
    } });
    if (arguments.events_directory) |directory| {
        close(options.events_fd.?);
        options.events_fd = if (exploration.fork != null and !arguments.setup_only)
            try events_file(context.arena, directory, "fork.jsonl")
        else
            null;
    }
    // Setup mode: the setup ran to setup_complete (explore_snapshot ends the process otherwise),
    // its events are in setup.jsonl; no timeline.
    if (arguments.setup_only) {
        say("[determinismo] setup mode: setup complete at {d:.3}s of virtual time, " ++
            "{d:.1}s of wall time; no timeline (a full run: the same request without " ++
            "--setup-only)\n", .{
            @as(f64, @floatFromInt(snapshot.tsc / report.tsc_per_ns)) / 1e9,
            @as(f64, @floatFromInt(monotonic_ns() - time_start_ns)) / 1e9,
        });
        const multiverse = try context.arena.create(report.Multiverse);
        multiverse.* = .{ .nodes = system_nodes(arguments.system) };
        return multiverse;
    }
    var start = if (exploration.fork) |fork| try explore_fork(context, vm, options, .{
        .from = snapshot,
        .exploration = &exploration,
        .fork = fork,
    }) else snapshot;
    // A tree explorer's branch replays along its path: each ancestor to the moment the next
    // branched from it, snapshotted there as the exploration did.
    if (exploration.replay) |replay| {
        // Ancestors' tapes are beside this one: what a strategy decided in them, replayed.
        const directory = std.fs.path.dirname(arguments.tape_path.?) orelse ".";
        const ancestor = if (replay.header.chain.len > 0)
            try tape.Overrides.create(context.arena)
        else
            undefined;
        // From a snapshot of the branch itself (--tape-snapshot): its ancestors are behind it.
        const chain = if (arguments.tape_snapshot != null) &.{} else replay.header.chain;
        // Its ancestors each on the clock it ran on (the chain's segments say them), the
        // timeline itself on its own (the header's).
        var own_clock = options.*;
        if (replay.header.clock_jitter_seed) |jitter| own_clock.tsc_jitter_seed = jitter;
        var failure: ?node_core.ChainFailure = null;
        start = try node_core.chain(context.arena, vm, options, start, chain, directory, ancestor, &failure);
        // Futures from a moment of the taped branch (`--tape ... --from-vtime-ms`, causality
        // analysis): the branch itself replayed to the moment, then new branches from there,
        // with their own seeds.
        if (arguments.from_vtime_ms) |ms| {
            const own = try tape.Overrides.create(context.arena);
            const recorded = try Recorded.load(context.arena, directory, replay.header.branch, replay.header.branch_seed, own);
            const at = ms * std.time.ns_per_ms;
            const branch_point = replay.header.chain.len > 0;
            start = try node_make(context.arena, vm, &own_clock, start, recorded, at, branch_point);
            exploration.replay = null;
            exploration.exploration_seed = futures_seed(exploration.exploration_seed, start);
        }
    }
    if (arguments.events_directory != null) {
        if (options.events_fd) |fd| close(fd);
        options.events_fd = null; // Each branch writes its own file.
    }
    // A timeline a session extended: its steps, taped at the moments they ran, delivered there
    // again on the way to this replay's moment, none after it (those before the snapshot it
    // starts from are in it already). A moment named by an event (until) is a time by now: serve
    // finds it in the run's events first. Extending it: det:extend where the session takes over.
    // (Each branch takes its moment from the arguments: a copy given them carries it.)
    if (exploration.replay) |replay| if (replay.overrides.step_count > 0 or exploration.extend != null) {
        if (replay.overrides.step_count > 0 and arguments.until != null) return error.UntilWithTapedSteps;
        const moment_ns: ?u64 = if (arguments.moment_vtime_ms) |ms| ms * std.time.ns_per_ms else null;
        const own: ?[]const u8 = if (exploration.extend != null)
            try std.mem.concat(context.arena, u8, &.{ "det:extend\x00", arguments.moment_command orelse VM.step_here })
        else
            arguments.moment_command;
        const start_ns = start.tsc / report.tsc_per_ns;
        const taped = try taped_steps_moment(context.arena, replay.overrides, start_ns, moment_ns, own);
        if (taped != null or exploration.extend != null) {
            const with_steps = try context.arena.create(Arguments);
            with_steps.* = branch_arguments.*;
            if (taped) |steps| {
                with_steps.moment_vtime_ms = steps.moment_ms;
                with_steps.moment_command = steps.commands;
                if (steps.go_on) with_steps.moment_continue = true;
            } else with_steps.moment_command = own;
            // From a snapshot inside its steps (a checkpoint's, a replay's saved there): the
            // guest's agent holds already, as where they began.
            const steps_taped = replay.overrides.steps_taped();
            with_steps.moment_held = arguments.tape_snapshot != null and steps_taped.len > 0 and
                steps_taped[0].vtime_ns < start_ns;
            branch_arguments = with_steps;
        }
    };
    const multiverse = try context.arena.create(report.Multiverse);
    multiverse.* = .{ .nodes = system_nodes(arguments.system) };
    // A resumed run's recorded timelines count in its verdict as its own do (CE29).
    if (exploration.done) |resumed| try resumed.merge_into(multiverse);
    const branches = Branches{
        .snapshot = start,
        .setup = snapshot,
        .setup_behaviors = setup_behaviors,
        .multiverse = multiverse,
        .exploration = &exploration,
        .arguments = branch_arguments,
        .deadline_ns = if (arguments.time_budget_ns) |ns| time_start_ns + ns else null,
        .draws = if (branch_arguments.events_directory != null) try context.arena.create(draws_zig.Draws) else null,
    };
    const jobs = jobs_count(arguments);
    // Where the run's workers spend their time, minute by minute (activity.zig): every process
    // forked after this appends to it.
    if (exploration_is_run(arguments)) if (arguments.run_directory) |directory| {
        activity.open(directory, jobs, activity.ms_of_monotonic(time_start_ns));
    };
    // Timelines replayed from their tapes as the run goes, beside its workers (replays.zig).
    // Not a run with a moment's steps: they are not on its tapes, so a replay without them
    // parts from it wherever they changed something (a trial that filled /run, run 717).
    const moment_steps = arguments.moment_command != null or arguments.moment_script_path != null or
        arguments.moment_interactive;
    // The strategy plugins' connections, closed in the verifier's process.
    var held_buffer: [2 * Strategies.plugins_max]linux.fd_t = undefined;
    const held: []const linux.fd_t = if (exploration.strategy) |strategy| strategy.held(&held_buffer) else &.{};
    const verifier: ?replays.Verifier = if (arguments.record_path != null and
        arguments.tape_directory != null and arguments.verify_percent > 0 and !moment_steps and
        arguments.branch_only == null and arguments.tape_path == null and arguments.raw_argv.len >= 2)
        try replays.Verifier.start(context.arena, context.io, arguments.raw_argv, arguments.record_path.?, arguments.tape_directory.?, arguments.events_directory, arguments.verify_percent, jobs, held)
    else
        null;
    if (arguments.branching == .tree) {
        // A strategy decides within its branches and chooses where the tree returns: an
        // instance here (the setup's, when it decided the setup) and one per worker.
        if (exploration.strategy == null) try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        if (arguments.time_budget_text) |budget| {
            say("[determinismo] a tree for {s} (at most {d} timelines) on {d} workers\n", .{
                budget, arguments.branches, jobs,
            });
        } else {
            say("[determinismo] a tree of {d} timelines on {d} workers\n", .{ arguments.branches, jobs });
        }
        try explore_tree(context, vm, options, branches, jobs);
    } else if (jobs == 1) {
        if (exploration.strategy == null) try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        try explore_branches(context, vm, options, branches);
    } else {
        // The setup's instance ends before the workers fork: each starts its own, and one that
        // kept this one's connection would keep the plugin from seeing its end.
        if (exploration.strategy) |strategy| {
            strategy.stop();
            exploration.strategy = null;
        }
        if (arguments.time_budget_text) |budget| {
            say("[determinismo] branches for {s} (at most {d}) on {d} workers\n", .{
                budget, arguments.branches, jobs,
            });
        } else {
            say("[determinismo] {d} branches on {d} workers\n", .{
                arguments.branches, jobs,
            });
        }
        try explore_parallel(context, vm, options, branches, jobs);
    }
    if (verifier) |*running| {
        const watcher: VerifyStatus = .{ .directory = arguments.run_directory, .multiverse = multiverse };
        const end_ns = if (arguments.time_budget_ns) |ns| time_start_ns + ns + tail_grace_ns(ns) else null;
        const found = try running.finish(context.arena, context.io, watcher, end_ns);
        try multiverse.replays_judge(found.replayed, found.same, found.first_different);
        for (found.different) |line| {
            const rejudged = std.mem.indexOf(u8, line, " rejudged ") != null;
            say("[determinismo] {s}: {s}\n", .{ if (rejudged) "judged anew" else "did not replay", line });
        }
    }
    try multiverse.learned_limit_judge(learned_stopped, learned_cuts, learned_cut_first);
    // What set it, beside its cuts: a slow but sound system told from a hang.
    if (timeline_learner.limit_ns()) |limit| say("[determinismo] learned timeline limit: {d:.1} s past a " ++
        "branch point (twice {d:.1} s, its normal ends' 99th percentile; the longest, timeline {?d}'s, " ++
        "{d:.1} s; {d} normal ends, {d} needed; never under {d:.0} s until {d} of them, {d:.0} s after); " ++
        "{d} of {d} timelines with it cut there\n", .{
        @as(f64, @floatFromInt(limit)) / 1e9,
        @as(f64, @floatFromInt(timeline_learner.kept_longest_ns())) / 1e9,
        timeline_learner.longest_index,
        @as(f64, @floatFromInt(timeline_learner.longest_ns)) / 1e9,
        timeline_learner.ends,
        timeline_learner.min_ends,
        @as(f64, @floatFromInt(timeline_learner.floor_ns)) / 1e9,
        timeline_learner.floor_ends,
        @as(f64, @floatFromInt(timeline_learner.learned_floor_ns)) / 1e9,
        learned_cuts,
        learned_stopped,
    });
    // A resume with nothing left (every timeline recorded, the run stopped before its end, or a
    // scenario's run complete in a chain) is judged from its record: it ended with
    // NoTimelineFinished, and a chain resumed from a complete first scenario never went on.
    const recorded = if (exploration.done) |resumed| resumed.done.count() else 0;
    if (multiverse.branches == 0 and recorded > 0) {
        say("[determinismo] nothing left to explore: its {d} recorded timelines judged from the record\n", .{recorded});
        return multiverse;
    }
    multiverse.summarize(monotonic_ns() - time_start_ns);
    // Not a pass: nothing was judged.
    if (multiverse.branches == 0) return error.NoTimelineFinished;
    return multiverse;
}

const Fork = struct { from: *const Snapshot, exploration: *const Exploration, fork: tape.Fork };

/// Replays branch `fork.branch` of the setup snapshot to the moment and snapshots it there.
fn explore_fork(context: Context, vm: *VM, options: *VM.Options, fork: Fork) !*const Snapshot {
    const time_start_ns = monotonic_ns();
    try moment_after_snapshot(fork.from, fork.fork.vtime_ns);
    options.seed = branch_seed(fork.exploration.exploration_seed, fork.fork.branch);
    options.moment_vtime_ns = fork.fork.vtime_ns;
    options.moment_command = fork.fork.exec;
    const until = options.until;
    options.until = null; // The fork point is the moment; --until belongs to its branches.
    defer options.until = until;
    options.moment_continue = false;
    defer options.moment_vtime_ns = null;
    defer options.moment_command = null;
    own_cpu.take();
    try vm.init_from_snapshot(options, fork.from);
    const outcome = try vm.run_until_exit();
    const expected: VM.Outcome = if (fork.fork.exec != null) .command_done else .moment_reached;
    if (std.meta.activeTag(outcome) != std.meta.activeTag(expected)) {
        say("[determinismo] branch {d} ended ({s}) before {d}ns\n", .{
            fork.fork.branch, @tagName(outcome), fork.fork.vtime_ns,
        });
        vm.deinit();
        return error.ForkPointNotReached;
    }
    if (fork.fork.pokes) |pokes| _ = try pokes_parse(pokes, vm);
    const snapshot = try context.arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    const wall_s = @as(f64, @floatFromInt(monotonic_ns() - time_start_ns)) / std.time.ns_per_s;
    say("[determinismo] forked branch {d} at vtime={d}ns branches={d} " ++
        "({d:.3}s wall); its branches follow\n", .{
        fork.fork.branch,
        fork.fork.vtime_ns,
        snapshot.branches,
        wall_s,
    });
    return snapshot;
}

/// The seed of futures from a moment of a timeline (causality's), replayed to it or saved there
/// (`--from-snapshot`): the same either way, and neither the timeline's own nor another moment's.
fn futures_seed(exploration_seed: u64, at: *const Snapshot) u64 {
    return exploration_seed ^ 0x9e3779b97f4a7c15 ^ at.tsc;
}

/// Branches start at their snapshot: a moment before it would be in the past.
const cpuid_tsc_hz = @import("core").cpuid.tsc_hz;
const node_core = @import("core").node;
const Recorded = node_core.Recorded;
const node_make = node_core.make;
const moment_after_snapshot = node_core.moment_after_snapshot;

fn strategy_start(context: Context, arguments: *const Arguments, exploration: *Exploration) !void {
    const command = arguments.strategy_command orelse return;
    const strategy = try context.arena.create(Strategies);
    const follow: ?Strategies.Follow = if (arguments.strategy_follow) .{
        .io = context.io,
        .data = try runs.data_directory(context.arena, arguments.data_directory),
    } else null;
    try strategy.start(context.arena, command, context.environ, follow);
    try strategy.hello(exploration.exploration_seed, arguments.run_url);
    exploration.strategy = strategy;
    // A run shows the strategy by its own name (serve's strategy_name), not only its command.
    if (arguments.run_directory) |directory| {
        const path = try std.fs.path.join(context.arena, &.{ directory, "strategy-name" });
        std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = strategy.hello_name() }) catch {};
    }
}

/// Workers for the branches: one per CPU this process may run on, unless one branch is asked
/// for or events are logged (one log, one timeline at a time).
fn jobs_count(arguments: *const Arguments) u32 {
    const single = arguments.branch_only != null or arguments.tape_path != null;
    if (single or arguments.events_path != null) return 1;
    const jobs = arguments.jobs orelse cpus_available();
    const shard_branches = @divCeil(arguments.branches, arguments.shard_count);
    return @max(1, @min(jobs, shard_branches, jobs_max));
}

test "a run's strategy in a tree takes its run's tapes" {
    // As serve asks (run 1340): --strategy and --branching tree, no --tape-dir.
    var run: Arguments = .{ .command = .explore, .strategy_command = "tcp://127.0.0.1:9110", .branching = .tree, .branching_given = true };
    try branching_resolve(&run, false);
    try std.testing.expectEqual(.tree, run.branching);
    // Not a run (one branch replayed): its tapes must be named.
    var replay: Arguments = .{ .command = .explore, .strategy_command = "x", .branching = .tree, .branching_given = true, .branch_only = 3 };
    try std.testing.expectError(error.Usage, branching_resolve(&replay, false));
}

/// Tree branching unless something else plans the branches (a strategy, a tape, a fork, one
/// branch, shards, a moment): then flat; asked for a tree, an error.
fn branching_resolve(arguments: *Arguments, at_moment: bool) !void {
    if (arguments.changed != null and arguments.branching != .tree) return changed_needs_tree();
    if (arguments.changed_repository != null and arguments.changed == null) {
        say("[determinismo] --changed-repository says where --changed's range is: " ++
            "give the range too (a commit, a..b, v1.6.0..v1.7.0)\n", .{});
        return error.Usage;
    }
    if (arguments.branching != .tree) return;
    // A strategy in a tree (asked for): its parents are replayed with their tapes. A run's are in
    // its directory (run_register, after this: serve's strategy runs were refused, run 1340).
    if (arguments.branching_given and arguments.strategy_command != null) {
        if (arguments.tape_directory == null and !exploration_is_run(arguments)) {
            say("[determinismo] a strategy in a tree needs --tape-dir: nodes " ++
                "replay their parents' decisions from their tapes\n", .{});
            return error.Usage;
        }
    }
    const strategy_planned = arguments.strategy_command != null and !arguments.branching_given;
    const planned = strategy_planned or arguments.branch_only != null or
        arguments.tape_path != null or arguments.from_branch != null or
        arguments.from_snapshot != null or arguments.shard_count > 1 or at_moment;
    if (planned and arguments.branching_given) return error.Usage;
    // A tree's first generation starts from the snapshot, as flat branches do; later ones start
    // inside others and replay from their tapes only. With its tape given, the tape says where
    // it starts (extract --branch 18 --tape branch-18.jsonl was refused: run 730, 2026-11-03).
    if (arguments.branch_only) |only| {
        if (!arguments.branching_given and only >= arguments.generation_size and arguments.tape_path == null) {
            say("[determinismo] branch {d} of a tree exploration (the default) " ++
                "starts from a moment of another: replay it from its tape (--tape " ++
                "<tape dir>/branch-{d}.jsonl), or explore with --branching flat\n", .{
                only, only,
            });
            return error.Usage;
        }
    }
    if (planned and arguments.changed != null) return changed_needs_tree();
    if (planned) arguments.branching = .flat;
}

const retroactive_max = 16;

/// The texts retroactive logging hides, the profile's (`Profile.retroactive`) and explore's
/// (`--retroactive`): none when looking at one timeline (a replay, a moment, a tape), which
/// writes everything.
fn retroactive_texts(
    arena: std.mem.Allocator,
    arguments: *const Arguments,
    profile: []const []const u8,
) ![]const []const u8 {
    const one = arguments.branch_only != null or arguments.tape_path != null or
        arguments.moment_vtime_ms != null or arguments.until != null;
    if (one) return &.{};
    // And Antithesis's retroactive sink (ANTITHESIS_FILTERED_OUTPUT_DIR: det-sinks names its
    // lines' stream "filtered <file>"), whatever was asked.
    const asked = arguments.retroactive[0..arguments.retroactive_count];
    const texts = try arena.alloc([]const u8, profile.len + asked.len + 1);
    @memcpy(texts[0..profile.len], profile);
    @memcpy(texts[profile.len..][0..asked.len], asked);
    texts[profile.len + asked.len] = filtered_stream_text;
    return texts;
}

const filtered_stream_text = "\"stream\":\"filtered ";

fn changed_needs_tree() error{Usage} {
    say("[determinismo] --changed aims the tree explorer: not with flat branching, " ++
        "a strategy's plan, shards or a replay\n", .{});
    return error.Usage;
}

/// Unix seconds, or a date (`YYYY-MM-DD`, its midnight UTC).
fn epoch_parse(text: []const u8) !u64 {
    if (std.fmt.parseInt(u64, text, 10)) |seconds| return seconds else |_| {}
    return prepare.date_seconds(text) orelse error.Usage;
}

test epoch_parse {
    try std.testing.expectEqual(VM.epoch_seconds_default, try epoch_parse("2026-01-01"));
    try std.testing.expectEqual(42, try epoch_parse("42"));
    try std.testing.expectError(error.Usage, epoch_parse("2026-13-01"));
}

/// A duration: a number of seconds, or with a unit (`500ms`, `90s`, `10m`, `2h`).
pub fn duration_parse(text: []const u8) !u64 {
    const units = [_]struct { suffix: []const u8, ns: u64 }{
        .{ .suffix = "ms", .ns = std.time.ns_per_ms },
        .{ .suffix = "s", .ns = std.time.ns_per_s },
        .{ .suffix = "m", .ns = std.time.ns_per_min },
        .{ .suffix = "h", .ns = std.time.ns_per_hour },
    };
    for (units) |unit| {
        if (!std.mem.endsWith(u8, text, unit.suffix)) continue;
        const number = text[0 .. text.len - unit.suffix.len];
        // "10ms" also ends in "s": the longer suffix is tried first.
        if (number.len > 0 and std.ascii.isDigit(number[number.len - 1])) {
            return try std.math.mul(u64, try std.fmt.parseInt(u64, number, 10), unit.ns);
        }
    }
    return try std.math.mul(u64, try std.fmt.parseInt(u64, text, 10), std.time.ns_per_s);
}

test duration_parse {
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), try duration_parse("500ms"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90s"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90"));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_min), try duration_parse("10m"));
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try duration_parse("2h"));
    try std.testing.expectError(error.InvalidCharacter, duration_parse("ten"));
}

/// The CPUs VMs may run on here: one thread per core (cpus.zig).
fn cpus_available() u32 {
    return cpus.usable_count();
}

/// Forks `jobs` workers after the snapshot: each makes its own VMs from it (copy-on-write) and
/// runs the next branch not yet taken until none is left, then sends its results through a
/// pipe. A branch's timeline does not depend on which worker runs it.
fn explore_parallel(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    assert(jobs > 1 and jobs <= jobs_max);
    own_cpu.give(); // The workers take their own.
    // The workers' shared counter of positions (branch_place).
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const shared_flags: linux.MAP = .{ .TYPE = .SHARED, .ANONYMOUS = true };
    const shared = linux.mmap(null, std.heap.page_size_min, protection, shared_flags, -1, 0);
    if (linux.errno(shared) != .SUCCESS) return error.Mmap;
    defer _ = linux.munmap(@ptrFromInt(shared), std.heap.page_size_min);
    const counter: *std.atomic.Value(u32) = @ptrFromInt(shared);
    counter.* = .init(0);
    var shared_branches = branches;
    shared_branches.next = counter;
    var readers: [jobs_max]linux.fd_t = undefined;
    var pids: [jobs_max]linux.pid_t = undefined;
    const explorer = linux.getpid();
    for (0..jobs) |worker| {
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            child_dies_with(explorer);
            _ = linux.close(pipe[0]);
            worker_run(context, vm, options, shared_branches, .{
                .worker = @intCast(worker),
                .jobs = jobs,
                .results_fd = pipe[1],
            });
        }
        _ = linux.close(pipe[1]);
        readers[worker] = pipe[0];
        pids[worker] = @intCast(pid);
    }
    const results = try context.arena.create(report.Multiverse);
    for (readers[0..jobs], pids[0..jobs]) |reader, pid| {
        var received = read_exact(reader, std.mem.asBytes(results));
        // Then a tree generation's summaries: their count, and each.
        if (branches.summaries) |summaries| {
            var count: u32 = 0;
            received = received and read_exact(reader, std.mem.asBytes(&count));
            received = received and summaries.count + count <= summaries.items.len;
            if (received) {
                const into = summaries.items[summaries.count..][0..count];
                received = read_exact(reader, std.mem.sliceAsBytes(into));
                summaries.count += count;
            }
        }
        _ = linux.close(reader);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        if (!received or status != 0) return error.WorkerFailed;
        try branches.multiverse.absorb(results);
    }
}

const Worker = struct { worker: u32, jobs: u32, results_fd: linux.fd_t };

fn worker_run(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    worker: Worker,
) noreturn {
    // The host's CPUs, shared with every other run's workers: one per timeline (cpus.zig).
    var pool: cpus.Pool = undefined;
    pool.open() catch |err| {
        say("[determinismo] worker {d}: the CPU pool: {s}\n", .{
            worker.worker, @errorName(err),
        });
        linux.exit_group(1);
    };
    var exploration = branches.exploration.*;
    // The explorer's plugin stays the explorer's: this process starts its own (worker_explore),
    // and the explorer's pipes kept here (and in this process's holders) would keep that plugin
    // from seeing the end of its input when the explorer stops it.
    if (exploration.strategy) |explorer_strategy| explorer_strategy.forget();
    var mine = branches;
    mine.exploration = &exploration;
    mine.worker = worker.worker;
    mine.jobs = worker.jobs;
    mine.pool = &pool;
    mine.multiverse.* = .{};
    var summaries: Summaries = undefined;
    if (branches.summaries) |all| {
        summaries = .{ .items = all.items };
        mine.summaries = &summaries;
    }
    const ok = worker_explore(context, vm, options, mine, &exploration);
    if (ok) write_all(worker.results_fd, std.mem.asBytes(mine.multiverse));
    if (ok and branches.summaries != null) {
        write_all(worker.results_fd, std.mem.asBytes(&summaries.count));
        write_all(worker.results_fd, std.mem.sliceAsBytes(summaries.items[0..summaries.count]));
    }
    linux.exit_group(if (ok) 0 else 1);
}

fn worker_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    exploration: *Exploration,
) bool {
    strategy_start(context, branches.arguments, exploration) catch return false;
    defer if (exploration.strategy) |strategy| strategy.stop();
    explore_branches(context, vm, options, branches) catch |err| {
        say("[determinismo] worker {d}: {s}\n", .{ branches.worker, @errorName(err) });
        return false;
    };
    return true;
}

fn read_exact(fd: linux.fd_t, target: []u8) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const result = linux.read(fd, target[done..].ptr, target.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return false;
        done += result;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        done += result;
    }
}

/// The setup run to its snapshot; every behavior it reached into `collected` (the tree's first
/// known set: Events.behaviors_collected).
/// The setup's own tape beside the timelines': what a strategy decided before the snapshot.
const setup_tape_name = "setup.jsonl";

/// A replay's setup tape (beside its timeline's, from the same exploration), if the run had one:
/// what a strategy decided in the setup, applied as the setup runs again.
fn setup_tape_load(context: Context, tape_path: []const u8, header: tape.Header) !?*tape.Overrides {
    const directory = std.fs.path.dirname(tape_path) orelse ".";
    const path = try std.fs.path.join(context.arena, &.{ directory, setup_tape_name });
    const source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const overrides = try tape.Overrides.create(context.arena);
    const setup_header = try tape.parse(source, try context.arena.alloc(u8, 64 * 1024), overrides);
    if (setup_header.inputs != header.inputs or setup_header.exploration_seed != header.exploration_seed) {
        say("[determinismo] {s} is another exploration's setup (inputs {x:0>16}, seed {x:0>16})\n", .{
            path, setup_header.inputs, setup_header.exploration_seed,
        });
        return error.SetupTapeDiffers;
    }
    return overrides;
}

fn explore_snapshot(
    vm: *VM,
    options: *VM.Options,
    snapshot: *Snapshot,
    collected: *Events.Collected,
    advisor: ?VM.Advisor,
    /// Where the setup's answers are taped (a strategy decided them), or null.
    tape_fd: ?linux.fd_t,
    /// A replay's setup tape, applied as the setup runs again, or null.
    taped: ?*tape.Overrides,
) !void {
    Events.behaviors_collected = collected;
    defer Events.behaviors_collected = null;
    options.stop_at_setup_complete = true;
    defer options.stop_at_setup_complete = false;
    // Moments belong to branches: none during the run to the snapshot.
    const moment_vtime_ns = options.moment_vtime_ns;
    const moment_command = options.moment_command;
    const until = options.until;
    options.moment_vtime_ns = null;
    options.moment_command = null;
    options.until = null;
    defer options.moment_vtime_ns = moment_vtime_ns;
    defer options.moment_command = moment_command;
    defer options.until = until;
    own_cpu.take();
    if (own_cpu.held) |held| setup_waited = held;
    // The setup's virtual time, said every half minute by a thread of its own: the explorer runs
    // the setup's VM itself, and a long one said nothing (31 minutes once, 2026-11-06).
    var watch: SetupWatch = .{ .start_ns = monotonic_ns() };
    options.progress = &watch.vtime_ns;
    defer options.progress = null;
    const watcher = std.Thread.spawn(.{}, SetupWatch.run, .{&watch}) catch null;
    defer if (watcher) |thread| {
        watch.done.store(true, .release);
        thread.join();
    };
    try vm.init(options);
    // After the machine's init, which starts it with none.
    vm.advisor = advisor;
    vm.tape_attach(tape_fd);
    vm.overrides = taped;
    const outcome = try vm.run_until_exit();
    vm.advisor = null;
    vm.tape_attach(null);
    vm.overrides = null;
    if (outcome != .setup_complete) {
        say("[determinismo] the guest never signalled setup_complete ({s})\n", .{
            @tagName(outcome),
        });
        std.process.exit(1);
    }
    setup_draws_say(&vm.setup_draws);
    try snapshot.take(vm);
    vm.deinit();
    assert(snapshot.branches > 0);
}

/// The named decisions the setup drew: made before the timelines part, each is one value for every
/// timeline of the run (a random schema, a size, a workaround's coin: PostgreSQL's internal-sim,
/// 2026-11-08), said so that the workload draws them where timelines differ (a first command, each
/// start). A node's start draw (`node.start_draw`) is each start's own.
fn setup_draws_say(draws: *const VM.SetupDraws) void {
    var said: u32 = 0;
    for (0..draws.count) |index| {
        const name = draws.name(index);
        if (std.mem.eql(u8, name, "node.start_draw")) continue;
        if (said == 0) say("[determinismo] the setup drew, one value for every timeline of the run:", .{});
        say("{s} {s}", .{ if (said == 0) "" else ",", name });
        said += 1;
    }
    if (said == 0) return;
    if (draws.dropped > 0) say(" (and {d} more)", .{draws.dropped});
    say(" (a first command, or each start, draws per timeline)\n", .{});
}

/// The setup's progress line (explore_snapshot): its VM's virtual time (VM.progress), printed
/// every progress_interval_ms until it is done.
const SetupWatch = struct {
    vtime_ns: u64 = 0,
    start_ns: u64,
    done: std.atomic.Value(bool) = .init(false),

    fn run(watch: *SetupWatch) void {
        var waited_ms: u64 = 0;
        while (!watch.done.load(.acquire)) {
            const pause: linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&pause, null);
            waited_ms += std.time.ms_per_s;
            if (waited_ms % progress_interval_ms != 0) continue;
            say("[determinismo] setup at {d}s of virtual time, {d}s of wall time\n", .{
                @atomicLoad(u64, &watch.vtime_ns, .monotonic) / std.time.ns_per_s,
                (monotonic_ns() - watch.start_ns) / std.time.ns_per_s,
            });
        }
    }
};

const Branches = struct {
    snapshot: *const Snapshot,
    /// The setup snapshot (`snapshot` is a later one when branching from a moment): the base of
    /// snapshots saved to disk (saver.zig).
    setup: ?*const Snapshot = null,
    /// Every behavior the setup reached (explore_snapshot), when it ran here: a tree knows them
    /// before its first generation. Null: a snapshot loaded from disk.
    setup_behaviors: ?*const std.AutoHashMapUnmanaged(u64, void) = null,
    /// The setup snapshot written among the disk holders (holders.setup_origin), once its writer
    /// is done: a root's first disk holder saves against it, a diff, not the whole guest.
    setup_disk_origin: ?holders.Origin = null,
    multiverse: *report.Multiverse,
    exploration: *const Exploration,
    arguments: *const Arguments,
    /// No branch starts after this (monotonic_ns): the time budget.
    deadline_ns: ?u64 = null,
    /// The driver phase's length bucket the tree chose for this timeline (Novelty), if any.
    drive_k: ?u8 = null,
    /// The tree returned it to an objective's best: it drives one more phase when its composer
    /// asks (advisor.zig's again_left).
    again: bool = false,
    /// The tree's bandit over configuration draws, as this timeline forks with it.
    bandit: ?*const bandit_zig.Bandit = null,
    /// Where a live timeline's named draws are noted (draws.zig), written beside its events:
    /// reserved once, each process its own copy. Null: no events directory, nothing to read them.
    draws: ?*draws_zig.Draws = null,
    /// A worker's: each timeline runs on a CPU taken from it (and given back after).
    pool: ?*cpus.Pool = null,
    /// The tree explorer's generation: which branches run, and where each starts. Null: the
    /// branches `0..arguments.branches`, all from `snapshot`.
    plan: ?[]const Planned = null,
    /// Where the branches of a plan tell how they went (behaviors, for the next generation).
    summaries: ?*Summaries = null,
    /// This process runs the branches whose index modulo `jobs` is `worker`; or, with `next`,
    /// whichever comes next.
    worker: u32 = 0,
    jobs: u32 = 1,
    /// The tree's in-run snapshots (holders.zig): the explorer that names them, and the
    /// behaviors the tree knew before this generation. Null: none (no tree, or a strategy, or
    /// CPU modulation).
    holders: ?linux.pid_t = null,
    seen: ?*const std.AutoHashMapUnmanaged(u64, void) = null,
    /// The system's last runs' behaviors (--history): known too where a table decides what it
    /// keeps (Events.behaviors_history), never in what the tree counts new.
    history: ?*const std.AutoHashMapUnmanaged(u64, u32) = null,
    /// Where its holders write themselves when it fails (Ladders).
    ladder: ?*const holders.Ladder = null,
    /// Where its holders go while memory runs low.
    holders_disk: ?*const holders.Disk = null,
    /// Where the run's timelines end, on average so far (virtual time): its holders' spacing
    /// when neither a horizon nor `--timeline` says how long it runs.
    end_ns_expected: ?u64 = null,
    /// Shared by parallel workers (memory mapped before they fork): the next position to run.
    /// A timeline is the same whichever worker runs it, so a worker that finished takes the
    /// next instead of idling while others run long ones.
    next: ?*std.atomic.Value(u32) = null,
};

const jobs_max = 256;

fn explore_branches(context: Context, vm: *VM, options: *VM.Options, branches: Branches) !void {
    const exploration = branches.exploration;
    const replay_branch = if (exploration.replay) |replay| replay.header.branch else null;
    const first = replay_branch orelse branches.arguments.branch_only orelse 0;
    const single = replay_branch != null or branches.arguments.branch_only != null;
    const count = if (single) 1 else branches.arguments.branches;
    if (branches.arguments.moment_vtime_ms) |ms| {
        try moment_after_snapshot(branches.snapshot, ms * std.time.ns_per_ms);
    }
    const total = if (branches.plan) |plan| plan.len else count;
    // A holder's capture (one at a time: each holder keeps its own copy, forked).
    const capture = if (branches.holders != null) try context.arena.create(Snapshot) else undefined;
    var maker = HolderMaker{
        .arena = context.arena,
        .options = options,
        .tape_directory = exploration.tape_directory,
        .buffer = if (branches.holders != null) try tape.Overrides.create(context.arena) else undefined,
    };
    var position_next: usize = 0;
    while (true) {
        const position: usize = if (branches.next) |counter|
            counter.fetchAdd(1, .monotonic)
        else
            position_next;
        position_next += 1;
        if (position >= total) break;
        var place = branch_place(branches, first + position, single, position) orelse continue;
        const index = place.index;
        // Where it stops: its horizon, a replay's (the horizon it was cut at), else the run's
        // learned limit past its branch point, so a timeline a crash left hanging ends cut short
        // there, not as hung at the explicit limit. The learned one is not its horizon: its
        // holders stay spaced over the timelines' usual length.
        const stop_ns = place.horizon_ns orelse branches.arguments.stop_ns orelse learned_stop(place);
        const stop_learned = place.horizon_ns == null and branches.arguments.stop_ns == null and stop_ns != null;
        maker.index = index;
        if (exploration.done) |resumed| {
            if (resumed.done.contains(index)) continue;
        }
        // A flat run's number, its own as it is taken (a tree's: as planned, index_settle): one
        // a timeline extending another took meanwhile is passed over.
        if (branches.plan == null and !single) if (exploration.tape_directory) |directory| {
            if (!tape.claim(directory, index)) continue;
        };
        if (past_deadline(branches)) break;
        wait_deadline_ns = branches.deadline_ns;
        const held = if (branches.pool) |pool| (pool.take_unless(wait_over) orelse break) else null;
        defer if (held) |cpu| branches.pool.?.give(cpu);
        if (held != null) if (timeline_admission) |admitted| @atomicStore(u64, admitted, 1, .monotonic);
        // Its strategy hears it start first, and may give it another seed (another random
        // future) and, from the setup snapshot, its own clock, which its tape's header then
        // says (a replay takes them from there).
        if (exploration.strategy) |strategy| {
            const from: ?Strategy.From = if (place.path.len == 0) null else .{
                .branch = place.path[place.path.len - 1].branch,
                .vtime_ns = place.path[place.path.len - 1].vtime_ns,
            };
            // A followed plugin's new bytes, from this timeline on (strategies.zig).
            _ = try strategy.refresh(context.arena);
            const choice = try strategy.branch(place.index, place.seed, from);
            if (choice.seed) |seed| place.seed = seed;
            if (choice.jitter_seed) |jitter| place.jitter_seed = jitter;
            if (choice.margin_branches) |margin| place.margin_branches = margin;
        }
        // Its clock: its own (Planned.jitter_seed) for its VM alone, the run's for the rest.
        const jitter_run = options.tsc_jitter_seed;
        defer options.tsc_jitter_seed = jitter_run;
        if (place.jitter_seed) |jitter| options.tsc_jitter_seed = jitter;
        // And its stepper (Planned.margin_branches): a speed choice, the guest's events alike.
        const margin_run = options.margin_branches;
        defer options.margin_branches = margin_run;
        if (place.margin_branches) |margin| options.margin_branches = margin;
        options.seed = place.seed;
        Events.ranges_salt = place.seed; // Its own draw over the range buckets (events.zig).
        const moment_ms = branches.arguments.moment_vtime_ms;
        options.moment_vtime_ns = if (moment_ms) |ms| ms * std.time.ns_per_ms else stop_ns;
        options.moment_command = try timeline_substituted(context.arena, branches.arguments.moment_command, index);
        options.moment_continue = branches.arguments.moment_continue;
        options.moment_held = branches.arguments.moment_held;
        options.steps_fd = if (branches.arguments.moment_interactive) 0 else null;
        options.steps_live = branches.arguments.moment_live;
        options.fork_index = if (branches.arguments.fork_futures) index + 1 else 0;
        if (branches.arguments.moment_live) {
            // Looked at as the guest runs, never waited on.
            const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
            _ = linux.fcntl(0, linux.F.SETFL, linux.fcntl(0, linux.F.GETFL, 0) | nonblock);
        }
        options.fresh_seed = branches.arguments.fresh_seed;
        options.until = branches.arguments.until;
        // Saving to disk: the replay goes just past the last moment saved.
        const save_at_ms = branches.arguments.save_at_ms;
        if (save_at_ms.len > 0) {
            const last_ns = (std.mem.max(u64, save_at_ms) + 1) * std.time.ns_per_ms;
            options.moment_vtime_ns = @min(options.moment_vtime_ns orelse last_ns, last_ns);
        }
        if (branches.arguments.rewind_ms) |ms| {
            try rewind(vm, options, branches.snapshot, exploration, ms * std.time.ns_per_ms);
        }
        if (branches.pool == null) own_cpu.take(); // In this process: its own CPU.
        // From a node (a moment of another timeline): a branch point. Not for causality's
        // futures from a moment (--from-vtime-ms): how likely a failure is from there, not
        // after a fault drawn there.
        // On from a snapshot of the timeline itself (--tape-snapshot): it goes on as its replay
        // did there, a hold point (VM.Options.from_hold), never a branch point.
        const resumed = branches.arguments.tape_snapshot;
        options.branch_signal = place.path.len > 0 and branches.arguments.from_vtime_ms == null and
            resumed == null;
        defer options.branch_signal = false;
        if (resumed) |path| {
            const idle = try Snapshot.disk_idle(std.fs.path.dirname(path) orelse ".", std.fs.path.basename(path));
            options.from_hold = .{ .idle = idle };
        }
        defer options.from_hold = null;
        // Its strategy judges it at its end too, when it wants (after the program's checks).
        var strategy_check: StrategyCheck = undefined;
        const end_checks_own = options.end_checks;
        if (exploration.strategy) |strategy| if (strategy.wants_check) {
            strategy_check = .{ .inner = end_checks_own, .strategy = strategy, .index = place.index };
            options.end_checks = strategy_check.hook();
        };
        try vm.init_from_snapshot(options, place.snapshot);
        options.end_checks = end_checks_own;
        defer vm.deinit();
        // A timeline extending another (a session's): its lineage the parent's and the parent up
        // to the moment, its events its own from there on, in the run's events.
        const lineage = if (exploration.extend) |extend| extend.lineage else place.path;
        const events_directory = branches.arguments.events_directory orelse
            if (exploration.extend) |extend| extend.events_directory else null;
        if (events_directory) |directory| {
            const name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{index});
            vm.events.log_fd = try events_file(context.arena, directory, name);
            vm.check_keep = try std.fmt.allocPrint(context.arena, "{s}/branch-{d}", .{ directory, index });
            // A tree's timeline begins inside its ancestors: queries assemble it (query.zig).
            if (lineage.len > 0) {
                const header = try std.fmt.allocPrint(context.arena, "{f}\n", .{
                    std.json.fmt(.{ .path = lineage }, .{}),
                });
                _ = linux.write(vm.events.log_fd.?, header.ptr, header.len);
            }
            if (exploration.extend) |extend| vm.events.log_from_ns = extend.extends.vtime_ns;
        }
        defer if (vm.events.log_fd) |fd| close(fd);
        var owner: holders.Owner = undefined;
        Events.behaviors_seen = branches.seen;
        Events.behaviors_history = branches.history;
        // Its snapshot's table (the setup's, full in a JVM system) past half of it: what the tree
        // knows goes, room for what this timeline reaches (Events.known_forget).
        if (branches.seen) |known| vm.events.known_forget(known);
        Events.ranges_on = branches.arguments.ranges;
        Events.memory_objective_on = branches.arguments.memory_objective;
        if (branches.holders) |explorer| {
            owner = .{
                .explorer = explorer,
                .worker = linux.getpid(),
                .seen = branches.seen.?,
                .branch = index,
                .seed = place.seed,
                .start_ns = place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s),
                // Spread over the branch: a short one keeps holders up to its horizon, where the
                // tree extends it.
                .spacing_ns = holders.Owner.spacing(if (place.horizon_ns) |horizon|
                    horizon -| place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s)
                else if (branches.arguments.timeline_ms) |ms|
                    ms * std.time.ns_per_ms
                else if (branches.end_ns_expected) |end|
                    end -| place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s)
                else
                    null),
                .snapshot = capture,
                .make = .{ .context = &maker, .function = HolderMaker.make },
                .ladder = branches.ladder,
                .disk = branches.holders_disk,
                .disk_always = branches.arguments.holders_on_disk,
                .disk_sync_always = branches.arguments.holders_on_disk_sync,
                .leave_always = branches.arguments.holders_leave,
                .disk_origin = place.disk_origin orelse holder_origin(branches.setup, branches.setup_disk_origin, place.snapshot, place.path.len),
            };
            try owner.attach(vm);
        }
        var saver: saver_zig.Saver = undefined;
        if (branches.arguments.save_directory) |directory| {
            assert(branches.holders == null); // One hold owner: a replayed branch has none.
            const setup = branches.setup.?;
            var hasher = std.hash.Wyhash.init(0);
            for ([_]u64{ exploration.inputs, exploration.exploration_seed, setup.tsc, setup.branches }) |value| {
                hasher.update(std.mem.asBytes(&value));
            }
            // On from a saved snapshot: the next saved against it (where it is, else written whole).
            const setup_name = if (resumed) |path|
                std.fs.path.basename(path)
            else
                try std.fmt.allocPrint(context.arena, "setup-{x:0>16}", .{hasher.final()});
            try std.Io.Dir.cwd().createDirPath(context.io, directory);
            saver = try saver_zig.Saver.init(context.arena, directory, index, save_at_ms, setup, setup_name);
            saver.unpin = cpus.unpin;
            try saver.attach(vm, place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s));
        }
        var forker: saver_zig.Saver = undefined;
        if (branches.arguments.fork_directory) |directory| {
            assert(branches.holders == null and branches.arguments.save_directory == null);
            try std.Io.Dir.cwd().createDirPath(context.io, directory);
            forker = try saver_zig.Saver.init_forks(context.arena, directory, index, options.memory_size);
            forker.unpin = cpus.unpin;
            vm.fork_hook = .{ .context = &forker, .request = saver_zig.Saver.fork_request };
        }
        defer if (branches.arguments.fork_directory != null) forker.finish() catch {};
        var checkpointer: saver_zig.Saver = undefined;
        if (branches.arguments.checkpoint_directory) |directory| {
            assert(branches.holders == null and branches.arguments.save_directory == null);
            try std.Io.Dir.cwd().createDirPath(context.io, directory);
            checkpointer = try saver_zig.Saver.init_checkpoints(context.arena, directory, index, options.memory_size);
            checkpointer.unpin = cpus.unpin;
            vm.checkpoint_hook = .{ .context = &checkpointer, .save = saver_zig.Saver.checkpoint_save };
        }
        // Its last checkpoint written before the session's explore ends (serve's end of it
        // waits for its output's end, so a session opened after starts from it).
        defer if (branches.arguments.checkpoint_directory != null) checkpointer.finish() catch {};
        vm.serve_url = branches.arguments.serve_url;
        vm.serve_call = serve_call.call;
        vm.egress_allow = branches.arguments.egress_allow;
        vm.egress_io = context.io;
        vm.ingress_listen = branches.arguments.ingress_listen;
        // The explorer's advice on the timeline's pulls (advisor.zig: its strategy, its bandit).
        // Its named draws noted as answered (draws.zig), unless it replays: nothing is asked then.
        var advice: advisor_zig.Explorer = .{
            .strategy = exploration.strategy,
            .learned = branches.bandit,
            .draws = if (exploration.replay == null) branches.draws else null,
            .fixed = branches.arguments.decide,
            .again_asked = exploration.replay == null and objective_extends(branches.arguments),
            .again_left = @intFromBool(branches.again),
        };
        if (advice.draws) |draws| draws.reset(.first);
        vm.advisor = advice.advisor();
        // A replay's draws as the tape answered them (--draws-out): noted, never answered.
        const replay_draws: ?*draws_zig.Draws = if (exploration.replay != null) if (branches.arguments.draws_out != null)
            try context.arena.create(draws_zig.Draws)
        else
            null else null;
        if (replay_draws) |draws| {
            draws.reset(.last);
            vm.pull_note = .{ .context = draws, .pull = replay_draw_note, .event = replay_event_note };
        }
        vm.drive_k = branches.drive_k;
        if (exploration.replay) |replay| {
            vm.overrides = replay.overrides;
            // From inside the timeline: its tape from the snapshot's pull on.
            if (resumed != null) replay.overrides.seek_inside(vm.decisions.pulls);
        }
        try branch_announce(context, vm, exploration, place);
        defer if (vm.tape_fd) |fd| close(fd);
        if (exploration.extend != null) {
            // Its own tape from what the parent's gave this machine before it began (and the
            // parent's steps before the snapshot it started from), then all it is given.
            vm.tape_extend_begin();
            const taped = exploration.replay.?.overrides;
            const start_ns = place.snapshot.tsc / report.tsc_per_ns;
            for (taped.steps_taped()) |step| {
                if (step.vtime_ns >= start_ns) break;
                tape.write_step(vm.tape_fd.?, taped.step_of(step), step.vtime_ns);
                // Counted as the timeline's own: its steps' cap is its tape's (CE52).
                vm.tape_steps += 1;
                vm.tape_step_bytes += step.size;
            }
        }
        const time_start_ns = monotonic_ns();
        const idle_start_tsc = vm.stats.idle_tsc;
        const outcome = try vm.run_until_exit();
        // Its last holder on disk complete before the explorer may load it.
        if (branches.holders != null) owner.disk_wait();
        // Its events compressed before the explorer hears it ended (its summary, its line in
        // the record): what reads an ended timeline's events reads them so (event_files.zig).
        if (events_directory) |directory| {
            close(vm.events.log_fd.?);
            vm.events.log_fd = null;
            try event_files.compress(directory, index);
        }
        if (branches.arguments.save_directory != null) try saver.finish();
        if (replay_draws) |draws| {
            const fd = try open_for_writing(context.arena, branches.arguments.draws_out.?);
            defer close(fd);
            draws.write(fd);
        }
        // Its draws on disk before its line in the record: serve ingests them with its events.
        if (advice.draws) |draws| if (events_directory) |directory| {
            try draws_write(context.arena, directory, try std.fmt.allocPrint(context.arena, "draws-{d}.jsonl", .{index}), draws);
        };
        // A tree timeline's summary on disk before its line in the record: killed between the
        // two, the resumed run runs it again (once), never takes it as recorded without one.
        if (branches.summaries) |summaries| {
            var stopped = place; // Cut at its stop: a learned one as a horizon would be.
            stopped.horizon_ns = stop_ns;
            summaries.note(vm, stopped, outcome, if (branches.holders != null) owner.holders() else &.{}, advice.uses[0..advice.use_count], advice.again_ns);
            const noted = &summaries.items[summaries.count - 1];
            noted.learned_stop = stop_learned;
            noted.learned_cut = stop_learned and outcome == .moment_reached;
            if (tree_summaries_fd) |fd| summary_write(fd, &summaries.items[summaries.count - 1]);
        }
        const vtime_before_ns = branches.multiverse.vtime_ns;
        try branches.multiverse.add(vm, .{
            .index = index,
            .seed = options.seed,
            .outcome = outcome,
            .wall_ns = monotonic_ns() - time_start_ns,
            .start_tsc = place.snapshot.tsc,
            .start_idle_tsc = idle_start_tsc,
            .path = lineage,
            .extends = if (exploration.extend) |extend| extend.extends else null,
            .generation = place.generation,
            .horizon_ns = stop_ns,
            .learned_stop = stop_learned,
            .why = if (exploration.extend) |extend| try std.fmt.allocPrint(context.arena, "A session's: timeline {d} up to {d:.3} s, its own from there (its steps, what came from outside).", .{
                extend.extends.branch, @as(f64, @floatFromInt(extend.extends.vtime_ns)) / 1e9,
            }) else place.why,
            .memory_wait_ns = if (held) |cpu| cpu.memory_wait_ns else 0,
            .cpu_wait_ns = if (held) |cpu| cpu.cpu_wait_ns else 0,
        });
        // A flat run's timeline in the run's activity, from its worker (a tree's: the explorer
        // writes it as the timeline's results arrive). Without it a flat run's timelines per
        // hour, virtual hours per hour and workers by activity were empty (clj-orders' runs).
        if (branches.summaries == null) activity.interval(.timeline, activity.ms_of_monotonic(time_start_ns), activity.now_ms(), .{
            .vtime_ns = branches.multiverse.vtime_ns - vtime_before_ns,
            .wait_ns = if (held) |cpu| cpu.cpu_wait_ns + cpu.memory_wait_ns else 0,
            .index = index,
        });
        if (exploration.strategy) |strategy| {
            const end = BranchResult{ .index = index, .outcome = outcome };
            if (try strategy_branch_end(strategy, vm, end)) break;
        }
    }
}

/// Tells the strategy a branch starts (and where), and opens its tape.
fn branch_announce(
    context: Context,
    vm: *VM,
    exploration: *const Exploration,
    place: Planned,
) !void {
    if (exploration.extend) |extend| {
        vm.tape_attach(extend.tape_fd); // Its header there since its number was taken.
    } else if (exploration.tape_directory) |directory| {
        vm.tape_attach(try open_tape(context.arena, directory, place.index));
        tape.write_header(vm.tape_fd.?, .{
            .inputs = exploration.inputs,
            .exploration_seed = exploration.exploration_seed,
            .branch = place.index,
            .branch_seed = place.seed,
            .clock_jitter_seed = place.jitter_seed,
            .fork = exploration.fork,
            .chain = place.path,
            .host = exploration.host,
            .tsc_jitter_seed = exploration.tsc_jitter_seed,
            .machine = exploration.machine,
            .strategy = if (exploration.strategy) |strategy| strategy.commands else null,
            .margin_branches = place.margin_branches,
        });
    }
}

/// Where the branch at `position` starts, if this worker (and shard) runs it: the snapshot, or
/// (a tree explorer's branch) a moment of another.
fn branch_place(branches: Branches, index_flat: usize, single: bool, position: usize) ?Planned {
    const mine = branches.next != null or position % branches.jobs == branches.worker;
    if (branches.plan) |plan| {
        if (!mine) return null;
        return plan[position];
    }
    const index: u32 = @intCast(index_flat);
    const shards = if (single) 1 else branches.arguments.shard_count;
    const shard = if (single) 0 else branches.arguments.shard_index;
    if (index % shards != shard) return null;
    if (branches.next == null and index / shards % branches.jobs != branches.worker) return null;
    const exploration = branches.exploration;
    const replay = exploration.replay;
    return .{
        .index = index,
        .seed = if (replay) |tape_replay|
            tape_replay.header.branch_seed
        else
            branch_seed(seed_base(exploration), index),
        .snapshot = branches.snapshot,
        .path = if (replay) |tape_replay| tape_replay.header.chain else &.{},
        .jitter_seed = if (replay) |tape_replay| tape_replay.header.clock_jitter_seed else null,
        .margin_branches = if (replay) |tape_replay| tape_replay.header.margin_branches else null,
    };
}

/// Where a branch starts and with what: the tree explorer plans these, a generation at a time.
const Planned = struct {
    index: u32,
    seed: u64,
    snapshot: *const Snapshot,
    /// From the setup snapshot to `snapshot`: the ancestors and the moments they branched.
    path: []const tape.Segment = &.{},
    generation: u32 = 0,
    /// Why it starts there, for people (the tree explorer's reason).
    why: []const u8 = "",
    /// Where it stops (virtual time), a returned branch's horizon: null for the timeline's end.
    horizon_ns: ?u64 = null,
    /// The disk holder its node was made from: its own first disk holder saves against it.
    disk_origin: ?holders.Origin = null,
    /// The archive cell its return went to (TreeReturn.cell).
    cell: ?u64 = null,
    /// Its own clock's jitter (VM.Options.tsc_jitter_seed from where it starts): its strategy's
    /// choice at its branch, else a child's its parent's. Its path's segments say each
    /// ancestor's, which a replay boots each segment with. Null: the run's.
    jitter_seed: ?u64 = null,
    /// Its stepper's margin (VM.Options.margin_branches): its strategy's choice at its branch,
    /// its tape's header saying it (a replay steps alike). Null: the run's.
    margin_branches: ?u32 = null,
};

/// How a branch went, for planning the next generation: the behaviors it reached first, when.
const Summary = struct {
    index: u32,
    start_ns: u64,
    end_ns: u64,
    behavior_count: u32,
    behaviors: [Events.behavior_count_max]Events.Behavior,
    /// The in-run snapshots it kept (holders.zig), for the explorer to return to.
    holder_count: u32,
    holders: [holders.per_timeline_max]holders.Held,
    /// Its whole trace's hash (from the setup snapshot): equal, the same timeline.
    trace_hash: u64,
    /// Its last randomness pull's moment (VM.last_pull_ns), or when its checks' inputs began
    /// streaming out (Events.checks_start_ns) if earlier: branches return before it. From later, a branch
    /// replays the timeline's shutdown alone, and its host checks get part of their input (run
    /// 43, srv3: the archive returned after a built-in property of the end, and Elle refused
    /// 28 such histories).
    last_pull_ns: u64,
    /// Stopped at its horizon: it can be extended (returned to at its end), its future unknown.
    cut: bool,
    /// Past the timeline limit without finishing (VM.Outcome.hung). Not on disk: a resumed run's
    /// recorded timelines teach the learned limit nothing.
    hung: bool = false,
    /// It ran with a stop from the run's learned limit (learned_stop), and was cut there. Not on
    /// disk either.
    learned_stop: bool = false,
    learned_cut: bool = false,
    /// Ended by the strategy (VM.Outcome.strategy_ended): not extended, nor counted in the
    /// timelines' usual length. Not on disk: a resumed run takes it as ended.
    ended_early: bool = false,
    /// When its driver phase ended (Events.drive_end_ns), if it did in this timeline.
    drive_end_ns: ?u64 = null,
    /// The last event's moment before its composer last asked whether to drive another phase
    /// (advisor.zig's again_ns), if it asked in this timeline: a return to an objective's best
    /// lands no later, so its branches meet the ask. Not on disk: a resumed run's recorded
    /// timelines are returned to where their best was.
    again_ns: ?u64 = null,
    /// When its workload said its state looked hopeless (Events.doomed_ns: sdk.doomed), if it did.
    doomed_ns: ?u64 = null,
    /// When its tape was full (VM.tape_full_ns), if it was: no return lands past it, whatever
    /// else allows one (a cut timeline's moments to its end, a strategy's: CE58).
    tape_full_ns: ?u64 = null,
    /// The properties it fails (their messages' hashes), up to `failing_max`: the explorer saves
    /// the first failing timeline of each to disk from its holders (Ladders).
    failing: [failing_max]u64 = undefined,
    failing_count: u8 = 0,
    /// The configuration draws' buckets it drew (VM.bandit_uses), credited when judged. Not on
    /// disk: a resumed run's recorded timelines credit nothing.
    bandit_uses: [bandit_zig.uses_max]bandit_zig.Use = undefined,
    bandit_use_count: u8 = 0,
    /// Its own clock (Planned.jitter_seed), which its strategy may have chosen in the worker:
    /// the tree gives it to the timelines it plans from this one.
    jitter_seed: ?u64 = null,
    /// The seed it ran with (Planned.seed, its strategy's choice at its branch if any): the
    /// plan's once judged, so its children's chains replay it as it ran (plan_adopt_ran).
    seed: ?u64 = null,

    const failing_max = 16;
};

const Summaries = struct {
    items: []Summary,
    count: u32 = 0,

    fn note(
        summaries: *Summaries,
        vm: *VM,
        place: Planned,
        outcome: VM.Outcome,
        kept: []const holders.Held,
        /// The configuration draws' buckets it drew (advisor.zig), credited when judged.
        uses: []const bandit_zig.Use,
        again_ns: ?u64,
    ) void {
        assert(summaries.count < summaries.items.len);
        const summary = &summaries.items[summaries.count];
        summaries.count += 1;
        summary.index = place.index;
        summary.jitter_seed = place.jitter_seed;
        summary.seed = place.seed;
        summary.start_ns = place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s);
        summary.end_ns = if (vm.moment()) |moment| moment.vtime_ns else |_| summary.start_ns;
        summary.behavior_count = vm.events.behavior_count;
        summary.trace_hash = vm.events.hash.final();
        summary.last_pull_ns = returns_before_ns(vm.last_pull_ns, vm.events.checks_start_ns, vm.tape_full_ns);
        summary.tape_full_ns = vm.tape_full_ns;
        summary.cut = place.horizon_ns != null and outcome == .moment_reached;
        summary.hung = outcome == .hung;
        summary.ended_early = outcome == .strategy_ended;
        summary.drive_end_ns = vm.events.drive_end_ns;
        summary.again_ns = again_ns;
        summary.doomed_ns = vm.events.doomed_ns;
        summary.bandit_use_count = @intCast(uses.len);
        @memcpy(summary.bandit_uses[0..uses.len], uses);
        summary.holder_count = @intCast(kept.len);
        @memcpy(summary.holders[0..kept.len], kept);
        summary.failing_count = 0;
        for (vm.events.properties[0..vm.events.property_count]) |*property| {
            if (property.passing() or summary.failing_count == Summary.failing_max) continue;
            summary.failing[summary.failing_count] = std.hash.Wyhash.hash(0, property.name());
            summary.failing_count += 1;
        }
        @memcpy(
            summary.behaviors[0..summary.behavior_count],
            vm.events.behaviors[0..vm.events.behavior_count],
        );
    }
};

/// Why a return is a replay from its parent's start, its parent's earliest holder known or not
/// (Registry.earliest): before it, after it (those at or before the moment taken or gone), or
/// none at all (`no_holder`: a timeline of an earlier generation, its holders gone with its
/// judgment, none on disk). Silent until 2026-11-23, though late in a long run most replays
/// were so (calibration run 2125: generation 44's 6 moments, 4 in generation 0's timelines).
const ReplayWhy = enum { before_holders, holders_gone, no_holder };

fn replay_why(first: ?u64, vtime_ns: u64) ReplayWhy {
    const earliest = first orelse return .no_holder;
    return if (earliest > vtime_ns) .before_holders else .holders_gone;
}

test "a return to a timeline that kept no holder says why it replays" {
    try std.testing.expectEqual(ReplayWhy.before_holders, replay_why(5000, 1000));
    try std.testing.expectEqual(ReplayWhy.holders_gone, replay_why(1000, 5000));
    try std.testing.expectEqual(ReplayWhy.no_holder, replay_why(null, 5000));
}

/// Antithesis's exploration, as a tree: every branch is a potential branch point. The first
/// generation starts from the setup snapshot; after each, the branches that reached behaviors
/// no branch before them had are returned to (Go-Explore): a snapshot at the moment just after
/// the new behavior (replaying the branch to it), and new branches from there, with their own
/// seeds. Some branches of every generation start from the setup snapshot again. A generation
/// is planned only from the ones before it; which timelines form it follows the order they
/// finish in, so the same seed can grow another tree on other workers (each timeline, and any
/// moment of it, replays exactly, and a resumed run judges its recorded generations again).
const tree = struct {
    /// Timelines per generation by default, and the unit of `--generation`.
    const generation_base = 16;
    const generation_max = 256;
    /// Branches from each moment returned to, by default (`--return-branches`).
    const children = 4;

    /// A generation's size for `workers`: the most multiples of the base that run at once, so a
    /// generation is one wave (its judgment after its slowest timeline, not two waves' worth);
    /// the workers past it take the next generation's fresh timelines meanwhile (queue_take).
    /// Rounded up (48 on 40 workers), eight started only as the first wave ended, and YugabyteDB's
    /// hunts judged no generation in their hour (runs 1996, 1999, A/B arm 2001).
    fn generation_for(workers: u32) u32 {
        return std.math.clamp(std.mem.alignBackward(u32, workers, generation_base), generation_base, generation_max);
    }

    test generation_for {
        try std.testing.expectEqual(@as(u32, 32), generation_for(40));
        try std.testing.expectEqual(@as(u32, 32), generation_for(32));
        try std.testing.expectEqual(@as(u32, 16), generation_for(8));
        try std.testing.expectEqual(@as(u32, 16), generation_for(16));
        try std.testing.expectEqual(@as(u32, 256), generation_for(1000));
    }

    /// From the setup snapshot, in every generation after the first: a quarter.
    fn roots(size: u32) u32 {
        return size / 4;
    }

    /// Moments returned to per generation, `branches` from each.
    fn nodes(size: u32, branches: u32) u32 {
        assert(branches > 0);
        return (size - roots(size)) / branches;
    }

    /// Whether each moment's branches fill a generation's returns exactly.
    fn fits(size: u32, branches: u32) bool {
        return branches > 0 and (size - roots(size)) % branches == 0;
    }

    comptime {
        assert(roots(generation_base) + nodes(generation_base, children) * children == generation_base);
    }
};

fn explore_tree(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    const arena = context.arena;
    own_cpu.give(); // Its timelines and node makers take their own.
    timeline_learner = .{ .multiple = branches.arguments.timeline_limit_learned };
    const exploration = branches.exploration;
    const size = branches.arguments.generation_size;
    if (!tree.fits(size, branches.arguments.return_branches)) {
        say("error: --return-branches {d} does not divide a generation of {d}'s " ++
            "{d} returned timelines\n", .{ branches.arguments.return_branches, size, size - tree.roots(size) });
        return error.Usage;
    }
    // In-run snapshots (holders.zig): not with a strategy that decides within timelines (its
    // decisions replay from its tape, as holders do not); one that only chooses where the tree
    // returns ("decides":false) keeps them.
    var registry: holders.Registry = undefined;
    const deciding = if (exploration.strategy) |plugin| plugin.decides else false;
    const holding = !deciding and branches.arguments.holders;
    if (holding) try registry.init(arena);
    // While memory runs low, holders go to the run's directory (holders.Disk), on its disk.
    const disk: ?*const holders.Disk = if (holding) if (branches.arguments.run_directory) |run| disk: {
        const directory = try std.fs.path.join(arena, &.{ run, "holders" });
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        const made = try arena.create(holders.Disk);
        made.* = .{ .directory = directory };
        made.delete(null); // An interrupted run's.
        break :disk made;
    } else null else null;
    if (holding) registry.disk = disk;
    registry.retain = holding and branches.arguments.holders_retain;
    holders.writeback = branches.arguments.holders_writeback;
    if (holding) if (branches.arguments.holders_budget_gb) |gb| {
        registry.kept_budget = gb << 30;
    };
    defer if (holding) {
        registry.release(disk);
        const left = holders.listening(registry.explorer);
        if (left > 0) {
            say("[determinismo] holders: {d} still listening at the tree's end (never in the registry)\n", .{left});
            activity.holders_left(left);
        }
    };
    // The setup snapshot among the disk holders, written once by a writer of its own (the run
    // goes on meanwhile; a root before it lands writes its whole guest, as before).
    var tree_branches = branches;
    if (disk) |on_disk| if (branches.setup) |setup| {
        if (holders.setup_origin_write(setup, on_disk)) |origin| tree_branches.setup_disk_origin = origin;
    };
    // The failing timelines' holders go to the run's snapshots (a run's: a directory to keep
    // them). The table of page hashes is shared before the workers fork: their holders write it.
    const ladders: ?*Ladders = if (holding) if (branches.arguments.run_directory) |run| ladders: {
        const setup = branches.setup orelse branches.snapshot;
        const page_hashes = try Snapshot.PageHashes.init(setup.memory_size);
        var hasher = std.hash.Wyhash.init(0);
        for ([_]u64{ exploration.inputs, exploration.exploration_seed, setup.tsc, setup.branches }) |value| {
            hasher.update(std.mem.asBytes(&value));
        }
        const directory = try Snapshot.layout_directory(arena, try std.fs.path.join(arena, &.{ run, "snapshots" }));
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        const made = try arena.create(Ladders);
        made.* = .{
            .ladder = .{ .directory = directory, .hashes = page_hashes.hashes },
            .holders_directory = if (disk) |known| known.directory else null,
            .setup = setup,
            .setup_name = try std.fmt.allocPrint(arena, "setup-{x:0>16}", .{hasher.final()}),
            .explorer = linux.getpid(),
            .io = context.io,
        };
        break :ladders made;
    } else null else null;
    const change: ?changed.Change = if (branches.arguments.changed) |source|
        try changed.read(
            arena,
            context.io,
            source,
            branches.arguments.changed_repository,
            branches.arguments.cache_directory,
        )
    else
        null;
    // Its workers, holders and node makers branch from snapshots it holds: their VMs may claim
    // what it learns they hold of their own (cpus.claim_shares). Before any of them forks.
    cpus.claim_shares = true;
    // The tree's root, held for the whole run: its branches, and the nodes made from them, keep
    // only their pages that differ from it (Snapshot.root, base_fd). Before any worker forks.
    @constCast(branches.snapshot).root = true;
    var state: TreeState = .{
        .base = seed_base(exploration),
        .total = branches.arguments.branches,
        .tape_directory = branches.exploration.tape_directory,
        .size = size,
        .children = branches.arguments.return_branches,
        .pipeline = branches.arguments.pipeline,
        .archive = branches.arguments.archive,
        .prefer_sometimes = branches.arguments.prefer_sometimes,
        .prefer_severe = branches.arguments.prefer_severe,
        .history = if (branches.arguments.history_path) |path| try history_read(arena, context.io, path) else null,
        .setup = branches.snapshot,
        .setup_vtime_ns = branches.snapshot.events.last_vtime_ns,
        // The setup's origin among the holders on disk is the root's when the tree starts from
        // the setup (not from a later moment): chains on it load over the root.
        .root_origin = if (branches.setup) |setup| (if (setup == branches.snapshot) tree_branches.setup_disk_origin else null) else null,
        .return_offsets_ns = branches.arguments.return_offsets_ns,
        .jobs = jobs,
        .holding = holding,
        .registry = &registry,
        .change = change,
        .hunks_reached = try arena.alloc(bool, if (change) |known| known.hunks.len else 0),
        // A judgment takes up to the batch's whole room (judge_count).
        .candidates = try arena.alloc(Candidate, batch_generations * size + jobs),
        .ladders = ladders,
        .disk = disk,
        .io = context.io,
        .tape_buffer = try tape.Overrides.create(arena),
        .resumed = exploration.done,
    };
    // What the setup reached, known before the first generation: each timeline reaches it again
    // (a JVM's startup coverage at every restart) before anything of its own, and the tables keep
    // room past their first half only for behaviors the tree does not know (Events.behaviors_seen).
    // Without it, hunt run 1901 (Pulsar, coverage on): generation 0, "8192 new behaviors (8192
    // known); 0 moments returned to", every table the same startup lines; no return in 170
    // timelines. The setup is every timeline's, and a resumed run's too: the same tree.
    if (branches.setup_behaviors) |known| {
        try state.seen.ensureTotalCapacity(arena, known.count());
        var hashes = known.keyIterator();
        while (hashes.next()) |hash| state.seen.putAssumeCapacity(hash.*, {});
        say("[determinismo] tree: {d} behaviors known from the setup\n", .{state.seen.count()});
    }
    // The configuration bandit warm from the system's last runs (serve's history, `.bandit`
    // beside it): none yet, a run starts cold.
    if (branches.arguments.history_path) |path| if (branches.arguments.config_bandit) {
        const learned_path = try std.fmt.allocPrint(arena, "{s}.bandit", .{path});
        if (std.Io.Dir.cwd().readFileAlloc(context.io, learned_path, arena, .limited(1 << 24))) |learned| {
            bandit_zig.warm(&state.bandit, arena, learned);
            say("[determinismo] configuration bandit: warm from the system's last runs ({d} draws)\n", .{state.bandit.name_count});
        } else |_| {}
    };
    if (branches.arguments.record_path) |record| {
        const path = try std.fmt.allocPrint(arena, "{s}.summaries", .{record});
        const fd = try open_for_appending(arena, path, if (state.resumed != null) .kept else .fresh);
        // A record the interruption cut: gone, the timeline runs again.
        if (state.resumed) |resumed| _ = linux.ftruncate(fd, @intCast(resumed.summaries_size));
        tree_summaries_fd = fd;
    }
    defer if (tree_summaries_fd) |fd| {
        close(fd);
        tree_summaries_fd = null;
    };
    // A queue of planned timelines, taken in order as CPUs free up; a generation is the next
    // `size` timelines to finish, whatever their indices, judged as soon as it is complete and
    // its returns planned at the queue's end. No CPU waits for a slow timeline: it is judged
    // with a later generation (a fixed set of indices once held back every timeline planned
    // after it, and minutes-long timelines left cores idle). The queue starts with `pipeline`
    // generations from the setup snapshot: while one fills, the others keep every CPU busy.
    // Which timelines formed each generation is recorded, and a resumed run judges the same
    // generations again: the tree follows the timelines' finishing order, its record says which.
    for (0..state.pipeline * size) |planned| {
        index_settle(&state);
        if (state.next_index >= state.total) break;
        // The first generation planned; the rest filler, behind every judged generation's plan.
        const place: Planned = .{
            .index = state.next_index,
            .seed = branch_seed(state.base, state.next_index),
            .snapshot = branches.snapshot,
        };
        try if (planned < size) queue_push(arena, &state, place) else queue_fill(arena, &state, place);
        state.next_index += 1;
    }
    nodes_claim_refresh(&state); // The setup snapshot's, from the start.
    // Room for a few generations and every timeline running past them: those finish while the
    // last judgment's nodes are still being made, and are the next generations' (batch_generations).
    var batch: Batch = .{
        .items = try arena.alloc(Summary, batch_generations * size + jobs),
        .scratch = try arena.alloc(Summary, 1),
        .spare = try arena.alloc(Summary, batch_generations * size + jobs),
    };
    batch.summaries = .{ .items = batch.items };
    if (state.resumed) |resumed| try tree_rejudge(context, vm, options, branches, &state, &batch, resumed);
    var running: [jobs_max]Running = undefined;
    var running_count: u32 = 0;
    // How busy the workers were: timelines running, over the loop's wall time (status.json and
    // the end's line). A hunt's 16 workers ran 8.8 timelines at once by their wall times (Kafka,
    // srv3 2026-10-28): which share was idle, and for memory, is what this says.
    var busy: Busy = .{ .jobs = jobs, .start_ns = monotonic_ns(), .last_ns = monotonic_ns() };
    defer busy.print(branches.multiverse);
    var judging: ?Judging = null;
    // Said once a generation: it completed while the last judgment's nodes were being made.
    var waiting_said = false;
    var sampled_ns: u64 = 0;
    // When the progress line was last said (said no oftener while the loop looks for room).
    var progressed_ns: u64 = monotonic_ns();
    // Whether the run's holders went at its ending (below).
    var holders_dropped = false;
    // The explorer's own pool, for its run's claims alone (claims_look): its timelines' processes
    // each open theirs (worker_run), and `branches.pool` is none here. Without one the run's
    // claims stay its guests' size.
    var claims_pool: cpus.Pool = undefined;
    const claims_pool_open = if (claims_pool.open()) |_| true else |_| false;
    defer if (claims_pool_open) claims_pool.close();
    while (true) {
        busy.advance(running_count);
        if (monotonic_ns() -| sampled_ns >= activity_sample_ns) {
            sampled_ns = monotonic_ns();
            var nodes: u32 = 0;
            if (judging) |*pending| for (pending.makings[0..pending.making_count]) |making| {
                nodes += @intFromBool(!making.ready);
            };
            var starts: [jobs_max]u64 = undefined;
            var indices: [jobs_max]u32 = undefined;
            for (running[0..running_count], starts[0..running_count], indices[0..running_count]) |entry, *start, *index| {
                start.* = activity.ms_of_monotonic(entry.start_ns);
                index.* = entry.index;
            }
            const split = cpus.memory_split();
            activity.sample(starts[0..running_count], indices[0..running_count], nodes, @intCast(state.queue.items.len - state.queue_head), cpus.memory_available(), if (holding) registry.count else 0, split.anonymous, split.shared);
        }
        claims_look(&state, if (claims_pool_open) &claims_pool else null, running[0..running_count], jobs);
        const late = past_deadline(branches);
        // A run that starts no timeline any more (drained, or past its budget) returns to none of
        // its holders: their memory and disk go now, to the next hunt beside its last timelines,
        // and again as each of those ends with its own (a drained Oxia pass kept 363 GB on disk
        // for its last timeline, run 1785; memory short, the next hunt's went to disk too). A
        // resume starts without them; a failing timeline's ladder took its own as it ended.
        if (late and holding and (!holders_dropped or registry.count > 0)) {
            registry.release(disk);
            holders_dropped = true;
        }
        // Past the budget and its grace: the timelines still running stop, not counted. Not in a
        // drained run: what it holds is its last timelines' cores alone (the next hunt has the
        // rest, its holders gone), and they are counted as they end; Pulsar's, longer than the
        // budget's hour, were killed after 50 minutes of drain, 49% of the run's core time lost
        // (hunt run 1792).
        if (branches.deadline_ns) |deadline| if (running_count > 0 and !drain_requested.load(.acquire) and
            monotonic_ns() >= deadline + tail_grace_ns(branches.arguments.time_budget_ns.?))
        {
            // Those that finished first, counted: only the ones still running stop.
            if (try timeline_wait(running[0..running_count], branches.multiverse, &batch.summaries, 0)) |finished| {
                try timeline_reaped(arena, &state, &batch, &running, &running_count, finished);
                continue;
            }
            for (running[0..running_count]) |entry| _ = linux.kill(entry.pid, .KILL);
            for (running[0..running_count]) |entry| {
                var status: i32 = 0;
                _ = linux.waitpid(entry.pid, &status, 0);
                _ = linux.close(entry.results);
            }
            say("[determinismo] the budget's grace is over: {d} timelines still running " ++
                "stopped, not counted\n", .{running_count});
            running_count = 0;
            continue;
        };
        // A run that starts no timeline any more makes no node more: the makers that waited
        // for room are not started, and those making one are stopped (their returns' timelines
        // would never run). Waited for, they held the run's end: Turso composer's run 2093, its
        // budget and grace over, its explorer in makings_finish_all.
        if (late) if (judging) |*pending| {
            makings_cancel(pending.makings[0..pending.making_count]);
            makings_stop(pending.makings[0..pending.making_count]);
        };
        // A generation judged meanwhile: its branches planned once its nodes are all made.
        if (judging) |*pending| if (try tree_judge_poll(arena, maker_start(vm, options, branches, &state), branches, &state, pending)) {
            try tree_judge_end(context, vm, options, branches, &state, &batch, pending);
            judging = null;
            continue;
        };
        // A complete generation: judged, its nodes made while timelines go on. One judgment at a
        // time: one complete while the last one's nodes are still being made waits for them
        // (polled above), timelines reaped and started meanwhile, the ones past it the next
        // generation's first. Waiting on the nodes here blocked the loop: on a c8i.metal-48xl
        // nothing was reaped, sampled or started for 752 s, and past the budget's grace 95
        // timelines were killed uncounted (docs/AWS.md, Mu3's hunt, 2026-11-08).
        if (!late and judging == null and batch.summaries.count >= size) {
            judging = try tree_judge_begin(context, vm, options, branches, &state, &batch, !state.rejudge_last);
            state.rejudge_last = false;
            waiting_said = false;
            continue;
        }
        if (!late and !waiting_said and batch.summaries.count >= size) if (judging) |*pending| {
            waiting_said = true;
            say("[determinismo] tree: generation {d} complete while generation {d}'s " ++
                "nodes are made: it waits, timelines going on\n", .{ pending.generation + 1, pending.generation });
        };
        // Timelines start as CPUs free up, in the queue's order; none past the budget, none
        // without room for its summary beside every running one's, and none ahead of the VMs
        // that fit in memory (timeline_gated), but a recorded one.
        const startable = !late and running_count < jobs and batch.summaries.count + running_count < batch.items.len;
        const waiting = if (timeline_admissions) |admissions| timelines_waiting(running[0..running_count], admissions) else 0;
        state.gated = startable and claims_pool_open and queue_offers(&state, judging != null) and
            !queue_recorded(&state) and timeline_gated(&claims_pool, waiting);
        state.filler_waits = startable and queue_filler_held(&state, judging != null);
        state.filler_held += @intFromBool(startable and queue_filler_held(&state, judging != null));
        state.queue_held += @intFromBool(state.gated);
        if (startable and !state.gated) if (try queue_take(arena, &state, judging != null, branches.snapshot)) |place| {
            // A resumed run's recorded timeline: its summary, not the timeline again.
            if (state.resumed) |resumed| if (resumed.summaries.get(place.index)) |bytes| {
                summary_load(&batch.items[batch.summaries.count], bytes);
                batch.summaries.count += 1;
                try batch.plan.append(arena, place);
                continue;
            };
            var mine = tree_branches;
            mine.plan = (&place)[0..1];
            // What the tree knows, with holders or without: past half its table, a timeline keeps
            // only what is new (Events.behaviors_seen; given with holders alone, --no-holders
            // runs' tables filled with known behaviors).
            mine.seen = &state.seen;
            mine.history = state.history;
            if (holding) {
                mine.holders = registry.explorer;
                // None while holders not judged yet fill the disk budget: a judgment frees room
                // (their returns then load them or replay). Said as it changes.
                const full = registry.disk_full();
                if (full != state.holders_disk_full) std.debug.print("[determinismo] holders: {s}\n", .{if (full)
                    "the disk budget is full of holders not judged yet: timelines start with none on disk"
                else
                    "room in the disk budget again: timelines keep holders on disk"});
                state.holders_disk_full = full;
                mine.holders_disk = if (full) null else disk;
                if (ladders) |known| mine.ladder = &known.ladder;
                if (state.ends_count > 0) mine.end_ns_expected = state.ends_ns_sum / state.ends_count;
            }
            if (branches.arguments.drive_steered_max_ms) |max_ms| mine.drive_k = state.novelty.choose(max_ms, place.index);
            // A return to an objective's best state: its branch goes on a driver phase past
            // where its parent stopped (advisor.zig answers its composer's ask yes, once).
            mine.again = objective_extends(branches.arguments) and if (place.cell) |hash|
                (if (state.cells.getPtr(hash)) |cell| cell.best != null else false)
            else
                false;
            if (branches.arguments.config_bandit) mine.bandit = &state.bandit;
            running[running_count] = try timeline_start(context, vm, options, mine, &batch, &state);
            running_count += 1;
            continue;
        };
        if (running_count > 0) {
            // Every half minute without a timeline finishing, what the run is doing: a long
            // timeline (minutes) otherwise leaves its output silent.
            status_write(branches.arguments.run_directory, running[0..running_count], branches.multiverse, state.generation, &busy);
            // Shorter while a judgment's nodes are made (they are collected between waits) and
            // while memory holds the queue back: the one waiting is let in without a timeline's end.
            const wait_ms: i32 = if (judging != null or state.gated) judging_poll_ms else progress_interval_ms;
            const finished = try timeline_wait(running[0..running_count], branches.multiverse, &batch.summaries, wait_ms) orelse {
                if (judging != null) continue;
                if (state.gated and monotonic_ns() -| progressed_ns < progress_interval_ms * std.time.ns_per_ms) continue;
                progressed_ns = monotonic_ns();
                const held = if (claims_pool_open) claims_pool.run_held() else null;
                progress_print(running[0..running_count], held, branches.multiverse, state.generation);
                continue;
            };
            try timeline_reaped(arena, &state, &batch, &running, &running_count, finished);
            continue;
        }
        // Nothing runs and nothing is queued: a judgment's nodes awaited (its returns may keep the
        // run going), a last, partial generation judged, or the run is over (out of time, or of
        // timelines).
        if (judging) |*pending| {
            try makings_finish_all(arena, maker_start(vm, options, branches, &state), pending.makings[0..pending.making_count], state.jobs, &state.nodes_skipped);
            try tree_judge_end(context, vm, options, branches, &state, &batch, pending);
            judging = null;
            continue;
        }
        if (!late and batch.summaries.count > 0 and state.next_index < state.total) {
            try tree_judge(context, vm, options, branches, &state, &batch, true);
            if (state.queue_head < state.queue.items.len) continue;
        }
        break;
    }
    for (state.queue.items[state.queue_head..]) |entry| node_free(entry.snapshot, branches.snapshot);
    for (batch.plan.items) |entry| node_free(entry.snapshot, branches.snapshot);
    say("[determinismo] tree: {d} looks held queued filler for a judgment's makers, {d} held the " ++
        "queue for memory\n", .{ state.filler_held, state.queue_held });
    if (branches.arguments.record_path) |record| try behaviors_write(context, &state, record);
    if (state.change) |*target| {
        // The last timelines no judgment took ran too (CE39).
        for (batch.summaries.items[0..batch.summaries.count]) |*summary| change_count(target, context.arena, state.hunks_reached, summary);
        target.summarize();
        report.record(.{ .changed = .{
            .hunks = target.hunks,
            .timelines = target.timelines,
            .first = target.first,
            .closest = target.closest,
        } });
    }
}

/// The run's behaviors, for its system's history (the `--history` of its next runs, serve's):
/// each one's hash, how many timelines reached it, and its label, a JSON line each. Apart from
/// record.jsonl.summaries, which is this build's memory layout: a history outlives builds.
fn behaviors_write(context: Context, state: *const TreeState, record: []const u8) !void {
    const arena = context.arena;
    var text: std.Io.Writer.Allocating = .init(arena);
    var iterator = state.visits.iterator();
    while (iterator.next()) |entry| {
        const cell = state.cells.get(entry.key_ptr.*);
        const label = if (cell) |found| found.label else "";
        try text.writer.print("{{\"hash\":\"{x:0>16}\",\"timelines\":{d},\"label\":{f}", .{
            entry.key_ptr.*, entry.value_ptr.*, std.json.fmt(label, .{}),
        });
        // A scored bucket (an optimization's, a learned range's): its best and the timeline
        // holding it (serve's /runs/<id>/ranges, the report's Learned ranges).
        if (cell) |found| if (found.best) |best| {
            try text.writer.print(",\"best\":{d},\"timeline\":{d}", .{ best, found.places[0].branch });
        };
        try text.writer.writeAll("}\n");
    }
    const path = try std.fmt.allocPrint(arena, "{s}.behaviors", .{record});
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = text.written() });
    // What the configuration bandit learned: serve gathers the system's last runs' into the next
    // run's history (`<history>.bandit`), which starts from it (bandit_zig.warm).
    var learned: std.Io.Writer.Allocating = .init(arena);
    try bandit_zig.write(&state.bandit, &learned.writer);
    const bandit_path = try std.fmt.allocPrint(arena, "{s}.bandit", .{record});
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = bandit_path, .data = learned.written() });
}

/// A history (`--history`): each behavior's timelines over the runs it holds.
fn history_read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !*const std.AutoHashMapUnmanaged(u64, u32) {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 28));
    const history = try history_parse(arena, source);
    say("[determinismo] history: {d} behaviors from the system's last runs\n", .{history.count()});
    return history;
}

fn history_parse(arena: std.mem.Allocator, source: []const u8) !*const std.AutoHashMapUnmanaged(u64, u32) {
    const history = try arena.create(std.AutoHashMapUnmanaged(u64, u32));
    history.* = .empty;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const Line = struct { hash: []const u8, timelines: u32 = 0 };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const hash = std.fmt.parseInt(u64, parsed.hash, 16) catch continue;
        const entry = try history.getOrPut(arena, hash);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* +| parsed.timelines else parsed.timelines;
    }
    return history;
}

test history_parse {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Two runs' behaviors, one line cut short, one hash not hexadecimal: skipped.
    const history = try history_parse(arena_state.allocator(),
        \\{"hash":"00000000000000a1","timelines":3,"label":"kernel printed \"x\""}
        \\{"hash":"00000000000000b3","timelines":1,"label":"sometimes \"y\": true"}
        \\{"hash":"00000000000000a1","timelines":4,"label":"kernel printed \"x\""}
        \\{"hash":"00000000000000c5","time
        \\{"hash":"zz","timelines":2}
    );
    try std.testing.expectEqual(@as(u32, 2), history.count());
    try std.testing.expectEqual(@as(?u32, 7), history.get(0xa1));
    try std.testing.expectEqual(@as(?u32, 1), history.get(0xb3));
}

/// Plans a timeline at the queue's end: its start snapshot has one more timeline to serve.
/// A planned timeline: after the planned ones, before the filler.
fn queue_push(arena: std.mem.Allocator, state: *TreeState, place: Planned) !void {
    try queue_plan(arena, state, place);
    try queue_use(arena, state, place.snapshot);
}

/// A fresh timeline only to keep the CPUs busy: after everything, taken when nothing planned
/// waits.
fn queue_fill(arena: std.mem.Allocator, state: *TreeState, place: Planned) !void {
    try state.queue.append(arena, place);
    try queue_use(arena, state, place.snapshot);
}

/// Into the planned part of the queue (a killed timeline again, its snapshot already counted).
fn queue_plan(arena: std.mem.Allocator, state: *TreeState, place: Planned) !void {
    assert(state.queue_head <= state.queue.items.len);
    const at = @max(state.filler_start, state.queue_head);
    assert(at <= state.queue.items.len);
    try state.queue.insert(arena, at, place);
    state.filler_start = at + 1;
}

fn queue_use(arena: std.mem.Allocator, state: *TreeState, snapshot: *const Snapshot) !void {
    const entry = try state.users.getOrPut(arena, snapshot);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
}

/// Whether the queue has a timeline to start (queue_take): one queued, or a fresh one while a
/// judgment's nodes are made; no filler while that judgment's makers wait for memory, but one a
/// resume has recorded, which loads its summary and asks for no VM.
fn queue_offers(state: *const TreeState, judging: bool) bool {
    if (queue_held_back(state, judging)) return false;
    if (state.queue_head < state.queue.items.len) return true;
    return judging and state.next_index < state.total;
}

/// Whether what the queue would give now, queued or fresh, is filler held for a judgment's
/// makers (queue_offers).
fn queue_held_back(state: *const TreeState, judging: bool) bool {
    if (!judging or !state.makers_short) return false;
    if (state.queue_head < state.filler_start or queue_recorded(state)) return false;
    return state.queue_head < state.queue.items.len or state.next_index < state.total;
}

/// Whether that is filler already queued: a fresh one was refused before 2026-11-22 too, so
/// only this counts as the queue's hold acting (filler_held).
fn queue_filler_held(state: *const TreeState, judging: bool) bool {
    return queue_held_back(state, judging) and state.queue_head < state.queue.items.len;
}

/// Whether the queue's next timeline is one a resumed run recorded.
fn queue_recorded(state: *const TreeState) bool {
    if (state.queue_head == state.queue.items.len) return false;
    const resumed = state.resumed orelse return false;
    return resumed.summaries.contains(state.queue.items[state.queue_head].index);
}

/// Started timelines whose VMs were never admitted (timeline_admissions).
fn timelines_waiting(running: []const Running, admissions: *const [jobs_max]u64) u32 {
    var waiting: u32 = 0;
    for (running) |timeline| waiting += @intFromBool(@atomicLoad(u64, &admissions[timeline.slot], .monotonic) == 0);
    return waiting;
}

/// What the claims' learning takes for the workers with a timeline (ClaimLearning.sample learns
/// while every one has): all of them while memory alone keeps the rest from taking one
/// (`memory_idle`: the queue held for it, or its queued filler for makers that wait for it), as
/// when they took one and waited; a first claim then only at a plateau. Otherwise such a run
/// would learn no claim, its VMs its guests' size for good, and stay short.
fn learning_workers(started: u32, jobs: u32, memory_idle: bool) u32 {
    return if (memory_idle) jobs else started;
}

/// Whether memory keeps the queue's next timeline from a worker: one started waits for its VM,
/// and there is no room for those waiting and it (`pool`: cpus.Pool's room). Taken ahead of the
/// VMs that fit, timelines stood in the admission's line before whatever a judgment planned
/// after them: 48 workers, 17 VMs of 10 GiB guests on 192 GiB, 31 in line, and no returned
/// timeline ran in 2 hours (aws-hunt run 18; srv4's run 1145 the same). One waits, so that a
/// VM's room never idles; the rest stay in the queue, whose order is the tree's.
fn timeline_gated(pool: anytype, waiting: u32) bool {
    return waiting > 0 and !pool.room(waiting + 1);
}

/// The next planned timeline, if any.
fn queue_next(state: *TreeState) ?Planned {
    if (state.queue_head == state.queue.items.len) return null;
    const place = state.queue.items[state.queue_head];
    state.queue_head += 1;
    return place;
}

/// The next planned timeline; with none planned while a judgment's nodes are still being made,
/// a fresh one from the setup snapshot: no CPU waits for a slow node. One node loaded from disk
/// took 546 s while memory ran low, its judgment 555 s, and with nothing planned the hunt's
/// 40 timelines ran down to 10 (etcd A/B arm run 1832, 2026-11-10; arm 1831 lost ~11% of its
/// core time so). The judgment's branches still go first once planned (queue_plan, before the
/// filler).
/// Each such timeline is recorded with the generation being judged: a resumed run takes it again
/// at the same place (tree_rejudge), before that generation's plan, so that every index keeps
/// its timeline.
fn queue_take(arena: std.mem.Allocator, state: *TreeState, judging: bool, setup: *const Snapshot) !?Planned {
    // No filler while the judgment's makers wait for memory, one queued (the pipeline's, from
    // the launch) no more than a new one: its VM would take the room they wait for as it frees,
    // and the judgment waits on them (run 2106: its judgments went from 35 s to over 538 s, the
    // filler most of its timelines; held to new ones alone, 21 minutes of a 2 hour hunt whose
    // returns never ran, 2026-11-22). What a judgment planned is before the filler, and starts.
    if (!queue_offers(state, judging)) return null;
    if (queue_next(state)) |place| return place;
    index_settle(state);
    if (state.next_index >= state.total) return null;
    report.record(.{ .fresh = .{ .generation = state.generation, .index = state.next_index } });
    try queue_fresh(arena, state, setup);
    return queue_next(state);
}

/// The tree's next number made its own: taken as it is planned (tape.claim: a timeline's number
/// is whoever creates its tape first's), those a timeline extending another took meanwhile (a
/// session's) passed over. Before every number planned; a resumed run passes over the same.
fn index_settle(state: *TreeState) void {
    while (state.next_index < state.total) : (state.next_index += 1) {
        // A number the interrupted run gave a return's child: that return's again (child_indices).
        if (state.resumed) |resumed| if (resumed.planned_indices.contains(state.next_index)) continue;
        const directory = state.tape_directory orelse return;
        if (tape.claim(directory, state.next_index)) return;
    }
}

/// A return's children's numbers: those the interrupted run gave them (a resumed run's), else
/// the next `count` free ones (the run's numbering as it is planned).
fn child_indices(arena: std.mem.Allocator, state: *TreeState, key: ReturnKey, count: u32) ![]const u32 {
    if (state.resumed) |resumed| if (resumed.planned.get(key)) |recorded| return recorded;
    var indices: std.ArrayList(u32) = .empty;
    for (0..count) |_| {
        index_settle(state);
        if (state.next_index >= state.total) break;
        try indices.append(arena, state.next_index);
        state.next_index += 1;
    }
    return indices.items;
}

fn queue_fresh(arena: std.mem.Allocator, state: *TreeState, setup: *const Snapshot) !void {
    assert(state.next_index < state.total);
    try queue_fill(arena, state, .{
        .index = state.next_index,
        .seed = branch_seed(state.base, state.next_index),
        .snapshot = setup,
        .generation = state.generation + 1,
        .why = "From the setup snapshot while a judgment's nodes were made: the CPUs kept busy.",
    });
    state.next_index += 1;
}

/// Generations of summaries a tree's batch has room for, beside every running timeline's: the
/// next ones complete while a slow judgment's nodes are made, and timelines go on starting
/// meanwhile (with room for one, a 9-minute judgment left 30 of 40 CPUs idle: run 1832). With
/// four, a 40-worker run whose returns end in seconds filled them in the 161 to 184 s its
/// judgments' replays from their parents' starts took, four times in three hours (24.7 to 70.8%
/// of ten minutes idle, 2026-11-17). Room costs little resident memory: a summary's pages are
/// touched as it fills (Summaries.note writes its behaviors' count), its behaviors' fixed array
/// mostly not.
const batch_generations = 16;

/// The timelines a judgment takes: every whole generation completed by then, one judgment for
/// them all, their returns and fresh timelines in proportion (tree.nodes, tree.roots of the
/// whole). Judged one generation each, the ones completed while a judgment waited for its slowest
/// node maker queued behind it: generations completed faster than they were judged (run 2012:
/// 33 an hour against 26.6), until they filled the batch and no timeline could start, not even a
/// fresh one (184 waiting, 69 to 74% of its workers idle in its minutes 50 to 60). Fewer than a
/// generation (a run's last, partial one): all of them.
fn judge_count(complete: u32, size: u32) u32 {
    assert(size > 0);
    if (complete < size) return complete;
    return size * (complete / size);
}

test judge_count {
    // One generation completed, and some of the next: the one.
    try std.testing.expectEqual(@as(u32, 32), judge_count(45, 32));
    // Five waiting behind a slow judgment: the five, at once.
    try std.testing.expectEqual(@as(u32, 160), judge_count(168, 32));
    // A run's last, partial generation.
    try std.testing.expectEqual(@as(u32, 20), judge_count(20, 32));
    // Whole generations' returns and fresh timelines add up to the whole.
    const judged = judge_count(100, 32);
    try std.testing.expect(tree.fits(judged, tree.children));
    try std.testing.expectEqual(judged, tree.roots(judged) + tree.nodes(judged, tree.children) * tree.children);
}

/// A judged timeline's start snapshot serves one timeline fewer: freed with its last (siblings
/// from one moment can finish in different generations).
fn node_served(state: *TreeState, snapshot: *const Snapshot) void {
    const entry = state.users.getEntry(snapshot) orelse return;
    entry.value_ptr.* -= 1;
    if (entry.value_ptr.* > 0) return;
    _ = state.users.remove(snapshot);
    node_free(snapshot, state.setup);
}

/// A resumed run's recorded generations judged again, in their order, each from its timelines'
/// summaries (none runs again): the queue is then the interrupted run's. A generation whose
/// summaries the interruption cut ends it: from there the run goes on as a new one would.
fn tree_rejudge(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    resumed: *const Resumed,
) !void {
    for (0..resumed.generations.items.len) |at_generation| {
        switch (try rejudge_load(context.arena, state, batch, resumed, at_generation, branches.snapshot)) {
            .cut, .last => return,
            .judge => try tree_judge(context, vm, options, branches, state, batch, false),
        }
    }
}

/// What becomes of a resumed run's recorded generation (rejudge_load).
const Rejudged = enum {
    /// Not the plan its record was made with, or cut by the interruption: nothing taken, the run
    /// goes on from here as a new one would.
    cut,
    /// Its timelines out of the queue, their summaries in the batch: judged at once, not
    /// recorded again. Its returns are all recorded: no node is made for them.
    judge,
    /// The last recorded: in the batch as well, and left to the run's loop (rejudge_last).
    last,
};

/// A recorded generation's timelines out of the queue (the rest keeps its order, and its
/// filler's start), their summaries into the batch, and who judges it.
fn rejudge_load(
    arena: std.mem.Allocator,
    state: *TreeState,
    batch: *Batch,
    resumed: *const Resumed,
    at_generation: usize,
    setup: *const Snapshot,
) !Rejudged {
    const members = resumed.generations.items[at_generation];
    if (members.len > batch.items.len) return .cut;
    for (members) |index| if (!resumed.summaries.contains(index)) return .cut;
    var found: usize = 0;
    for (state.queue.items[state.queue_head..]) |entry| {
        if (std.mem.indexOfScalar(u32, members, entry.index) != null) found += 1;
    }
    if (found != members.len) return .cut; // Not the plan this record was made with.
    // The fresh timelines taken while it was judged, before its plan as they were.
    for (resumed.fresh.items) |fresh| if (fresh.generation == state.generation) {
        index_settle(state);
        if (fresh.index != state.next_index or state.next_index >= state.total) return .cut;
        try queue_fresh(arena, state, setup);
    };
    var kept: usize = state.queue_head;
    var filler_start: usize = state.queue_head;
    for (state.queue.items[state.queue_head..], state.queue_head..) |entry, at| {
        const member = std.mem.indexOfScalar(u32, members, entry.index) != null;
        if (!member and at < state.filler_start) filler_start += 1;
        if (member) {
            summary_load(&batch.items[batch.summaries.count], resumed.summaries.get(entry.index).?);
            batch.summaries.count += 1;
            try batch.plan.append(arena, entry);
        } else {
            state.queue.items[kept] = entry;
            kept += 1;
        }
    }
    state.queue.shrinkRetainingCapacity(kept);
    state.filler_start = @intCast(@max(filler_start, state.queue_head));
    // The last recorded generation is judged by the run's loop, as a running run's is: its
    // nodes made while fresh timelines keep the CPUs busy (queue_take). Judged in tree_rejudge
    // it waited for its nodes with every CPU idle, the holders gone with the stop: etcd's run
    // 2007 resumed at 20:41, 35 of 40 CPUs idle 15 minutes and more while 6 nodes replayed to
    // their moments (one 388 s into its timeline).
    if (at_generation + 1 == resumed.generations.items.len) {
        state.rejudge_last = true;
        return .last;
    }
    return .judge;
}

test "a resumed run's recorded generations: the earlier ones judged at once, the last left to the run's loop" {
    const arena = std.testing.allocator;
    var state: TreeState = undefined;
    state.resumed = null;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.users = .empty;
    state.generation = 0;
    state.rejudge_last = false;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    // The interrupted run's queue again: timelines 0 to 5, two generations of two recorded.
    for (0..6) |index| try queue_push(arena, &state, .{ .index = @intCast(index), .seed = index, .snapshot = setup });
    const items = try arena.alloc(Summary, 2);
    defer arena.free(items);
    var batch: Batch = .{ .items = items, .scratch = &.{}, .spare = &.{} };
    batch.summaries.items = items;
    defer batch.plan.deinit(arena);
    var resumed: Resumed = .{};
    defer resumed.summaries.deinit(arena);
    defer resumed.generations.deinit(arena);
    var recorded: [4]SummaryHeader = undefined;
    for (&recorded, 0..) |*header, index| {
        header.* = .{ .index = @intCast(index), .behavior_count = 0, .start_ns = 0, .end_ns = 100 + index, .trace_hash = index, .last_pull_ns = 0, .cut = 0 };
        try resumed.summaries.put(arena, @intCast(index), std.mem.asBytes(header));
    }
    try resumed.generations.append(arena, &.{ 0, 1 });
    try resumed.generations.append(arena, &.{ 2, 3 });

    // The first: judged at once (tree_rejudge's tree_judge, not recorded), its summaries in.
    try std.testing.expectEqual(Rejudged.judge, try rejudge_load(arena, &state, &batch, &resumed, 0, setup));
    try std.testing.expect(!state.rejudge_last);
    try std.testing.expectEqual(@as(u32, 2), batch.summaries.count);
    try std.testing.expectEqual(@as(u64, 101), batch.items[1].end_ns);
    // Judged: the batch is the next generation's.
    batch.summaries.count = 0;
    batch.plan.clearRetainingCapacity();
    // The last recorded: its summaries in as well, and the loop's to judge. Judged here it
    // held the run for its nodes with every CPU idle (run 2007's resume, 25 minutes).
    try std.testing.expectEqual(Rejudged.last, try rejudge_load(arena, &state, &batch, &resumed, 1, setup));
    try std.testing.expect(state.rejudge_last);
    try std.testing.expectEqual(@as(u32, 2), batch.summaries.count);
    try std.testing.expectEqual(@as(u32, 2), batch.plan.items[0].index);
    try std.testing.expectEqual(@as(u32, 3), batch.plan.items[1].index);
    // The queue: what neither took, in its order.
    try std.testing.expectEqual(@as(usize, 2), state.queue.items.len - state.queue_head);
    try std.testing.expectEqual(@as(u32, 4), state.queue.items[state.queue_head].index);
    try std.testing.expectEqual(@as(u32, 5), state.queue.items[state.queue_head + 1].index);
}

/// Whether the exploration's strategy decides within timelines (its answers are in tapes).
fn deciding_strategy(exploration: *const Exploration) bool {
    return if (exploration.strategy) |plugin| plugin.decides else false;
}

/// A timeline running in a process of its own (explore_tree): where its results come back, and
/// where it started.
/// The most a timeline process of the run holds of its own: its anonymous memory (RssAnon, in
/// /proc/<pid>/status: the kernel's count, read at once where smaps_rollup walked a VM's pages
/// for 48 ms): the pages its guest wrote, its VMM's, and the explorer's it shares since its
/// fork (about 1.4 GiB on srv4, so a little high); not the snapshot pages it reads, the nodes'.
/// 0 for a process gone or unreadable.
fn vms_held_most(running: []const Running, admissions: *const [jobs_max]u64) u64 {
    var most: u64 = 0;
    for (running) |*entry| {
        if (!vm_counts(entry, admissions)) continue;
        most = @max(most, rss_anon(entry.pid));
    }
    return most;
}

/// Whether a timeline's VM is one the claims' learning reads, or ends short of memory: admitted
/// (one in line holds only what it shares with the explorer since its fork, 1.6 GiB in run 2125,
/// and killed it frees nothing and is the next in line again), and not ended already.
fn vm_counts(timeline: *const Running, admissions: *const [jobs_max]u64) bool {
    if (timeline.short) return false; // Ended already, not reaped yet.
    return @atomicLoad(u64, &admissions[timeline.slot], .monotonic) != 0;
}

/// The run's timelines whose VMs count: the claims' learning's admitted, not the run's CPU
/// claims, which are its makers' and its verifier's replays' too.
fn vms_admitted(running: []const Running, admissions: *const [jobs_max]u64) u32 {
    var admitted: u32 = 0;
    for (running) |*entry| admitted += @intFromBool(vm_counts(entry, admissions));
    return admitted;
}

/// The one to end short of memory: the youngest that counts.
fn vms_youngest(running: []Running, admissions: *const [jobs_max]u64) ?*Running {
    var youngest: ?*Running = null;
    for (running) |*entry| {
        if (!vm_counts(entry, admissions)) continue;
        if (youngest == null or entry.start_ns > youngest.?.start_ns) youngest = entry;
    }
    return youngest;
}

fn rss_anon(pid: linux.pid_t) u64 {
    var path_buffer: [40]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/status", .{pid}, 0) catch return 0;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [4096]u8 = undefined;
    const size = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    const key = "RssAnon:";
    const at = std.mem.indexOf(u8, buffer[0..size], key) orelse return 0;
    var fields = std.mem.tokenizeAny(u8, buffer[at + key.len .. size], " \t\n");
    const kib = std.fmt.parseInt(u64, fields.next() orelse return 0, 10) catch return 0;
    return kib * 1024;
}

test rss_anon {
    // This process's own: read, and more than nothing.
    try std.testing.expect(rss_anon(linux.getpid()) > 0);
    try std.testing.expectEqual(@as(u64, 0), rss_anon(std.math.maxInt(i32)));
}

/// How often the explorer looks at the host's memory for its run's claims (claims_look).
const claims_look_ns = 5 * std.time.ns_per_s;

/// The run's claims, from its VMs' own memory (cpus.ClaimLearning, vms_held_most), every
/// claims_look_ns: what its VMs came to hold is what the next ones claim, and what those running
/// count as (the run's turn file: every process of the run reads it at its take). Memory short
/// after it said less than its guests' size: the claims are the guests' again, for good, and its
/// youngest VM ends, one a look while memory stays short (the least work lost; it runs again
/// once memory allows: its take waits as any). Nothing heavy on this path: a read of meminfo, a
/// write of 8 bytes, a signal.
fn claims_look(state: *TreeState, pool: ?*cpus.Pool, running: []Running, jobs: u32) void {
    const claims_pool = pool orelse return;
    const now = monotonic_ns();
    if (now -| state.claims_looked_ns < claims_look_ns) return;
    // Said at its first look: the explorer has a pool for its run's claims and looks (at
    // abfb598 it had none, returned here at once, and nothing said so; the tree check expects
    // this line). What it learns comes later, while every worker has a timeline: once what its
    // VMs hold stopped growing for a minute, or once as many timelines ended as it has workers.
    if (state.claims_looked_ns == 0) say("[determinismo] the run's VMs claim their " ++
        "guest's {d} MiB each until it learns what one holds of its own (looks every {d} s " ++
        "while every worker has one: once that stops growing for a minute, or from its {d}th " ++
        "timeline's end)\n", .{
        cpus.claim_bytes >> 20, claims_look_ns / std.time.ns_per_s, jobs,
    });
    state.claims_looked_ns = now;
    if (state.claims.short(cpus.memory_available(), cpus.memory_reserve())) {
        claims_pool.claim_soft_set(0);
        const youngest = if (timeline_admissions) |admissions| vms_youngest(running, admissions) else null;
        if (youngest) |entry| {
            entry.short = true;
            _ = linux.kill(entry.pid, .KILL);
            say("[determinismo] memory is short ({d} MiB available) after the run claimed " ++
                "less than its guests' size: its claims are the guests' again until {d} timelines " ++
                "ended, then with more room, and timeline {d}, its youngest, ends and runs again\n", .{
                cpus.memory_available() >> 20, state.claims.backoff_until, entry.place.index,
            });
        }
        return;
    }
    const held_before = state.claims.held_max;
    const memory_idle = running.len < jobs and (state.gated or state.filler_waits);
    const workers = learning_workers(@intCast(running.len), jobs, memory_idle);
    state.claims.memory_idle = memory_idle;
    if (timeline_admissions) |admissions| {
        state.claims.sample(vms_held_most(running, admissions), vms_admitted(running, admissions), workers, jobs, state.ended);
    }
    const claim = state.claims.claim(cpus.claim_bytes);
    claims_pool.claim_soft_set(claim);
    // Said at its first look that counts, and whenever its VMs' claim goes below their guest's
    // size or back to it (what they hold grew: Vitess's run 2070 claimed 11 GiB of 16 at 40
    // timelines, its guest's size again some minutes later, and said nothing of it).
    if (claim != 0 and (state.claims_said == 0 or held_before == 0)) {
        say("[determinismo] the run's VMs claim {d} MiB each from now, not their guest's " ++
            "{d}: half again the most one held of its own ({d} timelines ended)\n", .{
            claim >> 20, cpus.claim_bytes >> 20, state.ended,
        });
    } else if (claim == 0 and state.claims.held_max != 0 and (held_before == 0 or state.claims_said != 0)) {
        say("[determinismo] the run's VMs claim their guest's {d} MiB each: one held " ++
            "{d} MiB of its own at most ({d} timelines ended)\n", .{
            cpus.claim_bytes >> 20, state.claims.held_max >> 20, state.ended,
        });
    }
    state.claims_said = claim;
}

const Running = struct {
    pid: linux.pid_t,
    results: linux.fd_t,
    place: Planned,
    index: u32,
    start_ns: u64,
    slot: u16,
    /// Ended by the explorer, memory short under its run's learned claim (claims_look): it
    /// runs again, and is none of the kills a host is given up for.
    short: bool = false,
};

/// A tree's timelines planned from moments returned to, and those started, so far (status.json's
/// `returns_planned`, `returned`): the hunt queue ends a first pass once its first returns run
/// (hunt-queue.sh's first_pass_over), not at the judgment that plans them, which drained them
/// unrun (YugabyteDB run 2005: generation 0 judged at 28 minutes, its 6 returns never started).
var returns_planned: u32 = 0;
var returns_started: u32 = 0;

/// Each running timeline's virtual time, its worker's VM storing it (VM.progress): a page shared
/// with the workers, mapped by the explorer before its first fork; a slot a running timeline.
var timeline_vtimes: ?*[jobs_max]u64 = null;
var timeline_slots: std.StaticBitSet(jobs_max) = .empty;
/// Beside their virtual times, whether each running timeline's VM was ever admitted (its take of
/// a CPU): the others wait. Not read from the run's CPU claims, which count its verifier's
/// replays and its makers, and not a timeline finishing with its CPU given.
var timeline_admissions: ?*[jobs_max]u64 = null;
/// In a timeline's process, its own of these.
var timeline_admission: ?*u64 = null;
/// The run's learned timeline limit (timeline_limit.zig): the explorer's, fed each timeline's
/// summary as it arrives (timeline_wait); a tree's worker, forked for its one timeline, reads the
/// explorer's as it was then (learned_stop).
var timeline_learner: timeline_limit.Learner = .{};
/// The learned limit's property (report.learned_limit_property), counted by the explorer as
/// summaries arrive: timelines that ran with a learned stop, those cut there, the first of them.
/// serve's store judges it the same from the record (each line's learned_stop).
var learned_stopped: u32 = 0;
var learned_cuts: u32 = 0;
var learned_cut_first: ?u32 = null;

/// Where a timeline with no horizon of its own stops, learned: its branch point plus the run's
/// learned limit, or null while there is none.
fn learned_stop(place: Planned) ?u64 {
    const limit = timeline_learner.limit_ns() orelse return null;
    return place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s) + limit;
}

/// A finished timeline's summary for the learner: a normal end teaches it its length from the
/// branch point; a hang, a cut and a strategy's end teach it nothing.
fn learner_note(summary: *const Summary) void {
    const end: timeline_limit.Learner.End = if (summary.cut or summary.ended_early or summary.learned_cut)
        .cut_short
    else if (summary.hung)
        .hung
    else
        .normal;
    timeline_learner.note(end, summary.index, summary.end_ns -| summary.start_ns);
    if (!summary.learned_stop) return;
    learned_stopped += 1;
    if (!summary.learned_cut) return;
    learned_cuts += 1;
    learned_cut_first = @min(learned_cut_first orelse summary.index, summary.index);
}

fn timeline_vtimes_map() !*[jobs_max]u64 {
    if (timeline_vtimes) |known| return known;
    const size = std.mem.alignForward(usize, 2 * jobs_max * @sizeOf(u64), std.heap.page_size_min);
    const address = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(address) != .SUCCESS) return error.ProgressMap;
    const vtimes: *[jobs_max]u64 = @ptrFromInt(address);
    timeline_vtimes = vtimes;
    timeline_admissions = @ptrFromInt(address + @sizeOf([jobs_max]u64));
    return vtimes;
}

/// A running timeline's virtual time so far, in seconds (0 before its VM's first store).
fn timeline_vtime_s(timeline: Running) u64 {
    const vtimes = timeline_vtimes orelse return 0;
    return @atomicLoad(u64, &vtimes[timeline.slot], .monotonic) / std.time.ns_per_s;
}

/// A drain asked (SIGUSR2: serve's POST /runs/<id>/stop?drain=1): the run starts no timeline
/// more, as past its budget, and ends once those running end, each recorded. A stop that kills
/// discards them, and a resume runs them again from their start: 26 to 82% of a 15-minute first
/// pass's core time (56 hunts, 2026-11-10: the heavier the system, the longer its timelines).
var drain_requested: std.atomic.Value(bool) = .init(false);
/// The drain, where the explorer's timeline processes see it (a page shared with them, mapped
/// before the first fork): one still waiting for a CPU as it comes runs nothing (wait_over).
var drain_shared: ?*std.atomic.Value(bool) = null;
/// The process that writes the run's ending (activity.ending): the explorer, not its timelines.
var explorer_pid: linux.pid_t = 0;

fn drain_handle(_: linux.SIG) callconv(.c) void {
    drain_requested.store(true, .release);
    if (drain_shared) |shared| shared.store(true, .release);
}

fn drain_install() void {
    explorer_pid = linux.getpid();
    const address = linux.mmap(null, std.heap.page_size_min, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(address) == .SUCCESS) drain_shared = @ptrFromInt(address);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = drain_handle },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(linux.SIG.USR2, &action, null);
}

fn drained() bool {
    if (drain_requested.load(.acquire)) return true;
    const shared = drain_shared orelse return false;
    return shared.load(.acquire);
}

/// No timeline starts any more: the budget is spent, or a drain was asked.
fn past_deadline(branches: Branches) bool {
    const drain = drained();
    const past = drain or if (branches.deadline_ns) |deadline| monotonic_ns() >= deadline else false;
    if (past and linux.getpid() == explorer_pid and !ending_said.swap(true, .acq_rel)) {
        activity.ending(if (drain) "drain" else "budget");
    }
    return past;
}

/// The budget's end a timeline waiting for its CPU gives up at (wait_over), set as it asks.
var wait_deadline_ns: ?u64 = null;

/// Whether a timeline still waiting for its CPU runs no more (cpus.Pool.take_unless): the run
/// drained or past its budget, it has run nothing yet, and a resume runs it from its start.
/// Waiting on, it ran whole after the drain, beside the next hunt's VMs: Pulsar's run 1803 had
/// four at 0 s of virtual time after 53 to 56 minutes, cut at its stop, and Cassandra's 1805
/// twenty, holding its drain open.
fn wait_over() bool {
    if (drained()) return true;
    const deadline = wait_deadline_ns orelse return false;
    return monotonic_ns() >= deadline;
}

/// Whether the activity log said the explorer's ending (activity.ending): once.
var ending_said: std.atomic.Value(bool) = .init(false);

/// How long past its budget a run may go on: its last timelines and its leftover replays get
/// this, then stop. They ran beside the next hunt on its cores for as long as they took
/// (Conductor's run 443: 1.8 h of a 1 h budget, 2026-11-02). A twentieth of the budget, a minute
/// to five.
fn tail_grace_ns(budget_ns: u64) u64 {
    return std.math.clamp(budget_ns / 20, std.time.ns_per_min, 5 * std.time.ns_per_min);
}

test tail_grace_ns {
    try std.testing.expectEqual(3 * std.time.ns_per_min, tail_grace_ns(std.time.ns_per_hour));
    try std.testing.expectEqual(std.time.ns_per_min, tail_grace_ns(5 * std.time.ns_per_min));
    try std.testing.expectEqual(5 * std.time.ns_per_min, tail_grace_ns(8 * std.time.ns_per_hour));
}

/// In a child just forked from the explorer: it dies with it. A worker left running after the
/// explorer was interrupted keeps its VM, its CPU and its memory (an interrupted hunt on srv2
/// left all twelve). The signal follows the forking thread: these forks are the main thread's.
/// The kernel's OOM killer takes a timeline's process (or a replay's, or a future's) before the
/// host's own (sshd, tailscaled, dbus, podman's pause process: a host OOM once took that last
/// one, and no run could start a container after, srv3 2026-10-28) and before the explorer;
/// holders go first of all (holders.zig). A timeline it kills runs again (timeline_wait).
fn oom_before_the_host() void {
    const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), "800", 3);
    _ = linux.close(@intCast(fd));
}

fn child_dies_with(explorer: linux.pid_t) void {
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    if (linux.getppid() != explorer) linux.exit_group(1); // It died before the prctl.
    runs.running_forget(); // The run is the explorer's: it ends with it.
}

/// Starts the one timeline of `branches.plan` in a child process: a worker of one timeline, on a
/// CPU of the host's (cpus.zig); its results come back through a pipe.
fn timeline_start(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    batch: *Batch,
    state: *const TreeState,
) !Running {
    assert(branches.plan.?.len == 1);
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const vtimes = try timeline_vtimes_map();
    var free = timeline_slots;
    free.toggleAll();
    const slot: u16 = @intCast(free.findFirstSet() orelse return error.NoTimelineSlot);
    timeline_slots.set(slot);
    @atomicStore(u64, &vtimes[slot], 0, .monotonic);
    const admitted = &timeline_admissions.?[slot];
    @atomicStore(u64, admitted, 0, .monotonic);
    const explorer = linux.getpid();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        child_dies_with(explorer);
        oom_before_the_host();
        _ = linux.close(pipe[0]);
        nodes_close_but(state, branches.plan.?[0].snapshot);
        options.progress = &vtimes[slot]; // Its VM made from these (VM.init).
        timeline_admission = admitted;
        var one = Summaries{ .items = batch.scratch }; // Its own copy: sent back whole.
        var mine = branches;
        mine.summaries = &one;
        mine.next = null;
        worker_run(context, vm, options, mine, .{ .worker = 0, .jobs = 1, .results_fd = pipe[1] });
    }
    _ = linux.close(pipe[1]);
    returns_started += @intFromBool(branches.plan.?[0].path.len > 0);
    return .{
        .pid = @intCast(pid),
        .results = pipe[0],
        .place = branches.plan.?[0],
        .index = branches.plan.?[0].index,
        .start_ns = monotonic_ns(),
        .slot = slot,
    };
}

/// In a timeline's process just forked: the memory of the tree's other nodes closed (the
/// setup's stays: every timeline's path starts there). A node the tree lets go is then gone
/// with the tree's own file, where every child forked while it existed kept it open until
/// that child ended (run 2067, 27 minutes in: 37 nodes let go still alive in the children,
/// 28.3 GiB nothing claimed, beside the tree's own 32).
fn nodes_close_but(state: *const TreeState, mine: *const Snapshot) void {
    var iterator = state.users.keyIterator();
    while (iterator.next()) |snapshot| {
        if (snapshot.* == mine or snapshot.* == state.setup) continue;
        if (snapshot.*.memory_fd >= 0) _ = linux.close(snapshot.*.memory_fd);
    }
}

/// How often a tree run says what it is doing while no timeline finishes.
const progress_interval_ms = 30 * std.time.ms_per_s;
/// How often a tree run says what runs, what is queued and the memory available (activity.zig),
/// at least: its loop waits up to progress_interval_ms for a timeline to finish.
const activity_sample_ns = 10 * std.time.ns_per_s;

/// The run's state for whoever shows it (serve): `status.json` in its directory, written whole
/// (renamed into place) as timelines start and finish: those running (each since when, in
/// seconds since the epoch), those done and failing, the generation judged next.
/// Timelines running, integrated over a tree loop's wall time.
const Busy = struct {
    jobs: u32,
    start_ns: u64,
    last_ns: u64,
    running_ns: u128 = 0,

    /// `count` timelines ran since the last call.
    fn advance(busy: *Busy, count: u32) void {
        const now_ns = monotonic_ns();
        busy.running_ns += @as(u128, count) * (now_ns - busy.last_ns);
        busy.last_ns = now_ns;
    }

    /// Timelines at once, on average so far.
    fn at_once(busy: *const Busy) f64 {
        const span_ns = busy.last_ns - busy.start_ns;
        if (span_ns == 0) return 0;
        return @as(f64, @floatFromInt(busy.running_ns)) / @as(f64, @floatFromInt(span_ns));
    }

    fn print(busy: *Busy, multiverse: *report.Multiverse) void {
        busy.advance(0);
        multiverse.workers = busy.jobs;
        multiverse.at_once = busy.at_once();
        say("[determinismo] workers: {d:.1} timelines at once of {d} on average " ++
            "({d:.0}%); their VMs waited {d:.0}s for memory, {d:.0}s for a CPU\n", .{
            busy.at_once(),
            busy.jobs,
            100 * busy.at_once() / @as(f64, @floatFromInt(@max(busy.jobs, 1))),
            @as(f64, @floatFromInt(multiverse.memory_wait_ns)) / std.time.ns_per_s,
            @as(f64, @floatFromInt(multiverse.cpu_wait_ns)) / std.time.ns_per_s,
        });
    }
};

fn status_write(directory: ?[]const u8, running: []const Running, multiverse: *const report.Multiverse, generation: u32, busy: *const Busy) void {
    const known = directory orelse return;
    var buffer: [8192]u8 = undefined;
    var text: std.Io.Writer = .fixed(&buffer);
    var wall: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &wall);
    const now_ns = monotonic_ns();
    text.print("{{\"running\":[", .{}) catch return;
    for (running, 0..) |timeline, at| {
        const since_s = wall.sec - @as(i64, @intCast((now_ns - timeline.start_ns) / std.time.ns_per_s));
        text.print("{s}{{\"index\":{d},\"since_s\":{d},\"vtime_s\":{d}}}", .{ if (at == 0) "" else ",", timeline.index, since_s, timeline_vtime_s(timeline) }) catch return;
    }
    const efficiency = multiverse.efficiency();
    text.print("],\"done\":{d},\"failing\":{d},\"generation\":{d},\"at_s\":{d}," ++
        "\"workers\":{d},\"at_once\":{d:.2},\"memory_wait_s\":{d:.1},\"cpu_wait_s\":{d:.1},\"idle_share\":{d:.3}," ++
        "\"clock_reads_per_s\":{d:.0},\"per_node\":{d:.2},\"returns_planned\":{d},\"returned\":{d}}}\n", .{
        multiverse.branches,   multiverse.failing_branches,  generation,                                                             wall.sec,
        busy.jobs,             busy.at_once(),               @as(f64, @floatFromInt(multiverse.memory_wait_ns)) / std.time.ns_per_s, @as(f64, @floatFromInt(multiverse.cpu_wait_ns)) / std.time.ns_per_s,
        efficiency.idle_share, efficiency.clock_reads_per_s, efficiency.per_node,                                                    returns_planned,
        returns_started,
    }) catch return;
    status_file_write(known, text.buffered());
}

/// The run's last replays (replays.zig), its timelines all done: status.json says how many of
/// how many, as they go.
const VerifyStatus = struct {
    directory: ?[]const u8,
    multiverse: *const report.Multiverse,

    pub fn verifying(status: VerifyStatus, progress: replays.Progress) void {
        const known = status.directory orelse return;
        var buffer: [512]u8 = undefined;
        var wall: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &wall);
        const text = std.fmt.bufPrint(&buffer, "{{\"running\":[],\"done\":{d},\"failing\":{d}," ++
            "\"verifying\":{{\"replayed\":{d},\"of\":{?d}}},\"at_s\":{d}}}\n", .{
            status.multiverse.branches, status.multiverse.failing_branches, progress.replayed, progress.of, wall.sec,
        }) catch return;
        status_file_write(known, text);
    }
};

/// status.json in the run's directory, written whole (renamed into place).
fn status_file_write(known: []const u8, bytes: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staging = std.fmt.bufPrintSentinel(&path_buffer, "{s}/status.json.next", .{known}, 0) catch return;
    var final_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const final = std.fmt.bufPrintSentinel(&final_buffer, "{s}/status.json", .{known}, 0) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(staging, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), bytes.ptr, bytes.len);
    _ = linux.close(@intCast(fd));
    _ = linux.renameat(linux.AT.FDCWD, staging, linux.AT.FDCWD, final);
}

/// One line: the timelines running and those still waiting to (each with its wall time so far),
/// those done and failing. `held`: the CPUs the run's VMs hold (Pool.run_held), null unknown.
fn progress_print(running: []const Running, held: ?u32, multiverse: *const report.Multiverse, generation: u32) void {
    var line_buffer: [1024]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buffer);
    const now = monotonic_ns();
    progress_head(&line, @intCast(running.len), held) catch {};
    for (running, 0..) |timeline, at| {
        if (at == 12) {
            line.print(" ...", .{}) catch {};
            break;
        }
        line.print("{s}#{d} {d}s at {d}s", .{ if (at == 0) "" else ", ", timeline.index, (now - timeline.start_ns) / std.time.ns_per_s, timeline_vtime_s(timeline) }) catch {};
    }
    line.print("), {d} done, {d} failing, generation {d}\n", .{
        multiverse.branches, multiverse.failing_branches, generation,
    }) catch {};
    say("{s}", .{line.buffered()});
}

/// The line's start. A worker has its timeline from before its VM is admitted: those waiting
/// for memory or a CPU are not running (48 workers of 10 GiB guests on 192 GiB said "48 timelines
/// running" for an hour, 17 VMs admitted). A VM making a node holds a CPU too: the waiting are
/// then counted fewer, never more.
fn progress_head(line: *std.Io.Writer, started: u32, held: ?u32) !void {
    const admitted = @min(held orelse started, started);
    if (admitted == started) return line.print("[determinismo] {d} timelines running (", .{started});
    try line.print("[determinismo] {d} timelines running, {d} waiting for memory or a CPU (", .{
        admitted, started - admitted,
    });
}

test "timelines waiting for memory are not said to run" {
    var buffer: [160]u8 = undefined;
    const cases = [_]struct { started: u32, held: ?u32, said: []const u8 }{
        .{ .started = 48, .held = 17, .said = "17 timelines running, 31 waiting for memory or a CPU (" },
        .{ .started = 4, .held = 0, .said = "0 timelines running, 4 waiting for memory or a CPU (" },
        .{ .started = 48, .held = 48, .said = "48 timelines running (" },
        .{ .started = 8, .held = 11, .said = "8 timelines running (" }, // Node makers hold CPUs too.
        .{ .started = 8, .held = null, .said = "8 timelines running (" }, // No pool to ask.
    };
    for (cases) |case| {
        var line: std.Io.Writer = .fixed(&buffer);
        try progress_head(&line, case.started, case.held);
        try std.testing.expectEqualStrings(case.said, line.buffered()["[determinismo] ".len..]);
    }
}

const Finished = struct { at: usize, killed: bool = false };

/// Waits for one of the running timelines to finish: its results in the run's multiverse, its
/// summary in the generation filling (`summaries`). Returns which, or null when none finished
/// within `timeout_ms`. One killed (SIGKILL: the host's OOM killer) before it sent its results
/// is `killed`: it runs again (the same timeline, from the same place).
/// A finished timeline out of `running`: its place in the batch's plan beside its summary, or
/// queued again when it was killed before it finished (the host's OOM killer).
fn timeline_reaped(
    arena: std.mem.Allocator,
    state: *TreeState,
    batch: *Batch,
    running: *[jobs_max]Running,
    running_count: *u32,
    finished: Finished,
) !void {
    const place = running[finished.at].place;
    const short = running[finished.at].short;
    timeline_slots.unset(running[finished.at].slot);
    running[finished.at] = running[running_count.* - 1];
    running_count.* -= 1;
    if (finished.killed) {
        // Not served: its start snapshot's count already has it. One the explorer ended for
        // memory (claims_look) said so there, and is not the host's doing.
        if (!short) {
            state.kills += 1;
            if (state.kills > kills_max) return error.WorkerFailed;
            say("[determinismo] timeline {d} was killed (SIGKILL: the host's OOM " ++
                "killer?) before it finished: it runs again ({d} so far)\n", .{ place.index, state.kills });
        }
        try queue_plan(arena, state, place);
        return;
    }
    state.ended += 1;
    try batch.plan.append(arena, place);
    // Its holders, in the registry from now (judged or not: a late run releases them). Not one
    // summary a reap: an unstarted timeline brings none, one past the summaries' room is dropped
    // (its holders killed as it is read), and a resume loads summaries without holders.
    if (state.holding) batch_register(state.registry, batch);
}

/// The batch's summaries whose holders the registry does not have yet, added to it.
fn batch_register(registry: *holders.Registry, batch: *Batch) void {
    assert(batch.registered <= batch.summaries.count);
    for (batch.summaries.items[batch.registered..batch.summaries.count]) |*summary| {
        registry.add(summary.index, summary.holders[0..summary.holder_count]);
    }
    batch.registered = batch.summaries.count;
}

fn timeline_wait(running: []const Running, multiverse: *report.Multiverse, summaries: *Summaries, timeout_ms: i32) !?Finished {
    assert(running.len > 0);
    var polled: [jobs_max]linux.pollfd = undefined;
    for (running, polled[0..running.len]) |timeline, *entry| {
        entry.* = .{ .fd = timeline.results, .events = linux.POLL.IN | linux.POLL.HUP, .revents = 0 };
    }
    while (true) {
        const ready = linux.poll(&polled, @intCast(running.len), timeout_ms);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return error.Poll;
        if (ready == 0) return null; // None finished in time.
        break;
    }
    const at = for (polled[0..running.len], 0..) |entry, index| {
        if (entry.revents != 0) break index;
    } else unreachable;
    const timeline = running[at];
    const results = try std.heap.page_allocator.create(report.Multiverse);
    defer std.heap.page_allocator.destroy(results);
    var count: u32 = 0;
    var received = read_exact(timeline.results, std.mem.asBytes(results));
    received = received and read_exact(timeline.results, std.mem.asBytes(&count));
    received = received and count <= 1;
    if (received and count == 1) {
        // Read whole even with no slot left (past the time budget no generation is judged, and
        // they fill): unread, the worker blocks writing it, other processes holding the pipe's
        // read end, while this waits for the worker to exit (runs 177 and 200 hung so for hours).
        const room = summaries.count < summaries.items.len;
        const scratch = if (room) null else try std.heap.page_allocator.create(Summary);
        defer if (scratch) |summary| std.heap.page_allocator.destroy(summary);
        const slot = if (scratch) |summary| summary else &summaries.items[summaries.count];
        // Counted once read whole: a worker killed while it wrote leaves part of one (its
        // holders' pids among the slot's old bytes).
        received = read_exact(timeline.results, std.mem.asBytes(slot));
        if (received) learner_note(slot);
        if (received and room) summaries.count += 1;
        // Dropped: its holders, which no generation will take, go now.
        if (received and !room) for (slot.holders[0..@min(slot.holder_count, slot.holders.len)]) |held| {
            if (!held.disk) holders.kill(held.pid);
        };
    }
    _ = linux.close(timeline.results);
    var status: i32 = 0;
    _ = linux.waitpid(timeline.pid, &status, 0);
    const signaled: u32 = @bitCast(status);
    const killed = linux.W.IFSIGNALED(signaled) and linux.W.TERMSIG(signaled) == .KILL;
    if (!received and killed) return .{ .at = at, .killed = true };
    if (!received or status != 0) return error.WorkerFailed;
    if (count == 0) {
        // It ran nothing (it gave up waiting for its CPU: wait_over): its wait alone.
        activity.unstarted(timeline.index, (monotonic_ns() -| timeline.start_ns) / std.time.ns_per_ms);
    } else activity.interval(.timeline, activity.ms_of_monotonic(timeline.start_ns), activity.now_ms(), .{
        .vtime_ns = results.vtime_ns,
        .wait_ns = results.cpu_wait_ns + results.memory_wait_ns,
        .index = timeline.index,
    });
    try multiverse.absorb(results);
    return .{ .at = at };
}

/// The first failing timeline of each property, saved to disk from its holders as it is judged
/// (holders.Ladder): `b<timeline>-<ms>` at each of its in-run snapshots' moments, each diffed
/// against the one before, from the setup snapshot (saved first when it is not). Causality and
/// multiverse debugging then start from them, without the replay that otherwise saves them (a
/// YugabyteDB timeline's took longer than its exploration, srv3 2026-10-27). In a thread of
/// the explorer's (the tree goes on meanwhile), one ladder at a time: one table of page hashes.
const Ladders = struct {
    ladder: holders.Ladder,
    /// Where the run's holders go while memory runs low (holders.Disk): a failing timeline's
    /// there are kept by linking them, and the snapshots they are diffed from, into the ladder's
    /// directory (the run's end deletes the holders' own). In a hunt every holder may be on disk
    /// (memory short beside the next hunt): before this, such a run kept no failure (none of
    /// srv4's nine runs of 2026-11-10 morning), and a bundle replayed the whole timeline.
    holders_directory: ?[]const u8 = null,
    setup: *const Snapshot,
    setup_name: []const u8,
    /// The setup's page hashes, copied into the shared table before each ladder; null until the
    /// first.
    setup_hashes: ?[]u64 = null,
    explorer: linux.pid_t,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Properties (their messages' hashes) a ladder was saved for: the first failure of each.
    saved: std.AutoHashMapUnmanaged(u64, void) = .empty,

    const Job = struct { ladders: *Ladders, branch: u32, helds: []holders.Held, room: []holders.Held };

    /// A timeline judged: when it fails a property no ladder has yet, its holders nobody took
    /// are set aside and written in a thread; else they go with their generation.
    fn consider(ladders: *Ladders, arena: std.mem.Allocator, registry: *holders.Registry, summary: *const Summary) !void {
        var new = false;
        for (summary.failing[0..summary.failing_count]) |hash| {
            if (!(try ladders.saved.getOrPut(arena, hash)).found_existing) new = true;
        }
        if (!new) return;
        if (ladders.holders_directory) |from| {
            var on_disk_room: [holders.per_timeline_max + 1]holders.Held = undefined;
            const on_disk = registry.disk_of(summary.index, &on_disk_room);
            if (on_disk.len > 0) ladders.keep_disk(from, summary.index, on_disk);
        }
        const room = try std.heap.page_allocator.alloc(holders.Held, holders.per_timeline_max + 1);
        const helds = registry.set_aside(summary.index, room);
        if (helds.len == 0) {
            std.heap.page_allocator.free(room);
            return;
        }
        const job = try std.heap.page_allocator.create(Job);
        job.* = .{ .ladders = ladders, .branch = summary.index, .helds = helds, .room = room };
        const thread = try std.Thread.spawn(.{}, run, .{job});
        thread.detach();
    }

    /// A failing timeline's disk holders kept: each one whose chain of bases is whole on disk
    /// linked into the ladder's directory with its bases (their names unchanged: a load follows
    /// the bases there), and the marker serve reads. Links, no copies: no page is written again.
    fn keep_disk(ladders: *Ladders, from: []const u8, branch: u32, on_disk: []const holders.Held) void {
        const to = ladders.ladder.directory;
        var kept_names: std.ArrayList(u8) = .empty;
        defer kept_names.deinit(std.heap.page_allocator);
        var kept: u32 = 0;
        for (on_disk) |held| {
            var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
            const name = holders.Disk.name(&name_buffer, branch, held.vtime_ns);
            // The chain first, whole (a writer that failed left a gap): only then linked.
            var chain: [chain_max][Snapshot.disk_name_max]u8 = undefined;
            var lengths: [chain_max]usize = undefined;
            var depth: usize = 0;
            var current_buffer: [Snapshot.disk_name_max]u8 = undefined;
            @memcpy(current_buffer[0..name.len], name);
            var current_len = name.len;
            const whole = while (depth < chain_max) {
                const current = current_buffer[0..current_len];
                if (!Snapshot.disk_exists(from, current)) break false;
                @memcpy(chain[depth][0..current_len], current);
                lengths[depth] = current_len;
                depth += 1;
                var base_buffer: [Snapshot.disk_name_max]u8 = undefined;
                const base = Snapshot.disk_base(from, current, &base_buffer) catch break false;
                if (base.len == 0) break true;
                @memcpy(current_buffer[0..base.len], base);
                current_len = base.len;
            } else false;
            if (!whole) continue;
            for (chain[0..depth], lengths[0..depth]) |*link_name, length| {
                for ([_][]const u8{ "state", "mem" }) |kind| {
                    var from_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const source = std.fmt.bufPrintSentinel(&from_buffer, "{s}/{s}.{s}", .{ from, link_name[0..length], kind }, 0) catch continue;
                    const target = std.fmt.bufPrintSentinel(&to_buffer, "{s}/{s}.{s}", .{ to, link_name[0..length], kind }, 0) catch continue;
                    // A base another kept chain linked already: the same file.
                    _ = linux.linkat(linux.AT.FDCWD, source, linux.AT.FDCWD, target, 0);
                }
            }
            kept_names.print(std.heap.page_allocator, " {s}", .{name}) catch return;
            kept += 1;
        }
        if (kept == 0) return;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.heap.page_allocator);
        text.print(std.heap.page_allocator, "kept by the explorer from timeline {d}'s in-run snapshots on disk:{s}\n", .{ branch, kept_names.items }) catch return;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const snapshots = std.fs.path.dirname(to) orelse return;
        const marker = std.fmt.bufPrint(&path_buffer, "{s}/failure-{d}.log", .{ snapshots, branch }) catch return;
        std.Io.Dir.cwd().writeFile(ladders.io, .{ .sub_path = marker, .data = text.items }) catch {};
        say("[determinismo] ladder of timeline {d}: {d} of {d} in-run snapshots on disk kept\n", .{
            branch, kept, on_disk.len,
        });
    }

    /// A chain this deep at most (holders.zig's origin_chain_max, and a timeline's own).
    const chain_max = 4 * holders.per_timeline_max;

    fn run(job: *Job) void {
        defer {
            std.heap.page_allocator.free(job.room);
            std.heap.page_allocator.destroy(job);
        }
        const ladders = job.ladders;
        ladders.mutex.lockUncancelable(ladders.io);
        defer ladders.mutex.unlock(ladders.io);
        const setup_hashes = ladders.setup_hashes orelse ladders.setup_prepare() catch |err| {
            say("[determinismo] ladder of timeline {d}: the setup snapshot: {s}\n", .{ job.branch, @errorName(err) });
            for (job.helds) |held| holders.end(held);
            return;
        };
        @memcpy(ladders.ladder.hashes, setup_hashes);
        var base_buffer: [Snapshot.disk_name_max]u8 = undefined;
        var base: []const u8 = ladders.setup_name;
        var saved: u32 = 0;
        var names: [holders.per_timeline_max + 1][Snapshot.disk_name_max]u8 = undefined;
        var name_lengths: [holders.per_timeline_max + 1]usize = undefined;
        // After a failed write the table is no longer the base's: the rest go unsaved.
        var broken = false;
        for (job.helds) |held| {
            if (broken) {
                holders.end(held);
                continue;
            }
            switch (holders.ask_disk(ladders.explorer, held, base)) {
                .written => {},
                // Left for memory, as holders do (a YugabyteDB ladder kept 2 of 9 that way):
                // the next one is diffed against the same base.
                .gone => continue,
                .failed => {
                    broken = true;
                    continue;
                },
            }
            const name = holders.ladder_name(&names[saved], job.branch, held.vtime_ns);
            name_lengths[saved] = name.len;
            @memcpy(base_buffer[0..name.len], name);
            base = base_buffer[0..name.len];
            saved += 1;
        }
        // A marker serve reads: this failure is on disk (its own replay that saves one is not
        // needed). None when nothing was saved: the disk holders' keep_disk may have written it
        // (run 1831's timeline 12: 3 kept, then this ladder's 0 of 4 emptied its list).
        if (saved == 0) {
            say("[determinismo] ladder of timeline {d}: 0 of {d} in-run snapshots on disk\n", .{ job.branch, job.helds.len });
            return;
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.heap.page_allocator);
        text.print(std.heap.page_allocator, "saved by the explorer from timeline {d}'s in-run snapshots:", .{job.branch}) catch return;
        for (names[0..saved], name_lengths[0..saved]) |*name, length| {
            text.print(std.heap.page_allocator, " {s}", .{name[0..length]}) catch return;
        }
        text.append(std.heap.page_allocator, '\n') catch return;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        // Serve's marker, in the run's snapshots directory (above the layout's).
        const snapshots = std.fs.path.dirname(ladders.ladder.directory) orelse return;
        const marker = std.fmt.bufPrint(&path_buffer, "{s}/failure-{d}.log", .{ snapshots, job.branch }) catch return;
        std.Io.Dir.cwd().writeFile(ladders.io, .{ .sub_path = marker, .data = text.items }) catch {};
        say("[determinismo] ladder of timeline {d}: {d} of {d} in-run snapshots on disk\n", .{
            job.branch, saved, job.helds.len,
        });
    }

    /// The setup snapshot on disk (saved unless it is there) and its page hashes.
    fn setup_prepare(ladders: *Ladders) ![]u64 {
        const setup = ladders.setup;
        const size = setup.memory_size;
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, setup.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.Map;
        defer _ = linux.munmap(@ptrFromInt(address), size);
        const memory = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(address))[0..size];
        const directory = ladders.ladder.directory;
        @memset(ladders.ladder.hashes, 0); // A fresh table: every page is new.
        if (Snapshot.disk_exists(directory, ladders.setup_name)) {
            try Snapshot.pages_hash(memory, setup.memory_fd, ladders.ladder.hashes);
        } else {
            try Snapshot.disk_save(setup, memory, setup.memory_fd, ladders.ladder.hashes, directory, ladders.setup_name, null, false);
        }
        const hashes = try std.heap.page_allocator.dupe(u64, ladders.ladder.hashes);
        ladders.setup_hashes = hashes;
        return hashes;
    }
};

/// The tree explorer's state across generations (explore_tree, tree_judge).
const TreeState = struct {
    /// A resumed run's last recorded generation, left by tree_rejudge for the run's loop to
    /// judge: recorded already, its judgment is not recorded again (a later resume would stop
    /// re-judging at the second copy).
    rejudge_last: bool = false,
    base: u64,
    total: u32,
    size: u32,
    /// Branches from each moment returned to (`--return-branches`).
    children: u32,
    /// Generations in flight (`--pipeline`).
    pipeline: u32,
    jobs: u32,
    holding: bool,
    registry: *holders.Registry,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The traces explored: a timeline that repeats one is never returned to (its first was).
    traces: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// How many timelines reached each behavior (what a strategy's `returns` is told).
    visits: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    change: ?changed.Change,
    hunks_reached: []bool,
    candidates: []Candidate,
    /// Parents' tapes are read into this (their overrides), one at a time.
    tape_buffer: *tape.Overrides,
    /// The next number to plan: the tree's own once settled (index_settle).
    next_index: u32 = 0,
    /// Where the run's tapes are: a number is taken by creating its tape (tape.claim).
    tape_directory: ?[]const u8 = null,
    /// The failing timelines' holders written to disk (with a run directory).
    ladders: ?*Ladders = null,
    /// Where holders go while memory runs low (with a run directory).
    disk: ?*const holders.Disk = null,
    io: std.Io,
    /// Where the timelines that ran to their end ended (virtual time): their sum and count, for
    /// a timeline's expected end (holders' spacing).
    ends_ns_sum: u64 = 0,
    ends_count: u64 = 0,
    /// What the run's timelines found new, by virtual minute: the driver phase's length a
    /// timeline gets.
    novelty: Novelty = .{},
    /// Planned timelines, taken in order from `queue_head` (explore_tree).
    queue: std.ArrayList(Planned) = .empty,
    queue_head: u32 = 0,
    /// Where the filler begins: fresh timelines from the setup snapshot planned only to keep the
    /// CPUs busy (the pipeline's beyond its first generation, queue_fill). Planned timelines go
    /// before it (queue_push), so a judged generation's branches start as soon as it is judged.
    /// Behind the filler, a run of fewer than pipeline times generation timelines never branched:
    /// Galera's hunt (run 410, 132 timelines) and RabbitMQ's smoke (run 422, 89) were all of the
    /// first, flat searches, the tree's first returns planned after 144 fresh ones.
    filler_start: u32 = 0,
    /// A judgment's node makers wait for memory (makings_start: fewer in flight than the run's
    /// jobs, short of room for the next): no filler starts meanwhile (queue_take), as it would
    /// take the room they wait for.
    makers_short: bool = false,
    /// Memory keeps the queue's next timeline from a worker at the loop's last look
    /// (timeline_gated).
    gated: bool = false,
    /// A judgment's makers, short of memory, keep queued filler from one at that look
    /// (queue_filler_held: not a fresh one, refused since before the queue held any).
    filler_waits: bool = false,
    /// The loop's looks that held queued filler for a judgment's makers, and the queue for memory: said
    /// as the tree ends, so a run shows whether either ever acted.
    filler_held: u64 = 0,
    queue_held: u64 = 0,
    /// The disk holders of generations not judged yet fill the run's disk budget
    /// (holders.Registry.disk_full): timelines start with no disk for their holders meanwhile.
    holders_disk_full: bool = false,
    /// Each start snapshot's timelines not judged yet: freed after its last (node_served).
    users: std.AutoHashMapUnmanaged(*const Snapshot, u32) = .empty,
    /// The generation filling: judged next.
    generation: u32 = 0,
    /// Go-Explore's archive (`--archive`): each behavior's cell, and every branch planned (its
    /// seed and path: one of an earlier generation is rebuilt from the setup snapshot).
    archive: bool,
    /// The bandit over configuration draws (src/bandit.zig): each timeline forks with it.
    bandit: bandit_zig.Bandit = .{},
    /// Returns go first to sought behaviors (`--no-prefer-sometimes`: all alike).
    prefer_sometimes: bool,
    /// And to severe kinds of output lines (`--no-prefer-severe`: as any other).
    prefer_severe: bool = true,
    /// The behaviors the system's last runs reached (`--history`): one they never reached is
    /// preferred too.
    history: ?*const std.AutoHashMapUnmanaged(u64, u32) = null,
    cells: std.AutoHashMapUnmanaged(u64, Cell) = .empty,
    /// This generation's doom draws (sdk.doomed): the archive's weight on a hopeless place, and
    /// whether the frontier skips them.
    doom_weight: u64 = 1,
    doom_frontier: bool = false,
    planned: std.AutoHashMapUnmanaged(u32, Planned) = .empty,
    setup: *const Snapshot,
    /// The setup's last moment (virtual time): no return lands before it (every return replays
    /// from the setup's snapshot). Kept apart from `setup`, which tests leave undefined.
    setup_vtime_ns: u64 = 0,
    /// The setup's origin among the holders on disk, when it is the tree's root (setup ==
    /// branches.snapshot): disk nodes over the root (DiskHeld.root_origin).
    root_origin: ?holders.Origin = null,
    /// Offsets a return just after a behavior may land before it (`--return-offsets`).
    return_offsets_ns: []const u64 = &return_offsets_default,
    /// A resumed run's: recorded timelines are not run again; their summaries are judged.
    resumed: ?*const Resumed = null,
    /// Timelines killed before they finished (and queued again).
    kills: u32 = 0,
    /// Returns whose node was not made: the run's nodes held half the host's memory.
    nodes_skipped: u32 = 0,
    /// The memory of the snapshots it holds (nodes_claim_refresh).
    nodes_bytes: u64 = 0,
    /// Timelines that ran to their end, and what the run learned its VMs come to hold from the
    /// host's memory beside them (claims_look).
    ended: u64 = 0,
    claims: cpus.ClaimLearning = .{},
    claims_looked_ns: u64 = 0,
    /// The claim said last (0: the guests' size), for a line when it changes.
    claims_said: u64 = 0,

    /// Why a behavior comes first, when it does (each preference as asked).
    fn preferred(state: *const TreeState, behavior: *const Events.Behavior) Preferred {
        if (state.prefer_sometimes and behavior.sought) return .sometimes;
        if (state.prefer_severe and behavior.severe) return .severe;
        if (state.unseen(behavior.hash)) return .unseen;
        return .no;
    }

    /// A behavior the system's last runs never reached (with a history: `--history`).
    fn unseen(state: *const TreeState, hash: u64) bool {
        const history = state.history orelse return false;
        return !history.contains(hash);
    }
};

/// The memory of the snapshots the tree holds (the setup's, and each node with timelines still
/// to serve), claimed for the host's admission (cpus.nodes_claim): VMs wait while it fills it.
fn nodes_claim_refresh(state: *TreeState) void {
    var bytes: u64 = snapshot_bytes(state.setup);
    var iterator = state.users.keyIterator();
    while (iterator.next()) |snapshot| {
        if (snapshot.* != state.setup) bytes += snapshot_bytes(snapshot.*);
    }
    state.nodes_bytes = bytes;
    cpus.nodes_claim(bytes);
}

/// What a node is charged while it is made (its pages once made: nodes_claim_refresh): the mean
/// of the tree's nodes' own so far (each its differences from the root: Snapshot.base_fd), half
/// again for what a timeline grows, at most a VM's claim; a VM's claim before any (what one holds
/// of its own, once the run learned it: what a node over the root is). The VM's whole size made a
/// run under a memory limit make 1 or 2 a generation in a 24 GB unit of 4 GB VMs (run 317: 14
/// returns not made) where their pages were a fraction of it.
fn node_charge(state: *const TreeState) u64 {
    const setup = snapshot_bytes(state.setup);
    var count: u64 = 0;
    var iterator = state.users.keyIterator();
    while (iterator.next()) |snapshot| count += @intFromBool(snapshot.* != state.setup);
    if (count == 0) return vm_claim(state);
    const mean = (state.nodes_bytes -| setup) / count;
    return @min(cpus.claim_bytes, mean * 3 / 2);
}

/// The memory a snapshot's memfd holds (its pages written, not its size).
fn snapshot_bytes(snapshot: *const Snapshot) u64 {
    if (snapshot.memory_fd < 0) return 0;
    var stat: linux.Statx = undefined;
    const result = linux.statx(snapshot.memory_fd, "", linux.AT.EMPTY_PATH, .{ .BLOCKS = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return 0;
    return stat.blocks * 512;
}

/// Killed timelines a run takes before it ends (a host that keeps killing them).
const kills_max = 64;

/// Why the tree returns to a behavior first: each preference (`--no-prefer-sometimes`,
/// `--no-prefer-severe`, `--history`) says so in its own words.
const Preferred = enum {
    no,
    sometimes,
    severe,
    unseen,

    fn why(preferred: Preferred) []const u8 {
        return switch (preferred) {
            .no => unreachable,
            .sometimes => "a state the program marks worth reaching (a sometimes or reachable " ++
                "made true comes first)",
            .severe => "a kind of output line that reads as trouble (an error, a timeout: " ++
                "such lines come first)",
            .unseen => "a behavior the system's last runs never reached (with a history, " ++
                "such behaviors come first)",
        };
    }
};

/// A cell of the archive: where a behavior was first reached (the moment just after it), and how
/// often the tree returned there.
/// An archive cell: a behavior, where timelines reached it (up to `cell_places_max` timelines'
/// moments, returns going to each in turn: the same state reached from different pasts), and how
/// often the tree returned there.
const Cell = struct {
    places: [cell_places_max]Place,
    place_count: u8 = 1,
    label: []const u8,
    visits: u32 = 0,
    /// Branches of its returns that found a behavior new to the tree: a return that pays ranks
    /// it higher (seed scheduling as a bandit: EcoFuzz, USENIX Security 2020; AFL-Hier, NDSS
    /// 2021), rarity alone otherwise.
    paid: u32 = 0,
    sought: bool = false,
    severe: bool = false,
    /// Never reached by the system's last runs (`--history`).
    unseen: bool = false,
    /// An optimization's bucket (sdk.optimize): the best score reached in it, at its one place.
    best: ?f64 = null,

    /// `doomed`: after its timeline's sdk.doomed (Summary.doomed_ns).
    const Place = struct { branch: u32, vtime_ns: u64, doomed: bool = false };

    fn place(cell: *const Cell) Place {
        assert(cell.place_count >= 1 and cell.place_count <= cell_places_max);
        return cell.places[cell.visits % cell.place_count];
    }
};

const cell_places_max = 4;

/// Fixed-point resolution of a cell's rank divided by its paying returns.
const paid_scale = 16;

test "the archive returns first to a cell whose returns paid, among equally rare ones, mostly" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 64,
        .size = 16,
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    for ([_]u64{ 11, 22 }, [_]u32{ 0, 3 }) |hash, paid| {
        var cell: Cell = .{ .places = undefined, .label = "a behavior", .visits = 3, .paid = paid };
        cell.places[0] = .{ .branch = @intCast(hash), .vtime_ns = 5 };
        try state.cells.put(arena, hash, cell);
        try state.visits.put(arena, hash, 2);
    }
    // Scores 12 * 16 / 4 = 48 against 12 * 16 = 192: the paying cell first four times in five,
    // the other first sometimes (never locked out).
    var random: std.Random.DefaultPrng = .init(7);
    var paying_first: u32 = 0;
    for (0..400) |_| {
        const ranked = try archive_ranked(arena, &state, &random);
        try std.testing.expectEqual(@as(usize, 2), ranked.len);
        paying_first += @intFromBool(ranked[0].hash == 22);
    }
    try std.testing.expect(paying_first > 280 and paying_first < 360);
    const returns = try archive_returns(arena, &state, state.size, &.{}, &random);
    try std.testing.expect(returns.len >= 2);
}

test "a generation never returns twice to one moment" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 64,
        .size = 16,
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    // #0 made a sometimes true at 5 ms: the frontier returns just after it, and the behavior's
    // new cell has that one place.
    const moment = 5 * std.time.ns_per_ms;
    var cell: Cell = .{ .places = undefined, .label = "sometimes \"zero\"", .visits = 0, .paid = 0 };
    cell.places[0] = .{ .branch = 0, .vtime_ns = moment };
    try state.cells.put(arena, 9, cell);
    const frontier = [_]TreeReturn{.{ .branch = 0, .vtime_ns = moment, .why = "Just after #0 first made a sometimes true." }};
    var random: std.Random.DefaultPrng = .init(3);
    const returns = try archive_returns(arena, &state, state.size, &frontier, &random);
    for (returns, 0..) |a, i| for (returns[i + 1 ..]) |b| {
        try std.testing.expect(!(a.branch == b.branch and a.vtime_ns == b.vtime_ns));
    };
}

test "a plugin's returns are kept whole and the archive fills around them, never to a cell it took" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 256,
        .size = 64, // 12 returns a generation, 4 branches from each.
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    for ([_]u64{ 11, 22, 33 }) |hash| {
        var cell: Cell = .{ .places = undefined, .label = "a behavior", .visits = 1 };
        cell.places[0] = .{ .branch = @intCast(hash), .vtime_ns = 5 };
        try state.cells.put(arena, hash, cell);
        try state.visits.put(arena, hash, 1);
    }
    var random: std.Random.DefaultPrng = .init(7);
    // The plugin offered the archive's cells, then answered 8 returns, one to cell 22's place.
    const offered = try archive_offered(arena, &state, state.size, &random);
    try std.testing.expectEqual(@as(usize, 3), offered.len);
    const nodes = tree.nodes(state.size, state.children);
    var returns: std.ArrayList(TreeReturn) = .empty;
    for (0..8) |index| try returns.append(arena, .{
        .branch = @intCast(100 + index),
        .vtime_ns = 1,
        .why = "The strategy returned",
        .strategy = true,
        .cell = if (index == 0) 22 else null,
    });
    // The frontier's fill after them, as tree_returns makes it.
    while (returns.items.len < nodes) try returns.append(arena, .{ .branch = 200, .vtime_ns = 1, .why = "Returned to" });
    const final = try archive_returns(arena, &state, state.size, returns.items, &random);
    try std.testing.expectEqual(nodes, final.len);
    for (final[0..8], 0..) |back, index| try std.testing.expectEqual(@as(u32, @intCast(100 + index)), back.branch);
    var archived: u32 = 0;
    for (final[8..]) |back| if (back.cell) |hash| {
        try std.testing.expect(hash != 22);
        archived += 1;
    };
    // The slots left (nodes - 8) split as the explorer's alone: half the frontier, then the archive.
    try std.testing.expectEqual(@as(u32, @intCast((nodes - 8) / 2)), archived);
}

test "a strategy's wide returns leave the archive only the timelines they did not take" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 256,
        .size = 64, // 12 returns of 4 a generation: 48 timelines returned.
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    for ([_]u64{ 11, 22, 33, 44 }) |hash| {
        var cell: Cell = .{ .places = undefined, .label = "a behavior", .visits = 1 };
        cell.places[0] = .{ .branch = @intCast(hash), .vtime_ns = 5 };
        try state.cells.put(arena, hash, cell);
        try state.visits.put(arena, hash, 1);
    }
    var random: std.Random.DefaultPrng = .init(7);
    // Two returns of 16 timelines each: 32 of the 48, 16 left, 4 returns of 4.
    const returns = [_]TreeReturn{
        .{ .branch = 100, .vtime_ns = 1, .why = "The strategy returned", .strategy = true, .branches = 16 },
        .{ .branch = 101, .vtime_ns = 1, .why = "The strategy returned", .strategy = true, .branches = 16 },
        .{ .branch = 200, .vtime_ns = 1, .why = "Returned to" },
        .{ .branch = 201, .vtime_ns = 1, .why = "Returned to" },
        .{ .branch = 202, .vtime_ns = 1, .why = "Returned to" },
    };
    const final = try archive_returns(arena, &state, state.size, &returns, &random);
    try std.testing.expectEqual(@as(usize, 2 + 4), final.len);
    try std.testing.expectEqual(@as(u32, 48), returns_branches(final, state.children));
    // Half the 4 left from the frontier, then the archive.
    try std.testing.expectEqual(@as(u32, 200), final[2].branch);
    try std.testing.expectEqual(@as(u32, 201), final[3].branch);
    try std.testing.expect(final[4].cell != null and final[5].cell != null);
}

/// How much more a sought behavior (a `sometimes` or `reachable` made true) weighs than another
/// new one, in a timeline's novelty and as an archive cell (`--prefer-sometimes`): a few output
/// lines new to the tree still outweigh one, as several rare things do.
const sought_weight = 4;

/// Generations planned ahead by default (`--pipeline`): the queue starts with that many from the
/// setup snapshot, and each generation judged plans as many timelines as it had, so the queue,
/// the generation filling and the timelines running always add up to that many generations.
/// Every worker is busy while they hold at least a generation more than the workers: two for up
/// to a generation's worth of workers (16), three for more. More only delays the first returns:
/// the tree deepens from timeline `pipeline * generation` on (a system whose timelines take five
/// minutes on six workers once waited three quarters of an hour for its first branch).
const pipeline_depth_default = 3;

/// How often a judgment's nodes are looked for while timelines run (tree_judge_poll).
const judging_poll_ms = 500;

/// `--drive-max`'s default.
const drive_max_ms_default = 20 * std.time.ms_per_min;

/// The run's novelty by virtual minute from the setup snapshot: the behaviors new to the run its
/// timelines reached in each minute, and the time they explored there (each its own stretch, a
/// branch's ancestors' being theirs); each generation judged weighs twice what the one before it
/// does, so the curve follows what is still new. From it, a timeline's driver phase length
/// (det-composer's `composer.drive_ms`, a bucket k: drawn between `max >> k` and half that): the
/// marginal value theorem's, the length whose expected new behaviors per minute of the
/// timeline's cost (its length and what every timeline pays besides, its start and its ending's
/// checks: `cost_ms`) is highest. Measured on Galera's run 410 (59.6 new behaviors per explored
/// minute in the first, 1.4, 0.6, 0.2, about none from the 7th) and rqlite's (none past the
/// 2nd), where the drivers otherwise ran as long as their slowest commands. One timeline in
/// `explore_one_in` keeps det-composer's own draw, so longer lengths stay measured; so does
/// every timeline before a first generation is judged, or when nothing is new any more.
const Novelty = struct {
    origin_ns: ?u64 = null,
    found: [minutes]f64 = @splat(0),
    explored_ns: [minutes]f64 = @splat(0),
    /// The endings measured (a timeline's end past its driver phase's): their sum and count.
    ending_ns_sum: f64 = 0,
    ending_count: u32 = 0,

    const minutes = 64;
    /// det-composer's buckets (drive_drawn_ns: k from 0 to 6).
    const buckets = 7;
    const explore_one_in = 8;
    /// What a timeline costs besides its driver phase, at least: its start, and the state its
    /// drivers rebuild before they reach anything new (a cluster with data, a membership change
    /// under way), which nothing measures; Galera's ending alone took about 90 s (run 410's
    /// timeline 7: faults stopped at 195.9 s, its composer done at 287 s). rqlite's measured 1 s
    /// (its final reads): a cost that small would steer every driver phase to its shortest
    /// bucket (14 s), a choice for the A/B to make, not this rule.
    const cost_ms_min = 2 * std.time.ms_per_min;
    const endings_measured = 8;

    /// The run's mean ending (its timelines' end past their driver phase's), once enough are
    /// known, where longer than `cost_ms_min` (a system whose eventually commands wait).
    fn cost_ms(novelty: *const Novelty) u64 {
        if (novelty.ending_count < endings_measured) return cost_ms_min;
        const mean_ms: u64 = @intFromFloat(novelty.ending_ns_sum / @as(f64, @floatFromInt(novelty.ending_count)) / std.time.ns_per_ms);
        return @max(cost_ms_min, mean_ms);
    }
    /// A minute explored less than this (all timelines' time there) takes the rate before it.
    const trusted_ns: f64 = 5 * std.time.ns_per_min;

    fn judge(novelty: *Novelty, done: []const *const Summary, seen: *const std.AutoHashMapUnmanaged(u64, void)) void {
        for (&novelty.found, &novelty.explored_ns) |*found, *explored| {
            found.* /= 2;
            explored.* /= 2;
        }
        if (novelty.origin_ns == null) {
            var origin: u64 = std.math.maxInt(u64);
            for (done) |summary| origin = @min(origin, summary.start_ns);
            if (done.len > 0) novelty.origin_ns = origin;
        }
        for (done) |summary| {
            // Its ending, when its driver phase ended in it (a branch from later has none).
            if (summary.drive_end_ns) |drive_end| if (!summary.cut and drive_end > summary.start_ns and drive_end <= summary.end_ns) {
                novelty.ending_ns_sum += @floatFromInt(summary.end_ns - drive_end);
                novelty.ending_count += 1;
            };
            novelty.explore(summary.start_ns, summary.end_ns);
            for (summary.behaviors[0..summary.behavior_count]) |behavior| {
                if (behavior.vtime_ns <= summary.start_ns) continue; // Its ancestors'.
                if (seen.contains(behavior.hash)) continue;
                novelty.found[novelty.minute(behavior.vtime_ns)] += 1;
            }
        }
    }

    fn minute(novelty: *const Novelty, vtime_ns: u64) usize {
        const from = vtime_ns -| (novelty.origin_ns orelse 0);
        return @intCast(@min(from / std.time.ns_per_min, minutes - 1));
    }

    fn explore(novelty: *Novelty, start_ns: u64, end_ns: u64) void {
        const origin = novelty.origin_ns orelse 0;
        var at = @max(start_ns, origin);
        while (at < end_ns) {
            const index = novelty.minute(at);
            const minute_end = if (index == minutes - 1) end_ns else origin + (index + 1) * std.time.ns_per_min;
            const until = @min(end_ns, minute_end);
            assert(until > at);
            novelty.explored_ns[index] += @floatFromInt(until - at);
            at = until;
        }
    }

    /// New behaviors a timeline is expected to find in its first `length_ms` of virtual time.
    fn gain(novelty: *const Novelty, length_ms: u64) f64 {
        var total: f64 = 0;
        var rate: f64 = 0; // Per explored nanosecond.
        for (0..minutes) |index| {
            if (novelty.explored_ns[index] >= trusted_ns) rate = novelty.found[index] / novelty.explored_ns[index];
            const start_ms: u64 = index * std.time.ms_per_min;
            if (start_ms >= length_ms) break;
            const span_ms: u64 = @min(length_ms - start_ms, std.time.ms_per_min);
            total += rate * @as(f64, @floatFromInt(span_ms * std.time.ns_per_ms));
        }
        return total;
    }

    /// Timeline `index`'s bucket, or null for det-composer's own draw.
    fn choose(novelty: *const Novelty, max_ms: u64, index: u32) ?u8 {
        if (index % explore_one_in == explore_one_in - 1) return null;
        if (novelty.explored_ns[0] < trusted_ns) return null; // Nothing judged yet.
        var best: f64 = 0;
        var chosen: ?u8 = null;
        for (0..buckets) |k| {
            const top_ms = @max(1, max_ms >> @intCast(k));
            const mean_ms = top_ms - top_ms / 4; // Drawn evenly between half and all of it.
            const rate = novelty.gain(mean_ms) / @as(f64, @floatFromInt(mean_ms + novelty.cost_ms()));
            if (rate > best) {
                best = rate;
                chosen = @intCast(k);
            }
        }
        return chosen;
    }
};

test "a timeline's driver phase ends where the run's novelty flattened" {
    var novelty: Novelty = .{ .origin_ns = 0 };
    const minute_ns = std.time.ns_per_min;
    // Galera's curve (run 410): many new behaviors early, about none from the 7th minute.
    const found = [_]f64{ 600, 140, 60, 22, 4, 9, 86, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (found, 0..) |count, index| {
        novelty.found[index] = count;
        novelty.explored_ns[index] = 100 * minute_ns;
    }
    // Buckets of 20 minutes: 20, 10, 5, 2.5, 1.25, ...: this curve's first minute outweighs the
    // rest (all of a first generation's finds), so short; it lengthens as that is known.
    const k = novelty.choose(20 * std.time.ms_per_min, 0).?;
    try std.testing.expect(k >= 2 and k <= 4);
    // The first minute known (its finds halved away), the later finds weigh: longer.
    var later = novelty;
    later.found[0] = 6;
    try std.testing.expect(later.choose(20 * std.time.ms_per_min, 0).? < k);
    // Every eighth timeline keeps det-composer's draw; so does a run with nothing judged yet.
    try std.testing.expectEqual(@as(?u8, null), novelty.choose(20 * std.time.ms_per_min, 7));
    const empty: Novelty = .{};
    try std.testing.expectEqual(@as(?u8, null), empty.choose(20 * std.time.ms_per_min, 0));
    // Nothing new any more: det-composer's draw.
    var known: Novelty = .{ .origin_ns = 0 };
    for (0..20) |index| known.explored_ns[index] = 100 * minute_ns;
    try std.testing.expectEqual(@as(?u8, null), known.choose(20 * std.time.ms_per_min, 0));
    // Endings measured replace the default cost: long ones (here 20 minutes) favour longer
    // driver phases, as a timeline's fixed part weighs more.
    var slow_ending = novelty;
    slow_ending.ending_count = Novelty.endings_measured;
    slow_ending.ending_ns_sum = Novelty.endings_measured * 20.0 * minute_ns;
    try std.testing.expectEqual(@as(u64, 20 * std.time.ms_per_min), slow_ending.cost_ms());
    try std.testing.expect(slow_ending.choose(20 * std.time.ms_per_min, 0).? <= k);
    // A stretch explored across minutes counts in each.
    var spans: Novelty = .{ .origin_ns = 10 };
    spans.explore(10 + minute_ns / 2, 10 + 2 * minute_ns + 5);
    try std.testing.expectEqual(@as(f64, minute_ns / 2), spans.explored_ns[0]);
    try std.testing.expectEqual(@as(f64, minute_ns), spans.explored_ns[1]);
    try std.testing.expectEqual(@as(f64, 5), spans.explored_ns[2]);
}
const pipeline_depth_few_workers = 2;
const pipeline_depth_max = 4;

/// The generation filling: the timelines finished since the last was judged, where each started
/// and its summary (in `items`, reused by every generation). `scratch`: a worker's own summary.
const Batch = struct {
    plan: std.ArrayList(Planned) = .empty,
    items: []Summary,
    summaries: Summaries = .{ .items = &.{} },
    /// The first `registered` summaries' holders are in the registry (batch_register).
    registered: u32 = 0,
    scratch: []Summary,
    /// The other generation's summaries: the next fills one while the last is judged (its
    /// nodes made, Judging) in the other.
    spare: []Summary,
};

/// A generation judged but for its nodes, each made by a child process meanwhile: the explorer
/// starts and collects timelines as they are made (a judgment held its loop 82 to 148 s on
/// Galera's run 431, finished workers waiting), and plans their branches once all are
/// (tree_judge_end). One at a time.
const Judging = struct {
    generation: u32,
    start_ns: u64,
    done: []*const Summary,
    members: []u32,
    plan: std.ArrayList(Planned),
    /// The generation's summaries (`done` points into them), the batch's again once judged.
    items: []Summary,
    makings: []NodeMaking,
    making_count: u32,
    reached_count: usize,
    /// How many makings have their branches planned (judge_plan_ready), the branches so far,
    /// and the nodes made by where from (a holder in memory, one on disk, or a replay from the
    /// parent's start, along its path from the setup snapshot for an earlier generation's).
    planned: u32 = 0,
    branches_planned: u32 = 0,
    made: Made = .{},

    const Made = struct { all: u32 = 0, held: u32 = 0, disk: u32 = 0, before: u32 = 0, gone: u32 = 0, none: u32 = 0, unloaded: u32 = 0 };
};

/// A generation complete (the timelines that finished since the last): what each reached that
/// none before it had, the moments returned to (nodes made), and their branches planned at the
/// queue's end; the generation recorded unless `recording` is false (a resumed run's, judged
/// again).
fn tree_judge(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    recording: bool,
) !void {
    var judging = try tree_judge_begin(context, vm, options, branches, state, batch, recording);
    try makings_finish_all(context.arena, maker_start(vm, options, branches, state), judging.makings[0..judging.making_count], state.jobs, &state.nodes_skipped);
    try tree_judge_end(context, vm, options, branches, state, batch, &judging);
}

/// Whether every node of the generation being judged is made: the ones ready collected, those
/// that waited for room started as it comes (makings_start), the others left to make (a child
/// process each), without waiting.
fn tree_judge_poll(arena: std.mem.Allocator, start: MakerStart, branches: Branches, state: *TreeState, judging: *Judging) !bool {
    const makings = judging.makings[0..judging.making_count];
    for (makings) |*making| {
        if (making.ready or making.waiting) continue;
        var poll_fds = [_]linux.pollfd{.{ .fd = making.socket, .events = linux.POLL.IN, .revents = 0 }};
        const result = linux.poll(&poll_fds, 1, 0);
        if (linux.errno(result) == .SUCCESS and result > 0) node_make_finish(making);
    }
    // The made prefix's branches planned now (not while holders are verified: that compares
    // the nodes first, tree_judge_end): timelines start from the first nodes as later ones come.
    if (!branches.arguments.verify_holders) try judge_plan_ready(arena, branches, state, judging);
    state.makers_short = try makings_start(arena, start, makings, state.jobs, runners_keep(state), vm_claim(state), &state.nodes_skipped);
    for (makings) |making| if (!making.ready) return false;
    return true;
}

fn maker_start(vm: *VM, options: *const VM.Options, branches: Branches, state: *const TreeState) MakerStart {
    return .{
        .vm = vm,
        .options = options,
        .tape_directory = branches.arguments.tape_directory,
        .tape_buffer = state.tape_buffer,
    };
}

/// The judgment's nodes made so far, their branches planned: every made one not planned yet, in
/// the makings' order among them, each node's branches at the queue's planned end. Planned as
/// they come (tree_judge_poll), timelines start from a judgment's nodes while its others are
/// made, where before every one waited for all (ParadeDB's run 2091, its generation's 6 nodes,
/// 134.5 GiB, made before any of their 32 branches could start beside them), and then for every
/// one before it (run 2114: a first node replayed 806 s, the five made in seconds behind it).
/// Their indices go as they are planned, as a filler's do while a judgment runs: the run's
/// numbering follows the host's timing either way; each timeline replays from its own tape.
fn judge_plan_ready(arena: std.mem.Allocator, branches: Branches, state: *TreeState, judging: *Judging) !void {
    for (judging.makings[0..judging.making_count]) |*making| {
        if (!making.ready or making.planned) continue;
        making.planned = true;
        judging.planned += 1;
        try judge_plan_one(arena, branches, state, judging, making);
    }
}

fn judge_plan_one(arena: std.mem.Allocator, branches: Branches, state: *TreeState, judging: *Judging, making: *NodeMaking) !void {
    const snapshot = making.snapshot orelse return;
    const parent = making.parent;
    const back = making.back;
    const at = back.vtime_ns;
    const key: ReturnKey = .{ .generation = judging.generation + 1, .branch = parent.index, .vtime_ns = at };
    const recorded = if (state.resumed) |resumed| resumed.planned.contains(key) else false;
    const indices = try child_indices(arena, state, key, back.branches orelse state.children);
    if (indices.len == 0) {
        node_free(snapshot, branches.snapshot); // Not needed after all.
        return;
    }
    if (!recorded) report.record(.{ .planned = PlannedLine{
        .generation = key.generation,
        .branch = key.branch,
        .vtime_ns = key.vtime_ns,
        .indices = indices,
    } });
    judging.made.all += 1;
    judging.made.held += @intFromBool(making.held);
    judging.made.disk += @intFromBool(making.disk != null);
    judging.made.before += @intFromBool(making.before_holders);
    judging.made.gone += @intFromBool(making.holders_gone);
    judging.made.none += @intFromBool(making.no_holder);
    judging.made.unloaded += @intFromBool(making.unloaded);
    const path = try arena.alloc(tape.Segment, parent.path.len + 1);
    @memcpy(path[0..parent.path.len], parent.path);
    path[parent.path.len] = .{
        .branch = parent.index,
        .seed = parent.seed,
        .vtime_ns = at,
        .jitter_seed = parent.jitter_seed,
    };
    for (indices) |index| {
        try queue_push(arena, state, .{
            .index = index,
            .seed = branch_seed(state.base, index),
            .snapshot = snapshot,
            .path = path,
            .generation = judging.generation + 1,
            .why = back.why,
            .cell = back.cell,
            // A strategy's horizon as it gave it; `--horizon` drawn per timeline.
            .horizon_ns = if (back.horizon_ns) |horizon|
                at + horizon
            else if (branches.arguments.horizon_ns) |horizon|
                at + horizon_drawn(horizon, branch_seed(state.base, index))
            else
                null,
            .disk_origin = if (making.disk) |on_disk| .{ .branch = on_disk.branch, .vtime_ns = on_disk.held.vtime_ns } else null,
            .jitter_seed = parent.jitter_seed, // Its parent's clock, unless its strategy chooses one.
        });
        returns_planned += 1;
        judging.branches_planned += 1;
    }
}

/// A generation judged up to its nodes, started (tree_judge_poll collects them, tree_judge_end
/// plans their branches); its summaries and plan the Judging's, the batch's spare ones the next
/// generation's.
/// Where a timeline's returns must land before: its last randomness pull, when its checks'
/// inputs began streaming out, and when its tape was full (VM.tape_full_ns), the earliest. Past
/// a full tape's marker a child's chain stops there and never replays, nor its failures (CE53,
/// the blind Lean replica of the platform).
fn returns_before_ns(last_pull_ns: u64, checks_start_ns: ?u64, tape_full_ns: ?u64) u64 {
    return @min(last_pull_ns, @min(checks_start_ns orelse std.math.maxInt(u64), tape_full_ns orelse std.math.maxInt(u64)));
}

/// A cut timeline's moments past its last pull are open to its end (its future never drawn),
/// unless its tape was full: past the marker a child's chain never replays (CE58, the blind
/// Lean replica of the platform: the archive's places and an extension at a horizon cut).
fn open_to_end(summary: *const Summary) bool {
    return summary.cut and summary.tape_full_ns == null;
}

/// Where any return to a timeline must land before: its end, or its tape's marker if full (a
/// strategy's returns too, offered as its end: CE58).
fn returns_end(summary: *const Summary) u64 {
    return @min(summary.end_ns, summary.tape_full_ns orelse std.math.maxInt(u64));
}

test "a return lands before a full tape's marker" {
    // Its tape full at 3 s, its last pull at 9 s: returns before 3 s.
    try std.testing.expectEqual(@as(u64, 3), returns_before_ns(9, null, 3));
    try std.testing.expectEqual(@as(u64, 2), returns_before_ns(9, 2, 3));
    try std.testing.expectEqual(@as(u64, 9), returns_before_ns(9, null, null));
}

/// Each judged timeline's clock and seed as its worker ran them (its strategy may have chosen
/// them there): the plan's, which the timelines planned from it inherit, so a child's chain
/// replays its parent as it ran. The seed stayed the plan's: a strategy's seed's children
/// replayed another parent, and a node made by replay was a state the parent never had (CE23,
/// the blind Lean replica of the platform).
fn plan_adopt_ran(plan: []Planned, done: []const *const Summary) void {
    for (done) |summary| for (plan) |*entry| {
        if (entry.index != summary.index) continue;
        if (summary.jitter_seed) |jitter| entry.jitter_seed = jitter;
        if (summary.seed) |seed| entry.seed = seed;
    };
}

test "a judged timeline's plan has the seed it ran with: its children's chain replays it" {
    const summary = try std.testing.allocator.create(Summary);
    defer std.testing.allocator.destroy(summary);
    summary.index = 3;
    summary.jitter_seed = null;
    summary.seed = 0x42; // Its strategy's, at its branch.
    var plan = [_]Planned{.{ .index = 3, .seed = 7, .snapshot = undefined }};
    const done = [_]*const Summary{summary};
    plan_adopt_ran(&plan, &done);
    try std.testing.expectEqual(@as(u64, 0x42), plan[0].seed);
}

/// A targeted run's count of a timeline that ended: which hunks it ran (once each; its parents'
/// prefix too), whatever its trace (a timeline the same as an earlier one still ran them), and
/// how near the hunks none ran its lines come. Every timeline that ended counts, the last ones no
/// judgment took too: counted at judgments alone, a hunk only they ran read "NEVER RAN", and
/// "ran in n/N" divided by the timelines planned (CE39, the blind Lean replica of the platform).
fn change_count(target: *changed.Change, arena: std.mem.Allocator, reached: []bool, summary: *const Summary) void {
    target.counted += 1;
    @memset(reached, false);
    for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        const hunk = target.hunk_of(arena, behavior.name()) orelse {
            if (target.approach(arena, behavior.name())) |near| {
                target.closest[near.hunk] = @min(target.closest[near.hunk], near.distance);
            }
            continue;
        };
        if (!reached[hunk]) {
            target.timelines[hunk] += 1;
            target.first[hunk] = @min(target.first[hunk], summary.index);
        }
        reached[hunk] = true;
    }
}

fn tree_judge_begin(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    recording: bool,
) !Judging {
    assert(batch.spare.len > 0); // One judgment at a time.
    const judge_start_ns = monotonic_ns();
    const plan = &batch.plan;
    const summaries = &batch.summaries;
    const generation = state.generation;
    const arena = context.arena;
    const exploration = branches.exploration;
    // In index order (workers finish in any): what each reached that none before it had.
    // Summaries are large: their order is sorted, not them.
    // Every whole generation completed by now (judge_count): the timelines past them are the
    // next one's first, carried below.
    const judged = judge_count(@intCast(summaries.count), state.size);
    // Its returns and fresh timelines in proportion (a last, partial one: a generation's).
    const judged_size = @max(judged, state.size);
    assert(plan.items.len == summaries.count); // Both in the order timelines were reaped.
    if (state.holding) batch_register(state.registry, batch);
    const done = try arena.alloc(*const Summary, judged);
    for (done, summaries.items[0..judged]) |*entry, *summary| entry.* = summary;
    std.sort.insertion(*const Summary, done, {}, summary_before);
    const members = try arena.alloc(u32, done.len);
    for (members, done) |*member, summary| member.* = summary.index;
    if (recording) report.record(.{ .generation = .{ .number = generation, .branches = members } });
    // What each behavior new this generation was reached by: how many of its timelines.
    // Every timeline is judged against what earlier generations knew, and what it found
    // weighs more the fewer of its generation found it too (measured on the self-test maze:
    // deeper than claiming behaviors in index order, where the first timeline took all the
    // common ones and the latest of them sat past the decisions that mattered).
    var reached: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (done) |summary| for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        if (state.seen.contains(behavior.hash)) continue;
        const entry = try reached.getOrPut(arena, behavior.hash);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    state.novelty.judge(done, &state.seen);
    plan_adopt_ran(plan.items, done);
    try archive_add_judged(arena, state, plan.items, done);
    var candidate_count: u32 = 0;
    const generation_seed = state.base ^ (@as(u64, generation) *% 0x9e3779b97f4a7c15);
    var random: std.Random.DefaultPrng = .init(generation_seed);
    // Doom (sdk.doomed), drawn for this generation: how much the archive weighs a hopeless place
    // down (1, no pruning, to 64 times), and whether the frontier skips such places at all.
    state.doom_weight = @as(u64, 1) << random.random().uintAtMost(u6, 6);
    state.doom_frontier = random.random().boolean();
    for (done) |summary| {
        if (state.change) |*target| change_count(target, arena, state.hunks_reached, summary);
        // Its configuration draws: paid when it found a behavior new to the run or failed.
        var paid = summary.failing_count > 0;
        for (summary.behaviors[0..summary.behavior_count]) |behavior| {
            paid = paid or reached.contains(behavior.hash);
        }
        state.bandit.credit(summary.bandit_uses[0..summary.bandit_use_count], paid);
        if ((try state.traces.getOrPut(arena, summary.trace_hash)).found_existing) continue;
        const candidate = try frontier_choose(arena, state, summary, &reached);
        // A return that paid: its cell ranks higher from now on.
        if (candidate.novel > 0) if (state.planned.get(summary.index)) |planned| if (planned.cell) |hash| {
            if (state.cells.getPtr(hash)) |cell| cell.paid += 1;
        };
        state.candidates[candidate_count] = candidate;
        candidate_count += 1;
    }
    var new_ones = reached.keyIterator();
    while (new_ones.next()) |hash| try state.seen.put(arena, hash.*, {});
    const chosen = state.candidates[0..candidate_count];
    std.sort.insertion(Candidate, chosen, {}, candidate_before);
    memory_forget(state, &random);
    const counts = Counts{ .reached = &reached, .visits = &state.visits };
    const plugin = exploration.strategy;
    // A plugin is offered the archive's best cells beside the generation's timelines, and the
    // explorer fills around its returns with its own rule, the archive included (without it, a
    // plugin arm returned only to the frontier: the rarity plugin's chosen timelines failed a
    // quarter as often as the explorer's, raft A/B run 1347 against 1338).
    const archive = if (plugin != null) try archive_offered(arena, state, judged_size, &random) else &.{};
    var fill_fresh = false;
    var returns = try tree_returns(arena, plugin, generation, chosen, counts, &random, judged_size, state.children, &state.planned, archive, &state.cells, &fill_fresh);
    if (state.archive and !fill_fresh) returns = try archive_returns(arena, state, judged_size, returns, &random);
    returns = try returns_earlier(arena, state.return_offsets_ns, returns, &random);
    // A resumed run's recorded generation judged again: its returns are the record's, never chosen
    // again. An explorer that chooses otherwise (a newer one, on the same core: PLAN) made nodes
    // for returns nothing would run, each a replay along its path (run 2012's resume: 45 minutes
    // for 43 generations), and its record's numbering no longer the queue's.
    if (!recording) if (state.resumed) |resumed| {
        if (try recorded_returns(arena, resumed, generation + 1)) |recorded| returns = recorded;
    };
    for (done) |summary| for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        const entry = try state.visits.getOrPut(arena, behavior.hash);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    // The nodes are made at once, each replay in a child process (`state.jobs` at a time); then
    // their branches are numbered in the returns' order, as if made one after the other.
    const makings = try arena.alloc(NodeMaking, returns.len);
    const total = cpus.memory_total();
    const nodes_cap = if (total == 0) std.math.maxInt(u64) / 2 else (total -| cpus.memory_reserve()) / 2;
    var nodes_pending: u64 = 0; // The nodes being made, each charged node_charge's estimate.
    const charge = node_charge(state);
    var making_count: u32 = 0;
    var waiting = false; // A maker waits for room: those after it too.
    for (returns) |back| {
        var earlier = false;
        const parent = for (plan.items) |entry| {
            if (entry.index == back.branch) break entry;
        } else state.planned.get(back.branch) orelse continue;
        if (state.planned.get(back.branch) != null) earlier = for (plan.items) |entry| {
            if (entry.index == back.branch) break false;
        } else true;
        // A resumed run's return whose timelines are all recorded: none runs again, no node
        // (its timelines are planned from the setup snapshot, never started).
        if (state.resumed) |resumed| {
            const key: ReturnKey = .{
                .generation = generation + 1,
                .branch = back.branch,
                .vtime_ns = back.vtime_ns,
            };
            if (resumed.return_recorded(key)) {
                makings[making_count] = .{ .back = back, .parent = parent, .ready = true, .snapshot = state.setup };
                making_count += 1;
                continue;
            }
        }
        // A holder of the parent at the moment, or a little before it: no replay from the
        // parent's start. One on disk is loaded by a node maker, as a replay's node is made; an
        // earlier generation's parent has only those (Registry.kept).
        var from_disk: ?holders.Held = null;
        var before_holders = false;
        var holders_gone = false;
        var no_holder = false;
        if (state.holding) if (state.registry.take(back.branch, back.vtime_ns)) |taken| {
            if (taken.disk) |on_disk| from_disk = on_disk else {
                makings[making_count] = .{
                    .back = back,
                    .parent = parent,
                    .held = true,
                    .pid = taken.pid,
                    .socket = taken.socket,
                };
                making_count += 1;
                continue;
            }
        } else {
            // Why a replay: the moment comes before the timeline's first holder (Pulsar 1921's
            // generation 0 had 5 of its 9 nodes so), or its holders at or before it were taken
            // (one serves one return: RabbitMQ 1927 returned to one moment three times in a
            // generation) or gone (left for memory). `later` alone took both for the first.
            const first = state.registry.earliest(back.branch);
            const why = replay_why(first, back.vtime_ns);
            before_holders = why == .before_holders;
            holders_gone = why == .holders_gone;
            no_holder = why == .no_holder;
            if (first) |first_ns| say("[determinismo] tree: a return to timeline {d} at {d} ms, " ++
                "{s} at {d} ms (it began at {d} ms): a replay\n", .{
                back.branch,
                back.vtime_ns / std.time.ns_per_ms,
                if (before_holders) "before its first holder" else "its holders before it taken or gone, the first",
                first_ns / std.time.ns_per_ms,
                parent.snapshot.events.last_vtime_ns / std.time.ns_per_ms,
            }) else say("[determinismo] tree: a return to timeline {d} at {d} ms, the timeline " ++
                "keeps no holder (one of an earlier generation, its holders gone with its judgment, " ++
                "none on disk; it began at {d} ms): a replay\n", .{
                back.branch,
                back.vtime_ns / std.time.ns_per_ms,
                parent.snapshot.events.last_vtime_ns / std.time.ns_per_ms,
            });
        };
        // A node made by a replay holds a copy of its VM's memory, gigabytes, claimed once made
        // (nodes_claim_refresh): VMs wait while nodes fill memory. Up to half the host's, so
        // that VMs always have room to serve them; past it, the return is not made (as when
        // making fails). A holder's node is the holder's memory already.
        if (state.nodes_bytes + nodes_pending + charge > nodes_cap) {
            state.nodes_skipped += 1;
            continue;
        }
        nodes_pending += charge;
        makings[making_count] = .{
            .back = back,
            .parent = parent,
            // Its start snapshot is gone (an earlier generation's), or was never made (a resumed
            // run's recorded timeline): replayed along its path.
            .chain_from = if ((earlier or parent.snapshot == state.setup) and parent.path.len > 0) state.setup else null,
            .tape_directory = branches.arguments.tape_directory,
            .before_holders = before_holders,
            .holders_gone = holders_gone,
            .no_holder = no_holder,
            .disk = if (from_disk) |on_disk| .{
                .held = on_disk,
                .branch = back.branch,
                .disk = state.disk.?,
                .io = state.io,
                .root_origin = state.root_origin,
                .root_fd = state.setup.memory_fd,
            } else null,
        };
        // Room for one more maker's VM beside those in flight, each to grow to its guest's size:
        // each maker's own admission sees the memory available now, before the others have
        // grown (a judgment's 9 makers took srv4's last 10 GB under Kafka run 1910, the global
        // OOM killer, 2026-11-12). Short of it, or of a job, it waits and those after it too
        // (the returns' order): started as room comes, the explorer's loop going on
        // (makings_start; waiting here for one in flight to answer stopped the loop for 43% of
        // etcd's 12-hour run 2007).
        if (waiting or !maker_may_start(makings[0..making_count], state.jobs, cpus.memory_available(), runners_keep(state), vm_claim(state))) {
            waiting = true;
            makings[making_count].waiting = true;
            makings[making_count].waited = true;
            making_count += 1;
            continue;
        }
        if (!try maker_begin(arena, maker_start(vm, options, branches, state), &makings[making_count])) {
            nodes_pending -= charge;
            state.nodes_skipped += 1;
            continue;
        }
        making_count += 1;
    }
    state.makers_short = if (waiting) try makings_start(arena, maker_start(vm, options, branches, state), makings[0..making_count], state.jobs, runners_keep(state), vm_claim(state), &state.nodes_skipped) else false;
    // The next generation fills the spare summaries meanwhile, from those carried; this one's
    // stay the Judging's.
    const carried = summaries.count - judged;
    @memcpy(batch.spare[0..carried], summaries.items[judged..summaries.count]);
    var next_plan: std.ArrayList(Planned) = .empty;
    try next_plan.appendSlice(arena, plan.items[judged..]);
    plan.shrinkRetainingCapacity(judged);
    const judging: Judging = .{
        .generation = generation,
        .start_ns = judge_start_ns,
        .done = done,
        .members = members,
        .plan = batch.plan,
        .items = batch.items,
        .makings = makings,
        .making_count = making_count,
        .reached_count = reached.count(),
    };
    batch.items = batch.spare;
    batch.spare = &.{};
    batch.summaries = .{ .items = batch.items, .count = carried };
    batch.registered = carried; // Registered before the judgment, all of them.
    batch.plan = next_plan;
    return judging;
}

/// A judged generation's nodes all made: their branches planned before the queue's filler, and
/// the rest of the generation from the setup snapshot.
fn tree_judge_end(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    judging: *Judging,
) !void {
    const arena = context.arena;
    const done = judging.done;
    const members = judging.members;
    const plan = &judging.plan;
    const makings = judging.makings;
    const making_count = judging.making_count;
    const generation = judging.generation;
    assert(generation == state.generation);
    for (makings[0..making_count]) |*making| assert(making.ready);
    for (done) |summary| if (!summary.cut and !summary.ended_early and summary.end_ns > 0) {
        state.ends_ns_sum += summary.end_ns;
        state.ends_count += 1;
    };
    // A property's first failing timeline: its holders nobody took, to disk (Ladders).
    if (state.ladders) |ladders| for (done) |summary| {
        if (summary.failing_count > 0) try ladders.consider(arena, state.registry, summary);
    };
    // Their memory: this generation's (the ones in flight keep theirs). Their files stay till
    // the run ends (Registry.kept).
    if (state.holding) state.registry.release_listed(members);
    if (branches.arguments.verify_holders) for (makings[0..making_count]) |*making| {
        const held_node = making.snapshot orelse continue;
        if (!making.held and making.disk == null) continue;
        // The replay's own way there: an earlier generation's parent along its path, with the
        // run's tapes (a holder's making records none: replayed from its seed alone, the check
        // parted wherever a tape overrode a pull, the configuration bandit's every timeline,
        // e2e tree 2026-11-10; the holder's own run and a true replay agreed pull by pull).
        const tapes = branches.arguments.tape_directory;
        var replayed: NodeMaking = .{ .back = making.back, .parent = making.parent, .tape_directory = tapes, .chain_from = making.chain_from };
        const parent_recorded = try Recorded.load(arena, tapes, making.parent.index, making.parent.seed, state.tape_buffer);
        try node_make_start(arena, vm, options, &replayed, parent_recorded);
        node_make_finish(&replayed);
        const replay_node = replayed.snapshot orelse continue;
        snapshots_compare(making.back, held_node, replay_node);
        node_free(replay_node, branches.snapshot);
    };
    // The nodes made, their branches planned in the makings' order: those planned as they
    // came (tree_judge_poll), the rest here.
    try judge_plan_ready(arena, branches, state, judging);
    assert(judging.planned == making_count);
    const made = judging.made;
    // These timelines served their start snapshots (a snapshot goes with its last timeline;
    // the setup snapshot is everyone's: never freed).
    for (plan.items) |entry| node_served(state, entry.snapshot);
    nodes_claim_refresh(state);
    if (state.nodes_skipped > 0) {
        say("[determinismo] {d} returns not made so far: the run's nodes held half " ++
            "the host's memory\n", .{state.nodes_skipped});
    }
    // As many planned as judged: the rest start over from the setup snapshot.
    var planned = judging.branches_planned;
    while (planned < done.len) : (state.next_index += 1) {
        index_settle(state);
        if (state.next_index >= state.total) break;
        try queue_push(arena, state, .{
            .index = state.next_index,
            .seed = branch_seed(state.base, state.next_index),
            .snapshot = branches.snapshot,
            .generation = generation + 1,
            .why = "From the setup snapshot: some timelines of every generation start " ++
                "over, so the tree does not only deepen.",
        });
        planned += 1;
    }
    activity.interval(.judge, activity.ms_of_monotonic(judging.start_ns), activity.now_ms(), .{});
    activity.found(judging.reached_count, state.seen.count());
    var makers_waited: u32 = 0;
    for (makings[0..making_count]) |making| makers_waited += @intFromBool(making.waited);
    say("[determinismo] tree: generation {d}: {d} branches, {d} new behaviors " ++
        "({d} known); {d} moments returned to ({d} from holders in memory, {d} from holders on disk, " ++
        "{d} replayed from the parent's start, {d} of them before its first holder, {d} with its holders before it taken or gone, " ++
        "{d} whose timeline keeps no holder, " ++
        "{d} with a holder on disk that did not load); " ++
        "judged in {d:.1} s (timelines going on meanwhile, {d} of its makers waited for room); a timeline's ending {d:.0} s ({d} measured)\n", .{
        generation,                                                                     done.len,      judging.reached_count,                                                state.seen.count(),         made.all, made.held, made.disk, made.all - made.held - made.disk, made.before, made.gone, made.none, made.unloaded,
        @as(f64, @floatFromInt(monotonic_ns() - judging.start_ns)) / std.time.ns_per_s, makers_waited, @as(f64, @floatFromInt(state.novelty.cost_ms())) / std.time.ms_per_s, state.novelty.ending_count,
    });
    // Its summaries the spare ones again (the next judgment's).
    batch.spare = judging.items;
    plan.deinit(arena);
    state.generation += 1;
}

/// After changed code, the least virtual time a timeline must go on for the tree to return
/// there (tree_returns keeps moments a millisecond inside a timeline).
const changed_room_ns = 2 * std.time.ns_per_ms;
/// A return is this long after its moment (the behavior's event): past it, before the next
/// randomness pull (the state maze's draws follow their events by 5-10 us).
const return_after_ns = std.time.ns_per_us;

/// A timeline's frontier (Go-Explore): its rarest new behavior (the fewest of its generation
/// reached it; latest among equals) with a randomness pull after it; the branches return just
/// after it. However late: a program's choices can all sit at its end (the e2e state maze's, in
/// the last eighth of each timeline: a rule of the first four fifths never returned there).
/// Its labels point into `summary`'s behaviors: into the loop's copy of each, they named every
/// return after the timeline's last behavior (the sought e2e's all said "the guest finishes its
/// scenario"). A timeline's prefix is its ancestors': a first generation's setup lines (the
/// kernel's RETBleed warning, severe) won its frontier, a return to its start.
fn frontier_choose(
    arena: std.mem.Allocator,
    state: *TreeState,
    summary: *const Summary,
    reached: *const std.AutoHashMapUnmanaged(u64, u32),
) !Candidate {
    var novel: u32 = 0;
    var moment: ?u64 = null;
    var label: []const u8 = "";
    var changed_moment: ?u64 = null;
    var changed_label: []const u8 = "";
    var score: f64 = 0;
    var moment_reached: u32 = std.math.maxInt(u32);
    var moment_sought: Preferred = .no;
    const room_end = if (summary.cut) summary.end_ns -| std.time.ns_per_ms else summary.end_ns;
    for (summary.behaviors[0..summary.behavior_count]) |*behavior| {
        // A targeted run: when it first ran changed code itself (not in its parents'
        // prefix). Any moment with a little room after it: what follows changed code is
        // what a targeted run explores, however late it ran.
        if (state.change) |*target| if (target.hunk_of(arena, behavior.name())) |_| {
            const own = behavior.vtime_ns > summary.start_ns;
            const room = behavior.vtime_ns + changed_room_ns < summary.end_ns and
                behavior.vtime_ns < summary.last_pull_ns;
            if (own and room and changed_moment == null) {
                changed_moment = behavior.vtime_ns;
                changed_label = behavior.name();
            }
        };
        // Its ancestors' (a first generation's: the setup's), as novelty and strategies see them.
        if (behavior.vtime_ns <= summary.start_ns) continue;
        const timelines = reached.get(behavior.hash) orelse continue; // Known before.
        novel += 1;
        const sought = state.preferred(behavior);
        const weight: f64 = if (sought != .no) sought_weight else 1;
        score += weight / @as(f64, @floatFromInt(timelines));
        // A moment past its last randomness pull returns to the same timeline (a cut
        // branch's future was never drawn: open to its end). A sought behavior's moment
        // first (the rarest of them), then the rarest of the rest.
        const open = (open_to_end(summary) or behavior.vtime_ns + return_after_ns < summary.last_pull_ns) and
            !(state.doom_frontier and doomed_at(summary, behavior.vtime_ns));
        const better = if ((sought != .no) != (moment_sought != .no))
            sought != .no
        else
            timelines <= moment_reached;
        if (behavior.vtime_ns <= room_end and open and better) {
            moment = behavior.vtime_ns;
            moment_reached = timelines;
            moment_sought = sought;
            label = behavior.name();
        }
    }
    return .{
        .summary = summary,
        .novel = novel,
        .score = score,
        .moment = moment,
        .label = label,
        .sought = moment_sought,
        .changed_moment = changed_moment,
        .changed_label = changed_label,
    };
}

test frontier_choose {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = undefined;
    state.resumed = null;
    state.change = null;
    state.prefer_sometimes = true;
    state.prefer_severe = true;
    state.history = null;
    const summary = try arena.create(Summary);
    summary.start_ns = std.time.ns_per_s / 2;
    summary.end_ns = 10 * std.time.ns_per_s;
    summary.last_pull_ns = 9 * std.time.ns_per_s;
    summary.cut = false;
    summary.behavior_count = 0;
    // The setup's own line first (a first generation's timelines all have it): no frontier of
    // this timeline's, however severe (the kernel's RETBleed warning won the sought e2e's).
    const behaviors = [_]struct { name: []const u8, vtime_ns: u64, sought: bool = false, severe: bool = false }{
        .{ .name = "kernel printed \"WARNING\"", .vtime_ns = std.time.ns_per_s / 10, .severe = true },
        .{ .name = "sometimes \"marked\": true", .vtime_ns = 1 * std.time.ns_per_s, .sought = true },
        .{ .name = "always \"finishes\": true", .vtime_ns = 2 * std.time.ns_per_s },
    };
    var reached: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (behaviors, 0..) |entry, index| {
        const behavior = &summary.behaviors[index];
        behavior.* = .{ .hash = index + 1, .vtime_ns = entry.vtime_ns, .sought = entry.sought, .severe = entry.severe };
        @memcpy(behavior.label[0..entry.name.len], entry.name);
        behavior.label_size = @intCast(entry.name.len);
        summary.behavior_count += 1;
        try reached.put(arena, behavior.hash, 4);
    }
    const candidate = try frontier_choose(arena, &state, summary, &reached);
    try std.testing.expectEqual(@as(?u64, 1 * std.time.ns_per_s), candidate.moment);
    try std.testing.expectEqual(Preferred.sometimes, candidate.sought);
    try std.testing.expectEqualStrings("sometimes \"marked\": true", candidate.label);
    // Without the preference: the rarest of equals, the latest.
    state.prefer_sometimes = false;
    const plain = try frontier_choose(arena, &state, summary, &reached);
    try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_s), plain.moment);
    try std.testing.expectEqual(Preferred.no, plain.sought);
    try std.testing.expectEqualStrings("always \"finishes\": true", plain.label);
}

const Candidate = struct {
    summary: *const Summary,
    novel: u32,
    /// Its new behaviors, each weighing 1 / the timelines of its generation that reached it.
    score: f64 = 0,
    moment: ?u64,
    label: []const u8,
    /// Why its moment comes first, when it does: a `sometimes` or `reachable` made true, a line
    /// that reads as trouble, a behavior the last runs never reached.
    sought: Preferred = .no,
    /// A targeted run: when it first ran changed code (with room to go on), and which line.
    changed_moment: ?u64 = null,
    changed_label: []const u8 = "",
};

/// The returns a resumed run's record has for its generation `generation` (its timelines' paths'
/// last places), in the order their children were numbered (each one's first); null when the
/// record has none (the generation was not planned before the interruption).
fn recorded_returns(arena: std.mem.Allocator, resumed: *const Resumed, generation: u32) !?[]const TreeReturn {
    const Recorded_ = struct { first: u32, back: TreeReturn };
    var found: std.ArrayList(Recorded_) = .empty;
    var keys = resumed.planned.iterator();
    while (keys.next()) |entry| {
        if (entry.key_ptr.generation != generation or entry.value_ptr.len == 0) continue;
        try found.append(arena, .{ .first = entry.value_ptr.*[0], .back = .{
            .branch = entry.key_ptr.branch,
            .vtime_ns = entry.key_ptr.vtime_ns,
            .why = "Recorded: the return this resumed run made before its interruption.",
            .branches = @intCast(entry.value_ptr.len),
        } });
    }
    if (found.items.len == 0) return null;
    std.mem.sort(Recorded_, found.items, {}, struct {
        fn before(_: void, a: Recorded_, b: Recorded_) bool {
            return a.first < b.first;
        }
    }.before);
    const returns = try arena.alloc(TreeReturn, found.items.len);
    for (returns, found.items) |*back, item| back.* = item.back;
    return returns;
}

test recorded_returns {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var resumed: Resumed = .{};
    // Generation 3's two returns (their children numbered from 70 and from 66), and one of 4's.
    try resumed.plan_note(allocator, .{ .generation = 3, .branch = 40, .vtime_ns = 9, .indices = &.{ 70, 71 } });
    try resumed.plan_note(allocator, .{ .generation = 3, .branch = 12, .vtime_ns = 5, .indices = &.{ 66, 67, 68, 69 } });
    try resumed.plan_note(allocator, .{ .generation = 4, .branch = 70, .vtime_ns = 2, .indices = &.{98} });
    const returns = (try recorded_returns(allocator, &resumed, 3)).?;
    try std.testing.expectEqual(@as(usize, 2), returns.len);
    // In the order they were numbered, not the map's.
    try std.testing.expectEqual(@as(u32, 12), returns[0].branch);
    try std.testing.expectEqual(@as(u64, 5), returns[0].vtime_ns);
    try std.testing.expectEqual(@as(u32, 40), returns[1].branch);
    try std.testing.expectEqual(@as(?u32, 4), returns[0].branches);
    try std.testing.expectEqual(@as(?u32, 2), returns[1].branches);
    try std.testing.expectEqual(@as(?[]const TreeReturn, null), try recorded_returns(allocator, &resumed, 7));
}

test "a resumed tree keeps every return's recorded numbers, whatever ran and whatever order its nodes come in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var resumed: Resumed = .{};
    // Generation 0 is timelines 0 to 4. Its returns: #0 at 10 ms (5 and 6), a filler (7) taken
    // between the plans, #1 at 20 ms (8 and 9). Only 6, 8 and 9 finished before the stop.
    try resumed.plan_note(arena, .{ .generation = 1, .branch = 0, .vtime_ns = 10, .indices = &.{ 5, 6 } });
    try resumed.plan_note(arena, .{ .generation = 1, .branch = 1, .vtime_ns = 20, .indices = &.{ 8, 9 } });
    for ([_]u32{ 0, 1, 2, 3, 4, 6, 8, 9 }) |index| try resumed.done.put(arena, index, {});
    // #0 is back though only one of its children ran (CE32), #1 needs no node.
    const returns = (try recorded_returns(arena, &resumed, 1)).?;
    try std.testing.expectEqual(@as(usize, 2), returns.len);
    try std.testing.expect(!resumed.return_recorded(.{ .generation = 1, .branch = 0, .vtime_ns = 10 }));
    try std.testing.expect(resumed.return_recorded(.{ .generation = 1, .branch = 1, .vtime_ns = 20 }));
    var state: TreeState = undefined;
    state.resumed = &resumed;
    state.tape_directory = null;
    state.next_index = 5;
    state.total = 64;
    // The ready #1 planned first (CE33): its own numbers, the next number untouched.
    const first = try child_indices(arena, &state, .{ .generation = 1, .branch = 1, .vtime_ns = 20 }, 4);
    try std.testing.expectEqualSlices(u32, &.{ 8, 9 }, first);
    try std.testing.expectEqual(@as(u32, 5), state.next_index);
    // A filler between the plans takes 7 again (CE34): the recorded numbers passed over.
    index_settle(&state);
    try std.testing.expectEqual(@as(u32, 7), state.next_index);
    state.next_index += 1;
    const second = try child_indices(arena, &state, .{ .generation = 1, .branch = 0, .vtime_ns = 10 }, 4);
    try std.testing.expectEqualSlices(u32, &.{ 5, 6 }, second);
    // A return the record has not: fresh numbers past them.
    const fresh = try child_indices(arena, &state, .{ .generation = 2, .branch = 6, .vtime_ns = 30 }, 2);
    try std.testing.expectEqualSlices(u32, &.{ 10, 11 }, fresh);
}

const TreeReturn = struct {
    branch: u32,
    vtime_ns: u64,
    why: []const u8,
    /// The archive cell it returns to (archive_returns), credited when its branches find
    /// something new.
    cell: ?u64 = null,
    /// A strategy's horizon for this return (null: `--horizon`, or to the end).
    horizon_ns: ?u64 = null,
    /// The plugin chose it (kept whole by archive_returns, which fills around it).
    strategy: bool = false,
    /// How many timelines branch from it (null: the tree's `children`): the strategy's call.
    branches: ?u32 = null,
    /// A return just after a behavior (the frontier's, the archive's): the earliest moment
    /// returns_earlier may move it to, its branch's start; null: never moved (a strategy's, an
    /// extension, a return to changed code, a random moment).
    earliest_ns: ?u64 = null,
};

/// Where a judged branch began (virtual time): the moment its last ancestor branched it, or the
/// setup's end.
fn branch_start_ns(state: *const TreeState, branch: u32) u64 {
    const planned = state.planned.get(branch) orelse return state.setup_vtime_ns;
    if (planned.path.len == 0) return state.setup_vtime_ns;
    return planned.path[planned.path.len - 1].vtime_ns;
}

/// docs/ANTITHESIS_EXPLORATION.md's B: a return just after a behavior lands earlier by an offset
/// drawn from `offsets_ns` (`--return-offsets`; by default just after half the time, else 1, 5 or
/// 30 s before), so that a state doomed by a message already in flight, or a fault already under
/// way, gets futures where those go another way. Never before its branch's start: just after
/// then.
fn returns_earlier(
    arena: std.mem.Allocator,
    offsets_ns: []const u64,
    returns: []const TreeReturn,
    random: *std.Random.DefaultPrng,
) ![]const TreeReturn {
    if (offsets_ns.len == 0) return returns;
    const moved = try arena.dupe(TreeReturn, returns);
    for (moved, 0..) |*back, at| {
        const earliest_ns = back.earliest_ns orelse continue;
        const offset_ns = offsets_ns[random.random().uintLessThan(usize, offsets_ns.len)];
        if (offset_ns == 0 or back.vtime_ns < earliest_ns + offset_ns) continue;
        // Never onto a moment another return of the generation has: two returns there made two
        // nodes and their branches from one moment, and a resume's two planned lines under one
        // key kept the last (CE59, CE26's remainder, the blind Lean replica of the platform).
        const landing = back.vtime_ns - offset_ns;
        const taken = for (moved, 0..) |other, other_at| {
            if (other_at != at and other.branch == back.branch and other.vtime_ns == landing) break true;
        } else false;
        if (taken) continue;
        back.vtime_ns = landing;
        back.why = try std.fmt.allocPrint(arena, "{s} Landed {d} ms before that moment instead " ++
            "(an earlier return): what was already in flight there can go another way.", .{
            back.why, offset_ns / std.time.ns_per_ms,
        });
    }
    return moved;
}

test "a generation's returns, moved earlier, never meet at one moment (CE59)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = std.time.ns_per_s;
    // A frontier return and an archive place on #0, 5 s apart: an offset of 5 s moves the later
    // one onto the earlier one's moment, unless the landing is taken.
    const returns = [_]TreeReturn{
        .{ .branch = 0, .vtime_ns = 40 * s, .why = "frontier", .earliest_ns = s },
        .{ .branch = 0, .vtime_ns = 35 * s, .why = "archive", .earliest_ns = s },
    };
    for (0..64) |seed| {
        var random: std.Random.DefaultPrng = .init(seed);
        const moved = try returns_earlier(arena, &return_offsets_default, &returns, &random);
        try std.testing.expect(moved[0].vtime_ns != moved[1].vtime_ns);
    }
}

test "earlier returns move only returns just after a behavior, never before their branch's start" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = std.time.ns_per_s;
    const returns = [_]TreeReturn{
        .{ .branch = 1, .vtime_ns = 100 * s, .why = "a", .earliest_ns = 10 * s },
        .{ .branch = 2, .vtime_ns = 12 * s, .why = "b", .earliest_ns = 10 * s }, // 30 s cannot fit.
        .{ .branch = 3, .vtime_ns = 100 * s, .why = "c" }, // A strategy's: never moved.
    };
    var random: std.Random.DefaultPrng = .init(1);
    var moved_first: u32 = 0;
    for (0..64) |_| {
        const moved = try returns_earlier(arena, &.{30 * s}, &returns, &random);
        try std.testing.expectEqual(@as(u64, 70 * s), moved[0].vtime_ns);
        try std.testing.expectEqual(@as(u64, 12 * s), moved[1].vtime_ns);
        try std.testing.expectEqual(@as(u64, 100 * s), moved[2].vtime_ns);
        moved_first += 1;
    }
    try std.testing.expectEqual(@as(u32, 64), moved_first);
    // The default: just after half the time, else 1, 5 or 30 s before.
    var after: u32 = 0;
    for (0..600) |_| {
        const moved = try returns_earlier(arena, &return_offsets_default, returns[0..1], &random);
        after += @intFromBool(moved[0].vtime_ns == 100 * s);
        try std.testing.expect(moved[0].vtime_ns == 100 * s or moved[0].vtime_ns == 99 * s or
            moved[0].vtime_ns == 95 * s or moved[0].vtime_ns == 70 * s);
    }
    try std.testing.expect(after > 240 and after < 360);
    // None asked: none moved.
    const kept = try returns_earlier(arena, &.{}, &returns, &random);
    try std.testing.expectEqual(@as(u64, 100 * s), kept[0].vtime_ns);
}

/// `--return-offsets`' default (docs/ANTITHESIS_EXPLORATION.md's B): just after half the time,
/// 1, 5 or 30 s before a sixth each.
const return_offsets_max = 32;

const return_offsets_default = [_]u64{ 0, 0, 0, std.time.ns_per_s, 5 * std.time.ns_per_s, 30 * std.time.ns_per_s };

/// `--horizon`'s drawn length for one returned timeline (docs/ANTITHESIS_EXPLORATION.md's K):
/// from half to one and a half times the horizon, from the timeline's own seed, so that returned
/// branches stop at different lengths (Antithesis's stop around 129 s).
fn horizon_drawn(horizon_ns: u64, seed: u64) u64 {
    var random: std.Random.DefaultPrng = .init(seed ^ 0x686f72697a6f6e);
    return horizon_ns / 2 + random.random().uintAtMost(u64, horizon_ns);
}

test "a drawn horizon is between half and one and a half times --horizon" {
    var below: u32 = 0;
    for (0..1000) |seed| {
        const drawn = horizon_drawn(120 * std.time.ns_per_s, seed);
        try std.testing.expect(drawn >= 60 * std.time.ns_per_s and drawn <= 180 * std.time.ns_per_s);
        below += @intFromBool(drawn < 120 * std.time.ns_per_s);
    }
    try std.testing.expect(below > 400 and below < 600);
}

/// The timelines a list of returns branches into, each its own count or the tree's default.
fn returns_branches(returns: []const TreeReturn, children: u32) u32 {
    var total: u32 = 0;
    for (returns) |back| total += back.branches orelse children;
    return total;
}

/// A judged timeline, kept for returns from later generations (a strategy's archive, or ours);
/// Whether a moment of a timeline comes after its workload said its state looked hopeless.
fn doomed_at(summary: *const Summary, vtime_ns: u64) bool {
    const doomed = summary.doomed_ns orelse return false;
    return vtime_ns >= doomed;
}

/// with `--archive`, every behavior it reached that the archive lacks becomes a cell just after
/// it (a moment that leads elsewhere: before its last randomness pull, or anywhere in a cut
/// branch).
/// A judgment's timelines in the archive, in index order: each one planned (its children's
/// parent), and its places in the cells unless it repeats an earlier timeline's whole trace
/// (state.traces, or one before it in this judgment). A repeat added there was returned to as a
/// cell's next place, a node and its branches spent on a state the tree had (CE25, the blind
/// Lean replica of the platform).
fn archive_add_judged(arena: std.mem.Allocator, state: *TreeState, plan: []const Planned, done: []const *const Summary) !void {
    var traced: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (done) |summary| {
        const repeat = state.traces.contains(summary.trace_hash) or (try traced.getOrPut(arena, summary.trace_hash)).found_existing;
        try archive_add(arena, state, plan, summary, repeat);
    }
}

test "a cut timeline whose tape was full is no archive place past its marker (CE58)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 64,
        .size = 16,
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    // Cut at its horizon (100 ms), its tape full at 3 ms, its last pull bound there: behaviors at
    // 2 ms and 5 ms.
    const summary = try std.testing.allocator.create(Summary);
    defer std.testing.allocator.destroy(summary);
    summary.index = 0;
    summary.start_ns = 0;
    summary.end_ns = 100 * std.time.ns_per_ms;
    summary.last_pull_ns = 3 * std.time.ns_per_ms;
    summary.tape_full_ns = 3 * std.time.ns_per_ms;
    summary.cut = true;
    summary.doomed_ns = null;
    summary.again_ns = null;
    summary.trace_hash = 42;
    summary.behavior_count = 2;
    summary.behaviors[0] = .{ .hash = 7, .vtime_ns = 2 * std.time.ns_per_ms };
    summary.behaviors[1] = .{ .hash = 8, .vtime_ns = 5 * std.time.ns_per_ms };
    const plan = [_]Planned{.{ .index = 0, .seed = 1, .snapshot = undefined }};
    try archive_add(arena, &state, &plan, summary, false);
    try std.testing.expect(state.cells.contains(7));
    try std.testing.expect(!state.cells.contains(8));
    try std.testing.expect(!open_to_end(summary));
    try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_ms), returns_end(summary));
}

test "a repeat is no archive cell's place" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: TreeState = .{
        .base = 1,
        .total = 64,
        .size = 16,
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    // Timelines 0 and 1, one trace: 1 repeats 0, and both reached the behavior at 5 ms.
    const summaries = try std.testing.allocator.alloc(Summary, 2);
    defer std.testing.allocator.free(summaries);
    for (summaries, 0..) |*summary, index| {
        summary.index = @intCast(index);
        summary.start_ns = 0;
        summary.end_ns = 100 * std.time.ns_per_ms;
        summary.last_pull_ns = 90 * std.time.ns_per_ms;
        summary.cut = false;
        summary.doomed_ns = null;
        summary.again_ns = null;
        summary.trace_hash = 42;
        summary.behavior_count = 1;
        summary.behaviors[0] = .{ .hash = 7, .vtime_ns = 5 * std.time.ns_per_ms };
    }
    const plan = [_]Planned{ .{ .index = 0, .seed = 1, .snapshot = undefined }, .{ .index = 1, .seed = 2, .snapshot = undefined } };
    const done = [_]*const Summary{ &summaries[0], &summaries[1] };
    try archive_add_judged(arena, &state, &plan, &done);
    const cell = state.cells.get(7).?;
    try std.testing.expectEqual(@as(u32, 1), cell.place_count);
    try std.testing.expectEqual(@as(u32, 0), cell.places[0].branch);
    // Both planned: the repeat's children still have their parent.
    try std.testing.expect(state.planned.contains(0) and state.planned.contains(1));
}

fn archive_add(arena: std.mem.Allocator, state: *TreeState, plan: []const Planned, summary: *const Summary, repeat: bool) !void {
    const planned = for (plan) |entry| {
        if (entry.index == summary.index) break entry;
    } else return;
    try state.planned.put(arena, summary.index, planned);
    if (!state.archive or repeat) return;
    for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        if (behavior.vtime_ns <= summary.start_ns) continue; // Its ancestors' (reached before).
        // An objective's state: no later than just before its composer's ask (objective_place).
        const reached = behavior.vtime_ns + return_after_ns;
        const at = if (behavior.score != null) objective_place(summary, reached) else reached;
        const open = open_to_end(summary) or at < summary.last_pull_ns;
        if (!open or at >= summary.end_ns) continue;
        const entry = try state.cells.getOrPut(arena, behavior.hash);
        if (entry.found_existing) if (behavior.score) |score| {
            // An optimization's bucket: its place is its best state (Antithesis's representative
            // replaced by a better one, "Optimizing our way through Metroid"), returned to anew.
            const cell = entry.value_ptr;
            if (cell.best != null and score <= cell.best.?) continue;
            cell.places[0] = .{ .branch = summary.index, .vtime_ns = at, .doomed = doomed_at(summary, behavior.vtime_ns) };
            cell.place_count = 1;
            cell.best = score;
            cell.visits = 0;
            // A better state is an objective's payoff (its bucket is no new behavior): its cell
            // ranks as one whose returns paid.
            cell.paid += 1;
            continue;
        };
        if (entry.found_existing) {
            // A behavior reached by another timeline: one more place to return to (its exemplars,
            // every cell's: docs/ANTITHESIS_EXPLORATION.md's B; sought ones only, before).
            const cell = entry.value_ptr;
            if (cell.place_count == cell_places_max) continue;
            const known = for (cell.places[0..cell.place_count]) |known| {
                if (known.branch == summary.index) break true;
            } else false;
            if (known) continue;
            cell.places[cell.place_count] = .{ .branch = summary.index, .vtime_ns = at, .doomed = doomed_at(summary, behavior.vtime_ns) };
            cell.place_count += 1;
            continue;
        }
        entry.value_ptr.* = .{
            .places = undefined,
            .label = try arena.dupe(u8, behavior.name()),
            .sought = behavior.sought,
            .severe = behavior.severe,
            .unseen = state.unseen(behavior.hash),
            .best = behavior.score,
        };
        entry.value_ptr.places[0] = .{ .branch = summary.index, .vtime_ns = at, .doomed = doomed_at(summary, behavior.vtime_ns) };
    }
}

/// Where the tree returns for an objective's best state reached at `at`: there, or just before
/// the timeline's composer last asked whether to drive another phase when the best came after
/// it (a node's memory is sampled every two seconds: its highest often shows once the phase's
/// last commands are in). A branch from after the ask can only end; from before it, it goes on a
/// phase (Branches.again).
fn objective_place(summary: *const Summary, at: u64) u64 {
    const asked_ns = summary.again_ns orelse return at;
    const before = asked_ns -| return_after_ns;
    if (at <= before or before <= summary.start_ns + return_after_ns) return at;
    return before;
}

/// The explorer's memory forgets as it goes: each generation keeps a drawn share of what it
/// counted before (k eighths, k uniform in 0..8, drawn for the archive and the bandit apart), so
/// what the run learned lately weighs more than its first generations, and a run sometimes
/// starts its archive afresh (k = 0) or keeps it whole (k = 8). Never one rate: the share is
/// drawn, as Antithesis's explorer discards its strategies' memory now and then ("brain damage",
/// antithesis.com/blog/2026/nethack). The archive's counts: the timelines that reached each
/// behavior (never below 1 once reached: "new to the run" is `seen`'s, not these counts), each
/// cell's returns and the returns of it that paid; the bandit's draws and payoffs.
fn memory_forget(state: *TreeState, random: *std.Random.DefaultPrng) void {
    const archive_keep: u32 = random.random().uintAtMost(u32, 8);
    const bandit_keep: u32 = random.random().uintAtMost(u32, 8);
    if (archive_keep < 8) {
        var visits = state.visits.valueIterator();
        while (visits.next()) |count| count.* = @max(1, count.* * archive_keep / 8);
        var cells = state.cells.valueIterator();
        while (cells.next()) |cell| {
            cell.visits = cell.visits * archive_keep / 8;
            cell.paid = cell.paid * archive_keep / 8; // Its returns' branches: can pass its returns.
        }
    }
    state.bandit.forget(bandit_keep);
}

/// Go-Explore's selection: half the generation's moments (all of them when it found nothing
/// new) go to the archive's most promising cells: rare (few timelines reached the behavior) and
/// seldom returned to, scored (1 + timelines) * (1 + returns), ties at random; each return
/// counts.
fn archive_returns(
    arena: std.mem.Allocator,
    state: *TreeState,
    size: u32,
    returns: []const TreeReturn,
    random: *std.Random.DefaultPrng,
) ![]const TreeReturn {
    const nodes = tree.nodes(size, state.children);
    // A plugin's returns first (tree_returns puts them there), kept whole; the slots left split
    // as the explorer's alone: half the frontier, when it found something new, then the archive.
    var taken: usize = 0;
    while (taken < returns.len and returns[taken].strategy) taken += 1;
    const frontier = returns[taken..];
    // The timelines its returns' branches left, in the tree's `children` each.
    const slots = (nodes * state.children -| returns_branches(returns[0..taken], state.children)) / state.children;
    const novel = frontier.len > 0 and !std.mem.startsWith(u8, frontier[0].why, "A random moment");
    const keep: usize = if (novel) @min(frontier.len, (slots + 1) / 2) else 0;
    var list: std.ArrayList(TreeReturn) = .empty;
    try list.appendSlice(arena, returns[0..taken]);
    try list.appendSlice(arena, frontier[0..keep]);
    if (state.cells.count() == 0) return list.items;
    const ranked = try archive_ranked(arena, state, random);
    next: for (ranked) |cell_ranked| {
        if (list.items.len >= taken + slots) break;
        for (returns[0..taken]) |chosen| if (chosen.cell == cell_ranked.hash) continue :next;
        const cell = state.cells.getPtr(cell_ranked.hash).?;
        const place = cell.place();
        // Never a moment this generation returns to already (the frontier's, a plugin's): two
        // returns there gave it 8 timelines from one moment and 2 moments where 3 were planned,
        // its second node replayed from the parent's start (CE26, the blind Lean replica of the
        // platform: a new behavior's cell ranks first while its visits are not counted yet).
        for (list.items) |planned| if (planned.branch == place.branch and planned.vtime_ns == place.vtime_ns) continue :next;
        cell.visits += 1;
        try list.append(arena, .{
            .branch = place.branch,
            .vtime_ns = place.vtime_ns,
            .why = try std.fmt.allocPrint(arena, "Go-Explore's archive: back to just after {s}, " ++
                "as #{d} reached it ({d} timelines reached it, from {d} places kept); returned " ++
                "there {d} times, {d} of its branches finding something new.", .{
                cell.label,  place.branch, state.visits.get(cell_ranked.hash) orelse 0, cell.place_count,
                cell.visits, cell.paid,
            }),
            .cell = cell_ranked.hash,
            .earliest_ns = branch_start_ns(state, place.branch) + return_after_ns,
        });
    }
    return list.items;
}

const Ranked = struct { hash: u64, score: u64, key: f64 };

/// The archive's cells in a weighted random order: each comes before the others in proportion to
/// 1 / score (weighted sampling without replacement, Efraimidis and Spirakis 2006: ranked by score
/// times an exponential draw). Scored (1 + timelines) * (1 + returns): rare (few timelines
/// reached the behavior) and seldom returned to come far more often, and less as they are
/// explored, but every cell can come (2026-11-10: "if the count is low for one branch,
/// then the chance of it being triggered more times increases"). The order was the scores' before,
/// greedy: a cell just past the slots never came while the ones above it stayed.
fn archive_ranked(arena: std.mem.Allocator, state: *TreeState, random: *std.Random.DefaultPrng) ![]Ranked {
    const ranked = try arena.alloc(Ranked, state.cells.count());
    var iterator = state.cells.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const timelines: u64 = state.visits.get(entry.key_ptr.*) orelse 0;
        // A sought cell, or a severe one, ranks as one a few times rarer (lower scores go first).
        const preferred = (state.prefer_sometimes and entry.value_ptr.sought) or
            (state.prefer_severe and entry.value_ptr.severe) or entry.value_ptr.unseen;
        const prefers = state.prefer_sometimes or state.prefer_severe or state.history != null;
        const weight: u64 = if (prefers and !preferred) sought_weight else 1;
        // An objective's bucket by its returns alone (since its best last improved): buckets
        // explored evenly however many timelines reach them, as Antithesis's are. A cell whose
        // returns paid ranks as one that many times rarer.
        const rarity = if (entry.value_ptr.best != null)
            1 + @as(u64, entry.value_ptr.visits)
        else
            (1 + timelines) * (1 + @as(u64, entry.value_ptr.visits)) * weight;
        const doom: u64 = if (entry.value_ptr.place().doomed) state.doom_weight else 1;
        const score = rarity * doom * paid_scale / (1 + @as(u64, entry.value_ptr.paid));
        const exponential = random.random().floatExp(f64);
        ranked[index] = .{ .hash = entry.key_ptr.*, .score = score, .key = @as(f64, @floatFromInt(@max(score, 1))) * exponential };
    }
    std.sort.pdq(Ranked, ranked, {}, struct {
        fn before(_: void, a: Ranked, b: Ranked) bool {
            return if (a.key != b.key) a.key < b.key else a.hash < b.hash;
        }
    }.before);
    return ranked;
}

/// The archive's most promising cells offered to a plugin with the generation's timelines (as
/// archive_returns would take them: each at the place its next return goes): twice the nodes.
fn archive_offered(
    arena: std.mem.Allocator,
    state: *TreeState,
    size: u32,
    random: *std.Random.DefaultPrng,
) ![]const ArchiveOffer {
    if (!state.archive or state.cells.count() == 0) return &.{};
    const ranked = try archive_ranked(arena, state, random);
    const count = @min(ranked.len, 2 * tree.nodes(size, state.children));
    const offered = try arena.alloc(ArchiveOffer, count);
    for (ranked[0..count], offered) |cell_ranked, *offer| {
        const cell = state.cells.getPtr(cell_ranked.hash).?;
        const place = cell.place();
        offer.* = .{ .hash = cell_ranked.hash, .cell = .{
            .branch = place.branch,
            .vtime_ns = place.vtime_ns,
            .label = cell.label,
            .timelines = state.visits.get(cell_ranked.hash) orelse 0,
            .returns = cell.visits,
            .paid = cell.paid,
        } };
    }
    return offered;
}

const ArchiveOffer = struct { hash: u64, cell: Strategy.ArchiveCell };

/// Where the next generation returns: the strategy's choice when it makes one; else the
/// branches with the most new behaviors, just after the last of them that leaves room (Go-
/// Explore's frontier), or a random moment of a branch when nothing was new.
/// A generation's behavior counts: how many of its timelines reached each behavior new to it,
/// and how many timelines of earlier generations reached each.
const Counts = struct {
    reached: *const std.AutoHashMapUnmanaged(u64, u32),
    visits: *const std.AutoHashMapUnmanaged(u64, u32),
};

fn tree_returns(
    arena: std.mem.Allocator,
    strategy: ?*Strategies,
    generation: u32,
    chosen: []const Candidate,
    counts: Counts,
    random: *std.Random.DefaultPrng,
    size: u32,
    children: u32,
    /// Every branch planned before: a strategy may return to any of them (its own archive).
    planned: *const std.AutoHashMapUnmanaged(u32, Planned),
    /// The explorer's archive cells offered with them (archive_offered).
    archive: []const ArchiveOffer,
    cells: ?*std.AutoHashMapUnmanaged(u64, Cell),
    /// Set when the strategy wants the timelines its returns leave started fresh, not filled
    /// with the explorer's returns.
    fill_fresh: *bool,
) ![]const TreeReturn {
    var list: std.ArrayList(TreeReturn) = .empty;
    const nodes = tree.nodes(size, children);
    fill_fresh.* = false;
    if (strategy) |plugin| {
        const offered = try arena.alloc(Strategy.Candidate, chosen.len);
        for (chosen, offered) |candidate, *offer| offer.* = .{
            .branch = candidate.summary.index,
            .start_ns = candidate.summary.start_ns,
            .end_ns = returns_end(candidate.summary),
            .novel = candidate.novel,
            .moment_ns = candidate.moment,
            .label = candidate.label,
            .behaviors = if (plugin.wants_behaviors)
                try behaviors_offered(arena, candidate.summary, counts)
            else
                &.{},
        };
        const cells_offered = try arena.alloc(Strategy.ArchiveCell, archive.len);
        for (archive, cells_offered) |offer, *cell| cell.* = offer.cell;
        // The generation's shape is the strategy's: how many moments, how many timelines from
        // each (the whole generation if it likes), and whether what it leaves starts fresh.
        const answer = try plugin.returns(arena, generation, offered, cells_offered, nodes, children, size);
        fill_fresh.* = answer.fill == .fresh;
        for (answer.returns) |back| {
            // A timeline of this generation: within its span. Of an earlier one: the strategy's
            // archive; a moment outside its span makes no node (the replay says why).
            const candidate = for (chosen) |candidate| {
                if (candidate.summary.index == back.branch) break candidate;
            } else null;
            if (candidate) |known| {
                const summary = known.summary;
                if (back.vtime_ns <= summary.start_ns or back.vtime_ns >= returns_end(summary)) continue;
            } else if (!planned.contains(back.branch)) continue;
            const reason = if (back.reason.len > 0) back.reason else "(it gave no reason)";
            // An archive cell's place: the cell credited as the explorer's own return would be.
            const cell_hash: ?u64 = for (archive) |offer| {
                if (offer.cell.branch == back.branch and offer.cell.vtime_ns == back.vtime_ns) break offer.hash;
            } else null;
            if (cell_hash) |hash| if (cells) |all| if (all.getPtr(hash)) |cell| {
                cell.visits += 1;
            };
            try list.append(arena, .{
                .branch = back.branch,
                .vtime_ns = back.vtime_ns,
                .horizon_ns = back.horizon_ns,
                .why = try std.fmt.allocPrint(arena, "The strategy returned to #{d} here: {s}", .{
                    back.branch, reason,
                }),
                .cell = cell_hash,
                .strategy = true,
                .branches = back.branches,
            });
        }
        // Fewer moments than asked: the explorer's own choices fill the rest, so a strategy that
        // knows only a few good moments costs the generation no depth (Tetris's deepest.py
        // returned to one or two, and fresh games took the rest: run 161).
    }
    // The explorer's own fill takes the timelines the strategy's branches left, `children` each
    // (none when it asked for fresh starts).
    const strategy_count = list.items.len;
    const fill_nodes = if (fill_fresh.*) 0 else (nodes * children -| returns_branches(list.items, children)) / children;
    next: for (chosen) |candidate| {
        if (list.items.len >= strategy_count + fill_nodes) break;
        const summary = candidate.summary;
        for (list.items) |taken| if (taken.branch == summary.index) continue :next;
        // Only moments before its last randomness pull lead elsewhere. Microseconds can be all
        // there is: margins of a millisecond moved the state maze's returns before the
        // transitions they followed, and left its children (30 us from their start to their
        // last draw) out.
        const end_ns = @min(summary.end_ns, summary.last_pull_ns);
        const span = end_ns -| summary.start_ns;
        if (span < 2 * return_after_ns) continue;
        const extend = open_to_end(summary) and candidate.novel > 0 and candidate.changed_moment == null;
        const after = if (candidate.changed_moment) |moment|
            moment + return_after_ns
        else if (extend)
            summary.end_ns -| std.time.ns_per_ms
        else if (candidate.moment) |moment|
            moment + return_after_ns
        else
            summary.start_ns + random.random().uintLessThan(u64, span);
        const at = std.math.clamp(
            after,
            summary.start_ns + return_after_ns,
            end_ns - return_after_ns,
        );
        const why = if (extend)
            try std.fmt.allocPrint(arena, "Extended #{d} from where it stopped: it reached " ++
                "{d} behaviors no timeline before it had (the rarest, {s}).", .{
                summary.index, candidate.novel, candidate.label,
            })
        else if (candidate.changed_moment != null)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first ran changed " ++
                "code ({s}): a targeted run explores what follows it.", .{
                summary.index, candidate.changed_label,
            })
        else if (candidate.moment != null and candidate.sought != .no)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first reached " ++
                "{s}, {s}, of the {d} behaviors no timeline before it had: its frontier.", .{
                summary.index, candidate.label, candidate.sought.why(), candidate.novel,
            })
        else if (candidate.moment != null)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first reached " ++
                "{s}, the rarest of the {d} behaviors no timeline before it had: its " ++
                "frontier.", .{
                summary.index, candidate.label, candidate.novel,
            })
        else
            try std.fmt.allocPrint(arena, "A random moment of #{d}: no timeline of this " ++
                "generation reached anything new, so a moment is chosen at random.", .{
                summary.index,
            });
        try list.append(arena, .{
            .branch = summary.index,
            .vtime_ns = at,
            .why = why,
            .earliest_ns = if (!extend and candidate.changed_moment == null and candidate.moment != null)
                summary.start_ns + return_after_ns
            else
                null,
        });
    }
    return list.items;
}

/// A timeline's own behaviors (after it began), with their counts, for a strategy's `returns`.
fn behaviors_offered(
    arena: std.mem.Allocator,
    summary: *const Summary,
    counts: Counts,
) ![]const Strategy.Behavior {
    var offered: std.ArrayList(Strategy.Behavior) = .empty;
    for (summary.behaviors[0..summary.behavior_count]) |*behavior| {
        if (behavior.vtime_ns <= summary.start_ns) continue; // Its parents'.
        try offered.append(arena, .{
            .label = behavior.name(),
            .vtime_ns = behavior.vtime_ns,
            .new_in_generation = counts.reached.get(behavior.hash) orelse 0,
            .timelines_before = counts.visits.get(behavior.hash) orelse 0,
        });
    }
    return offered.items;
}

fn candidate_before(_: void, a: Candidate, b: Candidate) bool {
    // Timelines that ran changed code first (targeted runs), then the most novel.
    if ((a.changed_moment != null) != (b.changed_moment != null)) return a.changed_moment != null;
    if (a.score != b.score) return a.score > b.score;
    return a.summary.index < b.summary.index;
}

fn summary_before(_: void, a: *const Summary, b: *const Summary) bool {
    return a.index < b.index;
}

/// The overrides of branch `index`'s tape in `directory` (null when it has no tape).
/// A branch's tape (beside its ancestors'): the decisions overridden in it, by a strategy or by
/// the explorer's own steering (Novelty), and its checkpoints; null when there is none. Plain
/// reads: the forked node maker reads its ancestors' too.
/// What a holder replays with, to a moment later than its own (node_make, in the holder).
const HolderMaker = struct {
    arena: std.mem.Allocator,
    options: *const VM.Options,
    /// The timeline running (its tape so far: what was decided in it until now).
    tape_directory: ?[]const u8,
    index: u32 = 0,
    buffer: *tape.Overrides,

    fn make(
        context: *anyopaque,
        vm: *VM,
        from: *const Snapshot,
        seed: u64,
        vtime_ns: u64,
        point: VM.Hold.Point,
    ) anyerror!*const Snapshot {
        const maker: *HolderMaker = @ptrCast(@alignCast(context));
        const start_ms = activity.now_ms();
        const recorded = try Recorded.load(maker.arena, maker.tape_directory, maker.index, seed, maker.buffer);
        const made = try node_core.from_hold(maker.arena, vm, maker.options, from, recorded, vtime_ns, point);
        activity.interval(.node_memory, start_ms, activity.now_ms(), .{});
        return made;
    }
};

/// A tree node in the making: a child process replays its parent to the moment, freezes it and
/// hands the snapshot over (its memory's memfd through the socket, fd_pass); or a holder of the
/// parent at or before the moment does (holders.zig), with the same protocol.
const NodeMaking = struct {
    back: TreeReturn,
    parent: Planned,
    /// Set for a parent of an earlier generation: replayed from this (the setup snapshot) along
    /// its path, ancestor by ancestor, then to the moment.
    chain_from: ?*const Snapshot = null,
    /// Where the ancestors' tapes are: each replayed with what was decided in it beyond its seed.
    tape_directory: ?[]const u8 = null,
    /// Made by a holder (else by a replay).
    held: bool = false,
    /// Replayed from the parent's start for a moment before the parent's first holder (it has
    /// later ones): nothing to start from nearer, by design.
    before_holders: bool = false,
    /// Replayed from the parent's start although it had holders at or before the moment: taken
    /// by another return (a holder serves one) or gone (left for memory).
    holders_gone: bool = false,
    /// Replayed from its parent's start: its timeline keeps no holder at all (replay_why).
    no_holder: bool = false,
    /// Loaded from a holder on disk (holders.Disk), then replayed on to the moment as a holder
    /// does; a replay from the parent's start when it cannot be loaded (null again then, and
    /// `unloaded` set: node_make_finish).
    disk: ?DiskHeld = null,
    /// Its holder on disk did not load: replayed from the parent's start.
    unloaded: bool = false,
    pid: linux.pid_t = 0,
    socket: linux.fd_t = -1,
    /// Null when the moment could not be reached (the child said why).
    snapshot: ?*const Snapshot = null,
    /// Nothing to make (a resumed run's return whose timelines are recorded).
    ready: bool = false,
    /// Its branches planned (judge_plan_ready): once, whenever it was made among the others.
    planned: bool = false,
    /// Not started yet: short of room for its VM beside the makers in flight, or of a job
    /// (maker_may_start) when its judgment began. The judgment's poll starts it as room comes,
    /// the explorer's loop going on meanwhile (makings_start).
    waiting: bool = false,
    /// It waited so (the generation's line counts them).
    waited: bool = false,
};

fn node_make_start(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    making: *NodeMaking,
    /// The parent, recorded (its seed and its tape, loaded before the fork).
    parent_recorded: Recorded,
) !void {
    var pair: [2]i32 = undefined;
    const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, flags, 0, &pair)) != .SUCCESS) {
        return error.Socketpair;
    }
    const explorer = linux.getpid();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        child_dies_with(explorer);
        close(pair[0]);
        const start_ms = activity.now_ms();
        // A replay to the node's moment: on a CPU of the host's (cpus.zig), until it is made.
        var pool: cpus.Pool = undefined;
        pool.open() catch linux.exit_group(1);
        pool.first = true; // The generation's branches wait for every node (cpus.Pool.first).
        const cpu = pool.take();
        // Its wait for that CPU, in its interval (`w`): a judgment's makers beside a hunt's
        // timelines on every core (Kafka 1928's 9, 47 to 204 s each).
        const waited_ns = (activity.now_ms() -| start_ms) * std.time.ns_per_ms;
        const parent = making.parent;
        const at = making.back.vtime_ns;
        // The parent's segment on its clock (Planned.jitter_seed), its ancestors each on theirs
        // (its path's segments, from the run's options).
        var parent_options = options.*;
        if (parent.jitter_seed) |jitter| parent_options.tsc_jitter_seed = jitter;
        var from = parent.snapshot;
        assert(parent_recorded.seed == parent.seed);
        if (making.disk) |on_disk| if (disk_node(arena, vm, &parent_options, on_disk, parent_recorded, at)) |snapshot| {
            pool.give(cpu);
            activity.interval(.node_disk, start_ms, activity.now_ms(), .{ .wait_ns = waited_ns });
            fd_pass.send(pair[1], snapshot.memory_fd) catch linux.exit_group(1);
            write_all(pair[1], std.mem.asBytes(snapshot));
            write_all(pair[1], &.{node_loaded}); // From the holder on disk (node_make_finish).
            linux.exit_group(0);
        } else |err| say("[determinismo] tree: holder {d}ns of branch {d} not loaded " ++
            "from disk ({s}): a replay\n", .{ on_disk.held.vtime_ns, parent.index, @errorName(err) });
        if (making.chain_from) |setup| {
            from = setup;
            // Each ancestor with its own tape (its overrides), read in turn into one table.
            const ancestor = tape.Overrides.create(arena) catch linux.exit_group(1);
            var failure: ?node_core.ChainFailure = null;
            from = node_core.chain(arena, vm, options, from, parent.path, making.tape_directory, ancestor, &failure) catch |err| {
                const segment = failure.?.segment;
                if (failure.?.tape_unread) {
                    say("[determinismo] tree: branch {d}'s tape unread: {s}\n", .{ segment.branch, @errorName(err) });
                } else say("[determinismo] tree: no snapshot at {d}ns of branch {d}'s path: {s}\n", .{
                    segment.vtime_ns, segment.branch, @errorName(err),
                });
                linux.exit_group(1);
            };
        }
        const snapshot = node_make(arena, vm, &parent_options, from, parent_recorded, at, parent.path.len > 0) catch |err| {
            say("[determinismo] tree: no snapshot at {d}ns of branch {d}: {s}\n", .{
                at, parent.index, @errorName(err),
            });
            linux.exit_group(1);
        };
        // Its CPU back before the answer: the explorer may read another's first, one waiting for
        // a CPU (a pool of two, both held by makers writing to an explorer reading a third that
        // waited for one: an e2e deadlocked, srv3 2026-10-28).
        pool.give(cpu);
        activity.interval(.node_replay, start_ms, activity.now_ms(), .{ .wait_ns = waited_ns });
        fd_pass.send(pair[1], snapshot.memory_fd) catch linux.exit_group(1);
        // Everything else is plain data, or set up before the fork (the same in the explorer).
        write_all(pair[1], std.mem.asBytes(snapshot));
        write_all(pair[1], &.{node_replayed}); // A replay, whatever was to be loaded.
        linux.exit_group(0);
    }
    close(pair[1]);
    making.pid = @intCast(pid);
    making.socket = pair[0];
}

/// Whether another node maker's VM of `claim` bytes fits beside `in_flight` makers, each counted
/// at its whole claim (they grow to it as they replay), with `reserve` left: 0 available is
/// unknown, never a reason to wait.
fn maker_room(available: u64, reserve: u64, claim: u64, in_flight: u32) bool {
    if (available == 0) return true;
    return reserve + (@as(u64, in_flight) + 1) * claim <= available;
}

test maker_room {
    const gib = 1 << 30;
    // Run 1910's judgment: 12 GB available, 3 GB VMs, an 8 GB reserve: one maker at a time.
    try std.testing.expect(maker_room(12 * gib, 8 * gib, 3 * gib, 0));
    try std.testing.expect(!maker_room(12 * gib, 8 * gib, 3 * gib, 1));
    // With room, a whole burst.
    try std.testing.expect(maker_room(50 * gib, 8 * gib, 3 * gib, 8));
    try std.testing.expect(maker_room(0, 8 * gib, 3 * gib, 40));
}

/// A holder on disk, for a node maker to load.
const DiskHeld = struct {
    held: holders.Held,
    branch: u32,
    disk: *const holders.Disk,
    io: std.Io,
    /// The tree's root among the holders on disk (its setup's origin) and its memfd: a chain
    /// reaching it loads as a node over the root (Snapshot.disk_load's `root`).
    root_origin: ?holders.Origin = null,
    root_fd: linux.fd_t = -1,
};

/// The node at `vtime_ns` from a holder on disk: its snapshot itself at its own moment, else a
/// replay on from it as the holder would have made (HolderMaker).
fn disk_node(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    on_disk: DiskHeld,
    recorded: Recorded,
    vtime_ns: u64,
) !*const Snapshot {
    const held = on_disk.held;
    var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
    const name = holders.Disk.name(&name_buffer, on_disk.branch, held.vtime_ns);
    var root_buffer: [Snapshot.disk_name_max]u8 = undefined;
    const root: ?Snapshot.DiskRoot = if (on_disk.root_origin) |origin| .{
        .name = holders.Disk.name(&root_buffer, origin.branch, origin.vtime_ns),
        .fd = on_disk.root_fd,
    } else null;
    return node_core.from_disk(arena, vm, options, on_disk.io, on_disk.disk.directory, name, held.vtime_ns, .{ .idle = held.idle }, recorded, vtime_ns, root);
}

/// The origin of a timeline's first disk holder, when its start has none of its own (a node loaded
/// from a holder on disk does): the setup's copy among the disk holders for a root from the setup
/// snapshot (run 1914: a root's first disk holder wrote the whole 8 GB guest, every later one
/// skipped while it wrote, and the moments before them replayed), and for a branch of a node over
/// it (Snapshot.base_fd the setup's: its pages the setup's but for its differences). None, a
/// node's branches wrote their whole guest: ParadeDB's run 2098, 11 holders of 21 GB each (223 of
/// its 298 GB on disk) where those saved against the setup's held 0.56 GB at the median.
fn holder_origin(setup: ?*const Snapshot, setup_origin: ?holders.Origin, start: *const Snapshot, path_len: usize) ?holders.Origin {
    const known = setup orelse return null;
    if (path_len == 0 and known == start) return setup_origin;
    if (start.base_fd >= 0 and start.base_fd == known.memory_fd) return setup_origin;
    return null;
}

test holder_origin {
    var setup: Snapshot = undefined;
    setup.memory_fd = 5;
    setup.base_fd = -1;
    var node: Snapshot = undefined;
    node.memory_fd = 9;
    node.base_fd = 5; // Over the setup.
    var whole: Snapshot = undefined;
    whole.memory_fd = 11;
    whole.base_fd = -1; // Loaded whole (from disk, before any root).
    const origin: holders.Origin = .{ .branch = std.math.maxInt(u32), .vtime_ns = 0 };
    try std.testing.expectEqual(origin, holder_origin(&setup, origin, &setup, 0).?);
    try std.testing.expectEqual(origin, holder_origin(&setup, origin, &node, 2).?);
    try std.testing.expectEqual(@as(?holders.Origin, null), holder_origin(&setup, origin, &whole, 2));
    try std.testing.expectEqual(@as(?holders.Origin, null), holder_origin(&setup, null, &node, 2)); // Not written.
    try std.testing.expectEqual(@as(?holders.Origin, null), holder_origin(null, origin, &node, 2)); // No setup.
}

test "a run's makers and the room kept for its timelines are what its VMs were learned to claim" {
    const gib: u64 = 1 << 30;
    const saved = cpus.claim_bytes;
    defer cpus.claim_bytes = saved;
    cpus.claim_bytes = 32 * gib; // ParadeDB's guests.
    var state: TreeState = .{
        .base = 1,
        .total = 64,
        .size = 16,
        .children = 4,
        .pipeline = 1,
        .jobs = 1,
        .holding = false,
        .registry = undefined,
        .change = null,
        .hunks_reached = &.{},
        .candidates = &.{},
        .tape_buffer = undefined,
        .io = undefined,
        .archive = true,
        .prefer_sometimes = true,
        .setup = undefined,
    };
    // Nothing learned: a VM's guest's size.
    try std.testing.expectEqual(32 * gib, vm_claim(&state));
    // Run 2098's: 2.7 GiB a VM held of its own, 40 ended: half again.
    state.claims.sample(2765 << 20, 34, 40, 40, 40);
    const learned = vm_claim(&state);
    try std.testing.expect(learned > 4 * gib - gib / 8 and learned < 4 * gib + gib / 8);
    try std.testing.expect(!state.claims.softened); // Read, not said.
    // A second maker beside one in flight: room at the learned claim, none at the guest's.
    const makings = [_]NodeMaking{.{ .back = undefined, .parent = undefined, .pid = 1, .socket = -1 }};
    const reserve = cpus.reserve_bytes();
    try std.testing.expect(maker_may_start(&makings, 40, reserve + 10 * gib, 0, learned));
    try std.testing.expect(!maker_may_start(&makings, 40, reserve + 10 * gib, 0, cpus.claim_bytes));
}

/// The makers still making (started, not collected).
fn makings_in_flight(makings: []const NodeMaking) u32 {
    var count: u32 = 0;
    for (makings) |making| count += @intFromBool(!making.ready and !making.waiting);
    return count;
}

/// Whether one more maker may start beside those in flight: a job for it, and room for its VM
/// (maker_room) with `keep` left for the timelines planned and waiting to run (runners_keep).
/// With none waiting, the first of them starts whatever the memory (its own admission waits).
/// Made while their branches waited for room, a judgment's nodes took the host: ParadeDB's run
/// 2091, 134.5 GiB of nodes before any of their 32 GiB VMs could start.
fn maker_may_start(makings: []const NodeMaking, jobs: u32, available: u64, keep: u64, claim: u64) bool {
    const in_flight = makings_in_flight(makings);
    if (in_flight >= jobs) return false;
    if (in_flight == 0 and keep == 0) return true;
    return maker_room(available, cpus.reserve_bytes() + keep, claim, in_flight);
}

/// What one of the run's VMs claims now, a maker's included (a branch of a node or the root, its
/// own memory its writes): what the run learned they hold, half again (ClaimLearning.learned),
/// else its guest's size. Its guest's size made ParadeDB's run 2098's first judgment take 725.8
/// s, two of its makers waiting for 32 GiB of room each while its nodes came to 0.26-0.58 GiB.
fn vm_claim(state: *const TreeState) u64 {
    const learned = state.claims.learned(cpus.claim_bytes);
    return if (learned != 0) learned else cpus.claim_bytes;
}

/// The room a judgment's makers leave: a VM's, while timelines it planned (not the filler's,
/// started only to keep CPUs busy) wait to run; none otherwise. Memory admission keeps one of
/// those running whatever its nodes hold (cpus.Pool.stalled_alone), so nodes come as their
/// branches go.
fn runners_keep(state: *const TreeState) u64 {
    return if (state.filler_start > state.queue_head) vm_claim(state) else 0;
}

/// What starts a maker: the tapes' directory and the buffer a parent's tape is loaded in (one
/// for all: loaded just before the fork, the child has its copy).
const MakerStart = struct {
    vm: *VM,
    options: *const VM.Options,
    tape_directory: ?[]const u8,
    tape_buffer: *tape.Overrides,
};

/// Starts a node's maker (a replay, or a holder on disk loaded). What was decided in the
/// parent beyond its seed (a strategy's decisions, the explorer's steering of its driver phase)
/// is in its tape: replayed to the moment with it. Without it, a branch started from a state
/// its parent never had, and its replays parted from it (rqlite's run 427: 11 of 212, every one
/// below a steered timeline). False when the tape cannot be loaded (said): a tape that cannot
/// be loaded costs its return, never the run (Valkey's run 1523 ended on a TapeTooLong here
/// before checkpoints were thinned).
fn maker_begin(arena: std.mem.Allocator, start: MakerStart, making: *NodeMaking) !bool {
    const parent = making.parent;
    const parent_recorded = Recorded.load(arena, start.tape_directory, parent.index, parent.seed, start.tape_buffer) catch |err| {
        say("[determinismo] timeline {d}'s tape could not be loaded ({s}): its return to {d} ms is not made\n", .{
            parent.index, @errorName(err), making.back.vtime_ns / std.time.ns_per_ms,
        });
        return false;
    };
    try node_make_start(arena, start.vm, start.options, making, parent_recorded);
    return true;
}

/// The makers that waited when their judgment began (NodeMaking.waiting), started in its order
/// as room comes; the room they wait for said to the host's holders meanwhile
/// (cpus.makers_want: those in memory leave for it, holders.zig), and no longer once none
/// waits. Never waits itself: the explorer's loop goes on (timelines taken and started, the
/// run's samples and status, a drain). It waited here, for a maker in flight to answer, short
/// of room for the next (4f3acbf1): etcd's 12-hour run 2007, 40 workers of 4 GB VMs beside 10
/// to 16 GB available, made its nodes 1.5 at a time and its explorer was in that wait for 43%
/// of its time (68 gaps over 30 s in its samples, 13,901 s of 32,227 s; a drain taken up
/// after 3 min 37 s, 405 children ended and not collected).
/// Whether makers still wait for memory then (fewer in flight than `jobs`): TreeState.makers_short.
fn makings_start(arena: std.mem.Allocator, start: MakerStart, makings: []NodeMaking, jobs: u32, keep: u64, claim: u64, skipped: *u32) !bool {
    var waiting = false;
    for (makings) |*making| {
        if (!making.waiting) continue;
        if (!maker_may_start(makings, jobs, cpus.memory_available(), keep, claim)) {
            waiting = true;
            break;
        }
        if (try maker_begin(arena, start, making)) {
            making.waiting = false;
        } else {
            making.waiting = false;
            making.ready = true; // No node: its return is not made.
            skipped.* += 1;
        }
    }
    const in_flight = makings_in_flight(makings);
    const room = (@as(u64, in_flight) + 1) * cpus.claim_bytes;
    // Short of a job alone (as many in flight as the run has): no room to ask for.
    const short = waiting and in_flight < jobs;
    if (short and room > 0) {
        cpus.makers_want(room);
    } else {
        cpus.makers_want_end();
    }
    return short;
}

/// The makers that still wait are not started: no node of theirs (a run that starts no timeline
/// any more), and no room asked for.
fn makings_cancel(makings: []NodeMaking) void {
    for (makings) |*making| if (making.waiting) {
        making.waiting = false;
        making.ready = true;
    };
    cpus.makers_want_end();
}

/// The makers in flight stopped and collected, no node of theirs: a run that starts no timeline
/// any more (makings_cancel has those that waited).
fn makings_stop(makings: []NodeMaking) void {
    for (makings) |*making| {
        if (making.ready or making.waiting) continue;
        assert(making.pid > 0);
        _ = linux.kill(making.pid, .KILL);
        close(making.socket);
        var status: i32 = 0;
        _ = linux.wait4(making.pid, &status, 0, null);
        making.ready = true;
    }
}

test makings_stop {
    // A maker in flight (a child that would take its time), one that waited, one collected.
    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair));
    const pid = linux.fork();
    if (pid == 0) {
        const long: linux.timespec = .{ .sec = 600, .nsec = 0 };
        _ = linux.nanosleep(&long, null);
        linux.exit_group(0);
    }
    _ = linux.close(pair[1]);
    var makings = [_]NodeMaking{
        .{ .back = undefined, .parent = undefined, .pid = @intCast(pid), .socket = pair[0] },
        .{ .back = undefined, .parent = undefined, .waiting = true },
        .{ .back = undefined, .parent = undefined, .ready = true },
    };
    makings_stop(&makings);
    try std.testing.expect(makings[0].ready and makings[0].snapshot == null);
    try std.testing.expectEqual(@as(u32, 0), makings_in_flight(&makings));
    // Its process is gone, collected: none left to wait for.
    var status: i32 = 0;
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.wait4(@intCast(pid), &status, linux.W.NOHANG, null)));
    try std.testing.expect(makings[1].waiting and !makings[1].ready); // makings_cancel's.
}

/// Every maker of a judgment made, waited for: where nothing else goes on (no timeline runs,
/// or a judgment made in one go).
fn makings_finish_all(arena: std.mem.Allocator, start: MakerStart, makings: []NodeMaking, jobs: u32, skipped: *u32) !void {
    while (true) {
        _ = try makings_start(arena, start, makings, jobs, 0, cpus.claim_bytes, skipped);
        if (makings_in_flight(makings) == 0) break; // None waits then: the first always starts.
        makings_finish_any(makings);
    }
    for (makings) |making| assert(making.ready);
}

/// Waits for whichever maker in flight answers first and collects every one that has: not the
/// oldest, whose wait held the others' room (Kafka 1928's judgment, makers allowed one to three
/// at a time by memory: a 47 s one done, the next started only as a 194 s one ended; 636 s).
fn makings_finish_any(makings: []NodeMaking) void {
    var polled: [jobs_max]linux.pollfd = undefined;
    var which: [jobs_max]u32 = undefined;
    var count: usize = 0;
    for (makings, 0..) |making, at| {
        if (making.ready or making.waiting or count == polled.len) continue;
        polled[count] = .{ .fd = making.socket, .events = linux.POLL.IN | linux.POLL.HUP, .revents = 0 };
        which[count] = @intCast(at);
        count += 1;
    }
    assert(count > 0);
    while (true) {
        const ready = linux.poll(&polled, @intCast(count), -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) {
            node_make_finish(&makings[which[0]]); // Waited for in order, as before.
            return;
        }
        break;
    }
    for (polled[0..count], which[0..count]) |entry, at| {
        if (entry.revents != 0) node_make_finish(&makings[at]);
    }
}

test "a maker short of room waits, not the explorer: the one in flight is left to answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gib = 1 << 30;
    const claim = cpus.claim_bytes;
    defer cpus.claim_bytes = claim;
    cpus.claim_bytes = 4 * gib;
    const reserve = cpus.reserve_bytes();
    // A maker in flight, to answer in 2 s (its socket closed: collected as one that made its
    // node is), and two that wait behind it.
    var pair: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) == .SUCCESS);
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.close(pair[0]);
        const wait: linux.timespec = .{ .sec = 2, .nsec = 0 };
        _ = linux.nanosleep(&wait, null);
        linux.exit_group(0);
    }
    _ = linux.close(pair[1]);
    var makings = [_]NodeMaking{
        .{ .back = undefined, .parent = undefined, .pid = @intCast(pid), .socket = pair[0] },
        .{ .back = undefined, .parent = undefined, .waiting = true },
        .{ .back = undefined, .parent = undefined, .waiting = true },
    };
    try std.testing.expectEqual(@as(u32, 1), makings_in_flight(&makings));
    // Run 2007's memory: the reserve and 6 GB, a claim for one maker and not for two. The next
    // does not start, and the question comes back at once with the one in flight left alone
    // (the explorer waited for it here, its loop stopped: 2 s in this test).
    const start_ns = monotonic_ns();
    try std.testing.expect(!maker_may_start(&makings, 40, reserve + 6 * gib, 0, cpus.claim_bytes));
    try std.testing.expect(monotonic_ns() - start_ns < std.time.ns_per_s);
    try std.testing.expect(!makings[0].ready);
    try std.testing.expectEqual(@as(u32, 1), makings_in_flight(&makings));
    // Room for the one in flight and the next: it starts. Not for a third beside two.
    try std.testing.expect(maker_may_start(&makings, 40, reserve + 8 * gib, 0, cpus.claim_bytes));
    makings[1].waiting = false; // Started (in flight: neither ready nor waiting).
    try std.testing.expect(!maker_may_start(&makings, 40, reserve + 8 * gib, 0, cpus.claim_bytes));
    try std.testing.expect(maker_may_start(&makings, 40, reserve + 12 * gib, 0, cpus.claim_bytes));
    makings[1].waiting = true;
    // A job for each: none beside as many in flight as the run has, whatever the memory.
    try std.testing.expect(!maker_may_start(&makings, 1, reserve + 64 * gib, 0, cpus.claim_bytes));
    // The memory unknown: never a reason to wait.
    try std.testing.expect(maker_may_start(&makings, 40, 0, 0, cpus.claim_bytes));
    // None in flight: the first starts whatever the memory (its own admission waits).
    node_make_finish(&makings[0]);
    try std.testing.expect(makings[0].ready);
    try std.testing.expect(maker_may_start(&makings, 40, 1 * gib, 0, cpus.claim_bytes));
    // Timelines planned and waiting to run: a VM's room is kept for them, the first maker too.
    try std.testing.expect(!maker_may_start(&makings, 40, reserve + 6 * gib, 4 * gib, cpus.claim_bytes));
    try std.testing.expect(maker_may_start(&makings, 40, reserve + 8 * gib, 4 * gib, cpus.claim_bytes));
    // Those that wait are not started in a run that starts no timeline any more.
    makings_cancel(&makings);
    for (makings) |making| try std.testing.expect(making.ready and !making.waiting);
}

test "a judgment short of room collects the maker that answers first, not the oldest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Two makers: the oldest answers in 2 s, the second at once (its socket closed: a maker that
    // failed, collected as one that made its node is).
    var makings: [2]NodeMaking = undefined;
    for (&makings, [_]u32{ 2, 0 }) |*making, seconds| {
        var pair: [2]i32 = undefined;
        try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) == .SUCCESS);
        const pid = linux.fork();
        if (pid == 0) {
            _ = linux.close(pair[0]);
            const wait: linux.timespec = .{ .sec = seconds, .nsec = 0 };
            _ = linux.nanosleep(&wait, null);
            linux.exit_group(0);
        }
        _ = linux.close(pair[1]);
        making.* = .{ .back = undefined, .parent = undefined, .pid = @intCast(pid), .socket = pair[0] };
    }
    const start_ns = monotonic_ns();
    makings_finish_any(&makings);
    try std.testing.expect(!makings[0].ready);
    try std.testing.expect(makings[1].ready);
    try std.testing.expect(monotonic_ns() - start_ns < std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), makings_in_flight(&makings));
    makings_finish_any(&makings);
    try std.testing.expectEqual(@as(u32, 0), makings_in_flight(&makings));
}

test "a node whose holder on disk did not load is a replay's: not from disk, no origin for its branches" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const disk: holders.Disk = .{ .directory = "/nonexistent" };
    // Two makers given a holder on disk: the first loaded it, the second replayed (its file gone).
    for ([_]u8{ node_loaded, node_replayed }) |how| {
        var pair: [2]linux.fd_t = undefined;
        try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) == .SUCCESS);
        const sent = try arena.create(Snapshot);
        @memset(std.mem.asBytes(sent), 0);
        const pid = linux.fork();
        if (pid == 0) {
            _ = linux.close(pair[0]);
            const memory = linux.memfd_create("node", 0);
            fd_pass.send(pair[1], @intCast(memory)) catch linux.exit_group(1);
            write_all(pair[1], std.mem.asBytes(sent));
            write_all(pair[1], &.{how});
            linux.exit_group(0);
        }
        _ = linux.close(pair[1]);
        var making: NodeMaking = .{
            .back = undefined,
            .parent = undefined,
            .pid = @intCast(pid),
            .socket = pair[0],
            .disk = .{ .held = .{ .pid = 0, .worker = 0, .id = 0, .vtime_ns = 5, .disk = true }, .branch = 3, .disk = &disk, .io = std.testing.io },
        };
        node_make_finish(&making);
        try std.testing.expect(making.ready);
        try std.testing.expect(making.snapshot != null);
        _ = linux.close(making.snapshot.?.memory_fd);
        try std.testing.expectEqual(how == node_loaded, making.disk != null);
        try std.testing.expectEqual(how == node_replayed, making.unloaded);
    }
}

fn node_make_finish(making: *NodeMaking) void {
    if (making.ready) return;
    assert(making.pid > 0);
    defer {
        close(making.socket);
        var status: i32 = 0;
        _ = linux.wait4(making.pid, &status, 0, null);
        making.ready = true; // Collected (made or not): once.
    }
    const fd = fd_pass.receive(making.socket) catch return; // It failed, and said why.
    const snapshot = node_snapshot_create() catch {
        close(fd);
        return;
    };
    if (!read_exact(making.socket, std.mem.asBytes(snapshot))) {
        close(fd);
        _ = node_snapshots.remove(@intFromPtr(snapshot));
        std.heap.page_allocator.destroy(snapshot);
        return;
    }
    snapshot.memory_fd = fd;
    making.snapshot = snapshot;
    // A holder on disk that did not load (its file or one of its chain's gone: the kept holders'
    // budget, holders.zig) was replayed from the parent's start by its maker, which says so: no
    // longer counted among those from disk, nor its node the origin of its branches' holders.
    if (making.disk != null) {
        var how: [1]u8 = .{node_loaded};
        if (read_exact(making.socket, &how) and how[0] == node_replayed) {
            making.disk = null;
            making.unloaded = true;
        }
    }
}

/// What a node's maker says after its snapshot: how it was made.
const node_loaded: u8 = 1;
const node_replayed: u8 = 0;

/// DETERMINISMO_VERIFY_HOLDERS=1: every node a holder made is made again by a replay and the
/// two compared (they must be the same: holders.zig).
/// Prints how a holder's node and a replay's node of the same moment differ (memory included),
/// but for what the guest cannot see (field_same).
fn snapshots_compare(back: TreeReturn, held: *const Snapshot, replayed: *const Snapshot) void {
    var differ: u32 = 0;
    inline for (@typeInfo(Snapshot).@"struct".field_names) |name| {
        // Descriptors and the tree's bookkeeping, not the machine.
        if (comptime std.mem.eql(u8, name, "memory_fd") or std.mem.eql(u8, name, "base_fd") or
            std.mem.eql(u8, name, "root")) continue;
        if (!field_same(name, held, replayed)) {
            differ += 1;
            const a = std.mem.asBytes(&@field(held, name));
            const b = std.mem.asBytes(&@field(replayed, name));
            const at = std.mem.indexOfDiff(u8, a, b) orelse 0;
            say("[determinismo] verify #{d} at {d}ns: {s} differs (byte {d} of {d}: " ++
                "{x} against {x})\n", .{
                back.branch,
                back.vtime_ns,
                name,
                at,
                a.len,
                a[at..@min(a.len, at + 8)],
                b[at..@min(b.len, at + 8)],
            });
        }
    }
    const memory_same = memory_equal(held, replayed);
    if (!memory_same) differ += 1;
    say("[determinismo] verify #{d} at {d}ns: {s}{s}\n", .{
        back.branch,
        back.vtime_ns,
        if (differ == 0) "the same" else "DIFFERENT",
        if (memory_same) "" else " (memory too)",
    });
}

/// MSRs KVM derives from host time, which the guest's clock (the branch count) is not: the TSC
/// (its reads are the branch clock) and Hyper-V's runtime and reference counters (not offered).
const host_time_msrs = [_]u32{ 0x10, 0x40000010, 0x40000020 };

/// A snapshot field the same in both, but for what the guest cannot see: host-time MSRs, the
/// last exception's or interrupt's leftovers while none is pending or injected (struct
/// kvm_vcpu_events), and the attributes of unusable segments.
/// Two machines' event states, by what they hold: never their padding, nor the arrays past
/// what is used (a holder's copy and a replay's differ there and nowhere the guest or the tree
/// can see: run on srv3, 2026-10-27, `check_inputs`' padding).
fn events_same(a: *const Events, b: *const Events) bool {
    if (a.count != b.count or !std.meta.eql(a.hash, b.hash)) return false;
    if (a.property_count != b.property_count) return false;
    for (a.properties[0..a.property_count], b.properties[0..b.property_count]) |*x, *y| {
        if (x.kind != y.kind or x.hits != y.hits or x.trues != y.trues) return false;
        if (x.message_hash != y.message_hash) return false;
        if (!std.mem.eql(u8, x.name(), y.name()) or !std.mem.eql(u8, x.where(), y.where())) return false;
        if (!std.meta.eql(x.first_failure, y.first_failure)) return false;
    }
    if (!std.meta.eql(a.setup_complete, b.setup_complete) or a.guest_done != b.guest_done) return false;
    const a_last = a.last_event_name[0..a.last_event_name_size];
    if (!std.mem.eql(u8, a_last, b.last_event_name[0..b.last_event_name_size])) return false;
    if (a.output_bytes != b.output_bytes or !std.meta.eql(a.first_vtime_ns, b.first_vtime_ns)) return false;
    if (a.last_vtime_ns != b.last_vtime_ns or a.behavior_count != b.behavior_count) return false;
    for (a.behaviors[0..a.behavior_count], b.behaviors[0..b.behavior_count]) |*x, *y| {
        if (x.hash != y.hash or x.vtime_ns != y.vtime_ns or !std.mem.eql(u8, x.name(), y.name())) return false;
    }
    if (!std.mem.eql(u64, &a.behavior_slots, &b.behavior_slots)) return false;
    if (a.check_used != b.check_used) return false;
    for (a.check_inputs, b.check_inputs) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

fn field_same(comptime name: []const u8, held: *const Snapshot, replayed: *const Snapshot) bool {
    if (comptime std.mem.eql(u8, name, "msrs")) {
        if (held.msrs.count != replayed.msrs.count) return false;
        const count = held.msrs.count;
        for (held.msrs.entries[0..count], replayed.msrs.entries[0..count]) |x, y| {
            if (x.index != y.index) return false;
            if (std.mem.indexOfScalar(u32, &host_time_msrs, x.index) != null) continue;
            if (x.data != y.data) return false;
        }
        return true;
    }
    if (comptime std.mem.eql(u8, name, "vcpu_events")) {
        var a = held.vcpu_events.bytes;
        var b = replayed.vcpu_events.bytes;
        for ([_]*[64]u8{ &a, &b }) |events| {
            if (events[0] == 0 and events[3] == 0) { // Exception neither injected nor pending.
                events[1] = 0;
                events[2] = 0;
                @memset(events[4..8], 0);
            }
            if (events[8] == 0) { // Interrupt not injected.
                events[9] = 0;
                events[10] = 0;
            }
        }
        return std.mem.eql(u8, &a, &b);
    }
    if (comptime std.mem.eql(u8, name, "sregs")) {
        var a = held.sregs;
        var b = replayed.sregs;
        inline for (.{ "ds", "es", "fs", "gs", "ss", "ldt" }) |segment| {
            const x = &@field(a, segment);
            const y = &@field(b, segment);
            if (x.unusable != 0 and y.unusable != 0) { // Only the base counts (FS and GS).
                x.* = segment_unusable(x.base);
                y.* = segment_unusable(y.base);
            }
        }
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
    // By value: an optional's padding is whatever its writer left there.
    if (comptime std.mem.eql(u8, name, "modulation")) {
        return std.meta.eql(held.modulation, replayed.modulation);
    }
    if (comptime std.mem.eql(u8, name, "events")) return events_same(&held.events, &replayed.events);
    const a = std.mem.asBytes(&@field(held, name));
    const b = std.mem.asBytes(&@field(replayed, name));
    return std.mem.eql(u8, a, b);
}

fn segment_unusable(base: u64) kvm.Segment {
    var segment = std.mem.zeroes(kvm.Segment);
    segment.base = base;
    segment.unusable = 1;
    return segment;
}

fn memory_equal(held: *const Snapshot, replayed: *const Snapshot) bool {
    const size = held.memory_size;
    var buffers: [2][1 << 20]u8 = undefined;
    var offset: u64 = 0;
    var pages_differing: u64 = 0;
    var xsave_headers: u64 = 0;
    while (offset < size) : (offset += buffers[0].len) {
        const length = @min(buffers[0].len, size - offset);
        // Each whole: its own pages, the root's where it holds only its differences.
        held.memory_read(buffers[0][0..length], offset) catch return false;
        replayed.memory_read(buffers[1][0..length], offset) catch return false;
        if (std.mem.eql(u8, buffers[0][0..length], buffers[1][0..length])) continue;
        // Each page that differs (the first few told): a page of zeros on one side is one a copy
        // missed; contents on both, memory that changed.
        const page = std.heap.page_size_min;
        var at: usize = 0;
        while (at < length) : (at += page) {
            const x = buffers[0][at..][0..page];
            const y = buffers[1][at..][0..page];
            if (std.mem.eql(u8, x, y)) continue;
            if (xsave_bits_only(buffers[0][0..length], buffers[1][0..length], at)) {
                xsave_headers += 1;
                continue;
            }
            pages_differing += 1;
            if (pages_differing > 8) continue;
            const first = std.mem.indexOfDiff(u8, x, y).?;
            say("[determinismo] verify: page at {d} differs from byte {d}: {x} against " ++
                "{x}{s}{s}\n", .{
                offset + at,
                first,
                x[first..@min(page, first + 16)],
                y[first..@min(page, first + 16)],
                if (std.mem.allEqual(u8, x, 0)) " (held: all zeros)" else "",
                if (std.mem.allEqual(u8, y, 0)) " (replayed: all zeros)" else "",
            });
            rings_name(held, offset + at + first);
            page_dump(offset + at, x, y);
            mappings_name(held, offset + at);
        }
    }
    if (xsave_headers > 0) say("[determinismo] verify: {d} pages differ only in an " ++
        "XSAVE header's x87/SSE in-use bits (the same registers either way)\n", .{xsave_headers});
    if (pages_differing > 0) say("[determinismo] verify: {d} pages differ\n", .{pages_differing});
    return pages_differing == 0;
}

/// Whether the page at `at` differs only in the in-use bits of XSAVE headers whose components
/// are in their initial state. XSAVE writes XSTATE_BV from the processor's XINUSE tracking,
/// which may clear a component's bit once it holds its initial values; the host's own FPU
/// saves and restores of the guest (when its thread is preempted) do so at host-chosen moments,
/// so a guest task's saved x87 state reads XSTATE_BV 2 in one run and 3 in another. XRSTOR
/// gives back the same registers either way, and the guest cannot read XINUSE (XGETBV 1 is
/// hidden: cpuid.zig), so the two machines are the same.
fn xsave_bits_only(x: []const u8, y: []const u8, at: usize) bool {
    const page = std.heap.page_size_min;
    const header_size = 64;
    const legacy_size = 512;
    const in_use_bits: u64 = 0b11; // x87, SSE.
    assert(at % page == 0 and at + page <= x.len and x.len == y.len);
    var word = at;
    while (word < at + page) : (word += 8) {
        const a = std.mem.readInt(u64, x[word..][0..8], .little);
        const b = std.mem.readInt(u64, y[word..][0..8], .little);
        if (a == b) continue;
        // XSTATE_BV: a 64-byte aligned header after the 512-byte legacy area, its reserved
        // bytes zero (else XRSTOR faults), differing in in-use bits alone.
        if (word % header_size != 0 or word + header_size > x.len or word < legacy_size) return false;
        if ((a ^ b) & ~in_use_bits != 0) return false;
        if (!std.mem.allEqual(u8, x[word + 8 ..][0 .. header_size - 8], 0)) return false;
        if (!std.mem.allEqual(u8, y[word + 8 ..][0 .. header_size - 8], 0)) return false;
        const legacy = x[word - legacy_size ..][0..legacy_size];
        if (!std.mem.eql(u8, legacy, y[word - legacy_size ..][0..legacy_size])) return false;
        // The components whose bit differs hold their initial values.
        if ((a ^ b) & 0b01 != 0) {
            const control = std.mem.readInt(u16, legacy[0..2], .little);
            if (control != 0x037f or !std.mem.allEqual(u8, legacy[2..24], 0)) return false;
            if (!std.mem.allEqual(u8, legacy[32..160], 0)) return false; // ST0-ST7.
        }
        if ((a ^ b) & 0b10 != 0) {
            const mxcsr = std.mem.readInt(u32, legacy[24..28], .little);
            if (mxcsr != 0x1f80 or !std.mem.allEqual(u8, legacy[160..416], 0)) return false; // XMM0-XMM15.
        }
        word += header_size - 8; // The header's other words are equal (zero) on both.
    }
    return true;
}

test "xsave_bits_only: an x87 in-use bit in an XSAVE header, nothing else" {
    // As found on srv1: a task's XSAVE area at 704 in its page, x87 and SSE initial.
    var held: [2 * std.heap.page_size_min]u8 = @splat(0);
    std.mem.writeInt(u16, held[704..][0..2], 0x037f, .little);
    std.mem.writeInt(u32, held[704 + 24 ..][0..4], 0x1f80, .little);
    std.mem.writeInt(u32, held[704 + 28 ..][0..4], 0xffff, .little);
    held[1216] = 2;
    var replayed = held;
    replayed[1216] = 3;
    try std.testing.expect(xsave_bits_only(&held, &replayed, 0));
    // Not when the x87 state is in use (a register holds a value).
    var used_held = held;
    var used_replayed = replayed;
    used_held[704 + 32] = 1;
    used_replayed[704 + 32] = 1;
    try std.testing.expect(!xsave_bits_only(&used_held, &used_replayed, 0));
    // Not for another bit, nor at an unaligned place, nor for any other byte.
    replayed[1216] = 2 | 4;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
    replayed[1216] = 2;
    replayed[1217] = 1;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
    replayed[1217] = 0;
    replayed[1224] = 3;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
}

/// Says which virtual addresses of the running address space (CR3, 4-level paging) map a guest
/// page, the kernel's direct map left out: a user address names a process's memory.
fn mappings_name(snapshot: *const Snapshot, page_address: u64) void {
    const mask: u64 = 0x000f_ffff_ffff_f000;
    var told: u32 = 0;
    const pml4 = snapshot.sregs.cr3 & mask;
    for (0..512) |a| {
        const e4 = entry_read(snapshot, pml4, a) orelse continue;
        for (0..512) |b| {
            const e3 = entry_read(snapshot, e4 & mask, b) orelse continue;
            const va3 = canonical((a << 39) | (b << 30));
            if (e3 & 0x80 != 0) { // 1 GiB page.
                const base = e3 & 0x000f_ffff_c000_0000;
                if (page_address >= base and page_address < base + (1 << 30)) {
                    told += mapping_tell(va3 + (page_address - base), told);
                }
                continue;
            }
            for (0..512) |c| {
                const e2 = entry_read(snapshot, e3 & mask, c) orelse continue;
                const va2 = va3 | (c << 21);
                if (e2 & 0x80 != 0) { // 2 MiB page.
                    const base = e2 & 0x000f_ffff_ffe0_0000;
                    if (page_address >= base and page_address < base + (1 << 21)) {
                        told += mapping_tell(va2 + (page_address - base), told);
                    }
                    continue;
                }
                var table: [512]u64 = undefined;
                const length = std.mem.sliceAsBytes(&table).len;
                snapshot.memory_read(std.mem.sliceAsBytes(&table)[0..length], e2 & mask) catch continue;
                for (table, 0..) |e1, d| {
                    if (e1 & 1 == 0 or e1 & mask != page_address) continue;
                    told += mapping_tell(va2 | (d << 12), told);
                }
            }
        }
    }
    if (told == 0) say("[determinismo] verify: no mapping of it but the direct map (cr3 {x})\n", .{
        snapshot.sregs.cr3,
    });
}

fn entry_read(snapshot: *const Snapshot, table: u64, index: usize) ?u64 {
    var entry: u64 = 0;
    snapshot.memory_read(std.mem.asBytes(&entry), table + index * 8) catch return null;
    if (entry & 1 == 0) return null;
    return entry;
}

fn canonical(address: u64) u64 {
    return if (address & (1 << 47) != 0) address | 0xffff_0000_0000_0000 else address;
}

/// Tells one mapping (up to eight), the kernel's direct map left out; returns how many it told.
fn mapping_tell(address: u64, told: u32) u32 {
    const direct_map_start: u64 = 0xffff_8880_0000_0000;
    const direct_map_end: u64 = 0xffff_c880_0000_0000;
    if (address >= direct_map_start and address < direct_map_end) return 0;
    if (told >= 8) return 0;
    say("[determinismo] verify: mapped at {x}{s}\n", .{
        address, if (address < (1 << 47)) " (user space)" else "",
    });
    return 1;
}

/// Writes both sides of a page that differs to /tmp/determinismo-verify-<pid>-<address>-{held,
/// replayed}, to read what it holds.
fn page_dump(address: u64, held: []const u8, replayed: []const u8) void {
    const sides = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "held", .bytes = held },
        .{ .name = "replayed", .bytes = replayed },
    };
    for (sides) |side| {
        var path_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-verify-{d}-{d}-{s}", .{
            linux.getpid(), address, side.name,
        }, 0) catch return;
        const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) return;
        _ = linux.write(@intCast(fd), side.bytes.ptr, side.bytes.len);
        _ = linux.close(@intCast(fd));
    }
    say("[determinismo] verify: page written to /tmp/determinismo-verify-{d}-{d}-{{held,replayed}}\n", .{
        linux.getpid(), address,
    });
}

/// Says which disk's virtqueue part holds a guest address, if one does (the parts the VMM and
/// the guest both write).
fn rings_name(snapshot: *const Snapshot, address: u64) void {
    for (snapshot.blocks[0..snapshot.block_count], 0..) |*block, disk| {
        const size: u64 = block.queue_size;
        const parts = [_]struct { name: []const u8, start: u64, length: u64 }{
            .{ .name = "descriptors", .start = block.queue_descriptors, .length = 16 * size },
            .{ .name = "available ring", .start = block.queue_available, .length = 6 + 2 * size },
            .{ .name = "used ring", .start = block.queue_used, .length = 6 + 8 * size },
        };
        for (parts) |part| {
            if (address < part.start or address >= part.start + part.length) continue;
            say("[determinismo] verify: that is disk {d}'s {s}, byte {d} (the VMM's " ++
                "indices: available {d}, used {d})\n", .{
                disk, part.name, address - part.start, block.available_index, block.used_index,
            });
        }
    }
}

/// Releases a tree node's memory (never the setup snapshot's), once its branches ran.
/// A node's snapshot struct (2.98 MB: the events' state it carries), its own pages so that
/// node_free gives them back (in the run's arena, a run of short timelines kept every one: 6,230
/// nodes and 19.5 GiB in Turso's run 2071 at 8.6 hours).
fn node_snapshot_create() !*Snapshot {
    const snapshot = try std.heap.page_allocator.create(Snapshot);
    assert(std.mem.isAligned(@intFromPtr(snapshot), std.heap.page_size_min));
    node_snapshots.put(std.heap.page_allocator, @intFromPtr(snapshot), {}) catch {
        std.heap.page_allocator.destroy(snapshot);
        return error.OutOfMemory;
    };
    return snapshot;
}

/// The node snapshots node_snapshot_create made whose pages node_free has not given back yet.
var node_snapshots: std.AutoHashMapUnmanaged(usize, void) = .empty;

/// A freed node's snapshot struct, all but the page holding its memory's descriptor (-1 now,
/// read by node_free again) given back to the kernel: what a Planned still pointing at it reads
/// of the rest is zeros (nothing does but a log line's start, read only while it lives).
fn node_pages_release(snapshot: *Snapshot) void {
    if (!node_snapshots.remove(@intFromPtr(snapshot))) return;
    const page = std.heap.page_size_min;
    const base = @intFromPtr(snapshot);
    const end = std.mem.alignForward(usize, base + @sizeOf(Snapshot), page);
    const keep_start = std.mem.alignBackward(usize, base + @offsetOf(Snapshot, "memory_fd"), page);
    const keep_end = std.mem.alignForward(usize, base + @offsetOf(Snapshot, "memory_fd") + @sizeOf(linux.fd_t), page);
    if (keep_start > base) _ = linux.madvise(@ptrFromInt(base), keep_start - base, linux.MADV.DONTNEED);
    if (end > keep_end) _ = linux.madvise(@ptrFromInt(keep_end), end - keep_end, linux.MADV.DONTNEED);
}

test "a freed node's snapshot gives its pages back, its memory's descriptor kept closed" {
    const snapshot = try node_snapshot_create();
    defer std.heap.page_allocator.destroy(snapshot);
    @memset(std.mem.asBytes(snapshot), 1);
    const root = try node_snapshot_create();
    defer {
        _ = node_snapshots.remove(@intFromPtr(root));
        std.heap.page_allocator.destroy(root);
    }
    snapshot.memory_fd = @intCast(linux.memfd_create("node-test", linux.MFD.CLOEXEC));
    node_free(snapshot, root);
    try std.testing.expectEqual(@as(linux.fd_t, -1), snapshot.memory_fd);
    // A byte far from its descriptor reads as the zero page: its memory went back.
    const bytes = std.mem.asBytes(snapshot);
    const far = if (@offsetOf(Snapshot, "memory_fd") < bytes.len / 2) bytes.len - 1 else 0;
    try std.testing.expectEqual(@as(u8, 0), bytes[far]);
    node_free(snapshot, root); // Freed again: nothing (its descriptor is not closed twice).
    try std.testing.expectEqual(@as(linux.fd_t, -1), snapshot.memory_fd);
}

fn node_free(snapshot: *const Snapshot, root: *const Snapshot) void {
    if (snapshot == root or snapshot.memory_fd < 0) return;
    close(snapshot.memory_fd);
    @constCast(snapshot).memory_fd = -1;
    node_pages_release(@constCast(snapshot));
}

/// Antithesis's rewind: runs the branch to the first event matching --until, then moves the
/// moment `ns` of virtual time before it. Decisions come from the seed (or the replayed tape), so
/// the rerun reaches the earlier moment on the same path.
fn rewind(
    vm: *VM,
    options: *VM.Options,
    snapshot: *const Snapshot,
    exploration: *const Exploration,
    ns: u64,
) !void {
    assert(options.until != null);
    assert(exploration.strategy == null);
    var probe = options.*;
    probe.moment_command = null;
    probe.moment_continue = false;
    own_cpu.take();
    try vm.init_from_snapshot(&probe, snapshot);
    defer vm.deinit();
    if (exploration.replay) |replay| vm.overrides = replay.overrides;
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached or !vm.until_hit) {
        say("[determinismo] rewind: the condition does not hold in time\n", .{});
        return;
    }
    const at = (try vm.moment()).vtime_ns;
    const target = at -| ns;
    try moment_after_snapshot(snapshot, target);
    say("[determinismo] rewind: the condition holds at {d}ns; the moment is {d}ns\n", .{
        at, target,
    });
    options.until = null;
    options.moment_vtime_ns = target;
}

fn replay_draw_note(context: *anyopaque, pull: u64, label: []const u8, value: []const u8, overridden: bool) void {
    const draws: *draws_zig.Draws = @ptrCast(@alignCast(context));
    draws.note(label, pull, value, overridden);
}

fn replay_event_note(context: *anyopaque, vtime_ns: u64) void {
    const draws: *draws_zig.Draws = @ptrCast(@alignCast(context));
    draws.event_seen(vtime_ns);
}

/// A timeline's named draws beside its events (draws.zig), whole before its line in the record.
fn draws_write(arena: std.mem.Allocator, directory: []const u8, name: []const u8, draws: *const draws_zig.Draws) !void {
    const fd = try events_file(arena, directory, name);
    defer close(fd);
    draws.write(fd);
}

fn events_file(arena: std.mem.Allocator, directory: []const u8, name: []const u8) !linux.fd_t {
    const path = try std.fs.path.join(arena, &.{ directory, name });
    return open_for_writing(arena, path);
}

/// A timeline's end checks with its strategy's after the program's own (Strategy.judge): the
/// plugin's assertions are the timeline's at its end moment, after its guest hash, as a host
/// check's; a replay without the plugin keeps the guest hash, not them (Strategy.judge).
const StrategyCheck = struct {
    inner: ?VM.EndChecks,
    strategy: *Strategies,
    index: u32,

    fn hook(check: *const StrategyCheck) VM.EndChecks {
        return .{ .context = check, .run = run };
    }

    fn run(context: *const anyopaque, events: *Events, end: Events.Moment, keep: ?[]const u8) anyerror!void {
        const check: *const StrategyCheck = @ptrCast(@alignCast(context));
        if (check.inner) |inner| try inner.run(inner.context, events, end, keep);
        const buffer = try std.heap.page_allocator.alloc(u8, Strategy.check_assertions_max * Strategy.check_line_size_max);
        defer std.heap.page_allocator.free(buffer);
        var lines: [Strategy.check_assertions_max][]const u8 = undefined;
        // The histories its commands recorded for the program's checks, whole.
        var histories: [Events.check_count_max]Strategy.History = undefined;
        var history_count: usize = 0;
        if (check.inner) |inner| if (checks.Hook.of(inner)) |program| {
            for (program.checks, 0..) |program_check, position| {
                if (position >= Events.check_count_max) break;
                const records = events.check_input(position) orelse continue;
                histories[history_count] = .{ .name = program_check.name, .records = records };
                history_count += 1;
            }
        };
        const count = try check.strategy.judge(check.index, histories[0..history_count], buffer, &lines);
        for (lines[0..count]) |line| try events.emit(end, line);
        var said: [128]u8 = undefined;
        try events.emit(end, try std.fmt.bufPrint(&said, "{{\"event\":\"strategy_check\",\"details\":{{\"assertions\":{d}}}}}", .{count}));
    }
};

/// A line on standard error in one write: forked workers share it, and std.debug.print's small
/// buffer wrote a long line in pieces another process's whole line could land between (a
/// tree's generation line took a timeline's `[branch 18]` line inside it: e2e pausing parsed
/// 31 of 32 timelines, 2026-11-19). Up to 4 KiB, a pipe's atomic write; a longer one as before.
fn say(comptime format: []const u8, arguments: anytype) void {
    var buffer: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, arguments) catch return std.debug.print(format, arguments);
    var written: usize = 0;
    while (written < line.len) {
        const result = linux.write(2, line[written..].ptr, line.len - written);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return;
        written += result;
    }
}

/// Tells the strategy how the branch ended; returns true when it asks to stop.
const BranchResult = struct { index: u32, outcome: VM.Outcome };

fn strategy_branch_end(strategy: *Strategies, vm: *VM, branch: BranchResult) !bool {
    var failing_buffer: [64][]const u8 = undefined;
    var failing_count: u32 = 0;
    for (vm.events.properties[0..vm.events.property_count]) |*property| {
        if (property.passing()) continue;
        if (failing_count == failing_buffer.len) break;
        failing_buffer[failing_count] = property.name();
        failing_count += 1;
    }
    return strategy.branch_end(.{
        .index = branch.index,
        .outcome = @tagName(branch.outcome),
        .events = vm.events.count,
        .failing = failing_buffer[0..failing_count],
    });
}

fn open_tape(arena: std.mem.Allocator, directory: []const u8, index: u32) !linux.fd_t {
    assert(directory.len > 0);
    const path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, index });
    return open_for_writing(arena, path);
}

fn close(fd: linux.fd_t) void {
    assert(fd >= 0);
    _ = linux.close(fd);
}

/// What a timeline depends on besides its decisions: the kernel and initramfs bytes, the
/// command line (scenario included) and the disks. Disks are named by their content (image IDs,
/// system hashes), so their names stand for their bytes; other disks are hashed by path.
/// "<min>-<max>" microseconds, the shortest below the longest.
fn stretch_parse(text: []const u8) ![2]u64 {
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return error.BadStretch;
    const low = try std.fmt.parseInt(u64, text[0..dash], 10);
    const high = try std.fmt.parseInt(u64, text[dash + 1 ..], 10);
    if (low == 0 or high <= low) return error.BadStretch;
    return .{ low * std.time.ns_per_us, high * std.time.ns_per_us };
}

test stretch_parse {
    try std.testing.expectEqual([2]u64{ 20_000, 200_000 }, try stretch_parse("20-200"));
    try std.testing.expectError(error.BadStretch, stretch_parse("200-20"));
    try std.testing.expectError(error.BadStretch, stretch_parse("20"));
}

fn inputs_hash(options: *const VM.Options, arguments: *const Arguments) u64 {
    var hasher = std.hash.Wyhash.init(0x696e70757473);
    hasher.update(options.kernel);
    if (options.initrd) |initrd| hasher.update(initrd);
    hasher.update(options.cmdline);
    hasher.update(std.mem.asBytes(&options.timer_slack_ns)); // Where timer interrupts land.
    // And how far into their slack, when not at once (none before the landing point existed).
    if (options.timer_delay_permille != 0) hasher.update(std.mem.asBytes(&options.timer_delay_permille));
    hasher.update(std.mem.asBytes(&options.branch_event)); // What time is made of.
    // And what its low bits read (none for runs before the jitter: their inputs unchanged).
    if (options.tsc_jitter_seed != 0) hasher.update(std.mem.asBytes(&options.tsc_jitter_seed));
    if (options.cpu_modulation) { // And how fast it runs.
        hasher.update("cpu-modulation");
        hasher.update(std.mem.asBytes(&VM.modulation_version));
        // Stretches of another length (the default's tapes keep their inputs).
        if (!std.mem.eql(u64, &options.modulation_stretch_ns, &VM.modulation_stretch_default)) {
            hasher.update(std.mem.asBytes(&options.modulation_stretch_ns));
        }
    }
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        hasher.update(std.fs.path.basename(path));
    }
    // Another start date (the default's tapes keep their inputs).
    if (options.epoch_seconds != VM.epoch_seconds_default) hasher.update(std.mem.asBytes(&options.epoch_seconds));
    // Replays are guaranteed on the same CPU model and determinism ABI only (ARCHITECTURE.md §12).
    hasher.update(std.mem.asBytes(&VM.determinism_abi));
    hasher.update(std.mem.asBytes(&guest_cpu_signature(options)));
    // VM v1's guest (the host's tapes keep their inputs).
    if (options.guest_cpu != .host) hasher.update(@tagName(options.guest_cpu));
    return hasher.final();
}

/// The CPU the guest is shown: the host's, or with `--cpuid` the given table's (leaves 0 and 1),
/// the recording host's for its replays elsewhere (on that host the two are equal).
fn guest_cpu_signature(options: *const VM.Options) [4]u32 {
    const table = options.cpuid_table orelse return if (options.guest_cpu == .vm_v1)
        .{ 0x756e_6547, 0x4965_6e69, 0x6c65_746e, 0x0005_0657 } // GenuineIntel, family 6 model 85 stepping 7.
    else
        host_cpu_signature();
    var signature = host_cpu_signature();
    for (table) |entry| {
        if (entry.function == 0 and entry.index == 0) {
            signature[0] = entry.ebx;
            signature[1] = entry.edx;
            signature[2] = entry.ecx;
        }
        if (entry.function == 1 and entry.index == 0) signature[3] = entry.eax;
    }
    return signature;
}

/// The host CPU's vendor and family/model/stepping (CPUID leaves 0 and 1): retired-branch
/// counts are only known to agree on the same model.
fn host_cpu_signature() [4]u32 {
    const vendor = cpuid_raw(0);
    const signature = cpuid_raw(1);
    return .{ vendor[1], vendor[3], vendor[2], signature[0] };
}

fn cpuid_raw(leaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );
    return .{ eax, ebx, ecx, edx };
}

/// The seed branches derive theirs from: the exploration's, or for branches from a fork point,
/// one derived from it and the fork, so that every subtree has its own branches.
fn seed_base(exploration: *const Exploration) u64 {
    const fork = exploration.fork orelse return exploration.exploration_seed;
    const key = [3]u64{ exploration.exploration_seed, fork.branch, fork.vtime_ns };
    var hasher = std.hash.Wyhash.init(0x666f726b);
    hasher.update(std.mem.asBytes(&key));
    if (fork.exec) |command| hasher.update(command); // A changed system: other branches.
    if (fork.pokes) |pokes| hasher.update(pokes);
    return hasher.final();
}

/// Each branch's decisions derive from the exploration seed and the branch index only, so any
/// branch can be replayed alone with --branch.
pub fn branch_seed(seed: u64, index: u32) u64 {
    const key = [2]u64{ seed, index };
    return std.hash.Wyhash.hash(0x6272616e6368, std.mem.asBytes(&key));
}

/// `--run <run directory>`: the run's own options in its place (its machine, system, pin, seed,
/// scenario and profile, as verify --run takes them); with it, `--branch <n>` is that timeline's
/// tape. A moment of a run's timeline in two flags: rebuilt by hand, a seed or a timeline length
/// left out made the tape refuse its inputs (TapeInputsDiffer), or replayed another timeline.
fn run_expand(arena: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) ![]const [:0]const u8 {
    const at = for (argv, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--run") and index + 1 < argv.len) break index;
    } else return argv;
    const directory = argv[at + 1];
    var options: std.ArrayList([]const u8) = .empty;
    try verify.run_arguments(arena, io, directory, &options);
    var out: std.ArrayList([:0]const u8) = .empty;
    try out.appendSlice(arena, argv[0..at]);
    for (options.items) |option| try out.append(arena, try arena.dupeSentinel(u8, option, 0));
    var index = at + 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--branch") and index + 1 < argv.len) {
            const branch_tape = try std.fmt.allocPrintSentinel(arena, "{s}/tapes/branch-{s}.jsonl", .{ directory, argv[index + 1] }, 0);
            if (std.Io.Dir.cwd().access(io, branch_tape, .{})) |_| {
                try out.appendSlice(arena, &.{ "--tape", branch_tape });
                index += 1;
                continue;
            } else |_| {}
        }
        try out.append(arena, argv[index]);
    }
    return out.items;
}

fn parse_arguments(arena: std.mem.Allocator, argv: []const [:0]const u8) !Arguments {
    if (argv.len < 2) return error.Usage;
    if (argv.len > arguments_max) return error.Usage;
    var arguments = Arguments{ .command = std.meta.stringToEnum(Command, argv[1]) orelse {
        return error.Usage;
    }, .raw_argv = argv };
    var index: u32 = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--deterministic")) {
            arguments.deterministic = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--hold-scenario")) {
            arguments.hold_scenario = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--exec-at-start")) {
            arguments.exec_at_start = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--continue")) {
            arguments.moment_continue = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--tsc-jitter-exact")) {
            arguments.tsc_jitter_exact = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--exec-interactive")) {
            arguments.moment_interactive = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--extend")) {
            arguments.extend = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--fork-futures")) {
            arguments.fork_futures = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--exec-live")) {
            arguments.moment_interactive = true;
            arguments.moment_live = true;
            arguments.moment_continue = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--cpu-modulation")) {
            arguments.cpu_modulation_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--no-cpu-modulation")) {
            arguments.cpu_modulation_given = false;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--cpu-modulation-stretch-us")) {
            index += 1;
            if (index == argv.len) return error.MissingValue;
            arguments.cpu_modulation_stretch_ns = try stretch_parse(argv[index]);
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--no-holders")) {
            arguments.holders = false;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--verify-holders")) {
            arguments.verify_holders = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--holders-on-disk")) {
            arguments.holders_on_disk = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--holders-retain")) {
            arguments.holders_retain = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--no-holders-writeback")) {
            arguments.holders_writeback = false;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--holders-leave")) {
            arguments.holders_leave = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--holders-on-disk-sync")) {
            arguments.holders_on_disk = true;
            arguments.holders_on_disk_sync = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--archive") or std.mem.eql(u8, argv[index], "--no-archive")) {
            arguments.archive = std.mem.eql(u8, argv[index], "--archive");
            arguments.archive_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--history")) {
            index += 1;
            if (index == argv.len) return error.Usage;
            arguments.history_path = argv[index];
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--strategy-follow")) {
            arguments.strategy_follow = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--run-url")) {
            index += 1;
            if (index == argv.len) return error.Usage;
            arguments.run_url = argv[index];
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--config-bandit") or std.mem.eql(u8, argv[index], "--no-config-bandit")) {
            arguments.config_bandit = std.mem.eql(u8, argv[index], "--config-bandit");
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--ranges") or std.mem.eql(u8, argv[index], "--no-ranges")) {
            arguments.ranges = std.mem.eql(u8, argv[index], "--ranges");
            arguments.ranges_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--memory-objective") or std.mem.eql(u8, argv[index], "--no-memory-objective")) {
            arguments.memory_objective = std.mem.eql(u8, argv[index], "--memory-objective");
            arguments.memory_objective_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--objective-extend") or std.mem.eql(u8, argv[index], "--no-objective-extend")) {
            arguments.objective_extend = std.mem.eql(u8, argv[index], "--objective-extend");
            arguments.objective_extend_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--prefer-severe") or std.mem.eql(u8, argv[index], "--no-prefer-severe")) {
            arguments.prefer_severe = std.mem.eql(u8, argv[index], "--prefer-severe");
            arguments.prefer_severe_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--prefer-sometimes") or std.mem.eql(u8, argv[index], "--no-prefer-sometimes")) {
            arguments.prefer_sometimes = std.mem.eql(u8, argv[index], "--prefer-sometimes");
            arguments.prefer_sometimes_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--swarm") or std.mem.eql(u8, argv[index], "--no-swarm")) {
            arguments.swarm = std.mem.eql(u8, argv[index], "--swarm");
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--resume")) {
            arguments.resume_run = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--setup-only")) {
            arguments.setup_only = true;
            continue;
        }
        if (index + 1 == argv.len) return error.Usage;
        try parse_option(arena, &arguments, argv[index], argv[index + 1]);
        index += 1;
    }
    assert(index == argv.len);
    if (arguments.kernel_path.len == 0 and arguments.command != .validate) return error.Usage; // It boots nothing.
    // Said alone: the usage after it buried it (ParadeDB's 40 GiB lines, trial 2083 on srv4).
    if (arguments.memory_mib < memory_mib_min or arguments.memory_mib > memory_mib_max) {
        say("[determinismo] --memory-mib {d}: a VM takes {d} to {d} MiB\n", .{ arguments.memory_mib, memory_mib_min, memory_mib_max });
        return error.MemorySize;
    }
    if (arguments.time_budget_ns != null and !arguments.branches_given) {
        arguments.branches = branches_max;
    }
    if (arguments.branches == 0 or arguments.branches > branches_max) return error.Usage;
    if (arguments.command == .explore) arguments.deterministic = true;
    // Several vCPUs: the fast VM only (`run`, not deterministic: docs/DEVELOPING.md).
    if (arguments.vcpus == 0 or arguments.vcpus > mptable.cpus_max) return error.Usage;
    if (arguments.vcpus > 1 and (arguments.deterministic or arguments.command != .run)) return error.Usage;
    if (!arguments.pipeline_given and jobs_count(&arguments) <= arguments.generation_size) {
        arguments.pipeline = pipeline_depth_few_workers;
    }
    // An interactive session's first step, when no command was given, is the VMM's no-op
    // (det:here): its own steps come after, the guest's agent not woken at the moment.
    if (arguments.moment_interactive and arguments.moment_command == null and
        arguments.moment_script_path == null) arguments.moment_command = VM.step_here;
    // A command runs at a moment: a virtual time, or the first event matching --until.
    // --exec-at-start's is the snapshot's own (--from-snapshot's).
    if (arguments.exec_at_start and arguments.from_snapshot == null) return error.Usage;
    const moment = arguments.moment_vtime_ms != null or arguments.until != null or arguments.exec_at_start;
    const commands = arguments.moment_command != null or arguments.moment_script_path != null;
    if (commands and !moment) return error.Usage;
    if (arguments.moment_command != null and arguments.moment_script_path != null) {
        return error.Usage;
    }
    if (arguments.rewind_ms != null and arguments.until == null) return error.Usage;
    // A fresh future begins with the commands at the moment (det:reseed first).
    if (arguments.fresh_seed != null and !commands) return error.Usage;
    try branching_resolve(&arguments, moment or commands);
    if (arguments.rewind_ms != null and arguments.strategy_command != null) return error.Usage;
    if (!arguments.generation_given) arguments.generation_size = tree.generation_for(jobs_count(&arguments));
    // From a moment: of a branch (`--from-branch`), or of the taped one (`--tape`).
    if (arguments.from_branch != null and arguments.from_vtime_ms == null) return error.Usage;
    if (arguments.from_vtime_ms != null and arguments.from_branch == null and arguments.tape_path == null) {
        return error.Usage;
    }
    // Saving: one replayed branch, saved where it runs (not from a moment of it).
    if ((arguments.save_directory == null) != (arguments.save_at_ms.len == 0)) return error.Usage;
    if (arguments.save_directory != null) {
        const single = arguments.tape_path != null or arguments.branch_only != null;
        if (!single or arguments.from_vtime_ms != null) return error.Usage;
    }
    // A session's checkpoints: its own timeline's (--extend), among its run's replay snapshots,
    // which a run from a machine's checkpoint never starts from.
    if (arguments.checkpoint_directory != null) {
        if (!arguments.extend or arguments.save_directory != null or arguments.from_snapshot != null) return error.Usage;
    }
    // From a saved snapshot: flat branches from it (their memory is a file's, which holders'
    // copies cannot see in full), nothing replayed to it.
    if (arguments.fork_futures and arguments.from_snapshot == null) return error.Usage;
    // run --from-snapshot: a fast VM going on from one, only.
    if (arguments.command == .run and arguments.from_snapshot != null and arguments.vcpus < 2) return error.Usage;
    if (arguments.command == .explore and arguments.from_snapshot != null) {
        // A tape: a timeline of a run from that snapshot (a machine's checkpoint) replayed.
        const elsewhere = arguments.from_branch != null or arguments.save_directory != null or
            arguments.rewind_ms != null or (arguments.tape_path != null and arguments.fork_futures);
        if (elsewhere or arguments.branching == .tree) return error.Usage;
    }
    // On from a snapshot of the taped timeline: that timeline alone, from there (nothing before
    // it to rewind into, no other moment to fork).
    if (arguments.tape_snapshot != null) {
        const elsewhere = arguments.from_snapshot != null or arguments.from_vtime_ms != null or
            arguments.rewind_ms != null or arguments.fork_futures;
        if (arguments.tape_path == null or elsewhere) return error.Usage;
    }
    arguments.cpu_modulation = arguments.cpu_modulation_given orelse (arguments.command == .explore);
    arguments.cmdline_given = arguments.cmdline;
    if (arguments.deterministic) {
        // VM v1's guests run without the kernel's CPU vulnerability mitigations: no attack surface
        // inside a test (each run's machine its own), entries and syscalls cheaper, and the kernel
        // code they choose by CPU model gone (Antithesis's VM v1 says the same of its machines).
        const vm_v1_extra: []const u8 = if (arguments.guest_cpu == .vm_v1) "mitigations=off" else "";
        const parts = [_][]const u8{ arguments.cmdline, VM.cmdline_deterministic, vm_v1_extra };
        arguments.cmdline = std.mem.trimEnd(u8, try std.mem.join(arena, " ", &parts), " ");
    }
    assert(arguments.cmdline.len > 0);
    return arguments;
}

fn parse_option(
    arena: std.mem.Allocator,
    arguments: *Arguments,
    flag: []const u8,
    value: []const u8,
) !void {
    assert(flag.len > 0);
    const eql = std.mem.eql;
    if (eql(u8, flag, "--kernel")) {
        arguments.kernel_path = value;
    } else if (eql(u8, flag, "--initrd")) {
        arguments.initrd_path = value;
    } else if (eql(u8, flag, "--keep-passing-checks")) {
        arguments.keep_passing_checks = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--holders-budget")) {
        arguments.holders_budget_gb = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--memory-mib")) {
        arguments.memory_mib = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--cmdline")) {
        arguments.cmdline = value;
    } else if (eql(u8, flag, "--append")) {
        arguments.cmdline = try std.mem.join(arena, " ", &.{ arguments.cmdline, value });
    } else if (eql(u8, flag, "--disk")) {
        if (arguments.disk_count == VM.disks_max) return error.Usage;
        arguments.disk_paths[arguments.disk_count] = value;
        arguments.disk_count += 1;
    } else if (eql(u8, flag, "--program")) {
        arguments.program_path = value;
    } else if (eql(u8, flag, "--injector")) {
        const injectors = try arena.alloc([]const u8, arguments.injectors.len + 1);
        @memcpy(injectors[0..arguments.injectors.len], arguments.injectors);
        injectors[arguments.injectors.len] = value;
        arguments.injectors = injectors;
    } else if (eql(u8, flag, "--script")) {
        arguments.script_path = value;
    } else if (eql(u8, flag, "--compose")) {
        arguments.compose_path = value;
    } else if (eql(u8, flag, "--kubernetes")) {
        arguments.kubernetes_path = value;
    } else if (eql(u8, flag, "--images")) {
        var images = std.mem.tokenizeScalar(u8, value, ',');
        while (images.next()) |image| if (!kubernetes.qualified(std.mem.trim(u8, image, " "))) return error.Usage;
        arguments.kubernetes_images = value;
    } else if (eql(u8, flag, "--profile")) {
        arguments.profile = value;
    } else if (eql(u8, flag, "--scenario")) {
        arguments.scenario = value;
    } else if (eql(u8, flag, "--cache")) {
        arguments.cache_directory = value;
    } else if (eql(u8, flag, "--seed")) {
        arguments.seed = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--margin-branches")) {
        arguments.margin_branches = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--watch")) {
        arguments.watch = try watch_parse(value);
    } else if (eql(u8, flag, "--branch-event")) {
        arguments.branch_event = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--cpuid")) {
        arguments.cpuid_path = value;
    } else if (eql(u8, flag, "--dev")) {
        arguments.dev_directory = value;
    } else if (eql(u8, flag, "--vcpus")) {
        arguments.vcpus = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--machines-per-cpu")) {
        // How many fast machines share a CPU (cpus.zig): serve's, given to each it starts.
        cpus.machines_per_cpu = try std.fmt.parseInt(u32, value, 10);
        if (cpus.machines_per_cpu == 0) return error.MachinesPerCpu;
    } else if (eql(u8, flag, "--guest-cpu")) {
        arguments.guest_cpu = std.meta.stringToEnum(VM.GuestCpu, value) orelse return error.UnknownGuestCpu;
    } else if (eql(u8, flag, "--tsc-jitter-seed")) {
        arguments.tsc_jitter_seed = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--timer-slack-us")) {
        arguments.timer_slack_us = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--timer-landing-permille")) {
        const permille = try std.fmt.parseInt(u16, value, 10);
        if (permille > 1000) return error.Usage;
        arguments.timer_delay_permille = permille;
    } else if (eql(u8, flag, "--events")) {
        arguments.events_path = value;
    } else if (eql(u8, flag, "--faults-record")) {
        arguments.faults_record_path = value;
    } else if (eql(u8, flag, "--events-dir")) {
        arguments.events_directory = value;
    } else if (eql(u8, flag, "--trace")) {
        arguments.trace_path = value;
    } else if (eql(u8, flag, "--branches")) {
        arguments.branches = try std.fmt.parseInt(u32, value, 10);
        arguments.branches_given = true;
    } else if (eql(u8, flag, "--mutant")) {
        arguments.mutant = value;
    } else if (eql(u8, flag, "--system")) {
        arguments.pinned = value;
    } else if (eql(u8, flag, "--faults")) {
        arguments.faults_added = value;
    } else if (eql(u8, flag, "--no-faults")) {
        arguments.faults_none = value;
    } else if (eql(u8, flag, "--coverage")) {
        arguments.coverage = value;
    } else if (eql(u8, flag, "--branching")) {
        arguments.branching = std.meta.stringToEnum(@TypeOf(arguments.branching), value) orelse
            return error.Usage;
        arguments.branching_given = true;
    } else if (eql(u8, flag, "--time-budget")) {
        arguments.time_budget_ns = try duration_parse(value);
        arguments.time_budget_text = value;
    } else if (eql(u8, flag, "--timeline-limit")) {
        arguments.timeline_limit_ns = try duration_parse(value);
        arguments.timeline_limit_text = value;
    } else if (eql(u8, flag, "--timeline-limit-learned")) {
        arguments.timeline_limit_learned = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--retroactive")) {
        if (arguments.retroactive_count == retroactive_max) return error.Usage;
        arguments.retroactive[arguments.retroactive_count] = value;
        arguments.retroactive_count += 1;
    } else if (eql(u8, flag, "--changed")) {
        arguments.changed = value;
    } else if (eql(u8, flag, "--changed-repository")) {
        arguments.changed_repository = value;
    } else if (eql(u8, flag, "--return-offsets")) {
        var offsets: std.ArrayList(u64) = .empty;
        var items = std.mem.tokenizeScalar(u8, value, ',');
        while (items.next()) |item| {
            if (offsets.items.len == return_offsets_max) return error.Usage;
            try offsets.append(arena, if (eql(u8, item, "0")) 0 else try duration_parse(item));
        }
        if (offsets.items.len == 0) return error.Usage;
        arguments.return_offsets_ns = offsets.items;
        arguments.return_offsets_text = value;
    } else if (eql(u8, flag, "--horizon")) {
        arguments.horizon_ns = try duration_parse(value);
        arguments.horizon_text = value;
    } else if (eql(u8, flag, "--pipeline")) {
        const depth = try std.fmt.parseInt(u32, value, 10);
        if (depth == 0 or depth > pipeline_depth_max) return error.Usage;
        arguments.pipeline = depth;
        arguments.pipeline_given = true;
    } else if (eql(u8, flag, "--generation")) {
        const size = try std.fmt.parseInt(u32, value, 10);
        const multiple = size % tree.generation_base == 0;
        if (!multiple or size == 0 or size > tree.generation_max) return error.Usage;
        arguments.generation_size = size;
        arguments.generation_given = true;
    } else if (eql(u8, flag, "--return-branches")) {
        const count = try std.fmt.parseInt(u32, value, 10);
        if (count == 0 or count > tree.generation_base) return error.Usage;
        arguments.return_branches = count;
    } else if (eql(u8, flag, "--ingress")) {
        // Where the live timeline takes connections into its machine (sdk.ingress): "ip:port".
        if (std.mem.lastIndexOfScalar(u8, value, ':') == null) return error.Usage;
        arguments.ingress_listen = value;
    } else if (eql(u8, flag, "--decide")) {
        // Named decisions fixed in every timeline: "name=value,...", a range's number or an
        // option's name (advisor.zig's Fixed).
        var entries: std.ArrayList(advisor_zig.Fixed) = .empty;
        var parts = std.mem.tokenizeScalar(u8, value, ',');
        while (parts.next()) |part| {
            const at = std.mem.indexOfScalar(u8, part, '=') orelse return error.Usage;
            if (at == 0 or at + 1 == part.len) return error.Usage;
            try entries.append(arena, .{ .name = part[0..at], .value = part[at + 1 ..] });
        }
        arguments.decide = entries.items;
    } else if (eql(u8, flag, "--egress")) {
        // Where a deterministic machine's egress may connect (sdk.egress): "host", "host:port",
        // "*.domain", "*", comma separated. None given: every connection refused.
        var entries: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, value, ',');
        while (parts.next()) |part| try entries.append(arena, part);
        arguments.egress_allow = entries.items;
    } else if (eql(u8, flag, "--clock-start-max")) {
        arguments.clock_start_max_ms = if (eql(u8, value, "0")) 0 else try duration_parse(value) / std.time.ns_per_ms;
        arguments.clock_start_max_text = value;
    } else if (eql(u8, flag, "--drive-max")) {
        arguments.drive_max_ms = if (eql(u8, value, "none")) null else try duration_parse(value) / std.time.ns_per_ms;
        arguments.drive_max_text = value;
    } else if (eql(u8, flag, "--timeline")) {
        arguments.timeline_ms = try duration_parse(value) / std.time.ns_per_ms;
        arguments.timeline_text = value;
    } else if (eql(u8, flag, "--trace-errno")) {
        arguments.trace_errno = try std.fmt.parseInt(u16, value, 10);
    } else if (eql(u8, flag, "--epoch")) {
        arguments.epoch_seconds = try epoch_parse(value);
    } else if (eql(u8, flag, "--keep")) {
        // Command names, comma-separated, no spaces (a guest command-line word).
        if (value.len == 0 or std.mem.indexOfAny(u8, value, " \t\n") != null) return error.Usage;
        arguments.keep = value;
    } else if (eql(u8, flag, "--fault-weights")) {
        // Kinds and weights, no spaces (a guest command-line word): checked by det-faults.
        if (value.len == 0 or std.mem.indexOfAny(u8, value, " \t\n") != null) return error.Usage;
        arguments.fault_weights = value;
    } else if (eql(u8, flag, "--fault-exclusions")) {
        // Compiled here as det-faults compiles it: a pattern it would not take is a usage error
        // now, not a run whose faults reach what it meant to spare.
        _ = regex.Regex.compile(value) catch |err| {
            say("--fault-exclusions: {s}: {s}\n", .{ value, @errorName(err) });
            return error.Usage;
        };
        arguments.fault_exclusions = value;
    } else if (eql(u8, flag, "--min-drive")) {
        arguments.min_drive_ms = try duration_parse(value) / std.time.ns_per_ms;
        arguments.min_drive_text = value;
    } else if (eql(u8, flag, "--drivers-cpu-weight")) {
        const weight = try std.fmt.parseInt(u64, value, 10);
        if (weight > 10_000) return error.Usage; // cgroup v2's cpu.weight: 1 to 10000.
        arguments.drivers_cpu_weight = weight;
        arguments.drivers_cpu_weight_text = value;
    } else if (eql(u8, flag, "--branch")) {
        arguments.branch_only = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-branch")) {
        arguments.from_branch = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-exec")) {
        arguments.from_exec = value;
    } else if (eql(u8, flag, "--from-poke")) {
        if (value.len > tape.pokes_size_max) return error.PokesTooLong;
        _ = try pokes_parse(value, null); // Refused here, not at the fork point.
        arguments.from_poke = value;
    } else if (eql(u8, flag, "--from-vtime-ms")) {
        arguments.from_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--save-snapshots")) {
        arguments.save_directory = value;
    } else if (eql(u8, flag, "--save-at-ms")) {
        var moments: std.ArrayList(u64) = .empty;
        var parts = std.mem.tokenizeScalar(u8, value, ',');
        while (parts.next()) |part| try moments.append(arena, try std.fmt.parseInt(u64, part, 10));
        if (moments.items.len == 0 or moments.items.len > saver_zig.moments_max) return error.Usage;
        arguments.save_at_ms = moments.items;
    } else if (eql(u8, flag, "--from-snapshot")) {
        arguments.from_snapshot = value;
    } else if (eql(u8, flag, "--tape-snapshot")) {
        arguments.tape_snapshot = value;
    } else if (eql(u8, flag, "--shard")) {
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.Usage;
        arguments.shard_index = try std.fmt.parseInt(u32, value[0..slash], 10);
        arguments.shard_count = try std.fmt.parseInt(u32, value[slash + 1 ..], 10);
        if (arguments.shard_count == 0 or arguments.shard_index >= arguments.shard_count) {
            return error.Usage;
        }
    } else if (eql(u8, flag, "--record")) {
        arguments.record_path = value;
    } else if (eql(u8, flag, "--run-key")) {
        arguments.run_key = try std.fmt.parseInt(linux.pid_t, value, 10);
    } else if (eql(u8, flag, "--verify-replays")) {
        arguments.verify_percent = try std.fmt.parseInt(u32, value, 10);
        if (arguments.verify_percent > 100) return error.Usage;
    } else if (eql(u8, flag, "--jobs")) {
        arguments.jobs = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--strategy")) {
        // Given again: another plugin, after the ones before it (strategies.zig: one a line).
        arguments.strategy_command = if (arguments.strategy_command) |before|
            try std.fmt.allocPrint(arena, "{s}\n{s}", .{ before, value })
        else
            value;
    } else if (eql(u8, flag, "--tape-dir")) {
        arguments.tape_directory = value;
    } else if (eql(u8, flag, "--tape")) {
        arguments.tape_path = value;
    } else if (eql(u8, flag, "--draws-out")) {
        arguments.draws_out = value;
    } else if (eql(u8, flag, "--at-vtime-ms")) {
        arguments.moment_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--stop-at-ns")) {
        arguments.stop_ns = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--data")) {
        arguments.data_directory = value;
    } else if (eql(u8, flag, "--run-directory")) {
        arguments.run_directory = value;
    } else if (eql(u8, flag, "--rewind-ms")) {
        arguments.rewind_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--exec")) {
        arguments.moment_command = value;
    } else if (eql(u8, flag, "--fresh-seed")) {
        arguments.fresh_seed = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--fork-snapshots")) {
        arguments.fork_directory = value;
    } else if (eql(u8, flag, "--checkpoint-snapshots")) {
        arguments.checkpoint_directory = value;
    } else if (eql(u8, flag, "--serve-url")) {
        arguments.serve_url = value;
    } else if (eql(u8, flag, "--exec-script")) {
        arguments.moment_script_path = value;
    } else if (eql(u8, flag, "--start-script")) {
        arguments.start_script_path = value;
    } else if (eql(u8, flag, "--until")) {
        const condition = try arena.create(query.Condition);
        condition.* = try query.parse(arena, value);
        arguments.until = condition;
        arguments.until_text = value;
    } else {
        return error.Usage;
    }
}

fn open_disks(arena: std.mem.Allocator, paths: []const []const u8) ![]const VM.Disk {
    assert(paths.len <= VM.disks_max);
    const disks = try arena.alloc(VM.Disk, paths.len);
    for (paths, disks) |path, *disk| {
        const path_z = try arena.dupeSentinel(u8, path, 0);
        const result = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) {
            say("[determinismo] cannot open disk {s}\n", .{path});
            return error.OpenFailed;
        }
        const fd: linux.fd_t = @intCast(result);
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS) return error.DiskSize;
        if (size % 512 != 0) return error.DiskSizeNotSectors;
        disk.* = .{ .fd = fd, .size = size };
    }
    return disks;
}

/// A new results file (truncated once per process; scenarios of one run append to it).
/// `resumed`: a resumed run's file, kept, its last line ended if the interruption cut it; `kept`:
/// kept as it is.
fn open_for_appending(arena: std.mem.Allocator, path: []const u8, mode: enum { fresh, resumed, kept }) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = mode == .fresh,
        .APPEND = true,
        .CLOEXEC = true,
    };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(result);
    if (mode == .resumed) {
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS) return error.SeekFailed;
        var last: [1]u8 = .{'\n'};
        if (size > 0) _ = linux.pread(fd, &last, 1, @intCast(size - 1));
        if (last[0] != '\n') _ = linux.write(fd, "\n", 1);
    }
    return fd;
}

/// This build of determinismo: a hash of its own executable, read through a small buffer (0
/// when it cannot be read).
fn host_build() u64 {
    const fd = linux.open("/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var hasher = std.hash.Wyhash.init(0);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(count) == .INTR) continue;
        if (linux.errno(count) != .SUCCESS) return 0;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    return hasher.final();
}

fn hex16(value: u64) [16]u8 {
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{value}) catch unreachable;
    return text;
}

/// The scenario a command line runs (`det.scenario=`), if any.
fn scenario_of(cmdline: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "det.scenario=")) return word["det.scenario=".len..];
    }
    return null;
}

/// A script's non-empty lines as one moment command: separated by NUL bytes, which the VMM runs
/// one after the other.
/// A script's commands, a line each (empty lines skipped), NUL-separated. A line ending in a
/// backslash goes on in the next, a newline kept between: a program over several lines in one
/// command (`python3 -c '...'`, which as lines of their own ran as commands of their own).
/// `{timeline}` in a run's commands: the timeline's index, as a number, wherever the command
/// puts it (inside a quoted awk program too); `{timeline%N}` its index modulo N and
/// `{timeline%N+K}` that plus K: a CI job's shard, one run a job, its timelines its shards'
/// (`{timeline%6+1}`). The same in a replay of it: its index is the tape's.
fn timeline_substituted(arena: std.mem.Allocator, command: ?[]const u8, index: u32) !?[]const u8 {
    const text = command orelse return null;
    if (std.mem.indexOf(u8, text, "{timeline") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "{timeline")) |open| {
        try out.appendSlice(arena, text[at..open]);
        const end = std.mem.indexOfScalarPos(u8, text, open, '}') orelse return error.Usage;
        const inside = text[open + "{timeline".len .. end];
        var value: u64 = index;
        if (inside.len > 0) {
            if (inside[0] != '%') return error.Usage;
            const plus = std.mem.indexOfScalar(u8, inside, '+');
            const modulo = std.fmt.parseInt(u64, inside[1 .. plus orelse inside.len], 10) catch return error.Usage;
            if (modulo == 0) return error.Usage;
            value %= modulo;
            if (plus) |p| value += std.fmt.parseInt(u64, inside[p + 1 ..], 10) catch return error.Usage;
        }
        try out.print(arena, "{d}", .{value});
        at = end + 1;
    }
    try out.appendSlice(arena, text[at..]);
    return out.items;
}

test "{timeline} in a run's commands is each timeline's index, {timeline%N+K} its shard" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("awk 'NR % 6 == 2 % 6' t", (try timeline_substituted(arena, "awk 'NR % 6 == {timeline%6+1} % 6' t", 7)).?);
    try std.testing.expectEqualStrings("i=1 at 7", (try timeline_substituted(arena, "i={timeline%3} at {timeline}", 7)).?);
    const plain = "make test";
    try std.testing.expect((try timeline_substituted(arena, plain, 7)).?.ptr == plain.ptr);
    try std.testing.expect(try timeline_substituted(arena, null, 7) == null);
    try std.testing.expectError(error.Usage, timeline_substituted(arena, "{timeline%0}", 7));
    try std.testing.expectError(error.Usage, timeline_substituted(arena, "{timelinex}", 7));
}

/// A run's start steps and a moment inside them: the start's steps but its final waits
/// (det:until, det:wait), the moment's own wait (det:at its virtual time, or det:until its
/// condition), then the moment's commands (none: a no-op, a session's steps coming after). No
/// moment: the start's steps are the commands. Up to the moment the guest sees what the run's
/// timeline saw: the waits are the platform's, never the guest's.
fn start_compose(arena: std.mem.Allocator, arguments: *Arguments, start: []const u8) !void {
    if (!arguments.exec_at_start) return error.Usage; // A start script is the held machine's start.
    const at_vtime = arguments.moment_vtime_ms;
    const until = arguments.until_text;
    if (at_vtime == null and until == null) {
        if (arguments.moment_command != null) return error.Usage; // Two sets of commands, no moment.
        arguments.moment_command = start;
        return;
    }
    var steps: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, start, 0);
    while (parts.next()) |step| try steps.append(arena, step);
    while (steps.items.len > 0) {
        const last = steps.items[steps.items.len - 1];
        if (!std.mem.startsWith(u8, last, "det:until ") and !std.mem.startsWith(u8, last, "det:wait ")) break;
        _ = steps.pop();
    }
    if (at_vtime) |ms| {
        try steps.append(arena, try std.fmt.allocPrint(arena, "det:at {d}", .{ms * std.time.ns_per_ms}));
    } else {
        try steps.append(arena, try std.fmt.allocPrint(arena, "det:until {d} {s}", .{ start_until_ms, until.? }));
    }
    try steps.append(arena, arguments.moment_command orelse VM.step_here);
    arguments.moment_command = try std.mem.join(arena, "\x00", steps.items);
    arguments.moment_vtime_ms = null;
    arguments.until = null;
}

/// How long a moment's condition inside a start script is waited for (virtual time).
const start_until_ms = 24 * std.time.ms_per_hour;

test "a moment inside a run's start steps: the start but its final wait, the moment's wait, its command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = "det:background det-nodes exec app run-tests\x00det:until 86400000 event=exec_done details.background=true";
    var whole: Arguments = .{ .command = .explore, .exec_at_start = true };
    try start_compose(arena, &whole, start);
    try std.testing.expectEqualStrings(start, whole.moment_command.?);
    var at: Arguments = .{ .command = .explore, .exec_at_start = true, .moment_vtime_ms = 338940, .moment_command = "cat /tmp/junit.xml" };
    try start_compose(arena, &at, start);
    try std.testing.expectEqualStrings("det:background det-nodes exec app run-tests\x00det:at 338940000000\x00cat /tmp/junit.xml", at.moment_command.?);
    try std.testing.expect(at.moment_vtime_ms == null);
    var session: Arguments = .{ .command = .explore, .exec_at_start = true, .until_text = "event=x" };
    const condition = try query.parse(arena, "event=x");
    session.until = &condition;
    try start_compose(arena, &session, start);
    try std.testing.expectEqualStrings("det:background det-nodes exec app run-tests\x00det:until 86400000 event=x\x00det:here", session.moment_command.?);
    try std.testing.expect(session.until == null);
    var held: Arguments = .{ .command = .explore };
    try std.testing.expectError(error.Usage, start_compose(arena, &held, start));
}

const Extend = struct { extends: tape.Extends, lineage: []const tape.Segment, events_directory: []const u8, tape_fd: linux.fd_t };

/// Where the events of the timeline `header` is of begin, before its own: its path from the
/// setup snapshot (a tree's chain); for one that extends another (a session's), that one's
/// lineage and it up to the moment, from its tape's header in `tapes` (a session on a session's
/// timeline: the first ones' events are its history too).
fn lineage_of(arena: std.mem.Allocator, io: std.Io, tapes: []const u8, header: tape.Header) ![]const tape.Segment {
    const extends = header.extends orelse return header.chain;
    const name = try std.fmt.allocPrint(arena, "branch-{d}.jsonl", .{extends.branch});
    const source = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ tapes, name }), arena, .unlimited);
    const extended = try tape.header_of(source, try arena.alloc(u8, 64 * 1024));
    const before = try lineage_of(arena, io, tapes, extended);
    const lineage = try arena.alloc(tape.Segment, before.len + 1);
    @memcpy(lineage[0..before.len], before);
    lineage[before.len] = .{ .branch = extends.branch, .seed = extended.branch_seed, .vtime_ns = extends.vtime_ns, .jitter_seed = extended.clock_jitter_seed };
    return lineage;
}

test "a timeline extending one that extends another begins in both: its lineage from their tapes' headers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tapes = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    // Timeline 4, a tree's (from timeline 0 at 2 s); 9 extends it from 5 s; 12 extends 9 from 7 s.
    const chain = [_]tape.Segment{.{ .branch = 0, .seed = 0x11, .vtime_ns = 2_000_000_000 }};
    const headers = [_]tape.Header{
        .{ .inputs = 1, .exploration_seed = 7, .branch = 4, .branch_seed = 0x44, .chain = &chain },
        .{ .inputs = 1, .exploration_seed = 7, .branch = 9, .branch_seed = 0x44, .chain = &chain, .extends = .{ .branch = 4, .vtime_ns = 5_000_000_000 } },
        .{ .inputs = 1, .exploration_seed = 7, .branch = 12, .branch_seed = 0x44, .chain = &chain, .extends = .{ .branch = 9, .vtime_ns = 7_000_000_000 } },
    };
    for (headers) |header| {
        const fd = try open_tape(arena, tapes, header.branch);
        defer close(fd);
        tape.write_header(fd, header);
    }
    // A session on 12 at 8 s: before its own events, 0's to 2 s, 4's to 5 s, 9's to 7 s (then
    // 12's to 8 s, which its opening adds).
    const lineage = try lineage_of(arena, io, tapes, headers[2]);
    try std.testing.expectEqual(@as(usize, 3), lineage.len);
    try std.testing.expectEqual(tape.Segment{ .branch = 0, .seed = 0x11, .vtime_ns = 2_000_000_000 }, lineage[0]);
    try std.testing.expectEqual(tape.Segment{ .branch = 4, .seed = 0x44, .vtime_ns = 5_000_000_000 }, lineage[1]);
    try std.testing.expectEqual(tape.Segment{ .branch = 9, .seed = 0x44, .vtime_ns = 7_000_000_000 }, lineage[2]);
    // A tree's timeline: its chain, no tape read.
    try std.testing.expectEqualSlices(tape.Segment, &chain, try lineage_of(arena, io, tapes, headers[0]));
}

/// A replay's moment and commands with a timeline's taped steps before them: the millisecond of
/// the first step, then each step at its own moment (det:at, as it ran), then the replay's
/// moment and its own commands; with none asked, every step and on to the timeline's end
/// (go_on). Steps before `start_ns` (the snapshot the replay starts from) are in it already.
/// Null: no step comes before the moment.
const Taped = struct { moment_ms: u64, commands: []const u8, go_on: bool };

fn taped_steps_moment(arena: std.mem.Allocator, overrides: *const tape.Overrides, start_ns: u64, moment_ns: ?u64, commands: ?[]const u8) !?Taped {
    var joined: std.ArrayList(u8) = .empty;
    var first: ?u64 = null;
    for (overrides.steps_taped()) |step| {
        if (step.vtime_ns < start_ns) continue; // In the snapshot the replay starts from.
        if (moment_ns) |until_ns| if (step.vtime_ns >= until_ns) break;
        if (first == null) first = step.vtime_ns else try joined.append(arena, 0);
        try joined.print(arena, "det:at {d}", .{step.vtime_ns});
        try joined.append(arena, 0);
        try joined.appendSlice(arena, overrides.step_of(step));
    }
    const start = first orelse return null;
    if (moment_ns) |until_ns| {
        try joined.print(arena, "\x00det:at {d}", .{until_ns});
        if (commands) |own| {
            try joined.append(arena, 0);
            try joined.appendSlice(arena, own);
        }
    }
    return .{ .moment_ms = start / std.time.ns_per_ms, .commands = joined.items, .go_on = moment_ns == null };
}

test taped_steps_moment {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const overrides = try tape.Overrides.create(std.testing.allocator);
    defer overrides.destroy();
    const scratch = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\",\"exploration_seed\":\"0000000000000007\"," ++
        "\"branch\":0,\"branch_seed\":\"00000000000000ff\"}\n" ++
        "{\"vtime\":15000019720,\"step\":\"det:scenario-pause\"}\n" ++
        "{\"vtime\":20000000000,\"step\":\"(boom)\"}\n";
    _ = try tape.parse(source, scratch, overrides);
    // To just before the crash: the pause at its moment, then the replay's own commands.
    const before = (try taped_steps_moment(arena, overrides, 0, 19_950_000_000, ":")).?;
    try std.testing.expectEqual(@as(u64, 15_000), before.moment_ms);
    try std.testing.expectEqualStrings("det:at 15000019720\x00det:scenario-pause\x00det:at 19950000000\x00:", before.commands);
    try std.testing.expect(!before.go_on);
    // The whole timeline: every step at its moment, then on.
    const whole = (try taped_steps_moment(arena, overrides, 0, null, null)).?;
    try std.testing.expectEqualStrings("det:at 15000019720\x00det:scenario-pause\x00det:at 20000000000\x00(boom)", whole.commands);
    try std.testing.expect(whole.go_on);
    // A moment before every step: nothing to deliver.
    try std.testing.expectEqual(@as(?Taped, null), try taped_steps_moment(arena, overrides, 0, 10_000_000_000, ":"));
    // From a snapshot of the timeline past its first step: only what comes after it.
    const inside = (try taped_steps_moment(arena, overrides, 16_000_000_000, 21_000_000_000, ":")).?;
    try std.testing.expectEqualStrings("det:at 20000000000\x00(boom)\x00det:at 21000000000\x00:", inside.commands);
}

fn commands_join(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var continued = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, line, 0) != null) return error.BadScript;
        const goes_on = std.mem.endsWith(u8, line, "\\");
        const body = if (goes_on) line[0 .. line.len - 1] else line;
        if (continued) {
            try joined.append(arena, '\n');
        } else {
            if (body.len == 0 and !goes_on) continue;
            if (joined.items.len > 0) try joined.append(arena, 0);
        }
        try joined.appendSlice(arena, body);
        continued = goes_on;
    }
    if (joined.items.len == 0) return error.BadScript;
    return joined.items;
}

test commands_join {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("a\x00b", try commands_join(arena, "a\n\nb\n"));
    try std.testing.expectEqualStrings("python3 -c 'x = 1\n\nprint(x)'\x00c", try commands_join(arena, "python3 -c 'x = 1\\\n\\\nprint(x)'\r\nc"));
    try std.testing.expectError(error.BadScript, commands_join(arena, "\n\n"));
}

fn open_for_writing(arena: std.mem.Allocator, path: []const u8) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    assert(result <= std.math.maxInt(i32));
    return @intCast(result);
}

fn monotonic_ns() u64 {
    var time: linux.timespec = undefined;
    const result = linux.clock_gettime(.MONOTONIC, &time);
    assert(linux.errno(result) == .SUCCESS);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

test branch_seed {
    try std.testing.expect(branch_seed(1, 0) != branch_seed(1, 1));
    try std.testing.expectEqual(branch_seed(7, 3), branch_seed(7, 3));
}

test {
    _ = @import("strategy.zig");
    _ = @import("strategies.zig");
    _ = @import("wasm_plugin.zig");
    _ = @import("core").kvm;
    _ = @import("core").rtc;
    _ = @import("core").pit;
    _ = @import("core").serial;
    _ = @import("core").vm;
    _ = @import("core").cpuid;
    _ = @import("core").decisions;
    _ = @import("core").events;
    _ = @import("core").tape;
    _ = @import("fd_pass.zig");
    _ = @import("core").virtio_block;
    _ = @import("prepare.zig");
    _ = @import("serve.zig");
    _ = @import("serve_call.zig");
    _ = @import("runs.zig");
    _ = @import("host_core.zig");
    _ = @import("advisor.zig");
    _ = @import("mcp.zig");
    _ = @import("merge.zig");
    _ = @import("script.zig");
    _ = @import("tla.zig");
    _ = @import("quint.zig");
    _ = @import("veil.zig");
    _ = @import("core").guest_memory;
    _ = @import("query.zig");
    _ = @import("runs_cli.zig");
    _ = @import("duckdb.zig");
    _ = @import("store.zig");
    _ = @import("draws.zig");
    _ = @import("cpus.zig");
    _ = @import("holders.zig");
    _ = @import("event_files.zig");
    _ = @import("label.zig");
    _ = @import("activity.zig");
    _ = @import("checks.zig");
    _ = @import("causality.zig");
    _ = @import("explain.zig");
    _ = @import("shrink.zig");
    _ = @import("mutate.zig");
    _ = @import("changed.zig");
    _ = @import("lines.zig");
    _ = @import("extract.zig");
    _ = @import("event_sets.zig");
    _ = @import("profile.zig");
    _ = @import("core").regex;
    _ = @import("compose.zig");
    _ = @import("kubernetes.zig");
    _ = @import("yaml.zig");
    _ = @import("report.zig");
    _ = @import("core").snapshot;
    _ = @import("bandit.zig");
    _ = @import("core").replay_snapshots;
    _ = @import("bundle.zig");
    _ = @import("timeline_limit.zig");
}

test "serve's store names the learned limit's property as the explorer does" {
    try std.testing.expectEqualStrings(report.learned_limit_property, @import("store.zig").learned_limit_property);
}

test "a judged generation's plan starts before the filler, whenever it is judged" {
    const arena = std.testing.allocator;
    // Only what the queue uses: the rest of a tree's state is a run's.
    var state: TreeState = undefined;
    state.resumed = null;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.users = .empty;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    const index = struct {
        fn place(at: u32) Planned {
            return .{ .index = at, .seed = at, .snapshot = @ptrFromInt(@alignOf(Snapshot)) };
        }
    }.place;
    // The pipeline: a generation planned, two of filler.
    try queue_push(arena, &state, index(0));
    try queue_push(arena, &state, index(1));
    for (2..6) |at| try queue_fill(arena, &state, index(@intCast(at)));
    try std.testing.expectEqual(@as(u32, 0), queue_next(&state).?.index);
    try std.testing.expectEqual(@as(u32, 1), queue_next(&state).?.index);
    try std.testing.expectEqual(@as(u32, 2), queue_next(&state).?.index); // Filler: nothing planned.
    // The first generation judged: its plan before the rest of the filler.
    try queue_push(arena, &state, index(6));
    try queue_push(arena, &state, index(7));
    try std.testing.expectEqual(@as(u32, 6), queue_next(&state).?.index);
    try queue_push(arena, &state, index(8)); // Behind 7, still before the filler.
    try std.testing.expectEqual(@as(u32, 7), queue_next(&state).?.index);
    try std.testing.expectEqual(@as(u32, 8), queue_next(&state).?.index);
    try std.testing.expectEqual(@as(u32, 3), queue_next(&state).?.index);
    try std.testing.expectEqual(@as(u32, 9), state.users.get(setup).?);
}

test "while a judgment's nodes are made and nothing is planned, a CPU takes a fresh timeline" {
    const arena = std.testing.allocator;
    var state: TreeState = undefined;
    state.resumed = null;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = false;
    state.users = .empty;
    state.base = 7;
    state.generation = 5;
    state.next_index = 300;
    state.total = 302;
    state.tape_directory = null;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    // The old dispatch: nothing planned, nothing to start (run 1832's CPUs idle for minutes).
    try std.testing.expectEqual(@as(?Planned, null), queue_next(&state));
    // Not judging: nothing (the run's end, or its last generation judged when all have ended).
    try std.testing.expectEqual(@as(?Planned, null), try queue_take(arena, &state, false, setup));
    // Judging: fresh ones from the setup snapshot, of the next generation, up to the run's total.
    const first = (try queue_take(arena, &state, true, setup)).?;
    try std.testing.expectEqual(@as(u32, 300), first.index);
    try std.testing.expectEqual(branch_seed(7, 300), first.seed);
    try std.testing.expectEqual(setup, first.snapshot);
    try std.testing.expectEqual(@as(u32, 6), first.generation);
    try std.testing.expectEqual(@as(u32, 301), (try queue_take(arena, &state, true, setup)).?.index);
    try std.testing.expectEqual(@as(?Planned, null), try queue_take(arena, &state, true, setup));
    try std.testing.expectEqual(@as(u32, 2), state.users.get(setup).?);
    // A judged generation's plan still goes first, before such fresh ones not started yet.
    state.total = 304;
    try queue_fresh(arena, &state, setup); // 302, waiting.
    var branch = first;
    branch.index = 303;
    try queue_push(arena, &state, branch);
    try std.testing.expectEqual(@as(u32, 303), (try queue_take(arena, &state, true, setup)).?.index);
    try std.testing.expectEqual(@as(u32, 302), (try queue_take(arena, &state, true, setup)).?.index);
}

test "a judgment's made nodes start their branches whatever their order: a slow first one holds none back" {
    // Run 2114 (the #558 harness, 2026-11-21): a generation's first node took 806 s to replay
    // (a return to 995 s of a generation-0 timeline, no holder left) while its other five were
    // made in seconds; planned as a prefix, none of their branches could start, and the judgment
    // waited 807 s with the CPUs on fillers.
    var state: TreeState = undefined;
    state.resumed = null;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.users = .empty;
    state.base = 7;
    state.children = 2;
    state.next_index = 100;
    state.total = 200;
    state.tape_directory = null;
    // The queue and its users grow by the planner's allocator (the run's arena): the test's own.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var arguments: Arguments = .{ .command = .explore };
    var branches: Branches = undefined;
    branches.arguments = &arguments;
    const node: *const Snapshot = @ptrFromInt(2 * @alignOf(Snapshot));
    const parent: Planned = .{ .index = 40, .seed = 1, .snapshot = @ptrFromInt(@alignOf(Snapshot)) };
    var makings = [_]NodeMaking{
        .{ .back = .{ .branch = 40, .vtime_ns = 995 * std.time.ns_per_s, .why = "far" }, .parent = parent },
        .{ .back = .{ .branch = 40, .vtime_ns = 10 * std.time.ns_per_s, .why = "near" }, .parent = parent, .ready = true, .snapshot = node },
    };
    var judging: Judging = undefined;
    judging.generation = 9;
    judging.makings = &makings;
    judging.making_count = makings.len;
    judging.planned = 0;
    judging.branches_planned = 0;
    judging.made = .{};
    try judge_plan_ready(arena_state.allocator(), branches, &state, &judging);
    // The second node's two branches queued, though the first is still being made.
    try std.testing.expectEqual(@as(u32, 1), judging.planned);
    try std.testing.expectEqual(@as(u32, 2), judging.branches_planned);
    const first = queue_next(&state).?;
    try std.testing.expectEqual(node, first.snapshot);
    try std.testing.expectEqual(@as(u32, 100), first.index);
    try std.testing.expectEqual(@as(u32, 101), queue_next(&state).?.index);
    // Planned once: the first node, made later, plans its own two after them.
    makings[0].ready = true;
    makings[0].snapshot = node;
    try judge_plan_ready(arena_state.allocator(), branches, &state, &judging);
    try std.testing.expectEqual(@as(u32, 2), judging.planned);
    try std.testing.expectEqual(@as(u32, 4), judging.branches_planned);
    try std.testing.expectEqual(@as(u32, 102), queue_next(&state).?.index);
}

test "no fresh timeline starts while a judgment's makers wait for memory; a planned one still does" {
    // Run 2106 (etcd, 2026-11-21): its claims back at the guests' 4 GiB, the makers waited for
    // room the filler's VMs took as it freed; judgments went from 35 s to over 538 s and the
    // filler ran most timelines.
    const arena = std.testing.allocator;
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = true;
    state.resumed = null;
    state.users = .empty;
    state.base = 7;
    state.generation = 5;
    state.next_index = 300;
    state.total = 304;
    state.tape_directory = null;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    // Indices compared: a Planned printed (a failure's) reads its snapshot, a fake one here.
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    try std.testing.expectEqual(@as(?u32, null), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
    try std.testing.expectEqual(@as(u32, 300), state.next_index);
    // A judged generation's branch is no filler: it starts.
    try queue_push(arena, &state, .{ .index = 303, .seed = 1, .snapshot = setup, .generation = 6, .why = "planned" });
    try std.testing.expectEqual(@as(u32, 303), (try queue_take(arena, &state, true, setup)).?.index);
    try std.testing.expectEqual(@as(?u32, null), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
    // Room for them again: the filler starts.
    state.makers_short = false;
    try std.testing.expectEqual(@as(u32, 300), (try queue_take(arena, &state, true, setup)).?.index);
}

test "no queued filler starts while a judgment's makers wait for memory" {
    // 48 workers, VMs of 10 GiB guests on 192 GiB (17 fit), 22 minutes a timeline, 2 hours: the
    // first judgment's makers waited 21 minutes for room while the pipeline's filler, queued at
    // the launch, went on taking workers; no returned timeline ever got a VM (73 timelines, all
    // of the first generation).
    const arena = std.testing.allocator;
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = true;
    state.resumed = null;
    state.users = .empty;
    state.base = 7;
    state.generation = 0;
    state.next_index = 144;
    state.total = 400;
    state.tape_directory = null;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    try queue_fill(arena, &state, .{ .index = 48, .seed = 1, .snapshot = setup });
    try std.testing.expectEqual(@as(?u32, null), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
    // A judged generation's branch still starts, before that filler; the filler still waits.
    try queue_push(arena, &state, .{ .index = 144, .seed = 1, .snapshot = setup, .generation = 1, .why = "planned" });
    try std.testing.expectEqual(@as(u32, 144), (try queue_take(arena, &state, true, setup)).?.index);
    try std.testing.expectEqual(@as(?u32, null), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
    // Room again, and with no judgment waiting: the filler starts.
    state.makers_short = false;
    try std.testing.expectEqual(@as(u32, 48), (try queue_take(arena, &state, true, setup)).?.index);
}

test "a recorded timeline needs no VM: held back with no filler" {
    const arena = std.testing.allocator;
    var resumed: Resumed = .{};
    defer resumed.summaries.deinit(arena);
    try resumed.summaries.put(arena, 48, "");
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = true;
    state.users = .empty;
    state.resumed = &resumed;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    try queue_fill(arena, &state, .{ .index = 48, .seed = 1, .snapshot = setup });
    try queue_fill(arena, &state, .{ .index = 49, .seed = 1, .snapshot = setup });
    // Recorded (a resume loads its summary): taken though makers wait for memory.
    try std.testing.expectEqual(@as(?u32, 48), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
    // The next is not: it waits.
    try std.testing.expectEqual(@as(?u32, null), if (try queue_take(arena, &state, true, setup)) |taken| taken.index else null);
}

test "workers take no timeline ahead of the VMs that fit: a judgment's branch runs next but one" {
    // 48 workers, 17 VMs that fit, 144 timelines queued at the launch (aws-hunt run 18): every
    // worker took one, and 31 waited for memory ahead of the first judgment's branches for good.
    const jobs = 48;
    const fit = 17;
    const arena = std.testing.allocator;
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = false;
    state.users = .empty;
    state.resumed = null;
    state.next_index = 400;
    state.total = 400;
    defer state.queue.deinit(arena);
    defer state.users.deinit(arena);
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    for (0..48) |index| try queue_push(arena, &state, .{ .index = @intCast(index), .seed = 1, .snapshot = setup });
    for (48..144) |index| try queue_fill(arena, &state, .{ .index = @intCast(index), .seed = 1, .snapshot = setup });
    const Fits = struct {
        admitted: u32,
        fn room(fits: @This(), vms: u32) bool {
            return fits.admitted + vms <= fit;
        }
    };
    var running: [jobs]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    var started: u32 = 0;
    while (started < jobs) {
        const waiting = timelines_waiting(running[0..started], &admissions);
        if (timeline_gated(Fits{ .admitted = started - waiting }, waiting)) break;
        _ = (try queue_take(arena, &state, false, setup)) orelse break;
        running[started].slot = @intCast(started);
        if (started < fit) admissions[started] = 1; // The admission's: as many as fit.
        started += 1;
    }
    try std.testing.expectEqual(@as(u32, fit + 1), started); // Those that fit, and one waiting.
    try queue_plan(arena, &state, .{ .index = 144, .seed = 1, .snapshot = setup, .generation = 1 });
    // The first to end lets the one waiting in: the branch is the next one taken. The loop's
    // order is the queue's, so nothing of the first generation is left before it but that one.
    running[0] = running[started - 1];
    started -= 1;
    admissions[running[0].slot] = 1; // The one in line, admitted into the room freed.
    const waiting = timelines_waiting(running[0..started], &admissions);
    try std.testing.expect(!timeline_gated(Fits{ .admitted = fit }, waiting));
    while (try queue_take(arena, &state, false, setup)) |taken| {
        if (taken.index == 144) break;
        try std.testing.expect(taken.index < 48); // Never the filler before it.
    } else return error.BranchNeverTaken;
}

test "a run gated by memory learns its claim as with every worker's timeline taken" {
    const mib: u64 = 1 << 20;
    const gib: u64 = 1 << 30;
    // ParadeDB's run 2098: 4 VMs of 32 GiB guests fit, 40 workers. Gated, 5 timelines taken:
    // learned as the 40 taken were (2.6 GB held once flat: 3.9 GB claimed), not never.
    var gated: cpus.ClaimLearning = .{};
    for ([_]u64{ 2200, 2400, 2550 }) |held| gated.sample(held * mib, 4, learning_workers(5, 40, true), 40, 0);
    try std.testing.expectEqual(@as(u64, 0), gated.claim(32 * gib)); // Young and growing: not yet.
    for (0..cpus.ClaimLearning.plateau_looks) |_| gated.sample(2600 * mib, 4, learning_workers(5, 40, true), 40, 0);
    try std.testing.expectEqual(3900 * mib, gated.claim(32 * gib));
    // Its 2.2 GB fault: a judgment's looks, the VMs young and few, take nothing down.
    for (0..200) |_| gated.sample(1400 * mib, 2, learning_workers(3, 40, true), 40, 45);
    try std.testing.expectEqual(3900 * mib, gated.claim(32 * gib));
    // Workers idle for another reason (nothing queued, not memory): nothing counted, as before.
    var idle: cpus.ClaimLearning = .{};
    for (0..100) |_| idle.sample(2 * gib, 4, learning_workers(5, 40, false), 40, 50);
    try std.testing.expectEqual(@as(u64, 0), idle.claim(32 * gib));
}

test "a learned claim rises as the VMs grow while workers are idle" {
    const gib: u64 = 1 << 30;
    var learning: cpus.ClaimLearning = .{};
    learning.sample(2 * gib, 40, 40, 40, 40);
    try std.testing.expectEqual(3 * gib, learning.claim(32 * gib));
    // Filler held for a judgment's makers: 20 workers idle, and what the running VMs hold grows.
    learning.sample(3 * gib, 20, 20, 40, 60);
    try std.testing.expectEqual(3 * gib / 2 * 3, learning.claim(32 * gib));
    // Nothing learned yet: idle workers still teach nothing.
    var young: cpus.ClaimLearning = .{};
    young.sample(2 * gib, 20, 20, 40, 60);
    try std.testing.expectEqual(@as(u64, 0), young.claim(32 * gib));
}

test "a replay's claim is no running timeline" {
    // Run 2125, 20:08: 35 started, the run's 35 claims 34 timelines' and a replay's.
    var running: [35]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    for (&running, 0..) |*timeline, slot| timeline.slot = @intCast(slot);
    for (admissions[0..34]) |*admitted| admitted.* = 1;
    try std.testing.expectEqual(@as(u32, 1), timelines_waiting(&running, &admissions));
}

test "makers in line hold no timeline back" {
    // 34 started and running, one maker holding a CPU, five more in line, no room for another.
    var running: [34]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    for (&running, 0..) |*timeline, slot| timeline.slot = @intCast(slot);
    for (admissions[0..34]) |*admitted| admitted.* = 1;
    const full = struct {
        fn room(_: @This(), _: u32) bool {
            return false;
        }
    }{};
    const waiting = timelines_waiting(&running, &admissions);
    try std.testing.expectEqual(@as(u32, 0), waiting);
    try std.testing.expect(!timeline_gated(full, waiting)); // A judged branch may take its place in line.
    try std.testing.expect(timeline_gated(full, 1)); // A second may not.
}

test "nothing is offered past the run's timeline limit" {
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = false;
    state.resumed = null;
    state.next_index = 400;
    state.total = 400;
    try std.testing.expect(!queue_offers(&state, true));
}

test "a timeline whose VM gave its CPU back is not waiting" {
    // 35 admitted, one of them finishing: its CPU given, not reaped yet.
    var running: [35]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    for (&running, 0..) |*timeline, slot| timeline.slot = @intCast(slot);
    for (admissions[0..35]) |*admitted| admitted.* = 1;
    try std.testing.expectEqual(@as(u32, 0), timelines_waiting(&running, &admissions));
}

test "a fresh timeline refused while makers are short is no held filler" {
    var state: TreeState = undefined;
    state.queue = .empty;
    state.queue_head = 0;
    state.filler_start = 0;
    state.makers_short = true;
    state.resumed = null;
    state.next_index = 10;
    state.total = 400;
    // Refused before f02c124 too: it shows nothing of that fix acting.
    try std.testing.expect(!queue_filler_held(&state, true));
    try std.testing.expect(queue_held_back(&state, true)); // It waits, as it did: no queued filler held.
    state.next_index = 400; // At the run's limit: nothing waits for memory.
    try std.testing.expect(!queue_held_back(&state, true));
}

test "a timeline never admitted teaches no claim: only the explorer's memory is its" {
    // Run 2125, 20:24: young ones in line showed 1.6 GiB, the explorer's own.
    var running: [2]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    for (&running, 0..) |*timeline, slot| {
        timeline.slot = @intCast(slot);
        timeline.short = false;
    }
    admissions[0] = 1;
    try std.testing.expect(vm_counts(&running[0], &admissions));
    try std.testing.expect(!vm_counts(&running[1], &admissions));
    try std.testing.expectEqual(@as(u32, 1), vms_admitted(&running, &admissions));
}

test "short of memory, the youngest admitted ends, never the one in line" {
    var running: [3]Running = undefined;
    var admissions: [jobs_max]u64 = @splat(0);
    for (&running, 0..) |*timeline, slot| {
        timeline.slot = @intCast(slot);
        timeline.short = false;
        timeline.start_ns = 100 + slot;
    }
    admissions[0] = 1;
    admissions[1] = 1; // The third waits: killed, it frees nothing and comes back first in the queue.
    try std.testing.expectEqual(@as(?*Running, &running[1]), vms_youngest(&running, &admissions));
}

test "a first claim learned while workers wait on memory needs the plateau, however many ended" {
    const gib: u64 = 1 << 30;
    var learning: cpus.ClaimLearning = .{ .memory_idle = true };
    learning.sample(2 * gib, 2, 40, 40, 45); // One look, at one young VM.
    try std.testing.expectEqual(@as(u64, 0), learning.claim(32 * gib));
    for (0..cpus.ClaimLearning.plateau_looks) |_| learning.sample(2 * gib, 2, 40, 40, 45);
    try std.testing.expectEqual(3 * gib, learning.claim(32 * gib));
}

test "the tree passes over a number a timeline extending another took, and plans the same again resumed" {
    const arena = std.testing.allocator;
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/det-tree-claim-{d}", .{linux.getpid()}, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(directory, 0o755)));
    defer {
        var path_buffer: [96]u8 = undefined;
        for (0..4) |index| {
            const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/branch-{d}.jsonl", .{ directory, index }, 0) catch unreachable;
            _ = linux.unlink(path);
        }
        _ = linux.rmdir(directory);
    }
    const setup: *const Snapshot = @ptrFromInt(@alignOf(Snapshot));
    // A session opened on timeline 0 as the tree had planned 0 alone: it took 1.
    try std.testing.expect(tape.claim(directory, 0));
    var header: tape.Header = .{ .inputs = 1, .exploration_seed = 7, .branch = 0, .branch_seed = 9, .extends = .{ .branch = 0, .vtime_ns = 5 } };
    _ = linux.close(try tape.claim_next(directory, &header));
    try std.testing.expectEqual(@as(u32, 1), header.branch);
    // The tree's next ones: 2 and 3, never 1; and the same from a record resumed (its own
    // tapes there from before, the session's too).
    for (0..2) |_| {
        var state: TreeState = undefined;
        state.resumed = null;
        state.queue = .empty;
        state.queue_head = 0;
        state.filler_start = 0;
        state.users = .empty;
        state.base = 7;
        state.generation = 0;
        state.next_index = 1;
        state.total = 4;
        state.tape_directory = directory;
        defer state.queue.deinit(arena);
        defer state.users.deinit(arena);
        const first = (try queue_take(arena, &state, true, setup)).?;
        try std.testing.expectEqual(@as(u32, 2), first.index);
        try std.testing.expectEqual(branch_seed(7, 2), first.seed);
        try std.testing.expectEqual(@as(u32, 3), (try queue_take(arena, &state, true, setup)).?.index);
        try std.testing.expectEqual(@as(?Planned, null), try queue_take(arena, &state, true, setup));
    }
}

test "a finished timeline's summary is read whole even when its generation has no slot left" {
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    const pid = linux.fork();
    if (pid == 0) {
        // A worker: its results, one summary (larger than a pipe holds), then it exits.
        _ = linux.close(pipe[0]);
        const results = std.heap.page_allocator.create(report.Multiverse) catch linux.exit_group(1);
        results.* = .{};
        write_all(pipe[1], std.mem.asBytes(results));
        const count: u32 = 1;
        write_all(pipe[1], std.mem.asBytes(&count));
        const summary = std.heap.page_allocator.create(Summary) catch linux.exit_group(1);
        @memset(std.mem.asBytes(summary), 0);
        write_all(pipe[1], std.mem.asBytes(summary));
        linux.exit_group(0);
    }
    _ = linux.close(pipe[1]);
    // The pipe's read end held elsewhere too, as the explorer's other forks hold it: its close
    // alone never ends the worker's write.
    const held: linux.fd_t = @intCast(linux.dup(pipe[0]));
    defer _ = linux.close(held);
    const multiverse = try std.testing.allocator.create(report.Multiverse);
    defer std.testing.allocator.destroy(multiverse);
    multiverse.* = .{};
    const items = try std.testing.allocator.alloc(Summary, 1);
    defer std.testing.allocator.free(items);
    var summaries: Summaries = .{ .items = items, .count = 1 }; // Full: past the budget.
    const running = [_]Running{.{ .pid = @intCast(pid), .results = pipe[0], .place = undefined, .index = 0, .start_ns = 0, .slot = 0 }};
    const finished = (try timeline_wait(&running, multiverse, &summaries, -1)).?;
    try std.testing.expectEqual(@as(usize, 0), finished.at);
    try std.testing.expectEqual(@as(u32, 1), summaries.count);
}
