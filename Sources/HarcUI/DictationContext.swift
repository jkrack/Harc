import Foundation

/// A snapshot of the user's working context at the moment a dictation
/// starts — selected text, clipboard contents, and the frontmost app.
/// Rendered via `promptBlock` into a compact markdown block that a mode
/// can append to its LLM prompt (SuperWhisper's "Super Mode" pattern).
///
/// All fields are optional: capture is per-mode opt-in and each source
/// can independently fail or be empty.
public struct DictationContext: Equatable, Sendable {
    /// Text currently selected in the frontmost app (read via Accessibility).
    public var selectedText: String?
    /// Current plain-string contents of the clipboard.
    public var clipboardText: String?
    /// Localized name of the frontmost application (e.g. "Safari").
    public var frontmostAppName: String?
    /// Bundle identifier of the frontmost application (e.g. "com.apple.Safari").
    public var frontmostBundleID: String?

    /// Maximum characters rendered per field in `promptBlock`. Longer values
    /// are cut and marked as truncated so the LLM knows the text is partial.
    public static let fieldCharacterCap = 4000

    public init(
        selectedText: String? = nil,
        clipboardText: String? = nil,
        frontmostAppName: String? = nil,
        frontmostBundleID: String? = nil
    ) {
        self.selectedText = selectedText
        self.clipboardText = clipboardText
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
    }

    /// An empty context — nothing captured.
    public static let empty = DictationContext()

    /// True when no field carries usable content.
    public var isEmpty: Bool {
        !hasContent(selectedText)
            && !hasContent(clipboardText)
            && !hasContent(frontmostAppName)
            && !hasContent(frontmostBundleID)
    }

    /// Compact markdown context block for appending to an LLM prompt.
    /// Empty/missing fields are omitted; each text field is capped at
    /// `fieldCharacterCap` characters with an explicit truncation marker.
    /// Returns `nil` when there is nothing to render.
    public var promptBlock: String? {
        guard !isEmpty else { return nil }

        var lines: [String] = ["## Context"]

        let app = appLine
        if let app {
            lines.append("")
            lines.append("Active app: \(app)")
        }
        if let selected = selectedText, hasContent(selected) {
            lines.append("")
            lines.append("Selected text:")
            lines.append(Self.fencedField(selected))
        }
        if let clipboard = clipboardText, hasContent(clipboard) {
            lines.append("")
            lines.append("Clipboard:")
            lines.append(Self.fencedField(clipboard))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering helpers

    private var appLine: String? {
        let name = hasContent(frontmostAppName) ? frontmostAppName : nil
        let bundle = hasContent(frontmostBundleID) ? frontmostBundleID : nil
        switch (name, bundle) {
        case let (name?, bundle?): return "\(name) (\(bundle))"
        case let (name?, nil): return name
        case let (nil, bundle?): return bundle
        case (nil, nil): return nil
        }
    }

    /// Cap `text` at `fieldCharacterCap` characters and wrap it in a
    /// triple-quote fence so multi-line content stays visually delimited.
    private static func fencedField(_ text: String) -> String {
        var body = text
        var truncated = false
        if body.count > fieldCharacterCap {
            body = String(body.prefix(fieldCharacterCap))
            truncated = true
        }
        var out = "\"\"\"\n\(body)\n\"\"\""
        if truncated {
            out += "\n(truncated to \(fieldCharacterCap) characters)"
        }
        return out
    }

    private func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
