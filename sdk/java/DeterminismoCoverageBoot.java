// SPDX-License-Identifier: MIT
import java.lang.instrument.Instrumentation;

/**
 * The coverage agent's entry point (its jar's Premain-Class), compiled for Java 8 so any JVM
 * loads it: on JDK 24 and later (java.lang.classfile) it starts DeterminismoCoverage; before,
 * it says once, on standard error, that this JVM is not instrumented and why, and the program
 * runs as it is. Determinismo puts this jar in every node's JAVA_TOOL_OPTIONS (guest/runtime/
 * nodes.zig): a JVM's code covered, and where thread pausing pauses, with no change to an image.
 */
public final class DeterminismoCoverageBoot {
  private DeterminismoCoverageBoot() {}

  public static void premain(String arguments, Instrumentation instrumentation) {
    String version = System.getProperty("java.specification.version", "");
    int feature;
    try {
      feature = Integer.parseInt(version.startsWith("1.") ? version.substring(2) : version);
    } catch (NumberFormatException unknown) {
      feature = 0;
    }
    if (feature < 24) {
      System.err.println("[determinismo] this JVM (Java " + version + ") is not instrumented: "
          + "determinismo's coverage agent needs JDK 24 or later (java.lang.classfile)");
      return;
    }
    try {
      Class.forName("DeterminismoCoverage")
          .getMethod("premain", String.class, Instrumentation.class)
          .invoke(null, arguments, instrumentation);
    } catch (ReflectiveOperationException failed) {
      System.err.println("[determinismo] the coverage agent did not start: " + failed);
    }
  }
}
