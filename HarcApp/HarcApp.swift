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
        }

        MenuBarExtra {
            MenuBarExtraContent(bridge: appDelegate.bridge)
                .environmentObject(appDelegate.prefs)
        } label: {
            MenuBarExtraLabel(iconState: appDelegate.bridge.iconState)
        }
        .menuBarExtraStyle(.window)
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

private struct MenuBarExtraLabel: View {
    @ObservedObject var iconState: MenuBarIconState
    var body: some View {
        // Static SF Symbol with tint changes only. Observes a narrow
        // MenuBarIconState — re-renders only on isRecording / pasteFlash
        // (effectively never during a recording). The bridge's 10 Hz
        // amplitudeHistory feed never reaches this label.
        MenuBarBarsView(
            history: [],
            isRecording: iconState.isRecording,
            pasteFlash: iconState.pasteFlash
        )
    }
}

private struct MenuBarExtraContent: View {
    @ObservedObject var bridge: HarcAppBridge
    @EnvironmentObject private var prefs: HarcPreferences
    var body: some View {
        MenuBarPanelView(
            recordingState: bridge.recordingState,
            trayState: bridge.trayState,
            amplitudeHistory: bridge.amplitudeHistory,
            onStartStop: bridge.onStartStop,
            onOpenWindow: bridge.onOpenWindow,
            onCopy: bridge.onCopyLastTranscript,
            onPasteIntoFrontmost: bridge.onPasteIntoFrontmost,
            frontmostAppName: bridge.frontmostAppName
        )
        .preferredColorScheme(prefs.appearance.colorScheme)
    }
}
