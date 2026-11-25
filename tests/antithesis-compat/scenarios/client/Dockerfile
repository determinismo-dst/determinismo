# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY ready /usr/local/bin/ready
COPY false/ /opt/antithesis/test/v1/rare_false/
COPY true/ /opt/antithesis/test/v1/rare_true/
RUN chmod 0755 /usr/local/bin/ready /opt/antithesis/test/v1/rare_false/singleton_driver_rare.sh \
      /opt/antithesis/test/v1/rare_true/singleton_driver_rare.sh
CMD ["/usr/local/bin/ready"]
