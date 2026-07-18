import SwiftUI
import KeyboardShortcuts

/// Dictation behaviour: hotkey, trigger style, insertion, sounds, keep-warm,
/// and history. Modes have their own pane (`DictationModesSettingsView`).
public struct DictationSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Section {
            KeyboardShortcuts.Recorder("Dictation hotkey", name: .pushToTalkDictation)
            Picker("Trigger", selection: $prefs.dictationTriggerStyle) {
                ForEach(HarcPreferences.DictationTriggerStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Picker("Dictated text", selection: $prefs.dictationInsertsAtCursor) {
                Text("Insert at the cursor").tag(true)
                Text("Copy to the clipboard").tag(false)
            }
            if prefs.dictationInsertsAtCursor {
                Toggle("Restore clipboard after inserting", isOn: $prefs.restoreClipboardAfterInsert)
            }
            Toggle("Sounds", isOn: $prefs.dictationSoundsEnabled)
            Toggle("Keep the dictation pill on screen", isOn: $prefs.persistentDictationHUD)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Push-to-talk: hold the key to dictate, release to insert. Toggle: tap to start and stop. Restoring the clipboard puts whatever you had copied back after the dictation lands. The pill stays visible when idle — hover it to start dictation or switch modes.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }

        Section {
            Toggle("Keep dictation ready", isOn: $prefs.keepDictationWarm)
            if prefs.keepDictationWarm {
                Picker("Keep the model loaded", selection: $prefs.keepDictationWarmWindow) {
                    ForEach(HarcPreferences.DictationKeepWarmWindow.allCases) { window in
                        Text(window.displayName).tag(window)
                    }
                }
            }
            Toggle("Keep dictation history", isOn: $prefs.dictationHistoryEnabled)
        } header: {
            Text("Dictation performance & privacy")
        } footer: {
            Text("Keep-ready holds the speech model in memory so dictation starts instantly. History keeps your last \(DictationHistoryStore.maxEntries) dictations as plain JSON in Application Support on this Mac — Clear History deletes the file; turn it off and nothing is written.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }
}
