import AppKit
import DCCore
import SwiftUI

/// Manual offsets are stored at boundaries, keyed by the moving timepoint.
/// All image work starts from the source TIFF, never from an earlier preview.
@MainActor
final class ManualXYModel: ObservableObject {
    @Published var path = ""
    @Published private(set) var source: TIFFStack?
    @Published private(set) var isLoading = false
    @Published private(set) var isRendering = false
    @Published private(set) var imagesCurrent = false
    @Published private(set) var status = "Load a TIFF. Select the same landmark in both panes."
    @Published var t = 0 { didSet { if t != oldValue { refresh() } } }
    @Published var referenceZ = 0 { didSet { if referenceZ != oldValue { sliceChanged(reference: true) } } }
    @Published var movingZ = 0 { didSet { if movingZ != oldValue { sliceChanged(reference: false) } } }
    @Published var channel = 0 { didSet { if channel != oldValue { refresh() } } }
    @Published var sigma = 0.0 { didSet { if sigma != oldValue { refresh() } } }
    @Published var enlargeCanvas = true { didSet { if enlargeCanvas != oldValue { refresh() } } }
    @Published var shiftMode: ShiftMode = .subpixel { didSet { if shiftMode != oldValue { refresh() } } }
    @Published var lowMemory = false
    @Published var fps = 2.0
    @Published private(set) var referenceImage: CGImage?
    @Published private(set) var movingImage: CGImage?
    @Published private(set) var referencePoint: CGPoint?
    @Published private(set) var movingPoint: CGPoint?
    @Published private(set) var corrections: [Int: CGPoint] = [:]
    @Published private(set) var pending: CGPoint?

    private let queue = DispatchQueue(label: "dc.manual.preview", qos: .userInitiated)
    private let cache = ManualSliceCache()
    private var renderContext: RunContext?
    private var sourceID = UUID()
    private var revision = 0

    var canPreview: Bool { referencePoint != nil && movingPoint != nil && pending == nil && !isRendering && imagesCurrent }
    var canAccept: Bool { pending != nil && !isRendering && imagesCurrent }
    var hasCorrection: Bool { corrections[t + 1] != nil }

