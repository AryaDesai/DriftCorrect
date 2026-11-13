import ArgumentParser
import DCApple
import DCCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The command line tool. The `convert` and `align` commands take the same arguments as nd2_to_tif.py and
/// centroid_align_xy.py. Both spellings `--output_dir` and `--output-dir` work.
@main
struct DC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dc",
        abstract: "Embryo drift-correction tools (Apple silicon).",
        subcommands: [Convert.self, Align.self, CorrectZ.self, ZShifts.self, ND2Info.self, Bench.self])
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

/// Read a channel given as a name or as an index that starts at 0.
func parseChannel(_ c: String?) -> (index: Int?, name: String?) {
    guard let c = c else { return (nil, nil) }
    return Int(c).map { ($0, nil) } ?? (nil, c)
}

/// Read the region to follow from a `--…-region` option and a `--…-box` option. `prefix` is z or xy.
func parseRegion(_ region: String?, box: String?, prefix: String, default fallback: FollowRegion) throws -> FollowRegion {
    var parsed: FollowRegion?
    if let b = box {
        let v = b.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4, v.allSatisfy({ $0 != nil }), v[2]! > 0, v[3]! > 0 else {
            throw ValidationError("--\(prefix)-box needs x,y,width,height in pixels")
        }
        parsed = .box(x: v[0]!, y: v[1]!, width: v[2]!, height: v[3]!)
    }
    switch region?.lowercased() {
    case nil: return parsed ?? fallback
    case "mask": return .embryoMask
    case "whole": return .wholeFrame
    case "box":
        guard let b = parsed else { throw ValidationError("--\(prefix)-region box needs --\(prefix)-box x,y,width,height") }
        return b
    default: throw ValidationError("--\(prefix)-region must be mask, whole or box")
    }
}

/// The z correction settings that `align --z-correct`, `correct-z` and `z-shifts` share.
struct ZOptionGroup: ParsableArguments {
    @Option(name: [.customLong("z-channel"), .customLong("z_channel")],
            help: "The channel to follow in z, given as a name or as an index that starts at 0. A nuclear marker is the best choice. The default is the threshold channel of the YAML file, or channel 0 when there is no YAML file.")
    var zChannel: String?

    @Option(name: [.customLong("z-region"), .customLong("z_region")],
            help: "The part of the image to follow in z. It is whole for the whole frame (default), mask for the embryo mask, or box for the box that --z-box gives.")
    var zRegion: String?

    @Option(name: [.customLong("z-box"), .customLong("z_box")],
            help: "A box over cells that should stay in the same slice, as x,y,width,height in pixels of the first timepoint.")
    var zBox: String?

    @Option(name: [.customLong("z-drop-above"), .customLong("z_drop_above")],
            help: "Leave out timepoints whose movement from the timepoint before them exceeds this many slices.")
    var zDropAbove: Double?

    @Option(name: [.customLong("z-span"), .customLong("z_span")],
            help: "Each timepoint is also compared with the one this many timepoints earlier, which catches slow movement (default 5). With 1 only neighbours are compared.")
    var zSpan: Int?

    func make() throws -> ZCorrectionOptions {
        var o = ZCorrectionOptions()
        if let v = zSpan {
            guard v >= 1 else { throw ValidationError("--z-span must be 1 or more") }
            o.span = v
        }
        (o.channelIndex, o.channelName) = parseChannel(zChannel)
        o.region = try parseRegion(zRegion, box: zBox, prefix: "z", default: .wholeFrame)
        if let limit = zDropAbove, !limit.isFinite || limit <= 0 {
            throw ValidationError("--z-drop-above must be a positive number of slices")
        }
        o.maximumStep = zDropAbove
        return o
    }
}

/// The settings of the xy alignment by image matching, which `align --xy-method image` selects.
struct XYOptionGroup: ParsableArguments {
    @Option(name: [.customLong("xy-method"), .customLong("xy_method")],
            help: "centroid centres the centroid of the embryo mask (default). image matches the image of each timepoint with the timepoint before it.")
    var xyMethod = "centroid"

