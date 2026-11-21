#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# M0 hardware qualification. Runs on the host as root; prints a report, exits non-zero on a hard failure.
set -uo pipefail
fail=0
ok()   { printf '  %-34s ok   %s\n' "$1" "${2:-}"; }
bad()  { printf '  %-34s FAIL %s\n' "$1" "${2:-}"; fail=1; }
bit()  { (( ($1 >> $2) & 1 )); }

modprobe msr
rd() { rdmsr -p 0 -0 "$1"; }  # 64-bit hex, no 0x

echo "== CPU"
grep -m1 'model name' /proc/cpuinfo | sed 's/^/  /'
printf '  microcode %s, kernel %s\n' "$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')" "$(uname -r)"

echo "== VMX controls (allowed-1)"
basic=$((16#$(rd 0x480)))
if bit $basic 55; then proc_msr=0x48e; pin_msr=0x48d; else proc_msr=0x482; pin_msr=0x481; fi
proc=$(( 16#$(rd $proc_msr) >> 32 ))
proc2=$(( 16#$(rd 0x48b) >> 32 ))
pin=$(( 16#$(rd $pin_msr) >> 32 ))
misc=$((16#$(rd 0x485)))
for c in "RDTSC exiting:proc:12" "monitor trap flag:proc:27" "activate secondary:proc:31" \
         "enable EPT:proc2:1" "enable RDTSCP:proc2:3" "unrestricted guest:proc2:7" \
         "RDRAND exiting:proc2:11" "RDSEED exiting:proc2:16" "enable PML:proc2:17" \
         "TSC scaling:proc2:25" "VMX preemption timer:pin:6"; do
  IFS=: read -r name reg b <<<"$c"
  if bit ${!reg} "$b"; then ok "$name"; else
    case $name in "TSC scaling") ok "$name" "(absent; not required)";; *) bad "$name";; esac
  fi
done
ok "preemption timer rate" "TSC >> $((misc & 31))"

echo "== PMU (CPUID 0xA)"
read -r eax ebx ecx edx < <(cpuid -1 -l 0xa -r | awk -F'[ =]+' '/0x0000000a/{print $5, $7, $9, $11}')
eax=$((eax)); edx=$((edx))
ok "arch perfmon version" "$((eax & 0xff))"
ok "general-purpose counters" "$(((eax >> 8) & 0xff)) x $(((eax >> 16) & 0xff)) bits"
ok "fixed counters" "$((edx & 0x1f)) x $(((edx >> 5) & 0xff)) bits"
bit $((ebx)) 5 && bad "branch-retired event" "(reported unavailable)" || ok "branch-retired event"

echo "== Host"
[ -c /dev/kvm ] && ok "/dev/kvm" || bad "/dev/kvm"
grep -q '^CONFIG_KVM_INTEL=m' "/boot/config-$(uname -r)" && ok "kvm_intel is a module" || bad "kvm_intel is a module"
[ -d "/lib/modules/$(uname -r)/build" ] && ok "headers for running kernel" || bad "headers for running kernel"
# TSX off where the CPU can turn it off (ARCH_CAPABILITIES' TSX_CTRL, bit 7: Cascade Lake on, and
# some earlier parts with microcode); a CPU without that switch (GTHost's Skylake-SP Gold 6152)
# keeps it, and passes: guests never see RTM or HLE (src/cpuid.zig hides them).
tsx_ctrl=$(( (0x$(rd 0x10a) >> 7) & 1 ))
if grep -q 'TSX disabled\|Not affected' /sys/devices/system/cpu/vulnerabilities/tsx_async_abort; then
  ok "TSX off"
elif [ $tsx_ctrl = 0 ]; then
  ok "TSX off" "(this CPU cannot turn it off; hidden from guests)"
else
  bad "TSX off" "(tsx=off on the kernel's command line, then a boot)"
fi
if ! grep -qw rtm /proc/cpuinfo || [ $tsx_ctrl = 0 ]; then ok "RTM hidden"; else bad "RTM hidden"; fi
# sysfs, not dmesg: a long kernel log piped into grep -q dies of SIGPIPE, which pipefail reports.
# EC2's Debian AMIs boot a cloud kernel built without EDAC (CONFIG_EDAC unset; a c8i.xlarge and a
# c8i.metal-48xl, 2026-11-08): an EC2 host's ECC is taken on trust.
if [ -d /sys/devices/system/edac/mc/mc0 ]; then ok "ECC (EDAC)"
elif [ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" = "Amazon EC2" ]; then
  ok "ECC (EDAC)" "(not exposed on Amazon EC2; trusted to the provider)"
else bad "ECC (EDAC)" "(not detected)"; fi

echo "== Branch-count repeatability (user mode, 50 runs, each CPU)"
src=$(dirname "$0")/../../bench/pmu/count_repeat.c
# Built beside this script, not in /tmp: a host may mount /tmp noexec (an EC2 machine from our
# base image, 2026-11-21: every CPU "Permission denied"). Executable whatever mode the file had.
bin=$(mktemp -p "$(dirname "$0")" .m0-check.XXXXXX); cc -O1 -o "$bin" "$src"; chmod 755 "$bin"
trap 'rm -f "$bin"' EXIT
for cpu in $(seq 0 $(( $(nproc) - 1 ))); do
  out=$(taskset -c "$cpu" "$bin" 50 | tail -1)
  case $out in *IDENTICAL*) ok "cpu $cpu" "${out%% ->*}";; *) bad "cpu $cpu" "$out";; esac
done
rm -f "$bin"

exit $fail
