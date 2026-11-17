#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Ships the toolchain's rolling downloads from this machine's cache to a host's ~/opt, where
# tools.sh's fetch finds them already there with their pinned checksum: jank's Ubuntu package is
# republished under the same name several times a day (2026-11-11: 18:46 and 22:07 UTC, each
# rebuild failing every new host's setup at its pin). The copy is kept here by its checksum, made
# once when the pin is set, and outlives jank's rebuilds. setup.sh and update.sh run this first.
# Usage: infra/host/tools-ship.sh <user@host> [ssh options...]
set -euo pipefail
target=${1:?usage: $0 <user@host> [ssh options...]}
shift
repo=$(cd "$(dirname "$0")/../.." && pwd)
deb=$(sed -n 's/^jank_deb=//p' "$repo/infra/host/tools.sh")
sha=$(sed -n 's/^jank_sha256=//p' "$repo/infra/host/tools.sh")
[ -n "$deb" ] && [ -n "$sha" ] || { echo "error: no jank pin in infra/host/tools.sh" >&2; exit 1; }
cache=${DETERMINISMO_TOOLS_CACHE:-$HOME/.cache/determinismo-tools}
mkdir -p "$cache"
kept="$cache/$sha.deb"
if ! { [ -f "$kept" ] && echo "$sha  $kept" | shasum -a 256 -c --status; }; then
  curl -fsSL -o "$kept.part" "https://ppa.jank-lang.org/pool/main/j/jank/$deb"
  if ! echo "$sha  $kept.part" | shasum -a 256 -c --status; then
    rm -f "$kept.part"
    echo "error: jank's $deb is no longer $sha (rebuilt) and no copy of it is kept in $cache:" \
      "pin the new one (jank_sha256 in infra/host/tools.sh)" >&2
    exit 1
  fi
  mv "$kept.part" "$kept"
fi
# A host with that jank installed needs nothing.
installed=$(ssh "$@" "$target" 'cat ~/opt/jank/.sha256 2>/dev/null' || true)
[ "$installed" = "$sha" ] && exit 0
echo "== jank's package, from this machine's copy"
ssh "$@" "$target" 'mkdir -p ~/opt'
rsync -a -e "ssh $*" "$kept" "$target:opt/$deb"
