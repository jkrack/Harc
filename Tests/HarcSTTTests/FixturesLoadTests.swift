import Testing
import Foundation

@Suite("Test fixtures load")
struct FixturesLoadTests {
    @Test("short-speech.wav is present and non-empty")
    func shortSpeechWAVExists() throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 10_000, "fixture should be at least 10 KB")
    }
}
