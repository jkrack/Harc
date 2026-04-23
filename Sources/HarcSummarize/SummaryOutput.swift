import Foundation

/// One row in the action-items section of a generated summary. The user
/// can toggle `done` from the SummaryCardView (Stage 4); the rest is
/// produced by `SummaryParser` and never edited after generation.
public struct ActionItem: Codable, Equatable, Sendable {
    public var text: String
    public var actor: String?
    public var due: String?
    public var done: Bool

    public init(text: String, actor: String? = nil, due: String? = nil, done: Bool = false) {
        self.text = text
        self.actor = actor
        self.due = due
        self.done = done
    }
}

/// What `SummaryParser.parse(_:)` returns — the structured pieces it
/// could pull out of a raw model response. Caller (Stage 2's
/// `SummarizerService`) wraps this into a full `SummaryOutput` with
/// metadata it owns (model id, timing, source word count).
public struct SummaryParseResult: Equatable, Sendable {
    public let summary: String
    public let actionItems: [ActionItem]
    /// True when the model didn't emit the expected `## Summary` /
    /// `## Action Items` shape. The view shows an `ⓘ` tooltip and
    /// surfaces the raw text in `summary`.
    public let parseWarning: Bool

    public init(summary: String, actionItems: [ActionItem], parseWarning: Bool) {
        self.summary = summary
        self.actionItems = actionItems
        self.parseWarning = parseWarning
    }
}

/// Persisted summary for a recording. Stored across the four new
/// columns added in Stage 3's `v7_summary` migration.
public struct SummaryOutput: Codable, Equatable, Sendable {
    public let summary: String
    public let actionItems: [ActionItem]
    /// `ModelDescriptor.id`, e.g. `"gemma-4-e2b-it-4bit"`.
    public let model: String
    public let generatedAt: Date
    public let elapsedMs: Int
    /// Transcript word count at generation time. Drives the staleness
    /// nudge in SummaryCardView (§7.2): if the current transcript
    /// differs by >5 %, the card shows a "regenerate?" banner.
    public let sourceWordCount: Int
    public let parseWarning: Bool

    public init(
        summary: String,
        actionItems: [ActionItem],
        model: String,
        generatedAt: Date,
        elapsedMs: Int,
        sourceWordCount: Int,
        parseWarning: Bool
    ) {
        self.summary = summary
        self.actionItems = actionItems
        self.model = model
        self.generatedAt = generatedAt
        self.elapsedMs = elapsedMs
        self.sourceWordCount = sourceWordCount
        self.parseWarning = parseWarning
    }
}
