# SPDX-License-Identifier: MIT
"""A checker over a history: the records a timeline's commands made for one of the program's
host checks (`sdk.record`), given to the plugin whole at the timeline's end, as Elle's or a
linearizability checker's input. Here det-selftest's `squares`: every record's square is its
number's, and the last says how many came before it. An example of a history checker, and the
e2e `plugin-histories` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/history_check.py squares"
"""
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class HistoryCheck:
    wants = ["plans", "check"]

    def __init__(self, name):
        self.name = name

    def check(self, index, histories):
        history = next((h for h in histories if h["name"] == self.name), None)
        if history is None or history.get("records") is None:
            return [{"type": "reachable", "message": f"a checker plugin is given the {self.name} history",
                     "condition": False, "details": {"bytes": (history or {}).get("bytes", 0)}}]
        records = [json.loads(line) for line in history["records"].splitlines() if line]
        squares, count = records[:-1], records[-1]["n"] if records else -1
        return [
            {"type": "reachable", "message": f"a checker plugin is given the {self.name} history",
             "condition": True, "details": {"records": len(records)}},
            {"type": "always", "message": f"a checker plugin sees every {self.name} record",
             "condition": len(squares) == count, "details": {"records": len(squares), "count": count}},
            {"type": "always", "message": f"a checker plugin finds each {self.name} record right",
             "condition": all(r["square"] == r["n"] * r["n"] for r in squares), "details": {}},
        ]


if __name__ == "__main__":
    serve(HistoryCheck(sys.argv[1]), "history-check")
