import Foundation

/// A threshold YAML written by the Mask tool (`find_threshold.py` schema).
public struct ThresholdConfig {
    public var parameters: ThresholdParams
    /// Materialized per-timepoint list; nil in older YAML files.
    public var timepointParameters: [ThresholdParams]?
    public var sourceFile: String
    public var raw: [String: Any]

    public static func load(_ url: URL) throws -> ThresholdConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let doc = YAMLReader.dict(try YAMLReader.load(text)) else {
            throw DCError("\(url.lastPathComponent) is not a threshold YAML mapping")
        }
        guard let p = YAMLReader.dict(doc["parameters"]) else { throw DCError("YAML has no 'parameters' block") }
        let params = try parse(p)
        var perT: [ThresholdParams]?
        if let list = YAMLReader.array(doc["timepoint_parameters"]) {
            perT = try list.map { item in
                guard let d = YAMLReader.dict(item) else { throw DCError("Bad timepoint_parameters entry") }
                return try parse(d)
            }
        }
        let source = YAMLReader.dict(doc["source"])
        guard let file = YAMLReader.string(source?["file"]) else { throw DCError("YAML has no source.file") }
        return ThresholdConfig(parameters: params, timepointParameters: perT, sourceFile: file, raw: doc)
    }

    /// `normalize_threshold_params`: fill defaults (method percentile, block_size 64,
    /// invert false, levels 3, selected_levels None).
    static func parse(_ d: [String: Any]) throws -> ThresholdParams {
        guard let ch = YAMLReader.int(d["channel_index"]) else { throw DCError("Threshold parameters need channel_index") }
        guard let sigma = YAMLReader.double(d["sigma"]) else { throw DCError("Threshold parameters need sigma") }
        guard let pct = YAMLReader.double(d["percentile"]) else { throw DCError("Threshold parameters need percentile") }
        var selected: [Int]?
        if let list = YAMLReader.array(d["selected_levels"]) { selected = list.compactMap { YAMLReader.int($0) } }
        return ThresholdParams(channel: YAMLReader.string(d["channel"]) ?? "",
                               channelIndex: ch, sigma: sigma, percentile: pct,
                               method: YAMLReader.string(d["method"]) ?? "percentile",
                               blockSize: YAMLReader.int(d["block_size"]) ?? 64,
                               invert: YAMLReader.bool(d["invert"]) ?? false,
                               levels: YAMLReader.int(d["levels"]) ?? 3,
                               selectedLevels: selected)
    }

    /// `get_threshold_params_for_timepoint(cfg, t)`.
    public func params(forTimepoint t: Int) throws -> ThresholdParams {
        guard let list = timepointParameters else { return parameters }
        guard t >= 0 && t < list.count else {
            throw DCError("timepoint_parameters has \(list.count) entries, cannot read T=\(t)")
        }
        return list[t]
    }
}

/// Builds the YAML that the Mask tool saves.
public enum ThresholdYAML {
    /// Parameter dict in the same key order as `_current_params()`.
    public static func paramsValue(_ p: ThresholdParams) -> YAMLValue {
        var items: [(String, YAMLValue)] = [
            ("channel", .str(p.channel)),
            ("channel_index", .int(p.channelIndex)),
            ("sigma", p.sigma == p.sigma.rounded() && abs(p.sigma) < 1e15 ? .int(Int(p.sigma)) : .float(p.sigma)),
            ("percentile", .float(p.percentile)),
            ("method", .str(p.method)),
            ("invert", .bool(p.invert)),
        ]
        if p.method == "multiotsu" {
            items.append(("levels", .int(p.levels)))
            items.append(("selected_levels", .seq((p.selectedLevels ?? []).map { .int($0) })))
        }
        return .map(items)
    }

    public struct Diagnostics {
        public var timePoint: Int
        public var savedAt: String
        public var embryoID: Int
        public var maskAreaPx: Int
        public var maskAreaPct: Double
        public var meanIntensity: Double
        public var centroidXY: (Double, Double)
        public init(timePoint: Int, savedAt: String, embryoID: Int, maskAreaPx: Int, maskAreaPct: Double,
                    meanIntensity: Double, centroidXY: (Double, Double)) {
            self.timePoint = timePoint; self.savedAt = savedAt; self.embryoID = embryoID
            self.maskAreaPx = maskAreaPx; self.maskAreaPct = maskAreaPct
            self.meanIntensity = meanIntensity; self.centroidXY = centroidXY
        }
    }

    public static func document(parameters: ThresholdParams, perTimepoint: [ThresholdParams], sourceFile: String,
                                t: Int, p: Int, y: Int, x: Int, diagnostics d: Diagnostics) -> YAMLValue {
        .map([
            ("parameters", paramsValue(parameters)),
            ("timepoint_parameters", .seq(perTimepoint.map(paramsValue))),
            ("source", .map([
                ("file", .str(sourceFile)),
                ("image_shape", .map([("T", .int(t)), ("P", .int(p)), ("Y", .int(y)), ("X", .int(x))])),
            ])),
            ("diagnostics", .map([
                ("time_point", .int(d.timePoint)),
                ("saved_at", .str(d.savedAt)),
                ("embryos", .seq([.map([
                    ("id", .int(d.embryoID)),
                    ("mask_area_px", .int(d.maskAreaPx)),
                    ("mask_area_pct", .float(d.maskAreaPct)),
                    ("mean_intensity", .float(d.meanIntensity)),
                    ("centroid", .seq([.float(d.centroidXY.0), .float(d.centroidXY.1)])),
                ])])),
            ])),
        ])
    }

    /// `datetime.now().isoformat(timespec="seconds")` in local time.
    public static func nowISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date())
    }
}
