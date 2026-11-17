// SPDX-License-Identifier: MIT
/**
 * One run of the race of examples/race, in Java: 64 threads, each incrementing the counter if it
 * is still zero; an AssertionError when all 64 did. Only this class is instrumented (the coverage
 * agent's prefix): the runner is no hint.
 */
public final class RaceRun {
  private static final int THREADS = 64;
  private static int counter;

  private RaceRun() {}

  private static void update() {
    if (counter == 0) counter++;
  }

  static int run() throws InterruptedException {
    counter = 0;
    Thread[] threads = new Thread[THREADS];
    for (int index = 0; index < THREADS; index++) {
      threads[index] = new Thread(RaceRun::update);
      threads[index].start();
    }
    for (Thread thread : threads) thread.join();
    if (counter == THREADS) throw new AssertionError("all 64 threads incremented the counter");
    return counter;
  }
}
