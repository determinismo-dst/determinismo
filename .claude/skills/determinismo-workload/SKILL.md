---
name: determinismo-workload
description: Write a determinismo test program (the Zig workload) for a system - its nodes, profiles, scenarios, drivers and recovery checks - and wire the SDK's assertions into the service. Use when asked to test a service, docker-compose project or cluster under determinismo.
---

# A determinismo workload

A test program is one Zig file, run inside the guest, that describes the system and drives it.
Read one example first: `examples/bank/bank_test.zig` (Redis, small), `examples/raft/raft_test.zig`
(three nodes), `examples/nrepl/nrepl_test.zig` (a protocol client), or
`examples/clojure-libs/libs_test.zig` (one scenario per library, as a function).

## Shape

```zig
const Nodes = struct { db: sdk.Node, app: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .transfers = transfers } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.db, .{ .build = .{ .context = ".", .dockerfile = "path/Dockerfile" },
        .ready = .{ .tcp = 5432 } });
}

fn transfers(s: *System.Scenario) void {
    s.parallel_driver("transfer", transfer);   // run concurrently, many times, under faults
    s.parallel_driver("rebalance", rebalance); // a nemesis of the workload's own, beside it
    s.eventually("recovers", recovers);         // after faults stop: the system works again
}
```

- A `singleton_driver` runs **alone**: a timeline that draws it runs no other driver (Antithesis's
  rule; half the timelines of a scenario with one). For a whole-program test (one driver), not
  for something meant to run beside the workload (a tablet mover, a reconfiguration, a
  rebalance): those are parallel drivers (Dgraph's tablet mover as a singleton left half its
  timelines without a workload, trial run 503).
