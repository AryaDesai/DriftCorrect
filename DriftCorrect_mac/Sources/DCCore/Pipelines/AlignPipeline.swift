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
/// - Optional z correction after xy (`zCorrection`): see `ZDrift`. The output is then
///   `{stem}_xy_z.ome.tif` plus `{stem}_xy_z_shifts.csv`.
public struct AlignOptions {
    public var yaml: URL
    public var useND2 = false
    public var fps: Double = 2
    public var enlargeCanvas = true
    public var shiftMode: ShiftMode = .subpixel
    public var lowMemory = false
    /// nil = xy alignment only.
    public var zCorrection: ZCorrectionOptions?
    public init(yaml: URL) { self.yaml = yaml }
}

public struct AlignResult {
    public var outputDirectory: URL
    public var tiffs: [URL] = []
    public var movies: [URL] = []
    /// shifts[p][t] = (dy, dx)
    public var shifts: [[(dy: Double, dx: Double)]] = []
    /// Z correction, per embryo: what was measured at every timepoint and the whole-slice shifts applied.
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

    /// "_z" in output names when z correction is on, so both versions can sit side by side.
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
        // Z correction needs every shift before anything is written, so it always takes the two-pass path.
        if options.enlargeCanvas || options.zCorrection != nil {
            try twoPass(cfg, input, &result)
        } else {
            try singlePass(cfg, input, &result)
        }
        return result
    }

    // MARK: Two-pass (default)

    private func twoPass(_ cfg: ThresholdConfig, _ input: Input, _ result: inout AlignResult) throws {
        let src = input.source
        let T = src.t, P = src.positions
        let width = pipelineWidth(frameBytes: src.frameBytes)
        let cache = FrameCache(enabled: !options.lowMemory && FrameCache.fits(bytes: src.frameBytes * T * P))
        let zopt = options.zCorrection
        let zChannel = try zopt?.resolveChannel(names: src.metadata.channelNames, count: src.c,
                                                fallback: cfg.parameters.channelIndex) ?? 0
        var trackers: [ZTracker] = []
        let pixelSize = src.metadata.physicalSizeX
        if zopt != nil {
            let names = src.metadata.channelNames
            ctx.log("  Z correction: channel \(zChannel < names.count ? names[zChannel] : "ch\(zChannel)") (index \(zChannel)), "
                    + (src.metadata(position: 0).stageZ == nil ? "no stage positions in the file" : "starting from the stage positions"))
        }

        ctx.log("\n--- Pass 1: precomputing shifts ---")
        var shifts = [[(dy: Double, dx: Double)]](repeating: [], count: P)
        for p in 0..<P {
            ctx.log("\n  Embryo \(p)/\(P - 1):")
            let tracker = zopt.map { ZTracker(options: $0, metadata: src.metadata(position: p)) }
            var zBox: ZBox?
            if let z = zopt, case .box(let bx, let by, let bw, let bh) = z.region, T > 0 {
                // The box was drawn on the reference timepoint before alignment: move it with that timepoint's xy shift.
                let rt = min(max(0, z.referenceTimepoint), T - 1)
                let r = try Detection.computeShift(frame: try src.readFrame(t: rt, p: p), params: try cfg.params(forTimepoint: rt),
                                                   backend: backend)
                zBox = ZBox(x: bx + Shift.pyRound(r.dx), y: by + Shift.pyRound(r.dy), width: bw, height: bh)
            }
            let unaligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: false),
                                  width: src.x, height: src.y, fps: options.fps)
            }
            do {
                try orderedPipeline(count: T, width: width, context: ctx, produce: { t -> (Detection.Result, [[UInt8]], ZDescriptor?) in
                    let frame = try src.readFrame(t: t, p: p)
                    let params = try cfg.params(forTimepoint: t)
                    let r = try Detection.computeShift(frame: frame, params: params, backend: self.backend)
                    var gray: [[UInt8]] = []
                    if unaligned != nil { gray = ChannelMovies.grayFrames(try self.backend.maxProjectAll(frame)) }
                    // What z correction needs of this timepoint, measured on the xy-centred frame.
                    var descriptor: ZDescriptor?
                    if let z = zopt {
                        descriptor = ZDrift.describe(frame: frame, channel: zChannel, shift: (Shift.pyRound(r.dy), Shift.pyRound(r.dx)),
                                                     mask: z.region == .embryoMask ? r.mask : nil, box: zBox,
                                                     pixelSizeUm: pixelSize, detectNuclei: z.useNuclei)
                    }
                    cache.put(p * T + t, frame)
                    return (r, gray, descriptor)
                }, consume: { t, value in
                    var line = Masking.shiftLine(value.0.dy, value.0.dx)
                    if let d = value.2, let tr = tracker { line += "   " + ZDrift.line(tr.add(d)) }
                    ctx.log(line)
                    shifts[p].append((value.0.dy, value.0.dx))
                    try unaligned?.append(value.1)
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

        // Whole-slice z shifts per embryo. Without canvas enlargement, slices that leave the stack are dropped.
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
            let writer = try OMETIFFWriter(url: url, t: T, c: src.c, z: src.z + (plan?.padLow ?? 0) + (plan?.padHigh ?? 0),
                                           y: Y, x: X, type: .uint16, metadata: meta, bigTIFF: options.lowMemory ? true : nil)
            let aligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: true),
                                  width: X, height: Y, fps: options.fps)
            }
            do {
                try orderedPipeline(count: T, width: width, context: ctx, produce: { t -> (Volume, [[UInt8]]) in
                    let frame = try cache.take(p * T + t) ?? src.readFrame(t: t, p: p)
                    let s = shifts[p][t]
                    var out = try self.backend.shift(frame, pad: pad, dy: s.dy, dx: s.dx, mode: self.options.shiftMode)
                    var gray: [[UInt8]] = []
                    if aligned != nil { gray = ChannelMovies.grayFrames(try self.backend.maxProjectAll(out)) }
                    // Move whole slices; the gaps stay empty. (The movies are max projections, which this does not change.)
                    if let pl = plan { out = ZDrift.place(out, shift: pl.shift[t], padLow: pl.padLow, padHigh: pl.padHigh) }
                    return (out, gray)
                }, consume: { t, value in
                    try writer.writeVolume(value.0)
                    try aligned?.append(value.1)
                    ctx.progress("Pass 2: aligning (embryo \(p))", t + 1, T)
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

    // MARK: Single pass (--no_enlarge_canvas)

    private func singlePass(_ cfg: ThresholdConfig, _ input: Input, _ result: inout AlignResult) throws {
        let src = input.source
        let T = src.t, P = src.positions
        let width = pipelineWidth(frameBytes: src.frameBytes)
        ctx.log("\nAligning \(P) embryo(s) × \(T) timepoints ...")
        var shifts = [[(dy: Double, dx: Double)]](repeating: [], count: P)
        for p in 0..<P {
            ctx.log("\n  Embryo \(p)/\(P - 1)")
            let url = tiffURL(input, p: p)
            ctx.log("    Saving \(url.lastPathComponent)\(options.lowMemory ? " (streaming)" : "") ...")
            let writer = try OMETIFFWriter(url: url, t: T, c: src.c, z: src.z, y: src.y, x: src.x, type: .uint16,
                                           metadata: src.metadata(position: p), bigTIFF: options.lowMemory ? true : nil)
            let aligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: true),
                                  width: src.x, height: src.y, fps: options.fps)
            }
            let unaligned = try movies.map {
                try ChannelMovies(factory: $0, urls: movieURLs(input, p: p, aligned: false),
                                  width: src.x, height: src.y, fps: options.fps)
            }
            struct Item { var r: Detection.Result; var out: Volume; var a: [[UInt8]]; var u: [[UInt8]] }
            do {
                try orderedPipeline(count: T, width: width, context: ctx, produce: { t -> Item in
                    let frame = try src.readFrame(t: t, p: p)
                    let params = try cfg.params(forTimepoint: t)
                    let r = try Detection.computeShift(frame: frame, params: params, backend: self.backend)
                    let out = try self.backend.shift(frame, pad: .none, dy: r.dy, dx: r.dx, mode: self.options.shiftMode)
                    var a: [[UInt8]] = [], u: [[UInt8]] = []
                    if self.movies != nil {
                        a = ChannelMovies.grayFrames(try self.backend.maxProjectAll(out))
                        u = ChannelMovies.grayFrames(try self.backend.maxProjectAll(frame))
                    }
                    return Item(r: r, out: out, a: a, u: u)
                }, consume: { t, item in
                    ctx.log(Masking.shiftLine(item.r.dy, item.r.dx))
                    shifts[p].append((item.r.dy, item.r.dx))
                    try writer.writeVolume(item.out)
                    try aligned?.append(item.a)
                    try unaligned?.append(item.u)
                    ctx.progress("Aligning timepoints (embryo \(p))", t + 1, T)
                })
                try writer.finish()
                try aligned?.finish()
                try unaligned?.finish()
            } catch {
                aligned?.cancel()
                unaligned?.cancel()
                throw error
            }
            ctx.log("    Saved \(url.lastPathComponent)")
            result.tiffs.append(url)
            for m in [aligned, unaligned].compactMap({ $0 }) {
                result.movies += m.urls
                for u in m.urls { ctx.log("    Saved \(u.lastPathComponent)") }
            }
        }
        result.shifts = shifts
    }
}
