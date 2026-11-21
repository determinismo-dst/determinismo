#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Sets up a determinismo host from your machine, in one go: from a Hetzner box in its rescue
# system (or one installed already) to a checked host. Debian, provisioning and hardening, the
# repository, the toolchain, hardware qualification, our KVM (loaded at every boot), the guest,
# the build, an end-to-end check, and serve (a unit). Idempotent: run it again after a failure,
# or to update (which stops serve and its runs first).
# Usage: infra/host/setup.sh <ip> [--user <user>] [--hostname <name>] [--guest-from <user@host>]
#                             [--reserved-cores N] [--inspect]
#   --inspect: a machine that only opens bundles (infra/aws/inspect.sh): up to our KVM, then the
#   AWS CLI, zstd and podman (a bundle's host checks start their services from its checkers/); no guest, build, end-to-end check or serve (a bundle carries its guest, its
#   system and the run's own explorer).
#   --guest-from: the guest kernel and module copied from that host instead of built here, so
#   every host runs the same guest (the same run inputs, for replays across hosts).
#   --reserved-cores: N cores for your own sessions, the rest for runs (serve.sh); kept for the
#   next setup or update. Default: as before, or 0 (runs take every core).
set -euo pipefail

ip=${1:?usage: $0 <ip> [--user <user>] [--hostname <name>] [--guest-from <user@host>] [--reserved-cores N] [--inspect]}
shift
user=det
hostname=determinismo
guest_from=
reserved=
inspect=false
while [ $# -gt 0 ]; do
  case $1 in
    --inspect) inspect=true; shift; continue ;;
    --user) user=$2 ;;
    --hostname) hostname=$2 ;;
    --guest-from) guest_from=$2 ;;
    --reserved-cores) reserved=$2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

echo "== waiting for $ip to accept SSH"
# The user first, root only when it cannot log in: each refused login counts toward OpenSSH's
# per-source penalties (Debian 13's), which then turn every connection away ("Not allowed at this
# time") for up to 10 minutes: root probes did it on a phoenixNAP server, root not allowed there
# (2026-11-08).
# At most 30 minutes, and SSH's own error said when it is not a wait (a changed host key: the
# address was another machine's before, `ssh-keygen -R <ip>`; a refused key): a phoenixNAP server
# on a reused address waited silently for 40 minutes (2026-11-10).
user_login=false
waited=0
until { ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null && user_login=true; } \
   || ssh "${ssh_opts[@]}" "root@$ip" true 2>/dev/null; do
  # Its error line only: under pipefail the failed ssh would end the script at its first try
  # (an EC2 machine still booting, 2026-11-21: setup gave up in 30 s).
  last=$(ssh "${ssh_opts[@]}" "$user@$ip" true 2>&1 | tail -1 || true)
  case $last in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      echo "error: $ip's host key changed (an address used before): ssh-keygen -R $ip, then again" >&2; exit 1 ;;
  esac
  [ "$waited" -lt 1800 ] || { echo "error: $ip never accepted SSH in 30 minutes: $last" >&2; exit 1; }
  sleep 30
  waited=$((waited + 30))
done

if ! $user_login && ssh "${ssh_opts[@]}" "root@$ip" 'test -x /root/.oldroot/nfs/install/installimage' 2>/dev/null; then
  echo "== installing Debian (rescue system)"
  "$repo/infra/hetzner/install-os.sh" "$ip" "$hostname"
  sleep 60 # The reboot begins.
fi

echo "== provisioning and hardening"
"$here/bootstrap.sh" "$ip" "$user"

echo "== the repository"
# update.sh's excludes: a list of setup's own missed the other build outputs (zig-out-trial's
# 22 GB went up to an EC2 instance, 2026-11-07).
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude-from "$repo/infra/host/rsync-excludes" \
  "$repo/" "$user@$ip:determinismo/"

if [ -n "$guest_from" ] && ! $inspect; then
  echo "== the guest, from $guest_from"
  ssh "${ssh_opts[@]}" "$guest_from" 'tar -C ~/guest -c vmlinuz det_guest.ko' \
    | ssh "${ssh_opts[@]}" "$user@$ip" 'mkdir -p ~/guest && tar -C ~/guest -x'
