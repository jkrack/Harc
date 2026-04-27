import Foundation

/// Persisted identity of the speaker-embedder model that produced a
/// `speaker_embeddings` row. Stored as `embedder_kind TEXT` in the table.
///
/// Cross-recording cosine search filters to a single kind, so rows from a
/// different embedder become invisible to suggestions. Bumping the constant
/// is the migration mechanism for an embedder swap — no schema change
/// required, old rows just stop matching.
public enum EmbedderKind {
    /// FluidAudio's WeSpeaker v2 — 256-dim, L2-normalized.
    /// Bumped if FluidAudio ships a breaking change to the model
    /// or its output layout.
    public static let wespeakerV2: String = "wespeaker_v2"
}
