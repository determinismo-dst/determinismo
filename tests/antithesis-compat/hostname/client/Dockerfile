# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY ready /usr/local/bin/ready
COPY tests/ /opt/antithesis/test/v1/named/
RUN chmod 0755 /usr/local/bin/ready /opt/antithesis/test/v1/named/singleton_driver_hostname.sh
CMD ["/usr/local/bin/ready"]
