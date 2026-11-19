# SPDX-License-Identifier: MIT
"""A strategy that decides the machine a run boots: the guest's wall clock at boot, from a date
(a leap day, a year's end, a far future), every timeline of the run on it, and optionally how far
into their slack timer interrupts land (thousandths). An example of the `machine` request, and
the e2e `machine-decisions` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/machine_date.py 951782400 [900]"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class MachineDate:
    wants = ["machine"]
    decides = False

    def __init__(self, epoch_seconds, landing):
        self.epoch_seconds = epoch_seconds
        self.landing = landing

    def machine(self, request):
        answer = {"epoch_seconds": self.epoch_seconds}
        if self.landing is not None:
            answer["timer_delay_permille"] = self.landing
        return answer


if __name__ == "__main__":
    landing = int(sys.argv[2]) if len(sys.argv) > 2 else None
    serve(MachineDate(int(sys.argv[1]), landing), "machine-date")
