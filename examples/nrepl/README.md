# nREPL

nREPL is the protocol Clojure editors speak. `nrepl_test.zig` drives a server with concurrent
clients (bencode over TCP, `client.zig`) under faults. It tests five servers:

- **nrepl/nrepl 1.8.0** (`Dockerfile`, `server/deps.edn`): profile `default`, scenario
  `sessions`. Its JVM runs our coverage agent on nREPL's code: a line first run is a new
  behavior the tree builds on.
- **jank 0.1's own server** (`Dockerfile.jank`): profile `jank`, scenario `jank`. jank is Clojure
  on LLVM, installed from jank's own repository; the package was built 2026-10-28, binary version
  `cf627abb`. Its scenario is the same without `interrupt`, an op jank's server does not have.
  Prebuilt: no coverage.
- **Babashka 1.13.229's own server** (`Dockerfile.babashka`, `bb nrepl-server`): profile
  `babashka`, scenario `sessions`. A native image: no coverage.
- **nbb 1.6.214** (ClojureScript on Node.js, `Dockerfile.nbb`) and **Basilisp 0.5.1** (Clojure
  on Python, `Dockerfile.basilisp`): profiles `nbb` and `basilisp`, scenario `basic` (`jank`'s:
  neither has an interrupt op). No coverage. Basilisp compiles its core at start (33 s natively).
  Completion and lookup go through the ops a server's `describe` offers, as editors pick them:
  nREPL's `completions` and `lookup`, or cider-nrepl's `complete` and `info`, the only ones
  Basilisp 0.5.1 has (it answers `unknown-op` to the others: hunt runs 1611 and 1635 failed both
  properties in every timeline that asked). On nbb, numbers are JavaScript doubles and
  `(+ 1 :a)`, `(quot 1 0)`, `(/ 1 0)` answer values: its operands stay below 2^51 and its failing
  forms are the ones that throw in ClojureScript (hunt run 1634 failed on both).

### nbb 1.6.214: known, all on nbb's tracker (hunt run 1634, 222 timelines)

- **The whole server dies when a client's connection breaks as it writes**, `Error: write EPIPE`
  as an unhandled `'error'` event (Node.js ends the process): `on-connect` listens to `data` and
  `close` on a client's socket, never to `error`. In 190 timelines ("no unexpected container
  exits"). nbb #335 (open since 2023, the same with `read ECONNRESET`), and still so on main.
- **Sessions share the namespace, `*1` and `*e`** (127 and 126 timelines: "a session keeps its
  namespace", "a session's *1 is its own", details naming another session's namespace): nbb #429
  and #418, fixed on main 2026-11-03, unreleased.
- **info answers empty lists for a symbol it doesn't find** (proof's `wire.field-types`, `ns is a
  list`): nbb #431; code that throws gets no `eval-error` status: #425. Both fixed on main
  2026-11-02/03, unreleased.

Profile `nbb-main` (`Dockerfile.nbb-main`): nbb at main's commit 60e141d (2026-11-03), built from
source by its own release task, with those fixes: what they leave, and what is new, under the
same drivers. #335's crash is still there (no fix on main). Trial run 1708 (2026-11-09, 2 timelines): #335's
EPIPE in timeline 0, and in timeline 1 the next finding.

### Found: one frame that is not a dict takes nbb's whole nREPL server down

