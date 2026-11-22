#!/bin/sh
# SPDX-License-Identifier: MIT
# The node's hostname in HOSTNAME in the environment (what a child inherits), for its start command
# and for a command run in it. Antithesis's formalized Raft nodes start through a bash script whose
# log forwarder, its child, names their log lines by it.
start=$(cat /tmp/start-hostname)
command=$(env | sed -n 's/^HOSTNAME=//p')
[ "$start" = named-host ] && [ "$command" = named-host ] && named=true || named=false
printf '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"the node'"'"'s processes have its hostname in HOSTNAME","condition":%s,"details":{"start":"%s","command":"%s"}}}\n' \
  "$named" "$start" "$command" > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
