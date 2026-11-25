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

/-- The part of the decision tree a search walks (a census's, a sizing's): decisions past
`depth` take their first option, and a decision named in `perName` its first k options at most.
Replayed values are never bounded: a tape repeats whatever it holds. -/
structure Bounds where
  /-- Decisions branched on: those at positions before it (none: every one). -/
  depth : Option Nat := none
  /-- At most this many options of each decision with this name (at least one). -/
  perName : List (String × Nat) := []
  deriving Inhabited

/-- How many of a decision's `options` the bounds leave it, at `position` in its timeline. -/
def Bounds.options (b : Bounds) (position : Nat) (name : String) (options : Nat) : Nat :=
  let byDepth := match b.depth with
    | some d => if position < d then options else min options 1
    | none => options
  match b.perName.lookup name with
  | some k => min byDepth (max k 1)
  | none => byDepth

/-- Where decisions' values come from. -/
structure Source where
  /-- Taken first, in order (a value at or past its decision's options wraps). -/
  given : Array Nat := #[]
  /-- Past `given`: drawn from this generator, else the first option (0). -/
  random : Bool := true
  gen : StdGen := mkStdGen 0
  /-- Random draws uniform over the options the bounds leave, weights ignored (Knuth's estimate
  needs each draw's probability). -/
  uniform : Bool := false
  /-- Random draws only among the options these leave (the default: all). -/
  bounds : Bounds := {}

/-- A seed mixed over 64 bits (splitmix64's finalizer). `mkStdGen` of consecutive small seeds
gives the same first draw: over seeds 0 to 2,999, option 1 of 2 and option 2 of 3 every time, so
every explored timeline took the same first decision until the seed was mixed. -/
def mixSeed (seed : Nat) : Nat :=
  let m := 2 ^ 64
  let z := (seed + 0x9E3779B97F4A7C15) % m
  let z := ((z ^^^ (z >>> 30)) * 0xBF58476D1CE4E5B9) % m
  let z := ((z ^^^ (z >>> 27)) * 0x94D049BB133111EB) % m
  z ^^^ (z >>> 31)

/-- A source drawing every decision at random from `seed`. -/
def Source.seeded (seed : Nat) : Source := { gen := mkStdGen (mixSeed seed) }

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
  /-- A node lost power inside its own code (a crash point at a disk operation): its event ends
  there, the node is down, the timeline goes on (`Cluster` catches it). -/
  | nodeDown (node : Nat)
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
        let allowed := weights.take (d.source.bounds.options position name options)
        let (v, gen) :=
          if d.source.uniform then drawUniform d.source.gen allowed.length
          else drawWeighted d.source.gen allowed
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

/-- `x` with decisions that are not the timeline's: drawn from `seed`, never recorded, the
timeline's own decisions untouched (a setup to reach a state, so a search explores only what
comes after it). The same seed repeats the same phase. -/
def unrecorded {α : Type} (seed : Nat) (x : EStateM Stop σ α) : EStateM Stop σ α := do
  let saved := Chaotic.decisions (← get)
  modify fun s => Chaotic.setDecisions s { source := Source.seeded seed, limit := saved.limit }
  try
    let r ← x
    modify fun s => Chaotic.setDecisions s saved
    pure r
  catch e =>
    modify fun s => Chaotic.setDecisions s saved
    throw e

/-- A property broken: the timeline stops here. -/
def violate {α : Type} (property : String) (detail : String) : EStateM Stop σ α :=
  throw (.violation property detail)

/-- Code that decides without knowing its world (a pure module: a tree's map order, an
allocator's choice): written over any `m` with this class, run from a world's monad
(`EStateM Stop σ` for a `Chaotic σ`, a node's `NodeM`) or alone over `Decisions`. -/
class MonadDecide (m : Type → Type) where
  /-- A decision among `weights.length` options, drawn by weight when random. -/
  decideIn : String → List Nat → m Nat

instance {σ : Type} [Chaotic σ] : MonadDecide (EStateM Stop σ) where
  decideIn name weights := decideWeighted (σ := σ) name weights

instance {m : Type → Type} {ρ : Type} [MonadDecide m] : MonadDecide (ReaderT ρ m) where
  decideIn name weights := fun _ => MonadDecide.decideIn name weights

/-- Decisions alone: a world for code that only decides. -/
instance : Chaotic Decisions where
  decisions d := d
  setDecisions _ d := d

end Determinismo
