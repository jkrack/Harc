import Testing
import Foundation
import AVFoundation
import HarcCore
@testable import HarcClient

private actor CoverageClient: TranscribingClient {
    var paths: [String] = []
    let words: [Word]
    let cancelAfterRequest: Bool
    init(_ words: [Word] = [], cancelAfterRequest: Bool = false) { self.words = words; self.cancelAfterRequest = cancelAfterRequest }
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        #expect(!diarize && !vad)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        paths.append(audioPath)
        if cancelAfterRequest { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(text: words.map(\.text).joined(), words: words, speakers: [], processingMs: 0)
    }
}

@Suite("Speech coverage recovery")
struct SpeechCoverageRecoveryTests {
    private func transcript(_ path: String = "/missing.wav") -> SessionTranscript {
        .init(startedAt: Date(), endedAt: Date(), audioPath: path,
              joinedText: "Hello", words: [.init(text: "Hello", startMs: 0, endMs: 500)],
              speakers: [.init(speaker: 0, startMs: 0, endMs: 800),
                         .init(speaker: 1, startMs: 1000, endMs: 2000)], chunks: [],
              processingCoverage: .complete)
    }
    private func wav(float: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-test-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for i in 0..<48000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: float ? 32 : 16, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: false])
        try file.write(from: buffer)
        return url
    }
    @Test(arguments: [false, true]) func straddlingWordNeedsUniqueTimeSupport(duplicatesExisting: Bool) async throws {
        let url = try wav(); defer { try? FileManager.default.removeItem(at: url) }
        var input = transcript(url.path)
        input.speakers[1] = .init(speaker: 1, startMs: 1000, endMs: 1048)
        if duplicatesExisting { input.words[0].endMs = 900 }
        let client = CoverageClient([.init(text: " word", startMs: 0, endMs: 240)])
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.failedRanges.isEmpty == !duplicatesExisting)
        #expect(result.transcript.joinedText.contains(" word") == !duplicatesExisting)
    }

    @Test func narrowSpanRecoversWholeWordRatherThanOnlyPunctuation() async throws {
        let url = try wav(); defer { try? FileManager.default.removeItem(at: url) }
        var input = transcript(url.path)
        input.speakers[1] = .init(speaker: 1, startMs: 1000, endMs: 1048)
        let client = CoverageClient([
            .init(text: " M", startMs: 0, endMs: 80),
            .init(text: "m", startMs: 0, endMs: 80),
            .init(text: "-", startMs: 80, endMs: 240),
            .init(text: "h", startMs: 240, endMs: 320),
            .init(text: "m", startMs: 240, endMs: 320),
            .init(text: "m", startMs: 320, endMs: 400),
            .init(text: ".", startMs: 320, endMs: 400)])
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.failedRanges.isEmpty)
        #expect(result.transcript.joinedText == "Hello Mm-hmm.")
        #expect(result.transcript.words.last == Word(text: " Mm-hmm.", startMs: 800, endMs: 1200))
    }

    @Test(arguments: [false, true]) func recoversAndRebasesWithoutChangingSpeakersOrMaster(float: Bool) async throws {
        let url = try wav(float: float); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AVAudioFile(forReading: url).length == 48000)
        let bytes = try Data(contentsOf: url)
        var input = transcript(url.path)
        let attribution = try WordSpeakerAttribution(speakerIndex: 4)
        input.words[0].speakerAttribution = attribution
        let client = CoverageClient([.init(text: " world", startMs: 200, endMs: 600,
            speakerAttribution: try WordSpeakerAttribution(speakerIndex: 9))])
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.transcript.joinedText == "Hello world")
        #expect(result.transcript.words.last?.startMs == 1000)
        #expect(result.transcript.words.first?.speakerAttribution == attribution)
        #expect(result.transcript.words.last?.speakerAttribution == nil)
        #expect(result.transcript.speakers == input.speakers)
        #expect(result.failedRanges.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        let paths = await client.paths
        #expect(paths.count == 1)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }
    @Test(arguments: [false, true]) func emptyOrInvalidResponseLeavesVisibleFailure(invalid: Bool) async throws {
        let url = try wav(); defer { try? FileManager.default.removeItem(at: url) }
        let client = CoverageClient(invalid ? [.init(text: "bad", startMs: 0, endMs: Int.max)] : [])
        let result = await SpeechCoverageRecovery.recover(transcript(url.path), client: client)
        #expect(result.failedRanges.count == 1)
        #expect(result.transcript.joinedText.contains("could not be transcribed"))
        #expect(result.transcript.processingCoverage?.failedRanges.first?.reasonCode == "stt.speech_without_text")
        #expect(result.transcript.words.count == 1)
        let paths = await client.paths
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }
    @Test func requestLimitMarksWholeRemainder() async {
        var input = transcript()
        input.speakers[1] = .init(speaker: 1, startMs: 1000, endMs: 600_000)
        let client = CoverageClient()
        let result = await SpeechCoverageRecovery.recover(input, client: client, maximumRequests: 0)
        #expect(result.failedRanges.count == 1)
        #expect(result.failedRanges.first?.endMs == 600_000)
        #expect(await client.paths.isEmpty)
    }
    @Test func lateResponseAfterCancellationIsNotCommitted() async throws {
        let url = try wav(); defer { try? FileManager.default.removeItem(at: url) }
        let input = transcript(url.path)
        let client = CoverageClient([.init(text: " world", startMs: 200, endMs: 600)], cancelAfterRequest: true)
        let result = await Task { await SpeechCoverageRecovery.recover(input, client: client) }.value
        #expect(result.transcript.words == input.words)
        #expect(result.failedRanges.count == 1)
        let paths = await client.paths
        #expect(paths.count == 1)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }
    @Test func coveredTranscriptDoesNotReadAudioOrChangeProvenance() async {
        var input = transcript(); input.speakers.removeLast(); input.processingCoverage = nil
        let client = CoverageClient()
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.transcript == input)
        #expect(await client.paths.isEmpty)
    }
    @Test func priorFailureIsNotRetried() async {
        var input = transcript()
        input.processingCoverage = .init(failedRanges: [.init(startMs: 1000, endMs: 2000, reasonCode: "existing")])
        let client = CoverageClient()
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.transcript == input)
        #expect(await client.paths.isEmpty)
    }
    @Test func manualTextIsPreserved() async {
        var input = transcript(); input.joinedText = "My correction"; input.manualEditAt = Date()
        let client = CoverageClient()
        let result = await SpeechCoverageRecovery.recover(input, client: client)
        #expect(result.transcript.joinedText.hasPrefix("My correction\n\n"))
        #expect(result.transcript.words == input.words)
        #expect(await client.paths.isEmpty)
    }
    @Test func cancellationMarksGapWithoutReadingMissingAudio() async {
        let input = transcript(), client = CoverageClient()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SpeechCoverageRecovery.recover(input, client: client)
        }
        let result = await task.value
        #expect(result.failedRanges.count == 1)
        #expect(result.transcript.words == input.words)
        #expect(await client.paths.isEmpty)
    }
}
