import Foundation
import HarcDomain
import HarcStore

/// Reconciles pending speaker-identity reviews after diarization or enrollment.
/// Matching and publication share a database transaction so obsolete suggestions
/// disappear without overwriting confirmed names or exact-evidence reviews.
public actor SpeakerSuggestionEngine {
    private let store: RecordingStore
    /// Raw string key stored in `embedder_kind` column (e.g. `EmbedderKind.wespeakerV2`).
    private let embedderKind: String
    private let globalDefaultThreshold: Double
    /// Expected vector dimension for the active embedder.
    private let embeddingDim: Int

    public init(
        store: RecordingStore,
        embedderKind: String,
        globalDefaultThreshold: Double = 0.65,
        embeddingDim: Int = 256
    ) {
        self.store = store
        self.embedderKind = embedderKind
        self.globalDefaultThreshold = globalDefaultThreshold
        self.embeddingDim = embeddingDim
    }

    /// Recompute pending review suggestions from one consistent database snapshot.
    public func suggestForRecording(recordingID: Int64) async throws {
        try await store.reconcileStandaloneSpeakerSuggestions(recordingID: recordingID,
            excludingRecordingID: nil, embedderKind: embedderKind,
            embeddingDim: embeddingDim, defaultThreshold: globalDefaultThreshold)
    }

    /// A new or corrected identity can invalidate an earlier winner, so backfill
    /// reevaluates competing people too, not just suggestions for the new person.
    public func suggestForNewPerson(personID: Int64, fromRecording recordingID: Int64, speakerIndex: Int) async throws {
        try await store.reconcileStandaloneSpeakerSuggestions(recordingID: nil,
            excludingRecordingID: recordingID, embedderKind: embedderKind,
            embeddingDim: embeddingDim, defaultThreshold: globalDefaultThreshold)
    }
}
