#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs on the host as root. Idempotent. Usage: provision.sh <user>
set -euo pipefail
user=${1:?usage: $0 <user>}
export DEBIAN_FRONTEND=noninteractive

# The running kernel's flavor, kept: amd64 (srv4), or cloud-amd64 (Debian's cloud images, EC2's
# AMIs among them: KVM a module there too, 2026-11-07). Its headers: the newest on a first
# provisioning, then pinned (below); a later run asks for the running kernel's, since asking for
# the held meta-package once Debian has a newer kernel fails the install (srv4's deploy,
# 2026-11-07: 6.12.115 out, 6.12.113 running and held).
flavor=$(uname -r | cut -d- -f2-)
headers=linux-headers-$flavor
dpkg -s "$headers" >/dev/null 2>&1 && headers="linux-headers-$(uname -r)"

# A host booted by UEFI whose boot loader is grub-efi-amd64 (phoenixNAP's Debian, installed by
# curtin on an EFI-only disk) also carries the cloud image's grub-cloud-amd64, which installs a BIOS
# GRUB as well: impossible on that disk, so every upgrade of it failed the install (2026-11-08). Its
# own switch off (the enable_cloud flag its postinst reads), and a half-configured one finished.
if [ -d /sys/firmware/efi ] && dpkg -s grub-efi-amd64 >/dev/null 2>&1 && [ -e /etc/grub.d/enable_cloud ]; then
  rm /etc/grub.d/enable_cloud
  dpkg --configure -a
fi

apt-get update -q
apt-get -y -q full-upgrade
apt-get -y -q install \
  build-essential bc bison flex libelf-dev libssl-dev dwarves zstd \
  "$headers" linux-perf msr-tools cpuid numactl gdb \
  git curl rsync tmux htop sudo nftables unattended-upgrades \
  podman uidmap erofs-utils busybox-static e2fsck-static xz-utils cpio file default-jre-headless \
  openjdk-25-jre-headless clojure nodejs npm
# Node: the UI's check (tests/ui, Playwright; check.sh installs its packages and browser).
# OpenJDK 25 and Clojure (/usr/share/java): test programs in Clojure (sdk/clojure's
# determinismo.workload, one file each: tools/clojure_program.zig) run on the host for their
# --describe and checks, calling libdeterminismo through FFM (Java 22 on).

# The host kernel is pinned: our KVM modules are built against it.
apt-mark hold "linux-image-$flavor" "linux-headers-$flavor" >/dev/null

# TSX off (Intel's transactional memory: its aborts are not deterministic, and a guest must not
# see RTM), on CPUs with the switch for it (TSX_CTRL); one without it keeps TSX (GTHost's
# Skylake-SP Gold 6152, 2026-10-31), hidden from guests all the same (src/cpuid.zig), and
# m0-check.sh says so. Takes effect at the next boot: bootstrap.sh boots until the running
# kernel has it.
if ! grep -q 'tsx=off' /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 tsx=off"/' /etc/default/grub
  update-grub >/dev/null 2>&1
fi

if ! id "$user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo,kvm "$user"
fi
# A user there before (a cloud image's login user: EC2's admin) joins them too: without kvm its
# VMs could not open /dev/kvm (EACCES, 2026-11-07).
usermod --append --groups sudo,kvm "$user"
install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
# Root's keys for a user without keys of its own. A cloud image's login user keeps its own: root's
# there only say to log in as that user, so copying them would lock it out (EC2's admin).
[ -s "/home/$user/.ssh/authorized_keys" ] \
  || install -m 600 -o "$user" -g "$user" /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"
echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$user"
chmod 440 "/etc/sudoers.d/90-$user"
visudo -cq
