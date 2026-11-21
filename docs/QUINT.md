# Quint

`determinismo quint` checks a timeline against a [Quint](https://quint-lang.org) spec: the
events the program emitted, in the order they happened, must be a run of the spec's actions.

    determinismo quint --spec bank.qnt --events <a timeline's events> [--branch <n>]
                       [--main <module>] [--invariant <name>] [--quint <command>] [--piece <steps>]

- `--events`: a timeline's events file (`branch-<n>.jsonl`, or `.jsonl.zst` once it ended), or
  a directory of them with `--branch <n>` (a run's `events`, an `--events-dir`).
- `--main`: the spec's module, when it is not named like its file.
- `--quint`: Quint's command (`quint` by default). `npm install -g @informalsystems/quint`
  installs it; `--quint "npx -y @informalsystems/quint"` runs it without installing.
- `--piece`: the trace checked in pieces of this many events, each from the state the one
  before ended in (written back as an assignment of the spec's variables); by default pieces of
  250 above 2,000 events. Quint holds and returns one piece's states only: whole, a timeline of
  22,549 events overflowed its output. A refusal is numbered in the whole trace; the states file
  then holds the last piece's. Quint's Node may need more heap for a long run's states:
  `--quint "env NODE_OPTIONS=--max-old-space-size=6144 quint"`.

## What is checked

- The trace is the program's own events (`sdk.event(name, details)`, any SDK) whose name is an
  action of the spec. An event is one step: its name the action, its details the action's
  argument, a record. An event without details calls the action without arguments.
- Events under other names (the platform's faults, a program's other events) are left out and
  counted. A spec that wants them defines an action of their name.
- A timeline's events are totally ordered (one vCPU, virtual time): the trace is the history
  as it happened, not one of its possible orders.
- JSON to Quint: integers, booleans and strings as they are, arrays as lists, objects as
  records. A `null` field is left out of its record. A float, or a field whose name is not an
  identifier, is an error. A string's `"` and `\` become `'` (Quint's strings have no escapes).

## What it writes, beside the spec

- `determinismo_trace.qnt`: the trace as a module with one run, checked with `quint test`.

      module determinismo_trace {
        import bank.* from "./bank"

        run determinismo_trace_run =
          init
            .then(bank_read({ client: 1, source: 0, target: 1, source_balance: 100, target_balance: 100 })) // event 10 at 1.000 s
            .then(bank_commit({ client: 1, amount: 7 })) // event 13 at 1.300 s
            .then(bank_audit({ total: 400 })) // event 16 at 1.600 s
      }

- `determinismo_trace.itf.json`: the spec's states along the run, in Quint's trace format
  (ITF): the timeline in the spec's terms.

## What it answers

- Exit 0: every event was an enabled action in the state the events before it left.

      [determinismo] the trace (5 events) is a behavior of the spec (1 events under names the spec has no action for; its states: determinismo_trace.itf.json)

- Exit 3: the first event the spec refuses, with the spec's state before it.

      [determinismo] the spec refuses event 5 of 5: bank_audit({ total: 400 }) (event 16 at 1.600 s): not enabled after the 4 before it
      [determinismo] the spec's state there: { balances: Map(0 -> 95, 1 -> 107, 2 -> 105, 3 -> 100), reads: Map() }

- With `--invariant <name>` the spec's invariant is asked in the first state and after every
  event. Exit 3 names the event after which it fails: where a timeline's bug shows in the
  spec's terms.

      [determinismo] total_conserved does not hold after event 4 of 5 (bank_commit, event 15 at 1.500 s)

- Exit 1: nothing could be checked (no event named like an action, Quint did not run).

## The events' order is the trace

An event is said where the program is when it calls `sdk.event`, which is not always where
the step happened. A client that says "I wrote" after the server's reply says it when it next
runs, and by then another client's read of that write may have been said: the trace has the
read before the write it saw, and a spec that follows the events refuses it.

- Say a step where it happens (in the server that takes it), or
- make the step and its event one: the bank's scenario `bank_steps` (examples/bank) takes a
  lock around each step at Redis and its event, so the events are in the order Redis took the
  steps. Its e2e check (`bank-steps`) runs each timeline's events against the bank they
  describe: none out of order with the lock, a third of them without it.

## Steps from a system's logs

A system that was not written for determinismo says its steps in its log. An output line of a
node or a command is an event too, named by its message:

    2026-11-19T00:00:03.158Z [INFO]  node-1: election won: term=4 tally=2
    election_won({ source: "raft-node-1", term: 4, tally: 2 })

- The message is what stands before the line's `key=value` pairs, after a logger's name
  (`<when> [LEVEL] <logger>: <message>: <pairs>`, hclog's shape; logfmt's `msg="..."` too). Its
  words' letters make the name, lowercase, `_` between them. A word with a digit in it is left
  out (an address, an id), so the names stay few.
- The pairs are the argument, with `source` (the node or command that wrote the line): a value
  of digits is a number, any other a string; a key's `-` or `.` is `_`.
- A line that is a JSON object is named by its `msg`, `message` or `event`, else by its keys
  (`{"op":"apply","data":"ab12"}` is `op_data`), its fields the argument.

A spec with an action of such a name takes those lines as steps, in the timeline's order with
the program's own events. Asked with a spec that names none of them, the command lists the
names a timeline has, how many of each and an example: what there is to model.

A step can also happen and never be said: a write whose reply a fault took is in the server
and not in the trace, and the spec refuses what follows from it (an audit that lists a balance
no said commit explains). `bank_steps` runs without the fault injector for that. A system
tested under faults needs such a step in its spec (a write that may have happened), or its
steps said by the server that takes them.

## From another machine

`clients/quint/trace.sh <serve's URL> <run> <timeline> <spec.qnt> [--invariant <name>]` does
the same for a spec and a Quint that are not where the run is (someone's laptop, an agent's
machine): serve gives the timeline's run (`POST /runs/<run>/quint`), Quint runs it there, and
serve says what the result means. Same answers, same exit statuses (clients/quint/README.md).

- From a REPL (Clojure, babashka, jank): `determinismo.quint` (clients/clojure) has `kinds`,
  `check`, `simulate` and `agent`; a check answers the verdict as data (its kind, the event,
  the spec's state there, the spec's numbers along the run), which clients/jank-viz draws.
- For an agent where determinismo runs: the MCP server's `quint` tool (`determinismo mcp`).
- From the run's page: a timeline's logs have "Trace for Quint". With no name it lists the
  names the timeline's events have; with the start of a name (`bank_`) and the spec's module
  it downloads determinismo_trace.qnt, to put beside the spec and run with `quint test`.

## Writing a spec from a trace

A spec that matches a timeline is written the way a test is made to pass:

1. Read the timeline's events and pick the ones that are the system's steps. Against a spec
   with no action of their names, the command lists the names the timeline's own events have,
   how many of each, and an example of each one's details.
2. Write an action for each event name, taking the event's details as its argument: its guard
   says when the step can happen, its updates what it changes.
3. Run `determinismo quint`. A refused event and the spec's state before it say what the spec
   has wrong; change the spec and run it again until the trace passes.
4. Ask the property the program asserts as an invariant (`--invariant`), and let Quint look for
   it in the spec alone: `quint run bank.qnt --invariant total_conserved`.

An agent does the same from its own machine with `clients/quint/trace.sh`: it reads a
timeline's events from serve, writes the spec, and runs the script until it exits 0
(examples/bank/quint has the one written so for `bank_steps`).

## Walking a spec's trace through the system

The other direction: a trace the spec gives (a test run's `quint test --out-itf`, a simulation's
`quint run --out-itf`) walked through the real system, each step caused by a control and
awaited, with `sdk.trace` (sdk/zig/trace.zig). A system's adapter maps a step (the change from
one ITF state to the next) to its control (a hand-over, a cut, a freeze, a hold let go, or
nothing for a step that follows by itself) and says when the system shows it; the driver
hands the adapter the whole trace first (what a later step needs armed early), draws a wait
before each step by its kind (`trace.<kind>.delay_ms`: the tree branches on timings, the trace
fixes the structure), and polls until the step shows or diverges:

    const states = try sdk.trace.parse(arena, @embedFile("two_leaders.itf.json"));
    var adapter: DoubleVote = .{ .context = context };
    const outcome = sdk.trace.walk(DoubleVote, &adapter, "two_leaders", states);

Each step is a `trace_step` event (its kind, the wait drawn, how long it took to show), the end a
`trace_walked` event (steps taken, where it diverged) and the catalog's "a spec trace walked to
its end". `sdk.trace.int`, `field`, `get`, `tag` and `contains` read ITF values (bigints,
records, maps, variants, sets).

## Limits

- 65,536 events a trace. Quint takes about 5 ms an event (a 3,000-event timeline: 18 s on a
  Xeon E-2276G, 4 s on an Apple M-series).
- The run is a tree of short runs (20 events each): Quint's evaluator takes a chain of `.then`
  as deep as it is long, and a long one ends it ("recursion limit exceeded").
- Events as actions, not states: Quint's simulator cannot be asked whether some step of a spec
  leads to a given state (an action cannot constrain the state it leads to). A check of states
  is `determinismo tla`, with TLC.
