#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""bundle-view.py <run directory> <bundle>: what serve shows of a run, for the timelines a bundle
carries (its tapes/branch-<n>.jsonl: the timeline and those it began inside), copied into the
bundle beside them, so that serve opens the bundle as a run of its own on an inspection machine
(infra/aws/serve-bundle.sh): the run's record (its run, snapshot and generation lines, and those
timelines' lines), their events (events/branch-<n>.jsonl.zst), the setup's events and the timelines'
summaries (events/timelines.jsonl). Serve builds its database (events.duckdb) from them there.
A NATS timeline's events are about a megabyte."""
import json
import os
import re
import shutil
import sys

run, bundle = sys.argv[1], sys.argv[2]
kept = {int(m[1]) for name in os.listdir(os.path.join(bundle, "tapes"))
        if (m := re.fullmatch(r"branch-(\d+)\.jsonl", name))}
if not kept:
    sys.exit(f"bundle-view.py: {bundle} carries no tapes")


def timeline_of(line):
    """The timeline a record or timelines.jsonl line is about, or None (a run-wide line)."""
    try:
        value = json.loads(line)
    except ValueError:
        return None
    if "branch" in value and isinstance(value["branch"], dict):
        return value["branch"].get("index")
    if "index" in value and "seed" in value:
        return value["index"]
    return None


with open(os.path.join(bundle, "request.json")) as request:
    program = json.load(request).get("program")


def filtered(source, target):
    with open(source) as lines, open(target, "w") as out:
        for line in lines:
            index = timeline_of(line)
            if index is not None and index not in kept:
                continue
            value = json.loads(line) if line.startswith('{"run":') else None
            if value and program and value["run"].get("program"):
                # The run's program as the bundle carries it (request.json: artifacts/, from the
                # bundle, where serve runs), not the recording host's path: the UI's "Fork here"
                # asks serve for a run of it.
                value["run"]["program"] = program
                line = json.dumps(value, separators=(",", ":")) + "\n"
            out.write(line)


os.makedirs(os.path.join(bundle, "events"), exist_ok=True)
# How the run ended (serve's state: failed, passed). A stopped or drained run has no exit: the
# bundled timelines' own verdict then, as explore exits (3 when a property fails).
filtered(os.path.join(run, "record.jsonl"), os.path.join(bundle, "record.jsonl"))
filtered(os.path.join(run, "events", "timelines.jsonl"), os.path.join(bundle, "events", "timelines.jsonl"))
failing = False
with open(os.path.join(run, "events", "timelines.jsonl")) as lines:
    for line in lines:
        value = json.loads(line)
        failing |= value.get("index") in kept and bool(value.get("failing"))
if os.path.exists(os.path.join(run, "exit")):
    shutil.copyfile(os.path.join(run, "exit"), os.path.join(bundle, "exit"))
else:
    with open(os.path.join(bundle, "exit"), "w") as out:
        out.write("3 exited with status 3\n" if failing else "0 exited with status 0\n")
copied = 0
# The system the run pinned (its nodes' images by digest, their commands): the runs serve starts
# from the bundle boot it (serve-bundle.sh), not one built again from a repository it lacks.
# An ended timeline's events are compressed (src/event_files.zig: branch-<n>.jsonl.zst).
for name in ["setup.jsonl", "system.pin.json"] + [f"branch-{index}.jsonl.zst" for index in sorted(kept)]:
    source = os.path.join(run, "events", name)
    if os.path.exists(source):
        shutil.copyfile(source, os.path.join(bundle, "events", name))
        copied += os.path.getsize(source)
print(f"bundle-view.py: timelines {sorted(kept)} of {run} for serve ({copied // 1024} KiB of events)")
