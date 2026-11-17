#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the guest kernel from the Debian linux-source tarball (the host kernel's version) with
# guest/kernel/patches applied and x86_64_defconfig plus guest/kernel/determinismo.config, and
# det_guest.ko against it.
# Runs on the Linux host. Usage: guest/kernel/build.sh <out-dir>
# The kernel's tree: ~/guest-kernel, or $DETERMINISMO_GUEST_KERNEL (a check's own: check.sh).
set -euo pipefail
out=${1:?usage: $0 <out-dir>}
here=$(cd "$(dirname "$0")" && pwd)
version=6.12
tarball=/usr/src/linux-source-$version.tar.xz
[ -f "$tarball" ] || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q linux-source-$version
work=${DETERMINISMO_GUEST_KERNEL:-$HOME/guest-kernel}
mkdir -p "$work" "$out"
tree="$work/linux-source-$version"
# The patches the tree has, in order (their hashes, `.det-patches`): the series now must extend
# them, or the tree starts again from the pristine source (a patch changed or removed: applied
# over its old version it would fail, or leave the old code in). A tree with no record is
# started again too.
series=$(cd "$here/patches" && sha256sum -- *.patch)
applied=$(cat "$tree/.det-patches" 2>/dev/null || true)
case $series in
  "$applied"*) [ -n "$applied" ] || [ ! -d "$tree" ] || rm -rf "$tree" ;;
  *) rm -rf "$tree" ;;
esac
if [ ! -d "$tree" ]; then
  tar -xJf "$tarball" -C "$work"
  : > "$tree/.det-patches"
fi
cd "$tree"
# guest/kernel/patches/*.patch, the ones the tree does not have yet, in order.
while read -r hash name; do
  grep -q "^$hash  $name\$" .det-patches && continue
  patch -p1 -s --no-backup-if-mismatch < "$here/patches/$name"
  echo "$hash  $name" >> .det-patches
done <<< "$series"
make -s x86_64_defconfig
scripts/kconfig/merge_config.sh -m -O . .config "$here/determinismo.config" >/dev/null
make -s olddefconfig
# Every option of the fragment must have survived (dependencies can silently drop some).
missing=0
while read -r line; do
  case $line in CONFIG_*=*) grep -qx "$line" .config || { echo "missing: $line" >&2; missing=1; } ;; esac
done < "$here/determinismo.config"
[ $missing -eq 0 ] || exit 1
make -s -j"$(nproc)" bzImage modules # modules: also writes Module.symvers
cp arch/x86/boot/bzImage "$out/vmlinuz"
make -s -C "$here/../module" KDIR="$PWD" clean all
cp "$here/../module/det_guest.ko" "$out/det_guest.ko"
ls -la "$out"
