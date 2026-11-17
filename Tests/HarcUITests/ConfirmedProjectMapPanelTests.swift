import AppKit
import SwiftUI
import Testing
import HarcDomain
@testable import HarcStore
@testable import HarcUI

@Suite("Inactive accepted map presentation")
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
}
