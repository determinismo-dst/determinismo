import Determinismo.Cluster

/-!
# Histories

A client history judged against a sequential model (`init`, `apply`): linearizable when some order
of its operations, each placed between its invocation and its answer, gives every acknowledged
result. A failed operation never took effect; an unanswered one may have, at any moment after its
invocation, or never (Jepsen's `info`). A search over orders (Wing and Gong's), for the small
histories of one timeline.
-/

namespace Determinismo

/-- Whether `ops` are linearizable against `init` and `apply`. -/
partial def linearizable {S Op Res : Type} [BEq Res] (init : S) (apply : S → Op → S × Res)
    (ops : List (OpRec Op Res)) : Bool :=
  let effective := ops.filter fun o => o.outcome != some .fail
  let rec go (state : S) (left : List (OpRec Op Res)) : Bool :=
    if left.all (·.ret.isNone) then true
    else
      -- An operation can come next when no other left operation was answered before it began.
      let firstReturn := (left.filterMap (·.ret)).foldl min (left.filterMap (·.ret)).head!
      let candidates := left.filter fun o => o.invoke < firstReturn || o.ret == some firstReturn
      candidates.any fun o =>
        let (state', res) := apply state o.op
        let agrees := match o.outcome with
          | some (.ok r) => res == r
          | _ => true
        agrees && go state' (left.filter (·.id != o.id))
  go init effective

/-- The first acknowledged operations of a history no order explains, for a report: the history
as lines. -/
def historyLines {Op Res : Type} [Repr Op] [Repr Res] (ops : Array (OpRec Op Res)) : List String :=
  ops.toList.map fun o =>
    let outcome := match o.outcome with
      | some (.ok r) => s!"ok {reprStr r}"
      | some .fail => "fail"
      | none => "unanswered"
    s!"op {o.id} at node {o.node}: {reprStr o.op} [{o.invoke}, {o.ret.map toString |>.getD "-"}] {outcome}"

end Determinismo
