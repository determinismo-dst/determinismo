#!/bin/sh
# SPDX-License-Identifier: MIT
# The maze four times, four processes, and its build without a symbol table four times: each
# edge is one coverage event in the timeline, whichever process ran it first (e2e
# coverage-shared).
for attempt in 1 2 3 4; do
  /usr/local/bin/maze
  /usr/local/bin/maze-bare
done
exit 0
