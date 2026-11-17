# SPDX-License-Identifier: MIT
# commit.sh (sourced): commit_of <repo>, the repository's commit as determinismo's builds stamp it
# into each run (-Dcommit=: short, "-dirty" with uncommitted changes to tracked files but
# Markdown's: notes and docs, never part of a build). Passed
# explicitly: Zig caches a build's configuration, so build.zig's own git call can be stale.
commit_of() {
  local head
  # A tree with no git of its own (assembled from several repositories, an archive) says its.
  if [ -f "$1/.commit" ]; then cat "$1/.commit"; return; fi
  head=$(git -C "$1" rev-parse --short=12 HEAD 2>/dev/null) || { echo unknown; return; }
  if [ -n "$(git -C "$1" status --porcelain --untracked-files=no -- . ':!*.md' 2>/dev/null)" ]; then
    echo "$head-dirty"
  else
    echo "$head"
  fi
}
