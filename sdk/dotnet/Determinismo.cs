// SPDX-License-Identifier: MIT
// determinismo SDK for .NET (C#, F#, VB): assertions, events and platform randomness, with
// Antithesis's .NET SDK's names (Assert, Lifecycle, Random, AntithesisRandom): code written for
// it ports by changing `using Antithesis.SDK;` to `using Determinismo;`. One file, no
// dependencies beyond the base library: compile it with your code (.NET 8 or later).
//
// Inside determinismo everything goes through /dev/determinismo (events are recorded with their
// moment; random values are platform decisions, steerable and replayable). Outside it,
// randomness comes from the OS and events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT (or
// ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else nowhere (Antithesis's default:
// assertions evaluated, nothing written).
//
//   Assert.Always(total == 1000, "total balance is conserved", new JsonObject { ["total"] = total });
//   var account = Random.RandomBelow(10);

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace Determinismo;

/// <summary>The platform: its device inside determinismo, the local output outside.</summary>
internal static class Platform
{
    private const string DevicePath = "/dev/determinismo";
    private const int MessageSizeMax = 4096 - 16; // One event or one pull per call.
    private static readonly object Lock = new();
    // The device through libc's open, read and write: one read is one pull, one write one
    // event (a FileStream may buffer, or read and write at offsets).
    private const int ReadWrite = 2; // O_RDWR; never O_CREAT: nothing is made where it is not.
    private const int CloseOnExec = 0x80000; // O_CLOEXEC
    private static readonly int Device = OpenDevice();
    private static TextWriter? localOutput;

    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int LibcOpen(string path, int flags);

    [DllImport("libc", EntryPoint = "read", SetLastError = true)]
    private static extern nint LibcRead(int fd, byte[] buffer, nint count);

    [DllImport("libc", EntryPoint = "write", SetLastError = true)]
    private static extern nint LibcWrite(int fd, byte[] buffer, nint count);

    public static bool Inside => Device >= 0;

    private static int OpenDevice()
    {
        if (!OperatingSystem.IsLinux()) return -1;
        try
        {
            return LibcOpen(DevicePath, ReadWrite | CloseOnExec);
        }
        catch (Exception unavailable) when (unavailable is DllNotFoundException or EntryPointNotFoundException)
        {
            return -1;
        }
    }

    /// <summary><paramref name="buffer"/> filled with random bytes: a platform decision inside.</summary>
    public static void Bytes(Span<byte> buffer)
    {
        if (Device < 0)
        {
            RandomNumberGenerator.Fill(buffer);
            return;
        }
        lock (Lock)
        {
            var chunk = new byte[256];
            var done = 0;
            while (done < buffer.Length)
            {
                var want = Math.Min(chunk.Length, buffer.Length - done);
                var got = (int)LibcRead(Device, chunk, want);
                if (got <= 0) throw new IOException("determinismo: short read from " + DevicePath);
                chunk.AsSpan(0, got).CopyTo(buffer.Slice(done));
                done += got;
            }
        }
    }

    public static ulong NextUInt64()
    {
        Span<byte> bytes = stackalloc byte[8];
        Bytes(bytes);
        return BitConverter.ToUInt64(bytes);
    }

    /// <summary>One event: one write to the device, or a line of the local output.</summary>
    public static void Emit(string line)
    {
        lock (Lock)
        {
            if (Device < 0)
            {
                LocalOutput().WriteLine(line);
                LocalOutput().Flush();
                return;
            }
            var bytes = Encoding.UTF8.GetBytes(line);
            if (LibcWrite(Device, bytes, bytes.Length) != bytes.Length) Console.Error.WriteLine(line); // One write, one event.
        }
    }

    public static bool Fits(string line) => Encoding.UTF8.GetByteCount(line) <= MessageSizeMax;

