// SPDX-License-Identifier: MIT
/**
 * determinismo SDK for JavaScript (Node.js 18+): assertions, events and platform randomness.
 *
 * Inside determinismo everything goes through /dev/determinismo: events are recorded with their
 * moment, and every random value is a decision the platform can steer and replay. Outside it
 * (local runs) randomness comes from the OS and events go to the local output file, if one is
 * named (below), so the same code runs everywhere. One file, no dependencies: copy it next to your code, or depend on this directory.
 *
 *     const det = require("determinismo");
 *     const account = det.randomBelow(10);
 *     det.always(total === 1000, "total balance is conserved", { total });
 *
 * The assertion catalog: every assertion with a literal message is announced when its module's
 * code loads (CommonJS, TypeScript's compiled output included), before the assertion itself
 * runs (Antithesis's catalog), so one no timeline reaches is judged too. Modules this SDK cannot
 * see load (ES modules, bundles) announce theirs with `catalog(file)`; a message computed at run
 * time is known once it runs.
 *
 * The same API as the other SDKs (sdk/python, sdk/c, sdk/zig, sdk/java, sdk/clojure, sdk/rust; see
 * docs/SDKS.md), in JavaScript's names: randomBytes, randomU64 (a BigInt), randomBelow,
 * randomChoice, random, rng, prng; decide, randomBelowNamed; buggify, buggifyPause; always,
 * alwaysOrUnreachable, sometimes, reachable, unreachable, the guidance comparisons, alwaysSome,
 * sometimesAll, setAssertionEvents; declare, catalog, catalogAssertions, catalogWrite;
 * setupComplete, event, output; stopFaults, fault; coverageStart. Antithesis's TypeScript SDK's
 * names work too (alwaysGreaterThanOrEqualTo, sendEvent, ...): its code runs unchanged.
 *
 * Outside determinismo, events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT names (or
 * Antithesis's ANTITHESIS_SDK_LOCAL_OUTPUT), one JSON object a line, else nowhere (Antithesis's
 * default: assertions evaluated, nothing written).
 */
"use strict";

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const DEVICE_PATH = "/dev/determinismo";
const MESSAGE_SIZE_MAX = 4096 - 16; // One event or one randomness pull per device call.
const FAULTS_CONTROL = "/opt/determinismo/faults-control"; // faults.zig's control_path

let device = null;
let deviceOpened = false;

function deviceFd() {
  if (!deviceOpened) {
    deviceOpened = true;
    try {
      device = fs.openSync(DEVICE_PATH, "r+");
    } catch {
      device = null; // Not inside determinismo.
    }
  }
  return device;
}

/** Whether this process runs inside determinismo. */
function inside() {
  return deviceFd() !== null;
}

// Randomness -------------------------------------------------------------------------------

/** `count` random bytes (a Buffer): a platform decision inside determinismo. */
function randomBytes(count) {
  if (!(count > 0 && count <= MESSAGE_SIZE_MAX)) throw new RangeError(`randomBytes: ${count} bytes`);
  const fd = deviceFd();
  if (fd === null) return crypto.randomBytes(count);
  const data = Buffer.alloc(count);
  const read = fs.readSync(fd, data, 0, count, null);
  if (read !== count) throw new Error(`randomBytes: the platform gave ${read} of ${count} bytes`);
  return data;
}

/** A random 64-bit unsigned integer, as a BigInt. */
function randomU64() {
  return randomBytes(8).readBigUInt64LE(0);
}

/** A uniformly random integer in [0, count): a Number (count a Number) or a BigInt. */
function randomBelow(count) {
  if (typeof count === "bigint") {
    if (count <= 0n) throw new RangeError("randomBelow: count must be positive");
    return randomU64() % count;
  }
  if (!(Number.isSafeInteger(count) && count > 0)) throw new RangeError(`randomBelow: ${count}`);
  return Number(randomU64() % BigInt(count));
}

/** One of the items, a platform decision; undefined when there are none (as Antithesis's
 *  randomChoice, and the other SDKs: Go's zero value, Rust's None, Java's null). */
function randomChoice(items) {
  if (items.length === 0) return undefined;
  return items[randomBelow(items.length)];
}

/** A float in [0, 1) from 53 random bits. */
function unitFloat(u64) {
  return Number(u64 >> 11n) / 2 ** 53;
}

/** A float in [0, 1), as Math.random: a platform decision. */
function random() {
  return unitFloat(randomU64());
}

/** Draws for code that takes a generator: each a platform decision (steerable, replayed from
 * tapes); one request to the platform per draw. For hot loops, prng(). */
function rng() {
  return generator(() => randomU64());
}

/** A generator the platform seeds once (SplitMix64): draws cost nothing, and replay with the
 * seed. */
function prng() {
  let state = randomU64();
  return generator(() => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    return z ^ (z >> 31n);
  });
}

function generator(nextU64) {
  return {
    nextU64,
    /** A float in [0, 1), as Math.random. */
    random: () => unitFloat(nextU64()),
    below(count) {
      if (typeof count === "bigint") return nextU64() % count;
      return Number(nextU64() % BigInt(count));
    },
    choice(items) {
      if (items.length === 0) return undefined;
      return items[this.below(items.length)];
    },
    /** Shuffles `items` in place (Fisher-Yates) and returns it. */
    shuffle(items) {
      for (let index = items.length - 1; index > 0; index--) {
        const other = this.below(index + 1);
        [items[index], items[other]] = [items[other], items[index]];
      }
      return items;
    },
  };
}

// Events -----------------------------------------------------------------------------------

/** JSON text of `value`, BigInts as JSON integers (their digits, not a rounded Number), else as
 * JSON.stringify does (escaping, toJSON, undefined left out). */
function toJson(value) {
  if (typeof value === "bigint") return value.toString();
  if (typeof value !== "object" || value === null) return JSON.stringify(value);
  if (value instanceof Error) return toJson({ name: value.name, message: value.message });
  if (typeof value.toJSON === "function") return toJson(value.toJSON());
  if (Array.isArray(value)) return `[${value.map((item) => toJson(item) ?? "null").join(",")}]`;
  const members = [];
  for (const [key, item] of Object.entries(value)) {
    const encoded = toJson(item);
    if (encoded !== undefined) members.push(`${JSON.stringify(key)}:${encoded}`);
  }
  return `{${members.join(",")}}`;
}

