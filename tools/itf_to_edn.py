#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""itf_to_edn.py <trace.itf.json> <out.edn>: an ITF trace's states as EDN, for jank's
determinismo.trace (Clojure and jank read EDN with read-string; the Zig SDK reads the ITF itself):
a vector of states, each a map of its variables. ITF's bigints ({"#bigint": "7"}) are numbers, its
maps ({"#map": [[k, v], ...]}) maps, sets sets, tuples vectors, variants ({"tag", "value"})
{:tag "Leader" :value ...} (a unit value left out); a record's fields and a state's variables
whose names are identifiers are keywords, others strings ("mbt::actionTaken"); "#meta" dropped."""
import json, re, sys

def key(k):
    return ":" + k if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_\-?!]*", k) else edn(k)

def edn(v):
    if v is None: return "nil"
    if v is True: return "true"
    if v is False: return "false"
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, str): return json.dumps(v)
    if isinstance(v, list): return "[" + " ".join(edn(x) for x in v) + "]"
    if isinstance(v, dict):
        if "#bigint" in v: return str(int(v["#bigint"]))
        if "#map" in v: return "{" + " ".join(f"{edn(k)} {edn(x)}" for k, x in v["#map"]) + "}"
        if "#set" in v: return "#{" + " ".join(edn(x) for x in v["#set"]) + "}"
        if "#tup" in v: return "[" + " ".join(edn(x) for x in v["#tup"]) + "]"
        if "tag" in v and set(v) <= {"tag", "value"}:
            value = v.get("value")
            unit = value is None or value == {"#tup": []}
            return "{:tag " + json.dumps(v["tag"]) + ("" if unit else " :value " + edn(value)) + "}"
        return "{" + " ".join(f"{key(k)} {edn(x)}" for k, x in v.items() if k != "#meta") + "}"
    raise ValueError(f"not an ITF value: {v!r}")

def main():
    source, out = sys.argv[1], sys.argv[2]
    states = json.load(open(source))["states"]
    with open(out, "w") as f:
        f.write("[\n")
        for state in states: f.write(" " + edn(state) + "\n")
        f.write("]\n")
    print(f"{len(states)} states: {out}")

main()
