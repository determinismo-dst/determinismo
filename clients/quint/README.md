# Quint, from another machine

`trace.sh` checks a timeline of a run on a `determinismo serve` against a Quint spec kept on
this machine: what `determinismo quint` does where the run is (docs/QUINT.md), for someone, or
an agent, who has the spec and Quint here and reaches serve over HTTP.

    clients/quint/trace.sh <serve's URL> <run> <timeline> <spec.qnt> [--main <module>]
                           [--invariant <name>] [--quint <command>]

- Needs `curl`, `jq` and Quint (`npm install -g @informalsystems/quint`, or
  `--quint "npx -y @informalsystems/quint"`).
- Writes beside the spec: `determinismo_trace.qnt` (the timeline's events as a run of the
  spec's actions), `determinismo_trace.itf.json` (the spec's states along it) and
  `determinismo_trace.out` (what Quint printed).
- Exit 0: the trace is a behavior of the spec. Exit 3: it is not; the first event the spec
  refuses, or the event after which the invariant fails, is printed with the spec's state
  there. Exit 1: nothing could be checked.

What it asks serve, twice (`POST /runs/<run>/quint`):

- `{"branch": 3, "spec": "<the spec's text>", "main": "bank", "file": "bank"}` (and
  `"invariant"`): the answer has the module's text (`module`), its file's name and how many
  events it has. `"actions": ["bank_read", ...]` in place of `spec` names the actions without
  sending the spec. `kinds` lists every name the timeline's own events have, how many of each,
  and the first one's details as the argument its action would get: what a spec could take,
  printed by the script when the spec has no action of any of those names.
- The same with `"passed"` (whether `quint test` passed) and `"states"` (the content of
  `determinismo_trace.itf.json`): the answer has the verdict's `status` and `text`, and the
  same as data: `kind` ("behavior", "refused", "invariant", "unknown"), `event` (the one
  refused, or after which the invariant was lost: its `index` among the trace's `of` events,
  its `seq` and `vtime_ns` in the timeline, its `action` and `argument`) and `state` (the
  spec's state there as plain JSON: a map an object, a set a list). `trace.sh --json` prints
  it.
