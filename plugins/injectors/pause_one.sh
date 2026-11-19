#!/bin/sh
# SPDX-License-Identifier: MIT
# A fault injector of a run's own (explore --injector, serve's "injectors"): run by the guest's
# composer in place of det-faults for the timelines whose "faults.injector" decision picks it,
# with `--scenario <name>`. It pauses a node a while, again and again, the node and the pause
# drawn by named decisions (det-sdk: steerable, on the tape), until stopped: on SIGTERM it
# resumes what it paused and exits, as det-faults undoes its faults. The e2e `injectors` check's.
paused=""
trap '[ -n "$paused" ] && det-nodes resume "$paused"; exit 0' TERM
det-sdk event custom_injector_started '{}'
nodes=$(det-nodes list | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
[ -n "$nodes" ] || exit 0
while true; do
  node=$(det-sdk decide injector.node $nodes)
  det-nodes pause "$node" && paused=$node
  det-sdk event custom_injector_paused "{\"node\":\"$node\"}"
  sleep "$(det-sdk random injector.pause_s 2)"
  det-nodes resume "$node"
  paused=""
  sleep 1
done
