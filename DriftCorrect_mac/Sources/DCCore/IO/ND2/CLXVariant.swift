import Foundation

/// Decoded ND2 metadata value (CLX Lite variant or CLX XML variant).
public indirect enum CLXValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case bytes([UInt8])
    case dict(CLXDict)
    case list([CLXValue])

    public subscript(key: String) -> CLXValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var dict: CLXDict? { if case .dict(let d) = self { return d }; return nil }

    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .uint(let v): return Double(v)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .uint(let v): return Int(truncatingIfNeeded: v)
        case .double(let v): return v.isFinite ? Int(v) : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Python truthiness.
    public var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .int(let v): return v != 0
        case .uint(let v): return v != 0
        case .double(let v): return v != 0
        case .string(let s): return !s.isEmpty
        case .bytes(let b): return !b.isEmpty
        case .dict(let d): return !d.isEmpty
        case .list(let l): return !l.isEmpty
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
}

/// Insertion-ordered dictionary (Python dict semantics).
public struct CLXDict: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var storage: [String: CLXValue] = [:]

    public init() {}

    public subscript(key: String) -> CLXValue? {
        get { storage[key] }
        set {
            if let v = newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = v
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var values: [CLXValue] { keys.compactMap { storage[$0] } }
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
}

/// Port of `nd2._parse._clx_lite.json_from_clx_lite_variant` (strip_prefix=False).
public enum CLXLite {
    enum T {
        static let bool = 1, int32 = 2, uint32 = 3, int64 = 4, uint64 = 5, double = 6
        static let voidPointer = 7, string = 8, byteArray = 9, deprecated = 10, level = 11, compress = 76
    }

    public static func decode(_ data: [UInt8]) throws -> CLXDict {
        var r = ByteReader(data)
        return try decode(&r, count: 1)
    }

    static func decode(_ r: inout ByteReader, count: Int) throws -> CLXDict {
        var output = CLXDict()
        var listItems: [CLXValue]? = nil  // values stored under the empty key
        if r.remaining == 0 { return output }
        for _ in 0..<count {
            let recordStart = r.pos
            if r.remaining < 2 { break }
            let dataType = Int(try r.readU8())
            let nameLength = Int(try r.readU8())
            if dataType == T.deprecated || dataType == 0 {
                throw DCError("Unknown data type in ND2 metadata header: \(dataType)")
            }
            var name = ""
            if dataType != T.compress {
                let raw = try r.readBytes(nameLength * 2)
                name = decodeUTF16(raw)
                if !name.isEmpty { name.removeLast() }  // drop the trailing NUL
            }

            if dataType == T.compress {
                _ = try r.readBytes(10)
                let rest = try r.readBytes(r.remaining)
                let inflated = try Decompress.zlib(rest, expected: rest.count * 4)
                return try decode(inflated)
            }

            var value: CLXValue
            switch dataType {
            case T.level:
                let itemCount = Int(try r.readU32())
                let length = Int(try r.readU64())
                let consumed = r.pos - recordStart
                let inner = try r.readBytes(max(0, length - consumed))
                var ir = ByteReader(inner)
                let val = try decode(&ir, count: itemCount)
                _ = try? r.readBytes(min(itemCount * 8, r.remaining))
                if val.count == 1, val.keys[0] == "" {
                    var items: [CLXValue]
                    if case .list(let l) = val[""]! { items = l } else { items = [val[""]!] }
                    var indexed = CLXDict()
                    for (n, x) in items.enumerated() { indexed[String(format: "i%010d", n)] = x }
                    value = .dict(indexed)
                } else {
                    value = .dict(val)
                }
            case T.byteArray:
                let size = Int(try r.readU64())
                let raw = try r.readBytes(size)
                value = .bytes(raw)
                if startsWithCLXHeader(raw), let nested = try? decode(raw), !nested.isEmpty {
                    value = .dict(nested)
                }
            case T.bool: value = .bool(try r.readU8() != 0)
            case T.int32: value = .int(Int64(try r.readI32()))
            case T.uint32: value = .uint(UInt64(try r.readU32()))
            case T.int64: value = .int(try r.readI64())
            case T.uint64, T.voidPointer: value = .uint(try r.readU64())
            case T.double: value = .double(try r.readF64())
            case T.string: value = .string(readString(&r))
            default: value = .bytes([])
            }

            if name == "" && (output[""] != nil || listItems != nil) {
                if listItems == nil { listItems = [output[""]!] }
                listItems!.append(value)
                output[""] = .list(listItems!)
            } else {
                output[name] = value
            }
        }
        return output
    }

    static func startsWithCLXHeader(_ data: [UInt8]) -> Bool {
        if data.count < 4 { return false }
        let t = Int(data[0]), n = Int(data[1])
        if t == T.compress { return true }
        return (1...11).contains(t) && n >= 2
    }

    static func readString(_ r: inout ByteReader) -> String {
        var raw = [UInt8]()
        while r.remaining >= 2 {
            let a = r.bytes[r.pos], b = r.bytes[r.pos + 1]
            r.pos += 2
            if a == 0 && b == 0 { break }
            raw.append(a); raw.append(b)
        }
        return decodeUTF16(raw)
    }

    static func decodeUTF16(_ raw: [UInt8]) -> String {
        var units = [UInt16]()
        units.reserveCapacity(raw.count / 2)
        var i = 0
        while i + 1 < raw.count { units.append(UInt16(raw[i]) | UInt16(raw[i + 1]) << 8); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Port of `nd2._parse._clx_xml.json_from_clx_variant` (strip_prefix=False), for ND2 v2 files.
public enum CLXXML {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    }

    final class Builder: NSObject, XMLParserDelegate {
        var stack: [Node] = []
        var root: Node?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let n = Node(name: elementName, attributes: attributes)
            stack.last?.children.append(n)
            if stack.isEmpty { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }

    public static func decode(_ data: [UInt8]) throws -> CLXValue {
        var bytes = data
        if let s = String(bytes: bytes.prefix(5), encoding: .utf8), s == "<?xml",
           let end = firstIndex(of: Array("?>".utf8), in: bytes) {
            bytes = Array(bytes[(end + 2)...])
        }
        let parser = XMLParser(data: Data(bytes))
        let b = Builder()
        parser.delegate = b
        if !parser.parse() || b.root == nil {
            // Retry after dropping invalid UTF-8.
            let text = String(decoding: bytes, as: UTF8.self)
            let p2 = XMLParser(data: Data(text.utf8))
            let b2 = Builder()
            p2.delegate = b2
            _ = p2.parse()
            guard let root = b2.root else { throw DCError("Cannot parse ND2 XML metadata") }
            return finish(root)
        }
        return finish(b.root!)
    }

    static func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        if needle.isEmpty || hay.count < needle.count { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<i + needle.count]) == needle { return i }
        }
        return nil
    }

    static func finish(_ root: Node) -> CLXValue {
        let isLegacy = root.attributes["_VERSION"] == "1.000000"
        let (name, value) = nodeValue(root, includeAttrs: isLegacy)
        var val = value
        if case .dict(let d) = val, d.count == 1, d.keys[0] == "i0000000000" { val = d["i0000000000"]! }
        if name == "variant" { return val }
        var wrapper = CLXDict()
        wrapper[name] = val
        return .dict(wrapper)
    }

    static let listNames: Set<String> = ["no_name", "", "BinaryItem", "TextInfoItem", "Wavelength", "MinSrc", "MaxSrc"]

    static func nodeValue(_ node: Node, includeAttrs: Bool) -> (String, CLXValue) {
        let name = node.name
        if let runtype = node.attributes["runtype"], let cast = castValue(runtype, node.attributes["value"]) {
            return (name, cast)
        }
        var out = CLXDict()
        if includeAttrs { for (k, v) in node.attributes.sorted(by: { $0.key < $1.key }) { out[k] = .string(v) } }
        for (i, child) in node.children.enumerated() {
            var (cname, cval) = nodeValue(child, includeAttrs: includeAttrs)
            if listNames.contains(cname) {
                if !cval.truthy { continue }
                cname = String(format: "i%010d", i)
            }
            out[cname] = cval
        }
        return (name, .dict(out))
    }

    static func castValue(_ runtype: String, _ value: String?) -> CLXValue? {
        let v = value ?? ""
        switch runtype {
        case "bool": return .bool(["true", "1"].contains(v.lowercased()))
        case "CLxByteArray": return .bytes(Array(v.utf8))
        case "CLxStringW", "unknown": return .string(v)
        case "double", "float": return .double(Double(v) ?? .nan)
        case "lx_int32", "lx_int64": return .int(Int64(v) ?? 0)
        case "lx_uint32", "lx_uint64": return .uint(UInt64(v) ?? 0)
        default: return nil
        }
    }
}
