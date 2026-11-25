# determinismo's visualization for a jank REPL

A window (Dear ImGui, from [jank-lang/commons](https://github.com/jank-lang/commons)) that
prints what a jank REPL does with determinismo. It is the cards library's window
(`jankifier/cards`: a card for each evaluation, drawn by what its value is, with handlers,
layouts and pinned cards) with determinismo's own cards: the process is the REPL (jank's nREPL
server), so every evaluation is told to the window with its value, and so is every call of the
client (`determinismo.api`, `determinismo.debug`, `determinismo.lab`, through `determinismo.tap`).
Nothing to call for it.

```sh
(cd ~/dev/jankifier/cards && lein install)    # once: the cards library, into ~/.m2
./viz.sh                                      # the window; its nREPL port in .nrepl-port
./viz.sh --hidden --record take.mp4           # no window: its frames to a video
./viz.sh --width 1500 --height 1250           # a wider window: the lab's three columns
DETERMINISMO_URL=http://host:7878 ./viz.sh    # serve's address, else http://127.0.0.1:7878
```

Connect an editor to the port (CIDER: `cider-connect-clj`), or an agent (an nREPL client such
as `clj-nrepl-eval -p $(cat .nrepl-port) '<form>'`), and work as anywhere; `(help)` from
`determinismo.help` lists what there is. The window draws what either evaluates, so a person
watches what an agent does:

```clojure
(require '[determinismo.api :as d] '[determinismo.debug :as dbg])
(def s (dbg/open 56 {:branch 0 :until "event=core_dump" :rewind-ms 1000}))
(dbg/regs s)
(dbg/mem s 0x1342000 8)
(dbg/poke s 0x1342000 [0x0f 0x0b])
(dbg/close s)
```

What it shows:

- **The multiverse**, pinned on top, of the run the REPL last touched: a row a timeline, where
  each left the one before it, faults (orange), crashes (a red cross), each timeline's first
  failed assertion (a red dot), what a query found (blue rings), checkpoints (green flags), the
  moments looked at (ticks) and the one a session is at (the pulsing cursor). A session's own
  timeline is a tick where it left until the REPL looks at it (a session opened on it, a query of
  it); a run of many timelines is thin rows, with those looked at drawn again below them, large.
  A run started from the REPL is followed while it explores. The window's title is the run's.
  While a game's session shows frames, its screen is pinned too.
- **A card an evaluation**, the newest last (the older ones roll up under the pinned ones; the
  mouse wheel looks back), shown by what it was: a session opened (its timeline, its moment, the
  event query that named it, the faults of the second before); registers and memory with what
  they were at the last look beside what they are now, changed ones in red; the instructions at
  an address, before and after a poke (llvm-mc, when installed); an address translated, virtual
  to physical; a crash's stack (a `crash_stack` event's details: its frames, the program's own
  lines standing out); a command's output, a kernel's oops in red; a query's events and nested
  values as pretty-printed EDN; a few numbers as bars with their sum and what changed since the
  last ones; plans, draws, a variable's values over time, a function's calls, Quint's verdicts.
  Anything else is the cards' own: text as it prints, a flat map as its keys and values, rows
  (SQL's) as a table, many numbers as a series, a matrix as a heat map; no card for nil.
  `(determinismo.viz/show "name" value)` adds a card by hand, `(determinismo.viz/clear!)` removes
  them.

## The moment lab

A session's moment as a world to act in (`determinismo.lab`, clients/clojure): while the lab is on
a session, its cards are pinned under the multiverse (drawn with the lab's timelines alone) and
made again after every step.

```clojure
(require '[determinismo.lab :as lab] '[determinismo.lean :as lean])
(def s (lab/open! 2163 {:branch 0 :at-vtime-ms 30000}))  ; a session, the lab on it
(lab/world)                                               ; the world as data (and a card)
(lab/fault! s {:kind "partition_groups" :groups [["rq-1"] ["rq-2" "rq-3"]]
               :direction "outbound" :duration_ms 3000})
(lab/advance! s 1000)                                     ; the timeline 1 s on
(lab/until! s "event=node_start details.node=rq-1")       ; on to an event (60 s at most)
(lab/checkpoint! s "before")
(lab/compare! s {:kind "pause" :node "rq-2" :duration_ms 2000} {:ms 3000})
(lab/close! s)
```

- **The moment**: the nodes as boxes coloured by their state (up green, paused blue, down red,
  halted grey: stopped with no fault that ended it), each with its badges (a skewed clock, a
  failing disk, a throttled CPU, every fault on it with the time it has left), the runner (where
  the test commands run) above them; between every two endpoints a line a direction, coloured
  by what the faults on do to it: cut (red), jammed (dark red, dashed), clogged (purple), slowed
  (orange, dashed), degraded (amber, dashed), with an arrow the way it is disrupted, so a one-way
  partition is one red line beside a healthy one.
- **Acting**: click a node, or a link's handle, for its faults as ImGui buttons, sliders and
  radio buttons: a node's pause, kill, power loss, stop, isolation, clogs, CPU throttle, clock
  skew (forward or back), disk failure (errors, write errors, lost writes, corrupt reads, slow);
  a link's partition both ways or one way (stopped, slowed or jammed) and degradation (each
  flavor); the network restored; each fault's length. Each is one `det-faults inject` step of
  the session's timeline, so it is recorded and replayed with it. Time goes on by 100 ms, 1 s,
  10 s, or until an event query (`det:until`). A checkpoint saves the moment; with "try as a
  comparison" a fault is tried as `lab/compare!` does.
- **Since the last action**: the events that came (faults, nodes' starts and ends, assertions:
  a failed property in red), the nodes' last output lines, the counts of the rest, and the test
  commands' last outcomes (their exit statuses).
- **What a fault changed** (`lab/compare!`): the moment checkpointed, then two futures of it, each
  a session resumed from the checkpoint (one at a time): without the fault (a `true` command in
  its place) and with it, each run on for the same time. The card says the failed properties new
  with the fault (red) and gone, the test commands' outcomes, how the nodes end, where the two
  futures first part, and the events by name that changed most. The lab goes on in the future
  with the fault; both futures stay timelines of the run.

Every action is a plain function too, for agents and editors, and each returns its result as
data (drawn as a card when evaluated): `lab/fault!`, `lab/advance!`, `lab/until!`,
`lab/checkpoint!`, `lab/compare!`, `lab/world`, `lab/attach!` (a session opened otherwise).

### Driving a Lean counterexample

A Lean replica's counterexample (sdk/lean) is a tape of decisions; its fault decisions are
driven against a real session, given which real node each model node is:

```clojure
(lean/load! "counterexamples/R2-H4-deposed-leader-revokes-renewed-lease.tape.jsonl"
            {:nodes ["rq-1" "rq-2" "rq-3"]})
(lean/next! s)      ; the next fault, then the timeline on to the one after it
(lean/drive! s)     ; the rest, one at a time
```

`fault.crash` is a power loss (`crash`), `fault.kill` a kill and start (`restart`),
`fault.partition.side` with `fault.partition.one_way` a `partition_groups` (one way:
`outbound`, the side's packets to the rest dropped), `fault.clock.node` with `fault.clock.skew`
a `clock_skew`, the replicas' `fault.pause.*` a `thread_pause`, `disk.sync.error` a disk's
`write_errors`, and a crash point (`fault.crash_point`) a power loss at the node's next sync
(`durable_crash`) or a kill. Which model node a decision names is followed through the tape's
kills, power losses and starts; the tape's story (`<name>.story.txt`, read when beside it) names
every one and gives each fault its length and the time to the next (`lean/defaults`: a tick 100
ms, a step 20 ms). What the tape decides that the real system decides itself (which message is
delivered, dropped or duplicated, a connection's break, a tick, a client's operation, the
model's disk) is listed as skipped, never faked. The tape card is pinned while it is driven:
its steps, the next one, what each did, and "Next step" and "The rest" buttons.

## How it is made

The window, its feed, its handlers and pinned cards are the cards library's
(`~/dev/jankifier/cards`). determinismo's part is `src/determinismo/viz.jank` (a handler for its
cards, keyed `:det/card`, the evaluation's card made from what the client did during it, the
multiverse and the screen as pinned cards) and `src/determinismo/viz/lab.jank` (the lab's pinned
cards and the handlers of its results); both draw with the cards' primitives, so a draw function
changed and evaluated is used by the next frame.

The first start compiles the packages it builds on. `viz.sh` sets what that needed on macOS: the
Command Line Tools' compiler, C++17 for ImGui's headers, and no sandbox around the packages'
builds (they ask Homebrew where GLFW is). Needs `lein`, `jank`, `bb`, `cmake`, `glfw`, and
`ffmpeg` for `--record`.
