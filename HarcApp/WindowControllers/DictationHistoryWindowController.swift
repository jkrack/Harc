import AppKit
import SwiftUI
import HarcUI

/// Window controller for the full dictation-history window. One instance is
/// kept by AppDelegate and re-shown; closing just hides it (history is cheap
/// to keep hosted).
@MainActor
final class DictationHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        historyStore: DictationHistoryStore,
        modeStore: DictationModeStore,
        reprocess: ((String, DictationMode) async throws -> String)?,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let host = NSHostingController(
            rootView: DictationHistoryWindowView(
                historyStore: historyStore,
                modeStore: modeStore,
                reprocess: reprocess
            )
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Dictation History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 440))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
