// SPDX-License-Identifier: MIT
/*
 * The self-test's maze on the JVM: four digits from platform randomness, each checked before the
 * next is drawn; 1 in 10000 attempts solves it by chance. With line coverage (the agent), a
 * coverage-guided strategy climbs it one digit at a time.
 *
 * Its digits pass through Step, whose own code joins a Step and a Digit (`mine ? this : ...`):
 * the agent's stack maps need Step's hierarchy while Step is being defined. An agent that loaded
 * a class to learn it defined Step twice, and the JVM refused ("duplicate class definition"): the
 * maze never ran (ZooKeeper's ensemble never formed so; srv4, 2026-10-31).
 */
public final class Maze {
  static class Digit {
    long value() {
      return Determinismo.randomBelow(10);
    }
  }

  static final class Step extends Digit {
    Digit next(boolean mine) {
      Digit chosen = mine ? this : new Digit();
      return chosen;
    }
  }

  public static void main(String[] arguments) {
    boolean solved = false;
    if (digit() == 7) {
      Determinismo.reachable("maze: first digit", null);
      if (digit() == 3) {
        Determinismo.reachable("maze: second digit", null);
        if (digit() == 9) {
          Determinismo.reachable("maze: third digit", null);
          if (digit() == 1) solved = true;
        }
      }
    }
    Determinismo.always(!solved, "the maze is never solved", null);
  }

  private static long digit() {
    return new Step().next(true).value();
  }
}
