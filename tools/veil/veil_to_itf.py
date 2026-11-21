#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""veil_to_itf.py <veil result> <out.itf.json>: a Veil model checker's counterexample as an ITF
trace (docs/VEIL.md, "Walking a Veil counterexample"), for sdk.trace (Zig), determinismo.trace
(jank, through tools/itf_to_edn.py) and the other tools that read Quint's. The input: the compiled
checker's result on stdout ({"result": "found_violation", "trace": {"theory", "states": [{"index",
"fields", "transition", "choices"}]}}), or the trace `#model_check` prints ("State k (via
Action(a=1)):" and "field = value" lines, as `lake env lean` writes them). Each state's variables
become ITF variables: Veil's maps ITF maps, sets sets, structures records, integers bigints,
`some x`/`none` Quint's Option variants; the transition taken and its arguments Quint's
`mbt::actionTaken` and `mbt::nondetPicks`.
"""
import json, re, sys

class Text:
    """Veil's printed values: maps {k ↦ v, ...}, sets {a, b}, structures { f := v, ... },
    Options (some x, none), numbers and names; as the JSON result's displayed values are."""
    def __init__(self, text): self.t, self.i = text, 0
    def ws(self):
        while self.i < len(self.t) and self.t[self.i] == " ": self.i += 1
    def peek(self, word): self.ws(); return self.t.startswith(word, self.i)
    def take(self, word):
        assert self.peek(word), (word, self.t[self.i:self.i + 30]); self.i += len(word)
    def value(self):
        self.ws()
        if self.peek("{"):
            self.take("{")
            if self.peek("}"): self.take("}"); return {"$veil": "set", "elements": []}
            save = self.i
            if re.match(r"\s*\w+ :=", self.t[self.i:]):
                fields = []
                while True:
                    name = re.match(r"\s*(\w+) :=", self.t[self.i:]); self.i += name.end()
                    fields.append({"name": name.group(1), "value": self.value()})
                    if self.peek(","): self.take(","); continue
                    self.take("}"); return {"type": "Struct", "fields": fields}
            first = self.value()
            if self.peek("↦"):
                entries = []
                key = first
                while True:
                    self.take("↦"); entries.append({"key": key, "value": self.value()})
                    if self.peek(","): self.take(","); key = self.value(); continue
                    self.take("}"); return {"$veil": "map", "entries": entries}
            elements = [first]
            while self.peek(","): self.take(","); elements.append(self.value())
            self.take("}"); return {"$veil": "set", "elements": elements}
        if self.peek("some "):
            self.take("some "); inner = self.value()
            return "some " + str(inner)
        word = re.match(r"-?\w+", self.t[self.i:]); self.i += word.end(); w = word.group(0)
        return int(w) if re.fullmatch(r"-?\d+", w) else w

def from_text(text):
    """The printed trace as the JSON result has it."""
    states = []
    for line in text.splitlines():
        head = re.match(r"\s*State (\d+) \(via (.+)\):\s*$", line)
        if head:
            label = head.group(2)
            call = re.match(r"(\w+)\((.*)\)$", label)
            transition = {"name": "after_init", "args": []} if label == "init" else {
                "name": call.group(1) if call else label,
                "args": [{"name": a.split("=")[0].strip(), "value": Text(a.split("=", 1)[1]).value()}
                         for a in (call.group(2).split(", ") if call and call.group(2) else [])]}
            states.append({"index": int(head.group(1)), "fields": {"type": "State", "fields": []}, "transition": transition})
            continue
        field = re.match(r"\s{4}(\w+) = (.+)$", line)
        if field and states and not line.strip().startswith("choices"):
            states[-1]["fields"]["fields"].append({"name": field.group(1), "value": Text(field.group(2)).value()})
    violation = re.search(r"Violation: (\w+) \(violates: ([\w, ]+)\)", text)
    return {"result": "found_violation" if states else "none",
            "violation": {"kind": violation.group(1), "violates": violation.group(2).split(", ")} if violation else None,
            "trace": {"states": states}}

def value(v):
    """A Veil displayed value as an ITF value."""
    if isinstance(v, bool): return v
    if isinstance(v, int): return {"#bigint": str(v)}
    if isinstance(v, str):
        if v == "none": return {"tag": "None", "value": {"#tup": []}}
        if v.startswith("some "):
            inner = v[5:]
            return {"tag": "Some", "value": {"#bigint": inner} if inner.lstrip("-").isdigit() else inner}
        return v
    if isinstance(v, list): return [value(x) for x in v]
    if isinstance(v, dict):
        kind = v.get("$veil")
        if kind == "map": return {"#map": [[value(e["key"]), value(e["value"])] for e in v["entries"]]}
        if kind == "set": return {"#set": [value(x) for x in v["elements"]]}
        if kind == "ctor": return {"tag": v.get("name", ""), "value": {a["name"]: value(a["value"]) for a in v.get("args", [])}}
        if "fields" in v and isinstance(v["fields"], list):
            return {f["name"]: value(f["value"]) for f in v["fields"]}
        return {k: value(x) for k, x in v.items() if not k.startswith("$")}
    return v

def result_of(text):
    """The checker's result: the whole text as JSON, or its last JSON line with a "result" (the
    compiled checker's stdout after its progress lines), or the printed trace."""
    try: return json.loads(text)
    except ValueError: pass
    for line in reversed(text.splitlines()):
        if line.startswith("{") and '"result"' in line:
            try: return json.loads(line)
            except ValueError: continue
    return from_text(text)

def main():
    source, out = sys.argv[1], sys.argv[2]
    text = open(source).read()
    result = result_of(text)
    if result.get("result") != "found_violation" or not result.get("trace"):
        sys.exit(f"{source}: no counterexample ({result.get('result')})")
    states = []
    for index, state in enumerate(result["trace"]["states"]):
        variables = value(state["fields"])
        record = {"#meta": {"index": index}}
        record.update(variables)
        label = state.get("transition")
        name = label if isinstance(label, str) else (label or {}).get("name", "")
        args = {} if isinstance(label, str) else {a["name"]: value(a["value"]) for a in (label or {}).get("args", [])}
        record["mbt::actionTaken"] = "init" if name == "after_init" else name
        record["mbt::nondetPicks"] = {k: {"tag": "Some", "value": v} for k, v in args.items()}
        states.append(record)
    names = [k for k in states[0] if k != "#meta"]
    itf = {"#meta": {"format": "ITF", "source": source, "description": "a Veil counterexample, by tools/veil/veil_to_itf.py",
                     "violation": result.get("violation")},
           "vars": names, "states": states}
    json.dump(itf, open(out, "w"), indent=1)
    print(f"{len(states)} states, violating {result.get('violation', {}).get('violates')}: {out}")

main()
