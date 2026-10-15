import DCCore
import SwiftUI

/// Front end for the ND2 → TIFF conversion (nd2_to_tif_gui.py).
struct ConvertView: View {
    @ObservedObject var job: JobRunner
    @State private var inputFolder = ""
    @State private var outputFolder = ""
    @State private var allPositions = true
    @State private var position = 0
    @State private var parallel = true
    @State private var concatOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Converts ND2 files in filename order, then joins each embryo's TIFFs across time.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("ND2 folder:") { PathField(placeholder: "", path: $inputFolder, directories: true) }
                LabeledContent("Output folder:") {
                    PathField(placeholder: "Default: tifs subfolder inside the input folder", path: $outputFolder, directories: true)
                }
                Toggle("All embryo positions", isOn: $allPositions).toggleStyle(.checkbox)
                LabeledContent("Position index:") {
                    Stepper(value: $position, in: 0...1_000_000) { TextField("", value: $position, format: .number).frame(width: 80) }
                        .disabled(allPositions)
                        .help("Zero-based embryo position: 0 is the first position.")
                }
                Toggle("Process positions in parallel", isOn: $parallel)
                    .toggleStyle(.checkbox)
                    .disabled(!allPositions)
                    .help("Reads each ND2 file once and writes all positions at the same time.")
                Toggle("Only concatenate existing TIFFs (skip conversion)", isOn: $concatOnly)
                    .toggleStyle(.checkbox)
                    .help("Joins the per-file TIFFs already in the output folder without reading the ND2 files.")
            }
            .disabled(job.isRunning)
            HStack {
                Spacer()
                if job.isRunning { Button("Cancel") { job.cancel() } }
                Button("Convert") { run() }.keyboardShortcut(.defaultAction).disabled(job.isRunning)
            }
            JobStatusView(job: job)
            LogView(text: job.log)
        }
        .padding()
        .frame(minWidth: 650, minHeight: 460)
    }

    private func run() {
        let folder = expand(inputFolder)
        var isDir: ObjCBool = false
        guard !inputFolder.trimmingCharacters(in: .whitespaces).isEmpty,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            showAlert("Select input", "Select an existing ND2 folder.")
            return
        }
        guard concatOnly || !globFiles(folder, pattern: "*.nd2").isEmpty else {
            showAlert("No ND2 files", "The selected folder contains no .nd2 files.")
            return
        }
        var options = ConvertOptions(folder: folder)
        if !outputFolder.trimmingCharacters(in: .whitespaces).isEmpty { options.outputDirectory = expand(outputFolder) }
        options.position = allPositions ? nil : position
        options.parallel = parallel
        options.concatOnly = concatOnly
        let opts = options
        job.clearLog()
        job.start(runningStatus: "Converting…") { ctx in
            let start = Date()
            try ConvertPipeline(options: opts, context: ctx).run()
            return String(format: "Completed in %.1f s", Date().timeIntervalSince(start))
        }
    }
}
