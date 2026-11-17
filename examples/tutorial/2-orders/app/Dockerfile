# SPDX-License-Identifier: MIT
# Dependencies are fetched here, at build time: the machine determinismo runs it in has no network.
FROM docker.io/library/python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.9"
COPY orders.py /app/orders.py
CMD ["python3", "/app/orders.py"]
