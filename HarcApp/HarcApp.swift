import SwiftUI
import HarcUI

@main
struct HarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            HarcSettingsForm()
                .environmentObject(appDelegate.prefs)
                .environmentObject(appDelegate.modelStore)
        }
    }
}
