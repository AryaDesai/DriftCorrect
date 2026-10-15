import Foundation
import Yams

/// Ordered YAML value for writing files in the same style as `yaml.dump(..., default_flow_style=False, sort_keys=False)`.
public indirect enum YAMLValue: Equatable {
    case map([(String, YAMLValue)])
    case seq([YAMLValue])
    case str(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    case null

    public static func == (a: YAMLValue, b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.seq(let x), .seq(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y || (x.isNaN && y.isNaN)
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }
}

public enum YAMLWriter {
    public static func dump(_ value: YAMLValue) -> String {
        var out = ""
        emit(value, indent: 0, into: &out, inSeq: false)
        return out
    }

    private static func pad(_ n: Int) -> String { String(repeating: " ", count: n) }

    private static func isScalar(_ v: YAMLValue) -> Bool {
        switch v {
        case .map(let m): return m.isEmpty
        case .seq(let s): return s.isEmpty
        default: return true
        }
    }

    private static func emit(_ v: YAMLValue, indent: Int, into out: inout String, inSeq: Bool) {
        switch v {
        case .map(let items):
            var first = true
            for (k, value) in items {
                let prefix = (first && inSeq) ? "" : pad(indent)
                first = false
                out += prefix + scalar(.str(k)) + ":"
                if isScalar(value) {
                    out += " " + scalar(value) + "\n"
                } else if case .seq = value {
                    out += "\n"
                    emit(value, indent: indent, into: &out, inSeq: false)  // PyYAML: indentless sequences in mappings
                } else {
                    out += "\n"
                    emit(value, indent: indent + 2, into: &out, inSeq: false)
                }
            }
        case .seq(let items):
            for item in items {
                out += pad(indent) + "-"
                if isScalar(item) {
                    out += " " + scalar(item) + "\n"
                } else if case .map = item {
                    out += " "
                    emit(item, indent: indent + 2, into: &out, inSeq: true)
                } else {
                    out += "\n"
                    emit(item, indent: indent + 2, into: &out, inSeq: false)
                }
            }
        default:
            out += pad(indent) + scalar(v) + "\n"
        }
    }

    static func scalar(_ v: YAMLValue) -> String {
        switch v {
        case .map: return "{}"
        case .seq: return "[]"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .float(let d):
            if d.isNaN { return ".nan" }
            if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
            var s = PyFormat.repr(d).lowercased()
            if !s.contains(".") && s.contains("e") { s = s.replacingOccurrences(of: "e", with: ".0e") }
            return s
        case .str(let s): return quote(s)
        }
    }

    /// Plain when PyYAML would write the string plain, else quoted.
    static func quote(_ s: String) -> String {
        if !s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            var o = "\""
            for u in s.unicodeScalars {
                switch u.value {
                case 0x22: o += "\\\""
                case 0x5C: o += "\\\\"
                case 0x0A: o += "\\n"
                case 0x09: o += "\\t"
                case 0x20..<0x7F: o.unicodeScalars.append(u)
                case 0..<0x100: o += String(format: "\\x%02X", u.value)
                case 0x100..<0x10000: o += String(format: "\\u%04X", u.value)
                default: o += String(format: "\\U%08X", u.value)
                }
            }
            return o + "\""
        }
        if needsQuotes(s) { return "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return s
    }

    static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        let specials: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        if let f = s.first, specials.contains(f) || f == " " {
            // "-", "?", ":" followed by a non-space may be plain (e.g. "-x"), but quoting is always safe.
            return true
        }
        if s.last == " " || s.last == ":" { return true }
        if s.contains(": ") || s.contains(" #") { return true }
        let lower = s.lowercased()
        let reserved: Set<String> = ["yes", "no", "true", "false", "on", "off", "null", "~"]
        if reserved.contains(lower) { return true }
        if Int(s) != nil || Double(s) != nil { return true }
        if s.range(of: #"^[-+]?(0x[0-9a-fA-F_]+|0o?[0-7_]+|0b[01_]+|[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?|\.(inf|Inf|INF|nan|NaN|NAN)|[0-9][0-9_]*\.?[0-9_]*([eE][-+]?[0-9]+)?)$"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}"#, options: .regularExpression) != nil { return true }
        if s == "=" || s == "<<" { return true }
        return false
    }
}

/// Loosely typed view of a YAML document read with Yams.
public enum YAMLReader {
    public static func load(_ text: String) throws -> Any? {
        try Yams.load(yaml: text)
    }

    public static func dict(_ v: Any?) -> [String: Any]? {
        if let d = v as? [String: Any] { return d }
        if let d = v as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (k, value) in d { out["\(k.base)"] = value }
            return out
        }
        return nil
    }

    public static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return d.isFinite ? Int(d) : nil
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    public static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let s as String: return ["true", "yes", "on", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    public static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case nil: return nil
        case is NSNull: return nil
        default: return "\(v!)"
        }
    }

    public static func array(_ v: Any?) -> [Any]? { v as? [Any] }
}
