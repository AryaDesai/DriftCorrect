import Foundation

/// One manual correspondence: point `p1` at timepoint `t1` and point `p2` at `t2`
/// mark the same feature. Timepoint `t2` is shifted by `p1 - p2`.
public struct ManualRow: Equatable, Sendable {
    public var t1: Int
    public var t2: Int
    public var p1: (y: Double, x: Double)
    public var p2: (y: Double, x: Double)
    public init(t1: Int, t2: Int, p1: (y: Double, x: Double), p2: (y: Double, x: Double)) {
        self.t1 = t1; self.t2 = t2; self.p1 = p1; self.p2 = p2
    }
    public static func == (a: ManualRow, b: ManualRow) -> Bool {
        a.t1 == b.t1 && a.t2 == b.t2 && a.p1 == b.p1 && a.p2 == b.p2
    }
}

public struct ManualXYOptions {
    public var rows: [ManualRow]
    /// Treat rows as incremental corrections at adjacent-frame boundaries.
    /// Each correction propagates from t2 through the last timepoint.
    public var propagateForward = false
    public var shiftMode: ShiftMode = .subpixel
    public var lowMemory = false
    public var enlargeCanvas = true
    public var fps: Double = 2
    public init(rows: [ManualRow]) { self.rows = rows }
}

/// Port of `apply_manual_xy_to_tif` and `apply_manual_xy_from_yaml`.
public enum ManualXYPipeline {
    /// Resolve the TIF for a threshold YAML (`resolve_xy_tif_from_yaml`).
    public static func tif(forYAML yaml: URL) throws -> URL {
        let cfg = try ThresholdConfig.load(yaml)
        return try AlignPipeline.resolveTIF(yaml: yaml, sourceFile: cfg.sourceFile).url
    }

    /// Resolve per-frame offsets once, so previews and export use the same sums.
    /// Legacy CLI rows retain their per-target behavior unless propagation is enabled.
    public static func resolvedShifts(timepoints T: Int, options: ManualXYOptions) throws -> [(dy: Double, dx: Double)] {
        guard T > 0 else { throw DCError("The input has no timepoints") }
        var shifts = [(dy: Double, dx: Double)](repeating: (0, 0), count: T)
        var boundaries = Set<Int>()
        for row in options.rows {
            guard row.t1 >= 0 && row.t1 < T && row.t2 >= 0 && row.t2 < T else {
                throw DCError("Manual row has out-of-range timepoint: t1=\(row.t1), t2=\(row.t2), T=\(T)")
            }
            if options.propagateForward {
                guard row.t2 == row.t1 + 1 else { throw DCError("Forward corrections require adjacent timepoints") }
                guard boundaries.insert(row.t2).inserted else { throw DCError("Only one correction per boundary is allowed") }
            }
            // Preserve the existing float32 offset representation.
            let dy = Double(Float(row.p1.y - row.p2.y)), dx = Double(Float(row.p1.x - row.p2.x))
            guard dy.isFinite && dx.isFinite else { throw DCError("Manual offsets must be finite") }
            shifts[row.t2] = (dy, dx)
        }
        if options.propagateForward, T > 1 {
            for t in 1..<T {
                shifts[t].dy += shifts[t - 1].dy
                shifts[t].dx += shifts[t - 1].dx
                guard shifts[t].dy.isFinite && shifts[t].dx.isFinite else { throw DCError("Cumulative offsets must be finite") }
            }
        }
        return shifts
    }

    @discardableResult
    public static func run(tif: URL, options: ManualXYOptions, backend: ComputeBackend,
                           movies: MovieWriterFactory?, context ctx: RunContext) throws -> URL {
        guard FileManager.default.fileExists(atPath: tif.path) else { throw DCError("TIF not found: \(tif.path)") }
        let src = try TIFFSource(url: tif)
        let T = src.t
        let shifts = try resolvedShifts(timepoints: T, options: options)
        let stem = PyFormat.stemWithoutOME(tif)
        let outDir = tif.deletingLastPathComponent().appendingPathComponent("aligned_\(stem)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let out = outDir.appendingPathComponent("\(stem)_xy_manual.ome.tif")
        let pad = options.enlargeCanvas ? Padding.covering(dys: shifts.map { $0.dy }, dxs: shifts.map { $0.dx }) : .none
        let Y = src.y + pad.top + pad.bottom, X = src.x + pad.left + pad.right
        ctx.log("Applying manual shifts to \(tif.lastPathComponent) -> \(out.lastPathComponent)")
        let writer = try OMETIFFWriter(url: out, t: T, c: src.c, z: src.z, y: Y, x: X, type: .uint16,
                                       metadata: src.metadata, bigTIFF: options.lowMemory ? true : nil)
        let urls = src.metadata.channelNames.prefix(src.c).map { outDir.appendingPathComponent("\(stem)_xy_manual_\($0)_aligned.mp4") }
        let mv = try movies.map { try ChannelMovies(factory: $0, urls: Array(urls), width: X, height: Y, fps: options.fps) }
        do {
            try orderedPipeline(count: T, width: pipelineWidth(frameBytes: src.frameBytes), context: ctx, produce: { t -> (Volume, [[UInt8]]) in
                let frame = try src.readFrame(t: t, p: 0)
                let o = try backend.shift(frame, pad: pad, dy: shifts[t].dy, dx: shifts[t].dx, mode: options.shiftMode)
                return (o, mv == nil ? [] : ChannelMovies.grayFrames(try backend.maxProjectAll(o)))
            }, consume: { t, v in
                try writer.writeVolume(v.0)
                try mv?.append(v.1)
                ctx.progress("Manual XY shift", t + 1, T)
            })
            try writer.finish()
            try mv?.finish()
        } catch {
            mv?.cancel()
            throw error
        }
        ctx.log("Saved \(out.lastPathComponent)")
        for u in mv?.urls ?? [] { ctx.log("Saved \(u.lastPathComponent)") }
        return out
    }
}
