import Foundation

public enum Contrast {
    /// `auto_contrast(img, percentile=99.5)`: float32 image to uint8 gray.
    public static func autoContrast(_ img: [Float], percentile: Double = 99.5) -> [UInt8] {
        var vmax = Stats.percentile(img, percentile)
        if vmax == 0 { vmax = 1 }
        return scale(img, vmax: vmax)
    }

    /// `np.clip(img / vmax * 255, 0, 255).astype(np.uint8)` in float32.
    public static func scale(_ img: [Float], vmax: Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: img.count)
        img.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf
                Parallel.forChunks(src.count, minChunk: 1 << 15) { r in
                    for i in r {
                        var v = src[i] / vmax * Float(255)
                        if !(v > 0) { v = 0 }
                        if v > 255 { v = 255 }
                        dst[i] = UInt8(v)
                    }
                }
            }
        }
        return out
    }
}
