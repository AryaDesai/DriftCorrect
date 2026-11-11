import Foundation

/// Settings of the z correction.
public struct ZCorrectionOptions: Sendable {
    /// The channel to follow, given by index or by name. When both are nil, the threshold channel of the YAML file
    /// is used. A nuclear marker is the best choice because its pattern stays the same while a reporter that
    /// oscillates changes from one timepoint to the next.
    public var channelIndex: Int?
    public var channelName: String?
    public var region: ZRegion = .embryoMask
    /// The timepoint whose slices stay where they are. Every other timepoint moves to match it.
    /// The app and the command line do not show this setting yet, so change it here.
    public var referenceTimepoint = 0
    /// The dead band of the rounding to whole slices, which `ZDrift.plan` describes.
    public var deadBand = 0.15
    /// Start from the stage z positions that the microscope recorded, when the file has them.
    public var useStagePositions = true
    /// Refine the estimate from the images by matching individual nuclei.
    public var useNuclei = true

    public init() {}

    /// Return the index of the channel to follow. `fallback` is used when no channel was chosen.
    func resolveChannel(names: [String], count: Int, fallback: Int) throws -> Int {
        if let i = channelIndex {
            guard i >= 0 && i < count else { throw DCError("Z channel index \(i) is out of range (the data has \(count) channel(s))") }
            return i
        }
        if let n = channelName, !n.isEmpty {
            guard let i = names.prefix(count).firstIndex(of: n) else {
                throw DCError("Z channel \"\(n)\" not found. The channels are: \(names.prefix(count).joined(separator: ", "))")
            }
            return i
        }
        return fallback
    }
}

/// Follows one embryo through time. The descriptor of each timepoint is added in the order of time.
final class ZTracker {
    let options: ZCorrectionOptions
    let stageZ: [Double]?
    let stageStep: Double?
    private var previous: ZDescriptor?
    private(set) var steps: [ZStep] = []

    init(options: ZCorrectionOptions, metadata: ImageMetadata) {
        self.options = options
        let usable = options.useStagePositions && (metadata.stageZStep ?? 0) != 0
        stageZ = usable ? metadata.stageZ : nil
        stageStep = usable ? metadata.stageZStep : nil
    }

    /// Return the number of slices the tissue appears to move between timepoint t - 1 and timepoint t when only the
    /// stage moved. When the stack starts higher by some distance, the same tissue sits lower in the stack by that
    /// distance divided by the z step.
    func stageEstimate(_ t: Int) -> Double? {
        guard let z = stageZ, let step = stageStep, t > 0, t < z.count else { return nil }
        return -(z[t] - z[t - 1]) / step + 0   // Adding 0 turns a negative zero into zero for the log.
    }

    /// Compare the timepoint with the previous one and store the result.
    @discardableResult
    func add(_ d: ZDescriptor) -> ZStep {
        let t = steps.count
        var step = ZStep()
        if let p = previous { step = ZDrift.match(p, d, stage: stageEstimate(t), useNuclei: options.useNuclei) }
        steps.append(step)
        previous = d
        return step
    }

    /// Return the shift of every timepoint in whole slices.
    func plan(pad: Bool) -> ZPlan {
        ZDrift.plan(steps: steps.map { $0.dz }, reference: options.referenceTimepoint, deadBand: options.deadBand, pad: pad)
    }
}

public enum ZReport {
    /// Build the table with one row for each timepoint. A row holds what was measured and the shift that was applied.
    public static func csv(steps: [ZStep], plan: ZPlan, stageZ: [Double]?) -> String {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var out = "t,stage_z_um,dz_used,dz_stage,dz_image,dz_nuclei,image_mismatch,nuclei_agreeing,nuclei_share,position_slices,shift_slices,flag\n"
        for (t, s) in steps.enumerated() {
            let stage = stageZ.flatMap { t < $0.count ? $0[t] : nil }
            out += "\(t),\(f(stage, 2)),\(f(s.dz)),\(f(s.stage)),\(f(s.image)),\(f(s.nuclei)),\(f(s.cost.isFinite ? s.cost : nil)),"
            out += "\(s.agreeing),\(f(s.share)),\(f(plan.position[t])),\(plan.shift[t]),\(s.flag)\n"
        }
        return out
    }

    /// Build the lines that the log shows after all timepoints are measured.
    public static func summary(steps: [ZStep], plan: ZPlan, z: Int) -> [String] {
        let flagged = steps.enumerated().filter { !$0.element.flag.isEmpty }
        var lines = [PyFormat.fmt("  z position  min=%+.1f  max=%+.1f slices", plan.position.min() ?? 0, plan.position.max() ?? 0),
                     "  Empty slices added:  low=\(plan.padLow)  high=\(plan.padHigh)   Z: \(z) -> \(z + plan.padLow + plan.padHigh)"]
        if !flagged.isEmpty {
            lines.append("  \(flagged.count) timepoint(s) need a look: " + flagged.prefix(12).map { "t\($0.offset) (\($0.element.flag))" }.joined(separator: ", ")
                         + (flagged.count > 12 ? ", …" : ""))
        }
        return lines
    }

