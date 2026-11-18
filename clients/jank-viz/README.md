# determinismo's visualization for a jank REPL

A window (Dear ImGui, from [jank-lang/commons](https://github.com/jank-lang/commons)) that
prints what a jank REPL does with determinismo: the process is the REPL (jank's nREPL server),
so every evaluation is told to the window with its value, and so is every call of the client
(`determinismo.api`, `determinismo.debug`, through `determinismo.tap`). Nothing to call for it.

```sh
./viz.sh                                      # the window; its nREPL port in .nrepl-port
./viz.sh --hidden --record take.mp4           # no window: its frames to a video (960x1080)
DETERMINISMO_URL=http://host:7878 ./viz.sh    # serve's address, else http://127.0.0.1:7878
```

Connect an editor to the port (CIDER: `cider-connect-clj`), or an agent (an nREPL client such
as `clj-nrepl-eval -p $(cat .nrepl-port) '<form>'`), and work as anywhere; `(help)` from
`determinismo.help` lists what there is. The window draws what either evaluates, so a person
watches what an agent does:

```clojure
(require '[determinismo.api :as d] '[determinismo.debug :as dbg])
(def s (dbg/open 56 {:branch 0 :until "event=core_dump" :rewind-ms 1000}))
(dbg/regs s)
(dbg/mem s 0x1342000 8)
(dbg/poke s 0x1342000 [0x0f 0x0b])
(dbg/close s)
```

What it shows:

- **The multiverse** of the run the REPL last touched: a row a timeline, where each left the one
  before it, faults (orange), crashes (a red cross), each timeline's first failed assertion (a
  red dot), what a query found (blue rings), the moments looked at (ticks) and the one a session
  is at (the pulsing cursor). A session's own timeline is a tick where it left until the REPL
  looks at it (a session opened on it, a query of it); a run of many timelines is thin rows, with
  those looked at drawn again below them, large. A run started from the REPL is followed while
  it explores.
- **A card an evaluation**, the newest last (the older ones roll up under the map as it comes),
  shown by what it was: a session opened (its
  timeline, its moment, the event query that named it, the faults of the second before);
  registers and memory with what they were at the last look beside what they are now, changed
  ones in red; the instructions at an address, before and after a poke (llvm-mc, when
  installed); an address translated, virtual to physical; a crash's stack (a `crash_stack` event's details:
  its frames, the program's own lines standing out); a command's output, a kernel's oops in
  red; a query's events and nested maps as pretty-printed EDN, a flat map as its keys and values;
  SQL's rows as a table; a vector of
  numbers as bars with their sum and what changed since the last ones; anything else as it prints.
  No card for nil. `(determinismo.viz/show "name" value)` adds a card by hand,
  `(determinismo.viz/clear!)` removes them.

The drawing is jank (`src/determinismo/viz.jank`) over a few native primitives
(`include/detviz.hpp`: text, lines, rectangles, the recording): change a `draw-` function and
evaluate it, and the next frame is drawn with it.

The first start compiles the packages it builds on. `viz.sh` sets what that needed on macOS: the
Command Line Tools' compiler, C++17 for ImGui's headers, and no sandbox around the packages'
builds (they ask Homebrew where GLFW is). Needs `lein`, `jank`, `bb`, `cmake`, `glfw`, and
`ffmpeg` for `--record`.
