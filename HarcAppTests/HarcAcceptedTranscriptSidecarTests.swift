import Foundation
import Testing
import HarcCore
import HarcClient
import HarcDomain
import HarcStore
import HarcProtocolWire
import HarcExport
@testable import HarcHost

@Suite("Accepted Client structured sidecar")
struct HarcAcceptedTranscriptSidecarTests {
    @Test func mappedProjectionPreservesUtteranceAndWordSpeakers() throws {
        let pcm = try CanonicalPCMHash(Data(repeating: 1, count: 32))
        let recording = Recording(wavPath: "/tmp/mapped.wav", startedAt: Date(), canonicalPCMHash: pcm,
            canonicalPCMFrames: 32000)
        let map = try SpeakerClusterMap(canonicalRecordingID: recording.canonicalID, canonicalPCMHash: pcm,
            producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterIDs: ["speaker-9", "speaker-2"])
        var transcript = Harc_V1_TranscriptArtifactV1()
        var first = Harc_V1_TranscriptUtteranceV1()
        first.text = "parent override"; first.endFrameExclusive = 16000; first.localSpeakerID = "speaker-2"
        var word = Harc_V1_TranscriptWordV1()
        word.text = "parent"; word.endFrameExclusive = 8000
        first.words = [word]
        word.text = "override"; word.startFrame = 8000; word.endFrameExclusive = 16000
        word.localSpeakerID = "speaker-9"; first.words.append(word)
        var second = Harc_V1_TranscriptUtteranceV1()
        second.text = "untimed"; second.startFrame = 16000; second.endFrameExclusive = 32000
        second.localSpeakerID = "speaker-9"; transcript.utterances = [first, second]
        var turn = Harc_V1_SpeakerTurnV1()
        turn.localClusterID = "speaker-2"; turn.endFrameExclusive = 16000
        let data = try HarcHostProcessingArtifactService.acceptedTranscriptData(transcript,
            recording: recording, clusterMap: map, turns: [turn])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let local = try decoder.decode(SessionTranscript.self, from: data)
        #expect(local.words.map { $0.speakerAttribution?.speakerIndex } == [0, 1])
        #expect(local.attributedUtterances?.count == 2)
        #expect(local.attributedUtterances?[0].words[0].speakerAttribution == nil)
        #expect(local.attributedUtterances?[1].words.isEmpty == true)
        #expect(local.attributedUtterances?[1].speakerAttribution?.speakerIndex == 1)
        #expect(local.speakers.first?.speaker == 0)
        #expect(TranscriptPlainTextRenderer.render(local) == "Speaker 1: parent\n\nSpeaker 2: override\n\nSpeaker 2: untimed")
        #expect(throws: (any Error).self) {
            try HarcHostProcessingArtifactService.acceptedTranscriptData(transcript, recording: recording)
        }
        transcript.utterances[0].words[0].localSpeakerID = "unknown"
        #expect(throws: (any Error).self) {
            try HarcHostProcessingArtifactService.acceptedTranscriptData(transcript, recording: recording, clusterMap: map)
        }
    }

    @Test func acceptedSidecarDecodesAndExportsOverlapAfterReplacingHostWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var recording = Recording(wavPath: root.appendingPathComponent("recording.wav").path,
            startedAt: Date(timeIntervalSince1970: 5000), endedAt: Date(timeIntervalSince1970: 5001))
        recording.processing = .pending
        let store = try await RecordingStore.inMemory()
        recording = try await store.upsert(recording)
        let id = try #require(recording.id)
        #expect(try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id,
            text: "losing Host words", modelID: "host", structuredTranscriptData: Data("{}".utf8)))
        let losingPath = try #require(try await store.fetch(id: id)?.jsonPath)

        var wire = Harc_V1_TranscriptArtifactV1()
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "mixed words"
        utterance.endFrameExclusive = 8000
        var word = Harc_V1_TranscriptWordV1()
        word.text = "mixed words"; word.endFrameExclusive = 8000
        utterance.words = [word]; wire.utterances = [utterance]
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 1601; range.endFrameExclusive = 6401
        wire.overlapAssessment.ranges = [range]
        let data = try HarcHostProcessingArtifactService.acceptedTranscriptData(wire, recording: recording)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(SessionTranscript.self, from: data)
        #expect(session.joinedText == "mixed words")
        #expect(session.words == [Word(text: "mixed words", startMs: 0, endMs: 500)])
        #expect(session.speakers.isEmpty)
        #expect(session.overlapRanges == [try SpeechOverlapRange(startMs: 100, endMs: 401)])
        #expect(session.audioPath == recording.wavPath)
        let rendered = HarcHostProcessingArtifactService.acceptedTranscriptText(wire)
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: rendered, modelID: "edge",
            structuredTranscriptData: data)
        let winner = try #require(try await store.fetch(id: id))
        let path = try #require(winner.jsonPath)
        #expect(path != losingPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        #expect(ExportInputBuilder.loadTranscript(from: winner)?.overlapRanges == session.overlapRanges)
        let output = root.appendingPathComponent("accepted.srt")
        try ExportService.write(recording: winner, format: .srt, to: output)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("Overlapping voices: mixed words"))
        try await store.applyAcceptedEdgeTranscript(recordingID: id, text: rendered, modelID: "edge",
            structuredTranscriptData: data)
        #expect(try await store.fetch(id: id)?.jsonPath == path)
        #expect(try await !store.publishHostProcessedProjectionIfNotReady(recordingID: id))
        #expect(FileManager.default.fileExists(atPath: losingPath))
    }

    @Test func legacyAndEmptyAssessmentStayDistinctInSavedJSON() throws {
        let recording = Recording(wavPath: "/tmp/recording.wav", startedAt: Date())
        var wire = Harc_V1_TranscriptArtifactV1()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(SessionTranscript.self,
            from: HarcHostProcessingArtifactService.acceptedTranscriptData(wire, recording: recording))
        #expect(legacy.overlapRanges == nil)
        wire.overlapAssessment = Harc_V1_SpeechOverlapAssessmentV1()
        let assessed = try decoder.decode(SessionTranscript.self,
            from: HarcHostProcessingArtifactService.acceptedTranscriptData(wire, recording: recording))
        #expect(assessed.overlapRanges == [])
    }
}
