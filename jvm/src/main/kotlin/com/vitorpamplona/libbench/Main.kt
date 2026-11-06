package com.vitorpamplona.libbench

import java.io.File
import java.lang.management.ManagementFactory
import kotlin.system.exitProcess

/**
 * nostrLibBench JVM harness. Follows HARNESS.md.
 *
 * The process the launcher starts is the *parent*: it never touches a library. For each
 * client it forks a fresh *child* JVM (same java binary, classpath and JVM flags) that runs
 * that one client on every selected workload and writes its rows to a temp file; the parent
 * merges them into one result file. One JVM per client keeps one library's JIT profile,
 * heap, thread pools and global caches from taxing the next.
 */
class Args(
    var relay: String = "ws://127.0.0.1:7777",
    var corpus: String = ".corpus",
    var out: String = "results/jvm.json",
    var workloads: List<String> = listOf("all"),
    var clients: List<String>? = null,
    var warmupRuns: Int = 2,
    var minRuns: Int = 5,
    var minTimeMs: Long = 10_000,
    var maxRuns: Int = 30,
    var timeoutMs: Long = 300_000,
    var list: Boolean = false,
    var childClient: String? = null,
    var childOut: String? = null,
) {
    fun toFlags(): List<String> =
        listOf(
            "--relay", relay, "--corpus", corpus, "--workloads", workloads.joinToString(","),
            "--warmup-runs", warmupRuns.toString(), "--min-runs", minRuns.toString(),
            "--min-time-ms", minTimeMs.toString(), "--max-runs", maxRuns.toString(),
            "--timeout-ms", timeoutMs.toString(),
        )

    companion object {
        fun parse(argv: Array<String>): Args {
            val a = Args()
            var quick = false
            val explicit = HashSet<String>()
            var i = 0

            fun next(): String {
                if (i + 1 >= argv.size) usage("missing value for ${argv[i]}")
                return argv[++i]
            }

            fun list(s: String) = s.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            while (i < argv.size) {
                val arg = argv[i]
                explicit += arg
                when (arg) {
                    "--relay" -> a.relay = next().trimEnd('/')
                    "--corpus" -> a.corpus = next()
                    "--out" -> a.out = next()
                    "--workloads" -> a.workloads = list(next())
                    "--clients" -> a.clients = list(next())
                    "--warmup-runs" -> a.warmupRuns = next().toInt()
                    "--min-runs" -> a.minRuns = next().toInt()
                    "--min-time-ms" -> a.minTimeMs = next().toLong()
                    "--max-runs" -> a.maxRuns = next().toInt()
                    "--timeout-ms" -> a.timeoutMs = next().toLong()
                    "--quick" -> quick = true
                    "--list" -> a.list = true
                    "--child-client" -> a.childClient = next()
                    "--child-out" -> a.childOut = next()
                    "-h", "--help" -> usage(null)
                    else -> usage("unknown argument: $arg")
                }
                i++
            }
            // --quick sets the smoke-test defaults; an explicit flag still wins.
            if (quick) {
                if ("--warmup-runs" !in explicit) a.warmupRuns = 1
                if ("--min-runs" !in explicit) a.minRuns = 2
                if ("--min-time-ms" !in explicit) a.minTimeMs = 0
            }
            if (a.minRuns < 1) usage("--min-runs must be at least 1")
            if (a.maxRuns < a.minRuns) a.maxRuns = a.minRuns
            return a
        }

        fun usage(error: String?): Nothing {
            if (error != null) System.err.println("libbench: $error")
            System.err.println(
                """
                usage: libbench [--relay URL] [--corpus DIR] [--out FILE] [--workloads a,b] [--clients x,y]
                                [--warmup-runs N] [--min-runs N] [--min-time-ms N] [--max-runs N]
                                [--timeout-ms N] [--quick] [--list]
                """.trimIndent(),
            )
            exitProcess(if (error == null) 0 else 2)
        }
    }
}

class Workload(
    val name: String,
    val events: Int,
    val bytes: Long,
    val validEvents: Int,
    val validIdXor: String,
    val ambiguousIds: List<String>,
    val expiredIds: List<String>,
)

class Manifest(
    val fingerprint: String,
    val workloads: List<Workload>,
) {
    companion object {
        fun load(corpusDir: File): Manifest {
            val f = File(corpusDir, "manifest.json")
            if (!f.exists()) {
                System.err.println("libbench: $f not found; build it with: python3 corpus/prepare.py")
                exitProcess(2)
            }

            @Suppress("UNCHECKED_CAST")
            val m = Js.parse(f.readText()) as Map<String, Any?>

            @Suppress("UNCHECKED_CAST")
            val ws =
                (m["workloads"] as List<Map<String, Any?>>).map {
                    Workload(
                        name = it["name"] as String,
                        events = (it["events"] as Number).toInt(),
                        bytes = (it["bytes"] as Number).toLong(),
                        validEvents = (it["valid_events"] as Number).toInt(),
                        validIdXor = it["valid_id_xor"] as String,
                        ambiguousIds = (it["ambiguous_ids"] as? List<String>) ?: emptyList(),
                        expiredIds = (it["expired_ids"] as? List<String>) ?: emptyList(),
                    )
                }
            return Manifest(m["fingerprint"] as? String ?: "", ws)
        }
    }
}

