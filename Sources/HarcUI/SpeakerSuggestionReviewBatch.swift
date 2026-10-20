import HarcStore

/// Immutable review state shared by the People screen and Library inspector.
/// Capture this value with the displayed suggestions; never reload authority on click.
@MainActor
struct SpeakerSuggestionReviewBatch {
    private enum Review {
        case bound(RecordingStore.HostSpeakerReview)
        case legacy
        case unavailable(Error)
    }
    let suggestions: [PendingSuggestion]
    private let reviews: [String: (PendingSuggestion, Review)]

    static let empty = SpeakerSuggestionReviewBatch(suggestions: [], reviews: [:])

    static func load(_ suggestions: [PendingSuggestion], store: RecordingStore) async -> Self {
        var reviews: [String: (PendingSuggestion, Review)] = [:]
        for suggestion in suggestions {
            do {
                let bound = try await store.hostSpeakerReview(for: suggestion)
                reviews[suggestion.id] = (suggestion, bound.map(Review.bound) ?? .legacy)
            } catch {
                reviews[suggestion.id] = (suggestion, .unavailable(error))
            }
        }
        return Self(suggestions: suggestions, reviews: reviews)
    }

    /// Returns true only when the legacy path still needs its separate label projection.
    @discardableResult
    func confirm(_ suggestion: PendingSuggestion, store: RecordingStore) async throws -> Bool {
        guard let (loaded, review) = reviews[suggestion.id], loaded == suggestion else {
            throw StoreError.invalidData("The speaker suggestion changed. Review it again before confirming.")
        }
        switch review {
        case .bound(let value):
            try await store.confirmHostSpeakerReview(value, personID: suggestion.personID)
            return false
        case .legacy:
            try await store.confirmSuggestion(personID: suggestion.personID,
                recordingID: suggestion.recordingID, speakerIndex: suggestion.speakerIndex)
            return true
        case .unavailable(let error):
            throw error
        }
    }
}
