#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# bundle-moment.sh <run directory> <timeline> <moment ms> <out> <store>: on the host that recorded
# the run, a bundle (determinismo bundle --store) with the timeline's snapshot at the moment
# (explore --save-snapshots: the moment's pages changed since its base, and the base, the setup's
# snapshot), each compressed (zstd: the memory files are sparse, 2 GiB apparent, kilobytes to
# hundreds of MB of pages) and put in the store by digest, STORED listing them beside the inputs.
# On the inspection machine (the recording CPU's model: docs/AWS.md; the run's own explorer,
# which the bundle carries, saves and loads the snapshot), after
# `determinismo bundle fetch <out> <store>` (bundle-s3.sh pull does it), INSPECT.sh in the bundle
# decompresses them and goes on from the moment instead of replaying to it: 19 s against minutes
# (NATS run 1647, timeline 64: from its snapshot at 30 s, 2026-11-09).
#   infra/host/bundle-moment.sh ~/.determinismo/runs/1647 64 278000 ~/bundles/nats-1647-64 ~/bundles/store
# The snapshot is saved BUNDLE_BEFORE_MS before the moment (30000 by default; just after the
# timeline's own start when the moment comes sooner: the run's setup snapshot, or for a timeline
# that returned to another its branch point, where it begins): every moment of the last 30 s before a failure is
# then at most that much replay away on the inspection machine (a nested CPU: going back seconds
# before a failure from the setup's snapshot took minutes), and INSPECT.sh goes on from it to the
# moment itself.
set -euo pipefail
[ $# -eq 5 ] || { sed -n '3,12p' "$0" >&2; exit 2; }
run=$1 timeline=$2 moment=$3 out=$4 store=$5
setup_ms=$(( $(grep -o '"snapshot":{"vtime_ns":[0-9]*' "$run/record.jsonl" | head -1 | grep -o '[0-9]*$' || echo 0) / 1000000 ))
# Where the timeline itself begins: a returned one at its branch point (the last moment of its
# path), a replay of it has nothing before. etcd's run 2007, timeline 3419 (returned to timeline
# 1 at 23.115 s, failing at 50.585 s): saved 30 s before, at 20.585 s, "the moment is not after
# the snapshot", and its finding had no bundle (2026-11-15).
start_ms=$(python3 - "$run/events/timelines.jsonl" "$timeline" "$setup_ms" <<'PY'
import json, sys
path, timeline, setup_ms = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
start_ms = setup_ms
try:
    with open(path) as lines:
        for line in lines:
            try:
                ended = json.loads(line)
            except ValueError:
                continue
            if ended.get("index") == timeline and ended.get("path"):
                start_ms = max(start_ms, ended["path"][-1]["vtime_ns"] // 1000000)
except OSError:
    pass
print(start_ms)
PY
)
saved=$((moment - ${BUNDLE_BEFORE_MS:-30000}))
if [ "$saved" -le "$start_ms" ]; then saved=$((start_ms + 1)); fi
if [ "$saved" -gt "$moment" ]; then saved=$moment; fi
command -v zstd >/dev/null || { echo "bundle-moment.sh: zstd is not installed" >&2; exit 1; }
determinismo=${DETERMINISMO:-determinismo}
"$determinismo" bundle "$run" "$timeline" "$out" --store "$store"
# The inputs back in place for the replay that saves the snapshot (removed after: the store has
# them).
"$determinismo" bundle fetch "$out" "$store"
mapfile -t inputs < <(awk '{ $1 = ""; $2 = ""; sub(/^  /, ""); print }' "$out/STORED")
# The run's own explorer, which the bundle carries: a snapshot loads only in the build that saved
# it, and the tape was recorded by that one.
explorer=$(grep -o '"explorer":"[^"]*"' "$out/request.json" | cut -d'"' -f4)
[ -n "$explorer" ] || { echo "bundle-moment.sh: the run kept no explorer (request.json)" >&2; exit 1; }
chmod +x "$out/$explorer"
# The run's own snapshot of the timeline nearest before the saved moment, when the explorer kept
# one (its ladder: snapshots/layout-*/h<timeline>-<ns> from its holders on disk, b<timeline>-<ms>
# from those in memory): the replay goes on from it, seconds instead of the whole timeline (a
# Pulsar timeline's 305 s took 15 minutes from the setup snapshot). Its chain of bases comes
# into the bundle with it (linked: the same files), as INSPECT.sh's load follows them.
resume=()
best=-1
for state in "$run"/snapshots/layout-*/h"$timeline"-*.state "$run"/snapshots/layout-*/b"$timeline"-*.state; do
  [ -f "$state" ] || continue
  name=$(basename "$state" .state)
  moment_of=${name#?"$timeline"-}
  case $name in h*) ms=$((moment_of / 1000000)) ;; *) ms=$moment_of ;; esac
  if [ "$ms" -lt "$saved" ] && [ "$ms" -gt "$best" ]; then best=$ms; resume=("$state"); fi
done
if [ ${#resume[@]} -gt 0 ]; then
  from_dir=$(dirname "${resume[0]}")
  mkdir -p "$out/snapshots"
  name=$(basename "${resume[0]}" .state)
  start=$name
  while [ -n "$name" ]; do
    for kind in state mem; do
      ln -f "$from_dir/$name.$kind" "$out/snapshots/$name.$kind" 2>/dev/null || cp "$from_dir/$name.$kind" "$out/snapshots/$name.$kind"
    done
    # The base's name: the header's 64 bytes at 40 (snapshot.zig's DiskHeader), empty for none.
    name=$(dd if="$from_dir/$name.state" bs=1 skip=40 count=64 2>/dev/null | tr -d '\0')
  done
  resume=(--tape-snapshot "snapshots/$start")
  echo "bundle-moment.sh: on from the run's snapshot $start ($best ms)"
fi
# Exit 3 is a property failing by the moment: a failure's own timeline bundled at its failure
# (DuckDB run 1742's timeline 43, 2026-11-10), its snapshot saved all the same.
(cd "$out" && "./$explorer" explore --run . --branch "$timeline" "${resume[@]}" --save-snapshots snapshots \
  --save-at-ms "$saved" --at-vtime-ms "$((saved + 1))" --exec true > snapshots.log 2>&1) \
  || [ $? -eq 3 ] || { tail -5 "$out/snapshots.log" >&2; exit 1; }
ls "$out"/snapshots/b"$timeline"-"$saved".state >/dev/null \
  || { echo "bundle-moment.sh: no snapshot saved at $saved ms (snapshots.log)" >&2; exit 1; }
for file in "$out"/snapshots/*.mem "$out"/snapshots/*.state; do
  [ -f "$file" ] || continue
  zstd -q -T0 -3 --rm "$file" -o "$file.zst"
  hex=$(sha256sum "$file.zst" | cut -d' ' -f1)
  size=$(stat -c %s "$file.zst")
  [ -f "$store/sha256/$hex" ] || cp "$file.zst" "$store/sha256/$hex"
  printf '%s  %s  %s\n' "$hex" "$size" "snapshots/$(basename "$file").zst" >> "$out/STORED"
  printf '%s  %s\n' "$hex" "snapshots/$(basename "$file").zst" >> "$out/SHA256SUMS"
  rm "$file.zst"
done
for path in "${inputs[@]}"; do rm -f "$out/$path"; done
rm -rf "$out/snapshots" "$out/snapshots.log"
cat > "$out/INSPECT.sh" <<EOF
#!/usr/bin/env bash
# After \`determinismo bundle fetch <this bundle> <store>\`: the snapshot decompressed, then the
# timeline from the moment: INSPECT.sh '<command at the moment>' (det-nodes exec <node> ...).
set -euo pipefail
cd "\$(dirname "\$0")"
for file in snapshots/*.zst; do [ -f "\${file%.zst}" ] || zstd -q -d --sparse "\$file" -o "\${file%.zst}"; done
chmod +x $explorer
# Nested (an AWS inspection instance), stops are less precise than on the recording metal:
# a wider margin, or the replay overshoots and leaves the history (serve-bundle.sh says why).
margin=()
grep -qw hypervisor /proc/cpuinfo && margin=(--margin-branches "\${NESTED_MARGIN_BRANCHES:-256}")
./$explorer explore --run . --branch $timeline --tape-snapshot snapshots/b$timeline-$saved \\
  "\${margin[@]}" --at-vtime-ms $((moment + 1)) --exec "\${1:-det-nodes list}"
EOF
chmod +x "$out/INSPECT.sh"
echo "bundle-moment.sh: $out (timeline $timeline at $moment ms, its snapshot at $saved ms), $(du -sh "$out" | cut -f1) here; fetch with determinismo bundle fetch $out $store, then $out/INSPECT.sh '<command>'"
