# Using determinismo from an agent

determinismo is built to be driven by programs as much as by people: every timeline replays
exactly, results are JSON, and a Model Context Protocol server exposes the main operations.

## Connect

```
determinismo mcp --kernel <vmlinuz> --initrd <base.cpio> --memory-mib 2048 --cache <dir>
```

Tools: `describe`, `explore`, `replay`, `fork`, `query`, `events`, `sql`, `causality`, `shrink`, `mutate`,
`verify` (schemas in `src/mcp_tools.json`). Every exploration is a run of the host's, in its run store
(`~/.determinismo`, src/runs.zig), with its record, events and tapes: people follow it in
`determinismo serve`'s web UI however it was started (explore prints its run's number and
directory). Without MCP, use `determinismo runs` (serve's runs from a shell, as Antithesis's
Snouty), `determinismo query` and `determinismo events` on a run's directory, or the HTTP API
(`determinismo serve`):

```
determinismo runs list
determinismo runs show 24
determinismo runs properties 24 --details        # failing ones with their first examples
determinismo runs logs 24 63 120.5               # timeline 63 up to 120.5 s (ancestors too)
determinismo runs export 24 63 120.5 > window.json  # its window (30 s before, 5 after) as one
                                                  # JSON document: events, the run, properties,
                                                  # causality, automations (no host needed)
determinismo runs search 24 'event=fault details.node="kafka-1"' --limit 20
determinismo runs exec 24 63 58 --node kafka-1 'cat /proc/net/route'
determinismo runs exec 32 9 --until 'assert.message="..." assert.condition=false' --rewind-ms 5000 \
  --node quint 'ps -eo etime,args'               # 5 s before timeline 9's violation
determinismo runs start --program zig-out/bin/bank-test --scenario bank --time-budget 1h
determinismo runs stop 24
```

`--url http://host:port` or `DETERMINISMO_URL` for a serve elsewhere (127.0.0.1:7878 by default).
Why a run is slow, or slowed down: `curl <serve>/runs/24/activity`, by minute of wall time its
timelines ended, the virtual time they explored, and its workers' seconds by activity (timelines
running or waiting for memory or a CPU, nodes from holders or replayed, verification replays,
setup), with the memory available; the run page draws them. Read it before the averages.
A replay through `runs exec` takes the run's own inputs (its kernel, initramfs, command line,
memory, faults, tape): prefer it to an `explore` command line put together by hand, which the
tape refuses when anything differs.

## A REPL

The same as a person at an editor: clients/jank-viz started (`./viz.sh`, its nREPL port in
`.nrepl-port`), or a Clojure REPL or babashka with clients/clojure on the path, and an nREPL
client (`clj-nrepl-eval`). `(require '[determinismo.help :refer [help]])` then `(help)` lists
every call there is, with its arguments and documentation: runs and their events
(determinismo.api), a session held at a moment of a timeline, with the machine's registers,
memory and breakpoints and commands inside its nodes (determinismo.debug), a node's file at a
moment, a file put into a node at a moment with the timeline going on (a fix tried on the
system itself), new timelines from a moment, causality, shrinking and explaining, and Quint
(determinismo.quint). A session stays at its moment between calls, so questions about one moment
cost one replay. The window draws each evaluation, for whoever watches. Who changed a value:
`symbol-at`, `calls` (arguments by their DWARF names), `moment-when` (the first moment a look
holds, bisected), `watch` and `continue` (a stop at the write), `frames` (its stack, unwound by
`.eh_frame`): the determinismo-debug skill's recipe. The same REPL serves exploration strategies
(determinismo.strategy, docs/PLUGINS.md): functions redefined while a run asks them.

## Skills

