#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs `determinismo serve` as a systemd unit for the user's build: started at boot after our
# KVM, restarted if it fails. A restart (a new build) leaves its runs running: the new serve adopts
# them (their pid files). `stop` takes the runs too (they live in its cgroup): before KVM is
# reloaded. Idempotent. Run as root.
# Usage: serve.sh <user> start|stop [--reserved-cores N] [--siblings on|off]
#   [--margin-branches N|auto] [--machines-per-cpu N] [--public-listen <address:port>|off]
#   Every exploration on the host is one of its runs (~/.determinismo, src/runs.zig): serve
#   shows them however they were started.
#   --reserved-cores N: N physical cores (with their hyperthreads) for the user's own sessions
#   (ssh: builds, checks, benchmarks), the rest for serve and every run it starts (hunts), each
#   confined to its share by the kernel (cgroup cpusets: systemd's AllowedCPUs). Kept in
#   /etc/determinismo/reserved-cores for the next start. Default 0: runs may take every core.
#   With them, 6 GiB per reserved core of the host's memory, which runs leave free while a
#   session's VM waits for memory (DETERMINISMO_SESSIONS_MEMORY_MIB, cpus.zig): cores without
#   memory to run VMs on are no reservation (a hunt left a check one VM at a time, srv3
#   2026-10-28), and memory held back for nobody kept a hunt's holders from being made.
#   --public-listen <address:port>|off: the page live and read only on that address too (serve
#   --public-listen: a CI hunt's machine, its tunnel in front); off removes it. Kept in
#   /etc/determinismo/public-listen. Default none.
#   --siblings on|off: VMs on a core's second hyperthread too, once every core's first is busy
#   (DETERMINISMO_SMT, cpus.zig). Kept in /etc/determinismo/siblings. Default off.
#   --margin-branches N|auto: how many branches before an exact stop the guest's clock starts
#   single-stepping (explore's --margin-branches). An overshoot (a counter interrupt handled
#   more branches late than the margin) makes that timeline another one, so the margin must
#   exceed this CPU's skid; every step past it is a VM exit. auto (the default): twice the
#   largest skid this host's last 500 runs measured, rounded up to 8, at least 32, once 5,000
#   of their timelines measured one; until then the explorer's 128. Kept in
#   /etc/determinismo/margin-branches. srv4 (Gold 6152): skid at most 23 over 48,148 timelines,
#   hunts' 40 VMs included; margin 48 instead of 128 took Mu3's single-steps from 5.78 M to
#   about 2 M a 20 s timeline, the same timeline (2026-11-10). Other CPUs skid more (a W-2295
#   65, Granite Rapids under 96 VMs 104): measured on each host, not assumed.
#   --machines-per-cpu N: how many machines (sandboxes, a CI job's setup: fast VMs) share a CPU
#   among themselves, never with a timeline's deterministic VM (serve's --machines-per-cpu,
#   cpus.zig). Kept in /etc/determinismo/machines-per-cpu. Default serve's own, 4: lower it
#   where the sandboxes are busy at the same moment.
set -euo pipefail
user=${1:?usage: $0 <user> start|stop [--reserved-cores N]}
action=${2:?usage: $0 <user> start|stop [--reserved-cores N]}
shift 2
reserved_given=
siblings_given=
margin_given=
machines_given=
public_given=
while [ $# -gt 0 ]; do
  case $1 in
    --reserved-cores) reserved_given=${2:?--reserved-cores needs a number}; shift 2 ;;
    --siblings) siblings_given=${2:?--siblings needs on or off}; shift 2 ;;
    --margin-branches) margin_given=${2:?--margin-branches needs a number or auto}; shift 2 ;;
    --machines-per-cpu) machines_given=${2:?--machines-per-cpu needs a number}; shift 2 ;;
    --public-listen) public_given=${2:?--public-listen needs an address or off}; shift 2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done
