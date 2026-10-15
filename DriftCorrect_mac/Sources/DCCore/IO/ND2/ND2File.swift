import Foundation

/// Native reader for Nikon ND2 files (format versions 2.x and 3.x).
///
/// Ported from the chunk-map, CLX-variant and experiment-loop logic of the
/// open-source `nd2` Python package, which `nd2_to_tif.py`,
/// `find_threshold.py` and `centroid_align_xy.py` use through
/// `nd2.ND2File`. Legacy JPEG-2000 ND2 files (format 1.0) are not supported.
public final class ND2File: @unchecked Sendable {
    public enum LoopType: Int {
        case unknown = 0, timeLoop = 1, xyPosLoop = 2, xyDiscrLoop = 3, zStackLoop = 4
        case polarLoop = 5, spectLoop = 6, customLoop = 7, neTimeLoop = 8, manTimeLoop = 9

        var axis: Character {
            switch self {
            case .timeLoop, .neTimeLoop: return "T"
            case .xyPosLoop: return "P"
            case .zStackLoop: return "Z"
            default: return "U"
            }
        }
    }

    public struct Loop: Equatable {
        public var type: LoopType
        public var count: Int
        public var nestingLevel: Int = 0
        public var periodMs: Double?
        public var zStepUm: Double?
    }

    public struct Attributes: Equatable {
        public var widthPx: Int
        public var heightPx: Int
        public var widthBytes: Int
        public var componentCount: Int
        public var bitsPerComponentInMemory: Int
        public var bitsPerComponentSignificant: Int
        public var sequenceCount: Int
        /// "lossless", "lossy", "none" or nil (eCompression 0, 1, 2 / other).
        public var compressionType: String?
    }

    static let chunkMagic: UInt32 = 0x0ABE_CEDA
    static let jp2Magic: UInt32 = 0x0C00_0000
    static let fileSignature = "ND2 FILE SIGNATURE CHUNK NAME01!"
    static let chunkMapSignature = "ND2 CHUNK MAP SIGNATURE 0000001!"
    static let fileMapSignature = "ND2 FILEMAP SIGNATURE NAME 0001!"

    public let url: URL
    private let file: RandomAccessFile
    public let version: (major: Int, minor: Int)
    public private(set) var chunkMap: [String: UInt64] = [:]
    public private(set) var attributes: Attributes
    public private(set) var loops: [Loop] = []
    public private(set) var channelNames: [String] = []
    public private(set) var voxelSize = VoxelSize(x: 1, y: 1, z: 1)
    /// `periodMs / 1000` of the first TimeLoop, as `load_nd2` computes it.
    public private(set) var periodSeconds: Double?
    public private(set) var sampleType: SampleType = .uint16

    /// Axis sizes as the pipeline uses them: (T, P, Z, C, Y, X); missing axes are 1.
    public private(set) var sizeT = 1, sizeP = 1, sizeZ = 1, sizeC = 1
    public var sizeY: Int { attributes.heightPx }
    public var sizeX: Int { attributes.widthPx }
    /// Axis letters of the non-singleton loops, outermost first (`ND2File.sizes` order).
    public private(set) var loopAxes: [Character] = []
    private var loopCounts: [Int] = []
    private var frameChunkOffsets: [Int: UInt64] = [:]

