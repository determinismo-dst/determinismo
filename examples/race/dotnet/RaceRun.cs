// SPDX-License-Identifier: MIT
// One run of the race of examples/race, in C#: 64 threads, each incrementing the counter if it is
// still zero; an exception when all 64 did. The only file instrumented (Dockerfile.dotnet's
// --include): its statements are where thread pausing pauses the threads.
static class RaceRun
{
    public const int Threads = 64;
    static int counter;

    static void Update()
    {
        if (counter == 0) counter++;
    }

    public static int Run()
    {
        counter = 0;
        var threads = new Thread[Threads];
        for (var i = 0; i < Threads; i++) (threads[i] = new Thread(Update)).Start();
        foreach (var thread in threads) thread.Join();
        if (counter == Threads) throw new InvalidOperationException($"all {Threads} threads incremented the counter");
        return counter;
    }
}
