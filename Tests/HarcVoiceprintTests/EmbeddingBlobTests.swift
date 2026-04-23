import XCTest
@testable import HarcVoiceprint

final class EmbeddingBlobTests: XCTestCase {

    func test_encode_produces4BytesPerFloat() {
        let vec = [Float](repeating: 0, count: 192)
        let data = EmbeddingBlob.encode(vec)
        XCTAssertEqual(data.count, 192 * MemoryLayout<Float>.size)
    }

    func test_encodeDecode_roundTrip() {
        let vec: [Float] = (0..<192).map { Float($0) / 100.0 - 1.0 }
        let data = EmbeddingBlob.encode(vec)
        let decoded = EmbeddingBlob.decode(data, expectedDim: 192)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 192)
        for i in 0..<192 {
            XCTAssertEqual(decoded![i], vec[i], accuracy: 1e-6)
        }
    }

    func test_decode_returnsNilOnWrongSize() {
        let data = EmbeddingBlob.encode([Float](repeating: 0, count: 100))
        XCTAssertNil(EmbeddingBlob.decode(data, expectedDim: 192))
    }

    func test_decode_returnsNilOnNonMultipleOfFour() {
        let data = Data([0x00, 0x01, 0x02])
        XCTAssertNil(EmbeddingBlob.decode(data, expectedDim: 1))
    }
}
