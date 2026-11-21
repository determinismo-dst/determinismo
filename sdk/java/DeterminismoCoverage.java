// SPDX-License-Identifier: MIT
/*
 * Code coverage for strategies on the JVM: a Java agent that makes each source line of the
 * classes it is told about emit a "coverage" event the first time it runs ({"name":"line
 * <class>:<line>"}), as the C, Zig and Python SDKs do. Strategies such as det-strategy-mutate
 * keep the timelines that reach new code.
 *
 * This class is what instrumented code calls (the probes, thread pausing, crash points, their
 * reports), for Java 17 and later; DeterminismoCoverageInstrument rewrites the classes, through
 * JDK 24's java.lang.classfile API: as they load on a JVM of 24 or later, or ahead of time (below)
 * with a JDK of 24 or later, for a program then run on any JVM from 17 on (Cassandra's, pinned
 * to 17 or 21 by its scripts).
 *
 *   java -javaagent:determinismo-coverage.jar[=<class name prefixes, comma-separated>] ...
 *
 * What it instruments: the classes under the agent's prefixes (every class but the JDK's when
 * none is given) that the node's coverage set holds, DETERMINISMO_COVERAGE (the Zig SDK's
 * schema.Coverage: class name prefixes, those starting with "-" excluded): the set, from a test
 * program's profile, scopes it at no change to the image.
 *
 * The jar holds this class, the instrumenter and Determinismo, with "Premain-Class:
 * DeterminismoCoverageBoot" in its manifest. Classes defined at run time (Clojure's, for
 * instance) are instrumented too.
 *
 * Or ahead of time, at an image's build, with no agent at run time:
 *
 *   java -cp determinismo-coverage.jar:<the program's classpath> DeterminismoCoverage \
 *       instrument <prefixes> <in.jar> <out.jar> [<in.jar> <out.jar>]...
 *
 * (a JDK of 24 or later) rewrites the classes under the prefixes of each jar with the same
 * probes, the table of their ids (lines, fields, blocks, the classes) a resource of the first jar
 * written; the coverage jar on the classpath then reads it as this class loads (the agent on a
 * JVM's JAVA_TOOL_OPTIONS puts it there). Classes are then loaded as they are,
 * so a JDK AOT cache holds for them: an agent transforming at load costs a JVM most of its
 * start and the cache's help (a Datalevin server: 16.5 s to load with the agent, 4.7 s with
 * its cache and no agent, on one of srv4's cores). The agent leaves the table's classes alone. A probe
 * costs an array read once its line has been reported, and is where thread pausing may pause
 * (`pausing`). So is a probe after each conditional branch, where its fall-through block starts:
 * a check and its act on one line (`if (x == 0) x++;`) have a point between them, as with
 * edge instrumentation.
 *
 * States too, as SGFuzz finds them (USENIX Security 2022: enum-typed variables are a program's
 * state): each store to a field outside initializers whose value is an enum constant of the
 * program's own (not the JDK's) reports the transition, old constant to new, the first time it
 * happens ({"name":"state <class>.<field>: OLD -> NEW"}, a "state" event), so the tree returns
 * to the timelines that reach a new one (a transaction's ONGOING -> PREPARE_ABORT) even where
 * no new line runs.
 *
 * And crash points there (CrashTuner, Lu et al., SOSP 2019: crash-recovery bugs sit where a node
 * updates its view of the cluster, a role, a session, an epoch): inside determinismo, one stretch
 * of two seconds in eight (DETERMINISMO_CRASH_POINTS: another number, or 0 for none; a named
 * decision, "crash points", at the stretch's start), one state transition in four (by its field,
 * old and new constant, drawn for the stretch) is a crash point: the first one a thread reaches
 * asks the fault injector to crash this node now (det-faults crash-point), and the thread waits
 * there, before the store or at its next probe after it (drawn), up to half a second. The
 * injector grants it as one of the node's crash faults the swarm keeps (a kill or a power loss),
 * outside quiet periods (`crash_point` events say each request's outcome). At most one a stretch.
 * Stores to fields whose names say they hold the node's view of the cluster (leader, epoch, term,
 * session, member, owner...: CrashTuner's meta-info, whatever their type) are points the same way.
 *
 * And watches, the REPL's watch-values and calls for the JVM (a Java field has no fixed address
 * for a hardware watchpoint, nor a JIT-compiled method a fixed entry): the node's
 * DETERMINISMO_WATCH (comma-separated: `<class>.<field>`, `<class>.<method>()`) names fields
 * whose every store says its value and methods whose every call says its arguments, a "watch"
 * event each ({"name":"field com.x.Raft.currentTerm","value":5,"object":"com.x.Raft@1b6d3586"},
 * {"name":"call com.x.Raft.handleVote","args":[...],"object":...}), said by the storing or
 * calling thread at that moment, so a run's every timeline holds them for event queries. A
 * value is a primitive's, a string's (cut at 200 characters), an enum's name, or else the
 * object's class and identity: no program code (toString) runs for it. The first
 * DETERMINISMO_WATCH_MAX (10,000) of each in a process, then one event with "over".
 */
