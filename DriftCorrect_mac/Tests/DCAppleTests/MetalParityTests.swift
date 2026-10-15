#if canImport(Metal)
import AVFoundation
import Foundation
import XCTest
import DCCore
@testable import DCApple

/// Metal kernels against the exact CPU reference (which DCCoreTests checks against Python).
final class MetalParityTests: XCTestCase {
    var gpu: MetalBackend!
    let cpu = CPUBackend()

    override func setUpWithError() throws {
        guard let g = MetalBackend() else { throw XCTSkip("No Metal device") }
        gpu = g
    }

    func randomImage(_ w: Int, _ h: Int, seed: UInt64) -> Image2D {
        var state = seed
        var img = Image2D(width: w, height: h)
        for i in 0..<(w * h) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(state >> 40) / Float(1 << 24) * 80
            let y = Float(i / w), x = Float(i % w)
            let d = ((y - Float(h) * 0.45) * (y - Float(h) * 0.45) + (x - Float(w) * 0.55) * (x - Float(w) * 0.55)) / Float(2 * (w / 6) * (w / 6))
            img.pixels[i] = (200 + 3000 * exp(-d) + noise).rounded()
        }
        return img
    }

    func testGaussianMatchesCPU() throws {
        for (w, h, sigma) in [(17, 20, 1.0), (64, 72, 2.5), (31, 33, 15.0), (512, 480, 30.0), (1024, 1024, 12.0)] {
            let img = randomImage(w, h, seed: UInt64(w * 31 + h))
            let a = try gpu.gaussian(img, sigma: sigma)
            let b = try cpu.gaussian(img, sigma: sigma)
            var mismatches = 0, maxULP: Int64 = 0
            for (x, y) in zip(a.pixels, b.pixels) where x.bitPattern != y.bitPattern {
                mismatches += 1
                maxULP = max(maxULP, abs(Int64(x.bitPattern) - Int64(y.bitPattern)))
            }
            // Float-float emulation of float64: at most 1 ulp, on a tiny fraction of pixels.
            XCTAssertLessThanOrEqual(maxULP, 1, "\(w)x\(h) sigma \(sigma)")
            XCTAssertLessThanOrEqual(Double(mismatches), Double(w * h) * 1e-4, "\(w)x\(h) sigma \(sigma): \(mismatches) mismatches")
            print("Gaussian \(w)x\(h) sigma \(sigma): \(mismatches) pixels differ by 1 ulp")
        }
    }

    func volume(c: Int, z: Int, y: Int, x: Int, type: SampleType, seed: UInt64) -> Volume {
        let v = Volume(c: c, z: z, y: y, x: x, type: type)
        var state = seed
        for i in 0..<v.elementCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Int(state >> 48)
            switch type {
            case .uint16: v.storage.raw.assumingMemoryBound(to: UInt16.self)[i] = UInt16(r)
            case .uint8: v.storage.raw.assumingMemoryBound(to: UInt8.self)[i] = UInt8(r & 0xFF)
            case .float32: v.storage.raw.assumingMemoryBound(to: Float.self)[i] = Float(r)
            }
        }
        return v
    }

    func testShiftBitExact() throws {
        for type in [SampleType.uint16, .float32, .uint8] {
            let frame = volume(c: 2, z: 3, y: 101, x: 87, type: type, seed: 7)
            for (dy, dx, pad) in [(2.3, -1.7, Padding.none), (13.370158730158735, -7.654321098765432, Padding(top: 0, bottom: 14, left: 8, right: 0)),
                                  (-0.5, 0.25, Padding(top: 3, bottom: 3, left: 3, right: 3)), (2.5, -3.5, Padding.none)] {
                for mode in ShiftMode.allCases {
                    let a = try gpu.shift(frame, pad: pad, dy: dy, dx: dx, mode: mode)
                    let b = try cpu.shift(frame, pad: pad, dy: dy, dx: dx, mode: mode)
                    let pa = UnsafeBufferPointer(start: a.storage.raw.assumingMemoryBound(to: UInt16.self), count: a.elementCount)
                    let pb = UnsafeBufferPointer(start: b.storage.raw.assumingMemoryBound(to: UInt16.self), count: b.elementCount)
                    XCTAssertTrue(pa.elementsEqual(pb), "\(type) \(mode) dy=\(dy) dx=\(dx)")
                }
            }
        }
    }

    func testProjectionExact() throws {
        for type in [SampleType.uint16, .float32, .uint8] {
            let frame = volume(c: 3, z: 5, y: 40, x: 50, type: type, seed: 11)
            let a = try gpu.maxProjectAll(frame), b = try cpu.maxProjectAll(frame)
            XCTAssertEqual(a, b)
            XCTAssertEqual(try gpu.maxProjectZ(frame, channel: 1), try cpu.maxProjectZ(frame, channel: 1))
        }
    }

    func testDetectionAgrees() throws {
        let frame = volume(c: 2, z: 4, y: 256, x: 240, type: .uint16, seed: 3)
        // Put a bright object on channel 0 so the mask is meaningful.
        let p = frame.storage.raw.assumingMemoryBound(to: UInt16.self)
        for z in 0..<4 { for y in 100..<150 { for x in 60..<120 { p[(z * 256 + y) * 240 + x] = 65000 } } }
        let params = ThresholdParams(channelIndex: 0, sigma: 6, percentile: 90)
        let a = try Detection.computeShift(frame: frame, params: params, backend: gpu)
        let b = try Detection.computeShift(frame: frame, params: params, backend: cpu)
        XCTAssertEqual(a.dy, b.dy, accuracy: 1e-9)
        XCTAssertEqual(a.dx, b.dx, accuracy: 1e-9)
    }

    func testHEVCWriterProducesMovie() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dc_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h) = (257, 191)  // odd sizes: padded to even
        let writer = try HEVCMovieWriter(url: url, width: w, height: h, fps: 2)
        for t in 0..<6 {
            var frame = [UInt8](repeating: 0, count: w * h)
            for i in 0..<frame.count { frame[i] = UInt8((i + t * 13) % 256) }
            try writer.append(gray: frame)
        }
        try writer.finish()
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.naturalSize, CGSize(width: 258, height: 192))
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 3.0, accuracy: 0.01)
    }
}
#endif
