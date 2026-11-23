#!/bin/sh
# SPDX-License-Identifier: MIT
# The JDK's AOT cache of a start (JEP 514), made by the image's build and again by determinismo
# (the Dockerfile's labels): the jar at time 0 first, as the guest's image has it (a jar whose
# time changed since the training is refused).
set -e
find /app -name '*.jar' -exec touch -h -d @0 {} +
exec java -XX:AOTCacheOutput=/app/app.aot -cp /app/app.jar CacheDemo train