home=$(getent passwd "$user" | cut -d: -f6)
uid=$(id -u "$user")
unit=determinismo-serve.service
case $action in
  stop)
    systemctl kill "$unit" 2>/dev/null || true # Every process of the unit: its runs too.
    systemctl stop "$unit" 2>/dev/null || true
    exit 0
    ;;
  start) ;;
  *) echo "error: unknown action $action" >&2; exit 2 ;;
esac
# The host's cores: N of them (the first, with their hyperthreads) for the user's sessions, the
# rest for serve and its runs.
config=/etc/determinismo/reserved-cores
if [ -n "$reserved_given" ]; then
  mkdir -p "$(dirname "$config")"
  echo "$reserved_given" > "$config"
fi
reserved=$(cat "$config" 2>/dev/null || echo 0)
siblings_config=/etc/determinismo/siblings
case $siblings_given in
  on|off) mkdir -p "$(dirname "$siblings_config")"; echo "$siblings_given" > "$siblings_config" ;;
  "") ;;
  *) echo "error: --siblings takes on or off" >&2; exit 2 ;;
esac
smt=0
[ "$(cat "$siblings_config" 2>/dev/null || echo off)" = on ] && smt=1
margin_config=/etc/determinismo/margin-branches
case $margin_given in
  auto|[1-9]*) mkdir -p "$(dirname "$margin_config")"; echo "$margin_given" > "$margin_config" ;;
  "") ;;
  *) echo "error: --margin-branches takes a number or auto" >&2; exit 2 ;;
esac
machines_config=/etc/determinismo/machines-per-cpu
case $machines_given in
  [1-9]*) mkdir -p "$(dirname "$machines_config")"; echo "$machines_given" > "$machines_config" ;;
  "") ;;
  *) echo "error: --machines-per-cpu takes a number" >&2; exit 2 ;;
esac
machines=$(cat "$machines_config" 2>/dev/null || true)
public_config=/etc/determinismo/public-listen
case $public_given in
  off) rm -f "$public_config" ;;
  "") ;;
  *:[0-9]*) mkdir -p "$(dirname "$public_config")"; echo "$public_given" > "$public_config" ;;
  *) echo "error: --public-listen takes address:port or off" >&2; exit 2 ;;
