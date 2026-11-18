---
name: determinismo-debug
description: Investigate a failing determinismo property - query the multiverse, replay the failing timeline, look at moments, find where the failure was decided, and verify a fix. Use when a determinismo exploration reports FAIL, or when asked why a property failed.
---

# Debugging a determinismo failure

Every timeline replays exactly, so a failure is evidence, not flakiness. Follow
`docs/AGENTS.md` ("A debugging loop that works"); in short:

1. **Read the summary**: each failing property names an example branch (`--branch N`) and,
   when the SDK sent it, the assertion's place in the code (file:line function).
   A run still going: `determinismo runs stream <id>` says each property as it first fails
   (a sample: its timeline and moment, for `runs logs`), and `runs search <id> '<condition>'
   --follow` prints new matches as timelines finish. In serve's UI a failing property opens on
   what led up to its first counterexample, its ⧉ is a link to it (`/?property=<message>#<run>`),
   and the Findings section's ticks are its verdict in the system's last runs.
2. **Query** what failures have in common: `determinismo query <events-dir>
   'assert.condition=false' --preceded-by 'event=fault'` (and `--not-preceded-by`), or an event
   set pipeline (`with_last`, `with_next`, `through`) with `determinismo events`. Any SELECT on
   a serve run's events database: `determinismo runs sql <id> -`, the statement on stdin (a
   heredoc through ssh needs no quoting), the rows tab-separated (`events`: branch, seq,
   vtime_ns, kind, name, condition, node, text, event: the whole JSON). A host check that
   asserted anything false keeps its input beside the timeline's events:
   `<run>/events/branch-<n>.check-<name>.jsonl` (Elle's whole history, its verdict's anomalies
   cut at an event's size).
   What the system logged as errors that no property reads: `determinismo runs logged <id>`
   (serve's "Logged errors": templates by node, panics first, NEW against the system's previous
   run). TiDB's recovered auto-analyze panic (#64466) showed only there; a system's own log line
   becomes a property with its nodes' `log_failures`.
3. **Replay** the example: same seed, `--branch N` (a timeline past the first 16 of a tree
   exploration started inside another: replay it with `--tape <tape dir>/branch-N.jsonl`). A
   run serve made: `determinismo explore --run <run directory> --branch N` takes the run's own
   options (machine, system, seed, scenario, profile, timeline length) and that timeline's tape.
   Add `--until '<condition>'` to stop at the first violation, `--rewind-ms` to stop before it.
4. **Look at the moment**: `--at-vtime-ms T --exec 'det-nodes exec <node> <command>'` (the
   output is the same on every replay). A run with `--retroactive` texts left those lines out:
   the Logs view's Recover filtered logs (`POST /runs/<id>/recover {branch, vtime_ns}`) brings
   back the 10 s before the moment. What you would run at every failure, ask for once: a run's
   `automations` (`[{"property": "...", "exec": "..."}]`, or the profile's) run at each failing
   property's first counterexample when it ends (`GET /runs/<id>/automations`); `determinismo stacks`, `determinismo profile`,
   `determinismo extract` for files and core dumps. The guest runs on while a command runs, so
   a long read sees a later moment: `--exec 'det:frozen <command>'` holds the nodes and the
   runner's side still meanwhile (read nodes from outside then: `/proc`, `/run/det/nodes/<node>`).
   The program's own state, from a REPL (`docs/AGENTS.md`, "A REPL"; `(help "symbol")`): a
   session at the moment (`(dbg/open run {:branch N :until "<condition>"})`), `dbg/symbol` for
   a node's variable or function by its name (a field by its path, its type from DWARF),
   `dbg/watch-values` for each write to it from there, `dbg/calls` for each call with its
   arguments, each an exact moment to open another session at; `dbg/across` makes the same look
   at a condition's first match in every timeline that has it (failing timelines against
   passing ones). For a native program with its symbols (C, C++, Go, Rust, Zig), not a JVM's
   Java fields.
5. **Shrink its faults**: `determinismo script <events>` then `determinismo shrink <explore
   options> --script <script.json> --property '<message>'`: the fewest faults that still make it
   fail (or that it needs none), judged over 16 seeds, and the shrunk script for `--script`.
   Which details of its last faults it needed: `determinismo explain <explore options> --tape
   <its tape> --property '<message>'` (serve's `POST /runs/<id>/explain`, the page's Explain):
   each detail drawn again against a control; needed, partly, free or unclear.
6. **Find where it was decided**: `determinismo causality` forks futures at moments of the
   branch; the failure probability jumps where the bug was decided. Query the events just
   before that moment, the code first run inside the jump (`event=coverage`), and every
   thread's stack at its end (`--at-vtime-ms T --exec '/opt/determinismo/bin/det-profile
   <node> --stacks'`, or `determinismo stacks`). Those name native frames (ELF symbols): a JVM's
   Java frames are JIT code they cannot name. For those, `infra/host/moment.sh <run> <timeline>
   <ms> 'det:threads <node>'` prints every thread's state and wait channel and a JVM's own dump
   (SIGQUIT), which named a server's stuck body read in one step (run 1005).
   A command at a moment runs while the guest goes on: keep it quick (a slow one, a client
   waiting on a down node, moves the moment it reports on by seconds).
   A crash too quick for a dump (a JVM dying in native code within milliseconds): read the
   `coverage` events of the node's last second (each instrumented line's first run, in order):
   they name the Java path the crash came out of (run 1145 timeline 11: a shutdown hook's lines
   between a SIGTERM and the crash in native code),
   and the faults just before it (`event=fault`, a `stop` 60 ms earlier). Then freeze a moment
   between them (`det:frozen ... det-profile <node> --stacks`, every replay resuming from the
   moment's snapshot: minutes, not the timeline's length) and read the core
   (`/runs/<id>/extract` of `/run/det/cores/...`, its mappings by gdb's `info proc mappings`,
   its stack's return addresses against them).
   A JVM out of heap: what holds the mass, at a moment before the error. `infra/host/heap.sh`
   with `infra/host/HeapRefs.java` (`moment.sh --put` both into the node; see HeapRefs.java)
   dumps the node's JVM (`--all` keeps the unreachable objects too: a full GC right at the
   moment otherwise leaves almost nothing) and prints the arrays by size, then their holders
   level by level up to the thread frame that roots them, with its stack (run 1145,
   timeline 17: 15,575 zeroed 64 KB arrays in one transient vector a thread was building).
   The steps that put the files in run the guest on: a full GC landing between the moment and
   the dump leaves the mass gone. Read the threads at the same moment too (`det:threads`): the
   one building the mass is in its frames (there: the HA sync loop inside `copy-out`).
7. **Turn the logs up inside the jump**: the system's own logs are often too quiet to show the
   mechanism. At a moment inside the jump, raise its logger (an admin API, a config the node
   rereads; one its restarts keep too) and `--continue`, the timeline's own randomness after
   it: a future that fails as the original shows the mechanism step by step. Before the jump
   the perturbation makes futures pass; past it the cause is already in the past (run 177:
   a transaction logger at trace from 116 s showed a coordinator crash between beginning a
   transaction and recording its partitions).
8. **Try a change at a moment**: `--exec ... --continue`, or `fork` with `--exec` to explore
   many futures of the changed system (a patch through a REPL, a setting, `inject` a binary).
9. **Verify a fix by exploring again** with the same seed and more branches. An old branch's
   replay is not proof: different inputs make a different timeline.

To show the failure to someone without the host: `determinismo runs export <id> <timeline>
failure --html > window.html` (or a failing example's Export in serve's UI): the 30 s before
and 5 s after as one page that plays it back, each node's log side by side with the faults.
Its JSON (without --html) is an analysis's input too, read offline.

Report: the property, the timeline (seed, branch, moment), the sequence of events that led to
it (faults, decisions, node output), the root cause in the code, and the fix with its
exploration result.
