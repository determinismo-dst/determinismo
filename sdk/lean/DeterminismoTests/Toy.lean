import Determinismo

/-!
# A toy register on a write-ahead log

Node 0 serves; the others forward their clients' requests to it. A write appends an entry (its
sequence number, its request, its value) to the log; a request already in the log is answered
again without a second write (forwarded requests can arrive twice). How a write then answers is
the variant:

- `ackBeforeSync`: answers at once (the log synced later, or never): a power loss loses an
  acknowledged write;
- `ignoreSyncError`: syncs, answers whatever the sync said: a failed sync's write is read back
  from the cache, then lost at a power loss;
- `correct`: syncs, answers only when the sync succeeded, halts when it failed; and a start appends
  a copy of what it reads and syncs it before serving, since after a failed sync the cache can hold
  what never reached the disk (the highest sequence number wins, so a torn copy changes nothing).

The world must find the first two and nothing in the third. Its earlier versions, found by it: a
duplicated forward wrote twice (no deduplication), and a halt after a failed sync served the
cache's unsynced entry after the restart.
-/

namespace DeterminismoTests.Toy

open Determinismo

inductive Variant where
  | ackBeforeSync | ignoreSyncError | correct
  deriving BEq, Repr

inductive Op where
  | write (value : Nat)
  | read
  deriving BEq, Repr

inductive Res where
  | done
  | value (v : Nat)
  deriving BEq, Repr

inductive Msg where
  | forward (request : Nat) (op : Op)

structure Entry where
  seq : Nat
  request : Nat
  value : Nat
  deriving BEq, Repr

structure State where
  value : Nat := 0
  seq : Nat := 0
  served : List Nat := []

abbrev sys : Sys := { State := State, Msg := Msg, Rec := Entry, Op := Op, Res := Res }

/-- What a log holds: its newest entry's value and sequence number, the requests in it. -/
def recover (wal : List Entry) : State :=
  let newest := wal.foldl (fun (b : Option Entry) e => match b with
    | some b => if e.seq > b.seq then some e else some b
    | none => some e) none
  { value := newest.map (·.value) |>.getD 0, seq := newest.map (·.seq) |>.getD 0,
    served := wal.map (·.request) }

def serve (variant : Variant) (st : State) (request : Nat) : Op → NodeM sys State
  | .read => do
    Node.reply (s := sys) request (.value st.value)
    pure st
  | .write v => do
    if st.served.contains request then
      Node.reply (s := sys) request .done
      return st
    let entry : Entry := { seq := st.seq + 1, request, value := v }
    Node.append (s := sys) "wal" [entry]
    let st' : State := { value := v, seq := entry.seq, served := request :: st.served }
    match variant with
    | .ackBeforeSync =>
      Node.reply (s := sys) request .done
      pure st'
    | .ignoreSyncError =>
      let _ ← Node.sync (s := sys) "wal"
      Node.reply (s := sys) request .done
      pure st'
    | .correct =>
      if ← Node.sync (s := sys) "wal" then
        Node.reply (s := sys) request .done
        pure st'
      else
        Node.halt (s := sys) "the log's sync failed"
        pure st

def behavior (variant : Variant) : Behavior sys where
  start := do
    let wal ← Node.readFile (s := sys) "wal"
    if variant == .correct && !wal.isEmpty then
      -- What the cache shows may not be on the disk (a failed sync before): written again.
      Node.append (s := sys) "wal" wal
      unless ← Node.sync (s := sys) "wal" do Node.halt (s := sys) "the log's sync failed at start"
    pure (recover wal)
  receive st e := do
    match e.msg with
    | .forward request op =>
      if (← Node.self (s := sys)) == 0 then serve variant st request op else pure st
  tick st := pure st
  request st id op := do
    if (← Node.self (s := sys)) == 0 then serve variant st id op
    else
      Node.send (s := sys) 0 (.forward id op)
      pure st
  operation := do
    if (← decide (σ := Cluster sys) "client.kind" 2) == 0 then pure .read
    else pure (.write ((← decide (σ := Cluster sys) "client.value" 3) + 1))

def apply (v : Nat) : Op → Nat × Res
  | .write w => (w, .done)
  | .read => (v, .value v)

def properties : Properties sys where
  final c :=
    if linearizable (S := Nat) (Op := Op) (Res := Res) 0 apply c.history.toList then none
    else some s!"not linearizable: {String.intercalate "; " (historyLines (Op := Op) (Res := Res) c.history)}"

def run (variant : Variant) (config : Config) (source : Source) : Ended :=
  let r := runCluster (behavior variant) properties config source
  { taken := r.taken, violation := r.violation }

def runLog (variant : Variant) (config : Config) (source : Source) : Array String :=
  (runCluster (behavior variant) properties config source).cluster.log

end DeterminismoTests.Toy
