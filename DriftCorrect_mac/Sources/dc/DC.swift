import ArgumentParser
import DCApple
import DCCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Command-line front end. The `convert` and `align` commands take the same
/// arguments as nd2_to_tif.py and centroid_align_xy.py (both `--output_dir`
/// and `--output-dir` spellings work).
@main
struct DC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dc",
        abstract: "Embryo drift-correction tools (Apple silicon).",
        subcommands: [Convert.self, Align.self, ManualXY.self, ND2Info.self, Bench.self])
}

struct BackendOption: ParsableArguments {
    @Flag(help: "Use the CPU reference implementation instead of Metal.")
    var cpu = false

    func make() -> ComputeBackend { cpu ? CPUBackend() : MetalBackend.best() }
}

func consoleContext() -> RunContext {
    let ctx = RunContext(log: { line in
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    }, progress: { phase, current, total in
        let text = "\r\(phase): \(current)/\(total)"
        FileHandle.standardError.write(((current == total) ? text + "\n" : text).data(using: .utf8)!)
    })
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { ctx.cancel() }
    source.resume()
    signalSources.append(source)
    return ctx
}
var signalSources: [DispatchSourceSignal] = []

func parseBool(_ s: String) throws -> Bool {
    switch s.lowercased() {
    case "true", "1", "yes": return true
    case "false", "0", "no": return false
    default: throw ValidationError("Expected true or false")
    }
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert a folder of ND2 files into per-embryo concatenated OME-TIFFs.")

    @Argument(help: "Directory containing .nd2 files. Defaults to the current directory.")
    var nd2Folder: String = "."

    @Option(name: [.customLong("output-dir"), .customLong("output_dir")], help: "Output directory (default: tifs inside the ND2 folder).")
    var outputDir: String?

    @Option(help: "Process positions in parallel (default: true).")
    var parallel: String = "true"

    @Option(help: "Extract only this embryo position index (e.g. 0).")
    var position: Int?

    @Flag(name: [.customLong("concat-only"), .customLong("concat_only")], help: "Skip conversion; only join existing per-embryo TIFFs.")
    var concatOnly = false

    func run() throws {
        var o = ConvertOptions(folder: URL(fileURLWithPath: nd2Folder))
        o.outputDirectory = outputDir.map { URL(fileURLWithPath: $0) }
        o.parallel = try parseBool(parallel)
        o.position = position
        o.concatOnly = concatOnly
        try ConvertPipeline(options: o, context: consoleContext()).run()
    }
}

struct Align: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Centroid-align embryo movies from a threshold YAML.")

    @Argument(help: "Threshold YAML from the Mask tool.")
    var yamlFile: String

    @Flag(name: [.customLong("use-nd2"), .customLong("use_nd2")], help: "Load from the ND2 file instead of the per-embryo TIF.")
    var useND2 = false

    @Option(help: "Frames per second of the movies (default: 2).")
    var fps: Double = 2

    @Flag(name: [.customLong("no-enlarge-canvas"), .customLong("no_enlarge_canvas")], help: "Single pass without canvas expansion (edge data may be clipped).")
    var noEnlargeCanvas = false

    @Flag(name: [.customLong("use-gpu"), .customLong("use_gpu")], help: "Whole-pixel shifts, as the Python --use_gpu path produced. (The GPU is always used.)")
    var useGPU = false

    @Option(name: .customLong("shift-mode"), help: "subpixel (scipy bilinear, default) or integer (whole pixels).")
    var shiftMode: String?

    @Flag(name: [.customLong("low-memory"), .customLong("low_memory")], help: "Do not keep frames in memory between the two passes.")
    var lowMemory = false

    @Flag(help: "Do not write MP4 movies.")
    var noMovies = false

    @OptionGroup var backend: BackendOption

    func run() throws {
        var o = AlignOptions(yaml: URL(fileURLWithPath: yamlFile))
        o.useND2 = useND2
        o.fps = fps
        o.enlargeCanvas = !noEnlargeCanvas
        o.lowMemory = lowMemory
        if let m = shiftMode {
            guard let mode = ShiftMode(rawValue: m) else { throw ValidationError("shift-mode must be subpixel or integer") }
            o.shiftMode = mode
        } else if useGPU {
            o.shiftMode = .integer
        }
        let start = Date()
        _ = try AlignPipeline(options: o, backend: backend.make(), movies: noMovies ? nil : (HEVCMovieFactory() as MovieWriterFactory),
                              context: consoleContext()).run()
        print(String(format: "Finished in %.1f s", Date().timeIntervalSince(start)))
    }
}

