# SPDX-License-Identifier: MIT
# The race in Go (examples/race/go), built with determinismo's Go instrumentation
# (sdk/go/cmd/determinismo-toolexec): package run's blocks call the Go SDK's coverage package,
# where thread pausing pauses goroutines. The runner (package main) is not instrumented.
FROM docker.io/library/golang:1.24-alpine AS build
COPY sdk/go /sdk
COPY examples/race/go /src
RUN cd /sdk && go build -o /usr/local/bin/determinismo-toolexec ./cmd/determinismo-toolexec
RUN cd /src && CGO_ENABLED=0 GOFLAGS=-toolexec=determinismo-toolexec DETERMINISMO_SDK_DIR=/sdk \
      DETERMINISMO_INSTRUMENT=race/run go build -o /race-go .
FROM scratch
COPY --from=build /race-go /race
ENTRYPOINT ["/race"]
