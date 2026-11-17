#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# make.sh [<out dir>]: the inspection kit, for people who open bundles without this repository
# (docs/INSPECT.md): determinismo-inspect-kit-<commit>.tar.gz with only what an inspection machine
# needs, laid out as in the repository so the scripts find each other:
#   install.sh                       run as root on Debian 13 (x86-64 Intel, KVM)
#   infra/host/m0-check.sh           whether the CPU qualifies (VT-x features, the PMU's counts)
#   bench/pmu/count_repeat.c         its branch-count repeatability probe
#   infra/host/build-kvm.sh          our KVM modules, built for the running kernel
#   kernel/patches/*.patch           from the stock kernel's source and our patch (GPL)
#   infra/host/load-kvm.sh, kvm-at-boot.sh   loaded now and at every boot
#   infra/host/bundle-s3.sh          bundles from S3 (or share.sh's links script, no AWS)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$PWD}
. "$repo/infra/host/commit.sh"
commit=$(commit_of "$repo")
name=determinismo-inspect-kit-$commit
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name/infra/host" "$stage/$name/kernel/patches" "$stage/$name/bench/pmu"
cp "$here/install.sh" "$stage/$name/"
cp "$repo"/infra/host/{m0-check.sh,build-kvm.sh,load-kvm.sh,kvm-at-boot.sh,bundle-s3.sh} \
  "$stage/$name/infra/host/"
cp "$repo"/kernel/patches/*.patch "$stage/$name/kernel/patches/"
cp "$repo/bench/pmu/count_repeat.c" "$stage/$name/bench/pmu/"
echo "$commit" > "$stage/$name/COMMIT"
tar -C "$stage" -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
