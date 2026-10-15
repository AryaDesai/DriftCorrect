import Foundation

/// `_threshold_local_otsu_torch` (methods "local_otsu_interp" and "local_otsu_pixel").
///
/// The float32 arithmetic follows the PyTorch CPU code path operation by
/// operation. These methods are reachable only from a hand-edited YAML.
public enum LocalOtsu {
    /// `batched_otsu` for one patch histogram: first argmax of the between-class variance.
    static func otsuIndex(_ hist: UnsafeBufferPointer<Float>, patchSize: Int) -> Int {
        var w1: Float = 0, cs: Float = 0
        var total: Float = 0
        for i in 0..<256 { total += hist[i] * Float(i) }
        let P = Float(patchSize)
        let eps: Float = 1e-8
        var best: Float = -.infinity
        var arg = 0
        for i in 0..<256 {
            w1 += hist[i]
            cs += hist[i] * Float(i)
            let w2 = P - w1
            let m1 = cs / (w1 + eps)
            let m2 = (total - cs) / (w2 + eps)
            let d = m1 - m2
            let v = w1 * w2 * (d * d)
            if v > best { best = v; arg = i }
        }
        return arg
    }

    /// Scaled uint8 image: `((s - vmin) / (vmax - vmin) * 255.0).clamp(0, 255).to(torch.uint8)`.
    static func scaled(_ s: Image2D, vmin: Float, vmax: Float) -> [UInt8] {
        let range = vmax - vmin
        return s.pixels.map { v in
            var t = (v - vmin) / range * Float(255.0)
            if t < 0 { t = 0 }
            if t > 255 { t = 255 }
            return UInt8(t)
        }
    }

    public static func mask(_ smoothed: Image2D, percentile: Double, blockSize: Int, interpolate: Bool) throws -> Mask2D {
        let H = smoothed.height, W = smoothed.width
        let (vmin, vmax) = Stats.minMax(smoothed.pixels)
        if vmax <= vmin {
            return Mask2D(width: W, height: H, bits: smoothed.pixels.map { $0 > vmin })
        }
        let bs = max(1, blockSize)
        let img = scaled(smoothed, vmin: vmin, vmax: vmax)
        var thresholdIndex = [Float](repeating: 0, count: W * H)  // out_thresh / upscaled

        if !interpolate {
            // Sliding window, reflect padding (torch "reflect" excludes the edge sample).
            let padL = bs / 2
            let padT = bs / 2
            guard padL < W && padT < H else {
                throw DCError("local_otsu_pixel: block size \(bs) is too large for a \(W)x\(H) image")
            }
            func refl(_ i: Int, _ n: Int) -> Int {
                var k = i
                if n == 1 { return 0 }
                let period = 2 * (n - 1)
                k %= period
                if k < 0 { k += period }
                return k < n ? k : period - k
            }
            let patch = bs * bs
            thresholdIndex.withUnsafeMutableBufferPointer { outBuf in
                let out = outBuf
                img.withUnsafeBufferPointer { src in
                    Parallel.forChunks(H, minChunk: 1) { rows in
                        var hist = [Float](repeating: 0, count: 256)
                        for y in rows {
                            // Sliding histogram along the row.
                            for i in 0..<256 { hist[i] = 0 }
                            let ys = (0..<bs).map { refl(y - padT + $0, H) }
                            for dx in 0..<bs {
                                let xx = refl(0 - padL + dx, W)
                                for yy in ys { hist[Int(src[yy * W + xx])] += 1 }
                            }
                            hist.withUnsafeBufferPointer { out[y * W] = Float(otsuIndex($0, patchSize: patch)) }
                            if W > 1 {
                                for x in 1..<W {
                                    let removeX = refl(x - 1 - padL, W)
                                    let addX = refl(x - 1 - padL + bs, W)
                                    for yy in ys {
                                        hist[Int(src[yy * W + removeX])] -= 1
                                        hist[Int(src[yy * W + addX])] += 1
                                    }
                                    hist.withUnsafeBufferPointer { out[y * W + x] = Float(otsuIndex($0, patchSize: patch)) }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            let gh = max(1, H / bs), gw = max(1, W / bs)
            guard gh * bs <= H && gw * bs <= W else {
                throw DCError("local_otsu_interp: block size \(bs) is too large for a \(W)x\(H) image")
            }
            var block = [Float](repeating: 0, count: gh * gw)
            var hist = [Float](repeating: 0, count: 256)
            for by in 0..<gh {
                for bx in 0..<gw {
                    for i in 0..<256 { hist[i] = 0 }
                    for yy in (by * bs)..<((by + 1) * bs) {
                        for xx in (bx * bs)..<((bx + 1) * bs) { hist[Int(img[yy * W + xx])] += 1 }
                    }
                    block[by * gw + bx] = hist.withUnsafeBufferPointer { Float(otsuIndex($0, patchSize: bs * bs)) }
                }
            }
            // F.interpolate(mode="bilinear", align_corners=False), PyTorch CPU index/weight rules.
            func weights(_ outSize: Int, _ inSize: Int) -> [(i0: Int, i1: Int, l0: Float, l1: Float)] {
                let scale = Float(inSize) / Float(outSize)
                return (0..<outSize).map { o in
                    var real = scale * (Float(o) + 0.5) - 0.5
                    if real < 0 { real = 0 }
                    let i0 = min(Int(real.rounded(.down)), inSize - 1)
                    let l1 = min(max(real - Float(i0), 0), 1)
                    let i1 = i0 + (i0 < inSize - 1 ? 1 : 0)
                    return (i0: i0, i1: i1, l0: 1 - l1, l1: l1)
                }
            }
            let wy = weights(H, gh), wx = weights(W, gw)
            for y in 0..<H {
                let a = wy[y]
                for x in 0..<W {
                    let b = wx[x]
                    let top = b.l0 * block[a.i0 * gw + b.i0] + b.l1 * block[a.i0 * gw + b.i1]
                    let bottom = b.l0 * block[a.i1 * gw + b.i0] + b.l1 * block[a.i1 * gw + b.i1]
                    thresholdIndex[y * W + x] = a.l0 * top + a.l1 * bottom
                }
            }
        }

        let range = vmax - vmin
        let q = Stats.percentile(smoothed.pixels, percentile)
        var bits = [Bool](repeating: false, count: W * H)
        for i in 0..<(W * H) {
            let th = (thresholdIndex[i] / Float(255.0)) * range + vmin
            let v = smoothed.pixels[i]
            bits[i] = v > th && v > q
        }
        return Mask2D(width: W, height: H, bits: bits)
    }
}
