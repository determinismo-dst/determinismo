import Determinismo.Decide
import Determinismo.Disk

/-!
# A cluster in the chaotic world

A system is its nodes' code, the way it is written: a node starts from what its disk holds,
receives a message, ticks, takes a client's request, and while doing so sends, writes files,
syncs them, reads its clock, replies, and asserts. The world decides everything else, each choice a
named decision:

- which event happens next (`world.event`): a message delivered, dropped or duplicated, a node's
  tick, a client's request, a fault;
- which message is delivered (`net.deliver`): any one in flight, so messages are reordered
  (`fifo`: only the oldest of each pair);
- the faults, as determinismo's (`Faults`): power losses (`fault.crash`, the disk keeping what
  `Disk` says), process kills (`fault.kill`), partitions (`fault.partition`), lost and duplicated
  messages, failed syncs, clock skew; at most `nodesDownMax` nodes down at once; per timeline each
  kind on or off (`world.swarm.*`, swarm testing);
- a node's own randomness (`choose`: an election timeout's);
- with `connections`, a node's death ends its connections: what was in flight from or to it is
  lost, a send to a down node fails, and each live peer sees it (`net.connection.reset`: its
  `connectionLost` runs) or not (a silent death: a half-open connection, as a peer cut off at the
  moment learns nothing);
- `Faults.targets` and `Config.clientNodes` keep faults and clients to some nodes;
- timers (`Node.setTimer`): due after some ticks, fired as an event (`world.timer` picks among the
  due), gone with their process; delayed sends (`Node.sendAfter`): deliverable only from a time
  on; ghost state (`Node.setGhost`, `Cluster.ghost`): values for the properties that no fault
  touches (what was acknowledged, a node's highest term ever).

A timeline boots every node, runs `steps` events with faults, then `recovery` events without
(partitions healed, every node started again), then judges. Properties: assertions in the code
(`check`), an `invariant` after every event, a `final` judgment after recovery (a history's
linearizability, convergence).
-/

namespace Determinismo

abbrev NodeId := Nat

/-- A system's types: a node's memory, its messages, its files' records, its clients' operations
and results. -/
structure Sys where
  State : Type
  Msg : Type
  Rec : Type
  Op : Type
  Res : Type

/-- A message in flight. -/
structure Envelope (M : Type) where
  id : Nat
  src : NodeId
  dst : NodeId
  msg : M
  /-- Not deliverable before this time (`Node.sendAfter`). -/
  notBefore : Nat := 0
  /-- The destination's starts when it was sent (a message from before its last start, with
  `connections` off, is a datagram outliving the process it was meant for). -/
  dstStarts : Nat := 0

/-- How a client's operation ended. -/
inductive Outcome (Res : Type) where
  /-- Acknowledged with this result. -/
  | ok (res : Res)
  /-- Definitely not applied. -/
  | fail
  deriving Repr, BEq

/-- A client's operation: invoked at a step, answered at another or never (indeterminate: it may
have taken effect, at any moment after its invocation). -/
structure OpRec (Op Res : Type) where
  id : Nat
  node : NodeId
  op : Op
  invoke : Nat
  ret : Option Nat := none
  outcome : Option (Outcome Res) := none

/-- The fault kinds, as determinismo injects them. -/
structure Faults where
  /-- Power losses: the disk keeps its synced writes, a prefix of the others, one torn. -/
  crash : Bool := true
  /-- Process kills: the node starts again with all it wrote. -/
  kill : Bool := true
  partition : Bool := true
  /-- One-way partitions too (a node hears but is not heard). -/
  asymmetric : Bool := true
  drop : Bool := true
  duplicate : Bool := true
  /-- Failed syncs (EIO): the writes reach the disk or not, never retried. -/
  syncErrors : Bool := false
  /-- Torn writes at a power loss. -/
  torn : Bool := true
  /-- Node clocks skewed, up to `skewMax` ticks either way. -/
  skew : Bool := false
  skewMax : Nat := 5
  /-- Power losses inside a node's code, at its disk operations: before a write, with the write
  cut short, or applied before the call returned; before a sync, or after it before it
  returned. One operation in `crashPointOneIn` when drawn, and only while fewer than
  `nodesDownMax` other nodes are down (`Cluster.downBesides`): a node's own start is eligible,
  nodes not yet booted are not down. -/
  crashPoints : Bool := true
  crashPointOneIn : Nat := 40
  /-- Memory pressure: a node's clean pages leave its cache (a failed sync's never-written pages
  with them). -/
  evict : Bool := true
  /-- At a power loss each pending write reached the disk or not, in any order (a filesystem
  that orders nothing); else a prefix of them, one torn (ordered appends). -/
  anyOrderWriteback : Bool := false
  /-- Per timeline, each kind drawn on or off. -/
  swarm : Bool := true
  /-- The nodes power losses, kills, clock skews and evictions may hit (none: any). -/
  targets : Option (List NodeId) := none
  deriving Repr

