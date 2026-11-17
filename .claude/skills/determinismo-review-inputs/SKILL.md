---
name: determinismo-review-inputs
description: Review a determinismo workload's input distribution (its drivers' operations, sizes, keys, pacing and draws) for what keeps it from reaching bugs, without changing it. Use when asked whether a workload explores well, why a hunt finds nothing, or before a workload's first long hunt.
---

# Reviewing a workload's inputs

Faults and strategies find timelines, but only the states a workload's inputs can reach get
explored. Swarm testing's lesson (docs/SWARM.md, docs/ANTITHESIS_EXPLORATION.md): randomize the
policy per timeline, not only the choices under a fixed policy. Read the workload (its
`*_test.zig`, its start scripts, the system's limits) and report; change nothing.

## What the platform already does (not findings)

- Fault kinds per timeline (swarm), their weights, regimes of rate and duration redrawn in
  stretches; `--no-swarm` turns all of it off.
- The composer: drivers kept per timeline (one `s.workload` driver at least), load in
  stretches (steady, quiet, spike), parallelism drawn.
- `sdk.swarm_choice`: operations kept, weighted and repeated in runs, per timeline.

## Findings, in tiers

**High: the workload cannot reach a state class.**
- Symmetric operations drawn uniformly (put/delete, insert/remove, join/leave): the state stays
  near its start. Fix: `sdk.swarm_choice` for the operation.
- A capacity, threshold or limit (cache size, batch size, segment size, compaction trigger,
  split threshold, timeout) the workload never reaches at test sizes. Fix: lower it in the
  system's configuration, or draw sizes up to and past it.
- A PRNG seeded once at a driver's start (`std.Random.DefaultPrng.init(seed)`, a library's own
  `Random`): every branch after the start repeats the same values. Fix: draw from the SDK at
  each decision.
- A draw in the setup (`s.setup`, or a node's first start): made before the timelines part, it
  is one value for the whole run (a random schema, a size, a workaround's coin: PostgreSQL's
  internal-sim schema and pg_hba draw, 2026-11-08). Fix: draw it in a `first` command (one a
  timeline, after the setup's snapshot, before faults; the composer runs one `first` of a
  scenario), at each start, or `s.snapshot_before_nodes = true`.
- Two-to-n of a group taken as its first ones (`for (mops[0..count], 0..) |*mop, id|`): the
  first is in every operation, the last only in the largest. Fix: shuffle, then take.
- A nemesis driver beside the workload without `s.workload` marking the workload's drivers: no
  timeline runs without the nemesis (unmarked scenarios of four drivers or fewer are only
  reweighted), and with more than four drivers a timeline of only nemeses judges nothing.

**Medium: the workload reaches it rarely.**
- Every tunable fixed per workload: key pool size, value size, transaction size, read/write
  ratio, retry count. Fix: named draws per timeline (`sdk.random_below_named`), sizes across
  orders of magnitude, probabilities from extremes and a middle (0.02, 0.3, 0.95).
- Only valid inputs, or a fixed share of invalid ones. Fix: the share drawn per timeline.
- One client shape (all clients alike, all keys shared). Fix: clients drawn unlike each other,
  their key overlap drawn.
- Monotonic growth only. Fix: grow-then-shrink, oscillation, as swarm runs give.

**Low: the workload's own noise.**
- An operation mix with dozens of operations all always on (passive suppression): each is
  called too rarely to matter. `sdk.swarm_choice` again.
- Values around configured limits (N-1, N, N+1, 2N) never drawn. Fix: `sdk.random_near(name,
  limit, max)` (every SDK: `randomNear`, `RandomNear`, `det_random_near`; docs/SDKS.md).

## Never findings

- Values that must be unique (ids, Elle's register values, idempotency keys) drawn plainly:
  they must stay plain. Shaping them (boundaries, repeats) makes duplicates, false anomalies.
- A driver that ends after a few operations: the composer starts drivers again and again.

## Output

A list, one line each: tier, the driver or file:line, what it keeps from being reached, and
the change (an SDK call, a configuration value). Then the workload's backlog item in its
README or PLAN, one workload at a time.