    /// Return the metadata with the stage positions of the corrected stack. The first slice of each timepoint moved
    /// by the shift of that timepoint.
    public static func correctedStage(_ m: ImageMetadata, plan: ZPlan) -> ImageMetadata {
        var out = m
        if let z = m.stageZ, let step = m.stageZStep, z.count == plan.shift.count {
            out.stageZ = zip(z, plan.shift).map { $0 - Double($1 + plan.padLow) * step }
        }
        return out
    }
}

/// The measurement pass that the two z tools without xy alignment share.
enum ZPass {
    /// Measure every timepoint of one position in the order of time and return the tracker that holds the result.
    /// The frames are not moved in xy. The embryo mask needs the threshold settings and a compute backend.
    static func measure(source src: FrameSource, position p: Int, options: ZCorrectionOptions, channel: Int,
                        thresholds: ThresholdConfig?, backend: ComputeBackend?, cache: FrameCache?,
                        context ctx: RunContext) throws -> ZTracker {
        let meta = src.metadata(position: p)
        var box: ZBox?
        if case .box(let x, let y, let w, let h) = options.region { box = ZBox(x: x, y: y, width: w, height: h) }
        if options.region == .embryoMask && (thresholds == nil || backend == nil) {
            throw DCError("Following the embryo mask needs a threshold YAML file. Give one, or follow the whole frame or a box.")
        }
        let tracker = ZTracker(options: options, metadata: meta)
        let T = src.t
        try orderedPipeline(count: T, width: pipelineWidth(frameBytes: src.frameBytes * 2), context: ctx, produce: { t -> ZDescriptor in
            let frame = try src.readFrame(t: t, p: p)
            // The mask comes from the same detection that the xy alignment uses. Its shift is not applied here.
            var mask: Mask2D?
            if options.region == .embryoMask, let cfg = thresholds, let b = backend {
                mask = try Detection.computeShift(frame: frame, params: try cfg.params(forTimepoint: t), backend: b).mask
            }
            let d = ZDrift.describe(frame: frame, channel: channel, mask: mask, box: box, pixelSizeUm: meta.physicalSizeX,
                                    detectNuclei: options.useNuclei)
            cache?.put(p * T + t, frame)
            return d
        }, consume: { t, d in
            let s = tracker.add(d)
            ctx.log(String(format: "  t%-4d ", t) + ZDrift.line(s))
            ctx.progress("Measuring z drift", t + 1, T)
        })
        return tracker
    }

    static func open(_ url: URL) throws -> FrameSource {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DCError("File not found: \(url.path)") }
        return url.pathExtension.lowercased() == "nd2" ? try ND2Source(url: url) : try TIFFSource(url: url)
    }

    static func describeRun(_ src: FrameSource, _ meta: ImageMetadata, channel: Int) -> String {
        let name = channel < meta.channelNames.count ? meta.channelNames[channel] : "ch\(channel)"
        return "Z drift of \(name) (index \(channel)), T=\(src.t), Z=\(src.z), "
            + (meta.stageZ == nil ? "no stage positions in the file" : "starting from the stage positions")
    }
}

/// Measure the z drift of a file and save the table without writing a corrected stack (`dc z-shifts`).
/// The frames are not aligned in xy first.
public enum ZMeasure {
    public struct Result {
        public var steps: [ZStep]
        public var plan: ZPlan
        public var csv: URL?
    }

    public static func run(source src: FrameSource, position p: Int = 0, options: ZCorrectionOptions,
                           thresholds: ThresholdConfig? = nil, backend: ComputeBackend? = nil,
                           csv: URL?, context ctx: RunContext) throws -> Result {
        guard p >= 0 && p < src.positions else { throw DCError("Position \(p) is out of range (the file has \(src.positions))") }
        let meta = src.metadata(position: p)
        let channel = try options.resolveChannel(names: meta.channelNames, count: src.c,
                                                 fallback: thresholds?.parameters.channelIndex ?? 0)
        ctx.log(ZPass.describeRun(src, meta, channel: channel))
        let tracker = try ZPass.measure(source: src, position: p, options: options, channel: channel, thresholds: thresholds,
                                        backend: backend, cache: nil, context: ctx)
        let plan = tracker.plan(pad: true)
        for line in ZReport.summary(steps: tracker.steps, plan: plan, z: src.z) { ctx.log(line) }
        if let url = csv {
            try ZReport.csv(steps: tracker.steps, plan: plan, stageZ: meta.stageZ).write(to: url, atomically: true, encoding: .utf8)
            ctx.log("Saved \(url.lastPathComponent)")
        }
        return Result(steps: tracker.steps, plan: plan, csv: csv)
    }
}

