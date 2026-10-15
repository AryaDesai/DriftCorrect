import Foundation

/// Threshold settings for one timepoint (one entry of `timepoint_parameters`).
public struct ThresholdParams: Equatable, Sendable {
    public var channel: String
    public var channelIndex: Int
    public var sigma: Double
    public var percentile: Double
    /// "percentile", "multiotsu", "global_otsu", "percentile_otsu_roi",
    /// "local_otsu_interp" or "local_otsu_pixel". Unknown values act as "percentile".
    public var method: String
    public var blockSize: Int
    public var invert: Bool
    public var levels: Int
    /// nil selects the brightest class only.
    public var selectedLevels: [Int]?

    public init(channel: String = "", channelIndex: Int = 0, sigma: Double = 2, percentile: Double = 90,
                method: String = "percentile", blockSize: Int = 64, invert: Bool = false,
                levels: Int = 3, selectedLevels: [Int]? = nil) {
        self.channel = channel
        self.channelIndex = channelIndex
        self.sigma = sigma
        self.percentile = percentile
        self.method = method
        self.blockSize = blockSize
        self.invert = invert
        self.levels = levels
        self.selectedLevels = selectedLevels
    }
}

public struct MaskResult: Sendable {
    public var mask: Mask2D
    /// (row, column) centroid; the frame centre when the mask is empty.
    public var centroid: (y: Double, x: Double)
}

public enum Masking {
    /// `find_largest_mask_xy(smoothed, percentile, method, block_size, invert, levels, selected_levels, class_map)`.
    public static func findLargestMask(_ smoothed: Image2D, percentile: Double, method: String = "percentile",
                                       blockSize: Int = 32, invert: Bool = false, levels: Int = 3,
                                       selectedLevels: [Int]? = nil, classMap: [Int32]? = nil) throws -> MaskResult {
        var binary: Mask2D
        switch method {
        case "multiotsu":
            let selected = selectedLevels ?? [min(max(levels, 2), MultiOtsu.maxLevels) - 1]
            if selected.isEmpty {
                binary = Mask2D(width: smoothed.width, height: smoothed.height)
            } else {
                let map = classMap ?? MultiOtsu.thresholdsAndClasses(smoothed, levels: levels).classes
                let set = Set(selected.map(Int32.init))
                binary = Mask2D(width: smoothed.width, height: smoothed.height, bits: map.map { set.contains($0) })
            }
        case "global_otsu":
            binary = Otsu.globalMask(smoothed)
        case "percentile_otsu_roi":
            binary = Otsu.percentileOtsuROIMask(smoothed, percentile)
        case "local_otsu_interp":
            binary = try LocalOtsu.mask(smoothed, percentile: percentile, blockSize: blockSize, interpolate: true)
        case "local_otsu_pixel":
            binary = try LocalOtsu.mask(smoothed, percentile: percentile, blockSize: blockSize, interpolate: false)
        default:
            binary = Otsu.percentileMask(smoothed, percentile).mask
        }
        if invert { binary.bits = binary.bits.map { !$0 } }
        return largestComponent(binary)
    }

    /// Largest 8-connected component and its centroid.
    public static func largestComponent(_ binary: Mask2D) -> MaskResult {
        let comps = Labeling.label(binary, eightConnected: true)
        guard let l = comps.largest else {
            return MaskResult(mask: Mask2D(width: binary.width, height: binary.height),
                              centroid: (Double(binary.height) / 2, Double(binary.width) / 2))
        }
        return MaskResult(mask: comps.mask(of: l), centroid: comps.centroid(of: l))
    }

    /// Centroid only (skips building the mask image).
    public static func largestCentroid(_ binary: Mask2D) -> (y: Double, x: Double) {
        let comps = Labeling.label(binary, eightConnected: true)
        guard let l = comps.largest else { return (Double(binary.height) / 2, Double(binary.width) / 2) }
        return comps.centroid(of: l)
    }

    /// `dy = Y / 2 - cy`, `dx = X / 2 - cx`.
    public static func shift(toCenter centroid: (y: Double, x: Double), height: Int, width: Int) -> (dy: Double, dx: Double) {
        (Double(height) / 2 - centroid.y, Double(width) / 2 - centroid.x)
    }

    /// The log line `compute_shift_xy` prints: `dy=%+7.2f  dx=%+7.2f`.
    public static func shiftLine(_ dy: Double, _ dx: Double) -> String {
        PyFormat.fmt("dy=%+7.2f  dx=%+7.2f", dy, dx)
    }
}
