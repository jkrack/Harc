import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("harc.toggleRecording")
    /// Dictation hotkey. Behaviour (push-to-talk vs toggle) is decided by
    /// `HarcPreferences.dictationTriggerStyle`, not by the shortcut itself.
    /// Ships with a default (⌃⌥D) so first-run dictation works before the
    /// user ever opens Settings; recording a new shortcut replaces it.
    static let pushToTalkDictation = Self(
        "harc.dictation",
        default: .init(.d, modifiers: [.control, .option])
    )

    /// Per-mode dictation hotkey: starts dictation with that mode as a
    /// one-shot override. Stable per mode id so the user's recorded
    /// shortcut survives relaunches and mode edits.
    static func dictationMode(_ modeID: String) -> Self {
        Self("harc.dictation.mode.\(modeID)")
    }
}
