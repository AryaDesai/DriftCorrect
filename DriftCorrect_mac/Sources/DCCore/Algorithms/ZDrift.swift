import Foundation

/// The part of the image that the image matching follows, for the xy alignment and for the z correction.
public enum FollowRegion: Equatable, Sendable {
    /// Every pixel that holds data.
    case wholeFrame
    /// The embryo mask from the threshold YAML file, which is the mask that the centroid alignment uses.
    case embryoMask
    /// A box over cells that should stay still. The box is in pixels of the first timepoint before the alignment.
    case box(x: Int, y: Int, width: Int, height: Int)
}

/// The data that z correction keeps of one timepoint, which is a reduced copy of the channel it follows.
public struct ZDescriptor: @unchecked Sendable {
    public let z: Int
    /// The height and width of the planes after binning by 4.
    public let h: Int, w: Int
    let planes: [Float]
    let valid: [Bool]
    let region: [Bool]
    /// A copy binned by 16, which the coarse search in xy uses.
    let ch: Int, cw: Int
    let coarse: [Float]
    let coarseValid: [Bool]
    let coarseRegion: [Bool]
}

/// The z movement measured between one timepoint and the timepoint before it.
public struct ZStep: Sendable {
    /// The number of slices the tissue moved since the previous timepoint. A positive value is a move toward a
    /// higher slice index.
    public var dz = 0.0
    /// The image mismatch at the best offset. It is 0 for identical images and 1 for images with nothing in common.
    public var cost = Double.nan
    /// The reason the measurement needs a look. The string is empty when the match is good.
    public var flag = ""
    public init() {}
}

/// The shift of every timepoint in whole slices, and the number of empty slices to add.
public struct ZPlan: Equatable, Sendable {
    /// The position of the tissue relative to the first timepoint, in slices. The value can be fractional.
    public var position: [Double]
    /// The number of slices to move each timepoint by. An input slice lands on output slice `input + shift + padLow`.
    public var shift: [Int]
    public var padLow: Int
    public var padHigh: Int
    /// The timepoints that are written.
    public var kept: [Int]
}

/// Measurement and correction of drift along z.
///
/// Each timepoint is compared with the timepoint before it, after the xy alignment. The stack of the later timepoint
/// is moved up and down against the earlier one, one slice at a time, with a small search in xy. The offset where the
/// two stacks differ least is the movement of the tissue. The correction then moves whole slices and fills the gaps
/// with empty slices. It does not interpolate between slices.
public enum ZDrift {
    /// A match is weak when its mismatch is above this share of the typical mismatch of the same two timepoints,
    /// as `isWeak` describes.
    static let weakShare = 0.65

    /// Say whether a match is too weak to trust. `best` is the mismatch of the match, and `tried` holds the mismatch
    /// of every placement that the search tried for the same two timepoints. Most of those placements are wrong,
    /// so their median is the mismatch of two images that do not match. A real match lies well below it, and a
    /// match close to it is no better than a wrong placement. A fixed limit cannot do this, because the mismatch
    /// of images that do not match depends on the pattern. It is much lower for membranes than for nuclei.
    static func isWeak(best: Double, tried: [Double]) -> Bool {
        let finite = tried.filter { $0.isFinite }.sorted()
        guard best.isFinite, !finite.isEmpty else { return true }
        return best > weakShare * finite[finite.count / 2]
    }