struct ManualXY: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "manual-xy", abstract: "Apply manual XY shifts to a TIF.")

    @Option(help: "Input OME-TIFF.") var tif: String?
    @Option(help: "Threshold YAML (the TIF is found as the Align tool finds it).") var yaml: String?
    @Option(name: .customLong("row"), help: "t1,t2,y1,x1,y2,x2 : point (y1,x1) at t1 matches (y2,x2) at t2. Repeat for more rows.")
    var rows: [String] = []
    @Option(name: .customLong("shift-mode")) var shiftMode: String = "subpixel"
    @Flag(name: .customLong("no-enlarge-canvas")) var noEnlargeCanvas = false
    @Flag(name: .customLong("low-memory")) var lowMemory = false
    @Option var fps: Double = 2
    @Flag var noMovies = false
    @OptionGroup var backend: BackendOption

    func run() throws {
        let tifURL: URL
        if let t = tif { tifURL = URL(fileURLWithPath: t) }
        else if let y = yaml { tifURL = try ManualXYPipeline.tif(forYAML: URL(fileURLWithPath: y)) }
        else { throw ValidationError("Give --tif or --yaml") }
        let parsed = try rows.map { r -> ManualRow in
            let v = r.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 6, v.allSatisfy({ $0 != nil }) else { throw ValidationError("Bad --row \(r)") }
            return ManualRow(t1: Int(v[0]!), t2: Int(v[1]!), p1: (v[2]!, v[3]!), p2: (v[4]!, v[5]!))
        }
        var o = ManualXYOptions(rows: parsed)
        guard let mode = ShiftMode(rawValue: shiftMode) else { throw ValidationError("shift-mode must be subpixel or integer") }
        o.shiftMode = mode
        o.enlargeCanvas = !noEnlargeCanvas
        o.lowMemory = lowMemory
        o.fps = fps
        try ManualXYPipeline.run(tif: tifURL, options: o, backend: backend.make(),
                                 movies: noMovies ? nil : (HEVCMovieFactory() as MovieWriterFactory), context: consoleContext())
    }
}

struct ND2Info: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "nd2-info",
        abstract: "Print ND2 metadata (and per-frame checksums) as JSON, for comparison with scripts/nd2_dump.py.")
    @Argument var file: String
    @Flag var checksums = false

    func run() throws {
        let f = try ND2File(url: URL(fileURLWithPath: file))
        var out: [String: Any] = [
            "sizes": ["T": f.sizeT, "P": f.sizeP, "Z": f.sizeZ, "C": f.sizeC, "Y": f.sizeY, "X": f.sizeX],
            "channels": f.channelNames,
            "voxel": [f.voxelSize.x, f.voxelSize.y, f.voxelSize.z],
            "period_s": f.periodSeconds.map { $0 as Any } ?? NSNull(),
            "dtype": f.sampleType.rawValue,
            "loops": f.loopAxes.map(String.init),
        ]
        #if canImport(CryptoKit)
        if checksums {
            var sums: [String] = []
            let v = Volume(c: f.sizeC, z: 1, y: f.sizeY, x: f.sizeX, type: f.sampleType)
            for t in 0..<f.sizeT {
                for p in 0..<f.sizeP {
                    for z in 0..<f.sizeZ {
                        try f.readPlanes(t: t, p: p, z: z, into: v, zSlot: 0)
                        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: v.storage.raw, count: v.byteCount))
                        sums.append(String(digest.map { String(format: "%02x", $0) }.joined().prefix(16)))
                    }
                }
            }
            out["frame_sha256_16"] = sums
        }
        #endif
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Time the Gaussian and the shift on CPU and Metal.")
    @Option var size = 1024
    @Option var sigma = 30.0
    @Option var planes = 82

    func run() throws {
        let n = size * size
        var img = Image2D(width: size, height: size)
        for i in 0..<n { img.pixels[i] = Float((i * 7919) % 4096) }
        let frame = Volume(c: 1, z: planes, y: size, x: size, type: .uint16)
        let p = frame.storage.raw.assumingMemoryBound(to: UInt16.self)
        for i in 0..<frame.elementCount { p[i] = UInt16(i % 60000) }
        func median(_ runs: Int, _ body: () throws -> Void) rethrows -> Double {
            try body()  // warm-up (first GPU use, allocation)
            var times: [Double] = []
            for _ in 0..<runs {
                let t = Date()
                try body()
                times.append(Date().timeIntervalSince(t))
            }
            return times.sorted()[runs / 2]
        }
        for backend in [CPUBackend() as ComputeBackend, MetalBackend.best()] {
            var g = img
            let tg = try median(7) { g = try backend.gaussian(img, sigma: sigma) }
            let ts = try median(7) {
                _ = try backend.shift(frame, pad: Padding(top: 10, bottom: 10, left: 10, right: 10), dy: 3.37, dx: -2.61, mode: .subpixel)
            }
            print(String(format: "%@: gaussian %dx%d sigma %.0f: %.1f ms | shift %d planes: %.1f ms | checksum %.3f",
                         backend.name, size, size, sigma, tg * 1000, planes, ts * 1000, g.pixels[n / 2]))
        }
    }
}
