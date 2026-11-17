// SPDX-License-Identifier: MIT
// A check-then-act race between threads: the toy of "Hillel joins Antithesis"
// (https://antithesis.com/blog/2026/hillel-joins-antithesis/). Every thread increments a shared
// counter if it is still zero, so it ends at 1 unless threads interleave between the check and
// the increment; a run asserts that not all 64 of them did. Natively, 100 million runs never had
// even three threads race; Antithesis found all 64 a hundred times in five minutes.
//
// Built at -O0 (build.zig): at -O1 the compiler turns the increment into a store of 1, and the
// counter never passes 1.
//
// `race run` is one run, its counter its exit status. Without arguments, a runner: runs again and
// again, each a fresh process (a new address space, as a shell starting it each time), printing
// every run's counter. No hint for the explorer: the runner is never instrumented for coverage
// (a race is no new edge), and every run prints the same line (a race is no new kind of output
// line, which the tree counts as a behavior).
#include <cassert>
#include <cstdio>
#include <cstring>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
#include <vector>

extern char **environ;

static const int threads_count = 64;
int counter = 0;

static void update() {
  if (counter == 0) counter++;
}

static int run() {
  std::vector<std::thread> threads(threads_count);
  for (auto &thread : threads) thread = std::thread(update);
  for (auto &thread : threads) thread.join();
  assert(counter != threads_count);
  return counter;
}

__attribute__((no_sanitize("coverage"))) int main(int argc, char **argv) {
  if (argc > 1 && std::strcmp(argv[1], "run") == 0) return run();
  char *const arguments[] = {argv[0], const_cast<char *>("run"), nullptr};
  for (unsigned long runs = 1;; runs++) {
    pid_t pid;
    if (posix_spawn(&pid, argv[0], nullptr, nullptr, arguments, environ) != 0) {
      std::perror("posix_spawn");
      return 1;
    }
    int status;
    if (waitpid(pid, &status, 0) < 0) {
      std::perror("waitpid");
      return 1;
    }
    if (WIFEXITED(status)) std::printf("run %lu: counter %d\n", runs, WEXITSTATUS(status));
  }
}