    /// Reduce one timepoint to the data that the comparison with another timepoint needs. `region` marks the
    /// pixels of the frame to follow, and without it the whole frame is followed. `transform` moves the timepoint
    /// in xy before it is reduced. The xy alignment gives it, so that two timepoints are compared in z with the
    /// same tissue on top of each other.
    public static func describe(frame: Volume, channel: Int, region: [Bool]? = nil, transform: Rigid = .identity) -> ZDescriptor {
        let Z = frame.z, Y = frame.y, X = frame.x
        let h4 = Y / 4, w4 = X / 4, n4 = h4 * w4
        let moving = transform != .identity
        // Each pixel of the moved frame reads the source at the position that the opposite transform gives.
        let back = transform.inverse

        // Move the channel and bin it by 4 in xy. Values between pixels are interpolated from the four nearest
        // pixels, and a pixel outside the frame counts as 0.
        var p4 = [Float](repeating: 0, count: Z * n4)
        p4.withUnsafeMutableBufferPointer { out in
            Parallel.forEach(Z) { zi in
                let plane = frame.planeIndex(c: channel, z: zi)
                @inline(__always) func source(_ yy: Int, _ xx: Int) -> Float {
                    (yy < 0 || yy >= Y || xx < 0 || xx >= X) ? 0 : frame.sample(plane: plane, index: yy * X + xx)
                }
                for y in 0..<h4 {
                    for x in 0..<w4 {
                        var s: Float = 0
                        for j in 0..<4 { for i in 0..<4 {
                            if !moving { s += frame.sample(plane: plane, index: (4 * y + j) * X + 4 * x + i); continue }
                            let q = back.apply(x: Double(4 * x + i), y: Double(4 * y + j))
                            let x0 = Int(q.x.rounded(.down)), y0 = Int(q.y.rounded(.down))
                            let fx = Float(q.x - Double(x0)), fy = Float(q.y - Double(y0))
                            s += (source(y0, x0) * (1 - fx) + source(y0, x0 + 1) * fx) * (1 - fy)
                                + (source(y0 + 1, x0) * (1 - fx) + source(y0 + 1, x0 + 1) * fx) * fy
                        } }
                        out[zi * n4 + y * w4 + x] = s / 16
                    }
                }
            }
        }
        var valid4 = [Bool](repeating: false, count: n4)
        for zi in 0..<Z { for i in 0..<n4 where p4[zi * n4 + i] > 0 { valid4[i] = true } }
        if n4 > 0 {
            // Subtract the background level, which is a low percentile of the data, and then blur each plane
            // lightly in xy. The blur makes the comparison tolerant of a small misalignment in xy.
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

        // Bin the region by 4. A binned pixel is in the region when any of its pixels is.
        var region4 = [Bool](repeating: region == nil, count: n4)
        if let r = region, r.count == X * Y {
            for y in 0..<h4 { for x in 0..<w4 {
                var any = false
                for j in 0..<4 { for i in 0..<4 {
                    var sx = 4 * x + i, sy = 4 * y + j
                    if moving {
                        let q = back.apply(x: Double(sx), y: Double(sy))
                        sx = Int(q.x.rounded()); sy = Int(q.y.rounded())
                        if sx < 0 || sx >= X || sy < 0 || sy >= Y { continue }
                    }
                    if r[sy * X + sx] { any = true }
                } }
                region4[y * w4 + x] = any
            } }
        }
        return assemble(z: Z, h: h4, w: w4, planes: p4, valid: valid4, region: region4)
    }

    /// Build a descriptor from planes binned by 4. This adds the copy binned by 16 for the coarse search in xy. A
    /// coarse pixel is valid when all of its pixels hold data, and it is in the region when at least half of them are.
    static func assemble(z Z: Int, h h4: Int, w w4: Int, planes p4: [Float], valid valid4: [Bool], region region4: [Bool]) -> ZDescriptor {
        let n4 = h4 * w4
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
        return ZDescriptor(z: Z, h: h4, w: w4, planes: p4, valid: valid4, region: region4, ch: ch, cw: cw, coarse: coarse,
                           coarseValid: coarseValid, coarseRegion: coarseRegion)
    }

    /// Find the z position of every timepoint from measured movements between pairs of timepoints. An edge says
    /// that the tissue moved by `d` slices from timepoint `i` to timepoint `j`. Neighbouring timepoints give one
    /// edge each, and pairs further apart give more. The positions are the ones that agree best with all edges. An
    /// edge that disagrees strongly with the rest counts less. The first timepoint is at 0.
    static func positions(count T: Int, edges: [(i: Int, j: Int, d: Double)]) -> [Double] {
        var z = [Double](repeating: 0, count: T)
        guard T > 1 else { return z }
        // Start from the sum of the movements between neighbours.
        var neighbour = [Double](repeating: 0, count: T)
        for e in edges where e.j == e.i + 1 { neighbour[e.j] = e.d }
        for t in 1..<T { z[t] = z[t - 1] + neighbour[t] }
        // Apply the weighted edges to a vector. This is the matrix of the least squares problem.
        var weight = [Double](repeating: 1, count: edges.count)
        func applied(_ v: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: T)
            for (k, e) in edges.enumerated() {
                let r = weight[k] * (v[e.j] - v[e.i])
                out[e.j] += r; out[e.i] -= r
            }
            out[0] = 0
            return out
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        for _ in 0..<8 {
            // Give each edge a weight that falls off once its error exceeds about a third of a slice.
            for (k, e) in edges.enumerated() {
                let r = (z[e.j] - z[e.i] - e.d) / 0.3
                weight[k] = 1 / (1 + r * r).squareRoot()
            }
            var rhs = [Double](repeating: 0, count: T)
            for (k, e) in edges.enumerated() { rhs[e.j] += weight[k] * e.d; rhs[e.i] -= weight[k] * e.d }
            rhs[0] = 0
            // Solve with the conjugate gradient method, starting from the current positions.
            var r = zip(rhs, applied(z)).map { $0 - $1 }
            var p = r, rr = dot(r, r)
            for _ in 0..<(4 * T) where rr > 1e-18 {
                let ap = applied(p)
                let alpha = rr / dot(p, ap)
                for t in 1..<T { z[t] += alpha * p[t]; r[t] -= alpha * ap[t] }
                let next = dot(r, r)
                for t in 1..<T { p[t] = r[t] + next / rr * p[t] }
                rr = next
            }
        }
        return z
    }

    // MARK: Helpers

    /// Blur one plane with a Gaussian, first along x and then along y. A pixel beyond the edge takes the value of
    /// the edge pixel. `dst` can be the same memory as `src`.
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

    /// Grow a mask by `radius` pixels along x and then along y.
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

    // MARK: Matching

    /// Measure the mismatch between `a` and `b` for every z offset in `ds`, with `b` moved by (sy, sx) pixels.
    /// The mismatch is the sum of |a - b| divided by the sum of (a + b) over the slices that both stacks share at
    /// that offset. Both stacks are first scaled to the same mean so that a change in brightness does not count.
    static func costCurve(a: [Float], b: [Float], z: Int, h: Int, w: Int, validA: [Bool], validB: [Bool],
                          regionA: [Bool], regionB: [Bool], sy: Int, sx: Int, ds: [Int], minPixels: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: ds.count)
        // List the pixels that hold data in both stacks and lie in the region of either one.
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
        // Sum each slice over those pixels once. The sums give the mean of any run of slices without another pass.
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
                        // Scale both sides so that their means over the shared slices are equal.
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

    /// Return the index of the smallest finite value, or nil when there is none.
    static func argmin(_ v: [Double]) -> Int? {
        var best: Int?
        for (i, c) in v.enumerated() where c.isFinite { if best == nil || c < v[best!] { best = i } }
        return best
    }

    /// Measure the z movement of the tissue from `a`, the previous timepoint, to `b`.
    public static func match(_ a: ZDescriptor, _ b: ZDescriptor) -> ZStep {
        var step = ZStep()
        let Z = a.z
        guard Z > 1, a.z == b.z, a.h == b.h, a.w == b.w, a.h > 0, a.w > 0 else {
            step.flag = Z > 1 ? "stack sizes differ" : "single slice"
            return step
        }
        // Consider the offsets that leave at least 5 slices in common, or half the stack when it is thinner.
        let minOverlap = min(5, max(1, Z / 2))
        let limit = Z - minOverlap
        let ds = Array(-limit...limit)

        // Coarse pass. Try every xy shift within 3 coarse pixels together with every offset.
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
        // Fine pass at the resolution binned by 4, within 2 slices of the coarse result. When the region is too
        // small for the coarse pass, search every offset.
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
            step.flag = "no data in the region"
            return step
        }
        // Measure the mismatch at every offset with the xy shift that was found. The offsets far from the best one
        // show how large the mismatch is when the two stacks do not match, which `isWeak` needs.
        let every = costCurve(a: a.planes, b: b.planes, z: Z, h: a.h, w: a.w, validA: a.valid, validB: b.valid,
                              regionA: a.region, regionB: b.region, sy: found.sy, sx: found.sx, ds: ds, minPixels: 64)
        // Fit a parabola through the mismatch at the best offset and at its two neighbours to place the minimum
        // between slices. `ds` starts at -limit, so offset d is at index d + limit.
        var dz = Double(found.d)
        if abs(found.d) < limit {
            let lower = every[found.d + limit - 1], upper = every[found.d + limit + 1]
            let den = lower - 2 * found.cost + upper
            if lower.isFinite && upper.isFinite && den > 0 { dz += min(0.5, max(-0.5, 0.5 * (lower - upper) / den)) }
        }
        step.dz = dz
        step.cost = found.cost
        if isWeak(best: found.cost, tried: every) { step.flag = "weak match" }
        return step
    }

