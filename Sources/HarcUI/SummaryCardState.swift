import Foundation
import HarcStore

/// The one-of-six state a `SummaryCardView` renders. Computed by the pure
/// `resolve(...)` helper so precedence logic is testable without SwiftUI.
public enum SummaryCardState: Equatable {
    /// No summary, no queued work, summarizer installed — user gets the
    /// "Generate" CTA.
    case empty
    /// No summary, summarizer not installed — renders `ModelRequirementView`.
    case installRequired
    /// Queued behind at least one other job (`position` is 1-based).
    case queued(position: Int, totalInFlight: Int)
    /// Currently generating.
    case inFlight
    /// Last run for this id failed; shows `message` + Retry + Dismiss.
    case failed(message: String)
    /// Summary persisted — the rich card.
    case summary

    public static func resolve(
        recording: Recording,
        isInFlight: Bool,
        isQueued: Bool,
        position: Int?,
        totalInFlight: Int,
        isSummarizerInstalled: Bool,
        lastFailure: String?
    ) -> SummaryCardState {
        // Precedence (top wins): inFlight > queued > summary > failed > installRequired > empty.
        if isInFlight { return .inFlight }
        if isQueued, let pos = position { return .queued(position: pos, totalInFlight: totalInFlight) }
        if recording.summaryMarkdown != nil { return .summary }
        if let msg = lastFailure { return .failed(message: msg) }
        if !isSummarizerInstalled { return .installRequired }
        return .empty
    }

    /// True when the current transcript word count differs from the persisted
    /// `summary_source_word_count` by more than 5 %. Shown as a nudge banner
    /// above the `.summary` card. False when either field is missing or empty
    /// (we don't badge based on catastrophic transcript loss; that's a different signal).
    public static func isStale(recording: Recording) -> Bool {
        guard let source = recording.summarySourceWordCount, source > 0 else { return false }
        guard let text = recording.transcriptText, !text.isEmpty else { return false }
        let current = text.split(whereSeparator: { $0.isWhitespace }).count
        let diff = abs(current - source)
        return Double(diff) / Double(source) > 0.05
    }
}
