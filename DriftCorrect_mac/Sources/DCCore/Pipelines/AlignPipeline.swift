import Foundation

/// Port of `centroid_align_xy.py` (the "Align movie" tool).
///
/// Differences from the Python script, by design:
/// - Every YAML setting is used: method, invert, levels, selected classes,
///   block size and the per-timepoint parameters. The Python worker used only
///   sigma, percentile and channel_index, so its result could differ from the
///   Mask tool preview.
/// - `--use_nd2` writes the unaligned movies from the ND2 frames. The Python
///   script stopped with a NameError at that step.
/// - Movies are encoded while the frames pass through, not by reading the
///   TIFFs again afterwards. The frames and the contrast rule are the same.
/// - The unaligned movie name is `{stem}_{channel}_unaligned.mp4` for both
///   canvas modes (the two-pass Python path produced a different name).
/// - With `xyMatching` set, the xy shift comes from image matching between neighbouring timepoints, as `XYMatch`
///   describes, in place of the centroid of the embryo mask.
/// - With `zCorrection` set, z correction runs after the xy alignment, as `ZDrift` describes. The output is then
///   `{stem}_xy_z.ome.tif` and `{stem}_xy_z_shifts.csv`.
public struct AlignOptions {
    public var yaml: URL
    public var useND2 = false
    public var fps: Double = 2
    public var enlargeCanvas = true
    public var shiftMode: ShiftMode = .subpixel
    public var lowMemory = false
    /// Settings of the xy alignment by image matching. When nil, the centroid of the embryo mask is centred.
    public var xyMatching: XYMatchOptions?
    /// Settings of the z correction. When nil, only the xy alignment runs.
    public var zCorrection: ZCorrectionOptions?
    public init(yaml: URL) { self.yaml = yaml }
}

public struct AlignResult {
    public var outputDirectory: URL
    public var tiffs: [URL] = []
    public var movies: [URL] = []
    /// shifts[p][t] = (dy, dx)
    public var shifts: [[(dy: Double, dx: Double)]] = []
    /// The z correction of each embryo. `zSteps` holds what was measured at every timepoint and `zPlans` holds
    /// the shifts in whole slices.
    public var zSteps: [[ZStep]] = []
    public var zPlans: [ZPlan] = []
}

public final class AlignPipeline {
    let options: AlignOptions
    let backend: ComputeBackend
    let movies: MovieWriterFactory?
    let ctx: RunContext

    public init(options: AlignOptions, backend: ComputeBackend, movies: MovieWriterFactory?, context: RunContext) {
        self.options = options
        self.backend = backend
        self.movies = movies
        self.ctx = context
    }

    struct Input {
        var source: FrameSource
        var base: String
        var outDir: URL
        var isND2: Bool
        /// Stem used for TIF-based output names (`Path.stem` minus `.ome`).
        var stem: String
    }

    /// Resolve the input file with the same rules as the Python script.
    public static func resolveTIF(yaml: URL, sourceFile: String) throws -> (url: URL, base: String) {
        let src = URL(fileURLWithPath: sourceFile)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue,
           [".tif", ".tiff"].contains("." + src.pathExtension.lowercased()) {
            return (src, PyFormat.stemWithoutOME(src))
        }
        let stem = PyFormat.stem(yaml)
        let parts = stem.components(separatedBy: "_P")
        guard parts.count > 1 else {
            throw DCError("Could not derive embryo ID from \(yaml.lastPathComponent) and source file not found.")
        }
        let pID = "P" + (parts[1].components(separatedBy: "_").first ?? "")
        let candidates = globFiles(yaml.deletingLastPathComponent(), pattern: "\(pID)*.ome.tif")
        guard let first = candidates.first else {
            throw DCError("no TIF found for \(pID) in \(yaml.deletingLastPathComponent().path)")
        }
        return (first, pID)
    }

