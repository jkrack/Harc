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
    /// True when headers or action lines could not be fully parsed.
    /// Unrecognized output remains in `summary` for review. Callers must
    /// explicitly propagate this flag if they display a format warning.
    public let parseWarning: Bool

    /// Earlier utterances excluded by the input budget, independent of model formatting.
    public let omittedUtteranceCount: Int

    public init(summary: String, actionItems: [ActionItem], parseWarning: Bool, omittedUtteranceCount: Int = 0) {
        self.summary = summary
        self.actionItems = actionItems
        self.omittedUtteranceCount = max(0, omittedUtteranceCount)
        self.parseWarning = parseWarning
    }

    /// The persisted text is also displayed by clients and included in exports.
    /// Keep the review notice with the preserved response so those surfaces do
    /// not depend on a separate, currently unpersisted parser flag.
    public var markdownForStorage: String {
        var notices: [String] = []
        if omittedUtteranceCount > 0 {
            notices.append("Partial summary: Earlier transcript content was excluded because it exceeded the model's input limit. This summary and its action items cover only the end of the transcript; earlier facts and commitments may be missing.")
        }
        if parseWarning {
            notices.append("Review needed: Some generated text could not be organized into summary and action items. Check the preserved response below against the transcript.")
        }
        return (notices + [summary]).joined(separator: "\n\n")
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
