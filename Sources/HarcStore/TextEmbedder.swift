import Foundation

/// Turns a passage of text into a fixed-width vector for similarity search.
///
/// Deliberately a protocol with a stable `modelID`: `transcript_chunks` records
/// which embedder produced each row, so vectors from different models are never
/// compared. Swapping in a neural embedder is then an additive change — index
/// under the new `modelID`, search filtered to it, and the old rows age out
/// instead of silently poisoning results with incomparable geometry.
public protocol TextEmbedder: Sendable {
    /// Stable identifier persisted alongside every vector. Changing the
    /// embedding maths REQUIRES changing this string.
    var modelID: String { get }
    /// Vector width. Constant for the lifetime of a `modelID`.
    var dimensions: Int { get }
    /// Embed a passage. Implementations must L2-normalize, so cosine
    /// similarity reduces to a dot product.
    func embed(_ text: String) -> [Float]
}

public extension TextEmbedder {
    /// Cosine similarity of two L2-normalized vectors. Mismatched widths score
    /// zero rather than trapping — a corrupt or stale row must not crash search.
    func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return Double(max(-1, min(1, dot)))
    }
}

/// Hashed lexical embedder: no model download, no inference, works offline the
/// moment the app launches.
///
/// Honest about what it is. It projects word unigrams and bigrams into a fixed
/// vector space, so it retrieves on *vocabulary overlap* with fuzziness that
/// exact-match FTS5 lacks — word order, inflection and partial phrasing stop
/// being all-or-nothing. It does NOT capture meaning: "cancel the contract"
/// and "terminate the agreement" share no tokens and will not match.
///
/// It exists so the retrieval, storage and fusion layers are real, exercised
/// and tested today rather than blocked behind a model. Genuine semantic
/// matching arrives by conforming a neural embedder to `TextEmbedder` and
/// re-indexing under its own `modelID` — no other layer changes.
public struct HashedLexicalEmbedder: TextEmbedder {
    public let modelID: String
    public let dimensions: Int

    public init(dimensions: Int = 256) {
        precondition(dimensions > 0)
        self.dimensions = dimensions
        // Width is part of the identity: vectors of different widths are not
        // comparable, and the modelID is what guards the comparison.
        self.modelID = "hashed-lexical-v1-d\(dimensions)"
    }

    public func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return vector }

        for token in tokens {
            vector[Self.bucket(token, dimensions)] += 1
        }
        // Bigrams give a little word-order sensitivity, weighted below unigrams
        // so a shared phrase helps without letting one repeated pair dominate.
        for (a, b) in zip(tokens, tokens.dropFirst()) {
            vector[Self.bucket("\(a)_\(b)", dimensions)] += 0.5
        }

        // Damp term frequency: a word said twenty times shouldn't swamp the
        // twenty distinct words around it.
        for i in 0..<dimensions where vector[i] > 0 {
            vector[i] = log(1 + vector[i])
        }

        var norm: Float = 0
        for v in vector { norm += v * v }
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        for i in 0..<dimensions { vector[i] /= norm }
        return vector
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 }
            .map(String.init)
    }

    /// FNV-1a, written out rather than using `hashValue`: Swift's hashing is
    /// seeded per-process, which would make every stored vector meaningless on
    /// the next launch.
    static func bucket(_ token: String, _ dimensions: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(dimensions))
    }
}

/// Packs and unpacks Float32 vectors for BLOB storage, little-endian.
public enum EmbeddingBlob {
    public static func pack(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let start = data.startIndex + i * 4
            var bits: UInt32 = 0
            for byteOffset in 0..<4 {
                bits |= UInt32(data[start + byteOffset]) << (8 * UInt32(byteOffset))
            }
            out.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        return out
    }
}
