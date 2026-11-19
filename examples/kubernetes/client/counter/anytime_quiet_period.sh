#!/bin/sh
# Antithesis gives every container $ANTITHESIS_STOP_FAULTS, a command that pauses faults for that
# many seconds: from a pod too (ParadeDB's recovery-liveness check holds faults off so).
set -eu
"$ANTITHESIS_STOP_FAULTS" 7
echo "faults paused for 7 s"
