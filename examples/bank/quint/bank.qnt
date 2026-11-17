// The bank as its clients' events tell it (run 1, timelines 0 to 5): four accounts kept in
// Redis, clients that move money from one to another in two steps, a read and then a write.
//
//   bank_read    a client reads the two balances of the transfer it is about to make
//   bank_commit  it writes both balances back, as its read and the amount make them
//   bank_reject  it gives the transfer up: the amount is more than the source held in its read
//   bank_audit   a client reads all four balances at once and adds them up
//
// Each action takes its event's details and is enabled only when they are exactly what this
// state implies; nothing in an event is taken on trust.
module bank {
  type Read = { client: int, source: int, target: int, source_balance: int, target_balance: int }
  type Commit = { client: int, amount: int, source_balance: int, target_balance: int }
  type Reject = { client: int, amount: int }
  type Audit = { balances: List[int], total: int }

  pure val ACCOUNTS = 0.to(3)
  pure val INITIAL = 100
  // No client asked for less than 1 or more than 50, in any timeline.
  pure val MAX_AMOUNT = 50

  // What Redis holds: each account's balance.
  var balances: int -> int
  // What each client that has read and not yet committed or rejected holds: its read.
  var reads: int -> Read
  // Not the bank's: the spec's own book of what the balances would be had every commit moved
  // its amount from its source to its target and done nothing else. No guard reads it.
  var ledger: int -> int

  pure def total(b: int -> int): int = b.keys().fold(0, (sum, a) => sum + b.get(a))
  // The balances as an audit lists them: account 0's first.
  def listing: List[int] =
    range(0, ACCOUNTS.size()).foldl(List(), (list, a) => list.append(balances.get(a)))
  def pending(c: int): bool = reads.keys().contains(c)
  def forget(c: int): int -> Read = reads.keys().exclude(Set(c)).mapBy(k => reads.get(k))
  // A client's read is stale once a commit changed one of its two balances.
  def stale(c: int): bool = {
    val r = reads.get(c)
    or {
      balances.get(r.source) != r.source_balance,
      balances.get(r.target) != r.target_balance,
    }
  }

  action init = all {
    balances' = ACCOUNTS.mapBy(_ => INITIAL),
    reads' = Map(),
    ledger' = ACCOUNTS.mapBy(_ => INITIAL),
  }

  // A client with no transfer under way reads two different accounts, and sees exactly what
  // the bank holds then.
  action bank_read(e: Read): bool = all {
    not(pending(e.client)),
    ACCOUNTS.contains(e.source),
    ACCOUNTS.contains(e.target),
    e.source != e.target,
    e.source_balance == balances.get(e.source),
    e.target_balance == balances.get(e.target),
    reads' = reads.put(e.client, e),
    balances' = balances,
    ledger' = ledger,
  }

  // The client writes both accounts: the balances OF ITS READ, less and plus the amount. The
  // amount is one its read could pay. Nothing here looks at what the bank holds now: the
  // events never needed it, in any timeline.
  action bank_commit(e: Commit): bool = all {
    pending(e.client),
    val r = reads.get(e.client)
    all {
      1 <= e.amount,
      e.amount <= MAX_AMOUNT,
      e.amount <= r.source_balance,
      e.source_balance == r.source_balance - e.amount,
      e.target_balance == r.target_balance + e.amount,
      balances' = balances.set(r.source, e.source_balance).set(r.target, e.target_balance),
      ledger' = ledger.setBy(r.source, b => b - e.amount).setBy(r.target, b => b + e.amount),
    },
    reads' = forget(e.client),
  }

  // The client gives up a transfer its read could not pay (again its read, not the bank now).
  action bank_reject(e: Reject): bool = all {
    pending(e.client),
    e.amount <= MAX_AMOUNT,
    e.amount > reads.get(e.client).source_balance,
    reads' = forget(e.client),
    balances' = balances,
    ledger' = ledger,
  }

  // An audit lists exactly the bank's balances, in the accounts' order, and their sum.
  action bank_audit(e: Audit): bool = all {
    e.balances == listing,
    e.total == total(balances),
    balances' = balances,
    reads' = reads,
    ledger' = ledger,
  }

  // --- What a bank must keep ---

  // Transfers move money, they neither make nor lose it.
  val total_conserved = total(balances) == ACCOUNTS.size() * INITIAL
  // Stronger: the balances are the initial ones and every committed transfer, no more, no
  // less. (A stale commit can undo another's transfer whole and leave the total as it was.)
  val no_lost_transfer = balances == ledger

  // --- What holds, and what tells the timelines apart ---

  // No account is overdrawn: a commit never writes less than zero. Holds everywhere.
  val no_overdraft = ACCOUNTS.forall(a => balances.get(a) >= 0)
  // At most one transfer under way. Holds only where the load had one client at a time.
  val one_at_a_time = reads.keys().size() <= 1

  // --- The spec alone: any client's next step, over small sets ---

  pure val CLIENTS = 1.to(3)
  pure val AMOUNTS = Set(10, 30, 50)

  action read_step = {
    nondet c = CLIENTS.oneOf()
    nondet s = ACCOUNTS.oneOf()
    nondet t = ACCOUNTS.oneOf()
    bank_read({
      client: c, source: s, target: t,
      source_balance: balances.get(s), target_balance: balances.get(t),
    })
  }

  // A client that has read commits when its read can pay, and rejects when it cannot.
  // `fresh_only`: a commit on a stale read is refused (the client is left to read again).
  action write_step(fresh_only: bool): bool = all {
    reads.keys().size() > 0,
    {
      nondet c = reads.keys().oneOf()
      nondet amount = AMOUNTS.oneOf()
      val r = reads.get(c)
      any {
        all {
          not(fresh_only and stale(c)),
          bank_commit({
            client: c, amount: amount,
            source_balance: r.source_balance - amount, target_balance: r.target_balance + amount,
          }),
        },
        bank_reject({ client: c, amount: amount }),
      }
    },
  }

  // What a client whose commit was refused does in the fixed bank: it reads again.
  action reread_step = all {
    reads.keys().size() > 0,
    {
      nondet c = reads.keys().oneOf()
      val r = reads.get(c)
      all {
        stale(c),
        reads' = reads.set(c, {
          ...r, source_balance: balances.get(r.source), target_balance: balances.get(r.target),
        }),
        balances' = balances,
        ledger' = ledger,
      }
    },
  }

  action audit_step = bank_audit({ balances: listing, total: total(balances) })

  // The bank of the traces.
  action step = any { read_step, write_step(false), audit_step }

  // The bank with one more guard: a commit goes through only if its client's read still
  // holds (what WATCH + MULTI/EXEC, a script or a lock gives). `--step fixed_step`.
  action fixed_step = any { read_step, write_step(true), reread_step, audit_step }
}
