import Foundation

/// Which pixels z correction looks at.
public enum ZRegion: Equatable, Sendable {
    /// Everything that holds data.
    case wholeFrame
    /// The embryo mask from the threshold YAML (the mask xy alignment uses).
    case embryoMask
    /// A box over cells that should stay still, in pixels of the reference timepoint before xy alignment.
    case box(x: Int, y: Int, width: Int, height: Int)
}

/// A box in pixels of the xy-centred frame.
public struct ZBox: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// What z correction keeps of one timepoint: a small copy of the detection channel and its nucleus centres.
public struct ZDescriptor: @unchecked Sendable {
    public let z: Int
    /// Size of the 4x-binned planes.
    public let h: Int, w: Int
    let planes: [Float]
    let valid: [Bool]
    let region: [Bool]
    /// 16x-binned copy for the coarse xy search.
    let ch: Int, cw: Int
    let coarse: [Float]
    let coarseValid: [Bool]
    let coarseRegion: [Bool]
    /// Nucleus centres inside the region: z in slices (fractional), y and x in 2x-binned pixels.
    let nz: [Float], ny: [Float], nx: [Float]
    let umPerPixel2: Double
    public var nucleusCount: Int { nz.count }
}

/// The measured z movement between two consecutive timepoints.
public struct ZStep: Sendable {
    /// Slices the tissue moved since the previous timepoint (+ = toward a higher slice index). The value used.
    public var dz = 0.0
    /// Estimate from the recorded stage positions.
    public var stage: Double?
    /// Estimate from comparing the images slice by slice.
    public var image: Double?
    /// Estimate from matching individual nuclei.
    public var nuclei: Double?
    /// Image mismatch at the best offset (0 = identical, 1 = nothing in common).
    public var cost = Double.nan
    /// Nuclei that agree on the movement, and their share of all nuclei in the region.
    public var agreeing = 0
    public var share = 0.0
    /// Empty when the estimate is trusted; otherwise why it is not.
    public var flag = ""
    public init() {}
}

/// Whole-slice shifts for every timepoint and the empty slices to add.
public struct ZPlan: Equatable, Sendable {
    /// Tissue position relative to the reference timepoint, in slices (fractional).
    public var position: [Double]
    /// Slices to move each timepoint by. Output slice = input slice + shift + padLow.
    public var shift: [Int]
    public var padLow: Int
    public var padHigh: Int
}

/// Z-drift measurement and correction.
///
/// Each timepoint is compared with the previous one, after xy alignment:
/// 1. The stage z recorded by the microscope gives the starting estimate (this covers a pause where the
///    operator re-centred the embryo, even when the two stacks no longer overlap).
/// 2. The images are compared slice by slice at every candidate offset, with a small xy search, using the
///    sum of absolute differences (not cross-correlation).
/// 3. Nucleus centres are matched between the two timepoints; when enough of them agree, the median of their
///    z movements replaces the image estimate.
/// The correction moves whole slices and fills the gaps with empty slices; nothing is interpolated.
public enum ZDrift {
    static let imageWindow = 8          // slices searched around the stage estimate
    static let weakCost = 0.27          // image mismatch above this is not trusted without nuclei
    static let minAgreeing = 10         // a drawn box may hold only a few cells
    static let minShare = 0.3

    // MARK: Descriptor

