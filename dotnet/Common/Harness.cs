// nostrLibBench .NET harness: the code shared by every client binary.
//
// Each client library is its own project (Clients/<Lib>/) compiled with this file. Its binary
// runs in two modes, both driven by the orchestrator (Bench/):
//   --list-json                     print the clients of this binary with their metadata
//   --child <client> --workload ... run one client on one workload (fresh process) and write
//                                   one result row as JSON to --result <file>
// A run follows HARNESS.md "A run": untimed setup (new client + connect), timed subscription
// until EOSE and the last accepted event, untimed teardown.

using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LibBench;

/// <summary>One client entry: a library driven through one of its subscription APIs.</summary>
public abstract class BenchClient
{
    public abstract string Id { get; }
    public abstract string Library { get; }
    /// <summary>NuGet package id whose resolved version (packages.lock.json) is the row's version.</summary>
    public abstract string Package { get; }
    public abstract string License { get; }
    public abstract string Api { get; }
    public abstract string Websocket { get; }
    /// <summary>secp256k1 implementation; "{Pkg.Id}" is replaced with that package's resolved version.</summary>
    public abstract string Crypto { get; }
    public abstract string Verify { get; }
    public virtual string Notes => "";
    public virtual bool Variant => false;

    /// <summary>Untimed: create a new client instance and connect it (when the API allows).</summary>
    public abstract Task SetupAsync(Uri url, RunCtx ctx);

    /// <summary>
    /// Timed: call ctx.Start() right before the library's subscription call, then report each
    /// delivered event with ctx.Event(id) (after the library's own verify for `explicit` rows)
    /// and the EOSE with ctx.Eose(). The returned task may finish at EOSE or keep running; the
    /// driver decides when the run is over and then calls TeardownAsync.
    /// </summary>
    public abstract Task RunAsync(RunCtx ctx);

    /// <summary>Untimed: close the subscription and the client.</summary>
    public abstract Task TeardownAsync();
}

/// <summary>Per-run bookkeeping: the accepted set, the EOSE and the timestamps.</summary>
public sealed class RunCtx
{
    readonly object _lock = new();
    readonly HashSet<string> _ambiguous, _expired;
    readonly int _complete; // valid + every ambiguous: nothing more can arrive
    readonly TaskCompletionSource _done = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public readonly int Events, Limit;
    public long T0, EoseTicks, LastEventTicks, LastActivityTicks;
    public TimeSpan Cpu0, CpuEose, CpuDone, CpuLastAfterEose;
    public long Alloc0; // GC.GetTotalAllocatedBytes(true) right before t0
    public bool CpuDoneSet;
    public int Accepted, Rejected, AmbiguousAccepted, ExpiredAccepted;
    public bool EoseSeen, Started;
    public ulong X0, X1, X2, X3;
    public Exception? Failure;
    public bool EventAfterEose;

    public RunCtx(Workload w)
    {
        _ambiguous = new HashSet<string>(w.AmbiguousIds, StringComparer.Ordinal);
        _expired = new HashSet<string>(w.ExpiredIds, StringComparer.Ordinal);
        _complete = w.ValidEvents + w.AmbiguousIds.Count;
        Events = w.Events;
        Limit = w.Events;
    }

    public Task Done => _done.Task;

    public static TimeSpan CpuNow() => Environment.CpuUsage.TotalTime;

    /// <summary>t0: read right before the library's subscription call.</summary>
    public void Start()
    {
        // Precise: suspends the runtime for a moment to add up every thread's allocation
        // context, so it is read before the CPU time and t0.
        Alloc0 = GC.GetTotalAllocatedBytes(true);
        Cpu0 = CpuNow();
        T0 = Stopwatch.GetTimestamp();
        LastActivityTicks = T0;
        Started = true;
    }

    /// <summary>The library delivered an event (already verified) with this id hex.</summary>
    public void Event(string id)
    {
        long now = Stopwatch.GetTimestamp();
        lock (_lock)
        {
            Accepted++;
            XorHex(id);
            LastEventTicks = now;
            LastActivityTicks = now;
            if (_ambiguous.Contains(id)) AmbiguousAccepted++;
            if (_expired.Contains(id)) ExpiredAccepted++;
            if (EoseSeen)
            {
                // CPU at the latest event after EOSE (as the JVM sink): if the set never
                // completes, the run's CPU ends here, not at the idle-timeout detection 1 s later.
                EventAfterEose = true;
                CpuLastAfterEose = CpuNow();
            }
            if (EoseSeen && Accepted >= _complete) Finish();
        }
    }