    private static TextWriter LocalOutput()
    {
        if (localOutput != null) return localOutput;
        localOutput = TextWriter.Null;
        var path = Environment.GetEnvironmentVariable("DETERMINISMO_SDK_LOCAL_OUTPUT");
        if (string.IsNullOrEmpty(path)) path = Environment.GetEnvironmentVariable("ANTITHESIS_SDK_LOCAL_OUTPUT");
        if (!string.IsNullOrEmpty(path))
        {
            try
            {
                localOutput = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
            }
            catch (Exception unwritable) when (unwritable is IOException or UnauthorizedAccessException)
            {
                localOutput = TextWriter.Null;
            }
        }
        return localOutput;
    }

    public static string Quote(string text) => JsonSerializer.Serialize(text);

    public static string Json(JsonNode? node) => node == null ? "{}" : node.ToJsonString();
}

/// <summary>Properties of the system: each assertion's message is its identity.</summary>
public static class Assert
{
    /// <summary>
    /// Which evaluations become events: every one (false, the default: queries see each), or, as
    /// Antithesis's SDKs do, each assertion's first pass and first failure in this process (true:
    /// for hot paths, the same verdict with far fewer events). Set it once, at the start.
    /// </summary>
    public static bool FirstPassFirstFailure { get; set; }

    private static readonly ConcurrentDictionary<string, bool> Seen = new();
    private static readonly ConcurrentDictionary<string, bool> Located = new();
    private static readonly ConcurrentDictionary<string, double> Best = new();

    public static void Always(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("always", condition, message, details, file, line, member);

    public static void AlwaysOrUnreachable(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("always_or_unreachable", condition, message, details, file, line, member);

    public static void Sometimes(bool condition, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("sometimes", condition, message, details, file, line, member);

    public static void Reachable(string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("reachable", true, message, details, file, line, member);

    public static void Unreachable(string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Assertion("unreachable", true, message, details, file, line, member);

    // Guidance assertions: the compared values in the details, and a guidance event telling
    // strategies how far the timeline is from the interesting outcome (an always violated, a
    // sometimes true): distance, lower is closer, 0 or less is there.

    public static void AlwaysGreaterThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left > right, left - right, left, right, message, details, file, line, member);

    public static void AlwaysGreaterThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left >= right, left - right, left, right, message, details, file, line, member);

    public static void AlwaysLessThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left < right, right - left, left, right, message, details, file, line, member);

    public static void AlwaysLessThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(true, left <= right, right - left, left, right, message, details, file, line, member);

    public static void SometimesGreaterThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left > right, left - right, left, right, message, details, file, line, member);

    public static void SometimesGreaterThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left >= right, left - right, left, right, message, details, file, line, member);

    public static void SometimesLessThan(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left < right, right - left, left, right, message, details, file, line, member);

    public static void SometimesLessThanOrEqualTo(double left, double right, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "") =>
        Compare(false, left <= right, right - left, left, right, message, details, file, line, member);

    /// <summary>At least one of the named conditions holds, every time.</summary>
    public static void AlwaysSome(IReadOnlyDictionary<string, bool> conditions, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "")
    {
        var held = Held(conditions);
        Assertion("always", held > 0, message, ConditionsDetails(conditions, details), file, line, member);
        Guidance(message, held);
    }

    /// <summary>All the named conditions hold together, at least once.</summary>
    public static void SometimesAll(IReadOnlyDictionary<string, bool> conditions, string message, JsonObject? details = default,
        [CallerFilePath] string file = "", [CallerLineNumber] int line = 0, [CallerMemberName] string member = "")
    {
        var held = Held(conditions);
        Assertion("sometimes", held == conditions.Count, message, ConditionsDetails(conditions, details), file, line, member);
        Guidance(message, conditions.Count - held);
    }

    private static void Compare(bool always, bool holds, double margin, double left, double right, string message,
        JsonObject? details, string file, int line, string member)
    {
        var merged = new JsonObject { ["left"] = Operand(left), ["right"] = Operand(right), ["details"] = details?.DeepClone() ?? new JsonObject() };
        Assertion(always ? "always" : "sometimes", holds, message, merged, file, line, member);
        Guidance(message, always ? margin : -margin);
    }

    private static int Held(IReadOnlyDictionary<string, bool> conditions)
    {
        var held = 0;
        foreach (var value in conditions.Values) if (value) held++;
        return held;
    }