    public static func describe(frame: Volume, channel: Int, shift: (dy: Int, dx: Int) = (0, 0), mask: Mask2D? = nil,
                                box: ZBox? = nil, pixelSizeUm: Double? = nil, detectNuclei: Bool = true) -> ZDescriptor {
        let Z = frame.z, Y = frame.y, X = frame.x
        let h2 = Y / 2, w2 = X / 2, n2 = h2 * w2
        let h4 = h2 / 2, w4 = w2 / 2, n4 = h4 * w4
        let dy = shift.dy, dx = shift.dx

        // 2x-binned copy of the detection channel, moved by the whole-pixel xy shift. Pixels without data stay 0.
        let b2 = UnsafeMutablePointer<Float>.allocate(capacity: max(1, Z * n2))
        b2.initialize(repeating: 0, count: max(1, Z * n2))
        defer { b2.deallocate() }
        let yLo = max(0, Int((Double(dy) / 2).rounded(.up))), yHi = min(h2 - 1, Int((Double(Y - 2 + dy) / 2).rounded(.down)))
        let xLo = max(0, Int((Double(dx) / 2).rounded(.up))), xHi = min(w2 - 1, Int((Double(X - 2 + dx) / 2).rounded(.down)))
        if yLo <= yHi && xLo <= xHi {
            Parallel.forEach(Z) { zi in
                let plane = frame.planeIndex(c: channel, z: zi)
                let dst = b2 + zi * n2
                for y2 in yLo...yHi {
                    let r0 = (2 * y2 - dy) * X, r1 = r0 + X
                    for x2 in xLo...xHi {
                        let s = 2 * x2 - dx
                        let v = frame.sample(plane: plane, index: r0 + s) + frame.sample(plane: plane, index: r0 + s + 1)
                            + frame.sample(plane: plane, index: r1 + s) + frame.sample(plane: plane, index: r1 + s + 1)
                        dst[y2 * w2 + x2] = v * 0.25
                    }
                }
            }
        }

        // 4x-binned planes.
        var p4 = [Float](repeating: 0, count: Z * n4)
        var valid4 = [Bool](repeating: false, count: n4)
        if n4 > 0 {
            p4.withUnsafeMutableBufferPointer { out in
                Parallel.forEach(Z) { zi in
                    let src = b2 + zi * n2
                    for y in 0..<h4 {
                        for x in 0..<w4 {
                            let i = (2 * y) * w2 + 2 * x
                            out[zi * n4 + y * w4 + x] = (src[i] + src[i + 1] + src[i + w2] + src[i + w2 + 1]) * 0.25
                        }
                    }
                }
            }
            for zi in 0..<Z { for i in 0..<n4 where p4[zi * n4 + i] > 0 { valid4[i] = true } }
            // Remove the background level (5th percentile of the data), then smooth lightly in xy.
            var sample: [Float] = []
            let stride4 = max(1, Z * n4 / 200_000)
            var i = 0
            while i < Z * n4 { if p4[i] > 0 { sample.append(p4[i]) }; i += stride4 }
            sample.sort()
            let bg = sample.isEmpty ? 0 : sample[Int(0.05 * Double(sample.count - 1))]
            p4.withUnsafeMutableBufferPointer { out in
                Parallel.forEach(Z) { zi in
                    let p = out.baseAddress! + zi * n4
                    for i in 0..<n4 { p[i] = max(0, p[i] - bg) }
                    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n4)
                    blur(p, into: p, w: w4, h: h4, sigma: 1.0, scratch: tmp)
                    tmp.deallocate()
                }
            }
        }

        // Region at 4x binning, in xy-centred coordinates.
        var region4 = [Bool](repeating: mask == nil && box == nil, count: n4)
        if let m = mask, n4 > 0 {
            for sy in 0..<min(m.height, Y) {
                let cy = (sy + dy) / 4
                if sy + dy < 0 || cy >= h4 { continue }
                for sx in 0..<min(m.width, X) where m.bits[sy * m.width + sx] {
                    let cx = (sx + dx) / 4
                    if sx + dx >= 0 && cx < w4 { region4[cy * w4 + cx] = true }
                }
            }
            region4 = dilate(region4, w: w4, h: h4, radius: 3)
        } else if let b = box, n4 > 0 {
            let y0 = max(0, b.y / 4), y1 = min(h4, (b.y + b.height + 3) / 4)
            let x0 = max(0, b.x / 4), x1 = min(w4, (b.x + b.width + 3) / 4)
            if y0 < y1 && x0 < x1 { for y in y0..<y1 { for x in x0..<x1 { region4[y * w4 + x] = true } } }
        }

