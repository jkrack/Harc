import Testing
@testable import HarcAudio

@Suite("HarcAudio scaffold")
struct ScaffoldTests {
    @Test("AudioError cases have non-empty descriptions")
    func errorDescriptions() {
        let errs: [AudioError] = [
            .micPermissionDenied,
            .systemAudioPermissionDenied,
            .audioEngineFailed("x"),
            .systemAudioStreamFailed("y"),
            .fileWriteFailed("z"),
            .conversionFailed("w"),
        ]
        for err in errs {
            #expect(err.errorDescription?.isEmpty == false, "empty description for \(err)")
        }
    }
}
