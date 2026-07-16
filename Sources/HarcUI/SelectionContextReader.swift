import AppKit
@preconcurrency import ApplicationServices

/// Captures the user's working context (selected text, clipboard, frontmost
/// app) into a `DictationContext` for Super-Mode prompt injection.
///
/// Selected text is read via the Accessibility API and therefore requires
/// the same Accessibility grant that `FrontmostAppPaster` already gates on.
/// This reader NEVER prompts for the permission — if untrusted it silently
/// yields `selectedText == nil`; the paste path owns prompting.
///
/// All system reads are routed through an injectable `Environment` so tests
/// can run headless (real AX calls need a UI session and a trusted process).
@MainActor
public enum SelectionContextReader {
    /// Injection seam for every system dependency the reader touches.
    /// Production uses `.live`; tests build one from plain closures.
    public struct Environment {
        /// Whether the process has Accessibility trust. Checked without
        /// prompting (`AXIsProcessTrusted`).
        public var isAXTrusted: @MainActor () -> Bool
        /// Selected text of the system-wide focused UI element, or nil on
        /// any failure (no focused element, attribute unsupported, …).
        public var focusedSelectedText: @MainActor () -> String?
        /// Frontmost application (name, bundle identifier), or nil if none.
        public var frontmostApp: @MainActor () -> (name: String?, bundleID: String?)?
        /// Current plain-string clipboard contents. Read-only.
        public var clipboardString: @MainActor () -> String?

        public init(
            isAXTrusted: @escaping @MainActor () -> Bool,
            focusedSelectedText: @escaping @MainActor () -> String?,
            frontmostApp: @escaping @MainActor () -> (name: String?, bundleID: String?)?,
            clipboardString: @escaping @MainActor () -> String?
        ) {
            self.isAXTrusted = isAXTrusted
            self.focusedSelectedText = focusedSelectedText
            self.frontmostApp = frontmostApp
            self.clipboardString = clipboardString
        }

        /// Real system implementations.
        @MainActor
        public static var live: Environment { Environment(
            isAXTrusted: { AXIsProcessTrusted() },
            focusedSelectedText: { SelectionContextReader.axFocusedSelectedText() },
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return (name: app.localizedName, bundleID: app.bundleIdentifier)
            },
            clipboardString: { NSPasteboard.general.string(forType: .string) }
        ) }
    }

    /// Capture the current context. `selectedText` / `clipboard` gate the
    /// corresponding reads (per-mode opt-in); the frontmost app is always
    /// recorded since it costs nothing and is not sensitive.
    ///
    /// IMPORTANT: call this while the target app is still frontmost — i.e.
    /// BEFORE any Harc window is shown, hidden, or takes key. The frontmost
    /// app and the AX-focused element both shift the moment our own UI grabs
    /// focus (same caveat as `FrontmostAppPaster.frontmostBundleID()`).
    public static func capture(
        selectedText: Bool,
        clipboard: Bool,
        environment: Environment = .live
    ) -> DictationContext {
        // Read the frontmost app first, before the (comparatively slow,
        // potentially focus-perturbing) AX round-trip.
        let app = environment.frontmostApp()

        var selection: String? = nil
        if selectedText, environment.isAXTrusted() {
            selection = normalized(environment.focusedSelectedText())
        }

        var clipboardText: String? = nil
        if clipboard {
            clipboardText = normalized(environment.clipboardString())
        }

        return DictationContext(
            selectedText: selection,
            clipboardText: clipboardText,
            frontmostAppName: app?.name,
            frontmostBundleID: app?.bundleID
        )
    }

    /// Collapse empty/whitespace-only reads to nil so "no selection" and
    /// "selection of nothing" look the same downstream.
    private static func normalized(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    // MARK: - Live AX read

    /// Selected text of the focused UI element via the Accessibility API.
    /// Returns nil for every failure mode: process untrusted, no focused
    /// element, element does not support `kAXSelectedTextAttribute` (menus,
    /// images, web areas without selection, …), or a non-string value.
    /// Never throws, never prompts.
    private static func axFocusedSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedErr == .success, let focusedRef else { return nil }
        // The attribute is documented to be an AXUIElement, but verify the
        // CF type before force-casting — some apps misbehave.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var selectedRef: CFTypeRef?
        let selectedErr = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        )
        guard selectedErr == .success, let text = selectedRef as? String else { return nil }
        return text
    }
}