In trial run 1708's timeline 1, nbb main's server died at 3.22 s on an exception thrown from its
socket's data handler, `Error: Vector's key for assoc must be a number` (a `PersistentVector`'s
assoc in nbb_nrepl_server.js's message handling): Node.js ends the process, every client's
session and REPL state gone. Reproduced outside determinismo (2026-11-09, podman on srv4, the
images' own servers): each of proof's 80 checks alone against a fresh server, and only
`robust.bad-frames` killed it; its transcript: "after a connection sent \"le\", the server took
no more connections". `le` is bencode's empty list, a frame that is not a request dict: nbb
decodes it to a vector and assocs a key into it. nREPL closes the connection it cannot read a
request from (server.clj) and goes on. Both nbb 1.6.214 (the release) and main at 60e141d die
the same way. Not on nbb's tracker (searched 2026-11-09; #335 is the EPIPE). Not reported.

### Found: nbb's `lookup` answers in `info`'s shape

Hunt run 1781 (profile `nbb-main`, 2026-11-10): "a definition looks up in another session" false
in all 34 timelines that asked, 8,698 times, never true, faults or not; "a definition completes
in another session" true every time. nbb's `describe` offers nREPL's `lookup` op, and its
handler (`handle-lookup`, nrepl_server.cljs, serving `info`, `lookup` and `eldoc` alike) answers
`lookup` with the symbol's fields at the top of the reply (`name`, `ns`, `arglists-str`), as
cider-nrepl's `info` does. nREPL's `lookup` returns them in an `info` map (its lookup middleware:
`{:status :done, :info ...}`, "A map of the symbol's info"), which Babashka's server does (run
1601: true). A client of nREPL's own op finds no `info` in nbb's answer. Main at 60e141d as
1.6.214. Not on nbb's tracker (searched 2026-11-10). Not reported.

## proof, nREPL's compatibility suite, under faults

[proof](https://github.com/nrepl/proof) (Bozhidar Batsov's, Apache-2.0, 2026) runs 80-odd checks
against a server the way clients would: the protocol, sessions, interrupts, stdin, what CIDER,
Calva, Conjure, vim-fireplace, REPLy and neorepl send, and every message's wire format. It runs
them one at a time from one client, no faults. Here it runs from a node of its own
(`Dockerfile.proof`, pinned to `e9e325a`), with its built-in profile for the server:

- once on the fresh server, in the setup: every check's verdict is the baseline (the server's
  known failures, by proof's judgment, are in it);
- by drawn groups of checks (`eval.*`, `session.*`, `interrupt.*`, `robust.*`, ... or all) as a
  driver beside ours, while faults land: its wire checks (`wire.*`: a message's status, payload,
  session, nothing after an error) must hold whatever happens, as a fault cannot change what the
  server writes; a frame cut off (`wire.bencode`, what a killed server leaves) and the other
  checks' failures are events (`proof_failed`), since faults fail them too;
- whole once faults stop: every check the fresh server passed must pass after the faults and the
  load (`a check proof passed on the fresh server passes once faults stop`), which catches what
  a timeline left broken (stuck sessions, leaked threads).

proof found nREPL 1.8.0's bugs where one client meets another's work: evaluations queued
behind an interrupted one dropped (#503, open), an interrupted evaluation's `done` sent to the
connection the interrupt came from (#498, fixed on master, unreleased), a session that stops
answering after its client left mid-evaluation (#509, open). Drivers build those shapes under
concurrency and faults, with sessions taken up from other connections (as editors reconnecting
do): `queue` (one to three evaluations queued behind a long one, interrupted from this connection
or from another) and `leave` (a client gone mid-evaluation, its session taken up, interrupted or
not, and evaluated in). A `done` that never comes is told from a fault: the connection is asked
`describe` outside the session every 5 s, and six answers over 30 s with the `done` still
missing is the server's drop.

Clients close their sessions on the way out, but one in eight leaves it open (as vim-fireplace
and REPLy do). nREPL 1.8.0 keeps a thread per session, and its sessions outlive their
connections: drivers that never closed theirs had it hold 4,734 threads at 150 s, 10,177 at 300 s
and 15,618 at 400 s, its JVM then killed for memory in a 4 GiB guest (trial run 1596). nREPL's
master (#512, merged 2026-11-05, unreleased) ends a session when its connection closes, "to
prevent session leakage when the client disconnects".

## Found: a request queued in a session whose client left mid-evaluation is never answered (nREPL 1.8.0, 2026-11-08)

- **Seen:** the first trial with the `leave` driver (run 1599, 4 timelines) failed "a request in a
  session whose client left mid-evaluation is answered" in 3: a client starts a 3 s evaluation
  and disconnects, another takes up the session and evaluates `(+ 20 22)` in it, and no reply
  ever comes, not even `done`, while the same connection answers `describe` for 30 s. Without an
  interrupt, 313 of 321 such requests went unanswered; with the second client interrupting the
  left evaluation first, 45 of 429.
- **Reproduced natively** (`leave-mid-eval/run.sh`, no faults): 5 of 5 unanswered; the controls,
  the first client staying connected, or the second evaluating after the left evaluation ended,
  5 of 5 answered.
- **The mechanism (1.8.0's session):** the left evaluation ends and its reply fails on the closed
  connection; the session's exec catches it and starts the session again (#489, "re-create
  persistent session thread on faulty exec thunks"), with a fresh queue, so what waited in the
  old one is gone. #503 is the same loss after an interrupt.
- **Upstream:** not in nREPL's issues (searched 2026-11-08: #503 is the interrupt's, #509 a
  thread an interrupt leaks, which says a disconnect without one is fine). On master the request
  is answered, `unknown-session`: #512 (2026-11-05, "end all transport sessions when transport
  closes") ends the session with its connection and reverts #489's restart. 1.8.0 is the latest
  release. Not reported.
- **The hunt** (run 1603, 15 min, 259 timelines): this finding in 107 timelines; #503 in 128,
  #498 in 125, #506 in 177 (below). 14 timelines ended with the server's JVM killed for memory
  (the sessions left open by one client in eight, and by the `leave` driver, are all kept), 10 of
  them failing "the server never evaluates again" after it: 1.8.0's sessions outliving their
  connections, which #512 ends on master.

## Rediscovered blind with proof's shapes (nREPL 1.8.0, trial run 1599)

The same trial failed, each in one timeline or two: "every evaluation queued behind an
interrupted one is answered" (#503, open), "an interrupted evaluation's done comes to its own
connection" with "a connection is answered nothing of another's requests" (#498, fixed on
master, unreleased), and "nothing answers a request after its done": an interrupted
evaluation's `InterruptedException` after its `done` (#506, open). proof's baseline on the fresh
server fails `interrupt.queued`, `interrupt.other-connection` and `robust.wrong-types` too: what
proof finds one request at a time, the drivers find under concurrency and faults.

The properties:

- `(+ a b)` answers a + b.
- `*1` right after it is a + b.
- Every answered request ends with `done`, and nothing answers it after.
- An evaluation that throws gets its error back, and its session evaluates on.
- A var defined in one session has its value in another, and completes and looks up there.
- After `(in-ns 'x)`, the session's next evaluation is in `x`.
- What an evaluation prints comes back to it, and nothing another evaluation printed.
- An interrupted evaluation ends interrupted or done.
- Evaluations queued behind an interrupted one are answered with their values; the interrupted
  one's `done` comes to its own connection, and another connection is answered nothing of it.
- A request in a session whose client left mid-evaluation is answered.
- After faults, a new session evaluates again.
- proof's wire checks hold under faults; once faults stop, every check proof passed on the fresh
  server passes.

```
determinismo explore ... --program zig-out/bin/nrepl-test --profile jank --scenario jank
```

## The first smoke (srv3, run 217, 2026-10-30)

Profile `jank`, 2 timelines of 37 s and 19 s. Every property held except "a session keeps its
namespace" (below), with no crash. jank's server idles most of the time: 91% of virtual time
was skipped, at 10 virtual seconds per wall second.

## The first hunt (srv3, run 235, 2026-10-30)

A tree, 1 h budget, seed 1. The plateau rule stopped it at the hour: 9,854 timelines, 77
behaviors, none reached by one timeline alone (Good-Turing's chance that the next finds a new
one: about 0). Two properties failed, both known from writing the workload: "a session keeps
its namespace" (7,150 timelines) and "an evaluation's output is its own" (3,875, the output
capture race below). No crash and no other failure: under these faults, sessions and
definitions held. The two forms that kill the server were left out of every jank timeline then
(below), which hid that crash; since 2026-11-06 half of jank's timelines meet them (drawn once
a timeline), where it fails the run. The server is the container's main process since then
(`jank-start.sh`): behind socat, its death would leave the container up, every connection
refused, the kernel's crash line the only sign. Checked on srv4: `(/ 1 0)` over nREPL now ends
the container (status 136, SIGFPE). Trial run 1236 (before it, both timelines drawing the
crashing forms) met no crash: its events show one failing form drawn in a whole timeline. The
faults ran continuously and the runner's link to the server was cut or lossy nearly all the time
(163 partitions and 291 degraded links in 120 s, 2,568 failed connections); since then they come
in bursts of up to 10 s with quiet stretches of up to 20 s, both scenarios.

