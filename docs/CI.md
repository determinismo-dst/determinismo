# CI on determinismo

Your test suite, run so that every failure, flaky or not, comes back as a link that replays it
exactly, and your setup is not redone on every run.

## How it runs

1. **Setup once, at full speed.** Your system boots in a fast VM (several cores, real time),
   and your setup command runs there: dependencies, a build, a database started. The machine is
   then saved as a snapshot, cached by a key: your config, your system's file, and the files
   you name as the setup's inputs (lockfiles, build files). The next run with the same key
   starts from that snapshot, in milliseconds, without running the setup.
2. **Tests sharded over deterministic machines.** A job is one run: shards times timelines
   started from the snapshot, each timeline its shard's (its index modulo the shards), the run's
   page holding the whole job. Each timeline runs its shard's tests under its own thread
   schedule and its own randomness, on one deterministic vCPU, one timeline a core.
3. **Verdicts per test.** With a JUnit report (`junit`), each test is a property of its own in
   each timeline (`det-assert junit`): failing in every timeline, **fail**; in some, **flaky**,
   with how often; in none, **pass**. Without one, each shard is judged as a whole. Each failing
   timeline is on serve's run page, the test with its own property page, where it replays
   exactly, with its logs, its moment, a REPL there.
4. **Timing faults while the tests run** (`faults`, "timing" by default): threads and processes
   paused, the scheduler's choices drawn (det-faults' thread_pause, process_pause, interleave).
   They change when threads run and nothing else, so a race between a test's threads shows in
   some timelines; "none" leaves only each timeline's own schedule. Faults that break the
   machine itself (partitions, crashes, disks) stay off: a test suite does not expect them.

## The config: `.determinismo/ci.json`

```json
{
  "compose": "compose.yaml",
  "node": "app",
  "setup": "cd /app && npm ci && npm run build",
  "list": "cd /app && npx jest --listTests",
  "run": "cd /app && npx jest --ci --shard={shard}/{shards}",
  "shards": 8,
  "timelines": 3,
  "key_files": ["package-lock.json", "src", "Dockerfile"]
}
```

- `compose` (or `program`, a determinismo test program): the system, its nodes from your
  Dockerfiles or images.
- `node`: where the commands run.
- `setup`: run once per key, in the fast VM.
- `list`: prints the tests, one per line.
- `run`: runs some of them, exit status 0 when they pass: `{tests}` (the shard's names, as
  arguments: its part of the list, written in the machine at setup) or `{shard}` and `{shards}`
  (1-based) for a runner that shards itself.
- `junit` (optional): where the run command writes a JUnit XML report in the node (pytest's
  `--junitxml`, Jest's jest-junit, go-junit-report). Given, each test gets its own verdict across
  its shard's timelines (failing in all, flaky in some, passing), each test a property with
  its own page on serve; without it, only shards do (a shard with one test failing everywhere hides a flaky one
  beside it). A shard failing with no failing test in its report (a crash in teardown) still
  fails the job.
- `faults`: "timing" (the default), "none", or a list of det-faults' kinds, "timing" among them
  for its three: `["timing", "partition", "disk"]` adds faults that break the machine itself
  for a suite that claims to handle them. A name det-faults does not know is refused before
  anything runs.
- `shards`, `timelines`: how many shards, and timelines each.
- `key_files`: what the setup depends on; a directory stands for every file in it. The setup's
  key is the system, `setup`, `list`, the machine's size and these files: changing `run`,
  `shards`, `timelines` or `junit` reuses the cached setup.
- `vcpus`, `memory_mib`: the machine's size (4 and 2048 by default).

## Coverage

The tests' code is covered with nothing in your repository asking for it, so explorations keep
the timelines that reach new code and serve can tell a job that ran from one that did not
(it stops a run whose first timelines report no coverage):

- **JVM** (24 or later): determinismo's agent, on `JAVA_TOOL_OPTIONS`; 17 to 23, only jars
  instrumented ahead of time (docs/PLUGINS.md).
- **Python** (3.12 or later): each Python process the run command starts reports the lines of
  its own code: every file but the interpreter's library and the installed packages (the
  node's `DETERMINISMO_COVERAGE` narrows it). A `sitecustomize` of your own still runs.
- Other languages: built with their instrumentation (docs/SDKS.md).

An older Python or JVM runs uncovered and says so on standard error.

## Running it

On the host (serve running there):

```sh
cd <your repository> && determinismo-ci
```

`determinismo-ci` is a product on determinismo: a client of serve's machines
and runs. It keeps the setup cache itself (`~/.determinismo/ci-cache`, `--cache`). Each job's
run is tagged with where its tests come from: the repository, branch, commit and subject, from
git where it runs, or given (`--repository`, `--branch`, `--commit`, `--subject`: the GitHub
Action passes GitHub's, its checkout copied without `.git`).

serve's UI has a CI page ("CI jobs" beside "All runs", `#ci`): each repository's jobs, newest
first, and every test that did not pass in all of its last ten jobs, its verdict in each (fail,
flaky with how often, pass), each linking to that test's page in that job's run: when a test
began failing, when it was fixed, which commits it is flaky in.

From GitHub Actions, with the composite action in this repository:

```yaml
- uses: actions/checkout@v4
- uses: <determinismo's repository>/.github/actions/determinismo-ci@develop
  with:
    host: ${{ secrets.DETERMINISMO_HOST }}
    ssh-key: ${{ secrets.DETERMINISMO_SSH_KEY }}
    known-hosts: ${{ secrets.DETERMINISMO_KNOWN_HOSTS }}
```

It copies the checkout to the host and runs `determinismo-ci` there; the job's log shows each
shard's verdict and its run's link. Exit status 0 when every shard passes, 1 when one fails, 2
when one is flaky (`--flaky-passes` counts flaky as passing).

## Limits

- A deterministic machine has one vCPU: a suite whose tests need many cores at once runs slower
  in each timeline than on a normal machine; shard it wider.
- Shard verdicts, not per-test ones yet: a shard is flaky or failing as a whole; its runs' pages
  show which test failed in each timeline.

Try it: [examples/ci-demo](../examples/ci-demo) (three tests: one passes, one flaky, one wrong).
