#!/bin/sh
# SPDX-License-Identifier: MIT
# A client placing orders (README.md): each acknowledged one (200 and its id) kept, for the
# check at the end. The service it calls is written at the REPL.
for i in 1 2 3 4 5; do
  id=$(curl -s -m 10 -f -X POST "http://127.0.0.1:8080/orders" --data "{\"item\":\"book-$i\"}") || continue
  [ -n "$id" ] && echo "$id" >> /tmp/acknowledged-orders
done
exit 0
