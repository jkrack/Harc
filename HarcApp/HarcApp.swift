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
            MenuBarExtraLabel(bridge: appDelegate.bridge)
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
    @ObservedObject var bridge: HarcAppBridge
    var body: some View {
        // Animated bars when recording, static SF Symbol when idle.
        // Driven by parent re-renders (10 Hz from amplitudeHistory @Published)
        // — NO TimelineView, since the always-visible menu-bar icon would
        // saturate SwiftUI if we did per-frame redraws.
        MenuBarBarsView(
            history: bridge.amplitudeHistory,
            isRecording: bridge.recordingState.isRecording,
            pasteFlash: bridge.pasteFlash
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
