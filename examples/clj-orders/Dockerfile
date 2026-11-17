# SPDX-License-Identifier: MIT
# The orders service's node (README.md): a JVM with nREPL on 7888 and the service's libraries
# (Kafka's client, next.jdbc, Postgres's driver) and determinismo's Clojure SDK on its classpath.
# Nothing of the service is written here: it is developed at the REPL, in a fast VM.
FROM docker.io/library/clojure:temurin-25-tools-deps-1.12.6.1673-trixie-slim
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
COPY examples/clj-orders/deps.edn /opt/app/deps.edn
RUN cd /opt/app && clojure -P && clojure -Spath > /opt/app/classpath
COPY sdk/clojure /opt/app/src
# The test templates (Antithesis's layout): the scenario timelines explored from the REPL's
# machine run, calling the service written there.
COPY examples/clj-orders/test /opt/antithesis/test/v1
WORKDIR /opt/app
EXPOSE 7888
CMD ["sh", "-c", "exec java --enable-native-access=ALL-UNNAMED -XX:+UseSerialGC -Xmx512m -cp \"/opt/app/src:$(cat /opt/app/classpath)\" clojure.main -m nrepl.cmdline --bind 0.0.0.0 --port 7888 --middleware '[cider.nrepl/cider-middleware]'"]
