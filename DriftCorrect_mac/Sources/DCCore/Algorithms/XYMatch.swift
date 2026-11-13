import Foundation

/// Settings of the xy alignment by image matching. When `AlignOptions.xyMatching` is nil, the alignment centres the
/// centroid of the embryo mask instead.
public struct XYMatchOptions: Sendable {
    /// The channel to compare, given by index or by name. When both are nil, the threshold channel of the YAML file
    /// is used. A nuclear marker is the best choice because its pattern stays the same between timepoints.
    public var channelIndex: Int?
    public var channelName: String?
    public var region: FollowRegion = .wholeFrame
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
/// then refines the result on finer copies. Adding up the movements gives the shift of every timepoint.
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

    /// Return how far `b`, the later timepoint, must be moved in whole pixels to lie on `a`, the earlier one, and the
    /// mismatch at that offset. `region` is in pixels of `a` at full resolution. Without it the whole frame is used.
    public static func match(_ a: XYFrame, _ b: XYFrame, region: [Bool]? = nil) -> (dy: Int, dx: Int, cost: Double) {
        var best = (dy: 0, dx: 0, cost: Double.infinity)
        var previousBin = 0
        for (la, lb) in zip(a.levels, b.levels) {
            let r = binned(region ?? [Bool](repeating: true, count: a.width * a.height), w: a.width, h: a.height, by: la.bin)
            var count = 0
            for i in 0..<r.count where r[i] && la.valid[i] { count += 1 }
            // The first level searches half the frame in each direction. Each later level searches around the
            // result of the level before, far enough to cover its rounding.
            let cy: Int, cx: Int, ry: Int, rx: Int
            if previousBin == 0 {
                cy = 0; cx = 0; ry = la.h / 2; rx = la.w / 2
            } else {
                cy = best.dy * previousBin / la.bin; cx = best.dx * previousBin / la.bin
                ry = previousBin / la.bin / 2 + 1; rx = ry
            }
            let rows = Array((cy - ry)...(cy + ry))
            var rowBest = [(dy: Int, dx: Int, cost: Double)](repeating: (0, 0, .infinity), count: rows.count)
            rowBest.withUnsafeMutableBufferPointer { out in
                Parallel.forEach(rows.count) { k in
                    var m = (dy: rows[k], dx: 0, cost: Double.infinity)
                    for dx in (cx - rx)...(cx + rx) {
                        let c = cost(la, lb, region: r, regionCount: count, dy: rows[k], dx: dx)
                        if c < m.cost { m = (rows[k], dx, c) }
                    }
                    out[k] = m
                }
            }
            best = (0, 0, .infinity)
            for m in rowBest where m.cost < best.cost { best = m }
            if !best.cost.isFinite { return (0, 0, .nan) }
            previousBin = la.bin
        }
        return best
    }

    /// The pixels of the earlier timepoint that the matching compares. `mask` is the embryo mask of that timepoint,
    /// and `position` is its shift so far, which moves the box from the first timepoint onto it.
    public static func region(_ follow: FollowRegion, mask: Mask2D?, position: (dy: Double, dx: Double),
                              width w: Int, height h: Int) -> [Bool]? {
        switch follow {
        case .wholeFrame:
            return nil
        case .embryoMask:
            // Grow the mask by 12 pixels so that the edge of the tissue, which carries most of the pattern, is included.
            guard let m = mask, m.width == w, m.height == h else { return nil }
            return ZDrift.dilate(m.bits, w: w, h: h, radius: 12)
        case .box(let bx, let by, let bw, let bh):
            // Pixel (y, x) of the first timepoint is at (y - dy, x - dx) of this timepoint.
            let oy = Int(position.dy.rounded()), ox = Int(position.dx.rounded())
            var out = [Bool](repeating: false, count: w * h)
            let y0 = max(0, by - oy), y1 = min(h, by + bh - oy), x0 = max(0, bx - ox), x1 = min(w, bx + bw - ox)
            if y0 < y1 && x0 < x1 { for y in y0..<y1 { for x in x0..<x1 { out[y * w + x] = true } } }
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
