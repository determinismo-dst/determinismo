#!/bin/bash
# SPDX-License-Identifier: MIT
# jank_aot_pack.sh <jank> <libdeterminismo dir> <out> <main namespace> <module directory>...: a jank workload
# compiled ahead of time (jank's static runtime: no LLVM or Clang inside), packed with what it needs
# that the guest's runner lacks (glibc's and libstdc++'s libraries, the loader) and libdeterminismo
# (for the host's --describe; the runner's own /opt/determinismo/lib first) into one file, which
# extracts itself once (/tmp/jank-program-<its size>) and runs through its bundled loader: a jank
# workload then runs in the runner as a Zig one does (det-nodes, holds), one file for serve.
set -euo pipefail
jank=$1; lib=$2; out=$3; main=$4; shift 4
# The module directories (the program's sources, sdk/jank's), jank's module path.
modules=$(IFS=:; echo "$*")
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$jank" --module-path "$modules" -I "$lib" -L "$lib" -l determinismo --runtime static -O 2 \
  --target-dir "$work/target" --name program compile "$main" > "$work/compile.log" 2>&1 || { tail -30 "$work/compile.log"; exit 1; }
mkdir -p "$work/payload"
cp "$work/target/program" "$work/payload/program"
ldd "$work/target/program" | awk '/=>/ {print $3}' | grep -v libdeterminismo | while read -r so; do cp -L "$so" "$work/payload/"; done
cp -L "$lib/libdeterminismo.so" "$work/payload/"
cp -L /lib64/ld-linux-x86-64.so.2 "$work/payload/"
(cd "$work/payload" && tar cf ../payload.tar .)
# The header names the payload's byte offset (fixed width, filled in below): extracted with tail
# and tar, no scan of the file for a marker (a sed over 15 MB was most of a short timeline).
cat > "$work/header" <<'HEADER'
#!/bin/sh
# A jank workload compiled ahead of time (tools/jank_aot_pack.sh): its libraries and loader after
# this header (a tar at byte OFFSET_), extracted once a file and run through the bundled loader.
dir=/tmp/jank-program-$(stat -c %s "$0")
if [ ! -x "$dir/program" ]; then
  mkdir -p "$dir.part" && tail -c +OFFSET_ "$0" | tar xf - -C "$dir.part" && mv "$dir.part" "$dir"
fi
exec "$dir/ld-linux-x86-64.so.2" --library-path "/opt/determinismo/lib:$dir" "$dir/program" "$@"
HEADER
size=$(stat -c %s "$work/header")
offset=$(printf "%07d" $((size + 1)))
sed "s/OFFSET_/$offset/g" "$work/header" > "$out"
[ "$(stat -c %s "$out")" = "$size" ] || { echo "jank_aot_pack: header size changed"; exit 1; }
cat "$work/payload.tar" >> "$out"
chmod +x "$out"
