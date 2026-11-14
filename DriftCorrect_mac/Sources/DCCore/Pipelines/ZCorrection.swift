import Foundation

/// Settings of the z correction.
public struct ZCorrectionOptions: Sendable {
    /// The channel to follow, given by index or by name. When both are nil, the threshold channel of the YAML file
    /// is used. A nuclear marker is the best choice because its pattern stays the same while a reporter that
    /// oscillates changes from one timepoint to the next.
    public var channelIndex: Int?
    public var channelName: String?
    public var region: FollowRegion = .wholeFrame
    /// The dead band of the rounding to whole slices, which `ZDrift.plan` describes.
    public var deadBand = 0.15
    /// Leave out timepoints whose movement from the last kept timepoint exceeds this many slices.
    public var maximumStep: Double?
    /// Each timepoint is also compared with the one this many timepoints earlier. A slow movement is too small to
    /// measure between neighbours, and the comparison further back catches it. With 1 only neighbours are compared.
    public var span = 5

    public init() {}

    func resolveChannel(names: [String], count: Int, fallback: Int) throws -> Int {
        try DCCore.resolveChannel(index: channelIndex, name: channelName, names: names, count: count, fallback: fallback, label: "Z")
    }
}

/// Follows one embryo through time. The descriptor of each timepoint is added in the order of time.
final class ZTracker {
    let options: ZCorrectionOptions
    /// This holds the last few kept timepoints. Each has the xy step that moves it onto the kept timepoint before it,
    /// and whether its match was good.
    private var recent: [(descriptor: ZDescriptor, step: Rigid, good: Bool)] = []
    /// When the timepoint before this one was dropped, this holds it with the xy step that moves it onto the last
    /// kept timepoint. It shows whether a large move stayed.
    private var dropped: (descriptor: ZDescriptor, step: Rigid)?
    /// This holds the measurement of every timepoint, kept or dropped, for the log and the table.
    private(set) var steps: [ZStep] = []
    /// These timepoints are written. The others moved further than `maximumStep` and are dropped.
    private(set) var kept: [Int] = []
    /// Each edge compares two kept timepoints. `i` and `j` count the kept timepoints only, because the positions are
    /// solved for the kept timepoints alone.
    private var edges: [(i: Int, j: Int, d: Double)] = []

    init(options: ZCorrectionOptions) { self.options = options }

    /// Compare the timepoint with the last kept one and store the result. `step` is the xy transform that moves
    /// this timepoint onto the last kept one. `describe` returns the descriptor of this timepoint after it is moved
    /// in xy by the transform it is given. The timepoint is also compared with the kept one `span` places earlier,
    /// where a slow movement is large enough to measure. A dropped timepoint takes no part in later comparisons,
    /// so the timepoints after it are measured as if it was never recorded.
    @discardableResult
    func add(step: Rigid = .identity, describe: (Rigid) -> ZDescriptor) -> ZStep {
        let t = steps.count
        let s = recent.last.map { ZDrift.match($0.descriptor, describe(step)) } ?? ZStep()
        steps.append(s)
        if let limit = options.maximumStep, t > 0, abs(s.dz) > limit {
            // The timepoint is far from the last kept one. It is dropped unless the timepoint before it was dropped
            // at the same place, which means that the tissue moved there and stayed.
            let stayed = dropped.map { abs(ZDrift.match($0.descriptor, describe($0.step.inverse.after(step))).dz) <= limit } ?? false
            if !stayed {
                dropped = (describe(.identity), step)
                return s
            }
        }
        dropped = nil
        let n = kept.count
        kept.append(t)
        if n > 0 { edges.append((n - 1, n, s.dz)) }
        let span = options.span
        if span > 1 && recent.count >= span {
            // Join the xy steps of the timepoints in between, so that this timepoint lands on the earlier one.
            var joined = step
            for k in stride(from: recent.count - 1, through: recent.count - span + 1, by: -1) { joined = recent[k].step.after(joined) }
            let far = ZDrift.match(recent[recent.count - span].descriptor, describe(joined))
            // Use the comparison only when it and every step it spans matched well.
            if far.flag.isEmpty && s.flag.isEmpty && recent.suffix(span - 1).allSatisfy({ $0.good }) { edges.append((n - span, n, far.dz)) }
        }
        // Keep this timepoint in its own frame, where later timepoints are moved onto it.
        recent.append((describe(.identity), step, s.flag.isEmpty))
        if recent.count > max(1, span) { recent.removeFirst() }
        return s
    }

