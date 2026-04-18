import AppKit
import SwiftUI
import HarcUI

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        entry: RecordingEntry,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        let root = TranscriptionDetailView(entry: entry, onReveal: onReveal, onDelete: onDelete)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(entry.date)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
