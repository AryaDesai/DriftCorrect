import DCApple
import DCCore
import SwiftUI

/// The Alignment window. It corrects a movie in xy and z, in xy only, or in z only. The user picks a movie and a
/// channel and runs. When the chosen settings use the embryo mask, the Mask window opens from here. The settings
/// that change how the correction works are under Advanced options. Each one shows an explanation when the pointer
/// rests on it.
struct AlignView: View {
    @ObservedObject var job: JobRunner
    @ObservedObject var mask: MaskModel
    @Environment(\.openWindow) private var openWindow

    /// What the run corrects.
    enum Mode: Int { case xyz, xy, z }
    /// The part of the image that image matching or z correction follows.
    enum Follow: Int { case mask, box, whole }
    /// The box being drawn, for the xy alignment or for the z correction.
    enum BoxTarget: Int, Identifiable { case xy, z; var id: Int { rawValue } }
    static let xyBoxPrompt = "Drag a box over cells that should stay still in xy. This is the first timepoint, before alignment."
    static let zBoxPrompt = "Drag a box over cells that should stay in the same slice. This is the first timepoint, before alignment."

    @State private var mode: Mode = .xyz
    @State private var moviePath = ""
    @State private var yamlPath = ""
    @State private var channels: [String] = []
    @State private var source: URL?
    @State private var channel = 0
    @State private var boxTarget: BoxTarget?
    @State private var showAdvanced = false

    // Advanced options for xy
    @State private var xyFollow: Follow = .whole
    @State private var xyBox: CGRect?
    @State private var hold = true
    @State private var smoothing = 10.0
    @State private var correctRotation = true
    @State private var maximumAngle = 3.0

    // Advanced options for z
    @State private var zFollow: Follow = .whole
    @State private var zBox: CGRect?
    @State private var dropLargeShifts = false
    @State private var maximumShift = 5.0
    @State private var span = 5

    // Advanced options for the output
    @State private var enlargeCanvas = true
    @State private var fps = 2.0
    @State private var lowMemory = true

