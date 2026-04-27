import Foundation

/// One extracted embedding + the metadata needed to decide whether it's
/// worth keeping. Independent of the producer — both daemon-side
/// computation and store-side decoding can build / consume this.
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
