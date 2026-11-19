# SPDX-License-Identifier: MIT
"""A strategy that gives each timeline a clock of its own: the jitter its RDTSC reads carry
(VM.Options.tsc_jitter_seed), drawn from the timeline's seed, so timelines differ in their
clocks' low bits as machines do; a tree's child from its branch point on, its ancestors on
theirs. Its tapes say each clock (a child's chain its ancestors'): replays need no plugin. The
e2e `timeline-clocks` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/clock.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class Clock:
    decides = False  # Only the timelines' starts: its runs keep their in-run snapshots.

    def branch(self, index, seed, start):
        return {"jitter_seed": (seed * 0x9E3779B97F4A7C15 + 1) & 0xFFFFFFFFFFFFFFFF}


if __name__ == "__main__":
    serve(Clock(), "clock")