## Found: every evaluation keeps memory jank never frees (jank 0.1, 2026-11-08)

Hunt run 1569 (`jank`, 111 timelines): "the kernel kills no process for lack of memory" failed
in 24 (and with them, as after the two crashing forms, "the server never evaluates again": the
node is gone), jank OOM-killed at about 1.8 GB of a 2 GB guest, 60 to 90 s in (4 of them in timelines
that never drew the two forms that kill the server). Its memory grew steadily, about 30 MiB a
second under the drivers (timeline 32: 299, 618, 922, 1,151, 1,436 and 1,670 MiB at ten-second
intervals), and never came back down.

Reproduced outside determinismo, with no faults: jank's nREPL server alone (the workload's image,
`jank 0.1-noble` from its PPA) and one client evaluating one form after another, jank's resident
memory read every 100 evaluations (`jank-memory/run.sh`). Each evaluated expression keeps memory
for good:

| Form, evaluated 400 to 600 times | Growth per evaluation |
|---|---|
| `(+ n 1)`, `n` different each time | 638 and 648 KiB (two runs) |
| `(+ 1 1)`, the same form each time | 338 KiB |
| `(shared-fn-k)`, a call of one of 64 defined functions | 115 KiB |
| `(defn shared-fn-k [] n)` over 64 names | 3 and 10 KiB |
| `(def shared-k n)` over 64 names | 2 KiB |