    func load() {
        let url = expand(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert("Select input", "Select an existing TIFF or threshold YAML file.")
            return
        }
        if !corrections.isEmpty || pending != nil {
            let alert = NSAlert()
            alert.messageText = "Load another file?"
            alert.informativeText = "This clears the manual corrections in this window."
            alert.addButton(withTitle: "Load")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        revision += 1
        renderContext?.cancel()
        isLoading = true
        isRendering = false
        status = "Loading…"
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> TIFFStack in
                let isYAML = ["yaml", "yml"].contains(url.pathExtension.lowercased())
                let tif = try isYAML ? ManualXYPipeline.tif(forYAML: url) : url
                let stack = try TIFFStack(url: tif)
                guard stack.t >= 2 else { throw DCError("Manual XY requires at least two timepoints") }
                return stack
            }
            await MainActor.run {
                switch result {
                case .success(let stack):
                    self.sourceID = UUID()
                    self.cache.reset()
                    self.source = stack
                    self.referenceImage = nil
                    self.movingImage = nil
                    self.corrections = [:]
                    self.t = 0
                    self.referenceZ = 0
                    self.movingZ = 0
                    self.channel = 0
                    self.isLoading = false
                    self.refresh()
                case .failure(let error):
                    self.isLoading = false
                    self.refresh()
                    self.status = "Load failed: \(error)"
                }
            }
        }
    }

    /// Points are in the common, already-corrected canvas coordinates.
    func select(_ point: CGPoint, reference: Bool) {
        guard !isRendering, !isLoading, imagesCurrent, pending == nil else { return }
        if reference { referencePoint = point } else { movingPoint = point }
        status = canPreview ? "Landmarks selected. Preview the correction." : "Select the corresponding landmark in the other pane."
    }

    private func options(for values: [Int: CGPoint]) -> ManualXYOptions {
        let rows = values.keys.sorted().map { boundary in
            let delta = values[boundary]!
            return ManualRow(t1: boundary - 1, t2: boundary,
                             p1: (Double(delta.y), Double(delta.x)), p2: (0, 0))
        }
        var o = ManualXYOptions(rows: rows)
        o.propagateForward = true
        o.enlargeCanvas = enlargeCanvas
        o.shiftMode = shiftMode
        o.lowMemory = lowMemory
        o.fps = fps
        return o
    }

    func preview() {
        guard canPreview, let a = referencePoint, let b = movingPoint else { return }
        let existing = corrections[t + 1] ?? .zero
        // The click difference is a residual on top of accepted corrections.
        pending = CGPoint(x: Double(Float(existing.x + a.x - b.x)),
                          y: Double(Float(existing.y + a.y - b.y)))
        referencePoint = nil
        movingPoint = nil
        render()
    }

    func accept() {
        guard canAccept, let delta = pending else { return }
        if delta == .zero { corrections.removeValue(forKey: t + 1) }
        else { corrections[t + 1] = delta }
        refresh()
    }

    func removeCorrection() {
        corrections.removeValue(forKey: t + 1)
        refresh()
    }

    private func sliceChanged(reference: Bool) {
        guard !isLoading else { return }
        if pending != nil {
            refresh()
        } else {
            // Browsing the other Z slider must not erase the first landmark.
            if reference { referencePoint = nil } else { movingPoint = nil }
            render()
        }
    }

    /// Navigation/settings discard only the unaccepted preview and landmarks.
    func refresh() {
        guard !isLoading else { return }
        pending = nil
        referencePoint = nil
        movingPoint = nil
        render()
    }

    private func render() {
        guard let stack = source else { return }
        revision += 1
        let requestID = revision
        renderContext?.cancel()
        var values = corrections
        if let pending { values[t + 1] = pending }
        let o = options(for: values)
        let ti = t, zi = referenceZ, zj = movingZ, ci = channel, blur = sigma
        let isPreview = pending != nil
        imagesCurrent = false
        isRendering = true
        status = "Updating slices…"
        let backend = Services.backend
        let context = RunContext.silent()
        renderContext = context
        let cache = self.cache, sourceID = self.sourceID
        queue.async { [weak self] in
            let result = Result { () throws -> (CGImage, CGImage) in
                try context.checkCancelled()
                let shifts = try ManualXYPipeline.resolvedShifts(timepoints: stack.t, options: o)
                let pad = o.enlargeCanvas ? Padding.covering(dys: shifts.map { $0.dy }, dxs: shifts.map { $0.dx }) : .none
                let a = try cache.image(stack: stack, sourceID: sourceID, t: ti, z: zi, channel: ci, sigma: blur,
                                       offset: shifts[ti], pad: pad, mode: o.shiftMode, backend: backend, context: context)
                let b = try cache.image(stack: stack, sourceID: sourceID, t: ti + 1, z: zj, channel: ci, sigma: blur,
                                       offset: shifts[ti + 1], pad: pad, mode: o.shiftMode, backend: backend, context: context)
                return (a, b)
            }
            Task { @MainActor [weak self] in
                guard let self, self.revision == requestID else { return }
                self.isRendering = false
                switch result {
                case .success(let images):
                    self.imagesCurrent = true
                    self.referenceImage = images.0
                    self.movingImage = images.1
                    self.status = isPreview
                        ? "Preview: correction applies from T \(ti + 1) onward. Accept or reset."
                        : "Select the same landmark in both panes. Corrections apply to all channels and Z slices."
                case .failure(let error):
                    self.status = "Preview failed: \(error)"
                }
            }
            // Warm neighboring raw slices only after the requested pair is ready.
            // A new request cancels this work before its next disk read.
            guard case .success = result else { return }
            for (nextT, nextZ) in [(ti + 1, zi), (ti + 2, zj), (ti, zi + 1),
                                    (ti + 1, zj + 1), (ti, zi - 1), (ti + 1, zj - 1)] {
                guard nextT >= 0, nextT < stack.t, nextZ >= 0, nextZ < stack.z else { continue }
                if context.isCancelled { break }
                _ = try? cache.plane(stack: stack, sourceID: sourceID, t: nextT, z: nextZ,
                                     channel: ci, context: context)
            }
        }
    }

    func export(job: JobRunner) {
        guard let stack = source, !corrections.isEmpty, pending == nil, !job.isRunning else { return }
        guard fps.isFinite && fps > 0 else { showAlert("Invalid FPS", "FPS must be positive and finite."); return }
        let o = options(for: corrections)
        let tif = stack.url
        let backend = Services.backend, movies = Services.movies
        job.clearLog()
        job.start(runningStatus: "Applying manual corrections…") { ctx in
            let out = try ManualXYPipeline.run(tif: tif, options: o, backend: backend, movies: movies, context: ctx)
            return "Saved \(out.lastPathComponent)"
        }
    }
}