    // MARK: Plan and apply

    /// Turn the movements between timepoints into a shift of whole slices for every timepoint.
    /// - Parameters:
    ///   - steps: The movement since the previous timepoint, with one value for each timepoint. The first value
    ///     is ignored.
    ///   - deadBand: The shift changes only when the position is this far beyond the midpoint between two slices.
    ///     A position that stays close to a midpoint would otherwise make the output switch between two slices.
    ///   - pad: When true, empty slices are added so that no slice is lost. When false, slices that leave the
    ///     stack are dropped.
    ///   - positions: The position of the tissue at every timepoint. Without it the movements are added up.
    public static func plan(steps: [Double], positions: [Double]? = nil, deadBand: Double = 0.15,
                            pad: Bool = true) -> ZPlan {
        let T = steps.count
        guard T > 0 else { return ZPlan(position: [], shift: [], padLow: 0, padHigh: 0, kept: []) }
        // Take the position of the tissue at every timepoint, or add up the movements to get it. It is then made
        // relative to the first timepoint.
        var pos = [Double](repeating: 0, count: T)
        if let given = positions, given.count == T { pos = given } else { for t in 1..<max(1, T) { pos[t] = pos[t - 1] + steps[t] } }
        let p0 = pos[0]
        pos = pos.map { $0 - p0 }
        // Follow the position in whole slices from the first timepoint.
        var whole = [Int](repeating: 0, count: T)
        for t in 1..<max(1, T) {
            whole[t] = abs(pos[t] - Double(whole[t - 1])) >= 0.5 + deadBand ? Int(pos[t].rounded()) : whole[t - 1]
        }
        // The correction moves each timepoint opposite to the movement of the tissue.
        let shift = whole.map { -$0 }
        return ZPlan(position: pos, shift: shift, padLow: pad ? max(0, -(shift.min() ?? 0)) : 0,
                     padHigh: pad ? max(0, shift.max() ?? 0) : 0, kept: Array(0..<T))
    }

    /// Move the slices of `v` by `shift` inside a stack that has `padLow` + `padHigh` extra slices. An output slice
    /// that no input slice lands on stays empty, which means filled with zeros. An input slice that lands outside
    /// the stack is dropped.
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

    /// Format the measurement of one timepoint for the log.
    public static func line(_ s: ZStep) -> String {
        var text = PyFormat.fmt("dz=%+6.2f", s.dz) + "  mismatch " + (s.cost.isFinite ? PyFormat.fmt("%.3f", s.cost) : "--")
        if !s.flag.isEmpty { text += "  [\(s.flag)]" }
        return text
    }
}
