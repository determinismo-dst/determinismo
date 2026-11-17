# SPDX-License-Identifier: MIT
# The race in JavaScript (examples/race/javascript): Node.js worker threads, the JavaScript SDK's
# coverage on raceworker.js alone, its positions where thread pausing pauses the workers.
FROM docker.io/library/node:22-bookworm-slim
WORKDIR /app
COPY sdk/javascript/determinismo.js examples/race/javascript/race.js examples/race/javascript/racerun.js examples/race/javascript/raceworker.js /app/
ENTRYPOINT ["node", "/app/race.js"]
