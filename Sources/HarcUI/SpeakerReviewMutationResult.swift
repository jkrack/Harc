import HarcStore
import HarcVoiceprint

/// Enrollment has already committed. A later refresh failure must never imply
/// that confirmation failed or encourage repeating a consumed bound review.
@MainActor
struct SpeakerReviewMutationResult {
    let needsLegacyLabel: Bool
    let refreshFailure: LibraryMutationFailure?

    static func refreshed(store: RecordingStore, needsLegacyLabel: Bool) async -> Self {
        do {
            // Reconsider every target, including other slots in the edited recording.
            // The Store excludes each target's own recording from its references.
            try await store.reconcileStandaloneSpeakerSuggestions(recordingID: nil,
                excludingRecordingID: nil, embedderKind: EmbedderKind.wespeakerV2,
                embeddingDim: 256, defaultThreshold: 0.65)
            return Self(needsLegacyLabel: needsLegacyLabel, refreshFailure: nil)
        } catch {
            return Self(needsLegacyLabel: needsLegacyLabel,
                refreshFailure: LibraryMutationFailure(action: .refreshSpeakerSuggestions, error: error))
        }
    }
}
