import AppKit
import Carbon.HIToolbox
@preconcurrency import ApplicationServices

/// Writes text to the clipboard and synthesises Cmd-V into the frontmost
/// application. Requires Accessibility permission (Input Monitoring works too
/// for some event types, but CGEvent post for synthetic keystrokes needs
/// Accessibility on modern macOS).
public enum FrontmostAppPaster {
    public enum PasteError: Error, LocalizedError {
        case accessibilityDenied
        case noFrontmostApp
        case eventCreationFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Harc needs Accessibility permission to paste into other apps. Grant it in System Settings → Privacy & Security → Accessibility."
            case .noFrontmostApp:
                return "No frontmost application to paste into."
            case .eventCreationFailed:
                return "Failed to synthesize the paste keystroke."
            }
        }
    }

    /// Copy `text` to the clipboard and paste into the frontmost app.
    /// `dwellMs` is the delay before the paste fires — gives macOS a moment to
    /// restore focus to the previous app after our window resigns key.
    ///
    /// Completes when the paste keystroke has been posted (or throws) — the
    /// caller learns the real outcome instead of fire-and-forget.
    ///
    /// `restoreClipboard: true` snapshots the pasteboard first and puts the
    /// user's previous contents back shortly after the paste lands — unless
    /// the user copied something else in the meantime (change-count guard).
    ///
    /// Throws `PasteError.accessibilityDenied` synchronously if Harc has not
    /// been granted Accessibility permission — the caller is responsible for
    /// presenting UI to request it. No system prompt is triggered here.
    @MainActor
    public static func copyAndPaste(
        _ text: String,
        dwellMs: UInt64 = 150,
        restoreClipboard: Bool = false
    ) async throws {
        // Verify AX up front so accessibilityDenied propagates to the caller.
        // synthesizeCmdV re-checks defensively; passing `false` here means we
        // don't race with our own AppKit modal.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            throw PasteError.accessibilityDenied
        }

        let pb = NSPasteboard.general
        let snapshot = restoreClipboard ? snapshotPasteboard(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterWrite = pb.changeCount

        // Resign key so focus returns to whatever was frontmost before us —
        // but only when a Harc window actually holds key. Hiding
        // unconditionally would also hide the library window as a side
        // effect of every dictation.
        if NSApp.keyWindow != nil {
            NSApp.hide(nil)
        }

        // Small delay, then synthesize ⌘V — awaited, so failures propagate.
        try await Task.sleep(for: .milliseconds(Int(dwellMs)))
        try synthesizeCmdV()

        if let snapshot {
            // Give the target app a beat to read the pasteboard, then put the
            // user's clipboard back. Skipped if anything else wrote to the
            // pasteboard in the meantime.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                restorePasteboard(snapshot, to: pb, ifChangeCountIs: changeCountAfterWrite)
            }
        }
    }

    /// Synthesize Cmd-V into the frontmost (post-hide) application.
    @MainActor
    public static func synthesizeCmdV() throws {
        // AXIsProcessTrustedWithOptions with the prompt flag asks the user
        // to grant Accessibility if it hasn't been granted yet.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            throw PasteError.accessibilityDenied
        }

        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            throw PasteError.eventCreationFailed
        }
        // V = key code 9.
        let vKey: CGKeyCode = 9
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { throw PasteError.eventCreationFailed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Just copy — no paste synthesis.
    public static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Bundle ID of the current frontmost application. Call this BEFORE any
    /// Harc window has hidden — otherwise the reading reflects whatever app
    /// receives focus after `NSApp.hide(nil)`.
    @MainActor
    public static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Clipboard snapshot / restore

    /// Deep-copy the pasteboard's current items (all types) so they can be
    /// put back after a dictation paste.
    static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Restore a snapshot — but only if the pasteboard still holds exactly
    /// what we wrote (`ifChangeCountIs`). If the user copied something new in
    /// the meantime, their copy wins.
    static func restorePasteboard(
        _ snapshot: [NSPasteboardItem],
        to pb: NSPasteboard,
        ifChangeCountIs expected: Int
    ) {
        guard pb.changeCount == expected else { return }
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        pb.writeObjects(snapshot)
    }
}
