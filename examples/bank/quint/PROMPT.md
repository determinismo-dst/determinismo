A small bank kept in Redis was tested under determinismo, a deterministic simulation platform.
Run 1 on the server at http://127.0.0.1:7979 has six timelines (0 to 5). In each one the bank's
clients said every step they took as an event: `bank_read`, `bank_commit`, `bank_reject`,
`bank_audit`. You do not have the bank's source code, only its traces.

Your task: write a Quint spec, `bank.qnt` (module `bank`), that every one of the six timelines is
a behavior of, and use it to say what is wrong with the bank.

What you have in this directory:
- `QUINT.md`: how a timeline is checked against a Quint spec. Read it first.
- `./trace.sh http://127.0.0.1:7979 1 <timeline> bank.qnt [--invariant <name>]`: checks one
  timeline against your spec. Exit 0: the trace is a behavior of the spec. Exit 3: it prints the
  first event the spec refuses (or the event after which the invariant fails) and the spec's
  state there. With a spec that has no action named like an event, it lists the timeline's
  event names, how many there are of each, and an example of each one's details.
- Quint itself: `quint` is on the PATH (`quint typecheck bank.qnt`, `quint run ...`).

Rules for the spec:
- One action per event name, taking the event's details (a record) as its argument. Do not model
  the platform's own events (fault, command_start and the like).
- Guards as strict as the events allow: a read must see exactly the balances your spec has, a
  commit must write exactly what its client's read implies, an audit must list exactly your
  spec's balances. A spec that accepts anything proves nothing.
- The spec must pass on all six timelines (run the script on each).

Then:
1. State the property a bank must keep as `val` in the spec and check it on every timeline with
   `--invariant`. Note which timelines break it and at which event.
2. Add a `step` action (nondeterministic, over small sets) and see whether Quint's simulator
   finds the same violation in the spec alone: `quint run bank.qnt --invariant <name>`.
3. Write `NOTES.md`: what the spec says in a few lines, which timelines break the invariant and
   where, what the bug is in plain words, and what a fixed bank would have to do.

Work only in this directory. Do not ask questions; finish the task.
