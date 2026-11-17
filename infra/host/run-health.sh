#!/bin/bash
# SPDX-License-Identifier: MIT
# run-health.sh <run>...: on a host running serve, what instrumentation did in finished runs, and
# whether each is healthy:
# coverage events and lines, thread pausing's draws, replays, failing properties; the setup's
# virtual time, how timelines ended, the failing share against the previous run of the same
# system, the sometimes never true. "UNHEALTHY: ..." (and exit 1) when the setup took over 120 s
# of virtual time and half again the previous run's of the system (Cassandra's three JVMs take
# about 160 s every time), a setup command failed, over 10% of timelines hung, the failing share went past
# 50% from under 20%, a sometimes the previous run made true in half its timelines is not, the
# kernel OOM-killed the test program or determinismo's own processes, its events passed 5 GB per
# virtual hour, a stop overshot its target (the stepping margin under the CPU's skid), or serve did
# not answer about it.
worst=0
for id in "$@"; do
python3 - "$id" <<'PY'
import json, os, sys, urllib.request
run_id = sys.argv[1]
data = os.environ.get("DETERMINISMO_DATA") or os.path.expanduser("~/.determinismo")
base = "http://localhost:7878/runs"
# The run's events on disk per hour of the virtual time its timelines ran, from the files, before
# serve is asked: Flecs's run 969 wrote 87 GB in 15 minutes (12.6 GB a virtual hour, every
# evaluation of a per-frame model check an event), its ingest kept serve busy for many minutes,
# and these queries timed out with nothing said. Other runs: 0.01 to 0.04 GB.
events_dir = os.path.join(data, "runs", run_id, "events")
events_bytes = 0
explored_ns = 0
try:
    for name in os.listdir(events_dir):
        if name.endswith(".jsonl"):
            events_bytes += os.path.getsize(os.path.join(events_dir, name))
    with open(os.path.join(events_dir, "timelines.jsonl")) as timelines_file:
        for line in timelines_file:
            try:
                explored_ns += json.loads(line).get("vtime_ns") or 0
            except ValueError:
                pass  # A line being written.
except OSError:
    pass  # No events yet.
events_gb = events_bytes / 1e9
events_gb_per_vhour = events_gb / (explored_ns / 3.6e12) if explored_ns else 0.0
events_gb_per_vhour_max = 5
def unanswered(error):
    print(json.dumps({"run": int(run_id), "events_gb": round(events_gb, 2),
                      "events_gb_per_virtual_hour": round(events_gb_per_vhour, 2)}))
    print(f"UNHEALTHY: serve did not answer about it ({error}); its events: {events_gb:.1f} GB, "
          f"{events_gb_per_vhour:.2f} GB per virtual hour")
    sys.exit(1)
def fetch(url, timeout, body=None):
    request = urllib.request.Request(url, data=body)
    try:
        return json.load(urllib.request.urlopen(request, timeout=timeout))
    except (OSError, ValueError) as error:  # URLError, a timeout, a reply cut short.
        unanswered(error)
def sql(run, q):
    return fetch(f"{base}/{run}/sql", 600, json.dumps({"sql": q}).encode())
run = fetch(f"{base}/{run_id}", 60)
stats = run.get("stats") or {}
coverage = sql(run_id, "SELECT count(*) AS events, count(DISTINCT event ->> '$.details.name') AS lines FROM events "
               "WHERE event ->> '$.event' = 'coverage'")[0]
pausing = sql(run_id, "SELECT count(*) AS n FROM events WHERE kind = 'decision' AND name = 'thread pausing'")[0]["n"]
replays = sql(run_id, "SELECT count(*) AS n, count(*) FILTER (WHERE same) AS same FROM replays")[0]
# Violations only: an always false, an unreachable reached. A sometimes false is no failure (it
# listed "a leased key expired" as failing in every kine run, and an Elle check of 6 ops).
failing = sql(run_id, "SELECT path_assert_message AS m, count(DISTINCT branch) AS t FROM events "
              "WHERE kind = 'assert' AND ((type IN ('always', 'always_or_unreachable') AND path_assert_condition = false) "
              "OR (type = 'unreachable' AND path_assert_condition = true)) GROUP BY 1 ORDER BY 2 DESC LIMIT 6")
def setup_of(run):  # The setup's virtual time: where its timelines begin.
    return sql(run, "SELECT min(vtime_ns) / 1e9 AS s FROM events WHERE branch IS NOT NULL")[0]["s"] or 0
setup = setup_of(run_id)
setup_failed = sql(run_id, "SELECT count(*) AS n FROM events WHERE branch IS NULL AND name = 'command_exit' "
                   "AND (event ->> '$.details.status')::INTEGER <> 0")[0]["n"]
outcomes = {r["outcome"]: r["n"] for r in sql(run_id, "SELECT outcome, count(*) AS n FROM timelines GROUP BY 1")}
# The kernel's OOM killer taking the test program or determinismo's own processes: ours, not the
# system's (CometBFT's run 865: its committed check at 2.7 GB in 3 timelines, called healthy).
oom_ours = sql(run_id, "SELECT count(DISTINCT branch) AS n FROM events WHERE kind = 'assert' "
               "AND path_assert_message = 'the kernel kills no process for lack of memory' "
               "AND path_assert_condition = false AND (event ->> '$.assert.details.line' LIKE '%(program)%' "
               "OR event ->> '$.assert.details.line' LIKE '%(det-%')")[0]["n"]
total = sum(outcomes.values()) or 1
share = (stats.get("failing_timelines") or 0) / total
previous = None
listing = fetch(base, 60)
def system_of(entry):  # "<inputs hash>-<program>": the program, whatever its build
    return (entry.get("system") or "").split("-", 1)[-1]
