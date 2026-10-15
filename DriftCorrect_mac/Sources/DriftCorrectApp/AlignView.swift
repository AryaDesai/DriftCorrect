import DCApple
import DCCore
import SwiftUI

/// Front end for XY centroid alignment (centroid_align_xy_gui.py).
struct AlignView: View {
    @ObservedObject var job: JobRunner
    @State private var yamlPath = ""
    @State private var fps = 2.0
    @State private var useND2 = false
    @State private var enlargeCanvas = true
    @State private var shiftMode: ShiftMode = .subpixel
    @State private var lowMemory = true

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
                    .help("Runs the default two-pass alignment. This path calculates the shifts first, expands the canvas, then corrects the shift. No edge data is lost. Turning this off may clip edge data.")
                Picker("Shift:", selection: $shiftMode) {
                    Text("Sub-pixel (bilinear interpolation)").tag(ShiftMode.subpixel)
                    Text("Whole pixels (no interpolation)").tag(ShiftMode.integer)
                }
                .help("Both run on the GPU. Sub-pixel matches scipy.ndimage.shift(order=1).")
                Toggle("Use low-memory streaming", isOn: $lowMemory)
                    .toggleStyle(.checkbox)
                    .help("Reads frames again in the second pass instead of keeping them in memory. Turn this on if the file is larger than the available RAM.")
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
        .frame(minWidth: 680, minHeight: 480)
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
