import Foundation

public enum EmbeddingVectorCodec {
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(vector.count * MemoryLayout<Float>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw EmbeddingVectorCodecError.invalidByteCount(data.count)
        }

        var values: [Float] = []
        values.reserveCapacity(data.count / MemoryLayout<Float>.size)

        for offset in stride(from: 0, to: data.count, by: MemoryLayout<Float>.size) {
            var bits: UInt32 = 0
            for byteOffset in 0..<MemoryLayout<Float>.size {
                let index = data.index(data.startIndex, offsetBy: offset + byteOffset)
                bits |= UInt32(data[index]) << UInt32(byteOffset * 8)
            }
            values.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }

        return values
    }
}

public enum EmbeddingVectorCodecError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
}
