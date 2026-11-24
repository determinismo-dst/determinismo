/-!
# Decisions

Every choice the chaotic world makes is a decision: its name (as determinismo names its own:
`fault.crash`, `net.deliver`, `disk.crash.kept`, ...), how many options it had, and the one
taken. A timeline is its decisions: the same decisions repeat it exactly, as a determinismo tape
repeats a timeline. Values come from a source: a fixed prefix (a tape, a search's path), then a
generator (random exploration) or the first option (exhaustive search extends a path with zeros).

A world's state carries its `Decisions` (the `Chaotic` class); `decide` draws one. A timeline that
breaks a property stops with `Stop.violation`; one past its decision limit stops with
`Stop.limit` (an end, not a failure).
-/

namespace Determinismo

/-- One decision taken: its name, how many options it had, the one taken. -/
structure Taken where
  name : String
  options : Nat
  value : Nat
  deriving Repr, BEq, Inhabited

/-- Where decisions' values come from. -/
structure Source where
  /-- Taken first, in order (a value at or past its decision's options wraps). -/
  given : Array Nat := #[]
  /-- Past `given`: drawn from this generator, else the first option (0). -/
  random : Bool := true
  gen : StdGen := mkStdGen 0

/-- A source drawing every decision at random from `seed`. -/
def Source.seeded (seed : Nat) : Source := { gen := mkStdGen seed }

/-- A source replaying `values`, then taking the first option of every decision after them. -/
def Source.path (values : Array Nat) : Source := { given := values, random := false }

/-- The decisions of one timeline: where they come from and the ones taken so far. -/
structure Decisions where
  source : Source := {}
  taken : Array Taken := #[]
  /-- Decisions a timeline may take before it ends (`Stop.limit`). -/
  limit : Nat := 1000000

/-- Why a timeline stopped before its end. -/
inductive Stop where
  /-- A property broke: its name and what was seen. -/
  | violation (property : String) (detail : String)
  /-- Its decision limit was reached: an end, not a failure. -/
  | limit
  deriving Repr, BEq, Inhabited

/-- A world's state that carries its decisions. -/
class Chaotic (σ : Type) where
  decisions : σ → Decisions
  setDecisions : σ → Decisions → σ

/-- A uniform draw in [0, options) from a generator. -/
def drawUniform (gen : StdGen) (options : Nat) : Nat × StdGen :=
  randNat gen 0 (options - 1)

/-- A draw in [0, weights.length) by weight (all weights 0: uniform). -/
def drawWeighted (gen : StdGen) (weights : List Nat) : Nat × StdGen :=
  let total := weights.foldl (· + ·) 0
  if total == 0 then drawUniform gen weights.length
  else
    let (r, gen') := randNat gen 0 (total - 1)
    let rec pick (ws : List Nat) (index acc : Nat) : Nat :=
      match ws with
      | [] => index - 1
      | w :: rest => if r < acc + w then index else pick rest (index + 1) (acc + w)
    (pick weights 0 0, gen')

/-- The next value of a decision with `weights.length` options (`weights` shape random draws
only: a replayed or searched path takes any option). One option: 0, not recorded. -/
def Decisions.next (d : Decisions) (name : String) (weights : List Nat) : Except Stop (Nat × Decisions) :=
  let options := weights.length
  if options ≤ 1 then .ok (0, d)
  else if d.taken.size ≥ d.limit then .error .limit
  else
    let position := d.taken.size
    let (value, source) :=
      if h : position < d.source.given.size then (d.source.given[position] % options, d.source)
      else if d.source.random then
        let (v, gen) := drawWeighted d.source.gen weights
        (v, { d.source with gen := gen })
      else (0, d.source)
    .ok (value, { d with source := source, taken := d.taken.push { name, options, value } })

variable {σ : Type} [Chaotic σ]

/-- A decision among `weights.length` options, drawn by weight when random. -/
def decideWeighted (name : String) (weights : List Nat) : EStateM Stop σ Nat := do
  let s ← get
  match (Chaotic.decisions s).next name weights with
  | .ok (value, d) => set (Chaotic.setDecisions s d); pure value
  | .error stop => throw stop

/-- A decision among `options` options, uniform when random. -/
def decide (name : String) (options : Nat) : EStateM Stop σ Nat :=
  decideWeighted name (List.replicate options 1)

/-- A yes or no, yes `inOf` times in `of` when random (a rare fault: 1 in 8). -/
def decideRare (name : String) (inOf : Nat) (of : Nat) : EStateM Stop σ Bool := do
  pure ((← decideWeighted name [of - inOf, inOf]) == 1)

/-- One element of a nonempty list, by a decision; `none` for an empty one. -/
def pick {α : Type} (name : String) (items : List α) : EStateM Stop σ (Option α) := do
  match items with
  | [] => pure none
  | first :: _ => pure (some (items.getD (← decide name items.length) first))

/-- A property broken: the timeline stops here. -/
def violate {α : Type} (property : String) (detail : String) : EStateM Stop σ α :=
  throw (.violation property detail)

end Determinismo
