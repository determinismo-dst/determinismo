# SPDX-License-Identifier: MIT
"""The tests' code covered (determinismo's Python SDK, Python 3.12+): each line a test reaches is
reported once, and explorations keep the timelines that reach new code. serve stops a run whose
first timelines report none."""
import determinismo

determinismo.coverage_start(["/app/"])
