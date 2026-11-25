# determinismo for Lean

Real code modeled in Lean 4 (core only) and run in a chaotic world with determinismo's faults:
searched for counterexamples, and proved where proofs are within reach. Every choice the world
makes is a named decision, so a timeline is its decisions, and the same decisions repeat it, as a
determinismo tape repeats a timeline of the real system.

| Module | What it gives |
|---|---|
| `Determinismo.Decide` | decisions (`decide`, `decideWeighted`, `decideRare`, `pick`, `permutation`, `subset`, `composition`), their sources (a seed, mixed; a path), `violate`; `unrecorded` (a setup phase whose decisions are not the timeline's: a search explores what follows it); `MonadDecide` (code that decides without knowing its world: a pure module run from a node's code or over `Decisions` alone) |
| `Determinismo.Disk` | a file's disk, cache and pending writes; syncs, failed syncs (EIO: never retried, read back until a power loss or an eviction), power losses (a prefix of the pending writes, one torn; or any subset), eviction under memory pressure, writes cut short; theorems; writes in place (`Write.at`, pwrite) torn by sectors at a power loss (`crashSectors`: any of their sectors kept); `FileSystem`: directories whose names are durable only at `syncDir` (a synced file renamed over another is the old one after a power loss before it); latent sector errors (`corruptAt`, `readAt`: a record reads corrupt until written again, through power losses), misdirected writes (`syncMisdirected`), a fault budget per zone (`FaultBudget`, TigerBeetle's model) |
| `Determinismo.Cluster` | nodes running a system's code (`Behavior`: start from the disk, receive, tick, request) in a world of lost, duplicated, reordered and partitioned messages (one way too), power losses (also inside a node's code: crash points at each write, before it, cut short or applied before the call returned, and at each sync, before or after it), process kills, halts, failed syncs, page-cache eviction, clock skew, swarm testing; client histories; `invariant` and `final` properties; connections (`Config.connections`: a death takes its messages in flight, sends to a down node fail, each live peer sees a reset, `Behavior.connectionLost`, or a silent death, by a decision); faults and clients kept to some nodes (`Faults.targets`, `Config.clientNodes`); timers (`Node.setTimer`, fired as events, gone with their process), delayed sends (`Node.sendAfter`), ghost state for properties (`Node.setGhost`, `Cluster.ghostOf`); a fair recovery (`Config.fairRecovery`: no decisions, deliveries rotating over destinations alternating with ticks in turn: a liveness property fails for the system, never for a starving schedule) |
| `Determinismo.Threads` | a process's threads, each step atomic, the next thread a decision (`thread.next`): every interleaving within bounds; deadlocks; the story (`Process.note`); threads spawned (`Process.spawn`), joined (`finished`), cancelled (`cancel`, seen at `cancelRequested`) or stopped |
| `Determinismo.Locks` | a mutex and a reader-writer lock (writer priority optional, as folly's `SharedMutex`), taken with a `try` in a step (`none`: the step blocks); a condition variable (`Condvar`: a wait's two steps, `notifyOne` deciding which waiter, `notifyAll`, spurious wakeups by a decision, a notify with nobody waiting lost) |
| `Determinismo.History` | linearizability of a client history against a sequential model (unanswered operations may take effect later or never; failed ones never) |
| `Determinismo.Search` | `explore` (timelines from seeds), `exhaust` (every timeline within bounds, depth first), `shrink`, `tape` (a counterexample as determinismo's named decisions) |
| `Determinismo.Census` | `census` (every timeline within bounds, counted: per property its count and first counterexample), resumable from its `next` (`censusStep`; `pathLine`/`pathOfLine` across processes), `censusIO` (segments under a wall-clock budget, progress after each), `deepen` (iterative deepening: shallow counterexamples first, each timeline counted once), `size` (Knuth's estimate from uniform probes); `Bounds` (a depth cap, per-name option caps) for all of them and for random draws |
| `Determinismo.Edn` | EDN values and their text (`Edn.render`): cases for Clojure systems (an Elle history, a Datomic transaction, a jank form); JSON is Lean's own `Lean.Json` |

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

The tests: decisions replayed and enumerated (a timeline's first decision spread across seeds, an
unrecorded phase, code deciding without knowing its world), the disk's fault semantics,
linearizability, crash points under `nodesDownMax` (inside a first boot and a restart, never past
the bound) and eviction
(a register that halts on a failed sync but starts again without writing its log again is found by
kills and eviction alone, and by nothing without eviction), locks
(opposite orders deadlock, a release in a thread's last step frees its waiter, a reader taking a
writer-priority lock again behind a waiting writer deadlocks), and a register on a write-ahead log
in three variants: acknowledging before its sync (found), ignoring
a failed sync (found), and correct (nothing in 3,000 random timelines each with power losses and
with failed syncs, nor in all 4,919 timelines of a small world).
