# SPDX-License-Identifier: MIT
# The crash points' server (crash-points.yaml): the SDK and its coverage agent in one jar, the
# server next to it; no test templates (the client's are the scenario's).
FROM docker.io/library/eclipse-temurin:25-jdk-alpine
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCoverage.java /app/sdk/
COPY tests/antithesis-compat/java/server/StateServer.java /app/src/
RUN javac -d /app/sdk-classes /app/sdk/*.java && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /app/manifest && \
    jar cfm /app/determinismo-coverage.jar /app/manifest -C /app/sdk-classes . && \
    javac -cp /app/sdk-classes -d /app/classes /app/src/StateServer.java
CMD ["sh", "-c", "exec java -XX:TieredStopAtLevel=1 -javaagent:/app/determinismo-coverage.jar=StateServer -cp /app/classes:/app/determinismo-coverage.jar StateServer"]
