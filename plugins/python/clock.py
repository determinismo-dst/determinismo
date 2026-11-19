# SPDX-License-Identifier: MIT
"""A strategy that gives each timeline from the setup snapshot a clock of its own: the jitter its
RDTSC reads carry (VM.Options.tsc_jitter_seed), drawn from the timeline's seed, so timelines
differ in their clocks' low bits as machines do. A timeline from a moment of another keeps that
one's (asked with `start`, it answers nothing). Its tapes say each clock: replays need no plugin.
The e2e `timeline-clocks` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/clock.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class Clock:
    decides = False  # Only the timelines' starts: its runs keep their in-run snapshots.

    def branch(self, index, seed, start):
        if start is not None:
            return None
        return {"jitter_seed": (seed * 0x9E3779B97F4A7C15 + 1) & 0xFFFFFFFFFFFFFFFF}


if __name__ == "__main__":
    serve(Clock(), "clock")
