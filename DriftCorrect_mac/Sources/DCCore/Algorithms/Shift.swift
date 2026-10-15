import Foundation

/// How a computed (dy, dx) is applied to the frame.
public enum ShiftMode: String, Sendable, CaseIterable {
    /// `scipy.ndimage.shift(order=1, mode="constant", cval=0)`: sub-pixel bilinear.
    /// This is what the Python CPU path produced.
    case subpixel
    /// Shift rounded to whole pixels (Python's `round`), zeros at exposed edges.
    /// This is what the Python `--use_gpu` path produced.
    case integer
}

/// Placement of the source frame inside a larger zero canvas (two-pass canvas expansion).
public struct Padding: Equatable, Sendable {
    public var top = 0, bottom = 0, left = 0, right = 0
    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let none = Padding()

    /// Padding that keeps every shifted pixel on the canvas:
    /// `pad_top = ceil(max(0, -min dy))`, `pad_bottom = ceil(max(0, max dy))`, same for x.
    public static func covering(dys: [Double], dxs: [Double]) -> Padding {
        func up(_ v: Double) -> Int { Int(max(0, v).rounded(.up)) }
        return Padding(top: up(-(dys.min() ?? 0)), bottom: up(dys.max() ?? 0),
                       left: up(-(dxs.min() ?? 0)), right: up(dxs.max() ?? 0))
    }
}

public enum Shift {
    /// Python `round(x)` (half to even).
    @inline(__always) public static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// Shift every plane of `frame` on a canvas of `frame` size plus `pad`, and
    /// convert to uint16 with `clip(0, 65535).astype(np.uint16)`.
    ///
    /// Exact CPU reference: double accumulation in scipy's order.
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

    /// `clip(0, 65535).astype(np.uint16)` for a float32 value.
    @inline(__always) public static func toUInt16(_ v: Float) -> UInt16 {
        if !(v > 0) { return 0 }
        if v >= 65535 { return 65535 }
        return UInt16(v)
    }

    /// Pad a frame onto a larger zero canvas without shifting (`np.pad`).
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
