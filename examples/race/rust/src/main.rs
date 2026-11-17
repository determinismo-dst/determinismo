// SPDX-License-Identifier: MIT
//! The race of examples/race in Rust, built with rustc's trace-pc-guard and the SDK's callbacks:
//! 64 threads, each incrementing a shared counter if it is still zero (a check-then-act on an
//! atomic: no data race, a race condition). `race run` is one run, its counter plus 10 its exit
//! status, a panic when all 64 incremented it. Without arguments, a runner: runs again and
//! again, each a fresh process, printing every run's counter (the same line each run: no hint
//! for the explorer).
extern crate determinismo; // Its coverage callbacks.

use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::thread;

const THREADS: usize = 64;
static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn update() {
    if COUNTER.load(Relaxed) == 0 {
        COUNTER.store(COUNTER.load(Relaxed) + 1, Relaxed);
    }
}

fn run() -> i32 {
    let threads: Vec<_> = (0..THREADS).map(|_| thread::spawn(update)).collect();
    for thread in threads {
        thread.join().expect("a thread");
    }
    let counter = COUNTER.load(Relaxed);
    assert_ne!(counter, THREADS, "all 64 threads incremented the counter");
    counter as i32 + 10
}

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).map(String::as_str) == Some("run") {
        std::process::exit(run());
    }
    for runs in 1u64.. {
        let status = Command::new(&arguments[0]).arg("run").status().expect("a run");
        if let Some(code) = status.code() {
            println!("run {runs}: counter {}", code - 10);
        }
    }
}
