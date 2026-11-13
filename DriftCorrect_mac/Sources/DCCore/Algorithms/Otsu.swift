import Foundation

public enum Otsu {
    /// Return the threshold that OpenCV finds with `cv2.threshold(u8, 0, 255, THRESH_BINARY + THRESH_OTSU)`.
    public static func cv2Threshold(histogram h: [Int], total: Int) -> Int {
        let fltEpsilon = Double(Float.ulpOfOne)
        let scale = 1.0 / Double(total)
        var mu = 0.0
        for i in 0..<256 { mu += Double(i) * Double(h[i]) }
        mu *= scale
        var mu1 = 0.0, q1 = 0.0
        var maxSigma = 0.0
        var maxVal = 0
        for i in 0..<256 {
            let pi = Double(h[i]) * scale
            mu1 *= q1
            q1 += pi
            let q2 = 1.0 - q1
            if min(q1, q2) < fltEpsilon || max(q1, q2) > 1.0 - fltEpsilon { continue }
            mu1 = (mu1 + Double(i) * pi) / q1
            let mu2 = (mu - q1 * mu1) / q2
            let sigma = q1 * q2 * (mu1 - mu2) * (mu1 - mu2)
            if sigma > maxSigma {
                maxSigma = sigma
                maxVal = i
            }
        }
        return maxVal
    }

    /// Scale a value to uint8 in float32, as `np.clip((v - vmin) / (vmax - vmin) * 255, 0, 255).astype(np.uint8)` does.
    @inline(__always)
    public static func toUInt8(_ v: Float, vmin: Float, range: Float) -> UInt8 {
        var s = (v - vmin) / range * Float(255)
        if s < 0 { s = 0 }
        if s > 255 { s = 255 }
        return UInt8(s)  // The conversion truncates toward zero.
    }

    /// Convert a uint8 threshold back to the scale of the image, as `thresh_uint8 / 255.0 * (vmax - vmin) + vmin`
    /// does. The result is float32, as in numpy 2.
    @inline(__always)
    public static func floatThreshold(_ t: Int, vmin: Float, vmax: Float) -> Float {
        Float(Double(t) / 255.0) * (vmax - vmin) + vmin
    }

    /// Return the Otsu threshold of a set of float32 values after scaling them to uint8. The result is nil when the
    /// values are constant.
    public static func threshold(ofValues values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let (vmin, vmax) = Stats.minMax(values)
        guard vmax > vmin else { return nil }
        let range = vmax - vmin
        var hist = [Int](repeating: 0, count: 256)
        for v in values { hist[Int(toUInt8(v, vmin: vmin, range: range))] += 1 }
        let t = cv2Threshold(histogram: hist, total: values.count)
        return floatThreshold(t, vmin: vmin, vmax: vmax)
    }

    /// Threshold the whole image with Otsu, as `_threshold_global_otsu(smoothed)` does in the Python scripts.
    public static func globalMask(_ smoothed: Image2D) -> Mask2D {
        guard let th = threshold(ofValues: smoothed.pixels) else {
            // In a constant image the threshold equals vmin, so no pixel exceeds it.
            return Mask2D(width: smoothed.width, height: smoothed.height)
        }
        return Mask2D(width: smoothed.width, height: smoothed.height, bits: smoothed.pixels.map { $0 > th })
    }

    /// Threshold at a percentile, as `_threshold_percentile(smoothed, percentile)` does in the Python scripts.
    public static func percentileMask(_ smoothed: Image2D, _ percentile: Double) -> (mask: Mask2D, threshold: Float) {
        let q = Stats.percentile(smoothed.pixels, percentile)
        return (Mask2D(width: smoothed.width, height: smoothed.height, bits: smoothed.pixels.map { $0 > q }), q)
    }

    /// Return the threshold that `_threshold_percentile_otsu_roi` derives from the largest region above the
    /// percentile, where pixels connect along their edges. The result is nil when that method falls back to the
    /// percentile mask. The Mask tool also draws this threshold in its histogram.
    public static func roiThreshold(_ smoothed: Image2D, percentileMask: Mask2D) -> Float? {
        let comps = Labeling.label(percentileMask, eightConnected: false)
        guard let roi = comps.largest else { return nil }
        var values = [Float]()
        values.reserveCapacity(comps.sizes[roi])
        smoothed.pixels.withUnsafeBufferPointer { p in comps.forEachPixel(of: roi) { values.append(p[$0]) } }
        return threshold(ofValues: values)
    }

    /// Threshold with Otsu inside the percentile region, as `_threshold_percentile_otsu_roi` does.
    public static func percentileOtsuROIMask(_ smoothed: Image2D, _ percentile: Double) -> Mask2D {
        let (base, _) = percentileMask(smoothed, percentile)
        guard let th = roiThreshold(smoothed, percentileMask: base) else { return base }
        return Mask2D(width: smoothed.width, height: smoothed.height, bits: smoothed.pixels.map { $0 > th })
    }
}
