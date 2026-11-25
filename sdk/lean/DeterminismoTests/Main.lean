import Determinismo
import DeterminismoTests.Toy
import DeterminismoTests.Locks
import DeterminismoTests.Boot

/-! The library's tests: `lake exe determinismo-lean-tests` (exit 1 when one fails). -/

open Determinismo

namespace DeterminismoTests

/-- A small program of decisions: two yes-or-no and one of three, a violation on one path. -/
structure Tiny where
  decisions : Decisions := {}

instance : Chaotic Tiny where
  decisions t := t.decisions
  setDecisions t d := { t with decisions := d }

def tinyBody : EStateM Stop Tiny Unit := do
  let a ← decide (σ := Tiny) "a" 2
  let b ← decide (σ := Tiny) "b" 2
  let c ← decide (σ := Tiny) "c" 3
  if a == 1 && b == 0 && c == 2 then violate (σ := Tiny) "tiny" "a=1 b=0 c=2"

def tinyRun (source : Source) : Ended :=
  match tinyBody.run { decisions := { source } } with
  | .ok _ t => { taken := t.decisions.taken, violation := none }
  | .error (.violation p d) t => { taken := t.decisions.taken, violation := some (p, d) }
  | .error .limit t => { taken := t.decisions.taken, violation := none }
  | .error (.nodeDown _) t => { taken := t.decisions.taken, violation := none }

def tinyClean (source : Source) : Ended := { tinyRun source with violation := none }

/-- The tiny program with its first decision in an unrecorded setup phase. -/
def tinyUnrecorded (source : Source) : Ended :=
  let body : EStateM Stop Tiny Unit := do
    let _ ← unrecorded (σ := Tiny) 3 (decide (σ := Tiny) "a" 2)
    let _ ← decide (σ := Tiny) "b" 2
    let _ ← decide (σ := Tiny) "c" 3
  match body.run { decisions := { source } } with
  | .ok _ t => { taken := t.decisions.taken, violation := none }
  | .error _ t => { taken := t.decisions.taken, violation := none }

/-- Code that decides without knowing its world. -/
def generic {m : Type → Type} [Monad m] [MonadDecide m] : m Nat := do
  let x ← MonadDecide.decideIn "generic.first" [1, 1, 1]
  let y ← MonadDecide.decideIn "generic.second" [1, 1]
  pure (10 * x + y)

structure Check where
  name : String
  ok : Bool

def disk : List Check :=
  let f : File Nat := {}
  let f1 := (f.write (.append [1, 2])).syncOk
  let f2 := (f1.write (.append [3])).write (.append [4, 5, 6])
  [ { name := "a synced write survives a power loss", ok := (f1.crash 0 0).cache == [1, 2] },
    { name := "a power loss keeps a prefix of the pending writes", ok := (f2.crash 1 0).cache == [1, 2, 3] },
    { name := "a torn write keeps part of the next", ok := (f2.crash 1 2).cache == [1, 2, 3, 4, 5] },
    { name := "nothing pending reached the disk: all lost", ok := (f2.crash 0 0).cache == [1, 2] },
    { name := "a failed sync's write is read back until a power loss",
      ok := (f2.syncFailed [false, true]).cache == [1, 2, 3, 4, 5, 6]
        && ((f2.syncFailed [false, true]).crash 0 0).cache == [1, 2, 4, 5, 6] },
    { name := "a failed sync's writes are never written again",
      ok := ((f2.syncFailed [false, false]).syncOk).disk == [1, 2] },
    { name := "a rewrite torn at a power loss keeps part of the new content",
      ok := ((f1.write (.replace [7, 8, 9])).crash 0 2).cache == [7, 8] },
    { name := "an eviction after a failed sync drops what never reached the disk",
      ok := ((f2.syncFailed [false, true]).evict).cache == [1, 2, 4, 5, 6] },
    { name := "an eviction keeps the writes still pending",
      ok := (f2.evict).cache == f2.cache },
    { name := "writeback in any order: the second pending write without the first",
      ok := (f2.crashAny [false, true]).cache == [1, 2, 4, 5, 6] },
    { name := "a write cut short keeps its first records",
      ok := ((Write.append [4, 5, 6]).cutShort 2).apply [1] == [1, 4, 5] } ]

