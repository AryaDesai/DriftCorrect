import Foundation

/// The Align tool. Pass 1 finds the xy movement of every timepoint by image matching, as `XYMatch` describes, and
/// can hold the body in place with the embryo mask, as `Anchor` describes. With `zCorrection` set, it also measures
/// the z drift, as `ZDrift` describes. Pass 2 moves every timepoint and writes the output, which is
/// `{stem}_xy.ome.tif`, or `{stem}_xy_z.ome.tif` and `{stem}_xy_z_shifts.csv` with z correction. Movies are encoded
/// while the frames pass through.
public struct AlignOptions {
    /// The OME-TIFF or ND2 movie to align.
    public var source: URL
    /// The threshold YAML file from the Mask tool. It is needed when the run uses the embryo mask.
    public var yaml: URL?
    public var fps: Double = 2
    public var enlargeCanvas = true
    public var lowMemory = false
    /// Settings of the xy alignment by image matching.
    public var xyMatching = XYMatchOptions()
    /// Settings of the z correction. When nil, only the xy alignment runs.
    public var zCorrection: ZCorrectionOptions?
    public init(source: URL, yaml: URL? = nil) { self.source = source; self.yaml = yaml }
}

public struct AlignResult {
    public var outputDirectory: URL
    public var tiffs: [URL] = []
    public var movies: [URL] = []
    /// `transforms[p][i]` places a written timepoint of embryo `p` in the output, before the canvas padding. `i`
    /// counts the timepoints that are written. `shifts[p][i]` holds how far the same transform moves the frame centre.
    public var shifts: [[(dy: Double, dx: Double)]] = []
    public var transforms: [[Rigid]] = []
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
        /// The stem of the output names for a TIFF input, which is `Path.stem` without `.ome`.
        var stem: String
    }

    func openInput() throws -> Input {
        // An ND2 file can hold several embryos, and a TIFF file holds one.
        let file = options.source
        guard FileManager.default.fileExists(atPath: file.path) else { throw DCError("File not found: \(file.path)") }
        ctx.log("Loading \(file.lastPathComponent) ...")
        let isND2 = file.pathExtension.lowercased() == "nd2"
        let src: FrameSource = isND2 ? try ND2Source(url: file) : try TIFFSource(url: file)
        let base = isND2 ? PyFormat.stem(file) : PyFormat.stemWithoutOME(file)
        ctx.log("  Shape: T=\(src.t), P=\(src.positions), Z=\(src.z), C=\(src.c), Y=\(src.y), X=\(src.x)")
        return Input(source: src, base: base,
                     outDir: file.deletingLastPathComponent().appendingPathComponent("aligned_\(base)"),
                     isND2: isND2, stem: base)
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
        let cfg = try options.yaml.map { try ThresholdConfig.load($0) }
        let input = try openInput()
        let src = input.source
        let names = src.metadata.channelNames
        guard names.count >= src.c else { throw DCError("The file has \(src.c) channels but only \(names.count) names") }
        ctx.log("  Channels: \(names)")
        if let top = cfg?.parameters {
            if top.channelIndex >= 0 && top.channelIndex < names.count {
                ctx.log("  Threshold channel: \(names[top.channelIndex]) (index \(top.channelIndex))")
            }
            ctx.log("  sigma=\(PyFormat.g(top.sigma)), percentile=\(PyFormat.g(top.percentile)), method=\(top.method)")
        }
        ctx.log("  Compute: \(backend.name)")
        try FileManager.default.createDirectory(at: input.outDir, withIntermediateDirectories: true)
        ctx.log("  Output: \(input.outDir.path)")

        var result = AlignResult(outputDirectory: input.outDir)
        try twoPass(cfg, input, &result)
        return result
    }

    // MARK: Two passes

    /// Pass 1 measures the shift of every timepoint. Pass 2 applies the shifts and writes the output. The canvas
    /// size, the image matching and the z correction all need every shift before anything is written.

    private func twoPass(_ cfg: ThresholdConfig?, _ input: Input, _ result: inout AlignResult) throws {
        let src = input.source
        let T = src.t, P = src.positions
        let width = pipelineWidth(frameBytes: src.frameBytes)
        let cache = FrameCache(enabled: !options.lowMemory && FrameCache.fits(bytes: src.frameBytes * T * P))
        var trackers: [ZTracker] = []
        let zopt = options.zCorrection, xy = options.xyMatching
        if let limit = zopt?.maximumStep, !limit.isFinite || limit <= 0 {
            throw DCError("Maximum shift must be a positive number of slices")
        }
        let names = src.metadata.channelNames
        func name(_ c: Int) -> String { c < names.count ? names[c] : "ch\(c)" }
        let thresholdChannel = cfg?.parameters.channelIndex ?? 0
        let zChannel = try zopt?.resolveChannel(names: names, count: src.c, fallback: thresholdChannel) ?? 0
        let xyChannel = try resolveChannel(index: xy.channelIndex, name: xy.channelName, names: names, count: src.c,
                                           fallback: thresholdChannel, label: "XY")
        // The embryo mask is needed to hold the body in place, and for image matching or z correction that follow it.
        let needsMask = xy.holdInPlace || xy.region == .embryoMask || zopt?.region == .embryoMask
        guard !needsMask || cfg != nil else {
            throw DCError("These settings need an embryo mask, and no threshold YAML file was given.")
        }
        ctx.log("  XY: image matching of \(name(xyChannel)) (index \(xyChannel)), following \(describe(xy.region))")
        ctx.log(xy.holdInPlace ? "      The centroid of the embryo mask holds the body in place, averaged over \(PyFormat.g(xy.smoothing)) timepoints."
                               : "      The body is not held in place.")
        let midX = Double(src.x - 1) / 2, midY = Double(src.y - 1) / 2
        if let z = zopt { ctx.log("  Z correction: \(name(zChannel)) (index \(zChannel)), following \(describe(z.region))") }

        ctx.log("\n--- Pass 1: precomputing shifts ---")
        // The step that moves each kept timepoint onto the kept one before it, and the pose of the body.
        var steps = [[Rigid]](repeating: [], count: P), poses = [[BodyPose?]](repeating: [], count: P)
        struct Item {
            var frame: Volume
            var detection: Detection.Result?
            var gray: [[UInt8]]
            var xy: XYFrame
        }
        for p in 0..<P {
            ctx.log("\n  Embryo \(p)/\(P - 1):")
            let tracker = zopt.map { ZTracker(options: $0) }
            // The previous timepoint for image matching, with its mask.
            var previous: (frame: XYFrame, mask: Mask2D?)?
            // The transform that moves the current timepoint onto the first one, which is the sum of the steps.
            var toFirst = Rigid.identity
            let unaligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: false),
                                  width: src.x, height: src.y, fps: options.fps)
            }
            do {
                try orderedPipeline(count: T, width: width, context: ctx, produce: { t -> Item in
                    let frame = try src.readFrame(t: t, p: p)
                    let detection = needsMask ? try Detection.computeShift(frame: frame, params: try cfg!.params(forTimepoint: t),
                                                                           backend: self.backend) : nil
                    var gray: [[UInt8]] = []
                    let xy: XYFrame
                    if unaligned != nil {
                        let projections = try self.backend.maxProjectAll(frame)
                        gray = ChannelMovies.grayFrames(projections)
                        xy = XYMatch.prepare(projections[xyChannel])
                    } else {
                        xy = XYMatch.prepare(try self.backend.maxProjectZ(frame, channel: xyChannel))
                    }
                    cache.put(p * T + t, frame)
                    return Item(frame: frame, detection: detection, gray: gray, xy: xy)
                }, consume: { t, item in
                    // The xy movement of this timepoint. `step` moves it onto the last kept timepoint.
                    var step = Rigid.identity, cost = 0.0
                    if let prev = previous {
                        let region = XYMatch.region(xy.region, mask: prev.mask, toFirst: toFirst,
                                                    width: item.xy.width, height: item.xy.height)
                        let m = XYMatch.match(prev.frame, item.xy, region: region, maximumAngle: xy.maximumAngle)
                        step = m.step; cost = m.cost
                    }
                    let moved = step.apply(x: midX, y: midY)
                    var line = Masking.shiftLine(moved.y - midY, moved.x - midX) + PyFormat.fmt("  angle=%+6.2f", step.degrees)
                        + "  mismatch " + (cost.isFinite ? PyFormat.fmt("%.3f", cost) : "--")
                    if !(cost <= ZDrift.weakCost) { line += "  [weak match]" }
                    let onFirst = toFirst.after(step)
                    // Z correction compares each timepoint with earlier ones after moving it onto them in xy.
                    var keep = true
                    if let z = zopt, let tr = tracker {
                        let region = XYMatch.region(z.region, mask: item.detection?.mask, toFirst: onFirst, width: src.x, height: src.y)
                        let measured = tr.add(step: step) {
                            ZDrift.describe(frame: item.frame, channel: zChannel, region: region, transform: $0)
                        }
                        line += "   " + ZDrift.line(measured)
                        keep = tr.kept.last == t
                    }
                    ctx.log(keep ? line : line + "  [dropped]")
                    // A dropped timepoint is not stored, so the next timepoint is matched to the last kept one.
                    if keep {
                        toFirst = onFirst
                        previous = (item.xy, item.detection?.mask)
                        steps[p].append(step)
                        poses[p].append(xy.holdInPlace ? item.detection?.mask.flatMap { Anchor.pose(of: $0) } : nil)
                        try unaligned?.append(item.gray)
                    }
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
        // Work out where every timepoint goes in the output.
        var transforms: [[Rigid]] = []
        for p in 0..<P {
            let held = xy.holdInPlace && !poses[p].contains(where: { $0 == nil })
            if xy.holdInPlace && !held {
                ctx.log("\n  The embryo mask of embryo \(p) is empty at some timepoint, so the body is not held in place.")
            }
            transforms.append(Anchor.transforms(steps: steps[p], poses: held ? poses[p] : nil, smoothing: xy.smoothing,
                                                width: src.x, height: src.y))
        }
        let shifts = transforms.map { $0.map { m -> (dy: Double, dx: Double) in let q = m.apply(x: midX, y: midY); return (q.y - midY, q.x - midX) } }
        result.shifts = shifts
        result.transforms = transforms

        let dys = shifts.flatMap { $0.map { $0.dy } }, dxs = shifts.flatMap { $0.map { $0.dx } }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        ctx.log("\nShift summary (pixels):")
        ctx.log(PyFormat.fmt("  dy  min=%+.1f  max=%+.1f  mean=%+.1f", dys.min() ?? 0, dys.max() ?? 0, mean(dys)))
        ctx.log(PyFormat.fmt("  dx  min=%+.1f  max=%+.1f  mean=%+.1f", dxs.min() ?? 0, dxs.max() ?? 0, mean(dxs)))
        let angles = transforms.flatMap { $0.map { $0.degrees } }
        ctx.log(PyFormat.fmt("  angle  min=%+.1f  max=%+.1f degrees", angles.min() ?? 0, angles.max() ?? 0))
        let pad = options.enlargeCanvas ? Padding.covering(transforms: transforms.flatMap { $0 }, width: src.x, height: src.y) : .none
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
                    // The transforms hold the kept timepoints only.
                    var out = try self.backend.warp(frame, pad: pad, transform: transforms[p][index])
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
