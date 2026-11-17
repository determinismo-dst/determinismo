#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# serve-bundle.sh <bundle> [--listen <address:port>]: serve's web UI for a bundle, on an inspection
# machine (docs/INSPECT.md): the bundle as run 1 of a data directory of its own, served by its
# own explorer (the run's build: its UI, its replays, its sessions and their REPLs, its futures),
# listening on 127.0.0.1:7878 by default. Reach it from your machine through an SSH tunnel, AWS
# Session Manager's port forwarding or Tailscale, then http://localhost:7878.
# The bundle carries the run's view of its timelines (bundle-view.py: their record lines and
# events), from which serve builds its database at the first start.
#   serve-bundle.sh ~/duckdb-quack-1742-43
set -euo pipefail
bundle=$(cd "${1:?usage: serve-bundle.sh <bundle> [--listen <address:port>]}" && pwd)
shift
listen=127.0.0.1:7878
while [ $# -gt 0 ]; do
  case $1 in
    --listen) listen=$2; shift 2 ;;
    *) echo "serve-bundle.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -f "$bundle/record.jsonl" ] || { echo "serve-bundle.sh: $bundle carries no run view (bundle-view.py)" >&2; exit 1; }
explorer=$(grep -o '"explorer":"[^"]*"' "$bundle/request.json" | cut -d'"' -f4)
[ -n "$explorer" ] || explorer=$(ls "$bundle"/artifacts/*-determinismo | head -1 | sed "s|$bundle/||")
chmod +x "$bundle/$explorer"
# The explorer's library under the names a build has it beside its binary (runs.zig's
# library_keep reads them there for each run serve starts): the bundle keeps it under the run's.
for extension in so json; do
  [ -f "$bundle/$explorer.libdeterminismo.$extension" ] \
    && ln -sfn "$(basename "$explorer").libdeterminismo.$extension" "$(dirname "$bundle/$explorer")/libdeterminismo.$extension"
done
# INSPECT.sh decompresses the moment's snapshot (sessions start from it).
(cd "$bundle" && ./INSPECT.sh true >/dev/null 2>&1) || true
# The moment's snapshot where serve's replays look for one (replay_snapshots.zig:
# replays/layout-<the state's size, from its header>/b<timeline>-<ms>, with the base it names):
# "Run at this moment" and sessions then start from it, not from boot (a minute and more on a
# nested machine).
for state in "$bundle"/snapshots/*.state; do
  [ -f "$state" ] || continue
  size=$(od -An -t u8 -j 8 -N 8 "$state" | tr -d ' ')
  layout=$bundle/replays/layout-$size
  mkdir -p "$layout"
  name=$(basename "$state" .state)
  ln -sf "$state" "$layout/$name.state"
  ln -sf "${state%.state}.mem" "$layout/$name.mem"
done
data=$HOME/.determinismo-bundles/$(basename "$bundle")
mkdir -p "$data/runs"
ln -sfn "$bundle" "$data/runs/1"
# A run directory changed in its last minute, with no pid file, is one an explorer may be
# claiming: serve lists it only after that minute (claim_grace_s). The bundle is complete.
touch -d '2 minutes ago' "$bundle"
echo "serve-bundle.sh: $(basename "$bundle") as run 1, on http://$listen (from your machine: a tunnel to it)"
# From the bundle: its machine's paths (artifacts/, cache, cpuid.txt) are relative to it.
cd "$bundle"
# The run's machine (machine.json: its kernel, initramfs, cache, memory, CPUID, all in the bundle)
# as serve's, which boots the runs it starts with it: the UI's "Fork here" and "New run". Not
# its clock's jitter: each run takes it from its own seed (the same seed, the same jitter).
mapfile -t machine < <(python3 -c '
import json, sys
flags = json.load(open("machine.json"))
skip = False
for flag in flags:
    if skip:
        skip = False
    elif flag == "--tsc-jitter-seed":
        skip = True
    else:
        print(flag)
')
# The run's pinned system too (bundle-view.py): a fork from a moment boots the system the run
# booted (its images are in the bundle's cache), not one built from the repository's sources.
[ -f events/system.pin.json ] && machine+=(--system "$bundle/events/system.pin.json")
# Nested (an inspection instance: our KVM inside AWS's), the guest stops less precisely than on
# the recording host's metal, whose margin machine.json carries (srv4's 48): DuckDB run 1950's
# timeline 241 on a c8i.xlarge overshot its stops 96 times at 128 and replayed another history,
# exact at 256 (events hash 723afca63648509b, srv4's; 2026-11-13). Serve's replays take the run's
# machine.json, so this machine's copy says it (checked only at the fetch; tapes check inputs).
if grep -qw hypervisor /proc/cpuinfo; then
  python3 - "$bundle/machine.json" "${NESTED_MARGIN_BRANCHES:-256}" <<'PY'
import json, sys
path, margin = sys.argv[1], sys.argv[2]
flags = json.load(open(path))
if "--margin-branches" in flags:
    at = flags.index("--margin-branches") + 1
    if int(flags[at]) < int(margin):
        flags[at] = margin
else:
    flags += ["--margin-branches", margin]
json.dump(flags, open(path, "w"))
PY
  machine+=(--margin-branches "${NESTED_MARGIN_BRANCHES:-256}")
fi
# Snapshots kept for good: serve's janitor removes a run's after a day without a new one, and
# the bundle's is its moment.
exec "./$explorer" serve --listen "$listen" --data "$data" --snapshots-keep-hours 87600 "${machine[@]}"
