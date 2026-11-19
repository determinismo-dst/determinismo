// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    // The VMM and the guest tools only ever run on x86-64 Linux: cross-compile by default.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // TCP with timeouts (sdk.tcp), its own module so that protocol clients use it too.
    const tcp = b.addModule("tcp", .{
        .root_source_file = b.path("sdk/zig/tcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The guest-host protocol's shared part (sdk/zig/protocol.zig): the SDK's and the core's,
    // its own module so that the core imports it alone (a run's pin moves with it, not with the
    // SDK's other files).
    const protocol = b.addModule("protocol", .{
        .root_source_file = b.path("sdk/zig/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The SDK for tests written in Zig; it also holds the system schema the VMM reads.
    const sdk = b.addModule("determinismo", .{
        .root_source_file = b.path("sdk/zig/determinismo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "tcp", .module = tcp }, .{ .name = "protocol", .module = protocol } },
    });
    // The core (src/core/core.zig): what decides a timeline's execution given its inputs (the VMM,
    // the snapshot, the tape, the events recorded, the condition language). Its own module, so
    // that it reaches nothing of the explorer's (a stray import is a build error), and what a run
    // pins (PLAN: a run pins its core, not its whole explorer).
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protocol", .module = protocol }},
    });
    // The events database (src/duckdb.zig): DuckDB 2.0's static libraries for musl and the
    // libstdc++ they were built against, as infra/host/tools.sh installs them.
    const duckdb = b.option([]const u8, "duckdb", "DuckDB's libraries ($HOME/opt/duckdb)") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "opt", "duckdb" });
    // The commit determinismo is built from ("-dirty" with uncommitted changes), in each run's
    // request: runs compared per build (infra/host/finds.py).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "commit", b.option([]const u8, "commit", "The build's commit " ++
        "(default: the repository's, \"unknown\" without git)") orelse commit_of(b));
    // What a run pins (PLAN: a run pins its core, not its whole explorer): the core's files and the
    // protocol it shares with the SDK (sdk/zig/protocol.zig, its only import), by their content
    // (uncommitted changes and new files included), with the compiler, the optimize mode and the target. A resume, a replay
    // or a node maker runs a newer binary only where this is the run's.
    build_options.addOption([]const u8, "core_id", core_id_of(b, target, optimize));
    const build_options_module = build_options.createModule();
    // The SDK the explorer carries (tools/sdk_pack.zig): node images built from a Dockerfile take
    // it as the build context `determinismo-sdk` (src/prepare.zig), the SDK of the platform that
    // builds them, wherever their Dockerfile lives.
    const sdk_pack = b.addExecutable(.{
        .name = "det-sdk-pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sdk_pack.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const sdk_pack_run = b.addRunArtifact(sdk_pack);
    const sdk_tar = sdk_pack_run.addOutputFileArg("sdk.tar");
    sdk_pack_run.addDirectoryArg(b.path("sdk"));
    program_inputs(b, sdk_pack_run, "sdk", "");
    // libvoidstar as an object (lib/libvoidstar.o) for programs linked statically without libc
    // (a Zig program's own _start, as TigerBeetle's): its trace-pc-guard callbacks, system calls
    // only, needing memcpy, memset and getauxval of the program. A fixed target and mode and no
    // debug info, so its bytes are the same wherever the explorer is built: the tar's hash names
    // the build context, and podman caches a COPY by its content.
    const voidstar_object = b.addObject(.{
        .name = "libvoidstar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guest/runtime/voidstar.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none, .cpu_model = .baseline }),
            .optimize = .ReleaseSafe,
            .pic = true,
            .strip = true,
            .stack_check = false,
        }),
    });
    sdk_pack_run.addPrefixedFileArg("lib/libvoidstar.o=", voidstar_object.getEmittedBin());
    const sdk_tar_module = b.createModule(.{ .root_source_file = sdk_tar });
    // The guest's fault exclusions' regular expressions, checked by the explorer as it takes them.
    const regex_module = b.createModule(.{ .root_source_file = b.path("guest/runtime/regex.zig") });
    const exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "determinismo", .module = sdk },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "core", .module = core },
                .{ .name = "sdk_tar", .module = sdk_tar_module },
                .{ .name = "regex", .module = regex_module },
            },
        }),
    });
    duckdb_link(b, exe.root_module, duckdb);
    zstd_link(b, exe.root_module);
    wamr_link(b, exe.root_module);
    // Compiled, not linked: no DuckDB needed (its functions are declared in src/duckdb.zig), so
    // any machine checks the code in seconds (`zig build check`), a Mac included.
    const check_exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "determinismo", .module = sdk },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "core", .module = core },
                .{ .name = "sdk_tar", .module = sdk_tar_module },
                .{ .name = "regex", .module = regex_module },
            },
        }),
    });
    check_exe.root_module.link_libc = true;
    const check = b.step("check", "Compile determinismo without linking it (no DuckDB needed), the guest's programs and the e2e checks");
    check.dependOn(&check_exe.step);
    // Phases, each built alone (`zig build <phase>`): determinismo is one thing, the workloads
    // another. A change to the SDK rebuilt all ~50 examples for a check that runs five (40
    // minutes on two cores, srv4 2026-11-01). Each workload is its own step too
    // (`zig build etcd-test`: its test program and the binaries its nodes run). `zig build`: all.
    const phases: Phases = .{
        .determinismo = b.step("determinismo", "The host's tool, its initramfs builder and the strategy plugins"),
        .guest = b.step("guest", "The guest runtime (det-init, det-nodes, ...) and libvoidstar"),
        .selftest = b.step("selftest", "The self-tests' programs and fixtures"),
        .workloads = b.step("workloads", "Every example workload"),
    };

    phases.install(b, phases.determinismo, exe);

    // A small Redis client, shared by the examples and the plain workload.
    const resp = b.addModule("resp", .{
        .root_source_file = b.path("examples/bank/resp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tcp", .module = tcp }},
    });

    // A PostgreSQL client (also for CockroachDB and YugabyteDB), and list-append transactions
    // over SQL checked by Elle, shared by the SQL examples.
    const pg = b.addModule("pg", .{
        .root_source_file = b.path("examples/shop/pg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "determinismo", .module = sdk }},
    });
    // An nREPL client, shared by the nREPL and clojure-cli.repl examples.
    const nrepl = b.addModule("nrepl", .{
        .root_source_file = b.path("examples/nrepl/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "determinismo", .module = sdk }},
    });

    // Guest side: the in-guest runtime and example tests, static binaries that run in the VM.
    const guest_programs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "det-init", .path = "guest/runtime/init.zig" },
        .{ .name = "det-nodes", .path = "guest/runtime/nodes_main.zig" },
        .{ .name = "det-composer", .path = "guest/runtime/composer.zig" },
        .{ .name = "det-faults", .path = "guest/runtime/faults.zig" },
        .{ .name = "det-agent", .path = "guest/runtime/agent.zig" },
        .{ .name = "det-stop-faults", .path = "guest/runtime/stop_faults.zig" },
        .{ .name = "det-nrepl-relay", .path = "guest/runtime/nrepl_relay.zig" },
        .{ .name = "det-assert", .path = "guest/runtime/assert_main.zig" },
        .{ .name = "det-egress", .path = "guest/runtime/egress.zig" },
        .{ .name = "det-ingress", .path = "guest/runtime/ingress.zig" },
        .{ .name = "det-runner", .path = "guest/runtime/runner.zig" },
        .{ .name = "det-profile", .path = "guest/runtime/profile.zig" },
        .{ .name = "det-core", .path = "guest/runtime/cores.zig" },
        .{ .name = "det-podlogs", .path = "guest/runtime/podlogs.zig" },
        .{ .name = "det-kubespec", .path = "guest/runtime/kubespec.zig" },
        .{ .name = "det-sinks", .path = "guest/runtime/sinks.zig" },
        .{ .name = "bank-test", .path = "examples/bank/bank_test.zig" },
        .{ .name = "notes-test", .path = "examples/tutorial/1-notes/notes_test.zig" },
        .{ .name = "orders-test", .path = "examples/tutorial/2-orders/orders_test.zig" },
        .{ .name = "shop-test", .path = "examples/shop/shop_test.zig" },
        .{ .name = "clojure-bank-test", .path = "examples/clojure-bank/clojure_bank_test.zig" },
        .{ .name = "k3s-test", .path = "examples/k3s/k3s_test.zig" },
        .{ .name = "raft-test", .path = "examples/raft/raft_test.zig" },
        .{ .name = "race-test", .path = "examples/race/race_test.zig" },
        .{ .name = "nrepl-test", .path = "examples/nrepl/nrepl_test.zig" },
        .{ .name = "det-selftest", .path = "tests/selftest/selftest.zig" },
        .{ .name = "det-selftest-node", .path = "tests/selftest/node.zig" },
        .{ .name = "det-selftest-catalog", .path = "tests/selftest/catalog_test.zig" },
        .{ .name = "det-maze-sum", .path = "tests/selftest/maze_sum.zig" },
        .{ .name = "det-selftest-sum", .path = "tests/mutate/sum_test.zig" },
        .{ .name = "det-fake-explore", .path = "tests/selftest/fake_explore.zig" },
    };
    for (guest_programs) |program| {
        const guest_exe = b.addExecutable(.{
            .name = program.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(program.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "determinismo", .module = sdk },
                    .{ .name = "resp", .module = resp },
                    .{ .name = "nrepl", .module = nrepl },
                    .{ .name = "pg", .module = pg },
                },
            }),
        });
        check.dependOn(&guest_exe.step);
        if (std.mem.startsWith(u8, program.path, "examples/")) {
            phases.workload(b, program.name, guest_exe);
        } else {
            phases.install(b, if (std.mem.startsWith(u8, program.path, "tests/")) phases.selftest else phases.guest, guest_exe);
        }
        // The selftest node's next release, for the upgrade check: the same program under
        // another name (an image of its own: which root is mounted shows in which runs).
        if (std.mem.eql(u8, program.name, "det-selftest-node")) {
            const next = b.addInstallBinFile(guest_exe.getEmittedBin(), "det-selftest-node-next");
            phases.selftest.dependOn(&next.step);
            b.getInstallStep().dependOn(&next.step);
        }
    }

    // libvoidstar.so, Antithesis's native library for the system's processes (nodes with
    // antithesis_library have it at /usr/lib/libvoidstar.so): no libc, so any program can load
    // it. Beside the runtime.
    const voidstar = b.addLibrary(.{
        .name = "voidstar",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("guest/runtime/voidstar.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .strip = true, // It lands in every initramfs.
        }),
    });
    const voidstar_installed = b.addInstallArtifact(voidstar, .{ .dest_dir = .{ .override = .bin } });
    phases.guest.dependOn(&voidstar_installed.step);
    b.getInstallStep().dependOn(&voidstar_installed.step);

    // The JVM coverage agent: its runtime for Java 17 (sdk/java/DeterminismoCoverage.java, what
    // instrumented code calls), its instrumenter for JDK 24+ (DeterminismoCoverageInstrument.java:
    // java.lang.classfile), its entry point compiled for Java 8 (DeterminismoCoverageBoot: any JVM
    // loads it, and an old one says it instruments nothing as it loads): in every initramfs at /opt/determinismo/lib, on every
    // node's JAVA_TOOL_OPTIONS (guest/runtime/nodes.zig). Built with a JDK 25 (infra/host/tools.sh:
    // ~/opt/jdk-25), entries dated alike so the jar, part of every timeline, is reproducible.
    const jdk = b.option([]const u8, "jdk", "A JDK 25 for the JVM coverage agent ($HOME/opt/jdk-25)") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "opt", "jdk-25" });
    const coverage_jar = b.addSystemCommand(&.{
        "sh",           "-c",
        \\set -eu
        \\jdk=$1 out=$2 sdk=$3 boot=$4 agent=$5 instrument=$6
        \\work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; mkdir "$work/classes"
        \\"$jdk/bin/javac" --release 17 -d "$work/classes" "$sdk" "$agent"
        \\"$jdk/bin/javac" --release 24 -cp "$work/classes" -d "$work/classes" "$instrument"
        \\"$jdk/bin/javac" --release 8 -Xlint:-options -d "$work/classes" "$boot"
        \\printf 'Premain-Class: DeterminismoCoverageBoot\n' > "$work/manifest"
        \\"$jdk/bin/jar" --create --date=1980-01-01T00:00:02Z --file "$out" --manifest "$work/manifest" -C "$work/classes" .
        ,
        "coverage-jar", jdk,
    });
    const coverage_jar_file = coverage_jar.addOutputFileArg("determinismo-coverage.jar");
    coverage_jar.addFileArg(b.path("sdk/java/Determinismo.java"));
    coverage_jar.addFileArg(b.path("sdk/java/DeterminismoCoverageBoot.java"));
    coverage_jar.addFileArg(b.path("sdk/java/DeterminismoCoverage.java"));
    coverage_jar.addFileArg(b.path("sdk/java/DeterminismoCoverageInstrument.java"));
    const coverage_jar_installed = b.addInstallFileWithDir(coverage_jar_file, .bin, "determinismo-coverage.jar");
    phases.guest.dependOn(&coverage_jar_installed.step);
    b.getInstallStep().dependOn(&coverage_jar_installed.step);
    // Python's coverage for a command run covered (det-nodes exec --coverage): the SDK and the
    // sitecustomize that starts it, in every node's /opt/determinismo/lib/python (initramfs.zig).
    for ([_][2][]const u8{
        .{ "sdk/python/determinismo.py", "determinismo.py" },
        .{ "guest/runtime/python/sitecustomize.py", "determinismo-sitecustomize.py" },
    }) |file| {
        const installed = b.addInstallFileWithDir(b.path(file[0]), .bin, file[1]);
        phases.guest.dependOn(&installed.step);
        b.getInstallStep().dependOn(&installed.step);
    }

    // libdeterminismo.so, the Zig SDK behind a C ABI (sdk/zig/ffi.zig), for test programs in any
    // language: no libc, so a JVM loads it. In every initramfs at /opt/determinismo/lib, and on
    // the host for programs' --describe and checks. Beside it libdeterminismo.json, its interface
    // (sdk/zig/bindings.zig), which bindings are made from.
    const library = b.addLibrary(.{
        .name = "determinismo",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("sdk/zig/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .strip = true, // It lands in every initramfs.
            .sanitize_c = .off, // Its exports are its interface alone, not a C runtime's.
            .imports = &.{ .{ .name = "tcp", .module = tcp }, .{ .name = "protocol", .module = protocol } },
        }),
    });
    const library_installed = b.addInstallArtifact(library, .{ .dest_dir = .{ .override = .bin } });
    phases.guest.dependOn(&library_installed.step);
    b.getInstallStep().dependOn(&library_installed.step);
    const bindings_tool = b.addExecutable(.{
        .name = "det-bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sdk/zig/bindings.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // Test programs in Clojure and jank (sdk/clojure's and sdk/jank's determinismo.workload),
    // each one file: a shell script that runs itself as a jar of its sources
    // (tools/program_pack.zig).
    const program_pack_tool = b.addExecutable(.{
        .name = "det-program-pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/program_pack.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const Program = struct { name: []const u8, main: []const u8, sources: []const u8 };
    const clojure_programs = [_]Program{
        // The e2e repl check's (the examples' own: examples/build_workloads.zig).
        .{ .name = "repl-test", .main = "repl-test", .sources = "tests/repl" },
    };
    for ([_]struct { []const Program, []const u8, []const u8, []const u8 }{
        .{ &clojure_programs, "clojure", "sdk/clojure", ".clj" },
    }) |language| for (language[0]) |program| {
        const pack = b.addRunArtifact(program_pack_tool);
        const packed_program = pack.addOutputFileArg(program.name);
        pack.addArg(language[1]);
        pack.addArg(program.main);
        pack.addDirectoryArg(b.path(program.sources));
        pack.addDirectoryArg(b.path(language[2]));
        // Each source an input: a directory argument is its path to the cache, not its files (an
        // edited workload went out packed as it was).
        for ([_][]const u8{ program.sources, language[2] }) |directory| program_inputs(b, pack, directory, language[3]);
        const installed = b.addInstallFileWithDir(packed_program, .bin, program.name);
        if (std.mem.startsWith(u8, program.sources, "tests/")) {
            phases.selftest.dependOn(&installed.step);
        } else {
            const step = b.step(program.name, b.fmt("The {s} workload: its test program ({s})", .{ program.name, language[1] }));
            step.dependOn(&installed.step);
            phases.workloads.dependOn(step);
        }
        b.getInstallStep().dependOn(&installed.step);
    };

    const bindings_run = b.addRunArtifact(bindings_tool);
    const bindings_json = bindings_run.addOutputFileArg("libdeterminismo.json");
    const bindings_installed = b.addInstallFileWithDir(bindings_json, .bin, "libdeterminismo.json");
    phases.guest.dependOn(&bindings_installed.step);
    b.getInstallStep().dependOn(&bindings_installed.step);
    const header_run = b.addRunArtifact(bindings_tool);
    const header = header_run.addOutputFileArg("libdeterminismo.h");
    const header_installed = b.addInstallFileWithDir(header, .bin, "libdeterminismo.h");
    phases.guest.dependOn(&header_installed.step);
    b.getInstallStep().dependOn(&header_installed.step);

    // Reference strategy plugins (docs/PLUGINS.md). They run on the host, next to determinismo.
    for ([_][]const u8{ "random", "mutate" }) |plugin| {
        const plugin_exe = b.addExecutable(.{
            .name = b.fmt("det-strategy-{s}", .{plugin}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("plugins/{s}.zig", .{plugin})),
                .target = target,
                .optimize = optimize,
            }),
        });
        phases.install(b, phases.determinismo, plugin_exe);
    }

    // A plain workload with no SDK: tests can be any program, in any language.
    const redis_workload = b.addExecutable(.{
        .name = "det-workload-redis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("workload/redis.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "resp", .module = resp }},
        }),
    });
    phases.workload(b, "det-workload-redis", redis_workload);

    // A node written in C with the C SDK, for the self-tests.
    const c_node = b.addExecutable(.{
        .name = "det-selftest-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_node.root_module.addCSourceFile(.{
        .file = b.path("tests/selftest/c_node.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_node.root_module.addIncludePath(b.path("sdk/c"));
    phases.install(b, phases.selftest, c_node);

    // The 64-thread race of examples/race, at -O0 as in its post (at -O1 the increment becomes a
    // store of 1) and without sanitizer checks, which would add a branch inside the race.
    const race = b.addExecutable(.{
        .name = "race",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
            .sanitize_c = .off,
        }),
    });
    race.root_module.addCSourceFile(.{
        .file = b.path("examples/race/race.cpp"),
        .flags = &.{ "-std=c++17", "-O0", "-Wall", "-Wextra", "-Werror" },
    });
    phases.node_binary(b, "race-test", race);
    // The same program instrumented for coverage (as Antithesis's thread pausing needs), with the
    // C SDK's callbacks: thread pausing then pauses threads at its edges.
    const race_instrumented = b.addExecutable(.{
        .name = "race-instrumented",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
            .sanitize_c = .off,
        }),
    });
    race_instrumented.root_module.addCSourceFile(.{
        .file = b.path("examples/race/race.cpp"),
        .flags = &.{ "-std=c++17", "-O0", "-Wall", "-Wextra", "-Werror", "-fsanitize-coverage=trace-pc-guard" },
    });
    race_instrumented.root_module.addCSourceFile(.{
        .file = b.path("sdk/c/coverage.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    race_instrumented.root_module.addIncludePath(b.path("sdk/c"));
    phases.node_binary(b, "race-test", race_instrumented);

    // A maze for coverage-guided exploration, instrumented for edge coverage.
    const maze = b.addExecutable(.{
        .name = "det-maze",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    maze.root_module.addCSourceFile(.{
        .file = b.path("tests/selftest/maze.c"),
        .flags = &.{
            "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize-coverage=trace-pc-guard",
        },
    });
    maze.root_module.addIncludePath(b.path("sdk/c"));
    phases.install(b, phases.selftest, maze);
    // The same maze in Zig, through the Zig SDK's coverage hooks. In Debug, as the race: an
    // optimized build inlines its digits' draws into main, and each block's callback then sits
    // in the SDK's inlined code, its line the SDK's (the e2e coverage check names the maze's).
    const maze_zig = b.addExecutable(.{
        .name = "det-maze-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/selftest/maze.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    maze_zig.sanitize_coverage_trace_pc_guard = true;
    maze_zig.use_llvm = true; // Coverage instrumentation is an LLVM pass.
    phases.install(b, phases.selftest, maze_zig);
    // The race of examples/race in Zig, instrumented the same way: thread pausing at its edges.
    // Debug, as race.cpp is -O0: optimized, the counter only ever going from 0 to 1 becomes a
    // flag, and the race is gone (as the post's -O1).
    const race_zig = b.addExecutable(.{
        .name = "race-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/race/race.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    race_zig.sanitize_coverage_trace_pc_guard = true;
    race_zig.use_llvm = true;
    phases.node_binary(b, "race-test", race_zig);

    // The guest's base initramfs, built on the host from the guest runtime above.
    const initramfs = b.addExecutable(.{
        .name = "det-initramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/initramfs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phases.install(b, phases.determinismo, initramfs);

    // Products on determinismo (docs/PRODUCTS.md): binaries of their own, clients of serve's API.
    for ([_]struct { []const u8, []const u8 }{
        .{ "determinismo-ci", "src/products/ci.zig" },
        .{ "determinismo-sandbox", "src/products/sandbox.zig" },
    }) |product| {
        const product_exe = b.addExecutable(.{
            .name = product[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(product[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        phases.install(b, phases.determinismo, product_exe);
    }

    // End-to-end checks: real VMs through the command line, on the Linux host.
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check.dependOn(&e2e.step);
    // Installed with the self-tests: a machine that builds them ships it to the host that runs
    // the checks (infra/host/check.sh).
    phases.install(b, phases.selftest, e2e);
    // The e2e `wasm-plugin` check's plugin: a WebAssembly module (zig-out/bin/decide_named.wasm)
    // the explorer runs inside itself (src/wasm_plugin.zig), shipped with the self-tests.
    const wasm_decide_named = b.addExecutable(.{
        .name = "decide_named",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/wasm/decide_named.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
                .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory, .sign_ext, .mutable_globals, .nontrapping_fptoint }),
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_decide_named.entry = .disabled;
    wasm_decide_named.rdynamic = true;
    // Shared memory: compiled, its loops check the deadline's terminate flag (src/wasm_plugin.zig).
    wasm_decide_named.shared_memory = true;
    wasm_decide_named.max_memory = wasm_memory_max;
    phases.install(b, phases.selftest, wasm_decide_named);
    // And the `wasm-misbehaving` check's: one that traps or loops when asked for a decision.
    const wasm_misbehave = b.addExecutable(.{
        .name = "misbehave",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/wasm/misbehave.zig"),
            .target = wasm_decide_named.root_module.resolved_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_misbehave.entry = .disabled;
    wasm_misbehave.rdynamic = true;
    wasm_misbehave.shared_memory = true;
    wasm_misbehave.max_memory = wasm_memory_max;
    phases.install(b, phases.selftest, wasm_misbehave);
    // And the `wasm-reach` check's: a WASI module (its arguments, the clock, /state) that fetches
    // a URL with the `http` host function.
    const wasm_reach = b.addExecutable(.{
        .name = "reach",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/wasm/reach.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .wasi,
                .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
                .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory, .sign_ext, .mutable_globals, .nontrapping_fptoint }),
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_reach.entry = .disabled;
    wasm_reach.rdynamic = true;
    wasm_reach.wasi_exec_model = .reactor;
    wasm_reach.shared_memory = true;
    wasm_reach.max_memory = wasm_memory_max;
    phases.install(b, phases.selftest, wasm_reach);
    const e2e_run = b.addRunArtifact(e2e);
    // What it runs: determinismo, the guest, the self-tests and the workloads its checks name.
    for ([_]*std.Build.Step{ phases.determinismo, phases.guest, phases.selftest }) |phase| e2e_run.step.dependOn(phase);
    for (e2e_workloads) |name| e2e_run.step.dependOn(&b.top_level_steps.get(name).?.step);
    e2e_run.setCwd(b.path(".")); // Its defaults (zig-out/bin) and the examples' paths.
    // Checks take the host's next free CPUs before exploration runs (src/cpus.zig).
    e2e_run.setEnvironmentVariable("DETERMINISMO_CPU_PRIORITY", "1");
    // Its explorations are runs (src/runs.zig): in a store of its own, not the user's.
    // Relative to its working directory, the repository's.
    e2e_run.setEnvironmentVariable("DETERMINISMO_DATA", ".zig-cache/e2e-runs");
    const e2e_only = b.option([]const u8, "only", "e2e: the checks whose names contain this");
    if (e2e_only) |only| e2e_run.addArgs(&.{ "--only", only });
    const e2e_guest = b.option([]const u8, "guest", "e2e: the guest kernel and initramfs ($HOME/guest)");
    if (e2e_guest) |guest| e2e_run.addArgs(&.{ "--guest", guest });
    // Babashka, for the notebook's checks ($DETERMINISMO_BB did not reach the suite on srv3).
    const e2e_bb = b.option([]const u8, "bb", "e2e: babashka, for notebook evaluation");
    if (e2e_bb) |bb| e2e_run.addArgs(&.{ "--bb", bb });
    b.step("e2e", "Boot real systems: exploration, exact replays, tapes (on the Linux host)")
        .dependOn(&e2e_run.step);

    // Style checks run on the developer's machine, not the target.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const tidy_run = b.addRunArtifact(tidy);
    tidy_run.setCwd(b.path("."));
    b.step("tidy", "Check line and function lengths, headers and whitespace").dependOn(&tidy_run.step);

    // Unit tests use Linux system calls: they run on the Linux host (`zig build test` there).
    const test_step = b.step("test", "Run unit tests (on x86-64 Linux)");
    // The same tests built, not run (here too: cross-compiled), into <prefix>/tests, one binary
    // per root named after its path: infra/host/unit.sh runs them on a Linux host.
    const tests_step = b.step("tests", "Build the unit tests into <prefix>/tests, to run on x86-64 Linux");
    const test_roots = [_][]const u8{
        "src/main.zig",
        "src/products/ci.zig",
        "src/replays.zig",
        "src/verify.zig",
        "sdk/zig/determinismo.zig",
        "sdk/zig/tcp.zig",
        "examples/bank/resp.zig",
        "sdk/zig/ffi.zig",
        "sdk/zig/bindings.zig",
        "guest/runtime/init.zig",
        "guest/runtime/agent.zig",
        "guest/runtime/nodes.zig",
        "guest/runtime/netlink.zig",
        "guest/runtime/faults.zig",
        "guest/runtime/regex.zig",
        "guest/runtime/composer.zig",
        "guest/runtime/errno_trace.zig",
        "guest/runtime/persist_trace.zig",
        "guest/runtime/profile.zig",
        "guest/runtime/cores.zig",
        "guest/runtime/where.zig",
        "guest/runtime/gopclntab.zig",
        "guest/runtime/elfsyms.zig",
        "guest/runtime/symbol.zig",
        "guest/runtime/dwarf_types.zig",
        "guest/runtime/cxx.zig",
        "guest/runtime/voidstar.zig",
        "guest/runtime/output.zig",
        "guest/runtime/podlogs.zig",
        "guest/runtime/kubespec.zig",
        "guest/runtime/follow.zig",
        "guest/runtime/tail.zig",
        "guest/runtime/nrepl_relay.zig",
        "guest/runtime/runner.zig",
        "guest/runtime/junit.zig",
        "examples/nrepl/bencode.zig",
        "plugins/mutate.zig",
        "sdk/java/coverage_test.zig",
        "examples/shop/pg.zig",
        "tools/e2e.zig",
        "tools/initramfs.zig",
    };
    for (test_roots) |root| {
        const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "determinismo", .module = sdk },
                .{ .name = "tcp", .module = tcp },
                .{ .name = "core", .module = core },
                .{ .name = "protocol", .module = protocol },
            },
        }) });
        if (std.mem.eql(u8, root, "src/main.zig")) {
            unit_tests.root_module.addImport("build_options", build_options_module);
            unit_tests.root_module.addImport("sdk_tar", sdk_tar_module);
            unit_tests.root_module.addImport("regex", regex_module);
            duckdb_link(b, unit_tests.root_module, duckdb);
            zstd_link(b, unit_tests.root_module);
            wamr_link(b, unit_tests.root_module);
            // Its tests compiled by `check` too, not linked (no DuckDB): a Mac checks them.
            const check_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "determinismo", .module = sdk },
                    .{ .name = "tcp", .module = tcp },
                    .{ .name = "build_options", .module = build_options_module },
                    .{ .name = "core", .module = core },
                    .{ .name = "protocol", .module = protocol },
                    .{ .name = "sdk_tar", .module = sdk_tar_module },
                    .{ .name = "regex", .module = regex_module },
                },
            }) });
            check_tests.root_module.link_libc = true;
            check.dependOn(&check_tests.step);
        }
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        const name = std.mem.replaceOwned(u8, b.allocator, root[0 .. root.len - ".zig".len], "/", "-") catch @panic("OOM");
        tests_step.dependOn(&b.addInstallArtifact(unit_tests, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
            .dest_sub_path = name,
        }).step);
    }
    // A deployment's own workloads, built in this build beside the platform's (`zig build
    // <workload>`): workloads.zig's `register`, given the platform's modules and steps. Empty in
    // the platform's repository; a tree assembled with a workloads repository replaces it.
    @import("workloads.zig").register(b, .{
        .target = target,
        .optimize = optimize,
        .sdk = sdk,
        .tcp = tcp,
        .core = core,
        .protocol = protocol,
        .resp = resp,
        .pg = pg,
        .nrepl = nrepl,
        .examples = "examples",
        .platform = ".",
        .program_pack = program_pack_tool,
        .check = check,
        .workloads = phases.workloads,
        .test_step = test_step,
        .tests_step = tests_step,
    });
    // The core alone (src/core/core.zig), built and tested with nothing of the explorer's: a
    // hidden dependency shows here. Its tests use Linux system calls: run on the Linux host
    // (infra/host/unit.sh core), compiled anywhere (`check`).
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "protocol", .module = protocol }},
    }) });
    check.dependOn(&core_tests.step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    b.step("core-test", "Run the core's unit tests alone (on x86-64 Linux)").dependOn(&b.addRunArtifact(core_tests).step);
    tests_step.dependOn(&b.addInstallArtifact(core_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
        .dest_sub_path = "src-core-core",
    }).step);
    const tidy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/tidy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(tidy_tests).step);
}

