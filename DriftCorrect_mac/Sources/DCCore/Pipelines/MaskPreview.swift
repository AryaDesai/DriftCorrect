import Foundation

/// Z-projected images of an ND2 or TIFF file for the Mask tool
/// (`load_file` / `LazyTifAccessor` in find_threshold.py).
///
/// Both formats load one (t, p) at a time and keep a few recent ones. The
/// Python tool loaded the whole ND2 file into memory at open.
public final class ProjectionSource: @unchecked Sendable {
    public let url: URL
    public let isND2: Bool
    public let t: Int, p: Int, c: Int, y: Int, x: Int
    public let channelNames: [String]
    private let frames: FrameSource
    private let backend: ComputeBackend
    private var cache: [Int: [Image2D]] = [:]
    private var order: [Int] = []
    private let lock = NSLock()
    private let capacity = 6

    public init(url: URL, backend: ComputeBackend) throws {
        self.url = url
        self.backend = backend
        let f: FrameSource
        if url.pathExtension.lowercased() == "nd2" {
            let s = try ND2Source(url: url)
            f = s
            isND2 = true
            channelNames = s.metadata.channelNames
        } else {
            let s = try TIFFSource(url: url)
            f = s
            isND2 = false
            channelNames = s.stack.metadata.channelNames
        }
        frames = f
        t = f.t; p = f.positions; c = f.c; y = f.y; x = f.x
    }

    /// Max-projected (Y, X) float32 image of channel `ci` at (ti, pi).
    public func image(t ti: Int, p pi: Int, c ci: Int) throws -> Image2D {
        try projections(t: ti, p: pi)[ci]
    }

    public func projections(t ti: Int, p pi: Int) throws -> [Image2D] {
        let key = pi * t + ti
        lock.lock()
        if let hit = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        let frame = try frames.readFrame(t: ti, p: pi)
        let proj = try backend.maxProjectAll(frame)
        lock.lock()
        cache[key] = proj
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        return proj
    }

    /// Load (ti, pi) in the background so that playback does not wait for the disk.
    public func prefetch(t ti: Int, p pi: Int) {
        guard ti >= 0 && ti < t && pi >= 0 && pi < p else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in _ = try? self?.projections(t: ti, p: pi) }
    }
}

/// Colours of the Mask tool.
public struct RGB: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) { self.init(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF)) }
}

public enum MaskPreview {
    /// Overlay colour per intensity class (LEVEL_COLORS).
    public static let levelColors: [RGB] = [RGB(255, 50, 50), RGB(50, 200, 255), RGB(120, 255, 80),
                                            RGB(255, 220, 40), RGB(220, 100, 255)]

    public struct HistogramSeries { public var label: String; public var color: RGB; public var counts: [Int] }
    public struct HistogramLine { public var label: String; public var value: Double; public var color: RGB; public var dotted: Bool }

    public struct Histogram {
        public var edges: [Float]
        public var series: [HistogramSeries]
        public var lines: [HistogramLine]
        public var note: String
    }

    public struct Result {
        public var smoothed: Image2D
        public var mask: Mask2D
        public var centroid: (y: Double, x: Double)
        public var classMap: [Int32]?
        public var thresholds: [Double]
        public var area: Int
        public var meanIntensity: Double
        public var caption: String
        public var histogram: Histogram
    }

    /// Cached multi-level Otsu result for one (t, p, channel, sigma, levels) key.
    public struct ClassCache {
        public var key: String
        public var thresholds: [Double]
        public var classes: [Int32]
        public init(key: String, thresholds: [Double], classes: [Int32]) {
            self.key = key; self.thresholds = thresholds; self.classes = classes
        }
    }