def history : List Check :=
  let w (id : Nat) (v : Nat) (i r : Nat) (out : Option (Outcome Toy.Res)) : OpRec Toy.Op Toy.Res :=
    { id, node := 0, op := .write v, invoke := i, ret := if out.isSome then some r else none, outcome := out }
  let rd (id : Nat) (i r : Nat) (v : Nat) : OpRec Toy.Op Toy.Res :=
    { id, node := 0, op := .read, invoke := i, ret := some r, outcome := some (.ok (.value v)) }
  let lin (ops : List (OpRec Toy.Op Toy.Res)) := linearizable (S := Nat) 0 Toy.apply ops
  [ { name := "a read after an acknowledged write sees it", ok := lin [w 0 1 0 1 (some (.ok .done)), rd 1 2 3 1] },
    { name := "a read after an acknowledged write cannot see the old value",
      ok := !lin [w 0 1 0 1 (some (.ok .done)), rd 1 2 3 0] },
    { name := "concurrent write and read: either value",
      ok := lin [w 0 1 0 5 (some (.ok .done)), rd 1 1 4 0] && lin [w 0 1 0 5 (some (.ok .done)), rd 1 1 4 1] },
    { name := "an unanswered write may take effect later", ok := lin [w 0 1 0 0 none, rd 1 2 3 0, rd 2 4 5 1] },
    { name := "an unanswered write cannot be undone once seen",
      ok := !lin [w 0 1 0 0 none, rd 1 2 3 1, rd 2 4 5 0] },
    { name := "a failed write never took effect", ok := !lin [w 0 1 0 1 (some .fail), rd 1 2 3 1] } ]

