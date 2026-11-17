// SPDX-License-Identifier: MIT
//! determinismo SDK for Rust: assertions, events and platform randomness.
//!
//! Inside determinismo everything goes through `/dev/determinismo`: events are recorded with their
//! moment, and every random value is a decision the platform can steer and replay. Outside it
//! (local runs) randomness comes from the OS and events go to the file `DETERMINISMO_SDK_LOCAL_OUTPUT`
//! (or Antithesis's `ANTITHESIS_SDK_LOCAL_OUTPUT`) names, one JSON object a line, else nowhere
//! (Antithesis's default: assertions evaluated, nothing written).
//!
//! ```ignore
//! use determinismo::{always, json};
//! let account = determinismo::random_below(10);
//! always!(total == 1000, "total balance is conserved", &json!({ "total": total }));
//! ```
//!
//! The assertion catalog: every assertion macro's message is a literal, kept in the program's
//! `det_catalog` section (the C and Zig SDKs' layout) and announced as the program starts, before
//! the assertion runs (Antithesis's catalog), so one no timeline reaches is judged too;
//! [`catalog::assertions`] lists them.
//!
//! The same API as the other SDKs (docs/SDKS.md): randomness ([`random_bytes`], [`random_u64`],
//! [`random_below`], [`random_choice`], [`random`], [`rng`], [`prng`]), named decisions
//! ([`decide`], [`random_below_named`]), [`buggify`] and [`buggify_pause`], the assertions
//! ([`always!`], [`always_or_unreachable!`], [`sometimes!`], [`reachable!`], [`unreachable!`]),
//! the guidance comparisons ([`always_greater_than!`] ...), [`always_some!`] and
//! [`sometimes_all!`], [`set_assertion_events`], [`declare`], [`catalog`], [`setup_complete`],
//! [`event`], [`output`], [`stop_faults`], [`fault`], and edge coverage (feature `coverage`).
//! Antithesis's macro names (`assert_always!`, `assert_always_greater_than_or_equal_to!`, ...)
//! and functions (`get_random`, `send_event`) work too: its code ports with a changed import.

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub use serde_json::{json, Value};

const DEVICE_PATH: &str = "/dev/determinismo";
/// One event or one randomness pull per device call.
pub const MESSAGE_SIZE_MAX: usize = 4096 - 16;
/// faults.zig's control_path.
const FAULTS_CONTROL: &str = "/opt/determinismo/faults-control";

// The device ------------------------------------------------------------------------------

fn device() -> Option<&'static File> {
    static DEVICE: OnceLock<Option<File>> = OnceLock::new();
    DEVICE
        .get_or_init(|| {
            if !cfg!(feature = "full") {
                return None;
            }
            OpenOptions::new().read(true).write(true).open(DEVICE_PATH).ok() // Not inside: None.
        })
        .as_ref()
}

/// Whether this process runs inside determinismo.
pub fn inside() -> bool {
    device().is_some()
}

fn local_output() -> Option<&'static Mutex<File>> {
    static LOCAL: OnceLock<Option<Mutex<File>>> = OnceLock::new();
    LOCAL
        .get_or_init(|| {
            let path = std::env::var_os("DETERMINISMO_SDK_LOCAL_OUTPUT")
                .or_else(|| std::env::var_os("ANTITHESIS_SDK_LOCAL_OUTPUT"))?;
            let file = OpenOptions::new().create(true).append(true).open(path).ok()?;
            Some(Mutex::new(file))
        })
        .as_ref()
}

fn emit(message: &Value) {
    if !cfg!(feature = "full") {
        return;
    }
    let line = message.to_string();
    let Some(mut device) = device() else {
        if let Some(file) = local_output() {
            let mut file = file.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let _ = writeln!(file, "{line}");
        }
        return;
    };
    let mut data = line.into_bytes();
    if data.len() > MESSAGE_SIZE_MAX {
        // The assertion must not be lost: drop the details.
        let mut shortened = message.clone();
        if let Some(assertion) = shortened.get_mut("assert").and_then(Value::as_object_mut) {
            assertion.insert("details".into(), Value::String("<details too large>".into()));
        }
        data = shortened.to_string().into_bytes();
        data.truncate(MESSAGE_SIZE_MAX);
    }
    let _ = device.write(&data); // One write, one event.
}

// Randomness ------------------------------------------------------------------------------

/// Fills `buffer` with random bytes: a platform decision inside determinismo.
pub fn random_bytes(buffer: &mut [u8]) {
    assert!(!buffer.is_empty() && buffer.len() <= MESSAGE_SIZE_MAX, "random_bytes: {} bytes", buffer.len());
    match device() {
        Some(mut device) => {
            let read = device.read(buffer).expect("random_bytes: the platform's device");
            assert_eq!(read, buffer.len(), "random_bytes: the platform gave fewer bytes");
        }
        None => os_random(buffer),
    }
}

fn os_random(buffer: &mut [u8]) {
    static URANDOM: OnceLock<Mutex<File>> = OnceLock::new();
    let file = URANDOM.get_or_init(|| Mutex::new(File::open("/dev/urandom").expect("/dev/urandom")));
    let mut file = file.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    file.read_exact(buffer).expect("/dev/urandom");
}

/// A random 64-bit integer.
pub fn random_u64() -> u64 {
    let mut bytes = [0u8; 8];
    random_bytes(&mut bytes);
    u64::from_le_bytes(bytes)
}

/// Antithesis's name for [`random_u64`].
pub fn get_random() -> u64 {
    random_u64()
}

/// A uniformly random integer in `[0, count)`.
pub fn random_below(count: u64) -> u64 {
    assert!(count > 0, "random_below: count must be positive");
    random_u64() % count
}