    public init(url: URL) throws {
        self.url = url
        let f = try RandomAccessFile(url: url)
        file = f
        let head = try f.read(at: 0, count: min(112, Int(f.size)))
        guard head.count >= 16 else { throw DCError("Not an ND2 file: \(url.lastPathComponent)") }
        let hr = ByteReader(head)
        let magic = hr.u32(at: 0)
        if magic == ND2File.jp2Magic {
            throw DCError("\(url.lastPathComponent) is a legacy (JPEG 2000) ND2 file. Only ND2 format 2.0 and later is supported.")
        }
        guard magic == ND2File.chunkMagic, head.count >= 112 else { throw DCError("Not a valid ND2 file: \(url.lastPathComponent)") }
        let nameLen = hr.u32(at: 4), dataLen = hr.u64(at: 8)
        let name = String(decoding: head[16..<48], as: UTF8.self)
        guard nameLen == 32, dataLen == 64, name == ND2File.fileSignature else {
            throw DCError("Corrupt ND2 file header chunk: \(url.lastPathComponent)")
        }
        let major = Int(String(UnicodeScalar(head[48 + 3]))) ?? 0
        let minor = Int(String(UnicodeScalar(head[48 + 5]))) ?? 0
        version = (major, minor)

        // Placeholder values; replaced below.
        attributes = Attributes(widthPx: 0, heightPx: 0, widthBytes: 0, componentCount: 1,
                                bitsPerComponentInMemory: 16, bitsPerComponentSignificant: 16,
                                sequenceCount: 0, compressionType: nil)
        try readChunkMap()

        let v3 = version.major >= 3
        // Picture metadata (channels, calibration).
        let rawMetaTop = try decodeChunk(v3 ? "ImageMetadataSeqLV|0!" : "ImageMetadataSeq|0!")
        let rawMeta = rawMetaTop["SLxPictureMetadata"]?.dict ?? rawMetaTop
        let planesDict = rawMeta["sPicturePlanes"]?.dict ?? CLXDict()
        let channelCount = planesDict["uiCount"]?.int ?? 1

        // Attributes.
        let attrsTop = try decodeChunk(v3 ? "ImageAttributesLV!" : "ImageAttributes!")
        let a = attrsTop["SLxImageAttributes"]?.dict ?? attrsTop
        func req(_ k: String) throws -> Int {
            guard let v = a[k]?.int else { throw DCError("ND2 attribute \(k) is missing in \(url.lastPathComponent)") }
            return v
        }
        let bpc = try req("uiBpcInMemory")
        let ecomp = a["eCompression"]?.int ?? 2
        attributes = Attributes(widthPx: try req("uiWidth"), heightPx: try req("uiHeight"),
                                widthBytes: try req("uiWidthBytes"), componentCount: try req("uiComp"),
                                bitsPerComponentInMemory: bpc,
                                bitsPerComponentSignificant: a["uiBpcSignificant"]?.int ?? bpc,
                                sequenceCount: a["uiSequenceCount"]?.int ?? 0,
                                compressionType: (0..<3).contains(ecomp) ? ["lossless", "lossy", "none"][ecomp] : nil)
        switch bpc {
        case 8: sampleType = .uint8
        case 16: sampleType = .uint16
        case 32: sampleType = .float32
        default: throw DCError("Unsupported ND2 bit depth in memory: \(bpc)")
        }
        if attributes.compressionType == "lossy" {
            throw DCError("\(url.lastPathComponent) uses lossy compression, which is not supported.")
        }

        // Experiment loops.
        let expKey = v3 ? "ImageMetadataLV!" : "ImageMetadata!"
        if chunkMap[expKey] != nil {
            let expTop = try decodeChunk(expKey)
            let exp = expTop["SLxExperiment"]?.dict ?? expTop
            loops = try ND2File.loadExperiment(exp, level: 0, dest: [])
        }

        // Channel names: sPicturePlanes.sPlaneNew (or sPlane) values, sDescription.
        let rawPlanes = (planesDict["sPlaneNew"]?.dict).flatMap { $0.isEmpty ? nil : $0 } ?? planesDict["sPlane"]?.dict ?? CLXDict()
        channelNames = rawPlanes.values.map { $0["sDescription"]?.string ?? "" }
        if channelNames.count < channelCount {
            channelNames += (channelNames.count..<channelCount).map { "ch\($0)" }
        }

        // Voxel size: channels[0].volume.axesCalibration.
        if !rawPlanes.isEmpty {
            let cal = rawMeta["dCalibration"]?.double ?? 1.0
            var zCal = 1.0
            for loop in loops where loop.type == .zStackLoop { zCal = abs(loop.zStepUm ?? 0) }
            voxelSize = VoxelSize(x: cal > 0 ? cal : 1.0, y: cal > 0 ? cal : 1.0, z: zCal > 0 ? zCal : 1.0)
        }
        periodSeconds = loops.first(where: { $0.type == .timeLoop })?.periodMs.map { $0 / 1000.0 }

        // Axis sizes (ND2File.sizes, keeping singletons as 1).
        let perChannel = attributes.componentCount / max(1, channelCount)
        if perChannel == 3 {
            throw DCError("\(url.lastPathComponent) is an RGB ND2 file; only monochrome channels are supported.")
        }
        sizeC = attributes.componentCount
        var seen: [Character: Int] = [:]
        for loop in loops {
            let axis = loop.type.axis
            seen[axis] = loop.count
        }
        for (axis, count) in seen where count != 1 && axis == "U" {
            throw DCError("\(url.lastPathComponent) has a custom loop axis (U=\(count)), which the pipeline does not support.")
        }
        // Coordinate shape: one entry per distinct axis, in first-seen loop order, singletons removed.
        var order: [Character] = []
        for loop in loops where !order.contains(loop.type.axis) { order.append(loop.type.axis) }
        loopAxes = order.filter { (seen[$0] ?? 1) != 1 }
        loopCounts = loopAxes.map { seen[$0]! }
        sizeT = seen["T"] ?? 1
        sizeP = seen["P"] ?? 1
        sizeZ = seen["Z"] ?? 1

        for (key, offset) in chunkMap where key.hasPrefix("ImageDataSeq|") && key.hasSuffix("!") {
            let digits = key.dropFirst("ImageDataSeq|".count).dropLast()
            if let i = Int(digits) { frameChunkOffsets[i] = offset }
        }
    }

