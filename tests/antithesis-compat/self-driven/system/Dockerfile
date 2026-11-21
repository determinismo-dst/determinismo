# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY workload /usr/local/bin/workload
COPY tests/ /opt/antithesis/test/v1/main/
RUN chmod 0755 /usr/local/bin/workload /opt/antithesis/test/v1/main/first_start_workload
CMD ["/usr/local/bin/workload"]