Linear throughout (203 to 577 MiB over 600 distinct sums), not a warm-up. Not nREPL's: a plain
`jank run` of `(dotimes [i 2000] (eval (list '+ i 1)))` went from 242 MB to 1.23 GB, steadily, so
jank's evaluation itself keeps the memory. An editor session of a
few thousand evaluations then holds gigabytes, and a server with 2 GB dies after about 3,000.
Clojure keeps one small class per evaluation; jank keeps a third to two-thirds of a megabyte per
expression, even one it evaluated before. The cause, in jank's source (main, read 2026-11-08): a top-level
form is analyzed, optimized and evaluated (`runtime/context_dynamic.cpp`, `eval_string`), and an
expression the optimizer turns native, `(+ 5 1)` among them, is wrapped in a function of its own
name (`evaluate.cpp`'s `wrap_expression`: `user$cpp_conversion_1_0`, then `_5_0` for the next,
as `JANK_PRINT_CODEGEN=1` prints) whose C++ source is compiled through clang's incremental
interpreter (`jit/processor_dynamic.cpp`, `eval_string` → `ParseAndExecute`). clang's interpreter
keeps every input it compiled (its AST and its code); jank never undoes one, nor removes what
`load_ir_module` adds (no resource tracker), so each evaluation's compilation stays for good. Not in jank's tracker (searched: memory, leak, JIT
memory, OOM, redefine). Not reported.

## Found: jank's integer arithmetic silently wraps at 32 bits (jank 0.1, 2026-11-10)

Met at a REPL session in the guest (phoenixNAP s1.c1.small, run 12's timeline 0, the session
timing for docs/GETTING_STARTED.md's development loop): `(reduce + (range 1000000))` answered
1783293664, where Clojure answers 499999500000, the true sum (1783293664 is it modulo 2^32).
Reproduced natively with `jank run` on the same image (binary `cf627abb`, built 2026-10-28),
no determinismo involved:

```
(reduce + (range 1000000))   ; 1783293664       (Clojure: 499999500000)
(+ 2147483647 1)             ; -2147483648      (Clojure: 2147483648)
(* 100000 100000)            ; 1410065408       (Clojure: 10000000000)
(type (+ 2147483647 1))      ; small_integer    (Clojure: java.lang.Long)
```

Clojure's integers are 64-bit and its `+`, `*` throw on overflow rather than answer a wrong
number. jank's runtime looks right on main: `runtime/core/math.cpp` adds two integers into an
i64 with `__builtin_add_overflow` (a big integer past it), and `make_box(i64)` keeps a value
outside i32's range as an `obj::integer` (`core/make_box.hpp`); `small_integer` holds an i32.
So the wrap is in a path that bypasses them, most likely compiled code adding tagged small
integers as i32 (not traced yet). No commit since the binary's build touches arithmetic (main's
five commits to 2026-11-01). Not on jank's tracker (searched overflow, small_integer, integer
overflow, 32-bit, int64, wrap; 2026-11-10). Not reported.

