# SPDX-License-Identifier: MIT
"""One run of the race of examples/race, in Python: 64 threads, each incrementing the counter if
it is still zero; an AssertionError when all 64 did. Only this module is under coverage (its
lines and branches are where thread pausing pauses): the runner is no hint."""
import threading

THREADS = 64
counter = 0


def update():
    global counter
    if counter == 0: counter += 1


def run():
    global counter
    counter = 0
    threads = [threading.Thread(target=update) for _ in range(THREADS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if counter == THREADS:
        raise AssertionError("all 64 threads incremented the counter")
    return counter
