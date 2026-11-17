// Development-only .app fixture. Normal NSApplication run loop, synthetic Store,
// no production Library, model invocation, security flags or shipping entry.
import AppKit
import SwiftUI
import Foundation
import HarcDomain
import HarcStore
@testable import HarcUI

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var controller: SelectedProjectPreviewController?
    var terminationSignal: DispatchSourceSignal?
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("harc-preview-standalone-" + UUID().uuidString)
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApplication.shared.terminate(nil) }
        terminationSignal?.resume()
        Task {
            do { try await prepare() }
            catch { print("Synthetic fixture failed: \(error)"); NSApplication.shared.terminate(nil) }
        }
    }
    func prepare() async throws {
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let source = "If approval arrives, repair the entrance.\nCorrection: approval is blocked.\n"
            + (1...100).map { "Synthetic context line \($0): no completed work is established." }.joined(separator: "\n")
            + "\nFINAL SOURCE CORRECTION: approval remains blocked."
        let recording = try await store.upsert(Recording(wavPath: root.appendingPathComponent("unused.wav").path,
            startedAt: Date(), transcriptText: source))
        let project = try await store.createKnowledgeProject(name: "Entrance")
        let meta = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: meta.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x73, count: 32)), hostStateID: .random())
        let briefed = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
            brief: "Repair the entrance after approval.", expectedHost: store.libraryMetadata())
        let controller = SelectedProjectPreviewController(store: store, externalChanges: NotificationCenter())
        self.controller = controller
        controller.residentHostAvailabilityChanged(true)
        guard let token = await controller.begin(ProjectPreviewSelection(recordingID: recording.id!,
            canonicalID: recording.canonicalID, projectID: project.id, projectVersion: briefed.version,
            expectedHost: try await store.libraryMetadata())) else { fatalError("Synthetic preparation failed") }
        await controller.receive(rawResponse: #"{"decision":"suggest","quote":"repair the entrance."}"#,
            unverifiedModelLabel: "Synthetic response, no model executed", token: token)
        let panelHost = NSHostingController(rootView: UntrustedProjectPreviewPanel(controller: controller))
        let panelWindow = makeWindow(title: "Synthetic Harc preview", frame: NSRect(x: 80, y: 100, width: 640, height: 640))
        panelWindow.contentViewController = panelHost

        let native = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        let button = NSButton(title: "Dismiss native control", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 30, width: 260, height: 32)
        let text = NSTextField(labelWithString: "NATIVE ACCESSIBILITY CONTROL MARKER")
        text.frame = NSRect(x: 20, y: 90, width: 330, height: 32)
        native.addSubview(button); native.addSubview(text)
        let nativeWindow = makeWindow(title: "Synthetic native controls", frame: NSRect(x: 740, y: 100, width: 360, height: 200))
        nativeWindow.contentView = native
        let minimalWindow = makeWindow(title: "Synthetic SwiftUI controls", frame: NSRect(x: 740, y: 350, width: 360, height: 200))
        minimalWindow.contentViewController = NSHostingController(rootView: VStack {
            Button("Dismiss SwiftUI control") { }
            Text("SWIFTUI ACCESSIBILITY CONTROL MARKER")
        }.padding())
        windows = [panelWindow, nativeWindow, minimalWindow]
        windows.forEach { $0.orderFront(nil) }
        panelWindow.makeKeyAndOrderFront(nil)
        print("SYNTHETIC_PREVIEW_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        // Bound fixture lifetime independently from the read-only probe.
        Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
    func makeWindow(title: String, frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        return window
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller?.dismiss()
        windows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: root)
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
