# determinismo's Clojure client

serve's API from Clojure on the JVM, babashka or jank: one `.cljc` source, no dependencies
(java.net.http on the JVM and in babashka, curl through C++ on jank).

Everything the REPL can do, asked of the REPL itself (for a person at an editor and for an agent
at an nREPL alike):

```clojure
(require '[determinismo.help :refer [help]])
(help)                                  ; every function: its arguments, its first line
(help "moment")                         ; those whose name or documentation says it
(help 'determinismo.api/fork)           ; one, its whole documentation
```

`determinismo.api`: runs (start, stop, resume, wait), their timelines, properties, findings,
failures, triage report, what their nodes logged, learned ranges, activity, events (query, SQL),
replays, a node's file at a moment, the lines a timeline's events left out, new timelines from a
moment, a file put into a node at a moment (a patched binary, a config) with the timeline going
on from there, and the analyses of a failing timeline (causality, shrinking, explaining).

```clojure
(require '[determinismo.api :as api])
(api/runs)                                            ; [{:id 13 :state "failed" ...} ...]
(api/properties 13)
(api/sql 13 "SELECT count(*) AS n FROM events WHERE branch = 0")   ; [{:n 2741}]
(api/query 13 {:condition "event=fault" :branch 0 :limit 5})
(api/watched 13 "com.x.Raft.currentTerm")              ; a JVM field's stores, every timeline
                                                      ; (DETERMINISMO_WATCH: docs/SDKS.md)
(api/wait-run (:id (api/start-run {:program "..." :scenario "bank" :branches 16})))
(api/extract 13 {:branch 4 :at_vtime_ms 9000 :node "db-1" :path "/etc/db.conf"})   ; its text then
(api/extract-to 13 {:branch 4 :at_vtime_ms 9000 :node "db-1" :path "/data/db.bin"} "db.bin")
(api/recover 13 {:branch 4 :vtime_ns 9000000000})     ; lines its events left out near there
(api/fork 13 4 9000 16)                               ; 16 new timelines from timeline 4 at 9 s
(api/inject 13 {:branch 4 :at_vtime_ms 9000 :node "db-1" :path "/usr/bin/db" :from "db-patched"
                :mode "755" :exec "det-nodes kill db-1; det-nodes start db-1"
                :continue true})                      ; a fix tried there, the timeline going on
(api/shrink-start 13 {:branch 4 :property "..."})     ; the fewest faults the failure needs
(api/logged 13)                                       ; what the nodes logged, by template
```

A run's named draws (src/draws.zig: `knob.<name>`, a fault's parameters, `swarm.<name>`,
`sdk.decide`'s options, a workload's `random_below_named`), as the explorer answered them, from
runs recorded since 2026-11-15: a timeline's, a run's sets, and which values the timelines
failing a property share against the others (swarm testing's question).

```clojure
(api/draws 13 4)                                      ; [{:part "setup" :name "knob.mode" :value 2 ...} ...]
(api/draw-sets 13 "knob.")                            ; [{:name "knob.mode" :values [{:value 0 :timelines 5} ...]}]
(api/draw-split 13 "acknowledged writes survive")     ; {:failing 3 :passing 13 :labels [...]}
```

`determinismo.debug`: the debugger at a moment of a timeline (docs/DEBUGGING.md). A session of
serve's held at a moment; the machine stays stopped between calls, and stops change nothing of
the recorded history.

```clojure
(require '[determinismo.api :as api] '[determinismo.debug :as dbg])
(binding [api/*url* "http://127.0.0.1:7878"]          ; else $DETERMINISMO_URL (every namespace's)
  (let [s (dbg/open 13 {:branch 0 :at-vtime-ms 3000})]
    (dbg/regs s)                                      ; {:rip "0x..." :cr3 "0x..." ...}
    (dbg/translate s :current "0xffffffff824079c0")   ; 37779904 (jiffies)
    (dbg/mem s 37779904 8)                            ; [66 119 251 255 0 0 0 0]
    (dbg/poke s 37779904 [0 0 0 0])
    (dbg/break s "0xffffffff81b96960")                ; the kernel's schedule
    (dbg/continue s)                                  ; {:rip "0xffffffff81b96960" ...}
    (dbg/watch-values s "0xffffffff824079c0" 8 {:limit 3 :keep? even?})
                                                      ; jiffies' next even values, each a moment
    (dbg/watch-values s (dbg/symbol s "db-1" "counter") {:keep? #(> % 100)})
                                                      ; a node's variable by its name
    (dbg/watch-values s (dbg/symbol s :db-1 :stats {:field "latency.p99"}))
                                                      ; a field by its path, read as its type
    (dbg/calls s (dbg/symbol s "db-1" "handle_request") {:limit 5})
                                                      ; a function's calls, :args at each and
                                                      ; :params by name ({:name "fd" :value 5})
    (dbg/symbol-at 13 {:branch 4 :at-vtime-ms 2000} :db-1 :handle_request)
                                                      ; looked up in a session of its own: a session
                                                      ; given it runs no guest command, as recorded
    (dbg/frames s :db-1)                              ; at a stop in its process: its calls, named,
                                                      ; unwound by .eh_frame (:via :cfi), else frame
                                                      ; pointers, then the stack's scan
    (dbg/moment-when 13 4 #(pos? (dbg/value-of (dbg/mem % page 8) :u64)) {:from-ms 2000 :to-ms 3000})
                                                      ; the first moment a look holds, to the branch
    (dbg/across 13 "event=request_start" #(dbg/calls % (dbg/symbol % :db-1 :handle_request) {:limit 3})
                                                      ; the same look in each timeline the query keeps
    (dbg/step-branches s 1000)                        ; the registers 1000 branches on
    (dbg/sh s "det-nodes list")                       ; a guest command's output
    (dbg/node-sh s "db-1" "ls /data")                 ; a command inside a node, as it sees itself
    (dbg/node-sh s "raft-node-0" "kill -QUIT 1")      ; a Go node's goroutines, to its output
    (dbg/checkpoint s "loaded")                       ; {:name "loaded" :saved true ...}
    (dbg/close s)
    (dbg/resume 13 s "loaded")))                      ; a session back there, not from boot
```

`determinismo.lab`: a session's moment as a world to act in (clients/jank-viz draws it and acts
from its buttons). The world at the moment is derived from the timeline's own events and
`det-nodes list`: each node up, paused, down or halted, each link's directions cut, jammed,
clogged, slowed or degraded, the faults on with the time they have left, failed properties, the
test commands' last outcomes. Each action is a step of the session, so it is on its timeline.