    private static JsonObject ConditionsDetails(IReadOnlyDictionary<string, bool> conditions, JsonObject? details)
    {
        var named = new JsonObject();
        foreach (var (name, value) in conditions) named[name] = value;
        return new JsonObject { ["conditions"] = named, ["details"] = details?.DeepClone() ?? new JsonObject() };
    }

    // A comparison's operand as JSON. JSON has no infinity or NaN (System.Text.Json refuses them,
    // and the assertion was lost), so those are the strings "Infinity", "-Infinity" and "NaN", as
    // every SDK of ours sends them.
    private static JsonNode Operand(double value) =>
        double.IsNaN(value) ? JsonValue.Create("NaN")
        : double.IsInfinity(value) ? JsonValue.Create(value > 0 ? "Infinity" : "-Infinity")
        : JsonValue.Create(value);

    private static void Guidance(string message, double distance)
    {
        // NaN is nowhere; an infinite distance (an infinite operand) is the largest JSON number:
        // "R" writes "Infinity" and "NaN", no JSON at all.
        if (double.IsNaN(distance)) return;
        distance = Math.Clamp(distance, -double.MaxValue, double.MaxValue);
        // Only improvements: all a strategy needs.
        if (Best.TryGetValue(message, out var known) && distance >= known) return;
        Best[message] = distance;
        Platform.Emit("{\"guidance\":{\"message\":" + Platform.Quote(message) + ",\"distance\":" +
            distance.ToString("R", CultureInfo.InvariantCulture) + "}}");
    }

    private static void Assertion(string kind, bool condition, string message, JsonObject? details,
        string file, int line, string member)
    {
        if (FirstPassFirstFailure && !Seen.TryAdd(condition + "\0" + message, true)) return;
        Catalog.Note(kind, message);
        // The caller's place, the first time an assertion runs.
        var location = Located.TryAdd(message, true)
            ? ",\"location\":{\"file\":" + Platform.Quote(file) + ",\"line\":" + line + ",\"function\":" + Platform.Quote(member) + "}"
            : "";
        var head = "{\"assert\":{\"type\":\"" + kind + "\",\"message\":" + Platform.Quote(message) +
            ",\"condition\":" + (condition ? "true" : "false") + location + ",\"details\":";
        var text = head + Platform.Json(details) + "}}";
        if (!Platform.Fits(text)) text = head + "{}}}";
        Platform.Emit(text);
    }
}

/// <summary>The assertion catalog: announced before assertions run, so one never reached is judged too.</summary>
public static class Catalog
{
    private static readonly object Lock = new();
    private static readonly List<(string Kind, string Message)> Declared = new();
    private static readonly HashSet<string> Known = new();

    /// <summary>
    /// Announces an assertion (kind: always, always_or_unreachable, sometimes, reachable,
    /// unreachable). A module initializer can declare a program's (Antithesis's .NET SDK
    /// generates one); each assertion is announced once.
    /// </summary>
    public static void Declare(string kind, string message)
    {
        if (!Note(kind, message)) return;
        // Outside determinismo, listed (Assertions) but not announced.
        if (!Platform.Inside) return;
        Platform.Emit("{\"assert\":{\"type\":" + Platform.Quote(kind) + ",\"message\":" + Platform.Quote(message) + ",\"hit\":false}}");
    }

    internal static bool Note(string kind, string message)
    {
        lock (Lock)
        {
            if (!Known.Add(kind + "\0" + message)) return false;
            Declared.Add((kind, message));
            return true;
        }
    }

    /// <summary>The assertions declared or run so far.</summary>
    public static IReadOnlyList<(string Kind, string Message)> Assertions()
    {
        lock (Lock) return Declared.ToArray();
    }

    /// <summary>Writes the catalog, one JSON object a line ({"kind","message"}): for review or CI.</summary>
    public static void Write(TextWriter output)
    {
        foreach (var (kind, message) in Assertions())
            output.WriteLine("{\"kind\":" + Platform.Quote(kind) + ",\"message\":" + Platform.Quote(message) + "}");
    }
}