- A driver that finds nothing to do (a slot taken, a lock held, a node not ready) waits for it
  rather than returning at once: the composer starts it again within milliseconds, and a start
  that returns at once becomes a busy loop of processes (SQLancer's slots, TiDB trial run 1529:
  4,415 starts in one timeline, the guest's CPU spent on them; a blocking `flock` fixed it).
- Keep each start of a driver short (a few operations, seconds to a minute): the composer starts
  drivers again and again, and a timeline drawn with parallelism 1 runs one at a time, so a long
  one holds the only slot (the tablet mover's 30 rounds held one for 206 s, its workload never
  started: trial run 504).

- Nodes are containers built from Dockerfiles (fetch every dependency at build time: the guest
  has no network), or binaries. An Antithesis-style compose project runs as is
  (`explore --compose compose.yaml`, see `tests/antithesis-compat`); `determinismo validate
  --compose compose.yaml` first resolves it without booting and names what would keep a run from
  testing it (a command file not executable or without a shebang, a template with no driver).
- Draw every choice from the SDK (`sdk.random_below`, `sdk.decide("name", options)`), never from
  the clock or `std.crypto.random`: strategies steer these, and replays repeat them.
- Randomize the policy per timeline, not only the choices under a fixed one (swarm testing:
  docs/SWARM.md, docs/ANTITHESIS_EXPLORATION.md). Drawn uniformly, inserts and removes keep a
  cache near empty forever and its eviction never runs. Draw a driver's operation with
  `sdk.swarm_choice(Op, "<workload>.operation")`: each timeline keeps some operations, weights
  them, and repeats answers in runs, the mix changing with stretches of virtual time. Also per
  timeline, by named draws (`sdk.random_below_named`): sizes across orders of magnitude, key
  pools from 1 to thousands, probabilities from extremes and a middle (0.02, 0.3, 0.95), valid
  and invalid inputs mixed. Values that must be unique (ids, an Elle register's values) stay
  plain draws: never shape them.
- Mark the drivers whose operations the properties judge with `s.workload("<name>")` when the
  scenario has nemesis drivers beside them (a member changer, a migrator, a mover): the
  composer's swarm then leaves any driver out of some timelines (timelines with no nemesis at
  all among them) and keeps one marked driver at least. Unmarked, a scenario of four drivers or
  fewer keeps them all, weighted per timeline: safe, but never without its nemesis.
- Values around the limits the system is configured with (a queue's capacity, a batch size, a
  timeout: N-1, N, N+1, 2N) are where bugs sit: draw them by name, one of the menu or uniform.
- Draw from the platform at each decision, never from a PRNG seeded once at a driver's start:
  every branch after the start would repeat the same values.
- Membership changes are where clustered systems break (Jepsen's member nemesis): give the
  system a spare node (`.spare = true`: prepared, not started) and a `member` parallel driver
  that takes one step at a time under a lock file: join the spare, remove it through the
  system's API (stopped first when it would otherwise rejoin), join it again fresh (`wipe`).
  See `examples/etcd/etcd_test.zig` (`member_step`) or `examples/cockroachdb`.
- Progress that builds up (a backlog, outcomes left unknown) can be an objective:
  `sdk.optimize(message, bucket, value, .maximize)`; the tree climbs from each bucket's best.
- Clients: `sdk.tcp` (`Connection`, `request_line`, `http`), `node.exec_output` to run a command
  in a node. Protocol clients stay in the example (see `examples/bank/resp.zig`).
- A driver that loses its server to a fault is not a failure: `sdk.tcp.unavailable(err)` tells
  those errors apart; note them with a `sometimes`, pause a drawn moment (`return
  sdk.unavailable_pause();`: 0.2 to 1 s), and return. Returning at once, the composer starts it again within 20 ms, and an
  outage of seconds becomes thousands of starts (etcd's lease driver: 1,606 in one timeline,
  trial run 1534).
- A `sometimes` is a target, cataloged as the program starts: one never true fails the run.
  What may rightly never happen (a known bug's signature, a rare documented behavior, a budget
  running out) is an `sdk.event`, searchable and no property (Redpanda's run 177 failed on a
  Kafka-only sometimes).
- A claim that covers a minority's failures (a replicated policy surviving one replica, a
  quorum of 2n+1 surviving n) needs its scenario's `s.nodes_down_max`: the nodes' own faults
  overlap otherwise (one node's restart beside another's power loss), and `outage = false` only
  keeps them out of simultaneous outages. Without a cap, judge only what survives any failure.
- A timeline runs one ending command: one `eventually` or one `finally` among the scenario's
  (Antithesis's rule), so two are alternatives, each judged in some timelines only. Checks that
  must all run go in one command, in order (a durability read after a recovery check; Comdb2's
  judgment and its generations, etcd's recovery and durability ran each in about half the
  timelines until 2026-11-08); the same for `first` commands.
- `eventually` retries (`sdk.retry`) and ends in `assert_unreachable(...)` if the system never
  recovers. It kills the drivers still running as the composer reaches it (Antithesis's rule):
  a check that needs them done is a `finally` command (faults stop after them).
- Judge durability directly once faults stop: Elle below strict serializability takes a read
  missing a committed write for an older snapshot, and the drivers' own reads may never read a
  key again (a committed row lost so once, Elle none the wiser). List-append workloads: a
  `finally` command calling `sdk.elle.final_reads(arena, &history, &reader)`, the reader's
  `read_list(arena, key)` reading one key's list through any node that answers (see
  `examples/sql/append.zig`, `examples/mongodb/mongodb_test.zig`). Before declaring a queue
  drained, wait past the broker's dead-connection detection: a delivery held by a connection
  that died in the faults comes back only then (RabbitMQ: drain, wait 15 s, drain again).
- Never hide a system's bug for good: no permanent workaround (a sync of its files, a patched
  build, a fault left out, a known-exit entry, an outcome reclassified) for a real bug. The path
  its users take stays the default and a property fails whenever the bug happens. Only a bug
  that fails every timeline and keeps the rest from being tested is worked around, and then at
  random: a draw per timeline or operation (`sdk.random_below_named`), a node's drawn flusher
  (`writeback_s`), or in a start script `$DETERMINISMO_DRAW` (a number drawn for each start).
  Swarm testing already leaves each fault kind out of about half the timelines. Known-exit
  lists are for documented behavior only. A draw at a node's first start or in the setup is
  made before the timelines part, the same in every timeline of a run: draw an operator's
  recovery at each start instead, or `s.snapshot_before_nodes = true` (each timeline starts the
  nodes and runs the setup itself, at the cost of their start).
- A node's start script is part of the system under test: start it as production does
  (Galera: the systemd unit's `galera_recovery` before each start, which Jepsen's wrapper and
  the official image leave out; without it a cluster that crashed whole re-forms with no state).
- Values a judge tells apart (queue messages, register writes for Elle) are unique across every
  driver start of a timeline: an id of 40 random bits or more per start, then a sequence
  (`(id << 12) | sequence`, under 2^52). 24 bits collided at ~1,700 starts (8% a timeline): two
  starts' same values read as a refused message dequeued (RabbitMQ, hunt run 1786), a record
  twice in its partition, or a loss hidden by its twin.
- Note each operation before sending it (Jepsen's invocations), then its outcome: the composer
  may end the driver phase and kill drivers mid-call, and an operation that applied but was
  noted only after its answer is neither acknowledged nor unknown (an etcd counter came out one
  over in 83 timelines). Invoked without an outcome counts as unknown.
- An operation whose outcome is unknown (no answer: a timeout, a dropped connection) may still
  apply at any later moment, after operations sent later (Jepsen's `info`: concurrent with
  everything after it). A request held behind a partition is delivered when it heals, by the
  kernel, after the client gave up (MongoDB, run 1567: a write of 2 applied after the same
  session's acknowledged 6). A judge of read-your-writes, monotonic reads or a final value
  accepts a lower value that is such a write's (sent, never acknowledged); otherwise it reports
  the network's doing as the system's.
- A connection that only reads (a watch, a subscription, a stream) needs TCP keepalive
  (`tcp.Options.keepalive_s`): a peer restarted while partitioned from the runner never says so
  (its FIN lost), and a driver that sends nothing waits for good on a half-open socket (a watch client,
  run 1566: watchers judged as not delivering). Request/response connections need none: their
  reads time out.
- Nodes start one after another, each once it is ready: make readiness something that comes up
  alone (Patroni waits for an etcd quorum before its REST API listens: ready on etcd's peer port,
  or pg1 waits forever for pg2). But where the next node must not start before this one joined
  (Cassandra: two joining at once choose the same tokens), be ready once joined, with time for
  it: `.ready = .{ .tcp = 9042, .timeout_s = 240 }` (60 s by default). Systems that take tens of seconds to recover (elections,
  leases, JVMs) need faults in bursts, `s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max =
  30_000 }`, or they never serve during a timeline; and their drivers need enough refused
  connections in a row to outlast a failover.
- Systems that order by wall clocks (hybrid logical clocks, Paxos ballots from timestamps,
  leases, TSOs): turn on `.faults.clock_skew` (one node's realtime clock skewed for a while),
  with `clock_skew_ms_max` below their documented maximum offset when their safety assumes
  one (YugabyteDB's, CockroachDB's 500 ms): past it they stop nodes or lose safety by design.
- `sdk.fault(.{ .kind = ..., .node = ... })` asks the fault injector, which the composer starts
  only when some node allows some fault kind: with none (every kind off), a request finds no
  reader and is dropped without a word (the e2e stale-pid scenario tested nothing until its node
  drew clock skews). Asked kinds need not be among the node's drawn ones.
- When the scenario learns which node matters most right now (a primary, a leader), aim the
  faults at it: `sdk.fault_aim(name)` (half the faults then involve it, decisions replays
  repeat; "" stops). examples/sql/append.zig's `node_names` does it for `primary_only` drivers.
  The aim moving is itself marked (a `sometimes` det-faults asserts), so the tree returns to
  just after leader changes.
- Mark the rare states worth building on with a `sometimes` (a recovery, a retry path, an
  outcome unknown): the tree returns to just after one first. Only states every run should
  reach go in the catalog (a literal message); one a system may never have takes
  `sdk.assert_computed(.sometimes, ...)`, or an unreached `sometimes` fails the run. An `always`
  never evaluated fails too (Antithesis's rule): one that only a profile reaches (Pulsar's
  "with deduplication on, ...", trial run 1706) is judged in every profile, true where it does
  not apply (`!deduplicating or twice == 0`), or is `always_or_unreachable`.
- Draw the system's own settings (FoundationDB's knobs): a node's `.knobs`, each a named set of
  choices of `NAME=value` environment entries (a knob's entry replaces the node's own of that
  name), drawn as the node starts, or once for the run with `.scope = .run` for settings every
  member must share (timeouts). Only what the system documents for production (never an unsafe
  mode): snapshot and compaction thresholds, protocol options (Raft's pre-vote), its own
  integrity checks (etcd's corruption-check feature gates: the system then judges itself). A
  system that reads flags only: a start script turning the variables into flags. Never also
  pass a knob's setting as a flag (etcd refuses an ETCD_ variable a flag shadows). Variable
  names stay shell names (a dotted property goes in the value: Kafka's
  `KAFKA_KNOB_SEGMENT=log.segment.bytes=1048576`, start.sh appending it). Check every choice
  against every release the knob's profiles run, natively: Kafka 4 refuses segments under
  1 MB (KIP-1030) that its 3.8 takes, so a 4.x broker drawing 256 KB never started (trial run
  1694). A setup-only run cannot show it when the nodes start in each timeline
  (`snapshot_before_nodes`); a trial of a few timelines does. See examples/etcd's
  `member_knobs`, examples/kafka's `broker_knobs`, examples/postgres's `postgres_knobs`.
- Give each profile an `explain` command when the system can turn its logs up at runtime
  (`profile.explain = "det-nodes exec <node> <set the log level>"`, ones restarts keep too):
  causality runs it in futures inside a failure's jump, and their logs show the mechanism
  (Redpanda's `rpk ... log-level set tx`, examples/kafka).
- Check what a system creates for itself in the infrastructure it is given (Kafka topics,
  buckets, streams): XTDB 2.2 makes its log topics with one replica (`NewTopic(topic, 1, 1)`, an
  operator's choice it only warns about), on which every broker fault read as XTDB's failure
  (trial xtdb-2: no commit under faults). Make them as production would, replicated, before the
  system starts (examples/xtdb/topics.clj), and say so in the README.
- A node's disk is the VM's memory (snapshots hold it): size what the system writes and keeps
  for long timelines (preallocated segments, retention, log files), or OOM kills end them
  (YugabyteDB's 64 MB WAL segments, preallocated per tablet: `--log_segment_size_mb 4`).
- The image's files all have time 0 in the guest (mkfs.erofs -T0, reproducible images): what
  compares times there sees every file as old. Clojure ignores AOT classes in a directory of the
  image for their sources in jars (Datalevin's servers compiled from source at every start,
  trial run 1101): jar them, a jar's entries carry their own times. Compile what must be newer
  during setup instead (a writable directory: `prepare` in examples/datalevin/start.sh). A JDK
  AOT cache or CDS archive of the classpath refuses a jar whose time changed since it was
  trained: `touch -d @0` the jars first (examples/datalevin/Dockerfile).
- The guest has one vCPU: every JVM a node starts shares it with the system's. A Clojure
  program's commands as JVMs of their own pay the client library's load at each driver start
  (a median 114.7 s of virtual time for one system's, 4.4 s for another's): run them warm,
  in the client node's REPL JVM (its launcher's `run` handed to sdk/clojure/warm-run), and open
  clients once in the program's `:warm`, shared by every command, so that a control plane down
  for minutes after a restart does not keep every driver from starting.
- Size background work to the test (Antithesis's "Optimizing"): work that happens at production
  sizes or periods never happens in a timeline of minutes and a few MB, and its bugs stay
  hidden. Lower the thresholds of splits, merges and rebalancing (ranges, tablets, regions,
  shards: TiKV regions of 5 keys, as Jepsen does), snapshots and log truncation (etcd every
  100 entries, rqlite's `snapshots` profile), compaction and flushes, heartbeats, leases and
  failure detectors (Patroni's ttl 15, Scylla's `phi_convict_threshold: 2`), and keep data
  small and synthetic. The run's efficiency line says when a system is slow: little idle time
  (something busy-waits or polls: a runtime's spin setting), clock reads per virtual second,
  and the busy node (CPU by node).

## Assertions in the service

Use the SDK of the service's language (`sdk/c`, `sdk/python`, `sdk/java` with the catalog agent,
`sdk/clojure`): assertions are cataloged as the code loads, so one that never runs is reported
too. Messages are literals: they are the property's identity.

## Build and run

Add the program to `build.zig`'s `programs`, then on the host with KVM:

```
zig build -Drelease
determinismo explore --kernel ... --initrd ... --program zig-out/bin/<name> \
  --scenario <scenario> --seed 1 --branches 32
```

Exit 0: all passed; 3: some failed (then use the `determinismo-debug` skill).
