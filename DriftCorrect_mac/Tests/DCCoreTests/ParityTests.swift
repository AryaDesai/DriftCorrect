import Foundation
import XCTest
@testable import DCCore

/// Swift CPU implementations against outputs of the original Python code.
final class ParityTests: XCTestCase {

    func testGaussianBitExact() {
        for c in Ref.cases("gaussian") {
            let img = Ref.image(c["input"])
            let out = Gaussian.filter(img, sigma: Ref.num(c["sigma"]))
            XCTAssertTrue(bitsEqual(out.pixels, Ref.floats(c["expected"])), "sigma \(Ref.num(c["sigma"])) size \(img.width)x\(img.height)")
        }
    }

    func testPercentileBitExact() {
        for c in Ref.cases("percentile") {
            let a = Ref.floats(c["input"])
            let qs = (c["q"] as! [NSNumber]).map { $0.doubleValue }
            let expected = (c["expected"] as! [NSNumber]).map { $0.floatValue }
            for (q, e) in zip(qs, expected) {
                XCTAssertEqual(Stats.percentile(a, q).bitPattern, e.bitPattern, "n=\(a.count) q=\(q)")
            }
            let many = Stats.percentiles(a, qs)
            for (m, e) in zip(many, expected) { XCTAssertEqual(m.bitPattern, e.bitPattern) }
        }
    }

    func testHistogram() {
        for c in Ref.cases("histogram") {
            let (counts, edges) = Stats.histogram64(Ref.floats(c["input"]), bins: Ref.int(c["bins"]))
            XCTAssertEqual(counts, (c["counts"] as! [NSNumber]).map { $0.intValue })
            XCTAssertEqual(edges, (c["edges"] as! [NSNumber]).map { $0.doubleValue })
        }
    }

    func testLabelOrder() {
        for c in Ref.cases("label") {
            let s = Ref.shape(c["mask"])
            let mask = Mask2D(width: s[1], height: s[0], bits: Ref.bools(c["mask"]))
            let comps = Labeling.label(mask, eightConnected: c["eight"] as! Bool)
            var labels = [Int32](repeating: 0, count: mask.bits.count)
            for r in 0..<comps.runLabel.count {
                let base = Int(comps.runRow[r]) * mask.width
                for x in Int(comps.runStart[r])..<Int(comps.runEnd[r]) { labels[base + x] = comps.runLabel[r] }
            }
            XCTAssertEqual(labels, Ref.load(c["labels"], as: Int32.self))
            XCTAssertEqual(comps.count, Ref.int(c["count"]))
        }
    }

    func testCV2Otsu() {
        for c in Ref.cases("otsu") {
            let u = Ref.load(c["input"], as: UInt8.self)
            var h = [Int](repeating: 0, count: 256)
            for v in u { h[Int(v)] += 1 }
            XCTAssertEqual(Otsu.cv2Threshold(histogram: h, total: u.count), Ref.int(c["threshold"]))
        }
    }

    /// The Python code solves the multi-Otsu program in float32 (JAX); this port uses float64.
    /// Where float32 cannot tell two partitions apart, the results can differ. The test then
    /// requires the Swift partition to be at least as good as the Python one.
    func testMultiOtsu() {
        var nearTies = 0
        for c in Ref.cases("multiotsu") {
            let img = Ref.image(c["input"])
            let levels = Ref.int(c["levels"])
            let r = MultiOtsu.thresholdsAndClasses(img, levels: levels)
            let py = (c["thresholds"] as! [NSNumber]).map { $0.doubleValue }
            if r.thresholds == py {
                XCTAssertEqual(r.classes, Ref.load(c["classes"], as: Int32.self))
                continue
            }
            nearTies += 1
            let (counts, edges) = Stats.histogram64(img.pixels, bins: MultiOtsu.defaultBins)
            func bins(_ t: [Double]) -> [Int] { t.map { v in edges.firstIndex(of: v)! } }
            XCTAssertEqual(r.thresholds.count, py.count, "levels \(levels)")
            let swiftScore = MultiOtsu.partitionScore(histogram: counts, breaks: bins(r.thresholds))
            let pyScore = MultiOtsu.partitionScore(histogram: counts, breaks: bins(py))
            XCTAssertGreaterThanOrEqual(swiftScore, pyScore * (1 - 1e-12), "levels \(levels): \(r.thresholds) vs \(py)")
            XCTAssertLessThan(abs(swiftScore - pyScore) / pyScore, 1e-6, "not a near tie: \(r.thresholds) vs \(py)")
        }
        print("multi-Otsu: \(nearTies) near-tie case(s) where float64 found a partition at least as good as JAX float32")
    }

