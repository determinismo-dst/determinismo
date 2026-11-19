# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY ready /usr/local/bin/ready
COPY tests/ /opt/antithesis/test/v1/wait/
RUN chmod 0755 /usr/local/bin/ready /opt/antithesis/test/v1/wait/singleton_driver_wait.sh
CMD ["/usr/local/bin/ready"]