    // MARK: Chunks

    private func readChunkMap() throws {
        guard file.size >= 40 else { throw DCError("ND2 file is too short") }
        let tail = try file.read(at: file.size - 40, count: 40)
        let sig = String(decoding: tail[0..<32], as: UTF8.self)
        guard sig == ND2File.chunkMapSignature else {
            throw DCError("Invalid ND2 chunk map signature in \(url.lastPathComponent)")
        }
        let location = ByteReader(tail).u64(at: 32)
        let data = try readChunk(at: location, expectName: ND2File.fileMapSignature)
        var pos = 0
        let sigBytes = Array(ND2File.chunkMapSignature.utf8)
        while pos < data.count {
            guard let bang = data[pos...].firstIndex(of: UInt8(ascii: "!")) else { break }
            let nameBytes = Array(data[pos...bang])
            if nameBytes == sigBytes { break }
            let p = bang + 1
            guard p + 16 <= data.count else { break }
            let r = ByteReader(Array(data[p..<p + 16]))
            chunkMap[String(decoding: nameBytes, as: UTF8.self)] = r.u64(at: 0)
            pos = p + 16
        }
    }

    /// Read the data of the chunk whose header starts at `position`.
    func readChunk(at position: UInt64, expectName: String? = nil) throws -> [UInt8] {
        let (dataStart, dataLength) = try chunkData(at: position, expectName: expectName)
        return try file.read(at: dataStart, count: dataLength)
    }

    private func chunkData(at position: UInt64, expectName: String? = nil) throws -> (UInt64, Int) {
        let h = try file.read(at: position, count: 16)
        let r = ByteReader(h)
        guard r.u32(at: 0) == ND2File.chunkMagic else {
            throw DCError("Invalid ND2 chunk header at \(position) in \(url.lastPathComponent)")
        }
        let nameLength = Int(r.u32(at: 4))
        let dataLength = Int(r.u64(at: 8))
        if let expect = expectName {
            let name = try file.read(at: position + 16, count: nameLength)
            guard name.starts(with: Array(expect.utf8)) else {
                throw DCError("Expected ND2 chunk \(expect) at \(position) in \(url.lastPathComponent)")
            }
        }
        return (position + 16 + UInt64(nameLength), dataLength)
    }

    func decodeChunk(_ name: String) throws -> CLXDict {
        guard let offset = chunkMap[name] else {
            throw DCError("ND2 chunk \(name) not found in \(url.lastPathComponent)")
        }
        let data = try readChunk(at: offset)
        if data.first == UInt8(ascii: "<") {
            let v = try CLXXML.decode(data)
            if case .dict(let d) = v { return d }
            return CLXDict()
        }
        return try CLXLite.decode(data)
    }

    // MARK: Experiment loops (nd2._parse._parse.load_experiment)

