# SPDX-License-Identifier: MIT
"""determinismo SDK for Python: assertions, events and platform randomness.

Inside determinismo everything goes through /dev/determinismo: events are recorded with their
moment, and every random value is a decision the platform can steer and replay. Outside it
(local runs) randomness comes from the OS and events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT
(or Antithesis's ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else nowhere
(Antithesis's default: assertions evaluated, nothing written), so
the same code runs everywhere. One file, standard library only: copy it next to your code.

The same API as the other SDKs (docs/SDKS.md); Antithesis's Python SDK's names work too
(get_random, send_event, always_greater_than_or_equal_to, ...).

    import determinismo as det
    account = det.random_below(10)
    det.always(total == 1000, "total balance is conserved", {"total": total})

The assertion catalog: every assertion with a literal message is announced when its module's
code runs (imported or executed), before the assertion itself runs (Antithesis's catalog), so
one no timeline reaches is judged too. A message computed at run time is known once it runs.
"""
import ast
import json
import math
import random
import os
import sys
import threading
import time
import zlib

DEVICE_PATH = "/dev/determinismo"
MESSAGE_SIZE_MAX = 4096 - 16  # One event or one randomness pull per device call.

_device = None
_device_opened = False


def _device_fd():
    global _device, _device_opened
    if not _device_opened:
        _device_opened = True
        try:
            _device = os.open(DEVICE_PATH, os.O_RDWR | os.O_CLOEXEC)
        except OSError:
            _device = None  # Not inside determinismo.
    return _device


def random_bytes(count):
    """`count` random bytes: a platform decision inside determinismo."""
    assert 0 < count <= MESSAGE_SIZE_MAX
    fd = _device_fd()
    if fd is None:
        return os.urandom(count)
    data = os.read(fd, count)
    assert len(data) == count
    return data


def random_u64():
    return int.from_bytes(random_bytes(8), "little")


def random_below(count):
    """A uniformly random integer in [0, count)."""
    assert count > 0
    return random_u64() % count


def random_choice(items):
    """One of the items, a platform decision; None when there are none (as Antithesis's
    random_choice, and the other SDKs: Go's zero value, Rust's None, Java's null)."""
    if len(items) == 0:
        return None
    return items[random_below(len(items))]


def random_float():
    """A float in [0, 1) from 53 random bits: a platform decision."""
    return (random_u64() >> 11) * (1.0 / (1 << 53))


get_random = random_u64  # Antithesis's name.