    /// <summary>The harness dropped an event its explicit verify rejected.</summary>
    public void Reject()
    {
        long now = Stopwatch.GetTimestamp();
        lock (_lock) { Rejected++; LastActivityTicks = now; }
    }

    public void Eose()
    {
        long now = Stopwatch.GetTimestamp();
        var cpu = CpuNow();
        lock (_lock)
        {
            if (EoseSeen) return;
            EoseSeen = true;
            EoseTicks = now;
            CpuEose = cpu;
            if (now > LastActivityTicks) LastActivityTicks = now;
            if (Accepted >= _complete) Finish();
        }
    }

    public void Fail(Exception e)
    {
        lock (_lock) { Failure ??= e; }
        _done.TrySetResult();
    }

    void Finish()
    {
        if (!CpuDoneSet) { CpuDone = CpuNow(); CpuDoneSet = true; }
        _done.TrySetResult();
    }

    void XorHex(string id)
    {
        if (id.Length != 64) throw new FormatException($"event id is not 64 hex chars: '{id}'");
        X0 ^= ulong.Parse(id.AsSpan(0, 16), NumberStyles.HexNumber);
        X1 ^= ulong.Parse(id.AsSpan(16, 16), NumberStyles.HexNumber);
        X2 ^= ulong.Parse(id.AsSpan(32, 16), NumberStyles.HexNumber);
        X3 ^= ulong.Parse(id.AsSpan(48, 16), NumberStyles.HexNumber);
    }

    public string XorHexString() => $"{X0:x16}{X1:x16}{X2:x16}{X3:x16}";

    public static string HexOf(ReadOnlySpan<byte> b) => Convert.ToHexStringLower(b);
}

public sealed class Workload
{
    public string Name = "";
    public int Events, ValidEvents;
    public long Bytes;
    public string ValidIdXor = "";
    public List<string> AmbiguousIds = new(), ExpiredIds = new();

    public static (string fingerprint, List<Workload> workloads) LoadManifest(string corpusDir)
    {
        var doc = JsonNode.Parse(File.ReadAllText(Path.Combine(corpusDir, "manifest.json")))!;
        var list = new List<Workload>();
        foreach (var w in doc["workloads"]!.AsArray())
        {
            list.Add(new Workload
            {
                Name = (string)w!["name"]!,
                Events = (int)w["events"]!,
                Bytes = (long)w["bytes"]!,
                ValidEvents = (int)w["valid_events"]!,
                ValidIdXor = (string)w["valid_id_xor"]!,
                AmbiguousIds = w["ambiguous_ids"]?.AsArray().Select(x => (string)x!).ToList() ?? new(),
                ExpiredIds = w["expired_ids"]?.AsArray().Select(x => (string)x!).ToList() ?? new(),
            });
        }
        return ((string?)doc["fingerprint"] ?? "", list);
    }

    /// <summary>The expected XOR for a given choice on the ambiguous and expired events.</summary>
    public string ExpectedXor(bool ambiguousAccepted, bool expiredAccepted)
    {
        var x = Convert.FromHexString(ValidIdXor);
        void Xor(string id) { var b = Convert.FromHexString(id); for (int i = 0; i < 32; i++) x[i] ^= b[i]; }
        if (ambiguousAccepted) foreach (var id in AmbiguousIds) Xor(id);
        if (!expiredAccepted) foreach (var id in ExpiredIds) Xor(id);
        return Convert.ToHexStringLower(x);
    }
}

public static class Versions
{
    static Dictionary<string, string>? _resolved;

    /// <summary>Resolved package versions from this project's embedded packages.lock.json.</summary>
    public static Dictionary<string, string> Resolved
    {
        get
        {
            if (_resolved != null) return _resolved;
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using var s = Assembly.GetEntryAssembly()!.GetManifestResourceStream("packages.lock.json");
            if (s != null)
            {
                var doc = JsonNode.Parse(s)!;
                foreach (var fw in doc["dependencies"]!.AsObject())
                    foreach (var pkg in fw.Value!.AsObject())
                        if (pkg.Value?["resolved"] is JsonNode r) map[pkg.Key] = (string)r!;
            }
            return _resolved = map;
        }
    }