fun selectWorkloads(
    manifest: Manifest,
    args: Args,
): List<Workload> {
    val unknown = args.workloads.filter { w -> manifest.workloads.none { it.name == w } }
    if (unknown.isNotEmpty()) Args.usage("unknown workload(s): ${unknown.joinToString()}")
    return args.workloads.map { w -> manifest.workloads.first { it.name == w } }
}

fun selectClients(args: Args): List<ClientSpec> {
    val wanted = args.clients ?: return CLIENTS
    val unknown = wanted.filter { id -> CLIENTS.none { it.id == id } }
    if (unknown.isNotEmpty()) Args.usage("unknown client(s): ${unknown.joinToString()} (see --list)")
    return CLIENTS.filter { it.id in wanted }
}

fun main(argv: Array<String>) {
    val args = Args.parse(argv)
    if (args.list) {
        CLIENTS.forEach { println(it.id) }
        return
    }
    if (args.childClient != null) {
        Child.run(args)
    } else {
        Parent.run(args)
    }
}

/** Peak resident set of this process (VmHWM), in MB. */
fun peakRssMb(): Double? =
    try {
        File("/proc/self/status")
            .readLines()
            .firstOrNull { it.startsWith("VmHWM:") }
            ?.substringAfter(':')
            ?.trim()
            ?.removeSuffix("kB")
            ?.trim()
            ?.toLong()
            ?.let { it / 1024.0 }
    } catch (_: Exception) {
        null
    }