/// The repository's commit (git from where zig build runs, the repository's root), short, with
/// "-dirty" when tracked files other than Markdown (notes, docs: never built) changed; "unknown" without git (a tree synced without .git). Zig
/// caches the build's configuration, so this can be stale: infra/host's scripts pass -Dcommit.
/// The source files (`extension`) below `directory`, as inputs of `run`.
fn program_inputs(b: *std.Build, run: *std.Build.Step.Run, directory: []const u8, extension: []const u8) void {
    const io = b.graph.io;
    var dir = b.root.openDir(io, directory, .{ .iterate = true }) catch |err|
        std.debug.panic("{s}: {t}", .{ directory, err });
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("{s}: {t}", .{ directory, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, extension)) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ directory, entry.path })));
    }
}

fn core_id_of(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const u8 {
    var code: u8 = 0;
    // Every .zig file of the core's and the protocol it shares with the SDK, in path order, each
    // path then its content as it is on disk (uncommitted changes and new files too): read by
    // the shell, as the build runs in trees that are no git repository (update.sh's frozen copy,
    // check.sh's), from the tree's root as commit_of's git does.
    const files = b.runAllowFail(&.{
        "sh", "-c",
        \\find src/core sdk/zig/protocol.zig -name '*.zig' -type f | LC_ALL=C sort | while IFS= read -r file; do
        \\  printf '%s\n' "$file"; wc -c < "$file"; cat "$file"
        \\done
        ,
    }, &code, .ignore) catch return "unknown";
    if (files.len == 0) return "unknown";
    // Zig caches the configure phase by its declared inputs (build.zig, the options, the files
    // named here): each file hashed is one, and its directory's entries (a file added or
    // removed), or a core edit built with the id from before it (2026-11-15: src/core/pit.zig
    // edited, the id unchanged; deploys escaped it only by -Dcommit's new value each time).
    b.dependOnDirectoryContents(b.path("src/core"));
    const list = b.runAllowFail(&.{ "sh", "-c", "find src/core sdk/zig/protocol.zig -name '*.zig' -type f" }, &code, .ignore) catch
        return "unknown";
    var paths = std.mem.tokenizeScalar(u8, list, '\n');
    while (paths.next()) |path| b.dependOnFileContents(b.path(path));
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(files);
    hasher.update(@import("builtin").zig_version_string);
    hasher.update(@tagName(optimize));
    hasher.update(target.result.zigTriple(b.allocator) catch @panic("OOM"));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return b.fmt("{x}", .{digest[0..8]});
}

fn commit_of(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "rev-parse", "--short=12", "HEAD" }, &code, .ignore) catch
        return "unknown";
    const status = b.runAllowFail(&.{ "git", "status", "--porcelain", "--untracked-files=no", "--", ".", ":!*.md" }, &code, .ignore) catch "";
    const commit = std.mem.trim(u8, head, " \n");
    // Git's state is no input the configure cache can track (a commit, an edit anywhere): read
    // again by every build that has no -Dcommit (deploys and checks give theirs).
    b.graph.poisonCache();
    return if (std.mem.trim(u8, status, " \n").len > 0) b.fmt("{s}-dirty", .{commit}) else commit;
}