let localOutput; // Outside determinismo: the local output file's descriptor, null for none.

function localOutputFd() {
  if (localOutput === undefined) {
    localOutput = null;
    const file = process.env.DETERMINISMO_SDK_LOCAL_OUTPUT || process.env.ANTITHESIS_SDK_LOCAL_OUTPUT;
    if (file) {
      try {
        localOutput = fs.openSync(file, "a");
      } catch {
        localOutput = null;
      }
    }
  }
  return localOutput;
}

function emit(message) {
  const line = toJson(message);
  let data = Buffer.from(line);
  if (data.length > MESSAGE_SIZE_MAX && message.assert) {
    // The assertion must not be lost, nor all its details: their JSON text, cut to what fits,
    // as a string (the Zig SDK's "<details cut>"; replaced whole, a failure said nothing).
    const text = toJson(message.assert.details);
    message.assert.details = "";
    const room = MESSAGE_SIZE_MAX - Buffer.byteLength(toJson(message)) - 64;
    let cut = "<details cut> " + text;
    // Whole characters, as JSON escapes them, within the room left.
    while (cut.length > 0 && Buffer.byteLength(toJson(cut)) > room) cut = cut.slice(0, Math.max(0, cut.length - Math.max(1, (Buffer.byteLength(toJson(cut)) - room) >> 1)));
    if (cut.length > 0 && cut.charCodeAt(cut.length - 1) >= 0xd800 && cut.charCodeAt(cut.length - 1) < 0xdc00) cut = cut.slice(0, -1);
    message.assert.details = cut;
    data = Buffer.from(toJson(message));
  }
  if (data.length > MESSAGE_SIZE_MAX) data = data.subarray(0, MESSAGE_SIZE_MAX);
  const fd = deviceFd();
  if (fd === null) {
    const local = localOutputFd();
    if (local !== null) fs.writeSync(local, line + "\n");
    return;
  }
  fs.writeSync(fd, data); // One write, one event.
}

/** Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md). */
function output(object) {
  emit(object);
}

/** The system is ready: the platform snapshots here and starts exploring. */
function setupComplete(details) {
  emit({ lifecycle: "setup_complete", details: details || {} });
}

/** A structured event: {"event": name, "details": details}. */
/** This timeline's state looks hopeless for finding anything more (a cluster wedged by a known bug,
 * a workload that cannot progress): the explorer weighs returns after this moment down, by a share
 * it draws each generation (never excluded). The first call in a timeline counts. */
function doomed(message, details) {
  event("doomed", { message: String(message), details: details || {} });
}

function event(name, details) {
  if (!name) throw new RangeError("event: a name");
  emit({ event: name, details: details || {} });
}

// Assertions -------------------------------------------------------------------------------

// Which evaluations become events: "every" one (the default: queries see each), or, as
// Antithesis's SDKs do, each assertion's "first" pass and first failure in this process (for hot
// paths: the same verdict, far fewer events). Set it once, at the start.
let assertionEvents = "every";
const seen = new Set(); // `${condition}\u0000${message}` already sent, in "first" mode.
const located = new Set(); // Assertions whose location this process already sent.
const best = new Map(); // Guidance: the smallest distance sent per message.

function setAssertionEvents(mode) {
  if (mode !== "every" && mode !== "first") throw new RangeError(`assertion events: ${mode}`);
  assertionEvents = mode;
}

/** Where the SDK was called from: the first stack frame outside this file. */
function location() {
  const stack = new Error().stack.split("\n").slice(1);
  for (const frame of stack) {
    const match = frame.match(/at (?:(.*?) \()?(.*?):(\d+):\d+\)?$/);
    if (!match || match[2] === __filename) continue;
    const at = { file: match[2], line: Number(match[3]), function: match[1] || "" };
    const owner = classOf(at.function);
    if (owner) at.class = owner;
    return at;
  }
  return null;
}

/** The class a stack frame's function belongs to, from V8's name for it: "Ledger.audit",
 *  "async Ledger.audit", "new Ledger" and "Ledger.audit [as check]" are Ledger's; "audit",
 *  and a module's top level ("Object.<anonymous>"), are no class's. */
function classOf(name) {
  const bare = name.replace(/ \[as [^\]]*\]$/, "").replace(/^async /, "");
  if (bare.startsWith("new ")) return bare.slice(4) || null;
  const dot = bare.lastIndexOf(".");
  if (dot <= 0) return null;
  const owner = bare.slice(0, dot);
  return owner === "Object" || owner === "Function" ? null : owner;
}

function assertion(kind, condition, message, details) {
  if (!message) throw new RangeError("an assertion needs a message");
  const holds = Boolean(condition);
  if (assertionEvents === "first") {
    const key = `${holds}\u0000${message}`;
    if (seen.has(key)) return;
    seen.add(key);
  }
  const body = { type: kind, message, condition: holds, details: details || {} };
  if (!located.has(message)) {
    // Its location once per process: the platform keeps it.
    located.add(message);
    const at = location();
    if (at) body.location = at;
  }
  emit({ assert: body });
}

function always(condition, message, details) {
  assertion("always", condition, message, details);
}

function alwaysOrUnreachable(condition, message, details) {
  assertion("always_or_unreachable", condition, message, details);
}

function sometimes(condition, message, details) {
  assertion("sometimes", condition, message, details);
}

function reachable(message, details) {
  assertion("reachable", true, message, details);
}

function unreachable(message, details) {
  assertion("unreachable", true, message, details);
}

// Guidance assertions: the compared values in the details, and a guidance event telling
// strategies how far the timeline is from the interesting outcome (an `always` violated, a
// `sometimes` true): `distance`, lower is closer, 0 or less is there.

function guidance(message, distance) {
  // NaN is nowhere; an infinite distance (an infinite operand) is the largest JSON number
  // (JSON.stringify makes it null, no distance at all).
  if (Number.isNaN(distance)) return;
  distance = Math.max(-Number.MAX_VALUE, Math.min(Number.MAX_VALUE, distance));
  const known = best.get(message);
  if (known !== undefined && distance >= known) return; // Only improvements.
  best.set(message, distance);
  emit({ guidance: { message, distance } });
}

