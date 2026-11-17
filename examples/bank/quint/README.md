# The bank as a Quint spec, written from its traces

`bank.qnt` is a Quint spec of the bank of this example. An agent wrote it from the timelines
of one run, without the bank's source: what `determinismo quint` is for (docs/QUINT.md).

## How it was made

- The run: the scenario `bank_steps` through `determinismo serve`, seed 1, six flat timelines
  of 8 s. Four of them fail "total balance is conserved".

      curl -X POST localhost:7878/runs -H 'Content-Type: application/json' -d '{
        "program": "zig-out/bin/bank-test", "scenario": "bank_steps", "coverage": "off",
        "seed": 1, "branches": 6, "branching": "flat", "timeline": "8s"}'

- The agent: Claude Code on a laptop (`claude -p`, allowed to read and write files in an empty
  directory and to run `./trace.sh`, `quint` and a few shell tools). It had `PROMPT.md`,
  docs/QUINT.md, `clients/quint/trace.sh`, Quint 0.33.1, and serve's URL through a tunnel.
  46 turns, 12 minutes.
- What it left: `bank.qnt` and `NOTES.md` (its own account: the spec, where each timeline
  breaks the invariants, the bug, and a fixed bank). Both are here as it wrote them.

## What was checked afterwards, by hand

| timeline | events | passes the spec | `total_conserved` | `no_lost_transfer` |
|---|---|---|---|---|
| 0 | 1637 | yes | fails after event 28 | fails after event 8 |
| 1 | 1634 | yes | fails after event 22 | fails after event 22 |
| 2 | 2972 | yes | fails after event 20 | fails after event 20 |
| 3 | 1639 | yes | fails after event 51 | fails after event 15 |
| 4 | 1 | yes | holds | holds |
| 5 | 1115 | yes | holds | holds |

- The last audit's totals in `NOTES.md` (1180, 516, 489, 260, 400, 400) are the timelines'.
- `quint run bank.qnt --invariant total_conserved` finds a violation in the spec alone.
- `quint run bank.qnt --step fixed_step --invariant "total_conserved and no_lost_transfer and
  no_overdraft" --max-samples 20000 --max-steps 50` finds none (a simulation, not a proof).
- Not checked: the notes' account of which client overwrote which in timelines 1 to 3.

`no_lost_transfer` is the agent's own: stronger than the property the program asserts, it
fails earlier in two timelines, where one transfer undid another and left the total at 400.

## Repeating it

    clients/quint/trace.sh http://127.0.0.1:7878 <run> <timeline> examples/bank/quint/bank.qnt
    clients/quint/trace.sh http://127.0.0.1:7878 <run> <timeline> examples/bank/quint/bank.qnt --invariant total_conserved
    quint run examples/bank/quint/bank.qnt --invariant total_conserved

Where the run is: `determinismo quint --spec examples/bank/quint/bank.qnt --events
<the run's events> --branch <timeline>`.

A run on another build has other timelines (the events and the places differ); the spec
accepts them all the same, or the bank changed.
