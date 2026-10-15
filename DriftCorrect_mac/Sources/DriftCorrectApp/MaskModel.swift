import AppKit
import DCCore
import SwiftUI

enum MaskMethod: String, CaseIterable, Identifiable {
    case percentile = "Percentile"
    case multiotsu = "Multi-Level Otsu"
    case percentileOtsuROI = "Percentile -> Otsu ROI"
    var id: String { rawValue }
    var code: String {
        switch self {
        case .percentile: return "percentile"
        case .multiotsu: return "multiotsu"
        case .percentileOtsuROI: return "percentile_otsu_roi"
        }
    }
}

/// One preview request (a snapshot of the controls).
struct PreviewRequest {
    var source: ProjectionSource
    var t: Int
    var p: Int
    var params: ThresholdParams
}

struct PreviewOutput {
    var image: CGImage?
    var caption: String
    var histogram: MaskPreview.Histogram?
    var error: String?
}

/// Computes previews off the main thread. When requests arrive faster than
/// they finish, only the newest waiting request runs ("latest wins").
final class PreviewWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dc.mask.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var waiting: (PreviewRequest, (PreviewOutput) -> Void)?
    private var busy = false
    private var classCache: MaskPreview.ClassCache?

    func resetCache() { queue.async { self.classCache = nil } }

    func submit(_ request: PreviewRequest, completion: @escaping (PreviewOutput) -> Void) {
        lock.lock()
        waiting = (request, completion)
        let start = !busy
        if start { busy = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let item = waiting else { busy = false; lock.unlock(); return }
            let (req, done) = item
            waiting = nil
            lock.unlock()
            done(compute(req))
        }
    }

    private func compute(_ r: PreviewRequest) -> PreviewOutput {
        do {
            let raw = try r.source.image(t: r.t, p: r.p, c: r.params.channelIndex)
            let key = "\(r.source.url.path)|\(r.t)|\(r.p)|\(r.params.channelIndex)|\(r.params.sigma)|\(r.params.levels)"
            let result = try MaskPreview.compute(raw: raw, params: r.params, embryo: r.p, backend: Services.backend,
                                                 classCache: &classCache, cacheKey: key)
            let rgba = MaskPreview.renderComposite(raw: raw, mask: result.mask, centroid: result.centroid,
                                                   classMap: result.classMap, selected: r.params.selectedLevels ?? [])
            // Look ahead: the next timepoint is likely next (slider drag or playback).
            r.source.prefetch(t: r.t + 1, p: r.p)
            return PreviewOutput(image: makeImage(rgba, width: raw.width, height: raw.height),
                                 caption: result.caption, histogram: result.histogram, error: nil)
        } catch {
            return PreviewOutput(image: nil, caption: "", histogram: nil, error: "\(error)")
        }
    }

    private func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// State of the Mask tool window (find_threshold.py ThresholdApp).
@MainActor
final class MaskModel: ObservableObject {
    // File
    @Published var path = ""
    @Published private(set) var source: ProjectionSource?
    @Published private(set) var channelNames: [String] = []
    @Published var status = ""

    // Controls
    @Published var channelIndex = 0 { didSet { if oldValue != channelIndex { update() } } }
    @Published var embryo = 0
    @Published var t = 0 { didSet { if oldValue != t { update() } } }
    @Published var sigma = 2 { didSet { if oldValue != sigma { update() } } }
    @Published var method: MaskMethod = .percentile { didSet { if oldValue != method { methodChanged() } } }
    @Published var levels = 3 { didSet { if oldValue != levels { rebuildLevelChecks(); update() } } }
    @Published var levelChecks: [Bool] = [false, false, true]
    /// Percentile in half-percent steps (20...199 → 10.0...99.5).
    @Published var percentileSteps = 180 { didSet { if oldValue != percentileSteps { update() } } }
    @Published var invert = false { didSet { if oldValue != invert { update() } } }

    // Per-timepoint overrides
    @Published private(set) var custom: [Int: ThresholdParams] = [:]
    @Published var rangeStart = 0
    @Published var rangeEnd = 0

    // Playback
    @Published private(set) var playing = false
    @Published var delay = 0.5
    private var timer: Timer?

    // Display
    @Published private(set) var image: CGImage?
    @Published private(set) var header = ""
    @Published private(set) var caption = ""
    @Published private(set) var histogram: MaskPreview.Histogram?

    private let worker = PreviewWorker()

    var T: Int { source?.t ?? 0 }
    var P: Int { source?.p ?? 0 }
    var percentile: Double { Double(percentileSteps) * 0.5 }
    var selectedLevels: [Int] { levelChecks.enumerated().filter { $0.element }.map { $0.offset } }
    var channelName: String {
        channelIndex < channelNames.count ? channelNames[channelIndex] : "Ch\(channelIndex)"
    }

