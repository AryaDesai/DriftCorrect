import Foundation
import XCTest
@testable import DCCore

/// Z correction on a synthetic embryo: a fixed 3-D scene of nucleus-like blobs, seen through a stack that
/// starts at a different depth at each timepoint.
final class ZCorrectionTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dcztest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    static let size = 160, depth = 44, slices = 14, base = 14

    /// Scene planes (depth, size, size) as uint16: a bright disc with blobs in it, on a dim background.
    static let scene: [[UInt16]] = {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let n = size * size
        var planes = [[Float]](repeating: [Float](repeating: 0, count: n), count: depth)
        for z in 0..<depth {
            for y in 0..<size { for x in 0..<size {
                let r = hypot(Double(y - size / 2), Double(x - size / 2))
                planes[z][y * size + x] = (r < 62 ? 500 : 150) + Float(rnd() * 30)
            } }
        }
        for _ in 0..<260 {
            let angle = rnd() * 2 * .pi, radius = 56 * rnd().squareRoot()
            let cy = Double(size / 2) + radius * sin(angle), cx = Double(size / 2) + radius * cos(angle)
            let cz = 1 + rnd() * Double(depth - 2), amp = 1500 + 2000 * rnd()
            for z in max(0, Int(cz) - 3)...min(depth - 1, Int(cz) + 3) {
                for y in max(0, Int(cy) - 10)...min(size - 1, Int(cy) + 10) {
                    for x in max(0, Int(cx) - 10)...min(size - 1, Int(cx) + 10) {
                        let dz = (Double(z) - cz) / 0.9, dy = (Double(y) - cy) / 3.2, dx = (Double(x) - cx) / 3.2
                        planes[z][y * size + x] += Float(amp * exp(-0.5 * (dz * dz + dy * dy + dx * dx)))
                    }
                }
            }
        }
        return planes.map { $0.map { UInt16(min(65535, max(0, $0))) } }
    }()

    /// One timepoint whose first slice is scene plane `base + offset`.
    func frame(offset: Int) -> Volume {
        let n = Self.size * Self.size
        let v = Volume(c: 1, z: Self.slices, y: Self.size, x: Self.size, type: .uint16)
        for z in 0..<Self.slices {
            Self.scene[Self.base + offset + z].withUnsafeBytes { v.planePointer(c: 0, z: z).copyMemory(from: $0.baseAddress!, byteCount: n * 2) }
        }
        return v
    }

    /// Write a movie with the given stack offsets; optionally record them as stage positions (2 um per slice).
    func writeMovie(_ name: String, offsets: [Int], stage: Bool) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var meta = ImageMetadata(channelNames: ["nuc"], physicalSizeX: 0.43, physicalSizeY: 0.43, physicalSizeZ: 2, timeIncrement: 240)
        if stage {
            meta.stageZ = offsets.map { 1000 + 2 * Double($0) }
            meta.stageZStep = 2
        }
        let w = try OMETIFFWriter(url: url, t: offsets.count, c: 1, z: Self.slices, y: Self.size, x: Self.size, type: .uint16, metadata: meta)
        for o in offsets { try w.writeVolume(frame(offset: o)) }
        try w.finish()
        return url
    }

    func testStagePositionsRoundTripAndConcat() throws {
        let a = try writeMovie("a_P0.ome.tif", offsets: [0, 1], stage: true)
        let s = try TIFFStack(url: a)
        XCTAssertEqual(s.metadata.stageZ, [1000, 1002])
        XCTAssertEqual(s.metadata.stageZStep, 2)
        let plain = try TIFFStack(url: try writeMovie("plain.ome.tif", offsets: [0, 1], stage: false))
        XCTAssertNil(plain.metadata.stageZ)
        XCTAssertFalse(plain.omeXML!.contains("<Plane"))

        _ = try writeMovie("b_P0.ome.tif", offsets: [4], stage: true)
        let joined = tmp.appendingPathComponent("P0_concat.ome.tif")
        try TIFFConcat.concatenate(globFiles(tmp, pattern: "*_P0.ome.tif"), to: joined, context: .silent())
        let j = try TIFFSource(url: joined)
        XCTAssertEqual(j.metadata(position: 0).stageZ, [1000, 1002, 1008])
        XCTAssertEqual(j.metadata(position: 0).stageZStep, 2)
    }

    func testPlanDeadBandAndPadding() {
        // Positions 0, 0.55, 0.75, 2.75, -0.65: the shift waits until the position is 0.65 away from it.
        let plan = ZDrift.plan(steps: [0, 0.55, 0.2, 2.0, -3.4], reference: 0, deadBand: 0.15, pad: true)
        XCTAssertEqual(plan.shift, [0, 0, -1, -3, 1])
        XCTAssertEqual(plan.padLow, 3)
        XCTAssertEqual(plan.padHigh, 1)
        // A later reference timepoint keeps its own slices in place.
        let late = ZDrift.plan(steps: [0, 2, 0, -5], reference: 2)
        XCTAssertEqual(late.shift, [2, 0, 0, 5])
        XCTAssertEqual(ZDrift.plan(steps: [0, 2, 0, -5], pad: false).padLow, 0)
    }

    func testPlaceInsertsEmptySlices() {
        let v = frame(offset: 0)
        let out = ZDrift.place(v, shift: -2, padLow: 3, padHigh: 1)
        XCTAssertEqual(out.z, Self.slices + 4)
        XCTAssertEqual(out.floatPlane(1), v.floatPlane(0))                 // input slice 0 -> output slice 0 - 2 + 3
        XCTAssertEqual(out.floatPlane(0).max(), 0)                         // nothing lands here: empty
        XCTAssertEqual(out.floatPlane(Self.slices + 3).max(), 0)
        XCTAssertEqual(out.floatPlane(Self.slices), v.floatPlane(Self.slices - 1))
    }

    func testMeasuresKnownShifts() throws {
        // The stack start moves by these many slices; the tissue then appears to move the other way.
        let offsets = [0, 0, 3, 3, -2, -1]
        let expected: [Double] = [0, 0, -3, 0, 5, -1]
        for stage in [false, true] {
            let src = try TIFFSource(url: try writeMovie("m\(stage).ome.tif", offsets: offsets, stage: stage))
            for region in [ZRegion.wholeFrame, .box(x: 50, y: 50, width: 64, height: 64)] {
                var o = ZCorrectionOptions()
                o.region = region
                let r = try ZMeasure.run(source: src, options: o, csv: nil, context: .silent())
                for (t, e) in expected.enumerated() {
                    XCTAssertEqual(r.steps[t].dz, e, accuracy: 0.3, "t\(t) stage=\(stage) \(region)")
                    XCTAssertEqual(r.steps[t].flag, "", "t\(t)")
                    if stage && t > 0 { XCTAssertEqual(r.steps[t].stage!, e, accuracy: 1e-9) }
                }
                XCTAssertEqual(r.plan.shift, offsets.map { $0 - offsets[0] })
                XCTAssertEqual(r.plan.padLow, 2)
                XCTAssertEqual(r.plan.padHigh, 3)
                XCTAssertGreaterThan(r.steps[1].agreeing, 10, "nuclei should be matched (\(region))")
            }
            // After placing, every timepoint shows the same scene plane in a given output slice.
            let r = try ZMeasure.run(source: src, options: ZCorrectionOptions(), csv: nil, context: .silent())
            let k = r.plan.padLow + 6
            let reference = ZDrift.place(try src.readFrame(t: 0, p: 0), shift: r.plan.shift[0], padLow: r.plan.padLow, padHigh: r.plan.padHigh)
            for t in 1..<offsets.count {
                let v = ZDrift.place(try src.readFrame(t: t, p: 0), shift: r.plan.shift[t], padLow: r.plan.padLow, padHigh: r.plan.padHigh)
                XCTAssertEqual(v.floatPlane(k), reference.floatPlane(k), "t\(t)")
            }
        }
    }

    func testStageCoversJumpWithoutOverlap() throws {
        // An 11-slice jump leaves 3 of 14 slices in common: too few to compare, so the stage value is used as is.
        let offsets = [0, 11, 11]
        let withStage = try ZMeasure.run(source: TIFFSource(url: try writeMovie("jump.ome.tif", offsets: offsets, stage: true)),
                                         options: ZCorrectionOptions(), csv: tmp.appendingPathComponent("jump.csv"), context: .silent())
        XCTAssertEqual(withStage.steps[1].dz, -11, accuracy: 1e-9)
        XCTAssertTrue(withStage.steps[1].flag.hasPrefix("stage only"))
        XCTAssertEqual(withStage.steps[2].dz, 0, accuracy: 0.3)
        XCTAssertEqual(withStage.plan.shift, [0, 11, 11])
        let csv = try String(contentsOf: tmp.appendingPathComponent("jump.csv"), encoding: .utf8)
        XCTAssertEqual(csv.split(separator: "\n").count, 4)
    }

    func testAlignWithZCorrection() throws {
        let offsets = [0, 0, 3, 3, -2]
        let tif = try writeMovie("P0_concat.ome.tif", offsets: offsets, stage: true)
        let yaml = tmp.appendingPathComponent("P0_nuc_threshold.yaml")
        try """
        parameters:
          channel: nuc
          channel_index: 0
          sigma: 8
          percentile: 60.0
        source:
          file: \(tif.path)
        """.write(to: yaml, atomically: true, encoding: .utf8)
        var opts = AlignOptions(yaml: yaml)
        opts.zCorrection = ZCorrectionOptions()
        let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        XCTAssertEqual(r.zPlans[0].shift, [0, 0, 3, 3, -2])
        let out = try TIFFStack(url: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy_z.ome.tif"))
        XCTAssertEqual(out.z, Self.slices + 5)
        XCTAssertEqual(out.t, offsets.count)
        // The corrected stack starts at the same stage z at every timepoint.
        let stage = try XCTUnwrap(out.metadata.stageZ)
        for z in stage { XCTAssertEqual(z, stage[0], accuracy: 1e-6) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy_z_shifts.csv").path))
        // Timepoint 2 moved up 3 slices and 2 empty slices were added below: its slices 0-4 are empty.
        let t2 = try out.readFrame(2)
        XCTAssertEqual(t2.floatPlane(4).max(), 0)
        XCTAssertGreaterThan(t2.floatPlane(5).max() ?? 0, 0)

        // Without z correction the output is unchanged in name and depth.
        opts.zCorrection = nil
        _ = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        XCTAssertEqual(try TIFFStack(url: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy.ome.tif")).z, Self.slices)
    }
}
