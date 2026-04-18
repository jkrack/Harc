import AppKit
import SwiftUI
import HarcUI

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(prefs: HarcPreferences) {
        let root = SettingsView()
            .environmentObject(prefs)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        self.init(window: window)
    }
}
