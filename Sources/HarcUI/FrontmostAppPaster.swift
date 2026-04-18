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
    public static func copyAndPaste(_ text: String, dwellMs: UInt64 = 150) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Resign key so focus returns to whatever was frontmost before us.
        NSApp.hide(nil)

        // Small delay, then synthesize ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(dwellMs))) {
            _ = try? synthesizeCmdV()
        }
    }

    /// Synthesize Cmd-V into the frontmost (post-hide) application.
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
}