## jank 0.1, met while writing the workload (2026-10-30)

Each one was checked against jank's tracker; none was reported upstream.

### Two evaluations kill the whole server

When one of these runs over nREPL, every connected editor loses the server.

- **Integer division by zero dies of SIGFPE.** `(/ 1 0)` and `(/ 0 0)` kill the process. So do
  `apply`, a function, `let` and runtime counts (`(/ 1 (count []))`). `(quot 1 0)`, `(rem 1 0)`,
  `(mod 5 0)` and `(/ 1N 0)` throw "Division by zero is not permitted." as they should.
  - The cause is the known regression of jank#629: `/` on two integers divides natively again,
    so `(/ 2 4)` is `0`, not `1/2`. That report names only the truncation.
- **A stack overflow dies of SIGSEGV, even inside `try`.** For example,
  `((fn deep [n] (if (zero? n) 0 (inc (deep (dec n))))) 100000)`. Clojure throws a
  StackOverflowError the program can catch. Not in the tracker.

The workload's jank timelines leave these two forms out. Otherwise every timeline would end at
them.

### Concurrent evaluations swap each other's output

The probe: three rounds of eight clients at once, each evaluation printing its own mark twice.

- **Most evaluations got the wrong output.** Only 4 of 24 got exactly their two marks. The rest
  got none (client 2 of round 1), one, or other evaluations' marks: client 1 of round 1 got
  marks 12 and 17 beside one of its own.
- **The server's stdout ends up in a deleted file.** After the rounds, its fd 1 pointed at
  `/tmp/jank-nrepl-WVmQWk (deleted)`, so whatever it prints from then on is lost.
- **The cause** is `capture.jank`. To capture an evaluation's output, it points the process's
  own stdout and stderr at a temp file of the evaluation's own (`dup` the fd, then `dup2` the
  temp file over it), and restores the saved fd when the evaluation ends. Two evaluations
  interleave those swaps. One saves the other's temp file as "the original" and restores it
  last.

Concurrent evaluations became possible when jank#1022 was fixed (2026-10-09). This race is not
in the tracker. The workload's `print` driver checks it ("output is its own").

### Non-ASCII source needs a UTF-8 locale

Started without one (the C or POSIX locale: most containers' and services' default, this
image's included), jank cannot read any source with a character outside ASCII, from a file or
over nREPL:

- `"é"` and `(count "日本語")` fail with `lex/unterminated-string`. A comment `;; é` or a symbol
  `é` fails with "The Unicode character literal is unfinished".
- An editor's evaluation containing such a character gets that error back.
- With `LANG=C.UTF-8` the same source reads fine, and the replies' bencode lengths are right
  (in bytes).
- jank#277 ("unicode string does not work", `"你好"` unterminated) was closed in 2025. Its fix
  holds only under a UTF-8 locale. The locale dependence is not in the tracker.

### Wrong answers

- **`count` of a string counts bytes.** `(count "日本語")` is `9`; Clojure's is `3`. Not in the
  tracker.

- **Out-of-range casts answer `-9223372036854775808`.** This happens for `(long ##Inf)` and
  `(int 1e20)`: C++'s conversion is undefined. Clojure throws "Value out of range for long".
  Not in the tracker.

### Sessions don't hold state

A session is a bare id: `clone` answers `(random-uuid)`.

- **The namespace is not kept.** After `(in-ns 'x)`, whose reply's ns is `x`, the session's
  next evaluation is in `user`. Every request without an `ns` field evaluates in `user`.
  Clojure's server keeps the session in `x`. Not in the tracker.
- **`*1` belongs to the connection, not the session.** It is the thread's binding, and each
  connection has its own thread. On the same connection `*1` is right; a request of the same
  session on another connection reads `nil`.

### Protocol details

- **`completions` and `lookup` need `ns`.** Without it, `completions` answers
  `namespace-not-found` and `lookup` answers an error. nREPL's ops reference makes `ns` optional,
  defaulting to `*ns*`. Editors send it, and so does the workload.
- **Empty messages.** Each part of an evaluation's reply that is `nil` (no output, no error)
  goes out as a message with only an id and a session, before the value.
- **Unsorted keys.** Reply keys are not in sorted order (jank#1088, open).
