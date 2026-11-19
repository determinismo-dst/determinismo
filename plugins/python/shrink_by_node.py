# SPDX-License-Identifier: MIT
"""A shrink plugin (determinismo shrink --strategy): cuts by node before ddmin's halves. First
each node's faults alone (a failure from one node's faults is found in one exploration a node),
then, from the smallest set that reproduces it, each node's faults left out. ddmin goes on from
there. The e2e `shrink-plugin` check's plugin.

    determinismo shrink ... --property '<message>' --strategy "python3 plugins/python/shrink_by_node.py"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


def nodes_of(fault):
    """The nodes a fault hit: its node, and its peer for a link's (a fault of the whole system,
    a clock's or an outage's, its own group)."""
    named = [fault.get(key) for key in ("node", "peer") if fault.get(key)]
    return tuple(sorted(set(named))) or ("(system)",)


class ShrinkByNode:
    wants = ["plans", "shrink"]

    def __init__(self):
        self.stage = "alone"

    def shrink(self, faults, tried, needed):
        groups = {}
        for index, fault in enumerate(faults):
            for node in nodes_of(fault):
                groups.setdefault(node, set()).add(index)
        seen = {tuple(entry["kept"]) for entry in tried}
        if self.stage == "alone":
            self.stage = "without"
            alone = [sorted(group) for group in groups.values()]
            return [cut for cut in alone if tuple(cut) not in seen]
        if self.stage == "without":
            self.stage = "done"
            reproducing = [entry["kept"] for entry in tried if entry["failing"] >= needed]
            smallest = min(reproducing, key=len)
            cuts = []
            for group in groups.values():
                cut = sorted(set(smallest) - group)
                if len(cut) < len(smallest) and tuple(cut) not in seen:
                    cuts.append(cut)
            return cuts
        return []


if __name__ == "__main__":
    serve(ShrinkByNode(), "shrink-by-node")
