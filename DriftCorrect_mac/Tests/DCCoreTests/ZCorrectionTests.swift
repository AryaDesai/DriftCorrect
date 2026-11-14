import Foundation
import XCTest
@testable import DCCore

/// Tests of z correction on a synthetic embryo. The embryo is a fixed scene of blobs that look like nuclei, and the
/// stack of each timepoint starts at a different depth of that scene.
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

    /// Settings that follow the whole frame. The default region is the embryo mask, which needs a threshold YAML file.
    var wholeFrame: ZCorrectionOptions {
        var o = ZCorrectionOptions()
        o.region = .wholeFrame
        return o
    }

    /// The planes of the scene as uint16. The scene is a bright disc with blobs in it on a dim background.
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

    /// One timepoint whose first slice is scene plane `base + offset`. The scene is moved by (dy, dx) pixels in xy,
    /// and pixels that the move uncovers are 0.
    func frame(offset: Int, dy: Int = 0, dx: Int = 0) -> Volume {
        let n = Self.size
        let v = Volume(c: 1, z: Self.slices, y: n, x: n, type: .uint16, zeroed: true)
        for z in 0..<Self.slices {
            let plane = Self.scene[Self.base + offset + z]
            let out = v.planePointer(c: 0, z: z).assumingMemoryBound(to: UInt16.self)
            for y in 0..<n where y - dy >= 0 && y - dy < n {
                for x in 0..<n where x - dx >= 0 && x - dx < n { out[y * n + x] = plane[(y - dy) * n + x - dx] }
            }
        }
        return v
    }

    /// Write a movie with the given stack offsets and xy moves. With `stage`, the offsets are also recorded as stage
    /// positions.
    func writeMovie(_ name: String, offsets: [Int], moves: [(Int, Int)]? = nil, stage: Bool) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var meta = ImageMetadata(channelNames: ["nuc"], physicalSizeX: 0.43, physicalSizeY: 0.43, physicalSizeZ: 2, timeIncrement: 240)
        if stage {
            meta.stageZ = offsets.map { 1000 + 2 * Double($0) }
            meta.stageZStep = 2
        }
        let w = try OMETIFFWriter(url: url, t: offsets.count, c: 1, z: Self.slices, y: Self.size, x: Self.size, type: .uint16, metadata: meta)
        for (t, o) in offsets.enumerated() { try w.writeVolume(frame(offset: o, dy: moves?[t].0 ?? 0, dx: moves?[t].1 ?? 0)) }
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
        // The positions are 0, 0.55, 0.75, 2.75 and -0.65. The shift changes only when the position is 0.65 away from it.
        let plan = ZDrift.plan(steps: [0, 0.55, 0.2, 2.0, -3.4], deadBand: 0.15, pad: true)
        XCTAssertEqual(plan.shift, [0, 0, -1, -3, 1])
        XCTAssertEqual(plan.padLow, 3)
        XCTAssertEqual(plan.padHigh, 1)
        XCTAssertEqual(ZDrift.plan(steps: [0, 2, 0, -5], pad: false).padLow, 0)
    }

    func testPlaceInsertsEmptySlices() {
        let v = frame(offset: 0)
        let out = ZDrift.place(v, shift: -2, padLow: 3, padHigh: 1)
        XCTAssertEqual(out.z, Self.slices + 4)
        // Input slice 0 lands on output slice 1, and no input slice lands on output slice 0 or on the last output slice.
        XCTAssertEqual(out.floatPlane(1), v.floatPlane(0))
        XCTAssertEqual(out.floatPlane(0).max(), 0)
        XCTAssertEqual(out.floatPlane(Self.slices + 3).max(), 0)
        XCTAssertEqual(out.floatPlane(Self.slices), v.floatPlane(Self.slices - 1))
    }

    func testMeasuresKnownShifts() throws {
        // The start of the stack moves by this many slices, so the tissue appears to move the other way.
        let offsets = [0, 0, 3, 3, -2, -1]
        let expected: [Double] = [0, 0, -3, 0, 5, -1]
        for stage in [false, true] {
            let url = try writeMovie("m\(stage).ome.tif", offsets: offsets, stage: stage)
            let src = try TIFFSource(url: url)
            for region in [FollowRegion.wholeFrame, .box(x: 50, y: 50, width: 64, height: 64)] {
                var o = ZCorrectOptions(input: url)
                o.z.region = region
                let r = try ZCorrectPipeline.run(options: o, backend: CPUBackend(), context: .silent())
                for (t, e) in expected.enumerated() {
                    XCTAssertEqual(r.steps[t].dz, e, accuracy: 0.3, "t\(t) stage=\(stage) \(region)")
                    XCTAssertEqual(r.steps[t].flag, "", "t\(t)")
                }
                XCTAssertEqual(r.plan.shift, offsets.map { $0 - offsets[0] })
                XCTAssertEqual(r.plan.padLow, 2)
                XCTAssertEqual(r.plan.padHigh, 3)
            }
            // After placing, every timepoint shows the same scene plane in a given output slice.
            var o = ZCorrectOptions(input: url)
            o.z = wholeFrame
            let r = try ZCorrectPipeline.run(options: o, backend: CPUBackend(), context: .silent())
            let k = r.plan.padLow + 6
            let reference = ZDrift.place(try src.readFrame(t: 0, p: 0), shift: r.plan.shift[0], padLow: r.plan.padLow, padHigh: r.plan.padHigh)
            for t in 1..<offsets.count {
                let v = ZDrift.place(try src.readFrame(t: t, p: 0), shift: r.plan.shift[t], padLow: r.plan.padLow, padHigh: r.plan.padHigh)
                XCTAssertEqual(v.floatPlane(k), reference.floatPlane(k), "t\(t)")
            }
        }
    }

    func testEmptyRegionIsFlagged() {
        let empty = Volume(c: 1, z: Self.slices, y: Self.size, x: Self.size, type: .uint16, zeroed: true)
        let blank = ZDrift.describe(frame: empty, channel: 0)
        let step = ZDrift.match(blank, blank)
        XCTAssertEqual(step.dz, 0)
        XCTAssertEqual(step.flag, "no data in the region")
    }

    func testCorrectZWithoutXYAlignment() throws {
        let offsets = [0, 3, 3, -2]
        let tif = try writeMovie("P0_concat_xy.ome.tif", offsets: offsets, stage: false)
        var o = ZCorrectOptions(input: tif)
        o.z = wholeFrame
        let r = try ZCorrectPipeline.run(options: o, backend: CPUBackend(), context: .silent())
        XCTAssertEqual(r.tiff.lastPathComponent, "P0_concat_xy_z.ome.tif")
        XCTAssertEqual(r.plan.shift, [0, 3, 3, -2])
        let out = try TIFFStack(url: r.tiff)
        XCTAssertEqual(out.z, Self.slices + 5)
        XCTAssertEqual(out.y, Self.size)
        // Output slice k holds the same scene plane at every timepoint, with the original pixel values.
        let k = r.plan.padLow + 6
        let first = try out.readFrame(0).floatPlane(k)
        XCTAssertEqual(first, frame(offset: 0).floatPlane(6))
        for t in 1..<offsets.count { XCTAssertEqual(try out.readFrame(t).floatPlane(k), first, "t\(t)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.csv.path))

        // The embryo mask cannot be followed without a threshold YAML file.
        o.z.region = .embryoMask
        XCTAssertThrowsError(try ZCorrectPipeline.run(options: o, backend: CPUBackend(), context: .silent()))
        // Without extra slices the stack keeps its depth.
        o.z = wholeFrame
        o.enlargeStack = false
        XCTAssertEqual(try TIFFStack(url: try ZCorrectPipeline.run(options: o, backend: CPUBackend(), context: .silent()).tiff).z, Self.slices)
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
        var opts = AlignOptions(source: tif, yaml: yaml)
        opts.zCorrection = ZCorrectionOptions()
        opts.zCorrection?.region = .embryoMask
        let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        XCTAssertEqual(r.zPlans[0].shift, [0, 0, 3, 3, -2])
        let out = try TIFFStack(url: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy_z.ome.tif"))
        XCTAssertEqual(out.z, Self.slices + 5)
        XCTAssertEqual(out.t, offsets.count)
        // The corrected stack starts at the same stage z at every timepoint.
        let stage = try XCTUnwrap(out.metadata.stageZ)
        for z in stage { XCTAssertEqual(z, stage[0], accuracy: 1e-6) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy_z_shifts.csv").path))
        // Timepoint 2 moved up by 3 slices and 2 empty slices were added below, so its slices 0 to 4 are empty.
        let t2 = try out.readFrame(2)
        XCTAssertEqual(t2.floatPlane(4).max(), 0)
        XCTAssertGreaterThan(t2.floatPlane(5).max() ?? 0, 0)

        // Without z correction the output is unchanged in name and depth.
        opts.zCorrection = nil
        _ = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        XCTAssertEqual(try TIFFStack(url: tmp.appendingPathComponent("aligned_P0_concat/P0_concat_xy.ome.tif")).z, Self.slices)
    }
    func testDropComparesWithTheLastKeptTimepoint() throws {
        // One timepoint that jumps and comes back is dropped, and the timepoint after it is kept.
        var options = ZCorrectOptions(input: try writeMovie("spike.ome.tif", offsets: [0, 0, 4, 0, 1], stage: false))
        options.z = wholeFrame
        options.z.maximumStep = 2
        let spike = try ZCorrectPipeline.run(options: options, backend: CPUBackend(), context: .silent())
        XCTAssertEqual(spike.plan.kept, [0, 1, 3, 4])
        XCTAssertEqual(spike.plan.padLow + spike.plan.padHigh, 1)
        // A jump that stays drops only its first timepoint.
        options.input = try writeMovie("jump.ome.tif", offsets: [0, 0, 4, 4, 5], stage: false)
        let jump = try ZCorrectPipeline.run(options: options, backend: CPUBackend(), context: .silent())
        XCTAssertEqual(jump.plan.kept, [0, 1, 3, 4])
        XCTAssertEqual(jump.plan.padLow + jump.plan.padHigh, 5)
    }

    func testDropOutputKeepsOriginalTimesAndMetadata() throws {
        let tif = try writeMovie("drop.ome.tif", offsets: [0, 0, 3, 3, -2, -1], stage: true)
        var options = ZCorrectOptions(input: tif)
        options.z = wholeFrame
        options.z.maximumStep = 2
        for lowMemory in [false, true] {
            options.lowMemory = lowMemory
            let result = try ZCorrectPipeline.run(options: options, backend: CPUBackend(), context: .silent())
            XCTAssertEqual(result.plan.kept, [0, 1, 3, 5])
            // A dropped timepoint is listed with the shift of the last kept timepoint before it.
            XCTAssertEqual(result.plan.shift, [0, 0, 0, 3, 3, -1])
            let stack = try TIFFStack(url: result.tiff)
            XCTAssertEqual(stack.t, 4)
            XCTAssertEqual(stack.z, 18)
            let first = try stack.readFrame(0).floatPlane(result.plan.padLow + 6)
            for t in 1..<stack.t { XCTAssertEqual(try stack.readFrame(t).floatPlane(result.plan.padLow + 6), first) }
            let xml = try XCTUnwrap(stack.omeXML)
            XCTAssertTrue(xml.contains("DeltaT=\"720.0\""))
            XCTAssertTrue(xml.contains("DeltaT=\"1200.0\""))
            let csv = try String(contentsOf: result.csv, encoding: .utf8)
            XCTAssertTrue(csv.contains("output_t"))
            XCTAssertEqual(csv.components(separatedBy: "dropped (large shift)").count - 1, 2)
        }
    }

    func testAlignmentDropsTIFFAndMovieFramesTogether() throws {
        final class Writer: MovieWriter {
            var count = 0
            func append(gray: [UInt8]) throws { count += 1 }
            func finish() throws {}
            func cancel() {}
        }
        final class Factory: MovieWriterFactory {
            var writers: [Writer] = []
            func makeWriter(url: URL, width: Int, height: Int, fps: Double) throws -> MovieWriter {
                let writer = Writer(); writers.append(writer); return writer
            }
        }
        let tif = try writeMovie("P0_concat.ome.tif", offsets: [0, 0, 3, 3, -2, -1], stage: true)
        let yaml = tmp.appendingPathComponent("threshold.yaml")
        try """
        parameters:
          channel_index: 0
          sigma: 8
          percentile: 60.0
        source:
          file: \(tif.path)
        """.write(to: yaml, atomically: true, encoding: .utf8)
        for enlarge in [false, true] {
            var options = AlignOptions(source: tif, yaml: yaml)
            options.zCorrection = ZCorrectionOptions()
            options.zCorrection?.maximumStep = 2
            options.enlargeCanvas = enlarge
            let factory = Factory()
            let result = try AlignPipeline(options: options, backend: CPUBackend(), movies: factory, context: .silent()).run()
            XCTAssertEqual(result.zPlans[0].kept, [0, 1, 3, 5])
            XCTAssertEqual(try TIFFStack(url: result.tiffs[0]).t, 4)
            XCTAssertEqual(factory.writers.map { $0.count }, [4, 4])
        }
    }

    /// A threshold YAML file whose mask is the bright disc of the scene.
    func writeYAML(for tif: URL) throws -> URL {
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
        return yaml
    }

    func testXYMatchFindsLargeJumps() {
        let a = XYMatch.prepare(Image2D(width: Self.size, height: Self.size, pixels: frame(offset: 0).floatPlane(6)))
        for (dy, dx) in [(0, 0), (3, -2), (-17, 25), (38, -41)] {
            let b = XYMatch.prepare(Image2D(width: Self.size, height: Self.size, pixels: frame(offset: 0, dy: dy, dx: dx).floatPlane(6)))
            // A pure shift is found without a turn, also when angles are tried. The shift is placed between pixels,
            // so a move by whole pixels is found to within a small part of one.
            for maximumAngle in [0.0, 3.0] {
                let m = XYMatch.match(a, b, maximumAngle: maximumAngle)
                XCTAssertEqual(m.step.degrees, 0, "move \(dy), \(dx)")
                XCTAssertEqual(m.step.tx, Double(-dx), accuracy: 0.01, "move \(dy), \(dx)")
                XCTAssertEqual(m.step.ty, Double(-dy), accuracy: 0.01, "move \(dy), \(dx)")
                XCTAssertLessThan(m.cost, 0.1)
            }
        }
    }

    func testXYMatchFindsRotation() {
        let n = Self.size, mid = Double(n - 1) / 2
        let first = frame(offset: 0)
        let a = XYMatch.prepare(Image2D(width: n, height: n, pixels: first.floatPlane(6)))
        for (degrees, dx, dy) in [(2.0, 5.0, -4.0), (-1.5, -12.0, 9.0)] {
            // Turn and shift the scene, and check that the match undoes both.
            let move = Rigid.shift(dx: dx, dy: dy).after(Rigid.rotation(degrees: degrees, aboutX: mid, y: mid))
            let b = XYMatch.prepare(Image2D(width: n, height: n, pixels: Shift.warp(first, pad: .none, transform: move).floatPlane(6)))
            let m = XYMatch.match(a, b, maximumAngle: 3)
            XCTAssertEqual(m.step.degrees, -degrees, accuracy: 0.2)
            let round = m.step.after(move)
            for point in [(mid, mid), (mid + 50, mid), (mid, mid - 50)] {
                let q = round.apply(x: point.0, y: point.1)
                XCTAssertEqual(q.x, point.0, accuracy: 1.5, "\(degrees)")
                XCTAssertEqual(q.y, point.1, accuracy: 1.5, "\(degrees)")
            }
            XCTAssertLessThan(m.cost, 0.15)
        }
    }

    func testMaskMetrics() {
        let examples: [([(Int, Int)], Double, Double)] = [
            ([(0, 0), (0, 1), (0, 2), (1, 1), (4, 8)], 1, 0),
            ([(0, 0), (1, 1), (2, 4), (4, 8)], 2.5, 1.5)
        ]
        for (points, x, y) in examples {
            var mask = Mask2D(width: 9, height: 5)
            for (row, column) in points { mask.bits[row * mask.width + column] = true }
            let median = Anchor.pose(of: mask, metric: .median)!
            XCTAssertEqual(median.x, x)
            XCTAssertEqual(median.y, y)
            let centroid = Anchor.pose(of: mask)!
            XCTAssertEqual(centroid.x, Double(points.reduce(0) { $0 + $1.1 }) / Double(points.count))
            XCTAssertEqual(centroid.y, Double(points.reduce(0) { $0 + $1.0 }) / Double(points.count))
        }
        XCTAssertNil(Anchor.pose(of: Mask2D(width: 9, height: 5), metric: .median))
    }

    func testAnchorHoldsTheBody() {
        // The cells move through the body by 1 pixel and turn by half a degree at every step, and at timepoint 10
        // the stage jumps by 20 pixels. The body itself does not move or turn apart from that jump.
        let T = 30, w = 200, h = 100
        let mid = (x: Double(w - 1) / 2, y: Double(h - 1) / 2)
        var steps: [Rigid] = [], poses: [BodyPose?] = []
        for t in 0..<T {
            let jump = t >= 10 ? 20.0 : 0
            steps.append(Rigid.shift(dx: t == 10 ? -21 : -1, dy: 0).after(Rigid.rotation(degrees: 0.5, aboutX: 80 + jump, y: 40)))
            poses.append(BodyPose(x: 80 + jump, y: 40))
        }
        let held = Anchor.transforms(steps: steps, poses: poses, smoothing: 2, width: w, height: h)
        let free = Anchor.transforms(steps: steps, poses: nil, smoothing: 2, width: w, height: h)
        for t in 6..<24 {
            // With the anchor the body stays in the middle and keeps its direction.
            let q = held[t].apply(x: poses[t]!.x, y: poses[t]!.y)
            XCTAssertEqual(q.x, mid.x, accuracy: 0.5, "t\(t)")
            XCTAssertEqual(q.y, mid.y, accuracy: 0.5, "t\(t)")
            XCTAssertEqual(held[t].degrees, 0, accuracy: 0.2, "t\(t)")
        }
        // Without it the sum of the steps carries the body away.
        XCTAssertGreaterThan(abs(free[T - 1].apply(x: 100, y: 40).x - 100), 20)
        XCTAssertEqual(free[T - 1].degrees, 0.5 * Double(T - 1), accuracy: 1e-6)
    }

    func testPositionsUseComparisonsFurtherBack() {
        // The tissue sinks by a fifth of a slice at every step. Neighbours measure no movement, and the
        // comparison five timepoints back measures one slice.
        let T = 41
        var edges: [(i: Int, j: Int, d: Double)] = (1..<T).map { ($0 - 1, $0, 0.0) }
        XCTAssertEqual(ZDrift.positions(count: T, edges: edges)[T - 1], 0, accuracy: 1e-6)
        for t in 5..<T { edges.append((t - 5, t, -1.0)) }
        let z = ZDrift.positions(count: T, edges: edges)
        XCTAssertLessThan(z[T - 1], -0.15 * Double(T - 1))
        XCTAssertEqual(z[0], 0)
        // With only neighbours, the positions are the sum of the steps.
        let chain = ZDrift.positions(count: 4, edges: [(0, 1, 2.0), (1, 2, -0.5), (2, 3, 1.0)])
        for (a, b) in zip(chain, [0, 2, 1.5, 2.5]) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testAlignByImageMatching() throws {
        let moves = [(0, 0), (4, -3), (9, 2), (-12, 15), (-10, 14)]
        let tif = try writeMovie("P0_concat.ome.tif", offsets: [0, 0, 0, 0, 0], moves: moves, stage: false)
        let yaml = try writeYAML(for: tif)
        for region in [FollowRegion.wholeFrame, .embryoMask, .box(x: 40, y: 40, width: 80, height: 80)] {
            var opts = AlignOptions(source: tif, yaml: yaml)
            opts.xyMatching.region = region
            opts.xyMatching.holdInPlace = false
            let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
            // Every timepoint moves back onto the first one.
            for (t, m) in moves.enumerated() {
                XCTAssertEqual(r.shifts[0][t].dy, Double(-m.0), accuracy: 0.01, "t\(t) \(region)")
                XCTAssertEqual(r.shifts[0][t].dx, Double(-m.1), accuracy: 0.01, "t\(t) \(region)")
            }
            // In the output, every timepoint shows the scene in the same place, apart from the pixels that its move
            // uncovered. The output is interpolated, so the values agree closely without being equal.
            let out = try TIFFStack(url: r.tiffs[0])
            let first = try out.readFrame(0).floatPlane(6)
            for t in 1..<moves.count {
                let plane = try out.readFrame(t).floatPlane(6)
                var difference = 0.0, total = 0.0, compared = 0
                for i in plane.indices where plane[i] > 0 && first[i] > 0 {
                    compared += 1; difference += Double(abs(plane[i] - first[i])); total += Double(first[i])
                }
                XCTAssertGreaterThan(compared, 10_000, "t\(t) \(region)")
                XCTAssertLessThan(difference / total, 0.02, "t\(t) \(region)")
            }
        }
    }

    func testImageMatchingWithZCorrection() throws {
        let offsets = [0, 2, 2, -1]
        let moves = [(0, 0), (6, -5), (-8, 11), (-7, 12)]
        let tif = try writeMovie("P0_concat.ome.tif", offsets: offsets, moves: moves, stage: false)
        var opts = AlignOptions(source: tif, yaml: try writeYAML(for: tif))
        opts.xyMatching.holdInPlace = false
        opts.zCorrection = ZCorrectionOptions()
        let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        XCTAssertEqual(r.zPlans[0].shift, offsets)
        // The stacks start at different depths, so their projections differ slightly and the shift is found to within
        // a few hundredths of a pixel.
        for (t, m) in moves.enumerated() {
            XCTAssertEqual(r.shifts[0][t].dy, Double(-m.0), accuracy: 0.05)
            XCTAssertEqual(r.shifts[0][t].dx, Double(-m.1), accuracy: 0.05)
        }
        // After both corrections, a given output slice shows the same scene plane at every timepoint, apart from
        // the pixels that the xy move uncovered. The output is interpolated, so the values agree closely.
        let out = try TIFFStack(url: r.tiffs[0])
        let k = r.zPlans[0].padLow + 6
        let first = try out.readFrame(0).floatPlane(k)
        for t in 1..<offsets.count {
            let plane = try out.readFrame(t).floatPlane(k)
            var difference = 0.0, total = 0.0, compared = 0
            for i in plane.indices where plane[i] > 0 && first[i] > 0 {
                compared += 1; difference += Double(abs(plane[i] - first[i])); total += Double(first[i])
            }
            XCTAssertGreaterThan(compared, 10_000, "t\(t)")
            XCTAssertLessThan(difference / total, 0.02, "t\(t)")
        }
    }

    func testImageMatchingHoldsTheBodyInTheMiddle() throws {
        // The scene and its mask move together, so holding the body must put the scene in the same place at every
        // timepoint, with the centre of the bright disc in the middle of the frame.
        let moves = [(0, 0), (4, -3), (9, 2), (-12, 15), (-10, 14), (3, 3)]
        let tif = try writeMovie("P0_concat.ome.tif", offsets: [0, 0, 0, 0, 0, 0], moves: moves, stage: false)
        var opts = AlignOptions(source: tif, yaml: try writeYAML(for: tif))
        let r = try AlignPipeline(options: opts, backend: CPUBackend(), movies: nil, context: .silent()).run()
        let out = try TIFFStack(url: r.tiffs[0])
        let first = try out.readFrame(0).floatPlane(6)
        for t in 1..<moves.count {
            let plane = try out.readFrame(t).floatPlane(6)
            var difference = 0.0, total = 0.0
            for i in plane.indices where plane[i] > 0 && first[i] > 0 { difference += Double(abs(plane[i] - first[i])); total += Double(first[i]) }
            XCTAssertLessThan(difference / total, 0.05, "t\(t)")
        }
        // The disc is centred in the scene, and the output canvas grows evenly enough that it stays near the middle.
        let width = out.x, height = out.y
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<height { for x in 0..<width where first[y * width + x] > 400 { sx += Double(x); sy += Double(y); n += 1 } }
        let pad = Padding.covering(transforms: r.transforms[0], width: Self.size, height: Self.size)
        XCTAssertEqual(sx / n - Double(pad.left), Double(Self.size - 1) / 2, accuracy: 3)
        XCTAssertEqual(sy / n - Double(pad.top), Double(Self.size - 1) / 2, accuracy: 3)
    }

    /// A movie writer that keeps the frames in memory.
    final class RecordedMovie: MovieWriter {
        var frames: [[UInt8]] = []
        var finished = false
        func append(gray: [UInt8]) throws { frames.append(gray) }
        func finish() throws { finished = true }
        func cancel() {}
    }

    final class Recorder: MovieWriterFactory {
        var movies: [(url: URL, width: Int, height: Int, movie: RecordedMovie)] = []
        func makeWriter(url: URL, width: Int, height: Int, fps: Double) throws -> MovieWriter {
            let m = RecordedMovie(); movies.append((url, width, height, m)); return m
        }
    }

    func testExportShowsSliceAndComparesSideBySide() throws {
        let still = try writeMovie("still.ome.tif", offsets: [0, 0, 0, 0], stage: false)
        let moved = try writeMovie("moved.ome.tif", offsets: [0, 1, 2], stage: false)
        let n = Self.size

        // A movie of one slice with the brightness of each frame matches the slice scaled on its own.
        var o = ExportOptions(source: moved)
        o.slice = 7
        o.wholeMovieContrast = false
        var recorder = Recorder()
        _ = try ExportPipeline.run(options: o, backend: CPUBackend(), movies: recorder, context: .silent())
        XCTAssertEqual(recorder.movies.map { $0.url.lastPathComponent }, ["moved_nuc_z7.mp4"])
        let source = try TIFFSource(url: moved)
        for t in 0..<3 {
            let plane = try source.readFrame(t: t, p: 0).floatPlane(6)
            XCTAssertEqual(recorder.movies[0].movie.frames[t], Contrast.autoContrast(plane), "t\(t)")
        }

        // With the brightness of the whole movie, a scene that does not change gives the same frame every time.
        o = ExportOptions(source: still)
        recorder = Recorder()
        _ = try ExportPipeline.run(options: o, backend: CPUBackend(), movies: recorder, context: .silent())
        let frames = recorder.movies[0].movie.frames
        XCTAssertEqual(frames.count, 4)
        for f in frames { XCTAssertEqual(f, frames[0]) }
        XCTAssertTrue(recorder.movies[0].movie.finished)

        // The second movie sits to the right, and the export stops after the shorter movie.
        o.compare = moved
        recorder = Recorder()
        _ = try ExportPipeline.run(options: o, backend: CPUBackend(), movies: recorder, context: .silent())
        let side = recorder.movies[0]
        XCTAssertEqual(side.url.lastPathComponent, "still_nuc_max_vs_moved.mp4")
        XCTAssertEqual(side.width, 2 * n)
        XCTAssertEqual(side.height, n)
        XCTAssertEqual(side.movie.frames.count, 3)
        // Timepoint 0 of both movies is the same stack. With the brightness of each frame, the two halves of the first
        // frame are equal. With the brightness of the whole movie, each side takes its own.
        o.wholeMovieContrast = false
        recorder = Recorder()
        _ = try ExportPipeline.run(options: o, backend: CPUBackend(), movies: recorder, context: .silent())
        let first = recorder.movies[0].movie.frames[0]
        for y in 0..<n { XCTAssertEqual(first[(y * 2 * n)..<(y * 2 * n + n)], first[(y * 2 * n + n)..<(y * 2 * n + 2 * n)]) }

        // A slice outside the stack is refused.
        o.slice = Self.slices + 1
        XCTAssertThrowsError(try ExportPipeline.run(options: o, backend: CPUBackend(), movies: Recorder(), context: .silent()))
    }
}
