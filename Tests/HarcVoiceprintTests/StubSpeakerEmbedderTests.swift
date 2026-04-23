import XCTest
@testable import HarcVoiceprint

final class StubSpeakerEmbedderTests: XCTestCase {

    func test_embed_returnsRequestedDim() throws {
        let embedder = StubSpeakerEmbedder(embeddingDim: 192)
        let samples = sineWave(hz: 440, seconds: 2)
        let v = try embedder.embed(samples: samples)
        XCTAssertEqual(v.count, 192)
    }

    func test_embed_returnsL2NormalizedVector() throws {
        let embedder = StubSpeakerEmbedder()
        let samples = sineWave(hz: 440, seconds: 2)
        let v = try embedder.embed(samples: samples)
        let n = sqrt(v.reduce(0.0) { $0 + Double($1 * $1) })
        XCTAssertEqual(n, 1.0, accuracy: 1e-5)
    }

    func test_embed_isDeterministicForSameInput() throws {
        let embedder = StubSpeakerEmbedder()
        let samples = sineWave(hz: 440, seconds: 2)
        let a = try embedder.embed(samples: samples)
        let b = try embedder.embed(samples: samples)
        for i in 0..<a.count {
            XCTAssertEqual(a[i], b[i], accuracy: 1e-6)
        }
    }

    func test_embed_differentSignals_giveDifferentEmbeddings() throws {
        let embedder = StubSpeakerEmbedder()
        let a = try embedder.embed(samples: sineWave(hz: 200, seconds: 2))
        let b = try embedder.embed(samples: sineWave(hz: 3000, seconds: 2))
        // Stub is not a real speaker embedder — but two very different
        // spectra should still produce meaningfully different output.
        let sim = CosineSimilarity.of(a, b)
        XCTAssertLessThan(sim, 0.95)
    }

    func test_embed_throwsOnShortInput() {
        let embedder = StubSpeakerEmbedder()
        let samples = [Float](repeating: 0.1, count: 100)   // <1 s
        XCTAssertThrowsError(try embedder.embed(samples: samples))
    }

    // MARK: - helpers

    private func sineWave(hz: Float, seconds: Float) -> [Float] {
        let sampleRate: Float = 16_000
        let count = Int(sampleRate * seconds)
        return (0..<count).map {
            sinf(2 * .pi * hz * Float($0) / sampleRate)
        }
    }
}
