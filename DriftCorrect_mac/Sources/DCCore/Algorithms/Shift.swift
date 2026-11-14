import Foundation

/// The placement of the source frame inside a larger canvas of zeros.
public struct Padding: Equatable, Sendable {
    public var top = 0, bottom = 0, left = 0, right = 0
    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let none = Padding()

    /// Return the padding that keeps every pixel on the canvas when frames of the given size are moved by `transforms`.
    public static func covering(transforms: [Rigid], width: Int, height: Int) -> Padding {
        func up(_ v: Double) -> Int { Int(max(0, v).rounded(.up)) }
        let w = Double(width - 1), h = Double(height - 1)
        var minX = 0.0, maxX = w, minY = 0.0, maxY = h
        for m in transforms {
            for corner in [(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)] {
                let q = m.apply(x: corner.0, y: corner.1)
                minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y)
            }
        }
        return Padding(top: up(-minY), bottom: up(maxY - h), left: up(-minX), right: up(maxX - w))
    }
}

public enum Shift {
    /// Round as `round(x)` does in Python, where a half goes to the even value.
    @inline(__always) public static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// Where one output pixel of a move reads the source. `x0` and `y0` are the upper left of the four source pixels,
    /// and `fx` and `fy` are the fractions toward the next pixel. A pixel that reads nothing has `x0` at `Int32.min`.
    public struct WarpEntry {
        public var x0: Int32, y0: Int32
        public var fx: Float, fy: Float
    }

    /// Work out where every output pixel reads the source when a frame of `width` by `height` pixels is moved by
    /// `transform` onto its canvas plus `pad`. The positions are the same for every plane, so they are worked out
    /// once. The CPU and the GPU both use this table, which keeps their results identical.
    public static func warpTable(width X: Int, height Y: Int, pad: Padding, transform: Rigid) -> [WarpEntry] {
        let H = Y + pad.top + pad.bottom, W = X + pad.left + pad.right
        // Each output pixel reads the source at the position that the opposite transform gives.
        let back = Rigid.shift(dx: Double(pad.left), dy: Double(pad.top)).after(transform).inverse
        var table = [WarpEntry](repeating: WarpEntry(x0: Int32.min, y0: 0, fx: 0, fy: 0), count: W * H)
        table.withUnsafeMutableBufferPointer { out in
            Parallel.forEach(H) { y in
                for x in 0..<W {
                    let s = back.apply(x: Double(x), y: Double(y))
                    if s.x <= -1 || s.y <= -1 || s.x >= Double(X) || s.y >= Double(Y) { continue }
                    let x0 = Int(s.x.rounded(.down)), y0 = Int(s.y.rounded(.down))
                    out[y * W + x] = WarpEntry(x0: Int32(x0), y0: Int32(y0), fx: Float(s.x - Double(x0)), fy: Float(s.y - Double(y0)))
                }
            }
        }
        return table
    }

    /// Move every plane of `frame` by `transform` onto a canvas of the size of `frame` plus `pad`, and convert the
    /// result to uint16. `transform` is in pixels of the frame. Values between pixels are interpolated from the four
    /// nearest pixels, and a pixel outside the frame counts as 0.
    public static func warp(_ frame: Volume, pad: Padding, transform: Rigid) -> Volume {
        let H = frame.y + pad.top + pad.bottom, W = frame.x + pad.left + pad.right
        let X = frame.x, Y = frame.y
        let out = Volume(c: frame.c, z: frame.z, y: H, x: W, type: .uint16)
        let table = warpTable(width: X, height: Y, pad: pad, transform: transform)
        Parallel.forEach(frame.planeCount) { plane in
            let dst = out.planePointer(plane).assumingMemoryBound(to: UInt16.self)
            @inline(__always) func src(_ yy: Int, _ xx: Int) -> Float {
                (yy < 0 || yy >= Y || xx < 0 || xx >= X) ? 0 : frame.sample(plane: plane, index: yy * X + xx)
            }
            for k in 0..<(W * H) {
                let e = table[k]
                if e.x0 == Int32.min { dst[k] = 0; continue }
                let x0 = Int(e.x0), y0 = Int(e.y0)
                // Each sum of two products is written as one product plus a fused multiply and add. The GPU kernel
                // does the same, so that both round in the same places and give the same values.
                let top = (src(y0, x0) * (1 - e.fx)).addingProduct(src(y0, x0 + 1), e.fx)
                let bottom = (src(y0 + 1, x0) * (1 - e.fx)).addingProduct(src(y0 + 1, x0 + 1), e.fx)
                dst[k] = toUInt16((top * (1 - e.fy)).addingProduct(bottom, e.fy).rounded())
            }
        }
        return out
    }

    /// Convert a float32 value to uint16 as `clip(0, 65535).astype(np.uint16)` does.
    @inline(__always) public static func toUInt16(_ v: Float) -> UInt16 {
        if !(v > 0) { return 0 }
        if v >= 65535 { return 65535 }
        return UInt16(v)
    }

    /// Pad a frame onto a larger canvas of zeros without shifting it, as `np.pad` does.
    public static func pad(_ frame: Volume, _ pad: Padding) -> Volume {
        let H = frame.y + pad.top + pad.bottom, W = frame.x + pad.left + pad.right
        let out = Volume(c: frame.c, z: frame.z, y: H, x: W, type: frame.type, zeroed: true)
        let bpp = frame.type.byteCount
        for plane in 0..<frame.planeCount {
            let s = frame.planePointer(plane), d = out.planePointer(plane)
            for y in 0..<frame.y {
                (d + ((y + pad.top) * W + pad.left) * bpp).copyMemory(from: s + y * frame.x * bpp, byteCount: frame.x * bpp)
            }
        }
        return out
    }
}