    static func loadExperiment(_ src: CLXDict, level: Int, dest: [Loop]) throws -> [Loop] {
        var dest = dest
        var level = level
        guard var loop = try loadSingleLoop(src), loop.count != 0 else { return dest }
        if loop.type == .spectLoop {
            level -= 1
        } else if dest.isEmpty || dest[dest.count - 1].nestingLevel < level {
            loop.nestingLevel = level
            dest.append(loop)
        } else {
            let prev = dest[dest.count - 1]
            if prev.nestingLevel == level && prev.type == loop.type {
                loop.nestingLevel = level
                if prev.count < loop.count { dest[dest.count - 1] = loop }
            }
        }
        // NETimeLoop sub-loop special case (nd2 issue #190).
        if let pars = src["uLoopPars"]?.dict, let sub = pars["pSubLoops"]?.dict,
           let first = sub["i0000000000"]?.dict, let next = first["ppNextLevelEx"]?.dict,
           let firstNext = next["i0000000000"]?.dict, let exp = firstNext["SLxExperiment"]?.dict {
            dest += try loadExperiment(exp, level: 0, dest: [])
        }
        if let next = src["ppNextLevelEx"]?.dict, !next.isEmpty {
            for item in next.values {
                if let d = item.dict { dest = try loadExperiment(d, level: level + 1, dest: dest) }
            }
        }
        return dest
    }

    static func loadSingleLoop(_ exp: CLXDict) throws -> Loop? {
        let loopTypeRaw = exp["eType"]?.int ?? 0
        guard var pars = exp["uLoopPars"]?.dict, !pars.isEmpty, loopTypeRaw <= 9 else { return nil }
        if pars.keys == ["i0000000000"], let inner = pars["i0000000000"]?.dict { pars = inner }
        guard let type = LoopType(rawValue: loopTypeRaw) else { return nil }
        switch type {
        case .timeLoop:
            return parseTimeLoop(pars)
        case .xyPosLoop:
            return Loop(type: .xyPosLoop, count: parseXYCount(pars, valid: exp["pItemValid"]))
        case .zStackLoop:
            let count = pars["uiCount"]?.int ?? 0
            let low = pars["dZLow"]?.double ?? 0, hi = pars["dZHigh"]?.double ?? 0
            var step = pars["dZStep"]?.double ?? 0
            if step == 0 && count > 1 { step = abs(hi - low) / Double(count - 1) }
            return Loop(type: .zStackLoop, count: count, zStepUm: step)
        case .neTimeLoop:
            let valid = boolList(pars["pPeriodValid"])
            let periods = pars["pPeriod"]?.dict?.values ?? []
            var count = 0
            for (it, ok) in zip(periods, valid) where ok {
                if let d = it.dict, let t = parseTimeLoop(d) { count += t.count }
            }
            return Loop(type: .neTimeLoop, count: count)
        case .spectLoop:
            var count = pars["uiCount"]?.int ?? 0
            if let planes = pars["pPlanes"]?.dict, let c = planes["uiCount"]?.int { count = c }
            return Loop(type: .spectLoop, count: count)
        case .customLoop:
            return Loop(type: .customLoop, count: pars["uiCount"]?.int ?? 0)
        default:
            throw DCError("Unsupported ND2 experiment loop type \(loopTypeRaw)")
        }
    }

    static func parseTimeLoop(_ pars: CLXDict) -> Loop? {
        let count = pars["uiCount"]?.int ?? 0
        if count == 0 { return nil }
        return Loop(type: .timeLoop, count: count, periodMs: pars["dPeriod"]?.double)
    }

    static func boolList(_ v: CLXValue?) -> [Bool] {
        guard let v = v else { return [] }
        switch v {
        case .bytes(let b): return b.map { $0 != 0 }
        case .list(let l): return l.map { $0.truthy }
        case .dict(let d): return d.keys.sorted().map { d[$0]!.truthy }
        default: return []
        }
    }

    static func parseXYCount(_ pars: CLXDict, valid: CLXValue?) -> Int {
        var points: Int
        if let p = pars["Points"]?.dict { points = p.count }
        else if let x = pars["dPosX"]?.dict { points = x.count }
        else { points = 0 }
        let validList = boolList(valid)
        if !validList.isEmpty {
            points = zip(0..<points, validList).filter { $0.1 }.count
        }
        return points
    }