```clojure
(require '[determinismo.lab :as lab])
(def s (lab/open! 13 {:branch 0 :at-vtime-ms 30000}))  ; a session, the lab on it
(lab/world)                                             ; {:nodes [...] :links [...] :faults [...] ...}
(lab/fault! s {:kind "partition_groups" :groups [["n1"] ["n2" "n3"]] :direction "outbound"
               :duration_ms 3000})                      ; det-faults inject, until it applied
(lab/advance! s 1000)                                   ; det:wait: what happened meanwhile
(lab/until! s "event=node_start details.node=n1")       ; det:until (60 s at most)
(lab/checkpoint! s "before")
(lab/compare! s {:kind "pause" :node "n2" :duration_ms 2000} {:ms 3000 :control true})
                                                        ; two futures of a checkpoint, without
                                                        ; and with the fault: what it changed
(lab/close! s)
```

`determinismo.lean`: a Lean replica's counterexample (sdk/lean) driven on a session: its fault
decisions as det-faults requests against the real nodes, the rest (message deliveries, ticks,
clients, the model's disk) listed as skipped.

```clojure
(require '[determinismo.lean :as lean])
(lean/load! "counterexamples/H1.tape.jsonl" {:nodes ["n1" "n2" "n3"]})  ; its story beside it named
(lean/next! s)                                          ; one fault, then on to the next one
(lean/drive! s)                                         ; the rest
(lean/plan (lean/read-tape path) ["n1" "n2" "n3"] nil {})  ; the plan alone, as data
```

`determinismo.tap`: what the client does, told to whoever listens (each call's kind and data:
`:session/open`, `:regs`, `:mem`, `:poke`, `:sh`, `:checkpoint`, `:query`, `:sql`, `:replay`,
`:run/start` ...),
for a tool that follows a REPL. clients/jank-viz is one: a window drawing the run's multiverse
and a card for each evaluation.

```clojure
(require '[determinismo.tap :as tap])
(tap/listen! (fn [kind data] (println kind (keys data))))
```

Addresses past 2^63 (the kernel's, 0xffffffff8...) are big integers in every dialect, jank's
too (`0xffffffff824079c0` reads as `18446744071599847872N`); the client takes them as numbers or
as `0x...` strings, and reads every integer exactly (a seed past 2^63 too).

On jank, integer `+` and `*` wrap at 32 bits when both operands fit in 32 bits (`(* 1000000
1000000)` is -727379968, `(+ 2000000000 2000000000)` is -294967296), and past 64 bits wrap
instead of throwing (`(+ 9223372036854775807 1)`); on the JVM and babashka they are exact or
throw. Code that runs on jank multiplies such values as big integers (`0N`) or doubles, as
clients/jank-viz does with nanoseconds.

A run replays with the explorer that recorded it: these answer in runs recorded since they exist
(2026-11-13); an older run's guest takes them for shell commands.

## Trying it

serve listens on 127.0.0.1:7878 on its host; from your machine, a tunnel:

    ssh -N -L 7878:127.0.0.1:7878 <user>@<host>

then, from this directory:

    bb -cp src your-script.clj                        # babashka
    clojure -M your-script.clj                        # the JVM (deps.edn: src)
    jank --module-path src run your-script.cljc       # jank

## Publishing

The sources are a library as they are (`src/determinismo/{debug,http,json}.cljc`, MIT). To
Clojars when wanted: a jar of `src` with a pom (group `io.github.<owner>`, artifact
`determinismo-client`), the maintainer's step.
