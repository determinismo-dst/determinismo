#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A strategy that changes its own source file at its third timeline (a line appended): run
followed (`--strategy-follow`), the explorer starts it again on the new bytes for the timelines
after it, each tape naming the copy it ran with. The e2e `strategy-follow` check's plugin.

    determinismo explore ... --strategy-follow --strategy "<a copy of it> <plugins/python> <the copy>"
"""
import os
import sys

sys.path.insert(0, sys.argv[1])
from determinismo_strategy import serve  # noqa: E402


class RewriteSelf:
    decides = False  # Only the timelines' starts.

    def __init__(self, source):
        self.source = source  # The followed file (it runs from a kept copy of it).

    def branch(self, index, seed, start):
        if index == 2:
            with open(self.source, "a") as file:
                file.write("# rewritten at timeline 2\n")
        return None


if __name__ == "__main__":
    serve(RewriteSelf(os.path.abspath(sys.argv[2])), "rewrite-self")
