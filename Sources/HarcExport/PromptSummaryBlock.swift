import Foundation
import HarcStore

/// Extracted summary metadata for the prompt export. Non-nil only when a
/// recording has all four required summary columns populated; partial data
/// returns nil rather than a half-rendered block.
public struct PromptSummaryBlock: Equatable, Sendable {
    public let summaryMarkdown: String
    public let actionItemsMarkdown: String
    public let modelID: String
    public let generatedAt: Date

    public init(
        summaryMarkdown: String,
        actionItemsMarkdown: String,
        modelID: String,
        generatedAt: Date
    ) {
        self.summaryMarkdown = summaryMarkdown
        self.actionItemsMarkdown = actionItemsMarkdown
        self.modelID = modelID
        self.generatedAt = generatedAt
    }

    /// Returns nil when any of `summaryMarkdown`, `actionItemsMarkdown`,
    /// `summaryModelID`, or `summaryGeneratedAt` is missing. The fifth
    /// column (`summarySourceWordCount`) is not required here — the prompt
    /// export doesn't surface word count.
    public static func make(from recording: Recording) -> PromptSummaryBlock? {
        guard let summary = recording.summaryMarkdown,
              let items = recording.actionItemsMarkdown,
              let modelID = recording.summaryModelID,
              let generatedAt = recording.summaryGeneratedAt else {
            return nil
        }
        return PromptSummaryBlock(
            summaryMarkdown: summary,
            actionItemsMarkdown: items,
            modelID: modelID,
            generatedAt: generatedAt
        )
    }
}
