# SPDX-License-Identifier: MIT
"""A strategy that answers one named decision with a fixed value wherever it is drawn, the
setup's draws included (they are a strategy's too: asked before the snapshot every timeline
starts from, recorded on the setup's tape). An example of a named decision steered by a plugin,
and the e2e `setup-decisions` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/decide_named.py node.start_draw 7"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class DecideNamed:
    wants = ["labeled", "setup"]

    def __init__(self, name, value):
        self.name = name
        self.value = value

    def random(self, pull, default, source, moment, decision):
        if not decision or decision.get("name") != self.name:
            return None
        size = len(default)
        return (self.value.to_bytes(size, "little"), f"{self.name} fixed at {self.value}")


if __name__ == "__main__":
    serve(DecideNamed(sys.argv[1], int(sys.argv[2])), "decide-named")