Claude Code skills in `.claude/skills/` (as Antithesis's antithesis-skills):
`determinismo-properties` finds what a system must guarantee, `determinismo-workload` writes its
test program, `determinismo-review-inputs` reviews its input distribution (what its drivers can
never reach), `determinismo-debug` investigates a failure. Copy them to `~/.claude/skills/` to
use them in other repositories.

## A debugging loop that works

1. **Describe** the program: its profiles (nodes, faults allowed) and scenarios (test commands).
2. **Explore** a scenario with enough branches (32 to 128) and a fixed seed. Read the summary:
   which properties failed, in how many branches, and an example branch for each.
3. **Read what the system logged as errors**, which no property reads: `determinismo runs logged
   <id>` (serve's "Logged errors": each error-like node line as a template, by node, panics
   first, NEW against the system's previous run). TiDB's recovered auto-analyze panic (#64466)
   was in a third of a hunt's timelines and failed nothing; a node's `log_failures` (schema.zig)
   turns such a line into a property.
4. **Query** the multiverse: every branch's events (assertions, faults, commands, and what each
   node printed) are in the exploration's `events_dir`. Ask what the failures have in common:
   `query {condition: "assert.condition=false", preceded_by: "event=fault", within: 1,
   output: "branches"}` lists the timelines where a failure came within a second of a fault;
   `not_preceded_by` the ones where it did not. Each match carries its moment. For more, `events`
   takes a pipeline (Antithesis's event sets): `[{"filter": "assert.condition=false"},
   {"with_last": {"fault": "event=fault"}}]` gives each failure with the last fault before it
   (`last_fault`), to filter or group on; `with_next` with a `timeout` finds what followed (or
   did not, in time); `through` runs any program over the set (JSON lines in and out) for maps
   and folds.
5. **Replay** a failing branch: same seed, `branch` = the example. It is the same timeline,
   every time, so its events (with virtual times) are evidence, not noise. Explorations branch
   as a tree by default: a timeline past the first 16 started inside another (its `path` in the
   results), so replay it from its tape: MCP `replay` with `tape` = `<tape_dir>/branch-<n>.jsonl`
   (explore returns `tape_dir`), or `explore --tape` on the command line.
6. **Look at a moment**: replay with `at_vtime_ms` just before the first failure and an `exec`
   command, e.g. `det-nodes exec postgres psql -U postgres -c 'select ...'` or
   `det-nodes exec redis redis-cli get key`. The output is identical on every replay. To watch
   what happens next, grow a branch from the moment step by step (HTTP replay `steps`, the
   notebook's `branch`/`bash`/`bash-bg`/`wait`/`wait-until`/`run-branch`, or `--exec-script`
   lines): start a monitor in the background (`det:background redis-cli monitor`), let time
   pass (`det:wait 500`) or wait for an event (`det:until 2000 <condition>`), run a command;
   each step's end is a moment, and each command a process with its output and exit code.
   Add `--fresh-seed <n>` (HTTP and MCP `fresh_seed`; the notebook's branches by default) for
   the branch's own future: new randomness from the moment, as Antithesis's branches, the same
   for the same seed; without it the branch keeps the timeline's.
7. **Narrow down**: which faults does the failure need? `determinismo script` turns the failing
   branch into a script (its commands and faults by virtual time), and `determinismo shrink
   <explore options> --script <it> --property '<message>'` removes faults (delta debugging) for
   as long as the script still fails, each candidate over the same 16 seeds (a fault removed
   shifts the guest's randomness: one timeline is chance): it reports the faults kept, how often
   they fail, how often the whole script and no faults do, and writes the shrunk script for
   `explore --script`. "It needs no fault" is an answer too: the bug is in the workload's own
   interleavings. Which details of the last faults it needed, in the same timeline:
   `determinismo explain <explore options> --tape <its tape> --property '<message>'` (serve:
   `POST /runs/<id>/explain {branch, property}`, the run page's Explain) draws each detail of each
   of the last 3 faults again (its kind, target, length, the wait to the next), 6 times, from a
   snapshot just before them, against a control (another draw after the fault, varied as often):
   needed, partly, free or unclear (90% intervals). Bank's race needs no fault; a reply cut by an
   isolation needs the next fault ~6 ms on. Then `causality` measures, at moments of the failing branch, how likely the
   failure was (futures forked there that fail): the bug was decided where the probability
   jumps. A future that has not failed by the failure's moment plus its distance from the setup
   snapshot ends there, counted as not failing (`--horizon-ms`, serve's `horizon_ms`; 0 runs every
   future to its end): a bug decided early in a long timeline costs futures that long, not the
   timeline's length. With `--verdict '<condition>'` (`verdict`) the bug is an event condition
   instead of the property, and futures stop at it. Query the branch's events just before, and inside the jump the code first run there
   (`event=coverage`: each line once, the first time a process runs it; the UI lists them per
   jump) and every thread's stack at its end (`replay` with `exec` "/opt/determinismo/bin/det-profile
   <node> --stacks"; the UI's "stacks" on a jump). `replay` with `until` stops at the first event
   matching a condition (its first violation, say) to look there, and with `rewind_ms` that long
   before it. `fork` from any moment
   explores its futures. When the system's logs are too quiet to show the mechanism,
   `--explain-exec '<command that turns them up>'` (serve: `explain_exec`) ends the analysis
   with futures from inside the narrowest jump to failure, the command run at their moment and
   the timeline's own randomness after it, each one's events kept: a failing one shows the
   mechanism step by step (a transaction left open, run 177). A test program's profile may
   declare that command (`profile.explain`): serve then runs it in every analysis of the run.
   **Try a change**: `replay` with `exec` and `continue` makes a change at a moment (data, a
   setting, a function redefined through a REPL) and lets the branch play out; `fork` with
   `exec` explores many futures of the changed system. `determinismo extract` takes a node's
   file out at a moment (a data file, a core dump; from a node that exited, through its
   writable layer: `--file runner:/run/det/nodes/<node>/layer/upper/<path>`, for the last lines
   of a log written just before an exit); `determinismo inject` puts a local file in
   (a patched binary, a config), then `--then` and `--continue`. `determinismo profile --node
   <node> --ms <duration>` samples where the node spends its CPU from the moment on (`--all`
   for waiting threads too, `--svg` for a flame graph); `determinismo stacks --node <node>`
   prints every thread's stack at the moment; `det-nodes list` at a moment lists the
   nodes, their state and pid. A crashed process leaves a `core_dump` event whose `path`
   `determinismo extract --file runner:<path>` takes out (for gdb with the binary), and a
   `crash_stack` event saying where it crashed: the thread's `rip`, `rsp`, `rbp`, the
   `fault_address` of a segfault, its `frames` (the instruction it stopped at, then its callers
   by frame pointers) and `scanned` (the words of its stack's top that point into code: the
   callers of code built without frame pointers, a libc's abort under an assertion, among
   whatever older calls left there), each `at` its source line when the node has the module's
   lines (below), else its module and offset. The coverage events before it are the lines that
   ran into it.
8. **Fix and verify**: change the code, explore again with the same seed and more branches; the
   property should pass in all of them. A replay of an old failing branch is not proof (the
   inputs changed, so it is a different timeline); exploration is.

## Sessions: commands one at a time, and a REPL inside the guest

A session is a replay held at a moment that takes steps as they come:
- `POST /runs/<id>/session {branch, at_vtime_ms}` replays to the moment, holds it there and
  returns its id;
- each `POST /sessions/<n>/step {exec}` runs one command or `det:` step there and returns its
  output once it is done;
- `POST /sessions/<n>/end` releases the timeline.

Between steps the machine is paused, so a session is a function of its steps. With
`"live": true` the guest runs on between steps, each step at a moment of its own. Either is
recorded as a timeline of the run from its moment on, under the run's next number (the open's
`timeline`): its steps and what came from outside on its tape, its events in the run's. So a
session is queried and replayed as any timeline (`/query` and `/replay` with its `branch`), and
another session opens at a moment inside it. Underneath, explore's `--exec-interactive`,
`--exec-live` and `--extend`.

docs/REPL.md is the guide for people. A test program in Clojure (`sdk/clojure`'s
determinismo.workload) serves a REPL: `run nrepl
<port>` in its node starts nREPL with CIDER's middleware, the program loaded.
`infra/host/nrepl-proxy.py --serve <url> --run <id> --node <node> [--branch <n>] [--at-ms <ms> |
--until <condition>] [--live]` (by default timeline 0 where its scenario's commands begin) opens
a session and starts that server with the session's relay
(`det-nrepl-relay serve`: one connection to it for the session). It is then an nREPL server here
(port 7888, `.nrepl-port`) for CIDER, Calva or any client.

A program makes its REPL warm by making it its node's command (`run nrepl <port> 0.0.0.0`, ready
on that port, as tests/repl's client): it is up before the setup's snapshot, so every session's
relay connects at once, the JVM and CIDER's middleware already loaded. Before it, `run prepare`
(tests/repl/client-run) compiles the program's namespaces into the node: every command of every
timeline then starts in 1.1 s on the guest's vCPU instead of 3.2 s. Otherwise the proxy starts
it for the session, and its first evaluations pay for loading.

Each message is one step, `det:ask`: the guest's agent writes it to the relay's FIFO (no process
started), and the machine runs until the relay says the message is done. Its replies come back
as events. A message takes about 10 ms on the host itself, plus the network's round trip from
elsewhere (62 ms from a Mac over an ssh tunnel, 53 ms of it the tunnel). The first evaluation
loads the JVM's eval and middleware, seconds once.

At the REPL, evaluate against the running system: the nodes by name, libdeterminismo's
functions (`fault`, `stop-faults`, `event`, assertions), the program's drivers, redefined and
called again. That is scenario development without rebuilding images or booting again, each
attempt replayable from the session's script.

`(w/fork! n)` clones the machine where it stands, as Unix's fork. In a session the platform
saves it then (a copy-on-write snapshot, `--fork-snapshots`), and serve starts its n futures as
a run of its own (`from_snapshot`: `--from-snapshot --fork-futures`). That run is listed,
followed and replay-verified like any other: a future replays from the snapshot by its index.
The call returns 0 in the session and k in future k, which plays out from there to its
timeline's end. `POST /sessions/<n>/forks` gives each fork's run, state and verdicts. Outside a
session, `fork!` returns 0 and nothing is cloned.

From the REPL, serve is reachable inside the machine (`w/serve`, `w/start-run!`, `w/run-state`:
libdeterminismo's `det_serve`), so a run can be started there and followed as it goes.

From the REPL, the program controls the other nodes through the runner (`w/runner`, `w/node!`,
`w/node-exec`: libdeterminismo's `det_runner`). Platform mechanics, such as a fault kind or a
recovery procedure, can be written there and replay like the platform's own (docs/SDKS.md).

From any Clojure REPL that reaches serve (`cider-jack-in` in a project with `sdk/clojure` on its
classpath), `determinismo.session` drives sessions and runs:

- sessions: `open`, `step`, `steps` (several steps in one request: a command defined in Clojure
  costs one round trip, as `det:ask` does), `wait`, `until`, `at`, `background`, `node-exec`,
  `start-repl`, `eval`, `forks`, `end`;
- runs: `start-run` (as `POST /runs`), `run`, `runs`, `output`, `watch` (its lines as they come,
  until it ends), `stop!`.

## Facts worth knowing

- A workload never hides a system's bug for good: the path its users take stays the default and
  a property judges it (it fails whenever the bug happens: a known exit list is for documented
  behavior only). Where a bug would fail every timeline and keep the rest from being tested, it
  is worked around at random: a draw per timeline, connection or operation (`sdk.random_below_named`),
  a node's drawn flusher (`writeback_s`: on and off in stretches, strict when off), or in a
  node's start script `$DETERMINISMO_DRAW`, a number drawn for each start (the decision
  `node.start_draw`; a command run in a node draws none): `[ $((DETERMINISMO_DRAW % 2)) = 0 ] &&
  <the workaround>`.
  Swarm testing already leaves each fault kind out of some timelines. A draw at a
  node's first start, or in the setup, is made before the timelines part (the setup snapshot),
  so it is the same in all of a run's timelines: prefer an operator's recovery drawn at each
  start (Consul's start.sh), or set `s.snapshot_before_nodes = true` so that each timeline
  starts the nodes and runs the setup itself (Garage's scenarios).
- A system is a test program (`--program`), an Antithesis Compose project (`--compose`), or
  Kubernetes manifests (`--kubernetes <dir>`, the MCP and HTTP `kubernetes`): a single-node K3s
  cluster runs them, images fully qualified and taken from the host, deployed and ready before
  branching; test templates in any image run in their pod. Its faults include single pods
  (`pod_pause`, `pod_kill`, `pod_isolate`, `pod_degrade`, `pod_partition`), named in each fault
  event. examples/kubernetes is one.
- Exploration is a tree (Antithesis's "every event a potential branch point"): after each
  generation of 16 timelines, the ones that first reached something (an assertion outcome, a
  fault kind, a closer guidance distance, a new kind of output line) are returned to just after
  it, and new timelines branch from there. A `sometimes` or `reachable` made true comes first
  (the frontier's moment, a heavier archive cell): put one on each rare state worth building on
  (a failover, a retry path, a recovery), and the tree returns there. An archive cell whose
  returns found something new ranks higher (returns go where they pay). For progress that builds
  up (a growing backlog, a longer partition, more uncommitted entries), `sdk.optimize(message,
  bucket, value, .maximize)`: each bucket keeps its best state so far and the tree returns
  there, climbing (Antithesis's Metroid exploration). Each timeline also draws its own mix of
  fault kinds and their weights, and regimes of fault rate and duration that change every 10 to
  120 s with the mix (swarm testing; `fault_swarm` and `fault_regime` say
  which); its drivers kept (`command_left_out` says which, one `s.workload` driver at least)
  and its load in stretches (`composer_load`); and `sdk.swarm_choice` gives a workload's
  operations the same treatment. `--no-swarm` turns all of it off (the comparison arm). Each timeline's `why` says why it starts where it
  does. A generation of 16 is 4 fresh starts and 3 moments with 4 branches each:
  `--return-branches 2` makes it 6 moments with 2 (serve's `return_branches`), and `--horizon
  60s` stops each returned branch a minute past its moment unless it found something new
  (short branches, the promising ones extended). `--branching flat` starts every timeline at the setup snapshot; strategies plan flat
  unless asked for a tree (`--branching tree --strategy ... --tape-dir ...`). Through MCP,
  explore and fork take `strategy`: any command speaking docs/PLUGINS.md's protocol, one you
  wrote included; its decisions are in the tapes, so replays need no strategy.
- Disk faults: a node that allows `crash` gets an ext4 disk of its own (4 GiB, the inodes mkfs
  gives a disk of that size, held in the guest's memory as it is written); a crash is a power
  loss (what it synced survives, the rest is lost; the journal keeps the filesystem consistent),
  a `wipe` starts it fresh from its image, its starts from then on given `$DETERMINISMO_WIPES`
  (how many times its disk was lost; unset before any), for a start script whose system brings
  back a member that lost its disk with another command than a new one's (TigerBeetle's
  `recover`, never `format`). A node that fills its disk starts again as a machine
  would, its programs meeting the full disk (a reserve outside its view keeps room for the
  start). `disk` makes its disk fail for a while (I/O errors,
  write errors, lost writes, corrupted reads, slowness); an exit then is expected, and a node
  that exited or whose filesystem went read-only starts again at the fault's end.
  `--faults +restart,+crash,+disk` adds kinds to every node (`+clock_skew`: one node's realtime
  clock ahead or behind for a while, for systems that order by clocks; any system, a Compose
  project's too), and `-interleave` takes one from every node (a run without it, to compare);
  `interleave`, on by default, draws some of the scheduler's choices among a node's threads
  for a while (a woken thread runs before its waker goes on, a random runnable one runs next),
  `--no-faults client,monitor` takes them all from some (an Antithesis launch's
  `exclude_faults`).
- Efficiency (Antithesis's "virtual time per wall time"): every run reports how many virtual
  seconds a wall second simulates (one core), that times the system's nodes (Antithesis's rule
  of thumb: above 1), the share of virtual time the guest was idle and skipped (little: something
  busy-waits or polls, so idle time is not fast-forwarded), clock reads per virtual second (each
  an exit to the VMM), and each node's CPU time over the uptime (det-init's `node_cpu` events at
  a timeline's end; serve's run page, "CPU by node"). A slow system: lower its background work
  to test sizes (compaction, splits, heartbeats, failure detectors), find the busy node, then
  `determinismo profile` at a moment: with instrumented code it also prints the coverage
  callbacks' share of the samples, by the package that called them, which a node's coverage
  set (`.coverage = .{ .exclude = ... }`, docs/SDKS.md) can leave out.
- A timeline not finished by `--timeline-limit` (1 h of virtual time by default) ends as hung
  ("the guest finishes its scenario" fails). The composer starts no driver past half of it
  (a `drivers_stopped` event): those running finish, then the ending and the checks, so only a
  command that never finishes is a hang, not a slow system's many drivers.
- Before a first run of a Compose or Kubernetes system: `determinismo validate --compose <file>` resolves
  it without booting it and names what would keep a run from testing it (invalid commands, a
  template with no driver).
- Verbose systems: `explore --retroactive 'Applied block'` leaves such output lines out of the
  events (queries stay fast); replay a timeline (`--branch`, its tape) to see them. A workload
  declares its own in its profile (`profile.retroactive = &.{"Applied block"}`), every run's.
  The Logs view's "Recover filtered logs" shows them inline at a moment (`POST /runs/<id>/recover`).
- What you would run at every failure by hand (`det-nodes list`, a node's state, its log tail):
  an automation, in the profile (`profile.automations = &.{.{ .exec = "det-nodes list" }}`) or a
  run's request (`"automations": [{"property": "...", "exec": "...", "rewind_ms": 0}]`); serve
  runs it at each failing property's first counterexample once the run ends (`GET
  /runs/<id>/automations`, and the property's examples).
- The guest's clock starts the day after the system's newest image was made (2026-01-01 for
  older ones), so an image's data (an initial catalog, certificates) is never from the guest's
  future. Another date: `profile.epoch_seconds`, or explore's `--epoch <unix seconds |
  YYYY-MM-DD>`.
- Targeted runs: `explore --changed <diff file | git range>` aims the tree at a change's lines
  (line coverage: Python, the JVM, Go built with Antithesis's instrumentor, and C, C++ or Rust
  built for Antithesis with the binary in the image's /symbols) and reports which
  hunks ran in how many timelines and which never did (`{"changed":...}` in the record). With
  `--changed-repository <directory | URL>` the range is in the system's repository: a commit
  alone is that commit's change, `a..b` a range, `v1.6.0..v1.7.0` a release.
- Mutation testing: `determinismo mutate <explore options> --mutants mutants.jsonl` explores the
  system and each mutant (a patch to a node's build context, `{"name","node","patch"}` per
  line) with the same seed: each is caught (a property fails that passes without it), never ran
  (coverage shows its lines never ran), or unnoticed (a gap in the properties).
- A run's notebook is Clojure (babashka on the server: `query`, `events`, `run`, `replay`,
  `stacks`, `why` (a timeline's faults and why each, the strategies' reasons, the tree's for the
  timeline), ...); `POST /runs/<id>/nrepl` starts a babashka nREPL server with the same names.
- `POST /runs/<id>/stop` stops a run (its timelines so far stay; state `stopped`). A restarted
  `serve` adopts the runs still going (each run's `pid` file).
- Determinism checks: every run replays 20% of its timelines from their tapes as it goes (by a
  hash of their index, spread over the run; a quarter of that once 30 replays agreed and none
  differed, the whole share again at a difference) and each failing property's first failing timeline
  at its end, and judges "timelines replay to their recorded history" (`explore
  --verify-replays <percent>`, HTTP `verify_replays`; 100 replays them all, 0 none). `priority: true` (HTTP) gives a run's VMs the CPUs
  before other runs': a check beside a hunt, which goes on with the CPUs left. `reserved: true`
  (HTTP) puts a run on the host's reserved cores, out of the hunts' (serve.sh's reserved scope):
  a CI job or a sanity check beside a calibration, whose cores stay its own. A timeline that
  did not replay keeps its output beside the tapes (`replay-<n>.log`), its events
  (`replay-<n>-events`), and its line in the results says where it parted from the run's events:
  the last checkpoint both passed and the first line that differs on each side (the events carry
  a `{"checkpoint":{"vtime_ns","branches"}}` line at the first timer past each second of virtual
  time, neither counted nor hashed, so a divergence is placed within a second even where no
  event comes for long). Tapes and the run's record carry the build that made them (`host`, a
  hash of the explorer's executable): a replay by another build says so, as parting from a tape
  can then be the build's doing (run 56, recorded the day before: the same 26 of 64 parted at the
  same events every time) rather than nondeterminism. After the fact,
  `determinismo verify --run <run directory> [--sample <n>] [--timeline <n>]...` replays a
  sample of a run's timelines, or the ones named; a replay that parts from its tape prints the
  last events before the checkpoint it failed, to compare with the run's. To find where it
  parts, replay it with `--trace` (`DETERMINISMO_RDTSC_LOG_CAP` for long timelines), then
  `DETERMINISMO_ITRACE_AT=<RDTSC exit>` for the instructions of that interval.

- A branch is identified by (inputs, seed, branch index[, fork point]). Inputs are the kernel,
  initramfs, command line (scenario included), timer slack and disks; `explore` prints their hash.
- Tapes (`--tape-dir`) record strategy overrides; `--tape` replays a branch without its strategy
  and refuses to run on different inputs.
- Virtual time is not wall time: idle time is skipped, so timeouts and sleeps cost nothing.
- Membership changes (Jepsen's member nemesis): a node with `.spare = true` is prepared with the
  others but not started; a `member` driver starts it, joins it, removes it and joins it again
  through the system's own API, one step at a time (a lock file in the runner), while faults
  leave a node alone whenever it is not running; every refused call is a `member_refused`
  event. examples/etcd, rqlite, consul, mongodb (replSetReconfig), galera, cockroachdb,
  cassandra, scylla, yugabyte, zookeeper (profile `reconfig`) and kafka (partition moves;
  Redpanda's decommission; the `kafka-4.4-dynamic` quorum) have one; rabbitmq and nats change a
  queue's or a stream's group.
- Latency bounds (FoundationDB's LowLatency): a scenario's `s.quorum = &.{...}` names the nodes
  whose majority the system needs; faults then always leave a majority of them up, linked and
  reachable (others skipped: `fault_skipped` QuorumKept), and a driver asserts each operation
  answers within a bound throughout: examples/etcd's `latency` scenario.
- Causality through a side channel (FoundationDB's Sideband): `sdk.sideband.Channel` is a file in
  the runner where one driver posts what the system acknowledged and another takes it and must
  read it through the system: read-your-writes across clients without a history checker, where
  none runs (examples/scylla's and examples/cassandra's `sideband`, QUORUM writes and reads).
- Upgrades (FoundationDB's restarting tests): a node with `.upgrade = .{ .image | .build | ... }`
  has its next release on a disk of its own; `node.upgrade(.next)` stops it gracefully, swaps
  its root image under its writable layer (its data kept) and starts it with that image's
  command and environment, `.base` goes back (a downgrade), `node.upgraded()` says which it is
  on. A driver upgrades one node at a time by the system's documented procedure, the
  scenario's own properties judging the mixed cluster: examples/etcd's `upgrade` profile
  (v3.6 to v3.7 and back).
- Faults happen only during the driver phase; `finally` and `eventually` commands see a system
  without faults, which is where recovery is checked. The ending's command gets a window of
  virtual time (`s.ending_ms_max`, 20 min by default): past it, it is killed and "an ending
  command finishes within its window" fails, so a check retrying a system that never came back
  holds no timeline for hours; give a final check a deadline of its own well inside it. Before an `eventually` command the
  drivers still running carry on for a drawn minimum since they began (a tenth of 10 s up to
  it, the decision `composer.min_drive_ms`; the scenario's `min_drive_ms` or explore's
  `--min-drive` set its maximum, 0 none), then are killed. Within it, any node or command can ask for
  a quiet period: `"$DETERMINISMO_STOP_FAULTS" 5` (also `$ANTITHESIS_STOP_FAULTS`): the fault
  under way ends and none but clock skips start for 5 seconds (`0` ends a quiet period). And
  progress mid-run, not only once faults are over (Antithesis's property catalogs: a store
  serves, a queue moves, in fault-free windows): a singleton driver calling
  `sdk.progress_while_quiet(message, window_ms, interval_ms, operation, arguments)` pauses
  faults, retries the operation until it succeeds within the window (the property fails when a
  whole window passes without one), then resumes them at once. etcd, NATS, rqlite, Consul,
  ZooKeeper and Kafka have one (an operation outside Elle's keys where Elle checks). Every
  link that allows degradation carries a baseline (a small delay with jitter, rare drops) for
  the whole run, as Antithesis's baseline latency; faults end by returning links to it.
  Durable disks have a baseline too (`disk_baseline`: 0 to 2 ms per I/O, per timeline).
  Branches run at varying speeds by default (CPU modulation, as Antithesis's with faults: other
  interleavings of the same seed); `--no-cpu-modulation` (MCP and HTTP `cpu_modulation: false`)
  turns it off. A run keeps its setting and serve's replays follow it; a replay by hand of a run
  without it needs `--no-cpu-modulation` (its tape refuses otherwise).
- Setup mode: `explore ... --setup-only` (serve's `setup_only`) builds, boots and runs the setup to
  `setup_complete`, then stops: no timeline, its setup events and output kept. Iterate on a system's
  setup with it before a full run.
- Exit status of explore: 0 every property passed, 3 some failed, anything else an error.
- Built-in properties come with every system (Antithesis's defaults): nodes do not exit
  unexpectedly (0, SIGKILL and SIGTERM are expected), the guest finishes its scenario, no process
  crashes, the kernel kills no process for lack of memory and reports no warnings, BUGs or hung
  tasks, peak memory stays under 95%, logging stays under 200 MB per hour of virtual time, the
  fault injector started, and no panics or uncaught exceptions in output (Go, Rust, Java). A kernel property's failure carries the log line and the
  kernel's timestamp (`kernel_us`, virtual time) in its details. The kernel's console lines are
  events too, output from source `kernel` at their moments (ext4 aborting a journal at a power
  loss, the OOM killer, a hung task): query them as any node's output (`output.source=kernel`).
