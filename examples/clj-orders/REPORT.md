# An orders service in Clojure, on Kafka and Postgres, written at a REPL in a fast VM

2026-11-11, phoenixNAP s1.c1.small (Xeon E-2276G, 6 cores, 12 threads, 64 GB), branch `fast-vm`.

The question: can a Clojure developer write a service against real Kafka and Postgres at a
REPL, at full speed, and from that same REPL explore it with faults, deterministically, without
leaving the session? The service: orders taken over HTTP, put on Kafka (`acks=all`, idempotent
producer), a consumer writing them to Postgres; acknowledged once Kafka has them. Its property:
every acknowledged order ends up in Postgres. Nothing of it is in the image: it is written form by
form at the REPL (`repl-session.clj`).

## The setup

- `compose.yaml`: Kafka 4.0 (KRaft, one node), Postgres 17, and a JVM with nREPL (Clojure 1.12,
  Kafka's client, next.jdbc, Postgres's driver, determinismo's Clojure SDK).
- The drivers, test templates in the image: `parallel_driver_order.sh` places 5 orders over HTTP
  and keeps the acknowledged ids; `eventually_verify.sh`, once faults stop, posts them to the
  service's `/verify`, which asserts the property with the SDK.
- `determinismo-sandbox create --compose examples/clj-orders/compose.yaml --vcpus 4 --memory-mib
  6144`: the fast VM booted the three nodes (532 to 546 s: the app's image rebuilt each time,
  its SDK layer changed), a base checkpoint (618 to 638 ms, 986 to 989 MB on disk), and
  `nrepl-proxy.py --dev` served the app node's nREPL on the host. Three machines in all: the
  first two found the bugs in determinismo listed at the end, the third ran with them fixed.

## Writing it at the REPL

Each form's wall time at the REPL (the fast VM, 4 vCPUs, real time; the second machine's
session, the first to run whole):

| form | time |
|---|---|
| `(require ...)` next.jdbc and the SDK, first load | 5.45 s |
| the orders table created | 0.29 s |
| the Kafka producer | 0.61 s |
| `place!`, the consumer and its thread, `verify`, the HTTP server: each | 0.05 to 0.45 s |
| `(place! "first-book")`, acknowledged by Kafka | 0.75 s |
| the row in Postgres 2 s later | 0.13 s |

## Exploring from the REPL

`(w/explore-here! {:branches 24 :time-budget "10m"})` answered `{:run 1, :checkpoint
"1/here-2"}` in 0.67 s: the machine checkpointed as it stood (348 ms, 348 MB on disk: only the
pages changed since the base checkpoint), and serve started a run of deterministic timelines from
it. In each, the drivers place orders against the service just written while faults hit the
three nodes (pauses, partitions, degraded links, process and thread pauses), then the
verification. The numbers below are the third machine's, once the fixes below were in; the
first two found the same bugs.

**Run 1: 8 of 17 timelines fail "every acknowledged order is in Postgres".** Every timeline put
load on the service (32 to 19,656 driver starts).

- **5 timelines: the consumer died.** One exception left `consume!`, its thread ended, and no
  order after it reached Postgres (25,359 to 76,280 missing). Every one of the 5 has the
  consumer's death in its output, and no passing timeline has it. Two ways in:
  - a Postgres connection failing under a fault (`PSQLException`): connect timed out (3),
    network unreachable (1);
  - Kafka's `commitSync` timing out after 60 s (1).
  On the first machine the same, and a third way: the consumer kicked out of its group, its
  offset commit refused (`CommitFailedException`).
- **3 timelines: the consumer alive but behind** (397 of 3,734, 2,276 of 8,226, and 23,273 of
  74,613 missing). One connection opened per insert (10.8 ms each at the REPL, 3.0 ms on a
  connection kept open): about 90 orders a second, behind by thousands when the faults stopped
  and still behind after `verify`'s minute.

## The fix, at the REPL

`consume!` rewritten (`repl-session.clj`): it reopens after an error, and writes each poll's
records as one batch in one transaction on a connection it keeps; offsets committed after the
inserts, inserts idempotent (at least once, stored once). `verify` also reports how many were
missing when it began. The old thread interrupted, a new one started, an order checked (1.33 s),
and `(w/explore-here! ...)` again: run 2 from checkpoint `1/here-3` (0.72 s; 409 ms, 426 MB).

**Run 2: 21 of 22 timelines pass.** The consumer reopened in 10 of them (up to 36 times in one);
5 began `verify` with orders still missing (9, 11, 225, 233 and 7,580) and caught up within its
minute.

**One timeline fails, a new way:** timeline 10, 885 orders missing when `verify` began and the
same 885 when it ended: the consumer neither dead nor reopening, stuck.

## A REPL inside the failing timeline

`nrepl-proxy.py --serve http://... --run 3 --branch 10 --until
'event=command_start details.name="eventually_verify.sh"' --node app`: serve replayed timeline 10
deterministically to the moment its verification started, and served that replayed JVM's
nREPL. (Run 3 is run 2's request again, on the build with the replay fixes below: the same
checkpoint and seed gave the same timelines, events hashes equal, 0, 1, 2, 5 and 10 compared.)
There, at the REPL:

- `(.isAlive consumer-thread)` true, its state `RUNNABLE`;
- its stack: a socket read in pgjdbc, under `next.jdbc`'s `with-transaction` asking the kept
  connection its isolation level (`PgConnection.getTransactionIsolation`);
