import AppKit
import SwiftUI
import HarcModels
import HarcUI

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(prefs: HarcPreferences, modelStore: ModelManagerStore) {
        let root = SettingsView()
            .environmentObject(prefs)
            .environmentObject(modelStore)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 460))
        window.center()
        self.init(window: window)
    }
}
