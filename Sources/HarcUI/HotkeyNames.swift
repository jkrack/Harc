import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// Meeting capture start/stop. Ships with a default (⌃⌥R) for the same
    /// reason dictation does: the Welcome flow tells the user to "use the menu
    /// bar button or hotkey", and shipping no hotkey made that half false. The
    /// primary use case had no keyboard path out of the box while the
    /// secondary one did. Pairs with ⌃⌥D; recording a new shortcut replaces it.
    static let toggleRecording = Self(
        "harc.toggleRecording",
        default: .init(.r, modifiers: [.control, .option])
    )
    /// Quick Capture: the name-it-first start sheet (⌘⇧R). Distinct from
    /// `toggleRecording`, which starts instantly with a timestamp name —
    /// both paths stay live so muscle memory keeps working.
    static let quickCapture = Self(
        "harc.quickCapture",
        default: .init(.r, modifiers: [.command, .shift])
    )
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
