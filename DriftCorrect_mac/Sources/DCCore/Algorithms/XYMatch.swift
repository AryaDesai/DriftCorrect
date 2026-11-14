import Foundation

/// Settings of the xy alignment by image matching.
public struct XYMatchOptions: Sendable {
    /// The channel to compare, given by index or by name. When both are nil, the threshold channel of the YAML file
    /// is used. A nuclear marker is the best choice because its pattern stays the same between timepoints.
    public var channelIndex: Int?
    public var channelName: String?
    public var region: FollowRegion = .wholeFrame
    /// Hold the body in place with the embryo mask, as `Anchor` describes. Without it the frame can slowly travel
    /// when the cells move through the body.
    public var holdInPlace = true
    /// The number of timepoints over which the position of the body and the turn are averaged.
    public var smoothing = 10.0
    /// The largest turn between two neighbouring timepoints that the matching looks for, in degrees. With 0 the
    /// matching only shifts.
    public var maximumAngle = 3.0
    public init() {}
}

/// One timepoint prepared for the xy image matching. It holds the maximum projection of the compared channel at full
/// resolution, binned by 2, and binned by a coarse factor.
public struct XYFrame: @unchecked Sendable {
    struct Level {
        let bin: Int, w: Int, h: Int
        let pixels: [Float]
        let valid: [Bool]
    }
    let levels: [Level]
    public var width: Int { levels.last!.w }
    public var height: Int { levels.last!.h }
}

/// XY alignment by image matching.
///
/// Each timepoint is compared with the timepoint before it. The later image is slid over the earlier one, and for
/// every offset the mismatch is the sum of the absolute differences divided by the sum of both images, over the
/// pixels that both hold inside the region. The offset with the smallest mismatch is the movement between the two.
/// The search starts on a coarse copy across half the frame in each direction, so that a large jump is found, and
/// then refines the result on finer copies. Candidate angles are tried in the same way, by turning the later image
/// before it is compared. `Anchor` turns the movements of all timepoints into their place in the output.
public enum XYMatch {
    /// The coarse copy is binned until its longer side is at most this many pixels, which keeps the full search fast.
    static let coarseSide = 128
    /// An offset is only considered when the pixels compared cover at least this share of the region.
    static let minOverlap = 0.3

