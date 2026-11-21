#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installs the pinned toolchain into ~/opt, checked against its published checksums: Zig, babashka
# (notebooks), DuckDB (the events database), the TLA+ tools (`determinismo tla`), WAMR's wamrc
# (wasm plugins compiled to native code), jank (test programs in jank: their --describe on the
# host) and a JDK 25 (the guest's JVM coverage agent).
# Idempotent.
# Runs on the host as the user.
# Usage: infra/host/tools.sh [--build]
# --build: only what `zig build` needs (Zig, DuckDB, the JDK), as GitHub's CI runners install it
# (.github/workflows/ci.yml); jank's rolling package, pinned by the copy shipped from your
# machine, is not fetched there.
set -euo pipefail
opt=$HOME/opt
mkdir -p "$opt"
build_only=0
[ "${1:-}" = --build ] && build_only=1

# fetch <url> <sha256> <file>: downloads unless the file is there with that checksum.
fetch() {
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --status; then return; fi
  curl -fsSL -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --status || { echo "error: checksum of $1" >&2; exit 1; }
  mv "$3.part" "$3"
}

zig=zig-x86_64-linux-0.17.0
if [ ! -x "$opt/$zig/zig" ]; then
  fetch "https://ziglang.org/download/0.17.0/$zig.tar.xz" \
    1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 "$opt/$zig.tar.xz"
  tar -xJf "$opt/$zig.tar.xz" -C "$opt"
  rm "$opt/$zig.tar.xz"
fi
ln -sfn "$opt/$zig" "$opt/zig"

bb=babashka-1.13.225-linux-amd64-static.tar.gz
if [ $build_only = 0 ] && ! "$opt/bb/bb" --version 2>/dev/null | grep -q 'v1.13.225'; then
  mkdir -p "$opt/bb"
  fetch "https://github.com/babashka/babashka/releases/download/v1.13.225/$bb" \
    ab0e98307405ba19e7c5ba0c3c7cd17a6f90aa90577a72709055f120796d6bfe "$opt/$bb"
  tar -xzf "$opt/$bb" -C "$opt/bb"
  rm "$opt/$bb"
fi

# DuckDB (the events database, linked into determinismo by build.zig): its static libraries for
# musl, and the libstdc++ they were built against (Alpine 3.22's, GCC 14.2.0).
duckdb=$opt/duckdb-2.0.0
if [ ! -f "$duckdb/libstdc++.a" ]; then
  mkdir -p "$duckdb"
  fetch https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-static-libs-linux-amd64-musl.tar.gz \
    2f783d69fc8713cf8482577fcde7e000f487997908feb9ef20ad35a3a642f59c "$opt/duckdb-static-libs.tar.gz"
  tar -xzf "$opt/duckdb-static-libs.tar.gz" -C "$duckdb"
  rm "$opt/duckdb-static-libs.tar.gz"
  # An apk is gzip members of tar archives one after another (--ignore-zeros reads past each).
  fetch https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/libstdc++-dev-14.2.0-r6.apk \
    13e2169b46a24f03c87caf91387312724b01951c222bd061d6d87c48903836a9 "$opt/libstdc++-dev.apk"
  tar -xzf "$opt/libstdc++-dev.apk" --ignore-zeros -C "$duckdb" --strip-components 2 \
    usr/lib/libstdc++.a 2>/dev/null
  rm "$opt/libstdc++-dev.apk"
  echo "150c8c511468a90780f804058d984c07c1c69519f3bd8fe0689c49c9a1f7da70  $duckdb/libstdc++.a" |
    sha256sum -c --status || { echo "error: libstdc++.a from the apk" >&2; exit 1; }
fi
ln -sfn "$duckdb" "$opt/duckdb"

if [ $build_only = 0 ]; then
mkdir -p "$opt/tla"
# The latest stable release: v1.8.0 is a pre-release its project republishes under the same tag
# (2026-10-26, 2026-10-30), each time failing the checksum.
fetch https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar \
  936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 "$opt/tla/tla2tools.jar"

# WAMR's ahead-of-time compiler, wamrc (2.4.4, its release's x86-64 Linux build): the explorer
# compiles a wasm plugin with it to native code before it runs (src/wasm_plugin.zig finds it in
# ~/opt/wamrc), the runtime compiled into determinismo of the same version.
wamrc=$opt/wamrc-2.4.4
if ! "$wamrc/wamrc" --version 2>/dev/null | grep -q 'wamrc 2.4.4'; then
  mkdir -p "$wamrc"
  fetch "https://github.com/bytecodealliance/wasm-micro-runtime/releases/download/WAMR-2.4.4/wamrc-2.4.4-x86_64-ubuntu-22.04.tar.gz" \
    71cb2a47ec5df45e9221511ddbf6f3cfb5bcee530b3889cae5d5c3a6526056e8 "$opt/wamrc-2.4.4.tar.gz"
  tar -xzf "$opt/wamrc-2.4.4.tar.gz" -C "$wamrc"
  rm "$opt/wamrc-2.4.4.tar.gz"
fi
ln -sfn "$wamrc" "$opt/wamrc"
fi

# A JDK 25 (Temurin), for the guest's JVM coverage agent (build.zig: java.lang.classfile needs
# JDK 24+ to compile, its entry point built for Java 8): ~/opt/jdk-25.
jdk=$opt/jdk-25.0.5+8
if [ ! -x "$jdk/bin/javac" ]; then
  fetch https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5_8.tar.gz \
    68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb "$opt/jdk-25.tar.gz"
  tar -xzf "$opt/jdk-25.tar.gz" -C "$opt"
  rm "$opt/jdk-25.tar.gz"
fi
ln -sfn "$jdk" "$opt/jdk-25"

# jank's Ubuntu package (jank's own repository), unpacked into ~/opt/jank: Debian has none, and
# its binary needs only what the host has (tools/program_pack.zig's programs run it from there).
# A rolling build, republished under the same name several times a day: the pinned one is the copy
# setup.sh and update.sh ship from your machine (tools-ship.sh, kept by its checksum), which fetch
# finds here; a new pin downloads once more.
jank_deb=jank_0.1-noble_amd64.deb
jank_sha256=68f6d0d8f0f85bbed76ba7c04d38de0abbb50db4ae9adba214117e4e2eafd983
if [ $build_only = 1 ]; then
  echo "zig $("$opt/zig/zig" version), duckdb v2.0.0, jdk 25.0.5"
  exit 0
fi
if [ "$(cat "$opt/jank/.sha256" 2>/dev/null)" != "$jank_sha256" ]; then
  fetch "https://ppa.jank-lang.org/pool/main/j/jank/$jank_deb" "$jank_sha256" "$opt/$jank_deb"
  rm -rf "$opt/jank" && mkdir -p "$opt/jank"
  dpkg -x "$opt/$jank_deb" "$opt/jank"
  echo "$jank_sha256" > "$opt/jank/.sha256"
  rm "$opt/$jank_deb"
fi

echo "zig $("$opt/zig/zig" version), $("$opt/bb/bb" --version), duckdb v2.0.0, tla2tools v1.7.4, jank 0.1-noble"
