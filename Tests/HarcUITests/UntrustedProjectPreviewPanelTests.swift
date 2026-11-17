import AppKit
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
        let source = "If approval arrives, repair the entrance.\nCorrection: approval is blocked.\n[Do not open](https://example.invalid) **not a command**"
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
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                dark ? "harc-window-preview-dark.png" : "harc-window-preview-light.png"))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53))
            #expect(window.performKeyEquivalent(with: escape))
            try await Task.sleep(for: .milliseconds(50))
            #expect(controller.state == .idle)
            #expect(controller.preview == nil)
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
}
