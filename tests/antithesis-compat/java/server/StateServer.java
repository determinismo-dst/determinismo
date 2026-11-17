// SPDX-License-Identifier: MIT
/*
 * A server whose role moves through an enum (FOLLOWER, CANDIDATE, LEADER, again and again), each
 * step after some work, its epoch bumped as it becomes leader (before its role says so, as a
 * term is): the Java agent's crash points, at its state transitions and its epoch's stores,
 * crash it there (tools/e2e.zig's crash-points check). A stretch's first point reached is the
 * one asked: with the epoch stored after the role, a transition's point came first almost
 * always (3 or 4 asks in the check's 16 timelines, the epoch's among them one time in seven). The work gives the agent's probes their pace (it looks
 * at the clock every 4096 of them).
 */
public final class StateServer {
  enum Role { FOLLOWER, CANDIDATE, LEADER }

  private Role role = Role.FOLLOWER;
  /** Bumped as it becomes leader: a meta-info store (its name), a crash point too. */
  private long epoch;
  private long work;

  public static void main(String[] arguments) throws InterruptedException {
    StateServer server = new StateServer();
    while (true) {
      server.step();
      Thread.sleep(5);
    }
  }

  private void step() {
    for (int index = 0; index < 64; index++) {
      work = work * 31 + index;
    }
    if (role == Role.CANDIDATE) epoch++;
    role = switch (role) {
      case FOLLOWER -> Role.CANDIDATE;
      case CANDIDATE -> Role.LEADER;
      case LEADER -> Role.FOLLOWER;
    };
  }
}
