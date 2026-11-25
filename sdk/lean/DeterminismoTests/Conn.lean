import Determinismo

/-! Connections: two nodes pinging each other through kills; faults and clients kept to nodes. -/

namespace DeterminismoTests.Conn

open Determinismo

abbrev sys : Sys := { State := Nat, Msg := Unit, Rec := Unit, Op := Unit, Res := Unit }

/-- Each tick pings the other node; a ping meant for an earlier process of its node breaks
"stale"; a reset counts in the state. -/
def behavior : Behavior sys where
  start := pure 0
  receive st e := do
    let me ← Node.self (s := sys)
    let starts := ((← get).node me).starts
    Node.check (s := sys) (e.dstStarts == starts) "stale" s!"a ping sent to start {e.dstStarts} delivered in start {starts}"
    pure st
  tick st := do
    Node.send (s := sys) (1 - (← Node.self (s := sys))) ()
    pure st
  request st id _ := do Node.reply (s := sys) id (); pure st
  operation := pure ()
  connectionLost st _ := pure (st + 1)

def config (connections : Bool) (targets : Option (List NodeId) := none)
    (clientNodes : Option (List NodeId) := none) : Config :=
  { nodes := 2, steps := 60, recovery := 20, clientOps := 4, connections, clientNodes,
    faults := { crash := false, partition := false, drop := false, duplicate := false,
                crashPoints := false, evict := false, swarm := false, targets } }

def runFull (cfg : Config) (source : Source) : Run sys := runCluster behavior {} cfg source

def run (cfg : Config) (source : Source) : Ended :=
  let r := runFull cfg source
  { taken := r.taken, violation := r.violation }

/-- Over `count` seeds, whether some timeline's story has a line containing `text`. -/
def someLog (cfg : Config) (count : Nat) (text : String) : Bool :=
  (List.range count).any fun i => (runFull cfg (Source.seeded i)).cluster.log.any (fun l => (l.splitOn text).length > 1)

end DeterminismoTests.Conn
