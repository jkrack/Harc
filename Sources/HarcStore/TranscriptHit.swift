import Foundation

/// A single search hit. Bundles the matching recording, a pre-highlighted
/// snippet (with literal `<mark>…</mark>` sentinels around matched tokens),
/// and the BM25 relevance score (higher = more relevant — we negate SQLite's
/// lower-is-better bm25() so the UI layer can sort naturally).
public struct TranscriptHit: Sendable, Equatable, Identifiable {
    public var recording: Recording
    public var snippet: String
    public var score: Double

    public var id: String { recording.wavPath }

    public init(recording: Recording, snippet: String, score: Double) {
        self.recording = recording
        self.snippet = snippet
        self.score = score
    }
}
