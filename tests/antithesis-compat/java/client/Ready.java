// SPDX-License-Identifier: MIT
/*
 * The client's setup: done once the JVM runs, said as an Antithesis workload says it (the SDK's
 * setup_complete). Without it the composer waited its 300 s for the signal at every run, and a
 * first generation's behaviors, all in the last fraction of a second of a 300-second timeline,
 * were never moments to return to.
 */
public final class Ready {
  public static void main(String[] arguments) {
    Determinismo.setupComplete(null);
  }
}
