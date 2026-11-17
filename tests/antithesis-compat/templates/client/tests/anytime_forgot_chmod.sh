#!/bin/sh
# SPDX-License-Identifier: MIT
# Left without chmod +x (the Dockerfile's 0644): invalid, never run.
echo "the unexecutable command ran"
exit 1
