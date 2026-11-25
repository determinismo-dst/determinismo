/-!
# A node's disk

A file is what its disk holds (`disk`), what reads see (`cache`, the page cache), and the writes
since its last sync (`pending`, in order). Writes change the cache at once and reach the disk at a
sync. What a fault leaves:

- a power loss (`crash`): a prefix of the pending writes reached the disk, the next one maybe in
  part (a torn write), the rest lost; the cache is then what the disk holds;
- a process kill: nothing (the kernel keeps the cache and writes it back): the node starts again
  with every write;
- a failed sync (EIO, `syncFailed`): each pending write reached the disk or not, and none is
  written again (Linux marks the pages clean); reads still see them until a power loss.

The records are the system's own (a WAL's entries, a snapshot, a hard state).
-/

namespace Determinismo

/-- A write to a file. -/
inductive Write (R : Type) where
  /-- Records added at its end. -/
  | append (records : List R)
  /-- The whole file rewritten in place (not atomic: a power loss can leave part of it). -/
  | replace (records : List R)
  /-- Cut to its first `length` records. -/
  | truncate (length : Nat)
  deriving Repr, BEq

namespace Write

variable {R : Type}

def apply : Write R → List R → List R
  | .append records, content => content ++ records
  | .replace records, _ => records
  | .truncate length, content => content.take length

/-- How many records of it can reach a disk on their own (a torn write keeps fewer). -/
def size : Write R → Nat
  | .append records => records.length
  | .replace records => records.length
  | .truncate _ => 0

/-- The same write applied only partly, its first `kept` records: a write a power loss cut short
while the kernel was copying it (the write call never returned). -/
def cutShort (kept : Nat) : Write R → Write R
  | .append records => .append (records.take kept)
  | .replace records => .replace (records.take kept)
  | .truncate length => .truncate length

/-- Its first `kept` records on the disk, the rest lost: an append cut short, or a rewrite whose
truncation reached the disk with part of the new content. -/
def torn (kept : Nat) : Write R → List R → List R
  | .append records, content => content ++ records.take kept
  | .replace records, _ => records.take kept
  | .truncate length, content => content.take length

end Write

/-- One file of a node. -/
structure File (R : Type) where
  disk : List R := []
  cache : List R := []
  pending : List (Write R) := []
  deriving Repr

namespace File

variable {R : Type}

/-- The pending writes applied to `content`, in order. -/
def applyAll (writes : List (Write R)) (content : List R) : List R :=
  writes.foldl (fun c w => w.apply c) content

/-- A write: seen at once, on the disk at the next sync. -/
def write (f : File R) (w : Write R) : File R :=
  { f with cache := w.apply f.cache, pending := f.pending ++ [w] }

/-- A sync that succeeded: every pending write on the disk. -/
def syncOk (f : File R) : File R :=
  { f with disk := applyAll f.pending f.disk, pending := [] }

/-- The writes whose Bool is true (missing Bools: false). -/
def keptOf (writes : List (Write R)) (reached : List Bool) : List (Write R) :=
  match writes, reached with
  | [], _ => []
  | w :: ws, r :: rs => if r then w :: keptOf ws rs else keptOf ws rs
  | _ :: ws, [] => keptOf ws []

theorem keptOf_all (ws : List (Write R)) : keptOf ws (List.replicate ws.length true) = ws := by
  induction ws with
  | nil => simp [keptOf]
  | cons w ws ih => simp [keptOf, List.replicate_succ, ih]

/-- A sync that failed: the writes `reached` (one Bool each, in order) are on the disk, the others
never will be; none is pending any more; the cache still shows them all. -/
def syncFailed (f : File R) (reached : List Bool) : File R :=
  { f with disk := applyAll (keptOf f.pending reached) f.disk, pending := [] }

/-- A power loss: the first `kept` pending writes reached the disk, then `torn` records of the
next (0: none of it), the rest lost. After it reads see the disk. -/
def crash (f : File R) (kept : Nat) (torn : Nat) : File R :=
  let whole := applyAll (f.pending.take kept) f.disk
  let disk := match f.pending.drop kept with
    | next :: _ => if torn > 0 then next.torn torn whole else whole
    | [] => whole
  { disk := disk, cache := disk, pending := [] }

/-- A power loss where the writeback went in any order: each pending write reached the disk or
not (`reached`, one Bool each), whole; what is not on the disk is lost. -/
def crashAny (f : File R) (reached : List Bool) : File R :=
  let disk := applyAll (keptOf f.pending reached) f.disk
  { disk := disk, cache := disk, pending := [] }

/-- Memory pressure: the clean pages leave the cache, so reads see the disk and the writes still
pending. A failed sync's writes were marked clean though never written: they are gone now, with
no power loss (the second half of the path a failed sync opens). -/
def evict (f : File R) : File R :=
  { f with cache := applyAll f.pending f.disk }

/-- Nothing lost: the pending writes on the disk would give what reads see (no failed sync since
the last power loss). -/
def Consistent (f : File R) : Prop := applyAll f.pending f.disk = f.cache

theorem applyAll_append (ws vs : List (Write R)) (c : List R) :
    applyAll (ws ++ vs) c = applyAll vs (applyAll ws c) := by
  simp [applyAll, List.foldl_append]

/-- Writing keeps a consistent file consistent. -/
theorem write_consistent (f : File R) (w : Write R) (h : f.Consistent) : (f.write w).Consistent := by
  unfold Consistent at *
  simp only [write, applyAll_append]
  rw [h]
  simp [applyAll]

/-- What a successful sync wrote survives any power loss right after it. -/
theorem crash_after_sync (f : File R) (h : f.Consistent) (kept torn : Nat) :
    ((f.syncOk).crash kept torn).cache = f.cache := by
  simp [crash, syncOk, applyAll, Consistent] at *
  exact h

/-- Eviction changes nothing a read sees while no failed sync left pages that never reached the
disk. -/
theorem evict_consistent (f : File R) (h : f.Consistent) : (f.evict).cache = f.cache := by
  simp [evict, Consistent] at *
  exact h

/-- A power loss where every pending write reached the disk is a sync's. -/
theorem crashAny_all (f : File R) :
    (f.crashAny (List.replicate f.pending.length true)).disk = (f.syncOk).disk := by
  simp [crashAny, syncOk, keptOf_all]

/-- A power loss with nothing pending loses nothing. -/
theorem crash_synced (f : File R) (h : f.pending = []) (kept torn : Nat) :
    (f.crash kept torn).disk = f.disk := by
  simp [crash, h, applyAll]

end File

/-- A node's files by name (a missing one is empty). -/
abbrev Files (R : Type) := List (String × File R)

namespace Files

variable {R : Type}

def get (fs : Files R) (name : String) : File R :=
  (fs.lookup name).getD {}

def set (fs : Files R) (name : String) (f : File R) : Files R :=
  (name, f) :: fs.filter (·.1 != name)

end Files

end Determinismo
