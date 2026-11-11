import Foundation

/// Settings of the z correction that runs after xy alignment.
public struct ZCorrectionOptions: Sendable {
    /// Channel to follow, by index or by name. With neither, the threshold channel of the YAML is used.
    /// A nuclear marker works best: its pattern does not change with the oscillating reporter.
    public var channelIndex: Int?
    public var channelName: String?
    public var region: ZRegion = .embryoMask
    /// The timepoint whose slices keep their meaning; every other timepoint moves to match it.
    /// Change it here in code; the app and the command line do not expose it yet.
    public var referenceTimepoint = 0
    /// See `ZDrift.plan`.
    public var deadBand = 0.15
    /// Start from the stage z recorded by the microscope, when the file has it.
    public var useStagePositions = true
    /// Refine the image estimate by matching individual nuclei.
    public var useNuclei = true

    public init() {}

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

/// Follows one embryo through time: add the descriptor of each timepoint in order.
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

    /// Slices the tissue should have moved between t-1 and t if only the stage moved.
    /// The stack starts `delta` um higher, so the same tissue sits `delta / step` slices lower in it.
    func stageEstimate(_ t: Int) -> Double? {
        guard let z = stageZ, let step = stageStep, t > 0, t < z.count else { return nil }
        return -(z[t] - z[t - 1]) / step + 0   // + 0 turns -0.0 into 0.0
    }

    @discardableResult
    func add(_ d: ZDescriptor) -> ZStep {
        let t = steps.count
        var step = ZStep()
        if let p = previous { step = ZDrift.match(p, d, stage: stageEstimate(t), useNuclei: options.useNuclei) }
        steps.append(step)
        previous = d
        return step
    }

    func plan(pad: Bool) -> ZPlan {
        ZDrift.plan(steps: steps.map { $0.dz }, reference: options.referenceTimepoint, deadBand: options.deadBand, pad: pad)
    }
}

public enum ZReport {
    /// One row per timepoint: what was measured and what was applied.
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

    /// Lines for the log after all timepoints are measured.
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

    /// Stage positions of the corrected stack: each timepoint's first slice moved with its shift.
    public static func correctedStage(_ m: ImageMetadata, plan: ZPlan) -> ImageMetadata {
        var out = m
        if let z = m.stageZ, let step = m.stageZStep, z.count == plan.shift.count {
            out.stageZ = zip(z, plan.shift).map { $0 - Double($1 + plan.padLow) * step }
        }
        return out
    }
}

/// Measure z drift without writing a corrected stack (`dc z-shifts`). No xy alignment is applied,
/// so this suits files that are already aligned in xy, and checks of the method.
public enum ZMeasure {
    public struct Result {
        public var steps: [ZStep]
        public var plan: ZPlan
        public var csv: URL?
    }

    public static func run(source src: FrameSource, position p: Int = 0, options: ZCorrectionOptions,
                           csv: URL?, context ctx: RunContext) throws -> Result {
        guard p >= 0 && p < src.positions else { throw DCError("Position \(p) is out of range (the file has \(src.positions))") }
        let meta = src.metadata(position: p)
        let channel = try options.resolveChannel(names: meta.channelNames, count: src.c, fallback: 0)
        var box: ZBox?
        if case .box(let x, let y, let w, let h) = options.region { box = ZBox(x: x, y: y, width: w, height: h) }
        if options.region == .embryoMask { ctx.log("No threshold YAML here, so the whole frame is used instead of the embryo mask.") }
        let name = channel < meta.channelNames.count ? meta.channelNames[channel] : "ch\(channel)"
        ctx.log("Z drift of \(name) (index \(channel)), T=\(src.t), Z=\(src.z)"
                + (meta.stageZ == nil ? ", no stage positions in the file" : ", using stage positions"))
        let tracker = ZTracker(options: options, metadata: meta)
        let T = src.t
        try orderedPipeline(count: T, width: pipelineWidth(frameBytes: src.frameBytes * 2), context: ctx, produce: { t -> ZDescriptor in
            let frame = try src.readFrame(t: t, p: p)
            return ZDrift.describe(frame: frame, channel: channel, box: box, pixelSizeUm: meta.physicalSizeX,
                                   detectNuclei: options.useNuclei)
        }, consume: { t, d in
            let s = tracker.add(d)
            ctx.log(String(format: "  t%-4d ", t) + ZDrift.line(s))
            ctx.progress("Measuring z drift", t + 1, T)
        })
        let plan = tracker.plan(pad: true)
        for line in ZReport.summary(steps: tracker.steps, plan: plan, z: src.z) { ctx.log(line) }
        if let url = csv {
            try ZReport.csv(steps: tracker.steps, plan: plan, stageZ: meta.stageZ).write(to: url, atomically: true, encoding: .utf8)
            ctx.log("Saved \(url.lastPathComponent)")
        }
        return Result(steps: tracker.steps, plan: plan, csv: csv)
    }
}
