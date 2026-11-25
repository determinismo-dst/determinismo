#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# elle-image.sh [--dry-run]: in a host's deployed tree (update.sh runs it after the build), Elle's
# service (checkers/elle, on 127.0.0.1:7700) rebuilt and restarted when the deployed checkers/elle
# differs from the one its image was built from. A fix keeps the service's version, and the SDK
# replaces only a service answering another version, so without this step a deploy left the old
# Elle judging (2026-11-25: a 7-day-old image while next held Elle's fixes). The image carries
# checkers/elle's content hash as a label. Rebuilt only with no run and no det-* unit going: a
# check in flight would lose its service, and podman beside a run's holders on disk blocks.
# One line printed either way, naming the label and the tree's hash (a deploy's read-back).
# --dry-run: what it would do, nothing done.
set -euo pipefail
dry=
[ "${1:-}" = --dry-run ] && dry=1
image=determinismo-elle
label=determinismo.elle.tree
tree=$(find checkers/elle -type f ! -path '*/classes/*' ! -path '*/.cpcache/*' -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
built=$(podman image inspect "$image" --format "{{index .Labels \"$label\"}}" 2>/dev/null || true)
[ "$built" = "<no value>" ] && built=
if [ "$built" = "$tree" ]; then
  echo "== Elle: image $label=$built = checkers/elle $tree: current"
  exit 0
fi
# serve's runs, once it answers: update.sh calls this right after serve's restart, when /runs
# answers nothing yet, and the count read as unknown refused every rebuild (2026-11-25's deploy
# left the old image judging). Up to a minute; still unknown after it, refused as before.
runs_running() {
  curl -s -m 20 http://127.0.0.1:7878/runs | python3 -c '
import json, sys
v = json.load(sys.stdin)
v = v if isinstance(v, list) else next(x for x in v.values() if isinstance(x, list))
print(sum(r.get("state") == "running" for r in v))' 2>/dev/null
}
running=unknown
for _ in $(seq 1 30); do
  if count=$(runs_running) && [ -n "$count" ]; then running=$count; break; fi
  sleep 2
done
units=$(systemctl list-units --no-legend --plain 'det-*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$running" != 0 ] || [ "$units" != 0 ]; then
  echo "== Elle: image $label=${built:-none} != checkers/elle $tree: NOT rebuilt ($running runs," \
    "$units det-* units going); run infra/host/elle-image.sh here once idle"
  exit 0
fi
if [ -n "$dry" ]; then
  echo "== Elle: image $label=${built:-none} != checkers/elle $tree: would rebuild $image" \
    "(podman build --label $label=$tree -f checkers/elle/Dockerfile .), restart it, wait for :7700"
  exit 0
fi
echo "== Elle: rebuilding $image ($label ${built:-none} -> $tree)"
podman build -q --label "$label=$tree" -t "$image" -f checkers/elle/Dockerfile . > /dev/null
podman rm -f "$image" > /dev/null 2>&1 || true
podman run -d --name "$image" --network host "$image" > /dev/null
answer=
for _ in $(seq 1 120); do
  answer=$(curl -fsS -m 2 http://127.0.0.1:7700/version 2>/dev/null) && break
  sleep 1
done
now=$(podman image inspect "$image" --format "{{index .Labels \"$label\"}}")
echo "== Elle: image $label=$now, checkers/elle $tree, :7700 ${answer:-not answering}"
[ "$now" = "$tree" ] && [ -n "$answer" ]
