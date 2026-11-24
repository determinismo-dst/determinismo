import Determinismo

/-! Threads with locks: scripts of lock actions, every interleaving searched. -/

namespace DeterminismoTests.Locks

open Determinismo

inductive Act where
  | lockA | unlockA | lockB | unlockB | rlock | runlock | announce | wlock | wunlock
  deriving Repr, BEq

structure Mem where
  a : Mutex := {}
  b : Mutex := {}
  rw : RwLock := {}

/-- Each thread runs its script; its locals are its position in it. A step that ends the script
returns `.done` after its action (a release in a thread's last step). -/
def program (scripts : Array (List Act)) : Program Mem Nat where
  step t pc := do
    let script := scripts.getD t []
    let some act := script[pc]? | return .done
    let m := (← get).memory
    let next : Option Mem := match act with
      | .lockA => (m.a.tryLock t).map fun a => { m with a }
      | .unlockA => some { m with a := m.a.unlock }
      | .lockB => (m.b.tryLock t).map fun b => { m with b }
      | .unlockB => some { m with b := m.b.unlock }
      | .rlock => (m.rw.tryLockShared t).map fun rw => { m with rw }
      | .runlock => some { m with rw := m.rw.unlockShared t }
      | .announce => some { m with rw := m.rw.announce t }
      | .wlock => (m.rw.tryLock t).map fun rw => { m with rw }
      | .wunlock => some { m with rw := m.rw.unlock }
    match next with
    | none => return .blocked
    | some m' =>
      modify fun p => { p with memory := m' }
      Process.note (M := Mem) (L := Nat) s!"thread {t}: {reprStr act}"
      return if pc + 1 == script.length then .done else .ran (pc + 1)

def run (scripts : Array (List Act)) (writerPriority : Bool := true) (source : Source) : Ended :=
  let start : Process Mem Nat :=
    { memory := { rw := { writerPriority } }, threads := scripts.map fun _ => some 0 }
  let (result, p) := runProcess start (interleave (program scripts) 100) source
  match result with
  | .ok _ => { taken := p.decisions.taken, violation := none }
  | .error (.violation property detail) => { taken := p.decisions.taken, violation := some (property, detail) }
  | .error .limit => { taken := p.decisions.taken, violation := none }

end DeterminismoTests.Locks
