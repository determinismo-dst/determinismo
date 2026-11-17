# SPDX-License-Identifier: MIT
"""The CI demo's tests (README.md): one that passes, one flaky, one that always fails."""
import os


def test_adds():
    assert 2 + 2 == 4


def test_flaky():
    # Fails when a random byte is low: half the time, each timeline its own randomness.
    assert os.urandom(1)[0] >= 128


def test_always_wrong():
    assert sorted([3, 1, 2]) == [3, 2, 1]
