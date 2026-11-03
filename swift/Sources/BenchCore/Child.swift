import Foundation

/// Entry point of a per-library binary (libbench-<package>): runs one client, in this
/// process, for every selected workload, and writes one row per workload (JSON lines) to
/// --child-out. The parent (libbench) starts one such process per client.
///
/// The harness runs on a background thread while the main thread runs the main dispatch
/// queue, as in an app: some libraries deliver on the main queue or the main actor.
public func childMain(openers: [String: Opener]) -> Never {
    let o = Options.parse(Array(CommandLine.arguments.dropFirst()))
    if o.list {
        for c in allClients where openers[c.id] != nil { print(c.id) }
        exit(0)
    }
    guard o.child, o.clients.count == 1, let opener = openers[o.clients[0]],
          let info = allClients.first(where: { $0.id == o.clients[0] }) else {
        fatal("this is a per-library child binary; run swift/run.sh (clients here: \(openers.keys.sorted().joined(separator: ",")))")
    }
    let manifest = Manifest.load(o.corpus)
    let workloads = manifest.select(o.workloads)
    let thread = Thread {
        var lines: [String] = []
        for w in workloads {
            let (row, fatalRun) = runWorkload(info, opener, o, w)
            lines.append(row.compact())
            writeLines(lines, to: o.childOut)
            if fatalRun {
                // A timed-out run may leave the library wedged: stop here; the parent
                // reports the remaining workloads as failed.
                break
            }
        }
        exit(0)
    }
    thread.stackSize = 8 << 20
    thread.start()
    dispatchMain()
}

private func writeLines(_ lines: [String], to path: String) {
    let text = lines.joined(separator: "\n") + "\n"
    if path.isEmpty {
        FileHandle.standardOutput.write(Data(text.utf8))
    } else if !FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) {
        fatal("cannot write \(path)")
    }
}

private let quietNs: UInt64 = 1_000_000_000

private struct RunError: Error, CustomStringConvertible {
    let description: String
    let isTimeout: Bool
}

/// One subscription, end to end (HARNESS.md "A run").
private func oneRun(_ opener: Opener, url: String, w: Workload, expect: Expect, timeoutMs: Int) throws -> RunResult {
    // 1. setup, untimed
    let session: Session
    do {
        session = try opener(url)
    } catch {
        throw RunError(description: "setup: \(error)", isTimeout: false)
    }
    let sink = Sink(expect: expect)

    // 2. timed
    let cpu0 = cpuNs()
    let t0 = nowNs()
    do {
        try session.subscribe(sink, limit: w.events)
    } catch {
        closeWithin(session, seconds: 5)
        throw RunError(description: "subscribe: \(error)", isTimeout: false)
    }

    // 3. end: EOSE seen and either every event a correct library can deliver has arrived,
    // or nothing arrived for 1 s.
    let deadline = t0 + UInt64(timeoutMs) * 1_000_000
    while true {
        if sink.waitDone(ns: 20_000_000) { break }
        let now = nowNs()
        let (eose, lastAt, n) = sink.snapshot { s in (s.eose, max(s.eoseNs, s.lastNs), s.accepted) }
        if eose && now - lastAt >= quietNs { break }
        if now > deadline {
            if !eose {
                // No teardown: a library stuck here may never return from it.
                throw RunError(description: "timeout: no EOSE within \(timeoutMs) ms (\(n) events delivered)", isTimeout: true)
            }
            break
        }
    }

    let (result, err): (RunResult, String?) = sink.snapshot { s in
        let end = max(s.eoseNs, s.lastNs)
        var r = RunResult()
        r.ms = Double(end &- t0) / 1e6
        r.cpuMs = Double(s.cpuEndNs &- cpu0) / 1e6
        r.accepted = s.accepted
        r.xor = s.xor
        r.ambiguous = s.ambiguous
        r.ambiguousXor = s.ambiguousXor
        r.expired = s.expired
        return (r, s.error)
    }

    // 4. teardown, untimed
    closeWithin(session, seconds: 5)
    if let err { throw RunError(description: err, isTimeout: false) }
    return result
}

