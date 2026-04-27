import Testing
import Foundation
@testable import HarcCore

@Suite("IPC round-trip")
struct IPCRoundTripTests {
    @Test("TranscribeRequest round-trip")
    func transcribeRequestRoundTrip() throws {
        let original = IPCRequest.transcribe(
            TranscribeRequest(
                audioPath: "/tmp/audio.wav",
                language: "en",
                wantTimestamps: true,
                diarize: true
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("Status request round-trip")
    func statusRequestRoundTrip() throws {
        let data = try JSONEncoder().encode(IPCRequest.status)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == .status)
    }

    @Test("Shutdown request round-trip")
    func shutdownRequestRoundTrip() throws {
        let data = try JSONEncoder().encode(IPCRequest.shutdown)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == .shutdown)
    }

    @Test("Result response round-trip")
    func resultResponseRoundTrip() throws {
        let result = TranscribeResult(
            text: "hello world",
            words: [
                Word(text: "hello", startMs: 0, endMs: 500),
                Word(text: "world", startMs: 500, endMs: 1000),
            ],
            speakers: [SpeakerSegment(speaker: 1, startMs: 0, endMs: 1000)],
            processingMs: 42
        )
        let original = IPCResponse.result(result)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("Status response round-trip")
    func statusResponseRoundTrip() throws {
        let original = IPCResponse.status(
            DaemonStatus(version: "0.1.0", modelLoaded: false, uptimeSeconds: 3)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("Error response round-trip")
    func errorResponseRoundTrip() throws {
        let original = IPCResponse.error(IPCError(code: "not_found", message: "No such file"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("TranscribeRequest decodes with defaults when optional fields omitted")
    func transcribeRequestOmittedFieldsUseDefaults() throws {
        let data = Data(#"{"audioPath":"/x.wav"}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscribeRequest.self, from: data)
        #expect(decoded.audioPath == "/x.wav")
        #expect(decoded.language == "en")
        #expect(decoded.wantTimestamps == true)
        #expect(decoded.diarize == true)
    }

    @Test("DiarizeRequest round-trip")
    func diarizeRequestRoundTrip() throws {
        let original = IPCRequest.diarize(DiarizeRequest(audioPath: "/tmp/audio.wav"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("DiarizeResult round-trip")
    func diarizeResultRoundTrip() throws {
        let result = DiarizeResult(
            segments: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
                SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2500),
            ],
            speakers: [
                SpeakerEmbeddingRow(
                    speakerIndex: 0,
                    vector: Array(repeating: Float(0.1), count: 256),
                    totalMs: 1000,
                    segmentCount: 1
                ),
                SpeakerEmbeddingRow(
                    speakerIndex: 1,
                    vector: Array(repeating: Float(-0.05), count: 256),
                    totalMs: 1500,
                    segmentCount: 1
                ),
            ],
            processingMs: 87
        )
        let original = IPCResponse.diarization(result)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }
}
