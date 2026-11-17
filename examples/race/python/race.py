# SPDX-License-Identifier: MIT
"""The race of examples/race in Python: runs (racerun) again and again in this process, printing
every run's counter (the same line each run: no hint for the explorer). A run's AssertionError
ends the process (an unexpected exit)."""
import os

import determinismo
import racerun

determinismo.coverage_start([os.path.abspath(racerun.__file__)])
runs = 0
while True:
    runs += 1
    print(f"run {runs}: counter {racerun.run()}", flush=True)
