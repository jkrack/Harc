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
    /// Capture the user's selected text (via Accessibility) at dictation
    /// start and feed it to the transform as context. LLM modes only.
    public var includeSelectedText: Bool
    /// Capture the clipboard contents at dictation start as context.
    public var includeClipboard: Bool

    public init(
        id: String,
        name: String,
        symbolName: String,
        postProcess: PostProcess,
        instruction: String,
        systemPrompt: String? = nil,
        modelID: String? = nil,
        isBuiltIn: Bool = false,
        includeSelectedText: Bool = false,
        includeClipboard: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.postProcess = postProcess
        self.instruction = instruction
        self.systemPrompt = systemPrompt
        self.modelID = modelID
        self.isBuiltIn = isBuiltIn
        self.includeSelectedText = includeSelectedText
        self.includeClipboard = includeClipboard
    }

    /// True when this mode should capture working context at dictation start.
    public var wantsContext: Bool {
        postProcess == .llm && (includeSelectedText || includeClipboard)
    }

    // MARK: Codable (backward-compatible)

    // Custom decoding so modes persisted before the context toggles existed
    // (JSON without the keys) still load — the toggles default to off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decode(String.self, forKey: .symbolName)
        postProcess = try c.decode(PostProcess.self, forKey: .postProcess)
        instruction = try c.decode(String.self, forKey: .instruction)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        includeSelectedText = try c.decodeIfPresent(Bool.self, forKey: .includeSelectedText) ?? false
        includeClipboard = try c.decodeIfPresent(Bool.self, forKey: .includeClipboard) ?? false
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
        // SuperWhisper "Super Mode" analog: the dictated words are a request,
        // and the selected text / clipboard are the material to act on.
        DictationMode(
            id: "builtin.answer",
            name: "Answer",
            symbolName: "sparkles",
            postProcess: .llm,
            instruction: """
            The dictated text is a request or question. Answer it, or carry \
            out the rewrite/edit it asks for, using the provided context \
            (selected text, clipboard) as the material when relevant. Output \
            only the result, no preamble or explanation.
            """,
            isBuiltIn: true,
            includeSelectedText: true,
            includeClipboard: true
        ),
    ]

    public static func builtIn(id: String) -> DictationMode? {
        builtIns.first { $0.id == id }
    }
}