    func testFindLargestMask() throws {
        for c in Ref.cases("mask") {
            let img = Ref.image(c["input"])
            let selected = (c["selected_levels"] as? [NSNumber])?.map { $0.intValue }
            let r = try Masking.findLargestMask(img, percentile: Ref.num(c["percentile"]), method: c["method"] as! String,
                                                invert: c["invert"] as! Bool, levels: Ref.int(c["levels"]),
                                                selectedLevels: selected)
            let label = "\(c["method"]!) invert=\(c["invert"]!) sel=\(String(describing: selected))"
            if let py = c["multiotsu_thresholds"] as? [NSNumber] {
                // Compare only where both implementations chose the same classes (see testMultiOtsu).
                let swift = MultiOtsu.thresholdsAndClasses(img, levels: Ref.int(c["levels"])).thresholds
                if swift != py.map({ $0.doubleValue }) { continue }
            }
            XCTAssertEqual(r.mask.bits, Ref.bools(c["mask"]), label)
            let cen = (c["centroid"] as! [NSNumber]).map { $0.doubleValue }
            XCTAssertEqual(r.centroid.y, cen[0], label)
            XCTAssertEqual(r.centroid.x, cen[1], label)
        }
    }

    func testComputeShift() throws {
        for c in Ref.cases("compute_shift") {
            let frame = Ref.volume(c["frame"])
            let p = c["params"] as! [String: Any]
            let params = ThresholdParams(channelIndex: 0, sigma: Ref.num(p["sigma"]), percentile: Ref.num(p["percentile"]),
                                         method: p["method"] as? String ?? "percentile", blockSize: 32,
                                         levels: (p["levels"] as? NSNumber)?.intValue ?? 3,
                                         selectedLevels: (p["selected_levels"] as? [NSNumber])?.map { $0.intValue })
            let r = try Detection.computeShift(frame: frame, params: params, backend: CPUBackend())
            XCTAssertEqual(r.dy, Ref.num(c["dy"]))
            XCTAssertEqual(r.dx, Ref.num(c["dx"]))
        }
    }

    func testShiftBitExact() {
        for c in Ref.cases("shift") {
            let frame = Ref.volume(c["frame"])
            let pad = (c["pad"] as! [NSNumber]).map { $0.intValue }
            let padding = Padding(top: pad[0], bottom: pad[1], left: pad[2], right: pad[3])
            let dy = Ref.num(c["dy"]), dx = Ref.num(c["dx"])
            let sub = Shift.apply(frame, pad: padding, dy: dy, dx: dx, mode: .subpixel)
            XCTAssertEqual(Ref.uint16s(sub), Ref.load(c["subpixel"], as: UInt16.self), "subpixel \(dy) \(dx)")
            let whole = Shift.apply(frame, pad: padding, dy: dy, dx: dx, mode: .integer)
            XCTAssertEqual(Ref.uint16s(whole), Ref.load(c["integer"], as: UInt16.self), "integer \(dy) \(dx)")
        }
    }

    func testAutoContrast() {
        for c in Ref.cases("auto_contrast") {
            XCTAssertEqual(Contrast.autoContrast(Ref.floats(c["input"])), Ref.load(c["expected"], as: UInt8.self))
        }
    }

    func testYAMLWriterMatchesPyYAML() throws {
        let expected = Ref.dict("yaml")["text"] as! String
        let multi = ThresholdParams(channel: "Venus", channelIndex: 0, sigma: 3, percentile: 92.5, method: "multiotsu",
                                    invert: false, levels: 4, selectedLevels: [2, 3])
        let pct = ThresholdParams(channel: "Venus", channelIndex: 0, sigma: 2, percentile: 90, method: "percentile", invert: true)
        let d = ThresholdYAML.Diagnostics(timePoint: 1, savedAt: "2026-09-26T10:11:12", embryoID: 0, maskAreaPx: 12345,
                                          maskAreaPct: 4.71, meanIntensity: 812.35, centroidXY: (240.12, 250.5))
        let doc = ThresholdYAML.document(parameters: multi, perTimepoint: [multi, pct, multi],
                                         sourceFile: "/Users/me/data run/P0_concat.ome.tif", t: 3, p: 1, y: 512, x: 480,
                                         diagnostics: d)
        XCTAssertEqual(YAMLWriter.dump(doc), expected)

        // Files written by find_threshold.py contain anchors; the reader must follow them.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anchored_\(UUID().uuidString).yaml")
        try (Ref.dict("yaml")["anchored_text"] as! String).write(to: url, atomically: true, encoding: .utf8)
        let cfg = try ThresholdConfig.load(url)
        XCTAssertEqual(cfg.timepointParameters?.count, 3)
        XCTAssertEqual(try cfg.params(forTimepoint: 2).selectedLevels, [2, 3])
        XCTAssertEqual(try cfg.params(forTimepoint: 1).method, "percentile")
        XCTAssertEqual(try cfg.params(forTimepoint: 1).blockSize, 64)
        XCTAssertTrue(try cfg.params(forTimepoint: 1).invert)
    }
}
