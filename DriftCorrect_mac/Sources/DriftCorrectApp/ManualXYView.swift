import DCCore
import SwiftUI

struct ManualXYView: View {
    @ObservedObject var job: JobRunner
    @StateObject private var model = ManualXYModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PathField(placeholder: "OME-TIFF or threshold YAML", path: $model.path,
                          types: [.tiff, .yaml, .yml]) { model.load() }
                Button("Load") { model.load() }
            }
            .disabled(job.isRunning || model.isLoading)

            if let source = model.source {
                controls(source)
                    .disabled(job.isRunning || model.isLoading)
                HStack(spacing: 12) {
                    slice(title: "Reference · T \(model.t)", z: $model.referenceZ,
                          image: model.referenceImage, point: model.referencePoint, reference: true, count: source.z)
                    slice(title: "Moving · T \(model.t + 1)", z: $model.movingZ,
                          image: model.movingImage, point: model.movingPoint, reference: false, count: source.z)
                }
                .disabled(job.isRunning || model.isLoading)
                HStack {
                    Button("Preview correction") { model.preview() }.disabled(!model.canPreview)
                    Button("Accept correction") { model.accept() }.disabled(!model.canAccept)
                    Button("Reset selection / preview") { model.refresh() }
                        .disabled(model.pending == nil && model.referencePoint == nil && model.movingPoint == nil)
                    Button("Remove correction here") { model.removeCorrection() }.disabled(!model.hasCorrection)
                    Spacer()
                    Text("\(model.corrections.count) corrected boundaries").foregroundStyle(.secondary)
                }
                .disabled(job.isRunning || model.isLoading)
                if let delta = model.pending ?? model.corrections[model.t + 1] {
                    Text("Boundary T \(model.t) → \(model.t + 1): ΔX \(Double(delta.x), specifier: "%.2f"), ΔY \(Double(delta.y), specifier: "%.2f") px")
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text("Load a TIFF to browse adjacent timepoints and select matching landmarks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Toggle("Enlarge canvas", isOn: $model.enlargeCanvas).toggleStyle(.checkbox)
                Picker("Shift", selection: $model.shiftMode) {
                    Text("Sub-pixel").tag(ShiftMode.subpixel)
                    Text("Whole pixels").tag(ShiftMode.integer)
                }.frame(width: 210)
                Toggle("Low-memory streaming", isOn: $model.lowMemory).toggleStyle(.checkbox)
                TextField("FPS", value: $model.fps, format: .number).frame(width: 55)
                Text("fps")
            }
            .disabled(job.isRunning || model.isLoading)
            HStack {
                Text("Timepoints and Z slices are numbered from 0.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel export") { job.cancel() }.disabled(!job.isRunning)
                Button("Export corrected TIFF + movies") { model.export(job: job) }
                    .disabled(job.isRunning || model.isLoading || model.source == nil || model.corrections.isEmpty || model.pending != nil)
            }
            JobStatusView(job: job)
            LogView(text: job.log).frame(height: 75)
        }
        .padding()
        .frame(minWidth: 1100, minHeight: 780)
    }

    private func controls(_ source: TIFFStack) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button("Previous") { model.t -= 1 }.disabled(model.t == 0)
                Slider(value: Binding(get: { Double(model.t) }, set: { model.t = Int($0.rounded()) }),
                       in: 0...Double(max(1, source.t - 2)), step: 1)
                    .disabled(source.t <= 2)
                Button("Next") { model.t += 1 }.disabled(model.t >= source.t - 2)
                Text("T \(model.t) → \(model.t + 1)").monospacedDigit().frame(width: 120)
            }
            HStack {
                Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("Channel", selection: $model.channel) {
                    ForEach(0..<source.c, id: \.self) { c in
                        Text(c < source.metadata.channelNames.count ? source.metadata.channelNames[c] : "Ch\(c)").tag(c)
                    }
                }.frame(width: 230)
                Text("Display smoothing: \(model.sigma, specifier: "%.1f") px")
                Slider(value: $model.sigma, in: 0...20, step: 0.5).frame(width: 130)
            }
        }
    }

    private func slice(title: String, z: Binding<Int>, image: CGImage?, point: CGPoint?, reference: Bool, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ManualSliceView(image: image, point: point) { model.select($0, reference: reference) }
                .allowsHitTesting(!model.isRendering && model.pending == nil)
                .frame(minHeight: 280)
            HStack {
                Text("Z \(z.wrappedValue) / \(count - 1)").monospacedDigit().frame(width: 95, alignment: .leading)
                Slider(value: Binding(get: { Double(z.wrappedValue) }, set: { z.wrappedValue = Int($0.rounded()) }),
                       in: 0...Double(max(1, count - 1)), step: 1)
                    .disabled(count <= 1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Click coordinates use the fitted image rectangle, excluding letterboxing.
/// Both panes have the same canvas dimensions and therefore the same scale.
private struct ManualSliceView: View {
    let image: CGImage?
    let point: CGPoint?
    let select: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: size.width, height: size.height)
                        if let point {
                            Path { path in
                                let x = (point.x + 0.5) * scale, y = (point.y + 0.5) * scale
                                path.move(to: CGPoint(x: x - 7, y: y)); path.addLine(to: CGPoint(x: x + 7, y: y))
                                path.move(to: CGPoint(x: x, y: y - 7)); path.addLine(to: CGPoint(x: x, y: y + 7))
                            }
                            .stroke(Color.yellow, lineWidth: 1.5)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard scale > 0, location.x >= 0, location.y >= 0,
                              location.x < size.width, location.y < size.height else { return }
                        select(CGPoint(x: max(0, min(CGFloat(image.width - 1), location.x / scale - 0.5)),
                                       y: max(0, min(CGFloat(image.height - 1), location.y / scale - 0.5))))
                    }
                } else {
                    Text("Loading slice…").foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
