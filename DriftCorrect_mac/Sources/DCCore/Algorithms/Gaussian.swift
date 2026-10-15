import Foundation

/// `scipy.ndimage.gaussian_filter(image, sigma)` for float32 images, bit for bit.
///
/// scipy filters axis 0 (Y) then axis 1 (X). Each pass accumulates in
/// double precision in a fixed order, extends lines with mode "reflect"
/// (d c b a | a b c d | d c b a) and stores float32 between passes.
public enum Gaussian {
    /// numpy's pairwise summation for a contiguous float64 array (`ndarray.sum()`).
    public static func pairwiseSum(_ a: UnsafeBufferPointer<Double>) -> Double {
        let n = a.count
        if n < 8 {
            var res = 0.0
            for v in a { res += v }
            return res
        } else if n <= 128 {
            var r = (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
            var i = 8
            let limit = n - (n % 8)
            while i < limit {
                r.0 += a[i]; r.1 += a[i + 1]; r.2 += a[i + 2]; r.3 += a[i + 3]
                r.4 += a[i + 4]; r.5 += a[i + 5]; r.6 += a[i + 6]; r.7 += a[i + 7]
                i += 8
            }
            var res = ((r.0 + r.1) + (r.2 + r.3)) + ((r.4 + r.5) + (r.6 + r.7))
            while i < n { res += a[i]; i += 1 }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwiseSum(UnsafeBufferPointer(rebasing: a[0..<n2]))
                + pairwiseSum(UnsafeBufferPointer(rebasing: a[n2..<n]))
        }
    }

    /// scipy `_gaussian_kernel1d(sigma, 0, radius)` with `radius = int(truncate * sigma + 0.5)`.
    public static func kernel(sigma: Double, truncate: Double = 4.0) -> (weights: [Double], radius: Int) {
        let radius = Int(truncate * sigma + 0.5)
        let sigma2 = sigma * sigma
        let factor = -0.5 / sigma2
        var phi = [Double](repeating: 0, count: 2 * radius + 1)
        for i in 0...(2 * radius) {
            let x = Double(i - radius)
            phi[i] = exp(factor * (x * x))
        }
        let total = phi.withUnsafeBufferPointer { pairwiseSum($0) }
        for i in 0..<phi.count { phi[i] /= total }
        return (phi, radius)
    }

    /// Index into a line of length `n` with scipy "reflect" extension.
    @inline(__always)
    public static func reflect(_ i: Int, _ n: Int) -> Int {
        if i >= 0 && i < n { return i }
        let period = 2 * n
        var m = i % period
        if m < 0 { m += period }
        return m >= n ? period - 1 - m : m
    }

    /// One scipy `correlate1d` pass over lines of length `n`.
    /// `load(k)` returns element k of the line, `store(k, v)` writes the float32 result.
    @inline(__always)
    static func correlateLine(n: Int, weights w: UnsafeBufferPointer<Double>, radius r: Int,
                              ext: UnsafeMutableBufferPointer<Double>,
                              load: (Int) -> Float, store: (Int, Float) -> Void) {
        // Extended line buffer: ext[k + r] = line[reflect(k)] for k in -r ..< n + r.
        for k in -r..<(n + r) { ext[k + r] = Double(load(reflect(k, n))) }
        let center = w[r]
        for i in 0..<n {
            let c = i + r
            var acc = ext[c] * center
            // scipy symmetric loop: jj from -r up to -1, weight fw[jj] = w[r + jj].
            var jj = -r
            while jj < 0 {
                acc += (ext[c + jj] + ext[c - jj]) * w[r + jj]
                jj += 1
            }
            store(i, Float(acc))
        }
    }

    /// Exact CPU implementation (reference and fallback).
    public static func filter(_ image: Image2D, sigma: Double, truncate: Double = 4.0) -> Image2D {
        if sigma <= 1e-15 { return image }
        let (weights, radius) = kernel(sigma: sigma, truncate: truncate)
        let w = image.width, h = image.height
        if w == 0 || h == 0 { return image }
        var tmp = image.pixels
        var out = image.pixels
        weights.withUnsafeBufferPointer { wp in
            // Axis 0: columns.
            image.pixels.withUnsafeBufferPointer { src in
                tmp.withUnsafeMutableBufferPointer { dst in
                    let d = dst
                    Parallel.forChunks(w, minChunk: 8) { cols in
                        let ext = UnsafeMutableBufferPointer<Double>.allocate(capacity: h + 2 * radius)
                        defer { ext.deallocate() }
                        for x in cols {
                            correlateLine(n: h, weights: wp, radius: radius, ext: ext,
                                          load: { src[$0 * w + x] }, store: { d[$0 * w + x] = $1 })
                        }
                    }
                }
            }
            // Axis 1: rows.
            tmp.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let d = dst
                    Parallel.forChunks(h, minChunk: 8) { rows in
                        let ext = UnsafeMutableBufferPointer<Double>.allocate(capacity: w + 2 * radius)
                        defer { ext.deallocate() }
                        for y in rows {
                            let base = y * w
                            correlateLine(n: w, weights: wp, radius: radius, ext: ext,
                                          load: { src[base + $0] }, store: { d[base + $0] = $1 })
                        }
                    }
                }
            }
        }
        return Image2D(width: w, height: h, pixels: out)
    }
}
