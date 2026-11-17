#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# isolate.sh <own cpus> <run cpus>: the runs' cores theirs alone, enforced by the kernel. Runs
# take one hyperthread of each of their cores (siblings off) and the other stays idle: nothing
# else may run on either. Every other service, scope and slice is confined to the reserved CPUs
# (cgroup cpusets: systemd's AllowedCPUs, a drop-in for every service and the user slice, so
# those started later too), and device interrupts and unbound kernel work go there as well.
# Run as root by serve's unit before each start (ExecStartPre=+), idempotent. Without a
# reservation (no own cpus) it does nothing: runs take every core.
#
# Why: trials, checks and a development serve on the runs' hyperthread siblings shared their
# physical cores. Conductor's run 443 ran 155 timelines an hour beside them, 264 without
# (2026-11-02).
set -euo pipefail
own=${1:?usage: $0 <own cpus> <run cpus>}
run=${2:?usage: $0 <own cpus> <run cpus>}
[ "$own" = - ] && exit 0
# Everything but serve, from now on: services (transient ones too: systemd-run units), the user
# slice (ssh sessions, the user's manager and rootless podman's containers), machines. Serve's
# own drop-in sorts after (drop-ins apply by file name, whatever their directory) and resets the
# list first: assignments of AllowedCPUs merge (serve got 0-45 without the reset).
mkdir -p /etc/systemd/system/service.d /etc/systemd/system/user.slice.d \
  /etc/systemd/system/machine.slice.d /etc/systemd/system/determinismo-serve.service.d
printf '[Service]\nAllowedCPUs=%s\n' "$own" > /etc/systemd/system/service.d/50-determinismo-reserved-cpus.conf
printf '[Slice]\nAllowedCPUs=%s\n' "$own" > /etc/systemd/system/user.slice.d/50-determinismo-reserved-cpus.conf
printf '[Slice]\nAllowedCPUs=%s\n' "$own" > /etc/systemd/system/machine.slice.d/50-determinismo-reserved-cpus.conf
printf '[Service]\nAllowedCPUs=\nAllowedCPUs=%s\n' "$run" > /etc/systemd/system/determinismo-serve.service.d/zz-determinismo-run-cpus.conf
systemctl daemon-reload
# Those running now, at once (a reload applies drop-ins to units as they start).
for unit in $(systemctl list-units --type=service,scope,slice --state=active --no-legend --plain | awk '{print $1}'); do
  case $unit in
    determinismo-serve.service | -.slice | system.slice) continue ;;
  esac
  systemctl set-property --runtime "$unit" "AllowedCPUs=$own" 2>/dev/null || true
done
systemctl set-property --runtime determinismo-serve.service "AllowedCPUs=$run"
effective=$(cat /sys/fs/cgroup/system.slice/determinismo-serve.service/cpuset.cpus.effective)
[ "$effective" = "$run" ] || { echo "error: serve's CPUs are $effective, not $run" >&2; exit 1; }
# Interrupts and the kernel's unbound work on the reserved CPUs (per-CPU ones stay where they
# must: their writes fail, harmlessly).
mask=$(python3 - "$own" <<'PY'
import sys
mask = 0
for span in sys.argv[1].replace(" ", ",").split(","):
    if span:
        a, _, b = span.partition("-")
        for cpu in range(int(a), int(b or a) + 1):
            mask |= 1 << cpu
words = []
while mask:
    words.append(f"{mask & 0xffffffff:08x}")
    mask >>= 32
print(",".join(reversed(words)) or "0")
PY
)
echo "$mask" > /proc/irq/default_smp_affinity 2>/dev/null || true
for irq in /proc/irq/[0-9]*; do
  echo "$own" > "$irq/smp_affinity_list" 2>/dev/null || true
done
echo "$mask" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true
# Kernel threads free to run anywhere (kswapd, khugepaged, ...): there too. Per-CPU ones and
# workqueue rescuers refuse, and stay.
all="0-$(( $(nproc --all) - 1 ))"
for task in /proc/[0-9]*; do
  pid=${task#/proc/}
  [ "$(taskset -cp "$pid" 2>/dev/null | sed 's/.*: //')" = "$all" ] || continue
  taskset -pc "$own" "$pid" >/dev/null 2>&1 || true
done
echo "isolate: runs alone on $run (and their siblings, idle); everything else on $own"
