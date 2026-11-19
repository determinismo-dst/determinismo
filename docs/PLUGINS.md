# Strategy plugins (protocol v1)

A strategy decides what the guest gets at each decision point. determinismo runs it as a separate
process and talks to it over its stdin/stdout: one JSON object per line, strictly alternating
request (from determinismo) and response (from the plugin). Anything a plugin writes to stderr is
passed through to the user. Plugins can be written in any language: the reference plugins are in
`plugins/` (Zig, with `protocol.zig`), and `plugins/python/` has a helper for Python
(`determinismo_strategy.py`, standard library only) with an example that learns
(`extremes.py`: a UCB1 bandit over how often to push decisions to their extremes). The command
is split at spaces; a program without a slash is looked up in PATH, and the plugin inherits
determinismo's environment (so a strategy that asks a model can read its API key):

```
determinismo explore ... --strategy "det-strategy-mutate --sync-dir /tmp/corpus"
determinismo explore ... --strategy "python3 plugins/python/extremes.py"
determinismo explore ... --strategy "python3 plugins/python/llm.py"     # Claude Haiku 5.5
determinismo explore ... --strategy tcp://127.0.0.1:9100                # plugins/clojure/strategies.clj
determinismo explore ... --strategy tcp://127.0.0.1:9000                # a plugin elsewhere
determinismo explore ... --strategy image:localhost/determinismo-strategy-extremes:1  # in a container
determinismo explore ... --strategy "wasm:zig-out/bin/decide_named.wasm node.start_draw 7"  # inside the explorer
```

What a strategy decides, and what it sees (each detailed below):

| It decides | How |
|---|---|
| any draw inside a timeline (faults, timings, the workload's inputs), or only the named ones | `random` replies (`"wants":["labeled"]`), without stopping the timeline: it may answer from a plan made beside it |
| the named ones by weights the explorer draws from itself, no round trip per decision (a strategy served from afar) | `"wants":["plans"]`: a `plan` with each reply to a batch of events |
| where the tree branches or backtracks to: any moment of any timeline, an earlier generation's or the explorer's archive cells | `returns` replies |
| the next generation's shape: how many timelines branch from each moment, what fills the rest (the explorer's own picks or fresh starts) | `returns`: `branches` per return, `fill` |
| how long each branch runs past its moment | `returns`: `horizon_ns` |
| when a timeline ends: at any event of it (one headed only for failures already found frees its worker) | `event` reply `{"end": true}` |
| when the exploration stops | `branch_end` reply `{"stop": true}` |

| It sees | How |
|---|---|
| each timeline's structured events as they happen (faults, assertions, guidance), and its coverage (code reached) live | `event` requests (`"wants":["assertions","coverage"]` to be told only those) |
| each timeline's outcome (its failing properties) | `branch_end` |
| each generation's timelines and the behaviors each reached first, with their moments; the explorer's archive | `returns` (`"wants":["behaviors"]`), its `archive` |
| the whole run: its events, logs and properties by SQL, earlier runs of the system | the hello's `run_url` (serve's API) |

Whether its choices pay shows on the run's page (serve's Where failures came from): how often
the timelines it returned to failed a property anew, per CPU-hour, beside the fresh ones nobody
chose; and its decisions by the reason it gave (numbers taken out), each with the branches it
sent, how many failed a property anew and how many only as their parent had: a reason worth
repeating, or one that returns to timelines already broken.

A plugin can be uploaded to `determinismo serve`: `PUT /strategies/<name>` with the executable
(or a script with a `#!` line) as the body, or the web UI's New run dialog; runs then name it
`@<name> [arguments]`, and `GET /strategies` lists them. It runs on the server like any
`--strategy` command, so serve should listen where only trusted users reach it. Nothing about
determinismo is rebuilt for a new strategy.

