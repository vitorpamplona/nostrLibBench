import Foundation

/// A tiny ordered JSON writer: rows keep HARNESS.md's key order and nulls stay explicit.
public indirect enum JSON {
    case null
    case bool(Bool)
    case int(Int)
    case num(Double)
    case str(String)
    case arr([JSON])
    case obj([(String, JSON)])
    /// Already-serialized JSON text (a row a child wrote), spliced in as is.
    case raw(String)

    public static func opt(_ v: Double?) -> JSON { v.map { .num($0) } ?? .null }
    public static func opt(_ v: Int?) -> JSON { v.map { .int($0) } ?? .null }
    public static func opt(_ v: String?) -> JSON { v.map { .str($0) } ?? .null }

    public func compact() -> String {
        var out = ""
        write(&out, indent: nil, level: 0)
        return out
    }

    public func pretty() -> String {
        var out = ""
        write(&out, indent: "  ", level: 0)
        return out + "\n"
    }

    private func write(_ out: inout String, indent: String?, level: Int) {
        func nl(_ l: Int) {
            if let indent { out += "\n" + String(repeating: indent, count: l) }
        }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .num(let d):
            if d.isFinite {
                if d == d.rounded(), abs(d) < 1e15 { out += String(Int64(d)) + ".0" } else { out += String(d) }
            } else {
                out += "null"
            }
        case .str(let s): JSON.quote(s, into: &out)
        case .raw(let s): out += s
        case .arr(let a):
            if a.isEmpty { out += "[]"; return }
            // Arrays of plain numbers stay on one line.
            let flat = a.allSatisfy { if case .num = $0 { return true }; if case .int = $0 { return true }; return false }
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += flat && indent != nil ? ", " : "," }
                if !flat { nl(level + 1) }
                v.write(&out, indent: indent, level: level + 1)
            }
            if !flat { nl(level) }
            out += "]"
        case .obj(let kv):
            if kv.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (k, v)) in kv.enumerated() {
                if i > 0 { out += "," }
                nl(level + 1)
                JSON.quote(k, into: &out)
                out += indent != nil ? ": " : ":"
                v.write(&out, indent: indent, level: level + 1)
            }
            nl(level)
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