fn duckdb_link(b: *std.Build, module: *std.Build.Module, directory: []const u8) void {
    const archives = [_][]const u8{
        "libduckdb_static.a", "libcore_functions_extension.a", "libjson_extension.a", "libstdc++.a",
    };
    for (archives) |archive| module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ directory, archive }) });
    module.link_libc = true;
    // libstdc++ unwinds with LLVM's libunwind, Zig's own (the same _Unwind ABI as libgcc's).
    module.linkSystemLibrary("unwind", .{ .use_pkg_config = .no });
}

/// zstd's compressor (its lib/common and lib/compress, C, single-threaded, no assembly): a
/// timeline's events compressed as it ends (src/event_files.zig), 13.7 times smaller (a TiDB
/// timeline's 28 MB in 2.1 MB): srv4 kept 1.7 TB of them, its disk past the holders' reserve.
/// Reading them back is Zig's own (std.compress.zstd). Its functions are declared in
/// src/event_files.zig: `check` compiles without it.
fn zstd_link(b: *std.Build, module: *std.Build.Module) void {
    const zstd = b.dependency("zstd", .{});
    module.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "common/debug.c",                      "common/entropy_common.c",
            "common/error_private.c",              "common/fse_decompress.c",
            "common/pool.c",                       "common/threading.c",
            "common/xxhash.c",                     "common/zstd_common.c",
            "compress/fse_compress.c",             "compress/hist.c",
            "compress/huf_compress.c",             "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",   "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",                "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",                 "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",            "compress/zstdmt_compress.c",
        },
        .flags = &.{ "-DZSTD_DISABLE_ASM", "-DZSTD_LEGACY_SUPPORT=0" },
    });
    module.link_libc = true;
}