    func openInput(_ cfg: ThresholdConfig) throws -> Input {
        if options.useND2 {
            let nd2 = URL(fileURLWithPath: cfg.sourceFile)
            guard FileManager.default.fileExists(atPath: nd2.path) else {
                throw DCError("ND2 file not found: \(nd2.path)")
            }
            ctx.log("Loading \(nd2.path) ...")
            let src = try ND2Source(url: nd2)
            let base = PyFormat.stem(nd2)
            ctx.log("  Shape: T=\(src.t), P=\(src.positions), Z=\(src.z), C=\(src.c), Y=\(src.y), X=\(src.x)")
            return Input(source: src, base: base,
                         outDir: nd2.deletingLastPathComponent().appendingPathComponent("aligned_\(base)"),
                         isND2: true, stem: base)
        }
        let (tif, base) = try AlignPipeline.resolveTIF(yaml: options.yaml, sourceFile: cfg.sourceFile)
        if tif.path == URL(fileURLWithPath: cfg.sourceFile).path { ctx.log("Using source file from YAML: \(tif.path)") }
        ctx.log("Loading \(tif.lastPathComponent) ...")
        let src = try TIFFSource(url: tif)
        ctx.log("  Shape: T=\(src.t), C=\(src.c), Z=\(src.z), Y=\(src.y), X=\(src.x)")
        return Input(source: src, base: base,
                     outDir: tif.deletingLastPathComponent().appendingPathComponent("aligned_\(base)"),
                     isND2: false, stem: PyFormat.stemWithoutOME(tif))
    }

    /// The suffix that output names get when z correction is on. It keeps the output apart from the output of a
    /// run without z correction.
    var zSuffix: String { options.zCorrection == nil ? "" : "_z" }

    func tiffURL(_ input: Input, p: Int) -> URL {
        input.isND2 ? input.outDir.appendingPathComponent("\(input.base)_P\(p)\(zSuffix).ome.tif")
                    : input.outDir.appendingPathComponent("\(input.stem)_xy\(zSuffix).ome.tif")
    }

    func movieURLs(_ input: Input, p: Int, aligned: Bool) -> [URL] {
        input.source.metadata.channelNames.prefix(input.source.c).map { ch in
            if input.isND2 {
                return input.outDir.appendingPathComponent(aligned ? "\(input.base)_P\(p)\(zSuffix)_\(ch)_aligned.mp4"
                                                                    : "\(input.base)_P\(p)_\(ch)_unaligned.mp4")
            }
            return input.outDir.appendingPathComponent(aligned ? "\(input.stem)_xy\(zSuffix)_\(ch)_aligned.mp4"
                                                                : "\(input.stem)_\(ch)_unaligned.mp4")
        }
    }

    public func run() throws -> AlignResult {
        let cfg = try ThresholdConfig.load(options.yaml)
        let input = try openInput(cfg)
        let src = input.source
        let names = src.metadata.channelNames
        guard names.count >= src.c else { throw DCError("The file has \(src.c) channels but only \(names.count) names") }
        let top = cfg.parameters
        ctx.log("  Channels: \(names)")
        if top.channelIndex >= 0 && top.channelIndex < names.count {
            ctx.log("  Threshold channel: \(names[top.channelIndex]) (index \(top.channelIndex))")
        }
        ctx.log("  sigma=\(PyFormat.g(top.sigma)), percentile=\(PyFormat.g(top.percentile)), method=\(top.method)")
        ctx.log("  Compute: \(backend.name), shift: \(options.shiftMode.rawValue)")
        try FileManager.default.createDirectory(at: input.outDir, withIntermediateDirectories: true)
        ctx.log("  Output: \(input.outDir.path)")

        var result = AlignResult(outputDirectory: input.outDir)
        try twoPass(cfg, input, &result)
        return result
    }

    // MARK: Two passes

    /// Pass 1 measures the shift of every timepoint. Pass 2 applies the shifts and writes the output. The canvas
    /// size, the image matching and the z correction all need every shift before anything is written.

