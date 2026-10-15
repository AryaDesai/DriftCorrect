import Foundation

/// A TIFF file viewed as a (T, C, Z, Y, X) stack, as `tifffile.series[0]` shows it.
///
/// Singleton axes are kept (tifffile squeezes them, which made the Python
/// scripts fail on single-channel or single-slice files).
public final class TIFFStack: @unchecked Sendable {
    public let url: URL
    public let tiff: TIFFFile
    public let t: Int, c: Int, z: Int, y: Int, x: Int
    public let sampleType: SampleType
    public let metadata: ImageMetadata
    /// OME-XML text of the first page, when present (`tif.ome_metadata`).
    public let omeXML: String?
    /// Axis strides for the page index, in pages.
    private let strideT: Int, strideC: Int, strideZ: Int
    private let firstPage: Int

    public var shape: (t: Int, c: Int, z: Int, y: Int, x: Int) { (t, c, z, y, x) }
    public var pagesPerTimepoint: Int { c * z }

    public convenience init(url: URL) throws {
        try self.init(tiff: TIFFFile(url: url))
    }

    public init(tiff: TIFFFile) throws {
        self.tiff = tiff
        self.url = tiff.url
        let p0 = tiff.pages[0]
        guard let st = p0.sampleType else {
            throw DCError("Unsupported sample format in \(tiff.url.lastPathComponent): \(p0.bitsPerSample)-bit")
        }
        sampleType = st
        y = p0.height
        x = p0.width
        let desc = p0.description ?? ""
        let n = tiff.pages.count

        var order = "XYZCT"
        var sizes: (t: Int, c: Int, z: Int)
        var meta: ImageMetadata?
        var ome: String?
        var first = 0

        // 1. JSON description (tifffile "shaped" series) — load_tif_metadata tries this first.
        if let json = TIFFStack.parseJSON(desc) {
            let shape = (json["shape"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            let axes = (json["axes"] as? String) ?? (shape.count == 5 ? "TCZYX" : "")
            var dims: [Character: Int] = [:]
            if shape.count == axes.count {
                for (a, s) in zip(axes, shape) { dims[a, default: 1] *= s }
            }
            sizes = (dims["T"] ?? 1, dims["C"] ?? 1, dims["Z"] ?? 1)
            if sizes.t * sizes.c * sizes.z != n {
                sizes = (n, 1, 1)
            }
            // Row-major over the axes as written (T slowest, then C, then Z).
            let ordered = axes.filter { "TCZ".contains($0) }
            order = "XY" + String(ordered.reversed())
            if let ch = json["Channel"] as? [String: Any], let names = ch["Name"] {
                let list: [String] = (names as? [String]) ?? ((names as? String).map { [$0] } ?? [])
                meta = ImageMetadata(channelNames: list,
                                     physicalSizeX: (json["PhysicalSizeX"] as? NSNumber)?.doubleValue,
                                     physicalSizeY: (json["PhysicalSizeY"] as? NSNumber)?.doubleValue,
                                     physicalSizeZ: (json["PhysicalSizeZ"] as? NSNumber)?.doubleValue,
                                     timeIncrement: (json["TimeIncrement"] as? NSNumber)?.doubleValue)
            }
        } else if desc.contains("<OME"), let px = OMEXML.parse(desc) {
            // 2. OME-XML.
            ome = desc
            order = px.dimensionOrder
            sizes = (px.sizeT, px.sizeC, px.sizeZ)
            first = px.firstIFD
            if first + sizes.t * sizes.c * sizes.z > n {
                throw DCError("\(tiff.url.lastPathComponent): OME-XML declares \(sizes.t * sizes.c * sizes.z) planes but the file has \(n - first)")
            }
            meta = OMEXML.metadata(from: px, channelCount: sizes.c)
        } else if desc.hasPrefix("ImageJ=") {
            // 3. ImageJ hyperstack: C fastest, then Z, then T.
            var kv: [String: String] = [:]
            for line in desc.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
            }
            let cc = Int(kv["channels"] ?? "") ?? 1
            let zz = Int(kv["slices"] ?? "") ?? 1
            var tt = Int(kv["frames"] ?? "") ?? 1
            if cc * zz * tt != n { tt = max(1, n / max(1, cc * zz)) }
            sizes = (tt, cc, zz)
            order = "XYCZT"
            meta = ImageMetadata(channelNames: (0..<cc).map { "ch\($0)" },
                                 physicalSizeX: 1, physicalSizeY: 1,
                                 physicalSizeZ: Double(kv["spacing"] ?? "") ?? 1,
                                 timeIncrement: Double(kv["finterval"] ?? ""))
        } else {
            // 4. Plain multi-page TIFF: one plane per timepoint.
            sizes = (n, 1, 1)
        }

        t = sizes.t; c = sizes.c; z = sizes.z
        firstPage = first
        omeXML = ome
        metadata = meta ?? ImageMetadata(channelNames: (0..<sizes.c).map { "ch\($0)" },
                                         physicalSizeX: 1, physicalSizeY: 1, physicalSizeZ: 1, timeIncrement: nil)

        // Page strides from the dimension order (first letter after XY varies fastest).
        var stride = 1
        var sT = 0, sC = 0, sZ = 0
        let letters = Array(order.uppercased().dropFirst(2))
        let validOrder = letters.count == 3 && Set(letters) == Set(["Z", "C", "T"])
        for letter in validOrder ? letters : ["Z", "C", "T"] {
            switch letter {
            case "Z": sZ = stride; stride *= sizes.z
            case "C": sC = stride; stride *= sizes.c
            default: sT = stride; stride *= sizes.t
            }
        }
        strideT = sT; strideC = sC; strideZ = sZ

        for i in first..<min(n, first + sizes.t * sizes.c * sizes.z) {
            let p = tiff.pages[i]
            if p.width != x || p.height != y || p.sampleType != sampleType {
                throw DCError("\(tiff.url.lastPathComponent): page \(i) has a different size or sample type")
            }
        }
    }

    static func parseJSON(_ s: String) -> [String: Any]? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func pageIndex(t ti: Int, c ci: Int, z zi: Int) -> Int {
        firstPage + ti * strideT + ci * strideC + zi * strideZ
    }

    /// Read timepoint `ti` as a (C, Z, Y, X) volume in the file's sample type.
    public func readFrame(_ ti: Int) throws -> Volume {
        let v = Volume(c: c, z: z, y: y, x: x, type: sampleType)
        try readFrame(ti, into: v)
        return v
    }

    public func readFrame(_ ti: Int, into v: Volume) throws {
        precondition(v.c == c && v.z == z && v.y == y && v.x == x && v.type == sampleType)
        for ci in 0..<c {
            for zi in 0..<z {
                try tiff.readPage(pageIndex(t: ti, c: ci, z: zi), into: v.planePointer(c: ci, z: zi))
            }
        }
    }

    /// Read only channel `ci` of timepoint `ti` as a (1, Z, Y, X) volume.
    public func readChannel(_ ti: Int, channel ci: Int) throws -> Volume {
        let v = Volume(c: 1, z: z, y: y, x: x, type: sampleType)
        for zi in 0..<z {
            try tiff.readPage(pageIndex(t: ti, c: ci, z: zi), into: v.planePointer(c: 0, z: zi))
        }
        return v
    }
}