    /// numpy float32 `mean()` (pairwise float32 summation, float32 division).
    public static func meanFloat32(_ values: [Float]) -> Float {
        func pw(_ a: UnsafeBufferPointer<Float>) -> Float {
            let n = a.count
            if n < 8 {
                var res: Float = 0
                for v in a { res += v }
                return res
            } else if n <= 128 {
                var r = [a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]]
                var i = 8
                let limit = n - (n % 8)
                while i < limit { for k in 0..<8 { r[k] += a[i + k] }; i += 8 }
                var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
                while i < n { res += a[i]; i += 1 }
                return res
            }
            var n2 = n / 2
            n2 -= n2 % 8
            return pw(UnsafeBufferPointer(rebasing: a[0..<n2])) + pw(UnsafeBufferPointer(rebasing: a[n2..<n]))
        }
        guard !values.isEmpty else { return .nan }
        return values.withUnsafeBufferPointer { pw($0) } / Float(values.count)
    }

    /// One redraw of the Mask tool (`_update` and `_update_histogram`).
    public static func compute(raw: Image2D, params: ThresholdParams, embryo: Int, backend: ComputeBackend,
                               classCache: inout ClassCache?, cacheKey: String) throws -> Result {
        let smoothed = try backend.gaussian(raw, sigma: params.sigma)
        var classMap: [Int32]?
        var thresholds: [Double] = []
        if params.method == "multiotsu" {
            if classCache?.key != cacheKey {
                let r = MultiOtsu.thresholdsAndClasses(smoothed, levels: params.levels)
                classCache = ClassCache(key: cacheKey, thresholds: r.thresholds, classes: r.classes)
            }
            classMap = classCache!.classes
            thresholds = classCache!.thresholds
        }
        let selected = params.selectedLevels ?? []
        let r = try Masking.findLargestMask(smoothed, percentile: params.percentile, method: params.method,
                                            blockSize: params.blockSize, invert: params.invert, levels: params.levels,
                                            selectedLevels: params.method == "multiotsu" ? selected : params.selectedLevels,
                                            classMap: classMap)
        let area = r.mask.trueCount
        var inside = [Float]()
        inside.reserveCapacity(area)
        for i in 0..<r.mask.bits.count where r.mask.bits[i] { inside.append(raw.pixels[i]) }
        let meanValue = area > 0 ? Double(meanFloat32(inside)) : 0.0
        var cap = "Embryo \(embryo)  |  Area: \(area) px (" + PyFormat.fmt("%.1f", Double(area) / Double(r.mask.bits.count) * 100)
            + "%)  |  Centroid: (" + PyFormat.fmt("%.1f, %.1f", r.centroid.x, r.centroid.y)
            + ")  |  Mean intensity: " + PyFormat.fmt("%.1f", meanValue)
        if let map = classMap, !selected.isEmpty {
            let set = Set(selected.map(Int32.init))
            let selectedPx = map.reduce(0) { $0 + (set.contains($1) ? 1 : 0) }
            if selectedPx > 0 {
                cap += "  |  Largest component: " + PyFormat.fmt("%.0f", Double(area) / Double(selectedPx) * 100) + "% of selected"
            }
        }
        let hist = histogram(smoothed: smoothed, mask: r.mask, params: params, classMap: classMap,
                             thresholds: thresholds, selected: selected)
        return Result(smoothed: smoothed, mask: r.mask, centroid: r.centroid, classMap: classMap,
                      thresholds: thresholds, area: area, meanIntensity: meanValue, caption: cap, histogram: hist)
    }

    static func histogram(smoothed: Image2D, mask: Mask2D, params: ThresholdParams, classMap: [Int32]?,
                          thresholds: [Double], selected: [Int]) -> Histogram {
        let (_, edges) = Stats.histogram32(smoothed.pixels, bins: 80)
        let range = (edges.first!, edges.last!)
        func counts(_ values: [Float]) -> [Int] { Stats.histogram32(values, bins: 80, range: range).counts }
        var series: [HistogramSeries] = []
        var lines: [HistogramLine] = []
        var note: String
        if let map = classMap {
            let levels = min(max(params.levels, 2), MultiOtsu.maxLevels)
            var groups = [[Float]](repeating: [], count: levels)
            for i in 0..<map.count where Int(map[i]) < levels { groups[Int(map[i])].append(smoothed.pixels[i]) }
            for i in 0..<levels {
                let state = selected.contains(i) ? "selected" : "not displayed"
                series.append(HistogramSeries(label: "Class \(i) (\(state))", color: levelColors[i % levelColors.count],
                                              counts: counts(groups[i])))
            }
            var markers: [String] = []
            for (i, th) in thresholds.enumerated() {
                lines.append(HistogramLine(label: i == 0 ? "Otsu boundaries" : "", value: th, color: RGB(hex: 0x8A6500), dotted: false))
                markers.append("\(i)/\(i + 1): \(PyFormat.g6(th))")
            }
            note = "Classes are numbered from 0 (darkest), matching the checkboxes. "
            note += "Colours show classes before inclusion and largest-component selection. "
            if !markers.isEmpty { note += "Otsu boundaries: " + markers.joined(separator: "; ") + "." }
            else { note += "Too few distinct intensities: all pixels assigned to class 0; no Otsu boundaries." }
        } else {
            var outside = [Float](), insideVals = [Float]()
            for i in 0..<mask.bits.count {
                if mask.bits[i] { insideVals.append(smoothed.pixels[i]) } else { outside.append(smoothed.pixels[i]) }
            }
            series.append(HistogramSeries(label: "Outside final mask", color: RGB(hex: 0x7A8793), counts: counts(outside)))
            series.append(HistogramSeries(label: "Inside final mask (red overlay)", color: RGB(hex: 0xFF3232), counts: counts(insideVals)))
            let q = Stats.percentile(smoothed.pixels, params.percentile)
            let gate = params.method == "percentile" ? "Percentile threshold" : "Percentile gate"
            lines.append(HistogramLine(label: "\(gate): P\(PyFormat.g(params.percentile)) = \(PyFormat.g6(Double(q)))",
                                       value: Double(q), color: RGB(hex: 0x8A6500), dotted: false))
            note = "Colours show final mask after largest-component selection. "
            if params.method == "percentile_otsu_roi" {
                let base = Mask2D(width: smoothed.width, height: smoothed.height, bits: smoothed.pixels.map { $0 > q })
                if let th = Otsu.roiThreshold(smoothed, percentileMask: base) {
                    lines.append(HistogramLine(label: "ROI-derived Otsu threshold: \(PyFormat.g6(Double(th)))",
                                               value: Double(th), color: RGB(hex: 0x007C91), dotted: true))
                    note += "Otsu is fitted to the largest percentile region, then applied to the full frame."
                } else {
                    note += "ROI empty or constant: masking uses the percentile threshold only."
                }
            } else {
                note += "Pixels must exceed the percentile threshold before inclusion in the final mask. "
            }
        }
        if params.invert {
            note += " Invert Mask is ON: the threshold selection is complemented before keeping the largest component."
        }
        return Histogram(edges: edges, series: series, lines: lines, note: note)
    }

    /// `render_embryo`: gray image, translucent overlay (alpha 100) and a cyan crosshair,
    /// composited with PIL's `alpha_composite` integer arithmetic. Returns RGBA bytes.
    public static func renderComposite(raw: Image2D, mask: Mask2D, centroid: (y: Double, x: Double),
                                       classMap: [Int32]?, selected: [Int]) -> [UInt8] {
        let w = raw.width, h = raw.height
        var vmax = Stats.percentile(raw.pixels, 99.5)
        if vmax == 0 { vmax = 1 }
        let gray = Contrast.scale(raw.pixels, vmax: vmax)
        var colors = [Int32: RGB]()
        for i in selected { colors[Int32(i)] = levelColors[i % levelColors.count] }
        let colorOf = colors
        let maskColor = RGB(255, 50, 50)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        // alpha_composite of an opaque base with an overlay of alpha 100.
        let srcA: UInt32 = 100
        let blend = 255 * (255 - srcA)
        let outa255 = srcA * 255 + blend
        let coef1 = srcA * 255 * 255 * (1 << 7) / outa255
        let coef2 = 255 * (1 << 7) - coef1
        @inline(__always) func mix(_ s: UInt8, _ d: UInt8) -> UInt8 {
            let tmp = UInt32(s) * coef1 + UInt32(d) * coef2 + (0x80 << 7)
            return UInt8(truncatingIfNeeded: (((tmp >> 8) + tmp) >> 8) >> 7)
        }
        out.withUnsafeMutableBufferPointer { o in
            let op = o
            gray.withUnsafeBufferPointer { g in
                Parallel.forChunks(w * h, minChunk: 1 << 14) { r in
                    for i in r {
                        let v = g[i]
                        var color: RGB? = nil
                        if let map = classMap { color = colorOf[map[i]] } else if mask.bits[i] { color = maskColor }
                        if let c = color {
                            op[4 * i] = mix(c.r, v); op[4 * i + 1] = mix(c.g, v); op[4 * i + 2] = mix(c.b, v)
                        } else {
                            op[4 * i] = v; op[4 * i + 1] = v; op[4 * i + 2] = v
                        }
                        op[4 * i + 3] = 255
                    }
                }
            }
        }
        // Crosshair: arms of 25 px, 7 px wide.
        let cy = Shift.pyRound(centroid.y), cx = Shift.pyRound(centroid.x)
        func fill(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) {
            let ya = max(0, y0), yb = min(h - 1, y1), xa = max(0, x0), xb = min(w - 1, x1)
            guard ya <= yb, xa <= xb else { return }
            for yy in ya...yb {
                for xx in xa...xb {
                    let k = 4 * (yy * w + xx)
                    out[k] = 0; out[k + 1] = 255; out[k + 2] = 255; out[k + 3] = 255
                }
            }
        }
        if cy - 28 < h && cy + 28 >= 0 && cx - 28 < w && cx + 28 >= 0 {
            fill(cy - 3, cy + 3, cx - 25, cx + 25)
            fill(cy - 25, cy + 25, cx - 3, cx + 3)
        }
        return out
    }
}

