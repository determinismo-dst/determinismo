import Determinismo

/-!
# A system whose every start writes

Each start appends a record to its `boot` file and syncs it, and nothing else touches the disk:
every crash point is inside a start. The tests check where crash points may fire under
`nodesDownMax`: inside a node's first boot while the others are not yet booted, inside a restart,
and never past the bound.
-/

namespace DeterminismoTests.Boot

open Determinismo

abbrev sys : Sys := { State := Unit, Msg := Unit, Rec := Nat, Op := Unit, Res := Unit }

def behavior : Behavior sys where
  start := do
    Node.append (s := sys) "boot" [1]
    let _ ← Node.sync (s := sys) "boot"
    pure ()
  receive st _ := pure st
  tick st := pure st
  request st _ _ := pure st
  operation := pure ()

/-- Three nodes, kills only (no power-loss event), a crash point at every other disk operation. -/
def config : Config :=
  { nodes := 3, steps := 12, recovery := 4, clientOps := 0, nodesDownMax := 1,
    faults := { crash := false, partition := false, drop := false, duplicate := false,
                skew := false, evict := false, swarm := false, crashPointOneIn := 2 } }

/-- Nodes that started at least once and are down now. -/
def downNow (c : Cluster sys) : Nat :=
  ((List.range c.nodes.size).filter fun n => (c.node n).starts > 0 && !c.up n).length

/-- With `bound`, breaks when more than `nodesDownMax` started nodes are down; with `seek`, when
the story has a line containing it (a marker the search looks for). -/
def properties (bound : Bool) (seek : Option String) : Properties sys where
  invariant c :=
    if bound && downNow c > c.config.nodesDownMax then some s!"{downNow c} nodes down at once"
    else match seek with
      | some text => if c.log.any (fun l => (l.splitOn text).length > 1) then some s!"seen: {text}" else none
      | none => none

def run (bound : Bool) (seek : Option String) (config : Config) (source : Source) : Ended :=
  let r := runCluster behavior (properties bound seek) config source
  { taken := r.taken, violation := r.violation }

end DeterminismoTests.Boot
