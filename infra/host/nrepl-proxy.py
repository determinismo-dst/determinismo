#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""nrepl-proxy.py: an nREPL server here that is a REPL inside a guest, at a moment of a run's
timeline. Any nREPL client connects to it (CIDER, Calva, `lein repl :connect`).

    infra/host/nrepl-proxy.py --serve http://<host>:7878 --run 436 --branch 0 \\
      --at-ms 60000 --node client [--listen 127.0.0.1:7888]

What it does:
  - serve replays the timeline to the moment and holds it there (a session: POST
    /runs/<id>/session);
  - in the node, `/opt/workload/run nrepl <port>` starts the program's nREPL server, in the
    background (determinismo.workload);
  - the session's relay (`det-nrepl-relay serve`) holds one connection to it; each message a
    client sends is one step (det:ask): written to the relay's FIFO by the guest's agent, no
    process started, the machine run until the relay says the message is done, its replies
    events in the step's output.

The machine runs only while a step does: the session is a function of its steps, recorded with
their moments as a timeline of the run (its next number: the run's tapes and events have it,
its replay is the session again). With --live the guest runs on between messages, each message
at a moment it prints. Ctrl-C ends the session (the timeline released).

Two ops of the proxy's own, from any client (CIDER: `(nrepl-send-sync-request
'("op" "det-checkpoint" "name" "loaded"))`): `det-checkpoint` saves the machine where the REPL
is (det:checkpoint: a session at it starts from the machine, not from boot), its value
`{"name":...,"vtime_ns":...,"saved":true}`; `det-resume` ends the session and opens one at the
last checkpoint of that name (after a crash, a wedged server, an experiment gone wrong), the
REPL as it was there: nREPL sessions cloned after it are gone (the client reconnects).

On a machine that opens bundles (an inspection machine: docs/INSPECT.md), with no serve:
    nrepl-proxy.py --bundle ~/<bundle> --node client [--listen 127.0.0.1:7888]
