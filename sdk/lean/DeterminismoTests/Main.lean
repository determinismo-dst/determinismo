import Determinismo
import DeterminismoTests.Toy
import DeterminismoTests.Locks

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

def tinyClean (source : Source) : Ended := { tinyRun source with violation := none }

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
      ok := ((f1.write (.replace [7, 8, 9])).crash 0 2).cache == [7, 8] } ]

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
    { name := "a weighted draw stays in range",
      ok := (List.range 200).all fun i => (drawWeighted (mkStdGen i) [1, 0, 5]).1 ∈ [0, 2] } ]

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

def small (syncErrors : Bool) : Config :=
  { nodes := 1, steps := 5, recovery := 3, clientOps := 2,
    faults := { syncErrors, skew := false, partition := false, drop := false, duplicate := false,
                kill := false, swarm := false } }

def describe (c : Counterexample) : String :=
  s!"{c.property} after {c.runs} timelines, {c.taken.size} decisions: {c.detail}"

def main : IO UInt32 := do
  let mut failed := 0
  for c in decisions ++ disk ++ history ++ locks do
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
  -- Exhaustive, on a small world.
  for (name, variant, syncErrors, expectFound) in [
      ("exhaustive: acknowledging before the sync is found", Toy.Variant.ackBeforeSync, false, true),
      ("exhaustive: the correct register, every timeline", Toy.Variant.correct, true, false) ] do
    let result := exhaust (Toy.run variant (small syncErrors)) 500000
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
