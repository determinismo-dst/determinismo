# SPDX-License-Identifier: MIT
# etcd-raft-node (examples/etcd-raft-joint/node): a replicated log over go.etcd.io/raft/v3 at
# 99f9ffb (etcd-io/raft#558's commit), built with determinismo's Go instrumentation
# (sdk/go/cmd/determinismo-toolexec): the raft library and the node report their blocks as
# coverage, and thread pausing pauses their goroutines there.
FROM docker.io/library/golang:1.26.10-alpine AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
COPY examples/etcd-raft-joint/node /src
RUN cd /src && go mod download
COPY sdk/go /sdk
RUN cd /sdk && go build -o /usr/local/bin/determinismo-toolexec ./cmd/determinismo-toolexec
# What is instrumented: the packages the node's coverage set holds (a build argument from the
# test program's profile; every package but the standard library's without one).
ARG DETERMINISMO_COVERAGE
RUN cd /src && GOFLAGS=-toolexec=determinismo-toolexec DETERMINISMO_SDK_DIR=/sdk \
      DETERMINISMO_INSTRUMENT=go.etcd.io/raft/v3,etcd-raft-node \
      go build -o /out/etcd-raft-node .

FROM docker.io/library/debian:bookworm-slim
COPY --from=build /out/etcd-raft-node /usr/local/bin/etcd-raft-node
ENTRYPOINT ["/usr/local/bin/etcd-raft-node"]
