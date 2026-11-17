#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run.sh <image> [<count> [<phases>]]: jank's nREPL server outside determinismo (the workload's
# image, Dockerfile.jank, its jank-start), 6 GiB at most, then client.py's phases: each form
# evaluated <count> times, jank's resident memory read every 100 and its growth per evaluation
# printed. Phases: distinct, same, def, defn, call (comma-separated; distinct,def,defn by default).
#   podman build -f examples/nrepl/Dockerfile.jank -t jank-nrepl . && examples/nrepl/jank-memory/run.sh jank-nrepl 400 same,defn,call,distinct
set -uo pipefail
cd "$(dirname "$0")"
image=${1:?usage: run.sh <image> [<count> [<phases>]]}
podman rm -f jank-memory >/dev/null 2>&1
podman run -d --name jank-memory --memory 6g -p 127.0.0.1:27888:7888 "$image" >/dev/null || exit 1
python3 client.py 27888 jank-memory "${2:-600}" "${3:-distinct,def,defn}"
podman rm -f jank-memory >/dev/null
