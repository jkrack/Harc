import AppKit
import SwiftUI
import HarcUI
import HarcStore

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void
    ) {
        let root = TranscriptionDetailView(
            recording: recording,
            onReveal: onReveal,
            onDelete: onDelete,
            onRename: onRename,
            onSpeakerNamesChanged: onSpeakerNamesChanged
        )
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