/// One of `items`, at random; None when there is none.
pub fn random_choice<T>(items: &[T]) -> Option<&T> {
    if items.is_empty() {
        return None;
    }
    Some(&items[random_below(items.len() as u64) as usize])
}

/// A float in `[0, 1)` from 53 random bits.
pub fn random() -> f64 {
    unit_float(random_u64())
}

fn unit_float(value: u64) -> f64 {
    (value >> 11) as f64 / (1u64 << 53) as f64
}

/// A generator whose every draw is a platform decision (steerable, replayed from tapes): one
/// request to the platform a draw. For hot loops, [`prng`].
pub fn rng() -> Rng {
    Rng
}

/// Draws from the platform, one a call (see [`rng`]).
#[derive(Clone, Copy, Debug, Default)]
pub struct Rng;

/// Antithesis's name for [`Rng`].
pub type AntithesisRng = Rng;

/// A generator the platform seeds once (SplitMix64): draws cost nothing, and replay with the
/// seed.
pub fn prng() -> Prng {
    Prng { state: random_u64() }
}

/// A SplitMix64 generator (see [`prng`]).
#[derive(Clone, Debug)]
pub struct Prng {
    state: u64,
}

impl Prng {
    /// One seeded with `seed` (a test's own).
    pub fn from_seed(seed: u64) -> Prng {
        Prng { state: seed }
    }
}

/// What both generators draw.
pub trait Generator {
    fn next_u64(&mut self) -> u64;

    /// A float in `[0, 1)`.
    fn random(&mut self) -> f64 {
        unit_float(self.next_u64())
    }

    /// An integer in `[0, count)`.
    fn below(&mut self, count: u64) -> u64 {
        assert!(count > 0, "below: count must be positive");
        self.next_u64() % count
    }

    fn choice<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        if items.is_empty() {
            return None;
        }
        Some(&items[self.below(items.len() as u64) as usize])
    }

    /// Shuffles `items` in place (Fisher-Yates).
    fn shuffle<T>(&mut self, items: &mut [T]) {
        for index in (1..items.len()).rev() {
            let other = self.below(index as u64 + 1) as usize;
            items.swap(index, other);
        }
    }
}

impl Generator for Rng {
    fn next_u64(&mut self) -> u64 {
        random_u64()
    }
}

impl Generator for Prng {
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
}

#[cfg(any(feature = "rand_core_0_6", feature = "rand_core_0_9"))]
fn fill_from(generator: &mut impl Generator, destination: &mut [u8]) {
    for chunk in destination.chunks_mut(8) {
        let bytes = generator.next_u64().to_le_bytes();
        chunk.copy_from_slice(&bytes[..chunk.len()]);
    }
}

#[cfg(any(feature = "rand_core_0_6", feature = "rand_core_0_9"))]
// `RngCore` for the rand crate's users: rand_core 0.6 also wants try_fill_bytes. Not
// `CryptoRng`: a timeline's draws replay.
macro_rules! rng_core {
    ($rand_core:ident $(, $try_fill:item)?) => {
        impl $rand_core::RngCore for Rng {
            fn next_u32(&mut self) -> u32 {
                Generator::next_u64(self) as u32
            }
            fn next_u64(&mut self) -> u64 {
                Generator::next_u64(self)
            }
            fn fill_bytes(&mut self, destination: &mut [u8]) {
                for chunk in destination.chunks_mut(MESSAGE_SIZE_MAX) {
                    random_bytes(chunk);
                }
            }
            $($try_fill)?
        }
        impl $rand_core::RngCore for Prng {
            fn next_u32(&mut self) -> u32 {
                Generator::next_u64(self) as u32
            }
            fn next_u64(&mut self) -> u64 {
                Generator::next_u64(self)
            }
            fn fill_bytes(&mut self, destination: &mut [u8]) {
                fill_from(self, destination);
            }
            $($try_fill)?
        }
    };
}

#[cfg(feature = "rand_core_0_6")]
mod rand_core_0_6_impls {
    use super::*;
    rng_core!(
        rand_core_0_6,
        fn try_fill_bytes(&mut self, destination: &mut [u8]) -> Result<(), rand_core_0_6::Error> {
            rand_core_0_6::RngCore::fill_bytes(self, destination);
            Ok(())
        }
    );
}

#[cfg(feature = "rand_core_0_9")]
mod rand_core_0_9_impls {
    use super::*;
    rng_core!(rand_core_0_9);
}

// Labeled decisions: the platform's strategies see the name and the options -------------------

/// A named decision among options (which fault, which account, which node): the index chosen,
/// a platform decision announced with the options' names.
pub fn decide<S: AsRef<str>>(name: &str, options: &[S]) -> usize {
    assert!(!options.is_empty(), "decide: no options");
    if inside() {
        let names: Vec<&str> = options.iter().map(AsRef::as_ref).collect();
        emit(&json!({ "decision": { "name": name, "options": names } }));
    }
    random_below(options.len() as u64) as usize
}

/// [`random_below`], named for strategies ("retry.jitter_ms").
pub fn random_below_named(name: &str, count: u64) -> u64 {
    if inside() {
        emit(&json!({ "decision": { "name": name, "range": count } }));
    }
    random_below(count)
}

