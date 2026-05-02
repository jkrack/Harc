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
        // Static SF Symbol — NOT LiveWaveformView. The menu-bar icon is always
        // visible, so a Canvas + TimelineView running at 24 Hz here would pin
        // the main thread for the entire recording (saturating SwiftUI's
        // re-render path and pinwheeling everything else, including hotkey
        // dispatch). The panel viz still runs when the panel is open.
        Image(systemName: "waveform")
            .foregroundStyle(bridge.recordingState.isRecording ? HarcBrand.live : .primary)
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
