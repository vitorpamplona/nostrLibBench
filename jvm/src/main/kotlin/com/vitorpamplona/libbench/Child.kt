package com.vitorpamplona.libbench

import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.ceil

/** One run's outcome. */
class RunResult(
    val ms: Double,
    val cpuMs: Double,
    /** Heap bytes all threads allocated from t0 to the end of the wait; null if the JVM has no counter. */
    val allocBytes: Long?,
    val accepted: Int,
    val xor: String,
    val ambiguous: Int,
    val expired: Int,
    val ambiguousXor: LongArray,
    val expiredXor: LongArray,
)

class RunFailure(
    message: String,
    /** The library may be wedged: stop this JVM after writing what we have. */
    val fatal: Boolean,
) : Exception(message)

/**
 * The child JVM: runs one client on every selected workload (HARNESS.md "A run") and
 * writes its rows to `--child-out`.
 */
object Child {
    /** Runs setup, subscribe and teardown off the main thread so a hung library call times out. */
    private val worker =
        Executors.newSingleThreadExecutor { r -> Thread(r, "libbench-run").apply { isDaemon = true } }

    /** --timeout-ms, for clients whose own timeouts must not cut a run short. */
    @Volatile var timeoutMs = 300_000L

    fun run(args: Args) {
        timeoutMs = args.timeoutMs
        val spec = CLIENTS.firstOrNull { it.id == args.childClient } ?: Args.usage("unknown client ${args.childClient}")
        val manifest = Manifest.load(File(args.corpus))
        val workloads = selectWorkloads(manifest, args)
        val out = File(args.childOut!!)
        val rows = ArrayList<Map<String, Any?>>()
        for (w in workloads) {
            val (row, fatal) = runWorkload(spec, w, args)
            rows += row
            out.writeText(Js.write(rows))
            if (fatal) {
                System.err.println("  stopping this JVM: a timed-out library may be wedged")
                System.err.flush()
                Runtime.getRuntime().halt(0)
            }
        }
        System.err.flush()
        dumpFlightRecordings()
        // Libraries leave non-daemon threads behind (OkHttp, Ktor, Tomcat); do not wait for them.
        Runtime.getRuntime().halt(0)
    }

    /**
     * Profiling aid: halt() skips JFR's dump on exit, so with -Dlibbench.jfrDump=<file> (and a
     * recording started by -XX:StartFlightRecording in JAVA_OPTS) the child writes its recordings
     * to <file> first. `%p` in the name becomes the child's pid. Off unless the property is set.
     */
    private fun dumpFlightRecordings() {
        val target = System.getProperty("libbench.jfrDump") ?: return
        val path = target.replace("%p", ProcessHandle.current().pid().toString())
        jdk.jfr.FlightRecorder
            .getFlightRecorder()
            .recordings
            .forEach { it.dump(java.nio.file.Path.of(path)) }
    }

    private fun <T> onWorker(
        timeoutMs: Long,
        what: String,
        block: () -> T,
    ): T {
        val f = worker.submit<T> { block() }
        try {
            return f.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            f.cancel(true)
            throw RunFailure("timeout: $what took longer than $timeoutMs ms", fatal = true)
        } catch (e: java.util.concurrent.ExecutionException) {
            val c = e.cause ?: e
            throw RunFailure("$what threw ${c.javaClass.name}: ${c.message?.take(300)}", fatal = false)
        }
    }

    /**
     * Cumulative heap bytes allocated by every thread of the JVM, live and terminated
     * (JDK 21+), or null when the JVM does not support or has disabled the counter.
     */
    private val threadMx = java.lang.management.ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean

    private fun totalAllocated(): Long? = threadMx?.totalThreadAllocatedBytes?.takeIf { it >= 0 }

    /** Current resident set of this process (VmRSS), in MB. */
    private fun currentRssMb(): Double? =
        try {
            File("/proc/self/status")
                .readLines()
                .firstOrNull { it.startsWith("VmRSS:") }
                ?.substringAfter(':')
                ?.trim()
                ?.removeSuffix("kB")
                ?.trim()
                ?.toLong()
                ?.let { it / 1024.0 }
        } catch (_: Exception) {
            null
        }

