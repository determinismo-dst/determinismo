// SPDX-License-Identifier: MIT
// The race of examples/race in C#: runs (RaceRun) again and again in this process, printing every
// run's counter (the same line each run: no hint for the explorer). A run's exception is
// unhandled: it ends the process.
for (long runs = 1; ; runs++) Console.WriteLine($"run {runs}: counter {RaceRun.Run()}");
