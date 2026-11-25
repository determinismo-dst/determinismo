import Determinismo.Search

/-!
# Census

`exhaust` stops at the first counterexample; a census walks the whole space within its bounds
and counts: timelines run, those breaking no property, and per property its count and first
counterexample. Every replica's rounds built this for themselves (counts per property, a time
budget, progress, resumable segments, depth and per-name caps, a size estimate first).

- `census`: depth first, at most `maxRuns` timelines; `next` says where it stopped (`none`: the
  space is done), so a later call (`censusStep`, or another process, through `pathLine` and
  `pathOfLine`) resumes it;
- `censusIO`: segments until the space is done or a wall-clock budget runs out, a progress
  callback after each;
- `deepen`: iterative deepening, shallow counterexamples first: every timeline branching only in
  its first d decisions, for d = 0, 1, ..., each timeline counted at the first depth reaching it;
- `size`: Knuth's estimate of the space within the bounds, from random probes, before a census
  that would not finish.
-/

namespace Determinismo

/-- A property's count in a census, and its first counterexample. -/
structure PropertyCount where
  property : String
  count : Nat
  first : Counterexample

/-- A census so far. -/
structure Census where
  /-- Timelines run. -/
  runs : Nat := 0
  /-- Timelines counted (`deepen` runs a depth's shallower timelines again, uncounted). -/
  counted : Nat := 0
  /-- Of those counted, the ones that broke no property. -/
  clean : Nat := 0
  byProperty : Array PropertyCount := #[]
  /-- Where the next segment starts; `none`: every timeline within the bounds was run. -/
  next : Option (Array Nat) := some #[]

/-- Timelines counted that broke a property. -/
def Census.violations (c : Census) : Nat := c.byProperty.foldl (· + ·.count) 0

/-- `o` counted. -/
def Census.add (c : Census) (o : Ended) : Census :=
  let c := { c with counted := c.counted + 1 }
  match o.violation with
  | none => { c with clean := c.clean + 1 }
  | some (property, detail) =>
    match c.byProperty.findIdx? (·.property == property) with
    | some i => { c with byProperty := c.byProperty.modify i (fun p => { p with count := p.count + 1 }) }
    | none =>
      let first : Counterexample := { taken := o.taken, property, detail, runs := c.runs }
      { c with byProperty := c.byProperty.push { property, count := 1, first } }

/-- The path after `taken` within `bounds`: its last decision with an option left advanced. -/
def nextPathWithin (bounds : Bounds) (taken : Array Taken) : Option (Array Nat) := Id.run do
  let mut i := taken.size
  while i > 0 do
    i := i - 1
    let t := taken[i]!
    if t.value + 1 < bounds.options i t.name t.options then
      return some ((taken.extract 0 i).map (·.value) |>.push (t.value + 1))
  return none

/-- At most `count` more timelines of `c`, depth first from `c.next`; `fresh` says which to count. -/
def censusStep (run : Source → Ended) (bounds : Bounds) (count : Nat) (c : Census)
    (fresh : Ended → Bool := fun _ => true) : Census := Id.run do
  let mut c := c
  for _ in List.range count do
    match c.next with
    | none => return c
    | some path =>
      let o := run (Source.path path)
      c := { c with runs := c.runs + 1 }
      if fresh o then c := c.add o
      c := { c with next := nextPathWithin bounds o.taken }
  return c

/-- Every timeline within `bounds`, at most `maxRuns`, from `start` (a segment's `next`). -/
def census (run : Source → Ended) (bounds : Bounds := {}) (maxRuns : Nat := 1000000)
    (start : Array Nat := #[]) : Census :=
  censusStep run bounds maxRuns { next := some start }

/-- Segments of `every` timelines until the space is done or `budgetMs` of wall clock ran out
(checked between segments), `progress` after each. Resumes `start`. -/
def censusIO (run : Source → Ended) (bounds : Bounds := {}) (budgetMs : Nat := 1800000)
    (every : Nat := 10000) (start : Census := {}) (progress : Census → IO Unit := fun _ => pure ()) :
    IO Census := do
  let t0 ← IO.monoMsNow
  let mut c := start
  while c.next.isSome do
    c := censusStep run bounds every c
    progress c
    if (← IO.monoMsNow) - t0 ≥ budgetMs then break
  return c

/-- A path as one line of values, to resume a census in another process. -/
def pathLine (path : Array Nat) : String := String.intercalate " " (path.toList.map toString)

def pathOfLine (line : String) : Option (Array Nat) :=
  (line.splitOn " ").filter (· ≠ "") |>.mapM String.toNat? |>.map List.toArray

/-- The census in a few lines: counts, then each property with its first counterexample's tape. -/
def Census.report (c : Census) : String :=
  let head := s!"{c.runs} timelines run, {c.counted} counted: {c.clean} clean, {c.violations} broke a property"
    ++ (match c.next with | none => " (every timeline within the bounds)" | some p => s!" (stopped; resume at [{pathLine p}])")
  String.intercalate "\n" (head :: c.byProperty.toList.map fun p =>
    s!"- {p.property}: {p.count}; first at run {p.first.runs}, {p.first.taken.size} decisions: {p.first.detail}")

/-- Iterative deepening, shallow counterexamples first: for d = 0 to `maxDepth`, every timeline
branching only in its first d decisions (later ones take their first option), within `bounds`,
counting at depth d only the timelines whose decision d - 1 took another option than its first
(the rest were counted at a shallower depth). One census per depth, each of at most `maxRuns`. -/
def deepen (run : Source → Ended) (maxDepth : Nat) (bounds : Bounds := {}) (maxRuns : Nat := 1000000) :
    Array Census := Id.run do
  let mut levels := #[]
  for d in List.range (maxDepth + 1) do
    let capped := { bounds with depth := some (match bounds.depth with | some b => min b d | none => d) }
    let fresh (o : Ended) : Bool := d == 0 || (match o.taken[d - 1]? with | some t => t.value != 0 | none => false)
    levels := levels.push (censusStep run capped maxRuns { next := some #[] } fresh)
  return levels

/-- Knuth's estimate of a space's size. -/
structure Sizing where
  probes : Nat
  /-- The estimate: the mean over probes of each probe's inverse probability. -/
  mean : Float
  /-- The largest single probe's (the estimate's spread: far above the mean, more probes). -/
  max : Nat
  /-- The longest probe, in decisions. -/
  depthMax : Nat

/-- Knuth's estimate of the number of timelines within `bounds`: `probes` timelines drawn
uniformly within them, each the product of its decisions' options (its inverse probability). -/
def size (run : Source → Ended) (bounds : Bounds := {}) (probes : Nat := 100) (seed : Nat := 0) :
    Sizing := Id.run do
  let mut total : Float := 0
  let mut largest := 0
  let mut depthMax := 0
  for i in List.range probes do
    let o := run { gen := mkStdGen (mixSeed (seed + i)), uniform := true, bounds }
    let mut product := 1
    for j in List.range o.taken.size do
      let t := o.taken[j]!
      product := product * bounds.options j t.name t.options
    total := total + product.toFloat
    largest := max largest product
    depthMax := max depthMax o.taken.size
  return { probes, mean := if probes == 0 then 0 else total / probes.toFloat, max := largest, depthMax }

end Determinismo
