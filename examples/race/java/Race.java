// SPDX-License-Identifier: MIT
/**
 * The race of examples/race in Java: runs (RaceRun) again and again in this JVM, printing every
 * run's counter (the same line each run: no hint for the explorer). A run's AssertionError ends
 * the JVM: "no uncaught exceptions (Java)".
 */
public final class Race {
  private Race() {}

  public static void main(String[] arguments) throws InterruptedException {
    for (long runs = 1; ; runs++) {
      System.out.println("run " + runs + ": counter " + RaceRun.run());
    }
  }
}
