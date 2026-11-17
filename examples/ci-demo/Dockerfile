# SPDX-License-Identifier: MIT
# The CI demo's node (README.md): Python with pytest, the tests in /app.
FROM docker.io/library/python:3.12-slim
RUN pip install --no-cache-dir pytest==8.3.3
# The Python SDK, for the tests' coverage (tests/conftest.py).
COPY --from=determinismo-sdk python/determinismo.py /app/
COPY examples/ci-demo/tests /app/tests
WORKDIR /app
CMD ["sleep", "infinity"]
