/-!
# EDN

Cases written for a Clojure system (an Elle history, a Datomic transaction, a jank form) as EDN
text, from a replica's values. JSON needs nothing here: Lean's own `Lean.Json`
(`import Lean.Data.Json`) renders and parses it.
-/

namespace Determinismo

inductive Edn where
  | nil
  | bool (b : Bool)
  | int (i : Int)
  | str (s : String)
  /-- A keyword, without its colon: `kw "db/id"` is `:db/id`. -/
  | kw (name : String)
  | sym (name : String)
  | vec (items : List Edn)
  | list (items : List Edn)
  | set (items : List Edn)
  /-- Entries in the order given (EDN's maps are unordered; a fixed order keeps text stable). -/
  | map (entries : List (Edn × Edn))
  /-- A tagged literal: `tagged "inst" (str "2026-11-25T00:00:00Z")` is `#inst "..."`. -/
  | tagged (tag : String) (value : Edn)
  deriving Repr, BEq, Inhabited

namespace Edn

/-- A string literal: quotes, backslashes and control characters escaped. -/
def quote (s : String) : String :=
  "\"" ++ s.foldl (fun acc c =>
    acc ++ match c with
      | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\t' => "\\t" | '\r' => "\\r"
      | c => c.toString) "" ++ "\""

partial def render : Edn → String
  | .nil => "nil"
  | .bool b => if b then "true" else "false"
  | .int i => toString i
  | .str s => quote s
  | .kw name => ":" ++ name
  | .sym name => name
  | .vec items => "[" ++ " ".intercalate (items.map render) ++ "]"
  | .list items => "(" ++ " ".intercalate (items.map render) ++ ")"
  | .set items => "#{" ++ " ".intercalate (items.map render) ++ "}"
  | .map entries => "{" ++ ", ".intercalate (entries.map fun (k, v) => render k ++ " " ++ render v) ++ "}"
  | .tagged tag value => "#" ++ tag ++ " " ++ render value

instance : ToString Edn := ⟨render⟩

end Edn

end Determinismo
