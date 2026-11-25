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

/-- Timers and delayed sends: each start sets timer "t" 3 ticks ahead, noting the time and its
start in ghost state; node 0's start sends node 1 a message deliverable 5 ticks later. A timer
firing early or for an earlier process, or a message arriving early, breaks a property. -/
def timed : Behavior sys where
  start := do
    let me ← Node.self (s := sys)
    let c ← get
    Node.setGhost (s := sys) s!"set.{me}" c.time
    Node.setGhost (s := sys) s!"start.{me}" (c.node me).starts
    Node.setTimer (s := sys) "t" 3
    if me == 0 then
      Node.setGhost (s := sys) "sent" c.time
      Node.sendAfter (s := sys) 1 5 ()
    pure 0
  receive st _ := do
    let now ← Node.now (s := sys)
    let sent ← Node.ghost (s := sys) "sent"
    Node.check (s := sys) (Int.ofNat now ≥ sent + 5) "early" s!"sent at {sent}, delivered at {now}"
    Node.setGhost (s := sys) "received" ((← Node.ghost (s := sys) "received") + 1)
    pure st
  tick st := pure st
  request st id _ := do Node.reply (s := sys) id (); pure st
  operation := pure ()
  timer st _ := do
    let me ← Node.self (s := sys)
    let c ← get
    let set ← Node.ghost (s := sys) s!"set.{me}"
    let start ← Node.ghost (s := sys) s!"start.{me}"
    Node.check (s := sys) (Int.ofNat c.time ≥ set + 3) "timer early" s!"set at {set}, fired at {c.time}"
    Node.check (s := sys) (start == Int.ofNat (c.node me).starts) "timer outlived its process" s!"set in start {start}"
    Node.setGhost (s := sys) "fired" ((← Node.ghost (s := sys) "fired") + 1)
    pure st

def runTimed (cfg : Config) (source : Source) : Run sys := runCluster timed {} cfg source

end DeterminismoTests.Conn