    @Option(name: [.customLong("xy-channel"), .customLong("xy_channel")],
            help: "The channel that image matching compares, given as a name or as an index that starts at 0. A nuclear marker is the best choice. The default is the threshold channel of the YAML file.")
    var xyChannel: String?

    @Option(name: [.customLong("xy-region"), .customLong("xy_region")],
            help: "The part of the image that image matching follows. It is whole for the whole frame (default), mask for the embryo mask, or box for the box that --xy-box gives.")
    var xyRegion: String?

    @Option(name: [.customLong("xy-box"), .customLong("xy_box")],
            help: "A box over cells that should stay still, as x,y,width,height in pixels of the first timepoint.")
    var xyBox: String?

    @Flag(name: [.customLong("xy-no-hold"), .customLong("xy_no_hold")],
          help: "Do not hold the body in place with the embryo mask. The frame can then slowly travel when the cells move through the body.")
    var xyNoHold = false

    @Option(name: [.customLong("xy-smoothing"), .customLong("xy_smoothing")],
            help: "The number of timepoints over which the position of the body and the turn are averaged (default 10).")
    var xySmoothing: Double?

    @Option(name: [.customLong("xy-max-angle"), .customLong("xy_max_angle")],
            help: "The largest turn between two neighbouring timepoints that image matching looks for, in degrees (default 3). With 0 the matching only shifts.")
    var xyMaxAngle: Double?

    @Flag(name: [.customLong("xy-no-rotation"), .customLong("xy_no_rotation")],
          help: "Do not correct rotation. Image matching then only shifts.")
    var xyNoRotation = false

