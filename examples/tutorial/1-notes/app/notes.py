# SPDX-License-Identifier: MIT
# A small notes service: POST /notes/<id> stores a note, GET /notes lists their ids. It keeps
# every note in one JSON file, rewritten whole on each change: written to a temporary file, then
# renamed over the old one, so a reader never sees half a file. That looks safe. It is not, as
# determinismo shows in docs/GETTING_STARTED.md: nothing is synced to the disk before the reply.
import http.server
import json
import os

DATA = os.environ.get("NOTES_DATA", "/data/notes.json")
# The fix, behind a switch so the tutorial can run both: sync the file before the rename, and
# the directory after it, so the rename itself is on the disk.
DURABLE = os.environ.get("NOTES_DURABLE") == "1"


def load():
    try:
        with open(DATA) as file:
            return json.load(file)
    except FileNotFoundError:
        return {}


notes = load()


def save():
    temporary = DATA + ".tmp"
    with open(temporary, "w") as file:
        json.dump(notes, file)
        if DURABLE:
            file.flush()
            os.fsync(file.fileno())
    os.replace(temporary, DATA)
    if DURABLE:
        directory = os.open(os.path.dirname(DATA), os.O_RDONLY)
        os.fsync(directory)
        os.close(directory)


class Handler(http.server.BaseHTTPRequestHandler):
    # A request whose client went quiet (a network cut mid-request) gives up after 10 s rather
    # than holding this one-request-at-a-time server forever (tutorial 2 is about such hangs).
    timeout = 10

    def do_POST(self):
        note_id = self.path.rsplit("/", 1)[-1]
        length = int(self.headers.get("Content-Length", 0))
        notes[note_id] = self.rfile.read(length).decode()
        save()
        self.reply(200, "stored\n")

    def do_GET(self):
        self.reply(200, "".join(note_id + "\n" for note_id in notes))

    def reply(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments):
        pass


os.makedirs(os.path.dirname(DATA), exist_ok=True)
print("notes: listening on 8080", flush=True)
http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
