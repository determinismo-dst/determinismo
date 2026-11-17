# SPDX-License-Identifier: MIT
"""A strategy that plans: every named decision with options it is told of is drawn from its plan,
the first option always, by the explorer itself (no round trip per decision). An example of
`wants = ["plans"]` (events in batches, a plan with each reply), and the e2e `plans` check's
plugin.

    determinismo explore ... --strategy "python3 plugins/python/plan_first.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class PlanFirst:
    decides = True
    wants = ["assertions", "plans"]

    def __init__(self):
        self.seen = set()

    def event(self, event, source, moment):
        decision = event.get("decision")
        if isinstance(decision, dict) and len(decision.get("options") or []) > 1:
            self.seen.add(decision["name"])

    def plan(self):
        return {name: [[0, 1, 1.0]] for name in sorted(self.seen)}


if __name__ == "__main__":
    serve(PlanFirst(), "plan-first")
