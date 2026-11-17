#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# own-cpus.sh: on a host running serve with reserved cores, the reserved CPUs (every CPU but
# the runs' and their hyperthread siblings: isolate.sh keeps the runs' cores theirs alone), as an
# AllowedCPUs list: where trials, checks, unit tests and a development serve run beside a hunt.
# The runs' siblings were used so once, and shared the hunt's physical cores (Conductor's run
# 443: 155 timelines an hour beside them, 264 without, 2026-11-02).
set -euo pipefail
runs=$(systemctl show determinismo-serve.service -p AllowedCPUs --value)
cpus=$(python3 -c '
import os, sys
def spans(text):
    cpus = set()
    for part in text.replace(" ", ",").split(","):
        if part:
            a, _, b = part.partition("-")
            cpus.update(range(int(a), int(b or a) + 1))
    return cpus
runs = spans(sys.argv[1])
taken = set(runs)
for cpu in runs:
    taken |= spans(open(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list").read().strip())
every = set(range(os.cpu_count()))
print(",".join(str(c) for c in sorted(every - taken)))' "$runs")
[ -n "$cpus" ] || { echo "error: no reserved CPUs beside the runs' ($runs)" >&2; exit 1; }
echo "$cpus"