A plugin can come as a container image, its dependencies in it: `image:<reference>
[arguments]` runs `podman run --rm -i --network=host <reference> [arguments]`, the image's
entrypoint the plugin (a container per exploration worker, gone once its input closes; on the
host's network, so its `run_url` and the services a command would reach are there).
`plugins/python/Dockerfile` packages extremes.py so (`podman build --tag
localhost/determinismo-strategy-extremes:1 --file plugins/python/Dockerfile .`); serve's runs
name images the same way.

A plugin can be a WebAssembly module the explorer runs inside itself: `wasm:<module.wasm>
[arguments]` (src/wasm_plugin.zig: WAMR's fast interpreter, compiled into determinismo). Each
message is a direct call, no process, pipe or ring: a module answers in about a microsecond
where a process takes tens. Its arguments come in the hello (`"arguments":[...]`), a module
having no argv. The ABI `determinismo_1` (the import module's name; a module built for another
is refused at load):

| | |
|---|---|
| `export fn det_call(request_size: u32) i32` | One message: 0 once its reply is written. |
| `import request_read(buffer, length) i32` | Copies the request's next bytes into the module's memory; 0 at its end. |
| `import reply_write(bytes, length) i32` | Appends to the reply (16 KiB at most); nonzero past its room. |
| `import log(level, bytes, length)` | A line on determinismo's standard error (0 error, 1 warn, 2 info, 3 debug). |

The host owns the request and the reply: a module exports no allocator, and reads a large
request (a history) in parts.
A call has an instruction budget (2 billion, WAMR's metering): a module that traps, loops past
it, returns nonzero or outgrows the reply answers `{}` (the defaults), said on standard error,
and the exploration goes on. The module's memory is the explorer's: it forks with it, each
timeline's process carrying the plugin's state as of its start, as a holder carries the
machine's. It imports nothing else (no clock, no files, no randomness of its own): its answers
are a function of the messages it was sent, and its overrides are on the tapes as any plugin's.
Zig builds one with `-target wasm32-freestanding -fno-entry -rdynamic`
(`plugins/wasm/decide_named.zig`, built and installed with the self-tests); Rust, C and TinyGo
target wasm32 too.

A plugin can run anywhere: `tcp://<address>:<port>` connects to one already listening (one
connection per exploration worker). `plugins/python/serve_tcp.py <port> <command>` serves any
plugin command that way, and an SSH tunnel brings it to the host from a laptop:
`ssh -N -R 9000:127.0.0.1:9000 det@<host>`. `plugins/python/llm.py` asks a language model
(Claude Haiku 5.5, through the `claude` command line) every few branches which labeled decisions
to favor, from what recent branches did; run it where `claude` is logged in.
`plugins/clojure/strategies.clj` is a strategy host on the JVM (`clojure -M -m strategies` from
its directory) with an nREPL server: strategies are functions redefined live, everything they saw
kept in the host for the REPL, switched by `(use-strategy! :name)` or its control port. The
explorer's archive cells offered with a generation are `*archive*` while a strategy answers
(`archive-returns` makes returns of the first few): `:rarity` is the explorer's rule whole, half
its returns from the frontier and the rest from the archive (`:jev-archive` the same with Jev
ranking inside each half: rarity times Jev for the frontier, Jev over the explorer's rank for the
archive). `:jev-follow` steers inside each timeline instead, beside it and never stopping it: its
named decisions (`fault`, the workload's `decide`) are drawn from the timeline's current plan, Jev's
probabilities per decision, made in the background from that timeline's own story (its faults,
failed assertions and choices; a branch starts from its parent's) and made again on news or every
10 s of virtual time; the draws it changed are in the tapes, so timelines replay exactly whenever
it answered. When a timeline ends its own instance names the moment of it to branch from (just
after a behavior it reached first, a fault it was given, a failure; one choice per timeline, all
in one call), and the generation follows the most confident half, never into a failed timeline,
the explorer's archive for the rest. `:evolve` rewrites itself: its returns are Claude's latest
proposal's (`propose-strategy!`), proposed again every 7 minutes of a run from the run's state and
the system's history (each strategy's finds and its chosen timelines' new failures per CPU-hour),
the last one passing its checks followed from the next generation and into the next run. `:learn`
needs no model: it learns which kinds of moments (a behavior's label without its numbers) lead to
branches failing a property anew, UCB1 over kinds times rarity, during a run and across runs, a
property no timeline of the run failed before paying a whole point and one already found again a
quarter. Jev is asked the same way: best a property the run has not failed yet. `:mix` is a
portfolio that learns: each generation's returns split among the explorer's whole rule, `:learn`,
`:jev-archive` and Claude's evolving strategy, a slot each to the members whose picks found bugs
not yet found best so far (credited as `:learn` credits a kind), its record kept across runs.
`:council` makes every decision with all of them at once: each generation the explorer proposes
(its frontier, its archive's best cells) and each timeline's own story does too (just after the
faults it was given, rarer kinds first), and every candidate is judged by its rarity, its kind's
record of new failures (kept as `:learn` keeps one, its own) and Jev's probability of a failure not yet had, a weighted
product under the weights and boosts Claude sets every 5 minutes reviewing how the picks paid;
inside each timeline its named decisions are drawn the same way: Jev's plan for each (made beside
the timeline, `:jev-follow`'s), each option's learned payoff (the kinds of fault chosen in
timelines that failed a property not yet found) and Claude's boosts. `:council-ender` is the
council ending the timelines headed only for failures the run already has (they failed only
properties another timeline failed, 10 s of virtual time ago, and reached no new code since), so
their workers start others; an arm to measure, its end's checks not run. Among them
`:jev` asks Jev (TypeSafe AI's System One model: typed answers with calibrated probabilities,
about 0.1 s a call) one question per timeline of a generation, the probability that branching
just after its rarest new behavior finds a bug, and `:jev-blend` multiplies it by the rarity;
its key from `--jev-key-file` or `$TYPESAFE_API_KEY`. What Jev is told the system is comes from
the run itself under serve (the hello's `run_url`: its compose file or program, scenario, faults
and property catalog, failing ones marked), and from `--jev-system` or the control port's
`jev-system <text>` when set. `:jev-faults` weights named decisions by Jev's choice over their
options. A port can serve one strategy whatever the current one is (`--strategy-ports
rarity:9110,jev:9111`, or `(serve-strategy! :jev 9111)` from the REPL): an A/B's arms, each hunt
naming its port, run with no control step between them. The slow
loop over the fast one: `:adaptive` returns as `adaptive-choice` names, and `(advise! run-url)`
(or `(advise-every! run-url 10)`) shows Claude (the `claude` command line) the run's properties
with their finds and what recent generations chose and why; Claude names the strategy to use next
and may describe the system better for Jev; every advice kept in `@advice`. Claude can also write
one: `(propose-strategy! run-url)` asks for a `(fn [generation candidates count] ...)` over the
host's helpers, refuses a form that reaches past them (I/O, eval, definitions, threads, Java
calls, other namespaces), dry-runs it on recorded generations, and registers it as `:claude-<n>`
(its code in plugins/clojure/proposed/, for review).

The client's `determinismo.strategy` (clients/clojure) serves the same protocol from whatever REPL
the client runs in, the JVM's, babashka's or jank's (the viz's), with no project of its own:
`(strategy/serve! 9120)`, then `--strategy tcp://127.0.0.1:9120`. A strategy is a map of
functions in a live registry (`:returns`, `:event`, `:decide`, `:branch`, `:end`, each optional),
`(strategy/use-strategy! :middle)` switches every connection from its next request, and each
generation's candidates and choices stay in `strategy/generations` for the REPL. Per service,
`(strategy/use-strategy-for! #"^redis" :mine)` gives the decisions and events whose `source`
(the asking process) matches a strategy of their own, the run-wide one keeping the returns and
every other source. e2e `repl-strategy` serves its `:middle` from babashka and from jank to a
tree exploration, the composer's named draws answered by a strategy of their own.

## Messages

Every request has a `method`. Every response is a JSON object; `{}` always means "the default".

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"exploration_seed":"<hex>","run_url":"http://host:port/runs/<id>"\|null}` | Once, at start. `run_url`: the run's HTTP API under serve (null outside it), for a strategy that wants more than the events it is sent: the run's events and SQL as it goes (`POST <run_url>/sql`, `/query`), its properties, earlier runs of the system. | `{"name":"<plugin name>"}`; add `"decides":false` for a plugin that only chooses where the tree returns (it is then sent no `random` or `event` requests: no round trip per decision), and `"wants":["behaviors"]` to get each candidate's behaviors in `returns`; `"labeled"` to be asked only for the decisions the guest named (`fault`, `decide`: the other pulls keep their defaults with no round trip, what makes a plugin served from afar practical), `"assertions"` to be told only of assertions, guidance and faults, and `"coverage"` besides to be told the coverage events too (the code lines a timeline reaches, live), and `"batched"` to be told events in batches (`events` requests) rather than one round trip each: what a plugin served from afar needs (a 12 s bank timeline told 4600 events through a 25 ms tunnel took 115 s). In Python: class attributes `decides = False`, `wants = ["behaviors"]`. |
| `{"method":"branch","index":I,"seed":"<hex>"[,"from":{"branch":P,"vtime_ns":T}]}` | Before each branch, with the branch's seed; `from` when it starts at a moment of branch `P` (the tree explorer), not at the setup snapshot. | `{}`, or `{"seed":"<16 hex digits>"}` to give the branch another seed (another random future: its tape's header says it, so its replay needs no plugin; `plugins/python/same_seed.py`) |
| `{"method":"returns","generation":G,"count":K,"candidates":[{"branch","start_ns","end_ns","novel","moment_ns","label"},...]}` | With `--branching tree --strategy ... --tape-dir <dir>`, after each generation: its timelines, with how many behaviors each reached first (`novel`) and the explorer's own choice of moment (`moment_ns`, `label`); with `"wants":["behaviors"]`, also `behaviors`: those it reached itself, each `{"label","vtime_ns","new_in_generation","timelines_before"}` (how many timelines of the generation reached it when no earlier one had, 0 if known before; how many timelines reached it before). `plugins/python/tree_rarity.py` is the explorer's own rule as a plugin, a starting point for trying others without rebuilding. `archive`: the explorer's Go-Explore archive, its most promising cells (twice `K`, the explorer's own ranking: rare behaviors, seldom returned to, returns that paid first), each `{"branch","vtime_ns","label","timelines","returns","paid"}` (just after behavior `label` as `branch` reached it; how many timelines reached it, how many returns went there, how many of those found something new): return to one by its `branch` and `vtime_ns` and it is credited as the explorer's own return would be. Choose up to `K` moments to branch the next generation from; with fewer, the explorer fills the rest with its own rule, the frontier then the archive (other timelines than those chosen). In Python, a `returns` with an `archive` parameter gets them. Nodes replay their parents with their tapes, so what the strategy decided there stays. | `{}` to leave it to the explorer (the frontier), or `{"returns":[{"branch":B,"vtime_ns":T,"reason":"<why>"[,"horizon_ns":H][,"branches":N]},...][,"fill":"explorer"\|"fresh"]}`; the reason is shown at the branch point, `horizon_ns` (optional) is how long that return's branches run past the moment (instead of `--horizon`): short around a decision point, long where something builds up. The generation's shape is the strategy's: the request says `branches` (timelines per return by default, `--return-branches`) and `budget` (the next generation's timelines); each return may take `branches` of them, as many as it likes up to the budget (the whole generation from one moment if it wants), and `fill` says what the timelines it left are: the explorer's own returns (`explorer`, the default) or fresh starts from the setup snapshot (`fresh`). In Python, `returns(generation, candidates, count)` returns `[(branch, vtime_ns, reason[, branches]), ...]`, or `{"returns": [...], "fill": "fresh"}`. |
| `{"method":"random","pull":P,"size":N,"default":"<hex>","source":"<process>","vtime_ns":T,"branches":C[,"decision":{...}]}` | The guest asked for `N` random bytes; pull `P` of this timeline (counted from boot); `source` is the asking process's name (Linux's `comm`, e.g. `det-faults`, `det-composer`, a test command), so a strategy can tell decision streams apart. `decision` labels it when the guest named it (the SDKs' `decide` and `random_below_named`): `{"name":"fault","options":["pause raft-2","partition raft-1 raft-3",...]}` (answer the index, little endian) or `{"name":"fault.duration_ns","range":R}`. det-faults names its faults, waits and durations, and the models of the nodes' devices: the network's baseline (`network.baseline_delay_ns`, `_jitter_ns`, `_loss_ppm`), the disks' (`disk.baseline_ms`), a degradation's flavor and netem settings (`fault.degrade.flavor`, `.delay_ns`, `.jitter_ns`, `.loss_percent`, `.duplicate_percent`, `.corrupt_percent`, `.reorder_percent`, `.rate`, `.burst_enter_ppm`, `.burst_leave_ppm`), a disk fault's (`fault.disk.failure`, `.delay_ms`, `.corrupt_byte`, `.corrupt_value`) and the clock's skips and skews (`fault.clock.forward`, `.skip_ns`, `.permanent`, `.strobe`, `.strobe_ms`, `.skew_decade`, `.skew_ns`): a strategy steers them by name, a plan shapes their distributions. | `{}` to use `default`, or `{"hex":"<2N hex digits>"[,"reason":"<why>"]}`: a reason (240 bytes at most) goes into the timeline as a `decision` event and into the tape, and the web UI shows it with what it chose (a fault's tooltip, say). In Python, return `(bytes, "reason")`. |
| `{"method":"events","events":[{"vtime_ns":T,"branches":C,"source":"<process>","event":<guest event>}, ...]}` | With `"batched"`: the events held since the last request, in order, sent before the next decision the plugin is asked, the timeline's end, or once 256 KiB of them are held. With `"plans"` also when a named decision comes and the plan is a virtual second old (empty if nothing was held); a planning plugin is told each decision's announcement (`{"decision":{"name":"fault","options":[...]}}` or `"range":N`) and each value its plan drew (`{"event":"planned","details":{"value":V,"decision":{...}}}`). | `{}`, or `{"end":true}` to end the timeline (at the decision about to be asked); with `"plans"`, `"plan":{"<name>":[[low,high,weight],...]}`: the explorer draws that decision (a u64 pull) itself, a segment by weight and a value inside it, its value on the tape as the plugin's answer, with no reason nor decision event per draw (a long timeline draws thousands; a replay repeats them without the plugin); a name the plan leaves out keeps the explorer's default. `plugins/python/plan_first.py`; in Python, a `plan()` method. |
| `{"method":"event","vtime_ns":T,"branches":C,"source":"<process>","event":<guest event>}` | The guest emitted an event (assertions, lifecycle, logs); `source` is the writing process's name, as for decisions ("" for events near the size limit). | `{}`; `{"end":true}` ends the timeline at this moment: its outcome `strategy_ended`, its end's checks (`eventually`, `finally`, the built-in finish) not run, and the tree does not extend it (`plugins/python/end_at_fault.py`; in Python, `event` returning True). |
| `{"method":"branch_end","index":I,"outcome":"<outcome>","events":E,"failing":["<property>",...]}` | The branch ended. | `{}` to continue, `{"stop":true}` to end the exploration early |

Seeds are 64-bit and travel as 16 hex digits, since JSON numbers lose precision past 2^53.
`vtime_ns` and `branches` together are the moment (ARCHITECTURE.md §1).

Two hooks before the timelines, each for a plugin that asks for it in its hello's `wants`:

- `"setup"`: the setup's decisions (a node's knobs as it first starts, the swarm's seed, its
  start draws: before the snapshot every timeline starts from) are its too. A `branch` request
  with `"setup":true` comes first, then the setup's decisions and events as a timeline's; its
  answers go on the setup's own tape (`setup.jsonl` beside the timelines'), which a replay
  applies as its setup runs again. What the setup decided, every timeline of the run shares.
- `"machine"`: the machine the run boots, asked once before it does:
  `{"method":"machine","epoch_seconds":E,"timer_slack_us":S,"timer_delay_permille":D,"tsc_jitter_seed":"<hex>","modulation_stretch_us":[low,high]}`,
  the run's own. The reply's fields replace them: the guest's wall clock at boot (Unix
  seconds, up to 2100: a leap day, a year's end, a date past a certificate's expiry), how far
  past a timer's deadline its interrupt may land (up to 1 s), how far into that slack it lands
  at the earliest (thousandths: interrupts late as a loaded host makes them; explore's
  `--timer-landing-permille`), the clock's jitter, and CPU modulation's stretches (1 us to
  10 s, low below high). The reply may also add faults of the plugin's own:
  `"custom_faults":[{"node":"<name>","command":"/abs/path args"},...]` (up to 4, 256 bytes in
  all), each a command run in that node at random times, drawn by the fault injector among the
  node's other faults as a profile's custom fault (Redis's `CLIENT PAUSE`, an admin API's
  failover, a compaction). The machine is in every tape's header and the run's record: a
  replay and a resume boot it, never asking again. `plugins/python/machine_date.py` sets the
  wall clock; `plugins/python/plugin_faults.py` adds a fault.
- `"check"`: a checker. Each timeline that ended (not one cut short at a moment) is judged by it
  at its end, its events told first: `{"method":"check","index":I,"histories":[{"name","records"},...]}`
  (`histories`: what the timeline's commands recorded for the program's host checks with
  `sdk.record`, JSON lines, whole: Elle's or a linearizability checker's input; one past the
  request's 16 MiB as `"records":null,"bytes":N`;
  `plugins/python/history_check.py`), the reply
  `{"assertions":[{"type":"always"|"sometimes"|"reachable"|"unreachable"|"always_or_unreachable","message":"...","condition":true|false,"details":{...}},...]}`
  (up to 64). Each is an assertion of the timeline at its end moment, as the program's host
  checks' are (after its guest hash: a replay without the plugin keeps the guest hash), so the
  run's properties, its report and serve's pages carry them; a `strategy_check` event says how
  many it made. With `"plans"` (and no plan) it is never asked for a decision, told the
  events in batches. `plugins/python/count_check.py` bounds how often an event happens.

## Tapes

Every answer a plugin overrides is written to the branch's tape, so a branch replays without the
plugin, which may not be deterministic itself (ARCHITECTURE.md §7):

```
{"tape":2,"inputs":"<hex>","exploration_seed":"<hex>","branch":I,"branch_seed":"<hex>"}
{"pull":P,"hex":"..."}
{"checkpoint":{"events":N,"branches":B,"events_hash":"<hex>"}}
```

A checkpoint every 64 events records the branch's state (event count, branch count, running hash
of its events); a replay compares them as it goes and stops at the first that differs ("replay
diverged from its tape at event N").

`determinismo explore ... --tape <file>` replays one branch from its tape. `inputs` identifies what
the machine booted (kernel and initramfs bytes, command line, disks): a replay with different
inputs is refused, since it would be a different universe.

## Limits

Overridden values are at most 64 bytes (SDK pulls are 8). A plugin must answer every request; a
plugin that exits or writes a malformed line ends the exploration with an error.

## Coverage

Strategies see every event, so behavior is coverage: event names, assertion outcomes. Every
decision and event also says which guest process it came from (`source`), so a strategy can
tell the system's behavior from determinismo's own (`det-faults`, `det-composer`, ...) and the
decision streams of concurrent processes apart.

For code coverage:

- **C** (or anything C-compatible): build with `-fsanitize-coverage=trace-pc-guard` and
  `#define DETERMINISMO_COVERAGE` next to `DETERMINISMO_IMPLEMENTATION`. Each edge emits
  `{"event":"coverage","details":{"name":"edge N"}}` the first time a process runs it.
- **Zig**: set `sanitize_coverage_trace_pc_guard = true` and `use_llvm = true` on the program's
  compile step and reference `sdk.coverage` (`comptime { _ = sdk.coverage; }`); the whole
  compilation is instrumented, the standard library included.
- **Python** (3.12+): `determinismo.coverage_start(paths=[...])` reports each line under those
  prefixes the first time it runs (`"line <file>:<n>"`), through `sys.monitoring`; a reported
  line costs nothing afterwards.
- **JVM** (JDK 24+; Java, Clojure, Kotlin, ...): run with the agent in
  `sdk/java/DeterminismoCoverage.java`, `-javaagent:determinismo-coverage.jar=<class prefixes>`;
  each source line of those classes reports itself the first time it runs (`"line
  <class>:<n>"`), classes defined at run time included (see `tests/antithesis-compat/java`).
  A program pinned to Java 17 to 23: its jars instrumented ahead of time at the image's build
  by a JDK of 24 or later (`java -cp determinismo-coverage.jar:<its classpath>
  DeterminismoCoverage instrument <prefixes> <in.jar> <out.jar>...`), then run on its own JVM
  with the agent (determinismo's, on `JAVA_TOOL_OPTIONS`) holding their runtime.
  States too, as SGFuzz finds them (enum-typed variables are a program's state): each store
  outside initializers of one of the program's enum constants to a field reports the
  transition the first time it happens (a `state` event, `"state <class>.<field>: OLD ->
  NEW"`), so the tree returns to timelines that reach a new state even where no new line runs
  (template `state`, against `state_int`: the same maze, its progress an int).

Coverage can also be semantic: any `{"event":"coverage","details":{"name":"..."}}` is a
feature, so a system can report an abstraction of its own state (a spec's abstract state, a
protocol phase, "two leaders seen") from any SDK, and strategies then search for timelines that
reach new abstract states, as spec-guided fuzzers do. Keep the abstraction small: a name per
distinct balance sheet, say, makes every timeline new and guides nothing.

`plugins/mutate.zig` keeps timelines that reach new features and mutates the decisions of the
process that reached them, around where it did. The benchmark is a maze (four digit checks, 1
in 10000 timelines by chance) in C and Zig (`tests/selftest/maze.c`, `maze.zig`), and in Python
and Java under faults (`tests/antithesis-compat/python` and `tests/antithesis-compat/java`, template `maze`);
`zig build e2e` checks each is solved and that the solving branch replays from its tape. First
solving branch, 6 seeds, 8 synced workers: C 24 to 211, Zig 24 to 225 (300 branches), Python 116
to 352, Java 65 to 224 (1000 branches).

Each worker runs its own strategy process; `mutate --sync-dir <dir>` makes them share one corpus
(each writes the timelines it keeps, with the features they reached first, and imports the
others'), as parallel fuzzers do: synced workers need about as many branches as one worker, run
8 at a time (unsynced, about twice as many). Give each exploration a fresh directory.

A child replays its parent's pulls exactly, the decisions and the pulls of other sizes too (the
composer's 32 bytes, say), which it never mutates but answers with the parent's bytes: answered
from each child's own seed, they moved when commands start, and under faults the maze's third
digit was another process's pull in some children (the e2e Python maze, never solved since a
timing change). `mutate --trace on` prints what the strategy sees, on stderr: each pull (its
position, source, value, and whether the parent's copy, a mutation or the branch's own), each new
feature (the position it marks and its process), and each branch's parent, frontier and mutated
positions.

## Two levels of strategy

A plugin (this protocol) decides inside a run: it sees every event with its moment and may
override any randomness pull (scheduling choices of the composer, faults and their parameters,
test inputs). It may be written in any language and use any algorithm (a fixed policy, a
learned one, a language model); it does not need to be deterministic, because every override
it makes is written to the branch's tape, and the tape alone replays the branch.

An outer loop decides across runs: it drives determinismo through the MCP server or the HTTP
API (`describe`, `explore`, `replay`, `fork`), reads the JSON results, and chooses what to do
next: which scenario, how many branches, which branch and moment to fork from. Reinforcement
learning over whole timelines, or an agent forming and testing hypotheses about a failure,
lives here. See docs/AGENTS.md.

Both compose: an outer loop can run explorations whose branches are steered by a plugin.

What strategies cannot do well yet (choose where to put a fault, where to branch) and how they
will (labeled decisions, branching mid-timeline from a plugin, Go-Explore, fault scheduling, RL
and LLM strategies, `sometimes` assertions as targets): [PLAN.md](PLAN.md), "Strategy guidance".

## Fault schedules (nemeses)

A fault schedule is a strategy that decides: the fault injector names its decisions (`"fault"`
with its options, durations, waits), and a strategy that says `"decides": true` at hello is
asked each one and told every guest event. plugins/clojure/strategies.clj's `leader-faults`
follows the Raft leader in the logs (`entering leader state`) and, when a fault is drawn, picks
one aimed at the leader seven times in ten ("nemesis: pause raft-node-2, at the leader"), as
Jepsen's nemeses go for the leader: the moments a cluster is most fragile. Its state is per
connection (an exploration worker's timelines, one at a time), reset at each `branch`.

## Causality planners

A causality analysis (`determinismo causality`, the page's Causality button, `POST
/runs/<id>/causality`) measures a failure's probability at moments of the timeline where it
happened: snapshots of it saved to disk there, futures forked from each. Which moments, and how
many futures each, is a planner's choice, on the same transport as strategies (a command's
standard input and output, `tcp://host:port`, or `@<name>` uploaded to serve):

```
determinismo causality ... --planner tcp://127.0.0.1:9102            # the Clojure host's
determinismo causality ... --planner "python3 my_planner.py"
POST /runs/93/causality {"branch":4862,"property":"...","planner":"tcp://127.0.0.1:9102"}
```

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"kind":"causality"}` | Once. | `{"name":"<planner>"}` |
| `{"method":"plan","round":R,"branch":N,"property":"<message>","snapshot_ms":S,"failure_ms":F,"futures":M,"points_asked":K,"jump_min":J,"gap_min_ms":G,"moments_left":L,"run_url":"http://host:port/runs/<id>"\|null,"tape":"<path>"\|null,"points":[{"vtime_ms","futures","failing","probability","low","high"},...]}` | Before each round (at most `--refine` rounds after the first), with every moment analyzed so far: its futures, how many failed, the probability and its 90% interval. `run_url` is the run's HTTP API: a planner may query the timeline's events there (its faults, its logs: `POST <run_url>/query`). | `{"moments":[{"vtime_ms":T,"futures":M},...],"note":"<why>"}`; no moments ends the analysis. Moments outside (S, F], already analyzed, or past `L` are left out. |

What counts as the bug in a future is pluggable too: the property failing by default, or any event
condition (`--verdict '<condition>'`, the page's verdict field, `"verdict"` in the request), on
which the timeline's replay and each future stop.

The built-in planner analyzes the moment just after the setup snapshot and K moments evenly to the
failure, then, each round, halfway inside the jumps of J or more until they are G wide.
plugins/clojure/strategies.clj serves planners on port 9102 (`--planner-port`), reloaded live
over its nREPL: `bisect` (the built-in rule), `faults` (inside each jump, a moment just before
and just after every fault injected there: whether that fault decided the bug) and `dense` (four
times the moments, one round). `(use-planner! :faults)` switches; `@plans` keeps every round asked
and answered. clients/clojure's `determinismo.api` is the HTTP API from Clojure, babashka and
jank (runs, timelines, properties, query, SQL, replays, causality), for planners, strategies and
scripts alike; `determinismo.debug` the debugger's sessions. A strategy is uploaded with
`curl -T <executable> <serve>/strategies/<name>`.