system = next((system_of(entry) for entry in listing if entry["id"] == int(run_id)), "")
def asked(run):  # the scenario and profile, as serve's run identity has them
    try:
        r = json.load(open(os.path.join(data, "runs", str(run), "request.json")))
        return (r.get("scenario"), r.get("profile"), r.get("coverage"))
    except Exception:
        return None
mine = asked(run_id)
for other in reversed(listing):
    if other["id"] < int(run_id) and system and system_of(other) == system and asked(other["id"]) == mine:
        o = fetch(f"{base}/{other['id']}", 60).get("stats") or {}
        # A baseline of at least 10 timelines: a one-timeline trial's failing share (0 or 1) is no
        # baseline (run 1799's 0.52 was called unhealthy against trial 1796's single passing one).
        if (o.get("timelines") or 0) >= 10:
            previous = {"run": other["id"], "failing_share": round((o.get("failing_timelines") or 0) / o["timelines"], 2),
                        "setup_s": round(setup_of(other["id"]), 1)}
            break
# Sometimes and reachable assertions: never true here; and those the previous run of the system
# made true in at least half its timelines (a smoke too short to reach a rare one says nothing).
def properties(run):
    return fetch(f"{base}/{run}/properties", 300)
sometimes = [p for p in properties(run_id) if p.get("type") in ("sometimes", "reachable")]
unreached = sorted(p["message"] for p in sometimes if not p.get("timelines_true"))
lost = []
if previous:
    before = {p["message"]: p for p in properties(previous["run"]) if p.get("type") in ("sometimes", "reachable")}
    prior_total = (fetch(f"{base}/{previous['run']}", 60).get("stats") or {}).get("timelines") or 1
    for message in unreached:
        old = before.get(message)
        if old and (old.get("timelines_true") or 0) >= prior_total / 2 and total >= 30:
            lost.append(message)
problems = []
# A run that never explored is the worst kind (Scylla's smoke, run 394, ended in error at its
# image build, 0 timelines, and was called healthy).
if run.get("state") == "error": problems.append("it ended in error (its output.log says why)")
elif run.get("state") not in (None, "running") and sum(outcomes.values()) == 0:  # total is at least 1.
    problems.append("it ended without a timeline")
if lost: problems.append(f"sometimes no longer reached (the previous run in half its timelines): {lost}")
# The setup's baseline: the previous run of the same scenario and profile, else of the system in
# any (a program's setup is the same: Cassandra's first power-loss run, 163 s, was flagged
# against none though its default runs take 160 s).
setup_previous = previous["setup_s"] if previous else 0
if not previous:
    for other in reversed(listing):
        if other["id"] < int(run_id) and system and system_of(other) == system:
            setup_previous = setup_of(other["id"])
            if setup_previous:
                break
setup_max = max(120, 1.5 * setup_previous)
if setup > setup_max: problems.append(f"setup took {setup:.0f} s of virtual time (at most {setup_max:.0f})")
if oom_ours: problems.append(f"the test program or determinismo's own was OOM-killed in {oom_ours} timelines")
# A counter interrupt handled more branches late than the stepping margin: that stop came late,
# and its timeline may not replay (serve.sh's margin from the host's measured skid).
overshoots = largest_skid = 0
try:
    for line in open(os.path.join(data, "runs", run_id, "record.jsonl")):
        record = json.loads(line)
        overshoots += record.get("overshoots") or 0
        largest_skid = max(largest_skid, record.get("skid_max") or 0)
except (OSError, ValueError):
    pass
if overshoots: problems.append(f"{overshoots} stops overshot their target (largest skid {largest_skid} branches): raise the stepping margin")
if setup_failed: problems.append(f"{setup_failed} setup command(s) failed")
if outcomes.get("hung", 0) > 0.1 * total: problems.append(f"{outcomes.get('hung')} of {total} timelines hung")
if previous and share > 0.5 and previous["failing_share"] < 0.2:
    problems.append(f"failing share {share:.2f} against {previous['failing_share']} in run {previous['run']}")
# A command run in nodes taking a fifth of the guest or more: a runtime started per call
# (Cassandra's nodetool, a JVM each, about 100 a timeline: most of run 964's CPU), which the
# node's own CPU hid. Slowness, not a failure: said, not counted against the run.
exec_cpu = stats.get("cpu_by_exec") or {}
if isinstance(exec_cpu, str):
    exec_cpu = json.loads(exec_cpu)
costly = {name: cost for name, cost in exec_cpu.items() if (cost.get("share") or 0) >= 0.2}
if events_gb_per_vhour > events_gb_per_vhour_max:
    problems.append(f"its events: {events_gb:.1f} GB, {events_gb_per_vhour:.1f} GB per virtual hour (at most "
                    f"{events_gb_per_vhour_max}; hot assertions: first pass and first failure)")
print(json.dumps({"run": run["id"], "state": run.get("state"), "timelines": total, "outcomes": outcomes,
    "setup_s": round(setup, 1), "failing_share": round(share, 2), "previous": previous,
    "coverage_lines": coverage["lines"], "pausing_draws": pausing,
    "replays": f"{replays['same']}/{replays['n']}", "failing": {f["m"]: f["t"] for f in failing},
    "unreached_sometimes": unreached, "costly_execs": costly,
    "events_gb": round(events_gb, 2), "events_gb_per_virtual_hour": round(events_gb_per_vhour, 2)}))
print("UNHEALTHY: " + "; ".join(problems) if problems else "healthy")
sys.exit(1 if problems else 0)
PY
[ $? -eq 0 ] || worst=1
done
exit $worst
