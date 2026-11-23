# SPDX-License-Identifier: MIT
# The JVM caches' image (tools/e2e.zig's jvm-caches): an app whose JDK AOT cache (JEP 514) its
# build trains (train.sh), labeled for determinismo to train it again with the coverage agent's
# module and its classes instrumented ahead (src/prepare.zig's jvm_caches, docs/CI.md). With
# CACHES empty (unlabeled.yaml) no label: the image's own cache, which the agent makes refused.
FROM docker.io/library/eclipse-temurin:25-jdk-alpine
ARG CACHES=/app/train.sh
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCoverage.java sdk/java/DeterminismoCoverageInstrument.java /app/sdk/
COPY tests/jvm-caches/CacheDemo.java /app/src/
COPY tests/jvm-caches/train.sh /app/train.sh
COPY tests/jvm-caches/main/ /opt/antithesis/test/v1/main/
# The SDK in the app's jar: the classes instrumented ahead call its DeterminismoCoverage, also
# while the cache is trained (no agent then).
RUN javac -d /app/classes /app/sdk/*.java /app/src/CacheDemo.java && jar cf /app/app.jar -C /app/classes . && \
    rm -rf /app/classes && chmod +x /app/train.sh /opt/antithesis/test/v1/main/* && /app/train.sh
LABEL determinismo.jvm-caches="$CACHES" determinismo.jvm-jars="CacheDemo /app/app.jar"
CMD ["sh", "-c", "exec java -XX:AOTCache=/app/app.aot -cp /app/app.jar CacheDemo serve"]
