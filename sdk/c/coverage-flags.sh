#!/bin/sh
# SPDX-License-Identifier: MIT
# coverage-flags.sh <directory>: clang's flags for the C SDK's coverage callbacks
# (sdk/c/coverage.c), scoped by the node's coverage set, DETERMINISMO_COVERAGE (a build argument
# from the test program's profile: source file prefixes as the compiler is given them, those
# starting with "-" excluded): -fsanitize-coverage=trace-pc-guard, with an allowlist of the
# included prefixes and an ignorelist of the excluded ones, written to <directory>. What the set
# leaves out is not instrumented at all. Without a set, every file compiled with the flags.
#   CFLAGS="$(sh coverage-flags.sh /tmp/coverage) ..."
set -eu
directory=$1
mkdir -p "$directory"
flags="-fsanitize-coverage=trace-pc-guard"
include=""
exclude=""
old_ifs=$IFS
IFS=,
for entry in ${DETERMINISMO_COVERAGE:-}; do
  case "$entry" in
    -?*) exclude="${exclude}src:${entry#-}*
" ;;
    -) ;;
    ?*) include="${include}src:${entry}*
" ;;
  esac
done
IFS=$old_ifs
if [ -n "$include" ]; then
  # SanitizerCoverage's allowlist asks a function to match a `src` and a `fun` entry both.
  printf '%sfun:*\n' "$include" > "$directory/allowlist.txt"
  flags="$flags -fsanitize-coverage-allowlist=$directory/allowlist.txt"
fi
if [ -n "$exclude" ]; then
  printf '%s' "$exclude" > "$directory/ignorelist.txt"
  flags="$flags -fsanitize-coverage-ignorelist=$directory/ignorelist.txt"
fi
echo "$flags"