    // MARK: Frames

    /// Sequence index of loop coordinates (numpy `ravel_multi_index` over the non-singleton loops).
    public func sequenceIndex(t: Int, p: Int, z: Int) -> Int {
        var index = 0
        for (axis, count) in zip(loopAxes, loopCounts) {
            let coord: Int
            switch axis {
            case "T": coord = t
            case "P": coord = p
            case "Z": coord = z
            default: coord = 0
            }
            index = index * count + coord
        }
        return index
    }

    /// Byte layout of one stored frame: rows of `widthBytes`, samples interleaved by component.
    private var frameBytes: Int { attributes.heightPx * attributes.widthBytes }

    /// Read frame `seq` as interleaved (Y, X, component) samples without row padding.
    public func readInterleaved(_ seq: Int) throws -> [UInt8] {
        let bpp = attributes.bitsPerComponentInMemory / 8
        let rowOut = attributes.widthPx * attributes.componentCount * bpp
        var out = [UInt8](repeating: 0, count: rowOut * attributes.heightPx)
        guard let chunkOffset = frameChunkOffsets[seq] else { return out }  // missing frame: zeros
        let (dataStart, dataLength) = try chunkData(at: chunkOffset)
        var stored: [UInt8]
        if attributes.compressionType == "lossless" {
            let compressed = try file.read(at: dataStart + 8, count: max(0, dataLength - 8))
            stored = try Decompress.zlib(compressed, expected: frameBytes)
        } else {
            let available = max(0, min(frameBytes, dataLength - 8))
            stored = try file.read(at: dataStart + 8, count: available)
        }
        let rowIn = attributes.widthBytes
        out.withUnsafeMutableBytes { dst in
            stored.withUnsafeBytes { src in
                for y in 0..<attributes.heightPx {
                    let s = y * rowIn
                    if s >= src.count { break }
                    let n = min(rowOut, src.count - s)
                    (dst.baseAddress! + y * rowOut).copyMemory(from: src.baseAddress! + s, byteCount: n)
                }
            }
        }
        return out
    }

    /// Read (t, p, z) for every channel into plane `z` of each channel in `volume` (C, Z, Y, X).
    public func readPlanes(t: Int, p: Int, z: Int, into volume: Volume, zSlot: Int? = nil) throws {
        precondition(volume.c == sizeC && volume.y == sizeY && volume.x == sizeX && volume.type == sampleType)
        let raw = try readInterleaved(sequenceIndex(t: t, p: p, z: z))
        let comps = attributes.componentCount
        let n = sizeY * sizeX
        let slot = zSlot ?? z
        raw.withUnsafeBytes { src in
            switch sampleType {
            case .uint8:
                let s = src.bindMemory(to: UInt8.self)
                for ci in 0..<comps {
                    let d = volume.planePointer(c: ci, z: slot).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<n { d[i] = s[i * comps + ci] }
                }
            case .uint16:
                let s = src.bindMemory(to: UInt16.self)
                for ci in 0..<comps {
                    let d = volume.planePointer(c: ci, z: slot).assumingMemoryBound(to: UInt16.self)
                    if comps == 1 { d.update(from: s.baseAddress!, count: n) }
                    else { for i in 0..<n { d[i] = s[i * comps + ci] } }
                }
            case .float32:
                let s = src.bindMemory(to: Float.self)
                for ci in 0..<comps {
                    let d = volume.planePointer(c: ci, z: slot).assumingMemoryBound(to: Float.self)
                    for i in 0..<n { d[i] = s[i * comps + ci] }
                }
            }
        }
    }

    /// Read one timepoint of one position as a (C, Z, Y, X) volume
    /// (`data[t, p].transpose(1, 0, 2, 3)` in the Python code).
    public func readFrame(t: Int, p: Int) throws -> Volume {
        let v = Volume(c: sizeC, z: sizeZ, y: sizeY, x: sizeX, type: sampleType)
        for zi in 0..<sizeZ { try readPlanes(t: t, p: p, z: zi, into: v) }
        return v
    }

    public var metadata: ImageMetadata {
        ImageMetadata.standard(channelNames: channelNames, voxel: voxelSize, period: periodSeconds)
    }
}
