import Foundation

/// The codec decides how the frames of a movie file are compressed.
public enum MovieCodec: String, CaseIterable, Sendable {
    /// HEVC is also called H.265. Its files are about half the size of H.264 files at the same quality.
    case hevc
    /// H.264 plays on almost every computer and in most programs, which makes it the safer choice for sharing.
    case h264
}

/// These are the settings of the Export tool.
public struct ExportOptions {
    /// This is the OME-TIFF or ND2 movie to export.
    public var source: URL
    /// This is the channel to export, given by index or by name. When both are nil, every channel gets its own movie.
    public var channelIndex: Int?
    public var channelName: String?
    /// This is the slice to show, counted from 1. When it is nil, the movie shows the maximum projection along z.
    public var slice: Int?
    /// This is the playback speed in frames per second. Each timepoint is one frame.
    public var fps = 2.0
    /// When this is true, the brightness is set once for the whole movie. When it is false, each frame sets its own.
    public var wholeMovieContrast = true
    /// When this is set, the frames of this second movie are shown to the right of the first one.
    public var compare: URL?
    public init(source: URL) { self.source = source }
}

/// The Export tool. It writes one MP4 movie for each exported channel, next to the source movie. Each frame is the
/// maximum projection along z or one slice, in gray. The brightest 0.5% of the pixels are white.
public enum ExportPipeline {
    /// The share of the pixels that is shown as white is 100 minus this percentile. This is the same rule that the
    /// movies of the alignment use.
    static let percentile = 99.5
    /// The brightness of the whole movie comes from this many timepoints, spread evenly over the movie. Reading every
    /// timepoint for it would read the whole movie twice.
    static let contrastSamples = 20

    /// Each side of a frame shows one movie file. This holds the file, the channels it shows and its embryo position.
    struct Side {
        var source: FrameSource
        var channels: [Int]
        var position: Int
    }

