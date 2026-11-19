# SPDX-License-Identifier: MIT
"""A strategy that decides the machine a run boots: the guest's wall clock at boot, from a date
(a leap day, a year's end, a far future), every timeline of the run on it. An example of the
`machine` request, and the e2e `machine-decisions` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/machine_date.py 951782400"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class MachineDate:
    wants = ["machine"]
    decides = False

    def __init__(self, epoch_seconds):
        self.epoch_seconds = epoch_seconds

    def machine(self, request):
        return {"epoch_seconds": self.epoch_seconds}


if __name__ == "__main__":
    serve(MachineDate(int(sys.argv[1])), "machine-date")
