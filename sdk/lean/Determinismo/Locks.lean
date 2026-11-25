import Determinismo.Decide

/-!
# Locks for threads

A step of a `Threads` program takes a lock with a `try`: `some` the lock taken (the step runs),
`none` held by another (the step returns `.blocked` and is retried after another thread's step).
Not reentrant: a thread taking a lock it holds is refused, as a plain mutex deadlocks there.

- `Mutex`: one holder.
- `RwLock`: readers share it, a writer holds it alone. With `writerPriority` (folly's
  `SharedMutex`, glibc's `PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`), a writer that
  `announce`d itself keeps new readers out until it has taken and released the lock: a reader
  already holding it that asks again then waits behind the writer, the deadlock such locks are
  known for.
- `Condvar`: a wait is two steps, `enter` (the thread joins the waiters and releases its mutex)
  then `tryWake` (blocked until notified and the mutex is free, then holding it again; a
  spurious wakeup is a decision, `wakeSpuriously`). `notifyOne` wakes a waiter chosen by a
  decision, `notifyAll` every one; a notify with nobody waiting is lost, as in the real thing.
-/

namespace Determinismo

structure Mutex where
  holder : Option Nat := none
  deriving Repr, BEq

namespace Mutex

def tryLock (m : Mutex) (t : Nat) : Option Mutex :=
  match m.holder with
  | none => some { holder := some t }
  | some _ => none

def unlock (_ : Mutex) : Mutex := {}

end Mutex

structure RwLock where
  readers : List Nat := []
  writer : Option Nat := none
  /-- Writers waiting (announced), ahead of new readers when `writerPriority`. -/
  waiting : List Nat := []
  writerPriority : Bool := true
  deriving Repr, BEq

namespace RwLock

/-- Shared: no writer holds it, and (writer priority) none waits. -/
def tryLockShared (l : RwLock) (t : Nat) : Option RwLock :=
  if l.writer.isSome then none
  else if l.writerPriority && !l.waiting.isEmpty then none
  else some { l with readers := t :: l.readers }

def unlockShared (l : RwLock) (t : Nat) : RwLock :=
  { l with readers := l.readers.erase t }

/-- A writer says it waits (a step of its own: then readers queue behind it). -/
def announce (l : RwLock) (t : Nat) : RwLock :=
  if l.waiting.contains t then l else { l with waiting := l.waiting ++ [t] }

/-- Exclusive: no reader and no writer holds it. -/
def tryLock (l : RwLock) (t : Nat) : Option RwLock :=
  if l.writer.isSome || !l.readers.isEmpty then none
  else some { l with writer := some t, waiting := l.waiting.erase t }

def unlock (l : RwLock) : RwLock := { l with writer := none }

end RwLock

structure Condvar where
  /-- Threads waiting, in the order they began to. -/
  waiting : List Nat := []
  /-- Threads notified, not yet holding the mutex again. -/
  notified : List Nat := []
  deriving Repr, BEq

namespace Condvar

/-- Thread `t` begins to wait (its step also releases the mutex it held). -/
def enter (c : Condvar) (t : Nat) : Condvar :=
  if c.waiting.contains t then c else { c with waiting := c.waiting ++ [t] }

/-- Thread `t` wakes if it was notified and `m` is free: both updated, `t` holding `m`. -/
def tryWake (c : Condvar) (m : Mutex) (t : Nat) : Option (Condvar × Mutex) :=
  if c.notified.contains t then
    (m.tryLock t).map fun m' => ({ c with notified := c.notified.erase t }, m')
  else none

/-- Waiter number `i` (in `waiting`) notified. -/
def notifyAt (c : Condvar) (i : Nat) : Condvar :=
  match c.waiting[i]? with
  | some t => { waiting := c.waiting.erase t, notified := c.notified ++ [t] }
  | none => c

def notifyAll (c : Condvar) : Condvar := { waiting := [], notified := c.notified ++ c.waiting }

/-- A spurious wakeup of `t`, as if notified (POSIX allows it: a waiter must check again). -/
def spurious (c : Condvar) (t : Nat) : Condvar :=
  if c.waiting.contains t then { waiting := c.waiting.erase t, notified := c.notified ++ [t] } else c

end Condvar

variable {σ : Type} [Chaotic σ]

/-- One waiter notified, which one decided (`name`); nobody waiting: the notify is lost. -/
def notifyOne (name : String) (c : Condvar) : EStateM Stop σ Condvar := do
  if c.waiting.isEmpty then pure c
  else pure (c.notifyAt (← decide name c.waiting.length))

/-- Whether waiter `t` wakes spuriously now, `inOf` in `of` when random. -/
def wakeSpuriously (name : String) (c : Condvar) (t : Nat) (inOf : Nat := 1) (of : Nat := 16) :
    EStateM Stop σ Condvar := do
  if c.waiting.contains t && (← decideRare name inOf of) then pure (c.spurious t) else pure c

end Determinismo
