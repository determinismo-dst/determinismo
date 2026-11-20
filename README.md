# Determinismo

NOTE This README is written by me, Paulo, the human, but the code is entirely
LLM-generated.

Determinismo is a project where we build/experiment with a deterministic environment
à la Antithesis ( https://antithesis.com/ ), but where I try to make everything as
pluggable as possible (strategies, stepper, fault injection, clock drift, we can upload
hooks as wasm etc) and accessible via an API and, specially, via nrepl (clj, jank,
bb, but focusing more on jank at the moment).

Think of it as a hot-reloadable deterministic environment (I'm used to the
fast-feedback from clj, so I want to push it everywhere).

We use here concepts like swarm testing, code coverage-guided exploration, fuzzing,
fault injections.

I will update this README as needed.

## Learning a lot, thanks to

- Antithesis ofc, https://antithesis.com/
- Jepsen, AWESOME analyses, Kyle is a genius! https://jepsen.io/analyses
- Quint, CEO Gabi! Formal methods (FM) https://quint.sh/
- TLA+, my first contact with FM, Lamport doesn't need words ofc https://lamport.azurewebsites.net/tla/tla.html

## Research Papers / Links

- Swarm Testing, https://users.cs.utah.edu/~regehr/papers/swarm12.pdf (LOVE IT)
- Ijon: Exploring Deep State Spaces via Fuzzing, https://nyx-fuzz.com/papers/ijon.pdf
- SKI: Exposing Kernel Concurrency Bugs through Systematic Schedule Exploration, https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-fonseca.pdf
- Test-Case Reduction via Test-Case Generation: Insights from the Hypothesis Reducer, https://drops.dagstuhl.de/storage/00lipics/lipics-vol166-ecoop2020/LIPIcs.ECOOP.2020.13/LIPIcs.ECOOP.2020.13.pdf
- The Fuzzing Book, https://www.fuzzingbook.org/
- The Use of Likely Invariants as Feedback for Fuzzers, https://www.usenix.org/system/files/sec21-fioraldi.pdf
- When Amnesia Strikes: Understanding and Reproducing Data Loss Bugs with Fault Injection, https://www.vldb.org/pvldb/vol17/p3017-ramos.pdf

## AI over-verbose README

Go to [README_AI.md](README_AI.md).
