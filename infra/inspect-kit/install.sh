#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# install.sh <user>: makes this host open determinismo bundles. Run as root, from the unpacked kit
# (kept where it is, e.g. /opt: the boot loads our KVM from it),
# on Debian 13, x86-64 Intel with KVM (bare metal, or a VM with nested virtualization). Run it
# again after the boot it may ask for (TSX off, or the running kernel without headers).
#   1. packages: the kernel module build's, the CPU check's, mkfs.erofs (the explorer makes a
#      system's disk with it), the AWS CLI, zstd and podman (a
#      bundle's host checks build their services with it); the kernel pinned (our modules are
#      built for it; unattended upgrades leave it), TSX off; <user> in the kvm group. Nothing
#      else on the host changes (no users, sudo rules, SSH keys or firewall).
#   2. the CPU checked (m0-check.sh): VT-x features and the PMU's branch counts. ECC is reported
#      but not required: an inspection machine replays, it does not hunt.
#   3. our KVM modules built (build-kvm.sh, as <user>) from Debian's kernel source and
#      kernel/patches, loaded now and at every boot (determinismo-kvm.service).
# Then, as <user>: bundle-s3.sh pull ... (or share.sh's links script), and the bundle's
# ./INSPECT.sh '<command>'.
set -euo pipefail
user=${1:?usage: install.sh <user>}
kit=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "install.sh: run as root" >&2; exit 1; }
id "$user" >/dev/null 2>&1 || { echo "install.sh: no user $user" >&2; exit 1; }
grep -q GenuineIntel /proc/cpuinfo || { echo "install.sh: an Intel CPU is needed (our KVM patch is VT-x only)" >&2; exit 1; }
grep -qw vmx /proc/cpuinfo || { echo "install.sh: no VT-x here (on a VM: enable nested virtualization)" >&2; exit 1; }
. /etc/os-release
[ "$VERSION_CODENAME" = trixie ] || echo "install.sh: tested on Debian 13 (trixie), this is $PRETTY_NAME" >&2

echo "== packages"
export DEBIAN_FRONTEND=noninteractive
flavor=$(uname -r | cut -d- -f2-)
apt-get update -q
apt-get install -y -q build-essential bc bison flex libelf-dev libssl-dev dwarves zstd xz-utils \
  "linux-headers-$(uname -r)" git msr-tools cpuid podman uidmap awscli erofs-utils >/dev/null
apt-mark hold "linux-image-$flavor" "linux-headers-$flavor" >/dev/null
if [ -d /etc/apt/apt.conf.d ]; then
  echo 'Unattended-Upgrade::Package-Blacklist { "linux-"; };' > /etc/apt/apt.conf.d/52determinismo-inspect
fi
usermod --append --groups kvm "$user"
if ! grep -q tsx=off /proc/cmdline; then
  if ! grep -q 'tsx=off' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 tsx=off"/' /etc/default/grub
    update-grub >/dev/null 2>&1
  fi
  echo "== a boot is needed (tsx=off): reboot, then run install.sh $user again"
  exit 0
fi

echo "== the CPU"
check=$("$kit/infra/host/m0-check.sh" || true)
echo "$check"
if echo "$check" | grep ' FAIL ' | grep -qv 'ECC (EDAC)'; then
  echo "install.sh: this CPU does not qualify (the FAIL lines above)" >&2
  exit 1
fi

echo "== our KVM"
home=$(getent passwd "$user" | cut -d: -f6)
chown -R "$user:" "$kit"
sudo -u "$user" -H "$kit/infra/host/build-kvm.sh"
"$kit/infra/host/load-kvm.sh" "$home/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm"
"$kit/infra/host/kvm-at-boot.sh" "$user"
ln -sf "$kit/infra/host/bundle-s3.sh" /usr/local/bin/bundle-s3.sh
echo "== ready: as $user, bundle-s3.sh pull s3://<bucket>/<prefix> <bundle> ~/store ~/<bundle> (or a links script), then cd ~/<bundle> && ./INSPECT.sh '<command>'"
