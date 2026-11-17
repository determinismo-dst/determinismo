# Sharing a moment

Any moment of any timeline (failing or not) can be handed to someone else as a **bundle**: they
open it on their own machine at that moment, in seconds, without replaying the timeline from its
start, and the guest goes on from there exactly as it did where it was recorded.

## What a bundle holds

- The timeline's tapes (its own, and those of the timelines it began inside: a tree's).
- The run's inputs: kernel, initramfs, the test program, the system's images, its pinned
  guest CPU (`cpuid.txt`), and the run's own explorer (a snapshot loads only in the build
  that saved it).
- The moment's snapshot (memory and CPU state, zstd-compressed).
- `checkers/`: the sources of the host checks' services (Elle's). The checks build and start
  them with podman where the bundle is opened, so its verdicts are the recording host's.
- `INSPECT.sh`: opens the timeline at its moment and runs a command there.

Large files go into a content-addressed store (`sha256/<digest>`): a blob is sent once,
whichever bundle or run needs it again.

## Making one (on the recording host)

```
infra/host/bundle-moment.sh ~/.determinismo/runs/<run> <timeline> <moment ms> ~/bundles/<name> ~/bundles/store
infra/host/bundle-s3.sh push ~/bundles/store ~/bundles/<name> s3://<bucket>/<prefix>
```

## Opening one on AWS

`infra/aws/inspect.sh <name> --bucket <bucket>` launches a c8i.xlarge (about $0.2 an hour, nested
virtualization), pulls the bundle through a read-only instance role and opens it at its moment. It
prints `ssh admin@<ip>` and the command that terminates the machine.

- **From the inspection AMI** (the newest `determinismo-inspect-*` the account owns or may launch):
  no setup, our KVM loaded at boot.
- **Without one** (`--no-ami`, or none exists): Debian 13's AMI set up with `setup.sh --inspect`,
  about 3.5 minutes from launch, and it needs this repository.

There: `cd ~/<name> && ./INSPECT.sh '<command>'` runs a command at the moment (for example
`det-nodes exec <node> <command>`); the run's explorer in `artifacts/` does everything else
`determinismo explore --run . --branch <timeline>` does (continue to the end, fork futures).

### The inspection AMI (`infra/aws/inspect-ami.sh`)

One generic image per release, not one per bundle or per person: a bundle carries everything
specific to its run (guest, system images, the run's own explorer, its checkers' sources), so any
bundle opens on it. The script sets a c8i up with `setup.sh --inspect`, then seals it:
- kept, in `/opt/determinismo-inspect`: the built `kvm.ko` and `kvm-intel.ko` (loaded at boot by
  `determinismo-kvm.service`), `load-kvm.sh`, `bundle-s3.sh` (also `/usr/local/bin`), and the KVM
  patch with the script that built them (the modules are GPL: their source goes with them);
- Elle's service, built once and started at every boot (a quadlet of admin's), so a bundle's
  checks find it answering and build nothing (a bundle of another Elle version replaces it);
- removed: the repository (it is private), the kernel tree, the toolchain, every authorized SSH
  key (an instance gets its launcher's key from cloud-init) and cloud-init's state (new host keys
  at each launch).

Rebuild it when our KVM patch or the pinned kernel changes; the name carries the commit. Its
snapshot costs about $0.05 per GB-month of used blocks (a few GB), each region copy as much: old
images are deregistered and their snapshots deleted.

## Sharing with someone else

### Their own AWS account (`infra/aws/share.sh`)

```
infra/aws/share.sh grant <their account id> <bundle>...   # read access + the AMI
infra/aws/share.sh list
infra/aws/share.sh revoke <their account id> [<bundle>...]
```

`grant` adds the bucket policy's statements for that account (list and read each bundle's own
files; read blobs, which are named by their content's digest, so only a holder of a bundle's
`STORED` can name one) and shares the newest inspection AMI with it. It prints what they set up
once: an instance profile whose role reads the bucket (the policy is printed), a key pair and a
security group with SSH from their address. Then they run `inspect.sh <bundle> --bucket <ours>
--profile <theirs> --key <theirs> --group <theirs>` on their account, paying for their machine.

### Without AWS

