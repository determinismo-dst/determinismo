import Determinismo.Decide

/-!
# Threads in one process

A process's threads share its memory; each runs its code as steps, each step atomic (a load, a
store, a compare-and-set, a lock's acquisition: the granularity the real code's atomics and locks
give). Which thread steps next is a decision (`thread.next`), as determinismo's interleave and
thread-pause faults choose it in the real process, so a search reaches every interleaving within
its bounds. A step can also block (a lock held, a queue empty): the thread waits until a step of
another changes the memory. A process kill (`thread.kill`, when `kills` is on) ends every thread
at once; what survives is what the program kept in `durable`.

Threads come and go: a step may `spawn` one (it steps from the next decision on), wait for one to
end (`finished`, a join), ask one to stop (`cancel`, seen at its next `cancelRequested`), or end
one where it stands (`stop`). `Process.note` writes the process's story, step by step.
-/

namespace Determinismo

/-- What a thread's step did. -/
inductive StepResult (L : Type) where
  /-- It ran: the thread's next locals. -/
  | ran (locals : L)
  /-- It cannot run now (a lock held, nothing to take): retried after another thread's step. -/
  | blocked
  /-- The thread is over. -/
  | done

/-- The threads' world: their shared memory, each thread's locals, the decisions. -/
structure Process (M L : Type) where
  decisions : Decisions := {}
  memory : M
  threads : Array (Option L)
  /-- Steps so far. -/
  steps : Nat := 0
  log : Array String := #[]
  /-- Threads asked to stop (`cancel`): each sees it at its next check (`cancelRequested`). -/
  cancelled : List Nat := []

instance {M L : Type} : Chaotic (Process M L) where
  decisions p := p.decisions
  setDecisions p d := { p with decisions := d }

abbrev ProcessM (M L : Type) := EStateM Stop (Process M L)

/-- A line of the process's story (`Process.log`), stamped with its step. -/
def Process.note {M L : Type} (line : String) : ProcessM M L Unit :=
  modify fun p => { p with log := p.log.push s!"{p.steps}: {line}" }

/-- A new thread with `locals`, stepping from the next interleaving decision on: its index. -/
def Process.spawn {M L : Type} (locals : L) : ProcessM M L Nat := do
  let p ← get
  set { p with threads := p.threads.push (some locals) }
  pure p.threads.size

/-- Whether thread `t` is over (its last step done, or stopped). A step joining `t` returns
`.blocked` until it is. -/
def Process.finished {M L : Type} (p : Process M L) (t : Nat) : Bool := (p.threads.getD t none).isNone

/-- Asks thread `t` to stop: cooperative, as Java's interrupt or a cancellation point, seen when
`t` next checks `cancelRequested`. -/
def Process.cancel {M L : Type} (t : Nat) : ProcessM M L Unit :=
  modify fun p => { p with cancelled := if p.cancelled.contains t then p.cancelled else t :: p.cancelled }

def Process.cancelRequested {M L : Type} (p : Process M L) (t : Nat) : Bool := p.cancelled.contains t

/-- Ends thread `t` where it stands (an asynchronous cancellation: whatever it held stays held). -/
def Process.stop {M L : Type} (t : Nat) : ProcessM M L Unit :=
  modify fun p => { p with threads := p.threads.set! t none }

/-- A program: a thread's step on the shared memory (it may decide: a thread's own randomness). -/
structure Program (M L : Type) where
  step : Nat → L → ProcessM M L (StepResult L)

/-- Runs every thread to its end (or `maxSteps`): which one steps next decided each time. A
deadlock (every live thread blocked) is reported to `stuck`. -/
def interleave {M L : Type} (prog : Program M L) (maxSteps : Nat)
    (stuck : Process M L → Option String := fun _ => some "every live thread blocked") :
    ProcessM M L Unit := do
  let mut blocked : List Nat := []
  for _ in List.range maxSteps do
    let p ← get
    let live := (List.range p.threads.size).filter fun i => (p.threads.getD i none).isSome
    if live.isEmpty then return
    let ready := live.filter (!blocked.contains ·)
    if ready.isEmpty then
      if let some detail := stuck p then throw (.violation "deadlock" detail)
      return
    let some t ← pick (σ := Process M L) "thread.next" ready | return
    let some locals := p.threads.getD t none | return
    match ← prog.step t locals with
    | .ran locals' =>
      modify fun p => { p with threads := p.threads.set! t (some locals'), steps := p.steps + 1 }
      -- A step that ran may unblock the others (approximated: any step).
      blocked := []
    | .blocked => blocked := t :: blocked
    | .done =>
      modify fun p => { p with threads := p.threads.set! t none, steps := p.steps + 1 }
      -- A thread's last step may release what the others wait for (a lock's unlock).
      blocked := []

/-- Runs a process from a source of decisions: how it ended. -/
def runProcess {M L : Type} (start : Process M L) (body : ProcessM M L Unit) (source : Source)
    (limit : Nat := 100000) : Except Stop Unit × Process M L :=
  let p := { start with decisions := { source, limit } }
  match body.run p with
  | .ok _ p => (.ok (), p)
  | .error e p => (.error e, p)

end Determinismo
