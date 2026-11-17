#!/bin/sh
# SPDX-License-Identifier: MIT
# The server's write, seen through the client's read-only mount of the same directory.
[ "$(cat /check/shared/server)" = server ] || { echo "the server's file is not shared" >&2; exit 1; }
grep -qw the_server_1 /etc/hosts || { echo "the_server_1 does not resolve" >&2; exit 1; }
if ( echo client > /check/shared/client ) 2>/dev/null; then echo "a read-only mount took a write" >&2; exit 1; fi
echo "shared"