/// Settings of a z correction that runs on its own, without the xy alignment.
public struct ZCorrectOptions {
    /// The OME-TIFF or ND2 file to correct. It can be a file that the Align tool already aligned in xy.
    public var input: URL
    /// The embryo position, for an ND2 file with several positions.
    public var position = 0
    public var z = ZCorrectionOptions()
    /// The threshold YAML file. It is needed only when the region is the embryo mask.
    public var yaml: URL?
    /// Add empty slices so that no slice is lost. Without it the stack keeps its depth.
    public var enlargeStack = true
    /// Read the frames again for writing, and do not keep them in memory after the measurement.
    public var lowMemory = false
    public init(input: URL) { self.input = input }
}

/// Z correction of one file without the xy alignment (`dc correct-z` and the "Correct z drift" window).
/// The first pass measures every timepoint and the second pass writes `{name}_z.ome.tif` next to the input,
/// together with `{name}_z_shifts.csv`. The pixel values and the sample type do not change.
public enum ZCorrectPipeline {
    public struct Result {
        public var tiff: URL
        public var csv: URL
        public var steps: [ZStep]
        public var plan: ZPlan
    }

    public static func run(options: ZCorrectOptions, backend: ComputeBackend, context ctx: RunContext) throws -> Result {
        let src = try ZPass.open(options.input)
        let p = options.position
        guard p >= 0 && p < src.positions else { throw DCError("Position \(p) is out of range (the file has \(src.positions))") }
        let cfg = try options.yaml.map { try ThresholdConfig.load($0) }
        let meta = src.metadata(position: p)
        let channel = try options.z.resolveChannel(names: meta.channelNames, count: src.c,
                                                   fallback: cfg?.parameters.channelIndex ?? 0)
        ctx.log("Loading \(options.input.lastPathComponent) ...")
        ctx.log("  Shape: T=\(src.t), C=\(src.c), Z=\(src.z), Y=\(src.y), X=\(src.x)")
        ctx.log("  " + ZPass.describeRun(src, meta, channel: channel))

        // Pass 1 measures the movement at every timepoint. The frames stay in memory for pass 2 when they fit.
        ctx.log("\n--- Pass 1: measuring z drift ---")
        let T = src.t
        let cache = FrameCache(enabled: !options.lowMemory && FrameCache.fits(bytes: src.frameBytes * T))
        let tracker = try ZPass.measure(source: src, position: p, options: options.z, channel: channel, thresholds: cfg,
                                        backend: backend, cache: cache, context: ctx)
        let plan = tracker.plan(pad: options.enlargeStack)
        for line in ZReport.summary(steps: tracker.steps, plan: plan, z: src.z) { ctx.log(line) }

        // Pass 2 moves the slices of every timepoint and writes the corrected stack.
        let stem = PyFormat.stemWithoutOME(options.input) + (src.positions > 1 ? "_P\(p)" : "")
        let dir = options.input.deletingLastPathComponent()
        let out = dir.appendingPathComponent("\(stem)_z.ome.tif")
        let csv = dir.appendingPathComponent("\(stem)_z_shifts.csv")
        ctx.log("\n--- Pass 2: moving slices ---")
        ctx.log("  Saving \(out.lastPathComponent) ...")
        let writer = try OMETIFFWriter(url: out, t: T, c: src.c, z: src.z + plan.padLow + plan.padHigh, y: src.y, x: src.x,
                                       type: src.sampleType, metadata: ZReport.correctedStage(meta, plan: plan),
                                       bigTIFF: options.lowMemory ? true : nil)
        try orderedPipeline(count: T, width: pipelineWidth(frameBytes: src.frameBytes * 2), context: ctx, produce: { t -> Volume in
            let frame = try cache.take(p * T + t) ?? src.readFrame(t: t, p: p)
            return ZDrift.place(frame, shift: plan.shift[t], padLow: plan.padLow, padHigh: plan.padHigh)
        }, consume: { t, v in
            try writer.writeVolume(v)
            ctx.progress("Pass 2: moving slices", t + 1, T)
        })
        try writer.finish()
        try ZReport.csv(steps: tracker.steps, plan: plan, stageZ: meta.stageZ).write(to: csv, atomically: true, encoding: .utf8)
        ctx.log("  Saved \(out.lastPathComponent)")
        ctx.log("  Saved \(csv.lastPathComponent)")
        return Result(tiff: out, csv: csv, steps: tracker.steps, plan: plan)
    }
}
