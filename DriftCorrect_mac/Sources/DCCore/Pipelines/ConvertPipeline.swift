import Foundation

/// Port of `nd2_to_tif.py` (the "Convert ND2 to TIFF" tool).
///
/// Each ND2 file is read once, in file order, and every embryo position is
/// written to its own OME-TIFF at the same time. Then the per-file TIFFs of
/// each position are joined along T. Concatenated files keep the stored
/// sample type (see `TIFFConcat`).
public struct ConvertOptions {
    public var folder: URL
    public var outputDirectory: URL?
    /// Process all positions in one pass over each ND2 file.
    public var parallel = true
    /// Only this position (0-based); nil = all.
    public var position: Int?
    /// Skip conversion; only join the per-file TIFFs already in the output directory.
    public var concatOnly = false
    public init(folder: URL) { self.folder = folder }
}

public final class ConvertPipeline {
    let options: ConvertOptions
    let ctx: RunContext

    public init(options: ConvertOptions, context: RunContext) {
        self.options = options
        self.ctx = context
    }

    @discardableResult
    public func run() throws -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw DCError("Error: not a directory: \(options.folder.path)")
        }
        let nd2Files = options.concatOnly ? [] : globFiles(options.folder, pattern: "*.nd2")
        guard options.concatOnly || !nd2Files.isEmpty else {
            throw DCError("Error: no .nd2 files found in \(options.folder.path)")
        }
        let outDir = options.outputDirectory ?? options.folder.appendingPathComponent("tifs")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if !options.concatOnly { ctx.log("Found \(nd2Files.count) ND2 file(s) in \(options.folder.path)") }
        ctx.log("Output directory: \(outDir.path)")

        var written: [URL] = []
        var targetPositions: [Int] = []
        if options.concatOnly {
            targetPositions = options.position.map { [$0] } ?? ConvertPipeline.existingPositions(in: outDir)
        }
        for (fileIndex, url) in nd2Files.enumerated() {
            try ctx.checkCancelled()
            ctx.log("\nOpening \(url.lastPathComponent) ...")
            let nd2 = try ND2File(url: url)
            let T = nd2.sizeT, P = nd2.sizeP, Z = nd2.sizeZ, C = nd2.sizeC, Y = nd2.sizeY, X = nd2.sizeX
            ctx.log("  Shape: T=\(T), P=\(P), Z=\(Z), C=\(C), Y=\(Y), X=\(X)")
            if let pos = options.position {
                guard pos >= 0 && pos < P else {
                    throw DCError("Position \(pos) is out of range: \(url.lastPathComponent) has \(P) position(s)")
                }
                targetPositions = [pos]
            } else {
                targetPositions = Array(0..<P)
            }
            let base = PyFormat.stem(url)
            let meta = nd2.metadata
            let groups: [[Int]] = (options.parallel && options.position == nil) ? [targetPositions] : targetPositions.map { [$0] }
            for group in groups {
                var writers: [Int: OMETIFFWriter] = [:]
                for p in group {
                    let out = outDir.appendingPathComponent("\(base)_P\(p).ome.tif")
                    ctx.log("  Writing \(out.lastPathComponent) ...")
                    writers[p] = try OMETIFFWriter(url: out, t: T, c: C, z: Z, y: Y, x: X,
                                                   type: nd2.sampleType, metadata: meta)
                }
                // Work items in (t, p) order; each reads all Z frames of one timepoint and position.
                let items = (0..<T).flatMap { t in group.map { (t, $0) } }
                let width = pipelineWidth(frameBytes: C * Z * Y * X * nd2.sampleType.byteCount)
                try orderedPipeline(count: items.count, width: width, context: ctx, produce: { i -> Volume in
                    let (t, p) = items[i]
                    return try nd2.readFrame(t: t, p: p)
                }, consume: { i, volume in
                    try writers[items[i].1]!.writeVolume(volume)
                    ctx.progress("Converting \(url.lastPathComponent) (\(fileIndex + 1)/\(nd2Files.count))", i + 1, items.count)
                })
                for p in group {
                    try writers[p]!.finish()
                    written.append(writers[p]!.url)
                }
            }
        }

        ctx.log("\nConcatenating per-embryo TIFFs ...")
        for p in targetPositions {
            try ctx.checkCancelled()
            let tifs = globFiles(outDir, pattern: "*_P\(p).ome.tif")
            if tifs.count < 2 {
                ctx.log("  P\(p): only \(tifs.count) file(s), skipping concatenation")
                continue
            }
            let concat = outDir.appendingPathComponent("P\(p)_concat.ome.tif")
            ctx.log("  P\(p): concatenating \(tifs.count) files -> \(concat.lastPathComponent)")
            try TIFFConcat.concatenate(tifs, to: concat, context: ctx)
            written.append(concat)
        }
        ctx.log("\nDone.")
        return written
    }

    /// Position indices of the per-file TIFFs (`*_P{p}.ome.tif`) in `dir`, sorted.
    static func existingPositions(in dir: URL) -> [Int] {
        let pattern = #/_P(\d+)\.ome\.tif$/#
        let positions = globFiles(dir, pattern: "*_P*.ome.tif").compactMap { url in
            url.lastPathComponent.firstMatch(of: pattern).flatMap { Int($0.1) }
        }
        return Array(Set(positions)).sorted()
    }
}
