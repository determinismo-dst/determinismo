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
  strict serializability with real-time order only between operations that touch a key in common,
  the `ydb-serializable` model of YDB's team's Jepsen suite. That is stricter than "serializable,
  each key linearizable": each transaction takes effect at one point for all its keys, so a
  history whose transactions would need a different point per key fails here though that weaker
  reading allows it. A failure under this model is reported with that note. Its anomalies keep
  Elle's names: `G-single-item-realtime` is then per key.
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
of Elle ([determinismo-workloads' workloads/elle/lean](https://github.com/determinismo-dst/determinismo-workloads/tree/main/workloads/elle/lean),
its findings in UNREPORTED.md) and reproduced on Elle. Elle's own suite with them: 103 tests, its
failures only the expected outputs they change. `failure-to-observe-test` (now also the
G-single-realtime its history holds), `lost-update-test` (gains G-single-item, D1),
`g1c-multi-key-delete-test` (D21), `all-anomalies-test` and rw-register's `checker-test` (the new
`:fuzzy-read`, D6), `anomalies-prohibited-by-test` (the new `:garbage-read`, D8); list-append's
`checker-test` can't write its output file here, as on Elle as written.
- `closed_predicate.clj`: writes (`[:w k v]`) get write-write edges (`ww-graph` matched
  `:write`); `versions-after` keeps its unborn branch and `version<` orders `:elle/unborn` first,
  so a predicate anti-dependency on a key the init created is found and explained.
- `core.clj`, `txn.clj`: for models that prohibit G1a, the process order reaches a process's
  `:info` operation; for models that allow it, real time has no edges into `:info` completions
  (cycles that vanish when the operation aborted).
- `rw_register.clj`: `:info` writes are indexed (as a write an `:ok` read saw, for models that
  prohibit G1a), and a transaction order through an `:info` write keeps its neighbours' edge.

Round 3's (2026-11-25), the fixes its replica checked safe:
- `list_append.clj` (new here): a G-single through appends nobody read is found (D1); for models
  allowing G1a, `:info` appends aren't indexed as writes and failed ones are stepped over (D5 with
  D4), which also restores strong read uncommitted verdicts the D3 fix above lost (D23); a read of
  an element nobody appended is a `:garbage-read`, not a crash (D8).
- `rw_register.clj`: unread writes the same (D1); every external read counts, two values read
  for one key are a `:fuzzy-read` (D6); a read of the transaction's own later write is a
  `:future-read` (D7).
- `closed_predicate.clj`: a predicate read's rows are item reads (D21); explainers read only `:ok`
  operations' reads (D22). `txn.clj`: cycles mixing item and predicate anti-dependencies are
  G2-item or G-nonadjacent-item (D20).
- `consistency_model.clj` (new here): `:fuzzy-read` and `:garbage-read` proscribed where Adya's
  levels do.

Not taken: D12 (deterministic version order, but one verdict lost in 40,000), D2 (two models at
once: the service never sends two), D15 (jepsen.history, safe only compiled ahead of time).

The service itself, likewise: a read holding a value twice is dropped (not deduplicated) before
Elle judges the rest, `not` covers the duplicates too, and per key a predicate read reads every key.

The service keeps its version: a deploy rebuilds and restarts it when checkers/elle changed
(infra/host/elle-image.sh, which update.sh runs, with no check going).

The service's tests: `clojure -M:test` here.