private func closeWithin(_ s: Session, seconds: Double) {
    let latch = Latch()
    DispatchQueue.global().async {
        s.close()
        latch.open()
    }
    if !latch.wait(seconds: seconds) {
        log("   teardown did not finish in \(Int(seconds)) s")
    }
}

private struct Row {
    var accepted: Int?
    var acceptedXor: String?
    var ambiguousAccepted: Int?
    var expiredAccepted: Int?
    var acceptedOK = false
    var errors = 0
    var error: String?
    var warmupRuns = 0
    var runs = 0
    var firstRunMs: Double?
    var medianMs: Double?
    var minMs: Double?
    var p90Ms: Double?
    var runMs: [Double] = []
    var eventsPerS: Double?
    var usPerEvent: Double?
    var cpuMs: Double?
    var peakRss: Double?

    mutating func nullTimings() {
        firstRunMs = nil; medianMs = nil; minMs = nil; p90Ms = nil
        eventsPerS = nil; usPerEvent = nil; cpuMs = nil
        runMs = []
        runs = 0
        acceptedOK = false
        peakRss = round1(peakRssMb())
    }
}

/// A row in HARNESS.md's key order. The parent passes the version it read from the
/// package's Package.resolved in LIBBENCH_VERSION.
func rowJSON(_ info: ClientInfo, _ w: Workload, version: String,
             accepted: Int? = nil, acceptedXor: String? = nil, ambiguousAccepted: Int? = nil, expiredAccepted: Int? = nil,
             acceptedOK: Bool = false, errors: Int = 0, error: String? = nil, warmupRuns: Int = 0, runs: Int = 0,
             firstRunMs: Double? = nil, medianMs: Double? = nil, minMs: Double? = nil, p90Ms: Double? = nil,
             runMs: [Double] = [], eventsPerS: Double? = nil, usPerEvent: Double? = nil, cpuMs: Double? = nil,
             peakRssMb: Double? = nil) -> JSON {
    .obj([
        ("client", .str(info.id)),
        ("library", .str(info.library)),
        ("version", .str(version)),
        ("license", .str(info.license)),
        ("api", .str(info.api)),
        ("websocket", .str(info.websocket)),
        ("crypto", .str(info.crypto)),
        ("verify", .str(info.verify)),
        ("notes", .str(info.notes)),
        ("variant", .bool(info.variant)),
        ("workload", .str(w.name)),
        ("events", .int(w.events)),
        ("bytes", .int(w.bytes)),
        ("accepted", .opt(accepted)),
        ("accepted_xor", .opt(acceptedXor)),
        ("ambiguous_accepted", .opt(ambiguousAccepted)),
        ("expired_accepted", .opt(expiredAccepted)),
        ("accepted_ok", .bool(acceptedOK)),
        ("errors", .int(errors)),
        ("error", .opt(error)),
        ("warmup_runs", .int(warmupRuns)),
        ("runs", .int(runs)),
        ("first_run_ms", .opt(firstRunMs)),
        ("median_ms", .opt(medianMs)),
        ("min_ms", .opt(minMs)),
        ("p90_ms", .opt(p90Ms)),
        ("run_ms", .arr(runMs.map { .num($0) })),
        ("events_per_s", .opt(eventsPerS)),
        ("us_per_event", .opt(usPerEvent)),
        ("cpu_ms", .opt(cpuMs)),
        ("peak_rss_mb", .opt(peakRssMb)),
    ])
}

