import Testing
import Foundation
@testable import HarcUI

@Suite("AmplitudeEnvelopeLoader")
@MainActor
struct AmplitudeEnvelopeLoaderTests {

    private static var fixtureURL: URL {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav")
    }

    @Test("returns array of requested sample count")
    func returnsRequestedSampleCount() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(envelope.count == 256)
    }

    @Test("all values are in [0, 1]")
    func valuesNormalized() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        for v in envelope {
            #expect(v >= 0)
            #expect(v <= 1)
        }
    }

    @Test("at least one sample exceeds 0.1 (fixture has audible speech)")
    func envelopeHasContent() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let maxVal = envelope.max() ?? 0
        #expect(maxVal > 0.1, "expected at least one envelope sample > 0.1; got max \(maxVal)")
    }

    @Test("cache returns identical contents on second call")
    func cacheHit() async throws {
        let first = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let second = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(first == second)
    }

    @Test("missing file throws")
    func missingFileThrows() async {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-a-real-harc-file-\(UUID().uuidString).wav")
        await #expect(throws: (any Error).self) {
            _ = try await AmplitudeEnvelopeLoader.load(url: bogus, samples: 64)
        }
    }
}
