import AppKit
import SwiftUI
import Testing
import HarcDomain
@testable import HarcStore
@testable import HarcUI

@Suite("Inactive accepted map presentation", .serialized)
@MainActor
struct ConfirmedProjectMapPanelTests {
    @Test(arguments: [false, true])
    func syntheticLayout(dark: Bool) {
        let snapshot = ConfirmedProjectMapSnapshot(recordingID: 1, canonicalID: .random(),
            recordingTitle: "[Synthetic](https://example.invalid)", connections: [
                .init(id: UUID(), projectName: "Entrance", originalQuote: "approval is blocked", evidenceIsCurrent: true),
                .init(id: UUID(), projectName: "Changed project", originalQuote: "if approved", evidenceIsCurrent: false)
            ], hasMore: true)
        let view = NSHostingView(rootView: ConfirmedProjectMapPanel(snapshot: snapshot)
            .environment(\.colorScheme, dark ? .dark : .light))
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        #expect(view.fittingSize.height > 0)
    }
    /// Opt-in window harness: only synthetic Store data and this view's pixels.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARC_MAP_WINDOW_QA"] == "1"), arguments: [false, true])
    func storeToWindow(dark: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        let recording = try await store.upsert(Recording(wavPath: root.appendingPathComponent("unused.wav").path,
            startedAt: Date(timeIntervalSince1970: 1), title: "Synthetic planning note",
            transcriptText: "We discussed Entrance. Approval is blocked."))
        let metadata = try await store.libraryMetadata()
        _ = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x65, count: 32)), hostStateID: .random())
        let hostMetadata = try await store.libraryMetadata()
        for name in ["Entrance", "Changed project"] {
            let project = try await store.createKnowledgeProject(name: name)
            let review = try await store.proposeProjectMatch(recordingID: recording.id!, projectID: project.id,
                quote: "Approval is blocked.", generatorID: "synthetic-window")
            _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version,
                decision: .accepted, operationID: UUID())
            if name == "Changed project" {
                _ = try await store.updateKnowledgeProjectBrief(id: project.id, expectedVersion: project.version,
                    brief: "Changed after acceptance", expectedHost: hostMetadata)
            }
        }
        let snapshot = try await store.confirmedProjectMap(recordingID: recording.id!,
            canonicalID: recording.canonicalID, expectedHost: hostMetadata)
        #expect(snapshot.connections.count == 2)
        #expect(snapshot.connections.filter { $0.evidenceIsCurrent }.count == 1)
        let host = NSHostingView(rootView: ConfirmedProjectMapPanel(snapshot: snapshot)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Harc synthetic accepted-map QA"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-map-synthetic-" + (dark ? "dark.png" : "light.png")))
        // Only walk this owned synthetic view. Never inspect the application,
        // global menus, other windows or external processes; never dump raw AX.
        let texts = ownedAccessibilityText(host)
        let nativeControl = NSTextField(labelWithString: "SYNTHETIC NATIVE CONTROL")
        window.contentView = nativeControl
        try await Task.sleep(for: .milliseconds(100))
        #expect(ownedAccessibilityText(nativeControl).contains("SYNTHETIC NATIVE CONTROL"))
        let control = NSHostingView(rootView: Text("SYNTHETIC SWIFTUI CONTROL"))
        control.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
        window.contentView = control
        try await Task.sleep(for: .milliseconds(100))
        control.layoutSubtreeIfNeeded()
        let controlExposed = ownedAccessibilityText(control).contains("SYNTHETIC SWIFTUI CONTROL")
        #expect(controlExposed, "Minimal SwiftUI control must be exposed before panel AX qualification is credible")
        #expect(texts.contains { $0.contains("Accepted connections") })
        #expect(texts.contains { $0.contains("Accepted association") })
        #expect(texts.contains { $0.contains("Source or project changed") })
    }

    private func ownedAccessibilityText(_ root: NSView) -> [String] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ item: Any, depth: Int) -> [String] {
            guard depth < 40, let object = item as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            // Fail closed before reading text: no menus, windows, application
            // roots, unknown roles, or back-links may enter this owned subtree.
            let allowedRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXStaticText", "AXHeading", "AXButton",
                "AXDisclosureTriangle", "AXCheckBox", "AXTextArea", "AXTextField"]
            guard let role = attribute("accessibilityRole") as? String,
                  allowedRoles.contains(role) else { return [] }
            let text = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"]
                .compactMap { attribute($0) as? String }
            let children = (attribute("accessibilityChildren") as? [Any] ?? [])
                + (attribute("accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
            return text + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }

}
