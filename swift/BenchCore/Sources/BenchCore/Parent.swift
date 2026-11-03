import Foundation

/// The parent (libbench): runs every selected client in a fresh child process of its
/// library's binary, one after another, and writes results/swift.json. A child that crashes,
/// hangs or was never built still gets rows with `error` set.
public func parentMain() -> Never {
    let o = Options.parse(Array(CommandLine.arguments.dropFirst()))
    if o.list {
        for c in allClients { print(c.id) }
        exit(0)
    }
    let manifest = Manifest.load(o.corpus)
    let workloads = manifest.select(o.workloads)
    let selected: [ClientInfo] = o.clients.isEmpty ? allClients : o.clients.map { id in
        guard let c = allClients.first(where: { $0.id == id }) else { fatal("unknown client \"\(id)\" (see --list)") }
        return c
    }
    let swiftDir = findSwiftDir()

    var rows: [JSON] = []
    for c in selected {
        log("== \(c.id)")
        let version = resolvedVersion(c, swiftDir: swiftDir)
        func errorRows(_ msg: String, for ws: [Workload]) -> [JSON] {
            ws.map { rowJSON(c, $0, version: version, errors: 1, error: msg) }
        }
        #if !os(macOS)
        if c.appleOnly {
            log("   macOS only, skipped")
            rows += errorRows("macOS only", for: workloads)
            continue
        }
        #endif
        let bin = "\(swiftDir)/.build/bin/libbench-\(c.package)"
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            let msg = "not built (build log: swift/.build/logs/\(c.package).log)"
            log("   \(msg)")
            rows += errorRows(msg, for: workloads)
            continue
        }
        let out = NSTemporaryDirectory() + "libbench-swift-\(getpid())-\(c.id).jsonl"
        try? FileManager.default.removeItem(atPath: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = o.passThrough + ["--clients", c.id, "--child", "--child-out", out]
        var env = ProcessInfo.processInfo.environment
        env["LIBBENCH_VERSION"] = version
        p.environment = env
        p.standardOutput = FileHandle.standardError // nothing a library prints can corrupt the rows
        p.standardError = FileHandle.standardError
        var status = "did not start"
        do {
            try p.run()
            // Watchdog: every run of every workload at its timeout, plus setup and teardown.
            let runsPerWorkload = o.settings.warmupRuns + o.settings.maxRuns
            let limit = Double(workloads.count * runsPerWorkload) * (Double(o.settings.timeoutMs) / 1000 + 40)
            let pid = p.processIdentifier
            let watchdog = DispatchWorkItem {
                log("   child ran past \(Int(limit)) s, killing it")
                kill(pid, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
            p.waitUntilExit()
            watchdog.cancel()
            status = p.terminationReason == .uncaughtSignal
                ? "child killed by signal \(p.terminationStatus)"
                : "child exited with status \(p.terminationStatus)"
        } catch {
            status = "cannot start \(bin): \(error)"
        }
        var got: [String: String] = [:]
        if let text = try? String(contentsOfFile: out, encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.isEmpty {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let w = obj["workload"] as? String {
                    got[w] = String(line)
                }
            }
        }
        try? FileManager.default.removeItem(atPath: out)
        for w in workloads {
            if let line = got[w.name] {
                rows.append(.raw(line))
            } else {
                let msg = got.isEmpty ? "\(status) before writing a row" : "\(status) before this workload (an earlier one timed out or crashed)"
                log("   \(w.name): \(msg)")
                rows += errorRows(msg, for: [w])
            }
        }
    }

    let doc = JSON.obj([
        ("harness", .str("swift")),
        ("language", .str("Swift")),
        ("runtime", .str(runtimeDescription())),
        ("host", hostInfo()),
        ("settings", .obj([
            ("warmup_runs", .int(o.settings.warmupRuns)),
            ("min_runs", .int(o.settings.minRuns)),
            ("min_time_ms", .int(o.settings.minTimeMs)),
            ("max_runs", .int(o.settings.maxRuns)),
            ("timeout_ms", .int(o.settings.timeoutMs)),
        ])),
        ("relay", .str(o.relay)),
        ("corpus_fingerprint", .str(manifest.fingerprint)),
        ("results", .arr(rows)),
    ])
    let dir = (o.out as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    guard FileManager.default.createFile(atPath: o.out, contents: Data(doc.pretty().utf8)) else {
        fatal("cannot write \(o.out)")
    }
    log("wrote \(o.out)")
    exit(0)
}

/// swift/ (holds Package.swift and libs/): from run.sh, or found above the executable.
private func findSwiftDir() -> String {
    if let d = ProcessInfo.processInfo.environment["LIBBENCH_SWIFT_DIR"] { return d }
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("libs").path),
           FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url.path
        }
        url.deleteLastPathComponent()
    }
    return "swift"
}

/// The library's version as pinned in its package's Package.resolved: the release tag, or for
/// a revision pin the client's label (release + short commit).
private func resolvedVersion(_ c: ClientInfo, swiftDir: String) -> String {
    let path = "\(swiftDir)/libs/bench-\(c.package)/Package.resolved"
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pins = obj["pins"] as? [[String: Any]],
          let pin = pins.first(where: { ($0["identity"] as? String)?.lowercased() == c.pin.lowercased() }),
          let state = pin["state"] as? [String: Any] else {
        return c.versionLabel
    }
    if let v = state["version"] as? String { return v }
    if let rev = state["revision"] as? String {
        let short = String(rev.prefix(7))
        return c.versionLabel.hasSuffix(short) ? c.versionLabel : "\(c.versionLabel) (resolved \(short))"
    }
    return c.versionLabel
}