/// <summary>The test's lifecycle and events of its own.</summary>
/// <summary>An objective's direction (<see cref="Lifecycle.Optimize"/>).</summary>
public enum Goal { Maximize, Minimize }

public static class Lifecycle
{
    /// <summary>Whether this runs inside determinismo (Antithesis's IsAntithesis).</summary>
    public static bool IsDeterminismo => Platform.Inside;

    public static bool IsAntithesis => Platform.Inside;

    /// <summary>The system is ready: the platform snapshots here.</summary>
    public static void SetupComplete(JsonObject? details = null) =>
        Platform.Emit("{\"lifecycle\":\"setup_complete\",\"details\":" + Platform.Json(details) + "}");

    public static void SendEvent(string? name, JsonObject? details = null) =>
        Platform.Emit("{\"event\":" + Platform.Quote(name ?? "") + ",\"details\":" + Platform.Json(details) + "}");

    /// <summary>
    /// An objective for exploration (Antithesis's "Optimizing our way through Metroid"):
    /// <paramref name="bucket"/>'s strings and booleans split states into buckets (a leader, a
    /// phase), explored evenly, each keeping the state with the best <paramref name="value"/> by
    /// <paramref name="goal"/>; the tree returns there and goes further from it.
    /// </summary>
    public static void Optimize(string message, JsonObject? bucket, double value, Goal goal = Goal.Maximize)
    {
        if (!double.IsFinite(value)) return;
        Platform.Emit("{\"optimize\":{\"message\":" + Platform.Quote(message) + ",\"bucket\":" + Platform.Json(bucket) +
            ",\"value\":" + value.ToString("R", CultureInfo.InvariantCulture) + ",\"goal\":\"" +
            (goal == Goal.Maximize ? "maximize" : "minimize") + "\"}}");
    }

    /// <summary>Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md).</summary>
    public static void Output(JsonObject json) => Platform.Emit(json.ToJsonString());

    /// <summary>
    /// A fault now, from the scenario: <c>Fault("{\"kind\":\"pause\",\"node\":\"db\"}")</c> (as
    /// det-faults inject takes it). Applied, logged and undone like a drawn one; only while the
    /// fault injector runs.
    /// </summary>
    public static void Fault(string json) => Run("/opt/determinismo/bin/det-faults", "inject", json);

    /// <summary>
    /// Aims the fault injector at <paramref name="node"/> from now on, until another call ("" for
    /// none): half its faults involve it, each a decision strategies see and replays repeat.
    /// </summary>
    public static void FaultAim(string node) => Run("/opt/determinismo/bin/det-faults", "aim", node);

    /// <summary>A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS) of <paramref name="seconds"/>; 0 ends it.</summary>
    public static void StopFaults(double seconds) =>
        Run(Environment.GetEnvironmentVariable("DETERMINISMO_STOP_FAULTS") ?? "/opt/determinismo/bin/det-stop-faults",
            seconds.ToString(CultureInfo.InvariantCulture));

    /// <summary>
    /// A moment worth a crash (the Zig SDK's crash_point: the node just changed its view of the
    /// cluster, a record is half written): inside determinismo and in a node, a point is armed one
    /// two-second stretch in eight (a named decision, "crash point &lt;name&gt;"), and its first
    /// evaluation then asks the fault injector to crash this node now (det-faults crash-point,
    /// which refuses at once where the injector would) and waits for it, up to half a second.
    /// </summary>
    public static void CrashPoint(string name)
    {
        if (!Platform.Inside) return;
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DETERMINISMO_NODE"))) return;
        var now = DateTime.UtcNow.Ticks; // Virtual time inside determinismo.
        bool armed;
        lock (CrashPoints)
        {
            if (!CrashPoints.TryGetValue(name, out var point) || now >= point.UntilTicks)
                point = (Random.RandomBelowNamed("crash point " + name, 8) == 0, now + 2 * TimeSpan.TicksPerSecond);
            armed = point.Armed;
            CrashPoints[name] = (false, point.UntilTicks); // Once a stretch.
        }
        if (!armed) return;
        var askedNs = MonotonicNs();
        if (RunStatus("/opt/determinismo/bin/det-faults", "crash-point",
                askedNs.ToString(CultureInfo.InvariantCulture), "point " + name) != 0) return;
        while (MonotonicNs() - askedNs < 500_000_000UL) Thread.Sleep(5);
    }

