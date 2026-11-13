import DCApple
import DCCore
import SwiftUI

/// The Alignment window. It corrects a movie in xy and z, in xy only, or in z only. The user picks a movie and a
/// channel and runs. When the chosen settings use the embryo mask, the Mask window opens from here. The settings
/// that change how the correction works are under Advanced options, each with an explanation.
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
    @State private var centroidMethod = false
    @State private var xyFollow: Follow = .whole
    @State private var xyBox: CGRect?
    @State private var hold = true
    @State private var smoothing = 10.0
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
    /// The embryo mask is needed for the centroid method, for holding the body, and for following the mask.
    private var needsMask: Bool {
        (doesXY && (centroidMethod || hold || xyFollow == .mask)) || (doesZ && zFollow == .mask)
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
                if hasMovie && needsMask && !hasMask { Text("Make the mask first").font(.caption).foregroundStyle(.secondary) }
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

    /// A short explanation shown under a setting.
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var channelPicker: some View {
        if channels.isEmpty {
            LabeledContent("Channel:") { Text("Select a movie to list the channels").foregroundStyle(.secondary) }
        } else {
            Picker("Channel:", selection: $channel) {
                ForEach(channels.indices, id: \.self) { Text(channels[$0]).tag($0) }
            }
            note("The channel whose pattern is followed. A nuclear marker is the best choice, because its pattern stays the same from one timepoint to the next.")
        }
    }

    @ViewBuilder
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
        note("These settings use the embryo mask. Make mask opens the threshold window with a suggested threshold. Adjust it, save, and the saved file appears here. You can also browse to a threshold YAML file you saved before.")
    }

    @ViewBuilder
    private var advanced: some View {
        if doesXY {
            Section("XY") {
                Picker("Method:", selection: $centroidMethod) {
                    Text("Image matching").tag(false)
                    Text("Mask centroid").tag(true)
                }
                note("Image matching compares each timepoint with the one before it. It tries shifts and small turns and keeps the one where the two images differ least. Mask centroid moves the centre of the embryo mask to the middle of the frame, without turning.")
                if !centroidMethod {
                    followPicker(selection: $xyFollow, target: .xy, box: xyBox)
                    note("The part of the image that the matching compares. Whole frame uses every pixel. Embryo mask uses the tissue only. A box follows only the cells inside it.")
                    Toggle("Hold the body in place with the embryo mask", isOn: $hold).toggleStyle(.checkbox)
                    note("Matching alone follows the cells. When cells move through the body, the frame slowly travels with them. With this on, the embryo mask keeps the body in the middle of the frame and pointing the same way.")
                    if hold {
                        LabeledContent("Averaging (timepoints):") { TextField("", value: $smoothing, format: .number).frame(width: 80) }
                        note("The mask is rough at a single timepoint, so its position and direction are averaged over about this many timepoints. A small value follows the mask closely and can wobble. A large value is steadier and lets the body glide further before it is pulled back.")
                    }
                    LabeledContent("Largest turn (degrees):") { TextField("", value: $maximumAngle, format: .number).frame(width: 80) }
                    note("The largest turn between two neighbouring timepoints that the matching looks for. With 0 it only shifts and never turns.")
                }
            }
        }
        if doesZ {
            Section("Z") {
                followPicker(selection: $zFollow, target: .z, box: zBox)
                note("The part of the image that must stay in the same slice. To follow only some cells, draw a box over cells that should not move in z.")
                LabeledContent("Also compare this many timepoints back:") {
                    Stepper("\(span)", value: $span, in: 1...50)
                }
                note("A slow movement is too small to measure between neighbouring timepoints. Each timepoint is also compared with an earlier one, where the movement has added up. With 1 only neighbours are compared.")
                Toggle("Drop time points with large shifts", isOn: $dropLargeShifts).toggleStyle(.checkbox)
                if dropLargeShifts {
                    LabeledContent("Maximum shift (slices):") { TextField("", value: $maximumShift, format: .number).frame(width: 80) }
                }
                note("Leaves out timepoints whose z movement from the timepoint before them is larger than the maximum, for example after the stage was moved. Later timepoints are still corrected for that movement.")
            }
        }
        Section("Output") {
            Toggle("Enlarge the canvas and the stack so that nothing is cut off", isOn: $enlargeCanvas).toggleStyle(.checkbox)
            note("Adds empty pixels around the frame and empty slices to the stack, so that data moved by the correction stays in the file. With this off the file keeps its size and data that moves outside is lost.")
            if doesXY {
                LabeledContent("Movie speed:") {
                    HStack {
                        TextField("", value: $fps, format: .number.precision(.fractionLength(2))).frame(width: 80)
                        Text("fps")
                    }
                }
                note("The playback speed of the MP4 movies that are written next to the corrected file.")
            }
            Toggle("Use low-memory streaming", isOn: $lowMemory).toggleStyle(.checkbox)
            note("Reads the movie from disk a second time when writing, instead of keeping it in memory. Leave this on when the file is larger than the available memory. Turning it off is faster for small files.")
        }
    }

    /// A picker of the region to follow, with a button to draw the box when the box is chosen.
    @ViewBuilder
    private func followPicker(selection: Binding<Follow>, target: BoxTarget, box: CGRect?) -> some View {
        Picker("Follow:", selection: selection) {
            Text("Whole frame").tag(Follow.whole)
            Text("Embryo mask").tag(Follow.mask)
            Text("A box I draw").tag(Follow.box)
        }
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
                showAlert("No mask", "These settings use the embryo mask. Make the mask first, or select a threshold YAML file."); return
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
        if !centroidMethod {
            var m = XYMatchOptions()
            if !channels.isEmpty { m.channelIndex = channel }
            guard let r = region(xyFollow, box: xyBox) else {
                showAlert("No box", "Draw a box over the cells to follow in xy, or choose another option."); return
            }
            m.region = r
            m.holdInPlace = hold
            m.smoothing = smoothing
            m.maximumAngle = maximumAngle
            o.xyMatching = m
        }
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
