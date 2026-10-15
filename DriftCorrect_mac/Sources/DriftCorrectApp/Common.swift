import AppKit
import DCApple
import DCCore
import SwiftUI
import UniformTypeIdentifiers

/// Objects shared by all windows.
enum Services {
    /// Metal on Apple silicon, with the CPU reference as fallback.
    static let backend: ComputeBackend = MetalBackend.best()
    static let movies: MovieWriterFactory = HEVCMovieFactory()
}

/// Lines and progress sent from worker threads, collected for the main thread.
final class PendingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var progress: (String, Int, Int)?

    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func setProgress(_ phase: String, _ current: Int, _ total: Int) { lock.lock(); progress = (phase, current, total); lock.unlock() }

    func take() -> ([String], (String, Int, Int)?) {
        lock.lock(); defer { lock.unlock() }
        let out = (lines, progress)
        lines.removeAll()
        progress = nil
        return out
    }
}

/// Runs one pipeline at a time on a background thread and publishes its log,
/// progress and state. Jobs belong to the app, not to a window, so closing a
/// window does not stop a run; quitting asks first.
@MainActor
final class JobRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var status = "Ready"
    @Published private(set) var log = ""
    @Published private(set) var phase = ""
    @Published private(set) var fraction: Double = 0

    private var context: RunContext?
    private let pending = PendingOutput()
    private var flushTimer: Timer?
    private static let maxLines = 5000

    static var all: [JobRunner] = []

    init() { JobRunner.all.append(self) }

    func clearLog() { log = "" }

    func append(_ text: String) {
        log += text
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > JobRunner.maxLines {
            lines.removeFirst(lines.count - JobRunner.maxLines)
            log = lines.joined(separator: "\n")
        }
    }

    /// Start `work` with a fresh RunContext. `done` runs on the main actor.
    func start(runningStatus: String, work: @escaping @Sendable (RunContext) throws -> String,
               done: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        status = runningStatus
        phase = ""
        fraction = 0
        let pending = self.pending
        let ctx = RunContext(log: { pending.add($0) }, progress: { pending.setProgress($0, $1, $2) })
        context = ctx
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<String, Error> = Result { try work(ctx) }
            Task { @MainActor in
                self.finish(outcome)
                done?(outcome.isSuccess)
            }
        }
    }

    private func finish(_ outcome: Result<String, Error>) {
        flush()
        flushTimer?.invalidate()
        flushTimer = nil
        isRunning = false
        context = nil
        switch outcome {
        case .success(let message):
            status = message
            fraction = 1
        case .failure(let error):
            if error is CancelledError {
                status = "Stopped"
                append("\nStopped by user.\n")
            } else {
                status = "Failed — see log"
                append("\nError: \(error)\n")
            }
        }
    }

    func cancel() {
        context?.cancel()
        status = "Stopping…"
    }

    private func flush() {
        let (lines, p) = pending.take()
        if !lines.isEmpty { append(lines.map { $0 + "\n" }.joined()) }
        if let (ph, c, t) = p {
            phase = "\(ph): \(c)/\(t)"
            fraction = t > 0 ? Double(c) / Double(t) : 0
        }
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

/// Text field with a Browse button (NSOpenPanel).
struct PathField: View {
    @AppStorage("lastBrowseDirectory") private var lastBrowseDirectory = ""
    let placeholder: String
    @Binding var path: String
    var directories = false
    var types: [UTType] = []
    var onPick: (() -> Void)? = nil

    var body: some View {
        HStack {
            TextField(placeholder, text: $path)
                .textFieldStyle(.roundedBorder)
            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directories
                panel.canChooseFiles = !directories
                panel.allowsMultipleSelection = false
                if !types.isEmpty { panel.allowedContentTypes = types }
                var isDirectory: ObjCBool = false
                if !lastBrowseDirectory.isEmpty,
                   FileManager.default.fileExists(atPath: lastBrowseDirectory, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: lastBrowseDirectory, isDirectory: true)
                } else if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let current = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    panel.directoryURL = directories ? current : current.deletingLastPathComponent()
                }
                if panel.runModal() == .OK, let url = panel.url {
                    lastBrowseDirectory = (directories ? url : url.deletingLastPathComponent()).path
                    path = url.path
                    onPick?()
                }
            }
        }
    }
}

/// Scrolling, selectable log text that follows new output.
struct LogView: View {
    let text: String
    var placeholder = "Processing output will appear here."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// Status line with progress bar.
struct JobStatusView: View {
    @ObservedObject var job: JobRunner
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.status)
            if job.isRunning {
                ProgressView(value: job.fraction) { Text(job.phase).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

extension UTType {
    static let nd2 = UTType(filenameExtension: "nd2") ?? .data
    static let yaml = UTType(filenameExtension: "yaml") ?? .plainText
    static let yml = UTType(filenameExtension: "yml") ?? .plainText
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath).standardizedFileURL
}

func showAlert(_ title: String, _ message: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.alertStyle = .warning
    a.runModal()
}
