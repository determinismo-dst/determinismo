# SPDX-License-Identifier: MIT
# The race in Java (examples/race/java), with the JVM SDK's coverage agent on RaceRun alone
# (JDK 24+): its probes, one per line and one after each conditional branch, are where thread
# pausing pauses threads.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java sdk/java/DeterminismoCoverage.java sdk/java/DeterminismoCoverageInstrument.java /app/sdk/
COPY examples/race/java/Race.java examples/race/java/RaceRun.java /app/race/
RUN mkdir -p /app/sdk-classes /app/classes && javac -d /app/sdk-classes /app/sdk/*.java && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /app/coverage.manifest && \
    jar cfm /app/determinismo-coverage.jar /app/coverage.manifest -C /app/sdk-classes . && \
    javac -d /app/classes /app/race/*.java
ENTRYPOINT ["java", "-XX:TieredStopAtLevel=1", "-javaagent:/app/determinismo-coverage.jar=RaceRun", "-cp", "/app/classes", "Race"]