    private func twoPass(_ cfg: ThresholdConfig, _ input: Input, _ result: inout AlignResult) throws {
        let src = input.source
        let T = src.t, P = src.positions
        let width = pipelineWidth(frameBytes: src.frameBytes)
        let cache = FrameCache(enabled: !options.lowMemory && FrameCache.fits(bytes: src.frameBytes * T * P))
        var trackers: [ZTracker] = []
        let zopt = options.zCorrection, xyopt = options.xyMatching
        if let limit = zopt?.maximumStep, !limit.isFinite || limit <= 0 {
            throw DCError("Maximum shift must be a positive number of slices")
        }
        let names = src.metadata.channelNames
        func name(_ c: Int) -> String { c < names.count ? names[c] : "ch\(c)" }
        let zChannel = try zopt?.resolveChannel(names: names, count: src.c, fallback: cfg.parameters.channelIndex) ?? 0
        let xyChannel = try xyopt.map {
            try resolveChannel(index: $0.channelIndex, name: $0.channelName, names: names, count: src.c,
                               fallback: cfg.parameters.channelIndex, label: "XY")
        } ?? 0
        // The embryo mask is needed for the centroid, and for image matching or z correction that follow the mask.
        let needsMask = xyopt == nil || xyopt?.region == .embryoMask || zopt?.region == .embryoMask
        ctx.log(xyopt == nil ? "  XY: centroid of the embryo mask"
                             : "  XY: image matching of \(name(xyChannel)) (index \(xyChannel)), following \(describe(xyopt!.region))")
        if let z = zopt { ctx.log("  Z correction: \(name(zChannel)) (index \(zChannel)), following \(describe(z.region))") }

        ctx.log("\n--- Pass 1: precomputing shifts ---")
        var shifts = [[(dy: Double, dx: Double)]](repeating: [], count: P)
        struct Item {
            var frame: Volume
            var detection: Detection.Result?
            var gray: [[UInt8]]
            var xy: XYFrame?
        }
        for p in 0..<P {
            ctx.log("\n  Embryo \(p)/\(P - 1):")
            let tracker = zopt.map { ZTracker(options: $0) }
            var zBox: ZBox?
            // The previous timepoint for image matching, with its mask and its shift so far.
            var previous: (frame: XYFrame, mask: Mask2D?)?
            var position = (dy: 0.0, dx: 0.0)
            let unaligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: false),
                                  width: src.x, height: src.y, fps: options.fps)
            }
            do {
                try orderedPipeline(count: T, width: width, context: ctx, produce: { t -> Item in
                    let frame = try src.readFrame(t: t, p: p)
                    let detection = needsMask ? try Detection.computeShift(frame: frame, params: try cfg.params(forTimepoint: t),
                                                                           backend: self.backend) : nil
                    var gray: [[UInt8]] = []
                    var xy: XYFrame?
                    if unaligned != nil {
                        let projections = try self.backend.maxProjectAll(frame)
                        gray = ChannelMovies.grayFrames(projections)
                        if xyopt != nil { xy = XYMatch.prepare(projections[xyChannel]) }
                    } else if xyopt != nil {
                        xy = XYMatch.prepare(try self.backend.maxProjectZ(frame, channel: xyChannel))
                    }
                    cache.put(p * T + t, frame)
                    return Item(frame: frame, detection: detection, gray: gray, xy: xy)
                }, consume: { t, item in
                    // The xy shift of this timepoint.
                    var line: String
                    if let current = item.xy {
                        var cost = 0.0
                        if let prev = previous {
                            let region = XYMatch.region(xyopt!.region, mask: prev.mask, position: position,
                                                        width: current.width, height: current.height)
                            let m = XYMatch.match(prev.frame, current, region: region)
                            position.dy += Double(m.dy); position.dx += Double(m.dx); cost = m.cost
                        }
                        previous = (current, item.detection?.mask)
                        line = Masking.shiftLine(position.dy, position.dx) + "  mismatch " + (cost.isFinite ? PyFormat.fmt("%.3f", cost) : "--")
                        if !(cost <= ZDrift.weakCost) { line += "  [weak match]" }
                    } else {
                        position = (item.detection!.dy, item.detection!.dx)
                        line = Masking.shiftLine(position.dy, position.dx)
                    }
                    shifts[p].append(position)
                    // Z correction compares the frames after they are moved in xy. The box was drawn on the first
                    // timepoint before the alignment, so it moves with the xy shift of that timepoint.
                    if let z = zopt, let tr = tracker {
                        let whole = (dy: Shift.pyRound(position.dy), dx: Shift.pyRound(position.dx))
                        if t == 0, case .box(let bx, let by, let bw, let bh) = z.region {
                            zBox = ZBox(x: bx + whole.dx, y: by + whole.dy, width: bw, height: bh)
                        }
                        let d = ZDrift.describe(frame: item.frame, channel: zChannel, shift: whole,
                                                mask: z.region == .embryoMask ? item.detection?.mask : nil, box: zBox)
                        line += "   " + ZDrift.line(tr.add(d))
                    }
                    ctx.log(line)
                    var keep = true
                    if let tracker = tracker, let limit = zopt?.maximumStep, t > 0 { keep = abs(tracker.steps[t].dz) <= limit }
                    if keep { try unaligned?.append(item.gray) }
                    ctx.progress("Pass 1: shifts (embryo \(p))", t + 1, T)
                })
                try unaligned?.finish()
            } catch {
                unaligned?.cancel()
                throw error
            }
            if let u = unaligned { result.movies += u.urls }
            if let tr = tracker { trackers.append(tr) }
        }
        result.shifts = shifts

        let dys = shifts.flatMap { $0.map { $0.dy } }, dxs = shifts.flatMap { $0.map { $0.dx } }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        ctx.log("\nShift summary (pixels):")
        ctx.log(PyFormat.fmt("  dy  min=%+.1f  max=%+.1f  mean=%+.1f", dys.min() ?? 0, dys.max() ?? 0, mean(dys)))
        ctx.log(PyFormat.fmt("  dx  min=%+.1f  max=%+.1f  mean=%+.1f", dxs.min() ?? 0, dxs.max() ?? 0, mean(dxs)))
        let pad = options.enlargeCanvas ? Padding.covering(dys: dys, dxs: dxs) : Padding.none
        ctx.log("\nCanvas padding:  top=\(pad.top)  bottom=\(pad.bottom)  left=\(pad.left)  right=\(pad.right)")
        let Y = src.y + pad.top + pad.bottom, X = src.x + pad.left + pad.right
        ctx.log("  Expanded canvas: Y=\(Y)  X=\(X)")

        // Work out the z shift of every timepoint in whole slices, for each embryo. When the canvas is not
        // enlarged, slices that leave the stack are dropped.
        let plans = trackers.map { $0.plan(pad: options.enlargeCanvas) }
        for (p, plan) in plans.enumerated() {
            ctx.log("\nZ correction, embryo \(p):")
            for line in ZReport.summary(steps: trackers[p].steps, plan: plan, z: src.z) { ctx.log(line) }
        }
        result.zSteps = trackers.map { $0.steps }
        result.zPlans = plans

        ctx.log("\n--- Pass 2: aligning \(P) embryo(s) × \(T) timepoints ---")
        for p in 0..<P {
            ctx.log("\n  Embryo \(p)/\(P - 1)")
            let url = tiffURL(input, p: p)
            ctx.log("    Saving \(url.lastPathComponent)\(options.lowMemory ? " (streaming)" : "") ...")
            let plan = plans.isEmpty ? nil : plans[p]
            var meta = src.metadata(position: p)
            if let pl = plan { meta = ZReport.correctedStage(meta, plan: pl) }
            let kept = plan?.kept ?? Array(0..<T)
            let writer = try OMETIFFWriter(url: url, t: kept.count, c: src.c, z: src.z + (plan?.padLow ?? 0) + (plan?.padHigh ?? 0),
                                           y: Y, x: X, type: .uint16, metadata: meta, bigTIFF: options.lowMemory ? true : nil)
            let aligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: true),
                                  width: X, height: Y, fps: options.fps)
            }
            do {
                try orderedPipeline(count: kept.count, width: width, context: ctx, produce: { index -> (Volume, [[UInt8]]) in
                    let t = kept[index]
                    let frame = try cache.take(p * T + t) ?? src.readFrame(t: t, p: p)
                    let s = shifts[p][t]
                    var out = try self.backend.shift(frame, pad: pad, dy: s.dy, dx: s.dx, mode: self.options.shiftMode)
                    var gray: [[UInt8]] = []
                    if aligned != nil { gray = ChannelMovies.grayFrames(try self.backend.maxProjectAll(out)) }
                    // Move whole slices and leave the gaps empty. The movie frames are made before this step
                    // because a maximum projection along z does not change.
                    if let pl = plan { out = ZDrift.place(out, shift: pl.shift[t], padLow: pl.padLow, padHigh: pl.padHigh) }
                    return (out, gray)
                }, consume: { t, value in
                    try writer.writeVolume(value.0)
                    try aligned?.append(value.1)
                    ctx.progress("Pass 2: aligning (embryo \(p))", t + 1, kept.count)
                })
                try writer.finish()
                try aligned?.finish()
            } catch {
                aligned?.cancel()
                throw error
            }
            ctx.log("    Saved \(url.lastPathComponent)")
            result.tiffs.append(url)
            if let pl = plan {
                let csv = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".ome.tif", with: "_shifts.csv"))
                try ZReport.csv(steps: trackers[p].steps, plan: pl, stageZ: src.metadata(position: p).stageZ)
                    .write(to: csv, atomically: true, encoding: .utf8)
                ctx.log("    Saved \(csv.lastPathComponent)")
            }
            if let a = aligned {
                result.movies += a.urls
                for u in a.urls { ctx.log("    Saved \(u.lastPathComponent)") }
            }
        }
        if movies != nil {
            for u in result.movies where u.lastPathComponent.hasSuffix("_unaligned.mp4") {
                ctx.log("    Saved \(u.lastPathComponent)")
            }
        }
    }

    func describe(_ r: FollowRegion) -> String {
        switch r {
        case .wholeFrame: return "the whole frame"
        case .embryoMask: return "the embryo mask"
        case .box(let x, let y, let w, let h): return "the box x \(x), y \(y), \(w) × \(h) px"
        }
    }
}
