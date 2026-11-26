import AppKit
import ApplicationServices
import SwiftUI
import Foundation
import Testing
import HarcDomain
@testable import HarcStore
@testable import HarcUI

@Suite("Unhosted untrusted preview panel", .serialized)
@MainActor
struct UntrustedProjectPreviewPanelTests {
    @Test func statusCopyDoesNotPromoteFidelityOrAbstentionToTruth() {
        #expect(UntrustedProjectPreviewPanel.statusText(.processingResponse).contains("does not verify meaning"))
        #expect(UntrustedProjectPreviewPanel.statusText(.abstained).contains("does not mean"))
        #expect(UntrustedProjectPreviewPanel.statusText(.invalidated).contains("explicitly select"))
    }

    @Test(arguments: [false, true])
    func syntheticControllerHarnessLaysOutInBothAppearances(dark: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-panel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let longSource = ProcessInfo.processInfo.environment["HARC_PREVIEW_LONG_SOURCE_QA"] == "1"
        let source = "If approval arrives, repair the entrance.\nCorrection: approval is blocked.\n[Do not open](https://example.invalid) **not a command**" + (longSource
            ? "\n" + (1...100).map { "Synthetic context line \($0): no approval or completed work is established." }.joined(separator: "\n")
                + "\nFINAL SOURCE CORRECTION: approval remains blocked."
            : "")
        let recording = try await store.upsert(Recording(wavPath: root.appendingPathComponent("unused.wav").path,
            startedAt: Date(), transcriptText: source))
        let project = try await store.createKnowledgeProject(name: "Entrance")
        let metadata = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x72, count: 32)), hostStateID: .random())
        let briefed = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
            brief: "Repair the entrance after approval.", expectedHost: store.libraryMetadata())
        let controller = SelectedProjectPreviewController(store: store, externalChanges: NotificationCenter())
        controller.residentHostAvailabilityChanged(true)
        let token = try #require(await controller.begin(ProjectPreviewSelection(recordingID: recording.id!,
            canonicalID: recording.canonicalID, projectID: project.id, projectVersion: briefed.version,
            expectedHost: store.libraryMetadata())))
        await controller.receive(rawResponse: #"{"decision":"suggest","quote":"repair the entrance."}"#,
            unverifiedModelLabel: "[unverified](https://example.invalid)", token: token)
        #expect(controller.preview?.fullSourceText == source)
        let panel = UntrustedProjectPreviewPanel(controller: controller)
        let host = NSHostingView(rootView: panel
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
        if ProcessInfo.processInfo.environment["HARC_PREVIEW_WINDOW_QA"] == "1" {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 640),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Harc synthetic preview QA"
            window.appearance = host.appearance
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if longSource {
                window.setContentSize(NSSize(width: 360, height: 480))
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let scroll = try #require(findScrollView(host))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                let target = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                #expect(scroll.contentView.bounds.minY > 100)
                if let probe = ProcessInfo.processInfo.environment["HARC_PREVIEW_AX_PROBE"] {
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let output = try await Task.detached {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: probe)
                        process.arguments = [String(pid)]
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try process.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        return String(decoding: data, as: UTF8.self)
                    }.value
                    try output.write(to: FileManager.default.temporaryDirectory
                        .appendingPathComponent("harc-preview-real-ax-client.txt"), atomically: true, encoding: .utf8)
                }
                let snapshot = accessibilitySnapshot(host)
                let texts = snapshot.texts
                #expect(texts.contains { $0.contains("Dismiss") })
                #expect(texts.contains { $0.contains("FINAL SOURCE CORRECTION") })
                try (snapshot.diagnostics + ["TEXT VALUES"] + texts).joined(separator: "\n").write(to:
                    FileManager.default.temporaryDirectory.appendingPathComponent("harc-preview-synthetic-accessibility.txt"),
                    atomically: true, encoding: .utf8)
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                (longSource ? "harc-window-preview-long-" : "harc-window-preview-") + (dark ? "dark.png" : "light.png")))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53))
            #expect(window.performKeyEquivalent(with: escape))
            try await Task.sleep(for: .milliseconds(50))
            #expect(controller.state == .idle)
            #expect(controller.preview == nil)
            if longSource { try await compareAccessibilityControls(in: window) }
        }
        // Harness only: no application entry point, model, or automatic scan.
        // Layout construction is not a VoiceOver/keyboard/visual qualification.
        controller.dismiss()
        host.layoutSubtreeIfNeeded()
        #expect(controller.preview == nil)
        #expect(controller.state == .idle)
        #expect(try await store.pendingProjectReviewCards().isEmpty)
        #expect(try await store.confirmedProjectMatches(recordingID: recording.id!).isEmpty)
    }
    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }

    private func accessibilitySnapshot(_ root: Any) -> (texts: [String], diagnostics: [String]) {
        var diagnostics: [String] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ item: Any, depth: Int) -> [String] {
            guard depth < 40, let object = item as? NSObject else { return [] }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            // SwiftUI's accessibility proxies need not adopt the full AppKit
            // protocol. Ask only standard object-valued accessibility getters.
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            let navigation = attribute("accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            diagnostics.append("depth=\(depth) class=\(type(of: object)) role=\(String(describing: attribute("accessibilityRole"))) identifier=\(String(describing: attribute("accessibilityIdentifier"))) children=\(children.count) navigationChildren=\(navigation.count)")
            var values: [String] = []
            if let title = attribute("accessibilityTitle") as? String { values.append(title) }
            if let label = attribute("accessibilityLabel") as? String { values.append(label) }
            if let value = attribute("accessibilityValue") as? String { values.append(value) }
            for child in children + navigation {
                values += walk(child, depth: depth + 1)
            }
            return values
        }
        let texts = walk(root, depth: 0)
        return (texts, diagnostics)
    }

    private func compareAccessibilityControls(in window: NSWindow) async throws {
        let native = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        let button = NSButton(title: "Dismiss native control", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 100, width: 240, height: 32)
        let label = NSTextField(labelWithString: "NATIVE ACCESSIBILITY CONTROL MARKER")
        label.frame = NSRect(x: 20, y: 160, width: 320, height: 32)
        native.addSubview(button); native.addSubview(label)
        window.contentView = native
        try await Task.sleep(for: .milliseconds(100))
        let nativeRoot = accessibilitySnapshot(native)
        let nativeButton = accessibilitySnapshot(button)
        let nativeLabel = accessibilitySnapshot(label)
        let minimal = NSHostingView(rootView: VStack {
            Button("Dismiss SwiftUI control") { }
            Text("SWIFTUI ACCESSIBILITY CONTROL MARKER")
        })
        window.contentView = minimal
        try await Task.sleep(for: .milliseconds(100))
        minimal.layoutSubtreeIfNeeded()
        let swiftUI = accessibilitySnapshot(minimal)
        var sections = ["Test process AXIsProcessTrusted=\(AXIsProcessTrusted()) (read-only, no prompt)"]
        for (name, snapshot) in [("native subtree", nativeRoot), ("native button direct diagnostic", nativeButton),
                                 ("native label direct diagnostic", nativeLabel), ("minimal SwiftUI subtree", swiftUI)] {
            sections += [name] + snapshot.diagnostics + ["TEXT VALUES"] + snapshot.texts
        }
        try sections.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-preview-synthetic-accessibility-controls.txt"), atomically: true, encoding: .utf8)
        // Controls diagnose the probe, never substitute for panel assertions.
        // No real-client/VoiceOver traversal or permissions change is implied.
    }

}
