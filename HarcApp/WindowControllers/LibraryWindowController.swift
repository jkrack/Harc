import AppKit
import SwiftUI
import HarcUI
import HarcStore

@MainActor
final class LibraryWindowController: NSWindowController {
    convenience init(
        vm: LibraryViewModel,
        onOpen: @escaping (Recording) -> Void,
        onOpenInEditor: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        let root = LibraryWindowRootView(
            onOpen: onOpen,
            onOpenInEditor: onOpenInEditor,
            onOpenSettings: onOpenSettings
        )
            .environmentObject(vm)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.center()
        self.init(window: window)
    }
}
