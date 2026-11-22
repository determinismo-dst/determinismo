# etcd-io/raft#558 made to happen with thread holds

[etcd-io/raft#558](https://github.com/etcd-io/raft/issues/558): a follower that crashes during a
joint configuration change, between writing the change's entries and writing its HardState, can
come back with both configuration entries above its commit index, stand in the old
configuration and win, while the rest of the cluster commits in the new one. Two replicas then
apply different entries at the same index.

`node/` is our own harness (MIT): a replicated log over go.etcd.io/raft/v3 at 99f9ffb (the
issue's commit, Apache-2.0), its entries and its HardState written as two separate synced writes,
entries first, as the library's README prescribes. Five nodes, voters {1,2,3} at the start. A
client API (a JSON object a line) proposes entries, makes a joint change, says a node's state and
the digest of an applied entry.

## Scenarios

- `joint_crash` (profile `holds`): the issue's triggers, each by a control. `det-nodes hold`
  stops a thread at a function's first instruction (ptrace and a breakpoint) until it is let go;
  here the follower's HardState write is held and the follower crashed there, at the one moment
  the issue needs. Every step is a `joint_stage` event; the roles and waits are named decisions.
  Found in every fresh timeline that crashed there (half of them do; the others are the walk's
  control), and in every timeline of a tree branching past the crash: the walk's first run
  failed "replicas agree on the entries they applied" in 1,433 of 1,433 timelines (the
  follower, crashed at its HardState write and elected in the old configuration, applied a
  different entry at index 7 than the nodes of the new one).
- `joint_blind`: the same system with faults drawn as in any hunt (power losses among them) and
  nothing steering toward the crash point: what blind exploration finds. A 12-hour run found the
  divergence at 2.85 hours (2,406 timelines, 109 VM-hours): a voter the change removes crashed
  44 ms after writing the change's last entry, its HardState's commit below the joint entry,
  came back in the old configuration, won a term with one other voter and committed an entry at
  an index the new configuration had committed another at. Its timeline replays exactly.
- `async_vote` (profile `async_writes_holds`): etcd-io/raft#551, a candidate's vote request
  leaving before its term and vote are written (the library's AsyncStorageWrites).

The `agree` command judges election safety ("at most one leader per term": each node keeps
the terms it led in a file of its own, read through the client API) and state machine safety
("replicas agree on the entries they applied"). Two leaders of one term can show without a
divergence: their first entries in the term are both empty, and the old configuration's leader
may stop before it sends others (raft panics when a follower's commit is past its log).

The `holds` profiles run the nodes with Go's collector off (GOGC=off, four Ps): a held thread
keeps its P, and a collection's stop-the-world would wait for it. The others run as production
does.

## Running it

    zig build etcd-raft-joint-test
    zig-out/bin/determinismo explore --program zig-out/bin/etcd-raft-joint-test \
      --profile holds --scenario joint_crash --branches 4 --memory-mib 3072

The e2e check `raft-558` runs the same and expects the divergence in every timeline whose walk
crashed the follower at its held write, and in none of the others: the walk draws its own
control (`joint.crash`), letting the held write go on in about half its timelines, which the
issue's rules keep safe.
