# SPDX-License-Identifier: MIT
"""A strategy that ends each timeline at its first fault: an example of ending a timeline early
(an event's reply `{"end": true}`), and the e2e `end` check's plugin. A real one ends the
timelines headed only for failures already found, and their workers start others.

    determinismo explore ... --strategy "python3 plugins/python/end_at_fault.py [--batched]"

--batched: told its events in batches (one round trip for many): the end comes with the batch sent
before the next decision it is asked.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class EndAtFault:
    decides = True  # Told of events; no `random`: every draw as the explorer would.
    wants = ["labeled", "assertions"]

    def event(self, event, source, moment):
        return event.get("event") == "fault"


if __name__ == "__main__":
    strategy = EndAtFault()
    if "--batched" in sys.argv[1:]:
        strategy.wants = strategy.wants + ["batched"]
    serve(strategy, "end-at-fault")
