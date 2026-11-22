#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs e2e checks on a set-up host, from your machine, beside its hunts: the repository synced to
# a check tree on the host (~/determinismo-check), determinismo's phases, the e2e runner and the
# workloads it runs built here (release, cross-compiled: 26 s on an M3 Max where srv4's busy cores
# took minutes) and shipped, the initramfs built on the host from them (with the host's guest
# kernel and module, or with --kernel the repository's guest/kernel built into the check's own
# guest directory, in a kernel tree of its own), then each check in a unit on every CPU at a low weight (20: the hunts keep
# precedence) with its memory capped. Each check's verdict printed; exit 1 when one failed.
# Without DuckDB's x86_64-musl libraries here ($DETERMINISMO_DUCKDB or ~/opt/duckdb-x86_64-musl),
# the host builds instead (--build-on host).
# Usage: infra/host/check.sh <ip> <check>... [--user <user>] [--kernel] [--build-on here|host]
#          [--tree <name>] [--cpus <list>]
# --cpus: the CPUs the checks run on, instead of the host's reserved ones (a host shared with
# someone whose work has those: the checks on the CPUs agreed).
set -euo pipefail

ip=${1:?usage: $0 <ip> <check>... [--user <user>] [--kernel] [--build-on here|host] [--tree <name>] [--cpus <list>]}
shift
user=det
kernel=0
# The tree on the host the checks run in (and <tree>-guest beside it): one a session, never two
# runs in one (they overwrite each other's binaries, guest and logs: 2026-11-11, two sessions).
tree=determinismo-check
cpus_given=
duckdb_here=${DETERMINISMO_DUCKDB:-$HOME/opt/duckdb-x86_64-musl}
build_on=host
[ -f "$duckdb_here/libduckdb_static.a" ] && build_on=here
checks=()
while [ $# -gt 0 ]; do
  case $1 in
    --user) user=$2; shift ;;
    --kernel) kernel=1 ;;
    --build-on) build_on=$2; shift ;;
    --tree) tree=$2; shift ;;
    --cpus) cpus_given=$2; shift ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) checks+=("$1") ;;
  esac
  shift
