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
        // MenuBarBarsIcon is an AppKit-only enum (NSImage rendering); use an
        // SF Symbol placeholder here. TODO: swap in a SwiftUI bars view when
        // the SwiftUI port of the bars icon is available.
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
            scopeHistory: bridge.scopeHistory,
            onStartStop: bridge.onStartStop,
            onOpenWindow: bridge.onOpenWindow,
            onCopy: bridge.onCopyLastTranscript,
            onPasteIntoFrontmost: bridge.onPasteIntoFrontmost,
            frontmostAppName: bridge.frontmostAppName
        )
        .preferredColorScheme(prefs.appearance.colorScheme)
    }
}
