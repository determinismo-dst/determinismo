# SPDX-License-Identifier: MIT
# The repl check's node: a JVM with nREPL and CIDER's middleware, the program's sources.
FROM docker.io/library/clojure:temurin-25-tools-deps-1.12.6.1673-trixie-slim
COPY tests/repl/deps.edn /opt/workload/deps.edn
RUN cd /opt/workload && clojure -P && clojure -Spath > /opt/workload/classpath
COPY sdk/clojure /opt/workload/src
COPY tests/repl/repl_test.clj /opt/workload/src/
COPY tests/repl/client-run /opt/workload/run
