import Foundation
import XCTest
@testable import DCCore

/// Loads the reference data written by scripts/make_reference.py.
enum Ref {
    static let root: URL = {
        let base = Bundle.module.resourceURL!
        let candidates = [base.appendingPathComponent("Resources/reference"), base.appendingPathComponent("reference")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }()

    static let manifest: [String: Any] = {
        let data = try! Data(contentsOf: root.appendingPathComponent("manifest.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    static func cases(_ key: String) -> [[String: Any]] { (manifest[key] as? [[String: Any]]) ?? [] }
    static func dict(_ key: String) -> [String: Any] { (manifest[key] as? [String: Any]) ?? [:] }
    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    static func shape(_ d: Any?) -> [Int] { ((d as! [String: Any])["shape"] as! [NSNumber]).map { $0.intValue } }

    static func raw(_ d: Any?) -> (Data, String, [Int]) {
        let desc = d as! [String: Any]
        let data = try! Data(contentsOf: root.appendingPathComponent(desc["file"] as! String))
        return (data, desc["dtype"] as! String, shape(d))
    }

    static func load<T>(_ d: Any?, as type: T.Type) -> [T] {
        let (data, _, _) = raw(d)
        return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    static func floats(_ d: Any?) -> [Float] {
        let (_, dtype, _) = raw(d)
        switch dtype {
        case "float32": return load(d, as: Float.self)
        case "float64": return load(d, as: Double.self).map { Float($0) }
        case "uint16": return load(d, as: UInt16.self).map { Float($0) }
        case "uint8": return load(d, as: UInt8.self).map { Float($0) }
        default: fatalError("unsupported dtype \(dtype)")
        }
    }

    static func doubles(_ d: Any?) -> [Double] {
        let (_, dtype, _) = raw(d)
        return dtype == "float64" ? load(d, as: Double.self) : floats(d).map { Double($0) }
    }

    static func image(_ d: Any?) -> Image2D {
        let s = shape(d)
        return Image2D(width: s[1], height: s[0], pixels: floats(d))
    }

    static func bools(_ d: Any?) -> [Bool] { load(d, as: UInt8.self).map { $0 != 0 } }

    /// A (C, Z, Y, X) uint16 volume.
    static func volume(_ d: Any?) -> Volume {
        let s = shape(d)
        let v = Volume(c: s[0], z: s[1], y: s[2], x: s[3], type: .uint16)
        let values = load(d, as: UInt16.self)
        values.withUnsafeBytes { v.storage.raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return v
    }

    static func uint16s(_ v: Volume) -> [UInt16] {
        Array(UnsafeBufferPointer(start: v.storage.raw.assumingMemoryBound(to: UInt16.self), count: v.elementCount))
    }

    static func num(_ v: Any?) -> Double { (v as! NSNumber).doubleValue }
    static func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }
}

func bitsEqual(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
}