structure Config where
  nodes : Nat := 3
  /-- Events with faults. -/
  steps : Nat := 200
  /-- Events after the faults: partitions healed, every node started again. -/
  recovery : Nat := 300
  /-- Clients' operations at most. -/
  clientOps : Nat := 8
  faults : Faults := {}
  /-- At most this many nodes down at once. -/
  nodesDownMax : Nat := 1
  /-- Messages between two nodes delivered in order (one TCP connection's). -/
  fifo : Bool := false
  /-- Messages travel on connections that a node's death ends (see the module's text). -/
  connections : Bool := false
  /-- The nodes clients ask (none: any up node). -/
  clientNodes : Option (List NodeId) := none
  /-- Decisions per timeline at most. -/
  limit : Nat := 100000
  deriving Repr

/-- One node of the cluster. -/
structure Node (s : Sys) where
  /-- Its memory; none while it is down. -/
  state : Option s.State := none
  files : Files s.Rec := []
  /-- Its clock's skew, in ticks. -/
  skew : Int := 0
  starts : Nat := 0
  /-- Its code ended its process (`Node.halt`) during the event running now. -/
  halted : Bool := false

/-- The world: every node, the network, the clock, the history, the decisions. -/
structure Cluster (s : Sys) where
  decisions : Decisions := {}
  config : Config := {}
  /-- This timeline's fault kinds (the swarm's draw). -/
  faults : Faults := {}
  nodes : Array (Node s) := #[]
  net : List (Envelope s.Msg) := []
  nextMessage : Nat := 0
  /-- (from, to): messages from `from` to `to` cannot be delivered. -/
  blocked : List (NodeId × NodeId) := []
  /-- Ticks so far: the monotonic clock. -/
  time : Nat := 0
  /-- Events so far. -/
  step : Nat := 0
  history : Array (OpRec s.Op s.Res) := #[]
  /-- What happened, a line an event: a counterexample's story. -/
  log : Array String := #[]
  /-- The faults are over (the recovery phase). -/
  recovering : Bool := false
  /-- Nodes that died in this event, their peers not yet told (`connections`). -/
  died : List NodeId := []
  /-- Timers set: node, name, due time. -/
  timers : List (NodeId × String × Nat) := []
  /-- Ghost state: named values the properties read, outside every node (no fault touches it). -/
  ghost : List (String × Int) := []

instance {s : Sys} : Chaotic (Cluster s) where
  decisions c := c.decisions
  setDecisions c d := { c with decisions := d }

abbrev ClusterM (s : Sys) := EStateM Stop (Cluster s)

/-- A node's code runs here: it knows which node it is. -/
abbrev NodeM (s : Sys) := ReaderT NodeId (ClusterM s)

/-- What a system is: its nodes' code and its clients' operations. -/
structure Behavior (s : Sys) where
  /-- A start (the first boot, every start after a fault): its memory from what its disk holds. -/
  start : NodeM s s.State
  receive : s.State → Envelope s.Msg → NodeM s s.State
  tick : s.State → NodeM s s.State
  /-- A client's request `id`: the node answers it now (`reply`, `fail`) or later. -/
  request : s.State → Nat → s.Op → NodeM s s.State
  /-- A client's next operation, drawn. -/
  operation : ClusterM s s.Op
  /-- With `connections`: the connection to `peer` was reset (it died). -/
  connectionLost : s.State → NodeId → NodeM s s.State := fun state _ => pure state
  /-- A timer the node set (`Node.setTimer`) fired. -/
  timer : s.State → String → NodeM s s.State := fun state _ => pure state

structure Properties (s : Sys) where
  invariant : Cluster s → Option String := fun _ => none
  final : Cluster s → Option String := fun _ => none