    /** [baseRss], when given, gets the RSS after setup and a full GC, before the REQ. */
    private fun oneRun(
        spec: ClientSpec,
        w: Workload,
        url: String,
        args: Args,
        baseRss: ((Double?) -> Unit)? = null,
    ): RunResult {
        val sink = EventSink(w.ambiguousIds.toHashSet(), w.expiredIds.toHashSet(), w.validEvents + w.ambiguousIds.size)
        val client = spec.create()
        onWorker(args.timeoutMs, "setup") { client.setup(url) }
        if (baseRss != null) {
            System.gc()
            baseRss(currentRssMb())
        }
        var t0 = 0L
        var cpu0 = 0L
        var alloc0: Long? = null
        var alloc1: Long? = null
        try {
            val started = System.nanoTime()
            val subscribed =
                worker.submit {
                    alloc0 = totalAllocated()
                    cpu0 = Cpu.nanos()
                    t0 = System.nanoTime()
                    client.subscribe(w.events, sink)
                }
            val outcome = sink.await(idleMs = 1000, deadlineNanos = started + args.timeoutMs * 1_000_000L)
            alloc1 = totalAllocated()
            sink.close()
            if (outcome == EventSink.Outcome.TIMEOUT) {
                throw RunFailure(
                    "timeout: no EOSE within ${args.timeoutMs} ms (${sink.accepted} events accepted)",
                    fatal = true,
                )
            }
            try {
                subscribed.get(args.timeoutMs, TimeUnit.MILLISECONDS)
            } catch (e: java.util.concurrent.ExecutionException) {
                val c = e.cause ?: e
                throw RunFailure("subscribe threw ${c.javaClass.name}: ${c.message?.take(300)}", fatal = false)
            }
        } finally {
            sink.close()
            try {
                onWorker(30_000, "teardown") { client.teardown() }
            } catch (e: RunFailure) {
                System.err.println("   teardown: ${e.message}")
                if (e.fatal) throw e
            }
        }
        sink.dumped?.let { ids ->
            val dir = File(System.getenv("LIBBENCH_DUMP_IDS")).apply { mkdirs() }
            File(dir, "${spec.id}-${w.name}-${System.nanoTime()}.ids").writeText(ids.joinToString("\n"))
        }
        if (sink.late > 0) System.err.println("   ${sink.late} events were delivered after the run had ended (not counted)")
        if (sink.badIds > 0) System.err.println("   ${sink.badIds} delivered events had an id that is not 64 hex chars (not counted)")
        val end = sink.endNanos()
        return RunResult(
            ms = (end - t0) / 1e6,
            cpuMs = (sink.endCpu() - cpu0) / 1e6,
            allocBytes = alloc0?.let { a0 -> alloc1?.let { it - a0 } },
            accepted = sink.accepted,
            xor = EventSink.toHex(sink.xor),
            ambiguous = sink.ambiguous,
            expired = sink.expired,
            ambiguousXor = sink.ambiguousXor.copyOf(),
            expiredXor = sink.expiredXor.copyOf(),
        )
    }

    /** HARNESS.md "Correctness: the accepted set". */
    private fun acceptedOk(
        w: Workload,
        r: RunResult,
    ): Boolean {
        val e = w.expiredIds.size
        if (r.expired != 0 && r.expired != e) return false
        if (r.accepted != w.validEvents - e + r.expired + r.ambiguous) return false
        val expected = LongArray(4)
        EventSink.xorHex(w.validIdXor, expected)
        val allExpired = LongArray(4)
        w.expiredIds.forEach { EventSink.xorHex(it, allExpired) }
        for (i in 0 until 4) {
            val droppedExpired = allExpired[i] xor r.expiredXor[i]
            expected[i] = expected[i] xor droppedExpired xor r.ambiguousXor[i]
        }
        return EventSink.toHex(expected) == r.xor
    }

