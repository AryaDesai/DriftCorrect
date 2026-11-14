import DCApple
import DCCore
import SwiftUI

/// The Export window. It writes MP4 movies of an OME-TIFF or ND2 file, such as the input of the alignment or its
/// output. Each setting shows an explanation when the pointer rests on it.
struct ExportView: View {
    @ObservedObject var job: JobRunner

    // These hold the files and the channel. The channel is -1 when every channel gets its own movie.
    @State private var moviePath = ""
    @State private var comparePath = ""
    @State private var channels: [String] = []
    @State private var channel = -1
    // These hold the view. `slices` is the number of slices of the movie, which limits the slice number.
    @State private var slices = 0
    @State private var oneSlice = false
    @State private var slice = 1
    // These hold the playback speed and the encoding.
    @State private var fps = 2.0
    @State private var wholeMovieContrast = true
    @State private var codec: MovieCodec = .hevc
    @State private var quality = 65.0

    private var hasMovie: Bool { !moviePath.trimmingCharacters(in: .whitespaces).isEmpty }

    // Each setting shows its explanation when the pointer rests on it.
    static let movieHelp = "The OME-TIFF or ND2 file to export. The movies are saved next to it."
    static let channelHelp = "All channels writes one movie for each channel. A single channel writes one movie."
    static let viewHelp = "Maximum projection shows the brightest value along z at each pixel. One slice shows a single slice, counted from 1, which is the way to see z correction."
    static let compareHelp = "A second OME-TIFF or ND2 file shown to the right of the first one, such as the unaligned movie next to the aligned one. Each side keeps its own size and brightness. Leave this empty for a movie of one file."
    static let fpsHelp = "The playback speed in frames per second. Each timepoint is one frame."
    static let contrastHelp = "Whole movie sets the brightness once from timepoints spread over the movie, so a cell keeps its brightness from frame to frame. Each frame sets the brightness of every frame on its own, which shows dim frames better and can flicker."
    static let codecHelp = "HEVC gives files about half the size of H.264 at the same quality. H.264 plays in more programs, such as older versions of PowerPoint and some web tools."
    static let qualityHelp = "From 1 to 100. Higher values keep more detail and give larger files. The default is 65."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                LabeledContent("Movie:") {
                    PathField(placeholder: "Select an OME-TIFF or ND2 file", path: $moviePath, types: [.tiff, .nd2])
                }
                .help(Self.movieHelp)
                Picker("Channel:", selection: $channel) {
                    Text("All channels").tag(-1)
                    ForEach(channels.indices, id: \.self) { Text(channels[$0]).tag($0) }
                }
                .help(Self.channelHelp)
                Picker("View:", selection: $oneSlice) {
                    Text("Maximum projection").tag(false)
                    Text("One slice").tag(true)
                }
                .help(Self.viewHelp)
                if oneSlice {
                    LabeledContent("Slice:") {
                        Stepper(value: $slice, in: 1...max(1, slices)) {
                            HStack {
                                TextField("", value: $slice, format: .number).frame(width: 60)
                                if slices > 0 { Text("of \(slices)").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .help(Self.viewHelp)
                }
                LabeledContent("Compare with:") {
                    PathField(placeholder: "Optional second movie shown on the right", path: $comparePath, types: [.tiff, .nd2])
                }
                .help(Self.compareHelp)
                LabeledContent("Speed:") {
                    HStack {
                        TextField("", value: $fps, format: .number.precision(.fractionLength(2))).frame(width: 80)
                        Text("fps")
                    }
                }
                .help(Self.fpsHelp)
                Picker("Contrast:", selection: $wholeMovieContrast) {
                    Text("Whole movie").tag(true)
                    Text("Each frame").tag(false)
                }
                .help(Self.contrastHelp)
                Picker("Codec:", selection: $codec) {
                    Text("HEVC").tag(MovieCodec.hevc)
                    Text("H.264").tag(MovieCodec.h264)
                }
                .help(Self.codecHelp)
                LabeledContent("Quality:") {
                    HStack {
                        Slider(value: $quality, in: 1...100, step: 1).frame(width: 200)
                        Text("\(Int(quality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                }
                .help(Self.qualityHelp)
            }
            .disabled(job.isRunning)
            HStack {
                Spacer()
                Button("Cancel") { job.cancel() }.disabled(!job.isRunning)
                Button("Export") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isRunning || !hasMovie)
            }
            JobStatusView(job: job)
            LogView(text: job.log)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 560)
        .onChange(of: moviePath) { _, _ in movieChanged() }
    }

    /// List the channels and count the slices of the selected movie.
    private func movieChanged() {
        let url = expand(moviePath)
        Task.detached(priority: .userInitiated) {
            var names: [String] = []
            var depth = 0
            if FileManager.default.fileExists(atPath: url.path),
               let src: FrameSource = url.pathExtension.lowercased() == "nd2" ? try? ND2Source(url: url) : try? TIFFSource(url: url) {
                names = Array(src.metadata.channelNames.prefix(src.c))
                depth = src.z
            }
            let foundNames = names, foundDepth = depth
            await MainActor.run {
                if foundNames != channels { channels = foundNames; channel = -1 }
                slices = foundDepth
                slice = min(max(1, slice), max(1, foundDepth))
            }
        }
    }

    private func run() {
        let movie = expand(moviePath)
        guard FileManager.default.fileExists(atPath: movie.path) else {
            showAlert("Invalid movie", "Select an existing OME-TIFF or ND2 file."); return
        }
        var compare: URL?
        if !comparePath.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = expand(comparePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                showAlert("Invalid movie to compare", "Select an existing OME-TIFF or ND2 file, or leave the field empty."); return
            }
            compare = url
        }
        guard fps.isFinite && fps > 0 else { showAlert("Invalid speed", "The speed must be a positive number."); return }
        var o = ExportOptions(source: movie)
        if channel >= 0 { o.channelIndex = channel }
        o.slice = oneSlice ? slice : nil
        o.fps = fps
        o.wholeMovieContrast = wholeMovieContrast
        o.compare = compare
        let options = o, factory = MovieFileFactory(codec: codec, quality: quality)
        job.clearLog()
        job.append("Exporting: \(movie.path)\n")
        job.start(runningStatus: "Exporting…") { ctx in
            let start = Date()
            _ = try ExportPipeline.run(options: options, backend: Services.backend, movies: factory, context: ctx)
            return String(format: "Completed successfully in %.1f s", Date().timeIntervalSince(start))
        }
    }
}