namespace Cluster

variable {s : Sys}

def node (c : Cluster s) (n : NodeId) : Node s := c.nodes.getD n {}

def setNode (c : Cluster s) (n : NodeId) (f : Node s → Node s) : Cluster s :=
  { c with nodes := c.nodes.modify n f }

def up (c : Cluster s) (n : NodeId) : Bool := (c.node n).state.isSome

def upNodes (c : Cluster s) : List NodeId := (List.range c.nodes.size).filter c.up

def downNodes (c : Cluster s) : List NodeId := (List.range c.nodes.size).filter (!c.up ·)

/-- The nodes other than `n` that booted and are down now: what bounds a crash point in `n`'s
code (`nodesDownMax`), `n`'s own start included. -/
def downBesides (c : Cluster s) (n : NodeId) : List NodeId :=
  (List.range c.nodes.size).filter fun m => m != n && (c.node m).starts > 0 && !c.up m

/-- The up nodes faults may hit. -/
def targetable (c : Cluster s) : List NodeId :=
  match c.faults.targets with
  | some ts => c.upNodes.filter ts.contains
  | none => c.upNodes

/-- The up nodes clients may ask. -/
def clientable (c : Cluster s) : List NodeId :=
  match c.config.clientNodes with
  | some ns => c.upNodes.filter ns.contains
  | none => c.upNodes

/-- Node `n` died: its timers gone with its process; with `connections`, its messages in flight
lost and its peers to be told. -/
def connectionsEnd (c : Cluster s) (n : NodeId) : Cluster s :=
  let c := { c with timers := c.timers.filter (·.1 != n) }
  if c.config.connections then
    { c with net := c.net.filter (fun e => e.src != n && e.dst != n),
             died := if c.died.contains n then c.died else c.died ++ [n] }
  else c

/-- Timers due now, of nodes that are up. -/
def dueTimers (c : Cluster s) : List (NodeId × String × Nat) :=
  c.timers.filter fun (n, _, due) => due ≤ c.time && c.up n

def ghostOf (c : Cluster s) (key : String) : Int := (c.ghost.lookup key).getD 0

def deliverable (c : Cluster s) : List (Envelope s.Msg) :=
  let open_ := c.net.filter fun e => !c.blocked.contains (e.src, e.dst) && e.notBefore ≤ c.time
  if c.config.fifo then
    open_.filter fun e => !(c.net.any fun o => o.src == e.src && o.dst == e.dst && o.id < e.id)
  else open_

end Cluster

def note {s : Sys} (line : String) : ClusterM s Unit :=
  modify fun c => { c with log := c.log.push s!"{c.step}: {line}" }

/-! ## What a node's code can do -/

namespace Node

variable {s : Sys}

def self : NodeM s NodeId := read

/-- How many nodes the cluster has. -/
def clusterSize : NodeM s Nat := do pure (← get).nodes.size

def send (dst : NodeId) (msg : s.Msg) : NodeM s Unit := do
  let src ← read
  let c ← get
  -- On a connection, a send to a down node fails (nothing to connect to).
  if c.config.connections && !c.up dst then return
  modify fun c => { c with net := c.net ++ [{ id := c.nextMessage, src, dst, msg, dstStarts := (c.node dst).starts }],
                           nextMessage := c.nextMessage + 1 }

