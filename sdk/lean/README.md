# determinismo for Lean

Real code modeled in Lean 4 (core only) and run in a chaotic world with determinismo's faults:
searched for counterexamples, and proved where proofs are within reach. Every choice the world
makes is a named decision, so a timeline is its decisions, and the same decisions repeat it, as a
determinismo tape repeats a timeline of the real system.

| Module | What it gives |
|---|---|
| `Determinismo.Decide` | decisions (`decide`, `decideWeighted`, `decideRare`, `pick`), their sources (a seed, a path), `violate` |
| `Determinismo.Disk` | a file's disk, cache and pending writes; syncs, failed syncs (EIO: never retried, read back until a power loss), power losses (a prefix of the pending writes, one torn); theorems |
| `Determinismo.Cluster` | nodes running a system's code (`Behavior`: start from the disk, receive, tick, request) in a world of lost, duplicated, reordered and partitioned messages (one way too), power losses, process kills, halts, failed syncs, clock skew, swarm testing; client histories; `invariant` and `final` properties |
| `Determinismo.Threads` | a process's threads, each step atomic, the next thread a decision (`thread.next`): every interleaving within bounds; deadlocks; the story (`Process.note`) |
| `Determinismo.Locks` | a mutex and a reader-writer lock (writer priority optional, as folly's `SharedMutex`), taken with a `try` in a step (`none`: the step blocks) |
| `Determinismo.History` | linearizability of a client history against a sequential model (unanswered operations may take effect later or never; failed ones never) |
| `Determinismo.Search` | `explore` (timelines from seeds), `exhaust` (every timeline within bounds, depth first), `shrink`, `tape` (a counterexample as determinismo's named decisions) |

A node's code (`NodeM`): `send`, `readFile`, `append`, `replace`, `truncate`, `sync` (false on a
failed sync), `now`, `wallclock`, `choose` (its own randomness, a decision), `reply`, `fail`,
`check` (an assertion), `halt` (a fatal exit), `log`.

Model the real code function by function, the way it is written: its state as a structure, its
handlers as `NodeM` functions, its files' records as its own. A property the search breaks comes
with the decisions that break it and the timeline's story (`Cluster.log`), to be driven in the
real system by determinismo; a property that holds in every timeline within bounds (`exhaust`'s
`complete`) is the model's, within those bounds; a theorem is for every timeline.

    lake build
    lake exe determinismo-lean-tests

The tests: decisions replayed and enumerated, the disk's fault semantics, linearizability, locks
(opposite orders deadlock, a release in a thread's last step frees its waiter, a reader taking a
writer-priority lock again behind a waiting writer deadlocks), and a register on a write-ahead log
in three variants: acknowledging before its sync (found), ignoring
a failed sync (found), and correct (nothing in 3,000 random timelines each with power losses and
with failed syncs, nor in all 4,919 timelines of a small world).
