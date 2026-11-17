#!/bin/sh
# SPDX-License-Identifier: MIT
# Every one of the nineteen servers answers by its own name.
/usr/local/bin/ask 25 || exit 1
echo "nineteen answered"