/-- A send delivered no sooner than `ticks` from now (a retry's backoff, a queued reply). -/
def sendAfter (dst : NodeId) (ticks : Nat) (msg : s.Msg) : NodeM s Unit := do
  let src ← read
  let c ← get
  if c.config.connections && !c.up dst then return
  modify fun c => { c with net := c.net ++ [{ id := c.nextMessage, src, dst, msg, notBefore := c.time + ticks,
                                              dstStarts := (c.node dst).starts }],
                           nextMessage := c.nextMessage + 1 }

/-- A timer named `name` due in `ticks` (the node's earlier one of that name replaced). -/
def setTimer (name : String) (ticks : Nat) : NodeM s Unit := do
  let n ← read
  modify fun c => { c with timers := (n, name, c.time + ticks) :: c.timers.filter (fun (m, k, _) => !(m == n && k == name)) }

def cancelTimer (name : String) : NodeM s Unit := do
  let n ← read
  modify fun c => { c with timers := c.timers.filter (fun (m, k, _) => !(m == n && k == name)) }

/-- Ghost state, for the properties: kept across every fault. -/
def setGhost (key : String) (value : Int) : NodeM s Unit :=
  modify fun c => { c with ghost := (key, value) :: c.ghost.filter (·.1 != key) }

def ghost (key : String) : NodeM s Int := do pure ((← get).ghostOf key)

def file (name : String) : NodeM s (File s.Rec) := do
  pure (((← get).node (← read)).files.get name)

/-- What reads of a file see. -/
def readFile (name : String) : NodeM s (List s.Rec) := do pure (← file name).cache

def setFile (name : String) (f : File s.Rec) : NodeM s Unit := do
  let n ← read
  modify fun c => c.setNode n fun nd => { nd with files := nd.files.set name f }

/-- A crash point here, drawn: none, or where in the operation the power goes (its phases). -/
def crashPoint (phases : Nat) : NodeM s (Option Nat) := do
  let c ← get
  if !c.faults.crashPoints || c.recovering then return none
  -- At most `nodesDownMax` down once the power goes here: the node itself counts as up (its own
  -- start too), and nodes not yet booted are not down.
  if (c.downBesides (← read)).length ≥ c.config.nodesDownMax then return none
  if !(← decideRare (σ := Cluster s) "disk.crash.point" 1 c.faults.crashPointOneIn) then return none
  return some (← decide (σ := Cluster s) "disk.crash.phase" phases)

def write (name : String) (w : Write s.Rec) : NodeM s Unit := do
  match ← crashPoint (s := s) 3 with
  | none => setFile name ((← file name).write w)
  | some phase =>
    let n ← read
    -- 0: before the write; 1: cut short partway; 2: applied, before the call returned.
    if phase == 1 && w.size > 1 then
      let kept ← decide (σ := Cluster s) "disk.crash.cut" w.size
      setFile name ((← file name).write (w.cutShort kept))
    else if phase == 2 then setFile name ((← file name).write w)
    note (s := s) s!"node {n}: power lost at its write of {name} ({["before it", "partway", "after it"].getD phase ""})"
    throw (.nodeDown n)

def append (name : String) (records : List s.Rec) : NodeM s Unit := write name (.append records)

def replace (name : String) (records : List s.Rec) : NodeM s Unit := write name (.replace records)

def truncate (name : String) (length : Nat) : NodeM s Unit := write name (.truncate length)

/-- fsync: true when it succeeded. A failure (syncErrors) leaves each pending write on the disk or
not, never retried. -/
def sync (name : String) : NodeM s Bool := do
  let f ← file name
  if f.pending.isEmpty then return true
  if let some phase ← crashPoint (s := s) 2 then
    let n ← read
    -- 0: before the sync; 1: after it, before the call returned (the data is on the disk).
    if phase == 1 then setFile name f.syncOk
    note (s := s) s!"node {n}: power lost at its sync of {name} ({if phase == 0 then "before it" else "after it"})"
    throw (.nodeDown n)
  let c ← get
  let failed ← if c.faults.syncErrors && !c.recovering then
      decideRare (σ := Cluster s) "disk.sync.error" 1 8 else pure false
  if failed then
    let mut reached := []
    for _ in f.pending do
      reached := reached ++ [(← decide (σ := Cluster s) "disk.sync.reached" 2) == 1]
    setFile name (f.syncFailed reached)
    note (s := s) s!"node {← read}: sync of {name} failed"
    return false
  setFile name f.syncOk
  return true

/-- The monotonic clock, in ticks. -/
def now : NodeM s Nat := do pure (← get).time

/-- The node's wall clock, in ticks: the cluster's time plus its skew. -/
def wallclock : NodeM s Int := do
  let c ← get
  pure (Int.ofNat c.time + (c.node (← read)).skew)

/-- The node's own randomness (Go's rand, a jittered timeout): a decision. -/
def choose (name : String) (options : Nat) : NodeM s Nat :=
  decide (σ := Cluster s) s!"node.{name}" options

def answer (request : Nat) (outcome : Outcome s.Res) : NodeM s Unit :=
  modify fun c =>
    { c with history := c.history.map fun o =>
        if o.id == request && o.ret.isNone then { o with ret := some c.step, outcome := some outcome } else o }

def reply (request : Nat) (res : s.Res) : NodeM s Unit := answer request (.ok res)

def fail (request : Nat) : NodeM s Unit := answer request .fail

/-- An assertion in the code: the timeline stops when it is false. -/
def check (cond : Bool) (property : String) (detail : String := "") : NodeM s Unit := do
  unless cond do
    let n ← read
    throw (.violation property s!"node {n}: {detail}")

def log (line : String) : NodeM s Unit := do note (s := s) s!"node {← read}: {line}"

/-- The process ends here (a fatal error's exit, a panic): the node is down once this event's code
returns, its memory gone, its disk as it is; the world may start it again. -/
def halt (reason : String) : NodeM s Unit := do
  let n ← read
  modify fun c => c.setNode n fun nd => { nd with halted := true }
  note (s := s) s!"node {n} halted: {reason}"

end Node

/-! ## The world's events -/

namespace World

variable {s : Sys}

/-- A power loss's effect on node `n`: down, each file keeping what `Disk` says, by decisions. -/
def powerLossFiles (n : NodeId) : ClusterM s Unit := do
  let c ← get
  let mut files : Files s.Rec := []
  for (name, f) in (c.node n).files do
    if c.faults.anyOrderWriteback then
      let mut reached := []
      for _ in f.pending do
        reached := reached ++ [(← decide (σ := Cluster s) "disk.crash.reached" 2) == 1]
      files := files ++ [(name, f.crashAny reached)]
    else
      let kept ← decide (σ := Cluster s) "disk.crash.kept" (f.pending.length + 1)
      let torn ← match f.pending.drop kept with
        | next :: _ =>
          if c.faults.torn && next.size > 1 then decide (σ := Cluster s) "disk.crash.torn" next.size
          else pure 0
        | [] => pure 0
      files := files ++ [(name, f.crash kept torn)]
  modify fun c => (c.setNode n fun nd => { nd with state := none, halted := false, files := files }).connectionsEnd n
  note s!"node {n} lost power"

/-- A node's code at node `n`; none when the power went inside it (a crash point): the node is
then down, its files as a power loss leaves them. -/
def runAt {α : Type} (n : NodeId) (x : NodeM s α) : ClusterM s (Option α) := do
  try
    let r ← x.run n
    pure (some r)
  catch e =>
    match e with
    | .nodeDown m => do powerLossFiles m; pure none
    | other => throw other

/-- A node's memory after an event's code: down when the code halted. -/
def settle (n : NodeId) (state : s.State) : ClusterM s Unit :=
  modify fun c =>
    let halted := (c.node n).halted
    let c := c.setNode n fun nd =>
      if nd.halted then { nd with state := none, halted := false } else { nd with state := some state }
    if halted then c.connectionsEnd n else c

def startNode (b : Behavior s) (n : NodeId) : ClusterM s Unit := do
  modify fun c => c.setNode n fun nd => { nd with starts := nd.starts + 1 }
  match ← runAt n b.start with
  | some state =>
    settle n state
    note s!"node {n} started"
  | none =>
    note s!"node {n} lost power during its {if ((← get).node n).starts == 1 then "first " else ""}start"

/-- A power loss: the node down, each file keeping what `Disk` says, by decisions. -/
def powerLoss (n : NodeId) : ClusterM s Unit := powerLossFiles n

def kill (n : NodeId) : ClusterM s Unit := do
  modify fun c => (c.setNode n fun nd => { nd with state := none }).connectionsEnd n
  note s!"node {n} killed"

/-- The live peers of the nodes that died in this event: each told (a reset) or not (silent). -/
def tellDeaths (b : Behavior s) : ClusterM s Unit := do
  let died := (← get).died
  modify fun c => { c with died := [] }
  for n in died do
    for m in (← get).upNodes do
      if m != n then
        if (← decide (σ := Cluster s) "net.connection.reset" 2) == 1 then
          note s!"node {m}: connection to node {n} reset"
          if let some state := ((← get).node m).state then
            if let some state' ← runAt m (b.connectionLost state n) then settle m state'
        else note s!"node {m}: connection to node {n} died silently"

/-- A partition: a side drawn, cut from the rest (one way only when drawn so). -/
def partition : ClusterM s Unit := do
  let c ← get
  let size := c.nodes.size
  if size < 2 then return
  -- A nonempty proper side, as a bit mask.
  let mask := 1 + (← decide (σ := Cluster s) "fault.partition.side" (2 ^ size - 2))
  let side := (List.range size).filter fun n => (mask >>> n) % 2 == 1
  let rest := (List.range size).filter (!side.contains ·)
  let oneWay ← if c.faults.asymmetric then decideRare (σ := Cluster s) "fault.partition.one_way" 1 4
    else pure false
  let cut := side.flatMap fun a => rest.flatMap fun b => if oneWay then [(a, b)] else [(a, b), (b, a)]
  modify fun c => { c with blocked := cut }
  note s!"partition: {side} from {rest}{if oneWay then " (one way)" else ""}"

def deliver (b : Behavior s) (e : Envelope s.Msg) (keepCopy : Bool) : ClusterM s Unit := do
  unless keepCopy do
    modify fun c => { c with net := c.net.filter (·.id != e.id) }
  let c ← get
  match (c.node e.dst).state with
  | none => pure () -- Its node is down: lost.
  | some state =>
    if let some state' ← runAt e.dst (b.receive state e) then settle e.dst state'

def tickNode (b : Behavior s) (n : NodeId) : ClusterM s Unit := do
  match ((← get).node n).state with
  | none => pure ()
  | some state =>
    if let some state' ← runAt n (b.tick state) then settle n state'

def clientRequest (b : Behavior s) (n : NodeId) : ClusterM s Unit := do
  let op ← b.operation
  let c ← get
  let id := c.history.size
  modify fun c => { c with history := c.history.push { id, node := n, op, invoke := c.step } }
  note s!"client {id} asks node {n}"
  match (c.node n).state with
  | none => pure ()
  | some state =>
    if let some state' ← runAt n (b.request state id op) then settle n state'

inductive Event where
  | deliver | duplicate | drop | tick | client | crash | kill | start | partition | heal | skew | evict | timer
  deriving Repr, BEq

/-- The events possible now, each with its weight. -/
def possible (c : Cluster s) : List (Event × Nat) :=
  let f := c.faults
  let faulty := !c.recovering
  let up := c.upNodes
  let down := c.downNodes
  let canTakeDown := faulty && down.length < c.config.nodesDownMax && !c.targetable.isEmpty
  let some_ := c.deliverable
  [ (.deliver, if some_.isEmpty then 0 else 6),
    (.duplicate, if faulty && f.duplicate && !some_.isEmpty then 1 else 0),
    (.drop, if faulty && f.drop && !c.net.isEmpty then 1 else 0),
    (.tick, if up.isEmpty then 0 else 4),
    (.client, if c.history.size < c.config.clientOps && !c.clientable.isEmpty && !c.recovering then 2 else 0),
    (.crash, if canTakeDown && f.crash then 1 else 0),
    (.kill, if canTakeDown && f.kill then 1 else 0),
    (.start, if down.isEmpty then 0 else if c.recovering then 4 else 2),
    (.partition, if faulty && f.partition && c.blocked.isEmpty then 1 else 0),
    (.heal, if !c.blocked.isEmpty then (if c.recovering then 8 else 1) else 0),
    (.skew, if faulty && f.skew && !c.targetable.isEmpty then 1 else 0),
    (.evict, if faulty && f.evict && !c.targetable.isEmpty then 1 else 0),
    (.timer, if c.dueTimers.isEmpty then 0 else 3) ].filter (·.2 > 0)

/-- One event, drawn. False when nothing can happen. -/
def event (b : Behavior s) : ClusterM s Bool := do
  let c ← get
  let options := possible c
  if options.isEmpty then return false
  let index ← decideWeighted (σ := Cluster s) "world.event" (options.map (·.2))
  let kind := (options.getD index (.tick, 1)).1
  match kind with
  | .deliver =>
    if let some e ← pick (σ := Cluster s) "net.deliver" c.deliverable then deliver b e false
  | .duplicate =>
    if let some e ← pick (σ := Cluster s) "net.duplicate" c.deliverable then
      note s!"message {e.id} duplicated"
      deliver b e true
  | .drop =>
    if let some e ← pick (σ := Cluster s) "net.drop" c.net then
      modify fun c => { c with net := c.net.filter (·.id != e.id) }
      note s!"message {e.id} lost"
  | .tick =>
    if let some n ← pick (σ := Cluster s) "world.tick" c.upNodes then
      modify fun c => { c with time := c.time + 1 }
      tickNode b n
  | .client =>
    if let some n ← pick (σ := Cluster s) "world.client" c.clientable then clientRequest b n
  | .crash => if let some n ← pick (σ := Cluster s) "fault.crash" c.targetable then powerLoss n
  | .kill => if let some n ← pick (σ := Cluster s) "fault.kill" c.targetable then kill n
  | .start => if let some n ← pick (σ := Cluster s) "world.start" c.downNodes then startNode b n
  | .partition => partition
  | .heal =>
    modify fun c => { c with blocked := [] }
    note "partition healed"
  | .skew =>
    if let some n ← pick (σ := Cluster s) "fault.clock.node" c.targetable then
      let m := c.faults.skewMax
      let v ← decide (σ := Cluster s) "fault.clock.skew" (2 * m + 1)
      let skew : Int := Int.ofNat v - Int.ofNat m
      modify fun c => c.setNode n fun nd => { nd with skew := skew }
      note s!"node {n}'s clock skewed {skew}"
  | .evict =>
    if let some n ← pick (σ := Cluster s) "fault.evict" c.targetable then
      modify fun c => c.setNode n fun nd => { nd with files := nd.files.map fun (name, f) => (name, f.evict) }
      note s!"node {n}'s page cache evicted"
  | .timer =>
    if let some (n, name, _) ← pick (σ := Cluster s) "world.timer" c.dueTimers then
      modify fun c => { c with timers := c.timers.filter (fun (m, k, _) => !(m == n && k == name)) }
      note s!"node {n}: timer {name} fired"
      if let some state := ((← get).node n).state then
        if let some state' ← runAt n (b.timer state name) then settle n state'
  tellDeaths b
  modify fun c => { c with step := c.step + 1 }
  return true

def checkInvariant (p : Properties s) : ClusterM s Unit := do
  if let some detail := p.invariant (← get) then throw (.violation "invariant" detail)

/-- This timeline's fault kinds: each on or off (swarm testing). -/
def swarm (f : Faults) : ClusterM s Faults := do
  if !f.swarm then return f
  let on (name : String) (enabled : Bool) : ClusterM s Bool := do
    if enabled then pure ((← decide (σ := Cluster s) s!"world.swarm.{name}" 2) == 1) else pure false
  return { f with
    crash := ← on "crash" f.crash, kill := ← on "kill" f.kill,
    partition := ← on "partition" f.partition, drop := ← on "drop" f.drop,
    duplicate := ← on "duplicate" f.duplicate, syncErrors := ← on "sync_errors" f.syncErrors,
    skew := ← on "skew" f.skew, crashPoints := ← on "crash_points" f.crashPoints,
    evict := ← on "evict" f.evict }

/-- A whole timeline: boot, faults, recovery, judgment. -/
def timeline (b : Behavior s) (p : Properties s) : ClusterM s Unit := do
  let c ← get
  let faults ← swarm c.config.faults
  modify fun c => { c with faults := faults, nodes := Array.replicate c.config.nodes {} }
  for n in List.range c.config.nodes do startNode b n
  for _ in List.range c.config.steps do
    unless ← event b do break
    checkInvariant p
  modify fun c => { c with recovering := true, blocked := [] }
  note "faults over"
  for _ in List.range c.config.recovery do
    unless ← event b do break
    checkInvariant p
  if let some detail := p.final (← get) then throw (.violation "final" detail)

end World

/-- How one timeline ended. -/
structure Run (s : Sys) where
  taken : Array Taken
  /-- The property broken, if any. -/
  violation : Option (String × String)
  cluster : Cluster s

/-- Runs one timeline from a source of decisions. -/
def runCluster {s : Sys} (b : Behavior s) (p : Properties s) (config : Config) (source : Source) : Run s :=
  let start : Cluster s := { config, decisions := { source, limit := config.limit } }
  match (World.timeline b p).run start with
  | .ok _ c => { taken := c.decisions.taken, violation := none, cluster := c }
  | .error (.violation property detail) c => { taken := c.decisions.taken, violation := some (property, detail), cluster := c }
  | .error .limit c => { taken := c.decisions.taken, violation := none, cluster := c }
  | .error (.nodeDown _) c => { taken := c.decisions.taken, violation := none, cluster := c }

end Determinismo