/// A value up to `max` drawn around a limit the workload declares (a batch size, a buffer, a
/// threshold): half the time uniform, else one of the limit's edges, where bugs gather and uniform
/// draws seldom land: 0, 1, limit - 1, limit, limit + 1 or twice it (each kept within `max`).
/// Named decisions (`<name>.near`, then `name`), as the Zig SDK's random_near.
pub fn random_near(name: &str, limit: u64, max: u64) -> u64 {
    assert!(max > 0, "random_near: max must be positive");
    if random_below_named(&format!("{name}.near"), 2) == 0 {
        return random_below_named(name, max.saturating_add(1));
    }
    let edges = ["zero", "one", "limit-1", "limit", "limit+1", "twice"];
    let value = match decide(name, &edges) {
        0 => 0,
        1 => 1,
        2 => limit.saturating_sub(1),
        3 => limit,
        4 => limit.saturating_add(1),
        _ => limit.saturating_mul(2),
    };
    value.min(max)
}

// Swarm testing over a workload's operations: the Zig SDK's swarm_index (sdk/zig/
// determinismo.zig), the same table from the same seed (FNV-1a and SplitMix64), so drivers in
// any language agree on a timeline's mix.

const SWARM_SEED_PATH: &str = "/opt/determinismo/swarm-seed";

#[derive(Default)]
struct SwarmState {
    seed: Option<u64>,
    /// Each name's last answer in this process: its stretch, the answer.
    runs: HashMap<String, (u64, u64)>,
}

static SWARM: OnceLock<Mutex<SwarmState>> = OnceLock::new();

fn swarm_mix(value: u64) -> u64 {
    let mut z = value.wrapping_add(0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

/// The table's draws: FNV-1a of the name, mixed with the seed, stretch and what by SplitMix64,
/// the same in every SDK.
pub fn swarm_hash(seed: u64, name: &str, stretch: u64, what: u64) -> u64 {
    let mut name_hash: u64 = 0xcbf29ce484222325;
    for byte in name.bytes() {
        name_hash = (name_hash ^ byte as u64).wrapping_mul(0x100000001b3);
    }
    swarm_mix(swarm_mix(swarm_mix(seed ^ name_hash) ^ stretch) ^ what)
}

/// CLOCK_MONOTONIC in milliseconds, as the other SDKs read it.
#[cfg(target_os = "linux")]
fn monotonic_ms() -> u64 {
    #[repr(C)]
    struct Timespec {
        sec: i64,
        nsec: i64,
    }
    extern "C" {
        fn clock_gettime(clock: i32, now: *mut Timespec) -> i32;
    }
    let mut now = Timespec { sec: 0, nsec: 0 };
    // SAFETY: a valid timespec to fill; CLOCK_MONOTONIC (1) always exists on Linux.
    unsafe { clock_gettime(1, &mut now) };
    now.sec as u64 * 1000 + now.nsec as u64 / 1_000_000
}

/// Outside Linux there is no determinismo, no swarm seed, and so no table to time.
#[cfg(not(target_os = "linux"))]
fn monotonic_ms() -> u64 {
    0
}

/// CLOCK_MONOTONIC in nanoseconds: the fault injector's clock (a crash point's request names its
/// moment in it).
#[cfg(target_os = "linux")]
fn monotonic_ns() -> u64 {
    #[repr(C)]
    struct Timespec {
        sec: i64,
        nsec: i64,
    }
    extern "C" {
        fn clock_gettime(clock: i32, now: *mut Timespec) -> i32;
    }
    let mut now = Timespec { sec: 0, nsec: 0 };
    // SAFETY: a valid timespec to fill; CLOCK_MONOTONIC (1) always exists on Linux.
    unsafe { clock_gettime(1, &mut now) };
    now.sec as u64 * 1_000_000_000 + now.nsec as u64
}

#[cfg(not(target_os = "linux"))]
fn monotonic_ns() -> u64 {
    0
}

/// An index below `count` (64 at most) by swarm testing: among the options this timeline keeps
/// for the name, weighted and repeated in runs, the table changing with stretches of virtual
/// time. Plain uniform outside determinismo, before the drivers, or with --no-swarm.
pub fn swarm_index(name: &str, count: u64) -> u64 {
    assert!(count > 0 && count <= 64, "swarm_index: 1 to 64 options");
    let label = format!("swarm.{name}");
    let mut state = SWARM.get_or_init(Default::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if state.seed.is_none() {
        state.seed = std::fs::read_to_string(SWARM_SEED_PATH).ok().and_then(|text| text.trim().parse().ok());
    }
    let Some(seed) = state.seed else {
        return random_below_named(&label, count);
    };
    let stretch = monotonic_ms() / (10_000 + swarm_hash(seed, name, 0, 1) % 110_001);
    let eighths = 1 + swarm_hash(seed, name, stretch, 2) % 7;
    let mean = [1u64, 4, 16, 64][(swarm_hash(seed, name, stretch, 3) % 4) as usize];
    let mut weights = vec![0u64; count as usize];
    let mut kept = 0u64;
    for i in 0..count {
        let drawn = swarm_hash(seed, name, stretch, 16 + i);
        if drawn % 8 >= eighths {
            continue;
        }
        weights[i as usize] = 1 << ((drawn >> 32) % 8);
        kept |= 1 << i;
    }
    if kept == 0 {
        let i = swarm_hash(seed, name, stretch, 4) % count;
        weights[i as usize] = 1;
        kept = 1 << i;
    }
    let total: u64 = weights.iter().sum();
    let run = state.runs.get(name).copied();
    if let Some((run_stretch, answer)) = run {
        if run_stretch == stretch && mean > 1 && random_below_named(&format!("{label} run"), mean) != 0 {
            return answer;
        }
    }
    let mut pick = random_below_named(&label, total);
    let mut answer = 0u64;
    for (i, weight) in weights.iter().enumerate() {
        if pick < *weight {
            answer = i as u64;
            break;
        }
        pick -= weight;
    }
    if run.map(|(run_stretch, _)| run_stretch != stretch).unwrap_or(true) {
        event("swarm", &json!({ "name": name, "stretch": stretch, "kept": kept, "mean": mean }));
    }
    state.runs.insert(name.to_string(), (stretch, answer));
    answer
}

/// One of the items by swarm testing ([`swarm_index`]), where [`random_choice`] drew uniformly.
pub fn swarm_choice<'a, T>(name: &str, items: &'a [T]) -> &'a T {
    &items[swarm_index(name, items.len() as u64) as usize]
}

#[cfg(test)]
mod swarm_tests {
    #[test]
    fn swarm_hash_vectors() {
        // The Zig SDK's vectors: every SDK derives the same table.
        assert_eq!(super::swarm_hash(1, "cache.operation", 0, 2), 0xbf59ece8b9488041);
        assert_eq!(super::swarm_hash(42, "a", 7, 16), 0xf5452f6a537dff80);
        assert!(super::swarm_index("cache.operation", 3) < 3);
    }
}

struct BuggifyPoint {
    generator: Option<Prng>,
    until: Instant,
}

const BUGGIFY_PERIOD: Duration = Duration::from_secs(2);

fn buggify_draw<T>(name: &str, draw: impl FnOnce(&mut Prng) -> T) -> Option<T> {
    static POINTS: OnceLock<Mutex<HashMap<String, BuggifyPoint>>> = OnceLock::new();
    if !inside() {
        return None;
    }
    let now = Instant::now(); // Virtual time inside determinismo.
    let points = POINTS.get_or_init(Default::default);
    let mut points = points.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let expired = points.get(name).map_or(true, |point| now >= point.until);
    if expired {
        let active = random_below_named(&format!("buggify {name}"), 4) == 0;
        let generator = if active { Some(prng()) } else { None };
        points.insert(name.to_string(), BuggifyPoint { generator, until: now + BUGGIFY_PERIOD });
    }
    points.get_mut(name)?.generator.as_mut().map(draw)
}

/// A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
/// of two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's
/// first evaluation; while active, it is true one evaluation in four, drawn from its own
/// generator seeded by the platform for the stretch (a hot point costs a decision a stretch).
/// Outside determinismo, always false. Where it is true, take a rare path the real system can
/// take too (a pause, a retry), never one it cannot.
pub fn buggify(name: &str) -> bool {
    buggify_draw(name, |generator| generator.below(4) == 0).unwrap_or(false)
}

/// At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
/// (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
/// the other threads to run in the window).
pub fn buggify_pause(name: &str) {
    let pause = buggify_draw(name, |generator| {
        if generator.below(32) != 0 {
            0
        } else {
            generator.below(10)
        }
    });
    if let Some(ms) = pause.filter(|&ms| ms > 0) {
        std::thread::sleep(Duration::from_millis(ms));
    }
}

// Assertions ------------------------------------------------------------------------------

/// Which evaluations become events: every one (the default: queries see each), or, as
/// Antithesis's SDKs do, each assertion's first pass and first failure in this process (for hot
/// paths: the same verdict, far fewer events).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssertionEvents {
    Every,
    First,
}

