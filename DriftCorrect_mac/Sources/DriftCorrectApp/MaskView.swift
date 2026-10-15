import Charts
import DCCore
import SwiftUI

/// The Mask tool window (find_threshold.py).
struct MaskView: View {
    @ObservedObject var model: MaskModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView { controls.padding(.trailing, 6) }
                .frame(width: 330)
            VSplitView {
                imagePanel.frame(minHeight: 200)
                histogramPanel.frame(minHeight: 130)
            }
        }
        .padding()
        .frame(minWidth: 900, minHeight: 700)
        .onDisappear { model.stopPlaying() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find threshold for masking PSM").font(.title3.bold())
            Text("Red overlay = mask  |  + = centroid").foregroundStyle(.secondary)
            PathField(placeholder: "ND2 or TIF file", path: $model.path, types: [.nd2, .tiff]) { model.load() }
            Button("Load") { model.load() }

            if model.source != nil {
                Picker("Channel", selection: $model.channelIndex) {
                    ForEach(Array(model.channelNames.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
                if model.P > 1 {
                    HStack {
                        Button("Prev") { model.previousEmbryo() }
                        Text("Embryo \(model.embryo) / \(model.P - 1)")
                        Button("Next") { model.nextEmbryo() }
                    }
                }
                intSlider("T", value: $model.t, range: 0...max(0, model.T - 1))
            }
            intSlider("Sigma", value: $model.sigma, range: 1...100)

            Text("Threshold Method")
            Picker("", selection: $model.method) {
                ForEach(MaskMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()

            if model.method == .multiotsu {
                Stepper("Levels: \(model.levels)", value: $model.levels, in: 2...MultiOtsu.maxLevels)
                HStack(spacing: 6) {
                    ForEach(0..<model.levelChecks.count, id: \.self) { i in
                        Toggle("\(i)", isOn: Binding(get: { model.levelChecks[i] }, set: { _ in model.toggleLevel(i) }))
                            .toggleStyle(.checkbox)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Percentile: \(PyFormat.repr(model.percentile))")
                Slider(value: Binding(get: { Double(model.percentileSteps) }, set: { model.percentileSteps = Int($0.rounded()) }),
                       in: 20...199, step: 1)
            }
            .disabled(model.method == .multiotsu)
            Toggle("Invert Mask", isOn: $model.invert).toggleStyle(.checkbox)

            Divider()
            Button("Apply to current T") { model.applyToCurrentT() }
            HStack {
                Text("Range")
                TextField("", value: $model.rangeStart, format: .number).frame(width: 60)
                TextField("", value: $model.rangeEnd, format: .number).frame(width: 60)
                Button("Apply") { model.applyToRange() }
            }
            Text(model.customizedText).foregroundStyle(.secondary)

            Divider()
            HStack {
                Button(model.playing ? "Pause" : "Play") { model.togglePlay() }
                Text("Delay (s):")
                TextField("", value: $model.delay, format: .number.precision(.fractionLength(1))).frame(width: 50)
                Stepper("", value: $model.delay, in: 0.1...5.0, step: 0.1).labelsHidden()
            }

            Divider()
            Button("Save thresholds to YAML") { model.save() }
            Text(model.status).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func intSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(value.wrappedValue)")
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1)
                .disabled(range.upperBound <= range.lowerBound)
        }
    }

    // MARK: Image

    private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.header).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            ZStack {
                Color.black.opacity(0.05)
                if let img = model.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("Load a file to display it").foregroundStyle(.secondary)
                }
            }
            Text(model.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Histogram

    private var histogramPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gaussian-smoothed intensity histogram")
            if let h = model.histogram {
                HistogramChart(histogram: h)
                Text(h.note).font(.caption).fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
                Text("Load a file to display its histogram").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.top, 6)
    }
}

struct HistogramChart: View {
    let histogram: MaskPreview.Histogram

    struct Bar: Identifiable {
        let id: Int
        let x0: Double, x1: Double, y0: Double, y1: Double
        let series: String
    }

    var bars: [Bar] {
        var out: [Bar] = []
        let edges = histogram.edges.map(Double.init)
        var base = [Double](repeating: 0, count: max(0, edges.count - 1))
        var id = 0
        for s in histogram.series {
            for (i, c) in s.counts.enumerated() where c > 0 && i < base.count {
                out.append(Bar(id: id, x0: edges[i], x1: edges[i + 1], y0: base[i], y1: base[i] + Double(c), series: s.label))
                base[i] += Double(c)
                id += 1
            }
        }
        return out
    }

    func color(_ c: RGB) -> Color { Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }

    var body: some View {
        let lo = Double(histogram.edges.first ?? 0), hi = Double(histogram.edges.last ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(bars) { b in
                    RectangleMark(xStart: .value("Intensity", b.x0), xEnd: .value("Intensity", b.x1),
                                  yStart: .value("Pixel count", b.y0), yEnd: .value("Pixel count", b.y1))
                        .foregroundStyle(by: .value("Series", b.series))
                }
                ForEach(Array(histogram.lines.enumerated()), id: \.offset) { _, line in
                    RuleMark(x: .value("Threshold", line.value))
                        .foregroundStyle(color(line.color))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: line.dotted ? [2, 3] : [6, 3]))
                }
            }
            .chartForegroundStyleScale(domain: histogram.series.map { $0.label },
                                       range: histogram.series.map { color($0.color) })
            .chartXScale(domain: lo...max(hi, lo + 1e-6))
            .chartXAxisLabel("Gaussian-smoothed intensity")
            .chartYAxisLabel("Pixel count")
            .chartLegend(position: .top, alignment: .center)
            .aspectRatio(1, contentMode: .fit)
            ForEach(Array(histogram.lines.enumerated()).filter { !$0.element.label.isEmpty }, id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Rectangle().fill(color(line.color)).frame(width: 18, height: 2)
                    Text(line.label).font(.caption)
                }
            }
        }
    }
}
