import Determinismo

/-! Condition variables, spawning, joining and cancelling, every interleaving searched. -/

namespace DeterminismoTests.Sync

open Determinismo

structure Mem where
  m : Mutex := {}
  cv : Condvar := {}
  ready : Bool := false
  counter : Nat := 0
  worker : Nat := 0

abbrev P := ProcessM Mem Nat

def setMem (f : Mem → Mem) : P Unit := modify fun p => { p with memory := f p.memory }

/-- Thread 0 waits for `ready` (`recheck`: in a loop, as POSIX requires; else once, an `if`);
thread 1 sets it, holding the mutex or not (`locked`), and notifies. -/
def waitProgram (locked recheck spurious : Bool) : Program Mem Nat where
  step t pc := do
    let mem := (← get).memory
    if t == 0 then
      match pc with
      | 0 => match mem.m.tryLock t with
        | some m => setMem ({ · with m }); pure (.ran 1)
        | none => pure .blocked
      | 1 => pure (.ran (if mem.ready then 4 else 2))
      | 2 => setMem fun x => { x with cv := x.cv.enter t, m := x.m.unlock }; pure (.ran 3)
      | 3 =>
        let cv ← if spurious then wakeSpuriously (σ := Process Mem Nat) "cv.spurious" mem.cv t else pure mem.cv
        setMem ({ · with cv })
        match cv.tryWake mem.m t with
        | some (cv, m) => setMem ({ · with cv, m }); pure (.ran (if recheck then 1 else 4))
        | none => pure .blocked
      | _ =>
        if !mem.ready then violate (σ := Process Mem Nat) "woke before ready" "the waiter went on with ready false"
        setMem fun x => { x with m := x.m.unlock }; pure .done
    else
      if locked then
        match pc with
        | 0 => match mem.m.tryLock t with
          | some m => setMem ({ · with m }); pure (.ran 1)
          | none => pure .blocked
        | 1 => setMem ({ · with ready := true }); pure (.ran 2)
        | 2 => let cv ← notifyOne (σ := Process Mem Nat) "cv.notify" mem.cv; setMem ({ · with cv }); pure (.ran 3)
        | _ => setMem fun x => { x with m := x.m.unlock }; pure .done
      else
        match pc with
        | 0 => setMem ({ · with ready := true }); pure (.ran 1)
        | _ => let cv ← notifyOne (σ := Process Mem Nat) "cv.notify" mem.cv; setMem ({ · with cv }); pure .done

/-- Thread 0 spawns a worker that counts once (`join`: waits for it) and reads the count; with
`loop`, the worker counts until cancelled and thread 0 cancels it before joining. -/
def spawnProgram (join loop : Bool) : Program Mem Nat where
  step t pc := do
    let p ← get
    if pc ≥ 100 then
      if loop then
        if p.cancelRequested t then pure .done
        else setMem (fun x => { x with counter := x.counter + 1 }); pure (.ran 100)
      else setMem (fun x => { x with counter := x.counter + 1 }); pure .done
    else
      match pc with
      | 0 => let w ← Process.spawn (M := Mem) 100; setMem ({ · with worker := w }); pure (.ran 1)
      | 1 => if loop then Process.cancel (M := Mem) (L := Nat) p.memory.worker; pure (.ran 2) else pure (.ran 2)
      | 2 => if join && !p.finished p.memory.worker then pure .blocked else pure (.ran 3)
      | _ =>
        if !loop && p.memory.counter != 1 then violate (σ := Process Mem Nat) "read before the worker ran" s!"counter {p.memory.counter}"
        pure .done

def run (prog : Program Mem Nat) (threads : Nat) (source : Source) (maxSteps : Nat := 60) : Ended × Process Mem Nat :=
  let start : Process Mem Nat := { memory := {}, threads := (List.replicate threads (some 0)).toArray }
  let (result, p) := runProcess start (interleave prog maxSteps) source
  let violation := match result with
    | .error (.violation property detail) => some (property, detail)
    | _ => none
  ({ taken := p.decisions.taken, violation }, p)

def found (r : Exhausted) (property : String) : Bool :=
  match r with | .found c => c.property == property | _ => false

def complete (r : Exhausted) : Bool := match r with | .complete _ => true | _ => false

end DeterminismoTests.Sync