/**
 * An objective for exploration (Antithesis's "Optimizing our way through Metroid"): `bucket`'s
 * strings and booleans split states into buckets (a leader, a phase), explored evenly, each
 * keeping the state with the best `value` by `goal` ("maximize" or "minimize"); the tree returns
 * there and goes further from it.
 */
function optimize(message, bucket, value, goal = "maximize") {
  if (goal !== "maximize" && goal !== "minimize") throw new RangeError(`optimize: a goal, not ${goal}`);
  const number = Number(value);
  if (!Number.isFinite(number)) return;
  emit({ optimize: { message, bucket: bucket || {}, value: number, goal } });
}

function difference(a, b) {
  return typeof a === "bigint" || typeof b === "bigint" ? Number(BigInt(a) - BigInt(b)) : a - b;
}

// A comparison's operand as JSON. JSON has no infinity or NaN (JSON.stringify makes them null,
// which says nothing), so those are the strings "Infinity", "-Infinity" and "NaN", as every SDK
// of ours sends them.
function operand(value) {
  if (typeof value !== "number" || Number.isFinite(value)) return value;
  return Number.isNaN(value) ? "NaN" : value > 0 ? "Infinity" : "-Infinity";
}

function compare(kind, holds, margin, left, right, message, details) {
  assertion(kind, holds, message, { left: operand(left), right: operand(right), details: details || {} });
  guidance(message, kind === "always" ? margin : -margin);
}

function alwaysGreaterThan(left, right, message, details) {
  compare("always", left > right, difference(left, right), left, right, message, details);
}

function alwaysGreaterThanOrEqual(left, right, message, details) {
  compare("always", left >= right, difference(left, right), left, right, message, details);
}

function alwaysLessThan(left, right, message, details) {
  compare("always", left < right, difference(right, left), left, right, message, details);
}

function alwaysLessThanOrEqual(left, right, message, details) {
  compare("always", left <= right, difference(right, left), left, right, message, details);
}

function sometimesGreaterThan(left, right, message, details) {
  compare("sometimes", left > right, difference(left, right), left, right, message, details);
}

function sometimesGreaterThanOrEqual(left, right, message, details) {
  compare("sometimes", left >= right, difference(left, right), left, right, message, details);
}

function sometimesLessThan(left, right, message, details) {
  compare("sometimes", left < right, difference(right, left), left, right, message, details);
}

function sometimesLessThanOrEqual(left, right, message, details) {
  compare("sometimes", left <= right, difference(right, left), left, right, message, details);
}

/** At least one of the named conditions (an object of booleans, all evaluated) holds, every
 * time. */
function alwaysSome(conditions, message, details) {
  const held = Object.values(conditions).filter(Boolean).length;
  assertion("always", held > 0, message, { conditions, details: details || {} });
  guidance(message, held);
}

/** All the named conditions hold together, at least once. */
function sometimesAll(conditions, message, details) {
  const values = Object.values(conditions);
  const held = values.filter(Boolean).length;
  assertion("sometimes", held === values.length, message, { conditions, details: details || {} });
  guidance(message, values.length - held);
}

// Labeled decisions: the platform's strategies see the name and the options.

/** A named decision among options (which fault, which account, which node): returns the index
 * chosen, a platform decision announced with the options' names. */
function decide(name, options) {
  if (options.length === 0) throw new RangeError("decide: no options");
  if (inside()) emit({ decision: { name, options: options.map(String) } });
  return randomBelow(options.length);
}

/** randomBelow, named for strategies ("retry.jitter_ms"). */
function randomBelowNamed(name, count) {
  if (inside()) emit({ decision: { name, range: typeof count === "bigint" ? count.toString() : count } });
  return randomBelow(count);
}

const NEAR_EDGES = ["zero", "one", "limit-1", "limit", "limit+1", "twice"];

/**
 * A value up to `max` drawn around a limit the workload declares (a batch size, a buffer, a
 * threshold): half the time uniform, else one of the limit's edges, where bugs gather and uniform
 * draws seldom land: 0, 1, limit - 1, limit, limit + 1 or twice it (each kept within `max`).
 * Named decisions (`<name>.near`, then `name`), as the Zig SDK's random_near. Numbers (safe
 * integers).
 */
function randomNear(name, limit, max) {
  if (!(max > 0) || !(limit >= 0)) throw new RangeError("randomNear: max must be positive, limit not negative");
  if (randomBelowNamed(name + ".near", 2) === 0) return randomBelowNamed(name, max + 1);
  const edge = decide(name, NEAR_EDGES);
  return Math.min([0, 1, Math.max(limit - 1, 0), limit, limit + 1, limit * 2][edge], max);
}

// Swarm testing over a workload's operations: the Zig SDK's swarm_index (sdk/zig/
// determinismo.zig), the same table from the same seed (FNV-1a and SplitMix64), so drivers in
// any language agree on a timeline's mix.
const SWARM_SEED_PATH = "/opt/determinismo/swarm-seed";
const MASK64 = (1n << 64n) - 1n;
let swarmSeedCached = null;
const swarmRuns = new Map(); // name -> { stretch, answer }

function swarmMix(value) {
  let z = (value + 0x9E3779B97F4A7C15n) & MASK64;
  z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
  z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
  return z ^ (z >> 31n);
}

/** The table's draws: FNV-1a of the name, mixed with the seed, stretch and what by SplitMix64. */
function swarmHash(seed, name, stretch, what) {
  let nameHash = 0xCBF29CE484222325n;
  for (const byte of Buffer.from(name, "utf8")) nameHash = ((nameHash ^ BigInt(byte)) * 0x100000001B3n) & MASK64;
  return swarmMix(swarmMix(swarmMix((BigInt(seed) ^ nameHash) & MASK64) ^ BigInt(stretch)) ^ BigInt(what));
}

function swarmSeed() {
  if (swarmSeedCached !== null) return swarmSeedCached;
  try {
    swarmSeedCached = BigInt(fs.readFileSync(SWARM_SEED_PATH, "utf8").trim());
  } catch {
    return null;
  }
  return swarmSeedCached;
}