static FIRST_ONLY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Sets [`AssertionEvents`], once, at the start.
pub fn set_assertion_events(mode: AssertionEvents) {
    FIRST_ONLY.store(mode == AssertionEvents::First, std::sync::atomic::Ordering::Relaxed);
}

/// Where an assertion is in the code (the macros fill it in).
#[derive(Clone, Copy, Debug)]
pub struct Location {
    pub file: &'static str,
    pub line: u32,
    pub column: u32,
    pub function: &'static str,
}

struct AssertionState {
    seen: HashSet<(String, bool)>,
    located: HashSet<String>,
    best: HashMap<String, f64>,
}

fn assertion_state() -> std::sync::MutexGuard<'static, AssertionState> {
    static STATE: OnceLock<Mutex<AssertionState>> = OnceLock::new();
    STATE
        .get_or_init(|| {
            Mutex::new(AssertionState { seen: HashSet::new(), located: HashSet::new(), best: HashMap::new() })
        })
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[doc(hidden)]
pub fn __assert(kind: &'static str, condition: bool, message: &str, details: &Value, location: Location) {
    if !cfg!(feature = "full") {
        return;
    }
    let with_location = {
        let mut state = assertion_state();
        if FIRST_ONLY.load(std::sync::atomic::Ordering::Relaxed) && !state.seen.insert((message.to_string(), condition)) {
            return;
        }
        state.located.insert(message.to_string()) // Its location once per process: the platform keeps it.
    };
    let details = if details.is_null() { json!({}) } else { details.clone() };
    let mut body = json!({ "type": kind, "message": message, "condition": condition, "details": details });
    if with_location {
        body["location"] = json!({
            "file": location.file,
            "line": location.line,
            "column": location.column,
            "function": location.function,
        });
    }
    emit(&json!({ "assert": body }));
}

// Guidance assertions: the compared values in the details, and a guidance event telling
// strategies how far the timeline is from the interesting outcome (an `always` violated, a
// `sometimes` true): `distance`, lower is closer, 0 or less is there.

fn guidance(message: &str, distance: f64) {
    {
        let mut state = assertion_state();
        if let Some(&best) = state.best.get(message) {
            if distance >= best {
                return; // Only improvements.
            }
        }
        state.best.insert(message.to_string(), distance);
    }
    emit(&json!({ "guidance": { "message": message, "distance": finite_distance(distance) } }));
}

/// An infinite distance (a comparison with an infinite operand) as the largest JSON number:
/// serde_json makes it null, no distance at all.
fn finite_distance(distance: f64) -> f64 {
    distance.clamp(-f64::MAX, f64::MAX)
}

