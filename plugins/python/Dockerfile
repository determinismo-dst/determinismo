# SPDX-License-Identifier: MIT
# extremes.py as a container image: a strategy whose dependencies come with it, run with
# `--strategy image:<reference>` (src/strategy.zig: podman run --rm -i, the entrypoint the plugin).
# The e2e python check builds it from the repository's root:
#   podman build --tag localhost/determinismo-strategy-extremes:1 --file plugins/python/Dockerfile .
FROM docker.io/library/python:3.13-slim
# Python's standard library compiled here: the image ships it without bytecode, so a first start
# writes it, unsynced, and a power loss persisting part of that tears a .pyc (its header kept, its
# body cut): Python then fails to start (EOFError from _compile_bytecode, CPython #72194; local-fs
# hunt run 1019, 161 timelines). Nothing written at run time either.
RUN python3 -m compileall -q -j 0 "$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')"
ENV PYTHONDONTWRITEBYTECODE=1
COPY plugins/python/determinismo_strategy.py plugins/python/extremes.py /plugin/
ENTRYPOINT ["python3", "/plugin/extremes.py"]
