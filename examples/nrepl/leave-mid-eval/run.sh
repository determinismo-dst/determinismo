#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# nREPL 1.8.0: a request queued in a session whose client left mid-evaluation is never answered
# (examples/nrepl/README.md, "Found"). repro.clj three ways, 5 attempts each, natively (no
# faults): A leaves while its eval runs and B queues one at once (no reply at all), A stays (B
# answered), B after A's eval ended (answered). NREPL=<version> for another release; with
# NREPL=master, nREPL's master built from source (sessions end with their connection there:
# B is answered unknown-session).
set -uo pipefail
cd "$(dirname "$0")"
version=${NREPL:-1.8.0}
image=docker.io/library/clojure:temurin-25-tools-deps-alpine
if [ "$version" = master ]; then
  podman run --rm -v "$PWD":/w:Z -w /w $image sh -c 'apk add --no-cache git >/dev/null 2>&1
    rm -rf nrepl && git clone -q https://github.com/nrepl/nrepl && mkdir -p nrepl/target/classes
    javac -cp "$(clojure -Spath 2>/dev/null)" -d nrepl/target/classes $(find nrepl/src/java -name "*.java")
    clojure -Sdeps "{:deps {nrepl/nrepl {:local/root \"nrepl\"}}}" -M repro.clj; rm -rf nrepl' 2>&1 | grep -v '^Downloading'
else
  podman run --rm -v "$PWD":/w:Z -w /w $image \
    clojure -Sdeps "{:deps {nrepl/nrepl {:mvn/version \"$version\"}}}" -M repro.clj 2>&1 | grep -v '^Downloading'
fi
