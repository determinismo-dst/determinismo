# A 64-thread race under determinismo

The toy race of [Hillel joins Antithesis](https://antithesis.com/blog/2026/hillel-joins-antithesis/):
threads increment a shared counter if it is still zero (`if (counter == 0) counter++;`), so it
ends at 1 unless threads interleave between the check and the increment. A run of 64 threads
asserts that not all of them incremented it. Natively (one CPU), the post's 100 million runs never
had even three threads race, while Antithesis found all 64 a hundred times in five minutes.

`race.cpp` is the program, our own and MIT. A runner in it starts runs again and again, each a
fresh process as a shell would start it, and prints every run's counter. A run's own `assert`
aborts when all 64 incremented the counter, which fails "no process crashes: race". There is no
other assertion or guidance: the explorer is blind to how close a run came. The runner is never
instrumented (a race is no new edge), and every run prints the same line (a race is no new
kind of output line, which the tree counts as a behavior).

It is built at `-O0`, as the post's had to be: at `-O1` the compiler turns the increment into a
store of 1, and the counter never passes 1. At `-O0`, `update` is

```
cmpl  $0x0, counter      ; the check
jne   done
movl  counter, %eax      ; the increment: load, add, store
addl  $0x1, %eax
movl  %eax, counter
```

so the counter reaches 64 only if every thread is preempted between its check and its load, and
then the increments run one after another: on one CPU, 63 preemptions, each in a window of two
instructions.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/race-test --scenario race --seed 1 --branches 64
```

Faults: scheduling alone varies a single process, so the interleave fault (the guest scheduler's
choices drawn), pauses of the process or of one of its threads, and CPU throttling.

Profiles: `default`, the program as it is; `instrumented`, the same built for coverage
(`-fsanitize-coverage=trace-pc-guard`, the C SDK's callbacks: `sdk/c/coverage.c`), where thread pausing
pauses threads; and the race in other languages, each instrumented the way its SDK does it:
`go` (`go/`, `determinismo-toolexec`), `java` (`java/`, the coverage agent), `python`
(`python/`, `coverage_start`), `javascript` (`javascript/`, Node.js worker threads over a
SharedArrayBuffer, `coverageStart`: its pausing through the inspector), `dotnet` (`dotnet/`,
C#, instrumented after its build by `determinismo-dotnet-instrument`), `rust` (`rust/`, rustc's
trace-pc-guard) and `zig` (`race.zig`).
Each language's program runs the same race and fails as that language fails (an abort, a
panic, an uncaught exception). The e2e `pausing` check explores each for 32 timelines.

## Status

srv4 (2x Xeon Gold 6152, 42 workers), five minutes each, blind (2026-10-31):

| Profile | Timelines | Found (independent finds) | CPU per find | Races (counter past 1) |
|---|---|---|---|---|
| `default` (no instrumentation) | 1,461 | never | | none in 1.4 million runs |
| `instrumented` (C++) | 2,153 | 787 times | 0.1 min | 2 to 63 threads |
| `go` | 2,105 | 562 times | 0.2 min | up to 63 |
| `rust` | 2,057 | 858 times | 0.1 min | up to 62 |
| `java` | 953 | 9 times | 6.1 min | up to 60 |
| `python` | 2,077 | 4 times | 20.4 min | all or nothing (the GIL) |
| `javascript` (runs 971, 978, 2026-11-04) | 734, 567 | never | | the pool's 8 s start added (run 938, without it: 951 timelines, no race). Run 971, 1 to 10 ms pauses: 267 races in 2 timelines, counters to 60. Run 978, 4 to 40 ms: 165 races in 2 timelines, counters to 63, 5 past 50: the gathering grows with the pause; the stretches that race are rare (the act's slow point drawn about 1 stretch in 256). The SDK's pauses are 10 to 100 ms since |
| `dotnet` (run 939, 2026-11-04) | 1,479 | 6 times (in 473 timelines) | 17.8 min | counters to 40 seen before a find |

Without instrumentation, the scheduler's choices land at ticks and wakeups, and a preemption
inside a two-instruction window is about one in a million: like the post's native runs, not one
race. With it, thread pausing makes the check's block a slow point now and then, every thread
that passed the check waits there, and all 64 increment. Antithesis: "a hundred times in five
minutes" (hardware not comparable). Python races all or nothing: under the GIL a thread runs
`update` whole, unless its branch point is slow. Run 283 (`java`) also had a timeline whose
original history its replays do not reproduce (docs/PLAN.md, open issues).