class Random(random.Random):
    """A random.Random whose every draw is a platform decision, for code that takes an RNG
    (shuffle, choice, sample, uniform, ...): what it draws is steerable by strategies and replays
    from tapes. Each draw is one request to the platform; for hot loops, prng()."""

    def seed(self, *arguments, **options):
        pass  # The platform decides.

    def random(self):
        return (random_u64() >> 11) * (1.0 / (1 << 53))

    def getrandbits(self, k):
        if k <= 0:
            return 0
        return int.from_bytes(random_bytes((k + 7) // 8), "little") >> (-k % 8)

    def getstate(self):
        raise NotImplementedError("platform randomness has no state to save")

    def setstate(self, state):
        raise NotImplementedError("platform randomness has no state to restore")


def rng():
    """A random.Random backed by platform decisions (see Random)."""
    return Random()


def prng():
    """A fast random.Random seeded from one platform decision: deterministic and different in
    every branch, steered only through its seed."""
    return random.Random(random_u64())


_local_output = None
_local_output_opened = False


def _local_output_fd():
    global _local_output, _local_output_opened
    if not _local_output_opened:
        _local_output_opened = True
        path = os.environ.get("DETERMINISMO_SDK_LOCAL_OUTPUT") or os.environ.get(
            "ANTITHESIS_SDK_LOCAL_OUTPUT")
        if path:
            try:
                _local_output = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC,
                                        0o644)
            except OSError:
                _local_output = None
    return _local_output


def _finite(value):
    """`value` with each number JSON has no form for (infinity, NaN: json.dumps writes them bare,
    `Infinity` and `NaN`, which no parser reads, and the whole event was lost) as the strings
    "Infinity", "-Infinity" and "NaN", as every SDK of ours sends them."""
    if isinstance(value, float) and not math.isfinite(value):
        return "NaN" if math.isnan(value) else ("Infinity" if value > 0 else "-Infinity")
    if isinstance(value, dict):
        return {key: _finite(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_finite(item) for item in value]
    return value


def _dumps(message):
    try:
        return json.dumps(message, separators=(",", ":"), default=str, allow_nan=False)
    except ValueError:  # A number JSON has none for, somewhere in it.
        return json.dumps(_finite(message), separators=(",", ":"), default=str)


def _emit(message):
    line = _dumps(message)
    data = line.encode()
    if len(data) > MESSAGE_SIZE_MAX and "assert" in message:
        # The assertion must not be lost, nor all its details: their JSON text, cut to what
        # fits, as a string (the Zig SDK's "<details cut>"; replaced whole, a failure said
        # nothing).
        text = _dumps(message["assert"].get("details"))
        message["assert"]["details"] = ""
        room = MESSAGE_SIZE_MAX - len(_dumps(message).encode()) - 64
        cut = "<details cut> " + text
        while cut and len(json.dumps(cut).encode()) > room:
            cut = cut[:max(0, len(cut) - max(1, (len(json.dumps(cut).encode()) - room) // 2))]
        message["assert"]["details"] = cut
        data = _dumps(message).encode()
    data = data[:MESSAGE_SIZE_MAX]
    fd = _device_fd()
    if fd is None:
        local = _local_output_fd()
        if local is not None:
            os.write(local, (line + "\n").encode())
        return
    os.write(fd, data)  # One write, one event.


def output(message):
    """Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md)."""
    _emit(message)


_located = set()  # Assertions whose location this process already sent.

# Which evaluations become events: "every" one (the default: queries see each), or, as
# Antithesis's SDKs do, each assertion's "first" pass and first failure in this process (for hot
# paths: the same verdict, far fewer events). Set it once, at the start.
assertion_events = "every"
_seen = set()  # (message, condition) already sent, in "first" mode.
_best = {}  # Guidance: the smallest distance sent per message.


def _location():
    """Where the SDK was called from: the first frame outside this file."""
    frame = sys._getframe(1)
    while frame is not None and frame.f_code.co_filename == __file__:
        frame = frame.f_back
    if frame is None:
        return None
    code = frame.f_code
    location = {"file": code.co_filename, "line": frame.f_lineno, "function": code.co_name}
    # The class the function is defined in, from its qualified name (Python 3.11 and later):
    # "Ledger.audit" is Ledger's; "check.<locals>.inner" is no class's.
    owner = getattr(code, "co_qualname", "").rpartition(".")[0]
    if owner and not owner.rpartition(".")[2].startswith("<"):
        location["class"] = owner
    return location


def _assert(kind, condition, message, details):
    assert message
    if assertion_events == "first":
        if (message, bool(condition)) in _seen:
            return
        _seen.add((message, bool(condition)))
    assertion = {"type": kind, "message": message, "condition": bool(condition),
                 "details": details or {}}
    if message not in _located:  # Its location once per process: the platform keeps it.
        _located.add(message)
        location = _location()
        if location:
            assertion["location"] = location
    _emit({"assert": assertion})


def always(condition, message, details=None):
    _assert("always", condition, message, details)


def always_or_unreachable(condition, message, details=None):
    _assert("always_or_unreachable", condition, message, details)


def sometimes(condition, message, details=None):
    _assert("sometimes", condition, message, details)


def reachable(message, details=None):
    _assert("reachable", True, message, details)


def unreachable(message, details=None):
    _assert("unreachable", True, message, details)


# Guidance assertions: the compared values in the details, and a guidance event telling
# strategies how far the timeline is from the interesting outcome (an `always` violated, a
# `sometimes` true): `distance`, lower is closer, 0 or less is there.

def _guidance(message, distance):
    # NaN is nowhere; an infinite distance (an infinite operand) is the largest JSON number.
    if math.isnan(distance):
        return
    distance = max(-sys.float_info.max, min(sys.float_info.max, distance))
    # Only improvements: all a strategy needs.
    if distance >= _best.get(message, float("inf")):
        return
    _best[message] = distance
    _emit({"guidance": {"message": message, "distance": distance}})


def optimize(message, bucket, value, goal="maximize"):
    """An objective for exploration (Antithesis's "Optimizing our way through Metroid"):
    `bucket`'s strings and booleans split states into buckets (a leader, a phase), explored
    evenly, each keeping the state with the best `value` (goal "maximize" or "minimize"); the
    tree returns there and goes further from it."""
    assert goal in ("maximize", "minimize"), goal
    if not math.isfinite(value):
        return
    _emit({"optimize": {"message": message, "bucket": bucket or {}, "value": value, "goal": goal}})


def _compare(kind, holds, margin, left, right, message, details):
    merged = {"left": left, "right": right, "details": details or {}}
    _assert(kind, holds, message, merged)
    _guidance(message, margin if kind == "always" else -margin)


def always_greater_than(left, right, message, details=None):
    _compare("always", left > right, left - right, left, right, message, details)


def always_greater_than_or_equal(left, right, message, details=None):
    _compare("always", left >= right, left - right, left, right, message, details)


def always_less_than(left, right, message, details=None):
    _compare("always", left < right, right - left, left, right, message, details)


def always_less_than_or_equal(left, right, message, details=None):
    _compare("always", left <= right, right - left, left, right, message, details)


def sometimes_greater_than(left, right, message, details=None):
    _compare("sometimes", left > right, left - right, left, right, message, details)


def sometimes_greater_than_or_equal(left, right, message, details=None):
    _compare("sometimes", left >= right, left - right, left, right, message, details)


def sometimes_less_than(left, right, message, details=None):
    _compare("sometimes", left < right, right - left, left, right, message, details)


def sometimes_less_than_or_equal(left, right, message, details=None):
    _compare("sometimes", left <= right, right - left, left, right, message, details)


# Antithesis's names.
always_greater_than_or_equal_to = always_greater_than_or_equal
always_less_than_or_equal_to = always_less_than_or_equal
sometimes_greater_than_or_equal_to = sometimes_greater_than_or_equal
sometimes_less_than_or_equal_to = sometimes_less_than_or_equal


def always_some(conditions, message, details=None):
    """At least one of the named conditions (a dict of bools, all evaluated) holds, every time."""
    held = sum(1 for value in conditions.values() if value)
    _assert("always", held > 0, message, {"conditions": conditions, "details": details or {}})
    _guidance(message, held)


def sometimes_all(conditions, message, details=None):
    """All the named conditions hold together, at least once."""
    held = sum(1 for value in conditions.values() if value)
    _assert("sometimes", held == len(conditions), message,
            {"conditions": conditions, "details": details or {}})
    _guidance(message, len(conditions) - held)


# Labeled decisions: the platform's strategies see the name and the options.

def decide(name, options):
    """A named decision among options (which fault, which account, which node): returns the
    index chosen, a platform decision announced with the options' names."""
    assert options
    if _device_fd() is not None:
        _emit({"decision": {"name": name, "options": [str(option) for option in options]}})
    return random_below(len(options))


def random_below_named(name, count):
    """`random_below`, named for strategies ("retry.jitter_ms")."""
    if _device_fd() is not None:
        _emit({"decision": {"name": name, "range": count}})
    return random_below(count)


_NEAR_EDGES = ("zero", "one", "limit-1", "limit", "limit+1", "twice")


def random_near(name, limit, maximum):
    """A value up to `maximum` drawn around a limit the workload declares (a batch size, a
    buffer, a threshold): half the time uniform, else one of the limit's edges, where bugs gather
    and uniform draws seldom land: 0, 1, limit - 1, limit, limit + 1 or twice it (each kept within
    `maximum`). Named decisions (`<name>.near`, then `name`), as the Zig SDK's random_near."""
    assert maximum > 0 and limit >= 0
    if random_below_named(name + ".near", 2) == 0:
        return random_below_named(name, maximum + 1)
    edge = decide(name, _NEAR_EDGES)
    return min((0, 1, max(limit - 1, 0), limit, limit + 1, limit * 2)[edge], maximum)


# Swarm testing over a workload's operations: the Zig SDK's swarm_choice (sdk/zig/
# determinismo.zig), the same table from the same seed (FNV-1a and SplitMix64), so drivers in
# any language agree on a timeline's mix.

SWARM_SEED_PATH = "/opt/determinismo/swarm-seed"
SWARM_OPTIONS_MAX = 64
_MASK = (1 << 64) - 1
_swarm_lock = threading.Lock()
_swarm_seed = None
_swarm_runs = {}  # name -> (stretch, answer)


def _splitmix(value):
    z = (value + 0x9E3779B97F4A7C15) & _MASK
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _MASK
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _MASK
    return z ^ (z >> 31)


def swarm_hash(seed, name, stretch, what):
    """The table's draws: FNV-1a of the name, mixed with the seed, stretch and what by SplitMix64."""
    name_hash = 0xCBF29CE484222325
    for byte in name.encode():
        name_hash = ((name_hash ^ byte) * 0x100000001B3) & _MASK
    return _splitmix(_splitmix(_splitmix((seed ^ name_hash) & _MASK) ^ stretch) ^ what)


def _swarm_seed_read():
    global _swarm_seed
    if _swarm_seed is not None:
        return _swarm_seed
    try:
        with open(SWARM_SEED_PATH) as seed_file:
            _swarm_seed = int(seed_file.read().strip())
    except (OSError, ValueError):
        return None
    return _swarm_seed


def _swarm_table(seed, name, count, now_ms):
    stretch_ms = 10_000 + swarm_hash(seed, name, 0, 1) % 110_001
    stretch = now_ms // stretch_ms
    eighths = 1 + swarm_hash(seed, name, stretch, 2) % 7
    mean = (1, 4, 16, 64)[swarm_hash(seed, name, stretch, 3) % 4]
    weights = [0] * count
    for index in range(count):
        drawn = swarm_hash(seed, name, stretch, 16 + index)
        if drawn % 8 < eighths:
            weights[index] = 1 << ((drawn >> 32) % 8)
    if not any(weights):
        weights[swarm_hash(seed, name, stretch, 4) % count] = 1
    return stretch, weights, mean


def swarm_index(name, count):
    """An index below count (64 at most) by swarm testing: among the options this timeline keeps
    for the name, weighted, repeated in runs, the table changing with stretches of virtual time.
    Plain uniform outside determinismo, before the drivers, or with --no-swarm."""
    assert 0 < count <= SWARM_OPTIONS_MAX
    label = "swarm." + name
    seed = _swarm_seed_read()
    if seed is None:
        return random_below_named(label, count)
    stretch, weights, mean = _swarm_table(seed, name, count, time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000)
    with _swarm_lock:
        last = _swarm_runs.get(name)
        if last is not None and last[0] == stretch and mean > 1:
            if random_below_named(label + " run", mean) != 0:
                return last[1]
        pick = random_below_named(label, sum(weights))
        answer = 0
        for index, weight in enumerate(weights):
            if pick < weight:
                answer = index
                break
            pick -= weight
        if last is None or last[0] != stretch:
            kept = sum(1 << index for index, weight in enumerate(weights) if weight)
            event("swarm", {"name": name, "stretch": stretch, "kept": kept, "mean": mean})
        _swarm_runs[name] = (stretch, answer)
        return answer


def swarm_choice(name, options):
    """One of the options by swarm testing (swarm_index): where random_choice drew one uniformly."""
    return options[swarm_index(name, len(options))]


_buggify_lock = threading.Lock()
_buggified = {}  # name -> (random.Random, or None when inactive; end of the stretch, ns)
_BUGGIFY_PERIOD_NS = 2_000_000_000


def buggify(name):
    """A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one
    stretch of two seconds (virtual time) in four, a named decision ("buggify <name>") at the
    stretch's first evaluation; while active, it is True one evaluation in four, drawn from its own
    generator seeded by the platform for the stretch (a hot point costs a decision a stretch).
    Outside determinismo, always False. Where it is True, take a rare path the real system can
    take too (a pause, a retry), never one it cannot."""
    with _buggify_lock:
        generator = _buggify_generator(name)
        return generator is not None and generator.randrange(4) == 0


def buggify_pause(name):
    """At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
    (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
    the other threads to run in the window)."""
    with _buggify_lock:
        generator = _buggify_generator(name)
        if generator is None or generator.randrange(32) != 0:
            return
        ms = generator.randrange(10)
    if ms:
        time.sleep(ms / 1000)


def _buggify_generator(name):
    if _device_fd() is None:
        return None
    now = time.monotonic_ns()  # Virtual time inside determinismo.
    generator, until = _buggified.get(name, (None, 0))
    if now >= until:
        active = random_below_named("buggify " + name, 4) == 0
        generator = random.Random(random_u64()) if active else None
        _buggified[name] = (generator, now + _BUGGIFY_PERIOD_NS)
    return generator


def setup_complete(details=None):
    """The system is ready: the platform snapshots here and starts exploring."""
    _emit({"lifecycle": "setup_complete", "details": details or {}})


def event(name, details=None):
    """A structured event: {"event": name, "details": details}."""
    assert name
    _emit({"event": name, "details": details or {}})


send_event = event  # Antithesis's name.


_FAULTS_CONTROL = "/opt/determinismo/faults-control"  # faults.zig's control_path


def _faults_control(message):
    try:
        fd = os.open(_FAULTS_CONTROL, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return  # No injector running.
    try:
        os.write(fd, message)  # Atomic: under PIPE_BUF.
    finally:
        os.close(fd)


def stop_faults(seconds):
    """A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`,
    except clock skips; 0 ends it. Only while the fault injector runs."""
    _faults_control(int(max(seconds, 0) * 1e9).to_bytes(8, "little"))


def fault(**request):
    """A fault now, from the scenario: fault(kind="pause", node="db", duration_ms=2000),
    fault(kind="partition_groups", groups=[["runner", "a"], ["b"]], disruption="stopped").
    Applied, logged and undone like a drawn one (guest/runtime/faults.zig lists the kinds).
    Only while the fault injector runs (the drivers)."""
    body = json.dumps(request).encode()
    if len(body) + 8 > 4096:
        raise ValueError("a fault request is at most 4088 bytes")
    _faults_control(((1 << 63) | len(body)).to_bytes(8, "little") + body)


def fault_aim(node):
    """Aims the fault injector at `node` from now on, until another call ("" for none): half its
    faults involve it, each a decision strategies see and replays repeat. For the node that
    matters most at the moment (a primary, a leader), as Jepsen's nemeses target one."""
    name = node.encode()[:32]
    _faults_control(((1 << 61) | len(name)).to_bytes(8, "little") + name)


_CRASH_POINTS = "/opt/determinismo/crash-points"  # faults.zig's crash_points_path
_CRASH_POINT_FLAG = 1 << 59  # faults.zig's crash_point_flag
_CRASH_POINT_WAIT_NS = 500_000_000
_crash_points = {}
_crash_points_lock = threading.Lock()


def crash_point(name):
    """A moment worth a crash (CrashTuner's points, by hand: the node just changed its view of
    the cluster, a record is half written), as the Zig SDK's crash_point: inside determinismo and
    in a node, a point is armed one two-second stretch in eight (a named decision, "crash point
    <name>"), and its first evaluation then asks the fault injector to crash this node now and
    waits for it up to half a second. The injector grants it as one of the node's crash faults the
    swarm keeps (a kill or a power loss), outside quiet periods; where it would refuse (its
    published state), the thread goes on at once. Nothing elsewhere."""
    if _device_fd() is None:
        return
    node = os.environ.get("DETERMINISMO_NODE")
    if not node:
        return  # The runner's processes crash nothing.
    now = time.monotonic_ns()  # Virtual time inside determinismo.
    with _crash_points_lock:
        armed, until = _crash_points.get(name, (False, 0))
        if now >= until:
            armed = random_below_named("crash point " + name, 8) == 0
            until = now + _BUGGIFY_PERIOD_NS
        _crash_points[name] = (False, until)  # Once a stretch.
    if not armed or not _crash_point_open(node, now):
        return
    body = ("%d %s\npoint %s" % (now, node, name)).encode()[:4000]
    _faults_control((_CRASH_POINT_FLAG | len(body)).to_bytes(8, "little") + body)
    while time.monotonic_ns() - now < _CRASH_POINT_WAIT_NS:
        time.sleep(0.005)


def _crash_point_open(node, now):
    """Whether the injector may grant `node` a crash point now (the end of a quiet period, then
    the nodes whose crash faults the swarm keeps, a line each)."""
    try:
        with open(_CRASH_POINTS) as state:
            lines = state.read().split("\n")
    except OSError:
        return False
    try:
        if now < int(lines[0]):
            return False
    except ValueError:
        return False
    return node in lines[1:]


def _coverage_set(text):
    """A coverage set's included and excluded prefixes, as tuples ("a,b,-c")."""
    entries = [entry for entry in text.split(",") if entry and entry != "-"]
    return (tuple(entry for entry in entries if not entry.startswith("-")),
            tuple(entry[1:] for entry in entries if entry.startswith("-")))


def coverage_start(paths=None):
    """Code coverage for strategies (Python 3.12+): from now on, each line of code under `paths`
    (prefixes of file names; None for every file but this SDK's) emits a "coverage" event the
    first time this process runs it, as the C and Zig SDKs do for edges. Strategies such as
    det-strategy-mutate keep the timelines that reach new code. A line costs nothing once
    reported: sys.monitoring stops watching it, except where thread pausing pauses (inside
    determinismo, _pausing_stretches). Branches are points for thread pausing too (where a
    conditional branch went, before its destination runs): a check and its act on one line
    (`if x == 0: x += 1`) have a point between them, as with edge instrumentation. The node's
    coverage set, DETERMINISMO_COVERAGE (file name prefixes, those starting with "-" excluded: the
    Zig SDK's schema.Coverage), narrows it further: a test program's profile scopes it."""
    monitoring = sys.monitoring
    tool = monitoring.COVERAGE_ID
    monitoring.use_tool_id(tool, "determinismo")
    prefixes = tuple(paths) if paths else None
    included, excluded = _coverage_set(os.environ.get("DETERMINISMO_COVERAGE", ""))
    reported = set()
    local = threading.local()

    def outside(file):
        return (file == __file__ or (prefixes is not None and not file.startswith(prefixes))
                or (excluded and file.startswith(excluded))
                or (included and not file.startswith(included)))

    def line(code, number):
        file = code.co_filename
        if outside(file):
            return monitoring.DISABLE
        key = f"{file}:{number}"
        if key not in reported:
            reported.add(key)
            event("coverage", {"name": f"line {key}"})
        return pausing(key)

    def branch(code, offset, destination):
        file = code.co_filename
        if outside(file):
            return monitoring.DISABLE
        return pausing(f"{file}@{offset}>{destination}")

    def pausing(key):
        seed = _pausing["seed"]
        if not seed:
            return monitoring.DISABLE
        value = _pausing_mix(seed ^ zlib.crc32(key.encode()))
        if value % 64:
            return monitoring.DISABLE  # Not a slow point this stretch.
        stretch = _pausing["stretch"]
        if getattr(local, "stretch", None) != stretch:
            local.stretch, local.pauses = stretch, 0
        if local.pauses < _PAUSING_PAUSES_MAX:  # Others may still pause here.
            local.pauses += 1
            time.sleep((1 + (value >> 8) % 10) / 1000)
        return None

    events = monitoring.events
    # 3.14 tells a branch's two ways apart (BRANCH_LEFT, BRANCH_RIGHT); 3.12 and 3.13 have BRANCH.
    branches = [getattr(events, name) for name in ("BRANCH_LEFT", "BRANCH_RIGHT")
                if hasattr(events, name)] or [events.BRANCH]
    monitoring.register_callback(tool, events.LINE, line)
    watched = events.LINE
    if _device_fd() is not None:
        for kind in branches:
            monitoring.register_callback(tool, kind, branch)
            watched |= kind
    monitoring.set_events(tool, watched)
    if _device_fd() is not None:
        threading.Thread(target=_pausing_stretches, args=(monitoring,),
                         name="determinismo-pausing", daemon=True).start()


# Thread pausing (Antithesis's, which needs their instrumentation too), the C SDK's
# det_pausing_at: inside determinismo, one stretch of two seconds (virtual time) in four, a named
# decision ("thread pausing") at the stretch's start, one line in 64 is a slow point with its own
# pause (1 to 10 ms), drawn for the stretch: a thread reaching one waits there, at most 8 times a
# stretch. Threads that reach a slow point wait there together, so the checks of a
# check-then-act between them all run before any of its acts. A thread of the SDK starts each
# stretch, and an active one turns every line's monitoring back on: lines that are no slow point
# turn theirs off again at their next run.
_PAUSING_PAUSES_MAX = 8
_pausing = {"seed": 0, "stretch": 0}


def _pausing_mix(value):
    value = (value * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    value ^= value >> 29
    value = (value * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
    return value ^ (value >> 32)


def _pausing_stretches(monitoring):
    while True:
        seed = random_u64() | 1 if random_below_named("thread pausing", 4) == 0 else 0
        _pausing["seed"], _pausing["stretch"] = seed, _pausing["stretch"] + 1
        if seed:
            monitoring.restart_events()
        time.sleep(2)


# The assertion catalog ---------------------------------------------------------------------

_KINDS = ("always", "always_or_unreachable", "sometimes", "reachable", "unreachable")
# Guidance assertions: their kind, and where their message is among the arguments.
_GUIDED = {name: ("always" if name.startswith("always") else "sometimes", position)
           for name, position in [(f"{kind}_{relation}", 2)
                                  for kind in ("always", "sometimes")
                                  for relation in ("greater_than_or_equal_to",
                                                   "less_than_or_equal_to",
                                                   "greater_than", "greater_than_or_equal",
                                                   "less_than", "less_than_or_equal")]
           + [("always_some", 1), ("sometimes_all", 1)]}
_declared = {}  # (kind, message) -> the file it is in (None: declare()'s)
_scanned = set()
_announcing = False  # Inside determinismo, declared assertions are announced as they are.


def declare(kind, message, file=None):
    """Announces an assertion before it runs: one never reached is judged too. Assertions with
    literal messages are announced already."""
    if (kind, message) in _declared:
        return
    _declared[(kind, message)] = file
    if _announcing:
        _emit({"assert": {"type": kind, "message": message, "hit": False}})


def catalog_assertions():
    """The assertions the program declares so far (its loaded modules' and declare()'s): a list
    of {"kind", "message", "file"}."""
    return [{"kind": kind, "message": message, "file": file}
            for (kind, message), file in _declared.items()]


def catalog_write(stream=None):
    """Writes the catalog, one JSON object a line, to `stream` (stdout by default): what a
    program checks, for review or CI."""
    stream = stream or sys.stdout
    for entry in catalog_assertions():
        stream.write(json.dumps(entry) + "\n")


def catalog(filename):
    """Announces the assertions of `filename` (a module this SDK did not see run)."""
    _catalog_source(os.path.abspath(filename))


_TREE_SKIPPED = {"__pycache__", "node_modules", "venv", ".venv", "site-packages"}


def catalog_tree(root):
    """Announces the assertions of every Python file under `root` (Antithesis's
    catalog.scan_tree): a program's whole catalog, the modules it never imports included."""
    for directory, names, files in os.walk(root):
        names[:] = sorted(name for name in names if not name.startswith(".") and name not in _TREE_SKIPPED)
        for name in sorted(files):
            if name.endswith(".py"):
                catalog(os.path.join(directory, name))


def _catalog_source(filename):
    """Declares the assertions of a source file: calls to this SDK's assertions (through the
    names the file binds to it) whose message is a literal."""
    if filename in _scanned or filename == __file__ or not filename.endswith(".py"):
        return
    _scanned.add(filename)
    try:
        with open(filename, encoding="utf-8") as source:
            tree = ast.parse(source.read(), filename)
    except (OSError, SyntaxError, ValueError):
        return
    modules = set()  # Names of this module: `import determinismo as det`.
    direct = {}  # Names of its assertions: `from determinismo import sometimes as s`.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(a.asname or a.name for a in node.names if a.name == "determinismo")
        elif isinstance(node, ast.ImportFrom) and node.module == "determinismo":
            direct.update((a.asname or a.name, a.name) for a in node.names
                          if a.name in _KINDS or a.name in _GUIDED)
    if not modules and not direct:
        return
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        if (isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name)
                and function.value.id in modules):
            called = function.attr
        elif isinstance(function, ast.Name) and function.id in direct:
            called = direct[function.id]
        else:
            continue
        if called in _GUIDED:
            kind, position = _GUIDED[called]
        elif called in _KINDS:
            kind = called
            position = 0 if kind in ("reachable", "unreachable") else 1
        else:
            continue
        message = node.args[position] if len(node.args) > position else next(
            (keyword.value for keyword in node.keywords if keyword.arg == "message"), None)
        if isinstance(message, ast.Constant) and isinstance(message.value, str):
            declare(kind, message.value, filename)


def _catalog_hook(name, arguments):
    # Every module's code goes through exec as it runs: imported, run as a script, or exec'd.
    if name == "exec" and arguments and hasattr(arguments[0], "co_filename"):
        _catalog_source(arguments[0].co_filename)


def _catalog_start():
    global _announcing
    # Outside determinismo too: catalog_assertions() lists them, but nothing is announced.
    _announcing = _device_fd() is not None
    for module in list(sys.modules.values()):  # Those that ran before this SDK was imported.
        filename = getattr(module, "__file__", None)
        if filename:
            _catalog_source(filename)
    sys.addaudithook(_catalog_hook)


_catalog_start()


def _main(arguments):
    """python3 -m determinismo catalog <file or directory>...: the assertion catalog of a source
    tree, one JSON object a line ({"kind", "message", "file"}), for review or CI (Antithesis's
    catalog module, to view a catalog locally).
    python3 -m determinismo run <script> [argument]...: the script with code coverage on from its
    first line (coverage_start, Python 3.12+: its directory's files, or the node's coverage set),
    as Antithesis's `python -m antithesis` launches an application with coverage guidance, the
    program unchanged."""
    if len(arguments) >= 2 and arguments[0] == "catalog":
        for path in arguments[1:]:
            if os.path.isdir(path):
                catalog_tree(path)
            else:
                catalog(path)
        catalog_write()
        return 0
    if len(arguments) >= 2 and arguments[0] == "run":
        import runpy
        script = arguments[1]
        sys.argv = arguments[1:]
        home = os.path.dirname(os.path.abspath(script))
        sys.path.insert(0, home)
        # The application's own code: its directory's, unless the node's coverage set says
        # (the interpreter's library, runpy's first, is noise to guidance).
        coverage_start(None if os.environ.get("DETERMINISMO_COVERAGE") else [home + os.sep])
        runpy.run_path(os.path.abspath(script), run_name="__main__")  # Its code's file names absolute.
        return 0
    sys.stderr.write("usage: python3 -m determinismo catalog <file or directory>...\n"
                     "       python3 -m determinismo run <script> [argument]...\n")
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
