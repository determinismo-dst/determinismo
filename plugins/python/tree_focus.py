# SPDX-License-Identifier: MIT
"""A strategy that shapes the generation: all its returns on one moment, the rarest new behavior
of the generation (the fewest timelines reached it first), `FOCUS` timelines from it, and the
rest of the generation started fresh from the setup snapshot (no explorer's picks). An example of
the protocol's `branches` and `fill`, and the e2e `shape` check's plugin.

    determinismo explore ... --branching tree --tape-dir <dir> \\
        --strategy "python3 plugins/python/tree_focus.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402

MS = 1_000_000
FOCUS = 8


class TreeFocus:
    decides = False
    wants = ["behaviors"]

    def returns(self, generation, candidates, count):
        best = None
        for candidate in candidates:
            start, end = candidate["start_ns"], candidate["end_ns"]
            room_end = start + (end - start) // 5 * 4
            for behavior in candidate["behaviors"]:
                timelines = behavior["new_in_generation"]
                if timelines == 0 or behavior["vtime_ns"] > room_end or end - start < 2 * MS:
                    continue
                key = (timelines, -behavior["vtime_ns"], candidate["branch"])
                if best is None or key < best[0]:
                    at = min(max(behavior["vtime_ns"] + 1000, start + MS), end - MS)
                    best = (key, candidate["branch"], at, behavior["label"])
        if best is None:
            return None  # Nothing new: the explorer chooses.
        _, branch, at, label = best
        reason = f"focus: all on just after {label} ({best[0][0]} timelines reached it first)"
        return {"returns": [(branch, at, reason, FOCUS)], "fill": "fresh"}


if __name__ == "__main__":
    serve(TreeFocus(), "tree-focus")
