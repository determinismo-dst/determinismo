# Debugging a timeline: watching and changing memory

A replay is exact, so a timeline can be stopped at any moment and looked at as often as needed.
Besides running commands there (`--at-vtime-ms <ms> --exec '<command>'`, serve's "At this moment"),
the VMM can watch guest memory for writes during a replay and change guest memory at a fork
point. Both are for a person's question, never for exploration: they cost exits, and pages are
shared by unrelated data (allocator arenas, the page cache).

Both take guest physical addresses. A process's virtual address becomes one through its
`/proc/<pid>/pagemap` (8 bytes a page: bit 63 present, bits 0-54 the frame), read at the moment:

    --at-vtime-ms <ms> --exec 'p=<pid>; a=<virtual address, decimal>;
      dd if=/proc/$p/pagemap bs=8 skip=$((a / 4096)) count=1 2>/dev/null | od -An -tx8'

The frame times 4096, plus the address's offset in its page (`a % 4096`), is the physical address.
A page not present (bit 63 clear) has no frame yet: pick a moment after the process touched it.

## Who wrote this, and when: `--watch`

    determinismo explore <machine> --run <run> --branch <timeline> \
      --watch <guest physical address>[:<bytes>] [--at-vtime-ms <ms>]

Every write to those bytes during the replay is printed, one JSON line each:

    [determinismo] watch: {"vtime_ns":138206000123,"branches":18493748051,"address":"0x3f2a018",
      "size":8,"before":"0x0","after":"0x1","rip":"0xffffffff8123abcd","cr3":"0x2b4e000"}

`rip` is the instruction that wrote, `cr3` the address space it ran in (one per process). The
watched pages are mapped read-only in KVM, so each write to them exits; the VMM applies it and
resumes without the exit counting as the guest's (no clock modulation, no timer): the replay is
the recorded history, which its events hash shows. A replay from a snapshot near the question's
window keeps it short (`--tape-snapshot`, serve's saved replays).

A page holding page tables cannot be watched: the CPU sets their accessed and dirty bits itself, which KVM cannot emulate on a read-only page, and the guest stops (a 1 MiB watch over the kernel's image never let it boot). Watch the bytes in question, not a wide range.

Not seen: writes the VMM itself makes (the virtual disks' DMA into the page cache), which do not
go through the guest's CPU. Watching a stack page can break exactness: a `call` whose push lands
there is emulated by KVM, and the CPU's branch counter, the guest's clock, does not count it.

## What if: `--from-poke`

    determinismo explore <machine> --run <run> --from-branch <timeline> --from-vtime-ms <ms> \
      --from-poke '<guest physical address>=<hex bytes>[,<address>=<hex bytes>...]' [--branches <n>]

At the fork point the VMM writes the bytes into guest RAM (after `--from-exec`, if given), then
snapshots: the fork's timelines go on from the changed memory. Data or code, the guest's own
protections do not apply (a VM entry is serializing: patched instructions take effect when it
resumes). The pokes are on each branch's tape (`from_poke`), so the branches replay exactly. A
shared page (a library, copy-on-write after a fork, a file's page cache) changes for every
process that maps it.

## Looking and changing at a moment: `det:regs`, `det:mem`, `det:poke`

Steps a moment's script runs (`--exec-script`, a serve session's steps), the VMM's own, the
vCPU stopped:

    det:regs                                  the registers, a JSON line (rip, rsp, ..., cr3, and
                                              xmm0 to xmm7's low 64 bits: float arguments)
    det:mem <guest physical address> [bytes]  memory as hex, 4 KiB at most (64 by default)
    det:poke <address>=<hex bytes>[,...]      written into guest RAM
    det:step <n>                              the guest runs on n taken branches (jumps, calls,
                                              returns; one more at most), stopped there
    det:break <virtual address> [cr3] | off   a hardware execute breakpoint (one), in that
                                              address space or any
    det:watch <virtual address> <bytes> [cr3] | off
                                              a hardware write watchpoint (one; 1, 2, 4 or 8
                                              bytes, aligned to their size), in that address
                                              space or any
    det:continue [ms]                         on until the breakpoint or a watched write (or ms
                                              of virtual time, 60 s by default), stopped before
                                              the breakpoint's instruction, after the write
    det:collect [ms]                          on for ms of virtual time (10 s by default), each
                                              hit of the breakpoint or the watch said as it
                                              passes ("hit": a write's bytes, a call's argument
                                              registers), 10,000 at most (the rest counted),
                                              stopped at the window's end: many hits, one request
    det:translate <cr3 | current> <virtual>   a virtual address's physical one, through the page
                                              tables of that address space (det:regs' cr3, a
                                              watch hit's), or the running one's

Stops change nothing either: a replay to 5 s that stopped at a breakpoint twice and stepped has
the plain replay's events hash (timers fire where they would; the breakpoint's exits are the
VMM's, the instruction passed once with RF). A watched write's stop says the bytes written, in
memory order, with its moment (`"watch"`, `"size"`, `"hex"` beside `vtime_ns`, `branches`, `rip`
and `cr3`): `det:continue` again goes to the next one, so a variable's values over a stretch of a
timeline are the stops' lines, each a moment a session can be opened at. A node's variable by
its name: `det-nodes symbol <node> <name> [--field <path>] [--pid <pid>]`, a guest command, says where it is in the first
of the node's processes that defines it (its program's symbols, then its libraries'): its
`address` there, `size`, `kind`, the `physical` address of its page now (null until the
process first touched it), its `type` from the module's DWARF (`kind`: signed, unsigned,
float, boolean, pointer, aggregate; `size`, `name`; null without DWARF), with `--field` a field
of it by its path (`stats.accepted`, `table[2].key`: structures, unions and arrays followed,
pointers not), a function's `params` from its DWARF definition (`name`, `kind`, `size`,
`type`, in order) and a `probe`, a page of the process's own (its stack's top) by which
a stop in any address space is told the process's or not. The REPL's `symbol`, `watch-values`
(a variable's writes) and `calls` (a function's calls, its arguments the calling convention's
registers at its entry, by their parameters' names and types when the module has DWARF: a
float's from its vector register) take it from there, keeping to the process's address space from its
first stop there. `det-nodes where <node> <address>... [--return]` names each address as a crash's
stack names its frames (its source line, its Go function and line, its ELF function with Rust's
and C++'s paths demangled, else its module and offset), with the ELF function beside a line;
the REPL's `frames` reads a process's
stack at a stop inside it (a breakpoint's, a watch's) and unwinds it there: the stop's own
instruction, then each caller by its frame's rule (`det-nodes cfi`: the module's .eh_frame, as
Rust and C++ release code needs, else the frame pointers'), each named; and `moment-when`
bisects a timeline to the first moment a look holds (a fresh session each look, to the
millisecond, then to the taken branch with det:step): where a value changed, for instance, then
`frames` there for who changed it. `across` does one look in many timelines: a session in each of a run's
timelines an event query keeps (the first eight, or those named), opened at the condition's
first match, the look done there and the session closed, one session at a time. Looking moves nothing: these steps leave the vCPU where it is, the next one queued runs there,
and a session (not live) waits for the next request with the machine stopped, so every look
between requests sees one state; the guest moves only with a guest command (or a step that runs
it). A bad one answers `[determinismo] debug: {"step":..., "error":...}` and the session goes on.
Guest commands go between them as usual (`cat /proc/<pid>/maps`, the pagemap read above).

From anywhere, over serve's API (curl, a jank or Clojure client, an agent; remotely through
Tailscale or an SSH tunnel):

    curl -X POST localhost:7878/runs/<run>/session \
      -d '{"branch":0,"until":"event=composer_start"}'           # -> {"session":4,"timeline":16}
    curl -X POST localhost:7878/sessions/4/step -d '{"exec":"det:regs"}'
    curl -X POST localhost:7878/sessions/4/step -d '{"exec":"det:mem 0x24079c0 8"}'
    curl -X POST localhost:7878/sessions/4/step -d '{"exec":"det-nodes exec n1 cat /proc/1/maps"}'
    curl -X POST localhost:7878/sessions/4/end -d '{}'

The moment is an event's: `until`, a condition in the query language, the first event of the
timeline that matches, and `rewind_ms` before it (`at_vtime_ms` when a time itself is meant).
The query's temporal conditions name it among others (`preceded_by`, `not_preceded_by`,
`followed_by`, `not_followed_by` another condition, `within` seconds of virtual time):
`{"until":"event=ingress_open","not_followed_by":"event=ingress_open","rewind_ms":1}` is just
before the last connection a relay took.

## A session is a timeline

A session is recorded as a timeline of its run: the one it was opened on up to its moment, its
own from there, under the run's next number (the reply's `timeline`; `explore --extend`). Its
steps (commands, pokes, and its waits too: where one stops is where the next begins) and what
came in from outside (a relay's connections) are on its tape at the moments they happened, its
events in the run's events from the moment on, its line in the record (`extends`: the timeline
and the moment). So it is queried, replayed, drawn on the map and opened by another session as
any timeline is:

    curl -X POST localhost:7878/runs/<run>/query \
      -d '{"condition":"event=node_kill details.node=n1","branch":16,"limit":1}'
    curl -X POST localhost:7878/runs/<run>/session \
      -d '{"branch":16,"until":"event=node_kill details.node=n1","rewind_ms":50}'

The second is a session 50 ms before n1 was killed in the first one: what the first did up to there is
replayed from its tape (the commands at their moments, the connections with nobody outside), and
what it did after never happened here: this one is timeline 17, going another way.

A timeline's number is whoever creates its tape first's (as a run's id is whoever creates its
directory's): the explorer's as it plans one, a session's as it starts. A session opened while
its run explores takes the next number, and the explorer passes over it (its later timelines
are the numbers after, with those numbers' seeds); a resumed run passes over the same. A
session with `fresh_seed` is a timeline too: the seed it takes at its moment is a step on its
tape (`det:fresh <seed>`), so its replay draws the same future.

What a session did is not what the run found: the run's findings, properties and statistics are
over the timelines it explored, never a session's (a crash made by hand at a REPL is in that
timeline's events, on the map and in every query, not among the run's findings). And a live
session runs at a person's pace: idle, its virtual time passes no faster than the wall clock.

serve holds 8 sessions at once (a 9th start answers 503) and answers one request per session at
a time (a step or an end while another, or the start, runs answers 409). A session no request
touched for 30 minutes is ended (`serve --session-idle-minutes <n>`): a client that went away
leaves no machine behind.

## Coming back to a moment: `det:checkpoint`

A session replays its timeline from boot each time one is opened on it, unless a snapshot of the
timeline before the moment is on disk (the run's replay snapshots, which a replay far into a
timeline saves): a REPL's 15 s library load, a JVM's warm-up, replayed again after every crash.
A checkpoint saves the session's machine where it is, among those snapshots:

    curl -X POST localhost:7878/sessions/4/step -d '{"exec":"det:checkpoint loaded"}'
    # [determinismo] checkpoint: {"name":"loaded","vtime_ns":21004000917,"saved":true}
    curl -X POST localhost:7878/runs/<run>/session \
      -d '{"branch":16,"until":"event=session_checkpoint details.name=loaded"}'

The step runs the guest 1 ns on, exactly, leaves a `session_checkpoint` event there (its name in
its details), saves the machine (a child writes its pages, the first whole, the next against the
one before) and runs on to that millisecond's end, where the session's next step begins. A
session opened at the event is held at that millisecond's end and starts from the saved machine,
not from boot: the same state (a replay from the snapshot is the timeline's replay from there),
what the first session did after the checkpoint not done. Its replay from boot, with the
snapshots gone, is the same history. The snapshot is `b<timeline>-<ms>` in the run's
`replays/layout-<n>`, kept within the replay snapshots' budget (50 GB over every run, the least
recently used removed first): a checkpoint removed is a session replayed from boot, never a
wrong one. A replay of the timeline (the session's steps from its tape) leaves the same event at
the same moment and saves nothing; neither does a run from a machine's checkpoint (a CI shard's),
whose replays never start from a snapshot.

A run replays with the explorer that recorded it (its artifact), so these steps answer in runs
recorded since they exist (2026-11-13; det:checkpoint since 2026-11-15); an older run's guest
takes them for shell commands.

From Clojure, babashka or jank (one `.cljc` source, no dependencies): clients/clojure,
`determinismo.debug`'s `open`, `regs`, `translate`, `mem`, `poke`, `break`, `continue`,
`step-branches`, `sh`, `checkpoint`, `resume` (a session at a session's last checkpoint of a
name) and `close`, each answered as data. `determinismo.lab` builds a moment lab on them: the
world at a session's moment derived from the timeline's events and `det-nodes list` (nodes up,
paused, down or halted, each link's directions, the faults on with the time they have left),
faults injected there as `det-faults inject` steps, the timeline on by `det:wait` or `det:until`,
and a fault tried against the same moment without it (two sessions resumed from a checkpoint);
clients/jank-viz draws it and acts from its buttons. `det:continue` needs a breakpoint or a
watchpoint: without one, the step answers `error: NoBreakpoint` and the session ends.

Planned: an interactive debugger (a GDB stub at a moment, pokes and watches from serve's panel).

## What a timeline drew: `timeline_draws`

A timeline is its seed and the answers the explorer gave the guest's pulls. A pull the guest
names before it (`sdk.random_below_named`, `sdk.decide`'s options, `sdk.random_config`, a
node's `knob.<name>` at its start, `swarm.<name>`) is a decision someone can reason about, and
the explorer notes each as it answers it (src/draws.zig): its label, its range or options, the
value drawn, whether a strategy or the bandit chose it, and the moment of the event before it.
A live timeline's own part is written beside its events (`draws-<n>.jsonl`, the setup's
`draws-setup.jsonl`) and the run's database has them in `draws`; `timeline_draws` is each
timeline's, its setup's and ancestors' parts included, as `timeline_events` is its events:

    curl -X POST localhost:7878/runs/<run>/sql -d '{"sql":
      "SELECT part, name, drew, after_ns FROM timeline_draws WHERE timeline = 4 ORDER BY pull"}'

`drew` says what was drawn: an option's name (`sdk.decide`'s "fault" is drawn among a varying
subset of fault kinds: an index names another kind in another subset), else the number.

Which choices the failing timelines share, against the others (swarm testing's question), is
a join with `timeline_properties`; determinismo.api's `draw-split` asks it, and clients/jank-viz
draws its answer: a row a label, each value the failing timelines' share in red over the
others' in blue. Only named pulls are noted (an unnamed `random_u64` is no choice to reason
about), a label's first 32 values kept and the rest counted by value (a label of 16 values or
fewer). A replay asks the explorer nothing and notes nothing: a session's own part is not
noted. Runs recorded before 2026-11-15 have none.

A decision can be fixed: a run with `decide` ("name=value,...", a range's number or an option's
name; explore's `--decide`) answers that label so in every timeline, taped as a strategy's
answer, so its replays repeat it: the run as it goes with that choice, against the run without.

    curl -X POST localhost:7878/runs -d '{"program": "...", "scenario": "bank",
      "decide": "composer.drivers_cpu=flat"}'

determinismo.api's `start-run` takes it as a map (`{:decide {"composer.drivers_cpu" "flat"}}`).
A session replays its timeline and asks the explorer nothing: a fixed decision is a run's.


## What a call would do: `plan`

A session or a run asked with `"plan": true` does nothing and says what it would do, from the
same code that does it:

    curl -X POST localhost:7878/runs/<run>/session -d '{"branch": 9,
      "until": "assert.message=\"test commands exit successfully\" assert.condition=false",
      "plan": true}'
    {"plan":true,"timeline":32,"extends":9,"at_vtime_ms":221506,"from":"boot",
     "from_vtime_ms":0,"replay_ms":221506,"wall_ms":111416,"live":false}

A session's plan is exact but for its number (another session opened meanwhile may take it):
the timeline it would be, its moment, whether its replay starts from one of the run's replay
snapshots or from boot, how much of the timeline that replays and about how long at the
timeline's own pace. A run's plan is an estimate: its timelines are known only as they run (the
tree follows what turns out new), so it says how many the last run of the same program and
scenario explored in its budget, as many for this budget at that rate, and the named choices
that run drew (`sets`): what this one will draw from. determinismo.debug's `open` and
determinismo.api's `start-run` take `:plan true` and return the plan; `execute` makes it real.
clients/jank-viz draws a planned session as a dashed row where it would leave its timeline, the
part it would replay bracketed above that one.


## Where one of determinismo's guest tools panicked

The guest's own tools (det-nodes, det-composer, det-runner, ...) are packed into its image
without their debug sections (tools/elf_strip.zig: DWARF named the tree they were built in, and
made every image's bytes depend on it). A panic of one of them names its functions and their
addresses, not their lines:

    thread 412 panic: ...
    ???:?:?: 0x107977d in nodes.restart (/opt/determinismo/bin/det-nodes)

The tools whole are kept beside the image, named by its content: a run's machine.json names its
initramfs (`artifacts/<hash>-base.cpio`), and `artifacts/<hash>-tools.cpio` beside it holds them.
The lines (`-i`: the functions inlined into it too), from any shell with binutils:

    mkdir t && cd t && cpio -id det-nodes < ~/.determinismo/artifacts/<hash>-tools.cpio
    addr2line -f -i -e det-nodes 0x107977d

A tool that crashes on a signal (its trace as above, then "no process crashes: det-sinks"
failing) also gets a `crash_stack` event, whose frames name no function either: each is
`{"address":"0x1031e21","at":"det-sinks+0x30e21"}`, the offset in the stripped copy. Its
`address` goes to addr2line the same way.