done
[ ${#checks[@]} -gt 0 ] || { echo "error: no check named" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
# What the e2e checks run: determinismo's phases (the runner among the self-tests) and the
# workloads its checks name (build.zig's e2e_workloads).
steps=(determinismo guest selftest bank-test shop-test clojure-bank-test k3s-test race-test nrepl-test etcd-raft-joint-test)

if [ "$build_on" = here ]; then
  echo "== the build, here"
  rm -rf "$repo/zig-out-check"
  . "$repo/infra/host/commit.sh"
  (cd "$repo" && zig build "${steps[@]}" -Drelease -Dduckdb="$duckdb_here" -Dcommit="$(commit_of "$repo")" -p zig-out-check)
fi
echo "== the repository"
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude-from "$repo/infra/host/rsync-excludes" \
  "$repo/" "$user@$ip:$tree/"
if [ "$build_on" = here ]; then
  echo "== the binaries"
  ssh "${ssh_opts[@]}" "$user@$ip" mkdir -p "$tree/zig-out/bin"
  rsync -az --delete -e "ssh ${ssh_opts[*]}" "$repo/zig-out-check/bin/" "$user@$ip:$tree/zig-out/bin/"
fi

# Quoted for the host's shell: ssh joins its arguments into one command line.
ssh "${ssh_opts[@]}" "$user@$ip" "env BUILD_ON=$(printf %q "$build_on") KERNEL=$kernel TREE=$(printf %q "$tree") CPUS=$(printf %q "$cpus_given")" \
  "STEPS=$(printf %q "${steps[*]}") CHECKS=$(printf %q "${checks[*]}") bash -s" <<'EOF'
set -euo pipefail
cd ~/"$TREE"
guest=~/"$TREE"-guest
mkdir -p "$guest"
# On the reserved CPUs (own-cpus.sh): the runs' cores are theirs alone (isolate.sh), their
# siblings too (sharing a hunt's physical cores cost Conductor's run 443 40% of its timelines).
# A host without reserved cores (serve on every CPU: a small rented machine, a user's own) has no
# hunt's cores to keep apart: the checks take every CPU, at their low weight still, and say so.
if [ -n "$CPUS" ]; then
  cpus=$CPUS
elif ! cpus=$(infra/host/own-cpus.sh 2>/dev/null); then
  cpus=0-$(( $(nproc --all) - 1 ))
  echo "== no reserved CPUs here: the checks run on all of them ($cpus), beside any run at weight 20"
fi
# OOMPolicy: a VM the kernel's OOM killer takes is the check's to judge, not a reason for systemd to
# stop the unit (its default; trial.sh's run 689, 2026-11-02).
# taskset beside AllowedCPUs: on a host with reserved cores every service is given them by a
# drop-in for all services (isolate.sh's service.d), and systemd merges that list with a unit's
# own: a unit asked onto other CPUs is allowed both (checks asked onto 3-5 of a shared host ran on
# 0-5, their VMs on the neighbour's cores, 2026-11-17). The command's own affinity is what its
# children inherit and what the CPU pool reads (cpus.zig: the CPUs a process was given).
run() { sudo -n systemd-run --uid="$USER" --gid="$(id -g)" --quiet --wait --collect --pipe \
  -p AllowedCPUs="$cpus" -p CPUWeight=20 -p MemoryMax=24G -p OOMPolicy=continue \
  --working-directory="$PWD" taskset -c "$cpus" "$@"; }
# Read back before anything runs: what a process of the checks' unit is allowed.
allowed=$(run grep Cpus_allowed_list /proc/self/status < /dev/null | cut -f2) || allowed=
if ! python3 -c 'import sys
cpus = lambda text: {cpu for part in text.split(",") for cpu in range(int(part.split("-")[0]), int(part.split("-")[-1]) + 1)}
sys.exit(0 if sys.argv[2] and cpus(sys.argv[2]) <= cpus(sys.argv[1]) else 1)' "$cpus" "$allowed"; then
  echo "error: the checks' unit may run on CPUs '$allowed', not within '$cpus': nothing was run" >&2
  exit 2
fi
echo "== the checks' CPUs: $allowed"
if [ "$BUILD_ON" = host ]; then
  echo "== the build, on the host"
  run ~/opt/zig/zig build $STEPS -Drelease
fi
if [ "$KERNEL" = 1 ]; then
  echo "== the guest kernel"
  # In a kernel tree of the check's own (<tree>-kernel), begun as a copy of the host's (what
  # changed is all that compiles): a branch's patch applied to the host's tree made the next
  # deploy from main start that tree again from the source (build.sh: a series that does not
  # extend the tree's), and two trees' checks would have patched one tree.
  kernel_tree=~/"$TREE"-kernel
  if [ ! -d "$kernel_tree" ] && [ -d ~/guest-kernel ]; then cp -a ~/guest-kernel "$kernel_tree"; fi
  started=$(date +%s)
  run env DETERMINISMO_GUEST_KERNEL="$kernel_tree" "$PWD/guest/kernel/build.sh" "$guest" > /dev/null
  echo "== the guest kernel built in $(( $(date +%s) - started )) s"
else
  cp ~/guest/vmlinuz ~/guest/det_guest.ko "$guest/"
fi
run "$PWD/zig-out/bin/det-initramfs" --bin zig-out/bin --module "$guest/det_guest.ko" \
  --busybox /usr/bin/busybox --e2fsck /sbin/e2fsck.static --out "$guest/base.cpio" > /dev/null
# The UI's check (tests/ui: Playwright, in a browser against a serve of the check's own). Its
# packages live in this tree (node_modules, kept through the syncs) and its browser in the
# user's cache: made here when missing or behind the lock file, with the browser's system
# libraries (root, once a host), and Node itself on a host set up before provision.sh had it.
# Without them the check said SKIP, on every host, and the page was checked by hand
# (2026-11-14: a night's work on the run's page).
case " $CHECKS " in *" ui "*)
  command -v npm >/dev/null || sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -q nodejs npm >/dev/null
  if ! cmp -s tests/ui/package-lock.json tests/ui/node_modules/.lock-installed 2>/dev/null; then
    echo "== the UI check's packages and browser"
    (cd tests/ui && run npm ci --no-audit --no-fund >/dev/null)
    (cd tests/ui && sudo -n npx playwright install-deps chromium >/dev/null)
    (cd tests/ui && run npx playwright install chromium >/dev/null)
    cp tests/ui/package-lock.json tests/ui/node_modules/.lock-installed
  fi ;;
esac
# Babashka for the checks that evaluate Clojure (serve's notebook cells, the REPL's client): the
# host's own (tools.sh). Without it they said SKIP on every host (2026-11-18: each serve check).
bb=~/opt/bb/bb
[ -x "$bb" ] || bb=
# jank too, the viz's runtime: the client's check runs under both (tools.sh installs it).
jank=~/opt/jank/usr/local/bin/jank
[ -x "$jank" ] || jank=
failed=0
# The checks' runs of 3 days ago and before: each check leaves its runs (39 GB of them,
# 2026-11-06), never read again once its verdict was printed.
find .zig-cache/e2e-runs/runs -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
for check in $CHECKS; do
  start=$(date +%s)
  status=0
  # Its runs in a store of its own.
  run env DETERMINISMO_DATA=.zig-cache/e2e-runs \
    zig-out/bin/e2e --guest "$guest" --only "$check" ${bb:+--bb "$bb"} ${jank:+--jank "$jank"} > "check-$check.log" 2>&1 || status=$?
  # Passed only with e2e's own verdict: a check whose unit was stopped from outside ends on
  # SIGTERM, which systemd counts as a clean exit (status 0). On 2026-11-22 a hold check
  # stopped by hand after 21 minutes, one timeline still running, said "exit 0".
  if [ $status -eq 0 ] && ! grep -aq "^e2e: all checks passed" "check-$check.log"; then
    echo "  no verdict: the check ended without e2e's (stopped from outside?)" >> "check-$check.log"
    status=1
  fi
  echo "== $check: exit $status in $(( $(date +%s) - start )) s"
  grep -aE "^(FAIL|SKIP)|^  failed:|^  no verdict:|all checks passed" "check-$check.log" | head -20 || true
  [ $status -eq 0 ] || failed=1
done
exit $failed
EOF
