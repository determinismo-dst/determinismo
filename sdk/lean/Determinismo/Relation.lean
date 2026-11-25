/-!
# Relations

The transitive closure (`Plus`) and the reflexive-transitive closure (`Star`) of a relation, with
what proofs about dependency graphs need of them: built from steps at either end, joined,
mapped along a stronger relation. A replica's graphs (a dependency graph's paths, a chain of
writers) are stated in them; Lean's core library has neither.
-/

namespace Determinismo.Relation

variable {α : Type} {r s : α → α → Prop}

/-- `a` reaches `b` in one step or more. -/
inductive Plus (r : α → α → Prop) : α → α → Prop where
  | single {a b : α} : r a b → Plus r a b
  | tail {a b c : α} : Plus r a b → r b c → Plus r a c

/-- `a` reaches `b` in zero steps or more. -/
inductive Star (r : α → α → Prop) : α → α → Prop where
  | refl {a : α} : Star r a a
  | tail {a b c : α} : Star r a b → r b c → Star r a c

theorem Star.single {a b : α} (h : r a b) : Star r a b := .tail .refl h

theorem Star.trans {a b c : α} (h₁ : Star r a b) (h₂ : Star r b c) : Star r a c := by
  induction h₂ with
  | refl => exact h₁
  | tail _ hs ih => exact .tail ih hs

theorem Star.head {a b c : α} (h₁ : r a b) (h₂ : Star r b c) : Star r a c :=
  Star.trans (Star.single h₁) h₂

theorem Plus.toStar {a b : α} (h : Plus r a b) : Star r a b := by
  induction h with
  | single hs => exact Star.single hs
  | tail _ hs ih => exact .tail ih hs

/-- A path of zero steps or more, then one: one step or more. -/
theorem Plus.of_star_tail {a b c : α} (h₁ : Star r a b) (h₂ : r b c) : Plus r a c := by
  induction h₁ generalizing c with
  | refl => exact .single h₂
  | tail _ hs ih => exact .tail (ih hs) h₂

theorem Plus.trans {a b c : α} (h₁ : Plus r a b) (h₂ : Plus r b c) : Plus r a c := by
  induction h₂ with
  | single hs => exact .tail h₁ hs
  | tail _ hs ih => exact .tail ih hs

theorem Plus.head {a b c : α} (h₁ : r a b) (h₂ : Star r b c) : Plus r a c := by
  induction h₂ with
  | refl => exact .single h₁
  | tail _ hs ih => exact .tail ih hs

/-- One step or more: a first step, then zero or more. -/
theorem Plus.head_star {a c : α} (h : Plus r a c) : ∃ b, r a b ∧ Star r b c := by
  induction h with
  | single hs => exact ⟨_, hs, .refl⟩
  | tail _ hs ih =>
    obtain ⟨b, hab, hbc⟩ := ih
    exact ⟨b, hab, .tail hbc hs⟩

theorem Plus.mono (hm : ∀ a b, r a b → s a b) {a b : α} (h : Plus r a b) : Plus s a b := by
  induction h with
  | single hs => exact .single (hm _ _ hs)
  | tail _ hs ih => exact .tail ih (hm _ _ hs)

theorem Star.mono (hm : ∀ a b, r a b → s a b) {a b : α} (h : Star r a b) : Star s a b := by
  induction h with
  | refl => exact .refl
  | tail _ hs ih => exact .tail ih (hm _ _ hs)

/-- A cycle: a node that reaches itself in one step or more. -/
def Cycle (r : α → α → Prop) (a : α) : Prop := Plus r a a

/-- A cycle through `a` and `b` (each reaching the other) is a cycle at each. -/
theorem Cycle.of_both {a b : α} (h₁ : Plus r a b) (h₂ : Plus r b a) : Cycle r a :=
  Plus.trans h₁ h₂

end Determinismo.Relation