object Parent {
    fun run(args: Args) {
        val corpusDir = File(args.corpus)
        val manifest = Manifest.load(corpusDir)
        val workloads = selectWorkloads(manifest, args)
        val specs = selectClients(args)

        val runtime = ManagementFactory.getRuntimeMXBean()
        // inputArguments also lists what the JVM picked up from JAVA_TOOL_OPTIONS; the child
        // inherits the environment and picks those up itself, so they are not repeated.
        val toolOptions = System.getenv("JAVA_TOOL_OPTIONS")?.split(Regex("\\s+"))?.toSet() ?: emptySet()
        val jvmArgs =
            runtime.inputArguments.filterNot {
                it in toolOptions || it.startsWith("-agentlib:") || it.startsWith("-javaagent:")
            }
        val java =
            ProcessHandle
                .current()
                .info()
                .command()
                .orElse(File(System.getProperty("java.home"), "bin/java").path)
        val classpath = System.getProperty("java.class.path")

        val gcNames = ManagementFactory.getGarbageCollectorMXBeans().map { it.name }
        val shownArgs = jvmArgs.filter { it.startsWith("-Xm") || it.startsWith("-XX:") }
        val runtimeString =
            "${System.getProperty("java.vm.name")} ${System.getProperty("java.runtime.version")} " +
                "(${System.getProperty("java.vm.vendor")}), GC ${gcName(gcNames)}, ${shownArgs.joinToString(" ")}, one JVM per client"

        System.err.println("libbench (jvm): ${specs.size} clients x ${workloads.size} workloads against ${args.relay}; $runtimeString")

        val logDir = File(System.getProperty("libbench.logDir") ?: File(System.getProperty("java.io.tmpdir"), "libbench-jvm-logs").path)
        logDir.mkdirs()

        val results = ArrayList<Any?>()
        for (spec in specs) {
            System.err.println("== ${spec.id}  (${spec.library} ${spec.version}, verify ${spec.verify})")
            val tmp = File.createTempFile("libbench-${spec.id}-", ".json")
            val stdoutLog = File(logDir, "${spec.id}.stdout.log")
            try {
                val cmd = ArrayList<String>()
                cmd += java
                cmd += jvmArgs
                cmd += listOf("-cp", classpath, "com.vitorpamplona.libbench.MainKt")
                cmd += listOf("--child-client", spec.id, "--child-out", tmp.path)
                cmd += args.toFlags()
                // Libraries that print (Rhodium prints every invalid event) write to a log
                // file, not to the terminal; progress goes to stderr.
                val code =
                    ProcessBuilder(cmd)
                        .redirectOutput(ProcessBuilder.Redirect.to(stdoutLog))
                        .redirectError(ProcessBuilder.Redirect.INHERIT)
                        .start()
                        .waitFor()

                @Suppress("UNCHECKED_CAST")
                val rows = if (tmp.length() > 0) (Js.parse(tmp.readText()) as? List<Map<String, Any?>>) ?: emptyList() else emptyList()
                val done = rows.map { it["workload"] }.toSet()
                results.addAll(rows)
                for (w in workloads) {
                    if (w.name in done) continue
                    val why =
                        if (rows.isNotEmpty()) {
                            "not run: an earlier workload timed out and the child JVM stopped"
                        } else {
                            "child JVM exited with code $code before writing a result (stdout: ${stdoutLog.path})"
                        }
                    System.err.println("  ${w.name}: $why")
                    results.add(failedRow(spec, w, why))
                }
            } finally {
                tmp.delete()
            }
        }

        val out = LinkedHashMap<String, Any?>()
        out["harness"] = "jvm"
        out["language"] = "JVM (Kotlin/Java)"
        out["runtime"] = runtimeString
        out["jvm"] =
            linkedMapOf(
                "vm" to System.getProperty("java.vm.name"),
                "vendor" to System.getProperty("java.vm.vendor"),
                "version" to System.getProperty("java.runtime.version"),
                "gc" to gcName(gcNames),
                "args" to jvmArgs,
            )
        out["host"] =
            linkedMapOf(
                "cpu" to cpuModel(),
                "cores" to Runtime.getRuntime().availableProcessors(),
                "os" to "${System.getProperty("os.name")} ${System.getProperty("os.version")}",
            )
        out["settings"] =
            linkedMapOf(
                "warmup_runs" to args.warmupRuns,
                "min_runs" to args.minRuns,
                "min_time_ms" to args.minTimeMs,
                "max_runs" to args.maxRuns,
                "timeout_ms" to args.timeoutMs,
            )
        out["relay"] = args.relay
        out["corpus_fingerprint"] = manifest.fingerprint
        out["results"] = results

        val outFile = File(args.out)
        outFile.absoluteFile.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) error("could not create $it") }
        outFile.writeText(Js.write(out, prettyPrint = true) + "\n")
        printTable(results)
        System.err.println("wrote ${outFile.path}")
    }

    private fun printTable(results: List<Any?>) {
        System.err.println(
            String.format(
                "%-26s %-9s %-8s %8s %4s %4s %-5s %10s %10s %8s  %s",
                "client", "workload", "verify", "accepted", "amb", "exp", "ok", "median_ms", "cpu_ms", "rss_mb", "error",
            ),
        )
        for (r in results) {
            val row = r as Map<*, *>
            System.err.println(
                String.format(
                    java.util.Locale.ROOT,
                    "%-26s %-9s %-8s %8s %4s %4s %-5s %10s %10s %8s  %s",
                    row["client"], row["workload"], row["verify"], row["accepted"], row["ambiguous_accepted"],
                    row["expired_accepted"], row["accepted_ok"], row["median_ms"], row["cpu_ms"], row["peak_rss_mb"],
                    (row["error"] as? String)?.take(80) ?: "",
                ),
            )
        }
    }

    private fun gcName(beans: List<String>): String =
        when {
            beans.any { it.startsWith("G1") } -> "G1"
            beans.any { it.startsWith("ZGC") } -> "ZGC"
            beans.any { it.startsWith("Shenandoah") } -> "Shenandoah"
            beans.any { it.startsWith("PS ") } -> "Parallel"
            beans.any { it == "Copy" || it == "MarkSweepCompact" } -> "Serial"
            else -> beans.joinToString("+")
        }

    private fun cpuModel(): String =
        try {
            File("/proc/cpuinfo")
                .readLines()
                .firstOrNull { it.startsWith("model name") }
                ?.substringAfter(':')
                ?.trim()
        } catch (_: Exception) {
            null
        } ?: System.getProperty("os.arch")
}

/** The fields every row starts with. */
fun baseRow(
    spec: ClientSpec,
    w: Workload,
): LinkedHashMap<String, Any?> =
    linkedMapOf(
        "client" to spec.id,
        "library" to spec.library,
        "version" to spec.version,
        "license" to spec.license,
        "api" to spec.api,
        "websocket" to spec.websocket,
        "crypto" to spec.crypto,
        "verify" to spec.verify,
        "notes" to spec.notes,
        "variant" to spec.variant,
        "workload" to w.name,
        "events" to w.events,
        "bytes" to w.bytes,
        "accepted" to null,
        "accepted_xor" to null,
        "ambiguous_accepted" to null,
        "expired_accepted" to null,
        "accepted_ok" to false,
        "errors" to 0,
        "error" to null,
        "warmup_runs" to 0,
        "runs" to 0,
        "first_run_ms" to null,
        "median_ms" to null,
        "min_ms" to null,
        "p90_ms" to null,
        "run_ms" to emptyList<Double>(),
        "events_per_s" to null,
        "us_per_event" to null,
        "cpu_ms" to null,
        "peak_rss_mb" to null,
        "base_rss_mb" to null,
        "alloc_bytes" to null,
    )

fun failedRow(
    spec: ClientSpec,
    w: Workload,
    error: String,
): Map<String, Any?> =
    baseRow(spec, w).apply {
        this["errors"] = 1
        this["error"] = error
    }
