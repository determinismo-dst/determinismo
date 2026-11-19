# SPDX-License-Identifier: MIT
"""A strategy that gives each timeline a stepper of its own: how many branches before a stop KVM
starts single-stepping (VM.Options.margin_branches), 96, 128, 512 or 4096 by the timeline's index.
A speed choice: the guest sees the same at any of them (the e2e `steppers` check compares the
events with the default stepper's). Each tape says its margin.

    determinismo explore ... --strategy "python3 plugins/python/steppers.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402

MARGINS = [96, 128, 512, 4096]


class Steppers:
    decides = False  # Only the timelines' starts.

    def branch(self, index, seed):
        return {"margin_branches": MARGINS[index % len(MARGINS)]}


if __name__ == "__main__":
    serve(Steppers(), "steppers")
