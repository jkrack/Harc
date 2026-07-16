import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("harc.toggleRecording")
    /// Dictation hotkey. Behaviour (push-to-talk vs toggle) is decided by
    /// `HarcPreferences.dictationTriggerStyle`, not by the shortcut itself.
    static let pushToTalkDictation = Self("harc.dictation")
}
