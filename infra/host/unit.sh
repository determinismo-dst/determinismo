#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# unit.sh <ip> [<pattern>...]: the unit tests (they use Linux's system calls) built here
# (`zig build tests`, cross-compiled) and run on a Linux host beside its hunts: the repository
# synced to ~/determinismo-unit (tests read files of it), each test binary whose name matches a
# pattern (a substring of its root's path, slashes as dashes: kafka, sdk-zig, src-main; all of
# them without one) run there in one low-weight unit, memory capped. Each binary's verdict
# printed; exit 1 when one failed. Without DuckDB's x86_64-musl libraries here
# ($DETERMINISMO_DUCKDB or ~/opt/duckdb-x86_64-musl) src/main.zig's tests cannot link: the others
# still build (pass patterns that leave it out).
#   infra/host/unit.sh <ip> kafka sdk-zig
# --cpus <list>: the CPUs the tests run on, instead of the host's reserved ones (a host shared
# by cores with someone whose work has those), as check.sh's.
set -euo pipefail

usage="usage: $0 <ip> [<pattern>...] [--user <user>] [--cpus <list>]"
ip=${1:?$usage}
shift
user=det
cpus_given=
patterns=()
while [ $# -gt 0 ]; do
  case $1 in
    --user) user=$2; shift ;;
    --cpus) cpus_given=$2; shift ;;
    -*) echo "error: unknown option $1 ($usage)" >&2; exit 2 ;;
    *) patterns+=("$1") ;;
  esac
  shift
done
repo=$(cd "$(dirname "$0")/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
duckdb=${DETERMINISMO_DUCKDB:-$HOME/opt/duckdb-x86_64-musl}
duckdb_option=()
[ -d "$duckdb" ] && duckdb_option=(-Dduckdb="$duckdb")

rm -rf "$repo/zig-out-unit"
(cd "$repo" && zig build tests ${duckdb_option[@]+"${duckdb_option[@]}"} -p zig-out-unit)
chosen=()
for binary in "$repo"/zig-out-unit/tests/*; do
  name=$(basename "$binary")
  if [ ${#patterns[@]} -eq 0 ]; then
    chosen+=("$name")
    continue
  fi
  for pattern in "${patterns[@]}"; do
    case $name in *"$pattern"*) chosen+=("$name"); break ;; esac
  done
done
[ ${#chosen[@]} -gt 0 ] || { echo "error: no unit test matches ${patterns[*]}" >&2; exit 2; }
ssh "${ssh_opts[@]}" "$user@$ip" mkdir -p determinismo-unit
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude-from "$repo/infra/host/rsync-excludes" \
  "$repo/" "$user@$ip:determinismo-unit/"
ssh "${ssh_opts[@]}" "$user@$ip" mkdir -p determinismo-unit/zig-out-unit
rsync -az --delete -e "ssh ${ssh_opts[*]}" "$repo/zig-out-unit/tests/" "$user@$ip:determinismo-unit/zig-out-unit/tests/"
# Shipped: the local build goes (1.2 GB a build; the Mac's disk filled on 2026-11-08).
rm -rf "$repo/zig-out-unit"
# Each binary run in turn in one unit; its last lines and its verdict, then the count failed.
ssh "${ssh_opts[@]}" "$user@$ip" "env CPUS=$(printf %q "$cpus_given") bash -s -- $(printf '%q ' "${chosen[@]}")" <<'EOF'
set -uo pipefail
cd ~/determinismo-unit
cat > zig-out-unit/run.sh <<'RUN'
failed=0
for name in "$@"; do
  output=$(timeout 600 "zig-out-unit/tests/$name" 2>&1)
  status=$?
  if [ $status = 0 ]; then
    echo "PASS $name: $(echo "$output" | grep -E 'passed|All [0-9]+ tests' | tail -1)"
  else
    echo "FAIL $name (exit $status):"
    # Each failing test and its first lines (a long binary's failure is far above its tail).
    echo "$output" | grep -B14 -A3 -E '^FAIL \(|\.\.\.FAIL' | head -60 | sed 's/^/  /'
    # A test that panicked (exit 134): the panic and the test running then, which the tail of
    # its stack trace never names.
    echo "$output" | grep -B2 -A8 -E 'panic: |reached unreachable' | head -40 | sed 's/^/  /'
    echo "$output" | tail -3 | sed 's/^/  /'
    failed=$((failed + 1))
  fi
done
exit $failed
RUN
cpus=${CPUS:-$(infra/host/own-cpus.sh)}
# Through taskset, its CPUs read back first, as check.sh's units (a unit's AllowedCPUs is merged
# with the reserved cores' drop-in for all services: alone it does not confine).
run() { sudo -n systemd-run --uid="$USER" --gid="$(id -g)" --quiet --wait --pipe --collect \
  -p AllowedCPUs="$cpus" -p CPUWeight=20 -p MemoryMax=16G \
  --working-directory="$PWD" taskset -c "$cpus" "$@"; }
allowed=$(run grep Cpus_allowed_list /proc/self/status < /dev/null | cut -f2) || allowed=
if ! python3 -c 'import sys
cpus = lambda text: {cpu for part in text.split(",") for cpu in range(int(part.split("-")[0]), int(part.split("-")[-1]) + 1)}
sys.exit(0 if sys.argv[2] and cpus(sys.argv[2]) <= cpus(sys.argv[1]) else 1)' "$cpus" "$allowed"; then
  echo "error: the tests' unit may run on CPUs '$allowed', not within '$cpus': nothing was run" >&2
  exit 2
fi
echo "== the tests' CPUs: $allowed"
status=0
run /bin/bash zig-out-unit/run.sh "$@" < /dev/null || status=$?
exit $status
EOF
