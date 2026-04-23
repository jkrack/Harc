import Foundation

/// A voice-fingerprint extractor. Given a mono 16 kHz Float32 audio buffer,
/// returns an L2-normalized fixed-length embedding suitable for cosine
/// similarity against embeddings from other recordings.
///
/// Production implementation target: a bundled ECAPA-TDNN Core ML model
/// (~20 MB), producing 192-dim vectors. Until that model is bundled, the
/// only implementation is `StubSpeakerEmbedder` — see that type for caveats.
public protocol SpeakerEmbedder: Sendable {
    /// The dimensionality of the returned vectors. Fixed per embedder
    /// instance; consumers can rely on this for buffer sizing.
    var embeddingDim: Int { get }

    /// Extract one embedding from `samples`. Caller is expected to have
    /// gathered enough audio — generally at least ~1 s; shorter inputs are
    /// allowed but produce less stable embeddings.
    func embed(samples: [Float]) throws -> [Float]
}

public enum SpeakerEmbedderError: Error, LocalizedError {
    case tooShort(minSamples: Int, got: Int)
    case modelUnavailable
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tooShort(let min, let got):
            return "Audio too short for speaker embedding: needed \(min) samples, got \(got)."
        case .modelUnavailable:
            return "Speaker-embedding model is not bundled in this build."
        case .inferenceFailed(let s):
            return "Speaker-embedding inference failed: \(s)."
        }
    }
}

/// One extracted embedding + the metadata needed to decide whether it's
/// worth keeping (short `total_ms` means the embedding is noisy and the
/// re-ID service will skip it).
public struct SpeakerEmbedding: Sendable, Equatable {
    public let speakerIndex: Int
    public let vector: [Float]
    public let segmentCount: Int
    public let totalMs: Int

    public init(speakerIndex: Int, vector: [Float], segmentCount: Int, totalMs: Int) {
        self.speakerIndex = speakerIndex
        self.vector = vector
        self.segmentCount = segmentCount
        self.totalMs = totalMs
    }
}

// MARK: - Cosine similarity

public enum CosineSimilarity {
    /// Cosine similarity between two equal-length Float vectors. Returns 0
    /// when either vector is empty or lengths differ; L2-norm zero is
    /// treated as 0 similarity.
    public static func of(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        return denom > 0 ? dot / denom : 0
    }

    /// Cosine similarity assuming both inputs are already L2-normalized. A
    /// single dot product — cheaper than the general `of(...)` when a
    /// batch of candidates is normalized ahead of time.
    public static func dotNormalized(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }
}

/// L2-normalize a vector in place. No-op if the norm is zero.
public func l2Normalize(_ v: inout [Float]) {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    let norm = sqrtf(sumSq)
    guard norm > 0 else { return }
    for i in 0..<v.count { v[i] /= norm }
}
