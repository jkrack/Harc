import Foundation
import HarcStore
import HarcVoiceprint

/// One candidate match found for a speaker in the current recording. The UI
/// groups these by `name` to produce the "Sounds like Jason · 3 prior
/// recordings" chips rendered in `SpeakerNameEditor`.
public struct SpeakerMatch: Sendable, Equatable {
    public let recordingID: Int64
    public let speakerIndex: Int
    /// The user-entered override name for this speaker in its source
    /// recording, if any. `nil` means "an unnamed speaker in a prior
    /// recording" — still surfaceable as an anchor candidate.
    public let name: String?
    public let similarity: Float
    public let totalMs: Int
}

/// Grouped suggestion shown to the user — one per candidate identity.
public struct SpeakerSuggestion: Sendable, Equatable, Identifiable {
    /// Stable per-session id — derived from name (or "unnamed-<recID>-<idx>").
    public let id: String
    /// The name we'd apply. `nil` for unnamed-in-prior-recording matches.
    public let name: String?
    /// Best cosine similarity across matches in this group (0..1).
    public let bestSimilarity: Float
    /// The underlying match list. For a "Jason · 3 prior recordings" chip,
    /// this holds the 3 matches.
    public let matches: [SpeakerMatch]
}

/// Cross-library speaker re-identification. Stateless; holds a reference
/// to `RecordingStore` + the per-app `SpeakerNameResolver` so the callers
/// don't have to thread both through.
public actor SpeakerReIDService {
    public let store: RecordingStore
    public let nameResolver: SpeakerNameResolver
    public let embeddingDim: Int

    /// Cosine similarity cutoff below which matches are discarded. 0.65 is
    /// tuned for WeSpeaker; older ECAPA embeddings used 0.62 but are now
    /// filtered out by embedderKind before cosine comparison.
    public let threshold: Float
    /// Ignore embeddings whose source audio was shorter than this. Short
    /// segments produce noisy fingerprints.
    public let minTotalMs: Int

    public init(
        store: RecordingStore,
        nameResolver: SpeakerNameResolver,
        embeddingDim: Int = 192,
        threshold: Float = 0.65,
        minTotalMs: Int = 5_000
    ) {
        self.store = store
        self.nameResolver = nameResolver
        self.embeddingDim = embeddingDim
        self.threshold = threshold
        self.minTotalMs = minTotalMs
    }

    /// Top-K speaker suggestions for a new recording's speaker. The query
    /// vector is the new speaker's embedding; candidates are every other
    /// recording's stored embeddings.
    public func suggestions(
        for query: [Float],
        excludingRecording: Int64,
        k: Int = 5
    ) async throws -> [SpeakerSuggestion] {
        guard query.count == embeddingDim else { return [] }

        let rows = try await store.allSpeakerEmbeddings(
            excludingRecording: excludingRecording,
            embedderKind: EmbedderKind.wespeakerV2
        )
        guard !rows.isEmpty else { return [] }

        var matches: [SpeakerMatch] = []
        matches.reserveCapacity(rows.count)

        for row in rows where row.totalMs >= minTotalMs {
            guard let vec = EmbeddingBlob.decode(row.embedding, expectedDim: embeddingDim) else {
                continue
            }
            // Both sides should be L2-normalized by the embedder, but fall
            // back to the general form to avoid trusting that invariant.
            let sim = CosineSimilarity.of(query, vec)
            if sim >= threshold {
                let name = await nameResolver.name(recordingID: row.recordingID,
                                                   speakerIndex: row.speakerIndex)
                matches.append(SpeakerMatch(
                    recordingID: row.recordingID,
                    speakerIndex: row.speakerIndex,
                    name: name,
                    similarity: sim,
                    totalMs: row.totalMs
                ))
            }
        }

        // Group by name (unnamed → own bucket keyed by recording + speaker).
        var groups: [String: [SpeakerMatch]] = [:]
        for m in matches {
            let key = m.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? "__unnamed:\(m.recordingID):\(m.speakerIndex)"
            groups[key, default: []].append(m)
        }

        let suggestions: [SpeakerSuggestion] = groups.map { key, ms in
            let name = key.hasPrefix("__unnamed:") ? nil : key
            let best = ms.map(\.similarity).max() ?? 0
            return SpeakerSuggestion(id: key, name: name, bestSimilarity: best, matches: ms)
        }

        return suggestions
            .sorted { $0.bestSimilarity > $1.bestSimilarity }
            .prefix(k)
            .map { $0 }
    }
}

// MARK: - Name resolver

/// Looks up the user-entered override name for a (recording, speaker) pair.
/// Extracted behind a protocol so tests can inject a fake without touching
/// the full `RecordingsViewModel`.
public protocol SpeakerNameResolver: Sendable {
    func name(recordingID: Int64, speakerIndex: Int) async -> String?
}

/// Reads `recordings.speaker_names` directly from the store. Cheap — each
/// lookup is a single-row SELECT keyed by primary key.
public actor StoreSpeakerNameResolver: SpeakerNameResolver {
    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func name(recordingID: Int64, speakerIndex: Int) async -> String? {
        guard let recording = try? await store.fetch(id: recordingID) else { return nil }
        let trimmed = recording.speakerNames[speakerIndex]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
