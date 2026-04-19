import AppKit
import SwiftUI
import HarcUI

@MainActor
final class TranscriptEditorWindowController: NSWindowController, NSWindowDelegate {
    private let vm: TranscriptEditorViewModel
    private let onClose: () -> Void

    init(vm: TranscriptEditorViewModel, onClose: @escaping () -> Void) {
        self.vm = vm
        self.onClose = onClose
        let host = NSHostingController(rootView: TranscriptEditorView(vm: vm))
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Editor — \(vm.recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard vm.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to transcript?"
        alert.informativeText = "Unsaved edits will be lost if you don't save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await vm.save()
                if vm.saveError == nil {
                    sender.close()
                }
            }
            return false
        case .alertSecondButtonReturn:
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        vm.stopPlayback()
        onClose()
    }
}