    private static readonly Dictionary<string, (bool Armed, long UntilTicks)> CrashPoints = new();

    /// <summary>CLOCK_MONOTONIC in nanoseconds (Stopwatch's timestamp on Linux): the injector's clock.</summary>
    private static ulong MonotonicNs() =>
        (ulong)((System.Numerics.BigInteger)System.Diagnostics.Stopwatch.GetTimestamp() * 1_000_000_000
            / System.Diagnostics.Stopwatch.Frequency);

    /// <summary>A command's exit status; -1 when it could not run.</summary>
    private static int RunStatus(string program, params string[] arguments)
    {
        try
        {
            using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(program, arguments));
            if (process == null) return -1;
            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Exception unavailable) when (unavailable is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return -1;
        }
    }

    private static void Run(string program, params string[] arguments)
    {
        try
        {
            using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(program, arguments));
            process?.WaitForExit();
        }
        catch (Exception unavailable) when (unavailable is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // Outside determinismo: nothing to ask.
        }
    }
}

/// <summary>Code coverage and thread pausing for .NET. determinismo-dotnet-instrument
/// (sdk/dotnet/instrument) rewrites a built assembly with this SDK compiled in so that each of its
/// sequence points (a statement: `if (x == 0) x++;` has two) calls <see cref="Point"/> first.
/// A point reports its line the first time the process runs it (a "coverage" event, `line
/// &lt;file&gt;:&lt;n&gt;`, as the other SDKs report theirs), and is where thread pausing pauses
/// (the C SDK's det_pausing_at): inside determinismo, one stretch of two seconds (virtual time) in
/// four, a named decision ("thread pausing") at its start, one point in 64 is a slow point with its
/// own pause (1 to 10 ms), drawn for the stretch: a thread reaching one sleeps there, at most 8
/// times a stretch. Threads that reach a slow point wait there together, so the checks of a
/// check-then-act between them all run before any of its acts. The node's coverage set
/// (DETERMINISMO_COVERAGE: file name prefixes, "-" excluding) scopes both. Inside determinismo
/// only: outside it a point returns at once.</summary>
public static class Coverage
{
    private const ulong SlowOneIn = 64;
    private const int PausesMax = 8;
    private static long seed; // This stretch's; 0 when it pauses nothing.
    private static int stretch;
    [ThreadStatic] private static int threadStretch;
    [ThreadStatic] private static int threadPauses;
    private static readonly string[] Included;
    private static readonly string[] Excluded;

