import Determinismo.Decide

/-!
# Search

A timeline is a function of its decisions, so the world is searched as determinismo searches the
real system, at the model's scale:

- `explore`: timelines from seeds, every decision drawn at random (swarm testing in the world);
- `exhaust`: every timeline within the world's bounds, depth first: a timeline's decisions
  replayed up to the last one with an option left, that one advanced, the rest first options;
- `shrink`: a counterexample made shorter and plainer (values to 0, a shorter prefix) while it
  still breaks the same property.

A counterexample is its decisions: `tape` prints them as determinismo's named decisions.
-/

namespace Determinismo

/-- One timeline's result, whatever the world: its decisions and the property broken. -/
structure Ended where
  taken : Array Taken
  violation : Option (String × String)

/-- A counterexample: the timeline's decisions and what it broke. -/
structure Counterexample where
  taken : Array Taken
  property : String
  detail : String
  /-- Timelines run to find it. -/
  runs : Nat

def Counterexample.values (c : Counterexample) : Array Nat := c.taken.map (·.value)

/-- The decisions as determinismo's tape lines: one JSON object each. -/
def tape (taken : Array Taken) : String :=
  String.intercalate "\n" (taken.toList.map fun t =>
    s!"\{\"name\":\"{t.name}\",\"options\":{t.options},\"value\":{t.value}}")

/-- Timelines from seeds `first` to `first + count - 1`; the first counterexample. -/
def explore (run : Source → Ended) (count : Nat) (first : Nat := 0) : Option Counterexample := Id.run do
  for i in List.range count do
    let o := run (Source.seeded (first + i))
    if let some (property, detail) := o.violation then
      return some { taken := o.taken, property, detail, runs := i + 1 }
  return none

/-- How an exhaustive search ended. -/
inductive Exhausted where
  | found (c : Counterexample)
  /-- Every timeline within the bounds: none broke a property. -/
  | complete (runs : Nat)
  /-- Stopped at `runs` timelines, some left. -/
  | stopped (runs : Nat)

/-- The path after `taken`: its last decision with an option left advanced, those after it dropped. -/
def nextPath (taken : Array Taken) : Option (Array Nat) := Id.run do
  let mut i := taken.size
  while i > 0 do
    i := i - 1
    let t := taken[i]!
    if t.value + 1 < t.options then
      return some ((taken.extract 0 i).map (·.value) |>.push (t.value + 1))
  return none

/-- Every timeline, depth first, up to `maxRuns`. -/
def exhaust (run : Source → Ended) (maxRuns : Nat) : Exhausted := Id.run do
  let mut path : Array Nat := #[]
  for i in List.range maxRuns do
    let o := run (Source.path path)
    if let some (property, detail) := o.violation then
      return .found { taken := o.taken, property, detail, runs := i + 1 }
    match nextPath o.taken with
    | none => return .complete (i + 1)
    | some p => path := p
  return .stopped maxRuns

/-- A shorter, plainer counterexample breaking the same property: values set to 0, the path cut
shorter (first options after it), as long as it still breaks; at most `tries` timelines. -/
def shrink (run : Source → Ended) (c : Counterexample) (tries : Nat := 2000) : Counterexample := Id.run do
  let mut best := c
  let mut budget := tries
  let mut improved := true
  while improved && budget > 0 do
    improved := false
    -- A shorter path: the first half, then the first three quarters, ...
    let mut cut := best.taken.size / 2
    while cut > 0 && cut < best.taken.size && budget > 0 do
      budget := budget - 1
      let o := run (Source.path (best.values.extract 0 cut))
      if let some (property, detail) := o.violation then
        if property == c.property && o.taken.size < best.taken.size then
          best := { best with taken := o.taken, detail }
          improved := true
          break
      cut := cut + (best.taken.size - cut + 1) / 2
    -- Plainer values: each one to 0.
    let mut i := 0
    while i < best.taken.size && budget > 0 do
      if best.taken[i]!.value != 0 then
        budget := budget - 1
        let o := run (Source.path (best.values.set! i 0))
        if let some (property, detail) := o.violation then
          if property == c.property && o.taken.size ≤ best.taken.size then
            best := { best with taken := o.taken, detail }
            improved := true
      i := i + 1
  return best

end Determinismo
