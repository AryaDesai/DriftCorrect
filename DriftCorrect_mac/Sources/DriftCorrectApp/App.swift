import AppKit
import DCCore
import SwiftUI

@main
struct DriftCorrectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var convertJob = JobRunner()
    @StateObject private var alignJob = JobRunner()
    @StateObject private var manualJob = JobRunner()
    @StateObject private var mask = MaskModel()

    var body: some Scene {
        Window("Drift correction", id: "launcher") {
            LauncherView()
        }
        .windowResizability(.contentSize)

        Window("Convert ND2 to TIFF", id: "convert") {
            ConvertView(job: convertJob)
        }
        Window("Find threshold for masking PSM", id: "mask") {
            MaskView(model: mask)
        }
        Window("XY Centroid Alignment", id: "align") {
            AlignView(job: alignJob)
        }
        Window("Manual XY Shift", id: "manual") {
            ManualXYView(job: manualJob)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the executable runs outside an .app bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard JobRunner.all.contains(where: { $0.isRunning }) else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A tool is still running"
        a.informativeText = "Stop the running work and quit?"
        a.addButton(withTitle: "Stop and Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            JobRunner.all.forEach { $0.cancel() }
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LauncherView: View {
    struct Tool: Identifiable { let title: String; let id: String }
    static let tools = [Tool(title: "Convert ND2 to TIFF", id: "convert"), Tool(title: "Mask embryo", id: "mask"),
                        Tool(title: "Align movie", id: "align"),
                        Tool(title: "Manual XY shift", id: "manual")]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to do?")
            ForEach(LauncherView.tools) { tool in
                Button { openWindow(id: tool.id) } label: {
                    Text(tool.title).frame(maxWidth: .infinity, minHeight: 30)
                }
                .controlSize(.large)
            }
            Text("Compute: \(Services.backend.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }
}
