# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY ready /usr/local/bin/ready
COPY tests/ /opt/antithesis/test/v1/home/
RUN chmod 0755 /usr/local/bin/ready /opt/antithesis/test/v1/home/singleton_driver_home.sh
CMD ["/usr/local/bin/ready"]
