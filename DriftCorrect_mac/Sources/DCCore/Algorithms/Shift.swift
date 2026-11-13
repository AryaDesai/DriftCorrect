import Foundation

/// Selects how a shift (dy, dx) is applied to the frame.
public enum ShiftMode: String, Sendable, CaseIterable {
    /// The shift is applied with bilinear interpolation, as `scipy.ndimage.shift(order=1, mode="constant", cval=0)`
    /// does. This is what the CPU path of the Python scripts produced.
    case subpixel
    /// The shift is rounded to whole pixels as `round` does in Python, and exposed edges are filled with zeros.
    /// This is what the `--use_gpu` path of the Python scripts produced.
    case integer
}

/// The placement of the source frame inside a larger canvas of zeros.
public struct Padding: Equatable, Sendable {
    public var top = 0, bottom = 0, left = 0, right = 0
    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let none = Padding()

    /// Return the padding that keeps every shifted pixel on the canvas. The top padding is
    /// `ceil(max(0, -min dy))` and the bottom padding is `ceil(max(0, max dy))`. The same holds for x.
    public static func covering(dys: [Double], dxs: [Double]) -> Padding {
        func up(_ v: Double) -> Int { Int(max(0, v).rounded(.up)) }
        return Padding(top: up(-(dys.min() ?? 0)), bottom: up(dys.max() ?? 0),
                       left: up(-(dxs.min() ?? 0)), right: up(dxs.max() ?? 0))
    }

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

    /// Shift every plane of `frame` on a canvas of the size of `frame` plus `pad`, and convert the result to
    /// uint16 with `clip(0, 65535).astype(np.uint16)`. This is the exact CPU reference. It accumulates in double
    /// precision in the order that scipy uses.
    public static func apply(_ frame: Volume, pad: Padding, dy: Double, dx: Double, mode: ShiftMode) -> Volume {
        let H = frame.y + pad.top + pad.bottom
        let W = frame.x + pad.left + pad.right
        let out = Volume(c: frame.c, z: frame.z, y: H, x: W, type: .uint16)
        let planes = frame.planeCount
        Parallel.forEach(planes) { plane in
            let dst = out.planePointer(plane).assumingMemoryBound(to: UInt16.self)
            @inline(__always) func src(_ yy: Int, _ xx: Int) -> Double {
                let sy = yy - pad.top, sx = xx - pad.left
                if sy < 0 || sy >= frame.y || sx < 0 || sx >= frame.x { return 0 }
                return Double(frame.sample(plane: plane, index: sy * frame.x + sx))
            }
            switch mode {
            case .integer:
                let iy = pyRound(dy), ix = pyRound(dx)
                for y in 0..<H {
                    for x in 0..<W {
                        let yy = y - iy, xx = x - ix
                        let v = (yy >= 0 && yy < H && xx >= 0 && xx < W) ? Float(src(yy, xx)) : 0
                        dst[y * W + x] = toUInt16(v)
                    }
                }
            case .subpixel:
                // The shift is the same for every pixel, so the weights are too.
                for y in 0..<H {
                    let cy = Double(y) - dy
                    if cy < 0 || cy > Double(H - 1) {
                        for x in 0..<W { dst[y * W + x] = 0 }
                        continue
                    }
                    let y0 = Int(cy.rounded(.down))
                    let ty = cy - Double(y0)
                    let wy0 = 1.0 - ty, wy1 = ty
                    let y1 = min(y0 + 1, H - 1)
                    for x in 0..<W {
                        let cx = Double(x) - dx
                        if cx < 0 || cx > Double(W - 1) { dst[y * W + x] = 0; continue }
                        let x0 = Int(cx.rounded(.down))
                        let tx = cx - Double(x0)
                        let wx0 = 1.0 - tx, wx1 = tx
                        let x1 = min(x0 + 1, W - 1)
                        var acc = 0.0
                        acc += src(y0, x0) * wy0 * wx0
                        acc += src(y0, x1) * wy0 * wx1
                        acc += src(y1, x0) * wy1 * wx0
                        acc += src(y1, x1) * wy1 * wx1
                        dst[y * W + x] = toUInt16(Float(acc))
                    }
                }
            }
        }
        return out
    }

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
