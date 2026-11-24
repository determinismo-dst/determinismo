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

end Determinismo