/// Save of the Mask tool (`_save_yaml` in find_threshold.py).
public enum MaskSave {
    /// `{base}_P{p}_{channel}_threshold.yaml` for ND2, `{base}_{channel}_threshold.yaml` for TIFF,
    /// next to the input file.
    public static func url(for source: ProjectionSource, embryo p: Int, channel: String) -> URL {
        var base = PyFormat.stem(source.url)
        let name: String
        if source.isND2 {
            name = "\(base)_P\(p)_\(channel)_threshold.yaml"
        } else {
            if base.hasSuffix(".ome") { base = String(base.dropLast(4)) }
            name = "\(base)_\(channel)_threshold.yaml"
        }
        return source.url.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)
    }

    @discardableResult
    public static func save(source: ProjectionSource, embryo p: Int, t: Int, params: ThresholdParams,
                            perTimepoint: [ThresholdParams], backend: ComputeBackend) throws -> URL {
        let img = try source.image(t: t, p: p, c: params.channelIndex)
        let smoothed = try backend.gaussian(img, sigma: params.sigma)
        let r = try Masking.findLargestMask(smoothed, percentile: params.percentile, method: params.method,
                                            blockSize: params.blockSize, invert: params.invert, levels: params.levels,
                                            selectedLevels: params.method == "multiotsu" ? (params.selectedLevels ?? []) : nil)
        let area = r.mask.trueCount
        var inside = [Float]()
        for i in 0..<r.mask.bits.count where r.mask.bits[i] { inside.append(img.pixels[i]) }
        let mean = area > 0 ? PyFormat.round(Double(MaskPreview.meanFloat32(inside)), 2) : 0.0
        let d = ThresholdYAML.Diagnostics(timePoint: t, savedAt: ThresholdYAML.nowISO(), embryoID: p, maskAreaPx: area,
                                          maskAreaPct: PyFormat.round(Double(area) / Double(r.mask.bits.count) * 100, 2),
                                          meanIntensity: mean,
                                          centroidXY: (PyFormat.round(r.centroid.x, 2), PyFormat.round(r.centroid.y, 2)))
        let doc = ThresholdYAML.document(parameters: params, perTimepoint: perTimepoint, sourceFile: source.url.path,
                                         t: source.t, p: source.p, y: source.y, x: source.x, diagnostics: d)
        let out = url(for: source, embryo: p, channel: params.channel)
        try YAMLWriter.dump(doc).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