/// A comparison's operand as JSON. JSON has no infinity or NaN (serde_json makes them null,
/// which says nothing), so those are the strings "Infinity", "-Infinity" and "NaN", as every
/// SDK of ours sends them.
fn operand<T: Number>(value: T) -> Value {
    let number = value.as_f64();
    if number.is_nan() {
        json!("NaN")
    } else if number.is_infinite() {
        json!(if number > 0.0 { "Infinity" } else { "-Infinity" })
    } else {
        value.into()
    }
}

/// An objective's direction ([`optimize`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Goal {
    Maximize,
    Minimize,
}

/// An objective for exploration (Antithesis's "Optimizing our way through Metroid"): `bucket`'s
/// strings and booleans split states into buckets (a leader, a phase), explored evenly, each
/// keeping the state with the best `value` by `goal`; the tree returns there and goes further
/// from it.
pub fn optimize(message: &str, bucket: &Value, value: f64, goal: Goal) {
    if !value.is_finite() {
        return;
    }
    let bucket = if bucket.is_null() { json!({}) } else { bucket.clone() };
    let goal = match goal {
        Goal::Maximize => "maximize",
        Goal::Minimize => "minimize",
    };
    emit(&json!({ "optimize": { "message": message, "bucket": bucket, "value": value, "goal": goal } }));
}

/// The numbers the guidance comparisons take.
pub trait Number: Copy + PartialOrd + Into<Value> {
    fn as_f64(self) -> f64;
}

macro_rules! numbers {
    ($($t:ty),*) => { $(impl Number for $t { fn as_f64(self) -> f64 { self as f64 } })* };
}
numbers!(i8, i16, i32, i64, isize, u8, u16, u32, u64, usize, f32, f64);

#[doc(hidden)]
pub fn __compare<T: Number>(
    kind: &'static str,
    relation: &str,
    left: T,
    right: T,
    message: &str,
    details: &Value,
    location: Location,
) {
    let (holds, margin) = match relation {
        ">" => (left > right, left.as_f64() - right.as_f64()),
        ">=" => (left >= right, left.as_f64() - right.as_f64()),
        "<" => (left < right, right.as_f64() - left.as_f64()),
        _ => (left <= right, right.as_f64() - left.as_f64()),
    };
    let merged = json!({ "left": operand(left), "right": operand(right), "details": if details.is_null() { json!({}) } else { details.clone() } });
    __assert(kind, holds, message, &merged, location);
    guidance(message, if kind == "always" { margin } else { -margin });
}

#[doc(hidden)]
pub fn __boolean(kind: &'static str, conditions: &[(&str, bool)], message: &str, details: &Value, location: Location) {
    let held = conditions.iter().filter(|(_, value)| *value).count();
    let named: serde_json::Map<String, Value> =
        conditions.iter().map(|(name, value)| (name.to_string(), Value::Bool(*value))).collect();
    let merged = json!({ "conditions": named, "details": if details.is_null() { json!({}) } else { details.clone() } });
    if kind == "always" {
        __assert("always", held > 0, message, &merged, location);
        guidance(message, held as f64);
    } else {
        __assert("sometimes", held == conditions.len(), message, &merged, location);
        guidance(message, (conditions.len() - held) as f64);
    }
}

// The catalog -----------------------------------------------------------------------------

/// The magic that tells catalog entries from the linker's padding (the C and Zig SDKs').
pub const CATALOG_MAGIC: u64 = 0x676f6c6174616364;

/// One assertion call site in the `det_catalog` section (`struct det_catalog_entry`).
#[repr(C)]
#[doc(hidden)]
pub struct CatalogEntry {
    pub magic: u64,
    pub kind: *const u8,
    pub message: *const u8,
    pub message_size: u64,
}

// Pointers to string literals: read-only, for the program's life.
unsafe impl Sync for CatalogEntry {}

// The section exists in every program with this SDK (an entry the walk skips), so its bounds do.
#[cfg(target_os = "linux")]
#[link_section = "det_catalog"]
#[used]
static CATALOG_SENTINEL: CatalogEntry =
    CatalogEntry { magic: 0, kind: std::ptr::null(), message: std::ptr::null(), message_size: 0 };

#[cfg(target_os = "linux")]
extern "C" {
    #[link_name = "__start_det_catalog"]
    static CATALOG_START: u8;
    #[link_name = "__stop_det_catalog"]
    static CATALOG_STOP: u8;
}

/// The program's assertions, and announcing them.
pub mod catalog {
    use super::*;

    /// One assertion the program declares.
    #[derive(Clone, Debug, PartialEq, Eq, Hash)]
    pub struct Assertion {
        pub kind: String,
        pub message: String,
    }

    /// The assertions in the program's code (its macros' call sites) and those [`declare`]d.
    pub fn assertions() -> Vec<Assertion> {
        let mut listed = Vec::new();
        let mut known = HashSet::new();
        for (kind, message) in section().into_iter().chain(declared()) {
            if known.insert((kind.clone(), message.clone())) {
                listed.push(Assertion { kind, message });
            }
        }
        listed
    }

