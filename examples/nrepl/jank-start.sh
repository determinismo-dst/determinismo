#!/bin/sh
# jank's nREPL server as the container's main process: its death (README: a division by zero's
# SIGFPE, a stack overflow's SIGSEGV) is the container's exit, which the run's properties see.
# Behind socat it was not: socat lived on, refusing connections, the kernel's crash line the only
# sign. jank's REPL reads stdin (held open by a FIFO with a writer that never ends) and
# listens on 127.0.0.1 only: socat forwards 7888, started once the server says it has started,
# so the port's opening is the node's readiness as before.
set -eu
mkfifo /tmp/repl.in
sleep infinity > /tmp/repl.in &
: > /tmp/repl.log
tail -n +1 -F /tmp/repl.log &
(until grep -q 'nREPL server started' /tmp/repl.log 2>/dev/null; do sleep 0.2; done
 exec socat TCP-LISTEN:7888,fork,reuseaddr TCP:127.0.0.1:17888) &
# --perf: jank's JIT writes a jitdump file (perf's format) naming each function it compiles, which
# det-profile reads: `determinismo stacks` and profiles name REPL-compiled frames.
exec jank repl --perf --port 17888 < /tmp/repl.in > /tmp/repl.log 2>&1
