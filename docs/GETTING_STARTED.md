# Getting started: testing your own system with determinismo

determinismo runs your system (its services, its database, its workers) inside one virtual
machine whose every source of nondeterminism it controls: time, thread scheduling, randomness,
the network and the disk. It explores many possible futures of the system from one snapshot,
injects faults (power losses, crashes, pauses, network cuts) along the way, checks the
properties you state, and when one fails, replays that exact timeline as often as you want, to
the instruction.

This guide takes you from a rented machine to your own system's first findings, through three
worked examples of growing size:

1. [**Notes**](#tutorial-1-a-notes-service-and-a-power-loss): one small service, one property,
   one bug most of us have written.
2. [**Orders**](#tutorial-2-an-order-service-api-workers-and-postgresql): an API, two workers and
   PostgreSQL, the shape of many company backends, with two bugs.
3. **A real open-source system, from scratch** (coming): how we built the test that found a real
   bug in one, step by step.

Then [your own system](#your-own-system).

## Your machine

determinismo needs a Linux machine with an **Intel CPU with VT-x**, on **bare metal** (its
hypervisor is a patched KVM: a cloud VM, without nested virtualization fast enough, will not
do). Memory and cores decide how many timelines run at once: each one is a VM of 2 to 8 GiB.

| | Minimum | Comfortable |
|---|---|---|
| CPU | Intel with VT-x, 8 cores | 32+ physical cores (one timeline per core) |
| Memory | 32 GiB | 128 GiB+ |
| Disk | 200 GB free | 1 TB+ (in-run snapshots, tapes) |

Machines it runs on: Xeon Gold 6152 servers (44 cores, 187 GB), Hetzner's dedicated servers
(`setup.sh` installs from their rescue system), phoenixNAP's hourly bare metal.

From your laptop, with SSH access to the machine as root:

```sh
git clone <determinismo's repository> && cd determinismo
infra/host/setup.sh <the machine's address>
```

`setup.sh` installs Debian if needed, hardens the machine, builds and loads determinismo's KVM
(at every boot too), builds the guest and determinismo, runs the end-to-end check and starts
`serve`, the web UI. Then, on the machine:

```sh
determinismo doctor
```

It checks every requirement and says what to do about each one that is not met.

The UI listens on the machine's port 7878, on localhost only: reach it with
`ssh -N -L 7878:127.0.0.1:7878 det@<the machine>`, then open <http://localhost:7878>.

## The shape of a test

A test is one program (Zig, using determinismo's SDK) that says three things:

- **The system**: its nodes, each a container built from a Dockerfile (or an image), how to
  tell it is ready, and which faults it may suffer.
- **The workload**: drivers, functions that use the system as its clients would, run many
  times, concurrently, under faults.
- **The properties**: what must always hold (`sdk.always`), and what must happen at least
  once for the test to mean anything (`sdk.sometimes`).

You rarely write it alone: with [Claude Code](https://claude.com/claude-code) in this
repository, ask *"test my service with determinismo"*: its skills (`determinismo-properties`,
then `determinismo-workload`) read your code, list the properties your system promises, and
write the test program and its Dockerfiles; `determinismo-debug` then explains a failure.
The tutorials show what they produce, so you can read and change it.

To run a test: build its program, then run it from the UI (**New run**) or the command line:

```sh
~/opt/zig/zig build notes-test -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --cache ~/cache \
  --program zig-out/bin/notes-test --scenario notes --time-budget 10m
```

A run explores for its time budget, as many timelines at once as the machine has cores, and
prints each property's verdict; the UI shows the same run as it goes.

## Tutorial 1: a notes service and a power loss

[examples/tutorial/1-notes](../examples/tutorial/1-notes): `app/notes.py` is a short Python
service. `POST /notes/<id>` stores a note, `GET /notes` lists them. It keeps every note in one
JSON file, rewritten whole on each change: written to a temporary file, then renamed over the
old one, so a reader never sees half a file. That is how most of us would write it.

Its test, `notes_test.zig`, says:

- **the system**: one node, built from `app/Dockerfile`, ready when port 8080 answers, which may
  lose power (`.faults = .{ .crash = true }`): its disk keeps only what was synced;
- **the workload**: drivers add notes, and note each one the service acknowledged;
- **the properties**: once the faults stop, *the service comes back*, and *every acknowledged
  note is still there*.

**First run** (10 minutes on a 6-core machine, 56 timelines). Two things fail:

- *every acknowledged note is still there* (in 11 timelines): the service said `stored`, then
  lost the note in a power loss. Nothing was synced before the reply: the rename was in the disk's cache, not on it.
- *the service comes back*: after some power losses the service never starts again, and its log
  says `EOFError: marshal data too short`, raised by `import http.server`. This one is not in
  your code. Python writes its compiled bytecode (`.pyc` files) the first time it imports a
  module, unsynced, and a power loss can leave one short; on the next start Python refuses it
  instead of compiling the module again. A bug in the language runtime underneath the service,
  found by a test that never looked for it.

Click a failing timeline in the UI: its logs, its faults and the moment the property failed
are there, and **Run at this moment** replays it exactly, as often as you want.

**The fixes** (profile `durable`): sync the file before the rename and its directory after it,
so the reply comes only when the note is on the disk; and stop Python writing bytecode as it
runs (`PYTHONDONTWRITEBYTECODE=1`). **Second run**: 24 timelines, every property passes.

```sh
determinismo explore ... --program zig-out/bin/notes-test --scenario notes --profile durable --time-budget 10m
```

## Tutorial 2: an order service: API, workers and PostgreSQL

[examples/tutorial/2-orders](../examples/tutorial/2-orders): an API takes orders, two workers
charge them, PostgreSQL holds both. A worker finds a pending order, marks it as charging,
charges it and marks it charged: four statements, each committed on its own, the way it often
grows in a codebase. The test runs four nodes (the database from PostgreSQL's image, the API
and two workers from one Dockerfile), kills and restarts workers anywhere in their loop, and
pauses and cuts the network. Its properties, any team running such a service would sign:

- *no order is charged twice*;
- *every accepted order is charged*, once the faults are over;
- *the API answers again* once the faults are over.

**First run** (15 timelines): all three fail.

- **Charged twice** (11 timelines): two workers read the same pending order before either
  marks it: nothing stops the second.
- **Never charged** (5 timelines): a worker killed between *charging* and *charged* leaves the
  order charging forever; no one picks it up again.
- **The API never answers again** (4 timelines): a network cut leaves a database connection
  waiting forever on a peer that is gone (no keepalives, no timeouts), and the API, serving one
  request at a time, never answers anyone again. Nobody set out to test this one.

**The fixes** (profile `safe`): claim an order with `SELECT ... FOR UPDATE SKIP LOCKED` and
charge and mark it in the same transaction (a worker that dies mid-way rolls back, the order is
pending again); give the database connection keepalives and timeouts, and each HTTP request a
timeout. **Second run**: 11 timelines, every property passes.

## Developing with determinismo

You can also develop *inside* determinismo: a REPL in one of the system's nodes, at a moment of
a timeline, from your editor ([docs/REPL.md](REPL.md)):

```sh
python3 infra/host/nrepl-proxy.py --serve http://127.0.0.1:7878 --run <id> --node <node>
```

then connect your editor (CIDER, Calva, any nREPL client) to port 7888, through an SSH tunnel
from your laptop. Measured on the 6-core rented machine, from a laptop: about 0.1 s an
evaluation, Clojure on the JVM and jank alike. Write a function and a property there, trigger a
run on the machine's other cores, keep working while it explores, read its verdict. The REPL
stays as fast while the run goes.

## Your own system

1. Describe it: its nodes (the Dockerfiles you already have), how each one says it is ready.
   Run it with no workload first: determinismo's built-in properties (no crash, no unexpected
   exit, no out-of-memory kill, a node that faulted starts again) judge it under faults already.
2. Say what it promises: the properties a user of it would sign, as the tutorials do.
   `determinismo-properties` lists them from your code and docs.
3. Write the workload that uses it as its clients do, and put assertions in your own code where
   a property is decided (`sdk.always`, `sdk.sometimes`, in your language: docs/SDKS.md): they
   are what determinismo steers toward.
4. Run, open each failure at its moment, fix, run again.