    /// Return the shift of every timepoint in whole slices. The shifts are worked out from the kept timepoints.
    func plan(pad: Bool) -> ZPlan {
        let part = ZDrift.plan(steps: kept.map { steps[$0].dz }, positions: ZDrift.positions(count: kept.count, edges: edges),
                               deadBand: options.deadBand, pad: pad)
        // A dropped timepoint is listed in the table with its position measured from the last kept timepoint.
        var position = [Double](repeating: 0, count: steps.count), shift = [Int](repeating: 0, count: steps.count)
        var k = -1
        for t in steps.indices {
            let isKept = k + 1 < kept.count && kept[k + 1] == t
            if isKept { k += 1 }
            position[t] = part.position[k] + (isKept ? 0 : steps[t].dz)
            shift[t] = part.shift[k]
        }
        return ZPlan(position: position, shift: shift, padLow: part.padLow, padHigh: part.padHigh, kept: kept)
    }
}

public enum ZReport {
    /// Build the table with one row for each timepoint. A row holds what was measured and the shift that was applied.
    public static func csv(steps: [ZStep], plan: ZPlan, stageZ: [Double]?) -> String {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var out = "t,output_t,stage_z_um,dz,mismatch,position_slices,shift_slices,flag\n"
        let outputIndices = Dictionary(uniqueKeysWithValues: plan.kept.enumerated().map { ($0.element, $0.offset) })
        for (t, s) in steps.enumerated() {
            let stage = stageZ.flatMap { t < $0.count ? $0[t] : nil }
            let flag = [s.flag, outputIndices[t] == nil ? "dropped (large shift)" : ""].filter { !$0.isEmpty }.joined(separator: "; ")
            out += "\(t),\(outputIndices[t].map(String.init) ?? ""),\(f(stage, 2)),\(f(s.dz)),\(f(s.cost.isFinite ? s.cost : nil)),"
            out += "\(f(plan.position[t])),\(plan.shift[t]),\(flag)\n"
        }
        return out
    }

