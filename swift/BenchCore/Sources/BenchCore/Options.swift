import Foundation

/// Run settings (HARNESS.md "Command line").
public struct Settings {
    public var warmupRuns = 2
    public var minRuns = 5
    public var minTimeMs = 10_000
    public var maxRuns = 30
    public var timeoutMs = 300_000
}

/// The command line of both the parent (`libbench`) and the per-library child binaries.
public struct Options {
    public var relay = "ws://127.0.0.1:7777"
    public var corpus = ".corpus"
    public var out = "results/swift.json"
    public var workloads: [String] = []
    public var clients: [String] = []
    public var settings = Settings()
    public var list = false
    public var quick = false
    public var child = false
    public var childOut = ""

    /// The flags a parent passes on to a child, minus --clients / --child / --child-out.
    public var passThrough: [String] = []

    public static func parse(_ args: [String]) -> Options {
        var o = Options()
        var explicit = Set<String>()
        var i = 0
        func value(_ name: String) -> String {
            i += 1
            guard i < args.count else { fatal("\(name) needs a value") }
            return args[i]
        }
        func int(_ name: String) -> Int {
            let v = value(name)
            guard let n = Int(v) else { fatal("\(name): not an integer: \(v)") }
            return n
        }
        while i < args.count {
            var a = args[i]
            // Accept --flag=value as well as --flag value.
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                let v = String(a[a.index(after: eq)...])
                a = String(a[..<eq])
                var rest = Array(args[(i + 1)...])
                rest.insert(v, at: 0)
                return Options.parse(Array(args[..<i]) + [a] + rest)
            }
            switch a {
            case "--relay": o.relay = value(a)
            case "--corpus": o.corpus = value(a)
            case "--out": o.out = value(a)
            case "--workloads": o.workloads = splitList(value(a))
            case "--clients": o.clients = splitList(value(a))
            case "--warmup-runs": o.settings.warmupRuns = int(a); explicit.insert(a)
            case "--min-runs": o.settings.minRuns = int(a); explicit.insert(a)
            case "--min-time-ms": o.settings.minTimeMs = int(a); explicit.insert(a)
            case "--max-runs": o.settings.maxRuns = int(a); explicit.insert(a)
            case "--timeout-ms": o.settings.timeoutMs = int(a)
            case "--quick": o.quick = true
            case "--list": o.list = true
            case "--child": o.child = true
            case "--child-out": o.childOut = value(a)
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                fatal("unknown argument: \(a)\n\(usage)")
            }
            i += 1
        }
        if o.quick {
            if !explicit.contains("--warmup-runs") { o.settings.warmupRuns = 1 }
            if !explicit.contains("--min-runs") { o.settings.minRuns = 2 }
            if !explicit.contains("--min-time-ms") { o.settings.minTimeMs = 0 }
        }
        o.settings.minRuns = max(1, o.settings.minRuns)
        o.settings.maxRuns = max(o.settings.minRuns, o.settings.maxRuns)
        o.settings.warmupRuns = max(0, o.settings.warmupRuns)
        while o.relay.hasSuffix("/") { o.relay.removeLast() }
        o.passThrough = [
            "--relay", o.relay, "--corpus", o.corpus,
            "--workloads", o.workloads.joined(separator: ","),
            "--warmup-runs", String(o.settings.warmupRuns),
            "--min-runs", String(o.settings.minRuns),
            "--min-time-ms", String(o.settings.minTimeMs),
            "--max-runs", String(o.settings.maxRuns),
            "--timeout-ms", String(o.settings.timeoutMs),
        ]
        return o
    }

    static let usage = """
    usage: swift/run.sh [flags]   (see HARNESS.md)
      --relay URL        default ws://127.0.0.1:7777 (the harness appends /<workload>)
      --corpus DIR       default .corpus
      --out FILE         default results/swift.json
      --workloads a,b    default all
      --clients x,y      default: every client (see --list)
      --warmup-runs N    default 2
      --min-runs N       default 5
      --min-time-ms N    default 10000
      --max-runs N       default 30
      --timeout-ms N     per run, default 300000
      --quick            warmup-runs 1, min-runs 2, min-time-ms 0
      --list             print client ids and exit
    """
}

func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

public func fatal(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("libbench: \(msg)\n".utf8))
    exit(2)
}

public func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
