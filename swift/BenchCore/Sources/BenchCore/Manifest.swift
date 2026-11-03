import Foundation

public struct Workload: Decodable {
    public let name: String
    public let file: String
    public let events: Int
    public let bytes: Int
    public let valid_events: Int
    public let valid_id_xor: String
    public let ambiguous_ids: [String]
    public let expired_ids: [String]?
}

public struct Manifest: Decodable {
    public let fingerprint: String
    public let workloads: [Workload]

    public static func load(_ dir: String) -> Manifest {
        let path = (dir as NSString).appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            fatal("cannot read \(path) (build the corpus with: python3 corpus/prepare.py)")
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            fatal("\(path): \(error)")
        }
    }

    public func select(_ names: [String]) -> [Workload] {
        let names = names.isEmpty ? ["all"] : names
        return names.map { n in
            guard let w = workloads.first(where: { $0.name == n }) else { fatal("unknown workload \"\(n)\"") }
            return w
        }
    }
}

/// A 32-byte event id.
public struct ID32: Hashable {
    public var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0, d: UInt64 = 0
    public init() {}

    /// Parses 64 hex digits (either case); nil if the text is not that.
    public init?<S: Sequence>(hexUTF8 s: S) where S.Element == UInt8 {
        var n = 0
        for ch in s {
            let v: UInt8
            switch ch {
            case 48...57: v = ch - 48
            case 97...102: v = ch - 87
            case 65...70: v = ch - 55
            default: return nil
            }
            if n >= 64 { return nil }
            switch n >> 4 {
            case 0: a = a << 4 | UInt64(v)
            case 1: b = b << 4 | UInt64(v)
            case 2: c = c << 4 | UInt64(v)
            default: d = d << 4 | UInt64(v)
            }
            n += 1
        }
        if n != 64 { return nil }
    }

    public init?(hex: String) {
        self.init(hexUTF8: hex.utf8)
    }

    /// From 32 raw bytes (big-endian words, so `hex` round-trips).
    public init?<C: Collection>(bytes: C) where C.Element == UInt8 {
        guard bytes.count == 32 else { return nil }
        for (i, byte) in bytes.enumerated() {
            switch i >> 3 {
            case 0: a = a << 8 | UInt64(byte)
            case 1: b = b << 8 | UInt64(byte)
            case 2: c = c << 8 | UInt64(byte)
            default: d = d << 8 | UInt64(byte)
            }
        }
    }

    public mutating func xor(_ o: ID32) {
        a ^= o.a; b ^= o.b; c ^= o.c; d ^= o.d
    }

    public var hex: String {
        [a, b, c, d].map { w -> String in
            let s = String(w, radix: 16)
            return String(repeating: "0", count: 16 - s.count) + s
        }.joined()
    }
}

/// What a correct library delivers for a workload (HARNESS.md "Correctness").
public struct Expect {
    public let valid: Int
    public let validXor: ID32
    public let ambiguous: Set<ID32>
    public let expired: Set<ID32>
    public let expiredXor: ID32

    public init(_ w: Workload) throws {
        struct BadID: Error, CustomStringConvertible { let description: String }
        guard let vx = ID32(hex: w.valid_id_xor) else { throw BadID(description: "bad valid_id_xor in manifest") }
        valid = w.valid_events
        validXor = vx
        var amb = Set<ID32>()
        for s in w.ambiguous_ids {
            guard let id = ID32(hex: s) else { throw BadID(description: "bad ambiguous id \(s)") }
            amb.insert(id)
        }
        var exp = Set<ID32>()
        var ex = ID32()
        for s in w.expired_ids ?? [] {
            guard let id = ID32(hex: s) else { throw BadID(description: "bad expired id \(s)") }
            exp.insert(id)
            ex.xor(id)
        }
        ambiguous = amb
        expired = exp
        expiredXor = ex
    }

    /// The most events a correct library can deliver: every valid one plus every ambiguous one.
    public var full: Int { valid + ambiguous.count }

    public func ok(_ r: RunResult) -> Bool {
        let nExp = expired.count
        if r.expired != 0 && r.expired != nExp { return false }
        if r.accepted != valid - nExp + r.expired + r.ambiguous { return false }
        var want = validXor
        if r.expired == 0 { want.xor(expiredXor) }
        want.xor(r.ambiguousXor)
        return want == r.xor
    }
}