fi

# The build stamps the commit into each run, as update.sh's (the host's copy has no .git).
. "$repo/infra/host/commit.sh"
commit=$(commit_of "$repo")
# Quoted for the remote shell: ssh joins its arguments into one command line, where an empty
# --reserved-cores vanished and the commit took its place (an EC2 setup, 2026-11-07).
# jank's rolling package, from your machine's kept copy (tools-ship.sh).
"$repo/infra/host/tools-ship.sh" "$user@$ip" "${ssh_opts[@]}"
ssh "${ssh_opts[@]}" "$user@$ip" "bash -s -- $(printf '%q ' "$reserved" "$commit" "$inspect")" <<'EOF'
set -euo pipefail
reserved=${1:-}
commit=${2:-unknown}
inspect=${3:-false}
cd ~/determinismo
echo "== serve stopped (and its runs): the build and KVM change under them"
sudo infra/host/serve.sh "$USER" stop
# With serve stopped, the runs' reserved cores are idle: what follows runs on every CPU, in a unit
# of its own whose AllowedCPUs merges with isolate.sh's reservation (a session is confined to the
# own CPUs: m0-check's taskset to a run CPU failed, and the build took 8 CPUs of 48, 2026-11-07).
everywhere() {
  sudo systemd-run --quiet --wait --pipe --collect --uid="$(id -u)" --gid="$(id -g)" \
    -p "AllowedCPUs=0-$(( $(nproc --all) - 1 ))" --working-directory="$PWD" \
    --setenv=HOME="$HOME" --setenv=PATH="$PATH" "$@"
}
echo "== toolchain"
infra/host/tools.sh
echo "== hardware qualification"
sudo systemd-run --quiet --wait --pipe --collect -p "AllowedCPUs=0-$(( $(nproc --all) - 1 ))" \
  --working-directory="$PWD" infra/host/m0-check.sh # As root, on every CPU.
echo "== our KVM"
everywhere infra/host/build-kvm.sh
# Loaded unless this very build is (load-kvm.sh records its hashes): a patch changed, it is
# reloaded, which needs every VM stopped (load-kvm.sh says so otherwise).
kvm_build=~/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm
built=$(sha256sum "$kvm_build/kvm.ko" "$kvm_build/kvm-intel.ko" | cut -d' ' -f1)
[ "$built" = "$(cat /run/determinismo-kvm 2>/dev/null)" ] || sudo infra/host/load-kvm.sh
sudo infra/host/kvm-at-boot.sh "$USER"
if $inspect; then
  echo "== for bundles: the AWS CLI and zstd"
  sudo apt-get install -y -q awscli zstd >/dev/null
  # Podman: a bundle carries its host checks' services' sources (checkers/), which its checks
  # build and start in its directory as they need them, as on the recording host.
  echo "== podman, for the bundles' host checks"
  command -v podman >/dev/null || sudo apt-get install -y -q podman >/dev/null
  exit 0
fi
echo "== the guest and the build"
[ -f ~/guest/vmlinuz ] && [ -f ~/guest/det_guest.ko ] || everywhere guest/kernel/build.sh ~/guest
# determinismo's phases only, as update.sh builds: a hunt builds its workload as it starts (the
# whole tree, every workload, took srv4's setup most of its time, 2026-11-07).
everywhere ~/opt/zig/zig build determinismo guest selftest -Drelease -Dcommit="$commit"
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko \
  --busybox /usr/bin/busybox --e2fsck /sbin/e2fsck.static --out ~/guest/base.cpio
echo "== end-to-end check"
everywhere ~/opt/zig/zig build e2e -Drelease -Donly=bank
echo "== serve"
sudo infra/host/serve.sh "$USER" start ${reserved:+--reserved-cores "$reserved"}
EOF
if $inspect; then
  echo "== $ip opens bundles ($user@$ip)"
else
  echo "== $ip is a determinismo host ($user@$ip)"
fi