    /// Writes the catalog to `out`, one JSON object a line (`{"kind","message"}`): what a program
    /// checks, for review or CI.
    pub fn write(out: &mut dyn Write) -> std::io::Result<()> {
        for assertion in assertions() {
            writeln!(out, "{}", json!({ "kind": assertion.kind, "message": assertion.message }))?;
        }
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn section() -> Vec<(String, String)> {
        let mut found = Vec::new();
        // SAFETY: the linker's bounds of the det_catalog section, which holds CatalogEntry
        // values (8-aligned) and the linker's padding, which the magic tells apart.
        unsafe {
            let mut at = std::ptr::addr_of!(CATALOG_START) as usize;
            let stop = std::ptr::addr_of!(CATALOG_STOP) as usize;
            while at + std::mem::size_of::<CatalogEntry>() <= stop {
                let entry = &*(at as *const CatalogEntry);
                if entry.magic != CATALOG_MAGIC {
                    at += 8;
                    continue;
                }
                let kind = std::ffi::CStr::from_ptr(entry.kind.cast()).to_string_lossy().into_owned();
                let bytes = std::slice::from_raw_parts(entry.message, entry.message_size as usize);
                found.push((kind, String::from_utf8_lossy(bytes).into_owned()));
                at += std::mem::size_of::<CatalogEntry>();
            }
        }
        found
    }

    #[cfg(not(target_os = "linux"))]
    fn section() -> Vec<(String, String)> {
        Vec::new() // The section is an ELF one.
    }

    pub(crate) fn declared_set() -> &'static Mutex<Vec<(String, String)>> {
        static DECLARED: OnceLock<Mutex<Vec<(String, String)>>> = OnceLock::new();
        DECLARED.get_or_init(Default::default)
    }

    fn declared() -> Vec<(String, String)> {
        declared_set().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }

    /// Announces the section's assertions: inside determinismo only, and once per program file on
    /// each machine or node (a marker named after the file, as the C SDK's).
    #[cfg(target_os = "linux")]
    pub(crate) fn announce() {
        use std::os::unix::fs::MetadataExt;
        if !inside() {
            return;
        }
        if let Ok(status) = std::fs::metadata("/proc/self/exe") {
            let marker = format!("/tmp/.determinismo-catalog-rust-{:x}-{:x}", status.dev(), status.ino());
            if OpenOptions::new().write(true).create_new(true).open(&marker).is_err()
                && std::path::Path::new(&marker).exists()
            {
                return;
            }
        }
        for (kind, message) in section() {
            emit(&json!({ "assert": { "type": kind, "message": message, "hit": false } }));
        }
    }
}

/// Announces an assertion before it runs (one with a message computed at run time, or one in
/// code that never links in): one never reached is judged too.
pub fn declare(kind: &str, message: &str) {
    {
        let mut declared = catalog::declared_set().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if declared.iter().any(|(k, m)| k == kind && m == message) {
            return;
        }
        declared.push((kind.to_string(), message.to_string()));
    }
    emit(&json!({ "assert": { "type": kind, "message": message, "hit": false } }));
}

#[cfg(all(target_os = "linux", feature = "full"))]
extern "C" fn catalog_announce() {
    catalog::announce();
}

// As the program starts (a constructor, as the C SDK's), before any assertion runs.
#[cfg(all(target_os = "linux", feature = "full"))]
#[used]
#[link_section = ".init_array"]
static CATALOG_ANNOUNCE: extern "C" fn() = catalog_announce;

// Lifecycle and events ----------------------------------------------------------------------

/// The system is ready: the platform snapshots here and starts exploring.
pub fn setup_complete(details: &Value) {
    let details = if details.is_null() { json!({}) } else { details.clone() };
    emit(&json!({ "lifecycle": "setup_complete", "details": details }));
}

/// A structured event: `{"event": name, "details": details}`.
pub fn event(name: &str, details: &Value) {
    assert!(!name.is_empty(), "event: a name");
    let details = if details.is_null() { json!({}) } else { details.clone() };
    emit(&json!({ "event": name, "details": details }));
}

/// Antithesis's name for [`event`].
pub fn send_event(name: &str, details: &Value) {
    event(name, details)
}

/// Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md).
pub fn output(object: &Value) {
    emit(object);
}

// The fault injector ------------------------------------------------------------------------

fn faults_control(message: &[u8]) {
    use std::os::unix::fs::OpenOptionsExt;
    let Ok(mut fifo) = OpenOptions::new().write(true).custom_flags(0o4000 /* O_NONBLOCK */).open(FAULTS_CONTROL)
    else {
        return; // No injector running.
    };
    let _ = fifo.write(message); // Atomic: under PIPE_BUF.
}

/// A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`, except clock
/// skips; 0 ends it. Only while the fault injector runs.
pub fn stop_faults(seconds: f64) {
    let ns = (seconds.max(0.0) * 1e9) as u64;
    faults_control(&ns.to_le_bytes());
}

/// A fault now, from the scenario: `fault(&json!({"kind": "pause", "node": "db",
/// "duration_ms": 2000}))`. Applied, logged and undone like a drawn one (guest/runtime/faults.zig
/// lists the kinds). Only while the fault injector runs (the drivers).
pub fn fault(request: &Value) {
    let body = request.to_string().into_bytes();
    assert!(body.len() + 8 <= 4096, "a fault request is at most 4088 bytes");
    let mut message = ((1u64 << 63) | body.len() as u64).to_le_bytes().to_vec();
    message.extend_from_slice(&body);
    faults_control(&message);
}

