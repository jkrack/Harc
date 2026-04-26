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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Initial size; overridden by autosaved frame on subsequent launches.
        window.setContentSize(NSSize(width: 560, height: 460))
        // Floor below which controls would clip. Form's internal scroll view
        // handles overflow, so this is just the smallest comfortable size.
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.center()
        // Persist user-resized size + position across sessions. Must be set
        // after the initial frame so first-launch geometry is what center()
        // chose; on later launches the saved frame wins.
        window.setFrameAutosaveName("HarcSettingsWindow")
        self.init(window: window)
    }
}