    func make() throws -> XYMatchOptions? {
        switch xyMethod.lowercased() {
        case "centroid": return nil
        case "image":
            var o = XYMatchOptions()
            (o.channelIndex, o.channelName) = parseChannel(xyChannel)
            o.region = try parseRegion(xyRegion, box: xyBox, prefix: "xy", default: .wholeFrame)
            o.holdInPlace = !xyNoHold
            if let v = xySmoothing {
                guard v.isFinite, v >= 0 else { throw ValidationError("--xy-smoothing must be 0 or a positive number of timepoints") }
                o.smoothing = v
            }
            if let v = xyMaxAngle {
                guard v.isFinite, v >= 0 else { throw ValidationError("--xy-max-angle must be 0 or a positive number of degrees") }
                o.maximumAngle = v
            }
            if xyNoRotation { o.maximumAngle = 0 }
            return o
        default: throw ValidationError("--xy-method must be centroid or image")
        }
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
    static let configuration = CommandConfiguration(abstract: "Align embryo movies in xy from a threshold YAML, by the mask centroid or by image matching, and optionally correct z drift.")

    @Argument(help: "Threshold YAML from the Mask tool.")
    var yamlFile: String

    @Flag(name: [.customLong("use-nd2"), .customLong("use_nd2")], help: "Load from the ND2 file instead of the per-embryo TIF.")
    var useND2 = false

    @Option(help: "Frames per second of the movies (default: 2).")
    var fps: Double = 2

    @Flag(name: [.customLong("no-enlarge-canvas"), .customLong("no_enlarge_canvas")], help: "Keep the original canvas (edge data may be clipped).")
    var noEnlargeCanvas = false

    @Flag(name: [.customLong("use-gpu"), .customLong("use_gpu")], help: "Whole-pixel shifts, as the Python --use_gpu path produced. (The GPU is always used.)")
    var useGPU = false

    @Option(name: .customLong("shift-mode"), help: "subpixel (scipy bilinear, default) or integer (whole pixels).")
    var shiftMode: String?

    @Flag(name: [.customLong("low-memory"), .customLong("low_memory")], help: "Do not keep frames in memory between the two passes.")
    var lowMemory = false

    @Flag(help: "Do not write MP4 movies.")
    var noMovies = false

    @Flag(name: [.customLong("z-correct"), .customLong("z_correct")],
          help: "Also correct z drift after the xy alignment. Whole slices move and empty slices fill the gaps.")
    var zCorrect = false

    @OptionGroup var xy: XYOptionGroup

    @OptionGroup var z: ZOptionGroup

    @OptionGroup var backend: BackendOption

    func run() throws {
        var o = AlignOptions(yaml: URL(fileURLWithPath: yamlFile))
        o.xyMatching = try xy.make()
        if zCorrect { o.zCorrection = try z.make() }
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

struct CorrectZ: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "correct-z",
        abstract: "Correct z drift of an OME-TIFF or ND2 file without the xy alignment. Writes {name}_z.ome.tif next to the file.")

    @Argument(help: "An OME-TIFF or ND2 file, for example the _xy.ome.tif that align wrote.")
    var file: String

    @Option(help: "Threshold YAML from the Mask tool. It is needed only with --z-region mask.")
    var yaml: String?

    @Option(help: "Embryo position (ND2 only).")
    var position = 0

    @Flag(name: [.customLong("no-enlarge-stack"), .customLong("no_enlarge_stack")],
          help: "Keep the depth of the stack. Slices that leave it are dropped.")
    var noEnlargeStack = false

    @Flag(name: [.customLong("low-memory"), .customLong("low_memory")], help: "Do not keep frames in memory between the two passes.")
    var lowMemory = false

    @OptionGroup var z: ZOptionGroup
    @OptionGroup var backend: BackendOption

    func run() throws {
        var o = ZCorrectOptions(input: URL(fileURLWithPath: file))
        o.yaml = yaml.map { URL(fileURLWithPath: $0) }
        o.position = position
        o.enlargeStack = !noEnlargeStack
        o.lowMemory = lowMemory
        o.z = try z.make()
        let start = Date()
        _ = try ZCorrectPipeline.run(options: o, backend: backend.make(), context: consoleContext())
        print(String(format: "Finished in %.1f s", Date().timeIntervalSince(start)))
    }
}

struct ZShifts: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "z-shifts",
        abstract: "Measure the z drift of an OME-TIFF or ND2 file and save it as CSV, without writing a corrected stack.")

    @Argument(help: "An OME-TIFF or ND2 file.")
    var file: String

    @Option(help: "Threshold YAML from the Mask tool. It is needed only with --z-region mask.")
    var yaml: String?

    @Option(help: "Embryo position (ND2 only).")
    var position = 0

    @Option(help: "Where to save the table (default: next to the file, {name}_z_shifts.csv).")
    var csv: String?

    @OptionGroup var z: ZOptionGroup
    @OptionGroup var backend: BackendOption

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let source: FrameSource = url.pathExtension.lowercased() == "nd2" ? try ND2Source(url: url) : try TIFFSource(url: url)
        let options = try z.make()
        let cfg = try yaml.map { try ThresholdConfig.load(URL(fileURLWithPath: $0)) }
        let out = csv.map { URL(fileURLWithPath: $0) }
            ?? url.deletingLastPathComponent().appendingPathComponent("\(PyFormat.stemWithoutOME(url))_z_shifts.csv")
        let start = Date()
        _ = try ZMeasure.run(source: source, position: position, options: options, thresholds: cfg, backend: backend.make(),
                             csv: out, context: consoleContext())
        print(String(format: "Finished in %.1f s", Date().timeIntervalSince(start)))
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
    static let configuration = CommandConfiguration(abstract: "Time the Gaussian, the shift, and the shift with rotation on CPU and Metal.")
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
            try body()  // Run once to warm up, which covers the first GPU use and the allocation.
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
            let move = Rigid.shift(dx: -2.61, dy: 3.37).after(Rigid.rotation(degrees: 4, aboutX: Double(size) / 2, y: Double(size) / 2))
            let tw = try median(7) {
                _ = try backend.warp(frame, pad: Padding(top: 10, bottom: 10, left: 10, right: 10), transform: move)
            }
            print(String(format: "%@: gaussian %dx%d sigma %.0f: %.1f ms | shift %d planes: %.1f ms | shift with rotation: %.1f ms | checksum %.3f",
                         backend.name, size, size, sigma, tg * 1000, planes, ts * 1000, tw * 1000, g.pixels[n / 2]))
        }
    }
}
