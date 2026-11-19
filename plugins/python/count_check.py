# SPDX-License-Identifier: MIT
"""A checker: judges each timeline from its events at its end. Here, how often an event happened
in a timeline: always at most `max` of them, and sometimes at least one. Never asked for a
decision (wants "plans" with no plan): told the events in batches, asked to `check` at the end.
An example of a checker plugin, and the e2e `plugin-checks` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/count_check.py fault 3"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class CountCheck:
    wants = ["plans", "check"]

    def __init__(self, name, most):
        self.name = name
        self.most = most
        self.count = 0

    def branch(self, index, seed):
        self.count = 0

    def event(self, event, source, moment):
        if event.get("event") == self.name:
            self.count += 1

    def check(self, index):
        details = {"event": self.name, "count": self.count, "most": self.most}
        return [
            {"type": "always", "message": f"at most {self.most} {self.name} events in a timeline",
             "condition": self.count <= self.most, "details": details},
            {"type": "sometimes", "message": f"a {self.name} event in a timeline",
             "condition": self.count > 0, "details": details},
        ]


if __name__ == "__main__":
    serve(CountCheck(sys.argv[1], int(sys.argv[2])), "count-check")