    private var doesXY: Bool { mode != .z }
    private var doesZ: Bool { mode != .xy }
    /// The embryo mask is needed for holding the body and for following the mask.
    private var needsMask: Bool {
        (doesXY && (hold || xyFollow == .mask)) || (doesZ && zFollow == .mask)
    }
    private var hasMovie: Bool { !moviePath.trimmingCharacters(in: .whitespaces).isEmpty }
    private var hasMask: Bool { !yamlPath.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                Text("XYZ").tag(Mode.xyz)
                Text("XY only").tag(Mode.xy)
                Text("Z only").tag(Mode.z)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(job.isRunning)
            ScrollView {
                Form {
                    LabeledContent("Movie:") {
                        PathField(placeholder: "Select an OME-TIFF or ND2 file", path: $moviePath, types: [.tiff, .nd2])
                    }
                    channelPicker
                    if needsMask { maskRow }
                    DisclosureGroup("Advanced options", isExpanded: $showAdvanced) { advanced }
                }
                .padding(.trailing, 8)
            }
            .frame(minHeight: showAdvanced ? 320 : 150)
            .disabled(job.isRunning)
            HStack {
                Text("Compute: \(Services.backend.name)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if hasMovie && needsMask && !hasMask { Text("These settings need an embryo mask").font(.caption).foregroundStyle(.secondary) }
                Button("Cancel") { job.cancel() }.disabled(!job.isRunning)
                Button(mode == .xyz ? "Run xyz alignment" : mode == .xy ? "Run xy alignment" : "Run z correction") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isRunning || !hasMovie || (needsMask && !hasMask))
            }
            JobStatusView(job: job)
            LogView(text: job.log)
        }
        .padding()
        .frame(minWidth: 700, minHeight: 620)
        .onChange(of: moviePath) { _, _ in movieChanged() }
        .onChange(of: mask.lastSaved) { _, saved in
            // Pick up a mask that was just saved for this movie.
            if let url = saved, expand(mask.path) == expand(moviePath) { yamlPath = url.path }
        }
        .sheet(item: $boxTarget) { target in
            if let url = source {
                BoxPicker(source: url, channel: channel, prompt: target == .xy ? Self.xyBoxPrompt : Self.zBoxPrompt,
                          box: target == .xy ? $xyBox : $zBox)
            }
        }
    }

    // The explanation of each setting. It is shown when the pointer rests on the setting.
    static let channelHelp = "The matching follows the pattern of this channel. A nuclear marker works best because its pattern stays the same between timepoints."
    static let maskHelp = "These settings need the embryo mask. Make mask opens the threshold window on this movie and starts from a threshold estimated from the image. Saving there writes a YAML file next to the movie, and this field then points to it. An existing threshold YAML file can also be selected."
    static let xyFollowHelp = "The pixels that the matching compares. Whole frame uses every pixel that holds data. Embryo mask uses the pixels inside the mask. A box uses the cells inside a box drawn on the first timepoint."
    static let holdHelp = "Image matching follows the cells. When the cells move through the body, the summed steps slowly carry the frame away and slowly turn it. With this option the centroid of the embryo mask sets where the body sits, and the slow turning stays as it was acquired. The matching still removes the jumps and the sudden turns between neighbouring timepoints."
    static let smoothingHelp = "The centroid of the mask and the summed turn are averaged over about this many timepoints. A small number follows the mask closely and passes on its wobble. A large number is steadier, and the body can then glide further before the mask pulls it back."
    static let rotationHelp = "Image matching also tries small turns between neighbouring timepoints and removes the sudden ones. With this off the matching only shifts, and the image is never turned."
    static let angleHelp = "The matching tries turns up to this angle between two neighbouring timepoints."
    static let zFollowHelp = "The pixels whose pattern must stay in the same slice. Whole frame uses every pixel that holds data. Embryo mask uses the pixels inside the mask. A box uses the cells inside a box drawn on the first timepoint."
    static let spanHelp = "Each timepoint is compared with the one before it and with the one this many timepoints earlier. A slow movement is too small to measure between neighbours and adds up to a measurable amount over several timepoints. With 1 only neighbours are compared."
    static let dropHelp = "Timepoints whose z movement from the last kept timepoint exceeds the maximum are left out of the output. The other timepoints are aligned as if the dropped ones were never recorded. When the tissue stays at the new depth, only the first timepoint after the move is dropped."
    static let enlargeHelp = "Adds empty pixels around the frame and empty slices to the stack so that data moved by the correction stays in the file. Without it the file keeps its size and data that moves outside is lost."
    static let fpsHelp = "The playback speed of the MP4 movies written next to the corrected file."
    static let lowMemoryHelp = "Reads the movie from disk again when writing the output. Without it the frames are kept in memory between the two passes, which is faster and needs enough memory for the whole movie."

    @ViewBuilder
    private var channelPicker: some View {
        if channels.isEmpty {
            LabeledContent("Channel:") { Text("Select a movie to list the channels").foregroundStyle(.secondary) }
        } else {
            Picker("Channel:", selection: $channel) {
                ForEach(channels.indices, id: \.self) { Text(channels[$0]).tag($0) }
            }
            .help(Self.channelHelp)
        }
    }

    private var maskRow: some View {
        LabeledContent("Embryo mask:") {
            HStack {
                PathField(placeholder: "No mask yet", path: $yamlPath, types: [.yaml, .yml])
                Button("Make mask…") {
                    mask.open(path: moviePath, channel: channel)
                    openWindow(id: "mask")
                }
                .disabled(!hasMovie)
            }
        }
        .help(Self.maskHelp)
    }

    @ViewBuilder
    private var advanced: some View {
        if doesXY {
            Section("XY") {
                followPicker(selection: $xyFollow, target: .xy, box: xyBox, help: Self.xyFollowHelp)
                Toggle("Hold the body in place with the embryo mask", isOn: $hold).toggleStyle(.checkbox)
                    .help(Self.holdHelp)
                if hold {
                    LabeledContent("Averaging (timepoints):") { TextField("", value: $smoothing, format: .number).frame(width: 80) }
                        .help(Self.smoothingHelp)
                }
                Toggle("Correct rotation", isOn: $correctRotation).toggleStyle(.checkbox)
                    .help(Self.rotationHelp)
                if correctRotation {
                    LabeledContent("Largest turn (degrees):") { TextField("", value: $maximumAngle, format: .number).frame(width: 80) }
                        .help(Self.angleHelp)
                }
            }
        }
        if doesZ {
            Section("Z") {
                followPicker(selection: $zFollow, target: .z, box: zBox, help: Self.zFollowHelp)
                LabeledContent("Also compare this many timepoints back:") {
                    Stepper("\(span)", value: $span, in: 1...50)
                }
                .help(Self.spanHelp)
                Toggle("Drop time points with large shifts", isOn: $dropLargeShifts).toggleStyle(.checkbox)
                    .help(Self.dropHelp)
                if dropLargeShifts {
                    LabeledContent("Maximum shift (slices):") { TextField("", value: $maximumShift, format: .number).frame(width: 80) }
                        .help(Self.dropHelp)
                }
            }
        }
        Section("Output") {
            Toggle("Enlarge the canvas and the stack so that nothing is cut off", isOn: $enlargeCanvas).toggleStyle(.checkbox)
                .help(Self.enlargeHelp)
            if doesXY {
                LabeledContent("Movie speed:") {
                    HStack {
                        TextField("", value: $fps, format: .number.precision(.fractionLength(2))).frame(width: 80)
                        Text("fps")
                    }
                }
                .help(Self.fpsHelp)
            }
            Toggle("Use low-memory streaming", isOn: $lowMemory).toggleStyle(.checkbox)
                .help(Self.lowMemoryHelp)
        }
    }

    /// A picker of the region to follow, with a button to draw the box when the box is chosen.
    @ViewBuilder
    private func followPicker(selection: Binding<Follow>, target: BoxTarget, box: CGRect?, help: String) -> some View {
        Picker("Follow:", selection: selection) {
            Text("Whole frame").tag(Follow.whole)
            Text("Embryo mask").tag(Follow.mask)
            Text("A box I draw").tag(Follow.box)
        }
        .help(help)
        if selection.wrappedValue == .box {
            LabeledContent("Box:") {
                HStack {
                    Button("Draw box…") { boxTarget = target }.disabled(source == nil)
                    Text(boxLabel(box)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func boxLabel(_ box: CGRect?) -> String {
        guard let b = box else { return source == nil ? "Select a movie first" : "No box yet" }
        return "x \(Int(b.minX)), y \(Int(b.minY)), \(Int(b.width)) × \(Int(b.height)) px"
    }

    /// Turn the choice of region into the setting of the pipeline. It is nil when a box is needed but none is drawn.
    private func region(_ follow: Follow, box: CGRect?) -> FollowRegion? {
        switch follow {
        case .mask: return .embryoMask
        case .whole: return .wholeFrame
        case .box: return box.map { .box(x: Int($0.minX), y: Int($0.minY), width: Int($0.width), height: Int($0.height)) }
        }
    }

    /// List the channels of the selected movie and look for a mask that was saved for it.
    private func movieChanged() {
        let url = expand(moviePath)
        Task.detached(priority: .userInitiated) {
            var names: [String] = []
            var file: URL?
            var saved: URL?
            if FileManager.default.fileExists(atPath: url.path), let src = try? ProjectionSource(url: url, backend: Services.backend) {
                names = Array(src.channelNames.prefix(src.c))
                file = url
                // The Mask window saves `{name}_{channel}_threshold.yaml` next to the movie. Take the newest one.
                let stem = PyFormat.stemWithoutOME(url)
                let folder = url.deletingLastPathComponent()
                let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix(stem + "_") && $0.lastPathComponent.hasSuffix("_threshold.yaml") }
                saved = found.max { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da < db
                }
            }
            // Start on a channel whose name looks like a nuclear marker.
            let nuclear = names.firstIndex { n in ["mcherry", "h2b", "nuc", "dapi", "hoechst"].contains { n.lowercased().contains($0) } }
            let foundNames = names, foundFile = file, foundMask = saved
            await MainActor.run {
                if foundFile != source { xyBox = nil; zBox = nil; yamlPath = foundMask?.path ?? "" }
                source = foundFile
                if foundNames != channels {
                    channels = foundNames
                    channel = nuclear ?? 0
                }
            }
        }
    }

    private func run() {
        let movie = expand(moviePath)
        guard FileManager.default.fileExists(atPath: movie.path) else {
            showAlert("Invalid movie", "Select an existing OME-TIFF or ND2 file."); return
        }
        var yaml: URL?
        if needsMask {
            let url = expand(yamlPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                showAlert("No mask", "These settings need an embryo mask. Make one with Make mask, or select a threshold YAML file."); return
            }
            yaml = url
        }
        if doesZ && dropLargeShifts && (!maximumShift.isFinite || maximumShift <= 0) {
            showAlert("Invalid maximum shift", "Enter a positive number of slices."); return
        }
        var z = ZCorrectionOptions()
        if doesZ {
            z.maximumStep = dropLargeShifts ? maximumShift : nil
            z.span = span
            if !channels.isEmpty { z.channelIndex = channel }
            guard let r = region(zFollow, box: zBox) else {
                showAlert("No box", "Draw a box over the cells to follow in z, or choose another option."); return
            }
            z.region = r
        }
        job.clearLog()
        if mode == .z {
            var o = ZCorrectOptions(input: movie)
            o.z = z
            o.yaml = yaml
            o.enlargeStack = enlargeCanvas
            o.lowMemory = lowMemory
            let options = o
            job.append("Correcting z drift: \(movie.path)\n")
            job.start(runningStatus: "Running…") { ctx in
                let start = Date()
                _ = try ZCorrectPipeline.run(options: options, backend: Services.backend, context: ctx)
                ctx.log("\nZ correction completed.")
                return String(format: "Completed successfully in %.1f s", Date().timeIntervalSince(start))
            }
            return
        }
        guard fps.isFinite && fps > 0 else { showAlert("Invalid speed", "The movie speed must be a positive number."); return }
        guard smoothing.isFinite && smoothing >= 0 && maximumAngle.isFinite && maximumAngle >= 0 else {
            showAlert("Invalid setting", "The averaging and the largest turn must be 0 or positive."); return
        }
        var o = AlignOptions(source: movie, yaml: yaml)
        o.fps = fps
        o.enlargeCanvas = enlargeCanvas
        o.lowMemory = lowMemory
        if !channels.isEmpty { o.xyMatching.channelIndex = channel }
        guard let r = region(xyFollow, box: xyBox) else {
            showAlert("No box", "Draw a box over the cells to follow in xy, or choose another option."); return
        }
        o.xyMatching.region = r
        o.xyMatching.holdInPlace = hold
        o.xyMatching.smoothing = smoothing
        o.xyMatching.maximumAngle = correctRotation ? maximumAngle : 0
        if doesZ { o.zCorrection = z }
        let options = o
        job.append("Running alignment: \(movie.path)\n")
        job.start(runningStatus: "Running…") { ctx in
            let start = Date()
            _ = try AlignPipeline(options: options, backend: Services.backend, movies: Services.movies, context: ctx).run()
            ctx.log("\nAlignment completed.")
            return String(format: "Completed successfully in %.1f s", Date().timeIntervalSince(start))
        }
    }
}

/// A sheet for drawing the box that image matching or z correction follows, on the maximum projection of the first
/// timepoint.
struct BoxPicker: View {
    let source: URL
    let channel: Int
    let prompt: String
    @Binding var box: CGRect?
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var draft: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt)
            Group {
                if let img = image {
                    GeometryReader { geo in
                        let scale = min(geo.size.width / CGFloat(img.width), geo.size.height / CGFloat(img.height))
                        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
                        ZStack(alignment: .topLeading) {
                            Image(decorative: img, scale: 1).resizable().interpolation(.medium).frame(width: w, height: h)
                            if let r = draft {
                                Rectangle().stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: r.width * scale, height: r.height * scale)
                                    .offset(x: r.minX * scale, y: r.minY * scale)
                            }
                        }
                        .frame(width: w, height: h, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                            func px(_ v: CGFloat, _ limit: Int) -> CGFloat { min(CGFloat(limit), max(0, v / scale)).rounded() }
                            let x0 = px(g.startLocation.x, img.width), x1 = px(g.location.x, img.width)
                            let y0 = px(g.startLocation.y, img.height), y1 = px(g.location.y, img.height)
                            draft = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                        })
                    }
                } else if let f = failure {
                    Text(f).foregroundStyle(.red)
                } else {
                    ProgressView("Loading the first timepoint…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, minHeight: 560)
            HStack {
                if let r = draft { Text("\(Int(r.width)) × \(Int(r.height)) px").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use this box") { box = draft; dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((draft?.width ?? 0) < 16 || (draft?.height ?? 0) < 16)
            }
        }
        .padding()
        .task {
            draft = box
            let url = source, c = channel
            let result: Result<CGImage, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let src = try ProjectionSource(url: url, backend: Services.backend)
                    let img = try src.image(t: 0, p: 0, c: min(c, src.c - 1))
                    let gray = Contrast.autoContrast(img.pixels)
                    guard let provider = CGDataProvider(data: Data(gray) as CFData),
                          let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                           bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(),
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    else { throw DCError("Could not make the preview image") }
                    return cg
                }
            }.value
            switch result {
            case .success(let cg): image = cg
            case .failure(let e): failure = "\(e)"
            }
        }
    }
}