    /// Write the movies and return their paths. Every setting is checked before the first movie is started, so that
    /// a wrong setting does not leave some movies written and others missing.
    public static func run(options o: ExportOptions, backend: ComputeBackend, movies: MovieWriterFactory,
                           context ctx: RunContext) throws -> [URL] {
        guard o.fps.isFinite && o.fps > 0 else { throw DCError("The movie speed must be a positive number") }
        // Open the first movie and report its size.
        ctx.log("Loading \(o.source.lastPathComponent) ...")
        let a = try ZPass.open(o.source)
        let namesA = Array(a.metadata.channelNames.prefix(a.c))
        ctx.log("  Shape: T=\(a.t), P=\(a.positions), Z=\(a.z), C=\(a.c), Y=\(a.y), X=\(a.x)")

        // Export every channel of the first movie, or the one channel that was chosen.
        let channelsA: [Int]
        if o.channelIndex == nil && o.channelName == nil {
            channelsA = Array(0..<a.c)
        } else {
            channelsA = [try resolveChannel(index: o.channelIndex, name: o.channelName, names: namesA, count: a.c,
                                            fallback: 0, label: "Export")]
        }
        var compared: FrameSource?
        var channelsB: [Int] = []
        if let url = o.compare {
            ctx.log("Comparing with \(url.lastPathComponent)")
            let b = try ZPass.open(url)
            ctx.log("  Shape: T=\(b.t), P=\(b.positions), Z=\(b.z), C=\(b.c), Y=\(b.y), X=\(b.x)")
            // The second movie shows the channel with the same name. The channel order can differ between files, so a
            // match by name is safer. When no name matches, the channel with the same index is used.
            let namesB = Array(b.metadata.channelNames.prefix(b.c))
            channelsB = try channelsA.map { c in
                if let match = namesB.firstIndex(of: name(c, namesA)) { return match }
                guard c < b.c else {
                    throw DCError("The second movie has no channel \(name(c, namesA)). Its channels are \(namesB.joined(separator: ", ")).")
                }
                return c
            }
            // A file with one embryo can be compared with every embryo of the first movie. Files with several embryos
            // must hold the same number, so that each embryo is compared with the same embryo.
            if b.positions > 1 && b.positions != a.positions {
                throw DCError("The two movies hold a different number of embryos (\(a.positions) and \(b.positions)).")
            }
            compared = b
        }
        let b = compared
        // The slice must exist in both movies. A stack that z correction enlarged has more slices than its input.
        if let s = o.slice {
            for (url, src) in [(o.source, a)] + (b.map { [(o.compare!, $0)] } ?? []) where s < 1 || s > src.z {
                throw DCError("Slice \(s) is outside \(url.lastPathComponent), which has \(src.z) slices.")
            }
        }
        // The two movies can differ in length, for example when z correction dropped timepoints. The export then
        // stops after the shorter movie, because there is nothing to show on the other side.
        var T = a.t
        if let b = b, b.t != a.t {
            T = min(a.t, b.t)
            ctx.log("  The two movies have \(a.t) and \(b.t) timepoints. The export stops after \(T).")
        }

        // The movies are saved next to the first movie. The name says the channel, the view and the compared movie,
        // so that exports with different settings do not overwrite each other.
        let folder = o.source.deletingLastPathComponent()
        let view = o.slice.map { "z\($0)" } ?? "max"
        let versus = o.compare.map { "_vs_" + PyFormat.stemWithoutOME($0) } ?? ""
        var written: [URL] = []
        // Each embryo of an ND2 file gets its own movies.
        for p in 0..<a.positions {
            let sides = [Side(source: a, channels: channelsA, position: p)]
                + (b.map { [Side(source: $0, channels: channelsB, position: $0.positions > 1 ? p : 0)] } ?? [])
            let stem = PyFormat.stemWithoutOME(o.source) + (a.positions > 1 ? "_P\(p)" : "")
            let urls = channelsA.map { c in
                folder.appendingPathComponent("\(stem)_\(name(c, namesA).replacingOccurrences(of: " ", with: "_"))_\(view)\(versus).mp4")
            }
            // The two movies sit side by side, so the frame is as wide as both and as tall as the taller one.
            let width = sides.reduce(0) { $0 + $1.source.x }, height = sides.map { $0.source.y }.max()!

            // Set the brightness of each channel of each movie from a sample of timepoints spread over the movie.
            // Each side gets its own value, so that a dimmer movie is not shown darker than the other one.
            if o.wholeMovieContrast { ctx.log("  Setting the brightness from \(min(T, contrastSamples)) timepoints ...") }
            let whites = o.wholeMovieContrast
                ? try sides.map { side in try brightness(side, slice: o.slice, count: T, backend: backend) } : nil

            // Read the timepoints in parallel and write the frames in order. A failure deletes the partial movies.
            var writers: [MovieWriter] = []
            do {
                for u in urls { writers.append(try movies.makeWriter(url: u, width: width, height: height, fps: o.fps)) }
                try orderedPipeline(count: T, width: pipelineWidth(frameBytes: sides.reduce(0) { $0 + $1.source.frameBytes }),
                                    context: ctx, produce: { t -> [[UInt8]] in
                    // Each channel gets a black frame, and each movie is copied into it at its place from the left.
                    var frames = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: urls.count)
                    var left = 0
                    for (k, side) in sides.enumerated() {
                        let frame = try side.source.readFrame(t: t, p: side.position)
                        for (i, c) in side.channels.enumerated() {
                            let pixels = try image(frame, channel: c, slice: o.slice, backend: backend)
                            // Scale with the brightness of the whole movie, or with the brightness of this frame alone.
                            let gray = whites.map { Contrast.scale(pixels, vmax: $0[k][i]) } ?? Contrast.autoContrast(pixels, percentile: percentile)
                            place(gray, width: frame.x, height: frame.y, into: &frames[i], canvasWidth: width, left: left)
                        }
                        left += frame.x
                    }
                    return frames
                }, consume: { t, frames in
                    for (w, f) in zip(writers, frames) { try w.append(gray: f) }
                    ctx.progress("Exporting" + (a.positions > 1 ? " (embryo \(p))" : ""), t + 1, T)
                })
                for w in writers { try w.finish() }
            } catch {
                writers.forEach { $0.cancel() }
                throw error
            }
            for u in urls { ctx.log("  Saved \(u.lastPathComponent)") }
            written += urls
        }
        return written
    }

    /// Return the name of a channel. A file without channel names gets ch0, ch1 and so on.
    static func name(_ c: Int, _ names: [String]) -> String { c < names.count ? names[c] : "ch\(c)" }

    /// Return the image of one channel of a frame, which is one slice or the maximum projection along z.
    static func image(_ frame: Volume, channel: Int, slice: Int?, backend: ComputeBackend) throws -> [Float] {
        if let s = slice { return frame.floatPlane(frame.planeIndex(c: channel, z: s - 1)) }
        return try backend.maxProjectZ(frame, channel: channel).pixels
    }

    /// Return the value that is shown as white for each channel of one movie. It is the percentile of the pixels of
    /// timepoints spread evenly over the movie. Every fourth pixel is used, which gives the same value to within a
    /// gray level and keeps the memory small.
    static func brightness(_ side: Side, slice: Int?, count T: Int, backend: ComputeBackend) throws -> [Float] {
        let n = min(T, contrastSamples)
        let times = (0..<n).map { n > 1 ? $0 * (T - 1) / (n - 1) : 0 }
        var values = [[Float]](repeating: [], count: side.channels.count)
        for t in times {
            let frame = try side.source.readFrame(t: t, p: side.position)
            for (i, c) in side.channels.enumerated() {
                let pixels = try image(frame, channel: c, slice: slice, backend: backend)
                values[i] += stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
            }
        }
        return values.map { v in
            let white = Stats.percentile(v, percentile)
            return white > 0 ? white : 1
        }
    }

    /// Copy a gray image into a wider canvas, with its left edge at column `left` and its top at the top. A shorter
    /// image leaves black below it.
    static func place(_ gray: [UInt8], width: Int, height: Int, into canvas: inout [UInt8], canvasWidth: Int, left: Int) {
        gray.withUnsafeBufferPointer { src in
            canvas.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    (dst.baseAddress! + y * canvasWidth + left).update(from: src.baseAddress! + y * width, count: width)
                }
            }
        }
    }
}
