// SPDX-License-Identifier: MIT
// determinismo-dotnet-instrument [--include <path prefix>]... <assembly.dll>...: coverage and
// thread pausing for .NET (the C SDK's trace-pc-guard callbacks, the JVM's coverage agent). Each
// assembly, built with sdk/dotnet/Determinismo.cs compiled in and its portable PDB beside it, is
// rewritten in place: every visible sequence point (a statement; a line can hold several, as
// `if (x == 0) x++;` does) of its methods, the SDK's own left out, first calls
// Determinismo.Coverage.Point(hits, id, key, "line <file>:<n>"), which reports the line the first
// time the process runs it and is where thread pausing pauses (Determinismo.cs). `--include`
// keeps the points whose source file starts with one of the prefixes (the race's runner is no
// hint; the node's coverage set narrows them again at run). Stack-neutral at a sequence point,
// where the stack is empty; the original instruction becomes the call's first one, so every
// branch and exception handler aimed at the statement runs the call first.
//
//   dotnet publish -c Release -o out && determinismo-dotnet-instrument out/App.dll
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

var includes = new List<string>();
var assemblies = new List<string>();
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--include" && i + 1 < args.Length) includes.Add(args[++i]);
    else assemblies.Add(args[i]);
}
if (assemblies.Count == 0)
{
    Console.Error.WriteLine("usage: determinismo-dotnet-instrument [--include <path prefix>]... <assembly.dll>...");
    return 2;
}
foreach (var path in assemblies)
{
    var points = Instrument(path, includes);
    if (points < 0) return 1;
    Console.WriteLine($"{path}: {points} points");
}
return 0;

static int Instrument(string path, List<string> includes)
{
    using var module = ModuleDefinition.ReadModule(path, new ReaderParameters { ReadSymbols = true, InMemory = true });
    var coverage = module.GetType("Determinismo.Coverage");
    var point = coverage?.Methods.FirstOrDefault(method => method.Name == "Point");
    if (point is null)
    {
        Console.Error.WriteLine($"{path}: no Determinismo.Coverage.Point: compile sdk/dotnet/Determinismo.cs into it");
        return -1;
    }
    if (module.GetType("Determinismo.<CoverageHits>") is not null)
    {
        Console.Error.WriteLine($"{path}: instrumented already");
        return -1;
    }
    // The assembly's hits, one per point (Coverage.Point's states), sized once they are counted.
    var holder = new TypeDefinition("Determinismo", "<CoverageHits>",
        TypeAttributes.Class | TypeAttributes.Abstract | TypeAttributes.Sealed | TypeAttributes.NotPublic,
        module.TypeSystem.Object);
    var hits = new FieldDefinition("Hits", FieldAttributes.Static | FieldAttributes.Assembly | FieldAttributes.InitOnly,
        new ArrayType(module.TypeSystem.Int32));
    holder.Fields.Add(hits);
    var count = 0;
    foreach (var type in module.GetTypes().ToList())
    {
        if (Outermost(type).Namespace == "Determinismo") continue; // The SDK's.
        foreach (var method in type.Methods)
        {
            if (!method.HasBody || !method.DebugInformation.HasSequencePoints) continue;
            var body = method.Body;
            var byOffset = body.Instructions.ToDictionary(instruction => instruction.Offset);
            var chosen = new List<(Instruction Instruction, string Name, long Key)>();
            foreach (var sequence in method.DebugInformation.SequencePoints)
            {
                if (sequence.IsHidden || !byOffset.TryGetValue(sequence.Offset, out var at)) continue;
                var file = sequence.Document.Url;
                if (includes.Count > 0 && !includes.Any(prefix => file.StartsWith(prefix, StringComparison.Ordinal))) continue;
                var name = $"line {file}:{sequence.StartLine}";
                chosen.Add((at, name, (long)Fnv64($"{name}:{sequence.StartColumn}")));
            }
            if (chosen.Count == 0) continue;
            body.SimplifyMacros();
            var il = body.GetILProcessor();
            foreach (var (at, name, key) in chosen)
            {
                var original = il.Create(OpCodes.Nop);
                original.OpCode = at.OpCode;
                original.Operand = at.Operand;
                at.OpCode = OpCodes.Ldsfld;
                at.Operand = hits;
                var cursor = at;
                foreach (var next in new[]
                {
                    il.Create(OpCodes.Ldc_I4, count),
                    il.Create(OpCodes.Ldc_I8, key),
                    il.Create(OpCodes.Ldstr, name),
                    il.Create(OpCodes.Call, point),
                    original,
                })
                {
                    il.InsertAfter(cursor, next);
                    cursor = next;
                }
                count += 1;
            }
            body.OptimizeMacros();
        }
    }
    var initializer = new MethodDefinition(".cctor",
        MethodAttributes.Private | MethodAttributes.HideBySig | MethodAttributes.SpecialName |
        MethodAttributes.RTSpecialName | MethodAttributes.Static, module.TypeSystem.Void);
    var init = initializer.Body.GetILProcessor();
    init.Emit(OpCodes.Ldc_I4, count);
    init.Emit(OpCodes.Newarr, module.TypeSystem.Int32);
    init.Emit(OpCodes.Stsfld, hits);
    init.Emit(OpCodes.Ret);
    holder.Methods.Add(initializer);
    module.Types.Add(holder);
    module.Write(path, new WriterParameters { WriteSymbols = true });
    return count;
}

static TypeDefinition Outermost(TypeDefinition type) => type.DeclaringType is null ? type : Outermost(type.DeclaringType);

static ulong Fnv64(string text)
{
    var value = 14695981039346656037UL;
    foreach (var character in text)
    {
        value ^= character;
        value *= 1099511628211UL;
    }
    return value;
}
