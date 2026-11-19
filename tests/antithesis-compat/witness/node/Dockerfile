# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY start /usr/local/bin/start
RUN chmod 0755 /usr/local/bin/start
CMD ["/usr/local/bin/start", "node"]
