#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Updates a set-up host's build in place, from your machine: the repository synced, the pinned
# tools installed (tools.sh), determinismo and the guest's initramfs rebuilt, and serve restarted
# on the new build with its runs left running (a run keeps the binary it started with; new runs,
# replays and serve itself use the new one). A change to the KVM patch needs setup.sh, which stops
# serve and its runs.
# The guest kernel and its module (det_guest.ko) are rebuilt on a host with the guest kernel's
# tree (~/guest-kernel, from guest/kernel/build.sh: new patches applied, only what changed
# compiled); a host without one takes vmlinuz and the module from another, updated first:
# --guest-from <user@host>.
# determinismo's phases are built here (--build-on here: this machine cross-compiles them for
# x86_64-linux-musl and ships the binaries, srv4's 120 s release build of determinismo 35 s on an
# M3 Max, its upload 2 s) when DuckDB's x86_64-musl libraries are here ($DETERMINISMO_DUCKDB or
# ~/opt/duckdb-x86_64-musl, copied once from a host's ~/opt/duckdb); else on the host
# (--build-on host). The guest kernel and the initramfs are always built on the host.
# Usage: infra/host/update.sh <ip> [--user <user>] [--guest-from <user@host>] [--build-on here|host]
set -euo pipefail

ip=${1:?usage: $0 <ip> [--user <user>] [--guest-from <user@host>]}
shift
user=det
guest_from=
duckdb_here=${DETERMINISMO_DUCKDB:-$HOME/opt/duckdb-x86_64-musl}
build_on=host
[ -f "$duckdb_here/libduckdb_static.a" ] && build_on=here
while [ $# -gt 0 ]; do
  case $1 in
    --user) user=$2 ;;
    --guest-from) guest_from=$2 ;;
    --build-on) build_on=$2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
repo=$(cd "$(dirname "$0")/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)

# The tree as it is when the deploy starts, frozen in a copy of its own (8 s, 1.2 GB, removed
# at exit; its build uses the repository's cache): what is built and shipped, so an edit made
# while the deploy runs never ships (2026-11-08: schema.zig, edited during the build, reached
# the host half-written after it; every workload build failed and the hunt queue skipped 12
# hunts).
. "$repo/infra/host/commit.sh"
commit=$(commit_of "$repo")
frozen=$(mktemp -d "${TMPDIR:-/tmp}/determinismo-deploy.XXXXXX")
trap 'rm -rf "$frozen"' EXIT
echo "== the tree, frozen at $commit"
rsync -a --exclude-from "$repo/infra/host/rsync-excludes" "$repo/" "$frozen/"

if [ "$build_on" = here ]; then
  echo "== the build, here"
  # Its own install directory: only the phases' binaries are shipped (never a workload built
  # here earlier), over the host's (its workloads, which the hunt queue builds, stay).
  rm -rf "$frozen/zig-out-ship"
  # The repository's cache (keyed by content): a second one would take gigabytes of a disk
  # that filled up once (2026-11-08).
  (cd "$frozen" && zig build determinismo guest selftest -Drelease -Dduckdb="$duckdb_here" -Dcommit="$commit" \
    --cache-dir "$repo/.zig-cache" -p zig-out-ship)
fi
echo "== the repository"
rsync -az -e "ssh ${ssh_opts[*]}" --exclude-from "$repo/infra/host/rsync-excludes" \
  "$frozen/" "$user@$ip:determinismo/"
if [ "$build_on" = here ]; then
  echo "== the binaries"
  rsync -az -e "ssh ${ssh_opts[*]}" "$frozen/zig-out-ship/bin/" "$user@$ip:determinismo/zig-out/bin/"
fi

if [ -n "$guest_from" ]; then
  echo "== the guest, from $guest_from"
  ssh "${ssh_opts[@]}" "$guest_from" 'tar -C ~/guest -c vmlinuz det_guest.ko' \
    | ssh "${ssh_opts[@]}" "$user@$ip" 'mkdir -p ~/guest && tar -C ~/guest -x'
fi

# jank's rolling package, from your machine's kept copy (tools-ship.sh).
"$repo/infra/host/tools-ship.sh" "$user@$ip" "${ssh_opts[@]}"
ssh "${ssh_opts[@]}" "$user@$ip" env BUILD_ON="$build_on" bash -s <<'EOF'
set -euo pipefail
cd ~/determinismo
# KVM as built (build-kvm.sh: the patch over a committed base) is the patch in the repository:
# else setup.sh, which rebuilds and reloads it. Compared by what they change: blob hashes and
# hunk line numbers differ on another point release's base (a host on 6.12.116, the patch cut
# on 6.12.115: the same patch, refused).
kvm_tree=~/kvm-build/linux-$(uname -r | cut -d+ -f1)
changes() { grep -v '^index ' | sed -E 's/^@@ [^@]* @@/@@/'; }
if ! diff -q <(cd "$kvm_tree" && git diff -- arch/x86/kvm arch/x86/include virt/kvm include | changes) \
             <(sed '1,4d' kernel/patches/0001-kvm-determinismo.patch | changes) >/dev/null 2>&1; then
  echo "error: kernel/patches is not the KVM built here: run setup.sh" >&2
  exit 1
fi
echo "== the tools"
infra/host/tools.sh
echo "== the build"
# On the reserved cores: the runs' are a hunt's alone (isolate.sh). determinismo's phases are
# built on your machine (--build-on here); the host builds the initramfs, and the guest kernel
# only when it changed. 16 jobs at most: each compile takes a few GB.
jobs=(-j16)
kernel_tree=~/guest-kernel/linux-source-6.12
if [ -d "$kernel_tree" ]; then
  guest/kernel/build.sh ~/guest > /dev/null
fi
# determinismo's phases; each hunt's workload is built as the hunt queue starts it
# (hunt-queue.sh's workload_build): an SDK change rebuilt all ~50 workloads on every deploy.
# Built and shipped by the machine updating it (--build-on here): nothing to compile here.
if [ "$BUILD_ON" = host ]; then
  ~/opt/zig/zig build determinismo guest selftest -Drelease "${jobs[@]}"
fi
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko \
  --busybox /usr/bin/busybox --e2fsck /sbin/e2fsck.static --out ~/guest/base.cpio
if systemctl is-active --quiet determinismo-serve.service; then
  # The unit as serve.sh writes it now (its runs outlive a restart), then the new build.
  sudo infra/host/serve.sh "$USER" start
fi
echo "== serve: $(systemctl is-active determinismo-serve.service || true)"
# Elle's service, rebuilt when checkers/elle changed and nothing runs (elle-image.sh).
infra/host/elle-image.sh
EOF
echo "== $ip updated"