        // 16x-binned copy for the coarse xy search.
        let ch = h4 / 4, cw = w4 / 4, nc = ch * cw
        var coarse = [Float](repeating: 0, count: Z * nc)
        var coarseValid = [Bool](repeating: false, count: nc), coarseRegion = [Bool](repeating: false, count: nc)
        if nc > 0 {
            for y in 0..<ch {
                for x in 0..<cw {
                    var nv = 0, nr = 0
                    for j in 0..<4 { for i in 0..<4 {
                        let k = (4 * y + j) * w4 + 4 * x + i
                        if valid4[k] { nv += 1 }
                        if region4[k] { nr += 1 }
                    } }
                    coarseValid[y * cw + x] = nv == 16
                    coarseRegion[y * cw + x] = nr >= 8
                }
            }
            coarse.withUnsafeMutableBufferPointer { out in
                p4.withUnsafeBufferPointer { src in
                    Parallel.forEach(Z) { zi in
                        for y in 0..<ch { for x in 0..<cw {
                            var s: Float = 0
                            for j in 0..<4 { for i in 0..<4 { s += src[zi * n4 + (4 * y + j) * w4 + 4 * x + i] } }
                            out[zi * nc + y * cw + x] = s / 16
                        } }
                    }
                }
            }
        }

        // Nucleus centres.
        let known = (pixelSizeUm ?? 1) > 0 && pixelSizeUm != nil && pixelSizeUm != 1
        let um2 = known ? 2 * pixelSizeUm! : 0.86
        var nzs: [Float] = [], nys: [Float] = [], nxs: [Float] = []
        if detectNuclei && Z >= 1 && h2 >= 16 && w2 >= 16 {
            (nzs, nys, nxs) = detectNuclei2(b2, z: Z, h: h2, w: w2, umPerPixel: um2)
            // Keep the ones inside the region.
            var kz: [Float] = [], ky: [Float] = [], kx: [Float] = []
            for i in 0..<nzs.count {
                let y4 = min(h4 - 1, Int(nys[i]) / 2), x4 = min(w4 - 1, Int(nxs[i]) / 2)
                if region4[y4 * w4 + x4] { kz.append(nzs[i]); ky.append(nys[i]); kx.append(nxs[i]) }
            }
            (nzs, nys, nxs) = (kz, ky, kx)
        }
        return ZDescriptor(z: Z, h: h4, w: w4, planes: p4, valid: valid4, region: region4, ch: ch, cw: cw, coarse: coarse,
                           coarseValid: coarseValid, coarseRegion: coarseRegion, nz: nzs, ny: nys, nx: nxs, umPerPixel2: um2)
    }

    /// Separable Gaussian blur of one float plane (edge values repeat). `dst` may equal `src`.
    static func blur(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>, w: Int, h: Int, sigma: Double,
                     scratch: UnsafeMutablePointer<Float>) {
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var k = (-r...r).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
        let sum = k.reduce(0, +)
        k = k.map { $0 / sum }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for i in -r...r { s += k[i + r] * src[y * w + min(w - 1, max(0, x + i))] }
                scratch[y * w + x] = s
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for i in -r...r { s += k[i + r] * scratch[min(h - 1, max(0, y + i)) * w + x] }
                dst[y * w + x] = s
            }
        }
    }

    static func dilate(_ m: [Bool], w: Int, h: Int, radius r: Int) -> [Bool] {
        var a = m, b = m
        for y in 0..<h { for x in 0..<w {
            var v = false
            for i in max(0, x - r)...min(w - 1, x + r) where m[y * w + i] { v = true; break }
            a[y * w + x] = v
        } }
        for y in 0..<h { for x in 0..<w {
            var v = false
            for j in max(0, y - r)...min(h - 1, y + r) where a[j * w + x] { v = true; break }
            b[y * w + x] = v
        } }
        return b
    }

    /// Nucleus centres in a 2x-binned (Z, h, w) stack: band-pass each slice (difference of two Gaussians), then
    /// keep the 3-D local maxima that stand clear of the noise. Z is refined between slices.
    static func detectNuclei2(_ b2: UnsafePointer<Float>, z Z: Int, h: Int, w: Int, umPerPixel um: Double)
        -> ([Float], [Float], [Float]) {
        let n = h * w
        let s1 = min(4, max(0.7, 1.3 / um)), s2 = max(2 * s1, 3.0 / um)
        let rxy = max(1, Int((3.0 / um).rounded()))
        let dog = UnsafeMutablePointer<Float>.allocate(capacity: Z * n)
        let mx = UnsafeMutablePointer<Float>.allocate(capacity: Z * n)
        defer { dog.deallocate(); mx.deallocate() }

        // Pixels with data, shrunk so the stack edge does not produce maxima.
        var valid = [Bool](repeating: false, count: n)
        for zi in 0..<Z { let p = b2 + zi * n; for i in 0..<n where p[i] > 0 { valid[i] = true } }
        let inner = dilate(valid.map { !$0 }, w: w, h: h, radius: 6).map { !$0 }

        Parallel.forEach(Z) { zi in
            let a = UnsafeMutablePointer<Float>.allocate(capacity: n), b = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let t = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { a.deallocate(); b.deallocate(); t.deallocate() }
            blur(b2 + zi * n, into: a, w: w, h: h, sigma: s1, scratch: t)
            blur(b2 + zi * n, into: b, w: w, h: h, sigma: s2, scratch: t)
            let d = dog + zi * n
            for i in 0..<n { d[i] = a[i] - b[i] }
            // xy maximum filter of this slice.
            let m = mx + zi * n
            for y in 0..<h { for x in 0..<w {
                var v = -Float.infinity
                for i in max(0, x - rxy)...min(w - 1, x + rxy) { v = max(v, d[y * w + i]) }
                t[y * w + x] = v
            } }
            for y in 0..<h { for x in 0..<w {
                var v = -Float.infinity
                for j in max(0, y - rxy)...min(h - 1, y + rxy) { v = max(v, t[j * w + x]) }
                m[y * w + x] = v
            } }
        }

        // Noise level of the band-passed data: median and scaled median absolute deviation.
        var sample: [Float] = []
        let step = max(1, Z * n / 300_000)
        var i = 0
        while i < Z * n { if valid[i % n] { sample.append(dog[i]) }; i += step }
        guard sample.count > 100 else { return ([], [], []) }
        sample.sort()
        let med = sample[sample.count / 2]
        var dev = sample.map { abs($0 - med) }
        dev.sort()
        let threshold = med + 4 * 1.4826 * dev[dev.count / 2]

        var zs: [Float] = [], ys: [Float] = [], xs: [Float] = []
        for zi in 0..<Z {
            let d = dog + zi * n
            for y in 0..<h {
                for x in 0..<w {
                    let k = y * w + x
                    let v = d[k]
                    guard v > threshold, inner[k], v == mx[zi * n + k] else { continue }
                    if zi > 0 && mx[(zi - 1) * n + k] > v { continue }
                    if zi < Z - 1 && mx[(zi + 1) * n + k] > v { continue }
                    var zf = Float(zi)
                    if zi > 0 && zi < Z - 1 {
                        let c0 = dog[(zi - 1) * n + k], c2 = dog[(zi + 1) * n + k]
                        let den = c0 - 2 * v + c2
                        if den < 0 { zf += min(0.5, max(-0.5, 0.5 * (c0 - c2) / den)) }
                    }
                    zs.append(zf); ys.append(Float(y)); xs.append(Float(x))
                }
            }
        }
        return (zs, ys, xs)
    }

    // MARK: Matching

    /// Mismatch between `a` and `b` for every offset in `ds`, with `b` moved by (sy, sx) pixels:
    /// sum |a - b| / sum (a + b) over the slices that overlap, after scaling both sides to the same mean.
    static func costCurve(a: [Float], b: [Float], z: Int, h: Int, w: Int, validA: [Bool], validB: [Bool],
                          regionA: [Bool], regionB: [Bool], sy: Int, sx: Int, ds: [Int], minPixels: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: ds.count)
        var ia: [Int32] = [], ib: [Int32] = []
        let y0 = max(0, sy), y1 = min(h, h + sy), x0 = max(0, sx), x1 = min(w, w + sx)
        if y0 >= y1 || x0 >= x1 { return out }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * w + x, j = (y - sy) * w + (x - sx)
                if validA[i] && validB[j] && (regionA[i] || regionB[j]) { ia.append(Int32(i)); ib.append(Int32(j)) }
            }
        }
        let n = ia.count, hw = h * w
        guard n >= minPixels else { return out }
        var sa = [Double](repeating: 0, count: z), sb = [Double](repeating: 0, count: z)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            ia.withUnsafeBufferPointer { la in ib.withUnsafeBufferPointer { lb in
                sa.withUnsafeMutableBufferPointer { qa in sb.withUnsafeMutableBufferPointer { qb in
                    Parallel.forEach(z) { zi in
                        var ta = 0.0, tb = 0.0
                        for k in 0..<n { ta += Double(pa[zi * hw + Int(la[k])]); tb += Double(pb[zi * hw + Int(lb[k])]) }
                        qa[zi] = ta; qb[zi] = tb
                    }
                } }
                out.withUnsafeMutableBufferPointer { o in
                    Parallel.forEach(ds.count) { q in
                        let d = ds[q]
                        let lo = max(0, -d), hi = z - max(0, d)
                        guard hi > lo else { return }
                        var ta = 0.0, tb = 0.0
                        for zi in lo..<hi { ta += sa[zi]; tb += sb[zi + d] }
                        guard ta > 0, tb > 0 else { return }
                        let count = Double((hi - lo) * n)
                        let ka = Float(count / ta), kb = Float(count / tb)
                        var acc = 0.0
                        for zi in lo..<hi {
                            let oa = zi * hw, ob = (zi + d) * hw
                            var s: Float = 0
                            for k in 0..<n { s += abs(pa[oa + Int(la[k])] * ka - pb[ob + Int(lb[k])] * kb) }
                            acc += Double(s)
                        }
                        o[q] = acc / (2 * count)
                    }
                }
            } }
        } }
        return out
    }

    static func argmin(_ v: [Double]) -> Int? {
        var best: Int?
        for (i, c) in v.enumerated() where c.isFinite { if best == nil || c < v[best!] { best = i } }
        return best
    }

    /// Z movement of the tissue from `a` (previous timepoint) to `b`. `stage` is the estimate from the recorded
    /// stage positions, in slices; nil when the file has none.
    public static func match(_ a: ZDescriptor, _ b: ZDescriptor, stage: Double?, useNuclei: Bool = true) -> ZStep {
        var step = ZStep()
        step.stage = stage
        let Z = a.z
        guard Z > 1, a.z == b.z, a.h == b.h, a.w == b.w, a.h > 0, a.w > 0 else {
            step.flag = Z > 1 ? "stack sizes differ" : "single slice"
            return step
        }
        // Offsets that leave enough slices in common.
        let minOverlap = min(5, max(1, Z / 2))
        let limit = Z - minOverlap
        var ds = Array(-limit...limit)
        if let s = stage {
            // The stage moved so far that too few slices are shared: the images cannot confirm or refine it.
            if abs(s) > Double(limit) {
                step.dz = s
                step.flag = "stage only (stacks do not overlap)"
                return step
            }
            let centre = Int(s.rounded())
            ds = ds.filter { abs($0 - centre) <= imageWindow }
        }

        // Coarse pass: every xy shift within 3 coarse pixels, every offset.
        var sy = 0, sx = 0
        var coarseBest: (cost: Double, d: Int)?
        if a.ch > 0 && a.cw > 0 {
            for cy in -3...3 {
                for cx in -3...3 {
                    let c = costCurve(a: a.coarse, b: b.coarse, z: Z, h: a.ch, w: a.cw, validA: a.coarseValid, validB: b.coarseValid,
                                      regionA: a.coarseRegion, regionB: b.coarseRegion, sy: cy, sx: cx, ds: ds, minPixels: 12)
                    if let i = argmin(c), coarseBest == nil || c[i] < coarseBest!.cost {
                        coarseBest = (c[i], ds[i]); sy = cy * 4; sx = cx * 4
                    }
                }
            }
        }
        // Fine pass at 4x binning: around the coarse answer, or everything when the region is too small for it.
        let fineDs = coarseBest.map { cb in ds.filter { abs($0 - cb.d) <= 2 } } ?? ds
        var best: (cost: Double, d: Int, sy: Int, sx: Int)?
        for oy in [-2, 0, 2] {
            for ox in [-2, 0, 2] {
                let c = costCurve(a: a.planes, b: b.planes, z: Z, h: a.h, w: a.w, validA: a.valid, validB: b.valid,
                                  regionA: a.region, regionB: b.region, sy: sy + oy, sx: sx + ox, ds: fineDs, minPixels: 64)
                if let i = argmin(c), best == nil || c[i] < best!.cost { best = (c[i], fineDs[i], sy + oy, sx + ox) }
            }
        }
        guard let found = best else {
            step.dz = stage ?? 0
            step.flag = stage == nil ? "no data in the region" : "stage only (no data in the region)"
            return step
        }
        // Sub-slice position from the costs on both sides of the best offset.
        let three = costCurve(a: a.planes, b: b.planes, z: Z, h: a.h, w: a.w, validA: a.valid, validB: b.valid,
                              regionA: a.region, regionB: b.region, sy: found.sy, sx: found.sx,
                              ds: [found.d - 1, found.d, found.d + 1], minPixels: 64)
        var image = Double(found.d)
        if three[0].isFinite && three[2].isFinite && abs(found.d) < limit {
            let den = three[0] - 2 * three[1] + three[2]
            if den > 0 { image += min(0.5, max(-0.5, 0.5 * (three[0] - three[2]) / den)) }
        }
        step.image = image
        step.cost = found.cost
        step.dz = image

        // Nuclei: each nucleus of `a` looks for nuclei of `b` near where the image estimate puts it.
        if useNuclei && a.nucleusCount >= minAgreeing && b.nucleusCount >= minAgreeing {
            let um = a.umPerPixel2
            // b is compared after moving it by (sy, sx) 4x-binned pixels, so tissue at (y, x) in a is at (y - sy, x - sx) in b.
            let ey = Float(-2 * found.sy), ex = Float(-2 * found.sx)
            let radius = Float(6.0 / um)
            let cell = max(1, Int(radius.rounded(.up)))
            let gw = (2 * a.w) / cell + 2, gh = (2 * a.h) / cell + 2
            var grid = [[Int32]](repeating: [], count: gw * gh)
            for i in 0..<b.nucleusCount {
                let gy = min(gh - 1, max(0, Int(b.ny[i]) / cell)), gx = min(gw - 1, max(0, Int(b.nx[i]) / cell))
                grid[gy * gw + gx].append(Int32(i))
            }
            var rz: [Float] = [], ry: [Float] = [], rx: [Float] = []
            for i in 0..<a.nucleusCount {
                let py = a.ny[i] + ey, px = a.nx[i] + ex, pz = a.nz[i] + Float(image)
                let gy = min(gh - 1, max(0, Int(py) / cell)), gx = min(gw - 1, max(0, Int(px) / cell))
                for yy in max(0, gy - 1)...min(gh - 1, gy + 1) {
                    for xx in max(0, gx - 1)...min(gw - 1, gx + 1) {
                        for j in grid[yy * gw + xx] {
                            let k = Int(j)
                            let dy = b.ny[k] - py, dx = b.nx[k] - px, dz = b.nz[k] - pz
                            if abs(dz) <= 2 && dy * dy + dx * dx <= radius * radius {
                                rz.append(dz); ry.append(dy * Float(um)); rx.append(dx * Float(um))
                            }
                        }
                    }
                }
            }
            // Votes: 0.25-slice bins over +-2 slices, 1 um bins over +-6 um; the fullest neighbourhood wins.
            let bz = 17, bxy = 13
            var votes = [Float](repeating: 0, count: bz * bxy * bxy)
            func bin(_ i: Int) -> (Int, Int, Int) {
                (min(bz - 1, max(0, Int(((rz[i] + 2) / 0.25).rounded()))),
                 min(bxy - 1, max(0, Int((ry[i] + 6).rounded()))), min(bxy - 1, max(0, Int((rx[i] + 6).rounded()))))
            }
            for i in 0..<rz.count { let (p, q, r) = bin(i); votes[(p * bxy + q) * bxy + r] += 1 }
            var peak = (0, 0, 0), peakVotes: Float = -1
            for p in 0..<bz { for q in 0..<bxy { for r in 0..<bxy {
                var s: Float = 0
                for dp in -1...1 { for dq in -1...1 { for dr in -1...1 {
                    let pp = p + dp, qq = q + dq, rr = r + dr
                    if pp >= 0 && pp < bz && qq >= 0 && qq < bxy && rr >= 0 && rr < bxy { s += votes[(pp * bxy + qq) * bxy + rr] }
                } } }
                if s > peakVotes { peakVotes = s; peak = (p, q, r) }
            } } }
            let cz = Float(peak.0) * 0.25 - 2, cy = Float(peak.1) - 6, cx = Float(peak.2) - 6
            var agree: [Float] = []
            for i in 0..<rz.count where abs(rz[i] - cz) <= 1 && hypot(ry[i] - cy, rx[i] - cx) <= 2 { agree.append(rz[i]) }
            agree.sort()
            step.agreeing = agree.count
            step.share = Double(agree.count) / Double(min(a.nucleusCount, b.nucleusCount))
            if !agree.isEmpty { step.nuclei = image + Double(agree[agree.count / 2]) }
            if agree.count >= minAgreeing && step.share >= minShare, let nz = step.nuclei { step.dz = nz }
        }
        let nucleiTrusted = step.agreeing >= minAgreeing && step.share >= minShare
        if !nucleiTrusted && found.cost > weakCost { step.flag = "weak match" }
        return step
    }

    // MARK: Plan and apply

    /// Turn the per-timepoint movements into whole-slice shifts.
    /// - Parameters:
    ///   - steps: movement since the previous timepoint, one per timepoint (the first is ignored).
    ///   - reference: the timepoint whose slices keep their meaning.
    ///   - deadBand: the shift changes only once the position is this far past the half-slice point,
    ///     so a position near a half slice does not make the output flip between two slices.
    ///   - pad: add empty slices so nothing is lost; without it, slices that leave the stack are dropped.
    public static func plan(steps: [Double], reference: Int = 0, deadBand: Double = 0.15, pad: Bool = true) -> ZPlan {
        let T = steps.count
        guard T > 0 else { return ZPlan(position: [], shift: [], padLow: 0, padHigh: 0) }
        var pos = [Double](repeating: 0, count: T)
        for t in 1..<max(1, T) { pos[t] = pos[t - 1] + steps[t] }
        let ref = min(max(0, reference), T - 1)
        let p0 = pos[ref]
        pos = pos.map { $0 - p0 }
        var whole = [Int](repeating: 0, count: T)
        func follow(_ t: Int, from previous: Int) -> Int {
            abs(pos[t] - Double(previous)) >= 0.5 + deadBand ? Int(pos[t].rounded()) : previous
        }
        if ref + 1 < T { for t in (ref + 1)..<T { whole[t] = follow(t, from: whole[t - 1]) } }
        if ref > 0 { for t in stride(from: ref - 1, through: 0, by: -1) { whole[t] = follow(t, from: whole[t + 1]) } }
        let shift = whole.map { -$0 }
        return ZPlan(position: pos, shift: shift, padLow: pad ? max(0, -(shift.min() ?? 0)) : 0,
                     padHigh: pad ? max(0, shift.max() ?? 0) : 0)
    }

    /// Move the slices of `v` by `shift` inside a stack with `padLow` + `padHigh` extra slices. Slices that no
    /// input slice lands on stay empty (zero); input slices that land outside are dropped.
    public static func place(_ v: Volume, shift: Int, padLow: Int, padHigh: Int) -> Volume {
        if shift == 0 && padLow == 0 && padHigh == 0 { return v }
        let zOut = v.z + padLow + padHigh
        let out = Volume(c: v.c, z: zOut, y: v.y, x: v.x, type: v.type, zeroed: true)
        for ci in 0..<v.c {
            for zi in 0..<v.z {
                let zo = zi + shift + padLow
                if zo >= 0 && zo < zOut {
                    out.planePointer(c: ci, z: zo).copyMemory(from: v.planePointer(c: ci, z: zi), byteCount: v.planeBytes)
                }
            }
        }
        return out
    }

    /// Log line for one timepoint.
    public static func line(_ s: ZStep) -> String {
        func f(_ v: Double?) -> String { v.map { PyFormat.fmt("%+6.2f", $0) } ?? "   -- " }
        var text = PyFormat.fmt("dz=%+6.2f", s.dz) + "  (stage \(f(s.stage))  image \(f(s.image))  nuclei \(f(s.nuclei))"
        text += PyFormat.fmt("  agree %d = %.0f%%)", s.agreeing, 100 * s.share)
        if !s.flag.isEmpty { text += "  [\(s.flag)]" }
        return text
    }
}