/// WAMR (the WebAssembly Micro Runtime, 2.4.4): wasm plugins run inside the explorer as native
/// code, each module compiled ahead of time by WAMR's wamrc (src/wasm_plugin.zig), this its
/// loader and runtime in C, no interpreter, no JIT; WASI (files under its preopened directories,
/// clocks, randomness, its arguments and environment, sockets) for a module that imports it.
/// Software bounds checks (no signal handlers but the deadline's), shared memory and the thread
/// manager's terminate flag (a call past its deadline is stopped: src/wasm_interrupt.c). src/wasm_plugin.zig declares its
/// functions: `check` compiles without it.
fn wamr_link(b: *std.Build, module: *std.Build.Module) void {
    const wamr = b.dependency("wamr", .{});
    const includes = [_][]const u8{
        "core",                                                               "core/iwasm/include",                                             "core/iwasm/common",
        "core/iwasm/aot",                                                     "core/iwasm/interpreter",                                         "core/iwasm/libraries/thread-mgr",
        "core/shared/platform/linux",                                         "core/shared/platform/include",                                   "core/shared/utils",
        "core/shared/mem-alloc",                                              "core/shared/platform/common/libc-util",                          "core/iwasm/libraries/libc-wasi",
        "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include", "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src",
    };
    for (includes) |directory| module.addIncludePath(wamr.path(directory));
    const flags = [_][]const u8{
        "-DBH_PLATFORM_LINUX",                 "-DBUILD_TARGET_X86_64",
        "-DBH_MALLOC=wasm_runtime_malloc",     "-DBH_FREE=wasm_runtime_free",
        "-DWASM_ENABLE_INTERP=0",              "-DWASM_ENABLE_AOT=1",
        "-DWASM_ENABLE_JIT=0",                 "-DWASM_ENABLE_THREAD_MGR=1",
        "-DWASM_ENABLE_SHARED_MEMORY=1",       "-DWASM_ENABLE_LIBC_BUILTIN=0",
        "-DWASM_ENABLE_LIBC_WASI=1",           "-DWASM_ENABLE_MODULE_INST_CONTEXT=1",
        "-DWASM_ENABLE_BULK_MEMORY=1",         "-DWASM_ENABLE_REF_TYPES=1",
        "-DWASM_DISABLE_HW_BOUND_CHECK=1",     "-DWASM_DISABLE_STACK_HW_BOUND_CHECK=1",
        "-DWASM_DISABLE_WAKEUP_BLOCKING_OP=1", "-DWASM_ENABLE_LOG=0",
        "-DWASM_HAVE_MREMAP=1",                "-D_GNU_SOURCE",
        "-DNDEBUG",
        // Its loaders read and write words at any address (x86-64 allows it), and it calls a
        // module's compiled code through C function pointers (aot_runtime.c: no type prefix
        // before machine code it loaded): both by design, so the sanitizer's alignment and
        // function checks are off for it alone, every other one kept.
                                   "-fno-sanitize=alignment",
        "-fno-sanitize=function",
    };
    module.addCSourceFiles(.{
        .root = wamr.path("core"),
        .files = &.{
            "iwasm/common/wasm_application.c",                                         "iwasm/common/wasm_c_api.c",
            "iwasm/common/wasm_blocking_op.c",                                         "iwasm/common/wasm_exec_env.c",
            "iwasm/common/wasm_loader_common.c",                                       "iwasm/common/wasm_memory.c",
            "iwasm/common/wasm_native.c",                                              "iwasm/common/wasm_runtime_common.c",
            "iwasm/common/wasm_shared_memory.c",                                       "iwasm/common/arch/invokeNative_em64.s",
            "iwasm/aot/aot_loader.c",                                                  "iwasm/aot/aot_runtime.c",
            "iwasm/aot/aot_intrinsic.c",                                               "iwasm/aot/arch/aot_reloc_x86_64.c",
            "iwasm/libraries/thread-mgr/thread_manager.c",                             "shared/platform/linux/platform_init.c",
            "shared/platform/common/posix/posix_blocking_op.c",                        "shared/platform/common/posix/posix_malloc.c",
            "shared/platform/common/posix/posix_memmap.c",                             "shared/platform/common/posix/posix_sleep.c",
            "shared/platform/common/posix/posix_thread.c",                             "shared/platform/common/posix/posix_time.c",
            "shared/utils/bh_assert.c",                                                "shared/utils/bh_bitmap.c",
            "shared/utils/bh_common.c",                                                "shared/utils/bh_hashmap.c",
            "shared/utils/bh_leb128.c",                                                "shared/utils/bh_list.c",
            "shared/utils/bh_log.c",                                                   "shared/utils/bh_queue.c",
            "shared/utils/bh_vector.c",                                                "shared/utils/runtime_timer.c",
            "shared/mem-alloc/mem_alloc.c",                                            "shared/mem-alloc/ems/ems_alloc.c",
            "shared/mem-alloc/ems/ems_gc.c",                                           "shared/mem-alloc/ems/ems_hmu.c",
            "shared/mem-alloc/ems/ems_kfc.c",
            // WASI.
                                                     "iwasm/libraries/libc-wasi/libc_wasi_wrapper.c",
            "iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/blocking_op.c", "iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/posix.c",
            "iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/random.c",      "iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/str.c",
            "shared/platform/common/posix/posix_file.c",                               "shared/platform/common/posix/posix_clock.c",
            "shared/platform/common/posix/posix_socket.c",                             "shared/platform/common/libc-util/libc_errno.c",
        },
        .flags = &flags,
    });
    // The deadline's interrupt, through WAMR's own headers.
    module.addCSourceFile(.{ .file = b.path("src/wasm_interrupt.c"), .flags = &flags });
    module.link_libc = true;
}

