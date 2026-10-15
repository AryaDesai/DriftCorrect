import Foundation

public enum Stats {
    // MARK: Selection

    /// k-th smallest element (0-based); partially reorders `a`.
    static func select(_ buffer: UnsafeMutableBufferPointer<Float>, _ k: Int) -> Float {
        var a = buffer
        var lo = 0, hi = a.count - 1
        while hi > lo {
            // Median of three pivot.
            let mid = lo + (hi - lo) / 2
            if a[mid] < a[lo] { a.swapAt(mid, lo) }
            if a[hi] < a[lo] { a.swapAt(hi, lo) }
            if a[hi] < a[mid] { a.swapAt(hi, mid) }
            let pivot = a[mid]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return a[k] }
        }
        return a[k]
    }

    /// `np.percentile(values, q)` with the default "linear" method, for float32 data.
    ///
    /// Reproduces numpy 2 exactly: the virtual index is `(n - 1) * (q / 100)`
    /// in float64 and the interpolation is numpy's `_lerp` in float32.
    public static func percentile(_ values: [Float], _ q: Double) -> Float {
        let n = values.count
        precondition(n > 0, "percentile of empty array")
        var work = values
        return work.withUnsafeMutableBufferPointer { a -> Float in
            let v = Double(n - 1) * (q / 100.0)
            if v >= Double(n - 1) {
                var m = a[0]
                for i in 1..<n where a[i] > m { m = a[i] }
                return m
            }
            if v < 0 {
                var m = a[0]
                for i in 1..<n where a[i] < m { m = a[i] }
                return m
            }
            let prev = Int(v.rounded(.down))
            let gamma = v - Double(prev)
            let lower = select(a, prev)
            // After selection every element right of `prev` is >= lower; the next order statistic is their minimum.
            var upper = Float.infinity
            for i in (prev + 1)..<n where a[i] < upper { upper = a[i] }
            return lerp(lower, upper, gamma)
        }
    }

    /// numpy `_lerp(a, b, t)` with float32 operands and a weak Python-float `t`.
    @inline(__always)
    public static func lerp(_ a: Float, _ b: Float, _ t: Double) -> Float {
        let diff = b - a
        if t >= 0.5 {
            return b - diff * Float(1.0 - t)
        }
        return a + diff * Float(t)
    }

    /// Several percentiles of the same data (sorted once).
    public static func percentiles(_ values: [Float], _ qs: [Double]) -> [Float] {
        let n = values.count
        precondition(n > 0)
        let sorted = values.sorted()
        return qs.map { q in
            let v = Double(n - 1) * (q / 100.0)
            if v >= Double(n - 1) { return sorted[n - 1] }
            if v < 0 { return sorted[0] }
            let prev = Int(v.rounded(.down))
            return lerp(sorted[prev], sorted[prev + 1], v - Double(prev))
        }
    }

    public static func minMax(_ values: [Float]) -> (min: Float, max: Float) {
        var lo = Float.infinity, hi = -Float.infinity
        for v in values { if v < lo { lo = v }; if v > hi { hi = v } }
        return (lo, hi)
    }

    // MARK: Histograms

    /// `np.histogram(values.astype(np.float64), bins=nbins)` — counts and float64 edges.
    public static func histogram64(_ values: [Float], bins nbins: Int) -> (counts: [Int], edges: [Double]) {
        var first = Double.infinity, last = -Double.infinity
        for v in values { let d = Double(v); if d < first { first = d }; if d > last { last = d } }
        if values.isEmpty { first = 0; last = 1 }
        if first == last { first -= 0.5; last += 0.5 }
        let step = (last - first) / Double(nbins)
        var edges = [Double](repeating: 0, count: nbins + 1)
        for i in 0...nbins { edges[i] = Double(i) * step + first }
        edges[nbins] = last
        let denom = last - first
        var counts = [Int](repeating: 0, count: nbins)
        let norm = Double(nbins)
        for v in values {
            let a = Double(v)
            var idx = Int((a - first) / denom * norm)
            if idx == nbins { idx -= 1 }
            if a < edges[idx] { idx -= 1 }
            if idx != nbins - 1 && a >= edges[idx + 1] { idx += 1 }
            counts[idx] += 1
        }
        return (counts, edges)
    }

    /// `np.histogram_bin_edges(float32_values, bins)` and counts, computed in float32 as numpy does
    /// for float32 input (display histogram in the Mask tool).
    public static func histogram32(_ values: [Float], bins nbins: Int, range: (Float, Float)? = nil)
        -> (counts: [Int], edges: [Float]) {
        let mm = minMax(values)
        var (first, last) = range ?? (mm.min, mm.max)
        if values.isEmpty && range == nil { first = 0; last = 1 }
        if first == last { first -= 0.5; last += 0.5 }
        let step = (last - first) / Float(nbins)
        var edges = [Float](repeating: 0, count: nbins + 1)
        for i in 0...nbins { edges[i] = Float(i) * step + first }
        edges[nbins] = last
        let denom = last - first
        var counts = [Int](repeating: 0, count: nbins)
        for a in values where a >= first && a <= last {
            var idx = Int((a - first) / denom * Float(nbins))
            if idx >= nbins { idx = nbins - 1 }
            if idx < 0 { idx = 0 }
            if a < edges[idx] && idx > 0 { idx -= 1 }
            if idx != nbins - 1 && a >= edges[idx + 1] { idx += 1 }
            counts[idx] += 1
        }
        return (counts, edges)
    }
}
