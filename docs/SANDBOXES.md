# Agent sandboxes

A machine for an AI agent to work in: the agent's commands and files there, nothing outside it
touched, and every state it reaches saved, forked, rewound or replayed.

## What a sandbox is

A fast VM booted from a system: a Compose file, an image, or a determinismo
test program's profile. Several cores, real time: compilers, test suites and databases run as on
any machine. On it:

- **exec**: a shell command in a node, its status and output;
- **files**: written and read in a node;
- **checkpoints**: the whole machine saved as it stands, in about a second, the sandbox going on;
- **forks**: new sandboxes, each a copy of a checkpoint's machine (restored in under a second):
  an agent's N attempts at a task from one state, side by side;
- **rewind**: the sandbox back to a checkpoint;
- **explore**: deterministic timelines from a checkpoint, with faults (a crash, a network cut,
  a disk full), each replayable exactly: does what the agent built hold up?

## Where the agent runs

- **Outside** (its loop on your machine, Claude Code, an SDK): its tools act in the sandbox
  through serve's API or the MCP tools below. Nothing changes for the agent: the same bash,
  read and write tools, answered by the sandbox.
- **Inside**, in a node, wholly contained: its harness runs there unchanged. (Its model's calls
  recorded for exact replays: coming.)

## determinismo-sandbox

A product on determinismo: its own binary, a client of serve's machines
(`/machines`: fast VMs) and runs. It keeps each sandbox's state and record (every step, and each
written file's bytes) in its data directory (`~/.determinismo/sandboxes`), so a sandbox outlives
its machine: a rewind replaces the machine, a replay runs the record.

```
determinismo-sandbox [--serve <url>] [--data <dir>] <command>
  create (--compose <file> | --program <p>) [--profile p] [--scenario s] [--vcpus n] [--memory-mib n]
  exec <sandbox> <node> <command>         its status and output
  write <sandbox> <node> <path> <file> [--secret]   (`-`: stdin)
  read <sandbox> <node> <path>
  checkpoint <sandbox>                    the machine saved, going on
  fork <sandbox> <checkpoint> <count>     new sandboxes, each from the checkpoint
  rewind <sandbox> <checkpoint>
  explore <sandbox> <checkpoint> [branches] [time budget]   timelines with faults (a run)
  replay <sandbox> <checkpoint> [until]   its steps after the checkpoint, deterministic (a run)
  egress <sandbox> <node> <host>...       an HTTPS proxy in the node for those hosts
  delete <sandbox> | list
  mcp                                     the same as MCP tools, over stdio
```

serve's address: `--serve`, else `DETERMINISMO_SERVE`, else `http://127.0.0.1:7878`.

## Egress

A sandbox's nodes reach nothing outside by default. `egress <sandbox> <node> <host>...` starts
a proxy in the node (`http://127.0.0.1:3128`, for `HTTPS_PROXY`) that reaches only the hosts
named: an agent's model, a package index.

The permission is part of the sandbox's state, as its files are. A checkpoint records it, so:

- a **fork** or a **rewind** of that checkpoint has the same way out (an agent in each fork
  calls its model);
- a **replay** or an **exploration** from it may reach the same hosts. There the connections
  are decisions on the timeline's tape: a replay of a recorded timeline answers from the tape
  and reaches nothing.

## CPUs

Sandboxes share CPUs among themselves: a sandbox is idle most of the time, so several sit on
one CPU (4 by default, serve's `--machines-per-cpu`), and a new one joins the CPU that already
has some before taking a fresh one. They never share one with a timeline: a deterministic VM
has its CPU to itself, and a CPU with a sandbox on it is closed to timelines until its last
sandbox goes. So the sandboxes alive at once are the CPUs serve's machines run on (the reserved
cores when serve has them, `serve.sh --reserved-cores`; serve's own otherwise) times that
number. One more is refused at once (`every place for a machine is taken`): delete a sandbox
first. Busy at the same moment, the sandboxes of one CPU slow each other: lower the number for
agents that compile or test all the time. A deleted sandbox keeps its record and checkpoints and
leaves `list`.
