import Foundation
import XCTest
@testable import DCCore

final class IOAndPipelineTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dctest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Flat samples of a stack in (T, C, Z, Y, X) order, as Float.
    func samples(_ s: TIFFStack) throws -> [Float] {
        var out: [Float] = []
        for t in 0..<s.t {
            let v = try s.readFrame(t)
            for p in 0..<v.planeCount { out += v.floatPlane(p) }
        }
        return out
    }

    func testReadPythonOMETIFF() throws {
        for c in Ref.cases("tiff") {
            let s = try TIFFStack(url: Ref.url(c["file"] as! String))
            let shape = Ref.shape(c["data"])
            XCTAssertEqual([s.t, s.c, s.z, s.y, s.x], shape, c["file"] as! String)
            XCTAssertEqual(s.metadata.channelNames, c["channels"] as! [String])
            let vox = (c["vox"] as! [NSNumber]).map { $0.doubleValue }
            XCTAssertEqual(s.metadata.voxel, VoxelSize(x: vox[0], y: vox[1], z: vox[2]))
            XCTAssertEqual(s.metadata.timeIncrement, (c["period"] as? NSNumber)?.doubleValue)
            XCTAssertTrue(bitsEqual(try samples(s), Ref.floats(c["data"])), c["file"] as! String)
        }
    }

    func testWriteReadRoundTrip() throws {
        for big in [false, true] {
            let url = tmp.appendingPathComponent("rt_\(big).ome.tif")
            let meta = ImageMetadata.standard(channelNames: ["Venus", "mCherry"], voxel: VoxelSize(x: 0.5, y: 0.5, z: 2), period: 300)
            let w = try OMETIFFWriter(url: url, t: 3, c: 2, z: 2, y: 5, x: 7, type: .uint16, metadata: meta, bigTIFF: big)
            var expected: [Float] = []
            for t in 0..<3 {
                let v = Volume(c: 2, z: 2, y: 5, x: 7, type: .uint16)
                let p = v.storage.raw.assumingMemoryBound(to: UInt16.self)
                for i in 0..<v.elementCount { p[i] = UInt16((i * 37 + t * 1000) % 65536); expected.append(Float(p[i])) }
                try w.writeVolume(v)
            }
            try w.finish()
            let s = try TIFFStack(url: url)
            XCTAssertEqual(s.tiff.isBigTIFF, big)
            XCTAssertEqual([s.t, s.c, s.z, s.y, s.x], [3, 2, 2, 5, 7])
            XCTAssertEqual(s.metadata.channelNames, ["Venus", "mCherry"])
            XCTAssertEqual(s.metadata.timeIncrement, 300)
            XCTAssertEqual(try samples(s), expected)
        }
    }

    func testND2Synthetic() throws {
        for c in Ref.cases("nd2") {
            let f = try ND2File(url: Ref.url(c["file"] as! String))
            let sizes = c["sizes"] as! [String: NSNumber]
            XCTAssertEqual([f.sizeT, f.sizeP, f.sizeZ, f.sizeC, f.sizeY, f.sizeX],
                           ["T", "P", "Z", "C", "Y", "X"].map { sizes[$0]!.intValue })
            XCTAssertEqual(f.channelNames, c["channels"] as! [String])
            let vox = (c["vox"] as! [NSNumber]).map { $0.doubleValue }
            XCTAssertEqual(f.voxelSize, VoxelSize(x: vox[0], y: vox[1], z: vox[2]))
            XCTAssertEqual(f.periodSeconds, (c["period"] as? NSNumber)?.doubleValue)
            // Data (T, P, Z, C, Y, X) against the nd2 package.
            let expected = Ref.load(c["data"], as: UInt16.self)
            var got: [UInt16] = []
            for t in 0..<f.sizeT {
                for p in 0..<f.sizeP {
                    let v = try f.readFrame(t: t, p: p)  // (C, Z, Y, X)
                    for z in 0..<f.sizeZ {
                        for ch in 0..<f.sizeC {
                            let ptr = v.planePointer(c: ch, z: z).assumingMemoryBound(to: UInt16.self)
                            got += UnsafeBufferPointer(start: ptr, count: v.planeElements)
                        }
                    }
                }
            }
            XCTAssertEqual(got, expected, c["file"] as! String)
        }
    }

    func testConvertMatchesPython() throws {
        let conv = Ref.dict("convert")
        let input = tmp.appendingPathComponent("in")
        try FileManager.default.copyItem(at: Ref.url(conv["input"] as! String), to: input)
        let out = tmp.appendingPathComponent("out")
        var opts = ConvertOptions(folder: input)
        opts.outputDirectory = out
        try ConvertPipeline(options: opts, context: .silent()).run()
        let py = Ref.url("convert/python_out")
        for name in conv["python_outputs"] as! [String] {
            let a = try TIFFStack(url: out.appendingPathComponent(name))
            let b = try TIFFStack(url: py.appendingPathComponent(name))
            XCTAssertEqual([a.t, a.c, a.z, a.y, a.x], [b.t, b.c, b.z, b.y, b.x], name)
            XCTAssertEqual(a.metadata.channelNames, b.metadata.channelNames, name)
            XCTAssertEqual(a.metadata.voxel, b.metadata.voxel, name)
            XCTAssertEqual(a.metadata.timeIncrement, b.metadata.timeIncrement, name)
            // Python writes the concatenated files as float32; the values must be equal.
            XCTAssertEqual(try samples(a), try samples(b), name)
            XCTAssertEqual(a.sampleType, .uint16, name)
        }
    }

    func testConcatOnlyRebuildsConcatenation() throws {
        let conv = Ref.dict("convert")
        let input = tmp.appendingPathComponent("in")
        try FileManager.default.copyItem(at: Ref.url(conv["input"] as! String), to: input)
        let out = tmp.appendingPathComponent("out")
        var opts = ConvertOptions(folder: input)
        opts.outputDirectory = out
        try ConvertPipeline(options: opts, context: .silent()).run()
        let concats = globFiles(out, pattern: "P*_concat.ome.tif")
        XCTAssertFalse(concats.isEmpty)
        var before: [String: [Float]] = [:]
        for url in concats {
            before[url.lastPathComponent] = try samples(TIFFStack(url: url))
            try FileManager.default.removeItem(at: url)
        }

        // Concatenation alone: no ND2 files are needed, and no per-file TIFF is rewritten.
        for nd2 in globFiles(input, pattern: "*.nd2") { try FileManager.default.removeItem(at: nd2) }
        opts.concatOnly = true
        try ConvertPipeline(options: opts, context: .silent()).run()
        for (name, expected) in before {
            XCTAssertEqual(try samples(TIFFStack(url: out.appendingPathComponent(name))), expected, name)
        }
    }

    func testAlignMatchesPython() throws {
        let src = Ref.url("align")
        let work = tmp.appendingPathComponent("align")
        try FileManager.default.copyItem(at: src, to: work)
        // The YAML refers to the TIFF by absolute path; point it at the copy.
        for name in ["percentile.yaml", "multi.yaml"] {
            let u = work.appendingPathComponent(name)
            var text = try String(contentsOf: u, encoding: .utf8)
            if let line = text.split(separator: "\n").first(where: { $0.contains("file:") }) {
                text = text.replacingOccurrences(of: String(line), with: "  file: \(work.appendingPathComponent("P0_concat.ome.tif").path)")
            }
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        for c in Ref.cases("align") {
            let yamlName = (c["yaml"] as! String).components(separatedBy: "/").last!
            let flags = c["flags"] as! [String]
            var opts = AlignOptions(yaml: work.appendingPathComponent(yamlName))
            opts.enlargeCanvas = !flags.contains("--no_enlarge_canvas")
            let outTIF = work.appendingPathComponent("aligned_P0_concat/P0_concat_xy.ome.tif")
            let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
            let expectedShifts = (c["shifts"] as! [[NSNumber]]).map { $0.map { $0.doubleValue } }
            let tolerance = yamlName == "percentile.yaml" ? 0.0051 : 1e-12  // the worker logs 2 decimals
            for (s, e) in zip(r.shifts[0], expectedShifts) {
                XCTAssertEqual(s.dy, e[0], accuracy: tolerance)
                XCTAssertEqual(s.dx, e[1], accuracy: tolerance)
            }
            let got = try TIFFStack(url: outTIF)
            let expected = Ref.load(c["expected"], as: UInt16.self)
            XCTAssertEqual(try samples(got).map { UInt16($0) }, expected, "\(yamlName) \(flags)")
            if c["expected_integer"] != nil {
                opts.shiftMode = .integer
                _ = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
                let gi = try TIFFStack(url: outTIF)
                XCTAssertEqual(try samples(gi).map { UInt16($0) }, Ref.load(c["expected_integer"], as: UInt16.self))
            }
        }
    }

    func testOrderedPipelineKeepsOrder() throws {
        var seen: [Int] = []
        try orderedPipeline(count: 200, width: 8, context: nil, produce: { i -> Int in
            usleep(UInt32((i * 7919) % 500))
            return i * 2
        }, consume: { i, v in
            XCTAssertEqual(v, i * 2)
            seen.append(i)
        })
        XCTAssertEqual(seen, Array(0..<200))
    }

    func testLZWAndPackBits() throws {
        // "TOBEORNOTTOBEORTOBEORNOT" style round trip through a tiny LZW encoder.
        let input: [UInt8] = Array("TOBEORNOTTOBEORTOBEORNOT#TOBEORNOTTOBEORTOBEORNOT".utf8)
        let encoded = lzwEncode(input)
        XCTAssertEqual(try Decompress.lzw(encoded, expected: input.count), input)
        let packed: [UInt8] = [0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80, 0x00, 0x2A, 0x22, 0xF7, 0xAA]
        let unpacked = try Decompress.packBits(packed, expected: 24)
        XCTAssertEqual(unpacked, [0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0x22,
                                  0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
    }

    /// Reference TIFF LZW encoder (MSB-first, early change) for the decoder test.
    func lzwEncode(_ data: [UInt8]) -> [UInt8] {
        var dict: [[UInt8]: Int] = [:]
        for i in 0..<256 { dict[[UInt8(i)]] = i }
        var next = 258, width = 9
        var bits: [Bool] = []
        func put(_ code: Int) { for k in stride(from: width - 1, through: 0, by: -1) { bits.append((code >> k) & 1 == 1) } }
        put(256)
        var w: [UInt8] = []
        for b in data {
            let wc = w + [b]
            if dict[wc] != nil { w = wc; continue }
            put(dict[w]!)
            dict[wc] = next; next += 1
            if next >= (1 << width) && width < 12 { width += 1 }  // encoder side of TIFF early change
            w = [b]
        }
        if !w.isEmpty { put(dict[w]!) }
        put(257)
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, bit) in bits.enumerated() where bit { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        return out
    }
}