    public static string Of(string package) => Resolved.TryGetValue(package, out var v) ? v : "?";

    /// <summary>Replace every {Package.Id} in s with the package's resolved version.</summary>
    public static string Expand(string s)
    {
        return System.Text.RegularExpressions.Regex.Replace(s, @"\{([A-Za-z0-9_.\-]+)\}", m => Of(m.Groups[1].Value));
    }
}

public static class ChildMain
{
    static readonly JsonSerializerOptions Json = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static JsonObject Meta(BenchClient c) => new()
    {
        ["client"] = c.Id,
        ["library"] = c.Library,
        ["version"] = Versions.Of(c.Package),
        ["license"] = c.License,
        ["api"] = c.Api,
        ["websocket"] = Versions.Expand(c.Websocket),
        ["crypto"] = Versions.Expand(c.Crypto),
        ["verify"] = c.Verify,
        ["notes"] = Versions.Expand(c.Notes),
        ["variant"] = c.Variant,
    };

    public static async Task<int> Run(string[] args, IReadOnlyList<BenchClient> clients)
    {
        if (args.Contains("--list-json"))
        {
            var arr = new JsonArray();
            foreach (var c in clients) arr.Add(Meta(c));
            Console.Out.Write(arr.ToJsonString(Json));
            return 0;
        }
        string Arg(string name, string? def = null)
        {
            int i = Array.IndexOf(args, name);
            if (i >= 0 && i + 1 < args.Length) return args[i + 1];
            return def ?? throw new ArgumentException($"missing {name}");
        }
        var id = Arg("--child");
        var client = clients.FirstOrDefault(c => c.Id == id) ?? throw new ArgumentException($"unknown client {id}");
        var corpus = Arg("--corpus");
        var (_, workloads) = Workload.LoadManifest(corpus);
        var w = workloads.First(x => x.Name == Arg("--workload"));
        var url = new Uri(Arg("--relay").TrimEnd('/') + "/" + w.Name);
        var s = new Settings
        {
            WarmupRuns = int.Parse(Arg("--warmup-runs")),
            MinRuns = int.Parse(Arg("--min-runs")),
            MinTimeMs = int.Parse(Arg("--min-time-ms")),
            MaxRuns = int.Parse(Arg("--max-runs")),
            TimeoutMs = int.Parse(Arg("--timeout-ms")),
        };
        var resultFile = Arg("--result");
        JsonObject row;
        try
        {
            row = await Driver.Measure(client, w, url, s);
        }
        catch (Exception e)
        {
            row = Driver.ErrorRow(client, w, e.GetType().Name + ": " + e.Message);
        }
        File.WriteAllText(resultFile, row.ToJsonString(Json));
        Console.Out.Flush();
        // Libraries may leave foreground threads or hung sockets behind: leave hard.
        Environment.Exit(0);
        return 0;
    }
}

public sealed class Settings
{
    public int WarmupRuns, MinRuns, MinTimeMs, MaxRuns, TimeoutMs;
}

public static class Driver
{
    static readonly double TicksPerMs = Stopwatch.Frequency / 1000.0;

    sealed class RunResult
    {
        public double Ms, CpuMs;
        public long AllocBytes;
        public int Accepted, Ambiguous, Expired;
        public string Xor = "";
    }

    /// <summary>VmRSS after the first setup of this process, after a full GC (base_rss_mb).</summary>
    static double? _baseRssMb;

