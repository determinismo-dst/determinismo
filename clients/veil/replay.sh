#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# replay.sh <serve's URL> <run> <timeline> <Module.lean> <map.json> <instance> <veil checkout>
#           [--theory <theory>] [--lake <command>]
# A timeline of a run checked against a Veil model kept on this machine (docs/VEIL.md), with no
# determinismo here: serve gives the timeline's lines as the module's action labels through the
# map; Veil's #replay (a checkout with tools/veil/replay.patch applied, built) takes them here
# from the instance's initial states; serve then names the line where it stopped. As
# `determinismo veil` where the run is: exit 0 the timeline is a run of the model, every property
# holding; 3 a label the model refuses, or a property broken after one (its moment, node and
# line); 1 nothing could be checked.
# Needs curl, jq and Lean's lake (elan).
#   clients/veil/replay.sh http://127.0.0.1:7878 1415 10 StuckLeaderLog.lean log-map.json \
#     '{ node := Fin 3 }' ~/opt/veil
set -euo pipefail
usage="usage: $0 <serve's URL> <run> <timeline> <Module.lean> <map.json> <instance> <veil checkout> [--theory <theory>] [--lake <command>]"
serve=${1:?$usage}; run=${2:?$usage}; timeline=${3:?$usage}; module=${4:?$usage}; map=${5:?$usage}
instance=${6:?$usage}; checkout=${7:?$usage}
shift 7
theory="{}"
lake=${LAKE:-lake}
while [ $# -gt 0 ]; do
  case $1 in
    --theory) theory=${2:?$usage} ;;
    --lake) lake=${2:?$usage} ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2
done
ask() { curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' --data-binary @- "$serve/runs/$run/veil"; }
reply=$(jq -n --slurpfile map "$map" --argjson branch "$timeline" '{branch: $branch, map: $map[0]}' | ask)
count=$(jq -r .count <<< "$reply")
if [ "$count" = 0 ]; then
  echo "no line of timeline $timeline matches an action of $map"
  exit 1
fi
name=$(grep -oE '^veil module [A-Za-z0-9_]+' "$module" | head -1 | cut -d' ' -f3)
end=$(grep -n "^end $name\$" "$module" | tail -1 | cut -d: -f1)
if [ -z "$name" ] || [ -z "$end" ]; then
  echo "$module: no \`veil module <Name>\` ... \`end <Name>\`"
  exit 1
fi
# The labels and the module with its #replay, in the checkout (its build reused).
work=$(cd "$checkout" && pwd)/.determinismo-veil
mkdir -p "$work"
labels=$work/determinismo_veil_labels.json
jq -c .labels <<< "$reply" > "$labels"
copy=$work/DeterminismoVeilReplay.lean
{ head -n $((end - 1)) "$module"
  printf '#replay interpreted %s %s (file := "%s")\n\n' "$instance" "$theory" "$labels"
  tail -n +"$end" "$module"; } > "$copy"
# $lake may be several words.
said=$(cd "$checkout" && $lake env lean "$copy" 2>&1) || true
verdict=$(grep -o '{"replay":.*}' <<< "$said" | head -1 || true)
if [ -z "$verdict" ]; then
  echo "Veil gave no replay verdict; its output:"
  tail -n 30 <<< "$said"
  exit 1
fi
line_of() {
  jq -n --slurpfile map "$map" --argjson branch "$timeline" --argjson label "$1" '{branch: $branch, map: $map[0], label: $label}' \
    | ask | jq -r '.at | "\(.name)(node \(.node)) at \(.vtime_ns / 1e9 * 1000 | floor / 1000) s, \(.source): \(.text)"'
}
refused=$(jq -r '.replay.refused_at // empty' <<< "$verdict")
violated=$(jq -r '.replay.violated_at // empty' <<< "$verdict")
if [ -n "$refused" ]; then
  echo "the model refuses label $refused of $count: $(line_of "$refused")"
  exit 3
fi
if [ "$violated" = 0 ]; then
  echo "$(jq -r '.replay.violates[0]' <<< "$verdict") does not hold in the instance's initial states"
  exit 3
fi
if [ -n "$violated" ]; then
  echo "$(jq -r '.replay.violates[0]' <<< "$verdict") does not hold after label $violated of $count: $(line_of "$violated")"
  exit 3
fi
echo "the timeline ($count labels) is a run of the model, every property holding"