/// A wasm plugin's memory at most (shared memory declares one): 256 MiB.
const wasm_memory_max = 256 << 20;

/// The example workloads the e2e checks run (tools/e2e.zig's programs from zig-out/bin).
const e2e_workloads = [_][]const u8{ "bank-test", "shop-test", "clojure-bank-test", "k3s-test", "race-test", "nrepl-test" };

const Phases = struct {
    determinismo: *std.Build.Step,
    guest: *std.Build.Step,
    selftest: *std.Build.Step,
    workloads: *std.Build.Step,

    /// Installed with its phase, and with `zig build`.
    fn install(phases: Phases, b: *std.Build, phase: *std.Build.Step, artifact: *std.Build.Step.Compile) void {
        _ = phases;
        const installed = b.addInstallArtifact(artifact, .{});
        phase.dependOn(&installed.step);
        b.getInstallStep().dependOn(&installed.step);
    }

    /// A workload's test program: its own step (`zig build <name>`), in the workloads phase.
    fn workload(phases: Phases, b: *std.Build, name: []const u8, artifact: *std.Build.Step.Compile) void {
        const step = b.step(name, b.fmt("The {s} workload: its test program and its nodes' binaries", .{name}));
        const installed = b.addInstallArtifact(artifact, .{});
        step.dependOn(&installed.step);
        phases.workloads.dependOn(step);
        b.getInstallStep().dependOn(&installed.step);
    }

    /// A binary a workload's nodes run (`binary` nodes): built with that workload's step.
    fn node_binary(phases: Phases, b: *std.Build, workload_name: []const u8, artifact: *std.Build.Step.Compile) void {
        _ = phases;
        const step = &b.top_level_steps.get(workload_name).?.step;
        const installed = b.addInstallArtifact(artifact, .{});
        step.dependOn(&installed.step);
        b.getInstallStep().dependOn(&installed.step);
    }
};
