# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY ready /usr/local/bin/ready
COPY tests/ /opt/antithesis/test/v1/checks/
# The valid command and the helper executable; one named as a command left without chmod +x.
RUN chmod 0755 /usr/local/bin/ready /opt/antithesis/test/v1/checks/singleton_driver_ok.sh \
      /opt/antithesis/test/v1/checks/eventually_no_shebang /opt/antithesis/test/v1/checks/helper.sh \
 && chmod 0644 /opt/antithesis/test/v1/checks/anytime_forgot_chmod.sh
CMD ["/usr/local/bin/ready"]
