#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Provisions and hardens a fresh determinismo host from your machine.
# Usage: infra/host/bootstrap.sh <ip> [user]   (default user: det)
set -euo pipefail

ip=${1:?usage: $0 <ip> [user]}
user=${2:-det}
here=$(cd "$(dirname "$0")" && pwd)
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# The user first, root only when it cannot log in (setup.sh says why: OpenSSH's penalties).
user_login=false
until { ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null && user_login=true; } \
   || ssh "${ssh_opts[@]}" "root@$ip" true 2>/dev/null; do
  echo "waiting for $ip to accept SSH..."; sleep 10
done

# A host whose sshd still serves the keys its image booted with while cloud-init has written new
# ones (phoenixNAP's Debian: cloud-init's keys two minutes after boot, sshd started before them):
# the first sshd restart, apt's in provision.sh, switched keys under us (2026-11-08). The keys on
# its disk, read over this authenticated session, are trusted and sshd restarted onto them.
login=$user@$ip
$user_login || login=root@$ip
sudo_cmd=sudo
$user_login || sudo_cmd=
disk_key=$(ssh "${ssh_opts[@]}" "$login" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $1, $2}')
if [ -n "$disk_key" ] && ! ssh-keygen -F "$ip" | grep -qF "${disk_key#* }"; then
  echo "sshd serves keys its disk replaced: restarted, the disk's ed25519 key trusted"
  ssh "${ssh_opts[@]}" "$login" "$sudo_cmd systemctl restart ssh"
  ssh-keygen -R "$ip" >/dev/null 2>&1
  echo "$ip $disk_key" >> ~/.ssh/known_hosts
fi

if ! $user_login; then
  ssh "${ssh_opts[@]}" "root@$ip" "bash -s -- $user" < "$here/provision.sh"
  # Never lock ourselves out: harden only once the new user can log in and sudo.
  ssh "${ssh_opts[@]}" "$user@$ip" 'sudo -n true'
  ssh "${ssh_opts[@]}" "root@$ip" "bash -s -- $user" < "$here/harden.sh"
else
  ssh "${ssh_opts[@]}" "$user@$ip" "sudo bash -s -- $user" < "$here/provision.sh"
  ssh "${ssh_opts[@]}" "$user@$ip" "sudo bash -s -- $user" < "$here/harden.sh"
fi

# A full-upgrade may have installed a newer kernel (Debian doesn't always flag it), and TSX goes
# off only at a boot (provision.sh's tsx=off): boot so the running kernel matches the installed
# headers and has it.
if ! ssh "${ssh_opts[@]}" "$user@$ip" 'test -d /lib/modules/$(uname -r)/build && grep -q tsx=off /proc/cmdline'; then
  ssh "${ssh_opts[@]}" "$user@$ip" 'sudo systemctl reboot' || true
  sleep 20
  # Bounded: AWS metal's firmware takes its time after the shutdown (m5zn.metal 2026-11-15: 12
  # minutes from the shutdown to SSH, the console silent meanwhile; on 2026-11-10 two metal sizes
  # were given up on as never coming back), and an unbounded wait kept a paid machine idle for
  # half an hour. Past 20 minutes: restart it from the provider (EC2: stop, then start; its
  # public IP changes) and run setup again on the new address, which then needs no reboot.
  waited=0
  until ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null; do
    if [ "$waited" -ge 1200 ]; then
      echo "error: $ip did not come back within 20 minutes of its reboot: restart it from the provider (EC2: stop and start), then run setup again" >&2
      exit 1
    fi
    echo "waiting for reboot..."
    sleep 10
    waited=$((waited + 10))
  done
fi

ssh "${ssh_opts[@]}" "$user@$ip" \
  'test -d /lib/modules/$(uname -r)/build && echo "ok: $(whoami)@$(hostname), $(uname -r)"'