    static Coverage()
    {
        var entries = (Environment.GetEnvironmentVariable("DETERMINISMO_COVERAGE") ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Where(entry => entry != "-")
            .ToArray();
        Included = entries.Where(entry => !entry.StartsWith('-')).ToArray();
        Excluded = entries.Where(entry => entry.StartsWith('-')).Select(entry => entry[1..]).ToArray();
        if (!Platform.Inside) return;
        new Thread(Stretches) { IsBackground = true, Name = "determinismo-pausing" }.Start();
    }

    /// <summary>The instrumentation's call, at a point: `hits` the assembly's (0 not run yet, 1
    /// covered, 2 outside the coverage set), `id` its index there, `key` its name's hash (the
    /// tool's: .NET's string hashes differ between processes), `name` its line.</summary>
    public static void Point(int[] hits, int id, long key, string name)
    {
        if (!Platform.Inside) return;
        var state = Volatile.Read(ref hits[id]);
        if (state == 0)
        {
            var covered = InSet(name);
            // One thread reports it.
            if (Interlocked.CompareExchange(ref hits[id], covered ? 1 : 2, 0) == 0 && covered)
                Lifecycle.SendEvent("coverage", new JsonObject { ["name"] = name });
            state = covered ? 1 : 2;
        }
        if (state != 1) return;
        var current = Volatile.Read(ref seed);
        if (current == 0) return;
        var value = Mix((ulong)current ^ (ulong)key);
        if (value % SlowOneIn != 0) return; // Not a slow point this stretch.
        var number = Volatile.Read(ref stretch);
        if (threadStretch != number)
        {
            threadStretch = number;
            threadPauses = 0;
        }
        if (threadPauses >= PausesMax) return; // Others may still pause here.
        threadPauses += 1;
        Thread.Sleep(1 + (int)((value >> 8) % 10));
    }

    private static bool InSet(string name)
    {
        // "line <file>:<n>"
        var file = name.StartsWith("line ") ? name[5..name.LastIndexOf(':')] : name;
        if (Excluded.Any(prefix => file.StartsWith(prefix, StringComparison.Ordinal))) return false;
        return Included.Length == 0 || Included.Any(prefix => file.StartsWith(prefix, StringComparison.Ordinal));
    }

    private static void Stretches()
    {
        while (true)
        {
            var pausing = Random.RandomBelowNamed("thread pausing", 4) == 0;
            Volatile.Write(ref seed, pausing ? (long)(Random.GetRandom() | 1) : 0);
            Interlocked.Increment(ref stretch);
            Thread.Sleep(2000);
        }
    }

    private static ulong Mix(ulong value)
    {
        value *= 0x9E3779B97F4A7C15;
        value ^= value >> 29;
        value *= 0xBF58476D1CE4E5B9;
        return value ^ (value >> 32);
    }
}

/// <summary>Platform randomness: every draw a decision inside determinismo.</summary>
public static class Random
{
    /// <summary>64 random bits (Antithesis's GetRandom).</summary>
    public static ulong GetRandom() => Platform.NextUInt64();

    public static void Bytes(Span<byte> buffer) => Platform.Bytes(buffer);

    /// <summary>A uniformly random integer in [0, count).</summary>
    public static ulong RandomBelow(ulong count)
    {
        if (count == 0) throw new ArgumentOutOfRangeException(nameof(count), "count must be positive");
        return Platform.NextUInt64() % count;
    }

    /// <summary>A double in [0, 1) from 53 random bits.</summary>
    public static double RandomFloat() => (Platform.NextUInt64() >> 11) * (1.0 / (1UL << 53));

    /// <summary>One of the items, a platform decision; default for none (Antithesis's RandomChoice).</summary>
    public static T? RandomChoice<T>(IReadOnlyList<T> items) =>
        items.Count == 0 ? default : items[(int)RandomBelow((ulong)items.Count)];

    /// <summary>A named decision among options: the index chosen, announced with the options for strategies.</summary>
    public static int Decide(string name, IReadOnlyList<string> options)
    {
        if (options.Count == 0) throw new ArgumentException("no options", nameof(options));
        if (Platform.Inside)
        {
            var list = new JsonArray();
            foreach (var option in options) list.Add(option);
            Platform.Emit("{\"decision\":{\"name\":" + Platform.Quote(name) + ",\"options\":" + list.ToJsonString() + "}}");
        }
        return (int)RandomBelow((ulong)options.Count);
    }

    /// <summary>RandomBelow, named for strategies ("retry.jitterMs").</summary>
    public static ulong RandomBelowNamed(string name, ulong count)
    {
        if (Platform.Inside) Platform.Emit("{\"decision\":{\"name\":" + Platform.Quote(name) + ",\"range\":" + count + "}}");
        return RandomBelow(count);
    }

    private static readonly string[] NearEdges = { "zero", "one", "limit-1", "limit", "limit+1", "twice" };