    static async Task<RunResult> OneRun(BenchClient client, Workload w, Uri url, Settings s)
    {
        var ctx = new RunCtx(w);
        var timeout = TimeSpan.FromMilliseconds(s.TimeoutMs);
        var setup = client.SetupAsync(url, ctx);
        if (await Task.WhenAny(setup, Task.Delay(timeout)) != setup)
            throw new TimeoutException($"setup (connect) did not finish within {s.TimeoutMs} ms");
        await setup;
        if (_baseRssMb == null)
        {
            GC.Collect();
            _baseRssMb = CurrentRssMb();
        }

        Task run;
        try { run = client.RunAsync(ctx); }
        catch (Exception e) { run = Task.FromException(e); }
        _ = run.ContinueWith(t => { if (t.IsFaulted) ctx.Fail(t.Exception!.GetBaseException()); },
            TaskContinuationOptions.ExecuteSynchronously);

        long idle = Stopwatch.Frequency; // 1 s without events after EOSE: the run is over
        while (true)
        {
            await Task.WhenAny(ctx.Done, Task.Delay(20));
            if (ctx.Failure != null) break;
            if (ctx.Done.IsCompleted) break;
            long now = Stopwatch.GetTimestamp();
            if (!ctx.Started) { if (run.IsCompleted) break; continue; }
            if (ctx.EoseSeen && now - Volatile.Read(ref ctx.LastActivityTicks) >= idle) break;
            if (now - ctx.T0 > timeout.TotalMilliseconds * TicksPerMs) break;
        }
        long alloc1 = GC.GetTotalAllocatedBytes(true);
        var failure = ctx.Failure;
        bool eose;
        RunResult r;
        lock (ctx)
        {
            eose = ctx.EoseSeen;
            long tEnd = Math.Max(ctx.EoseTicks, ctx.LastEventTicks);
            TimeSpan cpuEnd = ctx.CpuDoneSet ? ctx.CpuDone : ctx.EventAfterEose ? ctx.CpuLastAfterEose : ctx.CpuEose;
            r = new RunResult
            {
                Ms = (tEnd - ctx.T0) / TicksPerMs,
                CpuMs = (cpuEnd - ctx.Cpu0).TotalMilliseconds,
                AllocBytes = alloc1 - ctx.Alloc0,
                Accepted = ctx.Accepted,
                Ambiguous = ctx.AmbiguousAccepted,
                Expired = ctx.ExpiredAccepted,
                Xor = ctx.XorHexString(),
            };
        }
        try
        {
            var td = client.TeardownAsync();
            await Task.WhenAny(td, Task.Delay(5000));
        }
        catch { /* teardown errors do not fail a run */ }
        if (failure != null) throw new Exception($"run failed: {failure.GetType().Name}: {failure.Message}", failure);
        if (!ctx.Started) throw new Exception("the client never started the subscription");
        if (!eose) throw new TimeoutException($"no EOSE within {s.TimeoutMs} ms (accepted {r.Accepted} events)");
        return r;
    }

    public static async Task<JsonObject> Measure(BenchClient client, Workload w, Uri url, Settings s)
    {
        var warm = new List<RunResult>();
        var runs = new List<RunResult>();
        RunResult? first = null;
        string? error = null;
        try
        {
            for (int i = 0; i < s.WarmupRuns; i++)
            {
                var r = await OneRun(client, w, url, s);
                warm.Add(r);
                first ??= r;
                Check(first, r);
                Console.Error.WriteLine($"  {client.Id} {w.Name} warmup {i + 1}: {r.Ms:F1} ms, cpu {r.CpuMs:F1} ms, accepted {r.Accepted}");
            }
            var sw = Stopwatch.StartNew();
            while (runs.Count < s.MaxRuns && (runs.Count < s.MinRuns || sw.ElapsedMilliseconds < s.MinTimeMs))
            {
                var r = await OneRun(client, w, url, s);
                first ??= r;
                Check(first, r);
                runs.Add(r);
                Console.Error.WriteLine($"  {client.Id} {w.Name} run {runs.Count}: {r.Ms:F1} ms, cpu {r.CpuMs:F1} ms, accepted {r.Accepted}");
            }
        }
        catch (Exception e)
        {
            error = e.GetType().Name + ": " + e.Message;
            if (e.InnerException != null && !error.Contains(e.InnerException.Message)) error += " (" + e.InnerException.Message + ")";
        }

        if (error != null || first == null)
        {
            var row = ErrorRow(client, w, error ?? "no runs");
            if (first != null) { FillAccepted(row, w, first); row["accepted_ok"] = false; }
            row["warmup_runs"] = warm.Count;
            row["runs"] = runs.Count;
            row["base_rss_mb"] = _baseRssMb is double baseMb ? R(baseMb) : null;
            return row;
        }

        var ms = runs.Select(r => r.Ms).ToList();
        var sorted = ms.OrderBy(x => x).ToList();
        double median = Median(sorted);
        double p90 = sorted[Math.Max(0, (int)Math.Ceiling(0.9 * sorted.Count) - 1)];
        var row2 = BaseRow(client, w);
        FillAccepted(row2, w, first);
        row2["errors"] = 0;
        row2["error"] = null;
        row2["warmup_runs"] = warm.Count;
        row2["runs"] = runs.Count;
        row2["first_run_ms"] = warm.Count > 0 ? R(warm[0].Ms) : null;
        row2["median_ms"] = R(median);
        row2["min_ms"] = R(sorted[0]);
        row2["p90_ms"] = R(p90);
        var arr = new JsonArray();
        foreach (var m in ms) arr.Add(R(m));
        row2["run_ms"] = arr;
        row2["events_per_s"] = R(w.Events / (median / 1000.0));
        row2["us_per_event"] = Math.Round(median * 1000.0 / w.Events, 2);
        row2["cpu_ms"] = R(Median(runs.Select(r => r.CpuMs).OrderBy(x => x).ToList()));
        row2["peak_rss_mb"] = R(PeakRssMb());
        row2["base_rss_mb"] = _baseRssMb is double baseMb2 ? R(baseMb2) : null;
        // alloc of the run whose ms is median_ms; with an even number of runs (median_ms is
        // then the mean of the two middle runs) the mean of those two runs' values.
        var byMs = runs.OrderBy(r => r.Ms).ToList();
        int n = byMs.Count;
        row2["alloc_bytes"] = n % 2 == 1 ? byMs[n / 2].AllocBytes : (byMs[n / 2 - 1].AllocBytes + byMs[n / 2].AllocBytes) / 2;
        return row2;
    }

