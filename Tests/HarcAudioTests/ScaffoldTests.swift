import Testing
import AVFAudio
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

    @Test("mic tap format candidates prefer AVAudioEngine-negotiated format")
    func micTapFormatCandidatesPreferEngineNegotiation() {
        let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let candidates = MicCapture.tapFormatCandidates(outputFormat: output, inputFormat: input)

        #expect(candidates.count == 3)
        #expect(candidates[0] == nil)
        #expect(candidates[1] == output)
        #expect(candidates[2] == input)
    }
}