    /// <summary>A value up to max drawn around a limit the workload declares (a batch size, a buffer, a
    /// threshold): half the time uniform, else one of the limit's edges, where bugs gather and uniform
    /// draws seldom land: 0, 1, limit - 1, limit, limit + 1 or twice it (each kept within max). Named
    /// decisions ("&lt;name&gt;.near", then name), as the Zig SDK's random_near.</summary>
    public static ulong RandomNear(string name, ulong limit, ulong max)
    {
        if (max == 0) throw new ArgumentOutOfRangeException(nameof(max), "max must be positive");
        if (RandomBelowNamed(name + ".near", 2) == 0) return RandomBelowNamed(name, max == ulong.MaxValue ? max : max + 1);
        ulong value = Decide(name, NearEdges) switch
        {
            0 => 0,
            1 => 1,
            2 => limit == 0 ? 0 : limit - 1,
            3 => limit,
            4 => limit == ulong.MaxValue ? limit : limit + 1,
            _ => limit > ulong.MaxValue / 2 ? ulong.MaxValue : limit * 2,
        };
        return Math.Min(value, max);
    }

    // Swarm testing over a workload's operations: the Zig SDK's swarm_index (sdk/zig/
    // determinismo.zig), the same table from the same seed (FNV-1a and SplitMix64), so drivers in
    // any language agree on a timeline's mix.
    private const string SwarmSeedPath = "/opt/determinismo/swarm-seed";
    private static ulong? swarmSeed;
    private static readonly Dictionary<string, (ulong Stretch, ulong Answer)> swarmRuns = new();
    private static readonly object swarmLock = new();

