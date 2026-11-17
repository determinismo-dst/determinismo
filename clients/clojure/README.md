# determinismo's Clojure client

serve's API from Clojure on the JVM, babashka or jank: one `.cljc` source, no dependencies
(java.net.http on the JVM and in babashka, curl through C++ on jank).

`determinismo.api`: runs (start, stop, wait), their timelines, properties and findings, events
(query, SQL), replays and causality analyses.

```clojure
(require '[determinismo.api :as api])
(api/runs)                                            ; [{:id 13 :state "failed" ...} ...]
(api/properties 13)
(api/sql 13 "SELECT count(*) AS n FROM events WHERE branch = 0")   ; [{:n 2741}]
(api/query 13 {:condition "event=fault" :branch 0 :limit 5})
(api/wait-run (:id (api/start-run {:program "..." :scenario "bank" :branches 16})))
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
(require '[determinismo.debug :as dbg])
(binding [dbg/*url* "http://127.0.0.1:7878"]          ; else $DETERMINISMO_URL
  (let [s (dbg/open 13 {:branch 0 :at-vtime-ms 3000})]
    (dbg/regs s)                                      ; {:rip "0x..." :cr3 "0x..." ...}
    (dbg/translate s :current "0xffffffff824079c0")   ; 37779904 (jiffies)
    (dbg/mem s 37779904 8)                            ; [66 119 251 255 0 0 0 0]
    (dbg/poke s 37779904 [0 0 0 0])
    (dbg/break s "0xffffffff81b96960")                ; the kernel's schedule
    (dbg/continue s)                                  ; {:rip "0xffffffff81b96960" ...}
    (dbg/step-branches s 1000)                        ; the registers 1000 branches on
    (dbg/sh s "det-nodes list")                       ; a guest command's output
    (dbg/checkpoint s "loaded")                       ; {:name "loaded" :saved true ...}
    (dbg/close s)
    (dbg/resume 13 s "loaded")))                      ; a session back there, not from boot
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
