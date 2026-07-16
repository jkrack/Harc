import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("harc.toggleRecording")
    /// Dictation hotkey. Behaviour (push-to-talk vs toggle) is decided by
    /// `HarcPreferences.dictationTriggerStyle`, not by the shortcut itself.
    static let pushToTalkDictation = Self("harc.dictation")

    /// Per-mode dictation hotkey: starts dictation with that mode as a
    /// one-shot override. Stable per mode id so the user's recorded
    /// shortcut survives relaunches and mode edits.
    static func dictationMode(_ modeID: String) -> Self {
        Self("harc.dictation.mode.\(modeID)")
    }
}
