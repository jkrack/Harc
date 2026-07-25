import HarcModels
import SwiftUI

/// The complete set of observable objects `HarcSettingsForm` and its panes
/// require.
///
/// Settings is built from two places — the SwiftUI `Settings` scene (⌘, and
/// the app menu) and `AppDelegate.openSettings()` (the panel's Settings row,
/// the summary card, the main-menu item, which can't reach a `SettingsLink`
/// programmatically on macOS 14+). Both once injected their environment by
/// hand, and they drifted: the scene never got `LibraryMaintenanceStore`, so
/// opening Transcription from ⌘, trapped in `EnvironmentObject.error()` the
/// moment `librarySection` read it. A missing `@EnvironmentObject` is a
/// runtime `assertionFailure`, not a compile error, so nothing caught it.
///
/// Funnelling both sites through one modifier makes the next added dependency
/// a compile error at every call site instead of a crash in one of them.
public extension View {
    func harcSettingsEnvironment(
        prefs: HarcPreferences,
        modelStore: ModelManagerStore,
        bridge: HarcAppBridge,
        dictationModes: DictationModeStore,
        maintenance: LibraryMaintenanceStore
    ) -> some View {
        environmentObject(prefs)
            .environmentObject(modelStore)
            .environmentObject(bridge)
            .environmentObject(dictationModes)
            .environmentObject(maintenance)
    }
}
