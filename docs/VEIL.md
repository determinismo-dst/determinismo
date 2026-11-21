# Veil

[Veil](https://github.com/verse-lab/veil) (Apache-2.0; Lean 4) models a protocol as a transition
system: explicit-state model checking of a finite instance (every reachable state), symbolic
checking and proofs of inductive invariants for any size, invariant synthesis (`#updr`). Beside
Quint (docs/QUINT.md) and TLA+ (`determinismo tla`), a model source users choose.

## A timeline checked against a Veil model

    determinismo veil --module <M.lean> --map <map.json> --instance '{ node := Fin 3 }' \
      --events <run>/events --branch <n> --veil <checkout> [--theory '{}'] [--lake <command>]

The timeline's output lines become the module's action labels through the map, a label each line
that matches one of its actions, its argument the node the line came from (its source's trailing
number: `raft-node-2` is node 2). Veil's `#replay` then takes the labels in order from the
instance's initial states, keeping at each step the successors whose label matches:

- refused: the first label no successor takes (the run is not a behavior of the model);
- a property broken: the first state that breaks a `safety` or `invariant`;
- accepted: every label taken, every property holding.

Exit 0 when accepted, 3 otherwise, 1 when it could not run. The map:

    {"node_arg": "n", "actions": [
      {"name": "EnterLeader", "match": "entering leader state"},
      {"name": "TransferTimeout", "match": "leadership transfer timeout",
       "unless": "sent response to client"}]}

the first action whose `match` a line holds (and not its `unless`) taking it.

The model is shaped like the logs, an action a kind of line, its arguments nodes only: a checker
enumerates every action's arguments, so a term is not one (count what the lines show instead, as
a node's leaderships). A protocol-shaped model, written to be model checked and proved, is a
separate module.

## Setup

`#replay` is a patch to Veil (tools/veil/replay.patch, against Veil 252208c):

    git clone https://github.com/verse-lab/veil && cd veil && git checkout 252208c
    git apply <determinismo>/tools/veil/replay.patch
    lake build        # Lean through elan; about 1,300 jobs

A large model's checks take memory (a five-node log model passed 16 GB): run them where there is
room, with a bound.
