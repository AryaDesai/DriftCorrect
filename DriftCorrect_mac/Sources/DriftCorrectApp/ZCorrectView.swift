import DCApple
import DCCore
import SwiftUI

/// Z correction of one file without the xy alignment. The file can be one that the Align tool already aligned in xy.
struct ZCorrectView: View {
    @ObservedObject var job: JobRunner
    @State private var filePath = ""
    @State private var yamlPath = ""
    @State private var channels: [String] = []
    @State private var channel = 0
    @State private var follow: AlignView.Follow = .whole
    @State private var box: CGRect?
    @State private var source: URL?
    @State private var showBoxPicker = false
    @State private var dropLargeShifts = false
    @State private var maximumShift = 5.0
    @State private var enlargeStack = true
    @State private var lowMemory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                LabeledContent("Image file:") {
                    PathField(placeholder: "Select an OME-TIFF or ND2 file", path: $filePath, types: [.tiff, .nd2])
                }
                if channels.isEmpty {
                    LabeledContent("Z channel:") {
                        Text("Select an image file to list the channels").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Z channel:", selection: $channel) {
                        ForEach(channels.indices, id: \.self) { Text(channels[$0]).tag($0) }
                    }
                    .help("The channel whose pattern is followed in z. A nuclear marker is the best choice.")
                }
                Picker("Follow:", selection: $follow) {
                    Text("Whole frame").tag(AlignView.Follow.whole)
                    Text("A box I draw").tag(AlignView.Follow.box)
                    Text("Embryo mask").tag(AlignView.Follow.mask)
                }
                .help("The part of the image that must stay in the same slice. The embryo mask needs the threshold YAML file from the Mask tool.")
                if follow == .box {
                    LabeledContent("Box:") {
                        HStack {
                            Button("Draw box…") { showBoxPicker = true }.disabled(source == nil)
                            Text(boxLabel).foregroundStyle(.secondary)
                        }
                    }
                }
                if follow == .mask {
                    LabeledContent("Threshold YAML:") {
                        PathField(placeholder: "Select a threshold YAML file", path: $yamlPath, types: [.yaml, .yml])
                    }
                }
                Toggle("Drop time points with large shifts", isOn: $dropLargeShifts)
                    .toggleStyle(.checkbox)
                if dropLargeShifts {
                    LabeledContent("Maximum shift (slices):") {
                        TextField("", value: $maximumShift, format: .number).frame(width: 80)
                    }
                }
                Toggle("Add empty slices so that no slice is lost", isOn: $enlargeStack)
                    .toggleStyle(.checkbox)
                    .help("The stack becomes deeper by the largest shift in each direction. When this is off, the stack keeps its depth and slices that leave it are dropped.")
                Toggle("Use low-memory streaming", isOn: $lowMemory)
                    .toggleStyle(.checkbox)
                    .help("Reads the frames again for writing instead of keeping them in memory after the measurement. Turn this on if the file is larger than the available RAM.")
            }
            .disabled(job.isRunning)
            HStack {
                Spacer()
                Button("Cancel") { job.cancel() }.disabled(!job.isRunning)
                Button("Correct z drift") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isRunning || filePath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            JobStatusView(job: job)
            LogView(text: job.log)
        }
        .padding()
        .frame(minWidth: 680, minHeight: 520)
        .onChange(of: filePath) { _, _ in loadChannels() }
        .sheet(isPresented: $showBoxPicker) {
            if let url = source { BoxPicker(source: url, channel: channel, prompt: AlignView.zBoxPrompt, box: $box) }
        }
    }

    private var boxLabel: String {
        guard let b = box else { return source == nil ? "Select an image file first" : "No box yet" }
        return "x \(Int(b.minX)), y \(Int(b.minY)), \(Int(b.width)) × \(Int(b.height)) px"
    }

    /// List the channels of the selected file. The picker starts on a channel whose name looks like a nuclear marker.
    private func loadChannels() {
        let url = expand(filePath)
        Task.detached(priority: .userInitiated) {
            var names: [String] = []
            var file: URL?
            if FileManager.default.fileExists(atPath: url.path), let src = try? ProjectionSource(url: url, backend: Services.backend) {
                names = Array(src.channelNames.prefix(src.c))
                file = url
            }
            let nuclear = names.firstIndex { n in ["mcherry", "h2b", "nuc", "dapi", "hoechst"].contains { n.lowercased().contains($0) } }
            let foundNames = names, foundFile = file
            await MainActor.run {
                if foundFile != source { box = nil }
                source = foundFile
                if foundNames != channels {
                    channels = foundNames
                    channel = nuclear ?? 0
                }
            }
        }
    }

    private func run() {
        let file = expand(filePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            showAlert("Invalid image file", "Select an existing OME-TIFF or ND2 file.")
            return
        }
        if dropLargeShifts && (!maximumShift.isFinite || maximumShift <= 0) {
            showAlert("Invalid maximum shift", "Enter a positive number of slices."); return
        }
        var o = ZCorrectOptions(input: file)
        o.z.maximumStep = dropLargeShifts ? maximumShift : nil
        o.enlargeStack = enlargeStack
        o.lowMemory = lowMemory
        if !channels.isEmpty { o.z.channelIndex = channel }
        switch follow {
        case .whole: o.z.region = .wholeFrame
        case .box:
            guard let b = box else { showAlert("No box", "Draw a box over the cells to follow, or choose another option."); return }
            o.z.region = .box(x: Int(b.minX), y: Int(b.minY), width: Int(b.width), height: Int(b.height))
        case .mask:
            let yaml = expand(yamlPath)
            guard FileManager.default.fileExists(atPath: yaml.path) else {
                showAlert("Invalid YAML file", "Following the embryo mask needs the threshold YAML file from the Mask tool.")
                return
            }
            o.yaml = yaml
            o.z.region = .embryoMask
        }
        let options = o
        job.clearLog()
        job.append("Correcting z drift: \(file.path)\n")
        job.start(runningStatus: "Running…") { ctx in
            let start = Date()
            _ = try ZCorrectPipeline.run(options: options, backend: Services.backend, context: ctx)
            ctx.log("\nZ correction completed.")
            return String(format: "Completed successfully in %.1f s", Date().timeIntervalSince(start))
        }
    }
}
