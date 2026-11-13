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

/// A box in pixels of the frame after it is moved in xy.
public struct ZBox: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
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
    /// The position of the tissue relative to the reference timepoint, in slices. The value can be fractional.
    public var position: [Double]
    /// The number of slices to move each timepoint by. An input slice lands on output slice `input + shift + padLow`.
    public var shift: [Int]
    public var padLow: Int
    public var padHigh: Int
    /// The timepoints that are written. The shifts still add up the movement of every timepoint.
    public var kept: [Int]
}

/// Measurement and correction of drift along z.
///
/// Each timepoint is compared with the timepoint before it, after the xy alignment. The stack of the later timepoint
/// is moved up and down against the earlier one, one slice at a time, with a small search in xy. The offset where the
/// two stacks differ least is the movement of the tissue. The correction then moves whole slices and fills the gaps
/// with empty slices. It does not interpolate between slices.
public enum ZDrift {
    /// A match with a mismatch above this value is flagged in the log and the table.
    static let weakCost = 0.27

    /// Reduce one timepoint to the data that the comparison with its neighbours needs.
    /// `shift` is the xy shift of this timepoint in whole pixels. With `mask` the region is the mask, with `box` it
    /// is the box, and with neither it is the whole frame.
    public static func describe(frame: Volume, channel: Int, shift: (dy: Int, dx: Int) = (0, 0), mask: Mask2D? = nil,
                                box: ZBox? = nil) -> ZDescriptor {
        let Z = frame.z, Y = frame.y, X = frame.x
        let h4 = Y / 4, w4 = X / 4, n4 = h4 * w4
        let dy = shift.dy, dx = shift.dx

        // Bin the channel by 4 in xy and move it by the xy shift. Source pixels outside the frame count as 0.
        var p4 = [Float](repeating: 0, count: Z * n4)
        p4.withUnsafeMutableBufferPointer { out in
            Parallel.forEach(Z) { zi in
                let plane = frame.planeIndex(c: channel, z: zi)
                for y in 0..<h4 {
                    for x in 0..<w4 {
                        var s: Float = 0
                        for j in 0..<4 {
                            let sy = 4 * y + j - dy
                            if sy < 0 || sy >= Y { continue }
                            for i in 0..<4 {
                                let sx = 4 * x + i - dx
                                if sx >= 0 && sx < X { s += frame.sample(plane: plane, index: sy * X + sx) }
                            }
                        }
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

        // Build the region at the resolution binned by 4, in the coordinates of the frame after the xy shift.
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

        // Make the copy binned by 16 for the coarse search in xy. A coarse pixel is valid when all of its pixels
        // hold data, and it is in the region when at least half of them are.
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
        // Fit a parabola through the mismatch at the best offset and at its two neighbours to place the minimum
        // between slices.
        let three = costCurve(a: a.planes, b: b.planes, z: Z, h: a.h, w: a.w, validA: a.valid, validB: b.valid,
                              regionA: a.region, regionB: b.region, sy: found.sy, sx: found.sx,
                              ds: [found.d - 1, found.d, found.d + 1], minPixels: 64)
        var dz = Double(found.d)
        if three[0].isFinite && three[2].isFinite && abs(found.d) < limit {
            let den = three[0] - 2 * three[1] + three[2]
            if den > 0 { dz += min(0.5, max(-0.5, 0.5 * (three[0] - three[2]) / den)) }
        }
        step.dz = dz
        step.cost = found.cost
        if found.cost > weakCost { step.flag = "weak match" }
        return step
    }

    // MARK: Plan and apply

    /// Turn the movements between timepoints into a shift of whole slices for every timepoint.
    /// - Parameters:
    ///   - steps: The movement since the previous timepoint, with one value for each timepoint. The first value
    ///     is ignored.
    ///   - reference: The timepoint whose slices stay where they are.
    ///   - deadBand: The shift changes only when the position is this far beyond the midpoint between two slices.
    ///     A position that stays close to a midpoint would otherwise make the output switch between two slices.
    ///   - pad: When true, empty slices are added so that no slice is lost. When false, slices that leave the
    ///     stack are dropped.
    public static func plan(steps: [Double], reference: Int = 0, deadBand: Double = 0.15, pad: Bool = true, maximumStep: Double? = nil) -> ZPlan {
        let T = steps.count
        guard T > 0 else { return ZPlan(position: [], shift: [], padLow: 0, padHigh: 0, kept: []) }
        // Add up the movements to get the position of the tissue at every timepoint, relative to the reference
        // timepoint.
        var pos = [Double](repeating: 0, count: T)
        for t in 1..<max(1, T) { pos[t] = pos[t - 1] + steps[t] }
        let ref = min(max(0, reference), T - 1)
        let p0 = pos[ref]
        pos = pos.map { $0 - p0 }
        // Follow the position in whole slices, forward and then backward from the reference timepoint.
        var whole = [Int](repeating: 0, count: T)
        func follow(_ t: Int, from previous: Int) -> Int {
            abs(pos[t] - Double(previous)) >= 0.5 + deadBand ? Int(pos[t].rounded()) : previous
        }
        if ref + 1 < T { for t in (ref + 1)..<T { whole[t] = follow(t, from: whole[t - 1]) } }
        if ref > 0 { for t in stride(from: ref - 1, through: 0, by: -1) { whole[t] = follow(t, from: whole[t + 1]) } }
        // The correction moves each timepoint opposite to the movement of the tissue.
        let shift = whole.map { -$0 }
        let kept = (0..<T).filter { $0 == 0 || maximumStep == nil || abs(steps[$0]) <= maximumStep! }
        let retainedShifts = kept.map { shift[$0] }
        return ZPlan(position: pos, shift: shift, padLow: pad ? max(0, -(retainedShifts.min() ?? 0)) : 0,
                     padHigh: pad ? max(0, retainedShifts.max() ?? 0) : 0, kept: kept)
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
