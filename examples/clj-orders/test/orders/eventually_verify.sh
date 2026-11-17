#!/bin/sh
# SPDX-License-Identifier: MIT
# Once faults stop: every acknowledged order is in Postgres (the service's /verify, written at the
# REPL, waits for its consumer and asserts it with determinismo's SDK).
touch /tmp/acknowledged-orders
curl -s -m 120 -X POST "http://127.0.0.1:8080/verify" --data-binary @/tmp/acknowledged-orders