/** An index below count (64 at most) by swarm testing: among the options this timeline keeps for
 * the name, weighted and repeated in runs, the table changing with stretches of virtual time.
 * Plain uniform outside determinismo, before the drivers, or with --no-swarm. */
function swarmIndex(name, count) {
  if (!(count > 0 && count <= 64)) throw new RangeError("swarmIndex: 1 to 64 options");
  const label = "swarm." + name;
  const seed = swarmSeed();
  if (seed === null) return randomBelowNamed(label, count);
  const nowMs = process.hrtime.bigint() / 1000000n; // CLOCK_MONOTONIC on Linux, as the other SDKs.
  const stretch = nowMs / (10000n + (swarmHash(seed, name, 0n, 1n) % 110001n));
  const eighths = 1n + (swarmHash(seed, name, stretch, 2n) % 7n);
  const mean = [1, 4, 16, 64][Number(swarmHash(seed, name, stretch, 3n) % 4n)];
  const weights = new Array(count).fill(0);
  let kept = 0n;
  for (let i = 0; i < count; i++) {
    const drawn = swarmHash(seed, name, stretch, 16n + BigInt(i));
    if (drawn % 8n >= eighths) continue;
    weights[i] = 1 << Number((drawn >> 32n) % 8n);
    kept |= 1n << BigInt(i);
  }
  if (kept === 0n) {
    const i = Number(swarmHash(seed, name, stretch, 4n) % BigInt(count));
    weights[i] = 1;
    kept = 1n << BigInt(i);
  }
  const total = weights.reduce((sum, weight) => sum + weight, 0);
  const run = swarmRuns.get(name);
  if (run && run.stretch === stretch && mean > 1 && randomBelowNamed(label + " run", mean) !== 0) return run.answer;
  let pick = randomBelowNamed(label, total);
  let answer = 0;
  for (let i = 0; i < count; i++) {
    if (pick < weights[i]) {
      answer = i;
      break;
    }
    pick -= weights[i];
  }
  if (!run || run.stretch !== stretch) event("swarm", { name, stretch, kept, mean });
  swarmRuns.set(name, { stretch, answer });
  return answer;
}

/** One of the items by swarm testing (swarmIndex), where randomChoice drew one uniformly. */
function swarmChoice(name, items) {
  return items[swarmIndex(name, items.length)];
}

const buggified = new Map(); // name -> { generator (null when inactive), until (ns) }
const BUGGIFY_PERIOD_NS = 2000000000n;

/** A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
 * of two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's
 * first evaluation; while active, it is true one evaluation in four, drawn from its own generator
 * seeded by the platform for the stretch (a hot point costs a decision a stretch). Outside
 * determinismo, always false. Where it is true, take a rare path the real system can take too (a
 * pause, a retry), never one it cannot. */
function buggify(name) {
  const generator = buggifyGenerator(name);
  return generator !== null && generator.below(4) === 0;
}

/** At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
 * (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
 * the others to run in the window). Synchronous (it blocks the event loop, as a slow call does);
 * buggifyPauseAsync awaits instead. */
