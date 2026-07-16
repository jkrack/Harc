import SwiftUI
import HarcUI

@main
struct HarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot()
                .environmentObject(appDelegate.prefs)
                .environmentObject(appDelegate.modelStore)
                .environmentObject(appDelegate.bridge)
                .environmentObject(appDelegate.dictationModeStore)
        }
    }
}

// MARK: - Wrapper views that observe prefs for live appearance changes

private struct SettingsRoot: View {
    @EnvironmentObject private var prefs: HarcPreferences
    var body: some View {
        HarcSettingsForm()
            .preferredColorScheme(prefs.appearance.colorScheme)
    }
}
