#!/bin/sh
# SPDX-License-Identifier: MIT
# A driver's start: a JVM on the cache, the coverage agent on (the guest's JAVA_TOOL_OPTIONS).
exec java -XX:AOTCache=/app/app.aot -cp /app/app.jar CacheDemo drive
