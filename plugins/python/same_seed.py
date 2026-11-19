# SPDX-License-Identifier: MIT
"""A strategy that gives every timeline one seed: the same random future each time, so they
differ only by what else the strategy decides. An example of choosing a timeline's seed at its
`branch`, and the e2e `branch-seeds` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/same_seed.py 0x42"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class SameSeed:
    decides = False

    def __init__(self, seed):
        self.seed = seed

    def branch(self, index, seed):
        return self.seed


if __name__ == "__main__":
    serve(SameSeed(int(sys.argv[1], 0)), "same-seed")
