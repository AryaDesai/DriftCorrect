import Foundation

/// Multi-level Otsu over a uniform histogram (port of `multi_otsu_jax.py`).
///
/// The dynamic program is the same as `_solve_histogram`: it maximizes the
/// between-class variance over contiguous, nonempty histogram classes,
/// and exact ties choose the earliest split. It runs in float64 on the CPU
/// (O(classes · nbins²), about 5 million operations for 10 classes and 1024
/// bins). Thresholds are histogram bin edges; a pixel equal to a threshold
/// goes to the brighter class.
public enum MultiOtsu {
    public static let maxLevels = 10
    public static let defaultBins = 1024

    public enum Failure: Error { case invalid(String) }

    /// Optimal split indices (first bin of each brighter class).
    public static func solve(histogram: [Double], classes: Int) -> (breaks: [Int], score: Double) {
        let nb = histogram.count
        let total = histogram.reduce(0, +)
        var mass = [Double](repeating: 0, count: nb + 1)
        var moment = [Double](repeating: 0, count: nb + 1)
        var cm = 0.0, cmo = 0.0
        for i in 0..<nb {
            let w = histogram[i] / total
            let c = (Double(i) + 0.5) / Double(nb) - 0.5
            cm += w; cmo += w * c
            mass[i + 1] = cm; moment[i + 1] = cmo
        }
        var previous = [Double](repeating: -.infinity, count: nb + 1)
        previous[0] = 0
        var parents = [[Int32]](repeating: [], count: classes)
        for k in 1...classes {
            var current = [Double](repeating: -.infinity, count: nb + 1)
            var split = [Int32](repeating: 0, count: nb)
            let startMin = k - 1
            mass.withUnsafeBufferPointer { m in
                moment.withUnsafeBufferPointer { mo in
                    previous.withUnsafeBufferPointer { prev in
                        current.withUnsafeMutableBufferPointer { cur in
                            split.withUnsafeMutableBufferPointer { sp in
                                let curP = cur, spP = sp
                                Parallel.forChunks(nb, minChunk: 32) { range in
                                    for endIndex in range {
                                        let end = endIndex + 1
                                        var best = -Double.infinity
                                        var arg = 0
                                        var s = startMin
                                        while s < end {
                                            let im = m[end] - m[s]
                                            if im > 0 {
                                                let imo = mo[end] - mo[s]
                                                let score = prev[s] + imo * imo / im
                                                if score > best { best = score; arg = s }
                                            }
                                            s += 1
                                        }
                                        curP[end] = best
                                        spP[endIndex] = Int32(arg)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            parents[k - 1] = split
            previous = current
        }
        var breaks = [Int](repeating: 0, count: max(0, classes - 1))
        var end = nb
        if classes > 1 {
            for step in 0..<(classes - 1) {
                let s = Int(parents[classes - step - 1][end - 1])
                breaks[classes - step - 2] = s
                end = s
            }
        }
        return (breaks, previous[nb])
    }

    /// Between-class variance of a partition (the quantity the dynamic program maximizes), in float64.
    public static func partitionScore(histogram: [Int], breaks: [Int]) -> Double {
        let nb = histogram.count
        let total = Double(histogram.reduce(0, +))
        let bounds = [0] + breaks + [nb]
        var score = 0.0
        for i in 0..<(bounds.count - 1) {
            var m = 0.0, mo = 0.0
            for b in bounds[i]..<bounds[i + 1] {
                let w = Double(histogram[b]) / total
                m += w
                mo += w * ((Double(b) + 0.5) / Double(nb) - 0.5)
            }
            if m > 0 { score += mo * mo / m }
        }
        return score
    }

    /// `multi_otsu(image, classes, nbins)`: thresholds (bin edges) and int class labels.
    public static func multiOtsu(_ image: Image2D, classes: Int, nbins: Int = defaultBins) throws
        -> (thresholds: [Double], labels: [Int32]) {
        guard classes >= 1, nbins >= 1, classes <= nbins else { throw Failure.invalid("bad classes/nbins") }
        guard image.count > 0 else { throw Failure.invalid("empty image") }
        guard image.pixels.allSatisfy({ $0.isFinite }) else { throw Failure.invalid("non-finite intensities") }
        if classes == 1 { return ([], [Int32](repeating: 0, count: image.count)) }
        let (lo, hi) = Stats.minMax(image.pixels)
        guard lo != hi else { throw Failure.invalid("constant image") }
        let (counts, edges) = Stats.histogram64(image.pixels, bins: nbins)
        guard counts.filter({ $0 != 0 }).count >= classes else { throw Failure.invalid("too few occupied bins") }
        let (breaks, score) = solve(histogram: counts.map(Double.init), classes: classes)
        guard score.isFinite else { throw Failure.invalid("no valid partition") }
        var totals = [Int](repeating: 0, count: nbins + 1)
        for i in 0..<nbins { totals[i + 1] = totals[i] + counts[i] }
        let bounds = [0] + breaks + [nbins]
        for i in 0..<(bounds.count - 1) where bounds[i + 1] <= bounds[i] || totals[bounds[i + 1]] - totals[bounds[i]] <= 0 {
            throw Failure.invalid("empty class")
        }
        let thresholds = breaks.map { edges[$0] }
        return (thresholds, labels(image.pixels, thresholds: thresholds))
    }

    /// `np.searchsorted(thresholds, image, side="right")`.
    public static func labels(_ pixels: [Float], thresholds: [Double]) -> [Int32] {
        var out = [Int32](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                let op = o
                Parallel.forChunks(p.count) { r in
                    for i in r {
                        let v = Double(p[i])
                        var k: Int32 = 0
                        for t in thresholds where v >= t { k += 1 }
                        op[i] = k
                    }
                }
            }
        }
        return out
    }

    /// `multiotsu_thresholds_and_classes(smoothed, levels)` from useful_functions.py,
    /// including the fallback to no thresholds and an all-zero class map.
    public static func thresholdsAndClasses(_ smoothed: Image2D, levels: Int) -> (thresholds: [Double], classes: [Int32]) {
        let lv = min(max(levels, 2), maxLevels)
        if let r = try? multiOtsu(smoothed, classes: lv, nbins: defaultBins) { return (r.thresholds, r.labels) }
        return ([], [Int32](repeating: 0, count: smoothed.count))
    }
}
