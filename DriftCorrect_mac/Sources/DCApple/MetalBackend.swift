#if canImport(Metal)
import Foundation
import Metal
import DCCore

/// GPU implementation of `ComputeBackend` for Apple silicon.
///
/// - Frames use unified memory: a `Volume`'s page-aligned storage is wrapped
///   in an `MTLBuffer` without a copy, and shift output is written straight
///   into the result volume's storage.
/// - The Gaussian is separable (2 passes of 2r+1 taps), not a full 2-D
///   (2r+1)² kernel as in the Python GPU path.
/// - Thread safe: every call encodes its own command buffer.
public final class MetalBackend: ComputeBackend {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    public var name: String { "Metal (\(device.name))" }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device = device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        // Float-float arithmetic needs IEEE-exact float operations.
        if #available(macOS 15.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        guard let library = try? device.makeLibrary(source: metalSource, options: options) else { return nil }
        let names = ["max_project_u16", "max_project_u8", "max_project_f32", "gaussian_pass",
                     "shift_bilinear_u16", "shift_bilinear_f32", "shift_bilinear_u8",
                     "shift_integer_u16", "shift_integer_f32", "shift_integer_u8"]
        for n in names {
            guard let f = library.makeFunction(name: n),
                  let p = try? device.makeComputePipelineState(function: f) else { return nil }
            pipelines[n] = p
        }
    }

    /// Metal on Apple silicon when available, else the CPU reference.
    public static func best() -> ComputeBackend { MetalBackend() ?? CPUBackend() }

    // MARK: Buffers

    /// Wrap page-aligned volume storage without copying.
    private func wrap(_ storage: AlignedBuffer) throws -> MTLBuffer {
        guard let b = device.makeBuffer(bytesNoCopy: storage.raw, length: storage.capacity,
                                        options: .storageModeShared, deallocator: nil) else {
            throw DCError("Metal: cannot map \(storage.capacity) bytes")
        }
        return b
    }

    private func buffer(_ floats: [Float]) throws -> MTLBuffer {
        guard let b = floats.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max(4, $0.count), options: .storageModeShared) }) else {
            throw DCError("Metal: cannot allocate buffer")
        }
        return b
    }

    private func buffer(length: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared) else {
            throw DCError("Metal: cannot allocate \(length) bytes")
        }
        return b
    }

    private func floats(_ b: MTLBuffer, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: count))
    }

    private func run(_ encode: (MTLComputeCommandEncoder) throws -> Void) throws {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw DCError("Metal: cannot create a command buffer")
        }
        try encode(enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw DCError("Metal: \(e.localizedDescription)") }
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ name: String, width: Int, height: Int = 1, depth: Int = 1) {
        let p = pipelines[name]!
        enc.setComputePipelineState(p)
        let w = p.threadExecutionWidth
        let h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        let tg = height > 1 ? MTLSize(width: w, height: h, depth: 1) : MTLSize(width: min(p.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: depth), threadsPerThreadgroup: tg)
    }

    private func suffix(_ t: SampleType) -> String {
        switch t { case .uint16: return "u16"; case .uint8: return "u8"; case .float32: return "f32" }
    }

    // MARK: ComputeBackend

    public func maxProjectZ(_ frame: Volume, channel: Int) throws -> Image2D {
        let src = try wrap(frame.storage)
        let dst = try buffer(length: frame.planeElements * 4)
        struct P { var planeElements: UInt32; var zCount: UInt32; var firstPlane: UInt32 }
        var p = P(planeElements: UInt32(frame.planeElements), zCount: UInt32(frame.z),
                  firstPlane: UInt32(frame.planeIndex(c: channel, z: 0)))
        try run { enc in
            enc.setBuffer(src, offset: 0, index: 0)
            enc.setBuffer(dst, offset: 0, index: 1)
            enc.setBytes(&p, length: MemoryLayout<P>.size, index: 2)
            dispatch(enc, "max_project_\(suffix(frame.type))", width: frame.planeElements)
        }
        return Image2D(width: frame.x, height: frame.y, pixels: floats(dst, count: frame.planeElements))
    }

    public func maxProjectAll(_ frame: Volume) throws -> [Image2D] {
        let src = try wrap(frame.storage)
        let n = frame.planeElements
        let dst = try buffer(length: n * 4 * frame.c)
        struct P { var planeElements: UInt32; var zCount: UInt32; var firstPlane: UInt32 }
        try run { enc in
            for c in 0..<frame.c {
                var p = P(planeElements: UInt32(n), zCount: UInt32(frame.z), firstPlane: UInt32(frame.planeIndex(c: c, z: 0)))
                enc.setBuffer(src, offset: 0, index: 0)
                enc.setBuffer(dst, offset: c * n * 4, index: 1)
                enc.setBytes(&p, length: MemoryLayout<P>.size, index: 2)
                dispatch(enc, "max_project_\(suffix(frame.type))", width: n)
            }
        }
        let all = dst.contents().assumingMemoryBound(to: Float.self)
        return (0..<frame.c).map { c in
            Image2D(width: frame.x, height: frame.y, pixels: Array(UnsafeBufferPointer(start: all + c * n, count: n)))
        }
    }

    public func gaussian(_ image: Image2D, sigma: Double) throws -> Image2D {
        if sigma <= 1e-15 || image.count == 0 { return image }
        let (weights, radius) = Gaussian.kernel(sigma: sigma)
        let w = weights.map { d -> SIMD2<Float> in
            let hi = Float(d)
            return SIMD2<Float>(hi, Float(d - Double(hi)))
        }
        let a = try buffer(image.pixels)
        let b = try buffer(length: image.count * 4)
        let c = try buffer(length: image.count * 4)
        struct P { var width: UInt32; var height: UInt32; var radius: Int32; var alongY: UInt32 }
        var pY = P(width: UInt32(image.width), height: UInt32(image.height), radius: Int32(radius), alongY: 1)
        var pX = P(width: UInt32(image.width), height: UInt32(image.height), radius: Int32(radius), alongY: 0)
        let wBuffer = try w.withUnsafeBytes { raw -> MTLBuffer in
            guard let buf = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) else {
                throw DCError("Metal: cannot allocate weights")
            }
            return buf
        }
        try run { enc in
            // Axis 0 (along Y), then axis 1 (along X), as scipy does.
            enc.setBuffer(a, offset: 0, index: 0)
            enc.setBuffer(b, offset: 0, index: 1)
            enc.setBuffer(wBuffer, offset: 0, index: 2)
            enc.setBytes(&pY, length: MemoryLayout<P>.size, index: 3)
            dispatch(enc, "gaussian_pass", width: image.width, height: image.height)
            enc.memoryBarrier(scope: .buffers)
            enc.setBuffer(b, offset: 0, index: 0)
            enc.setBuffer(c, offset: 0, index: 1)
            enc.setBytes(&pX, length: MemoryLayout<P>.size, index: 3)
            dispatch(enc, "gaussian_pass", width: image.width, height: image.height)
        }
        return Image2D(width: image.width, height: image.height, pixels: floats(c, count: image.count))
    }

    /// Interpolation table of one axis (computed in float64 as scipy does).
    struct AxisEntry {
        var i0: Int32; var i1: Int32; var valid: Int32; var pad: Int32
        var w0: SIMD2<Float>; var w1: SIMD2<Float>
    }

    static func split(_ d: Double) -> SIMD2<Float> {
        let hi = Float(d)
        return SIMD2<Float>(hi, Float(d - Double(hi)))
    }

    static func axisTable(count n: Int, shift: Double) -> [AxisEntry] {
        (0..<n).map { i in
            let c = Double(i) - shift
            if c < 0 || c > Double(n - 1) {
                return AxisEntry(i0: 0, i1: 0, valid: 0, pad: 0, w0: .zero, w1: .zero)
            }
            let i0 = Int(c.rounded(.down))
            let t = c - Double(i0)
            return AxisEntry(i0: Int32(i0), i1: Int32(min(i0 + 1, n - 1)), valid: 1, pad: 0,
                             w0: split(1.0 - t), w1: split(t))
        }
    }

    public func shift(_ frame: Volume, pad: Padding, dy: Double, dx: Double, mode: ShiftMode) throws -> Volume {
        let H = frame.y + pad.top + pad.bottom, W = frame.x + pad.left + pad.right
        let out = Volume(c: frame.c, z: frame.z, y: H, x: W, type: .uint16)
        let src = try wrap(frame.storage)
        let dst = try wrap(out.storage)
        struct P {
            var outW: UInt32; var outH: UInt32; var srcW: UInt32; var srcH: UInt32
            var padTop: Int32; var padLeft: Int32; var iy: Int32; var ix: Int32; var planes: UInt32
        }
        var p = P(outW: UInt32(W), outH: UInt32(H), srcW: UInt32(frame.x), srcH: UInt32(frame.y),
                  padTop: Int32(pad.top), padLeft: Int32(pad.left),
                  iy: Int32(Shift.pyRound(dy)), ix: Int32(Shift.pyRound(dx)), planes: UInt32(frame.planeCount))
        let kind = suffix(frame.type)
        switch mode {
        case .integer:
            try run { enc in
                enc.setBuffer(src, offset: 0, index: 0)
                enc.setBuffer(dst, offset: 0, index: 1)
                enc.setBytes(&p, length: MemoryLayout<P>.size, index: 4)
                dispatch(enc, "shift_integer_\(kind)", width: W, height: H, depth: frame.planeCount)
            }
        case .subpixel:
            let rows = MetalBackend.axisTable(count: H, shift: dy)
            let cols = MetalBackend.axisTable(count: W, shift: dx)
            let rb = try rows.withUnsafeBytes { r -> MTLBuffer in
                guard let b = device.makeBuffer(bytes: r.baseAddress!, length: r.count, options: .storageModeShared) else { throw DCError("Metal: table") }
                return b
            }
            let cb = try cols.withUnsafeBytes { r -> MTLBuffer in
                guard let b = device.makeBuffer(bytes: r.baseAddress!, length: r.count, options: .storageModeShared) else { throw DCError("Metal: table") }
                return b
            }
            try run { enc in
                enc.setBuffer(src, offset: 0, index: 0)
                enc.setBuffer(dst, offset: 0, index: 1)
                enc.setBuffer(rb, offset: 0, index: 2)
                enc.setBuffer(cb, offset: 0, index: 3)
                enc.setBytes(&p, length: MemoryLayout<P>.size, index: 4)
                dispatch(enc, "shift_bilinear_\(kind)", width: W, height: H, depth: frame.planeCount)
            }
        }
        return out
    }
}
#endif
