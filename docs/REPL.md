# Scenarios at the REPL

A test program in Clojure (sdk/clojure's `determinismo.workload`) can be developed against its
running system: connect CIDER (or Calva, Conjure, any nREPL client) to a REPL inside the guest,
write a service, its workload and its faults there, run them, fork the machine to see their
futures, and replay any of it. Each evaluation is a step of the guest's timeline, so a session
is a script that replays.

## Connect

A run of the program first (any run: its timelines are where sessions start), then a session on
one of them, held at a moment, with the proxy:

    python3 infra/host/nrepl-proxy.py --serve http://127.0.0.1:7878 --run <id> --node client

(the session at its timeline 0's first scenario command; `--branch`, `--at-ms` or `--until`
another moment).

It listens on 127.0.0.1:7888 and writes `.nrepl-port`: `M-x cider-connect` there (from a
machine other than the host, an ssh tunnel to serve's port first). Evaluation, `cider-load-file`,
completion and docs all run in the guest's JVM: about 10 ms a message on the host, 60-150 ms from
a laptop through a tunnel.

A program makes its REPL warm by making it its node's command, ready on its port, after
compiling itself (`prepare`): tests/repl/repl_test.clj's client, examples/datomic's. Sessions then
find it up, compiled, its middleware loaded.

## In the guest's REPL

`(require '[determinismo.workload :as w])`, then:

- the system: `(w/system)`; nodes by name (`client`, `peer`, ...);
- decisions and properties: `w/random-below`, `w/swarm-index`, `w/random-near`, `w/decide`, `w/always`, `w/sometimes`, ...;
- the other nodes, through the runner: `(w/node-exec :peer "hostname")`, `(w/node! :kill :peer)`,
  `(w/node! :crash :db)`, any command: `(w/runner ["det-nodes" "pause" "db"])`;
- faults: `(w/fault {:kind "partition" ...})`, `(w/stop-faults ms)`;
- the machine cloned where it stands: `(w/fork! 4)` answers 0 here and k in future k; the
  futures are a run of serve's, followed from the REPL itself with `(w/fork-runs <run>)` and
  `(w/run-state id)`, or outside with `POST /sessions/<n>/forks`;
- serve from inside: `(w/start-run! {...})`, `(w/run-state id)`, `(w/serve :get "/runs")`.

A fault kind of the program's own is a function in its `:custom-faults` (tests/repl's rolling
restart): the fault injector picks it with its own decisions and runs it in the program's node.

## From any Clojure REPL

`cider-jack-in` in a project with `sdk/clojure` on its classpath; `determinismo.session` drives
serve:

    (require '[determinismo.session :as s])
    (def session (s/open "http://127.0.0.1:7878" 12 {:branch 0 :at-ms 30000}))
    (s/start-repl session :client 7888)
    (s/eval session "(+ 1 2)")
    (s/steps session ["det:wait 500" "det-nodes exec client hostname"])  ; one round trip
    (s/end session)
    (s/watch "http://127.0.0.1:7878" (s/start-run "http://127.0.0.1:7878" {...}))
    (s/verdict (s/replay "http://127.0.0.1:7878" 438 {:branch 60 :at-ms 117000 :continue true
                                                      :steps [{:exec "det-nodes kill pdb"}]}))

A command of your own is a function of steps: `steps` sends them as one request.

## Replaying

A session is a timeline of its run (the open's `timeline`, the run's next number): its steps
with their moments and what came from outside (serve's replies to the guest, a relay's
connections) are on its tape. `POST /runs/<id>/replay` with that `branch` replays it, a query
with it finds its events, and a session opens at a moment inside it (docs/DEBUGGING.md, "A
session is a timeline").

## jank

jank's own nREPL server works the same way: the relay speaks nREPL to whatever serves it in a
node. examples/nrepl's `jank` profile makes it its node's command (`jank repl --port`, warm before
the snapshot; jank's startup is slow, so keep it warm), and

    python3 infra/host/nrepl-proxy.py --serve http://127.0.0.1:7878 --run <id> --node nrepl

connects CIDER to jank in the guest (the e2e `jank` check: `(+ 1 2)`, a function defined at the
REPL, an atom's state kept between evaluations). What jank's server lacks (examples/nrepl's
README): `interrupt`, output of concurrent evaluations (its capture races), non-ASCII source,
CIDER's middleware (completion and the inspector are thinner than the JVM's).

examples/jank-box3d is a whole jank project to work on this way: box3d (through
jank-lang/commons' box3d-sys), its test program in jank (`determinismo.workload`, sdk/jank),
and at its REPL `(require '[determinismo.core :as det])` for decisions, events, assertions and
faults inside the run (`--node box3d` for the proxy; its README).

## Other languages

libdeterminismo is the same for every language: its interface as data (libdeterminismo.json)
and as a C header (libdeterminismo.h). Clojure's bindings are made from the JSON as they load;
jank, C, C++ and Rust read the header. docs/SDKS.md has the details.