function buggifyPause(name) {
  const ms = buggifyPauseMs(name);
  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** buggifyPause for async code: resolves at once, or after the pause. */
function buggifyPauseAsync(name) {
  const ms = buggifyPauseMs(name);
  return new Promise((resolve) => (ms > 0 ? setTimeout(resolve, ms) : resolve()));
}

function buggifyPauseMs(name) {
  const generator = buggifyGenerator(name);
  if (generator === null || generator.below(32) !== 0) return 0;
  return generator.below(10);
}

function buggifyGenerator(name) {
  if (!inside()) return null;
  const now = process.hrtime.bigint(); // Virtual time inside determinismo.
  let point = buggified.get(name);
  if (!point || now >= point.until) {
    const active = randomBelowNamed("buggify " + name, 4) === 0;
    point = { generator: active ? prng() : null, until: now + BUGGIFY_PERIOD_NS };
    buggified.set(name, point);
  }
  return point.generator;
}

// The fault injector ------------------------------------------------------------------------

function faultsControl(message) {
  let fd;
  try {
    fd = fs.openSync(FAULTS_CONTROL, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
  } catch {
    return; // No injector running.
  }
  try {
    fs.writeSync(fd, message); // Atomic: under PIPE_BUF.
  } finally {
    fs.closeSync(fd);
  }
}

/** A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`, except
 * clock skips; 0 ends it. Only while the fault injector runs. */
function stopFaults(seconds) {
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE(BigInt(Math.round(Math.max(seconds, 0) * 1e9)));
  faultsControl(header);
}

/** A fault now, from the scenario: fault({ kind: "pause", node: "db", duration_ms: 2000 }),
 * fault({ kind: "partition_groups", groups: [["runner", "a"], ["b"]], disruption: "stopped" }).
 * Applied, logged and undone like a drawn one (guest/runtime/faults.zig lists the kinds). Only
 * while the fault injector runs (the drivers). */
function fault(request) {
  const body = Buffer.from(JSON.stringify(request));
  if (body.length + 8 > 4096) throw new RangeError("a fault request is at most 4088 bytes");
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE((1n << 63n) | BigInt(body.length));
  faultsControl(Buffer.concat([header, body]));
}

/** Aims the fault injector at `node` from now on, until another call ("" for none): half its
 * faults involve it, each a decision strategies see and replays repeat (a primary, a leader). */
function faultAim(node) {
  const name = Buffer.from(node).subarray(0, 32);
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE((1n << 61n) | BigInt(name.length));
  faultsControl(Buffer.concat([header, name]));
}

const crashPoints = new Map();

/** A moment worth a crash (the Zig SDK's crash_point: the node just changed its view of the
 * cluster, a record is half written): inside determinismo and in a node, a point is armed one
 * two-second stretch in eight (a named decision, "crash point <name>"), and its first evaluation
 * then asks the fault injector to crash this node now and waits for it, up to half a second (the
 * thread blocked: what the crash finds is this moment). Refused at once where the injector's
 * published state says it would refuse. */
function crashPoint(name) {
  if (!inside()) return;
  const node = process.env.DETERMINISMO_NODE;
  if (!node) return; // The runner's processes crash nothing.
  const now = process.hrtime.bigint(); // CLOCK_MONOTONIC: virtual time inside determinismo.
  let point = crashPoints.get(name);
  if (!point || now >= point.until) {
    point = { armed: randomBelowNamed("crash point " + name, 8) === 0, until: now + BUGGIFY_PERIOD_NS };
  }
  const armed = point.armed;
  crashPoints.set(name, { armed: false, until: point.until }); // Once a stretch.
  if (!armed || !crashPointOpen(node, now)) return;
  const body = Buffer.from(`${now} ${node}\npoint ${name}`).subarray(0, 4000);
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE((1n << 59n) | BigInt(body.length)); // faults.zig's crash_point_flag
  faultsControl(Buffer.concat([header, body]));
  const wait = new Int32Array(new SharedArrayBuffer(4));
  while (process.hrtime.bigint() - now < 500000000n) Atomics.wait(wait, 0, 0, 5);
}

/** Whether the injector may grant `node` a crash point now: the end of a quiet period, then the
 * nodes whose crash faults the swarm keeps, a line each (faults.zig's crash_points_path). */
function crashPointOpen(node, now) {
  let lines;
  try {
    lines = fs.readFileSync("/opt/determinismo/crash-points", "utf8").split("\n");
  } catch {
    return false;
  }
  let quietUntil;
  try {
    quietUntil = BigInt(lines[0]);
  } catch {
    return false;
  }
  return now >= quietUntil && lines.slice(1).includes(node);
}

// Code coverage ----------------------------------------------------------------------------

/** Where a block of a script starts, as a coverage name: `line <file>:<n>` (its source's file and
 * line through the script's source map when it has one, as Antithesis's JavaScript
 * instrumentation follows them: TypeScript's lines, not the compiled file's), so that targeted
 * runs (`--changed`) match a change's lines; `block <file>:<offset>` for a file it cannot read.
 * `files` caches each file's line starts. */
function coverageLine(file, offset, files) {
  let starts = files.get(file);
  if (starts === undefined) {
    starts = null;
    try {
      const text = require("fs").readFileSync(file, "utf8");
      starts = [0];
      for (let at = text.indexOf("\n"); at >= 0; at = text.indexOf("\n", at + 1)) starts.push(at + 1);
    } catch { /* Not a file: an internal module, an eval. */ }
    files.set(file, starts);
  }
  if (!starts) return `block ${file}:${offset}`;
  let low = 0, high = starts.length - 1;
  while (low < high) {
    const middle = (low + high + 1) >> 1;
    if (starts[middle] <= offset) low = middle; else high = middle - 1;
  }
  const map = require("module").findSourceMap?.(file);
  const entry = map ? map.findEntry(low, offset - starts[low]) : null;
  if (entry && entry.originalSource !== undefined) {
    const source = entry.originalSource.startsWith("file://") ? entry.originalSource.slice(7) : entry.originalSource;
    return `line ${source}:${entry.originalLine + 1}`;
  }
  return `line ${file}:${low + 1}`;
}

/** Code coverage for strategies: from now on, each block of code (V8's precise coverage) in
 * files under `paths` (prefixes; all but this SDK's when omitted) emits a "coverage" event the
 * first time this process runs it (as its source line: coverageLine), as the C and Zig SDKs do
 * for edges, collected every `intervalMs` of (virtual) time and when the process exits.
 * Strategies such as det-strategy-mutate keep the timelines that reach new code. Source maps are
 * on from here (process.setSourceMapsEnabled), for the modules loaded after. The same files'
 * code is where thread pausing pauses the process's threads (pausingStart). Inside determinismo
 * only. */
function coverageStart(options = {}) {
  if (!inside()) return;
  const prefixes = options.paths || null;
  const set = coverageSet(process.env.DETERMINISMO_COVERAGE || "");
  pausingStart(prefixes, set);
  process.setSourceMapsEnabled?.(true);
  const inspector = require("inspector");
  const intervalMs = options.intervalMs || 1000;
  const session = new inspector.Session();
  session.connect();
  const reported = new Set();
  const files = new Map();
  const collect = () => {
    session.post("Profiler.takePreciseCoverage", (error, result) => {
      if (error || !result) return;
      for (const script of result.result) {
        const file = script.url.startsWith("file://") ? script.url.slice(7) : script.url;
        if (!file || !coveredBy(file, __filename, prefixes, set)) continue;
        for (const fn of script.functions) {
          for (const range of fn.ranges) {
            if (range.count === 0) continue;
            const name = coverageLine(file, range.startOffset, files);
            if (reported.has(name)) continue;
            reported.add(name);
            event("coverage", { name });
          }
        }
      }
    });
  };
  session.post("Profiler.enable", () => {
    session.post("Profiler.startPreciseCoverage", { callCount: false, detailed: true }, () => {
      setInterval(collect, intervalMs).unref();
      process.on("exit", collect);
    });
  });
}

/** A node's coverage set (DETERMINISMO_COVERAGE: file name prefixes, those starting with "-"
 * excluded; the Zig SDK's schema.Coverage), as { included, excluded }: a test program's profile
 * scopes coverage and thread pausing with it. */
function coverageSet(text) {
  const entries = text.split(",").filter((entry) => entry && entry !== "-");
  return {
    included: entries.filter((entry) => !entry.startsWith("-")),
    excluded: entries.filter((entry) => entry.startsWith("-")).map((entry) => entry.slice(1)),
  };
}

/** Whether `file` is under coverage: not the SDK, under `prefixes` (null: anywhere) and in the
 * node's coverage `set`. */
function coveredBy(file, sdkFile, prefixes, set) {
  if (file === sdkFile) return false;
  if (prefixes && !prefixes.some((prefix) => file.startsWith(prefix))) return false;
  if (set.excluded.some((prefix) => file.startsWith(prefix))) return false;
  return set.included.length === 0 || set.included.some((prefix) => file.startsWith(prefix));
}

// Thread pausing ------------------------------------------------------------------------------

// Thread pausing (Antithesis's, which needs their instrumentation too), the C SDK's
// det_pausing_at: inside determinismo, one stretch of two seconds (virtual time) in four, a named
// decision ("thread pausing") at the stretch's start, one breakable position in 64 of the code
// under coverage is a slow point (one a file at least) with its own pause (10 to 100 ms: PAUSE_SCALE), drawn for the stretch: a thread
// reaching one waits there, at most 8 times a stretch. Threads stopped together at a point wait
// together, so the checks of a check-then-act between them all run before any of its acts. V8
// calls nothing at a block (its coverage is counted, read later), so a helper thread pauses
// through the inspector: connected to the main thread's, and through it to the workers' whose
// script is under coverage (each held at its start until the stretch's slow points are set in
// it), it sets the slow points as
// breakpoints by URL and resumes a thread stopped at one after its pause (a timer of its own).
// It learns a file's breakable positions by compiling the file as the CommonJS loader does
// (vm.compileFunction) in its own isolate, the first time any thread parses it, so a worker's
// are set before it runs; an ES module's from the thread that parsed it (learn).
const PAUSING_HELPER = String.raw`
"use strict";
const inspector = require("inspector");
const fs = require("fs");
const vm = require("vm");
const { workerData, threadId } = require("worker_threads");
const det = require(workerData.sdk);
const { prefixes, set, sdk } = workerData;
const SLOW_ONE_IN = 64n;
const PAUSES_MAX = 8;
const STRETCH_MS = 2000;
// A slow point's pause: the C SDK's 1 to 10 ms, times 10. A JavaScript thread reaches a window
// later than a native one (its event loop, an entry into V8, the inspector's relay through the
// main thread): the race's 64 workers gathered at most 60 in 1 to 10 ms (hunt run 971: 267 races
// in two timelines), 63 in 4 to 40 ms (run 978: 165 races, 5 past 50).
const PAUSE_SCALE = 10;
// Alive as long as the process (it is unref'd there): inspector replies hold no handle.
setInterval(() => {}, 1 << 30);

function mix(value) {
  value = BigInt.asUintN(64, value * 0x9E3779B97F4A7C15n);
  value ^= value >> 29n;
  value = BigInt.asUintN(64, value * 0xBF58476D1CE4E5B9n);
  return value ^ (value >> 32n);
}
function hash(text) { // FNV-1a, 32 bits.
  let value = 2166136261;
  for (let i = 0; i < text.length; i++) value = Math.imul(value ^ text.charCodeAt(i), 16777619) >>> 0;
  return BigInt(value);
}

const session = new inspector.Session();
session.connectToMainThread();
const post = (method, params) => new Promise((resolve, reject) =>
  session.post(method, params, (error, result) => (error ? reject(error) : resolve(result))));
// This thread's own session: where a file is compiled to learn its breakable positions.
const own = new inspector.Session();
own.connect();
const ownScripts = new Map(); // url -> scriptId
own.on("Debugger.scriptParsed", ({ params }) => ownScripts.set(params.url, params.scriptId));
own.post("Debugger.enable");

let seed = 0n; // This stretch's; 0 when it pauses nothing.
const positions = new Map(); // url -> [{ line, column, value }] (value: the position's hash)
// The main thread and each worker under coverage: { send, points: breakpointId -> point, enabled }.
const targets = new Set();


const ownPost = (method, params) => new Promise((resolve, reject) =>
  own.post(method, params, (error, result) => (error ? reject(error) : resolve(result))));

/** A file's breakable positions, learned once: from its compile here as CommonJS (before any
 * thread runs it), else (an ES module: the inspector reports no vm.SourceTextModule) from the
 * thread that parsed it, by its scriptId there: code run at its load, before the points are set, is
 * not paused, its functions called later are. */
function learn(url, target, scriptId) {
  if (positions.has(url) || !url.startsWith("file://")) return;
  const file = decodeURIComponent(url.slice("file://".length));
  if (!det._coveredBy(file, sdk, prefixes, set)) {
    positions.set(url, []);
    return;
  }
  let compiled = false;
  try {
    const source = fs.readFileSync(file, "utf8");
    vm.compileFunction(source, ["exports", "require", "module", "__filename", "__dirname"], { filename: url });
    compiled = true;
  } catch {
    // Unreadable, or an ES module.
  }
  const ownId = compiled ? ownScripts.get(url) : undefined;
  let asked;
  if (ownId !== undefined) asked = ownPost("Debugger.getPossibleBreakpoints", { start: { scriptId: ownId, lineNumber: 0, columnNumber: 0 } });
  else if (target && scriptId !== undefined) asked = target.send("Debugger.getPossibleBreakpoints", { start: { scriptId, lineNumber: 0, columnNumber: 0 } });
  else return; // A thread parsing it says where (its scriptParsed).
  positions.set(url, []);
  asked.then((result) => {
    const learned = result.locations.map((location) => ({
      line: location.lineNumber,
      column: location.columnNumber,
      value: hash(file + ":" + (location.lineNumber + 1) + ":" + location.columnNumber),
    }));
    positions.set(url, learned);
    if (seed) for (const each of targets) if (each.enabled) arm(each, [[url, learned]]).catch(() => {});
  }).catch(() => positions.delete(url));
}

// A stretch's slow points in a file: its positions whose draw is 0 modulo SLOW_ONE_IN, or, when
// none is (a file of a few positions, most stretches: the race's worker has a handful), the one
// with the smallest draw. Every covered file then has one at least: a check-then-act in a small
// file was a slow point in about 1 stretch in 256 (runs 971, 978: two racing timelines in 734
// and 567).
async function arm(target, entries) {
  for (const [url, learned] of entries) {
    const chosen = [];
    let least = null;
    for (const position of learned) {
      const value = mix(seed ^ position.value);
      if (value % SLOW_ONE_IN === 0n) chosen.push([position, value]);
      if (least === null || value < least[1]) least = [position, value];
    }
    if (chosen.length === 0 && least !== null) chosen.push(least);
    for (const [position, value] of chosen) {
      const reply = await target.send("Debugger.setBreakpointByUrl", { url, lineNumber: position.line, columnNumber: position.column });
      target.points.set(reply.breakpointId, { ms: PAUSE_SCALE * (1 + Number((value >> 8n) % 10n)), pauses: 0 });
    }
  }
}

async function disarm(target) {
  const ids = [...target.points.keys()];
  target.points.clear();
  for (const breakpointId of ids) await target.send("Debugger.removeBreakpoint", { breakpointId });
}

function notified(target, method, params) {
  if (method === "Debugger.scriptParsed") {
    if (params.url) learn(params.url, target, params.scriptId);
  } else if (method === "Debugger.paused") {
    const point = target.points.get((params.hitBreakpoints || [])[0]);
    if (!point || point.pauses >= PAUSES_MAX) {
      target.send("Debugger.resume", {}).catch(() => {});
      return;
    }
    point.pauses += 1;
    setTimeout(() => target.send("Debugger.resume", {}).catch(() => {}), point.ms);
  }
}

const main = { send: post, points: new Map(), enabled: true };
targets.add(main);
session.on("inspectorNotification", (message) => notified(main, message.method, message.params));

// Workers, through the main thread's NodeWorker domain.
const workers = new Map(); // sessionId -> target
const replies = new Map(); // message id -> { resolve, reject }
let messageId = 1;
session.on("NodeWorker.attachedToWorker", ({ params }) => {
  const { sessionId, workerInfo, waitingForDebugger } = params;
  if (workerInfo.workerId === String(threadId)) {
    post("NodeWorker.detach", { sessionId }).catch(() => {});
    return;
  }
  const send = (method, sent) => new Promise((resolve, reject) => {
    const id = messageId++;
    replies.set(id, { resolve, reject });
    post("NodeWorker.sendMessageToWorker", { sessionId, message: JSON.stringify({ id, method, params: sent }) }).catch(reject);
  });
  // Its debugger on, as it starts, only if its script is under coverage: on, V8 reports every
  // script it compiled already (Node's own, about 170 in a worker, 75 KB), each relayed here
  // through the main thread. Paid at a stretch that pauses, the race's 64 workers' made it
  // outlast its timelines in the guest.
  const url = workerInfo.url || "";
  const file = url.startsWith("file://") ? decodeURIComponent(url.slice("file://".length)) : url;
  const release = () => {
    if (waitingForDebugger) send("Runtime.runIfWaitingForDebugger", {}).catch(() => {});
  };
  if (!det._coveredBy(file, sdk, prefixes, set)) {
    release();
    return;
  }
  const target = { send, points: new Map(), enabled: false };
  workers.set(sessionId, target);
  targets.add(target);
  (async () => {
    await send("Debugger.enable", {});
    target.enabled = true;
    learn(url, target);
    if (seed) await arm(target, positions);
  })().catch(() => {}).finally(release);
});
session.on("NodeWorker.receivedMessageFromWorker", ({ params }) => {
  const message = JSON.parse(params.message);
  if (message.id !== undefined) {
    const reply = replies.get(message.id);
    replies.delete(message.id);
    if (reply) (message.error ? reply.reject(message.error) : reply.resolve(message.result));
    return;
  }
  const target = workers.get(params.sessionId);
  if (target) notified(target, message.method, message.params);
});
session.on("NodeWorker.detachedFromWorker", ({ params }) => {
  targets.delete(workers.get(params.sessionId));
  workers.delete(params.sessionId);
});

async function stretch() {
  seed = det.randomBelowNamed("thread pausing", 4) === 0 ? det.randomU64() | 1n : 0n;
  // Every thread at once: one after another, 64 workers' round trips took a stretch's length.
  await Promise.all([...targets].map(async (target) => {
    try {
      await disarm(target);
      if (seed && target.enabled) await arm(target, positions);
    } catch {
      // A worker gone meanwhile.
    }
  }));
}

(async () => {
  await post("Debugger.enable", {});
  await post("NodeWorker.enable", { waitForDebuggerOnStart: true });
  await stretch();
  setInterval(() => stretch().catch(() => {}), STRETCH_MS);
})().catch(() => {});
`;

/** Starts thread pausing in this process (inside determinismo; coverageStart calls it), at the
 * code of files under coverage (coveredBy). */
function pausingStart(prefixes, set) {
  if (!inside() || !require("worker_threads").isMainThread) return;
  const { Worker } = require("worker_threads");
  const helper = new Worker(PAUSING_HELPER, { eval: true, workerData: { sdk: __filename, prefixes, set } });
  helper.on("error", () => {}); // Pausing stops; the program goes on.
  helper.unref();
}

// The assertion catalog ---------------------------------------------------------------------

const KINDS = {
  always: ["always", 1],
  alwaysOrUnreachable: ["always_or_unreachable", 1],
  sometimes: ["sometimes", 1],
  reachable: ["reachable", 0],
  unreachable: ["unreachable", 0],
  alwaysSome: ["always", 1],
  sometimesAll: ["sometimes", 1],
};
for (const relation of ["GreaterThan", "GreaterThanOrEqual", "LessThan", "LessThanOrEqual", "GreaterThanOrEqualTo", "LessThanOrEqualTo"]) {
  KINDS["always" + relation] = ["always", 2];
  KINDS["sometimes" + relation] = ["sometimes", 2];
}
const declared = new Map(); // `${kind}\u0000${message}` -> { kind, message, file }
const scanned = new Set();
let announcing = false; // Inside determinismo, declared assertions are announced as they are.

/** Announces an assertion before it runs: one never reached is judged too. Assertions with
 * literal messages in CommonJS modules are announced already. */
function declare(kind, message, file = null) {
  const key = `${kind}\u0000${message}`;
  if (declared.has(key)) return;
  declared.set(key, { kind, message, file });
  if (announcing) emit({ assert: { type: kind, message, hit: false } });
}

/** The assertions the program declares so far (its loaded modules' and declare()'s): an
 * array of { kind, message, file }. */
function catalogAssertions() {
  return [...declared.values()];
}

/** Writes the catalog, one JSON object a line (`{"kind","message","file"}`), to `stream`
 * (process.stdout by default): what a program checks, for review or CI. */
function catalogWrite(stream = process.stdout) {
  for (const entry of catalogAssertions()) stream.write(toJson(entry) + "\n");
}

/** The arguments of the call whose "(" is at `open`: each argument's source text, split at the
 * top level (strings, template literals, brackets skipped). */
function callArguments(source, open) {
  const parts = [];
  let depth = 0;
  let start = open + 1;
  for (let at = open; at < source.length; at++) {
    const char = source[at];
    if (char === '"' || char === "'" || char === "`") {
      for (at++; at < source.length && source[at] !== char; at++) if (source[at] === "\\") at++;
      continue;
    }
    if (char === "(" || char === "[" || char === "{") depth++;
    else if (char === ")" || char === "]" || char === "}") {
      depth--;
      if (depth === 0) {
        parts.push(source.slice(start, at));
        return parts;
      }
    } else if (char === "," && depth === 1) {
      parts.push(source.slice(start, at));
      start = at + 1;
    }
  }
  return parts;
}

/** A plain string literal's value ('...', "..." or `...` without substitutions), else null. */
function literal(text) {
  const trimmed = text.trim();
  if (trimmed.length < 2) return null;
  const quote = trimmed[0];
  if (!(quote === '"' || quote === "'" || quote === "`") || trimmed[trimmed.length - 1] !== quote) return null;
  if (quote === "`" && trimmed.includes("${")) return null;
  try {
    return quote === '"' ? JSON.parse(trimmed) : JSON.parse('"' + trimmed.slice(1, -1).replace(/\\'/g, "'").replace(/"/g, '\\"') + '"');
  } catch {
    return null;
  }
}

/** Declares the assertions of a module's source: calls to this SDK's assertions, through the
 * names the module binds to it (require, import, TypeScript's compiled forms), whose message is a
 * literal. */
function catalogSource(source, file = null) {
  const bindings = new Set();
  const direct = new Map(); // Local name -> the SDK's.
  const requireOf = /(?:const|let|var)\s+(\w+)\s*=\s*(?:__importStar\(|__importDefault\()?\s*require\(\s*["'`][^"'`]*determinismo[^"'`]*["'`]\s*\)/g;
  for (const match of source.matchAll(requireOf)) bindings.add(match[1]);
  const importAll = /import\s+\*\s+as\s+(\w+)\s+from\s+["'][^"']*determinismo[^"']*["']/g;
  for (const match of source.matchAll(importAll)) bindings.add(match[1]);
  const destructured = /(?:(?:const|let|var)\s*\{([^}]*)\}\s*=\s*require\(\s*["'][^"']*determinismo[^"']*["']\s*\))|(?:import\s*\{([^}]*)\}\s*from\s*["'][^"']*determinismo[^"']*["'])/g;
  for (const match of source.matchAll(destructured)) {
    for (const entry of (match[1] || match[2]).split(",")) {
      const [name, alias] = entry.split(/\s*(?::|\bas\b)\s*/).map((part) => part.trim());
      if (KINDS[name]) direct.set(alias || name, name);
    }
  }
  if (bindings.size === 0 && direct.size === 0) return;
  const call = /(\w+)\.(\w+)\s*\)?\s*\(|\b(\w+)\s*\(/g;
  for (const match of source.matchAll(call)) {
    let called = null;
    if (match[1] && bindings.has(match[1]) && KINDS[match[2]]) called = match[2];
    else if (match[3] && direct.has(match[3])) called = direct.get(match[3]);
    if (!called) continue;
    const open = match.index + match[0].lastIndexOf("(");
    const [kind, position] = KINDS[called];
    const argument = callArguments(source, open)[position];
    const message = argument === undefined ? null : literal(argument);
    if (message) declare(kind, message, file);
  }
}

/** Announces the assertions of `file` (a module this SDK did not see load: an ES module, a
 * bundle). */
function catalog(file) {
  const resolved = path.resolve(file);
  if (scanned.has(resolved) || resolved === __filename) return;
  scanned.add(resolved);
  let source;
  try {
    source = fs.readFileSync(resolved, "utf8");
  } catch {
    return;
  }
  catalogSource(source, resolved);
}

function catalogStart() {
  // Outside determinismo too: catalogAssertions() lists them, but nothing is announced.
  announcing = inside();
  const Module = require("module");
  // The modules that loaded before this SDK, then every one that loads after.
  for (const loaded of Object.values(require.cache)) if (loaded && loaded.filename) catalog(loaded.filename);
  const compile = Module.prototype._compile;
  Module.prototype._compile = function (content, filename) {
    if (filename && !scanned.has(filename) && filename !== __filename) {
      scanned.add(filename);
      catalogSource(content, filename);
    }
    return compile.call(this, content, filename);
  };
  // The main script: the main thread's to announce (a worker has the same argv: thread pausing's
  // helper, or the program's own).
  if (process.argv[1] && require("worker_threads").isMainThread) catalog(process.argv[1]);
}

catalogStart();

module.exports = {
  crashPoint,
  _coverageLine: coverageLine, // The SDK's own check of its coverage names, not an API.
  _classOf: classOf, // The same, of a location's class.
  _coveredBy: coveredBy, // Thread pausing's helper's, and the SDK's own check.
  _coverageSet: coverageSet,
  inside,
  randomBytes,
  randomU64,
  randomBelow,
  randomChoice,
  swarmHash,
  swarmIndex,
  swarmChoice,
  random,
  rng,
  prng,
  decide,
  randomBelowNamed,
  randomNear,
  buggify,
  buggifyPause,
  buggifyPauseAsync,
  setAssertionEvents,
  always,
  alwaysOrUnreachable,
  sometimes,
  reachable,
  unreachable,
  alwaysGreaterThan,
  alwaysGreaterThanOrEqual,
  alwaysLessThan,
  alwaysLessThanOrEqual,
  sometimesGreaterThan,
  sometimesGreaterThanOrEqual,
  sometimesLessThan,
  sometimesLessThanOrEqual,
  alwaysSome,
  sometimesAll,
  optimize,
  declare,
  catalog,
  catalogAssertions,
  catalogWrite,
  setupComplete,
  event,
  doomed,
  output,
  stopFaults,
  fault,
  faultAim,
  coverageStart,
  // Antithesis's TypeScript SDK's names.
  alwaysGreaterThanOrEqualTo: alwaysGreaterThanOrEqual,
  alwaysLessThanOrEqualTo: alwaysLessThanOrEqual,
  sometimesGreaterThanOrEqualTo: sometimesGreaterThanOrEqual,
  sometimesLessThanOrEqualTo: sometimesLessThanOrEqual,
  sendEvent: event,
};