private func runWorkload(_ info: ClientInfo, _ opener: Opener, _ o: Options, _ w: Workload) -> (JSON, Bool) {
    var r = Row()
    func json() -> JSON {
        rowJSON(info, w, version: ProcessInfo.processInfo.environment["LIBBENCH_VERSION"] ?? info.versionLabel, accepted: r.accepted, acceptedXor: r.acceptedXor,
                ambiguousAccepted: r.ambiguousAccepted, expiredAccepted: r.expiredAccepted,
                acceptedOK: r.acceptedOK, errors: r.errors, error: r.error, warmupRuns: r.warmupRuns, runs: r.runs,
                firstRunMs: r.firstRunMs, medianMs: r.medianMs, minMs: r.minMs, p90Ms: r.p90Ms, runMs: r.runMs,
                eventsPerS: r.eventsPerS, usPerEvent: r.usPerEvent, cpuMs: r.cpuMs, peakRssMb: r.peakRss)
    }
    let expect: Expect
    do {
        expect = try Expect(w)
    } catch {
        r.errors += 1
        r.error = "\(error)"
        r.nullTimings()
        return (json(), false)
    }
    let url = o.relay + "/" + w.name
    let set = o.settings

    var first: RunResult?
    var measured: [RunResult] = []
    var runs = 0
    var mStart: UInt64 = 0
    while true {
        let warm = runs < set.warmupRuns
        if !warm && measured.isEmpty { mStart = nowNs() }
        let res: RunResult
        do {
            res = try oneRun(opener, url: url, w: w, expect: expect, timeoutMs: set.timeoutMs)
        } catch {
            runs += 1
            r.errors += 1
            r.error = "run \(runs): \(error)"
            r.nullTimings()
            log("   \(w.name.padding(toLength: 9, withPad: " ", startingAt: 0)) run \(runs): \(error)")
            return (json(), (error as? RunError)?.isTimeout ?? false)
        }
        runs += 1
        log(String(format: "   %@ run %-2d %@ %9.1f ms  cpu %9.1f ms  accepted %d (ambiguous %d, expired %d)",
                   w.name.padding(toLength: 9, withPad: " ", startingAt: 0), runs, warm ? "warm" : "    ",
                   res.ms, res.cpuMs, res.accepted, res.ambiguous, res.expired))
        if let f = first {
            if res.accepted != f.accepted || res.xor != f.xor {
                r.errors += 1
                r.error = "run \(runs) delivered a different set than the first run (\(res.accepted) events, xor \(res.xor.hex); first: \(f.accepted), \(f.xor.hex))"
                r.nullTimings()
                return (json(), false)
            }
        } else {
            first = res
            r.accepted = res.accepted
            r.acceptedXor = res.xor.hex
            r.ambiguousAccepted = res.ambiguous
            r.expiredAccepted = res.expired
            r.acceptedOK = expect.ok(res)
            r.firstRunMs = round1(res.ms)
        }
        if warm {
            r.warmupRuns += 1
            continue
        }
        measured.append(res)
        let n = measured.count
        if n >= set.maxRuns || (n >= set.minRuns && nowNs() - mStart >= UInt64(set.minTimeMs) * 1_000_000) {
            break
        }
    }

    r.runs = measured.count
    let ms = measured.map { round1($0.ms) }
    r.runMs = ms
    let sorted = ms.sorted()
    let cpus = measured.map { $0.cpuMs }.sorted()
    let med = median(sorted)
    r.medianMs = round1(med)
    r.minMs = sorted.first
    r.p90Ms = round1(nearestRank(sorted, 0.9))
    r.eventsPerS = round1(Double(w.events) / (med / 1000))
    r.usPerEvent = round3(med * 1000 / Double(w.events))
    r.cpuMs = round1(median(cpus))
    r.peakRss = round1(peakRssMb())
    return (json(), false)
}

func median(_ s: [Double]) -> Double {
    let n = s.count
    if n == 0 { return 0 }
    return n % 2 == 0 ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[n / 2]
}

func nearestRank(_ s: [Double], _ q: Double) -> Double {
    var i = Int((q * Double(s.count)).rounded(.up)) - 1
    i = min(max(i, 0), s.count - 1)
    return s[i]
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
