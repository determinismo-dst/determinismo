# SPDX-License-Identifier: MIT
FROM docker.io/library/python:3.12-alpine
# Python's standard library compiled here: the image ships it without bytecode, so a first start
# writes it, unsynced, and a power loss persisting part of that tears a .pyc (its header kept, its
# body cut): Python then fails to start (EOFError from _compile_bytecode, CPython #72194; local-fs
# hunt run 1019, 161 timelines). Nothing written at run time either.
RUN python3 -m compileall -q -j 0 "$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')"
ENV PYTHONDONTWRITEBYTECODE=1
COPY sdk/python/determinismo.py /usr/local/lib/python3.12/site-packages/determinismo.py
COPY tests/antithesis-compat/python/client/bank.py /usr/local/lib/python3.12/site-packages/bank.py
COPY tests/antithesis-compat/python/client/tests/ /opt/antithesis/test/v1/bank/
COPY tests/antithesis-compat/python/client/maze/ /opt/antithesis/test/v1/maze/
COPY tests/antithesis-compat/python/client/mazes/ /opt/antithesis/test/v1/mazes/
RUN chmod +x /opt/antithesis/test/v1/bank/* /opt/antithesis/test/v1/maze/* /opt/antithesis/test/v1/mazes/*
CMD ["sleep", "infinity"]
