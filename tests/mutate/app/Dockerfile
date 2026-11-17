# SPDX-License-Identifier: MIT
# The node under mutation (tests/mutate/sum_test.zig): sum.sh, which the mutants patch. It also
# takes a file of the SDK the explorer carries (the build context determinismo-sdk, src/prepare.zig),
# as the examples' instrumented builds do: without that context this image does not build.
FROM docker.io/library/alpine:3.20
COPY --from=determinismo-sdk c/determinismo.h /opt/determinismo-sdk/determinismo.h
COPY sum.sh /usr/local/bin/sum.sh
RUN chmod +x /usr/local/bin/sum.sh