- the group's committed offsets 2,679, 2,505 and 2,618 against the partitions' ends 2,982, 2,792
  and 2,913: 885 behind, the missing orders exactly; the group `Stable`, this consumer holding
  all three partitions.

A fault had cut the Postgres connection silently, and pgjdbc waits for a reply forever by
default (`socketTimeout` 0): the connection the fix kept open became a place to hang. The fix,
at the dev REPL: `:socketTimeout 30 :connectTimeout 10` on the connection, the consumer
restarted (the old one ends after its poll), an order checked, and `(w/explore-here! ...)`:
run 4.

**Run 4: 19 of 19 timelines pass** (from checkpoint `1/here-4`: 408 ms, 451 MB). The consumer
reopened in 5 of them (up to 10 times in one), after: a connection attempt failing (12), an I/O
error sending to Postgres (2), the 60 s commit timeout (1), a rollback failing (1), a commit
refused after a rebalance (1). 3 began `verify` behind (4, 5 and 503 missing) and caught up.
None of the 19 met a connection cut silently mid-read, as timeline 10 had: the bounded reads are
in, not yet exercised by a timeline.

## In short

- Writing the service at the REPL against real Kafka and Postgres ran at the speed of any REPL:
  most forms under half a second.
- `(w/explore-here!)` from that REPL: under a second to a run of deterministic timelines with
  faults, from the machine exactly as it stood; each later checkpoint 348 to 451 MB, in 348 to
  409 ms.
- The service as first written lost acknowledged orders in 8 of 17 timelines (a consumer that
  died on its first error, and one too slow to catch up); the fix written at the REPL held in 21
  of 22, and the one left, a hang, was found with a REPL inside that timeline replayed to its
  moment; the second fix held in 19 of 19.
- On the way, determinismo needed the fixes below; the fast VM's clock on hosts without TSC
  scaling and replays of runs from a checkpoint were the ones that mattered most.

## A clock that ran ahead

On the second machine, every timeline of a run began with the same stretch of virtual time in
which nothing ran: 92.3 s for a checkpoint at 1,682.7 s, and a timeline whose drawn driver phase
was shorter (25 to 78 s) spent it all there (15 of 24 timelines started the driver at most once).
The gap was a constant share of the checkpoint's age: 20.3 s at 371.2 s, 29.7 s at 541.2 s,
92.3 s at 1,682.7 s, 222.3 s at 4,053.9 s (the first machine's): 5.47 to 5.49%. phoenixNAP's
Xeon E-2276G has no TSC scaling: the fast VM asked KVM for the deterministic 4 GHz TSC, KVM
accepted it (without scaling it only catches the TSC up now and then), the guest's TSC ran at
the host's 3.79 GHz, and the fast VM's PIT clock, computed at 4 GHz, ran 5.49% ahead of it. Each
checkpoint saved its timer that far in the future of the guest's own clock. Fixed: the fast VM
asks KVM whether it scales TSCs and runs its PIT clock at the rate the guest's TSC really has;
each checkpoint logs the skew between the two (the third machine's: 191 to 210 us; e2e fast holds
it under 5 ms). srv4's Xeon Gold 6152 scales TSCs: there the clock was right.

## What determinismo needed

Built for this: exploring from the REPL, and diff checkpoints. Fixed on the way, each fix with an
e2e check that failed before it and passes after: the rest.

- **Explore from the REPL**: the SDK's `w/explore-here!` (an `explore_request` event), serve's
  watcher of each machine (checkpoint, then a run from it), the answer back through a FIFO.
- **Diff checkpoints**: after the first, a checkpoint writes only the pages changed since the
  previous one, which becomes its base.
- **The timeline limit counts from the checkpoint**: the fast VM's clock carries its whole
  session, and every timeline from a checkpoint taken after an hour was a "hang" at its start.
- **Timelines take explore's settings**: the guest kept the fast VM's kernel command line, so
  the composer and the fault injector never saw explore's driver length, swarm or fault
  weights; the platform now gives the timeline's command line to the guest's agent with its
  start (`/run/det/cmdline`). Before it, 14 of 24 timelines ended within half a second of
  wall time (the one looked at: a single driver start).
- **Forks keep their CPUs**: a fast VM restored from a checkpoint created its other vCPUs after
  the interrupt controllers' restore, and the guest's INIT and SIPI never started them.
- **A fast VM ends when its directory is deleted**: no serve can reach it any more.
- **The dev nREPL proxy keeps what it read past a message's end**: a reply the server sent by
  itself (output a thread printed) lost its first part, and the next message's client got its
  tail alone, its bencode broken (twice in this session, "prepare2" where a length belonged).
- **The fast VM's clock on hosts without TSC scaling** (above).
- **Replays and sessions of a run from a checkpoint start from the checkpoint**: serve's replay,
  session and extract commands lacked the run's checkpoint (a session booted the system fresh,
  its tape a stranger's: `ReplayDiverged`), explore refused a tape with a snapshot, and a
  replay left the tape's explore-here answer unconsumed (`TapeOutOfOrder`). Runs made before
  the fix replay with their own explorer, which refuses: run 2's request was run again (run 3).

A run of the exploration stays in serve like any run, each timeline replayable exactly (serve's
replay and sessions, from the run's tapes).
