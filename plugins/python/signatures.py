# SPDX-License-Identifier: MIT
"""A triage checker: labels each timeline by the signatures its events show, a known bug's text
each (`<label>=<regex>`, matched against each event as JSON): a sometimes assertion "known:
<label>" for every signature a timeline matched, with the first match's moment and text; an
argument `@<file>` gives them a line each (a plugin's command is split at spaces). Live
(a run's --strategy) or over a run that ended (determinismo triage), as the calibrations'
signature scripts (infra/calibrations/*-signatures.py) are; the e2e `triage` check's plugin.

    determinismo triage --events <run>/events \\
        --strategy "python3 plugins/python/signatures.py '#3217=result must be set only once'"
"""
import json
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402

# A match's text kept, at most (the event's JSON around it).
SNIPPET_MAX = 240


class Signatures:
    wants = ["plans", "check"]

    def __init__(self, signatures):
        self.signatures = []
        lines = []
        for given in signatures:
            if given.startswith("@"):
                lines += [line.strip() for line in open(given[1:]) if line.strip() and not line.startswith("#")]
            else:
                lines.append(given)
        for given in lines:
            label, _, pattern = given.partition("=")
            if not label or not pattern:
                raise SystemExit(f"signatures.py: '<label>=<regex>', not {given!r}")
            self.signatures.append((label, re.compile(pattern)))
        self.found = {}

    def branch(self, index, seed):
        self.found = {}

    def event(self, event, source, moment):
        if len(self.found) == len(self.signatures):
            return
        text = json.dumps(event)
        for label, pattern in self.signatures:
            if label in self.found:
                continue
            match = pattern.search(text)
            if match:
                start = max(0, match.start() - SNIPPET_MAX // 4)
                self.found[label] = {"vtime_ns": moment[0], "text": text[start:start + SNIPPET_MAX]}

    def check(self, index):
        return [{"type": "sometimes", "message": f"known: {label}", "condition": True, "details": found}
                for label, found in self.found.items()]


if __name__ == "__main__":
    serve(Signatures(sys.argv[1:]), "signatures")
