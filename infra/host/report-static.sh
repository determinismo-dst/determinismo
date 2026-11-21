#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# report-static.sh <serve-url> <run> <out.html>: a run's report as one HTML file, read only, no
# serve behind it (to publish: GitHub Pages, a bucket). Headless Chrome opens serve's page at the
# run with `?record` (src/ui/index.html: the report, then each property's page, every answer it
# reads kept), its DOM gives the recording, and the file is serve's page with the recording
# embedded (#determinismo-report): it answers from it alone, and starts or changes nothing.
# Needs Chrome or Chromium (GitHub's hosted runners have Chrome) and python3.
set -euo pipefail
serve=${1:?usage: report-static.sh <serve-url> <run> <out.html>}
run=${2:?usage: report-static.sh <serve-url> <run> <out.html>}
out=${3:?usage: report-static.sh <serve-url> <run> <out.html>}
chrome=${CHROME:-}
for candidate in google-chrome google-chrome-stable chromium chromium-browser \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
  [ -n "$chrome" ] && break
  if command -v "$candidate" > /dev/null 2>&1 || [ -x "$candidate" ]; then chrome=$candidate; fi
done
[ -n "$chrome" ] || { echo "error: no Chrome or Chromium (CHROME=<path>)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsS -m 60 "$serve/" > "$work/page.html"
# Virtual time: the page's waits for quiet pass at once while nothing is asked, its requests
# taking their real time.
"$chrome" --headless=new --disable-gpu --no-sandbox --user-data-dir="$work/profile" \
  --virtual-time-budget=1800000 --dump-dom "$serve/?record#$run" > "$work/dom.html" 2> "$work/chrome.log"
python3 - "$work/page.html" "$work/dom.html" "$out" "$run" <<'EOF'
import json, re, sys
page_path, dom_path, out, run = sys.argv[1:5]
dom = open(dom_path, encoding="utf-8").read()
found = re.search(r'<script type="application/json" id="determinismo-report-recorded">(.*?)</script>', dom, re.S)
if not found:
    sys.exit(f"error: run {run}'s page recorded nothing (is it serve's run, and has the page a ?record mode?)")
recording = json.loads(found.group(1))
if str(recording.get("run")) != str(run):
    sys.exit(f"error: the recording is run {recording.get('run')}'s, not {run}'s")
# The host's other runs are not this report's: the runs list holds this one alone.
if "/runs" in recording["answers"]:
    runs = json.loads(recording["answers"]["/runs"])
    recording["answers"]["/runs"] = json.dumps([r for r in runs if str(r.get("id")) == str(run)])
page = open(page_path, encoding="utf-8").read()
# Before the page's own script, which reads it as it starts.
embedded = ('<script type="application/json" id="determinismo-report">'
            + json.dumps(recording, separators=(",", ":")).replace("<", "\\u003c") + "</script>\n")
at = page.index("<body>") + len("<body>")
page = page[:at] + "\n" + embedded + page[at:]
page = page.replace("<title>determinismo</title>", f"<title>determinismo: run {run}</title>", 1)
open(out, "w", encoding="utf-8").write(page)
print(f"{out}: run {run}, {len(recording['answers'])} answers, {len(page) // 1024} KB")
EOF