esac
public=$(cat "$public_config" 2>/dev/null || true)
margin=$(cat "$margin_config" 2>/dev/null || echo auto)
if [ "$margin" = auto ]; then
  margin=
  read -r margin < <(python3 - "$home/.determinismo/runs" <<'PY'
import os, re, sys
runs = sys.argv[1]
skid = re.compile(rb'"skid_max":(\d+)')  # Each timeline: its largest, in its record line.
try:
    ids = sorted((int(n) for n in os.listdir(runs) if n.isdigit()), reverse=True)[:500]
except OSError:
    ids = []
timelines = largest = 0
for run in ids:
    try:
        with open(os.path.join(runs, str(run), "record.jsonl"), "rb") as f:
            data = f.read()
    except OSError:
        continue
    for match in skid.finditer(data):
        timelines += 1
        largest = max(largest, int(match[1]))
if timelines >= 5000:
    print(max(32, -(-2 * largest // 8) * 8))
PY
) || true # Nothing printed: too few timelines measured yet.
fi
echo "serve.sh: stepping margin ${margin:-128, the explorer default} (branches)"
# Runs get the cores past the reserved ones: with siblings off, each core's first thread only,
# so nothing of a run (its explorer, workers waiting for a CPU, a holder copying memory, a
# replay) runs beside a VM on its core's other thread (srv4, 2026-10-31: a run's other
# processes were allowed there, beside VMs pinned to the first threads).
read -r own_cpus run_cpus < <(python3 - "$reserved" "$smt" <<'PY'
import sys

def cpus(text):
    out = []
    for part in text.strip().split(","):
        if part:
            first, _, last = part.partition("-")
            out += range(int(first), int(last or first) + 1)
    return out

def listed(cpus):
    ranges, start, previous = [], None, None
    for cpu in sorted(cpus) + [None]:
        if start is not None and cpu != previous + 1:
            ranges.append(f"{start}" if start == previous else f"{start}-{previous}")
            start = None
        if start is None:
            start = cpu
        previous = cpu
    return ",".join(ranges)

reserved = int(sys.argv[1])
smt = sys.argv[2] == "1"
online = cpus(open("/sys/devices/system/cpu/online").read())
cores = {}
for cpu in online:
    path = f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"
    siblings = [c for c in cpus(open(path).read()) if c in online]
    cores.setdefault(min(siblings), set()).update(siblings)
if reserved >= len(cores):
    sys.exit(f"error: {reserved} reserved cores leave none of {len(cores)} to runs")
firsts = sorted(cores)
own = set().union(*(cores[first] for first in firsts[:max(reserved, 0)]))
run = set().union(*(cores[first] for first in firsts[max(reserved, 0):])) if smt else set(firsts[max(reserved, 0):])
print(listed(own) or "-", listed(run) or "-")
PY
)
[ "$own_cpus" = - ] && own_cpus=
[ "$run_cpus" = - ] && run_cpus=
# The user's sessions on their cores (or every core again, without a reservation).
systemctl set-property "user-$uid.slice" "AllowedCPUs=$own_cpus"
# The user's manager survives an OOM kill of one of its processes: its default (stop) took
# rootless podman's pause process with it, and no run could start a container after (srv3,
# 2026-10-28, twice).
mkdir -p "/etc/systemd/system/user@$uid.service.d"
printf '[Service]\nOOMPolicy=continue\n' > "/etc/systemd/system/user@$uid.service.d/determinismo.conf"
# On the tailnet too (tailscale.sh): the web UI from your devices, without a tunnel.
listen=127.0.0.1:7878
if command -v tailscale >/dev/null && address=$(tailscale ip -4 2>/dev/null); then
  listen="$listen,$address:7878"
fi
# Runs prepare images with rootless podman, which wants the user's runtime directory: the user's
# manager runs without a login (lingering), and the unit starts after it.
loginctl enable-linger "$user"
cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=determinismo serve (runs, results and the web UI on $listen)
# At boot, after our KVM is loaded (ordering only: setup.sh loads it itself), and Tailscale.
After=network.target determinismo-kvm.service user@$uid.service tailscaled.service
Wants=user@$uid.service

[Service]
User=$user
Environment=XDG_RUNTIME_DIR=/run/user/$uid
# What someone asks for (replays, sessions, a fork's futures, analyses) on the reserved cores, out
# of the hunt's (serve.zig's reserved): with reserved cores only.
Environment=DETERMINISMO_RESERVED_SCOPE=${own_cpus:+1}
Environment=DETERMINISMO_SMT=$smt
Environment=DETERMINISMO_SESSIONS_MEMORY_MIB=$((reserved * 6144))
WorkingDirectory=$home/determinismo
# The runs' cores theirs alone: everything else on the reserved ones (isolate.sh), as root.
ExecStartPre=+$home/determinismo/infra/host/isolate.sh ${own_cpus:--} ${run_cpus:--}
# The UI page read from the repository's file at each request: a UI change ships as a copy.
ExecStart=$home/determinismo/zig-out/bin/determinismo serve --listen $listen ${public:+--public-listen $public} \\
  --ui $home/determinismo/src/ui/index.html --bb $home/opt/bb/bb --kernel $home/guest/vmlinuz \\
  --initrd $home/guest/base.cpio --append quiet --cache $home/cache --memory-mib 4096${margin:+ --margin-branches $margin}${machines:+ --machines-per-cpu $machines}
# Restarts stop serve alone: its runs go on, adopted by the next.
KillMode=process
# A process the kernel's OOM killer takes (a holder, a worker) is not a reason to stop the unit
# and every run in it: systemd's default (stop) did, 2026-10-27.
OOMPolicy=continue
# The CPUs runs may take: the cores past the reserved ones, their first threads alone with
# siblings off (above).
AllowedCPUs=$run_cpus
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$unit" >/dev/null
systemctl restart "$unit"
echo "$unit running: $home/determinismo, runs in $home/.determinismo"
[ -z "$own_cpus" ] || echo "cores: CPUs $own_cpus for $user's sessions, $run_cpus for runs"