def decisions : List Check :=
  let replayed := tinyRun (Source.path #[1, 0, 2])
  let again := (tinyRun (Source.seeded 7)).taken == (tinyRun (Source.seeded 7)).taken
  [ { name := "a path replays its timeline", ok := replayed.violation.isSome },
    { name := "the same seed takes the same decisions", ok := again },
    { name := "every path of the tiny program: 12 timelines",
      ok := match exhaust tinyClean 100 with | .complete n => n == 12 | _ => false },
    { name := "the exhaustive search finds the one bad path",
      ok := match exhaust tinyRun 100 with | .found c => c.values == #[1, 0, 2] | _ => false },
    { name := "an unrecorded phase leaves the search what follows it: 6 timelines",
      ok := match exhaust tinyUnrecorded 100 with | .complete n => n == 6 | _ => false },
    { name := "an unrecorded phase repeats from its seed and records nothing",
      ok := (tinyUnrecorded (Source.path #[1, 2])).taken.map (·.name) == #["b", "c"]
        && (tinyUnrecorded (Source.path #[1, 2])).taken.map (·.value) == #[1, 2] },
    { name := "generic code decides from a world's monad",
      ok := match (generic (m := EStateM Stop Tiny)).run { decisions := { source := Source.path #[2, 1] } } with
        | .ok v _ => v == 21 | _ => false },
    { name := "generic code decides from a node-like reader, and over decisions alone",
      ok := (match ((generic (m := ReaderT Nat (EStateM Stop Tiny))).run 7).run { decisions := { source := Source.path #[1, 0] } } with
          | .ok v _ => v == 10 | _ => false)
        && (match (generic (m := EStateM Stop Decisions)).run { source := Source.path #[2, 0] } with
          | .ok v d => v == 20 && d.taken.size == 2 | _ => false) },
    { name := "a timeline's first decision varies across seeds (2 options: each 40-60% of 1,000 seeds)",
      ok := let ones := ((List.range 1000).filter fun i => (tinyRun (Source.seeded i)).taken[0]!.value == 1).length
        400 ≤ ones && ones ≤ 600 },
    { name := "a timeline's first decision varies across seeds (3 options: each 25-42% of 1,000 seeds)",
      ok := let firsts := (List.range 1000).map fun i =>
          (Decisions.next { source := Source.seeded i } "x" [1, 1, 1]).toOption.map (·.1) |>.getD 9
        (List.range 3).all fun v => let k := (firsts.filter (· == v)).length; 250 ≤ k && k ≤ 420 },
    { name := "a weighted draw stays in range",
      ok := (List.range 200).all fun i => (drawWeighted (mkStdGen i) [1, 0, 5]).1 ∈ [0, 2] } ]

/-- An uneven tree: a's second option ends the timeline, its first opens three more: 4 timelines. -/
def unevenRun (source : Source) : Ended :=
  let body : EStateM Stop Tiny Unit := do
    let a ← decide (σ := Tiny) "a" 2
    if a == 0 then
      let _ ← decide (σ := Tiny) "c" 3
      pure ()
  match body.run { decisions := { source } } with
  | .ok _ t => { taken := t.decisions.taken, violation := none }
  | .error _ t => { taken := t.decisions.taken, violation := none }

/-- Steps until a 0; a 2 after a 1 breaks "order". -/
def stepsRun (source : Source) : Ended :=
  let body : EStateM Stop Tiny Unit := do
    let mut seenOne := false
    for _ in List.range 10 do
      let step ← decide (σ := Tiny) "step" 3
      if step == 0 then return
      if step == 2 && seenOne then violate (σ := Tiny) "order" s!"a 2 after a 1"
      if step == 1 then seenOne := true
  match body.run { decisions := { source } } with
  | .ok _ t => { taken := t.decisions.taken, violation := none }
  | .error (.violation p d) t => { taken := t.decisions.taken, violation := some (p, d) }
  | .error _ t => { taken := t.decisions.taken, violation := none }

def shrinkChecks : List Check :=
  let o := stepsRun (Source.path #[1, 1, 1, 2])
  let c : Counterexample := { taken := o.taken, property := "order", detail := "a 2 after a 1", runs := 1 }
  [ { name := "the counterexample to shrink breaks the property", ok := o.violation.isSome && o.taken.size == 4 },
    { name := "shrinking drops decisions from the middle: 1 1 1 2 to 1 2",
      ok := (shrink stepsRun c).values == #[1, 2] } ]

def censusChecks : List Check :=
  let whole := census tinyRun
  let half := census tinyRun (maxRuns := 5)
  let rest := censusStep tinyRun {} 100 half
  let capped := census tinyRun { perName := [("c", 2)] }
  [ { name := "a census runs every timeline and counts the one bad path",
      ok := whole.runs == 12 && whole.clean == 11 && whole.next.isNone
        && (match whole.byProperty.toList with
            | [p] => p.property == "tiny" && p.count == 1 && p.first.values == #[1, 0, 2]
            | _ => false) },
    { name := "a census resumed from its segment's next counts the same",
      ok := half.runs == 5 && half.next.isSome && rest.runs == 12 && rest.clean == 11
        && rest.violations == 1 && rest.next.isNone },
    { name := "a path line round-trips", ok := pathOfLine (pathLine #[1, 0, 2]) == some #[1, 0, 2] && pathOfLine "" == some #[] },
    { name := "a depth cap branches only the first decisions: 2 timelines, then 4",
      ok := (census tinyClean { depth := some 1 }).runs == 2 && (census tinyClean { depth := some 2 }).runs == 4 },
    { name := "a per-name cap: c's first two options, 8 timelines, the bad path (c = 2) left out",
      ok := capped.runs == 8 && capped.violations == 0 },
    { name := "deepening counts each timeline once, shallowest first: 1, 1, 2, 8",
      ok := (deepen tinyClean 3).toList.map (·.counted) == [1, 1, 2, 8] },
    { name := "deepening finds the bad path at depth 3, not before",
      ok := (deepen tinyRun 3).toList.map (·.violations) == [0, 0, 0, 1] },
    { name := "Knuth's estimate of a uniform tree is exact: 12",
      ok := (size tinyClean).mean == 12.0 && (size tinyClean).max == 12 },
    { name := "Knuth's estimate within a depth cap: 4", ok := (size tinyClean { depth := some 2 }).mean == 4.0 },
    { name := "Knuth's estimate of an uneven tree (4 timelines) is near 4",
      ok := let z := size unevenRun (probes := 400); z.mean > 3.5 && z.mean < 4.5 && z.max == 6 },
    { name := "random draws keep within a per-name cap",
      ok := (List.range 50).all fun i =>
        (tinyRun { gen := mkStdGen (mixSeed i), bounds := { perName := [("c", 1)] } }).taken[2]!.value == 0 } ]

def locks : List Check :=
  let complete (r : Exhausted) := match r with | .complete _ => true | _ => false
  let deadlock (r : Exhausted) := match r with | .found c => c.property == "deadlock" | _ => false
  let opposite := #[[Locks.Act.lockA, .lockB, .unlockB, .unlockA], [.lockB, .lockA, .unlockA, .unlockB]]
  let same := #[[Locks.Act.lockA, .lockB, .unlockB, .unlockA], [.lockA, .lockB, .unlockB, .unlockA]]
  let lastRelease := #[[Locks.Act.lockA, .unlockA], [.lockA, .unlockA]]
  let reread := #[[Locks.Act.rlock, .rlock, .runlock, .runlock], [.announce, .wlock, .wunlock]]
  [ { name := "two mutexes taken in opposite orders deadlock", ok := deadlock (exhaust (Locks.run opposite true) 10000) },
    { name := "taken in the same order: every interleaving ends", ok := complete (exhaust (Locks.run same true) 10000) },
    { name := "a lock released in a thread's last step frees its waiter", ok := complete (exhaust (Locks.run lastRelease true) 10000) },
    { name := "writer priority: a reader taking it again behind a waiting writer deadlocks",
      ok := deadlock (exhaust (Locks.run reread true) 10000) },
    { name := "reader priority: the same never deadlocks", ok := complete (exhaust (Locks.run reread false) 10000) } ]

def toyConfig (syncErrors : Bool) : Config :=
  { nodes := 3, steps := 40, recovery := 40, clientOps := 6,
    faults := { syncErrors, skew := false } }

/-- Kills and evictions, failed syncs, no power loss at all. -/
def noPowerLoss : Config :=
  { nodes := 3, steps := 40, recovery := 40, clientOps := 6,
    faults := { syncErrors := true, skew := false, crash := false, crashPoints := false, swarm := false } }

def small (syncErrors : Bool) : Config :=
  { nodes := 1, steps := 5, recovery := 3, clientOps := 2,
    faults := { syncErrors, skew := false, partition := false, drop := false, duplicate := false,
                kill := false, swarm := false, crashPoints := false, evict := false } }

/-- A smaller world with crash points at every disk operation and evictions. -/
def smallCrashPoints : Config :=
  { nodes := 1, steps := 3, recovery := 3, clientOps := 2,
    faults := { syncErrors := false, skew := false, partition := false, drop := false, duplicate := false,
                kill := false, swarm := false, crashPointOneIn := 2 } }

/-- The toy register judged only by how many started nodes are down at once. -/
def toyBound : Properties Toy.sys where
  invariant c :=
    let d := ((List.range c.nodes.size).filter fun n => (c.node n).starts > 0 && !c.up n).length
    if d > c.config.nodesDownMax then some s!"{d} nodes down at once" else none

/-- Kills and frequent crash points, at most one node down. -/
def toyDown : Config :=
  { nodes := 3, steps := 40, recovery := 20, clientOps := 6, nodesDownMax := 1,
    faults := { skew := false, swarm := false, crashPointOneIn := 3 } }

def describe (c : Counterexample) : String :=
  s!"{c.property} after {c.runs} timelines, {c.taken.size} decisions: {c.detail}"

def main : IO UInt32 := do
  let mut failed := 0
  for c in decisions ++ censusChecks ++ shrinkChecks ++ disk ++ history ++ locks do
    IO.println s!"{if c.ok then "ok  " else "FAIL"} {c.name}"
    if !c.ok then failed := failed + 1
  -- The toy register, end to end.
  let cases : List (String × Toy.Variant × Bool × Bool) := [
    ("acknowledging before the sync is found", .ackBeforeSync, false, true),
    ("ignoring a failed sync is found", .ignoreSyncError, true, true),
    ("the correct register: nothing found (power losses)", .correct, false, false),
    ("the correct register: nothing found (failed syncs)", .correct, true, false) ]
  for (name, variant, syncErrors, expectFound) in cases do
    let run := Toy.run variant (toyConfig syncErrors)
    let found := explore run 3000
    let ok := found.isSome == expectFound
    IO.println s!"{if ok then "ok  " else "FAIL"} {name}: {match found with | some c => describe c | none => "none in 3000 timelines"}"
    if !ok then failed := failed + 1
    if let some c := found then
      let short := shrink run c
      IO.println s!"       shrunk to {short.taken.size} decisions; its story:"
      for line in Toy.runLog variant (toyConfig syncErrors) (Source.path short.values) do
        IO.println s!"         {line}"
  -- A failed sync's entry served after a restart, then evicted: no power loss needed.
  for (name, variant, evict, expectFound) in [
      ("halting without writing the log again is found by kills and eviction alone", Toy.Variant.haltNoCopy, true, true),
      ("without eviction, kills alone never expose it (the entry stays in the cache)", Toy.Variant.haltNoCopy, false, false),
      ("the correct register: nothing found by kills and eviction", Toy.Variant.correct, true, false) ] do
    let config := { noPowerLoss with faults := { noPowerLoss.faults with evict } }
    let found := explore (Toy.run variant config) 3000
    let ok := found.isSome == expectFound
    IO.println s!"{if ok then "ok  " else "FAIL"} {name}: {match found with | some c => describe c | none => "none in 3000 timelines"}"
    if !ok then failed := failed + 1
  -- Crash points and nodesDownMax: a node's own start is eligible, nodes not yet booted are not
  -- down, and crash points never take more than nodesDownMax down.
  let seen (name : String) (seek : String) : IO Bool := do
    let found := explore (Boot.run false (some seek) Boot.config) 3000
    let ok := match found with | some c => c.detail.startsWith "seen" | none => false
    IO.println s!"{if ok then "ok  " else "FAIL"} {name}: {match found with | some c => describe c | none => "none in 3000 timelines"}"
    pure ok
  unless ← seen "a crash point fires in a node's first boot, the others not yet booted"
      "node 1 lost power during its first start" do failed := failed + 1
  unless ← seen "a crash point fires inside a restart" "lost power during its start" do failed := failed + 1
  for (name, found) in [
      ("crash points in starts never take more than nodesDownMax down", explore (Boot.run true none Boot.config) 3000),
      ("crash points in a node's code never take more than nodesDownMax down",
        explore (fun src => let r := runCluster (Toy.behavior .correct) toyBound toyDown src
                            { taken := r.taken, violation := r.violation }) 3000) ] do
    IO.println s!"{if found.isNone then "ok  " else "FAIL"} {name}: {match found with | some c => describe c | none => "none in 3000 timelines"}"
    if found.isSome then failed := failed + 1
  -- Exhaustive, on a small world.
  for (name, variant, syncErrors, expectFound) in [
      ("exhaustive: acknowledging before the sync is found", Toy.Variant.ackBeforeSync, false, true),
      ("exhaustive: the correct register, every timeline", Toy.Variant.correct, true, false),
      ("exhaustive, crash points and evictions: the correct register, every timeline", Toy.Variant.correct, false, false) ] do
    let config := if name.startsWith "exhaustive, crash points" then smallCrashPoints else small syncErrors
    let result := exhaust (Toy.run variant config) 500000
    let (ok, said) := match result with
      | .found c => (expectFound, s!"found after {c.runs} timelines: {c.detail}")
      | .complete n => (!expectFound, s!"complete: {n} timelines, none broke")
      | .stopped n => (false, s!"stopped at {n} timelines")
    IO.println s!"{if ok then "ok  " else "FAIL"} {name}: {said}"
    if !ok then failed := failed + 1
  IO.println s!"{failed} failed"
  return if failed == 0 then 0 else 1

end DeterminismoTests

def main : IO UInt32 := DeterminismoTests.main
