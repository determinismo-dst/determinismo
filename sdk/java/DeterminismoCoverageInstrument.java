// SPDX-License-Identifier: MIT
/*
 * The JVM coverage agent's instrumenter (DeterminismoCoverage's header says what its probes do):
 * it rewrites classes through JDK 24's java.lang.classfile API, as they load (premain, on a JVM of
 * 24 or later) or ahead of time (main: jars rewritten at an image's build, for a program then run
 * on any JVM from 17 on). Its probes call DeterminismoCoverage, the runtime, compiled for Java 17.
 */
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;
import java.lang.classfile.ClassModel;
import java.lang.classfile.CodeBuilder;
import java.lang.classfile.CodeElement;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.TypeKind;
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
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

public final class DeterminismoCoverageInstrument {
  /** The runtime the probes call, by the name instrumented classes already hold. */
  private static final ClassDesc SELF = ClassDesc.of("DeterminismoCoverage");
  private static final MethodTypeDesc PROBE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_int);
  private static final MethodTypeDesc STATE = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_int);

  private static final MethodTypeDesc WATCH_CALL = MethodTypeDesc.of(ConstantDescs.CD_void,
      ConstantDescs.CD_Object, ConstantDescs.CD_Object.arrayType(), ConstantDescs.CD_int);

  /** The node's watches (DETERMINISMO_WATCH, DeterminismoCoverage's header): fields as
   * `<class>.<field>`, methods as `<class>.<method>` (written with "()"), and their classes'
   * internal names, instrumented whatever the coverage set says. */
  static final Set<String> watchedFields = new java.util.HashSet<>();
  static final Set<String> watchedMethods = new java.util.HashSet<>();
  static final Set<String> watchedClasses = new java.util.HashSet<>();

  static {
    String text = System.getenv("DETERMINISMO_WATCH");
    if (text != null) {
      for (String entry : text.split(",")) {
        String named = entry.trim();
        boolean method = named.endsWith("()");
        if (method) named = named.substring(0, named.length() - 2);
        int dot = named.lastIndexOf('.');
        if (dot <= 0 || dot == named.length() - 1) continue;
        (method ? watchedMethods : watchedFields).add(named);
        watchedClasses.add(named.substring(0, dot).replace('.', '/'));
      }
    }
  }

  private DeterminismoCoverageInstrument() {}

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
    // The runtime first (its sender, its exit hook, an ahead-of-time table), before any class is
    // transformed, as when this was its premain.
    DeterminismoCoverage.start();
    String[] set = DeterminismoCoverage.setEntries(System.getenv("DETERMINISMO_COVERAGE"));
    instrumentation.addTransformer(new ClassFileTransformer() {
      @Override
      public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
          ProtectionDomain domain, byte[] bytes) {
        String[] covered = coveredPrefixes;
        if (name == null || name.startsWith("Determinismo")
            || DeterminismoCoverage.ahead.contains(name)
            || !watchedClasses.contains(name)
            && (!(covered.length == 0 ? !DeterminismoCoverage.jdk(name)
                : DeterminismoCoverage.matches(name, covered))
            || !DeterminismoCoverage.setContains(set, name))) {
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
      // fields may not be readable yet (before super()): only their DeterminismoCoverage.lines.
      boolean initializer = method.methodName().equalsString("<init>")
          || method.methodName().equalsString("<clinit>");
      CodeTransform code = probes(className, !initializer);
      String called = className + "." + method.methodName().stringValue();
      if (watchedMethods.contains(called)) {
        code = withCallProbe(code, method, DeterminismoCoverage.registerField(called), initializer);
      }
      classes.transformMethod(method, MethodTransform.transformingCode(code));
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
          code.loadConstant(blockId());
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
        code.loadConstant(fieldId(field));
        code.invokestatic(SELF, "crashStore", PROBE);
      }
      if (states && element instanceof FieldInstruction field && mayHoldState(field)) {
        // The value about to be stored and the field's value now, both left as they were.
        int id = fieldId(field);
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
      if (element instanceof FieldInstruction field && watched(field)) watchProbe(code, field, !states);
      code.with(element);
      if (element instanceof LineNumber number) {
        code.loadConstant(DeterminismoCoverage.register(className + ":" + number.line()));
        code.invokestatic(SELF, "line", PROBE);
      } else if (element instanceof BranchInstruction branch && branch.opcode() != Opcode.GOTO
          && branch.opcode() != Opcode.GOTO_W) {
        Label to = branch.target();
        int[] known = targets.get(to);
        if (passed.contains(to)) {
          code.loadConstant(blockId()); // A loop's branch back: no pair.
          code.invokestatic(SELF, "block", PROBE);
        } else {
          if (known != null) known[0]++; // A second branch to the label: its taken side has none.
          else targets.put(to, new int[] {1});
          code.loadConstant(blockId()); // The fall-through side.
          code.invokestatic(SELF, "block", PROBE);
        }
      }
    };
  }

  /** A store to a field the node watches. */
  private static boolean watched(FieldInstruction field) {
    if (field.opcode() != Opcode.PUTFIELD && field.opcode() != Opcode.PUTSTATIC) return false;
    return watchedFields.contains(field.owner().asInternalName().replace('/', '.') + "."
        + field.name().stringValue());
  }

  /**
   * Before a watched store: the value set aside in a local of its own, DeterminismoCoverage.watchStore
   * told it (boxed) with the object (null for a static field, and in an initializer, where the
   * object may not be initialized yet), then the stack as it was.
   */
  private static void watchProbe(CodeBuilder code, FieldInstruction field, boolean initializer) {
    TypeKind kind = TypeKind.from(field.typeSymbol());
    int slot = code.allocateLocal(kind);
    code.storeLocal(kind, slot);
    if (field.opcode() == Opcode.PUTFIELD && !initializer) code.dup();
    else code.aconst_null();
    code.loadLocal(kind, slot);
    box(code, kind);
    code.loadConstant(fieldId(field));
    code.invokestatic(SELF, "watchStore", STATE);
    code.loadLocal(kind, slot);
  }

  /** The method's code with DeterminismoCoverage.watchCall told its arguments at its start. */
  private static CodeTransform withCallProbe(CodeTransform base, MethodModel method, int id,
      boolean initializer) {
    boolean statical = method.flags().has(AccessFlag.STATIC);
    return new CodeTransform() {
      @Override
      public void atStart(CodeBuilder code) {
        java.util.List<ClassDesc> parameters = method.methodTypeSymbol().parameterList();
        if (statical || initializer) code.aconst_null();
        else code.aload(0);
        code.loadConstant(parameters.size());
        code.anewarray(ConstantDescs.CD_Object);
        int slot = statical ? 0 : 1;
        for (int index = 0; index < parameters.size(); index++) {
          TypeKind kind = TypeKind.from(parameters.get(index));
          code.dup();
          code.loadConstant(index);
          code.loadLocal(kind, slot);
          box(code, kind);
          code.aastore();
          slot += kind.slotSize();
        }
        code.loadConstant(id);
        code.invokestatic(SELF, "watchCall", WATCH_CALL);
        base.atStart(code);
      }

      @Override
      public void accept(CodeBuilder code, CodeElement element) {
        base.accept(code, element);
      }

      @Override
      public void atEnd(CodeBuilder code) {
        base.atEnd(code);
      }
    };
  }

  /** A primitive on the stack as its box (valueOf); a reference left as it is. */
  private static void box(CodeBuilder code, TypeKind kind) {
    ClassDesc boxed;
    ClassDesc primitive;
    switch (kind) {
      case INT -> { boxed = ConstantDescs.CD_Integer; primitive = ConstantDescs.CD_int; }
      case LONG -> { boxed = ConstantDescs.CD_Long; primitive = ConstantDescs.CD_long; }
      case FLOAT -> { boxed = ConstantDescs.CD_Float; primitive = ConstantDescs.CD_float; }
      case DOUBLE -> { boxed = ConstantDescs.CD_Double; primitive = ConstantDescs.CD_double; }
      case BOOLEAN -> { boxed = ConstantDescs.CD_Boolean; primitive = ConstantDescs.CD_boolean; }
      case BYTE -> { boxed = ConstantDescs.CD_Byte; primitive = ConstantDescs.CD_byte; }
      case SHORT -> { boxed = ConstantDescs.CD_Short; primitive = ConstantDescs.CD_short; }
      case CHAR -> { boxed = ConstantDescs.CD_Character; primitive = ConstantDescs.CD_char; }
      default -> { return; }
    }
    code.invokestatic(boxed, "valueOf", MethodTypeDesc.of(boxed, primitive));
  }

  /** A block probe's id: its own number, with the runtime's block bit. */
  private static int blockId() {
    return DeterminismoCoverage.BLOCKS | DeterminismoCoverage.nextBlock();
  }

  /** A field's id in the runtime's table: `<class>.<field>`. */
  private static int fieldId(FieldInstruction field) {
    return DeterminismoCoverage.registerField(field.owner().asInternalName().replace('/', '.')
        + "." + field.name().stringValue());
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
    System.out.println("determinismo-coverage: " + DeterminismoCoverage.ahead.size()
        + " classes, " + DeterminismoCoverage.lines.size() + " lines, "
        + DeterminismoCoverage.blocks + " blocks, " + DeterminismoCoverage.fields.size()
        + " fields");
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
        if (name.equals(DeterminismoCoverage.TABLE) || name.startsWith("META-INF/")
            && (name.endsWith(".SF")
            || name.endsWith(".RSA") || name.endsWith(".DSA") || name.endsWith(".EC"))) {
          continue;
        }
        byte[] bytes;
        try (java.io.InputStream in = jar.getInputStream(entry)) {
          bytes = in.readAllBytes();
        }
        if (!entry.isDirectory() && name.endsWith(".class") && !name.endsWith("module-info.class")) {
          String internal = name.substring(0, name.length() - ".class".length());
          if (!internal.startsWith("Determinismo")
              && (DeterminismoCoverage.matches(internal, prefixes) || watchedClasses.contains(internal))) {
            try {
              bytes = instrument(internal.replace('/', '.'), bytes, loader);
              DeterminismoCoverage.ahead.add(internal);
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
        for (String line : DeterminismoCoverage.lines) text.append(line).append('\n');
        text.append("@fields\n");
        for (String field : DeterminismoCoverage.fields) text.append(field).append('\n');
        text.append("@classes\n");
        for (String internal : DeterminismoCoverage.ahead) text.append(internal).append('\n');
        text.append("@blocks ").append(DeterminismoCoverage.blocks).append('\n');
        out.putNextEntry(new java.util.jar.JarEntry(DeterminismoCoverage.TABLE));
        out.write(text.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        out.closeEntry();
      }
    }
  }
}
