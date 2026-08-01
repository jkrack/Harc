import Testing
import Foundation
import HarcClient
import HarcCore
@testable import HarcUI
@testable import HarcStore

@Suite("RecordingNerdStats")
struct RecordingNerdStatsTests {

    private func recording(durationSeconds: Double) -> Recording {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return Recording(
            wavPath: "/tmp/stats.wav",
            startedAt: start,
            endedAt: start.addingTimeInterval(durationSeconds),
            transcriptText: "x"
        )
    }

    private func transcript(
        text: String,
        speakers: [SpeakerSegment],
        chunks: [ChunkResult] = []
    ) -> SessionTranscript {
        SessionTranscript(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            audioPath: "/tmp/stats.wav",
            joinedText: text,
            words: [],
            speakers: speakers,
            chunks: chunks
        )
    }

    @Test("realtime factor and words-per-minute derive from duration")
    func throughput() {
        // 120s of audio, 4000ms of compute → 30× realtime. 300 words → 150/min.
        let words = Array(repeating: "w", count: 300).joined(separator: " ")
        let chunks = [
            ChunkResult(startMs: 0, endMs: 60_000, text: "", words: [], speakers: [], processingMs: 2500),
            ChunkResult(startMs: 60_000, endMs: 120_000, text: "", words: [], speakers: [], processingMs: 1500),
        ]
        let stats = RecordingNerdStats.build(
            recording: recording(durationSeconds: 120),
            transcript: transcript(text: words, speakers: [], chunks: chunks)
        )
        #expect(stats.chunkCount == 2)
        #expect(stats.totalProcessingMs == 4000)
        #expect(abs((stats.realtimeFactor ?? 0) - 30.0) < 0.001)
        #expect(abs((stats.wordsPerMinute ?? 0) - 150.0) < 0.001)
    }

    @Test("speech coverage merges overlapping segments")
    func coverage() {
        // Two overlapping segments 0–10s and 5–15s, plus 20–25s = 20s of 100s.
        let stats = RecordingNerdStats.build(
            recording: recording(durationSeconds: 100),
            transcript: transcript(text: "a", speakers: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 10_000),
                SpeakerSegment(speaker: 1, startMs: 5_000, endMs: 15_000),
                SpeakerSegment(speaker: 0, startMs: 20_000, endMs: 25_000),
            ])
        )
        #expect(abs((stats.speechCoverage ?? 0) - 0.20) < 0.001)
    }

    @Test("turns and longest monologue count same-speaker runs")
    func turnsAndMonologue() {
        // Runs: 0 (0–8s across two segments), 1 (8–9s), 0 (9–10s) → 3 turns,
        // longest monologue 8s.
        let stats = RecordingNerdStats.build(
            recording: recording(durationSeconds: 10),
            transcript: transcript(text: "a", speakers: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 4_000),
                SpeakerSegment(speaker: 0, startMs: 5_000, endMs: 8_000),
                SpeakerSegment(speaker: 1, startMs: 8_000, endMs: 9_000),
                SpeakerSegment(speaker: 0, startMs: 9_000, endMs: 10_000),
            ])
        )
        #expect(stats.speakerTurns == 3)
        #expect(stats.longestMonologueMs == 8_000)
    }

    @Test("talk shares are fractions of attributed speech, largest first")
    func talkShares() {
        let stats = RecordingNerdStats.build(
            recording: recording(durationSeconds: 100),
            transcript: transcript(text: "a", speakers: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 30_000),
                SpeakerSegment(speaker: 1, startMs: 30_000, endMs: 40_000),
            ])
        )
        #expect(stats.speakerShares.count == 2)
        #expect(stats.speakerShares[0].index == 0)
        #expect(abs(stats.speakerShares[0].share - 0.75) < 0.001)
        #expect(abs(stats.speakerShares[1].share - 0.25) < 0.001)
    }

    @Test("voiceprint dimensions derive from blob size")
    func voiceprintDims() {
        let row = RecordingStore.SpeakerEmbeddingRow(
            recordingID: 1,
            speakerIndex: 0,
            embedding: Data(count: 256 * 4),
            segmentCount: 7,
            totalMs: 42_000,
            embedderKind: "wespeaker_v2"
        )
        let stats = RecordingNerdStats.build(
            recording: recording(durationSeconds: 60),
            transcript: nil,
            voiceprintRows: [row]
        )
        #expect(stats.voiceprints.count == 1)
        #expect(stats.voiceprints[0].dimensions == 256)
        #expect(stats.voiceprints[0].embedderKind == "wespeaker_v2")
    }

    @Test("no sidecar still yields audio and model facts")
    func noSidecar() {
        var rec = recording(durationSeconds: 60)
        rec.sttModelID = "parakeet-tdt-0.6b-v3"
        let stats = RecordingNerdStats.build(recording: rec, transcript: nil, wavBytes: 1_920_000)
        #expect(stats.durationSeconds == 60)
        #expect(stats.sttModelID == "parakeet-tdt-0.6b-v3")
        #expect(stats.wavBytes == 1_920_000)
        #expect(stats.chunkCount == 0)
        #expect(stats.realtimeFactor == nil)
    }
}