    /// Prepare the maximum projection of one timepoint. A pixel that is 0 holds no data, for example in the empty
    /// border of a merged file.
    public static func prepare(_ projection: Image2D) -> XYFrame {
        let w = projection.width, h = projection.height, n = w * h
        let valid = projection.pixels.map { $0 > 0 }
        // Subtract the background level, which is a low percentile of the data, and blur lightly so that single
        // noisy pixels do not decide the match.
        var sample: [Float] = []
        var i = 0
        while i < n { if valid[i] { sample.append(projection.pixels[i]) }; i += max(1, n / 200_000) }
        sample.sort()
        let bg = sample.isEmpty ? 0 : sample[Int(0.05 * Double(sample.count - 1))]
        var pixels = projection.pixels.map { max(0, $0 - bg) }
        if n > 0 {
            pixels.withUnsafeMutableBufferPointer { p in
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n)
                ZDrift.blur(p.baseAddress!, into: p.baseAddress!, w: w, h: h, sigma: 1.0, scratch: tmp)
                tmp.deallocate()
            }
        }
        var coarse = 8
        while max(w, h) / coarse > coarseSide { coarse *= 2 }
        while coarse > 2 && max(w, h) / coarse < coarseSide / 4 { coarse /= 2 }
        let bins = coarse > 2 ? [coarse, 2, 1] : [2, 1]
        let full = XYFrame.Level(bin: 1, w: w, h: h, pixels: pixels, valid: valid)
        return XYFrame(levels: bins.map { $0 == 1 ? full : binned(full, by: $0) })
    }

    /// Bin a level by `b`. A binned pixel holds the mean of its pixels and is valid when all of them hold data.
    static func binned(_ l: XYFrame.Level, by b: Int) -> XYFrame.Level {
        let w = l.w / b, h = l.h / b
        var pixels = [Float](repeating: 0, count: w * h), valid = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, all = true
                for j in 0..<b { for i in 0..<b {
                    let k = (b * y + j) * l.w + b * x + i
                    s += l.pixels[k]; all = all && l.valid[k]
                } }
                pixels[y * w + x] = s / Float(b * b); valid[y * w + x] = all
            }
        }
        return XYFrame.Level(bin: b, w: w, h: h, pixels: pixels, valid: valid)
    }

    /// Bin a region at full resolution by `b`. A binned pixel is in the region when more than half of its pixels are.
    static func binned(_ region: [Bool], w: Int, h: Int, by b: Int) -> [Bool] {
        if b == 1 { return region }
        let bw = w / b, bh = h / b
        var out = [Bool](repeating: false, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                var c = 0
                for j in 0..<b { for i in 0..<b where region[(b * y + j) * w + b * x + i] { c += 1 } }
                out[y * bw + x] = 2 * c > b * b
            }
        }
        return out
    }

    /// The mismatch when `b` is moved by (dy, dx) onto `a`, so that pixel (y, x) of `a` meets pixel (y - dy, x - dx)
    /// of `b`. Both sides are first scaled to the same mean so that a change in brightness does not count.
    static func cost(_ a: XYFrame.Level, _ b: XYFrame.Level, region: [Bool], regionCount: Int, dy: Int, dx: Int) -> Double {
        let w = a.w, h = a.h
        let y0 = max(0, dy), y1 = min(h, h + dy), x0 = max(0, dx), x1 = min(w, w + dx)
        if y0 >= y1 || x0 >= x1 { return .infinity }
        var n = 0, sa = 0.0, sb = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * w + x, j = (y - dy) * w + (x - dx)
                if region[i] && a.valid[i] && b.valid[j] { n += 1; sa += Double(a.pixels[i]); sb += Double(b.pixels[j]) }
            }
        }
        guard Double(n) >= minOverlap * Double(regionCount), sa > 0, sb > 0 else { return .infinity }
        let ka = Float(Double(n) / sa), kb = Float(Double(n) / sb)
        var diff = 0.0
        for y in y0..<y1 {
            var row: Float = 0
            for x in x0..<x1 {
                let i = y * w + x, j = (y - dy) * w + (x - dx)
                if region[i] && a.valid[i] && b.valid[j] { row += abs(a.pixels[i] * ka - b.pixels[j] * kb) }
            }
            diff += Double(row)
        }
        // The sum of both sides after scaling is 2n.
        return diff / Double(2 * n)
    }

    /// Turn a level by `degrees` about the centre of the frame. A pixel is valid when the four pixels it is
    /// interpolated from are valid.
    static func rotated(_ l: XYFrame.Level, degrees: Double, frameWidth: Int, frameHeight: Int) -> XYFrame.Level {
        if degrees == 0 { return l }
        // The centre of the frame in pixels of this level.
        let bin = Double(l.bin)
        let cx = (Double(frameWidth - 1) / 2 - (bin - 1) / 2) / bin, cy = (Double(frameHeight - 1) / 2 - (bin - 1) / 2) / bin
        // Each output pixel reads the source at the position that the opposite rotation gives.
        let back = Rigid.rotation(degrees: -degrees, aboutX: cx, y: cy)
        let w = l.w, h = l.h
        var pixels = [Float](repeating: 0, count: w * h), valid = [Bool](repeating: false, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            valid.withUnsafeMutableBufferPointer { ok in
                Parallel.forEach(h) { y in
                    for x in 0..<w {
                        let s = back.apply(x: Double(x), y: Double(y))
                        let x0 = Int(s.x.rounded(.down)), y0 = Int(s.y.rounded(.down))
                        if x0 < 0 || y0 < 0 || x0 + 1 >= w || y0 + 1 >= h { continue }
                        let i = y0 * w + x0
                        if !(l.valid[i] && l.valid[i + 1] && l.valid[i + w] && l.valid[i + w + 1]) { continue }
                        let fx = Float(s.x - Double(x0)), fy = Float(s.y - Double(y0))
                        out[y * w + x] = (l.pixels[i] * (1 - fx) + l.pixels[i + 1] * fx) * (1 - fy)
                            + (l.pixels[i + w] * (1 - fx) + l.pixels[i + w + 1] * fx) * fy
                        ok[y * w + x] = true
                    }
                }
            }
        }
        return XYFrame.Level(bin: l.bin, w: w, h: h, pixels: pixels, valid: valid)
    }

    /// Try every whole offset within (ry, rx) of (cy, cx) and return the one with the smallest mismatch.
    static func search(_ la: XYFrame.Level, _ lb: XYFrame.Level, region: [Bool], regionCount: Int,
                       cy: Int, cx: Int, ry: Int, rx: Int) -> (dy: Int, dx: Int, cost: Double) {
        let rows = Array((cy - ry)...(cy + ry))
        var rowBest = [(dy: Int, dx: Int, cost: Double)](repeating: (0, 0, .infinity), count: rows.count)
        rowBest.withUnsafeMutableBufferPointer { out in
            Parallel.forEach(rows.count) { k in
                var m = (dy: rows[k], dx: 0, cost: Double.infinity)
                for dx in (cx - rx)...(cx + rx) {
                    let c = cost(la, lb, region: region, regionCount: regionCount, dy: rows[k], dx: dx)
                    if c < m.cost { m = (rows[k], dx, c) }
                }
                out[k] = m
            }
        }
        var best = (dy: 0, dx: 0, cost: Double.infinity)
        for m in rowBest where m.cost < best.cost { best = m }
        return best
    }

    /// The step between the candidate angles on the coarsest copy, in degrees. Each finer copy halves it.
    static let angleStep = 0.5
    /// A turn is accepted only when it lowers the mismatch by at least this share compared with no turn. A turned
    /// image is interpolated, which smooths it slightly and can lower the mismatch without a real turn.
    static let turnMargin = 0.02

    /// Return the transform that moves `b`, the later timepoint, onto `a`, the earlier one, and the mismatch there.
    /// The transform turns `b` about the centre of the frame and then shifts it by whole pixels. `region` is in
    /// pixels of `a` at full resolution, and without it the whole frame is used. Angles up to `maximumAngle` degrees
    /// in either direction are tried. With 0 the match only shifts.
    public static func match(_ a: XYFrame, _ b: XYFrame, region: [Bool]? = nil, maximumAngle: Double = 0) -> (step: Rigid, cost: Double) {
        let W = a.width, H = a.height
        let whole = region ?? [Bool](repeating: true, count: W * H)
        var best = (dy: 0, dx: 0, cost: Double.infinity)
        var angle = 0.0, step = angleStep
        var previousBin = 0
        for (la, lb) in zip(a.levels, b.levels) {
            let r = binned(whole, w: W, h: H, by: la.bin)
            var count = 0
            for i in 0..<r.count where r[i] && la.valid[i] { count += 1 }
            func turned(_ degrees: Double) -> XYFrame.Level { rotated(lb, degrees: degrees, frameWidth: W, frameHeight: H) }
            if previousBin == 0 {
                // The coarsest copy first searches half the frame in each direction without turning, so that a
                // large jump is found. It then tries every candidate angle close to that offset.
                best = search(la, lb, region: r, regionCount: count, cy: 0, cx: 0, ry: la.h / 2, rx: la.w / 2)
                if !best.cost.isFinite { return (.identity, .nan) }
                let straight = best
                var turn = (dy: 0, dx: 0, cost: Double.infinity), turnAngle = 0.0
                var candidate = -maximumAngle
                while maximumAngle > 0 && candidate <= maximumAngle + 1e-9 {
                    if abs(candidate) > 1e-9 {
                        let m = search(la, turned(candidate), region: r, regionCount: count, cy: straight.dy, cx: straight.dx, ry: 2, rx: 2)
                        if m.cost < turn.cost { turn = m; turnAngle = candidate }
                    }
                    candidate += step
                }
                if turn.cost < straight.cost * (1 - turnMargin) { best = turn; angle = turnAngle }
            } else {
                // Each finer copy searches around the result of the copy before it, far enough to cover its
                // rounding. It tries no turn, and the angle found so far with half a step to either side.
                let scale = previousBin / la.bin
                let cy = best.dy * scale, cx = best.dx * scale, radius = scale / 2 + 1
                step /= 2
                let straight = search(la, lb, region: r, regionCount: count, cy: cy, cx: cx, ry: radius, rx: radius)
                var turn = (dy: 0, dx: 0, cost: Double.infinity), turnAngle = 0.0
                for candidate in maximumAngle > 0 ? [angle, angle - step, angle + step] : [] where abs(candidate) > 1e-9 {
                    let m = search(la, turned(candidate), region: r, regionCount: count, cy: cy, cx: cx, ry: radius, rx: radius)
                    if m.cost < turn.cost { turn = m; turnAngle = candidate }
                }
                if turn.cost < straight.cost * (1 - turnMargin) {
                    best = turn; angle = turnAngle
                } else if straight.cost.isFinite {
                    best = straight; angle = 0
                } else {
                    return (.identity, .nan)
                }
            }
            previousBin = la.bin
        }
        let turn = Rigid.rotation(degrees: angle, aboutX: Double(W - 1) / 2, y: Double(H - 1) / 2)
        return (Rigid.shift(dx: Double(best.dx), dy: Double(best.dy)).after(turn), best.cost)
    }

    /// Return the pixels of one timepoint that the matching compares, or nil for the whole frame. `mask` is the
    /// embryo mask of that timepoint. `toFirst` moves that timepoint onto the first one, where the box was drawn.
    public static func region(_ follow: FollowRegion, mask: Mask2D?, toFirst: Rigid, width w: Int, height h: Int) -> [Bool]? {
        switch follow {
        case .wholeFrame:
            return nil
        case .embryoMask:
            // Grow the mask by 12 pixels so that the edge of the tissue, which carries most of the pattern, is included.
            guard let m = mask, m.width == w, m.height == h else { return nil }
            return ZDrift.dilate(m.bits, w: w, h: h, radius: 12)
        case .box(let bx, let by, let bw, let bh):
            // A pixel is in the region when its position on the first timepoint lies inside the box.
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let p = toFirst.apply(x: Double(x), y: Double(y))
                    out[y * w + x] = p.x >= Double(bx) && p.x < Double(bx + bw) && p.y >= Double(by) && p.y < Double(by + bh)
                }
            }
            return out
        }
    }
}

/// Return the index of the channel given by `index` or `name`. `fallback` is used when neither is given.
func resolveChannel(index: Int?, name: String?, names: [String], count: Int, fallback: Int, label: String) throws -> Int {
    if let i = index {
        guard i >= 0 && i < count else { throw DCError("\(label) channel index \(i) is out of range (the data has \(count) channel(s))") }
        return i
    }
    if let n = name, !n.isEmpty {
        guard let i = names.prefix(count).firstIndex(of: n) else {
            throw DCError("\(label) channel \"\(n)\" not found. The channels are: \(names.prefix(count).joined(separator: ", "))")
        }
        return i
    }
    return fallback
}