/// Bounded caches shared by the two panes. Accesses use the preview queue;
/// NSCache also permits reset on the main actor when another file is loaded.
private final class ManualSliceCache: @unchecked Sendable {
    private final class Slice {
        let volume: Volume
        init(_ volume: Volume) { self.volume = volume }
    }
    private let planes = NSCache<NSString, Slice>()
    private let images = NSCache<NSString, CGImage>()

    init() {
        planes.countLimit = 12
        planes.totalCostLimit = 64 * 1024 * 1024
        images.countLimit = 12
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func reset() {
        planes.removeAllObjects()
        images.removeAllObjects()
    }

    func plane(stack: TIFFStack, sourceID: UUID, t: Int, z: Int, channel: Int, context: RunContext) throws -> Volume {
        try context.checkCancelled()
        let key = "\(sourceID)|\(stack.pageIndex(t: t, c: channel, z: z))" as NSString
        if let hit = planes.object(forKey: key) { return hit.volume }
        let volume = Volume(c: 1, z: 1, y: stack.y, x: stack.x, type: stack.sampleType)
        try stack.tiff.readPage(stack.pageIndex(t: t, c: channel, z: z), into: volume.planePointer(0))
        try context.checkCancelled()
        planes.setObject(Slice(volume), forKey: key, cost: volume.byteCount)
        return volume
    }

    func image(stack: TIFFStack, sourceID: UUID, t: Int, z: Int, channel: Int, sigma: Double,
               offset: (dy: Double, dx: Double), pad: Padding,
               mode: ShiftMode, backend: ComputeBackend, context: RunContext) throws -> CGImage {
        try context.checkCancelled()
        let key = "\(sourceID)|\(stack.pageIndex(t: t, c: channel, z: z))|\(sigma)|\(offset.dy)|\(offset.dx)|\(pad.top),\(pad.bottom),\(pad.left),\(pad.right)|\(mode.rawValue)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let plane = try self.plane(stack: stack, sourceID: sourceID, t: t, z: z, channel: channel, context: context)
        var raw = Image2D(width: stack.x, height: stack.y, pixels: plane.floatPlane(0))
        if sigma > 0 { raw = try backend.gaussian(raw, sigma: sigma) }
        // Viewing contrast/smoothing are not part of the exported stack.
        try context.checkCancelled()
        let gray = Contrast.autoContrast(raw.pixels)
        let display = Volume(c: 1, z: 1, y: stack.y, x: stack.x, type: .uint8)
        gray.withUnsafeBytes { bytes in
            display.storage.raw.copyMemory(from: bytes.baseAddress!, byteCount: gray.count)
        }
        try context.checkCancelled()
        let shifted = try backend.shift(display, pad: pad, dy: offset.dy, dx: offset.dx, mode: mode)
        let bytes = shifted.floatPlane(0).map { UInt8(clamping: Int($0)) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: shifted.x, height: shifted.y, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: shifted.x, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw DCError("Could not render the slice") }
        try context.checkCancelled()
        images.setObject(image, forKey: key, cost: shifted.x * shifted.y)
        return image
    }

}