    static void Check(RunResult first, RunResult r)
    {
        if (r.Accepted != first.Accepted || r.Xor != first.Xor)
            throw new Exception($"run delivered a different set than the first run (accepted {r.Accepted} vs {first.Accepted}, xor {r.Xor} vs {first.Xor})");
    }

    static double Median(List<double> sorted)
    {
        int n = sorted.Count;
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
    }

    static double R(double v) => Math.Round(v, 1);

    static void FillAccepted(JsonObject row, Workload w, RunResult first)
    {
        row["accepted"] = first.Accepted;
        row["accepted_xor"] = first.Xor;
        row["ambiguous_accepted"] = first.Ambiguous;
        row["expired_accepted"] = first.Expired;
        bool expiredOk = first.Expired == 0 || first.Expired == w.ExpiredIds.Count;
        bool countOk = first.Accepted == w.ValidEvents - w.ExpiredIds.Count + first.Expired + first.Ambiguous;
        bool xorOk = first.Xor == w.ExpectedXor(first.Ambiguous > 0, first.Expired > 0 || w.ExpiredIds.Count == 0);
        // (every ambiguous id is in one workload at most once: with one ambiguous event per
        //  workload, "accepted some" == "accepted all")
        row["accepted_ok"] = expiredOk && countOk && xorOk && first.Ambiguous <= w.AmbiguousIds.Count;
    }

    static JsonObject BaseRow(BenchClient c, Workload w)
    {
        var row = ChildMain.Meta(c);
        row["workload"] = w.Name;
        row["events"] = w.Events;
        row["bytes"] = w.Bytes;
        return row;
    }

    public static JsonObject ErrorRow(BenchClient c, Workload w, string error)
    {
        var row = BaseRow(c, w);
        row["accepted"] = null;
        row["accepted_xor"] = null;
        row["ambiguous_accepted"] = null;
        row["expired_accepted"] = null;
        row["accepted_ok"] = false;
        row["errors"] = 1;
        row["error"] = error;
        row["warmup_runs"] = 0;
        row["runs"] = 0;
        foreach (var k in new[] { "first_run_ms", "median_ms", "min_ms", "p90_ms", "run_ms", "events_per_s", "us_per_event", "cpu_ms" })
            row[k] = null;
        row["peak_rss_mb"] = Math.Round(PeakRssMb(), 1);
        row["base_rss_mb"] = null;
        row["alloc_bytes"] = null;
        return row;
    }

    static double? CurrentRssMb()
    {
        try
        {
            foreach (var line in File.ReadLines("/proc/self/status"))
                if (line.StartsWith("VmRSS:"))
                    return long.Parse(line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1]) / 1024.0;
        }
        catch { }
        return null;
    }

    public static double PeakRssMb()
    {
        try
        {
            foreach (var line in File.ReadLines("/proc/self/status"))
                if (line.StartsWith("VmHWM:"))
                    return long.Parse(line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1]) / 1024.0;
        }
        catch { }
        return 0;
    }
}
