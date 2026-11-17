#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# trace.sh <serve's URL> <run> <timeline> <spec.qnt> [--main <module>] [--invariant <name>]
#          [--quint <command>]
# A timeline of a run checked against a Quint spec kept on this machine (docs/QUINT.md), with
# no determinismo here: serve gives the timeline's own events as a run of the spec's actions,
# written beside the spec (determinismo_trace.qnt); Quint runs it here; serve says what its
# result means. As `determinismo quint` where the run is: exit 0 the trace is a behavior of
# the spec, 3 it is not (the first event the spec refuses, or the one after which the invariant
# fails, with the spec's state there), 1 nothing could be checked.
# Needs curl, jq and Quint (`npm install -g @informalsystems/quint`).
#   clients/quint/trace.sh http://127.0.0.1:7878 12 3 examples/bank/quint/bank.qnt --invariant total_conserved
set -euo pipefail
usage="usage: $0 <serve's URL> <run> <timeline> <spec.qnt> [--main <module>] [--invariant <name>] [--quint <command>]"
serve=${1:?$usage}; run=${2:?$usage}; timeline=${3:?$usage}; spec=${4:?$usage}
shift 4
file=$(basename "$spec" .qnt)
main=$file
invariant=
quint=${QUINT:-quint}
while [ $# -gt 0 ]; do
  case $1 in
    --main) main=${2:?$usage} ;;
    --invariant) invariant=${2:?$usage} ;;
    --quint) quint=${2:?$usage} ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2
done
directory=$(dirname "$spec")
ask() { curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' --data-binary @- "$serve/runs/$run/quint"; }
request=$(jq -n --rawfile spec "$spec" --arg main "$main" --arg file "$file" --arg invariant "$invariant" \
  --argjson branch "$timeline" \
  '{branch: $branch, spec: $spec, main: $main, file: $file} + (if $invariant == "" then {} else {invariant: $invariant} end)')
reply=$(ask <<< "$request")
events=$(jq -r .events <<< "$reply")
if [ "$events" = 0 ]; then
  echo "no event of timeline $timeline is named like an action of $spec ($(jq -r .unnamed <<< "$reply") events under other names):"
  jq -r '.kinds[] | "  \(.count) \(.name) \(.example)"' <<< "$reply"
  exit 1
fi
jq -r .module <<< "$reply" > "$directory/$(jq -r .file <<< "$reply")"
states=$directory/$(jq -r .states <<< "$reply")
rm -f "$states"
passed=true
# $quint may be several words ("npx -y @informalsystems/quint").
(cd "$directory" && $quint test determinismo_trace.qnt --main determinismo_trace \
  --match '^determinismo_trace_run$' --max-samples 1 --out-itf determinismo_trace.itf.json) \
  > "$directory/determinismo_trace.out" 2>&1 || passed=false
# The states Quint wrote, each but the last whole one (the spec's state where the run stopped)
# as a mark that it is there: serve needs their count, not megabytes of them.
if [ -s "$states" ]; then
  marks=$(jq -c '.states |= (
      (map(length > 1) | index(false) // length) as $whole
      | to_entries
      | map(if (.value | length) > 1 and .key != $whole - 1 then {"#meta": .value["#meta"], seen: true} else .value end))
    | {states: .states}' "$states")
else
  marks=null
  cat "$directory/determinismo_trace.out" >&2
fi
verdict=$(jq -n --argjson request "$request" --argjson passed "$passed" --argjson states "$marks" \
  '$request + {passed: $passed, states: $states}' | ask)
jq -r .text <<< "$verdict"
exit "$(jq -r .status <<< "$verdict")"