`infra/aws/share.sh links <bundle> [--hours N]` writes a script that downloads the bundle and its
blobs through presigned links (valid N hours, default 24; links signed with temporary
credentials, such as `aws login`'s, end with them) and puts each blob in place with the bundle's
own explorer. They need a host as below.

## Opening one elsewhere

Any x86-64 Intel host with KVM, bare metal or with nested virtualization, running Debian 13.

**Without this repository:** the inspection kit (`infra/inspect-kit/make.sh` makes
`determinismo-inspect-kit-<commit>.tar.gz`: install.sh, the CPU check, the KVM patch and its build
and load scripts, bundle-s3.sh). Unpack it in /opt (the boot loads our KVM from there), then as
root `install.sh <user>` (a user with sudo), reboot when it asks (TSX off), and run it again. It
installs the module build's packages, podman, zstd and the AWS CLI, pins the kernel, and changes
nothing else (no users, sudo rules, SSH keys or firewall). ECC is reported, not required.

**With this repository:**

```
infra/host/setup.sh <ip> --user <user> --inspect   # our KVM module, the AWS CLI, zstd, podman
```

Then fetch the bundle (`infra/host/bundle-s3.sh pull ...`, or copy the bundle and the blobs its
`STORED` lists by any means, then `artifacts/<explorer> bundle fetch <bundle> <store>`), and run
its `INSPECT.sh`.

The host's CPU must offer every feature of the bundle's `cpuid.txt`; otherwise the explorer
refuses at once ("this host lacks CPUID ... bits ... of the given table"), naming the bits.
Runs recorded since 2026-11-10 hide MPX, VMX and RSBA from their guests: Skylake-SP and
Cascade Lake open them, and so does Granite Rapids (a c8i, measured); try another model and the
explorer says which bits it lacks. Older runs need a CPU with MPX (Skylake-SP, Cascade Lake).

### In one click, with serve's web UI (`infra/aws/inspect-stack.yaml`)

A Launch link opens CloudFormation's quick-create
page with this template (published as the bucket's `tools/metal-stack.yaml`) and the bundle's name
filled in: the visitor picks a key pair and their address (one, a /32) and creates the stack. A
bare-metal m5zn.metal (spot by default, about $1 an hour; on demand $3.96) from determinismo's base
AMI (`inspect-ami.sh --type m5zn.metal`: determinismo-base-*) pulls the bundle at boot and serves it
with the run's own explorer (`infra/aws/serve-bundle.sh`: the bundle as
run 1, its machine and pinned system serve's); the stack's outputs give the SSH tunnel, then
http://localhost:7878. There, as on the recording host: the report, the failing property and its
example, the timeline's logs, "Run at this moment" (from the bundle's snapshot, 30 s before the
moment at most) and "Fork here" (futures from the moment, a run of their own). Deleting the stack
removes everything.

A REPL inside the guest at the moment (`infra/host/nrepl-proxy.py --bundle ~/<name> --node <node>`
on the machine, then `ssh -L 7888:127.0.0.1:7888`): any nREPL client, each message a step of the
timeline.

## Measured (2026-11-10)

The one-click stack, DuckDB run 1742's timeline 43 (failure at 2806 ms, snapshot at 2432 ms), on a
c8i.xlarge: 3 min 25 s from creating the stack to the UI served; "Run at this moment"
(`det-nodes list` at the failure) under 10 s; "Fork here" reached the failure in 4.7 s from the
setup's snapshot (the system the run pinned, d258857928297e31), its 4 futures then about 0.15 virtual
seconds per second on 2 workers (2 physical cores: nothing else runs meanwhile; a c8i.2xlarge for
forks). The futures ran past the original timeline's end (379 s against 220 s) before being stopped:
not looked into.

jank's nREPL inside determinismo from a laptop: nrepl-test's jank timeline (trial run 1782, timeline 2)
bundled at 40 s (2 GB: jank's image), opened on that machine through nrepl-proxy.py --bundle and an
SSH tunnel: the session up 3 min after the replay from the snapshot (10 s to 40 s) began;
`(+ 1 2)` answered `3` in 48 s, `(defn sq [x] (* x x))` and a call in 25 s (jank compiling on a
nested CPU).

From the inspection AMI: 52 to 58 s from launch to the moment open (207 s with setup); the same
timeline run on to its end with the recording host's events hash (32c0f3eb17ff8e23, 144047 events,
Elle judging),
4 min 52 s. Elle's service answers by itself about 30 s after boot.

With the kit, on a fresh Debian 13 c8i with no repository and no AWS credentials (the bundle through
`share.sh links`): install 99 s including its boot; the moment open with the same hash; the
timeline to its end with the recording host's events hash, Elle built on its first check.

NATS run 1722's timeline 241 (begun inside timeline 27), recorded on a Xeon Gold 6152 (Skylake-SP),
opened
at 300 s on a c8i (Granite Rapids): 207 s from launch to the moment open; the snapshot loaded in
0.2 s; run on to its end (574 s, 5 min 21 s) with the recording host's events hash exactly
(32c0f3eb17ff8e23,
Elle judging its history).