import java.lang.instrument.Instrumentation;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public final class DeterminismoCoverage {
  static final List<String> lines = new ArrayList<>();
  private static final Map<String, Integer> ids = new HashMap<>();
  /** The lines' and fields' names by id, for a probe's own report: read with no lock, each
   * array published whole (a volatile store) once a name is in it, before its class runs. */
  private static volatile String[] lineNames = new String[1024];
  private static volatile String[] fieldNames = new String[64];
  /** Lines reported, in pages of 65,536 ids. A page never moves once made: a probe marks its
   * line there itself, and no mark is lost to a copy (an array grown by copying lost the mark
   * of a probe that wrote the old one meanwhile, and its line took the slow path ever after). */
  private static final int REPORTED_PAGE_BITS = 16;
  private static final java.util.concurrent.atomic.AtomicReferenceArray<boolean[]> reported =
      new java.util.concurrent.atomic.AtomicReferenceArray<>(1 << (30 - REPORTED_PAGE_BITS));
  static final List<String> fields = new ArrayList<>();
  private static final Map<String, Integer> fieldIds = new HashMap<>();
  /** Transitions reported: field id, old ordinal + 1 (0 for null), new ordinal + 1. */
  private static final Set<Long> transitions = ConcurrentHashMap.newKeySet();
  /** The table of an ahead-of-time instrumentation: a resource of its first jar. */
  static final String TABLE = "determinismo-coverage.table";
  /** Classes instrumented ahead of time (internal names): the agent leaves them alone. */
  static final Set<String> ahead = ConcurrentHashMap.newKeySet();

  private DeterminismoCoverage() {}

  /**
   * The agent's start, on JDK 24 or later: the platform's jar's DeterminismoCoverageBoot calls it,
   * and a program's own agent jar names this class its Premain-Class (`=<class name prefixes>`
   * narrowing what is covered). The instrumenter, which needs JDK 24's java.lang.classfile,
   * installs its transformer; a jar without it (its Dockerfile copied no
   * DeterminismoCoverageInstrument.java) says so, and the program runs uninstrumented.
   */
  public static void premain(String arguments, Instrumentation instrumentation) {
    try {
      Class.forName("DeterminismoCoverageInstrument")
          .getMethod("premain", String.class, Instrumentation.class)
          .invoke(null, arguments, instrumentation);
    } catch (ReflectiveOperationException | LinkageError failed) {
      System.err.println("[determinismo] the coverage agent did not start: " + failed);
    }
  }

  /** Initializes this class (its sender, its exit hook, an ahead-of-time table): the
   * instrumenter's premain calls it before it transforms any class. */
  static void start() {}

  /** Called by instrumented code at the start of each line. */
  public static void line(int id) {
    boolean[] page = reported.get(id >>> REPORTED_PAGE_BITS);
    if ((page == null || !page[id & ((1 << REPORTED_PAGE_BITS) - 1)]) && queued.add(id)) first(id);
    if (crashAfterThread != null) crashAfterReached();
    pausing(id);
  }

  /*
   * A line's first run, and a state's first transition, are reported by the thread that ran
   * them, as they happen: the event is that thread's (its source the program's, as its decisions
   * are) and comes before what the line does next. Through the sender they came some 0.1 to 1
   * ms late and as the sender's: the tree's return just after a new state landed past the
   * program's next draws, and a strategy changing the decisions of the process that reached a
   * feature changed the sender's own (e2e `states`, 0 of 256 timelines solved, and the Java
   * maze of `coverage`, none of 134 past the second digit: det-strategy-mutate's frontier was
   * the sender's "crash points" draw). No lock on the way (below): one write to the device,
   * names and marks read and written with none. A virtual thread's go through the sender still
   * (its write would park it; its source is its carrier's anyway), and every report outside
   * determinismo (the SDK's local output is a stream with a lock of its own).
   */
  private static boolean direct() {
    if (!pausingInside) return false;
    String kind = Thread.currentThread().getClass().getName();
    return !kind.equals("java.lang.VirtualThread") && !kind.endsWith("BoundVirtualThread");
  }

  private static void first(int id) {
    if (direct()) {
      String[] names = lineNames;
      String name = id < names.length ? names[id] : null;
      StringBuilder details = new StringBuilder(48).append("{\"name\":\"line ");
      if (name != null) details.append(name);
      else details.append('?').append(id);
      if (Determinismo.eventUnlocked("coverage", details.append("\"}").toString())) {
        mark(id);
        return;
      }
    }
    send(id);
  }

  /** The line is reported: its probes take the fast path from now on. */
  private static void mark(int id) {
    int index = id >>> REPORTED_PAGE_BITS;
    boolean[] page = reported.get(index);
    if (page == null) {
      reported.compareAndSet(index, null, new boolean[1 << REPORTED_PAGE_BITS]);
      page = reported.get(index);
    }
    page[id & ((1 << REPORTED_PAGE_BITS) - 1)] = true;
    reported.set(index, page); // Publishes the write to the probes (a volatile store).
  }

  /** Called by instrumented code after each conditional branch: a point for thread pausing. */
  public static void block(int id) {
    if (crashAfterThread != null) crashAfterReached();
    pausing(id);
  }

  /*
   * Thread pausing (Antithesis's, which needs their instrumentation too), the C SDK's
   * det_pausing_at: inside determinismo, one stretch of two seconds (virtual time) in four, a
   * named decision ("thread pausing") at the stretch's start, one line in 64 is a slow point with
   * its own pause (1 to 10 ms), drawn for the stretch: a thread reaching one waits there, at most
   * 8 times a stretch. Threads that reach a slow point wait there together, so the checks of a
   * check-then-act between them all run before any of its acts. The clock is read at the first
   * probe and every 4096 after (of all threads: the countdown is shared, racy on purpose); the
   * stretch's draw is the sender's (below).
   */
  private static final boolean pausingInside = Determinismo.inside();
  private static final int PAUSING_PROBES_PER_LOOK = 4096;
  private static final int PAUSING_PAUSES_MAX = 8;
  /** The clock's 2-second count + 1 of the stretch drawn; 0 before any. */
  private static volatile long pausingStretch;
  /** The stretch a probe saw begin, for the sender to draw. */
  private static volatile long pausingWanted;
  /** The stretch's, odd; 0 when it pauses nothing. */
  private static volatile long pausingSeed;
  private static int pausingCountdown;
  /** Per thread: the stretch its pauses count in, and how many. */
  private static final ThreadLocal<long[]> pausingThread = ThreadLocal.withInitial(() -> new long[2]);

  private static void pausing(int id) {
    if (!pausingInside) return;
    if (--pausingCountdown <= 0) {
      pausingCountdown = PAUSING_PROBES_PER_LOOK;
      long stretch = System.nanoTime() / 2_000_000_000L + 1; // Virtual time inside determinismo.
      if (stretch != pausingWanted) {
        pausingWanted = stretch;
        java.util.concurrent.locks.LockSupport.unpark(sender);
      }
    }
    long seed = pausingSeed;
    if (seed == 0) return;
    long value = mix(seed ^ id); // The line's draw for the stretch.
    if (Long.remainderUnsigned(value, 64) != 0) return;
    long[] thread = pausingThread.get();
    long stretch = pausingStretch;
    if (thread[0] != stretch) {
      thread[0] = stretch;
      thread[1] = 0;
    }
    if (thread[1] == PAUSING_PAUSES_MAX) return;
    thread[1]++;
    try {
      Thread.sleep(1 + Long.remainderUnsigned(value >>> 8, 10));
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt(); // The program's to see, at its next wait.
    }
  }

  private static long mix(long value) {
    value *= 0x9e3779b97f4a7c15L;
    value ^= value >>> 29;
    value *= 0xbf58476d1ce4e5b9L;
    value ^= value >>> 32;
    return value;
  }

  /* Crash points (the header's). */
  private static final int CRASH_POINTS_ONE_IN = crashPointsOneIn();
  private static final int CRASH_POINT_TRANSITIONS_ONE_IN = 4;
  /** How long a thread at a crash point waits for its crash (the injector drops older asks). */
  private static final long CRASH_POINT_WAIT_NS = 500_000_000L;
  /** The stretch's, odd; 0 when it has no crash points. */
  private static volatile long crashSeed;
  /** The stretch a crash point was asked in last: one a stretch. */
  private static final java.util.concurrent.atomic.AtomicLong crashAsked =
      new java.util.concurrent.atomic.AtomicLong();
  private static final java.util.concurrent.atomic.AtomicLong crashSerial =
      new java.util.concurrent.atomic.AtomicLong();
  /** The last request the injector could not be asked for: its thread goes on at once. */
  private static volatile long crashDeclined;
  /** A crash point after a store: its thread, which waits at its next probe. Plain fields: only
   * that thread acts on them (another sees a thread not its own, or null). */
  private static Thread crashAfterThread;
  private static String[] crashAfterPoint;

  private record CrashRequest(long serial, int field, String before, String next, boolean after,
      long askedNs) {}

  private static int crashPointsOneIn() {
    String text = System.getenv("DETERMINISMO_CRASH_POINTS");
    if (text == null || text.isEmpty()) return 8;
    try {
      return Math.max(0, Integer.parseInt(text.trim()));
    } catch (NumberFormatException unreadable) {
      return 8;
    }
  }

  /** Called by instrumented code before a store to a meta-info field (metaInfo). */
  public static void crashStore(int field) {
    if (crashSeed == 0) return;
    crashPoint(((long) field << 32) | 0xffff_ffffL, field, null, null);
  }

  /** A state transition (before its store), or a meta-info store (`before` null): a crash
   * point, maybe. */
  private static void crashPoint(long key, int field, String before, String next) {
    long seed = crashSeed;
    if (seed == 0) return;
    long value = mix(seed ^ key);
    if (Long.remainderUnsigned(value, CRASH_POINT_TRANSITIONS_ONE_IN) != 0) return;
    long stretch = pausingStretch;
    long asked = crashAsked.get();
    if (asked == stretch || !crashAsked.compareAndSet(asked, stretch)) return;
    if ((value >>> 8 & 1) == 0) {
      crashWait(field, before, next, false);
    } else {
      crashAfterPoint = new String[] {Integer.toString(field), before, next};
      crashAfterThread = Thread.currentThread();
    }
  }

  private static void crashAfterReached() {
    if (crashAfterThread != Thread.currentThread()) return;
    String[] point = crashAfterPoint;
    crashAfterThread = null;
    crashAfterPoint = null;
    if (point != null) crashWait(Integer.parseInt(point[0]), point[1], point[2], true);
  }

  /** Asks for the crash (through the sender) and waits for it, at most CRASH_POINT_WAIT_NS. */
  private static void crashWait(int field, String before, String next, boolean after) {
    long serial = crashSerial.incrementAndGet();
    long asked = System.nanoTime();
    send(new CrashRequest(serial, field, before, next, after, asked));
    while (crashDeclined != serial && System.nanoTime() - asked < CRASH_POINT_WAIT_NS) {
      try {
        Thread.sleep(5);
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt(); // The program's to see, at its next wait.
        return;
      }
    }
  }

  /*
   * A probe waits for no lock: it may run in any class's initializer, with other threads (a
   * carrier among them, pinned) waiting for that initialization, and a lock's holder may wait
   * for it too. What it reports itself (`first`, a state's transition) is one write to the
   * device. The rest goes to a sender thread of the agent's through a lock-free queue: the
   * stretches' draws, crash requests, a virtual thread's reports and every report outside
   * determinismo; the sender calls the SDK (whose emit is synchronized). Probes calling the
   * SDK's emit deadlocked JVMs twice (core.async, hunt runs 1115 and 1122): an instrumented
   * initializer's first probe waited for the agent's monitor, then for the SDK's, each held by a
   * virtual thread that needed the only carrier, pinned waiting for that initialization
   * (sdk/java/coverage_test.zig).
   */

  /** Lines whose first report was taken: by their probe's thread, or queued for the sender. */
  private static final Set<Integer> queued = ConcurrentHashMap.newKeySet();
  /** Reports for the sender: a line's id, or a state transition's event. */
  private static final java.util.concurrent.ConcurrentLinkedQueue<Object> outbox =
      new java.util.concurrent.ConcurrentLinkedQueue<>();
  private static final Thread sender = senderStart();

  private static Thread senderStart() {
    Thread thread = new Thread(DeterminismoCoverage::senderRun, "determinismo-coverage");
    thread.setDaemon(true);
    thread.start();
    // What is still queued as the JVM exits goes out first. A JVM already exiting as the agent
    // loads (a node stopped during its start: CrateDB, hunt run 1893) takes no hook, and its
    // exit goes on: refused, the hook failed this class's initialization, the premain, and the
    // JVM aborted ("processing of -javaagent failed"), an uncaught exception of ours blamed on
    // the system.
    try {
      Runtime.getRuntime().addShutdownHook(new Thread(() -> {
        for (Object report; (report = outbox.poll()) != null; ) deliver(report);
      }, "determinismo-coverage-exit"));
    } catch (IllegalStateException shuttingDown) {
      // Nothing to deliver at an exit already under way: the program has not run.
    }
    return thread;
  }

  private static void send(Object report) {
    outbox.add(report);
    java.util.concurrent.locks.LockSupport.unpark(sender);
  }

  private static void senderRun() {
    while (true) {
      try {
        long wanted = pausingWanted;
        if (wanted != pausingStretch) {
          pausingSeed = Determinismo.randomBelowNamed("thread pausing", 4) == 0
              ? Determinismo.randomLong() | 1 : 0;
          crashSeed = CRASH_POINTS_ONE_IN > 0
              && Determinismo.randomBelowNamed("crash points", CRASH_POINTS_ONE_IN) == 0
              ? Determinismo.randomLong() | 1 : 0;
          pausingStretch = wanted;
        }
        for (Object report; (report = outbox.poll()) != null; ) deliver(report);
        if (outbox.isEmpty() && pausingWanted == pausingStretch) {
          java.util.concurrent.locks.LockSupport.park(); // An unpark since the checks returns at once.
        }
      } catch (Throwable unreported) {
        // Coverage is best effort: the sender goes on with the next report.
      }
    }
  }

  private static void deliver(Object report) {
    if (report instanceof Integer id) {
      String line;
      synchronized (DeterminismoCoverage.class) {
        line = id < lines.size() ? lines.get(id) : "?" + id;
      }
      mark(id);
      Determinismo.event("coverage", "{\"name\":\"line " + line + "\"}");
    } else if (report instanceof Object[] state) {
      String name;
      synchronized (DeterminismoCoverage.class) {
        int id = (Integer) state[0];
        name = id < fields.size() ? fields.get(id) : "?" + id;
      }
      Determinismo.event("state", "{\"name\":\"state " + name + ": " + state[1] + " -> "
          + state[2] + "\"}");
    } else if (report instanceof Watched watched) {
      Determinismo.event("watch", watched.details());
    } else if (report instanceof CrashRequest crash) {
      String name;
      synchronized (DeterminismoCoverage.class) {
        name = crash.field() < fields.size() ? fields.get(crash.field()) : "?" + crash.field();
      }
      String point = (crash.before() == null ? "store " + name
          : "state " + name + ": " + crash.before() + " -> " + crash.next())
          + (crash.after() ? " (after)" : " (before)");
      boolean sent = false;
      try {
        sent = new ProcessBuilder("/opt/determinismo/bin/det-faults", "crash-point",
            Long.toString(crash.askedNs()), point)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start().waitFor() == 0;
      } catch (java.io.IOException | InterruptedException unavailable) {
        // No injector to ask: the thread goes on.
      }
      if (!sent) crashDeclined = crash.serial();
    }
  }

  /** Called by instrumented code before a store to a field that may hold a state. */
  public static void state(Object value, Object old, int id) {
    if (!(value instanceof Enum<?> next) || value == old) return;
    Enum<?> before = old instanceof Enum<?> known ? known : null;
    long key = ((long) id << 32) | ((long) (before == null ? 0 : before.ordinal() + 1) << 16)
        | (next.ordinal() + 1);
    crashPoint(key, id, before == null ? "null" : before.name(), next.name());
    if (!transitions.add(key)) return;
    if (direct()) {
      String[] names = fieldNames;
      String name = id < names.length ? names[id] : null;
      StringBuilder details = new StringBuilder(96).append("{\"name\":\"state ");
      if (name != null) details.append(name);
      else details.append('?').append(id);
      details.append(": ").append(before == null ? "null" : before.name()).append(" -> ")
          .append(next.name()).append("\"}");
      if (Determinismo.eventUnlocked("state", details.toString())) return;
    }
    send(new Object[] {id, before == null ? "null" : before.name(), next.name()});
  }

  /** A watch's event, for the sender when its thread cannot write it itself. */
  private record Watched(String details) {}

  static final int WATCH_MAX = watchMax();
  private static final ConcurrentHashMap<Integer, java.util.concurrent.atomic.AtomicInteger> watchCounts =
      new ConcurrentHashMap<>();

  private static int watchMax() {
    String text = System.getenv("DETERMINISMO_WATCH_MAX");
    if (text == null || text.isEmpty()) return 10_000;
    try {
      return Math.max(0, Integer.parseInt(text.trim()));
    } catch (NumberFormatException unreadable) {
      return 10_000;
    }
  }

  /**
   * Called by instrumented code before a store to a watched field: the value about to be stored
   * (boxed) and the object it goes into (null: a static field, or a store in a constructor,
   * where the object may not be usable yet).
   */
  public static void watchStore(Object object, Object value, int id) {
    StringBuilder details = watchStart(id, "field ");
    if (details == null) return;
    details.append(",\"value\":");
    watchValue(details, value);
    if (object != null) {
      details.append(",\"object\":");
      watchIdentity(details, object);
    }
    watchSay(details.append('}'));
  }

  /** Called at a watched method's entry: its arguments (boxed) and `this` (null: a static method
   * or a constructor). */
  public static void watchCall(Object self, Object[] arguments, int id) {
    StringBuilder details = watchStart(id, "call ");
    if (details == null) return;
    details.append(",\"args\":[");
    for (int index = 0; index < arguments.length; index++) {
      if (index > 0) details.append(',');
      watchValue(details, arguments[index]);
    }
    details.append(']');
    if (self != null) {
      details.append(",\"object\":");
      watchIdentity(details, self);
    }
    watchSay(details.append('}'));
  }

  /** The event's start ({"name":"<kind><name>"), or null past the watch's cap (the first one
   * past it says "over" itself). No lambda and no string concatenation: a probe may run inside a
   * class's initializer, where linking a call site is nothing to start. */
  private static StringBuilder watchStart(int id, String kind) {
    Integer key = id;
    java.util.concurrent.atomic.AtomicInteger count = watchCounts.get(key);
    if (count == null) {
      java.util.concurrent.atomic.AtomicInteger fresh = new java.util.concurrent.atomic.AtomicInteger();
      count = watchCounts.putIfAbsent(key, fresh);
      if (count == null) count = fresh;
    }
    int seen = count.incrementAndGet();
    if (seen > WATCH_MAX + 1) return null;
    String[] names = fieldNames;
    String name = id < names.length ? names[id] : null;
    StringBuilder details = new StringBuilder(128).append("{\"name\":\"").append(kind);
    if (name != null) details.append(name);
    else details.append('?').append(id);
    details.append('"');
    if (seen == WATCH_MAX + 1) {
      watchSay(details.append(",\"over\":").append(WATCH_MAX).append('}'));
      return null;
    }
    return details;
  }

  private static void watchSay(StringBuilder details) {
    String text = details.toString();
    if (direct() && Determinismo.eventUnlocked("watch", text)) return;
    send(new Watched(text));
  }

  /** A value as JSON with no program code run: the JDK's boxes, strings and enums' names, a
   * Clojure keyword's name, any other object its class and identity. */
  private static void watchValue(StringBuilder out, Object value) {
    if (value == null) {
      out.append("null");
    } else if (value instanceof Boolean || value instanceof Integer || value instanceof Long
        || value instanceof Short || value instanceof Byte) {
      out.append(value.toString());
    } else if (value instanceof Double number) {
      if (number.isNaN() || number.isInfinite()) watchText(out, number.toString());
      else out.append(number.toString());
    } else if (value instanceof Float number) {
      if (number.isNaN() || number.isInfinite()) watchText(out, number.toString());
      else out.append(number.toString());
    } else if (value instanceof String || value instanceof Character) {
      watchText(out, value.toString());
    } else if (value instanceof Enum<?> constant) {
      watchText(out, constant.name());
    } else if (value.getClass().getName().equals("clojure.lang.Keyword")) {
      // A Clojure keyword by its name (":leader"): its toString is the Clojure runtime's, no
      // program code (known by its class's name: the SDK depends on no Clojure).
      watchText(out, value.toString());
    } else {
      watchIdentity(out, value);
    }
  }

  private static void watchIdentity(StringBuilder out, Object value) {
    out.append('"').append(value.getClass().getName()).append('@')
        .append(Integer.toHexString(System.identityHashCode(value))).append('"');
  }

  /** A JSON string, cut at 200 characters. */
  private static void watchText(StringBuilder out, String text) {
    out.append('"');
    int end = Math.min(text.length(), 200);
    for (int index = 0; index < end; index++) {
      char c = text.charAt(index);
      if (c == '"' || c == '\\') out.append('\\').append(c);
      else if (c < 0x20) out.append("\\u00").append(Character.forDigit(c >> 4, 16)).append(Character.forDigit(c & 15, 16));
      else out.append(c);
    }
    out.append('"');
  }

  static boolean matches(String name, String[] prefixes) {
    for (String prefix : prefixes) {
      if (name.startsWith(prefix)) return true;
    }
    return false;
  }

  /** The JDK's own classes, left alone when the agent is given no prefixes. */
  static boolean jdk(String name) {
    return name.startsWith("java/") || name.startsWith("javax/") || name.startsWith("jdk/")
        || name.startsWith("sun/") || name.startsWith("com/sun/");
  }

  /** A coverage set's entries, in class files' form ("org/apache/x", "-org/apache/x/y"). */
  static String[] setEntries(String text) {
    if (text == null || text.isEmpty()) return new String[0];
    return text.replace('.', '/').split(",");
  }

  /** Whether the set holds the class: under an included prefix (or none is given), no excluded. */
  static boolean setContains(String[] set, String name) {
    boolean included = true;
    for (String entry : set) {
      if (entry.startsWith("-")) {
        if (entry.length() > 1 && name.startsWith(entry.substring(1))) return false;
      } else if (!entry.isEmpty()) {
        included = false;
      }
    }
    if (included) return true;
    for (String entry : set) {
      if (!entry.isEmpty() && !entry.startsWith("-") && name.startsWith(entry)) return true;
    }
    return false;
  }

  static synchronized int registerField(String field) {
    Integer id = fieldIds.get(field);
    if (id != null) return id;
    fieldIds.put(field, fields.size());
    fields.add(field);
    fieldNames = named(fieldNames, fields.size() - 1, field);
    return fields.size() - 1;
  }

  /** `names` with `name` at `id` (grown when it must), for its volatile field: the store that
   * shows the probes the name. Under this class's monitor, or as it loads. */
  private static String[] named(String[] names, int id, String name) {
    String[] known = id < names.length
        ? names : Arrays.copyOf(names, Math.max(id + 1, 2 * names.length));
    known[id] = name;
    return known;
  }

  /** Block probes' ids: their own numbers, with this bit (lines' ids are below it). */
  static final int BLOCKS = 1 << 30;
  static int blocks;

  static synchronized int nextBlock() {
    return blocks++;
  }

  static synchronized int register(String line) {
    Integer id = ids.get(line);
    if (id != null) return id;
    ids.put(line, lines.size());
    lines.add(line);
    lineNames = named(lineNames, lines.size() - 1, line);
    return lines.size() - 1;
  }

  /** `instrument <prefixes> <in.jar> <out.jar>...`: ahead-of-time instrumentation, by the
   * instrumenter (a JDK of 24 or later). */
  public static void main(String[] arguments) throws Exception {
    try {
      Class.forName("DeterminismoCoverageInstrument").getMethod("main", String[].class)
          .invoke(null, (Object) arguments);
    } catch (java.lang.reflect.InvocationTargetException failed) {
      if (failed.getCause() instanceof Exception cause) throw cause;
      throw failed;
    } catch (UnsupportedClassVersionError old) {
      System.err.println("determinismo-coverage: instrumenting needs a JDK of 24 or later "
          + "(java.lang.classfile); this is Java " + System.getProperty("java.specification.version"));
      System.exit(2);
    }
  }

  /** An ahead-of-time instrumentation's table, when the classpath has one: its ids again. */
  private static void tableLoad() {
    ClassLoader loader = DeterminismoCoverage.class.getClassLoader();
    java.io.InputStream in = loader == null ? null : loader.getResourceAsStream(TABLE);
    if (in == null) return;
    try (java.io.BufferedReader reader = new java.io.BufferedReader(
        new java.io.InputStreamReader(in, java.nio.charset.StandardCharsets.UTF_8))) {
      String section = "";
      for (String line; (line = reader.readLine()) != null; ) {
        if (line.startsWith("@blocks ")) {
          blocks = Integer.parseInt(line.substring("@blocks ".length()).trim());
        } else if (line.startsWith("@")) {
          section = line;
        } else if (section.equals("@lines")) {
          ids.put(line, lines.size());
          lines.add(line);
          lineNames = named(lineNames, lines.size() - 1, line);
        } else if (section.equals("@fields")) {
          fieldIds.put(line, fields.size());
          fields.add(line);
          fieldNames = named(fieldNames, fields.size() - 1, line);
        } else if (section.equals("@classes")) {
          ahead.add(line);
        }
      }
    } catch (java.io.IOException | RuntimeException unreadable) {
      // No names for the probes: their reports name nothing, the program runs on.
    }
  }

  static {
    tableLoad(); // Last: every table above is initialized by now.
  }
}