    private fun runWorkload(
        spec: ClientSpec,
        w: Workload,
        args: Args,
    ): Pair<Map<String, Any?>, Boolean> {
        val row = baseRow(spec, w)
        val url = "${args.relay}/${w.name}"
        var first: RunResult? = null
        val measured = ArrayList<RunResult>()
        var runs = 0
        var measureStart = 0L

        fun fail(msg: String) {
            row["errors"] = (row["errors"] as Int) + 1
            row["error"] = msg
            row["accepted_ok"] = false
            row["runs"] = 0
            row["peak_rss_mb"] = peakRssMb()?.let { round1(it) }
        }

        while (true) {
            val warm = runs < args.warmupRuns
            if (!warm && measured.isEmpty()) measureStart = System.nanoTime()
            val r =
                try {
                    oneRun(spec, w, url, args, if (runs == 0) { rss -> row["base_rss_mb"] = rss?.let { round1(it) } } else null)
                } catch (e: RunFailure) {
                    runs++
                    System.err.println("   %-9s run %d: %s".format(w.name, runs, e.message))
                    fail("run $runs: ${e.message}")
                    return row to e.fatal
                } catch (t: Throwable) {
                    runs++
                    System.err.println("   %-9s run %d: %s".format(w.name, runs, t))
                    fail("run $runs: ${t.javaClass.name}: ${t.message?.take(300)}")
                    return row to false
                }
            runs++
            System.err.println(
                String.format(
                    java.util.Locale.ROOT,
                    "   %-9s run %-2d %s %9.1f ms  cpu %9.1f ms  accepted %d (ambiguous %d, expired %d)",
                    w.name, runs, if (warm) "warm" else "    ", r.ms, r.cpuMs, r.accepted, r.ambiguous, r.expired,
                ),
            )
            if (first == null) {
                first = r
                row["accepted"] = r.accepted
                row["accepted_xor"] = r.xor
                row["ambiguous_accepted"] = r.ambiguous
                row["expired_accepted"] = r.expired
                row["accepted_ok"] = acceptedOk(w, r)
                row["first_run_ms"] = round1(r.ms)
            } else if (r.accepted != first.accepted || r.xor != first.xor) {
                fail(
                    "run $runs delivered a different set than the first run " +
                        "(${r.accepted} events, xor ${r.xor}; first: ${first.accepted}, ${first.xor})",
                )
                return row to false
            }
            if (warm) {
                row["warmup_runs"] = (row["warmup_runs"] as Int) + 1
                continue
            }
            measured += r
            val n = measured.size
            val elapsedMs = (System.nanoTime() - measureStart) / 1e6
            if (n >= args.maxRuns || (n >= args.minRuns && elapsedMs >= args.minTimeMs)) break
        }

        val ms = measured.map { round1(it.ms) }
        val sorted = ms.sorted()
        val med = median(sorted)
        row["runs"] = measured.size
        row["median_ms"] = round1(med)
        row["min_ms"] = sorted.first()
        row["p90_ms"] = nearestRank(sorted, 0.9)
        row["run_ms"] = ms
        row["events_per_s"] = round1(w.events / (med / 1000))
        row["us_per_event"] = Math.round(med * 1000 / w.events * 1000) / 1000.0
        row["cpu_ms"] = round1(median(measured.map { it.cpuMs }.sorted()))
        row["alloc_bytes"] = medianAlloc(measured)
        row["peak_rss_mb"] = peakRssMb()?.let { round1(it) }
        return row to false
    }

    /**
     * alloc_bytes of the run whose ms is median_ms; with an even number of runs (median_ms
     * is then the mean of the two middle runs) the mean of those two runs' values.
     */
    private fun medianAlloc(measured: List<RunResult>): Long? {
        if (measured.isEmpty()) return null
        val byMs = measured.sortedBy { it.ms }
        val n = byMs.size
        val mid = byMs[n / 2].allocBytes ?: return null
        if (n % 2 == 1) return mid
        val lo = byMs[n / 2 - 1].allocBytes ?: return null
        return (lo + mid) / 2
    }

    private fun median(s: List<Double>): Double {
        val n = s.size
        if (n == 0) return 0.0
        return if (n % 2 == 0) (s[n / 2 - 1] + s[n / 2]) / 2 else s[n / 2]
    }

    private fun nearestRank(
        s: List<Double>,
        q: Double,
    ): Double = s[(ceil(q * s.size).toInt() - 1).coerceIn(0, s.size - 1)]
}

fun round1(v: Double) = Math.round(v * 10) / 10.0
