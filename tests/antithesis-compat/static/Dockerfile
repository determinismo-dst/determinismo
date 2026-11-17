# SPDX-License-Identifier: MIT
# A static program without libc (prog.c: its own _start, no constructors run), built with clang's
# trace-pc-guard and stack depth (as Zig's own trace-pc-guard instruments: each function's entry
# writes a thread-local the coverage runtime defines) and linked with the SDK's
# lib/libvoidstar.o, the binary in /symbols.
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache clang lld
COPY --from=determinismo-sdk lib/libvoidstar.o /sdk/libvoidstar.o
COPY tests/antithesis-compat/static/ /src/static/
WORKDIR /src/static
RUN clang -g -O1 -ffreestanding -fno-builtin -fno-stack-protector -fsanitize-coverage=trace-pc-guard,stack-depth -c prog.c -o prog.o && \
    clang -fuse-ld=lld -nostdlib -static -Wl,--build-id -o /usr/local/bin/static-prog prog.o /sdk/libvoidstar.o && \
    mkdir -p /symbols /opt/antithesis/test/v1/run && cp /usr/local/bin/static-prog /symbols/static-prog && \
    cp run/singleton_driver_run.sh /opt/antithesis/test/v1/run/ && chmod +x /opt/antithesis/test/v1/run/*
CMD ["sleep", "infinity"]
