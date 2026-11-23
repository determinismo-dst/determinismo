#!/bin/sh
# SPDX-License-Identifier: MIT
# The node's user's home (its /etc/passwd entry, "/" without one) in HOME in the environment, for
# its start command and for a command run in it, as runc sets it.
want=$(awk -F: -v uid="$(id -u)" '$3 == uid { print $6; exit }' /etc/passwd)
[ -n "$want" ] || want=/
start=$(cat /tmp/start-home)
command=$(env | sed -n 's/^HOME=//p')
[ "$start" = "$want" ] && [ "$command" = "$want" ] && homed=true || homed=false
printf '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"the node'"'"'s processes have its user'"'"'s home in HOME","condition":%s,"details":{"want":"%s","start":"%s","command":"%s"}}}\n' \
  "$homed" "$want" "$start" "$command" > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