/// A moment worth a crash (the Zig SDK's crash_point: the node just changed its view of the
/// cluster, a record is half written): inside determinismo and in a node, a point is armed one
/// two-second stretch in eight (a named decision, "crash point <name>"), and its first
/// evaluation then asks the fault injector to crash this node now and waits for it, up to half a
/// second. Granted as one of the node's crash faults the swarm keeps (a kill or a power loss),
/// outside quiet periods; refused at once where the injector's published state says so.
pub fn crash_point(name: &str) {
    static POINTS: OnceLock<Mutex<HashMap<String, (bool, Instant)>>> = OnceLock::new();
    if !inside() {
        return;
    }
    let Ok(node) = std::env::var("DETERMINISMO_NODE") else {
        return; // The runner's processes crash nothing.
    };
    if node.is_empty() {
        return;
    }
    let now = Instant::now(); // Virtual time inside determinismo.
    let armed = {
        let points = POINTS.get_or_init(Default::default);
        let mut points = points.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let expired = points.get(name).map_or(true, |point| now >= point.1);
        if expired {
            let armed = random_below_named(&format!("crash point {name}"), 8) == 0;
            points.insert(name.to_string(), (armed, now + BUGGIFY_PERIOD));
        }
        let point = points.get_mut(name).expect("inserted above");
        std::mem::replace(&mut point.0, false) // Once a stretch.
    };
    let asked_ns = monotonic_ns();
    if !armed || !crash_point_open(&node, asked_ns) {
        return;
    }
    let body = format!("{asked_ns} {node}\npoint {name}").into_bytes();
    if body.len() > 4000 {
        return;
    }
    let mut message = ((1u64 << 59) | body.len() as u64).to_le_bytes().to_vec(); // crash_point_flag
    message.extend_from_slice(&body);
    faults_control(&message);
    while monotonic_ns().saturating_sub(asked_ns) < 500_000_000 {
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Whether the injector may grant `node` a crash point now: the end of a quiet period, then the
/// nodes whose crash faults the swarm keeps, a line each (faults.zig's crash_points_path).
fn crash_point_open(node: &str, now_ns: u64) -> bool {
    let Ok(text) = std::fs::read_to_string("/opt/determinismo/crash-points") else {
        return false;
    };
    let mut lines = text.lines();
    let Some(Ok(quiet_until)) = lines.next().map(str::parse::<u64>) else {
        return false;
    };
    now_ns >= quiet_until && lines.any(|line| line == node)
}

/// Aims the fault injector at `node` from now on, until another call ("" for none): half its
/// faults involve it, each a decision strategies see and replays repeat (a primary, a leader).
pub fn fault_aim(node: &str) {
    let name = &node.as_bytes()[..node.len().min(32)];
    let mut message = ((1u64 << 61) | name.len() as u64).to_le_bytes().to_vec();
    message.extend_from_slice(name);
    faults_control(&message);
}

// The macros --------------------------------------------------------------------------------

#[doc(hidden)]
#[macro_export]
macro_rules! __catalog_site {
    ($kind:literal, $message:literal) => {{
        #[cfg_attr(target_os = "linux", link_section = "det_catalog")]
        #[used]
        static DET_CATALOG_SITE: $crate::CatalogEntry = $crate::CatalogEntry {
            magic: $crate::CATALOG_MAGIC,
            kind: ::core::concat!($kind, "\0").as_ptr(),
            message: ::core::concat!($message, "\0").as_ptr(),
            message_size: $message.len() as u64,
        };
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __location {
    () => {{
        fn f() {}
        let name = ::core::any::type_name_of_val(&f);
        $crate::Location {
            file: ::core::file!(),
            line: ::core::line!(),
            column: ::core::column!(),
            function: name.strip_suffix("::f").unwrap_or(name),
        }
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __details {
    () => {
        &$crate::Value::Null
    };
    ($details:expr) => {
        $details
    };
}

/// `condition` holds every time it is evaluated (and it is: a run that never evaluates it fails
/// it too). `always!(condition, "message")` or `always!(condition, "message", &json!({...}))`.
#[macro_export]
macro_rules! always {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always", $message);
        $crate::__assert("always", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `condition` holds every time it is evaluated, if it ever is.
#[macro_export]
macro_rules! always_or_unreachable {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always_or_unreachable", $message);
        $crate::__assert("always_or_unreachable", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `condition` holds at least once.
#[macro_export]
macro_rules! sometimes {
    ($condition:expr, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("sometimes", $message);
        $crate::__assert("sometimes", $condition, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// This line runs at least once.
#[macro_export]
macro_rules! reachable {
    ($message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("reachable", $message);
        $crate::__assert("reachable", true, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// This line never runs.
#[macro_export]
macro_rules! unreachable {
    ($message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("unreachable", $message);
        $crate::__assert("unreachable", true, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __comparison {
    ($kind:literal, $relation:literal, $left:expr, $right:expr, $message:literal $(, $details:expr)?) => {{
        $crate::__catalog_site!($kind, $message);
        $crate::__compare($kind, $relation, $left, $right, $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// `left > right` every time, with guidance toward a violation.
#[macro_export]
macro_rules! always_greater_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", ">", $left, $right, $message $(, $details)?)
    };
}

/// `left >= right` every time.
#[macro_export]
macro_rules! always_greater_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", ">=", $left, $right, $message $(, $details)?)
    };
}

/// `left < right` every time.
#[macro_export]
macro_rules! always_less_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", "<", $left, $right, $message $(, $details)?)
    };
}

/// `left <= right` every time.
#[macro_export]
macro_rules! always_less_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("always", "<=", $left, $right, $message $(, $details)?)
    };
}

/// `left > right` at least once, with guidance toward it.
#[macro_export]
macro_rules! sometimes_greater_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", ">", $left, $right, $message $(, $details)?)
    };
}

/// `left >= right` at least once.
#[macro_export]
macro_rules! sometimes_greater_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", ">=", $left, $right, $message $(, $details)?)
    };
}

/// `left < right` at least once.
#[macro_export]
macro_rules! sometimes_less_than {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", "<", $left, $right, $message $(, $details)?)
    };
}

/// `left <= right` at least once.
#[macro_export]
macro_rules! sometimes_less_than_or_equal {
    ($left:expr, $right:expr, $message:literal $(, $details:expr)? $(,)?) => {
        $crate::__comparison!("sometimes", "<=", $left, $right, $message $(, $details)?)
    };
}

/// At least one of the named conditions holds, every time:
/// `always_some!({ leader: a, follower: b }, "a role")`.
#[macro_export]
macro_rules! always_some {
    ({ $($name:ident : $condition:expr),+ $(,)? }, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("always", $message);
        $crate::__boolean("always", &[$((::core::stringify!($name), $condition)),+], $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

/// All the named conditions hold together, at least once.
#[macro_export]
macro_rules! sometimes_all {
    ({ $($name:ident : $condition:expr),+ $(,)? }, $message:literal $(, $details:expr)? $(,)?) => {{
        $crate::__catalog_site!("sometimes", $message);
        $crate::__boolean("sometimes", &[$((::core::stringify!($name), $condition)),+], $message, $crate::__details!($($details)?), $crate::__location!())
    }};
}

// Antithesis's names: its code ports with a changed import.

#[macro_export]
macro_rules! assert_always { ($($t:tt)*) => { $crate::always!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_or_unreachable { ($($t:tt)*) => { $crate::always_or_unreachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes { ($($t:tt)*) => { $crate::sometimes!($($t)*) }; }
#[macro_export]
macro_rules! assert_reachable { ($($t:tt)*) => { $crate::reachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_unreachable { ($($t:tt)*) => { $crate::unreachable!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_greater_than { ($($t:tt)*) => { $crate::always_greater_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_greater_than_or_equal_to { ($($t:tt)*) => { $crate::always_greater_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_less_than { ($($t:tt)*) => { $crate::always_less_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_less_than_or_equal_to { ($($t:tt)*) => { $crate::always_less_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_greater_than { ($($t:tt)*) => { $crate::sometimes_greater_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_greater_than_or_equal_to { ($($t:tt)*) => { $crate::sometimes_greater_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_less_than { ($($t:tt)*) => { $crate::sometimes_less_than!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_less_than_or_equal_to { ($($t:tt)*) => { $crate::sometimes_less_than_or_equal!($($t)*) }; }
#[macro_export]
macro_rules! assert_always_some { ($($t:tt)*) => { $crate::always_some!($($t)*) }; }
#[macro_export]
macro_rules! assert_sometimes_all { ($($t:tt)*) => { $crate::sometimes_all!($($t)*) }; }

/// Antithesis's start-up call: nothing to do here (the catalog announces itself as the program
/// starts), kept so its code ports unchanged.
pub fn antithesis_init() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_near_draws_every_edge_within_max() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..2000 {
            let value = random_near("test.batch", 64, 1000);
            assert!(value <= 1000);
            seen.insert(value);
        }
        for edge in [0, 1, 63, 64, 65, 128] {
            assert!(seen.contains(&edge), "edge {edge} never drawn");
        }
        assert!(random_near("test.small", 64, 10) <= 10);
    }

    #[test]
    fn prng_replays_from_its_seed() {
        let mut a = Prng::from_seed(7);
        let mut b = Prng::from_seed(7);
        let first: Vec<u64> = (0..4).map(|_| a.next_u64()).collect();
        let second: Vec<u64> = (0..4).map(|_| b.next_u64()).collect();
        assert_eq!(first, second);
        assert!(a.below(10) < 10);
        let mut items = [1, 2, 3, 4];
        a.shuffle(&mut items);
        items.sort();
        assert_eq!(items, [1, 2, 3, 4]);
    }

    #[test]
    fn assertions_and_catalog() {
        always!(1 + 1 == 2, "arithmetic holds", &json!({ "sum": 2 }));
        sometimes!(random_below(2) < 2, "a draw below two");
        reachable!("the test runs");
        always_greater_than!(3, 2, "three beats two");
        assert_always_greater_than_or_equal_to!(3u64, 3u64, "three ties three");
        always_some!({ a: true, b: false }, "a or b");
        sometimes_all!({ a: true, b: true }, "a and b");
        optimize("backlog", &json!({ "leader": "n1" }), 3.0, Goal::Maximize);
        optimize("ignored", &Value::Null, f64::NAN, Goal::Minimize);
        declare("sometimes", "a declared one");
        let listed = catalog::assertions();
        assert!(listed.iter().any(|entry| entry.message == "a declared one"));
        if cfg!(target_os = "linux") {
            assert!(listed.iter().any(|entry| entry.message == "three beats two" && entry.kind == "always"));
        }
        let mut out = Vec::new();
        catalog::write(&mut out).unwrap();
        assert!(String::from_utf8(out).unwrap().contains("a declared one"));
    }

    #[test]
    fn numbers_that_are_not_finite_stay_json() {
        assert_eq!(operand(f64::INFINITY), json!("Infinity"));
        assert_eq!(operand(f64::NEG_INFINITY), json!("-Infinity"));
        assert_eq!(operand(f64::NAN), json!("NaN"));
        assert_eq!(operand(3u64), json!(3));
        assert_eq!(operand(2.5f64), json!(2.5));
        assert_eq!(json!(finite_distance(f64::NEG_INFINITY)), json!(-f64::MAX));
        always_less_than!(f64::INFINITY, 100.0, "latency stays under 100 ms");
    }

    #[test]
    fn decisions_outside_determinismo() {
        assert!(decide("which", &["a", "b"]) < 2);
        assert!(random_below_named("jitter", 5) < 5);
        assert!(!buggify("anywhere"));
        buggify_pause("anywhere");
        assert!(random() < 1.0);
        assert_eq!(random_choice::<u8>(&[]), None);
    }
}
