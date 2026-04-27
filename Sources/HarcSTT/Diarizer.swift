import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's DiarizerManager. Separate from Transcriber because
/// the diarizer model loads independently — the Daemon pre-loads this in a
/// background task and degrades gracefully to empty speaker segments if load fails.
///
/// API adaptations from best-guess spec:
/// - `initialize(models:)` used instead of `loadModels(_:)` (consuming parameter pattern)
/// - `performCompleteDiarization` is synchronous `throws`, not `async throws`
/// - `TimedSpeakerSegment.speakerId` is `String` (UUID-style), not `Int`;
///   mapped to stable `Int` via an insertion-order dictionary inside the actor
/// - `startTimeSeconds`/`endTimeSeconds` are `Float`, not `Double`
public actor Diarizer: DiarizeService {
    /// Returned by `diarizeWithEmbeddings` — both the segment timeline and
    /// the per-speaker centroid embeddings, in the wire-shape ready for
    /// `DiarizeResult`.
    public struct DiarizationOutput: Sendable, Equatable {
        public let segments: [SpeakerSegment]
        public let speakers: [SpeakerEmbeddingRow]
        public init(segments: [SpeakerSegment], speakers: [SpeakerEmbeddingRow]) {
            self.segments = segments
            self.speakers = speakers
        }
    }

    private var manager: DiarizerManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func loadModels() async throws {
        guard manager == nil else { return }
        let m = DiarizerManager(config: .default)
        let models = try await DiarizerModels.download()
        m.initialize(models: models)
        self.manager = m
    }

    public func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        try await diarizeWithEmbeddings(audioPath: audioPath).segments
    }

    public func diarizeWithEmbeddings(audioPath: String) async throws -> DiarizationOutput {
        guard let m = manager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let result = try m.performCompleteDiarization(samples)

        // Map FluidAudio's String speakerIds to stable sequential Ints,
        // preserving insertion order. We need the mapping in two passes —
        // once for segments, once for the per-speaker embedding rollup.
        var speakerIndexByID: [String: Int] = [:]
        var segments: [SpeakerSegment] = []
        segments.reserveCapacity(result.segments.count)
        for seg in result.segments {
            let idx: Int
            if let existing = speakerIndexByID[seg.speakerId] {
                idx = existing
            } else {
                idx = speakerIndexByID.count
                speakerIndexByID[seg.speakerId] = idx
            }
            segments.append(SpeakerSegment(
                speaker: idx,
                startMs: Int(seg.startTimeSeconds * 1000),
                endMs: Int(seg.endTimeSeconds * 1000)
            ))
        }

        // Build per-speaker centroid + duration aggregates.
        // Preferred: FluidAudio's `speakerDatabase` is the authoritative
        // averaged centroid map keyed by speakerId. Fallback: weighted-
        // average the per-segment `embedding` vectors.
        let speakers = Self.buildSpeakerEmbeddingRows(
            segments: result.segments,
            speakerIndexByID: speakerIndexByID,
            speakerDatabase: result.speakerDatabase
        )

        return DiarizationOutput(segments: segments, speakers: speakers)
    }

    /// Pure helper for testability — does not touch FluidAudio state.
    static func buildSpeakerEmbeddingRows(
        segments: [TimedSpeakerSegment],
        speakerIndexByID: [String: Int],
        speakerDatabase: [String: [Float]]?
    ) -> [SpeakerEmbeddingRow] {
        // Aggregate totalMs and segmentCount per speaker.
        struct Agg {
            var totalMs: Int = 0
            var segmentCount: Int = 0
            var weightedSum: [Float] = []
        }
        var aggBySpeaker: [String: Agg] = [:]
        for seg in segments {
            var agg = aggBySpeaker[seg.speakerId] ?? Agg()
            let durMs = Int((seg.endTimeSeconds - seg.startTimeSeconds) * 1000)
            agg.totalMs += max(0, durMs)
            agg.segmentCount += 1
            // Build weighted sum vector for fallback path. Skip if seg
            // embedding is empty (defensive — FluidAudio sometimes returns
            // a zero-length placeholder).
            if !seg.embedding.isEmpty {
                if agg.weightedSum.isEmpty {
                    agg.weightedSum = [Float](repeating: 0, count: seg.embedding.count)
                }
                if agg.weightedSum.count == seg.embedding.count {
                    let w = Float(max(0, durMs))
                    for i in 0..<seg.embedding.count {
                        agg.weightedSum[i] += seg.embedding[i] * w
                    }
                }
            }
            aggBySpeaker[seg.speakerId] = agg
        }

        var rows: [SpeakerEmbeddingRow] = []
        rows.reserveCapacity(aggBySpeaker.count)
        for (speakerId, agg) in aggBySpeaker {
            guard let speakerIndex = speakerIndexByID[speakerId] else { continue }

            // Pick centroid: speakerDatabase if present, else fallback average.
            var vec: [Float]
            if let db = speakerDatabase, let centroid = db[speakerId], !centroid.isEmpty {
                vec = centroid
            } else if !agg.weightedSum.isEmpty, agg.totalMs > 0 {
                vec = agg.weightedSum
                let w = Float(agg.totalMs)
                for i in 0..<vec.count { vec[i] /= w }
            } else {
                continue   // No embedding source — skip the row.
            }

            l2Normalize(&vec)
            rows.append(SpeakerEmbeddingRow(
                speakerIndex: speakerIndex,
                vector: vec,
                totalMs: agg.totalMs,
                segmentCount: agg.segmentCount
            ))
        }
        // Sort by speakerIndex for deterministic ordering.
        rows.sort { $0.speakerIndex < $1.speakerIndex }
        return rows
    }
}

/// L2-normalize a vector in place. No-op if the norm is zero.
/// (Local copy here so HarcSTT doesn't need to depend on HarcVoiceprint.)
private func l2Normalize(_ v: inout [Float]) {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    let norm = sqrtf(sumSq)
    guard norm > 0 else { return }
    for i in 0..<v.count { v[i] /= norm }
}
