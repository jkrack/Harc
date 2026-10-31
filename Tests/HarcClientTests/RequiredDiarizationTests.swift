import Foundation
import Testing
import HarcCore
@testable import HarcClient

private enum RequiredDiarizationFailure: Error { case transcription, diarization }

private actor RequiredDiarizationClient: TranscribingClient, DiarizingClient {
    let failTranscription: Bool
    let failDiarization: Bool
    var calls: [String] = []
    init(failTranscription: Bool = false, failDiarization: Bool = false) {
        self.failTranscription = failTranscription
        self.failDiarization = failDiarization
    }
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        calls.append("transcribe")
        #expect(!diarize && vad)
        if failTranscription { throw RequiredDiarizationFailure.transcription }
        return .init(text: "retained words", words: [.init(text: "retained words", startMs: 0, endMs: 500)],
                     speakers: [], processingMs: 7)
    }
    func diarize(audioPath: String) async throws -> DiarizeResult {
        calls.append("diarize")
        if failDiarization { throw RequiredDiarizationFailure.diarization }
        var result = DiarizeResult(segments: [.init(speaker: 2, startMs: 0, endMs: 500)],
            speakers: [.init(speakerIndex: 2, vector: [1, 0], totalMs: 500, segmentCount: 1)], processingMs: 3)
        result.overlapRanges = [try SpeechOverlapRange(startMs: 100, endMs: 200)]
        return result
    }
}

@Suite("Required diarization")
struct RequiredDiarizationTests {
    @Test func successPreservesWordsAndSpeakerEvidence() async throws {
        let client = RequiredDiarizationClient()
        let result = try await client.transcribeRequiringDiarization(audioPath: "/fixture.wav", vad: true, diarizer: client)
        #expect(result.text == "retained words")
        #expect(result.words == [.init(text: "retained words", startMs: 0, endMs: 500)])
        #expect(result.speakers == [.init(speaker: 2, startMs: 0, endMs: 500)])
        #expect(result.speakerEmbeddings.first?.speakerIndex == 2)
        #expect(result.overlapRanges == [try SpeechOverlapRange(startMs: 100, endMs: 200)])
        #expect(await client.calls == ["transcribe", "diarize"])
    }

    @Test func diarizationFailureCannotBecomeSuccessfulTextOnlyCompletion() async throws {
        let client = RequiredDiarizationClient(failDiarization: true)
        await #expect(throws: RequiredDiarizationFailure.self) {
            try await client.transcribeRequiringDiarization(audioPath: "/fixture.wav", vad: true, diarizer: client)
        }
        #expect(await client.calls == ["transcribe", "diarize"])
    }

    @Test func failedTranscriptionDoesNotRunDiarization() async throws {
        let client = RequiredDiarizationClient(failTranscription: true)
        await #expect(throws: RequiredDiarizationFailure.self) {
            try await client.transcribeRequiringDiarization(audioPath: "/fixture.wav", vad: true, diarizer: client)
        }
        #expect(await client.calls == ["transcribe"])
    }
}
