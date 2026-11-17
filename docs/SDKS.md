# SDKs

A program under test reports properties and draws randomness through an SDK: one per language,
the same capabilities in each, in that language's idiom.

| SDK | Where | How it is used |
|---|---|---|
| Zig | `sdk/zig/determinismo.zig` | the `determinismo` module (workloads, test programs) |
| C, C++ | `sdk/c/determinismo.h` | one header: `#define DETERMINISMO_IMPLEMENTATION` in one file |
| Python | `sdk/python/determinismo.py` | one file, standard library only |
| Java | `sdk/java/Determinismo.java` | one class; the catalog agent `DeterminismoCatalog` (`-javaagent`) |
| Clojure | `sdk/clojure/determinismo.clj` | wraps the Java SDK; assertions are macros |
| JavaScript, TypeScript | `sdk/javascript/` | one file for Node.js 18+, types in `determinismo.d.ts` |
| Rust | `sdk/rust/` | the crate `determinismo` (`serde_json` details) |
| Go | `sdk/go/` | the package `github.com/determinismo-dst/determinismo/sdk/go`; its catalog from `go generate` (`cmd/determinismo-catalog`) |
| .NET (C#, F#, VB) | `sdk/dotnet/Determinismo.cs` | one file (.NET 8+); its catalog from `dotnet run --project sdk/dotnet/catalog -- <project>` (a module initializer) |

## What every SDK has

| Capability | Zig | C | Python | Java | Clojure | JavaScript | Rust | Go | .NET |
|---|---|---|---|---|---|---|---|---|---|
| Random bytes, u64, below n | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Random choice | `random_choice` | (`det_random_below`) | `random_choice` | `randomChoice` | `choice` | `randomChoice` | `random_choice` | `RandomChoice` | `RandomChoice` |
| Swarm choice (an operation drawn among those this timeline keeps, weighted, in runs: `/opt/determinismo/swarm-seed`, the composer's; the table by FNV-1a and SplitMix64, test vectors in the Zig SDK) | `swarm_choice`, `swarm_index` (libdeterminismo: `det_swarm_index`) | `det_swarm_index` | `swarm_choice`, `swarm_index` | `swarmChoice`, `swarmIndex` | `swarm-choice`, `swarm-index` | `swarmChoice`, `swarmIndex` | `swarm_choice`, `swarm_index` | `SwarmChoice`, `SwarmIndex` | `Random.SwarmChoice`, `Random.SwarmIndex` |
| Open-loop load (requests at a rate that does not wait for answers, each client retrying by a policy drawn per timeline; goodput per second and a recovery judgment: metastable failures) | `open_loop.run`, `open_loop.Load.draw` | — | — | — | — | — | — | — | — |
| Draws around a declared limit (half uniform, half its edges: 0, 1, limit - 1, limit, limit + 1, twice; named decisions) | `random_near` | `det_random_near` | `random_near` | `randomNear` | `random-near` | `randomNear` | `random_near` | `RandomNear` | `Random.RandomNear` |
| Random float in [0, 1) | `random_float` | `det_random` | `random_float` | `random` | `random-float` | `random` | `random` | `Random` | `RandomFloat` |
| Random choice of no items | asserts (a precondition) | | `None` | `null` | `nil` | `undefined` | `None` | the zero value | `default` |
| A generator drawing from the platform | `rng` (std.Random) | `determinismo::random_engine` (C++) | `rng` (random.Random) | `rng` (java.util.Random) | `rng` | `rng` | `rng` (RngCore) | `Source()` (math/rand/v2) | `Rng`, `AntithesisRandom` (System.Random) |
| A generator seeded once | `prng` | `det_prng`, `prng_engine` (C++) | `prng` | `prng` | `prng` | `prng` | `prng` (RngCore) | `Prng()` (math/rand/v2) | `Prng` (System.Random) |
| Named decisions | `decide`, `random_below_named` | `det_decide`, `det_random_below_named` | ✓ | ✓ | ✓ | `decide`, `randomBelowNamed` | ✓ | `Decide`, `RandomBelowNamed` | `Decide`, `RandomBelowNamed` |
| Buggify, and its pauses | `buggify`, `buggify_pause` | `det_buggify`, `det_buggify_pause` | ✓ | `buggify`, `buggifyPause` | ✓ | `buggify`, `buggifyPause` | ✓ | `Buggify`, `BuggifyPause` | `Buggify`, `BuggifyPause` |
| always, always_or_unreachable, sometimes, reachable, unreachable | ✓ | `DET_*` macros | ✓ | ✓ | macros | ✓ | macros | ✓ | ✓ |
| The assertion's place in the code | debug info | `__FILE__`, `__LINE__` | the frame | the stack | the stack | the stack | `file!`, `line!`, `column!` | `runtime.Caller` | caller attributes |
| Guidance comparisons (8) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| always_some, sometimes_all | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`NamedBool`) | ✓ |
| Every evaluation an event, or first pass and first failure | `assertion_events` | `det_first_pass_first_failure` | `assertion_events` | `firstPassFirstFailure` | `first-pass-first-failure!` | `setAssertionEvents` | `set_assertion_events` | `SetAssertionEvents` | `Assert.FirstPassFirstFailure` |
| The catalog, announced before assertions run | det_catalog section | det_catalog section | source scan | class scan (agent) | macro expansion | source scan (CommonJS) | det_catalog section | generated `init` (`go generate`) | generated module initializer |
| Declare one at run time | `declare` | `det_declare` | `declare` | `declare` | (the macros) | `declare` | `declare` | `Declare` | `Catalog.Declare` |
| List the catalog | `catalog_assertions`, `catalog_write` | `det_catalog_write` | `catalog_assertions`, `catalog_write`; a source tree's, `catalog_tree` or `python3 determinismo.py catalog <dir>` | `catalogAssertions`, `catalogWrite` | `catalog-assertions`, `catalog-write` | `catalogAssertions`, `catalogWrite` | `catalog::assertions`, `catalog::write` | `CatalogAssertions`, `CatalogWrite` | `Catalog.Assertions`, `Catalog.Write` |
| setup_complete, event | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Raw output (any JSON object) | `output` | `det_output` | `output` | `output` | `output` | `output` | `output` | `Output` | `Lifecycle.Output` |
| Quiet periods, faults from the scenario | `stop_faults` (Zig: and `progress_while_quiet`, progress in a quiet period as a property), `fault` | ✓ | ✓ | ✓ | ✓ | `stopFaults`, `fault` | ✓ | `StopFaults`, `Fault` | `Lifecycle.StopFaults`, `Lifecycle.Fault` |
| Faults aimed at a node (half then involve it) | `fault_aim` | `det_fault_aim` | `fault_aim` | `faultAim` | `fault-aim` | `faultAim` | `fault_aim` | `FaultAim` | `Lifecycle.FaultAim` |
| Code coverage for strategies | trace-pc-guard | trace-pc-guard (source lines with the binary in /symbols) | sys.monitoring | the coverage agent | (Java's) | V8 precise coverage | trace-pc-guard (feature `coverage`; source lines with the binary in /symbols) | `determinismo-toolexec` (`go build -toolexec`: every block, no change to the code or go.mod) | (not yet) |
| Outside determinismo: local output file, else nothing (as Antithesis's) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Outside determinismo (a local run, a unit test), randomness comes from the OS and events go to
the file `DETERMINISMO_SDK_LOCAL_OUTPUT` names (Antithesis's `ANTITHESIS_SDK_LOCAL_OUTPUT` too), one
JSON object a line, else nowhere: Antithesis's default outside Antithesis (its SDKs' "SDK
runtime modes": assertions still evaluate their arguments, nothing is written), so a program
that reads its own stderr, or a production log, sees nothing of ours. Buggify points are always
false there, and nothing is announced; the catalog still lists.

Code coverage, for strategies that keep timelines reaching new code: C and Zig with
`-fsanitize-coverage=trace-pc-guard` (`sanitize_coverage_trace_pc_guard`); Rust with the
feature `coverage` and `RUSTFLAGS="-C passes=sancov-module -C llvm-args=-sanitizer-coverage-level=3
-C llvm-args=-sanitizer-coverage-trace-pc-guard"`, building with `--target <triple>`; Python
(3.12+) with `coverage_start()`, or unchanged with `python3 -m determinismo run <script> [argument]...` (its directory's code, or the node's coverage set; Antithesis's `python -m antithesis`); the JVM with nothing to do: determinismo puts its coverage agent on every node's `JAVA_TOOL_OPTIONS` (JDK 24+; every class but the JDK's, narrowed by the node's coverage set or a program's own `-javaagent:determinismo-coverage.jar=<prefixes>`; an older JVM runs uninstrumented and says so on standard error), as Antithesis instruments the JVM on its side; Node.js with `coverageStart()`;
Go with `GOFLAGS=-toolexec=determinismo-toolexec DETERMINISMO_SDK_DIR=<sdk/go> go build`
(`go install ./cmd/determinismo-toolexec` in sdk/go; every package but the standard library's,
or those `DETERMINISMO_INSTRUMENT` names by import path prefix: each block calls
`coverage.Block` on its own first line, so line numbers stay the program's); .NET after its
build, with `determinismo-dotnet-instrument [--include <path prefix>] <assembly.dll>`
(`dotnet publish sdk/dotnet/instrument`; Mono.Cecil): an assembly with `Determinismo.cs`
compiled in and its portable PDB beside it, rewritten so each statement (sequence point) calls
`Coverage.Point` first. The BEAM (Erlang, Elixir; OTP 27+) with nothing compiled into the
program: `sdk/erlang/det_cover_recompile.erl` recompiles a release's modules from their own
abstract code with `line_coverage` at image build time (its `main([Prefixes, Ebin...])`, run
with the image's own `erl`), and the node starts with `+JPcover line_counters -pa <dir> -s
det_cover`, the emulator counting each line and `det_cover` reporting each line's first hit
every virtual second (the node's coverage set: module name prefixes; examples/rabbitmq's
Dockerfile.4.4 and examples/couchdb's). No thread pausing there yet: the BEAM schedules its own
processes.
Each edge, line or block reports itself once: in C, C++, Rust, Zig and Go the first time the
timeline runs it (a bitmap per module or binary in /opt/determinismo/coverage, shared by every
process of every node: a node restarted reports nothing again), on the JVM, Python and Node.js
the first time a process runs it. Every pass through one is where thread pausing
pauses threads (docs/ANTITHESIS.md): instrumenting is all it needs. Node.js's coverage is counted
(V8's, read later): there `coverageStart` pauses through the inspector, a helper thread setting
the stretch's slow points as breakpoints in the main thread and every worker under coverage (a
CommonJS file's set before a worker runs it; an ES module's once a thread parsed it). Native code
(C, C++, Rust) whose unstripped binary is in the image's `/symbols` reports the source lines of
its edges, for targeted runs (`--changed`) and for reading what ran before a crash; a node given
as a binary (`.binary`) has its table made with its disk, nothing to place: keep the debug information (`-g`; for Rust, a
release profile with `debug = true` and `strip = false`: Cargo strips it by default since 1.77,
whatever `RUSTFLAGS` ask). Zig programs report their edges' lines from their own debug
information wherever they run (not stripped: Zig keeps it but in ReleaseSmall).

Branch directions: each side of a branch is a block of its own (Go: `determinismo-toolexec`
gives an `if` without an `else` one, on its body's closing line, so the direction not taken is a
behavior too; the JVM: each side of a forward conditional branch probes as a block, a thread
pausing point). How rarely a direction is reached is the explorer's to weigh, across the run's
timelines: the archive returns to a behavior in proportion to how few timelines reached it. The
per-process 1,000-to-1 `rare line` events copied from
Antithesis's example are gone (the rare-branch A/B, 2026-11-10: no large effect on coverage, fewer
known bugs found).

What of a node is covered is a set, given where the system is described, the test program's
profile, at no change to the image (Antithesis-built projects included: libvoidstar applies it):

```zig
profile.node(.broker, .{
    .build = .{ .context = ".", .dockerfile = "Dockerfile" },
    .coverage = .{
        .include = &.{ "org.apache.kafka.raft", "kafka.server" }, // none: everything instrumented
        .exclude = &.{"kafka.server.metadata"},
    },
});
```

A name is in the set when an `include` prefix starts it (or none is given) and no `exclude`
prefix does; the names are each language's own: Java classes, Go package import paths, Python
file names, and for C, C++, Rust and Zig source files (an edge whose source line is unknown has
the empty name: in the set only without includes). What the set leaves out reports nothing and is
no point for thread pausing. The node's processes get it as `DETERMINISMO_COVERAGE`
(`include,...,-exclude,...`, which a Compose project sets in a service's `environment`), and its
image's build as a build argument of that name: Go's `determinismo-toolexec` reads it (declare
`ARG DETERMINISMO_COVERAGE`), so a package left out is not instrumented at all, at no cost. Elsewhere
an excluded edge or line still calls the SDK once, which then never reports or pauses it: to take
a part's cost out entirely, leave it out of the build: C and C++ through `sdk/c/coverage-flags.sh`,
which turns the build argument into clang's allowlist and ignorelist (`examples/galera`).
The JVM agent given no prefixes instruments every class but the JDK's that the set holds; given
prefixes, those the set also holds. `.build.args` passes other build arguments (`NAME=value`).
A run can replace every node's set (`explore --coverage <set>`, serve's `coverage`), and
`--coverage off` covers nothing on the same build: what the instrumentation costs, measured.

On the JVM the agent also reports a program's states (SGFuzz's: a store of one of its own enum
constants to a field, outside initializers, says its transition once, `state <class>.<field>:
OLD -> NEW`), and makes them crash points (CrashTuner, SOSP 2019): one stretch of two seconds in
eight (a named decision, `crash points`), one transition in four is a point, and the first a
thread reaches asks the fault injector to crash its node there (`det-faults crash-point`), the
thread waiting for it before the store or just after (drawn). The injector grants it as one of
the node's crash faults the swarm keeps now (a kill or a power loss: `why: crash_point`), outside
quiet periods; `crash_point` events say each request's outcome (a request the injector would
refuse, in a quiet period or for a node whose crash faults the swarm left out, is refused by
`det-faults` at once from `/opt/determinismo/crash-points`, the thread going on). Stores to fields whose names say
they hold the node's view of the cluster (a word of `leader`, `epoch`, `term`, `session`,
`member`, `owner`, `coordinator`, `master`, `primary`, `quorum`, `lease`, `zxid`, `generation`,
`peer`, or its plural: `currentTerm`, `leader_id`; CrashTuner's meta-info) are points the same
way, whatever their type. `DETERMINISMO_CRASH_POINTS` in a
node's environment changes the one in eight (`0`: none). Nodes know their own name as
`DETERMINISMO_NODE`.

Any program can mark its own: `sdk.crash_point(name)` (Zig; Python's `crash_point(name)`; Go's `CrashPoint(name)`; C's `det_crash_point(name)`; Rust's `crash_point(name)`; .NET's `Lifecycle.CrashPoint(name)`; JavaScript's
`crashPoint(name)`;
`det_crash_point` in libdeterminismo, for Clojure, jank and other FFI callers) where a crash would test something (the
node just changed its view of the cluster, a record is half written). Inside determinismo and in
a node, a point is armed one two-second stretch in eight (a named decision, `crash point
<name>`), and its first evaluation then asks the injector to crash its node and waits for it, as
the agent's points do; the runner's processes (drivers) crash nothing.

## Doomed states

`doomed(message, details)` (Zig `sdk.doomed`, JavaScript `doomed`): this timeline's state looks
hopeless for finding anything more (a cluster wedged by a known bug, a workload that cannot make
progress). The explorer then weighs returns after that moment down: each generation it draws how
much (from not at all to 64 times rarer in the archive) and whether the frontier skips such
moments. Never excluded for good: a hopeless state can still hold a bug. The first call in a
timeline counts. Antithesis's explorer prunes doomed states the same way (its NetHack and
Castlevania runs: blog/2026/nethack).

## Antithesis's SDKs

Programs written against Antithesis's SDKs run under determinismo as they are: their libvoidstar
is determinismo's (`antithesis_library` on a node), and imported Compose projects have it. The
SDKs above also take Antithesis's names, so such code ports by changing an import:

- JavaScript: `alwaysGreaterThanOrEqualTo`, `alwaysLessThanOrEqualTo`, the `sometimes...` ones,
  `sendEvent` (Antithesis's TypeScript SDK).
- Rust: `assert_always!`, `assert_always_greater_than_or_equal_to!`, ..., `get_random`,
  `send_event`, `AntithesisRng`, `antithesis_init` (Antithesis's crate `antithesis_sdk`).
- Python: `get_random`, `send_event`, `always_greater_than_or_equal_to`, ...
- Java: `getRandom`, `sendEvent`, `alwaysGreaterThanOrEqualTo`, ...
- Go: `GetRandom`, `SendEvent`, `AlwaysGreaterThanOrEqualTo`, `NamedBool`, `Source` (Antithesis's
  Go SDK's), and the build tag `determinismo_off` for no-op builds (theirs: `no_antithesis_sdk`).
- .NET: `Assert`, `Lifecycle`, `Random`, `AntithesisRandom` with the same members as Antithesis's
  `Antithesis.SDK` (`JsonObject` details): `using Determinismo;` in place of `using Antithesis.SDK;`.

What determinismo's SDKs add to Antithesis's: named decisions (strategies see what they steer),
buggify points, faults and quiet periods from the scenario, a seeded generator, catalog listing in
every SDK (Antithesis's Rust SDK has one), and raw output.

## libdeterminismo: the Zig SDK for any language

`libdeterminismo.so` (`sdk/zig/ffi.zig`) is the Zig SDK behind a C ABI, with no libc, so any
process loads it (a JVM through FFM, Python through ctypes): test programs written in another
language get what Zig programs have, from the same code. That covers system definitions
(`det_describe` checks and converts them as Zig's `System` does), decisions, assertions, records
for host checks, faults, and Elle's histories and checks. It is in every guest at
`/opt/determinismo/lib/libdeterminismo.so`, and on the host in the build's `zig-out/bin`.

Its interface is data: `sdk/zig/bindings.zig` lists every function with its typed parameters and
what it does. The library is checked against that table at compile time: a function missing, extra
or with another signature does not build. The build writes the table beside the library as
`libdeterminismo.json`, and bindings are made from that file. The types are:

- `string` and `json`: a pointer and a length (`json` is JSON text, checked);
- `buffer`: a pointer and a capacity that the function writes into, returning the size it has;
- `u64`, `i32`, `f64` and `bool`.

An `i32` result below 0 is an error named in the file (`invalid_argument`, ...).

The same table is written as a C header, `libdeterminismo.h`, beside the library (and in the
guest at `/opt/determinismo/lib`): C and C++ include it, as does anything that reads C headers
(jank's `(:include "libdeterminismo.h")`, Rust's bindgen, Zig's `@cImport`).

Clojure (`sdk/clojure/determinismo/`) makes its binding from the file as it loads. In it:

- `determinismo.ffi` has one function per entry, on Java 22+'s FFM (`det_random_below` is
  `random-below`);
- `determinismo.workload` is Zig's `System` in Clojure: profiles and nodes, scenarios' commands,
  host checks, `main`, assertions as catalog macros, and Elle;
- `determinismo.json` handles JSON with nothing but Clojure.

`examples/datomic` is a whole test program written this way.

A program in a language the runner lacks runs in a node: its scenarios name the node and the
program's path there (`Scenario.node`, `Scenario.program`), and the composer runs its commands as
`det-nodes exec <node> <program> run <scenario> <command>`. Records go to
`/opt/determinismo/records`, the system to `/opt/determinismo/system.json`, both visible in every
node. On the host its `--describe` and checks need its language there too: OpenJDK 25
and Debian's Clojure (`infra/host/provision.sh`), the program one file (`zig build <name>`:
`tools/clojure_program.zig`), and determinismo hands it libdeterminismo (`DETERMINISMO_LIBRARY`).

### jank

`sdk/jank` packages libdeterminismo for [jank](https://jank-lang.org) as jank's book packages a
system library: `org.determinismo/determinismo-sys` (its `jank-build.bb` gives the include
directory and the library by path, `/opt/determinismo/lib` in every node;
`DETERMINISMO_LIBRARY_DIR` for another) and `org.determinismo/determinismo`:
`determinismo.core` (`(:include "libdeterminismo.h")`, libdeterminismo's functions called with
jank's own conversions: `random-below`, `event`, `always`, `sometimes`, `fault`, `stop-faults`,
`describe`) and `determinismo.workload` (a test program as data, as Clojure's: profiles, nodes,
scenarios, commands; `main` answers `--describe` through det_describe and runs `run <scenario>
<command>`). A jank test program is one file (build.zig's `jank_programs`,
tools/program_pack.zig): its `--describe` runs on the host with jank from `~/opt/jank`
(infra/host/tools.sh), its commands in its node. examples/jank-box3d is one, with box3d.

### Platform mechanics in any language

A program in a node sees only its node, while the guest's runner sees them all. `det_runner`
asks the runner to run a command (`{"argv": [...], "stdin"?: "..."}`), and `det_runner_reply`
gives its answer (`{"status", "stdout", "stderr", "truncated"}`). Behind it is `det-runner`, a
service in the runner on a Unix socket in the records tmpfs (`schema.runner_socket`). The
commands are the runner's: `det-nodes` (start, stop, kill, crash, wipe, pause, resume, exec),
the network and the disks. Each request is a `runner_request` event.

Mechanics are then the program's own code: a fault kind, a node's lifecycle, a recovery
procedure. Its choices come from the platform's decisions (`det_decide`, `det_random_below`:
replayed, steered by strategies) and its effects are runner commands, so it replays like the
platform's own. Clojure's `determinismo.workload` has `runner`, `node!` (`(w/node! :crash :db)`)
and `node-exec`, which also work from the guest's REPL. What remains Zig's are the primitives:
virtual time, steps, snapshots and decisions in the hypervisor.

Inside a session's machine (a REPL in the guest), `det_serve(method, path, body)` calls serve's
API: `POST /runs` starts a run, `GET /runs/<id>` follows it. The session's explore makes the
call (`--serve-url`), and the reply comes back as decisions on the tape, so a replay repeats it
without serve. Its body is kept for `det_serve_reply`. `/sessions` routes are refused, since
they would wait on the machine making the call. Clojure has `serve`, `start-run!` and
`run-state`.

An Elle check declares its properties where it is defined (`det_elle_declare`, which Zig's
`sdk.elle.check` does as it builds). A program without one has no Elle properties to reach.

## The protocol (any language, no SDK)

Inside determinismo a process opens `/dev/determinismo` read-write.

- Randomness: `read(fd, buffer, n)` with n at most 4080 returns n random bytes, each read a
  platform decision (replayed from tapes, steered by strategies).
- Events: `write(fd, json, n)`, one JSON object per write, at most 4080 bytes:
  - `{"assert":{"type":"always","message":"...","condition":true,"details":{...},"location":{"file":"...","line":1,"function":"..."}}}`
    (types: always, always_or_unreachable, sometimes, reachable, unreachable);
  - `{"assert":{"type":"...","message":"...","hit":false}}`: declared, not evaluated (the catalog);
  - `{"guidance":{"message":"...","distance":1.5}}`: how far from the interesting outcome;
  - a comparison's (`always_greater_than` and the like) operands are in its details, `left` and
    `right`. JSON has no infinity or NaN, so every SDK sends those as the strings "Infinity",
    "-Infinity" and "NaN", and an infinite guidance distance as the largest finite number (NaN
    sends none): a line that is not JSON is stored as text and never judged, so before this an
    `always_less_than(latency, 100)` with an infinite latency failed unseen (Zig, C, Python and
    the JVM wrote bare `inf` or `Infinity`, Go an unencodable event, and .NET threw into the
    caller);
  - `{"optimize":{"message":"...","bucket":{"leader":"n1"},"value":12,"goal":"maximize"}}`: an
    objective (goal maximize or minimize). Each bucket (its strings and booleans) is explored
    evenly, keeping the state with its best value; the tree returns to it (`sdk.optimize` in Zig,
    `det_optimize` in C, `optimize` in Python, Rust, JavaScript and Clojure, `Optimize` in Go,
    `Determinismo.optimize` in Java, `Lifecycle.Optimize` in .NET);
  - `{"decision":{"name":"...","options":["a","b"]}}` or `{"decision":{"name":"...","range":10}}`
    before the read that draws it;
  - `{"lifecycle":"setup_complete","details":{...}}`;
  - `{"event":"name","details":{...}}`; and any other object (raw output).
- Faults: `/opt/determinismo/faults-control`, a FIFO, opened write-only non-blocking: an 8-byte
  little-endian u64, nanoseconds of quiet (0 ends it), or `(1 << 63) | n` followed by n bytes of a
  JSON fault (guest/runtime/faults.zig lists the kinds); one write each.