the bundle's own explorer runs its timeline from the moment's snapshot (bundle-moment.sh's: a
session starting in a second, no replay from the start), speaking the steps serve's sessions
speak (explore --exec-interactive), and the REPL is the same. From your laptop:
`ssh -L 7888:127.0.0.1:7888 admin@<machine>`, then connect CIDER or Calva to localhost:7888."""
import argparse
import base64
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

# A det:send is one agent action (a page at most): a message goes in parts this large.
PART_BYTES = 2400


class Serve:
    """serve's HTTP API over one kept connection (a step answers in milliseconds: no connection
    made for each)."""

    def __init__(self, url):
        parsed = urllib.parse.urlparse(url)
        self.host, self.port = parsed.hostname, parsed.port or 80
        self.connection = None

    def post(self, path, body):
        for attempt in range(2):
            if self.connection is None:
                self.connection = http.client.HTTPConnection(self.host, self.port, timeout=3600)
            try:
                self.connection.request("POST", path, body=json.dumps(body),
                                        headers={"Content-Type": "application/json"})
                return json.loads(self.connection.getresponse().read())
            except (http.client.HTTPException, ConnectionError):
                self.connection.close()
                self.connection = None
                if attempt == 1:
                    raise


class Local:
    """serve's session API, played by a bundle's own explorer here (--bundle): its timeline from
    the moment's snapshot, explore --exec-interactive's steps on its standard input, each reply
    ending with serve's step marker, `done` once it exits."""

    marker = b"[determinismo] step done\n"

    def __init__(self, bundle):
        self.bundle = os.path.abspath(bundle)
        self.process = None
        self.pending = b""

    def start(self, live):
        inspect = open(os.path.join(self.bundle, "INSPECT.sh")).read()
        explorer = re.search(r"\./(artifacts/\S+-determinismo) explore", inspect)[1]
        branch = re.search(r"--branch (\d+)", inspect)[1]
        snapshot = re.search(r"--tape-snapshot (\S+)", inspect)[1]
        at = re.search(r"--at-vtime-ms (\d+)", inspect)[1]
        # INSPECT.sh decompresses the snapshots and makes the explorer runnable: once, for nothing.
        subprocess.run(["./INSPECT.sh", "true"], cwd=self.bundle, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        argv = [f"./{explorer}", "explore", "--run", ".", "--branch", branch,
                "--tape-snapshot", snapshot, "--at-vtime-ms", at,
                "--exec-live" if live else "--exec-interactive"]
        self.process = subprocess.Popen(argv, cwd=self.bundle, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(f"nrepl-proxy: {os.path.basename(self.bundle)}'s timeline {branch} at {int(at)} ms "
              "(its snapshot)", file=sys.stderr)
        return self.wait()

    def wait(self):
        while self.marker not in self.pending:
            chunk = self.process.stdout.read1(65536)
            if not chunk:
                output, self.pending = self.pending, b""
                return {"output": output.decode(errors="replace"), "done": True}
            self.pending += chunk
        output, self.pending = self.pending.split(self.marker, 1)
        return {"output": output.decode(errors="replace"), "done": False}

    def post(self, path, body):
        if path.endswith("/session"):
            reply = self.start(body.get("live", False))
            return dict(reply, session=0)
        if path.endswith("/step"):
            self.process.stdin.write(body["exec"].encode() + b"\n")
            self.process.stdin.flush()
            return self.wait()
        if path.endswith("/end"):
            self.process.stdin.close()
            output = b""
            while True:
                reply = self.wait()
                output += reply["output"].encode()
                if reply["done"]:
                    return {"output": output.decode(errors="replace"), "done": True}
        raise ValueError(path)


class Session:
    def __init__(self, serve, run, branch, moment, node, port, live):
        self.serve = serve if isinstance(serve, Local) else Serve(serve)
        self.node, self.port = node, port
        self.lock = threading.Lock()
        self.relay_up = False
        # The relay's FIFO: in the tmpfs every node and the runner share.
        self.fifo = f"/opt/determinismo/records/.nrepl-{port}"
        reply = self.serve.post(f"/runs/{run}/session", dict(moment, branch=branch, live=live))
        if reply["done"]:
            sys.exit("the replay ended before its moment:\n" + reply["output"][-4000:])
        self.id = reply["session"]
        # The session's timeline (a checkpoint's), and whether the relay was up at each
        # checkpoint: a session resumed there has it as it was.
        self.run, self.live = run, live
        self.timeline = reply.get("timeline", branch)
        self.relay_at = {}
        print(f"nrepl-proxy: session {self.id} at {moment} of run {run}'s timeline {branch}",
              file=sys.stderr)

    def step(self, command):
        with self.lock:
            reply = self.serve.post(f"/sessions/{self.id}/step", {"exec": command})
        if reply["done"]:
            raise SystemExit("nrepl-proxy: the session ended:\n" + reply["output"][-4000:])
        return reply["output"]

    def start_server(self):
        """The session's relay (one connection to the program's nREPL server for the whole
        session), up once it says it is ready: at once when the server is warm (the node's
        command, up before the setup's snapshot), else once the program's server, started now,
        listens."""
        self.step(f"det:background det-nodes exec {self.node} /opt/determinismo/bin/det-nrepl-relay "
                  f"serve {self.port} {self.fifo}")
        output = self.step("det:until 1500 event=nrepl_relay_ready")
        if "nrepl_relay_ready" not in output and self.node_stopped():
            # Its server was the node's own command, and it died: the node starts again (its
            # relay, retrying, connects once the server listens).
            self.step(f"det:background det-nodes start {self.node}")
            output = self.step("det:until 180000 event=nrepl_relay_ready")
        if "nrepl_relay_ready" not in output:
            self.step(f"det:background det-nodes exec {self.node} /opt/workload/run nrepl {self.port}")
            output = self.step("det:until 180000 event=nrepl_relay_ready")
        if "nrepl_relay_ready" not in output:
            sys.exit("nrepl-proxy: the guest's nREPL server did not start:\n" + output[-4000:])
        self.relay_up = True

    def node_stopped(self):
        """Whether the node has no live main process (det-nodes list's state)."""
        for line in self.step("det-nodes list").splitlines():
            if f'\\"name\\":\\"{self.node}\\"' in line or f'"name":"{self.node}"' in line:
                return "stopped" in line
        return False

    def checkpoint(self, name):
        """det:checkpoint: what it said ({"name", "vtime_ns", "saved"})."""
        output = self.step(f"det:checkpoint {name}")
        for line in output.splitlines():
            if line.startswith("[determinismo] checkpoint: "):
                self.relay_at[name] = self.relay_up
                return line[len("[determinismo] checkpoint: "):]
        raise ValueError("no checkpoint said:\n" + last_lines(output))

    def resume(self, name):
        """This session ended and one opened at the last checkpoint named `name` of its timeline
        (or of those it extends: a session resumed before): its timeline."""
        if isinstance(self.serve, Local):
            raise ValueError("a bundle's session has no run to resume in")
        named = f'event=session_checkpoint details.name="{name}"'
        with self.lock:
            try:
                self.serve.post(f"/sessions/{self.id}/end", {})
            except (ValueError, OSError, http.client.HTTPException):
                pass  # Ended already (its explorer gone): the new one opens all the same.
            reply = self.serve.post(f"/runs/{self.run}/session", {
                "branch": self.timeline, "until": named, "not_followed_by": named, "live": self.live})
        if reply.get("done", True):
            raise ValueError("the session at the checkpoint ended at once:\n" + reply.get("output", "")[-2000:])
        self.id, self.timeline = reply["session"], reply.get("timeline", self.timeline)
        # Up at the checkpoint unless said otherwise: this proxy starts its relay first.
        self.relay_up = self.relay_at.get(name, True)
        print(f"nrepl-proxy: session {self.id} at checkpoint {name!r} (timeline {self.timeline})",
              file=sys.stderr)
        return json.dumps({"session": self.id, "timeline": self.timeline})

    def platform_op(self, op, decoded):
        """A det-checkpoint or det-resume message's reply."""
        name = decoded.get("name", b"").decode()
        reply = {"id": decoded.get("id", b""), "session": decoded.get("session", b"")}
        try:
            value = self.checkpoint(name) if op == "det-checkpoint" else self.resume(name)
            reply.update({"value": value, "status": ["done"]})
        except (Exception, SystemExit) as error:
            reply.update({"err": f"nrepl-proxy: {op}: {error}\n", "status": ["done", "error"]})
        return encode(reply)

    def send(self, message):
        """The replies to one message (bencoded bytes each): a det:ask step, the message written
        to the relay's FIFO in parts, the machine run until the relay says it is done."""
        decoded, _ = decode(message, 0)
        op = decoded.get("op", b"").decode() if isinstance(decoded, dict) else ""
        if op in ("det-checkpoint", "det-resume"):
            return [self.platform_op(op, decoded)]
        message_id = decoded.get("id", b"").decode() if isinstance(decoded, dict) else ""
        if not message_id:
            # The relay finds a message's end by its id: one is given.
            message_id = f"det-{threading.get_ident()}-{id(message)}"
            decoded["id"] = message_id.encode()
            message = encode(decoded)
        parts = [base64.b64encode(message[at:at + PART_BYTES]).decode()
                 for at in range(0, len(message), PART_BYTES)]
        if not self.relay_up:
            self.start_server()
        output = self.step(f"det:ask {self.fifo} {message_id} {' '.join(parts)}")
        replies = replies_of(output)
        if "nrepl_relay_closed" in output or not any(b"4:done" in r for r in replies):
            # No done reply: the server's connection closed (its process died: a crash in what
            # it ran) or the relay is gone. The client is told now, with the node's last lines,
            # and the next message starts the server again (the session goes on).
            self.relay_up = False
            replies.append(encode({
                "id": message_id, "session": decoded.get("session", b""),
                "err": (f"nrepl-proxy: the nREPL server in node {self.node} closed its connection "
                        f"without answering (its process exited?); it starts again at the next "
                        f"message. The machine's last lines:\n{last_lines(output)}\n").encode(),
                "status": ["done", "error", "eval-error"],
            }))
        return replies

    def end(self):
        with self.lock:
            self.serve.post(f"/sessions/{self.id}/end", {})


def replies_of(output):
    """The relay's replies in a step's output: its nrepl_reply events, parts put together."""
    replies, pending = [], b""
    for line in output.splitlines():
        if not line.startswith("[guest @") or "nrepl_reply" not in line:
            continue
        event = json.loads(line.split("] ", 1)[1])
        if event.get("event") != "nrepl_reply":
            continue
        details = event["details"]
        pending += base64.b64decode(details["data"])
        if details["last"]:
            replies.append(pending)
            pending = b""
    return replies


def last_lines(output, count=12):
    """A step's output as a person reads it: guest lines that are not the relay's own events."""
    kept = [line for line in output.splitlines()
            if "nrepl_reply" not in line and "det-nrepl-relay" not in line and line.strip()]
    return "\n".join(kept[-count:])


def encode(value):
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(encode(v) for v in value) + b"e"
    if isinstance(value, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in value.items())
        return b"d" + b"".join(encode(k) + encode(v) for k, v in items) + b"e"
    raise TypeError(value)


def decode(data, at):
    head = data[at:at + 1]
    if head == b"i":
        end = data.index(b"e", at)
        return int(data[at + 1:end]), end + 1
    if head in (b"l", b"d"):
        at += 1
        items = []
        while data[at:at + 1] != b"e":
            item, at = decode(data, at)
            items.append(item)
        if head == b"l":
            return items, at + 1
        return {items[i].decode(): items[i + 1] for i in range(0, len(items), 2)}, at + 1
    colon = data.index(b":", at)
    size = int(data[at:colon])
    return data[colon + 1:colon + 1 + size], colon + 1 + size


def bencode_end(data, at):
    """Where the bencoded value at `at` ends, or None when data does not hold all of it."""
    if at >= len(data):
        return None
    head = data[at:at + 1]
    if head == b"i":
        end = data.find(b"e", at)
        return None if end < 0 else end + 1
    if head in (b"l", b"d"):
        position = at + 1
        while True:
            if position >= len(data):
                return None
            if data[position:position + 1] == b"e":
                return position + 1
            position = bencode_end(data, position)
            if position is None:
                return None
    colon = data.find(b":", at)
    if colon < 0:
        return None
    end = colon + 1 + int(data[at:colon])
    return None if end > len(data) else end


class DevSession:
    """A REPL in a fast VM's node (`determinismo run --vcpus N --dev <dir>`, docs/DEVELOPING.md):
    no moment, no steps; the guest runs on. The same relay as a session's, its messages given
    to the guest's agent through the dev control FIFO (`action det:send ...`), its replies read
    from the guest's events (<dir>/events.jsonl) as they come."""

    def __init__(self, directory, node, port):
        self.directory, self.node, self.port = directory, node, port
        self.fifo = f"/opt/determinismo/records/.nrepl-{port}"
        self.lock = threading.Lock()
        self.relay_up = False
        self.events = open(os.path.join(directory, "events.jsonl"), "rb")
        self.events.seek(0, os.SEEK_END)
        # Kept across calls: a line read in part, and events read past the one a call waited
        # for (dropped with each call's own once: a reply's part lost, the next message's
        # replies began with another's bytes and the client's bencode broke, clj-orders).
        self.pending = b""
        self.backlog = []
        print(f"nrepl-proxy: the fast VM in {directory}, node {node}", file=sys.stderr)

    def action(self, text):
        with open(os.path.join(self.directory, "control"), "w") as control:
            control.write(f"action {text}\n")

    def events_until(self, done, timeout_s):
        """The guest's events from here until one makes `done` true (or the timeout)."""
        seen, deadline = [], time.time() + timeout_s
        while True:
            while self.backlog:
                event = self.backlog.pop(0)
                seen.append(event)
                if done(event):
                    return seen
            if time.time() >= deadline:
                return seen
            chunk = self.events.read()
            if not chunk:
                time.sleep(0.005)
                continue
            self.pending += chunk
            *lines, self.pending = self.pending.split(b"\n")
            for line in lines:
                try:
                    self.backlog.append(json.loads(line).get("event", {}))
                except ValueError:
                    print(f"nrepl-proxy: an event line unreadable: {line[:120]!r}", file=sys.stderr)

    def start_server(self):
        """The relay started in the node, again until it reaches the server: the machine may
        still be setting up (its nodes not up: det-nodes refuses) or the server starting."""
        deadline = time.time() + 900
        while time.time() < deadline:
            self.action(f"det:background det-nodes exec {self.node} /opt/determinismo/bin/det-nrepl-relay "
                        f"serve {self.port} {self.fifo}")
            relay = {}

            def ended(event):
                details = event.get("details", {}) if isinstance(event.get("details"), dict) else {}
                if event.get("event") == "exec_start" and "det-nrepl-relay" in details.get("command", ""):
                    relay["id"] = details.get("id")
                if event.get("event") == "exec_done" and details.get("id") == relay.get("id"):
                    return True  # Exited before it was ready: not yet.
                return event.get("event") == "nrepl_relay_ready"

            seen = self.events_until(ended, 300)
            if any(e.get("event") == "nrepl_relay_ready" for e in seen):
                self.relay_up = True
                return
            time.sleep(2)
        sys.exit("nrepl-proxy: the relay did not reach the node's nREPL server in 15 minutes")

    def send(self, message):
        decoded, _ = decode(message, 0)
        message_id = decoded.get("id", b"").decode() if isinstance(decoded, dict) else ""
        if not message_id:
            message_id = f"det-{threading.get_ident()}-{id(message)}"
            decoded["id"] = message_id.encode()
            message = encode(decoded)
        with self.lock:
            if not self.relay_up:
                self.start_server()
            for at in range(0, len(message), PART_BYTES):
                self.action(f"det:send {self.fifo} {base64.b64encode(message[at:at + PART_BYTES]).decode()}")
            finished = lambda e: (e.get("event") == "nrepl_done" and e.get("details", {}).get("id") == message_id) \
                or e.get("event") == "nrepl_relay_closed"
            seen = self.events_until(finished, 3600)
        replies, pending = [], b""
        for event in seen:
            if event.get("event") != "nrepl_reply":
                continue
            details = event["details"]
            pending += base64.b64decode(details["data"])
            if details["last"]:
                replies.append(pending)
                pending = b""
        if not any(e.get("event") == "nrepl_done" for e in seen):
            self.relay_up = False
            replies.append(encode({
                "id": message_id, "session": decoded.get("session", b""),
                "err": (f"nrepl-proxy: the nREPL server in node {self.node} closed its connection "
                        f"without answering (its process exited?); it starts again at the next "
                        f"message.\n").encode(),
                "status": ["done", "error", "eval-error"],
            }))
        return replies

    def end(self):
        pass


def client_serve(session, connection):
    buffer = b""
    with connection:
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                return
            buffer += chunk
            while True:
                end = bencode_end(buffer, 0)
                if end is None:
                    break
                message, buffer = buffer[:end], buffer[end:]
                for reply in session.send(message):
                    connection.sendall(reply)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--serve", help="serve's URL (with --run)")
    parser.add_argument("--run", type=int)
    parser.add_argument("--bundle", help="or a bundle here, opened at its moment (its snapshot)")
    parser.add_argument("--dev", help="or a fast VM's dev directory (determinismo run --dev): a REPL "
                        "in its node as it runs, no moment, no steps")
    parser.add_argument("--branch", type=int, default=0)
    parser.add_argument("--at-ms", type=int, help="the session's moment, in virtual time")
    parser.add_argument("--until", default="event=composer_start",
                        help="or the first event matching this (query.zig): by default where the "
                        "scenario's commands begin")
    parser.add_argument("--node", required=True, help="the node whose program serves the REPL")
    parser.add_argument("--port", type=int, default=7888, help="the guest's nREPL port")
    parser.add_argument("--listen", default="127.0.0.1:7888")
    parser.add_argument("--live", action="store_true",
                        help="the guest runs on between messages (each at a moment it prints)")
    arguments = parser.parse_args()
    if arguments.dev:
        serve = None
    elif arguments.bundle:
        serve, run, moment = Local(arguments.bundle), 0, {}
    elif arguments.serve and arguments.run is not None:
        serve, run = arguments.serve.rstrip("/"), arguments.run
        moment = {"at_vtime_ms": arguments.at_ms} if arguments.at_ms is not None else {"until": arguments.until}
    else:
        parser.error("--serve and --run, --bundle, or --dev")
    if arguments.dev:
        session = DevSession(arguments.dev, arguments.node, arguments.port)
    else:
        session = Session(serve, run, arguments.branch, moment, arguments.node, arguments.port,
                          arguments.live)
    try:
        session.start_server()
        host, port = arguments.listen.rsplit(":", 1)
        listener = socket.create_server((host, int(port)))
        print(f"nrepl-proxy: nREPL on {arguments.listen} (a REPL in {arguments.node})", file=sys.stderr)
        # A .nrepl-port for editors that look for one.
        with open(".nrepl-port", "w") as port_file:
            port_file.write(port)
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=client_serve, args=(session, connection), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        session.end()


if __name__ == "__main__":
    main()
