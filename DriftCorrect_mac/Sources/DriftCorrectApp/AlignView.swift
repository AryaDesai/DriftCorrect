import DCApple
import DCCore
import SwiftUI

/// Front end for the xy alignment (centroid_align_xy_gui.py), by the mask centroid or by image matching, with
/// optional z correction after it.
struct AlignView: View {
    @ObservedObject var job: JobRunner
    @State private var yamlPath = ""
    @State private var fps = 2.0
    @State private var useND2 = false
    @State private var enlargeCanvas = true
    @State private var shiftMode: ShiftMode = .subpixel
    @State private var lowMemory = true

    /// The part of the image that image matching or z correction follows.
    enum Follow: Int { case mask, box, whole }
    /// The box being drawn, for the xy alignment or for the z correction.
    enum BoxTarget: Int, Identifiable { case xy, z; var id: Int { rawValue } }
    static let xyBoxPrompt = "Drag a box over cells that should stay still in xy. This is the first timepoint, before alignment."
    static let zBoxPrompt = "Drag a box over cells that should stay in the same slice. This is the first timepoint, before alignment."
    @State private var channels: [String] = []
    @State private var source: URL?
    @State private var boxTarget: BoxTarget?

    // XY alignment by image matching
    @State private var imageMatching = false
    @State private var xyChannel = 0
    @State private var xyFollow: Follow = .whole
    @State private var xyBox: CGRect?