    func load() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url = expand(trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert("Error", "File not found:\n\(url.path)")
            return
        }
        status = "Loading..."
        stopPlaying()
        Task.detached(priority: .userInitiated) {
            do {
                let src = try ProjectionSource(url: url, backend: Services.backend)
                await MainActor.run { self.didLoad(src) }
            } catch {
                await MainActor.run {
                    self.status = ""
                    showAlert("Error", "\(error)")
                }
            }
        }
    }

    private func didLoad(_ src: ProjectionSource) {
        source = src
        channelNames = src.channelNames
        custom = [:]
        worker.resetCache()
        embryo = 0
        rangeStart = 0
        rangeEnd = 0
        channelIndex = 0
        t = 0
        status = "Loaded: T=\(src.t), P=\(src.p), C=\(src.c), Y=\(src.y), X=\(src.x)"
        update()
    }

    func previousEmbryo() { guard P > 1 else { return }; embryo = (embryo - 1 + P) % P; update() }
    func nextEmbryo() { guard P > 1 else { return }; embryo = (embryo + 1) % P; update() }

    private func methodChanged() {
        if method == .multiotsu && levelChecks.count != levels { rebuildLevelChecks() }
        update()
    }

    /// One checkbox per class; selection resets to the brightest class
    /// (class indices mean different intensity bands for another level count).
    private func rebuildLevelChecks() {
        levelChecks = (0..<levels).map { $0 == levels - 1 }
    }

    func toggleLevel(_ i: Int) {
        guard i < levelChecks.count else { return }
        levelChecks[i].toggle()
        update()
    }

    /// `_current_params()`.
    func currentParams() -> ThresholdParams {
        ThresholdParams(channel: channelName, channelIndex: channelIndex, sigma: Double(sigma), percentile: percentile,
                        method: method.code, blockSize: 64, invert: invert, levels: levels,
                        selectedLevels: method == .multiotsu ? selectedLevels : nil)
    }

    func applyToCurrentT() {
        guard source != nil else { return }
        custom[t] = currentParams()
    }

    func applyToRange() {
        guard source != nil, T > 0 else { return }
        var a = rangeStart, b = rangeEnd
        if a > b { swap(&a, &b) }
        a = max(0, min(a, T - 1))
        b = max(0, min(b, T - 1))
        let p = currentParams()
        for k in a...b { custom[k] = p }
        rangeStart = a
        rangeEnd = b
    }

    var customizedText: String { "Customized: \(custom.count) / \(T) T" }

    /// Recompute the mask and redraw (`_update`).
    func update() {
        guard let src = source else { return }
        let p = currentParams()
        var h = "T = \(t)  |  \(channelName)  |  sigma = \(sigma)  |  method = \(p.method)  |  percentile = \(PyFormat.repr(percentile))"
        if method == .multiotsu {
            let shown = selectedLevels.map(String.init).joined(separator: ",")
            h += "  |  levels = \(levels)  |  selected = \(shown.isEmpty ? "none" : shown)"
        }
        if invert { h += "  |  INVERTED" }
        header = h
        let request = PreviewRequest(source: src, t: min(t, max(0, src.t - 1)), p: min(embryo, max(0, src.p - 1)), params: p)
        worker.submit(request) { out in
            Task { @MainActor in
                if let e = out.error {
                    self.status = e
                    return
                }
                self.image = out.image
                self.caption = out.caption
                self.histogram = out.histogram
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        if playing { stopPlaying() } else { startPlaying() }
    }

    private func startPlaying() {
        guard source != nil, T > 0 else { return }
        playing = true
        scheduleNext()
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.playing, self.T > 0 else { return }
                self.t = (self.t + 1) % self.T
                self.scheduleNext()
            }
        }
    }

    func stopPlaying() {
        playing = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: Save

    func save() {
        guard let src = source else {
            showAlert("No data", "Load a file first.")
            return
        }
        let params = currentParams()
        let perT = (0..<src.t).map { custom[$0] ?? params }
        let embryo = min(self.embryo, src.p - 1), tp = t
        Task.detached(priority: .userInitiated) {
            do {
                let url = try MaskSave.save(source: src, embryo: embryo, t: tp, params: params, perTimepoint: perT,
                                            backend: Services.backend)
                await MainActor.run { self.status = "Saved → \(url.lastPathComponent)" }
            } catch {
                await MainActor.run { showAlert("Save failed", "\(error)") }
            }
        }
    }
}
