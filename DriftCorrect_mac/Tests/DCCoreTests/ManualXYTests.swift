import Foundation
import XCTest
@testable import DCCore

final class ManualXYTests: XCTestCase {
    private func row(_ t: Int, dy: Double, dx: Double) -> ManualRow {
        ManualRow(t1: t - 1, t2: t, p1: (dy, dx), p2: (0, 0))
    }

    func testForwardCorrectionsAndRemoval() throws {
        // Deliberately entered out of chronological order.
        var o = ManualXYOptions(rows: [row(5, dy: -1, dx: 4), row(2, dy: 3, dx: -2)])
        o.propagateForward = true
        var s = try ManualXYPipeline.resolvedShifts(timepoints: 8, options: o)
        XCTAssertEqual(s.map { $0.dy }, [0, 0, 3, 3, 3, 2, 2, 2])
        XCTAssertEqual(s.map { $0.dx }, [0, 0, -2, -2, -2, 2, 2, 2])
        // Removing an earlier boundary updates all later cumulative offsets.
        o.rows.removeLast()
        s = try ManualXYPipeline.resolvedShifts(timepoints: 8, options: o)
        XCTAssertEqual(s.map { $0.dy }, [0, 0, 0, 0, 0, -1, -1, -1])
        XCTAssertEqual(s.map { $0.dx }, [0, 0, 0, 0, 0, 4, 4, 4])
    }

    func testLegacyRowsRemainPerTarget() throws {
        let o = ManualXYOptions(rows: [row(2, dy: 3, dx: -2), row(5, dy: -1, dx: 4)])
        let s = try ManualXYPipeline.resolvedShifts(timepoints: 8, options: o)
        XCTAssertEqual(s.map { $0.dy }, [0, 0, 3, 0, 0, -1, 0, 0])
        XCTAssertEqual(s.map { $0.dx }, [0, 0, -2, 0, 0, 4, 0, 0])
    }

    func testInvalidBoundaries() {
        var o = ManualXYOptions(rows: [row(0, dy: 1, dx: 2)])
        o.propagateForward = true
        XCTAssertThrowsError(try ManualXYPipeline.resolvedShifts(timepoints: 4, options: o))
        o.rows = [ManualRow(t1: 0, t2: 2, p1: (1, 2), p2: (0, 0))]
        XCTAssertThrowsError(try ManualXYPipeline.resolvedShifts(timepoints: 4, options: o))
        o.rows = [row(2, dy: 1, dx: 2), row(2, dy: 3, dx: 4)]
        XCTAssertThrowsError(try ManualXYPipeline.resolvedShifts(timepoints: 4, options: o))
        o.rows = [row(1, dy: .nan, dx: 0)]
        XCTAssertThrowsError(try ManualXYPipeline.resolvedShifts(timepoints: 4, options: o))
    }

    func testExportPropagatesAcrossChannelsAndSlicesWithoutRepeatedResampling() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = tmp.appendingPathComponent("manual.ome.tif")
        let meta = ImageMetadata.standard(channelNames: ["A", "B"], voxel: VoxelSize(x: 1, y: 1, z: 2), period: 10)
        let writer = try OMETIFFWriter(url: input, t: 4, c: 2, z: 2, y: 5, x: 6, type: .uint16, metadata: meta)
        for _ in 0..<4 {
            let v = Volume(c: 2, z: 2, y: 5, x: 6, type: .uint16, zeroed: true)
            for plane in 0..<4 {
                v.planePointer(plane).assumingMemoryBound(to: UInt16.self)[2 * 6 + 2] = UInt16(100 * (plane + 1))
            }
            try writer.writeVolume(v)
        }
        try writer.finish()
        var o = ManualXYOptions(rows: [row(1, dy: 0, dx: 0.5), row(2, dy: 0, dx: 0.5)])
        o.propagateForward = true
        let output = try ManualXYPipeline.run(tif: input, options: o, backend: CPUBackend(), movies: nil, context: .silent())
        let stack = try TIFFStack(url: output)
        XCTAssertEqual([stack.t, stack.c, stack.z, stack.y, stack.x], [4, 2, 2, 5, 7])
        XCTAssertEqual(stack.metadata.channelNames, ["A", "B"])
        for t in 0..<4 {
            let v = try stack.readFrame(t)
            for plane in 0..<4 {
                let amplitude = Float(100 * (plane + 1))
                var expected = [Float](repeating: 0, count: 5 * 7)
                if t == 0 { expected[2 * 7 + 2] = amplitude }
                else if t == 1 {
                    expected[2 * 7 + 2] = amplitude / 2
                    expected[2 * 7 + 3] = amplitude / 2
                } else {
                    // Two half-pixel boundary increments produce a single whole-pixel
                    // resampling, not a blurred impulse from sequential resampling.
                    expected[2 * 7 + 3] = amplitude
                }
                XCTAssertEqual(v.floatPlane(plane), expected, "T=\(t), plane=\(plane)")
            }
        }
    }
}
