import Foundation

/// Connected components with the numbering of `scipy.ndimage.label`.
///
/// Labels are assigned in raster order of each component's first pixel,
/// which is scipy's order. `largest` breaks size ties toward the lowest
/// label, as `np.bincount(...).argmax()` does. The work is run-length based.
public struct Components {
    public let width: Int
    public let height: Int
    /// Runs in raster order: row, first column, one past the last column.
    public let runRow: [Int32]
    public let runStart: [Int32]
    public let runEnd: [Int32]
    /// 1-based label of each run.
    public let runLabel: [Int32]
    /// sizes[label] = pixel count; sizes[0] = 0.
    public let sizes: [Int]

    public var count: Int { sizes.count - 1 }

    /// Label of the largest component, or nil when there is no foreground.
    public var largest: Int? {
        var best = 0, bestSize = 0
        for l in 1..<max(1, sizes.count) where sizes[l] > bestSize { best = l; bestSize = sizes[l] }
        return bestSize > 0 ? best : nil
    }

    public func mask(of label: Int) -> Mask2D {
        var bits = [Bool](repeating: false, count: width * height)
        for r in 0..<runLabel.count where Int(runLabel[r]) == label {
            let base = Int(runRow[r]) * width
            for x in Int(runStart[r])..<Int(runEnd[r]) { bits[base + x] = true }
        }
        return Mask2D(width: width, height: height, bits: bits)
    }

    /// Mean (row, column) of the component's pixels (`np.argwhere(mask).mean(axis=0)`).
    public func centroid(of label: Int) -> (y: Double, x: Double) {
        var sy: Int64 = 0, sx: Int64 = 0, n: Int64 = 0
        for r in 0..<runLabel.count where Int(runLabel[r]) == label {
            let len = Int64(runEnd[r] - runStart[r])
            sy += Int64(runRow[r]) * len
            sx += (Int64(runStart[r]) + Int64(runEnd[r]) - 1) * len / 2
            n += len
        }
        return (Double(sy) / Double(n), Double(sx) / Double(n))
    }

    /// Visit every pixel index of a component.
    public func forEachPixel(of label: Int, _ body: (Int) -> Void) {
        for r in 0..<runLabel.count where Int(runLabel[r]) == label {
            let base = Int(runRow[r]) * width
            for x in Int(runStart[r])..<Int(runEnd[r]) { body(base + x) }
        }
    }
}

public enum Labeling {
    /// Label a binary mask. `eightConnected` = `structure=np.ones((3, 3))`;
    /// otherwise the default cross structure (4-connectivity).
    public static func label(_ mask: Mask2D, eightConnected: Bool) -> Components {
        let w = mask.width, h = mask.height
        var runRow = [Int32](), runStart = [Int32](), runEnd = [Int32]()
        var rowFirstRun = [Int](repeating: 0, count: h + 1)
        mask.bits.withUnsafeBufferPointer { b in
            for y in 0..<h {
                rowFirstRun[y] = runRow.count
                var x = 0
                let base = y * w
                while x < w {
                    if b[base + x] {
                        let s = x
                        while x < w && b[base + x] { x += 1 }
                        runRow.append(Int32(y)); runStart.append(Int32(s)); runEnd.append(Int32(x))
                    } else {
                        x += 1
                    }
                }
            }
        }
        rowFirstRun[h] = runRow.count
        let n = runRow.count
        var parent = [Int32](repeating: 0, count: n)
        for i in 0..<n { parent[i] = Int32(i) }

        func find(_ i: Int) -> Int {
            var r = i
            while Int(parent[r]) != r { r = Int(parent[r]) }
            var c = i
            while Int(parent[c]) != r { let next = Int(parent[c]); parent[c] = Int32(r); c = next }
            return r
        }

        let reach: Int32 = eightConnected ? 1 : 0
        if h > 1 {
            for y in 1..<h {
                var j = rowFirstRun[y - 1]
                let jEnd = rowFirstRun[y]
                for i in rowFirstRun[y]..<rowFirstRun[y + 1] {
                    let s = runStart[i] - reach, e = runEnd[i] + reach
                    // Skip previous-row runs that end before this run's reach.
                    while j < jEnd && runEnd[j] <= s { j += 1 }
                    var k = j
                    while k < jEnd && runStart[k] < e {
                        let a = find(i), b = find(k)
                        if a != b { if a < b { parent[b] = Int32(a) } else { parent[a] = Int32(b) } }
                        k += 1
                    }
                }
            }
        }

        // Roots are the earliest run of each component, so numbering roots in
        // run order is numbering by first pixel in raster order.
        var labelOfRoot = [Int32](repeating: 0, count: n)
        var runLabel = [Int32](repeating: 0, count: n)
        var sizes = [0]
        for i in 0..<n {
            let r = find(i)
            if labelOfRoot[r] == 0 {
                sizes.append(0)
                labelOfRoot[r] = Int32(sizes.count - 1)
            }
            let l = labelOfRoot[r]
            runLabel[i] = l
            sizes[Int(l)] += Int(runEnd[i] - runStart[i])
        }
        return Components(width: w, height: h, runRow: runRow, runStart: runStart, runEnd: runEnd,
                          runLabel: runLabel, sizes: sizes)
    }
}
