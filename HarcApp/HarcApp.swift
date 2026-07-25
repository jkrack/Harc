import SwiftUI
import HarcUI

@main
struct HarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot()
                .harcSettingsEnvironment(
                    prefs: appDelegate.prefs,
                    modelStore: appDelegate.modelStore,
                    bridge: appDelegate.bridge,
                    dictationModes: appDelegate.dictationModeStore,
                    maintenance: appDelegate.ensureMaintenanceStore()
                )
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
