// nostrLibBench .NET harness: the orchestrator.
//
// Parses the HARNESS.md flags, asks every client binary (one per library project, built into
// out/<Project>/) for its clients, then runs each client on each workload in a fresh process,
// one after another, and writes results/dotnet.json.

using System.Diagnostics;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

static class Program
{
    // Library projects, in the order their rows are written.
    static readonly string[] Projects =
    [
        "NostrClient", "NNostr", "NostrNet", "NostrSdk", "Blockcore", "NostraFs", "NostrSharpBench",
    ];

    static async Task<int> Main(string[] args)
    {
        string relay = "ws://127.0.0.1:7777", corpus = ".corpus", outFile = "results/dotnet.json";
        string? workloadsArg = null, clientsArg = null;
        int warmup = 2, minRuns = 5, minTime = 10000, maxRuns = 30, timeout = 300000;
        bool list = false;
        for (int i = 0; i < args.Length; i++)
        {
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value");
            switch (args[i])
            {
                case "--relay": relay = Next(); break;
                case "--corpus": corpus = Next(); break;
                case "--out": outFile = Next(); break;
                case "--workloads": workloadsArg = Next(); break;
                case "--clients": clientsArg = Next(); break;
                case "--warmup-runs": warmup = int.Parse(Next()); break;
                case "--min-runs": minRuns = int.Parse(Next()); break;
                case "--min-time-ms": minTime = int.Parse(Next()); break;
                case "--max-runs": maxRuns = int.Parse(Next()); break;
                case "--timeout-ms": timeout = int.Parse(Next()); break;
                case "--quick": warmup = 1; minRuns = 2; minTime = 0; break;
                case "--list": list = true; break;
                default: Console.Error.WriteLine($"unknown flag {args[i]}"); return 2;
            }
        }

        string outDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        var binaries = new List<(string bin, JsonObject meta)>();
        foreach (var p in Projects)
        {
            var bin = Path.Combine(outDir, p, p);
            if (!File.Exists(bin)) { Console.Error.WriteLine($"missing client binary {bin}"); return 1; }
            var (code, stdout) = await RunCapture(bin, ["--list-json"], 120_000);
            if (code != 0) { Console.Error.WriteLine($"{bin} --list-json failed ({code})"); return 1; }
            foreach (var m in JsonNode.Parse(stdout)!.AsArray()) binaries.Add((bin, m!.AsObject()));
        }
        if (list)
        {
            foreach (var (_, m) in binaries) Console.WriteLine((string)m["client"]!);
            return 0;
        }

        var manifestDoc = JsonNode.Parse(File.ReadAllText(Path.Combine(corpus, "manifest.json")))!;
        var allWorkloads = manifestDoc["workloads"]!.AsArray().Select(w => (string)w!["name"]!).ToList();
        var workloads = workloadsArg == null ? new List<string> { "all" }
            : workloadsArg.Split(',', StringSplitOptions.RemoveEmptyEntries).ToList();
        foreach (var w in workloads)
            if (!allWorkloads.Contains(w)) { Console.Error.WriteLine($"unknown workload {w}"); return 2; }
        var selected = binaries;
        if (clientsArg != null)
        {
            var want = clientsArg.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
            foreach (var c in want)
                if (!binaries.Any(b => (string)b.meta["client"]! == c)) { Console.Error.WriteLine($"unknown client {c}"); return 2; }
            selected = binaries.Where(b => want.Contains((string)b.meta["client"]!)).ToList();
        }

        var results = new JsonArray();
        var tmp = Path.Combine(Path.GetTempPath(), $"libbench-dotnet-{Environment.ProcessId}");
        Directory.CreateDirectory(tmp);
        foreach (var w in workloads)
        {
            foreach (var (bin, meta) in selected)
            {
                var id = (string)meta["client"]!;
                Console.Error.WriteLine($"== {id} / {w}");
                var resultFile = Path.Combine(tmp, $"{id}-{w}.json");
                File.Delete(resultFile);
                string[] childArgs =
                [
                    "--child", id, "--workload", w, "--relay", relay, "--corpus", Path.GetFullPath(corpus),
                    "--warmup-runs", warmup.ToString(), "--min-runs", minRuns.ToString(),
                    "--min-time-ms", minTime.ToString(), "--max-runs", maxRuns.ToString(),
                    "--timeout-ms", timeout.ToString(), "--result", resultFile,
                ];
                // The child enforces --timeout-ms per run; this outer bound only catches a child
                // that hangs outside a run (it gets killed and the row reports it).
                long bound = (long)(warmup + maxRuns + 2) * (timeout + 10_000) + (long)minTime + 60_000;
                int code;
                string? err = null;
                try { code = await RunPassthrough(bin, childArgs, bound); }
                catch (TimeoutException) { code = -1; err = $"child process did not finish within {bound} ms; killed"; }
                JsonObject row;
                if (File.Exists(resultFile))
                {
                    row = JsonNode.Parse(File.ReadAllText(resultFile))!.AsObject();
                }
                else
                {
                    row = ErrorRow(meta, manifestDoc, w, err ?? $"child process exited with code {code} without a result (crash)");
                }
                Console.Error.WriteLine(Summary(row));
                results.Add(row);
            }
        }
        try { Directory.Delete(tmp, true); } catch { }

        var doc = new JsonObject
        {
            ["harness"] = "dotnet",
            ["language"] = "C#/.NET",
            ["runtime"] = RuntimeString(),
            ["host"] = Host(),
            ["settings"] = new JsonObject
            {
                ["warmup_runs"] = warmup, ["min_runs"] = minRuns, ["min_time_ms"] = minTime, ["max_runs"] = maxRuns,
            },
            ["relay"] = relay,
            ["corpus_fingerprint"] = (string?)manifestDoc["fingerprint"] ?? "",
            ["results"] = results,
        };
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outFile))!);
        File.WriteAllText(outFile, doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n");
        Console.Error.WriteLine($"wrote {outFile}");
        return 0;
    }

    static string Summary(JsonObject r) =>
        $"   -> accepted {r["accepted"]} ok={r["accepted_ok"]} median {r["median_ms"]} ms cpu {r["cpu_ms"]} ms rss {r["peak_rss_mb"]} MB" +
        (r["error"] is JsonNode e ? $" ERROR {e}" : "");

    static JsonObject ErrorRow(JsonObject meta, JsonNode manifest, string workload, string error)
    {
        var w = manifest["workloads"]!.AsArray().First(x => (string)x!["name"]! == workload)!;
        var row = (JsonObject)meta.DeepClone();
        row["workload"] = workload;
        row["events"] = (int)w["events"]!;
        row["bytes"] = (long)w["bytes"]!;
        foreach (var k in new[] { "accepted", "accepted_xor", "ambiguous_accepted", "expired_accepted" }) row[k] = null;
        row["accepted_ok"] = false;
        row["errors"] = 1;
        row["error"] = error;
        row["warmup_runs"] = 0;
        row["runs"] = 0;
        foreach (var k in new[] { "first_run_ms", "median_ms", "min_ms", "p90_ms", "run_ms", "events_per_s", "us_per_event", "cpu_ms", "peak_rss_mb", "base_rss_mb", "alloc_bytes" })
            row[k] = null;
        return row;
    }

    static string RuntimeString()
    {
        // The children run on this same runtime with the same (default) settings.
        string gc = GCSettings.IsServerGC ? "Server GC" : "Workstation GC";
        gc += AppContext.TryGetSwitch("System.GC.Concurrent", out var conc) && !conc ? ", non-concurrent" : ", concurrent";
        string tiered = Environment.GetEnvironmentVariable("DOTNET_TieredPGO") == "0" ? "TieredPGO off" : "tiered compilation + dynamic PGO (defaults)";
        return $"{RuntimeInformation.FrameworkDescription} ({RuntimeInformation.RuntimeIdentifier}, {gc}, {tiered}, Release build)";
    }

    static JsonObject Host()
    {
        string cpu = "";
        try { cpu = File.ReadLines("/proc/cpuinfo").First(l => l.StartsWith("model name")).Split(':', 2)[1].Trim(); } catch { }
        string os = "Linux";
        try { os = "Linux " + File.ReadAllText("/proc/sys/kernel/osrelease").Trim(); } catch { }
        return new JsonObject { ["cpu"] = cpu, ["cores"] = Environment.ProcessorCount, ["os"] = os };
    }

    static async Task<(int, string)> RunCapture(string bin, string[] args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(bin) { RedirectStandardOutput = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        using var cts = new CancellationTokenSource(timeoutMs);
        await p.WaitForExitAsync(cts.Token);
        return (p.ExitCode, await stdout);
    }

    /// <summary>Runs a child with its stdout and stderr sent to our stderr (stdout stays clean).</summary>
    static async Task<int> RunPassthrough(string bin, string[] args, long timeoutMs)
    {
        var psi = new ProcessStartInfo(bin) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Console.Error.WriteLine("    | " + e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) Console.Error.WriteLine(e.Data); };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(timeoutMs));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            throw new TimeoutException();
        }
        p.WaitForExit();
        return p.ExitCode;
    }
}
