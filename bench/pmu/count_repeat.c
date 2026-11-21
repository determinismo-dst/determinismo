// SPDX-License-Identifier: MIT
// Counts retired taken branches, conditional branches and instructions (user mode only) around a
// fixed workload, N times. Passes if every run retires the same number of taken branches (the
// guest clock's event since 2026-11-02, src/vm.zig's branch_event_default) and of conditional
// branches (the runs recorded before it count those); instruction counts are reported for
// information (they drift by a few per run on Intel).
// Build: cc -O1 -o count_repeat count_repeat.c   Run (root): ./count_repeat [runs]
#define _GNU_SOURCE
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int open_counter(uint32_t type, uint64_t config, int group) {
  struct perf_event_attr a;
  memset(&a, 0, sizeof a);
  a.size = sizeof a;
  a.type = type;
  a.config = config;
  a.disabled = group == -1;
  a.exclude_kernel = 1;
  a.exclude_hv = 1;
  int fd = (int)syscall(SYS_perf_event_open, &a, 0, -1, group, 0);
  if (fd < 0) { perror("perf_event_open"); exit(1); }
  return fd;
}

// Data-dependent branches so the predictor can't shortcut the count.
static uint64_t workload(uint64_t seed) {
  uint64_t x = seed, acc = 0;
  for (int i = 0; i < 1000000; i++) {
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    if (x & 1) acc += x; else acc ^= x >> 3;
    if ((x & 0xff) == 0x42) acc *= 3;
  }
  return acc;
}

int main(int argc, char **argv) {
  int runs = argc > 1 ? atoi(argv[1]) : 50;
  // Raw events (Skylake on): BR_INST_RETIRED.NEAR_TAKEN = event 0xC4, umask 0x20;
  // BR_INST_RETIRED.CONDITIONAL = event 0xC4, umask 0x01.
  int taken = open_counter(PERF_TYPE_RAW, 0x20c4, -1);
  int br = open_counter(PERF_TYPE_RAW, 0x01c4, taken);
  int ins = open_counter(PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, taken);
  uint64_t first_taken = 0, first_br = 0, min_ins = UINT64_MAX, max_ins = 0, sink = 0;
  int same = 1;
  for (int r = 0; r < runs; r++) {
    uint64_t vt, vb, vi;
    ioctl(taken, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
    ioctl(taken, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
    sink += workload(42);
    ioctl(taken, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
    if (read(taken, &vt, sizeof vt) != sizeof vt || read(br, &vb, sizeof vb) != sizeof vb ||
        read(ins, &vi, sizeof vi) != sizeof vi)
      return 1;
    if (vi < min_ins) min_ins = vi;
    if (vi > max_ins) max_ins = vi;
    if (r == 0) {
      first_taken = vt;
      first_br = vb;
    } else if (vt != first_taken || vb != first_br) {
      same = 0;
      printf("run %d: taken %llu, conditional %llu; first run %llu, %llu\n", r,
             (unsigned long long)vt, (unsigned long long)vb, (unsigned long long)first_taken,
             (unsigned long long)first_br);
    }
  }
  printf("%d runs: taken branches=%llu conditional branches=%llu instructions=%llu..%llu -> "
         "branches %s (sink %llu)\n",
         runs, (unsigned long long)first_taken, (unsigned long long)first_br,
         (unsigned long long)min_ins,
         (unsigned long long)max_ins, same ? "IDENTICAL" : "DIFFERENT",
         (unsigned long long)(sink & 0xff));
  return same ? 0 : 2;
}