    /// Build the lines that the log shows after all timepoints are measured.
    public static func summary(steps: [ZStep], plan: ZPlan, z: Int) -> [String] {
        let flagged = steps.enumerated().filter { !$0.element.flag.isEmpty }
        let retainedPositions = plan.kept.map { plan.position[$0] }
        var lines = [PyFormat.fmt("  z position  min=%+.1f  max=%+.1f slices", retainedPositions.min() ?? 0, retainedPositions.max() ?? 0),
                     "  Empty slices added:  low=\(plan.padLow)  high=\(plan.padHigh)   Z: \(z) -> \(z + plan.padLow + plan.padHigh)"]
        if !flagged.isEmpty {
            lines.append("  \(flagged.count) timepoint(s) need a look: " + flagged.prefix(12).map { "t\($0.offset) (\($0.element.flag))" }.joined(separator: ", ")
                         + (flagged.count > 12 ? ", …" : ""))
        }
        let retainedShifts = plan.kept.map { plan.shift[$0] }
        let retained = Set(plan.kept)
        let dropped = steps.indices.filter { !retained.contains($0) }
        if !dropped.isEmpty { lines.append("Dropped timepoints (0-based): " + dropped.map(String.init).joined(separator: ", ")) }
        let firstSlice = max(0, plan.padLow + (retainedShifts.max() ?? 0))
        let endSlice = min(z + plan.padLow + plan.padHigh, z + plan.padLow + (retainedShifts.min() ?? 0))
        lines.append("Embryo visible in slices:")
        if !retainedShifts.isEmpty && firstSlice < endSlice {
            lines.append(contentsOf: (firstSlice..<endSlice).map { "\($0 + 1)" + ($0 < endSlice - 1 ? "," : "") })
        } else {
            lines.append("None")
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
        if let stage = out.stageZ, stage.count == plan.shift.count { out.stageZ = plan.kept.map { stage[$0] } }
        if plan.kept.count != plan.shift.count, let period = m.timeIncrement {
            out.timeOffsets = plan.kept.map { Double($0) * period }
        }
        return out
    }
}

/// The measurement pass of the z correction without xy alignment.
enum ZPass {
    /// Measure every timepoint of one position in the order of time and return the tracker that holds the result.
    /// The frames are not moved in xy. The embryo mask needs the threshold settings and a compute backend.
    static func measure(source src: FrameSource, position p: Int, options: ZCorrectionOptions, channel: Int,
                        thresholds: ThresholdConfig?, backend: ComputeBackend?, cache: FrameCache?,
                        context ctx: RunContext) throws -> ZTracker {
        if let limit = options.maximumStep, !limit.isFinite || limit <= 0 {
            throw DCError("Maximum shift must be a positive number of slices")
        }
        let meta = src.metadata(position: p)
        if options.region == .embryoMask && (thresholds == nil || backend == nil) {
            throw DCError("Following the embryo mask needs a threshold YAML file. Give one, or follow the whole frame or a box.")
        }
        let tracker = ZTracker(options: options)
        let T = src.t
        try orderedPipeline(count: T, width: pipelineWidth(frameBytes: src.frameBytes * 2), context: ctx, produce: { t -> ZDescriptor in
            let frame = try src.readFrame(t: t, p: p)
            // The mask comes from the same detection that the xy alignment uses. Its shift is not applied here.
            var mask: Mask2D?
            if options.region == .embryoMask, let cfg = thresholds, let b = backend {
                mask = try Detection.computeShift(frame: frame, params: try cfg.params(forTimepoint: t), backend: b).mask
            }
            let region = XYMatch.region(options.region, mask: mask, toFirst: .identity, width: frame.x, height: frame.y)
            let d = ZDrift.describe(frame: frame, channel: channel, region: region)
            cache?.put(p * T + t, frame)
            return d
        }, consume: { t, d in
            let s = tracker.add { _ in d }
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
        return "Z drift of \(name) (index \(channel)), T=\(src.t), Z=\(src.z)"
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
        let writer = try OMETIFFWriter(url: out, t: plan.kept.count, c: src.c, z: src.z + plan.padLow + plan.padHigh, y: src.y, x: src.x,
                                       type: src.sampleType, metadata: ZReport.correctedStage(meta, plan: plan),
                                       bigTIFF: options.lowMemory ? true : nil)
        try orderedPipeline(count: plan.kept.count, width: pipelineWidth(frameBytes: src.frameBytes * 2), context: ctx, produce: { index -> Volume in
            let t = plan.kept[index]
            let frame = try cache.take(p * T + t) ?? src.readFrame(t: t, p: p)
            return ZDrift.place(frame, shift: plan.shift[t], padLow: plan.padLow, padHigh: plan.padHigh)
        }, consume: { t, v in
            try writer.writeVolume(v)
            ctx.progress("Pass 2: moving slices", t + 1, plan.kept.count)
        })
        try writer.finish()
        try ZReport.csv(steps: tracker.steps, plan: plan, stageZ: meta.stageZ).write(to: csv, atomically: true, encoding: .utf8)
        ctx.log("  Saved \(out.lastPathComponent)")
        ctx.log("  Saved \(csv.lastPathComponent)")
        return Result(tiff: out, csv: csv, steps: tracker.steps, plan: plan)
    }
}
