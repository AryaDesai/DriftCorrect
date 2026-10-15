import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Pixel sample types that the pipeline reads and writes.
public enum SampleType: String, Sendable, Equatable {
    case uint8
    case uint16
    case float32

    public var byteCount: Int {
        switch self {
        case .uint8: return 1
        case .uint16: return 2
        case .float32: return 4
        }
    }

    /// TIFF SampleFormat tag value (1 = unsigned integer, 3 = IEEE float).
    public var tiffSampleFormat: UInt16 { self == .float32 ? 3 : 1 }

    /// OME-XML Pixels@Type value.
    public var omeType: String {
        switch self {
        case .uint8: return "uint8"
        case .uint16: return "uint16"
        case .float32: return "float"
        }
    }

    public init?(omeType: String) {
        switch omeType.lowercased() {
        case "uint8": self = .uint8
        case "uint16": self = .uint16
        case "float", "float32": self = .float32
        default: return nil
        }
    }

    public init?(bitsPerSample: Int, sampleFormat: Int) {
        switch (bitsPerSample, sampleFormat) {
        case (8, 1): self = .uint8
        case (16, 1): self = .uint16
        case (32, 3): self = .float32
        default: return nil
        }
    }
}

/// Page-aligned, manually managed memory.
///
/// Page alignment lets the Metal backend wrap the same memory in an
/// `MTLBuffer` without a copy (unified memory on Apple silicon).
public final class AlignedBuffer: @unchecked Sendable {
    public static let pageSize: Int = Int(getpagesize())

    /// Bytes requested by the caller.
    public let byteCount: Int
    /// Bytes allocated: `byteCount` rounded up to a whole page, at least one page.
    public let capacity: Int
    public let raw: UnsafeMutableRawPointer

    public init(byteCount: Int, zeroed: Bool = false) {
        precondition(byteCount >= 0)
        let page = AlignedBuffer.pageSize
        let cap = max(page, (byteCount + page - 1) / page * page)
        var pointer: UnsafeMutableRawPointer?
        let status = posix_memalign(&pointer, page, cap)
        guard status == 0, let p = pointer else {
            fatalError("posix_memalign failed for \(cap) bytes (status \(status))")
        }
        self.byteCount = byteCount
        self.capacity = cap
        self.raw = p
        if zeroed { memset(p, 0, cap) }
    }

    deinit { free(raw) }

    public func zero() { memset(raw, 0, capacity) }

    public func typed<T>(_ type: T.Type) -> UnsafeMutableBufferPointer<T> {
        UnsafeMutableBufferPointer(start: raw.bindMemory(to: T.self, capacity: byteCount / MemoryLayout<T>.stride),
                                   count: byteCount / MemoryLayout<T>.stride)
    }
}

/// One timepoint of one position: a (C, Z, Y, X) block of samples, C-major.
///
/// Plane (c, z) starts at element `(c * z + z) * y * x`, which is the page
/// order that `save_ome_tiff` writes inside one timepoint.
public struct Volume: @unchecked Sendable {
    public let c: Int
    public let z: Int
    public let y: Int
    public let x: Int
    public let type: SampleType
    public let storage: AlignedBuffer

    public init(c: Int, z: Int, y: Int, x: Int, type: SampleType, zeroed: Bool = false) {
        self.c = c; self.z = z; self.y = y; self.x = x; self.type = type
        self.storage = AlignedBuffer(byteCount: c * z * y * x * type.byteCount, zeroed: zeroed)
    }

    public init(c: Int, z: Int, y: Int, x: Int, type: SampleType, storage: AlignedBuffer) {
        precondition(storage.byteCount >= c * z * y * x * type.byteCount)
        self.c = c; self.z = z; self.y = y; self.x = x; self.type = type
        self.storage = storage
    }

    public var planeElements: Int { y * x }
    public var planeBytes: Int { y * x * type.byteCount }
    public var planeCount: Int { c * z }
    public var elementCount: Int { c * z * y * x }
    public var byteCount: Int { elementCount * type.byteCount }

    public func planeIndex(c ci: Int, z zi: Int) -> Int { ci * z + zi }

    public func planePointer(_ plane: Int) -> UnsafeMutableRawPointer {
        storage.raw + plane * planeBytes
    }

    public func planePointer(c ci: Int, z zi: Int) -> UnsafeMutableRawPointer {
        planePointer(planeIndex(c: ci, z: zi))
    }

    /// Sample `i` of `plane`, converted to Float (exact for uint8/uint16).
    @inline(__always)
    public func sample(plane: Int, index i: Int) -> Float {
        let p = planePointer(plane)
        switch type {
        case .uint8: return Float(p.load(fromByteOffset: i, as: UInt8.self))
        case .uint16: return Float(p.load(fromByteOffset: i * 2, as: UInt16.self))
        case .float32: return p.load(fromByteOffset: i * 4, as: Float.self)
        }
    }

    /// Copy one plane to a Float array (numpy `.astype(np.float32)`).
    public func floatPlane(_ plane: Int) -> [Float] {
        var out = [Float](repeating: 0, count: planeElements)
        let n = planeElements
        let p = planePointer(plane)
        out.withUnsafeMutableBufferPointer { dst in
            switch type {
            case .uint8:
                let s = p.assumingMemoryBound(to: UInt8.self)
                for i in 0..<n { dst[i] = Float(s[i]) }
            case .uint16:
                let s = p.assumingMemoryBound(to: UInt16.self)
                for i in 0..<n { dst[i] = Float(s[i]) }
            case .float32:
                let s = p.assumingMemoryBound(to: Float.self)
                for i in 0..<n { dst[i] = s[i] }
            }
        }
        return out
    }

    /// Max over Z of channel `ci`, as Float (numpy `frame[c].max(axis=0)`).
    public func maxProjectZ(channel ci: Int) -> [Float] {
        var out = floatPlane(planeIndex(c: ci, z: 0))
        let n = planeElements
        if z > 1 {
            out.withUnsafeMutableBufferPointer { dst in
                for zi in 1..<z {
                    let p = planePointer(c: ci, z: zi)
                    switch type {
                    case .uint8:
                        let s = p.assumingMemoryBound(to: UInt8.self)
                        for i in 0..<n { let v = Float(s[i]); if v > dst[i] { dst[i] = v } }
                    case .uint16:
                        let s = p.assumingMemoryBound(to: UInt16.self)
                        for i in 0..<n { let v = Float(s[i]); if v > dst[i] { dst[i] = v } }
                    case .float32:
                        // numpy max propagates NaN; inputs are finite here.
                        let s = p.assumingMemoryBound(to: Float.self)
                        for i in 0..<n { let v = s[i]; if v > dst[i] { dst[i] = v } }
                    }
                }
            }
        }
        return out
    }
}

/// A 2-D float image in row-major (Y, X) order.
public struct Image2D: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "pixel count does not match size")
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: fill, count: width * height))
    }

    public var count: Int { width * height }

    @inline(__always) public subscript(y: Int, x: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// Boolean mask in row-major (Y, X) order.
public struct Mask2D: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bits: [Bool]

    public init(width: Int, height: Int, bits: [Bool]) {
        precondition(bits.count == width * height)
        self.width = width; self.height = height; self.bits = bits
    }

    public init(width: Int, height: Int, fill: Bool = false) {
        self.init(width: width, height: height, bits: [Bool](repeating: fill, count: width * height))
    }

    public var trueCount: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }
    public var any: Bool { bits.contains(true) }
}