    // Z correction
    @State private var zCorrect = false
    @State private var zChannel = 0
    @State private var zFollow: Follow = .whole
    @State private var zBox: CGRect?
    @State private var dropLargeShifts = false
    @State private var maximumShift = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                LabeledContent("Threshold YAML:") {
                    PathField(placeholder: "Select a threshold YAML file", path: $yamlPath, types: [.yaml, .yml])
                }
                LabeledContent("Output video speed:") {
                    HStack {
                        TextField("", value: $fps, format: .number.precision(.fractionLength(2))).frame(width: 80)
                        Stepper("", value: $fps, in: 0.01...1000, step: 0.5).labelsHidden()
                        Text("fps")
                    }
                }
                Toggle("Load directly from the raw ND2 file", isOn: $useND2)
                    .toggleStyle(.checkbox)
                    .help("Uses the ND2 path stored in the YAML instead of the per-embryo TIFF.")
                Toggle("Enlarge canvas to prevent clipping", isOn: $enlargeCanvas)
                    .toggleStyle(.checkbox)
                    .help("Runs the default two-pass alignment. This path calculates the shifts first, expands the canvas, then corrects the shift. No edge data is lost. Turning this off may clip edge data, and with z correction it drops slices that leave the stack.")
                Picker("Shift:", selection: $shiftMode) {
                    Text("Sub-pixel (bilinear interpolation)").tag(ShiftMode.subpixel)
                    Text("Whole pixels (no interpolation)").tag(ShiftMode.integer)
                }
                .help("Both run on the GPU. Sub-pixel matches scipy.ndimage.shift(order=1).")
                Toggle("Use low-memory streaming", isOn: $lowMemory)
                    .toggleStyle(.checkbox)
                    .help("Reads frames again in the second pass instead of keeping them in memory. Turn this on if the file is larger than the available RAM.")
                Picker("XY method:", selection: $imageMatching) {
                    Text("Mask centroid").tag(false)
                    Text("Image matching").tag(true)
                }
                .help("Mask centroid centres the centroid of the embryo mask at every timepoint. Image matching compares each timepoint with the one before it and moves it to where the two images differ least.")
                if imageMatching {
                    channelPicker("XY channel:", selection: $xyChannel,
                                  help: "The channel that image matching compares. A nuclear marker is the best choice.")
                    followPicker(selection: $xyFollow, target: .xy, box: xyBox,
                                 help: "The part of the image that must stay still in xy. To follow only some cells, draw a box over them.")
                }
                Toggle("Correct z drift (after xy)", isOn: $zCorrect)
                    .toggleStyle(.checkbox)
                    .help("Compares each timepoint with the previous one and moves whole slices so the tissue stays in the same slice. Empty slices fill the gaps. Writes …_xy_z.ome.tif and a table of the shifts.")
                if zCorrect {
                    channelPicker("Z channel:", selection: $zChannel,
                                  help: "The channel whose pattern is followed in z. A nuclear marker is the best choice.")
                    Toggle("Drop time points with large shifts", isOn: $dropLargeShifts)
                        .toggleStyle(.checkbox)
                    if dropLargeShifts {
                        LabeledContent("Maximum shift (slices):") {
                            TextField("", value: $maximumShift, format: .number).frame(width: 80)
                        }
                    }
                    followPicker(selection: $zFollow, target: .z, box: zBox,
                                 help: "The part of the image that must stay in the same slice. To follow only some cells, draw a box over cells that should not move in z.")
                }
            }
            .disabled(job.isRunning)
            HStack {
                Text("Compute: \(Services.backend.name)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { job.cancel() }.disabled(!job.isRunning)
                Button("Run alignment") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isRunning || yamlPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            JobStatusView(job: job)
            LogView(text: job.log)
        }
        .padding()
        .frame(minWidth: 680, minHeight: 560)
        .onChange(of: yamlPath) { _, _ in loadChannels() }
        .onChange(of: useND2) { _, _ in loadChannels() }
        .onChange(of: zCorrect) { _, on in if on { loadChannels() } }
        .onChange(of: imageMatching) { _, on in if on { loadChannels() } }
        .sheet(item: $boxTarget) { target in
            if let url = source {
                if target == .xy { BoxPicker(source: url, channel: xyChannel, prompt: Self.xyBoxPrompt, box: $xyBox) }
                else { BoxPicker(source: url, channel: zChannel, prompt: Self.zBoxPrompt, box: $zBox) }
            }
        }
    }

    /// A picker of the channels of the file that the YAML file points to.
    @ViewBuilder
    private func channelPicker(_ label: String, selection: Binding<Int>, help: String) -> some View {
        if channels.isEmpty {
            LabeledContent(label) { Text("Select a threshold YAML to list the channels").foregroundStyle(.secondary) }
        } else {
            Picker(label, selection: selection) {
                ForEach(channels.indices, id: \.self) { Text(channels[$0]).tag($0) }
            }
            .help(help)
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
        guard let b = box else { return source == nil ? "Select a threshold YAML first" : "No box yet" }
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

    /// Find the image file that the YAML file points to and list its channels.
    private func loadChannels() {
        guard zCorrect || imageMatching else { return }
        let yaml = expand(yamlPath)
        let nd2 = useND2
        Task.detached(priority: .userInitiated) {
            var names: [String] = []
            var file: URL?
            var threshold = 0
            if let cfg = try? ThresholdConfig.load(yaml) {
                threshold = cfg.parameters.channelIndex
                let url = nd2 ? URL(fileURLWithPath: cfg.sourceFile)
                              : (try? AlignPipeline.resolveTIF(yaml: yaml, sourceFile: cfg.sourceFile).url)
                if let u = url, let src = try? ProjectionSource(url: u, backend: Services.backend) {
                    names = Array(src.channelNames.prefix(src.c))
                    file = u
                }
            }
            // Start on a channel whose name looks like a nuclear marker. Without one, start on the threshold channel.
            let nuclear = names.firstIndex { n in ["mcherry", "h2b", "nuc", "dapi", "hoechst"].contains { n.lowercased().contains($0) } }
            let choice = nuclear ?? min(threshold, max(0, names.count - 1))
            let foundNames = names, foundFile = file
            await MainActor.run {
                if foundFile != source { xyBox = nil; zBox = nil }
                source = foundFile
                if foundNames != channels {
                    channels = foundNames
                    xyChannel = choice
                    zChannel = choice
                }
            }
        }
    }

    private func run() {
        let yaml = expand(yamlPath)
        guard FileManager.default.fileExists(atPath: yaml.path) else {
            showAlert("Invalid YAML file", "Select an existing YAML file.")
            return
        }
        if !["yaml", "yml"].contains(yaml.pathExtension.lowercased()) {
            let a = NSAlert()
            a.messageText = "Unexpected file type"
            a.informativeText = "The selected file does not have a .yaml or .yml extension. Continue anyway?"
            a.addButton(withTitle: "Continue")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        guard fps.isFinite && fps > 0 else { showAlert("Invalid speed", "FPS must be a positive number."); return }
        var o = AlignOptions(yaml: yaml)
        o.useND2 = useND2
        o.fps = fps
        o.enlargeCanvas = enlargeCanvas
        o.shiftMode = shiftMode
        o.lowMemory = lowMemory
        if imageMatching {
            var m = XYMatchOptions()
            if !channels.isEmpty { m.channelIndex = xyChannel }
            guard let r = region(xyFollow, box: xyBox) else {
                showAlert("No box", "Draw a box over the cells to follow in xy, or choose another option."); return
            }
            m.region = r
            o.xyMatching = m
        }
        if zCorrect {
            if dropLargeShifts && (!maximumShift.isFinite || maximumShift <= 0) {
                showAlert("Invalid maximum shift", "Enter a positive number of slices."); return
            }
            var z = ZCorrectionOptions()
            z.maximumStep = dropLargeShifts ? maximumShift : nil
            if !channels.isEmpty { z.channelIndex = zChannel }
            guard let r = region(zFollow, box: zBox) else {
                showAlert("No box", "Draw a box over the cells to follow in z, or choose another option."); return
            }
            z.region = r
            o.zCorrection = z
        }
        let options = o
        job.clearLog()
        job.append("Running alignment: \(yaml.path)\n")
        job.start(runningStatus: "Running…") { ctx in
            let start = Date()
            _ = try AlignPipeline(options: options, backend: Services.backend, movies: Services.movies, context: ctx).run()
            ctx.log("\nAlignment completed.")
            return String(format: "Completed successfully in %.1f s", Date().timeIntervalSince(start))
        }
    }
}

/// Sheet for drawing the box that image matching or z correction follows, on the max projection of the first timepoint.
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
