import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Monotonic clock in nanoseconds (DispatchTime: mach_absolute_time on macOS,
/// CLOCK_MONOTONIC on Linux).
@inline(__always)
public func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func selfUsage() -> rusage {
    var ru = rusage()
    #if os(Linux)
    _ = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &ru)
    #else
    _ = getrusage(RUSAGE_SELF, &ru)
    #endif
    return ru
}

/// Process CPU time (user + system, every thread) in nanoseconds.
public func cpuNs() -> UInt64 {
    let ru = selfUsage()
    let user = UInt64(ru.ru_utime.tv_sec) * 1_000_000_000 + UInt64(ru.ru_utime.tv_usec) * 1_000
    let sys = UInt64(ru.ru_stime.tv_sec) * 1_000_000_000 + UInt64(ru.ru_stime.tv_usec) * 1_000
    return user + sys
}

/// Peak resident set of this process in MB (MiB). ru_maxrss is bytes on macOS, KiB on Linux.
public func peakRssMb() -> Double {
    let ru = selfUsage()
    #if os(Linux)
    return Double(ru.ru_maxrss) / 1024
    #else
    return Double(ru.ru_maxrss) / (1024 * 1024)
    #endif
}

private func sysctlString(_ name: String) -> String? {
    #if canImport(Darwin)
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
    #else
    return nil
    #endif
}

public func hostInfo() -> JSON {
    var cpu = "unknown"
    #if os(Linux)
    if let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8),
       let line = text.split(separator: "\n").first(where: { $0.hasPrefix("model name") }),
       let colon = line.firstIndex(of: ":") {
        cpu = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    #else
    cpu = sysctlString("machdep.cpu.brand_string") ?? cpu
    #endif
    var u = utsname()
    uname(&u)
    func field<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
    let machine = field(u.machine)
    var os: String
    #if os(macOS)
    let v = ProcessInfo.processInfo.operatingSystemVersion
    os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    if let build = sysctlString("kern.osversion") { os += " (\(build))" }
    os += " \(machine)"
    #else
    os = "\(field(u.sysname)) \(field(u.release)) \(machine)"
    #endif
    return .obj([
        ("cpu", .str(cpu)),
        ("cores", .int(ProcessInfo.processInfo.activeProcessorCount)),
        ("os", .str(os)),
    ])
}

/// "Swift 6.x (...)", from the toolchain run.sh built with (LIBBENCH_SWIFT_VERSION).
public func runtimeDescription() -> String {
    var s = ProcessInfo.processInfo.environment["LIBBENCH_SWIFT_VERSION"] ?? "Swift"
    #if os(macOS)
    s += ", Apple Foundation"
    #else
    s += ", swift-corelibs-foundation"
    #endif
    return s
}
