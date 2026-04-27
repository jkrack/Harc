import Testing
import Foundation
import HarcCore
import FluidAudio
@testable import HarcSTT

@Suite("Diarizer", .tags(.slow))
struct DiarizerTests {
    @Test("diarizing short-speech.wav returns at least one speaker segment")
    func diarizeShortSpeech() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let diarizer = Diarizer()
        try await diarizer.loadModels()

        let segments = try await diarizer.diarize(audioPath: url.path)

        #expect(segments.count >= 1, "expected at least one speaker segment")
        for segment in segments {
            #expect(segment.endMs > segment.startMs, "segment ends should come after starts")
        }
    }

    @Test("diarize before loadModels throws .modelNotLoaded")
    func diarizeBeforeLoadThrows() async throws {
        let diarizer = Diarizer()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await diarizer.diarize(audioPath: "/tmp/whatever.wav")
        }
    }

    @Test("diarizeWithEmbeddings returns 256-dim L2-normalized speaker embeddings")
    func diarizeWithEmbeddingsReturnsVectors() async throws {
        let diarizer = Diarizer()
        try await diarizer.loadModels()

        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let output = try await diarizer.diarizeWithEmbeddings(audioPath: url.path)

        #expect(!output.segments.isEmpty, "expected at least one segment")
        #expect(!output.speakers.isEmpty, "expected at least one speaker embedding")

        for sp in output.speakers {
            #expect(sp.vector.count == 256, "expected 256-dim, got \(sp.vector.count)")
            let normSq = sp.vector.reduce(Float(0)) { $0 + $1 * $1 }
            #expect(abs(normSq - 1) < 0.05, "expected L2-normalized; got |v|² = \(normSq)")
            #expect(sp.totalMs > 0)
            #expect(sp.segmentCount > 0)
        }

        // Speaker-index space is consistent between the two arrays — every
        // segment.speaker has a matching speaker row.
        let segmentSpeakers = Set(output.segments.map(\.speaker))
        let speakerIndices = Set(output.speakers.map(\.speakerIndex))
        #expect(segmentSpeakers.isSubset(of: speakerIndices),
                "every segment speaker should have an embedding row")
    }

    // MARK: - Pure helper tests (no model load required)

    @Test("buildSpeakerEmbeddingRows uses speakerDatabase when present")
    func buildRowsPrefersSpeakerDatabase() {
        let dbVecA = [Float](repeating: 0.5, count: 256)
        let dbVecB: [Float] = {
            var v = [Float](repeating: 0, count: 256)
            v[0] = 1.0
            return v
        }()
        let segs = [
            TimedSpeakerSegment(
                speakerId: "A",
                embedding: [Float](repeating: 99, count: 256),  // ignored; DB wins
                startTimeSeconds: 0,
                endTimeSeconds: 2,
                qualityScore: 0
            ),
            TimedSpeakerSegment(
                speakerId: "B",
                embedding: [Float](repeating: 99, count: 256),
                startTimeSeconds: 2,
                endTimeSeconds: 5,
                qualityScore: 0
            ),
        ]
        let rows = Diarizer.buildSpeakerEmbeddingRows(
            segments: segs,
            speakerIndexByID: ["A": 0, "B": 1],
            speakerDatabase: ["A": dbVecA, "B": dbVecB]
        )
        #expect(rows.count == 2)
        #expect(rows[0].speakerIndex == 0)
        #expect(rows[0].totalMs == 2000)
        #expect(rows[0].segmentCount == 1)
        // dbVecA was uniform; L2-normalized uniform 256-vector has each component = 1/sqrt(256) = 0.0625.
        #expect(abs(rows[0].vector[0] - 0.0625) < 1e-4)
        // dbVecB had only index 0 set to 1; L2-normalized = same vector.
        #expect(abs(rows[1].vector[0] - 1) < 1e-4)
        #expect(abs(rows[1].vector[1] - 0) < 1e-4)
    }

    @Test("buildSpeakerEmbeddingRows falls back to weighted segment averaging")
    func buildRowsFallsBackToAveraging() {
        let segA1: [Float] = [Float](repeating: 1.0, count: 256)
        let segA2: [Float] = [Float](repeating: 3.0, count: 256)
        let segs = [
            TimedSpeakerSegment(
                speakerId: "A",
                embedding: segA1,
                startTimeSeconds: 0,
                endTimeSeconds: 1,        // 1000ms weight
                qualityScore: 0
            ),
            TimedSpeakerSegment(
                speakerId: "A",
                embedding: segA2,
                startTimeSeconds: 1,
                endTimeSeconds: 4,        // 3000ms weight
                qualityScore: 0
            ),
        ]
        let rows = Diarizer.buildSpeakerEmbeddingRows(
            segments: segs,
            speakerIndexByID: ["A": 0],
            speakerDatabase: nil   // forces fallback
        )
        #expect(rows.count == 1)
        #expect(rows[0].totalMs == 4000)
        #expect(rows[0].segmentCount == 2)
        // Weighted mean: (1*1000 + 3*3000) / 4000 = 10000/4000 = 2.5. L2-normalized over 256
        // identical components: each = 1/sqrt(256) = 0.0625.
        #expect(abs(rows[0].vector[0] - 0.0625) < 1e-4)
    }

    @Test("buildSpeakerEmbeddingRows skips speakers with no usable embedding")
    func buildRowsSkipsEmptyEmbeddings() {
        let segs = [
            TimedSpeakerSegment(
                speakerId: "A",
                embedding: [],   // unusable
                startTimeSeconds: 0,
                endTimeSeconds: 1,
                qualityScore: 0
            ),
        ]
        let rows = Diarizer.buildSpeakerEmbeddingRows(
            segments: segs,
            speakerIndexByID: ["A": 0],
            speakerDatabase: nil
        )
        #expect(rows.isEmpty)
    }
}
