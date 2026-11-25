# Elle, on the host

[Elle](https://github.com/jepsen-io/elle) (Jepsen's checker, EPL-2.0) infers the dependency graph
of a transactional history and reports every anomaly it finds: G0, G1a/b/c, G-single, G2, and
with real-time order, violations of strict serializability. To a test program it is a library:
a host check (ARCHITECTURE.md §10.4) from `sdk.elle`, run on every timeline's history.

```zig
// The program's checks: Elle on every timeline's history (a model per scenario if need be).
return System.main(init, .{ .describe = describe, .scenarios = .{ ... },
    .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) } });

// A driver: each operation as it happens (sdk.elle.History records them for the check).
try history.invoke(arena, process, &asked);
try history.ok(arena, process, &done); // Or fail, or info.
```

Under it, Elle (Clojure, on the JVM) runs as one warm service per host, on 127.0.0.1:7700, built
from this directory and started by the first check that needs it: a JVM per check would cost
more than the check. The check posts the timeline's history to it and asserts the verdict. The
history is JSON lines, in the order operations happened:

```
POST /check?model=list-append&consistency=strict-serializable

{"process": 7, "type": "invoke", "f": "txn", "value": [["append", 3, 17], ["r", 4, null]]}
{"process": 7, "type": "ok", "f": "txn", "value": [["append", 3, 17], ["r", 4, [2, 9]]]}
```

- `type`: `invoke`, then the same process's `ok` (reads filled in), `fail` (it did not happen)
  or `info` (unknown: the process then goes on as another, Elle's one-operation-at-a-time rule).
  An invocation never completed (its driver stopped mid-call) is closed as `info`.
- `model`: `list-append` (`append k v` with values unique per key, `r k [v ...]`),
  `rw-register` (`w k v`, `r k v`) or `closed-predicate` (Elle's `elle.closed-predicate`, for
  jepsen-io/mysql's closed-predicate test: first an operation of `f` `init` whose value is
  `[["init", k, v], ...]`, the universe's first state; then transactions of `insert k v`,
  `w k v`, `delete k null`, `r k v-or-null` and `rp predicate rows`, a predicate `"true"`,
  `["=", a]` or `["mod", a, b]` and rows `[[k, v], ...]`). `consistency`: any of Elle's models (`strict-serializable`,
  `serializable`, `snapshot-isolation`, `read-committed`, ...), or `strict-serializable-per-key`:
  strict serializability with real-time order only between operations that touch a key in common
  (serializable, each key linearizable). That is YDB's claim, the `ydb-serializable` model of its
  team's Jepsen suite. Its anomalies keep Elle's names: `G-single-item-realtime` is then per key.
  Elle's real-time graph is replaced JVM-wide while such a check runs, so it runs alone.
- `linearizable_keys=true` (rw-register): Elle's `:linearizable-keys?`, each key's version
  order inferred from real time, for a system that claims each key linearizable. Without it
  Elle cannot order two blind writes of a key: two reads after both, answering one and then the
  other, pass. With it they are `cyclic-versions`.
- The answer: `{"valid": true | false | "unknown", "anomaly_types": [...], "not": [...], "ops": n,
  "anomalies": "..."}` (the anomalies as Elle prints them, cut short).

Since the history is recorded inside the timeline, an anomaly replays exactly, to the moment of
every operation in its cycle. Used by `examples/etcd` and `examples/postgres`.

Three things the image works around: a JVM that sees one CPU (as in a guest, or a host pinned to
one) sizes its pools at one thread, with which Elle deadlocks (its history folds wait on tasks
queued to the same pool), even on an empty history, so the JVM runs with
`-XX:ActiveProcessorCount=16` (16 histories checked at once, `-Xmx8g`);
rhizome (Elle's Graphviz renderer) sets Swing up as it loads, which fails on a headless JVM, so
`src/rhizome/viz.clj` stands in for it (Elle draws only into a `:directory`, never given here);
and Elle 0.2.8's `elle.txn` loads unilog while declaring it for its dev profile only, so
`deps.edn` adds it.

## Elle, patched

`src/elle/` holds Elle 0.2.8 namespaces with fixes, loaded ahead of Elle's jar (`:paths` come
first), each under Elle's license (EPL-2.0, `src/elle/LICENSE`). All were found by a Lean replica
of Elle and reproduced on Elle; Elle's own test suite passes with them, except
`failure-to-observe-test`, which now also reports the G-single-realtime its history holds.
- `closed_predicate.clj`: writes (`[:w k v]`) get write-write edges (`ww-graph` matched
  `:write`); `versions-after` keeps its unborn branch and `version<` orders `:elle/unborn` first,
  so a predicate anti-dependency on a key the init created is found and explained.
- `core.clj`, `txn.clj`: for models that prohibit G1a, the process order reaches a process's
  `:info` operation; for models that allow it, real time has no edges into `:info` completions
  (cycles that vanish when the operation aborted).
- `rw_register.clj`: `:info` writes are indexed (as a write an `:ok` read saw, for models that
  prohibit G1a), and a transaction order through an `:info` write keeps its neighbours' edge.

The service itself, likewise: a read holding a value twice is dropped (not deduplicated) before
Elle judges the rest, `not` covers the duplicates too, and per key a predicate read reads every key.

The service keeps its version: rebuild and restart it by hand on each host
(`podman build -t determinismo-elle -f checkers/elle/Dockerfile .`, `podman rm -f
determinismo-elle`, `podman run -d --name determinismo-elle --network host determinismo-elle`)
with no check running.

The service's tests: `clojure -M:test` here.
