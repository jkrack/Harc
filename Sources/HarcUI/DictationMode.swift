import Foundation

/// A dictation mode: how a dictated transcript is post-processed before
/// insertion. `.none` inserts the raw transcript; `.llm` reformats it via the
/// local summarizer model using the mode's instruction.
public struct DictationMode: Codable, Equatable, Identifiable, Sendable {
    public enum PostProcess: String, Codable, Sendable {
        case none
        case llm
    }

    public var id: String
    public var name: String
    /// SF Symbol shown in pickers and the HUD chip.
    public var symbolName: String
    public var postProcess: PostProcess
    /// The per-mode prompt. Ignored when `postProcess == .none`.
    public var instruction: String
    /// Optional system-prompt override; nil uses the shared transform default.
    public var systemPrompt: String?
    /// Model to run the transform on; nil follows `prefs.activeSummarizerID`
    /// (recommended — avoids thrash-reloading a second multi-GB model).
    public var modelID: String?
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        symbolName: String,
        postProcess: PostProcess,
        instruction: String,
        systemPrompt: String? = nil,
        modelID: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.postProcess = postProcess
        self.instruction = instruction
        self.systemPrompt = systemPrompt
        self.modelID = modelID
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Built-ins

extension DictationMode {
    public static let rawID = "builtin.raw"

    /// Seeded modes. Non-deletable; instructions are user-editable and can be
    /// reset to these defaults per mode.
    public static let builtIns: [DictationMode] = [
        DictationMode(
            id: rawID,
            name: "Raw",
            symbolName: "text.quote",
            postProcess: .none,
            instruction: "",
            isBuiltIn: true
        ),
        DictationMode(
            id: "builtin.cleanup",
            name: "Clean-up",
            symbolName: "wand.and.stars",
            postProcess: .llm,
            instruction: """
            Fix punctuation and capitalization. Remove filler words (um, uh, \
            like, you know). Keep the meaning, wording, and tone otherwise \
            unchanged. Output only the result, no preamble or explanation.
            """,
            isBuiltIn: true
        ),
        DictationMode(
            id: "builtin.email",
            name: "Email",
            symbolName: "envelope",
            postProcess: .llm,
            instruction: """
            Rewrite as a polite, concise email body. Keep the sender's intent \
            and all concrete details. Use short paragraphs. Do not invent a \
            subject line, greeting names, or signature unless dictated. \
            Output only the result, no preamble or explanation.
            """,
            isBuiltIn: true
        ),
        DictationMode(
            id: "builtin.message",
            name: "Message",
            symbolName: "bubble.left",
            postProcess: .llm,
            instruction: """
            Rewrite as a casual chat message: brief, friendly, lowercase-ok, \
            no formal sign-offs. Keep all concrete details. Output only the \
            result, no preamble or explanation.
            """,
            isBuiltIn: true
        ),
        DictationMode(
            id: "builtin.bullets",
            name: "Bullet List",
            symbolName: "list.bullet",
            postProcess: .llm,
            instruction: """
            Convert to a concise markdown bullet list. One idea per bullet, \
            keep the original order, drop filler. Output only the result, no \
            preamble or explanation.
            """,
            isBuiltIn: true
        ),
    ]

    public static func builtIn(id: String) -> DictationMode? {
        builtIns.first { $0.id == id }
    }
}
