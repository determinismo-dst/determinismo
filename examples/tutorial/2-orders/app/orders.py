# SPDX-License-Identifier: MIT
# An order service in two roles, as a small company might run it: the API (ROLE=api) takes
# orders, and workers (ROLE=worker) charge them, all through PostgreSQL. A worker finds a pending
# order, marks it as charging, charges it and marks it charged: four statements, each committed
# on its own. Two workers can pick the same order, and a worker that dies between them leaves an
# order charging forever. And a network cut can leave a connection waiting forever on a peer that
# is gone (no keepalives, no timeouts): the API, one request at a time, then never answers again.
# docs/GETTING_STARTED.md's second tutorial finds all three. ORDERS_SAFE=1 is the fix: claim with
# FOR UPDATE SKIP LOCKED, charge and mark it in the claim's transaction, and give connections
# keepalives and timeouts (the database's, and each HTTP request's), so a dead one fails.
import http.server
import os
import time

import psycopg

ROLE = os.environ.get("ROLE", "api")
SAFE = os.environ.get("ORDERS_SAFE") == "1"
DSN = "host=db user=postgres dbname=postgres connect_timeout=3"
if SAFE:
    DSN += (" keepalives=1 keepalives_idle=2 keepalives_interval=1 keepalives_count=3"
            " tcp_user_timeout=5000 options='-c statement_timeout=5000'")


def connect():
    while True:
        try:
            return psycopg.connect(DSN, autocommit=True)
        except psycopg.OperationalError:
            time.sleep(0.2)


def schema(connection):
    connection.execute("CREATE TABLE IF NOT EXISTS orders (id bigserial PRIMARY KEY, "
                       "status text NOT NULL DEFAULT 'pending')")
    connection.execute("CREATE TABLE IF NOT EXISTS charges (order_id bigint NOT NULL)")


def charge_one(connection):
    """Charges one pending order; False when there is none."""
    if SAFE:
        with connection.transaction():
            row = connection.execute("SELECT id FROM orders WHERE status = 'pending' "
                                     "ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED").fetchone()
            if row is None:
                return False
            connection.execute("INSERT INTO charges (order_id) VALUES (%s)", row)
            connection.execute("UPDATE orders SET status = 'charged' WHERE id = %s", row)
        return True
    row = connection.execute("SELECT id FROM orders WHERE status = 'pending' "
                             "ORDER BY id LIMIT 1").fetchone()
    if row is None:
        return False
    connection.execute("UPDATE orders SET status = 'charging' WHERE id = %s", row)
    connection.execute("INSERT INTO charges (order_id) VALUES (%s)", row)
    connection.execute("UPDATE orders SET status = 'charged' WHERE id = %s", row)
    return True


def worker():
    print("orders: worker started", flush=True)
    connection = connect()
    while True:
        try:
            schema(connection)
            if not charge_one(connection):
                time.sleep(0.05)
        except psycopg.Error:
            time.sleep(0.2)
            connection = connect()


class Api(http.server.BaseHTTPRequestHandler):
    connection = None
    # The fix's other half: a request whose client went quiet (cut mid-request) gives up after
    # 10 s, instead of holding this one-request-at-a-time server forever.
    timeout = 10 if SAFE else None

    def database(self):
        if Api.connection is None or Api.connection.closed:
            Api.connection = connect()
            schema(Api.connection)
        return Api.connection

    def do_POST(self):
        try:
            row = self.database().execute("INSERT INTO orders DEFAULT VALUES RETURNING id").fetchone()
        except psycopg.Error as error:
            Api.connection = None
            return self.reply(503, f"unavailable: {error}\n")
        self.reply(200, f"{row[0]}\n")

    def do_GET(self):
        try:
            rows = self.database().execute(
                "SELECT o.id, o.status, count(c.order_id) FROM orders o "
                "LEFT JOIN charges c ON c.order_id = o.id GROUP BY o.id, o.status ORDER BY o.id").fetchall()
        except psycopg.Error as error:
            Api.connection = None
            return self.reply(503, f"unavailable: {error}\n")
        self.reply(200, "".join(f"{id} {status} {charges}\n" for id, status, charges in rows))

    def reply(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments):
        pass


if ROLE == "worker":
    worker()
else:
    print("orders: api listening on 8080", flush=True)
    http.server.HTTPServer(("0.0.0.0", 8080), Api).serve_forever()
