import Foundation

/// Encode/decode helpers for persisting a Float vector as a SQLite BLOB.
///
/// Layout: little-endian packed `Float32`, no header. 192 dims → 768 bytes.
/// Dim mismatches on decode return `nil` so callers can ignore rows that
/// were written by a different embedder version.
public enum EmbeddingBlob {
    public static func encode(_ vec: [Float]) -> Data {
        var data = Data(capacity: vec.count * MemoryLayout<Float>.size)
        for x in vec {
            var bits = x.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Returns `nil` when `data.count` isn't a multiple of 4, or when the
    /// decoded vector length doesn't match `expectedDim`.
    public static func decode(_ data: Data, expectedDim: Int) -> [Float]? {
        guard data.count == expectedDim * MemoryLayout<Float>.size else {
            return nil
        }
        var out = [Float](repeating: 0, count: expectedDim)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt32.self).baseAddress else { return }
            for i in 0..<expectedDim {
                let bits = UInt32(littleEndian: base[i])
                out[i] = Float(bitPattern: bits)
            }
        }
        return out
    }
}
