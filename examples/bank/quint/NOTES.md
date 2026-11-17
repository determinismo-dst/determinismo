<!-- Written by the agent that wrote bank.qnt (README.md), as it left it. -->
# The bank of run 1, from its traces

`bank.qnt` (module `bank`) accepts all six timelines, event for event. The bank loses and makes
money: a transfer writes back balances it read earlier, over whatever was committed in between.
Timelines 0, 1, 2 and 3 break the invariant; 4 and 5 do not, because no two transfers overlap
in them.

## What the spec says

State: `balances` (four accounts, 100 each at the start) and `reads` (for each client with a
transfer under way, what it read). `ledger` is the spec's own bookkeeping for one invariant; no
guard reads it.

- `bank_read`: a client with no transfer under way reads two different accounts and sees
  exactly the balances the spec has.
- `bank_commit`: the client writes both accounts as **its read's** balances less and plus the
  amount (1 to 50, at most the source balance it read). The guard never looks at what the
  bank holds at commit time, and no timeline needed it to.
- `bank_reject`: the amount is more than the source balance the client read; nothing is written.
- `bank_audit`: lists exactly the spec's four balances, and their sum.

Every guard is an equality or a bound on the event's details, so the spec refuses any event
that does not follow from the ones before it. All six timelines exit 0.

## The property, and where it breaks

`total_conserved`: the balances add up to 400. A stronger one, `no_lost_transfer`: the balances
are the initial ones plus every committed transfer (`balances == ledger`).

"Event 28 of 1637" is the position among the events the spec has actions for; "event 240" is
the timeline's own numbering.

| timeline | events | `total_conserved` | `no_lost_transfer` | last audit's total |
|---|---|---|---|---|
| 0 | 1637 | breaks after event 28 (`bank_commit`, event 240 at 1.266 s) | breaks after event 8 (`bank_commit`, event 141 at 0.888 s) | 1180 |
| 1 | 1634 | breaks after event 22 (`bank_commit`, event 257 at 1.308 s) | same event | 516 |
| 2 | 2972 | breaks after event 20 (`bank_commit`, event 190 at 1.047 s) | same event | 489 |
| 3 | 1639 | breaks after event 51 (`bank_commit`, event 332 at 2.038 s) | breaks after event 15 (`bank_commit`, event 222 at 1.234 s) | 260 |
| 4 | 1 | holds | holds | 400 |
| 5 | 1115 | holds | holds | 400 |

What happened at each break of `total_conserved`:

- **Timeline 0**: client 91 read accounts 3 and 0 as 123 and 100 (event 155). Before it
  committed, clients 100, 103 and 115 took account 0 to 68 and account 3 to 154. Client 91
  then wrote 3 = 110 and 0 = 113: total 401. The bank's own next audit (event 244) says 401.
- **Timeline 1**: client 88 read accounts 0 and 2 as 100 and 100 (event 155). Clients 115 and
  118 took account 2 to 64. Client 88 wrote 0 = 70 and 2 = 130: total 436.
- **Timeline 2**: client 91 read accounts 1 and 3 as 100 and 57 (event 154). Client 109 paid
  18 into account 3. Client 91 wrote 1 = 86 and 3 = 71: total 382, client 109's 18 gone.
- **Timeline 3**: client 103 read accounts 3 and 2 as 67 and 110 (event 223). Clients 106 and
  109 took account 3 to 92 and account 2 to 116. Client 103 wrote 3 = 49 and 2 = 128: total 369.

The earlier breaks of `no_lost_transfer` in timelines 0 and 3 are the same bug with the total
left intact: two clients worked on the same pair of accounts, and the second commit overwrote
both of the first one's writes. In timeline 0, client 73's transfer of 24 (3 to 1) vanished
under client 76's commit; in timeline 3, client 69's transfer of 48 (2 to 0) vanished under
client 76's. The total stayed 400 while a transfer the bank had confirmed was undone, so
watching the total alone under-reports the bug.

Two more invariants tell the timelines apart:

- `one_at_a_time` (at most one transfer under way) holds on 4 and 5 and breaks on 0 to 3 (at
  events 3, 13, 12 and 13). The platform's `composer_load` events agree: parallelism 1 in
  timelines 4 and 5, 32 in the others. Timeline 4 has no transfer at all, only one audit.
- `no_overdraft` (no balance below zero) holds on all six, and in the simulator.

## The bug in plain words

A transfer is two separate steps: read two balances, then write two new ones computed from
that read. Nothing ties the write to the read. If another client commits to either account in
between, the write puts back stale numbers and the other client's change disappears: its debit
(money is made), its credit (money is lost), or both (its transfer is undone). The decision to
reject is made on the same stale read. It is a lost update, and it needs only two overlapping
transfers that share an account.

## The spec alone

`step` picks any next step for 3 clients, 4 accounts and amounts of 10, 30 or 50.

- `quint run bank.qnt --invariant total_conserved` finds the violation in 7 steps
  (`--seed=0xbbb91837853cdb18`): three clients read; client 1 moves 30 from account 0 to 1;
  client 3, which had read account 0 as 100, commits 30 from 3 to 0 and writes 0 = 130.
  Total 430. Same shape as the timelines.
- `--invariant no_lost_transfer` is violated as well; `--invariant no_overdraft` is not.

## What a fixed bank would have to do

Make the commit depend on the read still being true: write only if both balances are still the
ones the client read, and otherwise read again (or reject). In the spec that is one more guard
on `bank_commit`, `not(stale(client))`. `fixed_step` is `step` with that guard and a re-read:
`quint run bank.qnt --step fixed_step --invariant "total_conserved and no_lost_transfer and
no_overdraft"` found no violation in 100,000 runs of 50 steps. That is random simulation, not a
proof.

In Redis terms, any of these gives that guard:

- `WATCH` both keys before the read, write in `MULTI`/`EXEC`, and retry when `EXEC` is refused.
- Do the whole transfer in one script at the server: check the source's funds, then
  `DECRBY`/`INCRBY`.
- Hold a lock on both accounts from the read to the commit.

Switching the write to `DECRBY`/`INCRBY` alone would not be enough: the total would be kept,
but the funds check would still use a stale read, so two transfers could overdraw an account.
This last point is reasoning; I did not model it.

## How to repeat it

    ./trace.sh http://127.0.0.1:7979 1 <0..5> bank.qnt
    ./trace.sh http://127.0.0.1:7979 1 <0..5> bank.qnt --invariant total_conserved
    ./trace.sh http://127.0.0.1:7979 1 <0..5> bank.qnt --invariant no_lost_transfer
    quint run bank.qnt --invariant total_conserved
    quint run bank.qnt --invariant total_conserved --step fixed_step
