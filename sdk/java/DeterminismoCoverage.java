// SPDX-License-Identifier: MIT
/*
 * Code coverage for strategies on the JVM (JDK 24+, through the java.lang.classfile API): a Java
 * agent that makes each source line of the classes it is told about emit a "coverage" event the
 * first time it runs ({"name":"line <class>:<line>"}), as the C, Zig and Python SDKs do.
 * Strategies such as det-strategy-mutate keep the timelines that reach new code.
 *
 *   java -javaagent:determinismo-coverage.jar[=<class name prefixes, comma-separated>] ...
 *
 * What it instruments: the classes under the agent's prefixes (every class but the JDK's when
 * none is given) that the node's coverage set holds, DETERMINISMO_COVERAGE (the Zig SDK's
 * schema.Coverage: class name prefixes, those starting with "-" excluded): the set, from a test
 * program's profile, scopes it at no change to the image.
 *
 * The jar holds this class and Determinismo, with "Premain-Class: DeterminismoCoverage" in its
 * manifest. Classes defined at run time (Clojure's, for instance) are instrumented too.
 *
 * Or ahead of time, at an image's build, with no agent at run time:
 *
 *   java -cp determinismo-coverage.jar:<the program's classpath> DeterminismoCoverage \
 *       instrument <prefixes> <in.jar> <out.jar> [<in.jar> <out.jar>]...
 *
 * rewrites the classes under the prefixes of each jar with the same probes, the table of their
 * ids (lines, fields, blocks, the classes) a resource of the first jar written; the coverage
 * jar on the classpath then reads it as this class loads. Classes are then loaded as they are,
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
 */
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.MethodModel;
import java.lang.classfile.MethodTransform;
import java.lang.classfile.Opcode;
import java.lang.classfile.instruction.BranchInstruction;
import java.lang.classfile.Instruction;
import java.lang.classfile.Label;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.LabelTarget;
import java.lang.classfile.instruction.LineNumber;
import java.lang.classfile.instruction.LocalVariable;
import java.lang.classfile.instruction.LocalVariableType;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.reflect.AccessFlag;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public final class DeterminismoCoverage {
  private static final ClassDesc SELF = ClassDesc.of("DeterminismoCoverage");
  private static final MethodTypeDesc PROBE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_int);
  private static final List<String> lines = new ArrayList<>();
  private static final Map<String, Integer> ids = new HashMap<>();
  private static volatile boolean[] reported = new boolean[1024];
  private static final MethodTypeDesc STATE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_int);
  private static final List<String> fields = new ArrayList<>();
  private static final Map<String, Integer> fieldIds = new HashMap<>();
  /** Transitions reported: field id, old ordinal + 1 (0 for null), new ordinal + 1. */
  private static final Set<Long> transitions = ConcurrentHashMap.newKeySet();
  /** The table of an ahead-of-time instrumentation: a resource of its first jar. */
  private static final String TABLE = "determinismo-coverage.table";
  /** Classes instrumented ahead of time (internal names): the agent leaves them alone. */
  private static final Set<String> ahead = ConcurrentHashMap.newKeySet();

  private DeterminismoCoverage() {}

  /**
   * The classes covered (internal-name prefixes; none: every class but the JDK's). Narrowed by a
   * later agent given prefixes: the platform's (every node's JAVA_TOOL_OPTIONS, loaded first)
   * covers everything until a program's own -javaagent=prefixes says what it wants.
   */
  private static volatile String[] coveredPrefixes = new String[0];
  private static boolean installed;

  public static synchronized void premain(String arguments, Instrumentation instrumentation) {
    String[] prefixes = arguments == null || arguments.isEmpty()
        ? new String[0] : arguments.replace('.', '/').split(",");
    if (prefixes.length > 0 || !installed) coveredPrefixes = prefixes;
    if (installed) return; // One transformer a JVM: the platform's agent and a program's own.
    installed = true;
    String[] set = setEntries(System.getenv("DETERMINISMO_COVERAGE"));
    instrumentation.addTransformer(new ClassFileTransformer() {
      @Override
      public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
          ProtectionDomain domain, byte[] bytes) {
        String[] covered = coveredPrefixes;
        if (name == null || name.startsWith("Determinismo") || ahead.contains(name)
            || !(covered.length == 0 ? !jdk(name) : matches(name, covered))
            || !setContains(set, name)) {
          return null;
        }
        try {
          return instrument(name.replace('/', '.'), bytes, loader);
        } catch (Throwable unsupported) {
          return null; // Left as it is: coverage is best effort, the program must still run.
        }
      }
    });
  }

  /** Called by instrumented code at the start of each line. */
  public static void line(int id) {
    boolean[] seen = reported;
    if ((id >= seen.length || !seen[id]) && queued.add(id)) send(id);
    if (crashAfterThread != null) crashAfterReached();
    pausing(id);
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
   * for it too. Its reports, and the stretches' draws, go to a sender thread of the agent's
   * through a lock-free queue; the sender calls the SDK (whose emit is synchronized). Probes
   * calling the SDK deadlocked JVMs twice (core.async, hunt runs 1115 and 1122): an instrumented
   * initializer's first probe waited for the agent's monitor, then for the SDK's, each held by a
   * virtual thread that needed the only carrier, pinned waiting for that initialization
   * (sdk/java/coverage_test.zig).
   */

  /** Lines whose first report is queued (the sender marks them reported). */
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
        if (id >= reported.length) reported = Arrays.copyOf(reported, Math.max(id + 1, 2 * id));
        boolean[] seen = reported;
        seen[id] = true;
        reported = seen; // Publishes the write to the probes (a volatile store).
        line = id < lines.size() ? lines.get(id) : "?" + id;
      }
      Determinismo.event("coverage", "{\"name\":\"line " + line + "\"}");
    } else if (report instanceof Object[] state) {
      String name;
      synchronized (DeterminismoCoverage.class) {
        int id = (Integer) state[0];
        name = id < fields.size() ? fields.get(id) : "?" + id;
      }
      Determinismo.event("state", "{\"name\":\"state " + name + ": " + state[1] + " -> "
          + state[2] + "\"}");
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
    send(new Object[] {id, before == null ? "null" : before.name(), next.name()});
  }

  private static boolean matches(String name, String[] prefixes) {
    for (String prefix : prefixes) {
      if (name.startsWith(prefix)) return true;
    }
    return false;
  }

  /** The JDK's own classes, left alone when the agent is given no prefixes. */
  private static boolean jdk(String name) {
    return name.startsWith("java/") || name.startsWith("javax/") || name.startsWith("jdk/")
        || name.startsWith("sun/") || name.startsWith("com/sun/");
  }

  /** A coverage set's entries, in class files' form ("org/apache/x", "-org/apache/x/y"). */
  private static String[] setEntries(String text) {
    if (text == null || text.isEmpty()) return new String[0];
    return text.replace('.', '/').split(",");
  }

  /** Whether the set holds the class: under an included prefix (or none is given), no excluded. */
  private static boolean setContains(String[] set, String name) {
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

  private static byte[] instrument(String className, byte[] bytes, ClassLoader loader) {
    ClassModel model = ClassFile.of().parse(bytes);
    // The stack maps of the probed code need the classes' hierarchy: from their class files, the
    // class being defined from its own bytes, never by loading a class. The JDK's default
    // resolver falls back to loading, and a class it loads while it is itself being defined is
    // defined twice: the JVM refuses the second ("duplicate class definition": ZooKeeper's
    // LearnerHandler died at each follower's connection, ObserverMaster, and no ensemble formed;
    // srv4, 2026-10-31).
    ClassDesc self = model.thisClass().asSymbol();
    ClassHierarchyResolver own = described -> {
      if (!described.equals(self)) return null;
      if (model.flags().has(AccessFlag.INTERFACE)) return ClassHierarchyResolver.ClassHierarchyInfo.ofInterface();
      return ClassHierarchyResolver.ClassHierarchyInfo.ofClass(
          model.superclass().map(entry -> entry.asSymbol()).orElse(null));
    };
    ClassLoader source = loader != null ? loader : ClassLoader.getSystemClassLoader();
    ClassHierarchyResolver resolver = own.orElse(ClassHierarchyResolver.ofResourceParsing(source)).cached();
    ClassFile files = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver));
    return files.transformClass(model, (classes, element) -> {
      if (!(element instanceof MethodModel method)) {
        classes.with(element);
        return;
      }
      // Initializers' stores set first states (an enum's its constants), and a constructor's
      // fields may not be readable yet (before super()): only their lines.
      boolean initializer = method.methodName().equalsString("<init>")
          || method.methodName().equalsString("<clinit>");
      classes.transformMethod(method, MethodTransform.transformingCode(probes(className, !initializer)));
    });
  }

  private static CodeTransform probes(String className, boolean states) {
    // Per method: forward conditional branches' targets awaiting their label (how many branches
    // reach it), labels passed, and whether the last instruction never falls through (a label
    // after it is reached by jumps alone).
    Map<Label, int[]> targets = new HashMap<>();
    Set<Label> passed = new java.util.HashSet<>();
    boolean[] noFallThrough = {false};
    // Whether that instruction was a goto back to a label passed: a loop's, and the label after
    // it the loop's exit.
    boolean[] backward = {false};
    return (code, element) -> {
      if (element instanceof LabelTarget target) {
        code.with(element);
        passed.add(target.label());
        int[] reaching = targets.remove(target.label());
        // The branch's taken side, when only it reaches the label (no fall-through into it, no
        // other branch to it): a point for thread pausing of its own.
        if (reaching != null && reaching[0] == 1 && noFallThrough[0] && !backward[0]) {
          code.loadConstant(BLOCKS | nextBlock());
          code.invokestatic(SELF, "block", PROBE);
        }
        noFallThrough[0] = false;
        backward[0] = false;
        return;
      }
      if (element instanceof Instruction instruction) {
        noFallThrough[0] = switch (instruction.opcode()) {
          case GOTO, GOTO_W, ATHROW, RETURN, IRETURN, LRETURN, FRETURN, DRETURN, ARETURN,
              TABLESWITCH, LOOKUPSWITCH -> true;
          default -> false;
        };
        backward[0] = element instanceof BranchInstruction jump
            && (jump.opcode() == Opcode.GOTO || jump.opcode() == Opcode.GOTO_W)
            && passed.contains(jump.target());
      }
      // Local variable tables are debugging information only, and dropped: the API sizes the
      // locals from the code, so a variable only the table names (one Clojure never loads or
      // stores) would point past them, and the JVM refuses the class (ClassFormatError).
      if (element instanceof LocalVariable || element instanceof LocalVariableType) return;
      if (states && element instanceof FieldInstruction field && metaInfo(field)) {
        code.loadConstant(registerField(field.owner().asInternalName().replace('/', '.') + "."
            + field.name().stringValue()));
        code.invokestatic(SELF, "crashStore", PROBE);
      }
      if (states && element instanceof FieldInstruction field && mayHoldState(field)) {
        // The value about to be stored and the field's value now, both left as they were.
        int id = registerField(field.owner().asInternalName().replace('/', '.') + "."
            + field.name().stringValue());
        if (field.opcode() == Opcode.PUTFIELD) {
          code.dup2(); // object, value, object, value
          code.swap(); // object, value, value, object
          code.getfield(field.field()); // object, value, value, old
        } else {
          code.dup(); // value, value
          code.getstatic(field.field()); // value, value, old
        }
        code.loadConstant(id);
        code.invokestatic(SELF, "state", STATE);
      }
      code.with(element);
      if (element instanceof LineNumber number) {
        code.loadConstant(register(className + ":" + number.line()));
        code.invokestatic(SELF, "line", PROBE);
      } else if (element instanceof BranchInstruction branch && branch.opcode() != Opcode.GOTO
          && branch.opcode() != Opcode.GOTO_W) {
        Label to = branch.target();
        int[] known = targets.get(to);
        if (passed.contains(to)) {
          code.loadConstant(BLOCKS | nextBlock()); // A loop's branch back: no pair.
          code.invokestatic(SELF, "block", PROBE);
        } else {
          if (known != null) known[0]++; // A second branch to the label: its taken side has none.
          else targets.put(to, new int[] {1});
          code.loadConstant(BLOCKS | nextBlock()); // The fall-through side.
          code.invokestatic(SELF, "block", PROBE);
        }
      }
    };
  }

  /**
   * A store to a field whose name says it holds the node's view of the cluster (CrashTuner's
   * meta-info: a leader, an epoch or term, a session, a member, an owner...), whatever its type
   * (an epoch is a long): a crash point too. Enum-typed ones are the states' already.
   */
  private static boolean metaInfo(FieldInstruction field) {
    if (field.opcode() != Opcode.PUTFIELD && field.opcode() != Opcode.PUTSTATIC) return false;
    return metaInfoName(field.name().stringValue());
  }

  /** Whether one of a name's words (camelCase or snake_case; a plural too) is a meta-info word:
   * `currentTerm`, `leader_id`, `members`, but not `terminated`, `released`, `remembered`. */
  static boolean metaInfoName(String name) {
    int start = 0;
    for (int index = 1; index <= name.length(); index++) {
      boolean end = index == name.length() || name.charAt(index) == '_' || name.charAt(index) == '$'
          || (Character.isUpperCase(name.charAt(index)) && Character.isLowerCase(name.charAt(index - 1)));
      if (!end) continue;
      String word = name.substring(start, index).toLowerCase(java.util.Locale.ROOT);
      for (String meta : META_INFO_WORDS) {
        if (word.equals(meta) || word.equals(meta + "s")) return true;
      }
      start = index < name.length() && (name.charAt(index) == '_' || name.charAt(index) == '$') ? index + 1 : index;
    }
    return false;
  }

  private static final String[] META_INFO_WORDS = {"leader", "epoch", "term", "session", "member",
      "owner", "coordinator", "master", "primary", "quorum", "lease", "zxid", "generation", "peer"};

  /** A store to a field typed by a class of the program's own: an enum constant, maybe. */
  private static boolean mayHoldState(FieldInstruction field) {
    if (field.opcode() != Opcode.PUTFIELD && field.opcode() != Opcode.PUTSTATIC) return false;
    String type = field.typeSymbol().descriptorString();
    if (!type.startsWith("L")) return false; // Primitives and arrays.
    for (String library : new String[] {"Ljava/", "Ljavax/", "Ljdk/", "Lsun/", "Lscala/", "Lkotlin/", "Lclojure/"}) {
      if (type.startsWith(library)) return false;
    }
    return true;
  }

  private static synchronized int registerField(String field) {
    Integer id = fieldIds.get(field);
    if (id != null) return id;
    fieldIds.put(field, fields.size());
    fields.add(field);
    return fields.size() - 1;
  }

  /** Block probes' ids: their own numbers, with this bit (lines' ids are below it). */
  private static final int BLOCKS = 1 << 30;
  private static int blocks;

  private static synchronized int nextBlock() {
    return blocks++;
  }

  private static synchronized int register(String line) {
    Integer id = ids.get(line);
    if (id != null) return id;
    ids.put(line, lines.size());
    lines.add(line);
    return lines.size() - 1;
  }

  /** `instrument <prefixes> <in.jar> <out.jar>...`: ahead-of-time instrumentation. */
  public static void main(String[] arguments) throws Exception {
    if (arguments.length < 4 || !arguments[0].equals("instrument") || arguments.length % 2 != 0) {
      System.err.println("usage: DeterminismoCoverage instrument <class name prefixes, "
          + "comma-separated> <in.jar> <out.jar> [<in.jar> <out.jar>]...");
      System.exit(2);
    }
    String[] prefixes = arguments[1].replace('.', '/').split(",");
    java.net.URL[] urls = new java.net.URL[(arguments.length - 2) / 2];
    for (int i = 2; i < arguments.length; i += 2) {
      urls[(i - 2) / 2] = java.nio.file.Path.of(arguments[i]).toUri().toURL();
    }
    // The hierarchy for stack maps from class files, never loaded: the jars', and the
    // classpath's this runs with (their dependencies': run it with the program's classpath).
    try (java.net.URLClassLoader loader =
        new java.net.URLClassLoader(urls, ClassLoader.getSystemClassLoader())) {
      // The first jar last: the table, every jar's ids, goes at its end.
      for (int i = arguments.length - 2; i >= 2; i -= 2) {
        instrumentJar(prefixes, arguments[i], arguments[i + 1], loader, i == 2);
      }
    }
    System.out.println("determinismo-coverage: " + ahead.size() + " classes, " + lines.size()
        + " lines, " + blocks + " blocks, " + fields.size() + " fields");
  }

  private static void instrumentJar(String[] prefixes, String input, String output,
      ClassLoader loader, boolean table) throws java.io.IOException {
    try (java.util.jar.JarFile jar = new java.util.jar.JarFile(input);
        java.util.jar.JarOutputStream out = new java.util.jar.JarOutputStream(
            java.nio.file.Files.newOutputStream(java.nio.file.Path.of(output)))) {
      for (java.util.Enumeration<java.util.jar.JarEntry> entries = jar.entries();
          entries.hasMoreElements(); ) {
        java.util.jar.JarEntry entry = entries.nextElement();
        String name = entry.getName();
        // A signature no longer holds for rewritten classes; an old table is replaced.
        if (name.equals(TABLE) || name.startsWith("META-INF/") && (name.endsWith(".SF")
            || name.endsWith(".RSA") || name.endsWith(".DSA") || name.endsWith(".EC"))) {
          continue;
        }
        byte[] bytes;
        try (java.io.InputStream in = jar.getInputStream(entry)) {
          bytes = in.readAllBytes();
        }
        if (!entry.isDirectory() && name.endsWith(".class") && !name.endsWith("module-info.class")) {
          String internal = name.substring(0, name.length() - ".class".length());
          if (!internal.startsWith("Determinismo") && matches(internal, prefixes)) {
            try {
              bytes = instrument(internal.replace('/', '.'), bytes, loader);
              ahead.add(internal);
            } catch (Throwable unsupported) {
              // Left as it is: coverage is best effort, the program must still run.
            }
          }
        }
        java.util.jar.JarEntry copy = new java.util.jar.JarEntry(name);
        copy.setTime(entry.getTime()); // Clojure loads a class newer than its source.
        out.putNextEntry(copy);
        out.write(bytes);
        out.closeEntry();
      }
      if (table) {
        StringBuilder text = new StringBuilder("@lines\n");
        for (String line : lines) text.append(line).append('\n');
        text.append("@fields\n");
        for (String field : fields) text.append(field).append('\n');
        text.append("@classes\n");
        for (String internal : ahead) text.append(internal).append('\n');
        text.append("@blocks ").append(blocks).append('\n');
        out.putNextEntry(new java.util.jar.JarEntry(TABLE));
        out.write(text.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        out.closeEntry();
      }
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
        } else if (section.equals("@fields")) {
          fieldIds.put(line, fields.size());
          fields.add(line);
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
