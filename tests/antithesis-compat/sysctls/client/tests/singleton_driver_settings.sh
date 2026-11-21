#!/bin/sh
# SPDX-License-Identifier: MIT
# The node's namespaced kernel settings, as its Compose file sets them (Linux's own: 10 and 4096).
qlen=$(cat /proc/sys/net/unix/max_dgram_qlen)
backlog=$(cat /proc/sys/net/core/somaxconn)
[ "$qlen" = 4096 ] && [ "$backlog" = 1024 ] && set=true || set=false
printf '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"the node'"'"'s kernel settings are its Compose file'"'"'s","condition":%s,"details":{"max_dgram_qlen":%s,"somaxconn":%s}}}\n' \
  "$set" "$qlen" "$backlog" > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
