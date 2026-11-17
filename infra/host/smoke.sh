#!/bin/bash
# SPDX-License-Identifier: MIT
# smoke.sh <hunt> [<sometimes message>...]: on a host running serve, in the repository, the hunt's
# request (infra/hunts/<hunt>.json) as a smoke: a 5-minute budget, timelines of 60 s unless the
# hunt sets its own length (several waves in 5 minutes: CockroachDB's 2- to 6-minute timelines
# gave one, run 365). Waits for it, then judges it: healthy (run-health.sh) and each message made
# true in some timeline (drivers whose whole point is one behavior, a membership change, that a
# smoke must show), or "UNHEALTHY" and exit 1. The hunt queue stops a smoke past its budget
# (hunt-queue.sh); this does not.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../.."
hunt=${1:?usage: $0 <hunt> [<sometimes message>...]}
shift
request=$(python3 -c 'import json, sys
r = json.load(open(sys.argv[1]))
r["time_budget"] = "5m"
r["timeline"] = r.get("timeline") or "60s"
print(json.dumps(r))' "infra/hunts/$hunt.json")
id=$(curl -s --max-time 120 -X POST localhost:7878/runs -d "$request" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')
echo "$(date +%H:%M) smoke $hunt: run $id"
while state=$(curl -s --max-time 30 "localhost:7878/runs/$id" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("state"))' 2>/dev/null || echo running) && [ "$state" = running ]; do
  sleep 15
done
"$here/run-health.sh" "$id" 2>&1 | grep -E '^\{|healthy|UNHEALTHY'
health=${PIPESTATUS[0]}
python3 - "$id" "$@" <<'PY'
import json, sys, urllib.request
run, wanted = sys.argv[1], sys.argv[2:]
properties = {p["message"]: p for p in json.load(urllib.request.urlopen(f"http://localhost:7878/runs/{run}/properties", timeout=300))}
missing = [m for m in wanted if not (properties.get(m) or {}).get("timelines_true")]
print(f"UNHEALTHY: never true in run {run}: {missing}" if missing else f"expected behaviors reached in run {run}: {wanted}")
sys.exit(1 if missing else 0)
PY
[ $? -eq 0 ] && [ "$health" -eq 0 ]
