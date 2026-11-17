# SPDX-License-Identifier: MIT
# A minimal nREPL client (bencode over TCP): evaluates forms in phases and prints jank's RSS
# (read by the caller's hook) every 100 evaluations.
import socket, subprocess, sys

def encode(value):
    if isinstance(value, int): return b"i%de" % value
    if isinstance(value, str): value = value.encode()
    if isinstance(value, bytes): return b"%d:%s" % (len(value), value)
    if isinstance(value, dict):
        return b"d" + b"".join(encode(k) + encode(v) for k, v in sorted(value.items())) + b"e"
    raise TypeError(value)

def decode(data, i=0):
    c = data[i:i+1]
    if c == b"i":
        end = data.index(b"e", i); return int(data[i+1:end]), end + 1
    if c == b"d":
        i += 1; out = {}
        while data[i:i+1] != b"e":
            k, i = decode(data, i); v, i = decode(data, i); out[k] = v
        return out, i + 1
    if c == b"l":
        i += 1; out = []
        while data[i:i+1] != b"e":
            v, i = decode(data, i); out.append(v)
        return out, i + 1
    colon = data.index(b":", i); n = int(data[i:colon])
    return data[colon+1:colon+1+n], colon + 1 + n

class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=60); self.buf = b""; self.id = 0
    def eval(self, code):
        self.id += 1
        self.s.sendall(encode({"op": "eval", "code": code, "id": str(self.id)}))
        value = None
        while True:
            while True:
                try:
                    msg, end = decode(self.buf); break
                except (ValueError, IndexError):
                    chunk = self.s.recv(65536)
                    if not chunk: raise EOFError
                    self.buf += chunk
            self.buf = self.buf[end:]
            if b"value" in msg: value = msg[b"value"]
            if b"status" in msg and b"done" in msg[b"status"]: return value

def rss(container):
    out = subprocess.run(["podman", "exec", container, "sh", "-c",
        "for p in /proc/[0-9]*; do grep -q '^Name:.jank$' $p/status 2>/dev/null && grep VmRSS $p/status; done"],
        capture_output=True, text=True).stdout.split()
    return int(out[1]) // 1024 if len(out) > 1 else -1

port, container, count = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
import time
# Podman's port forwarder accepts before the server listens: until an evaluation is answered.
for attempt in range(240):
    try:
        client = Client(port)
        if client.eval("(+ 1 1)") == b"2": break
    except (OSError, EOFError):
        pass
    time.sleep(1)
else:
    sys.exit("the server never answered")
all_phases = {
    "distinct": ("plain (+ n 1)", lambda n: "(+ %d 1)" % n),
    "same": ("the same (+ 1 1)", lambda n: "(+ 1 1)"),
    "def": ("def of 64 names", lambda n: "(def shared-%d %d)" % (n % 64, n)),
    "defn": ("defn of 64 names", lambda n: "(defn shared-fn-%d [] %d)" % (n % 64, n)),
    "call": ("a call of one of 64 defined fns", lambda n: "(shared-fn-%d)" % (n % 64)),
}
phases = [all_phases[name] for name in (sys.argv[4].split(",") if len(sys.argv) > 4 else ["distinct", "def", "defn"])]
print("start rss_mib", rss(container), flush=True)
for name, form in phases:
    before = rss(container)
    for n in range(count):
        client.eval(form(n))
        if (n + 1) % 100 == 0: print(name, n + 1, "rss_mib", rss(container), flush=True)
    after = rss(container)
    print("PHASE", name, "per evaluation KiB", round((after - before) * 1024 / count, 1), flush=True)
