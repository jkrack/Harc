import HarcStore

/// Direct speaker edits retain the same current-artifact authority as suggestions.
@MainActor
struct SpeakerSlotReviewBatch {
    private let recordingID: Int64?
    private let reviews: [Int: Result<RecordingStore.HostSpeakerReview?, Error>]
    static let empty = Self(recordingID: nil, reviews: [:])

    static func load(recordingID: Int64, indices: [Int], store: RecordingStore) async -> Self {
        var reviews: [Int: Result<RecordingStore.HostSpeakerReview?, Error>] = [:]
        for index in indices {
            do {
                reviews[index] = .success(try await store.hostSpeakerReviewForEditing(recordingID: recordingID, speakerIndex: index))
            } catch { reviews[index] = .failure(error) }
        }
        return Self(recordingID: recordingID, reviews: reviews)
    }

    /// True means the legacy caller still needs to mirror the selected person's name.
    func link(personID: Int64, recordingID: Int64, speakerIndex: Int, store: RecordingStore) async throws -> Bool {
        guard recordingID == self.recordingID, let result = reviews[speakerIndex] else {
            throw StoreError.invalidData("The speaker changed. Review it again before assigning its identity.")
        }
        if let review = try result.get() {
            try await store.confirmHostSpeakerReview(review, personID: personID)
            return false
        }
        try await store.linkSpeaker(personID: personID, recordingID: recordingID, speakerIndex: speakerIndex)
        return true
    }

    func createPerson(displayName: String, recordingID: Int64, speakerIndex: Int,
                      store: RecordingStore) async throws -> (personID: Int64, needsLegacyLabel: Bool) {
        guard recordingID == self.recordingID, let result = reviews[speakerIndex] else {
            throw StoreError.invalidData("The speaker changed. Review it again before creating its identity.")
        }
        if let review = try result.get() {
            return (try await store.createPersonForHostSpeakerReview(review, displayName: displayName), false)
        }
        return (try await store.createPersonForLegacySpeaker(displayName: displayName,
            recordingID: recordingID, speakerIndex: speakerIndex), false)
    }

    /// True means the legacy caller still needs to clear its mirrored label.
    func unlink(recordingID: Int64, speakerIndex: Int, store: RecordingStore) async throws -> Bool {
        guard recordingID == self.recordingID, let result = reviews[speakerIndex] else {
            throw StoreError.invalidData("The speaker changed. Review it again before removing its identity.")
        }
        if let review = try result.get() {
            try await store.unlinkHostSpeakerReview(review)
            return false
        }
        try await store.unlinkSpeaker(recordingID: recordingID, speakerIndex: speakerIndex)
        return true
    }
}
