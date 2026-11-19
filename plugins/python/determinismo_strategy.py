# SPDX-License-Identifier: MIT
"""The plugin side of docs/PLUGINS.md for strategies written in Python (standard library only).

A strategy is an object with any of these methods; missing ones answer the default:

    hello(exploration_seed)                   once, at start (seeds are ints)
    returns(generation, candidates, count)    the tree's next moments: [(branch, vtime_ns,
                                              reason), ...], up to count (the explorer fills
                                              the rest); with `wants = ["behaviors"]` each
                                              candidate has its behaviors (docs/PLUGINS.md)
    branch(index, seed)                       before each branch
    random(pull, default, source, moment[, decision])
                                              a decision: return bytes to override, or None;
                                              `decision` is its label when the guest named it
                                              ({"name", "options"} or {"name", "range"})
    event(event, source, moment)              a guest event (a dict); True ends the timeline here
    machine(request)                          with wants "machine": the run's machine before it boots
                                              ({"epoch_seconds", "timer_slack_us", "tsc_jitter_seed",
                                              "modulation_stretch_us"}), the fields to change
    plan()                                    with wants "plans": {"<decision name>": [[low, high,
                                              weight], ...]}, drawn from by the explorer
    branch_end(index, outcome, events, failing)   return True to stop the exploration

`default` is the bytes the branch would get; `source` is the asking process's name; `moment`
is (vtime_ns, branches). Run it with `serve(strategy)`; anything printed to stderr reaches the
user, stdout is the protocol.
"""
import inspect
import json
import sys


def serve(strategy, name):
    out = sys.stdout
    for line in sys.stdin:
        request = json.loads(line)
        reply = _dispatch(strategy, name, request)
        out.write(json.dumps(reply, separators=(",", ":")) + "\n")
        out.flush()


def _dispatch(strategy, name, request):
    method = request["method"]
    moment = (request.get("vtime_ns", 0), request.get("branches", 0))
    if method == "hello":
        if hasattr(strategy, "hello"):
            strategy.hello(int(request["exploration_seed"], 16))
        reply = {"name": name}
        # A strategy that only chooses where the tree returns: `decides = False` (no request per
        # decision or event); `wants = ["behaviors"]` gives `returns` each candidate's behaviors.
        if hasattr(strategy, "decides"):
            reply["decides"] = bool(strategy.decides)
        if hasattr(strategy, "wants"):
            reply["wants"] = list(strategy.wants)
        return reply
    if method == "branch":
        if hasattr(strategy, "branch"):
            arguments = [request["index"], int(request["seed"], 16)]
            # Where it starts, when the tree explorer branched it from another: {"branch", "vtime_ns"}.
            if "start" in inspect.signature(strategy.branch).parameters:
                arguments.append(request.get("from"))
            strategy.branch(*arguments)
        return {}
    if method == "returns":
        # The tree explorer's generation ended: which moments to return to (branch, vtime_ns,
        # reason), at most "count"; None leaves it to the explorer.
        if not hasattr(strategy, "returns"):
            return {}
        arguments = [request["generation"], request["candidates"], request["count"]]
        # The explorer's archive cells offered beside them, for a strategy that takes them.
        if "archive" in inspect.signature(strategy.returns).parameters:
            arguments.append(request.get("archive", []))
        chosen = strategy.returns(*arguments)
        # (branch, vtime_ns, reason[, branches]) each, or {"returns": [...], "fill": "fresh"}:
        # the generation's shape is the strategy's (request["budget"] timelines in all).
        fill = None
        if isinstance(chosen, dict):
            fill, chosen = chosen.get("fill"), chosen.get("returns") or []
        reply = {"fill": fill} if fill else {}
        if chosen:
            reply["returns"] = [dict({"branch": c[0], "vtime_ns": c[1], "reason": c[2]},
                                     **({"branches": c[3]} if len(c) > 3 else {})) for c in chosen]
        return reply
    if method == "random":
        if not hasattr(strategy, "random"):
            return {}
        default = bytes.fromhex(request["default"])
        arguments = [request["pull"], default, request.get("source", ""), moment]
        if "decision" in inspect.signature(strategy.random).parameters:
            arguments.append(request.get("decision"))
        answer = strategy.random(*arguments)
        if answer is None:
            return {}
        # An answer may come with why, (bytes, "reason"): shown with the decision, kept in tapes.
        reason = None
        if isinstance(answer, tuple):
            answer, reason = answer
        assert len(answer) == len(default), "an override has the default's size"
        return {"hex": answer.hex(), "reason": reason} if reason else {"hex": answer.hex()}
    if method == "event":
        # True ends the timeline here (its end checks not run, not extended).
        if hasattr(strategy, "event"):
            if strategy.event(request["event"], request.get("source", ""), moment) is True:
                return {"end": True}
        return {}
    if method == "events":
        # A batch of them (`wants = ["batched", ...]`: one round trip for many), each in turn.
        ended = False
        if hasattr(strategy, "event"):
            for item in request["events"]:
                at = (item.get("vtime_ns", 0), item.get("branches", 0))
                ended = strategy.event(item["event"], item.get("source", ""), at) is True or ended
        reply = {"end": True} if ended else {}
        # With `wants = ["plans", ...]`: the weights the explorer draws named decisions from,
        # {"<name>": [[low, high, weight], ...]}, no round trip per decision.
        plan = strategy.plan() if hasattr(strategy, "plan") else None
        if plan:
            reply["plan"] = plan
        return reply
    if method == "machine":
        # With `wants = ["machine", ...]`: the machine the run boots, asked before it does
        # (the run's own as the request); the fields the reply gives replace them.
        return strategy.machine(request) if hasattr(strategy, "machine") else {}
    if method == "branch_end":
        stop = False
        if hasattr(strategy, "branch_end"):
            stop = bool(strategy.branch_end(request["index"], request["outcome"],
                                            request["events"], request["failing"]))
        return {"stop": True} if stop else {}
    raise ValueError(f"unknown method {method}")