    private static ulong SwarmMix(ulong value)
    {
        unchecked
        {
            ulong z = value + 0x9e3779b97f4a7c15UL;
            z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
            z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>The swarm table's draws: FNV-1a of the name, mixed with the seed, stretch and what by SplitMix64, the same in every SDK.</summary>
    public static ulong SwarmHash(ulong seed, string name, ulong stretch, ulong what)
    {
        unchecked
        {
            ulong nameHash = 0xcbf29ce484222325UL;
            foreach (byte b in Encoding.UTF8.GetBytes(name)) nameHash = (nameHash ^ b) * 0x100000001b3UL;
            return SwarmMix(SwarmMix(SwarmMix(seed ^ nameHash) ^ stretch) ^ what);
        }
    }

    /// <summary>An index below count (64 at most) by swarm testing: among the options this timeline keeps for the name,
    /// weighted and repeated in runs, the table changing with stretches of virtual time. Plain uniform outside
    /// determinismo, before the drivers, or with --no-swarm.</summary>
    public static ulong SwarmIndex(string name, ulong count)
    {
        if (count == 0 || count > 64) throw new ArgumentOutOfRangeException(nameof(count), "1 to 64 options");
        string label = "swarm." + name;
        lock (swarmLock)
        {
            if (swarmSeed is null)
            {
                try { swarmSeed = ulong.Parse(File.ReadAllText(SwarmSeedPath).Trim(), CultureInfo.InvariantCulture); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException) { }
            }
            if (swarmSeed is not ulong seed) return RandomBelowNamed(label, count);
            // Stopwatch's timestamp is CLOCK_MONOTONIC on Linux, as the other SDKs read it.
            ulong nowMs = (ulong)System.Diagnostics.Stopwatch.GetTimestamp() / (ulong)(System.Diagnostics.Stopwatch.Frequency / 1000);
            ulong stretch = nowMs / (10_000 + SwarmHash(seed, name, 0, 1) % 110_001);
            ulong eighths = 1 + SwarmHash(seed, name, stretch, 2) % 7;
            ulong mean = new ulong[] { 1, 4, 16, 64 }[SwarmHash(seed, name, stretch, 3) % 4];
            var weights = new ulong[count];
            ulong kept = 0;
            for (ulong i = 0; i < count; i++)
            {
                ulong drawn = SwarmHash(seed, name, stretch, 16 + i);
                if (drawn % 8 >= eighths) continue;
                weights[i] = 1UL << (int)((drawn >> 32) % 8);
                kept |= 1UL << (int)i;
            }
            if (kept == 0)
            {
                ulong i = SwarmHash(seed, name, stretch, 4) % count;
                weights[i] = 1;
                kept = 1UL << (int)i;
            }
            ulong total = 0;
            foreach (ulong weight in weights) total += weight;
            bool ran = swarmRuns.TryGetValue(name, out var run);
            if (ran && run.Stretch == stretch && mean > 1 && RandomBelowNamed(label + " run", mean) != 0) return run.Answer;
            ulong pick = RandomBelowNamed(label, total);
            ulong answer = 0;
            for (ulong i = 0; i < count; i++)
            {
                if (pick < weights[i]) { answer = i; break; }
                pick -= weights[i];
            }
            if (!ran || run.Stretch != stretch)
            {
                Lifecycle.SendEvent("swarm", new JsonObject { ["name"] = name, ["stretch"] = stretch, ["kept"] = kept, ["mean"] = mean });
            }
            swarmRuns[name] = (stretch, answer);
            return answer;
        }
    }

    /// <summary>One of the items by swarm testing (SwarmIndex), where RandomChoice drew one uniformly.</summary>
    public static T SwarmChoice<T>(string name, IReadOnlyList<T> items) => items[(int)SwarmIndex(name, (ulong)items.Count)];

    /// <summary>A System.Random whose every draw is a platform decision (Antithesis's AntithesisRandom).</summary>
    public static System.Random Rng() => new AntithesisRandom();

    /// <summary>A fast generator seeded from one platform decision: different in every branch.</summary>
    public static System.Random Prng() => new System.Random((int)(Platform.NextUInt64() & 0x7fffffff));

    private sealed class Point
    {
        public System.Random? Generator;
        public long UntilTicks;
    }

    private static readonly ConcurrentDictionary<string, Point> Buggified = new();
    private static readonly long BuggifyPeriodTicks = 2 * TimeSpan.TicksPerSecond;

    /// <summary>
    /// A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
    /// of two seconds (virtual time) in four, a named decision ("buggify &lt;name&gt;"); while
    /// active, true one evaluation in four. Outside determinismo, always false.
    /// </summary>
    public static bool Buggify(string name)
    {
        var generator = BuggifyGenerator(name);
        if (generator == null) return false;
        lock (generator) return generator.Next(4) == 0;
    }

    /// <summary>At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active.</summary>
    public static void BuggifyPause(string name)
    {
        var generator = BuggifyGenerator(name);
        if (generator == null) return;
        int ms;
        lock (generator)
        {
            if (generator.Next(32) != 0) return;
            ms = generator.Next(10);
        }
        Thread.Sleep(ms);
    }

    private static System.Random? BuggifyGenerator(string name)
    {
        if (!Platform.Inside) return null;
        var now = DateTime.UtcNow.Ticks; // Virtual time inside determinismo.
        var point = Buggified.AddOrUpdate(name,
            key => Fresh(key, now),
            (key, current) => now < current.UntilTicks ? current : Fresh(key, now));
        return point.Generator;
    }

    private static Point Fresh(string name, long now)
    {
        var active = RandomBelowNamed("buggify " + name, 4) == 0;
        return new Point
        {
            Generator = active ? new System.Random((int)(Platform.NextUInt64() & 0x7fffffff)) : null,
            UntilTicks = now + BuggifyPeriodTicks,
        };
    }
}

/// <summary>A System.Random whose every draw is a platform decision (Antithesis's name).</summary>
public class AntithesisRandom : System.Random
{
    public override int Next() => (int)(Platform.NextUInt64() >> 33);

    public override int Next(int maxValue)
    {
        if (maxValue < 0) throw new ArgumentOutOfRangeException(nameof(maxValue));
        return maxValue == 0 ? 0 : (int)Random.RandomBelow((ulong)maxValue);
    }

    public override int Next(int minValue, int maxValue)
    {
        if (minValue > maxValue) throw new ArgumentOutOfRangeException(nameof(minValue));
        return maxValue == minValue ? minValue : minValue + (int)Random.RandomBelow((ulong)((long)maxValue - minValue));
    }

    public override long NextInt64() => (long)(Platform.NextUInt64() >> 1);

    public override double NextDouble() => Random.RandomFloat();

    protected override double Sample() => Random.RandomFloat();

    public override void NextBytes(byte[] buffer) => Platform.Bytes(buffer);

    public override void NextBytes(Span<byte> buffer) => Platform.Bytes(buffer);
}
